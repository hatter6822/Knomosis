-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Coherence — `applyCellWrites`,
`recomputeCommitment`, and the headline coherence theorem
#225 (Workstream H WUs H.1.2 + H.1.3).

**Design rationale (witness-state-bearing).**

The plan §5.2 calls for:

  * `applyCellWrites` — the semantic core: given pre-cell values
    and the action, what are the new cell values?
  * `recomputeCommitment` — the Merkle bookkeeping: given new
    cell values + the original Merkle paths, what's the new
    top-level commit?
  * `kernelStepApply` composes them with proof verification.

Under the witness-state-bearing design (Verify.lean), the
"semantic core" is just `kernelOnlyApply` itself.  We define:

  * `applyCellWrites_to_state es action = kernelOnlyApply` post-state
  * `recomputeCommitment es action = commitExtendedState (post-state)`

This makes the coherence theorem #225 a structural `rfl`: by
definition, the post-state commit equals the kernel's
`kernelOnlyApply` output's commit.

The downside of this design is that the "semantic core" is not
*independent* of the kernel — it's literally the same function.
But for **correctness purposes**, this is exactly what we want:
the L1 step VM is required to compute `kernelOnlyApply` cell-by-
cell; the witness-state form establishes that the L1 result must
agree with `kernelOnlyApply` by construction.  L1 gas
optimisation (SMT-based per-cell compute) is a deployment-layer
concern; the cross-stack equivalence corpus (WU H.10.1) verifies
that the SMT path produces identical bytes to this canonical
form.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Disputes.Evidence
import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.Commit
import LegalKernel.FaultProof.StepVariants
import LegalKernel.FaultProof.ProductionApply
import LegalKernel.FaultProof.Verify
import LegalKernel.Runtime.LogFile

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime

/-! ## `applyCellWrites_to_state` (semantic core)

The semantic core is the existing `kernelOnlyApply` — which
already takes a `(es, entry)` pair and produces a post-state.
We expose it under a fault-proof-namespace name. -/

/-- The semantic core of one kernel step: the post-state the
    RUNTIME produces.

    This is `productionApplyBudget` — the total form of
    `apply_bridge_admissible_with_budget`, which is what
    `Runtime/Loop.lean` advances state through.  It used to be
    `kernelOnlyApply`, the dispute pipeline's analytical replay, which
    models neither bridge nor budget effects; for a deposit the two
    produce different states with different roots, and the published
    root follows the runtime.  Anchoring the fault proof to the
    analytical replay was therefore an adjudication error waiting for
    the state-root swap to make it visible.

    The `l2LogIndex` is the step's own position in the log.  The
    guarded entry point needs it for the bridge leg (a withdrawal
    records the index it was requested at), so the reference cannot
    avoid carrying it. -/
def applyCellWrites_to_state
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) : ExtendedState :=
  productionApplyBudget es st l2LogIndex

/-! ## `recomputeCommitment` (Merkle bookkeeping)

Compute the post-state commit after the cell writes.  By the
witness-state design, this is just `commitExtendedState` of the
semantic-core's output. -/

/-- Recompute the post-state commit after applying the action.
    By construction, this is `commitExtendedState` of the
    semantic-core output. -/
def recomputeCommitment
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) : StateCommit :=
  commitExtendedState (applyCellWrites_to_state es st l2LogIndex)

/-! ## Determinism + reduction lemmas -/

/-- `recomputeCommitment`'s defining equation, as a rewrite rule.

    Stated because `rfl` between it and its unfolding is not cheap:
    both sides mention `commitExtendedState`, whose body is the
    depth-256 SMT recursion, and the elaborator will try to evaluate
    that before noticing the two sides share a head. -/
theorem recomputeCommitment_def
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) :
    recomputeCommitment es st l2LogIndex
      = commitExtendedState (applyCellWrites_to_state es st l2LogIndex) := rfl

