// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Append-only migration scaffolding (RH-E.0.d).
//!
//! ## Design
//!
//! Migrations are listed in a fixed [`MIGRATIONS`] table, in
//! ascending order.  Each migration's index in the table is its
//! schema version: the first entry is version 1, the second
//! version 2, etc.  Migration 0 (the empty initial state) is
//! implicit — a freshly-created database starts at version 0 and
//! immediately runs every migration in the table to reach the
//! current version.
//!
//! ## Append-only discipline
//!
//! Once a migration is published in a release of `knomosis-storage`,
//! its index and body are **frozen**.  Modifying a landed
//! migration is a backwards-incompatible change that breaks every
//! database created against the old version: an operator who
//! upgrades the binary will see an inconsistent schema and the
//! migration runner will refuse to load.
//!
//! Schema changes are made by **appending** a new migration to the
//! table.  The new migration body runs `ALTER TABLE`, `CREATE
//! INDEX`, `INSERT INTO`, etc. to evolve the schema in-place; the
//! version counter is bumped only after every statement succeeds.
//!
//! ## Down-migrations
//!
//! Down-migrations are not supported in v1.  Operators who need to
//! roll back a binary release also need to restore a database
//! backup from before the upgrade; `knomosis-storage` does not provide
//! automated rollback.
//!
//! ## Atomicity
//!
//! Each migration runs inside its own SQLite transaction.  If any
//! statement fails, the transaction is rolled back and the version
//! counter is NOT bumped — the database remains at its pre-migration
//! version, and the next `open()` will retry from that version.
//! Operators who hit a migration failure see a typed
//! [`crate::storage::StorageError::MigrationFailed`] error and can
//! intervene before retrying.

use crate::storage::StorageError;
use rusqlite::{params, Connection, TransactionBehavior};

/// Name of the metadata table that stores the schema version.
///
/// Reserved namespace: any key in `_meta` starting with `schema_`
/// is reserved for this module.  Downstream users of
/// `knomosis-storage` MUST NOT write to `_meta` directly; they use
/// the public `Storage::put`/`get` interface which operates on
/// the `kv` table.
pub const META_TABLE: &str = "_meta";

/// Key in the metadata table that stores the current schema
/// version as a decimal string.
pub const SCHEMA_VERSION_KEY: &str = "schema_version";

/// A single migration step.
///
/// Each migration is a pair of:
///   * a short human-readable name (operator-visible in logs);
///   * a function that runs inside a SQLite transaction and is
///     expected to evolve the schema by exactly one version.
///
/// The function MAY use any SQLite DDL or DML.  It MUST be
/// idempotent at the binary level — i.e. running the same binary
/// twice against a database that has not been touched between runs
/// MUST produce the same result.  (Migrations are run only once
/// per database, but the migration runner reads the on-disk
/// version before running each one, so re-running the same binary
/// after a successful migration is a no-op.)
pub struct Migration {
    /// Operator-visible name for diagnostics.
    pub name: &'static str,
    /// Function that applies the migration.  Takes a connection
    /// already inside a transaction; returns `Ok(())` on success
    /// or an `Err` carrying a backend-specific reason.  The runner
    /// commits the transaction (and bumps the version counter)
    /// only on `Ok`.
    pub apply: fn(&Connection) -> Result<(), rusqlite::Error>,
}

/// The frozen migration table.  Entries are 1-indexed by position
/// (entry 0 in this slice is schema version 1, entry 1 is version
/// 2, etc.).
///
/// **Append-only.**  Adding a new migration is a workspace-level
/// PR per the engineering plan §7 risk register.  Modifying or
/// removing an existing entry is a backwards-incompatible change
/// to every database created against the old version.
pub const MIGRATIONS: &[Migration] = &[
    Migration {
        name: "initial_kv_table",
        apply: migration_001_initial_kv_table,
    },
    Migration {
        name: "gp_6_4_budget_views",
        apply: migration_002_budget_views,
    },
    Migration {
        name: "widen_amount_cells",
        apply: migration_003_widen_amount_cells,
    },
];

