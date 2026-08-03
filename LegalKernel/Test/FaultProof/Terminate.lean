-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Terminate — the openings-only verifier
against the sequencer's fold.

`verifierPostRoot` holds a pre-root and a bundle; `stepPostRoot` holds
the state.  The property that matters is that they AGREE on the honest
bundle — otherwise an honest sequencer's bundle would not verify, which
is the failure the whole workstream exists to remove — and that the
verifier refuses every dishonest one.

The negative cases are the point.  A verifier that agreed on the honest
bundle and accepted everything else would pass the first test and be
worthless: it would let a responder fold to a root of their choosing.
-/

import LegalKernel.FaultProof.CellStore
import LegalKernel.FaultProof.Terminate
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Terminate

/-- A populated two-resource state with a policy whose free tier
    actually admits a consume.  The same base the cross-stack
    write-bundle goldens use, for the same reason: over an empty one
    the interesting variants no-op and every check passes vacuously. -/
def base : ExtendedState :=
  let st : LegalKernel.State :=
    { balances :=
        ((∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
           ((((∅ : BalanceMap).insert 7 100).insert 8 40).insert 9 25)).insert 2
           ((∅ : BalanceMap).insert 9 60) }
  { base          := st
  , nonces        := { next := (∅ : Std.TreeMap ActorId Nonce compare).insert 7 3 }
  , registry      := (∅ : KeyRegistry).insert 7 (ByteArray.mk #[1, 2, 3])
  , bridge        := { LegalKernel.Bridge.BridgeState.empty with nextWdId := 5 }
  , epochBudgets  := (∅ : EpochBudgetState).insert 7
                       { lastSeenEpoch := 2, budgetBalance := 50 }
  , budgetPolicy  := .bounded 100 1 2 }

/-- Sign an action as actor 7. -/
def sign (a : Authority.Action) : SignedAction :=
  { action := a, signer := 7, nonce := 3, sig := ByteArray.empty }

/-- The probe set.  Every distinct SHAPE the verifier has to handle,
    not every variant: the two-cell chain and its coinciding case, the
    failing precondition, the state-keyed cell, the duplicate
    epoch-budget cell, the two-resource swap, and each of the
    action-field-derived cells. -/
def probes : List (String × Authority.Action) :=
  [ ("transfer",            .transfer 1 7 8 30)
    -- Two writes at the SAME cell: the second opening is against the
    -- root the first produced, and both must land the same value.
  , ("selfTransfer",        .transfer 1 7 7 30)
  , ("mint",                .mint 1 8 5)
  , ("burn",                .burn 1 8 5)
    -- The precondition FAILS, so `step_impl` is the identity on the
    -- balances and the fold still has to reach the published root.
  , ("burnNoop",            .burn 1 8 999999)
  , ("reward",              .reward 1 8 5)
  , ("freezeResource",      .freezeResource 1)
  , ("withdraw",            .withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero)
  , ("deposit",             .deposit 1 8 5 3)
  , ("depositWithFee",      .depositWithFee 1 8 9 5 2 3 4)
    -- The recipient IS the signer, so the epoch-budget cell appears
    -- twice in the write set.
  , ("depositWithFeeSelf",  .depositWithFee 1 7 9 5 2 3 5)
  , ("topUpActionBudget",   .topUpActionBudget 1 10 4 9)
    -- The delegated form's `recipient ≠ payer` conjunct FAILS.
  , ("topUpActionBudgetForSelf", .topUpActionBudgetFor 7 1 10 4 9)
  , ("topUpActionBudgetFor", .topUpActionBudgetFor 8 1 10 4 9)
    -- The chain runs pool-first while the write set leads with the
    -- claimant: the two orders are opposite, and a verifier that
    -- confused them computes the mirror of the law.
  , ("claimBudgetRefund",   .claimBudgetRefund 1 2 3 9)
  , ("ammSwap",             .ammSwap 1 2 5 10 9)
  , ("registerIdentity",    .registerIdentity 8 (ByteArray.mk #[1, 2, 3]))
  , ("replaceKey",          .replaceKey 8 (ByteArray.mk #[0xAA, 0xBB]))
  , ("declareLocalPolicy",  .declareLocalPolicy Authority.LocalPolicy.empty)
  , ("revokeLocalPolicy",   .revokeLocalPolicy) ]

/-- Run the verifier on the honest bundle for one probe. -/
def runProbe (a : Authority.Action) : Option StateCommit :=
  let st := sign a
  verifierPostRoot (commitExtendedState base) a st.signer 0
    (policyOpening base) (stepOpenings base st 0)

/-- Tests. -/
def coreTests : List TestCase :=
  [ { name := "the verifier reaches the sequencer's post-root on every probe"
    , body := do
        for (name, a) in probes do
          let st := sign a
          let expected := stepPostRoot base st 0
          -- `stepPostRoot` itself must succeed, or the comparison
          -- below would be `none = none` and say nothing.
          if expected.isNone then
            throw <| IO.userError s!"{name}: the sequencer's fold aborted"
          assertEq (expected := expected.map ByteArray.toList)
            (actual := (runProbe a).map ByteArray.toList)
            s!"{name}: the verifier and the sequencer disagree"
    }
  , { name := "every probe MOVES the root"
    , body := do
        -- Without this the agreement above would be satisfied by a
        -- verifier that returned its input: every action advances the
        -- signer's nonce, so no probe's post-root is its pre-root —
        -- including the two whose LAW no-ops.
        for (name, a) in probes do
          let got := runProbe a
          if got = some (commitExtendedState base) then
            throw <| IO.userError s!"{name}: the fold left the root alone"
    }
  , { name := "a forged pre-value is refused"
    , body := do
        -- The opening is verified against the RUNNING root with a leaf
        -- built from exactly the submitted bytes, so claiming a
        -- balance the state does not hold fails the walk rather than
        -- deriving a post-value of the responder's choosing.
        let a := Authority.Action.transfer 1 7 8 30
        let st := sign a
        let ops := stepOpenings base st 0
        let forged := ops.map (fun o =>
          match o.cellTag with
          | .balance 1 7 =>
            { o with preValue :=
                ByteArray.mk (Encoding.encodeAmount 1000000).toArray }
          | _ => o)
        let got := verifierPostRoot (commitExtendedState base) a st.signer 0
          (policyOpening base) forged
        assertEq (expected := true) (actual := got.isNone)
          "a forged balance pre-value was accepted"
    }
  , { name := "omitting a write is refused"
    , body := do
        -- The forgery the re-derived cell list exists to stop: a
        -- shorter bundle folds to a root where the dropped cell never
        -- moved, which the publishing sequencer could then defend.
        let a := Authority.Action.transfer 1 7 8 30
        let st := sign a
        let ops := stepOpenings base st 0
        let got := verifierPostRoot (commitExtendedState base) a st.signer 0
          (policyOpening base) ops.dropLast
        assertEq (expected := true) (actual := got.isNone)
          "a short bundle was accepted"
    }
  , { name := "reordering the bundle is refused"
    , body := do
        -- Order is consensus, not convention: the openings are
        -- CHAINED, so opening `i` is only valid against the root write
        -- `i-1` produced.
        let a := Authority.Action.transfer 1 7 8 30
        let st := sign a
        let ops := stepOpenings base st 0
        let got := verifierPostRoot (commitExtendedState base) a st.signer 0
          (policyOpening base) ops.reverse
        assertEq (expected := true) (actual := got.isNone)
          "a reordered bundle was accepted"
    }
  , { name := "a policy opening naming another cell is refused"
    , body := do
        -- The policy selects the branch every epoch-budget write
        -- takes, so a responder able to substitute another cell's
        -- bytes for it could steer the budget leg of every action.
        let a := Authority.Action.transfer 1 7 8 30
        let st := sign a
        let bogus : CellOpening :=
          { cellTag := .nonce 7
          , preValue := getCellValue base (.nonce 7)
          , proof := buildStateCellProof base (.nonce 7) }
        let got := verifierPostRoot (commitExtendedState base) a st.signer 0
          bogus (stepOpenings base st 0)
        assertEq (expected := true) (actual := got.isNone)
          "a policy opening for the wrong cell was accepted"
    }
  , { name := "the two bulk variants are refused"
    , body := do
        -- Their write set is the actor set at a resource, which an L1
        -- holding only the pre-root cannot enumerate: a complete
        -- bundle and one missing a recipient are indistinguishable to
        -- it.  Refused rather than adjudicated on a coin flip.
        for a in [Authority.Action.distributeOthers 1 7 5,
                  Authority.Action.proportionalDilute 1 7 5] do
          let st := sign a
          let got := verifierPostRoot (commitExtendedState base) a st.signer 0
            (policyOpening base) (stepOpenings base st 0)
          assertEq (expected := true) (actual := got.isNone)
            s!"{repr a} was adjudicated"
    }
  , { name := "the verifier's cell list is the complete one"
    , body := do
        -- The theorem `verifierWriteCells_eq_writeCellsAt` in value
        -- form: deriving from the proven counter reaches exactly
        -- `writeCellsAt`, so the shape check is a check against
        -- COMPLETENESS rather than against a weaker static
        -- declaration.
        for (name, a) in probes do
          assertEq
            (expected := (Authority.Action.writeCellsAt base a 7).map
              (fun t => toString (repr t)))
            (actual := (verifierWriteCells a 7 base.bridge.nextWdId).map
              (fun t => toString (repr t)))
            s!"{name}: the derived cell list is not the complete one"
    }
  , { name := "API stability: the verifier's signature"
    , body := do
        let _agree : ∀ (es : ExtendedState) (a : Authority.Action)
            (signer : ActorId), FaultProofAdjudicable a = true →
            verifierWriteCells a signer es.bridge.nextWdId
              = Authority.Action.writeCellsAt es a signer :=
          fun es a signer h => verifierWriteCells_eq_writeCellsAt es a signer h
        pure ()
    }
  ]

/-! ## The multiproof verifier

`verifierPostRootMulti` is the same verifier over a pre-root
multiproof.  These cases exercise what the change makes newly
possible and newly refusable, rather than re-checking what the chained
suite above already pins. -/

/-- A step over the probe state: bump the signer's nonce. -/
def multiCells : List CellTag := [CellTag.nonce 7]

/-- Tests for the multiproof path. -/
def multiTests : List TestCase :=
  [ { name := "the frontier includes the policy cell"
    , body := do
        -- Under the chained fold the read-only budget policy needed its
        -- own opening and its own 256-level walk, because it is a read
        -- among writes.  Here a read is a write of the same value, so
        -- it is one more cell in the frontier and one fewer walk.
        let f := multiFrontierOf (.transfer 1 7 8 30) 7 0
        assertEq (expected := true)
          (actual := f.any (fun t => smtCellKey t == smtCellKey .budgetPolicy))
          "the policy cell is in the frontier"
        assertEq (expected := true) (actual := pathSorted f)
          "and the frontier is still strictly sorted"
    }
  , { name := "a cell's pre-value is read by cell, not by occurrence"
    , body := do
        -- `preStateValueAt`'s first-occurrence rule existed because a
        -- later write's opening was against the RUNNING state.  With
        -- one opening per cell there is nothing to disambiguate, and
        -- the lookup says so directly.
        let b : MultiBundle :=
          { cells := [(.nonce 7, natCellValue 3), (.budgetPolicy, ByteArray.empty)]
          , siblings := [] }
        assertEq (expected := some (natCellValue 3).toList)
          (actual := (bundleValueAt b (.nonce 7)).map ByteArray.toList)
          "the opened cell reads back"
        assertEq (expected := (none : Option (List UInt8)))
          (actual := (bundleValueAt b (.nonce 8)).map ByteArray.toList)
          "an unopened cell reads nothing, rather than a default"
    }
  , { name := "a non-adjudicable action is refused before any work"
    , body := do
        let b : MultiBundle := { cells := [], siblings := [] }
        assertEq (expected := true)
          (actual := (verifierPostRootMulti (ByteArray.mk #[]) 
                        (.distributeOthers 1 7 30) 7 0 b).isNone)
          "distributeOthers is refused"
        assertEq (expected := true)
          (actual := (verifierPostRootMulti (ByteArray.mk #[])
                        (.proportionalDilute 1 7 30) 7 0 b).isNone)
          "proportionalDilute is refused"
    }
  , { name := "a bundle whose cells are not the step's is refused"
    , body := do
        -- The shape check, at the verifier rather than in isolation.
        -- Order is free; content is not.
        let b : MultiBundle := { cells := [(.nonce 7, natCellValue 3)], siblings := [] }
        assertEq (expected := true)
          (actual := (verifierPostRootMulti (ByteArray.mk #[])
                        (.transfer 1 7 8 30) 7 0 b).isNone)
          "a bundle missing the balance and policy cells is refused"
    }
  ]

/-- Tests. -/
def tests : List TestCase := coreTests ++ multiTests

end LegalKernel.Test.FaultProof.Terminate
