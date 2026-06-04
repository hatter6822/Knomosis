-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Laws.ClaimBudgetRefund — the GP.9.1 refund-on-exit law.

Workstream GP / WU GP.9.1 (refund-on-exit, redesigned to refund the
claimant's *remaining action budget*).  The kernel-level leg of a
user-initiated budget refund: a `claimant` (the signer) converts
`budgetUnits` of their own remaining, purchased action-budget back
into `refundAmount` units of `gasResource`, paid out of the
`poolActor`'s (canonically `gasPoolActor`, GP.7.1 / `ActorId 1`)
balance.

Kernel-state effect.  Identical in shape to `Laws.transfer
gasResource poolActor claimant refundAmount` (and so to
`Laws.topUpActionBudget` / `Laws.topUpActionBudgetFor` modulo the
debit / credit roles): debit the `poolActor`, then credit the
`claimant`, reading the claimant's balance from the post-debit
intermediate state so the (degenerate) `poolActor = claimant` corner
still conserves total supply.

This law is deliberately the MIRROR of `topUpActionBudget`: a top-up
moves `claimant → poolActor` (the user pays gas to buy budget); a
refund moves `poolActor → claimant` (the pool pays gas to retire
budget).  The amount and budget-side accounting that make the refund
SAFE — the `refundAmount = budgetUnits × weiPerBudgetUnit` exchange
rate, the per-claimant `budgetUnits ≤ refundableBudget` bound that
excludes the free tier, the atomic budget consumption that prevents a
double refund, and the `poolActor = gasPoolActor` pin that prevents a
victim-balance drain — all live in `LegalKernel/Bridge/BudgetRefund.lean`
(the accounting layer) and the admission gate; they are NOT part of
this kernel leg, exactly as the budget *grant* of `topUpActionBudget`
lives in the admission gate rather than in `Laws.topUpActionBudget`.

`refundAmount` is taken as a single scalar parameter: the admission
layer computes it as `budgetUnits × weiPerBudgetUnit` from the
action's (rate-verified) fields and threads it through
`Action.toTransition` with `claimant := signer`, so the kernel leg
itself never divides or multiplies — it just moves an amount the
pool can afford.

Precondition.  `getBalance s gasResource poolActor ≥ refundAmount` —
the pool can afford the payout.  When the pool is short, `step_impl`
makes the law a no-op (no silent under-credit), and the admission
gate rejects the action earlier so the no-op branch is reachable
only by callers below the gate.  There is no positivity clause: a
`refundAmount = 0` refund is a harmless no-op (the admission gate
rejects pointless zero-unit refunds upstream).

This module is **not** part of the trusted computing base: bugs here
are scoped to one deployment-facing law, never a kernel invariant.

Conservation / classification.  Because the kernel-state effect is a
debit-then-credit transfer, the law inherits the full §4.11 ladder:
per-resource conservation, cross-resource locality, monotonicity,
`LocalTo [gasResource]`, and freeze-preservation for any resource set
excluding `gasResource`.  The proofs mirror `Laws/TopUpActionBudgetFor.lean`
verbatim (same debit-then-credit `apply_impl` shape), with the
poolActor in the debited role and the claimant in the credited role.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Laws.Transfer

namespace LegalKernel
namespace Laws

/-- GP.9.1 budget refund — kernel leg.

    `claimant` (the signer) retires `budgetUnits` of their own
    remaining action-budget; the admission layer credits them
    `refundAmount` units of `gasResource`, paid out of `poolActor`.

    * Precondition: the pool holds at least `refundAmount`
      (`getBalance s gasResource poolActor ≥ refundAmount`).
    * Effect: debit `poolActor`, then credit `claimant`, reading the
      claimant's balance from the post-debit intermediate state (so
      the degenerate `poolActor = claimant` corner conserves supply).

    `decPre` is inferred: the precondition is a single decidable
    `Nat` comparison. -/
def claimBudgetRefund (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount) : Transition where
  pre := fun s => getBalance s gasResource poolActor ≥ refundAmount
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let s1 := setBalance s gasResource poolActor
      (getBalance s gasResource poolActor - refundAmount)
    setBalance s1 gasResource claimant
      (getBalance s1 gasResource claimant + refundAmount)

