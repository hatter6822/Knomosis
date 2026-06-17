// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! WU GP.6.4 — combined `(kv + budget tables)` transaction.
//!
//! [`SqliteCombinedTransaction`] holds a single `BEGIN IMMEDIATE`
//! transaction over the underlying SQLite connection and exposes:
//!
//!   1. Operations on the `kv` table — `kv_get` / `kv_put` /
//!      `kv_delete` / `kv_scan`.  Same semantics as
//!      [`crate::storage::Storage`]'s kv operations on
//!      [`crate::sqlite::SqliteStorage`].
//!   2. Operations on the five GP.6.4 budget / pool tables —
//!      `credit_actor_budget` / `credit_pool_eth` etc.  Same
//!      semantics as [`crate::budget_storage::BudgetStorageTransaction`].
//!
//! The transaction holds the connection's mutex for its lifetime so
//! both operation sets run within the same SQL-level transaction
//! and commit / roll back atomically together.  This is the
//! load-bearing primitive the indexer uses to keep the balance
//! view and the GP.6.4 budget views in lockstep — without this,
//! a partial commit could leave the budget view permanently
//! behind the balance view.
//!
//! ## Usage
//!
//! ```ignore
//! use knomosis_storage::sqlite::SqliteStorage;
//! let storage = SqliteStorage::open_in_memory().unwrap();
//! let mut tx = storage.combined_transaction().unwrap();
//! // kv ops
//! tx.kv_put(b"k", b"v").unwrap();
//! // budget table ops
//! tx.credit_actor_budget(42, 100).unwrap();
//! // atomic commit covering BOTH
//! tx.commit().unwrap();
//! ```
//!
//! ## Visibility discipline
//!
//! This module is public so the indexer can use it.  Downstream
//! callers SHOULD prefer the typed `BudgetStorage` trait surface
//! (for read-only queries) and the typed `Storage` trait surface
//! (for standalone kv use cases); `SqliteCombinedTransaction` is
//! the COMBINED-WRITE escape hatch and only the indexer's
//! apply_batch should consume it.

use rusqlite::{params, Connection, OptionalExtension};

use crate::budget_storage::{
    actor_key, decode_counter, encode_counter, ActorId, BudgetStorageError, CounterValue,
    COUNTER_VALUE_LEN, TABLE_ACTOR_BUDGETS, TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED,
    TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS, TABLE_POOL_BALANCES_BOLD, TABLE_POOL_BALANCES_ETH,
};
use crate::storage::{KeyValuePairs, StorageError};

/// Trait surface for the typed combined-transaction operations.
/// Implemented by [`SqliteCombinedTransaction`] and (in test
/// harnesses) by adaptors like `FaultyStorage`.
///
/// Operations cover both the kv table (mirroring
/// [`crate::storage::StorageTransaction`]) AND the GP.6.4 budget
/// tables.  All within a single SQL-level transaction (BEGIN
/// IMMEDIATE held by the implementor for its lifetime).
///
/// **Commit / rollback semantics.**  `commit` / `rollback`
/// consume the handle via `Box<Self>` so the trait is
/// object-safe (the indexer holds `Box<dyn CombinedTransactionOps>`
/// and the FaultyStorage adaptor wraps these boxes).
pub trait CombinedTransactionOps {
    /// Read a value from the `kv` table.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn kv_get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, CombinedTransactionError>;

    /// Insert / overwrite a kv pair.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn kv_put(&mut self, key: &[u8], value: &[u8]) -> Result<(), CombinedTransactionError>;

    /// Delete a kv pair (idempotent).
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn kv_delete(&mut self, key: &[u8]) -> Result<(), CombinedTransactionError>;

    /// Scan kv entries by prefix.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn kv_scan(&self, prefix: &[u8]) -> Result<KeyValuePairs, CombinedTransactionError>;

    /// Read the lifetime cumulative actor budget.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn get_actor_budget(&self, actor: ActorId) -> Result<CounterValue, CombinedTransactionError>;

    /// Read the current-epoch grants counter.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn get_actor_budget_current_epoch_grants(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, CombinedTransactionError>;

    /// Read the current-epoch consumed counter.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn get_actor_budget_current_epoch_consumed(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, CombinedTransactionError>;

    /// Read the per-pool-actor ETH net balance.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn get_pool_eth(&self, pool_actor: ActorId) -> Result<CounterValue, CombinedTransactionError>;

