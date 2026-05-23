/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
-/

/-
LegalKernel.Authority.ActorBudget — per-actor action-budget ledger.
-/

import LegalKernel.Kernel
import LegalKernel.RBMapLemmas

open Std

namespace LegalKernel
namespace Authority

/-- Per-actor epoch budget cell. -/
structure ActorBudget where
  /-- Last epoch this cell was observed/mutated. -/
  lastSeenEpoch : Nat
  /-- Budget balance tracked for `lastSeenEpoch`. -/
  budgetBalance : Nat
  deriving Repr, DecidableEq

namespace ActorBudget

/-- Empty budget cell (epoch 0, balance 0). -/
def empty : ActorBudget := { lastSeenEpoch := 0, budgetBalance := 0 }

@[simp] theorem empty_lastSeenEpoch_zero : empty.lastSeenEpoch = 0 := rfl
@[simp] theorem empty_budgetBalance_zero : empty.budgetBalance = 0 := rfl

/-- Normalise against `now`, flooring stale balances at `freeTier`. -/
def normalise (b : ActorBudget) (now : Nat) (freeTier : Nat) : ActorBudget :=
  if b.lastSeenEpoch < now then
    { lastSeenEpoch := now, budgetBalance := max b.budgetBalance freeTier }
  else
    b

/-- Attempt to consume `cost` units after normalisation. -/
def consume (b : ActorBudget) (now : Nat) (freeTier : Nat) (cost : Nat) : Option ActorBudget :=
  let bn := b.normalise now freeTier
  if cost ≤ bn.budgetBalance then
    some { bn with budgetBalance := bn.budgetBalance - cost }
  else
    none

/-- Add `amount` units after normalisation. -/
def topUp (b : ActorBudget) (now : Nat) (freeTier : Nat) (amount : Nat) : ActorBudget :=
  let bn := b.normalise now freeTier
  { bn with budgetBalance := bn.budgetBalance + amount }

@[simp] theorem normalise_noop_if_current (b : ActorBudget) (now ft : Nat)
    (h : b.lastSeenEpoch ≥ now) : b.normalise now ft = b := by
  unfold normalise; simp [Nat.not_lt.mpr h]

@[simp] theorem normalise_lastSeenEpoch_eq_max (b : ActorBudget) (now ft : Nat) :
    (b.normalise now ft).lastSeenEpoch = max b.lastSeenEpoch now := by
  unfold normalise
  by_cases h : b.lastSeenEpoch < now
  · simp [h, Nat.max_eq_right (Nat.le_of_lt h)]
  · simp [h, Nat.max_eq_left (Nat.le_of_not_gt h)]

theorem normalise_floors_at_freeTier (b : ActorBudget) (now ft : Nat)
    (h : b.lastSeenEpoch < now) :
    (b.normalise now ft).budgetBalance ≥ ft := by
  unfold normalise
  simp [h, Nat.le_max_right]

theorem normalise_balance_lower_bound (b : ActorBudget) (now ft : Nat) :
    (b.normalise now ft).budgetBalance ≥ b.budgetBalance := by
  unfold normalise
  by_cases h : b.lastSeenEpoch < now
  · simp [h, Nat.le_max_left]
  · simp [h]

@[simp] theorem normalise_idempotent (b : ActorBudget) (now ft : Nat) :
    (b.normalise now ft).normalise now ft = b.normalise now ft := by
  have hge : (b.normalise now ft).lastSeenEpoch ≥ now := by
    rw [normalise_lastSeenEpoch_eq_max]
    exact Nat.le_max_right _ _
  exact normalise_noop_if_current _ _ _ hge

/-! ## GP.3.2 supporting lemmas

The following lemmas describe the post-state of `consume` and `topUp`
so that the admission-layer theorems can reason about budget changes
through `currentBudget`. -/

/-- A successful `consume` produces a cell whose `lastSeenEpoch`
    is at least `now`.  The cell is "normalised" with respect to
    `now`: subsequent `normalise now ft` calls are the identity. -/
theorem consume_some_lastSeenEpoch_ge (b : ActorBudget) (now ft cost : Nat)
    (b' : ActorBudget) (h : b.consume now ft cost = some b') :
    b'.lastSeenEpoch ≥ now := by
  unfold consume at h
  by_cases hle : cost ≤ (b.normalise now ft).budgetBalance
  · simp [hle] at h
    rw [← h]
    -- After simp + rw, the goal mentions `max b.lastSeenEpoch now` directly
    -- because `simp` unfolded `(b.normalise now ft).lastSeenEpoch`.
    show max b.lastSeenEpoch now ≥ now
    exact Nat.le_max_right _ _
  · simp [hle] at h

