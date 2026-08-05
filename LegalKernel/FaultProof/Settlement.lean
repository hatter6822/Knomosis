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
      * The game is `inProgress` with no bisection round open.
      * The range has narrowed to a single step.
      * The submitted step starts from the COMMITTED pre-state
        (`gs.range.low.commit`) — not one of the responder's
        choosing.
      * The step VM reproduces the COMMITTED disputed endpoint
        (`gs.range.high.commit`).

    Conclusion: the responding party wins.

    Note what is *not* a hypothesis: there is no
    `claimedPostCommit`.  Both sides of the comparison the
    settlement turns on are already fixed in the game state, so the
    responder cannot supply either.  The previous statement took
    the claim as a parameter and compared it against
    `kernelStepApply step`, which returned `step.postStateCommit` —
    the responder's own field.  Both sides came from the responder,
    so the theorem held for every responder, honest or not. -/
theorem terminate_responder_wins_when_step_reproduces_high
    (gs gs' : GameState) (step : KernelStep)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_prestate : step.preStateCommit = gs.range.low.commit)
    (h_reproduces : kernelStepApply step = some gs.range.high.commit)
    (h_apply : applyTransition gs (.terminateOnSingleStep step) = .ok gs') :
    gs'.status =
      (match gs.turn with
       | .sequencer  => GameStatus.sequencerWon
       | .challenger => GameStatus.challengerWon) := by
  unfold applyTransition at h_apply
  simp [h_status, h_single_step, h_no_pending, h_prestate, h_reproduces] at h_apply
  rw [← h_apply]
  rfl

/-- The responder LOSES when the step VM does not reproduce the
    committed endpoint.

    This is the branch that carries the whole trust model: a
    sequencer defending a state root it fabricated cannot make the
    step VM agree with it, so it loses without any adjudicator
    participating. -/
theorem terminate_responder_loses_when_step_differs
    (gs gs' : GameState) (step : KernelStep) (computed : StateCommit)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_prestate : step.preStateCommit = gs.range.low.commit)
    (h_computes : kernelStepApply step = some computed)
    (h_mismatch : computed ≠ gs.range.high.commit)
    (h_apply : applyTransition gs (.terminateOnSingleStep step) = .ok gs') :
    gs'.status =
      (match gs.turn with
       | .sequencer  => GameStatus.challengerWon
       | .challenger => GameStatus.sequencerWon) := by
  unfold applyTransition at h_apply
  simp [h_status, h_single_step, h_no_pending, h_prestate, h_computes, h_mismatch]
    at h_apply
  rw [← h_apply]
  rfl

/-- The responder loses when its cell proofs fail to verify
    against the committed pre-state. -/
theorem terminate_responder_with_invalid_proofs_loses
    (gs gs' : GameState) (step : KernelStep)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_prestate : step.preStateCommit = gs.range.low.commit)
    (h_kernel_fails : kernelStepApply step = none)
    (h_apply : applyTransition gs (.terminateOnSingleStep step) = .ok gs') :
    gs'.status =
      (match gs.turn with
       | .sequencer  => GameStatus.challengerWon
       | .challenger => GameStatus.sequencerWon) := by
  unfold applyTransition at h_apply
  simp [h_status, h_single_step, h_no_pending, h_prestate, h_kernel_fails] at h_apply
  rw [← h_apply]
  rfl

/-- The responder loses when it re-executes from a pre-state that
    is not the committed `gs.range.low.commit`.

    On L1 this branch is unreachable — the contract passes
    `g.low.commit` to the step VM itself — but in the Lean model the
    pre-state travels inside the `KernelStep`, so it has to be
    rejected explicitly.  Without this, a responder could run the
    disputed step from a fabricated pre-state and manufacture
    whatever post-commit it needed. -/
theorem terminate_responder_with_wrong_prestate_loses
    (gs gs' : GameState) (step : KernelStep)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_prestate : step.preStateCommit ≠ gs.range.low.commit)
    (h_apply : applyTransition gs (.terminateOnSingleStep step) = .ok gs') :
    gs'.status =
      (match gs.turn with
       | .sequencer  => GameStatus.challengerWon
       | .challenger => GameStatus.sequencerWon) := by
  unfold applyTransition at h_apply
  simp [h_status, h_single_step, h_no_pending, h_prestate] at h_apply
  rw [← h_apply]
  rfl

/-! ## #232 — Composite trust-model upgrade theorem

The composite unifies the branches above into the proposition the
workstream exists to establish: **an honest challenger secures a
`challengerWon` settlement against a fabricated state root without
any adjudicator quorum.**

The shape changed with the adjudication.  It used to be a
disjunction over which party supplied the winning *claim*.  There
are no claims now — the settlement compares the step VM's output
against the committed endpoint — so the composite is simply: under
disagreement at the upper bound, a truthful step cannot reproduce
`gs.range.high.commit`, hence the responding sequencer loses. -/

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
    (disagreement at the upper bound) plus a kernel-truthful step,
    the sequencer defending its own disputed endpoint loses.

    The chain is short because the adjudication is now direct: the
    step VM computes `truth gs.range.high.idx`, the committed
    endpoint is something else (that is what
    `settlementDisagreement` says), so the comparison fails and the
    responder — the sequencer — loses.  No adjudicator quorum
    participates; the challenger's only obligation was to bisect
    honestly so that the sequencer owes the terminate. -/
theorem honest_challenger_wins_against_invalid_state_root
    (truth : LogIndex → StateCommit)
    (gs gs' : GameState) (step : KernelStep)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_prestate : step.preStateCommit = gs.range.low.commit)
    (h_turn : gs.turn = .sequencer)
    (h_disagree : settlementDisagreement truth gs)
    (h_kernel_truthful :
        kernelStepApply step = some (truth gs.range.high.idx))
    (h_apply : applyTransition gs (.terminateOnSingleStep step) = .ok gs') :
    gs'.status = .challengerWon := by
  have h_mismatch : truth gs.range.high.idx ≠ gs.range.high.commit :=
    Ne.symm h_disagree
  have h := terminate_responder_loses_when_step_differs
              gs gs' step (truth gs.range.high.idx)
              h_status h_single_step h_no_pending h_prestate
              h_kernel_truthful h_mismatch h_apply
  rw [h, h_turn]

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
