-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.BudgetRefund — Workstream GP.9.1 test suite.

Exercises the refund-on-exit kernel leg (`LegalKernel/Laws/ClaimBudgetRefund.lean`)
and its accounting layer (`LegalKernel/Bridge/BudgetRefund.lean`).  Coverage:

  * **Refundable-budget functional.**  The free-tier-and-cost
    exclusion (`89 = 100 − (1 + 10)`), the at-free-tier zero, and the
    below-reserves zero (the anti-drain guarantee).
  * **Round-trip non-profitability.**  `refundAmount (poolAmount / rate)
    rate ≤ poolAmount` on a concrete indivisible split (the residue
    stays in the pool).
  * **Kernel leg.**  Pool debit + claimant credit + per-resource
    conservation + the insolvent-pool no-op + other-actor / other-
    resource non-interference.
  * **Budget ledger.**  A concrete refund consume leaving the claimant
    at exactly the free tier; the strict `currentBudget` decrease
    (no-double-refund); refund locality on a second actor.
  * **Law ↔ ledger composite.**  `refund_pays_exact_amount_from_pool`
    at the canonical `gasPoolActor`.
  * **Term-level API stability** for every headline theorem + the law /
    accounting functionals.
-/

import LegalKernel.Bridge.BudgetRefund
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge
namespace BudgetRefundTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Test

/-! ## Fixtures -/

/-- A regular (non-reserved) user actor — the refund claimant. -/
def claimant : ActorId := 5

/-- A second user actor, for the locality checks. -/
def other : ActorId := 6

/-- The ETH-mirror gas resource (resource 0). -/
def gasResource : ResourceId := 0

/-- A representative epoch and free tier / action cost. -/
def now : Nat := 0
/-- A representative per-epoch free-tier allowance. -/
def freeTier : Nat := 10
/-- The per-action budget cost. -/
def actionCost : Nat := 1

/-- A claimant budget ledger: 100 action-budget units at epoch 0. -/
def ledger : EpochBudgetState :=
  EpochBudgetState.empty.topUp claimant now 0 100

/-- A state in which the gas pool holds 5000 ETH and the claimant 100. -/
def fundedPool : State :=
  setBalance (setBalance genesisState gasResource gasPoolActor 5000) gasResource claimant 100

/-- A state in which the gas pool is underfunded (holds only 100). -/
def emptyPool : State :=
  setBalance (setBalance genesisState gasResource gasPoolActor 100) gasResource claimant 50

/-! ## Tests -/

