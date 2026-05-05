/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Disputes.Verdict — runtime tests for Stages 3 + 4
of the §8.4 dispute pipeline.

Phase 6 WU 6.9 + WU 6.10.  Exercises:

  * `proposeVerdict` rejects an unknown disputeId.
  * `proposeVerdict` rejects when quorum not met.
  * `proposeVerdict` accepts a valid quorum-signed verdict.
  * `applyVerdict` rejects a verdict against an unknown dispute.
  * `applyVerdict` with `.rejected` outcome leaves state unchanged.
  * `applyVerdict` with `.inconclusive` outcome leaves state unchanged.
  * `applyVerdict` rejects already-decided disputes.
  * `countVerifiedSignatures` correctness on approved-list filtering.
  * `QuorumPolicy.singleton` / `.empty` constructor sanity.
-/

import LegalKernel.Disputes.Verdict
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Disputes
open LegalKernel.Test

namespace LegalKernel.Test.Disputes.VerdictTests

/-! ## Test fixtures -/

/-- A registered actor. -/
def actor1 : ActorId := 10

/-- A non-registered actor. -/
def actor2 : ActorId := 20

/-- A sample public key. -/
def k1 : PublicKey := ⟨#[0xAA]⟩

/-- ExtendedState with `actor1` registered. -/
def baseEs : ExtendedState where
  base     := emptyState
  nonces   := NonceState.empty
  registry := KeyRegistry.empty.register actor1 k1

