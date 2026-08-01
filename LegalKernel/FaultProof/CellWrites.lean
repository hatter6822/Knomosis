-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.CellWrites — a step's writes as a `setCell`
chain, and the one lemma that carries the SMT machinery for all of
them.

`foldStateCellWrites_eq_commit_of_coherent` says a coherent chain of
single-cell writes folds the pre-state's published root into the
post-state's.  It is stated over an arbitrary `CellWriteChain`, which
is the right generality for the theorem and the wrong shape for a
caller: a per-variant proof would have to re-establish six coherence
conjuncts per link, and there are up to six links per variant across
twenty-five variants.

This module closes that gap once.  A step's writes are a list of
`(cell, value)` pairs; `canonicalCellChain` turns that list into the
chain whose intermediate states are the `setCell` results and whose
openings are the canonical ones; and
`fold_canonicalCellChain_eq_commit_applyCellWrites` says folding it
lands on the root of the state the writes produce.

What is left for a variant is then purely a statement about cell
VALUES — no SMT, no openings, no entry lists:

    ∀ t, getCellValue (applyCellWrites es ws) t
           = getCellValue (productionApplyBudget es st idx) t

and `commitExtendedState_eq_of_cells_agree` turns that into root
equality.  That the target is cell agreement rather than state
equality is not a convenience: the production advance and a `setCell`
chain insert the same bindings in different orders, and `Std.TreeMap`
is a balanced search tree with no extensional equality in Lean core,
so the two `ExtendedState`s are genuinely not provably equal.  They
do not need to be.

`docs/planning/state_root_merkleisation_plan.md` §4.
-/

import LegalKernel.FaultProof.CellStore
import LegalKernel.FaultProof.StateCellsInjective

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding

/-! ## A step's writes as a list -/

/-- One cell write: the cell and the value it takes. -/
abbrev CellWrite := CellTag × ByteArray

/-- Apply a write list in order.  The state a step's writes produce,
    read off the writes alone. -/
def applyCellWrites (es : ExtendedState) : List CellWrite → ExtendedState
  | []           => es
  | (t, v) :: ws => applyCellWrites (setCell es t v) ws

/-- **Writes are local, in bulk.**  A cell no write in the list names
    reads exactly as it did before.

    The list-level form of `getCellValue_setCell_ne`, and what every
    per-variant proof uses to dispose of the infinitely many cells a
    step does not touch. -/
theorem getCellValue_applyCellWrites_of_not_written :
    ∀ (ws : List CellWrite) (es : ExtendedState) (t : CellTag),
      (∀ w ∈ ws, w.1 ≠ t) →
      getCellValue (applyCellWrites es ws) t = getCellValue es t := by
  intro ws
  induction ws with
  | nil => intro _ _ _; rfl
  | cons w rest ih =>
    obtain ⟨t₀, v⟩ := w
    intro es t h
    show getCellValue (applyCellWrites (setCell es t₀ v) rest) t = _
    rw [ih (setCell es t₀ v) t (fun w' hw' => h w' (List.mem_cons_of_mem _ hw'))]
    exact getCellValue_setCell_ne es t t₀ v
      (fun he => h (t₀, v) List.mem_cons_self (he ▸ rfl))

/-- The value a written cell ends up holding: whatever `setCell` left
    there, provided no LATER write names the same cell.

    Stated with the read-back left to the caller because read-back is
    conditional — `setCell` decodes what it is handed, so a value
    outside the arm's encoder image is a no-op.  Composing this with
    `CellStore`'s per-kind read-back laws is what gives a variant its
    written values. -/
theorem getCellValue_applyCellWrites_of_written
    (pre : List CellWrite) (t : CellTag) (v : ByteArray) (post : List CellWrite)
    (es : ExtendedState) (h : ∀ w ∈ post, w.1 ≠ t) :
    getCellValue (applyCellWrites es (pre ++ (t, v) :: post)) t
      = getCellValue (setCell (applyCellWrites es pre) t v) t := by
  induction pre generalizing es with
  | nil => exact getCellValue_applyCellWrites_of_not_written post _ t h
  | cons w rest ih =>
    obtain ⟨t₀, v₀⟩ := w
    exact ih (setCell es t₀ v₀)

/-! ## The chain the writes induce

`CellWriteChain` carries the intermediate STATES and the openings
alongside the tags, because `foldStateCellWrites_eq_commit_of_coherent`
needs both.  Both are determined by the write list, so the chain is
derived rather than supplied. -/

