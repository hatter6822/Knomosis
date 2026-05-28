/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.KernelStep — CBE codec for `KernelStep`
(Workstream H WU H.1.5).

The L1 fault-proof game contract consumes the encoded form of a
`KernelStep` when the responding party calls
`terminateOnSingleStep`.  The encoded form is a CBE byte string:

```
preStateCommit  : 32 bytes (CBE bstr; uniform-output ByteArray)
signedAction    : variable, CBE-encoded (per Phase-4)
postStateCommit : 32 bytes (CBE bstr)
cellProofs      : length-prefixed list of CellProof encodings
```

Each `CellProof` encodes as:
```
cellTag      : variable (variant-tag uint + per-variant fields)
cellValue    : CBE bstr
witnessState : CBE-encoded ExtendedState (Phase-4)
```

This module is **not** part of the trusted computing base.
Bugs here would produce incorrect serialisations, but cannot
violate any kernel invariant.
-/

import LegalKernel.Encoding.State
import LegalKernel.Encoding.SignedAction
import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.Step

namespace LegalKernel
namespace Encoding

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority

/-! ## `CellTag` codec

Encoded as `<kindIndex uint> ++ <key fields>`.  The `kindIndex`
is the frozen tag (0..6); the key fields depend on the variant.
-/

/-- Encode a `CellTag` to its CBE byte sequence. -/
def CellTag.encode : FaultProof.CellTag → Stream
  | .balance r a =>
    Encodable.encode (T := Nat) 0 ++
    Encodable.encode (T := Nat) r.toNat ++
    Encodable.encode (T := Nat) a.toNat
  | .nonce a =>
    Encodable.encode (T := Nat) 1 ++
    Encodable.encode (T := Nat) a.toNat
  | .registry a =>
    Encodable.encode (T := Nat) 2 ++
    Encodable.encode (T := Nat) a.toNat
  | .localPolicy a =>
    Encodable.encode (T := Nat) 3 ++
    Encodable.encode (T := Nat) a.toNat
  | .bridgeConsumed d =>
    Encodable.encode (T := Nat) 4 ++
    Encodable.encode (T := Nat) d
  | .bridgePending wd =>
    Encodable.encode (T := Nat) 5 ++
    Encodable.encode (T := Nat) wd
  | .bridgeNextWdId =>
    Encodable.encode (T := Nat) 6

/-- Decode a `CellTag` from a stream.  Returns the tag and
    residual stream.  Rejects unknown variant indices. -/
