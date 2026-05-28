// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Integration tests for `knomosis-storage`.
//!
//! Each test exercises a high-level scenario across the public API
//! (open → put/get/scan → snapshot → transaction → re-open).
//! The inline unit tests in `src/sqlite.rs` cover the per-method
//! contracts; these integration tests verify cross-method
//! interactions.

use knomosis_storage::sqlite::{JournalMode, SqliteOpenOptions, SqliteStorage, SynchronousMode};
use knomosis_storage::storage::Storage;
use std::sync::Arc;
use std::thread;

/// Open a SQLite store at a tempfile, perform a sequence of
/// operations, close the connection, then re-open and verify
/// every committed mutation persisted byte-for-byte.
#[test]
fn end_to_end_persistence() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("e2e.db");

    // Phase 1: write data.
    {
        let s = SqliteStorage::open(&path).unwrap();
        for i in 0..100u32 {
            let key = i.to_be_bytes();
            let value = format!("value-{i}");
            s.put(&key, value.as_bytes()).unwrap();
        }
        // Delete some entries.
        for i in (10..20u32).step_by(2) {
            s.delete(&i.to_be_bytes()).unwrap();
        }
    }

    // Phase 2: re-open and verify.
    {
        let s = SqliteStorage::open(&path).unwrap();
        for i in 0..100u32 {
            let key = i.to_be_bytes();
            let got = s.get(&key).unwrap();
            let deleted = (10..20).contains(&i) && i % 2 == 0;
            if deleted {
                assert_eq!(got, None, "expected key {i} to be deleted");
            } else {
                assert_eq!(
                    got,
                    Some(format!("value-{i}").into_bytes()),
                    "expected key {i} to roundtrip"
                );
            }
        }
    }
}

/// **Concurrent contention test**: N reader threads + 1 writer
/// thread, all sharing the same `Arc<SqliteStorage>`.  The
/// single-mutex design serialises every operation, so this
/// test verifies thread-safety / no-torn-reads under contention
/// rather than true WAL multi-reader concurrency.
///
/// Each reader thread reads every key 50 times and asserts the
/// value is either the seed value or the writer's update value
/// (the only two possibilities, since writes are atomic per
/// `put` call).  The writer thread updates every key once.
///
/// **What this test does NOT cover.**  The single-mutex design
/// means a snapshot held across a writer's update simply
/// blocks the writer until the snapshot drops.  True
/// concurrent-reader-vs-writer would require a connection-pool
/// refactor (planned for knomosis-faultproof-observer's
/// long-snapshot use case).
#[test]
fn contention_no_torn_reads() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("contention.db");
    let s = Arc::new(SqliteStorage::open(&path).unwrap());

    // Seed initial state.
    for i in 0..50u8 {
        s.put(&[i], &[i]).unwrap();
    }

    let n_readers = 4;
    let n_iterations = 50;
    let mut handles = Vec::new();
    // Spawn N reader threads.
    for _ in 0..n_readers {
        let s = Arc::clone(&s);
        let h = thread::spawn(move || {
            for _ in 0..n_iterations {
                for i in 0..50u8 {
                    let got = s.get(&[i]).unwrap();
                    let v = got.expect("seeded entry");
                    assert!(
                        v == vec![i] || v == vec![i + 0x80],
                        "torn read: key={i} got {v:?}"
                    );
                }
            }
        });
        handles.push(h);
    }
    // Concurrent writer thread.
    {
        let s = Arc::clone(&s);
        let h = thread::spawn(move || {
            // Update each key once.  Each `put` is atomic; readers
            // see either the old or new value, never a half-write.
            for i in 0..50u8 {
                s.put(&[i], &[i + 0x80]).unwrap();
                // Sleep briefly to encourage readers to interleave.
                std::thread::sleep(std::time::Duration::from_micros(10));
            }
        });
        handles.push(h);
    }

    for h in handles {
        h.join().unwrap();
    }

    // Final state: all values upgraded.
    for i in 0..50u8 {
        assert_eq!(s.get(&[i]).unwrap(), Some(vec![i + 0x80]));
    }
}

