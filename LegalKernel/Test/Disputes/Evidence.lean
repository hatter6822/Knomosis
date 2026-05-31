-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Disputes.Evidence — runtime tests for Stage 2
(evidence checking) of the §8.4 dispute pipeline.

Phase 6 WU 6.4 / 6.5 / 6.6 / 6.7 / 6.8.  Exercises:

  * `replayPrefix` for valid and out-of-range indices.
  * `checkPreconditionFalse` for the inconclusive cases (missing log
    entry, replay failure).
  * `checkSignatureInvalid` for unregistered-signer fallback.
  * `checkNonceMismatch` for inconclusive cases.
  * `checkOracleMisreported` returns whatever the oracle policy
    returns (pass-through).
  * `checkDoubleApply` correctness on idx₁ = idx₂, missing entries,
    and the upheld case.
  * `checkEvidence` dispatcher correctness.
-/

import LegalKernel.Disputes.Evidence
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Disputes
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Disputes.EvidenceTests

/-! ## Test fixtures -/

/-- A minimal genesis ExtendedState. -/
def genesis : ExtendedState := ExtendedState.empty

/-- An empty log (no entries to dispute against). -/
def emptyLog : List LogEntry := []

/-- A trivial log entry. -/
def fixtureLogEntry : LogEntry where
  prevHash      := ⟨#[]⟩
  signedAction  :=
    { action := .transfer 0 1 2 0
      signer := 1
      nonce  := 0
      sig    := ⟨#[]⟩ }
  postStateHash := ⟨#[]⟩

/-- A 2-entry log. -/
def twoEntryLog : List LogEntry := [fixtureLogEntry, fixtureLogEntry]

/-- An "always rejects" oracle policy fixture. -/
def oracleReject : OraclePolicy := OraclePolicy.alwaysRejects

/-- An "always upheld" oracle policy fixture. -/
def oracleUphold : OraclePolicy := OraclePolicy.alwaysUpheld

/-- The unrestricted authority policy (used for replay). -/
def Pall : AuthorityPolicy := AuthorityPolicy.unrestricted

/-! ## checkPreconditionFalse -/

/-- Sub-suite: preconditionFalse. -/
def preconditionFalseTests : List TestCase :=
  [ { name := "checkPreconditionFalse: inconclusive on missing log entry"
    , body := do
        match checkPreconditionFalse Pall genesis emptyLog 0 with
        | .inconclusive => pure ()
        | other => throw <| IO.userError s!"expected .inconclusive, got {repr other}"
    }
  , { name := "checkPreconditionFalse: inconclusive on out-of-range index"
    , body := do
        match checkPreconditionFalse Pall genesis twoEntryLog 99 with
        | .inconclusive => pure ()
        | other => throw <| IO.userError s!"expected .inconclusive, got {repr other}"
    }
  ]

/-! ## checkSignatureInvalid -/

/-- AR.2.5 fixture: a registered signer.  `mockPubKey 1` produces a
    canonical mock key for actor 1; the registry maps actor 1 to
    it.  The mock crypto API: `mockVerify` returns true iff the
    signature is 64 bytes with first byte `0xFF`, regardless of
    `(pk, msg)`; `mockSign` produces that signature. -/
def signerOne : Authority.PublicKey := mockPubKey 1

/-- AR.2.5 fixture: a state with actor 1 registered. -/
def registeredEs : ExtendedState :=
  { genesis with registry := genesis.registry.insert 1 signerOne }

/-- AR.2.5 fixture: a deployment-1 byte identifier. -/
def did1 : ByteArray :=
  ByteArray.mk (((0x01 : UInt8) :: List.replicate 31 (0 : UInt8))).toArray

/-- AR.2.5 fixture: a deployment-2 byte identifier, distinct from `did1`. -/
def did2 : ByteArray :=
  ByteArray.mk (((0x02 : UInt8) :: List.replicate 31 (0 : UInt8))).toArray

/-- AR.2.5 fixture: a fully-signed log entry under `did1`. -/
def signedEntry : LogEntry where
  prevHash      := ⟨#[]⟩
  signedAction  :=
    let act  := Action.transfer 0 1 2 0
    let pk   := signerOne
    -- The signing input under `did1` is what `mockSign` "signs"
    -- (the mock ignores msg / pk so any signature shaped
    -- `[0xFF, 0, …]` passes mockVerify).
    let msg  := signingInput act 1 0 did1
    { action := act
      signer := 1
      nonce  := 0
      sig    := mockSign pk msg }
  postStateHash := ⟨#[]⟩

/-- Sub-suite: signatureInvalid. -/
def signatureInvalidTests : List TestCase :=
  [ { name := "checkSignatureInvalid: inconclusive when signer unregistered"
    , body := do
        -- Genesis has empty registry; the entry's signer (1) is not registered.
        match checkSignatureInvalid genesis twoEntryLog 0 with
        | .inconclusive => pure ()
        | other => throw <| IO.userError s!"expected .inconclusive, got {repr other}"
    }
  , { name := "checkSignatureInvalid: inconclusive on missing log entry"
    , body := do
        match checkSignatureInvalid genesis emptyLog 5 with
        | .inconclusive => pure ()
        | other => throw <| IO.userError s!"expected .inconclusive, got {repr other}"
    }
  -- AR.2.5 / M-5 — parameterised checkSignatureInvalidWith.
  , { name := "AR.2.5: checkSignatureInvalidWith API stability"
      -- Term-level API stability: the function exists with the
      -- documented signature.  Elaboration failure is the failure
      -- mode.
    , body := do
        let _proof :
            (Authority.PublicKey → ByteArray → Authority.Signature → Bool) →
            ByteArray → ExtendedState → List LogEntry → LogIndex →
            EvidenceVerdict :=
          checkSignatureInvalidWith
        pure ()
    }
  , { name := "AR.2.5: same deployment ⇒ mockVerify accepts (rejected)"
      -- Positive: mockVerify accepts under did1, so the signature
      -- is "valid" → the `signatureInvalid` claim is REJECTED.
    , body := do
        match checkSignatureInvalidWith mockVerify did1
                 registeredEs [signedEntry] 0 with
        | .rejected => pure ()
        | other =>
            throw <| IO.userError
              s!"expected .rejected under same deployment, got {repr other}"
    }
  , { name := "AR.2.5: cross-deployment ⇒ mockVerify still accepts (mockVerify ignores msg)"
      -- The `mockVerify` adaptor ignores `(pk, msg)`, so it
      -- accepts under any deployment.  This test exercises the
      -- *plumbing* — that the deploymentId reaches the verifier
      -- via `signingInput action signer nonce d`.  A production
      -- `Verify` (EUF-CMA) would reject under did2 because the
      -- message bytes differ; mock verify cannot demonstrate
      -- that, but exercising the plumbing on a different
      -- deploymentId is the regression we can land at the Lean
      -- level.
    , body := do
        match checkSignatureInvalidWith mockVerify did2
                 registeredEs [signedEntry] 0 with
        | .rejected => pure ()
        | other =>
            throw <| IO.userError
              s!"expected .rejected (mockVerify deployment-agnostic), got {repr other}"
    }
  , { name := "AR.2.5: production Verify ⇒ upheld at empty signature (cross-deployment proxy)"
      -- The production `Verify` opaque returns `false` at the
      -- Lean level (the real implementation is linked at
      -- runtime).  An entry with an empty signature therefore
      -- triggers `.upheld` regardless of deploymentId.  This is
      -- the proxy for "production-Verify-style rejection"
      -- that the dispute pipeline relies on in deployment
      -- binaries.
    , body := do
        match checkSignatureInvalidWith Verify did1
                 registeredEs twoEntryLog 0 with
        | .upheld => pure ()
        | other =>
            throw <| IO.userError
              s!"expected .upheld under production Verify, got {repr other}"
    }
  , { name := "AR.2.5: back-compat alias checkSignatureInvalid still works"
      -- The non-parameterised `checkSignatureInvalid` alias
      -- specialises at `ByteArray.empty` for the empty-deployment
      -- test path.  This test pins the alias to its
      -- delegated behaviour.
    , body := do
        let v1 := checkSignatureInvalid registeredEs twoEntryLog 0
        let v2 := checkSignatureInvalidWith Verify ByteArray.empty
                                            registeredEs twoEntryLog 0
        if v1 = v2 then pure ()
        else
          throw <| IO.userError s!"alias diverged: {repr v1} vs {repr v2}"
    }
  -- AR.2.5: parameterised dispatcher (checkEvidenceWith) routes
  -- the deploymentId through to the signatureInvalid arm.  These
  -- pin the Stage-2 entry point to use the deploymentId-aware
  -- variant; production deployments must call this with the
  -- runtime's RuntimeState.deploymentId.
  , { name := "AR.2.5: checkEvidenceWith API stability"
    , body := do
        let _proof :
            (Authority.PublicKey → ByteArray → Authority.Signature → Bool) →
            ByteArray → AuthorityPolicy → OraclePolicy →
            ExtendedState → ExtendedState → List LogEntry → DisputeRecord →
            EvidenceVerdict :=
          checkEvidenceWith
        pure ()
    }
  , { name := "AR.2.5: checkEvidence = checkEvidenceWith Verify .empty"
      -- Back-compat alias preservation: `checkEvidence` is
      -- definitionally `checkEvidenceWith Verify ByteArray.empty`.
    , body := do
        let drec : DisputeRecord :=
          { dispute   := { challenger := 1, claim := .signatureInvalid 0,
                           evidence := ⟨#[]⟩, nonce := 0, sig := ⟨#[]⟩ }
          , idx       := 0
          , status    := .open }
        let v1 := checkEvidence Pall oracleReject registeredEs genesis
                                twoEntryLog drec
        let v2 := checkEvidenceWith Verify ByteArray.empty Pall oracleReject
                                    registeredEs genesis twoEntryLog drec
        if v1 = v2 then pure ()
        else
          throw <| IO.userError s!"checkEvidence alias diverged: {repr v1} vs {repr v2}"
    }
  ]

/-! ## checkNonceMismatch -/

/-- Sub-suite: nonceMismatch. -/
def nonceMismatchTests : List TestCase :=
  [ { name := "checkNonceMismatch: inconclusive on missing log entry"
    , body := do
        match checkNonceMismatch Pall genesis emptyLog 0 with
        | .inconclusive => pure ()
        | other => throw <| IO.userError s!"expected .inconclusive, got {repr other}"
    }
  ]

/-! ## checkOracleMisreported -/

/-- Sub-suite: oracleMisreported. -/
def oracleMisreportedTests : List TestCase :=
  [ { name := "checkOracleMisreported: alwaysRejects returns rejected"
    , body := do
        -- Use a 1-entry log so the defensive index check passes.
        match checkOracleMisreported oracleReject [fixtureLogEntry] 0 ⟨#[]⟩ with
        | .rejected => pure ()
        | other => throw <| IO.userError s!"expected .rejected, got {repr other}"
    }
  , { name := "checkOracleMisreported: alwaysUpheld returns upheld"
    , body := do
        match checkOracleMisreported oracleUphold [fixtureLogEntry] 0 ⟨#[]⟩ with
        | .upheld => pure ()
        | other => throw <| IO.userError s!"expected .upheld, got {repr other}"
    }
  , { name := "checkOracleMisreported is a pure pass-through (in-range)"
    , body := do
        let v1 := checkOracleMisreported oracleReject [fixtureLogEntry] 0 ⟨#[1, 2]⟩
        let v2 := oracleReject.verifier 0 ⟨#[1, 2]⟩
        assert (v1 == v2) "pass-through equality"
    }
  , { name := "checkOracleMisreported: out-of-range idx returns .inconclusive"
    , body := do
        -- Empty log, idx 0 → defensive check kicks in.
        match checkOracleMisreported oracleUphold [] 0 ⟨#[]⟩ with
        | .inconclusive => pure ()
        | other => throw <| IO.userError s!"expected .inconclusive, got {repr other}"
    }
  , { name := "checkOracleMisreported_inconclusive_on_out_of_range API stability"
    , body := do
        let _proof : ∀ (oracle : OraclePolicy) (log : List LogEntry)
                       (idx : LogIndex) (evidence : ByteArray),
            log[idx]? = none →
            checkOracleMisreported oracle log idx evidence = .inconclusive :=
          fun o l i e h => checkOracleMisreported_inconclusive_on_out_of_range o l i e h
        pure ()
    }
  ]

/-! ## checkDoubleApply -/

/-- Sub-suite: doubleApply. -/
def doubleApplyTests : List TestCase :=
  [ { name := "checkDoubleApply: rejects idx₁ = idx₂"
    , body := do
        match checkDoubleApply twoEntryLog 0 0 with
        | .rejected => pure ()
        | other => throw <| IO.userError s!"expected .rejected, got {repr other}"
    }
  , { name := "checkDoubleApply: inconclusive on missing entries"
    , body := do
        match checkDoubleApply emptyLog 0 1 with
        | .inconclusive => pure ()
        | other => throw <| IO.userError s!"expected .inconclusive, got {repr other}"
    }
  , { name := "checkDoubleApply: upheld when same signer + nonce + distinct indices"
    , body := do
        -- Both entries in twoEntryLog have signer=1 and nonce=0 (same fixture).
        match checkDoubleApply twoEntryLog 0 1 with
        | .upheld => pure ()
        | other => throw <| IO.userError s!"expected .upheld, got {repr other}"
    }
  , { name := "checkDoubleApply: rejected when signers differ"
    , body := do
        let altEntry : LogEntry :=
          { prevHash := ⟨#[]⟩
            signedAction :=
              { action := .transfer 0 1 2 0, signer := 99, nonce := 0, sig := ⟨#[]⟩ }
            postStateHash := ⟨#[]⟩ }
        let mixedLog : List LogEntry := [fixtureLogEntry, altEntry]
        match checkDoubleApply mixedLog 0 1 with
        | .rejected => pure ()
        | other => throw <| IO.userError s!"expected .rejected, got {repr other}"
    }
  , { name := "checkDoubleApply_rejects_self API stability"
    , body := do
        let _proof : ∀ (log : List LogEntry) (idx : LogIndex),
            checkDoubleApply log idx idx = .rejected :=
          checkDoubleApply_rejects_self
        pure ()
    }
  ]

/-! ## checkEvidence dispatcher -/

/-- Sub-suite: dispatcher. -/
def dispatcherTests : List TestCase :=
  [ { name := "checkEvidence: dispatches to oracleMisreported"
    , body := do
        let drec : DisputeRecord :=
          { dispute :=
              { challenger := 1, claim := .oracleMisreported 0 ⟨#[]⟩
                evidence := ⟨#[]⟩, nonce := 0, sig := ⟨#[]⟩ }
            idx := 1, status := .open }
        match checkEvidence Pall oracleUphold genesis genesis twoEntryLog drec with
        | .upheld => pure ()
        | other => throw <| IO.userError s!"expected .upheld, got {repr other}"
    }
  , { name := "checkEvidence: dispatches to doubleApply"
    , body := do
        let drec : DisputeRecord :=
          { dispute :=
              { challenger := 1, claim := .doubleApply 0 1
                evidence := ⟨#[]⟩, nonce := 0, sig := ⟨#[]⟩ }
            idx := 2, status := .open }
        -- Both entries have signer=1 + nonce=0, so doubleApply should be upheld.
        match checkEvidence Pall oracleReject genesis genesis twoEntryLog drec with
        | .upheld => pure ()
        | other => throw <| IO.userError s!"expected .upheld, got {repr other}"
    }
  , { name := "checkEvidence_deterministic API stability"
    , body := do
        let _proof : ∀ (P : AuthorityPolicy) (oracle : OraclePolicy)
                       (currentEs₁ currentEs₂ : ExtendedState)
                       (genesis₁ genesis₂ : ExtendedState)
                       (log₁ log₂ : List LogEntry) (rec₁ rec₂ : DisputeRecord),
            currentEs₁ = currentEs₂ → genesis₁ = genesis₂ →
            log₁ = log₂ → rec₁ = rec₂ →
            checkEvidence P oracle currentEs₁ genesis₁ log₁ rec₁ =
            checkEvidence P oracle currentEs₂ genesis₂ log₂ rec₂ :=
          fun P o e1 e2 g1 g2 l1 l2 r1 r2 he hg hl hr =>
            checkEvidence_deterministic P o e1 e2 g1 g2 l1 l2 r1 r2 he hg hl hr
        pure ()
    }
  ]

/-! ## Audit-3.6 coherence-theorem API stability -/

/-- Term-level: `apply_admissible_with_eq_kernelOnlyApply` is the
    headline per-step coherence theorem.  Pin its signature. -/
def coherenceLemmaAPI : TestCase := {
  name := "Audit-3.6 apply_admissible_with_eq_kernelOnlyApply API stability"
  body := do
    let _proof :
      ∀ {verify : PublicKey → ByteArray → Signature → Bool}
        {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
        {entry : LogEntry}
        (h : AdmissibleWith verify P d es entry.signedAction),
        apply_admissible_with verify P d es entry.signedAction h
          = kernelOnlyApply es entry :=
      @apply_admissible_with_eq_kernelOnlyApply
    pure ()
}

/-- Term-level: `RuntimeAdmissibleWith.head` extracts the head
    admissibility witness from a non-empty admissible chain. -/
def runtimeAdmissibleHeadAPI : TestCase := {
  name := "Audit-3.6 RuntimeAdmissibleWith.head API stability"
  body := do
    let _proof :
      ∀ {verify : PublicKey → ByteArray → Signature → Bool}
        {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
        {entry : LogEntry} {rest : List LogEntry},
        RuntimeAdmissibleWith verify P d es (entry :: rest) →
        AdmissibleWith verify P d es entry.signedAction :=
      @RuntimeAdmissibleWith.head
    pure ()
}

/-- Term-level: `kernelOnlyApply_eq_apply_admissible_with_at_head`
    is the chain-level cons-step corollary. -/
def chainLevelCohAPI : TestCase := {
  name := "Audit-3.6 kernelOnlyApply_eq_apply_admissible_with_at_head API stability"
  body := do
    let _proof :
      ∀ {verify : PublicKey → ByteArray → Signature → Bool}
        {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
        {entry : LogEntry} {rest : List LogEntry}
        (h : RuntimeAdmissibleWith verify P d es (entry :: rest)),
        kernelOnlyApply es entry =
          apply_admissible_with verify P d es entry.signedAction h.head :=
      @kernelOnlyApply_eq_apply_admissible_with_at_head
    pure ()
}

/-- Audit-3.6 inductive predicate's `nil` constructor. -/
def runtimeAdmissibleNilAPI : TestCase := {
  name := "Audit-3.6 RuntimeAdmissibleWith.nil constructible (empty log)"
  body := do
    let _witness :
      RuntimeAdmissibleWith mockVerify AuthorityPolicy.unrestricted
        ByteArray.empty ExtendedState.empty [] :=
      RuntimeAdmissibleWith.nil
    pure ()
}

/-! ## Aggregate -/

/-- Audit-3.6 API-stability tests added to the existing evidence
    suite. -/
def coherenceTests : List TestCase :=
  [coherenceLemmaAPI, runtimeAdmissibleHeadAPI, chainLevelCohAPI,
   runtimeAdmissibleNilAPI]

/-- All Phase 6 evidence tests. -/
def tests : List TestCase :=
  preconditionFalseTests ++ signatureInvalidTests ++
  nonceMismatchTests ++ oracleMisreportedTests ++
  doubleApplyTests ++ dispatcherTests ++ coherenceTests

end LegalKernel.Test.Disputes.EvidenceTests
