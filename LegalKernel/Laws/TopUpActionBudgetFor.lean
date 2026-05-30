-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Laws.TopUpActionBudgetFor — the GP.3.4 delegated
action-budget top-up law.

Workstream GP / WU GP.3.4.  The kernel-level leg of the
pre-authorised *delegated* budget top-up resolved in OQ-GP-7: a
`signer` (delegate) pays `gasAmount` of `gasResource` into the
`poolActor`, so that the admission layer can credit a *different*
actor's (`recipient`'s) epoch budget by `budgetIncrement`.

Kernel-state effect.  Identical in shape to `Laws.topUpActionBudget`
(and to a `Laws.transfer gasResource signer poolActor gasAmount`):
debit the signer, credit the pool actor, reading the pool actor's
balance from the post-debit intermediate state so the
`signer = poolActor` corner conserves total supply.  The `recipient`
and `budgetIncrement` parameters do NOT touch kernel state — they are
consumed by the GP.3.4 admission gate (`Authority/SignedAction.lean`),
which performs the recipient-consent check and the recipient-targeted
budget grant.

Precondition.  `getBalance s gasResource signer ≥ gasAmount` (the
signer can afford the payment) AND `recipient ≠ signer` (the
delegated path is for funding *others*; self-top-up goes through
`Action.topUpActionBudget` directly).  The `recipient ≠ signer`
guard is load-bearing for the admission gate: without it, a signer
could route a delegated top-up to their own slot and obtain budget
without the kernel step actually executing a net gas debit.

This module is **not** part of the trusted computing base: bugs here
are scoped to one deployment-facing law, never a kernel invariant.

Conservation / classification.  Because the kernel-state effect is a
debit-then-credit transfer, the law inherits the full §4.11 ladder:
per-resource conservation, cross-resource locality, monotonicity,
`LocalTo [gasResource]`, and freeze-preservation for any resource set
excluding `gasResource`.  The proofs mirror `Laws/Transfer.lean`
verbatim (same `apply_impl` shape), only the precondition differs.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Laws.Transfer

namespace LegalKernel
namespace Laws

/-- GP.3.4 delegated action-budget top-up — kernel leg.

    `signer` (the delegate) pays `gasAmount` units of `gasResource`
    into `poolActor`; the admission layer credits `recipient`'s epoch
    budget by `budgetIncrement` (not modelled at the kernel level).

    * Precondition: the signer holds at least `gasAmount`, and the
      recipient is a *different* actor (`recipient ≠ signer`).
    * Effect: debit `signer`, then credit `poolActor`, reading the
      pool's balance from the post-debit intermediate state (so the
      `signer = poolActor` corner conserves supply).

    `decPre` is inferred: the precondition is a conjunction of a
    decidable `Nat` comparison and a decidable `ActorId`
    disequality. -/
def topUpActionBudgetFor (recipient signer : ActorId) (gasResource : ResourceId)
    (gasAmount : Amount) (_budgetIncrement : Nat) (poolActor : ActorId) : Transition where
  pre := fun s => getBalance s gasResource signer ≥ gasAmount ∧ recipient ≠ signer
  decPre := fun _ => inferInstance
  apply_impl := fun s =>
    let s1 := setBalance s gasResource signer (getBalance s gasResource signer - gasAmount)
    setBalance s1 gasResource poolActor (getBalance s1 gasResource poolActor + gasAmount)

/-- The delegated-top-up kernel effect coincides with the
    debit-then-credit `transfer gasResource signer poolActor
    gasAmount` effect at the `apply_impl` level.  Definitional
    (`rfl`): both unfold to the same two-`setBalance` chain.  The
    `recipient` / `budgetIncrement` parameters are kernel-state-inert,
    so they do not appear on the right. -/
theorem topUpActionBudgetFor_apply_eq_transfer
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) (s : State) :
    (topUpActionBudgetFor recipient signer gasResource gasAmount budgetIncrement poolActor).apply_impl s =
    (transfer gasResource signer poolActor gasAmount).apply_impl s := rfl

/-! ## Per-resource conservation (mirrors §4.11.1)

The argument is the §4.11 transfer argument verbatim: open `step_impl`
via the precondition, apply the master `setBalance`-on-`TotalSupply`
accounting lemma at each write, and discharge the resulting linear
system with `omega`.  Uniform over the `signer = poolActor` corner. -/

