-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/


import LegalKernel

/-!
LegalKernel.Runtime.ReplayCli — the `knomosis-replay` auditor
binary's logic, split out of the executable root so it can be
unit-tested.

`Replay.lean` is a `lean_exe` root: a root-level `main` there
cannot be imported alongside any sibling binary's `main`, which is
why the flag parser and the replay driver had no tests and
`AttestedSnapshotCli.lean` recorded that "CLI-level invocation
tests would require subprocess scaffolding".  They do not — the
flag parser is a pure function and the driver is ordinary `IO`.
This module holds both; `Replay.lean` is the thin entry point,
mirroring the `NamingAudit.lean` / `Tools.NamingAudit` split used
by the audit binaries.

This module is **not** part of the trusted computing base.
-/

namespace LegalKernel.Runtime.ReplayCli

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding

/-- The `unrestricted` policy: every signer can issue every action. -/
def replayPolicy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- The empty genesis state used when no snapshot is provided. -/
def replayGenesis : ExtendedState := ExtendedState.empty

/-- Format a `ContentHash` (32 bytes after Audit-3.1 width
    unification) as a hex string (64 chars on the post-Audit-3
    canonical width).  Mirror of the `Main.lean` helper; duplicated
    to keep the two binaries independent (each binary should be
    readable in isolation). -/
def formatHashHex (h : ContentHash) : String :=
  let toHex (b : UInt8) : String :=
    let hi := b.toNat / 16
    let lo := b.toNat % 16
    let toChar (n : Nat) : Char :=
      if n < 10 then Char.ofNat (n + 48)
               else Char.ofNat (n - 10 + 97)
    String.ofList [toChar hi, toChar lo]
  h.toList.foldl (fun acc b => acc ++ toHex b) ""

/-- Print usage and exit. -/
def usage : IO UInt32 := do
  IO.println "knomosis-replay — Phase-5 replay tool"
  IO.println ""
  IO.println "Usage:"
  IO.println "  knomosis-replay [--allow-fallback-hash] --deployment-id <hex>"
  IO.println "                  [--require-attestation <pk-hex>] LOG [SNAPSHOT]"
  IO.println ""
  IO.println "Replays LOG (an append-only Knomosis log file) against the empty"
  IO.println "genesis state (or, if SNAPSHOT is given, against the snapshot's"
  IO.println "starting state) and prints the final state hash."
  IO.println ""
  IO.println "Audit-3.1: by default, knomosis-replay refuses to run with the"
  IO.println "Lean fallback hash (FNV-1a-64 padded to 32) because the"
  IO.println "auditor's reproduction guarantee is meaningless under a"
  IO.println "non-cryptographic hash.  Pass --allow-fallback-hash to opt in"
  IO.println "for explicit test runs."
  IO.println ""
  IO.println "AR.3.2: --require-attestation <pk-hex> requires SNAPSHOT to be an"
  IO.println "attested-snapshot envelope signed by that attestor over"
  IO.println "(snapshot, deploymentId).  A bare Snapshot is REJECTED under the"
  IO.println "flag: its own hash check re-derives the hash from the supplied"
  IO.println "state, so an adversarial supplier passes it trivially."
  IO.println ""
  IO.println "Output formats:"
  IO.println "  OK <hash> via=<id>          (clean replay, exit 0)"
  IO.println "  FALLBACK_HASH_NOT_PERMITTED (audit-3.1, fallback w/o flag, exit 1)"
  IO.println "  REPLAY_ERROR <repr>         (replay failure, exit 1)"
  IO.println "  SNAPSHOT_ERROR <repr>       (snapshot restore failed, exit 1)"
  IO.println "  SNAPSHOT_DECODE_ERROR <repr> (snapshot bytes invalid, exit 1)"
  IO.println "  SNAPSHOT_INDEX_OVERRUN ...  (snapshot logIndex > log size, exit 1)"
  IO.println "  LOG_TRUNCATED <count>       (info; replay still proceeds)"
  IO.println "  FLAG_ERROR                  (malformed / unrecognised flag, exit 1)"
  IO.println "  USAGE_ERROR                 (wrong positional-argument count, exit 1)"
  IO.println "  ATTESTATION_INVALID         (--require-attestation, bad signature, exit 1)"
  IO.println "  ATTESTATION_DECODE_ERROR    (--require-attestation, not an envelope, exit 1)"
  IO.println "  ATTESTATION_DEPLOYMENT_MISMATCH (envelope signed for another deployment, exit 1)"
  pure 0

