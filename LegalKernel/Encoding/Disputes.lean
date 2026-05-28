/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
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
    of a `Verdict`.  Audit-3.5 shape: `signatures` is a single list
    of `(ActorId × Signature)` pairs.  The encoder splits the list
    into `signatures.unzip` (a parallel `List ActorId` and `List
    Signature`) for the wire format; the bounds below cover that
    split form. -/
def Verdict.fieldsBounded (v : Verdict) : Prop :=
  v.disputeId < 256 ^ 8 ∧
  v.rationale.size < 256 ^ 8 ∧
  v.signatures.length < 256 ^ 8 ∧
  v.signatures.all (fun p => decide (p.snd.size < 256 ^ 8)) = true

/-- Decidability of `Verdict.fieldsBounded`. -/
instance Verdict.decFieldsBounded (v : Verdict) :
    Decidable (Verdict.fieldsBounded v) := by
  unfold Verdict.fieldsBounded
  exact inferInstance

/-! ## Audit-3.5 wire format

`Verdict.encode` emits the parallel-list view of `signatures` (via
`List.unzip`), preserving the pre-Audit-3.5 wire format byte-for-
byte.  `Verdict.decode` reads back the two lists, **enforces the
canonicality predicate** (strict-ascending key order), and zips
them back into a single signatures list.  Round-trip is provable
unconditionally on canonical verdicts via `List.zip_unzip`. -/

/-- Encode a `Verdict` as the concatenation of its CBE-encoded
    fields.  Audit-3.5: `signatures` is unzipped into a parallel
    `(signers, sigs)` view to preserve the pre-Audit-3.5 wire
    format; the decoder enforces canonicality on the input bytes. -/
def Verdict.encode (v : Verdict) : Stream :=
  Encodable.encode (T := Nat) v.disputeId ++
  Encodable.encode (T := EvidenceVerdict) v.outcome ++
  Encodable.encode (T := ByteArray) v.rationale ++
  Encodable.encode (T := List ActorId) v.signatures.unzip.1 ++
  Encodable.encode (T := List Signature) v.signatures.unzip.2

/-- Audit-3.5: decoder-side canonicality check on the decoded
    signers list.  Returns `true` iff the list is strictly
    ascending (no duplicates, sorted by `<`).  Decoders that fail
    this check return `nonCanonical` rather than constructing a
    non-canonical `Verdict`. -/
def actorsStrictlyAscending : List ActorId → Bool
  | []          => true
  | _ :: []     => true
  | x :: y :: r => decide (x < y) && actorsStrictlyAscending (y :: r)

/-- Decode a `Verdict` from the front of `s`.  Audit-3.5: enforces
    canonicality on the decoded signers list (strict-ascending) and
    rejects unsorted / duplicate-key inputs as `nonCanonical`.

    AR.16 / m-17 amendment.  Adds an explicit length-match check
    on `signers` vs. `sigs` before invoking `List.zip`.  Pre-AR,
    mismatched-length inputs silently truncated via `List.zip` to
    the shorter list; downstream consumers saw a shorter
    `signatures` list than the wire bytes implied, with no
    diagnostic.  Post-AR the decoder returns
    `.nonCanonical "verdict signers/signatures length mismatch"`
    on mismatch, surfacing the framing error to the caller. -/
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
          | .ok (sigs, s₅) =>
            -- AR.16 / m-17: explicit length-match check before zip.
            -- Mismatched lengths surface as a `.nonCanonical` error
            -- rather than being silently truncated by `List.zip`.
            if signers.length ≠ sigs.length then
              .error
                (.nonCanonical "verdict signers/signatures length mismatch")
            -- Audit-3.5 canonicality: signers must be strictly
            -- ascending (which implies no duplicate keys).
            else if !actorsStrictlyAscending signers then
              .error
                (.nonCanonical "verdict signers list not strictly ascending")
            else
              .ok ({ disputeId, outcome, rationale,
                     signatures := List.zip signers sigs }, s₅)
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

The `Verdict` round-trip composes:
  * Two list round-trips for the unzipped signers and sigs lists
    (via `list_roundtrip{,_bounded}` from `Encoding/Encodable.lean`).
  * `actorsStrictlyAscending` evaluates to `true` on the encoded
    signers list, since `Verdict.canonical v` requires the
    `signatures` list (and hence `unzip.1`) to be strictly ascending
    by ActorId.
  * `List.zip_unzip` recovers the original `signatures` list from
    the unzipped pair. -/

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
  have h_each : ∀ y ∈ xs, decide (y.size < 256 ^ 8) = true := by
    intro y hy
    exact (List.all_eq_true.mp h_all) y hy
  have hx_size : x.size < 256 ^ 8 := of_decide_eq_true (h_each x hx)
  exact byteArray_roundtrip x rest hx_size

/-- Audit-3.5 helper: `actorsStrictlyAscending` returns `true` on
    `(unzip).1` of any strictly-pairwise-less signatures list.

    The proof inducts on the signatures list using `Pairwise.cons`'s
    pattern decomposition (head-vs-rest separator) and recurses on
    the tail. -/
