/-
  Canon  - A Societal Kernel
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
field encodings in declaration order. -/

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

/-! ## Round-trip + injectivity -/

private theorem readUInt64Field_via_nat (n : UInt64) (rest : Stream) :
    Action.readUInt64Field (Encodable.encode (T := Nat) n.toNat ++ rest) = .ok (n, rest) := by
  unfold Action.readUInt64Field
  have hbound : n.toNat < 256 ^ 8 := by
    have : n.toNat < 2 ^ 64 := UInt64.toNat_lt n
    have h256 : (256 : Nat) ^ 8 = 2 ^ 64 := by decide
    omega
  rw [nat_roundtrip n.toNat rest hbound]
  dsimp only
  have hp : n.toNat < 18446744073709551616 := by
    have : (2 : Nat) ^ 64 = 18446744073709551616 := by decide
    have : n.toNat < 2 ^ 64 := UInt64.toNat_lt n
    omega
  rw [dif_pos hp]
  congr 1
  congr 1
  show UInt64.ofNat n.toNat = n
  exact UInt64.ofNat_toNat

/-- Round-trip with suffix for `SignedAction`, conditional on
    `fieldsBounded`. -/
theorem signedAction_roundtrip (st : SignedAction) (rest : Stream)
    (h : SignedAction.fieldsBounded st) :
    Encodable.decode (T := SignedAction) (Encodable.encode st ++ rest) = .ok (st, rest) := by
  obtain ⟨hAction, hSigner, hNonce, hSig⟩ := h
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
  rw [readUInt64Field_via_nat st.signer _]
  dsimp only
  unfold Action.readNatField
  rw [nat_roundtrip st.nonce _ hNonce]
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
