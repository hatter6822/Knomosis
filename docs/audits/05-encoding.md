# Audit 05 — Encoding modules

Line-by-line audit of all 10 files under `/home/user/Knomosis/LegalKernel/Encoding/`.
This is the CBE (Knomosis Binary Encoding) codec foundation: a deliberately
simpler subset of canonical CBOR (Genesis Plan §8.8.2-deviation,
documented in `CBOR.lean:23-58`) used to canonicalise `Action`,
`SignedAction`, `State`, dispute / verdict / policy data, and
fault-proof step / game commitments.

**Out-of-scope claim (per all 10 file docstrings):** none of these
modules is part of the trusted computing base. Bugs here produce
wrong serialisations that downstream round-trip / determinism proofs
would catch at build time, but cannot violate any kernel invariant
because the kernel never serialises or deserialises bytes — only the
deployment-facing runtime adaptor does. Verified independently below.

---

## 1. `LegalKernel/Encoding/CBOR.lean` (primitive byte-level codec)

### Imports
None — Lean core only (`namespace`, primitive types, `Nat`, `UInt8`,
`List`, `Except`). Reasonable: this is the codec foundation; no other
project module can be a dependency.

### Public surface
- `Stream : Type := List UInt8` — the working stream representation
  (`CBOR.lean:132`). Conversion to `ByteArray` is the public boundary
  (in `Encodable.lean`).
- Type-tag bytes (`CBOR.lean:107-119`): `cbeTagUint = 0x00`, `cbeTagBytes
  = 0x02`, `cbeTagText = 0x03`, `cbeTagArray = 0x04`, `cbeTagMap = 0x05`.
  Note: **`cbeTagBytes`** double-serves text strings (no separate text
  tag is used downstream); the comment at `CBOR.lean:113` and the
  reference in `SignInput.lean:79-82` confirm this.
- `DecodeError` inductive (`CBOR.lean:78-96`): closed set with `Repr,
  DecidableEq`. Variants: `unexpectedEof`, `invalidMajorType`,
  `invalidConstructorIndex`, `nonCanonical (reason : String)`,
  `trailingBytes (count : Nat)`, `invalidLength (reason : String)`.

### Codec primitives
- `natToBytesLE n k` (`CBOR.lean:143-145`): writes the low `k` LE bytes
  of `n`. Total — silently truncates if `n ≥ 256^k`.
- `natFromBytesLE` (`CBOR.lean:157-163`): reads `k` bytes, fails with
  `unexpectedEof` if input is shorter.
- `cborHeadEncode major n` (`CBOR.lean:244-245`): `major :: natToBytesLE
  n 8` — exactly **9 bytes**, no minimal-form bucketing. The docstring
  at `CBOR.lean:243` is explicit: "For `n ≥ 2^64`, the high bits of `n`
  are silently truncated." This is the encoder's lossiness; downstream
  `*_roundtrip` lemmas are conditional on `n < 256^8`.
- `cborHeadDecode s major` (`CBOR.lean:257-265`): single byte tag check
  + `natFromBytesLE _ 8`.

### Round-trip theorems
- `natFromBytesLE_natToBytesLE` (`CBOR.lean:192-225`): for `n < 256^k`,
  decoding the encoding returns `(n, [])`.
- `natFromBytesLE_append_natToBytesLE` (`CBOR.lean:270-292`): same with
  arbitrary suffix.
- `cborHeadRoundtrip` (`CBOR.lean:298-302`) and
  `cborHeadRoundtrip_append` (`CBOR.lean:309-314`): the headline 1-byte
  tag + 8 LE bytes round-trip. Both bounded `n < 256^8`.

### Sharp points
- **Silent truncation in `cborHeadEncode` for `n ≥ 2^64`.** The
  obligation to gate via `fieldsBounded` predicates is pushed entirely
  to callers. Every higher-level encoder reproduces this discipline.
- **Documentation honest about the CBOR deviation** (`CBOR.lean:23-51`).
  The fixed-width 9-byte uint form is explicitly **not wire-compatible
  with strict-canonical CBOR**; a future Phase-5 adaptor MAY add a
  translation layer. Reviewers should not confuse the documented
  "canonical CBOR" name with RFC 8949 §3.1 canonical form.
- **No collision-resistance claim on bytes** — only canonicality
  *within* a single type. See "Type-collision discipline" in
  `Encodable.lean:43-68`.

### Documentation drift
None observed. Module docstring (`CBOR.lean:9-59`) matches code precisely.

---

## 2. `LegalKernel/Encoding/Encodable.lean` (typeclass + primitive instances)

### Imports
- `LegalKernel.Encoding.CBOR` only. Reasonable.

### Typeclass
- `class Encodable (T : Type)` (`Encodable.lean:95-101`): two methods,
  `encode : T → Stream` and `decode : Stream → Except DecodeError (T ×
  Stream)`. **Round-trip and injectivity are stated as standalone
  theorems, NOT as typeclass methods.** This avoids the awkwardness of
  bound preconditions in a method signature, but means there is **no
  `LawfulEncodable` typeclass** — a buggy encoder/decoder pair can be
  instantiated without the type system noticing.

### `Encodable.decodeAll` / `encodeBytes` / `decodeAllBytes`
(`Encodable.lean:111-127`) — boundary helpers. `decodeAll` rejects
trailing bytes with `.trailingBytes rest.length`. `encodeBytes` uses
`ByteArray.mk (encode v).toArray`; `decodeAllBytes` uses
`bs.toList`.

### Primitive Encodable instances and their byte layouts

