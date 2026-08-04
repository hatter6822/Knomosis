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
import LegalKernel.FaultProof.StateCellsInjective

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Encoding

/-! ## DoS bound -/

/-- Maximum recipients per bulk action (Workstream H §2).

    **One definition, and it lives in the LAW.**  `Laws.BulkBound`
    owns it because the bulk laws' preconditions enforce it: above the
    bound `step_impl` is a no-op, so the decomposition covers the
    law's effect by construction rather than by convention.  Two other
    modules used to hold their own copy of the number — this one and
    `StepVMCoherence` — and a cap that must agree with two others,
    checked by nothing, is how a DoS bound drifts. -/
abbrev maxRecipientsPerBulkAction : Nat := Laws.maxRecipientsPerBulkAction

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
    and the decomposition traverse.

    A thin lift of `Laws.bulkRecipients` to `ExtendedState`, not a
    parallel definition: the order is consensus, so the fault proof
    must read the law's list rather than rebuild something that
    happens to agree today. -/
def bulkRecipients (es : ExtendedState) (r : ResourceId) (excluded : ActorId) :
    List (ActorId × Amount) :=
  Laws.bulkRecipients es.base r excluded

/-- **The decomposition traverses exactly the law's list, in the law's
    order** — spelled out as the concrete filter both laws now fold.

    Both bulk laws *call* `Laws.bulkRecipients`, so an order or
    membership divergence between the law and the decomposition is no
    longer expressible; this theorem is what pins the shared list to a
    concrete traversal, so a future edit to `Laws.bulkRecipients` that
    changed which entries it keeps would surface here rather than
    silently move consensus.  Note both conjuncts: the excluded actor
    is dropped, and so is any entry whose balance is zero (which has no
    leaf in the state-commitment tree — see `Laws.bulkRecipients`). -/
theorem bulkRecipients_eq_law_list
    (es : ExtendedState) (r : ResourceId) (excluded : ActorId) :
    bulkRecipients es r excluded
      = (es.base.balances[r]?.getD ∅).toList.filter
          (fun kv => kv.1 != excluded && kv.2 != 0) := rfl

/-! ### A recipient is exactly a live balance LEAF

`Laws.bulkRecipients` drops zero-valued entries, and the reason is not
a policy preference: the state-commitment root cannot see them.
`stateCellEntries` filters out cells whose value is the canonical
absent one, and `canonicalAbsentValue (.balance _ _)` IS
`encodeAmount 0` — so an actor whose `Std.TreeMap` entry reads zero
has no leaf, and a state holding that entry is root-identical to one
holding nothing for that actor.

The two theorems below say the filter lands exactly on that boundary,
so the rationale is a theorem rather than a comment.  Without them the
claim "the recipients are the live balance cells" would be prose the
code merely happens to satisfy. -/

/-- A zero balance makes its cell canonically absent.  **Free** — no
    amount bound, because it only evaluates the encoder at `0`. -/
theorem balanceCell_absent_of_balance_zero (es : ExtendedState)
    (r : ResourceId) (a : ActorId)
    (h : LegalKernel.getBalance es.base r a = 0) :
    getCellValue es (.balance r a) = canonicalAbsentValue (.balance r a) := by
  show ByteArray.mk
    (Encoding.encodeAmount (LegalKernel.getBalance es.base r a)).toArray = _
  rw [h]
  rfl

/-- A balance cell is canonically ABSENT exactly when the balance is
    zero.

    **The bound is on the converse only**, and that asymmetry is the
    whole content of finding C-3.  `encodeAmount` is a 16-byte
    little-endian body, so it truncates modulo `2^128`: without a
    bound, a balance of a nonzero multiple of `2^128` also encodes as
    `encodeAmount 0` and its cell reads absent, which is precisely the
    residual the zero filter does not close.  The hypothesis is the
    narrow, per-cell form of `ExtendedState.CanonicalBounds.base_amt`
    rather than the whole bundle, so a consumer sees exactly what it
    needs.  The free direction is
    `balanceCell_absent_of_balance_zero`. -/
theorem balanceCell_absent_iff_balance_zero (es : ExtendedState)
    (r : ResourceId) (a : ActorId)
    (h_amt : LegalKernel.getBalance es.base r a < 256 ^ 32) :
    getCellValue es (.balance r a) = canonicalAbsentValue (.balance r a) ↔
      LegalKernel.getBalance es.base r a = 0 := by
  constructor
  · intro h
    have h' : Encoding.encodeAmount (LegalKernel.getBalance es.base r a)
        = Encoding.encodeAmount 0 := by
      have hd := congrArg (fun b => b.data.toList) h
      simp only [getCellValue, canonicalAbsentValue] at hd
      simpa using hd
    exact Encoding.encodeAmount_injective _ _ h_amt (Nat.pow_pos (by decide)) h'
  · exact balanceCell_absent_of_balance_zero es r a

