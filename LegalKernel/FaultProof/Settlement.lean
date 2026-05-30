-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Settlement — composite trust-model upgrade
theorem.

Brings together the disagreement-persistence content from
`Honesty.lean`, the convergence content from `Convergence.lean`,
and the single-step termination semantics of `applyTransition` into
the **load-bearing trust-model theorem**: an invalid sequencer
claim is unconditionally refuted by an honest responding challenger
at single-step settlement.

The two atomic settlement theorems below form the composite
trust-model upgrade:

  * `honest_challenger_responds_truthfully_wins` — when the
    challenger is the responding party and submits a truthful
    step that matches the kernel's computation at the disputed
    upper bound.

  * `sequencer_responding_with_disputed_high_loses` — when the
    sequencer is the responding party and (by the bisection
    invariant) must claim its original disputed `range.high.commit`
    whose value differs from the kernel's truthful computation.

Together with the convergence theorem (`Convergence.lean`) and the
disagreement-persistence chain (`Honesty.lean`), these establish:
**any single honest challenger refutes an invalid sequencer claim**.

This module is **not** part of the trusted computing base.  Bugs
here would weaken the L1 fault-proof game's trust model but cannot
violate any kernel invariant.
-/

import LegalKernel.FaultProof.Honesty

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes

/-! ## Single-step settlement under honest challenger response

When the bisection has narrowed to a single step and the
challenger is the responding party submitting a truthful step,
the L1 step VM computes the same post-commit as the challenger's
claim and the contract awards the challenger.  This is the
"challenger wins by execution" branch. -/

/-- Settlement-time win for an honest challenger response.

    Hypotheses:
      * The game is `inProgress`.
      * It's the challenger's turn (they are the responding party).
      * The challenger's submitted `KernelStep` is truthful — its
        kernel-side `kernelStepApply` returns the same commit the
        challenger claims as `claimedPostCommit`.
      * The transition applies legally (range is single-step).

    Conclusion: the resulting game state has `status = challengerWon`.

    This is the positive branch of theorem #232 and the load-bearing
    upgrade over the Phase-6 trust assumption: there is no
    adjudicator quorum dependency, no off-chain coordination — the
    challenger's single move + the L1 step VM's deterministic check
    settles the game in their favour. -/
