/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.Deposit — Workstream C.2 acceptance tests.

Mirrors `LegalKernel.Test.Laws.Mint` case-for-case (since `deposit`'s
kernel-level shape is identical to `mint`'s plus a free `depositId`
field), with extra coverage for the `IsMonotonic` instance.
-/

import LegalKernel.Laws.Deposit
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.DepositTests

/-- Tests for the `deposit` law. -/
def tests : List TestCase :=
  [ { name := "precondition: trivially true"
    , body := do
        let s := emptyState
        let t := deposit 1 10 50 0
        assert (decide (t.pre s)) "deposit's pre is True"
    }
  , { name := "deposit adds amount to recipient's balance"
    , body := do
        let s  := emptyState
        let s' := step_impl s (deposit 1 10 50 0)
        assertEq (expected := (50 : Nat))
                 (actual   := getBalance s' 1 10) "after deposit"
    }
  , { name := "deposit accumulates on existing balance"
    , body := do
        let s  := setBalance emptyState 1 10 100
        let s' := step_impl s (deposit 1 10 20 0)
        assertEq (expected := (120 : Nat)) (actual := getBalance s' 1 10) "120"
    }
  , { name := "deposit leaves untouched actors / resources alone"
    , body := do
        let s  := setBalance (setBalance emptyState 1 99 7) 2 10 11
        let s' := step_impl s (deposit 1 10 50 0)
        assertEq (expected := (7 : Nat))  (actual := getBalance s' 1 99) "other actor"
        assertEq (expected := (11 : Nat)) (actual := getBalance s' 2 10) "other resource"
    }
  , { name := "totalSupply_after_deposit shifts supply by amount"
    , body := do
        let s := setBalance emptyState 1 10 100
        let _proof : TotalSupply (step_impl s (deposit 1 10 50 0)) 1 = TotalSupply s 1 + 50 :=
          totalSupply_after_deposit 1 10 50 0 s
        assertEq (expected := TotalSupply s 1 + 50)
                 (actual   := TotalSupply (step_impl s (deposit 1 10 50 0)) 1)
                 "supply shifted by deposit amount"
    }
  , { name := "deposit_not_conservative term-level API"
    , body := do
        let _proof : ¬ IsConservative (deposit 1 10 50 0) :=
          deposit_not_conservative 1 10 50 0 (by decide)
        pure ()
    }
  , { name := "deposit_other_resource_untouched: BalanceMap unchanged at r' ≠ r"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 100) 2 10 200
        let s' := step_impl s (deposit 1 10 50 0)
        let _proof : s'.balances[(2 : ResourceId)]? = s.balances[(2 : ResourceId)]? :=
          deposit_other_resource_untouched 1 2 10 50 0 s (by decide)
        assertEq (expected := (200 : Nat)) (actual := getBalance s' 2 10) "preserved"
    }
  , { name := "deposit_does_not_touch_other_resources: per-actor preservation"
    , body := do
        let s  := setBalance (setBalance emptyState 1 10 100) 2 99 7
        let s' := step_impl s (deposit 1 10 50 0)
        let _proof : getBalance s' 2 99 = getBalance s 2 99 :=
          deposit_does_not_touch_other_resources 1 2 10 50 0 99 s (by decide)
        assertEq (expected := (7 : Nat)) (actual := getBalance s' 2 99) "(2, 99)"
    }
  , { name := "deposit_other_actor_untouched: same-resource locality"
    , body := do
        let s  := setBalance (setBalance emptyState 1 10 100) 1 99 50
        let s' := step_impl s (deposit 1 10 25 0)
        -- Actor 99's balance at resource 1 is unaffected.
        let _proof : getBalance s' 1 99 = getBalance s 1 99 :=
          deposit_other_actor_untouched 1 10 99 25 0 s (by decide)
        assertEq (expected := (50 : Nat)) (actual := getBalance s' 1 99) "actor 99 preserved"
    }
  , { name := "deposit_conserves_other_resource: TotalSupply unchanged at r' ≠ r"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 100) 2 10 200
        let s' := step_impl s (deposit 1 10 50 0)
        let _proof : TotalSupply s' 2 = TotalSupply s 2 :=
          deposit_conserves_other_resource 1 2 10 50 0 s (by decide)
        assertEq (expected := TotalSupply s 2)
                 (actual   := TotalSupply s' 2)
                 "r=2 supply preserved"
    }
  , { name := "deposit_isMonotonic instance resolves"
    , body := do
        let _inst : IsMonotonic (deposit 1 5 10 42) := inferInstance
        pure ()
    }
  , { name := "deposit with depositId differs at the Action layer"
    , body := do
        -- Two deposits with the same numeric body but different
        -- depositIds should be distinguishable as kernel transitions
        -- only by the `depositId` field — since the kernel-level
        -- effect is identical, the kernel `Transition`s are extensionally
        -- equivalent.  The Action-layer distinction (via
        -- `Action.compile_injective`) is what actually distinguishes them
        -- at the bridge layer.
        let s := emptyState
        let s1 := step_impl s (deposit 1 10 25 100)
        let s2 := step_impl s (deposit 1 10 25 200)
        -- Same kernel effect:
        assertEq (expected := getBalance s1 1 10) (actual := getBalance s2 1 10)
                 "same kernel effect"
    }
  ]

end LegalKernel.Test.Laws.DepositTests
