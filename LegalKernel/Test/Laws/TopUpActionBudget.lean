import LegalKernel.Laws.TopUpActionBudget
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.TopUpActionBudgetTests

/-- Tests for the corresponding GP.2 law. -/
def tests : List TestCase :=
  [ { name := "precondition enforces sufficient balance"
    , body := do
        let s := setBalance emptyState 3 7 50
        let ok := topUpActionBudget 7 3 12 4 99
        let bad := topUpActionBudget 7 3 100 4 99
        assert (decide (ok.pre s)) "enough balance"
        assert (¬ decide (bad.pre s)) "insufficient balance"
    }
  , { name := "transfer leg debits signer, credits pool"
    , body := do
        let s := setBalance (setBalance emptyState 3 7 50) 3 99 20
        let s' := step_impl s (topUpActionBudget 7 3 12 4 99)
        assertEq (expected := (38 : Nat)) (actual := getBalance s' 3 7) "signer debited"
        assertEq (expected := (32 : Nat)) (actual := getBalance s' 3 99) "pool credited"
    }
  , { name := "insufficient-balance action is rejected by step_impl"
    , body := do
        let s := setBalance emptyState 3 7 50
        let s' := step_impl s (topUpActionBudget 7 3 100 4 99)
        assertEq (expected := getBalance s 3 7) (actual := getBalance s' 3 7) "signer unchanged"
        assertEq (expected := getBalance s 3 99) (actual := getBalance s' 3 99) "pool unchanged"
    }
  ]


end LegalKernel.Test.Laws.TopUpActionBudgetTests
