// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! WU GP.6.4 — per-actor budget view + per-resource gas-pool
//! inflow view.
//!
//! This module exposes three independent views over the indexer's
//! [`Storage`] backend:
//!
//!   * **`actor_budgets`** — per-actor cumulative budget credits
//!     received (in budget units).  Sourced from the three
//!     Workstream-GP "budget grant" events:
//!     `DepositWithFeeCredited`'s `budget_grant`,
//!     `ActionBudgetTopUp`'s `budget_increment`, and
//!     `DelegatedActionBudgetTopUp`'s `budget_increment`.
//!   * **`pool_balances_eth`** — per-(pool actor) cumulative pool
//!     credits AT RESOURCE 0 (ETH).  Sourced from the three GP
//!     "pool inflow" events when their resource field matches
//!     `RESOURCE_ID_ETH = 0`.
//!   * **`pool_balances_bold`** — symmetric, for `RESOURCE_ID_BOLD =
//!     1`.  Maintaining the ETH and BOLD legs separately lets a
//!     deployment UI render gas-pool accounting per-currency
//!     without joining two queries — and lines up with the
//!     `per_resource_pool_independence` theorem family (GP.7.3
//!     when it lands).
//!
//! ## Storage layout
//!
//! Each view occupies a distinct single-character keyspace prefix
//! in the underlying `knomosis-storage` KV store.  Keys are
//! fixed-width so lex-order scan over the prefix yields entries in
//! ascending actor-id order:
//!
//! ```text
//! key prefix          | content                            | format
//! --------------------+------------------------------------+------------------
//! "u/" + actor(8BE)   | cumulative budget units credited   | 16-byte BE u128
//! "pe/" + actor(8BE)  | cumulative ETH pool credits        | 16-byte BE u128
//! "pb/" + actor(8BE)  | cumulative BOLD pool credits       | 16-byte BE u128
//! ```
//!
//! The two-byte `u/` and three-byte `pe/` / `pb/` prefixes do not
//! collide with the balance view's `b/` prefix nor the cursor /
//! identifier `c/` prefix; a `scan(b"u/")` enumerates only the
//! budget view, `scan(b"pe/")` only the ETH pool view, etc.
//!
//! ## Semantics — additive, lifetime-cumulative
//!
//! Both views are **cumulative since the indexer's first event**
//! and **never decrement**.  Concretely:
//!
//!   * `actor_budgets[a] = sum of all budget credits to actor `a`
//!     across the indexer's history` (saturating at `u128::MAX`).
//!   * `pool_balances_eth[p] = sum of all ETH pool inflows to
//!     actor `p` across the indexer's history` (saturating).
//!   * `pool_balances_bold[p] = sum of all BOLD pool inflows to
//!     actor `p`` (saturating).
//!
//! This semantics is deliberately **simpler** than "current epoch
//! budget" or "live pool balance":
//!
//!   * **Epoch reset.**  The Lean kernel resets each actor's
//!     budget to the free tier at every epoch boundary (per
//!     `BudgetPolicy.advanceEpoch`).  The indexer's view does NOT
//!     model epoch advancement — it accumulates *grants*.  A
//!     deployment UI showing "remaining budget this epoch" would
//!     combine this view with the live `EpochBudgetState` (queried
//!     via `knomosis-host`); a UI showing "lifetime budget paid for
//!     by this actor" can read this view directly.
//!   * **Drains.**  `GasPoolClaim` (tag 18) is a future GP.7
//!     "drain" event; this WU decodes it but does NOT decrement
//!     the pool view.  The drain semantics will be wired in GP.7;
//!     until then, the pool view tracks **gross inflows**.  An
//!     operator who wants the *live* pool balance reads the
//!     existing balance view (`BalanceView::get(pool_actor,
//!     resource)`).
//!
//! ## Cross-checks
//!
//! For any (pool_actor, resource) pair, the following holds at
//! all times:
//!
//! ```text
//!   pool_balance_view[r][p]  ≤  total inflows to (p, r)
//!                            ≤  balance_view[p][r] + total drains
//! ```
//!
//! The first inequality is by construction (saturation: once we
//! hit `u128::MAX` we stop adding).  The second is by the gas-pool
//! accounting equation
//! (`pool_balance_eq_totalPoolDeposited_minus_payouts`).
//!
//! ## Mathematical contract
//!
//! Let `E = [e_1, ..., e_n]` be the event stream consumed by the
//! indexer.  Define:
//!
//!   * `gp_grants(a) = sum of `budget_grant` / `budget_increment`
//!     fields targeting actor `a` in `E`'s GP-family events`
//!     (tag 16's recipient, tag 17's signer, tag 19's recipient).
//!   * `gp_inflows(p, r) = sum of `pool_amount` / `gas_amount` to
//!     pool actor `p` at resource `r` in `E`'s GP-family events`
//!     (tag 16's pool_actor + pool_amount when matching r;
//!     tag 17 + 19's pool_actor + gas_amount when matching r).
//!
//! Then:
//!
//!   * `actor_budgets.get(a) = saturating_sum(gp_grants(a))`.
//!   * `pool_balances_eth.get(p) = saturating_sum(gp_inflows(p, 0))`.
//!   * `pool_balances_bold.get(p) = saturating_sum(gp_inflows(p, 1))`.
//!
//! The implementation is `O(1)` per event update (single SQLite
//! row read + write).
//!
//! ## Atomicity
//!
//! Updates to the three views go through [`BudgetViewTx`], a
//! transaction-bound view.  The indexer's `apply_batch` opens a
//! single storage transaction encompassing the balance view, the
//! budget view, and the cursor advance; on commit they all become
//! visible atomically; on any per-event error the whole batch
//! rolls back.

