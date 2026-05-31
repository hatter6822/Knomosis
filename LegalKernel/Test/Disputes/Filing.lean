-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Disputes.Filing — runtime tests for Stage 1 of the
§8.4 dispute pipeline.

Phase 6 WU 6.3 + WU 6.11.  Exercises:

  * `fileDispute` happy path: registered challenger, in-range
    claim, no duplicate.
  * `fileDispute` `unknownChallenger` error path.
  * `fileDispute` `indexOutOfRange` error paths (primary +
    secondary).
  * `fileDispute` `duplicateDispute` error path.
  * `claimImpugnedIdx` / `claimSecondaryIdx` projection
    correctness.
  * `applyWithdraw` idempotency at every dispute status.
  * `disputeStatus` walk-the-log correctness for open / withdrawn /
    decided cases.
-/

import LegalKernel.Disputes.Filing
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Disputes
open LegalKernel.Test

namespace LegalKernel.Test.Disputes.FilingTests

/-! ## Test fixtures -/

/-- A registered actor in the test extended state. -/
def actor1 : ActorId := 10

/-- A non-registered actor in the test extended state. -/
def actor2 : ActorId := 20

/-- A sample public key (opaque from the verify perspective). -/
def k1 : PublicKey := ⟨#[0xAA]⟩

/-- An ExtendedState with `actor1` registered, no balances. -/
def baseEs : ExtendedState where
  base     := emptyState
  nonces   := NonceState.empty
  registry := KeyRegistry.empty.register actor1 k1

/-- A trivial log entry: actor1 transfers 0 of resource 0 to actor 2.
    The balances are all zero, so the kernel `.pre` would fail
    against `emptyState`; for these tests we only need the entry to
    *exist*. -/