| Type        | Layout                              | Round-trip   | Injectivity   | Notes                                |
|-------------|-------------------------------------|--------------|---------------|--------------------------------------|
| `Bool`      | `cbeTagUint :: 8 LE bytes (0 or 1)` | unconditional | unconditional | Encoded as a `Nat`-shaped uint head  |
| `Nat`       | `cbeTagUint :: 8 LE bytes`          | `< 2^64`      | `< 2^64`      | Silently truncates for `n ≥ 2^64`    |
| `BoundedNat`| same                                | unconditional | unconditional | The `< 2^64` bound is in the struct  |
| `ByteArray` | `cbeTagBytes :: 8 LE len :: raw bytes` | `size < 2^64` | `size < 2^64` | Length-prefixed                   |
| `List α`    | `cbeTagArray :: 8 LE count :: <elems>` | parameterised `ElemRoundtrip α` + `length < 2^64` | not stated as Function.Injective | Element-recursive |
| `Option α`  | `cbeTagArray :: 8 LE (0 or 1) :: <elem if Some>` | parameterised | not stated | **Collides with `List α []` / `List α [v]`** |
| `UInt8`     | `via Nat`                           | unconditional | not as standalone theorem | range check on decode |
| `UInt16`    | `via Nat`                           | unconditional | not as standalone theorem |                       |
| `UInt32`    | `via Nat`                           | unconditional | not as standalone theorem |                       |
| `UInt64`    | `via Nat`                           | unconditional | not as standalone theorem |                       |

### Sharp points

1. **Type-collision is documented but not constrained.**
   `Encodable.lean:43-68` is explicit that distinct logical types
   share a byte representation (e.g. `Bool false` = `Nat 0`,
   `Option α none` = `List α []`). This is benign for the in-tree
   composite types (`Action`, `SignedAction`, `State`,
   `ExtendedState`) which fix field types at the type level. But
   the typeclass does not enforce schema-implicit usage — callers
   must commit to a fixed type at signing / hashing time. Any
   deployment that decodes raw bytes under the *wrong* type will
   succeed silently.

2. **`String` instance deliberately omitted** (`Encodable.lean:33-41`).
   The domain string in `SignInput.lean` is encoded byte-wise via
   `cborHeadEncode cbeTagBytes` instead. Acceptable, but worth noting:
   the `cbeTagText` constant (`CBOR.lean:113`) is defined but **never
   used** in the entire encoder suite.

3. **List decoder DoS hardening.** `decodeListN` (`Encodable.lean:408-416`)
   recurses on the declared count. A malicious encoder declaring a
   huge count is bounded by the implicit per-element minimum byte cost
   (≥ 9 bytes via `cborHeadDecode`), so recursion terminates in
   `stream.length / 9` steps. This is documented at
   `State.lean:154-163` (for `decodeMap`) but not at `Encodable.lean`'s
   `decodeListN` — minor drift; the analysis applies equally well.

4. **`ElemRoundtrip` / `ElemRoundtripIn` are `Prop` predicates, not
   typeclass instances.** Callers must pass these explicitly to
   `list_roundtrip` / `list_roundtrip_bounded`. There is no
   `LawfulEncodable α` typeclass that would generate them
   automatically — by design, but creates verbose proof obligations
   downstream.

5. **Bool-injectivity stated as `Function.Injective`** while `Nat` /
   `ByteArray` injectivities are stated as ∀-prefixed bounded equalities.
   Not a soundness issue, but inconsistent style.

### Documentation drift
The module docstring claims (line 23) "Per-type injectivity theorems
(`*_encode_injective`), derived from round-trip via the standard
decode-both-sides argument." Verified: `bool_encode_injective`
(`Encodable.lean:178-186`), `nat_encode_injective`
(`Encodable.lean:215-222`), `boundedNat_encode_injective`
(`Encodable.lean:280-289`), `byteArray_encode_injective`
(`Encodable.lean:380-389`) all exist. **No `list_encode_injective` or
`option_encode_injective`** is shipped — likely because parameterised
injectivity would require an `ElemInjective` predicate that no caller
needs. Worth flagging: the module docstring at lines 27-28 claims
universal coverage but `List α` and `Option α` are not actually covered.

---

## 3. `LegalKernel/Encoding/Action.lean` (Action codec)

### Imports
(`Action.lean:60-64`) `Authority.Action`, `Authority.LocalPolicySemantics`,
`Encoding.Encodable`, `Encoding.Disputes`, `Encoding.LocalPolicy`.
Reasonable: pulls in the inductive's definition and every variant's
inner-type encoder.

### Constructor-tag map (frozen at declaration order)

| Tag | Constructor              | Fields                                                  |
|-----|--------------------------|---------------------------------------------------------|
| 0   | `transfer`               | `r`, `sender`, `receiver`, `amount`                     |
| 1   | `mint`                   | `r`, `to`, `amount`                                     |
| 2   | `burn`                   | `r`, `fromActor`, `amount`                              |
| 3   | `freezeResource`         | `r`                                                     |
| 4   | `replaceKey`             | `actor`, `newKey` (CBE bstr)                            |
| 5   | `reward`                 | `r`, `to`, `amount`                                     |
| 6   | `distributeOthers`       | `r`, `excluded`, `amount`                               |
| 7   | `proportionalDilute`     | `r`, `excluded`, `totalReward`                          |
| 8   | `dispute`                | inner `Dispute`                                         |
| 9   | `disputeWithdraw`        | `idx`                                                   |
| 10  | `verdict`                | inner `Verdict`                                         |
| 11  | `rollback`               | `targetIdx`                                             |
| 12  | `registerIdentity`       | `actor`, `pk` (CBE bstr)                                |
| 13  | `deposit`                | `r`, `recipient`, `amount`, `depositId`                 |
| 14  | `withdraw`               | `r`, `sender`, `amount`, `recipientL1` (CBE bstr 20B)   |
| 15  | `declareLocalPolicy`     | inner `LocalPolicy`                                     |
| 16  | `revokeLocalPolicy`      | (no fields)                                             |
| 17  | `faultProofChallenge`    | `bh`, `s`, `e`, `cc`                                    |
| 18  | `faultProofResolution`   | `bh`, `gid`, `w`, `rfi`                                 |

**Docstring drift.** The header table at `Action.lean:27-47` stops at
tag 16 (`revokeLocalPolicy`) and does not list tags 17/18. Codegen
fence at `Action.lean:122-124`, `Action.lean:228-230`, `Action.lean:443-445`
is documented and respects the LX append-only contract; the doc
table just needs to add the two fault-proof rows.

### `Action.fieldsBounded` predicate
(`Action.lean:82-124`) — per-variant `< 2^64` conjunctions. Each
branch is decidable via `inferInstance` (`Action.lean:129-130`). The
`withdraw` variant (`Action.lean:105-112`) omits a `recipientL1` bound:
correct, because the address is encoded as a 20-byte ByteArray
(lossless via `EthAddress.toBytes`), and 20 < 2^64 unconditionally —
the comment at `Action.lean:106-110` explains the Audit-2 fix.

