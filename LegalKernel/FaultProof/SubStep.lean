-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
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

/-- Maximum recipients per bulk action (Workstream H §2).

    **The single definition.**  `StepVMCoherence` used to carry a
    second copy holding the same number; two caps that must agree with
    nothing checking them is how a DoS bound drifts, so the dispatcher
    now reads this one. -/
def maxRecipientsPerBulkAction : Nat := 256

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
  /-- The sub-step index (`0 .. maxRecipientsPerBulkAction - 1`). -/
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

/-! ## Recipient enumeration

The ordering hazard the plan flagged: `stepVMHash`'s bulk arms iterate
`bundle.proofs` — a CALLER-supplied order — while the sub-step
decomposition and `Laws.distributeOthers`'s own fold iterate the
balance map.  An SMT fold is order-sensitive, so those cannot both be
consensus.

The balance-map order wins, because it is a function of `(state,
action)` and the bundle order is not: a responder who could reorder
the bundle could steer the post-root.  `bulkRecipients` names it once,
and `distributeOthers_recipients_eq_law_fold_order` pins it against the
law's own list so the two cannot drift. -/

/-- The recipients a bulk action credits, in the order both the law
    and the decomposition traverse: the resource's balance-map order,
    minus the excluded actor. -/
def bulkRecipients (es : ExtendedState) (r : ResourceId) (excluded : ActorId) :
    List (ActorId × Amount) :=
  (match es.base.balances[r]? with
   | none    => []
   | some bm => bm.toList).filter (fun p => p.1 ≠ excluded)

/-- **The decomposition traverses exactly the law's list, in the law's
    order.**  `Laws.distributeOthers` folds over
    `bm.toList.filter (·.1 != excluded)`; this says `bulkRecipients` is
    that list.  Stated because the two spell their filter differently
    (`!=` against `≠`) and a `decide`-level difference here would be an
    order divergence nothing else would catch. -/
theorem bulkRecipients_eq_law_list
    (es : ExtendedState) (r : ResourceId) (excluded : ActorId) :
    bulkRecipients es r excluded
      = (es.base.balances[r]?.getD ∅).toList.filter (fun kv => kv.1 != excluded) := by
  unfold bulkRecipients
  -- `cases h : e` already substitutes `e` in the goal, so `h` itself
  -- is not needed in either arm's rewrite.
  cases h : es.base.balances[r]? with
  | none   => simp
  | some bm =>
    simp only [Option.getD_some]
    exact List.filter_congr (fun p _ => by by_cases hp : p.1 = excluded <;> simp [hp])

/-! ## Per-bulk-action sub-step decomposition

For `distributeOthers r exclude amount`, the sub-steps are one
per non-excluded actor at resource `r`.  For
`proportionalDilute r exclude totalReward`, the sub-steps are
one per non-excluded actor with credit
`totalReward * v / sumOthers`.