def fixtureLogEntry : LogEntry where
  prevHash      := ⟨#[]⟩
  signedAction  :=
    { action := .transfer 0 actor1 actor2 0
      signer := actor1
      nonce  := 0
      sig    := ⟨#[]⟩ }
  postStateHash := ⟨#[]⟩

/-- A 3-entry log with all three entries being trivial transfers. -/
def threeEntryLog : List LogEntry :=
  [fixtureLogEntry, fixtureLogEntry, fixtureLogEntry]

/-- A dispute by actor1 against log entry 1. -/
def disputeAgainst1 : Dispute :=
  { challenger := actor1
    claim      := .preconditionFalse 1
    evidence   := ⟨#[]⟩
    nonce      := 0
    sig        := ⟨#[]⟩ }

/-! ## fileDispute happy path -/

/-- Sub-suite: happy paths. -/
def happyPathTests : List TestCase :=
  [ { name := "fileDispute: succeeds for registered challenger, in-range claim"
    , body := do
        match fileDispute baseEs threeEntryLog disputeAgainst1 with
        | .ok rec =>
          assert (rec.dispute.challenger = actor1) "challenger preserved"
          assert (rec.idx = threeEntryLog.length) "idx is log.length"
          match rec.status with
          | .open => pure ()
          | _ => throw <| IO.userError "status should be .open"
        | .error e => throw <| IO.userError s!"expected .ok, got .error {repr e}"
    }
  , { name := "fileDispute: doubleApply succeeds when both indices in range"
    , body := do
        let d : Dispute :=
          { challenger := actor1
            claim      := .doubleApply 0 2
            evidence   := ⟨#[]⟩
            nonce      := 0
            sig        := ⟨#[]⟩ }
        match fileDispute baseEs threeEntryLog d with
        | .ok rec =>
          assert (rec.idx = threeEntryLog.length) "idx is log.length"
          match rec.status with
          | .open => pure ()
          | _ => throw <| IO.userError "status should be .open"
        | .error e => throw <| IO.userError s!"expected .ok, got .error {repr e}"
    }
  ]

/-! ## fileDispute error paths -/

/-- Sub-suite: error paths. -/
def errorPathTests : List TestCase :=
  [ { name := "fileDispute: unknownChallenger when challenger not registered"
    , body := do
        let d : Dispute :=
          { challenger := actor2  -- not registered in baseEs
            claim      := .preconditionFalse 0
            evidence   := ⟨#[]⟩
            nonce      := 0
            sig        := ⟨#[]⟩ }
        match fileDispute baseEs threeEntryLog d with
        | .error .unknownChallenger => pure ()
        | other => throw <| IO.userError s!"expected .unknownChallenger, got {repr other}"
    }
  , { name := "fileDispute: indexOutOfRange for primary index"
    , body := do
        let d : Dispute :=
          { challenger := actor1
            claim      := .preconditionFalse 99  -- out of range
            evidence   := ⟨#[]⟩
            nonce      := 0
            sig        := ⟨#[]⟩ }
        match fileDispute baseEs threeEntryLog d with
        | .error (.indexOutOfRange idx logLen) =>
          assert (idx = 99) "idx in error"
          assert (logLen = threeEntryLog.length) "logLen in error"
        | other => throw <| IO.userError s!"expected .indexOutOfRange, got {repr other}"
    }
  , { name := "fileDispute: indexOutOfRange for secondary doubleApply index"
    , body := do
        let d : Dispute :=
          { challenger := actor1
            claim      := .doubleApply 0 99  -- secondary out of range
            evidence   := ⟨#[]⟩
            nonce      := 0
            sig        := ⟨#[]⟩ }
        match fileDispute baseEs threeEntryLog d with
        | .error (.indexOutOfRange idx _) =>
          assert (idx = 99) "secondary idx in error"
        | other => throw <| IO.userError s!"expected .indexOutOfRange, got {repr other}"
    }
  -- AR.19: term-level API stability for the new named rejection
  -- theorems.  Elaboration failure is the failure mode.
  , { name := "fileDispute_rejects_indexOutOfRange: term-level API stability"
    , body := do
        let _proof : ∀ (es : ExtendedState) (log : List LogEntry)
                       (d : Dispute) (k : Authority.PublicKey),
                       es.registry[d.challenger]? = some k →
                       claimImpugnedIdx d.claim ≥ log.length →
                       fileDispute es log d =
                         .error (.indexOutOfRange (claimImpugnedIdx d.claim)
                                                  log.length) :=
          fileDispute_rejects_indexOutOfRange
        pure ()
    }
  , { name := "fileDispute_rejects_duplicateDispute: term-level API stability"
    , body := do
        let _proof : ∀ (es : ExtendedState) (log : List LogEntry)
                       (d : Dispute) (k : Authority.PublicKey)
                       (priorIdx : LogIndex),
                       es.registry[d.challenger]? = some k →
                       claimImpugnedIdx d.claim < log.length →
                       (∀ s, claimSecondaryIdx d.claim = some s → s < log.length) →
                       findPriorDisputeIdx d log = some priorIdx →
                       fileDispute es log d = .error (.duplicateDispute priorIdx) :=
          fileDispute_rejects_duplicateDispute
        pure ()
    }
  ]

/-! ## claimImpugnedIdx / claimSecondaryIdx projections -/

/-- Sub-suite: projection correctness. -/
def projectionTests : List TestCase :=
  [ { name := "claimImpugnedIdx: preconditionFalse projects idx"
    , body := do
        assert (claimImpugnedIdx (.preconditionFalse 7) = 7) "preconditionFalse"
    }
  , { name := "claimImpugnedIdx: doubleApply projects idx₁"
    , body := do
        assert (claimImpugnedIdx (.doubleApply 3 5) = 3) "doubleApply primary"
    }
  , { name := "claimSecondaryIdx: doubleApply projects idx₂"
    , body := do
        assert (claimSecondaryIdx (.doubleApply 3 5) = some 5) "doubleApply secondary"
    }
  , { name := "claimSecondaryIdx: non-doubleApply returns none"
    , body := do
        assert (claimSecondaryIdx (.preconditionFalse 3) = none) "preconditionFalse: no secondary"
        assert (claimSecondaryIdx (.signatureInvalid 3) = none) "signatureInvalid: no secondary"
    }
  ]

/-! ## applyWithdraw idempotency (WU 6.11) -/

/-- Sub-suite: idempotency. -/
def idempotencyTests : List TestCase :=
  [ { name := "applyWithdraw on .open transitions to .withdrawn"
    , body := do
        match applyWithdraw .open with
        | .withdrawn => pure ()
        | _ => throw <| IO.userError "expected .withdrawn"
    }
  , { name := "applyWithdraw on .withdrawn is a no-op"
    , body := do
        match applyWithdraw .withdrawn with
        | .withdrawn => pure ()
        | _ => throw <| IO.userError "expected .withdrawn (no-op)"
    }
  , { name := "applyWithdraw on .decided is a no-op (idempotency)"
    , body := do
        match applyWithdraw (.decided .upheld) with
        | .decided .upheld => pure ()
        | _ => throw <| IO.userError "expected .decided .upheld (no-op)"
    }
  , { name := "double withdraw is equivalent to single withdraw"
    , body := do
        let s1 := applyWithdraw .open
        let s2 := applyWithdraw s1
        assert (s1 == s2) "applyWithdraw idempotent"
    }
  , { name := "applyWithdraw_idempotent API stability"
    , body := do
        let _proof : ∀ s : DisputeStatus, applyWithdraw (applyWithdraw s) = applyWithdraw s :=
          applyWithdraw_idempotent
        pure ()
    }
  ]

/-! ## disputeStatus derivation -/

/-! Build a 3-entry log with a dispute at index 1 followed by a
    verdict at index 2.  Verify `disputeStatus log 1 = some .decided
    .upheld`. -/

/-- A log fragment: `[transfer]` + `[dispute]` + `[verdict]`. -/
def disputeAndVerdictLog : List LogEntry :=
  let disputeEntry : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction :=
        { action := .dispute disputeAgainst1
          signer := actor1
          nonce  := 0
          sig    := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  let verdictEntry : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction :=
        { action :=
            .verdict { disputeId := 1, outcome := .upheld
                       rationale := ⟨#[]⟩, signatures := [] }
          signer := actor1, nonce := 1, sig := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  [fixtureLogEntry, disputeEntry, verdictEntry]

/-- Sub-suite: disputeStatus. -/
def disputeStatusTests : List TestCase :=
  [ { name := "disputeStatus: returns none for non-dispute log entry"
    , body := do
        match disputeStatus threeEntryLog 0 with
        | none => pure ()
        | _ => throw <| IO.userError "expected none for non-dispute entry"
    }
  , { name := "disputeStatus: returns .decided .upheld after upheld verdict"
    , body := do
        match disputeStatus disputeAndVerdictLog 1 with
        | some (.decided .upheld) => pure ()
        | other => throw <| IO.userError s!"expected .decided .upheld, got {repr other}"
    }
  ]

/-! ## Aggregate -/

/-- All Phase 6 filing tests. -/
def tests : List TestCase :=
  happyPathTests ++ errorPathTests ++ projectionTests ++
  idempotencyTests ++ disputeStatusTests

end LegalKernel.Test.Disputes.FilingTests
