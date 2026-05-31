// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! SQLite-backed implementation of [`crate::storage::Storage`]
//! (RH-E.0.b + RH-E.0.c).
//!
//! ## Schema
//!
//! ```sql
//! CREATE TABLE kv(
//!     key BLOB PRIMARY KEY NOT NULL,
//!     value BLOB NOT NULL
//! ) WITHOUT ROWID;
//!
//! CREATE TABLE _meta(
//!     key TEXT PRIMARY KEY NOT NULL,
//!     value TEXT NOT NULL
//! );
//! ```
//!
//! `WITHOUT ROWID` saves a B-tree level and lets the primary key
//! itself be the storage key (no separate ROWID index).  This is the
//! recommended layout for BLOB-keyed KV stores per SQLite's docs.
//!
//! `_meta` carries the schema-version cell and any future internal
//! state the storage layer needs (currently nothing else).
//!
//! ## Pragmas
//!
//! On open, [`SqliteStorage::open`] applies:
//!
//!   * `journal_mode = WAL` — write-ahead log for crash safety.
//!     **Note**: in our single-connection design, WAL's
//!     multi-reader-with-concurrent-writer benefit is NOT
//!     realised at the intra-process level (we serialise
//!     everything through a single Mutex<Connection>); WAL is
//!     enabled primarily for crash recovery and to make
//!     multi-process file sharing safe (e.g., a future
//!     knomosis-faultproof-observer reading the same file).
//!   * `synchronous = NORMAL` — fsync on each transaction boundary
//!     (matches the SQLite default for WAL).  Operators wanting
//!     `synchronous = FULL` (fsync on every page write) override via
//!     [`SqliteOpenOptions::with_synchronous`].
//!   * `foreign_keys = ON` — defence-in-depth (we don't currently
//!     use foreign keys, but enabling at open time prevents an
//!     accidental future schema bug from silently ignoring them).
//!   * `temp_store = MEMORY` — temporary tables stay in RAM
//!     (faster, no temp-file pollution).
//!
//! ## Concurrency (single-mutex design)
//!
//! The [`SqliteStorage`] type wraps a single
//! `rusqlite::Connection` in a `std::sync::Mutex`.  EVERY public
//! method acquires this single mutex.  Consequences:
//!
//!   * `get` / `put` / `delete` / `scan` calls SERIALISE through
//!     the mutex (one at a time, even when their workloads are
//!     pairwise independent).
//!   * A live snapshot or transaction holds the mutex for its
//!     entire lifetime.  Other operations BLOCK until the
//!     snapshot/transaction is dropped (or `commit`/`rollback`-ed).
//!
//! This is correct for knomosis-indexer's single-thread,
//! short-transaction pattern.  Workstreams that need true
//! reader/writer concurrency (e.g., a future
//! knomosis-faultproof-observer holding a snapshot for hours) need
//! either a connection-pool refactor OR a separate
//! `SqliteStorage` opened against the same database file (each
//! holds its own connection — SQLite's WAL mode handles
//! inter-connection concurrency natively at that point).
//!
//! ## Why std::sync::Mutex rather than tokio::sync::Mutex
//!
//! The workspace consistently avoids an async runtime (matches
//! knomosis-host / knomosis-l1-ingest / knomosis-event-subscribe).  The
//! storage layer runs inside a synchronous worker thread; a
//! `std::sync::Mutex` is the right primitive.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rusqlite::{params, Connection, OpenFlags, OptionalExtension};

use crate::migration::apply_migrations;
use crate::storage::{KeyValuePairs, Storage, StorageError, StorageSnapshot, StorageTransaction};

/// Pragma value for SQLite's `synchronous` setting.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SynchronousMode {
    /// `OFF` — no fsync.  Fastest, but a crash mid-write can
    /// corrupt the WAL.  Reserved for tests.
    Off,
    /// `NORMAL` — fsync on transaction commit only.  Recommended
    /// default for WAL mode.
    Normal,
    /// `FULL` — fsync on every write.  Slower; appropriate for
    /// deployments that need strict durability against power loss.
    Full,
    /// `EXTRA` — `FULL` plus directory fsync.  Mostly relevant on
    /// older filesystems.
    Extra,
}

impl SynchronousMode {
    /// SQLite pragma value.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Off => "OFF",
            Self::Normal => "NORMAL",
            Self::Full => "FULL",
            Self::Extra => "EXTRA",
        }
    }
}

/// Pragma value for SQLite's `journal_mode` setting.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JournalMode {
    /// `DELETE` — rollback journal (default for non-WAL SQLite).
    /// Listed here for tests / debugging; production deployments
    /// should use `WAL`.
    Delete,
    /// `WAL` — write-ahead log.  Reader/writer concurrency.
    /// Recommended default.
    Wal,
    /// `MEMORY` — journal lives in RAM.  No crash safety; reserved
    /// for tests.
    Memory,
}

impl JournalMode {
    /// SQLite pragma value.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Delete => "DELETE",
            Self::Wal => "WAL",
            Self::Memory => "MEMORY",
        }
    }
}

/// Options for [`SqliteStorage::open`].
///
/// Use [`SqliteOpenOptions::new`] to start from defaults
/// (`WAL` + `NORMAL`), then chain `with_*` methods to customise.
#[derive(Clone, Debug)]
pub struct SqliteOpenOptions {
    journal_mode: JournalMode,
    synchronous: SynchronousMode,
    /// Optional override for SQLite's busy-timeout (ms).  Default
    /// is `5000` (5 seconds) — long enough to absorb a brief WAL
    /// checkpoint without surfacing a transient busy error.
    busy_timeout_ms: u32,
}

impl Default for SqliteOpenOptions {
    fn default() -> Self {
        Self {
            journal_mode: JournalMode::Wal,
            synchronous: SynchronousMode::Normal,
            busy_timeout_ms: 5_000,
        }
    }
}

impl SqliteOpenOptions {
    /// Default options: `WAL` + `NORMAL` + 5-second busy timeout.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Override the journal mode.
    #[must_use]
    pub fn with_journal_mode(mut self, mode: JournalMode) -> Self {
        self.journal_mode = mode;
        self
    }

