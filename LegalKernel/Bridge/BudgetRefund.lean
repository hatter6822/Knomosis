-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.BudgetRefund — Workstream GP.9.1 refund accounting.

The accounting layer that makes the GP.9.1 budget refund (the
`LegalKernel/Laws/ClaimBudgetRefund.lean` kernel leg) provably SAFE.
A refund lets a `claimant` (the signer) convert `budgetUnits` of their
*own remaining, purchased* action budget back into `refundAmount =
budgetUnits × weiPerBudgetUnit` units of a gas resource, paid out of
the gas pool (`gasPoolActor`, GP.7.1).

The whole point of refunding "exactly the remaining action budget"
(rather than the v1 sketch's `poolAmount × time-decay`) is that the
per-actor budget ledger ALREADY tracks each actor's remaining budget
(`EpochBudgetState.currentBudget`) — so there is no per-deposit
state-bloat, and the refund is computed from a quantity the kernel
already maintains.

This module pins the four properties that make the refund sound,
WITHOUT yet touching the frozen `Action` set or the §13.6-sensitive
admission gate (the signable-action wiring — a new `Action`
constructor, the admission-gate refund arm, and the cross-stack
CBE / step-VM / Solidity / Rust mirrors — is the GP.9.1 landing
scoped in `docs/planning/unified_gas_pool_plan.md` §GP.9.1):

  1. **Free-tier immunity (anti-drain).**  `refundableBudget`
     subtracts BOTH the per-action cost AND the free tier from
     `currentBudget`, so the free-tier subsidy is NEVER refundable.
     An actor sitting at (or below) the free tier has
     `refundableBudget = 0` (`refundableBudget_eq_zero_of_le_reserves`).
     Without this, every actor could drain `freeTier × rate` of real
     gas per epoch out of the pool — a catastrophic free-money leak.

  2. **Round-trip non-profitability.**  Refunding the budget a
     deposit granted pays back AT MOST the fee that funded it:
     `refundAmount (poolAmount / rate) rate ≤ poolAmount`
     (`refundAmount_le_deposit_fee`, by floor division).  The
     floor-division residue stays in the pool, so a deposit→refund
     cycle is never profitable (and the per-action cost of the refund
     itself makes it strictly lossy).

  3. **No double refund.**  A successful refund consumes
     `actionCost + budgetUnits` from the ledger, strictly lowering
     `currentBudget` (`currentBudget_after_refund_lt`), so the same
     budget can never be refunded twice.

  4. **Free tier preserved across the refund.**  Bounding
     `budgetUnits ≤ refundableBudget` guarantees the post-refund
     budget stays at or above the free tier
     (`currentBudget_after_refund_ge_free_tier`), so a refund never
     dips into the next epoch's free allowance.

Pool solvency (the precondition of the kernel leg,
`getBalance gasPoolActor ≥ refundAmount`) and victim-balance safety
(the `poolActor = gasPoolActor` pin) are handled by the kernel leg's
precondition and the admission gate respectively; the per-action
pieces are recorded here, the inductive cross-trace solvency bound is
the GP.7.3-style accounting track.

This module is **not** part of the kernel TCB: a bug here would weaken
a deployment-level refund-discipline claim but cannot violate any
kernel invariant.
-/

import LegalKernel.Laws.ClaimBudgetRefund
import LegalKernel.Authority.ActorBudget
import LegalKernel.Bridge.BridgeActor
import LegalKernel.Conservation

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-! ## Refundable-budget and refund-amount functionals -/

/-- The action-budget an actor `a` may refund: the budget held
    *above* the free tier, after reserving this refund action's own
    per-action `actionCost`.

    Two reserves are subtracted from `currentBudget`:

    * `actionCost` — the refund action, like every action, costs the
      actor `actionCost` budget; that cost is not itself refundable.
    * `freeTier` — the per-epoch free allowance is a subsidy, NOT
      purchased budget, so it can never be converted into gas.  This
      subtraction is the anti-drain guarantee
      (`refundableBudget_eq_zero_of_le_reserves`).

    `Nat` truncated subtraction makes the functional `0` whenever the
    actor's budget does not exceed the two reserves — exactly the
    "nothing purchased to refund" regime. -/
def refundableBudget (ebs : EpochBudgetState) (a : ActorId)
    (now freeTier actionCost : Nat) : Nat :=
  EpochBudgetState.currentBudget ebs a now freeTier - (actionCost + freeTier)

/-- The gas-resource amount paid out for refunding `budgetUnits`
    action-budget units at the deployment's trusted exchange rate
    `weiPerBudgetUnit`.  The rate is a deployment constant verified by
    the admission gate (NOT a free user field), so a refund cannot
    inflate its own payout. -/
def refundAmount (budgetUnits weiPerBudgetUnit : Nat) : Nat :=
  budgetUnits * weiPerBudgetUnit

/-! ## Free-tier immunity (the anti-drain guarantee) -/

/-- `refundableBudget` never exceeds the actor's `currentBudget`:
    truncated subtraction can only shrink it. -/
theorem refundableBudget_le_currentBudget
    (ebs : EpochBudgetState) (a : ActorId) (now freeTier actionCost : Nat) :
    refundableBudget ebs a now freeTier actionCost ≤
      EpochBudgetState.currentBudget ebs a now freeTier := by
  unfold refundableBudget
  omega

/-- **Free-tier immunity.**  An actor whose `currentBudget` does not
    exceed the reserves (`actionCost + freeTier`) has nothing
    refundable.  In particular, an actor sitting at exactly the free
    tier cannot convert any of it into gas — the headline anti-drain
    property: the free subsidy never leaks out of the pool. -/
theorem refundableBudget_eq_zero_of_le_reserves
    (ebs : EpochBudgetState) (a : ActorId) (now freeTier actionCost : Nat)
    (h : EpochBudgetState.currentBudget ebs a now freeTier ≤ actionCost + freeTier) :
    refundableBudget ebs a now freeTier actionCost = 0 := by
  unfold refundableBudget
  omega

/-- An actor sitting at or below the free tier has zero refundable
    budget (a corollary of `refundableBudget_eq_zero_of_le_reserves`:
    `currentBudget ≤ freeTier ≤ actionCost + freeTier`). -/
theorem refundableBudget_eq_zero_at_free_tier
    (ebs : EpochBudgetState) (a : ActorId) (now freeTier actionCost : Nat)
    (h : EpochBudgetState.currentBudget ebs a now freeTier ≤ freeTier) :
    refundableBudget ebs a now freeTier actionCost = 0 := by
  unfold refundableBudget
  omega

/-- A positive `refundableBudget` certifies the actor has strictly
    more budget than the two reserves — the sufficiency fact the
    consume step needs. -/
theorem sufficient_of_refundableBudget_pos
    (ebs : EpochBudgetState) (a : ActorId) (now freeTier actionCost : Nat)
    (h : 0 < refundableBudget ebs a now freeTier actionCost) :
    actionCost + freeTier ≤ EpochBudgetState.currentBudget ebs a now freeTier := by
  unfold refundableBudget at h
  omega

/-! ## The refund consume (`actionCost + budgetUnits`)

A refund action consumes `actionCost + budgetUnits` budget in one
step: the standard per-action cost PLUS the retired units.  The
lemmas below characterise that consume's success and post-state, all
in terms of the existing `EpochBudgetState` ledger lemmas. -/

/-- A refund of `budgetUnits ≥ 1` within the refundable bound always
    consumes successfully: `actionCost + budgetUnits` fits within the
    actor's `currentBudget`.  (`budgetUnits ≥ 1` rules out the
    truncation corner where `refundableBudget = 0` but the actor
    cannot even afford `actionCost`.) -/