    /// Read the per-pool-actor BOLD net balance.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn get_pool_bold(&self, pool_actor: ActorId) -> Result<CounterValue, CombinedTransactionError>;

    /// Credit lifetime actor budget; halts on overflow.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn credit_actor_budget(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError>;

    /// Credit current-epoch grants.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn credit_actor_budget_current_epoch_grants(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError>;

    /// Credit current-epoch consumed.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn credit_actor_budget_current_epoch_consumed(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError>;

    /// Credit ETH pool.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn credit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError>;

    /// Credit BOLD pool.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn credit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError>;

    /// Debit ETH pool (halts on underflow).
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn debit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError>;

    /// Debit BOLD pool.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn debit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError>;

    /// Reset per-epoch tables (DELETE all rows).
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn reset_current_epoch(&mut self) -> Result<(), CombinedTransactionError>;

    /// Commit the transaction.  Consumes the handle.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn commit(self: Box<Self>) -> Result<(), CombinedTransactionError>;

    /// Rollback the transaction.  Consumes the handle.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn rollback(self: Box<Self>) -> Result<(), CombinedTransactionError>;
}

/// Trait for storage backends that support combined kv + budget
/// transactions.  Implemented by
/// [`crate::sqlite::SqliteStorage`]; the indexer uses this
/// surface so test harnesses can substitute fault-injecting
/// adaptors.
///
/// **Method-name disambiguation.**  This trait's method is
/// named `begin_combined_tx` rather than `combined_transaction`
/// (which is the inherent method on
/// [`crate::sqlite::SqliteStorage`] returning the concrete
/// `SqliteCombinedTransaction` type).  The two co-exist: the
/// inherent gives a concrete handle (for direct callers), the
/// trait gives a boxed handle (for generic / test consumers).
pub trait CombinedStorage: Send + Sync {
    /// Begin a combined WRITE transaction (`BEGIN IMMEDIATE`).  The
    /// returned handle holds the connection mutex for its lifetime
    /// so all operations run within a single SQL-level transaction.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn begin_combined_tx(
        &self,
    ) -> Result<Box<dyn CombinedTransactionOps + '_>, CombinedTransactionError>;

    /// Begin a combined READ-ONLY transaction (`BEGIN DEFERRED`).
    /// Acquires only a SHARED READ lock, so a backend that supports
    /// it (e.g. [`crate::sqlite::SqliteStorage`] opened via
    /// `open_read_only`) can read several cells under one consistent
    /// snapshot WITHOUT write capability.  The caller MUST invoke
    /// only the read methods (`kv_get`, `kv_scan`, `get_*`) on the
    /// returned handle.
    ///
    /// The default implementation falls back to
    /// [`Self::begin_combined_tx`] — correct for read-write backends
    /// (and the in-memory test adaptors), where an `IMMEDIATE`
    /// transaction that performs only reads is observationally
    /// identical.  Read-only-capable backends override this with a
    /// genuine `DEFERRED` begin.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    fn begin_combined_read_tx(
        &self,
    ) -> Result<Box<dyn CombinedTransactionOps + '_>, CombinedTransactionError> {
        self.begin_combined_tx()
    }
}

/// Combined-transaction handle.  See module docstring.
///
/// **Lifetime guarantee.**  Holds the SqliteStorage connection
/// mutex for the entire transaction lifetime (BEGIN IMMEDIATE
/// through COMMIT / ROLLBACK).  No other thread can interleave
/// operations on the connection until the transaction is
/// finalised.
pub struct SqliteCombinedTransaction<'a> {
    /// The connection-mutex guard.  `None` after `commit` /
    /// `rollback` (which drop it explicitly to release the
    /// mutex before returning).
    guard: Option<std::sync::MutexGuard<'a, Connection>>,
    /// Tracks whether the transaction has been finalised
    /// (committed or rolled back).  On `Drop` without finalisation,
    /// the destructor invokes ROLLBACK as a safety net.
    finalised: bool,
}

