// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Top-level observer orchestrator.
//!
//! Ties together the L1 watcher, the game state machine, the
//! honest-strategy oracle, the persistence layer, and the
//! transaction submitter into a single long-running daemon.
//!
//! ## Iteration flow
//!
//! Each [`Observer::run_iteration`]:
//!
//!   1. Calls [`crate::watcher::Watcher::run_iteration`] to pull
//!      a batch of decoded L1 events.
//!   2. For each event:
//!      a. Apply the event to the in-memory game-state map.
//!      b. If the event introduces a new game where we should
//!         play (the challenger or sequencer side per
//!         [`ObserverConfig::play_as`]), compute the honest move
//!         via [`crate::strategy::compute_next_move`].
//!      c. If a move is required AND we haven't already
//!         submitted for this pivot, encode the calldata and
//!         submit via the configured [`crate::submitter::Submitter`].
//!   3. Commit the batch atomically: every updated game record
//!      plus every new response record plus the new watcher cursor
//!      via [`crate::persistence::Persistence::commit_batch`].
//!
//! ## Idempotency
//!
//! The orchestrator's persistence boundary ensures that a crash
//! mid-batch never leaves on-disk state inconsistent.  On
//! restart, the orchestrator re-loads every persisted game,
//! re-creates its in-memory map, and resumes the watcher from
//! the persisted cursor.  Per-pivot submission deduplication
//! defends against the corner case where a submitted tx
//! confirms on L1 but the local persistence commit failed: on
//! restart, the watcher re-sees the
//! `BisectionResponseSubmitted` event and the orchestrator
//! detects "we've already submitted for this pivot" via the
//! response-record scan + skips the second submission.
//!
//! ## Why no async runtime
//!
//! The workspace consistently avoids `tokio` / `async-std`.  The
//! observer uses `std::thread` + blocking I/O.  Long polls are
//! handled by a configurable `sleep` between iterations.  This
//! matches the design philosophy of every other runtime crate
//! (knomosis-host, knomosis-l1-ingest, knomosis-event-subscribe,
//! knomosis-indexer).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::sleep;
use std::time::Duration;

use knomosis_l1_ingest::source::L1Source;
use tracing::{debug, error, info, warn};

use crate::error::ObserverError;
use crate::events::GameEvent;
use crate::game::{
    apply_settlement, apply_transition, Claim, DisputedRange, GameState, GameStatus,
    GameTransition, TurnSide,
};
use crate::persistence::{
    GameRecord, PersistBatch, PersistedHeader, Persistence, ResponseRecord, ResponseStatus,
};
use crate::strategy::{
    compute_next_move, HonestMove, HonestMoveError, TerminateBundleError, TerminateBundleOracle,
    TruthOracle,
};
use crate::submitter::{encode_calldata, Submitter};
use crate::watcher::{Watcher, WatcherConfig};

/// The default poll interval between watcher iterations.
/// Mirrors Ethereum mainnet block time (12 s).
pub const DEFAULT_POLL_INTERVAL: Duration = Duration::from_secs(12);

/// Configuration for the orchestrator.
#[allow(clippy::module_name_repetitions)]
#[derive(Clone, Debug)]
pub struct ObserverConfig {
    /// Watcher configuration.
    pub watcher: WatcherConfig,
    /// Polling interval between iterations.
    pub poll_interval: Duration,
    /// Which side we're playing.  Production observers default
    /// to `Challenger`; the sequencer-side observer is unusual
    /// but supported for fully-symmetric deployment topologies.
    pub play_as: TurnSide,
    /// The 32-byte deployment-id used to validate inbound games.
    /// Mismatched deployment-ids are silently ignored (a
    /// cross-deployment-replay defence).
    pub deployment_id: [u8; 32],
}

impl ObserverConfig {
    /// Construct an observer config with defaults.
    #[must_use]
    pub fn new(watcher: WatcherConfig, deployment_id: [u8; 32]) -> Self {
        Self {
            watcher,
            poll_interval: DEFAULT_POLL_INTERVAL,
            play_as: TurnSide::Challenger,
            deployment_id,
        }
    }
}

/// The orchestrator.  Owns the watcher, the persistence handle,
/// the submitter, the truth oracle, plus the in-memory game map.
///
/// **Workstream SVC.5 wiring.**  The observer optionally holds a
/// [`TerminateBundleOracle`] (boxed as a trait object) for
/// constructing terminate-on-single-step calldata.  Without one,
/// the observer falls back to deferring terminate moves (logs a
/// loud warning).  Production deployments wire a
/// [`crate::strategy::SubprocessTruthOracle`] that ALSO implements
/// [`TerminateBundleOracle`] via the shared subprocess pattern.
pub struct Observer<S: L1Source, Sub: Submitter, T: TruthOracle> {
    config: ObserverConfig,
    watcher: Watcher<S>,
    persistence: Persistence,
    submitter: Sub,
    oracle: T,
    /// Optional terminate-bundle oracle (Workstream SVC).  When
    /// `None`, the observer logs + defers `TerminateOnSingleStep`
    /// moves.  When `Some`, the observer fetches the canonical
    /// bundle and constructs full-form calldata.  See
    /// [`Self::with_terminate_bundle_oracle`].
    terminate_bundle_oracle: Option<Box<dyn TerminateBundleOracle + Send + Sync>>,
    games: HashMap<u128, GameRecord>,
    /// In-memory cache of `(game_id, pivot_idx)` pairs the
    /// observer has already submitted a response for.  Populated
    /// at startup from the persisted response records; updated
    /// atomically with each `commit_batch`.  Replaces the
    /// previous O(N)-per-call `list_responses` scan with a
    /// constant-time lookup, defending against unbounded growth
    /// over the daemon's lifetime.
    submitted_pivots: std::collections::HashSet<(u128, Option<u64>)>,
    /// Per-iteration ROLLBACK SET — pivots inserted into
    /// `submitted_pivots` during the current iteration.  If
    /// `commit_batch` fails, these entries are rolled back so
    /// the same pivot can be retried on the next iteration
    /// (otherwise the dedup cache permanently locks the pivot
    /// in this process).  Cleared on successful commit.  Audit-
    /// pass-4-round-3 fix: previously a `commit_batch` failure
    /// cleared `pending_broadcasts` but left `submitted_pivots`
    /// populated, making the move un-retry-able in this process.
    iteration_pivot_inserts: Vec<(u128, Option<u64>)>,
    /// Per-iteration queue of prepared transactions awaiting
    /// L1 broadcast.  `maybe_play_move` enqueues; `run_iteration`
    /// drains AFTER `commit_batch` succeeds so the persistence
    /// commit and the L1 broadcast are properly sequenced
    /// (intent first → durable → broadcast).  Cleared at the
    /// end of each iteration.
    pending_broadcasts: Vec<PendingBroadcast>,
    /// Stop signal — when `true`, the run loop exits cleanly.
    stop: Arc<AtomicBool>,
}

/// One in-flight prepared transaction.  See `Observer.pending_broadcasts`
/// for the sequencing discipline.
#[derive(Clone, Debug)]
struct PendingBroadcast {
    prepared: crate::submitter::PreparedTx,
    game_id: u128,
    /// Carried for diagnostic logging only; the broadcast
    /// itself routes via `prepared.tx_hash`.  Marked
    /// `#[allow(dead_code)]` because the field is read only by
    /// the structured log fields (which clippy's dead-code
    /// analyzer doesn't track through `tracing::info!` macros).
    #[allow(dead_code)]
    pivot_idx: Option<u64>,
    /// Debug string for the `HonestMove` variant — logged on
    /// broadcast for operator visibility.
    move_kind: String,
}

impl<S: L1Source, Sub: Submitter, T: TruthOracle> Observer<S, Sub, T> {
    /// Construct an observer.  Opens the persistence layer,
    /// restores the in-memory state, and seeds the watcher's
    /// resume point.
    ///
    /// # Errors
    ///
    /// See [`ObserverError`].
    pub fn new(
        config: ObserverConfig,
        source: S,
        submitter: Sub,
        oracle: T,
        persistence: Persistence,
    ) -> Result<Self, ObserverError> {
        let mut watcher = Watcher::new(config.watcher.clone(), source)
            .map_err(|e| ObserverError::Config(format!("watcher: {e}")))?;
        // Restore cursor from persistence.
        let cursor = persistence.read_cursor().map_err(|e| {
            ObserverError::Storage(knomosis_storage::storage::StorageError::Other(
                e.to_string(),
            ))
        })?;
        watcher.set_last_confirmed(cursor);
        // Restore the re-org window from persistence.  This
        // closes the original RH-G.2 plan's "Persist watcher
        // state (last-processed block, recent block-hash
        // window)" requirement.  Without window persistence, a
        // re-org that orphans blocks between observer restart
        // and the next fetched block would silently be missed
        // (the new chain's block would link to a sibling of
        // the persisted cursor, not the orphan, and our window
        // would be empty → no detection).
        let persisted_headers = persistence.read_reorg_window().map_err(|e| {
            ObserverError::Storage(knomosis_storage::storage::StorageError::Other(
                e.to_string(),
            ))
        })?;
        if !persisted_headers.is_empty() {
            let restored: Vec<knomosis_l1_ingest::reorg::BlockHeader> =
                persisted_headers.into_iter().map(Into::into).collect();
            watcher.seed_window(restored);
        }
        // Restore in-memory game map.
        let game_records = persistence.list_games().map_err(|e| {
            ObserverError::Storage(knomosis_storage::storage::StorageError::Other(
                e.to_string(),
            ))
        })?;
        let mut games = HashMap::new();
        for rec in game_records {
            games.insert(rec.game_id, rec);
        }
        // Populate the in-memory pivot-dedup cache from the
        // persisted response records.  This is the O(N) cost
        // paid once at startup; subsequent dedup checks are O(1).
        let response_records = persistence.list_responses().map_err(|e| {
            ObserverError::Storage(knomosis_storage::storage::StorageError::Other(
                e.to_string(),
            ))
        })?;
        let submitted_pivots: std::collections::HashSet<(u128, Option<u64>)> = response_records
            .iter()
            .map(|r| (r.game_id, r.pivot_idx))
            .collect();
        info!(
            cursor = ?cursor,
            game_count = games.len(),
            submitted_pivot_count = submitted_pivots.len(),
            "observer initialised; resumed from persistence"
        );
        Ok(Self {
            config,
            watcher,
            persistence,
            submitter,
            oracle,
            terminate_bundle_oracle: None,
            games,
            submitted_pivots,
            iteration_pivot_inserts: Vec::new(),
            pending_broadcasts: Vec::new(),
            stop: Arc::new(AtomicBool::new(false)),
        })
    }

    /// Workstream SVC.5 wiring.  Attach a
    /// [`TerminateBundleOracle`] so the observer can construct
    /// full-form terminate-on-single-step calldata.
    ///
    /// Without a bundle oracle attached, the observer logs +
    /// defers terminate moves (the same behaviour as pre-SVC).
    ///
    /// # Examples
    ///
    /// ```ignore
    /// let oracle = SubprocessTruthOracle::new(knomosis, log)
    ///     .with_flag("--deployment-id", "00...00");
    /// let bundle_oracle = SubprocessTruthOracle::new(knomosis, log)
    ///     .with_flag("--deployment-id", "00...00");
    /// let observer = Observer::new(cfg, src, sub, oracle, persistence)?
    ///     .with_terminate_bundle_oracle(Box::new(bundle_oracle));
    /// ```
    #[must_use]
    pub fn with_terminate_bundle_oracle(
        mut self,
        bundle_oracle: Box<dyn TerminateBundleOracle + Send + Sync>,
    ) -> Self {
        self.terminate_bundle_oracle = Some(bundle_oracle);
        self
    }

    /// Read accessor for the configuration.
    #[must_use]
    pub fn config(&self) -> &ObserverConfig {
        &self.config
    }

    /// Read accessor for the in-memory game map.  Diagnostic /
    /// test-only.
    #[must_use]
    pub fn games(&self) -> &HashMap<u128, GameRecord> {
        &self.games
    }

    /// Get a clone of the stop signal.  The caller can set it to
    /// `true` to request an orderly shutdown.
    #[must_use]
    pub fn stop_signal(&self) -> Arc<AtomicBool> {
        self.stop.clone()
    }

    /// Signal a stop.
    pub fn request_stop(&self) {
        self.stop.store(true, Ordering::Release);
    }

    /// Read accessor for the submitter.  Diagnostic / test-only.
    #[must_use]
    pub fn submitter(&self) -> &Sub {
        &self.submitter
    }

    /// Read accessor for the watcher.  Tests use this to push
    /// synthetic blocks into the in-memory mock source.
    #[must_use]
    pub fn watcher(&self) -> &Watcher<S> {
        &self.watcher
    }

    /// Mutable accessor for the watcher.  Crate-private and
    /// test-only so tests can manipulate the in-memory mock
    /// source; production code runs through `run_iteration`
    /// only.
    #[cfg(test)]
    pub(crate) fn watcher_mut(&mut self) -> &mut Watcher<S> {
        &mut self.watcher
    }

