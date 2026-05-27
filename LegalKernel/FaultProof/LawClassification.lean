/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.LawClassification — `IsConservative` /
`IsMonotonic` classification for the two fault-proof action
constructors.

Workstream H §12.1.  Both `faultProofChallenge` and
`faultProofResolution` compile to `Laws.freezeResource 0` at the
kernel level (advisory L2 actions whose authoritative effect lives
in the L1 game contract).  Mirrors the Phase-6 dispute-pipeline
pattern (`Disputes.LawClassification`): identification lemmas
followed by typeclass instances followed by a composite summary
theorem.

Lets deployments include the fault-proof pipeline alongside
existing `ConservativeLawSet` / `MonotonicLawSet` typeclass
firewalls without breaking either invariant — the kernel-level
state advance for any fault-proof action is identity, so no
supply change can occur.

This module is **not** part of the trusted computing base.  Bugs
here would be type-level only (the typeclass synthesis would fail
or succeed wrongly); the kernel's invariant proofs are unaffected.
-/

import LegalKernel.Authority.Action
import LegalKernel.Conservation
import LegalKernel.Disputes.Types
import LegalKernel.Laws.Freeze

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Laws

/-! ## Identification lemmas -/

/-- Workstream H: `Action.faultProofChallenge` compiles to
    `Laws.freezeResource 0`.  The `bindingHash` /
    `disputedStartIdx` / `disputedEndIdx` / `challengerCommit`
    fields are payload only; they don't affect the kernel-level
    transition. -/
theorem faultProofChallenge_compileTransition_eq_freezeResource_zero
    (bh : ByteArray) (sIdx eIdx : Disputes.LogIndex)
    (cc : ByteArray) :
    Action.compileTransition (.faultProofChallenge bh sIdx eIdx cc) =
      Laws.freezeResource 0 := rfl

/-- Workstream H: `Action.faultProofResolution` compiles to
    `Laws.freezeResource 0`. -/
theorem faultProofResolution_compileTransition_eq_freezeResource_zero
    (bh : ByteArray) (gid : Nat) (winner : ActorId)
    (rfi : Disputes.LogIndex) :
    Action.compileTransition (.faultProofResolution bh gid winner rfi) =
      Laws.freezeResource 0 := rfl

/-! ## `IsConservative` instances -/

/-- The compiled transition for `.faultProofChallenge` is
    conservative — the kernel-level advance is identity, so no
    resource's total supply changes. -/
instance faultProofChallenge_compiled_isConservative
    (bh : ByteArray) (sIdx eIdx : Disputes.LogIndex)
    (cc : ByteArray) :
    IsConservative (Action.compileTransition
                      (.faultProofChallenge bh sIdx eIdx cc)) := by
  rw [faultProofChallenge_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isConservative 0

/-- The compiled transition for `.faultProofResolution` is
    conservative. -/
instance faultProofResolution_compiled_isConservative
    (bh : ByteArray) (gid : Nat) (winner : ActorId)
    (rfi : Disputes.LogIndex) :
    IsConservative (Action.compileTransition
                      (.faultProofResolution bh gid winner rfi)) := by
  rw [faultProofResolution_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isConservative 0

/-! ## `IsMonotonic` instances -/

/-- The compiled transition for `.faultProofChallenge` is monotonic. -/
instance faultProofChallenge_compiled_isMonotonic
    (bh : ByteArray) (sIdx eIdx : Disputes.LogIndex)
    (cc : ByteArray) :
    IsMonotonic (Action.compileTransition
                   (.faultProofChallenge bh sIdx eIdx cc)) := by
  rw [faultProofChallenge_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isMonotonic 0

/-- The compiled transition for `.faultProofResolution` is monotonic. -/
instance faultProofResolution_compiled_isMonotonic
    (bh : ByteArray) (gid : Nat) (winner : ActorId)
    (rfi : Disputes.LogIndex) :
    IsMonotonic (Action.compileTransition
                   (.faultProofResolution bh gid winner rfi)) := by
  rw [faultProofResolution_compileTransition_eq_freezeResource_zero]
  exact freezeResource_isMonotonic 0

/-! ## Composite summary -/

/-- Workstream H summary: every fault-proof action constructor's
    compiled transition is both conservative and monotonic.  The
    four conjuncts are each typeclass-resolvable separately (see
    the `instance` declarations above); this theorem packages them
    for use in deployment-level proofs that want to assert "the
    fault-proof pipeline doesn't break my law-set's classification". -/
theorem fault_proof_pipeline_actions_classification :
    (∀ bh sIdx eIdx cc,
        IsConservative (Action.compileTransition
                          (.faultProofChallenge bh sIdx eIdx cc))) ∧
    (∀ bh gid winner rfi,
        IsConservative (Action.compileTransition
                          (.faultProofResolution bh gid winner rfi))) ∧
    (∀ bh sIdx eIdx cc,
        IsMonotonic (Action.compileTransition
                       (.faultProofChallenge bh sIdx eIdx cc))) ∧
    (∀ bh gid winner rfi,
        IsMonotonic (Action.compileTransition
                       (.faultProofResolution bh gid winner rfi))) :=
  ⟨fun bh sIdx eIdx cc =>
      faultProofChallenge_compiled_isConservative bh sIdx eIdx cc,
   fun bh gid w rfi =>
      faultProofResolution_compiled_isConservative bh gid w rfi,
   fun bh sIdx eIdx cc =>
      faultProofChallenge_compiled_isMonotonic bh sIdx eIdx cc,
   fun bh gid w rfi =>
      faultProofResolution_compiled_isMonotonic bh gid w rfi⟩

end FaultProof
end LegalKernel
