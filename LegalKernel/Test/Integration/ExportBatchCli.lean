-- SPDX-License-Identifier: GPL-3.0-or-later
-- Knomosis  - A Societal Kernel
-- Copyright (C) 2026  Adam Hall
-- This program comes with ABSOLUTELY NO WARRANTY.
-- This is free software, and you are welcome to redistribute it
-- under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

/-
# Tests — the batch exporters' kernel contract (Workstream SB)

Integration regression for the `knomosis export-batch`,
`knomosis export-action-proof`, and widened
`knomosis export-terminate-bundle LOG IDX PREV_END END` subcommands.
The CLI surface itself lives in `Main.lean`; this module covers the
Lean-level contract those commands dispatch to — `buildBatchBinding`
and the three JSON formatters.  Subprocess-level invocation tests
live in the Rust observer's `tests/` directory once its consumer
lands.

Two of these carry weight beyond regression:

  * **The binding's wire verifies** — against the batch root the L1
    record commits, at the disputed key, for the leaf that binds the
    signature.  Without this the exporters could emit
    shape-plausible wires no contract accepts.
  * **The JSON back-compat pin** — a bundle formatted WITHOUT a batch
    binding must not mention the batch fields, so the pre-batching
    Rust consumer's parse is unchanged until its own cutover.
-/

import LegalKernel.FaultProof.TerminateBundle
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.FaultProof
open LegalKernel.FaultProof.TerminateBundle
open LegalKernel.Test

namespace LegalKernel.Test.Integration.ExportBatchCli

/-- A log entry whose action distinguishes itself by `amount`,
    carrying a fixed-width 65-byte pseudo-signature filled with
    `sigByte` (the R7 leaf binds the signature, so the fixture
    separates on it too). -/
private def entryWith (amount : Nat) (sigByte : UInt8) : LogEntry := {
  prevHash := ByteArray.empty,
  signedAction := {
    action := .transfer 0 1 2 amount,
    signer := 1,
    nonce := 0,
    sig := ByteArray.mk (Array.replicate 65 sigByte)
  },
  postStateHash := ByteArray.empty
}

/-- A six-entry log with pairwise-distinct actions and signatures. -/
private def log6 : List LogEntry :=
  (List.range 6).map (fun i => entryWith (100 + i) (UInt8.ofNat i))

