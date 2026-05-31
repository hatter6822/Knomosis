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
import LegalKernel.FaultProof.Step
import LegalKernel.FaultProof.StepVariants
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

/-- The semantic core of one kernel step: the post-state
    produced by applying the signed action to the pre-state.

    By construction, this is the dispute-pipeline's
    `kernelOnlyApply` (defined in `Disputes/Evidence.lean`).
    Wrapping a `SignedAction` into a `LogEntry` for compatibility
    with `kernelOnlyApply`'s signature is via
    `signedActionToLogEntry` below. -/
def applyCellWrites_to_state
    (es : ExtendedState) (st : SignedAction) : ExtendedState :=
  let entry : LogEntry := {
    prevHash := ByteArray.empty,
    signedAction := st,
    postStateHash := ByteArray.empty  -- not consumed by kernelOnlyApply
  }
  kernelOnlyApply es entry

/-! ## `recomputeCommitment` (Merkle bookkeeping)

Compute the post-state commit after the cell writes.  By the
witness-state design, this is just `commitExtendedState` of the
semantic-core's output. -/

/-- Recompute the post-state commit after applying the action.
    By construction, this is `commitExtendedState` of the
    semantic-core output. -/
def recomputeCommitment
    (es : ExtendedState) (st : SignedAction) : StateCommit :=
  commitExtendedState (applyCellWrites_to_state es st)

/-! ## Determinism + reduction lemmas -/

/-- `applyCellWrites_to_state` is deterministic. -/
theorem applyCellWrites_to_state_deterministic
    (es₁ es₂ : ExtendedState) (st₁ st₂ : SignedAction)
    (h_es : es₁ = es₂) (h_st : st₁ = st₂) :
    applyCellWrites_to_state es₁ st₁ = applyCellWrites_to_state es₂ st₂ := by
  rw [h_es, h_st]

/-- #249 — `applyCellWrites_to_state` is type-level total.  By
    virtue of being a total Lean function returning
    `ExtendedState` (not `Option ExtendedState`), every input
    has a defined result.  The plan-spec's
    "admissibility-conditioned" form follows directly: every
    admissible input has a result (because every input does). -/
theorem applyCellWrites_to_state_total
    (es : ExtendedState) (st : SignedAction) :
    ∃ es', applyCellWrites_to_state es st = es' :=
  ⟨applyCellWrites_to_state es st, rfl⟩

/-- `recomputeCommitment` is deterministic. -/
theorem recomputeCommitment_deterministic
    (es₁ es₂ : ExtendedState) (st₁ st₂ : SignedAction)
    (h_es : es₁ = es₂) (h_st : st₁ = st₂) :
    recomputeCommitment es₁ st₁ = recomputeCommitment es₂ st₂ := by
  rw [h_es, h_st]

/-- `recomputeCommitment` is extensional: equal post-states ⇒
    equal recommitted hashes. -/
theorem recomputeCommitment_extensional
    (es₁ es₂ : ExtendedState) (st : SignedAction)
    (h : applyCellWrites_to_state es₁ st = applyCellWrites_to_state es₂ st) :
    recomputeCommitment es₁ st = recomputeCommitment es₂ st := by
  unfold recomputeCommitment
  rw [h]

/-! ## #225 — Coherence with `kernelOnlyApply` -/

