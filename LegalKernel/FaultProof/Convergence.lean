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
  /-- Extend by one response.

      `h_canonical` records that the pending midpoint is the one
      `applyTransition` derives.  It is not an extra assumption on
      the game: `submitMidpoint_installs_canonical` shows no other
      pending midpoint is reachable, so a trace admitting one would
      be modelling states the contract cannot produce.  Carrying it
      is what makes the halving lemmas — and hence the logarithmic
      convergence bound — available at every node. -/
  | step  {gs gs' gs_k : LegalKernel.FaultProof.GameState} {k : Nat}
          {mp : Claim} {t : GameTransition}
          (h_pending   : gs.pendingMidpoint = some mp)
          (h_status    : gs.status = .inProgress)
          (h_canonical : mp.idx = gs.range.midpointIdx)
          (h_wf_mp     : gs.range.low.idx < mp.idx ∧ mp.idx < gs.range.high.idx)
          (h_t         : t = .respondAgree ∨ t = .respondDisagree)
          (h_apply     : applyTransition gs t = .ok gs')
          (h_tail      : ResponseTrace gs' k gs_k) :
      ResponseTrace gs (k + 1) gs_k

/-! ## Honest response traces

`ResponseTrace` says only that each step is a legal response.  A
theorem about an HONEST challenger needs, at each node, that the
response taken there matches the truth about that node's midpoint —
and that obligation must attach to the node's OWN response, not to a
free transition.

Quantifying it over an arbitrary `t` (as
`disagreement_persists_along_trace` originally did) is
self-contradictory: from any in-progress state with a pending
midpoint, BOTH `respondAgree` and `respondDisagree` apply, so a
hypothesis demanding `mp.commit = truth mp.idx` under the first and
`mp.commit ≠ truth mp.idx` under the second is unsatisfiable at that
state.  A theorem carrying it is vacuously true.

`HonestResponseTrace` carries the obligation per constructor, where
`t` is the response actually taken. -/

/-- A `ResponseTrace` in which every response is honest with respect
    to `truth`: at each node, agreeing means the midpoint really does
    match the truth, and disagreeing means it really does not.

    Mirrors `ResponseTrace` constructor-for-constructor, so an
    honest trace erases to a response trace
    (`HonestResponseTrace.toResponseTrace`) and every existing
    `ResponseTrace` theorem applies to it unchanged. -/
inductive HonestResponseTrace (truth : LegalKernel.Disputes.LogIndex → StateCommit) :
    LegalKernel.FaultProof.GameState → Nat →
    LegalKernel.FaultProof.GameState → Prop
  /-- Empty trace. -/
  | refl  {gs : LegalKernel.FaultProof.GameState} :
      HonestResponseTrace truth gs 0 gs
  /-- Extend by one HONEST response.  `h_honest` constrains the
      response `t` taken at THIS node, so it is satisfiable — unlike a
      hypothesis ranging over every transition applicable here. -/
  | step  {gs gs' gs_k : LegalKernel.FaultProof.GameState} {k : Nat}
          {mp : Claim} {t : GameTransition}
          (h_pending   : gs.pendingMidpoint = some mp)
          (h_status    : gs.status = .inProgress)
          (h_canonical : mp.idx = gs.range.midpointIdx)
          (h_wf_mp     : gs.range.low.idx < mp.idx ∧ mp.idx < gs.range.high.idx)
          (h_t         : t = .respondAgree ∨ t = .respondDisagree)
          (h_apply     : applyTransition gs t = .ok gs')
          (h_honest    :
            (t = .respondAgree    → mp.commit = truth mp.idx) ∧
            (t = .respondDisagree → mp.commit ≠ truth mp.idx))
          (h_tail      : HonestResponseTrace truth gs' k gs_k) :
      HonestResponseTrace truth gs (k + 1) gs_k

/-- An honest trace is in particular a response trace, so every
    `ResponseTrace` result (range narrowing, convergence) applies to
    it without restatement. -/
theorem HonestResponseTrace.toResponseTrace
    {truth : LegalKernel.Disputes.LogIndex → StateCommit}
    {gs₀ gs_k : LegalKernel.FaultProof.GameState} {k : Nat}
    (h : HonestResponseTrace truth gs₀ k gs_k) :
    ResponseTrace gs₀ k gs_k := by
  induction h with
  | refl => exact ResponseTrace.refl
  | @step gs gs' gs_k k mp t h_pending h_status h_canonical h_wf_mp h_t h_apply
          _h_honest _h_tail ih =>
    exact ResponseTrace.step h_pending h_status h_canonical h_wf_mp h_t h_apply ih

/-- The honest-trace relation is inhabited: the empty trace is one
    for every truth function and every state.  Exhibiting a witness
    is what distinguishes a conditional theorem from a vacuous one —
    the predicate this replaces had none. -/
theorem honestResponseTrace_refl_exists
    (truth : LegalKernel.Disputes.LogIndex → StateCommit)
    (gs : LegalKernel.FaultProof.GameState) :
    HonestResponseTrace truth gs 0 gs :=
  HonestResponseTrace.refl

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
  | @step gs gs' gs_k k mp t h_pending h_status _h_canonical h_wf_mp h_t h_apply
          _h_tail ih =>
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

/-! ## Logarithmic convergence (the canonical-midpoint bound)

The results above hold for any interior midpoint and are
therefore only *linear*: `k` rounds remove at least `k` from the
width.  With the midpoint canonical — which
`submitMidpoint_installs_canonical` shows is the only reachable
shape — each round instead **halves** the width, so `k` rounds
divide it by `2^k`.  This is what the `MAX_BISECTION_DEPTH = 64`
docstring has always claimed ("covers log lengths up to `2^64`"),
and it is now proved rather than asserted. -/

/-- One ceiling-halving: the width a single canonical bisection
    round can leave behind. -/
def halveCeil (w : Nat) : Nat := (w + 1) / 2

/-- `k` ceiling-halvings of `w`.  Spelled as an explicit
    recursion rather than `halveCeil^[k]`: `Function.iterate` and
    its `iterate_succ_apply` lemmas are Mathlib, and the kernel
    imports Lean core only. -/
def halveCeilIter : Nat → Nat → Nat
  | 0,     w => w
  | n + 1, w => halveCeilIter n (halveCeil w)

/-- `halveCeilIter` is monotone in the width: a narrower range
    stays narrower under any number of rounds. -/
theorem halveCeilIter_mono (n : Nat) : ∀ (a b : Nat), a ≤ b →
    halveCeilIter n a ≤ halveCeilIter n b := by
  induction n with
  | zero => intro a b h; exact h
  | succ m ih =>
    intro a b h
    show halveCeilIter m (halveCeil a) ≤ halveCeilIter m (halveCeil b)
    exact ih _ _ (by unfold halveCeil; omega)

/-- If the width is at most `2^k`, then `k` halvings bring it to
    at most 1 — the single-step range that forces termination. -/
theorem halveCeilIter_le_one (k w : Nat) (h : w ≤ 2 ^ k) :
    halveCeilIter k w ≤ 1 := by
  induction k generalizing w with
  | zero =>
    -- `2 ^ 0 = 1`, so `w ≤ 1` already.
    simpa [halveCeilIter] using h
  | succ n ih =>
    -- One halving takes `w ≤ 2^(n+1)` to `(w+1)/2 ≤ 2^n`.
    show halveCeilIter n (halveCeil w) ≤ 1
    refine ih (halveCeil w) ?_
    unfold halveCeil
    have h_pow : 2 ^ (n + 1) = 2 * 2 ^ n := by
      rw [Nat.pow_succ]; omega
    rw [h_pow] at h
    omega

/-- After `k` canonical response rounds the width is at most
    `halveCeilIter k` of the initial width. -/
theorem range_size_after_k_canonical_rounds
    (gs₀ gs_k : LegalKernel.FaultProof.GameState) (k : Nat)
    (h_trace : ResponseTrace gs₀ k gs_k) :
    gs_k.range.high.idx - gs_k.range.low.idx ≤
      halveCeilIter k (gs₀.range.high.idx - gs₀.range.low.idx) := by
  induction h_trace with
  | @refl gs => exact Nat.le_of_eq rfl
  | @step gs gs' gs_k k mp t h_pending h_status h_canonical _h_wf_mp h_t h_apply
          _h_tail ih =>
    -- One canonical round halves; then the induction hypothesis,
    -- moved across by monotonicity of the remaining rounds.
    have h_half : gs'.range.high.idx - gs'.range.low.idx ≤
        halveCeil (gs.range.high.idx - gs.range.low.idx) := by
      unfold halveCeil
      rcases h_t with h_a | h_d
      · subst h_a
        exact range_halves_on_response_agree gs gs' mp h_pending h_canonical
                h_status h_apply
      · subst h_d
        exact range_halves_on_response_disagree gs gs' mp h_pending h_canonical
                h_status h_apply
    show gs_k.range.high.idx - gs_k.range.low.idx ≤
      halveCeilIter k (halveCeil (gs.range.high.idx - gs.range.low.idx))
    exact Nat.le_trans ih (halveCeilIter_mono k _ _ h_half)

/-- **Logarithmic convergence.**  `k` canonical response rounds
    narrow an initial range of width at most `2^k` to a single
    step.

    Contrast `bisection_converges_after_enough_rounds`, which needs
    `k ≥ w₀`: this needs only `2^k ≥ w₀`.  At the shipped
    `MAX_BISECTION_DEPTH = 64` that is the difference between
    covering widths up to 64 and covering widths up to `2^64` —
    the bound the constant's docstring has always claimed. -/
theorem bisection_converges_in_log_rounds
    (gs₀ gs_k : LegalKernel.FaultProof.GameState) (k : Nat)
    (h_trace : ResponseTrace gs₀ k gs_k)
    (h_k : gs₀.range.high.idx - gs₀.range.low.idx ≤ 2 ^ k) :
    gs_k.range.high.idx - gs_k.range.low.idx ≤ 1 :=
  Nat.le_trans
    (range_size_after_k_canonical_rounds gs₀ gs_k k h_trace)
    (halveCeilIter_le_one k _ h_k)

/-- The shipped depth cap covers every log length the `LogIndex`
    type can express.  `MAX_BISECTION_DEPTH = 64` rounds suffice
    for any initial width up to `2^64`, which is what makes the
    cap a non-restriction in practice rather than a limit that a
    long enough log could exceed. -/
theorem bisection_converges_at_max_depth
    (gs₀ gs_k : LegalKernel.FaultProof.GameState)
    (h_trace : ResponseTrace gs₀ MAX_BISECTION_DEPTH gs_k)
    (h_width : gs₀.range.high.idx - gs₀.range.low.idx ≤ 2 ^ 64) :
    gs_k.range.high.idx - gs_k.range.low.idx ≤ 1 :=
  bisection_converges_in_log_rounds gs₀ gs_k MAX_BISECTION_DEPTH h_trace h_width

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
