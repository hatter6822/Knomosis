/-
  Knomosis  - A Societal Kernel
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
import LegalKernel.Encoding.LocalPolicy
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

/-! ### `encodeSortedPairs` round-trip + injectivity (EI.1.e)

The load-bearing polymorphic injectivity lemma for the
encoder-injectivity stack
(`docs/planning/encoder_injectivity_plan.md` §4.1).  Every per-sub-
state injectivity proof (EI.2 – EI.7) consumes
`encodeSortedPairs_injective` after specialising to its `(K, V)`
carrier.

The proof factors through `decodeNPairs_encode_foldr`, an internal
round-trip lemma for the body of an `encodeSortedPairs` output
(i.e. the foldr-concatenation of per-pair encodings).  The
hypothesis shape is the standard `ElemRoundtrip K` / `ElemRoundtrip V`
pair already used elsewhere in `Encoding/Encodable.lean`. -/

/-- Internal round-trip lemma for the body of an `encodeSortedPairs`
    output: under per-element round-trip hypotheses for both the key
    and value carriers, `decodeNPairs pairs.length` correctly inverts
    the foldr-encoded payload.

    Direct structural induction on `pairs`, mirroring the proof of
    `decodeListN_encode_foldr` in `Encoding/Encodable.lean`.

    Implementation note: we avoid `simp [..., List.append_assoc]`
    because that rewrites under the inner foldr's lambda binder
    (turning `encode p.1 ++ encode p.2 ++ acc` into
    `encode p.1 ++ (encode p.2 ++ acc)`), which prevents the IH from
    syntactically matching the goal.  Instead we apply
    `List.append_assoc` via targeted `rw` at the top level only,
    which keeps the inner foldr's lambda body intact. -/
private theorem decodeNPairs_encode_foldr
    {K V : Type} [Encodable K] [Encodable V]
    (hK : ElemRoundtrip K) (hV : ElemRoundtrip V)
    (pairs : List (K × V)) (rest : Stream) :
    decodeNPairs pairs.length
        (pairs.foldr (fun p acc =>
          Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] ++ rest)
      = .ok (pairs, rest) := by
  induction pairs with
  | nil =>
    -- The foldr over `[]` is `[]`, so the LHS becomes
    -- `decodeNPairs 0 ([] ++ rest) = .ok ([], rest)`, which is `rfl`
    -- after `decodeNPairs` unfolds.
    simp [decodeNPairs]
  | cons p ps ih =>
    -- Unfold `decodeNPairs` / `List.foldr` / `List.length` at the
    -- top level only.  Avoid `List.append_assoc` in simp; we apply
    -- it via targeted `rw` below to keep the inner foldr's lambda
    -- body untouched.
    simp only [decodeNPairs, List.foldr, List.length]
    -- Reassociate the outer ++ chain so the head encoding sits at
    -- the front of a single right-associated `++` cascade.  The
    -- two `List.append_assoc` rewrites apply only to the top-level
    -- terms, not under the foldr binder.
    rw [List.append_assoc (Encodable.encode p.1 ++ Encodable.encode p.2)]
    rw [List.append_assoc (Encodable.encode p.1)]
    -- Apply hK to decode the head key.
    rw [hK p.1 _]
    dsimp only
    -- Apply hV to decode the head value.
    rw [hV p.2 _]
    dsimp only
    -- Apply the induction hypothesis to recurse on the tail.
    rw [ih]
    -- Goal: .ok ((p.1, p.2) :: ps, rest) = .ok (p :: ps, rest).
    -- True by Prod's structural eta on the head pair.

/-- `encodeSortedPairs` injectivity: under per-element round-trip
    hypotheses for both the key and value carriers and the
    canonical-encoding length bound on the input pair lists, equal
    encoded byte streams imply equal pair lists.

    EI.1.e — `docs/planning/encoder_injectivity_plan.md` §4.1.  The
    headline polymorphic injectivity lemma of Workstream EI: every
    per-sub-state proof (EI.2 – EI.7) consumes this lemma after
    specialising to its `(K, V)` carrier.

    The length-bound hypotheses (`h_len₁` / `h_len₂`) discharge the
    `cborHeadEncode_injective` precondition (the pair-count fits in
    the 8-byte CBE head). -/
theorem encodeSortedPairs_injective
    {K V : Type} [Encodable K] [Encodable V]
    (hK : ElemRoundtrip K) (hV : ElemRoundtrip V)
    (pairs₁ pairs₂ : List (K × V))
    (h_len₁ : pairs₁.length < 256 ^ 8)
    (h_len₂ : pairs₂.length < 256 ^ 8)
    (h : encodeSortedPairs pairs₁ = encodeSortedPairs pairs₂) :
    pairs₁ = pairs₂ := by
  -- Unfold the encoder to expose its `head ++ body` decomposition.
  unfold encodeSortedPairs at h
  -- Apply `cborHeadDecode` to both sides of `h` (via the
  -- `cborHeadRoundtrip_append` lemma) to extract the pair-count
  -- equality and the body-bytes equality.
  have rd₁ := cborHeadRoundtrip_append cbeTagMap pairs₁.length
                (pairs₁.foldr (fun p acc =>
                  Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) []) h_len₁
  have rd₂ := cborHeadRoundtrip_append cbeTagMap pairs₂.length
                (pairs₂.foldr (fun p acc =>
                  Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) []) h_len₂
  rw [h] at rd₁
  -- rd₁ : cborHeadDecode (encoded RHS) cbeTagMap = .ok (pairs₁.length, body₁)
  -- rd₂ : cborHeadDecode (encoded RHS) cbeTagMap = .ok (pairs₂.length, body₂)
  have heq_head : (Except.ok (pairs₁.length,
                    pairs₁.foldr (fun p acc =>
                      Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [])
                  : Except DecodeError (Nat × Stream))
                = Except.ok (pairs₂.length,
                    pairs₂.foldr (fun p acc =>
                      Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) []) :=
    rd₁.symm.trans rd₂
  -- Extract pair-count equality and body equality.
  have h_pair := (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq_head)
  have h_len_eq : pairs₁.length = pairs₂.length := h_pair.1
  have h_body_eq : pairs₁.foldr (fun p acc =>
                    Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] =
                   pairs₂.foldr (fun p acc =>
                    Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] := h_pair.2
  -- Apply `decodeNPairs_encode_foldr` to recover the pair lists from
  -- the body bytes; equal bodies + equal length give the same decode
  -- result on both sides.
  have decn₁ := decodeNPairs_encode_foldr hK hV pairs₁ ([] : Stream)
  have decn₂ := decodeNPairs_encode_foldr hK hV pairs₂ ([] : Stream)
  simp only [List.append_nil] at decn₁ decn₂
  rw [h_body_eq, h_len_eq] at decn₁
  -- decn₁ : decodeNPairs pairs₂.length body₂ = .ok (pairs₁, [])
  -- decn₂ : decodeNPairs pairs₂.length body₂ = .ok (pairs₂, [])
  have heq_pairs : (Except.ok (pairs₁, ([] : Stream))
                  : Except DecodeError (List (K × V) × Stream))
                = Except.ok (pairs₂, []) := decn₁.symm.trans decn₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq_pairs) |>.1

