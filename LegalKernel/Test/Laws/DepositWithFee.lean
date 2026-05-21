import LegalKernel.Laws.DepositWithFee
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.DepositWithFeeTests

/-- Tests for the corresponding GP.2 law. -/
def tests : List TestCase :=
  [ { name := "precondition: trivially true"
    , body := do
        let t := depositWithFee 1 10 99 7 3 0 11
        assert (decide (t.pre emptyState)) "depositWithFee pre = True"
    }
  , { name := "credits recipient and pool actor"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 40) 1 99 5
        let s' := step_impl s (depositWithFee 1 10 99 7 3 0 11)
        assertEq (expected := (47 : Nat)) (actual := getBalance s' 1 10) "recipient"
        assertEq (expected := (8 : Nat))  (actual := getBalance s' 1 99) "pool"
    }
  , { name := "other resources untouched"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 40) 2 10 9
        let s' := step_impl s (depositWithFee 1 10 99 7 3 0 11)
        let _proof : s'.balances[(2 : ResourceId)]? = s.balances[(2 : ResourceId)]? :=
          depositWithFee_other_resource_untouched 1 2 10 99 7 3 0 11 s (by decide)
        assertEq (expected := (9 : Nat)) (actual := getBalance s' 2 10) "resource 2 untouched"
    }
  ]


end LegalKernel.Test.Laws.DepositWithFeeTests
