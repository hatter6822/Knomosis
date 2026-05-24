/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.SubStep — bulk-action sub-step
decomposition (Workstream H WU H.1.4).

Bulk actions (`distributeOthers`, `proportionalDilute`) write
to many balance cells in a single application.  The L1 step VM
cannot execute the entire bulk in one transaction (gas budget).
We decompose each bulk action into a sequence of `SubStep`s:
one per recipient.  Each sub-step touches exactly one balance
cell + the action's nonce on the final sub-step.

The bisection game can drill into a bulk action: the disputed
step becomes "sub-step `k` of log entry `j` is wrong."  The L1
step VM then executes that single sub-step.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Authority.Action
import LegalKernel.Encoding.Encodable
import LegalKernel.FaultProof.Cell

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Encoding

/-! ## DoS bound -/

/-- Maximum recipients per bulk action.  Per Workstream H §2:
    `MAX_RECIPIENTS_PER_BULK_ACTION = 256`. -/
def MAX_RECIPIENTS_PER_BULK_ACTION : Nat := 256

/-! ## `SubStep` data type -/

/-- A single sub-step within a bulk action.

    For `distributeOthers`, one sub-step is one per-recipient
    credit.  `affectedActor` identifies the recipient;
    `preCellValue` and `postCellValue` are the pre- and post-
    balance bytes (CBE-encoded `Amount`s).  `cellProof` carries
    the Merkle witness for the recipient's balance cell. -/
structure SubStep where
  /-- The bulk action this sub-step belongs to. -/
  parentAction       : Action
  /-- The sub-step index (0..MAX_RECIPIENTS_PER_BULK_ACTION-1). -/
  subStepIdx         : Nat
  /-- The recipient whose balance is being credited. -/
  affectedActor      : ActorId
  /-- The recipient's pre-step balance. -/
  preBalance         : Amount
  /-- The recipient's post-step balance. -/
  postBalance        : Amount
  /-- Merkle witness for the recipient's balance cell. -/
  cellProof          : CellProof
  deriving Repr

/-! ## Per-bulk-action sub-step decomposition

For `distributeOthers r exclude amount`, the sub-steps are one
per non-excluded actor at resource `r`.  For
`proportionalDilute r exclude totalReward`, the sub-steps are
one per non-excluded actor with credit
`totalReward * v / sumOthers`.

The decomposition's *length* is exactly the number of non-
excluded actors at the resource, capped at
`MAX_RECIPIENTS_PER_BULK_ACTION`. -/

/-- Construct the sub-step list for a `distributeOthers` action.
    Iterates over the non-excluded actors at the resource,
    producing one sub-step per actor.

    Each sub-step's `cellProof` carries the recipient's
    canonical pre-state balance encoding as `cellValue`; the
    witness state IS the pre-state (so the proof verifies via
    `verifyCellProof` against `commitExtendedState es`). -/
def Action.distributeOthers_subSteps
    (es : ExtendedState) (r : ResourceId) (excluded : ActorId)
    (amount : Amount) : List SubStep :=
  -- Iterate over all actors with positive balance at resource r.
  let allEntries :=
    match es.base.balances[r]? with
    | none    => []
    | some bm => bm.toList
  -- Filter out the excluded actor.
  let nonExcluded := allEntries.filter (fun p => p.1 ≠ excluded)
  -- Cap at MAX_RECIPIENTS_PER_BULK_ACTION (defensive; actual
  -- length is bounded by the number of actors).
  let capped := nonExcluded.take MAX_RECIPIENTS_PER_BULK_ACTION
  -- Build sub-steps with index from 0.  Each sub-step's
  -- cellProof carries the canonical balance encoding so the
  -- proof verifies against the pre-state commit.
  capped.zipIdx.map (fun (p, i) =>
    { parentAction := .distributeOthers r excluded amount,
      subStepIdx := i,
      affectedActor := p.1,
      preBalance := p.2,
      postBalance := p.2 + amount,
      cellProof :=
        { cellTag := CellTag.balance r p.1,
          cellValue :=
            ByteArray.mk (Encodable.encode (T := Nat) p.2).toArray,
          witnessState := es } })

