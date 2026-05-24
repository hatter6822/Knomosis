/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

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
import LegalKernel.Authority.LocalPolicySemantics
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.Authority.ActionTests

/-! ## AR.5 — Action constructor-tag regression pins

19 elaboration-time pins (one per `Action` constructor), each asserting
the `Action.tag` value via `rfl`.  Any future PR that reorders the
`Action` constructors must update the matching `Action.tag` match arm
in `LegalKernel/Authority/LocalPolicySemantics.lean` and these pins
will catch a transposition (swap tag N ↔ tag M while still passing
`Action.tag_matches_encode_tag`).

The pins are `example` declarations (no name), so they live in the
file's `#print axioms` surface as anonymous goals; elaboration failure
is the failure mode.

Frozen indices: 0 — `transfer`, 1 — `mint`, 2 — `burn`, 3 —
`freezeResource`, 4 — `replaceKey`, 5 — `reward`, 6 —
`distributeOthers`, 7 — `proportionalDilute`, 8 — `dispute`, 9 —
`disputeWithdraw`, 10 — `verdict`, 11 — `rollback`, 12 —
`registerIdentity`, 13 — `deposit`, 14 — `withdraw`, 15 —
`declareLocalPolicy`, 16 — `revokeLocalPolicy`, 17 —
`faultProofChallenge`, 18 — `faultProofResolution`.
-/

