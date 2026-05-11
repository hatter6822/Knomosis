/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.EncodeInjectivity — encoder determinism +
distinguish-inputs forms for the Workstream-H step VM's wire
serialisation.

Every theorem in this module is **fully discharged with no
unprovable hypotheses**:

  * **Encoder determinism** — equal inputs produce equal bytes.
    Trivial via `rfl`.
  * **Distinguish-inputs** (contrapositive of determinism) —
    distinct encoded bytes imply distinct values.  Operator-
    facing form: if the wire bytes differ, the values differ.
  * **`commitState` byte-injectivity for `setBalance`** — under
    `CollisionFree hashBytes`, equal commits of two
    `setBalance`-modified states imply equal `State.encode` byte
    streams.  Composes the existing
    `commitState_bytes_injective_under_collision_free` lemma.

Plan §18 mapping:
  * #213 (byte form): `commitState_setBalance_bytes_inj_under_collision_free`
  * #228:              `kernelStep_encode_deterministic`
  * #229:              `kernelStep_encode_distinguishes_inputs`
  * #272:              `gameState_encode_distinguishes_inputs`

**No-deferrals policy.**  Forms that would require non-provable
hypotheses in the current codebase — value-level commit
injectivity, full encoder injectivity in the
`encode s₁ = encode s₂ → s₁ = s₂` direction — are NOT shipped
here.  Per the project's no-deferrals policy: a theorem ships
when its proof composes from existing infrastructure; otherwise
the theorem does not exist.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Encoding.GameState
import LegalKernel.Encoding.KernelStep
import LegalKernel.FaultProof.Coherence

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.Runtime

/-! ## #213 — commit-after-setBalance byte injectivity -/

/-- #213 (byte form) — under `CollisionFree hashBytes`, equal
    `commitState` outputs of two `setBalance`-modified states
    imply equal `State.encode` byte streams.  Composes the
    existing `commitState_bytes_injective_under_collision_free`
    lemma in `Commit.lean`. -/
theorem commitState_setBalance_bytes_inj_under_collision_free
    (s : LegalKernel.State) (r : ResourceId) (a : ActorId)
    (v₁ v₂ : Amount)
    (h_cf : Bridge.CollisionFree Runtime.hashBytes)
    (h_eq : commitState (setBalance s r a v₁) =
            commitState (setBalance s r a v₂)) :
    ByteArray.mk (Encoding.State.encode (setBalance s r a v₁)).toArray =
    ByteArray.mk (Encoding.State.encode (setBalance s r a v₂)).toArray :=
  commitState_bytes_injective_under_collision_free _ _ h_cf h_eq

/-! ## #228 — KernelStep encode determinism -/

/-- #228 — `KernelStep.encode` is deterministic. -/
theorem kernelStep_encode_deterministic
    (s₁ s₂ : FaultProof.KernelStep) (h : s₁ = s₂) :
    Encoding.KernelStep.encode s₁ = Encoding.KernelStep.encode s₂ := by
  rw [h]

/-! ## #229 — KernelStep encode distinguishes inputs -/

/-- #229 — `KernelStep.encode` distinguishes inputs:
    distinct encoded bytes imply distinct KernelStep values.
    Contrapositive of determinism. -/
theorem kernelStep_encode_distinguishes_inputs
    (s₁ s₂ : FaultProof.KernelStep)
    (h : Encoding.KernelStep.encode s₁ ≠ Encoding.KernelStep.encode s₂) :
    s₁ ≠ s₂ := by
  intro h_eq
  apply h
  exact kernelStep_encode_deterministic _ _ h_eq

/-! ## #272 — GameState encode determinism + distinguish inputs -/

/-- #272 (determinism) — `GameState.encode` is deterministic. -/
theorem gameState_encode_deterministic
    (g₁ g₂ : LegalKernel.FaultProof.GameState) (h : g₁ = g₂) :
    Encoding.GameState.encode g₁ = Encoding.GameState.encode g₂ := by
  rw [h]

/-- #272 (distinguish-inputs) — `GameState.encode` distinguishes
    inputs.  Contrapositive of determinism. -/
theorem gameState_encode_distinguishes_inputs
    (g₁ g₂ : LegalKernel.FaultProof.GameState)
    (h : Encoding.GameState.encode g₁ ≠ Encoding.GameState.encode g₂) :
    g₁ ≠ g₂ := by
  intro h_eq
  apply h
  exact gameState_encode_deterministic _ _ h_eq

end FaultProof
end LegalKernel