use knomosis_storage::storage::{Storage, StorageError, StorageTransaction};

use crate::decoder::{amount_from_be_bytes, amount_to_be_bytes};
use crate::event::{
    ActorId, Amount, BudgetUnits, Event, ResourceId, RESOURCE_ID_BOLD, RESOURCE_ID_ETH,
};

/// Key prefix for the `actor_budgets` view.  Two-byte literal
/// chosen to keep the SQLite primary-key index scans tight while
/// remaining clearly distinguishable from `b/` (balance), `c/`
/// (cursor), `pe/` (pool ETH), and `pb/` (pool BOLD).
pub const ACTOR_BUDGET_KEY_PREFIX: &[u8] = b"u/";

/// Key prefix for the per-pool-actor ETH inflow view.
pub const POOL_ETH_KEY_PREFIX: &[u8] = b"pe/";

/// Key prefix for the per-pool-actor BOLD inflow view.
pub const POOL_BOLD_KEY_PREFIX: &[u8] = b"pb/";

/// Fixed-width budget-view key length: 2-byte prefix + 8-byte
/// actor = 10 bytes.
pub const ACTOR_BUDGET_KEY_LEN: usize = 2 + 8;

/// Fixed-width pool-view key length: 3-byte prefix + 8-byte pool
/// actor = 11 bytes.
pub const POOL_BALANCE_KEY_LEN: usize = 3 + 8;

/// Fixed-width value length: 16-byte BE u128 (same shape as the
/// balance view's value cell).
pub const BUDGET_VALUE_LEN: usize = 16;

/// Budget-view errors.
#[derive(Debug, thiserror::Error)]
pub enum BudgetViewError {
    /// The underlying storage failed.
    #[error("storage error: {0}")]
    Storage(#[from] StorageError),
    /// A stored value had the wrong length (corrupt storage).
    #[error("corrupt {view} cell for actor {actor}: expected {expected} bytes, got {actual}")]
    CorruptCell {
        /// Which view's cell was corrupt
        /// (`actor_budgets` / `pool_balances_eth` / `pool_balances_bold`).
        view: &'static str,
        /// Actor (or pool actor) whose cell was corrupt.
        actor: ActorId,
        /// Expected value length.
        expected: usize,
        /// Actual value length.
        actual: usize,
    },
}

/// Encode an `actor` as the canonical `actor_budgets` key.
#[must_use]
pub fn actor_budget_key(actor: ActorId) -> [u8; ACTOR_BUDGET_KEY_LEN] {
    let mut k = [0u8; ACTOR_BUDGET_KEY_LEN];
    k[0..2].copy_from_slice(ACTOR_BUDGET_KEY_PREFIX);
    k[2..10].copy_from_slice(&actor.to_be_bytes());
    k
}

/// Decode an `actor` from an `actor_budgets` key.  Returns
/// `None` on shape mismatch.
#[must_use]
pub fn parse_actor_budget_key(key: &[u8]) -> Option<ActorId> {
    if key.len() != ACTOR_BUDGET_KEY_LEN || &key[0..2] != ACTOR_BUDGET_KEY_PREFIX {
        return None;
    }
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&key[2..10]);
    Some(ActorId::from_be_bytes(buf))
}

/// Encode a `pool_actor` as the canonical `pool_balances_eth` key.
#[must_use]
pub fn pool_eth_key(pool_actor: ActorId) -> [u8; POOL_BALANCE_KEY_LEN] {
    let mut k = [0u8; POOL_BALANCE_KEY_LEN];
    k[0..3].copy_from_slice(POOL_ETH_KEY_PREFIX);
    k[3..11].copy_from_slice(&pool_actor.to_be_bytes());
    k
}

/// Decode a `pool_actor` from a `pool_balances_eth` key.  Returns
/// `None` on shape mismatch.
#[must_use]
pub fn parse_pool_eth_key(key: &[u8]) -> Option<ActorId> {
    if key.len() != POOL_BALANCE_KEY_LEN || &key[0..3] != POOL_ETH_KEY_PREFIX {
        return None;
    }
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&key[3..11]);
    Some(ActorId::from_be_bytes(buf))
}

/// Encode a `pool_actor` as the canonical `pool_balances_bold` key.
#[must_use]
pub fn pool_bold_key(pool_actor: ActorId) -> [u8; POOL_BALANCE_KEY_LEN] {
    let mut k = [0u8; POOL_BALANCE_KEY_LEN];
    k[0..3].copy_from_slice(POOL_BOLD_KEY_PREFIX);
    k[3..11].copy_from_slice(&pool_actor.to_be_bytes());
    k
}

/// Decode a `pool_actor` from a `pool_balances_bold` key.  Returns
/// `None` on shape mismatch.
#[must_use]
pub fn parse_pool_bold_key(key: &[u8]) -> Option<ActorId> {
    if key.len() != POOL_BALANCE_KEY_LEN || &key[0..3] != POOL_BOLD_KEY_PREFIX {
        return None;
    }
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&key[3..11]);
    Some(ActorId::from_be_bytes(buf))
}

