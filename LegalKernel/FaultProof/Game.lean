-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Game — bisection game data types + state
machine (Workstream H §12 / WUs H.4.1 + H.4.2 + H.4.3).

Formalises the interactive fault-proof game as a state machine
with explicit turn-based transitions.  The Lean side is the
*reference implementation*; the Solidity side
(`solidity/src/contracts/KnomosisFaultProofGame.sol`) ports it
line-for-line under cross-stack equivalence testing.

**Key design correction over v1.**  v1's `BisectionRound` carried
both `claimantMidpoint` and `challengerMidpoint` per round, which
suggested both parties submit midpoints simultaneously.  In the
standard interactive-proof game, **each round has exactly one
midpoint claim** from the responding party; the opposing party
either accepts (collapsing the range to the second half) or
rejects (collapsing to the first half).  v2 implements the
correct shape.

This module is **not** part of the trusted computing base.  Bugs
here would weaken the L1 fault-proof game's correctness but
cannot violate any kernel invariant.
-/

import LegalKernel.Disputes.Types
import LegalKernel.FaultProof.Step

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes

/-! ## DoS bounds (Workstream H §2) -/

/-- Maximum bisection depth (per §2 of the workstream plan):
    `MAX_BISECTION_DEPTH = 64`.  Caps the worst-case L1 game
    length at `2 × 64 + ε` transactions per dispute.  Covers log
    lengths up to `2^64`, essentially unbounded. -/
def MAX_BISECTION_DEPTH : Nat := 64

/-! ## Game data types (§12.4.1 / WU H.4.1) -/

/-- A state-root assertion: at log index `idx`, the state root
    is `commit`.  The bisection game's range and midpoint
    submissions all consume this type. -/
structure Claim where
  /-- The log index this claim covers. -/
  idx    : LogIndex
  /-- The claimed state-root commit at `idx`. -/
  commit : StateCommit
  deriving Repr

/-- The disputed range at any point in the game.  Both parties
    have agreed on the commits at `low` and `high` (the
    disagreement was already at the previous level); they
    disagree about the commit at the midpoint.

    `low.idx < high.idx`; equality means the bisection has
    narrowed to a single step. -/
structure DisputedRange where
  /-- The lower bound (both parties agree on this commit). -/
  low    : Claim
  /-- The upper bound (parties may disagree on this commit;
      the upper bound's claim is what the bisection is trying
      to falsify). -/
  high   : Claim
  deriving Repr

/-- Whose turn it is to act in the current round. -/
inductive TurnSide
  /-- The sequencer's turn. -/
  | sequencer
  /-- The challenger's turn. -/
  | challenger
  deriving Repr, DecidableEq

/-- The terminal status of a fault-proof game. -/
inductive GameStatus
  /-- The game is still in progress. -/
  | inProgress
  /-- The challenger lost; bonds redistribute to the sequencer. -/
  | sequencerWon
  /-- The sequencer lost; bonds redistribute to the challenger. -/
  | challengerWon
  /-- The unresponsive party (the loser) timed out. -/
  | timedOutSequencer
  /-- The challenger timed out. -/
  | timedOutChallenger
  deriving Repr, DecidableEq

/-! ## `GameState` (§12.4.1) -/

/-- The bisection game's state.  Bisection proceeds as a
    succession of midpoint submissions and accept/reject
    responses; each round halves the dispute range.  The L1
    contract stores this state per game in a Solidity mapping;
    the Lean side specifies the canonical shape. -/
structure GameState where
  /-- The sequencer's identity. -/
  sequencer       : ActorId
  /-- The challenger's identity. -/
  challenger      : ActorId
  /-- The current disputed range. -/
  range           : DisputedRange
  /-- The midpoint commit submitted in the current round (if
      any).  When `none`, the responding party owes a midpoint
      submission; when `some _`, the opposing party owes an
      accept/reject response. -/
  pendingMidpoint : Option Claim
  /-- The bisection depth so far.  Capped at
      `MAX_BISECTION_DEPTH = 64` by the legality predicate. -/
  depth           : Nat
  /-- Whose turn it is. -/
  turn            : TurnSide
  /-- The sequencer's bond (in deployment-supplied units; ETH
      wei on L1).  Slashed in full to the challenger if the
      sequencer loses. -/
  sequencerBond   : Nat
  /-- The challenger's bond.  Slashed in full to the sequencer
      if the challenger loses. -/
  challengerBond  : Nat
  /-- Game status. -/
  status          : GameStatus
  /-- The deployment-id binding the game to a specific Knomosis
      deployment.  Prevents cross-deployment replay of game
      transcripts. -/
  deploymentId    : ByteArray
  deriving Repr