/-- The chain a write list induces: each link's successor state is the
    `setCell` result and each link's opening is the canonical path of
    the state it opens against. -/
def canonicalCellChain (es : ExtendedState) : List CellWrite → CellWriteChain
  | []           => []
  | (t, v) :: ws =>
      (setCell es t v, t, buildStateCellProof es t)
        :: canonicalCellChain (setCell es t v) ws

/-- The chain ends where the writes land. -/
theorem chainLast_canonicalCellChain :
    ∀ (ws : List CellWrite) (es : ExtendedState),
      chainLast es (canonicalCellChain es ws) = applyCellWrites es ws := by
  intro ws
  induction ws with
  | nil => intro _; rfl
  | cons w rest ih =>
    obtain ⟨t, v⟩ := w
    intro es
    exact ih (setCell es t v)

/-! ## The side conditions

Three obligations per link, and each is a real hypothesis rather than
a technicality:

  * **Distinguishability.**  `smtRootListAux`'s depth-0 case collapses
    a bucket holding two entries, so a root over indistinguishable
    entries is not determined by them.  Required at every intermediate
    state, not just the endpoints.
  * **Key injectivity on live cells.**  Two live cells sharing an SMT
    key would make one cell's opening verify as the other's.  Scoped
    to cells that CONTRIBUTE an entry, because a tag can be enumerated
    while reading as canonically absent (`setBalance s r a 0` does
    exactly that) and an unscoped form would demand
    `smtCellKey t ≠ smtCellKey t` on a reachable state.
  * **Representation.**  That `buildStateCellProof`'s bitmask encoding
    expands to the canonical sibling path.  §2C left this pinned by
    `faultproof-smt-injective` rather than proved, so it is threaded
    as a hypothesis here exactly as
    `updateStateCellRoot_eq_commit_of_canonical` threads it — visible
    rather than assumed. -/

/-- What one link needs of the state it opens against. -/
structure CellWriteReady (es : ExtendedState) (t : CellTag) : Prop where
  /-- The state's entries are distinguishable below the SMT depth. -/
  distinct : BitsDistinctBelow smtDepth (stateCellEntries es)
  /-- No other live cell shares this cell's SMT key. -/
  keysInjective : ∀ t' ∈ stateCellTags es,
    getCellValue es t' ≠ canonicalAbsentValue t' → smtCellKey t' ≠ smtCellKey t
  /-- The built opening expands to the canonical path. -/
  expands : expandSiblings (buildStateCellProof es t)
    = canonicalSiblings smtDepth (stateCellEntries es) (smtCellKey t)
  /-- The built opening is shape-valid. -/
  wellFormed : (buildStateCellProof es t).isWellFormed = true

/-- Every link of a write list is ready, including the state the last
    write produces. -/
def CellWritesReady (es : ExtendedState) : List CellWrite → Prop
  | []           => BitsDistinctBelow smtDepth (stateCellEntries es)
  | (t, v) :: ws =>
      CellWriteReady es t
      ∧ CellWriteReady (setCell es t v) t
      ∧ CellWritesReady (setCell es t v) ws

/-- Readiness carries the distinguishability of the state it starts
    from, in both list shapes. -/
theorem CellWritesReady.distinctHead :
    ∀ {ws : List CellWrite} {es : ExtendedState}, CellWritesReady es ws →
      BitsDistinctBelow smtDepth (stateCellEntries es)
  | [],          _, h => h
  | (_, _) :: _, _, h => h.1.distinct

/-- ...and, inductively, of the state its writes end in.  This is what
    `commitExtendedState_eq_of_cells_agree` needs of the chain's own
    endpoint. -/
theorem CellWritesReady.distinctLast :
    ∀ (ws : List CellWrite) (es : ExtendedState), CellWritesReady es ws →
      BitsDistinctBelow smtDepth (stateCellEntries (applyCellWrites es ws)) := by
  intro ws
  induction ws with
  | nil => intro _ h; exact h
  | cons w rest ih =>
    obtain ⟨t, v⟩ := w
    intro es h
    exact ih (setCell es t v) h.2.2

/-! ## The canonical opening verifies

The completeness half of §3A, discharged from readiness rather than
re-derived per call site.  Both branches appear because a step writes
canonically-absent values routinely — crediting an actor who holds no
balance opens an absent cell, and that is the common case, not an edge
case. -/

