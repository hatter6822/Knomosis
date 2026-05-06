/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.State — `Encodable` instance for `State` and
`ExtendedState`.

Phase 4 WU 4.5 + WU 4.6 + WU 4.7.  The two-level kernel `State`
(per-resource → per-actor → balance) and the runtime
`ExtendedState` (kernel state + nonce ledger + key registry) require
a canonical byte encoding for hashing and signing.

Encoding scheme (per Genesis Plan §8.8.3):

  ```
  State          → CBE map { 0: balances }
                   where `balances` is an ordered map (CBE map with
                   keys sorted ascending) from `ResourceId` to inner
                   ordered maps from `ActorId` to `Amount`.

  ExtendedState  → CBE map { 0: base, 1: nonces, 2: registry }
  ```

CBE (Phase 4's simpler binary encoding) drops the explicit `0:` /
`1:` field-tags and encodes structures as fixed-order field
sequences (analogous to CBOR's ordered-key map but with the field
order frozen at the type level).  The two-level `TreeMap` is encoded
as a sorted list-of-pairs, which canonicalises away any RB-tree
shape variation: two `TreeMap`s with the same `(key, value)` set
produce identical bytes.

**Round-trip status.**  Round-trip and injectivity for the `State`
codec require a `TreeMap.Equiv` argument because `TreeMap.ofList`
(used by the decoder to rebuild the inner / outer maps) and
`TreeMap.toList` (used by the encoder to extract sorted entries)
form an extensional — not structural — inverse pair: rebuilding a
`TreeMap` from its `toList` produces a `TreeMap.Equiv`-equivalent
result, but not necessarily a structurally equal one (because the
RB-tree shape is determined by the insertion order, and `ofList`
inserts in the canonical sorted-list order).

Phase 4 ships:

  * **Determinism** at the structural level
    (`state_encode_deterministic`): equal `State`s produce equal
    bytes (trivially, because `encode` is a function).
  * **Determinism** at the extensional level for `BalanceMap`
    (`balanceMap_encode_deterministic_of_equiv`): two
    `Equiv`-equivalent inner balance maps produce identical bytes.
  * **Value-level round-trip** verified by tests in
    `LegalKernel/Test/Encoding/State.lean`: encoding then decoding
    a non-empty `State` (resp. `ExtendedState`) recovers the
    original at every probed `getBalance` / `expectsNonce` /
    `KeyRegistry.lookup` cell.

The full *abstract* round-trip theorem
(`∀ s, ∃ s', decode (encode s) = .ok s' ∧ s ~ext s'`) is deferred to
a follow-up; it requires lifting `equiv_iff_toList_eq` through the
two-level `TreeMap.ofList ∘ toList` composition.  Genesis Plan
§8.8.3's headline acceptance ("identical state values produce
identical bytes, verified across `RBMap`s built by different
insertion sequences") is met by the determinism theorems plus the
order-invariance test.  Deployments hash the canonical bytes; two
`State`s that happen to be extensionally equal but structurally
distinct can be canonicalised by re-encoding before hashing.

This module is **not** part of the trusted computing base.  Bugs
here produce wrong serialisations, but cannot violate any kernel
invariant.
-/

import LegalKernel.Authority.Nonce
import LegalKernel.Bridge.State
import LegalKernel.Encoding.Encodable
import LegalKernel.Encoding.SignedAction

open Std

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority

/-! ## Helpers: encode / decode a sorted-pair list

The CBE map encoding requires the pair list to be sorted ascending
by key (Genesis Plan §8.8.2 / §8.8.6).  The encoder accepts any
list (the canonical-encoding obligation is on the caller); the
decoder *enforces* the sorted-key + distinct-key discipline by
rejecting non-canonical inputs with `nonCanonical`.  This rejection
is critical for security: a permissive decoder would let an
attacker forge an alternative-but-equally-valid encoding of the
same logical state with a different signature input.  See
GENESIS_PLAN.md §8.8.6 for the threat model. -/

/-- Encode a list of `(key, value)` pairs (already sorted) as a CBE
    map: map tag + 8-byte LE pair count + alternating key / value
    encodings.  The "sorted" property is the caller's responsibility
    (the encoder works for any list, but only sorted-key inputs are
    canonical). -/
def encodeSortedPairs {K V : Type} [Encodable K] [Encodable V]
    (pairs : List (K × V)) : Stream :=
  cborHeadEncode cbeTagMap pairs.length ++
    pairs.foldr (fun p acc =>
      Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) []

/-- Decode `n` `(K × V)` pairs from the front of `s`.  Returns the
    pair list (in decode order) and the residual stream.  Does NOT
    enforce key ordering; that is the caller's responsibility (see
    `decodeMap`, which performs the canonicalisation check after
    `decodeNPairs` returns). -/
