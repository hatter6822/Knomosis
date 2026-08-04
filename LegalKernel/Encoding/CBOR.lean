-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.CBOR — primitive byte-level codec.

Phase 4 WU 4.1 (foundation).  Defines the byte-level helpers that
every higher-level `Encodable` instance composes:

  * `DecodeError` — the closed inductive of decoder failures
    (Genesis Plan §8.8.6).
  * `natToBytesLE` / `natFromBytesLE` — little-endian fixed-width
    `Nat ↔ List UInt8` codec, with a structural-induction round-trip
    proof.
  * `cborHeadEncode` / `cborHeadDecode` — single-tag-byte plus 8-byte
    length / value head, used by every higher-level encoder.

**Deviation from Genesis Plan §8.8.2 (documented).**  The Genesis
Plan §8.8.2 prescribes "canonical CBOR" with minimal-form integer
length encoding (the 5-way size-bucket of RFC 8949 §3.1).  Phase 4
ships a *simpler* canonical binary encoding, which we call **CBE**
(Knomosis Binary Encoding):

  * Each uint is fixed-width: 1 type byte + 8 little-endian value bytes
    (9 bytes total).
  * Byte / text strings are fixed length-prefixed (8 LE bytes).
  * Arrays / maps carry an 8-byte LE count.
  * Map keys are sorted ascending by their canonical CBE encoding
    (deterministic ordering).
  * Integers are bounded to `n < 2^64` (canonical CBOR's 8-byte
    length form); larger inputs are encoded as their `n mod 2^64`
    truncation, with the round-trip theorem conditional on the
    bound.  This matches the §8.5 plan that Phase 4 marshals
    `Nat → UInt64` with an explicit bound check at the deployment
    boundary.

CBE preserves every safety property the Genesis Plan §8.8 lists
(determinism, canonicality, injectivity, well-defined round-trip)
but is **not** wire-compatible with strict-canonical CBOR
implementations.  The trade-off is intentional: CBE's fixed-width
shape lets us prove round-trip and injectivity by structural
induction, with no case-splitting on uint size buckets and no
bit-level reasoning on the UInt8 representation.  Phase 5's runtime
adaptor MAY add a CBE↔canonical-CBOR translation layer for wire
interop; the kernel's proof obligations are independent of that
adaptor.

This module is **not** part of the trusted computing base.  Bugs
here produce wrong serialisations (which downstream
`decode_encode_roundtrip` proofs would catch at build time), but
cannot violate any kernel invariant — the kernel never serialises
or deserialises bytes, only the deployment-facing runtime adaptor
(Phase 5) does.
-/

/-! ## `ByteArray` equality is lawful

Lean core gives `ByteArray` a `BEq` instance but no `LawfulBEq`, so
`a == b` and `a = b` are formally unrelated: neither
`a = b → (a == b) = true` nor `(a == b) = true → a = b` is available.
That gap is not harmless in a project whose every content-addressed
identity — cell keys, commitments, encoded values — is a `ByteArray`
compared with `==`, because a side condition phrased on `≠` is then
*not* the condition the code decides, and a lemma proved about one
does not apply to the other.

The instance is true and its proof is three lines: `ByteArray` is a
one-field structure over `Array UInt8`, its `BEq` is that field's, and
`Array UInt8` is lawful.  Stated here rather than at the point of use
because it is a fact about the byte-level foundation, and an instance
in scope in some modules and not others is worse than none — `simp`
would close a goal in one file and fail on it in the next. -/

/-- `ByteArray`'s `==` decides its `=`.

    Both directions, and both are used: `eq_of_beq` is what lets a
    computed key comparison discharge a propositional side condition,
    and `rfl` is what lets a propositional distinctness hypothesis
    discharge a computed one. -/
instance : LawfulBEq ByteArray where
  eq_of_beq {a b} h := by
    cases a; cases b
    exact congrArg ByteArray.mk (eq_of_beq h)
  rfl {a} := by
    cases a
    exact beq_self_eq_true (α := Array UInt8) _

namespace LegalKernel
namespace Encoding

/-! ## DecodeError (§8.8.6) -/

