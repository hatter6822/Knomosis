-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Transcript — auxiliary infrastructure for
the fault-proof game's per-transcript reasoning.

Adds the following declarations:
  * `applyCellWrites` — the canonical cell-write function (alias
    of `applyCellWrites_to_state` from `Coherence.lean` for the
    per-cell write semantic).
  * `extractRequiredCells` — extract the per-action `requiredCells`
    from a SignedAction.
  * `Action.requiredCellProofs` — build the canonical cell-proof
    bundle for an Action's required cells.
  * `NonMembershipProof` — a proof that a cell is NOT in the
    state (the canonical-absent-value form).
  * `isLegalTranscript` — predicate over a list of `KernelStep`s
    asserting the chain is well-formed.
  * `chainKernelStepApplyFromLog` — derive a chain of
    `KernelStep`s from a log + initial state.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Coherence

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime

/-! ## `applyCellWrites` — alias

`applyCellWrites_to_state` from `Coherence.lean` is the
canonical cell-write function.  Per the plan §5.2 naming, we
expose it under `applyCellWrites`. -/

/-- The canonical per-step cell-write function: takes a pre-state
    and a SignedAction, returns the post-state.  Alias for
    `applyCellWrites_to_state` in `Coherence.lean`. -/
def applyCellWrites (es : ExtendedState) (st : SignedAction) : ExtendedState :=
  applyCellWrites_to_state es st

/-- `applyCellWrites` is deterministic. -/
theorem applyCellWrites_deterministic
    (es₁ es₂ : ExtendedState) (st₁ st₂ : SignedAction)
    (h_es : es₁ = es₂) (h_st : st₁ = st₂) :
    applyCellWrites es₁ st₁ = applyCellWrites es₂ st₂ := by
  rw [h_es, h_st]

/-! ## `extractRequiredCells` — projection helper -/

/-- Project the list of `CellTag`s the L1 step VM needs proofs
    for, given a SignedAction.  Specialises
    `Action.requiredCells` to the SignedAction's components. -/
def extractRequiredCells (st : SignedAction) : List CellTag :=
  Action.requiredCells st.action st.signer

/-- `extractRequiredCells` is deterministic. -/
theorem extractRequiredCells_deterministic
    (st₁ st₂ : SignedAction) (h : st₁ = st₂) :
    extractRequiredCells st₁ = extractRequiredCells st₂ := by rw [h]

/-! ## `Action.requiredCellProofs` — canonical cell-proof bundle -/

/-- Build the canonical cell-proof bundle for an action's
    required cells, given a witness ExtendedState.  Each proof
    in the bundle has the witness state as its `witnessState`
    field and the looked-up cell value as its `cellValue` field. -/
def Action.requiredCellProofs
    (es : ExtendedState) (st : SignedAction) : CellProofBundle :=
  buildCellProofsForAction es st

/-- The canonical cell-proof bundle's size matches the number
    of required cells. -/
theorem Action.requiredCellProofs_size
    (es : ExtendedState) (st : SignedAction) :
    (Action.requiredCellProofs es st).proofs.length =
    (extractRequiredCells st).length := by
  unfold Action.requiredCellProofs buildCellProofsForAction extractRequiredCells
  simp [List.length_map]

/-! ## `NonMembershipProof` — absent-cell witness -/

/-- A proof that a cell is NOT in the state (i.e. carries the
    canonical absent value).  Used for actions like `mint` to a
    fresh actor: the new balance entry is created from a
    canonical-absent precursor. -/
structure NonMembershipProof where
  /-- The cell tag whose absence is proved. -/
  cellTag      : CellTag
  /-- The witness state in which the cell is absent. -/
  witnessState : ExtendedState
  /-- The canonical absent value's expected bytes (per
      `canonicalAbsentValue`). -/
  absentValueHash : ByteArray
  deriving Repr

/-- Build a non-membership proof for a cell, given a witness
    state in which the cell is absent.  The constructor is a
    pure aggregator; the actual absence check is structural. -/
def NonMembershipProof.build
    (es : ExtendedState) (cellTag : CellTag) : NonMembershipProof where
  cellTag := cellTag
  witnessState := es
  absentValueHash := canonicalAbsentValue cellTag

/-- `NonMembershipProof.build` is deterministic. -/
theorem NonMembershipProof.build_deterministic
    (es₁ es₂ : ExtendedState) (t₁ t₂ : CellTag)
    (h_es : es₁ = es₂) (h_t : t₁ = t₂) :
    NonMembershipProof.build es₁ t₁ = NonMembershipProof.build es₂ t₂ := by
  rw [h_es, h_t]

/-! ## `isLegalTranscript` — well-formedness predicate -/

/-- A transcript is a list of `KernelStep`s.  A legal transcript
    has the property that each step's `preStateCommit` matches
    the previous step's `postStateCommit` (the chain is
    well-formed at the commit level). -/
def isLegalTranscript : StateCommit → List KernelStep → Prop
  | _,           []         => True
  | initialCommit, s :: rest =>
    s.preStateCommit = initialCommit ∧
    isLegalTranscript s.postStateCommit rest

/-- `isLegalTranscript` is decidable.  Definition uses structural
    recursion on `steps` so the resulting decidable instance
    compiles to a real runtime check. -/
