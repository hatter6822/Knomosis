// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Gateway G1.6a acceptance: the indexer's `BalanceView` and
//! `BudgetReadView` read views function over a
//! `knomosis_storage::sqlite::SqliteStorage::open_read_only` handle
//! while the writer is live — the read-only path the Knomosis
//! gateway uses for its balance / budget / pool endpoints.
//!
//! This pins the empirical resolution of the plan's open question
//! ("does a pure `SQLITE_OPEN_READ_ONLY` handle suffice, or is the
//! `query_only` fallback needed?"): pure read-only suffices for
//! every indexer read view, INCLUDING `remaining_this_epoch`, which
//! now uses a `BEGIN DEFERRED` combined-read rather than a `BEGIN
//! IMMEDIATE` write lock.

use knomosis_indexer::balance::{balance_key, BalanceView};
use knomosis_indexer::budget_view::BudgetReadView;
use knomosis_storage::sqlite::{ReadOnlyOpenOptions, SqliteStorage};
use knomosis_storage::storage::Storage;

/// Seed a schema-v2 on-disk WAL database with one balance cell, the
/// deployment-identity cell, and one actor's epoch budget counters
/// via the write path.  Returns the LIVE writer (kept open so the
/// read-only reader can map the WAL `-shm`/`-wal` sidecars) + path.
fn seed(dir: &tempfile::TempDir) -> (SqliteStorage, std::path::PathBuf) {
    let path = dir.path().join("index.db");
    let writer = SqliteStorage::open(&path).unwrap();
    // Balance: actor 7, resource 0 (ETH) = 1_000 (16-byte BE u128).
    writer
        .put(&balance_key(7, 0), &1_000u128.to_be_bytes())
        .unwrap();
    // Deployment-identity cell (UTF-8; see indexer storage layout).
    writer.put(b"c/identifier", b"deployment-alpha").unwrap();
    // Epoch budget counters for actor 7: grants 100, consumed 30.
    let mut tx = writer.combined_transaction().unwrap();
    tx.credit_actor_budget_current_epoch_grants(7, 100).unwrap();
    tx.credit_actor_budget_current_epoch_consumed(7, 30)
        .unwrap();
    tx.commit().unwrap();
    (writer, path)
}

/// `BalanceView` (`get` + `scan_all`) reads correct values over a
/// read-only handle.
#[test]
fn balance_view_reads_over_read_only_handle() {
    let dir = tempfile::tempdir().unwrap();
    let (writer, path) = seed(&dir);
    let ro = SqliteStorage::open_read_only(&path, &ReadOnlyOpenOptions::new()).unwrap();
    let view = BalanceView::new(&ro);
    assert_eq!(view.get(7, 0).unwrap(), 1_000);
    assert_eq!(view.get(7, 1).unwrap(), 0, "absent cell reads as 0");
    assert_eq!(view.scan_all().unwrap(), vec![(7, 0, 1_000)]);
    drop(writer);
}

/// `BudgetReadView` — including `remaining_this_epoch`, the method
/// that previously took a `BEGIN IMMEDIATE` write lock — reads
/// correctly over a read-only handle.  This is the headline G1.6a
/// acceptance.
#[test]
fn budget_view_reads_over_read_only_handle() {
    let dir = tempfile::tempdir().unwrap();
    let (writer, path) = seed(&dir);
    let ro = SqliteStorage::open_read_only(&path, &ReadOnlyOpenOptions::new()).unwrap();
    let view = BudgetReadView::new(&ro);
    assert_eq!(view.get_actor_budget_current_epoch_grants(7).unwrap(), 100);
    assert_eq!(view.get_actor_budget_current_epoch_consumed(7).unwrap(), 30);
    // free_tier 50: remaining = 50 + 100 − 30 = 120.
    assert_eq!(view.remaining_this_epoch(7, 50).unwrap(), 120);
    // An actor with no budget cells: remaining = free_tier only.
    assert_eq!(view.remaining_this_epoch(999, 50).unwrap(), 50);
    drop(writer);
}

/// The `required_kv` deployment-identity guard composes with the
/// indexer's `c/identifier` cell: a matching identity opens, a
/// mismatch is refused.
#[test]
fn read_only_identity_guard_matches_indexer_cell() {
    let dir = tempfile::tempdir().unwrap();
    let (writer, path) = seed(&dir);
    let ok = ReadOnlyOpenOptions::new()
        .with_required_cell(b"c/identifier".to_vec(), b"deployment-alpha".to_vec());
    assert!(SqliteStorage::open_read_only(&path, &ok).is_ok());
    let bad = ReadOnlyOpenOptions::new()
        .with_required_cell(b"c/identifier".to_vec(), b"other-deployment".to_vec());
    assert!(SqliteStorage::open_read_only(&path, &bad).is_err());
    drop(writer);
}