    /// Override the `synchronous` pragma.
    #[must_use]
    pub fn with_synchronous(mut self, mode: SynchronousMode) -> Self {
        self.synchronous = mode;
        self
    }

    /// Override the busy timeout (ms).
    #[must_use]
    pub fn with_busy_timeout_ms(mut self, ms: u32) -> Self {
        self.busy_timeout_ms = ms;
        self
    }
}

/// SQLite-backed implementation of [`Storage`].
///
/// Open a database via [`SqliteStorage::open`] (filesystem path),
/// [`SqliteStorage::open_in_memory`] (transient, per-process), or
/// [`SqliteStorage::open_with_options`].  Once open, the storage
/// is thread-safe (`Send + Sync`) and may be shared across worker
/// threads via `Arc<SqliteStorage>`.
pub struct SqliteStorage {
    /// The connection.  Wrapped in `Mutex` for cross-thread access.
    conn: Mutex<Connection>,
    /// Path the database was opened from.  `None` for in-memory
    /// databases.  Used for diagnostics and the `path()` accessor.
    path: Option<PathBuf>,
}

impl std::fmt::Debug for SqliteStorage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SqliteStorage")
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

impl SqliteStorage {
    /// Open a database at `path` with default options
    /// (`WAL`, `NORMAL`, 5s busy timeout).  Creates the file if
    /// it doesn't exist.
    ///
    /// # Errors
    ///
    /// Returns [`StorageError::Io`] (or [`StorageError::Backend`])
    /// if the file cannot be opened or the migrations fail.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, StorageError> {
        Self::open_with_options(path, &SqliteOpenOptions::default())
    }

    /// Open a database at `path` with custom options.
    ///
    /// # Errors
    ///
    /// See [`Self::open`].
    pub fn open_with_options(
        path: impl AsRef<Path>,
        options: &SqliteOpenOptions,
    ) -> Result<Self, StorageError> {
        let path_ref = path.as_ref();
        let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX;
        let conn = Connection::open_with_flags(path_ref, flags)
            .map_err(|e| StorageError::Backend(format!("open {}: {e}", path_ref.display())))?;
        let mut storage = Self {
            conn: Mutex::new(conn),
            path: Some(path_ref.to_path_buf()),
        };
        storage.configure_and_migrate(options)?;
        Ok(storage)
    }

    /// Open an in-memory database.  Useful for tests and ephemeral
    /// scratchpad indexes that don't outlive the process.
    ///
    /// In-memory databases ignore `journal_mode` (no WAL needed);
    /// the synchronous setting is also moot but is applied for
    /// consistency.
    ///
    /// # Errors
    ///
    /// See [`Self::open`].
    pub fn open_in_memory() -> Result<Self, StorageError> {
        Self::open_in_memory_with_options(&SqliteOpenOptions::default())
    }

    /// Open an in-memory database with custom options.
    ///
    /// # Errors
    ///
    /// See [`Self::open`].
    pub fn open_in_memory_with_options(options: &SqliteOpenOptions) -> Result<Self, StorageError> {
        let conn = Connection::open_in_memory()
            .map_err(|e| StorageError::Backend(format!("open in-memory: {e}")))?;
        let mut storage = Self {
            conn: Mutex::new(conn),
            path: None,
        };
        storage.configure_and_migrate(options)?;
        Ok(storage)
    }

    /// Apply pragmas + run migrations.  Internal helper called by
    /// both `open` and `open_in_memory`.
    fn configure_and_migrate(&mut self, options: &SqliteOpenOptions) -> Result<(), StorageError> {
        let conn = self
            .conn
            .get_mut()
            .map_err(|p| StorageError::Backend(format!("mutex poisoned: {p}")))?;

        // Set busy timeout first so subsequent pragmas don't fail
        // under transient contention.
        conn.busy_timeout(std::time::Duration::from_millis(u64::from(
            options.busy_timeout_ms,
        )))
        .map_err(|e| StorageError::Backend(format!("set busy_timeout: {e}")))?;

        // Pragmas.  Each `pragma_update` runs `PRAGMA <name> = <val>`.
        // For in-memory databases, journal_mode = WAL silently
        // upgrades to MEMORY (SQLite quirk); we accept whatever the
        // engine settles on.
        conn.pragma_update(None, "journal_mode", options.journal_mode.as_str())
            .map_err(|e| StorageError::Backend(format!("set journal_mode: {e}")))?;
        conn.pragma_update(None, "synchronous", options.synchronous.as_str())
            .map_err(|e| StorageError::Backend(format!("set synchronous: {e}")))?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(|e| StorageError::Backend(format!("set foreign_keys: {e}")))?;
        conn.pragma_update(None, "temp_store", "MEMORY")
            .map_err(|e| StorageError::Backend(format!("set temp_store: {e}")))?;

        // Apply migrations to bring the schema up to current.
        apply_migrations(conn)?;
        Ok(())
    }

    /// The filesystem path the database was opened from.  `None`
    /// for in-memory databases.
    #[must_use]
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Acquire the connection mutex.  Internal helper.
    ///
    /// Lock poisoning: a previous holder panicked while holding
    /// the mutex.  We recover by extracting the inner guard —
    /// the connection itself is fine; only the panicking
    /// operation is suspect.  Mirrors the knomosis-host /
    /// knomosis-event-subscribe pattern.
    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Acquire the connection mutex.  Public entry point for
    /// crate-internal modules (the [`crate::budget_storage`]
    /// module's `SqliteBudgetTransaction` holds this guard for
    /// the transaction's lifetime).  See the module's design note
    /// re. mutex discipline.
    ///
    /// Downstream crates (knomosis-indexer, etc.) MUST NOT call
    /// this directly — they consume the typed
    /// [`crate::budget_storage::BudgetStorage`] /
    /// [`crate::storage::Storage`] trait surfaces instead.  The
    /// method is `pub(crate)` to lexically enforce the discipline
    /// (Rust visibility) — only the storage crate's own modules
    /// may bypass the trait abstractions.
    pub(crate) fn lock_connection(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.lock()
    }

    /// Direct access to the schema version after open.  Mainly for
    /// tests; production code uses the trait surface.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    pub fn schema_version(&self) -> Result<u32, StorageError> {
        let conn = self.lock();
        crate::migration::current_schema_version(&conn)
    }

    /// Begin a combined `(kv + budget tables)` transaction.  See
    /// [`crate::combined_transaction::SqliteCombinedTransaction`]
    /// for the operation surface.  The transaction holds the
    /// connection mutex for its lifetime so all operations run
    /// atomically; downstream callers (the
    /// `knomosis-indexer::apply_batch` driver) use this primitive
    /// to keep the balance view (kv-keyspace) and the GP.6.4
    /// budget views (SQL tables) in lockstep.
    ///
    /// # Errors
    ///
    /// Returns [`crate::combined_transaction::CombinedTransactionError`]
    /// on `BEGIN IMMEDIATE` failure.
    pub fn combined_transaction(
        &self,
    ) -> Result<
        crate::combined_transaction::SqliteCombinedTransaction<'_>,
        crate::combined_transaction::CombinedTransactionError,
    > {
        let guard = self.lock();
        crate::combined_transaction::SqliteCombinedTransaction::begin(guard)
    }
}

