// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Indexer orchestration: dispatch events to the balance view +
//! the GP.6.4 budget / pool tables + advance the cursor atomically
//! via a single `SqliteCombinedTransaction` block.
//!
//! ## What changed in GP.6.4 v2.0
//!
//! Previously (v1) the indexer's `apply_batch` opened a kv-only
//! `Storage::transaction` and the budget views lived in
//! kv-keyspace prefixes (`u/`, `pe/`, `pb/`) inside the same kv
//! table.  v2.0 switches to FIVE physical SQLite tables (created
//! by `migration_002_budget_views`) and uses
//! `CombinedTransactionOps` so the kv operations (balance +
//! cursor) AND the budget-table operations commit atomically
//! together inside a single `BEGIN IMMEDIATE ... COMMIT` block.
//!
//! ## Dispatch table
//!
//! For each incoming `Event`, the indexer applies the following
//! per-view updates:
//!
//! **Balance view (kv `b/` keyspace, unchanged from v1):**
//!
//! | Tag | Constructor               | Balance-view effect                                |
//! |-----|---------------------------|----------------------------------------------------|
//! | 0   | `BalanceChanged`          | `set(actor, resource, new_value)` (authoritative)  |
//! | 8   | `RewardIssued`            | `credit(recipient, resource, amount)` if no `BalanceChanged` |
//! | 9   | `WithdrawalRequested`     | `debit(sender, resource, amount)` if no `BalanceChanged`    |
//! | 10  | `DepositCredited`         | `credit(recipient, resource, amount)` if no `BalanceChanged`|
//! | All other tags            | no-op (balance view unaffected)                        |
//!
//! **GP.6.4 budget / pool view (5 physical SQLite tables):**
//!
//! See [`crate::budget_view`]'s docstring for the per-tag
//! dispatch.  Briefly: tags 16/17/19 credit budget grants
//! (lifetime + current-epoch); tag 18 drains the pool view if
//! `--gas-pool-actor` is configured; tag 20 (GP.6.4) credits
//! current-epoch consumption.
//!
//! ## Atomicity
//!
//! Each event-batch (one log frame's worth of events, all
//! sharing the same seq) is applied inside a single
//! `SqliteCombinedTransaction`.  The transaction's last operation
//! is the cursor advance.  On commit, every balance update + the
//! budget-table updates + the cursor advance become visible
//! atomically.  On any per-event error, the transaction is rolled
//! back and the entire batch is discarded — the cursor does NOT
//! advance, and the indexer's next subscribe will re-deliver the
//! failing batch.
//!
//! ## Idempotency
//!
//! On startup, the indexer reads the cursor and subscribes with
//! `resume_from = cursor`.  The wire protocol guarantees that the
//! server then sends every event with `seq > cursor`.  If the
//! indexer crashes mid-batch, the cursor reflects the last
//! committed batch's seq; on restart, the server replays from
//! that seq.

use std::collections::HashSet;

use knomosis_storage::combined_transaction::{
    CombinedStorage, CombinedTransactionError, CombinedTransactionOps,
};
use knomosis_storage::storage::Storage;

use crate::balance::{BalanceError, BALANCE_KEY_LEN, BALANCE_KEY_PREFIX, BALANCE_VALUE_LEN};
use crate::budget_view::{dispatch_epoch_if_crossed, dispatch_event, BudgetDispatchError};
use crate::cursor::{ensure_identifier, read_cursor, CursorError, CURSOR_KEY, CURSOR_VALUE_LEN};
use crate::decoder::{amount_from_be_bytes, amount_to_be_bytes, DecodeError};
use crate::event::{ActorId, Amount, Event, ResourceId};
use crate::INDEXER_IDENTIFIER;

/// Maximum number of events allowed in a single `apply_batch`
/// call.  Defence-in-depth bound mirroring
/// `knomosis-event-subscribe::extract::HARD_MAX_EVENT_COUNT`.
pub const INDEXER_MAX_BATCH_EVENTS: usize = 1024;

