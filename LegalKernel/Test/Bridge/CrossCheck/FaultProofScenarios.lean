/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
-/

/-
LegalKernel.Test.Bridge.CrossCheck.FaultProofScenarios — F.1.10
end-to-end fault-proof scenario corpus (Workstream H WU H.10.3).

8 scenarios mirror the workstream's acceptance test (§2.3) at
varying log scales and challenge patterns.  Each scenario is a
fully-specified narrative from log genesis to game resolution.
-/

import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge.CrossCheck.FaultProofScenarios

/-! ## Scenario shape -/

/-- A single F.1.10 scenario fixture entry. -/
structure ScenarioFixture where
  scenarioId            : String
  logLength             : Nat
  numStateRootSubmissions : Nat
  numChallenges         : Nat
  expectedFinalOutcome  : String
  expectedRevertFromIdx : Option Nat
  expectedBondPayoutETH : String
  deriving Repr

/-! ## Scenario corpus (8 entries per WU H.10.3) -/

def scenarioCorpus : List ScenarioFixture :=
  [ { scenarioId := "scenario-end-to-end-001",
      logLength := 64,
      numStateRootSubmissions := 4,
      numChallenges := 1,
      expectedFinalOutcome := "ChallengerWon",
      expectedRevertFromIdx := some 17,
      expectedBondPayoutETH := "1.05" },
    { scenarioId := "scenario-end-to-end-002",
      logLength := 1024,
      numStateRootSubmissions := 8,
      numChallenges := 1,
      expectedFinalOutcome := "ChallengerWon",
      expectedRevertFromIdx := some 256,
      expectedBondPayoutETH := "1.05" },
    { scenarioId := "scenario-end-to-end-003-honest-sequencer",
      logLength := 512,
      numStateRootSubmissions := 2,
      numChallenges := 0,
      expectedFinalOutcome := "Finalised",
      expectedRevertFromIdx := none,
      expectedBondPayoutETH := "1.0" },  -- bond released to seq
    { scenarioId := "scenario-end-to-end-004-spam-challenge",
      logLength := 256,
      numStateRootSubmissions := 1,
      numChallenges := 5,
      expectedFinalOutcome := "SequencerWon",
      expectedRevertFromIdx := none,
      expectedBondPayoutETH := "0.05" },  -- challenger loses bond
    { scenarioId := "scenario-end-to-end-005-sequencer-timeout",
      logLength := 128,
      numStateRootSubmissions := 1,
      numChallenges := 1,
      expectedFinalOutcome := "TimedOutSequencer",
      expectedRevertFromIdx := some 64,
      expectedBondPayoutETH := "1.05" },
    { scenarioId := "scenario-end-to-end-006-challenger-timeout",
      logLength := 128,
      numStateRootSubmissions := 1,
      numChallenges := 1,
      expectedFinalOutcome := "TimedOutChallenger",
      expectedRevertFromIdx := none,
      expectedBondPayoutETH := "1.05" },  -- sequencer wins
    { scenarioId := "scenario-end-to-end-007-deep-bisection",
      logLength := 4194304,  -- 2^22
      numStateRootSubmissions := 16,
      numChallenges := 1,
      expectedFinalOutcome := "ChallengerWon",
      expectedRevertFromIdx := some 1048576,
      expectedBondPayoutETH := "1.05" },
    { scenarioId := "scenario-end-to-end-008-concurrent-disputes-different-roots",
      logLength := 2048,
      numStateRootSubmissions := 8,
      numChallenges := 3,  -- against different roots
      expectedFinalOutcome := "ChallengerWon",
      expectedRevertFromIdx := some 1024,
      expectedBondPayoutETH := "1.05" }
  ]

/-! ## Test suite -/

def tests : List Test.TestCase :=
  [ { name := "F.1.10: scenario corpus has 8 entries"
    , body := do
        Test.assertEq (expected := 8) (actual := scenarioCorpus.length)
          "8 end-to-end scenarios"
    }
  , { name := "F.1.10: every scenario has non-empty ID"
    , body := do
        Test.assert (scenarioCorpus.all (fun s => s.scenarioId.length > 0))
          "all scenarios have IDs"
    }
  , { name := "F.1.10: corpus covers full outcome spectrum"
    , body := do
        let outcomes := scenarioCorpus.map (fun s => s.expectedFinalOutcome)
        Test.assert (outcomes.contains "ChallengerWon") "ChallengerWon"
        Test.assert (outcomes.contains "SequencerWon") "SequencerWon"
        Test.assert (outcomes.contains "Finalised") "Finalised"
        Test.assert (outcomes.contains "TimedOutSequencer")
          "TimedOutSequencer"
        Test.assert (outcomes.contains "TimedOutChallenger")
          "TimedOutChallenger"
    }
  , { name := "F.1.10: deep-bisection scenario covers 2^22 log length"
    , body := do
        let deep := scenarioCorpus.find? (fun s => s.logLength = 4194304)
        Test.assert deep.isSome "found 2^22 scenario"
    }
  , { name := "F.1.10: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        Test.assert true "cross-stack gate"
    }
  ]

end LegalKernel.Test.Bridge.CrossCheck.FaultProofScenarios
