// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Indexer orchestration: dispatch events to the balance view +
//! advance the cursor atomically.
//!
//! ## Dispatch table
//!
//! For each incoming `Event`, the indexer applies:
//!
//! | Tag | Constructor               | Balance-view effect                                |
//! |-----|---------------------------|----------------------------------------------------|
//! | 0   | `BalanceChanged`          | `set(actor, resource, new_value)` (authoritative)  |
//! | 8   | `RewardIssued`            | `credit(recipient, resource, amount)` if no `BalanceChanged` for same key |
//! | 9   | `WithdrawalRequested`     | `debit(sender, resource, amount)` if no `BalanceChanged` for same key |
//! | 10  | `DepositCredited`         | `credit(recipient, resource, amount)` if no `BalanceChanged` for same key |
//! | All other tags            | no-op (balance view unaffected)                        |
//!
//! ## Two-pass dispatch (the BalanceChanged-overrides-semantic rule)
//!
//! The canonical kernel's `extractEvents`
//! (`LegalKernel/Events/Extract.lean`) emits events in the order:
//!
//! ```text
//!   action-events ++ bridge-events ++ lp-events ++ fault-proof-events ++ [nonceAdvanced]
//! ```
//!
//! For a `reward` action this is `[balanceChanged?, rewardIssued]`
//! — `balanceChanged` (delta-filtered, present iff balance
//! actually changed) FIRST, then the always-emitted
//! `rewardIssued`.  Similarly for `deposit` it's
//! `[balanceChanged?, depositCredited]` and for `withdraw` it's
//! `[balanceChanged?, withdrawalRequested]`.
//!
//! An arrival-order dispatch would DOUBLE-COUNT when both are
//! present: applying `BalanceChanged` first sets the cell to the
//! authoritative post-state value, then applying the semantic
//! credit/debit double-counts.  For `withdraw` it's worse: the
//! `BalanceChanged` sets the cell to the post-withdraw balance,
//! then `debit` underflows (since the post-withdraw value is less
//! than the withdrawn amount), rolling back the entire batch.
//!
//! The correct dispatch is **two-pass**:
//!
//!   1. **Pass 1**: collect the set `S = { (actor, resource) :
//!      ∃ BalanceChanged event in batch with this (actor, resource) }`.
//!   2. **Pass 2**: apply each `RewardIssued`, `WithdrawalRequested`,
//!      `DepositCredited` event whose `(actor, resource)` is NOT
//!      in `S`.  These are the "fall-back" semantic events when
//!      the kernel didn't emit a corresponding `BalanceChanged`
//!      (e.g. a zero-amount action, where the balance didn't
//!      change but the semantic event is unconditionally emitted).
//!   3. **Pass 3**: apply every `BalanceChanged` event as a `set`.
//!      This is the authoritative final value.
//!
//! ## Mathematical contract
//!
//! Let `B(a, r)` denote the balance-view value for `(actor, resource)`.
//! For each batch:
//!
//!   * If the batch contains `BalanceChanged(r, a, _, v)` for
//!     `(a, r)`: after `apply_batch`, `B(a, r) = v` (the
//!     `BalanceChanged.new_value`).
//!   * If the batch contains NO `BalanceChanged` for `(a, r)` but
//!     contains `RewardIssued(r, a, amt)` (or `DepositCredited`):
//!     after `apply_batch`, `B(a, r)` is incremented by `amt`.
//!   * If the batch contains NO `BalanceChanged` for `(a, r)` but
//!     contains `WithdrawalRequested(r, a, amt, …)`: after
//!     `apply_batch`, `B(a, r)` is decremented by `amt`.  If the
//!     pre-batch value was less than `amt`, the batch fails with
//!     [`IndexerError::Balance`] (no partial mutations persist).
//!   * Otherwise: `B(a, r)` is unchanged.
//!
//! This matches the kernel's `getBalance(actor, resource)` for
//! every `(actor, resource)` pair after replaying any event stream.
//!
//! ## Overflow handling
//!
//! `credit` overflow (current balance + delta > u128::MAX) is
//! treated as a **halt condition**: the batch rolls back and the
//! indexer surfaces [`IndexerError::Balance`].  Saturating credit
//! would permanently corrupt the balance cell to `u128::MAX`,
//! which is silently wrong.  An operator who hits this error
//! investigates the upstream event source (kernel bug or
//! malformed event).
//!
//! ## Atomicity
//!
//! Each event-batch (one log frame's worth of events, all sharing
//! the same seq) is applied inside a single storage transaction.
//! The transaction's last operation is the cursor advance.  On
//! commit, every balance update + the cursor advance become
//! visible atomically.  On any per-event error, the transaction
//! is rolled back and the entire batch is discarded — the cursor
//! does NOT advance, and the indexer's next subscribe will
//! re-deliver the failing batch (giving the operator time to
//! intervene).
//!
//! ## Idempotency
//!
//! On startup, the indexer reads the cursor and subscribes with
//! `resume_from = cursor`.  The wire protocol guarantees that
//! the server then sends every event with `seq > cursor`.  If
//! the indexer crashes mid-batch, the cursor reflects the last
//! committed batch's seq; on restart, the server replays from
//! that seq.  The replay is byte-equivalent to the original
//! batch (the event stream is deterministic given the log), so
//! the dispatch produces the same balance updates.

