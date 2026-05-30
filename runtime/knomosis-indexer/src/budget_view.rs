// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! WU GP.6.4 — per-actor budget view + per-resource gas-pool view
//! (now backed by five physical SQLite tables, NOT keyspaces).
//!
//! This module dispatches the Workstream-GP gas-pool events to the
//! five SQLite tables created by
//! `knomosis-storage::migration_002_budget_views`:
//!
//!   1. **`actor_budgets`** — lifetime cumulative budget grants
//!      received per actor.
//!   2. **`actor_budgets_current_epoch_grants`** — per-actor grants
//!      received in the current epoch (reset at every epoch
//!      boundary by `CombinedTransactionOps::reset_current_epoch`).
//!   3. **`actor_budgets_current_epoch_consumed`** — per-actor
//!      consumption in the current epoch (sourced from the GP.6.4
//!      `Event.budgetConsumed` event, tag 20).
//!   4. **`pool_balances_eth`** — per-pool-actor NET ETH balance
//!      (gross inflows minus drains when `--gas-pool-actor`
//!      matches).
//!   5. **`pool_balances_bold`** — symmetric for BOLD.
//!
//! ## Semantics — "N actions remaining this epoch"
//!
//! With the GP.6.4 wiring, a deployment UI computes:
//!
//! ```text
//!   remaining_this_epoch(a) = freeTier
//!                           + actor_budgets_current_epoch_grants[a]
//!                           - actor_budgets_current_epoch_consumed[a]
//! ```
//!
//! Lifetime totals (billing / leaderboards / historical analysis)
//! use `actor_budgets[a]`.
//!
//! ## Dispatch table
//!
//! | Tag | Event                          | `actor_budgets`           | `*_current_epoch_grants`     | `*_current_epoch_consumed` | `pool_balances_{eth,bold}` |
//! |-----|--------------------------------|---------------------------|------------------------------|----------------------------|----------------------------|
//! | 16  | `DepositWithFeeCredited`       | `recipient += budget_grant`| `recipient += budget_grant` | —                          | `pool_actor += pool_amount` if r ∈ {0,1} |
//! | 17  | `ActionBudgetTopUp`            | `signer += budget_increment`| `signer += budget_increment`| —                         | `pool_actor += gas_amount` if gr ∈ {0,1} |
//! | 18  | `GasPoolClaim`                 | —                         | —                            | —                          | `gas_pool_actor -= amount` if gr ∈ {0,1} AND configured |
//! | 19  | `DelegatedActionBudgetTopUp`   | `recipient += budget_increment`| `recipient += budget_increment`| —                     | `pool_actor += gas_amount` if gr ∈ {0,1} |
//! | 20  | `BudgetConsumed`               | —                         | —                            | `actor += amount`          | —                          |
//! | Other tags                          | —                         | —                            | —                          | —                          |
//!
//! ## Overflow / underflow discipline
//!
//! All credits use `checked_add` and HALT on overflow (consistent
//! with the balance view's halt-on-overflow discipline).  All
//! debits use `checked_sub` and HALT on underflow.  Halts surface
//! via `?` propagation; the combined transaction rolls back the
//! entire batch atomically.

use knomosis_storage::combined_transaction::{CombinedTransactionError, CombinedTransactionOps};
use knomosis_storage::sqlite::SqliteStorage;

use crate::event::{
    ActorId, Amount, BudgetUnits, Event, ResourceId, RESOURCE_ID_BOLD, RESOURCE_ID_ETH,
};

/// Key in the kv table for the indexer's persisted "current epoch"
/// cell.  Read by `apply_batch` to detect epoch crossings.
/// 8-byte BE u64 value.
pub const CURRENT_EPOCH_KEY: &[u8] = b"c/current_epoch";

/// Fixed width of the current-epoch cell.
pub const CURRENT_EPOCH_VALUE_LEN: usize = 8;

/// Errors surfaced by GP.6.4 dispatch — re-export of the
/// combined-transaction error type for uniform propagation.
pub type BudgetDispatchError = CombinedTransactionError;