/-! ### `encodeSortedPairs_injective_bounded` (EI.1.e per-list variant)

The `_bounded` variant accepts a *per-list* per-element round-trip
hypothesis instead of the universal `ElemRoundtrip K` / `ElemRoundtrip V`
requirement.  This is the variant downstream per-sub-state proofs
(EI.2 – EI.7) actually consume, because their inner pair lists key
on `Nat` (from `.toNat`) and value on `Nat` / `ByteArray` — both
of which have only *bounded* round-trip (`< 2^64`) rather than the
unconditional round-trip the universal variant requires.

The signature mirrors `list_roundtrip_bounded` / `ElemRoundtripIn`
in `Encoding/Encodable.lean`: the round-trip hypothesis is
quantified over membership in the actual input list rather than
universally over the carrier type.  We need four such hypotheses
(one for `K` and one for `V` per input list `pairs_i`) because the
proof applies the internal body-roundtrip lemma to each input
separately. -/

/-- Internal round-trip helper for the body of `encodeSortedPairs`
    under a per-list round-trip hypothesis.  Mirrors
    `decodeListN_encode_foldr_bounded` in `Encoding/Encodable.lean`. -/
private theorem decodeNPairs_encode_foldr_in
    {K V : Type} [Encodable K] [Encodable V]
    (pairs : List (K × V))
    (hK : ∀ p ∈ pairs, ∀ (rest : Stream),
            Encodable.decode (T := K) (Encodable.encode p.1 ++ rest) = .ok (p.1, rest))
    (hV : ∀ p ∈ pairs, ∀ (rest : Stream),
            Encodable.decode (T := V) (Encodable.encode p.2 ++ rest) = .ok (p.2, rest))
    (rest : Stream) :
    decodeNPairs pairs.length
        (pairs.foldr (fun p acc =>
          Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] ++ rest)
      = .ok (pairs, rest) := by
  induction pairs with
  | nil =>
    simp [decodeNPairs]
  | cons p ps ih =>
    -- Same proof structure as `decodeNPairs_encode_foldr`, but apply
    -- the per-list hypotheses at the head element and propagate the
    -- tail's per-list hypothesis to the IH.
    simp only [decodeNPairs, List.foldr, List.length]
    rw [List.append_assoc (Encodable.encode p.1 ++ Encodable.encode p.2)]
    rw [List.append_assoc (Encodable.encode p.1)]
    rw [hK p List.mem_cons_self _]
    dsimp only
    rw [hV p List.mem_cons_self _]
    dsimp only
    -- Propagate the tail's per-list hypothesis (membership in `ps`
    -- implies membership in `p :: ps`).
    have hK_tail : ∀ q ∈ ps, ∀ (rest : Stream),
        Encodable.decode (T := K) (Encodable.encode q.1 ++ rest) = .ok (q.1, rest) :=
      fun q hq_mem rest => hK q (List.mem_cons_of_mem _ hq_mem) rest
    have hV_tail : ∀ q ∈ ps, ∀ (rest : Stream),
        Encodable.decode (T := V) (Encodable.encode q.2 ++ rest) = .ok (q.2, rest) :=
      fun q hq_mem rest => hV q (List.mem_cons_of_mem _ hq_mem) rest
    rw [ih hK_tail hV_tail]

/-- `encodeSortedPairs` injectivity (bounded variant): per-list
    round-trip hypotheses for both the key and value carriers
    of each input pair list.  This is the variant per-sub-state
    proofs (EI.2 – EI.7) actually use, because they instantiate
    `K := Nat` (from `.toNat` coercion of `ActorId` etc.), and
    `nat_roundtrip` is *conditional* on the `< 2^64` bound — the
    universal `ElemRoundtrip Nat` required by
    `encodeSortedPairs_injective` is unprovable.

    EI.1.e (bounded variant) —
    `docs/planning/encoder_injectivity_plan.md` §4.1.  Use this
    when the carrier's round-trip is itself bound-conditional;
    use the universal `encodeSortedPairs_injective` when the
    carrier has unconditional round-trip (e.g. UInt8/16/32/64). -/