### `Action.encode` / `Action.decode`
(`Action.lean:137-230` / `:255-447`) — manual concatenation per variant,
manual `match` ladder for decoding. Each variant's encoded form starts
with `Encodable.encode (T := Nat) <tag>` (9 bytes: type-tag `0x00` plus
8 LE bytes of the constructor index). The decoder dispatches on the
first decoded `Nat`.

The decoder is **`Option`-flavoured** via `Except DecodeError`: every
malformed input produces a structured failure (`invalidMajorType`,
`invalidConstructorIndex`, `invalidLength`, `unexpectedEof`).

### `withdraw` decode safety (the Audit-2 fix)
(`Action.lean:381-403`) — reads `recipientL1` as `ByteArray` then
calls `Bridge.EthAddress.ofBytes`, rejecting non-20-byte streams.
Documentation at `Action.lean:107-110` and `:199-205` explains the
pre-audit Nat truncation bug. **Verified: the new code path is
lossless.**

### Round-trip + injectivity
- `action_roundtrip` (`Action.lean:495-808`) — per-variant `cases a`
  with explicit append-association rewrites, conditional on
  `fieldsBounded a`.
- `action_roundtrip_empty` (`Action.lean:811-814`).
- `action_encode_injective` (`Action.lean:818-827`) — bounded both sides.

### Helper round-trip lemmas (publicly exposed for `SignedAction`)
- `readUInt64Field_roundtrip` (`Action.lean:461-478`).
- `readNatField_roundtrip` (`Action.lean:485-488`).

### `Action.tag_matches_encode_tag` (LP.4)
(`Action.lean:849-877`) — provides an existential `tail : Stream` such
that `encode a = encode (Action.tag a) ++ tail`. Discharges the
LocalPolicy `denyTags` semantics: a clause's tag-based check (over
`Action.tag`) sees the same leading byte sequence as the wire format.

### Sharp points

1. **Hand-written decoder ladder is large and brittle.** 19 explicit
   `match` arms, each constructing the action and threading the
   residual stream by hand. Any divergence between `encode` and
   `decode` is caught at proof time by `action_roundtrip`, but the
   regression surface is wide. The LX-managed fence
   (`Action.lean:441-445`) is currently empty; once populated, codegen
   correctness is gated by `lake exe lex_codegen --check`.

2. **`Nat` fields stay as `Nat`, not `UInt64`, in fields like
   `idx`, `amount`, `tr`, `d`.** The decoder uses
   `Action.readNatField` (`Action.lean:249-251`) which delegates to
   the unbounded `Encodable.decode (T := Nat)`. **Result: a malicious
   stream can decode an `Action` whose `amount` field exceeds 2^64.**
   Re-encoding such a value silently truncates — encode-then-decode
   is not idempotent. This is documented at `SignedAction.lean:71-87`
   (for `nonce`) and the runtime adaptor is supposed to gate on
   `fieldsBounded` after decoding. Reviewers: this is the canonical
   sharp edge of the CBE design.

3. **`encode` does not enforce `fieldsBounded`.** A caller that
   constructs an `Action.transfer _ _ _ (2^64)` and encodes it
   produces 8 bytes of low-order amount and loses the high bits.
   This is intentional — `Action.encode` is total — but means the
   pair `(encode, decode)` is only the inverse-of-each-other on
   `fieldsBounded` actions. Cross-boundary callers (signature
   verification, log replay, fault-proof commitments) MUST gate.

### Documentation drift
- Header table (`Action.lean:27-47`) lists tags 0–16 but stops short
  of the new fault-proof tags 17/18 which are present in the code
  (`Action.lean:115-118`, `:215-226`, `:412-440`).
- The header comment at `Action.lean:39` describes tag 8 as `Dispute`
  but the inductive's actual order from `Authority/Action.lean` (not
  audited here) is what matters; the table is internally consistent
  with the encoder.

---

## 4. `LegalKernel/Encoding/SignedAction.lean` (SignedAction codec)

### Imports
(`SignedAction.lean:40-41`) `Authority.SignedAction`, `Encoding.Action`.
Minimal and reasonable.

### Layout
`[action ++ signer ++ nonce ++ sig]` — 4 fields concatenated, no
length prefix (the inner `Action` and `sig` are self-delimiting via
their own CBE heads).

### `SignedAction.fieldsBounded`
(`SignedAction.lean:53-57`): `Action.fieldsBounded st.action ∧
st.signer.toNat < 2^64 ∧ st.nonce < 2^64 ∧ st.sig.size < 2^64`.
Note: `signer.toNat < 2^64` is automatic since `signer : UInt64`; the
docstring at `SignedAction.lean:128-133` explains this is kept for
predicate symmetry / future API stability.

### Round-trip + injectivity
- `signedAction_roundtrip` (`SignedAction.lean:134-155`).
- `signedAction_roundtrip_empty` (`SignedAction.lean:158-162`).
- `signedAction_encode_injective` (`SignedAction.lean:165-174`).

All bounded on `fieldsBounded`.

### Sharp points

1. **Explicit acknowledgement of the nonce decoder gap.**
   (`SignedAction.lean:71-88`) The decoder reads `nonce : Nat` without
   enforcing `< 2^64`. A maliciously crafted stream can decode a
   `SignedAction` whose `nonce ≥ 2^64`, which would fail
   admissibility (via `expectsNonce`) but only at a much-later kernel
   step — not at the decoder. The runtime adaptor is supposed to
   gate on `SignedAction.fieldsBounded` post-decode, **before**
   invoking `apply_admissible`. **This is a layering responsibility,
   not a kernel-soundness issue.**

2. **No CBOR-style key-tagged map.** Genesis §8.8.3 prescribes a
   sorted-key CBOR map `{ 0: action, 1: signer, 2: nonce, 3: sig }`;
   CBE drops the key tags and uses fixed positional order
   (`SignedAction.lean:17-27`). Canonicalisation is preserved because
   the field type is fixed at the type level — there is exactly one
   byte sequence per `SignedAction` value (modulo the lossy-on-overflow
   caveat).

