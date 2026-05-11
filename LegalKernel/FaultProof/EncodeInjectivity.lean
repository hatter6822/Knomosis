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

For `commitState`, `KernelStep.encode`, and `GameState.encode`,
this module ships the **practical** content provable
unconditionally:

  * **Encoder determinism** — equal inputs produce equal bytes.
    Trivial via `rfl`.
  * **Distinguish-inputs (contrapositive of determinism)** —
    distinct encoded bytes imply distinct values.  This is the
    operator-facing form: if the wire bytes differ, the values
    differ.

For the **dual direction** (full encoder injectivity:
`encode s₁ = encode s₂ → s₁ = s₂`), this module ships
round-trip-conditional packagers under `_via_roundtrip` suffixes.
These become substantive when the underlying State round-trip
ships; until then, the round-trip hypotheses cannot be
discharged for arbitrary inputs (per `Encoding/State.lean`'s
explicit deferral comment regarding `TreeMap.ofList ∘ toList`
equality-up-to-equivalence).

For `commitState` specifically, the byte-injectivity form
`commitState_setBalance_bytes_inj_under_collision_free` ships
unconditionally: under `CollisionFree hashBytes`, equal commits
of two `setBalance`-modified states imply equal `State.encode`
byte streams.  The value-level form (`v₁ = v₂`) is the
round-trip-conditional packager.

Plan §18 mapping:
  * #213 (byte form): `commitState_setBalance_bytes_inj_under_collision_free`
  * #213 (value form): `commitState_after_setBalance_value_injective`
                       (round-trip-conditional packager)
  * #228:              `kernelStep_encode_deterministic_strong`
  * #229 (practical):  `kernelStep_encode_distinguishes_inputs`
  * #229 (full inj):   `kernelStep_encode_injective_via_roundtrip`
                       (round-trip-conditional packager)
  * #272 (practical):  `gameState_encode_distinguishes_inputs`
  * #272 (full inj):   `gameState_encode_injective_via_roundtrip`
                       (round-trip-conditional packager)

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

/-! ## #213 — commit-after-setBalance byte injectivity (unconditional) -/

/-- #213 (byte form) — under `CollisionFree hashBytes`, equal
    `commitState` outputs of two `setBalance`-modified states
    imply equal `State.encode` byte streams.  Substantive content
    proved unconditionally via the existing
    `commitState_bytes_injective_under_collision_free` lemma in
    `Commit.lean`. -/
theorem commitState_setBalance_bytes_inj_under_collision_free
    (s : LegalKernel.State) (r : ResourceId) (a : ActorId)
    (v₁ v₂ : Amount)
    (h_cf : Bridge.CollisionFree Runtime.hashBytes)
    (h_eq : commitState (setBalance s r a v₁) =
            commitState (setBalance s r a v₂)) :
    ByteArray.mk (Encoding.State.encode (setBalance s r a v₁)).toArray =
    ByteArray.mk (Encoding.State.encode (setBalance s r a v₂)).toArray :=
  commitState_bytes_injective_under_collision_free _ _ h_cf h_eq

/-- #213 (value form, round-trip-conditional packager) — under
    `CollisionFree hashBytes` AND State round-trip on both
    `setBalance` results, equal commits imply equal values.
    **Round-trip hypotheses are not yet provable for arbitrary
    states**; this packager becomes substantive when the State
    round-trip ships (multi-day deferred work per
    `Encoding/State.lean`). -/
theorem commitState_after_setBalance_value_injective
    (s : LegalKernel.State) (r : ResourceId) (a : ActorId)
    (v₁ v₂ : Amount)
    (h_cf : Bridge.CollisionFree Runtime.hashBytes)
    (h_rt₁ : Encoding.State.decode
              (Encoding.State.encode (setBalance s r a v₁)) =
              .ok (setBalance s r a v₁, []))
    (h_rt₂ : Encoding.State.decode
              (Encoding.State.encode (setBalance s r a v₂)) =
              .ok (setBalance s r a v₂, []))
    (h_eq : commitState (setBalance s r a v₁) =
            commitState (setBalance s r a v₂)) :
    v₁ = v₂ := by
  have h_bytes :=
    commitState_bytes_injective_under_collision_free
      (setBalance s r a v₁) (setBalance s r a v₂) h_cf h_eq
  have h_arr_eq :
      (Encoding.State.encode (setBalance s r a v₁)).toArray =
      (Encoding.State.encode (setBalance s r a v₂)).toArray :=
    ByteArray.mk.inj h_bytes
  have h_stream :
      Encoding.State.encode (setBalance s r a v₁) =
      Encoding.State.encode (setBalance s r a v₂) := by
    have := congrArg Array.toList h_arr_eq
    simpa using this
  rw [h_stream] at h_rt₁
  have h_ok :
      (Except.ok (setBalance s r a v₁, [])
        : Except Encoding.DecodeError _) =
      .ok (setBalance s r a v₂, []) := h_rt₁.symm.trans h_rt₂
  have h_pair :
      ((setBalance s r a v₁), ([] : Encoding.Stream)) =
      ((setBalance s r a v₂), []) := Except.ok.inj h_ok
  have h_state_eq : setBalance s r a v₁ = setBalance s r a v₂ :=
    (Prod.mk.inj h_pair).1
  have h_v₁ : getBalance (setBalance s r a v₁) r a = v₁ :=
    getBalance_setBalance_same s r a v₁
  have h_v₂ : getBalance (setBalance s r a v₂) r a = v₂ :=
    getBalance_setBalance_same s r a v₂
  calc v₁ = getBalance (setBalance s r a v₁) r a := h_v₁.symm
    _ = getBalance (setBalance s r a v₂) r a := by rw [h_state_eq]
    _ = v₂ := h_v₂