/// A read-only view of the three GP.6.4 keyspaces over any
/// [`Storage`] implementation.  Mirrors the shape of
/// [`crate::balance::BalanceView`].
pub struct BudgetView<'a, S: Storage + ?Sized> {
    storage: &'a S,
}

impl<'a, S: Storage + ?Sized> BudgetView<'a, S> {
    /// Construct a budget view over `storage`.
    pub fn new(storage: &'a S) -> Self {
        Self { storage }
    }

    /// Read the cumulative budget credits for `actor`.  Returns 0
    /// if the cell is not present (matching the "no cell means
    /// zero" semantics of the balance view).
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn get_actor_budget(&self, actor: ActorId) -> Result<BudgetUnits, BudgetViewError> {
        let key = actor_budget_key(actor);
        let cell = self.storage.get(&key)?;
        decode_cell(actor, "actor_budgets", cell.as_deref())
    }

    /// Read the cumulative ETH pool credits for `pool_actor`.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn get_pool_eth(&self, pool_actor: ActorId) -> Result<Amount, BudgetViewError> {
        let key = pool_eth_key(pool_actor);
        let cell = self.storage.get(&key)?;
        decode_cell(pool_actor, "pool_balances_eth", cell.as_deref())
    }

    /// Read the cumulative BOLD pool credits for `pool_actor`.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn get_pool_bold(&self, pool_actor: ActorId) -> Result<Amount, BudgetViewError> {
        let key = pool_bold_key(pool_actor);
        let cell = self.storage.get(&key)?;
        decode_cell(pool_actor, "pool_balances_bold", cell.as_deref())
    }

    /// Enumerate every `(actor, budget)` pair in the
    /// `actor_budgets` view, in ascending actor-id order.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn scan_actor_budgets(&self) -> Result<Vec<(ActorId, BudgetUnits)>, BudgetViewError> {
        let rows = self.storage.scan(ACTOR_BUDGET_KEY_PREFIX)?;
        let mut out = Vec::with_capacity(rows.len());
        for (key, value) in rows {
            let Some(actor) = parse_actor_budget_key(&key) else {
                continue;
            };
            let units = decode_cell(actor, "actor_budgets", Some(&value))?;
            out.push((actor, units));
        }
        Ok(out)
    }

    /// Enumerate every `(pool_actor, balance)` pair in the ETH
    /// pool view.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn scan_pool_eth(&self) -> Result<Vec<(ActorId, Amount)>, BudgetViewError> {
        let rows = self.storage.scan(POOL_ETH_KEY_PREFIX)?;
        let mut out = Vec::with_capacity(rows.len());
        for (key, value) in rows {
            let Some(actor) = parse_pool_eth_key(&key) else {
                continue;
            };
            let amount = decode_cell(actor, "pool_balances_eth", Some(&value))?;
            out.push((actor, amount));
        }
        Ok(out)
    }

    /// Enumerate every `(pool_actor, balance)` pair in the BOLD
    /// pool view.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn scan_pool_bold(&self) -> Result<Vec<(ActorId, Amount)>, BudgetViewError> {
        let rows = self.storage.scan(POOL_BOLD_KEY_PREFIX)?;
        let mut out = Vec::with_capacity(rows.len());
        for (key, value) in rows {
            let Some(actor) = parse_pool_bold_key(&key) else {
                continue;
            };
            let amount = decode_cell(actor, "pool_balances_bold", Some(&value))?;
            out.push((actor, amount));
        }
        Ok(out)
    }
}

/// Same as [`BudgetView`] but operating on a [`StorageTransaction`]
/// — used by the indexer to atomically commit a batch of event
/// dispatches together with the cursor advance.
pub struct BudgetViewTx<'a> {
    tx: &'a mut (dyn StorageTransaction + 'a),
}

