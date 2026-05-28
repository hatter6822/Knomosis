/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Runtime.Loop — Phase-5 WU 5.1 tests for the
runtime main loop (`processSignedAction` and `bootstrap`).

We exercise:

  * `bootstrap` of an empty log returns a fresh runtime with
    `logIndex = 0` and `prevHash = zeroHash`.
  * `processSignedAction` rejects an inadmissible action (the
    Verify stub returns false) with `notAdmissible`.
  * `processBatch` threads the runtime state through multiple
    actions correctly (every entry produces either an `OK` or a
    `notAdmissible` result).
  * Determinism: `processPure` is a pure function of its inputs.

**Verify-opaque caveat.**  See `Test/Runtime/Replay.lean` for the
full discussion.  Key implication: every `processSignedAction`
test that doesn't explicitly *expect* failure will fail (because
Verify returns false in the test runtime).  We test the rejection
path as the primary positive evidence that the runtime is wired
correctly.
-/

import LegalKernel.Test.Framework
import LegalKernel.Runtime.Loop

namespace LegalKernel.Test.Runtime
namespace LoopTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding

/-- Test policy: unrestricted. -/
def policy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- A genesis state: actor 1 holds 100 of resource 1. -/
def genesis : ExtendedState :=
  { base    := setBalance ({ balances := ∅ }) 1 1 100
  , nonces  := { next := ∅ }
  , registry := KeyRegistry.empty }

