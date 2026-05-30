// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Per-(actor, resource) balance view.
//!
//! ## Storage layout
//!
//! Each balance cell is stored as a 16-byte BE u128 value under
//! the key `b"b/" + actor(8BE) + resource(8BE)`:
//!
//! ```text
//! ┌──────┬──────────────┬────────────────┐
//! │ "b/" │ actor (8 BE) │ resource (8 BE)│   key (18 bytes)
//! └──────┴──────────────┴────────────────┘
//!
//! ┌──────────────────────────────────────┐
//! │       amount (16 BE u128)            │   value (16 bytes)
//! └──────────────────────────────────────┘
//! ```
//!
//! The fixed-width key encoding ensures lexicographic order on
//! `(actor, resource)` matches numeric order (BE arithmetic on
//! fixed-width fields).  This lets the indexer `scan(b"b/" +
//! actor(8BE))` to enumerate all resources for a given actor in
//! resource-id order, and `scan(b"b/")` to enumerate all balances
//! in (actor, resource) order.
//!
//! ## Arithmetic
//!
//! The balance store exposes typed adjusters (`set` / `credit` /
//! `debit`) that wrap [`crate::storage::Storage`] operations.
//! All arithmetic is **checked**:
//!
//!   * `credit(actor, resource, delta)` saturates at `u128::MAX`
//!     and returns [`BalanceError::CreditOverflow`].  The
//!     overflow is logged but the saturation means the balance
//!     cell still gets the maximum representable value (defence
//!     against an indexer halt on a malformed event source).
//!   * `debit(actor, resource, delta)` rejects with
//!     [`BalanceError::DebitUnderflow`] if the current balance
//!     is less than `delta`.  No saturation — an event source
//!     that would underflow indicates a real consistency error.
//!
//! ## Mathematical contract
//!
//! For any event stream `[e_1, e_2, ..., e_n]` and the corresponding
//! kernel's `getBalance(actor, resource)`, after applying the
//! event stream to a fresh balance store the indexer's
//! `get(actor, resource).unwrap_or(0)` must equal `getBalance(actor,
//! resource)` for every (actor, resource) pair.  This is the
//! invariant the `--verify-against-knomosis` flag eventually checks.

use knomosis_storage::storage::{Storage, StorageError, StorageTransaction};

use crate::decoder::{amount_from_be_bytes, amount_to_be_bytes};
use crate::event::{ActorId, Amount, ResourceId};

/// Key prefix for balance cells.  Single ASCII byte to keep the
/// SQLite primary-key index scans tight; future keyspaces follow
/// the same single-byte-prefix discipline.
pub const BALANCE_KEY_PREFIX: &[u8] = b"b/";

/// Fixed-width key length: 2-byte prefix + 8-byte actor + 8-byte
/// resource = 18 bytes.
pub const BALANCE_KEY_LEN: usize = 2 + 8 + 8;

/// Fixed-width value length: 16-byte BE u128.
pub const BALANCE_VALUE_LEN: usize = 16;

/// Balance-view errors.
#[derive(Debug, thiserror::Error)]
pub enum BalanceError {
    /// The underlying storage failed.
    #[error("storage error: {0}")]
    Storage(#[from] StorageError),
    /// `credit` would overflow `u128::MAX`.  The balance is
    /// saturated to `u128::MAX` even when this fires; the error
    /// carries the (actor, resource, delta) for diagnostics.
    #[error(
        "credit overflow for actor {actor} resource {resource}: balance + {delta} > u128::MAX"
    )]
    CreditOverflow {
        /// Actor whose balance would overflow.
        actor: ActorId,
        /// Resource whose balance would overflow.
        resource: ResourceId,
        /// Delta that triggered the overflow.
        delta: Amount,
    },
    /// `debit` would underflow.  The current balance is unchanged
    /// when this fires; the error carries the (actor, resource,
    /// delta) for diagnostics.
    #[error("debit underflow for actor {actor} resource {resource}: balance {current} < {delta}")]
    DebitUnderflow {
        /// Actor whose balance would underflow.
        actor: ActorId,
        /// Resource whose balance would underflow.
        resource: ResourceId,
        /// Current balance.
        current: Amount,
        /// Delta that triggered the underflow.
        delta: Amount,
    },
    /// A stored balance value had the wrong length (corrupt
    /// storage).
    #[error(
        "corrupt balance cell for actor {actor} resource {resource}: expected {expected} bytes, got {actual}"
    )]
    CorruptCell {
        /// Actor whose cell was corrupt.
        actor: ActorId,
        /// Resource whose cell was corrupt.
        resource: ResourceId,
        /// Expected value length.
        expected: usize,
        /// Actual value length.
        actual: usize,
    },
}

