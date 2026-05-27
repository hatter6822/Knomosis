/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.LocalPolicy.LawClassification — runtime tests for
the LP.9 law classification.

Workstream LP work unit LP.9.  Exercises:

  * Both LP action ctors compile to `Laws.freezeResource 0`.
  * Both have `IsConservative` and `IsMonotonic` instances.
  * The composite classification theorem packs the four instances
    into a single statement.
  * `MonotonicLawSet` constructibility with LP actions in the set.
-/

import LegalKernel.LocalPolicy.LawClassification
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.LocalPolicy
open LegalKernel.Test

namespace LegalKernel.Test.LocalPolicy.LawClassificationTests

/-- A sample policy for the tests. -/
def samplePolicy : Authority.LocalPolicy :=
  { clauses := [.denyTags [0]] }

/-- All LP.9 test cases. -/
def tests : List TestCase :=
  [ -- Identification lemmas (rfl-class).
    { name := "declareLocalPolicy compiles to freezeResource 0"
    , body := do
        let _proof :
          ∀ (p : Authority.LocalPolicy),
            Action.compileTransition (.declareLocalPolicy p) =
            Laws.freezeResource 0 :=
          declareLocalPolicy_compileTransition_eq_freezeResource_zero
        pure ()
    }
  , { name := "revokeLocalPolicy compiles to freezeResource 0"
    , body := do
        let _proof :
          Action.compileTransition .revokeLocalPolicy =
          Laws.freezeResource 0 :=
          revokeLocalPolicy_compileTransition_eq_freezeResource_zero
        pure ()
    }
  , -- Instance synthesis: IsConservative.
    { name := "declareLocalPolicy compiled is IsConservative (instance)"
    , body := do
        let _i : IsConservative (Action.compileTransition (.declareLocalPolicy samplePolicy)) :=
          inferInstance
        pure ()
    }
  , { name := "revokeLocalPolicy compiled is IsConservative (instance)"
    , body := do
        let _i : IsConservative (Action.compileTransition .revokeLocalPolicy) :=
          inferInstance
        pure ()
    }
  , -- Instance synthesis: IsMonotonic.
    { name := "declareLocalPolicy compiled is IsMonotonic (instance)"
    , body := do
        let _i : IsMonotonic (Action.compileTransition (.declareLocalPolicy samplePolicy)) :=
          inferInstance
        pure ()
    }
  , { name := "revokeLocalPolicy compiled is IsMonotonic (instance)"
    , body := do
        let _i : IsMonotonic (Action.compileTransition .revokeLocalPolicy) :=
          inferInstance
        pure ()
    }
  , -- Composite theorem.
    { name := "local_policy_actions_classification API stability"
    , body := do
        let _proof :
          (∀ p : Authority.LocalPolicy,
              IsConservative (Action.compileTransition (.declareLocalPolicy p))) ∧
          (∀ p : Authority.LocalPolicy,
              IsMonotonic (Action.compileTransition (.declareLocalPolicy p))) ∧
          IsConservative (Action.compileTransition .revokeLocalPolicy) ∧
          IsMonotonic (Action.compileTransition .revokeLocalPolicy) :=
          local_policy_actions_classification
        pure ()
    }
  , -- MonotonicLawSet constructibility check: a deployment-level law set
  -- containing the LP action ctors elaborates without breaking the firewall.
    { name := "MonotonicLawSet admits LP actions"
    , body := do
        let _ms : MonotonicLawSet :=
          { laws := [Action.compileTransition (.declareLocalPolicy samplePolicy),
                     Action.compileTransition .revokeLocalPolicy,
                     Laws.transfer 1 1 2 50],
            isMonotonic := by
              intro t ht
              simp only [List.mem_cons, List.not_mem_nil, or_false] at ht
              rcases ht with rfl | rfl | rfl
              · infer_instance
              · infer_instance
              · infer_instance }
        pure ()
    }
  , -- Smoke check: declareLocalPolicy / revokeLocalPolicy don't change
    -- balances (apply_impl is identity since they compile to
    -- `Laws.freezeResource 0`).
    { name := "declareLocalPolicy is balance-preserving"
    , body := do
        let s : LegalKernel.State := setBalance emptyState 1 1 100
        let s' := (Action.compileTransition (.declareLocalPolicy samplePolicy)).apply_impl s
        -- Probe a balance: 100 was at (1, 1); should still be 100 post-apply.
        assertEq (expected := (100 : Amount)) (actual := getBalance s' 1 1)
    }
  , { name := "revokeLocalPolicy is balance-preserving"
    , body := do
        let s : LegalKernel.State := setBalance emptyState 1 1 100
        let s' := (Action.compileTransition .revokeLocalPolicy).apply_impl s
        assertEq (expected := (100 : Amount)) (actual := getBalance s' 1 1)
    }
  ]

end LegalKernel.Test.LocalPolicy.LawClassificationTests