/// Error variants common to kv and budget operations.
#[derive(Debug, thiserror::Error)]
pub enum CombinedTransactionError {
    /// Underlying storage failure.
    #[error("storage error: {0}")]
    Storage(#[from] StorageError),
    /// Budget-tables operation failed (overflow, underflow,
    /// corrupt cell).
    #[error("budget error: {0}")]
    Budget(#[from] BudgetStorageError),
}

impl<'a> SqliteCombinedTransaction<'a> {
    /// Internal constructor — only called by
    /// `SqliteStorage::combined_transaction`.  Opens a WRITE
    /// transaction (`BEGIN IMMEDIATE`): the write lock is acquired
    /// at the BEGIN itself, so a later `credit_*` / `kv_put` cannot
    /// lose a lock-upgrade race.
    pub(crate) fn begin(
        guard: std::sync::MutexGuard<'a, Connection>,
    ) -> Result<Self, CombinedTransactionError> {
        Self::begin_with(guard, "BEGIN IMMEDIATE")
    }

    /// Internal constructor — only called by
    /// `SqliteStorage::combined_read_transaction`.  Opens a
    /// READ-ONLY transaction (`BEGIN DEFERRED`): it acquires only a
    /// SHARED READ lock (not the write lock [`Self::begin`] takes),
    /// so it functions over a `SQLITE_OPEN_READ_ONLY` connection
    /// (the read-only gateway path) and never blocks a concurrent
    /// writer.
    ///
    /// The handle still exposes the full operation surface for type
    /// uniformity, but a write method (`kv_put`, `credit_*`, …) on a
    /// deferred/read-only transaction fails at the SQL layer
    /// (`SQLITE_READONLY` on a read-only connection, or a lock
    /// upgrade against a live writer) rather than silently
    /// succeeding — callers MUST invoke only the read methods
    /// (`kv_get`, `kv_scan`, `get_*`).
    pub(crate) fn begin_deferred(
        guard: std::sync::MutexGuard<'a, Connection>,
    ) -> Result<Self, CombinedTransactionError> {
        Self::begin_with(guard, "BEGIN DEFERRED")
    }

    /// Shared body of [`Self::begin`] / [`Self::begin_deferred`].
    /// `begin_sql` is a compile-time-constant `BEGIN` statement
    /// (never user input — no SQL-injection surface).
    fn begin_with(
        guard: std::sync::MutexGuard<'a, Connection>,
        begin_sql: &'static str,
    ) -> Result<Self, CombinedTransactionError> {
        // Defence-in-depth recovery (mirroring
        // `recover_autocommit_if_needed` from the kv tx path).
        if !guard.is_autocommit() {
            let _ = guard.execute_batch("ROLLBACK");
        }
        guard
            .execute_batch(begin_sql)
            .map_err(|e| StorageError::Backend(format!("combined tx {begin_sql}: {e}")))?;
        Ok(Self {
            guard: Some(guard),
            finalised: false,
        })
    }

    /// Borrow the connection.  Internal helper.
    fn conn(&self) -> Result<&Connection, CombinedTransactionError> {
        self.guard.as_deref().ok_or_else(|| {
            CombinedTransactionError::Storage(StorageError::Invalidated {
                reason: "combined transaction handle drained".to_string(),
            })
        })
    }

    // -----------------------------------------------------------------
    // kv table operations (mirror Storage trait)
    // -----------------------------------------------------------------

    /// Read a value from the `kv` table.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn kv_get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, CombinedTransactionError> {
        let conn = self.conn()?;
        let value = conn
            .query_row("SELECT value FROM kv WHERE key = ?1", params![key], |row| {
                row.get::<_, Vec<u8>>(0)
            })
            .optional()
            .map_err(|e| StorageError::Backend(format!("kv_get: {e}")))?;
        Ok(value)
    }

    /// Insert / overwrite a kv pair.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn kv_put(&mut self, key: &[u8], value: &[u8]) -> Result<(), CombinedTransactionError> {
        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO kv(key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )
        .map_err(|e| StorageError::Backend(format!("kv_put: {e}")))?;
        Ok(())
    }

    /// Delete a kv pair (idempotent).
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn kv_delete(&mut self, key: &[u8]) -> Result<(), CombinedTransactionError> {
        let conn = self.conn()?;
        conn.execute("DELETE FROM kv WHERE key = ?1", params![key])
            .map_err(|e| StorageError::Backend(format!("kv_delete: {e}")))?;
        Ok(())
    }