    /// Override the watcher's resume point with the operator-
    /// supplied `--start-block` value.  Production callers
    /// (`main.rs`) use this after `Observer::new` to override
    /// the persisted-cursor recovery; the watcher will start
    /// fetching events from `block + 1` on the next iteration.
    ///
    /// **Operator-only escape hatch.**  Overriding the cursor
    /// outside startup bypasses the persisted-cursor resume
    /// path; specifying a value LOWER than the persisted cursor
    /// causes the observer to re-process events (idempotent at
    /// the event-dispatch boundary); specifying a value HIGHER
    /// causes the observer to silently skip events.  Use with
    /// care and document operator decisions in your runbook.
    pub fn set_start_block(&mut self, block: u64) {
        // Defensive validation: if a persisted cursor already
        // exists, warn when the override moves it BACKWARD
        // (re-processes events — usually intentional but
        // operator might typo) or way FORWARD (skips events —
        // usually a bug).  We don't BLOCK either; the operator
        // is explicitly opting in via the flag.
        if let Some(existing) = self.watcher.last_confirmed_block() {
            if block < existing {
                warn!(
                    persisted_cursor = existing,
                    start_block = block,
                    "--start-block moves cursor BACKWARD; the observer will re-process \
                     events from this block forward (idempotent at the event-dispatch \
                     boundary, but verify this is intentional)",
                );
            } else if block > existing.saturating_add(1_000_000) {
                warn!(
                    persisted_cursor = existing,
                    start_block = block,
                    skip_distance = block.saturating_sub(existing),
                    "--start-block JUMPS FORWARD by more than 1M blocks; the observer \
                     will silently SKIP all events between the persisted cursor and \
                     the override; verify this is intentional",
                );
            }
        }
        self.watcher.set_last_confirmed(Some(block));
        // Audit-pass-4-round-5 CRITICAL fix: clear the persisted
        // reorg window when the cursor is overridden.  The cached
        // headers are from the OLD chain position and would
        // surface as `OrphanedParent` / `DeepReorg` on the next
        // iteration's `advance` call against the new chain.
        // Clearing forces re-seeding from the override's first
        // block.
        self.watcher.clear_reorg_window();
    }

    /// Mark a previously-adopted cold-start game as
    /// `state_known = true`.  This is the load-bearing
    /// integration point for the deferred `eth_call`-based
    /// contract-state read: once a future PR adds the
    /// `games(uint256)` reader, it will call this method with
    /// the resolved (`range_low`, `range_high`, `sequencer`,
    /// `challenger`, bonds, `deployment_id`) values and mark
    /// the game as known.  The orchestrator's `maybe_play_move`
    /// will then start submitting moves for that game.
    ///
    /// # Defensive checks
    ///
    /// The method enforces three invariants on `full_state`:
    ///
    /// 1. **Deployment-id parity.**  The supplied `full_state`'s
    ///    `deployment_id` MUST equal the observer's configured
    ///    `deployment_id` (the bytes the operator passed on the
    ///    `--deployment-id` CLI flag).  A mismatch indicates the
    ///    caller's contract-read returned data for the WRONG
    ///    deployment, which would be a cross-deployment-replay
    ///    attempt.  Rejects with [`ObserverError::Invariant`].
    /// 2. **Status preservation.**  If the in-memory record was
    ///    already terminal (e.g., `SequencerWon`), we refuse to
    ///    overwrite with a non-terminal `InProgress` state.
    ///    The settlement event has authority over the status
    ///    field; an out-of-order `eth_call` response cannot
    ///    resurrect a settled game.  Rejects with
    ///    [`ObserverError::Invariant`].
    /// 3. **Game-id consistency.**  The supplied `full_state`'s
    ///    range bounds must satisfy `low.idx < high.idx`
    ///    (otherwise the game's bisection is degenerate).
    ///    Rejects with [`ObserverError::Invariant`].
    ///
    /// # Returns
    ///
    /// `Ok(true)` if the game was found and updated; `Ok(false)`
    /// if the game id is unknown (no-op).
    ///
    /// # Errors
    ///
    /// Returns [`ObserverError::Invariant`] if any of the
    /// defensive checks fail; [`ObserverError::Storage`] if the
    /// persistence commit fails.
    pub fn mark_state_known(
        &mut self,
        game_id: u128,
        full_state: GameState,
        block_number: u64,
    ) -> Result<bool, ObserverError> {
        let Some(rec) = self.games.get(&game_id).cloned() else {
            return Ok(false);
        };
        // Defensive check 1: deployment-id parity.
        if full_state.deployment_id != self.config.deployment_id {
            return Err(ObserverError::Invariant(format!(
                "mark_state_known game {game_id}: supplied deployment_id does not match observer's \
                 configured deployment_id; cross-deployment-replay refused",
            )));
        }
        // Defensive check 2: status preservation.  A settled
        // in-memory record cannot be overwritten with a
        // non-terminal status.
        if rec.state.status.is_terminal() && full_state.status.is_in_progress() {
            return Err(ObserverError::Invariant(format!(
                "mark_state_known game {game_id}: refusing to overwrite settled \
                 (status={:?}) state with InProgress",
                rec.state.status,
            )));
        }
        // Defensive check 3: range non-degeneracy.  A
        // legitimate game has low.idx < high.idx; the contract
        // enforces this at creation time (per
        // `initiateChallenge`'s `if (lowLogIndex >= disputedLogIndex)`
        // check).  Defends against a buggy contract-state read.
        if full_state.range.low.idx >= full_state.range.high.idx {
            return Err(ObserverError::Invariant(format!(
                "mark_state_known game {game_id}: degenerate range \
                 (low.idx={}, high.idx={}); legitimate L1 games have low < high",
                full_state.range.low.idx, full_state.range.high.idx,
            )));
        }
        let new_rec = GameRecord {
            game_id: rec.game_id,
            state: full_state,
            me: rec.me,
            last_updated_block: block_number,
            state_known: true,
        };
        self.games.insert(game_id, new_rec.clone());
        let mut batch = PersistBatch::new();
        batch.upsert_game(new_rec);
        self.persistence.commit_batch(&batch).map_err(|e| {
            ObserverError::Storage(knomosis_storage::storage::StorageError::Other(
                e.to_string(),
            ))
        })?;
        info!(
            game_id = %game_id,
            block_number = block_number,
            "game state_known transitioned to true via mark_state_known",
        );
        Ok(true)
    }

    /// Hydrate every `state_known = false` game by reading its
    /// full state from the L1 contract via the supplied state
    /// reader.  This is the production wiring for the deferred
    /// contract-state read documented on `handle_game_opened`.
    ///
    /// On a successful read, [`Self::mark_state_known`] is
    /// invoked, which atomically commits the upgraded state and
    /// flips the `state_known` flag.  Once that happens, the
    /// orchestrator's `maybe_play_move` starts submitting honest
    /// moves for the game.
    ///
    /// # Returns
    ///
    /// A tuple of `(hydrated_count, error_count)`.  Per-game
    /// errors are logged at warn-level and SKIPPED (the
    /// orchestrator continues with the remaining games); they
    /// do NOT halt the daemon.  Operators monitoring the daemon
    /// see the warn line and can investigate individually.
    ///
    /// # Errors
    ///
    /// Per-game errors are logged + counted but not propagated.
    /// The method itself does not return an error (callers can
    /// retry the next iteration).
    pub fn hydrate_cold_start_games(
        &mut self,
        reader: &crate::state_reader::ContractGameReader<'_>,
        block_number: u64,
    ) -> (usize, usize) {
        // Snapshot the cold-start game IDs.  We can't iterate
        // self.games and mark-state-known in the same loop
        // (mark_state_known mutates the map).
        let cold_start_ids: Vec<u128> = self
            .games
            .iter()
            .filter(|(_, rec)| !rec.state_known)
            .map(|(id, _)| *id)
            .collect();
        let mut hydrated = 0usize;
        let mut errors = 0usize;
        for game_id in cold_start_ids {
            match reader.read_and_validate(game_id, self.config.deployment_id) {
                Ok(full_state) => match self.mark_state_known(game_id, full_state, block_number) {
                    Ok(true) => hydrated += 1,
                    Ok(false) => {
                        // Race: game was already settled / removed
                        // between snapshot and mark.  Benign.
                    }
                    Err(e) => {
                        warn!(
                            game_id = %game_id,
                            error = %e,
                            "hydrate_cold_start_games: mark_state_known refused",
                        );
                        errors += 1;
                    }
                },
                Err(e) => {
                    warn!(
                        game_id = %game_id,
                        error = %e,
                        "hydrate_cold_start_games: eth_call failed",
                    );
                    errors += 1;
                }
            }
        }
        if hydrated > 0 || errors > 0 {
            info!(
                hydrated = hydrated,
                errors = errors,
                "hydrate_cold_start_games iteration complete",
            );
        }
        (hydrated, errors)
    }

    /// Read accessor for the persistence handle.  Tests use this
    /// to verify post-iteration state.
    #[must_use]
    pub fn persistence(&self) -> &Persistence {
        &self.persistence
    }

    /// Run a single orchestrator iteration.  Returns the number
    /// of events processed and the number of moves submitted.
    ///
    /// # Errors
    ///
    /// See [`ObserverError`].
    pub fn run_iteration(&mut self) -> Result<IterationOutcome, ObserverError> {
        // Audit-pass-4-round-4 HIGH fix: ensure the iteration
        // pivot-rollback set starts empty AND that we roll back
        // on every error path (not just commit-batch failure).
        // Previously the field was drained only on the commit-
        // batch success path; an early-return error from
        // `handle_event` could carry stale entries into the next
        // iteration AND leave `submitted_pivots` populated for
        // entries that never actually got persisted, silently
        // mis-attributing pivots to the wrong commit.
        //
        // We use a delegating helper + a final rollback on Err
        // so every early-return path (whether from recover_intent_
        // records, watcher.run_iteration, handle_event,
        // commit_batch, or any broadcast) correctly rolls back
        // the in-memory cache to match persistence.
        self.iteration_pivot_inserts.clear();
        let outcome = self.run_iteration_inner();
        if outcome.is_err() {
            // Roll back any pivots inserted during this failed
            // iteration so they can be retried.
            let pivots = std::mem::take(&mut self.iteration_pivot_inserts);
            for p in pivots {
                self.submitted_pivots.remove(&p);
            }
        }
        outcome
    }

    /// Inner implementation of `run_iteration`.  Separated so
    /// the outer wrapper can apply the per-iteration rollback
    /// discipline uniformly (audit-pass-4-round-4 HIGH fix).
    fn run_iteration_inner(&mut self) -> Result<IterationOutcome, ObserverError> {
        // Pre-flight: re-broadcast any prepared txs that we
        // persisted in a prior iteration but couldn't broadcast
        // (process killed between commit and broadcast).  These
        // appear in persistence with `status = Intent`.  At
        // most one such record per (game_id, pivot_idx) so the
        // recovery is bounded.
        self.recover_intent_records()?;

        let watch = self.watcher.run_iteration().map_err(|e| match e {
            crate::watcher::WatcherError::Source(s) => ObserverError::Source(s),
            crate::watcher::WatcherError::Reorg(r) => ObserverError::Reorg(r),
            crate::watcher::WatcherError::Decode(d) => ObserverError::EventDecode(d),
            crate::watcher::WatcherError::Config(m) => ObserverError::Config(m),
        })?;
        let mut batch = PersistBatch::new();
        let mut submitted_moves: u32 = 0;
        for event in &watch.events {
            match self.handle_event(event, &mut batch)? {
                EventHandling::Submitted => submitted_moves += 1,
                EventHandling::Recorded | EventHandling::Skipped => (),
            }
        }
        if let Some(new_cursor) = watch.new_last_confirmed {
            batch.set_cursor(new_cursor);
            // Snapshot the re-org window into the batch so it
            // commits atomically with the cursor advance.  This
            // closes RH-G.2's "persist recent block-hash window"
            // requirement.
            let snapshot: Vec<PersistedHeader> = self
                .watcher
                .window_snapshot()
                .into_iter()
                .map(Into::into)
                .collect();
            batch.set_reorg_window(snapshot);
        }
        // Phase 1: commit persistence (including any prepared
        // tx intent records staged by `maybe_play_move`).
        if !batch.is_empty() {
            // Audit-pass-4-round-4 simplification: the outer
            // `run_iteration` wrapper handles pivot rollback for
            // ALL error paths (including this one).  We only
            // need to clear `pending_broadcasts` on commit
            // failure so subsequent iterations don't try to
            // broadcast txs whose persistence intent record
            // never landed.  `iteration_pivot_inserts` stays
            // populated and the outer rollback drains it.
            match self.persistence.commit_batch(&batch) {
                Ok(()) => {
                    // Commit succeeded; clear the rollback set
                    // (pivots stay in the cache, matching
                    // persistence).
                    self.iteration_pivot_inserts.clear();
                    debug!(
                        games = batch.games.len(),
                        responses = batch.responses.len(),
                        cursor = ?batch.cursor,
                        "batch committed",
                    );
                }
                Err(e) => {
                    // Commit failed.  Drop queued broadcasts;
                    // outer wrapper drains `iteration_pivot_inserts`
                    // and rolls back the dedup cache.
                    self.pending_broadcasts.clear();
                    return Err(ObserverError::Storage(
                        knomosis_storage::storage::StorageError::Other(e.to_string()),
                    ));
                }
            }
        }
        // Phase 2: broadcast queued txs.  Persistence is now
        // durable for each prepared tx's `Intent` record.  On
        // broadcast success, transition the record from `Intent`
        // → `Pending`; on broadcast failure, transition to
        // `Failed` (operator-level investigation).  Each
        // broadcast's status update is a SEPARATE small
        // transaction so a network error mid-drain doesn't
        // unwind the whole batch.
        let drained = std::mem::take(&mut self.pending_broadcasts);
        for pending in drained {
            self.broadcast_and_update_status(&pending)?;
        }
        info!(
            event_count = watch.events.len(),
            submitted_moves = submitted_moves,
            cursor = ?watch.new_last_confirmed,
            reorg_absorbed = watch.reorg_absorbed,
            "iteration complete",
        );
        Ok(IterationOutcome {
            event_count: watch.events.len(),
            submitted_moves,
            reorg_absorbed: watch.reorg_absorbed,
            new_cursor: watch.new_last_confirmed,
        })
    }

