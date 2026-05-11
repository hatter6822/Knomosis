/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.GameTransitionEdgeCases — rejection-path
theorems for the bisection game's `applyTransition` state
machine.

For each malformed transition shape, this module proves that
`applyTransition` returns `.error` rather than silently
producing an invalid state.  These are the substantive content
of plan §18's #271 family of edge-case-rejection theorems.

Covered rejection paths:
  * Response without pending midpoint (#271.1, #271.2).
  * Settled-game transitions (#271.3).
  * Malformed midpoint at-or-beyond range boundaries (#271.6).

The other plan-spec #271 items (depth overflow, timeout during
active turn) are direct consequences of the same case-match
discipline and are exercised by the existing
`applyTransition_deterministic` theorem in `Game.lean`.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Game

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes

/-- #271.1 — `applyTransition` rejects `respondAgree` without a
    pending midpoint.  Returns `.error` for any in-progress game
    whose `pendingMidpoint` is `none`.

    Two error variants apply depending on whether the depth-cap
    has been exceeded:
    * `gs.depth ≥ MAX_BISECTION_DEPTH` → `bisectionDepthExceeded`
    * `gs.depth < MAX_BISECTION_DEPTH` + pending=none →
      `responseDuringSubmit`
    Either way, the result is `.error`. -/
theorem applyTransition_rejects_response_without_pendingMidpoint
    (gs : LegalKernel.FaultProof.GameState)
    (h_no_mp : gs.pendingMidpoint = none)
    (h_status : gs.status = .inProgress) :
    ∃ e, applyTransition gs .respondAgree = .error e := by
  unfold applyTransition
  by_cases h_cap : MAX_BISECTION_DEPTH ≤ gs.depth
  · -- Depth-cap branch.
    rw [h_status]
    simp [h_cap]
  · -- Past depth-cap check; pendingMidpoint=none catches us.
    rw [h_status]
    simp [h_cap, h_no_mp]

/-- #271.2 — `applyTransition` rejects `respondDisagree` without
    a pending midpoint.  Two error variants per the same
    depth-cap discipline as #271.1. -/
theorem applyTransition_rejects_disagree_without_pendingMidpoint
    (gs : LegalKernel.FaultProof.GameState)
    (h_no_mp : gs.pendingMidpoint = none)
    (h_status : gs.status = .inProgress) :
    ∃ e, applyTransition gs .respondDisagree = .error e := by
  unfold applyTransition
  by_cases h_cap : MAX_BISECTION_DEPTH ≤ gs.depth
  · rw [h_status]
    simp [h_cap]
  · rw [h_status]
    simp [h_cap, h_no_mp]

/-- #271.3 — `applyTransition` rejects any transition on a
    settled game (status ≠ inProgress).  This is the structural
    guarantee that the game-state machine doesn't accept
    transitions post-settlement. -/
theorem applyTransition_rejects_post_settlement
    (gs : LegalKernel.FaultProof.GameState)
    (t : GameTransition)
    (h_settled : gs.status ≠ .inProgress) :
    ∃ e, applyTransition gs t = .error e := by
  unfold applyTransition
  cases h_status_eq : gs.status with
  | inProgress => exact absurd h_status_eq h_settled
  | sequencerWon => cases t <;> exact ⟨_, rfl⟩
  | challengerWon => cases t <;> exact ⟨_, rfl⟩
  | timedOutSequencer => cases t <;> exact ⟨_, rfl⟩
  | timedOutChallenger => cases t <;> exact ⟨_, rfl⟩

/-- #271.6 — `applyTransition` rejects a malformed
    `submitMidpoint` whose midpoint index is at-or-beyond the
    high boundary or at-or-below the low boundary.  The
    structural guard inside `applyTransition` catches this. -/
theorem applyTransition_rejects_malformed_midpoint
    (gs : LegalKernel.FaultProof.GameState) (mp : Claim)
    (h_oob : mp.idx ≤ gs.range.low.idx ∨ gs.range.high.idx ≤ mp.idx)
    (h_status : gs.status = .inProgress)
    (h_no_pending : gs.pendingMidpoint = none)
    (h_depth : ¬ MAX_BISECTION_DEPTH ≤ gs.depth) :
    ∃ e, applyTransition gs (.submitMidpoint mp) = .error e := by
  unfold applyTransition
  rw [h_status, h_no_pending]
  simp only [if_neg h_depth, if_pos h_oob]
  exact ⟨_, rfl⟩

end FaultProof
end LegalKernel