use std::collections::HashSet;

use canon_storage::storage::Storage;

use crate::balance::{BalanceError, BalanceTxView};
use crate::cursor::{advance_cursor_in_tx, ensure_identifier, read_cursor, CursorError};
use crate::decoder::DecodeError;
use crate::event::{ActorId, Event, ResourceId};
use crate::INDEXER_IDENTIFIER;

/// Indexer-level errors.
#[derive(Debug, thiserror::Error)]
pub enum IndexerError {
    /// Storage error (open / read / write / commit).
    #[error("storage error: {0}")]
    Storage(#[from] canon_storage::storage::StorageError),
    /// Balance-view error (overflow / underflow / corrupt cell).
    #[error("balance error: {0}")]
    Balance(#[from] BalanceError),
    /// Cursor error (non-monotone / corrupt cell / identifier
    /// mismatch).
    #[error("cursor error: {0}")]
    Cursor(#[from] CursorError),
    /// CBE decoder error.  Indicates the wire-format payload was
    /// malformed (truncated, bad tag, oversize byte string, etc.).
    #[error("decoder error at seq {seq}: {source}")]
    Decode {
        /// The event sequence number whose payload failed to decode.
        seq: u64,
        /// The underlying decoder error.
        #[source]
        source: DecodeError,
    },
    /// The event batch is empty.  Indicates an extractor / wire
    /// protocol bug — events are emitted in batches of at least
    /// one event per log frame.
    #[error("empty event batch")]
    EmptyBatch,
    /// The event's seq is at or before the cursor.  Indicates a
    /// wire-protocol bug: the server should never deliver events
    /// the indexer has already processed.
    #[error("stale event seq {seq} (cursor at {cursor})")]
    StaleEvent {
        /// The event's seq.
        seq: u64,
        /// Current cursor value.
        cursor: u64,
    },
    /// The wire protocol delivered events out of order (a later
    /// frame's seq was strictly less than an earlier frame's seq).
    /// The wire-protocol spec (`docs/abi.md` §11.4) requires
    /// monotonically non-decreasing seq numbers; this error
    /// indicates the server is buggy or the connection is being
    /// tampered with.
    #[error(
        "protocol violation: out-of-order seq (current {current_seq}, received {offending_seq})"
    )]
    ProtocolViolation {
        /// The current seq the indexer was accumulating.
        current_seq: u64,
        /// The offending seq that arrived (must be < current_seq
        /// to trigger this variant).
        offending_seq: u64,
    },
    /// `tx.commit()` reported an error but the SQLite-level state
    /// may have partially succeeded.  After this error the
    /// indexer's in-memory cursor was reloaded from disk to
    /// determine the true state.  If the disk shows the new value,
    /// the commit succeeded despite the error report; if the disk
    /// shows the old value, the commit truly failed.  Either way,
    /// the caller MUST treat the in-memory cursor as authoritative
    /// (via `cursor()`) when retrying.
    #[error("commit ambiguous at seq {seq} (disk cursor after reload: {disk_cursor})")]
    CommitAmbiguous {
        /// The seq being committed.
        seq: u64,
        /// The disk cursor value AFTER reload from storage.
        disk_cursor: u64,
    },
}

/// An indexer instance backed by a [`Storage`].
///
/// Construct via [`Indexer::open`] which performs the startup
/// dance (identifier check + cursor read).  Apply event batches
/// via [`Indexer::apply_batch`]; the method handles the
/// transaction lifecycle internally.
pub struct Indexer<'a, S: Storage + ?Sized> {
    storage: &'a S,
    /// The last-committed cursor value, mirrored in memory for
    /// fast access.  Synced with the on-disk cursor at startup
    /// and after each successful batch commit.
    cursor: u64,
}