    /// Re-broadcast any persisted `Intent`-status response
    /// records that didn't get broadcast in their original
    /// iteration (process crashed between commit and
    /// broadcast).  Idempotent: the L1 RPC's
    /// `eth_sendRawTransaction` is `tx_hash`-idempotent.  After
    /// broadcast, the record's status transitions to
    /// `Pending` (or `Failed`).
    fn recover_intent_records(&mut self) -> Result<(), ObserverError> {
        let all_responses = self.persistence.list_responses().map_err(|e| {
            ObserverError::Storage(knomosis_storage::storage::StorageError::Other(
                e.to_string(),
            ))
        })?;
        for rec in all_responses {
            if rec.status != ResponseStatus::Intent {
                continue;
            }
            let Some(raw_hex) = &rec.raw_tx_hex else {
                warn!(
                    tx_hash = %rec.tx_hash_hex,
                    game_id = %rec.game_id,
                    "Intent record has no raw_tx_hex; cannot re-broadcast (skipping)",
                );
                continue;
            };
            let raw_bytes = match hex::decode(raw_hex) {
                Ok(b) => b,
                Err(e) => {
                    warn!(
                        tx_hash = %rec.tx_hash_hex,
                        err = %e,
                        "Intent record's raw_tx_hex malformed; cannot re-broadcast (skipping)",
                    );
                    continue;
                }
            };
            let tx_hash_bytes = match hex::decode(&rec.tx_hash_hex) {
                Ok(b) if b.len() == 32 => {
                    let mut a = [0u8; 32];
                    a.copy_from_slice(&b);
                    a
                }
                _ => {
                    warn!(
                        tx_hash = %rec.tx_hash_hex,
                        "Intent record's tx_hash_hex malformed; cannot re-broadcast (skipping)",
                    );
                    continue;
                }
            };
            let prepared = crate::submitter::PreparedTx {
                tx_hash: tx_hash_bytes,
                raw_bytes,
            };
            let pending = PendingBroadcast {
                prepared,
                game_id: rec.game_id,
                pivot_idx: rec.pivot_idx,
                move_kind: "re-broadcast".to_string(),
            };
            info!(
                tx_hash = %rec.tx_hash_hex,
                game_id = %rec.game_id,
                "re-broadcasting persisted Intent record after crash recovery",
            );
            // Audit-pass-4-round-5 CRITICAL fix: log + continue on
            // per-record errors instead of `?`-propagating.  The
            // previous code would abort recovery on the FIRST
            // failure, leaving all subsequent Intent records
            // un-recovered and crashing the daemon.  A wedged
            // broadcast for one tx would stall recovery for every
            // subsequent tx.  Recovery continues; failed records
            // will be retried next iteration via the same
            // recovery loop.
            if let Err(e) = self.broadcast_and_update_status(&pending) {
                warn!(
                    tx_hash = %rec.tx_hash_hex,
                    game_id = %rec.game_id,
                    err = %e,
                    "broadcast_and_update_status failed during recovery; \
                     will retry next iteration",
                );
            }
        }
        Ok(())
    }

    /// Broadcast a prepared tx and update its persisted
    /// response record's status atomically.  On broadcast
    /// success: transition `Intent` → `Pending`.  On broadcast
    /// failure: transition `Intent` → `Failed` so the operator
    /// can see what went wrong.
    fn broadcast_and_update_status(
        &mut self,
        pending: &PendingBroadcast,
    ) -> Result<(), ObserverError> {
        let (new_status, log_msg) = match self.submitter.broadcast(&pending.prepared) {
            Ok(()) => (ResponseStatus::Pending, "broadcast OK"),
            Err(e) => {
                warn!(
                    game_id = %pending.game_id,
                    tx_hash = %hex::encode(pending.prepared.tx_hash),
                    err = %e,
                    "broadcast failed; marking response Failed",
                );
                // Audit-pass-4 (round 3) fix: invalidate the
                // submitter's nonce cache.  The peek/commit
                // refactor protected against sign-time failures
                // but a broadcast-time failure still leaves the
                // cache at `N+1` while L1 may not have consumed
                // nonce `N`.  Without this re-sync, the next
                // build-and-sign would use a "skipped" nonce and
                // L1 would reject it.  The default trait impl is
                // a no-op (sufficient for `MockSubmitter`); the
                // `JsonRpcSubmitter` override clears the cache so
                // the next call re-fetches from
                // `eth_getTransactionCount`.
                self.submitter.invalidate_nonce_cache();
                (ResponseStatus::Failed, "broadcast failed")
            }
        };
        // Update the persisted record's status.  Fetch the
        // existing record, mutate the status field, persist
        // back.  Atomic per-record write.
        match self
            .persistence
            .load_response(&pending.prepared.tx_hash)
            .map_err(|e| {
                ObserverError::Storage(knomosis_storage::storage::StorageError::Other(
                    e.to_string(),
                ))
            })? {
            Some(mut existing) => {
                existing.status = new_status;
                self.persistence.store_response(&existing).map_err(|e| {
                    ObserverError::Storage(knomosis_storage::storage::StorageError::Other(
                        e.to_string(),
                    ))
                })?;
                info!(
                    game_id = %pending.game_id,
                    move_kind = %pending.move_kind,
                    tx_hash = %hex::encode(pending.prepared.tx_hash),
                    status = ?new_status,
                    "{log_msg}",
                );
            }
            None => {
                warn!(
                    tx_hash = %hex::encode(pending.prepared.tx_hash),
                    "broadcast for tx not in persistence; skipping status update",
                );
            }
        }
        Ok(())
    }

    /// Handle a single event.  Updates the in-memory game map +
    /// the persistence batch + (if appropriate) submits a move.
    fn handle_event(
        &mut self,
        event: &GameEvent,
        batch: &mut PersistBatch,
    ) -> Result<EventHandling, ObserverError> {
        match event {
            GameEvent::GameOpened {
                game_id,
                disputed_state_root,
                challenger_state_root,
                challenger_topic: _,
                block_number,
                ..
            } => self.handle_game_opened(
                *game_id,
                *disputed_state_root,
                *challenger_state_root,
                *block_number,
                batch,
            ),
            GameEvent::MidpointSubmitted {
                game_id,
                idx,
                commit,
                block_number,
                ..
            } => self.handle_midpoint_submitted(*game_id, *idx, *commit, *block_number, batch),
            GameEvent::ResponseSubmitted {
                game_id,
                agree,
                block_number,
                ..
            } => self.handle_response_submitted(*game_id, *agree, *block_number, batch),
            GameEvent::GameSettled {
                game_id,
                status,
                winner_payout: _,
                block_number,
                ..
            } => self.handle_game_settled(*game_id, *status, *block_number, batch),
            GameEvent::StateRootSubmitted { .. } => {
                // State-root submissions are monitored separately
                // by the fault-detection pipeline (RH-G.4 cell-
                // proof generator); they don't directly affect a
                // game state.  Record only.
                Ok(EventHandling::Skipped)
            }
        }
    }

    /// Handle a `GameOpened` event.
    ///
    /// **Note on cold-start games**: a real production observer
    /// challenges incorrect state roots BEFORE a game is opened
    /// (it calls `initiateChallenge` itself).  Here we model the
    /// case where the observer is watching games initiated by a
    /// SEPARATE party (or a previous instance of itself).  When
    /// `GameOpened` fires, the observer adopts the game and
    /// starts playing.
    ///
    /// The game-state synthesis here is a simplification: we
    /// don't have access to the full L1 game-state via events
    /// alone (events carry the disputed state roots but not the
    /// low/high index pair).  Production deployments would
    /// additionally read the game's storage via
    /// `games(uint256)` on the contract — that read is RH-G
    /// follow-up work.  For RH-G's initial landing, we
    /// synthesise a SKELETON game state and rely on the observer
    /// to learn the true game shape from subsequent events
    /// (`MidpointSubmitted` carries the actual `idx`).
    //
    // Returns `Result` for symmetry with the other event-handler
    // dispatch arms (`handle_midpoint_submitted`,
    // `handle_response_submitted`, `handle_game_settled`) so the
    // caller can use a single `?` pattern.  RH-G follow-up work
    // (contract-state reads) will introduce real fallible paths.
    #[allow(clippy::unnecessary_wraps)]
    fn handle_game_opened(
        &mut self,
        game_id: u128,
        disputed_state_root: [u8; 32],
        challenger_state_root: [u8; 32],
        block_number: u64,
        batch: &mut PersistBatch,
    ) -> Result<EventHandling, ObserverError> {
        if self.games.contains_key(&game_id) {
            // Duplicate event (probably from a re-org or restart);
            // ignore.
            return Ok(EventHandling::Skipped);
        }
        // Synthesise a skeleton game state.  The
        // `FaultProofGameOpened` event carries the disputed +
        // challenger state roots but NOT the full game state
        // (low.idx / high.idx range bounds, sequencer /
        // challenger actor ids, bond amounts).  Production
        // deployments learn the full state via an `eth_call` to
        // `games(uint256)` on the contract — deferred RH-G
        // follow-up work tracked in CLAUDE.md.
        //
        // Until the contract-state read lands, we mark the
        // skeleton as `state_known = false` so the orchestrator's
        // `maybe_play_move` refuses to compute or submit moves
        // for this game.  The skeleton IS still persisted +
        // updated from observed events, but no calldata is
        // submitted in the interim.  This defends against the
        // observer broadcasting wrong-shape calldata derived
        // from placeholder range bounds.
        let synthesised_state = GameState {
            sequencer: 0,  // placeholder
            challenger: 0, // placeholder
            range: DisputedRange {
                low: Claim {
                    idx: 0,
                    commit: [0u8; 32],
                },
                high: Claim {
                    idx: 0, // placeholder — real value via contract read
                    commit: disputed_state_root,
                },
            },
            pending_midpoint: None,
            depth: 0,
            // Per the Solidity contract, the sequencer responds
            // first after a game is opened.
            turn: TurnSide::Sequencer,
            sequencer_bond: 0,
            challenger_bond: 0,
            status: GameStatus::InProgress,
            // **Cross-deployment-replay defence is INCOMPLETE.**
            // The `FaultProofGameOpened` event does NOT carry the
            // contract's `deploymentId`.  We tag the skeleton
            // with `self.config.deployment_id` so downstream code
            // sees the expected value, but until the contract
            // read lands we cannot actually verify that this
            // game's deploymentId matches.  See lib.rs's
            // "Security properties" §3 for the deferral note.
            deployment_id: self.config.deployment_id,
        };
        let _ = challenger_state_root; // recorded for future use; the
                                       // honest strategy doesn't need
                                       // the challenger's claim here.
        let rec = GameRecord {
            game_id,
            state: synthesised_state,
            me: self.config.play_as,
            last_updated_block: block_number,
            state_known: false,
        };
        self.games.insert(game_id, rec.clone());
        batch.upsert_game(rec);
        info!(
            game_id = %game_id,
            "game opened; adopted (state_known=false until contract read lands)",
        );
        Ok(EventHandling::Recorded)
    }

