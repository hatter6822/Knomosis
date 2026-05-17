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
//! | 0   | `BalanceChanged`          | `set(actor, resource, new_value)`                  |
//! | 8   | `RewardIssued`            | `credit(recipient, resource, amount)`              |
//! | 9   | `WithdrawalRequested`     | `debit(sender, resource, amount)`                  |
//! | 10  | `DepositCredited`         | `credit(recipient, resource, amount)`              |
//! | All other tags            | no-op (balance view unaffected)                |
//!
//! **Consistency note.**  In the canonical kernel, the
//! `BalanceChanged` event is emitted for every action that
//! changes a balance — including transfers, mints, burns, rewards,
//! and bridge operations.  We dispatch `BalanceChanged` events
//! authoritatively (using the new_value field directly) and treat
//! `RewardIssued` / `WithdrawalRequested` / `DepositCredited` as
//! redundant.  If the upstream emits both, we apply the
//! `BalanceChanged` and the typed event in sequence; since
//! `BalanceChanged.new_value` is the post-state value, applying a
//! redundant credit afterwards would double-count.  To prevent
//! this, we use the following rule:
//!
//!   * If a `BalanceChanged` is in the same batch (same seq) as
//!     a reward / withdraw / deposit, the `BalanceChanged` takes
//!     precedence and the typed event is skipped at the balance
//!     view.  The typed event may still be observed by other
//!     consumers (e.g. a billing view subscribed to
//!     `RewardIssued` specifically).
//!
//! For now, the indexer applies dispatch in event-arrival order
//! WITHIN a seq batch; if the kernel emits `BalanceChanged` AFTER
//! the typed event in the same batch (the current convention),
//! the post-`BalanceChanged` `set` overwrites the credit/debit's
//! effect with the authoritative new_value.  This is the simpler
//! and more conservative implementation.
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

use canon_storage::storage::Storage;

use crate::balance::{BalanceError, BalanceTxView};
use crate::cursor::{advance_cursor_in_tx, ensure_identifier, read_cursor, CursorError};
use crate::event::Event;
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

        // Start a transaction; on failure mid-batch the
        // transaction is rolled back by Drop and the cursor stays
        // at its previous value.
        let mut tx = self.storage.transaction()?;
        {
            let mut bv = BalanceTxView::new(&mut *tx);
            for event in events {
                apply_event_to_view(&mut bv, event)?;
            }
        }
        // Cursor advance is the last operation inside the
        // transaction.  If it fails, the entire batch rolls back.
        advance_cursor_in_tx(&mut *tx, seq)?;
        tx.commit()?;
        self.cursor = seq;
        Ok(())
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

/// Apply a single event to a balance-tx view, per the dispatch
/// table in the module docstring.  Internal helper.
fn apply_event_to_view(view: &mut BalanceTxView<'_>, event: &Event) -> Result<(), BalanceError> {
    match event {
        Event::BalanceChanged {
            resource,
            actor,
            new_value,
            ..
        } => {
            // Authoritative post-state value — overwrite directly.
            view.set(*actor, *resource, *new_value)?;
        }
        Event::RewardIssued {
            resource,
            recipient,
            amount,
        } => {
            // Credit the recipient.  Saturating on overflow per
            // BalanceTxView::credit's contract.  An overflow IS
            // logged but DOES NOT halt the indexer — the balance
            // saturates at u128::MAX and the transaction still
            // commits.  If the operator wants strict
            // halt-on-overflow, they can future-extend the
            // dispatch table.
            //
            // Note: in production the kernel ALSO emits a
            // BalanceChanged event for the same balance change;
            // when both are in the same batch, the
            // BalanceChanged.new_value will overwrite this
            // credit's effect with the authoritative value.
            // Applying the credit anyway is the conservative
            // path: if BalanceChanged is missing (e.g. an
            // upstream bug), the credit alone produces a
            // reasonable balance.
            match view.credit(*recipient, *resource, *amount) {
                Ok(_) => {}
                Err(BalanceError::CreditOverflow { .. }) => {
                    tracing::warn!(
                        resource = *resource,
                        recipient = *recipient,
                        amount = *amount as u64,
                        "RewardIssued saturated balance at u128::MAX"
                    );
                }
                Err(e) => return Err(e),
            }
        }
        Event::WithdrawalRequested {
            resource,
            sender,
            amount,
            ..
        } => {
            // Debit the sender.  Rejects on underflow.  An
            // underflow indicates a real consistency error so we
            // surface it as a typed error (the batch rolls back).
            view.debit(*sender, *resource, *amount)?;
        }
        Event::DepositCredited {
            resource,
            recipient,
            amount,
            ..
        } => {
            // Credit the recipient.  Same saturating semantics as
            // RewardIssued.
            match view.credit(*recipient, *resource, *amount) {
                Ok(_) => {}
                Err(BalanceError::CreditOverflow { .. }) => {
                    tracing::warn!(
                        resource = *resource,
                        recipient = *recipient,
                        amount = *amount as u64,
                        "DepositCredited saturated balance at u128::MAX"
                    );
                }
                Err(e) => return Err(e),
            }
        }
        // All other events are no-ops at the balance-view layer.
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
}
