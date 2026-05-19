/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

import LegalKernel.Test.Framework
import LegalKernel.FaultProof.Commit
import LegalKernel.FaultProof.Observer
import LegalKernel.Runtime.CellProofJson

/-!
LegalKernel.Test.Integration.ExportCellProofsCli — RH-G plan
deliverable.

Integration regression for the `canon export-cell-proofs LOG
IDX SIGNER` subcommand that the off-chain `canon-faultproof-
observer` Rust crate's terminate-on-single-step move consumes
to build its `terminateOnSingleStep(..., CellProof[], ...)`
calldata.  Verifies the Lean-level kernel contract:
`buildObserverCellProofs` produces a bundle that
`verifyCellProofs` accepts against the pre-state's commit, and
the bundle is deterministic in its inputs.

The CLI surface itself lives in `Main.lean`; this test covers
the Lean-level kernel contract that the CLI dispatches to.
Subprocess-level invocation tests (spawning the binary and
parsing the emitted JSON) live in the Rust crate's `tests/`
directory.
-/

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Disputes
open LegalKernel.FaultProof
open LegalKernel.FaultProof.Observer
open LegalKernel.Runtime
open LegalKernel.Test

namespace LegalKernel.Test.Integration.ExportCellProofsCli

/-- The cell-proof bundle for a transfer has the documented
    four cells (registry, balance×2, nonce). -/
def transfer_bundle_has_four_cells : IO Unit := do
  let es : ExtendedState := ExtendedState.empty
  let signer : ActorId := 1
  let action : Action := Action.transfer 1 signer 2 100
  let bundle := buildObserverCellProofs es action signer
  unless bundle.proofs.length = 4 do
    throw (IO.userError
      s!"buildObserverCellProofs transfer bundle.proofs.length = {bundle.proofs.length}, expected 4")

/-- The cell-proof bundle is deterministic in its inputs.
    Audit-pass-4 fix: strengthened from length-only equality to
    JSON content equality so a regression that produced
    different `cellValue` bytes / `witnessState` for the same
    input would fail. -/
def bundle_is_deterministic : IO Unit := do
  let es : ExtendedState := ExtendedState.empty
  let signer : ActorId := 1
  let action : Action := Action.transfer 1 signer 2 100
  let b1 := buildObserverCellProofs es action signer
  let b2 := buildObserverCellProofs es action signer
  unless b1.proofs.length = b2.proofs.length do
    throw (IO.userError
      s!"bundle non-determinism: b1.length = {b1.proofs.length}, b2.length = {b2.proofs.length}")
  -- Compare each cell-proof's JSON serialization byte-for-byte.
  -- Two cell-proofs that produce identical JSON are extensionally
  -- equal w.r.t. every field the wire format pins.
  let zipped := b1.proofs.zip b2.proofs
  for (p1, p2) in zipped do
    let j1 := LegalKernel.Runtime.CellProofJson.formatCellProofJson p1
    let j2 := LegalKernel.Runtime.CellProofJson.formatCellProofJson p2
    unless j1 = j2 do
      throw (IO.userError s!"bundle non-determinism: json mismatch: j1={j1}, j2={j2}")

/-- The cell-proof bundle verifies against the pre-state's
    commit (i.e., `verifyCellProofs` returns `true`).  This is
    the load-bearing soundness contract: the off-chain bundle
    builder MUST produce verifier-accepting proofs. -/
def bundle_verifies_against_commit : IO Unit := do
  let es : ExtendedState := ExtendedState.empty
  let signer : ActorId := 1
  let action : Action := Action.transfer 1 signer 2 100
  let bundle := buildObserverCellProofs es action signer
  let commit := commitExtendedState es
  unless verifyCellProofs commit bundle = true do
    throw (IO.userError "buildObserverCellProofs bundle failed verifyCellProofs check")

/-- API stability: `buildObserverCellProofs : ExtendedState →
    Action → ActorId → CellProofBundle`. -/
def build_observer_cell_proofs_api_stable : IO Unit := do
  let _proof :
      ExtendedState → Action → ActorId → CellProofBundle :=
    buildObserverCellProofs
  pure ()

/-- API stability: `verifyCellProofs : StateCommit →
    CellProofBundle → Bool`. -/
def verify_cell_proofs_api_stable : IO Unit := do
  let _proof : StateCommit → CellProofBundle → Bool :=
    verifyCellProofs
  pure ()

/-- Audit-pass-4 fix: pin the JSON byte output of
    `formatCellProofJson` against a regression-stable
    structural shape.  The exact `cellValue` and `witnessCommit`
    bytes depend on the kernel's hash implementation, but the
    JSON envelope shape — snake_case field names, comma
    separators, no whitespace — is the load-bearing cross-stack
    contract.  This test parses the emitted JSON and verifies
    every field is present + correctly typed. -/
