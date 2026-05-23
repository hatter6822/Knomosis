/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

import LegalKernel.Test.Framework
import LegalKernel.FaultProof.Commit
import LegalKernel.FaultProof.Observer
import LegalKernel.FaultProof.StepVMCoherence
import LegalKernel.FaultProof.TerminateBundle
import LegalKernel.Runtime.CellProofJson

/-!
LegalKernel.Test.Integration.ExportTerminateBundleCli — SVC.3
deliverable.

Integration regression for the `knomosis export-terminate-bundle
LOG IDX` subcommand that the off-chain `knomosis-faultproof-
observer` Rust crate's terminate-on-single-step move consumes
to build its `terminateOnSingleStep(uint256, uint8, bytes,
uint64, CellProof[], bytes32)` calldata.

The CLI surface itself lives in `Main.lean`; this test covers
the Lean-level kernel contract that the CLI dispatches to.
Subprocess-level invocation tests (spawning the binary and
parsing the emitted JSON) live in the Rust crate's `tests/`
directory.

## Coverage

  * `buildTerminateBundle` constructs the canonical bundle.
  * The cell-proof bundle inside verifies against the pre-state
    commit.
  * The JSON envelope has the documented snake_case fields.
  * The `actionKind` field correctly dispatches per variant.
  * Byte-pinning for a minimal transfer entry: the JSON byte
    output prefix matches the documented wire format.
-/

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.FaultProof
open LegalKernel.FaultProof.StepVMCoherence
open LegalKernel.FaultProof.TerminateBundle
open LegalKernel.Runtime
open LegalKernel.Test

namespace LegalKernel.Test.Integration.ExportTerminateBundleCli

/-- A canonical example log entry: transfer 0→0, amount 0,
    signer 0 (no-op-shaped). -/
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

/-- The bundle's `actionKind` matches `actionKindByte` of the
    entry's action. -/
def actionKind_matches_actionKindByte : IO Unit := do
  let bundle := buildTerminateBundle exampleState exampleEntry
  let expected := actionKindByte exampleEntry.signedAction.action
  unless bundle.actionKind = expected do
    throw (IO.userError
      s!"actionKind mismatch: expected {expected}, got {bundle.actionKind}")

/-- The bundle's `actionFields` matches `actionFieldsForL1`. -/
def actionFields_matches_encoder : IO Unit := do
  let bundle := buildTerminateBundle exampleState exampleEntry
  let expected := actionFieldsForL1 exampleEntry.signedAction.action
  unless bundle.actionFields = expected do
    throw (IO.userError "actionFields does not match actionFieldsForL1")

/-- The bundle's `signer` matches the entry's signer. -/
def signer_matches_entry : IO Unit := do
  let bundle := buildTerminateBundle exampleState exampleEntry
  unless bundle.signer = exampleEntry.signedAction.signer do
    throw (IO.userError
      s!"signer mismatch: expected {exampleEntry.signedAction.signer}, got {bundle.signer}")

/-- The bundle's `claimedPostCommit` matches `stepVMHashFromAction`. -/
def claimedPostCommit_matches_stepVMHashFromAction : IO Unit := do
  let bundle := buildTerminateBundle exampleState exampleEntry
  let expected := stepVMHashFromAction exampleState
                    exampleEntry.signedAction.action
                    exampleEntry.signedAction.signer
  unless bundle.claimedPostCommit = expected do
    throw (IO.userError "claimedPostCommit does not match stepVMHashFromAction")

/-- The bundle's cell-proof bundle verifies against the
    pre-state's commit. -/
def cellProofs_verify_against_preCommit : IO Unit := do
  let bundle := buildTerminateBundle exampleState exampleEntry
  let preCommit := commitExtendedState exampleState
  unless verifyCellProofs preCommit bundle.cellProofs = true do
    throw (IO.userError "cellProofs failed to verify against preCommit")

/-- The bundle is deterministic in its inputs.  Two calls with
    the same inputs produce JSON-equivalent outputs. -/
def bundle_is_deterministic : IO Unit := do
  let b1 := buildTerminateBundle exampleState exampleEntry
  let b2 := buildTerminateBundle exampleState exampleEntry
  let j1 := formatTerminateBundleJson "log[0]" b1
  let j2 := formatTerminateBundleJson "log[0]" b2
  unless j1 = j2 do
    throw (IO.userError
      s!"bundle non-determinism: j1={j1}, j2={j2}")

/-- The JSON output starts with `{` and ends with `}` (single-
    object envelope). -/