/// Compile-time assertion that the migration table fits in u32.
/// Without this, a future PR that adds u32::MAX + 1 migrations
/// would silently truncate the version counter.  At time of
/// writing (1 migration), this is trivially below the cap.
const _MIGRATIONS_FIT_IN_U32: () = assert!(
    MIGRATIONS.len() <= u32::MAX as usize,
    "knomosis-storage MIGRATIONS table overflows u32"
);

/// The schema version this binary expects after every migration
/// has run.  Equals `MIGRATIONS.len()` cast to `u32` (the cap is
/// enforced statically by `_MIGRATIONS_FIT_IN_U32`).
#[must_use]
pub const fn target_schema_version() -> u32 {
    MIGRATIONS.len() as u32
}

/// Read the current schema version from `META_TABLE`.  Returns
/// `0` if the meta table doesn't exist (database is brand-new) or
/// if `SCHEMA_VERSION_KEY` is not present.
///
/// # Errors
///
/// Returns `Err` only on a real backend failure; the
/// "meta-table-missing" case is treated as version 0.
pub fn current_schema_version(conn: &Connection) -> Result<u32, StorageError> {
    // Probe whether the meta table exists.  `sqlite_master` is
    // SQLite's built-in catalogue; reading it can never produce
    // SQL injection because the query is a static string with a
    // single bound parameter.
    let table_exists: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            params![META_TABLE],
            |row| row.get(0),
        )
        .map_err(|e| StorageError::Backend(format!("meta-table existence probe failed: {e}")))?;
    if table_exists == 0 {
        return Ok(0);
    }
    // Meta table exists; look up the schema-version key.
    let value: Option<String> = conn
        .query_row(
            // SAFETY: META_TABLE is a compile-time constant
            // string, not user input — no SQL injection risk.
            &format!("SELECT value FROM {META_TABLE} WHERE key = ?1"),
            params![SCHEMA_VERSION_KEY],
            |row| row.get(0),
        )
        .map(Some)
        .or_else(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other),
        })
        .map_err(|e| StorageError::Backend(format!("schema-version read failed: {e}")))?;
    let Some(text) = value else {
        return Ok(0);
    };
    text.parse::<u32>().map_err(|e| {
        StorageError::Backend(format!(
            "schema-version value {text:?} is not a valid u32: {e}"
        ))
    })
}

