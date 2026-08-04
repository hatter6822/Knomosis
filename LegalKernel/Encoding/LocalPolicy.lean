-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
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
  | .allowTopUpFrom delegates  =>
      delegates.length ≤ LocalPolicy.MAX_DELEGATES_PER_ALLOW

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
  | 3   | `allowTopUpFrom`     | `delegates : List ActorId` (GP.3.4) |
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
  | .allowTopUpFrom delegates  =>
      Encodable.encode (T := Nat) 3 ++
      Encodable.encode (T := List ActorId) delegates

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
  | .ok (3, s₁) =>
    -- GP.3.4: allowTopUpFrom (delegates : List ActorId).  Enforce
    -- MAX_DELEGATES_PER_ALLOW at decode (same DoS discipline as
    -- requireRecipientIn's recipient-list cap).
    match Encodable.decode (T := List ActorId) s₁ with
    | .ok (delegates, s₂) =>
      if delegates.length ≤ LocalPolicy.MAX_DELEGATES_PER_ALLOW then
        .ok (.allowTopUpFrom delegates, s₂)
      else
        .error (.invalidLength
          s!"allowTopUpFrom: {delegates.length} delegates exceeds MAX_DELEGATES_PER_ALLOW={LocalPolicy.MAX_DELEGATES_PER_ALLOW}")
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
  | allowTopUpFrom delegates =>
    -- h : LocalPolicyClause.fieldsBounded (.allowTopUpFrom delegates)
    --   = delegates.length ≤ MAX_DELEGATES_PER_ALLOW
    have hDelLen : delegates.length ≤ LocalPolicy.MAX_DELEGATES_PER_ALLOW := h
    show LocalPolicyClause.decode
            (LocalPolicyClause.encode (.allowTopUpFrom delegates) ++ rest) = .ok _
    unfold LocalPolicyClause.encode LocalPolicyClause.decode
    rw [show
      Encodable.encode (T := Nat) 3 ++
        Encodable.encode (T := List ActorId) delegates ++ rest =
      Encodable.encode (T := Nat) 3 ++
        (Encodable.encode (T := List ActorId) delegates ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 3 _ (by decide)]
    dsimp only
    -- List ActorId round-trip.
    have hLen_bound : delegates.length < 256 ^ 8 := by
      have h64 : LocalPolicy.MAX_DELEGATES_PER_ALLOW < 256 ^ 8 := by
        unfold LocalPolicy.MAX_DELEGATES_PER_ALLOW
        decide
      omega
    rw [list_roundtrip actorId_elem_roundtrip delegates rest hLen_bound]
    dsimp only
    -- Take the true branch of the decode-time bound check.
    rw [if_pos hDelLen]

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

`LocalPolicy.MAX_POLICY_ENCODE_BYTES` used to be a bare constant
whose docstring cited a `LocalPolicy.encode_size_bound` lemma that
did not exist, whose value (`16_384`) this module's own comment
admitted was smaller than the worst case it computed, and which no
production code consulted.  It is now the PROVEN bound below, so it
cannot drift from the encoder again.

The arithmetic, all of it discharged by the lemmas rather than
asserted:

  * every CBE head is `1 + 8 = 9` bytes (`cborHeadEncode`), and a
    `Nat` / `ActorId` / list head is exactly one head;
  * an `Amount` rides the 33-byte head after C-1, which is why
    `capAmount` is the widest fixed-size clause;
  * a clause is at most `9 (variant tag) + 9 (resource) + 9 (list
    head) + 64 * 9 (elements) = 603` bytes;
  * a policy is `9 (clause-list head) + 64 * 603 = 38 601` bytes.
-/

/-- Every CBE head is exactly 9 bytes: a 1-byte tag plus an 8-byte
    little-endian length. -/
theorem cborHeadEncode_length (major : UInt8) (n : Nat) :
    (cborHeadEncode major n).length = 9 := by
  unfold cborHeadEncode
  simp [natToBytesLE_length]

/-- A `Nat`'s canonical encoding is exactly one CBE head. -/
theorem nat_encode_length (n : Nat) :
    (Encodable.encode (T := Nat) n).length = 9 :=
  cborHeadEncode_length _ _

/-- An `ActorId`'s canonical encoding is exactly one CBE head. -/
theorem actorId_encode_length (a : ActorId) :
    (Encodable.encode (T := ActorId) a).length = 9 :=
  cborHeadEncode_length _ _

/-- A list's encoding is the 9-byte head plus the concatenated
    element encodings, so its length is bounded by
    `9 + xs.length * w` whenever every element encodes to at most
    `w` bytes. -/
theorem encodeList_length_le {α : Type} [Encodable α]
    (xs : List α) (w : Nat)
    (h_elem : ∀ x ∈ xs, (Encodable.encode x).length ≤ w) :
    (encodeList xs).length ≤ 9 + xs.length * w := by
  unfold encodeList
  rw [List.length_append, cborHeadEncode_length]
  have h_body : ∀ (ys : List α),
      (∀ y ∈ ys, (Encodable.encode y).length ≤ w) →
      (ys.foldr (fun x acc => Encodable.encode x ++ acc) []).length
        ≤ ys.length * w := by
    intro ys
    induction ys with
    | nil => intro _; simp
    | cons y ys ih =>
      intro h
      have hy : (Encodable.encode y).length ≤ w :=
        h y (List.mem_cons_self)
      have hrest : (ys.foldr (fun x acc => Encodable.encode x ++ acc) []).length
          ≤ ys.length * w :=
        ih (fun z hz => h z (List.mem_cons_of_mem _ hz))
      show ((Encodable.encode y) ++
        (ys.foldr (fun x acc => Encodable.encode x ++ acc) [])).length
          ≤ (y :: ys).length * w
      rw [List.length_append]
      calc (Encodable.encode y).length
            + (ys.foldr (fun x acc => Encodable.encode x ++ acc) []).length
          ≤ w + ys.length * w := Nat.add_le_add hy hrest
        _ = (ys.length + 1) * w := by rw [Nat.succ_mul]; omega
        _ = (y :: ys).length * w := by rw [List.length_cons]
  have := h_body xs h_elem
  omega

/-- Maximum encoded size of a single `LocalPolicyClause` satisfying
    `fieldsBounded`: the variant tag, an optional resource id, a list
    head, and at most 64 list elements — all 9-byte heads. -/
def MAX_CLAUSE_ENCODE_BYTES : Nat := 9 + 9 + 9 + 64 * 9

/-- `LocalPolicyClause.encode` respects `MAX_CLAUSE_ENCODE_BYTES`
    under `fieldsBounded`. -/
theorem localPolicyClause_encode_size_bound
    (c : LocalPolicyClause) (h : LocalPolicyClause.fieldsBounded c) :
    (LocalPolicyClause.encode c).length ≤ MAX_CLAUSE_ENCODE_BYTES := by
  unfold MAX_CLAUSE_ENCODE_BYTES
  cases c with
  | denyTags tags =>
    unfold LocalPolicyClause.fieldsBounded at h
    obtain ⟨h_len, _⟩ := h
    show ((Encodable.encode (T := Nat) 0) ++
      (Encodable.encode (T := List Nat) tags)).length ≤ _
    rw [List.length_append, nat_encode_length]
    have : (Encodable.encode (T := List Nat) tags).length ≤ 9 + tags.length * 9 :=
      encodeList_length_le tags 9 (fun x _ => le_of_eq (nat_encode_length x))
    have h64 : tags.length ≤ 64 := h_len
    have : tags.length * 9 ≤ 64 * 9 := Nat.mul_le_mul_right 9 h64
    omega
  | requireRecipientIn r allow =>
    unfold LocalPolicyClause.fieldsBounded at h
    show ((Encodable.encode (T := Nat) 1) ++
      (Encodable.encode (T := Nat) r.toNat) ++
      (Encodable.encode (T := List ActorId) allow)).length ≤ _
    rw [List.length_append, List.length_append, nat_encode_length, nat_encode_length]
    have : (Encodable.encode (T := List ActorId) allow).length ≤ 9 + allow.length * 9 :=
      encodeList_length_le allow 9 (fun x _ => le_of_eq (actorId_encode_length x))
    have : allow.length * 9 ≤ 64 * 9 := Nat.mul_le_mul_right 9 h
    omega
  | capAmount r max =>
    show ((Encodable.encode (T := Nat) 2) ++
      (Encodable.encode (T := Nat) r.toNat) ++
      (Encodable.encode (T := Nat) max)).length ≤ _
    rw [List.length_append, List.length_append,
        nat_encode_length, nat_encode_length, nat_encode_length]
    omega
  | allowTopUpFrom delegates =>
    unfold LocalPolicyClause.fieldsBounded at h
    show ((Encodable.encode (T := Nat) 3) ++
      (Encodable.encode (T := List ActorId) delegates)).length ≤ _
    rw [List.length_append, nat_encode_length]
    have : (Encodable.encode (T := List ActorId) delegates).length
        ≤ 9 + delegates.length * 9 :=
      encodeList_length_le delegates 9 (fun x _ => le_of_eq (actorId_encode_length x))
    have : delegates.length * 9 ≤ 64 * 9 := Nat.mul_le_mul_right 9 h
    omega

/-- **The §3.0 encode-size bound.**  A `fieldsBounded` policy encodes
    to at most `LocalPolicy.MAX_POLICY_ENCODE_BYTES` bytes.

    This is the lemma `LocalPolicy.MAX_POLICY_ENCODE_BYTES`'s
    docstring named and that this module previously declined to
    prove ("we do not prove the bound at the Lean level"), leaving a
    constant that was arithmetically FALSE — its `16_384` was below
    the 38 KB worst case the same comment computed. -/
theorem LocalPolicy.encode_size_bound
    (p : LocalPolicy) (h : LocalPolicy.fieldsBounded p) :
    (LocalPolicy.encode p).length ≤ LocalPolicy.MAX_POLICY_ENCODE_BYTES := by
  obtain ⟨h_len, h_all⟩ := h
  show (encodeList p.clauses).length ≤ _
  have h_elem : ∀ c ∈ p.clauses,
      (Encodable.encode (T := LocalPolicyClause) c).length ≤ MAX_CLAUSE_ENCODE_BYTES := by
    intro c hc
    have : LocalPolicyClause.fieldsBounded c :=
      of_decide_eq_true ((List.all_eq_true.mp h_all) c hc)
    exact localPolicyClause_encode_size_bound c this
  have hb := encodeList_length_le p.clauses MAX_CLAUSE_ENCODE_BYTES h_elem
  have h64 : p.clauses.length ≤ 64 := h_len
  have hm : p.clauses.length * MAX_CLAUSE_ENCODE_BYTES
      ≤ 64 * MAX_CLAUSE_ENCODE_BYTES :=
    Nat.mul_le_mul_right _ h64
  calc (encodeList p.clauses).length
      ≤ 9 + p.clauses.length * MAX_CLAUSE_ENCODE_BYTES := hb
    _ ≤ 9 + 64 * MAX_CLAUSE_ENCODE_BYTES := Nat.add_le_add_left hm 9
    _ = LocalPolicy.MAX_POLICY_ENCODE_BYTES := rfl

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
              -- Cons + reverse: `acc ++ [x]` walks the whole
              -- accumulator per element, so decoding an N-entry map
              -- cost O(N^2) on attacker-controlled input.
              | .ok (lp, []) => .ok ((p.1.toUInt64, lp) :: acc)
              | .ok (_, _ :: _) => .error (.trailingBytes 1)
              | .error e => .error e)
            []
        match inner with
        | .ok entries => .ok (TreeMap.ofList entries.reverse compare, rest')
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
