-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.CellWrites — the cell-write primitives, and the
per-step completeness obligation the fault proof consumes.

Two concerns, kept together because the second is stated over the
first.

**The primitives.**  A step's writes are a list of `(cell, value)`
pairs.  `applyCellWrites` lands them, and the two `getCellValue_…`
laws say a written cell reads back its value while an unwritten one
does not move.  `CellTag.appendOnly` names the three kinds `setCell`
declines to clear, because no `Action` un-consumes a deposit, retires
a pending withdrawal or removes a registry entry inside one step.

**The obligation.**  `WriteSetComplete pre post action signer` says
the advance moves no cell `Action.writeCellsAt` omits.  That is the
hypothesis `stepMultiFold_eq_commit_post` (`Terminate.lean`) takes —
via `agreeOffOpened_openedOf` — so it is what makes the merged walk's
"one wire, two roots" argument sound: a cell the frontier does not
open is a cell the step does not move, hence a sibling both roots
share.  `writeSetComplete_of_field_footprints` and
`writeSetComplete_of_identity_advance` discharge it per variant, and
`StepWriteSets.lean` does so for all twenty-five.

This module once also hosted the CHAINED fold — `canonicalCellChain`,
`ChainCoherent` and the per-link coherence machinery — which was the
consensus surface before the pre-root multiproof replaced it.  That is
gone; what survives is what the multiproof still consumes.

**Why cells and not states.**  Two reasons, and the second is the
load-bearing one.

`ExtendedState` EQUALITY is out of reach: `Std.TreeMap` is a balanced
search tree, the production advance and a `setCell` chain insert the
same bindings in different orders, and Lean core has no pointwise
lemma concluding `=` on it.  It does have an extensional EQUIVALENCE —
`TreeMap.Equiv` (`~m`), built from pointwise lookups by
`Equiv.of_forall_constGet?_eq` and reduced to `toList` equality by
`equiv_iff_toList_eq` — which would carry through `stateCellEntries`
to the root.  So map-level agreement is reachable in principle.

It is also the WRONG target, and that is the real reason.  Map
agreement is strictly stronger than what the root observes:
`stateCellEntries` drops canonically-absent cells, so a balance
written to zero and a balance never written are cell-identical and
root-identical while their maps differ pointwise.
`reclaimAmmReserves` sweeps a balance to zero, so that pair is
reachable — a per-variant proof phrased over maps would be attempting
a hypothesis that is FALSE on a real action.  Pinned by
`faultproof-cell-writes`'s "cell agreement is STRICTLY WEAKER than map
agreement".

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

/-! ## What a canonical opening needs of its state

Three obligations per OPENED CELL, and each is a real hypothesis
rather than a technicality:

  * **Distinguishability.**  `smtRootListAux`'s depth-0 case collapses
    a bucket holding two entries, so a root over indistinguishable
    entries is not determined by them.
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

/-- What a cell's canonical opening needs of the state it opens
    against. -/
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
def stepCellWrites (pre post : ExtendedState) (action : Authority.Action)
    (signer : ActorId) : List CellWrite :=
  (action.writeCellsAt pre signer).map (fun t => (t, getCellValue post t))

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
  ∀ t : CellTag, t ∉ action.writeCellsAt pre signer → getCellValue post t = getCellValue pre t

/-- **A complete write set reproduces the post-state's cells.**

    Given completeness, applying the step's write list to the
    pre-state yields a state whose every cell reads as the
    post-state's.  With `commitExtendedState_eq_of_cells_agree` that
    is root equality, and with
    `fold_canonicalCellChain_eq_commit_of_cells_agree` it is the
    number the L1 folds.

    The `NoDuplicates` hypothesis is what lets the written cells be
    read off one at a time; every `Action.writeCellsAt` arm satisfies it
    except at a self-transfer, where sender and receiver coincide — see
    `applyCellWrites`'s later-write-wins test. -/
theorem getCellValue_applyCellWrites_stepCellWrites
    (pre post : ExtendedState) (action : Authority.Action) (signer : ActorId)
    (h_complete : WriteSetComplete pre post action signer)
    (h_nodup : (action.writeCellsAt pre signer).Nodup)
    (h_bounds : ExtendedState.CanonicalBounds post)
    (h_append : ∀ t : CellTag, t.appendOnly = true →
      getCellValue post t = canonicalAbsentValue t →
      getCellValue pre t = canonicalAbsentValue t)
    (t : CellTag) :
    getCellValue (applyCellWrites pre (stepCellWrites pre post action signer)) t
      = getCellValue post t := by
  by_cases h_mem : t ∈ action.writeCellsAt pre signer
  · -- A declared cell: split the list at its (unique) occurrence and
    -- read the write back.
    obtain ⟨l₁, l₂, h_split⟩ := List.append_of_mem h_mem
    have h_nd : (l₁ ++ t :: l₂).Nodup := h_split ▸ h_nodup
    obtain ⟨_, h_tail, h_cross⟩ := List.pairwise_append.mp h_nd
    have h_notin₁ : t ∉ l₁ := fun hc => h_cross t hc t List.mem_cons_self rfl
    have h_notin₂ : t ∉ l₂ := fun hc => (List.pairwise_cons.mp h_tail).1 t hc rfl
    have h_ws : stepCellWrites pre post action signer
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


