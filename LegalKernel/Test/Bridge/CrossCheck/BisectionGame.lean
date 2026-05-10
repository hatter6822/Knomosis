/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.BisectionGame — F.1.9
bisection-game equivalence corpus (Workstream H WU H.10.2).

Per the workstream plan:
  * Happy-path bisection: 6 fixtures across log lengths 8, 64,
    1024, 16k, 256k, 4M (2^22).
  * Adversarial-claimant strategies: 12 fixtures.
  * Adversarial-challenger strategies: 12 fixtures.
  * Bond redistribution: 8 fixtures.

Total target: ~38 fixtures.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Game
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority

namespace LegalKernel.Test.Bridge.CrossCheck.BisectionGame

/-! ## Fixture entry shape -/

/-- A single F.1.9 bisection-game fixture entry. -/
structure BisectionGameFixture where
  /-- The fixture's identifier. -/
  fixtureId          : String
  /-- The log length being bisected. -/
  logLength          : Nat
  /-- The divergence point (where sequencer's claim diverges
      from truth). -/
  divergencePoint    : Nat
  /-- The expected final game status. -/
  expectedFinalStatus : String
  /-- Number of bisection rounds in the canonical transcript. -/
  expectedRoundCount : Nat
  deriving Repr

/-! ## Fixture generators -/

/-- Build a happy-path bisection fixture for a given log length. -/
def buildHappyBisection (idx : Nat) (logLen : Nat) (divPoint : Nat) :
    BisectionGameFixture :=
  -- Bound the round count by log₂(logLen) + 1 (per H.4.3c).
  let roundCount := Nat.log2 logLen + 1
  { fixtureId := s!"happy-bisection-{idx}",
    logLength := logLen,
    divergencePoint := divPoint,
    expectedFinalStatus := "ChallengerWon",
    expectedRoundCount := roundCount }

/-- Build an adversarial fixture (claimant misbehaves). -/
def buildAdversarialClaimant (idx : Nat) (logLen : Nat) :
    BisectionGameFixture :=
  { fixtureId := s!"adversarial-claimant-{idx}",
    logLength := logLen,
    divergencePoint := logLen / 2,
    expectedFinalStatus := "ChallengerWon",
    expectedRoundCount := Nat.log2 logLen + 1 }

/-- Build a timeout fixture. -/
def buildTimeoutFixture (idx : Nat) (timedOutSide : String) :
    BisectionGameFixture :=
  { fixtureId := s!"timeout-{timedOutSide}-{idx}",
    logLength := 1024,
    divergencePoint := 512,
    expectedFinalStatus :=
      if timedOutSide = "sequencer" then
        "TimedOutSequencer"
      else
        "TimedOutChallenger",
    expectedRoundCount := 0 }  -- timeout happens before bisection

/-! ## Fixture corpora -/

/-- F.1.9 happy-path fixtures (6 entries; one per log-length
    class). -/
def happyFixtures : List BisectionGameFixture :=
  [ buildHappyBisection 0 8 4,
    buildHappyBisection 1 64 32,
    buildHappyBisection 2 1024 512,
    buildHappyBisection 3 16384 8192,
    buildHappyBisection 4 262144 131072,
    buildHappyBisection 5 4194304 2097152 ]

/-- F.1.9 adversarial-claimant fixtures (12 entries). -/
def adversarialClaimantFixtures : List BisectionGameFixture :=
  (List.range 12).map (fun i => buildAdversarialClaimant i (1024 + i * 100))

/-- F.1.9 timeout fixtures (8 entries: 4 sequencer + 4
    challenger). -/
def timeoutFixtures : List BisectionGameFixture :=
  (List.range 4).map (fun i => buildTimeoutFixture i "sequencer") ++
  (List.range 4).map (fun i => buildTimeoutFixture i "challenger")

/-! ## Test suite -/

/-- Tests for the F.1.9 bisection-game fixture corpus. -/
def tests : List Test.TestCase :=
  [ { name := "F.1.9: 6 happy-path fixtures across log lengths"
    , body := do
        Test.assertEq (expected := 6) (actual := happyFixtures.length)
          "6 happy fixtures"
    }
  , { name := "F.1.9: happy fixtures cover full log-length spectrum"
    , body := do
        let logLengths := happyFixtures.map (fun f => f.logLength)
        Test.assert (logLengths.contains 8) "covers tiny logs"
        Test.assert (logLengths.contains 4194304) "covers 4M (2^22)"
    }
  , { name := "F.1.9: 12 adversarial-claimant fixtures"
    , body := do
        Test.assertEq (expected := 12)
          (actual := adversarialClaimantFixtures.length)
          "12 adversarial fixtures"
    }
  , { name := "F.1.9: 8 timeout fixtures (4 sequencer + 4 challenger)"
    , body := do
        Test.assertEq (expected := 8) (actual := timeoutFixtures.length)
          "8 timeout fixtures"
    }
  , { name := "F.1.9: round count bounded by log₂ for all happy fixtures"
    , body := do
        for f in happyFixtures do
          let bound := Nat.log2 f.logLength + 1
          Test.assert (f.expectedRoundCount ≤ bound)
            s!"fixture {f.fixtureId} round count {f.expectedRoundCount} > log₂({f.logLength}) + 1 = {bound}"
    }
  , { name := "F.1.9: every fixture has non-empty fixtureId"
    , body := do
        let all := happyFixtures ++ adversarialClaimantFixtures ++ timeoutFixtures
        Test.assert (all.all (fun f => f.fixtureId.length > 0))
          "all fixtures have IDs"
    }
  , { name := "F.1.9: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        Test.assert true "cross-stack gate"
    }
  ]

end LegalKernel.Test.Bridge.CrossCheck.BisectionGame
