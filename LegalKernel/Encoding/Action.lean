/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.Action — `Encodable` instance for `Action`.

Phase 4 WU 4.3 + WU 4.6 + WU 4.7.  The `Action` inductive (defined
in `Authority/Action.lean`) is the boundary between the kernel's
operational `Transition`-shape and the deployment's first-order
data shape.  Every signed action that crosses a network, a disk, or
a signature lives in `Action`-space; this module provides the
canonical bytes for that space.

Encoding scheme (per Genesis Plan §8.8.3):

  * Each `Action` is encoded as a constructor-tag uint (0..7) followed
    by the constructor's field encodings in declaration order.
  * Constructor indices are *frozen*: they match the inductive's
    declaration order.  Adding a new constructor must append at the
    end.

The constructor-tag map (frozen):

  | Tag | Constructor          | Fields (in order)                                       |
  |-----|----------------------|---------------------------------------------------------|
  | 0   | `transfer`           | `r`, `sender`, `receiver`, `amount`                     |
  | 1   | `mint`               | `r`, `to`, `amount`                                     |
  | 2   | `burn`               | `r`, `fromActor`, `amount`                              |
  | 3   | `freezeResource`     | `r`                                                     |
  | 4   | `replaceKey`         | `actor`, `newKey` (CBE bstr)                            |
  | 5   | `reward`             | `r`, `to`, `amount`                                     |
  | 6   | `distributeOthers`   | `r`, `excluded`, `amount`                               |
  | 7   | `proportionalDilute` | `r`, `excluded`, `totalReward`                          |
  | 8   | `dispute`            | `Dispute` (encoded via `Encoding.Disputes`)             |
  | 9   | `disputeWithdraw`    | `idx`                                                   |
  | 10  | `verdict`            | `Verdict` (encoded via `Encoding.Disputes`)             |
  | 11  | `rollback`           | `targetIdx`                                             |
  | 12  | `registerIdentity`   | `actor`, `pk` (CBE bstr)                                |

The `Action.fieldsBounded` predicate captures the canonical-encoding
bound (`< 2^64`) on every numeric field.  Round-trip and injectivity
hold for `Action`s that satisfy `fieldsBounded`; outside that range
the encoder is total but lossy.  Phase 5's runtime adaptor must gate
on `fieldsBounded` before applying `encode`.

This module is **not** part of the trusted computing base.  Bugs
here produce wrong serialisations, but cannot violate any kernel
invariant.
-/

import LegalKernel.Authority.Action
import LegalKernel.Encoding.Encodable
import LegalKernel.Encoding.Disputes

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority
open LegalKernel.Disputes

/-! ## Numerical bound predicate

`Action.fieldsBounded a` holds when every numeric field of `a` fits
in canonical CBE's 8-byte uint form (`< 2^64`).  Phase 5's runtime
adaptor gates on this before serialising. -/

/-- The canonical-encoding bound (`< 2^64`) on every numeric field
    of `a`.  For `replaceKey`, the public key's byte length is the
    relevant bound.  For dispute / verdict actions, the bound is
    delegated to the inner type's `fieldsBounded`. -/