/-! ## Completeness for the kernel-identity variants

`WriteSetComplete` quantifies over cells; every advance is defined by
what it does to the seven `ExtendedState` FIELDS.
`writeSetComplete_of_field_footprints` is the bridge: it takes one
footprint per field and produces the cell-level statement, so no
per-variant proof ever does a `cases t` over the fifteen tags.

Both lemmas below state their hypotheses as equations on the state
rather than as a constructor list.  That keeps them about behaviour —
a future action satisfying them gets completeness for free, and one
that does not fails to instantiate rather than slipping through a
`| _ =>` catch-all. -/

/-- **Cell completeness from per-field footprints.**

    Each hypothesis says: this field moved only at keys the write set
    declares.  The six bridge scalars take an unconditional equation
    because no `Action` constructor touches them —
    `applyActionToBridgeState` writes `consumed`, `pending` and
    `nextWdId` and nothing else — so making them conditional would
    invite a caller to believe otherwise. -/
theorem writeSetComplete_of_field_footprints
    (pre post : ExtendedState) (action : Authority.Action) (signer : ActorId)
    (h_bal : ∀ r a, CellTag.balance r a ∉ action.writeCellsAt pre signer →
      LegalKernel.getBalance post.base r a = LegalKernel.getBalance pre.base r a)
    (h_nonce : ∀ a, CellTag.nonce a ∉ action.writeCellsAt pre signer →
      Authority.expectsNonce post a = Authority.expectsNonce pre a)
    (h_reg : ∀ a, CellTag.registry a ∉ action.writeCellsAt pre signer →
      post.registry[a]? = pre.registry[a]?)
    (h_lp : ∀ a, CellTag.localPolicy a ∉ action.writeCellsAt pre signer →
      post.localPolicies[a]? = pre.localPolicies[a]?)
    (h_cons : ∀ d, CellTag.bridgeConsumed d ∉ action.writeCellsAt pre signer →
      post.bridge.consumed[d]? = pre.bridge.consumed[d]?)
    (h_pend : ∀ w, CellTag.bridgePending w ∉ action.writeCellsAt pre signer →
      post.bridge.pending[w]? = pre.bridge.pending[w]?)
    (h_nxt : CellTag.bridgeNextWdId ∉ action.writeCellsAt pre signer →
      post.bridge.nextWdId = pre.bridge.nextWdId)
    (h_ammEth : post.bridge.ammReserveEth = pre.bridge.ammReserveEth)
    (h_ammBold : post.bridge.ammReserveBold = pre.bridge.ammReserveBold)
    (h_circuit : post.bridge.boldCircuitClosed = pre.bridge.boldCircuitClosed)
    (h_tvlCap : post.bridge.boldTvlCap = pre.bridge.boldTvlCap)
    (h_tvl : post.bridge.boldTotalLockedValue = pre.bridge.boldTotalLockedValue)
    (h_ammDisabled : post.bridge.ammDisabled = pre.bridge.ammDisabled)
    (h_eb : ∀ a, CellTag.epochBudget a ∉ action.writeCellsAt pre signer →
      post.epochBudgets[a]? = pre.epochBudgets[a]?)
    (h_pol : post.budgetPolicy = pre.budgetPolicy) :
    WriteSetComplete pre post action signer := by
  intro t h_notin
  cases t with
  | balance r a =>
    rw [getCellValue_balance, getCellValue_balance, h_bal r a h_notin]
  | nonce a => rw [getCellValue_nonce, getCellValue_nonce, h_nonce a h_notin]
  | registry a => rw [getCellValue_registry, getCellValue_registry, h_reg a h_notin]
  | localPolicy a => rw [getCellValue_localPolicy, getCellValue_localPolicy, h_lp a h_notin]
  | bridgeConsumed d =>
    rw [getCellValue_bridgeConsumed, getCellValue_bridgeConsumed, h_cons d h_notin]
  | bridgePending w =>
    rw [getCellValue_bridgePending, getCellValue_bridgePending, h_pend w h_notin]
  | bridgeNextWdId =>
    rw [getCellValue_bridgeNextWdId, getCellValue_bridgeNextWdId, h_nxt h_notin]
  | bridgeAmmReserveEth =>
    show getCellValue post .bridgeAmmReserveEth = _
    unfold getCellValue; rw [h_ammEth]
  | bridgeAmmReserveBold =>
    show getCellValue post .bridgeAmmReserveBold = _
    unfold getCellValue; rw [h_ammBold]
  | bridgeBoldCircuitClosed =>
    show getCellValue post .bridgeBoldCircuitClosed = _
    unfold getCellValue; rw [h_circuit]
  | bridgeBoldTvlCap =>
    show getCellValue post .bridgeBoldTvlCap = _
    unfold getCellValue; rw [h_tvlCap]
  | bridgeBoldTotalLockedValue =>
    show getCellValue post .bridgeBoldTotalLockedValue = _
    unfold getCellValue; rw [h_tvl]
  | bridgeAmmDisabled =>
    show getCellValue post .bridgeAmmDisabled = _
    unfold getCellValue; rw [h_ammDisabled]
  | epochBudget a =>
    rw [getCellValue_epochBudget', getCellValue_epochBudget', h_eb a h_notin]
  | budgetPolicy => rw [getCellValue_budgetPolicy', getCellValue_budgetPolicy', h_pol]

