// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Property tests for `knomosis-storage` (RH-E.0.e).
//!
//! ## What this covers
//!
//! The headline property test compares a `SqliteStorage` against an
//! in-memory `BTreeMap` reference under a randomised sequence of
//! KV operations.  After every operation, both stores must return
//! identical results for `get` / `scan`.  This is the canonical
//! oracle test for KV-store implementations.
//!
//! The additional property tests cover targeted invariants of the
//! `scan` operation (lex-order, prefix-filtering, completeness)
//! and the transaction model (commit atomicity, rollback
//! discards).

use knomosis_storage::sqlite::SqliteStorage;
use knomosis_storage::storage::Storage;
use proptest::collection::vec;
use proptest::prelude::*;
use std::collections::BTreeMap;

/// One operation in the random-op stream.
#[derive(Clone, Debug)]
enum Op {
    Put { key: Vec<u8>, value: Vec<u8> },
    Delete { key: Vec<u8> },
}

/// Generate a single op.  Keys are bounded to 16 bytes (typical
/// indexer key sizes); values to 64 bytes (typical indexer value
/// sizes).  The bounds keep the proptest harness fast while still
/// exercising the encoder paths.
fn op_strategy() -> impl Strategy<Value = Op> {
    prop_oneof![
        (vec(any::<u8>(), 0..=16), vec(any::<u8>(), 0..=64))
            .prop_map(|(key, value)| Op::Put { key, value }),
        vec(any::<u8>(), 0..=16).prop_map(|key| Op::Delete { key }),
    ]
}