theorem honest_challenger_responds_truthfully_wins
    (gs gs' : GameState) (step : KernelStep)
    (claimedPostCommit : StateCommit)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_turn : gs.turn = .challenger)
    (h_kernel_matches_claim :
        kernelStepApply step = some claimedPostCommit)
    (h_apply : applyTransition gs
                  (.terminateOnSingleStep step claimedPostCommit) = .ok gs') :
    gs'.status = .challengerWon := by
  unfold applyTransition at h_apply
  -- The transition is .terminateOnSingleStep; status = inProgress,
  -- range = singleStep, kernelStepApply = some claimed; match → win.
  simp [h_status, h_single_step, h_kernel_matches_claim, h_turn] at h_apply
  -- gs' = { gs with status := challengerWon }
  rw [← h_apply]

/-! ## Single-step settlement under sequencer disagreement

When the sequencer is the responding party at single-step
termination and they claim their original `range.high.commit`
(which differs from the kernel's truthful computation by
disagreement), the L1 step VM detects the mismatch and the
contract awards the challenger.  This is the "challenger wins
by sequencer's-own-claim refutation" branch. -/

/-- Settlement-time win when the sequencer responds with the
    disputed upper-bound commit.

    Hypotheses:
      * The game is `inProgress`.
      * It's the sequencer's turn (they are the responding party).
      * The sequencer's claimed post-commit equals
        `gs.range.high.commit` (the disputed claim being defended).
      * The kernel computes a different post-commit (the truthful
        one), so the step's `kernelStepApply` result does NOT match
        the sequencer's claim.
      * The transition applies legally.

    Conclusion: the resulting game state has `status = challengerWon`.

    This is the negative branch of theorem #232: even if the
    sequencer submits a valid step, if its claim doesn't match
    the kernel's deterministic output, they lose. -/
theorem sequencer_responding_with_disputed_high_loses
    (gs gs' : GameState) (step : KernelStep)
    (computedPostCommit claimedPostCommit : StateCommit)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_turn : gs.turn = .sequencer)
    (h_kernel_computes : kernelStepApply step = some computedPostCommit)
    (h_mismatch : computedPostCommit ≠ claimedPostCommit)
    (h_apply : applyTransition gs
                  (.terminateOnSingleStep step claimedPostCommit) = .ok gs') :
    gs'.status = .challengerWon := by
  unfold applyTransition at h_apply
  simp [h_status, h_single_step, h_kernel_computes, h_turn, h_mismatch]
    at h_apply
  rw [← h_apply]

/-- Settlement-time win when the sequencer's submitted step has
    invalid cell proofs at the L1 step VM (i.e. `kernelStepApply`
    returns `none`).  An honest challenger always wins this branch
    because the responding party — the sequencer — is the one
    whose `kernelStepApply` failed.

    This handles the case where the sequencer cannot construct a
    cell-proof bundle whose `witnessCommit` matches the pre-state
    commit at the single disputed step; the L1 step VM rejects
    the submission and the bonds redistribute to the challenger. -/
theorem sequencer_responding_with_invalid_proofs_loses
    (gs gs' : GameState) (step : KernelStep)
    (claimedPostCommit : StateCommit)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_turn : gs.turn = .sequencer)
    (h_kernel_fails : kernelStepApply step = none)
    (h_apply : applyTransition gs
                  (.terminateOnSingleStep step claimedPostCommit) = .ok gs') :
    gs'.status = .challengerWon := by
  unfold applyTransition at h_apply
  simp [h_status, h_single_step, h_kernel_fails, h_turn] at h_apply
  rw [← h_apply]

/-! ## #232 — Composite trust-model upgrade theorem

The composite theorem unifies the three settlement branches
into a single proposition: **regardless of which party is
responding at single-step termination, an honest challenger
secures a `challengerWon` settlement whenever the kernel's
deterministic output refutes the sequencer's original claim.**

This is the formal expression of the trust-model upgrade from
"M-of-N adjudicators honest" (Phase 6) to "1 honest challenger"
(this workstream).  No adjudicator-quorum participation is
required; the L1 step VM is the single source of truth at
settlement, and its determinism (via the coherence theorem #225
between `kernelStepApply` and `kernelOnlyApply`) ensures that
any party with access to the canonical log can construct the
winning move. -/

/-- A predicate describing the bisection invariant maintained
    by honest challenger play, lifted to single-step termination
    time.  Equivalent to: at the upper bound of the disputed
    range, the kernel's truthful post-commit differs from the
    sequencer's original (now disputed) claim. -/
def settlementDisagreement
    (truth : LogIndex → StateCommit)
    (gs : GameState) : Prop :=
  gs.range.high.commit ≠ truth gs.range.high.idx

/-- Decidability of `settlementDisagreement`.  Reduces to
    ByteArray inequality (decidable). -/
instance instDecidableSettlementDisagreement
    (truth : LogIndex → StateCommit) (gs : GameState) :
    Decidable (settlementDisagreement truth gs) := by
  unfold settlementDisagreement
  exact inferInstance

/-- #232 — Composite trust-model upgrade theorem.

    At single-step termination, under the bisection invariant
    (disagreement at the upper bound) plus a kernel-truthful step:

      * If the challenger responds with `claimedPostCommit = truth`,
        the kernel computes the same value and the challenger wins.
      * If the sequencer responds with `claimedPostCommit =
        gs.range.high.commit` (their disputed original), the kernel
        computes the truthful value which differs from the claim
        (by `settlementDisagreement`) and the challenger wins.

    Either way, the final status is `challengerWon`.

    The hypothesis `h_response_branch` is the disjunction that the
    honest strategy supplies: the challenger always picks the
    truthful claim; the sequencer (under the bisection invariant)
    is forced to defend its disputed claim. -/
theorem honest_challenger_wins_against_invalid_state_root
    (truth : LogIndex → StateCommit)
    (gs gs' : GameState) (step : KernelStep)
    (claimedPostCommit computedPostCommit : StateCommit)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_disagree : settlementDisagreement truth gs)
    (h_kernel_truthful :
        kernelStepApply step = some computedPostCommit)
    (h_computed_eq_truth :
        computedPostCommit = truth gs.range.high.idx)
    (h_response_branch :
        (gs.turn = .challenger ∧ claimedPostCommit = computedPostCommit)
        ∨ (gs.turn = .sequencer ∧ claimedPostCommit = gs.range.high.commit))
    (h_apply : applyTransition gs
                  (.terminateOnSingleStep step claimedPostCommit) = .ok gs') :
    gs'.status = .challengerWon := by
  rcases h_response_branch with ⟨h_turn, h_chal_claim⟩ | ⟨h_turn, h_seq_claim⟩
  · -- Challenger responds truthfully.
    rw [h_chal_claim] at h_apply
    exact honest_challenger_responds_truthfully_wins
            gs gs' step computedPostCommit h_status h_single_step h_turn
            h_kernel_truthful h_apply
  · -- Sequencer responds with disputed-high.commit; kernel disagrees.
    have h_mismatch : computedPostCommit ≠ claimedPostCommit := by
      rw [h_seq_claim, h_computed_eq_truth]
      exact Ne.symm h_disagree
    exact sequencer_responding_with_disputed_high_loses
            gs gs' step computedPostCommit claimedPostCommit
            h_status h_single_step h_turn h_kernel_truthful h_mismatch h_apply

/-! ## Trace-level composition with `disagreement_persists_along_trace`

The composite theorem above operates at single-step termination.
The full bisection-game trust-model corollary chains it with the
trace-level disagreement persistence + the convergence theorem
(#231) to yield: "an honest challenger, starting from a wrong
sequencer claim, plays the game to a single-step termination that
the L1 step VM resolves in their favour."

The bridging lemma below extracts the `settlementDisagreement`
predicate from the `inDisagreementWithTruth` predicate that the
trace-level chain produces. -/

/-- Bridge from the trace-level disagreement invariant (`inDisagreementWithTruth`)
    to the settlement-time disagreement (`settlementDisagreement`).
    The trace-level invariant is strictly stronger; this bridge
    projects out the upper-bound disagreement that settlement
    consumes. -/
theorem inDisagreementWithTruth_implies_settlementDisagreement
    (truth : LogIndex → StateCommit) (gs : GameState)
    (h : inDisagreementWithTruth truth gs) :
    settlementDisagreement truth gs := by
  exact h.2

/-! ## Smoke checks

Each of the per-branch theorems closes by `rfl`-class tactics
after unfolding `applyTransition`; the composite uses
`rcases` + the per-branch theorems.  No `sorry`, no
`Classical.choice` invocation. -/

/-- Spot-check: `settlementDisagreement` reduces to plain
    `ByteArray ≠` on the relevant fields. -/
example (truth : LogIndex → StateCommit) (gs : GameState)
    (h : gs.range.high.commit ≠ truth gs.range.high.idx) :
    settlementDisagreement truth gs := h

end FaultProof
end LegalKernel
