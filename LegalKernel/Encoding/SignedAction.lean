/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.SignedAction — `Encodable` instance for `SignedAction`.

Phase 4 WU 4.4 + WU 4.6 + WU 4.7.  The `SignedAction` structure (an
`Action` plus signer / nonce / signature) is the canonical wire form
that the runtime (Phase 5) accepts over the network.  This module
provides the canonical bytes for that wire form.

Genesis Plan §8.8.3 specifies a CBOR map encoding with sorted keys:

  ```
  SignedAction → CBOR map { 0: action, 1: signer, 2: nonce, 3: sig }
  ```

CBE (Phase 4's simpler binary encoding) uses the same field-ordering
discipline (canonically sorted) but encodes as a *fixed* sequence
rather than a tagged map: `[action, signer, nonce, sig]`.  The
canonicalisation property is identical (one byte sequence per value)
because the field order is fixed at the type level.

**Dispute/Verdict deferral.**  The Genesis Plan §8.8.3 also lists
`Dispute` and `Verdict` map encodings, but those types are Phase 6
deliverables (not yet defined).  Phase 4 ships only `SignedAction`'s
encoding; `Dispute` / `Verdict` will be added in Phase 6 when those
types land.

This module is **not** part of the trusted computing base.  Bugs
here produce wrong serialisations, but cannot violate any kernel
invariant.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.Action

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority

/-! ## Numerical bound predicate -/

/-- Canonical-encoding bound on every numeric / byte field of a
    `SignedAction`.  Combines `Action.fieldsBounded` with bounds on
    `signer`, `nonce`, and `sig.size`. -/
def SignedAction.fieldsBounded (st : SignedAction) : Prop :=
  Action.fieldsBounded st.action ∧
  st.signer.toNat < 256 ^ 8 ∧
  st.nonce < 256 ^ 8 ∧
  st.sig.size < 256 ^ 8

/-- Decidability of `SignedAction.fieldsBounded`. -/
instance SignedAction.decFieldsBounded (st : SignedAction) :
    Decidable (SignedAction.fieldsBounded st) := by
  unfold SignedAction.fieldsBounded
  exact inferInstance

/-! ## Encoder

CBE form: `[action, signer, nonce, sig]` — concatenation of the
field encodings in declaration order.

**Decoder bound discipline.**  The `decode` function reads fields
without enforcing the canonical `< 2^64` bound on `nonce` — `nonce :
Nat` is unbounded at the type level, so a maliciously crafted CBE
stream could decode to a `SignedAction` whose `nonce ≥ 2^64`.
Re-encoding such a value would silently truncate (the `cborHeadEncode`
helper writes only the low 8 bytes), breaking encode-then-decode
idempotence.

This is *not* a confidentiality / integrity issue: the kernel's
`Admissible` predicate (Genesis Plan §8.2 condition 4) requires
`st.nonce = expectsNonce es st.signer`, and `expectsNonce` returns
the actor's `expectsNonce`-tracked value (always `< 2^64` in
practice).  An out-of-bound `nonce` at the *signing input* layer
fails admissibility downstream.

The runtime adaptor (Phase 5) MUST gate on
`SignedAction.fieldsBounded` after decoding and before invoking
`apply_admissible`, to reject malicious streams at the boundary
rather than at the much-later admissibility check. -/

/-- Encode a `SignedAction` as `[action ++ signer ++ nonce ++ sig]`. -/
def SignedAction.encode (st : SignedAction) : Stream :=
  Encodable.encode (T := Action) st.action ++
  Encodable.encode (T := Nat) st.signer.toNat ++
  Encodable.encode (T := Nat) st.nonce ++
  Encodable.encode (T := ByteArray) st.sig