/// Read the persisted current epoch from the kv table.  Returns
/// 0 if the cell is absent (brand-new database).
///
/// # Errors
///
/// See [`BudgetDispatchError`].
pub fn read_current_epoch(tx: &dyn CombinedTransactionOps) -> Result<u64, BudgetDispatchError> {
    let cell = tx.kv_get(CURRENT_EPOCH_KEY)?;
    match cell {
        None => Ok(0),
        Some(bytes) if bytes.len() == CURRENT_EPOCH_VALUE_LEN => {
            let mut buf = [0u8; CURRENT_EPOCH_VALUE_LEN];
            buf.copy_from_slice(&bytes);
            Ok(u64::from_be_bytes(buf))
        }
        Some(bytes) => {
            tracing::warn!(
                actual_len = bytes.len(),
                expected_len = CURRENT_EPOCH_VALUE_LEN,
                "corrupt current_epoch cell: treating as 0; restart indexer to recover"
            );
            Ok(0)
        }
    }
}

/// Persist the current epoch to the kv table.
///
/// # Errors
///
/// See [`BudgetDispatchError`].
pub fn write_current_epoch(
    tx: &mut dyn CombinedTransactionOps,
    epoch: u64,
) -> Result<(), BudgetDispatchError> {
    tx.kv_put(CURRENT_EPOCH_KEY, &epoch.to_be_bytes())?;
    Ok(())
}

/// Compute the epoch number for a given log sequence number,
/// given an `epoch_length` config.  With `epoch_length = 0`,
/// epoch advancement is disabled (always returns 0).
///
/// Mirrors Lean's `BudgetPolicy.advanceEpoch` semantics:
/// `currentEpoch = seq / epochLength` for `epochLength > 0`.
#[must_use]
pub const fn epoch_for_seq(seq: u64, epoch_length: u64) -> u64 {
    if epoch_length == 0 {
        0
    } else {
        seq / epoch_length
    }
}

/// If `seq` falls in a different epoch than the persisted
/// `current_epoch`, reset the per-epoch tables and update the
/// persisted epoch.  Called by the indexer's `apply_batch`
/// BEFORE the per-event dispatch loop.
///
/// **Math.**  An epoch crossing means at least one full
/// `epoch_length` has elapsed since the last persisted epoch.
/// The per-epoch tables represent values WITHIN the current
/// epoch only; on crossing, they must reset to 0 for every
/// actor (DELETE FROM ...).  The dispatch then proceeds against
/// the new (empty) epoch.
///
/// Returns `true` iff an epoch crossing occurred + tables were
/// reset.
///
/// # Errors
///
/// See [`BudgetDispatchError`].
pub fn dispatch_epoch_if_crossed(
    tx: &mut dyn CombinedTransactionOps,
    seq: u64,
    epoch_length: u64,
) -> Result<bool, BudgetDispatchError> {
    let new_epoch = epoch_for_seq(seq, epoch_length);
    let persisted_epoch = read_current_epoch(tx)?;
    if new_epoch == persisted_epoch {
        return Ok(false);
    }
    tx.reset_current_epoch()?;
    write_current_epoch(tx, new_epoch)?;
    tracing::info!(
        previous_epoch = persisted_epoch,
        new_epoch,
        seq,
        epoch_length,
        "GP.6.4: epoch boundary crossed; reset current-epoch tables"
    );
    Ok(true)
}