/// Encode an (actor, resource) pair as the canonical balance key.
#[must_use]
pub fn balance_key(actor: ActorId, resource: ResourceId) -> [u8; BALANCE_KEY_LEN] {
    let mut k = [0u8; BALANCE_KEY_LEN];
    k[0..2].copy_from_slice(BALANCE_KEY_PREFIX);
    k[2..10].copy_from_slice(&actor.to_be_bytes());
    k[10..18].copy_from_slice(&resource.to_be_bytes());
    k
}

/// Decode an (actor, resource) pair from a balance key.  Returns
/// `None` if the key does not match the canonical layout.
#[must_use]
pub fn parse_balance_key(key: &[u8]) -> Option<(ActorId, ResourceId)> {
    if key.len() != BALANCE_KEY_LEN {
        return None;
    }
    if &key[0..2] != BALANCE_KEY_PREFIX {
        return None;
    }
    let mut a_buf = [0u8; 8];
    a_buf.copy_from_slice(&key[2..10]);
    let actor = ActorId::from_be_bytes(a_buf);
    let mut r_buf = [0u8; 8];
    r_buf.copy_from_slice(&key[10..18]);
    let resource = ResourceId::from_be_bytes(r_buf);
    Some((actor, resource))
}

/// A balance-view operating over any [`Storage`] implementation.
///
/// The view holds a borrowed reference to the storage; the
/// indexer typically opens one `SqliteStorage` at startup and
/// constructs a `BalanceView` around it.
pub struct BalanceView<'a, S: Storage + ?Sized> {
    storage: &'a S,
}

impl<'a, S: Storage + ?Sized> BalanceView<'a, S> {
    /// Construct a balance view over `storage`.
    pub fn new(storage: &'a S) -> Self {
        Self { storage }
    }

    /// Look up the balance for `(actor, resource)`.  Returns 0 if
    /// the cell is not present (matching the kernel's "no cell
    /// means zero" semantics).
    ///
    /// # Errors
    ///
    /// Returns [`BalanceError::Storage`] on storage failure.
    /// Returns [`BalanceError::CorruptCell`] if a stored value
    /// has the wrong length.
    pub fn get(&self, actor: ActorId, resource: ResourceId) -> Result<Amount, BalanceError> {
        let key = balance_key(actor, resource);
        let cell = self.storage.get(&key)?;
        decode_cell(actor, resource, cell.as_deref())
    }

    /// Set the balance for `(actor, resource)` to `value`.
    /// Used by `BalanceChanged` events (which carry the
    /// post-update balance directly).
    ///
    /// # Errors
    ///
    /// Returns [`BalanceError::Storage`] on storage failure.
    pub fn set(
        &self,
        actor: ActorId,
        resource: ResourceId,
        value: Amount,
    ) -> Result<(), BalanceError> {
        let key = balance_key(actor, resource);
        let cell = amount_to_be_bytes(value);
        self.storage.put(&key, &cell)?;
        Ok(())
    }

    /// Credit `delta` to the balance for `(actor, resource)`.
    /// Used by `RewardIssued` and `DepositCredited` events.
    ///
    /// Saturating: on overflow, the cell is set to `u128::MAX`
    /// and [`BalanceError::CreditOverflow`] is returned.
    ///
    /// # Errors
    ///
    /// See [`BalanceError`].
    pub fn credit(
        &self,
        actor: ActorId,
        resource: ResourceId,
        delta: Amount,
    ) -> Result<Amount, BalanceError> {
        let current = self.get(actor, resource)?;
        match current.checked_add(delta) {
            Some(sum) => {
                self.set(actor, resource, sum)?;
                Ok(sum)
            }
            None => {
                // Saturate: write u128::MAX so the indexer doesn't
                // halt on bad data; return the typed error so the
                // caller can log it.
                self.set(actor, resource, Amount::MAX)?;
                Err(BalanceError::CreditOverflow {
                    actor,
                    resource,
                    delta,
                })
            }
        }
    }