/-- Pure-arithmetic kernel of `topUpActionBudgetFor_conserves`.
    Identical shape to `Laws.transfer`'s `transfer_arithmetic`
    helper; lifted to plain `Nat` parameters so `omega`'s atom
    discovery sees clean variables rather than deeply-nested
    `TotalSupply (setBalance …)` terms. -/
private theorem topUpFor_arithmetic
    (T0 T1 T2 B R1 amount : Nat)
    (h1   : T1 + B = T0 + (B - amount))
    (h2   : T2 + R1 = T1 + (R1 + amount))
    (hbal : amount ≤ B) :
    T2 = T0 := by
  omega

/-- `topUpActionBudgetFor` preserves per-resource total supply at the
    gas resource.  Holds in both the distinct-actor and
    `signer = poolActor` cases (the post-debit re-read inside
    `apply_impl` makes the self-pool case conserve). -/
theorem topUpActionBudgetFor_conserves
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId)
    (s : State)
    (hpre : (topUpActionBudgetFor recipient signer gasResource gasAmount
              budgetIncrement poolActor).pre s) :
    TotalSupply (step_impl s (topUpActionBudgetFor recipient signer gasResource
                  gasAmount budgetIncrement poolActor)) gasResource =
    TotalSupply s gasResource := by
  rw [step_impl]
  simp only [if_pos hpre]
  show TotalSupply ((topUpActionBudgetFor recipient signer gasResource gasAmount
          budgetIncrement poolActor).apply_impl s) gasResource = TotalSupply s gasResource
  simp only [topUpActionBudgetFor]
  exact topUpFor_arithmetic
    (TotalSupply s gasResource)
    (TotalSupply (setBalance s gasResource signer
      (getBalance s gasResource signer - gasAmount)) gasResource)
    (TotalSupply (setBalance
      (setBalance s gasResource signer (getBalance s gasResource signer - gasAmount))
      gasResource poolActor
      (getBalance (setBalance s gasResource signer
        (getBalance s gasResource signer - gasAmount)) gasResource poolActor + gasAmount))
      gasResource)
    (getBalance s gasResource signer)
    (getBalance (setBalance s gasResource signer
      (getBalance s gasResource signer - gasAmount)) gasResource poolActor)
    gasAmount
    (totalSupply_setBalance s gasResource signer
      (getBalance s gasResource signer - gasAmount))
    (totalSupply_setBalance
      (setBalance s gasResource signer (getBalance s gasResource signer - gasAmount))
      gasResource poolActor
      (getBalance (setBalance s gasResource signer
        (getBalance s gasResource signer - gasAmount)) gasResource poolActor + gasAmount))
    hpre.left

/-- A convenient alias matching the GP.3.4 plan's theorem name:
    the gas-resource total supply is invariant under a delegated
    top-up. -/
theorem topUpActionBudgetFor_totalSupply_invariant
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId)
    (s : State)
    (hpre : (topUpActionBudgetFor recipient signer gasResource gasAmount
              budgetIncrement poolActor).pre s) :
    TotalSupply (step_impl s (topUpActionBudgetFor recipient signer gasResource
                  gasAmount budgetIncrement poolActor)) gasResource =
    TotalSupply s gasResource :=
  topUpActionBudgetFor_conserves recipient signer gasResource gasAmount
    budgetIncrement poolActor s hpre

/-! ## Cross-resource independence (mirrors §4.11.2) -/

/-- State-level companion: the per-resource `BalanceMap` at any
    `r' ≠ gasResource` is identical before and after a (legal or
    rejected) delegated top-up at `gasResource`. -/
