/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Encoding.Disputes — `Encodable` instances for the §8.4
dispute / verdict types.

Phase 6 WU 6.1.  Provides canonical CBE byte encodings for the
dispute-pipeline data types, with per-type round-trip and injectivity
proofs.  Encoded forms:

  * `DisputeClaim`   → constructor-tag (uint, 0..4) + per-variant fields
  * `EvidenceVerdict` → constructor-tag (uint, 0..2)
  * `Dispute`        → `[challenger, claim, evidence, nonce, sig]`
  * `Verdict`        → `[disputeId, outcome, rationale,
                         signers (List), sigs (List)]`

The constructor-tag indices are *frozen*: they match the inductive
declaration order in `LegalKernel/Disputes/Types.lean`.  Adding a
new variant must append at the end (so existing serialised disputes
remain decodable).

`Dispute.fieldsBounded` and `Verdict.fieldsBounded` predicate
families captures the canonical-encoding bound (`< 2^64`) on every
numeric field; round-trip and injectivity hold for values that
satisfy the predicate.

This module is **not** part of the trusted computing base.  Bugs
here produce wrong serialisations (caught by the per-type round-trip
proofs at build time) but cannot violate any kernel invariant.
-/

import LegalKernel.Disputes.Types
import LegalKernel.Encoding.Encodable

namespace LegalKernel
namespace Encoding

open LegalKernel.Authority
open LegalKernel.Disputes

/-! ## DisputeClaim encoding

Five constructor-tag indices (0..4):

  | Tag | Constructor          | Fields                                     |
  |-----|----------------------|--------------------------------------------|
  | 0   | `preconditionFalse`  | `idx`                                      |
  | 1   | `signatureInvalid`   | `idx`                                      |
  | 2   | `nonceMismatch`      | `idx`                                      |
  | 3   | `oracleMisreported`  | `idx`, `evidence` (CBE bstr)               |
  | 4   | `doubleApply`        | `idx₁`, `idx₂`                             |
-/

/-- The canonical-encoding bound on every numeric field of a
    `DisputeClaim`.  All `LogIndex` fields are `Nat`, so the
    predicate captures the `< 2^64` bound that the CBE uint encoder
    requires for round-trip. -/
def DisputeClaim.fieldsBounded : DisputeClaim → Prop
  | .preconditionFalse idx       => idx < 256 ^ 8
  | .signatureInvalid idx        => idx < 256 ^ 8
  | .nonceMismatch idx           => idx < 256 ^ 8
  | .oracleMisreported idx ev    => idx < 256 ^ 8 ∧ ev.size < 256 ^ 8
  | .doubleApply idx₁ idx₂       => idx₁ < 256 ^ 8 ∧ idx₂ < 256 ^ 8

/-- Decidability of `DisputeClaim.fieldsBounded`. -/
instance DisputeClaim.decFieldsBounded (c : DisputeClaim) :
    Decidable (DisputeClaim.fieldsBounded c) := by
  cases c <;> unfold DisputeClaim.fieldsBounded <;> infer_instance

/-- Encode a `DisputeClaim` as constructor-tag + fields. -/
def DisputeClaim.encode : DisputeClaim → Stream
  | .preconditionFalse idx       =>
      Encodable.encode (T := Nat) 0 ++
      Encodable.encode (T := Nat) idx
  | .signatureInvalid idx        =>
      Encodable.encode (T := Nat) 1 ++
      Encodable.encode (T := Nat) idx
  | .nonceMismatch idx           =>
      Encodable.encode (T := Nat) 2 ++
      Encodable.encode (T := Nat) idx
  | .oracleMisreported idx ev    =>
      Encodable.encode (T := Nat) 3 ++
      Encodable.encode (T := Nat) idx ++
      Encodable.encode (T := ByteArray) ev
  | .doubleApply idx₁ idx₂       =>
      Encodable.encode (T := Nat) 4 ++
      Encodable.encode (T := Nat) idx₁ ++
      Encodable.encode (T := Nat) idx₂