    /// Debit `delta` from the balance for `(actor, resource)`.
    /// Used by `WithdrawalRequested` events.
    ///
    /// Returns [`BalanceError::DebitUnderflow`] if the current
    /// balance is less than `delta`.  The cell is NOT modified
    /// on underflow.
    ///
    /// # Errors
    ///
    /// See [`BalanceError`].
    pub fn debit(
        &self,
        actor: ActorId,
        resource: ResourceId,
        delta: Amount,
    ) -> Result<Amount, BalanceError> {
        let current = self.get(actor, resource)?;
        match current.checked_sub(delta) {
            Some(diff) => {
                self.set(actor, resource, diff)?;
                Ok(diff)
            }
            None => Err(BalanceError::DebitUnderflow {
                actor,
                resource,
                current,
                delta,
            }),
        }
    }

    /// Enumerate every (actor, resource, balance) tuple.  Returns
    /// rows in (actor, resource) lex order (matching the
    /// fixed-width key encoding).
    ///
    /// # Errors
    ///
    /// Returns [`BalanceError::Storage`] on storage failure.
    /// Returns [`BalanceError::CorruptCell`] if any stored cell
    /// has the wrong length (the iteration stops at the first
    /// corrupt cell).
    pub fn scan_all(&self) -> Result<Vec<(ActorId, ResourceId, Amount)>, BalanceError> {
        let rows = self.storage.scan(BALANCE_KEY_PREFIX)?;
        let mut out = Vec::with_capacity(rows.len());
        for (key, value) in rows {
            let Some((actor, resource)) = parse_balance_key(&key) else {
                continue; // skip unexpected key shapes (defence-in-depth)
            };
            let amount = decode_cell(actor, resource, Some(&value))?;
            out.push((actor, resource, amount));
        }
        Ok(out)
    }
}

/// Same as [`BalanceView`] but operating on a [`StorageTransaction`]
/// — used by the indexer to atomically commit a batch of event
/// dispatches together with the cursor advance.
///
/// Mutating methods take `&mut self` because the underlying
/// transaction's `put`/`delete` borrow `&mut self`.
///
/// **Lifetime note.**  The view holds a mutable reference to a
/// `dyn StorageTransaction` trait object.  Calling sites typically
/// have a `Box<dyn StorageTransaction>` already and pass `&mut *tx`
/// to deref through the box; the explicit-deref form keeps the
/// borrow checker happy when the transaction is committed after
/// the view's scope ends.
pub struct BalanceTxView<'a> {
    tx: &'a mut (dyn StorageTransaction + 'a),
}

impl<'a> BalanceTxView<'a> {
    /// Wrap a borrowed transaction.  Callers passing a
    /// `Box<dyn StorageTransaction + 'a>` use `&mut *tx` to deref
    /// through the box.
    pub fn new(tx: &'a mut (dyn StorageTransaction + 'a)) -> Self {
        Self { tx }
    }

    /// Look up the balance under the transaction's view.  Sees
    /// staged mutations.
    ///
    /// # Errors
    ///
    /// See [`BalanceView::get`].
    pub fn get(&self, actor: ActorId, resource: ResourceId) -> Result<Amount, BalanceError> {
        let key = balance_key(actor, resource);
        let cell = self.tx.get(&key)?;
        decode_cell(actor, resource, cell.as_deref())
    }

    /// Stage a `set` mutation in the transaction.
    ///
    /// # Errors
    ///
    /// See [`BalanceView::set`].
    pub fn set(
        &mut self,
        actor: ActorId,
        resource: ResourceId,
        value: Amount,
    ) -> Result<(), BalanceError> {
        let key = balance_key(actor, resource);
        let cell = amount_to_be_bytes(value);
        self.tx.put(&key, &cell)?;
        Ok(())
    }

    /// Stage a credit (saturating).
    ///
    /// # Errors
    ///
    /// See [`BalanceView::credit`].
    pub fn credit(
        &mut self,
        actor: ActorId,
        resource: ResourceId,
        delta: Amount,
    ) -> Result<Amount, BalanceError> {
        let current = self.get(actor, resource)?;
        match current.checked_add(delta) {
            Some(sum) => {
                self.set(actor, resource, sum)?;
                Ok(sum)
            }
            None => {
                self.set(actor, resource, Amount::MAX)?;
                Err(BalanceError::CreditOverflow {
                    actor,
                    resource,
                    delta,
                })
            }
        }
    }

    /// Stage a debit (rejects on underflow).
    ///
    /// # Errors
    ///
    /// See [`BalanceView::debit`].
    pub fn debit(
        &mut self,
        actor: ActorId,
        resource: ResourceId,
        delta: Amount,
    ) -> Result<Amount, BalanceError> {
        let current = self.get(actor, resource)?;
        match current.checked_sub(delta) {
            Some(diff) => {
                self.set(actor, resource, diff)?;
                Ok(diff)
            }
            None => Err(BalanceError::DebitUnderflow {
                actor,
                resource,
                current,
                delta,
            }),
        }
    }
}

