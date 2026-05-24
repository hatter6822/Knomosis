/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.TerminateBundle — Workstream SVC.3:
canonical bundle of inputs the off-chain observer submits to
`CanonFaultProofGame.terminateOnSingleStep` on L1.

The L1 contract's terminate-on-single-step entry point has the
signature:

```solidity
function terminateOnSingleStep(
    uint256 gameId,
    uint8 actionKind,
    bytes calldata actionFields,
    uint64 signer,
    CanonStepVM.CellProof[] calldata cellProofs,
    bytes32 claimedPostCommit
) external nonReentrant
```

The five non-`gameId` arguments are derivable from a canonical
`(ExtendedState, LogEntry)` pair via the per-variant encoders this
module composes:

  * `actionKind`        := `actionKindByte action`
  * `actionFields`      := `actionFieldsForL1 action`
  * `signer`            := `entry.signedAction.signer`
  * `cellProofs`        := `buildObserverCellProofs preState action signer`
  * `claimedPostCommit` := `stepVMHashFromAction preState action signer`

A `TerminateBundle` value bundles these five fields; the
`buildTerminateBundle` function constructs the canonical bundle
for a (pre-state, log-entry) pair.

## Wire format

The bundle's JSON formatter (`formatTerminateBundleJson`) emits a
single JSON object with snake_case fields matching the Rust
serde-deserialize default conventions, so the Rust observer's
`TerminateBundle` struct can consume the output without renames:

```json
{
  "fixture_id": "log[7]",
  "action_kind": 0,
  "action_fields_hex": "00000000000000010000000000000002000...",
  "signer": 5,
  "claimed_post_commit_hex": "abcd1234...",
  "cell_proofs": [
    {"cell_kind": 0, "key_a": "0x01", "key_b": "0x05", ...},
    ...
  ]
}
```

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.Coherence
import LegalKernel.FaultProof.Commit
import LegalKernel.FaultProof.Observer
import LegalKernel.FaultProof.StepVMCoherence
import LegalKernel.Runtime.CellProofJson
import LegalKernel.Runtime.LogFile

namespace LegalKernel
namespace FaultProof
namespace TerminateBundle

open LegalKernel.Authority
open LegalKernel.FaultProof
open LegalKernel.FaultProof.StepVMCoherence
open LegalKernel.Runtime

/-! ## Bundle type

The bundle carries every input the L1 `terminateOnSingleStep`
contract function consumes (besides the `gameId`, which is
operator-supplied at submission time and not part of the kernel-
derived bundle). -/

/-- The canonical bundle of inputs for
    `CanonFaultProofGame.terminateOnSingleStep`.  Built from a
    `(pre-state, log-entry)` pair via `buildTerminateBundle`.

    All five fields are derived deterministically from the input
    pair plus the per-variant encoders.  Bundle construction is
    pure (no IO, no error paths); validity is established by the
    builder's contract:
      * `claimedPostCommit` equals what the L1 step VM would
        compute on the same inputs (under the production keccak256
        binding).
      * `cellProofs` includes proofs for every cell the per-variant
        step VM consumes (per `Action.requiredCells`).
      * `actionFields` is the canonical byte layout the L1's
        `_stepXX` decoder expects (per `actionFieldsForL1`). -/
structure TerminateBundle where
  /-- Action-variant dispatcher (0..20 post-Workstream-GP, per
      `actionKindByte`). -/
  actionKind        : UInt8
  /-- Canonical fields' byte layout per
      `actionFieldsForL1`. -/
  actionFields      : ByteArray
  /-- The signer's `ActorId` (= log entry's `signer`).  64-bit. -/
  signer            : ActorId
  /-- The canonical step-VM hash for this step.  Under the
      production keccak256 binding, this equals what
      `CanonStepVM.executeStep` returns on the same inputs. -/
  claimedPostCommit : ByteArray
  /-- The cell-proof bundle for the action's required cells,
      witnessed by the pre-state. -/
  cellProofs        : CellProofBundle
  deriving Repr

/-! ## Bundle builder

The canonical builder threads the per-variant encoders together: -/

/-- Build the canonical terminate bundle for applying `entry` to
    pre-state `preState`.

    Equation:
      `actionKind        := actionKindByte action`
      `actionFields      := actionFieldsForL1 action`
      `signer            := entry.signedAction.signer`
      `claimedPostCommit := stepVMHashFromAction preState action signer`
      `cellProofs        := buildObserverCellProofs preState action signer`

    Pre-conditions:
    * The entry's action must be admissible at `preState` (otherwise
      the cell proofs may witness an absent cell that the L1's
      `_stepXX` decoder will reject).  Admissibility is the
      caller's responsibility; the bundle is constructed
      unconditionally so test fixtures and debugging tools can
      emit it for any input pair. -/
def buildTerminateBundle
    (preState : ExtendedState) (entry : LogEntry) : TerminateBundle :=
  let action := entry.signedAction.action
  let signer := entry.signedAction.signer
  { actionKind        := actionKindByte action,
    actionFields      := actionFieldsForL1 action,
    signer            := signer,
    claimedPostCommit := stepVMHashFromAction preState action signer,
    cellProofs        := Observer.buildObserverCellProofs preState action signer }

/-! ## Well-formedness theorems -/

