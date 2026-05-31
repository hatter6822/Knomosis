-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Verify — value-level tests for the
witness-state-based cell proof verifier (Workstream H §12.3 / WUs
H.3.3 + H.3.4).
-/

import LegalKernel.FaultProof.Verify
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Verify

private def emptyEs : ExtendedState := ExtendedState.empty
private def emptyCommit : StateCommit := commitExtendedState emptyEs

/-- Tests for the witness-state-based cell-proof verifier. -/
def tests : List TestCase :=
  [ { name := "verifyCellProof_complete: canonical balance proof verifies"
    , body := do
        let proof := buildCellProof emptyEs (CellTag.balance 1 2)
        assertEq (expected := true)
                 (actual := verifyCellProof emptyCommit proof)
                 "canonical proof verifies"
    }
  , { name := "verifyCellProof_complete: canonical nonce proof verifies"
    , body := do
        let proof := buildCellProof emptyEs (CellTag.nonce 5)
        assertEq (expected := true)
                 (actual := verifyCellProof emptyCommit proof)
                 "canonical nonce proof verifies"
    }
  , { name := "verifyCellProof_complete: canonical registry proof verifies"
    , body := do
        let proof := buildCellProof emptyEs (CellTag.registry 7)
        assertEq (expected := true)
                 (actual := verifyCellProof emptyCommit proof)
                 "canonical registry proof verifies"
    }
  , { name := "verifyCellProof rejects mismatched commit"
    , body := do
        let proof := buildCellProof emptyEs (CellTag.balance 1 2)
        let badCommit : StateCommit := ByteArray.mk #[0xFF]
        assertEq (expected := false)
                 (actual := verifyCellProof badCommit proof)
                 "rejects wrong commit"
    }
  , { name := "verifyCellProof rejects forged cellValue"
    , body := do
        let canonicalProof := buildCellProof emptyEs (CellTag.balance 1 2)
        let forgedProof : CellProof :=
          { canonicalProof with cellValue := ByteArray.mk #[0xDE, 0xAD] }
        assertEq (expected := false)
                 (actual := verifyCellProof emptyCommit forgedProof)
                 "forged cellValue rejected"
    }
  , { name := "getCellValue on empty state returns canonical absent"
    , body := do
        assertEq (expected := canonicalAbsentValue (CellTag.balance 1 2))
                 (actual   := getCellValue emptyEs (CellTag.balance 1 2))
                 "balance absent"
        assertEq (expected := canonicalAbsentValue (CellTag.nonce 5))
                 (actual   := getCellValue emptyEs (CellTag.nonce 5))
                 "nonce absent"
        assertEq (expected := canonicalAbsentValue (CellTag.registry 7))
                 (actual   := getCellValue emptyEs (CellTag.registry 7))
                 "registry absent"
    }
  , { name := "isCellAbsent on empty state holds for every cell"
    , body := do
        assert (isCellAbsent emptyEs (CellTag.balance 1 2)) "balance"
        assert (isCellAbsent emptyEs (CellTag.nonce 5)) "nonce"
        assert (isCellAbsent emptyEs (CellTag.registry 7)) "registry"
        assert (isCellAbsent emptyEs (CellTag.localPolicy 9)) "localPolicy"
        assert (isCellAbsent emptyEs (CellTag.bridgeNextWdId)) "bridgeNextWdId"
    }
  , { name := "verifyCellProof_complete_for_absent_cell"
    , body := do
        let absentProof : CellProof :=
          { cellTag := CellTag.balance 1 2,
            cellValue := canonicalAbsentValue (CellTag.balance 1 2),
            witnessState := emptyEs }
        assertEq (expected := true)
                 (actual := verifyCellProof emptyCommit absentProof)
                 "absent-cell proof verifies"
    }
  , { name := "updateCommitment_agrees_with_setCell (rfl)"
    , body := do
        -- The theorem's content is established at the type level
        -- (rfl).  We call it to ensure value-level computation
        -- doesn't trap on something unexpected.
        let proof := buildCellProof emptyEs (CellTag.balance 1 2)
        let newValue : ByteArray :=
          ByteArray.mk (LegalKernel.Encoding.Encodable.encode (T := Nat) 100).toArray
        let updated := updateCommitment proof newValue
        let direct := commitExtendedState (setCell emptyEs (CellTag.balance 1 2) newValue)
        assertEq (expected := updated) (actual := direct) "agreement"
    }
  , { name := "verifyCellProofs of canonical bundle verifies"
    , body := do
        let tags : List CellTag := [CellTag.balance 1 2, CellTag.nonce 5, CellTag.registry 7]
        let bundle : CellProofBundle :=
          { proofs := tags.map (fun t => buildCellProof emptyEs t) }
        assertEq (expected := true)
                 (actual := verifyCellProofs emptyCommit bundle)
                 "canonical bundle verifies"
    }
  , { name := "verifyCellProofs empty bundle verifies trivially"
    , body := do
        assertEq (expected := true)
                 (actual := verifyCellProofs emptyCommit CellProofBundle.empty)
                 "empty bundle"
    }
  , { name := "setCell + getCellValue round-trips on registry pk"
    , body := do
        let pk : ByteArray := ByteArray.mk #[0x01, 0x02, 0x03]
        let updated := setCell emptyEs (CellTag.registry 7) pk
        assertEq (expected := pk)
                 (actual := getCellValue updated (CellTag.registry 7))
                 "registry round-trip"
    }
  , { name := "Theorem #221 verifyCellProof_complete API"
    , body := do
        let _proof := @verifyCellProof_complete
        pure ()
    }
  , { name := "Theorem #222 verifyCellProof_sound_under_collision_free API"
    , body := do
        let _proof := @verifyCellProof_sound_under_collision_free
        pure ()
    }
  , { name := "Theorem #223 updateCommitment_agrees_with_setCell API"
    , body := do
        let _proof := @updateCommitment_agrees_with_setCell
        pure ()
    }
  , { name := "Theorem #260 verifyCellProof_complete_for_absent_cell API"
    , body := do
        let _proof := @verifyCellProof_complete_for_absent_cell
        pure ()
    }
  , { name := "Theorem #220 commitExtendedState_subcommits_eq API"
    , body := do
        let _proof := @commitExtendedState_subcommits_eq_under_collision_free
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.Verify
