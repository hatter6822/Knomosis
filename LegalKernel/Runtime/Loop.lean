-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Runtime.Loop — the runtime's main event loop.

Phase 5 WU 5.1.  The deployment-facing `RuntimeState` and
`processSignedAction` operations: load genesis (or a snapshot),
accept incoming `SignedAction` records, dispatch them through
`apply_admissible`, write the resulting `LogEntry` to the log, and
emit observability events.

Genesis Plan §12 WU 5.1: "A `runtime` executable that loads genesis
(from a CBOR file), reads `SignedAction` values from stdin, calls
`apply_admissible`, appends results to a log file."

Phase 5 design:

  * The runtime's mutable state is a `RuntimeState` record holding
    the current `(ExtendedState, prevHash, logIndex, policy,
    logPath)`.  All updates go through `processSignedAction`, which
    is a pure-state-transformation followed by an IO append.
  * Admissibility checking is done inside the runtime (NOT delegated
    to the network adaptor), so a deployment can run with an
    untrusted network layer in front.
  * The runtime never silently drops a `SignedAction`: every
    submission either appends a `LogEntry` (success) or returns a
    `ProcessError` (failure).  Genesis Plan §8.9.1's "rejection log"
    will be added in Phase 6 with the dispute pipeline.

This module is **not** part of the trusted computing base.  Bugs
here can produce a runtime that silently drops actions or races on
its log file, but cannot violate any kernel invariant — every
state advance still goes through `apply_admissible`, which carries
the §8.2 admissibility witness as a dependent argument.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.SignedAction
import LegalKernel.Encoding.State
import LegalKernel.Events.Extract
import LegalKernel.Runtime.Hash
import LegalKernel.Runtime.LogFile
import LegalKernel.Runtime.Replay
import LegalKernel.Runtime.Snapshot

namespace LegalKernel
namespace Runtime

open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding
open LegalKernel.Events

/-! ## RuntimeState

The runtime's mutable record.  Persisted only via the log file: a
crash + restart re-derives `RuntimeState` by replaying the log
(possibly from a snapshot).  Genesis Plan §10.1's threat model
treats the in-memory state as untrusted between runs; the only
durable state is the log. -/

/-- The runtime's mutable state record.  Carries everything
    `processSignedAction` needs to dispatch the next action. -/
structure RuntimeState where
  /-- The deployment's `AuthorityPolicy` (static, but carried here
      for convenience). -/
  policy   : AuthorityPolicy
  /-- The current `ExtendedState`: kernel state + nonce ledger +
      key registry. -/
  state    : ExtendedState
  /-- The `LogEntry.hash` of the most recent log entry, or
      `zeroHash` for a fresh deployment. -/
  prevHash : ContentHash
  /-- The number of log entries written so far.  Equals the next
      log entry's index. -/
  logIndex : Nat
  /-- Filesystem path of the log file.  `processSignedAction`
      appends to this path; `bootstrap` reads from it on startup. -/
  logPath  : System.FilePath
  /-- AR.2.1 / M-1.  Deployment-specific domain-separation tag
      that the runtime threads into every `signInput`
      computation.  Production runtime supplies a non-empty value
      via the `--deployment-id <hex>` CLI flag (AR.2.6); test
      harnesses and the dev-mode binary default to
      `ByteArray.empty` for back-compat with pre-AR runtime
      behaviour.

      Pre-AR, `processSignedAction` hardcoded
      `processSignedActionWith Verify ByteArray.empty`; any
      cross-deployment replay would silently pass because every
      runtime used the same empty sentinel.  AR.2 threads the
      deploymentId through every entry point so production
      replicas of distinct deployments cannot be confused by
      replayed signatures from a sibling. -/
  deploymentId : ByteArray
  /-- GP.6.2 epoch-advancement schedule: the number of admitted log
      entries per budget epoch.  `0` (the default) disables
      advancement — the epoch stays fixed at the genesis
      `budgetPolicy.currentEpoch`, exactly the pre-GP.6.2-epoch
      runtime behaviour.  A positive value advances the effective
      epoch every `epochLength` admitted actions (see
      `BudgetPolicy.advanceEpoch`), lazily replenishing each actor's
      free tier at the epoch boundary.  Threaded into the budget gate
      via `ExtendedState.withAdvancedEpoch`; deterministic on replay
      because it is a pure function of the log index. -/
  epochLength : Nat := 0

/-! ## Errors

`ProcessError` enumerates the ways `processSignedAction` can refuse
a submission.  Each variant maps directly to a Genesis-Plan §8.2
admissibility clause; together they form the runtime's "rejection
log" vocabulary (Phase 6 will persist these alongside the
transition log). -/