The decomposition's *length* is exactly the number of non-
excluded actors at the resource, capped at
`maxRecipientsPerBulkAction`. -/

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
  -- The recipients, in the order the LAW folds them; see
  -- `bulkRecipients_eq_law_list`.
  let capped := (bulkRecipients es r excluded).take maxRecipientsPerBulkAction
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
          -- Balance cells ride the amount head; this must stay the
          -- exact byte form `getCellValue` produces or the proof
          -- stops verifying against the pre-state commit.
          cellValue :=
            ByteArray.mk (Encoding.encodeAmount p.2).toArray,
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
  let nonExcluded := bulkRecipients es r excluded
  let sumOthers : Nat :=
    nonExcluded.foldl (fun acc p => acc + p.2) 0
  let capped := nonExcluded.take maxRecipientsPerBulkAction
  capped.zipIdx.map (fun (p, i) =>
    let credit := if sumOthers = 0 then 0 else totalReward * p.2 / sumOthers
    { parentAction := .proportionalDilute r excluded totalReward,
      subStepIdx := i,
      affectedActor := p.1,
      preBalance := p.2,
      postBalance := p.2 + credit,
      cellProof :=
        { cellTag := CellTag.balance r p.1,
          -- Balance cells ride the amount head; this must stay the
          -- exact byte form `getCellValue` produces or the proof
          -- stops verifying against the pre-state commit.
          cellValue :=
            ByteArray.mk (Encoding.encodeAmount p.2).toArray,
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

/-- The sub-step list is bounded by `maxRecipientsPerBulkAction`. -/
theorem subSteps_length_bound (es : ExtendedState) (action : Action) :
    (Action.subSteps es action).length ≤ maxRecipientsPerBulkAction := by
  unfold Action.subSteps
  cases action with
  | distributeOthers r exc amt =>
    unfold Action.distributeOthers_subSteps
    simp only [List.length_map, List.length_zipIdx]
    -- After `take maxRecipientsPerBulkAction`, length is at
    -- most that bound.
    exact List.length_take_le _ _
  | proportionalDilute r exc tr =>
    unfold Action.proportionalDilute_subSteps
    simp only [List.length_map, List.length_zipIdx]
    exact List.length_take_le _ _
  | _ => simp [List.length_nil, Nat.zero_le]


/-! ## The DoS cap versus the law

`maxRecipientsPerBulkAction` truncates the decomposition.  The law it
decomposes does NOT truncate: `Laws.distributeOthers`'s precondition is
`amount > 0` alone, so it credits every non-excluded actor however many
there are.

The two therefore agree exactly when the recipient list fits the cap,
and the theorems below carry that as a hypothesis rather than hiding
it.  Above the cap the decomposition is a proper prefix of the law's
effect, which means a bulk action with more than
`maxRecipientsPerBulkAction` recipients **cannot be adjudicated** —
the game would settle on a post-state the L2 never produced.

That is a gap in the ACTION layer, not in this module: an action the
L1 cannot adjudicate should not be admissible on L2.  Closing it means
a recipient bound in the admission gate (or the law's precondition),
which is a consensus change; `docs/audits/19-findings-and-followups.md`
carries it.  `faultproof-substep`'s cap test exhibits the divergence so
it cannot be forgotten. -/

/-- The decomposition covers every recipient exactly when the list
    fits the cap. -/
theorem subSteps_length_eq_of_within_cap
    (es : ExtendedState) (r : ResourceId) (excluded : ActorId) (amount : Amount)
    (h : (bulkRecipients es r excluded).length ≤ maxRecipientsPerBulkAction) :
    (Action.distributeOthers_subSteps es r excluded amount).length
      = (bulkRecipients es r excluded).length := by
  unfold Action.distributeOthers_subSteps
  simp only [List.length_map, List.length_zipIdx]
  rw [List.length_take]
  exact Nat.min_eq_right h

/-! ## The sub-step write set

A sub-step writes exactly one cell: the recipient's balance.  The
parent step owns the nonce and the budget, so a sub-step's write set is
a singleton — which is what makes the bisection able to terminate on
one, and what bounds the opening bundle it has to carry. -/

/-- The cells one sub-step writes: the recipient's balance and nothing
    else. -/
def SubStep.writeCells (r : ResourceId) (ss : SubStep) : List CellTag :=
  [.balance r ss.affectedActor]

/-- A sub-step's write set is a singleton, so a bisection terminating
    on one carries a single opening.

    What still owes a proof before the ordered fold can consume these:
    that distinct sub-steps write DISTINCT cells.  It is true — the
    recipients are a `Std.TreeMap`'s keys, which are pairwise
    distinct — but core states that as `Pairwise (compare · · ≠ .eq)`
    over `keys` rather than as `Nodup` over `toList.map Prod.fst`, so
    it needs the same bridge `stateCellTags_nodup` builds.  Without it
    a duplicate recipient would make the second opening stale and the
    fold reject. -/
theorem SubStep.writeCells_length (r : ResourceId) (ss : SubStep) :
    (ss.writeCells r).length = 1 := rfl

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
example : maxRecipientsPerBulkAction = 256 := rfl

end FaultProof
end LegalKernel