    /// Scan the kv table for entries with the given prefix, in
    /// strict lex order.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn kv_scan(&self, prefix: &[u8]) -> Result<KeyValuePairs, CombinedTransactionError> {
        let conn = self.conn()?;
        // For empty prefix, scan the entire table.
        let sql = if prefix.is_empty() {
            "SELECT key, value FROM kv ORDER BY key ASC".to_string()
        } else {
            // Use the `>=` comparison and a synthesized upper bound
            // to avoid SQL LIKE escapes (the prefix is opaque bytes).
            "SELECT key, value FROM kv WHERE key >= ?1 AND key < ?2 ORDER BY key ASC".to_string()
        };
        if prefix.is_empty() {
            let mut stmt = conn
                .prepare(&sql)
                .map_err(|e| StorageError::Backend(format!("kv_scan prepare: {e}")))?;
            let rows = stmt
                .query_map([], |row| {
                    let k: Vec<u8> = row.get(0)?;
                    let v: Vec<u8> = row.get(1)?;
                    Ok((k, v))
                })
                .map_err(|e| StorageError::Backend(format!("kv_scan query: {e}")))?;
            let mut out = Vec::new();
            for r in rows {
                let (k, v) = r.map_err(|e| StorageError::Backend(format!("kv_scan row: {e}")))?;
                out.push((k, v));
            }
            Ok(out)
        } else {
            // Compute the exclusive upper bound by treating the
            // prefix as a big-endian number and adding 1; the
            // first key past the prefix range is the next
            // lex-greater key.  This matches RocksDB / LevelDB's
            // standard prefix-scan idiom.
            let upper = next_prefix_upper_bound(prefix);
            let mut stmt = conn
                .prepare(&sql)
                .map_err(|e| StorageError::Backend(format!("kv_scan prepare: {e}")))?;
            let rows = match upper {
                Some(ub) => stmt
                    .query_map(params![prefix, &ub as &[u8]], |row| {
                        let k: Vec<u8> = row.get(0)?;
                        let v: Vec<u8> = row.get(1)?;
                        Ok((k, v))
                    })
                    .map_err(|e| StorageError::Backend(format!("kv_scan query: {e}")))?,
                None => {
                    // The prefix is all-0xFF; the upper bound is +∞.
                    // Use `>=` only.
                    let sql_open = "SELECT key, value FROM kv WHERE key >= ?1 ORDER BY key ASC";
                    let mut stmt = conn
                        .prepare(sql_open)
                        .map_err(|e| StorageError::Backend(format!("kv_scan prepare: {e}")))?;
                    let rows = stmt
                        .query_map(params![prefix], |row| {
                            let k: Vec<u8> = row.get(0)?;
                            let v: Vec<u8> = row.get(1)?;
                            Ok((k, v))
                        })
                        .map_err(|e| StorageError::Backend(format!("kv_scan query: {e}")))?;
                    let mut out = Vec::new();
                    for r in rows {
                        let (k, v) =
                            r.map_err(|e| StorageError::Backend(format!("kv_scan row: {e}")))?;
                        out.push((k, v));
                    }
                    return Ok(out);
                }
            };
            let mut out = Vec::new();
            for r in rows {
                let (k, v) = r.map_err(|e| StorageError::Backend(format!("kv_scan row: {e}")))?;
                out.push((k, v));
            }
            Ok(out)
        }
    }

    // -----------------------------------------------------------------
    // Budget tables operations
    // -----------------------------------------------------------------

    /// Read the lifetime cumulative actor budget.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn get_actor_budget(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(read_cell(self.conn()?, TABLE_ACTOR_BUDGETS, actor)?)
    }

    /// Read the current-epoch grants counter.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn get_actor_budget_current_epoch_grants(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(read_cell(
            self.conn()?,
            TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS,
            actor,
        )?)
    }

    /// Read the current-epoch consumed counter.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn get_actor_budget_current_epoch_consumed(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(read_cell(
            self.conn()?,
            TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED,
            actor,
        )?)
    }

    /// Read the per-pool-actor ETH net balance.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn get_pool_eth(
        &self,
        pool_actor: ActorId,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(read_cell(
            self.conn()?,
            TABLE_POOL_BALANCES_ETH,
            pool_actor,
        )?)
    }

    /// Read the per-pool-actor BOLD net balance.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn get_pool_bold(
        &self,
        pool_actor: ActorId,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(read_cell(
            self.conn()?,
            TABLE_POOL_BALANCES_BOLD,
            pool_actor,
        )?)
    }

    /// Credit the lifetime cumulative actor budget by `delta`.
    /// Halts on overflow (propagates `CreditOverflow` so the
    /// caller's `?` rolls back the batch).
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn credit_actor_budget(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(checked_credit(
            self.conn()?,
            TABLE_ACTOR_BUDGETS,
            actor,
            delta,
        )?)
    }

    /// Credit the current-epoch grants counter.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn credit_actor_budget_current_epoch_grants(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(checked_credit(
            self.conn()?,
            TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS,
            actor,
            delta,
        )?)
    }

    /// Credit the current-epoch consumed counter.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn credit_actor_budget_current_epoch_consumed(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(checked_credit(
            self.conn()?,
            TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED,
            actor,
            delta,
        )?)
    }

    /// Credit the ETH pool view.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn credit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(checked_credit(
            self.conn()?,
            TABLE_POOL_BALANCES_ETH,
            pool_actor,
            delta,
        )?)
    }

    /// Credit the BOLD pool view.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn credit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(checked_credit(
            self.conn()?,
            TABLE_POOL_BALANCES_BOLD,
            pool_actor,
            delta,
        )?)
    }

    /// Debit the ETH pool view (e.g., `Event.gasPoolClaim`
    /// drain wiring).  Halts on underflow.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn debit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(checked_debit(
            self.conn()?,
            TABLE_POOL_BALANCES_ETH,
            pool_actor,
            delta,
        )?)
    }

    /// Debit the BOLD pool view.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn debit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Ok(checked_debit(
            self.conn()?,
            TABLE_POOL_BALANCES_BOLD,
            pool_actor,
            delta,
        )?)
    }

    /// Reset both current-epoch tables (DELETE all rows).  Called
    /// at every epoch boundary crossing.
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn reset_current_epoch(&mut self) -> Result<(), CombinedTransactionError> {
        let conn = self.conn()?;
        conn.execute(
            &format!("DELETE FROM {TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS}"),
            [],
        )
        .map_err(|e| StorageError::Backend(format!("reset_current_epoch grants: {e}")))?;
        conn.execute(
            &format!("DELETE FROM {TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED}"),
            [],
        )
        .map_err(|e| StorageError::Backend(format!("reset_current_epoch consumed: {e}")))?;
        Ok(())
    }

    // -----------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------

    /// Internal helper: finalise the transaction with the given
    /// terminator (`COMMIT` or `ROLLBACK`).  Sets `finalised =
    /// true` and drops the guard before returning.
    fn finalise(&mut self, terminator: &'static str) -> Result<(), CombinedTransactionError> {
        let conn = self.conn()?;
        conn.execute_batch(terminator)
            .map_err(|e| StorageError::Backend(format!("combined tx {terminator}: {e}")))?;
        self.finalised = true;
        drop(self.guard.take());
        Ok(())
    }

    /// Commit the transaction.  Inherent method (calls
    /// `finalise("COMMIT")` directly without going through the
    /// trait's `Box<Self>` indirection).  Mirrors the
    /// [`CombinedTransactionOps::commit`] trait method's
    /// behaviour for direct callers that hold the value
    /// (rather than `Box<dyn CombinedTransactionOps>`).
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn commit(mut self) -> Result<(), CombinedTransactionError> {
        self.finalise("COMMIT")
    }

    /// Rollback the transaction.  Inherent counterpart of
    /// [`CombinedTransactionOps::rollback`].
    ///
    /// # Errors
    ///
    /// See [`CombinedTransactionError`].
    pub fn rollback(mut self) -> Result<(), CombinedTransactionError> {
        self.finalise("ROLLBACK")
    }
}