/-- Errors that `processSignedAction` can produce.  Each variant
    corresponds to an admissibility-clause failure. -/
inductive ProcessError where
  /-- The submitted `SignedAction` failed the base
      `BridgeAdmissibleWith` check (signature, nonce, authority, or a
      bridge conjunct).  The specific clause is not distinguished
      here; a deployment can compute the failing clause via the
      per-clause extractors in `Authority/SignedAction.lean`. -/
  | notAdmissible
  /-- GP.6.2: the action was base-admissible but the GP.3.2 per-actor
      budget gate refused it (`apply_bridge_admissible_with_budget`
      returned `none`): an exhausted epoch budget, or one of the
      named safety-gate rejections (`topUpActionBudget_gasCheck`,
      `depositWithFee_signerCheck`, `topUpActionBudgetFor_gate`).
      Distinguished from `notAdmissible` so the runtime can surface
      the wire-stable `"InsufficientBudget"` reason (OQ-GP-3) across
      the `knomosis-host` `CommandKernel` boundary instead of a
      generic exit-status string. -/
  | budgetRejected
  deriving Repr

/-! ## processSignedAction

The single entry point that advances the runtime by one step.
Sequence:

  1. Decide admissibility of `(state, signedAction)` under the
     deployment's policy.
  2. If inadmissible, return `notAdmissible` without mutation.
  3. If admissible, compute the new state via `apply_admissible`.
  4. Hash the new state, build a `LogEntry`, append to the log
     file.
  5. Update `prevHash` and `logIndex` in the returned
     `RuntimeState`.
  6. Compute the events via `extractEvents` and return them
     alongside the new state.

The function is pure-state-transformation modulo the file append:
the `IO` is exactly one `IO.FS.Handle.write` call (and possibly
file creation on first append). -/

/-- The result of one `processSignedAction` call: the new
    `RuntimeState`, the appended `LogEntry`, and the extracted
    events list. -/
structure ProcessResult where
  /-- The post-application runtime state. -/
  state  : RuntimeState
  /-- The `LogEntry` that was appended to the log file. -/
  entry  : LogEntry
  /-- The list of events extracted from the application. -/
  events : List Event