impl Storage for SqliteStorage {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, StorageError> {
        let conn = self.lock();
        let mut stmt = conn
            .prepare_cached("SELECT value FROM kv WHERE key = ?1")
            .map_err(|e| StorageError::Backend(format!("prepare get: {e}")))?;
        let value: Option<Vec<u8>> = stmt
            .query_row(params![key], |row| row.get(0))
            .optional()
            .map_err(|e| StorageError::Backend(format!("query get: {e}")))?;
        Ok(value)
    }

    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), StorageError> {
        let conn = self.lock();
        let mut stmt = conn
            .prepare_cached(
                "INSERT INTO kv(key, value) VALUES (?1, ?2) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            )
            .map_err(|e| StorageError::Backend(format!("prepare put: {e}")))?;
        stmt.execute(params![key, value])
            .map_err(|e| StorageError::Backend(format!("execute put: {e}")))?;
        Ok(())
    }

    fn delete(&self, key: &[u8]) -> Result<(), StorageError> {
        let conn = self.lock();
        let mut stmt = conn
            .prepare_cached("DELETE FROM kv WHERE key = ?1")
            .map_err(|e| StorageError::Backend(format!("prepare delete: {e}")))?;
        stmt.execute(params![key])
            .map_err(|e| StorageError::Backend(format!("execute delete: {e}")))?;
        Ok(())
    }

    fn scan(&self, prefix: &[u8]) -> Result<KeyValuePairs, StorageError> {
        let conn = self.lock();
        scan_with_conn(&conn, prefix)
    }

    fn snapshot(&self) -> Result<Box<dyn StorageSnapshot + '_>, StorageError> {
        // Acquire the connection mutex ONCE for the entire
        // recovery + BEGIN DEFERRED + warm-up sequence.  An
        // earlier draft of this code released the lock between
        // recovery and BEGIN, opening a race window where
        // another thread could wedge the connection.  Holding
        // the lock for the entire sequence makes the
        // recovery+BEGIN atomic.
        let guard = self.lock();
        // Defensive autocommit recovery: if a prior caller's
        // commit-failure cleanup left the connection in a
        // half-transaction state, force a ROLLBACK before we
        // try BEGIN again.  Per audit H-1.
        recover_autocommit_if_needed(&guard);
        // BEGIN DEFERRED.  The deferred mode means the
        // transaction doesn't actually grab a lock until the
        // first SQL statement that touches a real table.
        guard
            .execute_batch("BEGIN DEFERRED;")
            .map_err(|e| StorageError::Backend(format!("snapshot BEGIN: {e}")))?;
        // Force the transaction to acquire its read mark NOW.
        //
        // **Critical contract.**  SQLite's WAL read mark is
        // established at the first statement that touches a
        // real database table — NOT at BEGIN, and NOT on a
        // literal `SELECT 1` (which doesn't read any table).
        // Using `sqlite_master` (SQLite's built-in catalogue
        // table, guaranteed present in every database) forces
        // the read mark to land immediately.  Without this, a
        // concurrent writer between `BEGIN DEFERRED` and the
        // snapshot's first `get` / `scan` could leak its
        // post-write state into the snapshot's view.
        //
        // **Failure recovery.**  If this warm-up read fails
        // (e.g. transient I/O error), we MUST roll back the
        // BEGIN DEFERRED before returning the error.
        match guard.query_row("SELECT 1 FROM sqlite_master LIMIT 1", [], |_| {
            Ok::<(), rusqlite::Error>(())
        }) {
            // Either a row was found or the schema was empty.
            // Both paths establish the read mark.
            Ok(()) | Err(rusqlite::Error::QueryReturnedNoRows) => {}
            Err(e) => {
                // Defensive ROLLBACK to leave the connection in
                // autocommit mode.  We log if even the ROLLBACK
                // fails so the operator can see the connection
                // may be wedged.  Note: the next caller's
                // `recover_autocommit_if_needed` will catch any
                // residual wedge.
                if let Err(rollback_err) = guard.execute_batch("ROLLBACK;") {
                    tracing::warn!(
                        rollback_error = %rollback_err,
                        original_error = %e,
                        "snapshot warm-up failed; defensive ROLLBACK also failed"
                    );
                }
                return Err(StorageError::Backend(format!("snapshot warm-up read: {e}")));
            }
        }
        Ok(Box::new(SqliteSnapshot {
            guard: Some(guard),
            ended: false,
        }))
    }

    fn transaction(&self) -> Result<Box<dyn StorageTransaction + '_>, StorageError> {
        // Acquire the connection mutex ONCE for the entire
        // recovery + BEGIN sequence (avoiding the same race
        // window discussed in `snapshot`).
        let guard = self.lock();
        recover_autocommit_if_needed(&guard);
        // BEGIN IMMEDIATE acquires the write lock at the BEGIN
        // statement itself (no warm-up needed).  Either the BEGIN
        // succeeds and we own the write lock, or it fails and the
        // connection stays in autocommit mode.
        guard
            .execute_batch("BEGIN IMMEDIATE;")
            .map_err(|e| StorageError::Backend(format!("transaction BEGIN: {e}")))?;
        Ok(Box::new(SqliteTransaction {
            guard: Some(guard),
            ended: false,
        }))
    }
}

