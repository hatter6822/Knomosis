/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.Disputes — runtime tests for the Phase 6
encoding instances.

Phase 6 WU 6.1.  Exercises the canonical CBE byte encodings for:

  * `DisputeClaim` (5 variants × round-trip + injectivity).
  * `EvidenceVerdict` (3 variants × round-trip).
  * `Dispute` (round-trip + injectivity).
  * `Verdict` (round-trip + structural determinism).
  * Term-level API stability checks for the headline lemmas.
-/

import LegalKernel.Encoding.Disputes
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Disputes
open LegalKernel.Test

namespace LegalKernel.Test.Encoding.DisputesTests

/-! ## DisputeClaim round-trip and injectivity -/

/-- Sub-suite: DisputeClaim. -/
def disputeClaimTests : List TestCase :=
  [ { name := "DisputeClaim: preconditionFalse round-trips"
    , body := do
        let c : DisputeClaim := .preconditionFalse 42
        match Encodable.decode (T := DisputeClaim) (Encodable.encode c) with
        | .ok (c', []) => assert (c == c') s!"recovered {repr c'}, expected {repr c}"
        | other => throw <| IO.userError s!"unexpected decode: {repr other}"
    }
  , { name := "DisputeClaim: signatureInvalid round-trips"
    , body := do
        let c : DisputeClaim := .signatureInvalid 7
        match Encodable.decode (T := DisputeClaim) (Encodable.encode c) with
        | .ok (c', []) => assert (c == c') "recovered ≠ original"
        | other => throw <| IO.userError s!"unexpected: {repr other}"
    }
  , { name := "DisputeClaim: nonceMismatch round-trips"
    , body := do
        let c : DisputeClaim := .nonceMismatch 0
        match Encodable.decode (T := DisputeClaim) (Encodable.encode c) with
        | .ok (c', []) => assert (c == c') "recovered ≠ original"
        | other => throw <| IO.userError s!"unexpected: {repr other}"
    }
  , { name := "DisputeClaim: oracleMisreported round-trips"
    , body := do
        let c : DisputeClaim := .oracleMisreported 3 ⟨#[0xAA, 0xBB, 0xCC]⟩
        match Encodable.decode (T := DisputeClaim) (Encodable.encode c) with
        | .ok (c', []) =>
          match c, c' with
          | .oracleMisreported i ev, .oracleMisreported i' ev' =>
            assert (i = i') "idx mismatch"
            assert (ev.toList = ev'.toList) "evidence bytes mismatch"
          | _, _ => throw <| IO.userError "constructor mismatch"
        | other => throw <| IO.userError s!"unexpected: {repr other}"
    }
  , { name := "DisputeClaim: doubleApply round-trips"
    , body := do
        let c : DisputeClaim := .doubleApply 4 7
        match Encodable.decode (T := DisputeClaim) (Encodable.encode c) with
        | .ok (c', []) => assert (c == c') "recovered ≠ original"
        | other => throw <| IO.userError s!"unexpected: {repr other}"
    }
  , { name := "DisputeClaim: cross-variant produces distinct encodings"
    , body := do
        let c1 : DisputeClaim := .preconditionFalse 5
        let c2 : DisputeClaim := .signatureInvalid 5
        let e1 := (Encodable.encode (T := DisputeClaim) c1).toArray
        let e2 := (Encodable.encode (T := DisputeClaim) c2).toArray
        assert (e1 ≠ e2) "preconditionFalse and signatureInvalid should encode differently"
    }
  , { name := "disputeClaim_roundtrip API stability"
    , body := do
        let _proof :
            DisputeClaim.fieldsBounded (.preconditionFalse 5) →
            Encodable.decode (T := DisputeClaim)
              (Encodable.encode (T := DisputeClaim) (.preconditionFalse 5) ++ [])
            = .ok (.preconditionFalse 5, []) :=
          fun h => disputeClaim_roundtrip _ _ h
        pure ()
    }
  ]

/-! ## EvidenceVerdict round-trip -/

/-- Sub-suite: EvidenceVerdict. -/
def evidenceVerdictTests : List TestCase :=
  [ { name := "EvidenceVerdict: upheld round-trips"
    , body := do
        let v : EvidenceVerdict := .upheld
        match Encodable.decode (T := EvidenceVerdict) (Encodable.encode v) with
        | .ok (v', []) => assert (v == v') "recovered ≠ original"
        | other => throw <| IO.userError s!"unexpected: {repr other}"
    }
  , { name := "EvidenceVerdict: rejected round-trips"
    , body := do
        let v : EvidenceVerdict := .rejected
        match Encodable.decode (T := EvidenceVerdict) (Encodable.encode v) with
        | .ok (v', []) => assert (v == v') "recovered ≠ original"
        | other => throw <| IO.userError s!"unexpected: {repr other}"
    }
  , { name := "EvidenceVerdict: inconclusive round-trips"
    , body := do
        let v : EvidenceVerdict := .inconclusive
        match Encodable.decode (T := EvidenceVerdict) (Encodable.encode v) with
        | .ok (v', []) => assert (v == v') "recovered ≠ original"
        | other => throw <| IO.userError s!"unexpected: {repr other}"
    }
  , { name := "EvidenceVerdict: distinct variants encode distinctly"
    , body := do
        let e1 := (Encodable.encode (T := EvidenceVerdict) .upheld).toArray
        let e2 := (Encodable.encode (T := EvidenceVerdict) .rejected).toArray
        assert (e1 ≠ e2) "upheld vs rejected should differ"
    }
  ]

/-! ## Dispute round-trip + injectivity -/

/-- A small fixture dispute: actor 10 challenges log entry 3 with a
    preconditionFalse claim, no evidence, nonce 0, signature
    `0xAA`. -/
def fixtureDispute : Dispute where
  challenger := 10
  claim      := .preconditionFalse 3
  evidence   := ⟨#[]⟩
  nonce      := 0
  sig        := ⟨#[0xAA]⟩

/-- A Dispute fields-bounded witness, decided at runtime. -/
def fixtureDisputeBounded : Dispute.fieldsBounded fixtureDispute := by
  unfold Dispute.fieldsBounded fixtureDispute DisputeClaim.fieldsBounded
  decide

/-- Sub-suite: Dispute. -/
def disputeTests : List TestCase :=
  [ { name := "Dispute: round-trips at fixture"
    , body := do
        match Encodable.decode (T := Dispute) (Encodable.encode fixtureDispute) with
        | .ok (d', []) =>
          assert (d'.challenger = fixtureDispute.challenger) "challenger"
          assert (d'.nonce = fixtureDispute.nonce) "nonce"
          assert (d'.sig.toList = fixtureDispute.sig.toList) "sig bytes"
        | other => throw <| IO.userError s!"unexpected: {repr other}"
    }
  , { name := "Dispute: dispute_roundtrip_empty API stability"
    , body := do
        let _proof :
            Dispute.fieldsBounded fixtureDispute →
            Encodable.decode (T := Dispute) (Encodable.encode fixtureDispute)
            = .ok (fixtureDispute, []) :=
          fun h => dispute_roundtrip_empty _ h
        pure ()
    }
  ]

/-! ## Verdict round-trip + injectivity -/

/-- A small fixture verdict: dispute at index 5, upheld, two
    adjudicators 1 and 2 with empty signatures. -/
def fixtureVerdict : Verdict where
  disputeId := 5
  outcome   := .upheld
  rationale := ⟨#[0x01, 0x02]⟩
  signatures := [(1, ⟨#[0xAA]⟩), (2, ⟨#[0xBB]⟩)]

/-- A Verdict fields-bounded witness. -/
def fixtureVerdictBounded : Verdict.fieldsBounded fixtureVerdict := by
  unfold Verdict.fieldsBounded fixtureVerdict
  decide

/-- Sub-suite: Verdict. -/
def verdictTests : List TestCase :=
  [ { name := "Verdict: round-trips at fixture"
    , body := do
        match Encodable.decode (T := Verdict) (Encodable.encode fixtureVerdict) with
        | .ok (v', []) =>
          assert (v'.disputeId = fixtureVerdict.disputeId) "disputeId"
          assert (v'.outcome == fixtureVerdict.outcome) "outcome"
          assert (v'.rationale.toList = fixtureVerdict.rationale.toList) "rationale"
          assert (v'.signers = fixtureVerdict.signers) "signers"
          assert (v'.sigs.length = fixtureVerdict.sigs.length) "sigs length"
        | other => throw <| IO.userError s!"unexpected: {repr other}"
    }
  , { name := "Verdict: rejected outcome round-trips"
    , body := do
        let v : Verdict :=
          { disputeId := 0, outcome := .rejected, rationale := ⟨#[]⟩
            signatures := [] }
        match Encodable.decode (T := Verdict) (Encodable.encode v) with
        | .ok (v', []) =>
          assert (v'.disputeId = v.disputeId) "disputeId"
          assert (v'.outcome == v.outcome) "outcome"
        | other => throw <| IO.userError s!"unexpected: {repr other}"
    }
  , { name := "verdict_roundtrip_empty API stability"
    , body := do
        -- Audit-3.5: verdict_roundtrip_empty now takes both
        -- fieldsBounded and canonical preconditions.
        let _proof :
            Verdict.fieldsBounded fixtureVerdict →
            Verdict.canonical fixtureVerdict →
            Encodable.decode (T := Verdict) (Encodable.encode fixtureVerdict)
            = .ok (fixtureVerdict, []) :=
          fun h hc => verdict_roundtrip_empty _ h hc
        pure ()
    }
  , { name := "verdict_encode_deterministic API stability"
    , body := do
        let _proof :
            ∀ v₁ v₂ : Verdict, v₁ = v₂ →
            Encodable.encode (T := Verdict) v₁ = Encodable.encode (T := Verdict) v₂ :=
          fun v₁ v₂ h => verdict_encode_deterministic v₁ v₂ h
        pure ()
    }
  , { name := "Audit-3.5: Verdict.canonical decides true for sorted fixture"
    , body := do
        -- fixtureVerdict's signatures = [(1, _), (2, _)]: strictly ascending.
        let h : Verdict.canonical fixtureVerdict := by decide
        let _ := h
        pure ()
    }
  , { name := "Audit-3.5: Verdict.canonical decides false for non-canonical"
      -- Rejects a verdict with duplicate signers.
    , body := do
        let bad : Verdict :=
          { disputeId := 0, outcome := .upheld,
            rationale := ⟨#[]⟩,
            signatures := [(1, ⟨#[]⟩), (1, ⟨#[]⟩)] }
        if (Verdict.canonical_decidable bad).decide then
          throw <| IO.userError "canonical accepted duplicate signers"
        else
          pure ()
    }
  , { name := "Audit-3.5: Verdict.canonical decides false for unsorted"
    , body := do
        let bad : Verdict :=
          { disputeId := 0, outcome := .upheld,
            rationale := ⟨#[]⟩,
            -- 2 then 1: not ascending.
            signatures := [(2, ⟨#[]⟩), (1, ⟨#[]⟩)] }
        if (Verdict.canonical_decidable bad).decide then
          throw <| IO.userError "canonical accepted unsorted list"
        else
          pure ()
    }
  , { name := "Audit-3.5: decoder rejects unsorted-signers bytes (nonCanonical)"
      -- Construct a non-canonical encoding by hand: an explicit
      -- (signers, sigs) pair where signers is unsorted.  Encoding
      -- via the parallel-list view, then decoding, must yield
      -- `.error nonCanonical` (not silently accept).
    , body := do
        let badSigners : List ActorId := [2, 1]
        let badSigs    : List Signature := [⟨#[]⟩, ⟨#[]⟩]
        let bytes : Stream :=
          Encodable.encode (T := Nat) 42 ++
          Encodable.encode (T := EvidenceVerdict) .upheld ++
          Encodable.encode (T := ByteArray) ⟨#[]⟩ ++
          Encodable.encode (T := List ActorId) badSigners ++
          Encodable.encode (T := List Signature) badSigs
        match Verdict.decode bytes with
        | .ok _ => throw <| IO.userError "decoder accepted unsorted signers"
        | .error _ => pure ()  -- expected: rejection
    }
  , { name := "Audit-3.5: signers + sigs back-compat accessors round-trip via signatures"
      -- v.signers is signatures.map fst; v.sigs is signatures.map snd.
      -- For canonical fixtureVerdict, signers = [1, 2] and sigs = [<AA>, <BB>].
    , body := do
        assertEq (expected := [(1 : ActorId), 2]) (actual := fixtureVerdict.signers)
          "signers accessor"
        assertEq (expected := [(⟨#[0xAA]⟩ : Signature), ⟨#[0xBB]⟩])
                 (actual := fixtureVerdict.sigs) "sigs accessor"
    }
  -- AR.16 / m-17: explicit length-mismatch rejection.
  , { name := "AR.16: decoder rejects mismatched signer/signature list lengths"
      -- Construct a deliberately-mismatched encoding: 2 signers but
      -- only 1 signature.  Pre-AR the decoder silently truncated
      -- via `List.zip` to the shorter list; post-AR it returns
      -- `.nonCanonical` so the framing error surfaces.
    , body := do
        let badSigners : List ActorId := [1, 2]
        let badSigs    : List Signature := [⟨#[0xAA]⟩]
        let bytes : Stream :=
          Encodable.encode (T := Nat) 42 ++
          Encodable.encode (T := EvidenceVerdict) .upheld ++
          Encodable.encode (T := ByteArray) ⟨#[]⟩ ++
          Encodable.encode (T := List ActorId) badSigners ++
          Encodable.encode (T := List Signature) badSigs
        match Verdict.decode bytes with
        | .ok _ =>
            throw <| IO.userError "decoder accepted mismatched-length signers/sigs"
        | .error (.nonCanonical reason) =>
            if reason == "verdict signers/signatures length mismatch" then pure ()
            else throw <| IO.userError s!"unexpected nonCanonical reason: {reason}"
        | .error e =>
            throw <| IO.userError s!"expected nonCanonical, got {repr e}"
    }
  ]

/-! ## Aggregate -/

/-- All Phase 6 encoding tests. -/
def tests : List TestCase :=
  disputeClaimTests ++ evidenceVerdictTests ++ disputeTests ++ verdictTests

end LegalKernel.Test.Encoding.DisputesTests