/-! ## Game transitions (§12.4.2 / WU H.4.2) -/

/-- The legal transitions from one game state to the next.

    **v1 bug fix**: v1's `terminateOnSingleStep` constructor
    took both `submitterPostCommit` and `challengerPostCommit`
    — but only one of them is the claim being tested; the L1
    step VM determines which is correct from its own
    re-execution.  v2 takes a single claimed post-commit. -/
inductive GameTransition
  /-- The party whose turn it is submits a midpoint commit. -/
  | submitMidpoint (mp : Claim)
  /-- The opposing party agrees with the pending midpoint;
      range narrows to `[mid.idx, high.idx]`. -/
  | respondAgree
  /-- The opposing party disagrees; range narrows to
      `[low.idx, mid.idx]`. -/
  | respondDisagree
  /-- When range is single-step, terminate by executing.  The
      step VM determines who's right; the contract reads its
      output. -/
  | terminateOnSingleStep
      (kernelStep : KernelStep)
      (claimedPostCommit : StateCommit)
  /-- A party times out (BISECTION_RESPONSE_TIMEOUT exceeded).
      The loser is *derived* from `gs.turn` at apply-time: the
      party whose turn it is when the deadline elapses is the
      one who failed to respond.  Mirrors Solidity's
      `claimTimeout` semantics (anyone can call; the loser is
      always the current turn-holder).

      Taking the loser as a parameter would be a Lean-side
      semantic mismatch with the Solidity implementation: an
      adversarial transition could specify the wrong loser. -/
  | timeoutLoss
  deriving Repr

/-- Errors `applyTransition` can produce.  Each variant maps
    to a precise revert reason in the L1 game contract. -/
inductive GameError
  /-- The game has already ended. -/
  | gameAlreadyEnded
  /-- Wrong turn (the caller is not the responding party). -/
  | wrongTurn
  /-- The submitted midpoint is outside the disputed range. -/
  | midpointOutOfRange
  /-- A midpoint is already pending; cannot submit another
      until the opposing party responds. -/
  | midpointDuringResponse
  /-- No midpoint pending; cannot accept/reject. -/
  | responseDuringSubmit
  /-- The bisection depth cap has been exceeded. -/
  | bisectionDepthExceeded
  /-- The range is not single-step yet; bisect more first. -/
  | rangeNotSingleStep
  /-- Termination attempted during an active bisection. -/
  | terminationDuringBisection
  deriving Repr, DecidableEq

/-! ## State-machine semantics -/

/-- The canonical midpoint of a disputed range.  Floor-divides
    to the lower half on odd-length ranges. -/
def DisputedRange.midpointIdx (r : DisputedRange) : LogIndex :=
  (r.low.idx + r.high.idx) / 2

/-- True iff the range is single-step (`high.idx = low.idx + 1`).
    When this holds, no further bisection is possible; the
    responding party must call `terminateOnSingleStep`. -/
def DisputedRange.isSingleStep (r : DisputedRange) : Prop :=
  r.high.idx = r.low.idx + 1

/-- Decidability of `isSingleStep`.  Reduces to `Nat`-equality. -/
instance instDecidableIsSingleStep (r : DisputedRange) :
    Decidable r.isSingleStep := by
  unfold DisputedRange.isSingleStep
  exact inferInstance

/-- The next turn after the current one.  Used by
    `applyTransition` to flip between sequencer / challenger. -/
def TurnSide.flip : TurnSide → TurnSide
  | .sequencer  => .challenger
  | .challenger => .sequencer

