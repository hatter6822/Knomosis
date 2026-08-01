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
import LegalKernel.FaultProof.Commit
import LegalKernel.FaultProof.StateCellsInjective
import LegalKernel.FaultProof.StepVariants

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

/-! ## The round-trip law

A step's write list sets each cell it names to the value the
production advance gives it — so every value written is one
`getCellValue` produced.  That is exactly the class the per-kind laws
above cover, and this composes them into the single statement the
write list needs.

The alternative would be for each of the twenty-five per-variant
proofs to pick the right per-kind law for each of its up-to-six cells.
This does it once, over all fifteen kinds. -/

/-- The three cells `setCell` cannot clear.

    Writing the canonical absent marker at these kinds is a NO-OP,
    not an erase: no `Action` removes a registry entry, un-consumes a
    deposit or retires a pending withdrawal inside a single step, so
    the write primitive declines to express it and the fault proof
    cannot be shown a step that does.

    `localPolicy` is deliberately absent from this list — writing its
    absent marker IS a real erase, because `revokeLocalPolicy` needs
    one. -/
def CellTag.appendOnly : CellTag → Bool
  | .registry _       => true
  | .bridgeConsumed _ => true
  | .bridgePending _  => true
  | _                 => false

/-- **`setCell` round-trips the reader's own output.**

    Writing the value a cell reads in one state into the same cell of
    another state makes it read that value there.  This is what makes
    a step's write list — "each declared cell, set to the value the
    advance gives it" — actually land what it names.

    Two side conditions, both real rather than technical:

      * `CanonicalBounds` on the SOURCE state, because `setCell`
        decodes the bytes it is handed and a value outside the arm's
        encoder image is a no-op.  This is the same hypothesis the
        commitment layer already carries, not a new one.
      * at the three `appendOnly` kinds, the target must not already
        hold a live entry the source lacks.  A step that would clear
        one is a step this primitive cannot express — see
        `CellTag.appendOnly`.

    Note what is NOT required: the two states need no relation beyond
    these.  In particular the target may be an intermediate state of a
    write chain, which is exactly how the per-variant proofs use it. -/
