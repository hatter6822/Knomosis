// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! The storage trait surface (RH-E.0.a).
//!
//! Three traits compose the storage abstraction:
//!
//!   * [`Storage`] — the top-level KV interface (`get` / `put` /
//!     `delete` / `scan`) plus higher-order constructors for
//!     read-only snapshots ([`Storage::snapshot`]) and atomic
//!     transactions ([`Storage::transaction`]).
//!   * [`StorageSnapshot`] — a read-only view of the database
//!     pinned at the moment [`Storage::snapshot`] was called.
//!     All reads through the snapshot see the same logical state
//!     even as concurrent writers commit new versions.
//!   * [`StorageTransaction`] — an atomic batch of mutations.
//!     `commit()` makes them all visible at once; dropping the
//!     transaction (or calling `rollback`) discards them.
//!
//! ## Trait stability
//!
//! These traits are part of the workspace's public API surface.
//! Adding a new method is a workspace-level PR per the engineering
//! plan §7 risk register; removing or changing a method's signature
//! is a major-version bump.
//!
//! ## Mathematical contract
//!
//! Conceptually a `Storage` is a finite map `B -> B` (where `B`
//! denotes the set of finite byte strings) augmented with two
//! transactional operations:
//!
//!   * `get(k) = m[k]` (or `None` if `k` not present).
//!   * `put(k, v) = m[k := v]` (overwrite).
//!   * `delete(k) = m \ {k}` (no-op if absent).
//!   * `scan(p) = [(k, m[k]) | k ∈ keys(m), p `is_prefix_of` k]`
//!     in strict lexicographic order on `k`.
//!   * `snapshot()` pins a frozen copy of `m` against future
//!     writers.
//!   * `transaction()` returns a write batch that atomically
//!     applies a list of (`put`, `delete`) operations.
//!
//! The implementation MUST guarantee strict serialisability for
//! committed transactions (`commit` either makes EVERY mutation
//! visible or none).  A snapshot taken before a transaction commits
//! reads pre-commit state for the snapshot's lifetime; a snapshot
//! taken after a transaction commits reads post-commit state.

/// A vector of `(key, value)` byte-pairs returned by `scan` /
/// snapshot-`scan`.  Centralised here so the trait surface and
/// the implementations agree on the exact shape; clippy's
/// `type_complexity` lint flags the inline `Vec<(Vec<u8>,
/// Vec<u8>)>` form.
pub type KeyValuePairs = Vec<(Vec<u8>, Vec<u8>)>;

/// A typed storage-layer error.
///
/// `Other` carries an opaque message for backend-specific errors
/// the trait doesn't enumerate explicitly (e.g. "disk full" from
/// SQLite).  All other variants name failure modes that callers
/// can act on programmatically.
#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    /// The underlying I/O operation (file open, fsync, etc.) failed.
    #[error("storage I/O error: {0}")]
    Io(#[from] std::io::Error),

    /// The backing store reported a database-engine error.  The
    /// message is the backend's typed diagnostic.
    #[error("storage backend error: {0}")]
    Backend(String),

    /// A migration failed to apply or is missing from the current
    /// binary's [`crate::migration::MIGRATIONS`] table.
    ///
    /// `expected` is the schema version the binary expects;
    /// `found` is the version the on-disk database reports.  A
    /// `found > expected` mismatch indicates the database was
    /// written by a newer binary and is forward-incompatible.
    #[error("storage migration mismatch: expected schema {expected}, found {found}")]
    MigrationMismatch {
        /// Schema version this binary knows about.
        expected: u32,
        /// Schema version recorded on disk.
        found: u32,
    },

    /// A migration body returned an error during execution.
    /// `index` is the migration that failed; `reason` is the
    /// backend's diagnostic.
    #[error("storage migration {index} failed: {reason}")]
    MigrationFailed {
        /// Index of the failed migration (1-indexed).
        index: u32,
        /// Backend's error message.
        reason: String,
    },

    /// A transaction commit failed.  The transaction has been
    /// rolled back by the backend.
    #[error("transaction commit failed: {reason}")]
    CommitFailed {
        /// Backend's error message.
        reason: String,
    },

    /// A previously-acquired snapshot or transaction has been
    /// dropped or invalidated and cannot be used.
    #[error("storage handle invalidated: {reason}")]
    Invalidated {
        /// Backend's diagnostic.
        reason: String,
    },

    /// Catch-all for backend errors that don't fit one of the
    /// typed variants above.  Used only when the backend's error
    /// type doesn't map onto a more specific variant.
    #[error("storage error: {0}")]
    Other(String),
}

