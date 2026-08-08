-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.CellWrites — the write-list machinery on
real states.

The theorems in `LegalKernel/FaultProof/CellWrites.lean` are about
`getCellValue` and roots; these tests run the same machinery on a
populated `ExtendedState` and check the values, which catches
definitional drift the elaborator would not.

Two properties are worth naming because they are the ones a per-variant
proof leans on and neither is obvious from the statements:

  * a LATER write to the same cell wins — the fold is ordered, so a
    variant whose write list names a cell twice (a self-transfer does)
    ends on the second value, not the first;
  * writing a cell moves the published root, and writing a cell back
    to its original value restores it — the root really is a function
    of the cell values, not of the write history.
-/

import LegalKernel.FaultProof.CellWrites
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.CellWrites

/-- A state with live entries in several sub-states, so the writes
    below have something to disturb. -/
def base : ExtendedState :=
  let st : LegalKernel.State :=
    { balances := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
                    (((∅ : BalanceMap).insert 7 100).insert 8 40) }
  { base          := st
  , nonces        := { next := (∅ : Std.TreeMap ActorId Nonce compare).insert 7 3 }
  , registry      := (∅ : KeyRegistry).insert 7 (ByteArray.mk #[1, 2, 3])
  , epochBudgets  := (∅ : EpochBudgetState).insert 7
                       { lastSeenEpoch := 2, budgetBalance := 50 }
  , budgetPolicy  := .bounded 10 3 4 }

/-- A transfer-shaped write list: debit 7, credit 8, bump the nonce. -/
def transferWrites : List CellWrite :=
  [ (.balance 1 7, amountCellValue 70)
  , (.balance 1 8, amountCellValue 70)
  , (.nonce 7,     natCellValue 4) ]

/-- Tests. -/
def tests : List TestCase :=
  [ { name := "applyCellWrites lands every written value"
    , body := do
        let es' := applyCellWrites base transferWrites
        assertEq (expected := (amountCellValue 70).toList)
          (actual := (getCellValue es' (.balance 1 7)).toList) "debited balance"
        assertEq (expected := (amountCellValue 70).toList)
          (actual := (getCellValue es' (.balance 1 8)).toList) "credited balance"
        assertEq (expected := (natCellValue 4).toList)
          (actual := (getCellValue es' (.nonce 7)).toList) "bumped nonce"
    }
  , { name := "applyCellWrites disturbs no unwritten cell"
    , body := do
        -- `getCellValue_applyCellWrites_of_not_written` at the value
        -- level.  Cells across every OTHER kind, so a write that
        -- rebuilt a shared sub-state would show up here.
        let es' := applyCellWrites base transferWrites
        let untouched : List CellTag :=
          [ .balance 1 9, .balance 2 7, .nonce 8, .registry 7, .localPolicy 7
          , .bridgeConsumed 3, .bridgePending 4, .bridgeNextWdId
          , .bridgeBoldTvlCap, .bridgeAmmDisabled, .epochBudget 7
          , .budgetPolicy ]
        for t in untouched do
          assertEq (expected := (getCellValue base t).toList)
            (actual := (getCellValue es' t).toList)
            s!"transfer writes disturbed {repr t}"
    }
  , { name := "a later write to the same cell wins"
    , body := do
        -- The self-transfer shape: `Action.writeCells` names
        -- `.balance r sender` and `.balance r receiver`, which are the
        -- SAME cell when sender = receiver.  The fold is ordered, so
        -- the second value is the one that lands — matching the
        -- production advance, which composes the two `setBalance`
        -- calls in the same order.
        let ws : List CellWrite :=
          [ (.balance 1 7, amountCellValue 70)
          , (.balance 1 7, amountCellValue 100) ]
        let es' := applyCellWrites base ws
        assertEq (expected := (amountCellValue 100).toList)
          (actual := (getCellValue es' (.balance 1 7)).toList)
          "the second write wins"
    }
  , { name := "the published root moves with the writes and returns"
    , body := do
        -- The root is a function of the cell VALUES, so a write that
        -- restores a cell's original value restores the root — even
        -- though the intermediate state was different and the
        -- underlying `Std.TreeMap` was rebuilt twice.
        let moved := applyCellWrites base [(.balance 1 7, amountCellValue 70)]
        assert ((commitExtendedState moved).toList != (commitExtendedState base).toList)
          "a write moves the root"
        let back := applyCellWrites moved [(.balance 1 7, amountCellValue 100)]
        assertEq (expected := (commitExtendedState base).toList)
          (actual := (commitExtendedState back).toList)
          "restoring the value restores the root"
    }
  , { name := "writing a cell to its canonical absent value drops it"
    , body := do
        -- `stateCellEntries` canonicalises, so a balance zeroed by a
        -- write is indistinguishable from one never written.  The
        -- `reclaimAmmReserves` sweep does exactly this, so it is the
        -- reachable case rather than a corner.
        let zeroed := applyCellWrites base [(.balance 1 8, amountCellValue 0)]
        assertEq (expected := (canonicalAbsentValue (CellTag.balance 1 8)).toList)
          (actual := (getCellValue zeroed (.balance 1 8)).toList)
          "the zeroed cell reads as canonically absent"
        assert (!((stateCellEntries zeroed).map (fun p => p.1.toList)).contains
                  (smtCellKey (CellTag.balance 1 8)).toList)
          "and contributes no entry to the root"
    }
  , { name := "stepCellWrites names exactly the declared cells"
    , body := do
        let action : Authority.Action := .transfer 1 7 8 30
        let ws := stepCellWrites base base action 7
        assertEq (expected := (Authority.Action.writeCellsAt base action 7).map (fun t => repr t |>.pretty))
          (actual := ws.map (fun w => repr w.1 |>.pretty))
          "write list tags"
        -- Each write carries the POST value, so the list is a
        -- specification the L1 checks, not one it recomputes.
        for (t, v) in ws do
          assertEq (expected := (getCellValue base t).toList) (actual := v.toList)
            s!"write value at {repr t} came from the state it was built against"
    }
  , { name := "a complete write set reproduces every cell of the post-state"
    , body := do
        -- `getCellValue_applyCellWrites_stepCellWrites` at the value
        -- level, on a state pair that really differs: `post` is `base`
        -- with the transfer's three cells moved.  Applying the write
        -- list to `base` must reproduce `post` cell-for-cell — and the
        -- root that follows must match.
        let action : Authority.Action := .transfer 1 7 8 30
        let post := applyCellWrites base
          [ (.balance 1 7, amountCellValue 70)
          , (.balance 1 8, amountCellValue 70)
          , (.nonce 7,     natCellValue 4) ]
        let rebuilt := applyCellWrites base (stepCellWrites base post action 7)
        let probes : List CellTag :=
          [ .balance 1 7, .balance 1 8, .balance 1 9, .nonce 7, .nonce 8
          , .registry 7, .localPolicy 7, .epochBudget 7, .bridgeNextWdId
          , .budgetPolicy, .bridgeAmmDisabled ]
        for t in probes do
          assertEq (expected := (getCellValue post t).toList)
            (actual := (getCellValue rebuilt t).toList)
            s!"rebuilt state disagrees with post at {repr t}"
        assertEq (expected := (commitExtendedState post).toList)
          (actual := (commitExtendedState rebuilt).toList)
          "and the two publish the same root"
    }
  , { name := "an INCOMPLETE write set does not reproduce the post-state"
    , body := do
        -- The negative control the theorem's `WriteSetComplete`
        -- hypothesis exists for.  `mint` declares no cell for actor 8,
        -- so a post-state that moved actor 8's balance is one its
        -- write list cannot express — the rebuild misses it and the
        -- roots differ.  Without this, "the write set is complete"
        -- would be a hypothesis nothing ever exercised.
        let action : Authority.Action := .mint 1 7 5
        let post := applyCellWrites base [(.balance 1 8, amountCellValue 999)]
        let rebuilt := applyCellWrites base (stepCellWrites base post action 7)
        assert ((getCellValue rebuilt (.balance 1 8)).toList
                  != (getCellValue post (.balance 1 8)).toList)
          "the undeclared cell is NOT reproduced"
        assert ((commitExtendedState rebuilt).toList != (commitExtendedState post).toList)
          "so the roots differ — which is what completeness rules out"
    }
  , { name := "withdraw's complete write set names the allocated cell"
    , body := do
        -- The static `writeCells` cannot name it: the key is the
        -- deployment's current `nextWdId`, which is not a function of
        -- `(action, signer)`.  `writeCellsAt` is what closes that, and
        -- without it a withdrawal's bundle omits the very cell the
        -- withdrawal creates.
        let wd : Authority.Action := .withdraw 1 7 30 LegalKernel.Bridge.EthAddress.zero
        let seeded : ExtendedState :=
          { base with bridge := { base.bridge with nextWdId := 5 } }
        let static := Authority.Action.writeCells wd 7
        let complete := Authority.Action.writeCellsAt seeded wd 7
        assert (!static.contains (.bridgePending 5))
          "the static declaration omits the allocated cell"
        assert (complete.contains (.bridgePending 5))
          "the complete set names it, keyed by the pre-state's counter"
        assertEq (expected := static.length + 1) (actual := complete.length)
          "and adds exactly one cell"
        -- Every OTHER variant pays nothing for the split.
        for a in [Authority.Action.transfer 1 7 8 5, .mint 1 7 5, .freezeResource 1,
                  .deposit 1 7 5 3, .reserveSwap 1 2 7 5 1 3] do
          assertEq (expected := (Authority.Action.writeCells a 7).map (fun t => repr t |>.pretty))
            (actual := (Authority.Action.writeCellsAt seeded a 7).map (fun t => repr t |>.pretty))
            s!"writeCellsAt widened a non-withdraw action: {repr a}"
    }
  , { name := "identity-advance completeness on a nonce-and-budget-only step"
    , body := do
        -- `writeSetComplete_of_identity_advance` at the value level.
        -- The post-state moves exactly the two cells every action
        -- writes; every other cell must read unchanged, which is what
        -- the lemma asserts and what the L1 relies on when it holds
        -- openings for those two alone.
        let post : ExtendedState :=
          { base with
              nonces := { next := base.nonces.next.insert 7 4 }
            , epochBudgets := base.epochBudgets.insert 7
                { lastSeenEpoch := 4, budgetBalance := 7 } }
        let action : Authority.Action := .freezeResource 1
        for t in [CellTag.balance 1 7, .balance 1 8, .nonce 8, .registry 7
                 , .localPolicy 7, .bridgeConsumed 3, .bridgePending 4
                 , .bridgeNextWdId, .bridgeAmmDisabled, .epochBudget 8
                 , .budgetPolicy] do
          assert (!(Authority.Action.writeCellsAt base action 7).contains t)
            s!"probe {repr t} must be outside the write set"
          assertEq (expected := (getCellValue base t).toList)
            (actual := (getCellValue post t).toList)
            s!"advance moved undeclared cell {repr t}"
        -- And the two declared ones really did move, so the test is
        -- not passing because nothing happened.
        assert ((getCellValue post (.nonce 7)).toList != (getCellValue base (.nonce 7)).toList)
          "the nonce moved"
        assert ((getCellValue post (.epochBudget 7)).toList
                  != (getCellValue base (.epochBudget 7)).toList)
          "the budget moved"
    }
  , { name := "the canonical opening verifies against its own root"
    , body := do
        -- `verifyStateCellProof_buildStateCellProof` at the value
        -- level.  `buildStateCellProof` is a LIVE production path — it
        -- is what `buildCellProofWithOpening` puts on the wire as
        -- `proofData` — so the statement that its output verifies
        -- against the published root is a guarantee about something
        -- the observer actually emits.  It lost its only caller when
        -- the chained fold retired; that made it unconsumed, not
        -- untrue, and this is what keeps it wired.
        for t in [CellTag.balance 1 7, .balance 1 8, .nonce 7, .epochBudget 7,
                  .budgetPolicy] do
          assertEq (expected := true)
            (actual := verifyStateCellProof (commitExtendedState base) t
              (getCellValue base t) (buildStateCellProof base t))
            s!"the canonical opening at {repr t} must verify"
        -- The negative control, and it has to move a DIFFERENT cell:
        -- a path's siblings are the subtrees it does not contain, so
        -- rewriting the opened cell itself leaves its own opening
        -- untouched.  Moving a neighbour is what shifts a sibling.
        let moved := setCell base (.balance 1 8) (amountCellValue 4242)
        assertEq (expected := false)
          (actual := verifyStateCellProof (commitExtendedState base) (.balance 1 7)
            (getCellValue base (.balance 1 7)) (buildStateCellProof moved (.balance 1 7)))
          "an opening from a state with a moved neighbour must not verify"
    }
  , { name := "cell agreement is STRICTLY WEAKER than map agreement"
    , body := do
        -- Why the per-variant proofs target cells rather than states,
        -- pinned rather than asserted.
        --
        -- Lean core DOES supply map extensionality — `Std.TreeMap` has
        -- `Equiv` (`~m`), `Equiv.of_forall_constGet?_eq` builds one
        -- from pointwise lookups, and `equiv_iff_toList_eq` turns it
        -- into `toList` equality, which would carry through
        -- `stateCellEntries` to the root.  (What core does NOT supply
        -- is `Eq`: two balanced trees holding the same bindings need
        -- not be equal, and no pointwise lemma concludes `=`.)
        --
        -- So targeting cells is not a way around a missing lemma.  It
        -- is that map agreement is strictly STRONGER than what the
        -- root observes: `stateCellEntries` drops canonically-absent
        -- cells, so a balance written to zero and a balance never
        -- written are cell-identical and root-identical while their
        -- maps differ pointwise.  `reclaimAmmReserves` sweeps a balance
        -- to zero, so this is a reachable pair — a per-variant proof
        -- phrased over maps would be attempting a hypothesis that is
        -- FALSE on a real action.
        let zeroed := applyCellWrites base [(.balance 1 8, amountCellValue 0)]
        let neverBase : LegalKernel.State :=
          { balances := (∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
              ((∅ : BalanceMap).insert 7 100) }
        let never : ExtendedState := { base with base := neverBase }
        for t in [CellTag.balance 1 7, .balance 1 8, .balance 1 9] do
          assertEq (expected := (getCellValue never t).toList)
            (actual := (getCellValue zeroed t).toList)
            s!"cells disagree at {repr t}"
        assertEq (expected := (commitExtendedState never).toList)
          (actual := (commitExtendedState zeroed).toList)
          "and the published roots agree"
        let lookup (es : ExtendedState) : Option Amount :=
          (es.base.balances[(1 : ResourceId)]?.getD ∅)[(8 : ActorId)]?
        assertEq (expected := some 0) (actual := lookup zeroed)
          "the zeroed write leaves a LIVE zero entry"
        assertEq (expected := (none : Option Amount)) (actual := lookup never)
          "while the never-written map has no entry at all"
        assert (lookup zeroed != lookup never)
          "so the maps differ pointwise — map agreement is a FALSE hypothesis here"
    }
  ]

end LegalKernel.Test.FaultProof.CellWrites