/-- Audit-3.3 + 3.4: parameterised step.  Same body as
    `processSignedAction`, but takes the `verify` function and
    `deploymentId` so that test code can exercise the happy path
    using `mockVerify` from `LegalKernel/Test/MockCrypto.lean`.

    RB.3 (2026-05-22, bridge-aware runtime admission gate):
    dispatches on `BridgeAdmissibleWith` (not the weaker
    `AdmissibleWith`) and applies via
    `apply_bridge_admissible_with_budget` so the bridge state
    (`bridge.consumed`, `bridge.pending`, `bridge.nextWdId`) is
    advanced atomically with the kernel state.  This closes the
    pre-RB gap where `processSignedActionWith` accepted bridge
    actions (`deposit`, `withdraw`, `registerIdentity`) at the
    kernel admission layer but left the bridge state stale —
    making depositId replay, identity re-registration, and bridge-
    only impersonation runtime-undetected vulnerabilities.

    The `l2LogIndex` threaded into the bridge-state advance is
    `rs.logIndex`, the index THIS action will be appended at
    (since `appendEntry` follows immediately and the
    post-application `rs'.logIndex` is `rs.logIndex + 1`, the
    bridge-state's `PendingWithdrawal.l2LogIndex` matches the
    log-entry's index exactly). -/
def processSignedActionWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (d : ByteArray) (rs : RuntimeState) (st : SignedAction) :
    IO (Except ProcessError ProcessResult) := do
  -- GP.6.2: advance the budget epoch for THIS action's log index
  -- before the gate (identity when `epochLength = 0`).  The gate,
  -- its theorems, and every non-budget sub-state are untouched.
  let esEff := rs.state.withAdvancedEpoch rs.epochLength rs.logIndex
  if h : BridgeAdmissibleWith verify rs.policy d esEff st then
    match apply_bridge_admissible_with_budget verify rs.policy d esEff st
            rs.logIndex h with
    | some newState =>
      let postHash := hashEncodable newState
      let entry : LogEntry :=
        { prevHash      := rs.prevHash
        , signedAction  := st
        , postStateHash := postHash }
      appendEntry rs.logPath entry
      let events := extractEvents esEff newState st
      let entryHash := LogEntry.hash entry
      let rs' : RuntimeState :=
        { policy       := rs.policy
        , state        := newState
        , prevHash     := entryHash
        , logIndex     := rs.logIndex + 1
        , logPath      := rs.logPath
        , deploymentId := rs.deploymentId
        , epochLength  := rs.epochLength }
      pure (.ok { state := rs', entry := entry, events := events })
    | none =>
      -- GP.6.2: base-admissible but the budget gate refused.
      pure (.error .budgetRejected)
  else
    pure (.error .notAdmissible)

/-- Process one `SignedAction` against the runtime's current state.
    Returns the new state + log entry + events on success, or a
    diagnostic error on failure.

    AR.2.2 / M-1.  Pre-AR this function defaulted the deploymentId
    to `ByteArray.empty`, silently disabling the §8.8.5
    cross-deployment-replay gate for every production runtime that
    didn't construct a `processSignedActionWith Verify` call
    directly.  Post-AR the deploymentId is sourced from
    `rs.deploymentId` (the new field added in AR.2.1), so a
    deployment that bootstraps with `--deployment-id <hex>` (the
    AR.2.6 CLI flag) gets cross-deployment-replay rejection
    end-to-end without any caller-side changes. -/
def processSignedAction (rs : RuntimeState) (st : SignedAction) :
    IO (Except ProcessError ProcessResult) :=
  processSignedActionWith Verify rs.deploymentId rs st

/-! ## Bootstrap

`bootstrap` is the runtime's startup path: load any existing log,
truncate the partial tail, replay the entries to reconstruct the
runtime state.  Returns a `RuntimeState` ready for the first
`processSignedAction` call.

Snapshot variant (`bootstrapFromSnapshot`): load a snapshot file
and the post-snapshot log tail, replay only the tail.  Used by
fresh replicas that catch up via snapshots rather than from
genesis. -/

/-- Errors during runtime bootstrap.  Distinguished from
    `Snapshot.ReplicaError` (which covers replica startup) by
    purpose: this enumerates failures of the runtime's own startup
    path (load log → truncate partial tail → replay → ready). -/
inductive BootstrapError where
  /-- The log file's contents failed to replay.  The `ReplayError`
      carries the failing index and reason. -/
  | replay (e : ReplayError)
  /-- A snapshot file was provided but failed to restore (used by
      `bootstrapFromSnapshot` only).  Carries the snapshot
      diagnostic so the runtime can distinguish "log corrupt" from
      "snapshot corrupt" without inspecting the inner enum. -/
  | snapshot (e : SnapshotError)
  /-- The log file was truncated to recover from a partial-write.
      Diagnostic only — bootstrap continues with the recovered
      prefix. -/
  | truncated (frameError : FrameError)
  /-- The snapshot's `logIndex` exceeds the log file's entry
      count.  Indicates a deployment-level inconsistency: the
      snapshot was taken at a point the log file no longer covers
      (snapshot kept; log was truncated externally; or the
      snapshot file is from a different deployment). -/
  | logIndexOverrun (snapIdx : Nat) (logEntries : Nat)
  /-- AR.3.1 / M-2.  The snapshot's recorded `seedHash` does not
      match the actual hash of the pre-snapshot log prefix.
      Surfaces when an operator supplies a snapshot from a
      different log timeline than the one at `logPath` — without
      this check, `bootstrapFromSnapshot` would silently start
      from the wrong state.

      Resolution: re-take the snapshot against the current log
      file, or supply the matching log file alongside the
      snapshot.  Cross-replica deployments should additionally
      gate snapshot acceptance on an attestor signature
      (`bootstrapFromAttestedSnapshot` in
      `LegalKernel/Runtime/AttestedSnapshot.lean`). -/
  | anchorMismatch
  deriving Repr

/-- Bootstrap the runtime from a fresh genesis state and a (possibly
    non-empty) log file.  Truncates any partial tail (WU 5.3) and
    replays the recovered prefix to reconstruct the runtime state.

    AR.2.3 / M-1.  The `deploymentId` parameter is threaded into
    the resulting `RuntimeState.deploymentId` field so subsequent
    `processSignedAction` calls (AR.2.2) reach the
    cross-deployment-replay gate.  The default value is
    `ByteArray.empty` so existing call sites (test harnesses,
    dev-mode binaries) keep their pre-AR behaviour; production
    binaries supply the value via the `--deployment-id <hex>`
    CLI flag (AR.2.6).

    Returns the bootstrapped `RuntimeState` on success.  Returns
    `truncated` as a *non-fatal* diagnostic when a partial tail
    was discarded — the caller may want to log this for ops
    visibility, but bootstrap itself succeeds. -/
def bootstrap
    (policy : AuthorityPolicy) (genesis : ExtendedState)
    (logPath : System.FilePath)
    (deploymentId : ByteArray := ByteArray.empty)
    (epochLength : Nat := 0) :
    IO (Except BootstrapError (RuntimeState × Option FrameError)) := do
  let (entries, frameErr) ← loadAndTruncate logPath
  -- GP.6.2: replay under the same epoch schedule the runtime used so
  -- the reconstructed state's epoch + budgets match the recorded
  -- post-state hashes (a divergent `epochLength` fails loudly with a
  -- post-state-hash mismatch — the intended fail-closed behaviour).
  match replay policy genesis entries epochLength with
  | .ok finalState =>
    let prevHash :=
      match entries.reverse with
      | [] => zeroHash
      | last :: _ => LogEntry.hash last
    let rs : RuntimeState :=
      { policy       := policy
      , state        := finalState
      , prevHash     := prevHash
      , logIndex     := entries.length
      , logPath      := logPath
      , deploymentId := deploymentId
      , epochLength  := epochLength }
    pure (.ok (rs, frameErr))
  | .error e =>
    pure (.error (.replay e))

/-- Bootstrap a replica from a snapshot plus the runtime's full log
    file at `logPath`.  Like `bootstrap`, but starts from the
    snapshot's `(state, seedHash)` rather than from genesis.

    The log file is expected to be the *full* on-disk log
    (including the entries that were already applied at snapshot
    time).  This function slices the entries to apply only those
    *after* the snapshot's `logIndex` — the Genesis Plan §13.2
    "apply only subsequent log entries" semantics.

    Validation: if `snap.logIndex > entries.length`, the snapshot
    refers to entries the log doesn't contain (the runtime took a
    snapshot, then truncated entries — a deployment-level
    inconsistency).  We surface this as `.logIndexOverrun snapIdx
    logEntries` so the operator can investigate.

    Returns precise diagnostics for the three failure modes:
      * `.snapshot e` — the snapshot itself failed to restore
        (decode error, or recorded stateHash didn't match the
        decoded state's hash).
      * `.logIndexOverrun snapIdx logEntries` — the snapshot is
        coherent on its own, but doesn't fit on top of the
        available log file.
      * `.replay e` — replay of the post-snapshot tail failed
        (chain broken, action inadmissible, etc.). -/
def bootstrapFromSnapshot
    (policy : AuthorityPolicy) (snap : Snapshot)
    (logPath : System.FilePath)
    (deploymentId : ByteArray := ByteArray.empty)
    (epochLength : Nat := 0) :
    IO (Except BootstrapError (RuntimeState × Option FrameError)) := do
  match restoreSnapshot snap with
  | .ok (state, seedHash, baseIdx) =>
    let (entries, frameErr) ← loadAndTruncate logPath
    if baseIdx > entries.length then
      pure (.error (.logIndexOverrun baseIdx entries.length))
    else
      -- AR.3.1 / M-2: anchor check.  The snapshot's `seedHash`
      -- must equal `LogEntry.hash entries[baseIdx-1]` (or
      -- `zeroHash` when `baseIdx = 0`).  Without this, the
      -- caller could supply a snapshot from a *different* log
      -- timeline and `replayFromSeed` would happily walk the
      -- chain starting from the wrong root, producing an
      -- internally-consistent but operator-unintended state.
      -- O(1) check: a single 32-byte hash comparison.
      let anchorOk : Bool :=
        match baseIdx with
        | 0     => seedHash.toList = zeroHash.toList
        | k + 1 =>
          match entries[k]? with
          | some e => seedHash.toList = (LogEntry.hash e).toList
          | none   => false
      if ¬ anchorOk then
        pure (.error .anchorMismatch)
      else
        let tail := entries.drop baseIdx
        -- GP.6.2: resume epoch advancement at the ABSOLUTE `baseIdx`
        -- so a snapshot-restored replica's epochs match a
        -- from-genesis replay byte-for-byte.
        match replayFromSeed policy seedHash state tail baseIdx epochLength with
        | .ok finalState =>
          let prevHash :=
            match tail.reverse with
            | [] => seedHash
            | last :: _ => LogEntry.hash last
          let rs : RuntimeState :=
            { policy       := policy
            , state        := finalState
            , prevHash     := prevHash
            , logIndex     := baseIdx + tail.length
            , logPath      := logPath
            , deploymentId := deploymentId
            , epochLength  := epochLength }
          pure (.ok (rs, frameErr))
        | .error e =>
          pure (.error (.replay e))
  | .error e =>
    -- Snapshot restoration failed (decode error or hash mismatch);
    -- surface the precise diagnostic rather than collapsing into
    -- a generic replay error.
    pure (.error (.snapshot e))

/-! ## Convenience: process a list of signed actions in sequence

The headline acceptance test for WU 5.1 runs a single transfer
round-trip: the runtime accepts one `SignedAction`, applies it,
writes the log, and the on-disk state is consistent.  In practice
deployments process many actions per session; this helper threads
them through one at a time. -/

/-- Process a list of `SignedAction`s sequentially.  Returns the
    final `RuntimeState` and the list of per-action results (in
    order).  The outer `IO` reflects the file appends; the inner
    list holds either a `ProcessResult` or a `ProcessError` per
    action. -/
def processBatch (rs : RuntimeState) :
    List SignedAction → IO (RuntimeState × List (Except ProcessError ProcessResult))
  | []       => pure (rs, [])
  | st :: rest => do
    let result ← processSignedAction rs st
    let rs' :=
      match result with
      | .ok r  => r.state
      | .error _ => rs
    let (rs'', results) ← processBatch rs' rest
    pure (rs'', result :: results)

/-! ## Determinism (acceptance gate)

The kernel's `apply_admissible` is a pure function; the runtime's
state advance is therefore deterministic up to the log-append IO.
Since the IO is just "write these bytes" (no read-modify-write,
no shared state), two runtime instances given the same
`(genesis, signedActionStream)` produce identical post-state
hashes.  This is the §8.7 acceptance criterion (replay reproduces
the runtime's state hash byte-for-byte). -/

/-- Pure form of `processSignedAction` (no IO).  For testing the
    state-transition logic without involving the file system.

    GP.3.2 wiring: dispatches through the budget-gated admission
    helper.  RB.3 (2026-05-22) further upgrades the dispatch to
    `BridgeAdmissibleWith` + `apply_bridge_admissible_with_budget`,
    so the bridge state (`bridge.consumed` / `bridge.pending`) is
    advanced atomically with the kernel state — `processPure` now
    fully mirrors `processSignedActionWith`'s production semantics.

    A `none` from the budget gate (insufficient signer budget
    under `bounded` policy) is mapped to `.error .budgetRejected`
    (GP.6.2), matching the production IO path; base-admissibility
    failures map to `.error .notAdmissible`.

    Deployment-id discipline: threads `rs.deploymentId` into the
    admissibility check (via `BridgeAdmissibleWith`) and the
    budget gate.  Pre-GP.3.2 `processPure` hardcoded
    `ByteArray.empty` here (a Phase-3 / pre-AR.2 leftover) while
    preserving `rs.deploymentId` in the returned
    `rs'.deploymentId` — an internal inconsistency that diverged
    from `processSignedActionWith Verify rs.deploymentId` when the
    deployment was bound to a non-empty id.  Threading
    `rs.deploymentId` end-to-end closes that gap and matches
    `processSignedAction`'s back-compat alias exactly. -/
def processPure (rs : RuntimeState) (st : SignedAction) :
    Except ProcessError (RuntimeState × LogEntry × List Event) :=
  -- GP.6.2: advance the budget epoch for this action's log index
  -- (identity when `epochLength = 0`); mirrors `processSignedActionWith`.
  let esEff := rs.state.withAdvancedEpoch rs.epochLength rs.logIndex
  if h : BridgeAdmissibleWith Verify rs.policy rs.deploymentId esEff st then
    match apply_bridge_admissible_with_budget Verify rs.policy rs.deploymentId
            esEff st rs.logIndex h with
    | some newState =>
      let entry : LogEntry :=
        { prevHash      := rs.prevHash
        , signedAction  := st
        , postStateHash := hashEncodable newState }
      let events := extractEvents esEff newState st
      let rs' : RuntimeState :=
        { policy       := rs.policy
        , state        := newState
        , prevHash     := LogEntry.hash entry
        , logIndex     := rs.logIndex + 1
        , logPath      := rs.logPath
        , deploymentId := rs.deploymentId
        , epochLength  := rs.epochLength }
      .ok (rs', entry, events)
    | none =>
      -- GP.6.2: base-admissible but the budget gate refused.
      .error .budgetRejected
  else
    .error .notAdmissible

/-- `processPure` is deterministic: equal inputs produce equal
    outputs.  Trivial (it's a pure function), but stated for the
    acceptance gate. -/
theorem processPure_deterministic
    (rs₁ rs₂ : RuntimeState) (st₁ st₂ : SignedAction)
    (h_rs : rs₁ = rs₂) (h_st : st₁ = st₂) :
    processPure rs₁ st₁ = processPure rs₂ st₂ := by
  rw [h_rs, h_st]

end Runtime
end LegalKernel
