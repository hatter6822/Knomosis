/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.TypedCellProof — read-only vs read-write
proof distinction (Workstream H WU H.3.5).

The L1 step VM treats read-only cells (verified but not commitment-
updated) differently from read-write cells (verified AND
commitment-updated).  This distinction:

  * Saves L1 gas: read-only proofs need only `verifyCellProof`,
    not `updateCommitment`.
  * Tightens cross-stack equivalence: the Lean and Solidity
    sides must agree on which cells are read-only.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.StepVariants
import LegalKernel.FaultProof.Verify

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority

/-! ## `TypedCellProof` -/

/-- A typed cell proof distinguishing read-only from read-write
    access modes.  Read-only proofs verify the cell value at the
    pre-state commit; read-write proofs additionally carry the
    new (post-state) cell value. -/
inductive TypedCellProof
  /-- Read-only: cell value is consulted but unchanged after step. -/
  | readOnly  (proof : CellProof)
  /-- Read-write: cell value is consulted and written.  The
      `newValue` is the post-step value. -/
  | readWrite (proof : CellProof) (newValue : ByteArray)
  deriving Repr

/-- A typed cell proof bundle: one per touched cell, tagged by
    its access mode. -/
structure TypedCellProofBundle where
  /-- The typed proofs in canonical order. -/
  proofs : List TypedCellProof
  deriving Repr

/-- Project a `TypedCellProof` to its underlying `CellProof`. -/
def TypedCellProof.cellProof : TypedCellProof → CellProof
  | .readOnly p     => p
  | .readWrite p _  => p

/-- True iff the proof is a read-only proof. -/
def TypedCellProof.isReadOnly : TypedCellProof → Bool
  | .readOnly _     => true
  | .readWrite _ _  => false

/-- True iff the proof is a read-write proof. -/
def TypedCellProof.isReadWrite : TypedCellProof → Bool
  | .readOnly _     => false
  | .readWrite _ _  => true

/-! ## `verifyTypedCellProofs`

A typed proof bundle verifies iff:
  * Every underlying `CellProof` verifies via `verifyCellProof`.
  * Every read-only proof's `cellTag` is in `Action.readOnlyCells`.
  * Every read-write proof's `cellTag` is in `Action.writeCells`. -/

/-- Verify a typed proof bundle against the committed state root
    plus the action's declared read-only / write cell sets. -/
def verifyTypedCellProofs
    (commit : StateCommit) (action : Action) (signer : ActorId)
    (bundle : TypedCellProofBundle) : Bool :=
  bundle.proofs.all (fun p =>
    verifyCellProof commit p.cellProof &&
    (match p with
     | .readOnly cp =>
       decide (cp.cellTag ∈ Action.readOnlyCells action signer)
     | .readWrite cp _ =>
       decide (cp.cellTag ∈ Action.writeCells action signer)))

/-- Decidability of `verifyTypedCellProofs`. -/
instance instDecidableVerifyTypedCellProofs
    (commit : StateCommit) (action : Action) (signer : ActorId)
    (bundle : TypedCellProofBundle) :
    Decidable (verifyTypedCellProofs commit action signer bundle = true) :=
  inferInstance

/-! ## Theorems -/

/-- Build the canonical typed proof bundle for an action.
    Read-only cells get `.readOnly` proofs; write cells get
    `.readWrite` proofs with the post-state value. -/
def buildTypedCellProofs (es : ExtendedState) (st : SignedAction) :
    TypedCellProofBundle :=
  let readOnly  := (Action.readOnlyCells st.action st.signer).map
                     (fun t => TypedCellProof.readOnly (buildCellProof es t))
  let readWrite := (Action.writeCells st.action st.signer).map
                     (fun t =>
                       TypedCellProof.readWrite
                         (buildCellProof es t)
                         (getCellValue es t))  -- post-value placeholder
  { proofs := readOnly ++ readWrite }

/-- Helper: a typed proof's underlying CellProof verifies iff
    the typed proof is canonical at a state. -/
private theorem typed_canonical_verifies_inner
    (es : ExtendedState) (t : CellTag) (kind : Bool) :
    verifyCellProof (commitExtendedState es)
      (if kind then
         TypedCellProof.cellProof (.readWrite (buildCellProof es t) (getCellValue es t))
       else
         TypedCellProof.cellProof (.readOnly (buildCellProof es t))) = true := by
  cases kind with
  | true  =>
    show verifyCellProof (commitExtendedState es) (buildCellProof es t) = true
    exact verifyCellProof_complete es t
  | false =>
    show verifyCellProof (commitExtendedState es) (buildCellProof es t) = true
    exact verifyCellProof_complete es t

/-- #262 — `verifyTypedCellProofs` of the canonical bundle is `true`
    (every cell proof verifies + every access mode matches the
    declared set).

    The proof structurally case-splits over the two branches of
    `buildTypedCellProofs` (readOnly cells from the `readOnlyCells`
    list, readWrite cells from the `writeCells` list).  Each
    branch satisfies its access-mode check by construction. -/
theorem verifyTypedCellProofs_complete
    (es : ExtendedState) (st : SignedAction) :
    verifyTypedCellProofs (commitExtendedState es) st.action st.signer
      (buildTypedCellProofs es st) = true := by
  unfold verifyTypedCellProofs buildTypedCellProofs
  simp only [List.all_eq_true, List.mem_append, List.mem_map]
  intro p hp
  rcases hp with ⟨t, ht_mem, h_eq⟩ | ⟨t, ht_mem, h_eq⟩
  · subst h_eq
    -- p = TypedCellProof.readOnly (buildCellProof es t)
    -- Goal: verifyCellProof commit p.cellProof && match p with ... = true
    have h_verify : verifyCellProof (commitExtendedState es)
                       (buildCellProof es t) = true :=
      verifyCellProof_complete es t
    -- The `match` reduces to readOnly-branch.
    show (verifyCellProof (commitExtendedState es) (buildCellProof es t) &&
          decide ((buildCellProof es t).cellTag ∈
                   Action.readOnlyCells st.action st.signer)) = true
    rw [h_verify]
    simp only [Bool.true_and, decide_eq_true_eq]
    show (buildCellProof es t).cellTag ∈ Action.readOnlyCells st.action st.signer
    -- (buildCellProof es t).cellTag = t by construction.
    show t ∈ Action.readOnlyCells st.action st.signer
    exact ht_mem
  · subst h_eq
    have h_verify : verifyCellProof (commitExtendedState es)
                       (buildCellProof es t) = true :=
      verifyCellProof_complete es t
    show (verifyCellProof (commitExtendedState es) (buildCellProof es t) &&
          decide ((buildCellProof es t).cellTag ∈
                   Action.writeCells st.action st.signer)) = true
    rw [h_verify]
    simp only [Bool.true_and, decide_eq_true_eq]
    show t ∈ Action.writeCells st.action st.signer
    exact ht_mem

end FaultProof
end LegalKernel