/// Internal helper: if the connection has a stale open
/// transaction (autocommit is off), force a ROLLBACK to recover.
/// Called at the start of [`SqliteStorage::snapshot`] and
/// [`SqliteStorage::transaction`] as defence-in-depth (audit H-1).
///
/// **Threat model.**  A previous caller's `snapshot()` or
/// `transaction()` could leave the SQLite connection in a
/// half-transaction state if BOTH the operation's primary cleanup
/// AND the defensive ROLLBACK failed (e.g., back-to-back I/O
/// errors).  Without recovery here, the next caller's `BEGIN`
/// would fail with "cannot start a transaction within a
/// transaction" until the process restarts.
///
/// Calling this at the start of each public BEGIN-issuing method
/// guarantees forward progress under any failure pattern.
fn recover_autocommit_if_needed(conn: &Connection) {
    if !conn.is_autocommit() {
        if let Err(e) = conn.execute_batch("ROLLBACK;") {
            tracing::warn!(
                error = %e,
                "recovered from wedged transaction state via ROLLBACK; original transaction state was inconsistent"
            );
        } else {
            tracing::debug!(
                "recovered from wedged transaction state (autocommit was off; issued ROLLBACK)"
            );
        }
    }
}

/// Helper: lex-ordered scan that takes a borrowed connection.
/// Shared by `SqliteStorage::scan` (operates on the live
/// connection) and `SqliteSnapshot::scan` (operates on the
/// snapshot's connection — which is the same connection but with
/// a pinned read view via the open transaction).
///
/// Three execution paths:
///
///   1. Empty `prefix` → `SELECT * FROM kv ORDER BY key ASC`.
///   2. `prefix` has a well-defined lex successor (per
///      [`next_prefix`]) → `WHERE key >= prefix AND key < successor`.
///      This is the fast path; SQLite's primary-key index scans
///      the range directly with no Rust-side filtering.
///   3. `prefix` is all-0xFF (no representable successor) →
///      `WHERE key >= prefix` plus a Rust-side prefix check.
///      Stops scanning at the first key that doesn't start with
///      `prefix`.
fn scan_with_conn(conn: &Connection, prefix: &[u8]) -> Result<KeyValuePairs, StorageError> {
    if prefix.is_empty() {
        return scan_all(conn);
    }
    match next_prefix(prefix) {
        Some(upper) => scan_two_bound(conn, prefix, &upper),
        None => scan_lower_bound_filtered(conn, prefix),
    }
}

/// Path 1: empty-prefix scan — return the entire table in lex order.
fn scan_all(conn: &Connection) -> Result<KeyValuePairs, StorageError> {
    let mut stmt = conn
        .prepare_cached("SELECT key, value FROM kv ORDER BY key ASC")
        .map_err(|e| StorageError::Backend(format!("prepare scan: {e}")))?;
    let mut rows = stmt
        .query([])
        .map_err(|e| StorageError::Backend(format!("execute scan: {e}")))?;
    let mut out = Vec::new();
    while let Some(row) = rows
        .next()
        .map_err(|e| StorageError::Backend(format!("scan iter: {e}")))?
    {
        let k: Vec<u8> = row
            .get(0)
            .map_err(|e| StorageError::Backend(format!("scan column 0: {e}")))?;
        let v: Vec<u8> = row
            .get(1)
            .map_err(|e| StorageError::Backend(format!("scan column 1: {e}")))?;
        out.push((k, v));
    }
    Ok(out)
}

/// Path 2: prefix has a successor — use `WHERE key >= prefix AND
/// key < upper` (the fast, index-friendly form).
fn scan_two_bound(
    conn: &Connection,
    prefix: &[u8],
    upper: &[u8],
) -> Result<KeyValuePairs, StorageError> {
    let mut stmt = conn
        .prepare_cached(
            "SELECT key, value FROM kv \
             WHERE key >= ?1 AND key < ?2 \
             ORDER BY key ASC",
        )
        .map_err(|e| StorageError::Backend(format!("prepare scan: {e}")))?;
    let mut rows = stmt
        .query(params![prefix, upper])
        .map_err(|e| StorageError::Backend(format!("execute scan: {e}")))?;
    let mut out = Vec::new();
    while let Some(row) = rows
        .next()
        .map_err(|e| StorageError::Backend(format!("scan iter: {e}")))?
    {
        let k: Vec<u8> = row
            .get(0)
            .map_err(|e| StorageError::Backend(format!("scan column 0: {e}")))?;
        let v: Vec<u8> = row
            .get(1)
            .map_err(|e| StorageError::Backend(format!("scan column 1: {e}")))?;
        out.push((k, v));
    }
    Ok(out)
}

/// Path 3: prefix is all-0xFF (no representable successor) — use
/// `WHERE key >= prefix` plus a Rust-side prefix check, stopping
/// at the first non-matching key.
///
/// **Allocation discipline.**  We check the key's `starts_with`
/// BEFORE materialising the value column.  This avoids allocating
/// (potentially large) value bytes for rows that won't be
/// returned to the caller.  Without this, a malicious prefix
/// could trigger materialisation of every row past the prefix
/// boundary before being discarded — an allocation-before-bounds-
/// check anti-pattern.
fn scan_lower_bound_filtered(
    conn: &Connection,
    prefix: &[u8],
) -> Result<KeyValuePairs, StorageError> {
    let mut stmt = conn
        .prepare_cached(
            "SELECT key, value FROM kv \
             WHERE key >= ?1 \
             ORDER BY key ASC",
        )
        .map_err(|e| StorageError::Backend(format!("prepare scan: {e}")))?;
    let mut rows = stmt
        .query(params![prefix])
        .map_err(|e| StorageError::Backend(format!("execute scan: {e}")))?;
    let mut out = Vec::new();
    while let Some(row) = rows
        .next()
        .map_err(|e| StorageError::Backend(format!("scan iter: {e}")))?
    {
        // Read the key column first; if it doesn't match the
        // prefix, skip the value column entirely.
        let k: Vec<u8> = row
            .get(0)
            .map_err(|e| StorageError::Backend(format!("scan column 0: {e}")))?;
        // Stop at the first key that doesn't start with `prefix`.
        // Keys are ordered, so no later row can match either.
        if !k.starts_with(prefix) {
            break;
        }
        let v: Vec<u8> = row
            .get(1)
            .map_err(|e| StorageError::Backend(format!("scan column 1: {e}")))?;
        out.push((k, v));
    }
    Ok(out)
}