/// The top-level storage trait.  See module docstring for the
/// mathematical contract.
///
/// ## Implementation notes
///
///   * Implementations MUST be `Send + Sync` so the trait object
///     can be shared across worker threads.
///   * `&self` exposes all methods; interior mutability is the
///     implementor's responsibility.
///   * `put` overwrites silently (no error on duplicate-key).
///     `delete` is idempotent (no error on missing key).
///   * `scan(prefix)` MUST return entries in strict lex order on
///     `key`.  An empty `prefix` returns the entire table.
///   * `snapshot()` and `transaction()` allocate a backend-specific
///     handle; dropping the handle releases the associated lock /
///     state.
pub trait Storage: Send + Sync {
    /// Look up the value associated with `key`.  Returns `None`
    /// if the key is not present.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, StorageError>;

    /// Insert or overwrite the value at `key`.  Does NOT error on
    /// duplicate-key — `put` is the canonical "upsert" operation.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn put(&self, key: &[u8], value: &[u8]) -> Result<(), StorageError>;

    /// Remove the entry at `key`.  Idempotent: succeeds even if
    /// the key is not present.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn delete(&self, key: &[u8]) -> Result<(), StorageError>;

    /// Enumerate every `(key, value)` pair whose key starts with
    /// `prefix`, in strict lexicographic order on `key`.
    ///
    /// An empty `prefix` returns the entire table.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn scan(&self, prefix: &[u8]) -> Result<KeyValuePairs, StorageError>;

    /// Take a read-only snapshot pinned at the current commit
    /// state.  All reads through the returned handle see the same
    /// logical state regardless of concurrent writers.
    ///
    /// Drop the handle to release the snapshot's read lock.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn snapshot(&self) -> Result<Box<dyn StorageSnapshot + '_>, StorageError>;

    /// Begin an atomic transaction.  Mutations on the returned
    /// handle are NOT visible to other readers until `commit()`
    /// returns successfully; dropping the handle (or calling
    /// `rollback()`) discards all uncommitted mutations.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn transaction(&self) -> Result<Box<dyn StorageTransaction + '_>, StorageError>;
}

/// A read-only snapshot of a [`Storage`].  Captures the database
/// state at the moment [`Storage::snapshot`] was called; reads
/// through this handle see the same logical state even as the
/// underlying store advances.
///
/// **Threading.**  Snapshots are deliberately NOT `Send`: the
/// SQLite implementation holds a `MutexGuard` for the snapshot's
/// lifetime, and `MutexGuard` is `!Send`.  Callers obtain the
/// snapshot on the thread that needs to read from it; that's the
/// usage pattern for every snapshot consumer in the workspace
/// (`canon-faultproof-observer`'s game-open path, `canon-indexer`'s
/// verification path).
pub trait StorageSnapshot {
    /// Look up `key` in the snapshot.  See [`Storage::get`].
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, StorageError>;

    /// Enumerate the snapshot.  See [`Storage::scan`].
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn scan(&self, prefix: &[u8]) -> Result<KeyValuePairs, StorageError>;
}

