// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! WU GP.6.4 — typed per-actor budget / pool storage.
//!
//! This module provides the [`BudgetStorage`] and
//! [`BudgetStorageTransaction`] traits + a [`SqliteBudgetStorage`]
//! implementation backed by the five SQLite tables created by
//! `migration_002_budget_views`:
//!
//!   * `actor_budgets` — lifetime cumulative grants (`u128`).
//!   * `actor_budgets_current_epoch_grants` — current-epoch
//!     cumulative grants (`u128`); reset at every epoch boundary
//!     by [`BudgetStorageTransaction::reset_current_epoch`].
//!   * `actor_budgets_current_epoch_consumed` — current-epoch
//!     cumulative consumption (`u128`); reset at every epoch
//!     boundary.
//!   * `pool_balances_eth` — per-pool-actor ETH (resource 0)
//!     NET balance (gross inflows minus drains).
//!   * `pool_balances_bold` — per-pool-actor BOLD (resource 1)
//!     NET balance.
//!
//! ## Wire shape
//!
//! Every row uses 8 BE bytes for the actor key + 16 BE bytes for
//! the value (a `u128`).  The fixed-width BE encoding ensures
//! lexicographic ordering matches numeric ordering, so a
//! `SELECT * FROM actor_budgets ORDER BY actor` returns actors in
//! ascending numeric order.
//!
//! ## Mathematical contract
//!
//! Let `E` be the indexer's consumed event stream.  Define:
//!   * `grants(a)` = sum of all budget credits to actor `a` in `E`
//!     (from tags 16 / 17 / 19).
//!   * `consumed(a, ep)` = sum of all `budgetConsumed a _` events
//!     in `E` whose seq is in epoch `ep`'s window.
//!   * `inflow(p, r)` = sum of all pool credits to actor `p` at
//!     resource `r` (from tags 16 / 17 / 19).
//!   * `drain(p, r)` = sum of all `gasPoolClaim r _ _` events in
//!     `E` matched against the configured `--gas-pool-actor` `p`.
//!
//! Then:
//!   * `actor_budgets[a]` = `saturating_sum(grants(a))`.
//!   * `actor_budgets_current_epoch_grants[a]` =
//!     `saturating_sum(grants(a) restricted to current epoch)`.
//!   * `actor_budgets_current_epoch_consumed[a]` =
//!     `saturating_sum(consumed(a, current_epoch))`.
//!   * `pool_balances_eth[p]` = `inflow(p, 0) - drain(p, 0)` if
//!     `p == configured gas_pool_actor`; else `inflow(p, 0)`.
//!   * `pool_balances_bold[p]` = symmetric for resource 1.
//!
//! Overflow on credit halts the indexer (matches
//! `BalanceView::credit`'s discipline; the transaction rolls back
//! via `?` propagation).  Underflow on drain rejects the batch
//! similarly.
//!
//! ## Security posture
//!
//! All SQL is parameterised; no string interpolation.  Defends
//! against SQL injection at the type system level.

use rusqlite::params;

use crate::sqlite::SqliteStorage;
use crate::storage::StorageError;

/// 64-bit actor identifier (mirrors Lean's `Authority.ActorId`).
pub type ActorId = u64;

/// 128-bit budget / pool counter (mirrors Lean's `Amount` /
/// `BudgetUnits`).  Stored as a 16-byte BE u128 in the underlying
/// table.
pub type CounterValue = u128;

/// Fixed-width on-disk key length (8-byte BE u64 actor id).
pub const ACTOR_KEY_LEN: usize = 8;

/// Fixed-width on-disk value length (16-byte BE u128).
pub const COUNTER_VALUE_LEN: usize = 16;