/// Indexer-level errors.
#[derive(Debug, thiserror::Error)]
pub enum IndexerError {
    /// Storage error (open / read / write / commit).
    #[error("storage error: {0}")]
    Storage(#[from] knomosis_storage::storage::StorageError),
    /// Balance-view error (overflow / underflow / corrupt cell).
    #[error("balance error: {0}")]
    Balance(#[from] BalanceError),
    /// Budget-view dispatch error (overflow / underflow / corrupt
    /// cell from the GP.6.4 budget tables).  Distinct from
    /// [`IndexerError::Balance`] so an operator can tell which
    /// view's invariant failed.
    #[error("budget-view error: {0}")]
    BudgetView(#[from] BudgetDispatchError),
    /// Cursor error (non-monotone / corrupt cell / identifier
    /// mismatch).
    #[error("cursor error: {0}")]
    Cursor(#[from] CursorError),
    /// CBE decoder error.
    #[error("decoder error at seq {seq}: {source}")]
    Decode {
        /// The event sequence number whose payload failed.
        seq: u64,
        /// The underlying decoder error.
        #[source]
        source: DecodeError,
    },
    /// The event batch is empty.
    #[error("empty event batch")]
    EmptyBatch,
    /// The event batch exceeds [`INDEXER_MAX_BATCH_EVENTS`].
    #[error("batch too large: {size} events > {max}")]
    BatchTooLarge {
        /// The offending batch size.
        size: usize,
        /// The configured maximum.
        max: usize,
    },
    /// The event's seq is at or before the cursor.
    #[error("stale event seq {seq} (cursor at {cursor})")]
    StaleEvent {
        /// The event's seq.
        seq: u64,
        /// Current cursor value.
        cursor: u64,
    },
    /// Wire protocol delivered events out of order.
    #[error(
        "protocol violation: out-of-order seq (current {current_seq}, received {offending_seq})"
    )]
    ProtocolViolation {
        /// The current seq the indexer was accumulating.
        current_seq: u64,
        /// The offending seq.
        offending_seq: u64,
    },
    /// `tx.commit()` reported an error but the SQLite-level state
    /// may have partially succeeded; the in-memory cursor was
    /// reloaded from disk.  Recoverable.
    #[error("commit ambiguous at seq {seq} (disk cursor after reload: {disk_cursor})")]
    CommitAmbiguous {
        /// The seq being committed.
        seq: u64,
        /// The disk cursor value AFTER reload from storage.
        disk_cursor: u64,
    },
    /// `tx.commit()` AND the disk-cursor reload BOTH failed.
    /// Unrecoverable; the indexer poisons itself.
    #[error(
        "cursor recovery failed at seq {seq} (commit error: {commit_error}; cursor read error: {cursor_error})"
    )]
    CursorRecoveryFailed {
        /// The seq being committed.
        seq: u64,
        /// The original commit error.
        commit_error: String,
        /// The cursor-read error.
        cursor_error: String,
    },
    /// The indexer is poisoned from a previous CursorRecoveryFailed.
    #[error("indexer poisoned by a previous cursor-recovery failure; restart required")]
    Poisoned,
}

/// Indexer-side accessors that the apply path needs:
///   * `Storage` for startup reads (cursor + identifier).
///   * `CombinedStorage` for atomic kv + budget tx during
///     `apply_batch`.
pub trait IndexerStorage: Storage + CombinedStorage {}
impl<T: Storage + CombinedStorage + ?Sized> IndexerStorage for T {}

/// An indexer instance backed by a storage that supports BOTH
/// kv operations (via [`Storage`]) AND combined kv + budget
/// transactions (via [`CombinedStorage`]).  The production impl
/// is `SqliteStorage`; tests can use fault-injecting adaptors.
///
/// Construct via [`Indexer::open`] (default config: no
/// `--gas-pool-actor`, no `--epoch-length`) or
/// [`Indexer::open_with_config`] (explicit config).
pub struct Indexer<'a, S: IndexerStorage + ?Sized> {
    storage: &'a S,
    /// Last-committed cursor value, mirrored in memory.
    cursor: u64,
    /// Poisoned by a previous `CursorRecoveryFailed`; subsequent
    /// `apply_batch` calls reject with [`IndexerError::Poisoned`].
    poisoned: bool,
    /// GP.6.4: `--gas-pool-actor` config.  When `Some(p)`,
    /// `Event.gasPoolClaim` debits `pool_balances_{eth,bold}[p]`.
    /// When `None`, GasPoolClaim is a no-op (gross-inflow pool
    /// view).
    gas_pool_actor: Option<ActorId>,
    /// GP.6.4: `--epoch-length` config.  When > 0, the indexer
    /// resets the per-epoch tables every `epoch_length` seqs.
    /// When 0, epoch advancement is disabled.
    epoch_length: u64,
}

