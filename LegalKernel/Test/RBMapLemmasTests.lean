/-
LegalKernel.Test.RBMapLemmasTests — value-level tests for §8.3.

Phase 1 WU 1.1 – 1.4 ship pointwise insert lemmas and fold-after-insert
lemmas as compile-time-checked theorems in `LegalKernel.RBMapLemmas`.
This file adds runtime spot-checks on representative `BalanceMap`-shaped
inputs.  The runtime tests catch regressions in the Std-library API
(e.g. a renamed `getElem?_insert_self`) that elaboration alone could
miss when the kernel's higher-level theorems still happen to elaborate.

Coverage map:

  * `find?_insert_self` round-trips on a single insert.
  * `find?_insert_other` preserves disjoint keys.
  * `sumValues` of an empty map is 0.
  * `sumValues_insert_absent` adds the new value to the running sum.
  * `sumValues_insert_present` swaps the old value for the new value.
-/

import LegalKernel.RBMapLemmas
import LegalKernel.Test.Framework

open Std
open LegalKernel
open LegalKernel.Test
open LegalKernel.RBMap

namespace LegalKernel.Test.RBMapLemmasTests

/-- A small `BalanceMap`-shaped fixture: `(actor 1, balance 100),
    (actor 2, balance 50)`. -/
def fundedMap : TreeMap UInt64 Nat compare :=
  ((∅ : TreeMap UInt64 Nat compare).insert 1 100).insert 2 50

/-- Tests for the §8.3 RBMap lemma library. -/
def tests : List TestCase :=
  [ { name := "find?_insert_self returns the inserted value"
    , body := do
        let m : TreeMap UInt64 Nat compare := ∅
        let m' := m.insert (7 : UInt64) 42
        assertEq (expected := some (42 : Nat))
                 (actual   := m'[(7 : UInt64)]?)
                 "fresh insert lookup"
    }
  , { name := "find?_insert_other preserves disjoint key"
    , body := do
        let m₀ := (∅ : TreeMap UInt64 Nat compare).insert (1 : UInt64) 100
        let m₁ := m₀.insert (2 : UInt64) 50
        -- Look up actor 1 in m₁: should still be 100.
        assertEq (expected := some (100 : Nat))
                 (actual   := m₁[(1 : UInt64)]?)
                 "key 1 unchanged after insert at key 2"
    }
  , { name := "sumValues of empty map is 0"
    , body := do
        assertEq (expected := (0 : Nat))
                 (actual   := sumValues (∅ : TreeMap UInt64 Nat compare))
                 "empty map sums to 0"
    }
  , { name := "sumValues sums every entry exactly once"
    , body := do
        -- 100 (at 1) + 50 (at 2) = 150.
        assertEq (expected := (150 : Nat))
                 (actual   := sumValues fundedMap)
                 "fundedMap total"
    }
  , { name := "sumValues_insert_absent witnesses on a fresh key"
    , body := do
        let m₁ := fundedMap.insert (99 : UInt64) 25
        -- 100 + 50 + 25 = 175.
        assertEq (expected := (175 : Nat))
                 (actual   := sumValues m₁)
                 "absent-key insert"
    }
  , { name := "sumValues_insert_present overwrites the old value"
    , body := do
        -- Replace actor 1's balance (100) with 7: total drops by 93.
        let m₁ := fundedMap.insert (1 : UInt64) 7
        -- 7 + 50 = 57.
        assertEq (expected := (57 : Nat))
                 (actual   := sumValues m₁)
                 "present-key insert"
    }
  , { name := "sumValues_insert_present erase-then-zero halves total"
    , body := do
        -- A common fee/burn shape: actor with balance B has it set to 0.
        let m₁ := fundedMap.insert (2 : UInt64) 0
        -- 100 + 0 = 100.
        assertEq (expected := (100 : Nat))
                 (actual   := sumValues m₁)
                 "set-to-zero insert"
    }
  , { name := "sumValues_eq_values_sum: theorem statement holds value-level"
    , body := do
        -- Drive the WU 1.4 theorem directly: compute both sides on a
        -- representative fixture and assert they agree.  This is a
        -- value-level regression check on top of the elaboration-time
        -- proof.  If the theorem signature changes, the term
        -- ascription below fails to elaborate.
        let m := fundedMap
        let _eq : sumValues m = (m.toList.map (·.snd)).sum :=
          sumValues_eq_values_sum m
        assertEq (expected := (m.toList.map (·.snd)).sum)
                 (actual   := sumValues m)
                 "sumValues = sum-of-values"
    }
  ]

end LegalKernel.Test.RBMapLemmasTests