/-- Closed inductive of decoder failures.  Mirrors Genesis Plan
    §8.8.6.  Each constructor records enough information for a
    deployment to diagnose the failure (e.g. which byte position it
    occurred at, which type tag was expected).

    The decoder rejects ill-formed encodings: a `nonCanonical` result
    indicates that the input *would* parse under a permissive decoder
    but is rejected here because it violates the canonicalisation
    discipline (e.g. an unsorted map key sequence).  This is critical
    for security — a permissive decoder would let an attacker forge
    an alternative-but-equally-valid encoding of the same value with
    a different signature input. -/
inductive DecodeError where
  /-- Decoder ran out of bytes mid-item. -/
  | unexpectedEof
  /-- Got CBE type tag `got`; expected type tag `expected`. -/
  | invalidMajorType (got : UInt8) (expected : UInt8)
  /-- An `Action`-layer or other tagged constructor index was out of
      range (e.g. `Action` has 8 constructors numbered 0..7; a tag of
      9 fails this check). -/
  | invalidConstructorIndex (got : Nat)
  /-- A canonicalisation rule was violated (unsorted map keys,
      duplicate map keys, etc.). -/
  | nonCanonical (reason : String)
  /-- Decoder consumed all expected bytes but the input has `count`
      trailing bytes after the value.  Top-level decoders reject this. -/
  | trailingBytes (count : Nat)
  /-- A length / count prefix was malformed (e.g. claimed a length
      larger than the remaining buffer). -/
  | invalidLength (reason : String)
  deriving Repr, DecidableEq

/-! ## CBE major type tags (§8.8.3, restricted)

CBE uses the same major-type *meanings* as canonical CBOR (uint,
bytes, text, array, map), but encodes them as a single fixed type
byte rather than packing the additional-info field into the same
byte.  The constants below give the type-byte values; downstream
encoders / decoders use them directly. -/

/-- Type byte for a CBE unsigned integer (canonical CBOR major type 0). -/
abbrev cbeTagUint  : UInt8 := 0x00

/-- Type byte for a CBE **256-bit amount** — a value-carrying uint with a
    32-byte little-endian body instead of the 8-byte body `cbeTagUint`
    uses.

    Value-carrying fields are the ones that legitimately exceed `2^64`: a
    balance denominated in wei passes that bound at ~18.45 ETH, and such
    fields additionally *accumulate*, so no gate on individual input
    amounts can keep a stored value inside a narrow body.  Encoding an
    out-of-range value through a too-narrow head silently truncates it,
    which makes `State.encode` — and therefore the L1 state root —
    non-injective: two values differing by exactly the modulus commit to
    the same root, and a value at a nonzero multiple of it becomes
    byte-identical to the *absent* encoding, so the cell drops out of
    `stateCellEntries` and the root stops seeing it at all.

    That defect has now been closed twice at successively wider moduli
    (`2^64`, then `2^128`).  The body is 32 bytes so the ceiling is
    `2^256` — the width of an EVM word, which is also the widest value
    any mirrored L1 surface can hold, so there is no wider head to
    migrate to next.  `Laws.AmountBound` makes the bound a checked
    precondition rather than a standing assumption, which is what stops
    the cycle rather than merely deferring it.

    What stays on the 8-byte `cbeTagUint` head is **structurally bounded
    or non-accumulating**: identifiers (`ActorId` / `ResourceId`, which
    are `UInt64` at the source and cannot exceed the range), constructor
    tags, list counts and every length prefix.  A list length does not
    accumulate the way a balance does, and `2^64` elements is not a
    reachable quantity, so widening those would cost wire size for no
    benefit.  The distinct tag keeps the two forms unambiguous for a
    decoder that knows which shape a field should have.

    The tag value moved when the body widened.  Holding the old byte at
    a new width would let a stale decoder read a 33-byte value as 17 and
    silently mis-parse the remainder of the stream; changing it makes
    that decoder fail closed on `invalidMajorType` instead. -/
abbrev cbeTagAmount : UInt8 := 0x06

/-- Type byte for a CBE byte string (canonical CBOR major type 2). -/
abbrev cbeTagBytes : UInt8 := 0x02

/-- Type byte for a CBE text string (canonical CBOR major type 3). -/
abbrev cbeTagText  : UInt8 := 0x03

/-- Type byte for a CBE array (canonical CBOR major type 4). -/
abbrev cbeTagArray : UInt8 := 0x04

