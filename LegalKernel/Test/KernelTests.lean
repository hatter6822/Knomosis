/-
LegalKernel.Test.KernelTests — unit tests for the Phase-0 kernel.

These tests exercise the *value-level* behaviour of the kernel:
`getBalance` / `setBalance` round-trips, `step_impl` decidability,
no-op when the precondition fails, `apply_certified` agreement, and
both `Reachable` constructors.  They do NOT exercise the
propositional theorems (those are checked at elaboration time by
Lean itself; if `Kernel.lean` builds, the theorems are proved).

The plan's WU 0.2 acceptance ("`lake build LegalKernel.Kernel`
succeeds; no `sorry` in the module") is a *compile-time* check; this
file adds a *run-time* check that the implementation behaves as the
specification says it should.
-/

import LegalKernel.Kernel
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Test

namespace LegalKernel.Test.KernelTests

/-- A trivial transition that is unconditionally legal and adds 1 unit
    of resource `r` to actor `a`.  Used to drive the `step_impl` /
    `apply_certified` paths. -/
def alwaysLegalCredit (r : ResourceId) (a : ActorId) : Transition where
  pre        := fun _ => True
  decPre     := fun _ => inferInstance
  apply_impl := fun s => setBalance s r a (getBalance s r a + 1)

/-- A trivial transition whose precondition is unconditionally false;
    used to exercise `impl_noop_if_not_pre` at runtime. -/
def neverLegal : Transition where
  pre        := fun _ => False
  decPre     := fun _ => inferInstance
  apply_impl := fun s => s -- unreachable; included for totality