theorem encodeSortedPairs_injective_bounded
    {K V : Type} [Encodable K] [Encodable V]
    (pairs₁ pairs₂ : List (K × V))
    (h_len₁ : pairs₁.length < 256 ^ 8)
    (h_len₂ : pairs₂.length < 256 ^ 8)
    (hK₁ : ∀ p ∈ pairs₁, ∀ (rest : Stream),
              Encodable.decode (T := K) (Encodable.encode p.1 ++ rest) = .ok (p.1, rest))
    (hV₁ : ∀ p ∈ pairs₁, ∀ (rest : Stream),
              Encodable.decode (T := V) (Encodable.encode p.2 ++ rest) = .ok (p.2, rest))
    (hK₂ : ∀ p ∈ pairs₂, ∀ (rest : Stream),
              Encodable.decode (T := K) (Encodable.encode p.1 ++ rest) = .ok (p.1, rest))
    (hV₂ : ∀ p ∈ pairs₂, ∀ (rest : Stream),
              Encodable.decode (T := V) (Encodable.encode p.2 ++ rest) = .ok (p.2, rest))
    (h : encodeSortedPairs pairs₁ = encodeSortedPairs pairs₂) :
    pairs₁ = pairs₂ := by
  -- The proof mirrors `encodeSortedPairs_injective` but invokes
  -- `decodeNPairs_encode_foldr_in` (the per-list helper) on each
  -- side separately, since the per-list round-trip hypotheses for
  -- `pairs₁` and `pairs₂` are independent.
  unfold encodeSortedPairs at h
  have rd₁ := cborHeadRoundtrip_append cbeTagMap pairs₁.length
                (pairs₁.foldr (fun p acc =>
                  Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) []) h_len₁
  have rd₂ := cborHeadRoundtrip_append cbeTagMap pairs₂.length
                (pairs₂.foldr (fun p acc =>
                  Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) []) h_len₂
  rw [h] at rd₁
  have heq_head : (Except.ok (pairs₁.length,
                    pairs₁.foldr (fun p acc =>
                      Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [])
                  : Except DecodeError (Nat × Stream))
                = Except.ok (pairs₂.length,
                    pairs₂.foldr (fun p acc =>
                      Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) []) :=
    rd₁.symm.trans rd₂
  have h_pair := (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq_head)
  have h_len_eq : pairs₁.length = pairs₂.length := h_pair.1
  have h_body_eq : pairs₁.foldr (fun p acc =>
                    Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] =
                   pairs₂.foldr (fun p acc =>
                    Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] := h_pair.2
  -- Apply the per-list body-roundtrip helper to each side
  -- separately, using its own per-list hypotheses.
  have decn₁ := decodeNPairs_encode_foldr_in pairs₁ hK₁ hV₁ ([] : Stream)
  have decn₂ := decodeNPairs_encode_foldr_in pairs₂ hK₂ hV₂ ([] : Stream)
  simp only [List.append_nil] at decn₁ decn₂
  rw [h_body_eq, h_len_eq] at decn₁
  have heq_pairs : (Except.ok (pairs₁, ([] : Stream))
                  : Except DecodeError (List (K × V) × Stream))
                = Except.ok (pairs₂, []) := decn₁.symm.trans decn₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq_pairs) |>.1

/-! ### `encodeSortedPairs_self_delim_split` (EI.7.e precursor)

The "with suffix" variant of `encodeSortedPairs_injective_bounded`:
given two `encodeSortedPairs` encodings concatenated with their
respective suffixes, both the pair-list and the suffix are
recoverable.  Captures the **self-delimiting** property of CBE map
encodings.

The proof is a small variation of `encodeSortedPairs_injective_bounded`:
`cborHeadRoundtrip_append` and `decodeNPairs_encode_foldr_in` both
already handle arbitrary suffixes, so we thread the per-suffix
copies through transitivity to derive both the pair-list and suffix
equalities. -/

/-- Self-delimiting property of `encodeSortedPairs`: from byte-equality
    of two encoded-pair-list prefixes with arbitrary suffixes, recover
    both the pair-list equality and the suffix equality.  EI.7.e
    precursor — `docs/planning/encoder_injectivity_plan.md` §4.7. -/
theorem encodeSortedPairs_self_delim_split
    {K V : Type} [Encodable K] [Encodable V]
    (pairs₁ pairs₂ : List (K × V))
    (h_len₁ : pairs₁.length < 256 ^ 8)
    (h_len₂ : pairs₂.length < 256 ^ 8)
    (hK₁ : ∀ p ∈ pairs₁, ∀ (rest : Stream),
              Encodable.decode (T := K) (Encodable.encode p.1 ++ rest) = .ok (p.1, rest))
    (hV₁ : ∀ p ∈ pairs₁, ∀ (rest : Stream),
              Encodable.decode (T := V) (Encodable.encode p.2 ++ rest) = .ok (p.2, rest))
    (hK₂ : ∀ p ∈ pairs₂, ∀ (rest : Stream),
              Encodable.decode (T := K) (Encodable.encode p.1 ++ rest) = .ok (p.1, rest))
    (hV₂ : ∀ p ∈ pairs₂, ∀ (rest : Stream),
              Encodable.decode (T := V) (Encodable.encode p.2 ++ rest) = .ok (p.2, rest))
    (rest₁ rest₂ : Stream)
    (h : encodeSortedPairs pairs₁ ++ rest₁ = encodeSortedPairs pairs₂ ++ rest₂) :
    pairs₁ = pairs₂ ∧ rest₁ = rest₂ := by
  unfold encodeSortedPairs at h
  -- Re-associate so the CBE head is followed by (body ++ rest).
  rw [List.append_assoc, List.append_assoc] at h
  -- Apply `cborHeadRoundtrip_append` to both sides; the suffix is
  -- arbitrary, so the lemma handles `body ++ rest` as a single suffix.
  have rd₁ := cborHeadRoundtrip_append cbeTagMap pairs₁.length
                (pairs₁.foldr (fun p acc =>
                  Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] ++ rest₁) h_len₁
  have rd₂ := cborHeadRoundtrip_append cbeTagMap pairs₂.length
                (pairs₂.foldr (fun p acc =>
                  Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] ++ rest₂) h_len₂
  rw [h] at rd₁
  have heq_head : (Except.ok (pairs₁.length,
                    pairs₁.foldr (fun p acc =>
                      Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] ++ rest₁)
                  : Except DecodeError (Nat × Stream))
                = Except.ok (pairs₂.length,
                    pairs₂.foldr (fun p acc =>
                      Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] ++ rest₂) :=
    rd₁.symm.trans rd₂
  have h_pair := (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq_head)
  have h_len_eq : pairs₁.length = pairs₂.length := h_pair.1
  have h_body_rest_eq :
      pairs₁.foldr (fun p acc => Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] ++ rest₁ =
      pairs₂.foldr (fun p acc => Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) [] ++ rest₂ :=
    h_pair.2
  -- Apply `decodeNPairs_encode_foldr_in` to both sides with their
  -- respective suffixes.
  have decn₁ := decodeNPairs_encode_foldr_in pairs₁ hK₁ hV₁ rest₁
  have decn₂ := decodeNPairs_encode_foldr_in pairs₂ hK₂ hV₂ rest₂
  rw [h_body_rest_eq, h_len_eq] at decn₁
  have heq_pairs : (Except.ok (pairs₁, rest₁)
                  : Except DecodeError (List (K × V) × Stream))
                = Except.ok (pairs₂, rest₂) := decn₁.symm.trans decn₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq_pairs)

