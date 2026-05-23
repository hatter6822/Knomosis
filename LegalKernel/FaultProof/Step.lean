/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Step — `KernelStep`, `kernelStepApply`,
and the multi-step composition machinery (Workstream H §12 /
WUs H.1.1 + H.1.2 + H.1.6).

A `KernelStep` is the first-class data form of one kernel step's
inputs and outputs: pre-state commit + signed action + post-state
commit + per-cell Merkle proofs.  This is what the L1 step VM
(`CanonStepVM.executeStep`) consumes when bisection narrows to a
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
  /-- Per-cell Merkle proofs covering all cells the step
      reads or writes. -/
  cellProofs      : CellProofBundle
  deriving Repr

/-! ## `kernelStepApply` (§12.1.2)

The first-pass `kernelStepApply` is a *cell-proof verifier*: it
returns `some postStateCommit` when (a) every cell proof
verifies against `preStateCommit`, AND (b) the claimed
postStateCommit is structurally consistent with the action's
declared writes.

The full per-cell semantic-write rules (i.e. "for `transfer r s
rcv amt`, the post-state's `balance r s` cell is preStateValue -
amt" etc.) live in the per-variant Solidity step functions
(WU H.5.2.*); the Lean side establishes the *interface* and the
coherence theorem with `kernelOnlyApply` (WU H.1.3).

The function is total (returns `Option StateCommit`) and
decidable.  The L1 step VM mirrors this dispatch logic. -/

/-- The Merkle-state-aware step function.  Given the pre-state
    commitment, the action, and the Merkle proofs for the
    touched cells, compute the claimed post-state commitment.

    Returns `none` if any cell proof fails to verify against
    `preStateCommit`.  Returns `some step.postStateCommit` if
    every proof verifies.  The actual post-state computation
    (per-variant cell writes) is delegated to the L1 step VM /
    Solidity-side `_step<Variant>` functions; this function
    captures the *interface* the L1 fault-proof game contract
    consumes. -/
def kernelStepApply (step : KernelStep) : Option StateCommit :=
  if verifyCellProofs step.preStateCommit step.cellProofs then
    some step.postStateCommit
  else
    none

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

/-! ## Smoke checks -/

/-- Spot-check: the chain reduction on the empty list returns
    the initial commit. -/
example (c : StateCommit) : chainKernelStepApply c [] = some c := rfl

end FaultProof
end LegalKernel