### Documentation drift
None observed. The header docstring's claim of "Phase 4 ships only
`SignedAction`'s encoding" (line 31) is stale — Phase 6 has since
added `Dispute` / `Verdict` encodings in `Disputes.lean` — but this
is a forward-looking comment, not a code claim.

---

## 5. `LegalKernel/Encoding/State.lean` (State + ExtendedState + BridgeState)

### Imports
(`State.lean:77-81`) `Authority.Nonce`, `Bridge.State`,
`Encoding.Encodable`, `Encoding.LocalPolicy`, `Encoding.SignedAction`.
Reasonable but heavyweight — `Encoding.SignedAction` pulls in `Action`
and `Authority.Action`. Note `open Std` (`State.lean:83`) for `TreeMap`.

### Sorted-pair helpers
- `encodeSortedPairs` (`State.lean:107-111`) — `cbeTagMap :: 8 LE
  count :: alternating <K-encode><V-encode>`.
- `decodeNPairs` (`State.lean:118-130`) — does **not** enforce key
  ordering.
- `keysStrictlyAscending` (`State.lean:136-142`) — checks strict
  ascending under `cmp`.
- `decodeMap` (`State.lean:164-176`) — calls `decodeNPairs`, then
  enforces `keysStrictlyAscending compare pairs` or returns
  `.nonCanonical`.

**Security property** (documented at `State.lean:90-100`): the
permissive decoder would let an attacker forge an
alternative-but-equally-valid encoding of the same state with a
different signature input. Verified: the canonicalisation check is
unconditional in `decodeMap`.

### Sub-state encoders
- `BalanceMap.encode` (`State.lean:197-198`): outer map of `ResourceId
  → BalanceMap` becomes pairs `(r.toNat, BalanceMap.encodeAsBytes
  bm)`. The inner `BalanceMap` is encoded then **wrapped as a
  ByteArray** before becoming a value slot. This length-prefixed
  framing is the only way to delimit inner maps in the outer
  pair-list. Critical for canonicality.
- `State.encode` (`State.lean:214-216`): outer sorted-pair map.
- `BridgeState.encode` (`State.lean:382-385`): `consumed ++ pending ++
  nextWdId`. The consumed and pending maps each use the inner-map
  framing pattern.
- `ExtendedState.encode` (`State.lean:450-455`): `base ++ nonces ++
  registry ++ bridge ++ localPolicies` — five segments concatenated.
- `NonceState.encode` / `KeyRegistry.encodeMap` /
  `LocalPolicies.encodeMap`: each is a sorted-pair map.

### `PendingWithdrawal.encode` (the Audit-2 fix)
(`State.lean:335-339`) — encodes `recipient : EthAddress` as a 20-byte
ByteArray. Pre-audit comment at `State.lean:329-334` documents the
truncation bug.

### Round-trip status — the sharp point
**There is NO `state_roundtrip` theorem.** What ships:
- `state_encode_deterministic` (`State.lean:527-529`): structural
  (trivially true, just `h ▸ rfl`).
- `balanceMap_encode_deterministic_of_equiv` (`State.lean:534-539`):
  extensional via `TreeMap.equiv_iff_toList_eq`.
- `extendedState_encode_deterministic` (`State.lean:544-547`):
  structural only.
- `bridgeState_encode_deterministic` (`State.lean:555-559`):
  structural only.
- `depositRecord_encode_deterministic` (`State.lean:563-566`):
  structural.
- `pendingWithdrawal_encode_deterministic` (`State.lean:569-572`):
  structural.
- `depositRecord_roundtrip` (`State.lean:576-604`): **the only**
  round-trip lemma in this module. Bounded.

**Distinct from `encode_injective`**: the module ships `*_deterministic`
(trivial: same input → same output) but **not** `state_encode_injective`,
`extendedState_encode_injective`, or `bridgeState_encode_injective`.
The header docstring is honest about this:

> The full abstract round-trip theorem (`∀ s, ∃ s', decode (encode s)
> = .ok s' ∧ s ~ext s'`) is deferred to a follow-up; it requires
> lifting `equiv_iff_toList_eq` through the two-level `TreeMap.ofList
> ∘ toList` composition. (`State.lean:60-66`)

And the CLAUDE.md table footnote 1 explicitly calls out:

> Lifting bytes-equality to extensional state equality (`toList`
> equality) requires CBE encoder canonicality for `State` /
> `NonceState` / `KeyRegistry` / `LocalPolicies` / `BridgeState`,
> which is shipped at the structural level (`*_encode_deterministic`
> and round-trip lemmas) but not as a stand-alone `*_encode_injective`
> lemma for the map-backed sub-states; that's a Workstream-H
> follow-up.

**Implication for fault proofs.** The `H` workstream's
`commitExtendedState_subcommits_bytes_eq_under_collision_free`
(in `FaultProof/Commit.lean`) proves byte-equality of the sub-state
commits under collision-resistance, but **does not** lift to
extensional state equality because the missing
`*_encode_injective` lemmas are the chokepoint.

### Decoder partiality
- `State.decode` (`State.lean:238-254`) does NOT explicitly check
  `Nat` outer-key bounds before `.toUInt64` conversion. Reads each
  outer key as `Nat`, then constructs `p.1.toUInt64`. If the
  decoded key ≥ 2^64, `toUInt64` performs modular reduction —
  silent narrowing. The inner-map encoding's `decodeMap` call uses
  `K := Nat, V := ByteArray`, so the key bound is not checked.
  **Documented at `State.lean:236-237`**: "Each outer key is a
  CBE-decoded `Nat` in `[0, 2^64)` and converts to `UInt64`
  exactly via `toUInt64`." — but this is a *promise about
  canonical inputs*, not a *check enforced by the decoder*. A
  malicious encoder could include an outer key with `Nat ≥ 2^64`;
  it would silently narrow on decode. Re-encode would produce
  different bytes; this is **a canonicality violation against the
  decoder**, but is not currently caught.

Same pattern in `NonceState.decode` (`State.lean:459-465`) and
`KeyRegistry.decodeMap` (`State.lean:469-475`).