/// Dispatch a single event to the GP.6.4 budget / pool tables.
/// No-op for non-GP events.
///
/// `gas_pool_actor` is the operator-configured pool actor whose
/// pool view should be DECREMENTED on `Event.gasPoolClaim`.  When
/// `None`, GasPoolClaim is a no-op (gross-inflow semantics
/// preserved); when `Some(p)`, GasPoolClaim with `resource ∈
/// {0, 1}` decrements `pool_balances_{eth,bold}[p]`.
///
/// **Math.**  See the module docstring's dispatch table.
///
/// # Errors
///
/// See [`BudgetDispatchError`].  Credit overflow halts the
/// batch; drain underflow halts; corrupt cells halt.
pub fn dispatch_event(
    tx: &mut dyn CombinedTransactionOps,
    event: &Event,
    gas_pool_actor: Option<ActorId>,
) -> Result<(), BudgetDispatchError> {
    match event {
        Event::DepositWithFeeCredited {
            resource,
            recipient,
            pool_actor,
            pool_amount,
            budget_grant,
            ..
        } => {
            // Lifetime + current-epoch grant to recipient.
            tx.credit_actor_budget(*recipient, *budget_grant)?;
            tx.credit_actor_budget_current_epoch_grants(*recipient, *budget_grant)?;
            credit_pool_inflow(tx, *resource, *pool_actor, *pool_amount)?;
        }
        Event::ActionBudgetTopUp {
            signer,
            gas_resource,
            gas_amount,
            budget_increment,
            pool_actor,
        } => {
            // Lifetime + current-epoch grant to signer.
            tx.credit_actor_budget(*signer, *budget_increment)?;
            tx.credit_actor_budget_current_epoch_grants(*signer, *budget_increment)?;
            credit_pool_inflow(tx, *gas_resource, *pool_actor, *gas_amount)?;
        }
        Event::DelegatedActionBudgetTopUp {
            recipient,
            gas_resource,
            gas_amount,
            budget_increment,
            pool_actor,
            ..
        } => {
            // Lifetime + current-epoch grant to RECIPIENT (NOT
            // signer — the load-bearing distinction from tag 17).
            tx.credit_actor_budget(*recipient, *budget_increment)?;
            tx.credit_actor_budget_current_epoch_grants(*recipient, *budget_increment)?;
            credit_pool_inflow(tx, *gas_resource, *pool_actor, *gas_amount)?;
        }
        Event::GasPoolClaim {
            resource,
            sequencer,
            amount,
        } => {
            // Drain wiring.  If operator configured a
            // gas_pool_actor, decrement that actor's pool view;
            // else no-op (preserves gross-inflow semantics).
            if let Some(pool_actor) = gas_pool_actor {
                drain_pool(tx, *resource, pool_actor, *amount)?;
                tracing::debug!(
                    sequencer,
                    resource,
                    amount,
                    pool_actor,
                    "GP.6.4: drained pool actor on gasPoolClaim"
                );
            } else {
                tracing::debug!(
                    sequencer,
                    resource,
                    amount,
                    "GP.6.4: gasPoolClaim received but --gas-pool-actor unset; pool view shows gross inflow"
                );
            }
        }
        Event::BudgetConsumed { actor, amount } => {
            // GP.6.4: track current-epoch consumption.
            tx.credit_actor_budget_current_epoch_consumed(*actor, *amount)?;
        }
        // Non-GP events (tags 0..=15) are out of scope.
        _ => {}
    }
    Ok(())
}

/// Credit a pool inflow, routing to ETH or BOLD based on
/// resource.  Other resources are silently skipped with a
/// `tracing::warn!` so operators see untracked-resource flow.
fn credit_pool_inflow(
    tx: &mut dyn CombinedTransactionOps,
    resource: ResourceId,
    pool_actor: ActorId,
    amount: Amount,
) -> Result<(), BudgetDispatchError> {
    match resource {
        RESOURCE_ID_ETH => {
            tx.credit_pool_eth(pool_actor, amount)?;
        }
        RESOURCE_ID_BOLD => {
            tx.credit_pool_bold(pool_actor, amount)?;
        }
        other => {
            tracing::warn!(
                resource = other,
                pool_actor,
                amount,
                "GP.6.4: pool inflow on unknown resource (not ETH=0 or BOLD=1); silently skipped"
            );
        }
    }
    Ok(())
}

/// Drain a pool view, routing to ETH or BOLD based on resource.
/// Halts on underflow.
fn drain_pool(
    tx: &mut dyn CombinedTransactionOps,
    resource: ResourceId,
    pool_actor: ActorId,
    amount: BudgetUnits,
) -> Result<(), BudgetDispatchError> {
    match resource {
        RESOURCE_ID_ETH => {
            tx.debit_pool_eth(pool_actor, amount)?;
        }
        RESOURCE_ID_BOLD => {
            tx.debit_pool_bold(pool_actor, amount)?;
        }
        other => {
            tracing::warn!(
                resource = other,
                pool_actor,
                amount,
                "GP.6.4: drain on unknown resource (not ETH=0 or BOLD=1); silently skipped"
            );
        }
    }
    Ok(())
}

/// Read-only handle for budget / pool views.  Wraps a
/// `SqliteStorage` reference and delegates to the
/// `BudgetStorage` trait for typed queries.  Used by the
/// `query-*` CLI subcommands.
pub struct BudgetReadView<'a> {
    storage: &'a SqliteStorage,
}

impl<'a> BudgetReadView<'a> {
    /// Construct a read view over `storage`.
    #[must_use]
    pub fn new(storage: &'a SqliteStorage) -> Self {
        Self { storage }
    }