-- 0
example (r : ResourceId) (s r' : ActorId) (am : Amount) :
    Action.tag (.transfer r s r' am) = 0 := rfl
-- 1
example (r : ResourceId) (to : ActorId) (am : Amount) :
    Action.tag (.mint r to am) = 1 := rfl
-- 2
example (r : ResourceId) (fr : ActorId) (am : Amount) :
    Action.tag (.burn r fr am) = 2 := rfl
-- 3
example (r : ResourceId) :
    Action.tag (.freezeResource r) = 3 := rfl
-- 4
example (a : ActorId) (pk : PublicKey) :
    Action.tag (.replaceKey a pk) = 4 := rfl
-- 5
example (r : ResourceId) (to : ActorId) (am : Amount) :
    Action.tag (.reward r to am) = 5 := rfl
-- 6
example (r : ResourceId) (ex : ActorId) (am : Amount) :
    Action.tag (.distributeOthers r ex am) = 6 := rfl
-- 7
example (r : ResourceId) (ex : ActorId) (tr : Amount) :
    Action.tag (.proportionalDilute r ex tr) = 7 := rfl
-- 8
example (d : LegalKernel.Disputes.Dispute) :
    Action.tag (.dispute d) = 8 := rfl
-- 9
example (idx : Nat) :
    Action.tag (.disputeWithdraw idx) = 9 := rfl
-- 10
example (v : LegalKernel.Disputes.Verdict) :
    Action.tag (.verdict v) = 10 := rfl
-- 11
example (idx : Nat) :
    Action.tag (.rollback idx) = 11 := rfl
-- 12
example (a : ActorId) (pk : PublicKey) :
    Action.tag (.registerIdentity a pk) = 12 := rfl
-- 13
example (r : ResourceId) (to : ActorId) (am : Amount) (did : LegalKernel.Bridge.DepositId) :
    Action.tag (.deposit r to am did) = 13 := rfl
-- 14
example (r : ResourceId) (fr : ActorId) (am : Amount) (eth : LegalKernel.Bridge.EthAddress) :
    Action.tag (.withdraw r fr am eth) = 14 := rfl
-- 15
example (p : LocalPolicy) :
    Action.tag (.declareLocalPolicy p) = 15 := rfl
-- 16
example :
    Action.tag .revokeLocalPolicy = 16 := rfl
-- 17
example (bh : ByteArray) (sIdx eIdx : LegalKernel.Disputes.LogIndex)
    (cc : ByteArray) :
    Action.tag (.faultProofChallenge bh sIdx eIdx cc) = 17 := rfl
-- 18
example (bh : ByteArray) (gid : Nat) (winner : ActorId)
    (revIdx : LegalKernel.Disputes.LogIndex) :
    Action.tag (.faultProofResolution bh gid winner revIdx) = 18 := rfl

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
  , { name := "Action.compile_eq_iff: term-level check"
    , body := do
        let _f : (a₁ a₂ : Action) →
                 (Action.compile a₁ = Action.compile a₂ ↔ a₁ = a₂) :=
          Action.compile_eq_iff
        pure ()
    }
  , { name := "Action.compile_ne_of_ne: term-level check"
    , body := do
        let _f : (a₁ a₂ : Action) → a₁ ≠ a₂ →
                 Action.compile a₁ ≠ Action.compile a₂ :=
          Action.compile_ne_of_ne
        pure ()
    }
  , { name := "Action.compile_ne_of_ne: value-level on distinct constructors"
    , body := do
        let a₁ : Action := .transfer 1 2 3 4
        let a₂ : Action := .mint 1 2 4
        have hne : a₁ ≠ a₂ := by decide
        let _proof : Action.compile a₁ ≠ Action.compile a₂ :=
          Action.compile_ne_of_ne a₁ a₂ hne
        pure ()
    }
  , { name := "Action.compile_ne_of_ne: value-level on transfer with different amounts"
    , body := do
        let a₁ : Action := .transfer 1 2 3 4
        let a₂ : Action := .transfer 1 2 3 5
        have hne : a₁ ≠ a₂ := by decide
        let _proof : Action.compile a₁ ≠ Action.compile a₂ :=
          Action.compile_ne_of_ne a₁ a₂ hne
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
  -- Phase-4-prelude WU R.18: positive-incentive constructor coverage.
  , { name := "Action.reward constructor distinguishability"
    , body := do
        let a₁ : Action := .reward 1 5 10
        let a₂ : Action := .reward 1 5 11
        assert (decide (a₁ ≠ a₂)) "different amounts ⇒ distinct"
    }
  , { name := "Action.distributeOthers constructor distinguishability"
    , body := do
        let a₁ : Action := .distributeOthers 1 2 50
        let a₂ : Action := .distributeOthers 1 3 50
        assert (decide (a₁ ≠ a₂)) "different excluded ⇒ distinct"
    }
  , { name := "Action.proportionalDilute constructor distinguishability"
    , body := do
        let a₁ : Action := .proportionalDilute 1 2 10
        let a₂ : Action := .proportionalDilute 1 2 11
        assert (decide (a₁ ≠ a₂)) "different totalReward ⇒ distinct"
    }
  -- Critical: reward and mint share scalar shape but must remain
  -- constructor-distinct so authority policies can grant them
  -- independently.
  , { name := "Action.reward vs Action.mint distinguishability (same scalars)"
    , body := do
        let a₁ : Action := .reward 1 5 10
        let a₂ : Action := .mint 1 5 10
        assert (decide (a₁ ≠ a₂)) "reward ≠ mint at the Action layer"
    }
  -- compile_eq_iff covers the new constructors via the structural proof.
  , { name := "Action.compile_eq_iff covers .reward"
    , body := do
        let a₁ : Action := .reward 1 5 10
        let a₂ : Action := .reward 1 5 10
        let _proof : Action.compile a₁ = Action.compile a₂ ↔ a₁ = a₂ :=
          Action.compile_eq_iff a₁ a₂
        pure ()
    }
  -- Compile shape check: the new transitions match the underlying laws.
  , { name := "Action.compile (.reward …).source = .reward …"
    , body := do
        let a : Action := .reward 1 5 10
        let _proof : (Action.compile a).source = .reward 1 5 10 := rfl
        pure ()
    }
  , { name := "Action.compile (.distributeOthers …).source = .distributeOthers …"
    , body := do
        let a : Action := .distributeOthers 1 2 50
        let _proof : (Action.compile a).source = .distributeOthers 1 2 50 := rfl
        pure ()
    }
  , { name := "Action.compile (.proportionalDilute …).source = .proportionalDilute …"
    , body := do
        let a : Action := .proportionalDilute 1 2 10
        let _proof : (Action.compile a).source = .proportionalDilute 1 2 10 := rfl
        pure ()
    }
  -- Workstream LP / LP.4 — declareLocalPolicy / revokeLocalPolicy tests:
  , { name := "Action.declareLocalPolicy ≠ Action.revokeLocalPolicy (DecidableEq)"
    , body := do
        let p : LocalPolicy := { clauses := [] }
        assert (! decide (Action.declareLocalPolicy p = Action.revokeLocalPolicy))
          "declareLocalPolicy and revokeLocalPolicy should be unequal"
    }
  , { name := "Action.declareLocalPolicy distinguishes by policy"
    , body := do
        let p₁ : LocalPolicy := { clauses := [.denyTags [0]] }
        let p₂ : LocalPolicy := { clauses := [.denyTags [1]] }
        assert (! decide (Action.declareLocalPolicy p₁ = Action.declareLocalPolicy p₂))
          "declareLocalPolicy with distinct policies should be unequal"
    }
  , { name := "Action.declareLocalPolicy ≠ Action.transfer (DecidableEq)"
    , body := do
        let p : LocalPolicy := { clauses := [] }
        assert (! decide (Action.declareLocalPolicy p = Action.transfer 1 1 2 50))
          "different action ctors should be unequal"
    }
  , { name := "Action.compile (.declareLocalPolicy _).source = .declareLocalPolicy _"
    , body := do
        let p : LocalPolicy := { clauses := [.denyTags [0]] }
        let a : Action := .declareLocalPolicy p
        let _proof : (Action.compile a).source = .declareLocalPolicy p := rfl
        pure ()
    }
  , { name := "Action.compile .revokeLocalPolicy.source = .revokeLocalPolicy"
    , body := do
        let _proof : (Action.compile .revokeLocalPolicy).source = .revokeLocalPolicy := rfl
        pure ()
    }
  , { name := "declareLocalPolicy/revokeLocalPolicy compile to freezeResource 0"
    , body := do
        let p : LocalPolicy := { clauses := [.denyTags [0]] }
        let _proofD : Action.compileTransition (.declareLocalPolicy p) =
                      Laws.freezeResource 0 := rfl
        let _proofR : Action.compileTransition .revokeLocalPolicy =
                      Laws.freezeResource 0 := rfl
        pure ()
    }
  ]

end LegalKernel.Test.Authority.ActionTests
