/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

import LegalKernel

/-!
Phase-5 `canon-replay` binary.

A focused, single-purpose tool: given a log file path and an optional
genesis state path, replay the log and print the final state hash.
This is the WU 5.5 deliverable in standalone form (the `canon` binary
also exposes a `replay` subcommand, but `canon-replay` is the
auditor's entry point — it has no other modes and does not write
to the log file).

Usage:

  canon-replay LOG [SNAPSHOT]

If `SNAPSHOT` is provided, replay starts from the snapshot's
`(seedHash, state)` rather than from the empty genesis.  The
`unrestricted` policy is hard-coded (see `Main.lean` for the
production-policy story).

Acceptance (Genesis Plan §13.2): the final state hash matches the
hash the `canon` runtime printed when it processed the same actions
online.  CI exercises this by running `canon process` then
`canon-replay` on the resulting log and asserting the hashes are
byte-identical.
-/

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
  IO.println "canon-replay — Phase-5 replay tool"
  IO.println ""
  IO.println "Usage:"
  IO.println "  canon-replay [--allow-fallback-hash] LOG [SNAPSHOT]"
  IO.println ""
  IO.println "Replays LOG (an append-only Canon log file) against the empty"
  IO.println "genesis state (or, if SNAPSHOT is given, against the snapshot's"
  IO.println "starting state) and prints the final state hash."
  IO.println ""
  IO.println "Audit-3.1: by default, canon-replay refuses to run with the"
  IO.println "Lean fallback hash (FNV-1a-64 padded to 32) because the"
  IO.println "auditor's reproduction guarantee is meaningless under a"
  IO.println "non-cryptographic hash.  Pass --allow-fallback-hash to opt in"
  IO.println "for explicit test runs."
  IO.println ""
  IO.println "Output formats:"
  IO.println "  OK <hash> via=<id>          (clean replay, exit 0)"
  IO.println "  FALLBACK_HASH_NOT_PERMITTED (audit-3.1, fallback w/o flag, exit 1)"
  IO.println "  REPLAY_ERROR <repr>         (replay failure, exit 1)"
  IO.println "  SNAPSHOT_ERROR <repr>       (snapshot restore failed, exit 1)"
  IO.println "  SNAPSHOT_DECODE_ERROR <repr> (snapshot bytes invalid, exit 1)"
  IO.println "  SNAPSHOT_INDEX_OVERRUN ...  (snapshot logIndex > log size, exit 1)"
  IO.println "  LOG_TRUNCATED <count>       (info; replay still proceeds)"
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
    same file the runtime appends to), and `canon-replay` slices it
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
    (snapshotPath : Option System.FilePath) : IO UInt32 := do
  -- Step 1: optionally load the snapshot.  Fail fast on error.
  -- The seed triple is (seedHash, seedState, snapLogIndex); snapLogIndex
  -- is 0 when no snapshot is provided, otherwise the snapshot's
  -- recorded `logIndex` (used to slice the log to post-snapshot entries).
  let seedResult : Except String (ContentHash × ExtendedState × Nat) ←
    match snapshotPath with
    | none => pure (Except.ok (zeroHash, replayGenesis, 0))
    | some p => do
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
      -- Step 4: replay the post-snapshot tail.
      match replayFromSeed replayPolicy seedHash seedState tail with
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
    IO.eprintln s!"WARN: canon-replay running with fallback hash \
                   ({hashImplementationIdentifier ()})"
    pure true
  else
    IO.println "FALLBACK_HASH_NOT_PERMITTED"
    IO.eprintln s!"canon-replay refuses to run with the Lean fallback hash. \
                   The auditor's reproduction guarantee is meaningless under \
                   a non-cryptographic hash. Pass --allow-fallback-hash to \
                   opt in for explicit test runs."
    pure false

/-- Pre-parse global flags from the argument list.  Audit-3.1
    introduces `--allow-fallback-hash`. -/
def parseGlobalFlags (args : List String) : Bool × List String :=
  args.foldr
    (fun arg (allow, rest) =>
      if arg = "--allow-fallback-hash" then (true, rest)
      else (allow, arg :: rest))
    (false, [])

/-- The `canon-replay` entry point.  Dispatches on argv. -/
def main (args : List String) : IO UInt32 := do
  let (allowFallbackHash, rest) := parseGlobalFlags args
  if !(← checkHashGrade allowFallbackHash) then
    pure 1
  else match rest with
  | [log] => runReplay (System.FilePath.mk log) none
  | [log, snap] => runReplay (System.FilePath.mk log) (some (System.FilePath.mk snap))
  | _ => usage
