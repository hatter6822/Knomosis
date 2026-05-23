/-
  Knomosis  - A Societal Kernel
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
  * `Encodable.decodeAll` — top-level "no trailing bytes" wrapper.
  * `Encodable.encodeBytes` / `decodeAllBytes` — `ByteArray`-flavoured
    boundary helpers.
  * Instances for `Bool`, `Nat`, `BoundedNat`, `ByteArray`,
    `List α` / `Option α` (when `[Encodable α]`),
    `UInt8` / `UInt16` / `UInt32` / `UInt64`.
  * Per-type round-trip theorems (`*_roundtrip`), with explicit
    bounds where canonical-encoding requires them (`Nat`,
    `ByteArray` bounded by `< 2^64`; `BoundedNat`, the four `UIntN`s,
    and `Bool` unconditional).
  * Per-type injectivity theorems (`*_encode_injective`), derived
    from round-trip via the standard "decode-both-sides" argument.
  * For `List α` and `Option α`, round-trip is *parameterised* on a
    per-element round-trip hypothesis (`ElemRoundtrip α`); the
    typeclass instance itself is unparameterised (just `[Encodable α]`).

**Deviation from Genesis Plan §12 WU 4.1 (documented).**  The Genesis
Plan §12 WU 4.1 acceptance criteria list `String` (CBE tstr) as one
of the primitive instances.  Phase 4 *omits* the `String` instance:
no in-tree consumer requires it (the `signInput` domain string is
encoded byte-wise via `cborHeadEncode cbeTagBytes` directly), and
proving its round-trip would require a `String.fromUTF8?_toUTF8`
identity that Lean core does not currently expose.  A future Phase
5 work unit (deployment-facing diagnostic event encoding) will land
the `String` instance with a hand-proved UTF-8 round-trip lemma.

**Type-collision discipline (schema-implicit).**  CBE encodes a
single byte tag for each major type but does NOT carry any per-
schema type discriminator.  As a result, distinct logical types
that happen to share a major type encode to the same bytes:

  * `Bool false` and `Nat 0` both encode to
    `[cbeTagUint, 0, 0, 0, 0, 0, 0, 0, 0]` (9 zero-payload bytes
    after the uint tag).
  * `Option α none` and `List α []` both encode to
    `[cbeTagArray, 0, 0, 0, 0, 0, 0, 0, 0]`.
  * Similarly, `Option α (some v)` and `List α [v]` collide as
    1-element CBE arrays, etc.

Per-type round-trip and injectivity (`*_encode_injective`) hold
WITHIN each type.  ACROSS types, the schema is implicit: the
caller must commit to a fixed type when encoding and the same type
when decoding.  This matches binary protocols like Protobuf's
schema-implicit wire format.  Phase 4's higher-level types
(`Action`, `SignedAction`, `State`, `ExtendedState`) all fix the
field types at the type level (no across-type ambiguity at any
field position), so this collision is benign in practice — but
deployment-level protocols using the raw `Encodable` typeclass
must commit to a fixed type at signing / hashing time and never
re-interpret the same bytes under a different type.  Phase 5's
runtime adaptor will document this as part of its protocol
specification.

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

/-! ### `List α` (CBE array, parameterised round-trip)

Encoded as: array tag + 8-byte LE count + concatenated element
encodings.  The decoder reads the count, then iterates `decode`
that many times.  Round-trip and injectivity are *parameterised*
on a per-element round-trip hypothesis (every element of the list
must itself round-trip with arbitrary suffix); this lets the lemma
work for any `α` whose `Encodable` instance is round-trip-correct,
without committing to a `LawfulEncodable` typeclass. -/

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

/-- Per-element round-trip hypothesis: every `x : α` round-trips with
    every possible suffix.  Stated as a `Prop` so callers can pass it
    explicitly as evidence. -/