theorem actorsStrictlyAscending_of_canonical
    (sigs : List (ActorId × Signature))
    (h : sigs.Pairwise (fun p q => p.fst < q.fst)) :
    actorsStrictlyAscending sigs.unzip.1 = true := by
  induction sigs with
  | nil => rfl
  | cons p rest ih =>
    -- Decompose the `Pairwise` witness into head (∀ q ∈ rest, p.fst < q.fst)
    -- and tail (rest is itself pairwise).
    cases h with
    | cons h_head h_tail =>
    -- Recurse on the tail.
    have ih_tail := ih h_tail
    -- Case-split on rest to expose the `actorsStrictlyAscending` recursion.
    cases rest with
    | nil =>
      -- Singleton: vacuously true.
      simp [List.unzip, actorsStrictlyAscending]
    | cons q rest' =>
      -- Head-second pair: p, q.  Need p.fst < q.fst from h_head.
      have h_pq : p.fst < q.fst := h_head q (List.mem_cons_self)
      simp only [List.unzip_cons, actorsStrictlyAscending]
      simp only [Bool.and_eq_true, decide_eq_true_eq]
      refine ⟨h_pq, ?_⟩
      -- The recursive call's result is on `(q :: rest').unzip.1`,
      -- which is `q.fst :: rest'.unzip.1` after the cons unfold.
      have h_unzip_cons : (q :: rest').unzip.1 = q.fst :: rest'.unzip.1 := by
        simp [List.unzip_cons]
      rw [← h_unzip_cons]
      exact ih_tail

/-- `Verdict` round-trip with suffix, conditional on
    `fieldsBounded` AND `Verdict.canonical`.  Audit-3.5 strengthens
    the precondition with canonicality so the decoder's strict-
    ascending check passes; in exchange, the round-trip is provable
    via `List.zip_unzip` rather than requiring TreeMap-shape
    machinery. -/
theorem verdict_roundtrip (v : Verdict) (rest : Stream)
    (h : Verdict.fieldsBounded v) (hcan : Verdict.canonical v) :
    Encodable.decode (T := Verdict) (Encodable.encode v ++ rest) = .ok (v, rest) := by
  obtain ⟨hId, hRat, hLen, hSigAll⟩ := h
  show Verdict.decode (Verdict.encode v ++ rest) = .ok (v, rest)
  unfold Verdict.encode Verdict.decode
  -- Re-associate the concatenation so each step's `++ rest` is
  -- exposed as `_ ++ (rest_of_encode_v ++ rest)`.
  rw [show
    Encodable.encode (T := Nat) v.disputeId ++
      Encodable.encode (T := EvidenceVerdict) v.outcome ++
      Encodable.encode (T := ByteArray) v.rationale ++
      Encodable.encode (T := List ActorId) v.signatures.unzip.1 ++
      Encodable.encode (T := List Signature) v.signatures.unzip.2 ++ rest =
    Encodable.encode (T := Nat) v.disputeId ++
      (Encodable.encode (T := EvidenceVerdict) v.outcome ++
        (Encodable.encode (T := ByteArray) v.rationale ++
          (Encodable.encode (T := List ActorId) v.signatures.unzip.1 ++
            (Encodable.encode (T := List Signature) v.signatures.unzip.2 ++ rest))))
      from by simp [List.append_assoc]]
  -- Step through the field decoders one by one, using each round-trip lemma.
  rw [nat_roundtrip v.disputeId _ hId]
  dsimp only
  rw [evidenceVerdict_roundtrip v.outcome _]
  dsimp only
  rw [byteArray_roundtrip v.rationale _ hRat]
  dsimp only
  -- For the signers list: bound is on `signatures.length`, but
  -- `(unzip.1).length = (signatures.map Prod.fst).length =
  -- signatures.length` (via `List.unzip_fst` + `List.length_map`).
  have hSL : v.signatures.unzip.1.length < 256 ^ 8 := by
    rw [List.unzip_fst, List.length_map]
    exact hLen
  rw [list_roundtrip actorId_elem_roundtrip v.signatures.unzip.1 _ hSL]
  dsimp only
  -- For the sigs list: bound on `signatures.length`; the per-element
  -- bound `hSigAll` is on the pair list, but `unzip.2 = sigs.map snd`
  -- so each element of `unzip.2` is `p.snd` for some `p ∈ sigs`,
  -- which has the bound.
  have hSGL : v.signatures.unzip.2.length < 256 ^ 8 := by
    rw [List.unzip_snd, List.length_map]
    exact hLen
  have hSigsAll : v.signatures.unzip.2.all (fun s => decide (s.size < 256 ^ 8)) = true := by
    show v.signatures.unzip.2.all _ = true
    rw [List.all_eq_true]
    intro s hs
    -- s ∈ unzip.2 means ∃ a, (a, s) ∈ signatures (via map_snd).
    have hsList : s ∈ v.signatures.map Prod.snd := by
      have : v.signatures.unzip.2 = v.signatures.map Prod.snd :=
        List.unzip_snd
      rw [this] at hs
      exact hs
    obtain ⟨p, hp_mem, hp_eq⟩ := List.mem_map.mp hsList
    have h_each : ∀ q ∈ v.signatures, decide (q.snd.size < 256 ^ 8) = true :=
      List.all_eq_true.mp hSigAll
    have h_p := h_each p hp_mem
    rw [hp_eq] at h_p
    exact h_p
  rw [list_roundtrip_bounded v.signatures.unzip.2
        (signature_elem_roundtripIn v.signatures.unzip.2 hSigsAll) rest hSGL]
  -- After all decode steps, the canonicality check passes (by
  -- `actorsStrictlyAscending_of_canonical hcan`); then `List.zip_unzip`
  -- recovers `v.signatures`.
  have h_can_bool := actorsStrictlyAscending_of_canonical v.signatures hcan
  -- Define the reconstructed verdict explicitly so we can talk about
  -- it without anonymous-constructor type-inference issues.
  let v_reconstructed : Verdict :=
    { disputeId  := v.disputeId
    , outcome    := v.outcome
    , rationale  := v.rationale
    , signatures := List.zip v.signatures.unzip.1 v.signatures.unzip.2 }
  -- The reconstructed verdict equals v: same fields modulo `zip_unzip`.
  have h_eq : v_reconstructed = v := by
    show ({ disputeId := v.disputeId, outcome := v.outcome,
            rationale := v.rationale,
            signatures := List.zip v.signatures.unzip.1 v.signatures.unzip.2 }
           : Verdict) = v
    cases v with
    | mk dId out rat sigs =>
      simp only
      have : List.zip sigs.unzip.1 sigs.unzip.2 = sigs := List.zip_unzip sigs
      rw [this]
  -- AR.16 / m-17: the new length-match check fires before the
  -- canonicality check.  `unzip.1.length = unzip.2.length` for any
  -- pair list (both reduce to the underlying list's length via
  -- `List.length_map` + `List.unzip_fst` / `_snd`), so the
  -- length-mismatch arm is dead under canonical inputs.
  have h_len_eq : v.signatures.unzip.1.length = v.signatures.unzip.2.length := by
    rw [List.unzip_fst, List.unzip_snd, List.length_map, List.length_map]
  have h_not_can : (!actorsStrictlyAscending v.signatures.unzip.1) = false := by
    rw [h_can_bool]; rfl
  -- Close the goal: under the canonicality + length-match witnesses,
  -- both `if` branches take their non-error arms and we reach
  -- `Except.ok (v_reconstructed, rest)`.
  show (if v.signatures.unzip.1.length ≠ v.signatures.unzip.2.length then
          Except.error
            (DecodeError.nonCanonical "verdict signers/signatures length mismatch")
        else if !actorsStrictlyAscending v.signatures.unzip.1 then
          Except.error
            (DecodeError.nonCanonical "verdict signers list not strictly ascending")
        else
          Except.ok (v_reconstructed, rest))
        = Except.ok (v, rest)
  -- Length-check: `unzip.1.length = unzip.2.length` so `≠` is `False`.
  rw [if_neg (fun h => h h_len_eq)]
  -- Canonicality check: the inner if has the form `if cond = true then …`
  -- because the elaborator desugars `if cond then` (with `cond : Bool`)
  -- via `decide_eq_true`.  Use the `h_not_can : cond = false` rewrite to
  -- force the else branch.
  rw [h_not_can]
  -- Now goal is `(if false = true then ... else Except.ok (v_reconstructed, rest)) = Except.ok (v, rest)`.
  show Except.ok (v_reconstructed, rest) = Except.ok (v, rest)
  rw [h_eq]

/-- Empty-suffix round-trip for `Verdict`. -/
theorem verdict_roundtrip_empty (v : Verdict)
    (h : Verdict.fieldsBounded v) (hcan : Verdict.canonical v) :
    Encodable.decode (T := Verdict) (Encodable.encode v) = .ok (v, []) := by
  have := verdict_roundtrip v [] h hcan
  simpa using this

/-- `Verdict` injectivity (bounded + canonical).  Audit-3.5: the
    canonicality precondition is required because non-canonical
    verdicts decode to `error .nonCanonical` rather than the
    original value, so injectivity at the encode level is only
    meaningful for canonical inputs. -/
theorem verdict_encode_injective (v₁ v₂ : Verdict)
    (h₁ : Verdict.fieldsBounded v₁) (h₂ : Verdict.fieldsBounded v₂)
    (hc₁ : Verdict.canonical v₁) (hc₂ : Verdict.canonical v₂)
    (h : Encodable.encode (T := Verdict) v₁ = Encodable.encode (T := Verdict) v₂) :
    v₁ = v₂ := by
  have r₁ := verdict_roundtrip_empty v₁ h₁ hc₁
  have r₂ := verdict_roundtrip_empty v₂ h₂ hc₂
  rw [h] at r₁
  have heq : (Except.ok (v₁, ([] : Stream)) : Except DecodeError (Verdict × Stream))
           = Except.ok (v₂, []) := r₁.symm.trans r₂
  exact (Prod.mk.injEq _ _ _ _).mp (Except.ok.inj heq) |>.1

end Encoding
end LegalKernel
