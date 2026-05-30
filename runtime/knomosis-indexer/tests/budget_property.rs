// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! GP.6.4 Stage G: property tests for the budget view.
//!
//! Strategy: generate a random sequence of GP-family events, apply
//! them to the indexer's budget view AND to a reference
//! `HashMap`-based model, then assert byte-for-byte equality of
//! the resulting views.
//!
//! The reference model implements the SAME semantics documented in
//! `budget_view.rs`'s module docstring (lifetime cumulative grants
//! per actor; per-epoch grants reset on epoch boundary; per-epoch
//! consumed reset on epoch boundary; pool view net of GasPoolClaim
//! drains when `--gas-pool-actor` matches; saturating overflow).
//!
//! What this catches:
//!   * Dispatch arm drift (a hand-written test pinning one event
//!     can miss a subtle wrong-actor or wrong-table credit).
//!   * Epoch-boundary off-by-one (the reference resets only at
//!     the FIRST event in a new epoch; the indexer must agree).
//!   * Pool-routing bugs (a future PR rewiring the
//!     `credit_pool_inflow` / `drain_pool` helpers must preserve
//!     the `resource ∈ {ETH, BOLD}` matching).
//!   * GasPoolClaim no-op vs. drain semantics depending on
//!     `--gas-pool-actor`.
//!
//! What this does NOT catch:
//!   * Bugs that AFFECT BOTH the model and the impl (e.g. if both
//!     are off-by-one, the test still passes).  The model is the
//!     load-bearing spec; it must be carefully reviewed.
//!   * SQLite-specific I/O bugs (the model uses in-memory
//!     HashMaps).
//!   * Concurrency bugs (this test is single-threaded; see
//!     `tests/budget_concurrency.rs` for that).

use std::collections::HashMap;

use knomosis_indexer::budget_view::BudgetReadView;
use knomosis_indexer::event::{Event, RESOURCE_ID_BOLD, RESOURCE_ID_ETH};
use knomosis_indexer::indexer::Indexer;
use knomosis_storage::sqlite::SqliteStorage;
use proptest::prelude::*;

// ---- Reference model -----------------------------------------------

/// Simple HashMap-backed reference model for the budget view.
/// Mirrors the semantics documented in
/// `knomosis-indexer/src/budget_view.rs`'s module docstring.
#[derive(Default)]
struct Model {
    /// Lifetime cumulative grants per actor.
    actor_budgets: HashMap<u64, u128>,
    /// Current-epoch grants per actor (reset on epoch boundary).
    cur_grants: HashMap<u64, u128>,
    /// Current-epoch consumed per actor (reset on epoch boundary).
    cur_consumed: HashMap<u64, u128>,
    /// Per-pool-actor ETH balance (resource 0).
    pool_eth: HashMap<u64, u128>,
    /// Per-pool-actor BOLD balance (resource 1).
    pool_bold: HashMap<u64, u128>,
    /// Persisted current epoch (resets per-epoch tables when seq
    /// crosses an epoch boundary).
    current_epoch: u64,
    /// Operator config: `--gas-pool-actor` (None ⇒ GasPoolClaim
    /// is a no-op).
    gas_pool_actor: Option<u64>,
    /// Operator config: `--epoch-length` (0 ⇒ epoch advancement
    /// disabled).
    epoch_length: u64,
}

impl Model {
    fn new(gas_pool_actor: Option<u64>, epoch_length: u64) -> Self {
        Self {
            gas_pool_actor,
            epoch_length,
            ..Default::default()
        }
    }

    /// Mirror of `epoch_for_seq` in budget_view: `(seq - 1) /
    /// epoch_length` so the indexer's per-epoch reset boundaries
    /// coincide with the kernel's `logIndex / epochLength`
    /// (logIndex = seq - 1).
    fn epoch_for_seq(&self, seq: u64) -> u64 {
        if self.epoch_length == 0 {
            0
        } else {
            seq.saturating_sub(1) / self.epoch_length
        }
    }

    /// Mirror of `dispatch_epoch_if_crossed`.  Returns true iff
    /// the per-epoch tables were reset.
    fn cross_epoch_if_needed(&mut self, seq: u64) -> bool {
        let new_epoch = self.epoch_for_seq(seq);
        if new_epoch == self.current_epoch {
            return false;
        }
        self.cur_grants.clear();
        self.cur_consumed.clear();
        self.current_epoch = new_epoch;
        true
    }