/-- A successful `consume` produces a cell whose `budgetBalance`
    equals the normalised-cell's `budgetBalance - cost`. -/
theorem consume_some_budgetBalance (b : ActorBudget) (now ft cost : Nat)
    (b' : ActorBudget) (h : b.consume now ft cost = some b') :
    b'.budgetBalance = (b.normalise now ft).budgetBalance - cost := by
  unfold consume at h
  by_cases hle : cost ≤ (b.normalise now ft).budgetBalance
  · simp [hle] at h
    rw [← h]
  · simp [hle] at h

/-- `consume` succeeds iff the normalised balance is at least `cost`. -/
theorem consume_isSome_iff (b : ActorBudget) (now ft cost : Nat) :
    (b.consume now ft cost).isSome = true ↔
    cost ≤ (b.normalise now ft).budgetBalance := by
  unfold consume
  by_cases hle : cost ≤ (b.normalise now ft).budgetBalance
  · simp [hle]
  · simp [hle]

/-- `consume` returns `none` iff the normalised balance is less than `cost`. -/
theorem consume_eq_none_iff (b : ActorBudget) (now ft cost : Nat) :
    b.consume now ft cost = none ↔
    (b.normalise now ft).budgetBalance < cost := by
  unfold consume
  by_cases hle : cost ≤ (b.normalise now ft).budgetBalance
  · simp [hle, Nat.not_lt.mpr hle]
  · simp [hle]
    exact Nat.lt_of_not_le hle

/-- A `consume` that succeeds keeps the cell normalised: re-normalising
    against the same `now` is the identity. -/
theorem consume_some_normalised (b : ActorBudget) (now ft cost : Nat)
    (b' : ActorBudget) (h : b.consume now ft cost = some b') :
    b'.normalise now ft = b' :=
  normalise_noop_if_current _ _ _ (consume_some_lastSeenEpoch_ge b now ft cost b' h)

/-- `topUp` produces a cell whose `lastSeenEpoch` is at least `now`,
    so the cell is "normalised" with respect to `now`. -/
theorem topUp_lastSeenEpoch_ge (b : ActorBudget) (now ft amount : Nat) :
    (b.topUp now ft amount).lastSeenEpoch ≥ now := by
  unfold topUp
  show (b.normalise now ft).lastSeenEpoch ≥ now
  rw [normalise_lastSeenEpoch_eq_max]
  exact Nat.le_max_right _ _

/-- `topUp` produces a cell whose `budgetBalance` equals the
    normalised-cell's `budgetBalance + amount`. -/
theorem topUp_budgetBalance (b : ActorBudget) (now ft amount : Nat) :
    (b.topUp now ft amount).budgetBalance =
      (b.normalise now ft).budgetBalance + amount := by
  unfold topUp
  rfl

/-- A `topUp` keeps the cell normalised: re-normalising against
    the same `now` is the identity. -/
theorem topUp_normalised (b : ActorBudget) (now ft amount : Nat) :
    (b.topUp now ft amount).normalise now ft = b.topUp now ft amount :=
  normalise_noop_if_current _ _ _ (topUp_lastSeenEpoch_ge b now ft amount)

end ActorBudget

/-- Per-actor map of budget cells. -/
abbrev EpochBudgetState := TreeMap ActorId ActorBudget compare

namespace EpochBudgetState

/-- Empty per-actor budget state. -/
def empty : EpochBudgetState := ∅

@[simp] theorem empty_is_empty (a : ActorId) : empty[a]? = none := by simp [empty]

/-- Actor budget after normalising current cell. -/
def currentBudget (ebs : EpochBudgetState) (a : ActorId) (now : Nat) (freeTier : Nat) : Nat :=
  ((ebs[a]?.getD ActorBudget.empty).normalise now freeTier).budgetBalance

/-- Consume actor budget; fails with `none` if insufficient. -/
def consume (ebs : EpochBudgetState) (a : ActorId) (now : Nat) (freeTier : Nat) (cost : Nat) :
    Option EpochBudgetState :=
  match (ebs[a]?.getD ActorBudget.empty).consume now freeTier cost with
  | some b' => some (ebs.insert a b')
  | none => none

