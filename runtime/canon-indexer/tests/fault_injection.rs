// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Fault-injection tests for the indexer's recovery paths.
//!
//! The audit-pass introduced two new error variants
//! ([`canon_indexer::indexer::IndexerError::CommitAmbiguous`] and
//! [`canon_indexer::indexer::IndexerError::CursorRecoveryFailed`])
//! that exercise SQLite-level failure modes we can't easily
//! trigger through the production `SqliteStorage`.  This file
//! defines a `FaultyStorage` adaptor that wraps any
//! `Storage` impl and injects controlled failures on demand,
//! plus tests that verify the indexer's recovery semantics.

use canon_indexer::event::Event;
use canon_indexer::indexer::{Indexer, IndexerError, INDEXER_MAX_BATCH_EVENTS};
use canon_storage::sqlite::SqliteStorage;
use canon_storage::storage::{
    KeyValuePairs, Storage, StorageError, StorageSnapshot, StorageTransaction,
};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::Arc;

/// A storage adaptor that wraps any `Storage` and can be told to
/// inject specific failures.  Each failure flag is `consumed`
/// when triggered (one-shot) so tests can observe single-event
/// recovery cleanly.
struct FaultyStorage<S: Storage + ?Sized> {
    inner: Box<S>,
    /// If set, the next `transaction()` call returns a wrapped
    /// transaction whose `commit()` returns Err.  Auto-cleared
    /// after one trigger.
    fail_next_commit: AtomicBool,
    /// If set, the next `get(b"c/cursor")` call returns Err.
    /// Used to inject the cascading failure (commit fails AND
    /// cursor reload fails).  Auto-cleared after one trigger.
    fail_next_cursor_read: AtomicBool,
    /// Counter for trigger-on-Nth-call patterns.
    cursor_read_count: AtomicU8,
}

impl<S: Storage + ?Sized> FaultyStorage<S> {
    fn new(inner: Box<S>) -> Self {
        Self {
            inner,
            fail_next_commit: AtomicBool::new(false),
            fail_next_cursor_read: AtomicBool::new(false),
            cursor_read_count: AtomicU8::new(0),
        }
    }

    fn trip_commit(&self) {
        self.fail_next_commit.store(true, Ordering::SeqCst);
    }

    fn trip_cursor_read(&self) {
        self.fail_next_cursor_read.store(true, Ordering::SeqCst);
    }
}

impl<S: Storage + ?Sized> Storage for FaultyStorage<S> {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, StorageError> {
        if key == b"c/cursor" {
            let _ = self.cursor_read_count.fetch_add(1, Ordering::SeqCst);
            if self.fail_next_cursor_read.swap(false, Ordering::SeqCst) {
                return Err(StorageError::Backend(
                    "fault-injected: cursor read failure".to_string(),
                ));
            }
        }
        self.inner.get(key)
    }

    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), StorageError> {
        self.inner.put(key, value)
    }

    fn delete(&self, key: &[u8]) -> Result<(), StorageError> {
        self.inner.delete(key)
    }

    fn scan(&self, prefix: &[u8]) -> Result<KeyValuePairs, StorageError> {
        self.inner.scan(prefix)
    }

    fn snapshot(&self) -> Result<Box<dyn StorageSnapshot + '_>, StorageError> {
        self.inner.snapshot()
    }

    fn transaction(&self) -> Result<Box<dyn StorageTransaction + '_>, StorageError> {
        let inner_tx = self.inner.transaction()?;
        if self.fail_next_commit.swap(false, Ordering::SeqCst) {
            Ok(Box::new(FaultyTransaction {
                inner: Some(inner_tx),
                fail_commit: true,
            }))
        } else {
            Ok(Box::new(FaultyTransaction {
                inner: Some(inner_tx),
                fail_commit: false,
            }))
        }
    }
}

/// Wrapper transaction that can be made to fail on commit.
struct FaultyTransaction<'a> {
    inner: Option<Box<dyn StorageTransaction + 'a>>,
    fail_commit: bool,
}

impl StorageTransaction for FaultyTransaction<'_> {
    fn put(&mut self, key: &[u8], value: &[u8]) -> Result<(), StorageError> {
        self.inner.as_mut().unwrap().put(key, value)
    }

    fn delete(&mut self, key: &[u8]) -> Result<(), StorageError> {
        self.inner.as_mut().unwrap().delete(key)
    }

    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, StorageError> {
        self.inner.as_ref().unwrap().get(key)
    }

    fn commit(mut self: Box<Self>) -> Result<(), StorageError> {
        let inner = self.inner.take().unwrap();
        if self.fail_commit {
            // Roll back the inner so the underlying SQLite state
            // is clean; then return Err so the indexer's
            // commit-failure path activates.
            let _ = inner.rollback();
            Err(StorageError::CommitFailed {
                reason: "fault-injected: commit failure".to_string(),
            })
        } else {
            inner.commit()
        }
    }

    fn rollback(mut self: Box<Self>) -> Result<(), StorageError> {
        let inner = self.inner.take().unwrap();
        inner.rollback()
    }
}