/-- The lookup form of `getBalance`, so the membership arguments below
    reason about `bm[a]?` instead of about the outer-map match. -/
private theorem getBalance_eq_lookup (es : ExtendedState)
    (r : ResourceId) (a : ActorId) :
    LegalKernel.getBalance es.base r a
      = (es.base.balances[r]?.getD ∅)[a]?.getD 0 := by
  unfold LegalKernel.getBalance
  cases es.base.balances[r]? with
  | none => rfl
  | some bm => rfl

/-- **Every live balance leaf at `r` other than `excluded` IS a
    recipient** — the COMPLETENESS direction, and it carries **no
    amount bound**.

    This is the half the bulk-adjudicability argument needs: it says
    the fold cannot miss a cell the root observes, so a verifier
    enumerating the live leaves under `r` enumerates exactly the actors
    the law credits.  It is bound-free because it only needs
    `getBalance = 0 → cell absent` (contrapositively), which evaluates
    the encoder at `0` and never inverts it.

    Its converse — a recipient's cell is live — is where the `2^128`
    truncation bites, and `exists_mem_bulkRecipients_iff_cell_live`
    carries the bound for it. -/
theorem mem_bulkRecipients_of_cell_live (es : ExtendedState)
    (r : ResourceId) (excluded : ActorId) (a : ActorId)
    (h_live : getCellValue es (.balance r a) ≠ canonicalAbsentValue (.balance r a))
    (h_ne : a ≠ excluded) :
    ∃ v, (a, v) ∈ bulkRecipients es r excluded := by
  have hnz : LegalKernel.getBalance es.base r a ≠ 0 :=
    fun h => h_live (balanceCell_absent_of_balance_zero es r a h)
  refine ⟨LegalKernel.getBalance es.base r a, ?_⟩
  refine (Laws.mem_bulkRecipients_iff _ r excluded _).mpr ⟨?_, h_ne, hnz⟩
  refine Std.TreeMap.mem_toList_iff_getElem?_eq_some.mpr ?_
  rw [getBalance_eq_lookup es r a] at hnz ⊢
  cases hv : (es.base.balances[r]?.getD ∅)[a]? with
  | none => simp [hv] at hnz
  | some w => simp

/-- **The recipients are exactly the live balance leaves at `r`, minus
    `excluded`.**

    This is the property that makes a bulk step's post-state a function
    of the pre-state ROOT: everything the fold credits is something the
    root observes, and everything the root observes at `r` (other than
    `excluded`) is credited.  Before the zero filter the left-to-right
    direction failed — `distributeOthers` paid an actor with no leaf —
    and two root-identical pre-states reached different post-roots.

    Only the LEFT-to-right direction needs `h_amt`; the completeness
    half is `mem_bulkRecipients_of_cell_live`, which is unconditional. -/
theorem exists_mem_bulkRecipients_iff_cell_live (es : ExtendedState)
    (r : ResourceId) (excluded : ActorId) (a : ActorId)
    (h_amt : LegalKernel.getBalance es.base r a < 256 ^ 32) :
    (∃ v, (a, v) ∈ bulkRecipients es r excluded) ↔
      (getCellValue es (.balance r a) ≠ canonicalAbsentValue (.balance r a)
        ∧ a ≠ excluded) := by
  constructor
  · rintro ⟨v, hv⟩
    obtain ⟨hmem, hne, hnz⟩ := (Laws.mem_bulkRecipients_iff _ r excluded (a, v)).mp hv
    have hlook : (es.base.balances[r]?.getD ∅)[a]? = some v :=
      Std.TreeMap.mem_toList_iff_getElem?_eq_some.mp hmem
    refine ⟨?_, hne⟩
    rw [ne_eq, balanceCell_absent_iff_balance_zero es r a h_amt,
      getBalance_eq_lookup es r a, hlook]
    exact hnz
  · rintro ⟨h_live, hne⟩
    exact mem_bulkRecipients_of_cell_live es r excluded a h_live hne

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
      -- The canonical builder, not a hand-rolled record: it reads the
      -- value through `getCellValue` (so the byte form cannot drift
      -- from what the commit observes) and attaches the cell's SMT
      -- opening (so an L1 holding only the root can check it).  The
      -- hand-rolled form carried `encodeAmount p.2` and a comment
      -- warning that it must stay equal to `getCellValue` — a
      -- convention where a call suffices.
      cellProof := buildCellProofWithOpening es (CellTag.balance r p.1) })

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
      -- The canonical builder, not a hand-rolled record: it reads the
      -- value through `getCellValue` (so the byte form cannot drift
      -- from what the commit observes) and attaches the cell's SMT
      -- opening (so an L1 holding only the root can check it).  The
      -- hand-rolled form carried `encodeAmount p.2` and a comment
      -- warning that it must stay equal to `getCellValue` — a
      -- convention where a call suffices.
      cellProof := buildCellProofWithOpening es (CellTag.balance r p.1) })

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