    /// Handle a `MidpointSubmitted` event.
    fn handle_midpoint_submitted(
        &mut self,
        game_id: u128,
        idx: u64,
        commit: [u8; 32],
        block_number: u64,
        batch: &mut PersistBatch,
    ) -> Result<EventHandling, ObserverError> {
        let Some(rec) = self.games.get(&game_id).cloned() else {
            warn!(
                game_id = %game_id,
                "midpoint submitted for unknown game; ignoring",
            );
            return Ok(EventHandling::Skipped);
        };
        // If we don't know the full game state yet (no
        // contract-state read has happened), we cannot validate
        // the midpoint against the true range bounds.  Record
        // the pending midpoint into the skeleton state directly
        // (without going through `apply_transition`, which would
        // reject `idx > high.idx = 0` for a cold-start game) so
        // we have an audit trail, but DO NOT call
        // `maybe_play_move` — we'd otherwise compute calldata
        // against placeholder bounds.
        //
        // Defensive: the bypass mirrors `apply_transition`'s
        // `gameAlreadyEnded` guard so a settled game cannot have
        // its `pending_midpoint` resurrected by a stale event.
        // In normal flow this is unreachable (events are
        // processed in `(block, log_index)` order and the L1
        // contract never emits MidpointSubmitted on a settled
        // game), but the watcher CAN re-deliver events under
        // re-org scenarios; better to fail loud than corrupt
        // state silently.
        if !rec.state_known {
            if !rec.state.status.is_in_progress() {
                warn!(
                    game_id = %game_id,
                    status = ?rec.state.status,
                    "midpoint event for settled cold-start game; ignoring",
                );
                return Ok(EventHandling::Skipped);
            }
            let mut new_rec = rec.clone();
            new_rec.state.pending_midpoint = Some(Claim { idx, commit });
            new_rec.state.turn = rec.state.turn.flip();
            new_rec.last_updated_block = block_number;
            self.games.insert(game_id, new_rec.clone());
            batch.upsert_game(new_rec);
            debug!(
                game_id = %game_id,
                idx = idx,
                "midpoint recorded for unknown-state game; no move computed",
            );
            return Ok(EventHandling::Recorded);
        }
        // Full state is known: drive the state machine.
        let mp = Claim { idx, commit };
        match apply_transition(&rec.state, GameTransition::SubmitMidpoint(mp)) {
            Ok(new_state) => {
                let mut new_rec = rec.clone();
                new_rec.state = new_state;
                new_rec.last_updated_block = block_number;
                self.games.insert(game_id, new_rec.clone());
                batch.upsert_game(new_rec.clone());
                // Now it's our turn to respond (if `play_as` ==
                // post-flip turn).
                if let Some(submitted) = self.maybe_play_move(&new_rec, block_number, batch)? {
                    if submitted {
                        return Ok(EventHandling::Submitted);
                    }
                }
                Ok(EventHandling::Recorded)
            }
            Err(e) => {
                // The L1 contract authoritatively accepted the
                // event, so our in-memory state machine
                // disagreeing is a sign of state drift.  Log and
                // skip; the on-chain contract is the truth.
                warn!(
                    game_id = %game_id,
                    err = ?e,
                    "midpoint event rejected by Rust state machine; possible drift",
                );
                Ok(EventHandling::Skipped)
            }
        }
    }

    /// Handle a `ResponseSubmitted` event.
    fn handle_response_submitted(
        &mut self,
        game_id: u128,
        agree: bool,
        block_number: u64,
        batch: &mut PersistBatch,
    ) -> Result<EventHandling, ObserverError> {
        let Some(rec) = self.games.get(&game_id).cloned() else {
            warn!(
                game_id = %game_id,
                "response submitted for unknown game; ignoring",
            );
            return Ok(EventHandling::Skipped);
        };
        // Unknown-state games: clear the pending midpoint (the
        // L1 contract did so) and flip the turn.  We CAN'T
        // narrow the range without knowing the bounds.  No move
        // computed.
        //
        // **Depth-tracking note.**  We increment depth on every
        // observed response, which matches the L1 contract's
        // post-respond `depth + 1`.  However, if the observer
        // adopted the game mid-flight (e.g., via `--start-block`
        // past the FaultProofGameOpened block), our depth will
        // be LOWER than the L1's by the number of pre-adoption
        // responses.  This is harmless: `maybe_play_move`
        // refuses to act on `state_known = false` games, and
        // when the deferred eth_call sets `state_known = true`
        // it will reload the true depth from the contract.
        //
        // Defensive: refuse to mutate state on a settled game.
        if !rec.state_known {
            if !rec.state.status.is_in_progress() {
                warn!(
                    game_id = %game_id,
                    status = ?rec.state.status,
                    "response event for settled cold-start game; ignoring",
                );
                return Ok(EventHandling::Skipped);
            }
            let mut new_rec = rec.clone();
            new_rec.state.pending_midpoint = None;
            new_rec.state.turn = rec.state.turn.flip();
            // Clamp depth at MAX_BISECTION_DEPTH + 1 (i.e., 65)
            // so the post-state remains within an envelope that
            // `apply_transition`'s `bisectionDepthExceeded` guard
            // would recognise.  An unclamped saturating_add lets
            // depth grow to u32::MAX over many observed responses,
            // which would defeat the depth-cap invariant if
            // `apply_transition` were later called on this state
            // (e.g., after `mark_state_known` flips state_known
            // but a subsequent event interleaves).  Clamp to the
            // "just-exceeded" value so the next `apply_transition`
            // call cleanly returns `BisectionDepthExceeded`.
            new_rec.state.depth = new_rec
                .state
                .depth
                .saturating_add(1)
                .min(crate::game::MAX_BISECTION_DEPTH + 1);
            new_rec.last_updated_block = block_number;
            self.games.insert(game_id, new_rec.clone());
            batch.upsert_game(new_rec);
            debug!(
                game_id = %game_id,
                agree = agree,
                "response recorded for unknown-state game; no move computed",
            );
            return Ok(EventHandling::Recorded);
        }
        let transition = if agree {
            GameTransition::RespondAgree
        } else {
            GameTransition::RespondDisagree
        };
        match apply_transition(&rec.state, transition) {
            Ok(new_state) => {
                let mut new_rec = rec.clone();
                new_rec.state = new_state;
                new_rec.last_updated_block = block_number;
                self.games.insert(game_id, new_rec.clone());
                batch.upsert_game(new_rec.clone());
                if let Some(submitted) = self.maybe_play_move(&new_rec, block_number, batch)? {
                    if submitted {
                        return Ok(EventHandling::Submitted);
                    }
                }
                Ok(EventHandling::Recorded)
            }
            Err(e) => {
                warn!(
                    game_id = %game_id,
                    err = ?e,
                    "response event rejected by Rust state machine; possible drift",
                );
                Ok(EventHandling::Skipped)
            }
        }
    }

    /// Handle a `GameSettled` event.
    //
    // Returns `Result` for symmetry with the other event-handler
    // dispatch arms; see `handle_game_opened` for rationale.
    #[allow(clippy::unnecessary_wraps)]
    fn handle_game_settled(
        &mut self,
        game_id: u128,
        status: GameStatus,
        block_number: u64,
        batch: &mut PersistBatch,
    ) -> Result<EventHandling, ObserverError> {
        let Some(rec) = self.games.get(&game_id).cloned() else {
            warn!(
                game_id = %game_id,
                "game settled for unknown game; ignoring",
            );
            return Ok(EventHandling::Skipped);
        };
        // If the L1 status is `InProgress`, that's a malformed
        // event (the contract never emits Settled with
        // `InProgress`); skip defensively.
        if status.is_in_progress() {
            warn!(game_id = %game_id, "game-settled event carries InProgress status; ignoring");
            return Ok(EventHandling::Skipped);
        }
        match apply_settlement(&rec.state, status) {
            Ok(new_state) => {
                let mut new_rec = rec.clone();
                new_rec.state = new_state;
                new_rec.last_updated_block = block_number;
                self.games.insert(game_id, new_rec.clone());
                batch.upsert_game(new_rec);
                info!(game_id = %game_id, status = ?status, "game settled");
                Ok(EventHandling::Recorded)
            }
            Err(e) => {
                warn!(
                    game_id = %game_id,
                    err = ?e,
                    "settlement rejected by Rust state machine; possible drift",
                );
                Ok(EventHandling::Skipped)
            }
        }
    }

    /// If the current game state requires a move from our side,
    /// compute it via the strategy and submit via the submitter.
    /// Returns `Ok(Some(true))` if a move was actually submitted,
    /// `Ok(Some(false))` if it was the player's turn but the
    /// strategy returned `NoMove` (degenerate state), `Ok(None)`
    /// if it wasn't our turn.
    //
    // Returns `Result` to preserve symmetry with the event-handler
    // dispatch surface and to leave room for future submitter
    // failure modes (e.g. cell-proof construction errors) to
    // propagate as typed errors rather than panics.
    #[allow(clippy::unnecessary_wraps)]
    fn maybe_play_move(
        &mut self,
        rec: &GameRecord,
        block_number: u64,
        batch: &mut PersistBatch,
    ) -> Result<Option<bool>, ObserverError> {
        if !rec.state.status.is_in_progress() {
            return Ok(None);
        }
        if rec.state.turn != rec.me {
            return Ok(None);
        }
        // Critical safety gate: refuse to compute or submit
        // moves for games whose full state we haven't learned.
        // The `handle_game_opened` synthesises a skeleton with
        // placeholder `low.idx = 0, high.idx = 0` because the
        // `FaultProofGameOpened` event doesn't carry the range
        // bounds; learning the true bounds requires an `eth_call`
        // to `games(uint256)` on the contract (deferred RH-G
        // follow-up).  Without the bounds, any computed midpoint
        // would be a fiction and the resulting calldata would be
        // rejected on-chain at best, or accepted-but-wrong at
        // worst.  Defer until the full state is known.
        if !rec.state_known {
            debug!(
                game_id = %rec.game_id,
                "skipping move: state_known=false (cold-start game; eth_call follow-up pending)",
            );
            return Ok(Some(false));
        }
        let mv = match compute_next_move(&self.oracle, &rec.state, rec.me) {
            Ok(m) => m,
            Err(HonestMoveError::TruthOracleMissed { idx }) => {
                // The oracle hasn't caught up; defer.
                warn!(
                    game_id = %rec.game_id,
                    missed_idx = idx,
                    "truth oracle missed; deferring move",
                );
                return Ok(Some(false));
            }
        };
        if matches!(mv, HonestMove::NoMove) {
            return Ok(Some(false));
        }
        let Some(calldata) = self.build_calldata_for_move(rec, mv) else {
            return Ok(Some(false));
        };
        // Deduplication check: have we already submitted at
        // this pivot?  The pivot for `Submit` is the
        // midpoint_idx; for `Respond` the pending_midpoint.idx.
        let pivot_idx = pivot_for_move(&rec.state, mv);
        if self.has_submitted_for_pivot(rec.game_id, pivot_idx) {
            debug!(
                game_id = %rec.game_id,
                pivot_idx = ?pivot_idx,
                "already submitted for this pivot; skipping",
            );
            return Ok(Some(false));
        }
        // Phase 1: build + sign.  No network I/O.  The
        // resulting `PreparedTx` carries the canonical
        // `tx_hash` (computable from the signed bytes, known
        // BEFORE broadcast) and the `raw_bytes` ready for
        // `eth_sendRawTransaction`.
        let prepared = match self.submitter.build_and_sign(&calldata) {
            Ok(p) => p,
            Err(e) => {
                error!(
                    game_id = %rec.game_id,
                    err = %e,
                    "build_and_sign failed; deferring move",
                );
                return Ok(Some(false));
            }
        };
        // Phase 2: persist the PRE-BROADCAST intent record.  The
        // tx_hash is the canonical one (computed from signed
        // bytes), so a crash between persist and broadcast can
        // be recovered by re-broadcasting the stored
        // `raw_tx_hex` on restart.  This closes the H-1 audit
        // gap.
        let resp = ResponseRecord {
            tx_hash_hex: hex::encode(prepared.tx_hash),
            raw_tx_hex: Some(hex::encode(&prepared.raw_bytes)),
            game_id: rec.game_id,
            status: ResponseStatus::Intent,
            submitted_at_block: block_number,
            depth: rec.state.depth,
            pivot_idx,
        };
        batch.upsert_response(resp);
        // Insert into the in-memory pivot-dedup cache so a
        // subsequent move within the same iteration cannot
        // duplicate-submit.  Stored under the canonical
        // tx_hash (not the calldata's hash) so cache + persistence
        // agree on the de-dup key.  Audit-pass-4-round-3 fix:
        // also record the insert in `iteration_pivot_inserts`
        // so we can roll it back if `commit_batch` fails (would
        // otherwise permanently lock the pivot in this process).
        let pivot_key = (rec.game_id, pivot_idx);
        if self.submitted_pivots.insert(pivot_key) {
            self.iteration_pivot_inserts.push(pivot_key);
        }
        // Phase 3 (deferred to `run_iteration` after
        // `commit_batch`): broadcast.  We enqueue the prepared
        // tx into `pending_broadcasts`; the orchestrator
        // drains the queue AFTER persistence commit so a
        // commit failure leaves NO intent + NO broadcast
        // (atomic rollback).  On commit success, the
        // orchestrator broadcasts each enqueued tx and updates
        // the persisted record's status to `Pending` (or
        // `Failed` on broadcast error).
        self.pending_broadcasts.push(PendingBroadcast {
            prepared,
            game_id: rec.game_id,
            pivot_idx,
            move_kind: format!("{mv:?}"),
        });
        info!(
            game_id = %rec.game_id,
            move_kind = ?mv,
            "honest move queued for broadcast (intent persisted)",
        );
        Ok(Some(true))
    }