    /// Read the lifetime cumulative budget grant for `actor`.
    ///
    /// # Errors
    ///
    /// See `knomosis_storage::budget_storage::BudgetStorageError`.
    pub fn get_actor_budget(
        &self,
        actor: ActorId,
    ) -> Result<BudgetUnits, knomosis_storage::budget_storage::BudgetStorageError> {
        use knomosis_storage::budget_storage::BudgetStorage;
        self.storage.get_actor_budget(actor)
    }

    /// Read the current-epoch grants counter for `actor`.
    ///
    /// # Errors
    ///
    /// See `knomosis_storage::budget_storage::BudgetStorageError`.
    pub fn get_actor_budget_current_epoch_grants(
        &self,
        actor: ActorId,
    ) -> Result<BudgetUnits, knomosis_storage::budget_storage::BudgetStorageError> {
        use knomosis_storage::budget_storage::BudgetStorage;
        self.storage.get_actor_budget_current_epoch_grants(actor)
    }

    /// Read the current-epoch consumed counter for `actor`.
    ///
    /// # Errors
    ///
    /// See `knomosis_storage::budget_storage::BudgetStorageError`.
    pub fn get_actor_budget_current_epoch_consumed(
        &self,
        actor: ActorId,
    ) -> Result<BudgetUnits, knomosis_storage::budget_storage::BudgetStorageError> {
        use knomosis_storage::budget_storage::BudgetStorage;
        self.storage.get_actor_budget_current_epoch_consumed(actor)
    }

    /// Read the per-pool-actor ETH (resource 0) balance.
    ///
    /// # Errors
    ///
    /// See `knomosis_storage::budget_storage::BudgetStorageError`.
    pub fn get_pool_eth(
        &self,
        pool_actor: ActorId,
    ) -> Result<Amount, knomosis_storage::budget_storage::BudgetStorageError> {
        use knomosis_storage::budget_storage::BudgetStorage;
        self.storage.get_pool_eth(pool_actor)
    }

    /// Read the per-pool-actor BOLD (resource 1) balance.
    ///
    /// # Errors
    ///
    /// See `knomosis_storage::budget_storage::BudgetStorageError`.
    pub fn get_pool_bold(
        &self,
        pool_actor: ActorId,
    ) -> Result<Amount, knomosis_storage::budget_storage::BudgetStorageError> {
        use knomosis_storage::budget_storage::BudgetStorage;
        self.storage.get_pool_bold(pool_actor)
    }

    /// Convenience: compute "remaining this epoch" given the
    /// deployment's `free_tier`.  Returns `free_tier +
    /// grants_this_epoch - consumed_this_epoch`, saturating at 0
    /// on underflow.
    ///
    /// # Errors
    ///
    /// See `knomosis_storage::budget_storage::BudgetStorageError`.
    pub fn remaining_this_epoch(
        &self,
        actor: ActorId,
        free_tier: BudgetUnits,
    ) -> Result<BudgetUnits, knomosis_storage::budget_storage::BudgetStorageError> {
        let grants = self.get_actor_budget_current_epoch_grants(actor)?;
        let consumed = self.get_actor_budget_current_epoch_consumed(actor)?;
        let total = free_tier.saturating_add(grants);
        Ok(total.saturating_sub(consumed))
    }
}

#[cfg(test)]
mod tests {
    use super::{
        dispatch_epoch_if_crossed, dispatch_event, epoch_for_seq, read_current_epoch,
        write_current_epoch, BudgetReadView, CURRENT_EPOCH_KEY, CURRENT_EPOCH_VALUE_LEN,
    };
    use crate::event::{Event, RESOURCE_ID_BOLD, RESOURCE_ID_ETH};
    use knomosis_storage::combined_transaction::CombinedStorage;
    use knomosis_storage::sqlite::SqliteStorage;

    /// Constants pinned.
    #[test]
    fn constants_stable() {
        assert_eq!(CURRENT_EPOCH_KEY, b"c/current_epoch");
        assert_eq!(CURRENT_EPOCH_VALUE_LEN, 8);
    }

    /// `epoch_for_seq` returns 0 when epoch advancement is disabled.
    #[test]
    fn epoch_for_seq_disabled() {
        for seq in [0u64, 1, 100, 1000, u64::MAX] {
            assert_eq!(epoch_for_seq(seq, 0), 0);
        }
    }

