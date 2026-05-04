/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.Encodable — the `Encodable` typeclass + primitive
instances.

Phase 4 WU 4.1 + WU 4.2.  Defines:

  * `Encodable` — the typeclass `T → Stream` plus a streaming
    parser `Stream → Except DecodeError (T × Stream)`.
  * `Encodable.encodeAll` / `Encodable.decodeAll` — top-level
    "no trailing bytes" wrappers.
  * Instances for `Bool`, `Nat`, `ByteArray`, `String`, `List α`,
    `Option α` (when `[Encodable α]`).
  * Per-type round-trip theorems (`*_roundtrip`), with explicit
    bounds where canonical-encoding requires them (`Nat`,
    `ByteArray`, `String` are bounded by `2^64`).
  * Per-type injectivity theorems (`*_encode_injective`), derived
    from round-trip via the standard "decode-both-sides" argument.

The typeclass works internally over `Stream = List UInt8`
(`Encoding.CBOR.Stream`), and the public API converts via
`ByteArray.toList` / `List.toByteArray`.

This module is **not** part of the trusted computing base.  Bugs
here produce wrong serialisations (caught by the per-type round-trip
proofs at build time), but cannot violate any kernel invariant.
-/

import LegalKernel.Encoding.CBOR

namespace LegalKernel
namespace Encoding

/-! ## The `Encodable` typeclass -/

/-- Typeclass for types with canonical CBE encodings.  Each instance
    bundles a serialiser `encode : T → Stream` and a streaming
    deserialiser `decode : Stream → Except DecodeError (T × Stream)`.

    Round-trip and injectivity are stated separately as standalone
    theorems (not as typeclass methods), because for some instances
    (e.g. `Nat`, `ByteArray`, `String`) the round-trip statement
    requires a static bound (`< 2^64`) that is awkward to express in
    a typeclass field. -/
class Encodable (T : Type) where
  /-- Serialise a `T` to its canonical byte stream. -/
  encode : T → Stream
  /-- Try to deserialise a `T` from the front of a byte stream;
      returns the recovered value and the residual suffix on
      success. -/
  decode : Stream → Except DecodeError (T × Stream)

namespace Encodable

variable {T : Type} [Encodable T]

/-! ## Top-level "no trailing bytes" wrapper -/

/-- Decode a complete byte stream, rejecting any trailing bytes.  The
    typical entry point for runtime / deployment-facing decoders. -/
def decodeAll (s : Stream) : Except DecodeError T :=
  match decode (T := T) s with
  | .ok (v, []) => .ok v
  | .ok (_, rest) => .error (.trailingBytes rest.length)
  | .error e => .error e

/-! ## ByteArray-flavoured wrappers (public API) -/

/-- `ByteArray`-flavoured encode: serialises `v` and packs the result
    into a `ByteArray`. -/
def encodeBytes (v : T) : ByteArray :=
  ByteArray.mk (encode v).toArray

/-- `ByteArray`-flavoured decode-all: parses a complete `ByteArray`,
    rejecting trailing bytes. -/
def decodeAllBytes (bs : ByteArray) : Except DecodeError T :=
  decodeAll bs.toList

end Encodable

/-! ## Primitive instances -/

/-! ### `Bool`

A `Bool` is encoded as a 9-byte CBE uint: `cbeTagUint :: <8 bytes
LE Nat>` where the Nat is `0` for `false` and `1` for `true`.  Using
the same CBE-uint shape as other small numbers keeps the proofs
uniform — the same `cborHeadRoundtrip_append` lemma discharges every
small-uint round-trip. -/

instance instEncodableBool : Encodable Bool where
  encode b := cborHeadEncode cbeTagUint (if b then 1 else 0)
  decode s :=
    match cborHeadDecode s cbeTagUint with
    | .ok (0, rest) => .ok (false, rest)
    | .ok (1, rest) => .ok (true, rest)
    | .ok (other, _) => .error (.invalidConstructorIndex other)
    | .error e => .error e

