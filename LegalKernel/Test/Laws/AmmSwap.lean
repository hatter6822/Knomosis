-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.AmmSwap — Workstream GP.11.4 acceptance tests.

Exercises the L2 AMM swap mirror law (`Laws.ammSwap`): precondition
semantics, the two-resource credit/debit shape on the reserve actor,
type-class instances (NOT conservative, NOT monotonic, local-to both
resources, freeze-preserving), and term-level API stability for all
headline theorems.
-/

import LegalKernel.Laws.AmmSwap
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.AmmSwapTests

/-- Tests for the `ammSwap` law. -/
def tests : List TestCase :=
  [ -- ## Precondition semantics
    { name := "precondition: holds when reserve has sufficient balance"
    , body := do
        let s := setBalance emptyState 1 3 1000
        let t := ammSwap 0 1 500 480 3
        assert (decide (t.pre s)) "pre holds with reserve balance 1000 >= amountOut 480"
    }
  , { name := "precondition: fails when reserve has insufficient balance"
    , body := do
        let s := setBalance emptyState 1 3 100
        let t := ammSwap 0 1 500 480 3
        assert (¬ decide (t.pre s)) "pre fails: 100 < 480"
    }
  , { name := "precondition: fails when fromResource = toResource"
    , body := do
        let s := setBalance emptyState 0 3 1000
        let t := ammSwap 0 0 500 480 3
        assert (¬ decide (t.pre s)) "pre fails: same resource"
    }
  , { name := "precondition: fails when amountIn = 0"
    , body := do
        let s := setBalance emptyState 1 3 1000
        let t := ammSwap 0 1 0 480 3
        assert (¬ decide (t.pre s)) "pre fails: zero input"
    }
  , { name := "precondition: holds at boundary (balance = amountOut)"
    , body := do
        let s := setBalance emptyState 1 3 480
        let t := ammSwap 0 1 500 480 3
        assert (decide (t.pre s)) "pre holds at exact boundary"
    }
  , { name := "decPre: inferInstance suffices"
    , body := do
        let t := ammSwap 0 1 500 480 3
        let _inst : (s : State) → Decidable (t.pre s) := t.decPre
        pure ()
    }
  , -- ## Apply semantics: credit fromResource, debit toResource
    { name := "apply: credits ammReserveActor at fromResource"
    , body := do
        let s := setBalance (setBalance emptyState 0 3 200) 1 3 1000
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        assertEq (expected := (700 : Nat)) (actual := getBalance s' 0 3)
          "fromResource balance = 200 + 500"
    }
  , { name := "apply: debits ammReserveActor at toResource"
    , body := do
        let s := setBalance (setBalance emptyState 0 3 200) 1 3 1000
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        assertEq (expected := (520 : Nat)) (actual := getBalance s' 1 3)
          "toResource balance = 1000 - 480"
    }
  , { name := "apply: zero-balance fromResource accumulates amountIn"
    , body := do
        let s := setBalance emptyState 1 3 1000
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        assertEq (expected := (500 : Nat)) (actual := getBalance s' 0 3)
          "fromResource starts at 0, becomes 500"
    }
  , { name := "apply: exact drain to zero at toResource"
    , body := do
        let s := setBalance emptyState 1 3 480
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        assertEq (expected := (0 : Nat)) (actual := getBalance s' 1 3)
          "toResource drained exactly to zero"
    }
  , { name := "apply: no-op when precondition fails (step_impl guard)"
    , body := do
        let s := setBalance emptyState 1 3 100
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        assertEq (expected := (100 : Nat)) (actual := getBalance s' 1 3)
          "state unchanged (insufficient balance)"
        assertEq (expected := (0 : Nat)) (actual := getBalance s' 0 3)
          "fromResource also unchanged"
    }
  , { name := "apply: other actors untouched"
    , body := do
        let s := setBalance (setBalance (setBalance emptyState 0 3 200) 1 3 1000) 0 7 999
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        assertEq (expected := (999 : Nat)) (actual := getBalance s' 0 7)
          "actor 7 at resource 0 untouched"
    }
  , { name := "apply: other resources on reserve actor untouched"
    , body := do
        let s := setBalance (setBalance (setBalance emptyState 0 3 200) 1 3 1000) 2 3 55
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        assertEq (expected := (55 : Nat)) (actual := getBalance s' 2 3)
          "resource 2 on reserve actor untouched"
    }
  , -- ## Theorem-backed: reserve-actor balance deltas
    { name := "ammSwap_increases_from_balance: fromResource gains amountIn"
    , body := do
        let s := setBalance (setBalance emptyState 0 3 200) 1 3 1000
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        have hpre : (ammSwap 0 1 500 480 3).pre s := by decide
        let _proof : getBalance s' 0 3 = getBalance s 0 3 + 500 :=
          ammSwap_increases_from_balance 0 1 500 480 3 s hpre
        assertEq (expected := (700 : Nat)) (actual := getBalance s' 0 3) "credited"
    }
  , { name := "ammSwap_decreases_to_balance: toResource loses amountOut"
    , body := do
        let s := setBalance (setBalance emptyState 0 3 200) 1 3 1000
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        have hpre : (ammSwap 0 1 500 480 3).pre s := by decide
        let _proof : getBalance s' 1 3 = getBalance s 1 3 - 480 :=
          ammSwap_decreases_to_balance 0 1 500 480 3 s hpre
        assertEq (expected := (520 : Nat)) (actual := getBalance s' 1 3) "debited"
    }
  , -- ## Theorem-backed: other-actor locality
    { name := "ammSwap_other_actor_untouched: non-reserve at fromResource"
    , body := do
        let s := setBalance (setBalance emptyState 0 7 999) 1 3 1000
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        have hpre : (ammSwap 0 1 500 480 3).pre s := by decide
        let _proof : getBalance s' 0 7 = getBalance s 0 7 :=
          ammSwap_other_actor_untouched 0 1 500 480 3 7 0 s hpre (by decide)
        assertEq (expected := (999 : Nat)) (actual := getBalance s' 0 7) "actor 7 from"
    }
  , { name := "ammSwap_other_actor_untouched: non-reserve at toResource"
    , body := do
        let s := setBalance (setBalance emptyState 1 7 888) 1 3 1000
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        have hpre : (ammSwap 0 1 500 480 3).pre s := by decide
        let _proof : getBalance s' 1 7 = getBalance s 1 7 :=
          ammSwap_other_actor_untouched 0 1 500 480 3 7 1 s hpre (by decide)
        assertEq (expected := (888 : Nat)) (actual := getBalance s' 1 7) "actor 7 to"
    }
  , -- ## Theorem-backed: cross-resource independence
    { name := "ammSwap_other_resource_untouched: BalanceMap at r' ∉ {from, to} preserved"
    , body := do
        let s := setBalance (setBalance (setBalance emptyState 0 3 200) 1 3 1000) 2 3 55
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        let _proof : s'.balances[(2 : ResourceId)]? = s.balances[(2 : ResourceId)]? :=
          ammSwap_other_resource_untouched 0 1 500 480 3 s (by decide) (by decide)
        assertEq (expected := (55 : Nat)) (actual := getBalance s' 2 3) "preserved"
    }
  , { name := "ammSwap_does_not_touch_other_resources: per-actor at r' ∉ {from, to}"
    , body := do
        let s := setBalance (setBalance (setBalance emptyState 0 3 200) 1 3 1000) 2 3 55
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        let _proof : getBalance s' 2 3 = getBalance s 2 3 :=
          ammSwap_does_not_touch_other_resources 0 1 500 480 3 2 3 s (by decide) (by decide)
        assertEq (expected := (55 : Nat)) (actual := getBalance s' 2 3) "per-actor preserved"
    }
  , { name := "ammSwap_conserves_other_resource: TotalSupply at r' ∉ {from, to}"
    , body := do
        let s := setBalance (setBalance (setBalance emptyState 0 3 200) 1 3 1000) 2 3 55
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        let _proof : TotalSupply s' 2 = TotalSupply s 2 :=
          ammSwap_conserves_other_resource 0 1 500 480 3 2 s (by decide) (by decide)
        assertEq (expected := TotalSupply s 2) (actual := TotalSupply s' 2) "supply preserved"
    }
  , -- ## Supply-change characterisation (non-conservation)
    { name := "ammSwap_fromResource_supply_increase: TS(from) increases by amountIn"
    , body := do
        let s := setBalance (setBalance emptyState 0 3 200) 1 3 1000
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        have hpre : (ammSwap 0 1 500 480 3).pre s := by decide
        let _proof : TotalSupply s' 0 = TotalSupply s 0 + 500 :=
          ammSwap_fromResource_supply_increase 0 1 500 480 3 s hpre
        pure ()
    }
  , { name := "ammSwap_toResource_supply_decrease: TS(to) + amountOut = TS(pre)"
    , body := do
        let s := setBalance (setBalance emptyState 0 3 200) 1 3 1000
        let s' := step_impl s (ammSwap 0 1 500 480 3)
        have hpre : (ammSwap 0 1 500 480 3).pre s := by decide
        let _proof : TotalSupply s' 1 + 480 = TotalSupply s 1 :=
          ammSwap_toResource_supply_decrease 0 1 500 480 3 s hpre
        pure ()
    }
  , { name := "ammSwap is NOT conservative (supply changes at fromResource)"
    , body := do
        let s := setBalance emptyState 1 3 1000
        have hpre : (ammSwap 0 1 500 480 3).pre s := by decide
        let _proof : TotalSupply (step_impl s (ammSwap 0 1 500 480 3)) 0 ≠
                     TotalSupply s 0 :=
          ammSwap_not_conservative_at_from 0 1 500 480 3 s hpre (by decide)
        pure ()
    }
  , { name := "ammSwap is NOT monotonic (supply decreases at toResource)"
    , body := do
        let s := setBalance emptyState 1 3 1000
        have hpre : (ammSwap 0 1 500 480 3).pre s := by decide
        let _proof : TotalSupply (step_impl s (ammSwap 0 1 500 480 3)) 1 <
                     TotalSupply s 1 :=
          ammSwap_not_monotonic_at_to 0 1 500 480 3 s hpre (by decide)
        pure ()
    }
  , -- ## Classification instances
    { name := "LocalTo [fromResource, toResource] instance"
    , body := do
        let _inst : LocalTo [0, 1] (ammSwap 0 1 500 480 3) :=
          inferInstance
        pure ()
    }
  , { name := "FreezePreserving [] instance"
    , body := do
        let _inst : FreezePreserving [] (ammSwap 0 1 500 480 3) :=
          inferInstance
        pure ()
    }
  , -- ## Reversed direction (BOLD→ETH)
    { name := "apply: reversed direction (resource 1 → resource 0)"
    , body := do
        let s := setBalance (setBalance emptyState 0 3 1000) 1 3 500
        let s' := step_impl s (ammSwap 1 0 200 180 3)
        assertEq (expected := (700 : Nat)) (actual := getBalance s' 1 3)
          "fromResource 1 credited: 500 + 200"
        assertEq (expected := (820 : Nat)) (actual := getBalance s' 0 3)
          "toResource 0 debited: 1000 - 180"
    }
  , -- ## Edge cases
    { name := "apply: amountOut = 1 (minimum non-zero output)"
    , body := do
        let s := setBalance emptyState 1 3 1
        let s' := step_impl s (ammSwap 0 1 1 1 3)
        assertEq (expected := (0 : Nat)) (actual := getBalance s' 1 3) "drained 1"
        assertEq (expected := (1 : Nat)) (actual := getBalance s' 0 3) "credited 1"
    }
  , { name := "apply: large values (near u64 max)"
    , body := do
        let big := 18446744073709551615
        let s := setBalance (setBalance emptyState 0 3 big) 1 3 big
        let s' := step_impl s (ammSwap 0 1 1000 999 3)
        assertEq (expected := big + 1000) (actual := getBalance s' 0 3) "big credit"
        assertEq (expected := big - 999) (actual := getBalance s' 1 3) "big debit"
    }
  , { name := "apply: amountIn = 1 (minimum non-zero input)"
    , body := do
        let s := setBalance emptyState 1 3 100
        let s' := step_impl s (ammSwap 0 1 1 1 3)
        assertEq (expected := (1 : Nat)) (actual := getBalance s' 0 3) "credit 1"
        assertEq (expected := (99 : Nat)) (actual := getBalance s' 1 3) "debit 1"
    }
  , -- ## Term-level API stability for headline theorems
    { name := "ammSwap_increases_from_balance term-level API"
    , body := do
        let _f : (fromResource toResource : ResourceId) →
                 (amountIn amountOut : Amount) → (ammReserveActor : ActorId) →
                 (s : State) →
                 (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s →
                 getBalance (step_impl s (ammSwap fromResource toResource amountIn amountOut
                   ammReserveActor)) fromResource ammReserveActor =
                 getBalance s fromResource ammReserveActor + amountIn :=
          ammSwap_increases_from_balance
        pure ()
    }
  , { name := "ammSwap_decreases_to_balance term-level API"
    , body := do
        let _f : (fromResource toResource : ResourceId) →
                 (amountIn amountOut : Amount) → (ammReserveActor : ActorId) →
                 (s : State) →
                 (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s →
                 getBalance (step_impl s (ammSwap fromResource toResource amountIn amountOut
                   ammReserveActor)) toResource ammReserveActor =
                 getBalance s toResource ammReserveActor - amountOut :=
          ammSwap_decreases_to_balance
        pure ()
    }
  , { name := "ammSwap_other_actor_untouched term-level API"
    , body := do
        let _f : (fromResource toResource : ResourceId) →
                 (amountIn amountOut : Amount) →
                 (ammReserveActor : ActorId) → (other : ActorId) →
                 (r : ResourceId) → (s : State) →
                 (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s →
                 other ≠ ammReserveActor →
                 getBalance (step_impl s (ammSwap fromResource toResource amountIn amountOut
                   ammReserveActor)) r other =
                 getBalance s r other :=
          ammSwap_other_actor_untouched
        pure ()
    }
  , { name := "ammSwap_other_resource_untouched term-level API"
    , body := do
        let _f : (fromResource toResource : ResourceId) →
                 (amountIn amountOut : Amount) →
                 (ammReserveActor : ActorId) → (s : State) →
                 {r' : ResourceId} →
                 fromResource ≠ r' → toResource ≠ r' →
                 (step_impl s (ammSwap fromResource toResource amountIn amountOut
                   ammReserveActor)).balances[r']? = s.balances[r']? :=
          ammSwap_other_resource_untouched
        pure ()
    }
  , { name := "ammSwap_does_not_touch_other_resources term-level API"
    , body := do
        let _f : (fromResource toResource : ResourceId) →
                 (amountIn amountOut : Amount) →
                 (ammReserveActor : ActorId) → (r' : ResourceId) →
                 (a : ActorId) → (s : State) →
                 fromResource ≠ r' → toResource ≠ r' →
                 getBalance (step_impl s (ammSwap fromResource toResource amountIn amountOut
                   ammReserveActor)) r' a =
                 getBalance s r' a :=
          ammSwap_does_not_touch_other_resources
        pure ()
    }
  , { name := "ammSwap_conserves_other_resource term-level API"
    , body := do
        let _f : (fromResource toResource : ResourceId) →
                 (amountIn amountOut : Amount) →
                 (ammReserveActor : ActorId) → (r' : ResourceId) →
                 (s : State) →
                 fromResource ≠ r' → toResource ≠ r' →
                 TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
                   ammReserveActor)) r' =
                 TotalSupply s r' :=
          ammSwap_conserves_other_resource
        pure ()
    }
  , { name := "ammSwap_fromResource_supply_increase term-level API"
    , body := do
        let _f : (fromResource toResource : ResourceId) →
                 (amountIn amountOut : Amount) → (ammReserveActor : ActorId) →
                 (s : State) →
                 (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s →
                 TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
                   ammReserveActor)) fromResource =
                 TotalSupply s fromResource + amountIn :=
          ammSwap_fromResource_supply_increase
        pure ()
    }
  , { name := "ammSwap_toResource_supply_decrease term-level API"
    , body := do
        let _f : (fromResource toResource : ResourceId) →
                 (amountIn amountOut : Amount) → (ammReserveActor : ActorId) →
                 (s : State) →
                 (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s →
                 TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
                   ammReserveActor)) toResource + amountOut =
                 TotalSupply s toResource :=
          ammSwap_toResource_supply_decrease
        pure ()
    }
  , { name := "ammSwap_not_conservative_at_from term-level API"
    , body := do
        let _f : (fromResource toResource : ResourceId) →
                 (amountIn amountOut : Amount) → (ammReserveActor : ActorId) →
                 (s : State) →
                 (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s →
                 amountIn > 0 →
                 TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
                   ammReserveActor)) fromResource ≠
                 TotalSupply s fromResource :=
          ammSwap_not_conservative_at_from
        pure ()
    }
  , { name := "ammSwap_not_monotonic_at_to term-level API"
    , body := do
        let _f : (fromResource toResource : ResourceId) →
                 (amountIn amountOut : Amount) → (ammReserveActor : ActorId) →
                 (s : State) →
                 (ammSwap fromResource toResource amountIn amountOut ammReserveActor).pre s →
                 amountOut > 0 →
                 TotalSupply (step_impl s (ammSwap fromResource toResource amountIn amountOut
                   ammReserveActor)) toResource <
                 TotalSupply s toResource :=
          ammSwap_not_monotonic_at_to
        pure ()
    }
  ]

end LegalKernel.Test.Laws.AmmSwapTests