impl<S: Storage + ?Sized> std::fmt::Debug for Indexer<'_, S> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Indexer")
            .field("cursor", &self.cursor)
            .finish_non_exhaustive()
    }
}

impl<'a, S: Storage + ?Sized> Indexer<'a, S> {
    /// Open an indexer over `storage`.  Verifies the on-disk
    /// identifier matches the binary's [`INDEXER_IDENTIFIER`]
    /// (initialising the cell if absent), then reads the cursor.
    ///
    /// # Errors
    ///
    /// Returns [`IndexerError::Cursor`] with
    /// [`CursorError::IdentifierMismatch`] if the database was
    /// written by an incompatible indexer.  Returns
    /// [`IndexerError::Storage`] on storage failure.
    pub fn open(storage: &'a S) -> Result<Self, IndexerError> {
        ensure_identifier(storage, INDEXER_IDENTIFIER)?;
        let cursor = read_cursor(storage)?;
        tracing::info!(cursor, identifier = INDEXER_IDENTIFIER, "indexer opened");
        Ok(Self { storage, cursor })
    }

    /// Current cursor value (last-committed seq).
    pub fn cursor(&self) -> u64 {
        self.cursor
    }

    /// Apply a batch of events that share the same seq.  All
    /// effects + the cursor advance commit atomically.
    ///
    /// `events` is the list of events from a single log frame
    /// (multiple events per frame are allowed; they all share
    /// the seq).  `seq` is the frame's seq number; it must be
    /// strictly greater than the current cursor.
    ///
    /// # Errors
    ///
    /// Returns [`IndexerError::EmptyBatch`] if `events` is empty.
    /// Returns [`IndexerError::StaleEvent`] if `seq <= cursor`.
    /// Returns [`IndexerError::Balance`] on balance arithmetic
    /// errors (the transaction is rolled back and the cursor
    /// remains at its previous value).  Returns
    /// [`IndexerError::Storage`] on transaction commit failure.
    pub fn apply_batch(&mut self, seq: u64, events: &[Event]) -> Result<(), IndexerError> {
        if events.is_empty() {
            return Err(IndexerError::EmptyBatch);
        }
        if seq <= self.cursor {
            return Err(IndexerError::StaleEvent {
                seq,
                cursor: self.cursor,
            });
        }

        // Pre-compute the set of (actor, resource) pairs covered
        // by `BalanceChanged` events in this batch.  Semantic
        // events for the same pair are skipped in pass 2 to
        // avoid double-counting (see module docstring).
        let bc_pairs: HashSet<(ActorId, ResourceId)> = events
            .iter()
            .filter_map(|e| match e {
                Event::BalanceChanged {
                    actor, resource, ..
                } => Some((*actor, *resource)),
                _ => None,
            })
            .collect();

        // Start a transaction; on failure mid-batch the
        // transaction is rolled back by Drop and the cursor stays
        // at its previous value.
        let mut tx = self.storage.transaction()?;
        {
            let mut bv = BalanceTxView::new(&mut *tx);

            // Pass 1 (Phase 2 in the docstring): apply semantic
            // events (RewardIssued / DepositCredited /
            // WithdrawalRequested) whose (actor, resource) is NOT
            // covered by a BalanceChanged.
            for event in events {
                apply_semantic_event(&mut bv, event, &bc_pairs)?;
            }

            // Pass 2 (Phase 3 in the docstring): apply
            // BalanceChanged events as authoritative `set`s.
            for event in events {
                if let Event::BalanceChanged {
                    resource,
                    actor,
                    new_value,
                    ..
                } = event
                {
                    bv.set(*actor, *resource, *new_value)?;
                }
            }
        }

        // Cursor advance is the last operation inside the
        // transaction.  If it fails, the entire batch rolls back.
        advance_cursor_in_tx(&mut *tx, seq)?;

        // Commit.  On commit failure, SQLite *may* have
        // partially succeeded — the in-memory cursor MUST be
        // re-synced with disk before any subsequent operation,
        // otherwise a stale in-memory cursor combined with a
        // successful disk commit could cause double-apply on
        // retry.  We reload from disk and surface a
        // `CommitAmbiguous` error so the caller knows to inspect
        // `cursor()`.
        match tx.commit() {
            Ok(()) => {
                self.cursor = seq;
                Ok(())
            }
            Err(commit_err) => {
                // The transaction's Drop already attempted a
                // ROLLBACK as part of the commit-failure path.
                // Reload the cursor from disk to determine the
                // true state.  If disk shows `seq`, the commit
                // succeeded despite the error report; if disk
                // shows the previous value, the commit truly
                // rolled back.
                let disk_cursor = read_cursor(self.storage).map_err(IndexerError::Cursor)?;
                self.cursor = disk_cursor;
                if disk_cursor >= seq {
                    // The commit actually succeeded.  Surface the
                    // CommitAmbiguous error so the caller knows
                    // the original error reported wasn't fatal.
                    Err(IndexerError::CommitAmbiguous { seq, disk_cursor })
                } else {
                    // The commit truly failed.  Propagate the
                    // original commit error.
                    Err(IndexerError::Storage(commit_err))
                }
            }
        }
    }

