/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Disputes.LawClassification — `IsConservative` / `IsMonotonic`
classification for the four dispute action constructors.

Phase-6 incentive-integration amendment.  The four dispute action
constructors (`dispute`, `disputeWithdraw`, `verdict`, `rollback`)
all compile to `Laws.freezeResource 0` at the kernel level (see
`Authority/Action.lean`'s `compileTransition` table).  Since
`Laws.freezeResource _` is both `IsConservative` (Phase-2) and
`IsMonotonic` (Phase-4-prelude R.3), the dispute action
constructors are too.

This module materialises that fact as four typeclass instances
each, plus four `_compileTransition_eq_freezeResource_zero`
identification lemmas, plus a composite summary theorem.  The
instances let deployments include the dispute pipeline alongside
existing `ConservativeLawSet` / `MonotonicLawSet` typeclass
firewalls without breaking either invariant — the kernel-level
state advance for any dispute action is identity, so no supply
change can occur.

**Boundary clarification.**  `applyVerdict (.upheld)` performs a
state *replacement* (rollback) at the **runtime** level, NOT
through `apply_admissible`.  The rolled-back state is therefore
NOT in the kernel's `Reachable` / `ReachableViaLaws` relation, and
the headline `total_supply_globally_nondecreasing` theorem makes
no claim about it.  Within `Reachable`, however, every dispute
action is a no-op, and supply non-decrease is preserved.

This module is **not** part of the trusted computing base.  Bugs
here would be type-level only (the typeclass synthesis would fail
or succeed wrongly); the kernel's invariant proofs are unaffected.
-/

import LegalKernel.Authority.Action
import LegalKernel.Conservation
import LegalKernel.Disputes.Types
import LegalKernel.Laws.Freeze

namespace LegalKernel
namespace Disputes

open LegalKernel.Authority
open LegalKernel.Laws

/-! ## Identification lemmas

Each dispute action constructor's `compileTransition` is
*definitionally* equal to `Laws.freezeResource 0` (see
`Authority/Action.lean`'s `compileTransition` cases).  These
lemmas surface that fact as named identifiers so downstream
proofs / instance synthesis can rewrite through them. -/

/-- `Action.dispute d` compiles to `Laws.freezeResource 0`. -/
theorem dispute_compileTransition_eq_freezeResource_zero (d : Dispute) :
    Action.compileTransition (.dispute d) = Laws.freezeResource 0 := rfl

/-- `Action.disputeWithdraw idx` compiles to `Laws.freezeResource 0`. -/
theorem disputeWithdraw_compileTransition_eq_freezeResource_zero
    (idx : LogIndex) :
    Action.compileTransition (.disputeWithdraw idx) = Laws.freezeResource 0 := rfl

/-- `Action.verdict v` compiles to `Laws.freezeResource 0`. -/
theorem verdict_compileTransition_eq_freezeResource_zero (v : Verdict) :
    Action.compileTransition (.verdict v) = Laws.freezeResource 0 := rfl

/-- `Action.rollback idx` compiles to `Laws.freezeResource 0`.

    **Note**: this captures the *kernel-level* compile target.  The
    runtime-level rollback effect (state replacement) happens via
    `applyVerdict` outside `apply_admissible`, NOT through this
    transition. -/
theorem rollback_compileTransition_eq_freezeResource_zero (idx : LogIndex) :
    Action.compileTransition (.rollback idx) = Laws.freezeResource 0 := rfl

/-! ## `IsConservative` instances

Each dispute action constructor's compiled transition preserves
total supply at every resource — a direct consequence of compiling
to `Laws.freezeResource 0` (which is conservative by Phase 2's
`freezeResource_isConservative`). -/

/-- The compiled transition for `.dispute d` is conservative. -/
instance dispute_compiled_isConservative (d : Dispute) :
    IsConservative (Action.compileTransition (.dispute d)) := by
  rw [dispute_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isConservative 0

/-- The compiled transition for `.disputeWithdraw idx` is conservative. -/
instance disputeWithdraw_compiled_isConservative (idx : LogIndex) :
    IsConservative (Action.compileTransition (.disputeWithdraw idx)) := by
  rw [disputeWithdraw_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isConservative 0

/-- The compiled transition for `.verdict v` is conservative. -/
instance verdict_compiled_isConservative (v : Verdict) :
    IsConservative (Action.compileTransition (.verdict v)) := by
  rw [verdict_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isConservative 0

/-- The compiled transition for `.rollback idx` is conservative. -/
instance rollback_compiled_isConservative (idx : LogIndex) :
    IsConservative (Action.compileTransition (.rollback idx)) := by
  rw [rollback_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isConservative 0

/-! ## `IsMonotonic` instances

Analogous to the conservative instances; reuses `freezeResource_isMonotonic`. -/

/-- The compiled transition for `.dispute d` is monotonic. -/
instance dispute_compiled_isMonotonic (d : Dispute) :
    IsMonotonic (Action.compileTransition (.dispute d)) := by
  rw [dispute_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isMonotonic 0

/-- The compiled transition for `.disputeWithdraw idx` is monotonic. -/
instance disputeWithdraw_compiled_isMonotonic (idx : LogIndex) :
    IsMonotonic (Action.compileTransition (.disputeWithdraw idx)) := by
  rw [disputeWithdraw_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isMonotonic 0

/-- The compiled transition for `.verdict v` is monotonic. -/
instance verdict_compiled_isMonotonic (v : Verdict) :
    IsMonotonic (Action.compileTransition (.verdict v)) := by
  rw [verdict_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isMonotonic 0

/-- The compiled transition for `.rollback idx` is monotonic. -/
instance rollback_compiled_isMonotonic (idx : LogIndex) :
    IsMonotonic (Action.compileTransition (.rollback idx)) := by
  rw [rollback_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isMonotonic 0

/-! ## Composite summary

The headline takeaway: the four dispute action constructors are
each both `IsConservative` and `IsMonotonic` at the kernel level.
This composite theorem packs all eight facts into a single
statement for use in deployment-level proofs that want to assert
"the dispute pipeline doesn't break my law-set's classification". -/

/-- Summary: every dispute action constructor's compiled transition
    is both conservative and monotonic.  The eight conjuncts are
    each typeclass-resolvable separately (see the `instance`
    declarations above); this theorem just packages them. -/
theorem dispute_pipeline_actions_classification :
    (∀ d : Dispute,        IsConservative (Action.compileTransition (.dispute d))) ∧
    (∀ idx : LogIndex,     IsConservative (Action.compileTransition (.disputeWithdraw idx))) ∧
    (∀ v : Verdict,        IsConservative (Action.compileTransition (.verdict v))) ∧
    (∀ idx : LogIndex,     IsConservative (Action.compileTransition (.rollback idx))) ∧
    (∀ d : Dispute,        IsMonotonic    (Action.compileTransition (.dispute d))) ∧
    (∀ idx : LogIndex,     IsMonotonic    (Action.compileTransition (.disputeWithdraw idx))) ∧
    (∀ v : Verdict,        IsMonotonic    (Action.compileTransition (.verdict v))) ∧
    (∀ idx : LogIndex,     IsMonotonic    (Action.compileTransition (.rollback idx))) :=
  ⟨fun d   => dispute_compiled_isConservative d,
   fun idx => disputeWithdraw_compiled_isConservative idx,
   fun v   => verdict_compiled_isConservative v,
   fun idx => rollback_compiled_isConservative idx,
   fun d   => dispute_compiled_isMonotonic d,
   fun idx => disputeWithdraw_compiled_isMonotonic idx,
   fun v   => verdict_compiled_isMonotonic v,
   fun idx => rollback_compiled_isMonotonic idx⟩

end Disputes
end LegalKernel