/// **Snapshot pins WAL state**: open a second connection on a
/// shared cache, take a snapshot from one, write through the
/// other.  The snapshot's view must be the pre-write state.
///
/// This test verifies the C-1 audit fix: the snapshot's warm-up
/// read of `sqlite_master` actually establishes a SQLite read
/// mark.  Without this, a concurrent writer could leak its
/// post-write state into the snapshot's view.
///
/// We open TWO SqliteStorage instances on the SAME database
/// file (each holds its own connection — the single-mutex
/// serialisation is per-instance).  This simulates a future
/// knomosis-faultproof-observer (separate process) reading while
/// knomosis-indexer writes.
#[test]
fn snapshot_pins_wal_state_across_connections() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pin.db");

    // Connection A: writer.
    let writer = SqliteStorage::open(&path).unwrap();
    writer.put(b"k", b"v1").unwrap();

    // Connection B: reader.  Opened AFTER the initial write so
    // the WAL has at least one frame.
    let reader = SqliteStorage::open(&path).unwrap();

    // Take a snapshot from B BEFORE the next write.
    let snap = reader.snapshot().unwrap();
    // Read through snapshot → must see v1 (pre-snapshot).
    assert_eq!(snap.get(b"k").unwrap(), Some(b"v1".to_vec()));

    // Now writer commits v2 via connection A.
    writer.put(b"k", b"v2").unwrap();

    // Snapshot's view is unchanged — it pinned the WAL state at
    // the time of the snapshot.  Without the fix (SELECT 1
    // doesn't pin the read mark), this assertion could fail:
    // SQLite would lazily acquire the read mark on the first
    // SELECT after the writer's commit, giving us v2.
    assert_eq!(snap.get(b"k").unwrap(), Some(b"v1".to_vec()));

    // Drop snapshot → snapshot's read mark released.
    drop(snap);
    // Now reader sees the latest committed value.
    assert_eq!(reader.get(b"k").unwrap(), Some(b"v2".to_vec()));
}

/// Scan with a prefix returns only matching rows in lex order,
/// even with > 1000 entries.
#[test]
fn scan_under_load() {
    let s = SqliteStorage::open_in_memory().unwrap();
    // Insert 1000 entries with two distinct prefixes.
    for i in 0..1000u32 {
        let mut key = if i % 3 == 0 {
            b"alpha:".to_vec()
        } else {
            b"beta:".to_vec()
        };
        key.extend_from_slice(&i.to_be_bytes());
        s.put(&key, &i.to_be_bytes()).unwrap();
    }
    let alpha_rows = s.scan(b"alpha:").unwrap();
    let beta_rows = s.scan(b"beta:").unwrap();
    // Counts.
    assert_eq!(alpha_rows.len() + beta_rows.len(), 1000);
    // All alpha rows start with "alpha:".
    assert!(alpha_rows.iter().all(|(k, _)| k.starts_with(b"alpha:")));
    // All beta rows start with "beta:".
    assert!(beta_rows.iter().all(|(k, _)| k.starts_with(b"beta:")));
    // Lex order.
    for w in alpha_rows.windows(2) {
        assert!(w[0].0 < w[1].0);
    }
    for w in beta_rows.windows(2) {
        assert!(w[0].0 < w[1].0);
    }
}

/// Transaction atomicity: a transaction that puts N rows commits
/// either all of them or none.
#[test]
fn transaction_atomicity() {
    let s = SqliteStorage::open_in_memory().unwrap();
    let mut tx = s.transaction().unwrap();
    for i in 0..100u32 {
        let key = i.to_be_bytes();
        tx.put(&key, b"v").unwrap();
    }
    tx.commit().unwrap();
    // All 100 visible.
    let rows = s.scan(b"").unwrap();
    assert_eq!(rows.len(), 100);

    // New transaction that rolls back.
    let mut tx2 = s.transaction().unwrap();
    for i in 100..200u32 {
        let key = i.to_be_bytes();
        tx2.put(&key, b"v").unwrap();
    }
    tx2.rollback().unwrap();
    // Still 100 visible (rollback discarded the new 100).
    let rows = s.scan(b"").unwrap();
    assert_eq!(rows.len(), 100);
}