/-- The refund kernel effect coincides with the debit-then-credit
    `transfer gasResource poolActor claimant refundAmount` effect at
    the `apply_impl` level.  Definitional (`rfl`): both unfold to the
    same two-`setBalance` chain (pool debited, then claimant credited
    reading the post-debit state).  The two transitions are NOT
    definitionally equal as `Transition`s — `transfer` carries an
    extra `amount > 0` positivity conjunct in its precondition that
    `claimBudgetRefund` omits — so this equation is stated at the
    `apply_impl` level only. -/
theorem claimBudgetRefund_apply_eq_transfer
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount) (s : State) :
    (claimBudgetRefund claimant poolActor gasResource refundAmount).apply_impl s =
    (transfer gasResource poolActor claimant refundAmount).apply_impl s := rfl

/-! ## Per-resource conservation (mirrors §4.11.1)

The argument is the §4.11 transfer argument verbatim: open `step_impl`
via the precondition, apply the master `setBalance`-on-`TotalSupply`
accounting lemma at each write, and discharge the resulting linear
system with `omega`.  Uniform over the (degenerate) `poolActor =
claimant` corner. -/

/-- Pure-arithmetic kernel of `claimBudgetRefund_conserves`.
    Identical shape to `Laws.transfer`'s `transfer_arithmetic`
    helper; lifted to plain `Nat` parameters so `omega`'s atom
    discovery sees clean variables rather than deeply-nested
    `TotalSupply (setBalance …)` terms. -/
private theorem refund_arithmetic
    (T0 T1 T2 B R1 amount : Nat)
    (h1   : T1 + B = T0 + (B - amount))
    (h2   : T2 + R1 = T1 + (R1 + amount))
    (hbal : amount ≤ B) :
    T2 = T0 := by
  omega

/-- `claimBudgetRefund` preserves per-resource total supply at the
    gas resource.  Holds in both the distinct-actor and
    `poolActor = claimant` cases (the post-debit re-read inside
    `apply_impl` makes the self case conserve). -/
theorem claimBudgetRefund_conserves
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount) (s : State)
    (hpre : (claimBudgetRefund claimant poolActor gasResource refundAmount).pre s) :
    TotalSupply (step_impl s (claimBudgetRefund claimant poolActor gasResource
                  refundAmount)) gasResource =
    TotalSupply s gasResource := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((claimBudgetRefund claimant poolActor gasResource
          refundAmount).apply_impl s) gasResource = TotalSupply s gasResource
  simp only [claimBudgetRefund]
  exact refund_arithmetic
    (TotalSupply s gasResource)
    (TotalSupply (setBalance s gasResource poolActor
      (getBalance s gasResource poolActor - refundAmount)) gasResource)
    (TotalSupply (setBalance
      (setBalance s gasResource poolActor (getBalance s gasResource poolActor - refundAmount))
      gasResource claimant
      (getBalance (setBalance s gasResource poolActor
        (getBalance s gasResource poolActor - refundAmount)) gasResource claimant + refundAmount))
      gasResource)
    (getBalance s gasResource poolActor)
    (getBalance (setBalance s gasResource poolActor
      (getBalance s gasResource poolActor - refundAmount)) gasResource claimant)
    refundAmount
    (totalSupply_setBalance s gasResource poolActor
      (getBalance s gasResource poolActor - refundAmount))
    (totalSupply_setBalance
      (setBalance s gasResource poolActor (getBalance s gasResource poolActor - refundAmount))
      gasResource claimant
      (getBalance (setBalance s gasResource poolActor
        (getBalance s gasResource poolActor - refundAmount)) gasResource claimant + refundAmount))
    hpre

/-! ## Cross-resource independence (mirrors §4.11.2) -/

/-- State-level companion: the per-resource `BalanceMap` at any
    `r' ≠ gasResource` is identical before and after a (legal or
    rejected) refund at `gasResource`. -/