`Bridge.DepositRecord.decode` (`State.lean:301-313`) and
`Bridge.PendingWithdrawal.decode` (`State.lean:348-374`) DO check
their resource fields with `dif h : ... < 2^64`. So the discipline
is inconsistent: bridge sub-records check, top-level maps do not.

### ExtendedState pre-LP migration drop
(`State.lean:444-499`) — the strict 5-segment decoder
(`base ++ nonces ++ registry ++ bridge ++ localPolicies`) will fail
on pre-LP 4-segment snapshots. Migration policy is documented and
operationally enforced via re-snapshotting.

### Documentation drift
- The "Round-trip status" docstring (`State.lean:37-70`) is detailed
  and honest about the deferral.
- Field-list comment at `State.lean:278-282` says `BridgeState` has
  `consumed`, `pending`, `nextWdId` — verified.

---

## 6. `LegalKernel/Encoding/SignInput.lean` (domain-separated sign input)

### Imports
(`SignInput.lean:47`) `Encoding.SignedAction` — pulls in `Action`,
`Authority.SignedAction`. Reasonable.

### Domain string
`signedActionDomain : String := "legalkernel/v1/signedaction"`
(`SignInput.lean:63`). **27 ASCII characters**, encoded byte-wise via
`signedActionDomain.toUTF8.data.toList`.

### `signInput` (`SignInput.lean:96-108`)
Layout — strictly concatenated:
1. **CBE-bstr-encoded domain string**: `cborHeadEncode cbeTagBytes
   signedActionDomain.toUTF8.size ++ signedActionDomain.toUTF8.data.toList`
   → 9 header bytes + 27 UTF-8 bytes = 36 bytes (the `_nonempty`
   theorem at `SignInput.lean:134-156` verifies this lower bound).
2. `Encodable.encode (T := ByteArray) deploymentId` — length-prefixed.
3. `Encodable.encode (T := Action) action` — variant-tagged.
4. `Encodable.encode (T := Nat) signer.toNat` — CBE uint.
5. `Encodable.encode (T := Nat) nonce` — CBE uint.

The result is wrapped as a `ByteArray.mk (...).toArray`.

### Domain separation guarantees (the §8.8.5 promise)
The docstring claims **cross-deployment replay resistance**: different
deployments produce different `deploymentId`s, so different
sign-input bytes for the same `(action, signer, nonce)`.

### Sharp points

1. **No BLAKE3 hash is applied at the Lean level.** Phase-4 returns
   the *bytes that would be hashed*; the runtime adaptor of Phase 5
   wires the hash function (`SignInput.lean:30-32`, `:93-96`). Lean-side
   proofs about sign-input distinguishability are therefore about
   byte distinguishability, not hash distinguishability.

2. **`signInput_deterministic` is `rfl`** (`SignInput.lean:127-131`)
   — trivial.

3. **Cross-deployment distinguishability is value-level only**
   (`SignInput.lean:110-125`). The abstract proof that
   `(d₁ ≠ d₂) → signInput _ _ _ d₁ ≠ signInput _ _ _ d₂` (which
   would follow from `byteArray_encode_injective` on the
   length-prefixed `deploymentId` segment) is **deferred**. Test
   vectors in `LegalKernel/Test/Encoding/SignInput.lean` are the
   shipped evidence.

4. **`cbeTagText` is unused.** The domain string uses `cbeTagBytes`
   (line 101). This is per the codec design (text and bytes share a
   tag) but the unused `cbeTagText` constant in `CBOR.lean:113` is a
   trap for future readers.

5. **The version suffix is implicit.** `"legalkernel/v1/signedaction"`
   embeds `v1`; any future v2 bump requires both rotating the
   domain string and (per `SignInput.lean:59`) "future versions
   bump the suffix." No `version : Nat` parameter, no decoder check
   that the domain string matches expectations on the verify side
   (verify-side calls `signInput` itself, so this is fine).

### Documentation drift
None observed.

---

## 7. `LegalKernel/Encoding/Disputes.lean` (Phase 6 dispute / verdict codec)

### Imports
(`Disputes.lean:38-39`) `Disputes.Types`, `Encoding.Encodable`.
Reasonable.

### `DisputeClaim` encoding (5 variants, tags 0–4)
- Tag 0: `preconditionFalse idx`
- Tag 1: `signatureInvalid idx`
- Tag 2: `nonceMismatch idx`
- Tag 3: `oracleMisreported idx ev` (CBE bstr evidence)
- Tag 4: `doubleApply idx₁ idx₂`

`DisputeClaim.fieldsBounded` / decidable instance / `encode` / `decode`
/ `roundtrip` / `roundtrip_empty` / `encode_injective` all present and
correctly bounded.

### `EvidenceVerdict` encoding (3 variants, tags 0–2)
`upheld` / `rejected` / `inconclusive`. **Unconditional round-trip and
injectivity** (no numeric fields). The decoder rejects unknown
indices with `invalidConstructorIndex`.

### `Dispute` encoding
Layout: `[challenger ++ claim ++ evidence ++ nonce ++ sig]`
(`Disputes.lean:302-307`). All standard fields.

- `Dispute.fieldsBounded` (`Disputes.lean:288-293`).
- Decoder (`Disputes.lean:310-330`) does check `challenger < 2^64`
  before `.toUInt64` (`if hch : challengerNat < 18446744073709551616
  then`). Better than the `State` decoder.
- `dispute_roundtrip` (`Disputes.lean:338-383`),
  `dispute_roundtrip_empty`, `dispute_encode_injective`.

### `Verdict` encoding (Audit-3.5 design)
Layout: `[disputeId ++ outcome ++ rationale ++ signers (List) ++
sigs (List)]` (`Disputes.lean:442-447`). The single
`signatures : List (ActorId × Signature)` field is **unzipped** into
parallel signer/sig lists for the wire format, then **zipped back**
on decode (using `List.zip_unzip`).

- `Verdict.fieldsBounded` (`Disputes.lean:417-421`): `disputeId <
  2^64 ∧ rationale.size < 2^64 ∧ signatures.length < 2^64 ∧
  ∀ p ∈ signatures, p.snd.size < 2^64`.
- `Verdict.canonical` predicate (referenced as `hcan` in
  `verdict_roundtrip`, defined in `Disputes/Types.lean`) requires
  strictly-ascending signers.