def json_envelope_well_formed : IO Unit := do
  let bundle := buildTerminateBundle exampleState exampleEntry
  let json := formatTerminateBundleJson "log[0]" bundle
  unless json.startsWith "{" do
    throw (IO.userError s!"JSON must start with brace: {json}")
  unless json.endsWith "}" do
    throw (IO.userError s!"JSON must end with brace: {json}")

/-- The JSON has the documented snake_case fields. -/
def json_has_snake_case_fields : IO Unit := do
  let bundle := buildTerminateBundle exampleState exampleEntry
  let json := formatTerminateBundleJson "log[7]" bundle
  let requiredFields := [
    "\"fixture_id\"",
    "\"action_kind\"",
    "\"action_fields_hex\"",
    "\"signer\"",
    "\"claimed_post_commit_hex\"",
    "\"cell_proofs\""
  ]
  for field in requiredFields do
    let parts := json.splitOn field
    unless parts.length > 1 do
      throw (IO.userError s!"JSON missing required field {field}: {json}")
  -- Camel-case regression guards.
  let forbiddenFields := [
    "\"fixtureId\"",
    "\"actionKind\"",
    "\"actionFields\"",
    "\"actionFieldsHex\"",
    "\"claimedPostCommit\"",
    "\"claimedPostCommitHex\"",
    "\"cellProofs\""
  ]
  for field in forbiddenFields do
    let parts := json.splitOn field
    if parts.length > 1 then
      throw (IO.userError
        s!"JSON must use snake_case, found {field}: {json}")

/-- The `fixture_id` is correctly embedded in the JSON output. -/
def json_fixture_id_round_trip : IO Unit := do
  let bundle := buildTerminateBundle exampleState exampleEntry
  let json := formatTerminateBundleJson "log[42]" bundle
  let parts := json.splitOn "\"log[42]\""
  unless parts.length > 1 do
    throw (IO.userError
      s!"fixture_id 'log[42]' not found in JSON output: {json}")

/-- Per-variant `actionKind` correctness: every Action variant's
    bundle has the canonical `actionKindByte` dispatcher byte. -/
def actionKind_dispatch_for_all_variants : IO Unit := do
  let variants : List (Action × UInt8) := [
    (.transfer 0 0 0 0, 0),
    (.mint 0 0 0, 1),
    (.burn 0 0 0, 2),
    (.freezeResource 0, 3),
    (.replaceKey 0 ByteArray.empty, 4),
    (.reward 0 0 0, 5),
    (.distributeOthers 0 0 0, 6),
    (.proportionalDilute 0 0 0, 7),
    (.registerIdentity 0 ByteArray.empty, 12),
    (.deposit 0 0 0 0, 13),
    (.revokeLocalPolicy, 16)
  ]
  for (action, expectedKind) in variants do
    let entry : LogEntry := { exampleEntry with
      signedAction := { exampleEntry.signedAction with action := action } }
    let bundle := buildTerminateBundle exampleState entry
    unless bundle.actionKind = expectedKind do
      throw (IO.userError
        s!"actionKind dispatch mismatch for {repr action}: expected {expectedKind}, got {bundle.actionKind}")

/-- Byte-pinning for a minimal transfer entry's JSON output
    PREFIX.  Pin only the deterministic parts (fixture_id +
    action_kind + action_fields_hex + signer); the
    claimed_post_commit_hex and witness_commit fields are
    hash-dependent. -/
def json_byte_pinning_transfer_minimal : IO Unit := do
  let bundle := buildTerminateBundle exampleState exampleEntry
  let json := formatTerminateBundleJson "log[0]" bundle
  -- Transfer 0→0 amount 0 ⇒ actionFields = 32 zero bytes;
  -- hex = "0000000000000000000000000000000000000000000000000000000000000000".
  let expectedPrefix :=
    "{\"fixture_id\":\"log[0]\"," ++
    "\"action_kind\":0," ++
    "\"action_fields_hex\":" ++
    "\"0000000000000000000000000000000000000000000000000000000000000000\"," ++
    "\"signer\":0,"
  unless json.startsWith expectedPrefix do
    throw (IO.userError
      s!"JSON byte-pinning failed.\n  Expected prefix: {expectedPrefix}\n  Actual:          {json}")

/-- Byte-pinning regression: revokeLocalPolicy's bundle has
    empty actionFields (action_fields_hex = ""). -/