    /// Saturating credit; mirrors the v2.0 halt-on-overflow path
    /// for purposes of this property test by REJECTING overflows
    /// (the test generators bound values so overflow can't
    /// happen).
    fn credit_grant(&mut self, actor: u64, delta: u128) -> Result<(), ()> {
        let lt = self.actor_budgets.entry(actor).or_insert(0);
        *lt = lt.checked_add(delta).ok_or(())?;
        let g = self.cur_grants.entry(actor).or_insert(0);
        *g = g.checked_add(delta).ok_or(())?;
        Ok(())
    }

    fn credit_consumed(&mut self, actor: u64, delta: u128) -> Result<(), ()> {
        let c = self.cur_consumed.entry(actor).or_insert(0);
        *c = c.checked_add(delta).ok_or(())?;
        Ok(())
    }

    fn credit_pool(&mut self, resource: u64, pool_actor: u64, amount: u128) -> Result<(), ()> {
        match resource {
            RESOURCE_ID_ETH => {
                let v = self.pool_eth.entry(pool_actor).or_insert(0);
                *v = v.checked_add(amount).ok_or(())?;
            }
            RESOURCE_ID_BOLD => {
                let v = self.pool_bold.entry(pool_actor).or_insert(0);
                *v = v.checked_add(amount).ok_or(())?;
            }
            _ => { /* unknown resource: silently ignored */ }
        }
        Ok(())
    }

    fn debit_pool(&mut self, resource: u64, pool_actor: u64, amount: u128) -> Result<(), ()> {
        match resource {
            RESOURCE_ID_ETH => {
                let v = self.pool_eth.entry(pool_actor).or_insert(0);
                *v = v.checked_sub(amount).ok_or(())?;
            }
            RESOURCE_ID_BOLD => {
                let v = self.pool_bold.entry(pool_actor).or_insert(0);
                *v = v.checked_sub(amount).ok_or(())?;
            }
            _ => { /* unknown resource: silently ignored */ }
        }
        Ok(())
    }

    /// Apply a single event, mirroring `dispatch_event` in
    /// `budget_view.rs`.  Returns `Err(())` on overflow/underflow
    /// (the impl halts the batch; the model rejects so the test
    /// generators can avoid these cases).
    fn apply(&mut self, event: &Event) -> Result<(), ()> {
        match event {
            Event::DepositWithFeeCredited {
                resource,
                recipient,
                pool_actor,
                pool_amount,
                budget_grant,
                ..
            } => {
                self.credit_grant(*recipient, *budget_grant)?;
                self.credit_pool(*resource, *pool_actor, *pool_amount)?;
            }
            Event::ActionBudgetTopUp {
                signer,
                gas_resource,
                gas_amount,
                budget_increment,
                pool_actor,
            } => {
                self.credit_grant(*signer, *budget_increment)?;
                self.credit_pool(*gas_resource, *pool_actor, *gas_amount)?;
            }
            Event::DelegatedActionBudgetTopUp {
                recipient,
                gas_resource,
                gas_amount,
                budget_increment,
                pool_actor,
                ..
            } => {
                self.credit_grant(*recipient, *budget_increment)?;
                self.credit_pool(*gas_resource, *pool_actor, *gas_amount)?;
            }
            Event::GasPoolClaim {
                resource, amount, ..
            } => {
                if let Some(p) = self.gas_pool_actor {
                    self.debit_pool(*resource, p, *amount)?;
                }
            }
            Event::BudgetConsumed { actor, amount } => {
                self.credit_consumed(*actor, *amount)?;
            }
            _ => {}
        }
        Ok(())
    }
}

// ---- Generators -----------------------------------------------------

/// A small actor universe so the property tests exercise
/// reusing the same actor across events.
fn actor_strategy() -> impl Strategy<Value = u64> {
    prop_oneof![Just(0u64), Just(1), Just(2), Just(42), Just(99)]
}

fn resource_strategy() -> impl Strategy<Value = u64> {
    prop_oneof![Just(RESOURCE_ID_ETH), Just(RESOURCE_ID_BOLD), Just(2u64)]
}

/// Bounded amount that won't overflow even after many credits.
fn amount_strategy() -> impl Strategy<Value = u128> {
    0u128..1_000_000
}