def decodeNPairs {K V : Type} [Encodable K] [Encodable V] :
    Nat → Stream → Except DecodeError (List (K × V) × Stream)
  | 0,     s => .ok ([], s)
  | k + 1, s =>
    match Encodable.decode (T := K) s with
    | .ok (key, s') =>
      match Encodable.decode (T := V) s' with
      | .ok (val, s'') =>
        match decodeNPairs k s'' with
        | .ok (rest, s''') => .ok ((key, val) :: rest, s''')
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e

/-- Predicate: the keys of `pairs` are *strictly* ascending under
    `cmp`.  Strictly ascending implies both sorted and duplicate-
    free, which together are the §8.8.2 / §8.8.6 canonicalisation
    requirement for CBE maps. -/
def keysStrictlyAscending {K V : Type} (cmp : K → K → Ordering)
    (pairs : List (K × V)) : Bool :=
  match pairs with
  | []                    => true
  | _ :: []               => true
  | (k₁, _) :: (k₂, v₂) :: rest =>
      (cmp k₁ k₂ == Ordering.lt) && keysStrictlyAscending cmp ((k₂, v₂) :: rest)

/-- Decode a CBE map header + N pairs, enforcing the canonical
    sorted-key + distinct-key discipline.

    Rejects inputs whose decoded pair list is not strictly ascending
    by key under `cmp` with `nonCanonical`.  The default `cmp` is
    `compare`, matching what `TreeMap.toList` produces (and what
    every CBE encoder must produce to be canonical).

    **DoS-hardening note.**  In principle a malicious encoder can
    set `count` to a huge value and rely on `decodeNPairs` to
    recurse deeply.  In practice the recursion depth is bounded by
    the input size (each successful element decode consumes ≥ 9
    bytes via the CBE head; each pair therefore ≥ 18 bytes), and
    every concrete in-tree `Encodable` instance returns
    `unexpectedEof` on a too-short stream — so the recursion
    terminates within `rest.length / 18` steps regardless of the
    declared count.  The runtime adaptor's max-message-size policy
    (Phase 5; not in-tree) is the right place to bound the
    *outer* input size; this decoder gracefully fails on any input
    whose declared count exceeds what the actual bytes can satisfy. -/
def decodeMap {K V : Type} [Encodable K] [Encodable V]
    (s : Stream) (cmp : K → K → Ordering := by exact compare) :
    Except DecodeError (List (K × V) × Stream) :=
  match cborHeadDecode s cbeTagMap with
  | .ok (count, rest) =>
    match decodeNPairs count rest with
    | .ok (pairs, rest') =>
      if keysStrictlyAscending cmp pairs then
        .ok (pairs, rest')
      else
        .error (.nonCanonical "map keys must be strictly ascending")
    | .error e => .error e
  | .error e => .error e

/-! ## State encoding

A `State` is encoded as a CBE map of `ResourceId → (CBE map of
ActorId → Amount)`.  The outer map's pairs are sorted ascending by
`ResourceId`; each inner map's pairs are sorted ascending by
`ActorId`.  Both orderings come for free from `TreeMap.toList`
under the canonical `compare` ordering.

**Inner-map framing.**  Each inner `BalanceMap` is first serialised
to its own `Stream` (via `BalanceMap.encode`), then wrapped as a
CBE byte string (`ByteArray`) before being placed in the outer
map's value slot.  This length-prefixed framing is what lets the
decoder cleanly extract each inner map's bytes from the outer map's
value slot — without it, the outer decoder would have no way to
know where each inner map's encoding ends and the next outer pair
begins. -/

/-- Encode a `BalanceMap` (the inner per-resource `TreeMap ActorId
    Amount`).  Produces a sorted-pair-list CBE map. -/
def BalanceMap.encode (bm : BalanceMap) : Stream :=
  encodeSortedPairs (bm.toList.map (fun (a, v) => (a.toNat, v)))

/-- Convenience helper: pack the inner-map bytes as a `ByteArray` so
    the outer encoder uses the `Encodable ByteArray` instance (CBE
    byte string framing).  This is the symmetric inverse of the
    "decode bytes, then re-decode as BalanceMap" step in
    `State.decode`. -/
private def BalanceMap.encodeAsBytes (bm : BalanceMap) : ByteArray :=
  ByteArray.mk (BalanceMap.encode bm).toArray

/-- Encode a `State` as the outer map of resource → (inner-map bytes).
    Each inner balance map is wrapped as a CBE byte string (via
    `encodeAsBytes`) so the outer encoder can use the `Encodable
    ByteArray` instance — this is the symmetric counterpart of the
    decoder, which extracts each inner map as a `ByteArray` then
    decodes the inner bytes via `BalanceMap.decode`. -/
def State.encode (s : State) : Stream :=
  encodeSortedPairs (s.balances.toList.map (fun (r, bm) =>
    (r.toNat, BalanceMap.encodeAsBytes bm)))

/-- Decode a `BalanceMap`: read the inner CBE map (with canonicality
    check on the keys), rebuild via `TreeMap.ofList`.

    Each key is a CBE-decoded `Nat`; by the codec invariant it lies
    in `[0, 2^64)` and converts to `UInt64` exactly via `toUInt64`. -/
def BalanceMap.decode (s : Stream) : Except DecodeError (BalanceMap × Stream) :=
  match decodeMap (K := Nat) (V := Nat) s with
  | .ok (pairs, rest) =>
    let pairs' : List (ActorId × Amount) :=
      pairs.map (fun (k, v) => (k.toUInt64, v))
    .ok (TreeMap.ofList pairs' compare, rest)
  | .error e => .error e

/-- Decode a `State`: read the outer CBE map (whose values are CBE
    byte strings), then for each entry decode the inner balance map
    from those bytes.  Rejects inner decode errors and trailing
    bytes inside any inner-map payload.

    Each outer key is a CBE-decoded `Nat` in `[0, 2^64)` and
    converts to `UInt64` exactly via `toUInt64`. -/
def State.decode (s : Stream) : Except DecodeError (State × Stream) :=
  match decodeMap (K := Nat) (V := ByteArray) s with
  | .ok (pairs, rest) =>
    -- Each pair carries a serialised inner balance map (as a CBE
    -- byte string).  Re-decode each inner payload as a `BalanceMap`.
    let inner : Except DecodeError (List (ResourceId × BalanceMap)) := pairs.foldlM
      (fun (acc : List (ResourceId × BalanceMap)) (p : Nat × ByteArray) =>
        match BalanceMap.decode p.2.data.toList with
        | .ok (bm, []) => .ok (acc ++ [(p.1.toUInt64, bm)])
        | .ok (_, _ :: _) =>
          .error (.trailingBytes 1)
        | .error e => .error e)
      []
    match inner with
    | .ok entries => .ok ({ balances := TreeMap.ofList entries compare }, rest)
    | .error e => .error e
  | .error e => .error e

instance instEncodableState : Encodable State where
  encode := State.encode
  decode := State.decode

/-! ## ExtendedState encoding

`ExtendedState = (base : State, nonces : NonceState, registry : KeyRegistry)`.
Encoded as the concatenation of the three field encodings.  The
`NonceState` is a `TreeMap ActorId Nonce`, encoded as a sorted-pair
list.  The `KeyRegistry` is a `TreeMap ActorId PublicKey`, also
sorted-pair-list. -/

/-- Encode a `NonceState` (per-actor nonce ledger). -/
def NonceState.encode (ns : NonceState) : Stream :=
  encodeSortedPairs (ns.next.toList.map (fun (a, n) => (a.toNat, n)))

/-- Encode a `KeyRegistry` (actor → public key). -/
def KeyRegistry.encodeMap (kr : KeyRegistry) : Stream :=
  encodeSortedPairs (kr.toList.map (fun (a, pk) => (a.toNat, pk)))

/-! ## BridgeState encoding (Workstream C.1.4)

`BridgeState` carries three fields: a `consumed : TreeMap DepositId
DepositRecord compare` (DepositId is `Nat`; DepositRecord is
`(resource, amount)`), a `pending : TreeMap WithdrawalId
PendingWithdrawal compare` (WithdrawalId is `Nat`;
PendingWithdrawal is `(resource, recipient, amount, l2LogIndex)`),
and `nextWdId : Nat`.

Encoded canonically as the concatenation of three sorted-pair-list
maps + a CBE uint:

```
BridgeState  → consumed-map ++ pending-map ++ nextWdId
```

Each inner record is encoded as a fixed-order field concatenation. -/

/-- Encode a single `DepositRecord` (resource + amount) as the
    concatenation of two CBE uints. -/
def Bridge.DepositRecord.encode (rec : Bridge.DepositRecord) : Stream :=
  Encodable.encode (T := Nat) rec.resource.toNat ++
  Encodable.encode (T := Nat) rec.amount

/-- Decode a `DepositRecord`. -/
def Bridge.DepositRecord.decode (s : Stream) :
    Except DecodeError (Bridge.DepositRecord × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (resN, s₁) =>
    if h : resN < 18446744073709551616 then
      match Encodable.decode (T := Nat) s₁ with
      | .ok (amount, s₂) =>
        .ok ({ resource := resN.toUInt64, amount := amount }, s₂)
      | .error e => .error e
    else
      let _ := h
      .error (.invalidLength s!"DepositRecord.resource {resN} ≥ 2^64")
  | .error e => .error e

/-- Wrap a `DepositRecord` payload as a length-prefixed CBE byte
    string for placement in the outer `consumed` map's value slot.
    Mirrors the inner-map framing pattern in `BalanceMap.encodeAsBytes`. -/
private def Bridge.DepositRecord.encodeAsBytes (rec : Bridge.DepositRecord) :
    ByteArray :=
  ByteArray.mk (Bridge.DepositRecord.encode rec).toArray

/-- Encode the `consumed` field of a `BridgeState`. -/
def Bridge.BridgeState.encodeConsumed (bs : Bridge.BridgeState) : Stream :=
  encodeSortedPairs (bs.consumed.toList.map (fun (d, rec) =>
    (d, Bridge.DepositRecord.encodeAsBytes rec)))

/-- Encode a single `PendingWithdrawal`. -/
def Bridge.PendingWithdrawal.encode (wd : Bridge.PendingWithdrawal) : Stream :=
  Encodable.encode (T := Nat) wd.resource.toNat ++
  Encodable.encode (T := Nat) wd.recipient.val ++
  Encodable.encode (T := Nat) wd.amount ++
  Encodable.encode (T := Nat) wd.l2LogIndex

/-- Wrap a `PendingWithdrawal` as a length-prefixed CBE byte string
    for placement in the outer `pending` map's value slot. -/
private def Bridge.PendingWithdrawal.encodeAsBytes
    (wd : Bridge.PendingWithdrawal) : ByteArray :=
  ByteArray.mk (Bridge.PendingWithdrawal.encode wd).toArray

/-- Decode a `PendingWithdrawal`. -/
def Bridge.PendingWithdrawal.decode (s : Stream) :
    Except DecodeError (Bridge.PendingWithdrawal × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (resN, s₁) =>
    if h₁ : resN < 18446744073709551616 then
      match Encodable.decode (T := Nat) s₁ with
      | .ok (recN, s₂) =>
        if h₂ : recN < Bridge.ethAddressBound then
          match Encodable.decode (T := Nat) s₂ with
          | .ok (amount, s₃) =>
            match Encodable.decode (T := Nat) s₃ with
            | .ok (idx, s₄) =>
              .ok ({ resource    := resN.toUInt64
                     recipient   := ⟨recN, h₂⟩
                     amount      := amount
                     l2LogIndex  := idx }, s₄)
            | .error e => .error e
          | .error e => .error e
        else
          let _ := h₂
          .error (.invalidLength
            s!"PendingWithdrawal.recipient {recN} ≥ 2^160")
      | .error e => .error e
    else
      let _ := h₁
      .error (.invalidLength s!"PendingWithdrawal.resource {resN} ≥ 2^64")
  | .error e => .error e

/-- Encode the `pending` field. -/
def Bridge.BridgeState.encodePending (bs : Bridge.BridgeState) : Stream :=
  encodeSortedPairs (bs.pending.toList.map (fun (wid, wd) =>
    (wid, Bridge.PendingWithdrawal.encodeAsBytes wd)))

/-- Encode a `BridgeState`: `[consumed; pending; nextWdId]`. -/
def Bridge.BridgeState.encode (bs : Bridge.BridgeState) : Stream :=
  Bridge.BridgeState.encodeConsumed bs ++
  Bridge.BridgeState.encodePending bs ++
  Encodable.encode (T := Nat) bs.nextWdId

/-- Decode the `consumed` map, rebuilding each inner `DepositRecord`
    from the framed inner bytes. -/
def Bridge.BridgeState.decodeConsumed (s : Stream) :
    Except DecodeError (TreeMap Bridge.DepositId Bridge.DepositRecord compare × Stream) :=
  match decodeMap (K := Nat) (V := ByteArray) s with
  | .ok (pairs, rest) =>
    let inner : Except DecodeError (List (Bridge.DepositId × Bridge.DepositRecord)) :=
      pairs.foldlM
        (fun (acc : List (Bridge.DepositId × Bridge.DepositRecord))
             (p : Nat × ByteArray) =>
          match Bridge.DepositRecord.decode p.2.data.toList with
          | .ok (rec, []) => .ok (acc ++ [(p.1, rec)])
          | .ok (_, _ :: _) => .error (.trailingBytes 1)
          | .error e => .error e)
        []
    match inner with
    | .ok entries => .ok (TreeMap.ofList entries compare, rest)
    | .error e => .error e
  | .error e => .error e

/-- Decode the `pending` map. -/
def Bridge.BridgeState.decodePending (s : Stream) :
    Except DecodeError (TreeMap Bridge.WithdrawalId Bridge.PendingWithdrawal compare × Stream) :=
  match decodeMap (K := Nat) (V := ByteArray) s with
  | .ok (pairs, rest) =>
    let inner : Except DecodeError (List (Bridge.WithdrawalId × Bridge.PendingWithdrawal)) :=
      pairs.foldlM
        (fun (acc : List (Bridge.WithdrawalId × Bridge.PendingWithdrawal))
             (p : Nat × ByteArray) =>
          match Bridge.PendingWithdrawal.decode p.2.data.toList with
          | .ok (wd, []) => .ok (acc ++ [(p.1, wd)])
          | .ok (_, _ :: _) => .error (.trailingBytes 1)
          | .error e => .error e)
        []
    match inner with
    | .ok entries => .ok (TreeMap.ofList entries compare, rest)
    | .error e => .error e
  | .error e => .error e

/-- Decode a `BridgeState`. -/
def Bridge.BridgeState.decode (s : Stream) :
    Except DecodeError (Bridge.BridgeState × Stream) :=
  match Bridge.BridgeState.decodeConsumed s with
  | .ok (consumed, s₁) =>
    match Bridge.BridgeState.decodePending s₁ with
    | .ok (pending, s₂) =>
      match Encodable.decode (T := Nat) s₂ with
      | .ok (nextWdId, s₃) =>
        .ok ({ consumed, pending, nextWdId }, s₃)
      | .error e => .error e
    | .error e => .error e
  | .error e => .error e

instance instEncodableBridgeState : Encodable Bridge.BridgeState where
  encode := Bridge.BridgeState.encode
  decode := Bridge.BridgeState.decode

/-- Encode an `ExtendedState` as
    `[base ++ nonces ++ registry ++ bridge]`. -/
def ExtendedState.encode (es : ExtendedState) : Stream :=
  State.encode es.base ++
  NonceState.encode es.nonces ++
  KeyRegistry.encodeMap es.registry ++
  Bridge.BridgeState.encode es.bridge

/-- Decode a `NonceState`.  Each key is a CBE-decoded `Nat` in
    `[0, 2^64)` and converts to `UInt64` exactly. -/
def NonceState.decode (s : Stream) : Except DecodeError (NonceState × Stream) :=
  match decodeMap (K := Nat) (V := Nat) s with
  | .ok (pairs, rest) =>
    let pairs' : List (ActorId × Nonce) :=
      pairs.map (fun (k, v) => (k.toUInt64, v))
    .ok ({ next := TreeMap.ofList pairs' compare }, rest)
  | .error e => .error e

/-- Decode a `KeyRegistry`.  Each key is a CBE-decoded `Nat` in
    `[0, 2^64)` and converts to `UInt64` exactly. -/
def KeyRegistry.decodeMap (s : Stream) : Except DecodeError (KeyRegistry × Stream) :=
  match Encoding.decodeMap (K := Nat) (V := ByteArray) s with
  | .ok (pairs, rest) =>
    let pairs' : List (ActorId × PublicKey) :=
      pairs.map (fun (k, v) => (k.toUInt64, v))
    .ok (TreeMap.ofList pairs' compare, rest)
  | .error e => .error e

/-- Decode an `ExtendedState`. -/
def ExtendedState.decode (s : Stream) : Except DecodeError (ExtendedState × Stream) :=
  match State.decode s with
  | .ok (base, s₁) =>
    match NonceState.decode s₁ with
    | .ok (nonces, s₂) =>
      match KeyRegistry.decodeMap s₂ with
      | .ok (registry, s₃) =>
        match Bridge.BridgeState.decode s₃ with
        | .ok (bridge, s₄) =>
          .ok ({ base, nonces, registry, bridge }, s₄)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .error e => .error e

instance instEncodableExtendedState : Encodable ExtendedState where
  encode := ExtendedState.encode
  decode := ExtendedState.decode

/-! ## Determinism (the headline §8.8.3 property)

"Identical state values produce identical bytes."  At the kernel
level, "identical" means structurally equal `State` values; at the
deployment level, callers care about *extensional* equality (two
`State`s agreeing at every `getBalance` query).

Both forms hold for our encoder:

  * Structural: `s₁ = s₂ → encode s₁ = encode s₂` (trivial — `encode`
    is a function).
  * Extensional: `s₁ ~ext s₂ → encode s₁ = encode s₂`.  This requires
    the `TreeMap.Equiv → toList = toList` lemma from Std (which holds
    under `TransCmp`).  The proof is omitted here as the structural
    form is sufficient for deployment hashing (deployments persist
    the canonical bytes alongside the state, so two `State`s that
    happen to be extensionally equal but structurally distinct can
    be canonicalised by re-encoding before hashing). -/

/-- Determinism (structural): `encode` is a function, so equal inputs
    produce equal outputs.  Trivially true; stated explicitly so the
    Phase-4 §8.8.3 deliverable is documented. -/
theorem state_encode_deterministic (s₁ s₂ : State) (h : s₁ = s₂) :
    Encodable.encode (T := State) s₁ = Encodable.encode (T := State) s₂ :=
  h ▸ rfl

/-- Determinism (extensional, via Equiv) for the `BalanceMap`:
    extensionally equal `BalanceMap`s encode to identical bytes,
    via `TreeMap.equiv_iff_toList_eq`. -/
theorem balanceMap_encode_deterministic_of_equiv
    (bm₁ bm₂ : BalanceMap) (h : bm₁.Equiv bm₂) :
    BalanceMap.encode bm₁ = BalanceMap.encode bm₂ := by
  unfold BalanceMap.encode
  congr 1
  rw [TreeMap.equiv_iff_toList_eq.mp h]

/-! ## ExtendedState determinism (analogous) -/

/-- Determinism (structural) for `ExtendedState`. -/
theorem extendedState_encode_deterministic
    (es₁ es₂ : ExtendedState) (h : es₁ = es₂) :
    Encodable.encode (T := ExtendedState) es₁ = Encodable.encode (T := ExtendedState) es₂ :=
  h ▸ rfl

end Encoding
end LegalKernel
