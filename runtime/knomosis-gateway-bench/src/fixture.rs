// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The read-only indexer fixture: a SQLite database seeded with
//! `actors × resources` actor balances + a cursor — exactly the shape the
//! gateway's `GET /v1/actors/{id}/balances` read consumes — plus a bearer
//! token file the harness presents.
//!
//! The seeded values are **deterministic** given `(seed, actor, resource)`, so
//! two fixtures with the same [`FixtureConfig`] are byte-identical.  The writer
//! [`knomosis_storage::sqlite::SqliteStorage`] handle is kept **alive** in the
//! returned [`Fixture`] so the gateway's *read-only* handle observes the
//! committed data under SQLite WAL (a read-only connection cannot itself
//! checkpoint — the OQ-GW-13 constraint; keeping the writer alive is the
//! same discipline the gateway's read tests use).

use std::path::PathBuf;

use knomosis_indexer::balance::balance_key;
use knomosis_indexer::cursor::CURSOR_KEY;
use knomosis_storage::sqlite::SqliteStorage;
use knomosis_storage::storage::Storage;

use crate::BENCH_TOKEN;

/// The fixture workload shape.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct FixtureConfig {
    /// Number of seeded actors (ids `0 .. actors`).
    pub actors: usize,
    /// Number of resources seeded per actor (ids `0 .. resources`).
    pub resources: usize,
    /// Deterministic seed mixed into each balance amount.
    pub seed: u64,
}

/// Errors building the fixture.
#[derive(Debug, thiserror::Error)]
pub enum FixtureError {
    /// The temp directory / token file could not be created.
    #[error("fixture I/O error: {0}")]
    Io(#[from] std::io::Error),
    /// The SQLite fixture database could not be opened / written.
    #[error("fixture storage error: {0}")]
    Storage(String),
    /// `actors` or `resources` was zero (an empty fixture is meaningless).
    #[error("fixture must have at least one actor and one resource")]
    Empty,
}

/// A built fixture.  Dropping it removes the temp directory; keep it alive for
/// the whole benchmark run so the gateway's read-only handle stays valid.
pub struct Fixture {
    /// The temp directory (owns the DB + token files; removed on drop).
    _dir: tempfile::TempDir,
    /// The read-only-opened-by-the-gateway indexer database path.
    pub db_path: PathBuf,
    /// The bearer-token file path (mode 0600 on Unix).
    pub token_path: PathBuf,
    /// The live writer handle — kept alive so the gateway's read-only reader
    /// observes the WAL-committed data.
    _writer: SqliteStorage,
    /// The workload shape this fixture was built from.
    pub config: FixtureConfig,
}

/// The deterministic balance amount for `(seed, actor, resource)` — a non-zero,
/// varied value (the exact magnitude is irrelevant; determinism is the point).
#[must_use]
pub fn balance_amount(seed: u64, actor: u64, resource: u64) -> u128 {
    let mix = u128::from(actor)
        .wrapping_mul(1_000_003)
        .wrapping_add(u128::from(resource).wrapping_mul(31))
        .wrapping_add(u128::from(seed & 0xffff));
    mix.wrapping_add(1) // never zero
}

/// Build the fixture: a 0700 temp dir, a 0600 token file, and a SQLite database
/// seeded with `actors × resources` balances + a cursor.
///
/// # Errors
///
/// [`FixtureError::Empty`] for a zero-sized workload, [`FixtureError::Io`] for
/// a filesystem failure, or [`FixtureError::Storage`] for a SQLite failure.
pub fn build(config: FixtureConfig) -> Result<Fixture, FixtureError> {
    if config.actors == 0 || config.resources == 0 {
        return Err(FixtureError::Empty);
    }
    let dir = tempfile::tempdir()?;
    let db_path = dir.path().join("index.db");
    let token_path = dir.path().join("tokens");
    std::fs::write(&token_path, BENCH_TOKEN)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&token_path, std::fs::Permissions::from_mode(0o600))?;
    }

    let writer = SqliteStorage::open(&db_path).map_err(|e| FixtureError::Storage(e.to_string()))?;
    // One transaction for the whole seed — orders of magnitude faster than a
    // per-put WAL commit for a large fixture.
    let mut tx = writer
        .transaction()
        .map_err(|e| FixtureError::Storage(e.to_string()))?;
    for actor in 0..config.actors as u64 {
        for resource in 0..config.resources as u64 {
            let amount = balance_amount(config.seed, actor, resource);
            tx.put(&balance_key(actor, resource), &amount.to_be_bytes())
                .map_err(|e| FixtureError::Storage(e.to_string()))?;
        }
    }
    // A non-zero cursor so the gateway's reads (which pair a cell read with a
    // cursor read for the `X-Knomosis-Seq` / ETag) see a populated index.
    let cursor = config.actors as u64;
    tx.put(CURSOR_KEY, &cursor.to_be_bytes())
        .map_err(|e| FixtureError::Storage(e.to_string()))?;
    tx.commit()
        .map_err(|e| FixtureError::Storage(e.to_string()))?;

    Ok(Fixture {
        _dir: dir,
        db_path,
        token_path,
        _writer: writer,
        config,
    })
}

#[cfg(test)]
mod tests {
    use super::{balance_amount, build, FixtureConfig, FixtureError};
    use knomosis_indexer::balance::BalanceView;
    use knomosis_storage::sqlite::{ReadOnlyOpenOptions, SqliteStorage};

    fn config(actors: usize, resources: usize) -> FixtureConfig {
        FixtureConfig {
            actors,
            resources,
            seed: 7,
        }
    }

    #[test]
    fn balance_amount_is_deterministic_and_nonzero() {
        assert_eq!(balance_amount(7, 3, 1), balance_amount(7, 3, 1));
        assert_ne!(balance_amount(7, 3, 1), balance_amount(7, 4, 1));
        assert_ne!(balance_amount(7, 3, 1), balance_amount(7, 3, 0));
        assert!(balance_amount(0, 0, 0) > 0);
    }

    #[test]
    fn seeded_balances_are_readable_read_only() {
        let fx = build(config(5, 2)).expect("build fixture");
        // Open a SECOND read-only handle (as the gateway does) while the
        // fixture writer is still alive.
        let ro = SqliteStorage::open_read_only(&fx.db_path, &ReadOnlyOpenOptions::new())
            .expect("read-only open");
        let view = BalanceView::new(&ro);
        for actor in 0..5u64 {
            for resource in 0..2u64 {
                let got = view.get(actor, resource).expect("read balance");
                assert_eq!(got, balance_amount(7, actor, resource));
            }
        }
        // An unseeded actor reads back the kernel's "no cell ⇒ zero".
        assert_eq!(view.get(99, 0).expect("read"), 0);
    }

    #[test]
    fn empty_workload_is_rejected() {
        assert!(matches!(build(config(0, 2)), Err(FixtureError::Empty)));
        assert!(matches!(build(config(2, 0)), Err(FixtureError::Empty)));
    }

    #[test]
    fn token_file_is_written_owner_only() {
        let fx = build(config(2, 1)).expect("build");
        assert_eq!(
            std::fs::read_to_string(&fx.token_path).unwrap(),
            crate::BENCH_TOKEN
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&fx.token_path)
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(
                mode & 0o077,
                0,
                "token file must not be group/other-accessible"
            );
        }
    }
}