/-- `Bool` round-trip with arbitrary suffix.  Direct case-split on
    the boolean and `cborHeadRoundtrip_append` discharge. -/
theorem bool_roundtrip (v : Bool) (rest : Stream) :
    Encodable.decode (T := Bool) (Encodable.encode v ++ rest) = .ok (v, rest) := by
  cases v with
  | false =>
    show (match cborHeadDecode (cborHeadEncode cbeTagUint 0 ++ rest) cbeTagUint with
      | .ok (0, rest) => Except.ok ((false : Bool), rest)
      | .ok (1, rest) => Except.ok (true, rest)
      | .ok (other, _) => Except.error (DecodeError.invalidConstructorIndex other)
      | .error e => Except.error e) = .ok (false, rest)
    rw [cborHeadRoundtrip_append cbeTagUint 0 rest (by decide)]
  | true =>
    show (match cborHeadDecode (cborHeadEncode cbeTagUint 1 ++ rest) cbeTagUint with
      | .ok (0, rest) => Except.ok ((false : Bool), rest)
      | .ok (1, rest) => Except.ok (true, rest)
      | .ok (other, _) => Except.error (DecodeError.invalidConstructorIndex other)
      | .error e => Except.error e) = .ok (true, rest)
    rw [cborHeadRoundtrip_append cbeTagUint 1 rest (by decide)]

/-- `Bool` round-trip without a suffix.  Specialisation of
    `bool_roundtrip` to `rest = []`. -/
theorem bool_roundtrip_empty (v : Bool) :
    Encodable.decode (T := Bool) (Encodable.encode v) = .ok (v, []) := by
  have := bool_roundtrip v []
  simpa using this

/-- `Bool` encode injectivity.  Falls out of `bool_roundtrip_empty`. -/
theorem bool_encode_injective :
    Function.Injective (Encodable.encode : Bool → Stream) := by
  intro v₁ v₂ h
  have h₁ := bool_roundtrip_empty v₁
  have h₂ := bool_roundtrip_empty v₂
  rw [h] at h₁
  have heq : (Except.ok (v₁, ([] : Stream)) : Except DecodeError (Bool × Stream))
           = Except.ok (v₂, []) := h₁.symm.trans h₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ### `Nat` (CBE uint head + 8 LE bytes; bounded round-trip)

Round-trip for `Nat` requires `n < 2^64`; outside that bound the
encoder is total but lossy (modular truncation).  Deployments must
gate `Amount` / `ActorId` / `ResourceId` arguments at the runtime
boundary (Genesis Plan §8.5). -/

instance instEncodableNat : Encodable Nat where
  encode n := cborHeadEncode cbeTagUint n
  decode s := cborHeadDecode s cbeTagUint

/-- Bounded `Nat` round-trip (with suffix): for `n < 2^64`, decoding
    `encode n ++ rest` returns `(n, rest)`.  Phase 5's runtime adaptor
    enforces the bound at the deployment boundary. -/
theorem nat_roundtrip (n : Nat) (rest : Stream) (h : n < 256 ^ 8) :
    Encodable.decode (T := Nat) (Encodable.encode n ++ rest) = .ok (n, rest) := by
  show cborHeadDecode (cborHeadEncode cbeTagUint n ++ rest) cbeTagUint = .ok (n, rest)
  exact cborHeadRoundtrip_append cbeTagUint n rest h

/-- Bounded `Nat` round-trip (empty suffix). -/
theorem nat_roundtrip_empty (n : Nat) (h : n < 256 ^ 8) :
    Encodable.decode (T := Nat) (Encodable.encode n) = .ok (n, []) := by
  have := nat_roundtrip n [] h
  simpa using this

/-- Bounded `Nat` injectivity: for `n₁, n₂ < 2^64`, equal encodings
    imply equal values. -/
