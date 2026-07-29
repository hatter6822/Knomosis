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
        -- The round trip is now stated on the CELL VALUE, not on the
        -- raw key.  `getCellValue` wraps the key in a CBE byte string
        -- so that a registration with an EMPTY key is distinguishable
        -- from no registration; `setCell` decodes that wrapper.
        -- Feeding `setCell` the raw key would now be feeding it a
        -- malformed cell value.
        let pk : ByteArray := ByteArray.mk #[0x01, 0x02, 0x03]
        let cellValue :=
          ByteArray.mk (LegalKernel.Encoding.Encodable.encode (T := ByteArray) pk).toArray
        let updated := setCell emptyEs (CellTag.registry 7) cellValue
        assertEq (expected := cellValue.toList)
                 (actual := (getCellValue updated (CellTag.registry 7)).toList)
                 "registry cell-value round-trip"
        -- And the underlying key really is the one we wrote.
        match updated.registry[(7 : ActorId)]? with
        | none     => assert false "registration lost"
        | some got => assertEq (expected := pk.toList) (actual := got.toList)
                        "the stored key is the one written"
    }
  , { name := "Theorem #221 verifyCellProof_complete API"
    , body := do
        let _proof : ∀ (es : ExtendedState) (tag : CellTag),
            verifyCellProof (commitExtendedState es) (buildCellProof es tag) = true :=
          verifyCellProof_complete
        pure ()
    }
  , { name := "Theorem #222 verifyCellProof_sound API"
    , body := do
        let _proof : ∀ (commit : StateCommit) (proof : CellProof),
            verifyCellProof commit proof = true →
            ∃ es, commitExtendedState es = commit ∧
                  getCellValue es proof.cellTag = proof.cellValue :=
          verifyCellProof_sound
        pure ()
    }
  , { name := "Theorem #222 verifyCellProof witness-uniqueness API"
    , body := do
        -- The uniqueness half is what a fault-proof consumer relies
        -- on; pinning its signature keeps the collision-resistance
        -- hypothesis attached to the statement that needs it.
        let _proof : ∀ (commit : StateCommit) (proof : CellProof) (es : ExtendedState),
            Bridge.CollisionFreeOn
              (stateCommitSmtPreimages es proof.witnessState)
              LegalKernel.Runtime.hashBytes →
            StateCellsWellFormed es →
            StateCellsWellFormed proof.witnessState →
            verifyCellProof commit proof = true →
            commitExtendedState es = commit →
            ∀ t : CellTag, getCellValue es t = getCellValue proof.witnessState t :=
          verifyCellProof_witness_cells_agree_under_collision_free
        pure ()
    }
  , { name := "Theorem #223 updateCommitment_agrees_with_setCell API"
    , body := do
        let _proof : ∀ (es : ExtendedState) (tag : CellTag) (newValue : ByteArray),
            updateCommitment (buildCellProof es tag) newValue =
              commitExtendedState (setCell es tag newValue) :=
          updateCommitment_agrees_with_setCell
        pure ()
    }
  , { name := "Theorem #260 verifyCellProof_complete_for_absent_cell API"
    , body := do
        let _proof : ∀ (es : ExtendedState) (tag : CellTag),
            isCellAbsent es tag →
            verifyCellProof (commitExtendedState es)
              { cellTag := tag,
                cellValue := canonicalAbsentValue tag,
                witnessState := es } = true :=
          verifyCellProof_complete_for_absent_cell
        pure ()
    }
  , { name := "Theorem #220 commitExtendedState_subcommits_eq API"
    , body := do
        let _proof : ∀ (es₁ es₂ : ExtendedState),
            Bridge.CollisionFreeOn
              [extendedStatePreimage es₁, extendedStatePreimage es₂]
              LegalKernel.Runtime.hashBytes →
            commitExtendedStateConcat es₁ = commitExtendedStateConcat es₂ →
            commitState es₁.base = commitState es₂.base ∧
            commitNonceState es₁.nonces = commitNonceState es₂.nonces ∧
            commitKeyRegistry es₁.registry = commitKeyRegistry es₂.registry ∧
            commitLocalPolicies es₁.localPolicies = commitLocalPolicies es₂.localPolicies ∧
            commitBridgeState es₁.bridge = commitBridgeState es₂.bridge ∧
            commitEpochBudgets es₁.epochBudgets = commitEpochBudgets es₂.epochBudgets ∧
            commitBudgetPolicy es₁.budgetPolicy = commitBudgetPolicy es₂.budgetPolicy :=
          commitExtendedStateConcat_subcommits_eq_under_collision_free
        pure ()
    }
  , -- ===== Absent vs present-but-empty =====
    { name := "registry: an EMPTY public key is not read as absent"
    , body := do
        -- `PublicKey` is a bare `ByteArray` and `registerIdentity`
        -- accepts any value, so registering the empty key is a
        -- reachable state — and registration is an admissibility
        -- gate, so it is a DIFFERENT state from unregistered.  The
        -- cell value must say so, or a cell root cannot tell them
        -- apart and a fault proof could not adjudicate the
        -- difference.
        let bare : ExtendedState := ExtendedState.empty
        let registeredEmpty : ExtendedState :=
          { bare with registry := bare.registry.insert 7 ByteArray.empty }
        let absent := getCellValue bare (.registry 7)
        let present := getCellValue registeredEmpty (.registry 7)
        assert (absent.toList != present.toList)
          "an empty registered key must not read as the absent marker"
        assertEq (expected := 0) (actual := absent.size)
          "absent stays the zero-length marker"
        assert (present.size > 0)
          "present carries its CBE head even with a zero-length key"
    }
  , { name := "registry: setCell inverts getCellValue on an empty key"
    , body := do
        -- The round trip is what makes the disambiguation usable
        -- rather than merely observable: a step VM that reads the
        -- cell and writes it back must not silently drop the
        -- registration.
        let bare : ExtendedState := ExtendedState.empty
        let registeredEmpty : ExtendedState :=
          { bare with registry := bare.registry.insert 7 ByteArray.empty }
        let v := getCellValue registeredEmpty (.registry 7)
        let restored := setCell bare (.registry 7) v
        match restored.registry[(7 : ActorId)]? with
        | none    => assert false "round trip lost the registration"
        | some pk => assertEq (expected := 0) (actual := pk.size)
                       "round trip preserved the empty key"
    }
  , { name := "localPolicy: a declared clause-less policy is not read as absent"
    , body := do
        -- `LocalPolicies.lookup` defaults an absent actor to
        -- `LocalPolicy.empty`, so keying the cell off `lookup`
        -- collapsed "declared nothing" onto "declared a policy with
        -- no clauses".  The cell now keys off the map itself.
        let bare : ExtendedState := ExtendedState.empty
        let declaredEmpty : ExtendedState :=
          { bare with
              localPolicies := bare.localPolicies.insert 7 Authority.LocalPolicy.empty }
        let absent := getCellValue bare (.localPolicy 7)
        let present := getCellValue declaredEmpty (.localPolicy 7)
        assert (absent.toList != present.toList)
          "a declared clause-less policy must not read as the absent marker"
    }
  ]

end LegalKernel.Test.FaultProof.Verify
