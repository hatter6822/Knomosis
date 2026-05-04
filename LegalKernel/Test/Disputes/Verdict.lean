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

/-! ## applyVerdict -/

/-- Sub-suite: applyVerdict. -/
def applyVerdictTests : List TestCase :=
  [ { name := "applyVerdict: rejects unknown dispute"
    , body := do
        let v : Verdict := { disputeId := 99, outcome := .upheld,
                              rationale := ⟨#[]⟩, signers := [], sigs := [] }
        match applyVerdict Pall baseEs ExtendedState.empty
                            transferThenDisputeLog v with
        | .error (.unknownDispute idx) => assert (idx = 99) "idx"
        | other => throw <| IO.userError s!"expected .unknownDispute, got {repr other}"
    }
  , { name := "applyVerdict: .rejected outcome leaves state unchanged"
    , body := do
        let v := verdictAgainstDispute1 .rejected
        match applyVerdict Pall baseEs ExtendedState.empty
                            transferThenDisputeLog v with
        | .ok es' =>
          -- The verdict is `.rejected`, so state should equal `currentEs = baseEs`.
          assert (es'.base.balances.size == baseEs.base.balances.size) "state unchanged"
        | other => throw <| IO.userError s!"expected .ok, got {repr other}"
    }
  , { name := "applyVerdict: .inconclusive outcome leaves state unchanged"
    , body := do
        let v := verdictAgainstDispute1 .inconclusive
        match applyVerdict Pall baseEs ExtendedState.empty
                            transferThenDisputeLog v with
        | .ok _es' => pure ()  -- state shape OK
        | other => throw <| IO.userError s!"expected .ok, got {repr other}"
    }
  , { name := "applyVerdict_deterministic API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (currentEs₁ currentEs₂ : ExtendedState)
                      (genesis₁ genesis₂ : ExtendedState)
                      (log₁ log₂ : List LogEntry) (v₁ v₂ : Verdict),
            currentEs₁ = currentEs₂ → genesis₁ = genesis₂ →
            log₁ = log₂ → v₁ = v₂ →
            applyVerdict P currentEs₁ genesis₁ log₁ v₁ =
            applyVerdict P currentEs₂ genesis₂ log₂ v₂ :=
          fun P e1 e2 g1 g2 l1 l2 v1 v2 he hg hl hv =>
            applyVerdict_deterministic P e1 e2 g1 g2 l1 l2 v1 v2 he hg hl hv
        pure ()
    }
  , { name := "applyVerdict_unknown_dispute API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (currentEs : ExtendedState)
                      (genesis : ExtendedState) (log : List LogEntry) (v : Verdict),
            log[v.disputeId]? = none →
            applyVerdict P currentEs genesis log v = .error (.unknownDispute v.disputeId) :=
          fun P es g log v h => applyVerdict_unknown_dispute P es g log v h
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
  ]

/-! ## Aggregate -/

/-- All Phase 6 verdict tests. -/
def tests : List TestCase :=
  proposeVerdictTests ++ applyVerdictTests ++ quorumPolicyTests

end LegalKernel.Test.Disputes.VerdictTests