def ElemRoundtrip (α : Type) [Encodable α] : Prop :=
  ∀ (x : α) (rest : Stream),
    Encodable.decode (T := α) (Encodable.encode x ++ rest) = .ok (x, rest)

/-- Internal lemma: `decodeListN xs.length` correctly inverts the
    foldr-encoded payload, given the per-element round-trip
    hypothesis.  Direct structural induction on `xs`. -/
private theorem decodeListN_encode_foldr {α : Type} [Encodable α]
    (h : ElemRoundtrip α) (xs : List α) (rest : Stream) :
    decodeListN xs.length
        (xs.foldr (fun x acc => Encodable.encode x ++ acc) [] ++ rest)
      = .ok (xs, rest) := by
  induction xs with
  | nil => simp [decodeListN]
  | cons x xs ih =>
    simp only [decodeListN, List.foldr, List.length, List.append_assoc]
    rw [h x (xs.foldr _ [] ++ rest)]
    dsimp only
    rw [ih]

/-- `List α` round-trip with suffix, parameterised on a per-element
    round-trip hypothesis and the canonical-encoding length bound. -/
theorem list_roundtrip {α : Type} [Encodable α]
    (h : ElemRoundtrip α) (xs : List α) (rest : Stream)
    (h_len : xs.length < 256 ^ 8) :
    Encodable.decode (T := List α) (Encodable.encode xs ++ rest) = .ok (xs, rest) := by
  show (match cborHeadDecode (encodeList xs ++ rest) cbeTagArray with
    | .ok (count, rest) => decodeListN count rest
    | .error e => Except.error e) = .ok (xs, rest)
  unfold encodeList
  rw [show
      cborHeadEncode cbeTagArray xs.length ++
        xs.foldr (fun x acc => Encodable.encode x ++ acc) [] ++ rest =
      cborHeadEncode cbeTagArray xs.length ++
        (xs.foldr (fun x acc => Encodable.encode x ++ acc) [] ++ rest)
      from by simp [List.append_assoc]]
  rw [cborHeadRoundtrip_append cbeTagArray xs.length _ h_len]
  dsimp only
  exact decodeListN_encode_foldr h xs rest

/-! ### Per-element-bounded list round-trip

