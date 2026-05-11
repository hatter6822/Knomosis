/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Game — value-level tests for the
bisection-game state machine (Workstream H §12.4 / WUs H.4.1 +
H.4.2 + H.4.3).
-/

import LegalKernel.FaultProof.Game
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Game

private def initialRange : DisputedRange := {
  low  := { idx := 0,   commit := ByteArray.empty },
  high := { idx := 64,  commit := ByteArray.empty }
}

private def initialGame : LegalKernel.FaultProof.GameState := {
  sequencer       := 1,
  challenger      := 2,
  range           := initialRange,
  pendingMidpoint := none,
  depth           := 0,
  turn            := .sequencer,
  sequencerBond   := 1_000,
  challengerBond  := 50,
  status          := .inProgress,
  deploymentId    := ByteArray.empty
}

/-- Tests for the bisection game data types + transitions. -/
def tests : List TestCase :=
  [ { name := "MAX_BISECTION_DEPTH is 64"
    , body := do
        assertEq (expected := 64) (actual := MAX_BISECTION_DEPTH) "depth cap"
    }
  , { name := "DisputedRange.midpointIdx of [0, 64] is 32"
    , body := do
        assertEq (expected := 32) (actual := initialRange.midpointIdx) "midpoint"
    }
  , { name := "DisputedRange.isSingleStep on adjacent indices"
    , body := do
        let r : DisputedRange := {
          low  := { idx := 5, commit := ByteArray.empty },
          high := { idx := 6, commit := ByteArray.empty }
        }
        assert r.isSingleStep "adjacent indices are single-step"
    }
  , { name := "DisputedRange.isSingleStep rejects gap"
    , body := do
        let r : DisputedRange := {
          low  := { idx := 5, commit := ByteArray.empty },
          high := { idx := 7, commit := ByteArray.empty }
        }
        assert (¬ r.isSingleStep) "gap of 2 is not single-step"
    }
  , { name := "TurnSide.flip alternates"
    , body := do
        assert (TurnSide.flip .sequencer = .challenger) "sequencer flips to challenger"
        assert (TurnSide.flip .challenger = .sequencer) "challenger flips to sequencer"
    }
  , { name := "submitMidpoint succeeds within range"
    , body := do
        let mp : Claim := { idx := 32, commit := ByteArray.empty }
        match applyTransition initialGame (.submitMidpoint mp) with
        | .ok gs' =>
          assert gs'.pendingMidpoint.isSome "midpoint pending after submit"
          assertEq (expected := TurnSide.challenger) (actual := gs'.turn)
            "turn flipped after submit"
        | .error _ => assert false "submitMidpoint should succeed"
    }
  , { name := "submitMidpoint rejects out-of-range midpoint"
    , body := do
        let mp : Claim := { idx := 100, commit := ByteArray.empty }
        match applyTransition initialGame (.submitMidpoint mp) with
        | .ok _   => assert false "should reject mp outside range"
        | .error e =>
          assertEq (expected := GameError.midpointOutOfRange) (actual := e)
            "got expected error variant"
    }
  , { name := "respondAgree without pending midpoint fails"
    , body := do
        match applyTransition initialGame .respondAgree with
        | .ok _   => assert false "should require a pending midpoint"
        | .error e =>
          assertEq (expected := GameError.responseDuringSubmit) (actual := e)
            "got expected error variant"
    }
  , { name := "respondAgree with pending midpoint succeeds and narrows range"
    , body := do
        let gameAfterSubmit : LegalKernel.FaultProof.GameState :=
          { initialGame with
              pendingMidpoint := some { idx := 32, commit := ByteArray.empty },
              turn := .challenger }
        match applyTransition gameAfterSubmit .respondAgree with
        | .ok gs' =>
          assertEq (expected := 32) (actual := gs'.range.low.idx)
            "low.idx narrowed to midpoint"
          assertEq (expected := 64) (actual := gs'.range.high.idx)
            "high.idx unchanged after agree"
          assertEq (expected := 1) (actual := gs'.depth)
            "depth incremented"
          assert gs'.pendingMidpoint.isNone "pending cleared after response"
        | .error _ => assert false "respondAgree should succeed"
    }
  , { name := "respondDisagree narrows to first half"
    , body := do
        let gameAfterSubmit : LegalKernel.FaultProof.GameState :=
          { initialGame with
              pendingMidpoint := some { idx := 32, commit := ByteArray.empty },
              turn := .challenger }
        match applyTransition gameAfterSubmit .respondDisagree with
        | .ok gs' =>
          assertEq (expected := 0) (actual := gs'.range.low.idx)
            "low.idx unchanged after disagree"
          assertEq (expected := 32) (actual := gs'.range.high.idx)
            "high.idx narrowed to midpoint"
        | .error _ => assert false "respondDisagree should succeed"
    }
  , { name := "applyTransition rejects after game ended"
    , body := do
        let endedGame : LegalKernel.FaultProof.GameState :=
          { initialGame with status := .sequencerWon }
        let mp : Claim := { idx := 32, commit := ByteArray.empty }
        match applyTransition endedGame (.submitMidpoint mp) with
        | .ok _   => assert false "should reject moves on ended game"
        | .error e =>
          assertEq (expected := GameError.gameAlreadyEnded) (actual := e)
            "got expected error variant"
    }
  , { name := "timeout transition advances status (turn = sequencer)"
    , body := do
        -- initialGame.turn = .sequencer; timeoutLoss derives the
        -- loser from the turn.
        match applyTransition initialGame .timeoutLoss with
        | .ok gs' =>
          assertEq (expected := GameStatus.timedOutSequencer) (actual := gs'.status)
            "sequencer timeout"
        | .error _ => assert false "timeout should succeed in progress"
    }
  , { name := "timeout transition advances status (turn = challenger)"
    , body := do
        let challengerTurnGame : LegalKernel.FaultProof.GameState :=
          { initialGame with turn := .challenger }
        match applyTransition challengerTurnGame .timeoutLoss with
        | .ok gs' =>
          assertEq (expected := GameStatus.timedOutChallenger) (actual := gs'.status)
            "challenger timeout"
        | .error _ => assert false "timeout should succeed in progress"
    }
  , { name := "gameWellFormed of initial game is true"
    , body := do
        assert (gameWellFormed initialGame) "initial game well-formed"
    }
  , { name := "gameWellFormed rejects degenerate range"
    , body := do
        let degenerate : LegalKernel.FaultProof.GameState :=
          { initialGame with
              range := { low := { idx := 5, commit := ByteArray.empty },
                         high := { idx := 5, commit := ByteArray.empty } } }
        assert (¬ gameWellFormed degenerate) "low = high is degenerate"
    }
  , { name := "gameWellFormed rejects depth > MAX"
    , body := do
        let deepGame : LegalKernel.FaultProof.GameState :=
          { initialGame with depth := MAX_BISECTION_DEPTH + 1 }
        assert (¬ gameWellFormed deepGame) "depth > cap rejected"
    }
  , { name := "applyTransition_deterministic"
    , body := do
        -- Determinism is structurally `rfl`: equal inputs produce
        -- equal outputs.  We don't have BEq on `Except GameError
        -- GameState`, so we project both into the success branch
        -- and compare the GameState fields.
        let mp : Claim := { idx := 32, commit := ByteArray.empty }
        match applyTransition initialGame (.submitMidpoint mp),
              applyTransition initialGame (.submitMidpoint mp) with
        | .ok gs1, .ok gs2 =>
          -- Compare critical fields.  GameState doesn't have BEq
          -- (ByteArray field), so compare a couple of observable
          -- pieces.
          assertEq (expected := gs1.depth) (actual := gs2.depth) "depth"
          assertEq (expected := gs1.range.high.idx) (actual := gs2.range.high.idx)
            "range high"
        | _, _ => assert false "both should succeed"
    }
  ]

end LegalKernel.Test.FaultProof.Game