def CellTag.decode (s : Stream) :
    Except DecodeError (FaultProof.CellTag × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (0, s₁) =>
    -- balance r a
    match Encodable.decode (T := Nat) s₁ with
    | .ok (r, s₂) =>
      match Encodable.decode (T := Nat) s₂ with
      | .ok (a, s₃) =>
        if hr : r < 18446744073709551616 then
          if ha : a < 18446744073709551616 then
            let _ := hr; let _ := ha
            .ok (.balance r.toUInt64 a.toUInt64, s₃)
          else
            let _ := ha
            .error (.invalidLength s!"CellTag.balance actor {a} exceeds 2^64")
        else
          let _ := hr
          .error (.invalidLength s!"CellTag.balance resource {r} exceeds 2^64")
      | .error e => .error e
    | .error e => .error e
  | .ok (1, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (a, s₂) =>
      if ha : a < 18446744073709551616 then
        let _ := ha
        .ok (.nonce a.toUInt64, s₂)
      else
        let _ := ha
        .error (.invalidLength s!"CellTag.nonce actor {a} exceeds 2^64")
    | .error e => .error e
  | .ok (2, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (a, s₂) =>
      if ha : a < 18446744073709551616 then
        let _ := ha
        .ok (.registry a.toUInt64, s₂)
      else
        let _ := ha
        .error (.invalidLength s!"CellTag.registry actor {a} exceeds 2^64")
    | .error e => .error e
  | .ok (3, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (a, s₂) =>
      if ha : a < 18446744073709551616 then
        let _ := ha
        .ok (.localPolicy a.toUInt64, s₂)
      else
        let _ := ha
        .error (.invalidLength s!"CellTag.localPolicy actor {a} exceeds 2^64")
    | .error e => .error e
  | .ok (4, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (d, s₂) => .ok (.bridgeConsumed d, s₂)
    | .error e => .error e
  | .ok (5, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (wd, s₂) => .ok (.bridgePending wd, s₂)
    | .error e => .error e
  | .ok (6, s₁) =>
    .ok (.bridgeNextWdId, s₁)
  | .ok (other, _) => .error (.invalidConstructorIndex other)
  | .error e => .error e

instance : Encodable FaultProof.CellTag where
  encode := CellTag.encode
  decode := CellTag.decode

/-! ## `CellProof` codec -/

/-- Encode a `CellProof`. -/
def CellProof.encode (p : FaultProof.CellProof) : Stream :=
  Encodable.encode (T := FaultProof.CellTag) p.cellTag ++
  Encodable.encode (T := ByteArray) p.cellValue ++
  Encodable.encode (T := ExtendedState) p.witnessState

/-- Decode a `CellProof`. -/
def CellProof.decode (s : Stream) :
    Except DecodeError (FaultProof.CellProof × Stream) :=
  match Encodable.decode (T := FaultProof.CellTag) s with
  | .ok (tag, s₁) =>
    match Encodable.decode (T := ByteArray) s₁ with
    | .ok (val, s₂) =>
      match Encodable.decode (T := ExtendedState) s₂ with
      | .ok (es, s₃) =>
        .ok ({ cellTag := tag, cellValue := val, witnessState := es }, s₃)
      | .error e => .error e
    | .error e => .error e
  | .error e => .error e

instance : Encodable FaultProof.CellProof where
  encode := CellProof.encode
  decode := CellProof.decode

/-! ## `CellProofBundle` codec -/

/-- Encode a `CellProofBundle` as a length-prefixed list of
    cell proofs. -/
def CellProofBundle.encode (b : FaultProof.CellProofBundle) : Stream :=
  Encodable.encode (T := List FaultProof.CellProof) b.proofs

/-- Decode a `CellProofBundle`. -/
def CellProofBundle.decode (s : Stream) :
    Except DecodeError (FaultProof.CellProofBundle × Stream) :=
  match Encodable.decode (T := List FaultProof.CellProof) s with
  | .ok (ps, s₁) => .ok ({ proofs := ps }, s₁)
  | .error e => .error e

instance : Encodable FaultProof.CellProofBundle where
  encode := CellProofBundle.encode
  decode := CellProofBundle.decode

/-! ## `KernelStep` codec -/

/-- Encode a `KernelStep` to its CBE byte sequence.  Layout:
    `preStateCommit ++ signedAction ++ postStateCommit ++
     cellProofs`. -/
def KernelStep.encode (step : FaultProof.KernelStep) : Stream :=
  Encodable.encode (T := ByteArray) step.preStateCommit ++
  Encodable.encode (T := SignedAction) step.signedAction ++
  Encodable.encode (T := ByteArray) step.postStateCommit ++
  Encodable.encode (T := FaultProof.CellProofBundle) step.cellProofs

/-- Decode a `KernelStep` from a stream. -/
def KernelStep.decode (s : Stream) :
    Except DecodeError (FaultProof.KernelStep × Stream) :=
  match Encodable.decode (T := ByteArray) s with
  | .ok (pre, s₁) =>
    match Encodable.decode (T := SignedAction) s₁ with
    | .ok (sa, s₂) =>
      match Encodable.decode (T := ByteArray) s₂ with
      | .ok (post, s₃) =>
        match Encodable.decode (T := FaultProof.CellProofBundle) s₃ with
        | .ok (cb, s₄) =>
          .ok ({ preStateCommit := pre,
                 signedAction := sa,
                 postStateCommit := post,
                 cellProofs := cb }, s₄)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .error e => .error e

instance : Encodable FaultProof.KernelStep where
  encode := KernelStep.encode
  decode := KernelStep.decode

/-! ## Determinism theorems -/

/-- `KernelStep.encode` is deterministic.  Equal steps ⇒ equal
    encoded bytes.  Mechanical via `rfl`. -/
theorem kernelStep_encode_deterministic (s₁ s₂ : FaultProof.KernelStep)
    (h : s₁ = s₂) :
    KernelStep.encode s₁ = KernelStep.encode s₂ := by rw [h]

/-- `CellProof.encode` is deterministic. -/
theorem cellProof_encode_deterministic (p₁ p₂ : FaultProof.CellProof)
    (h : p₁ = p₂) :
    CellProof.encode p₁ = CellProof.encode p₂ := by rw [h]

/-- `CellTag.encode` is deterministic. -/
theorem cellTag_encode_deterministic (t₁ t₂ : FaultProof.CellTag)
    (h : t₁ = t₂) :
    CellTag.encode t₁ = CellTag.encode t₂ := by rw [h]

/-! ## Smoke checks -/

/-- Spot-check: encoding a `CellTag.balance` produces non-empty
    bytes (constructor-tag uint, then field encodings). -/
example : (CellTag.encode (FaultProof.CellTag.balance 1 2)).length > 0 := by decide

/-- Spot-check: encoding `CellTag.bridgeNextWdId` produces a single
    9-byte CBE uint head. -/
example : (CellTag.encode FaultProof.CellTag.bridgeNextWdId).length = 9 := by decide

end Encoding
end LegalKernel