/// Write the schema version into `META_TABLE`.  Internal helper
/// called by [`apply_migrations`] after each successful migration.
fn write_schema_version(conn: &Connection, version: u32) -> Result<(), rusqlite::Error> {
    conn.execute(
        &format!(
            "INSERT INTO {META_TABLE}(key, value) VALUES (?1, ?2) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        ),
        params![SCHEMA_VERSION_KEY, version.to_string()],
    )?;
    Ok(())
}

/// Apply every pending migration in [`MIGRATIONS`] sequentially.
/// After this returns, the on-disk schema version matches
/// [`target_schema_version`].
///
/// # Errors
///
/// * [`StorageError::MigrationMismatch`] if the on-disk version is
///   strictly greater than the binary's target (forward
///   incompatibility — the database was written by a newer binary).
/// * [`StorageError::MigrationFailed`] if any migration body
///   returns an error.  The migration's transaction is rolled back
///   by the backend; the database remains at the pre-migration
///   version.
/// * [`StorageError::Backend`] for other backend failures (version
///   read, version write, etc.).
pub fn apply_migrations(conn: &mut Connection) -> Result<(), StorageError> {
    // Ensure the meta table exists.  Idempotent: `IF NOT EXISTS`.
    conn.execute(
        &format!(
            "CREATE TABLE IF NOT EXISTS {META_TABLE}(\
                key TEXT PRIMARY KEY NOT NULL, \
                value TEXT NOT NULL)"
        ),
        [],
    )
    .map_err(|e| StorageError::Backend(format!("meta-table CREATE failed: {e}")))?;

    let target = target_schema_version();
    let mut current = current_schema_version(conn)?;

    if current > target {
        return Err(StorageError::MigrationMismatch {
            expected: target,
            found: current,
        });
    }

    while current < target {
        // Use BEGIN IMMEDIATE to acquire the write lock at the
        // BEGIN itself rather than at the first write.  This
        // closes a multi-process race window: with BEGIN
        // DEFERRED, two processes could both read version=0
        // before either tries to write; with BEGIN IMMEDIATE,
        // only one can hold the write lock at a time, and the
        // loser's read inside its eventual transaction sees the
        // winner's committed version.
        let tx = conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| StorageError::Backend(format!("migration BEGIN failed: {e}")))?;
        // Re-read the version INSIDE the transaction.  Combined
        // with BEGIN IMMEDIATE above, this provides
        // serialisable migration semantics: each migration sees
        // the actual on-disk version (post any earlier
        // committed migration) when it decides what to apply.
        let in_tx_version = current_schema_version(&tx)?;
        if in_tx_version > target {
            return Err(StorageError::MigrationMismatch {
                expected: target,
                found: in_tx_version,
            });
        }
        if in_tx_version >= target {
            // Another process applied every remaining migration
            // while we were starting the transaction.  Nothing to
            // do — let the transaction drop (auto-rollback) and
            // exit the loop.
            break;
        }
        // `in_tx_version` is a u32 in [0, target); cast to usize
        // is safe because `target <= u32::MAX` (enforced by
        // `target_schema_version`) and `usize` is at least 32-bit
        // on every supported target.
        let migration_index = in_tx_version as usize;
        let migration = &MIGRATIONS[migration_index];
        let next_version = in_tx_version + 1;
        tracing::debug!(
            from = in_tx_version,
            to = next_version,
            name = migration.name,
            "applying knomosis-storage migration"
        );
        if let Err(e) = (migration.apply)(&tx) {
            // tx is dropped → automatic rollback.
            return Err(StorageError::MigrationFailed {
                index: next_version,
                reason: e.to_string(),
            });
        }
        if let Err(e) = write_schema_version(&tx, next_version) {
            return Err(StorageError::MigrationFailed {
                index: next_version,
                reason: format!("post-apply schema-version write: {e}"),
            });
        }
        tx.commit().map_err(|e| StorageError::MigrationFailed {
            index: next_version,
            reason: format!("transaction commit: {e}"),
        })?;

        current = next_version;
    }

    Ok(())
}

/// First migration: create the `kv(key BLOB PRIMARY KEY, value
/// BLOB NOT NULL)` table that the SQLite implementation reads /
/// writes through the [`crate::storage::Storage`] trait.
///
/// Frozen at index 1 (schema version 1).
fn migration_001_initial_kv_table(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS kv(\
            key BLOB PRIMARY KEY NOT NULL, \
            value BLOB NOT NULL) WITHOUT ROWID",
        [],
    )?;
    Ok(())
}

/// Second migration (Workstream GP / GP.6.4): create the three
/// per-actor budget / pool tables that
/// `knomosis-indexer::budget_view` consumes.
///
/// Tables created:
///   * `actor_budgets(actor BLOB PRIMARY KEY, value BLOB)`:
///     per-actor cumulative budget grants (16-byte BE u128).
///   * `actor_budgets_current_epoch_grants(actor BLOB PRIMARY KEY,
///     value BLOB)`: per-actor budget grants in the current epoch,
///     reset at every epoch boundary.
///   * `actor_budgets_current_epoch_consumed(actor BLOB PRIMARY
///     KEY, value BLOB)`: per-actor budget consumption (from
///     `Event.budgetConsumed`, tag 20) in the current epoch.
///   * `pool_balances_eth(actor BLOB PRIMARY KEY, value BLOB)`:
///     per-pool-actor ETH (resource 0) cumulative inflows / net
///     balance.
///   * `pool_balances_bold(actor BLOB PRIMARY KEY, value BLOB)`:
///     per-pool-actor BOLD (resource 1) cumulative inflows / net
///     balance.
///
/// All five tables use 8-byte BE actor keys + 16-byte BE u128
/// values.  `WITHOUT ROWID` aligns with the `kv` table for
/// consistency; the small fixed-size keys mean the rowid would be
/// pure overhead.
///
/// A sixth `_meta` cell `gp_6_4_current_epoch` records the
/// current epoch number (decimal `u64` text) for the indexer to
/// detect epoch crossings.
///
/// Frozen at index 2 (schema version 2).
///
/// **Idempotency**: every `CREATE TABLE` uses `IF NOT EXISTS`, so
/// a re-run against a partially-applied schema (e.g., crash
/// recovery) succeeds.
fn migration_002_budget_views(conn: &Connection) -> Result<(), rusqlite::Error> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS actor_budgets(\
            actor BLOB PRIMARY KEY NOT NULL, \
            value BLOB NOT NULL) WITHOUT ROWID",
        [],
    )?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS actor_budgets_current_epoch_grants(\
            actor BLOB PRIMARY KEY NOT NULL, \
            value BLOB NOT NULL) WITHOUT ROWID",
        [],
    )?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS actor_budgets_current_epoch_consumed(\
            actor BLOB PRIMARY KEY NOT NULL, \
            value BLOB NOT NULL) WITHOUT ROWID",
        [],
    )?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS pool_balances_eth(\
            actor BLOB PRIMARY KEY NOT NULL, \
            value BLOB NOT NULL) WITHOUT ROWID",
        [],
    )?;
    conn.execute(
        "CREATE TABLE IF NOT EXISTS pool_balances_bold(\
            actor BLOB PRIMARY KEY NOT NULL, \
            value BLOB NOT NULL) WITHOUT ROWID",
        [],
    )?;
    Ok(())
}