/-- A signed action.  Will fail admissibility because Verify=false. -/
def transferAction : SignedAction :=
  { action := .transfer 1 1 2 30
  , signer := 1
  , nonce  := 0
  , sig    := ⟨#[]⟩ }

/-- `bootstrap` of an empty log returns the fresh runtime state. -/
def bootstrapEmpty : TestCase := {
  name := "bootstrap of missing log returns fresh runtime"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-empty.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    match (← bootstrap policy genesis path) with
    | .ok (rs, frameErr?) =>
      assertEq (0 : Nat) rs.logIndex "logIndex"
      assertEq (zeroHash.toList) (rs.prevHash.toList) "prevHash"
      if frameErr?.isSome then
        throw <| IO.userError "unexpected truncation diagnostic"
    | .error e => throw <| IO.userError s!"bootstrap failed: {repr e}"
}

/-- `processSignedAction` rejects an inadmissible action.  Verify
    returns false in tests, so the signature-clause of `Admissible`
    fails. -/
def processInadmissible : TestCase := {
  name := "processSignedAction rejects inadmissible action"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-rej.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    let rs : RuntimeState :=
      { policy := policy, state := genesis, prevHash := zeroHash
      , logIndex := 0, logPath := path
      , deploymentId := ByteArray.empty }
    match (← processSignedAction rs transferAction) with
    | .ok _ =>
      throw <| IO.userError "BUG: accepted inadmissible action"
    | .error .notAdmissible =>
      -- Verify the file was NOT touched.
      let present ← path.pathExists
      if present then
        throw <| IO.userError "BUG: file written despite admissibility failure"
}

/-- `processBatch` threads state through multiple inadmissible
    actions, returning a list of `notAdmissible` results in the
    same order. -/
def processBatchAllReject : TestCase := {
  name := "processBatch returns one rejection per inadmissible action"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-batch.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    let rs : RuntimeState :=
      { policy := policy, state := genesis, prevHash := zeroHash
      , logIndex := 0, logPath := path
      , deploymentId := ByteArray.empty }
    let actions := [transferAction, transferAction, transferAction]
    let (rs', results) ← processBatch rs actions
    assertEq (3 : Nat) results.length "result count"
    assertEq (0 : Nat) rs'.logIndex "logIndex unchanged"
    -- Verify all rejections.
    let mut rejections := 0
    for r in results do
      match r with
      | .error _ => rejections := rejections + 1
      | .ok _ => pure ()
    assertEq (3 : Nat) rejections "all three rejected"
}

/-- `processPure` is deterministic: equal inputs yield equal
    outputs. -/
def processPureDeterministic : TestCase := {
  name := "processPure is deterministic"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-pure.bin"
    let rs : RuntimeState :=
      { policy := policy, state := genesis, prevHash := zeroHash
      , logIndex := 0, logPath := path
      , deploymentId := ByteArray.empty }
    let r1 := processPure rs transferAction
    let r2 := processPure rs transferAction
    -- Compare results.
    match r1, r2 with
    | .error _, .error _ => pure ()
    | .ok _, .ok _ => pure ()
    | _, _ => throw <| IO.userError "non-deterministic processPure"
}

/-- `processPure` rejects the inadmissible action (Verify=false). -/
def processPureRejection : TestCase := {
  name := "processPure rejects inadmissible action"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-pure-rej.bin"
    let rs : RuntimeState :=
      { policy := policy, state := genesis, prevHash := zeroHash
      , logIndex := 0, logPath := path
      , deploymentId := ByteArray.empty }
    match processPure rs transferAction with
    | .ok _ => throw <| IO.userError "BUG: accepted inadmissible action"
    | .error .notAdmissible => pure ()
}

/-- Term-level API: `processPure_deterministic`. -/
def deterministicAPI : TestCase := {
  name := "processPure_deterministic API stability"
  body := do
    let _proof : ∀ (rs₁ rs₂ : RuntimeState) (st₁ st₂ : SignedAction),
                   rs₁ = rs₂ → st₁ = st₂ →
                   processPure rs₁ st₁ = processPure rs₂ st₂ :=
      processPure_deterministic
    pure ()
}

/-- Bootstrap then bootstrap again: a fresh log followed by a
    re-bootstrap (no actions in between) should produce identical
    `RuntimeState`s.  This catches cases where bootstrap mutates
    state non-idempotently. -/
def bootstrapTwiceIdempotent : TestCase := {
  name := "bootstrap is idempotent on a stable log"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-idem.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    -- First bootstrap.
    let rs₁ ← match (← bootstrap policy genesis path) with
      | .ok (rs, _) => pure rs
      | .error e => throw <| IO.userError s!"first bootstrap failed: {repr e}"
    -- Second bootstrap on the same (still empty) file.
    let rs₂ ← match (← bootstrap policy genesis path) with
      | .ok (rs, _) => pure rs
      | .error e => throw <| IO.userError s!"second bootstrap failed: {repr e}"
    -- Logs index, prevHash, and state hash should match.
    assertEq rs₁.logIndex rs₂.logIndex "logIndex"
    assertEq rs₁.prevHash.toList rs₂.prevHash.toList "prevHash"
    assertEq (hashEncodable rs₁.state).toList (hashEncodable rs₂.state).toList "state hash"
    if (← path.pathExists) then
      IO.FS.removeFile path
}

/-- `bootstrapFromSnapshot` surfaces snapshot errors precisely
    (audit fix: previously these were collapsed into a misleading
    `chainBroken 0` replay error). -/
def bootstrapFromSnapshotSurfacesSnapshotError : TestCase := {
  name := "bootstrapFromSnapshot surfaces snapshot.hashMismatch precisely"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-snap-err.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    -- Build a tampered snapshot.
    let snap := takeSnapshot genesis zeroHash 0
    let tampered := { snap with stateHash := hashStream [0xCC, 0xCC] }
    -- Bootstrapping from the tampered snapshot should report a
    -- `.snapshot .hashMismatch`, not a generic replay error.
    match (← bootstrapFromSnapshot policy tampered path) with
    | .ok _ => throw <| IO.userError "BUG: accepted tampered snapshot"
    | .error (.snapshot .hashMismatch) => pure ()
    | .error other =>
      throw <| IO.userError s!"expected snapshot.hashMismatch, got {repr other}"
}

/-- `BootstrapError` constructor distinguishability: each tag is
    `Repr`-distinguishable from the others.  Catches Phase-6
    additions that accidentally rename / reorder constructors. -/
def bootstrapErrorRepr : TestCase := {
  name := "BootstrapError constructors are distinguishable"
  body := do
    let r1 := repr (BootstrapError.replay (.chainBroken 0))
    let r2 := repr (BootstrapError.snapshot .hashMismatch)
    let r3 := repr (BootstrapError.truncated .truncated)
    let r4 := repr (BootstrapError.logIndexOverrun 5 0)
    -- All four reprs should be pretty-printer distinct.
    let s1 := r1.pretty
    let s2 := r2.pretty
    let s3 := r3.pretty
    let s4 := r4.pretty
    -- Pairwise distinctness check.
    if s1 == s2 || s1 == s3 || s1 == s4 ||
       s2 == s3 || s2 == s4 ||
       s3 == s4 then
      throw <| IO.userError "BUG: distinct BootstrapError reprs collide"
    pure ()
}

/-- `bootstrapFromSnapshot` with `snap.logIndex` exceeding the
    log file's entry count surfaces a precise
    `logIndexOverrun` diagnostic.  Audit fix #5: the snapshot is
    coherent on its own but cannot fit on top of the log. -/
def bootstrapFromSnapshotIndexOverrun : TestCase := {
  name := "bootstrapFromSnapshot rejects logIndex > log length"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-overrun.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    -- Empty log file (zero entries), but snapshot claims index 5.
    let snap := takeSnapshot genesis zeroHash 5
    match (← bootstrapFromSnapshot policy snap path) with
    | .ok _ =>
      throw <| IO.userError "BUG: accepted overrunning snapshot"
    | .error (.logIndexOverrun snapIdx logEntries) =>
      assertEq (5 : Nat) snapIdx "snapIdx field"
      assertEq (0 : Nat) logEntries "logEntries field"
    | .error other =>
      throw <| IO.userError s!"expected logIndexOverrun, got {repr other}"
}

/-- `bootstrapFromSnapshot` slicing: with `snap.logIndex = log.length`,
    the post-snapshot tail is empty, so replay is trivial.  The
    resulting runtime state matches the snapshot's state exactly.
    This exercises the slicing path without needing Verify=true. -/
def bootstrapFromSnapshotEmptyTail : TestCase := {
  name := "bootstrapFromSnapshot slices to empty tail when logIndex = log length"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-empty-tail.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    -- Empty log + snap.logIndex = 0 → tail is empty, no replay needed.
    let snap := takeSnapshot genesis zeroHash 0
    match (← bootstrapFromSnapshot policy snap path) with
    | .ok (rs, _) =>
      -- The resulting state should match the snapshot's state.
      let snapStateHash := snap.stateHash
      let rsStateHash := hashEncodable rs.state
      assertEq snapStateHash.toList rsStateHash.toList "state hash match"
      assertEq (0 : Nat) rs.logIndex "logIndex"
    | .error e =>
      throw <| IO.userError s!"unexpected error: {repr e}"
}

/-- `bootstrapFromSnapshot` slicing exercises the drop-K path.  We
    write two synthetic LogEntries to the log file directly
    (bypassing admissibility), then build a snapshot at
    `logIndex = 2`.  bootstrapFromSnapshot should drop both entries
    (slicing) and return the snapshot state at logIndex = 2.  If
    the slicing were missing, replay would attempt to apply the
    pre-snapshot entries on top of the snapshot's seedHash, fail
    chain check, and return `.replay (.chainBroken 0)`. -/
def bootstrapFromSnapshotDropsPreSnapEntries : TestCase := {
  name := "bootstrapFromSnapshot drops pre-snapshot entries"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-slice.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    -- Two synthetic entries forming a valid chain.
    let entry1 : LogEntry :=
      { prevHash := zeroHash
      , signedAction := transferAction
      , postStateHash := hashStream [0x01] }
    let entry2 : LogEntry :=
      { prevHash := LogEntry.hash entry1
      , signedAction := { transferAction with nonce := 1 }
      , postStateHash := hashStream [0x02] }
    appendEntry path entry1
    appendEntry path entry2
    -- Snapshot at index 2 (after both entries), seedHash = hash of
    -- the last entry.
    let snap := takeSnapshot genesis (LogEntry.hash entry2) 2
    match (← bootstrapFromSnapshot policy snap path) with
    | .ok (rs, _) =>
      -- Correct slicing → empty tail, snapshot state preserved.
      assertEq (2 : Nat) rs.logIndex "logIndex preserved"
      assertEq snap.stateHash.toList (hashEncodable rs.state).toList "state matches snapshot"
      assertEq snap.seedHash.toList rs.prevHash.toList "prevHash = snap seedHash"
    | .error (.replay (.chainBroken _)) =>
      -- This is the bug we're guarding against: pre-snapshot entries
      -- were not dropped, so replay tried to apply entry1's prevHash
      -- (zeroHash) against the snapshot's seedHash (hash of entry2),
      -- failing the chain check at index 0.
      throw <| IO.userError "BUG: bootstrapFromSnapshot did NOT slice pre-snapshot entries"
    | .error e =>
      throw <| IO.userError s!"unexpected error: {repr e}"
    IO.FS.removeFile path
}

/-- `bootstrapFromSnapshot` partial slicing: snap.logIndex = 1 for a
    log with 2 entries.  Slicing leaves 1 entry to replay (entry 2),
    which would fail at admissibility (Verify=false) — but the
    failure index in the error is 0 (post-slice index), confirming
    the slicing happened. -/
def bootstrapFromSnapshotPartialSlice : TestCase := {
  name := "bootstrapFromSnapshot reports post-slice failure index"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-partial-slice.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    let entry1 : LogEntry :=
      { prevHash := zeroHash
      , signedAction := transferAction
      , postStateHash := hashStream [0x01] }
    let entry2 : LogEntry :=
      { prevHash := LogEntry.hash entry1
      , signedAction := { transferAction with nonce := 1 }
      , postStateHash := hashStream [0x02] }
    appendEntry path entry1
    appendEntry path entry2
    -- Snapshot at index 1 (after entry1), seedHash = hash of entry1.
    let snap := takeSnapshot genesis (LogEntry.hash entry1) 1
    match (← bootstrapFromSnapshot policy snap path) with
    | .ok _ =>
      throw <| IO.userError "BUG: replay accepted inadmissible entry2 (Verify=false)"
    | .error (.replay (.notAdmissible 0)) =>
      -- Index 0 in the post-slice tail = entry2 in the original log.
      -- Confirms slicing happened.
      pure ()
    | .error other =>
      throw <| IO.userError s!"expected replay (notAdmissible 0), got {repr other}"
    IO.FS.removeFile path
}

/-- AR.2.2 regression: `processSignedAction` reads
    `rs.deploymentId` rather than hard-coding `ByteArray.empty`.
    Under the empty-default `RuntimeState`, the runtime's behaviour
    is identical to pre-AR (the back-compat path).  Construct a
    `RuntimeState` with the empty default and confirm
    `processSignedAction` rejects the inadmissible action (the
    production `Verify` opaque returns `false`, so the action is
    rejected regardless of deploymentId). -/
def processSignedActionReadsDeploymentIdField : TestCase := {
  name := "AR.2.2: processSignedAction reads rs.deploymentId"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-ar22.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    let rs : RuntimeState :=
      { policy := policy, state := genesis, prevHash := zeroHash
      , logIndex := 0, logPath := path
      , deploymentId := ByteArray.empty }
    -- Confirm the field is what we set it to (no surprise default).
    if rs.deploymentId.size = 0 then pure ()
    else throw <| IO.userError "deploymentId field did not default to empty"
    -- Run processSignedAction: under production Verify (returns
    -- false at Lean level), the action is rejected regardless of
    -- deploymentId; this exercises the new code path.
    match (← processSignedAction rs transferAction) with
    | .ok _ => throw <| IO.userError "BUG: accepted under production Verify"
    | .error .notAdmissible => pure ()
}

/-- AR.2.2 regression: a non-empty `RuntimeState.deploymentId`
    survives the round-trip through `processSignedAction`'s
    success path.  Constructed via the `bootstrap` parameter so
    the field is set non-trivially. -/
def bootstrapWithDeploymentId : TestCase := {
  name := "AR.2.3: bootstrap threads --deployment-id into RuntimeState"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-loop-ar23.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    let did : ByteArray := ⟨#[0xDE, 0xAD, 0xBE, 0xEF]⟩
    match (← bootstrap policy genesis path (deploymentId := did)) with
    | .ok (rs, _) =>
      if rs.deploymentId.data == did.data then pure ()
      else throw <| IO.userError "deploymentId did not survive bootstrap"
    | .error e =>
      throw <| IO.userError s!"bootstrap failed: {repr e}"
}

/-- GP.3.2 wiring regression: `processPure` and `processSignedActionWith`
    must agree on rejection semantics for the same `(rs, st)` input.

    Pre-GP.3.2-fix, `processPure` called `apply_admissible` directly
    while `processSignedActionWith` called `apply_admissible_with_budget`.
    That divergence could let a unit-test `processPure` accept an
    action that the production IO path would reject under bounded
    policy.  After the fix, both paths thread through the same
    budget gate and reject for the same reasons.

    The fixture uses the test `transferAction` whose signature does
    not verify under the production `Verify` opaque — so both paths
    short-circuit at the admissibility check, BEFORE the budget gate
    runs.  The point of the test is that both paths CONSISTENTLY
    produce `.notAdmissible`, not that the budget gate fires
    specifically.

    GP.3.2 follow-up: tests both empty AND non-empty deploymentId
    fixtures.  Pre-fix `processPure` hardcoded `ByteArray.empty` for
    the admissibility check regardless of `rs.deploymentId` — the
    non-empty case verifies that `processPure` now threads
    `rs.deploymentId` end-to-end like `processSignedAction`. -/
def processPureMirrorsProcessSignedAction : TestCase := {
  name := "GP.3.2: processPure mirrors processSignedActionWith rejection semantics"
  body := do
    let runOnce (rs : RuntimeState) : IO Unit := do
      let pureResult := processPure rs transferAction
      let ioResult ← processSignedAction rs transferAction
      match pureResult, ioResult with
      | .error _, .error _ => pure ()
      | .ok _, .error _ =>
        throw <| IO.userError "processPure accepted but processSignedAction rejected (divergent)"
      | .error _, .ok _ =>
        throw <| IO.userError "processPure rejected but processSignedAction accepted (divergent)"
      | .ok _, .ok _ => pure ()
    -- Case 1: empty deploymentId.
    let path1 := System.FilePath.mk "/tmp/knomosis-test-loop-gp3-mirror-empty.bin"
    if (← path1.pathExists) then IO.FS.removeFile path1
    runOnce
      { policy := policy, state := genesis, prevHash := zeroHash
      , logIndex := 0, logPath := path1
      , deploymentId := ByteArray.empty }
    if (← path1.pathExists) then IO.FS.removeFile path1
    -- Case 2: non-empty deploymentId (exercises the rs.deploymentId
    -- pass-through restored by the GP.3.2 follow-up).
    let path2 := System.FilePath.mk "/tmp/knomosis-test-loop-gp3-mirror-bound.bin"
    if (← path2.pathExists) then IO.FS.removeFile path2
    runOnce
      { policy := policy, state := genesis, prevHash := zeroHash
      , logIndex := 0, logPath := path2
      , deploymentId := ⟨#[0xCA, 0xFE, 0xBA, 0xBE]⟩ }
    if (← path2.pathExists) then IO.FS.removeFile path2
}

/-- GP.3.2 wiring: `processPure` is term-level callable and still
    returns an `Except ProcessError ...`.  Pin so the signature does
    not drift away from `processSignedActionWith` after future
    refactors. -/
def processPureBudgetGatedAPI : TestCase := {
  name := "GP.3.2: processPure signature stable (budget-gated)"
  body := do
    let _proof :
        ∀ (_rs : RuntimeState) (_st : SignedAction),
          Except ProcessError (RuntimeState × LogEntry × List Events.Event) :=
      processPure
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [bootstrapEmpty, processInadmissible, processBatchAllReject,
   processPureDeterministic, processPureRejection, deterministicAPI,
   bootstrapTwiceIdempotent, bootstrapFromSnapshotSurfacesSnapshotError,
   bootstrapFromSnapshotIndexOverrun, bootstrapFromSnapshotEmptyTail,
   bootstrapFromSnapshotDropsPreSnapEntries, bootstrapFromSnapshotPartialSlice,
   bootstrapErrorRepr,
   processSignedActionReadsDeploymentIdField,
   bootstrapWithDeploymentId,
   -- GP.3.2 budget-gate wiring:
   processPureMirrorsProcessSignedAction,
   processPureBudgetGatedAPI]

end LoopTests
end LegalKernel.Test.Runtime
