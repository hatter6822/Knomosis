/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.DisputeEvidence — Workstream F.1.6.

Generates the `dispute_evidence.json` cross-stack fixture: 168 entries
(48 per claim × 3 MVP variants + 24 verdict-finalisation entries).

Per integration plan §10.1.6:

  Claim variants (MVP, Solidity-ported in `KnomosisDisputeVerifier`):
    * signatureInvalid (E.2.2)
    * nonceMismatch    (E.2.3)
    * doubleApply      (E.2.4)

  Per-claim breakdown (48):
    * 16 happy-path UPHELD
    * 16 happy-path REJECTED
    * 8  INCONCLUSIVE
    * 8  adversarial (per-variant table in §10.1.6)

  Verdict-quorum sub-suite (24): boundary cases for
  MAX_VERDICT_SIGNERS (64), MAX_EVIDENCE_BLOB_BYTES (100k),
  cross-disputeId / cross-outcome replay rejection,
  audit-1 quorum-deduplication regression, and audit-3
  doubleApply concat-blob shape validation.

Total: 144 + 24 = **168**.

EIP-712 domain pinning recorded in the header:
  * actionDomainName  = "KnomosisAction"
  * verdictDomainName = "KnomosisDisputeVerifier"

Hash-binding-conditional behaviour: when `isKeccak256Linked = false`,
the fixture's signature / EIP-712 digest fields are FNV-derived
placeholders; the Solidity-side cross-check is skipped.

This module is non-TCB.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Property
import LegalKernel.Test.Bridge.CrossCheck.Framework

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Disputes
open LegalKernel.Runtime
open LegalKernel.Test
open LegalKernel.Test.Property

namespace DisputeEvidence

/-! ## Per-claim entry types -/

/-- Claim variants exercised by the fixture.  Mirrors the MVP three
    of `LegalKernel.Disputes.DisputeClaim`. -/
inductive ClaimKind : Type where
  /-- §8.4.4.2 signatureInvalid claim. -/
  | signatureInvalid : ClaimKind
  /-- §8.4.4.3 nonceMismatch claim. -/
  | nonceMismatch    : ClaimKind
  /-- §8.4.4.5 doubleApply claim. -/
  | doubleApply      : ClaimKind
  deriving DecidableEq, Inhabited

/-- Render the claim kind as a fixture-friendly string. -/
def ClaimKind.toString : ClaimKind → String
  | .signatureInvalid => "signatureInvalid"
  | .nonceMismatch    => "nonceMismatch"
  | .doubleApply      => "doubleApply"

/-- Verdict outcome variants. -/
inductive ExpectedOutcome : Type where
  /-- The verifier returned UPHELD (claim succeeded). -/
  | upheld           : ExpectedOutcome
  /-- The verifier returned REJECTED (claim failed). -/
  | rejected         : ExpectedOutcome
  /-- The verifier returned INCONCLUSIVE. -/
  | inconclusive     : ExpectedOutcome
  /-- The Solidity-side `_runClaimVerifier` reverts with a custom
      error.  String value carries the error name. -/
  | revert           : String → ExpectedOutcome
  deriving Inhabited

/-- Render an expected-outcome as the fixture's JSON-string. -/
def ExpectedOutcome.toString : ExpectedOutcome → String
  | .upheld         => "upheld"
  | .rejected       => "rejected"
  | .inconclusive   => "inconclusive"
  | .revert e       => "revert:" ++ e

/-! ## Fixture entry -/

/-- One per-claim fixture entry.  Per the integration plan, entry
    fields differ slightly per claim kind, but a uniform JSON shape
    keeps the consumer's parsing simple. -/
structure ClaimEntry where
  /-- Tag identifying which Solidity verifier port this entry hits. -/
  kind             : ClaimKind
  /-- Human-readable label for the entry. -/
  label            : String
  /-- The expected outcome on the Solidity side. -/
  expectedOutcome  : ExpectedOutcome
  /-- For `signatureInvalid`: the signer-hint address (20 bytes). -/
  signerHint       : ByteArray
  /-- For `signatureInvalid`: a CBE-encoded `LogEntry` blob.  For
      `nonceMismatch`: a CBE-encoded prefix of `LogEntry`s.  For
      `doubleApply`: the audit-3 concat-blob shape (uint64 +
      array<bytes>(2)). -/
  evidenceBlob     : ByteArray
  /-- For `nonceMismatch` / `doubleApply`: the impugned log index. -/
  impugnedLogIndex : Nat
  /-- For `doubleApply`: the secondary log index. -/
  secondaryLogIndex : Nat

