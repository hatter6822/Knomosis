-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.StepWriteSets — `WriteSetComplete` on real
advances.

The theorems quantify over states; these run the production advance on
a populated `ExtendedState` and check the cells, which is what catches
definitional drift.

Three cases are worth naming because each pins something a reading of
the statements would not give:

  * the advance really MOVES the cells it declares, so a completeness
    test is not passing because nothing happened;
  * a `withdraw` moves `bridgePending` at the pre-state's counter —
    the cell `Action.writeCells` could not name, and the reason
    `Action.writeCellsAt` exists;
  * the two bulk actions are excluded by hypothesis, and the test
    exhibits WHY: a `distributeOthers` moves an actor's balance that
    no finite write set names.
-/

import LegalKernel.FaultProof.StepWriteSets
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.StepWriteSets

/-- A state with live entries across the sub-states, and a policy whose
    free tier actually admits a consume — `ExtendedState.empty`'s
    `.bounded 0 1 0` refuses every one, which is exactly how the budget
    leg went unexercised in the cross-stack corpus. -/
def base : ExtendedState :=
  let st : LegalKernel.State :=
    { balances := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
                    ((((∅ : BalanceMap).insert 7 100).insert 8 40).insert 9 25) }
  { base          := st
  , nonces        := { next := (∅ : Std.TreeMap ActorId Nonce compare).insert 7 3 }
  , registry      := (∅ : KeyRegistry).insert 7 (ByteArray.mk #[1, 2, 3])
  , bridge        := { LegalKernel.Bridge.BridgeState.empty with nextWdId := 5 }
  , epochBudgets  := (∅ : EpochBudgetState).insert 7
                       { lastSeenEpoch := 2, budgetBalance := 50 }
  , budgetPolicy  := .bounded 100 1 2 }

/-- A minimal dispute, for the kernel-identity dispute actions. -/
def probeDispute : LegalKernel.Disputes.Dispute :=
  { challenger := 7, claim := .preconditionFalse 1
  , evidence := ByteArray.empty, nonce := 0, sig := ByteArray.empty }

/-- A minimal verdict. -/
def probeVerdict : LegalKernel.Disputes.Verdict :=
  { disputeId := 1, outcome := .upheld
  , rationale := ByteArray.empty, signatures := [] }

/-- Sign an action as actor 7. -/
def sign (a : Authority.Action) : SignedAction :=
  { action := a, signer := 7, nonce := 3, sig := ByteArray.empty }

/-- Cells outside every non-bulk action's write set, spanning each
    kind — so a footprint that leaked would show up here.

    The keys are chosen disjoint from every representative action's
    parameters: resource 5 and actors 20 / 21 appear in none of them,
    deposit id 77 in none, withdrawal id 99 in none.  `checkComplete`
    ENFORCES that disjointness rather than trusting it — an earlier
    draft used actor 8, which `replaceKey 8` declares, and the guard
    caught it. -/
def probes : List CellTag :=
  [ .balance 5 20, .balance 5 7, .balance 1 21
  , .nonce 20, .nonce 21, .registry 20, .localPolicy 20
  , .bridgeConsumed 77, .bridgePending 99, .bridgeAmmReserveEth
  , .bridgeAmmReserveBold, .bridgeBoldCircuitClosed, .bridgeBoldTvlCap
  , .bridgeBoldTotalLockedValue, .bridgeAmmDisabled
  , .epochBudget 20, .budgetPolicy ]

/-- Check every probe survives one advance of `a`, and that the probe
    really is outside the declared write set. -/
def checkComplete (a : Authority.Action) : IO Unit := do
  let st := sign a
  let post := productionApplyBudget base st 0
  let declared := Authority.Action.writeCellsAt base a 7
  for t in probes do
    if declared.contains t then
      throw <| IO.userError
        s!"probe {repr t} is DECLARED for {repr a} — the test would pass vacuously"
    assertEq (expected := (getCellValue base t).toList)
      (actual := (getCellValue post t).toList)
      s!"{repr a} moved undeclared cell {repr t}"

/-- Tests. -/
def tests : List TestCase :=
  [ { name := "WriteSetComplete holds on every non-bulk action"
    , body := do
        -- One representative per constructor the theorem covers.  A
        -- footprint that escaped its declaration shows up as a moved
        -- probe cell.
        for a in [ Authority.Action.transfer 1 7 8 30
                 , .mint 1 8 5
                 , .burn 1 8 5
                 , .freezeResource 1
                 , .replaceKey 8 (ByteArray.mk #[9])
                 , .reward 1 8 5
                 , .dispute probeDispute
                 , .disputeWithdraw 0
                 , .verdict probeVerdict
                 , .rollback 0
                 , .registerIdentity 8 (ByteArray.mk #[9])
                 , .deposit 1 8 5 3
                 , .withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero
                 , .declareLocalPolicy Authority.LocalPolicy.empty
                 , .revokeLocalPolicy
                 , .faultProofChallenge ByteArray.empty 0 1 ByteArray.empty
                 , .faultProofResolution ByteArray.empty 0 1 1
                 , .depositWithFee 1 8 9 4 1 2 3
                 , .topUpActionBudget 1 5 2 9
                 , .topUpActionBudgetFor 8 1 5 2 9
                 , .claimBudgetRefund 1 2 1 9
                 , .ammSwap 1 2 5 1 8
                 , .reclaimAmmReserves 1 5 8 9 ] do
          checkComplete a
    }
  , { name := "the advance really moves the cells it declares"
    , body := do
        -- Without this, the completeness tests above would pass
        -- against an advance that did nothing at all.
        let st := sign (.transfer 1 7 8 30)
        let post := productionApplyBudget base st 0
        for t in [CellTag.balance 1 7, .balance 1 8, .nonce 7, .epochBudget 7] do
          assert ((getCellValue post t).toList != (getCellValue base t).toList)
            s!"declared cell {repr t} did NOT move"
    }
  , { name := "withdraw moves bridgePending at the pre-state's counter"
    , body := do
        -- The cell `Action.writeCells` cannot name, because its key is
        -- `es.bridge.nextWdId` rather than a field of the action.
        let wd : Authority.Action := .withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero
        let post := productionApplyBudget base (sign wd) 0
        let allocated : CellTag := .bridgePending base.bridge.nextWdId
        assert ((getCellValue post allocated).toList
                  != (getCellValue base allocated).toList)
          "the withdrawal created a pending entry"
        assert (!(Authority.Action.writeCells wd 7).contains allocated)
          "which the STATIC declaration omits"
        assert ((Authority.Action.writeCellsAt base wd 7).contains allocated)
          "and the complete set names — this is why writeCellsAt exists"
        assert ((getCellValue post .bridgeNextWdId).toList
                  != (getCellValue base .bridgeNextWdId).toList)
          "and the counter moved too"
    }
  , { name := "the bulk exclusion is not bookkeeping"
    , body := do
        -- `distributeOthers` credits every non-excluded actor, so its
        -- declared write set (nonce + budget) omits balance cells the
        -- advance moves.  The theorem excludes it by hypothesis; this
        -- exhibits the reason rather than asserting it.
        let bulk : Authority.Action := .distributeOthers 1 7 30
        let post := productionApplyBudget base (sign bulk) 0
        let declared := Authority.Action.writeCellsAt base bulk 7
        let escaped := [CellTag.balance 1 8, .balance 1 9].filter (fun t =>
          !declared.contains t && (getCellValue post t).toList != (getCellValue base t).toList)
        assert (!escaped.isEmpty)
          "distributeOthers must move a balance cell outside its write set"
    }
  , { name := "the budget policy survives every advance"
    , body := do
        -- No `Action` writes the deployment's policy.  Checked at the
        -- value level because `productionApplyBudget` reads it, and a
        -- read-then-write-back would be easy to introduce by accident.
        for a in [Authority.Action.transfer 1 7 8 30, .mint 1 8 5,
                  .topUpActionBudget 1 5 2 9, .withdraw 1 7 5
                    LegalKernel.Bridge.EthAddress.zero] do
          let post := productionApplyBudget base (sign a) 0
          assertEq (expected := (getCellValue base .budgetPolicy).toList)
            (actual := (getCellValue post .budgetPolicy).toList)
            s!"{repr a} moved the budget policy"
    }
  , { name := "API stability: WriteSetComplete signatures"
    , body := do
        let _complete : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat),
            (∀ x y z, st.action ≠ .distributeOthers x y z) →
            (∀ x y z, st.action ≠ .proportionalDilute x y z) →
            WriteSetComplete es (productionApplyBudget es st idx) st.action st.signer :=
          writeSetComplete_productionApplyBudget
        let _nonce : ∀ (es : ExtendedState) (action : Authority.Action) (signer : ActorId),
            CellTag.nonce signer ∈ Authority.Action.writeCellsAt es action signer :=
          mem_writeCellsAt_nonce
        let _budget : ∀ (es : ExtendedState) (action : Authority.Action) (signer : ActorId),
            CellTag.epochBudget signer ∈ Authority.Action.writeCellsAt es action signer :=
          mem_writeCellsAt_epochBudget
        let _policy : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat),
            (productionApplyBudget es st idx).budgetPolicy = es.budgetPolicy :=
          productionApplyBudget_budgetPolicy
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.StepWriteSets
