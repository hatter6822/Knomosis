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
  /-- The READ-ONLY budget-policy opening, against the pre-state
      root.

      Not a write, so it is not in `cellProofs` — but
      `deriveEpochBudget` selects its branch on it and every one of the
      twenty-five variants writes an epoch-budget cell, so the L1
      verifier cannot start without it. -/
  policyProof       : CellProof
  /-- The step's WRITTEN cells, in `writeCellsAt` order, with CHAINED
      openings: proof `i` opens against the root write `i-1` produced.

      Not against the pre-state root.  An opening goes stale the moment
      a write lands, and two writes at the SAME cell (a self-transfer)
      are reachable by anyone — a bundle whose openings were all
      against the pre-root would fold to a root no state has. -/
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
      (stepPostRoot preState entry.signedAction l2LogIndex).getD ByteArray.empty,
    policyProof       := openingCellProof preState (policyOpening preState),
    cellProofs        :=
      { proofs := (stepOpenings preState entry.signedAction l2LogIndex).map
                    (openingCellProof preState) } }

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
    (stepPostRoot es entry.signedAction idx).getD ByteArray.empty := rfl

/-- The bundle's `cellProofs` are the step's CHAINED write openings. -/
theorem buildTerminateBundle_cellProofs
    (es : ExtendedState) (entry : LogEntry) (idx : Nat) :
    (buildTerminateBundle es entry idx).cellProofs =
    { proofs := (stepOpenings es entry.signedAction idx).map
                  (openingCellProof es) } := rfl

/-- The bundle's cells are exactly the ones the action writes, in
    declaration order — so a verifier can check the bundle's SHAPE
    against `writeCellsAt` before doing any hashing, and an observer
    that dropped or reordered one fails that check rather than folding
    to a root no state has. -/
theorem buildTerminateBundle_cellProofs_tags
    (es : ExtendedState) (entry : LogEntry) (idx : Nat) :
    (buildTerminateBundle es entry idx).cellProofs.proofs.map CellProof.cellTag
      = entry.signedAction.action.writeCellsAt es entry.signedAction.signer := by
  show ((stepOpenings es entry.signedAction idx).map
          (openingCellProof es)).map CellProof.cellTag = _
  rw [List.map_map]
  show (stepOpenings es entry.signedAction idx).map CellOpening.cellTag = _
  unfold stepOpenings
  rw [List.map_map]
  exact stepWriteBundle_tags es entry.signedAction idx

/-- The bundle's policy proof names the budget-policy cell.  Fixed by
    the builder rather than chosen: the policy selects the branch every
    epoch-budget write takes, so a substitutable one would let a
    responder steer the budget leg of every action. -/
theorem buildTerminateBundle_policyProof_tag
    (es : ExtendedState) (entry : LogEntry) (idx : Nat) :
    (buildTerminateBundle es entry idx).policyProof.cellTag
      = CellTag.budgetPolicy := rfl

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
  let expectedPostCommitHex := bytesHex bundle.expectedPostCommit
  let cellProofsArr := formatCellProofsArray bundle.cellProofs
  let parts : List String := [
    "{",
    q ++ "fixture_id" ++ q, ":", q ++ fixtureId ++ q, ",",
    q ++ "action_kind" ++ q, ":", formatUInt8 bundle.actionKind, ",",
    q ++ "action_fields_hex" ++ q, ":", q ++ actionFieldsHex ++ q, ",",
    q ++ "signer" ++ q, ":", formatUInt64 bundle.signer, ",",
    q ++ "expected_post_commit_hex" ++ q, ":",
      q ++ expectedPostCommitHex ++ q, ",",
    q ++ "policy_opening" ++ q, ":",
      formatCellProofJson bundle.policyProof, ",",
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