- `actorsStrictlyAscending` (`Disputes.lean:454-457`) — decoder-side
  canonicality enforcement.
- `verdict_roundtrip` (`Disputes.lean:576-665`) — **requires
  `Verdict.canonical v`** in addition to `fieldsBounded`. Without
  canonicality, the decoder branches to `.nonCanonical` and
  injectivity fails.
- `verdict_encode_injective` (`Disputes.lean:679-689`) — bounded and
  canonical on both sides.

### Sharp points

1. **`Verdict.encode` is well-defined on non-canonical verdicts**
   (it just unzips and emits the parallel lists), but the round-trip
   property holds only for canonical ones. **A non-canonical verdict
   encodes deterministically but decodes to `.nonCanonical`.** This
   is the intended security posture: a signer of a non-canonical
   verdict cannot get their bytes back through the decoder, and
   their signature is therefore non-verifiable in the canonical
   pipeline. But Lean-level `Verdict.encode` is total — there is no
   precondition gate at the encoder.

2. **`List.zip_unzip` is the load-bearing identity.**
   `verdict_roundtrip` uses `List.zip_unzip : List.zip sigs.unzip.1
   sigs.unzip.2 = sigs` (line 656). This holds only because `List
   ActorId` and `List Signature` have the **same length** when they
   come from `unzip` of the same `List (ActorId × Signature)`.
   A maliciously crafted CBE stream where the two list lengths
   *disagree* would decode to a shortened or padded list (via the
   default behaviour of `List.zip`), then re-encode differently —
   **encode-then-decode is NOT idempotent for inputs with mismatched
   signer/sig list lengths**. The `actorsStrictlyAscending` check
   does not enforce length matching. **This is a sharp edge worth
   reviewing.**

3. **`fieldsBounded` allows pairs whose `.snd.size = 0`** — empty
   signatures are not rejected at the encoding layer. Whether this
   is acceptable depends on the verifier; per CBE, an empty
   ByteArray is a valid value.

### Documentation drift
- `Disputes.lean:18-21` describes `Verdict` as `[disputeId, outcome,
  rationale, signers (List), sigs (List)]`, then describes the
  Audit-3.5 unzip+zip strategy at `:404-436`. These match the code.

---

## 8. `LegalKernel/Encoding/LocalPolicy.lean` (LP.2 policy codec)

### Imports
(`LocalPolicy.lean:39-40`) `Authority.LocalPolicy`,
`Encoding.Encodable`. `open Std` for `TreeMap`. Reasonable.

### `LocalPolicyClause` encoding (3 variants, tags 0–2)
- Tag 0: `denyTags tags` (`List Nat`)
- Tag 1: `requireRecipientIn r allow` (`ResourceId`, `List ActorId`)
- Tag 2: `capAmount r max` (`ResourceId`, `Amount`)

### `LocalPolicy.fieldsBounded`
(`LocalPolicy.lean:74-76`) — enforces both `MAX_CLAUSES_PER_POLICY`
and per-clause boundedness.

### Decoder DoS-hardening (the LP.2 audit-1 fix)
The decoder explicitly enforces `MAX_TAGS_PER_DENY` (line 127–131),
`MAX_RECIPIENTS_PER_REQUIRE` (line 142–146), and
`MAX_CLAUSES_PER_POLICY` (line 358–362). On overflow, returns
`.invalidLength` with a descriptive message. **Defense-in-depth**:
even if a caller forgets to gate `fieldsBounded`, the decoder
rejects oversize streams.

`requireRecipientIn` (line 138) and `capAmount` (line 156) check
`rN < 2^64` before `.toUInt64`. Consistent with `Dispute.decode`.

### `LocalPolicies.encodeMap` / `decodeMap`
(`LocalPolicy.lean:482-484`, `:519-541`) — sorted-key CBE map mirroring
the `BalanceMap` pattern. Inner policies wrapped as length-prefixed
ByteArray. Decoder enforces `keysStrictlyAscending` (`nonCanonical`
on failure).

**Note: `encodeSortedPairs`, `decodeNPairs`, `keysStrictlyAscending`
are duplicated as `private def`s here** (`LocalPolicy.lean:469-513`)
to avoid pulling in `Encoding.State`. The duplication is intentional
and identical to the State module's definitions.

### Round-trip + injectivity + determinism
All shipped:
- `localPolicyClause_roundtrip` (`LocalPolicy.lean:196-303`).
- `localPolicy_roundtrip` (`LocalPolicy.lean:385-403`).
- `localPolicies_encodeMap_deterministic` (structural,
  `LocalPolicy.lean:550-553`).
- `localPolicies_encodeMap_deterministic_of_equiv` (extensional via
  `TreeMap.equiv_iff_toList_eq`, `LocalPolicy.lean:558-563`).

**But again: no `localPolicies_roundtrip` or
`localPolicies_encode_injective`.** Same pattern as `State` — the
map-backed sub-state's full round-trip is deferred.

### `MAX_POLICY_ENCODE_BYTES` doc
(`LocalPolicy.lean:432-454`) — documents the §3.0 16384-byte bound
as a **deployment-correctness obligation** that the Lean side does
not prove. The worst-case byte cost is sketched (38 KB for 64
maximal-size clauses) — acknowledged conservatively, deployment
mempool policy is supposed to enforce.

### Documentation drift
Stale-but-harmless comment at `LocalPolicy.lean:436`: "deployments
that need the loose 38 KB bound can amend §3.0 via the §13.6
two-reviewer gate." Verified the bound is documentation-only.

---

## 9. `LegalKernel/Encoding/KernelStep.lean` (Workstream H WU H.1.5)

### Imports
(`KernelStep.lean:36-39`) `Encoding.State`, `Encoding.SignedAction`,
`FaultProof.Cell`, `FaultProof.Step`. Heavyweight — pulls in
`ExtendedState` and `Action`.

### `CellTag` encoding (7 variants, tags 0–6)
- Tag 0: `balance r a` (`ResourceId`, `ActorId`)
- Tag 1: `nonce a` (`ActorId`)
- Tag 2: `registry a` (`ActorId`)
- Tag 3: `localPolicy a` (`ActorId`)
- Tag 4: `bridgeConsumed d` (`Nat` = DepositId)
- Tag 5: `bridgePending wd` (`Nat` = WithdrawalId)
- Tag 6: `bridgeNextWdId` (no fields)