/-- Run replay against the given log + optional snapshot.  Prints
    one of:

    * `OK <hash>` on a clean replay (exit code 0).
    * `REPLAY_ERROR <repr>` on a replay-time failure (exit 1).
    * `SNAPSHOT_ERROR <repr>` when a requested snapshot fails to
      restore — the tool exits non-zero (exit 1) WITHOUT proceeding
      to replay against the wrong starting state.
    * `SNAPSHOT_DECODE_ERROR <repr>` when the snapshot bytes don't
      parse — same exit semantics as `SNAPSHOT_ERROR`.
    * `SNAPSHOT_INDEX_OVERRUN snap_index=N log_entries=M` when the
      snapshot's recorded `logIndex` exceeds the log file's entry
      count — exit 1 (the snapshot doesn't fit on top of the log).
    * `LOG_TRUNCATED <count>` (info, not failure) when the log file
      had a partial tail; replay still proceeds against the
      recovered prefix.

    Snapshot+log semantics (Genesis Plan §13.2): when a snapshot is
    provided, the log file is expected to be the *full* log (the
    same file the runtime appends to), and `knomosis-replay` slices it
    to entries `[snap.logIndex..)` to apply "only subsequent log
    entries".  Equivalent: the on-disk LOG always contains the full
    history; SNAPSHOT just lets a fresh replica skip the prefix.

    Security note: failing fast on snapshot errors is critical.
    Earlier drafts silently continued with an empty genesis when a
    snapshot failed, which would print an `OK` line containing the
    hash of an empty-replay state — masking the snapshot failure
    and presenting fake-valid output to the caller.  The current
    implementation refuses to produce an `OK` line unless the
    requested starting state was successfully recovered. -/
def runReplay (logPath : System.FilePath)
    (snapshotPath : Option System.FilePath)
    (deploymentId : ByteArray := ByteArray.empty)
    (requiredAttestor : Option PublicKey := none) : IO UInt32 := do
  -- Step 0 — deployment-config reconstruction.  The auditor has no CLI
  -- config flags (unlike `knomosis replay`, which re-supplies them and
  -- only cross-checks the sidecars).  It must instead RE-DERIVE the
  -- producer's config from the persisted sidecars: the budget policy +
  -- epoch length (`<LOG>.budgetcfg`), the gas-pool policy
  -- (`<LOG>.gaspoolcfg`), and the refund rate (`<LOG>.refundratecfg`).
  -- All three participate in the log's post-state hashes (the refund
  -- rate additionally gates which `claimBudgetRefund` actions are
  -- admissible), so without reconstructing them a config-bearing log
  -- would be rejected or would replay to a divergent hash.  A corrupt
  -- sidecar fails loudly — the auditor must never silently audit under
  -- the wrong config.
  let budgetCfg? ← match ← BudgetSidecar.load logPath with
    | .error msg => IO.println s!"CONFIG_ERROR {msg}"; return 1
    | .ok c => pure c
  let gasPoolCfg? ← match ← GasPoolSidecar.load logPath with
    | .error msg => IO.println s!"CONFIG_ERROR {msg}"; return 1
    | .ok c => pure c
  let refundCfg? ← match ← RefundRateSidecar.load logPath with
    | .error msg => IO.println s!"CONFIG_ERROR {msg}"; return 1
    | .ok c => pure c
  -- Replay PARAMS (applied regardless of snapshot, since they are not
  -- captured in the snapshot's state): epoch length, refund rate, and the
  -- gas-pool-intersected AuthorityPolicy.
  let epochLength : Nat := (budgetCfg?.map (·.epochLength)).getD 0
  let refundRate : ResourceId → Nat :=
    (refundCfg?.map (·.toRefundRate)).getD (fun _ => 0)
  let auditorPolicy : AuthorityPolicy :=
    Bridge.gasPoolGenesisPolicyOfConfig replayPolicy gasPoolCfg?
  -- The from-genesis seed STATE must carry the producer's budget policy +
  -- gas-pool localPolicies; a snapshot already captures both in its
  -- restored state (and its budget policy's `currentEpoch` may have
  -- advanced past genesis), so the snapshot path below uses its state
  -- as-is and only this from-genesis seed is reconstructed.
  let reconstructedGenesis :=
    Bridge.gasPoolGenesisStateOfConfig
      ((budgetCfg?.map (fun bc =>
          { replayGenesis with budgetPolicy := BudgetSidecar.toPolicy bc })).getD
        replayGenesis)
      gasPoolCfg?
  -- Step 1: optionally load the snapshot.  Fail fast on error.
  -- The seed triple is (seedHash, seedState, snapLogIndex); snapLogIndex
  -- is 0 when no snapshot is provided, otherwise the snapshot's
  -- recorded `logIndex` (used to slice the log to post-snapshot entries).
  let seedResult : Except String (ContentHash × ExtendedState × Nat) ←
    match snapshotPath with
    | none => pure (Except.ok (zeroHash, reconstructedGenesis, 0))
    | some p => do
      match requiredAttestor with
      -- AR.3.2 / M-2: `--require-attestation <pk-hex>` was documented in
      -- `AttestedSnapshot.lean`, `docs/GENESIS_PLAN.md` §13.2 and
      -- `docs/audits/06-runtime.md` but implemented in neither binary.
      -- A bare `Snapshot`'s own `restoreSnapshot` check only re-derives
      -- the hash from the supplied encoded state, so an adversarial
      -- supplier's fabricated snapshot passes it trivially — the whole
      -- point of the envelope.  With the flag the auditor requires the
      -- envelope; a bare `Snapshot` is REJECTED outright rather than
      -- silently accepted at a weaker guarantee.
      | some attestorPk => do
        match (← loadAttestedSnapshot p) with
        | .error e =>
          pure (Except.error s!"ATTESTATION_DECODE_ERROR {repr e}")
        | .ok att =>
          -- Single-entry registry: the operator-supplied key IS the
          -- trusted attestor set for this run.
          let registry : KeyRegistry :=
            (Std.TreeMap.empty : KeyRegistry).insert att.attestor attestorPk
          if !verifyAttestationWith Verify registry att then
            pure (Except.error "ATTESTATION_INVALID")
          else if att.deploymentId != deploymentId then
            -- The attestation is over `(snapshot, deploymentId)`, so a
            -- valid signature for a DIFFERENT deployment must not be
            -- accepted here: that is exactly the cross-deployment replay
            -- the `--deployment-id` gate exists to refuse.
            pure (Except.error "ATTESTATION_DEPLOYMENT_MISMATCH")
          else
            match restoreSnapshot att.snap with
            | .ok (st, sh, idx) => pure (Except.ok (sh, st, idx))
            | .error e          => pure (Except.error s!"SNAPSHOT_ERROR {repr e}")
      | none => do
        match (← loadSnapshot p) with
        | .ok snap =>
          match restoreSnapshot snap with
          | .ok (st, sh, idx) => pure (Except.ok (sh, st, idx))
          | .error e          => pure (Except.error s!"SNAPSHOT_ERROR {repr e}")
        | .error e            => pure (Except.error s!"SNAPSHOT_DECODE_ERROR {repr e}")
  match seedResult with
  | Except.error msg =>
    IO.println msg
    pure 1
  | Except.ok (seedHash, seedState, snapLogIndex) =>
    -- Step 2: read the log.
    let (entries, _, frameErr?) ← readAllEntries logPath
    if let some _ := frameErr? then
      IO.println s!"LOG_TRUNCATED entries={entries.length}"
    -- Step 3: slice to post-snapshot entries.  Genesis Plan §13.2
    -- semantics: replica applies "only subsequent log entries".
    if snapLogIndex > entries.length then
      IO.println s!"SNAPSHOT_INDEX_OVERRUN snap_index={snapLogIndex} log_entries={entries.length}"
      pure 1
    else
      let tail := entries.drop snapLogIndex
      -- Step 4: replay the post-snapshot tail.  AR.2.4: deploymentId
      -- is threaded into the parameterised `replayFromSeedWith` so
      -- cross-deployment-replay rejection is observable in the
      -- auditor binary.  GP.9.1 auditor fix: the reconstructed
      -- `auditorPolicy` (gas-pool-intersected) and the persisted
      -- `epochLength` / `refundRate` are threaded so a config-bearing
      -- log audits to the same state hash `knomosis replay` produces;
      -- `snapLogIndex` is the absolute start index, so a snapshot
      -- replay advances budget epochs from the correct base.
      match replayFromSeedWith Verify deploymentId auditorPolicy seedHash
              seedState tail snapLogIndex epochLength refundRate with
      | .ok finalState =>
        let h := hashEncodable finalState
        IO.println s!"OK {formatHashHex h} via={hashImplementationIdentifier ()}"
        pure 0
      | .error e =>
        IO.println s!"REPLAY_ERROR {repr e}"
        pure 1

/-- Audit-3.1: pre-flight hash-grade check.  Auditor binary refuses
    to run under the Lean fallback hash unless the operator
    explicitly opts in.  Returns true iff the binary should proceed. -/
def checkHashGrade (allowFallback : Bool) : IO Bool := do
  if isProductionHash then
    pure true
  else if allowFallback then
    IO.eprintln s!"WARN: knomosis-replay running with fallback hash \
                   ({hashImplementationIdentifier ()})"
    pure true
  else
    IO.println "FALLBACK_HASH_NOT_PERMITTED"
    IO.eprintln s!"knomosis-replay refuses to run with the Lean fallback hash. \
                   The auditor's reproduction guarantee is meaningless under \
                   a non-cryptographic hash. Pass --allow-fallback-hash to \
                   opt in for explicit test runs."
    pure false

/-- AR.2.6: shared hex-decoding helpers (copy of `Main.lean`'s
    versions; duplicated so each binary remains independent). -/
def hexCharToNibble (c : Char) : Option Nat :=
  if c ≥ '0' && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if c ≥ 'a' && c ≤ 'f' then some (10 + c.toNat - 'a'.toNat)
  else if c ≥ 'A' && c ≤ 'F' then some (10 + c.toNat - 'A'.toNat)
  else none

/-- AR.2.6: hex → ByteArray.  Even length, lower/upper case. -/
def decodeHexString (s : String) : Option ByteArray := Id.run do
  let cs := s.toList
  if cs.length % 2 ≠ 0 then return none
  let mut bytes : List UInt8 := []
  let mut idx : Nat := 0
  let csA := cs.toArray
  while idx < cs.length do
    let hi := hexCharToNibble (csA[idx]!)
    let lo := hexCharToNibble (csA[idx + 1]!)
    match hi, lo with
    | some h, some l => bytes := bytes ++ [(h * 16 + l).toUInt8]
    | _, _ => return none
    idx := idx + 2
  return some (ByteArray.mk bytes.toArray)

/-- The parsed global-flag state.

    `flagError` is the fail-closed channel: a malformed flag value or
    an unrecognised `--`-prefixed token sets it, and `main` refuses to
    run.  Before this existed, an unrecognised flag fell through the
    catch-all into the positional arguments, produced an argument shape
    `main` did not match, and reached `usage` — which returned exit
    **0**.  An operator following a stale docstring got a silent PASS
    from an audit binary. -/
structure GlobalFlags where
  /-- Audit-3.1: opt in to running under the non-cryptographic
      fallback hash. -/
  allowFallbackHash : Bool := false
  /-- AR.2.6: the deployment id, REQUIRED on the audit binary. -/
  deploymentId : Option ByteArray := none
  /-- AR.3.2: the attestor public key for `--require-attestation`. -/
  requiredAttestor : Option PublicKey := none
  /-- First flag-parsing error, if any.  Non-`none` ⇒ refuse to run. -/
  flagError : Option String := none
  /-- The residual positional arguments. -/
  positional : List String := []
  deriving Inhabited

/-- Record the FIRST flag error only, so the diagnostic names the
    earliest problem rather than the last. -/
def GlobalFlags.withError (f : GlobalFlags) (msg : String) : GlobalFlags :=
  { f with flagError := f.flagError.orElse (fun _ => some msg) }

/-- Pre-parse global flags from the argument list.  Audit-3.1
    introduces `--allow-fallback-hash`; AR.2.6 adds
    `--deployment-id <hex>` (REQUIRED on the audit binary); AR.3.2
    adds `--require-attestation <pk-hex>`.

    Unrecognised `--`-prefixed tokens and malformed flag values are
    recorded in `flagError` rather than passed through as positional
    arguments. -/
def parseGlobalFlags (args : List String) : GlobalFlags :=
  let rec go (xs : List String) : GlobalFlags :=
    match xs with
    | [] => {}
    | "--allow-fallback-hash" :: rest =>
      { go rest with allowFallbackHash := true }
    | "--deployment-id" :: hex :: rest =>
      let f := go rest
      match decodeHexString hex with
      | some bs => { f with deploymentId := some bs }
      | none    =>
        f.withError s!"--deployment-id expects an even-length hex string, got {repr hex}"
    | ["--deployment-id"] =>
      GlobalFlags.withError {} "--deployment-id requires a value"
    | "--require-attestation" :: hex :: rest =>
      let f := go rest
      match decodeHexString hex with
      | some bs => { f with requiredAttestor := some bs }
      | none    =>
        f.withError
          s!"--require-attestation expects an even-length hex public key, got {repr hex}"
    | ["--require-attestation"] =>
      GlobalFlags.withError {} "--require-attestation requires a value"
    | x :: rest =>
      let f := go rest
      -- Fail closed on anything that LOOKS like a flag.  Passing it
      -- through as a positional argument is how a typo'd or stale flag
      -- reached `usage` and exited 0.
      if x.startsWith "--" then
        f.withError s!"unrecognised flag {repr x}"
      else
        { f with positional := x :: f.positional }
  go args

end LegalKernel.Runtime.ReplayCli
