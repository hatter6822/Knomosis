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

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority

/-! ## Numerical bound predicate

`Action.fieldsBounded a` holds when every numeric field of `a` fits
in canonical CBE's 8-byte uint form (`< 2^64`).  Phase 5's runtime
adaptor gates on this before serialising. -/

/-- The canonical-encoding bound (`< 2^64`) on every numeric field
    of `a`.  For `replaceKey`, the public key's byte length is the
    relevant bound. -/
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