/// **Audit-regression C-3 (CommitAmbiguous on commit-fail-but-disk-OK)**:
/// When `tx.commit()` returns Err but the disk cursor reflects the
/// new value (commit actually succeeded), the indexer returns
/// `CommitAmbiguous` and resyncs the in-memory cursor.
///
/// Note: our FaultyTransaction rolls back the inner before
/// returning Err, so the disk WILL show the old value.  This
/// test verifies the truly-failed path; we can't easily simulate
/// "commit returned error but actually persisted" without a more
/// elaborate fault-injection harness.
#[test]
fn commit_failure_truly_rolled_back_returns_storage_error() {
    let inner = SqliteStorage::open_in_memory().unwrap();
    let faulty = Arc::new(FaultyStorage::new(Box::new(inner)));
    let mut indexer = Indexer::open(&*faulty).unwrap();

    // Trip the next commit to fail.
    faulty.trip_commit();
    let result = indexer.apply_batch(
        1,
        &[Event::BalanceChanged {
            resource: 0,
            actor: 1,
            old_value: 0,
            new_value: 100,
        }],
    );
    match result {
        Err(IndexerError::Storage(_)) => {}
        other => panic!("expected Storage error, got {other:?}"),
    }
    // Cursor unchanged.
    assert_eq!(indexer.cursor(), 0);
    // NOT poisoned — recovery succeeded.
    assert!(!indexer.is_poisoned());
    // A subsequent apply_batch (no fault) should succeed.
    indexer
        .apply_batch(
            1,
            &[Event::BalanceChanged {
                resource: 0,
                actor: 1,
                old_value: 0,
                new_value: 100,
            }],
        )
        .unwrap();
    assert_eq!(indexer.cursor(), 1);
}

/// **Audit-regression C-2 (CursorRecoveryFailed)**: when commit
/// fails AND the subsequent cursor read also fails, the indexer
/// poisons itself and returns `CursorRecoveryFailed`.
#[test]
fn cascading_failure_poisons_indexer() {
    let inner = SqliteStorage::open_in_memory().unwrap();
    let faulty = Arc::new(FaultyStorage::new(Box::new(inner)));
    let mut indexer = Indexer::open(&*faulty).unwrap();

    // Trip BOTH: commit fails, and the post-commit cursor read
    // ALSO fails.
    faulty.trip_commit();
    faulty.trip_cursor_read();
    let result = indexer.apply_batch(
        1,
        &[Event::BalanceChanged {
            resource: 0,
            actor: 1,
            old_value: 0,
            new_value: 100,
        }],
    );
    match result {
        Err(IndexerError::CursorRecoveryFailed {
            seq,
            commit_error,
            cursor_error,
        }) => {
            assert_eq!(seq, 1);
            assert!(commit_error.contains("commit failure"));
            assert!(cursor_error.contains("cursor read failure"));
        }
        other => panic!("expected CursorRecoveryFailed, got {other:?}"),
    }
    // Indexer is now poisoned.
    assert!(indexer.is_poisoned());

    // Any subsequent apply_batch returns Poisoned.
    let result = indexer.apply_batch(
        2,
        &[Event::BalanceChanged {
            resource: 0,
            actor: 1,
            old_value: 0,
            new_value: 200,
        }],
    );
    assert!(matches!(result, Err(IndexerError::Poisoned)));
}

/// **Audit-regression H-2 (BatchTooLarge)**: a batch exceeding
/// `INDEXER_MAX_BATCH_EVENTS` is rejected with a typed error.
#[test]
fn batch_too_large_rejected() {
    let storage = SqliteStorage::open_in_memory().unwrap();
    let mut indexer = Indexer::open(&storage).unwrap();
    let events: Vec<Event> = (0..=INDEXER_MAX_BATCH_EVENTS as u64)
        .map(|i| Event::BalanceChanged {
            resource: 0,
            actor: i,
            old_value: 0,
            new_value: u128::from(i),
        })
        .collect();
    assert_eq!(events.len(), INDEXER_MAX_BATCH_EVENTS + 1);

    match indexer.apply_batch(1, &events) {
        Err(IndexerError::BatchTooLarge { size, max }) => {
            assert_eq!(size, INDEXER_MAX_BATCH_EVENTS + 1);
            assert_eq!(max, INDEXER_MAX_BATCH_EVENTS);
        }
        other => panic!("expected BatchTooLarge, got {other:?}"),
    }

    // Cursor unchanged.
    assert_eq!(indexer.cursor(), 0);
    // A batch at the limit is fine.
    let events_at_limit: Vec<Event> = (0..INDEXER_MAX_BATCH_EVENTS as u64)
        .map(|i| Event::BalanceChanged {
            resource: 0,
            actor: i,
            old_value: 0,
            new_value: u128::from(i),
        })
        .collect();
    assert_eq!(events_at_limit.len(), INDEXER_MAX_BATCH_EVENTS);
    indexer.apply_batch(1, &events_at_limit).unwrap();
    assert_eq!(indexer.cursor(), 1);
}

/// **Bound constant pinned**.  Regression: changing this without
/// the wire-protocol upstream changing first would be a real
/// problem.
#[test]
fn max_batch_constant_pinned() {
    assert_eq!(INDEXER_MAX_BATCH_EVENTS, 1024);
}