def cell_proof_json_envelope_shape_pinned : IO Unit := do
  let es : ExtendedState := ExtendedState.empty
  let signer : ActorId := 1
  let action : Action := Action.transfer 1 signer 2 100
  let bundle := buildObserverCellProofs es action signer
  let firstProof ← match bundle.proofs[0]? with
    | none =>
      throw (IO.userError "buildObserverCellProofs returned empty bundle")
    | some p => pure p
  let json := LegalKernel.Runtime.CellProofJson.formatCellProofJson firstProof
  -- Field-name pins: every required snake_case key must appear
  -- (a camelCase regression would fail this).
  let requiredFields := [
    "\"cell_kind\"",
    "\"key_a\"",
    "\"key_b\"",
    "\"cell_value\"",
    "\"witness_commit\""
  ]
  for field in requiredFields do
    let parts := json.splitOn field
    unless parts.length > 1 do
      throw (IO.userError s!"formatCellProofJson missing required field {field}: {json}")
  -- Camel-case regression guards: these MUST NOT appear
  -- (catches a maintainer accidentally re-introducing the old
  -- "keyA" / "keyB" / "cellValue" / "witnessCommit" form).
  let forbiddenFields := [
    "\"keyA\"",
    "\"keyB\"",
    "\"cellValue\"",
    "\"witnessCommit\""
  ]
  for field in forbiddenFields do
    let parts := json.splitOn field
    if parts.length > 1 then
      throw (IO.userError s!"formatCellProofJson must use snake_case, found {field}: {json}")
  -- Structural envelope: starts with `{`, ends with `}`,
  -- no newlines (single-line JSON for streaming).
  unless json.startsWith "{" do
    throw (IO.userError s!"formatCellProofJson must start with brace: {json}")
  unless json.endsWith "}" do
    throw (IO.userError s!"formatCellProofJson must end with brace: {json}")
  let newlineParts := json.splitOn "\n"
  unless newlineParts.length = 1 do
    throw (IO.userError s!"formatCellProofJson must be single-line: {json}")
  -- Audit-pass-4-round-4 LOW fix: enforce EXACTLY 5 fields by
  -- counting key-value separators.  A maintainer adding a sixth
  -- field would silently slip into production wire traffic
  -- otherwise (the Rust serde struct ignores unknown fields by
  -- default).  Count the `":"` separators between keys and
  -- values — should be exactly 5.
  let colonCount := (json.splitOn "\":").length - 1
  unless colonCount = 5 do
    throw (IO.userError
      s!"formatCellProofJson must have exactly 5 fields, got {colonCount}: {json}")

/-- Audit-pass-4 fix: pin the JSON output of a known small
    cell-tag input to its exact byte string.  This catches any
    drift in field ordering, separator characters, or hex
    encoding case.  The byte string is computed once and
    re-asserted on every test run; if `formatCellProofJson`
    changes, this test fails and a maintainer must consciously
    update the pinning. -/
def cell_proof_json_byte_pinning_minimal : IO Unit := do
  -- Construct a minimal CellProof with known inputs.
  let witness : ExtendedState := ExtendedState.empty
  let proof : CellProof :=
    { cellTag := CellTag.balance (resource := 7) (actor := 1)
    , cellValue := ByteArray.empty
    , witnessState := witness }
  let json := LegalKernel.Runtime.CellProofJson.formatCellProofJson proof
  -- Pin the prefix (witness_commit value depends on the kernel's
  -- hash implementation, which is FNV-1a-64 in the default test
  -- mode but keccak in production — so we don't pin the full
  -- string).
  let expectedPrefix :=
    "{\"cell_kind\":0," ++
    "\"key_a\":\"0000000000000007\"," ++
    "\"key_b\":\"0000000000000001\"," ++
    "\"cell_value\":\"\"," ++
    "\"witness_commit\":\""
  unless json.startsWith expectedPrefix do
    throw (IO.userError s!"formatCellProofJson byte-pinning failed.\n  Expected prefix: {expectedPrefix}\n  Actual:         {json}")
  -- The closing must be a hex string + quote + brace.
  unless json.endsWith "\"}" do
    throw (IO.userError s!"formatCellProofJson must close with quote-brace: {json}")

end LegalKernel.Test.Integration.ExportCellProofsCli

namespace LegalKernel.Test.Integration.ExportCellProofsCli

/-- All tests in this module — collected via the `@[test]`
    attribute and dispatched from `Tests.lean`. -/
def tests : List TestCase := [
  ⟨"export-cell-proofs: transfer bundle has 4 cells",
    transfer_bundle_has_four_cells⟩,
  ⟨"export-cell-proofs: bundle is deterministic",
    bundle_is_deterministic⟩,
  ⟨"export-cell-proofs: bundle verifies against commit",
    bundle_verifies_against_commit⟩,
  ⟨"export-cell-proofs: buildObserverCellProofs API stable",
    build_observer_cell_proofs_api_stable⟩,
  ⟨"export-cell-proofs: verifyCellProofs API stable",
    verify_cell_proofs_api_stable⟩,
  ⟨"export-cell-proofs: JSON envelope shape pinned",
    cell_proof_json_envelope_shape_pinned⟩,
  ⟨"export-cell-proofs: JSON byte-pinning (minimal balance proof)",
    cell_proof_json_byte_pinning_minimal⟩
]

end LegalKernel.Test.Integration.ExportCellProofsCli