instance instDecidableIsLegalTranscript :
    ∀ (initialCommit : StateCommit) (steps : List KernelStep),
    Decidable (isLegalTranscript initialCommit steps)
  | _,           []         => isTrue trivial
  | initialCommit, s :: rest =>
    have : Decidable (s.preStateCommit = initialCommit ∧
                     isLegalTranscript s.postStateCommit rest) :=
      let _ := instDecidableIsLegalTranscript s.postStateCommit rest
      instDecidableAnd
    show Decidable (s.preStateCommit = initialCommit ∧
                    isLegalTranscript s.postStateCommit rest)
    from this

/-- An empty transcript is always legal. -/
theorem isLegalTranscript_nil (initialCommit : StateCommit) :
    isLegalTranscript initialCommit [] := trivial

/-- A singleton transcript is legal iff the step's pre-commit
    matches the initial commit. -/
theorem isLegalTranscript_singleton
    (initialCommit : StateCommit) (s : KernelStep) :
    isLegalTranscript initialCommit [s] ↔
    s.preStateCommit = initialCommit := by
  constructor
  · intro ⟨h, _⟩; exact h
  · intro h; exact ⟨h, trivial⟩

/-! ## `chainKernelStepApplyFromLog` — log-based chain derivation

Given an initial state and a log, derive the canonical chain
of `KernelStep`s by applying each entry sequentially.  The
result is a list of canonical KernelSteps that:
  * Start at the initial commit.
  * End at the post-state commit of the last entry.
  * Each step is built via `buildKernelStep`. -/

/-- Build the canonical chain of KernelSteps from a list of log
    entries, threading the state through each step. -/
def chainKernelStepApplyFromLog
    (es : ExtendedState) : List LogEntry → List KernelStep
  | []         => []
  | e :: rest =>
    let step := buildKernelStep es e.signedAction
    step :: chainKernelStepApplyFromLog (kernelOnlyApply es e) rest

/-- The empty-log reduction. -/
theorem chainKernelStepApplyFromLog_empty (es : ExtendedState) :
    chainKernelStepApplyFromLog es [] = [] := rfl

/-- The canonical chain's length matches the log length. -/
theorem chainKernelStepApplyFromLog_length
    (es : ExtendedState) (log : List LogEntry) :
    (chainKernelStepApplyFromLog es log).length = log.length := by
  induction log generalizing es with
  | nil => rfl
  | cons e rest ih =>
    simp [chainKernelStepApplyFromLog]
    exact ih (kernelOnlyApply es e)

/-- The canonical chain's first step's pre-commit matches the
    initial state's commit. -/
theorem chainKernelStepApplyFromLog_first_preCommit
    (es : ExtendedState) (e : LogEntry) (rest : List LogEntry) :
    (chainKernelStepApplyFromLog es (e :: rest)).head?.map
      KernelStep.preStateCommit = some (commitExtendedState es) := by
  unfold chainKernelStepApplyFromLog
  rfl

/-- The canonical chain produced from a log is a legal
    transcript with the initial state's commit as the starting
    commit.  Discharged inductively over the log length. -/
theorem chainKernelStepApplyFromLog_isLegalTranscript
    (es : ExtendedState) (log : List LogEntry) :
    isLegalTranscript (commitExtendedState es)
                      (chainKernelStepApplyFromLog es log) := by
  induction log generalizing es with
  | nil =>
    -- Empty log: chain is empty; isLegalTranscript on empty is True.
    show isLegalTranscript (commitExtendedState es) []
    trivial
  | cons e rest ih =>
    -- The first step is buildKernelStep es e.signedAction.  Its
    -- preStateCommit = commitExtendedState es by definition; its
    -- postStateCommit = recomputeCommitment es e.signedAction.
    -- The tail is chainKernelStepApplyFromLog (kernelOnlyApply es e) rest.
    -- IH at (kernelOnlyApply es e) gives legality starting at
    -- commitExtendedState (kernelOnlyApply es e); we bridge via #225.
    show isLegalTranscript (commitExtendedState es)
           (buildKernelStep es e.signedAction ::
            chainKernelStepApplyFromLog (kernelOnlyApply es e) rest)
    refine ⟨?_, ?_⟩
    · -- (buildKernelStep es e.signedAction).preStateCommit = commitExtendedState es.
      show (buildKernelStep es e.signedAction).preStateCommit =
           commitExtendedState es
      rfl
    · -- The tail's initial commit is the first step's postStateCommit
      -- = recomputeCommitment es e.signedAction = commitExtendedState
      -- (kernelOnlyApply es e) by #225 coherence.
      have h_coh := recomputeCommitment_coherent_with_kernelOnlyApply
                      es e.signedAction e rfl
      show isLegalTranscript (buildKernelStep es e.signedAction).postStateCommit
             (chainKernelStepApplyFromLog (kernelOnlyApply es e) rest)
      have h_post : (buildKernelStep es e.signedAction).postStateCommit =
                    commitExtendedState (kernelOnlyApply es e) := by
        show recomputeCommitment es e.signedAction =
             commitExtendedState (kernelOnlyApply es e)
        exact h_coh
      rw [h_post]
      exact ih (kernelOnlyApply es e)

end FaultProof
end LegalKernel