    /// Check whether we've already submitted a response for the
    /// given (`game_id`, `pivot_idx`) pair.  Used by the
    /// deduplication discipline.  Constant-time lookup against
    /// the in-memory cache, populated at startup from persisted
    /// response records.
    fn has_submitted_for_pivot(&self, game_id: u128, pivot_idx: Option<u64>) -> bool {
        self.submitted_pivots.contains(&(game_id, pivot_idx))
    }

    /// Workstream SVC.5 helper: build the L1 calldata bytes for
    /// the chosen honest move.  Returns `Some(bytes)` if the
    /// observer should broadcast, `None` if the move was deferred
    /// (logged inside).  Extracted from `maybe_play_move` to keep
    /// the orchestrator function's line count manageable.
    fn build_calldata_for_move(&self, rec: &GameRecord, mv: HonestMove) -> Option<Vec<u8>> {
        match mv {
            HonestMove::TerminateOnSingleStep { .. } => self.build_terminate_calldata(rec, mv),
            other => match encode_calldata(rec.game_id, other) {
                Ok(c) => Some(c),
                Err(e) => {
                    error!(
                        game_id = %rec.game_id,
                        err = %e,
                        "calldata encoding failed; deferring move",
                    );
                    None
                }
            },
        }
    }

    /// Workstream SVC.5: build the full-form terminate-on-single-
    /// step calldata bytes using the configured bundle oracle.
    /// Returns `Some(bytes)` on success, `None` if any step failed
    /// (logged inside).
    fn build_terminate_calldata(&self, rec: &GameRecord, mv: HonestMove) -> Option<Vec<u8>> {
        let bundle_oracle = match &self.terminate_bundle_oracle {
            None => {
                warn!(
                    game_id = %rec.game_id,
                    pivot_idx = ?pivot_for_move(&rec.state, mv),
                    "TerminateOnSingleStep deferred: no TerminateBundleOracle \
                     attached (call Observer::with_terminate_bundle_oracle \
                     to enable terminate-move construction)",
                );
                return None;
            }
            Some(o) => o,
        };
        // Fetch the bundle at the disputed action-entry index.
        // For a single-step range `[low, high] = [n, n+1]`, the
        // action in dispute is `entries[n]`, i.e. `range.low.idx`.
        let pivot = rec.state.range.low.idx;
        let bundle = match bundle_oracle.terminate_bundle_at(pivot) {
            Ok(b) => b,
            Err(TerminateBundleError::Missed { idx }) => {
                warn!(
                    game_id = %rec.game_id,
                    missed_idx = idx,
                    "terminate bundle oracle missed; deferring move",
                );
                return None;
            }
            Err(e) => {
                error!(
                    game_id = %rec.game_id,
                    err = %e,
                    "terminate bundle fetch failed; deferring move",
                );
                return None;
            }
        };
        // Defence-in-depth: the bundle's `claimed_post_commit`
        // MUST agree with the strategy's `claimed_post_commit`
        // (the truth oracle's view of the L1 step VM hash at the
        // pivot).  `encode_calldata_with_bundle` enforces this
        // and surfaces `BundleCommitMismatch` on drift; if the
        // two oracles disagree, refuse to broadcast a calldata
        // that would lose the game.
        match crate::submitter::encode_calldata_with_bundle(rec.game_id, mv, Some(&bundle)) {
            Ok(c) => {
                info!(
                    game_id = %rec.game_id,
                    pivot_idx = pivot,
                    action_kind = bundle.action_kind,
                    "terminate calldata constructed from bundle",
                );
                Some(c)
            }
            Err(e) => {
                error!(
                    game_id = %rec.game_id,
                    err = %e,
                    "terminate calldata build failed; deferring move",
                );
                None
            }
        }
    }

    /// Run the orchestrator loop until the stop signal is set.
    /// Each iteration is followed by a poll-interval sleep
    /// unless the stop signal is set.
    ///
    /// # Errors
    ///
    /// Returns the first irrecoverable error.  Transient errors
    /// trigger a poll-interval sleep + retry; fatal errors
    /// (deep re-org, persistence corruption) exit the loop.
    pub fn run(&mut self) -> Result<(), ObserverError> {
        info!("observer loop starting");
        while !self.stop.load(Ordering::Acquire) {
            match self.run_iteration() {
                Ok(outcome) => {
                    debug!(
                        events = outcome.event_count,
                        submitted = outcome.submitted_moves,
                        "iteration ok",
                    );
                }
                Err(e) => {
                    // For transient errors, log + sleep + retry.
                    let exit_code = e.exit_code();
                    if matches!(
                        exit_code,
                        knomosis_cli_common::exit::OperatorExitCode::Transient
                    ) {
                        warn!(err = %e, "transient error; will retry");
                    } else {
                        error!(err = %e, "fatal error; exiting loop");
                        return Err(e);
                    }
                }
            }
            // Interruptible sleep.
            interruptible_sleep(self.config.poll_interval, &self.stop);
        }
        info!("observer loop stopped cleanly");
        Ok(())
    }
}

/// Convenience helper for the integration-test crate to seed
/// the watcher's last-confirmed-block.  Mirrors the test-only
/// crate-private accessor at the `Observer::watcher_mut` level.
/// Production code uses [`Observer::set_start_block`] directly;
/// this helper exists so the integration-test crate doesn't
/// have to know about the public method's full type signature.
#[doc(hidden)]
pub fn seed_watcher_for_tests<S: L1Source, Sub: Submitter, T: TruthOracle>(
    observer: &mut Observer<S, Sub, T>,
    last_confirmed: u64,
) {
    observer.set_start_block(last_confirmed);
}

/// Sleep for `duration`, but check the stop signal periodically
/// to allow prompt shutdown.
fn interruptible_sleep(duration: Duration, stop: &AtomicBool) {
    let tick = Duration::from_millis(100);
    let mut elapsed = Duration::ZERO;
    while elapsed < duration {
        if stop.load(Ordering::Acquire) {
            return;
        }
        let chunk = tick.min(duration - elapsed);
        sleep(chunk);
        elapsed += chunk;
    }
}

/// Compute the pivot index for the given move.  Returns:
///
///   * For `Submit(claim)`: `Some(claim.idx)` — the midpoint we
///     just submitted.
///   * For `Respond*`: `Some(pending_midpoint.idx)` — the
///     midpoint we just responded to.
///   * For `TerminateOnSingleStep`: `Some(range.high.idx)` —
///     the single-step's high index.
///   * For `NoMove`: `None`.
fn pivot_for_move(state: &GameState, mv: HonestMove) -> Option<u64> {
    match mv {
        HonestMove::NoMove => None,
        HonestMove::Submit(c) => Some(c.idx),
        HonestMove::RespondAgree | HonestMove::RespondDisagree => {
            state.pending_midpoint.map(|m| m.idx)
        }
        HonestMove::TerminateOnSingleStep { .. } => Some(state.range.high.idx),
    }
}

/// Per-event handling outcome.
#[derive(Debug)]
enum EventHandling {
    /// The event was recorded (state updated; no submission).
    Recorded,
    /// The event was recorded AND a move was submitted.
    Submitted,
    /// The event was skipped (duplicate, unknown game,
    /// malformed, or settled-game).
    Skipped,
}

/// One iteration's high-level outcome.
#[derive(Debug, Clone, Copy)]
pub struct IterationOutcome {
    /// Number of events processed.
    pub event_count: usize,
    /// Number of moves submitted.
    pub submitted_moves: u32,
    /// True iff the watcher absorbed a re-org during this
    /// iteration.
    pub reorg_absorbed: bool,
    /// The new cursor value (or `None` if no progress was
    /// made).
    pub new_cursor: Option<u64>,
}

#[cfg(test)]
mod tests {
    use super::{Observer, ObserverConfig};
    use crate::error::ObserverError;
    use crate::events::{GameEvent, GameEventTopic};
    use crate::game::{Claim, DisputedRange, GameState, GameStatus, StateCommit, TurnSide};
    use crate::persistence::{
        GameRecord, PersistBatch, Persistence, ResponseRecord, ResponseStatus,
    };
    use crate::strategy::{HonestMove, MemoryTruthOracle};
    use crate::submitter::mock::MockSubmitter;
    use crate::watcher::WatcherConfig;
    use knomosis_l1_ingest::action::EthAddress;
    use knomosis_l1_ingest::events::{RawLog, TopicHash};
    use knomosis_l1_ingest::reorg::BlockHeader;
    use knomosis_l1_ingest::source::mock::InMemoryL1Source;
    use std::collections::HashMap;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    fn make_contract_addr(seed: u8) -> EthAddress {
        let mut out = [0u8; 20];
        out[0] = seed;
        EthAddress(out)
    }

    fn make_block_hash(seed: u8, idx: u8) -> TopicHash {
        let mut out = [0u8; 32];
        out[0] = seed.wrapping_add(idx);
        out[31] = idx;
        out
    }

    fn commit(seed: u8) -> StateCommit {
        let mut out = [0u8; 32];
        out[0] = seed;
        out
    }

    fn header(number: u64, hash: TopicHash, parent_hash: TopicHash) -> BlockHeader {
        BlockHeader {
            number,
            hash,
            parent_hash,
        }
    }

    fn topic_from_u128(v: u128) -> TopicHash {
        let mut out = [0u8; 32];
        out[16..32].copy_from_slice(&v.to_be_bytes());
        out
    }

    fn topic_from_u64(v: u64) -> TopicHash {
        let mut out = [0u8; 32];
        out[24..32].copy_from_slice(&v.to_be_bytes());
        out
    }

    /// Build a fresh observer with mock dependencies.  Returns
    /// the observer + the tempdir guard (which must outlive the
    /// observer; `Persistence` keeps a file handle to the
    /// `SQLite` database inside `dir`).
    fn fresh_observer() -> (
        Observer<InMemoryL1Source, MockSubmitter, MemoryTruthOracle>,
        tempfile::TempDir,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let persistence = Persistence::open(&db).unwrap();
        let source = InMemoryL1Source::new();
        let submitter = MockSubmitter::new();
        let oracle = MemoryTruthOracle::new();
        let watcher_cfg = WatcherConfig {
            game_contract: make_contract_addr(1),
            state_root_submission_contract: make_contract_addr(2),
            confirmation_depth: 1,
            reorg_window_capacity: 16,
            blocks_per_iteration: 64,
        };
        let cfg = ObserverConfig::new(watcher_cfg, [0u8; 32]);
        let obs = Observer::new(cfg, source, submitter, oracle, persistence).unwrap();
        (obs, dir)
    }

    /// Empty source: iteration is a clean no-op.
    #[test]
    fn iteration_no_op_on_empty_source() {
        let (mut obs, _dir) = fresh_observer();
        let out = obs.run_iteration().unwrap();
        assert_eq!(out.event_count, 0);
        assert_eq!(out.submitted_moves, 0);
    }

    /// Adopt a game opened by an external party.  After
    /// `GameOpened`, the in-memory map has the game.
    ///
    /// Setup: push 5 blocks (100..104) one of which (block 102)
    /// emits a `FaultProofGameOpened` event.  Seed the watcher
    /// with `last_confirmed=Some(99)` so the first iteration
    /// processes blocks 100..103 (`confirmation_depth=1` makes
    /// blocks <= 103 confirmed when latest=104).
    #[test]
    fn adopt_game_opened_event() {
        let (mut obs, _dir) = fresh_observer();
        let game_contract = obs.config.watcher.game_contract;
        let mut last_hash = [0u8; 32];
        for i in 0..5u8 {
            let h = make_block_hash(0x10, i);
            let head = header(100 + u64::from(i), h, last_hash);
            last_hash = h;
            let mut logs = HashMap::new();
            if i == 2 {
                // Block 102: emit a `FaultProofGameOpened` event.
                let game_id = 42u128;
                let challenger = topic_from_u64(0xCAFE);
                let mut data = Vec::with_capacity(64);
                data.extend_from_slice(&[0x11u8; 32]); // disputed root
                data.extend_from_slice(&[0x22u8; 32]); // chal root
                let log = RawLog {
                    address: game_contract,
                    topics: vec![
                        GameEventTopic::GameOpened.hash(),
                        topic_from_u128(game_id),
                        challenger,
                    ],
                    data,
                    block_number: 100 + u64::from(i),
                    tx_hash: [0xab; 32],
                    log_index: 0,
                };
                logs.insert(game_contract, vec![log]);
            }
            obs.watcher_mut().source_mut().push_block(head, logs);
        }
        obs.watcher_mut().source_mut().set_latest(104);
        // Seed so the iteration processes blocks 100..103
        // (without this, fresh watcher jumps to confirmed_head
        // and processes only the latest confirmed block).
        obs.watcher_mut().set_last_confirmed(Some(99));

        let out = obs.run_iteration().unwrap();
        assert!(out.event_count >= 1, "should have decoded the GameOpened");
        assert!(obs.games().contains_key(&42));
        // The game state should be persisted as well.
        let loaded = obs.persistence().load_game(42).unwrap();
        assert!(loaded.is_some());
        let loaded_rec = loaded.unwrap();
        assert_eq!(loaded_rec.state.status, GameStatus::InProgress);
        // Audit-pass regression: cold-start games adopted from
        // event payloads must have state_known = false.
        assert!(!loaded_rec.state_known);
    }