/-- **Completeness for an advance whose only effect is the nonce bump
    and the budget consume.**

    Note the epoch-budget hypothesis is an inclusion, not an equation:
    `EpochBudgetState.consume` writes back through `insert` even when
    it normalises across an epoch boundary, so the signer's budget cell
    genuinely moves — which is why `.epochBudget signer` is in every
    `writeCells` arm. -/
theorem writeSetComplete_of_identity_advance
    (pre post : ExtendedState) (action : Authority.Action) (signer : ActorId)
    (h_decl : ∀ t : CellTag,
      t = .nonce signer ∨ t = .epochBudget signer → t ∈ action.writeCellsAt pre signer)
    (h_base : post.base = pre.base)
    (h_registry : post.registry = pre.registry)
    (h_lp : post.localPolicies = pre.localPolicies)
    (h_bridge : post.bridge = pre.bridge)
    (h_pol : post.budgetPolicy = pre.budgetPolicy)
    (h_nonces : ∀ a : ActorId, a ≠ signer →
      Authority.expectsNonce post a = Authority.expectsNonce pre a)
    (h_budget : ∀ a : ActorId, a ≠ signer →
      post.epochBudgets[a]? = pre.epochBudgets[a]?) :
    WriteSetComplete pre post action signer := by
  intro t h_notin
  cases t with
  | balance r a => rw [getCellValue_balance, getCellValue_balance, h_base]
  | nonce a =>
    rw [getCellValue_nonce, getCellValue_nonce,
      h_nonces a (fun he => h_notin (h_decl _ (Or.inl (by rw [he]))))]
  | registry a => rw [getCellValue_registry, getCellValue_registry, h_registry]
  | localPolicy a => rw [getCellValue_localPolicy, getCellValue_localPolicy, h_lp]
  | bridgeConsumed d => rw [getCellValue_bridgeConsumed, getCellValue_bridgeConsumed, h_bridge]
  | bridgePending w => rw [getCellValue_bridgePending, getCellValue_bridgePending, h_bridge]
  | bridgeNextWdId => rw [getCellValue_bridgeNextWdId, getCellValue_bridgeNextWdId, h_bridge]
  | bridgeAmmReserveEth =>
    show getCellValue post .bridgeAmmReserveEth = _
    unfold getCellValue
    rw [h_bridge]
  | bridgeAmmReserveBold =>
    show getCellValue post .bridgeAmmReserveBold = _
    unfold getCellValue
    rw [h_bridge]
  | bridgeBoldCircuitClosed =>
    show getCellValue post .bridgeBoldCircuitClosed = _
    unfold getCellValue
    rw [h_bridge]
  | bridgeBoldTvlCap =>
    show getCellValue post .bridgeBoldTvlCap = _
    unfold getCellValue
    rw [h_bridge]
  | bridgeBoldTotalLockedValue =>
    show getCellValue post .bridgeBoldTotalLockedValue = _
    unfold getCellValue
    rw [h_bridge]
  | bridgeAmmDisabled =>
    show getCellValue post .bridgeAmmDisabled = _
    unfold getCellValue
    rw [h_bridge]
  | epochBudget a =>
    rw [getCellValue_epochBudget', getCellValue_epochBudget',
      h_budget a (fun he => h_notin (h_decl _ (Or.inr (by rw [he]))))]
  | budgetPolicy => rw [getCellValue_budgetPolicy', getCellValue_budgetPolicy', h_pol]

end FaultProof
end LegalKernel