/-! ## #228 / #229 — KernelStep encoder properties -/

/-- #228 — `KernelStep.encode` is deterministic. -/
theorem kernelStep_encode_deterministic_strong
    (s₁ s₂ : FaultProof.KernelStep) (h : s₁ = s₂) :
    Encoding.KernelStep.encode s₁ = Encoding.KernelStep.encode s₂ := by
  rw [h]

/-- #229 (practical) — `KernelStep.encode` distinguishes inputs.
    Contrapositive of determinism: distinct encoded bytes imply
    distinct KernelStep values.  Provable unconditionally. -/
theorem kernelStep_encode_distinguishes_inputs
    (s₁ s₂ : FaultProof.KernelStep)
    (h : Encoding.KernelStep.encode s₁ ≠ Encoding.KernelStep.encode s₂) :
    s₁ ≠ s₂ := by
  intro h_eq
  apply h
  exact kernelStep_encode_deterministic_strong _ _ h_eq

/-- #229 (round-trip-conditional packager) — `KernelStep.encode`
    is injective.  Round-trip hypotheses are NOT yet provable
    until the State round-trip ships. -/
theorem kernelStep_encode_injective_via_roundtrip
    (s₁ s₂ : FaultProof.KernelStep)
    (h₁ : Encoding.KernelStep.decode (Encoding.KernelStep.encode s₁) =
            .ok (s₁, []))
    (h₂ : Encoding.KernelStep.decode (Encoding.KernelStep.encode s₂) =
            .ok (s₂, []))
    (h_eq : Encoding.KernelStep.encode s₁ = Encoding.KernelStep.encode s₂) :
    s₁ = s₂ := by
  rw [← h_eq] at h₂
  have h_ok : (Except.ok (s₁, []) : Except Encoding.DecodeError _) =
              Except.ok (s₂, []) := h₁.symm.trans h₂
  have h_pair : (s₁, ([] : Encoding.Stream)) = (s₂, []) :=
    Except.ok.inj h_ok
  exact (Prod.mk.inj h_pair).1

/-- #229 corollary — contrapositive of the round-trip packager. -/
theorem kernelStep_encode_distinguishes_via_roundtrip
    (s₁ s₂ : FaultProof.KernelStep)
    (h₁ : Encoding.KernelStep.decode (Encoding.KernelStep.encode s₁) =
            .ok (s₁, []))
    (h₂ : Encoding.KernelStep.decode (Encoding.KernelStep.encode s₂) =
            .ok (s₂, []))
    (h_neq : s₁ ≠ s₂) :
    Encoding.KernelStep.encode s₁ ≠ Encoding.KernelStep.encode s₂ := by
  intro h_eq
  exact h_neq (kernelStep_encode_injective_via_roundtrip s₁ s₂ h₁ h₂ h_eq)

/-! ## #272 — GameState encoder properties -/

/-- #272 — `GameState.encode` is deterministic. -/
theorem gameState_encode_deterministic_strong
    (g₁ g₂ : LegalKernel.FaultProof.GameState) (h : g₁ = g₂) :
    Encoding.GameState.encode g₁ = Encoding.GameState.encode g₂ := by
  rw [h]

/-- #272 (practical) — `GameState.encode` distinguishes inputs.
    Contrapositive of determinism. -/
theorem gameState_encode_distinguishes_inputs
    (g₁ g₂ : LegalKernel.FaultProof.GameState)
    (h : Encoding.GameState.encode g₁ ≠ Encoding.GameState.encode g₂) :
    g₁ ≠ g₂ := by
  intro h_eq
  apply h
  exact gameState_encode_deterministic_strong _ _ h_eq

/-- #272 (round-trip-conditional packager) — `GameState.encode`
    is injective. -/
theorem gameState_encode_injective_via_roundtrip
    (g₁ g₂ : LegalKernel.FaultProof.GameState)
    (h₁ : Encoding.GameState.decode (Encoding.GameState.encode g₁) =
            .ok (g₁, []))
    (h₂ : Encoding.GameState.decode (Encoding.GameState.encode g₂) =
            .ok (g₂, []))
    (h_eq : Encoding.GameState.encode g₁ = Encoding.GameState.encode g₂) :
    g₁ = g₂ := by
  rw [← h_eq] at h₂
  have h_ok : (Except.ok (g₁, []) : Except Encoding.DecodeError _) =
              Except.ok (g₂, []) := h₁.symm.trans h₂
  have h_pair : (g₁, ([] : Encoding.Stream)) = (g₂, []) :=
    Except.ok.inj h_ok
  exact (Prod.mk.inj h_pair).1

/-- #272 corollary — contrapositive of the round-trip packager. -/
theorem gameState_encode_distinguishes_via_roundtrip
    (g₁ g₂ : LegalKernel.FaultProof.GameState)
    (h₁ : Encoding.GameState.decode (Encoding.GameState.encode g₁) =
            .ok (g₁, []))
    (h₂ : Encoding.GameState.decode (Encoding.GameState.encode g₂) =
            .ok (g₂, []))
    (h_neq : g₁ ≠ g₂) :
    Encoding.GameState.encode g₁ ≠ Encoding.GameState.encode g₂ := by
  intro h_eq
  exact h_neq (gameState_encode_injective_via_roundtrip g₁ g₂ h₁ h₂ h_eq)

end FaultProof
end LegalKernel