theorem topUpActionBudgetFor_other_resource_untouched
    (recipient signer : ActorId) (gasResource r' : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) (s : State) (h : gasResource ≠ r') :
    (step_impl s (topUpActionBudgetFor recipient signer gasResource gasAmount
      budgetIncrement poolActor)).balances[r']? = s.balances[r']? := by
  rw [step_impl]
  by_cases hpre : (topUpActionBudgetFor recipient signer gasResource gasAmount
                    budgetIncrement poolActor).pre s
  · simp only [if_pos hpre]
    show ((setBalance
      (setBalance s gasResource signer (getBalance s gasResource signer - gasAmount))
      gasResource poolActor _).balances)[r']? = s.balances[r']?
    unfold setBalance
    rw [RBMap.find?_insert_other _ gasResource r' _ h,
        RBMap.find?_insert_other _ gasResource r' _ h]
  · simp only [if_neg hpre]

/-- Per-actor balance is preserved at any resource `r' ≠ gasResource`
    after a delegated top-up at `gasResource`. -/
theorem topUpActionBudgetFor_does_not_touch_other_resources
    (recipient signer : ActorId) (gasResource r' : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) (a : ActorId) (s : State)
    (h : gasResource ≠ r') :
    getBalance (step_impl s (topUpActionBudgetFor recipient signer gasResource
      gasAmount budgetIncrement poolActor)) r' a =
    getBalance s r' a := by
  unfold getBalance
  rw [topUpActionBudgetFor_other_resource_untouched recipient signer gasResource r'
        gasAmount budgetIncrement poolActor s h]

/-- Conservation extends to any resource `r' ≠ gasResource`. -/
theorem topUpActionBudgetFor_conserves_other_resource
    (recipient signer : ActorId) (gasResource r' : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) (s : State) (h : gasResource ≠ r') :
    TotalSupply (step_impl s (topUpActionBudgetFor recipient signer gasResource
      gasAmount budgetIncrement poolActor)) r' =
    TotalSupply s r' := by
  unfold TotalSupply
  rw [topUpActionBudgetFor_other_resource_untouched recipient signer gasResource r'
        gasAmount budgetIncrement poolActor s h]

/-! ## Per-actor balance deltas (GP.3.4 kernel-leg theorems)

These pin the "signer pays, pool is credited, everyone else is
untouched" reading the GP.3.4 admission theorems lift to. -/

/-- A successful delegated top-up debits the signer's gas-resource
    balance by exactly `gasAmount`, provided the signer is not the
    pool actor.  When `signer = poolActor` the net debit is zero
    (the credit re-credits the debit); that corner is excluded here
    and rejected at the admission gate (round-4 self-pool defence). -/
theorem topUpActionBudgetFor_signer_debited
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) (s : State)
    (hpre : (topUpActionBudgetFor recipient signer gasResource gasAmount
              budgetIncrement poolActor).pre s)
    (hne : signer ≠ poolActor) :
    getBalance (step_impl s (topUpActionBudgetFor recipient signer gasResource
      gasAmount budgetIncrement poolActor)) gasResource signer =
    getBalance s gasResource signer - gasAmount := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((topUpActionBudgetFor recipient signer gasResource gasAmount
          budgetIncrement poolActor).apply_impl s) gasResource signer = _
  simp only [topUpActionBudgetFor]
  -- Outer write is at `poolActor ≠ signer`; reading at `signer`
  -- sees the inner debit-write's value.
  rw [getBalance_setBalance_other _ gasResource gasResource poolActor signer _
        (Or.inr (Ne.symm hne))]
  rw [getBalance_setBalance_same]

/-- A successful delegated top-up credits the pool actor's
    gas-resource balance by exactly `gasAmount`, provided the signer
    is not the pool actor. -/
theorem topUpActionBudgetFor_pool_credited
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) (s : State)
    (hpre : (topUpActionBudgetFor recipient signer gasResource gasAmount
              budgetIncrement poolActor).pre s)
    (hne : signer ≠ poolActor) :
    getBalance (step_impl s (topUpActionBudgetFor recipient signer gasResource
      gasAmount budgetIncrement poolActor)) gasResource poolActor =
    getBalance s gasResource poolActor + gasAmount := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((topUpActionBudgetFor recipient signer gasResource gasAmount
          budgetIncrement poolActor).apply_impl s) gasResource poolActor = _
  simp only [topUpActionBudgetFor]
  -- The outer write is at `poolActor`; reading there returns the
  -- written value, whose addend reads the pool balance from the
  -- post-debit state, which (since poolActor ≠ signer) equals the
  -- pre-state pool balance.
  rw [getBalance_setBalance_same]
  rw [getBalance_setBalance_other _ gasResource gasResource signer poolActor _
        (Or.inr hne)]

/-- A successful delegated top-up leaves untouched the gas-resource
    balance of any actor other than the signer and the pool actor. -/
theorem topUpActionBudgetFor_other_actor_untouched
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) (other : ActorId) (s : State)
    (hpre : (topUpActionBudgetFor recipient signer gasResource gasAmount
              budgetIncrement poolActor).pre s)
    (hne_signer : other ≠ signer) (hne_pool : other ≠ poolActor) :
    getBalance (step_impl s (topUpActionBudgetFor recipient signer gasResource
      gasAmount budgetIncrement poolActor)) gasResource other =
    getBalance s gasResource other := by
  rw [step_impl]
  simp only [if_pos hpre]
  show getBalance ((topUpActionBudgetFor recipient signer gasResource gasAmount
          budgetIncrement poolActor).apply_impl s) gasResource other = _
  simp only [topUpActionBudgetFor]
  rw [getBalance_setBalance_other _ gasResource gasResource poolActor other _
        (Or.inr (Ne.symm hne_pool))]
  rw [getBalance_setBalance_other _ gasResource gasResource signer other _
        (Or.inr (Ne.symm hne_signer))]

