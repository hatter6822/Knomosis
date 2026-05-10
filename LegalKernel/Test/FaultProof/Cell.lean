/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Cell — value-level tests for the
`CellTag`, `CellProof`, `CellProofBundle` types (Workstream H §12 /
WUs H.3.1 + H.3.2).
-/

import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.StepVariants
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Cell

/-- Tests for the cell-proof shape primitives. -/
def tests : List TestCase :=
  [ { name := "CellTag.kindIndex is in [0, 6]"
    , body := do
        assertEq (expected := 0) (actual := (CellTag.balance 1 2).kindIndex) "balance"
        assertEq (expected := 1) (actual := (CellTag.nonce 5).kindIndex) "nonce"
        assertEq (expected := 2) (actual := (CellTag.registry 5).kindIndex) "registry"
        assertEq (expected := 3) (actual := (CellTag.localPolicy 5).kindIndex) "localPolicy"
        assertEq (expected := 4) (actual := (CellTag.bridgeConsumed 100).kindIndex) "bridgeConsumed"
        assertEq (expected := 5) (actual := (CellTag.bridgePending 50).kindIndex) "bridgePending"
        assertEq (expected := 6) (actual := CellTag.bridgeNextWdId.kindIndex) "bridgeNextWdId"
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
  ]

end LegalKernel.Test.FaultProof.Cell
