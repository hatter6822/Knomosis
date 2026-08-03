-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.TerminateBundle — Workstream SVC.3:
canonical bundle of inputs the off-chain observer submits to
`KnomosisFaultProofGame.terminateOnSingleStep` on L1.

The L1 contract's terminate-on-single-step entry point has the
signature:

```solidity
function terminateOnSingleStep(
    uint256 gameId,
    uint8 actionKind,
    bytes calldata actionFields,
    uint64 signer,
    KnomosisStepVM.CellProof[] calldata cellProofs
) external nonReentrant
```

**Five arguments, not six.**  This block used to spell a trailing
`bytes32 claimedPostCommit`, and the Rust submitter was built
against that shape — a different 4-byte selector, so every honest
terminate reverted into the unknown-selector fallback.  The
contract's shape is also the better design: it runs the step VM
from `g.low.commit` and compares the result against
`g.high.commit`, both already on-chain, so the post-commit is not
the caller's to claim.

The four non-`gameId` arguments are derivable from a canonical
`(ExtendedState, LogEntry)` pair via the per-variant encoders this
module composes:

  * `actionKind`   := `actionKindByte action`
  * `actionFields` := `actionFieldsForL1 action`
  * `signer`       := `entry.signedAction.signer`
  * `cellProofs`   := `buildObserverCellProofs preState action signer`

A `TerminateBundle` carries those four plus
`expectedPostCommit := stepVMHashFromAction preState action signer`.
The fifth is **not** calldata: it is what the observer expects the
step VM to compute, retained so the observer can cross-check its
own bundle against an independent oracle before broadcasting
(`BundleCommitMismatch`).  Shipping it would change the selector.

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
  "expected_post_commit_hex": "abcd1234...",
  "cell_proofs": [
    {"cell_kind": 0, "key_a": "0x01", "key_b": "0x05",
     "cell_value": "...", "witness_commit": "...",
     "proof_data": "..."},
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
import LegalKernel.FaultProof.Terminate
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
    `KnomosisFaultProofGame.terminateOnSingleStep`.  Built from a
    `(pre-state, log-entry)` pair via `buildTerminateBundle`.

    All five fields are derived deterministically from the input
    pair plus the per-variant encoders.  Bundle construction is
    pure (no IO, no error paths); validity is established by the
    builder's contract:
      * `expectedPostCommit` equals what the L1 step VM would
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
      `KnomosisStepVM.executeStep` returns on the same inputs.

      **Not part of the calldata** — see the module docstring.  The
      contract derives both sides of its comparison from the game
      state; this field exists so the observer can check its own
      bundle against an independent oracle before it broadcasts. -/
  expectedPostCommit : ByteArray
  /-- The log index this step produces.  Not an action field:
      `withdraw`'s pending-withdrawal record carries it, so the fold
      has to know which index it is adjudicating.

      **Not on the wire either.**  The L1 reads it from the game
      (`g.high.idx`) rather than from the caller, so shipping it would
      offer a responder a value to disagree with.  It is retained here
      because the builder needs it to compute `expectedPostCommit`. -/
  l2LogIndex        : Nat
  /-- The step's FRONTIER: every cell the step opens, with its proven
      PRE-state value, in path order.

      Replaced a `policyProof` + `cellProofs` pair.  The read-only
      budget-policy cell is IN here rather than beside it — under a
      multiproof a read is a write of the same value, so it is one more
      cell and costs no separate walk.  And a cell the step writes
      twice (a self-transfer, which anyone can submit) appears ONCE:
      every opening is against the same root, so the second one carried
      no information the first did not.

      Order is free on the wire — the L1 sorts by path index — but the
      builder emits path order anyway, which is what the walk consumes. -/
  openedCells       : List (CellTag × ByteArray)
  /-- The single shared wire: a gap mask, then the siblings the mask
      marks as non-canonical-empty.

      One list rather than one path per opening.  Sound because every
      sibling is the root of a sub-tree holding no opened cell, so the
      step's writes cannot move it and the pre- and post-folds share
      it — `multiSiblings_congr` is the Lean statement of that. -/
  wire              : SmtMultiProof
  deriving Repr

/-! ## Bundle builder

The canonical builder threads the per-variant encoders together: -/

/-- Build the canonical terminate bundle for applying `entry` to
    pre-state `preState`.

    Equation:
      `actionKind        := actionKindByte action`
      `actionFields      := actionFieldsForL1 action`
      `signer            := entry.signedAction.signer`
      `expectedPostCommit := stepVMHashFromAction preState action signer`
      `cellProofs        := buildObserverCellProofs preState action signer`

    Pre-conditions:
    * The entry's action must be admissible at `preState` (otherwise
      the cell proofs may witness an absent cell that the L1's
      `_stepXX` decoder will reject).  Admissibility is the
      caller's responsibility; the bundle is constructed
      unconditionally so test fixtures and debugging tools can
      emit it for any input pair. -/
