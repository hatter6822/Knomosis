-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.DistributeOthers — runtime tests for the
distributeOthers law.

Phase-4-prelude WU R.10 acceptance tests.  Drives `distributeOthers`'s
precondition decidability, value-level effect on a multi-actor
fixture, the `distributeOthers_excluded_unchanged` headline locality
property, the `totalSupply_after_distributeOthers` arithmetic equation,
the `distributeOthers_isMonotonic` instance, and the
`distributeOthers_not_conservative` negative witness.
-/

import LegalKernel.Laws.DistributeOthers
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.DistributeOthersTests

/-- Build a 3-actor fixture: actor 1 → 100, actor 2 → 200, actor 3 → 300
    at resource 1.  Total supply at r=1: 600. -/
def fixtureF1 : State :=
  setBalance (setBalance (setBalance emptyState 1 1 100) 1 2 200) 1 3 300

/-- Tests for the `distributeOthers` law. -/
def tests : List TestCase :=
  [ { name := "precondition: positive amount ⇒ true"
    , body := do
        let s := emptyState
        let t := distributeOthers 1 2 50
        assert (decide (t.pre s)) "distributeOthers with positive amount should accept"
    }
  , { name := "precondition: zero amount ⇒ false"
    , body := do
        let s := emptyState
        let t := distributeOthers 1 2 0
        assert (! decide (t.pre s)) "distributeOthers with zero amount should reject"
    }
  , { name := "F1 — actor 1 (non-excluded) gains amount"
    , body := do
        let s' := step_impl fixtureF1 (distributeOthers 1 2 50)
        assertEq (expected := (150 : Nat))
                 (actual   := getBalance s' 1 1)
                 "actor 1 in F1 after distributeOthers"
    }
  , { name := "F1 — actor 2 (excluded) is unchanged"
    , body := do
        let s' := step_impl fixtureF1 (distributeOthers 1 2 50)
        assertEq (expected := (200 : Nat))
                 (actual   := getBalance s' 1 2)
                 "actor 2 (excluded) in F1 after distributeOthers"
    }
  , { name := "F1 — actor 3 (non-excluded) gains amount"
    , body := do
        let s' := step_impl fixtureF1 (distributeOthers 1 2 50)
        assertEq (expected := (350 : Nat))
                 (actual   := getBalance s' 1 3)
                 "actor 3 in F1 after distributeOthers"
    }
  , { name := "F1 — total supply increases by amount * (n - 1) = 50 * 2 = 100"
    , body := do
        let s' := step_impl fixtureF1 (distributeOthers 1 2 50)
        assertEq (expected := (700 : Nat))
                 (actual   := TotalSupply s' 1)
                 "total supply at r=1 after F1 distributeOthers"
    }
  , { name := "Excluded actor absent from map: all current actors get amount"
    , body := do
        -- F1 has actors {1, 2, 3}.  Exclude actor 999 (absent).  All get +50.
        -- Supply: 600 → 750.
        let s' := step_impl fixtureF1 (distributeOthers 1 999 50)
        assertEq (expected := (150 : Nat)) (actual := getBalance s' 1 1) "actor 1"
        assertEq (expected := (250 : Nat)) (actual := getBalance s' 1 2) "actor 2"
        assertEq (expected := (350 : Nat)) (actual := getBalance s' 1 3) "actor 3"
        assertEq (expected := (750 : Nat)) (actual := TotalSupply s' 1) "supply"
    }
  , { name := "Empty BalanceMap: no-op (no actors to reward)"
    , body := do
        let s' := step_impl emptyState (distributeOthers 1 5 50)
        assertEq (expected := (0 : Nat))
                 (actual   := TotalSupply s' 1)
                 "empty resource yields zero supply unchanged"
    }
  , { name := "Single excluded actor: no-op (only actor is excluded)"
    , body := do
        -- {1 → 100} at r=1, excluded=1.  After: {1 → 100}.  Supply: 100 → 100.
        let s := setBalance emptyState 1 1 100
        let s' := step_impl s (distributeOthers 1 1 50)
        assertEq (expected := (100 : Nat))
                 (actual   := getBalance s' 1 1)
                 "excluded actor unchanged"
        assertEq (expected := (100 : Nat))
                 (actual   := TotalSupply s' 1)
                 "supply unchanged"
    }
  , { name := "Locality: distributeOthers at r=1 doesn't affect r=2"
    , body := do
        -- F1 with an extra balance at r=2.
        let s := setBalance fixtureF1 2 5 999
        let s' := step_impl s (distributeOthers 1 2 50)
        assertEq (expected := (999 : Nat))
                 (actual   := getBalance s' 2 5)
                 "actor 5's balance at r=2 unchanged"
    }
  , { name := "totalSupply_after_distributeOthers API stability"
    , body := do
        let s := fixtureF1
        let t := distributeOthers 1 2 50
        have hpre : t.pre s := by decide
        let _proof :
            TotalSupply (step_impl s t) 1 =
            TotalSupply s 1 +
              50 * ((s.balances[(1 : ResourceId)]?.getD ∅).toList.filter
                      (fun kv => kv.1 != 2)).length :=
          totalSupply_after_distributeOthers 1 2 50 s hpre
        pure ()
    }
  , { name := "distributeOthers_isMonotonic instance resolves"
    , body := do
        let _inst : IsMonotonic (distributeOthers 1 2 50) := inferInstance
        pure ()
    }
  , { name := "distributeOthers_not_conservative API stability"
    , body := do
        let _proof : ¬ IsConservative (distributeOthers 1 2 50) :=
          distributeOthers_not_conservative 1 2 50 (by decide)
        pure ()
    }
  , { name := "distributeOthers_excluded_unchanged API check"
    , body := do
        let s := fixtureF1
        let t := distributeOthers 1 2 50
        have hpre : t.pre s := by decide
        let _proof : getBalance (step_impl s t) 1 2 = getBalance s 1 2 :=
          distributeOthers_excluded_unchanged 1 2 50 s hpre
        assertEq (expected := getBalance s 1 2)
                 (actual   := getBalance (step_impl s t) 1 2)
                 "value-level: excluded actor's balance preserved"
    }
  ]

end LegalKernel.Test.Laws.DistributeOthersTests