/// Generate a single GP-family event.
fn gp_event_strategy() -> impl Strategy<Value = Event> {
    prop_oneof![
        // tag 16
        (
            resource_strategy(),
            actor_strategy(),
            actor_strategy(),
            amount_strategy(),
            amount_strategy(),
            amount_strategy(),
            any::<u64>(),
        )
            .prop_map(|(r, recipient, pa, ua, pamt, bg, did)| {
                Event::DepositWithFeeCredited {
                    resource: r,
                    recipient,
                    pool_actor: pa,
                    user_amount: ua,
                    pool_amount: pamt,
                    budget_grant: bg,
                    deposit_id: did,
                }
            }),
        // tag 17
        (
            actor_strategy(),
            resource_strategy(),
            amount_strategy(),
            amount_strategy(),
            actor_strategy(),
        )
            .prop_map(|(s, gr, ga, bi, pa)| Event::ActionBudgetTopUp {
                signer: s,
                gas_resource: gr,
                gas_amount: ga,
                budget_increment: bi,
                pool_actor: pa,
            }),
        // tag 18 (no drain unless gas_pool_actor configured)
        (resource_strategy(), actor_strategy(), amount_strategy()).prop_map(|(r, seq, amt)| {
            Event::GasPoolClaim {
                resource: r,
                sequencer: seq,
                amount: amt,
            }
        }),
        // tag 19
        (
            actor_strategy(),
            actor_strategy(),
            resource_strategy(),
            amount_strategy(),
            amount_strategy(),
            actor_strategy(),
        )
            .prop_map(|(rec, signer, gr, ga, bi, pa)| {
                Event::DelegatedActionBudgetTopUp {
                    recipient: rec,
                    signer,
                    gas_resource: gr,
                    gas_amount: ga,
                    budget_increment: bi,
                    pool_actor: pa,
                }
            }),
        // tag 20
        (actor_strategy(), amount_strategy()).prop_map(|(a, amt)| Event::BudgetConsumed {
            actor: a,
            amount: amt,
        }),
    ]
}

/// Generate a batch of (1..=20) GP-family events.
fn batch_strategy() -> impl Strategy<Value = Vec<Event>> {
    prop::collection::vec(gp_event_strategy(), 1..=20)
}

// ---- The property -------------------------------------------------