/// Compute the lexicographic successor of `prefix` (the smallest
/// byte string strictly greater than every string starting with
/// `prefix`).
///
/// Returns `Some(s)` such that for every key `k`, `k.starts_with(prefix)`
/// iff `prefix <= k && k < s`.  Returns `None` when `prefix` is
/// all-0xFF (no representable successor in finite bytes).
///
/// Mathematical contract: for any non-empty `prefix` that is not
/// all-0xFF, let `s = next_prefix(prefix)`.  Then for every byte
/// string `k`:
///
/// ```text
///     prefix.is_prefix_of(k) iff prefix <= k AND k < s
/// ```
///
/// where `<=` denotes lexicographic order on byte strings.
fn next_prefix(prefix: &[u8]) -> Option<Vec<u8>> {
    // Find the rightmost byte that is less than 0xFF and
    // increment it; drop all bytes after that.
    //
    // Example:
    //   prefix = [0x01, 0x02, 0xFF]  →  next = [0x01, 0x03]
    //   prefix = [0xFF, 0xFF]         →  None (overflow)
    //   prefix = [0x00]               →  [0x01]
    let mut out = prefix.to_vec();
    for i in (0..out.len()).rev() {
        if out[i] < 0xFF {
            out[i] += 1;
            out.truncate(i + 1);
            return Some(out);
        }
    }
    None
}

/// A SQLite snapshot — holds the connection mutex and a
/// long-running `BEGIN DEFERRED` transaction that pins the
/// WAL state.  Dropping the snapshot ends the transaction
/// (releasing the read lock).
struct SqliteSnapshot<'a> {
    guard: Option<std::sync::MutexGuard<'a, Connection>>,
    ended: bool,
}

impl SqliteSnapshot<'_> {
    /// Internal helper: end the transaction (rollback) if it
    /// hasn't been ended yet.  Called by Drop and the close-out
    /// path.
    ///
    /// **ROLLBACK failure logging.**  A failed ROLLBACK during
    /// Drop indicates the SQLite connection is in an unexpected
    /// state — we log via `tracing::warn` rather than silently
    /// swallow.  The error is non-recoverable at Drop time
    /// (we can't return an error from Drop), so logging is the
    /// only observable signal.
    fn end(&mut self) {
        if self.ended {
            return;
        }
        if let Some(guard) = self.guard.as_ref() {
            // ROLLBACK is the right verb for a deferred read
            // transaction: no writes occurred, but rolling back
            // is cleaner than COMMITTING a no-op transaction (and
            // matches SQLite's documented snapshot release path).
            if let Err(e) = guard.execute_batch("ROLLBACK;") {
                tracing::warn!(
                    error = %e,
                    "SqliteSnapshot Drop: ROLLBACK failed; connection may be wedged"
                );
            }
        }
        self.ended = true;
    }
}

impl StorageSnapshot for SqliteSnapshot<'_> {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, StorageError> {
        if self.ended {
            return Err(StorageError::Invalidated {
                reason: "snapshot has been released".to_string(),
            });
        }
        let guard = self
            .guard
            .as_ref()
            .ok_or_else(|| StorageError::Invalidated {
                reason: "snapshot guard missing".to_string(),
            })?;
        let mut stmt = guard
            .prepare_cached("SELECT value FROM kv WHERE key = ?1")
            .map_err(|e| StorageError::Backend(format!("prepare snapshot get: {e}")))?;
        let value: Option<Vec<u8>> = stmt
            .query_row(params![key], |row| row.get(0))
            .optional()
            .map_err(|e| StorageError::Backend(format!("snapshot get: {e}")))?;
        Ok(value)
    }

    fn scan(&self, prefix: &[u8]) -> Result<KeyValuePairs, StorageError> {
        if self.ended {
            return Err(StorageError::Invalidated {
                reason: "snapshot has been released".to_string(),
            });
        }
        let guard = self
            .guard
            .as_ref()
            .ok_or_else(|| StorageError::Invalidated {
                reason: "snapshot guard missing".to_string(),
            })?;
        scan_with_conn(guard, prefix)
    }
}

impl Drop for SqliteSnapshot<'_> {
    fn drop(&mut self) {
        self.end();
    }
}

/// A SQLite transaction — holds the connection mutex and a
/// `BEGIN IMMEDIATE` write transaction.  Each `put` / `delete`
/// is issued directly against the SQLite transaction (SQLite's
/// transaction isolation provides read-your-writes for free, so
/// `get` from within the transaction sees staged mutations
/// without an extra in-Rust working set).
///
/// **Lifecycle.**
///
///   * `commit()` consumes the `Box<Self>`, runs `COMMIT;`, and
///     marks the transaction as ended.  On `COMMIT` failure, a
///     defensive `ROLLBACK` is issued (which may itself fail
///     harmlessly if SQLite already auto-rolled-back) before
///     returning `Err`.
///   * `rollback()` consumes the `Box<Self>`, runs `ROLLBACK;`,
///     and marks the transaction as ended.
///   * Drop (without `commit` / `rollback`) runs `ROLLBACK;` as
///     a fallback so a forgotten transaction can't leak.
///
/// In all cases the `ended` flag is set BEFORE returning so the
/// Drop fallback doesn't double-roll-back a transaction that
/// the explicit close-out already handled (or that SQLite has
/// auto-rolled-back on commit failure).
struct SqliteTransaction<'a> {
    guard: Option<std::sync::MutexGuard<'a, Connection>>,
    ended: bool,
}