/-- Tests for the core kernel module. -/
def tests : List TestCase :=
  [ { name := "getBalance on empty state is 0"
    , body := do
        assertEq (expected := 0) (actual := getBalance emptyState 0 0)
          "empty state should report zero"
    }
  , { name := "setBalance / getBalance same key round-trip"
    , body := do
        let s := setBalance emptyState 7 42 100
        assertEq (expected := 100) (actual := getBalance s 7 42) "after set"
    }
  , { name := "setBalance / getBalance different actor unchanged"
    , body := do
        let s := setBalance emptyState 7 42 100
        assertEq (expected := 0) (actual := getBalance s 7 99)
          "other actor in same resource"
    }
  , { name := "setBalance / getBalance different resource unchanged"
    , body := do
        let s := setBalance emptyState 7 42 100
        assertEq (expected := 0) (actual := getBalance s 8 42)
          "same actor in different resource"
    }
  , { name := "setBalance overwrite"
    , body := do
        let s  := setBalance emptyState 7 42 100
        let s' := setBalance s 7 42 5
        assertEq (expected := 5) (actual := getBalance s' 7 42) "after second set"
    }
  , { name := "setBalance leaves other-resource entries intact"
    , body := do
        -- Seed two different resources with two different actors; the
        -- second `setBalance` must not touch the first.
        let s0 := setBalance emptyState 1 1 11
        let s1 := setBalance s0 2 2 22
        assertEq (expected := 11) (actual := getBalance s1 1 1) "(1,1) preserved"
        assertEq (expected := 22) (actual := getBalance s1 2 2) "(2,2) inserted"
    }
  , { name := "step_impl applies transformer when precondition holds"
    , body := do
        let t := alwaysLegalCredit 1 2
        let s := step_impl emptyState t
        assertEq (expected := 1) (actual := getBalance s 1 2) "credited"
    }
  , { name := "step_impl is no-op when precondition fails"
    , body := do
        let s := step_impl emptyState neverLegal
        -- Equality on `State` is not decidable in general, but
        -- behavioural equality at every accessor we can name suffices.
        assertEq (expected := 0) (actual := getBalance s 0 0) "no credit"
        assertEq (expected := 0) (actual := getBalance s 99 99) "no other change"
    }
  , { name := "apply_certified agrees with apply_impl on a legal step"
    , body := do
        let t  := alwaysLegalCredit 5 6
        let ct : CertifiedTransition emptyState := ⟨t, ⟨trivial⟩⟩
        let s  := apply_certified emptyState ct
        assertEq (expected := 1) (actual := getBalance s 5 6) "certified credit"
    }
  , { name := "apply_certified value matches step_impl on every probe"
    , body := do
        -- Theorem `apply_certified_eq_step_impl` proves these states
        -- equal propositionally; this is a cheap regression test on
        -- the executable path that catches any future divergence.
        let t  := alwaysLegalCredit 7 8
        let ct : CertifiedTransition emptyState := ⟨t, ⟨trivial⟩⟩
        let sCert := apply_certified emptyState ct
        let sImpl := step_impl emptyState t
        assertEq (expected := getBalance sImpl 7 8)
                 (actual   := getBalance sCert 7 8) "at (7,8)"
        assertEq (expected := getBalance sImpl 99 99)
                 (actual   := getBalance sCert 99 99) "at (99,99) (untouched)"
    }
  , { name := "Reachable.base holds for the initial state"
    , body := do
        -- Term construction is the assertion: if elaboration fails the
        -- test file would not compile.
        let _proof : Reachable emptyState emptyState := Reachable.base
        pure ()
    }
  , { name := "Reachable.step extends Reachable by one legal step"
    , body := do
        -- Build a depth-1 reachability witness.  `trivial : True` is
        -- the precondition proof (`alwaysLegalCredit.pre _ = True`).
        let t := alwaysLegalCredit 3 4
        let _proof : Reachable emptyState (step_impl emptyState t) :=
          Reachable.step emptyState t Reachable.base trivial
        pure ()
    }

  -- Phase 1 / WU 1.5: balance lemma value-level smoke tests.
  , { name := "getBalance_setBalance_same on representative inputs"
    , body := do
        -- The theorem proves the value-level equation; this test
        -- catches any future definitional-equality regression on
        -- the executable path.
        let s := setBalance emptyState 1 2 999
        assertEq (expected := (999 : Nat))
                 (actual   := getBalance s 1 2)
                 "round-trip at (1, 2)"
    }
  , { name := "getBalance_setBalance_other on different resource"
    , body := do
        let s0 := setBalance emptyState 1 2 100
        let s1 := setBalance s0 5 6 200
        -- Reading (1, 2) after the second setBalance should still be 100.
        assertEq (expected := (100 : Nat))
                 (actual   := getBalance s1 1 2)
                 "(1, 2) preserved after write at (5, 6)"
    }
  , { name := "getBalance_setBalance_other on different actor"
    , body := do
        let s0 := setBalance emptyState 1 2 100
        let s1 := setBalance s0 1 99 250
        -- Reading (1, 2) after the second setBalance at (1, 99) should be 100.
        assertEq (expected := (100 : Nat))
                 (actual   := getBalance s1 1 2)
                 "(1, 2) preserved after write at (1, 99)"
    }

  -- Phase 1 / WU 1.7: multi-step reachability properties.
  , { name := "Reachable.trans composes two reachability witnesses"
    , body := do
        let t := alwaysLegalCredit 3 4
        let s₁ := step_impl emptyState t
        let s₂ := step_impl s₁ t
        -- Step 0 → 1 and 1 → 2 each individually.
        let h₀₁ : Reachable emptyState s₁ :=
          Reachable.step emptyState t Reachable.base trivial
        let h₁₂ : Reachable s₁ s₂ :=
          Reachable.step s₁ t Reachable.base trivial
        let _proof : Reachable emptyState s₂ := Reachable.trans h₀₁ h₁₂
        pure ()
    }
  , { name := "Reachable.refl is a left identity for Reachable.trans"
    , body := do
        -- This exercises the WU 1.7 named theorem `Reachable.refl`
        -- directly (rather than its definitional equality with
        -- `Reachable.base`, which `Reachable.base holds for the
        -- initial state` already covers).
        let t := alwaysLegalCredit 5 6
        let h₀₁ : Reachable emptyState (step_impl emptyState t) :=
          Reachable.step emptyState t Reachable.base trivial
        let _proof : Reachable emptyState (step_impl emptyState t) :=
          Reachable.trans (Reachable.refl emptyState) h₀₁
        pure ()
    }

  -- Phase 1 / WU 1.8: ReachableViaLaws constructors and embedding.
  , { name := "ReachableViaLaws.base for any law set"
    , body := do
        let L : List Transition := [alwaysLegalCredit 1 2]
        let _proof : ReachableViaLaws L emptyState emptyState :=
          ReachableViaLaws.base
        pure ()
    }
  , { name := "ReachableViaLaws.step requires t ∈ L"
    , body := do
        let t  := alwaysLegalCredit 1 2
        let L  : List Transition := [t]
        -- `Or.inl rfl` is the membership witness for the head of L.
        let _proof :
            ReachableViaLaws L emptyState (step_impl emptyState t) :=
          ReachableViaLaws.step emptyState t (List.mem_singleton.mpr rfl)
            ReachableViaLaws.base trivial
        pure ()
    }
  , { name := "ReachableViaLaws embeds into Reachable"
    , body := do
        -- The `reachable_of_reachable_via_laws` theorem maps every
        -- `ReachableViaLaws L`-witness to a `Reachable`-witness; this
        -- test drives that path through the `step` constructor.
        let t  := alwaysLegalCredit 1 2
        let L  : List Transition := [t]
        let hL : ReachableViaLaws L emptyState (step_impl emptyState t) :=
          ReachableViaLaws.step emptyState t (List.mem_singleton.mpr rfl)
            ReachableViaLaws.base trivial
        let _proof : Reachable emptyState (step_impl emptyState t) :=
          reachable_of_reachable_via_laws hL
        pure ()
    }

  -- Phase 1 / WU 1.9: invariant_preservation_via_laws.
  , { name := "invariant_preservation_via_laws preserves the trivial invariant"
    , body := do
        -- Term construction is the assertion: if `invariant_preservation_via_laws`
        -- ever changes signature, this elaboration fails.  We instantiate the
        -- theorem with the trivially-true invariant (`fun _ => True`); the
        -- proof obligation reduces to `trivial`.
        let t  := alwaysLegalCredit 1 2
        let L  : List Transition := [t]
        let _holds : ∀ s, ReachableViaLaws L emptyState s → (fun _ : State => True) s :=
          invariant_preservation_via_laws (fun _ => True) L emptyState
            trivial
            (fun _ _ _ _ _ => trivial)
        pure ()
    }
  , { name := "invariant_preservation_via_laws derives I s from a witness"
    , body := do
        -- Construct a depth-1 ReachableViaLaws witness, feed it through
        -- `invariant_preservation_via_laws`, and check the resulting
        -- `I s` is the trivially-true `True`.  This drives the
        -- inductive *step* case at runtime, not just the base case.
        let t  := alwaysLegalCredit 1 2
        let L  : List Transition := [t]
        let s₁ := step_impl emptyState t
        let hL : ReachableViaLaws L emptyState s₁ :=
          ReachableViaLaws.step emptyState t (List.mem_singleton.mpr rfl)
            ReachableViaLaws.base trivial
        let _trueAt : (fun _ : State => True) s₁ :=
          invariant_preservation_via_laws (fun _ => True) L emptyState
            trivial (fun _ _ _ _ _ => trivial) s₁ hL
        pure ()
    }
  ]

end LegalKernel.Test.KernelTests
