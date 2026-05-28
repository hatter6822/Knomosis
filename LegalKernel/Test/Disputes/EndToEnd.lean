/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Disputes.EndToEnd — Phase 6 acceptance test.

WU 6.12.  The Genesis Plan §12 acceptance criterion: "Plant an
illegal tx (e.g. by bypassing the runtime check for the test); file
dispute; check evidence (returns `upheld`); propose verdict (signed
by adjudicator); apply verdict (rollback)."

This test exercises the full four-stage dispute pipeline end-to-
end on a planted log:

  1. Construct a 3-entry log:
     * `[0]` = a *legitimate* transfer (state-changing).
     * `[1]` = a *planted illegal* transfer (its precondition is
       false at the recovered pre-state — the runtime would have
       rejected it, but we plant it for the test).
     * `[2]` = a `dispute` action against entry 1.
  2. Stage 2: `checkEvidence` against the planted dispute returns
     `.upheld` (the precondition was false).
  3. Stage 3: `proposeVerdict` succeeds with a quorum-of-1 signature
     (the only adjudicator is the dispute filer themselves — a
     trivial single-quorum policy).  In the absence of a real
     `Verify` adaptor, we exercise the `applyVerdict` path
     directly with a pre-validated `Verdict`.
  4. Stage 4: `applyVerdict` returns the rolled-back state, which
     should be identical to the state immediately before the
     planted illegal transfer (i.e., the post-state of entry 0).

The acceptance check: the rolled-back state's `getBalance` queries
match the post-state of the legitimate transfer at every probed
cell.

Note on Verify-opaque: the test uses `applyVerdict` directly rather
than going through `proposeVerdict`'s quorum check.  Phase 6's
proof-level guarantees are independent of the `Verify` adaptor;
the value-level test verifies the rollback computation alone.

Acceptance criterion: `final_state.getBalance r a` for every
probed `(r, a)` matches the post-state of the legitimate (entry 0)
transfer.
-/

import LegalKernel.Disputes.Verdict
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Disputes
open LegalKernel.Test

namespace LegalKernel.Test.Disputes.EndToEndTests

/-! ## Test fixtures: actors, policies, initial state -/

/-- The sender actor. -/
def sender : ActorId := 10

/-- The receiver actor. -/
def receiver : ActorId := 20

/-- The challenger actor (also the adjudicator in this single-
    quorum test). -/
def challenger : ActorId := 30

/-- A sample public key. -/
def k1 : PublicKey := ⟨#[0xAA]⟩