theorem refund_consume_succeeds
    (ebs : EpochBudgetState) (a : ActorId) (now freeTier actionCost budgetUnits : Nat)
    (hpos : 1 ≤ budgetUnits)
    (hb : budgetUnits ≤ refundableBudget ebs a now freeTier actionCost) :
    ∃ ebs', EpochBudgetState.consume ebs a now freeTier (actionCost + budgetUnits) = some ebs' := by
  apply EpochBudgetState.consume_succeeds_when_sufficient
  unfold refundableBudget at hb
  omega

/-- After a successful refund consume, the claimant's `currentBudget`
    drops by exactly `actionCost + budgetUnits`.  Direct corollary of
    `EpochBudgetState.currentBudget_after_consume_self`. -/
theorem currentBudget_after_refund_consume
    (ebs : EpochBudgetState) (a : ActorId) (now freeTier actionCost budgetUnits : Nat)
    (ebs' : EpochBudgetState)
    (h : EpochBudgetState.consume ebs a now freeTier (actionCost + budgetUnits) = some ebs') :
    EpochBudgetState.currentBudget ebs' a now freeTier =
      EpochBudgetState.currentBudget ebs a now freeTier - (actionCost + budgetUnits) :=
  EpochBudgetState.currentBudget_after_consume_self ebs a now freeTier
    (actionCost + budgetUnits) ebs' h

/-- **Free tier preserved.**  Bounding `budgetUnits ≤ refundableBudget`
    (with `budgetUnits ≥ 1`) guarantees the post-refund budget stays at
    or above the free tier — the refund retires only purchased budget,
    never the per-epoch subsidy.  Together with free-tier immunity,
    this is why a refund cannot leak the free allowance. -/
theorem currentBudget_after_refund_ge_free_tier
    (ebs : EpochBudgetState) (a : ActorId) (now freeTier actionCost budgetUnits : Nat)
    (ebs' : EpochBudgetState)
    (hpos : 1 ≤ budgetUnits)
    (hb : budgetUnits ≤ refundableBudget ebs a now freeTier actionCost)
    (h : EpochBudgetState.consume ebs a now freeTier (actionCost + budgetUnits) = some ebs') :
    freeTier ≤ EpochBudgetState.currentBudget ebs' a now freeTier := by
  rw [currentBudget_after_refund_consume ebs a now freeTier actionCost budgetUnits ebs' h]
  unfold refundableBudget at hb
  omega

/-- **No double refund.**  A successful refund of `budgetUnits ≥ 1`
    strictly lowers the claimant's `currentBudget`, so the same budget
    can never be refunded a second time.  Uses
    `EpochBudgetState.consume_eq_none_iff` to recover the
    `actionCost + budgetUnits ≤ currentBudget` bound from the
    consume's success. -/
theorem currentBudget_after_refund_lt
    (ebs : EpochBudgetState) (a : ActorId) (now freeTier actionCost budgetUnits : Nat)
    (ebs' : EpochBudgetState)
    (hpos : 1 ≤ budgetUnits)
    (h : EpochBudgetState.consume ebs a now freeTier (actionCost + budgetUnits) = some ebs') :
    EpochBudgetState.currentBudget ebs' a now freeTier <
      EpochBudgetState.currentBudget ebs a now freeTier := by
  rw [currentBudget_after_refund_consume ebs a now freeTier actionCost budgetUnits ebs' h]
  have hle : actionCost + budgetUnits ≤ EpochBudgetState.currentBudget ebs a now freeTier := by
    apply Nat.not_lt.mp
    intro hlt
    have hnone := (EpochBudgetState.consume_eq_none_iff ebs a now freeTier
      (actionCost + budgetUnits)).mpr hlt
    rw [hnone] at h
    simp at h
  omega

/-- **Refund locality.**  A refund consume against actor `a` leaves
    every other actor's `currentBudget` unchanged — the ledger
    mutation is scoped to the claimant. -/
theorem currentBudget_after_refund_other
    (ebs : EpochBudgetState) (a a' : ActorId) (now freeTier actionCost budgetUnits : Nat)
    (ebs' : EpochBudgetState)
    (h : EpochBudgetState.consume ebs a now freeTier (actionCost + budgetUnits) = some ebs')
    (hne : a ≠ a') :
    EpochBudgetState.currentBudget ebs' a' now freeTier =
      EpochBudgetState.currentBudget ebs a' now freeTier :=
  EpochBudgetState.currentBudget_after_consume_other ebs a a' now freeTier
    (actionCost + budgetUnits) ebs' h hne

/-! ## Round-trip non-profitability -/

/-- `refundAmount` is monotone in the refunded units (fixed rate). -/
theorem refundAmount_le_of_budgetUnits_le
    (budgetUnits budgetUnits' weiPerBudgetUnit : Nat) (h : budgetUnits ≤ budgetUnits') :
    refundAmount budgetUnits weiPerBudgetUnit ≤ refundAmount budgetUnits' weiPerBudgetUnit := by
  unfold refundAmount
  exact Nat.mul_le_mul_right weiPerBudgetUnit h

/-- **Round-trip non-profitability.**  Refunding the budget a deposit
    granted (`poolAmount / weiPerBudgetUnit`, the same floor-division
    grant `KnomosisBridge` / `Laws.depositWithFee` use) pays back AT
    MOST the `poolAmount` fee that funded it.  The floor-division
    residue stays in the pool, so a deposit→refund cycle is never
    profitable; adding the per-action cost of the refund itself makes
    it strictly lossy.  This is the core economic-soundness guarantee:
    a refund cannot extract more gas than was paid in. -/
theorem refundAmount_le_deposit_fee (poolAmount weiPerBudgetUnit : Nat) :
    refundAmount (poolAmount / weiPerBudgetUnit) weiPerBudgetUnit ≤ poolAmount := by
  unfold refundAmount
  exact Nat.div_mul_le_self poolAmount weiPerBudgetUnit

/-- The most an actor can ever be paid in one refund: `refundableBudget
    × rate`.  Any admissible `budgetUnits ≤ refundableBudget` yields a
    payout within this cap (`refundAmount` monotone in the units). -/
theorem refundAmount_le_max
    (ebs : EpochBudgetState) (a : ActorId) (now freeTier actionCost : Nat)
    (budgetUnits weiPerBudgetUnit : Nat)
    (hb : budgetUnits ≤ refundableBudget ebs a now freeTier actionCost) :
    refundAmount budgetUnits weiPerBudgetUnit ≤
      refundAmount (refundableBudget ebs a now freeTier actionCost) weiPerBudgetUnit :=
  refundAmount_le_of_budgetUnits_le budgetUnits _ weiPerBudgetUnit hb

/-! ## Pool solvency (the kernel-leg precondition) -/

/-- The refund kernel leg's precondition IS exactly the pool-solvency
    check: the pool must hold at least `refundAmount`.  A refund
    against an under-funded pool is rejected (a no-op via `step_impl`),
    so the pool can never be over-drawn. -/
theorem refund_pre_iff_pool_solvent
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmt : Amount) (s : State) :
    (Laws.claimBudgetRefund claimant poolActor gasResource refundAmt).pre s ↔
      refundAmt ≤ getBalance s gasResource poolActor :=
  Iff.rfl

/-! ## Law ↔ ledger composite (the headline GP.9.1 safety theorems)

The theorems below combine the kernel leg (`Laws.claimBudgetRefund`)
with the canonical gas-pool actor (`gasPoolActor`, GP.7.1).  They
state the end-to-end effect a successful refund has: the claimant is
paid exactly `refundAmount budgetUnits rate` out of the pool, total
supply is conserved, and (with the budget bound) the claimant's
ledger stays at or above the free tier. -/

/-- **The refund pays exactly the computed amount.**  Applying the
    refund kernel leg at the canonical `gasPoolActor`, for a real user
    `claimant ≠ gasPoolActor` and a solvent pool, credits the claimant
    exactly `refundAmount budgetUnits weiPerBudgetUnit` and debits the
    pool by exactly the same amount.  No over-credit, no over-draw. -/
theorem refund_pays_exact_amount_from_pool
    (claimant : ActorId) (gasResource : ResourceId)
    (budgetUnits weiPerBudgetUnit : Nat) (s : State)
    (hne : claimant ≠ gasPoolActor)
    (hpre : (Laws.claimBudgetRefund claimant gasPoolActor gasResource
              (refundAmount budgetUnits weiPerBudgetUnit)).pre s) :
    getBalance (step_impl s (Laws.claimBudgetRefund claimant gasPoolActor gasResource
        (refundAmount budgetUnits weiPerBudgetUnit))) gasResource claimant =
      getBalance s gasResource claimant + refundAmount budgetUnits weiPerBudgetUnit ∧
    getBalance (step_impl s (Laws.claimBudgetRefund claimant gasPoolActor gasResource
        (refundAmount budgetUnits weiPerBudgetUnit))) gasResource gasPoolActor =
      getBalance s gasResource gasPoolActor - refundAmount budgetUnits weiPerBudgetUnit := by
  refine ⟨?_, ?_⟩
  · exact Laws.claimBudgetRefund_claimant_credited claimant gasPoolActor gasResource
      (refundAmount budgetUnits weiPerBudgetUnit) s hpre hne
  · exact Laws.claimBudgetRefund_pool_debited claimant gasPoolActor gasResource
      (refundAmount budgetUnits weiPerBudgetUnit) s hpre (Ne.symm hne)

/-- **The refund conserves total supply** at every resource.  Direct
    lift of the kernel leg's `IsConservative` instance: a refund moves
    gas from the pool to the claimant, it never mints or burns. -/
theorem refund_conserves_supply
    (claimant poolActor : ActorId) (gasResource r : ResourceId)
    (refundAmt : Amount) (s : State)
    (hpre : (Laws.claimBudgetRefund claimant poolActor gasResource refundAmt).pre s) :
    TotalSupply (step_impl s (Laws.claimBudgetRefund claimant poolActor gasResource
        refundAmt)) r =
      TotalSupply s r :=
  (Laws.claimBudgetRefund_isConservative claimant poolActor gasResource refundAmt).conserves
    r s hpre

/-- A refund at the canonical pool leaves every actor other than the
    claimant and `gasPoolActor` untouched at the gas resource. -/
theorem refund_other_actor_untouched
    (claimant other : ActorId) (gasResource : ResourceId)
    (refundAmt : Amount) (s : State)
    (hpre : (Laws.claimBudgetRefund claimant gasPoolActor gasResource refundAmt).pre s)
    (hne_claimant : other ≠ claimant) (hne_pool : other ≠ gasPoolActor) :
    getBalance (step_impl s (Laws.claimBudgetRefund claimant gasPoolActor gasResource
        refundAmt)) gasResource other =
      getBalance s gasResource other :=
  Laws.claimBudgetRefund_other_actor_untouched claimant gasPoolActor gasResource
    refundAmt other s hpre hne_claimant hne_pool

end Bridge
end LegalKernel
