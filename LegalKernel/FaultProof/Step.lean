-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Step — `KernelStep`, `kernelStepApply`,
and the multi-step composition machinery (Workstream H §12 /
WUs H.1.1 + H.1.2 + H.1.6).

A `KernelStep` is the first-class data form of one kernel step's
inputs and outputs: pre-state commit + signed action + post-state
commit + per-cell Merkle proofs.  This is what the L1 step VM
(`KnomosisStepVM.executeStep`) consumes when bisection narrows to a
single disputed step.

Coherence with `kernelOnlyApply` (the existing dispute-pipeline
step function) is established in WU H.1.3; this module ships the
type + the basic `kernelStepApply` function.

This module is **not** part of the trusted computing base.  Bugs
here would weaken the L1 fault-proof game's correctness but
cannot violate any kernel invariant.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.Commit
import LegalKernel.FaultProof.StepVMCoherence
import LegalKernel.FaultProof.Verify

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
-- `stepVMHash` / `stepVMHashFromAction` / `actionKindByte` /
-- `actionFieldsForL1`: the step-VM dispatch `kernelStepApply`
-- computes through, and the same one `KnomosisStepVM.executeStep`
-- implements on L1.
open LegalKernel.FaultProof.StepVMCoherence

/-! ## `KernelStep` (§12.1.1) -/

/-- The inputs and outputs of one kernel step.  Sufficient for
    the L1 step VM to verify the step's correctness given Merkle
    proofs for the touched cells.

    `preStateCommit` and `postStateCommit` are 32-byte hashes
    binding the pre-state and the claimed post-state.
    `signedAction` is the action being applied.  `cellProofs` is
    the per-cell Merkle proof bundle for each cell the step
    reads or writes (the L1 step VM consults this to load the
    relevant cells without holding the full state). -/
structure KernelStep where
  /-- The 32-byte commit of the pre-state. -/
  preStateCommit  : StateCommit
  /-- The signed action being applied. -/
  signedAction    : SignedAction
  /-- The 32-byte commit of the claimed post-state. -/
  postStateCommit : StateCommit
  /-- Per-cell Merkle proofs covering all cells the step
      reads or writes. -/
  cellProofs      : CellProofBundle
  deriving Repr

/-! ## `kernelStepApply` (§12.1.2)

`kernelStepApply` verifies the cell proofs against the pre-state
commitment and then **computes** the post-state commitment by
re-executing the step through `StepVMCoherence.stepVMHash` —
the same dispatch `KnomosisStepVM.executeStep` performs on L1,
pinned byte-for-byte against it by the SVC cross-stack corpus.

It did neither for a while.  The body returned
`step.postStateCommit` — the *responder's own claim* — whenever
the proofs verified, and `verifyCellProofs` is `List.all` over
the bundle, so an **empty** bundle verified vacuously.  A
responder could hand in an empty proof bundle carrying any
post-commit they liked, and
`applyTransition .terminateOnSingleStep` would find the
"computed" value equal to the claim and award them the game.
The step VM adjudicated nothing.

The per-variant write rules are not re-derived here: routing
through `stepVMHash` is what makes this function's output the
same object the L1 contract computes, which is the property the
single-step termination rests on. -/

/-- The Merkle-state-aware step function.  Given the pre-state
    commitment, the action, and the Merkle proofs for the touched
    cells, **compute** the post-state commitment.

    Returns `none` if any cell proof fails to verify against
    `preStateCommit`.  Otherwise returns the step-VM hash for
    `(preStateCommit, actionKindByte, actionFieldsForL1, signer,
    cellProofs)` — the value
    `KnomosisStepVM.executeStep(step.preStateCommit, …)` returns
    under the production keccak256 binding.

    `step.postStateCommit` is deliberately **not** consulted: it
    is the claim under dispute, and a function that returned it
    would make the single-step adjudication self-affirming. -/
def kernelStepApply (step : KernelStep) : Option StateCommit :=
  if verifyCellProofs step.preStateCommit step.cellProofs then
    some (stepVMHash step.preStateCommit
            (actionKindByte step.signedAction.action)
            (actionFieldsForL1 step.signedAction.action)
            step.signedAction.signer.toNat
            step.cellProofs)
  else
    none

/-- `kernelStepApply` agrees with the claim exactly when the
    claim is what the step VM computes.  The correctness of the
    claim is an explicit hypothesis rather than something the
    function assumes — folding it into the definition is what
    made the adjudication vacuous. -/