/// Apply a batch via the real indexer + the model; assert all
/// view cells match.
fn assert_model_matches(
    indexer: &mut Indexer<'_, SqliteStorage>,
    model: &mut Model,
    seq: u64,
    batch: Vec<Event>,
    storage: &SqliteStorage,
) -> Result<(), TestCaseError> {
    // Apply to indexer.  The indexer's apply_batch crosses
    // epochs (if any), then applies all events atomically.
    indexer
        .apply_batch(seq, &batch)
        .map_err(|e| TestCaseError::fail(format!("apply_batch failed: {e:?}")))?;
    // Apply to model.  Same ordering: epoch cross first, then
    // events.
    model.cross_epoch_if_needed(seq);
    for e in &batch {
        model
            .apply(e)
            .map_err(|()| TestCaseError::reject("model rejected (overflow/underflow)"))?;
    }
    // Now check every cell mentioned by an event in this batch
    // matches.
    let view = BudgetReadView::new(storage);
    let mut actors_to_check: Vec<u64> = batch
        .iter()
        .filter_map(|e| e.actor())
        .chain(batch.iter().filter_map(|e| match e {
            Event::DepositWithFeeCredited { pool_actor, .. }
            | Event::ActionBudgetTopUp { pool_actor, .. }
            | Event::DelegatedActionBudgetTopUp { pool_actor, .. } => Some(*pool_actor),
            _ => None,
        }))
        .collect();
    actors_to_check.sort_unstable();
    actors_to_check.dedup();
    for actor in actors_to_check {
        // actor_budgets (lifetime)
        let want = model.actor_budgets.get(&actor).copied().unwrap_or(0);
        let got = view
            .get_actor_budget(actor)
            .map_err(|e| TestCaseError::fail(format!("get_actor_budget: {e:?}")))?;
        prop_assert_eq!(want, got, "actor_budgets[{}]", actor);
        // current-epoch grants
        let want = model.cur_grants.get(&actor).copied().unwrap_or(0);
        let got = view
            .get_actor_budget_current_epoch_grants(actor)
            .map_err(|e| TestCaseError::fail(format!("current_epoch_grants: {e:?}")))?;
        prop_assert_eq!(want, got, "current_epoch_grants[{}]", actor);
        // current-epoch consumed
        let want = model.cur_consumed.get(&actor).copied().unwrap_or(0);
        let got = view
            .get_actor_budget_current_epoch_consumed(actor)
            .map_err(|e| TestCaseError::fail(format!("current_epoch_consumed: {e:?}")))?;
        prop_assert_eq!(want, got, "current_epoch_consumed[{}]", actor);
        // pool eth
        let want = model.pool_eth.get(&actor).copied().unwrap_or(0);
        let got = view
            .get_pool_eth(actor)
            .map_err(|e| TestCaseError::fail(format!("pool_eth: {e:?}")))?;
        prop_assert_eq!(want, got, "pool_eth[{}]", actor);
        // pool bold
        let want = model.pool_bold.get(&actor).copied().unwrap_or(0);
        let got = view
            .get_pool_bold(actor)
            .map_err(|e| TestCaseError::fail(format!("pool_bold: {e:?}")))?;
        prop_assert_eq!(want, got, "pool_bold[{}]", actor);
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 64,
        max_shrink_iters: 200,
        .. ProptestConfig::default()
    })]

    /// Single-batch property: every (actor, table) cell matches
    /// the reference model.  No GasPoolClaim wiring; no epoch
    /// advancement.
    #[test]
    fn single_batch_matches_model_no_drain_no_epoch(
        batch in batch_strategy(),
    ) {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        let mut model = Model::new(None, 0);
        assert_model_matches(&mut ix, &mut model, 1, batch, &s)?;
    }

    /// Multi-batch property: sequence of 1..=5 batches, each at
    /// strictly-increasing seq.  No drain wiring; no epoch
    /// advancement.
    #[test]
    fn multi_batch_matches_model_no_drain_no_epoch(
        batches in prop::collection::vec(batch_strategy(), 1..=5),
    ) {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open(&s).unwrap();
        let mut model = Model::new(None, 0);
        for (i, batch) in batches.into_iter().enumerate() {
            let seq = (i as u64) + 1;
            assert_model_matches(&mut ix, &mut model, seq, batch, &s)?;
        }
    }

    /// Drain-wired property: `--gas-pool-actor = 1`, sequence of
    /// 1..=5 batches at strictly-increasing seq.  GasPoolClaim
    /// events with `resource ∈ {0, 1}` decrement
    /// `pool_balances_{eth,bold}[1]`.
    ///
    /// The generator's amount_strategy bounds amounts so cumulative
    /// drain shouldn't underflow within the test's batch limit;
    /// rare hits use `proptest::test_runner` rejection.
    #[test]
    fn multi_batch_matches_model_with_drain(
        batches in prop::collection::vec(batch_strategy(), 1..=5),
    ) {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open_with_config(&s, Some(1), 0).unwrap();
        let mut model = Model::new(Some(1), 0);
        for (i, batch) in batches.into_iter().enumerate() {
            let seq = (i as u64) + 1;
            // Drain underflow: skip the test case.
            if let Err(e) = ix.apply_batch(seq, &batch) {
                match e {
                    knomosis_indexer::indexer::IndexerError::BudgetView(_) => {
                        // The indexer halted on underflow; reject.
                        return Err(TestCaseError::reject("drain underflow"));
                    }
                    _ => return Err(TestCaseError::fail(format!("unexpected: {e:?}"))),
                }
            }
            model.cross_epoch_if_needed(seq);
            for ev in &batch {
                if model.apply(ev).is_err() {
                    return Err(TestCaseError::reject("model underflow"));
                }
            }
            // Spot-check the pool actor (id 1) for both legs.
            let view = BudgetReadView::new(&s);
            let want_eth = model.pool_eth.get(&1).copied().unwrap_or(0);
            let got_eth = view.get_pool_eth(1).unwrap();
            prop_assert_eq!(want_eth, got_eth, "pool_eth[1]");
            let want_bold = model.pool_bold.get(&1).copied().unwrap_or(0);
            let got_bold = view.get_pool_bold(1).unwrap();
            prop_assert_eq!(want_bold, got_bold, "pool_bold[1]");
        }
    }

    /// Epoch-advancement property: `--epoch-length = 10`,
    /// applied across multiple epochs.  Lifetime tables
    /// accumulate; per-epoch tables reset.
    #[test]
    fn epoch_advancement_matches_model(
        batches in prop::collection::vec(batch_strategy(), 1..=5),
    ) {
        let s = SqliteStorage::open_in_memory().unwrap();
        let mut ix = Indexer::open_with_config(&s, None, 10).unwrap();
        let mut model = Model::new(None, 10);
        // Seqs: 1, 12, 23, 34, 45 (each in a different epoch).
        for (i, batch) in batches.into_iter().enumerate() {
            let seq = 1 + (i as u64) * 11;
            assert_model_matches(&mut ix, &mut model, seq, batch, &s)?;
        }
    }
}