theorem getCellValue_setCell_getCellValue
    (target source : ExtendedState) (t : CellTag)
    (h_bounds : ExtendedState.CanonicalBounds source)
    (h_append : t.appendOnly = true →
      getCellValue source t = canonicalAbsentValue t →
      getCellValue target t = canonicalAbsentValue t) :
    getCellValue (setCell target t (getCellValue source t)) t = getCellValue source t := by
  cases t with
  | balance r a =>
    rw [getCellValue_balance]
    refine getCellValue_setCell_balance target r a _ ?_
    exact getBalance_lt_of_canonicalBounds source r a h_bounds
  | nonce a =>
    rw [getCellValue_nonce]
    exact getCellValue_setCell_nonce target a _
      (expectsNonce_lt_of_canonicalBounds source a h_bounds)
  | registry a =>
    cases h_r : source.registry[a]? with
    | none =>
      have h_v : getCellValue source (.registry a) = ByteArray.empty := by
        rw [getCellValue_registry, h_r]
      have h_t : getCellValue target (.registry a) = ByteArray.empty := h_append rfl h_v
      rw [h_v]
      -- Writing the absent marker is a no-op at this kind, so the
      -- target's own value is what stands — and `h_append` is exactly
      -- what says that value is already absent.
      show getCellValue (setCell target (.registry a) ByteArray.empty) (.registry a)
        = ByteArray.empty
      rw [show setCell target (.registry a) ByteArray.empty = target from by
        simp only [setCell]
        rw [if_pos (show ByteArray.empty.size = 0 from rfl)]]
      exact h_t
    | some pk =>
      have h_v : getCellValue source (.registry a) = keyCellValue pk := by
        rw [getCellValue_registry, h_r]
      rw [h_v]
      exact getCellValue_setCell_registry target a pk
        (registry_size_lt_of_canonicalBounds source a pk h_r h_bounds)
  | localPolicy a =>
    cases h_p : source.localPolicies[a]? with
    | none =>
      have h_v : getCellValue source (.localPolicy a) = ByteArray.empty := by
        rw [getCellValue_localPolicy, h_p]
      rw [h_v]
      exact getCellValue_setCell_localPolicy_absent target a
    | some p =>
      have h_v : getCellValue source (.localPolicy a) = policyCellValue p := by
        rw [getCellValue_localPolicy, h_p]
      rw [h_v]
      exact getCellValue_setCell_localPolicy target a p
        (localPolicy_bounded_of_canonicalBounds source a p h_p h_bounds)
  | bridgeConsumed d =>
    cases h_d : source.bridge.consumed[d]? with
    | none =>
      have h_v : getCellValue source (.bridgeConsumed d) = ByteArray.empty := by
        rw [getCellValue_bridgeConsumed, h_d]
      have h_t : getCellValue target (.bridgeConsumed d) = ByteArray.empty :=
        h_append rfl h_v
      rw [h_v]
      show getCellValue (setCell target (.bridgeConsumed d) ByteArray.empty)
          (.bridgeConsumed d) = ByteArray.empty
      rw [show setCell target (.bridgeConsumed d) ByteArray.empty = target from by
        simp only [setCell]
        rw [if_pos (show ByteArray.empty.size = 0 from rfl)]]
      exact h_t
    | some rec =>
      have h_v : getCellValue source (.bridgeConsumed d) = depositCellValue rec := by
        rw [getCellValue_bridgeConsumed, h_d]
      rw [h_v]
      exact getCellValue_setCell_bridgeConsumed target d rec
        (depositRecord_bounded_of_canonicalBounds source d rec h_d h_bounds)
  | bridgePending w =>
    cases h_w : source.bridge.pending[w]? with
    | none =>
      have h_v : getCellValue source (.bridgePending w) = ByteArray.empty := by
        rw [getCellValue_bridgePending, h_w]
      have h_t : getCellValue target (.bridgePending w) = ByteArray.empty :=
        h_append rfl h_v
      rw [h_v]
      show getCellValue (setCell target (.bridgePending w) ByteArray.empty)
          (.bridgePending w) = ByteArray.empty
      rw [show setCell target (.bridgePending w) ByteArray.empty = target from by
        simp only [setCell]
        rw [if_pos (show ByteArray.empty.size = 0 from rfl)]]
      exact h_t
    | some pw =>
      have h_v : getCellValue source (.bridgePending w) = withdrawalCellValue pw := by
        rw [getCellValue_bridgePending, h_w]
      rw [h_v]
      obtain ⟨h_res, h_amt, h_idx⟩ :=
        pendingWithdrawal_bounded_of_canonicalBounds source w pw h_w h_bounds
      exact getCellValue_setCell_bridgePending target w pw h_res h_amt h_idx
  | bridgeNextWdId =>
    rw [getCellValue_bridgeNextWdId]
    exact getCellValue_setCell_bridgeNextWdId target _ h_bounds.bs_nxt
  | bridgeAmmReserveEth =>
    show getCellValue (setCell target _ (amountCellValue source.bridge.ammReserveEth)) _
      = amountCellValue source.bridge.ammReserveEth
    exact getCellValue_setCell_bridgeAmmReserveEth target _ h_bounds.bs_ammEth
  | bridgeAmmReserveBold =>
    show getCellValue (setCell target _ (amountCellValue source.bridge.ammReserveBold)) _
      = amountCellValue source.bridge.ammReserveBold
    exact getCellValue_setCell_bridgeAmmReserveBold target _ h_bounds.bs_ammBold
  | bridgeBoldCircuitClosed =>
    show getCellValue (setCell target _
        (natCellValue (if source.bridge.boldCircuitClosed then 1 else 0))) _
      = natCellValue (if source.bridge.boldCircuitClosed then 1 else 0)
    exact getCellValue_setCell_bridgeBoldCircuitClosed target _
  | bridgeBoldTvlCap =>
    show getCellValue (setCell target _ (amountCellValue source.bridge.boldTvlCap)) _
      = amountCellValue source.bridge.boldTvlCap
    exact getCellValue_setCell_bridgeBoldTvlCap target _ h_bounds.bs_tvlCap
  | bridgeBoldTotalLockedValue =>
    show getCellValue (setCell target _
        (amountCellValue source.bridge.boldTotalLockedValue)) _
      = amountCellValue source.bridge.boldTotalLockedValue
    exact getCellValue_setCell_bridgeBoldTotalLockedValue target _ h_bounds.bs_totalLocked
  | bridgeAmmDisabled =>
    show getCellValue (setCell target _
        (natCellValue (if source.bridge.ammDisabled then 1 else 0))) _
      = natCellValue (if source.bridge.ammDisabled then 1 else 0)
    exact getCellValue_setCell_bridgeAmmDisabled target _
  | epochBudget a =>
    rw [getCellValue_epochBudget']
    obtain ⟨h_epoch, h_bal⟩ := actorBudget_bounded_of_canonicalBounds source a h_bounds
    exact getCellValue_setCell_epochBudget target a _ h_epoch h_bal
  | budgetPolicy =>
    -- Named as an equation and REWRITTEN rather than case-split: the
    -- read-back law is stated over the `bounded` constructor, and
    -- leaving `source.budgetPolicy` in the goal makes the unifier
    -- chase the encoder through it.
    have h_ex : ∃ ft ac ce, source.budgetPolicy = .bounded ft ac ce := by
      cases source.budgetPolicy with | bounded ft ac ce => exact ⟨ft, ac, ce, rfl⟩
    obtain ⟨ft, ac, ce, h_eq⟩ := h_ex
    obtain ⟨h_ft, h_ac, h_ce, h_pos⟩ := h_bounds.bp_val ft ac ce h_eq
    have h_v : getCellValue source .budgetPolicy
        = budgetPolicyCellValue (.bounded ft ac ce) := by
      rw [getCellValue_budgetPolicy', h_eq]
    rw [h_v]
    exact getCellValue_setCell_budgetPolicy target ft ac ce h_ft h_ac h_ce h_pos

/-! ## A step's write list

Composing the pieces: a step writes each cell it declares, to the
value the advance gives that cell.  What remains for a variant is
COMPLETENESS — that the advance changes no cell the declaration omits
— and that is the per-variant obligation §4 is really about.  It is
also the property the bundle's sufficiency rests on: an L1 holding
openings only for the declared cells can compute the post-root exactly
when nothing else moved. -/

/-- The writes a step performs: each declared cell, set to the value
    the production advance gives it.

    Note this is a SPECIFICATION, not a computation the L1 performs —
    it reads the post-state.  The L1 is handed these values in the
    bundle and checks them against the pre-root; reproducing them
    on-chain is the step VM's handler job. -/
def stepCellWrites (post : ExtendedState) (action : Authority.Action)
    (signer : ActorId) : List CellWrite :=
  (action.writeCells signer).map (fun t => (t, getCellValue post t))

/-- Every declared cell appears in the write list, at its post value. -/
theorem mem_stepCellWrites (post : ExtendedState) (action : Authority.Action)
    (signer : ActorId) (t : CellTag) (h : t ∈ action.writeCells signer) :
    (t, getCellValue post t) ∈ stepCellWrites post action signer :=
  List.mem_map.mpr ⟨t, h, rfl⟩

/-- The write list names exactly the declared cells. -/
theorem stepCellWrites_tags (post : ExtendedState) (action : Authority.Action)
    (signer : ActorId) :
    (stepCellWrites post action signer).map Prod.fst = action.writeCells signer := by
  unfold stepCellWrites
  rw [List.map_map]
  exact List.map_id _

/-- **The declared write set is complete for a step.**

    The obligation each of the twenty-five per-variant proofs
    discharges, and the only one left after this module: the advance
    changes no cell the declaration omits.

    Stated over an arbitrary post-state rather than over
    `productionApplyBudget` directly so the per-variant proofs can be
    written against whichever form of the advance is convenient and
    composed here. -/
def WriteSetComplete (pre post : ExtendedState) (action : Authority.Action)
    (signer : ActorId) : Prop :=
  ∀ t : CellTag, t ∉ action.writeCells signer → getCellValue post t = getCellValue pre t

/-- **A complete write set reproduces the post-state's cells.**

    Given completeness, applying the step's write list to the
    pre-state yields a state whose every cell reads as the
    post-state's.  With `commitExtendedState_eq_of_cells_agree` that
    is root equality, and with
    `fold_canonicalCellChain_eq_commit_of_cells_agree` it is the
    number the L1 folds.

    The `NoDuplicates` hypothesis is what lets the written cells be
    read off one at a time; every `Action.writeCells` arm satisfies it
    except at a self-transfer, where sender and receiver coincide — see
    `applyCellWrites`'s later-write-wins test. -/
theorem getCellValue_applyCellWrites_stepCellWrites
    (pre post : ExtendedState) (action : Authority.Action) (signer : ActorId)
    (h_complete : WriteSetComplete pre post action signer)
    (h_nodup : (action.writeCells signer).Nodup)
    (h_bounds : ExtendedState.CanonicalBounds post)
    (h_append : ∀ t : CellTag, t.appendOnly = true →
      getCellValue post t = canonicalAbsentValue t →
      getCellValue pre t = canonicalAbsentValue t)
    (t : CellTag) :
    getCellValue (applyCellWrites pre (stepCellWrites post action signer)) t
      = getCellValue post t := by
  by_cases h_mem : t ∈ action.writeCells signer
  · -- A declared cell: split the list at its (unique) occurrence and
    -- read the write back.
    obtain ⟨l₁, l₂, h_split⟩ := List.append_of_mem h_mem
    have h_nd : (l₁ ++ t :: l₂).Nodup := h_split ▸ h_nodup
    obtain ⟨_, h_tail, h_cross⟩ := List.pairwise_append.mp h_nd
    have h_notin₁ : t ∉ l₁ := fun hc => h_cross t hc t List.mem_cons_self rfl
    have h_notin₂ : t ∉ l₂ := fun hc => (List.pairwise_cons.mp h_tail).1 t hc rfl
    have h_ws : stepCellWrites post action signer
        = l₁.map (fun t' => (t', getCellValue post t'))
          ++ (t, getCellValue post t)
            :: l₂.map (fun t' => (t', getCellValue post t')) := by
      unfold stepCellWrites; rw [h_split]; simp
    -- The writes before this one name other cells, so the state this
    -- one lands in still reads `pre` at `t` — which is what carries
    -- the append-only side condition inward.
    have h_mid : getCellValue
        (applyCellWrites pre (l₁.map (fun t' => (t', getCellValue post t')))) t
          = getCellValue pre t :=
      getCellValue_applyCellWrites_of_not_written _ pre t
        (fun w hw => by
          obtain ⟨t', ht', rfl⟩ := List.mem_map.mp hw
          exact fun he => h_notin₁ (he ▸ ht'))
    rw [h_ws, getCellValue_applyCellWrites_of_written _ t _ _ pre
      (fun w hw => by
        obtain ⟨t', ht', rfl⟩ := List.mem_map.mp hw
        exact fun he => h_notin₂ (he ▸ ht'))]
    exact getCellValue_setCell_getCellValue _ post t h_bounds
      (fun h_ao h_abs => h_mid.trans (h_append t h_ao h_abs))
  · -- An undeclared cell: no write names it, and completeness says
    -- the advance left it alone.
    rw [getCellValue_applyCellWrites_of_not_written _ pre t
      (fun w hw => by
        obtain ⟨t', ht', rfl⟩ := List.mem_map.mp hw
        exact fun he => h_mem (he ▸ ht'))]
    exact (h_complete t h_mem).symm

/-- **The step-VM statement.**  Folding a step's write bundle into the
    pre-state's published root computes the post-state's published
    root.

    This is what `docs/planning/state_root_merkleisation_plan.md` §4
    asks for on the Lean side, reduced to its per-variant residue: the
    only hypothesis that is not generic machinery or standing
    well-formedness is `WriteSetComplete`, and that is exactly "the
    declaration names every cell the advance moves". -/
theorem fold_stepCellWrites_eq_commit_post
    (pre post : ExtendedState) (action : Authority.Action) (signer : ActorId)
    (h_ready : CellWritesReady pre (stepCellWrites post action signer))
    (h_complete : WriteSetComplete pre post action signer)
    (h_nodup : (action.writeCells signer).Nodup)
    (h_bounds : ExtendedState.CanonicalBounds post)
    (h_wf : BitsDistinctBelow smtDepth (stateCellEntries post))
    (h_append : ∀ t : CellTag, t.appendOnly = true →
      getCellValue post t = canonicalAbsentValue t →
      getCellValue pre t = canonicalAbsentValue t) :
    foldStateCellWrites (commitExtendedState pre)
        (chainWrites pre (canonicalCellChain pre (stepCellWrites post action signer)))
      = some (commitExtendedState post) :=
  fold_canonicalCellChain_eq_commit_of_cells_agree _ pre post h_ready h_wf
    (getCellValue_applyCellWrites_stepCellWrites pre post action signer
      h_complete h_nodup h_bounds h_append)

end FaultProof
end LegalKernel
