-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Lex.Test.ExampleLex — runtime tests for the M1
acceptance Lex law.

LX.21 (`docs/planning/lex_implementation_plan.md` §19.3): the acceptance
gate's value-level test surface.
-/

import LegalKernel
import LegalKernel.Test.Framework
import Lex.Examples.ExampleLex

-- Plan §2.5: `Law.mk` is deprecated in favour of `lexlaw`; the
-- non-deprecated `lex_law_mk` constructor is M3 work and the
-- deprecation cleanup is explicitly deferred.  The legacy-DSL
-- API-stability test below exercises the deprecated surface to
-- pin its behaviour for the duration of the deprecation window.
set_option linter.deprecated false

namespace Lex.Test.ExampleLex

open LegalKernel.Test
open Lex.Examples

/-- Acceptance tests for the M1 example Lex law. -/
def tests : List TestCase :=
  [ { name := "example Lex law's transition.pre is True on every state"
    , body := do
        let s := emptyState
        assert (decide (example_example_lex_only_law_transition.pre s))
          "True precondition on emptyState"
    }
  , { name := "example Lex law's apply_impl is the identity"
    , body := do
        let s := emptyState
        let _ : example_example_lex_only_law_transition.apply_impl s = s := rfl
        pure ()
    }
  , { name := "example Lex law's transition is structurally `Law.mk True (fun s => s)`"
    , body := do
        let _ :
            example_example_lex_only_law_transition =
              LegalKernel.DSL.Law.mk
                (fun (_ : LegalKernel.State) => True)
                (fun (s : LegalKernel.State) => s) := rfl
        pure ()
    }
  , { name := "step_impl on the example law produces the same balances field"
    , body := do
        -- `step_impl s t` reduces to either `t.apply_impl s` or
        -- `s` (per the kernel's `if t.pre s then ... else s`
        -- branching).  For the example law, both branches return
        -- the same `balances` field.
        let s := emptyState
        let s' := LegalKernel.step_impl s example_example_lex_only_law_transition
        let _ : s'.balances = s.balances := by rfl
        pure ()
    }
  -- M1 acceptance §24.1 #10: the example Lex law's transition
  -- composes correctly with the LX.2 / LX.3 classification
  -- instances — the kernel-impl-identity transition satisfies
  -- every classification trivially.
  , { name := "example Lex law's transition is IsConservative (kernel-impl identity)"
    , body := do
        let _proof : LegalKernel.IsConservative
            example_example_lex_only_law_transition := {
          conserves := fun _ _ _ => rfl
        }
        pure ()
    }
  , { name := "example Lex law's transition is IsMonotonic (kernel-impl identity)"
    , body := do
        let _proof : LegalKernel.IsMonotonic
            example_example_lex_only_law_transition := {
          monotone := fun _ _ _ => Nat.le_refl _
        }
        pure ()
    }
  , { name := "example Lex law's transition is LocalTo [] (kernel-impl identity)"
    , body := do
        let _proof : LegalKernel.LocalTo []
            example_example_lex_only_law_transition := {
          local_to := fun _ _ _ _ _ => rfl
        }
        pure ()
    }
  , { name := "example Lex law's transition is FreezePreserving S for any S"
    , body := do
        let _proof : LegalKernel.FreezePreserving [3, 5]
            example_example_lex_only_law_transition := {
          preserves := fun _ _ _ _ h _ => h
        }
        pure ()
    }
  ]

end Lex.Test.ExampleLex
