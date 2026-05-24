/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.ProportionalDilute — runtime tests for the
proportionalDilute law.

Phase-4-prelude WU R.16 acceptance tests.  Drives proportionalDilute
across the four canonical fixtures from the plan, asserting precise
post-balances (verifying floor-division semantics), the dust-discard
property (numerical spot-check of the bound that R.14 ships in its
weaker non-decreasing form), and the term-level API stability of all
new theorems.
-/

import LegalKernel.Laws.ProportionalDilute
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.ProportionalDiluteTests

/-- F1 fixture: 3-actor map at r=1: actor 1 → 30, actor 2 → 40, actor 3 → 50.
    Total supply at r=1: 120.  Used with excluded=2, totalReward=10.
    Expected post-state: actor 1 → 33, actor 2 → 40, actor 3 → 56;
    distributed = 3 + 6 = 9, dust = 1. -/
def fixtureF1 : State :=
  setBalance (setBalance (setBalance emptyState 1 1 30) 1 2 40) 1 3 50

/-- F2 fixture: 2-actor map; exact division (no dust). -/
def fixtureF2 : State :=
  setBalance (setBalance emptyState 1 1 10) 1 2 10

/-- F4 fixture: single actor, excluded absent from map. -/
def fixtureF4 : State :=
  setBalance emptyState 1 1 100

/-- Tests for the `proportionalDilute` law. -/
def tests : List TestCase :=
  [ { name := "precondition: F1 with totalReward > 0 and sumOthers > 0 ⇒ true"
    , body := do
        let t := proportionalDilute 1 2 10
        assert (decide (t.pre fixtureF1)) "F1 precondition should accept"
    }
  , { name := "precondition: totalReward = 0 ⇒ false"
    , body := do
        let t := proportionalDilute 1 2 0
        assert (! decide (t.pre fixtureF1)) "totalReward = 0 should reject"
    }
  , { name := "precondition: sumOthers = 0 ⇒ false"
    , body := do
        -- F3: only the excluded actor has any balance.
        let s := setBalance emptyState 1 2 100
        let t := proportionalDilute 1 2 10
        assert (! decide (t.pre s)) "sumOthers = 0 should reject"
    }
  , { name := "F1 — actor 1 balance after = 30 + 10*30/80 = 33"
    , body := do
        let s' := step_impl fixtureF1 (proportionalDilute 1 2 10)
        assertEq (expected := (33 : Nat))
                 (actual   := getBalance s' 1 1)
                 "actor 1 in F1"
    }
  , { name := "F1 — actor 2 (excluded) unchanged at 40"
    , body := do
        let s' := step_impl fixtureF1 (proportionalDilute 1 2 10)
        assertEq (expected := (40 : Nat))
                 (actual   := getBalance s' 1 2)
                 "actor 2 (excluded) unchanged"
    }
  , { name := "F1 — actor 3 balance after = 50 + 10*50/80 = 56"
    , body := do
        let s' := step_impl fixtureF1 (proportionalDilute 1 2 10)
        assertEq (expected := (56 : Nat))
                 (actual   := getBalance s' 1 3)
                 "actor 3 in F1"
    }
  , { name := "F1 — total supply = pre + distributed = 120 + 9 = 129 (dust=1 discarded)"
    , body := do
        let s' := step_impl fixtureF1 (proportionalDilute 1 2 10)
        assertEq (expected := (129 : Nat))
                 (actual   := TotalSupply s' 1)
                 "F1 supply after"
    }
  , { name := "F1 — dust-bound numerical check: distributed ≤ totalReward"
    , body := do
        let s' := step_impl fixtureF1 (proportionalDilute 1 2 10)
        let distributed := TotalSupply s' 1 - TotalSupply fixtureF1 1
        assert (decide (distributed ≤ 10))
          "distributed amount must be ≤ totalReward"
    }
  , { name := "F2 — exact division (no dust): actor 1 gets full 10"
    , body := do
        let s' := step_impl fixtureF2 (proportionalDilute 1 2 10)
        assertEq (expected := (20 : Nat))
                 (actual   := getBalance s' 1 1)
                 "actor 1 after F2"
        assertEq (expected := (10 : Nat))
                 (actual   := getBalance s' 1 2)
                 "actor 2 (excluded) unchanged in F2"
        assertEq (expected := (30 : Nat))
                 (actual   := TotalSupply s' 1)
                 "F2 supply: 20 + 10 = 30"
    }
  , { name := "F4 — excluded actor absent: only present actor gets full proportional share"
    , body := do
        let s' := step_impl fixtureF4 (proportionalDilute 1 999 10)
        assertEq (expected := (110 : Nat))
                 (actual   := getBalance s' 1 1)
                 "actor 1 in F4 after"
        assertEq (expected := (110 : Nat))
                 (actual   := TotalSupply s' 1)
                 "F4 supply: 100 + 10 = 110"
    }
  , { name := "Locality: proportionalDilute at r=1 doesn't affect r=2"
    , body := do
        let s := setBalance fixtureF1 2 5 999
        let s' := step_impl s (proportionalDilute 1 2 10)
        assertEq (expected := (999 : Nat))
                 (actual   := getBalance s' 2 5)
                 "balance at r=2 unchanged"
    }
  , { name := "totalSupply_after_proportionalDilute API stability"
    , body := do
        let s := fixtureF1
        let t := proportionalDilute 1 2 10
        have hpre : t.pre s := by decide
        let _proof :
            TotalSupply (step_impl s t) 1 = TotalSupply s 1 +
              ((s.balances[(1 : ResourceId)]?.getD ∅).toList.filter
                (fun kv => kv.1 != 2)
                |>.map (fun kv => 10 * kv.2 / sumOthers s 1 2)).sum :=
          totalSupply_after_proportionalDilute 1 2 10 s hpre
        pure ()
    }
  , { name := "proportionalDilute_supply_nondecreasing API stability"
    , body := do
        let s := fixtureF1
        let t := proportionalDilute 1 2 10
        have hpre : t.pre s := by decide
        let _proof : TotalSupply s 1 ≤ TotalSupply (step_impl s t) 1 :=
          proportionalDilute_supply_nondecreasing 1 2 10 s hpre
        pure ()
    }
  , { name := "proportionalDilute_distributed_le_totalReward API stability (dust bound)"
    , body := do
        let s := fixtureF1
        let t := proportionalDilute 1 2 10
        have hpre : t.pre s := by decide
        let _proof :
            TotalSupply (step_impl s t) 1 ≤ TotalSupply s 1 + 10 :=
          proportionalDilute_distributed_le_totalReward 1 2 10 s hpre
        pure ()
    }
  , { name := "proportionalDilute_isMonotonic instance resolves"
    , body := do
        let _inst : IsMonotonic (proportionalDilute 1 2 10) := inferInstance
        pure ()
    }
  , { name := "proportionalDilute_not_conservative API stability"
    , body := do
        let _proof : ¬ IsConservative (proportionalDilute 1 2 10) :=
          proportionalDilute_not_conservative 1 2 10 (by decide)
        pure ()
    }
  , { name := "proportionalDilute_excluded_unchanged API check"
    , body := do
        let s := fixtureF1
        let t := proportionalDilute 1 2 10
        have hpre : t.pre s := by decide
        let _proof : getBalance (step_impl s t) 1 2 = getBalance s 1 2 :=
          proportionalDilute_excluded_unchanged 1 2 10 s hpre
        assertEq (expected := getBalance s 1 2)
                 (actual   := getBalance (step_impl s t) 1 2)
                 "value-level: excluded actor preserved"
    }
  ]

end LegalKernel.Test.Laws.ProportionalDiluteTests
