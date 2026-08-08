-- SPDX-License-Identifier: GPL-3.0-or-later
import LegalKernel.Laws.DepositWithFee
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.DepositWithFeeTests

/-- Tests for the GP.2 fee-split law, three-leg form (Workstream SB):
    recipient `+userAmount`, pool `+(poolAmount − seedAmount)`, reserve
    `+seedAmount`. -/
def tests : List TestCase :=
  [ { name := "precondition: bounded three-leg split admits"
    , body := do
        let t := depositWithFee 1 10 99 7 3 0 11 2 55
        assert (decide (t.pre emptyState)) "in-range split admits"
    }
  , { name := "precondition: over-seed split refused"
    , body := do
        -- `seedAmount = 4 > poolAmount = 3`: the third conjunct fails,
        -- so the split is refused rather than truncated.
        let t := depositWithFee 1 10 99 7 3 0 11 4 55
        assert (!decide (t.pre emptyState)) "seed > pool is refused"
    }
  , { name := "credits recipient, pool (net), and reserve"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 40) 1 99 5
        let s' := step_impl s (depositWithFee 1 10 99 7 3 0 11 2 55)
        assertEq (expected := (47 : Nat)) (actual := getBalance s' 1 10) "recipient +7"
        assertEq (expected := (6 : Nat))  (actual := getBalance s' 1 99) "pool +(3−2)"
        assertEq (expected := (2 : Nat))  (actual := getBalance s' 1 55) "reserve +2"
    }
  , { name := "zero seed: the pool keeps the whole fee"
    , body := do
        let s := setBalance emptyState 1 99 5
        let s' := step_impl s (depositWithFee 1 10 99 7 3 0 11 0 55)
        assertEq (expected := (8 : Nat)) (actual := getBalance s' 1 99) "pool +3"
        assertEq (expected := (0 : Nat)) (actual := getBalance s' 1 55) "reserve untouched"
    }
  , { name := "full seed: the whole fee reaches the reserve"
    , body := do
        let s' := step_impl emptyState (depositWithFee 1 10 99 7 3 0 11 3 55)
        assertEq (expected := (7 : Nat)) (actual := getBalance s' 1 10) "recipient +7"
        assertEq (expected := (0 : Nat)) (actual := getBalance s' 1 99) "pool +0"
        assertEq (expected := (3 : Nat)) (actual := getBalance s' 1 55) "reserve +3"
    }
  , { name := "pool = reserve coincidence: both legs land on one actor"
    , body := do
        -- The chained reads make the coinciding case exact: the net
        -- leg then the seed leg on the SAME actor sum back to the
        -- full fee.
        let s' := step_impl emptyState (depositWithFee 1 10 99 7 3 0 11 2 99)
        assertEq (expected := (3 : Nat)) (actual := getBalance s' 1 99)
          "net + seed = full fee"
    }
  , { name := "over-seed: the transition is a NO-OP, not a truncated write"
    , body := do
        let s := setBalance emptyState 1 10 40
        let s' := step_impl s (depositWithFee 1 10 99 7 3 0 11 4 55)
        assertEq (expected := (40 : Nat)) (actual := getBalance s' 1 10) "recipient unchanged"
        assertEq (expected := (0 : Nat))  (actual := getBalance s' 1 99) "pool unchanged"
        assertEq (expected := (0 : Nat))  (actual := getBalance s' 1 55) "reserve unchanged"
    }
  , { name := "other resources untouched"
    , body := do
        let s := setBalance (setBalance emptyState 1 10 40) 2 10 9
        let s' := step_impl s (depositWithFee 1 10 99 7 3 0 11 2 55)
        let _proof : s'.balances[(2 : ResourceId)]? = s.balances[(2 : ResourceId)]? :=
          depositWithFee_other_resource_untouched 1 2 10 99 7 3 0 11 2 55 s (by decide)
        assertEq (expected := (9 : Nat)) (actual := getBalance s' 2 10) "resource 2 untouched"
    }
  ]


end LegalKernel.Test.Laws.DepositWithFeeTests
