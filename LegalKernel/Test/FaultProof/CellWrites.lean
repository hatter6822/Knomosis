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
          , .bridgeAmmReserveEth, .bridgeAmmDisabled, .epochBudget 7
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
  , { name := "chainLast follows the writes"
    , body := do
        -- `chainLast_canonicalCellChain` at the value level: the chain
        -- the fold consumes really does end in the state the writes
        -- produce, so the root the fold computes is that state's.
        let viaChain := chainLast base (canonicalCellChain base transferWrites)
        let viaWrites := applyCellWrites base transferWrites
        for t in [CellTag.balance 1 7, .balance 1 8, .nonce 7, .epochBudget 7] do
          assertEq (expected := (getCellValue viaWrites t).toList)
            (actual := (getCellValue viaChain t).toList)
            s!"chain and write list disagree at {repr t}"
    }
  , { name := "canonicalCellChain opens each write against its own state"
    , body := do
        -- Openings go stale the moment a write lands, so each link's
        -- proof must be built against the state it opens against —
        -- NOT against the original pre-state.  A builder that reused
        -- the pre-state's path for every link would produce equal
        -- proofs here.
        let chain := canonicalCellChain base transferWrites
        assertEq (expected := 3) (actual := chain.length) "one link per write"
        let mid := applyCellWrites base [(.balance 1 7, amountCellValue 70)]
        match chain with
        | _ :: (_, _, p₁) :: _ =>
            -- Flattened to `List UInt8` alongside the count, rather
            -- than compared as a list of lists: the sibling widths are
            -- fixed at 32, so the pair is faithful, and the nested
            -- form blows the elaborator's recursion budget.
            let sibs (p : SmtCellProof) : Nat × List UInt8 :=
              (p.siblings.size, p.siblings.toList.flatMap (fun s => s.toList))
            assertEq (expected := sibs (buildStateCellProof mid (.balance 1 8)))
              (actual := sibs p₁)
              "link 1 opens against the state link 0 produced"
            -- And that is not the same thing as opening against the
            -- ORIGINAL pre-state: the first write moved a sibling root
            -- on this cell's path, so a builder that reused the
            -- pre-state's path would produce a stale opening the fold
            -- rejects.
            assert (sibs p₁ != sibs (buildStateCellProof base (.balance 1 8)))
              "and the pre-state's path really is stale by then"
        | _ => throw <| IO.userError "canonicalCellChain lost a link"
    }
  , { name := "stepCellWrites names exactly the declared cells"
    , body := do
        let action : Authority.Action := .transfer 1 7 8 30
        let ws := stepCellWrites base action 7
        assertEq (expected := (Authority.Action.writeCells action 7).map (fun t => repr t |>.pretty))
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
        let rebuilt := applyCellWrites base (stepCellWrites post action 7)
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
        let rebuilt := applyCellWrites base (stepCellWrites post action 7)
        assert ((getCellValue rebuilt (.balance 1 8)).toList
                  != (getCellValue post (.balance 1 8)).toList)
          "the undeclared cell is NOT reproduced"
        assert ((commitExtendedState rebuilt).toList != (commitExtendedState post).toList)
          "so the roots differ — which is what completeness rules out"
    }
  , { name := "API stability: write-chain signatures"
    , body := do
        let _local : ∀ (ws : List CellWrite) (es : ExtendedState) (t : CellTag),
            (∀ w ∈ ws, w.1 ≠ t) →
            getCellValue (applyCellWrites es ws) t = getCellValue es t :=
          getCellValue_applyCellWrites_of_not_written
        let _last : ∀ (ws : List CellWrite) (es : ExtendedState),
            chainLast es (canonicalCellChain es ws) = applyCellWrites es ws :=
          chainLast_canonicalCellChain
        let _fold : ∀ (ws : List CellWrite) (es : ExtendedState),
            CellWritesReady es ws →
            foldStateCellWrites (commitExtendedState es)
                (chainWrites es (canonicalCellChain es ws))
              = some (commitExtendedState (applyCellWrites es ws)) :=
          fold_canonicalCellChain_eq_commit_applyCellWrites
        let _agree : ∀ (es₁ es₂ : ExtendedState),
            BitsDistinctBelow smtDepth (stateCellEntries es₁) →
            BitsDistinctBelow smtDepth (stateCellEntries es₂) →
            (∀ t : CellTag, getCellValue es₁ t = getCellValue es₂ t) →
            commitExtendedState es₁ = commitExtendedState es₂ :=
          commitExtendedState_eq_of_cells_agree
        let _roundtrip : ∀ (target source : ExtendedState) (t : CellTag),
            ExtendedState.CanonicalBounds source →
            (t.appendOnly = true →
              getCellValue source t = canonicalAbsentValue t →
              getCellValue target t = canonicalAbsentValue t) →
            getCellValue (setCell target t (getCellValue source t)) t
              = getCellValue source t :=
          getCellValue_setCell_getCellValue
        let _step : ∀ (pre post : ExtendedState) (action : Authority.Action)
            (signer : ActorId),
            CellWritesReady pre (stepCellWrites post action signer) →
            WriteSetComplete pre post action signer →
            (Authority.Action.writeCells action signer).Nodup →
            ExtendedState.CanonicalBounds post →
            BitsDistinctBelow smtDepth (stateCellEntries post) →
            (∀ t : CellTag, t.appendOnly = true →
              getCellValue post t = canonicalAbsentValue t →
              getCellValue pre t = canonicalAbsentValue t) →
            foldStateCellWrites (commitExtendedState pre)
                (chainWrites pre
                  (canonicalCellChain pre (stepCellWrites post action signer)))
              = some (commitExtendedState post) :=
          fold_stepCellWrites_eq_commit_post
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.CellWrites
