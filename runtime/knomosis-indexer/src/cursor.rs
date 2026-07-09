// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Cursor tracking: last successfully-processed event seq number.
//!
//! ## Storage layout
//!
//! Two reserved control keys live under the `c/` prefix:
//!
//! ```text
//! key                  | content                            | format
//! ---------------------+------------------------------------+---------------
//! "c/cursor"           | last successfully-processed seq   | 8-byte BE u64
//! "c/identifier"       | indexer identifier string         | UTF-8 text
//! ```
//!
//! The cursor advances atomically with the corresponding event's
//! balance updates inside a single storage transaction.  On
//! restart the indexer reads `c/cursor` and subscribes with
//! `resume_from = cursor` so the server replays only events
//! with `seq > cursor`.
//!
//! ## Why store the identifier
//!
//! An operator who points the indexer at a database written by a
//! different (incompatible) indexer version should see a typed
//! error rather than silent corruption.  Comparing the on-disk
//! identifier against the binary's [`crate::INDEXER_IDENTIFIER`]
//! at startup catches this.
//!
//! ## Mathematical contract
//!
//! The cursor is **monotonically non-decreasing**.  Per the
//! `advance_cursor*` functions:
//!
//!   * `new_value > current` is permitted (the canonical forward
//!     advance).
//!   * `new_value == current` is permitted (idempotent: a retry
//!     applying the same batch can call `advance_cursor` with the
//!     existing value without error).
//!   * `new_value < current` is rejected with
//!     [`CursorError::NonMonotonicAdvance`].
//!
//! The higher-level [`crate::indexer::Indexer::apply_batch`]
//! enforces a STRICT-greater check on `seq > cursor` to prevent
//! double-applying a batch that's already been committed.  Both
//! policies are sound:
//!
//!   * Cursor level: monotone-NON-decreasing (allows idempotent
//!     re-writes of the cursor cell, useful for recovery paths).
//!   * Indexer level: strict-greater (prevents double-applying
//!     events to the balance view).

use std::fmt::Write as _;

use knomosis_storage::storage::{Storage, StorageError, StorageTransaction};

/// Key for the cursor cell.
pub const CURSOR_KEY: &[u8] = b"c/cursor";

/// Key for the identifier cell.
pub const IDENTIFIER_KEY: &[u8] = b"c/identifier";

/// Fixed-width cursor value length (8-byte BE u64).
pub const CURSOR_VALUE_LEN: usize = 8;