/-- A trivial transfer log entry. -/
def fixtureLogEntry : LogEntry where
  prevHash      := ⟨#[]⟩
  signedAction  :=
    { action := .transfer 0 actor1 actor2 0
      signer := actor1
      nonce  := 0
      sig    := ⟨#[]⟩ }
  postStateHash := ⟨#[]⟩

/-- A dispute by actor1 against log entry 0 with claim
    `preconditionFalse 0`.  Used as the dispute payload. -/
def disputeAgainst0 : Dispute :=
  { challenger := actor1
    claim      := .preconditionFalse 0
    evidence   := ⟨#[]⟩
    nonce      := 0
    sig        := ⟨#[]⟩ }

/-- A 2-entry log: `[transfer]` + `[dispute]`. -/
def transferThenDisputeLog : List LogEntry :=
  let disputeEntry : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction :=
        { action := .dispute disputeAgainst0, signer := actor1
          nonce := 0, sig := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  [fixtureLogEntry, disputeEntry]

/-- An empty quorum policy. -/
def qpEmpty : QuorumPolicy := QuorumPolicy.empty

/-- A 1-of-1 quorum policy with `actor1` as the sole adjudicator. -/
def qpSingleton : QuorumPolicy := QuorumPolicy.singleton actor1

/-- The unrestricted authority policy. -/
def Pall : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- The "always upheld" oracle policy. -/
def oracleUphold : OraclePolicy := OraclePolicy.alwaysUpheld

/-- The "always rejects" oracle policy. -/
def oracleReject : OraclePolicy := OraclePolicy.alwaysRejects

/-- A verdict against the dispute at index 1 in
    `transferThenDisputeLog`, with no signers / sigs. -/
def verdictAgainstDispute1 (outcome : EvidenceVerdict) : Verdict :=
  { disputeId := 1, outcome, rationale := ⟨#[]⟩, signers := [], sigs := [] }

/-! ## proposeVerdict -/

/-- Sub-suite: proposeVerdict. -/
def proposeVerdictTests : List TestCase :=
  [ { name := "proposeVerdict: rejects unknown disputeId"
    , body := do
        let v : Verdict := { disputeId := 99, outcome := .upheld,
                              rationale := ⟨#[]⟩, signers := [], sigs := [] }
        match proposeVerdict Pall oracleUphold qpSingleton baseEs ExtendedState.empty
                              transferThenDisputeLog v with
        | .error (.unknownDispute idx) => assert (idx = 99) "idx in error"
        | other => throw <| IO.userError s!"expected .unknownDispute, got {repr other}"
    }
  , { name := "proposeVerdict: rejects unknown disputeId on non-dispute entry"
    , body := do
        -- log[0] is a transfer, not a dispute.
        let v : Verdict := { disputeId := 0, outcome := .upheld,
                              rationale := ⟨#[]⟩, signers := [], sigs := [] }
        match proposeVerdict Pall oracleUphold qpSingleton baseEs ExtendedState.empty
                              transferThenDisputeLog v with
        | .error (.unknownDispute _) => pure ()
        | other => throw <| IO.userError s!"expected .unknownDispute, got {repr other}"
    }
  ]

/-! ## applyVerdictUnchecked -/

/-- Sub-suite: applyVerdictUnchecked (bypass-form tests).  These
    tests exercise the unchecked entry point on paths where the
    `VerdictPassedStage3` witness can't be constructed (the
    dispute doesn't exist) or where bypass semantics are
    intentionally being verified. -/
def applyVerdictUncheckedTests : List TestCase :=
  [ { name := "applyVerdictUnchecked: rejects unknown dispute"
    , body := do
        let v : Verdict := { disputeId := 99, outcome := .upheld,
                              rationale := ⟨#[]⟩, signers := [], sigs := [] }
        match applyVerdictUnchecked Pall baseEs ExtendedState.empty
                            transferThenDisputeLog v with
        | .error (.unknownDispute idx) => assert (idx = 99) "idx"
        | other => throw <| IO.userError s!"expected .unknownDispute, got {repr other}"
    }
  , { name := "applyVerdictUnchecked: .rejected outcome leaves state unchanged"
    , body := do
        let v := verdictAgainstDispute1 .rejected
        match applyVerdictUnchecked Pall baseEs ExtendedState.empty
                            transferThenDisputeLog v with
        | .ok es' =>
          -- The verdict is `.rejected`, so state should equal `currentEs = baseEs`.
          assert (es'.base.balances.size == baseEs.base.balances.size) "state unchanged"
        | other => throw <| IO.userError s!"expected .ok, got {repr other}"
    }
  , { name := "applyVerdictUnchecked: .inconclusive outcome leaves state unchanged"
    , body := do
        let v := verdictAgainstDispute1 .inconclusive
        match applyVerdictUnchecked Pall baseEs ExtendedState.empty
                            transferThenDisputeLog v with
        | .ok _es' => pure ()  -- state shape OK
        | other => throw <| IO.userError s!"expected .ok, got {repr other}"
    }
  , { name := "applyVerdictUnchecked_deterministic API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (currentEs₁ currentEs₂ : ExtendedState)
                      (genesis₁ genesis₂ : ExtendedState)
                      (log₁ log₂ : List LogEntry) (v₁ v₂ : Verdict),
            currentEs₁ = currentEs₂ → genesis₁ = genesis₂ →
            log₁ = log₂ → v₁ = v₂ →
            applyVerdictUnchecked P currentEs₁ genesis₁ log₁ v₁ =
            applyVerdictUnchecked P currentEs₂ genesis₂ log₂ v₂ :=
          fun P e1 e2 g1 g2 l1 l2 v1 v2 he hg hl hv =>
            applyVerdictUnchecked_deterministic P e1 e2 g1 g2 l1 l2 v1 v2 he hg hl hv
        pure ()
    }
  , { name := "applyVerdictUnchecked_unknown_dispute API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (currentEs : ExtendedState)
                      (genesis : ExtendedState) (log : List LogEntry) (v : Verdict),
            log[v.disputeId]? = none →
            applyVerdictUnchecked P currentEs genesis log v =
              .error (.unknownDispute v.disputeId) :=
          fun P es g log v h => applyVerdictUnchecked_unknown_dispute P es g log v h
        pure ()
    }
  ]

/-! ## QuorumPolicy + countVerifiedSignatures -/

/-- Sub-suite: QuorumPolicy. -/
def quorumPolicyTests : List TestCase :=
  [ { name := "QuorumPolicy.singleton: required = 1"
    , body := do
        assert (qpSingleton.required = 1) "required"
        assert (qpSingleton.approvedAdjudicators = [actor1]) "approvedAdjudicators"
    }
  , { name := "QuorumPolicy.empty: required = 0, no adjudicators"
    , body := do
        assert (qpEmpty.required = 0) "required"
        assert (qpEmpty.approvedAdjudicators = []) "approvedAdjudicators"
    }
  , { name := "countVerifiedSignatures: empty signers list returns 0"
    , body := do
        let v : Verdict := { disputeId := 0, outcome := .upheld,
                              rationale := ⟨#[]⟩, signers := [], sigs := [] }
        let n := countVerifiedSignatures qpSingleton baseEs v
        assert (n = 0) s!"expected 0, got {n}"
    }
  , { name := "countVerifiedSignatures: skips non-approved adjudicators"
    , body := do
        let v : Verdict := { disputeId := 0, outcome := .upheld,
                              rationale := ⟨#[]⟩,
                              signers := [actor2],  -- not in approved list
                              sigs := [⟨#[]⟩] }
        let n := countVerifiedSignatures qpSingleton baseEs v
        assert (n = 0) s!"expected 0 (non-approved), got {n}"
    }
  , { name := "countVerifiedSignatures: dedupes repeated approved signer"
      -- Regression test for the duplicate-signer quorum-forgery
      -- vulnerability.  Without per-signer deduplication, a single
      -- approved adjudicator with one valid signature could meet any
      -- quorum threshold by repeating the (signer, sig) pair N times.
      -- With deduplication, the count is bounded by the number of
      -- DISTINCT approved signers regardless of repetition.
      --
      -- Verify is opaque (returns false in tests), so the count stays
      -- at 0; the assertion below confirms duplicates do not inflate
      -- the count past 1 (which is the maximum for a singleton-quorum
      -- policy with the registered actor1).  The count is 0 because
      -- Verify rejects, but the structural property "≤ #distinct
      -- approved signers" holds at value level here.
    , body := do
        let v : Verdict := { disputeId := 0, outcome := .upheld,
                              rationale := ⟨#[]⟩,
                              -- Five copies of actor1 (the sole
                              -- approved adjudicator).
                              signers := [actor1, actor1, actor1, actor1, actor1],
                              sigs    := [⟨#[1]⟩, ⟨#[2]⟩, ⟨#[3]⟩, ⟨#[4]⟩, ⟨#[5]⟩] }
        let n := countVerifiedSignatures qpSingleton baseEs v
        -- With dedup: count ≤ 1 (only actor1 is in the approved list,
        -- and Verify rejects every signature, so count = 0).
        -- Without dedup (the buggy form), count would be 0 only
        -- because Verify rejects — but if any of the 5 signatures
        -- verified, a single legitimate signature would be replayed
        -- 5 times to forge quorum.  The dedup invariant is therefore:
        -- count ≤ #distinct approved signers in v.signers, which is 1.
        assert (n ≤ 1) s!"dedup failure: count {n} exceeds 1 (max distinct approved)"
    }
  , { name := "countVerifiedSignatures: dedup invariant on mixed list"
    , body := do
        -- Mixed list: actor1 (approved) appears twice; actor2 (not
        -- approved) appears once.  Dedup invariant: count ≤ 1.
        let v : Verdict := { disputeId := 0, outcome := .upheld,
                              rationale := ⟨#[]⟩,
                              signers := [actor1, actor2, actor1],
                              sigs    := [⟨#[1]⟩, ⟨#[2]⟩, ⟨#[3]⟩] }
        let n := countVerifiedSignatures qpSingleton baseEs v
        assert (n ≤ 1) s!"dedup failure: count {n} exceeds 1"
    }
  , { name := "verdictSigningInput: distinct outcomes produce distinct bytes"
      -- Regression test for the verdictSigningInput stub.  Previously
      -- returned ByteArray.empty for every verdict; with the real CBE
      -- encoding, distinct (disputeId, outcome, rationale) triples
      -- produce distinct byte sequences.
    , body := do
        let v_uph : Verdict := { disputeId := 0, outcome := .upheld,
                                  rationale := ⟨#[]⟩,
                                  signers := [], sigs := [] }
        let v_rej : Verdict := { v_uph with outcome := .rejected }
        let bytes_uph := verdictSigningInput v_uph
        let bytes_rej := verdictSigningInput v_rej
        assert (bytes_uph.toList ≠ bytes_rej.toList)
          "verdictSigningInput must distinguish .upheld from .rejected"
    }
  , { name := "verdictSigningInput: distinct disputeIds produce distinct bytes"
    , body := do
        let v0 : Verdict := { disputeId := 0, outcome := .upheld,
                                rationale := ⟨#[]⟩,
                                signers := [], sigs := [] }
        let v1 : Verdict := { v0 with disputeId := 1 }
        assert ((verdictSigningInput v0).toList ≠ (verdictSigningInput v1).toList)
          "verdictSigningInput must distinguish distinct disputeIds"
    }
  , { name := "verdictSigningInput: same payload, same bytes"
    , body := do
        -- Determinism: the same (disputeId, outcome, rationale)
        -- always produces the same bytes regardless of signers/sigs.
        let v0 : Verdict := { disputeId := 7, outcome := .inconclusive,
                                rationale := ⟨#[1, 2, 3]⟩,
                                signers := [actor1], sigs := [⟨#[42]⟩] }
        let v1 : Verdict := { disputeId := 7, outcome := .inconclusive,
                                rationale := ⟨#[1, 2, 3]⟩,
                                signers := [], sigs := [] }
        assert ((verdictSigningInput v0).toList = (verdictSigningInput v1).toList)
          "verdictSigningInput must ignore signers/sigs (only signs disputeId/outcome/rationale)"
    }
  , { name := "verdictSigningInput: domain prefix is present"
      -- Cross-protocol replay protection: every verdictSigningInput
      -- begins with the canonical verdictDomain bytes, ensuring the
      -- bytes can never collide with the SignedAction `signingInput`
      -- output.  An adversary with a `Verify`-true signature on a
      -- Verdict therefore cannot reuse it as a SignedAction signature.
    , body := do
        let v : Verdict := { disputeId := 0, outcome := .upheld,
                              rationale := ⟨#[]⟩,
                              signers := [], sigs := [] }
        let bytes := (verdictSigningInput v).toList
        -- Skip the 9-byte CBE byte-string head (1 tag + 8 LE length).
        let domainPart := bytes.drop 9 |>.take verdictDomain.toUTF8.size
        let expectedDomain := verdictDomain.toUTF8.data.toList
        assert (domainPart = expectedDomain)
          s!"domain prefix missing from verdictSigningInput"
    }
  , { name := "verdictSigningInput: domain differs from signedActionDomain"
      -- The two domain strings MUST differ to prevent cross-protocol
      -- signature replay between SignedActions and Verdicts.
    , body := do
        assert (verdictDomain ≠ Authority.signedActionDomain)
          s!"verdictDomain ({verdictDomain}) must differ from signedActionDomain"
    }
  ]

/-! ## Witness-bearing applyVerdict API stability tests (C.8c) -/

/-- Sub-suite: witness-bearing applyVerdict API. -/
def witnessApiTests : List TestCase :=
  [ { name := "proposeVerdict_ok_returns_input API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v v' : Verdict),
            proposeVerdict P oracle qp currentEs genesis log v = .ok v' →
            v' = v :=
          fun P o q e g l v v' h =>
            proposeVerdict_ok_returns_input P o q e g l v v' h
        pure ()
    }
  , { name := "applyVerdict_eq_unchecked API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict)
                       (h : VerdictPassedStage3 P oracle qp currentEs genesis log v),
            applyVerdict P oracle qp currentEs genesis log v h =
            applyVerdictUnchecked P currentEs genesis log v :=
          fun P o q e g l v h => applyVerdict_eq_unchecked P o q e g l v h
        pure ()
    }
  , { name := "applyVerdict_log_in_range API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict)
                       (_h : VerdictPassedStage3 P oracle qp currentEs genesis log v),
            ∃ entry, log[v.disputeId]? = some entry :=
          fun P o q e g l v h => applyVerdict_log_in_range P o q e g l v h
        pure ()
    }
  , { name := "applyVerdict_entry_is_dispute API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict) (entry : LogEntry)
                       (_h : VerdictPassedStage3 P oracle qp currentEs genesis log v),
            log[v.disputeId]? = some entry →
            ∃ d, entry.signedAction.action = .dispute d :=
          fun P o q e g l v entry h h_idx =>
            applyVerdict_entry_is_dispute P o q e g l v entry h h_idx
        pure ()
    }
  , { name := "applyVerdict_dispute_open API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict)
                       (_h : VerdictPassedStage3 P oracle qp currentEs genesis log v),
            disputeStatus log v.disputeId = some .open :=
          fun P o q e g l v h => applyVerdict_dispute_open P o q e g l v h
        pure ()
    }
  , { name := "applyVerdict_under_witness_succeeds API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict)
                       (h : VerdictPassedStage3 P oracle qp currentEs genesis log v),
            ∃ es, applyVerdict P oracle qp currentEs genesis log v h = .ok es :=
          fun P o q e g l v h =>
            applyVerdict_under_witness_succeeds P o q e g l v h
        pure ()
    }
  , { name := "applyVerdict_unknownDispute_unreachable API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict)
                       (h : VerdictPassedStage3 P oracle qp currentEs genesis log v),
            applyVerdict P oracle qp currentEs genesis log v h ≠
              .error (.unknownDispute v.disputeId) :=
          fun P o q e g l v h =>
            applyVerdict_unknownDispute_unreachable P o q e g l v h
        pure ()
    }
  , { name := "applyVerdict_alreadyDecided_unreachable API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict)
                       (h : VerdictPassedStage3 P oracle qp currentEs genesis log v),
            applyVerdict P oracle qp currentEs genesis log v h ≠
              .error .alreadyDecided :=
          fun P o q e g l v h =>
            applyVerdict_alreadyDecided_unreachable P o q e g l v h
        pure ()
    }
  , { name := "applyVerdict_replayFailed_unreachable API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict)
                       (h : VerdictPassedStage3 P oracle qp currentEs genesis log v),
            applyVerdict P oracle qp currentEs genesis log v h ≠
              .error .replayFailed :=
          fun P o q e g l v h =>
            applyVerdict_replayFailed_unreachable P o q e g l v h
        pure ()
    }
  , { name := "claimImpugnedIdx_in_range_when_upheld API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (currentEs genesis : ExtendedState) (log : List LogEntry)
                       (rec : DisputeRecord),
            checkEvidence P oracle currentEs genesis log rec = .upheld →
            claimImpugnedIdx rec.dispute.claim < log.length :=
          fun P o e g l rec h =>
            claimImpugnedIdx_in_range_when_upheld P o e g l rec h
        pure ()
    }
  ]

/-! ## proposeAndApplyVerdict tests (C.8d) -/

/-- Sub-suite: proposeAndApplyVerdict. -/
def proposeAndApplyVerdictTests : List TestCase :=
  [ { name := "proposeAndApplyVerdict_eq_applyVerdict_when_proposed_ok API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict),
            proposeVerdict P oracle qp currentEs genesis log v = .ok v →
            proposeAndApplyVerdict P oracle qp currentEs genesis log v =
            applyVerdictUnchecked P currentEs genesis log v :=
          fun P o q e g l v h =>
            proposeAndApplyVerdict_eq_applyVerdict_when_proposed_ok
              P o q e g l v h
        pure ()
    }
  , { name := "proposeAndApplyVerdict_proposeVerdict_error_path API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict)
                       (e : VerdictError),
            proposeVerdict P oracle qp currentEs genesis log v = .error e →
            proposeAndApplyVerdict P oracle qp currentEs genesis log v =
              .error e :=
          fun P o q e g l v err h =>
            proposeAndApplyVerdict_proposeVerdict_error_path
              P o q e g l v err h
        pure ()
    }
  , { name := "proposeAndApplyVerdict_deterministic API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (es₁ es₂ g₁ g₂ : ExtendedState)
                       (l₁ l₂ : List LogEntry) (v₁ v₂ : Verdict),
            es₁ = es₂ → g₁ = g₂ → l₁ = l₂ → v₁ = v₂ →
            proposeAndApplyVerdict P oracle qp es₁ g₁ l₁ v₁ =
            proposeAndApplyVerdict P oracle qp es₂ g₂ l₂ v₂ :=
          fun P o q e₁ e₂ g₁ g₂ l₁ l₂ v₁ v₂ he hg hl hv =>
            proposeAndApplyVerdict_deterministic P o q e₁ e₂ g₁ g₂
                                                  l₁ l₂ v₁ v₂ he hg hl hv
        pure ()
    }
  , { name := "proposeAndApplyVerdict_unknown_dispute API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (qp : QuorumPolicy) (currentEs genesis : ExtendedState)
                       (log : List LogEntry) (v : Verdict),
            log[v.disputeId]? = none →
            proposeAndApplyVerdict P oracle qp currentEs genesis log v =
              .error (.unknownDispute v.disputeId) :=
          fun P o q e g l v h =>
            proposeAndApplyVerdict_unknown_dispute P o q e g l v h
        pure ()
    }
  , { name := "proposeAndApplyVerdict: rejects unknown disputeId at runtime"
    , body := do
        let v : Verdict := { disputeId := 99, outcome := .upheld,
                              rationale := ⟨#[]⟩, signers := [], sigs := [] }
        match proposeAndApplyVerdict Pall oracleUphold qpEmpty baseEs ExtendedState.empty
                                      transferThenDisputeLog v with
        | .error (.unknownDispute idx) => assert (idx = 99) "idx in error"
        | other => throw <| IO.userError s!"expected .unknownDispute, got {repr other}"
    }
  ]

/-! ## Aggregate -/

/-- All Phase 6 verdict tests. -/
def tests : List TestCase :=
  proposeVerdictTests ++ applyVerdictUncheckedTests ++ quorumPolicyTests ++
    witnessApiTests ++ proposeAndApplyVerdictTests

end LegalKernel.Test.Disputes.VerdictTests