impl<S: IndexerStorage + ?Sized> std::fmt::Debug for Indexer<'_, S> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Indexer")
            .field("cursor", &self.cursor)
            .field("poisoned", &self.poisoned)
            .field("gas_pool_actor", &self.gas_pool_actor)
            .field("epoch_length", &self.epoch_length)
            .finish_non_exhaustive()
    }
}

impl<'a, S: IndexerStorage + ?Sized> Indexer<'a, S> {
    /// Open an indexer over `storage` with default GP.6.4
    /// config (no `--gas-pool-actor`, no `--epoch-length`).
    /// See [`Self::open_with_config`] for explicit-config
    /// construction.
    ///
    /// # Errors
    ///
    /// See [`IndexerError`].
    pub fn open(storage: &'a S) -> Result<Self, IndexerError> {
        Self::open_with_config(storage, None, 0)
    }

    /// Open an indexer with explicit GP.6.4 configuration:
    ///   * `gas_pool_actor`: `Some(p)` enables drain wiring on
    ///     `Event.gasPoolClaim` (decrements
    ///     `pool_balances_{eth,bold}[p]`); `None` preserves
    ///     gross-inflow pool semantics.
    ///   * `epoch_length`: `> 0` triggers per-epoch table resets
    ///     every `epoch_length` seqs; `0` disables.
    ///
    /// # Errors
    ///
    /// See [`IndexerError`].
    pub fn open_with_config(
        storage: &'a S,
        gas_pool_actor: Option<ActorId>,
        epoch_length: u64,
    ) -> Result<Self, IndexerError> {
        ensure_identifier(storage, INDEXER_IDENTIFIER)?;
        let cursor = read_cursor(storage)?;
        tracing::info!(
            cursor,
            identifier = INDEXER_IDENTIFIER,
            ?gas_pool_actor,
            epoch_length,
            "indexer opened (GP.6.4 v2.0)"
        );
        Ok(Self {
            storage,
            cursor,
            poisoned: false,
            gas_pool_actor,
            epoch_length,
        })
    }

    /// `true` if a previous `apply_batch` cascade-failed.
    #[must_use]
    pub fn is_poisoned(&self) -> bool {
        self.poisoned
    }

    /// Current cursor value (last-committed seq).
    #[must_use]
    pub fn cursor(&self) -> u64 {
        self.cursor
    }

    /// Configured `--gas-pool-actor`.  See
    /// [`Self::open_with_config`].
    #[must_use]
    pub fn gas_pool_actor(&self) -> Option<ActorId> {
        self.gas_pool_actor
    }

    /// Configured `--epoch-length`.  See
    /// [`Self::open_with_config`].
    #[must_use]
    pub fn epoch_length(&self) -> u64 {
        self.epoch_length
    }

