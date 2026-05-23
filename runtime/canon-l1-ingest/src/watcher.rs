// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Top-level orchestrator for the L1 ingestor.
//!
//! ## The watcher loop
//!
//! Each iteration:
//!
//!   1. Query [`L1Source::latest_block_number`] to find the
//!      chain head.
//!   2. Compute `confirmed_head = head - confirmation_depth`.
//!   3. For each block number in `(last_confirmed,
//!      confirmed_head]`:
//!      a. Fetch the block header and feed it to the re-org
//!         window.  Halts with `WatcherError::Reorg` if the
//!         re-org exceeds the window.
//!      b. Fetch the logs from `bridge_contract` and
//!         `identity_registry_contract` in that block, BY HASH
//!         (defends against re-orgs racing the header→logs
//!         fetch sequence).
//!      c. Decode each log via `events::decode_event`.  Skip
//!         non-Knomosis logs.
//!      d. For each `IngestedEvent`, dedup via the forwarded
//!         set.  If new, *peek* the translation via
//!         `translation::preview_ingest` (does NOT mutate the
//!         book), sign via the keystore, submit via the
//!         submitter.  ON SUCCESS, persist one atomic
//!         `Submitted` JSONL record and apply the in-memory
//!         mutations (book + nonce + forwarded set).
//!      e. Append a `Confirmed` record to the state store.
//!   4. Optionally sleep `poll_interval` before the next iteration.
//!
//! ## State-mutation discipline
//!
//! The `Submitted` record is the load-bearing atomicity boundary
//! for post-submit mutations.  Three pre-fix-era discoveries
//! motivate the design:
//!
//!   * **Address-book corruption**: eagerly mutating the book in
//!     `ingest` left it in a half-updated state if submission
//!     failed.  On retry, the watcher emitted `ReplaceKey`
//!     instead of `RegisterIdentity`.  Fixed by switching to
//!     `preview_ingest` + `commit_assignment`.
//!   * **Nonce desync**: reconstructing `next_nonce` from
//!     `forwarded.len()` over-counted by the number of
//!     `None`-translating events (`Revoked`, `DepositInitiated`).
//!     Fixed by writing an explicit nonce record (now folded
//!     into `Submitted`).
//!   * **Multi-record write tearing**: writing
//!     `AddressAssigned`, `NonceProgressed`, `Forwarded` as
//!     three separate JSONL lines created a partial-failure
//!     window between writes.  Fixed by consolidating into one
//!     `Submitted` line.
//!
//! ## Where this is callable
//!
//! The watcher is exposed as both:
//!
//!   * `WatcherLoop::run_until` — synchronous; runs until a
//!     fatal error or until `until_block` is reached.  Used by
//!     `main.rs` (the binary).
//!   * `WatcherLoop::run_iteration` — runs exactly one
//!     iteration.  Used by tests to drive the loop synthetically.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::sleep;
use std::time::Duration;

use sha3::{Digest, Keccak256};
use tracing::{debug, error, info, warn};

use crate::action::{EthAddress, Nonce};
use crate::address_book::AddressBook;
use crate::encoding::{signing_input, EncodeError};
use crate::events::{decode_event, DecodeError, IngestedEvent};
use crate::key::{BridgeActorKey, KeyError};
use crate::reorg::{AdvanceOutcome, ReorgError, ReorgWindow};
use crate::source::{L1Source, SourceError};
use crate::state::{
    AddressAssignment, ForwardedKey, HexBytes, StateError, StateRecord, StateStore,
};
use crate::submitter::{SignedActionForSubmit, SubmitError, Submitter, Verdict};
use crate::translation::{commit_assignment, preview_ingest, Translated, UnsignedAction};