/-- Decode a `SignedAction` from the front of `s`. -/
def SignedAction.decode (s : Stream) : Except DecodeError (SignedAction × Stream) :=
  match Encodable.decode (T := Action) s with
  | .ok (action, s₁) =>
    match Action.readUInt64Field s₁ with
    | .ok (signer, s₂) =>
      match Action.readNatField s₂ with
      | .ok (nonce, s₃) =>
        match Encodable.decode (T := ByteArray) s₃ with
        | .ok (sig, s₄) => .ok ({ action, signer, nonce, sig }, s₄)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .error e => .error e

instance instEncodableSignedAction : Encodable SignedAction where
  encode := SignedAction.encode
  decode := SignedAction.decode

/-! ## Round-trip + injectivity

The proof composes the per-field round-trips: `action_roundtrip` for
the `Action` prefix, `readUInt64Field_roundtrip` (re-used from
`Encoding.Action`) for the `signer` field, `readNatField_roundtrip`
for the `nonce` field, and `byteArray_roundtrip` for the `sig`
suffix.  No new lemmas are needed — the SignedAction round-trip is
purely compositional. -/

/-- Round-trip with suffix for `SignedAction`, conditional on
    `fieldsBounded`.

    Note on the `hSigner` clause of `fieldsBounded`: `signer.toNat <
    2^64` is automatic since `signer : UInt64`; we accept the
    explicit bound in the predicate for symmetry with
    `Action.fieldsBounded` and so a future migration to a
    `BoundedNat`-typed `signer` can keep the same predicate shape
    without API churn. -/
theorem signedAction_roundtrip (st : SignedAction) (rest : Stream)
    (h : SignedAction.fieldsBounded st) :
    Encodable.decode (T := SignedAction) (Encodable.encode st ++ rest) = .ok (st, rest) := by
  obtain ⟨hAction, _hSigner, hNonce, hSig⟩ := h
  show SignedAction.decode (SignedAction.encode st ++ rest) = .ok (st, rest)
  unfold SignedAction.encode SignedAction.decode
  rw [show
    Encodable.encode (T := Action) st.action ++ Encodable.encode (T := Nat) st.signer.toNat ++
      Encodable.encode (T := Nat) st.nonce ++ Encodable.encode (T := ByteArray) st.sig ++ rest =
    Encodable.encode (T := Action) st.action ++
      (Encodable.encode (T := Nat) st.signer.toNat ++
        (Encodable.encode (T := Nat) st.nonce ++
          (Encodable.encode (T := ByteArray) st.sig ++ rest)))
      from by simp [List.append_assoc]]
  rw [show (Encodable.decode (T := Action) (Encodable.encode (T := Action) st.action ++ _))
    = .ok (st.action, _) from action_roundtrip st.action _ hAction]
  dsimp only
  rw [readUInt64Field_roundtrip st.signer _]
  dsimp only
  rw [readNatField_roundtrip st.nonce _ hNonce]
  dsimp only
  rw [byteArray_roundtrip st.sig rest hSig]

/-- Empty-suffix round-trip for `SignedAction`. -/
theorem signedAction_roundtrip_empty (st : SignedAction)
    (h : SignedAction.fieldsBounded st) :
    Encodable.decode (T := SignedAction) (Encodable.encode st) = .ok (st, []) := by
  have := signedAction_roundtrip st [] h
  simpa using this

/-- `SignedAction` injectivity (bounded). -/
theorem signedAction_encode_injective (st₁ st₂ : SignedAction)
    (h₁ : SignedAction.fieldsBounded st₁) (h₂ : SignedAction.fieldsBounded st₂)
    (h : Encodable.encode (T := SignedAction) st₁ = Encodable.encode (T := SignedAction) st₂) :
    st₁ = st₂ := by
  have r₁ := signedAction_roundtrip_empty st₁ h₁
  have r₂ := signedAction_roundtrip_empty st₂ h₂
  rw [h] at r₁
  have heq : (Except.ok (st₁, ([] : Stream)) : Except DecodeError (SignedAction × Stream))
           = Except.ok (st₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

end Encoding
end LegalKernel