/-- Type byte for a CBE map (canonical CBOR major type 5). -/
abbrev cbeTagMap   : UInt8 := 0x05

/-! ## Stream type — the byte stream the codec operates on

We use `List UInt8` (rather than `ByteArray`) as the working byte
stream because every recursive codec we write decomposes on its
head — a structural feature of `List`, not `ByteArray`.  The
typeclass boundary (`Encodable.encode : T → ByteArray`) converts
between the two representations using
`ByteArray.toList` / `List.toByteArray`. -/

/-- The byte stream type used inside the codec.  All round-trip and
    injectivity proofs are stated over `Stream`. -/
abbrev Stream : Type := List UInt8

/-! ## Little-endian fixed-width Nat codec

For `n : Nat` and `k : Nat`, `natToBytesLE n k` writes the lowest `k`
bytes of `n` in little-endian (least-significant byte first) order.
`natFromBytesLE` reads `k` bytes back and returns the resulting
`Nat` plus the residual stream.  Round-trip holds for `n < 256^k`. -/

/-- Little-endian fixed-width encoder.  The output has length exactly
    `k`; the `i`-th byte (0-indexed) is `(n >>> (8 * i)) &&& 0xFF`. -/
def natToBytesLE (n : Nat) : Nat → Stream
  | 0     => []
  | k + 1 => (n % 256).toUInt8 :: natToBytesLE (n / 256) k

/-- Length of `natToBytesLE n k` is exactly `k`. -/
theorem natToBytesLE_length (n : Nat) (k : Nat) :
    (natToBytesLE n k).length = k := by
  induction k generalizing n with
  | zero      => rfl
  | succ k ih => simp [natToBytesLE, ih]

/-- Little-endian fixed-width decoder.  Reads `k` bytes from the front
    of `s`; returns the recovered `Nat` and the residual stream.
    Fails with `unexpectedEof` if `s` has fewer than `k` bytes. -/
def natFromBytesLE : Stream → Nat → Except DecodeError (Nat × Stream)
  | s,         0     => .ok (0, s)
  | [],        _ + 1 => .error .unexpectedEof
  | b :: rest, k + 1 =>
    match natFromBytesLE rest k with
    | .ok (high, rest') => .ok (b.toNat + 256 * high, rest')
    | .error e          => .error e

/-! ### Round-trip for `natToBytesLE` ↔ `natFromBytesLE`

The proof is direct structural induction on `k`.  The inductive
hypothesis applies because `n / 256 < 256 ^ k` whenever `n < 256
^ (k+1)`, and the inductive step uses two facts:

  * `(n % 256).toUInt8.toNat = n % 256`  (since `n % 256 < 256`),
    captured by `nat_lt_256_toUInt8_toNat_eq` below.
  * `n % 256 + 256 * (n / 256) = n`  (the standard
    `Nat.div_add_mod`-style arithmetic identity, dispatched by
    `omega` at the end of each branch).

The `n < 256^k` precondition lets `Nat.mod_eq_of_lt` collapse the
modular reduction at the recursive step. -/

/-- For `m < 256`, the `Nat → UInt8 → Nat` round-trip is the identity.
    Used by both `natFromBytesLE_natToBytesLE` and
    `natFromBytesLE_append_natToBytesLE` to discharge the
    `(n % 256).toUInt8.toNat = n % 256` step. -/
private theorem nat_lt_256_toUInt8_toNat_eq (m : Nat) (h : m < 256) :
    m.toUInt8.toNat = m := by
  -- UInt8.toNat (m.toUInt8) = m % 256; for m < 256 the modular reduction is m.
  show (m % 256) = m
  exact Nat.mod_eq_of_lt h

/-- Headline round-trip for the LE fixed-width codec.  For
    `n < 256^k`, decoding the encoding of `n` returns `(n, [])`. -/