/// The value width every amount-valued cell used before
/// [`migration_003_widen_amount_cells`] ran.
///
/// Frozen at the retired `u128` width.  Deliberately a local constant
/// rather than a reference to anything current: a migration describes
/// the shape of the data it FINDS, and pinning it to a live constant
/// would silently change what the migration matches the next time that
/// constant moves.
const RETIRED_AMOUNT_VALUE_LEN: usize = 16;

/// Third migration: widen every amount-valued cell from the retired
/// 16-byte encoding to the 32-byte one
/// [`knomosis_amount::Amount`] uses.
///
/// # Why the widening is lossless
///
/// Big-endian zero-extension preserves the value exactly: a 16-byte BE
/// integer and the same integer written in 32 BE bytes denote the same
/// number, because the sixteen added bytes are leading zeros.  No cell
/// can fail to fit, since every `u128` is representable as an
/// `Amount`.  The migration therefore cannot lose or change data — it
/// only re-spells it.
///
/// # What gets widened
///
///   * the `kv` table's balance cells — those and only those, matched
///     by the `b/` key prefix `knomosis-indexer` writes.  Every other
///     `kv` keyspace (the cursor, and anything a later workstream
///     adds) is left untouched, so a migration for balances cannot
///     corrupt a neighbouring keyspace that happens to hold a 16-byte
///     value;
///   * all five budget / pool tables from
///     `migration_002_budget_views`, whose values are the same
///     fixed-width integers.
///
/// # Why it is written in Rust rather than as one `UPDATE`
///
/// The obvious SQL — `SET value = zeroblob(16) || value` — is WRONG.
/// SQLite's `||` is string concatenation: it coerces both operands to
/// TEXT, which mangles any blob containing a NUL byte, and a balance
/// cell is mostly NUL bytes. Doing the re-encode in Rust keeps the
/// transformation on typed bytes.
///
/// # Idempotency and partial application
///
/// Every statement filters on `length(value) = 16`, so a cell that is
/// already 32 bytes is skipped.  Re-running the migration against a
/// fully- or partially-widened database is a no-op on the widened
/// rows.  The whole body runs inside the caller's transaction
/// ([`apply_migrations`] opens `BEGIN IMMEDIATE`), so a failure rolls
/// the database back to the pre-migration version rather than leaving
/// a half-widened table.
///
/// Frozen at index 3 (schema version 3).
fn migration_003_widen_amount_cells(conn: &Connection) -> Result<(), rusqlite::Error> {
    // The `kv` balance cells.  `substr(key, 1, 2) = 'b/'` mirrors
    // `knomosis_indexer::balance::BALANCE_KEY_PREFIX`; the length
    // filter keeps the rewrite to cells still at the retired width.
    widen_rows(
        conn,
        "SELECT key, value FROM kv \
         WHERE substr(key, 1, 2) = CAST('b/' AS BLOB) AND length(value) = ?1",
        "UPDATE kv SET value = ?2 WHERE key = ?1",
    )?;

    // The five budget / pool tables, all keyed by `actor`.
    for table in [
        "actor_budgets",
        "actor_budgets_current_epoch_grants",
        "actor_budgets_current_epoch_consumed",
        "pool_balances_eth",
        "pool_balances_bold",
    ] {
        widen_rows(
            conn,
            // SAFETY: `table` comes from the literal array above, not
            // from user input -- no SQL injection risk.
            &format!("SELECT actor, value FROM {table} WHERE length(value) = ?1"),
            &format!("UPDATE {table} SET value = ?2 WHERE actor = ?1"),
        )?;
    }
    Ok(())
}

