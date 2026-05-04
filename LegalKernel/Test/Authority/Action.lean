/-
LegalKernel.Test.Authority.Action — runtime tests for the Phase-3
Action layer.

Phase-3 WU 3.1 / 3.2.  Exercises:

  * The `Action` inductive's value-level semantics (smoke tests).
  * `Action.compile` produces the expected `Transition` values for
    each constructor.
  * `Action.compile_injective` is a one-line structural fact that
    elaborates without `sorry` (term-level API stability).
  * `CompiledAction.source` round-trips: `(Action.compile a).source
    = a` for every constructor.
  * The compiled transitions reach the kernel correctly (apply_impl
    behaviour matches the underlying law).
-/

import LegalKernel.Authority.Action
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.Authority.ActionTests

/-- Tests for the `Action` inductive and `Action.compile`. -/
def tests : List TestCase :=
  [ -- WU 3.1: Action constructors are value-level distinguishable.
    { name := "Action.transfer ≠ Action.mint (DecidableEq)"
    , body := do
        assert (! decide (Action.transfer 1 2 3 4 = Action.mint 1 2 4))
          "two distinct constructors should be unequal"
    }
  , { name := "Action.transfer with different params unequal"
    , body := do
        assert (! decide (Action.transfer 1 2 3 4 = Action.transfer 1 2 3 5))
          "transfer with different amount should be unequal"
    }
  , { name := "Action.replaceKey with different actor unequal"
    , body := do
        let k : PublicKey := ⟨#[0xAA, 0xBB]⟩
        assert (! decide (Action.replaceKey 1 k = Action.replaceKey 2 k))
          "replaceKey with different actor should be unequal"
    }
  -- WU 3.1: Action.compile produces the expected CompiledAction.
  , { name := "compile transfer produces transfer-shaped CompiledAction"
    , body := do
        let a : Action := .transfer 1 10 20 30
        let ca := Action.compile a
        -- source field is the originating action.
        assert (decide (ca.source = a)) "source matches input"
    }
  , { name := "compile mint produces mint-shaped CompiledAction"
    , body := do
        let a : Action := .mint 1 10 30
        let ca := Action.compile a
        assert (decide (ca.source = a)) "mint compile source"
    }
  , { name := "compile burn produces burn-shaped CompiledAction"
    , body := do
        let a : Action := .burn 1 10 30
        let ca := Action.compile a
        assert (decide (ca.source = a)) "burn compile source"
    }
  , { name := "compile freezeResource produces freeze-shaped CompiledAction"
    , body := do
        let a : Action := .freezeResource 5
        let ca := Action.compile a
        assert (decide (ca.source = a)) "freeze compile source"
    }
  , { name := "compile replaceKey produces replaceKey-shaped CompiledAction"
    , body := do
        let k : PublicKey := ⟨#[0xCA, 0xFE]⟩
        let a : Action := .replaceKey 7 k
        let ca := Action.compile a
        assert (decide (ca.source = a)) "replaceKey compile source"
    }

  -- WU 3.1: Compiled transition's apply_impl matches the underlying law.
  , { name := "compiled transfer's apply_impl moves the balance"
    , body := do
        let s := setBalance emptyState 1 10 100
        let ca := Action.compile (.transfer 1 10 20 30)
        let s' := ca.transition.apply_impl s
        assertEq (expected := 70) (actual := getBalance s' 1 10) "sender after"
        assertEq (expected := 30) (actual := getBalance s' 1 20) "receiver after"
    }
  , { name := "compiled mint's apply_impl credits the actor"
    , body := do
        let ca := Action.compile (.mint 1 10 30)
        let s' := ca.transition.apply_impl emptyState
        assertEq (expected := 30) (actual := getBalance s' 1 10) "minted"
    }
  , { name := "compiled burn's apply_impl debits the actor"
    , body := do
        let s := setBalance emptyState 1 10 100
        let ca := Action.compile (.burn 1 10 30)
        let s' := ca.transition.apply_impl s
        assertEq (expected := 70) (actual := getBalance s' 1 10) "burned"
    }
  , { name := "compiled freezeResource's apply_impl is identity on balances"
    , body := do
        let s := setBalance emptyState 1 10 100
        let ca := Action.compile (.freezeResource 1)
        let s' := ca.transition.apply_impl s
        assertEq (expected := 100) (actual := getBalance s' 1 10) "freeze noop"
    }
  , { name := "compiled replaceKey's apply_impl is identity on balances"
    , body := do
        let k : PublicKey := ⟨#[0x42]⟩
        let s := setBalance emptyState 1 10 100
        let ca := Action.compile (.replaceKey 7 k)
        let s' := ca.transition.apply_impl s
        assertEq (expected := 100) (actual := getBalance s' 1 10)
          "replaceKey noop on balances"
    }

  -- WU 3.2: Action.compile_injective term-level API stability.
  , { name := "Action.compile_injective elaborates as a Function.Injective"
    , body := do
        let _proof : Function.Injective Action.compile :=
          Action.compile_injective
        pure ()
    }

  -- WU 3.2: For specific action pairs, check compile injectivity.
  , { name := "compile_injective: transfer 1 = transfer 1 forces param equality"
    , body := do
        let a₁ : Action := .transfer 1 2 3 4
        let a₂ : Action := .transfer 1 2 3 4
        let ca₁ := Action.compile a₁
        let ca₂ := Action.compile a₂
        let _proof : ca₁ = ca₂ → a₁ = a₂ := fun h =>
          Action.compile_injective h
        assert (decide (a₁ = a₂)) "trivially equal"
    }
  , { name := "compile_injective: distinct actions ⇒ distinct CompiledActions"
    , body := do
        -- Term-level: we can construct a contrapositive witness.
        let a₁ : Action := .transfer 1 2 3 4
        let a₂ : Action := .mint 1 2 4
        -- The contrapositive of compile_injective: a₁ ≠ a₂ → compile a₁ ≠ compile a₂.
        let _proof : a₁ ≠ a₂ → Action.compile a₁ ≠ Action.compile a₂ := fun hne hca =>
          hne (Action.compile_injective hca)
        pure ()
    }

  -- Coverage: Action.pre and Action.apply_impl convenience accessors.
  , { name := "Action.pre transfer matches underlying law"
    , body := do
        let s := setBalance emptyState 1 10 100
        let a : Action := .transfer 1 10 20 30
        assert (decide (Action.pre a s)) "pre holds at funded state"
    }
  , { name := "Action.pre transfer fails at empty state"
    , body := do
        let a : Action := .transfer 1 10 20 30
        assert (! decide (Action.pre a emptyState)) "pre fails at empty"
    }
  , { name := "Action.apply_impl transfer matches step_impl on legal step"
    , body := do
        let s := setBalance emptyState 1 10 100
        let a : Action := .transfer 1 10 20 30
        let s' := Action.apply_impl a s
        assertEq (expected := 70) (actual := getBalance s' 1 10) "apply_impl"
    }
  ]

end LegalKernel.Test.Authority.ActionTests
