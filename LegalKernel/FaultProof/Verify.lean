-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Verify — `verifyCellProof` and friends
(Workstream H §12 / WUs H.3.3 + H.3.4).

The L1 step VM consumes cell proofs (`CellProof`s) for every
cell the step reads or writes.  This module specifies how those
proofs are *verified* against the committed state root.

**Witness-state-based verification** (first-pass design,
mathematically sound, optimisable to SMT for L1 gas).

A `CellProof` carries a witness `ExtendedState` plus the cell
tag and value.  Verification:
  1. Recommit the witness state.
  2. Check the recommit equals the public state root.
  3. Check the witness state has the claimed cell value at the
     claimed tag.

Under collision-freeness of `hashBytes` on the pre-images below, condition 1 plus
`commitExtendedState`'s injectivity (theorem #220) makes the
witness state unique up to extensional equality.  Condition 3
then authoritatively binds the cell value to the underlying
state.

**Helper functions for the L1 step VM (WU H.1.2 contract):**

  * `getCellValue es tag` — read a single cell from a state.
  * `setCell es tag value` — write a single cell to a state.
  * `isCellAbsent es tag` — decidable predicate detecting an
    absent cell.
  * `canonicalAbsentValue tag` — canonical "absent" marker.
  * `buildCellProof es tag` — construct the canonical proof
    for a cell at a state.