/-! ## The cap and the law agree

`maxRecipientsPerBulkAction` truncates the decomposition, because the
L1 cannot carry an unbounded bisection.  The LAW used to truncate
nothing — `Laws.distributeOthers`'s precondition was `amount > 0`
alone — so a bulk action with more recipients than the cap had a
post-state the game could not reach: a terminal step over it would
settle on a root the L2 never published.

That is closed at the source.  `Laws.BulkBounded` is now a conjunct of
both bulk preconditions, and `step_impl` is
`if pre then apply_impl else id`, so above the bound the step is a
no-op on both sides.  The decomposition therefore covers the law's
effect in every admissible case, and in every inadmissible one there
is no effect to cover — which is what
`subSteps_complete_of_pre` and `distributeOthers_noop_above_cap` say
from the two directions. -/

/-- **Below the bound the decomposition covers every recipient.** -/
theorem subSteps_length_eq_of_within_cap
    (es : ExtendedState) (r : ResourceId) (excluded : ActorId) (amount : Amount)
    (h : (bulkRecipients es r excluded).length ≤ maxRecipientsPerBulkAction) :
    (Action.distributeOthers_subSteps es r excluded amount).length
      = (bulkRecipients es r excluded).length := by
  unfold Action.distributeOthers_subSteps
  simp only [List.length_map, List.length_zipIdx]
  rw [List.length_take]
  exact Nat.min_eq_right h

/-- **The law's own precondition supplies the bound.**  A step the
    runtime admits is one the decomposition covers completely — no
    side condition for a caller to discharge, because the law already
    did. -/
theorem subSteps_complete_of_pre
    (es : ExtendedState) (r : ResourceId) (excluded : ActorId) (amount : Amount)
    (h : (Laws.distributeOthers r excluded amount).pre es.base) :
    (Action.distributeOthers_subSteps es r excluded amount).length
      = (bulkRecipients es r excluded).length :=
  subSteps_length_eq_of_within_cap es r excluded amount h.2.1

/-- **And above the bound the law does nothing.**  Fail-closed: the
    step VM is never asked to adjudicate an advance it cannot
    decompose, because there is no advance.

    This is the direction that used to be false, and the one a test
    would have caught only by looking for it: before the bound, the
    law credited every recipient while the decomposition stopped at
    256. -/
theorem distributeOthers_noop_above_cap
    (s : State) (r : ResourceId) (excluded : ActorId) (amount : Amount)
    (h : maxRecipientsPerBulkAction < (Laws.bulkRecipients s r excluded).length) :
    step_impl s (Laws.distributeOthers r excluded amount) = s := by
  unfold step_impl
  rw [if_neg (fun hpre => absurd hpre.2.1 (Nat.not_le.mpr h))]

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
    on one carries a single opening. -/
theorem SubStep.writeCells_length (r : ResourceId) (ss : SubStep) :
    (ss.writeCells r).length = 1 := rfl

/-- **Distinct sub-steps write distinct cells.**  The ordered fold
    opens each cell against the root the previous write produced, so a
    repeated recipient would make the second opening stale and the fold
    would reject a step an honest sequencer defended correctly.

    `Laws.bulkRecipients_nodup_keys` is the substance; this is it in
    the form the decomposition uses. -/
theorem subSteps_affectedActors_nodup
    (es : ExtendedState) (r : ResourceId) (excluded : ActorId) (amount : Amount) :
    ((Action.distributeOthers_subSteps es r excluded amount).map
      (fun ss => ss.affectedActor)).Nodup := by
  -- The actor column of `zipIdx`-then-build is the original key
  -- column: indexing adds a component the projection drops.
  have h_col : ∀ {α β : Type} (f : α → β) (l : List α) (k : Nat),
      ((l.zipIdx k).map (fun p => f p.1)) = l.map f := by
    intro α β f l
    induction l with
    | nil => intro _; rfl
    | cons a t ih => intro k; simp [List.zipIdx_cons, ih]
  unfold Action.distributeOthers_subSteps
  simp only [List.map_map, Function.comp_def]
  rw [h_col Prod.fst]
  exact List.Pairwise.sublist ((List.take_sublist _ _).map _)
    (Laws.bulkRecipients_nodup_keys es.base r excluded)

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