    /// Apply a batch of events that share the same seq.  Atomic
    /// commit: balance view + budget tables + cursor advance go
    /// in one `SqliteCombinedTransaction`.
    ///
    /// # Errors
    ///
    /// See [`IndexerError`].
    pub fn apply_batch(&mut self, seq: u64, events: &[Event]) -> Result<(), IndexerError> {
        if self.poisoned {
            return Err(IndexerError::Poisoned);
        }
        if events.is_empty() {
            return Err(IndexerError::EmptyBatch);
        }
        if events.len() > INDEXER_MAX_BATCH_EVENTS {
            return Err(IndexerError::BatchTooLarge {
                size: events.len(),
                max: INDEXER_MAX_BATCH_EVENTS,
            });
        }
        if seq <= self.cursor {
            return Err(IndexerError::StaleEvent {
                seq,
                cursor: self.cursor,
            });
        }

        // Pre-compute (actor, resource) pairs covered by
        // BalanceChanged in this batch (semantic events for the
        // same pair are skipped to avoid double-counting; see
        // the "BalanceChanged-overrides-semantic" rule).
        let bc_pairs: HashSet<(ActorId, ResourceId)> = events
            .iter()
            .filter_map(|e| match e {
                Event::BalanceChanged {
                    actor, resource, ..
                } => Some((*actor, *resource)),
                _ => None,
            })
            .collect();

        // Open the SINGLE combined transaction.
        let mut tx = self.storage.begin_combined_tx().map_err(map_combined_err)?;

        // ----- Pass 0 (GP.6.4): epoch boundary check -----
        // Reset per-epoch tables if seq crosses an epoch boundary
        // (BEFORE per-event dispatch so the dispatch loop credits
        // into the freshly-reset tables).
        dispatch_epoch_if_crossed(&mut *tx, seq, self.epoch_length)?;

        // ----- Pass 1 (balance semantic events) -----
        // Apply RewardIssued / WithdrawalRequested / DepositCredited
        // where (actor, resource) is NOT covered by a BalanceChanged.
        for event in events {
            apply_balance_semantic_event(&mut *tx, event, &bc_pairs)?;
        }

        // ----- Pass 2 (balance authoritative `set`s) -----
        // Apply BalanceChanged events as authoritative `set`s.
        for event in events {
            if let Event::BalanceChanged {
                resource,
                actor,
                new_value,
                ..
            } = event
            {
                balance_set(&mut *tx, *actor, *resource, *new_value)?;
            }
        }

        // ----- Pass 3 (GP.6.4 budget / pool dispatch) -----
        // Dispatch GP-family events (tags 16/17/19/20) to the
        // budget tables; tag 18 drains the pool if configured.
        for event in events {
            dispatch_event(&mut *tx, event, self.gas_pool_actor)?;
        }

        // ----- Pass 4 (cursor advance) -----
        // Cursor advance is the last operation inside the tx.
        // On failure, the entire batch rolls back.
        advance_cursor_via_combined(&mut *tx, self.cursor, seq)?;

        // Commit.  On commit failure, re-sync the in-memory
        // cursor with disk (matching the v1 recovery discipline).
        match tx.commit() {
            Ok(()) => {
                self.cursor = seq;
                Ok(())
            }
            Err(commit_err) => match read_cursor(self.storage) {
                Ok(disk_cursor) => {
                    self.cursor = disk_cursor;
                    if disk_cursor >= seq {
                        Err(IndexerError::CommitAmbiguous { seq, disk_cursor })
                    } else {
                        Err(map_combined_err(commit_err))
                    }
                }
                Err(cursor_err) => {
                    self.poisoned = true;
                    Err(IndexerError::CursorRecoveryFailed {
                        seq,
                        commit_error: commit_err.to_string(),
                        cursor_error: cursor_err.to_string(),
                    })
                }
            },
        }
    }

    /// Re-read the on-disk cursor (e.g. after another process
    /// committed).
    ///
    /// # Errors
    ///
    /// See [`CursorError`].
    pub fn reload_cursor(&mut self) -> Result<(), IndexerError> {
        self.cursor = read_cursor(self.storage)?;
        Ok(())
    }
}

/// Apply a semantic event (RewardIssued / WithdrawalRequested /
/// DepositCredited) to the balance view inside a combined
/// transaction, but only if `(actor, resource)` is not covered
/// by a BalanceChanged in the same batch.
fn apply_balance_semantic_event(
    tx: &mut dyn CombinedTransactionOps,
    event: &Event,
    bc_pairs: &HashSet<(ActorId, ResourceId)>,
) -> Result<(), IndexerError> {
    match event {
        Event::WithdrawalRequested {
            resource,
            sender,
            amount,
            ..
        } => {
            if bc_pairs.contains(&(*sender, *resource)) {
                return Ok(());
            }
            balance_debit(tx, *sender, *resource, *amount)?;
        }
        Event::RewardIssued {
            resource,
            recipient,
            amount,
        }
        | Event::DepositCredited {
            resource,
            recipient,
            amount,
            ..
        } => {
            if bc_pairs.contains(&(*recipient, *resource)) {
                return Ok(());
            }
            balance_credit(tx, *recipient, *resource, *amount)?;
        }
        _ => {}
    }
    Ok(())
}

/// Build the canonical balance key.  Mirrors
/// [`crate::balance::balance_key`] inline so the combined-tx
/// path doesn't depend on the keyspace-based BalanceTxView types.
fn balance_key_bytes(actor: ActorId, resource: ResourceId) -> [u8; BALANCE_KEY_LEN] {
    let mut k = [0u8; BALANCE_KEY_LEN];
    k[0..2].copy_from_slice(BALANCE_KEY_PREFIX);
    k[2..10].copy_from_slice(&actor.to_be_bytes());
    k[10..18].copy_from_slice(&resource.to_be_bytes());
    k
}