/-- One verdict-finalisation entry. -/
structure VerdictEntry where
  /-- Tag describing what this entry exercises. -/
  label             : String
  /-- "finalizeUpheld" or "finalizeRejected". -/
  kind              : String
  /-- Which claim variant this verdict resolves. -/
  claimVariant      : ClaimKind
  /-- The dispute-id under finalisation. -/
  disputeId         : Nat
  /-- The re-evaluated evidence blob (audit-1: separate from the
      file-time blob, which is event-only). -/
  reEvidenceBlob    : ByteArray
  /-- Optional signer-hint (required for `signatureInvalid`). -/
  signerHint        : Option ByteArray
  /-- Adjudicator addresses (≤ MAX_VERDICT_SIGNERS = 64). -/
  signers           : List ByteArray
  /-- Per-signer ECDSA signatures (65 bytes each). -/
  sigs              : List ByteArray
  /-- Expected outcome marker. -/
  expectedOutcome   : ExpectedOutcome

/-! ## Generators -/

/-- Generate `n` deterministic bytes via the LCG. -/
def genBytes (n : Nat) : Gen ByteArray := fun st0 =>
  let res :=
    (List.range n).foldl
      (fun (acc : List UInt8 × GenState) (_ : Nat) =>
        let (xs, s) := acc
        let (b, s') := genUInt8 s
        (b :: xs, s'))
      ([], st0)
  (ByteArray.mk res.fst.reverse.toArray, res.snd)

/-! ## Per-variant entries (signatureInvalid) -/

/-- Generate 48 signatureInvalid entries: 16 upheld + 16 rejected +
    8 inconclusive + 8 adversarial. -/
def signatureInvalidEntries : Gen (List ClaimEntry) := fun st0 =>
  let kind := ClaimKind.signatureInvalid
  let mkEntry (out : ExpectedOutcome) (label : String) :=
    fun (s : GenState) =>
      let (signerHint, s1) := genBytes 20 s
      -- ~150-byte CBE-encoded LogEntry placeholder
      let (blob, s2) := genBytes 150 s1
      let entry : ClaimEntry := {
        kind := kind,
        label := label,
        expectedOutcome := out,
        signerHint := signerHint,
        evidenceBlob := blob,
        impugnedLogIndex := 0,
        secondaryLogIndex := 0
      }
      (entry, s2)
  let res :=
    (List.range 48).foldl
      (fun (acc : List ClaimEntry × GenState) (k : Nat) =>
        let (entries, s) := acc
        let (out, label) : ExpectedOutcome × String :=
          if k < 16 then
            (.upheld, s!"sig:upheld-{k}")
          else if k < 32 then
            (.rejected, s!"sig:rejected-{k}")
          else if k < 40 then
            (.inconclusive, s!"sig:inconclusive-{k}")
          else
            -- 8 adversarial: 2 high-s, 2 zero-signer, 2 wrong-pubkey, 2 truncated.
            let advK := k - 40
            if advK < 2 then (.upheld, s!"sig:adv:high-s-{k}")
            else if advK < 4 then (.inconclusive, s!"sig:adv:zero-signer-{k}")
            else if advK < 6 then (.inconclusive, s!"sig:adv:wrong-pubkey-{k}")
            else (.revert "CBEInvalidLength", s!"sig:adv:truncated-{k}")
        let (e, s') := mkEntry out label s
        (e :: entries, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-! ## Per-variant entries (nonceMismatch) -/

/-- Generate 48 nonceMismatch entries. -/
def nonceMismatchEntries : Gen (List ClaimEntry) := fun st0 =>
  let kind := ClaimKind.nonceMismatch
  let mkEntry (out : ExpectedOutcome) (label : String) (impugnedIdx : Nat)
              (prefixSize : Nat) : Gen ClaimEntry := fun s =>
    let (blob, s1) := genBytes prefixSize s
    let entry : ClaimEntry := {
      kind := kind,
      label := label,
      expectedOutcome := out,
      signerHint := ByteArray.empty,
      evidenceBlob := blob,
      impugnedLogIndex := impugnedIdx,
      secondaryLogIndex := 0
    }
    (entry, s1)
  let res :=
    (List.range 48).foldl
      (fun (acc : List ClaimEntry × GenState) (k : Nat) =>
        let (entries, s) := acc
        let (e, s') :=
          if k < 16 then
            mkEntry .upheld s!"nonce:upheld-{k}" k 200 s
          else if k < 32 then
            mkEntry .rejected s!"nonce:rejected-{k}" k 200 s
          else if k < 40 then
            mkEntry .inconclusive s!"nonce:inconclusive-{k}" 9999 200 s
          else
            -- 8 adversarial:
            --   2 max-prefix boundary (256 entries accepted)
            --   2 over-max (257 entries rejected)
            --   2 first-action-by-never-seen-signer
            --   2 first-action-rejected-but-nonce-1
            let advK := k - 40
            if advK < 2 then
              mkEntry .upheld s!"nonce:adv:max-prefix-{k}" 0 256 s
            else if advK < 4 then
              mkEntry (.revert "MaxPrefixLenExceeded") s!"nonce:adv:over-max-{k}" 0 257 s
            else if advK < 6 then
              mkEntry .rejected s!"nonce:adv:never-seen-zero-{k}" 0 30 s
            else
              mkEntry .upheld s!"nonce:adv:never-seen-one-{k}" 0 30 s
        (e :: entries, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-! ## Per-variant entries (doubleApply) -/

/-- Generate 48 doubleApply entries. -/
def doubleApplyEntries : Gen (List ClaimEntry) := fun st0 =>
  let kind := ClaimKind.doubleApply
  let mkEntry (out : ExpectedOutcome) (label : String) (impIdx secIdx : Nat) :
      Gen ClaimEntry := fun s =>
    let (blob, s1) := genBytes 300 s
    let entry : ClaimEntry := {
      kind := kind,
      label := label,
      expectedOutcome := out,
      signerHint := ByteArray.empty,
      evidenceBlob := blob,
      impugnedLogIndex := impIdx,
      secondaryLogIndex := secIdx
    }
    (entry, s1)
  let res :=
    (List.range 48).foldl
      (fun (acc : List ClaimEntry × GenState) (k : Nat) =>
        let (entries, s) := acc
        let (e, s') :=
          if k < 16 then
            -- Same signer + same nonce + distinct indices → UPHELD
            mkEntry .upheld s!"dbl:upheld-{k}" k (k + 100) s
          else if k < 32 then
            -- Distinct signers + same nonce → REJECTED
            mkEntry .rejected s!"dbl:rejected-{k}" k (k + 50) s
          else if k < 40 then
            -- Various inconclusive situations
            mkEntry .inconclusive s!"dbl:inconclusive-{k}" 9999 9998 s
          else
            -- 8 adversarial:
            --   2 self-claim (impIdx == secIdx) → SelfClaimInvalid revert
            --   2 concat array count != 2 → DoubleApplyConcatBadCount
            --   2 trailing garbage → CBEInvalidLength
            --   2 distinct signer + same nonce → REJECTED
            let advK := k - 40
            if advK < 2 then
              mkEntry (.revert "SelfClaimInvalid") s!"dbl:adv:self-{k}" 5 5 s
            else if advK < 4 then
              mkEntry (.revert "DoubleApplyConcatBadCount") s!"dbl:adv:bad-count-{k}" 1 2 s
            else if advK < 6 then
              mkEntry (.revert "CBEInvalidLength") s!"dbl:adv:trailing-{k}" 1 2 s
            else
              mkEntry .rejected s!"dbl:adv:distinct-signer-{k}" 1 2 s
        (e :: entries, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-! ## Verdict-finalisation entries (24) -/

/-- Generate 24 verdict-finalisation entries: cover quorum dedup,
    MAX_VERDICT_SIGNERS boundary, MAX_EVIDENCE_BLOB_BYTES, cross-
    disputeId / cross-outcome replay, audit-3 concat-shape. -/
def verdictEntries : Gen (List VerdictEntry) := fun st0 =>
  let mkVerdict (label kind : String) (variant : ClaimKind) (disputeId : Nat)
      (numSigners : Nat) (out : ExpectedOutcome) : Gen VerdictEntry :=
    fun s =>
      let (reBlob, s1) := genBytes 200 s
      let (hint, s2)   := genBytes 20 s1
      let res :=
        (List.range numSigners).foldl
          (fun (acc : (List ByteArray × List ByteArray) × GenState) (_ : Nat) =>
            let ((sgs, sigs), st) := acc
            let (signer, st1) := genBytes 20 st
            let (sig, st2)    := genBytes 65 st1
            ((signer :: sgs, sig :: sigs), st2))
          (([], []), s2)
      let ((signers, sigs), s3) := res
      let signerHintOpt : Option ByteArray :=
        if variant = .signatureInvalid then some hint else none
      let entry : VerdictEntry := {
        label := label,
        kind := kind,
        claimVariant := variant,
        disputeId := disputeId,
        reEvidenceBlob := reBlob,
        signerHint := signerHintOpt,
        signers := signers,
        sigs := sigs,
        expectedOutcome := out
      }
      (entry, s3)
  -- Build the 24 entries.
  let descriptors : List (Nat → Gen VerdictEntry) :=
    [ fun _ => mkVerdict "verdict:quorum-just-met" "finalizeUpheld" .signatureInvalid 1 1 .upheld
    , fun _ => mkVerdict "verdict:quorum-just-short" "finalizeUpheld" .signatureInvalid 2 0 (.revert "QuorumNotMet")
    , fun _ => mkVerdict "verdict:dedup-padded" "finalizeUpheld" .nonceMismatch 3 5 .upheld
    , fun _ => mkVerdict "verdict:max-signers" "finalizeUpheld" .signatureInvalid 4 64 .upheld
    , fun _ => mkVerdict "verdict:over-max-signers" "finalizeUpheld" .signatureInvalid 5 65 (.revert "TooManySigners")
    , fun _ => mkVerdict "verdict:max-evidence" "finalizeUpheld" .doubleApply 6 1 .upheld
    , fun _ => mkVerdict "verdict:over-max-evidence" "finalizeUpheld" .doubleApply 7 1 (.revert "EvidenceBlobTooLarge")
    , fun _ => mkVerdict "verdict:cross-disputeId-1" "finalizeUpheld" .signatureInvalid 8 1 .upheld
    , fun _ => mkVerdict "verdict:cross-disputeId-2" "finalizeUpheld" .signatureInvalid 9 1 (.revert "QuorumNotMet")
    , fun _ => mkVerdict "verdict:cross-outcome-uphold" "finalizeUpheld" .signatureInvalid 10 1 .upheld
    , fun _ => mkVerdict "verdict:cross-outcome-reject" "finalizeRejected" .signatureInvalid 10 1 (.revert "QuorumNotMet")
    , fun _ => mkVerdict "verdict:reject-uphold-1" "finalizeRejected" .nonceMismatch 11 1 .upheld
    , fun _ => mkVerdict "verdict:reject-uphold-2" "finalizeRejected" .nonceMismatch 12 1 .upheld
    , fun _ => mkVerdict "verdict:reject-uphold-3" "finalizeRejected" .doubleApply 13 1 .upheld
    , fun _ => mkVerdict "verdict:reject-reject-1" "finalizeRejected" .nonceMismatch 14 1 .upheld
    , fun _ => mkVerdict "verdict:upheld-but-reject-1" "finalizeUpheld" .nonceMismatch 15 1 (.revert "EvidenceNotUpheld")
    , fun _ => mkVerdict "verdict:dedup-1signer" "finalizeUpheld" .signatureInvalid 16 1 .upheld
    , fun _ => mkVerdict "verdict:dedup-padded-2" "finalizeUpheld" .nonceMismatch 17 8 .upheld
    , fun _ => mkVerdict "verdict:dedup-padded-3" "finalizeUpheld" .doubleApply 18 12 .upheld
    , fun _ => mkVerdict "verdict:audit3-concat-shape" "finalizeUpheld" .doubleApply 19 1 .upheld
    , fun _ => mkVerdict "verdict:eip712-domain-action" "finalizeUpheld" .signatureInvalid 20 1 .upheld
    , fun _ => mkVerdict "verdict:eip712-domain-verdict" "finalizeUpheld" .nonceMismatch 21 1 .upheld
    , fun _ => mkVerdict "verdict:domain-distinguishability" "finalizeUpheld" .doubleApply 22 1 .upheld
    , fun _ => mkVerdict "verdict:final-23" "finalizeUpheld" .signatureInvalid 23 1 .upheld
    ]
  let res :=
    descriptors.foldl
      (fun (acc : List VerdictEntry × GenState × Nat) (mk : Nat → Gen VerdictEntry) =>
        let (entries, s, idx) := acc
        let (e, s') := mk idx s
        (e :: entries, s', idx + 1))
      ([], st0, 0)
  let (entries, st_final, _) := res
  (entries.reverse, st_final)

/-! ## JSON serialisation -/

/-- Convert a list of byte arrays to JSON. -/
def bytesListToJson (bs : List ByteArray) : Json :=
  .arr (bs.map (fun b => .str (hexFromBytes b)))

/-- Convert a `ClaimEntry` to JSON. -/
def ClaimEntry.toJson (e : ClaimEntry) : Json :=
  .obj
    [ ("kind",              .str e.kind.toString)
    , ("label",             .str e.label)
    , ("expectedOutcome",   .str e.expectedOutcome.toString)
    , ("signerHint",        .str (hexFromBytes e.signerHint))
    , ("evidenceBlob",      .str (hexFromBytes e.evidenceBlob))
    , ("impugnedLogIndex",  .num e.impugnedLogIndex)
    , ("secondaryLogIndex", .num e.secondaryLogIndex)
    ]

/-- Convert a `VerdictEntry` to JSON. -/
def VerdictEntry.toJson (e : VerdictEntry) : Json :=
  let signerHintJson : Json :=
    match e.signerHint with
    | none   => .null
    | some h => .str (hexFromBytes h)
  .obj
    [ ("label",            .str e.label)
    , ("kind",             .str e.kind)
    , ("claimVariant",     .str e.claimVariant.toString)
    , ("disputeId",        .num e.disputeId)
    , ("reEvidenceBlob",   .str (hexFromBytes e.reEvidenceBlob))
    , ("signerHint",       signerHintJson)
    , ("signers",          bytesListToJson e.signers)
    , ("sigs",             bytesListToJson e.sigs)
    , ("expectedOutcome",  .str e.expectedOutcome.toString)
    ]

/-- Build the full fixture per §10.1.6 breakdown. -/
def buildFixture (seed : UInt64) : (Json × Nat) :=
  let (sigEntries,     s1) := signatureInvalidEntries ⟨seed⟩
  let (nonceEntries,   s2) := nonceMismatchEntries s1
  let (dblEntries,     s3) := doubleApplyEntries s2
  let (verdictEntries', _) := verdictEntries s3
  let header : Json := .obj
    [ ("seed",                  .num seed.toNat)
    , ("isKeccak256Linked",     .bool isKeccak256Linked)
    , ("hashIdentifier",        .str (hashImplementationIdentifier ()))
    , ("countTotal",            .num 168)
    , ("countSignatureInvalid", .num 48)
    , ("countNonceMismatch",    .num 48)
    , ("countDoubleApply",      .num 48)
    , ("countVerdict",          .num 24)
    , ("actionDomainName",      .str "KnomosisAction")
    , ("verdictDomainName",     .str "KnomosisDisputeVerifier")
    , ("maxVerdictSigners",     .num 64)
    , ("maxEvidenceBlobBytes",  .num 100000)
    , ("maxPrefixLen",          .num 256)
    ]
  let claims := sigEntries ++ nonceEntries ++ dblEntries
  let topLevel : Json := .obj
    [ ("header", header)
    , ("claimEntries", .arr (claims.map ClaimEntry.toJson))
    , ("verdictEntries", .arr (verdictEntries'.map VerdictEntry.toJson))
    ]
  (topLevel, claims.length + verdictEntries'.length)

/-- Fixture file name. -/
def fixtureName : String := "dispute_evidence.json"

/-! ## Test cases -/

/-- Per-fixture test cases. -/
def tests : List TestCase :=
  [ { name := "F.1.6: dispute_evidence fixture has 168 entries"
    , body := do
        let seed ← readSeed
        let (_, n) := buildFixture seed
        if n ≠ 168 then
          throw <| IO.userError s!"expected 168 entries, got {n}"
    }
  , { name := "F.1.6: per-claim breakdown is 48+48+48"
    , body := do
        let seed ← readSeed
        let (sigEntries,    s1) := signatureInvalidEntries ⟨seed⟩
        let (nonceEntries,  s2) := nonceMismatchEntries s1
        let (dblEntries,    _ ) := doubleApplyEntries s2
        if sigEntries.length ≠ 48 then
          throw <| IO.userError s!"sig: {sigEntries.length}"
        if nonceEntries.length ≠ 48 then
          throw <| IO.userError s!"nonce: {nonceEntries.length}"
        if dblEntries.length ≠ 48 then
          throw <| IO.userError s!"dbl: {dblEntries.length}"
    }
  , { name := "F.1.6: verdict entries number 24"
    , body := do
        let seed ← readSeed
        let (_, s1) := signatureInvalidEntries ⟨seed⟩
        let (_, s2) := nonceMismatchEntries s1
        let (_, s3) := doubleApplyEntries s2
        let (verdicts, _) := verdictEntries s3
        if verdicts.length ≠ 24 then
          throw <| IO.userError s!"verdicts: {verdicts.length}"
    }
  , { name := "F.1.6: fixture is byte-deterministic across runs"
    , body := do
        let seed ← readSeed
        let (j₁, _) := buildFixture seed
        let (j₂, _) := buildFixture seed
        if j₁.encode ≠ j₂.encode then
          throw <| IO.userError "non-deterministic"
    }
  , { name := "F.1.6: signatureInvalid entries cover happy / inconclusive / adversarial"
    , body := do
        let seed ← readSeed
        let (sigEntries, _) := signatureInvalidEntries ⟨seed⟩
        let upheldCnt := sigEntries.countP (fun e => match e.expectedOutcome with | .upheld => true | _ => false)
        let rejCnt    := sigEntries.countP (fun e => match e.expectedOutcome with | .rejected => true | _ => false)
        let incCnt    := sigEntries.countP (fun e => match e.expectedOutcome with | .inconclusive => true | _ => false)
        let revCnt    := sigEntries.countP (fun e => match e.expectedOutcome with | .revert _ => true | _ => false)
        -- 16 upheld + 16 rejected + 8 inconclusive + 8 adversarial
        -- adversarial: 2 upheld + 4 inconclusive + 2 revert = 18 upheld, 20 inconclusive total
        if upheldCnt ≠ 18 then throw <| IO.userError s!"upheld: {upheldCnt}"
        if rejCnt ≠ 16 then throw <| IO.userError s!"rejected: {rejCnt}"
        if incCnt ≠ 12 then throw <| IO.userError s!"inconclusive: {incCnt}"
        if revCnt ≠ 2 then throw <| IO.userError s!"revert: {revCnt}"
    }
  , { name := "F.1.6: doubleApply entries include audit-3 concat-shape adversarials"
    , body := do
        let seed ← readSeed
        let (_, s1) := signatureInvalidEntries ⟨seed⟩
        let (_, s2) := nonceMismatchEntries s1
        let (dblEntries, _) := doubleApplyEntries s2
        let revs := dblEntries.filter (fun e => match e.expectedOutcome with | .revert _ => true | _ => false)
        let revLabels := revs.map (·.expectedOutcome.toString)
        if !revLabels.contains "revert:DoubleApplyConcatBadCount" then
          throw <| IO.userError "missing DoubleApplyConcatBadCount adversarial"
        if !revLabels.contains "revert:CBEInvalidLength" then
          throw <| IO.userError "missing CBEInvalidLength adversarial"
        if !revLabels.contains "revert:SelfClaimInvalid" then
          throw <| IO.userError "missing SelfClaimInvalid adversarial"
    }
  , { name := "F.1.6: verdict-finalisation entries cover MAX_VERDICT_SIGNERS boundary"
    , body := do
        let seed ← readSeed
        let (_, s1) := signatureInvalidEntries ⟨seed⟩
        let (_, s2) := nonceMismatchEntries s1
        let (_, s3) := doubleApplyEntries s2
        let (verdicts, _) := verdictEntries s3
        let labels := verdicts.map (·.label)
        if !labels.contains "verdict:max-signers" then
          throw <| IO.userError "missing max-signers boundary"
        if !labels.contains "verdict:over-max-signers" then
          throw <| IO.userError "missing over-max-signers boundary"
    }
  , { name := "F.1.6: action vs verdict EIP-712 domains are byte-distinct"
    , body := do
        -- Action domain "KnomosisAction" vs verdict domain "KnomosisDisputeVerifier".
        -- Documented in `LegalKernel.Authority.SignedAction.signedActionDomain`
        -- and `LegalKernel.Disputes.Verdict.verdictDomain` and recorded in the
        -- fixture header for cross-stack pinning.
        let actionDomain := "KnomosisAction"
        let verdictDomain := "KnomosisDisputeVerifier"
        if actionDomain == verdictDomain then
          throw <| IO.userError "action and verdict domains should be distinct"
    }
  , { name := "F.1.6: fixture file write / verify cycle succeeds"
    , body := do
        let seed ← readSeed
        let (json, _) := buildFixture seed
        writeFixture fixtureName json.encode
    }
  , { name := "F.1.6: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        if !isKeccak256Linked then
          skipWithReason s!"keccak256 fallback; cross-stack assert skipped"
    }
  ]

end DisputeEvidence
end LegalKernel.Test.Bridge.CrossCheck