/-- Tests. -/
def tests : List TestCase :=
  [ -- ## buildBatchBinding: the happy path, and the wire verifies
    { name := "buildBatchBinding: binding for the genesis batch verifies"
    , body := do
        match buildBatchBinding log6 0 6 2 with
        | none => throw <| IO.userError "binding for idx 2 of [0, 6) refused"
        | some b => do
          assertEq (expected := 0) (actual := b.prevEnd) "prevEnd"
          assertEq (expected := 6) (actual := b.endIndex) "end"
          assertEq (expected := 2) (actual := b.idx) "idx"
          assertEq (expected := (actionsRoot 0 log6).toList)
            (actual := b.actionsRoot.toList) "root is the batch's actionsRoot"
          assert (verifyActionProof b.actionsRoot 2 b.leafCommit b.actionProof)
            "the inclusion wire verifies at the disputed key"
    }
  , { name := "buildBatchBinding: a non-genesis batch verifies against ITS root"
    , body := do
        -- Batch [2, 5): three entries, first log index 2.
        match buildBatchBinding log6 2 5 3 with
        | none => throw <| IO.userError "binding for idx 3 of [2, 5) refused"
        | some b => do
          let batch := (log6.take 5).drop 2
          assertEq (expected := (actionsRoot 2 batch).toList)
            (actual := b.actionsRoot.toList)
            "root is the [2, 5) slice's actionsRoot"
          assert (b.actionsRoot != actionsRoot 0 log6)
            "...which is NOT the whole-log root"
          assert (verifyActionProof b.actionsRoot 3 b.leafCommit b.actionProof)
            "the wire verifies against the slice's root"
    }
  , { name := "buildBatchBinding: the leaf binds the entry's signature"
    , body := do
        match buildBatchBinding log6 0 6 4 with
        | none => throw <| IO.userError "binding refused"
        | some b => do
          assertEq (expected := (ByteArray.mk (Array.replicate 65
              (UInt8.ofNat 4))).toList)
            (actual := b.actionSig.toList) "signature rides verbatim"
          assertEq (expected := (actionLeafValue
              (entryWith 104 (UInt8.ofNat 4)).signedAction).toList)
            (actual := b.leafCommit.toList) "leaf commit is actionLeafValue"
          assertEq (expected := (actionKey 4).toList)
            (actual := b.actionKey.toList) "key is actionKey idx"
    }
  , -- ## Refusals
    { name := "buildBatchBinding: bounds are enforced"
    , body := do
        assert (buildBatchBinding log6 2 5 1 |>.isNone)
          "idx below prevEnd refused"
        assert (buildBatchBinding log6 2 5 5 |>.isNone)
          "idx at end (exclusive) refused"
        assert (buildBatchBinding log6 0 7 3 |>.isNone)
          "end past the log refused"
        assert (buildBatchBinding log6 0 6 0 |>.isSome)
          "the batch's first index is inside"
        assert (buildBatchBinding log6 0 6 5 |>.isSome)
          "the batch's last index is inside"
    }
  , -- ## The export-batch JSON
    { name := "formatBatchExportJson: documented fields, computed count"
    , body := do
        let json := formatBatchExportJson 2 5
          (ByteArray.mk (Array.replicate 32 0xAA))
          (ByteArray.mk (Array.replicate 32 0xBB))
        for f in ["\"prev_end\"", "\"end\"", "\"count\"",
                  "\"state_commit_hex\"", "\"actions_root_hex\""] do
          assert ((json.splitOn f).length > 1) s!"field {f} present"
        assert ((json.splitOn "\"count\":3").length > 1)
          "count = end - prev_end = 3"
        assert (json.startsWith "{" && json.endsWith "}") "object envelope"
    }
  , -- ## The export-action-proof JSON
    { name := "formatActionProofExportJson: documented fields"
    , body := do
        match buildBatchBinding log6 0 6 2 with
        | none => throw <| IO.userError "binding refused"
        | some b => do
          let json := formatActionProofExportJson b (entryWith 102 (UInt8.ofNat 2))
          for f in ["\"idx\"", "\"prev_end\"", "\"end\"", "\"action_kind\"",
                    "\"action_fields_hex\"", "\"signer\"", "\"action_sig_hex\"",
                    "\"actions_root_hex\"", "\"action_key_hex\"",
                    "\"leaf_commit_hex\"", "\"gap_mask_hex\"",
                    "\"siblings_hex\""] do
            assert ((json.splitOn f).length > 1) s!"field {f} present"
    }
  , -- ## The widened terminate JSON, and its back-compat pin
    { name := "formatTerminateBundleJson: batch fields appear iff a binding is given"
    , body := do
        let es := ExtendedState.empty
        let entry := entryWith 100 (UInt8.ofNat 0)
        let bundle := buildTerminateBundle es entry 2
        let bare := formatTerminateBundleJson "log[2]" bundle
        assert ((bare.splitOn "\"prev_end\"").length == 1)
          "no batch fields without a binding (back-compat shape)"
        match buildBatchBinding log6 0 6 2 with
        | none => throw <| IO.userError "binding refused"
        | some b => do
          let widened := formatTerminateBundleJson "log[2]" bundle (some b)
          for f in ["\"prev_end\"", "\"end\"", "\"batch_idx\"",
                    "\"actions_root_hex\"", "\"action_key_hex\"",
                    "\"leaf_commit_hex\"", "\"action_sig_hex\"",
                    "\"action_gap_mask_hex\"", "\"action_siblings_hex\""] do
            assert ((widened.splitOn f).length > 1) s!"field {f} present"
          assert (widened.startsWith "{" && widened.endsWith "}")
            "widened object envelope"
    }
  , -- ## The l2LogIndex threading fix
    { name := "buildTerminateBundle: the log index reaches the fold"
    , body := do
        -- A withdraw's pending record embeds the l2LogIndex, so the
        -- SAME (state, entry) pair at two indices must reach two
        -- DIFFERENT post roots.  This pins the CLI's idx threading —
        -- the exporter used to default the index to 0, deriving the
        -- wrong pending-cell value for any withdraw past index 0.
        let s := setBalance emptyState 0 1 1000
        let es : ExtendedState := { ExtendedState.empty with base := s }
        let wdEntry : LogEntry := {
          prevHash := ByteArray.empty,
          signedAction := {
            action := .withdraw 0 1 50 Bridge.EthAddress.zero,
            signer := 1,
            nonce := 0,
            sig := ByteArray.mk (Array.replicate 65 0x11)
          },
          postStateHash := ByteArray.empty
        }
        let b0 := buildTerminateBundle es wdEntry 0
        let b5 := buildTerminateBundle es wdEntry 5
        assert (b0.expectedPostCommit != b5.expectedPostCommit)
          "a withdraw's post root depends on the log index"
    }
  , -- ## Term-level API stability
    { name := "batch-binding API signatures are stable"
    , body := do
        let _refuse :
            ∀ (entries : List LogEntry) (prevEnd endIndex idx : Nat),
              ¬ (prevEnd ≤ idx ∧ idx < endIndex ∧ endIndex ≤ entries.length) →
              buildBatchBinding entries prevEnd endIndex idx = none :=
          buildBatchBinding_none_of_out_of_range
        let _root :
            ∀ (entries : List LogEntry) (prevEnd endIndex idx : Nat)
              (b : BatchBinding),
              buildBatchBinding entries prevEnd endIndex idx = some b →
              b.actionsRoot
                = actionsRoot prevEnd ((entries.take endIndex).drop prevEnd) :=
          buildBatchBinding_actionsRoot
        let _binds :
            ∀ (entries : List LogEntry) (prevEnd endIndex idx : Nat)
              (entry : LogEntry) (b : BatchBinding),
              entries[idx]? = some entry →
              buildBatchBinding entries prevEnd endIndex idx = some b →
              b.actionKey = actionKey idx ∧
              b.leafCommit = actionLeafValue entry.signedAction ∧
              b.actionSig = entry.signedAction.sig :=
          buildBatchBinding_binds_entry
        assert true "signatures elaborated"
    }
  ]

end LegalKernel.Test.Integration.ExportBatchCli