/-- `buildTerminateBundle` is deterministic. -/
theorem buildTerminateBundle_deterministic
    (es₁ es₂ : ExtendedState) (e₁ e₂ : LogEntry)
    (h_es : es₁ = es₂) (h_e : e₁ = e₂) :
    buildTerminateBundle es₁ e₁ = buildTerminateBundle es₂ e₂ := by
  rw [h_es, h_e]

/-- The bundle's `actionKind` agrees with `actionKindByte`. -/
theorem buildTerminateBundle_actionKind
    (es : ExtendedState) (entry : LogEntry) :
    (buildTerminateBundle es entry).actionKind =
    actionKindByte entry.signedAction.action := rfl

/-- The bundle's `actionFields` agrees with `actionFieldsForL1`. -/
theorem buildTerminateBundle_actionFields
    (es : ExtendedState) (entry : LogEntry) :
    (buildTerminateBundle es entry).actionFields =
    actionFieldsForL1 entry.signedAction.action := rfl

/-- The bundle's `signer` agrees with the entry's signer. -/
theorem buildTerminateBundle_signer
    (es : ExtendedState) (entry : LogEntry) :
    (buildTerminateBundle es entry).signer =
    entry.signedAction.signer := rfl

/-- The bundle's `claimedPostCommit` agrees with
    `stepVMHashFromAction`. -/
theorem buildTerminateBundle_claimedPostCommit
    (es : ExtendedState) (entry : LogEntry) :
    (buildTerminateBundle es entry).claimedPostCommit =
    stepVMHashFromAction es entry.signedAction.action
      entry.signedAction.signer := rfl

/-- The bundle's `cellProofs` agrees with
    `buildObserverCellProofs`. -/
theorem buildTerminateBundle_cellProofs
    (es : ExtendedState) (entry : LogEntry) :
    (buildTerminateBundle es entry).cellProofs =
    Observer.buildObserverCellProofs es entry.signedAction.action
      entry.signedAction.signer := rfl

/-- The bundle's cell-proof bundle verifies against the pre-state
    commit.  Direct from `buildObserverCellProofs_verifies`. -/
theorem buildTerminateBundle_cellProofs_verify
    (es : ExtendedState) (entry : LogEntry) :
    verifyCellProofs (commitExtendedState es)
      (buildTerminateBundle es entry).cellProofs = true := by
  rw [buildTerminateBundle_cellProofs]
  exact Observer.buildObserverCellProofs_verifies _ _ _

/-! ## JSON formatter

The Rust observer's `TerminateBundle` struct consumes this JSON
shape; field names are snake_case to match serde-deserialize
defaults. -/

open LegalKernel.Runtime.CellProofJson

/-- Format a `UInt8` as a decimal string (no `0x` prefix). -/
def formatUInt8 (b : UInt8) : String :=
  toString b.toNat

/-- Format a `UInt64` (as `ActorId`) as a decimal string. -/
def formatUInt64 (n : UInt64) : String :=
  toString n.toNat

/-- Format the `cellProofs` list as a JSON array (one cell-proof
    object per element).  Uses the existing `formatCellProofJson`
    formatter. -/
def formatCellProofsArray (bundle : CellProofBundle) : String :=
  let entries := bundle.proofs.map formatCellProofJson
  let joined := match entries with
    | [] => ""
    | x :: xs => xs.foldl (fun acc e => acc ++ "," ++ e) x
  "[" ++ joined ++ "]"

/-- Format a `TerminateBundle` as a single line of JSON.

    Snake_case field names match Rust serde-deserialize defaults
    so the Rust observer's `TerminateBundle` struct can consume
    the output without renames.

    The `fixture_id` argument is the operator-supplied identifier
    for the bundle (e.g., "log[7]" for the bundle at log index 7).
    It's passed through to the JSON so a multi-bundle export can
    distinguish entries. -/
def formatTerminateBundleJson (fixtureId : String)
    (bundle : TerminateBundle) : String :=
  let q := "\""
  let actionFieldsHex := bytesHex bundle.actionFields
  let claimedPostCommitHex := bytesHex bundle.claimedPostCommit
  let cellProofsArr := formatCellProofsArray bundle.cellProofs
  let parts : List String := [
    "{",
    q ++ "fixture_id" ++ q, ":", q ++ fixtureId ++ q, ",",
    q ++ "action_kind" ++ q, ":", formatUInt8 bundle.actionKind, ",",
    q ++ "action_fields_hex" ++ q, ":", q ++ actionFieldsHex ++ q, ",",
    q ++ "signer" ++ q, ":", formatUInt64 bundle.signer, ",",
    q ++ "claimed_post_commit_hex" ++ q, ":",
      q ++ claimedPostCommitHex ++ q, ",",
    q ++ "cell_proofs" ++ q, ":", cellProofsArr,
    "}"
  ]
  String.join parts

/-! ## Smoke checks -/

/-- An empty bundle's cell-proofs array formats as `[]`. -/
example : formatCellProofsArray { proofs := [] } = "[]" := rfl

/-- `formatUInt8 0 = "0"`. -/
example : formatUInt8 0 = "0" := rfl

/-- `formatUInt8 18 = "18"`. -/
example : formatUInt8 18 = "18" := rfl

end TerminateBundle
end FaultProof
end LegalKernel