/// An atomic mutation batch on a [`Storage`].  Mutations are
/// staged but not visible to other readers until `commit()` is
/// called.  Dropping the transaction (or explicitly calling
/// `rollback()`) discards all uncommitted mutations.
///
/// **Threading.**  Transactions are deliberately NOT `Send`: the
/// SQLite implementation holds a `MutexGuard` for the transaction's
/// lifetime, and `MutexGuard` is `!Send`.  See
/// [`StorageSnapshot`]'s docstring for the same constraint.
pub trait StorageTransaction {
    /// Stage a `put` in this transaction.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn put(&mut self, key: &[u8], value: &[u8]) -> Result<(), StorageError>;

    /// Stage a `delete` in this transaction.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn delete(&mut self, key: &[u8]) -> Result<(), StorageError>;

    /// Read `key` from the transaction's working view.  Sees
    /// staged mutations as well as committed state.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, StorageError>;

    /// Commit the transaction.  Consumes the handle; on success,
    /// every staged mutation becomes visible atomically.  On
    /// failure the transaction has been rolled back by the backend
    /// and the handle is consumed regardless.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn commit(self: Box<Self>) -> Result<(), StorageError>;

    /// Discard the transaction.  Consumes the handle; no mutations
    /// become visible.  Same observable effect as dropping the
    /// handle without calling `commit`.
    ///
    /// # Errors
    ///
    /// See [`StorageError`].
    fn rollback(self: Box<Self>) -> Result<(), StorageError>;
}

#[cfg(test)]
mod tests {
    use super::{Storage, StorageError, StorageSnapshot, StorageTransaction};

    /// `StorageError` is `Send + Sync` so it can be shipped across
    /// thread boundaries (required by the worker-thread pattern
    /// every Canon Rust binary uses).
    #[test]
    fn storage_error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<StorageError>();
    }

    /// `Storage` is object-safe (usable as `Box<dyn Storage>` and
    /// `Arc<dyn Storage>`).
    #[test]
    fn storage_is_object_safe() {
        fn assert_obj_safe(_: &dyn Storage) {}
        // Compile-only check; no runtime behaviour.
        let _ = assert_obj_safe;
    }

    /// `StorageSnapshot` is object-safe.
    #[test]
    fn snapshot_is_object_safe() {
        fn assert_obj_safe(_: &dyn StorageSnapshot) {}
        let _ = assert_obj_safe;
    }

    /// `StorageTransaction` is object-safe.
    #[test]
    fn transaction_is_object_safe() {
        fn assert_obj_safe(_: &dyn StorageTransaction) {}
        let _ = assert_obj_safe;
    }

    /// Variant Display strings are stable: a downstream caller may
    /// pattern-match on the leading prefix as part of operator
    /// diagnostics.  Pin the human-readable shapes.
    #[test]
    fn error_display_shapes() {
        let backend = StorageError::Backend("disk full".to_string());
        assert!(backend.to_string().starts_with("storage backend error: "));

        let mm = StorageError::MigrationMismatch {
            expected: 2,
            found: 3,
        };
        assert!(mm.to_string().contains("expected schema 2"));
        assert!(mm.to_string().contains("found 3"));

        let mf = StorageError::MigrationFailed {
            index: 4,
            reason: "syntax error near FOO".to_string(),
        };
        assert!(mf.to_string().contains("migration 4 failed"));

        let cf = StorageError::CommitFailed {
            reason: "constraint violated".to_string(),
        };
        assert!(cf.to_string().contains("transaction commit failed"));

        let inv = StorageError::Invalidated {
            reason: "already committed".to_string(),
        };
        assert!(inv.to_string().contains("invalidated"));

        let oth = StorageError::Other("plumber error".to_string());
        assert_eq!(oth.to_string(), "storage error: plumber error");
    }

    /// `Io` variant round-trips through `From<std::io::Error>`.
    #[test]
    fn error_io_conversion() {
        let io_err = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "denied");
        let storage: StorageError = io_err.into();
        assert!(storage.to_string().starts_with("storage I/O error: "));
    }
}