theorem claimBudgetRefund_other_resource_untouched
    (claimant poolActor : ActorId) (gasResource r' : ResourceId)
    (refundAmount : Amount) (s : State) (h : gasResource ≠ r') :
    (step_impl s (claimBudgetRefund claimant poolActor gasResource
      refundAmount)).balances[r']? = s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (claimBudgetRefund claimant poolActor gasResource refundAmount).pre s
  · simp only [if_pos hpre]
    show ((setBalance
      (setBalance s gasResource poolActor (getBalance s gasResource poolActor - refundAmount))
      gasResource claimant _).balances)[r']? = s.balances[r']?
    unfold setBalance
    rw [RBMap.find?_insert_other _ gasResource r' _ h,
        RBMap.find?_insert_other _ gasResource r' _ h]
  · simp only [if_neg hpre]

/-- Per-actor balance is preserved at any resource `r' ≠ gasResource`
    after a refund at `gasResource`. -/
theorem claimBudgetRefund_does_not_touch_other_resources
    (claimant poolActor : ActorId) (gasResource r' : ResourceId)
    (refundAmount : Amount) (a : ActorId) (s : State) (h : gasResource ≠ r') :
    getBalance (step_impl s (claimBudgetRefund claimant poolActor gasResource
      refundAmount)) r' a =
    getBalance s r' a := by
  unfold getBalance
  rw [claimBudgetRefund_other_resource_untouched claimant poolActor gasResource r'
        refundAmount s h]

/-- Conservation extends to any resource `r' ≠ gasResource`. -/
theorem claimBudgetRefund_conserves_other_resource
    (claimant poolActor : ActorId) (gasResource r' : ResourceId)
    (refundAmount : Amount) (s : State) (h : gasResource ≠ r') :
    TotalSupply (step_impl s (claimBudgetRefund claimant poolActor gasResource
      refundAmount)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [claimBudgetRefund_other_resource_untouched claimant poolActor gasResource r'
        refundAmount s h]

/-! ## Per-actor balance deltas (GP.9.1 kernel-leg theorems)

These pin the "pool pays, claimant is credited, everyone else is
untouched" reading the GP.9.1 admission theorems lift to. -/

/-- A successful refund debits the pool actor's gas-resource balance
    by exactly `refundAmount`, provided the pool and the claimant are
    distinct actors.  When `poolActor = claimant` the net change is
    zero (the credit re-credits the debit); that corner is excluded
    here and rejected at the admission gate (the claimant is a real
    user, never `gasPoolActor`). -/
theorem claimBudgetRefund_pool_debited
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount) (s : State)
    (hpre : (claimBudgetRefund claimant poolActor gasResource refundAmount).pre s)
    (hne : poolActor ≠ claimant) :
    getBalance (step_impl s (claimBudgetRefund claimant poolActor gasResource
      refundAmount)) gasResource poolActor =
    getBalance s gasResource poolActor - refundAmount := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((claimBudgetRefund claimant poolActor gasResource
          refundAmount).apply_impl s) gasResource poolActor = _
  simp only [claimBudgetRefund]
  -- The outer write is at `claimant ≠ poolActor`; reading at `poolActor`
  -- sees the inner debit-write's value.
  rw [getBalance_setBalance_other _ gasResource gasResource claimant poolActor _
        (Or.inr (Ne.symm hne))]
  rw [getBalance_setBalance_same]

/-- A successful refund credits the claimant's gas-resource balance by
    exactly `refundAmount`, provided the claimant and the pool are
    distinct actors. -/
theorem claimBudgetRefund_claimant_credited
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount) (s : State)
    (hpre : (claimBudgetRefund claimant poolActor gasResource refundAmount).pre s)
    (hne : claimant ≠ poolActor) :
    getBalance (step_impl s (claimBudgetRefund claimant poolActor gasResource
      refundAmount)) gasResource claimant =
    getBalance s gasResource claimant + refundAmount := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((claimBudgetRefund claimant poolActor gasResource
          refundAmount).apply_impl s) gasResource claimant = _
  simp only [claimBudgetRefund]
  -- The outer write is at `claimant`; reading there returns the
  -- written value, whose addend reads the claimant balance from the
  -- post-debit state, which (since claimant ≠ poolActor) equals the
  -- pre-state claimant balance.
  rw [getBalance_setBalance_same]
  rw [getBalance_setBalance_other _ gasResource gasResource poolActor claimant _
        (Or.inr (Ne.symm hne))]

/-- A successful refund leaves untouched the gas-resource balance of
    any actor other than the claimant and the pool actor. -/
theorem claimBudgetRefund_other_actor_untouched
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount) (other : ActorId) (s : State)
    (hpre : (claimBudgetRefund claimant poolActor gasResource refundAmount).pre s)
    (hne_claimant : other ≠ claimant) (hne_pool : other ≠ poolActor) :
    getBalance (step_impl s (claimBudgetRefund claimant poolActor gasResource
      refundAmount)) gasResource other =
    getBalance s gasResource other := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((claimBudgetRefund claimant poolActor gasResource
          refundAmount).apply_impl s) gasResource other = _
  simp only [claimBudgetRefund]
  rw [getBalance_setBalance_other _ gasResource gasResource claimant other _
        (Or.inr (Ne.symm hne_claimant))]
  rw [getBalance_setBalance_other _ gasResource gasResource poolActor other _
        (Or.inr (Ne.symm hne_pool))]

/-! ## Classification instances (mirrors §5.3 / LX.3) -/

/-- `claimBudgetRefund` is conservative at every resource: at the gas
    resource by `claimBudgetRefund_conserves`, elsewhere by
    `claimBudgetRefund_conserves_other_resource`. -/
instance claimBudgetRefund_isConservative
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount) :
    IsConservative (claimBudgetRefund claimant poolActor gasResource refundAmount) where
  conserves := by
    intro r' s hpre
    by_cases hr : gasResource = r'
    · subst hr
      exact claimBudgetRefund_conserves claimant poolActor gasResource refundAmount s hpre
    · exact claimBudgetRefund_conserves_other_resource claimant poolActor gasResource r'
        refundAmount s hr

/-- Conservative laws are monotonic; explicit instance for stable
    identifier resolution. -/
instance claimBudgetRefund_isMonotonic
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount) :
    IsMonotonic (claimBudgetRefund claimant poolActor gasResource refundAmount) where
  monotone := fun r' s hpre =>
    Nat.le_of_eq
      ((claimBudgetRefund_isConservative claimant poolActor gasResource refundAmount).conserves
        r' s hpre).symm

/-- `claimBudgetRefund … gasResource …` is `LocalTo [gasResource]`:
    no actor's balance changes at any resource other than
    `gasResource`. -/
instance claimBudgetRefund_localTo
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount) :
    LocalTo [gasResource] (claimBudgetRefund claimant poolActor gasResource refundAmount) where
  local_to := by
    intro r' a s hr_not_in _
    have hne : gasResource ≠ r' := by
      intro heq
      apply hr_not_in
      rw [← heq]
      exact List.mem_singleton.mpr rfl
    exact claimBudgetRefund_does_not_touch_other_resources claimant poolActor
      gasResource r' refundAmount a s hne

/-- `claimBudgetRefund … gasResource …` preserves freeze for any
    resource set `S` not containing `gasResource`.  A theorem (not an
    instance) because `S` is not inferable. -/
theorem claimBudgetRefund_freezePreserving
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount)
    (S : List ResourceId) (h : gasResource ∉ S) :
    FreezePreserving S (claimBudgetRefund claimant poolActor gasResource refundAmount) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne : r' ≠ gasResource := by
      intro heq
      apply h
      rw [← heq]
      exact hr'
    rw [claimBudgetRefund_other_resource_untouched claimant poolActor gasResource r'
          refundAmount s (Ne.symm hne)]
    exact h_init

/-- Empty-resource-set freeze preservation as an auto-resolvable
    instance (vacuous case of `claimBudgetRefund_freezePreserving`). -/
instance claimBudgetRefund_freezePreserving_empty
    (claimant poolActor : ActorId) (gasResource : ResourceId)
    (refundAmount : Amount) :
    FreezePreserving [] (claimBudgetRefund claimant poolActor gasResource refundAmount) :=
  claimBudgetRefund_freezePreserving claimant poolActor gasResource refundAmount [] (by simp)

end Laws
end LegalKernel
