/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.Reward — runtime tests for the reward law.

Phase-4-prelude WU R.6 acceptance tests.  Mirrors `Test/Laws/Mint.lean`
case-for-case (since the kernel-level shape of `reward` is identical
to `mint`); additional cases assert the new monotonicity classification
and the absence of an `IsConservative` instance.
-/

import LegalKernel.Laws.Reward
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.RewardTests

/-- Tests for the `reward` law. -/
def tests : List TestCase :=
  [ { name := "precondition: positive amount ⇒ true"
    , body := do
        let s := emptyState
        let t := reward 1 10 50
        assert (decide (t.pre s)) "reward with positive amount should accept"
    }
  , { name := "precondition: zero amount ⇒ false"
    , body := do
        let s := emptyState
        let t := reward 1 10 0
        assert (! decide (t.pre s)) "reward with zero amount should reject"
    }
  , { name := "reward credits recipient's balance"
    , body := do
        let s  := emptyState
        let t  := reward 1 10 50
        let s' := step_impl s t
        assertEq (expected := (50 : Nat))
                 (actual   := getBalance s' 1 10)
                 "after reward"
    }
  , { name := "reward accumulates on existing balance"
    , body := do
        let s  := setBalance emptyState 1 10 100
        let t  := reward 1 10 20
        let s' := step_impl s t
        assertEq (expected := (120 : Nat))
                 (actual   := getBalance s' 1 10)
                 "reward onto existing balance"
    }
  , { name := "reward leaves untouched actors and resources alone"
    , body := do
        let s  := setBalance (setBalance emptyState 1 99 7) 2 10 11
        let t  := reward 1 10 50
        let s' := step_impl s t
        assertEq (expected := (7 : Nat))
                 (actual   := getBalance s' 1 99)
                 "other actor in same resource"
        assertEq (expected := (11 : Nat))
                 (actual   := getBalance s' 2 10)
                 "same actor in other resource"
    }
  , { name := "totalSupply_after_reward shifts supply by amount"
    , body := do
        let s := setBalance emptyState 1 10 100
        let t := reward 1 10 50
        have hpre : t.pre s := by decide
        let _proof : TotalSupply (step_impl s t) 1 = TotalSupply s 1 + 50 :=
          totalSupply_after_reward 1 10 50 s hpre
        assertEq (expected := TotalSupply s 1 + 50)
                 (actual   := TotalSupply (step_impl s t) 1)
                 "supply shifted by reward amount"
    }
  , { name := "reward_isMonotonic instance resolves"
    , body := do
        let _inst : IsMonotonic (reward 1 10 50) := inferInstance
        pure ()
    }
  , { name := "reward_not_conservative witnesses non-conservation"
    , body := do
        let _proof : ¬ IsConservative (reward 1 10 50) :=
          reward_not_conservative 1 10 50 (by decide)
        pure ()
    }
  , { name := "reward_other_resource_untouched: BalanceMap unchanged at r' ≠ r"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 100) 2 10 200
        let s' := step_impl s (reward 1 10 50)
        let _proof : s'.balances[(2 : ResourceId)]? = s.balances[(2 : ResourceId)]? :=
          reward_other_resource_untouched 1 2 10 50 s (by decide)
        assertEq (expected := (200 : Nat)) (actual := getBalance s' 2 10)
          "r=2 balance preserved across reward at r=1"
    }
  , { name := "reward_does_not_touch_other_resources: per-actor preservation"
    , body := do
        let s  := setBalance (setBalance emptyState 1 10 100) 2 99 7
        let s' := step_impl s (reward 1 10 50)
        let _proof : getBalance s' 2 99 = getBalance s 2 99 :=
          reward_does_not_touch_other_resources 1 2 10 50 99 s (by decide)
        assertEq (expected := (7 : Nat)) (actual := getBalance s' 2 99) "(2, 99)"
    }
  , { name := "reward_conserves_other_resource: TotalSupply unchanged at r' ≠ r"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 100) 2 10 200
        let s' := step_impl s (reward 1 10 50)
        let _proof : TotalSupply s' 2 = TotalSupply s 2 :=
          reward_conserves_other_resource 1 2 10 50 s (by decide)
        assertEq (expected := TotalSupply s 2)
                 (actual   := TotalSupply s' 2)
                 "r=2 supply preserved across reward at r=1"
    }
  ]

end LegalKernel.Test.Laws.RewardTests
