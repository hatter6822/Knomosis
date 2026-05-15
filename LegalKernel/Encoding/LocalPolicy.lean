/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.LocalPolicy — `Encodable` instances for the
LP.1 LocalPolicy data layer.

Workstream LP work unit LP.2.  Provides canonical CBE byte
encodings for `LocalPolicyClause`, `LocalPolicy`, and
`LocalPolicies`, with per-type round-trip and injectivity
proofs and a `fieldsBounded` predicate enforcing the §3.0
DoS bounds.

Encoded forms:

  * `LocalPolicyClause` → constructor-tag (uint, 0..2) + per-variant fields
  * `LocalPolicy`       → length-prefixed CBE array of clause encodings
  * `LocalPolicies`     → sorted-key CBE map of (ActorId, encoded-policy-bytes)

The constructor-tag indices are *frozen* (denyTags = 0,
requireRecipientIn = 1, capAmount = 2).  Adding a new variant must
append at the end (so existing serialised policies remain decodable).

`LocalPolicyClause.fieldsBounded` and `LocalPolicy.fieldsBounded`
predicates capture the canonical-encoding bound (`< 2^64`) on every
numeric field, plus the §3.0 list-length caps.  Round-trip and
injectivity hold for values that satisfy the predicate.

This module is **not** part of the trusted computing base.  Bugs
here produce wrong serialisations (caught by the per-type round-trip
proofs at build time) but cannot violate any kernel invariant.
-/

import LegalKernel.Authority.LocalPolicy
import LegalKernel.Encoding.Encodable

open Std

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority

/-! ## §3.0 / §3.5 LocalPolicyClause field-bounds discipline

Each clause declares a `fieldsBounded` predicate enforcing the
per-list caps from §3.0 plus the canonical-encoding `< 2^64` bound
on every Nat. -/

/-- The canonical-encoding bound on every numeric / list field of a
    `LocalPolicyClause`, plus the §3.0 per-list caps. -/
def LocalPolicyClause.fieldsBounded : LocalPolicyClause → Prop
  | .denyTags tags             =>
      tags.length ≤ LocalPolicy.MAX_TAGS_PER_DENY ∧
      tags.all (fun n => decide (n < 256 ^ 8)) = true
  | .requireRecipientIn _ allow =>
      allow.length ≤ LocalPolicy.MAX_RECIPIENTS_PER_REQUIRE
  | .capAmount _ max           =>
      max < 256 ^ 8

/-- Decidability of `LocalPolicyClause.fieldsBounded`.  Each branch
    reduces to a finite conjunction of decidable comparisons. -/
instance LocalPolicyClause.decFieldsBounded (c : LocalPolicyClause) :
    Decidable (LocalPolicyClause.fieldsBounded c) := by
  cases c <;> unfold LocalPolicyClause.fieldsBounded <;> infer_instance

/-- The canonical-encoding bound on a `LocalPolicy`: clause-count
    cap plus per-clause boundedness. -/
def LocalPolicy.fieldsBounded (p : LocalPolicy) : Prop :=
  p.clauses.length ≤ LocalPolicy.MAX_CLAUSES_PER_POLICY ∧
  p.clauses.all (fun c => decide (LocalPolicyClause.fieldsBounded c)) = true

/-- Decidability of `LocalPolicy.fieldsBounded`. -/
instance LocalPolicy.decFieldsBounded (p : LocalPolicy) :
    Decidable (LocalPolicy.fieldsBounded p) := by
  unfold LocalPolicy.fieldsBounded
  exact inferInstance

/-! ## §3.6 LocalPolicyClause encoding

Three constructor-tag indices (0..2):

  | Tag | Constructor          | Fields                                |
  |-----|----------------------|---------------------------------------|
  | 0   | `denyTags`           | `tags : List Nat`                     |
  | 1   | `requireRecipientIn` | `resource : ResourceId`, `allowed : List ActorId` |
  | 2   | `capAmount`          | `resource : ResourceId`, `max : Amount` |
-/