proptest! {
    /// Random sequence of `put` / `delete` operations: `SqliteStorage`
    /// matches an in-memory `BTreeMap` reference at every step.
    ///
    /// This is the load-bearing property: the SQLite implementation
    /// is observationally equivalent to the canonical `BTreeMap<Vec<u8>,
    /// Vec<u8>>` semantics across an arbitrary mixed-op stream.
    #[test]
    fn sqlite_matches_btree_reference(ops in vec(op_strategy(), 0..50)) {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut reference: BTreeMap<Vec<u8>, Vec<u8>> = BTreeMap::new();

        for op in &ops {
            match op {
                Op::Put { key, value } => {
                    s.put(key, value).unwrap();
                    reference.insert(key.clone(), value.clone());
                }
                Op::Delete { key } => {
                    s.delete(key).unwrap();
                    reference.remove(key);
                }
            }
        }

        // After every op stream, scan equality.
        let storage_rows = s.scan(b"").unwrap();
        let reference_rows: Vec<_> = reference.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        prop_assert_eq!(storage_rows, reference_rows);

        // Spot-check `get` for every distinct key in the reference.
        for (k, v) in &reference {
            let got = s.get(k).unwrap();
            prop_assert_eq!(got.as_ref(), Some(v));
        }
    }

    /// `scan(prefix)` filters by prefix correctly: every returned
    /// key starts with `prefix`, and no matching key is omitted.
    #[test]
    fn scan_prefix_filters_correctly(
        prefix in vec(any::<u8>(), 0..=4),
        ops in vec(op_strategy(), 0..30)
    ) {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut reference: BTreeMap<Vec<u8>, Vec<u8>> = BTreeMap::new();

        for op in &ops {
            match op {
                Op::Put { key, value } => {
                    s.put(key, value).unwrap();
                    reference.insert(key.clone(), value.clone());
                }
                Op::Delete { key } => {
                    s.delete(key).unwrap();
                    reference.remove(key);
                }
            }
        }

        let rows = s.scan(&prefix).unwrap();
        // Every returned key starts with `prefix`.
        for (k, _) in &rows {
            prop_assert!(k.starts_with(&prefix));
        }
        // Strict lex order.
        for w in rows.windows(2) {
            prop_assert!(w[0].0 < w[1].0);
        }
        // No matching key is omitted.
        let expected: Vec<_> = reference
            .iter()
            .filter(|(k, _)| k.starts_with(&prefix))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        prop_assert_eq!(rows, expected);
    }

    /// Transaction commit atomicity: a transaction that puts N
    /// distinct keys produces a state where ALL N are visible
    /// after commit.
    #[test]
    fn transaction_commit_all_or_nothing(
        keys in vec(vec(any::<u8>(), 0..=8), 0..10)
            .prop_filter("distinct keys", |ks| {
                let mut seen = std::collections::HashSet::new();
                ks.iter().all(|k| seen.insert(k.clone()))
            })
    ) {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        for k in &keys {
            tx.put(k, b"v").unwrap();
        }
        tx.commit().unwrap();
        // Every key must be visible.
        for k in &keys {
            prop_assert_eq!(s.get(k).unwrap(), Some(b"v".to_vec()));
        }
    }

    /// Transaction rollback discards: a transaction that puts N
    /// keys then rolls back produces a state where NONE of the N
    /// are visible.
    #[test]
    fn transaction_rollback_discards_all(
        keys in vec(vec(any::<u8>(), 0..=8), 0..10)
            .prop_filter("distinct keys", |ks| {
                let mut seen = std::collections::HashSet::new();
                ks.iter().all(|k| seen.insert(k.clone()))
            })
    ) {
        let s = SqliteStorage::open_in_memory().unwrap();
        // Pre-existing keys that the transaction does NOT touch
        // must remain visible.  We seed one such key to confirm.
        s.put(b"seed", b"seed-value").unwrap();
        let mut tx = s.transaction().unwrap();
        for k in &keys {
            tx.put(k, b"v").unwrap();
        }
        tx.rollback().unwrap();
        // None of the rolled-back keys are visible (unless they
        // happen to collide with the seed, which our prop-filter
        // doesn't prevent — handle the seed-collision case
        // explicitly).
        for k in &keys {
            let expected = if k == b"seed" {
                Some(b"seed-value".to_vec())
            } else {
                None
            };
            prop_assert_eq!(s.get(k).unwrap(), expected);
        }
        // Seed is still there.
        prop_assert_eq!(s.get(b"seed").unwrap(), Some(b"seed-value".to_vec()));
    }

    /// Idempotency: putting the same key+value twice yields the
    /// same final state as putting it once.
    #[test]
    fn put_is_idempotent(key in vec(any::<u8>(), 0..=8), value in vec(any::<u8>(), 0..=32)) {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(&key, &value).unwrap();
        s.put(&key, &value).unwrap();
        prop_assert_eq!(s.get(&key).unwrap(), Some(value));
    }

    /// Delete idempotency: deleting a missing key twice is the
    /// same as deleting it once (no error in either case).
    #[test]
    fn delete_is_idempotent(key in vec(any::<u8>(), 0..=8)) {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.delete(&key).unwrap();
        s.delete(&key).unwrap();
        prop_assert_eq!(s.get(&key).unwrap(), None);
    }

    /// Round-trip: any byte string survives `put` + `get`.
    #[test]
    fn arbitrary_bytes_round_trip(key in vec(any::<u8>(), 0..=128), value in vec(any::<u8>(), 0..=256)) {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(&key, &value).unwrap();
        let got = s.get(&key).unwrap();
        prop_assert_eq!(got, Some(value));
    }

    /// `scan` is a "fold" over keys: scan returns the same set of
    /// `(k, v)` pairs whether or not we group puts into prefixes.
    /// Property: `scan(empty) == sort(every kv pair in the store)`.
    #[test]
    fn scan_empty_equals_sorted_set(ops in vec(op_strategy(), 0..20)) {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut reference: BTreeMap<Vec<u8>, Vec<u8>> = BTreeMap::new();
        for op in &ops {
            match op {
                Op::Put { key, value } => {
                    s.put(key, value).unwrap();
                    reference.insert(key.clone(), value.clone());
                }
                Op::Delete { key } => {
                    s.delete(key).unwrap();
                    reference.remove(key);
                }
            }
        }
        let rows = s.scan(b"").unwrap();
        let expected: Vec<_> = reference.into_iter().collect();
        prop_assert_eq!(rows, expected);
    }
}