### `CellTag.decode`
(`KernelStep.lean:80-142`) — checks `< 2^64` on each ActorId/ResourceId
narrowing (tags 0–3), but **NOT on `bridgeConsumed`/`bridgePending`
which are pure Nat fields (tags 4–5)**. Consistent with the underlying
DepositId/WithdrawalId being Nat-typed at the kernel level.

### `CellProof` encoding
(`KernelStep.lean:151-154`): `cellTag ++ cellValue (ByteArray) ++
witnessState (ExtendedState)`. The witness state is the full
post-image of the kernel step at that cell — substantial bytes
(consumed/pending maps, balances, etc.).

### `CellProofBundle` encoding
(`KernelStep.lean:178-179`): a length-prefixed list.

### `KernelStep` encoding
(`KernelStep.lean:197-201`): `preStateCommit (32 bytes) ++
signedAction ++ postStateCommit (32 bytes) ++ cellProofs (bundle)`.
The commits are **CBE byte strings** with their length prefix —
specifically 32 + 9 = 41 wire bytes each.

### Round-trip status
**Only `*_encode_deterministic` is shipped** (lines 231–243). NO
round-trip lemma, NO injectivity lemma. The reason: the
`witnessState` carries an `ExtendedState`, which has no round-trip
lemma (see §5).

### Sharp points

1. **The L1 fault-proof contract consumes these bytes** but the
   Lean side does not prove `decode (encode step) = step`. Any
   discrepancy between Lean's encoder and the Solidity-side decoder
   is caught only by cross-stack equivalence tests (in
   `solidity/test/`), not by an in-tree theorem.

2. **`CellTag` variants 4 and 5 take unbounded `Nat`**, encoded as
   CBE uints. A malicious challenge declaring `depositId = 2^65`
   silently truncates on encode. The L1 contract's bound check is
   the only guard; the Lean side has no `fieldsBounded` predicate
   for `CellTag`.

3. **`KernelStep.preStateCommit` and `postStateCommit` are
   ByteArrays**, encoded with the length prefix. The L1 contract
   expects exactly 32 bytes; nothing in `KernelStep.encode` enforces
   this. A malicious challenger producing a 31-byte commit would
   encode successfully but fail on L1.

### Documentation drift
- Header (`KernelStep.lean:17-21`) claims `preStateCommit : 32 bytes
  (CBE bstr; uniform-output ByteArray)`. The "32 bytes" is a
  description of the expected runtime contract, not a constraint
  the Lean code enforces.

---

## 10. `LegalKernel/Encoding/GameState.lean` (Workstream H WU H.4.5)

### Imports
(`GameState.lean:37-38`) `Encoding.Encodable`, `FaultProof.Game`.
Minimal.

### Sub-type codecs
- `Claim`: `idx (Nat) ++ commit (ByteArray)`.
- `DisputedRange`: `low (Claim) ++ high (Claim)`.
- `TurnSide`: 1-byte CBE uint tag (0 = sequencer, 1 = challenger).
  Total 9 wire bytes.
- `GameStatus`: 1-byte CBE uint tag (0..4).

### `GameState.encode`
(`GameState.lean:137-147`): 10 fields concatenated in declared order
(sequencer, challenger, range, pendingMidpoint, depth, turn,
sequencerBond, challengerBond, status, deploymentId).

### `GameState.decode`
(`GameState.lean:151-186`) — uses `do`-notation. Checks `seqId
< 2^64` and `chalId < 2^64` after `Encodable.decode (T := Nat)`.

### Round-trip status
Only `*_encode_deterministic` is shipped (`GameState.lean:194-204`).
NO round-trip lemma, NO injectivity lemma.

### Sharp points

1. **The decoder uses `do`-notation** (line 152), departing from the
   match-ladder style of every other decoder in the suite. Functionally
   equivalent but cosmetically different.

2. **`depth`, `sequencerBond`, `challengerBond` are all `Nat`** and
   decoded without the `< 2^64` guard. A `depth ≥ 2^64` would encode
   lossy and decode to the truncated value — same hazard as
   `Action`'s amount field. Documented at the type level; the L1
   contract's storage layout enforces.

3. **Smoke checks** (lines 209–214) verify that distinct `TurnSide` /
   `GameStatus` constructors encode to distinct bytes via `decide`.
   These are useful sanity checks but do not constitute proof of
   injectivity over the inductive — the `decide` evaluates each
   case independently.

### Documentation drift
- Header (line 17): `sequencer : 8 bytes (UInt64 / CBE uint head)`.
  In fact the CBE uint head is **9 bytes** (1 tag byte + 8 LE
  payload). Minor doc drift — describes the payload but not the head.

---

## Cross-cutting observations

### Sharp point: domain separation across `Encodable` instances

CBE assigns one byte tag per *major type*, not per *Encodable
instance*. Multiple types share a tag:

| Tag | Used by                                          |
|-----|--------------------------------------------------|
| `0x00` (uint) | `Bool`, `Nat`, `BoundedNat`, `UInt{8,16,32,64}`, all variant tags |
| `0x02` (bytes)| `ByteArray`, text strings (the domain string)    |
| `0x04` (array)| `List α`, `Option α`                             |
| `0x05` (map)  | sorted-pair maps (`State`, `LocalPolicies`, etc.)|

**Each `Encodable` instance does NOT start with a *distinct* tag
byte.** A `Bool true` and a `Nat 1` produce **identical** 9-byte
streams: `[0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]`.
This is the "type-collision discipline" documented at
`Encodable.lean:43-68`. The kernel's *composite* types
(`Action`, `SignedAction`, `State`) fix field types at the type
level, so collision is benign within a single composite — but
across raw `Encodable` uses, the bytes are schema-implicit. Any
deployment-level protocol that re-interprets bytes under a
different type at the *outer* level is unsound.

### Sharp point: round-trip ≠ injectivity ≠ determinism