    /// Re-read the on-disk cursor (e.g. after another indexer
    /// process committed).  Mostly diagnostic; production usage
    /// uses the in-memory cursor.
    ///
    /// # Errors
    ///
    /// See [`CursorError`].
    pub fn reload_cursor(&mut self) -> Result<(), IndexerError> {
        self.cursor = read_cursor(self.storage)?;
        Ok(())
    }
}

/// Apply a single semantic event (RewardIssued, DepositCredited,
/// WithdrawalRequested) to a balance-tx view, BUT ONLY IF the
/// event's (actor, resource) is not covered by a BalanceChanged
/// event elsewhere in the batch.  BalanceChanged events
/// themselves are not handled here — they're applied in a
/// separate pass after this one.
///
/// **Overflow handling.**  `credit` overflow is propagated as
/// [`BalanceError::CreditOverflow`] — the indexer rolls back the
/// batch.  We do NOT silently saturate (that would corrupt the
/// balance cell to u128::MAX permanently).
fn apply_semantic_event(
    view: &mut BalanceTxView<'_>,
    event: &Event,
    bc_pairs: &HashSet<(ActorId, ResourceId)>,
) -> Result<(), BalanceError> {
    match event {
        Event::RewardIssued {
            resource,
            recipient,
            amount,
        } => {
            if bc_pairs.contains(&(*recipient, *resource)) {
                // BalanceChanged in this batch overrides — skip.
                return Ok(());
            }
            // No BalanceChanged for this (actor, resource).  Apply
            // the credit; overflow halts the batch.
            view.credit(*recipient, *resource, *amount)?;
        }
        Event::WithdrawalRequested {
            resource,
            sender,
            amount,
            ..
        } => {
            if bc_pairs.contains(&(*sender, *resource)) {
                // BalanceChanged in this batch overrides — skip.
                // (This is the critical fix for the
                // BalanceChanged-then-withdraw underflow bug: a
                // batch like [BalanceChanged(s, r, _, 20),
                // WithdrawalRequested(r, s, 30, …)] would have
                // underflowed with arrival-order dispatch
                // because the set-to-20 + debit-30 = -10.)
                return Ok(());
            }
            // No BalanceChanged for this (sender, resource).
            // Apply the debit; underflow halts the batch.
            view.debit(*sender, *resource, *amount)?;
        }
        Event::DepositCredited {
            resource,
            recipient,
            amount,
            ..
        } => {
            if bc_pairs.contains(&(*recipient, *resource)) {
                // BalanceChanged in this batch overrides — skip.
                return Ok(());
            }
            view.credit(*recipient, *resource, *amount)?;
        }
        // BalanceChanged is handled in a separate pass; all
        // other events (NonceAdvanced, IdentityRegistered,
        // dispute/verdict/fault-proof/local-policy events) are
        // no-ops at the balance-view layer.
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Indexer, IndexerError};
    use crate::balance::BalanceView;
    use crate::event::Event;
    use canon_storage::sqlite::SqliteStorage;

    /// Opening a fresh database initialises the identifier and
    /// returns cursor = 0.
    #[test]
    fn open_fresh_db() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let ix = Indexer::open(&s).unwrap();
        assert_eq!(ix.cursor(), 0);
    }

    /// Re-opening an existing database matches the cursor.
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

    /// `BalanceChanged` sets the balance authoritatively.
    #[test]
    fn dispatch_balance_changed() {
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

    /// `RewardIssued` credits the recipient.
    #[test]
    fn dispatch_reward_issued() {
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

    /// `DepositCredited` credits the recipient.
    #[test]
    fn dispatch_deposit_credited() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        ix.apply_batch(
            1,
            &[Event::DepositCredited {
                resource: 2,
                recipient: 8,
                amount: 250,
                deposit_id: 1,
            }],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(8, 2).unwrap(), 250);
    }

    /// `WithdrawalRequested` debits the sender.
    #[test]
    fn dispatch_withdrawal_requested() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        // Seed sender balance via BalanceChanged.
        ix.apply_batch(
            1,
            &[Event::BalanceChanged {
                resource: 1,
                actor: 9,
                old_value: 0,
                new_value: 500,
            }],
        )
        .unwrap();
        // Withdraw 200.
        ix.apply_batch(
            2,
            &[Event::WithdrawalRequested {
                resource: 1,
                sender: 9,
                amount: 200,
                recipient_l1: [0; 20],
                withdrawal_id: 1,
            }],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(9, 1).unwrap(), 300);
    }

    /// Multi-event batch applies atomically.
    #[test]
    fn multi_event_batch_atomic() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        ix.apply_batch(
            1,
            &[
                Event::BalanceChanged {
                    resource: 1,
                    actor: 1,
                    old_value: 0,
                    new_value: 100,
                },
                Event::BalanceChanged {
                    resource: 1,
                    actor: 2,
                    old_value: 0,
                    new_value: 200,
                },
            ],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(1, 1).unwrap(), 100);
        assert_eq!(bv.get(2, 1).unwrap(), 200);
        assert_eq!(ix.cursor(), 1);
    }

    /// `apply_batch` rejects an empty batch.
    #[test]
    fn empty_batch_rejected() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        match ix.apply_batch(1, &[]) {
            Err(IndexerError::EmptyBatch) => {}
            other => panic!("expected EmptyBatch, got {other:?}"),
        }
    }

    /// `apply_batch` rejects a stale seq (already processed).
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
        // Try replaying seq 5.
        match ix.apply_batch(
            5,
            &[Event::BalanceChanged {
                resource: 1,
                actor: 1,
                old_value: 0,
                new_value: 200,
            }],
        ) {
            Err(IndexerError::StaleEvent { seq, cursor }) => {
                assert_eq!(seq, 5);
                assert_eq!(cursor, 5);
            }
            other => panic!("expected StaleEvent, got {other:?}"),
        }
        // Cursor unchanged.
        assert_eq!(ix.cursor(), 5);
        // Balance unchanged from the original.
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(1, 1).unwrap(), 100);
    }

    /// Debit underflow rolls back the entire batch.
    #[test]
    fn debit_underflow_rolls_back() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        // Seed with 50.
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
        // Try to withdraw 100.
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
        // Cursor unchanged from before the failed batch.
        assert_eq!(ix.cursor(), 1);
        // Balance unchanged.
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(1, 1).unwrap(), 50);
    }

    /// No-op events (e.g. NonceAdvanced) advance the cursor
    /// without touching balances.
    #[test]
    fn no_op_event_advances_cursor() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        ix.apply_batch(
            1,
            &[Event::NonceAdvanced {
                actor: 1,
                old_nonce: 0,
                new_nonce: 1,
            }],
        )
        .unwrap();
        assert_eq!(ix.cursor(), 1);
        let bv = BalanceView::new(&s);
        assert_eq!(bv.scan_all().unwrap().len(), 0);
    }

    /// Identifier mismatch on reopen.
    #[test]
    fn identifier_mismatch_on_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ix.db");
        // Manually plant a different identifier.
        {
            use canon_storage::storage::Storage;
            let s = SqliteStorage::open(&path).unwrap();
            s.put(crate::cursor::IDENTIFIER_KEY, b"other/v1").unwrap();
        }
        // Open as canon-indexer/v1 — must fail.
        let s = SqliteStorage::open(&path).unwrap();
        let result = Indexer::open(&s);
        // We can't use the {:?} formatter on Indexer because the
        // variant carries the storage borrow; match the typed
        // result against the expected `Err` shape.
        match result {
            Err(IndexerError::Cursor(crate::cursor::CursorError::IdentifierMismatch {
                expected,
                found,
            })) => {
                assert_eq!(expected, "canon-indexer/v1");
                assert_eq!(found, "other/v1");
            }
            Err(other) => panic!("expected IdentifierMismatch, got Err({other:?})"),
            Ok(_) => panic!("expected IdentifierMismatch, got Ok"),
        }
    }

    /// **Audit-regression C-2**: Dispatch order — when a batch
    /// contains both BalanceChanged and a semantic event for the
    /// same (actor, resource), the BalanceChanged value wins
    /// (the semantic event is skipped to avoid double-counting).
    ///
    /// This is the canonical kernel-emit order: for a `reward`
    /// action, the Lean side emits `[balanceChanged?,
    /// rewardIssued]` — balanceChanged FIRST.  Arrival-order
    /// dispatch would set then credit, giving 100 + 100 = 200.
    /// The correct dispatch is two-pass: credit is skipped
    /// because BalanceChanged covers the same (actor, resource).
    #[test]
    fn dispatch_two_pass_reward_no_double_count() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        // Initial state: actor 1, resource 0, balance 0.
        // Reward action with amount=100: balance becomes 100.
        // Kernel emits:
        //   1. BalanceChanged(0, 1, 0, 100)
        //   2. RewardIssued(0, 1, 100)
        ix.apply_batch(
            1,
            &[
                Event::BalanceChanged {
                    resource: 0,
                    actor: 1,
                    old_value: 0,
                    new_value: 100,
                },
                Event::RewardIssued {
                    resource: 0,
                    recipient: 1,
                    amount: 100,
                },
            ],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        // Without two-pass dispatch: balance would be 200 (set
        // then credit double-counts).  With two-pass: balance is
        // 100 (RewardIssued skipped because BalanceChanged
        // covers the same key).
        assert_eq!(bv.get(1, 0).unwrap(), 100);
    }

    /// **Audit-regression C-2 (withdraw variant)**: A withdraw
    /// action emits `[balanceChanged?, withdrawalRequested]`.  With
    /// arrival-order dispatch, the set-to-post-balance + debit
    /// would underflow (post-balance < withdrawn amount).  With
    /// two-pass dispatch, the WithdrawalRequested is skipped
    /// (BalanceChanged covers the key), and the balance ends up
    /// at the authoritative post-state value.
    #[test]
    fn dispatch_two_pass_withdraw_no_underflow() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        // Seed: actor 1, resource 0, balance 100.
        ix.apply_batch(
            1,
            &[Event::BalanceChanged {
                resource: 0,
                actor: 1,
                old_value: 0,
                new_value: 100,
            }],
        )
        .unwrap();
        // Withdraw 30: balance becomes 70.
        // Kernel emits:
        //   1. BalanceChanged(0, 1, 100, 70)
        //   2. WithdrawalRequested(0, 1, 30, addr, wdid)
        ix.apply_batch(
            2,
            &[
                Event::BalanceChanged {
                    resource: 0,
                    actor: 1,
                    old_value: 100,
                    new_value: 70,
                },
                Event::WithdrawalRequested {
                    resource: 0,
                    sender: 1,
                    amount: 30,
                    recipient_l1: [0; 20],
                    withdrawal_id: 1,
                },
            ],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        // Without two-pass: set-to-70 then debit-30 = 40 (WRONG,
        // double-counts the withdraw).  Or worse: in a scenario
        // where post-balance < withdrawn-amount, set-to-X then
        // debit-Y underflows.  With two-pass: balance is 70.
        assert_eq!(bv.get(1, 0).unwrap(), 70);
    }

    /// **Audit-regression C-2 (semantic-event-without-balance-changed)**:
    /// If a batch has a semantic event WITHOUT a corresponding
    /// BalanceChanged (e.g. amount=0, where the kernel
    /// delta-filters BalanceChanged but still emits the
    /// unconditional semantic event), the semantic event applies
    /// normally.
    #[test]
    fn dispatch_semantic_event_alone_applies() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        // Reward of 50 to actor 1 — no BalanceChanged (e.g., a
        // sythetic test scenario or a kernel quirk).
        ix.apply_batch(
            1,
            &[Event::RewardIssued {
                resource: 0,
                recipient: 1,
                amount: 50,
            }],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(1, 0).unwrap(), 50);
    }

    /// **Audit-regression C-2 (cross-key non-interference)**:
    /// A batch with BalanceChanged for (A1, R) and RewardIssued
    /// for (A2, R) (different actors) — both should apply.
    #[test]
    fn dispatch_two_pass_different_actors_dont_interfere() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        ix.apply_batch(
            1,
            &[
                Event::BalanceChanged {
                    resource: 0,
                    actor: 1,
                    old_value: 0,
                    new_value: 100,
                },
                Event::RewardIssued {
                    resource: 0,
                    recipient: 2, // different actor!
                    amount: 50,
                },
            ],
        )
        .unwrap();
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(1, 0).unwrap(), 100); // BalanceChanged for actor 1
        assert_eq!(bv.get(2, 0).unwrap(), 50); // RewardIssued for actor 2
    }

    /// **Audit-regression H-5**: `credit` overflow halts the
    /// batch — the indexer does NOT silently saturate.
    #[test]
    fn credit_overflow_halts_batch() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        // Seed: actor 1, balance just below u128::MAX.
        ix.apply_batch(
            1,
            &[Event::BalanceChanged {
                resource: 0,
                actor: 1,
                old_value: 0,
                new_value: u128::MAX - 10,
            }],
        )
        .unwrap();
        // Reward 100 to actor 1: overflow.
        let result = ix.apply_batch(
            2,
            &[Event::RewardIssued {
                resource: 0,
                recipient: 1,
                amount: 100,
            }],
        );
        assert!(matches!(result, Err(IndexerError::Balance(_))));
        // Cursor unchanged.
        assert_eq!(ix.cursor(), 1);
        // Balance unchanged (no saturation).
        let bv = BalanceView::new(&s);
        assert_eq!(bv.get(1, 0).unwrap(), u128::MAX - 10);
    }

    /// **Audit-regression C-3**: Cursor update happens AFTER
    /// successful commit.  If commit fails, the in-memory cursor
    /// is reloaded from disk to avoid desync.  We can't easily
    /// inject a commit failure via SqliteStorage; this test
    /// verifies the happy path that the cursor IS updated on
    /// success.
    #[test]
    fn cursor_updates_on_commit_success() {
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
        // Reload from disk: should match.
        let on_disk = crate::cursor::read_cursor(&s).unwrap();
        assert_eq!(on_disk, 10);
    }

    /// **Audit-regression**: A transfer-shaped batch (two
    /// BalanceChanged events, no semantic events) applies
    /// correctly.  Verifies the cross-key independence of the
    /// two-pass dispatch.
    #[test]
    fn transfer_shaped_batch_applies() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        // Seed: sender has 500.
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
        // Transfer 200 from actor 1 to actor 2: kernel emits two
        // BalanceChanged events.
        ix.apply_batch(
            2,
            &[
                Event::BalanceChanged {
                    resource: 0,
                    actor: 1, // sender
                    old_value: 500,
                    new_value: 300,
                },
                Event::BalanceChanged {
                    resource: 0,
                    actor: 2, // receiver
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
}