/-- Decode a `DisputeClaim` from the front of `s`. -/
def DisputeClaim.decode (s : Stream) :
    Except DecodeError (DisputeClaim × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (0, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (idx, s₂) => .ok (.preconditionFalse idx, s₂)
    | .error e => .error e
  | .ok (1, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (idx, s₂) => .ok (.signatureInvalid idx, s₂)
    | .error e => .error e
  | .ok (2, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (idx, s₂) => .ok (.nonceMismatch idx, s₂)
    | .error e => .error e
  | .ok (3, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (idx, s₂) =>
      match Encodable.decode (T := ByteArray) s₂ with
      | .ok (ev, s₃) => .ok (.oracleMisreported idx ev, s₃)
      | .error e => .error e
    | .error e => .error e
  | .ok (4, s₁) =>
    match Encodable.decode (T := Nat) s₁ with
    | .ok (idx₁, s₂) =>
      match Encodable.decode (T := Nat) s₂ with
      | .ok (idx₂, s₃) => .ok (.doubleApply idx₁ idx₂, s₃)
      | .error e => .error e
    | .error e => .error e
  | .ok (other, _) => .error (.invalidConstructorIndex other)
  | .error e => .error e

instance instEncodableDisputeClaim : Encodable DisputeClaim where
  encode := DisputeClaim.encode
  decode := DisputeClaim.decode

/-- Round-trip with suffix for `DisputeClaim`, conditional on
    `fieldsBounded`. -/
theorem disputeClaim_roundtrip (c : DisputeClaim) (rest : Stream)
    (h : DisputeClaim.fieldsBounded c) :
    Encodable.decode (T := DisputeClaim) (Encodable.encode c ++ rest) = .ok (c, rest) := by
  cases c with
  | preconditionFalse idx =>
    show DisputeClaim.decode (DisputeClaim.encode (.preconditionFalse idx) ++ rest) = .ok _
    unfold DisputeClaim.encode DisputeClaim.decode
    rw [show
      Encodable.encode (T := Nat) 0 ++ Encodable.encode (T := Nat) idx ++ rest =
      Encodable.encode (T := Nat) 0 ++ (Encodable.encode (T := Nat) idx ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 0 _ (by decide)]
    dsimp only
    rw [nat_roundtrip idx rest h]
  | signatureInvalid idx =>
    show DisputeClaim.decode (DisputeClaim.encode (.signatureInvalid idx) ++ rest) = .ok _
    unfold DisputeClaim.encode DisputeClaim.decode
    rw [show
      Encodable.encode (T := Nat) 1 ++ Encodable.encode (T := Nat) idx ++ rest =
      Encodable.encode (T := Nat) 1 ++ (Encodable.encode (T := Nat) idx ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 1 _ (by decide)]
    dsimp only
    rw [nat_roundtrip idx rest h]
  | nonceMismatch idx =>
    show DisputeClaim.decode (DisputeClaim.encode (.nonceMismatch idx) ++ rest) = .ok _
    unfold DisputeClaim.encode DisputeClaim.decode
    rw [show
      Encodable.encode (T := Nat) 2 ++ Encodable.encode (T := Nat) idx ++ rest =
      Encodable.encode (T := Nat) 2 ++ (Encodable.encode (T := Nat) idx ++ rest)
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 2 _ (by decide)]
    dsimp only
    rw [nat_roundtrip idx rest h]
  | oracleMisreported idx ev =>
    obtain ⟨h1, h2⟩ := h
    show DisputeClaim.decode (DisputeClaim.encode (.oracleMisreported idx ev) ++ rest) = .ok _
    unfold DisputeClaim.encode DisputeClaim.decode
    rw [show
      Encodable.encode (T := Nat) 3 ++ Encodable.encode (T := Nat) idx ++
        Encodable.encode (T := ByteArray) ev ++ rest =
      Encodable.encode (T := Nat) 3 ++ (Encodable.encode (T := Nat) idx ++
        (Encodable.encode (T := ByteArray) ev ++ rest))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 3 _ (by decide)]
    dsimp only
    rw [nat_roundtrip idx _ h1]
    dsimp only
    rw [byteArray_roundtrip ev rest h2]
  | doubleApply idx₁ idx₂ =>
    obtain ⟨h1, h2⟩ := h
    show DisputeClaim.decode (DisputeClaim.encode (.doubleApply idx₁ idx₂) ++ rest) = .ok _
    unfold DisputeClaim.encode DisputeClaim.decode
    rw [show
      Encodable.encode (T := Nat) 4 ++ Encodable.encode (T := Nat) idx₁ ++
        Encodable.encode (T := Nat) idx₂ ++ rest =
      Encodable.encode (T := Nat) 4 ++ (Encodable.encode (T := Nat) idx₁ ++
        (Encodable.encode (T := Nat) idx₂ ++ rest))
        from by simp [List.append_assoc]]
    rw [nat_roundtrip 4 _ (by decide)]
    dsimp only
    rw [nat_roundtrip idx₁ _ h1]
    dsimp only
    rw [nat_roundtrip idx₂ rest h2]

/-- Empty-suffix round-trip for `DisputeClaim`. -/
theorem disputeClaim_roundtrip_empty (c : DisputeClaim)
    (h : DisputeClaim.fieldsBounded c) :
    Encodable.decode (T := DisputeClaim) (Encodable.encode c) = .ok (c, []) := by
  have := disputeClaim_roundtrip c [] h
  simpa using this

/-- `DisputeClaim` injectivity (bounded). -/
theorem disputeClaim_encode_injective (c₁ c₂ : DisputeClaim)
    (h₁ : DisputeClaim.fieldsBounded c₁) (h₂ : DisputeClaim.fieldsBounded c₂)
    (h : Encodable.encode (T := DisputeClaim) c₁ =
         Encodable.encode (T := DisputeClaim) c₂) :
    c₁ = c₂ := by
  have r₁ := disputeClaim_roundtrip_empty c₁ h₁
  have r₂ := disputeClaim_roundtrip_empty c₂ h₂
  rw [h] at r₁
  have heq : (Except.ok (c₁, ([] : Stream)) : Except DecodeError (DisputeClaim × Stream))
           = Except.ok (c₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ## EvidenceVerdict encoding

Three constructor-tag indices (0..2): `upheld` / `rejected` /
`inconclusive`.  Trivially-bounded (no numeric fields). -/

/-- Encode an `EvidenceVerdict` as a 9-byte CBE uint head. -/
def EvidenceVerdict.encode : EvidenceVerdict → Stream
  | .upheld       => Encodable.encode (T := Nat) 0
  | .rejected     => Encodable.encode (T := Nat) 1
  | .inconclusive => Encodable.encode (T := Nat) 2

/-- Decode an `EvidenceVerdict` from the front of `s`. -/
def EvidenceVerdict.decode (s : Stream) :
    Except DecodeError (EvidenceVerdict × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (0, rest) => .ok (.upheld, rest)
  | .ok (1, rest) => .ok (.rejected, rest)
  | .ok (2, rest) => .ok (.inconclusive, rest)
  | .ok (other, _) => .error (.invalidConstructorIndex other)
  | .error e => .error e

instance instEncodableEvidenceVerdict : Encodable EvidenceVerdict where
  encode := EvidenceVerdict.encode
  decode := EvidenceVerdict.decode

/-- Round-trip (unconditional) for `EvidenceVerdict`. -/
theorem evidenceVerdict_roundtrip (v : EvidenceVerdict) (rest : Stream) :
    Encodable.decode (T := EvidenceVerdict) (Encodable.encode v ++ rest) = .ok (v, rest) := by
  cases v with
  | upheld =>
    show EvidenceVerdict.decode (EvidenceVerdict.encode .upheld ++ rest) = .ok _
    unfold EvidenceVerdict.encode EvidenceVerdict.decode
    rw [nat_roundtrip 0 _ (by decide)]
  | rejected =>
    show EvidenceVerdict.decode (EvidenceVerdict.encode .rejected ++ rest) = .ok _
    unfold EvidenceVerdict.encode EvidenceVerdict.decode
    rw [nat_roundtrip 1 _ (by decide)]
  | inconclusive =>
    show EvidenceVerdict.decode (EvidenceVerdict.encode .inconclusive ++ rest) = .ok _
    unfold EvidenceVerdict.encode EvidenceVerdict.decode
    rw [nat_roundtrip 2 _ (by decide)]

/-- Empty-suffix round-trip for `EvidenceVerdict`. -/
theorem evidenceVerdict_roundtrip_empty (v : EvidenceVerdict) :
    Encodable.decode (T := EvidenceVerdict) (Encodable.encode v) = .ok (v, []) := by
  have := evidenceVerdict_roundtrip v []
  simpa using this

/-- `EvidenceVerdict` injectivity (unconditional). -/
theorem evidenceVerdict_encode_injective :
    Function.Injective (Encodable.encode : EvidenceVerdict → Stream) := by
  intro v₁ v₂ h
  have r₁ := evidenceVerdict_roundtrip_empty v₁
  have r₂ := evidenceVerdict_roundtrip_empty v₂
  rw [h] at r₁
  have heq : (Except.ok (v₁, ([] : Stream)) : Except DecodeError (EvidenceVerdict × Stream))
           = Except.ok (v₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ## Dispute encoding

Field order: `[challenger, claim, evidence, nonce, sig]`.

`Dispute.fieldsBounded` requires every numeric / byte field to fit
within CBE's `< 2^64` canonical-encoding window. -/

/-- The canonical-encoding bound on every numeric / byte field of a
    `Dispute`. -/
def Dispute.fieldsBounded (d : Dispute) : Prop :=
  d.challenger.toNat < 256 ^ 8 ∧
  DisputeClaim.fieldsBounded d.claim ∧
  d.evidence.size < 256 ^ 8 ∧
  d.nonce < 256 ^ 8 ∧
  d.sig.size < 256 ^ 8

/-- Decidability of `Dispute.fieldsBounded`. -/
instance Dispute.decFieldsBounded (d : Dispute) :
    Decidable (Dispute.fieldsBounded d) := by
  unfold Dispute.fieldsBounded
  exact inferInstance

/-- Encode a `Dispute` as `[challenger ++ claim ++ evidence ++ nonce ++ sig]`. -/
def Dispute.encode (d : Dispute) : Stream :=
  Encodable.encode (T := Nat) d.challenger.toNat ++
  Encodable.encode (T := DisputeClaim) d.claim ++
  Encodable.encode (T := ByteArray) d.evidence ++
  Encodable.encode (T := Nat) d.nonce ++
  Encodable.encode (T := ByteArray) d.sig

/-- Decode a `Dispute` from the front of `s`. -/
def Dispute.decode (s : Stream) : Except DecodeError (Dispute × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (challengerNat, s₁) =>
    if hch : challengerNat < 18446744073709551616 then
      let challenger := challengerNat.toUInt64
      let _ := hch
      match Encodable.decode (T := DisputeClaim) s₁ with
      | .ok (claim, s₂) =>
        match Encodable.decode (T := ByteArray) s₂ with
        | .ok (evidence, s₃) =>
          match Encodable.decode (T := Nat) s₃ with
          | .ok (nonce, s₄) =>
            match Encodable.decode (T := ByteArray) s₄ with
            | .ok (sig, s₅) => .ok ({ challenger, claim, evidence, nonce, sig }, s₅)
            | .error e => .error e
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    else
      .error (.invalidLength s!"Dispute challenger {challengerNat} exceeds 2^64")
  | .error e => .error e

instance instEncodableDispute : Encodable Dispute where
  encode := Dispute.encode
  decode := Dispute.decode

/-- Round-trip with suffix for `Dispute`, conditional on
    `fieldsBounded`. -/
theorem dispute_roundtrip (d : Dispute) (rest : Stream)
    (h : Dispute.fieldsBounded d) :
    Encodable.decode (T := Dispute) (Encodable.encode d ++ rest) = .ok (d, rest) := by
  obtain ⟨hCh, hClaim, hEv, hN, hSig⟩ := h
  show Dispute.decode (Dispute.encode d ++ rest) = .ok (d, rest)
  unfold Dispute.encode Dispute.decode
  rw [show
    Encodable.encode (T := Nat) d.challenger.toNat ++
      Encodable.encode (T := DisputeClaim) d.claim ++
      Encodable.encode (T := ByteArray) d.evidence ++
      Encodable.encode (T := Nat) d.nonce ++
      Encodable.encode (T := ByteArray) d.sig ++ rest =
    Encodable.encode (T := Nat) d.challenger.toNat ++
      (Encodable.encode (T := DisputeClaim) d.claim ++
        (Encodable.encode (T := ByteArray) d.evidence ++
          (Encodable.encode (T := Nat) d.nonce ++
            (Encodable.encode (T := ByteArray) d.sig ++ rest))))
      from by simp [List.append_assoc]]
  rw [nat_roundtrip d.challenger.toNat _ hCh]
  dsimp only
  have hch64 : d.challenger.toNat < 18446744073709551616 := by
    have h2 : (2 : Nat) ^ 64 = 18446744073709551616 := by decide
    have : d.challenger.toNat < 2 ^ 64 := UInt64.toNat_lt d.challenger
    omega
  rw [dif_pos hch64]
  rw [show (Encodable.decode (T := DisputeClaim)
        (Encodable.encode (T := DisputeClaim) d.claim ++ _))
    = .ok (d.claim, _) from disputeClaim_roundtrip d.claim _ hClaim]
  dsimp only
  rw [byteArray_roundtrip d.evidence _ hEv]
  dsimp only
  rw [nat_roundtrip d.nonce _ hN]
  dsimp only
  rw [byteArray_roundtrip d.sig rest hSig]
  -- Reduce: the decoded record fields equal `d`'s fields, so the result is `d`.
  show Except.ok ({ challenger := UInt64.ofNat d.challenger.toNat
                  , claim := d.claim, evidence := d.evidence, nonce := d.nonce
                  , sig := d.sig }, rest) = .ok (d, rest)
  congr 1
  congr 1
  show ({ challenger := UInt64.ofNat d.challenger.toNat
        , claim := d.claim, evidence := d.evidence, nonce := d.nonce
        , sig := d.sig } : Dispute) = d
  cases d
  congr 1
  exact UInt64.ofNat_toNat

/-- Empty-suffix round-trip for `Dispute`. -/
theorem dispute_roundtrip_empty (d : Dispute) (h : Dispute.fieldsBounded d) :
    Encodable.decode (T := Dispute) (Encodable.encode d) = .ok (d, []) := by
  have := dispute_roundtrip d [] h
  simpa using this

/-- `Dispute` injectivity (bounded). -/
theorem dispute_encode_injective (d₁ d₂ : Dispute)
    (h₁ : Dispute.fieldsBounded d₁) (h₂ : Dispute.fieldsBounded d₂)
    (h : Encodable.encode (T := Dispute) d₁ = Encodable.encode (T := Dispute) d₂) :
    d₁ = d₂ := by
  have r₁ := dispute_roundtrip_empty d₁ h₁
  have r₂ := dispute_roundtrip_empty d₂ h₂
  rw [h] at r₁
  have heq : (Except.ok (d₁, ([] : Stream)) : Except DecodeError (Dispute × Stream))
           = Except.ok (d₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

/-! ## Verdict encoding

Field order: `[disputeId, outcome, rationale, signers (List), sigs (List)]`.

`signers` and `sigs` are CBE-encoded as `List ActorId` and `List
Signature` respectively.  Both are encoded via the parameterised
`encodeList` helper from `Encoding/Encodable.lean`. -/

/-- The canonical-encoding bound on every numeric / list / byte field
    of a `Verdict`.  All `ActorId` (= `UInt64`) fields are
    automatically `< 2^64` (so no per-element actor-id check is
    needed); the per-signature `< 2^64` size bound is materialised
    via `List.all` for `Decidable` synthesis. -/
def Verdict.fieldsBounded (v : Verdict) : Prop :=
  v.disputeId < 256 ^ 8 ∧
  v.rationale.size < 256 ^ 8 ∧
  v.signers.length < 256 ^ 8 ∧
  v.sigs.length < 256 ^ 8 ∧
  v.sigs.all (fun s => decide (s.size < 256 ^ 8)) = true

/-- Decidability of `Verdict.fieldsBounded`. -/
instance Verdict.decFieldsBounded (v : Verdict) :
    Decidable (Verdict.fieldsBounded v) := by
  unfold Verdict.fieldsBounded
  exact inferInstance

/-! Note on `signers`-as-`List ActorId` encoding.  `ActorId =
UInt64`, which has an `Encodable` instance via the `Nat`-headed
codec.  We use the standard `Encodable (List α)` instance to encode
the `signers` and `sigs` lists. -/

/-- Encode a `Verdict` as `[disputeId ++ outcome ++ rationale ++ signers ++ sigs]`. -/
def Verdict.encode (v : Verdict) : Stream :=
  Encodable.encode (T := Nat) v.disputeId ++
  Encodable.encode (T := EvidenceVerdict) v.outcome ++
  Encodable.encode (T := ByteArray) v.rationale ++
  Encodable.encode (T := List ActorId) v.signers ++
  Encodable.encode (T := List Signature) v.sigs

/-- Decode a `Verdict` from the front of `s`. -/
def Verdict.decode (s : Stream) : Except DecodeError (Verdict × Stream) :=
  match Encodable.decode (T := Nat) s with
  | .ok (disputeId, s₁) =>
    match Encodable.decode (T := EvidenceVerdict) s₁ with
    | .ok (outcome, s₂) =>
      match Encodable.decode (T := ByteArray) s₂ with
      | .ok (rationale, s₃) =>
        match Encodable.decode (T := List ActorId) s₃ with
        | .ok (signers, s₄) =>
          match Encodable.decode (T := List Signature) s₄ with
          | .ok (sigs, s₅) => .ok ({ disputeId, outcome, rationale, signers, sigs }, s₅)
          | .error e => .error e
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .error e => .error e

instance instEncodableVerdict : Encodable Verdict where
  encode := Verdict.encode
  decode := Verdict.decode

/-- Determinism: equal inputs produce equal verdict encodings.  The
    structural form (encode is a function); useful for downstream
    hashing arguments. -/
theorem verdict_encode_deterministic (v₁ v₂ : Verdict) (h : v₁ = v₂) :
    Encodable.encode (T := Verdict) v₁ = Encodable.encode (T := Verdict) v₂ :=
  h ▸ rfl

/-- Determinism for `Dispute` encoding. -/
theorem dispute_encode_deterministic (d₁ d₂ : Dispute) (h : d₁ = d₂) :
    Encodable.encode (T := Dispute) d₁ = Encodable.encode (T := Dispute) d₂ :=
  h ▸ rfl

/-! ## Round-trip lemmas for Verdict's list components

The `Verdict` round-trip composes two list round-trips.  Both go
through the `list_roundtrip{,_bounded}` family from
`Encoding/Encodable.lean`. -/

/-- Per-element round-trip for `ActorId = UInt64`: every UInt64
    encoded then decoded recovers itself.  Unconditional. -/
theorem actorId_elem_roundtrip : ElemRoundtrip ActorId :=
  fun a rest => uInt64_roundtrip a rest

/-- Per-element-bounded round-trip for a list of `Signature`s
    whose every element has `size < 2^64`.  The hypothesis is
    membership-conditional: only signatures *in* `xs` need to
    round-trip. -/
theorem signature_elem_roundtripIn (xs : List Signature)
    (h_all : xs.all (fun s => decide (s.size < 256 ^ 8)) = true) :
    ElemRoundtripIn xs := by
  intro x hx rest
  -- From `xs.all (fun s => decide (s.size < 2^64)) = true` and `x ∈ xs`,
  -- derive `x.size < 2^64` and apply byteArray_roundtrip.
  have h_each : ∀ y ∈ xs, decide (y.size < 256 ^ 8) = true := by
    intro y hy
    exact (List.all_eq_true.mp h_all) y hy
  have hx_size : x.size < 256 ^ 8 := of_decide_eq_true (h_each x hx)
  exact byteArray_roundtrip x rest hx_size

/-- `Verdict` round-trip with suffix, conditional on
    `fieldsBounded`. -/
theorem verdict_roundtrip (v : Verdict) (rest : Stream)
    (h : Verdict.fieldsBounded v) :
    Encodable.decode (T := Verdict) (Encodable.encode v ++ rest) = .ok (v, rest) := by
  obtain ⟨hId, hRat, hSL, hSGL, hSigAll⟩ := h
  show Verdict.decode (Verdict.encode v ++ rest) = .ok (v, rest)
  unfold Verdict.encode Verdict.decode
  rw [show
    Encodable.encode (T := Nat) v.disputeId ++
      Encodable.encode (T := EvidenceVerdict) v.outcome ++
      Encodable.encode (T := ByteArray) v.rationale ++
      Encodable.encode (T := List ActorId) v.signers ++
      Encodable.encode (T := List Signature) v.sigs ++ rest =
    Encodable.encode (T := Nat) v.disputeId ++
      (Encodable.encode (T := EvidenceVerdict) v.outcome ++
        (Encodable.encode (T := ByteArray) v.rationale ++
          (Encodable.encode (T := List ActorId) v.signers ++
            (Encodable.encode (T := List Signature) v.sigs ++ rest))))
      from by simp [List.append_assoc]]
  rw [nat_roundtrip v.disputeId _ hId]
  dsimp only
  rw [evidenceVerdict_roundtrip v.outcome _]
  dsimp only
  rw [byteArray_roundtrip v.rationale _ hRat]
  dsimp only
  rw [list_roundtrip actorId_elem_roundtrip v.signers _ hSL]
  dsimp only
  rw [list_roundtrip_bounded v.sigs (signature_elem_roundtripIn v.sigs hSigAll) rest hSGL]

/-- Empty-suffix round-trip for `Verdict`. -/
theorem verdict_roundtrip_empty (v : Verdict) (h : Verdict.fieldsBounded v) :
    Encodable.decode (T := Verdict) (Encodable.encode v) = .ok (v, []) := by
  have := verdict_roundtrip v [] h
  simpa using this

/-- `Verdict` injectivity (bounded). -/
theorem verdict_encode_injective (v₁ v₂ : Verdict)
    (h₁ : Verdict.fieldsBounded v₁) (h₂ : Verdict.fieldsBounded v₂)
    (h : Encodable.encode (T := Verdict) v₁ = Encodable.encode (T := Verdict) v₂) :
    v₁ = v₂ := by
  have r₁ := verdict_roundtrip_empty v₁ h₁
  have r₂ := verdict_roundtrip_empty v₂ h₂
  rw [h] at r₁
  have heq : (Except.ok (v₁, ([] : Stream)) : Except DecodeError (Verdict × Stream))
           = Except.ok (v₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

end Encoding
end LegalKernel