/-- Construct the sub-step list for a `proportionalDilute`
    action.  Iterates over non-excluded actors at the resource,
    producing one sub-step per actor with the proportional credit
    `totalReward * v / sumOthers` (Nat floor; dust discarded).

    Each sub-step's `cellProof` carries the recipient's
    canonical pre-state balance encoding as `cellValue`. -/
def Action.proportionalDilute_subSteps
    (es : ExtendedState) (r : ResourceId) (excluded : ActorId)
    (totalReward : Amount) : List SubStep :=
  let allEntries :=
    match es.base.balances[r]? with
    | none    => []
    | some bm => bm.toList
  let nonExcluded := allEntries.filter (fun p => p.1 ≠ excluded)
  let sumOthers : Nat :=
    nonExcluded.foldl (fun acc p => acc + p.2) 0
  let capped := nonExcluded.take MAX_RECIPIENTS_PER_BULK_ACTION
  capped.zipIdx.map (fun (p, i) =>
    let credit := if sumOthers = 0 then 0 else totalReward * p.2 / sumOthers
    { parentAction := .proportionalDilute r excluded totalReward,
      subStepIdx := i,
      affectedActor := p.1,
      preBalance := p.2,
      postBalance := p.2 + credit,
      cellProof :=
        { cellTag := CellTag.balance r p.1,
          cellValue :=
            ByteArray.mk (Encodable.encode (T := Nat) p.2).toArray,
          witnessState := es } })

/-- Top-level entry: dispatch on action variant. -/
def Action.subSteps
    (es : ExtendedState) (action : Action) : List SubStep :=
  match action with
  | .distributeOthers r exc amount =>
    distributeOthers_subSteps es r exc amount
  | .proportionalDilute r exc totalReward =>
    proportionalDilute_subSteps es r exc totalReward
  | _ => []  -- non-bulk actions have no sub-steps

/-! ## Length bound -/

/-- The sub-step list is bounded by `MAX_RECIPIENTS_PER_BULK_ACTION`. -/
theorem subSteps_length_bound (es : ExtendedState) (action : Action) :
    (Action.subSteps es action).length ≤ MAX_RECIPIENTS_PER_BULK_ACTION := by
  unfold Action.subSteps
  cases action with
  | distributeOthers r exc amt =>
    unfold Action.distributeOthers_subSteps
    simp only [List.length_map, List.length_zipIdx]
    -- After `take MAX_RECIPIENTS_PER_BULK_ACTION`, length is at
    -- most that bound.
    exact List.length_take_le _ _
  | proportionalDilute r exc tr =>
    unfold Action.proportionalDilute_subSteps
    simp only [List.length_map, List.length_zipIdx]
    exact List.length_take_le _ _
  | _ => simp [List.length_nil, Nat.zero_le]

/-! ## Determinism (plan §18 #227)

`Action.subSteps` is deterministic in the `(extendedState,
action)` input.  The L1 step VM's per-sub-step execution
depends on re-deriving the sub-step sequence byte-for-byte
identically to the L2 side. -/

/-- #227 — `Action.subSteps` is deterministic: equal inputs
    produce equal sub-step sequences. -/
theorem subSteps_deterministic
    (es₁ es₂ : ExtendedState) (a₁ a₂ : Action)
    (h_es : es₁ = es₂) (h_a : a₁ = a₂) :
    Action.subSteps es₁ a₁ = Action.subSteps es₂ a₂ := by
  rw [h_es, h_a]

/-! ## Smoke checks -/

/-- Non-bulk actions have empty sub-step lists. -/
example (es : ExtendedState) (r : ResourceId) (s : ActorId) (a : Amount) :
    Action.subSteps es (.transfer r s s a) = [] := rfl

/-- The DoS bound is exactly 256. -/
example : MAX_RECIPIENTS_PER_BULK_ACTION = 256 := rfl

end FaultProof
end LegalKernel
