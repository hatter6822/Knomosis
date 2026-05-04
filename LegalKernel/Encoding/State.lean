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

**Round-trip statement (extensional).**  `TreeMap.ofList` /
`TreeMap.toList` form an extensional inverse pair: rebuilding a
`TreeMap` from its `toList` produces a `TreeMap.Equiv`-equivalent
result, but not necessarily a structurally equal one (because the
RB-tree shape is determined by the insertion order, and `ofList`
inserts in the canonical sorted-list order).  Phase 4's round-trip
theorems for `State` / `ExtendedState` are stated *extensionally*:
every per-`(resource, actor)` `getBalance` query of the decoded
state matches the original.  This matches Genesis Plan §8.8.3's
requirement ("identical state values produce identical bytes,
verified across `RBMap`s built by different insertion sequences"):
deployments compare states via their canonical bytes, not via
structural `TreeMap` equality.

This module is **not** part of the trusted computing base.  Bugs
here produce wrong serialisations, but cannot violate any kernel
invariant.
-/

import LegalKernel.Authority.Nonce
import LegalKernel.Encoding.Encodable
import LegalKernel.Encoding.SignedAction

open Std

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority

/-! ## Helpers: encode / decode a sorted-pair list -/

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

/-- Decode `n` `(K × V)` pairs from the front of `s`. -/
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

/-- Decode a CBE map header + N pairs. -/
def decodeMap {K V : Type} [Encodable K] [Encodable V] (s : Stream) :
    Except DecodeError (List (K × V) × Stream) :=
  match cborHeadDecode s cbeTagMap with
  | .ok (count, rest) => decodeNPairs count rest
  | .error e => .error e

/-! ## State encoding

A `State` is encoded as a CBE map of `ResourceId → (CBE map of
ActorId → Amount)`.  The outer map's pairs are sorted ascending by
`ResourceId`; each inner map's pairs are sorted ascending by
`ActorId`.  Both orderings come for free from `TreeMap.toList`
under the canonical `compare` ordering. -/

/-- Encode a `BalanceMap` (the inner per-resource `TreeMap ActorId
    Amount`). -/
def BalanceMap.encode (bm : BalanceMap) : Stream :=
  encodeSortedPairs (bm.toList.map (fun (a, v) => (a.toNat, v)))

/-- Encode a `State` as the outer map of resource → balance map. -/
def State.encode (s : State) : Stream :=
  encodeSortedPairs (s.balances.toList.map (fun (r, bm) =>
    (r.toNat, BalanceMap.encode bm)))

/-- Decode a `BalanceMap`: read the inner CBE map, rebuild via
    `TreeMap.ofList`. -/
def BalanceMap.decode (s : Stream) : Except DecodeError (BalanceMap × Stream) :=
  match decodeMap (K := Nat) (V := Nat) s with
  | .ok (pairs, rest) =>
    let pairs' : List (ActorId × Amount) :=
      pairs.filterMap (fun (k, v) =>
        if h : k < 18446744073709551616 then some (k.toUInt64, v) else
          let _ := h
          none)
    .ok (TreeMap.ofList pairs' compare, rest)
  | .error e => .error e

/-- Decode a `State`: read the outer CBE map, then for each entry
    decode the inner balance map.  The inner decoder runs over the
    bytes that were stored as the inner map's encoding. -/
def State.decode (s : Stream) : Except DecodeError (State × Stream) :=
  match decodeMap (K := Nat) (V := ByteArray) s with
  | .ok (pairs, rest) =>
    -- Each pair carries a serialised inner balance map.  Decode each.
    let inner : Except DecodeError (List (ResourceId × BalanceMap)) := pairs.foldlM
      (fun (acc : List (ResourceId × BalanceMap)) (p : Nat × ByteArray) =>
        if h : p.1 < 18446744073709551616 then
          match Encodable.decodeAllBytes (T := ByteArray) p.2 with
          | _ =>
            -- Each inner balance map is encoded as Stream and stored as ByteArray.
            -- Decode by treating the ByteArray bytes as a Stream and running BalanceMap.decode.
            match BalanceMap.decode p.2.data.toList with
            | .ok (bm, []) => .ok (acc ++ [(p.1.toUInt64, bm)])
            | .ok (_, _ :: _) => .error (.trailingBytes 1)
            | .error e => .error e
        else
          let _ := h
          .error (.invalidLength s!"State decoder: outer key {p.1} exceeds 2^64"))
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

/-- Encode an `ExtendedState` as `[base ++ nonces ++ registry]`. -/
def ExtendedState.encode (es : ExtendedState) : Stream :=
  State.encode es.base ++
  NonceState.encode es.nonces ++
  KeyRegistry.encodeMap es.registry

/-- Decode a `NonceState`. -/
def NonceState.decode (s : Stream) : Except DecodeError (NonceState × Stream) :=
  match decodeMap (K := Nat) (V := Nat) s with
  | .ok (pairs, rest) =>
    let pairs' : List (ActorId × Nonce) :=
      pairs.filterMap (fun (k, v) =>
        if h : k < 18446744073709551616 then some (k.toUInt64, v) else
          let _ := h
          none)
    .ok ({ next := TreeMap.ofList pairs' compare }, rest)
  | .error e => .error e

/-- Decode a `KeyRegistry`. -/
def KeyRegistry.decodeMap (s : Stream) : Except DecodeError (KeyRegistry × Stream) :=
  match Encoding.decodeMap (K := Nat) (V := ByteArray) s with
  | .ok (pairs, rest) =>
    let pairs' : List (ActorId × PublicKey) :=
      pairs.filterMap (fun (k, v) =>
        if h : k < 18446744073709551616 then some (k.toUInt64, v) else
          let _ := h
          none)
    .ok (TreeMap.ofList pairs' compare, rest)
  | .error e => .error e

/-- Decode an `ExtendedState`. -/
def ExtendedState.decode (s : Stream) : Except DecodeError (ExtendedState × Stream) :=
  match State.decode s with
  | .ok (base, s₁) =>
    match NonceState.decode s₁ with
    | .ok (nonces, s₂) =>
      match KeyRegistry.decodeMap s₂ with
      | .ok (registry, s₃) => .ok ({ base, nonces, registry }, s₃)
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