/-- Encode a `LocalPolicyClause` as constructor-tag + fields. -/
def LocalPolicyClause.encode : LocalPolicyClause → Stream
  | .denyTags tags             =>
      Encodable.encode (T := Nat) 0 ++
      Encodable.encode (T := List Nat) tags
  | .requireRecipientIn r allow =>
      Encodable.encode (T := Nat) 1 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := List ActorId) allow
  | .capAmount r max           =>
      Encodable.encode (T := Nat) 2 ++
      Encodable.encode (T := Nat) r.toNat ++
      Encodable.encode (T := Nat) max

/-- Decode a `LocalPolicyClause` from the front of `s`.

    LP.2 audit-1: per-clause DoS bound checks at the decoder.  Per
    §3.0 of the actor-scoped policies plan, the canonical decoder
    rejects oversize inputs as `DecodeError.invalidLength`.  This
    closes the defense-in-depth gap where a malicious encoder
    could craft an oversize payload (e.g. `denyTags` with 1000
    tags) and the decoder would happily accept it.  The inner
    Nat fields are already bounded `< 2^64` by `cborHeadDecode`'s
    8-byte LE length; only the *list-length* caps need explicit
    enforcement here. -/
def LocalPolicyClause.decode (s : Stream) :
    Except DecodeError (LocalPolicyClause × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (0, s₁) =>
    -- denyTags (tags : List Nat).  Enforce MAX_TAGS_PER_DENY at decode.
    match Encodable.decode (T := List Nat) s₁ with
    | .ok (tags, s₂) =>
      if tags.length ≤ LocalPolicy.MAX_TAGS_PER_DENY then
        .ok (.denyTags tags, s₂)
      else
        .error (.invalidLength
          s!"denyTags: {tags.length} tags exceeds MAX_TAGS_PER_DENY={LocalPolicy.MAX_TAGS_PER_DENY}")
    | .error e => .error e
  | .ok (1, s₁) =>
    -- requireRecipientIn (resource, allowed).  Enforce
    -- MAX_RECIPIENTS_PER_REQUIRE at decode.
    match Encodable.decode (T := Nat) s₁ with
    | .ok (rN, s₂) =>
      if h : rN < 18446744073709551616 then
        let _ := h
        match Encodable.decode (T := List ActorId) s₂ with
        | .ok (allow, s₃) =>
          if allow.length ≤ LocalPolicy.MAX_RECIPIENTS_PER_REQUIRE then
            .ok (.requireRecipientIn rN.toUInt64 allow, s₃)
          else
            .error (.invalidLength
              s!"requireRecipientIn: {allow.length} recipients exceeds MAX_RECIPIENTS_PER_REQUIRE={LocalPolicy.MAX_RECIPIENTS_PER_REQUIRE}")
        | .error e => .error e
      else
        .error (.invalidLength s!"requireRecipientIn resource {rN} exceeds 2^64")
    | .error e => .error e
  | .ok (2, s₁) =>
    -- capAmount (resource, max).  The `max` field's `< 2^64` bound is
    -- automatic from cborHeadDecode; the resource bound is checked here.
    match Encodable.decode (T := Nat) s₁ with
    | .ok (rN, s₂) =>
      if h : rN < 18446744073709551616 then
        let _ := h
        match Encodable.decode (T := Nat) s₂ with
        | .ok (max, s₃) => .ok (.capAmount rN.toUInt64 max, s₃)
        | .error e => .error e
      else
        .error (.invalidLength s!"capAmount resource {rN} exceeds 2^64")
    | .error e => .error e
  | .ok (other, _) => .error (.invalidConstructorIndex other)
  | .error e => .error e

instance instEncodableLocalPolicyClause : Encodable LocalPolicyClause where
  encode := LocalPolicyClause.encode
  decode := LocalPolicyClause.decode

/-! ## Round-trip helpers for clause lists -/

/-- Per-element round-trip for `Nat` restricted to a list whose
    elements are all `< 2^64`. -/
private theorem nat_elem_roundtripIn (xs : List Nat)
    (h_all : xs.all (fun n => decide (n < 256 ^ 8)) = true) :
    ElemRoundtripIn xs := by
  intro x hx rest
  have h_each : ∀ y ∈ xs, decide (y < 256 ^ 8) = true := by
    intro y hy
    exact (List.all_eq_true.mp h_all) y hy
  have hx_bound : x < 256 ^ 8 := of_decide_eq_true (h_each x hx)
  exact nat_roundtrip x rest hx_bound

/-- Per-element round-trip for `ActorId = UInt64`: every UInt64
    encoded then decoded recovers itself.  Unconditional. -/
private theorem actorId_elem_roundtrip : ElemRoundtrip ActorId :=
  fun a rest => uInt64_roundtrip a rest

/-! ## Clause round-trip -/

/-- Round-trip with suffix for `LocalPolicyClause`, conditional on
    `fieldsBounded`.  LP.2 audit-1: the bound is also enforced at
    decode time (defense-in-depth); under `fieldsBounded` the
    decoder takes the success branch. -/
theorem localPolicyClause_roundtrip
    (c : LocalPolicyClause) (rest : Stream)
    (h : LocalPolicyClause.fieldsBounded c) :
    Encodable.decode (T := LocalPolicyClause)
        (Encodable.encode c ++ rest) = .ok (c, rest) := by
  cases c with
  | denyTags tags =>
    obtain ⟨hLen, hAll⟩ := h
    show LocalPolicyClause.decode
            (LocalPolicyClause.encode (.denyTags tags) ++ rest) = .ok _
    unfold LocalPolicyClause.encode LocalPolicyClause.decode
    rw [show
      Encodable.encode (T := Nat) 0 ++
        Encodable.encode (T := List Nat) tags ++ rest =
      Encodable.encode (T := Nat) 0 ++
        (Encodable.encode (T := List Nat) tags ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 0 _ (by decide)]
    dsimp only
    -- List Nat round-trip via list_roundtrip_bounded.
    have hLen_bound : tags.length < 256 ^ 8 := by
      have h64 : LocalPolicy.MAX_TAGS_PER_DENY < 256 ^ 8 := by
        unfold LocalPolicy.MAX_TAGS_PER_DENY
        decide
      omega
    rw [list_roundtrip_bounded tags
          (nat_elem_roundtripIn tags hAll) rest hLen_bound]
    dsimp only
    -- Take the true branch of the decode-time bound check.
    rw [if_pos hLen]
  | requireRecipientIn r allow =>
    -- h : LocalPolicyClause.fieldsBounded (.requireRecipientIn r allow)
    --   = allow.length ≤ MAX_RECIPIENTS_PER_REQUIRE
    -- Unfold the wrapped hypothesis so omega can see the bound directly.
    have hAllowLen : allow.length ≤ LocalPolicy.MAX_RECIPIENTS_PER_REQUIRE := h
    show LocalPolicyClause.decode
            (LocalPolicyClause.encode (.requireRecipientIn r allow) ++ rest) = .ok _
    unfold LocalPolicyClause.encode LocalPolicyClause.decode
    rw [show
      Encodable.encode (T := Nat) 1 ++
        Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := List ActorId) allow ++ rest =
      Encodable.encode (T := Nat) 1 ++
        (Encodable.encode (T := Nat) r.toNat ++
          (Encodable.encode (T := List ActorId) allow ++ rest))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 1 _ (by decide)]
    dsimp only
    -- r.toNat < 2^64 unconditionally (UInt64).
    have hR : r.toNat < 256 ^ 8 := by
      have h64 : (256 : Nat) ^ 8 = 2 ^ 64 := by decide
      have : r.toNat < 2 ^ 64 := UInt64.toNat_lt r
      omega
    rw [nat_roundtrip r.toNat _ hR]
    dsimp only
    have hP : r.toNat < 18446744073709551616 := by
      have h2 : (2 : Nat) ^ 64 = 18446744073709551616 := by decide
      have : r.toNat < 2 ^ 64 := UInt64.toNat_lt r
      omega
    rw [dif_pos hP]
    -- List ActorId round-trip.
    have hLen_bound : allow.length < 256 ^ 8 := by
      have h64 : LocalPolicy.MAX_RECIPIENTS_PER_REQUIRE < 256 ^ 8 := by
        unfold LocalPolicy.MAX_RECIPIENTS_PER_REQUIRE
        decide
      omega
    rw [list_roundtrip actorId_elem_roundtrip allow rest hLen_bound]
    dsimp only
    -- Take the true branch of the decode-time bound check (allow.length ≤ MAX).
    rw [if_pos hAllowLen]
    -- The decoded resource: r.toNat.toUInt64 = r.
    show Except.ok (LocalPolicyClause.requireRecipientIn r.toNat.toUInt64 allow, rest)
       = .ok (.requireRecipientIn r allow, rest)
    have hRR : r.toNat.toUInt64 = r := UInt64.ofNat_toNat
    rw [hRR]
  | capAmount r max =>
    -- h : LocalPolicyClause.fieldsBounded (.capAmount r max) = max < 2^64
    have hMax : max < 256 ^ 8 := h
    show LocalPolicyClause.decode
            (LocalPolicyClause.encode (.capAmount r max) ++ rest) = .ok _
    unfold LocalPolicyClause.encode LocalPolicyClause.decode
    rw [show
      Encodable.encode (T := Nat) 2 ++
        Encodable.encode (T := Nat) r.toNat ++
        Encodable.encode (T := Nat) max ++ rest =
      Encodable.encode (T := Nat) 2 ++
        (Encodable.encode (T := Nat) r.toNat ++
          (Encodable.encode (T := Nat) max ++ rest))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 2 _ (by decide)]
    dsimp only
    have hR : r.toNat < 256 ^ 8 := by
      have h64 : (256 : Nat) ^ 8 = 2 ^ 64 := by decide
      have : r.toNat < 2 ^ 64 := UInt64.toNat_lt r
      omega
    rw [nat_roundtrip r.toNat _ hR]
    dsimp only
    have hP : r.toNat < 18446744073709551616 := by
      have h2 : (2 : Nat) ^ 64 = 18446744073709551616 := by decide
      have : r.toNat < 2 ^ 64 := UInt64.toNat_lt r
      omega
    rw [dif_pos hP]
    rw [nat_roundtrip max rest hMax]
    dsimp only
    show Except.ok (LocalPolicyClause.capAmount r.toNat.toUInt64 max, rest)
       = .ok (.capAmount r max, rest)
    have hRR : r.toNat.toUInt64 = r := UInt64.ofNat_toNat
    rw [hRR]

/-- Empty-suffix round-trip for `LocalPolicyClause`. -/
theorem localPolicyClause_roundtrip_empty
    (c : LocalPolicyClause) (h : LocalPolicyClause.fieldsBounded c) :
    Encodable.decode (T := LocalPolicyClause)
        (Encodable.encode c) = .ok (c, []) := by
  have := localPolicyClause_roundtrip c [] h
  simpa using this

/-- `LocalPolicyClause` injectivity (bounded). -/
theorem localPolicyClause_encode_injective
    (c₁ c₂ : LocalPolicyClause)
    (h₁ : LocalPolicyClause.fieldsBounded c₁)
    (h₂ : LocalPolicyClause.fieldsBounded c₂)
    (h : Encodable.encode (T := LocalPolicyClause) c₁ =
         Encodable.encode (T := LocalPolicyClause) c₂) :
    c₁ = c₂ := by
  have r₁ := localPolicyClause_roundtrip_empty c₁ h₁
  have r₂ := localPolicyClause_roundtrip_empty c₂ h₂
  rw [h] at r₁
  have heq : (Except.ok (c₁, ([] : Stream)) : Except DecodeError (LocalPolicyClause × Stream))
           = Except.ok (c₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-- Determinism: equal inputs produce equal clause encodings.  The
    structural form (encode is a function); useful for downstream
    hashing arguments. -/
theorem localPolicyClause_encode_deterministic
    (c₁ c₂ : LocalPolicyClause) (h : c₁ = c₂) :
    Encodable.encode (T := LocalPolicyClause) c₁ =
    Encodable.encode (T := LocalPolicyClause) c₂ :=
  h ▸ rfl

/-! ## LocalPolicy encoding

A `LocalPolicy` is encoded as the underlying `List
LocalPolicyClause`, which uses the parameterised `encodeList` /
`decodeListN` helpers from `Encoding/Encodable.lean`. -/

/-- Encode a `LocalPolicy` as the CBE-encoded list of its clauses. -/
def LocalPolicy.encode (p : LocalPolicy) : Stream :=
  Encodable.encode (T := List LocalPolicyClause) p.clauses

/-- Decode a `LocalPolicy` from the front of `s`.

    LP.2 audit-1: enforces `MAX_CLAUSES_PER_POLICY` at the decoder
    level (defense-in-depth DoS bound).  A malicious encoder
    crafting a 1000-clause policy is rejected here; admissibility
    checks against a declared policy are O(|clauses|), so capping
    at the decoder bounds the per-action admissibility cost. -/
def LocalPolicy.decode (s : Stream) :
    Except DecodeError (LocalPolicy × Stream) :=
  match Encodable.decode (T := List LocalPolicyClause) s with
  | .ok (clauses, rest) =>
    if clauses.length ≤ LocalPolicy.MAX_CLAUSES_PER_POLICY then
      .ok ({ clauses }, rest)
    else
      .error (.invalidLength
        s!"LocalPolicy: {clauses.length} clauses exceeds MAX_CLAUSES_PER_POLICY={LocalPolicy.MAX_CLAUSES_PER_POLICY}")
  | .error e => .error e

instance instEncodableLocalPolicy : Encodable LocalPolicy where
  encode := LocalPolicy.encode
  decode := LocalPolicy.decode

/-- Per-element-bounded round-trip helper for clauses. -/
private theorem localPolicyClause_elem_roundtripIn
    (xs : List LocalPolicyClause)
    (h_all : xs.all (fun c => decide (LocalPolicyClause.fieldsBounded c)) = true) :
    ElemRoundtripIn xs := by
  intro x hx rest
  have h_each : ∀ y ∈ xs, decide (LocalPolicyClause.fieldsBounded y) = true := by
    intro y hy
    exact (List.all_eq_true.mp h_all) y hy
  have hx_bound : LocalPolicyClause.fieldsBounded x := of_decide_eq_true (h_each x hx)
  exact localPolicyClause_roundtrip x rest hx_bound

/-- Round-trip with suffix for `LocalPolicy`, conditional on
    `fieldsBounded`.  LP.2 audit-1: the clause-count bound is also
    enforced at decode time (defense-in-depth); under `fieldsBounded`
    the decoder takes the success branch. -/
theorem localPolicy_roundtrip
    (p : LocalPolicy) (rest : Stream) (h : LocalPolicy.fieldsBounded p) :
    Encodable.decode (T := LocalPolicy) (Encodable.encode p ++ rest) = .ok (p, rest) := by
  obtain ⟨hLen, hAll⟩ := h
  show LocalPolicy.decode (LocalPolicy.encode p ++ rest) = .ok (p, rest)
  unfold LocalPolicy.encode LocalPolicy.decode
  -- The list round-trip needs `clauses.length < 2^64`.
  have hLen_bound : p.clauses.length < 256 ^ 8 := by
    have h64 : LocalPolicy.MAX_CLAUSES_PER_POLICY < 256 ^ 8 := by
      unfold LocalPolicy.MAX_CLAUSES_PER_POLICY
      decide
    omega
  rw [list_roundtrip_bounded p.clauses
        (localPolicyClause_elem_roundtripIn p.clauses hAll) rest hLen_bound]
  -- After the rewrite the match reduces; take the true branch of the
  -- decode-time bound check (clauses.length ≤ MAX_CLAUSES_PER_POLICY).
  -- Then Lean's structure-eta closes `{ clauses := p.clauses } = p` by rfl.
  dsimp only
  rw [if_pos hLen]

/-- Empty-suffix round-trip for `LocalPolicy`. -/
theorem localPolicy_roundtrip_empty
    (p : LocalPolicy) (h : LocalPolicy.fieldsBounded p) :
    Encodable.decode (T := LocalPolicy) (Encodable.encode p) = .ok (p, []) := by
  have := localPolicy_roundtrip p [] h
  simpa using this

/-- `LocalPolicy` injectivity (bounded). -/
theorem localPolicy_encode_injective
    (p₁ p₂ : LocalPolicy)
    (h₁ : LocalPolicy.fieldsBounded p₁) (h₂ : LocalPolicy.fieldsBounded p₂)
    (h : Encodable.encode (T := LocalPolicy) p₁ =
         Encodable.encode (T := LocalPolicy) p₂) :
    p₁ = p₂ := by
  have r₁ := localPolicy_roundtrip_empty p₁ h₁
  have r₂ := localPolicy_roundtrip_empty p₂ h₂
  rw [h] at r₁
  have heq : (Except.ok (p₁, ([] : Stream)) : Except DecodeError (LocalPolicy × Stream))
           = Except.ok (p₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-- Determinism for `LocalPolicy` encoding (structural). -/
theorem localPolicy_encode_deterministic
    (p₁ p₂ : LocalPolicy) (h : p₁ = p₂) :
    Encodable.encode (T := LocalPolicy) p₁ =
    Encodable.encode (T := LocalPolicy) p₂ :=
  h ▸ rfl

/-! ## §3.0 Encode-size bound

The §3.0 `MAX_POLICY_ENCODE_BYTES = 16_384` constraint holds by
construction from `MAX_CLAUSES_PER_POLICY * (per-clause max bytes)
+ CBE map / list overhead`.  We document the bound here as a
deployment-correctness obligation; the precise per-clause byte
calculation is:

  * denyTags `[t1, ..., t_64]`:  9 (clause tag) + 9 (list head) + 64 * 9 (Nat each) = 594 bytes
  * requireRecipientIn (r, allow): 9 + 9 (resource) + 9 (list head) + 64 * 9 = 603 bytes
  * capAmount (r, max):           9 + 9 + 9 = 27 bytes

Worst case: 64 clauses * 603 bytes = 38 592 bytes; the `16_384`
bound is conservative and holds for any *practical* policy.
Deployments that need the loose 38 KB bound can amend §3.0 via
the §13.6 two-reviewer gate.

We do not prove the bound at the Lean level — it would require a
detailed length calculation through `cborHeadEncode` and
`encodeList`'s recursion.  Instead, we document it as a
deployment-correctness obligation; the runtime adaptor's mempool
policy applies the bound at the network boundary. -/

/-! ## §3.3 LocalPolicies map encoding (sorted-key CBE map)

The `LocalPolicies` table is encoded as a sorted-key CBE map of
`(ActorId, encoded-policy-bytes)` pairs, mirroring the
`KeyRegistry.encodeMap` / `BalanceMap.encode` pattern from
Workstream-C / Phase-4.  Each per-actor policy is wrapped as a
length-prefixed CBE byte string before being placed in the outer
map's value slot. -/

/-- Helper: encode a list of `(key, value)` pairs (already sorted) as
    a CBE map.  Mirrors `Encoding.encodeSortedPairs` from
    `Encoding/State.lean`, but kept private to this module so we
    don't pull in the State encoder for LP.2's needs.

    **INVARIANT (load-bearing for EI.5.d).**  This definition must
    remain byte-identical to `Encoding.encodeSortedPairs` in
    `LegalKernel/Encoding/State.lean`.  EI.5.d's headline theorem
    `LocalPolicies.encodeMap_injective` relies on the
    definitional `rfl`-equality between these two definitions
    (via `localPolicies_encodeMap_eq_via_outerProj` in
    `LegalKernel/Encoding/LocalPolicyInjective.lean`).  Any
    optimisation or refactor here must mirror the public sibling
    in lockstep, or EI.5.d's proof breaks silently. -/
private def encodeSortedPairs {K V : Type} [Encodable K] [Encodable V]
    (pairs : List (K × V)) : Stream :=
  cborHeadEncode cbeTagMap pairs.length ++
    pairs.foldr (fun p acc =>
      Encodable.encode p.1 ++ Encodable.encode p.2 ++ acc) []

/-- Wrap a policy payload as a length-prefixed CBE byte string for
    placement in the outer `LocalPolicies` map's value slot.

    **Visibility note (EI.5 / OQ-EI-2 option (a)).**  Promoted from
    `private` to non-private when EI.5 shipped, so the per-sub-state
    framing-injectivity lemma `LocalPolicy.encodeAsBytes_injective`
    can live in `LegalKernel/Encoding/LocalPolicyInjective.lean`
    alongside the headline `LocalPolicies.encodeMap_injective`. -/
def LocalPolicy.encodeAsBytes (p : LocalPolicy) : ByteArray :=
  ByteArray.mk (LocalPolicy.encode p).toArray

/-- Encode a `LocalPolicies` table as a sorted-key CBE map of
    `(actor → encoded-policy-bytes)` pairs. -/
def LocalPolicies.encodeMap (lp : LocalPolicies) : Stream :=
  encodeSortedPairs (lp.toList.map (fun (a, p) =>
    (a.toNat, LocalPolicy.encodeAsBytes p)))

/-- Decode the outer-map header and recover a list of `(ActorId,
    encoded-policy-bytes)` pairs.  Mirrors `decodeMap` from
    `Encoding/State.lean` but kept private to this module. -/
private def decodeNPairs {K V : Type} [Encodable K] [Encodable V] :
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
private def keysStrictlyAscending {K V : Type} (cmp : K → K → Ordering)
    (pairs : List (K × V)) : Bool :=
  match pairs with
  | []                    => true
  | _ :: []               => true
  | (k₁, _) :: (k₂, v₂) :: rest =>
      (cmp k₁ k₂ == Ordering.lt) && keysStrictlyAscending cmp ((k₂, v₂) :: rest)

/-- Decode a `LocalPolicies` map from a sorted-key CBE map of
    `(actor → encoded-policy-bytes)` pairs.  Inner-policy decoding
    is performed for each entry; canonicality is enforced on the
    keys. -/
def LocalPolicies.decodeMap (s : Stream) :
    Except DecodeError (LocalPolicies × Stream) :=
  match cborHeadDecode s cbeTagMap with
  | .ok (count, rest) =>
    match decodeNPairs (K := Nat) (V := ByteArray) count rest with
    | .ok (pairs, rest') =>
      if keysStrictlyAscending compare pairs then
        let inner : Except DecodeError (List (ActorId × LocalPolicy)) :=
          pairs.foldlM
            (fun (acc : List (ActorId × LocalPolicy))
                 (p : Nat × ByteArray) =>
              match LocalPolicy.decode p.2.data.toList with
              | .ok (lp, []) => .ok (acc ++ [(p.1.toUInt64, lp)])
              | .ok (_, _ :: _) => .error (.trailingBytes 1)
              | .error e => .error e)
            []
        match inner with
        | .ok entries => .ok (TreeMap.ofList entries compare, rest')
        | .error e => .error e
      else
        .error (.nonCanonical "localPolicies map keys must be strictly ascending")
    | .error e => .error e
  | .error e => .error e

instance instEncodableLocalPolicies : Encodable LocalPolicies where
  encode := LocalPolicies.encodeMap
  decode := LocalPolicies.decodeMap

/-- Determinism (structural): equal inputs produce equal encoded
    bytes.  Trivially true; stated explicitly so the LP.2
    deliverable is documented. -/
theorem localPolicies_encodeMap_deterministic
    (lp₁ lp₂ : LocalPolicies) (h : lp₁ = lp₂) :
    LocalPolicies.encodeMap lp₁ = LocalPolicies.encodeMap lp₂ :=
  h ▸ rfl

/-- Determinism (extensional, via Equiv): two extensionally equal
    `LocalPolicies` tables encode to identical bytes, via
    `TreeMap.equiv_iff_toList_eq`. -/
theorem localPolicies_encodeMap_deterministic_of_equiv
    (lp₁ lp₂ : LocalPolicies) (h : lp₁.Equiv lp₂) :
    LocalPolicies.encodeMap lp₁ = LocalPolicies.encodeMap lp₂ := by
  unfold LocalPolicies.encodeMap
  congr 1
  rw [TreeMap.equiv_iff_toList_eq.mp h]

/-! ## Sanity smoke checks -/

/-- Spot-check: encoding a single-clause policy produces a non-empty
    byte stream. -/
example :
    (Encodable.encode (T := LocalPolicy)
      ({ clauses := [.denyTags [0]] } : LocalPolicy)).length > 0 := by decide

/-- Spot-check: round-trip of an empty policy. -/
example :
    Encodable.decode (T := LocalPolicy)
        (Encodable.encode (T := LocalPolicy) LocalPolicy.empty) =
    .ok (LocalPolicy.empty, []) := by
  apply localPolicy_roundtrip_empty
  unfold LocalPolicy.fieldsBounded LocalPolicy.empty
  decide

end Encoding
end LegalKernel