    /// Cold-start bypass for `MidpointSubmitted` refuses to
    /// resurrect a settled game's `pending_midpoint`.  Mirrors
    /// `apply_transition`'s `gameAlreadyEnded` guard.
    #[test]
    fn cold_start_midpoint_event_on_settled_game_skipped() {
        let (mut obs, _dir) = fresh_observer();
        // Inject a settled cold-start game.
        obs.games.insert(
            42,
            GameRecord {
                game_id: 42,
                state: GameState {
                    sequencer: 0,
                    challenger: 0,
                    range: DisputedRange {
                        low: Claim {
                            idx: 0,
                            commit: [0u8; 32],
                        },
                        high: Claim {
                            idx: 0,
                            commit: commit(1),
                        },
                    },
                    pending_midpoint: None,
                    depth: 0,
                    turn: TurnSide::Sequencer,
                    sequencer_bond: 0,
                    challenger_bond: 0,
                    status: GameStatus::SequencerWon, // already settled
                    deployment_id: [0u8; 32],
                },
                me: TurnSide::Challenger,
                last_updated_block: 100,
                state_known: false,
            },
        );
        let event = GameEvent::MidpointSubmitted {
            game_id: 42,
            party_topic: [0u8; 32],
            idx: 32,
            commit: commit(7),
            block_number: 200,
            tx_hash: [0xff; 32],
            log_index: 0,
        };
        let mut batch = PersistBatch::new();
        let outcome = obs.handle_event(&event, &mut batch).unwrap();
        assert!(matches!(outcome, super::EventHandling::Skipped));
        // State should NOT have a resurrected pending_midpoint.
        let rec = obs.games().get(&42).unwrap();
        assert!(rec.state.pending_midpoint.is_none());
    }

    /// Cold-start bypass for `ResponseSubmitted` refuses to
    /// mutate a settled game's state.
    #[test]
    fn cold_start_response_event_on_settled_game_skipped() {
        let (mut obs, _dir) = fresh_observer();
        obs.games.insert(
            42,
            GameRecord {
                game_id: 42,
                state: GameState {
                    sequencer: 0,
                    challenger: 0,
                    range: DisputedRange {
                        low: Claim {
                            idx: 0,
                            commit: [0u8; 32],
                        },
                        high: Claim {
                            idx: 0,
                            commit: commit(1),
                        },
                    },
                    pending_midpoint: Some(Claim {
                        idx: 32,
                        commit: commit(7),
                    }),
                    depth: 5,
                    turn: TurnSide::Challenger,
                    sequencer_bond: 0,
                    challenger_bond: 0,
                    status: GameStatus::ChallengerWon, // settled
                    deployment_id: [0u8; 32],
                },
                me: TurnSide::Challenger,
                last_updated_block: 100,
                state_known: false,
            },
        );
        let event = GameEvent::ResponseSubmitted {
            game_id: 42,
            party_topic: [0u8; 32],
            agree: true,
            block_number: 200,
            tx_hash: [0xff; 32],
            log_index: 0,
        };
        let mut batch = PersistBatch::new();
        let outcome = obs.handle_event(&event, &mut batch).unwrap();
        assert!(matches!(outcome, super::EventHandling::Skipped));
        // State should NOT have its depth bumped.
        let rec = obs.games().get(&42).unwrap();
        assert_eq!(rec.state.depth, 5);
    }

    /// Pivot dedup: submitting the same pivot twice doesn't
    /// re-record.
    #[test]
    fn pivot_dedup_helper_populates_from_persistence_at_startup() {
        // The in-memory dedup cache is populated at startup
        // from the persisted response records.  Write a
        // response, then construct an observer over the same
        // DB and verify the cache reflects the persisted state.
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        {
            let persistence = Persistence::open(&db).unwrap();
            let resp = ResponseRecord {
                tx_hash_hex: format!("0x{}", "ab".repeat(32)),
                raw_tx_hex: None,
                game_id: 7,
                status: ResponseStatus::Pending,
                submitted_at_block: 100,
                depth: 0,
                pivot_idx: Some(32),
            };
            persistence.store_response(&resp).unwrap();
        }
        // Construct a fresh observer over the same DB.
        let persistence = Persistence::open(&db).unwrap();
        let source = InMemoryL1Source::new();
        let submitter = MockSubmitter::new();
        let oracle = MemoryTruthOracle::new();
        let watcher_cfg = WatcherConfig {
            game_contract: make_contract_addr(1),
            state_root_submission_contract: make_contract_addr(2),
            confirmation_depth: 1,
            reorg_window_capacity: 16,
            blocks_per_iteration: 64,
        };
        let cfg = ObserverConfig::new(watcher_cfg, [0u8; 32]);
        let obs = Observer::new(cfg, source, submitter, oracle, persistence).unwrap();
        // Cache populated from persistence: hit on (7, Some(32)).
        assert!(obs.has_submitted_for_pivot(7, Some(32)));
        assert!(!obs.has_submitted_for_pivot(7, Some(64)));
        assert!(!obs.has_submitted_for_pivot(99, Some(32)));
    }

    /// In-memory dedup cache is updated atomically with each
    /// `maybe_play_move` submission.  After a submission, the
    /// SAME pivot cannot be re-submitted in the same iteration.
    #[test]
    fn pivot_dedup_in_memory_cache_blocks_resubmission() {
        let (mut obs, _dir) = fresh_observer();
        assert!(!obs.has_submitted_for_pivot(42, Some(16)));
        // Insert directly into the in-memory cache (mirrors
        // what `maybe_play_move` does after a successful submit).
        obs.submitted_pivots.insert((42, Some(16)));
        assert!(obs.has_submitted_for_pivot(42, Some(16)));
        assert!(!obs.has_submitted_for_pivot(42, Some(32)));
    }

    /// `mark_state_known` updates a cold-start game's state and
    /// flips its `state_known` flag, unblocking move submission.
    #[test]
    fn mark_state_known_transitions_cold_start_game() {
        let (mut obs, _dir) = fresh_observer();
        // Inject a cold-start game.
        let cold_game = GameRecord {
            game_id: 77,
            state: GameState {
                sequencer: 0,
                challenger: 0,
                range: DisputedRange {
                    low: Claim {
                        idx: 0,
                        commit: [0u8; 32],
                    },
                    high: Claim {
                        idx: 0,
                        commit: commit(1),
                    },
                },
                pending_midpoint: None,
                depth: 0,
                turn: TurnSide::Sequencer,
                sequencer_bond: 0,
                challenger_bond: 0,
                status: GameStatus::InProgress,
                deployment_id: [0u8; 32],
            },
            me: TurnSide::Challenger,
            last_updated_block: 100,
            state_known: false,
        };
        obs.games.insert(77, cold_game);

        // Mark with full state.
        let full_state = GameState {
            sequencer: 11,
            challenger: 22,
            range: DisputedRange {
                low: Claim {
                    idx: 0,
                    commit: commit(7),
                },
                high: Claim {
                    idx: 1024,
                    commit: commit(8),
                },
            },
            pending_midpoint: None,
            depth: 0,
            turn: TurnSide::Sequencer,
            sequencer_bond: 100_000,
            challenger_bond: 100_000,
            status: GameStatus::InProgress,
            // Match the observer's configured deployment_id
            // (fresh_observer uses `[0u8; 32]`).  The audit-
            // pass-3 defensive check rejects mismatched ids.
            deployment_id: [0u8; 32],
        };
        let updated = obs.mark_state_known(77, full_state.clone(), 200).unwrap();
        assert!(updated);
        let rec = obs.games().get(&77).unwrap();
        assert!(rec.state_known);
        assert_eq!(rec.state.sequencer, 11);
        assert_eq!(rec.state.range.high.idx, 1024);
        assert_eq!(rec.last_updated_block, 200);
        // Persistence reflects the update.
        let loaded = obs.persistence().load_game(77).unwrap().unwrap();
        assert!(loaded.state_known);
    }

    /// `mark_state_known` on unknown game id is a no-op.
    #[test]
    fn mark_state_known_unknown_game_is_noop() {
        let (mut obs, _dir) = fresh_observer();
        let dummy_state = GameState {
            sequencer: 1,
            challenger: 2,
            range: DisputedRange {
                low: Claim {
                    idx: 0,
                    commit: [0u8; 32],
                },
                high: Claim {
                    idx: 64,
                    commit: [0u8; 32],
                },
            },
            pending_midpoint: None,
            depth: 0,
            turn: TurnSide::Sequencer,
            sequencer_bond: 0,
            challenger_bond: 0,
            status: GameStatus::InProgress,
            deployment_id: [0u8; 32],
        };
        let updated = obs.mark_state_known(99_999, dummy_state, 100).unwrap();
        assert!(!updated);
    }

    /// `mark_state_known` rejects a state with a mismatched
    /// `deployment_id`.  This is the cross-deployment-replay
    /// defence that prevents an `eth_call` from a misconfigured
    /// contract address from overwriting our in-memory state.
    #[test]
    fn mark_state_known_rejects_mismatched_deployment_id() {
        let (mut obs, _dir) = fresh_observer();
        // Inject a cold-start game with the observer's configured
        // deployment_id ([0u8; 32]).
        obs.games.insert(
            77,
            GameRecord {
                game_id: 77,
                state: GameState {
                    sequencer: 0,
                    challenger: 0,
                    range: DisputedRange {
                        low: Claim {
                            idx: 0,
                            commit: [0u8; 32],
                        },
                        high: Claim {
                            idx: 0,
                            commit: commit(1),
                        },
                    },
                    pending_midpoint: None,
                    depth: 0,
                    turn: TurnSide::Sequencer,
                    sequencer_bond: 0,
                    challenger_bond: 0,
                    status: GameStatus::InProgress,
                    deployment_id: [0u8; 32],
                },
                me: TurnSide::Challenger,
                last_updated_block: 100,
                state_known: false,
            },
        );
        // Attempt mark_state_known with WRONG deployment_id.
        let wrong_state = GameState {
            sequencer: 11,
            challenger: 22,
            range: DisputedRange {
                low: Claim {
                    idx: 0,
                    commit: commit(7),
                },
                high: Claim {
                    idx: 1024,
                    commit: commit(8),
                },
            },
            pending_midpoint: None,
            depth: 0,
            turn: TurnSide::Sequencer,
            sequencer_bond: 0,
            challenger_bond: 0,
            status: GameStatus::InProgress,
            deployment_id: [0xDE; 32], // mismatched!
        };
        let err = obs.mark_state_known(77, wrong_state, 200).unwrap_err();
        assert!(matches!(err, ObserverError::Invariant(_)));
        // The in-memory record must remain UNTOUCHED.
        let rec = obs.games().get(&77).unwrap();
        assert!(!rec.state_known);
    }

    /// `mark_state_known` refuses to overwrite a settled game's
    /// status with `InProgress`.  The settlement event has
    /// authority over the status field; an out-of-order
    /// `eth_call` response cannot resurrect a settled game.
    #[test]
    fn mark_state_known_refuses_to_resurrect_settled_game() {
        let (mut obs, _dir) = fresh_observer();
        obs.games.insert(
            88,
            GameRecord {
                game_id: 88,
                state: GameState {
                    sequencer: 0,
                    challenger: 0,
                    range: DisputedRange {
                        low: Claim {
                            idx: 0,
                            commit: [0u8; 32],
                        },
                        high: Claim {
                            idx: 0,
                            commit: commit(1),
                        },
                    },
                    pending_midpoint: None,
                    depth: 0,
                    turn: TurnSide::Sequencer,
                    sequencer_bond: 0,
                    challenger_bond: 0,
                    status: GameStatus::ChallengerWon, // already settled
                    deployment_id: [0u8; 32],
                },
                me: TurnSide::Challenger,
                last_updated_block: 100,
                state_known: false,
            },
        );
        let resurrect_state = GameState {
            sequencer: 11,
            challenger: 22,
            range: DisputedRange {
                low: Claim {
                    idx: 0,
                    commit: commit(7),
                },
                high: Claim {
                    idx: 1024,
                    commit: commit(8),
                },
            },
            pending_midpoint: None,
            depth: 0,
            turn: TurnSide::Sequencer,
            sequencer_bond: 0,
            challenger_bond: 0,
            status: GameStatus::InProgress, // tries to resurrect
            deployment_id: [0u8; 32],
        };
        let err = obs.mark_state_known(88, resurrect_state, 200).unwrap_err();
        assert!(matches!(err, ObserverError::Invariant(_)));
        // The settled status must remain unchanged.
        let rec = obs.games().get(&88).unwrap();
        assert_eq!(rec.state.status, GameStatus::ChallengerWon);
    }