/// Budget-storage-layer errors.
#[derive(Debug, thiserror::Error)]
pub enum BudgetStorageError {
    /// The underlying storage failed.
    #[error("budget-storage error: {0}")]
    Storage(#[from] StorageError),
    /// A stored value had the wrong length (corrupt cell).
    #[error("corrupt {table} cell for actor {actor}: expected {expected} bytes, got {actual}")]
    CorruptCell {
        /// Which table's cell was corrupt
        /// (`actor_budgets` / `pool_balances_eth` /
        /// `pool_balances_bold` etc.).
        table: &'static str,
        /// Actor key whose cell was corrupt.
        actor: ActorId,
        /// Expected value length (always
        /// [`COUNTER_VALUE_LEN`]).
        expected: usize,
        /// Actual value length read from disk.
        actual: usize,
    },
    /// A credit operation overflowed `u128::MAX`.  Halts the
    /// caller's batch via `?` propagation (consistent with
    /// `BalanceView::credit`'s discipline).
    #[error("credit overflow on {table} for actor {actor}: current {current} + delta {delta} > u128::MAX")]
    CreditOverflow {
        /// Which table overflowed.
        table: &'static str,
        /// Actor key whose counter overflowed.
        actor: ActorId,
        /// Pre-overflow counter value.
        current: CounterValue,
        /// Delta that caused the overflow.
        delta: CounterValue,
    },
    /// A drain (debit) underflowed (pre-drain counter < drain
    /// amount).  Halts the caller's batch via `?`.
    #[error("drain underflow on {table} for actor {actor}: current {current} < delta {delta}")]
    DrainUnderflow {
        /// Which table underflowed.
        table: &'static str,
        /// Actor key whose counter underflowed.
        actor: ActorId,
        /// Pre-drain counter value.
        current: CounterValue,
        /// Delta that caused the underflow.
        delta: CounterValue,
    },
}

/// Encode an actor id as the canonical 8-byte BE key.
#[must_use]
pub fn actor_key(actor: ActorId) -> [u8; ACTOR_KEY_LEN] {
    actor.to_be_bytes()
}

/// Decode an actor id from an 8-byte BE key.  Returns `None` if
/// the key length is wrong.
#[must_use]
pub fn parse_actor_key(key: &[u8]) -> Option<ActorId> {
    if key.len() != ACTOR_KEY_LEN {
        return None;
    }
    let mut buf = [0u8; ACTOR_KEY_LEN];
    buf.copy_from_slice(key);
    Some(ActorId::from_be_bytes(buf))
}

/// Encode a counter value as a 16-byte BE u128.
#[must_use]
pub fn encode_counter(value: CounterValue) -> [u8; COUNTER_VALUE_LEN] {
    value.to_be_bytes()
}

/// Decode a 16-byte BE u128 to a counter value.  Returns `None`
/// if the byte slice has the wrong length.
#[must_use]
pub fn decode_counter(bytes: &[u8]) -> Option<CounterValue> {
    if bytes.len() != COUNTER_VALUE_LEN {
        return None;
    }
    let mut buf = [0u8; COUNTER_VALUE_LEN];
    buf.copy_from_slice(bytes);
    Some(CounterValue::from_be_bytes(buf))
}

/// The five table names created by `migration_002_budget_views`.
/// Loadbearing constants: any rename of an underlying table must
/// update these AND the migration AND the
/// `gp_6_4_tables_exist_after_migration` test in lockstep.
pub const TABLE_ACTOR_BUDGETS: &str = "actor_budgets";
/// The current-epoch grants table.
pub const TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS: &str = "actor_budgets_current_epoch_grants";
/// The current-epoch consumed table.
pub const TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED: &str = "actor_budgets_current_epoch_consumed";
/// The ETH-resource pool-balance table.
pub const TABLE_POOL_BALANCES_ETH: &str = "pool_balances_eth";
/// The BOLD-resource pool-balance table.
pub const TABLE_POOL_BALANCES_BOLD: &str = "pool_balances_bold";

/// Read-only budget-storage operations.
pub trait BudgetStorage: Send + Sync {
    /// Look up the lifetime cumulative budget grant for `actor`.
    /// Returns 0 if the cell is absent (the "no-cell-means-zero"
    /// convention shared with the balance view).
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn get_actor_budget(&self, actor: ActorId) -> Result<CounterValue, BudgetStorageError>;

    /// Look up the current-epoch grants counter for `actor`.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn get_actor_budget_current_epoch_grants(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Look up the current-epoch consumed counter for `actor`.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn get_actor_budget_current_epoch_consumed(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Look up the per-pool-actor ETH (resource 0) net balance.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn get_pool_eth(&self, pool_actor: ActorId) -> Result<CounterValue, BudgetStorageError>;

    /// Look up the per-pool-actor BOLD (resource 1) net balance.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn get_pool_bold(&self, pool_actor: ActorId) -> Result<CounterValue, BudgetStorageError>;