/-- #225 — `recomputeCommitment` agrees with `commitExtendedState
    ∘ kernelOnlyApply`.  By construction (rfl).

    This is the headline coherence theorem of Workstream H: the
    L1 step VM (whose Lean reference is `recomputeCommitment`)
    produces exactly the same post-commit as the L2 kernel
    (whose semantics is `kernelOnlyApply`).

    **Scope.**  `kernelOnlyApply` is the kernel-EXECUTION semantics
    — `base` balances, `nonces`, `registry`, and `localPolicies`.
    It leaves the bridge ledger (`consumed` / `pending` / `nextWdId`)
    invariant (`applyCellWrites_to_state_preserves_bridge` below), so
    the bisection-adjudicated state-commitment chain holds the bridge
    sub-state CONSTANT across every adjudicated step.  The bridge
    ledger's own evolution — deposit-replay protection and withdrawal
    tracking — is verified by the dedicated bridge machinery
    (`BridgeAdmissibleWith`'s deposit-id-freshness conjuncts at
    admission and the §13 withdrawal-proof + finalisation chain on
    L1), NOT by the per-step bisection game.

    Cross-stack equivalence with the Solidity-side implementation
    is established by the WU H.10.1 fixture corpus; the
    Solidity-side step VM is required to produce the same bytes
    as `recomputeCommitment` for every cross-check fixture. -/
theorem recomputeCommitment_coherent_with_kernelOnlyApply
    (es : ExtendedState) (st : SignedAction)
    (entry : LogEntry)
    (h_entry : entry.signedAction = st) :
    recomputeCommitment es st =
    commitExtendedState (kernelOnlyApply es entry) := by
  unfold recomputeCommitment applyCellWrites_to_state
  -- The two `kernelOnlyApply` calls receive the same signed action
  -- (h_entry) and the same pre-state.  The `prevHash` and
  -- `postStateHash` fields of `LogEntry` aren't consumed by
  -- `kernelOnlyApply`, so the result depends only on signedAction
  -- and pre-state.
  congr 1
  -- We need to show kernelOnlyApply is invariant in the unused
  -- LogEntry fields.  This follows from the definition's match on
  -- entry.signedAction.action.
  rcases entry with ⟨prevHash, signedAction, postStateHash⟩
  simp only at h_entry
  -- entry = { prevHash := prevHash, signedAction := signedAction := st,
  --           postStateHash := postStateHash }
  unfold kernelOnlyApply
  rw [h_entry]

/-- **Fault-proof scope invariant (bridge sub-state).**  The fault
    proof's per-step reference transition `applyCellWrites_to_state`
    (= `kernelOnlyApply`) leaves the bridge sub-state unchanged.
    Consequently the L1 step VM re-derives only the kernel-execution
    sub-state; the `consumed` / `pending` / `nextWdId` bridge ledger is
    held constant across every step the bisection game adjudicates.

    This is the type-level statement of the Workstream-H scope
    boundary.  The bridge ledger's own evolution is verified by the
    dedicated bridge machinery (deposit-id freshness at
    `BridgeAdmissibleWith` admission and the §13 withdrawal-proof +
    finalisation chain on L1), not by the per-step game.  See
    `Disputes.kernelOnlyApply_preserves_bridge`. -/
theorem applyCellWrites_to_state_preserves_bridge
    (es : ExtendedState) (st : SignedAction) :
    (applyCellWrites_to_state es st).bridge = es.bridge := by
  unfold applyCellWrites_to_state
  exact kernelOnlyApply_preserves_bridge es _

/-! ## #253 — Multi-step coherence with `kernelOnlyReplay`

The multi-step generalisation: a chain of per-step semantic-core
applications threaded through a log agrees with `kernelOnlyReplay`
on the same log.  Concretely, we define a `foldOverLog` function
that maps each log entry through `applyCellWrites_to_state` and
threads the state, then prove it equals `kernelOnlyReplay`. -/

/-- The fold-over-log form of the multi-step kernel-step chain.
    Threads `applyCellWrites_to_state` through the entire log,
    starting from `es`.  Equivalent to `kernelOnlyReplay` by
    definition of `applyCellWrites_to_state`. -/
def foldStepApplyOverLog
    (es : ExtendedState) : List LogEntry → ExtendedState
  | []       => es
  | e :: rest =>
    foldStepApplyOverLog
      (applyCellWrites_to_state es e.signedAction) rest

/-- The empty-log reduction of `foldStepApplyOverLog`. -/
theorem foldStepApplyOverLog_nil (es : ExtendedState) :
    foldStepApplyOverLog es [] = es := rfl

/-- The cons-step reduction of `foldStepApplyOverLog`: one step of
    semantic application + the rest of the chain. -/
theorem foldStepApplyOverLog_cons
    (es : ExtendedState) (e : LogEntry) (rest : List LogEntry) :
    foldStepApplyOverLog es (e :: rest) =
    foldStepApplyOverLog
      (applyCellWrites_to_state es e.signedAction) rest := rfl

/-- **Per-step bridge**: `applyCellWrites_to_state es st` equals
    `kernelOnlyApply` applied to a `LogEntry` whose
    `signedAction = st`.  This follows from
    `applyCellWrites_to_state`'s definition (which wraps `st` into
    a synthetic entry) plus the fact that `kernelOnlyApply` only
    consumes `entry.signedAction`. -/
theorem applyCellWrites_to_state_eq_kernelOnlyApply
    (es : ExtendedState) (entry : LogEntry) :
    applyCellWrites_to_state es entry.signedAction =
    kernelOnlyApply es entry := by
  unfold applyCellWrites_to_state
  -- The synthetic entry's `signedAction` equals `entry.signedAction`
  -- by construction; `kernelOnlyApply` ignores `prevHash` and
  -- `postStateHash` (it only matches on `entry.signedAction.action`
  -- and reads `entry.signedAction.signer`).
  rcases entry with ⟨_prevHash, signedAction, _postStateHash⟩
  unfold kernelOnlyApply
  simp only

/-- #253 — Multi-step coherence: the fold-over-log application of
    `applyCellWrites_to_state` agrees with `kernelOnlyReplay` on
    the same log.

    This is the multi-step generalisation of theorem #225 (the
    per-step coherence).  Proof: structural induction on `log`,
    using the per-step bridge at each cons. -/
theorem foldStepApplyOverLog_eq_kernelOnlyReplay
    (es : ExtendedState) (log : List LogEntry) :
    foldStepApplyOverLog es log = kernelOnlyReplay es log := by
  induction log generalizing es with
  | nil =>
    -- foldStepApplyOverLog es [] = es;
    -- kernelOnlyReplay es [] = es.
    rfl
  | cons e rest ih =>
    -- foldStepApplyOverLog es (e :: rest) =
    --   foldStepApplyOverLog (applyCellWrites_to_state es e.signedAction) rest
    -- by IH = kernelOnlyReplay (applyCellWrites_to_state es e.signedAction) rest
    -- by per-step bridge = kernelOnlyReplay (kernelOnlyApply es e) rest
    -- = kernelOnlyReplay es (e :: rest)   (by definition of kernelOnlyReplay)
    unfold foldStepApplyOverLog
    rw [applyCellWrites_to_state_eq_kernelOnlyApply es e]
    rw [ih (kernelOnlyApply es e)]
    -- Goal: kernelOnlyReplay (kernelOnlyApply es e) rest =
    --       kernelOnlyReplay es (e :: rest)
    unfold kernelOnlyReplay
    simp [List.foldl_cons]

/-- #253 (commit-level form) — Multi-step coherence at the commit
    level: folding the per-step recomputed commit through the log
    yields the same value as `commitExtendedState (kernelOnlyReplay
    es log)`.  Direct corollary of the state-level form. -/
theorem recomputeCommitment_chain_coherent_with_kernelOnlyReplay
    (es : ExtendedState) (log : List LogEntry) :
    commitExtendedState (foldStepApplyOverLog es log) =
    commitExtendedState (kernelOnlyReplay es log) := by
  rw [foldStepApplyOverLog_eq_kernelOnlyReplay]

/-! ## Reduction theorem for `kernelStepApply` (interface coherence)

The `kernelStepApply` function (defined in `Step.lean`) verifies
the cell proofs and returns the claimed `postStateCommit` if
verification succeeds.  Coherence with the semantic core
(`recomputeCommitment`) requires that the claimed
`postStateCommit` actually equals `recomputeCommitment` — i.e.
the responding party must compute it correctly to win the game.

The L1 game contract enforces this *operationally*: in
`terminateOnSingleStep`, the L1 step VM computes
`recomputeCommitment` itself and compares against the responding
party's claim.  The `kernelStepApply` function in Lean is the
*verifier-side* form; the comparison happens in the
`terminateOnSingleStep` transition (see `Game.lean`).

The theorem below establishes the reduction: under the
canonical `buildCellProofs` (where every proof's witnessState is
the full pre-state) plus a correctly-claimed post-commit,
`kernelStepApply` returns `some (recomputeCommitment es st)`. -/

/-- Build the full canonical cell-proof bundle for a state +
    action: one cell proof per required cell tag, all witness
    states equal to the pre-state. -/
def buildCellProofsForAction
    (es : ExtendedState) (st : SignedAction) : CellProofBundle :=
  { proofs := (Authority.Action.requiredCells st.action st.signer).map
                (fun t => buildCellProof es t) }

/-- The canonical `KernelStep` derived from a pre-state + signed
    action.  Used by the responding party in
    `terminateOnSingleStep`. -/
def buildKernelStep
    (es : ExtendedState) (st : SignedAction) : KernelStep where
  preStateCommit  := commitExtendedState es
  signedAction    := st
  postStateCommit := recomputeCommitment es st
  cellProofs      := buildCellProofsForAction es st

/-- The canonical KernelStep verifies (cell proofs all verify
    against the pre-state commit). -/
theorem buildKernelStep_verifies (es : ExtendedState) (st : SignedAction) :
    verifyCellProofs (commitExtendedState es)
      (buildCellProofsForAction es st) = true := by
  unfold buildCellProofsForAction
  exact verifyCellProofs_complete_for_canonical_bundle es _

/-- The canonical KernelStep's `kernelStepApply` returns
    `some (recomputeCommitment es st)`.  By construction. -/
theorem kernelStepApply_canonical
    (es : ExtendedState) (st : SignedAction) :
    kernelStepApply (buildKernelStep es st) =
    some (recomputeCommitment es st) := by
  unfold kernelStepApply buildKernelStep
  -- The verify check passes by `buildKernelStep_verifies`; the
  -- function returns `some step.postStateCommit` =
  -- `some (recomputeCommitment es st)`.
  have h := buildKernelStep_verifies es st
  simp [h]

end FaultProof
end LegalKernel