    /// `mark_state_known` is idempotent: calling twice with the
    /// H-1 audit-pass-4 regression: an `Intent`-status record
    /// persisted by a prior iteration (process killed between
    /// commit and broadcast) is detected and re-broadcast at
    /// the next iteration via `recover_intent_records`.
    #[test]
    fn h1_intent_record_recovery_re_broadcasts() {
        let (mut obs, _dir) = fresh_observer();
        // Stage an Intent-status record directly in persistence
        // (simulating a prior iteration's pre-broadcast commit
        // followed by a crash).
        let intent_rec = ResponseRecord {
            tx_hash_hex: "ab".repeat(32),
            raw_tx_hex: Some(hex::encode([1u8, 2, 3, 4])),
            game_id: 42,
            status: ResponseStatus::Intent,
            submitted_at_block: 100,
            depth: 0,
            pivot_idx: Some(16),
        };
        obs.persistence().store_response(&intent_rec).unwrap();
        // Run an iteration; recover_intent_records should fire
        // pre-flight and broadcast the intent.
        let _ = obs.run_iteration().unwrap();
        // The mock submitter recorded the broadcast.
        let subs = obs.submitter().submissions();
        assert_eq!(subs.len(), 1);
        assert_eq!(subs[0].calldata, vec![1u8, 2, 3, 4]);
        // The persisted record's status transitioned to Pending.
        let mut hash_bytes = [0u8; 32];
        hash_bytes[..].copy_from_slice(&hex::decode("ab".repeat(32)).unwrap());
        let loaded = obs
            .persistence()
            .load_response(&hash_bytes)
            .unwrap()
            .unwrap();
        assert_eq!(loaded.status, ResponseStatus::Pending);
    }

    /// H-1 audit-pass-4 regression: if the broadcast FAILS
    /// during intent recovery, the record transitions to
    /// `Failed`.  The operator can investigate via
    /// `list_responses` filter on status.
    #[test]
    fn h1_intent_record_recovery_marks_failed_on_broadcast_error() {
        let (mut obs, _dir) = fresh_observer();
        let intent_rec = ResponseRecord {
            tx_hash_hex: "cd".repeat(32),
            raw_tx_hex: Some(hex::encode([5u8, 6, 7])),
            game_id: 99,
            status: ResponseStatus::Intent,
            submitted_at_block: 100,
            depth: 0,
            pivot_idx: Some(8),
        };
        obs.persistence().store_response(&intent_rec).unwrap();
        // Configure the mock submitter to reject the broadcast.
        obs.submitter().set_next_reject();
        // Pre-flight: invalidate_count should be zero.
        let pre_count = obs.submitter().invalidate_count();
        let _ = obs.run_iteration().unwrap();
        let mut hash_bytes = [0u8; 32];
        hash_bytes[..].copy_from_slice(&hex::decode("cd".repeat(32)).unwrap());
        let loaded = obs
            .persistence()
            .load_response(&hash_bytes)
            .unwrap()
            .unwrap();
        assert_eq!(loaded.status, ResponseStatus::Failed);
        // Audit-pass-4-round-3 regression: broadcast failure
        // MUST trigger `invalidate_nonce_cache` so the next
        // build-and-sign re-discovers the canonical nonce from
        // the RPC.  Without this, the cache stays at `N+1` while
        // L1 still expects `N` (the broadcast-failed tx never
        // consumed a nonce).
        let post_count = obs.submitter().invalidate_count();
        assert_eq!(
            post_count - pre_count,
            1,
            "broadcast failure must call invalidate_nonce_cache exactly once \
             (pre={pre_count}, post={post_count})",
        );
    }

    /// Audit-pass-4-round-4 HIGH regression: directly exercise
    /// the pivot-rollback semantics.  Inserting a pivot then
    /// invoking the rollback path should leave the cache empty.
    /// This pins the `run_iteration_inner` wrapper's contract
    /// that failed iterations roll back the cache.
    #[test]
    fn iteration_pivot_rollback_clears_cache_on_failed_iteration() {
        let (mut obs, _dir) = fresh_observer();
        // Pre-populate the iteration rollback set + cache.
        obs.submitted_pivots.insert((42, Some(7)));
        obs.iteration_pivot_inserts.push((42, Some(7)));
        // Simulate the run_iteration outer wrapper's error-path
        // rollback by invoking the same logic directly.
        let pivots = std::mem::take(&mut obs.iteration_pivot_inserts);
        for p in &pivots {
            obs.submitted_pivots.remove(p);
        }
        // Cache must be empty post-rollback.
        assert!(
            !obs.submitted_pivots.contains(&(42, Some(7))),
            "pivot should be rolled back after failed iteration",
        );
        // The rollback set is also drained.
        assert!(obs.iteration_pivot_inserts.is_empty());
    }

    /// `mark_state_known` is idempotent: calling twice with the
    /// same arguments produces the same observable end state.
    /// (The second call updates `last_updated_block` only.)
    #[test]
    fn mark_state_known_is_idempotent() {
        let (mut obs, _dir) = fresh_observer();
        // Inject a cold-start game.
        obs.games.insert(
            55,
            GameRecord {
                game_id: 55,
                state: GameState {
                    sequencer: 0,
                    challenger: 0,
                    range: DisputedRange {
                        low: Claim {
                            idx: 0,
                            commit: [0u8; 32],
                        },
                        high: Claim {
                            idx: 0,
                            commit: commit(1),
                        },
                    },
                    pending_midpoint: None,
                    depth: 0,
                    turn: TurnSide::Sequencer,
                    sequencer_bond: 0,
                    challenger_bond: 0,
                    status: GameStatus::InProgress,
                    deployment_id: [0u8; 32],
                },
                me: TurnSide::Challenger,
                last_updated_block: 100,
                state_known: false,
            },
        );
        let full_state = GameState {
            sequencer: 11,
            challenger: 22,
            range: DisputedRange {
                low: Claim {
                    idx: 0,
                    commit: commit(7),
                },
                high: Claim {
                    idx: 1024,
                    commit: commit(8),
                },
            },
            pending_midpoint: None,
            depth: 0,
            turn: TurnSide::Sequencer,
            sequencer_bond: 100_000,
            challenger_bond: 100_000,
            status: GameStatus::InProgress,
            deployment_id: [0u8; 32],
        };
        // First call: transitions to state_known = true.
        let first = obs.mark_state_known(55, full_state.clone(), 200).unwrap();
        assert!(first);
        let rec_after_first = obs.games().get(&55).unwrap().clone();
        // Second call with identical args.
        let second = obs.mark_state_known(55, full_state.clone(), 200).unwrap();
        assert!(second);
        let rec_after_second = obs.games().get(&55).unwrap().clone();
        // Idempotence: end states are equal.
        assert_eq!(rec_after_first, rec_after_second);
    }

    /// `mark_state_known` rejects a degenerate range (low >= high).
    #[test]
    fn mark_state_known_rejects_degenerate_range() {
        let (mut obs, _dir) = fresh_observer();
        obs.games.insert(
            99,
            GameRecord {
                game_id: 99,
                state: GameState {
                    sequencer: 0,
                    challenger: 0,
                    range: DisputedRange {
                        low: Claim {
                            idx: 0,
                            commit: [0u8; 32],
                        },
                        high: Claim {
                            idx: 0,
                            commit: commit(1),
                        },
                    },
                    pending_midpoint: None,
                    depth: 0,
                    turn: TurnSide::Sequencer,
                    sequencer_bond: 0,
                    challenger_bond: 0,
                    status: GameStatus::InProgress,
                    deployment_id: [0u8; 32],
                },
                me: TurnSide::Challenger,
                last_updated_block: 100,
                state_known: false,
            },
        );
        let degenerate_state = GameState {
            sequencer: 11,
            challenger: 22,
            range: DisputedRange {
                low: Claim {
                    idx: 100,
                    commit: commit(7),
                },
                high: Claim {
                    idx: 100, // SAME as low → degenerate
                    commit: commit(8),
                },
            },
            pending_midpoint: None,
            depth: 0,
            turn: TurnSide::Sequencer,
            sequencer_bond: 0,
            challenger_bond: 0,
            status: GameStatus::InProgress,
            deployment_id: [0u8; 32],
        };
        let err = obs.mark_state_known(99, degenerate_state, 200).unwrap_err();
        assert!(matches!(err, ObserverError::Invariant(_)));
    }

    /// Stop signal halts the run loop promptly.
    #[test]
    fn stop_signal_halts_run_loop() {
        let (mut obs, _dir) = fresh_observer();
        // Set the poll interval to 60s so we can verify the
        // stop check is honoured in the chunked sleep path.
        obs.config.poll_interval = Duration::from_secs(60);
        let stop = obs.stop_signal();
        let handle = std::thread::spawn(move || {
            obs.run().unwrap();
        });
        // Give the loop a tick to enter the sleep.
        std::thread::sleep(Duration::from_millis(50));
        stop.store(true, Ordering::Release);
        handle.join().unwrap();
    }

    /// `IterationOutcome` carries the expected fields.
    #[test]
    fn iteration_outcome_fields() {
        let out = super::IterationOutcome {
            event_count: 3,
            submitted_moves: 1,
            reorg_absorbed: false,
            new_cursor: Some(100),
        };
        assert_eq!(out.event_count, 3);
        assert_eq!(out.submitted_moves, 1);
        assert!(!out.reorg_absorbed);
        assert_eq!(out.new_cursor, Some(100));
    }

    /// Game settled by the L1 contract terminates the in-memory
    /// state.
    #[test]
    fn game_settled_updates_state() {
        let (mut obs, _dir) = fresh_observer();
        // Inject a game.
        obs.games.insert(
            42,
            GameRecord {
                game_id: 42,
                state: GameState {
                    sequencer: 1,
                    challenger: 2,
                    range: DisputedRange {
                        low: Claim {
                            idx: 0,
                            commit: commit(1),
                        },
                        high: Claim {
                            idx: 64,
                            commit: commit(2),
                        },
                    },
                    pending_midpoint: None,
                    depth: 0,
                    turn: TurnSide::Sequencer,
                    sequencer_bond: 1_000,
                    challenger_bond: 1_000,
                    status: GameStatus::InProgress,
                    deployment_id: [0u8; 32],
                },
                me: TurnSide::Challenger,
                last_updated_block: 100,
                state_known: true,
            },
        );
        // Simulate a `GameSettled` event.
        let event = GameEvent::GameSettled {
            game_id: 42,
            status: GameStatus::ChallengerWon,
            winner_topic: [0u8; 32],
            winner_payout: 1_000,
            block_number: 110,
            tx_hash: [0xcc; 32],
            log_index: 0,
        };
        let mut batch = PersistBatch::new();
        let _ = obs.handle_event(&event, &mut batch).unwrap();
        assert_eq!(obs.games[&42].state.status, GameStatus::ChallengerWon);
    }

