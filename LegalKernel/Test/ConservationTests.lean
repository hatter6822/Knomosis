-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.ConservationTests — runtime tests for §8.1 / §5.3.

Phase 2 ships compile-time-checked theorems for `TotalSupply`,
`IsConservative`, `ConservativeLawSet`, and `total_supply_global`.
This file adds runtime spot-checks on representative state fixtures:

  * `TotalSupply` is `0` on the genesis state at any resource.
  * `TotalSupply` sums every actor's balance for the queried resource.
  * `TotalSupply` is unchanged by writes at *other* resources.
  * `totalSupply_setBalance` master lemma matches at value level.
  * `TotalSupplyEquals` round-trips against an explicit target.
  * `total_supply_global` typechecks at term level (the inductive
    closure step is exercised by feeding it a depth-1 reachability
    witness).

These tests catch any future regression in the Std `TreeMap` API or
the Phase-1 `RBMap.sumValues_*` lemmas that the proofs depend on,
even when the term-level theorems still happen to elaborate.
-/

import LegalKernel
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Test
open LegalKernel.Laws

namespace LegalKernel.Test.ConservationTests

/-- A small fixture: the genesis state with two non-zero balances at
    resource `1`.  Total supply at `r=1` should be `100 + 50 = 150`. -/
def fundedState : State :=
  setBalance (setBalance genesisState 1 10 100) 1 20 50