/-- Apply a transition.  Returns the new game state if the
    transition is legal, an error otherwise.  Total function;
    decidable. -/
def applyTransition (gs : GameState) :
    GameTransition → Except GameError GameState
  -- Submit a midpoint.  Legal only when:
  --   * Game is in progress.
  --   * No midpoint already pending.
  --   * Bisection depth hasn't exceeded the cap.
  --   * The midpoint's idx is strictly between low.idx and high.idx
  --     (i.e. the range is at least 2 steps wide).
  | .submitMidpoint mp =>
    if gs.status ≠ .inProgress then .error .gameAlreadyEnded
    else if gs.pendingMidpoint.isSome then .error .midpointDuringResponse
    else if gs.depth ≥ MAX_BISECTION_DEPTH then
      .error .bisectionDepthExceeded
    else if mp.idx ≤ gs.range.low.idx ∨ gs.range.high.idx ≤ mp.idx then
      .error .midpointOutOfRange
    else
      .ok { gs with
              pendingMidpoint := some mp,
              turn := gs.turn.flip }

  -- Respond by agreeing.  Range narrows to [mid.idx, high.idx].
  -- The post-response depth (`gs.depth + 1`) must not exceed
  -- `MAX_BISECTION_DEPTH`.  Mirrors Solidity's
  -- `respondToMidpoint` post-increment cap check.
  | .respondAgree =>
    if gs.status ≠ .inProgress then .error .gameAlreadyEnded
    else if gs.depth ≥ MAX_BISECTION_DEPTH then
      .error .bisectionDepthExceeded
    else
      match gs.pendingMidpoint with
      | none    => .error .responseDuringSubmit
      | some mp =>
        .ok { gs with
                range := { low := mp, high := gs.range.high },
                pendingMidpoint := none,
                depth := gs.depth + 1,
                turn := gs.turn.flip }

  -- Respond by disagreeing.  Range narrows to [low.idx, mid.idx].
  -- Same depth-cap discipline as `respondAgree`.
  | .respondDisagree =>
    if gs.status ≠ .inProgress then .error .gameAlreadyEnded
    else if gs.depth ≥ MAX_BISECTION_DEPTH then
      .error .bisectionDepthExceeded
    else
      match gs.pendingMidpoint with
      | none    => .error .responseDuringSubmit
      | some mp =>
        .ok { gs with
                range := { low := gs.range.low, high := mp },
                pendingMidpoint := none,
                depth := gs.depth + 1,
                turn := gs.turn.flip }

  -- Single-step termination.  The L1 step VM verifies the
  -- claimed post-commit matches the kernelStepApply output.
  | .terminateOnSingleStep step claimedPostCommit =>
    if gs.status ≠ .inProgress then .error .gameAlreadyEnded
    else if !gs.range.isSingleStep then
      .error .rangeNotSingleStep
    else
      -- The step VM determines correctness.  If kernelStepApply
      -- agrees with the claimed post-commit, the responding party
      -- (whose turn it is) wins; otherwise, they lose.
      match kernelStepApply step with
      | none =>
        -- Cell-proof verification failed; the responding party loses.
        .ok { gs with
                status :=
                  match gs.turn with
                  | .sequencer  => .challengerWon
                  | .challenger => .sequencerWon }
      | some computedPostCommit =>
        if computedPostCommit = claimedPostCommit then
          -- The responding party's claim matches the VM's output;
          -- they win.
          .ok { gs with
                  status :=
                    match gs.turn with
                    | .sequencer  => .sequencerWon
                    | .challenger => .challengerWon }
        else
          -- Mismatch; responding party loses.
          .ok { gs with
                  status :=
                    match gs.turn with
                    | .sequencer  => .challengerWon
                    | .challenger => .sequencerWon }

  -- Timeout.  The unresponsive party loses — derived from
  -- `gs.turn` at apply-time (the current turn-holder is the one
  -- who failed to respond).  Mirrors Solidity's `claimTimeout`
  -- semantics.
  | .timeoutLoss =>
    if gs.status ≠ .inProgress then .error .gameAlreadyEnded
    else
      .ok { gs with
              status :=
                match gs.turn with
                | .sequencer  => .timedOutSequencer
                | .challenger => .timedOutChallenger }