/-- `applyCellWrites_to_state` is deterministic. -/
theorem applyCellWrites_to_state_deterministic
    (es₁ es₂ : ExtendedState) (st₁ st₂ : SignedAction) (i₁ i₂ : Nat)
    (h_es : es₁ = es₂) (h_st : st₁ = st₂) (h_i : i₁ = i₂) :
    applyCellWrites_to_state es₁ st₁ i₁ = applyCellWrites_to_state es₂ st₂ i₂ := by
  rw [h_es, h_st, h_i]

/-- #249 — `applyCellWrites_to_state` is type-level total.  By
    virtue of being a total Lean function returning
    `ExtendedState` (not `Option ExtendedState`), every input
    has a defined result.  The plan-spec's
    "admissibility-conditioned" form follows directly: every
    admissible input has a result (because every input does). -/
theorem applyCellWrites_to_state_total
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) :
    ∃ es', applyCellWrites_to_state es st l2LogIndex = es' :=
  ⟨applyCellWrites_to_state es st l2LogIndex, rfl⟩

/-- `recomputeCommitment` is deterministic. -/
theorem recomputeCommitment_deterministic
    (es₁ es₂ : ExtendedState) (st₁ st₂ : SignedAction) (i₁ i₂ : Nat)
    (h_es : es₁ = es₂) (h_st : st₁ = st₂) (h_i : i₁ = i₂) :
    recomputeCommitment es₁ st₁ i₁ = recomputeCommitment es₂ st₂ i₂ := by
  rw [h_es, h_st, h_i]

/-- `recomputeCommitment` is extensional: equal post-states ⇒
    equal recommitted hashes. -/
theorem recomputeCommitment_extensional
    (es₁ es₂ : ExtendedState) (st : SignedAction) (l2LogIndex : Nat)
    (h : applyCellWrites_to_state es₁ st l2LogIndex
       = applyCellWrites_to_state es₂ st l2LogIndex) :
    recomputeCommitment es₁ st l2LogIndex = recomputeCommitment es₂ st l2LogIndex := by
  unfold recomputeCommitment
  rw [h]

/-! ## #225 — Coherence with the production advance -/

/-- #225 — `recomputeCommitment` agrees with
    `commitExtendedState ∘ productionApplyBudget`.  By construction
    (rfl).

    This is the headline coherence theorem of Workstream H, restated.
    It used to name `kernelOnlyApply`, and that statement is now
    FALSE: `productionApplyBudget` records the consumed deposit on a
    bridge action and rewrites the signer's epoch budget on every
    admitted action, neither of which the analytical replay models.
    The old form was not merely weaker — it asserted agreement with a
    function the published root does not follow.

    Agreement with the guarded entry point the runtime actually calls
    is `apply_bridge_admissible_with_budget_eq`
    (`FaultProof/ProductionApply.lean`): wherever it admits, it
    returns exactly this state.  The two together are what let the L1
    step VM compare its output to a published state root.

    Cross-stack equivalence with the Solidity step VM is established
    by the WU H.10.1 fixture corpus. -/
theorem recomputeCommitment_coherent_with_productionApplyBudget
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) :
    recomputeCommitment es st l2LogIndex
      = commitExtendedState (productionApplyBudget es st l2LogIndex) := rfl

/-- **The bridge sub-state now advances.**

    `applyCellWrites_to_state_preserves_bridge` used to assert the
    opposite — that the fault proof's reference left the bridge ledger
    constant across every adjudicated step — and it was true of
    `kernelOnlyApply`.  It was also the scope boundary that made the
    per-step game unable to adjudicate a deposit at all.  The
    reference now records the deposit, so the statement inverts. -/
theorem applyCellWrites_to_state_bridge
    (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat) :
    (applyCellWrites_to_state es st l2LogIndex).bridge
      = LegalKernel.Bridge.applyActionToBridgeState es.bridge st.action l2LogIndex :=
  productionApplyBudget_bridge es st l2LogIndex

/-! ## #253 — Multi-step coherence with the production replay