impl CombinedTransactionOps for SqliteCombinedTransaction<'_> {
    fn kv_get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, CombinedTransactionError> {
        Self::kv_get(self, key)
    }

    fn kv_put(&mut self, key: &[u8], value: &[u8]) -> Result<(), CombinedTransactionError> {
        Self::kv_put(self, key, value)
    }

    fn kv_delete(&mut self, key: &[u8]) -> Result<(), CombinedTransactionError> {
        Self::kv_delete(self, key)
    }

    fn kv_scan(&self, prefix: &[u8]) -> Result<KeyValuePairs, CombinedTransactionError> {
        Self::kv_scan(self, prefix)
    }

    fn get_actor_budget(&self, actor: ActorId) -> Result<CounterValue, CombinedTransactionError> {
        Self::get_actor_budget(self, actor)
    }

    fn get_actor_budget_current_epoch_grants(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Self::get_actor_budget_current_epoch_grants(self, actor)
    }

    fn get_actor_budget_current_epoch_consumed(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Self::get_actor_budget_current_epoch_consumed(self, actor)
    }

    fn get_pool_eth(&self, pool_actor: ActorId) -> Result<CounterValue, CombinedTransactionError> {
        Self::get_pool_eth(self, pool_actor)
    }

    fn get_pool_bold(&self, pool_actor: ActorId) -> Result<CounterValue, CombinedTransactionError> {
        Self::get_pool_bold(self, pool_actor)
    }

    fn credit_actor_budget(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Self::credit_actor_budget(self, actor, delta)
    }

    fn credit_actor_budget_current_epoch_grants(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Self::credit_actor_budget_current_epoch_grants(self, actor, delta)
    }

    fn credit_actor_budget_current_epoch_consumed(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Self::credit_actor_budget_current_epoch_consumed(self, actor, delta)
    }

    fn credit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Self::credit_pool_eth(self, pool_actor, delta)
    }

    fn credit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Self::credit_pool_bold(self, pool_actor, delta)
    }

    fn debit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Self::debit_pool_eth(self, pool_actor, delta)
    }

    fn debit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, CombinedTransactionError> {
        Self::debit_pool_bold(self, pool_actor, delta)
    }

    fn reset_current_epoch(&mut self) -> Result<(), CombinedTransactionError> {
        Self::reset_current_epoch(self)
    }

    fn commit(mut self: Box<Self>) -> Result<(), CombinedTransactionError> {
        self.finalise("COMMIT")
    }

    fn rollback(mut self: Box<Self>) -> Result<(), CombinedTransactionError> {
        self.finalise("ROLLBACK")
    }
}