/-- The canonical opening of a cell verifies against its own state's
    published root. -/
theorem verifyStateCellProof_buildStateCellProof
    (es : ExtendedState) (t : CellTag) (h : CellWriteReady es t) :
    verifyStateCellProof (commitExtendedState es) t (getCellValue es t)
      (buildStateCellProof es t) = true := by
  unfold verifyStateCellProof smtWalkFrom
  rw [h.wellFormed, h.expands, Bool.true_and, decide_eq_true_eq]
  by_cases h_abs : getCellValue es t = canonicalAbsentValue t
  · exact canonicalSiblings_verifies_absent es t h_abs h.keysInjective
  · refine canonicalSiblings_verifies_present es t ?_ h_abs h.distinct
    by_cases hm : t ∈ stateCellTags es
    · exact hm
    · exact absurd (getCellValue_of_not_mem es t hm) h_abs

/-! ## Coherence, once -/

/-- **The chain a write list induces is coherent.**

    This is where all six conjuncts of `ChainCoherent` are discharged.
    The off-cell one is the substantive step and it comes from
    locality: `getCellValue_setCell_ne` says the write disturbs no
    other cell's VALUE, and
    `dropKey_stateCellEntries_perm_of_agree_off` lifts that to the
    entry lists the update theorem compares. -/
theorem chainCoherent_canonicalCellChain :
    ∀ (ws : List CellWrite) (es : ExtendedState), CellWritesReady es ws →
      ChainCoherent es (canonicalCellChain es ws) := by
  intro ws
  induction ws with
  | nil => intro _ _; trivial
  | cons w rest ih =>
    obtain ⟨t, v⟩ := w
    intro es h
    obtain ⟨h_pre, h_post, h_rest⟩ := h
    refine ⟨h_pre.expands, ?_, h_pre.distinct, h_post.distinct,
      h_post.keysInjective, verifyStateCellProof_buildStateCellProof es t h_pre,
      ih (setCell es t v) h_rest⟩
    exact dropKey_stateCellEntries_perm_of_agree_off es (setCell es t v) t
      h_pre.distinct h_post.distinct
      (fun t' h_key => (getCellValue_setCell_ne es t' t v
        (fun he => h_key (by rw [he]))).symm)

/-- **A step's write bundle folds onto the root of the state its
    writes produce.**

    The bridge between "here is what the step writes" and "here is the
    number the L1 computes".  Everything SMT-shaped is discharged
    here; a per-variant obligation is what remains, and it mentions
    only `getCellValue`. -/
theorem fold_canonicalCellChain_eq_commit_applyCellWrites
    (ws : List CellWrite) (es : ExtendedState) (h : CellWritesReady es ws) :
    foldStateCellWrites (commitExtendedState es)
        (chainWrites es (canonicalCellChain es ws))
      = some (commitExtendedState (applyCellWrites es ws)) := by
  rw [← chainLast_canonicalCellChain ws es]
  exact foldStateCellWrites_eq_commit_of_coherent _ es
    (chainCoherent_canonicalCellChain ws es h)

/-- **The step-VM form.**  Folding a step's writes into the pre-state's
    published root computes the post-state's published root, where
    "post-state" is any state the writes agree with cell-for-cell.

    The cell-agreement hypothesis is deliberately not state equality:
    the production advance builds its maps in a different insertion
    order than a `setCell` chain does, and `Std.TreeMap` has no
    extensional equality in Lean core.  Cell agreement is both
    provable and exactly what the root observes. -/
theorem fold_canonicalCellChain_eq_commit_of_cells_agree
    (ws : List CellWrite) (es post : ExtendedState) (h : CellWritesReady es ws)
    (h_wf : BitsDistinctBelow smtDepth (stateCellEntries post))
    (h_agree : ∀ t : CellTag,
      getCellValue (applyCellWrites es ws) t = getCellValue post t) :
    foldStateCellWrites (commitExtendedState es)
        (chainWrites es (canonicalCellChain es ws))
      = some (commitExtendedState post) := by
  rw [fold_canonicalCellChain_eq_commit_applyCellWrites ws es h]
  exact congrArg some (commitExtendedState_eq_of_cells_agree _ post
    (CellWritesReady.distinctLast ws es h) h_wf h_agree)

end FaultProof
end LegalKernel