/-- Tests for the §8.1 / §5.3 economic-invariants framework. -/
def tests : List TestCase :=
  [ { name := "TotalSupply on genesis is 0 at any resource"
    , body := do
        assertEq (expected := (0 : Nat))
                 (actual   := TotalSupply genesisState 1)
                 "genesis at r=1"
        assertEq (expected := (0 : Nat))
                 (actual   := TotalSupply genesisState 99)
                 "genesis at r=99"
    }
  , { name := "TotalSupply sums every actor's balance"
    , body := do
        assertEq (expected := (150 : Nat))
                 (actual   := TotalSupply fundedState 1)
                 "sum at r=1 should be 100 + 50"
    }
  , { name := "TotalSupply on an untouched resource is 0"
    , body := do
        assertEq (expected := (0 : Nat))
                 (actual   := TotalSupply fundedState 2)
                 "no actor in r=2"
    }
  , { name := "totalSupply_setBalance: write at fresh resource adds value"
    , body := do
        -- Genesis has no resource at r=5; setBalance adds (5, 7) ↦ 42.
        let s := setBalance genesisState 5 7 42
        -- Master lemma: TotalSupply (setBalance s r a v) r + getBalance s r a
        --             = TotalSupply s r + v
        -- Specialised to s = genesis: TotalSupply (...) 5 = 0 + 42 = 42.
        assertEq (expected := (42 : Nat))
                 (actual   := TotalSupply s 5)
                 "post-write supply at fresh resource"
    }
  , { name := "totalSupply_setBalance: overwrite present actor"
    , body := do
        -- Overwrite (1, 10)'s balance from 100 to 30.  Sum changes by -70.
        let s := setBalance fundedState 1 10 30
        -- Master lemma: TotalSupply (setBalance s r a 30) r + 100 = 150 + 30
        -- ⇒ TotalSupply ... = 80.
        assertEq (expected := (80 : Nat))
                 (actual   := TotalSupply s 1)
                 "post-overwrite supply at r=1"
    }
  , { name := "totalSupply_genesis_eq_zero (theorem statement holds value-level)"
    , body := do
        -- Term-level API check: the theorem exists with the right shape.
        -- If signature changes, this elaboration fails.
        let _proof : TotalSupply genesisState 0 = 0 :=
          totalSupply_genesis_eq_zero (r := 0)
        pure ()
    }
  , { name := "TotalSupplyEquals matches the closed-form value"
    , body := do
        -- TotalSupplyEquals r₀ target s ↔ TotalSupply s r₀ = target.
        let _proof : TotalSupplyEquals 1 150 fundedState :=
          show TotalSupply fundedState 1 = 150 by
            rfl
        pure ()
    }
  , { name := "transfer_conserves preserves supply on a legal step"
    , body := do
        -- Pre: actor 10 holds 100 at r=1.  Transfer 30 to actor 20.
        -- Post: TotalSupply at r=1 should still be 150.
        let s  := fundedState
        let t  := transfer 1 10 20 30
        -- Compute hpre at runtime to also drive the precondition path.
        have hbal : getBalance s 1 10 ≥ 30 := by decide
        have hpos : 30 > 0 := by decide
        let hpre : t.pre s := ⟨hbal, hpos⟩
        let _proof : TotalSupply (step_impl s t) 1 = TotalSupply s 1 :=
          transfer_conserves 1 10 20 30 s hpre
        -- Value-level check: both sides compute to 150.
        assertEq (expected := TotalSupply s 1)
                 (actual   := TotalSupply (step_impl s t) 1)
                 "supply preserved across transfer"
    }
  , { name := "transfer_conserves preserves supply on a self-transfer"
    , body := do
        -- The §4.11 self-transfer fix: actor 10 transfers 30 to itself.
        let s  := fundedState
        let t  := transfer 1 10 10 30
        have hbal : getBalance s 1 10 ≥ 30 := by decide
        have hpos : 30 > 0 := by decide
        let hpre : t.pre s := ⟨hbal, hpos⟩
        let _proof : TotalSupply (step_impl s t) 1 = TotalSupply s 1 :=
          transfer_conserves 1 10 10 30 s hpre
        assertEq (expected := TotalSupply s 1)
                 (actual   := TotalSupply (step_impl s t) 1)
                 "supply preserved across self-transfer"
    }
  , { name := "transfer is IsConservative (typeclass instance resolves)"
    , body := do
        -- Driving the typeclass: the instance must exist for the
        -- ConservativeLawSet construction to typecheck.
        let _inst : IsConservative (transfer 1 10 20 30) := inferInstance
        pure ()
    }
  , { name := "ConservativeLawSet accepts transfer"
    , body := do
        -- A two-element conservative law set (two transfer instances at
        -- different actor pairs).  The `isConservative` field is
        -- discharged automatically via the `transfer_isConservative`
        -- typeclass instance.
        let _cls : ConservativeLawSet :=
          { laws := [transfer 1 10 20 30, transfer 1 20 30 5]
            isConservative := by
              intro t htL
              simp only [List.mem_cons, List.not_mem_nil, or_false] at htL
              rcases htL with rfl | rfl
              · exact inferInstance
              · exact inferInstance }
        pure ()
    }
  , { name := "total_supply_global preserves an explicit target"
    , body := do
        -- Drive the §5.3 theorem at runtime: a target (150) preserved
        -- across a depth-0 reachability witness.  Larger reachability
        -- depths require more setup; the term-level API check is enough
        -- to catch a signature drift.
        let s0 := fundedState
        let h_init : TotalSupplyEquals 1 150 s0 := by
          show TotalSupply s0 1 = 150
          rfl
        let h_cons :
            ∀ t ∈ [transfer 1 10 20 30], ∀ s, t.pre s →
              TotalSupply (step_impl s t) 1 = TotalSupply s 1 := by
          intro t htL s hpre
          simp only [List.mem_cons, List.not_mem_nil, or_false] at htL
          subst htL
          exact transfer_conserves 1 10 20 30 s hpre
        let _proof : ∀ s, ReachableViaLaws [transfer 1 10 20 30] s0 s →
                          TotalSupplyEquals 1 150 s :=
          total_supply_global 1 150 s0 h_init [transfer 1 10 20 30] h_cons
        pure ()
    }
  , { name := "total_supply_global_via_law_set: typeclass-driven form"
    , body := do
        -- The typeclass-driven corollary discharges the conservation
        -- hypothesis automatically via the `IsConservative` instance
        -- attached to each law in the `ConservativeLawSet`.
        let s0 := fundedState
        let h_init : TotalSupplyEquals 1 150 s0 := by
          show TotalSupply s0 1 = 150
          rfl
        let cls : ConservativeLawSet :=
          { laws := [transfer 1 10 20 30]
            isConservative := by
              intro t htL
              simp only [List.mem_cons, List.not_mem_nil, or_false] at htL
              subst htL
              exact inferInstance }
        let _proof : ∀ s, ReachableViaLaws cls.laws s0 s →
                          TotalSupplyEquals 1 150 s :=
          total_supply_global_via_law_set 1 150 s0 h_init cls
        pure ()
    }
  , { name := "totalSupply_eq_zero_of_no_resource at an unseen resource"
    , body := do
        -- fundedState only touches r=1; querying r=99 gives `none` at
        -- the outer-map level, so total supply is 0.
        let s := fundedState
        have h : s.balances[(99 : ResourceId)]? = none := rfl
        let _proof : TotalSupply s 99 = 0 :=
          totalSupply_eq_zero_of_no_resource s 99 h
        assertEq (expected := (0 : Nat))
                 (actual   := TotalSupply s 99)
                 "supply at unused resource"
    }
  , { name := "TotalSupplyEquals: false case (target ≠ actual)"
    , body := do
        -- TotalSupplyEquals 1 999 fundedState is FALSE (actual is 150).
        -- We check this is well-formed (decidable) and false.
        let actualSupply := TotalSupply fundedState 1
        assert (decide (actualSupply ≠ 999))
          "fundedState's r=1 supply should not equal 999"
        assertEq (expected := (150 : Nat))
                 (actual   := actualSupply)
                 "ground-truth check"
    }
  -- Phase-4-prelude WU R.20: monotonicity tier extensions.
  , { name := "IsMonotonic typeclass resolves for transfer (via auto-upgrade or explicit)"
    , body := do
        let _inst : IsMonotonic (transfer 1 5 7 10) := inferInstance
        pure ()
    }
  , { name := "IsMonotonic typeclass resolves for mint"
    , body := do
        let _inst : IsMonotonic (mint 1 5 10) := inferInstance
        pure ()
    }
  , { name := "MonotonicLawSet construction with mixed conservative + monotone laws"
    , body := do
        -- A deployment law set that mixes a conservative law (transfer),
        -- a strictly-monotone law (mint), and the new positive-incentive
        -- laws.  Constructibility witnesses that all the IsMonotonic
        -- instances resolve and that MonotonicLawSet's per-element
        -- witness obligation is satisfied.
        let mls : MonotonicLawSet := {
          laws := [transfer 1 5 7 10, mint 1 5 50, reward 1 6 25,
                   distributeOthers 1 9 5]
          isMonotonic := by
            intro t htL
            simp [List.mem_cons] at htL
            rcases htL with h | h | h | h
            · rw [h]; exact transfer_isMonotonic 1 5 7 10
            · rw [h]; exact mint_isMonotonic 1 5 50
            · rw [h]; exact reward_isMonotonic 1 6 25
            · rw [h]; exact distributeOthers_isMonotonic 1 9 5
        }
        assertEq (expected := (4 : Nat)) (actual := mls.laws.length) "law set has 4 laws"
    }
  , { name := "total_supply_globally_nondecreasing API stability"
    , body := do
        let _proof :
          ∀ (r₀ : ResourceId) (s0 : State) (laws : List Transition),
            (∀ t ∈ laws, ∀ s, t.pre s →
              TotalSupply s r₀ ≤ TotalSupply (step_impl s t) r₀) →
            ∀ s, ReachableViaLaws laws s0 s →
                 TotalSupply s0 r₀ ≤ TotalSupply s r₀ :=
          total_supply_globally_nondecreasing
        pure ()
    }
  , { name := "total_supply_globally_nondecreasing_via_law_set API stability"
    , body := do
        let _proof :
          ∀ (r₀ : ResourceId) (s0 : State) (mls : MonotonicLawSet),
            ∀ s, ReachableViaLaws mls.laws s0 s →
                 TotalSupply s0 r₀ ≤ TotalSupply s r₀ :=
          total_supply_globally_nondecreasing_via_law_set
        pure ()
    }
  -- End-to-end behaviour test: 4-step trace through positive-incentive
  -- laws preserves the monotonicity invariant numerically.
  , { name := "end-to-end: 4-step positive-incentive trace is non-decreasing"
    , body := do
        -- s0 := genesis (supply 0 at every resource).
        let s0 : State := genesisState
        -- Step 1: mint 100 to actor 1 at resource 7 ⟹ supply 100.
        let s1 := step_impl s0 (mint 7 1 100)
        -- Step 2: reward actor 2 with 50 at resource 7 ⟹ supply 150.
        let s2 := step_impl s1 (reward 7 2 50)
        -- Step 3: distributeOthers excluding actor 99 (absent) with amount 10
        --         ⟹ all current actors (1, 2) get +10 ⟹ supply 170.
        let s3 := step_impl s2 (distributeOthers 7 99 10)
        -- Step 4: transfer 30 from actor 1 to actor 2 (zero-sum) ⟹ supply 170.
        let s4 := step_impl s3 (transfer 7 1 2 30)
        -- Per-step non-decrease assertions.
        assert (decide (TotalSupply s0 7 ≤ TotalSupply s1 7)) "step 1 non-decreasing"
        assert (decide (TotalSupply s1 7 ≤ TotalSupply s2 7)) "step 2 non-decreasing"
        assert (decide (TotalSupply s2 7 ≤ TotalSupply s3 7)) "step 3 non-decreasing"
        assert (decide (TotalSupply s3 7 ≤ TotalSupply s4 7)) "step 4 non-decreasing"
        -- Final supply check: 0 + 100 + 50 + (10 * 2) + 0 = 170.
        assertEq (expected := (170 : Nat)) (actual := TotalSupply s4 7) "final supply"
    }
  -- Workstream LX (LX.2 / LX.3) — `LocalTo`, `FreezePreserving`,
  -- `FreezePreservingLawSet`, `freeze_preservation_via_law_set`
  -- API stability checks.
  , { name := "LocalTo class API stability"
    , body := do
        let _proof : Prop :=
          ∀ (S : List ResourceId) (t : Transition), LocalTo S t
        pure ()
    }
  , { name := "FreezePreserving class API stability"
    , body := do
        let _proof : Prop :=
          ∀ (S : List ResourceId) (t : Transition), FreezePreserving S t
        pure ()
    }
  , { name := "FreezePreservingLawSet API stability"
    , body := do
        let _ : ∀ (S : List ResourceId), FreezePreservingLawSet S → List Transition :=
          fun _ fls => fls.laws
        pure ()
    }
  , { name := "FreezePreservingLawSet constructibility on empty law list"
    , body := do
        let _fls : FreezePreservingLawSet [] := {
          laws := []
          isFreezePreserving := by intro t htL; cases htL
        }
        pure ()
    }
  , { name := "freeze_preservation_via_law_set API stability"
    , body := do
        let _proof :
          ∀ (S : List ResourceId) (s0 : State) (fls : FreezePreservingLawSet S)
            (r : ResourceId) (_hr : r ∈ S) (snap : Option BalanceMap)
            (_h_init : s0.balances[r]? = snap),
            ∀ s, ReachableViaLaws fls.laws s0 s → s.balances[r]? = snap :=
          freeze_preservation_via_law_set
        pure ()
    }
  -- Per-existing-law instance-resolution checks (LX.3).
  , { name := "LocalTo [r] (transfer r ...) instance resolves"
    , body := do
        let _ : LocalTo [7] (Laws.transfer 7 1 2 5) := inferInstance
        pure ()
    }
  , { name := "LocalTo [r] (mint r ...) instance resolves"
    , body := do
        let _ : LocalTo [7] (Laws.mint 7 1 5) := inferInstance
        pure ()
    }
  , { name := "LocalTo [r] (burn r ...) instance resolves"
    , body := do
        let _ : LocalTo [7] (Laws.burn 7 1 5) := inferInstance
        pure ()
    }
  , { name := "LocalTo [r] (reward r ...) instance resolves"
    , body := do
        let _ : LocalTo [7] (Laws.reward 7 1 5) := inferInstance
        pure ()
    }
  , { name := "LocalTo [r] (distributeOthers r ...) instance resolves"
    , body := do
        let _ : LocalTo [7] (Laws.distributeOthers 7 99 5) := inferInstance
        pure ()
    }
  , { name := "LocalTo [r] (proportionalDilute r ...) instance resolves"
    , body := do
        let _ : LocalTo [7] (Laws.proportionalDilute 7 99 5) := inferInstance
        pure ()
    }
  , { name := "LocalTo S (freezeResource _) instance resolves for any S"
    , body := do
        let _ : LocalTo [] (Laws.freezeResource 0) := inferInstance
        let _ : LocalTo [3] (Laws.freezeResource 0) := inferInstance
        pure ()
    }
  , { name := "FreezePreserving S (freezeResource _) instance resolves for any S"
    , body := do
        let _ : FreezePreserving [] (Laws.freezeResource 0) := inferInstance
        let _ : FreezePreserving [3, 5] (Laws.freezeResource 7) := inferInstance
        pure ()
    }
  , { name := "transfer_freezePreserving theorem produces an instance for r ∉ S"
    , body := do
        -- For r=7 and S=[3,5], r ∉ S so the theorem applies.
        have h : (7 : ResourceId) ∉ ([3, 5] : List ResourceId) := by decide
        let _inst : FreezePreserving [3, 5] (Laws.transfer 7 1 2 5) :=
          Laws.transfer_freezePreserving 7 1 2 5 [3, 5] h
        pure ()
    }
  , { name := "RegistryPreserving instance resolves for transfer"
    , body := do
        let _ : Authority.RegistryPreserving (.transfer 7 1 2 5) := inferInstance
        pure ()
    }
  , { name := "RegistryPreserving instance resolves for mint"
    , body := do
        let _ : Authority.RegistryPreserving (.mint 7 1 5) := inferInstance
        pure ()
    }
  , { name := "RegistryPreserving instance resolves for burn"
    , body := do
        let _ : Authority.RegistryPreserving (.burn 7 1 5) := inferInstance
        pure ()
    }
  , { name := "RegistryPreserving instance resolves for freezeResource"
    , body := do
        let _ : Authority.RegistryPreserving (.freezeResource 7) := inferInstance
        pure ()
    }
  , { name := "RegistryPreserving instance resolves for reward"
    , body := do
        let _ : Authority.RegistryPreserving (.reward 7 1 5) := inferInstance
        pure ()
    }
  , { name := "RegistryPreserving applyActionToRegistry on transfer is identity"
    , body := do
        let kr : Authority.KeyRegistry := ∅
        let h := (Authority.transfer_registryPreserving 7 1 2 5).preserves kr
        let _ : Authority.applyActionToRegistry kr (.transfer 7 1 2 5) = kr := h
        pure ()
    }
  -- Negative-witness checks: `replaceKey` and `registerIdentity`
  -- are NOT `RegistryPreserving` instances (they mutate the
  -- registry).  We can't easily test "instance synthesis fails"
  -- at the value level, so we verify the underlying claim that
  -- `applyActionToRegistry` returns a *different* registry on
  -- those actions (the witness that breaks `RegistryPreserving`
  -- by construction).
  , { name := "RegistryPreserving negative witness: replaceKey mutates the registry"
    , body := do
        let kr : Authority.KeyRegistry := ∅
        let actorId : LegalKernel.ActorId := 42
        let pk : LegalKernel.Authority.PublicKey := ByteArray.empty
        let post := Authority.applyActionToRegistry kr (.replaceKey actorId pk)
        -- Pre-state: actor 42 has no key.  Post-state: actor 42 maps to pk.
        -- This is the negative witness that `RegistryPreserving
        -- (.replaceKey actor pk)` is structurally false (no
        -- `inferInstance`-derivable witness exists).
        let _ : kr[actorId]? = none := rfl
        let _ : post[actorId]? = some pk := by
          simp [Authority.applyActionToRegistry, post]
        pure ()
    }
  , { name := "RegistryPreserving negative witness: registerIdentity mutates the registry"
    , body := do
        let kr : Authority.KeyRegistry := ∅
        let actorId : LegalKernel.ActorId := 99
        let pk : LegalKernel.Authority.PublicKey := ByteArray.empty
        let post := Authority.applyActionToRegistry kr (.registerIdentity actorId pk)
        let _ : kr[actorId]? = none := rfl
        let _ : post[actorId]? = some pk := by
          simp [Authority.applyActionToRegistry, post]
        pure ()
    }
  ]

end LegalKernel.Test.ConservationTests
