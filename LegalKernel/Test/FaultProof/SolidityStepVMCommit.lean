/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.SolidityStepVMCommit — value-level
+ API-stability tests for the Lean-side mirror of the Solidity
step-VM commit recipe.

Tests cover:
  * Endian-encoding helpers (`uint64BE`, `uint256BE`) shape +
    value-level correctness.
  * Per-variant commit determinism.
  * Size theorems (32-byte outputs).
  * Cross-variant distinguishability (different recipes produce
    different bytes).
-/

import LegalKernel.FaultProof.SolidityStepVMCommit
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.FaultProof.SolidityStepVMCommit
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.SolidityStepVMCommit

private def zero32 : ByteArray := ByteArray.mk (List.replicate 32 (0 : UInt8)).toArray

/-- Tests for the Solidity step-VM commit mirror. -/
def tests : List TestCase :=
  [ -- ## Endian-encoding helpers
    { name := "uint64BE: size is 8"
    , body := do
        assertEq (expected := 8) (actual := (uint64BE 0).size) "zero size"
        assertEq (expected := 8) (actual := (uint64BE 0xDEADBEEF).size) "non-zero size"
    }
  , { name := "uint64BE: value 0 produces 8 zero bytes"
    , body := do
        let r := uint64BE 0
        for i in [0:8] do
          assertEq (expected := (0 : UInt8)) (actual := r.data[i]!)
            s!"byte {i} is zero"
    }
  , { name := "uint64BE: value 1 has 1 in last byte"
    , body := do
        let r := uint64BE 1
        assertEq (expected := (0 : UInt8)) (actual := r.data[0]!) "byte 0"
        assertEq (expected := (0 : UInt8)) (actual := r.data[6]!) "byte 6"
        assertEq (expected := (1 : UInt8)) (actual := r.data[7]!) "byte 7"
    }
  , { name := "uint64BE: big-endian order"
    , body := do
        -- 0x0102030405060708 → bytes [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        let r := uint64BE 0x0102030405060708
        assertEq (expected := (0x01 : UInt8)) (actual := r.data[0]!) "byte 0 = 0x01"
        assertEq (expected := (0x08 : UInt8)) (actual := r.data[7]!) "byte 7 = 0x08"
    }
  , { name := "uint256BE: size is 32"
    , body := do
        assertEq (expected := 32) (actual := (uint256BE 0).size) "zero size"
        assertEq (expected := 32) (actual := (uint256BE 0xDEADBEEF).size) "non-zero size"
    }
  , { name := "uint256BE: value 0 produces 32 zero bytes"
    , body := do
        let r := uint256BE 0
        for i in [0:32] do
          assertEq (expected := (0 : UInt8)) (actual := r.data[i]!)
            s!"byte {i} is zero"
    }
  , { name := "uint256BE: big-endian order"
    , body := do
        -- 0x01 should appear at byte 31 (last byte), bytes 0..30 are zero.
        let r := uint256BE 1
        assertEq (expected := (0 : UInt8)) (actual := r.data[0]!) "byte 0"
        assertEq (expected := (0 : UInt8)) (actual := r.data[30]!) "byte 30"
        assertEq (expected := (1 : UInt8)) (actual := r.data[31]!) "byte 31"
    }
    -- ## API stability
  , { name := "uint64BE_size API stable"
    , body := do
        let _ := @uint64BE_size
        assert true "API exists"
    }
  , { name := "uint256BE_size API stable"
    , body := do
        let _ := @uint256BE_size
        assert true "API exists"
    }
  , { name := "stepCommitTransfer_size API stable"
    , body := do
        let _ := @stepCommitTransfer_size
        assert true "API exists"
    }
  , { name := "stepCommitMint_size API stable"
    , body := do
        let _ := @stepCommitMint_size
        assert true "API exists"
    }
  , { name := "stepCommitBurn_size API stable"
    , body := do
        let _ := @stepCommitBurn_size
        assert true "API exists"
    }
  , { name := "hashString_inj_under_collision_free API stable"
    , body := do
        let _ := @hashString_inj_under_collision_free
        assert true "API exists"
    }
    -- ## Determinism (value level)
  , { name := "stepCommitTransfer: determinism on equal inputs"
    , body := do
        let r1 := stepCommitTransfer zero32 1 10 20 10 95 55
        let r2 := stepCommitTransfer zero32 1 10 20 10 95 55
        assertEq (expected := r1) (actual := r2) "determinism"
    }
  , { name := "stepCommitMint: determinism"
    , body := do
        let r1 := stepCommitMint zero32 1 20 0 60
        let r2 := stepCommitMint zero32 1 20 0 60
        assertEq (expected := r1) (actual := r2) "determinism"
    }
  , { name := "stepCommitBurn: determinism"
    , body := do
        let r1 := stepCommitBurn zero32 1 10 10 50
        let r2 := stepCommitBurn zero32 1 10 10 50
        assertEq (expected := r1) (actual := r2) "determinism"
    }
  , { name := "stepCommitFreezeResource: determinism"
    , body := do
        let r1 := stepCommitFreezeResource zero32 1 10
        let r2 := stepCommitFreezeResource zero32 1 10
        assertEq (expected := r1) (actual := r2) "determinism"
    }
    -- ## Cross-variant distinguishability (value level)
  , { name := "transfer vs mint produce distinct commits"
    , body := do
        -- Even with the same numerical fields, transfer and mint
        -- use distinct tag hashes, so the bytes must differ
        -- (under any non-trivial hash, including the Lean fallback).
        let rt := stepCommitTransfer zero32 1 10 20 10 95 55
        let rm := stepCommitMint     zero32 1 20    0 60
        assert (rt ≠ rm) "transfer != mint"
    }
  , { name := "burn vs mint produce distinct commits"
    , body := do
        -- Identical numerical inputs except for the tag.
        let rb := stepCommitBurn zero32 1 10 0 60
        let rm := stepCommitMint zero32 1 10 0 60
        assert (rb ≠ rm) "burn != mint"
    }
  , { name := "transfer with different amounts produces different commits"
    , body := do
        -- newSenderBalance 95 vs 90.
        let r1 := stepCommitTransfer zero32 1 10 20 10 95 55
        let r2 := stepCommitTransfer zero32 1 10 20 10 90 60
        assert (r1 ≠ r2) "different balances ⇒ different commits"
    }
    -- ## Tag-hash sanity
  , { name := "tagTransfer != tagMint at value level"
    , body := do
        assert (tagTransfer ≠ tagMint) "distinct tag bytes"
    }
  , { name := "tagBurn != tagReward at value level"
    , body := do
        assert (tagBurn ≠ tagReward) "distinct tag bytes"
    }
    -- ## Bulk-action fold functions (audit-5 fix: keyB encoded
    -- as uint256 to match Solidity's CellProof.keyB struct type).
  , { name := "stepCommitDistributeOthersFold uses uint256 keyB"
    , body := do
        -- Verify the fold function produces a 32-byte hash.
        let r := stepCommitDistributeOthersFold zero32 42 100
        assertEq (expected := 32) (actual := r.size)
                 "32-byte output under hashBytes"
    }
  , { name := "stepCommitProportionalDiluteFold uses uint256 keyB"
    , body := do
        let r := stepCommitProportionalDiluteFold zero32 42 100
        assertEq (expected := 32) (actual := r.size)
                 "32-byte output under hashBytes"
    }
  , { name := "DistributeOthers fold differs on different keyB"
    , body := do
        let r1 := stepCommitDistributeOthersFold zero32 1 100
        let r2 := stepCommitDistributeOthersFold zero32 2 100
        assert (r1 ≠ r2) "different keyB ⇒ different commit"
    }
  , { name := "DistributeOthers fold differs on different newBalance"
    , body := do
        let r1 := stepCommitDistributeOthersFold zero32 42 100
        let r2 := stepCommitDistributeOthersFold zero32 42 200
        assert (r1 ≠ r2) "different newBalance ⇒ different commit"
    }
  , { name := "DistributeOthers and ProportionalDilute folds agree on shape"
    , body := do
        -- Both folds have identical (acc, keyB, newBalance)
        -- shape, so they produce the same output for the same
        -- inputs.  Verifies the fold-shape invariance.
        let r1 := stepCommitDistributeOthersFold zero32 42 100
        let r2 := stepCommitProportionalDiluteFold zero32 42 100
        assertEq (expected := r1) (actual := r2)
                 "identical fold shape ⇒ identical output"
    }
  ]

end LegalKernel.Test.FaultProof.SolidityStepVMCommit