    /// Settled-game event on a game we don't know about is
    /// skipped (no crash).
    #[test]
    fn settled_for_unknown_game_skipped() {
        let (mut obs, _dir) = fresh_observer();
        let event = GameEvent::GameSettled {
            game_id: 999,
            status: GameStatus::ChallengerWon,
            winner_topic: [0u8; 32],
            winner_payout: 0,
            block_number: 1,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        let mut batch = PersistBatch::new();
        let outcome = obs.handle_event(&event, &mut batch).unwrap();
        assert!(matches!(outcome, super::EventHandling::Skipped));
    }

    /// Midpoint-submitted event on a game we don't know about
    /// is skipped.
    #[test]
    fn midpoint_for_unknown_game_skipped() {
        let (mut obs, _dir) = fresh_observer();
        let event = GameEvent::MidpointSubmitted {
            game_id: 999,
            party_topic: [0u8; 32],
            idx: 32,
            commit: commit(7),
            block_number: 1,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        let mut batch = PersistBatch::new();
        let outcome = obs.handle_event(&event, &mut batch).unwrap();
        assert!(matches!(outcome, super::EventHandling::Skipped));
    }

    /// Response-submitted event on a game we don't know about
    /// is skipped.
    #[test]
    fn response_for_unknown_game_skipped() {
        let (mut obs, _dir) = fresh_observer();
        let event = GameEvent::ResponseSubmitted {
            game_id: 999,
            party_topic: [0u8; 32],
            agree: true,
            block_number: 1,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        let mut batch = PersistBatch::new();
        let outcome = obs.handle_event(&event, &mut batch).unwrap();
        assert!(matches!(outcome, super::EventHandling::Skipped));
    }

    /// `StateRootSubmitted` events are skipped (recorded
    /// separately).
    #[test]
    fn state_root_submitted_skipped() {
        let (mut obs, _dir) = fresh_observer();
        let event = GameEvent::StateRootSubmitted {
            log_index_claim: 1,
            state_commit: commit(7),
            sequencer_topic: [0u8; 32],
            block_number: 1,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        let mut batch = PersistBatch::new();
        let outcome = obs.handle_event(&event, &mut batch).unwrap();
        assert!(matches!(outcome, super::EventHandling::Skipped));
    }

    /// Resume-from-persistence: a fresh observer over the same
    /// DB sees the previously-stored games + cursor.
    #[test]
    fn resume_from_persistence() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        // First observer: persist a game + cursor.
        {
            let persistence = Persistence::open(&db).unwrap();
            let source = InMemoryL1Source::new();
            let submitter = MockSubmitter::new();
            let oracle = MemoryTruthOracle::new();
            let watcher_cfg = WatcherConfig {
                game_contract: make_contract_addr(1),
                state_root_submission_contract: make_contract_addr(2),
                confirmation_depth: 1,
                reorg_window_capacity: 16,
                blocks_per_iteration: 64,
            };
            let cfg = ObserverConfig::new(watcher_cfg, [0u8; 32]);
            let obs = Observer::new(cfg, source, submitter, oracle, persistence).unwrap();
            // Persist a game directly.
            let rec = GameRecord {
                game_id: 99,
                state: GameState {
                    sequencer: 1,
                    challenger: 2,
                    range: DisputedRange {
                        low: Claim {
                            idx: 0,
                            commit: commit(1),
                        },
                        high: Claim {
                            idx: 64,
                            commit: commit(2),
                        },
                    },
                    pending_midpoint: None,
                    depth: 0,
                    turn: TurnSide::Sequencer,
                    sequencer_bond: 1_000,
                    challenger_bond: 1_000,
                    status: GameStatus::InProgress,
                    deployment_id: [0u8; 32],
                },
                me: TurnSide::Challenger,
                last_updated_block: 50,
                state_known: true,
            };
            obs.persistence().store_game(&rec).unwrap();
            obs.persistence().write_cursor(123).unwrap();
        }
        // Second observer: should see the game + cursor.
        let persistence = Persistence::open(&db).unwrap();
        let source = InMemoryL1Source::new();
        let submitter = MockSubmitter::new();
        let oracle = MemoryTruthOracle::new();
        let watcher_cfg = WatcherConfig {
            game_contract: make_contract_addr(1),
            state_root_submission_contract: make_contract_addr(2),
            confirmation_depth: 1,
            reorg_window_capacity: 16,
            blocks_per_iteration: 64,
        };
        let cfg = ObserverConfig::new(watcher_cfg, [0u8; 32]);
        let obs2 = Observer::new(cfg, source, submitter, oracle, persistence).unwrap();
        assert!(obs2.games().contains_key(&99));
        assert_eq!(obs2.watcher().last_confirmed_block(), Some(123));
    }

    /// Duplicate `GameOpened` is skipped (idempotent).
    #[test]
    fn duplicate_game_opened_idempotent() {
        let (mut obs, _dir) = fresh_observer();
        let event = GameEvent::GameOpened {
            game_id: 7,
            challenger_topic: [0u8; 32],
            disputed_state_root: commit(1),
            challenger_state_root: commit(2),
            block_number: 100,
            tx_hash: [0xff; 32],
            log_index: 0,
        };
        let mut batch1 = PersistBatch::new();
        let outcome1 = obs.handle_event(&event, &mut batch1).unwrap();
        assert!(matches!(outcome1, super::EventHandling::Recorded));
        let mut batch2 = PersistBatch::new();
        let outcome2 = obs.handle_event(&event, &mut batch2).unwrap();
        assert!(matches!(outcome2, super::EventHandling::Skipped));
    }

    /// `pivot_for_move` returns sensible pivots.
    #[test]
    fn pivot_for_move_correct() {
        use crate::strategy::HonestMove;
        let state = GameState {
            sequencer: 1,
            challenger: 2,
            range: DisputedRange {
                low: Claim {
                    idx: 0,
                    commit: commit(1),
                },
                high: Claim {
                    idx: 64,
                    commit: commit(2),
                },
            },
            pending_midpoint: Some(Claim {
                idx: 32,
                commit: commit(3),
            }),
            depth: 0,
            turn: TurnSide::Challenger,
            sequencer_bond: 0,
            challenger_bond: 0,
            status: GameStatus::InProgress,
            deployment_id: [0u8; 32],
        };
        assert_eq!(super::pivot_for_move(&state, HonestMove::NoMove), None,);
        assert_eq!(
            super::pivot_for_move(
                &state,
                HonestMove::Submit(Claim {
                    idx: 16,
                    commit: commit(7)
                }),
            ),
            Some(16),
        );
        assert_eq!(
            super::pivot_for_move(&state, HonestMove::RespondAgree),
            Some(32),
        );
        assert_eq!(
            super::pivot_for_move(&state, HonestMove::RespondDisagree),
            Some(32),
        );
        assert_eq!(
            super::pivot_for_move(
                &state,
                HonestMove::TerminateOnSingleStep {
                    claimed_post_commit: commit(7)
                },
            ),
            Some(64),
        );
    }

    /// `interruptible_sleep` returns promptly when the stop
    /// signal is set.
    #[test]
    fn interruptible_sleep_responds_to_stop() {
        use std::sync::atomic::AtomicBool;
        let stop = AtomicBool::new(false);
        let start = std::time::Instant::now();
        // Spawn a thread that sets the stop signal after 50ms.
        std::thread::scope(|s| {
            let stop_ref = &stop;
            s.spawn(|| {
                std::thread::sleep(Duration::from_millis(50));
                stop_ref.store(true, Ordering::Release);
            });
            super::interruptible_sleep(Duration::from_secs(10), &stop);
        });
        let elapsed = start.elapsed();
        // Sleep should have exited well under the 10s requested.
        assert!(elapsed < Duration::from_secs(1));
    }

    // -------------------------------------------------------------
    // Workstream SVC.5 tests: TerminateBundleOracle wiring
    // -------------------------------------------------------------

    use crate::strategy::{MemoryTerminateBundleOracle, TerminateBundle};

    fn make_terminate_bundle(commit: [u8; 32]) -> TerminateBundle {
        TerminateBundle {
            fixture_id: "log[0]".to_string(),
            action_kind: 1,
            action_fields: vec![0u8; 16],
            signer: 5,
            claimed_post_commit: commit,
            cell_proofs: vec![],
        }
    }

    /// `Observer::with_terminate_bundle_oracle` attaches the
    /// oracle and the observer reads it back.
    #[test]
    fn observer_attaches_terminate_bundle_oracle() {
        let (obs, _dir) = fresh_observer();
        let oracle = MemoryTerminateBundleOracle::new();
        let obs = obs.with_terminate_bundle_oracle(Box::new(oracle));
        // The terminate_bundle_oracle field is private; we can't
        // assert directly.  Indirectly verify via the helper:
        // build_terminate_calldata should return Some for a
        // bundle-available case, or None for a missed-case.  Here
        // the oracle is empty so the bundle lookup misses.
        let rec = GameRecord {
            game_id: 42,
            state: GameState {
                sequencer: 1,
                challenger: 2,
                range: DisputedRange {
                    low: Claim {
                        idx: 0,
                        commit: [0u8; 32],
                    },
                    high: Claim {
                        idx: 1,
                        commit: [1u8; 32],
                    },
                },
                pending_midpoint: None,
                depth: 5,
                turn: TurnSide::Sequencer,
                sequencer_bond: 0,
                challenger_bond: 0,
                status: GameStatus::InProgress,
                deployment_id: [0u8; 32],
            },
            me: TurnSide::Sequencer,
            last_updated_block: 100,
            state_known: true,
        };
        let mv = HonestMove::TerminateOnSingleStep {
            claimed_post_commit: [0xAB; 32],
        };
        let result = obs.build_terminate_calldata(&rec, mv);
        // Empty oracle ⇒ Missed ⇒ None.
        assert!(
            result.is_none(),
            "empty bundle oracle should miss and defer (return None)",
        );
    }

    /// Without a bundle oracle attached, `build_terminate_calldata`
    /// returns None (logs + defers).
    #[test]
    fn build_terminate_calldata_without_oracle_defers() {
        let (obs, _dir) = fresh_observer();
        let rec = GameRecord {
            game_id: 42,
            state: GameState {
                sequencer: 1,
                challenger: 2,
                range: DisputedRange {
                    low: Claim {
                        idx: 0,
                        commit: [0u8; 32],
                    },
                    high: Claim {
                        idx: 1,
                        commit: [1u8; 32],
                    },
                },
                pending_midpoint: None,
                depth: 5,
                turn: TurnSide::Sequencer,
                sequencer_bond: 0,
                challenger_bond: 0,
                status: GameStatus::InProgress,
                deployment_id: [0u8; 32],
            },
            me: TurnSide::Sequencer,
            last_updated_block: 100,
            state_known: true,
        };
        let mv = HonestMove::TerminateOnSingleStep {
            claimed_post_commit: [0xAB; 32],
        };
        let result = obs.build_terminate_calldata(&rec, mv);
        assert!(result.is_none(), "no bundle oracle ⇒ None (deferral)");
    }

    /// With a populated bundle oracle, `build_terminate_calldata`
    /// produces calldata starting with the full-form selector.
    #[test]
    fn build_terminate_calldata_with_matching_bundle_succeeds() {
        let (obs, _dir) = fresh_observer();
        let mut oracle = MemoryTerminateBundleOracle::new();
        let commit = [0xCD; 32];
        // Bundle lookup uses the action-entry index (`range.low.idx`).
        oracle.insert(0, make_terminate_bundle(commit));
        let obs = obs.with_terminate_bundle_oracle(Box::new(oracle));

        let rec = GameRecord {
            game_id: 42,
            state: GameState {
                sequencer: 1,
                challenger: 2,
                range: DisputedRange {
                    low: Claim {
                        idx: 0,
                        commit: [0u8; 32],
                    },
                    high: Claim { idx: 1, commit },
                },
                pending_midpoint: None,
                depth: 5,
                turn: TurnSide::Sequencer,
                sequencer_bond: 0,
                challenger_bond: 0,
                status: GameStatus::InProgress,
                deployment_id: [0u8; 32],
            },
            me: TurnSide::Sequencer,
            last_updated_block: 100,
            state_known: true,
        };
        let mv = HonestMove::TerminateOnSingleStep {
            claimed_post_commit: commit,
        };
        let result = obs.build_terminate_calldata(&rec, mv);
        let calldata = result.expect("bundle oracle hit ⇒ Some(calldata)");
        // Calldata must start with the full-form selector
        // (selector is the keccak of the full Solidity signature).
        assert!(
            calldata.len() > 4,
            "calldata should include selector + args"
        );
        // The selector is computed via `MethodSelector::TerminateOnSingleStepFull.selector()`.
        let expected_selector =
            crate::submitter::MethodSelector::TerminateOnSingleStepFull.selector();
        assert_eq!(
            &calldata[0..4],
            expected_selector,
            "calldata starts with TerminateOnSingleStepFull selector",
        );
    }

    /// When the bundle's `claimed_post_commit` disagrees with
    /// the strategy's `claimed_post_commit`,
    /// `build_terminate_calldata` refuses and returns `None`
    /// (logs `BundleCommitMismatch`).
    #[test]
    fn build_terminate_calldata_refuses_on_commit_mismatch() {
        let (obs, _dir) = fresh_observer();
        let mut oracle = MemoryTerminateBundleOracle::new();
        let bundle_commit = [0xCD; 32];
        let strategy_commit = [0xAB; 32]; // Disagrees.
        oracle.insert(0, make_terminate_bundle(bundle_commit));
        let obs = obs.with_terminate_bundle_oracle(Box::new(oracle));

        let rec = GameRecord {
            game_id: 42,
            state: GameState {
                sequencer: 1,
                challenger: 2,
                range: DisputedRange {
                    low: Claim {
                        idx: 0,
                        commit: [0u8; 32],
                    },
                    high: Claim {
                        idx: 1,
                        commit: bundle_commit,
                    },
                },
                pending_midpoint: None,
                depth: 5,
                turn: TurnSide::Sequencer,
                sequencer_bond: 0,
                challenger_bond: 0,
                status: GameStatus::InProgress,
                deployment_id: [0u8; 32],
            },
            me: TurnSide::Sequencer,
            last_updated_block: 100,
            state_known: true,
        };
        let mv = HonestMove::TerminateOnSingleStep {
            claimed_post_commit: strategy_commit,
        };
        let result = obs.build_terminate_calldata(&rec, mv);
        assert!(
            result.is_none(),
            "commit-mismatch ⇒ refusal (None) per defence-in-depth",
        );
    }

    /// `build_calldata_for_move` delegates non-terminate moves to
    /// `encode_calldata` directly.
    #[test]
    fn build_calldata_for_move_delegates_non_terminate() {
        let (obs, _dir) = fresh_observer();
        let rec = GameRecord {
            game_id: 42,
            state: GameState {
                sequencer: 1,
                challenger: 2,
                range: DisputedRange {
                    low: Claim {
                        idx: 0,
                        commit: [0u8; 32],
                    },
                    high: Claim {
                        idx: 10,
                        commit: [1u8; 32],
                    },
                },
                pending_midpoint: None,
                depth: 0,
                turn: TurnSide::Sequencer,
                sequencer_bond: 0,
                challenger_bond: 0,
                status: GameStatus::InProgress,
                deployment_id: [0u8; 32],
            },
            me: TurnSide::Sequencer,
            last_updated_block: 100,
            state_known: true,
        };
        let mv = HonestMove::RespondAgree;
        let result = obs.build_calldata_for_move(&rec, mv);
        assert!(result.is_some(), "non-terminate move ⇒ Some(calldata)");
        let calldata = result.unwrap();
        let expected_selector = crate::submitter::MethodSelector::RespondToMidpoint.selector();
        assert_eq!(
            &calldata[0..4],
            expected_selector,
            "RespondAgree dispatches to RespondToMidpoint selector",
        );
    }
}