    /// Enumerate the entire `actor_budgets` table as
    /// `(actor, value)` pairs, in ascending actor order.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn scan_actor_budgets(&self) -> Result<Vec<(ActorId, CounterValue)>, BudgetStorageError>;

    /// Enumerate the `pool_balances_eth` table.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn scan_pool_eth(&self) -> Result<Vec<(ActorId, CounterValue)>, BudgetStorageError>;

    /// Enumerate the `pool_balances_bold` table.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn scan_pool_bold(&self) -> Result<Vec<(ActorId, CounterValue)>, BudgetStorageError>;

    /// Begin a transaction over the five budget / pool tables.
    /// The returned handle's mutations are not visible to other
    /// readers until [`BudgetStorageTransaction::commit`] is
    /// called successfully; dropping the handle (or calling
    /// `rollback`) discards all uncommitted mutations.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn budget_transaction(
        &self,
    ) -> Result<Box<dyn BudgetStorageTransaction + '_>, BudgetStorageError>;
}

/// Mutable budget-storage operations inside a transaction.
///
/// All mutations checked: credit operations propagate
/// [`BudgetStorageError::CreditOverflow`] on `u128::MAX` overflow
/// (consistent with `BalanceView::credit`'s halt-on-overflow
/// discipline); drain operations propagate
/// [`BudgetStorageError::DrainUnderflow`].
pub trait BudgetStorageTransaction {
    /// Read the lifetime cumulative budget grant for `actor`
    /// inside the transaction's view (sees staged mutations).
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn get_actor_budget(&self, actor: ActorId) -> Result<CounterValue, BudgetStorageError>;

    /// Read the current-epoch grants counter for `actor`.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn get_actor_budget_current_epoch_grants(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Read the current-epoch consumed counter for `actor`.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn get_actor_budget_current_epoch_consumed(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Read the per-pool-actor ETH (resource 0) net balance.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn get_pool_eth(&self, pool_actor: ActorId) -> Result<CounterValue, BudgetStorageError>;

    /// Read the per-pool-actor BOLD (resource 1) net balance.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn get_pool_bold(&self, pool_actor: ActorId) -> Result<CounterValue, BudgetStorageError>;

    /// Credit `delta` to `actor_budgets[actor]`.  Halts on
    /// overflow (propagates `CreditOverflow` so the caller's `?`
    /// rolls back the batch).
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn credit_actor_budget(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Credit `delta` to `actor_budgets_current_epoch_grants[actor]`.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn credit_actor_budget_current_epoch_grants(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Credit `delta` to
    /// `actor_budgets_current_epoch_consumed[actor]`.  Tracks
    /// consumption from the GP.6.4 `Event.budgetConsumed` event.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn credit_actor_budget_current_epoch_consumed(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Credit `delta` to `pool_balances_eth[pool_actor]`.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn credit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Credit `delta` to `pool_balances_bold[pool_actor]`.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn credit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Debit `delta` from `pool_balances_eth[pool_actor]`.  Halts
    /// on underflow.  Used for the GP.6.4 `Event.gasPoolClaim`
    /// drain wiring when `pool_actor` matches the configured
    /// `--gas-pool-actor` flag.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn debit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Debit `delta` from `pool_balances_bold[pool_actor]`.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn debit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError>;

    /// Reset the current-epoch counters (`grants` + `consumed`)
    /// for ALL actors.  Called once per epoch boundary crossing
    /// by the indexer's apply_batch when it detects that the
    /// log-derived current_epoch has changed.  Atomic with the
    /// rest of the transaction.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn reset_current_epoch(&mut self) -> Result<(), BudgetStorageError>;

    /// Commit the transaction.  Consumes the handle; on success,
    /// every staged mutation becomes visible atomically.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn commit(self: Box<Self>) -> Result<(), BudgetStorageError>;

    /// Discard the transaction.  Consumes the handle; no
    /// mutations become visible.
    ///
    /// # Errors
    ///
    /// See [`BudgetStorageError`].
    fn rollback(self: Box<Self>) -> Result<(), BudgetStorageError>;
}

// =====================================================================
// SQLite implementation
// =====================================================================

/// Helper used by every `get_*` method.  Reads the cell from the
/// given table for `actor`, returning 0 on absence and
/// `CorruptCell` on wrong-length values.
fn read_counter_cell(
    conn: &rusqlite::Connection,
    table: &'static str,
    actor: ActorId,
) -> Result<CounterValue, BudgetStorageError> {
    let key = actor_key(actor);
    // SAFETY: `table` is a compile-time constant from the
    // TABLE_* list above (NOT user input), so the formatted SQL
    // is safe.  The `actor` parameter is bound, not interpolated.
    let sql = format!("SELECT value FROM {table} WHERE actor = ?1");
    let row: Option<Vec<u8>> = conn
        .query_row(&sql, params![&key as &[u8]], |row| row.get::<_, Vec<u8>>(0))
        .map(Some)
        .or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other),
        })
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