/-! ## Decidability + determinism -/

/-- `applyTransition` is deterministic: equal inputs produce
    equal outputs.  Mechanical via `rfl`. -/
theorem applyTransition_deterministic
    (gs₁ gs₂ : GameState) (t₁ t₂ : GameTransition)
    (h_gs : gs₁ = gs₂) (h_t : t₁ = t₂) :
    applyTransition gs₁ t₁ = applyTransition gs₂ t₂ := by
  rw [h_gs, h_t]

/-! ## Game well-formedness (§12.4.6 / WU H.4.6) -/

/-- Helper: the pending-midpoint constraint as a decidable
    predicate.  `none` is vacuously well-formed; `some mp`
    requires the midpoint to lie strictly inside the range. -/
def pendingMidpointInRange (gs : GameState) : Prop :=
  match gs.pendingMidpoint with
  | none    => True
  | some mp => gs.range.low.idx < mp.idx ∧ mp.idx < gs.range.high.idx

/-- Decidability of `pendingMidpointInRange`.  Case-split on the
    `Option` constructor; each branch is decidable. -/
instance instDecidablePendingMidpointInRange (gs : GameState) :
    Decidable (pendingMidpointInRange gs) := by
  unfold pendingMidpointInRange
  cases gs.pendingMidpoint <;> exact inferInstance

