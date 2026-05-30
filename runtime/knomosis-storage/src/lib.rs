// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-storage` — RH-E.0.
//!
//! Storage abstraction crate + SQLite-backed implementation shared
//! by `knomosis-indexer` (RH-E.1) and `knomosis-faultproof-observer`
//! (RH-G).  See `docs/planning/rust_host_runtime_plan.md` §RH-E.0
//! for the engineering plan.
//!
//! ## What this crate provides
//!
//!   * [`storage`] — the [`storage::Storage`] /
//!     [`storage::StorageSnapshot`] / [`storage::StorageTransaction`]
//!     traits.  Byte-array-key, byte-array-value KV abstraction with
//!     a documented lexicographic-scan-order contract.
//!   * [`sqlite`] — [`sqlite::SqliteStorage`], a SQLite-backed
//!     implementation of [`storage::Storage`] using a single-table
//!     schema (`kv(key BLOB PRIMARY KEY, value BLOB NOT NULL)`)
//!     under WAL mode.  Each `transaction()` call wraps a single
//!     SQLite `BEGIN ... COMMIT` block; `snapshot()` uses
//!     `BEGIN DEFERRED` to pin a consistent read view.
//!   * [`migration`] — append-only migration scaffolding.  Schema
//!     version is recorded in a `_meta(key TEXT PRIMARY KEY, value
//!     TEXT NOT NULL)` table; new migrations are appended to the
//!     fixed [`migration::MIGRATIONS`] table and run on first open
//!     against a database carrying the previous version.
//!
//! ## Trait surface
//!
//! The [`storage::Storage`] trait exposes five methods plus two
//! higher-order constructors:
//!
//! ```text
//!   fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>>;
//!   fn put(&self, key: &[u8], value: &[u8]) -> Result<()>;
//!   fn delete(&self, key: &[u8]) -> Result<()>;
//!   fn scan(&self, prefix: &[u8]) -> Result<Vec<(Vec<u8>, Vec<u8>)>>;
//!   fn snapshot(&self) -> Result<Box<dyn StorageSnapshot>>;
//!   fn transaction(&self) -> Result<Box<dyn StorageTransaction>>;
//! ```
//!
//! ## Byte-array-key contract
//!
//! Keys and values are opaque `&[u8]` to the storage layer.  Callers
//! that need structured keys (e.g. `(actor, resource)` for the
//! balance view) **must** encode them as fixed-length BE bytes so
//! lexicographic ordering matches the intended key ordering.  This
//! mirrors the standard KV-store discipline (RocksDB, LMDB, etc.).
//!
//! `scan(prefix)` returns every `(key, value)` pair whose key starts
//! with `prefix`, in **strict lexicographic order**.  An empty prefix
//! returns the entire table.
//!
//! ## Concurrency model (single-mutex)
//!
//! [`sqlite::SqliteStorage`] is `Send + Sync` and may be shared via
//! `Arc<SqliteStorage>`.  The implementation wraps a single
//! `rusqlite::Connection` in a `std::sync::Mutex` — **every
//! operation (`get`, `put`, `delete`, `scan`, `snapshot`,
//! `transaction`) acquires this single mutex**.  WAL mode is
//! enabled for crash recovery, NOT for reader/writer concurrency:
//!
//!   * Two concurrent `get` calls SERIALISE through the mutex.
//!   * A live `snapshot` BLOCKS every other operation for its
//!     entire lifetime (until the snapshot is dropped).
//!   * A live `transaction` BLOCKS every other operation similarly.
//!
//! This is the simplest correct design for `knomosis-indexer`'s
//! single-threaded event-consumption pattern (one writer thread,
//! short transactions, no long-lived snapshots).  Workstreams that
//! need true reader/writer concurrency (RH-G's
//! `knomosis-faultproof-observer`, which holds a snapshot across hours-
//! long bisection games) require either:
//!
//!   1. A future connection-pool refactor of this crate, OR
//!   2. Opening a second `SqliteStorage` against the same database
//!      file (each holds its own connection).
//!
//! We use `std::sync` rather than `tokio::sync` because the
//! workspace consistently avoids an async runtime (matches
//! knomosis-host / knomosis-l1-ingest / knomosis-event-subscribe).
//!
//! ## Snapshot consistency
//!
//! A [`storage::StorageSnapshot`] is a read-only view of the
//! database pinned at the moment [`storage::Storage::snapshot`] was
//! called.  Implementation: `BEGIN DEFERRED;` followed by a forced
//! read of `sqlite_master` (a real table — SQLite's WAL read mark
//! is established by the first SELECT that touches a real table,
//! NOT by `BEGIN` and NOT by `SELECT 1` on no table).  All
//! subsequent reads through the snapshot see the same WAL state.
//! Drop the snapshot to release the read lock.
//!
//! With the single-mutex design above, concurrent writers can't
//! actually happen WITHIN this process — but the snapshot's WAL
//! pinning still matters when a second process opens the same
//! database file (e.g., a future knomosis-faultproof-observer reading
//! while knomosis-indexer writes).
//!
//! ## Migration scaffolding
//!
//! Schema migrations are **append-only**: once a migration index is
//! published, its body is never modified.  Down-migrations are not
//! supported in v1 (operators handle rollback via SQLite's online
//! backup API or a filesystem snapshot).  See [`migration`] for the
//! per-step contract.
//!
//! ## Security posture
//!
//!   * `unsafe_code = "forbid"` workspace lint.  No FFI surface.
//!   * Every error path returns a typed [`storage::StorageError`];
//!     no `panic!` on attacker-supplied bytes.
//!   * SQL is constructed exclusively via prepared statements with
//!     bound parameters — no string interpolation.  Defends against
//!     SQL injection at the type system level even though the
//!     caller never supplies SQL.
//!   * Database files are opened with `OpenFlags::SQLITE_OPEN_READ_WRITE
//!     | SQLITE_OPEN_CREATE`; the parent directory is not modified
//!     beyond the file itself plus the `*-wal` / `*-shm` sidecars.

#![doc(html_root_url = "https://docs.rs/knomosis-storage/0.2.0")]

pub mod budget_storage;
pub mod migration;
pub mod sqlite;
pub mod storage;

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "knomosis-storage";

/// The crate's published version (auto-populated by `cargo` from
/// `Cargo.toml`).  Mirrors `knomosis-cli-common::VERSION`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The implementation identifier this storage layer publishes
/// through startup diagnostics.  Mirrors `knomosis-host`'s
/// `HOST_IDENTIFIER` pattern and is part of the cross-stack version
/// surface (operators can grep logs for the identifier to confirm
/// the deployed storage layer's version).
pub const STORAGE_IDENTIFIER: &str = "knomosis-storage/v1";

#[cfg(test)]
mod tests {
    use super::{CRATE_NAME, STORAGE_IDENTIFIER, VERSION};

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "knomosis-storage");
    }

    /// Identifier constant is the documented v1 string.
    #[test]
    fn identifier_constant() {
        assert_eq!(STORAGE_IDENTIFIER, "knomosis-storage/v1");
    }

    /// Version constant matches the workspace package version.
    #[test]
    fn version_constant_non_empty() {
        // Sanity: must start with a digit (semver `x.y.z`).
        // clippy::const_is_empty is `allow`-ed because the value is
        // injected at build time by cargo, not literal in source.
        #[allow(clippy::const_is_empty)]
        let v: &str = VERSION;
        assert!(v.chars().next().is_some_and(|c| c.is_ascii_digit()));
    }
}