/-- Credit actor budget by `amount`. -/
def topUp (ebs : EpochBudgetState) (a : ActorId) (now : Nat) (freeTier : Nat) (amount : Nat) :
    EpochBudgetState :=
  let b' := (ebs[a]?.getD ActorBudget.empty).topUp now freeTier amount
  ebs.insert a b'

/-! ## GP.3.2 supporting lemmas

The following lemmas relate `currentBudget` to `consume` and
`topUp` post-states.  They are the foundation for the admission-
layer theorems in `Authority/SignedAction.lean`. -/

/-- After a successful `consume`, the actor's `currentBudget`
    equals the pre-consume `currentBudget` minus `cost`.  The
    proof relies on three observations:

      1. The consumed cell's `lastSeenEpoch ≥ now` (by
         `ActorBudget.consume_some_lastSeenEpoch`), so a fresh
         `currentBudget` lookup against the post-state needs no
         re-normalisation.
      2. `RBMap.find?_insert_self` gives the inserted cell back
         on `[a]?` lookup.
      3. `ActorBudget.consume_some_budgetBalance` reduces the
         consumed balance to the normalised pre-balance minus
         `cost`. -/
theorem currentBudget_after_consume_self
    (ebs : EpochBudgetState) (a : ActorId) (now ft cost : Nat)
    (ebs' : EpochBudgetState) (h : ebs.consume a now ft cost = some ebs') :
    ebs'.currentBudget a now ft = ebs.currentBudget a now ft - cost := by
  -- Case-split on the inner `ActorBudget.consume` result.
  have h' := h
  unfold consume at h'
  cases hopt : (ebs[a]?.getD ActorBudget.empty).consume now ft cost with
  | none =>
    rw [hopt] at h'
    cases h'
  | some b' =>
    rw [hopt] at h'
    -- h' : some (ebs.insert a b') = some ebs'
    injection h' with hb'
    -- hb' : ebs.insert a b' = ebs'
    unfold currentBudget
    rw [← hb']
    rw [RBMap.find?_insert_self]
    show (b'.normalise now ft).budgetBalance =
      ((ebs[a]?.getD ActorBudget.empty).normalise now ft).budgetBalance - cost
    rw [ActorBudget.consume_some_normalised _ now ft cost b' hopt]
    rw [ActorBudget.consume_some_budgetBalance _ now ft cost b' hopt]

/-- After a successful `consume` against actor `a`, the
    `currentBudget` of any other actor `a' ≠ a` is unchanged.
    Captures the locality of `consume`: it only mutates the cell
    at `a`. -/
theorem currentBudget_after_consume_other
    (ebs : EpochBudgetState) (a a' : ActorId) (now ft cost : Nat)
    (ebs' : EpochBudgetState) (h : ebs.consume a now ft cost = some ebs')
    (hne : a ≠ a') :
    ebs'.currentBudget a' now ft = ebs.currentBudget a' now ft := by
  have h' := h
  unfold consume at h'
  cases hopt : (ebs[a]?.getD ActorBudget.empty).consume now ft cost with
  | none =>
    rw [hopt] at h'
    cases h'
  | some b' =>
    rw [hopt] at h'
    injection h' with hb'
    unfold currentBudget
    rw [← hb']
    rw [RBMap.find?_insert_other _ a a' _ hne]

/-- `consume` returns `none` iff the actor's `currentBudget` is
    strictly less than `cost`.  Direct corollary of
    `ActorBudget.consume_eq_none_iff` lifted from cell- to map-level. -/
theorem consume_eq_none_iff (ebs : EpochBudgetState) (a : ActorId) (now ft cost : Nat) :
    ebs.consume a now ft cost = none ↔ ebs.currentBudget a now ft < cost := by
  unfold consume currentBudget
  cases hopt : (ebs[a]?.getD ActorBudget.empty).consume now ft cost with
  | none =>
    -- LHS reduces to `none = none` which is `True`.
    -- RHS: by ActorBudget.consume_eq_none_iff.
    constructor
    · intro _
      exact (ActorBudget.consume_eq_none_iff _ now ft cost).mp hopt
    · intro _
      rfl
  | some b' =>
    -- LHS reduces to `some _ = none` which is `False`.
    constructor
    · intro h
      cases h
    · intro h
      -- RHS h : (normalise).budgetBalance < cost.
      -- But hopt : ActorBudget.consume = some, so cost ≤ (normalise).budgetBalance.
      exfalso
      have hsucc : cost ≤ ((ebs[a]?.getD ActorBudget.empty).normalise now ft).budgetBalance := by
        have := (ActorBudget.consume_isSome_iff (ebs[a]?.getD ActorBudget.empty) now ft cost).mp
          (by simp [hopt])
        exact this
      exact absurd h (Nat.not_lt.mpr hsucc)

/-- `consume` succeeds when the actor's `currentBudget` is at
    least `cost`.  Constructive existence. -/
theorem consume_succeeds_when_sufficient
    (ebs : EpochBudgetState) (a : ActorId) (now ft cost : Nat)
    (h : cost ≤ ebs.currentBudget a now ft) :
    ∃ ebs', ebs.consume a now ft cost = some ebs' := by
  cases hopt : ebs.consume a now ft cost with
  | some ebs' => exact ⟨ebs', rfl⟩
  | none =>
    exfalso
    have := (consume_eq_none_iff ebs a now ft cost).mp hopt
    exact absurd this (Nat.not_lt.mpr h)

/-- After `topUp` against actor `a`, the actor's `currentBudget`
    equals the pre-topup `currentBudget` plus `amount`. -/
theorem currentBudget_after_topUp_self
    (ebs : EpochBudgetState) (a : ActorId) (now ft amount : Nat) :
    (ebs.topUp a now ft amount).currentBudget a now ft =
    ebs.currentBudget a now ft + amount := by
  show ((((ebs.insert a ((ebs[a]?.getD ActorBudget.empty).topUp now ft amount))[a]?).getD
            ActorBudget.empty).normalise now ft).budgetBalance =
       (((ebs[a]?.getD ActorBudget.empty).normalise now ft).budgetBalance + amount)
  rw [RBMap.find?_insert_self]
  -- After `find?_insert_self`, the lookup is `some (b₀.topUp ...)`; `Option.getD` unwraps.
  show ((((ebs[a]?.getD ActorBudget.empty).topUp now ft amount).normalise now ft).budgetBalance) =
       (((ebs[a]?.getD ActorBudget.empty).normalise now ft).budgetBalance + amount)
  rw [ActorBudget.topUp_normalised _ now ft amount]
  rw [ActorBudget.topUp_budgetBalance _ now ft amount]

/-- After `topUp` against actor `a`, any other actor `a' ≠ a`'s
    `currentBudget` is unchanged.  Locality of `topUp`. -/
theorem currentBudget_after_topUp_other
    (ebs : EpochBudgetState) (a a' : ActorId) (now ft amount : Nat)
    (hne : a ≠ a') :
    (ebs.topUp a now ft amount).currentBudget a' now ft =
    ebs.currentBudget a' now ft := by
  unfold topUp currentBudget
  show ((((ebs.insert a ((ebs[a]?.getD ActorBudget.empty).topUp now ft amount))[a']?).getD
            ActorBudget.empty).normalise now ft).budgetBalance =
       (((ebs[a']?.getD ActorBudget.empty).normalise now ft).budgetBalance)
  rw [RBMap.find?_insert_other _ a a' _ hne]

/-- An actor whose cell has `lastSeenEpoch < now` sees their
    `currentBudget` floored at `freeTier`.  Direct corollary of
    `ActorBudget.normalise_floors_at_freeTier` lifted to map-level. -/
theorem currentBudget_floored_at_freeTier
    (ebs : EpochBudgetState) (a : ActorId) (now ft : Nat)
    (h : (ebs[a]?.getD ActorBudget.empty).lastSeenEpoch < now) :
    ebs.currentBudget a now ft ≥ ft := by
  unfold currentBudget
  exact ActorBudget.normalise_floors_at_freeTier _ now ft h

/-- The genesis `EpochBudgetState.empty` returns `currentBudget = 0`
    when `now = 0` (the cell's `lastSeenEpoch` defaults to 0, so
    normalise is the identity, and the default `budgetBalance = 0`). -/
theorem currentBudget_empty_genesis (a : ActorId) (ft : Nat) :
    EpochBudgetState.empty.currentBudget a 0 ft = 0 := by
  unfold currentBudget
  rw [empty_is_empty]
  unfold ActorBudget.normalise
  simp [ActorBudget.empty]

end EpochBudgetState

end Authority
end LegalKernel