/// Read a balance cell via the combined tx.  Returns 0 if absent.
fn balance_get(
    tx: &dyn CombinedTransactionOps,
    actor: ActorId,
    resource: ResourceId,
) -> Result<Amount, IndexerError> {
    let key = balance_key_bytes(actor, resource);
    let cell = tx.kv_get(&key).map_err(map_combined_err)?;
    match cell {
        None => Ok(0),
        Some(bytes) if bytes.len() == BALANCE_VALUE_LEN => {
            let mut buf = [0u8; BALANCE_VALUE_LEN];
            buf.copy_from_slice(&bytes);
            Ok(amount_from_be_bytes(&buf))
        }
        Some(bytes) => Err(IndexerError::Balance(BalanceError::CorruptCell {
            actor,
            resource,
            expected: BALANCE_VALUE_LEN,
            actual: bytes.len(),
        })),
    }
}

/// Set a balance cell via the combined tx.
fn balance_set(
    tx: &mut dyn CombinedTransactionOps,
    actor: ActorId,
    resource: ResourceId,
    value: Amount,
) -> Result<(), IndexerError> {
    let key = balance_key_bytes(actor, resource);
    let cell = amount_to_be_bytes(value);
    tx.kv_put(&key, &cell).map_err(map_combined_err)?;
    Ok(())
}

/// Credit a balance cell, halting on overflow (saturates the cell
/// to u128::MAX before returning the error, matching the v1
/// `BalanceTxView::credit` discipline).
fn balance_credit(
    tx: &mut dyn CombinedTransactionOps,
    actor: ActorId,
    resource: ResourceId,
    delta: Amount,
) -> Result<Amount, IndexerError> {
    let current = balance_get(tx, actor, resource)?;
    match current.checked_add(delta) {
        Some(sum) => {
            balance_set(tx, actor, resource, sum)?;
            Ok(sum)
        }
        None => {
            balance_set(tx, actor, resource, Amount::MAX)?;
            Err(IndexerError::Balance(BalanceError::CreditOverflow {
                actor,
                resource,
                delta,
            }))
        }
    }
}

/// Debit a balance cell, halting on underflow.
fn balance_debit(
    tx: &mut dyn CombinedTransactionOps,
    actor: ActorId,
    resource: ResourceId,
    delta: Amount,
) -> Result<Amount, IndexerError> {
    let current = balance_get(tx, actor, resource)?;
    match current.checked_sub(delta) {
        Some(diff) => {
            balance_set(tx, actor, resource, diff)?;
            Ok(diff)
        }
        None => Err(IndexerError::Balance(BalanceError::DebitUnderflow {
            actor,
            resource,
            current,
            delta,
        })),
    }
}

/// Advance the cursor inside the combined tx.  Mirrors
/// [`crate::cursor::advance_cursor_in_tx`] using the combined-tx
/// kv methods.  Returns CursorError on non-monotonic advance or
/// corrupt cell.
fn advance_cursor_via_combined(
    tx: &mut dyn CombinedTransactionOps,
    in_memory_cursor: u64,
    new_value: u64,
) -> Result<(), IndexerError> {
    let cell = tx.kv_get(CURSOR_KEY).map_err(map_combined_err)?;
    let on_disk_cursor: u64 = match cell {
        None => 0,
        Some(bytes) if bytes.len() == CURSOR_VALUE_LEN => {
            let mut buf = [0u8; CURSOR_VALUE_LEN];
            buf.copy_from_slice(&bytes);
            u64::from_be_bytes(buf)
        }
        Some(bytes) => {
            return Err(IndexerError::Cursor(CursorError::CorruptCell {
                expected: CURSOR_VALUE_LEN,
                actual: bytes.len(),
            }));
        }
    };
    // The in-memory cursor should match disk (last-committed
    // value); if not, we have an external writer or a recovery
    // anomaly.  Use the stricter of the two for the monotonicity
    // check.
    let current = on_disk_cursor.max(in_memory_cursor);
    if new_value < current {
        return Err(IndexerError::Cursor(CursorError::NonMonotonicAdvance {
            current,
            attempted: new_value,
        }));
    }
    tx.kv_put(CURSOR_KEY, &new_value.to_be_bytes())
        .map_err(map_combined_err)?;
    Ok(())
}