theorem kernelStepApply_eq_claim_iff_correct
    (step : KernelStep)
    (h_proofs : verifyCellProofs step.preStateCommit step.cellProofs = true) :
    kernelStepApply step = some step.postStateCommit ↔
      stepVMHash step.preStateCommit
        (actionKindByte step.signedAction.action)
        (actionFieldsForL1 step.signedAction.action)
        step.signedAction.signer.toNat
        step.cellProofs = step.postStateCommit := by
  -- `simp only`, not `rw`: the `if` condition sits under a
  -- `Decidable` instance that mentions the same term, so a
  -- rewrite cannot build a type-correct motive.
  unfold kernelStepApply
  simp only [h_proofs, if_true, Option.some.injEq]

/-- An empty proof bundle no longer wins the game for free.  It
    still *verifies* — `List.all` over `[]` is vacuously `true` —
    but the value returned is the step VM's own output on an
    empty bundle, which the responder does not control.  This is
    the regression that the old `some step.postStateCommit` body
    could not satisfy for any statement at all. -/
theorem kernelStepApply_empty_bundle_computes
    (pre : StateCommit) (sa : SignedAction) (claim : StateCommit) :
    kernelStepApply
        { preStateCommit := pre, signedAction := sa,
          postStateCommit := claim, cellProofs := { proofs := [] } } =
      some (stepVMHash pre (actionKindByte sa.action)
              (actionFieldsForL1 sa.action) sa.signer.toNat
              { proofs := [] }) := by
  unfold kernelStepApply verifyCellProofs
  simp

/-! ## Decidability + determinism -/

/-- Named decidable instance for `kernelStepApply step = some commit`. -/
instance instDecidableKernelStepApplySome
    (step : KernelStep) (commit : StateCommit) :
    Decidable (kernelStepApply step = some commit) :=
  inferInstance

/-- `kernelStepApply` is deterministic: equal inputs produce
    equal outputs.  Mechanical via `rfl`. -/
theorem kernelStepApply_deterministic (s₁ s₂ : KernelStep) (h : s₁ = s₂) :
    kernelStepApply s₁ = kernelStepApply s₂ := by rw [h]

/-! ## Multi-step composition (§12.1.6 / WU H.1.6) -/

/-- Apply a chain of kernel steps in order, threading the state
    commit through each.  Returns `none` if any step's pre-state
    commit doesn't match the running commit, OR if any step's
    cell proofs fail to verify. -/
def chainKernelStepApply (initialCommit : StateCommit)
    : List KernelStep → Option StateCommit
  | []         => some initialCommit
  | s :: rest =>
    if h : s.preStateCommit = initialCommit then
      let _ := h
      match kernelStepApply s with
      | none      => none
      | some next => chainKernelStepApply next rest
    else none

/-- The empty-chain reduction. -/
theorem chainKernelStepApply_empty (initialCommit : StateCommit) :
    chainKernelStepApply initialCommit [] = some initialCommit := rfl

/-- `chainKernelStepApply` is deterministic: equal inputs produce
    equal outputs. -/
theorem chainKernelStepApply_deterministic
    (c₁ c₂ : StateCommit) (steps : List KernelStep) (h : c₁ = c₂) :
    chainKernelStepApply c₁ steps = chainKernelStepApply c₂ steps := by
  rw [h]

/-- The single-step reduction: applying a one-element chain
    matches `kernelStepApply` directly under the matching-pre-commit
    hypothesis.

    This factors out the step-application case-split that the
    multi-step `chainKernelStepApply_split` lemma needs. -/
theorem chainKernelStepApply_singleton_match
    (c : StateCommit) (s : KernelStep) (h : s.preStateCommit = c) :
    chainKernelStepApply c [s] = kernelStepApply s := by
  unfold chainKernelStepApply
  simp [h]
  cases h_apply : kernelStepApply s with
  | none      => rfl
  | some next => rfl

/-- `chainKernelStepApply` splits over list concatenation: the
    chain of `steps₁ ++ steps₂` succeeds iff `steps₁` succeeds at
    `c` AND `steps₂` succeeds at the result of the first chain.

    This is what the bisection game's range-narrowing argument
    consumes: any range can be split into two sub-ranges, and the
    chain commits compose associatively. -/