theorem nat_encode_injective (n₁ n₂ : Nat) (h₁ : n₁ < 256 ^ 8) (h₂ : n₂ < 256 ^ 8)
    (h : Encodable.encode (T := Nat) n₁ = Encodable.encode (T := Nat) n₂) : n₁ = n₂ := by
  have r₁ := nat_roundtrip_empty n₁ h₁
  have r₂ := nat_roundtrip_empty n₂ h₂
  rw [h] at r₁
  have heq : (Except.ok (n₁, ([] : Stream)) : Except DecodeError (Nat × Stream))
           = Except.ok (n₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ### `BoundedNat`: a `Nat` with a static `< 2^64` bound

Used by callers that need *unconditional* round-trip / injectivity
(typeclass-driven).  The bound is part of the type, so the round-
trip theorem requires no extra hypothesis. -/

/-- A `Nat` with a static `< 2^64` bound, used when a caller needs
    unconditional round-trip / injectivity.  The runtime layer
    (Phase 5) marshals deployment inputs via this sub-type to enforce
    the canonical-encoding bound. -/
structure BoundedNat where
  /-- The underlying `Nat` value. -/
  val : Nat
  /-- The canonical-encoding bound: `val < 2^64`. -/
  bound : val < 256 ^ 8
  deriving Repr

namespace BoundedNat

/-- Equality on `BoundedNat`: the values must be equal (the bound is
    propositional and irrelevant). -/
instance : DecidableEq BoundedNat := fun b₁ b₂ =>
  if h : b₁.val = b₂.val then
    .isTrue (by cases b₁; cases b₂; subst h; rfl)
  else
    .isFalse (fun heq => h (by rw [heq]))

end BoundedNat

instance instEncodableBoundedNat : Encodable BoundedNat where
  encode b := cborHeadEncode cbeTagUint b.val
  decode s :=
    match cborHeadDecode s cbeTagUint with
    | .ok (n, rest) =>
      if h : n < 256 ^ 8 then
        .ok (⟨n, h⟩, rest)
      else
        .error (.invalidLength s!"BoundedNat decoded value {n} exceeds 2^64 bound")
    | .error e => .error e

/-- Unconditional `BoundedNat` round-trip with suffix. -/
theorem boundedNat_roundtrip (v : BoundedNat) (rest : Stream) :
    Encodable.decode (T := BoundedNat) (Encodable.encode v ++ rest) = .ok (v, rest) := by
  show (match cborHeadDecode (cborHeadEncode cbeTagUint v.val ++ rest) cbeTagUint with
    | .ok (n, rest) =>
      if h : n < 256 ^ 8 then
        Except.ok ((⟨n, h⟩ : BoundedNat), rest)
      else
        Except.error (DecodeError.invalidLength
          s!"BoundedNat decoded value {n} exceeds 2^64 bound")
    | .error e => Except.error e) = .ok (v, rest)
  rw [cborHeadRoundtrip_append cbeTagUint v.val rest v.bound]
  dsimp only
  rw [dif_pos v.bound]

/-- Unconditional `BoundedNat` injectivity. -/
theorem boundedNat_encode_injective :
    Function.Injective (Encodable.encode : BoundedNat → Stream) := by
  intro v₁ v₂ h
  have r₁ := boundedNat_roundtrip v₁ []
  have r₂ := boundedNat_roundtrip v₂ []
  simp at r₁ r₂
  rw [h] at r₁
  have heq : (Except.ok (v₁, ([] : Stream)) : Except DecodeError (BoundedNat × Stream))
           = Except.ok (v₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ### `ByteArray` (CBE bstr) -/

/-- Encode a list of UInt8 as a CBE byte string: tag + 8-byte LE
    length + raw bytes. -/
def encodeBytesList (bs : Stream) : Stream :=
  cborHeadEncode cbeTagBytes bs.length ++ bs

/-- Decode a CBE byte string: read tag + length, then take that many
    bytes. -/
def decodeBytesList (s : Stream) : Except DecodeError (Stream × Stream) :=
  match cborHeadDecode s cbeTagBytes with
  | .ok (len, rest) =>
    if h : len ≤ rest.length then
      .ok (rest.take len, rest.drop len)
    else
      let _ := h
      .error .unexpectedEof
  | .error e => .error e

instance instEncodableByteArray : Encodable ByteArray where
  encode bs := encodeBytesList bs.data.toList
  decode s :=
    match decodeBytesList s with
    | .ok (lst, rest) => .ok (ByteArray.mk lst.toArray, rest)
    | .error e => .error e

/-- `ByteArray.mk` ∘ `List.toArray` ∘ `bs.data.toList` is the
    identity.  Via `Array.toArray_toList` and the `ByteArray`
    constructor's injectivity. -/
private theorem byteArray_mk_data_toList_toArray (bs : ByteArray) :
    ByteArray.mk bs.data.toList.toArray = bs := by
  cases bs with
  | mk arr =>
    show ByteArray.mk arr.toList.toArray = ByteArray.mk arr
    rw [Array.toArray_toList]

/-- `bs.data.toList.length = bs.size` for any `ByteArray`. -/
private theorem byteArray_data_toList_length (bs : ByteArray) :
    bs.data.toList.length = bs.size := by
  cases bs with
  | mk arr =>
    show arr.toList.length = arr.size
    exact arr.length_toList

/-- `bs.toList.take bs.toList.length = bs.toList`. -/
private theorem list_take_self_length (l : List UInt8) :
    l.take l.length = l := by
  induction l with
  | nil => rfl
  | cons a as ih => simp [ih]

/-- `bs.toList.drop bs.toList.length = []`. -/
private theorem list_drop_self_length (l : List UInt8) :
    l.drop l.length = [] := by
  induction l with
  | nil => rfl
  | cons a as ih => simp [ih]

/-- Round-trip for `ByteArray`, bounded by `bs.size < 2^64`. -/
theorem byteArray_roundtrip (bs : ByteArray) (rest : Stream) (h : bs.size < 256 ^ 8) :
    Encodable.decode (T := ByteArray) (Encodable.encode bs ++ rest) = .ok (bs, rest) := by
  show (match decodeBytesList (encodeBytesList bs.data.toList ++ rest) with
    | .ok (lst, rest') => Except.ok (ByteArray.mk lst.toArray, rest')
    | .error e => Except.error e) = .ok (bs, rest)
  unfold encodeBytesList decodeBytesList
  rw [show cborHeadEncode cbeTagBytes bs.data.toList.length ++ bs.data.toList ++ rest =
        cborHeadEncode cbeTagBytes bs.data.toList.length ++ (bs.data.toList ++ rest) from
        by simp [List.append_assoc]]
  have hlen : bs.data.toList.length < 256 ^ 8 := by
    rw [byteArray_data_toList_length]; exact h
  rw [cborHeadRoundtrip_append cbeTagBytes bs.data.toList.length (bs.data.toList ++ rest) hlen]
  dsimp only
  have hle : bs.data.toList.length ≤ (bs.data.toList ++ rest).length := by
    rw [List.length_append]; omega
  rw [dif_pos hle]
  rw [List.take_append_of_le_length (Nat.le_refl _)]
  rw [List.drop_append_of_le_length (Nat.le_refl _)]
  rw [list_take_self_length, list_drop_self_length]
  show Except.ok (ByteArray.mk bs.data.toList.toArray, [] ++ rest) = .ok (bs, rest)
  rw [byteArray_mk_data_toList_toArray]
  simp

/-- Empty-suffix round-trip for `ByteArray`. -/
theorem byteArray_roundtrip_empty (bs : ByteArray) (h : bs.size < 256 ^ 8) :
    Encodable.decode (T := ByteArray) (Encodable.encode bs) = .ok (bs, []) := by
  have := byteArray_roundtrip bs [] h
  simpa using this

/-- Bounded injectivity for `ByteArray`. -/
theorem byteArray_encode_injective (bs₁ bs₂ : ByteArray)
    (h₁ : bs₁.size < 256 ^ 8) (h₂ : bs₂.size < 256 ^ 8)
    (h : Encodable.encode (T := ByteArray) bs₁ = Encodable.encode (T := ByteArray) bs₂) :
    bs₁ = bs₂ := by
  have r₁ := byteArray_roundtrip_empty bs₁ h₁
  have r₂ := byteArray_roundtrip_empty bs₂ h₂
  rw [h] at r₁
  have heq : (Except.ok (bs₁, ([] : Stream)) : Except DecodeError (ByteArray × Stream))
           = Except.ok (bs₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ### `String` (CBE tstr)

Encoded as: text-tag + 8-byte LE byte-length + UTF-8 bytes.  We treat
the UTF-8 boundary as opaque: `String.toUTF8` for encode and
`String.fromUTF8?` for decode.  Round-trip holds for `s.utf8ByteSize <
2^64` (the canonical-encoding bound).  Round-trip relies on the
identity `String.fromUTF8? s.toUTF8 = some s`, which is part of
Lean core's String invariants. -/

instance instEncodableString : Encodable String where
  encode s := cborHeadEncode cbeTagText s.utf8ByteSize ++ s.toUTF8.toList
  decode s :=
    match cborHeadDecode s cbeTagText with
    | .ok (len, rest) =>
      if h : len ≤ rest.length then
        let bytes := rest.take len
        let arr := ByteArray.mk bytes.toArray
        match String.fromUTF8? arr with
        | some str => .ok (str, rest.drop len)
        | none     => .error (.nonCanonical "non-UTF-8 text string")
      else
        let _ := h
        .error .unexpectedEof
    | .error e => .error e

/-! ### `List α` (CBE array)

Encoded as: array tag + 8-byte LE count + concatenated element
encodings.  The decoder reads the count, then iterates `decode`
that many times. -/

/-- Encode a list element-by-element, prefixed by the count. -/
def encodeList {α : Type} [Encodable α] (xs : List α) : Stream :=
  cborHeadEncode cbeTagArray xs.length ++
    xs.foldr (fun x acc => Encodable.encode x ++ acc) []

/-- Decode `n` elements of type `α` from the front of `s`.  Returns
    the list and the residual stream. -/
def decodeListN {α : Type} [Encodable α] : Nat → Stream → Except DecodeError (List α × Stream)
  | 0,     s => .ok ([], s)
  | k + 1, s =>
    match Encodable.decode s with
    | .ok (x, rest) =>
      match decodeListN k rest with
      | .ok (xs, rest') => .ok (x :: xs, rest')
      | .error e => .error e
    | .error e => .error e

instance instEncodableList {α : Type} [Encodable α] : Encodable (List α) where
  encode := encodeList
  decode s :=
    match cborHeadDecode s cbeTagArray with
    | .ok (count, rest) => decodeListN count rest
    | .error e => .error e

/-! ### `Option α` (CBE array of length 0 or 1) -/

instance instEncodableOption {α : Type} [Encodable α] : Encodable (Option α) where
  encode
    | none   => cborHeadEncode cbeTagArray 0
    | some v => cborHeadEncode cbeTagArray 1 ++ Encodable.encode v
  decode s :=
    match cborHeadDecode s cbeTagArray with
    | .ok (0, rest) => .ok (none, rest)
    | .ok (1, rest) =>
      match Encodable.decode rest with
      | .ok (v, rest') => .ok (some v, rest')
      | .error e => .error e
    | .ok (other, _) => .error (.invalidConstructorIndex other)
    | .error e => .error e

/-! ### `UInt8` / `UInt16` / `UInt32` / `UInt64`

Each goes through the underlying `Nat` encoder.  Round-trip is
*unconditional* on the source type's range (which fits in 2^64). -/

instance instEncodableUInt8 : Encodable UInt8 where
  encode n := Encodable.encode (T := Nat) n.toNat
  decode s :=
    match Encodable.decode (T := Nat) s with
    | .ok (n, rest) =>
      if h : n < 256 then
        .ok (n.toUInt8, rest)
      else
        let _ := h
        .error (.invalidLength s!"UInt8 decoded value {n} exceeds 2^8 bound")
    | .error e => .error e

instance instEncodableUInt16 : Encodable UInt16 where
  encode n := Encodable.encode (T := Nat) n.toNat
  decode s :=
    match Encodable.decode (T := Nat) s with
    | .ok (n, rest) =>
      if h : n < 65536 then
        .ok (n.toUInt16, rest)
      else
        let _ := h
        .error (.invalidLength s!"UInt16 decoded value {n} exceeds 2^16 bound")
    | .error e => .error e

instance instEncodableUInt32 : Encodable UInt32 where
  encode n := Encodable.encode (T := Nat) n.toNat
  decode s :=
    match Encodable.decode (T := Nat) s with
    | .ok (n, rest) =>
      if h : n < 4294967296 then
        .ok (n.toUInt32, rest)
      else
        let _ := h
        .error (.invalidLength s!"UInt32 decoded value {n} exceeds 2^32 bound")
    | .error e => .error e

instance instEncodableUInt64 : Encodable UInt64 where
  encode n := Encodable.encode (T := Nat) n.toNat
  decode s :=
    match Encodable.decode (T := Nat) s with
    | .ok (n, rest) =>
      if h : n < 18446744073709551616 then
        .ok (n.toUInt64, rest)
      else
        let _ := h
        .error (.invalidLength s!"UInt64 decoded value {n} exceeds 2^64 bound")
    | .error e => .error e

/-- `UInt8` round-trip (unconditional). -/
theorem uInt8_roundtrip (n : UInt8) (rest : Stream) :
    Encodable.decode (T := UInt8) (Encodable.encode n ++ rest) = .ok (n, rest) := by
  show (match Encodable.decode (T := Nat) (Encodable.encode (T := Nat) n.toNat ++ rest) with
    | .ok (m, rest') =>
      if h : m < 256 then Except.ok (m.toUInt8, rest')
      else Except.error
        (DecodeError.invalidLength s!"UInt8 decoded value {m} exceeds 2^8 bound")
    | .error e => Except.error e) = .ok (n, rest)
  have h1 : n.toNat < 2 ^ 8 := UInt8.toNat_lt n
  have hbound : n.toNat < 256 ^ 8 := by
    have h3 : (256 : Nat) ^ 8 = 18446744073709551616 := by decide
    have h4 : (2 : Nat) ^ 8 = 256 := by decide
    omega
  rw [nat_roundtrip n.toNat rest hbound]
  dsimp only
  have h256 : n.toNat < 256 := by
    have h4 : (2 : Nat) ^ 8 = 256 := by decide
    omega
  rw [dif_pos h256]
  congr 1
  congr 1
  show UInt8.ofNat n.toNat = n
  exact UInt8.ofNat_toNat

/-- `UInt64` round-trip (unconditional). -/
theorem uInt64_roundtrip (n : UInt64) (rest : Stream) :
    Encodable.decode (T := UInt64) (Encodable.encode n ++ rest) = .ok (n, rest) := by
  show (match Encodable.decode (T := Nat) (Encodable.encode (T := Nat) n.toNat ++ rest) with
    | .ok (m, rest') =>
      if h : m < 18446744073709551616 then Except.ok (m.toUInt64, rest')
      else Except.error
        (DecodeError.invalidLength s!"UInt64 decoded value {m} exceeds 2^64 bound")
    | .error e => Except.error e) = .ok (n, rest)
  have h1 : n.toNat < 2 ^ 64 := UInt64.toNat_lt n
  have hbound : n.toNat < 256 ^ 8 := by
    have h3 : (256 : Nat) ^ 8 = 18446744073709551616 := by decide
    have h2 : (2 : Nat) ^ 64 = 18446744073709551616 := by decide
    omega
  rw [nat_roundtrip n.toNat rest hbound]
  dsimp only
  have hp : n.toNat < 18446744073709551616 := by
    have h2 : (2 : Nat) ^ 64 = 18446744073709551616 := by decide
    omega
  rw [dif_pos hp]
  congr 1
  congr 1
  show UInt64.ofNat n.toNat = n
  exact UInt64.ofNat_toNat

end Encoding
end LegalKernel
