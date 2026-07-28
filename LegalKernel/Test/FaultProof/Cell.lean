-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Cell — value-level tests for the
`CellTag`, `CellProof`, `CellProofBundle` types (Workstream H §12 /
WUs H.3.1 + H.3.2).
-/

import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.KeyDerivation
import LegalKernel.FaultProof.StepVariants
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Cell

/-- Tests for the cell-proof shape primitives. -/
def tests : List TestCase :=
  [ { name := "CellTag.kindIndex pins every tag index in [0, 16]"
    , body := do
        -- 0–6 are FROZEN: they are mirrored in the Solidity `CellKind`
        -- enum and pinned by the cross-stack corpus, so a reorder here
        -- is a consensus split.  7–16 append to them.  Every
        -- constructor is listed, so a new tag added without a decision
        -- about its index fails this test rather than drifting.
        assertEq (expected := 0) (actual := (CellTag.balance 1 2).kindIndex) "balance"
        assertEq (expected := 1) (actual := (CellTag.nonce 5).kindIndex) "nonce"
        assertEq (expected := 2) (actual := (CellTag.registry 5).kindIndex) "registry"
        assertEq (expected := 3) (actual := (CellTag.localPolicy 5).kindIndex) "localPolicy"
        assertEq (expected := 4) (actual := (CellTag.bridgeConsumed 100).kindIndex) "bridgeConsumed"
        assertEq (expected := 5) (actual := (CellTag.bridgePending 50).kindIndex) "bridgePending"
        assertEq (expected := 6) (actual := CellTag.bridgeNextWdId.kindIndex) "bridgeNextWdId"
        assertEq (expected := 7) (actual := CellTag.bridgeAmmReserveEth.kindIndex)
          "bridgeAmmReserveEth"
        assertEq (expected := 8) (actual := CellTag.bridgeAmmReserveBold.kindIndex)
          "bridgeAmmReserveBold"
        assertEq (expected := 9) (actual := CellTag.bridgeBoldCircuitClosed.kindIndex)
          "bridgeBoldCircuitClosed"
        assertEq (expected := 10) (actual := CellTag.bridgeBoldTvlCap.kindIndex)
          "bridgeBoldTvlCap"
        assertEq (expected := 11)
          (actual := CellTag.bridgeBoldTotalLockedValue.kindIndex)
          "bridgeBoldTotalLockedValue"
        assertEq (expected := 12) (actual := CellTag.bridgeAmmDisabled.kindIndex)
          "bridgeAmmDisabled"
        assertEq (expected := 13) (actual := (CellTag.epochBudget 5).kindIndex)
          "epochBudget"
        assertEq (expected := 14) (actual := CellTag.budgetPolicyFreeTier.kindIndex)
          "budgetPolicyFreeTier"
        assertEq (expected := 15) (actual := CellTag.budgetPolicyActionCost.kindIndex)
          "budgetPolicyActionCost"
        assertEq (expected := 16) (actual := CellTag.budgetPolicyCurrentEpoch.kindIndex)
          "budgetPolicyCurrentEpoch"
    }
  , { name := "CellTag DecidableEq distinguishes balance keys"
    , body := do
        assert (CellTag.balance 1 2 = CellTag.balance 1 2) "self equality"
        assert (¬ (CellTag.balance 1 2 = CellTag.balance 1 3))
          "distinct actor distinguishable"
        assert (¬ (CellTag.balance 1 2 = CellTag.balance 2 2))
          "distinct resource distinguishable"
    }
  , { name := "CellTag DecidableEq across variants"
    , body := do
        assert (¬ (CellTag.balance 1 2 = CellTag.nonce 2)) "balance ≠ nonce"
        assert (¬ (CellTag.registry 2 = CellTag.localPolicy 2))
          "registry ≠ localPolicy"
        assert (¬ (CellTag.bridgeConsumed 1 = CellTag.bridgePending 1))
          "bridgeConsumed ≠ bridgePending"
    }
  , { name := "CellProofBundle.empty has size 0"
    , body := do
        assertEq (expected := 0) (actual := CellProofBundle.empty.size) "empty size"
    }
  , { name := "CellProofBundle.push grows the bundle by one"
    , body := do
        let p : CellProof :=
          { cellTag := CellTag.balance 1 2,
            cellValue := ByteArray.empty,
            witnessState := ExtendedState.empty }
        let b := CellProofBundle.empty.push p
        assertEq (expected := 1) (actual := b.size) "after one push"
        let b2 := b.push p
        assertEq (expected := 2) (actual := b2.size) "after two pushes"
    }
  , { name := "Action.requiredCells transfer covers 4 cells"
    , body := do
        let cells := Authority.Action.requiredCells (.transfer 1 2 3 4) 2
        assertEq (expected := 4) (actual := cells.length) "transfer cell count"
    }
  , { name := "Action.requiredCells mint covers 3 cells"
    , body := do
        let cells := Authority.Action.requiredCells (.mint 1 2 3) 2
        assertEq (expected := 3) (actual := cells.length) "mint cell count"
    }
  , { name := "Action.requiredCells burn covers 3 cells"
    , body := do
        let cells := Authority.Action.requiredCells (.burn 1 2 3) 2
        assertEq (expected := 3) (actual := cells.length) "burn cell count"
    }
  , { name := "Action.requiredCells freeze covers 2 cells"
    , body := do
        let cells := Authority.Action.requiredCells (.freezeResource 1) 2
        assertEq (expected := 2) (actual := cells.length) "freeze cell count"
    }
  , { name := "Action.requiredCells faultProofChallenge covers 2 cells"
    , body := do
        let cells := Authority.Action.requiredCells
          (.faultProofChallenge ByteArray.empty 0 0 ByteArray.empty) 2
        assertEq (expected := 2) (actual := cells.length) "fpchallenge cell count"
    }
  , { name := "Action.requiredCells faultProofResolution covers 2 cells"
    , body := do
        let cells := Authority.Action.requiredCells
          (.faultProofResolution ByteArray.empty 1 1 0) 2
        assertEq (expected := 2) (actual := cells.length) "fpresolution cell count"
    }
  , { name := "Action.requiredCells deposit covers 5 cells (incl. bridgeConsumed)"
    , body := do
        let cells := Authority.Action.requiredCells (.deposit 1 2 3 4) 2
        assertEq (expected := 5) (actual := cells.length) "deposit cell count"
    }
  , -- ===== SMT cell-key derivation =====
    { name := "smtCellKey: every tag maps to a distinct 32-byte key"
    , body := do
        -- One representative per kind, plus two same-kind tags that
        -- differ only in their key components.  A collision here is a
        -- proof-replay vector: an SMT proof opening one cell would
        -- verify as a proof about the other.
        let tags : List CellTag :=
          [ .balance 1 2, .balance 2 1, .balance 1 3
          , .nonce 5, .registry 5, .localPolicy 5, .epochBudget 5
          , .bridgeConsumed 9, .bridgePending 9
          , .bridgeNextWdId
          , .bridgeAmmReserveEth, .bridgeAmmReserveBold
          , .bridgeBoldCircuitClosed, .bridgeBoldTvlCap
          , .bridgeBoldTotalLockedValue, .bridgeAmmDisabled
          , .budgetPolicyFreeTier, .budgetPolicyActionCost
          , .budgetPolicyCurrentEpoch ]
        for t in tags do
          assertEq (expected := 32) (actual := (smtCellKey t).size)
            s!"key width for {repr t}"
        -- Pairwise distinctness.  Tags travel with their keys so the
        -- failure message can name the colliding pair (`CellTag` has
        -- no `Inhabited` instance, so indexed access is not available).
        let keyed : List (CellTag × List UInt8) :=
          tags.map (fun t => (t, (smtCellKey t).toList))
        let rec check : List (CellTag × List UInt8) → IO Unit
          | [] => pure ()
          | (t, k) :: rest => do
            for (t', k') in rest do
              if k == k' then
                throw <| IO.userError
                  s!"COLLISION: tags {repr t} and {repr t'} share an SMT \
                     key — a cell proof for one would verify as a proof \
                     about the other"
            check rest
        check keyed
    }
  , { name := "cellKeyPreimage: fixed 1 + 32 + 32 layout"
    , body := do
        -- The layout Solidity reproduces with
        -- `abi.encodePacked(uint8, uint256, uint256)`.  A width or
        -- order change here is a silent cross-stack root divergence,
        -- so it is pinned byte-wise rather than by size alone.
        let pre := cellKeyPreimage (.balance 0x1122 0x3344)
        assertEq (expected := 65) (actual := pre.size) "preimage width"
        let bytes := pre.toList
        assertEq (expected := 0) (actual := bytes[0]!.toNat)
          "byte 0 is the kind index (balance = 0)"
        -- keyA occupies bytes 1..32, big-endian.
        assertEq (expected := 0x11) (actual := bytes[31]!.toNat) "keyA high byte"
        assertEq (expected := 0x22) (actual := bytes[32]!.toNat) "keyA low byte"
        -- keyB occupies bytes 33..64, big-endian.
        assertEq (expected := 0x33) (actual := bytes[63]!.toNat) "keyB high byte"
        assertEq (expected := 0x44) (actual := bytes[64]!.toNat) "keyB low byte"
        -- Every other byte is zero padding.
        for i in List.range 65 do
          if i != 0 && i != 31 && i != 32 && i != 63 && i != 64 then
            assertEq (expected := 0) (actual := bytes[i]!.toNat)
              s!"padding byte {i}"
    }
  , { name := "CellTag.flatKey agrees with kindIndex and keyParts"
    , body := do
        -- `flatKey` is the single source of truth the JSON formatter
        -- and the fixture writer both consume; this pins that it
        -- really is the composition of the two projections.
        for t in [CellTag.balance 3 4, .epochBudget 9, .bridgeAmmDisabled,
                  .bridgeConsumed 77, .budgetPolicyActionCost] do
          let (k, a, b) := t.flatKey
          assertEq (expected := t.kindIndex) (actual := k) "kind agrees"
          assertEq (expected := t.keyParts.1) (actual := a) "keyA agrees"
          assertEq (expected := t.keyParts.2) (actual := b) "keyB agrees"
    }
  ]

end LegalKernel.Test.FaultProof.Cell
