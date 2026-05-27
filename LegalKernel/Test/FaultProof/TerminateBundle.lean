/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.TerminateBundle — value-level + API-
stability tests for Workstream SVC.3's terminate-bundle module.

Tests cover:
  * `buildTerminateBundle` constructs all five fields from a
    canonical `(preState, entry)` pair.
  * Per-field projections agree with their definitions.
  * The cell-proof bundle verifies against the pre-state commit.
  * JSON formatter produces the expected snake_case envelope.
-/

import LegalKernel.FaultProof.TerminateBundle
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.FaultProof
open LegalKernel.FaultProof.StepVMCoherence
open LegalKernel.FaultProof.TerminateBundle
open LegalKernel.Runtime
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.TerminateBundle

/-- A canonical example pre-state + entry pair: empty state +
    a no-op-shaped transfer (sender to itself, amount 0). -/
private def exampleEntry : LogEntry := {
  prevHash := ByteArray.empty,
  signedAction := {
    action := .transfer 0 0 0 0,
    signer := 0,
    nonce := 0,
    sig := ByteArray.empty
  },
  postStateHash := ByteArray.empty
}

private def exampleState : ExtendedState := ExtendedState.empty

/-- Tests for the SVC terminate-bundle module. -/
def tests : List TestCase :=
  [ -- ## Bundle construction: per-field correctness
    { name := "buildTerminateBundle: actionKind for transfer is 0"
    , body := do
        let bundle := buildTerminateBundle exampleState exampleEntry
        assertEq (expected := (0 : UInt8)) (actual := bundle.actionKind)
          "transfer's actionKind is 0"
    }
  , { name := "buildTerminateBundle: actionFields matches actionFieldsForL1"
    , body := do
        let bundle := buildTerminateBundle exampleState exampleEntry
        let expected := actionFieldsForL1 exampleEntry.signedAction.action
        assertEq (expected := expected) (actual := bundle.actionFields)
          "actionFields agrees with the standalone encoder"
    }
  , { name := "buildTerminateBundle: signer matches entry"
    , body := do
        let bundle := buildTerminateBundle exampleState exampleEntry
        assertEq (expected := exampleEntry.signedAction.signer)
          (actual := bundle.signer)
          "bundle's signer = entry's signer"
    }
  , { name := "buildTerminateBundle: claimedPostCommit matches stepVMHashFromAction"
    , body := do
        let bundle := buildTerminateBundle exampleState exampleEntry
        let expected := stepVMHashFromAction exampleState
                          exampleEntry.signedAction.action
                          exampleEntry.signedAction.signer
        assertEq (expected := expected) (actual := bundle.claimedPostCommit)
          "claimedPostCommit = stepVMHashFromAction"
    }
  , { name := "buildTerminateBundle: cellProofs matches observer's bundle"
    , body := do
        let bundle := buildTerminateBundle exampleState exampleEntry
        let expected := Observer.buildObserverCellProofs exampleState
                          exampleEntry.signedAction.action
                          exampleEntry.signedAction.signer
        assertEq (expected := expected.proofs.length)
          (actual := bundle.cellProofs.proofs.length)
          "bundle's cell-proof count matches observer's"
    }
    -- ## Determinism
  , { name := "buildTerminateBundle: deterministic on same input"
    , body := do
        let b1 := buildTerminateBundle exampleState exampleEntry
        let b2 := buildTerminateBundle exampleState exampleEntry
        assertEq (expected := b1.actionKind) (actual := b2.actionKind)
          "actionKind agrees"
        assertEq (expected := b1.actionFields) (actual := b2.actionFields)
          "actionFields agrees"
        assertEq (expected := b1.claimedPostCommit)
          (actual := b2.claimedPostCommit)
          "claimedPostCommit agrees"
    }
    -- ## Cell-proof bundle verification
  , { name := "buildTerminateBundle: cell-proof bundle verifies against pre-state commit"
    , body := do
        let bundle := buildTerminateBundle exampleState exampleEntry
        let commit := commitExtendedState exampleState
        let result := verifyCellProofs commit bundle.cellProofs
        assert result "cell-proof bundle verifies against pre-state commit"
    }
    -- ## Per-variant bundles: actionKind dispatch
  , { name := "buildTerminateBundle: actionKind for Mint is 1"
    , body := do
        let entry : LogEntry := { exampleEntry with
          signedAction := { exampleEntry.signedAction with
            action := .mint 0 0 0 } }
        let bundle := buildTerminateBundle exampleState entry
        assertEq (expected := (1 : UInt8)) (actual := bundle.actionKind)
          "mint's actionKind is 1"
    }
  , { name := "buildTerminateBundle: actionKind for FreezeResource is 3"
    , body := do
        let entry : LogEntry := { exampleEntry with
          signedAction := { exampleEntry.signedAction with
            action := .freezeResource 0 } }
        let bundle := buildTerminateBundle exampleState entry
        assertEq (expected := (3 : UInt8)) (actual := bundle.actionKind)
          "freezeResource's actionKind is 3"
    }
  , { name := "buildTerminateBundle: actionKind for Dispute is 8"
    , body := do
        let d : LegalKernel.Disputes.Dispute := {
          challenger := 0,
          claim := .signatureInvalid 0,
          evidence := ByteArray.empty,
          nonce := 0,
          sig := ByteArray.empty
        }
        let entry : LogEntry := { exampleEntry with
          signedAction := { exampleEntry.signedAction with
            action := .dispute d } }
        let bundle := buildTerminateBundle exampleState entry
        assertEq (expected := (8 : UInt8)) (actual := bundle.actionKind)
          "dispute's actionKind is 8"
    }
    -- ## GP.3.3: terminate-bundle coverage for the new variants.
    -- These verify the off-chain observer's terminate-move payload
    -- builder produces the right actionKind, the right L1 field
    -- layout, a claimedPostCommit equal to the production
    -- `stepVMHashFromAction` path, and a cell-proof bundle that
    -- verifies against the pre-state commit — for the two
    -- Workstream-GP variants at indices 19 / 20.
  , { name := "buildTerminateBundle: actionKind for DepositWithFee is 19"
    , body := do
        -- Bridge-signed deposit-with-fee; pre-state credits the
        -- recipient (10) and pool (99) balances on resource 1.
        let es : ExtendedState :=
          let b1 := LegalKernel.setBalance LegalKernel.genesisState 1 10 5
          let b2 := LegalKernel.setBalance b1 1 99 0
          { ExtendedState.empty with base := b2 }
        let entry : LogEntry := { exampleEntry with
          signedAction := {
            action := .depositWithFee 1 10 99 30 20 100 42,
            signer := LegalKernel.Bridge.bridgeActor,
            nonce := 0, sig := ByteArray.empty } }
        let bundle := buildTerminateBundle es entry
        assertEq (expected := (19 : UInt8)) (actual := bundle.actionKind)
          "depositWithFee's actionKind is 19"
        -- 7 × uint64BE = 56-byte L1 field layout.
        assertEq (expected := 56) (actual := bundle.actionFields.size)
          "depositWithFee actionFields = 56 bytes"
        -- claimedPostCommit matches the production dispatcher path.
        let expected := stepVMHashFromAction es
                          entry.signedAction.action entry.signedAction.signer
        assertEq (expected := expected) (actual := bundle.claimedPostCommit)
          "claimedPostCommit = stepVMHashFromAction for depositWithFee"
        -- The cell-proof bundle verifies against the pre-state commit.
        assert (verifyCellProofs (commitExtendedState es) bundle.cellProofs)
          "depositWithFee cell-proof bundle verifies"
    }
  , { name := "buildTerminateBundle: actionKind for TopUpActionBudget is 20"
    , body := do
        -- User-initiated top-up; signer (50) has gas balance on
        -- resource 2; pool actor 99 distinct from signer.
        let es : ExtendedState :=
          let b1 := LegalKernel.setBalance LegalKernel.genesisState 2 50 100
          let b2 := LegalKernel.setBalance b1 2 99 5
          { ExtendedState.empty with base := b2 }
        let entry : LogEntry := { exampleEntry with
          signedAction := {
            action := .topUpActionBudget 2 15 30 99,
            signer := 50, nonce := 0, sig := ByteArray.empty } }
        let bundle := buildTerminateBundle es entry
        assertEq (expected := (20 : UInt8)) (actual := bundle.actionKind)
          "topUpActionBudget's actionKind is 20"
        -- 4 × uint64BE = 32-byte L1 field layout.
        assertEq (expected := 32) (actual := bundle.actionFields.size)
          "topUpActionBudget actionFields = 32 bytes"
        let expected := stepVMHashFromAction es
                          entry.signedAction.action entry.signedAction.signer
        assertEq (expected := expected) (actual := bundle.claimedPostCommit)
          "claimedPostCommit = stepVMHashFromAction for topUpActionBudget"
        assert (verifyCellProofs (commitExtendedState es) bundle.cellProofs)
          "topUpActionBudget cell-proof bundle verifies"
    }
    -- ## JSON formatter
  , { name := "formatTerminateBundleJson: contains required snake_case fields"
    , body := do
        let bundle := buildTerminateBundle exampleState exampleEntry
        let json := formatTerminateBundleJson "log[0]" bundle
        assert (json.startsWith "{") "JSON starts with {"
        assert (json.endsWith "}") "JSON ends with }"
        assert (json.splitOn "\"fixture_id\"" |>.length |> (· > 1))
          "JSON contains fixture_id field"
        assert (json.splitOn "\"action_kind\"" |>.length |> (· > 1))
          "JSON contains action_kind field"
        assert (json.splitOn "\"action_fields_hex\"" |>.length |> (· > 1))
          "JSON contains action_fields_hex field"
        assert (json.splitOn "\"signer\"" |>.length |> (· > 1))
          "JSON contains signer field"
        assert (json.splitOn "\"claimed_post_commit_hex\"" |>.length |> (· > 1))
          "JSON contains claimed_post_commit_hex field"
        assert (json.splitOn "\"cell_proofs\"" |>.length |> (· > 1))
          "JSON contains cell_proofs field"
    }
  , { name := "formatTerminateBundleJson: fixture_id is quoted in output"
    , body := do
        let bundle := buildTerminateBundle exampleState exampleEntry
        let json := formatTerminateBundleJson "log[42]" bundle
        assert (json.splitOn "\"log[42]\"" |>.length |> (· > 1))
          "fixture_id 'log[42]' appears as a JSON string"
    }
  , { name := "formatTerminateBundleJson: action_kind is decimal (not hex)"
    , body := do
        let bundle := buildTerminateBundle exampleState exampleEntry
        let json := formatTerminateBundleJson "log[0]" bundle
        -- Transfer's actionKind = 0; should appear unprefixed (not "0x00").
        assert (json.splitOn "\"action_kind\":0" |>.length |> (· > 1))
          "action_kind:0 (no 0x prefix)"
    }
    -- ## API-stability
  , { name := "buildTerminateBundle API stable"
    , body := do
        let _ := @buildTerminateBundle
        assert true "API exists"
    }
  , { name := "buildTerminateBundle_deterministic API stable"
    , body := do
        let _ := @buildTerminateBundle_deterministic
        assert true "API exists"
    }
  , { name := "buildTerminateBundle_actionKind API stable"
    , body := do
        let _ := @buildTerminateBundle_actionKind
        assert true "API exists"
    }
  , { name := "buildTerminateBundle_cellProofs_verify API stable"
    , body := do
        let _ := @buildTerminateBundle_cellProofs_verify
        assert true "API exists"
    }
  , { name := "formatTerminateBundleJson API stable"
    , body := do
        let _ := @formatTerminateBundleJson
        assert true "API exists"
    }
  ]

end LegalKernel.Test.FaultProof.TerminateBundle