/-! ## Classification instances (mirrors §5.3 / LX.3) -/

/-- `topUpActionBudgetFor` is conservative at every resource: at the
    gas resource by `topUpActionBudgetFor_conserves`, elsewhere by
    `topUpActionBudgetFor_conserves_other_resource`. -/
instance topUpActionBudgetFor_isConservative
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) :
    IsConservative (topUpActionBudgetFor recipient signer gasResource gasAmount
      budgetIncrement poolActor) where
  conserves := by
    intro r' s hpre
    by_cases hr : gasResource = r'
    · subst hr
      exact topUpActionBudgetFor_conserves recipient signer gasResource gasAmount
        budgetIncrement poolActor s hpre
    · exact topUpActionBudgetFor_conserves_other_resource recipient signer gasResource r'
        gasAmount budgetIncrement poolActor s hr

/-- Conservative laws are monotonic; explicit instance for stable
    identifier resolution. -/
instance topUpActionBudgetFor_isMonotonic
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) :
    IsMonotonic (topUpActionBudgetFor recipient signer gasResource gasAmount
      budgetIncrement poolActor) where
  monotone := fun r' s hpre =>
    Nat.le_of_eq
      ((topUpActionBudgetFor_isConservative recipient signer gasResource gasAmount
        budgetIncrement poolActor).conserves r' s hpre).symm

/-- `topUpActionBudgetFor … gasResource …` is `LocalTo [gasResource]`:
    no actor's balance changes at any resource other than
    `gasResource`. -/
instance topUpActionBudgetFor_localTo
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) :
    LocalTo [gasResource] (topUpActionBudgetFor recipient signer gasResource gasAmount
      budgetIncrement poolActor) where
  local_to := by
    intro r' a s hr_not_in _
    have hne : gasResource ≠ r' := by
      intro heq
      apply hr_not_in
      rw [← heq]
      exact List.mem_singleton.mpr rfl
    exact topUpActionBudgetFor_does_not_touch_other_resources recipient signer
      gasResource r' gasAmount budgetIncrement poolActor a s hne

/-- `topUpActionBudgetFor … gasResource …` preserves freeze for any
    resource set `S` not containing `gasResource`.  A theorem (not an
    instance) because `S` is not inferable. -/
theorem topUpActionBudgetFor_freezePreserving
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId)
    (S : List ResourceId) (h : gasResource ∉ S) :
    FreezePreserving S (topUpActionBudgetFor recipient signer gasResource gasAmount
      budgetIncrement poolActor) where
  preserves := by
    intro r' hr' snap s h_init _
    have hne : r' ≠ gasResource := by
      intro heq
      apply h
      rw [← heq]
      exact hr'
    rw [topUpActionBudgetFor_other_resource_untouched recipient signer gasResource r'
          gasAmount budgetIncrement poolActor s (Ne.symm hne)]
    exact h_init

/-- Empty-resource-set freeze preservation as an auto-resolvable
    instance (vacuous case of `topUpActionBudgetFor_freezePreserving`). -/
instance topUpActionBudgetFor_freezePreserving_empty
    (recipient signer : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) :
    FreezePreserving [] (topUpActionBudgetFor recipient signer gasResource gasAmount
      budgetIncrement poolActor) :=
  topUpActionBudgetFor_freezePreserving recipient signer gasResource gasAmount
    budgetIncrement poolActor [] (by simp)

end Laws
end LegalKernel