/// Helper used by every `scan_*` method.
fn scan_counter_table(
    conn: &rusqlite::Connection,
    table: &'static str,
) -> Result<Vec<(ActorId, CounterValue)>, BudgetStorageError> {
    let sql = format!("SELECT actor, value FROM {table} ORDER BY actor ASC");
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
    let rows = stmt
        .query_map([], |row| {
            let key: Vec<u8> = row.get(0)?;
            let value: Vec<u8> = row.get(1)?;
            Ok((key, value))
        })
        .map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
    let mut out = Vec::new();
    for r in rows {
        let (key, value) =
            r.map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
        let actor = parse_actor_key(&key).ok_or(BudgetStorageError::CorruptCell {
            table,
            actor: 0,
            expected: ACTOR_KEY_LEN,
            actual: key.len(),
        })?;
        let v = decode_counter(&value).ok_or(BudgetStorageError::CorruptCell {
            table,
            actor,
            expected: COUNTER_VALUE_LEN,
            actual: value.len(),
        })?;
        out.push((actor, v));
    }
    Ok(out)
}

/// Read implementation: each read acquires the connection mutex
/// for the duration of the single read.
impl BudgetStorage for SqliteStorage {
    fn get_actor_budget(&self, actor: ActorId) -> Result<CounterValue, BudgetStorageError> {
        let conn = self.lock_connection();
        read_counter_cell(&conn, TABLE_ACTOR_BUDGETS, actor)
    }

    fn get_actor_budget_current_epoch_grants(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, BudgetStorageError> {
        let conn = self.lock_connection();
        read_counter_cell(&conn, TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS, actor)
    }

    fn get_actor_budget_current_epoch_consumed(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, BudgetStorageError> {
        let conn = self.lock_connection();
        read_counter_cell(&conn, TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED, actor)
    }

    fn get_pool_eth(&self, pool_actor: ActorId) -> Result<CounterValue, BudgetStorageError> {
        let conn = self.lock_connection();
        read_counter_cell(&conn, TABLE_POOL_BALANCES_ETH, pool_actor)
    }

    fn get_pool_bold(&self, pool_actor: ActorId) -> Result<CounterValue, BudgetStorageError> {
        let conn = self.lock_connection();
        read_counter_cell(&conn, TABLE_POOL_BALANCES_BOLD, pool_actor)
    }

    fn scan_actor_budgets(&self) -> Result<Vec<(ActorId, CounterValue)>, BudgetStorageError> {
        let conn = self.lock_connection();
        scan_counter_table(&conn, TABLE_ACTOR_BUDGETS)
    }

    fn scan_pool_eth(&self) -> Result<Vec<(ActorId, CounterValue)>, BudgetStorageError> {
        let conn = self.lock_connection();
        scan_counter_table(&conn, TABLE_POOL_BALANCES_ETH)
    }

    fn scan_pool_bold(&self) -> Result<Vec<(ActorId, CounterValue)>, BudgetStorageError> {
        let conn = self.lock_connection();
        scan_counter_table(&conn, TABLE_POOL_BALANCES_BOLD)
    }

    fn budget_transaction(
        &self,
    ) -> Result<Box<dyn BudgetStorageTransaction + '_>, BudgetStorageError> {
        let guard = self.lock_connection();
        // Recover any stale transaction state (defence in depth,
        // mirroring the kv-layer `recover_autocommit_if_needed`).
        if !guard.is_autocommit() {
            let _ = guard.execute_batch("ROLLBACK");
        }
        guard
            .execute_batch("BEGIN IMMEDIATE")
            .map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
        Ok(Box::new(SqliteBudgetTransaction {
            guard: Some(guard),
            finalised: false,
        }))
    }
}

/// Transaction handle bound to a [`SqliteStorage`].  Holds the
/// connection mutex for the transaction's lifetime so subsequent
/// operations serialize through the SAME connection (avoiding
/// the kind of "another thread joins my BEGIN" race that would
/// otherwise occur).
pub struct SqliteBudgetTransaction<'a> {
    /// Held for the transaction's lifetime; `None` after
    /// `commit` / `rollback` (which drop the guard explicitly to
    /// release the mutex before returning).
    guard: Option<std::sync::MutexGuard<'a, rusqlite::Connection>>,
    /// Tracks whether the inner `BEGIN` has been committed /
    /// rolled back.  On `Drop` without explicit
    /// `commit` / `rollback`, the destructor invokes ROLLBACK.
    finalised: bool,
}

