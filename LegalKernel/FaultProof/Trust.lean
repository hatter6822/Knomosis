-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Trust — composite trust-model upgrade
theorems for Workstream H.

This module consolidates the load-bearing trust-model theorems
(#232 composite, #233 inequality form, #257 single-honest-
challenger composite, #266 terminal-disagreement-implies-
sequencer-loss).

The disagreement-persistence machinery (per-round) lives in
`Honesty.lean`; this module composes it with `Convergence.lean`
(#231) and `Strategy.lean` (#268) to deliver the operational
form of the trust-model upgrade.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Honesty

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime

/-! ## #257 — Single-honest-challenger composite

The composite property: given an honest challenger playing
the canonical strategy from `honestStrategy`, after enough
rounds (per #231), the disputed range is at most single-step,
AND the disagreement-with-truth invariant still holds. -/

/-- #257 — Single-honest-challenger composite.  An honest
    challenger maintaining the disagreement-with-truth invariant
    along the trace, given enough rounds, narrows the range to
    width 1 while preserving the invariant.

    The conclusion is the conjunction of:
      * `disagreement_persists_along_trace` (the invariant
        survives every round).
      * `bisection_converges_after_enough_rounds` (the range
        narrows to ≤ 1).
    Together they characterise the position from which the
    sequencer loses at termination. -/
theorem single_honest_challenger_narrows_with_disagreement
    (truth : LogIndex → StateCommit)
    (gs₀ gs_k : LegalKernel.FaultProof.GameState) (k : Nat)
    (h_trace : ResponseTrace gs₀ k gs_k)
    (h_disagree₀ : inDisagreementWithTruth truth gs₀)
    (h_each_honest :
      ∀ {gs gs' : LegalKernel.FaultProof.GameState} {mp : Claim}
        {t : GameTransition},
        gs.pendingMidpoint = some mp →
        gs.status = .inProgress →
        applyTransition gs t = .ok gs' →
        (t = .respondAgree   → mp.commit  = truth mp.idx) ∧
        (t = .respondDisagree → mp.commit ≠ truth mp.idx))
    (h_k : k ≥ gs₀.range.high.idx - gs₀.range.low.idx) :
    inDisagreementWithTruth truth gs_k ∧
    gs_k.range.high.idx - gs_k.range.low.idx ≤ 1 := by
  refine ⟨?_, ?_⟩
  · exact disagreement_persists_along_trace truth gs₀ gs_k k
            h_trace h_disagree₀ h_each_honest
  · exact bisection_converges_after_enough_rounds gs₀ gs_k k h_trace h_k

/-! ## #266 — Terminal disagreement implies sequencer loss

The crux: at the terminal (single-step) range, an honest
challenger's disagreement-with-truth invariant means the
sequencer's claimed `range.high.commit` differs from truth.
The L1 step VM (per #225 coherence) recomputes the truth at
single-step termination, so the contract rules against the
sequencer.

The Lean-side content here is the inequality of the claimed
post-commit and the truth. -/

/-- #266 — Terminal disagreement implies the sequencer's claim
    at the terminal range's high index differs from truth.  This
    is a **direct projection** of the second conjunct of the
    `inDisagreementWithTruth` invariant: by definition, that
    invariant carries `high.commit ≠ truth high.idx`.  The
    composition with the L1 step VM's coherence theorem (#225,
    in `Coherence.lean`) is what establishes the L1 contract's
    rule-against-sequencer outcome at termination; this theorem
    only ships the type-level inequality. -/
theorem terminal_disagreement_implies_sequencer_claim_wrong
    (truth : LogIndex → StateCommit)
    (gs : LegalKernel.FaultProof.GameState)
    (h_disagree : inDisagreementWithTruth truth gs) :
    gs.range.high.commit ≠ truth gs.range.high.idx :=
  h_disagree.2

/-- #266 strengthened — the corollary in the contrapositive
    form: if the sequencer's high-commit equals the truth at
    `range.high.idx`, then the disagreement invariant has
    already broken (which an honest player never lets happen). -/
theorem sequencer_high_truthful_breaks_disagreement
    (truth : LogIndex → StateCommit)
    (gs : LegalKernel.FaultProof.GameState)
    (h_high_truthful : gs.range.high.commit = truth gs.range.high.idx) :
    ¬ inDisagreementWithTruth truth gs := by
  intro ⟨_, h_neq⟩
  exact h_neq h_high_truthful

/-! ## #232 — Trust-model upgrade composite (operational form)

Given:
  * The sequencer published a wrong state root at
    `revertFromIdx` (formalised as: `claim ≠ truth revertFromIdx`).
  * An honest challenger initiates and plays the bisection game.
  * Bisection runs for at least `initial_width` rounds.

Then: at the end of the trace, the challenger's terminal
position satisfies the disagreement invariant, which the L1
step VM converts into a settlement against the sequencer.

The Lean-side packaging:

  inDisagreementWithTruth_at_termination
    : after enough rounds with honest play, the terminal range
      has width ≤ 1 AND the disagreement invariant holds. -/

/-- #232 composite (operational form) — Given the
    disagreement-with-truth invariant at trace start and an
    honest-strategy challenger playing the trace, after enough
    rounds the terminal game state is positioned for the L1
    step VM to settle against the sequencer.

    The "settled-against-sequencer" conclusion is the
    composition of `terminal_disagreement_implies_sequencer_claim_wrong`
    (the type-level wrongness of the sequencer's claim at the
    terminal range) with the L1 step VM's coherence (#225,
    `recomputeCommitment_coherent_with_kernelOnlyApply`).  The
    latter is established in `Coherence.lean`; this theorem
    composes the L2-side content. -/
theorem trust_model_upgrade_composite
    (truth : LogIndex → StateCommit)
    (gs₀ gs_k : LegalKernel.FaultProof.GameState) (k : Nat)
    (h_trace : ResponseTrace gs₀ k gs_k)
    (h_disagree₀ : inDisagreementWithTruth truth gs₀)
    (h_each_honest :
      ∀ {gs gs' : LegalKernel.FaultProof.GameState} {mp : Claim}
        {t : GameTransition},
        gs.pendingMidpoint = some mp →
        gs.status = .inProgress →
        applyTransition gs t = .ok gs' →
        (t = .respondAgree   → mp.commit  = truth mp.idx) ∧
        (t = .respondDisagree → mp.commit ≠ truth mp.idx))
    (h_k : k ≥ gs₀.range.high.idx - gs₀.range.low.idx) :
    -- The trifecta: disagreement persists, range narrows, and
    -- the sequencer's high-commit at termination is wrong.
    inDisagreementWithTruth truth gs_k ∧
    gs_k.range.high.idx - gs_k.range.low.idx ≤ 1 ∧
    gs_k.range.high.commit ≠ truth gs_k.range.high.idx := by
  obtain ⟨h_inv, h_narrow⟩ :=
    single_honest_challenger_narrows_with_disagreement truth
      gs₀ gs_k k h_trace h_disagree₀ h_each_honest h_k
  refine ⟨h_inv, h_narrow, ?_⟩
  exact terminal_disagreement_implies_sequencer_claim_wrong truth gs_k h_inv

/-! ## #233 — Inequality form (the standalone version)

`#233_state_root_invalidity_inequality` packages the wrongness
claim in a standalone form.  Used downstream by the `Witness`
module to construct the propositional witness without requiring
the caller to repeat the disagreement-trifecta proof. -/

/-- #233 — Inequality form: if the sequencer's submitted state
    root differs from the truth at `revertFromIdx`, then the
    canonical commit (`truth revertFromIdx`) is provably distinct
    from the sequencer's claim.  Trivially true; the value of
    this theorem is documenting the standalone inequality form
    that downstream witness construction depends on. -/
theorem state_root_invalidity_inequality
    (truth : LogIndex → StateCommit)
    (revertFromIdx : LogIndex) (sequencerClaim : StateCommit)
    (h_wrong : sequencerClaim ≠ truth revertFromIdx) :
    truth revertFromIdx ≠ sequencerClaim := by
  intro h_eq
  exact h_wrong h_eq.symm

/-- #233 corollary — the dispatch from the disagreement
    invariant at terminal range to the standalone inequality.
    Provides the bridge from the game-state-level trifecta to
    the witness-level state-root inequality. -/
theorem disagreement_to_state_root_invalidity
    (truth : LogIndex → StateCommit)
    (gs : LegalKernel.FaultProof.GameState)
    (h_disagree : inDisagreementWithTruth truth gs) :
    truth gs.range.high.idx ≠ gs.range.high.commit := by
  intro h_eq
  exact h_disagree.2 h_eq.symm

end FaultProof
end LegalKernel