/-! ### EI.1.d (Equiv variant) — `encodeAsBytes` framing injectivity

The `BalanceMap.encodeAsBytes` framing wrapper produces a
`ByteArray` that the outer map's encoder slots into the value
position.  This helper lifts an inner-encoder injectivity proof
that concludes `Std.TreeMap.Equiv` through the framing wrapper to
the same `Equiv` conclusion on the framed `ByteArray` output.

Co-located with `encodeSortedPairs_injective` because both lemmas
operate on `Std.TreeMap`-valued data and share their consumer set
(`BalanceMap.encodeAsBytes_injective` lands in `Encoding/StateInjective.lean`
during EI.2.c). -/

/-- `Equiv`-flavoured framing-injectivity helper: when the inner
    encoder concludes a `Std.TreeMap.Equiv` rather than `Eq` (as
    `BalanceMap.encode` does, by EI.2.a/b), the framed
    `ByteArray.mk (encode m).toArray` form inherits the same
    `Equiv` conclusion.

    EI.1.d (Equiv variant) — `docs/planning/encoder_injectivity_plan.md`
    §4.1.  The `Eq` sibling lives in `Encoding/Encodable.lean`. -/
theorem encodeAsBytes_equiv_injective_of_encode_equiv_injective
    {α β : Type} {cmp : α → α → Ordering}
    (encode : Std.TreeMap α β cmp → Stream)
    (hInj : ∀ {m₁ m₂ : Std.TreeMap α β cmp}, encode m₁ = encode m₂ → m₁.Equiv m₂)
    {m₁ m₂ : Std.TreeMap α β cmp}
    (h : ByteArray.mk (encode m₁).toArray = ByteArray.mk (encode m₂).toArray) :
    m₁.Equiv m₂ := by
  -- Same byte-level argument as the `Eq`-flavoured sibling:
  -- structure-injection then `List.toList_toArray`.
  have h_arr : (encode m₁).toArray = (encode m₂).toArray := by
    injection h
  have h_list : (encode m₁).toArray.toList = (encode m₂).toArray.toList := by
    rw [h_arr]
  rw [List.toList_toArray, List.toList_toArray] at h_list
  exact hInj h_list

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
    `State.decode`.

    **Visibility note (EI.2 / OQ-EI-2 option (a)).**  Promoted from
    `private` to non-private when EI.2 shipped, so the per-sub-state
    framing-injectivity lemma `BalanceMap.encodeAsBytes_injective`
    can live alongside its siblings in
    `LegalKernel/Encoding/StateInjective.lean` (where
    `BalanceMap.encode_injective` is also stated).  This is an
    internal helper of the `State` codec — downstream callers should
    use `State.encode` / `Encodable.encode (T := State)` rather than
    constructing `encodeAsBytes` bytes directly. -/
def BalanceMap.encodeAsBytes (bm : BalanceMap) : ByteArray :=
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
    Mirrors the inner-map framing pattern in `BalanceMap.encodeAsBytes`.

    **Visibility note (EI.6 / OQ-EI-2 option (a)).**  Promoted from
    `private` to non-private when EI.6 shipped, so the per-sub-state
    framing-injectivity lemma `Bridge.DepositRecord.encodeAsBytes_injective`
    can live in `LegalKernel/Encoding/BridgeInjective.lean` alongside
    `Bridge.DepositRecord.encode_injective`.  Mirrors the visibility
    decision already taken for `BalanceMap.encodeAsBytes` during EI.2. -/
def Bridge.DepositRecord.encodeAsBytes (rec : Bridge.DepositRecord) :
    ByteArray :=
  ByteArray.mk (Bridge.DepositRecord.encode rec).toArray

/-- Encode the `consumed` field of a `BridgeState`. -/
def Bridge.BridgeState.encodeConsumed (bs : Bridge.BridgeState) : Stream :=
  encodeSortedPairs (bs.consumed.toList.map (fun (d, rec) =>
    (d, Bridge.DepositRecord.encodeAsBytes rec)))

/-- Encode a single `PendingWithdrawal`.

    Audit-2: the L1 recipient is encoded as a 20-byte BE ByteArray
    (lossless via `EthAddress.toBytes`).  The pre-audit Nat
    encoding truncated to 64 bits, which would have caused two
    distinct EthAddresses sharing low 64 bits to encode
    identically — corrupting the bridge's pending-withdrawal
    bookkeeping. -/
def Bridge.PendingWithdrawal.encode (wd : Bridge.PendingWithdrawal) : Stream :=
  Encodable.encode (T := Nat) wd.resource.toNat ++
  Encodable.encode (T := ByteArray) (Bridge.EthAddress.toBytes wd.recipient) ++
  Encodable.encode (T := Nat) wd.amount ++
  Encodable.encode (T := Nat) wd.l2LogIndex

/-- Wrap a `PendingWithdrawal` as a length-prefixed CBE byte string
    for placement in the outer `pending` map's value slot.

    **Visibility note (EI.7 / OQ-EI-2 option (a)).**  Promoted from
    `private` to non-private when EI.7 shipped, so the per-sub-state
    framing-injectivity lemma `Bridge.PendingWithdrawal.encodeAsBytes_injective`
    can live in `LegalKernel/Encoding/BridgeInjective.lean` alongside
    `Bridge.PendingWithdrawal.encode_injective`. -/
def Bridge.PendingWithdrawal.encodeAsBytes
    (wd : Bridge.PendingWithdrawal) : ByteArray :=
  ByteArray.mk (Bridge.PendingWithdrawal.encode wd).toArray