/// Helper: convert a [`CombinedTransactionError`] into an
/// [`IndexerError`].  Routes Storage errors via
/// `IndexerError::Storage` and Budget errors via
/// `IndexerError::BudgetView`.
fn map_combined_err(e: CombinedTransactionError) -> IndexerError {
    match e {
        CombinedTransactionError::Storage(s) => IndexerError::Storage(s),
        CombinedTransactionError::Budget(b) => {
            IndexerError::BudgetView(CombinedTransactionError::Budget(b))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Indexer, IndexerError, IndexerStorage};
    use crate::balance::BalanceView;
    use crate::budget_view::BudgetReadView;
    use crate::event::{Event, RESOURCE_ID_ETH};
    use knomosis_storage::sqlite::SqliteStorage;
    use knomosis_storage::storage::Storage;

    /// Open a fresh in-memory indexer.
    fn open_indexer() -> (SqliteStorage, ()) {
        let s = SqliteStorage::open_in_memory().unwrap();
        (s, ())
    }

    /// Indexer is constructable + reads cursor 0 from a fresh DB.
    #[test]
    fn open_fresh_db() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let ix = Indexer::open(&s).unwrap();
        assert_eq!(ix.cursor(), 0);
        assert!(!ix.is_poisoned());
        assert_eq!(ix.gas_pool_actor(), None);
        assert_eq!(ix.epoch_length(), 0);
    }

    /// `open_with_config` records the gas_pool_actor + epoch_length.
    #[test]
    fn open_with_config_records_settings() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let ix = Indexer::open_with_config(&s, Some(42), 100).unwrap();
        assert_eq!(ix.gas_pool_actor(), Some(42));
        assert_eq!(ix.epoch_length(), 100);
    }

    /// Reopen preserves the cursor across indexer instances.
    #[test]
    fn reopen_preserves_cursor() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ix.db");
        {
            let s = SqliteStorage::open(&path).unwrap();
            let mut ix = Indexer::open(&s).unwrap();
            let events = vec![Event::BalanceChanged {
                resource: 1,
                actor: 2,
                old_value: 0,
                new_value: 100,
            }];
            ix.apply_batch(1, &events).unwrap();
            assert_eq!(ix.cursor(), 1);
        }
        let s = SqliteStorage::open(&path).unwrap();
        let ix = Indexer::open(&s).unwrap();
        assert_eq!(ix.cursor(), 1);
    }

    /// BalanceChanged sets the balance authoritatively (via
    /// combined tx).
    #[test]
    fn dispatch_balance_changed_combined_tx() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        ix.apply_batch(
            1,
            &[Event::BalanceChanged {
                resource: 1,
                actor: 42,
                old_value: 0,
                new_value: 500,
            }],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(42, 1).unwrap(), 500);
    }

    /// RewardIssued credits the recipient (via combined tx).
    #[test]
    fn dispatch_reward_issued_combined_tx() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        ix.apply_batch(
            1,
            &[Event::RewardIssued {
                resource: 2,
                recipient: 7,
                amount: 100,
            }],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(7, 2).unwrap(), 100);
    }

    /// WithdrawalRequested debits the sender; underflow halts.
    #[test]
    fn dispatch_withdrawal_underflow_halts() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        // Seed actor with 50.
        ix.apply_batch(
            1,
            &[Event::BalanceChanged {
                resource: 1,
                actor: 1,
                old_value: 0,
                new_value: 50,
            }],
        )
        .unwrap();
        // Try withdraw 100 → underflow.
        let result = ix.apply_batch(
            2,
            &[Event::WithdrawalRequested {
                resource: 1,
                sender: 1,
                amount: 100,
                recipient_l1: [0; 20],
                withdrawal_id: 1,
            }],
        );
        assert!(matches!(result, Err(IndexerError::Balance(_))));
        // Cursor stays at 1.
        assert_eq!(ix.cursor(), 1);
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(1, 1).unwrap(), 50);
    }

    /// `apply_batch` rejects an empty batch.
    #[test]
    fn empty_batch_rejected() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        assert!(matches!(
            ix.apply_batch(1, &[]),
            Err(IndexerError::EmptyBatch)
        ));
    }

    /// `apply_batch` rejects a stale seq.
    #[test]
    fn stale_seq_rejected() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        ix.apply_batch(
            5,
            &[Event::BalanceChanged {
                resource: 1,
                actor: 1,
                old_value: 0,
                new_value: 100,
            }],
        )
        .unwrap();
        assert!(matches!(
            ix.apply_batch(
                5,
                &[Event::BalanceChanged {
                    resource: 1,
                    actor: 1,
                    old_value: 0,
                    new_value: 200
                }]
            ),
            Err(IndexerError::StaleEvent { seq: 5, cursor: 5 })
        ));
        assert_eq!(ix.cursor(), 5);
    }

    /// **Audit-regression**: a multi-event batch (transfer-shaped)
    /// applies atomically via the combined tx.
    #[test]
    fn transfer_shaped_batch_atomic() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        ix.apply_batch(
            1,
            &[Event::BalanceChanged {
                resource: 0,
                actor: 1,
                old_value: 0,
                new_value: 500,
            }],
        )
        .unwrap();
        ix.apply_batch(
            2,
            &[
                Event::BalanceChanged {
                    resource: 0,
                    actor: 1,
                    old_value: 500,
                    new_value: 300,
                },
                Event::BalanceChanged {
                    resource: 0,
                    actor: 2,
                    old_value: 0,
                    new_value: 200,
                },
            ],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(1, 0).unwrap(), 300);
        assert_eq!(bv.get(2, 0).unwrap(), 200);
    }

    /// GP.6.4: depositWithFee credits BOTH balance view AND
    /// budget view atomically via the combined tx.
    #[test]
    fn deposit_with_fee_credits_both_views_atomically() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        ix.apply_batch(
            1,
            &[
                Event::BalanceChanged {
                    resource: RESOURCE_ID_ETH,
                    actor: 42,
                    old_value: 0,
                    new_value: 900,
                },
                Event::BalanceChanged {
                    resource: RESOURCE_ID_ETH,
                    actor: 1,
                    old_value: 0,
                    new_value: 100,
                },
                Event::DepositWithFeeCredited {
                    resource: RESOURCE_ID_ETH,
                    recipient: 42,
                    pool_actor: 1,
                    user_amount: 900,
                    pool_amount: 100,
                    budget_grant: 50,
                    deposit_id: 7,
                },
            ],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        let budget = BudgetReadView::new(&s);
        assert_eq!(bv.get(42, RESOURCE_ID_ETH).unwrap(), 900);
        assert_eq!(bv.get(1, RESOURCE_ID_ETH).unwrap(), 100);
        assert_eq!(budget.get_actor_budget(42).unwrap(), 50);
        assert_eq!(
            budget.get_actor_budget_current_epoch_grants(42).unwrap(),
            50
        );
        assert_eq!(budget.get_pool_eth(1).unwrap(), 100);
    }

    /// GP.6.4: BudgetConsumed (tag 20) credits the current-epoch
    /// consumed counter via the combined tx.
    #[test]
    fn budget_consumed_credits_current_epoch_consumed() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        ix.apply_batch(
            1,
            &[Event::BudgetConsumed {
                actor: 42,
                amount: 1,
            }],
        )
        .unwrap();
        let budget = BudgetReadView::new(&s);
        assert_eq!(
            budget.get_actor_budget_current_epoch_consumed(42).unwrap(),
            1
        );
    }

    /// GP.6.4: GasPoolClaim with --gas-pool-actor set drains the
    /// pool view atomically with the cursor advance.
    #[test]
    fn gas_pool_claim_drains_with_config() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // Pre-credit pool ETH for actor 1.
        let mut ix = Indexer::open_with_config(&s, Some(1), 0).unwrap();
        ix.apply_batch(
            1,
            &[Event::ActionBudgetTopUp {
                signer: 99,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 1000,
                budget_increment: 100,
                pool_actor: 1,
            }],
        )
        .unwrap();
        // Drain 300 via GasPoolClaim.
        ix.apply_batch(
            2,
            &[Event::GasPoolClaim {
                resource: RESOURCE_ID_ETH,
                sequencer: 2,
                amount: 300,
            }],
        )
        .unwrap();
        let budget = BudgetReadView::new(&s);
        // Pool ETH: 1000 - 300 = 700.
        assert_eq!(budget.get_pool_eth(1).unwrap(), 700);
    }

    /// GP.6.4: epoch advancement resets per-epoch tables but
    /// preserves lifetime tables.
    #[test]
    fn epoch_advancement_resets_per_epoch_tables() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // epoch_length = 10 → epoch crosses every 10 seqs.
        let mut ix = Indexer::open_with_config(&s, None, 10).unwrap();
        // Apply in epoch 0 (seq 1).
        ix.apply_batch(
            1,
            &[Event::ActionBudgetTopUp {
                signer: 42,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 10,
                budget_increment: 100,
                pool_actor: 1,
            }],
        )
        .unwrap();
        let budget = BudgetReadView::new(&s);
        assert_eq!(budget.get_actor_budget(42).unwrap(), 100);
        assert_eq!(
            budget.get_actor_budget_current_epoch_grants(42).unwrap(),
            100
        );
        // Cross to epoch 1.  The kernel advances epoch at
        // logIndex == epochLength (= 10), which surfaces as
        // seq = logIndex + 1 = 11.  (seq 10 ⇒ logIndex 9 is
        // still epoch 0, so it would NOT cross — the
        // off-by-one the audit corrected.)
        ix.apply_batch(
            11,
            &[Event::ActionBudgetTopUp {
                signer: 42,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 5,
                budget_increment: 50,
                pool_actor: 1,
            }],
        )
        .unwrap();
        let budget = BudgetReadView::new(&s);
        // Lifetime accumulates (100 + 50 = 150).
        assert_eq!(budget.get_actor_budget(42).unwrap(), 150);
        // Current-epoch resets to just the new credit (50).
        assert_eq!(
            budget.get_actor_budget_current_epoch_grants(42).unwrap(),
            50
        );
    }

    /// **Atomicity**: a budget overflow halts the WHOLE batch
    /// (kv + budget tables rolled back together).
    #[test]
    fn budget_overflow_rolls_back_kv() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // Pre-saturate the budget for actor 42 via a direct
        // BudgetStorage write.
        {
            use knomosis_storage::combined_transaction::CombinedStorage;
            let mut tx = s.begin_combined_tx().unwrap();
            tx.credit_actor_budget(42, u128::MAX - 5).unwrap();
            tx.commit().unwrap();
        }
        let mut ix = Indexer::open(&s).unwrap();
        // A batch that updates a balance AND tries to credit
        // 100 more budget → budget overflow.
        let result = ix.apply_batch(
            1,
            &[
                Event::BalanceChanged {
                    resource: 0,
                    actor: 99,
                    old_value: 0,
                    new_value: 555,
                },
                Event::ActionBudgetTopUp {
                    signer: 42,
                    gas_resource: RESOURCE_ID_ETH,
                    gas_amount: 1,
                    budget_increment: 100,
                    pool_actor: 1,
                },
            ],
        );
        assert!(matches!(result, Err(IndexerError::BudgetView(_))));
        // **Critical**: cursor stays at 0 AND the balance change
        // for actor 99 was rolled back.
        assert_eq!(ix.cursor(), 0);
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(99, 0).unwrap(), 0);
    }

    /// `IndexerStorage` blanket impl: SqliteStorage qualifies
    /// (the production storage backend).  Compile-time check.
    #[test]
    fn sqlite_storage_implements_indexer_storage() {
        fn assert_indexer_storage<T: IndexerStorage>() {}
        assert_indexer_storage::<SqliteStorage>();
    }

    /// Identifier mismatch on reopen rejects (preserved from v1).
    #[test]
    fn identifier_mismatch_on_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ix.db");
        {
            let s = SqliteStorage::open(&path).unwrap();
            s.put(crate::cursor::IDENTIFIER_KEY, b"other/v1").unwrap();
        }
        let s = SqliteStorage::open(&path).unwrap();
        let result = Indexer::open(&s);
        assert!(matches!(
            result,
            Err(IndexerError::Cursor(
                crate::cursor::CursorError::IdentifierMismatch { .. }
            ))
        ));
    }

    /// **Audit-regression**: cursor advance happens AFTER commit
    /// success.  Pin on the happy path.
    #[test]
    fn cursor_updates_on_commit_success() {
        let (_s, ()) = open_indexer();
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        let pre = ix.cursor();
        ix.apply_batch(
            10,
            &[Event::BalanceChanged {
                resource: 0,
                actor: 1,
                old_value: 0,
                new_value: 100,
            }],
        )
        .unwrap();
        assert_eq!(ix.cursor(), 10);
        assert_ne!(ix.cursor(), pre);
        let on_disk = crate::cursor::read_cursor(&s).unwrap();
        assert_eq!(on_disk, 10);
    }
}
