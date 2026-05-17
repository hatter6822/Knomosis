// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

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
//! Once a migration is published in a release of `canon-storage`,
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
//! backup from before the upgrade; `canon-storage` does not provide
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
use rusqlite::{params, Connection};

/// Name of the metadata table that stores the schema version.
///
/// Reserved namespace: any key in `_meta` starting with `schema_`
/// is reserved for this module.  Downstream users of
/// `canon-storage` MUST NOT write to `_meta` directly; they use
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
pub const MIGRATIONS: &[Migration] = &[Migration {
    name: "initial_kv_table",
    apply: migration_001_initial_kv_table,
}];

/// Compile-time assertion that the migration table fits in u32.
/// Without this, a future PR that adds u32::MAX + 1 migrations
/// would silently truncate the version counter.  At time of
/// writing (1 migration), this is trivially below the cap.
const _MIGRATIONS_FIT_IN_U32: () = assert!(
    MIGRATIONS.len() <= u32::MAX as usize,
    "canon-storage MIGRATIONS table overflows u32"
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
        // `current` is a u32 in [0, target); cast to usize is
        // safe because `target <= u32::MAX` (enforced by
        // `target_schema_version`) and `usize` is at least 32-bit
        // on every supported target.
        let migration_index = current as usize;
        let migration = &MIGRATIONS[migration_index];
        let next_version = current + 1;
        tracing::debug!(
            from = current,
            to = next_version,
            name = migration.name,
            "applying canon-storage migration"
        );

        let tx = conn
            .transaction()
            .map_err(|e| StorageError::Backend(format!("migration BEGIN failed: {e}")))?;
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

#[cfg(test)]
mod tests {
    use super::{apply_migrations, current_schema_version, target_schema_version, MIGRATIONS};
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
}