impl CombinedStorage for crate::sqlite::SqliteStorage {
    fn begin_combined_tx(
        &self,
    ) -> Result<Box<dyn CombinedTransactionOps + '_>, CombinedTransactionError> {
        let tx = self.combined_transaction()?;
        Ok(Box::new(tx))
    }

    fn begin_combined_read_tx(
        &self,
    ) -> Result<Box<dyn CombinedTransactionOps + '_>, CombinedTransactionError> {
        let tx = self.combined_read_transaction()?;
        Ok(Box::new(tx))
    }
}

impl Drop for SqliteCombinedTransaction<'_> {
    fn drop(&mut self) {
        if !self.finalised {
            if let Some(conn) = self.guard.as_ref() {
                let _ = conn.execute_batch("ROLLBACK");
            }
        }
    }
}

/// Compute the exclusive upper bound for a prefix scan: the
/// lex-smallest byte sequence strictly greater than every key
/// starting with `prefix`.  Returns `None` if `prefix` is all
/// `0xFF` (no finite upper bound exists; the caller must omit
/// the upper-bound clause).
fn next_prefix_upper_bound(prefix: &[u8]) -> Option<Vec<u8>> {
    let mut out = prefix.to_vec();
    while let Some(last) = out.last_mut() {
        if *last == 0xFF {
            out.pop();
        } else {
            *last += 1;
            return Some(out);
        }
    }
    None
}

/// Free function shared with [`crate::budget_storage`]: read a
/// counter cell from the given table.
fn read_cell(
    conn: &Connection,
    table: &'static str,
    actor: ActorId,
) -> Result<CounterValue, BudgetStorageError> {
    let key = actor_key(actor);
    let sql = format!("SELECT value FROM {table} WHERE actor = ?1");
    let row: Option<Vec<u8>> = conn
        .query_row(&sql, params![&key as &[u8]], |row| row.get::<_, Vec<u8>>(0))
        .optional()
        .map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
    match row {
        None => Ok(0),
        Some(bytes) => decode_counter(&bytes).ok_or(BudgetStorageError::CorruptCell {
            table,
            actor,
            expected: COUNTER_VALUE_LEN,
            actual: bytes.len(),
        }),
    }
}

/// Apply a checked credit to the named table.
fn checked_credit(
    conn: &Connection,
    table: &'static str,
    actor: ActorId,
    delta: CounterValue,
) -> Result<CounterValue, BudgetStorageError> {
    let current = read_cell(conn, table, actor)?;
    let new_value = current
        .checked_add(delta)
        .ok_or(BudgetStorageError::CreditOverflow {
            table,
            actor,
            current,
            delta,
        })?;
    let key = actor_key(actor);
    let value = encode_counter(new_value);
    let sql = format!(
        "INSERT INTO {table}(actor, value) VALUES (?1, ?2) \
         ON CONFLICT(actor) DO UPDATE SET value = excluded.value"
    );
    conn.execute(&sql, params![&key as &[u8], &value as &[u8]])
        .map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
    Ok(new_value)
}

