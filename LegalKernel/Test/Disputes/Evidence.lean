/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
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