theorem natFromBytesLE_natToBytesLE (n : Nat) (k : Nat) (h : n < 256 ^ k) :
    natFromBytesLE (natToBytesLE n k) k = .ok (n, []) := by
  induction k generalizing n with
  | zero =>
    -- 256^0 = 1, so n = 0; both sides are .ok (0, []).
    have hn : n = 0 := by
      have : n < 1 := h
      omega
    subst hn
    rfl
  | succ k ih =>
    -- LHS: natFromBytesLE ((n%256).toUInt8 :: natToBytesLE (n/256) k) (k+1)
    --   = do let (high, rest') ← natFromBytesLE (natToBytesLE (n/256) k) k
    --        .ok ((n%256).toUInt8.toNat + 256 * high, rest')
    -- IH: natFromBytesLE (natToBytesLE (n/256) k) k = .ok (n/256 % 256^k, []).
    -- Combine: .ok ((n%256).toUInt8.toNat + 256 * (n/256 % 256^k), []).
    -- Simplify using nat_lt_256_toUInt8_toNat_eq and nat_mod_pow_succ.
    -- The IH applies because (n/256) < 256^k whenever n < 256^(k+1).
    have hsmall : (n / 256) < 256 ^ k := by
      have hpow : (256 : Nat) ^ (k+1) = 256 ^ k * 256 := by rw [Nat.pow_succ]
      rw [hpow] at h
      exact Nat.div_lt_iff_lt_mul (by decide : (0 : Nat) < 256) |>.mpr h
    -- Unfold one level of natToBytesLE / natFromBytesLE.
    simp only [natToBytesLE, natFromBytesLE]
    rw [ih (n / 256) hsmall]
    -- Reduce the match on the .ok branch.
    dsimp only
    -- Goal: .ok ((n%256).toUInt8.toNat + 256 * (n/256), []) = .ok (n, [])
    rw [nat_lt_256_toUInt8_toNat_eq _ (Nat.mod_lt _ (by decide : (0 : Nat) < 256))]
    -- Goal: .ok (n % 256 + 256 * (n/256), []) = .ok (n, [])
    -- This equals .ok (n, []) by the standard div / mod identity.
    congr 1
    congr 1
    omega

/-! ## CBE head: `<typeTag : UInt8> :: <8-byte LE Nat>`

The CBE head is a single type-tag byte followed by an 8-byte
little-endian Nat payload (length / count / value).  Fixed-width
makes round-trip provable by direct rewriting on the head byte. -/

/-- Encode a CBE head: 1 type-tag byte + 8-byte LE length / value.
    For uint payloads (`major = cbeTagUint`), the 8 bytes encode the
    value directly.  For length-prefixed types (`cbeTagBytes`,
    `cbeTagText`, `cbeTagArray`, `cbeTagMap`), they encode the
    payload's element count.

    For `n ≥ 2^64`, the high bits of `n` are silently truncated.
    This is **outside** the canonical-encoding bound; the
    `cborHeadRoundtrip` theorem is conditional on `n < 2^64`
    accordingly.  Deployments MUST gate `Amount` arguments at the
    runtime boundary (Genesis Plan §8.5). -/
def cborHeadEncode (major : UInt8) (n : Nat) : Stream :=
  major :: natToBytesLE n 8

/-- Decode a CBE head at the start of `s`, expecting type tag
    `major`.  Returns the recovered Nat and the residual stream.

    Rejects:

      * tag bytes that do not match `major` (`invalidMajorType`).
      * inputs shorter than 9 bytes (`unexpectedEof`).

    No "non-canonical" rejection is necessary — the fixed-width form
    has exactly one byte sequence per Nat in `[0, 2^64)`. -/
def cborHeadDecode (s : Stream) (major : UInt8) :
    Except DecodeError (Nat × Stream) :=
  match s with
  | []       => .error .unexpectedEof
  | b :: rest =>
    if b != major then
      .error (.invalidMajorType b major)
    else
      natFromBytesLE rest 8

/-- Generalised version of `natFromBytesLE_natToBytesLE` with a
    residual suffix.  Decoding `natToBytesLE n k ++ rest` consumes
    exactly `k` bytes and leaves `rest` untouched. -/
theorem natFromBytesLE_append_natToBytesLE
    (n : Nat) (k : Nat) (rest : Stream) (h : n < 256 ^ k) :
    natFromBytesLE (natToBytesLE n k ++ rest) k = .ok (n, rest) := by
  induction k generalizing n with
  | zero =>
    have hn : n = 0 := by
      have : n < 1 := h
      omega
    subst hn
    show natFromBytesLE ([] ++ rest) 0 = .ok (0, rest)
    simp [natFromBytesLE]
  | succ k ih =>
    have hsmall : (n / 256) < 256 ^ k := by
      have hpow : (256 : Nat) ^ (k+1) = 256 ^ k * 256 := by rw [Nat.pow_succ]
      rw [hpow] at h
      exact Nat.div_lt_iff_lt_mul (by decide : (0 : Nat) < 256) |>.mpr h
    simp only [natToBytesLE, List.cons_append, natFromBytesLE]
    rw [ih (n / 256) hsmall]
    dsimp only
    rw [nat_lt_256_toUInt8_toNat_eq _ (Nat.mod_lt _ (by decide : (0 : Nat) < 256))]
    congr 1
    congr 1
    omega

/-- Headline round-trip: encoding `(major, n)` and decoding under the
    same major returns `(n, "")` for any `n < 2^64`.  Direct
    consequence of `natFromBytesLE_natToBytesLE` and the head-byte
    `if`-elimination. -/
theorem cborHeadRoundtrip (major : UInt8) (n : Nat) (h : n < 256 ^ 8) :
    cborHeadDecode (cborHeadEncode major n) major = .ok (n, []) := by
  unfold cborHeadEncode cborHeadDecode
  simp
  exact natFromBytesLE_natToBytesLE n 8 h

/-- Round-trip composed with a residual suffix: encoding `(major, n)`
    and prepending the result to any byte stream `rest`, then
    decoding, yields `(n, rest)`.  Composition lemma used by
    higher-level encoders / decoders to chain encodings without
    losing the suffix. -/
theorem cborHeadRoundtrip_append (major : UInt8) (n : Nat) (rest : Stream)
    (h : n < 256 ^ 8) :
    cborHeadDecode (cborHeadEncode major n ++ rest) major = .ok (n, rest) := by
  unfold cborHeadEncode cborHeadDecode
  simp
  exact natFromBytesLE_append_natToBytesLE n 8 rest h

/-! ## The 256-bit amount head

The `cbeTagAmount` counterpart of `cborHeadEncode` / `cborHeadDecode`:
a 33-byte head (tag byte + 32 little-endian body bytes) carrying a
value in `[0, 2^256)`.  Everything below mirrors the 8-byte head
exactly — the underlying `natToBytesLE` / `natFromBytesLE` helpers are
already width-parametric, so the width is the only difference. -/

/-- Encode a 256-bit CBE amount head: the `cbeTagAmount` type byte
    followed by 32 little-endian body bytes.

    Total, and lossy only above `2^256` — the width of an EVM word, so
    no mirrored L1 surface can hold a value this head cannot.  Unlike
    the `2^128` bound it replaces, the ceiling is not merely far from
    reachable values but is *enforced*: `Laws.AmountBound` carries it as
    a precondition conjunct on every balance-increasing law. -/
def cborAmountHeadEncode (n : Nat) : Stream :=
  cbeTagAmount :: natToBytesLE n 32

/-- Decode a 256-bit CBE amount head.  Rejects a tag byte that is not
    `cbeTagAmount` (`invalidMajorType`) and inputs shorter than 33 bytes
    (`unexpectedEof`).

    As with the 8-byte head, no non-canonicality check is needed: the
    fixed-width body gives exactly one byte sequence per value in
    `[0, 2^256)`. -/
def cborAmountHeadDecode (s : Stream) :
    Except DecodeError (Nat × Stream) :=
  match s with
  | []       => .error .unexpectedEof
  | b :: rest =>
    if b != cbeTagAmount then
      .error (.invalidMajorType b cbeTagAmount)
    else
      natFromBytesLE rest 32

/-- The amount head is 33 bytes wide. -/
theorem cborAmountHeadEncode_length (n : Nat) :
    (cborAmountHeadEncode n).length = 33 := by
  unfold cborAmountHeadEncode
  simp [natToBytesLE_length]

/-- Amount-head round-trip with a suffix: for `n < 2^256`, decoding
    `cborAmountHeadEncode n ++ rest` returns `(n, rest)`. -/
theorem cborAmountHeadRoundtrip_append (n : Nat) (rest : Stream)
    (h : n < 256 ^ 32) :
    cborAmountHeadDecode (cborAmountHeadEncode n ++ rest) = .ok (n, rest) := by
  unfold cborAmountHeadEncode cborAmountHeadDecode
  simp
  exact natFromBytesLE_append_natToBytesLE n 32 rest h

/-- Amount-head round-trip with no suffix. -/
theorem cborAmountHeadRoundtrip (n : Nat) (h : n < 256 ^ 32) :
    cborAmountHeadDecode (cborAmountHeadEncode n) = .ok (n, []) := by
  have := cborAmountHeadRoundtrip_append n [] h
  simpa using this

/-- Amount-head injectivity: two in-range values with equal encodings
    are equal.  The `EI.1`-tier lemma the amount-carrying encoders build
    on, exactly as `cborHeadEncode_injective` serves the 8-byte head. -/
theorem cborAmountHeadEncode_injective
    {n₁ n₂ : Nat} (h₁ : n₁ < 256 ^ 32) (h₂ : n₂ < 256 ^ 32)
    (h : cborAmountHeadEncode n₁ = cborAmountHeadEncode n₂) : n₁ = n₂ := by
  have d₁ := cborAmountHeadRoundtrip n₁ h₁
  have d₂ := cborAmountHeadRoundtrip n₂ h₂
  rw [h] at d₁
  have heq : (Except.ok (n₁, ([] : Stream)) : Except DecodeError (Nat × Stream))
           = Except.ok (n₂, []) := d₁.symm.trans d₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-- A 256-bit amount head never collides with an 8-byte uint head: the
    leading type byte differs (`cbeTagAmount` vs `cbeTagUint`).  This is
    what lets a decoder keep the two forms apart, and what stops a
    widened amount field from aliasing an identifier field. -/
theorem cborAmountHeadEncode_ne_cborHeadEncode (n₁ n₂ : Nat) :
    cborAmountHeadEncode n₁ ≠ cborHeadEncode cbeTagUint n₂ := by
  unfold cborAmountHeadEncode cborHeadEncode
  simp [cbeTagAmount, cbeTagUint]

/-! ## CBE-head injectivity (EI.1.c)

The first link in the encoder-injectivity stack
(`docs/planning/encoder_injectivity_plan.md` §4.1).  Used by the
load-bearing `encodeSortedPairs_injective` lemma to extract the
pair-count and major-tag from a CBE map header, and by every
per-sub-state injectivity proof to discriminate distinct
constructor tags at the top of a value. -/

/-- CBE-head injectivity: under the canonical-encoding bound, equal
    encoded heads imply equal major-tag and equal payload.

    The bound `n < 2^64` is required because `cborHeadEncode`'s
    8-byte LE payload silently truncates values ≥ 2^64 (via the
    modular wrap in `natToBytesLE`); without the bound, two
    distinct `Nat`s whose low 64 bits agree would encode
    identically.  Phase 5's runtime adaptor enforces the bound at
    the deployment boundary (Genesis Plan §8.5). -/
theorem cborHeadEncode_injective
    {major₁ major₂ : UInt8} {n₁ n₂ : Nat}
    (h₁ : n₁ < 256 ^ 8) (h₂ : n₂ < 256 ^ 8)
    (h : cborHeadEncode major₁ n₁ = cborHeadEncode major₂ n₂) :
    major₁ = major₂ ∧ n₁ = n₂ := by
  -- `cborHeadEncode m n = m :: natToBytesLE n 8`; List.cons.injEq
  -- splits into a major-tag equality and a tail-bytes equality.
  unfold cborHeadEncode at h
  have h_split :=
    (List.cons.injEq major₁ (natToBytesLE n₁ 8) major₂ (natToBytesLE n₂ 8)).mp h
  refine ⟨h_split.1, ?_⟩
  -- Decode both tails via natFromBytesLE 8 (round-trip under the
  -- canonical-encoding bound) to recover n₁ and n₂ from equal bytes.
  have r₁ := natFromBytesLE_natToBytesLE n₁ 8 h₁
  have r₂ := natFromBytesLE_natToBytesLE n₂ 8 h₂
  rw [h_split.2] at r₁
  -- r₁ : natFromBytesLE (natToBytesLE n₂ 8) 8 = .ok (n₁, [])
  -- r₂ : natFromBytesLE (natToBytesLE n₂ 8) 8 = .ok (n₂, [])
  have heq : (Except.ok (n₁, ([] : Stream)) : Except DecodeError (Nat × Stream))
           = Except.ok (n₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

end Encoding
end LegalKernel
