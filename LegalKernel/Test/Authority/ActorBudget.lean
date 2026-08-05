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
    -- ## Stored-balance growth (the `eb_val` 8-byte-head argument)
    --
    -- `FaultProof/BoundsReachable.lean` rests the decision not to widen
    -- the epoch-budget cell on a per-step growth bound.  These pin the
    -- bound's SHAPE, and in particular the two facts an earlier
    -- statement of it ("a budget advances by at most
    -- `MAX_TOPUP_BUDGET_PER_ACTION`") got wrong.
  , { name := "storedBalance reads the raw cell, not the normalised one"
    , body := do
        -- The distinction the growth bound turns on: `currentBudget`
        -- floors at the free tier, `storedBalance` does not.
        let cell : ActorBudget := { lastSeenEpoch := 0, budgetBalance := 0 }
        let ebs := EpochBudgetState.empty.insert 1 cell
        assertEq (expected := 0) (actual := EpochBudgetState.storedBalance ebs 1)
          "stored balance is the raw cell value"
        assert (EpochBudgetState.currentBudget ebs 1 5 100 ≥ 100)
          "currentBudget normalises and so floors at the free tier"
    }
  , { name := "OBLIGATION: the free tier lifts a balance past the grant cap"
    , body := do
        -- A grant of 1 unit against a stale cell and a free tier of
        -- 10^6 leaves 10^6 + 1 stored.  So "a budget advances by at
        -- most MAX_TOPUP_BUDGET_PER_ACTION" is false: the advance is
        -- bounded by `max stored freeTier + amount`, and the free-tier
        -- term is set by `BudgetPolicy`, which does not bound it.
        let stale : ActorBudget := { lastSeenEpoch := 0, budgetBalance := 0 }
        let ebs := EpochBudgetState.empty.insert 1 stale
        let freeTier := 1000000
        let after := EpochBudgetState.topUp ebs 1 5 freeTier 1
        let stored := EpochBudgetState.storedBalance after 1
        assertEq (expected := freeTier + 1) (actual := stored)
          "one step lifted the stored balance to freeTier + grant"
        -- ...and the proved bound still holds, which is the point.
        assert (stored ≤ max (EpochBudgetState.storedBalance ebs 1) freeTier + 1)
          "storedBalance_topUp_le must bound the observed growth"
    }
  , { name := "storedBalance_topUp_le bounds the untargeted actor too"
    , body := do
        let ebs := EpochBudgetState.topUp EpochBudgetState.empty 1 5 0 40
        let after := EpochBudgetState.topUp ebs 2 5 0 7
        assertEq (expected := 40) (actual := EpochBudgetState.storedBalance after 1)
          "a top-up aimed elsewhere does not move this cell"
        assert (EpochBudgetState.storedBalance after 1
                  ≤ max (EpochBudgetState.storedBalance ebs 1) 0 + 7)
          "the bound is uniform in the actor"
    }
  , { name := "storedBalance_consume_le: spending is not a growth path"
    , body := do
        let ebs := EpochBudgetState.topUp EpochBudgetState.empty 1 5 0 40
        match EpochBudgetState.consume ebs 1 5 0 15 with
        | some ebs' =>
            assertEq (expected := 25) (actual := EpochBudgetState.storedBalance ebs' 1)
              "consume subtracts from the stored balance"
            assert (EpochBudgetState.storedBalance ebs' 1
                      ≤ max (EpochBudgetState.storedBalance ebs 1) 0)
              "consume cannot raise the stored balance above the floor"
        | none => throw <| IO.userError "expected consume success"
    }
  , { name := "growth-bound API stable"
    , body := do
        let _ := @EpochBudgetState.storedBalance_topUp_le
        let _ := @EpochBudgetState.storedBalance_consume_le
        let _ := @ActorBudget.topUp_budgetBalance_le
        let _ := @ActorBudget.consume_some_budgetBalance_le
        let _ := @ActorBudget.normalise_budgetBalance_le_max
        assert true "API exists"
    }
  ]

end LegalKernel.Test.Authority.ActorBudgetTests
