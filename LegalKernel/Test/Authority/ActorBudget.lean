/-
  Canon  - A Societal Kernel
-/

/-
Tests for GP.1 actor budget helpers.
-/

import LegalKernel.Authority.ActorBudget
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.Authority.ActorBudgetTests

/-- Runtime tests for `ActorBudget` / `EpochBudgetState` GP.1 helpers. -/
def tests : List TestCase :=
  [ { name := "empty currentBudget uses free-tier on epoch advance"
    , body := do
        let b := EpochBudgetState.currentBudget EpochBudgetState.empty 7 1 10
        assertEq (expected := 10) (actual := b) "free-tier floor"
    }
  , { name := "consume succeeds when funded"
    , body := do
        let e0 := EpochBudgetState.topUp EpochBudgetState.empty 1 5 0 4
        match EpochBudgetState.consume e0 1 5 0 3 with
        | some e1 =>
            assertEq (expected := 1) (actual := EpochBudgetState.currentBudget e1 1 5 0) "remaining"
        | none =>
            throw <| IO.userError "expected consume success"
    }
  , { name := "consume fails when insufficient"
    , body := do
        let e0 := EpochBudgetState.topUp EpochBudgetState.empty 1 5 0 2
        match EpochBudgetState.consume e0 1 5 0 3 with
        | some _ => throw <| IO.userError "expected consume failure"
        | none => pure ()
    }
  ]

end LegalKernel.Test.Authority.ActorBudgetTests
