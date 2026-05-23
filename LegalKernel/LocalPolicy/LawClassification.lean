/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.LocalPolicy.LawClassification — `IsConservative` /
`IsMonotonic` classification for the two LP-introduced action
constructors.

Workstream LP work unit LP.9.  The two LP-introduced action
constructors (`declareLocalPolicy`, `revokeLocalPolicy`) compile to
`Laws.freezeResource 0` at the kernel level (see
`Authority/Action.lean`'s `compileTransition` table).  Since
`Laws.freezeResource _` is both `IsConservative` (Phase-2) and
`IsMonotonic` (Phase-4-prelude R.3), the LP action constructors
are too.

This module materialises that fact as four typeclass instances
plus two `_compileTransition_eq_freezeResource_zero` identification
lemmas plus a composite summary theorem.  The instances let
deployments include the LP pipeline alongside existing
`ConservativeLawSet` / `MonotonicLawSet` typeclass firewalls
without breaking either invariant — the kernel-level state
advance for any LP action is identity, so no supply change can
occur.

**Boundary clarification.**  The LP actions don't touch
kernel-level `State.balances`, but they DO mutate
`ExtendedState.localPolicies`.  The classification here is only
about the kernel-level effect (which is identity); the
authority-level effect (the localPolicies update) is a separate
deployment-level concern and is NOT classified by these
typeclasses.

This module is **not** part of the trusted computing base.  Bugs
here would be type-level only (the typeclass synthesis would fail
or succeed wrongly); the kernel's invariant proofs are unaffected.

Mirrors `LegalKernel/Disputes/LawClassification.lean` in shape and
reasoning.
-/

import LegalKernel.Authority.Action
import LegalKernel.Authority.LocalPolicy
import LegalKernel.Conservation
import LegalKernel.Laws.Freeze

namespace LegalKernel
namespace LocalPolicy

open LegalKernel.Authority
open LegalKernel.Laws

/-! ## Identification lemmas

Each LP action constructor's `compileTransition` is *definitionally*
equal to `Laws.freezeResource 0` (see `Authority/Action.lean`'s
`compileTransition` cases).  These lemmas surface that fact as named
identifiers so downstream proofs / instance synthesis can rewrite
through them. -/

/-- `Action.declareLocalPolicy p` compiles to `Laws.freezeResource 0`. -/
theorem declareLocalPolicy_compileTransition_eq_freezeResource_zero
    (p : Authority.LocalPolicy) :
    Action.compileTransition (.declareLocalPolicy p) = Laws.freezeResource 0 := rfl

/-- `Action.revokeLocalPolicy` compiles to `Laws.freezeResource 0`. -/
theorem revokeLocalPolicy_compileTransition_eq_freezeResource_zero :
    Action.compileTransition .revokeLocalPolicy = Laws.freezeResource 0 := rfl

/-! ## `IsConservative` instances

Each LP action constructor's compiled transition preserves total
supply at every resource — a direct consequence of compiling to
`Laws.freezeResource 0` (which is conservative by Phase 2's
`freezeResource_isConservative`). -/

/-- The compiled transition for `.declareLocalPolicy p` is conservative. -/
instance declareLocalPolicy_compiled_isConservative
    (p : Authority.LocalPolicy) :
    IsConservative (Action.compileTransition (.declareLocalPolicy p)) := by
  rw [declareLocalPolicy_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isConservative 0

/-- The compiled transition for `.revokeLocalPolicy` is conservative. -/
instance revokeLocalPolicy_compiled_isConservative :
    IsConservative (Action.compileTransition .revokeLocalPolicy) := by
  rw [revokeLocalPolicy_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isConservative 0

/-! ## `IsMonotonic` instances

Analogous to the conservative instances; reuses
`freezeResource_isMonotonic`. -/

/-- The compiled transition for `.declareLocalPolicy p` is monotonic. -/
instance declareLocalPolicy_compiled_isMonotonic
    (p : Authority.LocalPolicy) :
    IsMonotonic (Action.compileTransition (.declareLocalPolicy p)) := by
  rw [declareLocalPolicy_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isMonotonic 0

/-- The compiled transition for `.revokeLocalPolicy` is monotonic. -/
instance revokeLocalPolicy_compiled_isMonotonic :
    IsMonotonic (Action.compileTransition .revokeLocalPolicy) := by
  rw [revokeLocalPolicy_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isMonotonic 0

/-! ## Composite summary

A single theorem packing the four instances for use in
deployment-level proofs.  Each conjunct exposes the corresponding
typeclass instance via `inferInstance`, so call sites can extract
exactly the fact they need without re-deriving the synthesis chain. -/

/-- LP.9: composite classification of the two LP action ctors:
    each compiles to a conservative AND monotonic transition.
    Useful for deployment-level proofs that want to assert the
    full classification at one place. -/
theorem local_policy_actions_classification :
    (∀ p : Authority.LocalPolicy,
        IsConservative (Action.compileTransition (.declareLocalPolicy p))) ∧
    (∀ p : Authority.LocalPolicy,
        IsMonotonic (Action.compileTransition (.declareLocalPolicy p))) ∧
    IsConservative (Action.compileTransition .revokeLocalPolicy) ∧
    IsMonotonic (Action.compileTransition .revokeLocalPolicy) :=
  ⟨fun _ => inferInstance,
   fun _ => inferInstance,
   inferInstance,
   inferInstance⟩

end LocalPolicy
end LegalKernel
