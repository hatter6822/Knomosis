-- SPDX-License-Identifier: GPL-3.0-or-later
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
  , { name := "buildTerminateBundle: expectedPostCommit is the fold's root"
    , body := do
        -- It was `stepVMHashFromAction`, a bespoke per-variant hash
        -- living outside state-root space, so the contract's terminal
        -- comparison against `g.high.commit` could never succeed.
        let bundle := buildTerminateBundle exampleState exampleEntry
        -- Against the STATE rather than against another verifier: the
        -- published root of the state the step produces, computed with
        -- no reference to the fold.
        let expected := commitExtendedState
          (productionApplyBudget exampleState exampleEntry.signedAction 0)
        assertEq (expected := some expected.toList)
          (actual := some bundle.expectedPostCommit.toList)
          "expectedPostCommit = the published post-root"
    }
  , { name := "buildTerminateBundle: the frontier is the step's"
    , body := do
        -- The written cells plus the read-only budget policy,
        -- deduplicated.  Not `writeCellsAt`'s length: a self-transfer
        -- writes one cell twice and opens it once, and the policy cell
        -- is on the frontier rather than beside it.
        let bundle := buildTerminateBundle exampleState exampleEntry
        assertEq
          (expected := (multiFrontierOf exampleEntry.signedAction.action
             exampleEntry.signedAction.signer
             exampleState.bridge.nextWdId).length)
          (actual := bundle.openedCells.length)
          "bundle opens exactly the frontier"
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
        assertEq (expected := b1.expectedPostCommit)
          (actual := b2.expectedPostCommit)
          "expectedPostCommit agrees"
    }
    -- ## The wire verifies
  , { name := "buildTerminateBundle: the wire folds to the pre-state root"
    , body := do
        -- The check the L1 makes, made here: the bundle's own values
        -- folded through its own wire must reproduce the root it
        -- claims to open against.  `verifyCellProofs` was the chained
        -- analogue and is not the property a multiproof has — there is
        -- one aggregate check, not one per opening.
        let bundle := buildTerminateBundle exampleState exampleEntry
        let got := verifierPostRootMulti (commitExtendedState exampleState)
          exampleEntry.signedAction.action exampleEntry.signedAction.signer 0
          { cells := bundle.openedCells, proof := bundle.wire }
        assertEq (expected := some bundle.expectedPostCommit.toList)
          (actual := got.map ByteArray.toList)
          "the bundle's own wire reaches the root it publishes"
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
    -- layout, a expectedPostCommit equal to the production
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
        -- 5 × uint64BE + 2 × uint128BE = 72-byte L1 field layout
        -- (userAmount and poolAmount are wei-denominated).
        assertEq (expected := 72) (actual := bundle.actionFields.size)
          "depositWithFee actionFields = 72 bytes"
        let expected := commitExtendedState
          (productionApplyBudget es entry.signedAction 0)
        assertEq (expected := some expected.toList)
          (actual := some bundle.expectedPostCommit.toList)
          "expectedPostCommit = the published post-root for depositWithFee"
        -- The bundle names exactly the cells the action writes --
        -- deduplicated, since a pre-root multiproof opens each cell
        -- once however many times the step writes it.
        assertEq
          (expected := (multiFrontierOf entry.signedAction.action
             entry.signedAction.signer es.bridge.nextWdId).length)
          (actual := bundle.openedCells.length)
          "depositWithFee bundle opens exactly the frontier"
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
        -- 3 × uint64BE + 1 × uint128BE = 40-byte L1 field layout
        -- (gasAmount is wei-denominated; budgetIncrement is a unit
        -- count and stays 8 bytes).
        assertEq (expected := 40) (actual := bundle.actionFields.size)
          "topUpActionBudget actionFields = 40 bytes"
        let expected := commitExtendedState
          (productionApplyBudget es entry.signedAction 0)
        assertEq (expected := some expected.toList)
          (actual := some bundle.expectedPostCommit.toList)
          "expectedPostCommit = the published post-root for topUpActionBudget"
        assertEq
          (expected := (multiFrontierOf entry.signedAction.action
             entry.signedAction.signer es.bridge.nextWdId).length)
          (actual := bundle.openedCells.length)
          "topUpActionBudget bundle opens exactly the frontier"
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
        assert (json.splitOn "\"expected_post_commit_hex\"" |>.length |> (· > 1))
          "JSON contains expected_post_commit_hex field"
        assert (json.splitOn "\"opened_cells\"" |>.length |> (· > 1))
          "JSON contains opened_cells field"
        assert (json.splitOn "\"gap_mask_hex\"" |>.length |> (· > 1))
          "JSON contains gap_mask_hex field"
        assert (json.splitOn "\"siblings_hex\"" |>.length |> (· > 1))
          "JSON contains siblings_hex field"
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
    --
    -- Ascribed, not merely named.  A `let _ := @thm` binding pins only
    -- that the identifier exists; the guarantee CLAUDE.md promises is
    -- that elaboration FAILS when a signature changes, which needs the
    -- type written out.
  , { name := "buildTerminateBundle API stable"
    , body := do
        let _builder : ExtendedState → LogEntry → Nat → TerminateBundle :=
          fun es entry idx => buildTerminateBundle es entry idx
        assert true "API exists"
    }
  , { name := "buildTerminateBundle_deterministic API stable"
    , body := do
        let _proof : ∀ (es₁ es₂ : ExtendedState) (e₁ e₂ : LogEntry),
            es₁ = es₂ → e₁ = e₂ →
            buildTerminateBundle es₁ e₁ = buildTerminateBundle es₂ e₂ :=
          fun es₁ es₂ e₁ e₂ h_es h_e =>
            buildTerminateBundle_deterministic es₁ es₂ e₁ e₂ h_es h_e
        assert true "API exists"
    }
  , { name := "buildTerminateBundle_actionKind API stable"
    , body := do
        let _proof : ∀ (es : ExtendedState) (entry : LogEntry),
            (buildTerminateBundle es entry).actionKind
              = actionKindByte entry.signedAction.action :=
          fun es entry => buildTerminateBundle_actionKind es entry
        assert true "API exists"
    }
  , { name := "buildTerminateBundle_openedCells_tags API stable"
    , body := do
        -- The SHAPE the L1 re-derives and compares against: the
        -- step's frontier, which is the written cells plus the
        -- read-only budget policy, deduplicated and in path order.
        -- Its chained predecessor stated `writeCellsAt`'s list, which
        -- names a duplicated cell twice and the policy not at all.
        let _proof : ∀ (es : ExtendedState) (entry : LogEntry) (idx : Nat),
            (buildTerminateBundle es entry idx).openedCells.map Prod.fst
              = multiFrontierOf entry.signedAction.action
                  entry.signedAction.signer es.bridge.nextWdId :=
          fun es entry idx => buildTerminateBundle_openedCells_tags es entry idx
        assert true "API exists"
    }
  , { name := "buildTerminateBundle_wire API stable"
    , body := do
        let _proof : ∀ (es : ExtendedState) (entry : LogEntry) (idx : Nat),
            (buildTerminateBundle es entry idx).wire
              = (stepMultiBundle es entry.signedAction).proof :=
          fun es entry idx => buildTerminateBundle_wire es entry idx
        assert true "API exists"
    }
  , { name := "formatTerminateBundleJson API stable"
    , body := do
        let _fmt : String → TerminateBundle → String := formatTerminateBundleJson
        assert true "API exists"
    }
  ]

end LegalKernel.Test.FaultProof.TerminateBundle
