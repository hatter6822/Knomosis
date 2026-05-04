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

/-- Format a `ContentHash` (8 LE bytes) as 16 ASCII hex chars.
    Mirror of the `Main.lean` helper; duplicated to keep the two
    binaries independent (each binary should be readable in
    isolation). -/
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
  IO.println "  canon-replay LOG [SNAPSHOT]"
  IO.println ""
  IO.println "Replays LOG (an append-only Canon log file) against the empty"
  IO.println "genesis state (or, if SNAPSHOT is given, against the snapshot's"
  IO.println "starting state) and prints the final state hash."
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
    * `LOG_TRUNCATED <count>` (info, not failure) when the log file
      had a partial tail; replay still proceeds against the
      recovered prefix.

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
  let seedResult : Except String (ContentHash × ExtendedState) ←
    match snapshotPath with
    | none => pure (Except.ok (zeroHash, replayGenesis))
    | some p => do
      match (← loadSnapshot p) with
      | .ok snap =>
        match restoreSnapshot snap with
        | .ok (st, sh, _) => pure (Except.ok (sh, st))
        | .error e        => pure (Except.error s!"SNAPSHOT_ERROR {repr e}")
      | .error e          => pure (Except.error s!"SNAPSHOT_DECODE_ERROR {repr e}")
  match seedResult with
  | Except.error msg =>
    IO.println msg
    pure 1
  | Except.ok (seedHash, seedState) =>
    -- Step 2: read the log.
    let (entries, _, frameErr?) ← readAllEntries logPath
    if let some _ := frameErr? then
      IO.println s!"LOG_TRUNCATED entries={entries.length}"
    -- Step 3: replay.
    match replayFromSeed replayPolicy seedHash seedState entries with
    | .ok finalState =>
      let h := hashEncodable finalState
      IO.println s!"OK {formatHashHex h}"
      pure 0
    | .error e =>
      IO.println s!"REPLAY_ERROR {repr e}"
      pure 1

/-- The `canon-replay` entry point.  Dispatches on argv. -/
def main (args : List String) : IO UInt32 :=
  match args with
  | [log] => runReplay (System.FilePath.mk log) none
  | [log, snap] => runReplay (System.FilePath.mk log) (some (System.FilePath.mk snap))
  | _ => usage
