/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Laws.Transfer — unit tests for §4.11.

Phase-0 acceptance for WU 0.3 is "builds; transfer.pre is decidable".
The first is checked by Lake; the second is checked at compile time
by the `example : Decidable ...` line in `Laws/Transfer.lean`.  This
file adds run-time tests that pin down the *intended semantics*:

* the precondition is decided correctly on positive and negative
  cases;
* a legal transfer moves the right amount in the distinct-actor case;
* a self-transfer leaves the actor's balance unchanged (the §4.11
  bug-fix invariant);
* a transfer of more than the sender holds is a no-op;
* a transfer of zero (vacuous) is rejected by precondition;
* unrelated resources are untouched.

Phase 2 extends the file with runtime witnesses for `transfer_conserves`
(distinct-actor and self-transfer cases), `transfer_conserves_other_resource`,
and the `IsConservative` typeclass instance.
-/

import LegalKernel.Laws.Transfer
import LegalKernel.Conservation
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Laws
open LegalKernel.Test

namespace LegalKernel.Test.Laws.TransferTests

/-- Convenience: a fresh state with `(r=1, sender=10) ↦ initialBalance`. -/
def fund (initialBalance : Amount) : State :=
  setBalance emptyState 1 10 initialBalance

/-- Tests for the `transfer` law. -/
def tests : List TestCase :=
  [ { name := "precondition: enough balance ∧ amount > 0 ⇒ true"
    , body := do
        let s := fund 100
        let t := transfer 1 10 20 30
        assert (decide (t.pre s)) "should accept"
    }
  , { name := "precondition: insufficient balance ⇒ false"
    , body := do
        let s := fund 5
        let t := transfer 1 10 20 30
        assert (! decide (t.pre s)) "should reject (insufficient)"
    }
  , { name := "precondition: zero amount ⇒ false"
    , body := do
        let s := fund 100
        let t := transfer 1 10 20 0
        assert (! decide (t.pre s)) "should reject (zero amount)"
    }
  , { name := "legal transfer moves balance to receiver"
    , body := do
        let s  := fund 100
        let t  := transfer 1 10 20 30
        let s' := step_impl s t
        assertEq (expected := 70) (actual := getBalance s' 1 10) "sender after"
        assertEq (expected := 30) (actual := getBalance s' 1 20) "receiver after"
    }
  , { name := "self-transfer preserves the actor's balance (the §4.11 fix)"
    , body := do
        -- Read receiver's balance from the post-debit state, not pre.
        -- Without the fix, a self-transfer of 30 from balance 100 would
        -- leave 130 (over-credit) or 70 (under-credit) instead of 100.
        let s  := fund 100
        let t  := transfer 1 10 10 30
        let s' := step_impl s t
        assertEq (expected := 100) (actual := getBalance s' 1 10)
          "self-transfer should be balance-preserving"
    }
  , { name := "self-transfer of 1 from balance 1 stays at 1"
    , body := do
        -- Boundary: amount equals balance, sender = receiver.  Without
        -- the §4.11 sequencing, this would compute 1-1+1 = 1 only if
        -- both reads come from the *original* state (over-credit when
        -- different actors, under-credit when same).  The fix makes the
        -- second read see the post-debit value (0), giving 0+1 = 1.
        let s  := fund 1
        let t  := transfer 1 10 10 1
        let s' := step_impl s t
        assertEq (expected := 1) (actual := getBalance s' 1 10)
          "self-transfer with full balance"
    }
  , { name := "rejected transfer is a no-op"
    , body := do
        let s  := fund 5
        let t  := transfer 1 10 20 30
        let s' := step_impl s t
        assertEq (expected := 5) (actual := getBalance s' 1 10) "sender unchanged"
        assertEq (expected := 0) (actual := getBalance s' 1 20) "no credit"
    }
  , { name := "transfer leaves unrelated resources untouched"
    , body := do
        let s0 := setBalance (fund 100) 2 99 7
        let t  := transfer 1 10 20 30
        let s' := step_impl s0 t
        assertEq (expected := 7) (actual := getBalance s' 2 99) "other resource"
    }
  , { name := "transfer leaves unrelated actors untouched"
    , body := do
        let s0 := setBalance (fund 100) 1 99 42
        let t  := transfer 1 10 20 30
        let s' := step_impl s0 t
        assertEq (expected := 42) (actual := getBalance s' 1 99) "other actor"
    }
  , { name := "decidable precondition typeclass resolves"
    , body := do
        -- This is mainly a smoke test that the `decPre` field still
        -- reaches the `Decidable` instance.  At runtime, `decide`
        -- exercises that path.
        let s := fund 100
        let t := transfer 1 10 20 30
        let _ : Decidable (t.pre s) := inferInstance
        pure ()
    }
  , { name := "two sequential legal transfers compose correctly"
    , body := do
        -- Drives the kernel through two `step_impl` applications, then
        -- checks balance invariants pointwise.  Phase 2 lifts the
        -- pointwise check to a TotalSupply-conservation property below.
        let s0 := fund 100
        let t1 := transfer 1 10 20 30
        let t2 := transfer 1 20 30 10
        let s1 := step_impl s0 t1
        let s2 := step_impl s1 t2
        assertEq (expected := 70) (actual := getBalance s2 1 10) "sender"
        assertEq (expected := 20) (actual := getBalance s2 1 20) "middle"
        assertEq (expected := 10) (actual := getBalance s2 1 30) "final"
    }

  -- Phase 2 / WU 2.2 + 2.3: transfer_conserves runtime witnesses.
  , { name := "transfer_conserves: distinct-actor transfer preserves supply"
    , body := do
        let s := fund 100
        let t := transfer 1 10 20 30
        have hpre : t.pre s := by decide
        let _proof : TotalSupply (step_impl s t) 1 = TotalSupply s 1 :=
          transfer_conserves 1 10 20 30 s hpre
        assertEq (expected := TotalSupply s 1)
                 (actual   := TotalSupply (step_impl s t) 1)
                 "supply preserved (distinct actors)"
    }
  , { name := "transfer_conserves: self-transfer preserves supply"
    , body := do
        -- The §4.11 self-transfer fix is what makes this case work:
        -- without the fix, the receiver-side credit would over-count.
        let s := fund 100
        let t := transfer 1 10 10 30
        have hpre : t.pre s := by decide
        let _proof : TotalSupply (step_impl s t) 1 = TotalSupply s 1 :=
          transfer_conserves 1 10 10 30 s hpre
        assertEq (expected := TotalSupply s 1)
                 (actual   := TotalSupply (step_impl s t) 1)
                 "supply preserved (self-transfer)"
    }
  -- Phase 2 / §4.11.2: cross-resource independence runtime witnesses.
  , { name := "transfer_does_not_touch_other_resources: pointwise"
    , body := do
        let s  := setBalance (fund 100) 2 99 7
        let t  := transfer 1 10 20 30
        let s' := step_impl s t
        let _proof : getBalance s' 2 99 = getBalance s 2 99 :=
          transfer_does_not_touch_other_resources 1 2 10 20 30 99 s
            (by decide)
        assertEq (expected := (7 : Nat))
                 (actual   := getBalance s' 2 99)
                 "(2, 99) preserved"
    }
  , { name := "transfer_conserves_other_resource preserves supply at r' ≠ r"
    , body := do
        let s := setBalance (fund 100) 2 99 200
        let t := transfer 1 10 20 30
        let _proof : TotalSupply (step_impl s t) 2 = TotalSupply s 2 :=
          transfer_conserves_other_resource 1 2 10 20 30 s (by decide)
        assertEq (expected := TotalSupply s 2)
                 (actual   := TotalSupply (step_impl s t) 2)
                 "supply at r=2 preserved across transfer at r=1"
    }
  -- Phase 2 / WU 2.4: IsConservative typeclass instance.
  , { name := "transfer is IsConservative (typeclass instance)"
    , body := do
        let _inst : IsConservative (transfer 1 10 20 30) := inferInstance
        pure ()
    }
  -- Phase-4-prelude WU R.19: monotonicity instance check.
  , { name := "transfer_isMonotonic instance resolves"
    , body := do
        let _inst : IsMonotonic (transfer 1 5 7 10) := inferInstance
        pure ()
    }
  ]

end LegalKernel.Test.Laws.TransferTests
