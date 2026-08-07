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
import LegalKernel.FaultProof.VerifierWrites
import LegalKernel.FaultProof.Terminate
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
                 , .depositWithFee 1 8 9 4 1 2 3 1
                 , .topUpActionBudget 1 5 2 9
                 , .topUpActionBudgetFor 8 1 5 2 9
                 , .claimBudgetRefund 1 2 1 9
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
  , { name := "a bulk action's write set covers every cell it moves"
    , body := do
        -- The inversion that S3 landed.  This test previously asserted
        -- the OPPOSITE — that `distributeOthers` moves balance cells
        -- its write set omits — because the write set was the static
        -- `Action.writeCells`, which cannot name a recipient.  It is
        -- now `writeCellsAt`, which takes the state and enumerates
        -- `Laws.bulkRecipients`, so nothing escapes.
        --
        -- Value-level rather than a restatement of
        -- `writeSetComplete_productionApplyBudget`: the theorem
        -- quantifies over all cells, and a probe over concrete
        -- recipients catches an enumeration that drifted from the
        -- fold's own order or filter.
        for bulk in [Authority.Action.distributeOthers 1 7 30,
                     .proportionalDilute 1 7 30] do
          let post := productionApplyBudget base (sign bulk) 0
          let declared := Authority.Action.writeCellsAt base bulk 7
          let escaped := [CellTag.balance 1 7, .balance 1 8, .balance 1 9,
                          .balance 1 20, .balance 2 8].filter (fun t =>
            !declared.contains t &&
              (getCellValue post t).toList != (getCellValue base t).toList)
          assert escaped.isEmpty
            s!"{repr bulk} moved a balance cell outside its write set: {repr escaped}"
    }
  , { name := "a bulk write set names exactly the credited actors"
    , body := do
        -- ...and it must not over-declare either: a write set naming a
        -- cell the advance leaves alone still folds correctly (the
        -- write is a no-op), but it costs the L1 an opening per phantom
        -- cell, and a cap is what stands between that and a step no
        -- honest sequencer can afford to defend.
        let bulk : Authority.Action := .distributeOthers 1 7 30
        let declared := Authority.Action.writeCellsAt base bulk 7
        let recipients := Laws.bulkRecipients base.base 1 7
        assertEq (expected := recipients.length + 2)
          (actual := declared.length)
          "declared = nonce + epochBudget + one cell per recipient"
        -- The excluded actor is not credited, so it is not written.
        assert (!declared.contains (CellTag.balance 1 7))
          "the excluded actor must not be in the write set"
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
  , { name := "OBLIGATION: a bulk write set is not verifiable from the root"
    , body := do
        -- **The write set is complete; a VERIFIER cannot check that.**
        --
        -- `writeSetComplete_productionApplyBudget` says the advance
        -- moves no cell `writeCellsAt` omits.  That is a statement
        -- about the HONEST bundle.  An L1 holding only the pre-root
        -- and a submitted bundle checks the openings it is given — and
        -- a bundle that DROPS a recipient opens a perfectly valid set,
        -- because the dropped cell is simply not mentioned and
        -- `smtCellKey` hashes the cell identity, so no subtree
        -- argument enumerates a resource's actors.
        --
        -- Stated on the MERGED walk, which is the live machinery: the
        -- obligation is about the SMT's inability to enumerate, not
        -- about any particular fold.
        --
        -- Resolved by EXCLUSION rather than by proof:
        -- `FaultProofAdjudicable` is false on exactly the two bulk
        -- variants, so a deployment leaning on the fault proof must
        -- not authorise them.  See
        -- `docs/planning/state_root_merkleisation_plan.md` §4 step 3.
        let bulk : Authority.Action := .distributeOthers 1 7 30
        let post := productionApplyBudget base (sign bulk) 0
        let ts := Authority.Action.writeCellsAt base bulk 7
        -- Drop the LAST declared cell.  Every remaining opening is
        -- untouched, so the short bundle's own wire is consistent.
        let short := ts.take (ts.length - 1)
        assert (short.length + 1 == ts.length) "the probe dropped exactly one cell"
        let walkOf : List CellTag → Option (StateCommit × List ByteArray) := fun cells =>
          multiWalk smtDepth (openedOf post cells)
            (multiSiblings smtDepth (stateCellEntries base) (openedOf base cells))
        match walkOf ts, walkOf short with
        | some (honestRoot, _), some (shortRoot, _) =>
          assert (shortRoot.toList != honestRoot.toList)
            "an incomplete bulk bundle must reach a DIFFERENT root"
          -- ...and that is the whole problem: the walk ACCEPTED it.
          -- A verifier with only the pre-root has seen nothing wrong.
          assert true "the short bundle walked successfully"
        | _, none =>
          throw <| IO.userError
            "the walk rejected the short bundle — if this ever becomes \
             true the obligation is discharged and this test should be \
             rewritten as the positive property"
        | none, _ =>
          throw <| IO.userError "the honest bundle failed to walk"
    }
  , { name := "OBLIGATION: a no-op step must fold to the pre-root, not revert"
    , body := do
        -- `step_impl` is `if pre then apply_impl else id`, so an
        -- action whose precondition fails advances nothing and its
        -- post-root IS the pre-root.  The multiproof gets this right:
        -- every declared cell is written back with its own value.
        --
        -- Solidity's `_stepTransfer` REVERTS (`InsufficientBalance`)
        -- on the same input.  Today that is invisible, because
        -- `Runtime.processSignedAction` only appends an entry when
        -- `AdmissibleWith` holds — and conjunct 5 of that predicate
        -- IS the transition's precondition, so no honestly-produced
        -- log entry has a failing `pre`.
        --
        -- It stops being invisible at the flip.  A DISHONEST
        -- sequencer can bind an inadmissible action into the
        -- log-entry chain, and `terminateOnSingleStep` may then be
        -- reached on the CHALLENGER's turn (the turn alternates
        -- through `respondToMidpoint`).  A revert is not a verdict:
        -- the responsible party simply cannot call, and loses by
        -- timeout.  Any input on which `executeStep` reverts is a
        -- weapon against whoever's turn it is.
        --
        -- So the flip owes one of two things: `executeStep` total
        -- over well-formed inputs, returning the pre-root when the
        -- precondition fails; or a terminal step either party may
        -- call.  Pinned here as the Lean-side expectation the L1 must
        -- match.
        let noop : Authority.Action := .transfer 1 7 8 999999999
        let post := productionApplyBudget base (sign noop) 0
        -- The base state is untouched: no balance moved.
        assertEq (expected := (getCellValue base (CellTag.balance 1 7)).toList)
          (actual := (getCellValue post (CellTag.balance 1 7)).toList)
          "a failing precondition must not move the sender's balance"
        -- ...but the nonce and budget still advance, so the post-root
        -- is NOT simply the pre-root, and the fold must produce it.
        match stepMultiPostRoot base (sign noop) 0 with
        | some root =>
          assertEq (expected := (commitExtendedState post).toList)
            (actual := root.toList)
            "the fold must land on the no-op advance's root"
        | none =>
          throw <| IO.userError "the fold rejected a no-op step"
    }
  , { name := "the verifier derives the nonce write from the proven cell"
    , body := do
        -- §4 step 3 for the one cell every action writes.  Value-level
        -- because the theorem quantifies over states, and the drift
        -- that matters is definitional: a change to the nonce cell's
        -- encoding or to `expectsNonce` would keep the theorem true
        -- and move the bytes.
        for action in [ Authority.Action.transfer 1 7 8 30
                      , .mint 1 8 5
                      , .freezeResource 1
                      , .withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero
                      , .distributeOthers 1 7 30 ] do
          let st := sign action
          let post := productionApplyBudget base st 0
          match deriveNonceCellValue (getCellValue base (CellTag.nonce st.signer)) with
          | some derived =>
            assertEq
              (expected := (getCellValue post (CellTag.nonce st.signer)).toList)
              (actual := derived.toList)
              s!"derived nonce write ≠ the advance's, for {repr action}"
          | none =>
            throw <| IO.userError
              s!"the derivation refused an honest nonce cell for {repr action}"
    }
  , { name := "the nonce derivation is fail-closed on a bad pre-value"
    , body := do
        -- Both refusal cases, because an implementation that decoded
        -- and ignored the residual would pass the happy path and the
        -- malformed one while accepting a padded cell — and two
        -- distinct bundles deriving the same write is exactly what
        -- lets a responder choose.
        assertEq (expected := (none : Option (List UInt8)))
          (actual := (deriveNonceCellValue (ByteArray.mk #[0xFF, 0x00])).map
            (fun b => b.toList))
          "garbage bytes must derive nothing"
        let honest := getCellValue base (CellTag.nonce 7)
        let padded := honest ++ ByteArray.mk #[0x00]
        assertEq (expected := (none : Option (List UInt8)))
          (actual := (deriveNonceCellValue padded).map (fun b => b.toList))
          "a trailing byte must derive nothing"
        -- ...and the unpadded value still works, so the check above is
        -- rejecting the padding rather than everything.
        assert (deriveNonceCellValue honest |>.isSome)
          "the honest cell must still derive"
    }
  , { name := "the epoch-budget equation holds on the three branches"
    , body := do
        -- `productionApplyBudget_epochBudgets_eq` at the value level,
        -- exercised on each branch, because the branch SELECTION is
        -- what an implementer gets wrong: a grant applied to the
        -- pre-consume budgets would let a top-up pay for itself, and a
        -- refused consume that still granted would hand budget to an
        -- actor who could not afford the step.
        let policyOf (es : ExtendedState) : Nat × Nat × Nat :=
          match es.budgetPolicy with
          | .bounded ft ac ce => (ft, ac, ce)
        let (freeTier, actionCost, currentEpoch) := policyOf base
        for action in [ Authority.Action.transfer 1 7 8 30
                      , .topUpActionBudget 1 5 2 9
                      , .mint 1 8 5 ] do
          let st := sign action
          let post := productionApplyBudget base st 0
          let expected : EpochBudgetState :=
            if st.signer = LegalKernel.Bridge.bridgeActor then
              budgetGrant st.signer st.action freeTier currentEpoch base.epochBudgets
            else
              match EpochBudgetState.consume base.epochBudgets st.signer
                      currentEpoch freeTier
                      (actionCost + refundConsumeExtra st.action) with
              | none      => base.epochBudgets
              | some ebs' => budgetGrant st.signer st.action freeTier currentEpoch ebs'
          assertEq (expected := (expected[st.signer]?.getD ActorBudget.empty).budgetBalance)
            (actual := (post.epochBudgets[st.signer]?.getD
              ActorBudget.empty).budgetBalance)
            s!"epoch-budget equation diverged for {repr action}"
        -- The refused-consume branch, reached by a policy whose free
        -- tier cannot cover the cost.  Without this the loop above only
        -- ever exercises the succeeding consume.
        let starved : ExtendedState := { base with budgetPolicy := .bounded 0 9999 3 }
        let st := sign (Authority.Action.transfer 1 7 8 30)
        let post := productionApplyBudget starved st 0
        assertEq
          (expected := (starved.epochBudgets[st.signer]?.getD
            ActorBudget.empty).budgetBalance)
          (actual := (post.epochBudgets[st.signer]?.getD
            ActorBudget.empty).budgetBalance)
          "a refused consume must leave the budgets entirely alone"
    }
  , { name := "the verifier derives the epoch-budget write from proven cells"
    , body := do
        -- The second cell every action writes, byte-for-byte, and over
        -- BOTH targets that can move: the signer (the consume) and a
        -- grant recipient.  `topUpActionBudgetFor` is the case where
        -- those differ, which is what would break a derivation that
        -- assumed the grant always lands on the signer.
        let cases : List (Authority.Action × ActorId) :=
          [ (.transfer 1 7 8 30, 7)
          , (.mint 1 8 5, 7)
          , (.topUpActionBudget 1 5 2 9, 7)
          , (.topUpActionBudgetFor 8 1 5 2 9, 8)
          , (.topUpActionBudgetFor 8 1 5 2 9, 7) ]
        for (action, target) in cases do
          let st := sign action
          let post := productionApplyBudget base st 0
          match deriveEpochBudgetCellValue
                  (getCellValue base CellTag.budgetPolicy)
                  (getCellValue base (CellTag.epochBudget st.signer))
                  (getCellValue base (CellTag.epochBudget target))
                  st.action st.signer target with
          | some derived =>
            assertEq
              (expected := (getCellValue post (CellTag.epochBudget target)).toList)
              (actual := derived.toList)
              s!"derived budget write ≠ the advance's, {repr action} at {target}"
          | none =>
            throw <| IO.userError
              s!"the derivation refused honest cells for {repr action}"
    }
  , { name := "a refused consume freezes every actor's budget"
    , body := do
        -- The branch a happy-path loop never reaches, and the one a
        -- flattened derivation gets wrong: the consume is checked
        -- against the SIGNER's budget but gates the write to EVERY
        -- actor, so a grant recipient must NOT be credited on a step
        -- the signer could not afford.
        let starved : ExtendedState := { base with budgetPolicy := .bounded 0 9999 3 }
        let action : Authority.Action := .topUpActionBudgetFor 8 1 5 2 9
        let st := sign action
        let post := productionApplyBudget starved st 0
        for target in [(7 : ActorId), 8] do
          match deriveEpochBudgetCellValue
                  (getCellValue starved CellTag.budgetPolicy)
                  (getCellValue starved (CellTag.epochBudget st.signer))
                  (getCellValue starved (CellTag.epochBudget target))
                  st.action st.signer target with
          | some derived =>
            assertEq
              (expected := (getCellValue starved (CellTag.epochBudget target)).toList)
              (actual := derived.toList)
              s!"a refused consume must leave actor {target} alone"
            assertEq
              (expected := (getCellValue post (CellTag.epochBudget target)).toList)
              (actual := derived.toList)
              s!"...and must agree with the advance at actor {target}"
          | none =>
            throw <| IO.userError "the derivation refused honest cells"
    }
  , { name := "the verifier derives every variant's balance writes"
    , body := do
        -- All twelve balance-writing variants at the value level, each
        -- against the advance's own cells.  The theorems quantify over
        -- states; what this catches is definitional drift in a law's
        -- `apply_impl` that keeps its theorem true and moves the bytes.
        let read := stateBalanceReader base
        let check (action : Authority.Action)
            (derived : Option (List ((ResourceId × ActorId) × Nat))) : IO Unit := do
          let post := productionApplyBudget base (sign action) 0
          match derived with
          | some ws =>
            for ((r, a), v) in ws do
              assertEq (expected := LegalKernel.getBalance post.base r a)
                (actual := v)
                s!"derived balance ≠ the advance's at ({r}, {a}) for {repr action}"
          | none =>
            throw <| IO.userError s!"the derivation refused honest cells for {repr action}"
        check (.transfer 1 7 8 30) (deriveTransferBalances read 1 7 8 30)
        -- The self-transfer, where the credit reads the debited state.
        check (.transfer 1 7 7 30) (deriveTransferBalances read 1 7 7 30)
        -- ...and the no-op, where the precondition fails and the L1
        -- currently reverts instead of returning the pre-values.
        check (.transfer 1 7 8 999999) (deriveTransferBalances read 1 7 8 999999)
        check (.mint 1 8 5) (deriveCreditBalance read 1 8 5)
        check (.reward 1 8 5) (deriveCreditBalance read 1 8 5)
        check (.burn 1 8 5) (deriveBurnBalance read 1 8 5)
        check (.burn 1 8 999999) (deriveBurnBalance read 1 8 999999)
        check (.deposit 1 8 5 3) (deriveDepositBalance read 1 8 5)
        check (.withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero)
          (deriveWithdrawBalance read 1 7 5)
        check (.depositWithFee 1 8 9 5 1 1 3 1)
          (deriveDepositWithFeeBalances read 1 8 9 5 1 1 Bridge.ammReserveActor)
        check (.topUpActionBudget 1 5 2 9) (deriveTopUpBalances read 1 7 9 5)
        check (.topUpActionBudgetFor 8 1 5 2 9)
          (deriveDelegatedTopUpBalances read 1 7 9 8 5)
        check (.claimBudgetRefund 1 2 3 9) (deriveRefundBalances read 1 9 7 (2 * 3))
        check (.reclaimAmmReserves 1 25 9 8) (deriveReclaimBalances read 1 9 8 25)
    }
  , { name := "a partial reader derives nothing"
    , body := do
        -- The fail-closed direction that makes the derivation an
        -- adjudicator: a cell the bundle does not open is not a zero
        -- balance, and a responder who omits an opening must not get a
        -- value of their choosing.
        let blind : BalanceReader := fun _ _ => none
        assert (deriveTransferBalances blind 1 7 8 30 |>.isNone)
          "a blind reader must derive nothing"
        assert (deriveReserveSwapBalances blind 1 2 7 5 4 9 |>.isNone)
          "...on the cross-resource variant too"
        -- Half-blind: the sender opens, the receiver does not.
        let partial_ : BalanceReader := fun r a =>
          if a == 7 then some (LegalKernel.getBalance base.base r a) else none
        assert (deriveTransferBalances partial_ 1 7 8 30 |>.isNone)
          "one missing opening must be enough to refuse"
    }
  , { name := "the verifier derives the registry, policy and bridge cells"
    , body := do
        -- The cells whose post-values come from the ACTION's own
        -- fields rather than from any proven cell — the ones an L1
        -- that ignored its declared writes would be most obviously
        -- wrong about, since the value is right there in the calldata.
        let check (action : Authority.Action) (tag : CellTag)
            (derived : ByteArray) : IO Unit := do
          let post := productionApplyBudget base (sign action) 0
          assertEq (expected := (getCellValue post tag).toList)
            (actual := derived.toList)
            s!"derived {repr tag} ≠ the advance's for {repr action}"
        let k := ByteArray.mk #[9, 9, 9]
        check (.replaceKey 7 k) (CellTag.registry 7) (deriveRegistryCellValue k)
        check (.registerIdentity 8 k) (CellTag.registry 8) (deriveRegistryCellValue k)
        check (.declareLocalPolicy Authority.LocalPolicy.empty)
          (CellTag.localPolicy 7)
          (deriveDeclaredPolicyCellValue Authority.LocalPolicy.empty)
        -- Revoke's derived value is the ABSENT marker, not an encoded
        -- empty policy: `revoke` erases the entry, and `getCellValue`
        -- keys off the map, so the two are different cell values.
        check .revokeLocalPolicy (CellTag.localPolicy 7)
          deriveRevokedPolicyCellValue
        assert (deriveRevokedPolicyCellValue.toList
                  != (deriveDeclaredPolicyCellValue
                       Authority.LocalPolicy.empty).toList)
          "revoked and declared-empty must not be the same cell value"
        check (.deposit 1 8 5 3) (CellTag.bridgeConsumed 3)
          (deriveConsumedCellValue
            { resource := 1, userAmount := 5, poolAmount := 0, budgetGrant := 0 })
        check (.depositWithFee 1 8 9 5 1 1 4 1) (CellTag.bridgeConsumed 4)
          (deriveConsumedCellValue
            { resource := 1, userAmount := 5, poolAmount := 1, budgetGrant := 1 })
        -- `withdraw`'s pending cell is keyed by the PRE-state's
        -- counter, which is itself a cell the verifier reads.
        check (.withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero)
          (CellTag.bridgePending base.bridge.nextWdId)
          (derivePendingCellValue
            { resource := 1, recipient := LegalKernel.Bridge.EthAddress.zero
            , amount := 5, l2LogIndex := 0
              -- The leaf's own claim about the key it occupies, which
              -- IS the cell key above.  Not defaultable here: `wdId`
              -- defaults to 0 because the allocator owns it at an
              -- `appendWithdrawal`, but a VERIFIER-side derivation has
              -- to state it, and the advance's value is the pre-state
              -- counter.
            , wdId := base.bridge.nextWdId })
        match deriveNextWdIdCellValue (getCellValue base CellTag.bridgeNextWdId) with
        | some derived =>
          check (.withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero)
            CellTag.bridgeNextWdId derived
        | none => throw <| IO.userError "the counter derivation refused an honest cell"
    }
  , { name := "the adjudicable predicate is exactly the bulk exclusion"
    , body := do
        -- The deployment decision, made checkable.  A gate never
        -- observed to fire is indistinguishable from an absent gate,
        -- so both directions are exercised on real actions.
        for a in [Authority.Action.transfer 1 7 8 30, .mint 1 8 5,
                  .withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero,
                  .deposit 1 8 5 3,
                  .reclaimAmmReserves 1 25 9 8] do
          assert (FaultProofAdjudicable a)
            s!"{repr a} must be adjudicable"
        for a in [Authority.Action.distributeOthers 1 7 30,
                  .proportionalDilute 1 7 30] do
          assert (!FaultProofAdjudicable a)
            s!"{repr a} must NOT be adjudicable — its write set is not \
               re-derivable from the pre-root"
        -- And the write set of an adjudicable, non-withdraw action IS
        -- the static one, which is what lets a verifier check a
        -- bundle's shape before hashing anything.
        let a : Authority.Action := .transfer 1 7 8 30
        assertEq
          (expected := (Authority.Action.writeCells a 7).map
            (fun t => repr t |>.pretty))
          (actual := (Authority.Action.writeCellsAt base a 7).map
            (fun t => repr t |>.pretty))
          "an adjudicable non-withdraw write set is static"
    }
  , { name := "API stability: the verifier-side derivation"
    , body := do
        let _nonce : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat),
            Authority.expectsNonce es st.signer < 256 ^ 8 →
            deriveNonceCellValue (getCellValue es (CellTag.nonce st.signer))
              = some (getCellValue (productionApplyBudget es st idx)
                        (CellTag.nonce st.signer)) :=
          deriveNonceCellValue_correct
        let _signer : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat),
            Authority.expectsNonce (productionApplyBudget es st idx) st.signer =
              Authority.expectsNonce es st.signer + 1 :=
          productionApplyBudget_expectsNonce_signer
        -- The epoch-budget derivation is stated for EVERY actor, not
        -- just the signer or the grant recipient.  A regression that
        -- narrowed it to one of those would fail here rather than
        -- quietly leaving the other unadjudicable.
        let _budget : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat)
            (a : ActorId),
            deriveEpochBudget es.budgetPolicy
                (es.epochBudgets[st.signer]?.getD ActorBudget.empty)
                (es.epochBudgets[a]?.getD ActorBudget.empty)
                st.action st.signer a
              = (productionApplyBudget es st idx).epochBudgets[a]?.getD
                  ActorBudget.empty :=
          deriveEpochBudget_correct
        pure ()
    }
  , { name := "API stability: WriteSetComplete signatures"
    , body := do
        -- No bulk exclusions: the write set is state-keyed, so all
        -- twenty-five variants are covered.  A regression that
        -- reintroduced the hypotheses would fail HERE rather than
        -- quietly narrowing what the game can adjudicate.
        let _complete : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat),
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
        -- The fold-level statement now lives on the multiproof
        -- (`stepMultiFold_eq_commit_post`, pinned in
        -- `faultproof-terminate`); what belongs HERE is the per-variant
        -- obligation it consumes, which is `_complete` above.
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.StepWriteSets
