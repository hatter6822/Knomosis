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
import LegalKernel.FaultProof.Terminate
import LegalKernel.FaultProof.Verify

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority

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
  /-- The log index this step produces.  `withdraw`'s
      pending-withdrawal record carries it, so the verifier has to be
      told which index it is adjudicating.  On L1 the game supplies
      `g.high.idx` rather than reading it from the caller. -/
  l2LogIndex      : Nat
  /-- The step's DEDUPLICATING PRE-ROOT MULTIPROOF: the frontier's
      cells with their proven pre-values, in any order, and the single
      shared wire.

      Replaced a `policyOpening` + `writeOpenings` pair.  The policy
      cell is no longer beside the bundle — a read is a write of the
      same value, so it is one more cell in the frontier — and the
      openings are no longer chained, so there is no order to get
      wrong and a cell written twice appears once. -/
  bundle          : MultiBundle
  deriving Repr

/-! ## `kernelStepApply` (§12.1.2)

`kernelStepApply` is the Lean model of
`KnomosisFaultProofGame.terminateOnSingleStep`'s call into the step
VM: it folds the step's DERIVED cell writes into the pre-state root
and returns the post-state root.

It has been wrong twice, in opposite directions, and both are worth
keeping on the record.

First it returned `step.postStateCommit` — the *responder's own
claim* — whenever the proofs verified, and `verifyCellProofs` is
`List.all` over the bundle, so an **empty** bundle verified
vacuously.  A responder could hand in an empty proof bundle carrying
any post-commit they liked and win.

Then it computed through `stepVMHash`, a bespoke per-variant hash
that lives outside state-root space.  That was faithful to the
contract of the day — and the contract could not adjudicate, because
its terminal comparison was between two different constructions.

It now routes through `verifierPostRoot`, which is what
`KnomosisStepVMRoot.executeStepToRoot` computes: the cell list and
every cell's value DERIVED from the proven pre-values, then folded.
A responder supplies openings, not values. -/

/-- The Merkle-state-aware step function.  Given the pre-state ROOT,
    the action, the log index, the read-only budget-policy opening and
    the step's chained write openings, **compute** the post-state
    root.

    Returns `none` on any refusal: a non-adjudicable action, a policy
    opening that does not verify or does not name the policy cell, a
    bundle whose cells are not the ones the action writes, a missing
    or malformed pre-value, or an opening that does not verify against
    the running root.  A failing law precondition is NOT a refusal —
    it is a no-op, and the fold still lands on the resulting root.

    `step.postStateCommit` is deliberately **not** consulted: it is
    the claim under dispute, and a function that returned it would
    make the single-step adjudication self-affirming. -/
def kernelStepApply (step : KernelStep) : Option StateCommit :=
  verifierPostRootMulti step.preStateCommit step.signedAction.action
    step.signedAction.signer step.l2LogIndex step.bundle

/-- `kernelStepApply` agrees with the claim exactly when the claim is
    the root the fold reaches.  The correctness of the claim is an
    explicit hypothesis rather than something the function assumes —
    folding it into the definition is what made the adjudication
    vacuous. -/
theorem kernelStepApply_eq_claim_iff_correct (step : KernelStep) :
    kernelStepApply step = some step.postStateCommit ↔
      verifierPostRootMulti step.preStateCommit step.signedAction.action
        step.signedAction.signer step.l2LogIndex
        step.bundle = some step.postStateCommit :=
  Iff.rfl

/-- An empty opening bundle no longer wins the game for free — and
    now it does not even parse.  Every one of the twenty-five action
    variants writes the signer's nonce and epoch budget, so the
    verifier's re-derived cell list is never empty and a bundle that
    is fails the shape check.

    This is the regression the old `some step.postStateCommit` body
    could not satisfy for any statement at all, strengthened: it used
    to return the step VM's own output on an empty bundle (a value the
    responder did not control, but a value); it now returns
    nothing. -/
theorem kernelStepApply_empty_bundle_refused
    (pre : StateCommit) (sa : SignedAction) (claim : StateCommit)
    (idx : Nat) (wire : SmtMultiProof)
    (h_adj : FaultProofAdjudicable sa.action = true) :
    kernelStepApply
        { preStateCommit := pre, signedAction := sa,
          postStateCommit := claim, l2LogIndex := idx,
          bundle := { cells := [], proof := wire } } = none := by
  unfold kernelStepApply verifierPostRootMulti
  -- The frontier leads with the read-only budget-policy cell on every
  -- variant, so it is never empty and an empty submission fails the
  -- shape check before the wire is read.  No per-variant case split:
  -- the chained form needed one, because the fact came from
  -- `writeCells` naming the nonce and the epoch budget; here it is a
  -- property of the list's shape.
  simp only [h_adj, not_true, if_false, ne_eq, frontierShapeOk_nil_of_cons,
    List.map_nil]
  rw [if_pos (show ¬(false = true) by simp)]

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
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) : KernelStep where
  preStateCommit  := commitExtendedState es
  signedAction    := st
  postStateCommit := recomputeCommitment es st l2LogIndex
  l2LogIndex      := l2LogIndex
  bundle          := stepMultiBundle es st

/-- The canonical step's pre-commit, as a projection lemma.

    Stated so downstream proofs can rewrite instead of forcing `rfl`
    through the whole record — `postStateCommit` now carries the
    production advance, and `whnf` on the full structure is expensive
    enough to hit the heartbeat limit. -/
theorem buildKernelStep_preStateCommit
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) :
    (buildKernelStep es st l2LogIndex).preStateCommit = commitExtendedState es := rfl

set_option maxHeartbeats 1000000 in
/-- The canonical step's post-commit, as a projection lemma.

    The heartbeat bump is not hiding a loop: the defeq is finite but
    large.  Both sides reduce through `recomputeCommitment` to
    `commitExtendedState`, whose body is the depth-256 SMT recursion,
    and the elaborator walks into it rather than stopping at the
    shared head.  Proving it once here means downstream proofs rewrite
    with this lemma instead of each paying the same cost. -/
theorem buildKernelStep_postStateCommit
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) :
    (buildKernelStep es st l2LogIndex).postStateCommit
      = recomputeCommitment es st l2LogIndex := by
  unfold buildKernelStep
  rfl

/-- **The canonical step's `kernelStepApply` IS the verifier on the
    honest bundle.**

    This is the statement that ties the Lean game model to the L1
    contract: the right-hand side is exactly what
    `KnomosisStepVMRoot.executeStepToRoot` computes, argument for
    argument, and the openings are the ones
    `TerminateBundle.buildTerminateBundle` emits.

    Note what it does **not** say.  The old form claimed
    `= some (recomputeCommitment es st)`, which held only because the
    function returned the claim it was handed.  A later form claimed
    `= some (stepVMHashFromAction …)`, which was faithful to a
    contract that could not adjudicate — `stepVMHash` lives outside
    state-root space.  That the fold LANDS on the published root — the
    root the honest sequencer published — is checked over twenty
    probes by `faultproof-terminate`, covering the chained pair, the
    duplicate cell, the failing precondition and the state-keyed
    write. -/
theorem kernelStepApply_canonical
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) :
    kernelStepApply (buildKernelStep es st l2LogIndex) =
      verifierPostRootMulti (commitExtendedState es) st.action st.signer
        l2LogIndex (stepMultiBundle es st) := rfl

/-! ## Smoke checks -/

/-- Spot-check: the chain reduction on the empty list returns
    the initial commit. -/
example (c : StateCommit) : chainKernelStepApply c [] = some c := rfl

end FaultProof
end LegalKernel
