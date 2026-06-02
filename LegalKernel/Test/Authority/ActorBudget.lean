-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
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
    -- GP.3.2 supporting lemma coverage (added under audit feedback):
  , { name := "currentBudget_after_consume_self pins post-consume balance"
    , body := do
        let e0 := EpochBudgetState.topUp EpochBudgetState.empty 1 5 0 10
        match EpochBudgetState.consume e0 1 5 0 3 with
        | some e1 =>
            let post := EpochBudgetState.currentBudget e1 1 5 0
            let pre := EpochBudgetState.currentBudget e0 1 5 0
            assertEq (expected := pre - 3) (actual := post)
              "currentBudget reduced by exactly cost"
        | none => throw <| IO.userError "expected consume success"
    }
  , { name := "currentBudget_after_consume_other: actor 2 unchanged when consuming actor 1"
    , body := do
        let e0 := EpochBudgetState.topUp
                    (EpochBudgetState.topUp EpochBudgetState.empty 1 5 0 10)
                    2 5 0 7
        let pre2 := EpochBudgetState.currentBudget e0 2 5 0
        match EpochBudgetState.consume e0 1 5 0 3 with
        | some e1 =>
            let post2 := EpochBudgetState.currentBudget e1 2 5 0
            assertEq (expected := pre2) (actual := post2)
              "actor 2's budget unchanged by actor 1's consume"
        | none => throw <| IO.userError "expected consume success"
    }
  , { name := "currentBudget_after_topUp_self credits actor"
    , body := do
        let e0 := EpochBudgetState.topUp EpochBudgetState.empty 1 5 0 4
        let pre := EpochBudgetState.currentBudget e0 1 5 0
        let e1 := EpochBudgetState.topUp e0 1 5 0 6
        let post := EpochBudgetState.currentBudget e1 1 5 0
        assertEq (expected := pre + 6) (actual := post)
          "currentBudget increased by exactly amount"
    }
  , { name := "currentBudget_after_topUp_other: actor 2 unchanged when topping up actor 1"
    , body := do
        let e0 := EpochBudgetState.topUp
                    (EpochBudgetState.topUp EpochBudgetState.empty 1 5 0 4)
                    2 5 0 7
        let pre2 := EpochBudgetState.currentBudget e0 2 5 0
        let e1 := EpochBudgetState.topUp e0 1 5 0 10
        let post2 := EpochBudgetState.currentBudget e1 2 5 0
        assertEq (expected := pre2) (actual := post2)
          "actor 2's budget unchanged by actor 1's topUp"
    }
  , { name := "consume_eq_none_iff: consume returns none iff insufficient"
    , body := do
        let e0 := EpochBudgetState.topUp EpochBudgetState.empty 1 5 0 3
        match EpochBudgetState.consume e0 1 5 0 5 with
        | some _ => throw <| IO.userError "expected consume to fail (3 < 5)"
        | none => pure ()
    }
  , { name := "currentBudget_floored_at_freeTier on epoch advance"
    , body := do
        -- Cell with lastSeenEpoch=0, budgetBalance=0.  Query at epoch=5,
        -- freeTier=100 → normalised balance is at least 100.
        let cell : ActorBudget := { lastSeenEpoch := 0, budgetBalance := 0 }
        let ebs := EpochBudgetState.empty.insert 1 cell
        let cb := EpochBudgetState.currentBudget ebs 1 5 100
        assert (cb ≥ 100) s!"floored at freeTier (got {cb})"
    }
  , { name := "currentBudget_empty_genesis: empty + epoch 0 = 0"
    , body := do
        let b := EpochBudgetState.currentBudget EpochBudgetState.empty 1 0 100
        assertEq (expected := 0) (actual := b) "epoch 0 + empty = 0"
    }
  ]

end LegalKernel.Test.Authority.ActorBudgetTests