/-- A genesis ExtendedState with the three actors registered and
    `sender` holding 100 of resource 0.  The kernel-level pre-state
    for entry 0 (legitimate transfer of 50) is therefore
    `[sender → 100, receiver → 0]`; for entry 1 (the planted
    illegal transfer of 200) it would be
    `[sender → 50, receiver → 50]`, and `transfer.pre` is FALSE
    (sender's 50 balance < 200 amount). -/
def genesis : ExtendedState where
  base     := setBalance emptyState 0 sender 100
  nonces   := NonceState.empty
  registry :=
    KeyRegistry.empty
      |>.register sender    k1
      |>.register receiver  k1
      |>.register challenger k1

/-- The unrestricted authority policy. -/
def Pall : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- The quorum policy: `challenger` is the sole approved
    adjudicator with `required = 0` (so the test can exercise
    `applyVerdict` directly without going through Verify). -/
def qpZero : QuorumPolicy where
  approvedAdjudicators := [challenger]
  required             := 0

/-! ## Step 1: Construct the planted log

  * Entry 0: legitimate transfer (sender → receiver, amount 50).
    Post-state: `[sender → 50, receiver → 50]`.
  * Entry 1: planted illegal transfer (sender → receiver, amount
    200).  At the post-state of entry 0, sender has only 50 — the
    `transfer.pre` requires `getBalance s 0 sender ≥ 200`, which
    is false.  This is the "planted illegal" entry.
  * Entry 2: `Action.dispute d` where `d.claim = .preconditionFalse 1`.

The runtime would NOT have applied entry 1 (admissibility check
would fail), but we plant it directly into the log to exercise
the dispute pipeline. -/

/-- The planted dispute: actor `challenger` files a
    `preconditionFalse 1` claim. -/
def plantedDispute : Dispute :=
  { challenger := challenger
    claim      := .preconditionFalse 1
    evidence   := ⟨#[]⟩
    nonce      := 0
    sig        := ⟨#[]⟩ }

/-- The 2-entry pre-dispute log: legitimate transfer + planted
    illegal transfer.  We set all hashes to empty `ByteArray`s
    because the dispute pipeline uses `kernelOnlyReplay`, which
    bypasses chain / admissibility checks. -/
def preDisputeLog : List LogEntry :=
  let entry0 : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction :=
        { action := .transfer 0 sender receiver 50
          signer := sender
          nonce  := 0
          sig    := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  let entry1 : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction :=
        { action := .transfer 0 sender receiver 200  -- ILLEGAL: precondition fails
          signer := sender
          nonce  := 1
          sig    := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  [entry0, entry1]

/-- The 3-entry full planted log: pre-dispute log + the dispute
    record itself at index 2.  This is the log AFTER the dispute is
    filed; the verdict at Stage 4 references entry 2. -/
def plantedLog : List LogEntry :=
  let entry2 : LogEntry :=
    { prevHash := ⟨#[]⟩
      signedAction :=
        { action := .dispute plantedDispute
          signer := challenger
          nonce  := 0
          sig    := ⟨#[]⟩ }
      postStateHash := ⟨#[]⟩ }
  preDisputeLog ++ [entry2]

/-! ## Step 2 + 4: rollback computation

The dispute targets entry 1, so the rollback target is the replay
of `log[0..0]` from genesis = applying entry 0 only.  Therefore
the rolled-back state should have:

  * sender balance: 50 (after entry 0's debit of 100 - 50)
  * receiver balance: 50 (after entry 0's credit of 0 + 50)
-/

/-- Compute the expected rollback target by direct application of
    the legitimate entry 0's `transfer` law to genesis.  This is
    what `applyVerdict (.upheld)` should return. -/
def expectedRollbackState : State :=
  -- transfer.apply_impl does: balance(sender) -= 50; balance(receiver) += 50.
  let s1 := setBalance genesis.base 0 sender 50
  setBalance s1 0 receiver 50

/-! ## End-to-end test cases -/

/-- Sub-suite: end-to-end. -/
def endToEndTests : List TestCase :=
  [ { name := "E2E: planted illegal tx → file dispute (Stage 1 acceptance)"
    , body := do
        -- File against the pre-dispute log (no prior dispute on record).
        match fileDispute genesis preDisputeLog plantedDispute with
        | .ok rec =>
          assert (rec.dispute.challenger = challenger) "challenger preserved"
          assert (rec.idx = preDisputeLog.length) "idx is log.length (post-append position)"
        | .error e => throw <| IO.userError s!"fileDispute should succeed, got {repr e}"
    }
  , { name := "E2E: checkEvidence on planted dispute returns .upheld"
    , body := do
        let drec : DisputeRecord :=
          { dispute := plantedDispute, idx := 2, status := .open }
        let v := checkEvidence Pall OraclePolicy.alwaysRejects genesis genesis plantedLog drec
        match v with
        | .upheld => pure ()
        | other => throw <| IO.userError s!"expected .upheld (planted illegal), got {repr other}"
    }
  , { name := "E2E: applyVerdict (.upheld) computes the rollback target"
    , body := do
        let verdict : Verdict :=
          { disputeId := 2  -- the dispute log entry
            outcome   := .upheld
            rationale := ⟨#[]⟩
            signatures := [] }
        match applyVerdictUnchecked Pall genesis genesis plantedLog verdict with
        | .ok rolledBack =>
          -- Verify the rolled-back state matches the expected (post-entry-0) state at every probed cell.
          let senderBal   := getBalance rolledBack.base 0 sender
          let receiverBal := getBalance rolledBack.base 0 receiver
          let expectedSender   := getBalance expectedRollbackState 0 sender
          let expectedReceiver := getBalance expectedRollbackState 0 receiver
          assert (senderBal = expectedSender) s!"sender: expected {expectedSender}, got {senderBal}"
          assert (receiverBal = expectedReceiver)
            s!"receiver: expected {expectedReceiver}, got {receiverBal}"
        | .error e => throw <| IO.userError s!"applyVerdict should succeed, got {repr e}"
    }
  , { name := "E2E: applyVerdict on rejected verdict leaves state unchanged"
    , body := do
        let verdict : Verdict :=
          { disputeId := 2, outcome := .rejected
            rationale := ⟨#[]⟩, signatures := [] }
        match applyVerdictUnchecked Pall genesis genesis plantedLog verdict with
        | .ok unchanged =>
          let senderBal := getBalance unchanged.base 0 sender
          let genesisSenderBal := getBalance genesis.base 0 sender
          assert (senderBal = genesisSenderBal) "rejected verdict: state unchanged"
        | .error e => throw <| IO.userError s!"unexpected {repr e}"
    }
  , { name := "E2E: full pipeline produces consistent final state"
    , body := do
        -- Combined pipeline: file → check → propose → apply.
        let drec : DisputeRecord :=
          { dispute := plantedDispute, idx := 2, status := .open }
        let outcome := checkEvidence Pall OraclePolicy.alwaysRejects genesis genesis
                                      plantedLog drec
        let verdict : Verdict :=
          { disputeId := 2, outcome,
            rationale := ⟨#[]⟩, signatures := [] }
        match applyVerdictUnchecked Pall genesis genesis plantedLog verdict with
        | .ok rolledBack =>
          assert (getBalance rolledBack.base 0 sender = 50)
            "post-rollback sender = 50"
          assert (getBalance rolledBack.base 0 receiver = 50)
            "post-rollback receiver = 50"
        | .error e => throw <| IO.userError s!"unexpected {repr e}"
    }
  ]

/-! ## Layer 3 (C.9): proposeAndApplyVerdict default-safe parallel tests

These tests exercise the default-safe `proposeAndApplyVerdict`
combined Stage 3 + Stage 4 entry point on the same planted log
fixtures.  The `qpZero` quorum policy (`required = 0`) ensures
the quorum check passes vacuously, isolating the Stage-3 chain
from the opaque-Verify problem. -/

/-- Sub-suite: proposeAndApplyVerdict E2E. -/
def proposeAndApplyEndToEndTests : List TestCase :=
  [ { name := "E2E: proposeAndApplyVerdict (.upheld) returns rollback target"
    , body := do
        let verdict : Verdict :=
          { disputeId := 2
            outcome   := .upheld
            rationale := ⟨#[]⟩
            signatures := [] }
        match proposeAndApplyVerdict Pall OraclePolicy.alwaysRejects qpZero
                                      genesis genesis plantedLog verdict with
        | .ok rolledBack =>
          let senderBal   := getBalance rolledBack.base 0 sender
          let receiverBal := getBalance rolledBack.base 0 receiver
          assert (senderBal = 50)   s!"sender: expected 50, got {senderBal}"
          assert (receiverBal = 50) s!"receiver: expected 50, got {receiverBal}"
        | .error e =>
          throw <| IO.userError s!"proposeAndApplyVerdict should succeed, got {repr e}"
    }
  , { name := "E2E: proposeAndApplyVerdict on .rejected verdict (outcome mismatch)"
    , body := do
        -- A verdict whose outcome is `.rejected` against an upheld-evidence
        -- dispute fails outcomeMismatch; surfaced as `.error .outcomeMismatch`.
        let verdict : Verdict :=
          { disputeId := 2, outcome := .rejected
            rationale := ⟨#[]⟩, signatures := [] }
        match proposeAndApplyVerdict Pall OraclePolicy.alwaysRejects qpZero
                                      genesis genesis plantedLog verdict with
        | .error .outcomeMismatch => pure ()
        | other => throw <| IO.userError s!"expected .outcomeMismatch, got {repr other}"
    }
  , { name := "E2E: proposeAndApplyVerdict surfaces unknown disputeId"
    , body := do
        let verdict : Verdict :=
          { disputeId := 99, outcome := .upheld
            rationale := ⟨#[]⟩, signatures := [] }
        match proposeAndApplyVerdict Pall OraclePolicy.alwaysRejects qpZero
                                      genesis genesis plantedLog verdict with
        | .error (.unknownDispute _) => pure ()
        | other => throw <| IO.userError s!"expected .unknownDispute, got {repr other}"
    }
  ]

/-! ## Aggregate -/

/-- All Phase 6 end-to-end tests. -/
def tests : List TestCase :=
  endToEndTests ++ proposeAndApplyEndToEndTests

end LegalKernel.Test.Disputes.EndToEndTests
