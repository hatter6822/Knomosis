/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Authority.Identity — runtime tests for the
Phase-3 Identity / KeyRegistry / AuthorityPolicy machinery.

Phase-3 WU 3.3.  Exercises:

  * `KeyRegistry` operations: `empty`, `register`, `revoke`, `lookup`,
    `mergeLeftBiased`.
  * `AuthorityPolicy` operations: `empty`, `unrestricted`, `union`,
    `intersect`, `singleton`, with concrete decidability witnesses.
  * Cross-policy composition produces the expected authorisation
    decisions.
-/

import LegalKernel.Authority.Identity
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.Authority.IdentityTests

/-- A sample public key (the "first" key, used as the initial
    registration). -/
def k1 : PublicKey := ⟨#[0xAA, 0xBB]⟩

/-- A second sample public key (used to test rotation / overwrite). -/
def k2 : PublicKey := ⟨#[0xCC, 0xDD]⟩

/-- Tests for `KeyRegistry` and `AuthorityPolicy`. -/
def tests : List TestCase :=
  [ -- KeyRegistry basics.
    { name := "KeyRegistry.empty.lookup returns none"
    , body := do
        assert (KeyRegistry.empty.lookup 1 = none) "empty has no entries"
    }
  , { name := "KeyRegistry.register then lookup returns some"
    , body := do
        let kr := KeyRegistry.empty.register 1 k1
        assert (kr.lookup 1 = some k1) "register-then-lookup round-trip"
    }
  , { name := "KeyRegistry.register then lookup at other actor returns none"
    , body := do
        let kr := KeyRegistry.empty.register 1 k1
        assert (kr.lookup 2 = none) "other actor still missing"
    }
  , { name := "KeyRegistry.revoke removes the entry"
    , body := do
        let kr := (KeyRegistry.empty.register 1 k1).revoke 1
        assert (kr.lookup 1 = none) "revoked actor returns none"
    }
  , { name := "KeyRegistry.register overwrites the existing key"
    , body := do
        let kr := (KeyRegistry.empty.register 1 k1).register 1 k2
        assert (kr.lookup 1 = some k2) "second register wins"
    }
  , { name := "KeyRegistry.mergeLeftBiased: left wins on collision"
    , body := do
        let kr1 := KeyRegistry.empty.register 1 k1
        let kr2 := KeyRegistry.empty.register 1 k2
        let merged := KeyRegistry.mergeLeftBiased kr1 kr2
        assert (merged.lookup 1 = some k1) "left key wins"
    }
  , { name := "KeyRegistry.mergeLeftBiased: disjoint keys both present"
    , body := do
        let kr1 := KeyRegistry.empty.register 1 k1
        let kr2 := KeyRegistry.empty.register 2 k2
        let merged := KeyRegistry.mergeLeftBiased kr1 kr2
        assert (merged.lookup 1 = some k1) "left actor present"
        assert (merged.lookup 2 = some k2) "right actor present"
    }

  -- AuthorityPolicy basics.
  , { name := "AuthorityPolicy.empty rejects every action"
    , body := do
        let P := AuthorityPolicy.empty
        assert (! decide (P.authorized 0 (.transfer 1 2 3 4))) "empty policy rejects"
    }
  , { name := "AuthorityPolicy.unrestricted permits every action"
    , body := do
        let P := AuthorityPolicy.unrestricted
        assert (decide (P.authorized 0 (.transfer 1 2 3 4))) "unrestricted permits"
    }

  -- AuthorityPolicy combinators.
  , { name := "AuthorityPolicy.union: empty ∪ unrestricted permits"
    , body := do
        let P := AuthorityPolicy.union AuthorityPolicy.empty AuthorityPolicy.unrestricted
        assert (decide (P.authorized 0 (.mint 1 2 3))) "union permits via right"
    }
  , { name := "AuthorityPolicy.intersect: empty ∩ unrestricted rejects"
    , body := do
        let P := AuthorityPolicy.intersect AuthorityPolicy.empty AuthorityPolicy.unrestricted
        assert (! decide (P.authorized 0 (.mint 1 2 3))) "intersect rejects via empty"
    }
  , { name := "AuthorityPolicy.intersect: unrestricted ∩ unrestricted permits"
    , body := do
        let P := AuthorityPolicy.intersect AuthorityPolicy.unrestricted AuthorityPolicy.unrestricted
        assert (decide (P.authorized 0 (.mint 1 2 3))) "both unrestricted permits"
    }
  , { name := "AuthorityPolicy.singleton permits the matching pair only"
    , body := do
        let target : Action := .transfer 1 10 20 30
        let P := AuthorityPolicy.singleton 5 target
        assert (decide (P.authorized 5 target)) "matching pair permitted"
        assert (! decide (P.authorized 6 target)) "wrong actor rejected"
        assert (! decide (P.authorized 5 (.mint 1 10 30))) "wrong action rejected"
    }
  , { name := "AuthorityPolicy.union of two singletons covers both"
    , body := do
        let act1 : Action := .transfer 1 10 20 30
        let act2 : Action := .mint 1 10 30
        let P := AuthorityPolicy.union
                  (AuthorityPolicy.singleton 5 act1)
                  (AuthorityPolicy.singleton 7 act2)
        assert (decide (P.authorized 5 act1)) "first permitted"
        assert (decide (P.authorized 7 act2)) "second permitted"
        assert (! decide (P.authorized 5 act2)) "wrong actor for second"
        assert (! decide (P.authorized 7 act1)) "wrong actor for first"
    }

  -- WU 3.3: KeyRegistry semantic theorems (term-level API stability).
  , { name := "KeyRegistry.lookup_register_self: term-level check"
    , body := do
        let _f : (kr : KeyRegistry) → (id : ActorId) → (key : PublicKey) →
                 (kr.register id key).lookup id = some key :=
          KeyRegistry.lookup_register_self
        pure ()
    }
  , { name := "KeyRegistry.lookup_register_other: term-level check"
    , body := do
        let _f : (kr : KeyRegistry) → (id₁ id₂ : ActorId) → (key : PublicKey) →
                 id₁ ≠ id₂ →
                 (kr.register id₁ key).lookup id₂ = kr.lookup id₂ :=
          KeyRegistry.lookup_register_other
        pure ()
    }
  , { name := "KeyRegistry.lookup_revoke_self: term-level check"
    , body := do
        let _f : (kr : KeyRegistry) → (id : ActorId) →
                 (kr.revoke id).lookup id = none :=
          KeyRegistry.lookup_revoke_self
        pure ()
    }
  , { name := "KeyRegistry.lookup_revoke_other: term-level check"
    , body := do
        let _f : (kr : KeyRegistry) → (id₁ id₂ : ActorId) → id₁ ≠ id₂ →
                 (kr.revoke id₁).lookup id₂ = kr.lookup id₂ :=
          KeyRegistry.lookup_revoke_other
        pure ()
    }

  -- WU 3.3: KeyRegistry value-level checks for revoke semantics.
  , { name := "KeyRegistry: revoke then lookup at revoked actor returns none"
    , body := do
        let kr := (KeyRegistry.empty.register 1 k1).revoke 1
        assert (kr.lookup 1 = none) "revoked actor returns none (value-level)"
    }
  , { name := "KeyRegistry: revoke at one actor leaves others intact"
    , body := do
        let kr := (KeyRegistry.empty.register 1 k1).register 2 k2
        let kr' := kr.revoke 1
        assert (kr'.lookup 1 = none) "actor 1 revoked"
        assert (kr'.lookup 2 = some k2) "actor 2 untouched"
    }

  -- WU 3.3: AuthorityPolicy combinator semantic theorems (term-level API).
  , { name := "AuthorityPolicy.empty_authorized term-level"
    , body := do
        let _f : (a : ActorId) → (act : Action) →
                 (AuthorityPolicy.empty.authorized a act ↔ False) :=
          AuthorityPolicy.empty_authorized
        pure ()
    }
  , { name := "AuthorityPolicy.unrestricted_authorized term-level"
    , body := do
        let _f : (a : ActorId) → (act : Action) →
                 (AuthorityPolicy.unrestricted.authorized a act ↔ True) :=
          AuthorityPolicy.unrestricted_authorized
        pure ()
    }
  , { name := "AuthorityPolicy.union_authorized term-level"
    , body := do
        let _f : (P₁ P₂ : AuthorityPolicy) → (a : ActorId) → (act : Action) →
                 ((AuthorityPolicy.union P₁ P₂).authorized a act ↔
                   P₁.authorized a act ∨ P₂.authorized a act) :=
          AuthorityPolicy.union_authorized
        pure ()
    }
  , { name := "AuthorityPolicy.intersect_authorized term-level"
    , body := do
        let _f : (P₁ P₂ : AuthorityPolicy) → (a : ActorId) → (act : Action) →
                 ((AuthorityPolicy.intersect P₁ P₂).authorized a act ↔
                   P₁.authorized a act ∧ P₂.authorized a act) :=
          AuthorityPolicy.intersect_authorized
        pure ()
    }
  , { name := "AuthorityPolicy.singleton_authorized term-level"
    , body := do
        let _f : (a₀ : ActorId) → (act₀ : Action) → (a : ActorId) → (act : Action) →
                 ((AuthorityPolicy.singleton a₀ act₀).authorized a act ↔
                   a = a₀ ∧ act = act₀) :=
          AuthorityPolicy.singleton_authorized
        pure ()
    }

  -- WU 3.3: AuthorityPolicy algebraic identities.
  , { name := "AuthorityPolicy.union_empty: P ∪ empty ≡ P (value-level)"
    , body := do
        let act : Action := .transfer 1 10 20 30
        let P := AuthorityPolicy.singleton 5 act
        let merged := AuthorityPolicy.union P AuthorityPolicy.empty
        assert (decide (merged.authorized 5 act)) "P-permitted survives"
        assert (! decide (merged.authorized 6 act)) "P-rejected survives"
    }
  , { name := "AuthorityPolicy.intersect_unrestricted: P ∩ unrestricted ≡ P"
    , body := do
        let act : Action := .transfer 1 10 20 30
        let P := AuthorityPolicy.singleton 5 act
        let intersected := AuthorityPolicy.intersect P AuthorityPolicy.unrestricted
        assert (decide (intersected.authorized 5 act)) "P-permitted survives"
        assert (! decide (intersected.authorized 6 act)) "P-rejected survives"
    }
  ]

end LegalKernel.Test.Authority.IdentityTests
