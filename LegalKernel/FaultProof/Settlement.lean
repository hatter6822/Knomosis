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
    (gs gs' : GameState) (step : KernelStep) (actionProof : SmtCellProof)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_sig : step.signedAction.sig.size = 65)
    (h_auth : verifyActionProof gs.actionsRoot gs.range.low.idx
      (actionLeafValue step.signedAction) actionProof = true)
    (h_prestate : step.preStateCommit = gs.range.low.commit)
    (h_idx : step.l2LogIndex = gs.range.high.idx)
    (h_reproduces : kernelStepApply step = some gs.range.high.commit)
    (h_apply : applyTransition gs (.terminateOnSingleStep step actionProof)
      = .ok gs') :
    gs'.status =
      (match gs.turn with
       | .sequencer  => GameStatus.sequencerWon
       | .challenger => GameStatus.challengerWon) := by
  unfold applyTransition at h_apply
  simp [h_status, h_single_step, h_no_pending, h_sig, h_auth, h_prestate,
    h_idx, h_reproduces] at h_apply
  rw [← h_apply]
  rfl

/-- The responder LOSES when the step VM does not reproduce the
    committed endpoint.

    This is the branch that carries the whole trust model: a
    sequencer defending a state root it fabricated cannot make the
    step VM agree with it, so it loses without any adjudicator
    participating. -/
theorem terminate_responder_loses_when_step_differs
    (gs gs' : GameState) (step : KernelStep) (actionProof : SmtCellProof)
    (computed : StateCommit)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_sig : step.signedAction.sig.size = 65)
    (h_auth : verifyActionProof gs.actionsRoot gs.range.low.idx
      (actionLeafValue step.signedAction) actionProof = true)
    (h_prestate : step.preStateCommit = gs.range.low.commit)
    (h_idx : step.l2LogIndex = gs.range.high.idx)
    (h_computes : kernelStepApply step = some computed)
    (h_mismatch : computed ≠ gs.range.high.commit)
    (h_apply : applyTransition gs (.terminateOnSingleStep step actionProof)
      = .ok gs') :
    gs'.status =
      (match gs.turn with
       | .sequencer  => GameStatus.challengerWon
       | .challenger => GameStatus.sequencerWon) := by
  unfold applyTransition at h_apply
  simp [h_status, h_single_step, h_no_pending, h_sig, h_auth, h_prestate,
    h_idx, h_computes, h_mismatch] at h_apply
  rw [← h_apply]
  rfl

/-- The responder loses when its cell proofs fail to verify
    against the committed pre-state. -/
theorem terminate_responder_with_invalid_proofs_loses
    (gs gs' : GameState) (step : KernelStep) (actionProof : SmtCellProof)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_sig : step.signedAction.sig.size = 65)
    (h_auth : verifyActionProof gs.actionsRoot gs.range.low.idx
      (actionLeafValue step.signedAction) actionProof = true)
    (h_prestate : step.preStateCommit = gs.range.low.commit)
    (h_idx : step.l2LogIndex = gs.range.high.idx)
    (h_kernel_fails : kernelStepApply step = none)
    (h_apply : applyTransition gs (.terminateOnSingleStep step actionProof)
      = .ok gs') :
    gs'.status =
      (match gs.turn with
       | .sequencer  => GameStatus.challengerWon
       | .challenger => GameStatus.sequencerWon) := by
  unfold applyTransition at h_apply
  simp [h_status, h_single_step, h_no_pending, h_sig, h_auth, h_prestate,
    h_idx, h_kernel_fails] at h_apply
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
    (gs gs' : GameState) (step : KernelStep) (actionProof : SmtCellProof)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_sig : step.signedAction.sig.size = 65)
    (h_auth : verifyActionProof gs.actionsRoot gs.range.low.idx
      (actionLeafValue step.signedAction) actionProof = true)
    (h_prestate : step.preStateCommit ≠ gs.range.low.commit)
    (h_apply : applyTransition gs (.terminateOnSingleStep step actionProof)
      = .ok gs') :
    gs'.status =
      (match gs.turn with
       | .sequencer  => GameStatus.challengerWon
       | .challenger => GameStatus.sequencerWon) := by
  unfold applyTransition at h_apply
  simp [h_status, h_single_step, h_no_pending, h_sig, h_auth, h_prestate]
    at h_apply
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
    (gs gs' : GameState) (step : KernelStep) (actionProof : SmtCellProof)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_sig : step.signedAction.sig.size = 65)
    (h_auth : verifyActionProof gs.actionsRoot gs.range.low.idx
      (actionLeafValue step.signedAction) actionProof = true)
    (h_prestate : step.preStateCommit = gs.range.low.commit)
    (h_idx : step.l2LogIndex = gs.range.high.idx)
    (h_turn : gs.turn = .sequencer)
    (h_disagree : settlementDisagreement truth gs)
    (h_kernel_truthful :
        kernelStepApply step = some (truth gs.range.high.idx))
    (h_apply : applyTransition gs (.terminateOnSingleStep step actionProof)
      = .ok gs') :
    gs'.status = .challengerWon := by
  have h_mismatch : truth gs.range.high.idx ≠ gs.range.high.commit :=
    Ne.symm h_disagree
  have h := terminate_responder_loses_when_step_differs
              gs gs' step actionProof (truth gs.range.high.idx)
              h_status h_single_step h_no_pending h_sig h_auth h_prestate
              h_idx h_kernel_truthful h_mismatch h_apply
  rw [h, h_turn]

/-- `honest_challenger_wins_against_invalid_state_root` with the bare
    turn hypothesis replaced by the turn–pending ALIGNMENT invariant
    (Workstream SB).

    The bare `h_turn` was load-bearing and unpinned: it happened to
    match the L1 deployment because the contract's turn discipline
    makes the sequencer the only party ever obligated to terminate,
    but nothing tied the hypothesis to that discipline — a transition
    flipping the turn an odd number of times would have silently
    unmoored the theorem from the deployment.  Here the turn is
    DERIVED: `turnAlignedWithPending` is preserved by every legal
    transition (`turn_aligned_preserved`) from the L1 starting shape
    (`turn_aligned_of_start`), and at the only game shape terminate
    accepts — no pending midpoint — it forces `turn = sequencer`. -/
theorem honest_challenger_wins_of_turn_aligned
    (truth : LogIndex → StateCommit)
    (gs gs' : GameState) (step : KernelStep) (actionProof : SmtCellProof)
    (h_status : gs.status = .inProgress)
    (h_single_step : gs.range.isSingleStep)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_sig : step.signedAction.sig.size = 65)
    (h_auth : verifyActionProof gs.actionsRoot gs.range.low.idx
      (actionLeafValue step.signedAction) actionProof = true)
    (h_prestate : step.preStateCommit = gs.range.low.commit)
    (h_idx : step.l2LogIndex = gs.range.high.idx)
    (h_aligned : turnAlignedWithPending gs)
    (h_disagree : settlementDisagreement truth gs)
    (h_kernel_truthful :
        kernelStepApply step = some (truth gs.range.high.idx))
    (h_apply : applyTransition gs (.terminateOnSingleStep step actionProof)
      = .ok gs') :
    gs'.status = .challengerWon :=
  honest_challenger_wins_against_invalid_state_root truth gs gs' step
    actionProof h_status h_single_step h_no_pending h_sig h_auth h_prestate
    h_idx (terminate_owner_is_sequencer h_aligned h_no_pending)
    h_disagree h_kernel_truthful h_apply

/-! ## The anchor's inversion + the anchored composite (Workstream SB
follow-up: the audit-22 model-chain-binding MAJOR)

`terminate_ok_requires_authentication` is the pin that the model no
longer adjudicates an unauthenticated action: EVERY `.ok` outcome of
a terminate passed the inclusion gate, so the executed spelling is
one that opens at the disputed index against the game's anchored
actions root.

`anchored_challenger_wins` is the upgraded #232 the audit asked for.
The old composite ASSUMED kernel-truthfulness of the responder's own
step (`h_kernel_truthful` was a hypothesis about `step`, a value the
responder chooses).  Here truthfulness is a hypothesis about the
BATCH-COMMITTED spelling — an L1-observable object fixed before the
game opened — and the responder's step is FORCED to that spelling by
`actionProof_binds_action`: its leaf opens at the same `(root,
index)` as the committed one, so under collision-freeness it IS the
committed `(kind, signer, fields, sig)` tuple.  The attack the audit
constructed — the sequencer picking a different action `st'` whose
honest bundle reproduces its fabricated root — is unrepresentable:
`st'` does not open in the batch, so its terminate is an `.error`,
not a settlement. -/

/-- **Inversion: a terminate only settles on an authenticated
    action.**  Any `.ok` outcome of `terminateOnSingleStep` implies
    the executed action's signature has the fixed 65-byte width and
    its signature-bound leaf opens at the disputed index against the
    game's anchored actions root. -/
theorem terminate_ok_requires_authentication
    {gs gs' : GameState} {step : KernelStep} {actionProof : SmtCellProof}
    (h_apply : applyTransition gs (.terminateOnSingleStep step actionProof)
      = .ok gs') :
    step.signedAction.sig.size = 65 ∧
      verifyActionProof gs.actionsRoot gs.range.low.idx
        (actionLeafValue step.signedAction) actionProof = true := by
  simp only [applyTransition] at h_apply
  split at h_apply
  · exact absurd h_apply (by simp)      -- gameAlreadyEnded
  · split at h_apply
    · exact absurd h_apply (by simp)    -- rangeNotSingleStep
    · split at h_apply
      · exact absurd h_apply (by simp)  -- terminationDuringBisection
      · split at h_apply
        · exact absurd h_apply (by simp)  -- the auth guard fired
        · -- The auth guard did NOT fire: extract the two conjuncts.
          rename_i h_guard
          rw [not_or] at h_guard
          obtain ⟨h_sig, h_auth⟩ := h_guard
          exact ⟨Decidable.of_not_not h_sig, Decidable.of_not_not h_auth⟩

/-- **The anchored composite (#232, upgraded).**  At single-step
    termination against a fabricated endpoint, with the game anchored
    to a batch that commits the TRUE spelling at the disputed index,
    the responding sequencer loses — where kernel-truthfulness is
    stated over the COMMITTED spelling, not over the responder's
    step.

    Hypothesis structure:

      * `h_committed` — the anchor: the true spelling's
        signature-bound leaf opens at `gs.range.low.idx` against
        `gs.actionsRoot` (this is what the sequencer's own batch
        submission published).
      * `h_truthful` — truthful execution of the committed spelling:
        ANY signed action carrying that spelling, executed from the
        committed pre-state at the committed index, folds (when it
        folds at all) to `truth gs.range.high.idx`.  Quantified over
        the bundle because the responder chooses its openings; the
        verifier's value-derivation discipline
        (`VerifierWrites.*_correct`, pinned per-variant) is what
        discharges it for a deployment.
      * `h_cf` — collision-freeness over the pre-images the two
        openings hash (the standard scoped hypothesis).

    The derivation: the `.ok` outcome forces authentication
    (`terminate_ok_requires_authentication`); the two verifying
    openings at one `(root, index)` force the responder's spelling to
    the committed one (`actionProof_binds_action`); `h_truthful` then
    pins every fold the responder can produce to the truth, which
    disagrees with the fabricated endpoint — so every settlement path
    is a challenger win. -/
theorem anchored_challenger_wins
    (truth : LogIndex → StateCommit)
    (gs gs' : GameState) (step : KernelStep)
    (actionProof trueProof : SmtCellProof)
    (trueKind : UInt8) (trueSigner : Nat) (trueFields trueSig : ByteArray)
    (h_turn : gs.turn = .sequencer)
    (h_disagree : settlementDisagreement truth gs)
    (h_signer_bound : trueSigner < 2 ^ 64)
    (h_true_sig : trueSig.size = 65)
    (h_committed : verifyActionProof gs.actionsRoot gs.range.low.idx
      (LegalKernel.Runtime.hashBytes
        (actionLeafPreimage trueKind trueSigner trueFields trueSig))
      trueProof = true)
    (h_cf : Bridge.CollisionFreeOn
      (smtCellProofPreimages (actionKey gs.range.low.idx)
        (LegalKernel.Runtime.hashBytes
          (actionLeafPreimage
            (StepVMCoherence.actionKindByte step.signedAction.action)
            step.signedAction.signer.toNat
            (StepVMCoherence.actionFieldsForL1 step.signedAction.action)
            step.signedAction.sig))
        (LegalKernel.Runtime.hashBytes
          (actionLeafPreimage trueKind trueSigner trueFields trueSig))
        actionProof trueProof
       ++ [actionLeafPreimage
             (StepVMCoherence.actionKindByte step.signedAction.action)
             step.signedAction.signer.toNat
             (StepVMCoherence.actionFieldsForL1 step.signedAction.action)
             step.signedAction.sig,
           actionLeafPreimage trueKind trueSigner trueFields trueSig])
      LegalKernel.Runtime.hashBytes)
    (h_truthful : ∀ st : SignedAction, ∀ b : MultiBundle,
        StepVMCoherence.actionKindByte st.action = trueKind →
        st.signer.toNat = trueSigner →
        StepVMCoherence.actionFieldsForL1 st.action = trueFields →
        st.sig = trueSig →
        ∀ c, verifierPostRootMulti gs.range.low.commit st.action st.signer
              gs.range.high.idx b = some c →
          c = truth gs.range.high.idx)
    (h_apply : applyTransition gs (.terminateOnSingleStep step actionProof)
      = .ok gs') :
    gs'.status = .challengerWon := by
  -- The `.ok` outcome forces the authentication gate.
  obtain ⟨h_sig, h_auth⟩ := terminate_ok_requires_authentication h_apply
  -- The two verifying openings force the responder's spelling to the
  -- committed one.
  obtain ⟨h_k, h_s, h_f, h_g⟩ :=
    actionProof_binds_action gs.actionsRoot gs.range.low.idx
      (h_s₁ := UInt64.toNat_lt step.signedAction.signer)
      (h_s₂ := h_signer_bound)
      (h_sig₁ := h_sig) (h_sig₂ := h_true_sig)
      actionProof trueProof h_cf
      (by
        have h_leaf : actionLeafValue step.signedAction =
            LegalKernel.Runtime.hashBytes
              (actionLeafPreimage
                (StepVMCoherence.actionKindByte step.signedAction.action)
                step.signedAction.signer.toNat
                (StepVMCoherence.actionFieldsForL1 step.signedAction.action)
                step.signedAction.sig) := rfl
        rw [← h_leaf]; exact h_auth)
      h_committed
  -- Walk the arm: the remaining branches are the Lean-model-only
  -- refusal (a challenger win at the sequencer's turn) and the fold,
  -- which `h_truthful` pins to the truth.
  simp only [applyTransition] at h_apply
  split at h_apply
  · exact absurd h_apply (by simp)      -- gameAlreadyEnded
  · split at h_apply
    · exact absurd h_apply (by simp)    -- rangeNotSingleStep
    · split at h_apply
      · exact absurd h_apply (by simp)  -- terminationDuringBisection
      · split at h_apply
        · exact absurd h_apply (by simp)  -- actionNotInBatch
        · split at h_apply
          · -- The pre-state / log-index refusal: responder
            -- (sequencer) loses.
            injection h_apply with h_gs
            rw [← h_gs]
            simp [h_turn]
          · -- The fold ran.  Its result, if any, is the truth.
            rename_i h_pre_idx
            rw [not_or] at h_pre_idx
            obtain ⟨h_pre, h_idx⟩ := h_pre_idx
            have h_pre' : step.preStateCommit = gs.range.low.commit :=
              Decidable.of_not_not h_pre
            have h_idx' : step.l2LogIndex = gs.range.high.idx :=
              Decidable.of_not_not h_idx
            cases h_fold : kernelStepApply step with
            | none =>
              rw [h_fold] at h_apply
              injection h_apply with h_gs
              rw [← h_gs]
              simp [h_turn]
            | some c =>
              have h_c : c = truth gs.range.high.idx := by
                refine h_truthful step.signedAction step.bundle h_k h_s h_f
                  h_g c ?_
                have h_run := h_fold
                unfold kernelStepApply at h_run
                rw [h_pre', h_idx'] at h_run
                exact h_run
              rw [h_fold] at h_apply
              have h_ne : c ≠ gs.range.high.commit := by
                rw [h_c]
                exact Ne.symm h_disagree
              simp only [h_ne, if_false] at h_apply
              injection h_apply with h_gs
              rw [← h_gs]
              simp [h_turn]

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