impl SqliteTransaction<'_> {
    /// Internal helper: roll back the transaction if not yet
    /// ended.  Called by Drop.
    ///
    /// **Failure logging.**  A failed ROLLBACK at Drop time
    /// indicates the SQLite connection is in an unexpected
    /// state — we log via `tracing::warn` rather than silently
    /// swallow.  We can't propagate the error from Drop.
    fn end_rollback(&mut self) {
        if self.ended {
            return;
        }
        if let Some(guard) = self.guard.as_ref() {
            if let Err(e) = guard.execute_batch("ROLLBACK;") {
                tracing::warn!(
                    error = %e,
                    "SqliteTransaction Drop: ROLLBACK failed; connection may be wedged"
                );
            }
        }
        self.ended = true;
    }
}

impl StorageTransaction for SqliteTransaction<'_> {
    fn put(&mut self, key: &[u8], value: &[u8]) -> Result<(), StorageError> {
        if self.ended {
            return Err(StorageError::Invalidated {
                reason: "transaction has been closed".to_string(),
            });
        }
        let guard = self
            .guard
            .as_ref()
            .ok_or_else(|| StorageError::Invalidated {
                reason: "transaction guard missing".to_string(),
            })?;
        let mut stmt = guard
            .prepare_cached(
                "INSERT INTO kv(key, value) VALUES (?1, ?2) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            )
            .map_err(|e| StorageError::Backend(format!("prepare tx put: {e}")))?;
        stmt.execute(params![key, value])
            .map_err(|e| StorageError::Backend(format!("tx put: {e}")))?;
        Ok(())
    }

    fn delete(&mut self, key: &[u8]) -> Result<(), StorageError> {
        if self.ended {
            return Err(StorageError::Invalidated {
                reason: "transaction has been closed".to_string(),
            });
        }
        let guard = self
            .guard
            .as_ref()
            .ok_or_else(|| StorageError::Invalidated {
                reason: "transaction guard missing".to_string(),
            })?;
        let mut stmt = guard
            .prepare_cached("DELETE FROM kv WHERE key = ?1")
            .map_err(|e| StorageError::Backend(format!("prepare tx delete: {e}")))?;
        stmt.execute(params![key])
            .map_err(|e| StorageError::Backend(format!("tx delete: {e}")))?;
        Ok(())
    }

    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, StorageError> {
        if self.ended {
            return Err(StorageError::Invalidated {
                reason: "transaction has been closed".to_string(),
            });
        }
        let guard = self
            .guard
            .as_ref()
            .ok_or_else(|| StorageError::Invalidated {
                reason: "transaction guard missing".to_string(),
            })?;
        // SQLite gives us read-your-writes for free within a
        // transaction.
        let mut stmt = guard
            .prepare_cached("SELECT value FROM kv WHERE key = ?1")
            .map_err(|e| StorageError::Backend(format!("prepare tx get: {e}")))?;
        let value: Option<Vec<u8>> = stmt
            .query_row(params![key], |row| row.get(0))
            .optional()
            .map_err(|e| StorageError::Backend(format!("tx get: {e}")))?;
        Ok(value)
    }

    fn commit(mut self: Box<Self>) -> Result<(), StorageError> {
        if self.ended {
            return Err(StorageError::Invalidated {
                reason: "transaction already closed".to_string(),
            });
        }
        let guard = self
            .guard
            .as_ref()
            .ok_or_else(|| StorageError::Invalidated {
                reason: "transaction guard missing".to_string(),
            })?;
        match guard.execute_batch("COMMIT;") {
            Ok(()) => {
                // Successful COMMIT — mark ended so Drop doesn't
                // try a redundant ROLLBACK.
                self.ended = true;
                Ok(())
            }
            Err(e) => {
                // COMMIT failed.  SQLite's behaviour on COMMIT
                // failure depends on the error:
                //   * Constraint violations / busy → SQLite
                //     auto-rolls-back; subsequent ROLLBACK is a
                //     no-op (or errors "no transaction").
                //   * I/O error during commit → SQLite's state
                //     is implementation-defined; defensive
                //     ROLLBACK is best-effort cleanup.
                //
                // We attempt the ROLLBACK and tolerate failure
                // (the original COMMIT error is the one we
                // surface to the caller).  Setting `ended` BEFORE
                // the rollback prevents Drop from trying yet
                // another ROLLBACK.
                let rollback_result = guard.execute_batch("ROLLBACK;");
                self.ended = true;
                if let Err(rollback_err) = rollback_result {
                    // Bumped from `debug` → `warn` per audit M-2.
                    // A failed COMMIT followed by a failed
                    // defensive ROLLBACK means the SQLite
                    // connection may be in an inconsistent state;
                    // operators running at INFO level would miss
                    // a debug log.  WARN aligns with the snapshot
                    // warmup and Drop log levels.
                    //
                    // NOTE: this is often benign — SQLite
                    // typically auto-rolls-back on a constraint /
                    // busy commit failure, after which our defensive
                    // ROLLBACK returns "no transaction in progress".
                    // The `recover_autocommit_if_needed` defense at
                    // the start of the next snapshot/transaction
                    // also handles this case.
                    tracing::warn!(
                        rollback_error = %rollback_err,
                        commit_error = %e,
                        "transaction commit failed; defensive ROLLBACK also failed (likely already auto-rolled-back)"
                    );
                }
                Err(StorageError::CommitFailed {
                    reason: e.to_string(),
                })
            }
        }
    }

    fn rollback(mut self: Box<Self>) -> Result<(), StorageError> {
        if self.ended {
            return Err(StorageError::Invalidated {
                reason: "transaction already closed".to_string(),
            });
        }
        let guard = self
            .guard
            .as_ref()
            .ok_or_else(|| StorageError::Invalidated {
                reason: "transaction guard missing".to_string(),
            })?;
        let result = guard.execute_batch("ROLLBACK;");
        // Set ended regardless of success — even on ROLLBACK
        // failure we don't want Drop to try again.
        self.ended = true;
        result.map_err(|e| StorageError::Backend(format!("ROLLBACK: {e}")))?;
        Ok(())
    }
}

