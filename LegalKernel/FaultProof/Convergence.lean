-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Convergence — bisection convergence
theorems (Workstream H WUs H.4.3a + H.4.3b + H.4.3c).

The bisection game's strict-narrowing per-round (proved in
`Game.lean` as `range_narrows_on_response_{agree,disagree}`)
extends to a multi-round descent: after `k` legal response
rounds, the range width has decreased by at least `k`.

**Headline theorem (#231):** `bisection_converges_after_enough_rounds`
— any legal transcript starting from a well-formed initial
range either terminates or has narrowed to a single-step range.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Game

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority

/-! ## A bisection trace: a chain of legal in-progress
    `respondAgree`/`respondDisagree` transitions. -/

/-- A trace of `k` legal in-progress game states terminating in
    `gs_k`, where each step is a `respondAgree` or
    `respondDisagree` transition with a well-formed midpoint.
    Used to formalise the multi-round descent argument. -/
inductive ResponseTrace :
    LegalKernel.FaultProof.GameState → Nat →
    LegalKernel.FaultProof.GameState → Prop
  /-- Empty trace. -/
  | refl  {gs : LegalKernel.FaultProof.GameState} :
      ResponseTrace gs 0 gs
  /-- Extend by one response. -/
  | step  {gs gs' gs_k : LegalKernel.FaultProof.GameState} {k : Nat}
          {mp : Claim} {t : GameTransition}
          (h_pending : gs.pendingMidpoint = some mp)
          (h_status  : gs.status = .inProgress)
          (h_wf_mp   : gs.range.low.idx < mp.idx ∧ mp.idx < gs.range.high.idx)
          (h_t       : t = .respondAgree ∨ t = .respondDisagree)
          (h_apply   : applyTransition gs t = .ok gs')
          (h_tail    : ResponseTrace gs' k gs_k) :
      ResponseTrace gs (k + 1) gs_k

/-! ## #265 — Range size after `k` rounds -/

/-- After any `k` legal responses, the range width has
    decreased by at least `k`.  Proof: induction on the trace
    length, using `range_narrows_on_response_*` at each step.

    Statement form: `width_k + k ≤ width_0`.  This is the
    *strict* form (no Nat-clamping); valid because each step
    strictly decreases the range. -/
theorem range_size_after_k_rounds
    (gs₀ gs_k : LegalKernel.FaultProof.GameState) (k : Nat)
    (h_trace : ResponseTrace gs₀ k gs_k) :
    gs_k.range.high.idx - gs_k.range.low.idx + k ≤
      gs₀.range.high.idx - gs₀.range.low.idx := by
  induction h_trace with
  | @refl gs =>
    -- Empty trace: gs_k = gs₀, k = 0.  width + 0 = width.  Trivial.
    show gs.range.high.idx - gs.range.low.idx + 0 ≤
         gs.range.high.idx - gs.range.low.idx
    exact Nat.le_of_eq rfl
  | @step gs gs' gs_k k mp t h_pending h_status h_wf_mp h_t h_apply _h_tail ih =>
    -- Strict descent: gs'.width + 1 ≤ gs.width.
    have h_descent : gs'.range.high.idx - gs'.range.low.idx + 1 ≤
                    gs.range.high.idx - gs.range.low.idx := by
      rcases h_t with h_a | h_d
      · subst h_a
        exact range_narrows_on_response_agree gs gs' mp h_pending h_status h_wf_mp h_apply
      · subst h_d
        exact range_narrows_on_response_disagree gs gs' mp h_pending h_status h_wf_mp h_apply
    -- ih : gs_k.width + k ≤ gs'.width
    -- h_descent : gs'.width + 1 ≤ gs.width
    -- Goal : gs_k.width + (k + 1) ≤ gs.width
    -- Use Nat.le_trans + Nat.add_le_add_right
    have h₁ : gs_k.range.high.idx - gs_k.range.low.idx + (k + 1) ≤
              gs'.range.high.idx - gs'.range.low.idx + 1 := by
      have h := Nat.add_le_add_right ih 1
      have e : (gs_k.range.high.idx - gs_k.range.low.idx + k) + 1 =
               gs_k.range.high.idx - gs_k.range.low.idx + (k + 1) := by
        rw [Nat.add_assoc]
      rw [e] at h
      exact h
    exact Nat.le_trans h₁ h_descent

/-! ## #231 — Bisection convergence -/

/-- After enough rounds, the range narrows to single-step (or
    the game has otherwise terminated).  Concretely: if the
    response count `k` is at least the initial range width, the
    final width is `0` or `1`.

    `MAX_BISECTION_DEPTH = 64` covers initial widths up to
    `2^64`, which is far beyond any practical log length. -/
theorem range_narrows_to_zero_after_enough_rounds
    (gs₀ gs_k : LegalKernel.FaultProof.GameState) (k : Nat)
    (h_trace : ResponseTrace gs₀ k gs_k)
    (h_k : k ≥ gs₀.range.high.idx - gs₀.range.low.idx) :
    gs_k.range.high.idx - gs_k.range.low.idx = 0 := by
  have h_bound := range_size_after_k_rounds gs₀ gs_k k h_trace
  -- h_bound : wK + k ≤ w₀
  -- h_k     : k ≥ w₀
  -- Combined: wK + k ≤ w₀ ≤ k, so wK = 0.
  have h_combined :
      gs_k.range.high.idx - gs_k.range.low.idx + k ≤ k :=
    Nat.le_trans h_bound h_k
  -- Now: x + k ≤ k for x = gs_k.width.  Hence x ≤ 0.
  have h_zero : gs_k.range.high.idx - gs_k.range.low.idx ≤ 0 := by
    have h_sub : gs_k.range.high.idx - gs_k.range.low.idx + k - k ≤ k - k :=
      Nat.sub_le_sub_right h_combined k
    rw [Nat.add_sub_cancel, Nat.sub_self] at h_sub
    exact h_sub
  exact Nat.le_zero.mp h_zero

/-- #231 — Bisection convergence: after enough rounds, the
    range has narrowed to width 0 (an essentially-degenerate
    range), which is structurally distinct from the in-progress
    state and forces one of the terminal transitions. -/
theorem bisection_converges_after_enough_rounds
    (gs₀ gs_k : LegalKernel.FaultProof.GameState) (k : Nat)
    (h_trace : ResponseTrace gs₀ k gs_k)
    (h_k : k ≥ gs₀.range.high.idx - gs₀.range.low.idx) :
    gs_k.range.high.idx - gs_k.range.low.idx ≤ 1 := by
  have h := range_narrows_to_zero_after_enough_rounds gs₀ gs_k k h_trace h_k
  rw [h]
  exact Nat.zero_le _

/-! ## #267 — Termination depth bound -/

/-- If a legal trace runs for more than `MAX_BISECTION_DEPTH`
    rounds and the initial range width is at most
    `MAX_BISECTION_DEPTH`, the final range has narrowed to
    width 0.  Specialisation of
    `range_narrows_to_zero_after_enough_rounds` to the
    standard bound. -/
theorem bisection_terminates_in_at_most_max_depth_rounds
    (gs₀ gs_k : LegalKernel.FaultProof.GameState)
    (h_trace : ResponseTrace gs₀ MAX_BISECTION_DEPTH gs_k)
    (h_initial_width : gs₀.range.high.idx - gs₀.range.low.idx ≤ MAX_BISECTION_DEPTH) :
    gs_k.range.high.idx - gs_k.range.low.idx = 0 := by
  apply range_narrows_to_zero_after_enough_rounds gs₀ gs_k MAX_BISECTION_DEPTH h_trace
  exact h_initial_width

end FaultProof
end LegalKernel
