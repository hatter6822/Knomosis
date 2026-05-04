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
  ]

end LegalKernel.Test.Authority.IdentityTests