/// Cursor errors.
#[derive(Debug, thiserror::Error)]
pub enum CursorError {
    /// The underlying storage failed.
    #[error("storage error: {0}")]
    Storage(#[from] StorageError),
    /// Attempt to advance the cursor to a value strictly less
    /// than its current value.  Indicates a caller bug (the
    /// indexer should never go backwards).
    #[error("non-monotonic cursor advance: current {current}, attempted {attempted}")]
    NonMonotonicAdvance {
        /// Current cursor value.
        current: u64,
        /// Attempted new value.
        attempted: u64,
    },
    /// The cursor cell had the wrong length (corrupt storage).
    #[error("corrupt cursor cell: expected {expected} bytes, got {actual}")]
    CorruptCell {
        /// Expected length.
        expected: usize,
        /// Actual length.
        actual: usize,
    },
    /// The on-disk identifier didn't match the binary's expected
    /// identifier.  Reading a database produced by an
    /// incompatible indexer.
    #[error("indexer identifier mismatch: expected {expected:?}, found {found:?}")]
    IdentifierMismatch {
        /// Identifier the binary expects.
        expected: String,
        /// Identifier read from disk.
        found: String,
    },
    /// The on-disk identifier was not valid UTF-8.  Carries a
    /// hex preview of the leading bytes so an operator can
    /// diagnose corruption without scrolling through binary log
    /// noise.
    #[error("identifier cell is not valid UTF-8: {bytes_len} bytes (preview: {preview_hex})")]
    IdentifierNotUtf8 {
        /// Length of the offending bytes.
        bytes_len: usize,
        /// Hex preview of up to 32 leading bytes.
        preview_hex: String,
    },
}

/// Produce a hex preview of up to 32 leading bytes for
/// diagnostic logging.
fn hex_preview(bytes: &[u8]) -> String {
    const PREVIEW_MAX: usize = 32;
    let n = bytes.len().min(PREVIEW_MAX);
    let mut out = String::with_capacity(n * 2 + 4);
    for b in &bytes[..n] {
        // Two-digit lowercase hex per byte.  ASCII-only — safe
        // for tracing logs.
        let _ = write!(out, "{b:02x}");
    }
    if bytes.len() > PREVIEW_MAX {
        out.push_str("...");
    }
    out
}

/// Read the current cursor value from `storage`.  Returns 0 if
/// the cell is not present (indicates a brand-new database).
///
/// # Errors
///
/// Returns [`CursorError::Storage`] on storage failure.
/// Returns [`CursorError::CorruptCell`] if the stored value has
/// the wrong length.
pub fn read_cursor<S: Storage + ?Sized>(storage: &S) -> Result<u64, CursorError> {
    let cell = storage.get(CURSOR_KEY)?;
    decode_cursor(cell.as_deref())
}

/// Write the cursor value (without monotonicity check).  Used
/// internally; callers prefer [`advance_cursor`] which enforces
/// the monotone invariant.
///
/// # Errors
///
/// Returns [`CursorError::Storage`] on storage failure.
pub fn write_cursor<S: Storage + ?Sized>(storage: &S, value: u64) -> Result<(), CursorError> {
    storage.put(CURSOR_KEY, &value.to_be_bytes())?;
    Ok(())
}

/// Advance the cursor, enforcing monotonicity.  `new_value` must
/// be `>= current` or [`CursorError::NonMonotonicAdvance`] is
/// returned.
///
/// **NOT atomic with subsequent operations.**  The atomic
/// path uses [`advance_cursor_in_tx`] inside a storage
/// transaction together with the corresponding event's effects.
///
/// # Errors
///
/// See [`CursorError`].
pub fn advance_cursor<S: Storage + ?Sized>(storage: &S, new_value: u64) -> Result<(), CursorError> {
    let current = read_cursor(storage)?;
    if new_value < current {
        return Err(CursorError::NonMonotonicAdvance {
            current,
            attempted: new_value,
        });
    }
    write_cursor(storage, new_value)
}

/// Advance the cursor inside a transaction.  Stages the put;
/// the caller commits the transaction to make it visible.
///
/// Takes a `&mut dyn StorageTransaction` directly (callers
/// passing `Box<dyn StorageTransaction>` use `&mut *tx` to deref
/// through the box).  This keeps the borrow checker happy when
/// the transaction is committed after this call returns.
///
/// # Errors
///
/// See [`CursorError`].
pub fn advance_cursor_in_tx(
    tx: &mut dyn StorageTransaction,
    new_value: u64,
) -> Result<(), CursorError> {
    let cell = tx.get(CURSOR_KEY)?;
    let current = decode_cursor(cell.as_deref())?;
    if new_value < current {
        return Err(CursorError::NonMonotonicAdvance {
            current,
            attempted: new_value,
        });
    }
    tx.put(CURSOR_KEY, &new_value.to_be_bytes())?;
    Ok(())
}

/// Decode a cursor cell value.  Returns 0 for an absent cell.
fn decode_cursor(cell: Option<&[u8]>) -> Result<u64, CursorError> {
    match cell {
        None => Ok(0),
        Some(bytes) if bytes.len() == CURSOR_VALUE_LEN => {
            let mut buf = [0u8; CURSOR_VALUE_LEN];
            buf.copy_from_slice(bytes);
            Ok(u64::from_be_bytes(buf))
        }
        Some(bytes) => Err(CursorError::CorruptCell {
            expected: CURSOR_VALUE_LEN,
            actual: bytes.len(),
        }),
    }
}

/// Check the on-disk identifier against `expected`.  If absent,
/// the identifier is initialised to `expected` and the function
/// returns `Ok(())`.  If present and matching, returns `Ok(())`.
/// If present and mismatched, returns [`CursorError::IdentifierMismatch`].
///
/// # Errors
///
/// See [`CursorError`].
pub fn ensure_identifier<S: Storage + ?Sized>(
    storage: &S,
    expected: &str,
) -> Result<(), CursorError> {
    let cell = storage.get(IDENTIFIER_KEY)?;
    match cell {
        None => {
            // Brand-new database — initialise the identifier.
            storage.put(IDENTIFIER_KEY, expected.as_bytes())?;
            Ok(())
        }
        Some(bytes) => {
            let found = std::str::from_utf8(&bytes)
                .map_err(|_| CursorError::IdentifierNotUtf8 {
                    bytes_len: bytes.len(),
                    preview_hex: hex_preview(&bytes),
                })?
                .to_string();
            if found == expected {
                Ok(())
            } else {
                Err(CursorError::IdentifierMismatch {
                    expected: expected.to_string(),
                    found,
                })
            }
        }
    }
}

/// **Read-only** verification of the on-disk identifier — the read-only peer of
/// [`ensure_identifier`] for a consumer that opens the database
/// `SQLITE_OPEN_READ_ONLY` and so cannot (and must not) initialise it.
///
/// Unlike [`ensure_identifier`], an **absent** identifier cell is an error
/// rather than a silent initialise: a read-only consumer is reading a database
/// it does not own, so it must fail fast on anything other than a present,
/// matching identifier rather than risk interpreting a foreign or
/// uninitialised database as this indexer's data.
///
/// Returns `Ok(())` iff the cell is present and equals `expected`.
///
/// # Errors
///
/// [`CursorError::IdentifierMismatch`] if the cell is absent or holds a
/// different identifier; [`CursorError::IdentifierNotUtf8`] if it is not UTF-8;
/// [`CursorError::Storage`] on a storage failure.
pub fn verify_identifier<S: Storage + ?Sized>(
    storage: &S,
    expected: &str,
) -> Result<(), CursorError> {
    match storage.get(IDENTIFIER_KEY)? {
        None => Err(CursorError::IdentifierMismatch {
            expected: expected.to_string(),
            found: "(absent)".to_string(),
        }),
        Some(bytes) => {
            let found = std::str::from_utf8(&bytes)
                .map_err(|_| CursorError::IdentifierNotUtf8 {
                    bytes_len: bytes.len(),
                    preview_hex: hex_preview(&bytes),
                })?
                .to_string();
            if found == expected {
                Ok(())
            } else {
                Err(CursorError::IdentifierMismatch {
                    expected: expected.to_string(),
                    found,
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        advance_cursor, advance_cursor_in_tx, ensure_identifier, read_cursor, write_cursor,
        CursorError, CURSOR_KEY, CURSOR_VALUE_LEN, IDENTIFIER_KEY,
    };
    use knomosis_storage::sqlite::SqliteStorage;
    use knomosis_storage::storage::Storage;

    /// Constants pinned.
    #[test]
    fn constants_stable() {
        assert_eq!(CURSOR_KEY, b"c/cursor");
        assert_eq!(IDENTIFIER_KEY, b"c/identifier");
        assert_eq!(CURSOR_VALUE_LEN, 8);
    }

    /// Brand-new database reads cursor = 0.
    #[test]
    fn fresh_db_cursor_zero() {
        let s = SqliteStorage::open_in_memory().unwrap();
        assert_eq!(read_cursor(&s).unwrap(), 0);
    }

    /// `write_cursor` then `read_cursor` round-trips.
    #[test]
    fn write_then_read() {
        let s = SqliteStorage::open_in_memory().unwrap();
        write_cursor(&s, 12345).unwrap();
        assert_eq!(read_cursor(&s).unwrap(), 12345);
    }

    /// `advance_cursor` accepts non-strict monotonic increase.
    #[test]
    fn advance_monotone() {
        let s = SqliteStorage::open_in_memory().unwrap();
        advance_cursor(&s, 10).unwrap();
        advance_cursor(&s, 10).unwrap(); // equal is fine (idempotent)
        advance_cursor(&s, 20).unwrap();
        assert_eq!(read_cursor(&s).unwrap(), 20);
    }

    /// `advance_cursor` rejects backwards moves.
    #[test]
    fn advance_rejects_backwards() {
        let s = SqliteStorage::open_in_memory().unwrap();
        advance_cursor(&s, 20).unwrap();
        match advance_cursor(&s, 10) {
            Err(CursorError::NonMonotonicAdvance { current, attempted }) => {
                assert_eq!(current, 20);
                assert_eq!(attempted, 10);
            }
            other => panic!("expected NonMonotonicAdvance, got {other:?}"),
        }
        // Cursor unchanged.
        assert_eq!(read_cursor(&s).unwrap(), 20);
    }

    /// `advance_cursor_in_tx` stages the put.
    #[test]
    fn tx_advance() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        advance_cursor_in_tx(&mut *tx, 5).unwrap();
        tx.commit().unwrap();
        assert_eq!(read_cursor(&s).unwrap(), 5);
    }

    /// `advance_cursor_in_tx` rolls back on rollback.
    #[test]
    fn tx_advance_rolls_back() {
        let s = SqliteStorage::open_in_memory().unwrap();
        write_cursor(&s, 10).unwrap();
        let mut tx = s.transaction().unwrap();
        advance_cursor_in_tx(&mut *tx, 20).unwrap();
        tx.rollback().unwrap();
        assert_eq!(read_cursor(&s).unwrap(), 10);
    }

    /// `advance_cursor_in_tx` rejects non-monotone.
    #[test]
    fn tx_advance_rejects_backwards() {
        let s = SqliteStorage::open_in_memory().unwrap();
        write_cursor(&s, 50).unwrap();
        let mut tx = s.transaction().unwrap();
        match advance_cursor_in_tx(&mut *tx, 10) {
            Err(CursorError::NonMonotonicAdvance { current, attempted }) => {
                assert_eq!(current, 50);
                assert_eq!(attempted, 10);
            }
            other => panic!("expected NonMonotonicAdvance, got {other:?}"),
        }
        tx.rollback().unwrap();
    }

    /// Corrupt cursor cell surfaced as `CorruptCell`.
    #[test]
    fn corrupt_cursor_surfaced() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(CURSOR_KEY, &[0xAA; 4]).unwrap(); // wrong length
        match read_cursor(&s) {
            Err(CursorError::CorruptCell { expected, actual }) => {
                assert_eq!(expected, 8);
                assert_eq!(actual, 4);
            }
            other => panic!("expected CorruptCell, got {other:?}"),
        }
    }

    /// `ensure_identifier` on a fresh DB initialises the cell.
    #[test]
    fn ensure_identifier_initialises() {
        let s = SqliteStorage::open_in_memory().unwrap();
        ensure_identifier(&s, "test/v1").unwrap();
        let cell = s.get(IDENTIFIER_KEY).unwrap();
        assert_eq!(cell, Some(b"test/v1".to_vec()));
    }

    /// `ensure_identifier` accepts a matching identifier.
    #[test]
    fn ensure_identifier_matches() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(IDENTIFIER_KEY, b"test/v1").unwrap();
        ensure_identifier(&s, "test/v1").unwrap();
    }

    /// `ensure_identifier` rejects a mismatch.
    #[test]
    fn ensure_identifier_rejects_mismatch() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(IDENTIFIER_KEY, b"other/v1").unwrap();
        match ensure_identifier(&s, "test/v1") {
            Err(CursorError::IdentifierMismatch { expected, found }) => {
                assert_eq!(expected, "test/v1");
                assert_eq!(found, "other/v1");
            }
            other => panic!("expected IdentifierMismatch, got {other:?}"),
        }
    }

    /// `ensure_identifier` rejects non-UTF-8 bytes.
    #[test]
    fn ensure_identifier_rejects_non_utf8() {
        let s = SqliteStorage::open_in_memory().unwrap();
        s.put(IDENTIFIER_KEY, &[0xFF, 0xFE, 0xFD]).unwrap();
        match ensure_identifier(&s, "test/v1") {
            Err(CursorError::IdentifierNotUtf8 {
                bytes_len,
                preview_hex,
            }) => {
                assert_eq!(bytes_len, 3);
                // Verify preview hex matches the bytes we wrote.
                assert_eq!(preview_hex, "fffefd");
            }
            other => panic!("expected IdentifierNotUtf8, got {other:?}"),
        }
    }
}
