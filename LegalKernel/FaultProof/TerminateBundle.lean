-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.TerminateBundle — Workstream SVC.3 (+ SB):
canonical bundle of inputs the off-chain observer submits to
`KnomosisFaultProofGame.terminateOnSingleStep` on L1.

The bundle's non-`gameId` inputs are derivable from a canonical
`(ExtendedState, LogEntry)` pair via the per-variant encoders this
module composes:

  * `actionKind`   := `actionKindByte action`
  * `actionFields` := `actionFieldsForL1 action`
  * `signer`       := `entry.signedAction.signer`
  * `openedCells`  := the step's frontier (each cell with its proven
                       PRE-state value, from `stepMultiBundle`)
  * `wire`         := the deduplicating pre-root multiproof
                       (`stepMultiBundle`'s shared sibling list)

A `TerminateBundle` additionally carries
`expectedPostCommit := stepMultiPostRoot preState st l2LogIndex`.
That field is **not** calldata: the contract computes the fold from
`g.low.commit` and compares against `g.high.commit`, both already
on-chain, so the post-root is not the caller's to claim.  It is
retained so the observer can cross-check its own bundle against an
independent oracle before broadcasting.

**Workstream SB — batched submission.**  Once one L1 submission
covers a batch of actions, terminate must additionally AUTHENTICATE
the disputed action against the batch's `actionsRoot` (the Merkle
root the submission committed).  `BatchBinding` carries that half:
the batch bounds, the action's SMT key, the signature the leaf
binds, and the inclusion wire, built by `buildBatchBinding` from
the same log the state bundle is built from.

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
  "opened_cells": [
    {"cell_kind": 0, "key_a": "0x01", "key_b": "0x05",
     "pre_value": "..."},
    ...
  ],
  "gap_mask_hex": "...",
  "siblings_hex": "..."
}
```

With a `BatchBinding` supplied, the object additionally carries
`prev_end`, `end`, `actions_root_hex`, `action_key_hex`,
`leaf_commit_hex`, `action_sig_hex`, `action_gap_mask_hex`, and
`action_siblings_hex` (the inclusion wire, in the same
bitmask‖siblings shape as the state wire).

This module is **not** part of the trusted computing base.
-/

import LegalKernel.FaultProof.ActionsRoot
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
  /-- Action-variant dispatcher (0..25, per `actionKindByte`). -/
  actionKind        : UInt8
  /-- Canonical fields' byte layout per
      `actionFieldsForL1`. -/
  actionFields      : ByteArray
  /-- The signer's `ActorId` (= log entry's `signer`).  64-bit. -/
  signer            : ActorId
  /-- The post-state ROOT the multiproof fold reaches — the value
      `stepMultiPostRoot` computes, and (under the production
      keccak256 binding) what the L1's root-computing
      `executeStepToRootMulti` returns on the same inputs.

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
  /-- Workstream F-A: the SIGNER'S REGISTRY CELL at the pre-state —
      a CBE byte string wrapping the registered public key, or EMPTY
      when the signer is unregistered (a real, adjudicable state: no
      key can have authorised the entry).  CALLDATA: the L1 resolves
      the signer's key from it before verifying the committed
      signature. -/
  registryValue     : ByteArray
  /-- Workstream F-A: that cell's single-cell opening against the
      disputed range's PRE-state root.  CALLDATA.  Present for BOTH
      the registered and unregistered cases — an absent cell opens
      from the canonical empty leaf — so it is what decides whether a
      bundle carries an F-A opening at all. -/
  registryProof     : SmtCellProof
  deriving Repr

/-! ## Bundle builder

The canonical builder threads the per-variant encoders together: -/

/-- Build the canonical terminate bundle for applying `entry` to
    pre-state `preState`.

    Equation:
      `actionKind        := actionKindByte action`
      `actionFields      := actionFieldsForL1 action`
      `signer            := entry.signedAction.signer`
      `expectedPostCommit := stepMultiPostRoot preState st l2LogIndex`
      `openedCells       := (stepMultiBundle preState st).cells`
      `wire              := (stepMultiBundle preState st).proof`

    Pre-conditions:
    * The entry's action must be admissible at `preState` (otherwise
      the fold's evaluated precondition no-ops and the expected root
      is the pre-root).  Admissibility is the caller's
      responsibility; the bundle is constructed unconditionally so
      test fixtures and debugging tools can emit it for any input
      pair. -/
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
    wire              := (stepMultiBundle preState entry.signedAction).proof,
    registryValue     := getCellValue preState (.registry signer),
    registryProof     := buildStateCellProof preState (.registry signer) }

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

/-! ## The batch binding (Workstream SB)

Under batched submission, one L1 record covers the log range
`[prevEnd, end)` and commits an `actionsRoot` over the per-action
leaf commits.  `terminateOnSingleStep` then authenticates the
disputed action by Merkle inclusion: the leaf binds
`(kind ‖ signer ‖ fields ‖ sig)` (`actionLeafValue`), keyed at
`actionKey idx`, and the wire opens it against the record's root.
`BatchBinding` is the observer-facing carrier of that half. -/

/-- The batch-inclusion half of a terminate bundle: the batch bounds,
    the disputed action's SMT key and leaf commit, the SIGNATURE the
    leaf binds (65 bytes on the wire, hashed by the L1 into the leaf
    it verifies), and the compressed inclusion wire against the
    batch's `actionsRoot`. -/
structure BatchBinding where
  /-- The batch's exclusive lower bound: the number of log entries
      already covered by earlier submissions (= the previous record's
      `end`).  The batch covers log indices `[prevEnd, end)`. -/
  prevEnd     : Nat
  /-- The batch's exclusive upper bound (= the covered entry count,
      and the L1 record's index). -/
  endIndex    : Nat
  /-- The disputed log index, in `[prevEnd, endIndex)`. -/
  idx         : Nat
  /-- The batch's actions root — the SMT root over
      `batchActionEntries prevEnd batch`, as the L1 record committed
      it. -/
  actionsRoot : ByteArray
  /-- The disputed action's SMT key, `actionKey idx` (32 bytes). -/
  actionKey   : ByteArray
  /-- The leaf commit, `actionLeafValue` of the disputed entry's
      signed action (32 bytes).  Not calldata — the L1 RE-DERIVES the
      leaf from the `(kind, fields, signer, sig)` it is handed —
      retained so the observer can cross-check its inclusion wire
      before broadcasting. -/
  leafCommit  : ByteArray
  /-- The signature the leaf binds, verbatim from the log entry. -/
  actionSig   : ByteArray
  /-- The compressed inclusion wire (bitmask ‖ siblings) opening the
      leaf at `actionKey` against `actionsRoot`. -/
  actionProof : SmtCellProof
  deriving Repr

/-- Build the batch binding for disputed index `idx` within the batch
    `[prevEnd, endIndex)` of `entries` (the WHOLE log, from which the
    batch slice is taken).  Returns `none` when the bounds are
    malformed — `idx` outside the batch, an empty or over-long
    batch — rather than authoring a wire that cannot verify. -/
def buildBatchBinding (entries : List LogEntry)
    (prevEnd endIndex idx : Nat) : Option BatchBinding :=
  if prevEnd ≤ idx ∧ idx < endIndex ∧ endIndex ≤ entries.length then
    let batch := (entries.take endIndex).drop prevEnd
    match entries[idx]? with
    | none => none
    | some entry =>
      some
        { prevEnd     := prevEnd
        , endIndex    := endIndex
        , idx         := idx
        , actionsRoot := actionsRoot prevEnd batch
        , actionKey   := actionKey idx
        , leafCommit  := actionLeafValue entry.signedAction
        , actionSig   := entry.signedAction.sig
        , actionProof := buildActionProof prevEnd batch idx }
  else
    none

/-- `buildBatchBinding` refuses an index outside the batch. -/
theorem buildBatchBinding_none_of_out_of_range
    (entries : List LogEntry) (prevEnd endIndex idx : Nat)
    (h : ¬ (prevEnd ≤ idx ∧ idx < endIndex ∧ endIndex ≤ entries.length)) :
    buildBatchBinding entries prevEnd endIndex idx = none := by
  unfold buildBatchBinding
  rw [if_neg h]

/-- A built binding's root is the batch's `actionsRoot` — the value
    the L1 record committed, recomputed from the same slice. -/
theorem buildBatchBinding_actionsRoot
    (entries : List LogEntry) (prevEnd endIndex idx : Nat)
    (b : BatchBinding)
    (h : buildBatchBinding entries prevEnd endIndex idx = some b) :
    b.actionsRoot = actionsRoot prevEnd ((entries.take endIndex).drop prevEnd) := by
  unfold buildBatchBinding at h
  by_cases hb : prevEnd ≤ idx ∧ idx < endIndex ∧ endIndex ≤ entries.length
  · rw [if_pos hb] at h
    cases he : entries[idx]? with
    | none => rw [he] at h; exact absurd h (by simp)
    | some entry =>
        rw [he] at h
        simp only [Option.some.injEq] at h
        subst h
        rfl
  · rw [if_neg hb] at h
    exact absurd h (by simp)

/-- A built binding's key, leaf, and signature are the disputed
    entry's own. -/
theorem buildBatchBinding_binds_entry
    (entries : List LogEntry) (prevEnd endIndex idx : Nat)
    (entry : LogEntry) (b : BatchBinding)
    (he : entries[idx]? = some entry)
    (h : buildBatchBinding entries prevEnd endIndex idx = some b) :
    b.actionKey = actionKey idx ∧
    b.leafCommit = actionLeafValue entry.signedAction ∧
    b.actionSig = entry.signedAction.sig := by
  unfold buildBatchBinding at h
  by_cases hb : prevEnd ≤ idx ∧ idx < endIndex ∧ endIndex ≤ entries.length
  · rw [if_pos hb, he] at h
    simp only [Option.some.injEq] at h
    subst h
    exact ⟨rfl, rfl, rfl⟩
  · rw [if_neg hb] at h
    exact absurd h (by simp)


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

/-- Format the batch-binding fields as a JSON fragment (leading
    comma included), appended inside the terminate-bundle object when
    a `BatchBinding` is supplied.  The inclusion wire rides the same
    bitmask ‖ concatenated-siblings shape as the state wire. -/
def formatBatchBindingFields (b : BatchBinding) : String :=
  let q := "\""
  String.join [
    ",",
    q ++ "prev_end" ++ q, ":", toString b.prevEnd, ",",
    q ++ "end" ++ q, ":", toString b.endIndex, ",",
    q ++ "batch_idx" ++ q, ":", toString b.idx, ",",
    q ++ "actions_root_hex" ++ q, ":", q ++ bytesHex b.actionsRoot ++ q, ",",
    q ++ "action_key_hex" ++ q, ":", q ++ bytesHex b.actionKey ++ q, ",",
    q ++ "leaf_commit_hex" ++ q, ":", q ++ bytesHex b.leafCommit ++ q, ",",
    q ++ "action_sig_hex" ++ q, ":", q ++ bytesHex b.actionSig ++ q, ",",
    q ++ "action_gap_mask_hex" ++ q, ":",
      q ++ bytesHex b.actionProof.bitmask ++ q, ",",
    q ++ "action_siblings_hex" ++ q, ":",
      q ++ bytesHex (b.actionProof.siblings.foldl (fun acc s => acc ++ s)
                       (ByteArray.mk #[])) ++ q
  ]

/-- Format a `TerminateBundle` as a single line of JSON.

    Snake_case field names match Rust serde-deserialize defaults
    so the Rust observer's `TerminateBundle` struct can consume
    the output without renames.

    The `fixture_id` argument is the operator-supplied identifier
    for the bundle (e.g., "log[7]" for the bundle at log index 7).
    It's passed through to the JSON so a multi-bundle export can
    distinguish entries.

    Workstream SB: an optional `BatchBinding` appends the
    batch-inclusion fields (`prev_end` / `end` / `batch_idx` /
    `actions_root_hex` / `action_key_hex` / `leaf_commit_hex` /
    `action_sig_hex` / `action_gap_mask_hex` /
    `action_siblings_hex`) — absent by default, so a pre-batching
    consumer's parse is unchanged. -/
def formatTerminateBundleJson (fixtureId : String)
    (bundle : TerminateBundle) (batch : Option BatchBinding := none) : String :=
  let q := "\""
  let actionFieldsHex := bytesHex bundle.actionFields
  let expectedPostCommitHex := bytesHex bundle.expectedPostCommit
  let openedCellsArr := formatOpenedCellsArray bundle.openedCells
  let batchFields := match batch with
    | none => ""
    | some b => formatBatchBindingFields b
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
                       (ByteArray.mk #[])) ++ q, ",",
    q ++ "registry_value_hex" ++ q, ":",
      q ++ bytesHex bundle.registryValue ++ q, ",",
    q ++ "registry_proof_hex" ++ q, ":",
      q ++ bytesHex (bundle.registryProof.bitmask ++
             bundle.registryProof.siblings.foldl (fun acc s => acc ++ s)
               (ByteArray.mk #[])) ++ q,
    batchFields,
    "}"
  ]
  String.join parts

/-! ## Batch-submission export (Workstream SB)

The `export-batch` CLI emits the two values `submitStateRoot`
consumes for a batch `[prevEnd, end)` — the post-state commit after
the batch's last entry and the batch's actions root — plus the
bounds, as one JSON line. -/

/-- Format the `export-batch` JSON: the batch bounds, the covered
    entry count, the post-state commit (`commitExtendedState` of the
    state after replaying `end` entries), and the batch's actions
    root. -/
def formatBatchExportJson (prevEnd endIndex : Nat)
    (stateCommit actionsRoot : ByteArray) : String :=
  let q := "\""
  String.join [
    "{",
    q ++ "prev_end" ++ q, ":", toString prevEnd, ",",
    q ++ "end" ++ q, ":", toString endIndex, ",",
    q ++ "count" ++ q, ":", toString (endIndex - prevEnd), ",",
    q ++ "state_commit_hex" ++ q, ":", q ++ bytesHex stateCommit ++ q, ",",
    q ++ "actions_root_hex" ++ q, ":", q ++ bytesHex actionsRoot ++ q,
    "}"
  ]

/-- Format the `export-action-proof` JSON: the standalone
    batch-inclusion proof for one log index, carrying everything an
    L1 caller needs to authenticate the action against the record's
    `actionsRoot` — the action's own wire data (`kind`, `fields`,
    `signer`, `sig`) plus the inclusion wire. -/
def formatActionProofExportJson (b : BatchBinding)
    (entry : LogEntry) : String :=
  let q := "\""
  let action := entry.signedAction.action
  String.join [
    "{",
    q ++ "idx" ++ q, ":", toString b.idx, ",",
    q ++ "prev_end" ++ q, ":", toString b.prevEnd, ",",
    q ++ "end" ++ q, ":", toString b.endIndex, ",",
    q ++ "action_kind" ++ q, ":", formatUInt8 (actionKindByte action), ",",
    q ++ "action_fields_hex" ++ q, ":",
      q ++ bytesHex (actionFieldsForL1 action) ++ q, ",",
    q ++ "signer" ++ q, ":", formatUInt64 entry.signedAction.signer, ",",
    q ++ "action_sig_hex" ++ q, ":", q ++ bytesHex b.actionSig ++ q, ",",
    q ++ "actions_root_hex" ++ q, ":", q ++ bytesHex b.actionsRoot ++ q, ",",
    q ++ "action_key_hex" ++ q, ":", q ++ bytesHex b.actionKey ++ q, ",",
    q ++ "leaf_commit_hex" ++ q, ":", q ++ bytesHex b.leafCommit ++ q, ",",
    q ++ "gap_mask_hex" ++ q, ":", q ++ bytesHex b.actionProof.bitmask ++ q, ",",
    q ++ "siblings_hex" ++ q, ":",
      q ++ bytesHex (b.actionProof.siblings.foldl (fun acc s => acc ++ s)
                       (ByteArray.mk #[])) ++ q,
    "}"
  ]

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