/-- Decode a `PendingWithdrawal`. -/
def Bridge.PendingWithdrawal.decode (s : Stream) :
    Except DecodeError (Bridge.PendingWithdrawal × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (resN, s₁) =>
    if h₁ : resN < 18446744073709551616 then
      match Encodable.decode (T := ByteArray) s₁ with
      | .ok (recBytes, s₂) =>
        match Bridge.EthAddress.ofBytes recBytes with
        | some rcp =>
          match Encodable.decode (T := Nat) s₂ with
          | .ok (amount, s₃) =>
            match Encodable.decode (T := Nat) s₃ with
            | .ok (idx, s₄) =>
              .ok ({ resource    := resN.toUInt64
                     recipient   := rcp
                     amount      := amount
                     l2LogIndex  := idx }, s₄)
            | .error e => .error e
          | .error e => .error e
        | none =>
          .error (.invalidLength
            s!"PendingWithdrawal.recipient expects 20 bytes; got {recBytes.size}")
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

/-- Encode an `ActorBudget` as `[lastSeenEpoch ++ budgetBalance]`. -/
def ActorBudget.encode (b : ActorBudget) : Stream :=
  Encodable.encode (T := Nat) b.lastSeenEpoch ++
  Encodable.encode (T := Nat) b.budgetBalance

/-- Decode an `ActorBudget` from `[lastSeenEpoch ++ budgetBalance]`. -/
def ActorBudget.decode (s : Stream) : Except DecodeError (ActorBudget × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (lastSeenEpoch, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (budgetBalance, s₂) =>
      .ok ({ lastSeenEpoch, budgetBalance }, s₂)
    | .error e => .error e
  | .error e => .error e

instance instEncodableActorBudget : Encodable ActorBudget where
  encode := ActorBudget.encode
  decode := ActorBudget.decode

/-- Encode `BudgetPolicy` in a tag+payload form:
    `0 ++ freeTier ++ actionCost ++ currentEpoch` for `bounded`. -/
def BudgetPolicy.encode : BudgetPolicy → Stream
  | .bounded freeTier actionCost currentEpoch =>
      Encodable.encode (T := Nat) 0 ++
      Encodable.encode (T := Nat) freeTier ++
      Encodable.encode (T := Nat) actionCost ++
      Encodable.encode (T := Nat) currentEpoch

/-- Decode `BudgetPolicy` from its canonical tag+payload encoding. -/
def BudgetPolicy.decode (s : Stream) : Except DecodeError (BudgetPolicy × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (0, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (freeTier, s₂) =>
      match Encodable.decode (T := Nat) s₂ with
      | .ok (actionCost, s₃) =>
        if actionCost = 0 then
          .error (.nonCanonical "budgetPolicy actionCost must be >= 1")
        else
          match Encodable.decode (T := Nat) s₃ with
          | .ok (currentEpoch, s₄) =>
            .ok (BudgetPolicy.mkBounded freeTier actionCost currentEpoch, s₄)
          | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .ok (_, _) => .error (.nonCanonical "budgetPolicy tag must be 0")
  | .error e => .error e

instance instEncodableBudgetPolicy : Encodable BudgetPolicy where
  encode := BudgetPolicy.encode
  decode := BudgetPolicy.decode

/-! ## GP.3.1.d — `ActorBudget` and `BudgetPolicy` encoder injectivity

The injectivity theorems for the new GP-introduced sub-state encodings,
shipping the GP.3.1.d "extension to ExtendedState.encode_injective"
deliverable per `docs/planning/unified_gas_pool_plan.md` §GP.3.1.
Mirrors the per-segment round-trip + nat-injectivity pattern used by
`depositRecord_roundtrip` / `pendingWithdrawal_roundtrip` (above) and
`nat_encode_injective` (`Encoding/Encodable.lean`).

Conditional on canonical-encoding bounds: every encoded `Nat` field
must fit in the CBE 8-byte LE length (< 2^64).  `BudgetPolicy` adds an
`actionCost ≥ 1` precondition that mirrors the smart constructor
`BudgetPolicy.mkBounded`'s clamp; otherwise the decoder rejects the
bytes and round-trip cannot hold.

These per-field theorems ratify that the new fields participate in
the existing encoder-injectivity ladder, even though
`ExtendedState.encode` itself is too coarse to admit a unified
structural-equality conclusion (the embedded `TreeMap`-backed
sub-states require extensional `Equiv`-shaped conclusions; see the
EI.8 ladder in `LegalKernel/FaultProof/Commit.lean` for the chain
that covers the kernel + bridge sub-states). -/

/-- Round-trip for `ActorBudget`: encode-then-decode is the identity
    when both `Nat` fields fit the canonical 8-byte LE bound. -/
theorem actorBudget_roundtrip
    (b : ActorBudget) (rest : Stream)
    (h_epoch : b.lastSeenEpoch < 256 ^ 8)
    (h_bal : b.budgetBalance < 256 ^ 8) :
    ActorBudget.decode (ActorBudget.encode b ++ rest) =
    .ok (b, rest) := by
  unfold ActorBudget.encode ActorBudget.decode
  rw [show Encodable.encode (T := Nat) b.lastSeenEpoch ++
            Encodable.encode (T := Nat) b.budgetBalance ++ rest =
          Encodable.encode (T := Nat) b.lastSeenEpoch ++
            (Encodable.encode (T := Nat) b.budgetBalance ++ rest)
      from by simp [List.append_assoc]]
  rw [nat_roundtrip b.lastSeenEpoch _ h_epoch]
  dsimp only
  rw [nat_roundtrip b.budgetBalance rest h_bal]

/-- Encoder injectivity for `ActorBudget`: equal canonical encodings
    imply equal structures, under canonical-encoding bounds on both
    sides.  Direct round-trip composition with `Except.ok.inj`. -/
theorem actorBudget_encode_injective
    (b₁ b₂ : ActorBudget)
    (h_e₁ : b₁.lastSeenEpoch < 256 ^ 8)
    (h_b₁ : b₁.budgetBalance < 256 ^ 8)
    (h_e₂ : b₂.lastSeenEpoch < 256 ^ 8)
    (h_b₂ : b₂.budgetBalance < 256 ^ 8)
    (h : ActorBudget.encode b₁ = ActorBudget.encode b₂) :
    b₁ = b₂ := by
  have r₁ := actorBudget_roundtrip b₁ [] h_e₁ h_b₁
  have r₂ := actorBudget_roundtrip b₂ [] h_e₂ h_b₂
  have h' : ActorBudget.encode b₁ ++ ([] : Stream)
          = ActorBudget.encode b₂ ++ [] := by rw [h]
  rw [h'] at r₁
  have heq : (Except.ok (b₁, ([] : Stream))
              : Except DecodeError (ActorBudget × Stream))
           = Except.ok (b₂, []) := r₁.symm.trans r₂
  have hpair := Except.ok.inj heq
  exact (Prod.mk.injEq _ _ _ _).mp hpair |>.1

/-- Round-trip for `BudgetPolicy`'s only constructor.  Discharges the
    `actionCost = 0` decoder gate via the `1 ≤ actionCost`
    precondition and reduces `mkBounded`'s `max actionCost 1` clamp
    to a no-op. -/
theorem budgetPolicy_bounded_roundtrip
    (freeTier actionCost currentEpoch : Nat) (rest : Stream)
    (h_ft : freeTier < 256 ^ 8)
    (h_ac : actionCost < 256 ^ 8)
    (h_ce : currentEpoch < 256 ^ 8)
    (h_pos : 1 ≤ actionCost) :
    BudgetPolicy.decode
        (BudgetPolicy.encode (.bounded freeTier actionCost currentEpoch) ++ rest)
      = .ok (.bounded freeTier actionCost currentEpoch, rest) := by
  unfold BudgetPolicy.encode BudgetPolicy.decode
  rw [show Encodable.encode (T := Nat) 0 ++
            Encodable.encode (T := Nat) freeTier ++
            Encodable.encode (T := Nat) actionCost ++
            Encodable.encode (T := Nat) currentEpoch ++ rest =
          Encodable.encode (T := Nat) 0 ++
            (Encodable.encode (T := Nat) freeTier ++
              (Encodable.encode (T := Nat) actionCost ++
                (Encodable.encode (T := Nat) currentEpoch ++ rest)))
      from by simp [List.append_assoc]]
  rw [nat_roundtrip 0 _ (by decide)]
  dsimp only
  rw [nat_roundtrip freeTier _ h_ft]
  dsimp only
  rw [nat_roundtrip actionCost _ h_ac]
  dsimp only
  have h_ne : actionCost ≠ 0 := by omega
  rw [if_neg h_ne]
  rw [nat_roundtrip currentEpoch rest h_ce]
  unfold BudgetPolicy.mkBounded
  rw [Nat.max_eq_left h_pos]

/-- Encoder injectivity for `BudgetPolicy`.  Two encodings agree iff
    the underlying structures agree, conditional on the canonical-
    encoding bounds (`< 2^64` on each `Nat` field) plus the
    `actionCost ≥ 1` smart-constructor invariant on both sides. -/
theorem budgetPolicy_encode_injective
    (p₁ p₂ : BudgetPolicy)
    (h_b₁ : ∀ ft ac ce, p₁ = .bounded ft ac ce →
              ft < 256 ^ 8 ∧ ac < 256 ^ 8 ∧ ce < 256 ^ 8 ∧ 1 ≤ ac)
    (h_b₂ : ∀ ft ac ce, p₂ = .bounded ft ac ce →
              ft < 256 ^ 8 ∧ ac < 256 ^ 8 ∧ ce < 256 ^ 8 ∧ 1 ≤ ac)
    (h : BudgetPolicy.encode p₁ = BudgetPolicy.encode p₂) :
    p₁ = p₂ := by
  cases p₁ with
  | bounded ft₁ ac₁ ce₁ =>
    cases p₂ with
    | bounded ft₂ ac₂ ce₂ =>
      obtain ⟨hft₁, hac₁, hce₁, hpos₁⟩ := h_b₁ ft₁ ac₁ ce₁ rfl
      obtain ⟨hft₂, hac₂, hce₂, hpos₂⟩ := h_b₂ ft₂ ac₂ ce₂ rfl
      have r₁ := budgetPolicy_bounded_roundtrip ft₁ ac₁ ce₁ [] hft₁ hac₁ hce₁ hpos₁
      have r₂ := budgetPolicy_bounded_roundtrip ft₂ ac₂ ce₂ [] hft₂ hac₂ hce₂ hpos₂
      have h' : BudgetPolicy.encode (.bounded ft₁ ac₁ ce₁) ++ ([] : Stream)
              = BudgetPolicy.encode (.bounded ft₂ ac₂ ce₂) ++ [] := by rw [h]
      rw [h'] at r₁
      have heq : (Except.ok (BudgetPolicy.bounded ft₁ ac₁ ce₁, ([] : Stream))
                  : Except DecodeError (BudgetPolicy × Stream))
               = Except.ok (BudgetPolicy.bounded ft₂ ac₂ ce₂, []) :=
        r₁.symm.trans r₂
      have hpair := Except.ok.inj heq
      exact (Prod.mk.injEq _ _ _ _).mp hpair |>.1

/-- Encode an `ExtendedState` as
    `[base ++ nonces ++ registry ++ bridge ++ localPolicies ++
      epochBudgets ++ budgetPolicy]`.
    GP.3.1 appends `epochBudgets` and `budgetPolicy` segments. -/
def ExtendedState.encode (es : ExtendedState) : Stream :=
  State.encode es.base ++
  NonceState.encode es.nonces ++
  KeyRegistry.encodeMap es.registry ++
  Bridge.BridgeState.encode es.bridge ++
  LocalPolicies.encodeMap es.localPolicies ++
  encodeSortedPairs (K := Nat) (V := ActorBudget)
    (es.epochBudgets.toList.map (fun (a, b) => (a.toNat, b))) ++
  BudgetPolicy.encode es.budgetPolicy

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

/-- Decode an `ExtendedState`.  Strict 7-segment decoder:
    pre-GP snapshots (without epoch budgets / budget policy) decode-fail,
    requiring operator re-snapshot under a GP.3-capable build. -/
def ExtendedState.decode (s : Stream) : Except DecodeError (ExtendedState × Stream) :=
  match State.decode s with
  | .ok (base, s₁) =>
    match NonceState.decode s₁ with
    | .ok (nonces, s₂) =>
      match KeyRegistry.decodeMap s₂ with
      | .ok (registry, s₃) =>
        match Bridge.BridgeState.decode s₃ with
        | .ok (bridge, s₄) =>
          match LocalPolicies.decodeMap s₄ with
          | .ok (localPolicies, s₅) =>
            match Encoding.decodeMap (K := Nat) (V := ActorBudget) s₅ with
            | .ok (budgetPairs, s₆) =>
              let epochBudgets : EpochBudgetState :=
                TreeMap.ofList (budgetPairs.map (fun (k, v) => (k.toUInt64, v))) compare
              match BudgetPolicy.decode s₆ with
              | .ok (budgetPolicy, s₇) =>
                .ok ({ base, nonces, registry, bridge, localPolicies, epochBudgets, budgetPolicy }, s₇)
              | .error e => .error e
            | .error e => .error e
          | .error e => .error e
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

/-! ## BridgeState encoding determinism (§7.1.4) -/

/-- Determinism (structural) for `BridgeState`: equal inputs
    produce equal bytes.  Trivially true (encode is a function);
    stated explicitly so the Workstream-C §7.1.4 deliverable is
    documented. -/
theorem bridgeState_encode_deterministic
    (bs₁ bs₂ : Bridge.BridgeState) (h : bs₁ = bs₂) :
    Encodable.encode (T := Bridge.BridgeState) bs₁ =
    Encodable.encode (T := Bridge.BridgeState) bs₂ :=
  h ▸ rfl

/-- Determinism for `DepositRecord`: equal inputs produce equal
    bytes. -/
theorem depositRecord_encode_deterministic
    (rec₁ rec₂ : Bridge.DepositRecord) (h : rec₁ = rec₂) :
    Bridge.DepositRecord.encode rec₁ = Bridge.DepositRecord.encode rec₂ :=
  h ▸ rfl

/-- Determinism for `PendingWithdrawal`. -/
theorem pendingWithdrawal_encode_deterministic
    (wd₁ wd₂ : Bridge.PendingWithdrawal) (h : wd₁ = wd₂) :
    Bridge.PendingWithdrawal.encode wd₁ = Bridge.PendingWithdrawal.encode wd₂ :=
  h ▸ rfl

/-- Round-trip for `DepositRecord`: under the canonical-encoding
    bound on the resource, encode-then-decode is the identity. -/
theorem depositRecord_roundtrip
    (rec : Bridge.DepositRecord) (rest : Stream)
    (h : rec.resource.toNat < 256 ^ 8 ∧ rec.amount < 256 ^ 8) :
    Bridge.DepositRecord.decode (Bridge.DepositRecord.encode rec ++ rest) =
    .ok (rec, rest) := by
  unfold Bridge.DepositRecord.encode Bridge.DepositRecord.decode
  obtain ⟨h1, h2⟩ := h
  rw [show Encodable.encode (T := Nat) rec.resource.toNat ++
            Encodable.encode (T := Nat) rec.amount ++ rest =
          Encodable.encode (T := Nat) rec.resource.toNat ++
            (Encodable.encode (T := Nat) rec.amount ++ rest)
      from by simp [List.append_assoc]]
  rw [nat_roundtrip rec.resource.toNat _ h1]
  dsimp only
  have hp : rec.resource.toNat < 18446744073709551616 := by
    have h_eq : (256 : Nat) ^ 8 = 18446744073709551616 := by decide
    omega
  rw [dif_pos hp]
  rw [nat_roundtrip rec.amount rest h2]
  show Except.ok ({ resource := rec.resource.toNat.toUInt64, amount := rec.amount }, rest)
       = .ok (rec, rest)
  congr 1
  congr 1
  show Bridge.DepositRecord.mk rec.resource.toNat.toUInt64 rec.amount = rec
  cases rec with
  | mk resource amount =>
    show Bridge.DepositRecord.mk resource.toNat.toUInt64 amount = ⟨resource, amount⟩
    have : resource.toNat.toUInt64 = resource := UInt64.ofNat_toNat
    rw [this]

/-- Round-trip for `PendingWithdrawal`: under canonical-encoding bounds on
    the resource, amount, and l2LogIndex `Nat` fields, encode-then-decode
    is the identity.  The recipient field's round-trip is unconditional
    (`EthAddress.toBytes` always produces a 20-byte payload that
    `EthAddress.ofBytes` recovers exactly via the existing
    `EthAddress.ofBytes_toBytes` lemma).

    EI.7.b precursor — `docs/planning/encoder_injectivity_plan.md` §4.7. -/
theorem pendingWithdrawal_roundtrip
    (wd : Bridge.PendingWithdrawal) (rest : Stream)
    (h_res : wd.resource.toNat < 256 ^ 8)
    (h_amt : wd.amount < 256 ^ 8)
    (h_idx : wd.l2LogIndex < 256 ^ 8) :
    Bridge.PendingWithdrawal.decode (Bridge.PendingWithdrawal.encode wd ++ rest) =
    .ok (wd, rest) := by
  unfold Bridge.PendingWithdrawal.encode Bridge.PendingWithdrawal.decode
  -- Re-associate the four-segment concatenation so each segment is
  -- consumed left-to-right by its own decoder.
  rw [show
    Encodable.encode (T := Nat) wd.resource.toNat ++
      Encodable.encode (T := ByteArray) (Bridge.EthAddress.toBytes wd.recipient) ++
      Encodable.encode (T := Nat) wd.amount ++
      Encodable.encode (T := Nat) wd.l2LogIndex ++ rest =
    Encodable.encode (T := Nat) wd.resource.toNat ++
      (Encodable.encode (T := ByteArray) (Bridge.EthAddress.toBytes wd.recipient) ++
        (Encodable.encode (T := Nat) wd.amount ++
          (Encodable.encode (T := Nat) wd.l2LogIndex ++ rest)))
    from by simp [List.append_assoc]]
  -- Segment 1: resource (Nat).
  rw [nat_roundtrip wd.resource.toNat _ h_res]
  dsimp only
  have hp_res : wd.resource.toNat < 18446744073709551616 := by
    have h_eq : (256 : Nat) ^ 8 = 18446744073709551616 := by decide
    omega
  rw [dif_pos hp_res]
  -- Segment 2: recipient bytes (ByteArray).  `EthAddress.toBytes` is
  -- always 20 bytes; well below 2^64.
  have h_size : (Bridge.EthAddress.toBytes wd.recipient).size < 256 ^ 8 := by
    rw [Bridge.EthAddress.toBytes_size]
    decide
  rw [byteArray_roundtrip _ _ h_size]
  dsimp only
  -- The `ofBytes (toBytes _)` step recovers the original `EthAddress`.
  rw [Bridge.EthAddress.ofBytes_toBytes]
  dsimp only
  -- Segment 3: amount (Nat).
  rw [nat_roundtrip wd.amount _ h_amt]
  dsimp only
  -- Segment 4: l2LogIndex (Nat).
  rw [nat_roundtrip wd.l2LogIndex rest h_idx]
  -- Reduce the constructed record back to `wd`.
  show Except.ok ({ resource := wd.resource.toNat.toUInt64,
                    recipient := wd.recipient,
                    amount := wd.amount,
                    l2LogIndex := wd.l2LogIndex }, rest)
     = .ok (wd, rest)
  congr 1
  congr 1
  cases wd with
  | mk resource recipient amount l2LogIndex =>
    show Bridge.PendingWithdrawal.mk resource.toNat.toUInt64 recipient amount l2LogIndex
       = ⟨resource, recipient, amount, l2LogIndex⟩
    have : resource.toNat.toUInt64 = resource := UInt64.ofNat_toNat
    rw [this]

/-! ## Project-wrapper encode injectivity (EI.1.g)

The project's atomic carriers (`ActorId`, `ResourceId`, `Amount`,
`Nonce`, `DepositId`, `WithdrawalId`, `PublicKey`) are all
`abbrev`-aliased to underlying primitive types; their `Encodable`
instances reduce directly to the primitive instance.  The lemmas
below provide named aliases for each wrapper's injectivity so
per-sub-state proofs (EI.2 – EI.7) can lean on the conventional
wrapper-named lemma instead of unfolding the abbreviation.

Per `docs/planning/encoder_injectivity_plan.md` §4.1 EI.1.g, the
wrappers are shipped here (in `Encoding/State.lean`, which already
imports every project-wrapper type) rather than in
`Encoding/Encodable.lean` (which would otherwise need to import
`Kernel`, `Authority.Crypto`, and `Bridge.State`).

`EthAddress` is **not** here.  `EthAddress` is a separate type
with its own `toBytes` / `ofBytes` pair; its injectivity is shipped
by EI.7.a (`EthAddress.toBytes_injective`) as a sub-state-specific
prerequisite. -/

/-- `ActorId` (`abbrev` for `UInt64`) encode injectivity.  Identical
    to `uInt64_encode_injective` after unfolding the abbreviation. -/
theorem actorId_encode_injective :
    Function.Injective (Encodable.encode : ActorId → Stream) :=
  uInt64_encode_injective

/-- `ResourceId` (`abbrev` for `UInt64`) encode injectivity.
    Identical to `uInt64_encode_injective`. -/
theorem resourceId_encode_injective :
    Function.Injective (Encodable.encode : ResourceId → Stream) :=
  uInt64_encode_injective

/-- `Amount` (`abbrev` for `Nat`) encode injectivity.  Conditional
    on the canonical-encoding bound `< 2^64` on both inputs. -/
theorem amount_encode_injective
    (a₁ a₂ : Amount)
    (h₁ : a₁ < 256 ^ 8) (h₂ : a₂ < 256 ^ 8)
    (h : Encodable.encode (T := Amount) a₁ = Encodable.encode (T := Amount) a₂) :
    a₁ = a₂ :=
  nat_encode_injective a₁ a₂ h₁ h₂ h

/-- `Nonce` (`abbrev` for `Nat`) encode injectivity.  Conditional
    on the canonical-encoding bound `< 2^64` on both inputs. -/
theorem nonce_encode_injective
    (n₁ n₂ : Nonce)
    (h₁ : n₁ < 256 ^ 8) (h₂ : n₂ < 256 ^ 8)
    (h : Encodable.encode (T := Nonce) n₁ = Encodable.encode (T := Nonce) n₂) :
    n₁ = n₂ :=
  nat_encode_injective n₁ n₂ h₁ h₂ h

/-- `Bridge.DepositId` (`abbrev` for `Nat`) encode injectivity.
    Conditional on the canonical-encoding bound `< 2^64`. -/
theorem depositId_encode_injective
    (d₁ d₂ : Bridge.DepositId)
    (h₁ : d₁ < 256 ^ 8) (h₂ : d₂ < 256 ^ 8)
    (h : Encodable.encode (T := Bridge.DepositId) d₁ =
         Encodable.encode (T := Bridge.DepositId) d₂) :
    d₁ = d₂ :=
  nat_encode_injective d₁ d₂ h₁ h₂ h

/-- `Bridge.WithdrawalId` (`abbrev` for `Nat`) encode injectivity.
    Conditional on the canonical-encoding bound `< 2^64`. -/
theorem withdrawalId_encode_injective
    (w₁ w₂ : Bridge.WithdrawalId)
    (h₁ : w₁ < 256 ^ 8) (h₂ : w₂ < 256 ^ 8)
    (h : Encodable.encode (T := Bridge.WithdrawalId) w₁ =
         Encodable.encode (T := Bridge.WithdrawalId) w₂) :
    w₁ = w₂ :=
  nat_encode_injective w₁ w₂ h₁ h₂ h

/-- `PublicKey` (`abbrev` for `ByteArray`) encode injectivity.
    Conditional on the canonical-encoding size bound `< 2^64` on
    both inputs.  Production `PublicKey` widths (e.g. secp256k1 at
    33 bytes compressed / 65 uncompressed; Ed25519 at 32) all
    trivially satisfy the bound. -/
theorem publicKey_encode_injective
    (p₁ p₂ : PublicKey)
    (h₁ : p₁.size < 256 ^ 8) (h₂ : p₂.size < 256 ^ 8)
    (h : Encodable.encode (T := PublicKey) p₁ =
         Encodable.encode (T := PublicKey) p₂) :
    p₁ = p₂ :=
  byteArray_encode_injective p₁ p₂ h₁ h₂ h

end Encoding
end LegalKernel