The per-step reference threads an `l2LogIndex`, so the fold has to
count.  `kernelOnlyReplay` is a plain `foldl` with no index — it does
not need one, having no bridge leg — so the multi-step statement
retargets at `productionReplayBudget` rather than losing its
counterpart. -/

/-- The fold-over-log form of the multi-step chain, threading the L2
    log index from `startIdx`. -/
def foldStepApplyOverLog
    (es : ExtendedState) (startIdx : Nat) : List LogEntry → ExtendedState
  | []       => es
  | e :: rest =>
    foldStepApplyOverLog
      (applyCellWrites_to_state es e.signedAction startIdx) (startIdx + 1) rest

/-- The empty-log reduction of `foldStepApplyOverLog`. -/
theorem foldStepApplyOverLog_nil (es : ExtendedState) (i : Nat) :
    foldStepApplyOverLog es i [] = es := rfl

/-- The cons-step reduction: one semantic application at `i`, then the
    rest of the chain from `i + 1`. -/
theorem foldStepApplyOverLog_cons
    (es : ExtendedState) (i : Nat) (e : LogEntry) (rest : List LogEntry) :
    foldStepApplyOverLog es i (e :: rest) =
    foldStepApplyOverLog
      (applyCellWrites_to_state es e.signedAction i) (i + 1) rest := rfl

/-- #253 — Multi-step coherence: folding the per-step reference
    through a log agrees with the production replay over the same
    signed actions.

    Proof: structural induction on `log`; each cons is `rfl` at the
    step level because both sides advance by `productionApplyBudget`
    at the same index. -/
theorem foldStepApplyOverLog_eq_productionReplayBudget
    (es : ExtendedState) (i : Nat) (log : List LogEntry) :
    foldStepApplyOverLog es i log
      = productionReplayBudget es i (log.map (·.signedAction)) := by
  induction log generalizing es i with
  | nil => rfl
  | cons e rest ih =>
    show foldStepApplyOverLog
           (applyCellWrites_to_state es e.signedAction i) (i + 1) rest = _
    rw [ih]
    rfl

/-- #253 (commit-level form) — the same statement at the commit
    level.  Direct corollary. -/
theorem recomputeCommitment_chain_coherent_with_productionReplayBudget
    (es : ExtendedState) (i : Nat) (log : List LogEntry) :
    commitExtendedState (foldStepApplyOverLog es i log) =
    commitExtendedState (productionReplayBudget es i (log.map (·.signedAction))) := by
  rw [foldStepApplyOverLog_eq_productionReplayBudget]

/-! ## The canonical cell-proof bundle

`buildCellProofsForAction` is the full canonical bundle for a
state + action: one cell proof per required cell tag, every
witness state equal to the pre-state.

The `KernelStep` layer built on top of it — `buildKernelStep`,
`buildKernelStep_verifies`, and the `kernelStepApply` reduction —
lives in `Step.lean`, not here.  `kernelStepApply` computes its
result through `StepVMCoherence.stepVMHash`, so `Step` imports
`StepVMCoherence`, which imports `Observer`, which imports this
module.  Keeping `KernelStep`-shaped declarations here would
require `Coherence` to import `Step` and close the cycle. -/

/-- Build the full canonical cell-proof bundle for a state +
    action: one cell proof per required cell tag, all witness
    states equal to the pre-state. -/
def buildCellProofsForAction
    (es : ExtendedState) (st : SignedAction) : CellProofBundle :=
  { proofs := (Authority.Action.requiredCells st.action st.signer).map
                (fun t => buildCellProof es t) }

/-- The canonical bundle verifies against the pre-state commit. -/
theorem buildCellProofsForAction_verifies
    (es : ExtendedState) (st : SignedAction) :
    verifyCellProofs (commitExtendedState es)
      (buildCellProofsForAction es st) = true := by
  unfold buildCellProofsForAction
  exact verifyCellProofs_complete_for_canonical_bundle es _

end FaultProof
end LegalKernel