/// Apply a checked debit (drain) to the named table.
fn checked_debit(
    conn: &Connection,
    table: &'static str,
    actor: ActorId,
    delta: CounterValue,
) -> Result<CounterValue, BudgetStorageError> {
    let current = read_cell(conn, table, actor)?;
    let new_value = current
        .checked_sub(delta)
        .ok_or(BudgetStorageError::DrainUnderflow {
            table,
            actor,
            current,
            delta,
        })?;
    let key = actor_key(actor);
    let value = encode_counter(new_value);
    let sql = format!(
        "INSERT INTO {table}(actor, value) VALUES (?1, ?2) \
         ON CONFLICT(actor) DO UPDATE SET value = excluded.value"
    );
    conn.execute(&sql, params![&key as &[u8], &value as &[u8]])
        .map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
    Ok(new_value)
}

#[cfg(test)]
mod tests {
    use super::{next_prefix_upper_bound, SqliteCombinedTransaction};
    use crate::sqlite::SqliteStorage;

    /// `next_prefix_upper_bound` produces the lex-smallest key
    /// strictly greater than every `prefix*` extension.
    #[test]
    fn next_prefix_upper_bound_basic() {
        assert_eq!(next_prefix_upper_bound(b"abc"), Some(b"abd".to_vec()));
        assert_eq!(next_prefix_upper_bound(b"a"), Some(b"b".to_vec()));
        assert_eq!(next_prefix_upper_bound(&[0xFE]), Some(vec![0xFF]));
        // All-0xFF prefix has no finite upper bound.
        assert_eq!(next_prefix_upper_bound(&[0xFF, 0xFF]), None);
        // Trailing 0xFF gets popped; the next-to-last is bumped.
        assert_eq!(next_prefix_upper_bound(&[0x05, 0xFF]), Some(vec![0x06]));
    }

    /// Combined transaction: kv ops + budget ops commit atomically.
    #[test]
    fn combined_tx_atomic_commit() {
        use crate::budget_storage::BudgetStorage;
        use crate::storage::Storage;
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.combined_transaction().unwrap();
        tx.kv_put(b"some_key", b"some_value").unwrap();
        tx.credit_actor_budget(42, 100).unwrap();
        tx.commit().unwrap();
        // Both visible after commit.
        assert_eq!(s.get(b"some_key").unwrap(), Some(b"some_value".to_vec()));
        assert_eq!(s.get_actor_budget(42).unwrap(), 100);
    }

    /// Combined transaction: rollback discards both kv + budget
    /// mutations atomically.
    #[test]
    fn combined_tx_atomic_rollback() {
        use crate::budget_storage::BudgetStorage;
        use crate::storage::Storage;
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.combined_transaction().unwrap();
        tx.kv_put(b"some_key", b"some_value").unwrap();
        tx.credit_actor_budget(42, 100).unwrap();
        tx.rollback().unwrap();
        assert_eq!(s.get(b"some_key").unwrap(), None);
        assert_eq!(s.get_actor_budget(42).unwrap(), 0);
    }

    /// Drop without commit/rollback ROLLBACKs as a safety net.
    #[test]
    fn combined_tx_drop_rollbacks() {
        use crate::budget_storage::BudgetStorage;
        use crate::storage::Storage;
        let s = SqliteStorage::open_in_memory().unwrap();
        {
            let mut tx = s.combined_transaction().unwrap();
            tx.kv_put(b"some_key", b"some_value").unwrap();
            tx.credit_actor_budget(42, 100).unwrap();
            // `tx` dropped without commit.
        }
        assert_eq!(s.get(b"some_key").unwrap(), None);
        assert_eq!(s.get_actor_budget(42).unwrap(), 0);
    }

    /// Credit overflow halts the combined tx + rolls back the
    /// kv side together.
    #[test]
    fn credit_overflow_rolls_back_kv() {
        use crate::budget_storage::BudgetStorage;
        use crate::storage::Storage;
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.combined_transaction().unwrap();
        tx.kv_put(b"k1", b"v1").unwrap();
        tx.credit_actor_budget(42, u128::MAX - 5).unwrap();
        // This credit overflows.
        let result = tx.credit_actor_budget(42, 100);
        assert!(result.is_err());
        // Rollback explicitly (or rely on Drop).
        tx.rollback().unwrap();
        // Both kv and budget reverted.
        assert_eq!(s.get(b"k1").unwrap(), None);
        assert_eq!(s.get_actor_budget(42).unwrap(), 0);
    }