Each module ships some subset of:
- `*_encode_deterministic` (trivial structural identity)
- `*_encode_deterministic_of_equiv` (extensional via TreeMap.Equiv)
- `*_roundtrip` (`decode (encode v ++ rest) = .ok (v, rest)`, bounded)
- `*_roundtrip_empty` (specialised to `rest = []`)
- `*_encode_injective` (bounded; via decode-both-sides)

**Map-backed sub-states (`State`, `ExtendedState`, `BridgeState`,
`LocalPolicies`, `KeyRegistry`, `NonceState`) ship only `*_deterministic`
and (for BalanceMap / LocalPolicies) `*_deterministic_of_equiv`.
They do NOT ship `*_roundtrip` or `*_encode_injective`.** This is
the chokepoint for lifting `commitExtendedState_subcommits_bytes_eq_*`
to extensional state equality in the fault-proof workstream.

### Sharp point: untrusted byte parsing

Every decoder returns `Except DecodeError`. Failure modes are
explicit and structurally distinguished. The four sharp
canonicality checks are:
- `decodeMap`'s `keysStrictlyAscending` check (rejects unsorted /
  duplicate-key maps).
- `Verdict.decode`'s `actorsStrictlyAscending` check.
- `LocalPolicies.decodeMap`'s same check.
- All decoders' `invalidConstructorIndex` on unknown variant tags.

**Where this discipline lapses:**
- `State.decode` / `NonceState.decode` / `KeyRegistry.decodeMap`
  do not bound the outer `Nat` key before `.toUInt64` narrowing.
  A canonical encoder would only emit `< 2^64` keys, but a
  malicious one could include `≥ 2^64` and the decoder would
  narrow silently — producing an `ActorId` / `ResourceId` distinct
  from the encoder's view. Re-encode would differ; this is a
  canonicality violation NOT caught at the decoder.
- `SignedAction.decode` / `Action.decode` read `nonce` and
  `amount` / `idx` fields as unbounded `Nat`. Documented at
  `SignedAction.lean:71-87`. The runtime adaptor is supposed to
  gate, but a misconfigured adaptor would let through values
  whose re-encode differs.

### Sharp point: golden byte sequences locked in

The compile-time `example`s at the bottom of several modules
(`Action.lean:885-892`, `LocalPolicy.lean:569-580`,
`KernelStep.lean:249-253`, `GameState.lean:209-214`) lock specific
byte-level behaviour into elaboration. These act as regression
witnesses — any change to the encoder that breaks them fails the
build. But they are spot checks, not exhaustive corpus.

There are NO version-controlled hex test vectors (e.g. an
`assert encode (transfer 1 2 3 4) = "0x00 00 00 ..."` golden file).
Such a vector would catch a stealth re-tagging of a constructor.

### Sharp point: trust-boundary documentation

Every file's module docstring includes "**not** part of the trusted
computing base. Bugs here produce wrong serialisations (which
downstream `decode_encode_roundtrip` proofs would catch at build
time), but cannot violate any kernel invariant." This is **true** —
the kernel TCB is `Kernel.lean + RBMapLemmas.lean` only, and the
encoders are not in that import set per `tcb_allowlist.txt`. But
the claim "downstream proofs would catch a bug at build time" is
**not airtight** because:
1. Map-backed sub-states ship no round-trip lemma at all.
2. Schema-implicit type collisions cannot be caught structurally.
3. The runtime adaptor's `fieldsBounded` gate is a manual obligation.

---

## Summary of notable findings

1. **CBE is not canonical CBOR** (documented). Fixed-width 9-byte
   uint head + length-prefixed bytes/text/array/map. Wire format
   diverges from RFC 8949 §3.1 by design — the gain is provable
   round-trip via structural induction.

2. **Silent truncation on `n ≥ 2^64`** is the single largest
   sharp edge. Every higher-level encoder reproduces this and
   pushes the bound to a `fieldsBounded` predicate that the
   *runtime adaptor* (Phase 5) is supposed to enforce. The Lean
   side ships totality + bounded round-trip.

3. **Map-backed sub-states (`State`, `ExtendedState`, `BridgeState`,
   `LocalPolicies`, `KeyRegistry`, `NonceState`) lack stand-alone
   `*_encode_injective` lemmas.** Only `*_deterministic` (trivial
   structural identity) and (for some) `*_deterministic_of_equiv`
   are shipped. This is the chokepoint flagged by CLAUDE.md
   footnote 1 — lifting fault-proof byte equality to extensional
   state equality remains a follow-up.

4. **Decoder canonicality is enforced inconsistently.**
   `decodeMap` / `LocalPolicies.decodeMap` enforce
   `keysStrictlyAscending`; `Verdict.decode` enforces
   `actorsStrictlyAscending`; but `State.decode` /
   `NonceState.decode` / `KeyRegistry.decodeMap` do NOT bound the
   outer `Nat` key before `.toUInt64`. Bridge sub-records do bound
   their resource fields.

5. **Domain separation in `SignInput.lean` is by-bytes, not
   by-hash.** Lean returns the canonical bytes-to-be-hashed; the
   runtime adaptor wires BLAKE3. Cross-deployment
   distinguishability is currently value-level only (test
   vectors); the abstract proof via `byteArray_encode_injective` on
   the deploymentId segment is deferred.

6. **`Verdict.encode`'s parallel-list trick is fragile** for
   inputs with mismatched signer/sig list lengths in the bytes —
   `List.zip` quietly truncates rather than failing. Round-trip
   holds for canonical inputs only; non-canonical bytes produce
   `.nonCanonical`.

7. **`cbeTagText` is defined but unused.** The domain string is
   encoded with `cbeTagBytes`. Documented but a trap for future
   readers.

8. **Documentation drift, minor:** the constructor-tag table in
   `Action.lean:27-47` stops at tag 16; tags 17/18
   (`faultProofChallenge` / `faultProofResolution`) are in the code
   but absent from the table. Easy fix.

9. **No `LawfulEncodable` typeclass.** Round-trip / injectivity
   are standalone theorems; the type system cannot prevent a buggy
   encoder/decoder pair from being instantiated as an `Encodable`.
   Acceptable for the project's scale; worth flagging.

10. **No version-controlled hex golden vectors.** Spot-check
    `example`s exist (`Action.lean:885`, etc.) but a stealth
    re-tagging of a constructor would only be caught by structural
    proofs, not by a byte-level corpus check.
