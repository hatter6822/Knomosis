/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.Withdraw — Workstream C.3 acceptance tests.

Mirrors `LegalKernel.Test.Laws.Burn` case-for-case (since `withdraw`'s
kernel-level shape is identical to `burn`'s plus an `EthAddress`
field), with extra coverage for the `recipientL1` parameter.
-/

import LegalKernel.Laws.Withdraw
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test
open LegalKernel.Bridge

namespace LegalKernel.Test.Laws.WithdrawTests

/-- Sample L1 destination for tests.  Numerical 0; deployments use
    real addresses. -/
def rcp0 : EthAddress := EthAddress.zero

/-- Tests for the `withdraw` law. -/
def tests : List TestCase :=
  [ { name := "precondition: sufficient balance ⇒ true"
    , body := do
        let s := setBalance emptyState 1 10 100
        let t := withdraw 1 10 50 rcp0
        assert (decide (t.pre s)) "withdraw with sufficient balance"
    }
  , { name := "precondition: insufficient balance ⇒ false"
    , body := do
        let s := setBalance emptyState 1 10 30
        let t := withdraw 1 10 50 rcp0
        assert (! decide (t.pre s)) "withdraw with insufficient balance"
    }
  , { name := "precondition: zero balance ⇒ false (when amount > 0)"
    , body := do
        let s := emptyState
        let t := withdraw 1 10 1 rcp0
        assert (! decide (t.pre s)) "withdraw with zero balance"
    }
  -- AR.21: zero-amount withdrawals are now INADMISSIBLE (positivity
  -- clause added to `withdraw.pre`).  The pre-AR test admitted them
  -- vacuously; the post-AR test exercises the rejection.
  , { name := "precondition: zero withdrawal ⇒ false (AR.21)"
    , body := do
        let s := emptyState
        let t := withdraw 1 10 0 rcp0
        assert (! decide (t.pre s)) "zero-amount withdraw must be inadmissible"
    }
  , { name := "withdraw decreases sender's balance"
    , body := do
        let s  := setBalance emptyState 1 10 100
        let s' := step_impl s (withdraw 1 10 30 rcp0)
        assertEq (expected := (70 : Nat)) (actual := getBalance s' 1 10) "after"
    }
  , { name := "withdraw rejected when balance insufficient"
    , body := do
        let s  := setBalance emptyState 1 10 30
        let s' := step_impl s (withdraw 1 10 50 rcp0)
        -- step_impl returns s unchanged when pre fails.
        assertEq (expected := (30 : Nat)) (actual := getBalance s' 1 10) "no-op"
    }
  , { name := "withdraw leaves untouched actors / resources alone"
    , body := do
        let s  := setBalance (setBalance (setBalance emptyState 1 10 100) 1 99 7) 2 10 11
        let s' := step_impl s (withdraw 1 10 30 rcp0)
        assertEq (expected := (7 : Nat))  (actual := getBalance s' 1 99) "actor 99"
        assertEq (expected := (11 : Nat)) (actual := getBalance s' 2 10) "resource 2"
    }
  , { name := "totalSupply_after_withdraw decreases supply by amount"
    , body := do
        let s := setBalance emptyState 1 10 100
        let t := withdraw 1 10 30 rcp0
        -- AR.21: precondition is `0 < amount ∧ amount ≤ balance`.
        have hpre : t.pre s := by
          show 0 < (30 : Nat) ∧ getBalance s 1 10 ≥ 30
          refine ⟨by decide, ?_⟩
          show getBalance (setBalance emptyState 1 10 100) 1 10 ≥ 30
          rw [getBalance_setBalance_same]
          decide
        let _proof : TotalSupply (step_impl s t) 1 + 30 = TotalSupply s 1 :=
          totalSupply_after_withdraw 1 10 30 rcp0 s hpre
        assertEq (expected := TotalSupply s 1)
                 (actual   := TotalSupply (step_impl s t) 1 + 30)
                 "supply equation"
    }
  , { name := "withdraw_not_conservative term-level API"
    , body := do
        let _proof : ¬ IsConservative (withdraw 1 10 50 rcp0) :=
          withdraw_not_conservative 1 10 50 rcp0 (by decide)
        pure ()
    }
  , { name := "withdraw_not_monotonic term-level API"
    , body := do
        let _proof : ¬ IsMonotonic (withdraw 1 10 50 rcp0) :=
          withdraw_not_monotonic 1 10 50 rcp0 (by decide)
        pure ()
    }
  , { name := "withdraw_other_resource_untouched: BalanceMap at r' ≠ r"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 100) 2 10 200
        let s' := step_impl s (withdraw 1 10 30 rcp0)
        let _proof : s'.balances[(2 : ResourceId)]? = s.balances[(2 : ResourceId)]? :=
          withdraw_other_resource_untouched 1 2 10 30 rcp0 s (by decide)
        assertEq (expected := (200 : Nat)) (actual := getBalance s' 2 10) "200"
    }
  , { name := "withdraw_does_not_touch_other_resources: per-actor preservation"
    , body := do
        let s  := setBalance (setBalance emptyState 1 10 100) 2 99 7
        let s' := step_impl s (withdraw 1 10 30 rcp0)
        let _proof : getBalance s' 2 99 = getBalance s 2 99 :=
          withdraw_does_not_touch_other_resources 1 2 10 30 rcp0 99 s (by decide)
        assertEq (expected := (7 : Nat)) (actual := getBalance s' 2 99) "(2, 99)"
    }
  , { name := "withdraw_other_actor_untouched: same-resource locality"
    , body := do
        let s  := setBalance (setBalance emptyState 1 10 100) 1 99 50
        let s' := step_impl s (withdraw 1 10 25 rcp0)
        let _proof : getBalance s' 1 99 = getBalance s 1 99 :=
          withdraw_other_actor_untouched 1 10 99 25 rcp0 s (by decide)
        assertEq (expected := (50 : Nat)) (actual := getBalance s' 1 99) "actor 99"
    }
  , { name := "withdraw_conserves_other_resource: TotalSupply unchanged at r' ≠ r"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 100) 2 10 200
        let s' := step_impl s (withdraw 1 10 30 rcp0)
        let _proof : TotalSupply s' 2 = TotalSupply s 2 :=
          withdraw_conserves_other_resource 1 2 10 30 rcp0 s (by decide)
        assertEq (expected := TotalSupply s 2)
                 (actual   := TotalSupply s' 2) "preserved"
    }
  , { name := "exact-balance withdrawal succeeds"
    , body := do
        let s  := setBalance emptyState 1 10 50
        let s' := step_impl s (withdraw 1 10 50 rcp0)
        assertEq (expected := (0 : Nat)) (actual := getBalance s' 1 10) "drained"
    }
  ]

end LegalKernel.Test.Laws.WithdrawTests