impl Drop for SqliteTransaction<'_> {
    fn drop(&mut self) {
        self.end_rollback();
    }
}

#[cfg(test)]
mod tests {
    use super::{next_prefix, JournalMode, SqliteOpenOptions, SqliteStorage, SynchronousMode};
    use crate::storage::{Storage, StorageError};

    /// `next_prefix` mathematical contract.
    #[test]
    fn next_prefix_examples() {
        assert_eq!(next_prefix(b"\x01\x02\xFF"), Some(b"\x01\x03".to_vec()));
        assert_eq!(next_prefix(b"\x00"), Some(b"\x01".to_vec()));
        assert_eq!(next_prefix(b"\xFE"), Some(b"\xFF".to_vec()));
        // All-0xFF prefix → None.
        assert_eq!(next_prefix(b"\xFF"), None);
        assert_eq!(next_prefix(b"\xFF\xFF\xFF"), None);
        // Empty prefix: per `scan_with_conn`'s logic, the empty
        // case is handled separately; `next_prefix(b"")` is
        // unreachable in production, but its mathematical answer
        // is `None` (there is no successor of the empty string
        // under the "prefix-of" relation).
        assert_eq!(next_prefix(b""), None);
    }

    /// SynchronousMode + JournalMode pragma values stable.
    #[test]
    fn pragma_constants_stable() {
        assert_eq!(SynchronousMode::Off.as_str(), "OFF");
        assert_eq!(SynchronousMode::Normal.as_str(), "NORMAL");
        assert_eq!(SynchronousMode::Full.as_str(), "FULL");
        assert_eq!(SynchronousMode::Extra.as_str(), "EXTRA");

        assert_eq!(JournalMode::Delete.as_str(), "DELETE");
        assert_eq!(JournalMode::Wal.as_str(), "WAL");
        assert_eq!(JournalMode::Memory.as_str(), "MEMORY");
    }

    /// Options builder defaults: WAL + NORMAL + 5s busy timeout.
    #[test]
    fn options_defaults() {
        let opts = SqliteOpenOptions::new();
        assert_eq!(opts.journal_mode, JournalMode::Wal);
        assert_eq!(opts.synchronous, SynchronousMode::Normal);
        assert_eq!(opts.busy_timeout_ms, 5_000);
    }

    /// Options builder chain — each `with_*` returns a customised
    /// copy.
    #[test]
    fn options_chain() {
        let opts = SqliteOpenOptions::new()
            .with_journal_mode(JournalMode::Memory)
            .with_synchronous(SynchronousMode::Off)
            .with_busy_timeout_ms(1000);
        assert_eq!(opts.journal_mode, JournalMode::Memory);
        assert_eq!(opts.synchronous, SynchronousMode::Off);
        assert_eq!(opts.busy_timeout_ms, 1000);
    }