    /// `epoch_for_seq` returns `seq / epoch_length`.
    #[test]
    fn epoch_for_seq_enabled() {
        assert_eq!(epoch_for_seq(0, 10), 0);
        assert_eq!(epoch_for_seq(5, 10), 0);
        assert_eq!(epoch_for_seq(9, 10), 0);
        assert_eq!(epoch_for_seq(10, 10), 1);
        assert_eq!(epoch_for_seq(15, 10), 1);
        assert_eq!(epoch_for_seq(20, 10), 2);
        assert_eq!(epoch_for_seq(99, 10), 9);
        assert_eq!(epoch_for_seq(100, 10), 10);
    }

    /// Fresh database: read_current_epoch returns 0.
    #[test]
    fn fresh_db_epoch_is_zero() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let tx = s.begin_combined_tx().unwrap();
        assert_eq!(read_current_epoch(&*tx).unwrap(), 0);
    }

    /// write then read round-trips current epoch.
    #[test]
    fn write_then_read_current_epoch() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        write_current_epoch(&mut *tx, 42).unwrap();
        tx.commit().unwrap();
        let tx = s.begin_combined_tx().unwrap();
        assert_eq!(read_current_epoch(&*tx).unwrap(), 42);
    }

    /// dispatch_epoch_if_crossed returns false when no crossing
    /// happens (same epoch).
    #[test]
    fn no_crossing_returns_false() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        write_current_epoch(&mut *tx, 5).unwrap();
        tx.commit().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        let crossed = dispatch_epoch_if_crossed(&mut *tx, 53, 10).unwrap();
        assert!(!crossed);
        assert_eq!(read_current_epoch(&*tx).unwrap(), 5);
    }

    /// dispatch_epoch_if_crossed returns true and resets the
    /// per-epoch tables on crossing.
    #[test]
    fn crossing_resets_per_epoch_tables() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        write_current_epoch(&mut *tx, 5).unwrap();
        tx.credit_actor_budget(42, 1000).unwrap();
        tx.credit_actor_budget_current_epoch_grants(42, 100)
            .unwrap();
        tx.credit_actor_budget_current_epoch_consumed(42, 50)
            .unwrap();
        tx.commit().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        let crossed = dispatch_epoch_if_crossed(&mut *tx, 60, 10).unwrap();
        assert!(crossed);
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 1000);
        assert_eq!(view.get_actor_budget_current_epoch_grants(42).unwrap(), 0);
        assert_eq!(view.get_actor_budget_current_epoch_consumed(42).unwrap(), 0);
    }

    /// dispatch_epoch_if_crossed with epoch_length=0 never crosses.
    #[test]
    fn no_epoch_length_never_crosses() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        for seq in [1u64, 100, 1000, 10000] {
            let crossed = dispatch_epoch_if_crossed(&mut *tx, seq, 0).unwrap();
            assert!(!crossed);
        }
        tx.commit().unwrap();
    }

    /// dispatch_event on DepositWithFeeCredited credits BOTH
    /// lifetime AND current-epoch tables.
    #[test]
    fn dispatch_deposit_with_fee_credits_both_lifetime_and_current_epoch() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        dispatch_event(
            &mut *tx,
            &Event::DepositWithFeeCredited {
                resource: RESOURCE_ID_ETH,
                recipient: 42,
                pool_actor: 1,
                user_amount: 900,
                pool_amount: 100,
                budget_grant: 50,
                deposit_id: 7,
            },
            None,
        )
        .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 50);
        assert_eq!(view.get_actor_budget_current_epoch_grants(42).unwrap(), 50);
        assert_eq!(view.get_pool_eth(1).unwrap(), 100);
    }

    /// dispatch_event on ActionBudgetTopUp credits SIGNER's
    /// lifetime + current-epoch grants.
    #[test]
    fn dispatch_action_budget_top_up_credits_signer() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        dispatch_event(
            &mut *tx,
            &Event::ActionBudgetTopUp {
                signer: 99,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 10,
                budget_increment: 100,
                pool_actor: 1,
            },
            None,
        )
        .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_actor_budget(99).unwrap(), 100);
        assert_eq!(view.get_actor_budget_current_epoch_grants(99).unwrap(), 100);
        assert_eq!(view.get_pool_eth(1).unwrap(), 10);
    }

    /// dispatch_event on DelegatedActionBudgetTopUp credits
    /// RECIPIENT (not signer).
    #[test]
    fn dispatch_delegated_top_up_credits_recipient_not_signer() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        dispatch_event(
            &mut *tx,
            &Event::DelegatedActionBudgetTopUp {
                recipient: 55,
                signer: 77,
                gas_resource: RESOURCE_ID_ETH,
                gas_amount: 10,
                budget_increment: 100,
                pool_actor: 1,
            },
            None,
        )
        .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_actor_budget(55).unwrap(), 100);
        assert_eq!(view.get_actor_budget_current_epoch_grants(55).unwrap(), 100);
        assert_eq!(view.get_actor_budget(77).unwrap(), 0);
    }

    /// dispatch_event on BudgetConsumed (tag 20) credits
    /// current-epoch consumed counter.
    #[test]
    fn dispatch_budget_consumed_credits_current_epoch_consumed() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        dispatch_event(
            &mut *tx,
            &Event::BudgetConsumed {
                actor: 42,
                amount: 1,
            },
            None,
        )
        .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 0);
        assert_eq!(view.get_actor_budget_current_epoch_consumed(42).unwrap(), 1);
    }

    /// GasPoolClaim with no gas_pool_actor configured: no-op.
    #[test]
    fn gas_pool_claim_no_actor_is_noop() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        tx.credit_pool_eth(1, 1000).unwrap();
        tx.commit().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        dispatch_event(
            &mut *tx,
            &Event::GasPoolClaim {
                resource: RESOURCE_ID_ETH,
                sequencer: 2,
                amount: 100,
            },
            None,
        )
        .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_pool_eth(1).unwrap(), 1000);
    }

    /// GasPoolClaim WITH gas_pool_actor configured: drains.
    #[test]
    fn gas_pool_claim_with_actor_drains() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        tx.credit_pool_eth(1, 1000).unwrap();
        tx.commit().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        dispatch_event(
            &mut *tx,
            &Event::GasPoolClaim {
                resource: RESOURCE_ID_ETH,
                sequencer: 2,
                amount: 300,
            },
            Some(1),
        )
        .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_pool_eth(1).unwrap(), 700);
    }

    /// GasPoolClaim drain underflow halts.
    #[test]
    fn gas_pool_claim_drain_underflow_halts() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        tx.credit_pool_eth(1, 50).unwrap();
        tx.commit().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        let result = dispatch_event(
            &mut *tx,
            &Event::GasPoolClaim {
                resource: RESOURCE_ID_ETH,
                sequencer: 2,
                amount: 500,
            },
            Some(1),
        );
        assert!(result.is_err());
        tx.rollback().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_pool_eth(1).unwrap(), 50);
    }

    /// Non-GP event: no-op.
    #[test]
    fn non_gp_event_noop() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        dispatch_event(
            &mut *tx,
            &Event::BalanceChanged {
                resource: 0,
                actor: 42,
                old_value: 0,
                new_value: 100,
            },
            None,
        )
        .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 0);
    }

    /// BOLD-resource dispatch credits the BOLD pool table.
    #[test]
    fn bold_resource_credits_bold_pool() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        dispatch_event(
            &mut *tx,
            &Event::DepositWithFeeCredited {
                resource: RESOURCE_ID_BOLD,
                recipient: 42,
                pool_actor: 1,
                user_amount: 900,
                pool_amount: 200,
                budget_grant: 75,
                deposit_id: 8,
            },
            None,
        )
        .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_pool_bold(1).unwrap(), 200);
        assert_eq!(view.get_pool_eth(1).unwrap(), 0);
    }

    /// Unknown resource pool inflow silently skipped (tracing
    /// warning).  Budget credit still applies.
    #[test]
    fn unknown_resource_pool_inflow_silently_skipped() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        dispatch_event(
            &mut *tx,
            &Event::DepositWithFeeCredited {
                resource: 99,
                recipient: 42,
                pool_actor: 1,
                user_amount: 900,
                pool_amount: 100,
                budget_grant: 50,
                deposit_id: 7,
            },
            None,
        )
        .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.get_actor_budget(42).unwrap(), 50);
        assert_eq!(view.get_pool_eth(1).unwrap(), 0);
        assert_eq!(view.get_pool_bold(1).unwrap(), 0);
    }

    /// `remaining_this_epoch` arithmetic.
    #[test]
    fn remaining_this_epoch_arithmetic() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        tx.credit_actor_budget_current_epoch_grants(42, 100)
            .unwrap();
        tx.credit_actor_budget_current_epoch_consumed(42, 30)
            .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.remaining_this_epoch(42, 10).unwrap(), 80);
    }

    /// `remaining_this_epoch` saturates at 0 on consumed >
    /// freeTier + grants.
    #[test]
    fn remaining_this_epoch_saturates_at_zero() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        tx.credit_actor_budget_current_epoch_consumed(42, 1000)
            .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.remaining_this_epoch(42, 10).unwrap(), 0);
    }

    /// `remaining_this_epoch` saturates at u128::MAX on
    /// freeTier+grants overflow.
    #[test]
    fn remaining_this_epoch_saturates_at_max_on_overflow() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        tx.credit_actor_budget_current_epoch_grants(42, u128::MAX - 5)
            .unwrap();
        tx.commit().unwrap();
        let view = BudgetReadView::new(&s);
        assert_eq!(view.remaining_this_epoch(42, 100).unwrap(), u128::MAX);
    }

    /// Dispatch on all 21 event tags — exhaustiveness check.
    #[test]
    fn dispatch_event_total_on_all_tags() {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut tx = s.begin_combined_tx().unwrap();
        let events: Vec<Event> = vec![
            Event::BalanceChanged {
                resource: 0,
                actor: 0,
                old_value: 0,
                new_value: 0,
            },
            Event::NonceAdvanced {
                actor: 0,
                old_nonce: 0,
                new_nonce: 0,
            },
            Event::IdentityRegistered {
                actor: 0,
                key: vec![],
            },
            Event::IdentityRevoked { actor: 0 },
            Event::TimeRecorded { time: 0 },
            Event::DisputeFiled {
                challenger: 0,
                target_idx: 0,
            },
            Event::DisputeWithdrawn { dispute_idx: 0 },
            Event::VerdictApplied {
                dispute_idx: 0,
                outcome_tag: 0,
            },
            Event::RewardIssued {
                resource: 0,
                recipient: 0,
                amount: 0,
            },
            Event::WithdrawalRequested {
                resource: 0,
                sender: 0,
                amount: 0,
                recipient_l1: [0; 20],
                withdrawal_id: 0,
            },
            Event::DepositCredited {
                resource: 0,
                recipient: 0,
                amount: 0,
                deposit_id: 0,
            },
            Event::LocalPolicyDeclared {
                actor: 0,
                policy: vec![],
            },
            Event::LocalPolicyRevoked { actor: 0 },
            Event::FaultProofGameOpened {
                game_id: 0,
                challenger: 0,
                disputed_start_idx: 0,
                disputed_end_idx: 0,
                binding_hash: vec![],
            },
            Event::FaultProofBisectionStep {
                game_id: 0,
                round: 0,
                party: 0,
                idx: 0,
                commit: vec![],
            },
            Event::FaultProofGameSettled {
                game_id: 0,
                winner: 0,
                loser: 0,
                payout: 0,
            },
            Event::DepositWithFeeCredited {
                resource: 0,
                recipient: 0,
                pool_actor: 0,
                user_amount: 0,
                pool_amount: 0,
                budget_grant: 0,
                deposit_id: 0,
            },
            Event::ActionBudgetTopUp {
                signer: 0,
                gas_resource: 0,
                gas_amount: 0,
                budget_increment: 0,
                pool_actor: 0,
            },
            Event::GasPoolClaim {
                resource: 0,
                sequencer: 0,
                amount: 0,
            },
            Event::DelegatedActionBudgetTopUp {
                recipient: 0,
                signer: 0,
                gas_resource: 0,
                gas_amount: 0,
                budget_increment: 0,
                pool_actor: 0,
            },
            Event::BudgetConsumed {
                actor: 0,
                amount: 0,
            },
        ];
        assert_eq!(events.len(), 21);
        let mut tags: Vec<u8> = events.iter().map(Event::tag).collect();
        tags.sort_unstable();
        assert_eq!(tags, (0..=20u8).collect::<Vec<_>>());
        for event in &events {
            dispatch_event(&mut *tx, event, None).unwrap();
        }
        tx.commit().unwrap();
    }
}