/// Decode a cell value to an `Amount`.  Internal helper shared
/// between [`BalanceView`] and [`BalanceTxView`].
fn decode_cell(
    actor: ActorId,
    resource: ResourceId,
    cell: Option<&[u8]>,
) -> Result<Amount, BalanceError> {
    match cell {
        None => Ok(0),
        Some(bytes) if bytes.len() == BALANCE_VALUE_LEN => {
            let mut buf = [0u8; BALANCE_VALUE_LEN];
            buf.copy_from_slice(bytes);
            Ok(amount_from_be_bytes(&buf))
        }
        Some(bytes) => Err(BalanceError::CorruptCell {
            actor,
            resource,
            expected: BALANCE_VALUE_LEN,
            actual: bytes.len(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        balance_key, parse_balance_key, BalanceError, BalanceTxView, BalanceView, BALANCE_KEY_LEN,
        BALANCE_KEY_PREFIX, BALANCE_VALUE_LEN,
    };
    use knomosis_storage::sqlite::SqliteStorage;
    use knomosis_storage::storage::Storage;

    /// Constants pinned.
    #[test]
    fn constants_stable() {
        assert_eq!(BALANCE_KEY_PREFIX, b"b/");
        assert_eq!(BALANCE_KEY_LEN, 18);
        assert_eq!(BALANCE_VALUE_LEN, 16);
    }

    /// `balance_key` produces a fixed-width key with prefix +
    /// big-endian actor + big-endian resource.
    #[test]
    fn balance_key_layout() {
        let k = balance_key(0x0102_0304_0506_0708u64, 0x090A_0B0C_0D0E_0F10u64);
        assert_eq!(k.len(), 18);
        assert_eq!(&k[0..2], b"b/");
        assert_eq!(&k[2..10], &[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
        assert_eq!(
            &k[10..18],
            &[0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]
        );
    }

    /// `parse_balance_key` is the inverse of `balance_key`.
    #[test]
    fn balance_key_round_trip() {
        for &(actor, resource) in &[(0u64, 0u64), (1, 2), (u64::MAX, u64::MAX), (42, 99)] {
            let k = balance_key(actor, resource);
            let (a, r) = parse_balance_key(&k).unwrap();
            assert_eq!(a, actor);
            assert_eq!(r, resource);
        }
    }

    /// `parse_balance_key` rejects wrong-length / wrong-prefix
    /// keys.
    #[test]
    fn parse_balance_key_rejects_malformed() {
        // Too short.
        assert!(parse_balance_key(b"b/short").is_none());
        // Too long.
        assert!(parse_balance_key(b"b/0123456789012345extra").is_none());
        // Wrong prefix (correct length, different prefix bytes).
        let mut bad = [0u8; BALANCE_KEY_LEN];
        bad[0] = b'X';
        bad[1] = b'/';
        assert!(parse_balance_key(&bad).is_none());
    }

    /// `get` on a missing cell returns 0 (the kernel's
    /// "no-cell-means-zero" convention).
    #[test]
    fn get_missing_returns_zero() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let view = BalanceView::new(&s);
        let v = view.get(1, 2).unwrap();
        assert_eq!(v, 0);
    }

    /// `set` then `get` round-trips a value.
    #[test]
    fn set_then_get() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let view = BalanceView::new(&s);
        view.set(1, 2, 100).unwrap();
        assert_eq!(view.get(1, 2).unwrap(), 100);
    }

    /// `credit` adds to existing balance.
    #[test]
    fn credit_accumulates() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let view = BalanceView::new(&s);
        view.set(1, 2, 50).unwrap();
        view.credit(1, 2, 30).unwrap();
        assert_eq!(view.get(1, 2).unwrap(), 80);
    }

    /// `credit` from a missing cell starts from 0.
    #[test]
    fn credit_from_zero() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let view = BalanceView::new(&s);
        view.credit(1, 2, 100).unwrap();
        assert_eq!(view.get(1, 2).unwrap(), 100);
    }

    /// `credit` overflow saturates + returns typed error.
    #[test]
    fn credit_overflow_saturates() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let view = BalanceView::new(&s);
        view.set(1, 2, u128::MAX - 5).unwrap();
        let result = view.credit(1, 2, 100);
        match result {
            Err(BalanceError::CreditOverflow {
                actor,
                resource,
                delta,
            }) => {
                assert_eq!(actor, 1);
                assert_eq!(resource, 2);
                assert_eq!(delta, 100);
            }
            other => panic!("expected CreditOverflow, got {other:?}"),
        }
        // Saturated to u128::MAX.
        assert_eq!(view.get(1, 2).unwrap(), u128::MAX);
    }

    /// `debit` subtracts.
    #[test]
    fn debit_subtracts() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let view = BalanceView::new(&s);
        view.set(1, 2, 100).unwrap();
        view.debit(1, 2, 40).unwrap();
        assert_eq!(view.get(1, 2).unwrap(), 60);
    }

    /// `debit` underflow rejects and leaves the cell unchanged.
    #[test]
    fn debit_underflow_rejects() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let view = BalanceView::new(&s);
        view.set(1, 2, 50).unwrap();
        let result = view.debit(1, 2, 100);
        match result {
            Err(BalanceError::DebitUnderflow {
                actor,
                resource,
                current,
                delta,
            }) => {
                assert_eq!(actor, 1);
                assert_eq!(resource, 2);
                assert_eq!(current, 50);
                assert_eq!(delta, 100);
            }
            other => panic!("expected DebitUnderflow, got {other:?}"),
        }
        // Cell unchanged.
        assert_eq!(view.get(1, 2).unwrap(), 50);
    }

    /// `scan_all` returns entries in (actor, resource) lex order.
    #[test]
    fn scan_all_ordered() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let view = BalanceView::new(&s);
        // Insert in mixed order.
        view.set(2, 5, 200).unwrap();
        view.set(1, 5, 100).unwrap();
        view.set(2, 3, 150).unwrap();
        let rows = view.scan_all().unwrap();
        assert_eq!(rows.len(), 3);
        // Sorted by (actor, resource): (1, 5), (2, 3), (2, 5).
        assert_eq!(rows[0], (1, 5, 100));
        assert_eq!(rows[1], (2, 3, 150));
        assert_eq!(rows[2], (2, 5, 200));
    }

    /// `BalanceTxView`: transaction sees its own staged updates.
    #[test]
    fn tx_view_read_your_writes() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BalanceTxView::new(&mut *tx);
            view.set(1, 2, 100).unwrap();
            assert_eq!(view.get(1, 2).unwrap(), 100);
            view.credit(1, 2, 50).unwrap();
            assert_eq!(view.get(1, 2).unwrap(), 150);
        }
        tx.commit().unwrap();
        // After commit, the canonical view sees the same value.
        let view = BalanceView::new(&s);
        assert_eq!(view.get(1, 2).unwrap(), 150);
    }

    /// `BalanceTxView`: rollback discards staged updates.
    #[test]
    fn tx_view_rollback() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let view = BalanceView::new(&s);
        view.set(1, 2, 100).unwrap();
        {
            let mut tx = s.transaction().unwrap();
            {
                let mut tx_view = BalanceTxView::new(&mut *tx);
                tx_view.set(1, 2, 999).unwrap();
            }
            tx.rollback().unwrap();
        }
        // Canonical view unchanged.
        assert_eq!(view.get(1, 2).unwrap(), 100);
    }

    /// Corrupt cell (wrong length) is surfaced as `CorruptCell`.
    #[test]
    fn corrupt_cell_surfaced() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // Manually write a wrong-length value.
        let k = balance_key(1, 2);
        s.put(&k, &[0xAA; 8]).unwrap(); // 8 bytes, expected 16
        let view = BalanceView::new(&s);
        match view.get(1, 2) {
            Err(BalanceError::CorruptCell {
                actor,
                resource,
                expected,
                actual,
            }) => {
                assert_eq!(actor, 1);
                assert_eq!(resource, 2);
                assert_eq!(expected, 16);
                assert_eq!(actual, 8);
            }
            other => panic!("expected CorruptCell, got {other:?}"),
        }
    }

    /// Storage error round-trips through `BalanceError::Storage`.
    #[test]
    fn storage_error_roundtrip() {
        // Construct a storage error directly to verify the `From`
        // conversion compiles.
        let se = knomosis_storage::storage::StorageError::Other("test".to_string());
        let be: BalanceError = se.into();
        assert!(be.to_string().contains("storage error"));
    }
}