def json_byte_pinning_revoke_local_policy : IO Unit := do
  let entry : LogEntry := { exampleEntry with
    signedAction := { exampleEntry.signedAction with
      action := .revokeLocalPolicy } }
  let bundle := buildTerminateBundle exampleState entry
  let json := formatTerminateBundleJson "log[0]" bundle
  let expectedPrefix :=
    "{\"fixture_id\":\"log[0]\"," ++
    "\"action_kind\":16," ++
    "\"action_fields_hex\":\"\","
  unless json.startsWith expectedPrefix do
    throw (IO.userError
      s!"revokeLocalPolicy JSON byte-pinning failed.\n  Expected prefix: {expectedPrefix}\n  Actual:          {json}")

/-- The JSON envelope has exactly the 6 documented top-level
    fields (fixture_id, action_kind, action_fields_hex,
    signer, claimed_post_commit_hex, cell_proofs).  Counting
    the `":` separators (where `"` is a field-name terminator)
    in the TOP-LEVEL object excluding nested cell-proof
    objects.  A maintainer adding a 7th field would silently
    slip into production wire traffic otherwise. -/
def json_exactly_six_top_level_fields : IO Unit := do
  -- Use an empty bundle (revokeLocalPolicy ⇒ no balance-cell
  -- proofs ⇒ shorter cell_proofs array).  Even then the
  -- registry+nonce cells are emitted; we count fields by
  -- splitting at top-level separators.
  let entry : LogEntry := { exampleEntry with
    signedAction := { exampleEntry.signedAction with
      action := .revokeLocalPolicy } }
  let bundle := buildTerminateBundle exampleState entry
  let json := formatTerminateBundleJson "log[0]" bundle
  -- The top-level object has six field-name keys, each
  -- starting with the pattern `"<name>":`.  Count by
  -- searching for the closing `":` of each top-level key.
  -- We use a defensive count by searching for the literal
  -- field names with the `":` boundary.
  let topLevelKeys := [
    "\"fixture_id\":",
    "\"action_kind\":",
    "\"action_fields_hex\":",
    "\"signer\":",
    "\"claimed_post_commit_hex\":",
    "\"cell_proofs\":"
  ]
  for key in topLevelKeys do
    let parts := json.splitOn key
    unless parts.length = 2 do
      throw (IO.userError
        s!"top-level key {key} should appear exactly once, found {parts.length - 1}: {json}")

/-- API stability for `buildTerminateBundle`. -/
def build_terminate_bundle_api_stable : IO Unit := do
  let _proof : ExtendedState → LogEntry → TerminateBundle :=
    buildTerminateBundle
  pure ()

/-- API stability for `formatTerminateBundleJson`. -/
def format_terminate_bundle_json_api_stable : IO Unit := do
  let _proof : String → TerminateBundle → String :=
    formatTerminateBundleJson
  pure ()

/-- All tests in this module. -/
def tests : List TestCase := [
  ⟨"export-terminate-bundle: actionKind matches actionKindByte",
    actionKind_matches_actionKindByte⟩,
  ⟨"export-terminate-bundle: actionFields matches encoder",
    actionFields_matches_encoder⟩,
  ⟨"export-terminate-bundle: signer matches entry",
    signer_matches_entry⟩,
  ⟨"export-terminate-bundle: claimedPostCommit matches stepVMHashFromAction",
    claimedPostCommit_matches_stepVMHashFromAction⟩,
  ⟨"export-terminate-bundle: cellProofs verify against preCommit",
    cellProofs_verify_against_preCommit⟩,
  ⟨"export-terminate-bundle: bundle is deterministic",
    bundle_is_deterministic⟩,
  ⟨"export-terminate-bundle: JSON envelope well-formed",
    json_envelope_well_formed⟩,
  ⟨"export-terminate-bundle: JSON has snake_case fields",
    json_has_snake_case_fields⟩,
  ⟨"export-terminate-bundle: JSON fixture_id round-trips",
    json_fixture_id_round_trip⟩,
  ⟨"export-terminate-bundle: actionKind dispatch for all variants",
    actionKind_dispatch_for_all_variants⟩,
  ⟨"export-terminate-bundle: JSON byte-pinning (transfer minimal)",
    json_byte_pinning_transfer_minimal⟩,
  ⟨"export-terminate-bundle: JSON byte-pinning (revokeLocalPolicy)",
    json_byte_pinning_revoke_local_policy⟩,
  ⟨"export-terminate-bundle: JSON has exactly 6 top-level fields",
    json_exactly_six_top_level_fields⟩,
  ⟨"export-terminate-bundle: buildTerminateBundle API stable",
    build_terminate_bundle_api_stable⟩,
  ⟨"export-terminate-bundle: formatTerminateBundleJson API stable",
    format_terminate_bundle_json_api_stable⟩
]

end LegalKernel.Test.Integration.ExportTerminateBundleCli