    /// kv_scan honors the prefix correctly + ascending order.
    #[test]
    fn kv_scan_basic() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.combined_transaction().unwrap();
        tx.kv_put(b"a/1", b"v1").unwrap();
        tx.kv_put(b"a/2", b"v2").unwrap();
        tx.kv_put(b"b/1", b"v3").unwrap();
        tx.commit().unwrap();
        let tx = s.combined_transaction().unwrap();
        let rows = tx.kv_scan(b"a/").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].0, b"a/1");
        assert_eq!(rows[1].0, b"a/2");
    }

    /// Empty-prefix scan returns the whole table.
    #[test]
    fn kv_scan_empty_prefix() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.combined_transaction().unwrap();
        tx.kv_put(b"k1", b"v1").unwrap();
        tx.kv_put(b"k2", b"v2").unwrap();
        tx.commit().unwrap();
        let tx = s.combined_transaction().unwrap();
        let rows = tx.kv_scan(b"").unwrap();
        assert_eq!(rows.len(), 2);
    }

    /// Reset current epoch within the combined tx affects only
    /// the per-epoch tables.
    #[test]
    fn reset_current_epoch_in_combined_tx() {
        use crate::budget_storage::BudgetStorage;
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.combined_transaction().unwrap();
        tx.credit_actor_budget(42, 1000).unwrap();
        tx.credit_actor_budget_current_epoch_grants(42, 100)
            .unwrap();
        tx.credit_actor_budget_current_epoch_consumed(42, 50)
            .unwrap();
        tx.commit().unwrap();
        let mut tx = s.combined_transaction().unwrap();
        tx.reset_current_epoch().unwrap();
        tx.commit().unwrap();
        assert_eq!(s.get_actor_budget(42).unwrap(), 1000);
        assert_eq!(s.get_actor_budget_current_epoch_grants(42).unwrap(), 0);
        assert_eq!(s.get_actor_budget_current_epoch_consumed(42).unwrap(), 0);
    }

    /// Compile-only: the type is Sized so it can be returned by
    /// value (not boxed).  This is the SqliteCombinedTransaction
    /// invariant used by `SqliteStorage::combined_transaction`.
    #[test]
    fn combined_tx_is_returnable_by_value() {
        fn assert_sized<T: Sized>() {}
        assert_sized::<SqliteCombinedTransaction<'_>>();
    }

    /// The DEFERRED read transaction (`combined_read_transaction` /
    /// `begin_combined_read_tx`) reads committed kv + budget cells
    /// identically to the write path — without taking the write
    /// lock.  (The read-only-CONNECTION enforcement is exercised in
    /// the `sqlite.rs::open_read_only` tests; here we confirm the
    /// read path's observable equivalence on a read-write
    /// connection, plus the boxed-trait surface.)
    #[test]
    fn combined_read_tx_reads_committed_state() {
        use crate::budget_storage::BudgetStorage;
        use crate::combined_transaction::CombinedStorage;
        let s = SqliteStorage::open_in_memory().unwrap();
        // Seed via the write path.
        let mut wtx = s.combined_transaction().unwrap();
        wtx.kv_put(b"k", b"v").unwrap();
        wtx.credit_actor_budget_current_epoch_grants(7, 100)
            .unwrap();
        wtx.credit_actor_budget_current_epoch_consumed(7, 30)
            .unwrap();
        wtx.commit().unwrap();
        // Read back via the inherent DEFERRED read transaction.
        let rtx = s.combined_read_transaction().unwrap();
        assert_eq!(rtx.kv_get(b"k").unwrap(), Some(b"v".to_vec()));
        assert_eq!(rtx.get_actor_budget_current_epoch_grants(7).unwrap(), 100);
        assert_eq!(rtx.get_actor_budget_current_epoch_consumed(7).unwrap(), 30);
        rtx.rollback().unwrap();
        // The boxed trait surface (`begin_combined_read_tx`) is
        // observationally equivalent.
        let btx = s.begin_combined_read_tx().unwrap();
        assert_eq!(btx.get_actor_budget_current_epoch_grants(7).unwrap(), 100);
        btx.rollback().unwrap();
        // Sanity: the seeded state is unchanged by the read txs.
        assert_eq!(s.get_actor_budget_current_epoch_grants(7).unwrap(), 100);
    }
}