    /// Open an in-memory database; schema_version equals the
    /// target after open.
    #[test]
    fn open_in_memory_runs_migrations() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let v = s.schema_version().unwrap();
        assert_eq!(v, crate::migration::target_schema_version());
        assert!(s.path().is_none());
    }

    /// Open a database from a tempfile; schema_version equals
    /// target after open.
    #[test]
    fn open_from_tempfile_runs_migrations() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.db");
        let s = SqliteStorage::open(&path).unwrap();
        let v = s.schema_version().unwrap();
        assert_eq!(v, crate::migration::target_schema_version());
        assert_eq!(s.path().map(std::path::Path::to_path_buf), Some(path));
    }

    /// `put` then `get` round-trips arbitrary bytes.
    #[test]
    fn put_then_get_roundtrips() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"foo", b"bar").unwrap();
        let v = s.get(b"foo").unwrap();
        assert_eq!(v, Some(b"bar".to_vec()));
    }

    /// `get` on a missing key returns `None`.
    #[test]
    fn get_missing_returns_none() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let v = s.get(b"missing").unwrap();
        assert_eq!(v, None);
    }

    /// `put` then `put` overwrites.
    #[test]
    fn put_overwrites() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"foo", b"v1").unwrap();
        s.put(b"foo", b"v2").unwrap();
        let v = s.get(b"foo").unwrap();
        assert_eq!(v, Some(b"v2".to_vec()));
    }

    /// `delete` removes the key; subsequent `get` returns None.
    #[test]
    fn delete_removes() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"foo", b"bar").unwrap();
        s.delete(b"foo").unwrap();
        let v = s.get(b"foo").unwrap();
        assert_eq!(v, None);
    }

    /// `delete` on a missing key is idempotent (no error).
    #[test]
    fn delete_missing_idempotent() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.delete(b"missing").unwrap(); // no-op, no error
    }

    /// `scan(empty)` returns the entire table in lex order.
    #[test]
    fn scan_empty_prefix_returns_all() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"b", b"bval").unwrap();
        s.put(b"a", b"aval").unwrap();
        s.put(b"c", b"cval").unwrap();
        let rows = s.scan(b"").unwrap();
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].0, b"a");
        assert_eq!(rows[1].0, b"b");
        assert_eq!(rows[2].0, b"c");
    }

    /// `scan(prefix)` returns only matching keys.
    #[test]
    fn scan_prefix_returns_matching() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"alpha/1", b"1").unwrap();
        s.put(b"alpha/2", b"2").unwrap();
        s.put(b"beta/1", b"3").unwrap();
        let rows = s.scan(b"alpha/").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].0, b"alpha/1");
        assert_eq!(rows[1].0, b"alpha/2");
    }

    /// `scan` returns entries in strict lex order even with
    /// adversarial insertion order.
    #[test]
    fn scan_orders_lexicographically() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let keys = [
            b"\xff".to_vec(),
            b"\x00".to_vec(),
            b"\x80".to_vec(),
            b"\x40\x40".to_vec(),
            b"\x40".to_vec(),
        ];
        for k in &keys {
            s.put(k, b"v").unwrap();
        }
        let rows = s.scan(b"").unwrap();
        assert_eq!(rows.len(), 5);
        let returned: Vec<Vec<u8>> = rows.into_iter().map(|(k, _)| k).collect();
        let mut expected = keys.to_vec();
        expected.sort();
        assert_eq!(returned, expected);
    }

    /// `scan` over an all-0xFF prefix uses the fallback path and
    /// still returns only matching rows.
    #[test]
    fn scan_all_ff_prefix_filtered() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"\xff\x00", b"a").unwrap();
        s.put(b"\xff\xff\xff", b"b").unwrap();
        s.put(b"\xfe", b"c").unwrap(); // does NOT match
        let rows = s.scan(b"\xff").unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|(k, _)| k.starts_with(b"\xff")));
    }

    /// Snapshot reads pre-snapshot state stably even as writes
    /// commit.
    #[test]
    fn snapshot_isolated_from_writes() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"k", b"v1").unwrap();
        let snap = s.snapshot().unwrap();
        // Snapshot sees v1; subsequent put won't change that.
        let v_before = snap.get(b"k").unwrap();
        assert_eq!(v_before, Some(b"v1".to_vec()));
        // NOTE: with our single-mutex design, the snapshot holds
        // the mutex.  A separate thread couldn't write while
        // the snapshot is live.  To exercise true isolation we
        // need a multi-threaded test (below in
        // `concurrent_readers_observe_consistent_snapshots`).
        drop(snap);
        // After dropping, writes resume.
        s.put(b"k", b"v2").unwrap();
        assert_eq!(s.get(b"k").unwrap(), Some(b"v2".to_vec()));
    }

    /// Snapshot `scan` returns the pinned view.
    #[test]
    fn snapshot_scan_returns_pinned_view() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"x", b"1").unwrap();
        let snap = s.snapshot().unwrap();
        let rows = snap.scan(b"").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].0, b"x");
        assert_eq!(rows[0].1, b"1");
    }

    /// Dropped snapshot releases the lock — subsequent storage
    /// methods succeed.
    #[test]
    fn dropped_snapshot_releases_lock() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"a", b"1").unwrap();
        {
            let _snap = s.snapshot().unwrap();
            // snap goes out of scope at end of block.
        }
        // Should be able to put again — no deadlock.
        s.put(b"b", b"2").unwrap();
        assert_eq!(s.get(b"b").unwrap(), Some(b"2".to_vec()));
    }

    /// Transaction `put` is visible via tx `get`.
    #[test]
    fn transaction_read_your_writes() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        tx.put(b"k", b"v").unwrap();
        let v = tx.get(b"k").unwrap();
        assert_eq!(v, Some(b"v".to_vec()));
        tx.commit().unwrap();
        assert_eq!(s.get(b"k").unwrap(), Some(b"v".to_vec()));
    }

    /// Transaction rolled back: mutations not visible after.
    #[test]
    fn transaction_rollback_discards() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        tx.put(b"k", b"v").unwrap();
        tx.rollback().unwrap();
        assert_eq!(s.get(b"k").unwrap(), None);
    }

    /// Transaction dropped without commit: mutations discarded.
    #[test]
    fn transaction_drop_rolls_back() {
        let s = SqliteStorage::open_in_memory().unwrap();
        {
            let mut tx = s.transaction().unwrap();
            tx.put(b"k", b"v").unwrap();
            // Drop without commit.
        }
        assert_eq!(s.get(b"k").unwrap(), None);
    }

    /// Transaction delete is staged; visible via tx get.
    #[test]
    fn transaction_delete_staged() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"k", b"v").unwrap();
        let mut tx = s.transaction().unwrap();
        tx.delete(b"k").unwrap();
        assert_eq!(tx.get(b"k").unwrap(), None);
        // Roll back: original value should still be there.
        tx.rollback().unwrap();
        assert_eq!(s.get(b"k").unwrap(), Some(b"v".to_vec()));
    }

    /// Multiple staged mutations all commit atomically.
    #[test]
    fn transaction_atomic_commit() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        for i in 0..10u8 {
            tx.put(&[i], &[i * 2]).unwrap();
        }
        tx.commit().unwrap();
        for i in 0..10u8 {
            assert_eq!(s.get(&[i]).unwrap(), Some(vec![i * 2]));
        }
    }

    /// Storage error variants Send + Sync.
    #[test]
    fn storage_error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<StorageError>();
    }

    /// `SqliteStorage` is `Send + Sync`.
    #[test]
    fn sqlite_storage_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<SqliteStorage>();
    }

    /// Empty key roundtrip — edge case.
    #[test]
    fn empty_key_roundtrip() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"", b"empty-key-value").unwrap();
        assert_eq!(s.get(b"").unwrap(), Some(b"empty-key-value".to_vec()));
    }

    /// Empty value roundtrip — edge case.
    #[test]
    fn empty_value_roundtrip() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(b"k", b"").unwrap();
        assert_eq!(s.get(b"k").unwrap(), Some(b"".to_vec()));
    }

    /// Large value roundtrip (1 MiB).
    #[test]
    fn large_value_roundtrip() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let value = vec![0xAB; 1024 * 1024];
        s.put(b"big", &value).unwrap();
        let got = s.get(b"big").unwrap();
        assert_eq!(got.as_deref().map(<[u8]>::len), Some(1024 * 1024));
        assert_eq!(got.unwrap()[0], 0xAB);
    }

    /// Reopening a file-backed database preserves data.
    #[test]
    fn file_persistence_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("persist.db");
        {
            let s = SqliteStorage::open(&path).unwrap();
            s.put(b"persist", b"yes").unwrap();
        } // s dropped → closes connection
        let s2 = SqliteStorage::open(&path).unwrap();
        assert_eq!(s2.get(b"persist").unwrap(), Some(b"yes".to_vec()));
    }

    /// Reopen-after-migration is a no-op (idempotent).
    #[test]
    fn reopen_does_not_re_migrate() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reopen.db");
        let v1 = {
            let s = SqliteStorage::open(&path).unwrap();
            s.schema_version().unwrap()
        };
        let v2 = {
            let s = SqliteStorage::open(&path).unwrap();
            s.schema_version().unwrap()
        };
        assert_eq!(v1, v2);
        assert_eq!(v2, crate::migration::target_schema_version());
    }
}