impl<'a> BudgetViewTx<'a> {
    /// Wrap a borrowed transaction.
    pub fn new(tx: &'a mut (dyn StorageTransaction + 'a)) -> Self {
        Self { tx }
    }

    /// Read the cumulative budget credits for `actor` under the
    /// transaction's view (sees staged mutations).
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn get_actor_budget(&self, actor: ActorId) -> Result<BudgetUnits, BudgetViewError> {
        let key = actor_budget_key(actor);
        let cell = self.tx.get(&key)?;
        decode_cell(actor, "actor_budgets", cell.as_deref())
    }

    /// Read the cumulative ETH pool credits.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn get_pool_eth(&self, pool_actor: ActorId) -> Result<Amount, BudgetViewError> {
        let key = pool_eth_key(pool_actor);
        let cell = self.tx.get(&key)?;
        decode_cell(pool_actor, "pool_balances_eth", cell.as_deref())
    }

    /// Read the cumulative BOLD pool credits.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn get_pool_bold(&self, pool_actor: ActorId) -> Result<Amount, BudgetViewError> {
        let key = pool_bold_key(pool_actor);
        let cell = self.tx.get(&key)?;
        decode_cell(pool_actor, "pool_balances_bold", cell.as_deref())
    }

    /// Saturating credit to the `actor_budgets` view.  Used when
    /// dispatching the three budget-grant events.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn credit_actor_budget(
        &mut self,
        actor: ActorId,
        delta: BudgetUnits,
    ) -> Result<BudgetUnits, BudgetViewError> {
        let current = self.get_actor_budget(actor)?;
        let new_value = current.saturating_add(delta);
        let key = actor_budget_key(actor);
        let cell = amount_to_be_bytes(new_value);
        self.tx.put(&key, &cell)?;
        Ok(new_value)
    }

    /// Saturating credit to the ETH pool view.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn credit_pool_eth(
        &mut self,
        pool_actor: ActorId,
        delta: Amount,
    ) -> Result<Amount, BudgetViewError> {
        let current = self.get_pool_eth(pool_actor)?;
        let new_value = current.saturating_add(delta);
        let key = pool_eth_key(pool_actor);
        let cell = amount_to_be_bytes(new_value);
        self.tx.put(&key, &cell)?;
        Ok(new_value)
    }

    /// Saturating credit to the BOLD pool view.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    pub fn credit_pool_bold(
        &mut self,
        pool_actor: ActorId,
        delta: Amount,
    ) -> Result<Amount, BudgetViewError> {
        let current = self.get_pool_bold(pool_actor)?;
        let new_value = current.saturating_add(delta);
        let key = pool_bold_key(pool_actor);
        let cell = amount_to_be_bytes(new_value);
        self.tx.put(&key, &cell)?;
        Ok(new_value)
    }

    /// Dispatch a single event to the three views.  No-op for
    /// non-GP-family events.  For `GasPoolClaim` (tag 18) the
    /// dispatch is also a no-op at this WU's scope — the drain
    /// semantics land in GP.7.
    ///
    /// **Math.**  See the module docstring.
    ///
    /// # Errors
    ///
    /// See [`BudgetViewError`].
    #[allow(clippy::match_same_arms)] // GasPoolClaim arm kept distinct for GP.7 wiring.
    pub fn dispatch_event(&mut self, event: &Event) -> Result<(), BudgetViewError> {
        match event {
            Event::DepositWithFeeCredited {
                resource,
                recipient,
                pool_actor,
                pool_amount,
                budget_grant,
                ..
            } => {
                // Credit the recipient's budget.
                self.credit_actor_budget(*recipient, *budget_grant)?;
                // Credit the pool actor's per-resource ledger.
                // Only ETH (0) and BOLD (1) are tracked separately;
                // other resources are out of scope for this WU.
                self.credit_pool_inflow(*resource, *pool_actor, *pool_amount)?;
            }
            Event::ActionBudgetTopUp {
                signer,
                gas_resource,
                gas_amount,
                budget_increment,
                pool_actor,
            } => {
                // Credit the signer's budget.
                self.credit_actor_budget(*signer, *budget_increment)?;
                // Credit the pool actor.
                self.credit_pool_inflow(*gas_resource, *pool_actor, *gas_amount)?;
            }
            Event::DelegatedActionBudgetTopUp {
                recipient,
                gas_resource,
                gas_amount,
                budget_increment,
                pool_actor,
                ..
            } => {
                // Credit the RECIPIENT's budget (not the signer —
                // the load-bearing distinction from tag 17).
                self.credit_actor_budget(*recipient, *budget_increment)?;
                // Credit the pool actor.
                self.credit_pool_inflow(*gas_resource, *pool_actor, *gas_amount)?;
            }
            // GasPoolClaim (tag 18): the per-resource pool *drain*
            // event.  Reserved for GP.7 — no dispatch at this WU's
            // scope.  Kept as a distinct arm (not merged with the
            // catch-all) so when GP.7 lands the drain semantics
            // wire here without a structural diff.
            Event::GasPoolClaim { .. } => {}
            // All other events (tag 0..=15) are out of scope for
            // the budget view — the existing balance view handles
            // them.
            _ => {}
        }
        Ok(())
    }

    /// Internal helper: credit a pool inflow to whichever of the
    /// ETH / BOLD legs matches `resource`.  Other resource ids
    /// are silently ignored (the view only tracks ETH and BOLD
    /// for this WU; future resources can extend the dispatch).
    fn credit_pool_inflow(
        &mut self,
        resource: ResourceId,
        pool_actor: ActorId,
        amount: Amount,
    ) -> Result<(), BudgetViewError> {
        match resource {
            RESOURCE_ID_ETH => {
                self.credit_pool_eth(pool_actor, amount)?;
            }
            RESOURCE_ID_BOLD => {
                self.credit_pool_bold(pool_actor, amount)?;
            }
            // Other resources: silently ignored.  A deployment
            // could extend this dispatch via additional keyspaces
            // (e.g., `pe2/`, `pb2/`) when new resources are added.
            _ => {}
        }
        Ok(())
    }
}