impl SqliteBudgetTransaction<'_> {
    /// Apply a checked credit to the named table.  Reads current
    /// value, adds delta, halts on overflow, writes back.
    fn credit_table(
        &mut self,
        table: &'static str,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError> {
        let conn = self.guard.as_ref().ok_or_else(|| {
            BudgetStorageError::Storage(StorageError::Invalidated {
                reason: "budget transaction handle drained".to_string(),
            })
        })?;
        let current = read_counter_cell(conn, table, actor)?;
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

    /// Apply a checked drain (debit) to the named table.  Reads
    /// current value, halts on underflow, writes back.
    fn debit_table(
        &mut self,
        table: &'static str,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError> {
        let conn = self.guard.as_ref().ok_or_else(|| {
            BudgetStorageError::Storage(StorageError::Invalidated {
                reason: "budget transaction handle drained".to_string(),
            })
        })?;
        let current = read_counter_cell(conn, table, actor)?;
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

    /// Look up a counter under the transaction's view.
    fn read_table(
        &self,
        table: &'static str,
        actor: ActorId,
    ) -> Result<CounterValue, BudgetStorageError> {
        let conn = self.guard.as_ref().ok_or_else(|| {
            BudgetStorageError::Storage(StorageError::Invalidated {
                reason: "budget transaction handle drained".to_string(),
            })
        })?;
        read_counter_cell(conn, table, actor)
    }
}

impl BudgetStorageTransaction for SqliteBudgetTransaction<'_> {
    fn get_actor_budget(&self, actor: ActorId) -> Result<CounterValue, BudgetStorageError> {
        self.read_table(TABLE_ACTOR_BUDGETS, actor)
    }

    fn get_actor_budget_current_epoch_grants(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, BudgetStorageError> {
        self.read_table(TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS, actor)
    }

    fn get_actor_budget_current_epoch_consumed(
        &self,
        actor: ActorId,
    ) -> Result<CounterValue, BudgetStorageError> {
        self.read_table(TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED, actor)
    }

    fn get_pool_eth(&self, pool_actor: ActorId) -> Result<CounterValue, BudgetStorageError> {
        self.read_table(TABLE_POOL_BALANCES_ETH, pool_actor)
    }

    fn get_pool_bold(&self, pool_actor: ActorId) -> Result<CounterValue, BudgetStorageError> {
        self.read_table(TABLE_POOL_BALANCES_BOLD, pool_actor)
    }

    fn credit_actor_budget(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError> {
        self.credit_table(TABLE_ACTOR_BUDGETS, actor, delta)
    }

    fn credit_actor_budget_current_epoch_grants(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError> {
        self.credit_table(TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS, actor, delta)
    }

    fn credit_actor_budget_current_epoch_consumed(
        &mut self,
        actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError> {
        self.credit_table(TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED, actor, delta)
    }

    fn credit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError> {
        self.credit_table(TABLE_POOL_BALANCES_ETH, pool_actor, delta)
    }

    fn credit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError> {
        self.credit_table(TABLE_POOL_BALANCES_BOLD, pool_actor, delta)
    }

    fn debit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError> {
        self.debit_table(TABLE_POOL_BALANCES_ETH, pool_actor, delta)
    }

    fn debit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: CounterValue,
    ) -> Result<CounterValue, BudgetStorageError> {
        self.debit_table(TABLE_POOL_BALANCES_BOLD, pool_actor, delta)
    }

    fn reset_current_epoch(&mut self) -> Result<(), BudgetStorageError> {
        let conn = self.guard.as_ref().ok_or_else(|| {
            BudgetStorageError::Storage(StorageError::Invalidated {
                reason: "budget transaction handle drained".to_string(),
            })
        })?;
        conn.execute(
            &format!("DELETE FROM {TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS}"),
            [],
        )
        .map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
        conn.execute(
            &format!("DELETE FROM {TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED}"),
            [],
        )
        .map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
        Ok(())
    }

    fn commit(mut self: Box<Self>) -> Result<(), BudgetStorageError> {
        let conn = self.guard.as_ref().ok_or_else(|| {
            BudgetStorageError::Storage(StorageError::Invalidated {
                reason: "budget transaction already finalised".to_string(),
            })
        })?;
        conn.execute_batch("COMMIT")
            .map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
        self.finalised = true;
        // Explicitly release the guard so the mutex is unlocked
        // before returning (otherwise Drop would handle it but
        // making it explicit makes the lifetime obvious).
        drop(self.guard.take());
        Ok(())
    }

    fn rollback(mut self: Box<Self>) -> Result<(), BudgetStorageError> {
        let conn = self.guard.as_ref().ok_or_else(|| {
            BudgetStorageError::Storage(StorageError::Invalidated {
                reason: "budget transaction already finalised".to_string(),
            })
        })?;
        conn.execute_batch("ROLLBACK")
            .map_err(|e| BudgetStorageError::Storage(StorageError::Backend(e.to_string())))?;
        self.finalised = true;
        drop(self.guard.take());
        Ok(())
    }
}

impl Drop for SqliteBudgetTransaction<'_> {
    fn drop(&mut self) {
        if !self.finalised {
            if let Some(conn) = self.guard.as_ref() {
                // Best-effort rollback.  We can't propagate
                // errors from Drop; a ROLLBACK on a
                // already-committed/-rolled-back tx is a no-op
                // in SQLite.
                let _ = conn.execute_batch("ROLLBACK");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        actor_key, decode_counter, encode_counter, parse_actor_key, BudgetStorage,
        BudgetStorageError, ACTOR_KEY_LEN, COUNTER_VALUE_LEN, TABLE_ACTOR_BUDGETS,
        TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED, TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS,
        TABLE_POOL_BALANCES_BOLD, TABLE_POOL_BALANCES_ETH,
    };
    use crate::sqlite::SqliteStorage;

    /// Constants pinned.
    #[test]
    fn constants_stable() {
        assert_eq!(ACTOR_KEY_LEN, 8);
        assert_eq!(COUNTER_VALUE_LEN, 16);
        assert_eq!(TABLE_ACTOR_BUDGETS, "actor_budgets");
        assert_eq!(
            TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_GRANTS,
            "actor_budgets_current_epoch_grants"
        );
        assert_eq!(
            TABLE_ACTOR_BUDGETS_CURRENT_EPOCH_CONSUMED,
            "actor_budgets_current_epoch_consumed"
        );
        assert_eq!(TABLE_POOL_BALANCES_ETH, "pool_balances_eth");
        assert_eq!(TABLE_POOL_BALANCES_BOLD, "pool_balances_bold");
    }

    /// `actor_key` / `parse_actor_key` are inverses.
    #[test]
    fn actor_key_round_trip() {
        for &a in &[0u64, 1, 42, u64::MAX] {
            let k = actor_key(a);
            assert_eq!(parse_actor_key(&k).unwrap(), a);
        }
    }

    /// `parse_actor_key` rejects wrong-length keys.
    #[test]
    fn parse_actor_key_rejects_malformed() {
        assert!(parse_actor_key(&[0u8; 7]).is_none());
        assert!(parse_actor_key(&[0u8; 9]).is_none());
        assert!(parse_actor_key(&[]).is_none());
    }

    /// `encode_counter` / `decode_counter` are inverses.
    #[test]
    fn counter_round_trip() {
        for v in [0u128, 1, 42, u128::MAX, u128::from(u64::MAX)] {
            let b = encode_counter(v);
            assert_eq!(decode_counter(&b).unwrap(), v);
        }
    }

    /// `decode_counter` rejects wrong-length input.
    #[test]
    fn decode_counter_rejects_malformed() {
        assert!(decode_counter(&[0u8; 15]).is_none());
        assert!(decode_counter(&[0u8; 17]).is_none());
        assert!(decode_counter(&[]).is_none());
    }

    /// Brand-new database: all `get_*` return 0.
    #[test]
    fn fresh_db_reads_zero() {
        let s = SqliteStorage::open_in_memory().unwrap();
        assert_eq!(s.get_actor_budget(42).unwrap(), 0);
        assert_eq!(s.get_actor_budget_current_epoch_grants(42).unwrap(), 0);
        assert_eq!(s.get_actor_budget_current_epoch_consumed(42).unwrap(), 0);
        assert_eq!(s.get_pool_eth(1).unwrap(), 0);
        assert_eq!(s.get_pool_bold(1).unwrap(), 0);
    }

    /// `credit_actor_budget` then `get_actor_budget` round-trips.
    #[test]
    fn credit_and_read() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_actor_budget(42, 100).unwrap();
        tx.commit().unwrap();
        assert_eq!(s.get_actor_budget(42).unwrap(), 100);
    }

    /// Credits to different tables are independent.
    #[test]
    fn credits_to_different_tables_independent() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_actor_budget(42, 100).unwrap();
        tx.credit_pool_eth(42, 200).unwrap();
        tx.credit_pool_bold(42, 300).unwrap();
        tx.credit_actor_budget_current_epoch_grants(42, 50).unwrap();
        tx.credit_actor_budget_current_epoch_consumed(42, 25)
            .unwrap();
        tx.commit().unwrap();
        assert_eq!(s.get_actor_budget(42).unwrap(), 100);
        assert_eq!(s.get_pool_eth(42).unwrap(), 200);
        assert_eq!(s.get_pool_bold(42).unwrap(), 300);
        assert_eq!(s.get_actor_budget_current_epoch_grants(42).unwrap(), 50);
        assert_eq!(s.get_actor_budget_current_epoch_consumed(42).unwrap(), 25);
    }

    /// Cumulative credits accumulate.
    #[test]
    fn credits_accumulate() {
        let s = SqliteStorage::open_in_memory().unwrap();
        for delta in [10u128, 20, 30] {
            let mut tx = s.budget_transaction().unwrap();
            tx.credit_actor_budget(42, delta).unwrap();
            tx.commit().unwrap();
        }
        assert_eq!(s.get_actor_budget(42).unwrap(), 60);
    }

    /// Credit overflow halts the transaction with a typed error.
    #[test]
    fn credit_overflow_halts() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // Seed actor 42 to u128::MAX - 5.
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_actor_budget(42, u128::MAX - 5).unwrap();
        tx.commit().unwrap();
        // Try to credit 100 — overflow.
        let mut tx = s.budget_transaction().unwrap();
        match tx.credit_actor_budget(42, 100) {
            Err(BudgetStorageError::CreditOverflow {
                table,
                actor,
                current,
                delta,
            }) => {
                assert_eq!(table, "actor_budgets");
                assert_eq!(actor, 42);
                assert_eq!(current, u128::MAX - 5);
                assert_eq!(delta, 100);
            }
            other => panic!("expected CreditOverflow, got {other:?}"),
        }
        // Rollback to clean up.
        tx.rollback().unwrap();
        // Value unchanged.
        assert_eq!(s.get_actor_budget(42).unwrap(), u128::MAX - 5);
    }

    /// Debit drain on pool view succeeds when there's enough.
    #[test]
    fn debit_pool_eth_drain_succeeds() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_pool_eth(1, 1000).unwrap();
        tx.commit().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        let new_v = tx.debit_pool_eth(1, 300).unwrap();
        assert_eq!(new_v, 700);
        tx.commit().unwrap();
        assert_eq!(s.get_pool_eth(1).unwrap(), 700);
    }

    /// Debit underflow halts with a typed error.
    #[test]
    fn debit_underflow_halts() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_pool_eth(1, 100).unwrap();
        tx.commit().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        match tx.debit_pool_eth(1, 500) {
            Err(BudgetStorageError::DrainUnderflow {
                table,
                actor,
                current,
                delta,
            }) => {
                assert_eq!(table, "pool_balances_eth");
                assert_eq!(actor, 1);
                assert_eq!(current, 100);
                assert_eq!(delta, 500);
            }
            other => panic!("expected DrainUnderflow, got {other:?}"),
        }
        tx.rollback().unwrap();
        // Cell unchanged.
        assert_eq!(s.get_pool_eth(1).unwrap(), 100);
    }

    /// `scan_actor_budgets` returns entries in ascending actor
    /// order.
    #[test]
    fn scan_actor_budgets_ascending_order() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_actor_budget(5, 50).unwrap();
        tx.credit_actor_budget(1, 10).unwrap();
        tx.credit_actor_budget(99, 99).unwrap();
        tx.commit().unwrap();
        let rows = s.scan_actor_budgets().unwrap();
        assert_eq!(rows, vec![(1, 10), (5, 50), (99, 99)]);
    }

    /// `scan_pool_eth` / `scan_pool_bold` are independent.
    #[test]
    fn scan_pool_views_independent() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_pool_eth(1, 100).unwrap();
        tx.credit_pool_bold(2, 200).unwrap();
        tx.commit().unwrap();
        assert_eq!(s.scan_pool_eth().unwrap(), vec![(1, 100)]);
        assert_eq!(s.scan_pool_bold().unwrap(), vec![(2, 200)]);
    }

    /// Transaction rollback discards every staged mutation.
    #[test]
    fn rollback_discards_mutations() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_actor_budget(42, 100).unwrap();
        tx.credit_pool_eth(1, 200).unwrap();
        tx.rollback().unwrap();
        assert_eq!(s.get_actor_budget(42).unwrap(), 0);
        assert_eq!(s.get_pool_eth(1).unwrap(), 0);
    }

    /// Dropping a transaction without commit/rollback ROLLBACKs
    /// (defence against forgotten commits).
    #[test]
    fn drop_without_commit_rollbacks() {
        let s = SqliteStorage::open_in_memory().unwrap();
        {
            let mut tx = s.budget_transaction().unwrap();
            tx.credit_actor_budget(42, 100).unwrap();
            // `tx` dropped here without commit.
        }
        // Value not persisted.
        assert_eq!(s.get_actor_budget(42).unwrap(), 0);
    }

    /// `reset_current_epoch` truncates both per-epoch tables but
    /// leaves the lifetime grant table untouched.
    #[test]
    fn reset_current_epoch_truncates_grants_and_consumed_only() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_actor_budget(42, 1000).unwrap(); // lifetime
        tx.credit_actor_budget_current_epoch_grants(42, 100)
            .unwrap(); // current epoch
        tx.credit_actor_budget_current_epoch_consumed(42, 50)
            .unwrap();
        tx.credit_pool_eth(1, 999).unwrap();
        tx.commit().unwrap();
        // Now reset.
        let mut tx = s.budget_transaction().unwrap();
        tx.reset_current_epoch().unwrap();
        tx.commit().unwrap();
        // Lifetime grants unchanged.
        assert_eq!(s.get_actor_budget(42).unwrap(), 1000);
        // Current-epoch counters wiped.
        assert_eq!(s.get_actor_budget_current_epoch_grants(42).unwrap(), 0);
        assert_eq!(s.get_actor_budget_current_epoch_consumed(42).unwrap(), 0);
        // Pool views unchanged.
        assert_eq!(s.get_pool_eth(1).unwrap(), 999);
    }

    /// Transaction-bound read sees the staged value (read-your-writes).
    #[test]
    fn tx_read_your_writes() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_actor_budget(42, 100).unwrap();
        assert_eq!(tx.get_actor_budget(42).unwrap(), 100);
        tx.credit_actor_budget(42, 50).unwrap();
        assert_eq!(tx.get_actor_budget(42).unwrap(), 150);
        tx.commit().unwrap();
        assert_eq!(s.get_actor_budget(42).unwrap(), 150);
    }

    /// u64::MAX actor handled.
    #[test]
    fn u64_max_actor_handled() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_actor_budget(u64::MAX, 999).unwrap();
        tx.commit().unwrap();
        assert_eq!(s.get_actor_budget(u64::MAX).unwrap(), 999);
        let rows = s.scan_actor_budgets().unwrap();
        assert_eq!(rows, vec![(u64::MAX, 999)]);
    }

    /// Zero credit succeeds + creates a cell with value 0 (vs.
    /// absence).  Pinned so a future "skip-zero-credit"
    /// optimisation has to update this test deliberately.
    #[test]
    fn zero_credit_creates_cell() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.budget_transaction().unwrap();
        tx.credit_actor_budget(42, 0).unwrap();
        tx.commit().unwrap();
        let rows = s.scan_actor_budgets().unwrap();
        assert_eq!(rows, vec![(42, 0)]);
    }
}