def Action.fieldsBounded : Action → Prop
  | .transfer r s r' a            =>
      r.toNat < 256 ^ 8 ∧ s.toNat < 256 ^ 8 ∧ r'.toNat < 256 ^ 8 ∧ a < 256 ^ 8
  | .mint r to a                  =>
      r.toNat < 256 ^ 8 ∧ to.toNat < 256 ^ 8 ∧ a < 256 ^ 8
  | .burn r fr a                  =>
      r.toNat < 256 ^ 8 ∧ fr.toNat < 256 ^ 8 ∧ a < 256 ^ 8
  | .freezeResource r             => r.toNat < 256 ^ 8
  | .replaceKey actor newKey      => actor.toNat < 256 ^ 8 ∧ newKey.size < 256 ^ 8
  | .reward r to a                =>
      r.toNat < 256 ^ 8 ∧ to.toNat < 256 ^ 8 ∧ a < 256 ^ 8
  | .distributeOthers r e a       =>
      r.toNat < 256 ^ 8 ∧ e.toNat < 256 ^ 8 ∧ a < 256 ^ 8
  | .proportionalDilute r e tr    =>
      r.toNat < 256 ^ 8 ∧ e.toNat < 256 ^ 8 ∧ tr < 256 ^ 8
  | .dispute d                    => Dispute.fieldsBounded d
  | .disputeWithdraw idx          => idx < 256 ^ 8
  | .verdict v                    => Verdict.fieldsBounded v ∧ Verdict.canonical v
  | .rollback idx                 => idx < 256 ^ 8
  | .registerIdentity actor pk    => actor.toNat < 256 ^ 8 ∧ pk.size < 256 ^ 8
  | .deposit r recipient amount d =>
      r.toNat < 256 ^ 8 ∧ recipient.toNat < 256 ^ 8 ∧
      amount < 256 ^ 8 ∧ d < 256 ^ 8
  | .withdraw r sender amount _rcp =>
      -- Audit-2: `recipientL1` is encoded as a 20-byte ByteArray
      -- (lossless via `EthAddress.toBytes`); no per-field bound
      -- needed (the EthAddress's bound `< 2^160` is enforced at
      -- the type level via `Fin (2^160)`, and the 20-byte encoded
      -- form is `< 2^64` unconditionally).
      r.toNat < 256 ^ 8 ∧ sender.toNat < 256 ^ 8 ∧
      amount < 256 ^ 8

/-- Decidable instance for `fieldsBounded`.  Each branch reduces to
    a finite conjunction of `Nat <` comparisons, so `Decidable`
    follows from `inferInstance` on each branch. -/
instance Action.decFieldsBounded (a : Action) : Decidable (Action.fieldsBounded a) := by
  cases a <;> unfold Action.fieldsBounded <;> infer_instance

/-! ## Encoder -/

/-- Encode an `Action` as constructor-tag + fields.  Total on every
    `Action` value; lossy (modular truncation) on numeric fields
    `≥ 2^64`. -/
def Action.encode : Action → Stream
  | .transfer r s r' a            =>
      Encodable.encode (T := Nat) 0 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := Nat) s.toNat ++
      Encodable.encode (T := Nat) r'.toNat ++
      Encodable.encode (T := Nat) a
  | .mint r to a                  =>
      Encodable.encode (T := Nat) 1 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := Nat) to.toNat ++
      Encodable.encode (T := Nat) a
  | .burn r fr a                  =>
      Encodable.encode (T := Nat) 2 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := Nat) fr.toNat ++
      Encodable.encode (T := Nat) a
  | .freezeResource r             =>
      Encodable.encode (T := Nat) 3 ++
      Encodable.encode (T := Nat) r.toNat
  | .replaceKey actor newKey      =>
      Encodable.encode (T := Nat) 4 ++
      Encodable.encode (T := Nat) actor.toNat ++
      Encodable.encode (T := ByteArray) newKey
  | .reward r to a                =>
      Encodable.encode (T := Nat) 5 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := Nat) to.toNat ++
      Encodable.encode (T := Nat) a
  | .distributeOthers r e a       =>
      Encodable.encode (T := Nat) 6 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := Nat) e.toNat ++
      Encodable.encode (T := Nat) a
  | .proportionalDilute r e tr    =>
      Encodable.encode (T := Nat) 7 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := Nat) e.toNat ++
      Encodable.encode (T := Nat) tr
  | .dispute d                    =>
      Encodable.encode (T := Nat) 8 ++
      Encodable.encode (T := Dispute) d
  | .disputeWithdraw idx          =>
      Encodable.encode (T := Nat) 9 ++
      Encodable.encode (T := Nat) idx
  | .verdict v                    =>
      Encodable.encode (T := Nat) 10 ++
      Encodable.encode (T := Verdict) v
  | .rollback idx                 =>
      Encodable.encode (T := Nat) 11 ++
      Encodable.encode (T := Nat) idx
  | .registerIdentity actor pk    =>
      Encodable.encode (T := Nat) 12 ++
      Encodable.encode (T := Nat) actor.toNat ++
      Encodable.encode (T := ByteArray) pk
  | .deposit r recipient amount d =>
      Encodable.encode (T := Nat) 13 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := Nat) recipient.toNat ++
      Encodable.encode (T := Nat) amount ++
      Encodable.encode (T := Nat) d
  | .withdraw r sender amount rcp =>
      -- Audit-2: encode `recipientL1` as a 20-byte BE ByteArray
      -- (CBE byte string), losslessly representing the full 160-bit
      -- Ethereum address.  The pre-audit Nat encoding truncated to
      -- 64 bits — making two distinct EthAddresses sharing low
      -- 64 bits indistinguishable in `signingInput`, enabling
      -- signature replay.
      Encodable.encode (T := Nat) 14 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := Nat) sender.toNat ++
      Encodable.encode (T := Nat) amount ++
      Encodable.encode (T := ByteArray) (Bridge.EthAddress.toBytes rcp)

