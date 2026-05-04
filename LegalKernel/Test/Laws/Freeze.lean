/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.Freeze — runtime tests for the freeze marker
and `FrozenForResource` invariant.

Phase 2 WU 2.9 acceptance tests.  Drives the four preservation lemmas
on representative state fixtures: that `freezeResource` itself is a
no-op, that mutating laws (`transfer`, `mint`, `burn`) preserve the
freeze when targeting a different resource, and (negatively) that
operating on the same resource breaks the freeze.
-/

import LegalKernel.Laws.Freeze
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.FreezeTests

/-- Fixture: state with a balance under resource 1 (frozen) and another
    under resource 2 (unfrozen).  Snapshot of resource 1's BalanceMap
    is taken pre-freeze and used as the FrozenForResource snapshot. -/
def baseState : State :=
  setBalance (setBalance emptyState 1 10 100) 2 10 200

/-- Tests for the freeze marker and `FrozenForResource` invariant. -/
def tests : List TestCase :=
  [ { name := "FrozenForResource holds reflexively at snapshot time"
    , body := do
        -- Snapshot equals the current per-resource BalanceMap; the
        -- invariant is `s.balances[r]? = snap`, which is `rfl`.
        let s := baseState
        let snap := s.balances[(1 : ResourceId)]?
        let _proof : FrozenForResource 1 snap s := rfl
        pure ()
    }
  , { name := "freezeResource preserves the freeze trivially"
    , body := do
        let s := baseState
        let snap := s.balances[(1 : ResourceId)]?
        have hI : FrozenForResource 1 snap s := rfl
        let _proof :
            FrozenForResource 1 snap (step_impl s (freezeResource 1)) :=
          freezeResource_preserves_freeze 1 1 snap s hI
        pure ()
    }
  , { name := "transfer at a different resource preserves the freeze"
    , body := do
        let s := baseState
        let snap := s.balances[(1 : ResourceId)]?
        have hI : FrozenForResource 1 snap s := rfl
        -- Transfer at resource 2 (unfrozen): freeze of resource 1 stands.
        let _proof :
            FrozenForResource 1 snap
              (step_impl s (transfer 2 10 99 50)) :=
          transfer_preserves_freeze 1 2 10 99 50 snap s
            (by decide) hI
        pure ()
    }
  , { name := "mint at a different resource preserves the freeze"
    , body := do
        let s := baseState
        let snap := s.balances[(1 : ResourceId)]?
        have hI : FrozenForResource 1 snap s := rfl
        let _proof :
            FrozenForResource 1 snap
              (step_impl s (mint 2 99 50)) :=
          mint_preserves_freeze 1 2 99 50 snap s
            (by decide) hI
        pure ()
    }
  , { name := "burn at a different resource preserves the freeze"
    , body := do
        let s := baseState
        let snap := s.balances[(1 : ResourceId)]?
        have hI : FrozenForResource 1 snap s := rfl
        let _proof :
            FrozenForResource 1 snap
              (step_impl s (burn 2 10 50)) :=
          burn_preserves_freeze 1 2 10 50 snap s
            (by decide) hI
        pure ()
    }
  , { name := "freeze invariant value-level: snapshot remains stable"
    , body := do
        -- Apply mint at resource 2; lookup at resource 1 should match
        -- the original BalanceMap.
        let s  := baseState
        let s' := step_impl s (mint 2 99 50)
        assertEq (expected := s.balances[(1 : ResourceId)]?)
                 (actual   := s'.balances[(1 : ResourceId)]?)
                 "resource 1 BalanceMap unchanged"
    }
  , { name := "freezeResource is identity on State (value-level)"
    , body := do
        -- `step_impl s (freezeResource r)` should agree with `s` on
        -- every accessor we can name.  Since State equality isn't
        -- decidable in general, check pointwise.
        let s  := baseState
        let s' := step_impl s (freezeResource 1)
        assertEq (expected := getBalance s 1 10)
                 (actual   := getBalance s' 1 10)
                 "balance preserved at (1, 10)"
        assertEq (expected := getBalance s 2 10)
                 (actual   := getBalance s' 2 10)
                 "balance preserved at (2, 10)"
        assertEq (expected := s.balances[(1 : ResourceId)]?)
                 (actual   := s'.balances[(1 : ResourceId)]?)
                 "BalanceMap at r=1 preserved"
    }
  -- Negative regression tests: mutating laws applied to the *frozen*
  -- resource genuinely change the per-actor balances at that resource.
  -- These witness the *necessity* of the disjointness hypothesis in
  -- the preservation lemmas: a future refactor that drops the
  -- hypothesis would silently pass the positive tests above but break
  -- these.  Uses `getBalance` (which returns `Nat`, `DecidableEq`) to
  -- side-step the lack of `DecidableEq` on `Option BalanceMap`.
  , { name := "mint at the FROZEN resource changes a balance"
    , body := do
        -- baseState has resource 1 holding `(10 ↦ 100)`; actor 99 has 0.
        let s   := baseState
        let s'  := step_impl s (mint 1 99 50)
        -- Pre-mint: actor 99 at r=1 is 0.  Post-mint: 50.  Different.
        assertEq (expected := (0  : Nat)) (actual := getBalance s  1 99) "pre"
        assertEq (expected := (50 : Nat)) (actual := getBalance s' 1 99) "post"
    }
  , { name := "burn at the FROZEN resource changes a balance"
    , body := do
        -- baseState has resource 1 holding `(10 ↦ 100)`.
        let s   := baseState
        let s'  := step_impl s (burn 1 10 30)
        assertEq (expected := (100 : Nat)) (actual := getBalance s  1 10) "pre"
        assertEq (expected := (70  : Nat)) (actual := getBalance s' 1 10) "post"
    }
  , { name := "transfer at the FROZEN resource changes balances"
    , body := do
        let s   := baseState
        let s'  := step_impl s (transfer 1 10 99 30)
        -- Sender's balance dropped from 100 to 70.
        assertEq (expected := (100 : Nat)) (actual := getBalance s  1 10) "sender pre"
        assertEq (expected := (70  : Nat)) (actual := getBalance s' 1 10) "sender post"
        -- Receiver's balance rose from 0 to 30.
        assertEq (expected := (0   : Nat)) (actual := getBalance s  1 99) "receiver pre"
        assertEq (expected := (30  : Nat)) (actual := getBalance s' 1 99) "receiver post"
    }
  -- Phase-4-prelude WU R.19: classification instance checks.
  , { name := "freezeResource_isConservative instance resolves"
    , body := do
        let _inst : IsConservative (freezeResource 1) := inferInstance
        pure ()
    }
  , { name := "freezeResource_isMonotonic instance resolves"
    , body := do
        let _inst : IsMonotonic (freezeResource 1) := inferInstance
        pure ()
    }
  ]

end LegalKernel.Test.Laws.FreezeTests