/// Decode a cell value to a `u128`.  Internal helper shared
/// between read paths.
fn decode_cell(
    actor: ActorId,
    view: &'static str,
    cell: Option<&[u8]>,
) -> Result<u128, BudgetViewError> {
    match cell {
        None => Ok(0),
        Some(bytes) if bytes.len() == BUDGET_VALUE_LEN => {
            let mut buf = [0u8; BUDGET_VALUE_LEN];
            buf.copy_from_slice(bytes);
            Ok(amount_from_be_bytes(&buf))
        }
        Some(bytes) => Err(BudgetViewError::CorruptCell {
            view,
            actor,
            expected: BUDGET_VALUE_LEN,
            actual: bytes.len(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        actor_budget_key, parse_actor_budget_key, parse_pool_bold_key, parse_pool_eth_key,
        pool_bold_key, pool_eth_key, BudgetView, BudgetViewError, BudgetViewTx,
        ACTOR_BUDGET_KEY_LEN, ACTOR_BUDGET_KEY_PREFIX, BUDGET_VALUE_LEN, POOL_BALANCE_KEY_LEN,
        POOL_BOLD_KEY_PREFIX, POOL_ETH_KEY_PREFIX,
    };
    use crate::event::{Event, RESOURCE_ID_BOLD, RESOURCE_ID_ETH};
    use knomosis_storage::sqlite::SqliteStorage;
    use knomosis_storage::storage::Storage;

    /// Constants pinned.
    #[test]
    fn constants_stable() {
        assert_eq!(ACTOR_BUDGET_KEY_PREFIX, b"u/");
        assert_eq!(POOL_ETH_KEY_PREFIX, b"pe/");
        assert_eq!(POOL_BOLD_KEY_PREFIX, b"pb/");
        assert_eq!(ACTOR_BUDGET_KEY_LEN, 10);
        assert_eq!(POOL_BALANCE_KEY_LEN, 11);
        assert_eq!(BUDGET_VALUE_LEN, 16);
    }

    /// Key prefixes are pairwise distinct (no two prefixes are
    /// each other's prefix; no view's prefix is a prefix of the
    /// balance / cursor prefixes).  This is the load-bearing
    /// keyspace-isolation invariant.
    #[test]
    fn key_prefixes_distinct() {
        let prefixes: &[&[u8]] = &[
            b"b/",  // balance
            b"c/",  // cursor
            b"u/",  // actor_budgets
            b"pe/", // pool_balances_eth
            b"pb/", // pool_balances_bold
        ];
        for (i, &a) in prefixes.iter().enumerate() {
            for (j, &b) in prefixes.iter().enumerate() {
                if i == j {
                    continue;
                }
                assert!(
                    !a.starts_with(b) && !b.starts_with(a),
                    "prefix overlap: {a:?} vs {b:?}"
                );
            }
        }
    }

    /// `actor_budget_key` produces a fixed-width key with prefix +
    /// big-endian actor.
    #[test]
    fn actor_budget_key_layout() {
        let k = actor_budget_key(0x0102_0304_0506_0708u64);
        assert_eq!(k.len(), ACTOR_BUDGET_KEY_LEN);
        assert_eq!(&k[0..2], b"u/");
        assert_eq!(&k[2..10], &[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
    }

    /// `pool_eth_key` produces a fixed-width key.
    #[test]
    fn pool_eth_key_layout() {
        let k = pool_eth_key(0x0102_0304_0506_0708u64);
        assert_eq!(k.len(), POOL_BALANCE_KEY_LEN);
        assert_eq!(&k[0..3], b"pe/");
        assert_eq!(&k[3..11], &[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
    }

    /// `pool_bold_key` produces a fixed-width key.
    #[test]
    fn pool_bold_key_layout() {
        let k = pool_bold_key(0x0102_0304_0506_0708u64);
        assert_eq!(k.len(), POOL_BALANCE_KEY_LEN);
        assert_eq!(&k[0..3], b"pb/");
        assert_eq!(&k[3..11], &[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
    }

    /// All three key encoders are invertible by the matching
    /// parser.
    #[test]
    fn key_round_trip() {
        for &actor in &[0u64, 1, 2, u64::MAX, 42, 999] {
            let kb = actor_budget_key(actor);
            assert_eq!(parse_actor_budget_key(&kb).unwrap(), actor);
            let ke = pool_eth_key(actor);
            assert_eq!(parse_pool_eth_key(&ke).unwrap(), actor);
            let kbo = pool_bold_key(actor);
            assert_eq!(parse_pool_bold_key(&kbo).unwrap(), actor);
        }
    }

    /// Parsers reject wrong-prefix / wrong-length keys.
    #[test]
    fn parsers_reject_malformed() {
        // Wrong prefix.
        assert!(parse_actor_budget_key(b"X/12345678").is_none());
        assert!(parse_pool_eth_key(b"XX/12345678").is_none());
        assert!(parse_pool_bold_key(b"XX/12345678").is_none());
        // Wrong length.
        assert!(parse_actor_budget_key(b"u/short").is_none());
        assert!(parse_pool_eth_key(b"pe/short").is_none());
        // Cross-keyspace rejection (use a budget key's bytes for a
        // pool view's parser).
        let kb = actor_budget_key(42);
        assert!(parse_pool_eth_key(&kb).is_none());
        assert!(parse_pool_bold_key(&kb).is_none());
        let ke = pool_eth_key(42);
        assert!(parse_actor_budget_key(&ke).is_none());
        assert!(parse_pool_bold_key(&ke).is_none());
    }

    /// `get_*` on missing cells returns 0.
    #[test]
    fn get_missing_returns_zero() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let view = BudgetView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 0);
        assert_eq!(view.get_pool_eth(1).unwrap(), 0);
        assert_eq!(view.get_pool_bold(1).unwrap(), 0);
    }

    /// `dispatch_event` on `DepositWithFeeCredited` credits both
    /// recipient budget and the right pool leg.
    #[test]
    fn dispatch_deposit_with_fee_credited_eth() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.dispatch_event(&Event::DepositWithFeeCredited {
                resource: RESOURCE_ID_ETH,
                recipient: 42,
                pool_actor: 1,
                user_amount: 900,
                pool_amount: 100,
                budget_grant: 50,
                deposit_id: 7,
            })
            .unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 50);
        assert_eq!(view.get_pool_eth(1).unwrap(), 100);
        // BOLD untouched.
        assert_eq!(view.get_pool_bold(1).unwrap(), 0);
    }

    /// `dispatch_event` on `DepositWithFeeCredited` with BOLD
    /// resource credits the BOLD pool leg.
    #[test]
    fn dispatch_deposit_with_fee_credited_bold() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.dispatch_event(&Event::DepositWithFeeCredited {
                resource: RESOURCE_ID_BOLD,
                recipient: 42,
                pool_actor: 1,
                user_amount: 900,
                pool_amount: 200,
                budget_grant: 75,
                deposit_id: 8,
            })
            .unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 75);
        // ETH untouched.
        assert_eq!(view.get_pool_eth(1).unwrap(), 0);
        // BOLD credited.
        assert_eq!(view.get_pool_bold(1).unwrap(), 200);
    }

    /// `dispatch_event` on `ActionBudgetTopUp` credits signer's
    /// budget and the pool's per-resource leg.
    #[test]
    fn dispatch_action_budget_top_up_eth() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.dispatch_event(&Event::ActionBudgetTopUp {
                signer: 99,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 10,
                budget_increment: 100,
                pool_actor: 1,
            })
            .unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        assert_eq!(view.get_actor_budget(99).unwrap(), 100);
        assert_eq!(view.get_pool_eth(1).unwrap(), 10);
        assert_eq!(view.get_pool_bold(1).unwrap(), 0);
    }

    /// `dispatch_event` on `DelegatedActionBudgetTopUp` credits
    /// the RECIPIENT's budget (NOT the signer's) — the
    /// load-bearing distinction from tag 17.
    #[test]
    fn dispatch_delegated_top_up_credits_recipient() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.dispatch_event(&Event::DelegatedActionBudgetTopUp {
                recipient: 55,
                signer: 77,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 10,
                budget_increment: 100,
                pool_actor: 1,
            })
            .unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        // Recipient (55) was credited.
        assert_eq!(view.get_actor_budget(55).unwrap(), 100);
        // Signer (77) was NOT credited.
        assert_eq!(view.get_actor_budget(77).unwrap(), 0);
        // Pool credited at gas_resource.
        assert_eq!(view.get_pool_eth(1).unwrap(), 10);
    }

    /// `dispatch_event` on `GasPoolClaim` is a no-op at this WU
    /// (drain semantics deferred to GP.7).
    #[test]
    fn dispatch_gas_pool_claim_is_noop() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // Pre-credit some pool balance.
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.dispatch_event(&Event::ActionBudgetTopUp {
                signer: 99,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 100,
                budget_increment: 1000,
                pool_actor: 1,
            })
            .unwrap();
        }
        tx.commit().unwrap();
        // Apply a GasPoolClaim.
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.dispatch_event(&Event::GasPoolClaim {
                resource: RESOURCE_ID_ETH,
                sequencer: 2,
                amount: 50,
            })
            .unwrap();
        }
        tx.commit().unwrap();
        // Pool credit unchanged (GasPoolClaim is a no-op).
        let view = BudgetView::new(&s);
        assert_eq!(view.get_pool_eth(1).unwrap(), 100);
    }

    /// Non-GP events (e.g. `BalanceChanged`) are no-ops at the
    /// budget view layer.
    #[test]
    fn dispatch_non_gp_event_is_noop() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.dispatch_event(&Event::BalanceChanged {
                resource: 0,
                actor: 42,
                old_value: 0,
                new_value: 100,
            })
            .unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 0);
        assert_eq!(view.get_pool_eth(42).unwrap(), 0);
        assert_eq!(view.get_pool_bold(42).unwrap(), 0);
    }

    /// Cumulative semantics: multiple budget credits sum.
    #[test]
    fn budget_credits_accumulate() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // Three credits of 100, 50, 25 = 175 total.
        for delta in [100u128, 50, 25] {
            let mut tx = s.transaction().unwrap();
            {
                let mut view = BudgetViewTx::new(&mut *tx);
                view.dispatch_event(&Event::ActionBudgetTopUp {
                    signer: 42,
                    gas_resource: RESOURCE_ID_ETH,
                    gas_amount: 1,
                    budget_increment: delta,
                    pool_actor: 1,
                })
                .unwrap();
            }
            tx.commit().unwrap();
        }
        let view = BudgetView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 175);
        // Pool ETH accumulated 1 + 1 + 1 = 3.
        assert_eq!(view.get_pool_eth(1).unwrap(), 3);
    }

    /// Cumulative semantics: ETH and BOLD legs accumulate
    /// independently.
    #[test]
    fn eth_bold_legs_independent() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // ETH: 100, BOLD: 200, ETH: 50, BOLD: 25.
        let events = [
            (RESOURCE_ID_ETH, 100u128),
            (RESOURCE_ID_BOLD, 200),
            (RESOURCE_ID_ETH, 50),
            (RESOURCE_ID_BOLD, 25),
        ];
        for (i, (r, amt)) in events.iter().enumerate() {
            let mut tx = s.transaction().unwrap();
            {
                let mut view = BudgetViewTx::new(&mut *tx);
                view.dispatch_event(&Event::DepositWithFeeCredited {
                    resource: *r,
                    recipient: 42,
                    pool_actor: 1,
                    user_amount: 1,
                    pool_amount: *amt,
                    budget_grant: (i as u128) + 1,
                    deposit_id: i as u64,
                })
                .unwrap();
            }
            tx.commit().unwrap();
        }
        let view = BudgetView::new(&s);
        // ETH leg: 100 + 50 = 150.
        assert_eq!(view.get_pool_eth(1).unwrap(), 150);
        // BOLD leg: 200 + 25 = 225.
        assert_eq!(view.get_pool_bold(1).unwrap(), 225);
        // Recipient's budget: 1 + 2 + 3 + 4 = 10.
        assert_eq!(view.get_actor_budget(42).unwrap(), 10);
    }

    /// Saturating credit semantics: budget credit at u128::MAX
    /// stays at u128::MAX (no panic).
    #[test]
    fn budget_credit_saturates_at_u128_max() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // Pre-credit to u128::MAX - 5 via direct put.
        let pre = u128::MAX - 5;
        let key = actor_budget_key(42);
        s.put(&key, &pre.to_be_bytes()).unwrap();
        // Credit 100 — should saturate.
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.dispatch_event(&Event::ActionBudgetTopUp {
                signer: 42,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 1,
                budget_increment: 100,
                pool_actor: 1,
            })
            .unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), u128::MAX);
    }

    /// Saturating credit semantics: ETH pool credit at u128::MAX
    /// stays at u128::MAX.
    #[test]
    fn pool_eth_credit_saturates() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let pre = u128::MAX - 5;
        let key = pool_eth_key(1);
        s.put(&key, &pre.to_be_bytes()).unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.dispatch_event(&Event::DepositWithFeeCredited {
                resource: RESOURCE_ID_ETH,
                recipient: 0,
                pool_actor: 1,
                user_amount: 0,
                pool_amount: 100,
                budget_grant: 0,
                deposit_id: 0,
            })
            .unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        assert_eq!(view.get_pool_eth(1).unwrap(), u128::MAX);
    }

    /// Scanning the budget view returns entries in ascending
    /// actor-id order.
    #[test]
    fn scan_actor_budgets_ordered() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // Insert in mixed order.
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.credit_actor_budget(5, 50).unwrap();
            view.credit_actor_budget(1, 10).unwrap();
            view.credit_actor_budget(3, 30).unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        let rows = view.scan_actor_budgets().unwrap();
        assert_eq!(rows, vec![(1, 10), (3, 30), (5, 50)]);
    }

    /// Scanning the ETH pool view returns entries in ascending
    /// pool-actor order.
    #[test]
    fn scan_pool_eth_ordered() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.credit_pool_eth(7, 70).unwrap();
            view.credit_pool_eth(2, 20).unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        let rows = view.scan_pool_eth().unwrap();
        assert_eq!(rows, vec![(2, 20), (7, 70)]);
    }

    /// Scanning the BOLD pool view returns entries in ascending
    /// pool-actor order.
    #[test]
    fn scan_pool_bold_ordered() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.credit_pool_bold(99, 999).unwrap();
            view.credit_pool_bold(1, 1).unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        let rows = view.scan_pool_bold().unwrap();
        assert_eq!(rows, vec![(1, 1), (99, 999)]);
    }

    /// Scans don't bleed across keyspaces: the budget view's
    /// scan doesn't surface pool entries and vice versa.
    #[test]
    fn scans_dont_bleed_across_keyspaces() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.credit_actor_budget(1, 10).unwrap();
            view.credit_pool_eth(1, 100).unwrap();
            view.credit_pool_bold(1, 1000).unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        assert_eq!(view.scan_actor_budgets().unwrap(), vec![(1, 10)]);
        assert_eq!(view.scan_pool_eth().unwrap(), vec![(1, 100)]);
        assert_eq!(view.scan_pool_bold().unwrap(), vec![(1, 1000)]);
    }

    /// Corrupt cell (wrong length) is surfaced via
    /// `BudgetViewError::CorruptCell`.
    #[test]
    fn corrupt_cell_surfaced() {
        let s = SqliteStorage::open_in_memory().unwrap();
        // Plant a malformed budget value.
        let k = actor_budget_key(42);
        s.put(&k, &[0xAA; 8]).unwrap();
        let view = BudgetView::new(&s);
        match view.get_actor_budget(42) {
            Err(BudgetViewError::CorruptCell {
                view,
                actor,
                expected,
                actual,
            }) => {
                assert_eq!(view, "actor_budgets");
                assert_eq!(actor, 42);
                assert_eq!(expected, 16);
                assert_eq!(actual, 8);
            }
            other => panic!("expected CorruptCell, got {other:?}"),
        }
    }

    /// Corrupt cell on the ETH pool view is reported with the
    /// correct view label.
    #[test]
    fn corrupt_cell_pool_eth_view_label() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let k = pool_eth_key(7);
        s.put(&k, &[0xAA; 5]).unwrap();
        let view = BudgetView::new(&s);
        match view.get_pool_eth(7) {
            Err(BudgetViewError::CorruptCell { view, actor, .. }) => {
                assert_eq!(view, "pool_balances_eth");
                assert_eq!(actor, 7);
            }
            other => panic!("expected CorruptCell, got {other:?}"),
        }
    }

    /// Corrupt cell on the BOLD pool view is reported with the
    /// correct view label.
    #[test]
    fn corrupt_cell_pool_bold_view_label() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let k = pool_bold_key(7);
        s.put(&k, &[0xAA; 5]).unwrap();
        let view = BudgetView::new(&s);
        match view.get_pool_bold(7) {
            Err(BudgetViewError::CorruptCell { view, .. }) => {
                assert_eq!(view, "pool_balances_bold");
            }
            other => panic!("expected CorruptCell, got {other:?}"),
        }
    }

    /// Multi-event sequence yields expected aggregate state.
    /// Models a typical L2 epoch: 1 deposit-with-fee (recipient
    /// gets balance + budget), 2 self top-ups, 1 delegated
    /// top-up.
    #[test]
    fn multi_event_aggregate() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let events = vec![
            // Alice (42) deposits via fee-split; gets 100 ETH user
            // amount, 10 ETH pool credit, 50 budget grant.
            Event::DepositWithFeeCredited {
                resource: RESOURCE_ID_ETH,
                recipient: 42,
                pool_actor: 1,
                user_amount: 100,
                pool_amount: 10,
                budget_grant: 50,
                deposit_id: 1,
            },
            // Alice tops up: pays 5 ETH for 30 budget.
            Event::ActionBudgetTopUp {
                signer: 42,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 5,
                budget_increment: 30,
                pool_actor: 1,
            },
            // Bob (77) tops up: pays 3 BOLD for 20 budget.
            Event::ActionBudgetTopUp {
                signer: 77,
                gas_resource: RESOURCE_ID_BOLD,
                gas_amount: 3,
                budget_increment: 20,
                pool_actor: 1,
            },
            // Charlie (99) delegates to Alice: pays 2 ETH for 15
            // budget credited to Alice.
            Event::DelegatedActionBudgetTopUp {
                recipient: 42,
                signer: 99,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 2,
                budget_increment: 15,
                pool_actor: 1,
            },
        ];
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            for e in &events {
                view.dispatch_event(e).unwrap();
            }
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        // Alice (42): 50 from deposit + 30 from own top-up + 15 from
        // delegated top-up = 95.
        assert_eq!(view.get_actor_budget(42).unwrap(), 95);
        // Bob (77): 20 from his own top-up.
        assert_eq!(view.get_actor_budget(77).unwrap(), 20);
        // Charlie (99): 0 — paid for Alice but didn't credit himself.
        assert_eq!(view.get_actor_budget(99).unwrap(), 0);
        // Pool ETH: 10 + 5 + 2 = 17.
        assert_eq!(view.get_pool_eth(1).unwrap(), 17);
        // Pool BOLD: 3.
        assert_eq!(view.get_pool_bold(1).unwrap(), 3);
    }

    /// Tx rollback discards every staged budget mutation.
    #[test]
    fn tx_rollback_discards() {
        let s = SqliteStorage::open_in_memory().unwrap();
        {
            let mut tx = s.transaction().unwrap();
            {
                let mut view = BudgetViewTx::new(&mut *tx);
                view.credit_actor_budget(42, 100).unwrap();
                view.credit_pool_eth(1, 50).unwrap();
            }
            tx.rollback().unwrap();
        }
        let view = BudgetView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 0);
        assert_eq!(view.get_pool_eth(1).unwrap(), 0);
    }

    /// Tx view sees its own staged writes (read-your-writes).
    #[test]
    fn tx_view_read_your_writes() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.credit_actor_budget(42, 100).unwrap();
            // Read inside the transaction sees the staged value.
            assert_eq!(view.get_actor_budget(42).unwrap(), 100);
            view.credit_actor_budget(42, 50).unwrap();
            assert_eq!(view.get_actor_budget(42).unwrap(), 150);
            view.credit_pool_eth(1, 200).unwrap();
            assert_eq!(view.get_pool_eth(1).unwrap(), 200);
        }
        tx.commit().unwrap();
        // After commit, the read-only view sees the same values.
        let view = BudgetView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 150);
        assert_eq!(view.get_pool_eth(1).unwrap(), 200);
    }

    /// Storage error round-trips through `BudgetViewError::Storage`.
    #[test]
    fn storage_error_roundtrip() {
        let se = knomosis_storage::storage::StorageError::Other("test".to_string());
        let be: BudgetViewError = se.into();
        assert!(be.to_string().contains("storage error"));
    }

    /// Unknown resource ID on `DepositWithFeeCredited` doesn't
    /// touch either pool leg (silently ignored — the indexer's
    /// pool view tracks only ETH and BOLD at this WU's scope).
    /// Budget is still credited.
    #[test]
    fn unknown_resource_pool_inflow_ignored() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.transaction().unwrap();
        {
            let mut view = BudgetViewTx::new(&mut *tx);
            view.dispatch_event(&Event::DepositWithFeeCredited {
                resource: 99, // not ETH (0) and not BOLD (1)
                recipient: 42,
                pool_actor: 1,
                user_amount: 100,
                pool_amount: 100,
                budget_grant: 50,
                deposit_id: 1,
            })
            .unwrap();
        }
        tx.commit().unwrap();
        let view = BudgetView::new(&s);
        // Budget credited.
        assert_eq!(view.get_actor_budget(42).unwrap(), 50);
        // Neither pool leg credited.
        assert_eq!(view.get_pool_eth(1).unwrap(), 0);
        assert_eq!(view.get_pool_bold(1).unwrap(), 0);
    }
}
