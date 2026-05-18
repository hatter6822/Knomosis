// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

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
//! (canon-host, canon-l1-ingest, canon-event-subscribe,
//! canon-indexer).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::sleep;
use std::time::Duration;

use canon_l1_ingest::source::L1Source;
use tracing::{debug, error, info, warn};

use crate::error::ObserverError;
use crate::events::GameEvent;
use crate::game::{
    apply_settlement, apply_transition, Claim, DisputedRange, GameState, GameStatus,
    GameTransition, TurnSide,
};
use crate::persistence::{GameRecord, PersistBatch, Persistence, ResponseRecord, ResponseStatus};
use crate::strategy::{compute_next_move, HonestMove, HonestMoveError, TruthOracle};
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
pub struct Observer<S: L1Source, Sub: Submitter, T: TruthOracle> {
    config: ObserverConfig,
    watcher: Watcher<S>,
    persistence: Persistence,
    submitter: Sub,
    oracle: T,
    games: HashMap<u128, GameRecord>,
    /// In-memory cache of `(game_id, pivot_idx)` pairs the
    /// observer has already submitted a response for.  Populated
    /// at startup from the persisted response records; updated
    /// atomically with each `commit_batch`.  Replaces the
    /// previous O(N)-per-call `list_responses` scan with a
    /// constant-time lookup, defending against unbounded growth
    /// over the daemon's lifetime.
    submitted_pivots: std::collections::HashSet<(u128, Option<u64>)>,
    /// Stop signal — when `true`, the run loop exits cleanly.
    stop: Arc<AtomicBool>,
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
            ObserverError::Storage(canon_storage::storage::StorageError::Other(e.to_string()))
        })?;
        watcher.set_last_confirmed(cursor);
        // Restore in-memory game map.
        let game_records = persistence.list_games().map_err(|e| {
            ObserverError::Storage(canon_storage::storage::StorageError::Other(e.to_string()))
        })?;
        let mut games = HashMap::new();
        for rec in game_records {
            games.insert(rec.game_id, rec);
        }
        // Populate the in-memory pivot-dedup cache from the
        // persisted response records.  This is the O(N) cost
        // paid once at startup; subsequent dedup checks are O(1).
        let response_records = persistence.list_responses().map_err(|e| {
            ObserverError::Storage(canon_storage::storage::StorageError::Other(e.to_string()))
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
            games,
            submitted_pivots,
            stop: Arc::new(AtomicBool::new(false)),
        })
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
        self.watcher.set_last_confirmed(Some(block));
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
    /// # Returns
    ///
    /// `Ok(true)` if the game was found and updated; `Ok(false)`
    /// if the game id is unknown (no-op).
    ///
    /// # Errors
    ///
    /// Returns [`ObserverError::Storage`] if the persistence
    /// commit fails.
    pub fn mark_state_known(
        &mut self,
        game_id: u128,
        full_state: GameState,
        block_number: u64,
    ) -> Result<bool, ObserverError> {
        let Some(rec) = self.games.get(&game_id).cloned() else {
            return Ok(false);
        };
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
            ObserverError::Storage(canon_storage::storage::StorageError::Other(e.to_string()))
        })?;
        info!(
            game_id = %game_id,
            block_number = block_number,
            "game state_known transitioned to true via mark_state_known",
        );
        Ok(true)
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
        }
        if !batch.is_empty() {
            self.persistence.commit_batch(&batch).map_err(|e| {
                ObserverError::Storage(canon_storage::storage::StorageError::Other(e.to_string()))
            })?;
            debug!(
                games = batch.games.len(),
                responses = batch.responses.len(),
                cursor = ?batch.cursor,
                "batch committed",
            );
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
            new_rec.state.depth = new_rec.state.depth.saturating_add(1);
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
        let calldata = match encode_calldata(rec.game_id, mv) {
            Ok(c) => c,
            Err(crate::submitter::SubmitError::TerminateNotImplemented) => {
                // The full-form terminate calldata builder is
                // deferred RH-G follow-up work.  Loudly log so
                // the operator knows the observer cannot finish
                // the game without intervention.
                error!(
                    game_id = %rec.game_id,
                    pivot_idx = ?pivot_for_move(&rec.state, mv),
                    "TerminateOnSingleStep calldata builder is RH-G follow-up work; \
                     operator must manually submit the full-form transaction or \
                     wait for the canon subprocess pipeline to land",
                );
                return Ok(Some(false));
            }
            Err(e) => {
                error!(
                    game_id = %rec.game_id,
                    err = %e,
                    "calldata encoding failed; deferring move",
                );
                return Ok(Some(false));
            }
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
        match self.submitter.submit(&calldata) {
            Ok(tx_hash) => {
                let resp = ResponseRecord {
                    tx_hash_hex: hex::encode(tx_hash),
                    game_id: rec.game_id,
                    status: ResponseStatus::Pending,
                    submitted_at_block: block_number,
                    depth: rec.state.depth,
                    pivot_idx,
                };
                batch.upsert_response(resp);
                // Insert into the in-memory pivot-dedup cache
                // immediately so a subsequent move within the
                // same iteration cannot duplicate-submit.
                // Persistence is committed atomically at the end
                // of `run_iteration`; on commit failure the
                // in-memory cache will be slightly ahead of the
                // persisted store until the next restart, which
                // is benign (we'd just over-defer on the next
                // iteration, never under-defer).
                self.submitted_pivots.insert((rec.game_id, pivot_idx));
                info!(
                    game_id = %rec.game_id,
                    move_kind = ?mv,
                    tx_hash = %hex::encode(tx_hash),
                    "submitted honest move",
                );
                Ok(Some(true))
            }
            Err(e) => {
                error!(
                    game_id = %rec.game_id,
                    err = %e,
                    "submission failed; retry on next iteration",
                );
                Ok(Some(false))
            }
        }
    }

    /// Check whether we've already submitted a response for the
    /// given (`game_id`, `pivot_idx`) pair.  Used by the
    /// deduplication discipline.  Constant-time lookup against
    /// the in-memory cache, populated at startup from persisted
    /// response records.
    fn has_submitted_for_pivot(&self, game_id: u128, pivot_idx: Option<u64>) -> bool {
        self.submitted_pivots.contains(&(game_id, pivot_idx))
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
                        canon_cli_common::exit::OperatorExitCode::Transient
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
    use crate::events::{GameEvent, GameEventTopic};
    use crate::game::{Claim, DisputedRange, GameState, GameStatus, StateCommit, TurnSide};
    use crate::persistence::{
        GameRecord, PersistBatch, Persistence, ResponseRecord, ResponseStatus,
    };
    use crate::strategy::MemoryTruthOracle;
    use crate::submitter::mock::MockSubmitter;
    use crate::watcher::WatcherConfig;
    use canon_l1_ingest::action::EthAddress;
    use canon_l1_ingest::events::{RawLog, TopicHash};
    use canon_l1_ingest::reorg::BlockHeader;
    use canon_l1_ingest::source::mock::InMemoryL1Source;
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
            deployment_id: [0xDE; 32],
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
}