/-! ## Decoder -/

/-- Read a `Nat` field from the stream and assert it fits in `UInt64`. -/
def Action.readUInt64Field (s : Stream) :
    Except DecodeError (UInt64 × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (n, rest) =>
    if h : n < 18446744073709551616 then
      .ok (n.toUInt64, rest)
    else
      let _ := h
      .error (.invalidLength s!"Action field {n} exceeds 2^64")
  | .error e => .error e

/-- Read a `Nat` field from the stream (used for `Amount`, which is a
    `Nat` and so unbounded at the type level, but bounded in practice
    by `fieldsBounded`). -/
def Action.readNatField (s : Stream) :
    Except DecodeError (Nat × Stream) :=
  Encodable.decode (T := Nat) s

/-- Decode an `Action` from the front of `s`.  Returns the recovered
    `Action` and the residual stream. -/
def Action.decode (s : Stream) : Except DecodeError (Action × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (0, s₁) =>
    -- transfer (r, sender, receiver, amount)
    match Action.readUInt64Field s₁ with
    | .ok (r, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (sender, s₃) =>
        match Action.readUInt64Field s₃ with
        | .ok (receiver, s₄) =>
          match Action.readNatField s₄ with
          | .ok (amount, s₅) => .ok (.transfer r sender receiver amount, s₅)
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (1, s₁) =>
    -- mint (r, to, amount)
    match Action.readUInt64Field s₁ with
    | .ok (r, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (to, s₃) =>
        match Action.readNatField s₃ with
        | .ok (amount, s₄) => .ok (.mint r to amount, s₄)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (2, s₁) =>
    -- burn (r, fromActor, amount)
    match Action.readUInt64Field s₁ with
    | .ok (r, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (fr, s₃) =>
        match Action.readNatField s₃ with
        | .ok (amount, s₄) => .ok (.burn r fr amount, s₄)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (3, s₁) =>
    -- freezeResource (r)
    match Action.readUInt64Field s₁ with
    | .ok (r, s₂) => .ok (.freezeResource r, s₂)
    | .error e => .error e
  | .ok (4, s₁) =>
    -- replaceKey (actor, newKey)
    match Action.readUInt64Field s₁ with
    | .ok (actor, s₂) =>
      match Encodable.decode (T := ByteArray) s₂ with
      | .ok (newKey, s₃) => .ok (.replaceKey actor newKey, s₃)
      | .error e => .error e
    | .error e => .error e
  | .ok (5, s₁) =>
    -- reward (r, to, amount)
    match Action.readUInt64Field s₁ with
    | .ok (r, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (to, s₃) =>
        match Action.readNatField s₃ with
        | .ok (amount, s₄) => .ok (.reward r to amount, s₄)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (6, s₁) =>
    -- distributeOthers (r, excluded, amount)
    match Action.readUInt64Field s₁ with
    | .ok (r, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (e, s₃) =>
        match Action.readNatField s₃ with
        | .ok (amount, s₄) => .ok (.distributeOthers r e amount, s₄)
        | .error e' => .error e'
      | .error e' => .error e'
    | .error e' => .error e'
  | .ok (7, s₁) =>
    -- proportionalDilute (r, excluded, totalReward)
    match Action.readUInt64Field s₁ with
    | .ok (r, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (e, s₃) =>
        match Action.readNatField s₃ with
        | .ok (tr, s₄) => .ok (.proportionalDilute r e tr, s₄)
        | .error e' => .error e'
      | .error e' => .error e'
    | .error e' => .error e'
  | .ok (8, s₁) =>
    -- dispute (Dispute)
    match Encodable.decode (T := Dispute) s₁ with
    | .ok (d, s₂) => .ok (.dispute d, s₂)
    | .error e => .error e
  | .ok (9, s₁) =>
    -- disputeWithdraw (idx)
    match Action.readNatField s₁ with
    | .ok (idx, s₂) => .ok (.disputeWithdraw idx, s₂)
    | .error e => .error e
  | .ok (10, s₁) =>
    -- verdict (Verdict)
    match Encodable.decode (T := Verdict) s₁ with
    | .ok (v, s₂) => .ok (.verdict v, s₂)
    | .error e => .error e
  | .ok (11, s₁) =>
    -- rollback (targetIdx)
    match Action.readNatField s₁ with
    | .ok (idx, s₂) => .ok (.rollback idx, s₂)
    | .error e => .error e
  | .ok (12, s₁) =>
    -- registerIdentity (actor, pk)
    match Action.readUInt64Field s₁ with
    | .ok (actor, s₂) =>
      match Encodable.decode (T := ByteArray) s₂ with
      | .ok (pk, s₃) => .ok (.registerIdentity actor pk, s₃)
      | .error e => .error e
    | .error e => .error e
  | .ok (13, s₁) =>
    -- deposit (r, recipient, amount, depositId)
    match Action.readUInt64Field s₁ with
    | .ok (r, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (recipient, s₃) =>
        match Action.readNatField s₃ with
        | .ok (amount, s₄) =>
          match Action.readNatField s₄ with
          | .ok (d, s₅) => .ok (.deposit r recipient amount d, s₅)
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (14, s₁) =>
    -- withdraw (r, sender, amount, recipientL1).
    -- Audit-2: recipientL1 is decoded as a 20-byte BE ByteArray,
    -- then converted via `EthAddress.ofBytes`.  Rejection cases:
    -- the ByteArray decode fails (truncated stream), or the
    -- decoded bytes don't form a valid 20-byte EthAddress.
    match Action.readUInt64Field s₁ with
    | .ok (r, s₂) =>
      match Action.readUInt64Field s₂ with
      | .ok (sender, s₃) =>
        match Action.readNatField s₃ with
        | .ok (amount, s₄) =>
          match Encodable.decode (T := ByteArray) s₄ with
          | .ok (rcpBytes, s₅) =>
            match Bridge.EthAddress.ofBytes rcpBytes with
            | some rcp => .ok (.withdraw r sender amount rcp, s₅)
            | none =>
              .error (.invalidLength
                s!"withdraw recipientL1 expects 20 bytes; got {rcpBytes.size}")
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (other, _) => .error (.invalidConstructorIndex other)
  | .error e => .error e

instance instEncodableAction : Encodable Action where
  encode := Action.encode
  decode := Action.decode

/-! ## Helper round-trip lemmas -/

/-- Reading a `UInt64` field that was encoded via `encode (T := Nat)
    n.toNat` recovers the original `UInt64`.

    Public (not `private`) so the `SignedAction` encoder can re-use
    the same lemma for its `signer` field — both fields go through
    `Action.readUInt64Field` after the encoder writes a `Nat` head. -/
theorem readUInt64Field_roundtrip (n : UInt64) (rest : Stream) :
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

/-- Reading a `Nat` field that was encoded via `encode (T := Nat) n`
    recovers `n`, given the canonical-encoding bound.

    Public (not `private`) so the `SignedAction` encoder can re-use
    the same lemma for its `nonce` field. -/
theorem readNatField_roundtrip (n : Nat) (rest : Stream) (h : n < 256 ^ 8) :
    Action.readNatField (Encodable.encode (T := Nat) n ++ rest) = .ok (n, rest) := by
  unfold Action.readNatField
  exact nat_roundtrip n rest h

/-! ## Action round-trip headline theorem -/

/-- Round-trip with suffix: encoding `a` and appending `rest`, then
    decoding, yields `(a, rest)` for `Action`s satisfying the
    canonical-encoding bound. -/
theorem action_roundtrip (a : Action) (rest : Stream) (h : Action.fieldsBounded a) :
    Encodable.decode (T := Action) (Encodable.encode a ++ rest) = .ok (a, rest) := by
  cases a with
  | transfer r s r' am =>
    obtain ⟨_, _, _, h4⟩ := h
    show Action.decode (Action.encode (.transfer r s r' am) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    -- The encoded form is concat of 5 nat encodings.  Re-bracket and step
    -- through each readUInt64Field / readNatField.
    rw [show
      Encodable.encode (T := Nat) 0 ++ Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := Nat) s.toNat ++ Encodable.encode (T := Nat) r'.toNat ++
        Encodable.encode (T := Nat) am ++ rest =
      Encodable.encode (T := Nat) 0 ++ (Encodable.encode (T := Nat) r.toNat ++
        (Encodable.encode (T := Nat) s.toNat ++ (Encodable.encode (T := Nat) r'.toNat ++
        (Encodable.encode (T := Nat) am ++ rest))))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 0 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip r _]
    dsimp only
    rw [readUInt64Field_roundtrip s _]
    dsimp only
    rw [readUInt64Field_roundtrip r' _]
    dsimp only
    rw [readNatField_roundtrip am rest h4]
  | mint r to am =>
    obtain ⟨_, _, h3⟩ := h
    show Action.decode (Action.encode (.mint r to am) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 1 ++ Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := Nat) to.toNat ++ Encodable.encode (T := Nat) am ++ rest =
      Encodable.encode (T := Nat) 1 ++ (Encodable.encode (T := Nat) r.toNat ++
        (Encodable.encode (T := Nat) to.toNat ++ (Encodable.encode (T := Nat) am ++ rest)))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 1 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip r _]
    dsimp only
    rw [readUInt64Field_roundtrip to _]
    dsimp only
    rw [readNatField_roundtrip am rest h3]
  | burn r fr am =>
    obtain ⟨_, _, h3⟩ := h
    show Action.decode (Action.encode (.burn r fr am) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 2 ++ Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := Nat) fr.toNat ++ Encodable.encode (T := Nat) am ++ rest =
      Encodable.encode (T := Nat) 2 ++ (Encodable.encode (T := Nat) r.toNat ++
        (Encodable.encode (T := Nat) fr.toNat ++ (Encodable.encode (T := Nat) am ++ rest)))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 2 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip r _]
    dsimp only
    rw [readUInt64Field_roundtrip fr _]
    dsimp only
    rw [readNatField_roundtrip am rest h3]
  | freezeResource r =>
    show Action.decode (Action.encode (.freezeResource r) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 3 ++ Encodable.encode (T := Nat) r.toNat ++ rest =
      Encodable.encode (T := Nat) 3 ++ (Encodable.encode (T := Nat) r.toNat ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 3 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip r rest]
  | replaceKey actor newKey =>
    obtain ⟨_, h2⟩ := h
    show Action.decode (Action.encode (.replaceKey actor newKey) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 4 ++ Encodable.encode (T := Nat) actor.toNat ++
        Encodable.encode (T := ByteArray) newKey ++ rest =
      Encodable.encode (T := Nat) 4 ++ (Encodable.encode (T := Nat) actor.toNat ++
        (Encodable.encode (T := ByteArray) newKey ++ rest))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 4 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip actor _]
    dsimp only
    rw [byteArray_roundtrip newKey rest h2]
  | reward r to am =>
    obtain ⟨_, _, h3⟩ := h
    show Action.decode (Action.encode (.reward r to am) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 5 ++ Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := Nat) to.toNat ++ Encodable.encode (T := Nat) am ++ rest =
      Encodable.encode (T := Nat) 5 ++ (Encodable.encode (T := Nat) r.toNat ++
        (Encodable.encode (T := Nat) to.toNat ++ (Encodable.encode (T := Nat) am ++ rest)))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 5 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip r _]
    dsimp only
    rw [readUInt64Field_roundtrip to _]
    dsimp only
    rw [readNatField_roundtrip am rest h3]
  | distributeOthers r e am =>
    obtain ⟨_, _, h3⟩ := h
    show Action.decode (Action.encode (.distributeOthers r e am) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 6 ++ Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := Nat) e.toNat ++ Encodable.encode (T := Nat) am ++ rest =
      Encodable.encode (T := Nat) 6 ++ (Encodable.encode (T := Nat) r.toNat ++
        (Encodable.encode (T := Nat) e.toNat ++ (Encodable.encode (T := Nat) am ++ rest)))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 6 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip r _]
    dsimp only
    rw [readUInt64Field_roundtrip e _]
    dsimp only
    rw [readNatField_roundtrip am rest h3]
  | proportionalDilute r e tr =>
    obtain ⟨_, _, h3⟩ := h
    show Action.decode (Action.encode (.proportionalDilute r e tr) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 7 ++ Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := Nat) e.toNat ++ Encodable.encode (T := Nat) tr ++ rest =
      Encodable.encode (T := Nat) 7 ++ (Encodable.encode (T := Nat) r.toNat ++
        (Encodable.encode (T := Nat) e.toNat ++ (Encodable.encode (T := Nat) tr ++ rest)))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 7 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip r _]
    dsimp only
    rw [readUInt64Field_roundtrip e _]
    dsimp only
    rw [readNatField_roundtrip tr rest h3]
  | dispute d =>
    -- h : Action.fieldsBounded (.dispute d) = Dispute.fieldsBounded d
    show Action.decode (Action.encode (.dispute d) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 8 ++ Encodable.encode (T := Dispute) d ++ rest =
      Encodable.encode (T := Nat) 8 ++ (Encodable.encode (T := Dispute) d ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 8 _ (by decide)]
    dsimp only
    rw [show Encodable.decode (T := Dispute)
              (Encodable.encode (T := Dispute) d ++ rest) = .ok (d, rest)
        from dispute_roundtrip d rest h]
  | disputeWithdraw idx =>
    show Action.decode (Action.encode (.disputeWithdraw idx) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 9 ++ Encodable.encode (T := Nat) idx ++ rest =
      Encodable.encode (T := Nat) 9 ++ (Encodable.encode (T := Nat) idx ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 9 _ (by decide)]
    dsimp only
    rw [readNatField_roundtrip idx rest h]
  | verdict v =>
    show Action.decode (Action.encode (.verdict v) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 10 ++ Encodable.encode (T := Verdict) v ++ rest =
      Encodable.encode (T := Nat) 10 ++ (Encodable.encode (T := Verdict) v ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 10 _ (by decide)]
    dsimp only
    rw [show Encodable.decode (T := Verdict)
              (Encodable.encode (T := Verdict) v ++ rest) = .ok (v, rest)
        from verdict_roundtrip v rest h.1 h.2]
  | rollback idx =>
    show Action.decode (Action.encode (.rollback idx) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 11 ++ Encodable.encode (T := Nat) idx ++ rest =
      Encodable.encode (T := Nat) 11 ++ (Encodable.encode (T := Nat) idx ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 11 _ (by decide)]
    dsimp only
    rw [readNatField_roundtrip idx rest h]
  | registerIdentity actor pk =>
    obtain ⟨_, h2⟩ := h
    show Action.decode (Action.encode (.registerIdentity actor pk) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 12 ++ Encodable.encode (T := Nat) actor.toNat ++
        Encodable.encode (T := ByteArray) pk ++ rest =
      Encodable.encode (T := Nat) 12 ++ (Encodable.encode (T := Nat) actor.toNat ++
        (Encodable.encode (T := ByteArray) pk ++ rest))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 12 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip actor _]
    dsimp only
    rw [byteArray_roundtrip pk rest h2]
  | deposit r recipient amount d =>
    obtain ⟨_, _, h3, h4⟩ := h
    show Action.decode (Action.encode (.deposit r recipient amount d) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 13 ++ Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := Nat) recipient.toNat ++
        Encodable.encode (T := Nat) amount ++
        Encodable.encode (T := Nat) d ++ rest =
      Encodable.encode (T := Nat) 13 ++ (Encodable.encode (T := Nat) r.toNat ++
        (Encodable.encode (T := Nat) recipient.toNat ++
        (Encodable.encode (T := Nat) amount ++
        (Encodable.encode (T := Nat) d ++ rest))))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 13 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip r _]
    dsimp only
    rw [readUInt64Field_roundtrip recipient _]
    dsimp only
    rw [readNatField_roundtrip amount _ h3]
    dsimp only
    rw [readNatField_roundtrip d rest h4]
  | withdraw r sender amount rcp =>
    obtain ⟨_, _, h3⟩ := h
    show Action.decode (Action.encode (.withdraw r sender amount rcp) ++ rest) = .ok (_, rest)
    unfold Action.encode Action.decode
    rw [show
      Encodable.encode (T := Nat) 14 ++ Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := Nat) sender.toNat ++
        Encodable.encode (T := Nat) amount ++
        Encodable.encode (T := ByteArray) (Bridge.EthAddress.toBytes rcp) ++ rest =
      Encodable.encode (T := Nat) 14 ++ (Encodable.encode (T := Nat) r.toNat ++
        (Encodable.encode (T := Nat) sender.toNat ++
        (Encodable.encode (T := Nat) amount ++
        (Encodable.encode (T := ByteArray) (Bridge.EthAddress.toBytes rcp) ++ rest))))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 14 _ (by decide)]
    dsimp only
    rw [readUInt64Field_roundtrip r _]
    dsimp only
    rw [readUInt64Field_roundtrip sender _]
    dsimp only
    rw [readNatField_roundtrip amount _ h3]
    dsimp only
    -- 20-byte ByteArray round-trip: size = 20 < 2^64.
    have hsize : (Bridge.EthAddress.toBytes rcp).size < 256 ^ 8 := by
      rw [Bridge.EthAddress.toBytes_size]
      decide
    rw [byteArray_roundtrip (Bridge.EthAddress.toBytes rcp) rest hsize]
    dsimp only
    -- EthAddress round-trip: ofBytes ∘ toBytes = some.
    rw [Bridge.EthAddress.ofBytes_toBytes rcp]

/-- Empty-suffix round-trip for `Action`. -/
theorem action_roundtrip_empty (a : Action) (h : Action.fieldsBounded a) :
    Encodable.decode (T := Action) (Encodable.encode a) = .ok (a, []) := by
  have := action_roundtrip a [] h
  simpa using this

/-- Action injectivity (bounded): for `a₁`, `a₂` both
    `fieldsBounded`, equal encodings imply equal actions. -/
theorem action_encode_injective (a₁ a₂ : Action)
    (h₁ : Action.fieldsBounded a₁) (h₂ : Action.fieldsBounded a₂)
    (h : Encodable.encode (T := Action) a₁ = Encodable.encode (T := Action) a₂) :
    a₁ = a₂ := by
  have r₁ := action_roundtrip_empty a₁ h₁
  have r₂ := action_roundtrip_empty a₂ h₂
  rw [h] at r₁
  have heq : (Except.ok (a₁, ([] : Stream)) : Except DecodeError (Action × Stream))
           = Except.ok (a₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ## Spot-check `example`s (compile-time-only test vectors) -/

/-- Spot-check: encoding a transfer action produces a non-empty byte
    stream beginning with the constructor tag (a CBE uint with value
    0).  The first 9 bytes are the `Encodable.encode (T := Nat) 0`
    head: tag `0x00` + 8 bytes of zero. -/
example : (Encodable.encode (T := Action) (.transfer 1 2 3 4)).length > 0 := by decide

/-- Spot-check: round-trip of a small transfer action. -/
example : Encodable.decode (T := Action) (Encodable.encode (T := Action) (.transfer 1 2 3 4))
        = .ok (.transfer 1 2 3 4, []) := by
  apply action_roundtrip_empty
  show 1 < _ ∧ _
  refine ⟨?_, ?_, ?_, ?_⟩ <;> decide

end Encoding
end LegalKernel
