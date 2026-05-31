-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Authority.Nonce — runtime tests for the §8.5
nonce ledger and `ExtendedState`.

Phase-3 WU 3.5.  Exercises:

  * `expectsNonce` returns 0 for unregistered actors.
  * `advanceNonce` increments the actor's nonce by 1.
  * `advanceNonce` is per-actor (other actors unchanged).
  * `expectsNonce_strict_mono` term-level API check.
  * Multiple `advanceNonce` calls compose correctly (nonce 0 → 1 → 2).
-/

import LegalKernel.Authority.Nonce
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.Authority.NonceTests

/-- Tests for `NonceState`, `ExtendedState`, and the §8.5 nonce
    operations. -/
def tests : List TestCase :=
  [ { name := "expectsNonce on empty state returns 0"
    , body := do
        let es := ExtendedState.empty
        assertEq (expected := (0 : Nonce)) (actual := expectsNonce es 1) "empty"
    }
  , { name := "advanceNonce increments by 1"
    , body := do
        let es := ExtendedState.empty
        let es' := advanceNonce es 1
        assertEq (expected := (1 : Nonce)) (actual := expectsNonce es' 1)
          "after one advance"
    }
  , { name := "advanceNonce twice produces nonce 2"
    , body := do
        let es := ExtendedState.empty
        let es' := advanceNonce (advanceNonce es 1) 1
        assertEq (expected := (2 : Nonce)) (actual := expectsNonce es' 1)
          "after two advances"
    }
  , { name := "advanceNonce of one actor leaves another at 0"
    , body := do
        let es := ExtendedState.empty
        let es' := advanceNonce es 1
        assertEq (expected := (0 : Nonce)) (actual := expectsNonce es' 2)
          "actor 2 unchanged"
    }
  , { name := "advanceNonce of one actor doesn't change another's"
    , body := do
        let es := advanceNonce ExtendedState.empty 2
        let es' := advanceNonce es 1
        assertEq (expected := (1 : Nonce)) (actual := expectsNonce es' 2)
          "actor 2 still at 1"
        assertEq (expected := (1 : Nonce)) (actual := expectsNonce es' 1)
          "actor 1 advanced to 1"
    }

  -- Term-level API stability.
  , { name := "expectsNonce_strict_mono term-level type check"
    , body := do
        let es := ExtendedState.empty
        let _proof : expectsNonce (advanceNonce es 1) 1 = expectsNonce es 1 + 1 :=
          expectsNonce_strict_mono es 1
        pure ()
    }
  , { name := "expectsNonce_advance_other term-level type check"
    , body := do
        let es := ExtendedState.empty
        let _proof : expectsNonce (advanceNonce es 1) 2 = expectsNonce es 2 :=
          expectsNonce_advance_other es 1 2 (by decide)
        pure ()
    }
  , { name := "advanceNonce_base preserves base state"
    , body := do
        let s := setBalance emptyState 1 10 100
        let es : ExtendedState := { ExtendedState.empty with base := s }
        let es' := advanceNonce es 1
        assertEq (expected := 100) (actual := getBalance es'.base 1 10)
          "base preserved"
    }
  , { name := "advanceNonce_registry preserves registry"
    , body := do
        let kr := KeyRegistry.empty.register 1 (⟨#[0xAA]⟩ : PublicKey)
        let es : ExtendedState := { ExtendedState.empty with registry := kr }
        let es' := advanceNonce es 1
        assert (es'.registry.lookup 1 = some (⟨#[0xAA]⟩ : PublicKey))
          "registry preserved"
    }

  -- Replay-relevant nonce identities.
  , { name := "expectsNonce_after_advance_gt_old: post > pre"
    , body := do
        let es := ExtendedState.empty
        let _proof : expectsNonce (advanceNonce es 1) 1 > expectsNonce es 1 :=
          expectsNonce_after_advance_gt_old es 1
        pure ()
    }
  , { name := "expectsNonce_after_advance_ne_old at exact pre nonce"
    , body := do
        let es := advanceNonce ExtendedState.empty 1  -- es with nonce 1 expected for actor 1
        -- expectsNonce es 1 = 1.  After another advance, expectsNonce = 2.
        -- The lemma says: 2 ≠ 1.
        -- Use the API: expectsNonce_strict_mono ExtendedState.empty 1 gives the
        -- equation for `es`, then `Nat.le_refl 1 ▸ this` lifts to `1 ≤ expectsNonce es 1`.
        have hes : expectsNonce es 1 = 1 := by
          show expectsNonce (advanceNonce ExtendedState.empty 1) 1 = 1
          rw [expectsNonce_strict_mono]
          rfl
        let _proof : expectsNonce (advanceNonce es 1) 1 ≠ 1 :=
          expectsNonce_after_advance_ne_old es 1 1 (by rw [hes]; exact Nat.le_refl _)
        pure ()
    }
  , { name := "GP.3.1: ExtendedState.empty budget policy is bounded"
    , body := do
        let _proof : ExtendedState.empty.budgetPolicy = .bounded 0 1 0 :=
          ExtendedState.genesis_has_bounded_budget_policy
        pure ()
    }
  ]

end LegalKernel.Test.Authority.NonceTests