/// Errors surfaced by the watcher.
#[derive(Debug, thiserror::Error)]
pub enum WatcherError {
    /// Source layer error.
    #[error(transparent)]
    Source(#[from] SourceError),
    /// Re-org-window error.  Some variants (`DeepReorg`,
    /// `OrphanedParent`) are fatal — the operator must
    /// intervene.
    #[error(transparent)]
    Reorg(#[from] ReorgError),
    /// Event-decoder error.
    #[error(transparent)]
    Decode(#[from] DecodeError),
    /// State-store error.
    #[error(transparent)]
    State(#[from] StateError),
    /// Action-encoder error.
    #[error(transparent)]
    Encode(#[from] EncodeError),
    /// Keystore / signer error.
    #[error(transparent)]
    Key(#[from] KeyError),
    /// Submitter error.
    #[error(transparent)]
    Submit(#[from] SubmitError),
    /// Configuration error — surfaced from `Self::new`.
    #[error("configuration error: {0}")]
    Config(String),
}

/// Configuration the watcher loop consumes.
#[derive(Clone, Debug)]
pub struct WatcherConfig {
    /// The bridge contract address whose logs we filter for
    /// `DepositInitiated`.
    pub bridge_contract: EthAddress,
    /// The identity-registry contract address whose logs we
    /// filter for `RegisteredECDSA` / `RegisteredEIP1271` /
    /// `Revoked`.
    pub identity_registry_contract: EthAddress,
    /// L1 confirmation depth.  Events are only processed after
    /// reaching this many blocks of confirmation.  Default 12
    /// per `knomosis-cli-common::paths::DEFAULT_L1_CONFIRMATION_DEPTH`.
    pub confirmation_depth: u32,
    /// Re-org-window capacity.  Recommended ≥ confirmation_depth
    /// + 1.  Defaults to `confirmation_depth + 4` for headroom.
    pub reorg_window_capacity: usize,
    /// Polling interval between iterations.  Default 12s
    /// (Ethereum mainnet block time).
    pub poll_interval: Duration,
    /// Canonical deployment id supplied at signing time.
    /// Threaded through the `signing_input` function so produced
    /// signatures bind to a specific Knomosis deployment.
    pub deployment_id: Vec<u8>,
    /// Maximum number of blocks the watcher processes per
    /// iteration before yielding.  Prevents a long historical
    /// catch-up from starving the rest of the daemon.  Default 64.
    pub blocks_per_iteration: u32,
}

impl WatcherConfig {
    /// Construct a config with the documented defaults.
    #[must_use]
    pub fn new(
        bridge_contract: EthAddress,
        identity_registry_contract: EthAddress,
        deployment_id: Vec<u8>,
    ) -> Self {
        let confirmation_depth = canon_cli_common::paths::DEFAULT_L1_CONFIRMATION_DEPTH;
        Self {
            bridge_contract,
            identity_registry_contract,
            confirmation_depth,
            reorg_window_capacity: (confirmation_depth as usize) + 4,
            poll_interval: Duration::from_secs(12),
            deployment_id,
            blocks_per_iteration: 64,
        }
    }
}

/// The watcher orchestrator.  Owns the in-memory state, the
/// keystore, the source, the submitter, and the state store.
pub struct WatcherLoop<S: L1Source, B: Submitter> {
    config: WatcherConfig,
    source: S,
    submitter: B,
    key: BridgeActorKey,
    state_store: StateStore,
    address_book: AddressBook,
    forwarded: std::collections::HashSet<ForwardedKey>,
    reorg_window: ReorgWindow,
    last_confirmed_block: Option<u64>,
    /// The signer's next-expected nonce.  Persisted indirectly
    /// via the address book + counter; incremented per
    /// successful submission.  Starts at `0` on a fresh
    /// daemon; resumes from `state.next_nonce` on restart.
    next_nonce: Nonce,
}

impl<S: L1Source, B: Submitter> WatcherLoop<S, B> {
    /// Construct a watcher.  Opens the state file at `state_path`
    /// (creating it if absent) and rebuilds the in-memory state
    /// from any pre-existing records.
    ///
    /// # Errors
    ///
    /// Returns `WatcherError::State` if the state file cannot be
    /// opened or rebuilt.  Returns `WatcherError::Config` if the
    /// `reorg_window_capacity` is 0.
    pub fn new(
        config: WatcherConfig,
        source: S,
        submitter: B,
        key: BridgeActorKey,
        state_path: &std::path::Path,
    ) -> Result<Self, WatcherError> {
        if config.reorg_window_capacity == 0 {
            return Err(WatcherError::Config(
                "reorg_window_capacity must be > 0".into(),
            ));
        }
        let (state_store, state) = StateStore::open(state_path)?;
        // Reconstruct nonce from the persisted
        // `NonceProgressed` records.  This is intentionally NOT
        // `state.forwarded.len()`: forwarded includes `None`-
        // returning events (`Revoked`, `DepositInitiated`) that
        // never produce a signed action, so using the forwarded
        // count would over-count and cause `NotAdmissible` on
        // the next submission.
        let next_nonce = state.next_nonce;
        let reorg_window = ReorgWindow::new(config.reorg_window_capacity);
        // No prior block headers in state (RH-B doesn't persist
        // them yet; RH-E.0 will).  Window starts empty; the
        // first advance call seeds it.
        Ok(Self {
            config,
            source,
            submitter,
            key,
            state_store,
            address_book: state.address_book,
            forwarded: state.forwarded,
            reorg_window,
            last_confirmed_block: state.last_confirmed_block,
            next_nonce,
        })
    }

    /// Read accessor for the configuration.
    #[must_use]
    pub fn config(&self) -> &WatcherConfig {
        &self.config
    }

    /// Read accessor for the last confirmed block.
    #[must_use]
    pub fn last_confirmed_block(&self) -> Option<u64> {
        self.last_confirmed_block
    }

    /// Read accessor for the current address book.
    #[must_use]
    pub fn address_book(&self) -> &AddressBook {
        &self.address_book
    }

    /// Read accessor for the forwarded-events set size.
    #[must_use]
    pub fn forwarded_count(&self) -> usize {
        self.forwarded.len()
    }

    /// Read accessor for the next nonce.
    #[must_use]
    pub fn next_nonce(&self) -> Nonce {
        self.next_nonce
    }

    /// Read accessor for the underlying submitter.  Useful for
    /// integration tests that inject a `BufferingSubmitter` to
    /// observe submitted actions.  Production code SHOULD NOT
    /// rely on this — the watcher is the only authorised
    /// caller of `submitter.submit`.
    #[must_use]
    pub fn submitter(&self) -> &B {
        &self.submitter
    }

    /// Run a single watcher iteration.  Returns the number of
    /// blocks processed.
    ///
    /// # Errors
    ///
    /// See [`WatcherError`].  In particular, `WatcherError::Reorg`
    /// with `DeepReorg` / `OrphanedParent` is a fatal error
    /// requiring operator intervention.
    pub fn run_iteration(&mut self) -> Result<u64, WatcherError> {
        let head = self.source.latest_block_number()?;
        let confirmation_depth = u64::from(self.config.confirmation_depth);
        if head < confirmation_depth {
            // Not enough chain confirmation depth yet; wait.
            debug!(
                head = head,
                confirmation_depth = confirmation_depth,
                "chain head below confirmation depth; nothing to do"
            );
            return Ok(0);
        }
        let confirmed_head = head - confirmation_depth;
        // Saturating add: if `last_confirmed_block == Some(u64::MAX)`
        // we'd otherwise overflow.  Saturating to `u64::MAX`
        // makes the subsequent `start_block > confirmed_head`
        // gate fire and we return early — preventing both a
        // debug-mode panic and a release-mode wrap that would
        // catastrophically restart from genesis.
        let start_block = match self.last_confirmed_block {
            None => 0,
            Some(b) => b.saturating_add(1),
        };
        if start_block > confirmed_head {
            // Already up to date.
            return Ok(0);
        }
        // `confirmed_head >= start_block` was just established,
        // so `confirmed_head - start_block` is non-negative.
        // The `+ 1` could in principle overflow if
        // `confirmed_head == u64::MAX` and `start_block == 0`
        // (i.e. the entire u64 range to process in one iteration).
        // Saturate at `u64::MAX`.
        let available_blocks = (confirmed_head - start_block).saturating_add(1);
        let configured_batch = u64::from(self.config.blocks_per_iteration);
        // Reject the degenerate `blocks_per_iteration == 0`
        // configuration: with zero blocks per iteration the
        // watcher would loop forever without making progress.
        // Return early; the operator's logs will show no
        // forward motion.
        if configured_batch == 0 {
            warn!("blocks_per_iteration is 0; watcher cannot make progress");
            return Ok(0);
        }
        let blocks_to_process = std::cmp::min(available_blocks, configured_batch);
        // `blocks_to_process >= 1` here, so `- 1` is safe.
        let end_block = start_block + (blocks_to_process - 1);
        let mut processed = 0u64;
        for block_number in start_block..=end_block {
            self.process_block(block_number)?;
            self.state_store
                .append(&StateRecord::Confirmed { block_number })?;
            self.last_confirmed_block = Some(block_number);
            processed += 1;
        }
        Ok(processed)
    }

    /// Run iterations until the watcher reaches `until_block`,
    /// receives a stop signal via `stop`, or hits a fatal error.
    /// Returns the total blocks processed.
    ///
    /// # Errors
    ///
    /// See [`WatcherError`].
    pub fn run_until(
        &mut self,
        until_block: u64,
        stop: Arc<AtomicBool>,
    ) -> Result<u64, WatcherError> {
        let mut total = 0u64;
        loop {
            if stop.load(Ordering::Relaxed) {
                info!("watcher received stop signal; exiting");
                break;
            }
            if self
                .last_confirmed_block
                .map_or(false, |b| b >= until_block)
            {
                info!(
                    last_confirmed = self.last_confirmed_block,
                    until_block = until_block,
                    "watcher reached target block; exiting"
                );
                break;
            }
            let processed = match self.run_iteration() {
                Ok(n) => n,
                Err(WatcherError::Reorg(ref e))
                    if matches!(
                        e,
                        ReorgError::DeepReorg { .. } | ReorgError::OrphanedParent { .. }
                    ) =>
                {
                    error!(error = %e, "deep re-org detected; halting for operator intervention");
                    return Err(e.clone().into());
                }
                Err(WatcherError::Submit(SubmitError::NotAdmissible)) => {
                    error!("downstream consumer rejected as not admissible; halting");
                    return Err(WatcherError::Submit(SubmitError::NotAdmissible));
                }
                Err(WatcherError::Submit(SubmitError::ParseError)) => {
                    error!("downstream consumer returned parse error; halting");
                    return Err(WatcherError::Submit(SubmitError::ParseError));
                }
                Err(e) => return Err(e),
            };
            // Saturate at `u64::MAX` to avoid an arithmetic
            // overflow if the watcher runs long enough to process
            // u64::MAX blocks (unrealistic but the bound is free).
            total = total.saturating_add(processed);
            if processed == 0 {
                sleep(self.config.poll_interval);
            }
        }
        Ok(total)
    }

    /// Process a single block: fetch its header, advance the
    /// re-org window, fetch logs from both contracts, decode,
    /// translate, sign, submit.
    fn process_block(&mut self, block_number: u64) -> Result<(), WatcherError> {
        // 1. Fetch block header and feed re-org window.
        let header = self.source.block_header_by_number(block_number)?;
        // The first block we see seeds the window without re-org
        // checks; subsequent blocks advance and detect re-orgs.
        let outcome = if self.reorg_window.is_empty() {
            // Seed: push directly.
            self.reorg_window.seed(std::iter::once(header));
            AdvanceOutcome::Advanced
        } else {
            self.reorg_window.advance(header)?
        };
        match outcome {
            AdvanceOutcome::Advanced => {
                debug!(block = block_number, "block advanced linearly");
            }
            AdvanceOutcome::Reorged {
                dropped_count,
                dropped_from_number,
            } => {
                warn!(
                    block = block_number,
                    dropped = dropped_count,
                    dropped_from = dropped_from_number,
                    "shallow re-org absorbed by sliding window"
                );
            }
        }
        // 2. Fetch logs from both contracts, BY BLOCK HASH
        //    rather than by number.  This defends against a
        //    mid-iteration re-org: if the chain forks between
        //    `block_header_by_number` and `logs_in_block_by_hash`,
        //    the by-hash query resolves to "no such block" and
        //    we surface a typed error rather than processing
        //    wrong-fork logs.
        let mut all_logs = self
            .source
            .logs_in_block_by_hash(&header.hash, &self.config.bridge_contract)?;
        // If the operator points both contract flags at the
        // same address (a test / single-contract deployment
        // pattern), skip the second RPC call — it would just
        // return the same logs and our process_event idempotency
        // layer would dedup them.  Saves one round-trip and
        // halves the log-decode work.
        if self.config.bridge_contract != self.config.identity_registry_contract {
            all_logs.extend(
                self.source
                    .logs_in_block_by_hash(&header.hash, &self.config.identity_registry_contract)?,
            );
        }
        // Sort by log index for determinism.
        all_logs.sort_by_key(|l| l.log_index);
        // 3. Decode and process each log.
        for log in all_logs {
            let event = match decode_event(&log) {
                Ok(Some(e)) => e,
                Ok(None) => continue,
                Err(e) => {
                    // Decode errors halt the watcher: a Knomosis
                    // event signature matched but the payload
                    // was malformed.  The operator must
                    // diagnose.
                    error!(error = %e, "event decode failed; halting");
                    return Err(e.into());
                }
            };
            self.process_event(event, header.hash)?;
        }
        Ok(())
    }

    /// Process a single decoded event.
    ///
    /// Ordering discipline (critical for resilience to mid-
    /// submission failures):
    ///
    ///   1. Idempotency check via the forwarded-key set.
    ///   2. **Peek-only** translation via `preview_ingest`
    ///      (does NOT mutate the address book).
    ///   3. For `NoAction` events: insert the dedup key
    ///      in-memory, persist a legacy `Forwarded` record,
    ///      return.
    ///   4. Sign and submit.
    ///   5. On submit success:
    ///      a. Persist the ATOMIC `Submitted` JSONL record
    ///         carrying the new nonce + optional address
    ///         assignment + dedup key in a single line write.
    ///      b. Commit the in-memory address-book mutation (if
    ///         the translation produced one).  Overflow here is
    ///         operator-actionable.
    ///      c. Bump the in-memory `next_nonce`.
    ///      d. Insert the dedup key into the in-memory
    ///         `forwarded` set.
    ///
    /// Step 5a's atomic single-line write is the load-bearing
    /// integrity boundary.  A crash between 5a and 5d leaves
    /// the disk consistent: replay re-applies all of 5b/c/d
    /// from the persisted Submitted record.  A crash BEFORE 5a
    /// leaves the disk untouched; the event is re-processed
    /// on restart.  The BOOK is only mutated AFTER submit
    /// succeeds — so a failed submit doesn't poison the next
    /// retry's translation.
    fn process_event(
        &mut self,
        event: IngestedEvent,
        block_hash: crate::events::TopicHash,
    ) -> Result<(), WatcherError> {
        let (_block_number, tx_hash, log_index) = event.origin_key();
        // Idempotency: skip events already forwarded.
        let key = ForwardedKey {
            block_hash,
            tx_hash,
            log_index,
        };
        if self.forwarded.contains(&key) {
            debug!(
                tx = ?tx_hash,
                log_index = log_index,
                "event already forwarded; skipping"
            );
            return Ok(());
        }
        // Peek-only translation: does NOT mutate the address book.
        let translated = preview_ingest(&self.address_book, &event, self.next_nonce);
        let (unsigned, pending_assignment) = match translated {
            Translated::NoAction => {
                // No Knomosis-side action: persist `Forwarded` for
                // idempotency and return.
                debug!(
                    variant = event.variant_name(),
                    "event translates to no Action; skipping"
                );
                self.forwarded.insert(key);
                self.state_store.append(&StateRecord::Forwarded {
                    block_hash: HexBytes(block_hash.to_vec()),
                    tx_hash: HexBytes(tx_hash.to_vec()),
                    log_index,
                })?;
                return Ok(());
            }
            Translated::Emit(u) => (u, None),
            Translated::EmitWithAssignment {
                action,
                address,
                new_actor_id,
            } => (action, Some((address, new_actor_id))),
        };
        // Sign and submit BEFORE persisting any state mutations.
        let signed = self.sign(unsigned)?;
        info!(
            signer = signed.unsigned.signer,
            nonce = signed.unsigned.nonce,
            tag = signed.unsigned.action.tag(),
            "submitting signed action"
        );
        let mut retries = 0u32;
        let max_retries = 16u32;
        let mut backoff_ms = 100u64;
        loop {
            match self.submitter.submit(&signed) {
                Ok(Verdict::Ok) => break,
                Ok(Verdict::Busy) => {
                    if retries >= max_retries {
                        error!("submitter busy beyond retry budget; halting");
                        return Err(WatcherError::Submit(SubmitError::Transport(
                            "exceeded retry budget on Busy verdict".into(),
                        )));
                    }
                    warn!(
                        backoff_ms = backoff_ms,
                        retry = retries,
                        "submitter busy; backing off"
                    );
                    sleep(Duration::from_millis(backoff_ms));
                    backoff_ms = backoff_ms.saturating_mul(2).min(60_000);
                    retries += 1;
                }
                Ok(Verdict::NotAdmissible) => {
                    // The built-in submitters (`BufferingSubmitter`,
                    // `HttpSubmitter`) wrap NotAdmissible as
                    // `Err(SubmitError::NotAdmissible)`, but a
                    // custom `Submitter` impl is free to return
                    // it as `Ok` (the trait contract allows it).
                    // Map to the semantically-correct error.
                    return Err(WatcherError::Submit(SubmitError::NotAdmissible));
                }
                Ok(Verdict::ParseError) => {
                    return Err(WatcherError::Submit(SubmitError::ParseError));
                }
                Err(e) => return Err(e.into()),
            }
        }
        // SUBMIT SUCCEEDED.  Commit state mutations atomically
        // via a single `Submitted` JSONL record.  Using one
        // record (rather than the previous three-record
        // sequence) eliminates the partial-failure window where
        // a mid-sequence write error left the watcher's nonce
        // counter and dedup set out of sync.
        let new_next_nonce = self.next_nonce.saturating_add(1);
        let assigned = pending_assignment.map(|(address, actor_id)| AddressAssignment {
            address: HexBytes(address.as_bytes().to_vec()),
            actor_id,
        });
        // 1. Persist the atomic post-submit record.
        self.state_store.append(&StateRecord::Submitted {
            block_hash: HexBytes(block_hash.to_vec()),
            tx_hash: HexBytes(tx_hash.to_vec()),
            log_index,
            next_nonce: new_next_nonce,
            assigned: assigned.clone(),
        })?;
        // 2. Apply in-memory mutations after the durable write.
        //    If commit_assignment fails (overflow OR expected-id
        //    mismatch), the on-disk `Submitted` record has
        //    already been persisted with the previewed id, but
        //    the in-memory book wasn't updated to match.  On
        //    restart, replay re-runs the assignment from the
        //    state file (via `try_assign`, which returns the
        //    same overflow error path).  The realistic-workload
        //    assumption is that overflow never happens; the
        //    typed error is defence-in-depth.
        //
        //    The expected-id-mismatch case indicates either a
        //    concurrent modification of the watcher's address
        //    book (the watcher is single-threaded, so this is a
        //    programming bug) or a `preview`-without-`commit`
        //    sequence that left the book unmutated and the
        //    monotone counter pointed at a different id than
        //    the preview expected.  Either way, surface as an
        //    operator-action error.
        if let Some((address, new_actor_id)) = pending_assignment {
            commit_assignment(&mut self.address_book, &address, new_actor_id)
                .map_err(|e| WatcherError::Config(format!("address-book commit failed: {e}")))?;
        }
        self.next_nonce = new_next_nonce;
        self.forwarded.insert(key);
        Ok(())
    }

    /// Sign an unsigned action via the bridge-actor keystore.
    fn sign(&self, unsigned: UnsignedAction) -> Result<SignedActionForSubmit, WatcherError> {
        let signing_bytes = signing_input(
            &unsigned.action,
            unsigned.signer,
            unsigned.nonce,
            &self.config.deployment_id,
        )?;
        // Pre-hash via keccak256 (matches the cross-stack contract
        // with `knomosis-verify-secp256k1`).
        let mut hasher = Keccak256::new();
        hasher.update(&signing_bytes);
        let prehash = hasher.finalize();
        let signature = self.key.sign_prehash(&prehash)?;
        Ok(SignedActionForSubmit {
            unsigned,
            signature,
        })
    }
}

/// `ReorgError` is `Clone` for the watcher's purposes (returned
/// inside `WatcherError::Reorg`).
impl Clone for ReorgError {
    fn clone(&self) -> Self {
        match self {
            Self::DeepReorg {
                incoming_number,
                window_floor,
            } => Self::DeepReorg {
                incoming_number: *incoming_number,
                window_floor: *window_floor,
            },
            Self::OrphanedParent { incoming_number } => Self::OrphanedParent {
                incoming_number: *incoming_number,
            },
            Self::NonMonotone {
                incoming_number,
                last_seen,
            } => Self::NonMonotone {
                incoming_number: *incoming_number,
                last_seen: *last_seen,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    use super::{WatcherConfig, WatcherLoop};
    use crate::action::EthAddress;
    use crate::events::{EventTopic, RawLog};
    use crate::key::BridgeActorKey;
    use crate::reorg::BlockHeader;
    use crate::source::mock::InMemoryL1Source;
    use crate::submitter::buffering::BufferingSubmitter;
    use crate::submitter::Verdict;

    /// Shared-state submitter wrapper used by the idempotency
    /// test to thread one `BufferingSubmitter` across two
    /// successive watcher constructions.
    struct SharedSubmitter(std::sync::Arc<BufferingSubmitter>);
    impl crate::submitter::Submitter for SharedSubmitter {
        fn submit(
            &self,
            signed: &crate::submitter::SignedActionForSubmit,
        ) -> Result<crate::submitter::Verdict, crate::submitter::SubmitError> {
            self.0.submit(signed)
        }
    }

    /// The well-known contract addresses used by tests.
    fn bridge_addr() -> EthAddress {
        EthAddress::from_bytes(&[0xb1; 20]).unwrap()
    }
    fn identity_addr() -> EthAddress {
        EthAddress::from_bytes(&[0x1d; 20]).unwrap()
    }

    /// Build a known-good bridge actor key.
    fn test_key() -> BridgeActorKey {
        let mut scalar = [0u8; 32];
        scalar[31] = 42;
        BridgeActorKey::from_private_bytes(&scalar).unwrap()
    }

    /// Construct a synthesised RegisteredECDSA log.
    fn build_registered_ecdsa_log(
        actor: [u8; 20],
        pubkey: &[u8],
        block_number: u64,
        log_index: u64,
        tx_hash: [u8; 32],
    ) -> RawLog {
        let mut actor_topic = [0u8; 32];
        actor_topic[12..32].copy_from_slice(&actor);
        // ABI-encode the bytes field: offset header + length + payload.
        let mut data = Vec::new();
        // offset = 32 (one slot)
        let mut off = [0u8; 32];
        off[31] = 32;
        data.extend_from_slice(&off);
        // length
        let mut len_be = [0u8; 32];
        let len = pubkey.len() as u64;
        len_be[24..32].copy_from_slice(&len.to_be_bytes());
        data.extend_from_slice(&len_be);
        // payload, padded to 32-byte alignment
        data.extend_from_slice(pubkey);
        let padding = (32 - (pubkey.len() % 32)) % 32;
        data.extend_from_slice(&vec![0u8; padding]);
        RawLog {
            address: identity_addr(),
            topics: vec![EventTopic::RegisteredEcdsa.hash(), actor_topic],
            data,
            block_number,
            tx_hash,
            log_index,
        }
    }

    /// Smoke test: empty source, no blocks to process.
    #[test]
    fn empty_source_no_blocks() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let source = InMemoryL1Source::new();
        let submitter = BufferingSubmitter::new();
        let config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        let processed = watcher.run_iteration().unwrap();
        assert_eq!(processed, 0);
        assert_eq!(watcher.last_confirmed_block(), None);
    }

    /// Confirmation-depth gate: head below depth processes nothing.
    #[test]
    fn confirmation_depth_holds_back() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        for n in 0..5 {
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                HashMap::new(),
            );
        }
        let submitter = BufferingSubmitter::new();
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12; // higher than chain head
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        let processed = watcher.run_iteration().unwrap();
        assert_eq!(processed, 0);
    }

    /// Happy-path: a single RegisteredECDSA event yields a
    /// RegisterIdentity submission.
    #[test]
    fn first_registration_submits_register_identity() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        // Build a chain: 0 (genesis) .. 12 (confirmation depth target).
        for n in 0..=12 {
            let mut logs_map = HashMap::new();
            if n == 0 {
                // Place the registration event at block 0.
                logs_map.insert(
                    identity_addr(),
                    vec![build_registered_ecdsa_log(
                        [0xaa; 20],
                        &[0x02, 0xab, 0xcd],
                        0,
                        0,
                        [0x77; 32],
                    )],
                );
            }
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                logs_map,
            );
        }
        let submitter = BufferingSubmitter::new();
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        // Run a single iteration; should process at least block 0.
        let processed = watcher.run_iteration().unwrap();
        // confirmed_head = head - confirmation_depth = 12 - 12 = 0.
        // start_block = 0, end_block = 0.  One block processed.
        assert_eq!(processed, 1);
        assert_eq!(watcher.last_confirmed_block(), Some(0));
        // The submitter recorded one action.
        let recorded = watcher.submitter.recorded();
        assert_eq!(recorded.len(), 1);
        match &recorded[0].unsigned.action {
            crate::action::Action::RegisterIdentity { actor, pk } => {
                assert_eq!(*actor, 1);
                assert_eq!(pk.as_bytes(), &[0x02, 0xab, 0xcd]);
            }
            _ => panic!("expected RegisterIdentity"),
        }
        // Watcher's nonce was bumped.
        assert_eq!(watcher.next_nonce(), 1);
        // Address book has one entry.
        assert_eq!(watcher.address_book().len(), 1);
    }

    /// Idempotency: re-running over the same event does not
    /// produce a duplicate submission.
    #[test]
    fn idempotency_drops_duplicates() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        for n in 0..=12 {
            let mut logs_map = HashMap::new();
            if n == 0 {
                logs_map.insert(
                    identity_addr(),
                    vec![build_registered_ecdsa_log(
                        [0xaa; 20],
                        &[0x02, 0xab],
                        0,
                        0,
                        [0x77; 32],
                    )],
                );
            }
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                logs_map,
            );
        }
        let submitter_inner = std::sync::Arc::new(BufferingSubmitter::new());
        let submitter = SharedSubmitter(submitter_inner.clone());
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        {
            let mut watcher = WatcherLoop::new(
                config.clone(),
                source.clone(),
                submitter,
                test_key(),
                &state_path,
            )
            .unwrap();
            watcher.run_iteration().unwrap();
        }
        let count_after_first = submitter_inner.len();
        assert_eq!(count_after_first, 1);
        // Reopen the watcher (simulating restart).
        let submitter2 = SharedSubmitter(submitter_inner.clone());
        let mut watcher2 =
            WatcherLoop::new(config, source, submitter2, test_key(), &state_path).unwrap();
        // Last_confirmed_block was persisted, so the watcher
        // doesn't re-process.
        let processed = watcher2.run_iteration().unwrap();
        assert_eq!(processed, 0);
        assert_eq!(submitter_inner.len(), 1, "no duplicate submission");
        assert_eq!(watcher2.last_confirmed_block(), Some(0));
        // Address-book state survived the restart.  The
        // `Submitted` record persisted the (addr, id=1)
        // assignment; replay rebuilt it.
        let addr = EthAddress::from_bytes(&[0xaa; 20]).unwrap();
        assert_eq!(watcher2.address_book().lookup(&addr), Some(1));
        // Nonce was bumped (the `RegisterIdentity` submission
        // bumped nonce from 0 to 1).
        assert_eq!(watcher2.next_nonce(), 1);
    }

    /// Backpressure: submitter returns Busy then Ok; the watcher
    /// retries.
    #[test]
    fn backpressure_retries_on_busy() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        for n in 0..=12 {
            let mut logs_map = HashMap::new();
            if n == 0 {
                logs_map.insert(
                    identity_addr(),
                    vec![build_registered_ecdsa_log(
                        [0xaa; 20],
                        &[0x02, 0xab],
                        0,
                        0,
                        [0x77; 32],
                    )],
                );
            }
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                logs_map,
            );
        }
        let submitter = BufferingSubmitter::new();
        submitter.set_responses(vec![Verdict::Busy, Verdict::Busy, Verdict::Ok]);
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        let processed = watcher.run_iteration().unwrap();
        assert_eq!(processed, 1);
        // 3 attempts: 2 busies + 1 ok.
        assert_eq!(watcher.submitter.len(), 3);
    }

    /// Halt-on-NotAdmissible: the watcher returns the typed
    /// error and does not silently skip.
    #[test]
    fn halts_on_not_admissible() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        for n in 0..=12 {
            let mut logs_map = HashMap::new();
            if n == 0 {
                logs_map.insert(
                    identity_addr(),
                    vec![build_registered_ecdsa_log(
                        [0xaa; 20],
                        &[0x02, 0xab],
                        0,
                        0,
                        [0x77; 32],
                    )],
                );
            }
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                logs_map,
            );
        }
        let submitter = BufferingSubmitter::new();
        submitter.set_responses(vec![Verdict::NotAdmissible]);
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        let result = watcher.run_iteration();
        assert!(matches!(
            result,
            Err(super::WatcherError::Submit(
                crate::submitter::SubmitError::NotAdmissible
            ))
        ));
    }

    /// `run_until` exits cleanly when the stop signal is set.
    #[test]
    fn run_until_respects_stop_signal() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let source = InMemoryL1Source::new();
        let submitter = BufferingSubmitter::new();
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        // Set a very short poll interval so the sleep is brief.
        config.poll_interval = std::time::Duration::from_millis(10);
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        let stop = Arc::new(AtomicBool::new(true)); // already stopped
        let result = watcher.run_until(100, stop).unwrap();
        assert_eq!(result, 0);
    }

    /// Revoked events do not produce a submission but ARE
    /// recorded in `forwarded` for idempotency.
    #[test]
    fn revoked_records_forwarded_no_submission() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        // Build a Revoked log at block 0.
        let mut actor_topic = [0u8; 32];
        actor_topic[12..32].copy_from_slice(&[0x42u8; 20]);
        let revoke_log = RawLog {
            address: identity_addr(),
            topics: vec![EventTopic::Revoked.hash(), actor_topic],
            data: vec![],
            block_number: 0,
            tx_hash: [0xee; 32],
            log_index: 0,
        };
        for n in 0..=12 {
            let mut logs_map = HashMap::new();
            if n == 0 {
                logs_map.insert(identity_addr(), vec![revoke_log.clone()]);
            }
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                logs_map,
            );
        }
        let submitter = BufferingSubmitter::new();
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        watcher.run_iteration().unwrap();
        assert!(watcher.submitter.is_empty(), "Revoked emits no submission");
        // Forwarded set has the record.
        assert_eq!(watcher.forwarded_count(), 1);
    }

    /// REGRESSION: a `Revoked` event recorded as `Forwarded`
    /// does NOT bump `next_nonce`.  This is the load-bearing
    /// fix for the nonce-desync bug where the watcher
    /// reconstructed `next_nonce` from `forwarded.len()` at
    /// startup, over-counting by the number of `Revoked` /
    /// `DepositInitiated` events.
    #[test]
    fn revoked_event_does_not_bump_nonce() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        // Build a Revoked log at block 0.
        let mut actor_topic = [0u8; 32];
        actor_topic[12..32].copy_from_slice(&[0x42u8; 20]);
        let revoke_log = RawLog {
            address: identity_addr(),
            topics: vec![EventTopic::Revoked.hash(), actor_topic],
            data: vec![],
            block_number: 0,
            tx_hash: [0xee; 32],
            log_index: 0,
        };
        for n in 0..=12u64 {
            let mut logs_map = HashMap::new();
            if n == 0 {
                logs_map.insert(identity_addr(), vec![revoke_log.clone()]);
            }
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                logs_map,
            );
        }
        let submitter = BufferingSubmitter::new();
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        watcher.run_iteration().unwrap();
        // Revoked: forwarded recorded, but nonce NOT bumped.
        assert_eq!(watcher.forwarded_count(), 1);
        assert_eq!(
            watcher.next_nonce(),
            0,
            "Revoked event must NOT bump next_nonce"
        );
    }

    /// REGRESSION: after a failed submit, retrying the same
    /// event must still emit `RegisterIdentity` (not
    /// `ReplaceKey`).  This is the state-corruption fix: the
    /// address book must NOT be mutated until submission
    /// succeeds.
    #[test]
    fn failed_submit_does_not_corrupt_address_book() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        let log =
            build_registered_ecdsa_log([0x55; 20], &[0x02, 0xab, 0xcd, 0xef], 0, 0, [0x77; 32]);
        for n in 0..=12u64 {
            let mut logs_map = HashMap::new();
            if n == 0 {
                logs_map.insert(identity_addr(), vec![log.clone()]);
            }
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                logs_map,
            );
        }
        // First attempt: submitter reports NotAdmissible.
        // Watcher should halt and leave book unmutated.
        {
            let submitter = BufferingSubmitter::new();
            submitter.set_responses(vec![Verdict::NotAdmissible]);
            let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
            config.confirmation_depth = 12;
            let mut watcher =
                WatcherLoop::new(config, source.clone(), submitter, test_key(), &state_path)
                    .unwrap();
            let result = watcher.run_iteration();
            assert!(result.is_err());
            // Book was NOT mutated in this watcher instance.
            assert!(
                watcher.address_book().is_empty(),
                "address book must remain empty after a failed submit"
            );
        }
        // Now retry with a fresh watcher (simulating restart).
        // The state file should NOT contain an `AddressAssigned`
        // record (because submit failed).  The new watcher
        // re-processes the event and emits `RegisterIdentity`.
        {
            let submitter = BufferingSubmitter::new();
            submitter.set_responses(vec![Verdict::Ok]);
            let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
            config.confirmation_depth = 12;
            let mut watcher =
                WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
            // Initial state: no prior assignment.
            assert!(
                watcher.address_book().is_empty(),
                "on restart, address book must be empty (no prior commit)"
            );
            watcher.run_iteration().unwrap();
            // After successful submit: book has the new id.
            assert_eq!(watcher.address_book().len(), 1);
            let recorded = watcher.submitter.recorded();
            assert_eq!(recorded.len(), 1);
            match &recorded[0].unsigned.action {
                crate::action::Action::RegisterIdentity { actor, .. } => {
                    assert_eq!(
                        *actor, 1,
                        "retry must emit fresh RegisterIdentity, NOT ReplaceKey"
                    );
                }
                other => panic!("expected RegisterIdentity after retry, got {other:?}"),
            }
        }
    }

    /// State file integrity: each successful submission writes
    /// exactly one atomic `Submitted` record (replacing the
    /// previous three-record `AddressAssigned` +
    /// `NonceProgressed` + `Forwarded` sequence).
    #[test]
    fn state_records_use_atomic_submitted_record() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        let log = build_registered_ecdsa_log([0x66; 20], &[0x02, 0xab], 0, 0, [0x88; 32]);
        for n in 0..=12u64 {
            let mut logs_map = HashMap::new();
            if n == 0 {
                logs_map.insert(identity_addr(), vec![log.clone()]);
            }
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                logs_map,
            );
        }
        let submitter = BufferingSubmitter::new();
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        watcher.run_iteration().unwrap();
        // Read the state file.  Successful event produced
        // exactly one `Submitted` line; block 0 then produced a
        // `Confirmed` line.  No legacy multi-record sequence.
        let contents = std::fs::read_to_string(&state_path).unwrap();
        let lines: Vec<&str> = contents.lines().filter(|l| !l.trim().is_empty()).collect();
        let submitted_count = lines
            .iter()
            .filter(|l| l.contains("\"event\":\"submitted\""))
            .count();
        let confirmed_count = lines
            .iter()
            .filter(|l| l.contains("\"event\":\"confirmed\""))
            .count();
        let legacy_count = lines
            .iter()
            .filter(|l| {
                l.contains("\"event\":\"address_assigned\"")
                    || l.contains("\"event\":\"nonce_progressed\"")
                    || l.contains("\"event\":\"forwarded\"")
            })
            .count();
        assert_eq!(submitted_count, 1, "expected exactly one Submitted record");
        assert_eq!(confirmed_count, 1, "expected exactly one Confirmed record");
        assert_eq!(
            legacy_count, 0,
            "new writes must not use the legacy multi-record format"
        );
        // The Submitted record must carry the assignment for a
        // RegisterIdentity path.
        let submitted_line = lines
            .iter()
            .find(|l| l.contains("\"event\":\"submitted\""))
            .expect("Submitted line present");
        assert!(
            submitted_line.contains("\"assigned\""),
            "Submitted record must include assigned field for RegisterIdentity"
        );
    }

    /// REGRESSION: `blocks_per_iteration == 0` would previously
    /// cause `end_block = start_block - 1` (underflow / panic
    /// in debug, wrap in release).  The fix returns Ok(0) with
    /// a warning.
    #[test]
    fn blocks_per_iteration_zero_does_not_underflow() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        for n in 0..=12u64 {
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                HashMap::new(),
            );
        }
        let submitter = BufferingSubmitter::new();
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        config.blocks_per_iteration = 0; // pathological config
        let mut watcher =
            WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        // Must NOT panic.  Should return 0 (no progress).
        let processed = watcher.run_iteration().unwrap();
        assert_eq!(processed, 0);
    }

    /// REGRESSION: `last_confirmed_block == Some(u64::MAX)`
    /// would previously cause `start_block = MAX + 1` (panic
    /// in debug, wrap to 0 → catastrophic re-processing from
    /// genesis in release).  The saturating add prevents both
    /// and the early-return gate keeps the watcher quiet.
    #[test]
    fn last_confirmed_block_at_u64_max_does_not_wrap() {
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let source = InMemoryL1Source::new();
        let submitter = BufferingSubmitter::new();
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        let watcher = WatcherLoop::new(config, source, submitter, test_key(), &state_path).unwrap();
        // Force last_confirmed_block to u64::MAX.  This is a
        // test-only manipulation simulating an extreme
        // resume-from-state scenario.  We don't expose a
        // setter, so we use the state-file path: write a
        // `Confirmed { block_number: u64::MAX }` record.
        // Actually that's even more direct.
        let confirmed_path = &state_path;
        let line = serde_json::to_string(&crate::state::StateRecord::Confirmed {
            block_number: u64::MAX,
        })
        .unwrap();
        std::fs::write(confirmed_path, format!("{line}\n")).unwrap();
        // Re-open the watcher.
        let source2 = InMemoryL1Source::new();
        let submitter2 = BufferingSubmitter::new();
        let mut config2 = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config2.confirmation_depth = 12;
        let mut watcher2 =
            WatcherLoop::new(config2, source2, submitter2, test_key(), &state_path).unwrap();
        assert_eq!(watcher2.last_confirmed_block(), Some(u64::MAX));
        // Run iteration: must NOT panic, must NOT wrap.
        let processed = watcher2.run_iteration().unwrap();
        assert_eq!(processed, 0);
        // last_confirmed_block unchanged.
        assert_eq!(watcher2.last_confirmed_block(), Some(u64::MAX));
        let _ = watcher; // silence unused
    }

    /// REGRESSION: a `Submitter` that returns
    /// `Ok(Verdict::NotAdmissible)` (rather than the
    /// trait-canonical `Err(SubmitError::NotAdmissible)`) is
    /// correctly translated to `WatcherError::Submit(NotAdmissible)`.
    #[test]
    fn ok_not_admissible_verdict_maps_to_submit_error() {
        struct OkNotAdmissibleSubmitter;
        impl crate::submitter::Submitter for OkNotAdmissibleSubmitter {
            fn submit(
                &self,
                _signed: &crate::submitter::SignedActionForSubmit,
            ) -> Result<crate::submitter::Verdict, crate::submitter::SubmitError> {
                // Trait-legal: return NotAdmissible as Ok.
                Ok(crate::submitter::Verdict::NotAdmissible)
            }
        }
        let temp = tempfile::tempdir().unwrap();
        let state_path = temp.path().join("state.jsonl");
        let mut source = InMemoryL1Source::new();
        let log = build_registered_ecdsa_log([0x55; 20], &[0x02, 0xab], 0, 0, [0x77; 32]);
        for n in 0..=12u64 {
            let mut logs_map = HashMap::new();
            if n == 0 {
                logs_map.insert(identity_addr(), vec![log.clone()]);
            }
            source.push_block(
                BlockHeader {
                    number: n,
                    hash: [n as u8; 32],
                    parent_hash: if n == 0 { [0; 32] } else { [(n - 1) as u8; 32] },
                },
                logs_map,
            );
        }
        let mut config = WatcherConfig::new(bridge_addr(), identity_addr(), vec![]);
        config.confirmation_depth = 12;
        let mut watcher = WatcherLoop::new(
            config,
            source,
            OkNotAdmissibleSubmitter,
            test_key(),
            &state_path,
        )
        .unwrap();
        let result = watcher.run_iteration();
        match result {
            Err(crate::watcher::WatcherError::Submit(
                crate::submitter::SubmitError::NotAdmissible,
            )) => {} // expected
            other => panic!("expected Submit(NotAdmissible), got {other:?}"),
        }
    }
}