def buildTerminateBundle
    (preState : ExtendedState) (entry : LogEntry) (l2LogIndex : Nat := 0) :
    TerminateBundle :=
  let action := entry.signedAction.action
  let signer := entry.signedAction.signer
  { actionKind        := actionKindByte action,
    actionFields      := actionFieldsForL1 action,
    signer            := signer,
    l2LogIndex        := l2LogIndex,
    expectedPostCommit :=
      (stepMultiPostRoot preState entry.signedAction l2LogIndex).getD
        ByteArray.empty,
    openedCells       := (stepMultiBundle preState entry.signedAction).cells,
    wire              := (stepMultiBundle preState entry.signedAction).proof }

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

/-- The bundle's `expectedPostCommit` is the fold's result — the root
    an L1 reaches from the pre-root and these openings, and the value
    the observer cross-checks before broadcasting.

    It was `stepVMHashFromAction`, a bespoke per-variant hash living
    outside state-root space, so the contract's terminal comparison
    against `g.high.commit` could never succeed. -/
theorem buildTerminateBundle_expectedPostCommit
    (es : ExtendedState) (entry : LogEntry) (idx : Nat) :
    (buildTerminateBundle es entry idx).expectedPostCommit =
    (stepMultiPostRoot es entry.signedAction idx).getD ByteArray.empty := rfl

/-- The bundle's opened cells are the honest sequencer's frontier. -/
theorem buildTerminateBundle_openedCells
    (es : ExtendedState) (entry : LogEntry) (idx : Nat) :
    (buildTerminateBundle es entry idx).openedCells =
    (stepMultiBundle es entry.signedAction).cells := rfl

/-- The bundle's wire is the honest sequencer's. -/
theorem buildTerminateBundle_wire
    (es : ExtendedState) (entry : LogEntry) (idx : Nat) :
    (buildTerminateBundle es entry idx).wire =
    (stepMultiBundle es entry.signedAction).proof := rfl

/-- **The bundle's cells are exactly the step's frontier** — the cells
    the action writes plus the read-only budget policy, deduplicated
    and in path order.

    The L1 re-derives that list and compares, so an observer that
    dropped a cell, added one, or named one twice fails the shape check
    rather than folding to a root no state has.  Order is NOT part of
    the comparison — the verifier sorts — but the builder emits the
    sorted form, which is what this states. -/
theorem buildTerminateBundle_openedCells_tags
    (es : ExtendedState) (entry : LogEntry) (idx : Nat) :
    (buildTerminateBundle es entry idx).openedCells.map Prod.fst
      = multiFrontierOf entry.signedAction.action entry.signedAction.signer
          es.bridge.nextWdId := by
  show ((multiFrontierOf entry.signedAction.action entry.signedAction.signer
          es.bridge.nextWdId).map (fun t => (t, getCellValue es t))).map Prod.fst = _
  rw [List.map_map]
  exact List.map_id _


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

/-- Format one opened cell as a JSON object.

    The same `cell_kind` / `key_a` / `key_b` shape a cell proof used,
    minus the opening: under a multiproof every cell is opened against
    the same root and they share one sibling list, so a per-cell
    `proof_data` would be a field with nothing to put in it. -/
def formatOpenedCellJson (c : CellTag × ByteArray) : String :=
  let (kind, keyA, keyB) := LegalKernel.Runtime.CellProofJson.formatCellTag c.1
  let q := "\""
  String.join
    [ "{", q ++ "cell_kind" ++ q, ":", kind, ","
    , q ++ "key_a" ++ q, ":", q ++ keyA ++ q, ","
    , q ++ "key_b" ++ q, ":", q ++ keyB ++ q, ","
    , q ++ "pre_value" ++ q, ":", q ++ bytesHex c.2 ++ q
    , "}" ]

/-- Format the frontier as a JSON array. -/
def formatOpenedCellsArray (cells : List (CellTag × ByteArray)) : String :=
  let entries := cells.map formatOpenedCellJson
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
  let expectedPostCommitHex := bytesHex bundle.expectedPostCommit
  let openedCellsArr := formatOpenedCellsArray bundle.openedCells
  let parts : List String := [
    "{",
    q ++ "fixture_id" ++ q, ":", q ++ fixtureId ++ q, ",",
    q ++ "action_kind" ++ q, ":", formatUInt8 bundle.actionKind, ",",
    q ++ "action_fields_hex" ++ q, ":", q ++ actionFieldsHex ++ q, ",",
    q ++ "signer" ++ q, ":", formatUInt64 bundle.signer, ",",
    q ++ "expected_post_commit_hex" ++ q, ":",
      q ++ expectedPostCommitHex ++ q, ",",
    q ++ "opened_cells" ++ q, ":", openedCellsArr, ",",
    q ++ "gap_mask_hex" ++ q, ":", q ++ bytesHex bundle.wire.gapMask ++ q, ",",
    q ++ "siblings_hex" ++ q, ":",
      q ++ bytesHex (bundle.wire.siblings.foldl (fun acc s => acc ++ s)
                       (ByteArray.mk #[])) ++ q,
    "}"
  ]
  String.join parts

/-! ## Smoke checks -/

/-- An empty frontier formats as `[]`. -/
example : formatOpenedCellsArray [] = "[]" := rfl

/-- `formatUInt8 0 = "0"`. -/
example : formatUInt8 0 = "0" := rfl

/-- `formatUInt8 18 = "18"`. -/
example : formatUInt8 18 = "18" := rfl

end TerminateBundle
end FaultProof
end LegalKernel
