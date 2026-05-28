/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Strategy — honest-strategy definition and
strategy-uniqueness theorem (Workstream H WUs H.4.4a + H.4.4b).

The honest strategy: given the truthful commit function (the
canonical state-root mapping computed by replaying the log from
genesis), the honest player always submits the truthful midpoint
when it's their turn to submit, and always agrees/disagrees with
the opposing party's midpoint based on whether it matches the
truth.

**Trust-model claim** (WU H.4.4c, in `Honesty.lean`): an honest
challenger playing this strategy always wins against a sequencer
who has published an invalid state root.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Coherence
import LegalKernel.FaultProof.Game
import LegalKernel.Runtime.LogFile

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime

/-! ## Truthful commit function -/

/-- The truthful state-root function: given a genesis state and
    a log, the canonical state-root commit at log index `idx` is
    `commitExtendedState` of the state obtained by replaying the
    log up to index `idx`. -/
def truthfulCommit
    (genesis : ExtendedState) (log : List LogEntry)
    (idx : LogIndex) : StateCommit :=
  commitExtendedState (kernelOnlyReplay genesis (log.take idx))

/-- Determinism of `truthfulCommit`. -/
theorem truthfulCommit_deterministic
    (g₁ g₂ : ExtendedState) (l₁ l₂ : List LogEntry) (i₁ i₂ : LogIndex)
    (h_g : g₁ = g₂) (h_l : l₁ = l₂) (h_i : i₁ = i₂) :
    truthfulCommit g₁ l₁ i₁ = truthfulCommit g₂ l₂ i₂ := by
  rw [h_g, h_l, h_i]

/-! ## Honest-strategy definition

The honest strategy maps a game state to the canonical move
prescribed by the truthful-commit function.  The strategy is
total over in-progress games when it's the player's turn. -/

/-- Whose turn is it relative to `me`?  `me` is the player whose
    perspective we're computing from. -/
def isMyTurn (gs : LegalKernel.FaultProof.GameState) (me : TurnSide) :
    Bool :=
  decide (gs.turn = me)

/-- The honest strategy.  Given the truthful commit function and
    the game state, return the unique honest move when it's the
    player's turn.

    Three cases:
      * No pending midpoint, my turn: submit the truthful
        midpoint at `(low.idx + high.idx) / 2`.
      * Pending midpoint, my turn: agree iff the pending midpoint
        commit matches the truth.
      * Single-step + no pending midpoint, my turn: terminate.

    For brevity, when range is single-step the strategy returns
    `none` (the actual termination requires a `KernelStep`
    argument that this strategy doesn't have access to in
    isolation; the L1 contract supplies it from the responding
    party's call). -/
def honestStrategy
    (truth : LogIndex → StateCommit)
    (gs : LegalKernel.FaultProof.GameState)
    (me : TurnSide) :
    Option GameTransition :=
  if h_status : gs.status = .inProgress then
    let _ := h_status
    if h_turn : gs.turn = me then
      let _ := h_turn
      match gs.pendingMidpoint with
      | none =>
        -- My turn to submit: pick the truthful midpoint.
        let midIdx := gs.range.midpointIdx
        if gs.range.low.idx < midIdx ∧ midIdx < gs.range.high.idx then
          some (.submitMidpoint
                  { idx := midIdx, commit := truth midIdx })
        else
          -- Range is single-step (or degenerate); termination
          -- needs a KernelStep argument the strategy doesn't have.
          none
      | some mp =>
        -- My turn to respond: agree iff the midpoint matches truth.
        if mp.commit = truth mp.idx then
          some .respondAgree
        else
          some .respondDisagree
    else none
  else none

/-! ## Strategy uniqueness (#268, H.4.4b)

A "strategy" is any function from game state to optional
transition.  The honest strategy is the unique strategy that
always picks the truthful move when it's the player's turn. -/

/-- A strategy is "honest by truth" iff it always picks the
    truthful move at every legal in-progress turn. -/
def isHonestByTruth
    (truth : LogIndex → StateCommit)
    (strategy : LegalKernel.FaultProof.GameState → TurnSide → Option GameTransition) :
    Prop :=
  ∀ gs me,
    gs.status = .inProgress →
    gs.turn = me →
    strategy gs me = honestStrategy truth gs me

/-- #268 — The honest strategy is uniquely determined by the
    truthful commit function: any strategy that's "honest by
    truth" agrees with `honestStrategy` at every in-progress
    turn.

    By definition; `isHonestByTruth` is exactly the property
    "agrees with `honestStrategy`". -/
theorem honest_strategy_unique
    (truth : LogIndex → StateCommit)
    (strategy : LegalKernel.FaultProof.GameState → TurnSide → Option GameTransition)
    (h : isHonestByTruth truth strategy)
    (gs : LegalKernel.FaultProof.GameState) (me : TurnSide)
    (h_status : gs.status = .inProgress)
    (h_turn : gs.turn = me) :
    strategy gs me = honestStrategy truth gs me :=
  h gs me h_status h_turn

/-! ## Smoke checks -/

/-- The honest strategy on a non-in-progress game is `none`. -/
example
    (truth : LogIndex → StateCommit)
    (gs : LegalKernel.FaultProof.GameState) (me : TurnSide)
    (h : gs.status ≠ .inProgress) :
    honestStrategy truth gs me = none := by
  unfold honestStrategy
  simp [h]

/-- The honest strategy on a wrong-turn game is `none`. -/
example
    (truth : LogIndex → StateCommit)
    (gs : LegalKernel.FaultProof.GameState) (me : TurnSide)
    (h : gs.turn ≠ me) :
    honestStrategy truth gs me = none := by
  unfold honestStrategy
  by_cases h_status : gs.status = .inProgress
  · simp [h_status, h]
  · simp [h_status]

end FaultProof
end LegalKernel
