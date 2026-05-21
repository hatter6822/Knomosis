/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
-/

/-
LegalKernel.Authority.ActorBudget — per-actor action-budget ledger.
-/

import LegalKernel.Kernel

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

end EpochBudgetState

end Authority
end LegalKernel