**Headline theorems (#221 + #222 + #223):**

  * `verifyCellProof_complete` — the canonical proof for any
    cell at any state always verifies against the state's
    commit.  Unconditional.
  * `verifyCellProof_sound` — a verifying proof's witness state
    has the claimed cell value at the claimed tag.  Unconditional:
    the verifier's own two checks establish it.
  * `verifyCellProof_witness_unique_under_collision_free` — under
    collision-freeness on the commitment chain's hash pre-images,
    that witness is the ONLY state behind the published root, so a
    responder cannot substitute a different cell value.
  * `updateCommitment_agrees_with_setCell` — recomputing the
    commit after writing one cell agrees with `commitExtendedState`
    on the post-state.

This module is **not** part of the trusted computing base.
Theorems hold without `sorry` and depend only on the standard
Lean built-ins (`propext`, `Quot.sound`, `Classical.choice`).
-/

import LegalKernel.Authority.LocalPolicy
import LegalKernel.Bridge.Eip712
import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.CellValue
import LegalKernel.FaultProof.Commit

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding

/-! ## `verifyCellProof` (§12.3.3) -/

/-- Verify a single cell proof against the committed state root.
    Two checks:
      1. The witness state's recommit equals the public commit.
      2. The witness state's cell at the proof's tag equals the
         proof's claimed value.

    Both checks are decidable; the conjunction is decidable. -/
def verifyCellProof (commit : StateCommit) (proof : CellProof) : Bool :=
  decide (commitExtendedState proof.witnessState = commit) &&
  decide (getCellValue proof.witnessState proof.cellTag = proof.cellValue)

/-- Verify every cell proof in a bundle against the committed
    state root.  All proofs must verify. -/
def verifyCellProofs (commit : StateCommit) (bundle : CellProofBundle) :
    Bool :=
  bundle.proofs.all (fun p => verifyCellProof commit p)

/-- Named decidable instance for `verifyCellProof`. -/
instance instDecidableVerifyCellProof
    (commit : StateCommit) (proof : CellProof) :
    Decidable (verifyCellProof commit proof = true) :=
  inferInstance

/-- Named decidable instance for `verifyCellProofs`. -/
instance instDecidableVerifyCellProofs
    (commit : StateCommit) (bundle : CellProofBundle) :
    Decidable (verifyCellProofs commit bundle = true) :=
  inferInstance

/-! ## Determinism -/

theorem verifyCellProof_deterministic
    (c₁ c₂ : StateCommit) (p₁ p₂ : CellProof)
    (h_c : c₁ = c₂) (h_p : p₁ = p₂) :
    verifyCellProof c₁ p₁ = verifyCellProof c₂ p₂ := by rw [h_c, h_p]

theorem verifyCellProofs_deterministic
    (c₁ c₂ : StateCommit) (b₁ b₂ : CellProofBundle)
    (h_c : c₁ = c₂) (h_b : b₁ = b₂) :
    verifyCellProofs c₁ b₁ = verifyCellProofs c₂ b₂ := by rw [h_c, h_b]

/-! ## #221 — Verifier completeness (unconditional) -/

/-- The canonical cell proof for any cell at any state always
    verifies against that state's commit.  Unconditional —
    no collision-freeness hypothesis needed for completeness. -/
theorem verifyCellProof_complete (es : ExtendedState) (tag : CellTag) :
    verifyCellProof (commitExtendedState es) (buildCellProof es tag) = true := by
  unfold verifyCellProof buildCellProof
  -- The two `decide` checks reduce by definitional equality.
  simp

/-- Empty-bundle verification trivially succeeds. -/
theorem verifyCellProofs_empty (commit : StateCommit) :
    verifyCellProofs commit CellProofBundle.empty = true := rfl

/-- Singleton-bundle verification reduces to per-proof. -/
theorem verifyCellProofs_singleton
    (commit : StateCommit) (p : CellProof) :
    verifyCellProofs commit { proofs := [p] } =
    verifyCellProof commit p := by
  unfold verifyCellProofs
  simp

/-- Bundle-level completeness corollary: every bundle of canonical
    proofs at the same state verifies. -/
theorem verifyCellProofs_complete_for_canonical_bundle
    (es : ExtendedState) (tags : List CellTag) :
    verifyCellProofs (commitExtendedState es)
      { proofs := tags.map (fun t => buildCellProof es t) } = true := by
  unfold verifyCellProofs
  simp only [List.all_eq_true, List.mem_map]
  intro p hp
  obtain ⟨t, _, rfl⟩ := hp
  exact verifyCellProof_complete es t

/-! ## #222 — Verifier soundness under collision-freeness on the level's pre-images -/

/-- A verifying proof's witness state recommits to the public
    commit.  Direct from the verifier's first check. -/
theorem verifyCellProof_witness_recommits
    (commit : StateCommit) (proof : CellProof)
    (h : verifyCellProof commit proof = true) :
    commitExtendedState proof.witnessState = commit := by
  unfold verifyCellProof at h
  -- `h : decide (...) && decide (...) = true`
  rw [Bool.and_eq_true] at h
  obtain ⟨h₁, _⟩ := h
  exact decide_eq_true_eq.mp h₁

/-- A verifying proof's witness state has the claimed cell value
    at the claimed tag.  Direct from the verifier's second
    check. -/
theorem verifyCellProof_witness_has_cell_value
    (commit : StateCommit) (proof : CellProof)
    (h : verifyCellProof commit proof = true) :
    getCellValue proof.witnessState proof.cellTag = proof.cellValue := by
  unfold verifyCellProof at h
  rw [Bool.and_eq_true] at h
  obtain ⟨_, h₂⟩ := h
  exact decide_eq_true_eq.mp h₂

/-- #222 — Existence: a verifying proof witnesses a state whose
    cell at the claimed tag has the claimed value.

    The witness state is the proof's `witnessState` field, and the
    verifier's own two checks establish both conjuncts, so this
    direction needs no collision-resistance hypothesis at all.  The
    hypothesis that makes the witness *unique* is stated separately
    by `verifyCellProof_witness_unique_under_collision_free` below —
    that is the property a fault-proof consumer actually relies on,
    and carrying it as an unused argument here stated nothing. -/
theorem verifyCellProof_sound
    (commit : StateCommit) (proof : CellProof)
    (h_verify : verifyCellProof commit proof = true) :
    ∃ es, commitExtendedState es = commit ∧
          getCellValue es proof.cellTag = proof.cellValue :=
  ⟨proof.witnessState,
   verifyCellProof_witness_recommits commit proof h_verify,
   verifyCellProof_witness_has_cell_value commit proof h_verify⟩

/-- #222 — Uniqueness: any state that commits to the same root as a
    verifying proof is extensionally equal to that proof's witness.

    This is the operational content of cell-proof soundness: an
    adversarial responder cannot exhibit a *different* state behind
    the same published root and thereby claim a different cell
    value.  It rests on `commitExtendedState`'s injectivity
    (theorem #220 / EI.8), which is where the collision-resistance
    hypothesis genuinely does work — scoped, as everywhere else, to
    the pre-images the commitment chain actually hashes. -/
theorem verifyCellProof_witness_unique_under_collision_free
    (commit : StateCommit) (proof : CellProof) (es : ExtendedState)
    (h_cf : Bridge.CollisionFreeOn
      (extendedStateCommitPreimages es proof.witnessState)
      LegalKernel.Runtime.hashBytes)
    (h_b₁ : ExtendedState.CanonicalBounds es)
    (h_b₂ : ExtendedState.CanonicalBounds proof.witnessState)
    (h_verify : verifyCellProof commit proof = true)
    (h_commit : commitExtendedState es = commit) :
    ExtendedState.extEq es proof.witnessState :=
  commitExtendedState_subcommits_extensional_eq_under_collision_free
    es proof.witnessState h_cf h_b₁ h_b₂
    (h_commit.trans
      (verifyCellProof_witness_recommits commit proof h_verify).symm)

/-! ## #223 — Update commitment agrees with setCell

The recompute-commitment-after-cell-write operation must agree
with `commitExtendedState` on the post-state.  We establish this
via a definitional reduction: `updateCommitment` is just
`commitExtendedState ∘ setCell`. -/

/-- Compute the new commitment after writing one cell.  Defined
    directly via `setCell` + `commitExtendedState`; the
    agreement theorem is `rfl`. -/
def updateCommitment (proof : CellProof) (newValue : ByteArray) :
    StateCommit :=
  commitExtendedState (setCell proof.witnessState proof.cellTag newValue)

/-- #223 — `updateCommitment` agrees with `commitExtendedState`
    on the post-cell-write state.  By construction. -/
theorem updateCommitment_agrees_with_setCell
    (es : ExtendedState) (tag : CellTag) (newValue : ByteArray) :
    updateCommitment (buildCellProof es tag) newValue =
    commitExtendedState (setCell es tag newValue) := rfl

/-! ## Non-membership cell proofs (#260, H.3.4) -/

/-- A canonical-absent cell proof verifies against any state's
    commit at a tag where the state has no cell.  The witness is
    the state itself; the proof's value matches the canonical
    absent marker by `isCellAbsent`. -/
theorem verifyCellProof_complete_for_absent_cell
    (es : ExtendedState) (tag : CellTag)
    (h_absent : isCellAbsent es tag) :
    verifyCellProof (commitExtendedState es)
      { cellTag := tag,
        cellValue := canonicalAbsentValue tag,
        witnessState := es } = true := by
  unfold verifyCellProof
  -- (1) commitExtendedState witness = commit: rfl
  -- (2) getCellValue witness tag = canonicalAbsentValue tag: from h_absent
  unfold isCellAbsent at h_absent
  simp [h_absent]

/-! ## Smoke checks -/

/-- Spot-check: an empty state's commit verifies the canonical
    proof for any tag. -/
example (tag : CellTag) :
    verifyCellProof (commitExtendedState ExtendedState.empty)
      (buildCellProof ExtendedState.empty tag) = true :=
  verifyCellProof_complete _ _

end FaultProof
end LegalKernel
