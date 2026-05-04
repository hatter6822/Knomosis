/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.Mint — runtime tests for the mint law.

Phase 2 WU 2.5 / WU 2.6 acceptance tests.  Drives `mint`'s precondition
decidability, value-level effect on balances, the
`totalSupply_after_mint` accounting equation, and the
`mint_not_conservative` non-conservation witness at runtime.
-/

import LegalKernel.Laws.Mint
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.MintTests

/-- Tests for the `mint` law. -/
def tests : List TestCase :=
  [ { name := "precondition: positive amount ⇒ true"
    , body := do
        let s := emptyState
        let t := mint 1 10 50
        assert (decide (t.pre s)) "mint with positive amount should accept"
    }
  , { name := "precondition: zero amount ⇒ false"
    , body := do
        let s := emptyState
        let t := mint 1 10 0
        assert (! decide (t.pre s)) "mint with zero amount should reject"
    }
  , { name := "mint adds amount to recipient's balance"
    , body := do
        let s  := emptyState
        let t  := mint 1 10 50
        let s' := step_impl s t
        assertEq (expected := (50 : Nat))
                 (actual   := getBalance s' 1 10)
                 "after mint"
    }
  , { name := "mint accumulates on existing balance"
    , body := do
        -- Pre: actor 10 holds 100 at r=1.  Post-mint(20): 120.
        let s  := setBalance emptyState 1 10 100
        let t  := mint 1 10 20
        let s' := step_impl s t
        assertEq (expected := (120 : Nat))
                 (actual   := getBalance s' 1 10)
                 "mint onto existing balance"
    }
  , { name := "mint leaves untouched actors and resources alone"
    , body := do
        let s  := setBalance (setBalance emptyState 1 99 7) 2 10 11
        let t  := mint 1 10 50
        let s' := step_impl s t
        assertEq (expected := (7 : Nat))
                 (actual   := getBalance s' 1 99)
                 "other actor in same resource"
        assertEq (expected := (11 : Nat))
                 (actual   := getBalance s' 2 10)
                 "same actor in other resource"
    }
  , { name := "totalSupply_after_mint shifts supply by amount"
    , body := do
        -- Pre-supply at r=1: 100.  Mint 50.  Post-supply: 150.
        let s := setBalance emptyState 1 10 100
        let t := mint 1 10 50
        have hpre : t.pre s := by decide
        let _proof : TotalSupply (step_impl s t) 1 = TotalSupply s 1 + 50 :=
          totalSupply_after_mint 1 10 50 s hpre
        assertEq (expected := TotalSupply s 1 + 50)
                 (actual   := TotalSupply (step_impl s t) 1)
                 "supply shifted by mint amount"
    }
  , { name := "mint_not_conservative witnesses non-conservation"
    , body := do
        -- Term-level API check that mint is not IsConservative.
        let _proof : ¬ IsConservative (mint 1 10 50) :=
          mint_not_conservative 1 10 50 (by decide)
        pure ()
    }
  -- Cross-resource independence: mint at r doesn't touch r' ≠ r.
  , { name := "mint_other_resource_untouched: BalanceMap unchanged at r' ≠ r"
    , body := do
        -- Pre-state has resource 2 holding (10 ↦ 200).  Mint at r=1
        -- shouldn't touch r=2's BalanceMap.
        let s := setBalance (setBalance emptyState 1 10 100) 2 10 200
        let s' := step_impl s (mint 1 10 50)
        -- Term-level API check.
        let _proof : s'.balances[(2 : ResourceId)]? = s.balances[(2 : ResourceId)]? :=
          mint_other_resource_untouched 1 2 10 50 s (by decide)
        -- Value-level: r=2 actor 10's balance is unchanged.
        assertEq (expected := (200 : Nat)) (actual := getBalance s' 2 10)
          "r=2 balance preserved across mint at r=1"
    }
  , { name := "mint_does_not_touch_other_resources: per-actor preservation"
    , body := do
        let s  := setBalance (setBalance emptyState 1 10 100) 2 99 7
        let s' := step_impl s (mint 1 10 50)
        let _proof : getBalance s' 2 99 = getBalance s 2 99 :=
          mint_does_not_touch_other_resources 1 2 10 50 99 s (by decide)
        assertEq (expected := (7 : Nat)) (actual := getBalance s' 2 99) "(2, 99)"
    }
  , { name := "mint_conserves_other_resource: TotalSupply unchanged at r' ≠ r"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 100) 2 10 200
        let s' := step_impl s (mint 1 10 50)
        let _proof : TotalSupply s' 2 = TotalSupply s 2 :=
          mint_conserves_other_resource 1 2 10 50 s (by decide)
        assertEq (expected := TotalSupply s 2)
                 (actual   := TotalSupply s' 2)
                 "r=2 supply preserved across mint at r=1"
    }
  -- Phase-4-prelude WU R.19: monotonicity instance check.
  , { name := "mint_isMonotonic instance resolves"
    , body := do
        let _inst : IsMonotonic (mint 1 5 10) := inferInstance
        pure ()
    }
  ]

end LegalKernel.Test.Laws.MintTests