/-- Well-formedness predicate for a game state.  A game is
    well-formed iff:
      * The disputed range has `low.idx < high.idx` (else the
        bisection is degenerate).
      * The depth has not exceeded the cap.
      * If a midpoint is pending, its idx is strictly within
        the range (`pendingMidpointInRange`).
      * If the game is in progress, the bond pool is positive
        (else there's nothing to redistribute on settlement).

    `→` is encoded as `¬ inProgress ∨ bondPool > 0` so the
    conjunction is decidable via `inferInstance` without
    requiring `Classical.propDecidable`. -/
def gameWellFormed (gs : GameState) : Prop :=
  gs.range.low.idx < gs.range.high.idx ∧
  gs.depth ≤ MAX_BISECTION_DEPTH ∧
  pendingMidpointInRange gs ∧
  (gs.status ≠ .inProgress ∨
    gs.sequencerBond + gs.challengerBond > 0)

/-- Decidability of `gameWellFormed`.  Each conjunct is
    decidable; the conjunction is decidable via
    `inferInstance`. -/
instance instDecidableGameWellFormed (gs : GameState) :
    Decidable (gameWellFormed gs) := by
  unfold gameWellFormed
  exact inferInstance

/-! ## Bisection convergence (§12.4.3 / WU H.4.3) -/

/-- The post-state of a successful `respondAgree` has the
    midpoint as its new low bound and the original high as its
    new high bound.  This is the structural shape lemma the
    range-narrowing lemma depends on.

    Successful applies imply `gs.depth < MAX_BISECTION_DEPTH`
    (the depth-cap gate); the proof derives this from the
    successful-apply hypothesis. -/
theorem applyTransition_respondAgree_shape
    (gs gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_status : gs.status = .inProgress)
    (h_apply : applyTransition gs .respondAgree = .ok gs') :
    gs'.range.low = mp ∧ gs'.range.high = gs.range.high := by
  unfold applyTransition at h_apply
  rw [h_pending] at h_apply
  simp [h_status] at h_apply
  -- The depth-cap gate produces an `if MAX_BISECTION_DEPTH ≤
  -- gs.depth then error else ok ...` expression; a successful
  -- apply (`= .ok gs'`) forces the false branch.  Split:
  by_cases h_cap : MAX_BISECTION_DEPTH ≤ gs.depth
  · simp [h_cap] at h_apply
  · simp [h_cap] at h_apply
    rw [← h_apply]
    exact ⟨rfl, rfl⟩

/-- The post-state of a successful `respondDisagree` has the
    original low as its new low bound and the midpoint as its
    new high bound. -/
theorem applyTransition_respondDisagree_shape
    (gs gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_status : gs.status = .inProgress)
    (h_apply : applyTransition gs .respondDisagree = .ok gs') :
    gs'.range.low = gs.range.low ∧ gs'.range.high = mp := by
  unfold applyTransition at h_apply
  rw [h_pending] at h_apply
  simp [h_status] at h_apply
  by_cases h_cap : MAX_BISECTION_DEPTH ≤ gs.depth
  · simp [h_cap] at h_apply
  · simp [h_cap] at h_apply
    rw [← h_apply]
    exact ⟨rfl, rfl⟩

/-- Helper: a strict-narrowing arithmetic lemma over abstract
    `Nat` operands.  Used by `range_narrows_on_response_agree`
    after substituting the post-state's range bounds. -/
private theorem nat_sub_lt_sub_left
    (lo mp hi : Nat) (h_lo_mp : lo < mp) (h_mp_hi : mp < hi) :
    hi - mp < hi - lo := by
  omega

/-- Helper: a symmetric strict-narrowing arithmetic lemma. -/
private theorem nat_sub_lt_sub_right
    (lo mp hi : Nat) (h_lo_mp : lo < mp) (h_mp_hi : mp < hi) :
    mp - lo < hi - lo := by
  omega

/-- Each successful `respondAgree` transition strictly narrows
    the dispute range under well-formedness on the midpoint
    (mp.idx strictly inside the old range). -/
theorem range_narrows_on_response_agree
    (gs gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_status : gs.status = .inProgress)
    (h_wf_mp : gs.range.low.idx < mp.idx ∧ mp.idx < gs.range.high.idx)
    (h_apply : applyTransition gs .respondAgree = .ok gs') :
    gs'.range.high.idx - gs'.range.low.idx <
      gs.range.high.idx - gs.range.low.idx := by
  obtain ⟨h_lo_lt_mp, h_mp_lt_hi⟩ := h_wf_mp
  obtain ⟨h_lo_eq, h_hi_eq⟩ :=
    applyTransition_respondAgree_shape gs gs' mp h_pending h_status h_apply
  have h_low_idx : gs'.range.low.idx = mp.idx := by rw [h_lo_eq]
  have h_high_idx : gs'.range.high.idx = gs.range.high.idx := by rw [h_hi_eq]
  rw [h_low_idx, h_high_idx]
  exact nat_sub_lt_sub_left _ _ _ h_lo_lt_mp h_mp_lt_hi

/-- Symmetric: `respondDisagree` strictly narrows the range. -/
theorem range_narrows_on_response_disagree
    (gs gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_status : gs.status = .inProgress)
    (h_wf_mp : gs.range.low.idx < mp.idx ∧ mp.idx < gs.range.high.idx)
    (h_apply : applyTransition gs .respondDisagree = .ok gs') :
    gs'.range.high.idx - gs'.range.low.idx <
      gs.range.high.idx - gs.range.low.idx := by
  obtain ⟨h_lo_lt_mp, h_mp_lt_hi⟩ := h_wf_mp
  obtain ⟨h_lo_eq, h_hi_eq⟩ :=
    applyTransition_respondDisagree_shape gs gs' mp h_pending h_status h_apply
  have h_low_idx : gs'.range.low.idx = gs.range.low.idx := by rw [h_lo_eq]
  have h_high_idx : gs'.range.high.idx = mp.idx := by rw [h_hi_eq]
  rw [h_low_idx, h_high_idx]
  exact nat_sub_lt_sub_right _ _ _ h_lo_lt_mp h_mp_lt_hi

/-! ## Smoke checks -/

/-- An initial game state with a non-trivial range. -/
example : DisputedRange where
  low  := { idx := 0,  commit := ByteArray.empty }
  high := { idx := 64, commit := ByteArray.empty }

/-- Spot-check: the depth cap is the documented 64. -/
example : MAX_BISECTION_DEPTH = 64 := rfl

/-- Spot-check: midpoint of [0, 64] is 32. -/
example :
    DisputedRange.midpointIdx
      { low := { idx := 0, commit := ByteArray.empty },
        high := { idx := 64, commit := ByteArray.empty } } = 32 := rfl

end FaultProof
end LegalKernel