/-- GP.9.1 test cases. -/
def tests : List TestCase :=
  [ -- ## Refundable-budget functional (free-tier + cost exclusion)
    { name := "refundableBudget excludes the free tier and the action cost"
    , body := do
        -- currentBudget = 100; reserves = actionCost (1) + freeTier (10) = 11.
        assertEq (expected := (100 : Nat))
          (actual := ledger.currentBudget claimant now freeTier) "currentBudget"
        assertEq (expected := (89 : Nat))
          (actual := refundableBudget ledger claimant now freeTier actionCost)
          "refundableBudget = 100 - 11"
    }
  , { name := "refundableBudget is zero at the free tier (anti-drain)"
    , body := do
        -- An actor sitting at exactly the free tier has nothing
        -- purchased to refund: free-tier subsidy never leaks.
        let atFree : EpochBudgetState := EpochBudgetState.empty.topUp claimant now 0 10
        assertEq (expected := (10 : Nat))
          (actual := atFree.currentBudget claimant now freeTier) "at free tier"
        assertEq (expected := (0 : Nat))
          (actual := refundableBudget atFree claimant now freeTier actionCost)
          "refundableBudget = 0 at free tier"
    }
  , { name := "refundableBudget is zero below the reserves"
    , body := do
        let belowReserves : EpochBudgetState := EpochBudgetState.empty.topUp claimant now 0 5
        assertEq (expected := (0 : Nat))
          (actual := refundableBudget belowReserves claimant now freeTier actionCost)
          "refundableBudget = 0 below reserves"
    }
  , -- ## Round-trip non-profitability (floor division)
    { name := "refundAmount of a deposit grant never exceeds the fee"
    , body := do
        -- A deposit of poolAmount = 1_000_000 at rate 7 grants
        -- 1_000_000 / 7 = 142_857 budget units.  Refunding all of them
        -- pays 142_857 * 7 = 999_999 ≤ 1_000_000 — the residue (1) stays
        -- in the pool, so the round trip is strictly lossy.
        let poolAmount : Nat := 1000000
        let rate : Nat := 7
        let grant := poolAmount / rate
        assertEq (expected := (142857 : Nat)) (actual := grant) "floor-division grant"
        assertEq (expected := (999999 : Nat)) (actual := refundAmount grant rate)
          "refundAmount of the grant"
        assert (decide (refundAmount grant rate ≤ poolAmount)) "refund ≤ fee paid"
    }
  , -- ## Kernel leg: balance deltas + conservation
    { name := "refund credits the claimant and debits the pool by refundAmount"
    , body := do
        let s' := step_impl fundedPool (Laws.claimBudgetRefund claimant gasPoolActor gasResource 300)
        assertEq (expected := (400 : Nat)) (actual := getBalance s' gasResource claimant)
          "claimant credited 100 + 300"
        assertEq (expected := (4700 : Nat)) (actual := getBalance s' gasResource gasPoolActor)
          "pool debited 5000 - 300"
    }
  , { name := "refund conserves per-resource total supply"
    , body := do
        let s' := step_impl fundedPool (Laws.claimBudgetRefund claimant gasPoolActor gasResource 300)
        assertEq (expected := TotalSupply fundedPool gasResource)
          (actual := TotalSupply s' gasResource) "supply conserved"
    }
  , { name := "refund against an insolvent pool is a no-op"
    , body := do
        -- Pool holds only 100; a 300-unit refund fails the precondition,
        -- so `step_impl` leaves the state untouched (no silent under-credit).
        let s' := step_impl emptyPool (Laws.claimBudgetRefund claimant gasPoolActor gasResource 300)
        assertEq (expected := getBalance emptyPool gasResource claimant)
          (actual := getBalance s' gasResource claimant) "claimant unchanged"
        assertEq (expected := getBalance emptyPool gasResource gasPoolActor)
          (actual := getBalance s' gasResource gasPoolActor) "pool unchanged"
    }
  , { name := "refund leaves other actors and other resources untouched"
    , body := do
        let s := setBalance fundedPool gasResource other 777
        let s2 := setBalance s 1 claimant 999  -- a BOLD-leg balance
        let s' := step_impl s2 (Laws.claimBudgetRefund claimant gasPoolActor gasResource 300)
        assertEq (expected := (777 : Nat)) (actual := getBalance s' gasResource other)
          "other actor untouched"
        assertEq (expected := (999 : Nat)) (actual := getBalance s' 1 claimant)
          "other resource untouched"
    }
  , -- ## Budget ledger: post-refund state
    { name := "a refund consume leaves the claimant at exactly the free tier"
    , body := do
        -- budgetUnits = 89 = refundableBudget; consume 1 + 89 = 90 from 100
        -- leaves 10 = freeTier.
        match EpochBudgetState.consume ledger claimant now freeTier (actionCost + 89) with
        | some ebs' =>
            assertEq (expected := (10 : Nat))
              (actual := ebs'.currentBudget claimant now freeTier)
              "post-refund budget = free tier"
        | none => assert false "refund consume should succeed"
    }
  , { name := "a refund strictly lowers the claimant budget (no double refund)"
    , body := do
        match EpochBudgetState.consume ledger claimant now freeTier (actionCost + 89) with
        | some ebs' =>
            assert (decide (ebs'.currentBudget claimant now freeTier <
              ledger.currentBudget claimant now freeTier)) "budget strictly decreased"
        | none => assert false "refund consume should succeed"
    }
  , { name := "a refund consume leaves another actor's budget untouched"
    , body := do
        let ledger2 := ledger.topUp other now 0 50
        match EpochBudgetState.consume ledger2 claimant now freeTier (actionCost + 89) with
        | some ebs' =>
            assertEq (expected := ledger2.currentBudget other now freeTier)
              (actual := ebs'.currentBudget other now freeTier) "other budget untouched"
        | none => assert false "refund consume should succeed"
    }
  , -- ## Term-level API stability
    { name := "GP.9.1: term-level API stability (law + accounting)"
    , body := do
        -- Kernel leg.
        let _l0 := @Laws.claimBudgetRefund
        let _l1 := @Laws.claimBudgetRefund_apply_eq_transfer
        let _l2 := @Laws.claimBudgetRefund_conserves
        let _l3 := @Laws.claimBudgetRefund_other_resource_untouched
        let _l4 := @Laws.claimBudgetRefund_does_not_touch_other_resources
        let _l5 := @Laws.claimBudgetRefund_conserves_other_resource
        let _l6 := @Laws.claimBudgetRefund_pool_debited
        let _l7 := @Laws.claimBudgetRefund_claimant_credited
        let _l8 := @Laws.claimBudgetRefund_other_actor_untouched
        let _l9 := @Laws.claimBudgetRefund_isConservative
        let _l10 := @Laws.claimBudgetRefund_isMonotonic
        let _l11 := @Laws.claimBudgetRefund_localTo
        let _l12 := @Laws.claimBudgetRefund_freezePreserving
        -- Accounting layer.
        let _a0 := @refundableBudget
        let _a1 := @refundAmount
        let _a2 := @refundableBudget_le_currentBudget
        let _a3 := @refundableBudget_eq_zero_of_le_reserves
        let _a4 := @refundableBudget_eq_zero_at_free_tier
        let _a5 := @sufficient_of_refundableBudget_pos
        let _a6 := @refund_consume_succeeds
        let _a7 := @currentBudget_after_refund_consume
        let _a8 := @currentBudget_after_refund_ge_free_tier
        let _a9 := @currentBudget_after_refund_lt
        let _a10 := @currentBudget_after_refund_other
        let _a11 := @refundAmount_le_of_budgetUnits_le
        let _a12 := @refundAmount_le_deposit_fee
        let _a13 := @refundAmount_le_max
        let _a14 := @refund_pre_iff_pool_solvent
        let _a15 := @refund_pays_exact_amount_from_pool
        let _a16 := @refund_conserves_supply
        let _a17 := @refund_other_actor_untouched
        pure ()
    }
  ]

end BudgetRefundTests
end LegalKernel.Test.Bridge
