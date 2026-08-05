-- SPDX-License-Identifier: GPL-3.0-or-later
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
preStateCommit  : 9 + 32   (CBE bstr: 9-byte head + 32-byte payload)
signedAction    : variable, CBE-encoded (per Phase-4)
postStateCommit : 9 + 32
cellProofs      : CBE array head (9 bytes, the count) followed by
                  that many CellProof encodings
```

Each `CellProof` encodes as:
```
cellTag      : 9 (variant tag) + 9 per key field
               (balance: 2 keys; nonce / registry / localPolicy /
                bridgeConsumed / bridgePending: 1; bridgeNextWdId: 0)
cellValue    : 9 + len   (CBE bstr)
witnessState : CBE-encoded ExtendedState (Phase-4)
```

The commits are 32-byte payloads behind a 9-byte CBE bytestring
head, not bare 32-byte fields; the previous header omitted every
head.  Likewise the cell-proof bundle carries a CBE array head, not
a bare length prefix.

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
is the frozen tag (0..16); the key fields depend on the
variant.  Singleton cells encode the tag alone.
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
  | .bridgeAmmReserveEth        => Encodable.encode (T := Nat) 7
  | .bridgeAmmReserveBold       => Encodable.encode (T := Nat) 8
  | .bridgeBoldCircuitClosed    => Encodable.encode (T := Nat) 9
  | .bridgeBoldTvlCap           => Encodable.encode (T := Nat) 10
  | .bridgeBoldTotalLockedValue => Encodable.encode (T := Nat) 11
  | .bridgeAmmDisabled          => Encodable.encode (T := Nat) 12
  | .epochBudget a =>
    Encodable.encode (T := Nat) 13 ++
    Encodable.encode (T := Nat) a.toNat
  | .budgetPolicy               => Encodable.encode (T := Nat) 14

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
  -- Tags 7..14: the AMM mirror, the BOLD circuit-breaker trio, the
  -- kill switch, the per-actor epoch budget and the budget policy.
  -- All but `epochBudget` are singleton cells, so the tag alone is
  -- the whole encoding and the residual stream passes through.
  | .ok (7, s₁)  => .ok (.bridgeAmmReserveEth, s₁)
  | .ok (8, s₁)  => .ok (.bridgeAmmReserveBold, s₁)
  | .ok (9, s₁)  => .ok (.bridgeBoldCircuitClosed, s₁)
  | .ok (10, s₁) => .ok (.bridgeBoldTvlCap, s₁)
  | .ok (11, s₁) => .ok (.bridgeBoldTotalLockedValue, s₁)
  | .ok (12, s₁) => .ok (.bridgeAmmDisabled, s₁)
  | .ok (13, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (a, s₂) =>
      if ha : a < 18446744073709551616 then
        let _ := ha
        .ok (.epochBudget a.toUInt64, s₂)
      else
        let _ := ha
        .error (.invalidLength s!"CellTag.epochBudget actor {a} exceeds 2^64")
    | .error e => .error e
  | .ok (14, s₁) => .ok (.budgetPolicy, s₁)
  | .ok (other, _) => .error (.invalidConstructorIndex other)
  | .error e => .error e

instance : Encodable FaultProof.CellTag where
  encode := CellTag.encode
  decode := CellTag.decode

/-- The field bounds `CellTag`'s round-trip needs.

    `ActorId` and `ResourceId` are `UInt64` (`Kernel.lean`), so their
    `toNat` sits below the 8-byte head's modulus by construction and
    costs no conjunct.  `DepositId` and `WithdrawalId` are bare `Nat`
    (`Bridge/State.lean`), so the two bridge-set cells carry the only
    real obligation — the same shape as
    `LocalPolicyClause.fieldsBounded`. -/
def CellTag.fieldsBounded : FaultProof.CellTag → Prop
  | .bridgeConsumed d  => d < 256 ^ 8
  | .bridgePending wd  => wd < 256 ^ 8
  | _                  => True

/-- Decidability of `CellTag.fieldsBounded`: every branch is either
    `True` or a single `Nat` comparison. -/
instance (t : FaultProof.CellTag) : Decidable (CellTag.fieldsBounded t) := by
  cases t <;> (unfold CellTag.fieldsBounded; infer_instance)

/-- A `UInt64`-typed key always fits the 8-byte CBE uint head. -/
private theorem uint64_key_lt_head (a : UInt64) : a.toNat < 256 ^ 8 := by
  have h64 : (256 : Nat) ^ 8 = 2 ^ 64 := by decide
  have : a.toNat < 2 ^ 64 := UInt64.toNat_lt a
  omega

/-- **`CellTag` round-trips.**  Decoding an encoded tag returns that
    tag and leaves the residual stream untouched.

    This is what `cellTag_encode_deterministic` is not: determinism is
    `t₁ = t₂ → encode t₁ = encode t₂`, which holds of every function
    and so establishes nothing about the codec.  The round-trip is the
    statement the decoder can fail — and did, for the eight tags
    (7..14) whose arms were missing while `encode` emitted them.  Since
    every action writes an `.epochBudget` cell (tag 13) and every
    frontier leads with `.budgetPolicy` (tag 14), the gap covered the
    majority of real bundles. -/
theorem cellTag_roundtrip (t : FaultProof.CellTag) (rest : Stream)
    (h : CellTag.fieldsBounded t) :
    CellTag.decode (CellTag.encode t ++ rest) = .ok (t, rest) := by
  cases t with
  | balance r a =>
    show CellTag.decode
      (Encodable.encode (T := Nat) 0 ++ Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := Nat) a.toNat ++ rest) = _
    unfold CellTag.decode
    rw [show
      Encodable.encode (T := Nat) 0 ++ Encodable.encode (T := Nat) r.toNat ++
          Encodable.encode (T := Nat) a.toNat ++ rest =
        Encodable.encode (T := Nat) 0 ++
          (Encodable.encode (T := Nat) r.toNat ++
            (Encodable.encode (T := Nat) a.toNat ++ rest))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 0 _ (by decide)]
    dsimp only
    rw [nat_roundtrip r.toNat _ (uint64_key_lt_head r)]
    dsimp only
    rw [nat_roundtrip a.toNat _ (uint64_key_lt_head a)]
    dsimp only
    rw [dif_pos (by have := uint64_key_lt_head r; omega),
        dif_pos (by have := uint64_key_lt_head a; omega)]
    simp [UInt64.ofNat_toNat]
  | nonce a =>
    show CellTag.decode
      (Encodable.encode (T := Nat) 1 ++ Encodable.encode (T := Nat) a.toNat ++ rest) = _
    unfold CellTag.decode
    rw [show
      Encodable.encode (T := Nat) 1 ++ Encodable.encode (T := Nat) a.toNat ++ rest =
        Encodable.encode (T := Nat) 1 ++
          (Encodable.encode (T := Nat) a.toNat ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 1 _ (by decide)]
    dsimp only
    rw [nat_roundtrip a.toNat _ (uint64_key_lt_head a)]
    dsimp only
    rw [dif_pos (by have := uint64_key_lt_head a; omega)]
    simp [UInt64.ofNat_toNat]
  | registry a =>
    show CellTag.decode
      (Encodable.encode (T := Nat) 2 ++ Encodable.encode (T := Nat) a.toNat ++ rest) = _
    unfold CellTag.decode
    rw [show
      Encodable.encode (T := Nat) 2 ++ Encodable.encode (T := Nat) a.toNat ++ rest =
        Encodable.encode (T := Nat) 2 ++
          (Encodable.encode (T := Nat) a.toNat ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 2 _ (by decide)]
    dsimp only
    rw [nat_roundtrip a.toNat _ (uint64_key_lt_head a)]
    dsimp only
    rw [dif_pos (by have := uint64_key_lt_head a; omega)]
    simp [UInt64.ofNat_toNat]
  | localPolicy a =>
    show CellTag.decode
      (Encodable.encode (T := Nat) 3 ++ Encodable.encode (T := Nat) a.toNat ++ rest) = _
    unfold CellTag.decode
    rw [show
      Encodable.encode (T := Nat) 3 ++ Encodable.encode (T := Nat) a.toNat ++ rest =
        Encodable.encode (T := Nat) 3 ++
          (Encodable.encode (T := Nat) a.toNat ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 3 _ (by decide)]
    dsimp only
    rw [nat_roundtrip a.toNat _ (uint64_key_lt_head a)]
    dsimp only
    rw [dif_pos (by have := uint64_key_lt_head a; omega)]
    simp [UInt64.ofNat_toNat]
  | bridgeConsumed d =>
    have hd : d < 256 ^ 8 := h
    show CellTag.decode
      (Encodable.encode (T := Nat) 4 ++ Encodable.encode (T := Nat) d ++ rest) = _
    unfold CellTag.decode
    rw [show
      Encodable.encode (T := Nat) 4 ++ Encodable.encode (T := Nat) d ++ rest =
        Encodable.encode (T := Nat) 4 ++ (Encodable.encode (T := Nat) d ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 4 _ (by decide)]
    dsimp only
    rw [nat_roundtrip d rest hd]
  | bridgePending wd =>
    have hw : wd < 256 ^ 8 := h
    show CellTag.decode
      (Encodable.encode (T := Nat) 5 ++ Encodable.encode (T := Nat) wd ++ rest) = _
    unfold CellTag.decode
    rw [show
      Encodable.encode (T := Nat) 5 ++ Encodable.encode (T := Nat) wd ++ rest =
        Encodable.encode (T := Nat) 5 ++ (Encodable.encode (T := Nat) wd ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 5 _ (by decide)]
    dsimp only
    rw [nat_roundtrip wd rest hw]
  | bridgeNextWdId =>
    show CellTag.decode (Encodable.encode (T := Nat) 6 ++ rest) = _
    unfold CellTag.decode
    rw [nat_roundtrip 6 rest (by decide)]
  | bridgeAmmReserveEth =>
    show CellTag.decode (Encodable.encode (T := Nat) 7 ++ rest) = _
    unfold CellTag.decode
    rw [nat_roundtrip 7 rest (by decide)]
  | bridgeAmmReserveBold =>
    show CellTag.decode (Encodable.encode (T := Nat) 8 ++ rest) = _
    unfold CellTag.decode
    rw [nat_roundtrip 8 rest (by decide)]
  | bridgeBoldCircuitClosed =>
    show CellTag.decode (Encodable.encode (T := Nat) 9 ++ rest) = _
    unfold CellTag.decode
    rw [nat_roundtrip 9 rest (by decide)]
  | bridgeBoldTvlCap =>
    show CellTag.decode (Encodable.encode (T := Nat) 10 ++ rest) = _
    unfold CellTag.decode
    rw [nat_roundtrip 10 rest (by decide)]
  | bridgeBoldTotalLockedValue =>
    show CellTag.decode (Encodable.encode (T := Nat) 11 ++ rest) = _
    unfold CellTag.decode
    rw [nat_roundtrip 11 rest (by decide)]
  | bridgeAmmDisabled =>
    show CellTag.decode (Encodable.encode (T := Nat) 12 ++ rest) = _
    unfold CellTag.decode
    rw [nat_roundtrip 12 rest (by decide)]
  | epochBudget a =>
    show CellTag.decode
      (Encodable.encode (T := Nat) 13 ++ Encodable.encode (T := Nat) a.toNat ++ rest) = _
    unfold CellTag.decode
    rw [show
      Encodable.encode (T := Nat) 13 ++ Encodable.encode (T := Nat) a.toNat ++ rest =
        Encodable.encode (T := Nat) 13 ++
          (Encodable.encode (T := Nat) a.toNat ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 13 _ (by decide)]
    dsimp only
    rw [nat_roundtrip a.toNat _ (uint64_key_lt_head a)]
    dsimp only
    rw [dif_pos (by have := uint64_key_lt_head a; omega)]
    simp [UInt64.ofNat_toNat]
  | budgetPolicy =>
    show CellTag.decode (Encodable.encode (T := Nat) 14 ++ rest) = _
    unfold CellTag.decode
    rw [nat_roundtrip 14 rest (by decide)]

/-! ## `CellProof` codec -/

/-- Encode a `CellProof`. -/
def CellProof.encode (p : FaultProof.CellProof) : Stream :=
  Encodable.encode (T := FaultProof.CellTag) p.cellTag ++
  Encodable.encode (T := ByteArray) p.cellValue ++
  Encodable.encode (T := ExtendedState) p.witnessState ++
  Encodable.encode (T := ByteArray) p.proofData

/-- Decode a `CellProof`. -/
def CellProof.decode (s : Stream) :
    Except DecodeError (FaultProof.CellProof × Stream) :=
  match Encodable.decode (T := FaultProof.CellTag) s with
  | .ok (tag, s₁) =>
    match Encodable.decode (T := ByteArray) s₁ with
    | .ok (val, s₂) =>
      match Encodable.decode (T := ExtendedState) s₂ with
      | .ok (es, s₃) =>
        match Encodable.decode (T := ByteArray) s₃ with
        | .ok (pd, s₄) =>
          .ok ({ cellTag := tag, cellValue := val, witnessState := es,
                 proofData := pd }, s₄)
        | .error e => .error e
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

/-! ## `SmtCellProof` and `CellOpening` codecs

The `KernelStep` a fault-proof game carries is a bundle of OPENINGS,
not of witness-state-bearing cell proofs, so its codec needs these
two.  An `SmtCellProof` is its sibling array and its bitmask; a
`CellOpening` is a cell identity, the cell's value in the state the
opening is against, and the path. -/

/-- Encode an `SmtCellProof`: the siblings as a length-prefixed list,
    then the bitmask. -/
def SmtCellProof.encode (p : FaultProof.SmtCellProof) : Stream :=
  Encodable.encode (T := List ByteArray) p.siblings.toList ++
  Encodable.encode (T := ByteArray) p.bitmask

/-- Decode an `SmtCellProof`. -/
def SmtCellProof.decode (s : Stream) :
    Except DecodeError (FaultProof.SmtCellProof × Stream) :=
  match Encodable.decode (T := List ByteArray) s with
  | .ok (sibs, s₁) =>
    match Encodable.decode (T := ByteArray) s₁ with
    | .ok (bm, s₂) => .ok ({ siblings := sibs.toArray, bitmask := bm }, s₂)
    | .error e     => .error e
  | .error e => .error e

instance : Encodable FaultProof.SmtCellProof where
  encode := SmtCellProof.encode
  decode := SmtCellProof.decode

/-- Encode a `CellOpening`. -/
def CellOpening.encode (o : FaultProof.CellOpening) : Stream :=
  Encodable.encode (T := FaultProof.CellTag) o.cellTag ++
  Encodable.encode (T := ByteArray) o.preValue ++
  Encodable.encode (T := FaultProof.SmtCellProof) o.proof

/-- Decode a `CellOpening`. -/
def CellOpening.decode (s : Stream) :
    Except DecodeError (FaultProof.CellOpening × Stream) :=
  match Encodable.decode (T := FaultProof.CellTag) s with
  | .ok (tag, s₁) =>
    match Encodable.decode (T := ByteArray) s₁ with
    | .ok (val, s₂) =>
      match Encodable.decode (T := FaultProof.SmtCellProof) s₂ with
      | .ok (pf, s₃) =>
        .ok ({ cellTag := tag, preValue := val, proof := pf }, s₃)
      | .error e => .error e
    | .error e => .error e
  | .error e => .error e

instance : Encodable FaultProof.CellOpening where
  encode := CellOpening.encode
  decode := CellOpening.decode

/-! ## `SmtMultiProof` + `MultiBundle` codecs

The multiproof wire, in the same shape as `SmtCellProof`'s: the
sibling list then the mask.  One structural difference is worth
naming — an `SmtCellProof`'s mask is always 32 bytes, while a
multiproof's is `ceil(G/8)` for a gap count the KEY SET determines, so
the decoder cannot check the length and the verifier does
(`SmtMultiProof.isWellFormedFor`, against levels it derives). -/

/-- Encode an `SmtMultiProof`. -/
def SmtMultiProof.encode (p : FaultProof.SmtMultiProof) : Stream :=
  Encodable.encode (T := List ByteArray) p.siblings.toList ++
  Encodable.encode (T := ByteArray) p.gapMask

/-- Decode an `SmtMultiProof`. -/
def SmtMultiProof.decode (s : Stream) :
    Except DecodeError (FaultProof.SmtMultiProof × Stream) :=
  match Encodable.decode (T := List ByteArray) s with
  | .ok (sibs, s₁) =>
    match Encodable.decode (T := ByteArray) s₁ with
    | .ok (gm, s₂) => .ok ({ siblings := sibs.toArray, gapMask := gm }, s₂)
    | .error e     => .error e
  | .error e => .error e

instance : Encodable FaultProof.SmtMultiProof where
  encode := SmtMultiProof.encode
  decode := SmtMultiProof.decode

/-- Encode one opened cell: its tag and its proven PRE-value.  No
    proof of its own — under a multiproof every cell is opened against
    the same root and they share one sibling list. -/
def OpenedCell.encode (c : FaultProof.CellTag × ByteArray) : Stream :=
  Encodable.encode (T := FaultProof.CellTag) c.1 ++
  Encodable.encode (T := ByteArray) c.2

/-- Decode one opened cell. -/
def OpenedCell.decode (s : Stream) :
    Except DecodeError ((FaultProof.CellTag × ByteArray) × Stream) :=
  match Encodable.decode (T := FaultProof.CellTag) s with
  | .ok (tag, s₁) =>
    match Encodable.decode (T := ByteArray) s₁ with
    | .ok (val, s₂) => .ok ((tag, val), s₂)
    | .error e      => .error e
  | .error e => .error e

instance : Encodable (FaultProof.CellTag × ByteArray) where
  encode := OpenedCell.encode
  decode := OpenedCell.decode

/-- Encode a `MultiBundle`: the opened cells, then the shared wire. -/
def MultiBundle.encode (b : FaultProof.MultiBundle) : Stream :=
  Encodable.encode (T := List (FaultProof.CellTag × ByteArray)) b.cells ++
  Encodable.encode (T := FaultProof.SmtMultiProof) b.proof

/-- Decode a `MultiBundle`. -/
def MultiBundle.decode (s : Stream) :
    Except DecodeError (FaultProof.MultiBundle × Stream) :=
  match Encodable.decode (T := List (FaultProof.CellTag × ByteArray)) s with
  | .ok (cells, s₁) =>
    match Encodable.decode (T := FaultProof.SmtMultiProof) s₁ with
    | .ok (pf, s₂) => .ok ({ cells := cells, proof := pf }, s₂)
    | .error e     => .error e
  | .error e => .error e

instance : Encodable FaultProof.MultiBundle where
  encode := MultiBundle.encode
  decode := MultiBundle.decode

/-! ## `KernelStep` codec -/

/-- Encode a `KernelStep` to its CBE byte sequence.  Layout:
    `preStateCommit ++ signedAction ++ postStateCommit ++
     l2LogIndex ++ bundle`. -/
def KernelStep.encode (step : FaultProof.KernelStep) : Stream :=
  Encodable.encode (T := ByteArray) step.preStateCommit ++
  Encodable.encode (T := SignedAction) step.signedAction ++
  Encodable.encode (T := ByteArray) step.postStateCommit ++
  Encodable.encode (T := Nat) step.l2LogIndex ++
  Encodable.encode (T := FaultProof.MultiBundle) step.bundle

/-- Decode a `KernelStep` from a stream. -/
def KernelStep.decode (s : Stream) :
    Except DecodeError (FaultProof.KernelStep × Stream) :=
  match Encodable.decode (T := ByteArray) s with
  | .ok (pre, s₁) =>
    match Encodable.decode (T := SignedAction) s₁ with
    | .ok (sa, s₂) =>
      match Encodable.decode (T := ByteArray) s₂ with
      | .ok (post, s₃) =>
        match Encodable.decode (T := Nat) s₃ with
        | .ok (idx, s₄) =>
          match Encodable.decode (T := FaultProof.MultiBundle) s₄ with
          | .ok (b, s₅) =>
            .ok ({ preStateCommit := pre,
                   signedAction := sa,
                   postStateCommit := post,
                   l2LogIndex := idx,
                   bundle := b }, s₅)
          | .error e => .error e
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