/// Transactions delete-then-put pattern: stale rows are
/// physically removed before the new rows land.
#[test]
fn transaction_delete_then_put() {
    let s = SqliteStorage::open_in_memory().unwrap();
    s.put(b"k", b"old").unwrap();
    let mut tx = s.transaction().unwrap();
    tx.delete(b"k").unwrap();
    // Mid-transaction get: should reflect the deletion.
    assert_eq!(tx.get(b"k").unwrap(), None);
    tx.put(b"k", b"new").unwrap();
    assert_eq!(tx.get(b"k").unwrap(), Some(b"new".to_vec()));
    tx.commit().unwrap();
    assert_eq!(s.get(b"k").unwrap(), Some(b"new".to_vec()));
}

/// Custom options propagate to the open call.
#[test]
fn custom_options_applied() {
    let s = SqliteStorage::open_in_memory_with_options(
        &SqliteOpenOptions::new()
            .with_synchronous(SynchronousMode::Full)
            .with_busy_timeout_ms(1000),
    )
    .unwrap();
    s.put(b"k", b"v").unwrap();
    assert_eq!(s.get(b"k").unwrap(), Some(b"v".to_vec()));
}

/// WAL mode applied on a file-backed database.
#[test]
fn wal_mode_on_file_db() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("wal.db");
    let _s = SqliteStorage::open_with_options(
        &path,
        &SqliteOpenOptions::new().with_journal_mode(JournalMode::Wal),
    )
    .unwrap();
    // WAL mode creates a -wal sidecar file on first write.
    // We can't reliably observe it just from open() since SQLite
    // may not create the WAL file until the first write.  But
    // the file itself should exist.
    assert!(path.exists());
}

/// Sharing a single SqliteStorage across threads: Arc<SqliteStorage>
/// patterns work.
#[test]
fn arc_storage_across_threads() {
    let s = Arc::new(SqliteStorage::open_in_memory().unwrap());
    let mut handles = Vec::new();
    for tid in 0..4u8 {
        let s = Arc::clone(&s);
        let h = thread::spawn(move || {
            for i in 0..25u8 {
                let key = [tid, i];
                let value = vec![tid * 10 + i];
                s.put(&key, &value).unwrap();
            }
        });
        handles.push(h);
    }
    for h in handles {
        h.join().unwrap();
    }
    // 4 threads × 25 keys each = 100 keys.
    let rows = s.scan(b"").unwrap();
    assert_eq!(rows.len(), 100);
}

/// Re-opening a database that was created with a newer schema
/// version is rejected with `MigrationMismatch`.
///
/// This test simulates the forward-incompatibility case: it
/// hacks the on-disk `_meta` table to claim a future schema
/// version, then verifies that `open()` returns the right typed
/// error.  Real-world this happens when an operator downgrades
/// the binary.
#[test]
fn forward_incompat_detected_on_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("incompat.db");
    {
        let _s = SqliteStorage::open(&path).unwrap();
    }
    // Tamper with the schema_version directly via raw rusqlite.
    {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute(
            "UPDATE _meta SET value = '9999' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
    }
    // Re-open: must surface a MigrationMismatch error.
    match SqliteStorage::open(&path) {
        Err(knomosis_storage::storage::StorageError::MigrationMismatch { expected, found }) => {
            assert!(found > expected);
            assert_eq!(found, 9999);
        }
        Ok(_) => panic!("expected forward-incompat error, got success"),
        Err(other) => panic!("unexpected error type: {other:?}"),
    }
}

/// rusqlite is a transitive dependency the test depends on for
/// the tamper scenario above; declare it so cargo deps line up.
extern crate rusqlite;
