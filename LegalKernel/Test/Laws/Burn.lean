/-
LegalKernel.Test.Laws.Burn — runtime tests for the burn law.

Phase 2 WU 2.5 / WU 2.6 acceptance tests for `burn`.  Symmetric to
`MintTests`: precondition decidability, value-level effect, the
`totalSupply_after_burn` accounting equation, and the
`burn_not_conservative` non-conservation witness.
-/

import LegalKernel.Laws.Burn
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.BurnTests

/-- Tests for the `burn` law. -/
def tests : List TestCase :=
  [ { name := "precondition: enough balance ∧ amount > 0 ⇒ true"
    , body := do
        let s := setBalance emptyState 1 10 100
        let t := burn 1 10 30
        assert (decide (t.pre s)) "burn with sufficient balance should accept"
    }
  , { name := "precondition: insufficient balance ⇒ false"
    , body := do
        let s := setBalance emptyState 1 10 5
        let t := burn 1 10 30
        assert (! decide (t.pre s)) "burn beyond balance should reject"
    }
  , { name := "precondition: zero amount ⇒ false"
    , body := do
        let s := setBalance emptyState 1 10 100
        let t := burn 1 10 0
        assert (! decide (t.pre s)) "zero-amount burn should reject"
    }
  , { name := "burn subtracts amount from balance"
    , body := do
        let s  := setBalance emptyState 1 10 100
        let t  := burn 1 10 30
        let s' := step_impl s t
        assertEq (expected := (70 : Nat))
                 (actual   := getBalance s' 1 10)
                 "after burn"
    }
  , { name := "burn down to zero is allowed"
    , body := do
        let s  := setBalance emptyState 1 10 50
        let t  := burn 1 10 50
        let s' := step_impl s t
        assertEq (expected := (0 : Nat))
                 (actual   := getBalance s' 1 10)
                 "burn the entire balance"
    }
  , { name := "rejected burn is a no-op"
    , body := do
        let s  := setBalance emptyState 1 10 5
        let t  := burn 1 10 30
        let s' := step_impl s t
        assertEq (expected := (5 : Nat))
                 (actual   := getBalance s' 1 10)
                 "balance unchanged after rejected burn"
    }
  , { name := "burn leaves untouched actors and resources alone"
    , body := do
        let s := setBalance (setBalance (setBalance emptyState 1 10 100)
                  1 99 7) 2 10 11
        let t  := burn 1 10 30
        let s' := step_impl s t
        assertEq (expected := (7 : Nat))
                 (actual   := getBalance s' 1 99)
                 "other actor in same resource"
        assertEq (expected := (11 : Nat))
                 (actual   := getBalance s' 2 10)
                 "same actor in other resource"
    }
  , { name := "totalSupply_after_burn shifts supply by amount (additive form)"
    , body := do
        -- Pre-supply at r=1: 100.  Burn 30.  Post-supply: 70.
        let s := setBalance emptyState 1 10 100
        let t := burn 1 10 30
        have hpre : t.pre s := by decide
        let _proof :
            TotalSupply (step_impl s t) 1 + 30 = TotalSupply s 1 :=
          totalSupply_after_burn 1 10 30 s hpre
        -- 70 + 30 = 100; check value-level.
        assertEq (expected := TotalSupply s 1)
                 (actual   := TotalSupply (step_impl s t) 1 + 30)
                 "supply shifted by burn amount"
    }
  , { name := "burn_not_conservative witnesses non-conservation"
    , body := do
        let _proof : ¬ IsConservative (burn 1 10 30) :=
          burn_not_conservative 1 10 30 (by decide)
        pure ()
    }
  -- Cross-resource independence: burn at r doesn't touch r' ≠ r.
  , { name := "burn_other_resource_untouched: BalanceMap unchanged at r' ≠ r"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 100) 2 10 200
        let s' := step_impl s (burn 1 10 30)
        let _proof : s'.balances[(2 : ResourceId)]? = s.balances[(2 : ResourceId)]? :=
          burn_other_resource_untouched 1 2 10 30 s (by decide)
        assertEq (expected := (200 : Nat)) (actual := getBalance s' 2 10)
          "r=2 balance preserved across burn at r=1"
    }
  , { name := "burn_does_not_touch_other_resources: per-actor preservation"
    , body := do
        let s  := setBalance (setBalance emptyState 1 10 100) 2 99 7
        let s' := step_impl s (burn 1 10 30)
        let _proof : getBalance s' 2 99 = getBalance s 2 99 :=
          burn_does_not_touch_other_resources 1 2 10 30 99 s (by decide)
        assertEq (expected := (7 : Nat)) (actual := getBalance s' 2 99) "(2, 99)"
    }
  , { name := "burn_conserves_other_resource: TotalSupply unchanged at r' ≠ r"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 100) 2 10 200
        let s' := step_impl s (burn 1 10 30)
        let _proof : TotalSupply s' 2 = TotalSupply s 2 :=
          burn_conserves_other_resource 1 2 10 30 s (by decide)
        assertEq (expected := TotalSupply s 2)
                 (actual   := TotalSupply s' 2)
                 "r=2 supply preserved across burn at r=1"
    }
  ]

end LegalKernel.Test.Laws.BurnTests