A more general `list_roundtrip` variant where the per-element round-
trip hypothesis is membership-conditional: each element of `xs` only
needs to round-trip *if it is in the list*.  Useful for types whose
unconditional round-trip is unprovable but whose bounded round-trip
holds on every list element of interest (e.g. `ByteArray` lists where
each element's `size < 2^64`).

`ElemRoundtripIn xs` is the per-list version of `ElemRoundtrip α`. -/

/-- Per-element round-trip restricted to the elements of a specific
    list `xs`.  Used by Phase-6 `Verdict` encoding where `signers
    : List ActorId` and `sigs : List Signature` have different
    per-element round-trip availability. -/
def ElemRoundtripIn {α : Type} [Encodable α] (xs : List α) : Prop :=
  ∀ x ∈ xs, ∀ (rest : Stream),
    Encodable.decode (T := α) (Encodable.encode x ++ rest) = .ok (x, rest)

/-- Internal helper: `decodeListN xs.length` correctly inverts the
    foldr-encoded payload, given the *list-restricted* per-element
    round-trip hypothesis. -/
private theorem decodeListN_encode_foldr_bounded {α : Type} [Encodable α]
    (xs : List α) (h : ElemRoundtripIn xs) (rest : Stream) :
    decodeListN xs.length
        (xs.foldr (fun x acc => Encodable.encode x ++ acc) [] ++ rest)
      = .ok (xs, rest) := by
  induction xs with
  | nil => simp [decodeListN]
  | cons x xs ih =>
    simp only [decodeListN, List.foldr, List.length, List.append_assoc]
    have hx : Encodable.decode (T := α) (Encodable.encode x ++
                  (xs.foldr (fun x acc => Encodable.encode x ++ acc) [] ++ rest))
            = .ok (x, xs.foldr _ [] ++ rest) :=
      h x List.mem_cons_self _
    rw [hx]
    dsimp only
    have h_tail : ElemRoundtripIn xs := by
      intro y hy_mem
      exact h y (List.mem_cons_of_mem _ hy_mem)
    rw [ih h_tail]

/-- `List α` round-trip with the per-element-bounded variant of the
    hypothesis.  Same shape as `list_roundtrip` but admits weaker
    per-element evidence. -/
theorem list_roundtrip_bounded {α : Type} [Encodable α]
    (xs : List α) (h : ElemRoundtripIn xs) (rest : Stream)
    (h_len : xs.length < 256 ^ 8) :
    Encodable.decode (T := List α) (Encodable.encode xs ++ rest) = .ok (xs, rest) := by
  show (match cborHeadDecode (encodeList xs ++ rest) cbeTagArray with
    | .ok (count, rest) => decodeListN count rest
    | .error e => Except.error e) = .ok (xs, rest)
  unfold encodeList
  rw [show
      cborHeadEncode cbeTagArray xs.length ++
        xs.foldr (fun x acc => Encodable.encode x ++ acc) [] ++ rest =
      cborHeadEncode cbeTagArray xs.length ++
        (xs.foldr (fun x acc => Encodable.encode x ++ acc) [] ++ rest)
      from by simp [List.append_assoc]]
  rw [cborHeadRoundtrip_append cbeTagArray xs.length _ h_len]
  dsimp only
  exact decodeListN_encode_foldr_bounded xs h rest

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

/-- `Option α` round-trip with suffix, parameterised on the per-
    element round-trip hypothesis. -/
theorem option_roundtrip {α : Type} [Encodable α]
    (h : ElemRoundtrip α) (v : Option α) (rest : Stream) :
    Encodable.decode (T := Option α) (Encodable.encode v ++ rest) = .ok (v, rest) := by
  cases v with
  | none =>
    show (match cborHeadDecode (cborHeadEncode cbeTagArray 0 ++ rest) cbeTagArray with
      | .ok (0, rest) => Except.ok ((none : Option α), rest)
      | .ok (1, rest) =>
        match Encodable.decode (T := α) rest with
        | .ok (v, rest') => Except.ok (some v, rest')
        | .error e => Except.error e
      | .ok (other, _) => Except.error (DecodeError.invalidConstructorIndex other)
      | .error e => Except.error e) = .ok (none, rest)
    rw [cborHeadRoundtrip_append cbeTagArray 0 rest (by decide)]
  | some v =>
    show (match cborHeadDecode
            (cborHeadEncode cbeTagArray 1 ++ Encodable.encode v ++ rest) cbeTagArray with
      | .ok (0, rest) => Except.ok ((none : Option α), rest)
      | .ok (1, rest) =>
        match Encodable.decode (T := α) rest with
        | .ok (v, rest') => Except.ok (some v, rest')
        | .error e => Except.error e
      | .ok (other, _) => Except.error (DecodeError.invalidConstructorIndex other)
      | .error e => Except.error e) = .ok (some v, rest)
    rw [show cborHeadEncode cbeTagArray 1 ++ Encodable.encode v ++ rest =
            cborHeadEncode cbeTagArray 1 ++ (Encodable.encode v ++ rest)
            from by simp [List.append_assoc]]
    rw [cborHeadRoundtrip_append cbeTagArray 1 _ (by decide)]
    dsimp only
    rw [h v rest]

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

/-- `UInt16` round-trip (unconditional). -/
theorem uInt16_roundtrip (n : UInt16) (rest : Stream) :
    Encodable.decode (T := UInt16) (Encodable.encode n ++ rest) = .ok (n, rest) := by
  show (match Encodable.decode (T := Nat) (Encodable.encode (T := Nat) n.toNat ++ rest) with
    | .ok (m, rest') =>
      if h : m < 65536 then Except.ok (m.toUInt16, rest')
      else Except.error
        (DecodeError.invalidLength s!"UInt16 decoded value {m} exceeds 2^16 bound")
    | .error e => Except.error e) = .ok (n, rest)
  have h1 : n.toNat < 2 ^ 16 := UInt16.toNat_lt n
  have hbound : n.toNat < 256 ^ 8 := by
    have h3 : (256 : Nat) ^ 8 = 18446744073709551616 := by decide
    have h4 : (2 : Nat) ^ 16 = 65536 := by decide
    omega
  rw [nat_roundtrip n.toNat rest hbound]
  dsimp only
  have h65k : n.toNat < 65536 := by
    have h4 : (2 : Nat) ^ 16 = 65536 := by decide
    omega
  rw [dif_pos h65k]
  congr 1
  congr 1
  show UInt16.ofNat n.toNat = n
  exact UInt16.ofNat_toNat

/-- `UInt32` round-trip (unconditional). -/
theorem uInt32_roundtrip (n : UInt32) (rest : Stream) :
    Encodable.decode (T := UInt32) (Encodable.encode n ++ rest) = .ok (n, rest) := by
  show (match Encodable.decode (T := Nat) (Encodable.encode (T := Nat) n.toNat ++ rest) with
    | .ok (m, rest') =>
      if h : m < 4294967296 then Except.ok (m.toUInt32, rest')
      else Except.error
        (DecodeError.invalidLength s!"UInt32 decoded value {m} exceeds 2^32 bound")
    | .error e => Except.error e) = .ok (n, rest)
  have h1 : n.toNat < 2 ^ 32 := UInt32.toNat_lt n
  have hbound : n.toNat < 256 ^ 8 := by
    have h3 : (256 : Nat) ^ 8 = 18446744073709551616 := by decide
    have h4 : (2 : Nat) ^ 32 = 4294967296 := by decide
    omega
  rw [nat_roundtrip n.toNat rest hbound]
  dsimp only
  have h4g : n.toNat < 4294967296 := by
    have h4 : (2 : Nat) ^ 32 = 4294967296 := by decide
    omega
  rw [dif_pos h4g]
  congr 1
  congr 1
  show UInt32.ofNat n.toNat = n
  exact UInt32.ofNat_toNat

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

/-! ## Encoder-injectivity foundation (Workstream EI.1)

The lemmas below form the atomic-injectivity layer of the
encoder-injectivity stack (`docs/planning/encoder_injectivity_plan.md`
§4.1).  They are consumed by:

  * `encodeSortedPairs_injective` (EI.1.e in
    `LegalKernel/Encoding/State.lean`) — the load-bearing map-level
    injectivity lemma.
  * Every per-sub-state `*_encode_injective` theorem (EI.2 – EI.7).

The layer ships:

  * **EI.1.b** — `Encodable_via_decode_inj` (and `_append` variant):
    "decode both sides" packaged as a polymorphic helper so every
    atomic-carrier injectivity proof is a three-line specialisation.
  * **EI.1.d** — `encodeAsBytes_eq_injective_of_encode_eq_injective`:
    framing-injectivity for the four `*.encodeAsBytes` wrappers used
    by the encoder stack (BalanceMap / DepositRecord /
    PendingWithdrawal / LocalPolicy).  The `Equiv`-flavoured sibling
    lives in `Encoding/State.lean` (where `Std.TreeMap.Equiv` is in
    scope).
  * **EI.1.f** — `uIntN_encode_injective` quartet: unconditional
    injectivity for the four `UIntN` carriers.
  * **EI.1.g** — Project-wrapper re-exports: `ActorId`, `Amount`,
    `Nonce`, `ResourceId`, `PublicKey`, `DepositId`, `WithdrawalId`.
  * **EI.1.h** — `list_encode_injective` / `option_encode_injective`:
    parameterised injectivity for the composite carriers, derived
    from `list_roundtrip` / `option_roundtrip` via the
    "decode both sides" technique.
  * **EI.1.i** — `HasInjective` typeclass: ergonomic wrapper for
    unconditional atomic-carrier injectivity; per-sub-state proofs
    that prefer instance-search can lean on it instead of passing
    explicit hypotheses.

None of these touch the trusted computing base.  `#print axioms`
on every shipped lemma is a subset of
`[propext, Classical.choice, Quot.sound]`. -/

namespace Encodable

/-! ### EI.1.b — Decode-both-sides polymorphic helper -/

/-- "Decode both sides" injectivity helper: for any `Encodable T`
    with a round-trip lemma `decode (encode v) = .ok (v, [])`,
    equal encoded bytes imply equal values.  Used as a one-line
    discharge for every atomic-carrier injectivity proof in EI.1.f
    / EI.1.g and as a sub-step in EI.1.h.

    EI.1.b — `docs/planning/encoder_injectivity_plan.md` §4.1. -/
theorem Encodable_via_decode_inj
    {T : Type} [Encodable T]
    (hRound : ∀ (v : T),
      Encodable.decode (T := T) (Encodable.encode v) = .ok (v, []))
    {v₁ v₂ : T} (h : Encodable.encode v₁ = Encodable.encode v₂) :
    v₁ = v₂ := by
  have r₁ := hRound v₁
  have r₂ := hRound v₂
  rw [h] at r₁
  have heq : (Except.ok (v₁, ([] : Stream)) : Except DecodeError (T × Stream))
           = Except.ok (v₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-- Residual-suffix variant of `Encodable_via_decode_inj`.  Most
    shipped round-trip lemmas have the stronger form
    `decode (encode v ++ rest) = .ok (v, rest)`; this variant
    accepts that hypothesis directly, specialising to `rest = []`
    internally. -/
theorem Encodable_via_decode_inj_append
    {T : Type} [Encodable T]
    (hRound : ∀ (v : T) (rest : Stream),
      Encodable.decode (T := T) (Encodable.encode v ++ rest) = .ok (v, rest))
    {v₁ v₂ : T} (h : Encodable.encode v₁ = Encodable.encode v₂) :
    v₁ = v₂ := by
  apply Encodable_via_decode_inj (hRound := ?_) h
  intro v
  have := hRound v []
  simpa using this

end Encodable

/-! ### EI.1.d — Framing-injectivity helper (`Eq` variant)

The `*.encodeAsBytes` framing pattern is used four times in the
encoder stack:

  * `BalanceMap.encodeAsBytes`       (`Encoding/State.lean`)
  * `DepositRecord.encodeAsBytes`    (`Encoding/State.lean`)
  * `PendingWithdrawal.encodeAsBytes` (`Encoding/State.lean`)
  * `LocalPolicy.encodeAsBytes`      (`Encoding/LocalPolicy.lean`)

Each wraps an inner-encoder `Stream` output as a length-prefixed
`ByteArray` for placement in an outer map's value slot.  The helper
below lifts inner-encoder `Eq`-injectivity through the
`ByteArray.mk (encode x).toArray` framing wrapper; the
`Equiv`-flavoured variant (for `BalanceMap`) lives in
`Encoding/State.lean` where `Std.TreeMap.Equiv` is in scope. -/

/-- Polymorphic framing-injectivity helper: if an inner encoder
    `encode : Inner → Stream` is `Eq`-injective, then the framed
    form `ByteArray.mk (encode x).toArray` is also `Eq`-injective.

    Discharges by combining (a) structure injectivity of
    `ByteArray.mk` on its single field and (b) `List.toArray`
    injectivity via `List.toList_toArray`.

    EI.1.d (Eq variant) — `docs/planning/encoder_injectivity_plan.md`
    §4.1.  The `Equiv` sibling lives in `Encoding/State.lean`. -/
theorem encodeAsBytes_eq_injective_of_encode_eq_injective
    {Inner : Type} (encode : Inner → Stream)
    (hInj : ∀ {x y : Inner}, encode x = encode y → x = y)
    {x y : Inner}
    (h : ByteArray.mk (encode x).toArray = ByteArray.mk (encode y).toArray) :
    x = y := by
  -- `ByteArray.mk` is a single-field structure constructor; injection
  -- extracts equality on the underlying `Array UInt8`.
  have h_arr : (encode x).toArray = (encode y).toArray := by
    injection h
  -- `List.toArray` is injective via the `List.toList_toArray` round-
  -- trip: `(encode x).toArray.toList = (encode y).toArray.toList` lifts
  -- to `encode x = encode y` by rewriting both sides.
  have h_list : (encode x).toArray.toList = (encode y).toArray.toList := by
    rw [h_arr]
  rw [List.toList_toArray, List.toList_toArray] at h_list
  exact hInj h_list

/-! ### EI.1.f — UIntN injectivity quartet

Each `UIntN` encoder routes through `Encodable.encode (T := Nat) n.toNat`.
Round-trip is unconditional (the source UIntN range is statically
`< 2^N ≤ 2^64`); injectivity falls out via `Encodable_via_decode_inj_append`
applied to the corresponding `uIntN_roundtrip` lemma. -/

/-- `UInt8` encode injectivity (unconditional). -/
theorem uInt8_encode_injective :
    Function.Injective (Encodable.encode : UInt8 → Stream) := by
  intro v₁ v₂ h
  exact Encodable.Encodable_via_decode_inj_append uInt8_roundtrip h

/-- `UInt16` encode injectivity (unconditional). -/
theorem uInt16_encode_injective :
    Function.Injective (Encodable.encode : UInt16 → Stream) := by
  intro v₁ v₂ h
  exact Encodable.Encodable_via_decode_inj_append uInt16_roundtrip h

/-- `UInt32` encode injectivity (unconditional). -/
theorem uInt32_encode_injective :
    Function.Injective (Encodable.encode : UInt32 → Stream) := by
  intro v₁ v₂ h
  exact Encodable.Encodable_via_decode_inj_append uInt32_roundtrip h

/-- `UInt64` encode injectivity (unconditional). -/
theorem uInt64_encode_injective :
    Function.Injective (Encodable.encode : UInt64 → Stream) := by
  intro v₁ v₂ h
  exact Encodable.Encodable_via_decode_inj_append uInt64_roundtrip h

/-! ### EI.1.h — `List α` / `Option α` injectivity (parameterised)

Both lemmas are parameterised on a per-element round-trip
hypothesis (`ElemRoundtrip α`).  The `list_encode_injective`
form additionally requires the canonical-encoding length bound
on each input list (so the CBE head's pair-count fits in 8 bytes);
`option_encode_injective` is unconditional. -/

/-- `List α` encode injectivity, parameterised on per-element
    round-trip and conditional on the canonical-encoding length
    bound (each input list has `length < 2^64`).

    EI.1.h — `docs/planning/encoder_injectivity_plan.md` §4.1. -/
theorem list_encode_injective {α : Type} [Encodable α]
    (hαRound : ElemRoundtrip α)
    {xs₁ xs₂ : List α}
    (h_len₁ : xs₁.length < 256 ^ 8)
    (h_len₂ : xs₂.length < 256 ^ 8)
    (h : Encodable.encode (T := List α) xs₁ = Encodable.encode (T := List α) xs₂) :
    xs₁ = xs₂ := by
  have r₁ : Encodable.decode (T := List α) (Encodable.encode xs₁) = .ok (xs₁, []) := by
    have := list_roundtrip hαRound xs₁ [] h_len₁
    simpa using this
  have r₂ : Encodable.decode (T := List α) (Encodable.encode xs₂) = .ok (xs₂, []) := by
    have := list_roundtrip hαRound xs₂ [] h_len₂
    simpa using this
  rw [h] at r₁
  have heq : (Except.ok (xs₁, ([] : Stream)) : Except DecodeError (List α × Stream))
           = Except.ok (xs₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-- `Option α` encode injectivity, parameterised on per-element
    round-trip.  Unconditional in the `Option` count (the CBE head
    payload is 0 or 1, trivially `< 2^64`).

    EI.1.h — `docs/planning/encoder_injectivity_plan.md` §4.1. -/
theorem option_encode_injective {α : Type} [Encodable α]
    (hαRound : ElemRoundtrip α)
    {o₁ o₂ : Option α}
    (h : Encodable.encode (T := Option α) o₁ = Encodable.encode (T := Option α) o₂) :
    o₁ = o₂ := by
  have r₁ : Encodable.decode (T := Option α) (Encodable.encode o₁) = .ok (o₁, []) := by
    have := option_roundtrip hαRound o₁ []
    simpa using this
  have r₂ : Encodable.decode (T := Option α) (Encodable.encode o₂) = .ok (o₂, []) := by
    have := option_roundtrip hαRound o₂ []
    simpa using this
  rw [h] at r₁
  have heq : (Except.ok (o₁, ([] : Stream)) : Except DecodeError (Option α × Stream))
           = Except.ok (o₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ### EI.1.i — `Encodable.HasInjective` ergonomic class

Typeclass-friendly wrapper for *unconditional* atomic-carrier
injectivity.  Downstream per-sub-state proofs that prefer instance-
search over explicit hypotheses can lean on `Encodable.HasInjective`
instances rather than threading the per-type injectivity lemma
through every proof.

Only types whose injectivity is unconditional (no `< 2^64`
hypothesis) get a `HasInjective` instance.  Conditional types
(`Nat`, `ByteArray`, and the `Nat`-aliased project wrappers
`Amount`, `Nonce`, `DepositId`, `WithdrawalId`; the `ByteArray`-
aliased `PublicKey`) keep their bound-quantified `*_encode_injective`
lemmas in explicit-hypothesis form.

If instance-search becomes a build-time hot spot, the maintainer may
strike this class without affecting the load-bearing lemmas — every
downstream proof can pass the per-type injectivity hypothesis
explicitly. -/

namespace Encodable

/-- Unconditional encode-injectivity for `T`: equal encodings imply
    equal values.  Only available when injectivity holds without
    a per-input numeric bound.  EI.1.i — see the section docstring
    for the design rationale. -/
class HasInjective (T : Type) [Encodable T] : Prop where
  /-- Equal encodings imply equal values, unconditionally on the
      values' magnitudes. -/
  encode_injective : Function.Injective (Encodable.encode : T → Stream)

namespace HasInjective

/-- `Bool` has unconditional encode injectivity. -/
instance instBool : HasInjective Bool where
  encode_injective := bool_encode_injective

/-- `BoundedNat` has unconditional encode injectivity (the `< 2^64`
    bound is internal to the type). -/
instance instBoundedNat : HasInjective BoundedNat where
  encode_injective := boundedNat_encode_injective

/-- `UInt8` has unconditional encode injectivity. -/
instance instUInt8 : HasInjective UInt8 where
  encode_injective := uInt8_encode_injective

/-- `UInt16` has unconditional encode injectivity. -/
instance instUInt16 : HasInjective UInt16 where
  encode_injective := uInt16_encode_injective

/-- `UInt32` has unconditional encode injectivity. -/
instance instUInt32 : HasInjective UInt32 where
  encode_injective := uInt32_encode_injective

/-- `UInt64` has unconditional encode injectivity.  Covers the
    `ActorId` and `ResourceId` project wrappers (both `abbrev`-aliased
    to `UInt64`). -/
instance instUInt64 : HasInjective UInt64 where
  encode_injective := uInt64_encode_injective

end HasInjective

end Encodable

end Encoding
end LegalKernel