/// Read every `(key, value)` the `select_sql` returns and rewrite the
/// value zero-extended to [`knomosis_amount::AMOUNT_BYTES`].
///
/// The rows are collected BEFORE any update is issued: holding a
/// prepared-statement cursor open across writes to the same table is
/// exactly the pattern SQLite's documentation warns produces
/// undefined iteration behaviour.
fn widen_rows(
    conn: &Connection,
    select_sql: &str,
    update_sql: &str,
) -> Result<(), rusqlite::Error> {
    let rows: Vec<(Vec<u8>, Vec<u8>)> = {
        let mut stmt = conn.prepare(select_sql)?;
        let mapped = stmt.query_map(params![RETIRED_AMOUNT_VALUE_LEN as i64], |row| {
            Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?))
        })?;
        mapped.collect::<Result<Vec<_>, _>>()?
    };

    for (key, narrow) in rows {
        // Zero-extend into the high bytes -- big-endian, so the
        // retired value keeps its place at the LOW end.
        let mut wide = [0u8; knomosis_amount::AMOUNT_BYTES];
        let start = knomosis_amount::AMOUNT_BYTES - narrow.len();
        wide[start..].copy_from_slice(&narrow);
        conn.execute(update_sql, params![&key as &[u8], &wide as &[u8]])?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        apply_migrations, current_schema_version, migration_001_initial_kv_table,
        migration_002_budget_views, migration_003_widen_amount_cells, target_schema_version,
        MIGRATIONS,
    };
    use rusqlite::params;
    use rusqlite::Connection;

    /// `MIGRATIONS` table is non-empty.  Adding the first migration
    /// is the contract anchor.
    #[test]
    fn migrations_non_empty() {
        // Pin the documented constraint: at least one migration must
        // exist in every released binary.  Clippy's
        // `const_is_empty` lint would otherwise reject the assertion
        // as "always true / always false" — but the assertion is the
        // contract we want surfaced if a future PR ever removes
        // every migration.
        let count = MIGRATIONS.len();
        assert!(count > 0, "MIGRATIONS table must be non-empty");
    }

    /// The first migration is the `initial_kv_table` step (frozen
    /// at index 1).  This is the load-bearing contract: any binary
    /// expecting schema version 1 to be "the kv table" reads this
    /// list to confirm.
    #[test]
    fn first_migration_is_initial_kv_table() {
        assert_eq!(MIGRATIONS[0].name, "initial_kv_table");
    }

    /// The second migration is the `gp_6_4_budget_views` step
    /// (frozen at index 2 / schema version 2).  Same load-bearing
    /// contract as the index-1 migration: tools / operators
    /// expecting schema-version 2 to mean "the GP.6.4 budget /
    /// pool tables exist" read this constant to confirm.
    #[test]
    fn second_migration_is_gp_6_4_budget_views() {
        assert!(MIGRATIONS.len() >= 2, "expected at least 2 migrations");
        assert_eq!(MIGRATIONS[1].name, "gp_6_4_budget_views");
    }

    /// After migrations apply, the five GP.6.4 tables exist.
    /// Pins the migration's DDL side effects against the
    /// migration's name; any future PR that renames a table must
    /// also update this list (and update the indexer's
    /// `budget_view.rs` to match).
    #[test]
    fn gp_6_4_tables_exist_after_migration() {
        let mut conn = Connection::open_in_memory().unwrap();
        apply_migrations(&mut conn).unwrap();
        for table in [
            "actor_budgets",
            "actor_budgets_current_epoch_grants",
            "actor_budgets_current_epoch_consumed",
            "pool_balances_eth",
            "pool_balances_bold",
        ] {
            let count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    rusqlite::params![table],
                    |row| row.get(0),
                )
                .unwrap_or_else(|e| panic!("table existence probe failed for {table}: {e}"));
            assert_eq!(count, 1, "table {table} not created by migration_002");
        }
    }

    /// The GP.6.4 tables share a uniform schema: `actor BLOB
    /// PRIMARY KEY NOT NULL` + `value BLOB NOT NULL`, both
    /// `WITHOUT ROWID`.  Pin the schema shape so a future PR that
    /// changes a column type / NULLability / WITHOUT-ROWID is
    /// caught up front.
    #[test]
    fn gp_6_4_tables_have_uniform_schema() {
        let mut conn = Connection::open_in_memory().unwrap();
        apply_migrations(&mut conn).unwrap();
        for table in [
            "actor_budgets",
            "actor_budgets_current_epoch_grants",
            "actor_budgets_current_epoch_consumed",
            "pool_balances_eth",
            "pool_balances_bold",
        ] {
            let sql_lower: String = conn
                .query_row(
                    "SELECT LOWER(sql) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    rusqlite::params![table],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(
                sql_lower.contains("actor blob primary key not null"),
                "table {table}: missing canonical actor column ({sql_lower})"
            );
            assert!(
                sql_lower.contains("value blob not null"),
                "table {table}: missing canonical value column ({sql_lower})"
            );
            assert!(
                sql_lower.contains("without rowid"),
                "table {table}: missing WITHOUT ROWID ({sql_lower})"
            );
        }
    }

    /// Re-applying migrations on an already-up-to-date DB is a no-op.
    /// Catches accidental side effects in the migration body.
    #[test]
    fn gp_6_4_migration_idempotent() {
        let mut conn = Connection::open_in_memory().unwrap();
        apply_migrations(&mut conn).unwrap();
        let v1 = current_schema_version(&conn).unwrap();
        apply_migrations(&mut conn).unwrap();
        let v2 = current_schema_version(&conn).unwrap();
        assert_eq!(v1, v2);
        assert_eq!(v2, target_schema_version());
    }

    /// `target_schema_version` matches the table length cast to
    /// u32.
    #[test]
    fn target_version_matches_table_length() {
        assert_eq!(target_schema_version() as usize, MIGRATIONS.len());
    }

    /// Fresh database starts at version 0.
    #[test]
    fn fresh_db_version_is_zero() {
        let conn = Connection::open_in_memory().unwrap();
        let v = current_schema_version(&conn).unwrap();
        assert_eq!(v, 0);
    }

    /// Apply migrations on a fresh DB → final version equals target.
    #[test]
    fn apply_brings_fresh_db_to_target() {
        let mut conn = Connection::open_in_memory().unwrap();
        apply_migrations(&mut conn).unwrap();
        let v = current_schema_version(&conn).unwrap();
        assert_eq!(v, target_schema_version());
    }

    /// Re-applying on an up-to-date DB is a no-op.
    #[test]
    fn apply_is_idempotent() {
        let mut conn = Connection::open_in_memory().unwrap();
        apply_migrations(&mut conn).unwrap();
        let v1 = current_schema_version(&conn).unwrap();
        apply_migrations(&mut conn).unwrap();
        let v2 = current_schema_version(&conn).unwrap();
        assert_eq!(v1, v2);
        assert_eq!(v2, target_schema_version());
    }

    /// After migrations apply, the kv table exists.
    #[test]
    fn kv_table_exists_after_migration() {
        let mut conn = Connection::open_in_memory().unwrap();
        apply_migrations(&mut conn).unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'kv'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    /// After migrations apply, the meta table exists with the
    /// correct schema_version value.
    #[test]
    fn meta_table_records_version() {
        let mut conn = Connection::open_in_memory().unwrap();
        apply_migrations(&mut conn).unwrap();
        let v: String = conn
            .query_row(
                "SELECT value FROM _meta WHERE key = 'schema_version'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(v, target_schema_version().to_string());
    }

    /// Forward-incompatibility: if the on-disk version is greater
    /// than the binary's target, we return MigrationMismatch.
    #[test]
    fn forward_incompatibility_detected() {
        let mut conn = Connection::open_in_memory().unwrap();
        apply_migrations(&mut conn).unwrap();
        // Simulate a future version on disk.
        conn.execute(
            "INSERT INTO _meta(key, value) VALUES ('schema_version', '999999') \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [],
        )
        .unwrap();
        match apply_migrations(&mut conn) {
            Err(crate::storage::StorageError::MigrationMismatch { expected, found }) => {
                assert_eq!(expected, target_schema_version());
                assert_eq!(found, 999_999);
            }
            other => panic!("expected MigrationMismatch, got {other:?}"),
        }
    }

    /// Malformed schema-version value (not a valid u32) → backend
    /// error.
    #[test]
    fn malformed_version_value_errors() {
        let mut conn = Connection::open_in_memory().unwrap();
        // Initialise the meta table by running migrations first.
        apply_migrations(&mut conn).unwrap();
        // Corrupt the version to a non-numeric string.
        conn.execute(
            "UPDATE _meta SET value = 'not-a-number' WHERE key = 'schema_version'",
            [],
        )
        .unwrap();
        match current_schema_version(&conn) {
            Err(crate::storage::StorageError::Backend(msg)) => {
                assert!(msg.contains("not a valid u32"));
            }
            other => panic!("expected Backend error, got {other:?}"),
        }
    }

    // ------------------------------------------------------------------
    // migration_003_widen_amount_cells
    // ------------------------------------------------------------------

    /// A database written at the retired 16-byte width is widened
    /// LOSSLESSLY: every value keeps its number, only its spelling
    /// changes.
    ///
    /// The check is arithmetic, not byte-comparative: each seeded
    /// `u128` must read back as the same integer from the 32-byte
    /// cell.  A byte-comparative assertion would pass for a migration
    /// that zero-extended on the WRONG end (which would multiply every
    /// balance by `2^128`), so the values are re-derived instead.
    #[test]
    fn widening_preserves_every_value() {
        let conn = Connection::open_in_memory().unwrap();
        // Bring the schema to v2, the last version before the widening.
        migration_001_initial_kv_table(&conn).unwrap();
        migration_002_budget_views(&conn).unwrap();

        // Values spanning the retired range, including both ends.
        let probes: [u128; 5] = [0, 1, 1_000_000, u128::MAX - 1, u128::MAX];

        for (i, v) in probes.iter().enumerate() {
            let mut key = b"b/".to_vec();
            key.extend_from_slice(&(i as u64).to_be_bytes());
            key.extend_from_slice(&0u64.to_be_bytes());
            conn.execute(
                "INSERT INTO kv(key, value) VALUES (?1, ?2)",
                params![&key as &[u8], &v.to_be_bytes() as &[u8]],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO actor_budgets(actor, value) VALUES (?1, ?2)",
                params![
                    &(i as u64).to_be_bytes() as &[u8],
                    &v.to_be_bytes() as &[u8]
                ],
            )
            .unwrap();
        }

        migration_003_widen_amount_cells(&conn).unwrap();

        for (i, v) in probes.iter().enumerate() {
            let mut key = b"b/".to_vec();
            key.extend_from_slice(&(i as u64).to_be_bytes());
            key.extend_from_slice(&0u64.to_be_bytes());
            let got: Vec<u8> = conn
                .query_row(
                    "SELECT value FROM kv WHERE key = ?1",
                    params![&key as &[u8]],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(
                got.len(),
                knomosis_amount::AMOUNT_BYTES,
                "kv cell must be widened"
            );
            assert_eq!(
                knomosis_amount::Amount::from_be_slice(&got).unwrap(),
                knomosis_amount::Amount::from_u128(*v),
                "kv value changed under the widening"
            );

            let got: Vec<u8> = conn
                .query_row(
                    "SELECT value FROM actor_budgets WHERE actor = ?1",
                    params![&(i as u64).to_be_bytes() as &[u8]],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(got.len(), knomosis_amount::AMOUNT_BYTES);
            assert_eq!(
                knomosis_amount::Amount::from_be_slice(&got).unwrap(),
                knomosis_amount::Amount::from_u128(*v),
                "budget value changed under the widening"
            );
        }
    }

    /// The widening touches ONLY `b/`-prefixed `kv` cells.
    ///
    /// The `kv` table is a shared keyspace — the indexer's cursor
    /// lives there too — so a migration that matched on value length
    /// alone would rewrite a neighbour's 16-byte value into something
    /// that neighbour cannot parse.
    #[test]
    fn widening_leaves_other_kv_keyspaces_alone() {
        let conn = Connection::open_in_memory().unwrap();
        migration_001_initial_kv_table(&conn).unwrap();
        migration_002_budget_views(&conn).unwrap();

        // A non-balance key carrying a 16-byte value: the exact shape
        // a length-only filter would catch by mistake.
        let bystander = b"c/some-control-cell".to_vec();
        let payload = [0xabu8; 16];
        conn.execute(
            "INSERT INTO kv(key, value) VALUES (?1, ?2)",
            params![&bystander as &[u8], &payload as &[u8]],
        )
        .unwrap();

        migration_003_widen_amount_cells(&conn).unwrap();

        let got: Vec<u8> = conn
            .query_row(
                "SELECT value FROM kv WHERE key = ?1",
                params![&bystander as &[u8]],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            got,
            payload.to_vec(),
            "a non-balance cell must be untouched"
        );
    }

    /// Re-running the widening is a no-op, so a partially-applied or
    /// already-current database survives it.
    #[test]
    fn widening_is_idempotent() {
        let mut conn = Connection::open_in_memory().unwrap();
        apply_migrations(&mut conn).unwrap();

        let mut key = b"b/".to_vec();
        key.extend_from_slice(&7u64.to_be_bytes());
        key.extend_from_slice(&0u64.to_be_bytes());
        let wide = knomosis_amount::Amount::from_u64(1_234).to_be_bytes();
        conn.execute(
            "INSERT INTO kv(key, value) VALUES (?1, ?2)",
            params![&key as &[u8], &wide as &[u8]],
        )
        .unwrap();

        for _ in 0..3 {
            migration_003_widen_amount_cells(&conn).unwrap();
        }

        let got: Vec<u8> = conn
            .query_row(
                "SELECT value FROM kv WHERE key = ?1",
                params![&key as &[u8]],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            got,
            wide.to_vec(),
            "an already-wide cell must not be re-extended"
        );
    }

    /// A value at the retired ceiling widens to the same number, not
    /// to a value shifted into the high half.
    ///
    /// The negative control for `widening_preserves_every_value`: if
    /// the zero-extension went to the wrong end, `u128::MAX` would come
    /// back as `u128::MAX * 2^128`, which this pins against.
    #[test]
    fn widening_extends_the_high_bytes_not_the_low_ones() {
        let conn = Connection::open_in_memory().unwrap();
        migration_001_initial_kv_table(&conn).unwrap();
        migration_002_budget_views(&conn).unwrap();

        let mut key = b"b/".to_vec();
        key.extend_from_slice(&1u64.to_be_bytes());
        key.extend_from_slice(&0u64.to_be_bytes());
        conn.execute(
            "INSERT INTO kv(key, value) VALUES (?1, ?2)",
            params![&key as &[u8], &u128::MAX.to_be_bytes() as &[u8]],
        )
        .unwrap();

        migration_003_widen_amount_cells(&conn).unwrap();

        let got: Vec<u8> = conn
            .query_row(
                "SELECT value FROM kv WHERE key = ?1",
                params![&key as &[u8]],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(&got[..16], &[0u8; 16], "the ADDED bytes are the high ones");
        assert_eq!(
            &got[16..],
            &u128::MAX.to_be_bytes()[..],
            "the original bytes stay low"
        );
    }
}