theorem chainKernelStepApply_split
    (c : StateCommit) (steps₁ steps₂ : List KernelStep) :
    chainKernelStepApply c (steps₁ ++ steps₂) =
    (chainKernelStepApply c steps₁).bind
      (fun c' => chainKernelStepApply c' steps₂) := by
  induction steps₁ generalizing c with
  | nil =>
    -- Empty prefix: chain on `[] ++ steps₂` reduces to chain on
    -- `steps₂`; the bind on `some c` reduces to the same.
    show chainKernelStepApply c ([] ++ steps₂) =
         (chainKernelStepApply c []).bind
           (fun c' => chainKernelStepApply c' steps₂)
    rw [List.nil_append]
    rw [chainKernelStepApply_empty]
    rfl
  | cons s rest ih =>
    -- Non-empty prefix.  Case-split on the matching-pre-commit guard.
    show chainKernelStepApply c (s :: rest ++ steps₂) =
         (chainKernelStepApply c (s :: rest)).bind
           (fun c' => chainKernelStepApply c' steps₂)
    rw [List.cons_append]
    -- Both sides start by checking s.preStateCommit = c.
    by_cases h_match : s.preStateCommit = c
    · -- Match: both sides apply kernelStepApply s.
      simp only [chainKernelStepApply, h_match, dite_true]
      cases h_apply : kernelStepApply s with
      | none      => rfl
      | some next =>
        -- After applying step s, recurse on the tail.
        simp only []
        exact ih next
    · -- Mismatch: both sides return `none`.
      simp only [chainKernelStepApply, h_match, dite_false]
      rfl

/-! ## The canonical `KernelStep` (relocated from `Coherence.lean`)

These live here rather than in `Coherence.lean` because
`kernelStepApply` now routes through `StepVMCoherence.stepVMHash`,
so `Step` imports `StepVMCoherence → Observer → Coherence`.  A
`KernelStep`-shaped declaration in `Coherence` would need the
reverse import and close the cycle. -/

/-- The canonical `KernelStep` derived from a pre-state + signed
    action.  This is what the responding party builds for
    `terminateOnSingleStep`. -/
def buildKernelStep
    (es : ExtendedState) (st : SignedAction) : KernelStep where
  preStateCommit  := commitExtendedState es
  signedAction    := st
  postStateCommit := recomputeCommitment es st
  cellProofs      := buildCellProofsForAction es st

/-- The canonical `KernelStep`'s cell proofs verify against the
    pre-state commit. -/
theorem buildKernelStep_verifies (es : ExtendedState) (st : SignedAction) :
    verifyCellProofs (commitExtendedState es)
      (buildCellProofsForAction es st) = true :=
  buildCellProofsForAction_verifies es st

/-- `buildCellProofsForAction` and `Observer.buildObserverCellProofs`
    are the same bundle — both map `buildCellProof es` over
    `Action.requiredCells`.  They were maintained as independent
    copies with nothing tying them together; this is the tie, and
    it is what lets `kernelStepApply_canonical` below be stated in
    terms of the observer's own `stepVMHashFromAction`. -/
theorem buildCellProofsForAction_eq_observer
    (es : ExtendedState) (st : SignedAction) :
    buildCellProofsForAction es st =
      Observer.buildObserverCellProofs es st.action st.signer := rfl

/-- The canonical step's `kernelStepApply` is exactly the step-VM
    hash the observer's terminate-bundle builder computes for the
    same `(state, action, signer)` triple.

    This is the statement that ties the Lean game model to the L1
    contract: `stepVMHashFromAction` is what
    `TerminateBundle.buildTerminateBundle` emits and what the SVC
    cross-stack corpus pins against
    `KnomosisStepVM.executeStep`.

    Note what it does **not** say.  The old form claimed
    `= some (recomputeCommitment es st)`, which held only because
    the function returned the claim it was handed;
    `recomputeCommitment` is `commitExtendedState ∘ stepApply`, a
    5-component hash over the whole post-state, while `stepVMHash`
    is a per-step hash over the proven cells.  Those two recipes
    are not equal today, and reconciling them is the open
    state-root Merkleisation work recorded in
    `docs/audits/19-findings-and-followups.md`.  Stating the
    reduction against the recipe the step VM actually uses makes
    that gap visible instead of papering over it. -/
theorem kernelStepApply_canonical
    (es : ExtendedState) (st : SignedAction) :
    kernelStepApply (buildKernelStep es st) =
      some (stepVMHashFromAction es st.action st.signer) := by
  unfold kernelStepApply buildKernelStep stepVMHashFromAction
  have h := buildKernelStep_verifies es st
  simp only [h, if_true]
  rfl

/-! ## Smoke checks -/

/-- Spot-check: the chain reduction on the empty list returns
    the initial commit. -/
example (c : StateCommit) : chainKernelStepApply c [] = some c := rfl

end FaultProof
end LegalKernel
