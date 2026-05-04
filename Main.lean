/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

import LegalKernel

/-!
Phase-5 `canon` runtime CLI.

The Phase-5 binary multiplexes six subcommands via its first
argument (plus the `help` alias):

  * `canon info`         — print the kernel build tag.
  * `canon process LOG IN [OUT]`
                        — process the binary `SignedAction` records in
                          `IN` against the (initially empty) genesis
                          state, persisting log entries to `LOG`.  If
                          `OUT` is provided, the final state's hash is
                          written to it (handy for CI).
  * `canon replay LOG`   — replay `LOG` against the empty genesis state
                          using the `unrestricted` policy and print the
                          final state hash.  Equivalent to
                          `canon-replay LOG`.
  * `canon bootstrap LOG` — load + truncate `LOG`, replay it, then print
                          the runtime state and final hash.  Used by
                          ops to verify a log file is parseable.
  * `canon snapshot LOG SNAP_PATH`
                        — load + replay `LOG`, then write a snapshot
                          of the final state to `SNAP_PATH`.
  * `canon help`         — show the per-subcommand usage text.

The CLI uses the `unrestricted` `AuthorityPolicy` (every signer can
issue every action) and an empty genesis state — sufficient for
demoing the end-to-end flow without committing to a particular
deployment's authority configuration.  Production deployments wire
their own `policy` via a Lean-level configuration module.

Genesis Plan §12 WU 5.1 acceptance criteria:

  * "single transfer round-trip" — exercised by `canon process` with a
    one-record input file containing a transfer.
  * "log-replay produces matching post-state hashes" — exercised by
    `canon replay` on the same log file, comparing against the hash
    `canon process` printed.
-/

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding

/-- The `unrestricted` policy: every signer can issue every action.
    Useful for demo / smoke testing; production deployments supply
    their own policy. -/
def demoPolicy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- The empty genesis state: no balances, no nonces, no registry.
    Production deployments build a richer genesis (founders
    registered, initial mint, etc.) and persist its bytes
    alongside the log file. -/
def demoGenesis : ExtendedState := ExtendedState.empty

/-- Decode a stream of concatenated `SignedAction` CBE records.
    Walks the stream, decoding one record at a time, until the
    stream is exhausted or a decode error occurs.  Termination
    measure: the input stream's length strictly decreases (each
    successful `SignedAction.decode` consumes ≥ 9 bytes — the CBE
    head of the embedded action — so `rest.length < s.length`).

    For Phase 5 we pre-fuel the loop with the input length to avoid
    needing a Lean termination proof on the `Encodable.decode`
    boundary; production deployments wire a real streaming parser. -/
def decodeSignedActionStream :
    Nat → Stream → List SignedAction → Except DecodeError (List SignedAction)
  | 0, _, acc => .ok acc.reverse
  | _ + 1, [], acc => .ok acc.reverse
  | fuel + 1, s, acc =>
    match Encodable.decode (T := SignedAction) s with
    | .ok (sa, rest) => decodeSignedActionStream fuel rest (sa :: acc)
    | .error e       => .error e

/-- Read a binary file containing concatenated `SignedAction` CBE
    records (no framing — each record is decoded by `SignedAction.decode`
    on the residual stream until the buffer is exhausted).  Returns
    the parsed actions in order, or an error if any record fails to
    decode.  Pre-fuels the recursion with `bytes.size + 1` so the
    function is structurally recursive. -/
def readSignedActionsFromFile (path : System.FilePath) :
    IO (Except DecodeError (List SignedAction)) := do
  let bytes ← IO.FS.readBinFile path
  let lst := bytes.toList
  pure (decodeSignedActionStream (lst.length + 1) lst [])

/-- Format a `ContentHash` (8 LE bytes) as 16 ASCII hex chars. -/
def formatHashHex (h : ContentHash) : String :=
  let toHex (b : UInt8) : String :=
    let hi := b.toNat / 16
    let lo := b.toNat % 16
    let toChar (n : Nat) : Char :=
      if n < 10 then Char.ofNat (n + 48)        -- '0'..'9'
               else Char.ofNat (n - 10 + 97)    -- 'a'..'f'
    String.ofList [toChar hi, toChar lo]
  h.toList.foldl (fun acc b => acc ++ toHex b) ""

/-- Subcommand: `canon info`.  Prints the build tag. -/
def cmdInfo : IO UInt32 := do
  IO.println s!"canon: legal-kernel runtime"
  IO.println s!"  build tag: {LegalKernel.kernelBuildTag}"
  IO.println s!"  Phase 5: Runtime and Extraction (WU 5.1 – 5.6, 5.9 – 5.12)"
  pure 0

/-- Subcommand: `canon process LOG IN [OUT]`.  Loads `LOG` (truncating
    any partial tail), replays it, then processes each `SignedAction`
    in `IN`, appending log entries to `LOG`.  If `OUT` is provided,
    writes the final state hash to it. -/
def cmdProcess (logPath : System.FilePath) (inputPath : System.FilePath)
    (outputPath : Option System.FilePath) : IO UInt32 := do
  -- 1. Bootstrap: load existing log (if any), truncate partial tail.
  IO.println s!"bootstrapping from log {logPath}"
  match (← bootstrap demoPolicy demoGenesis logPath) with
  | .error e =>
    IO.eprintln s!"bootstrap failed: {repr e}"
    pure 1
  | .ok (rs, frameErr?) =>
    if let some err := frameErr? then
      IO.eprintln s!"warning: truncated partial tail ({repr err})"
    IO.println s!"bootstrap OK ({rs.logIndex} entries)"
    -- 2. Read the input SignedAction stream.
    match (← readSignedActionsFromFile inputPath) with
    | .error e =>
      IO.eprintln s!"input parse failed: {repr e}"
      pure 1
    | .ok actions =>
      IO.println s!"processing {actions.length} action(s)"
      -- 3. Process each action.
      let (rs', results) ← processBatch rs actions
      let mut failures := 0
      let mut idx := 0
      for r in results do
        match r with
        | .ok pr =>
          IO.println s!"  [{idx}] OK ({pr.events.length} events)"
        | .error e =>
          IO.println s!"  [{idx}] FAIL ({repr e})"
          failures := failures + 1
        idx := idx + 1
      -- 4. Print final hash.
      let finalHash := hashEncodable rs'.state
      IO.println s!"final state hash: {formatHashHex finalHash}"
      -- 5. Optionally write hash to output file.
      if let some out := outputPath then
        IO.FS.writeBinFile out (ByteArray.mk finalHash.toList.toArray)
        IO.println s!"wrote final hash to {out}"
      if failures = 0 then pure 0 else pure 1

/-- Subcommand: `canon replay LOG`.  Replays `LOG` and prints the
    final state hash. -/
def cmdReplay (logPath : System.FilePath) : IO UInt32 := do
  IO.println s!"replaying log {logPath}"
  let (entries, _, frameErr?) ← readAllEntries logPath
  if let some err := frameErr? then
    IO.eprintln s!"warning: log has partial tail ({repr err})"
  IO.println s!"  parsed {entries.length} entries"
  match replayHash demoPolicy demoGenesis entries with
  | .ok h =>
    IO.println s!"  final state hash: {formatHashHex h}"
    pure 0
  | .error e =>
    IO.eprintln s!"  replay failed: {repr e}"
    pure 1

/-- Subcommand: `canon bootstrap LOG`.  Validates `LOG` parseability,
    truncates partial tails, and reports the final state. -/
def cmdBootstrap (logPath : System.FilePath) : IO UInt32 := do
  IO.println s!"bootstrapping from log {logPath}"
  match (← bootstrap demoPolicy demoGenesis logPath) with
  | .error e =>
    IO.eprintln s!"bootstrap failed: {repr e}"
    pure 1
  | .ok (rs, frameErr?) =>
    if let some err := frameErr? then
      IO.eprintln s!"warning: truncated partial tail ({repr err})"
    IO.println s!"bootstrap OK"
    IO.println s!"  log index: {rs.logIndex}"
    IO.println s!"  prev hash: {formatHashHex rs.prevHash}"
    IO.println s!"  state hash: {formatHashHex (hashEncodable rs.state)}"
    pure 0

/-- Subcommand: `canon snapshot LOG SNAP_PATH`.  Replays `LOG`, then
    writes a snapshot to `SNAP_PATH`. -/
def cmdSnapshot (logPath : System.FilePath) (snapPath : System.FilePath) :
    IO UInt32 := do
  IO.println s!"taking snapshot from log {logPath}"
  match (← bootstrap demoPolicy demoGenesis logPath) with
  | .error e =>
    IO.eprintln s!"bootstrap failed: {repr e}"
    pure 1
  | .ok (rs, _) =>
    let snap := takeSnapshot rs.state rs.prevHash rs.logIndex
    saveSnapshot snapPath snap
    IO.println s!"  state hash:  {formatHashHex snap.stateHash}"
    IO.println s!"  log index:   {snap.logIndex}"
    IO.println s!"  wrote {snapPath}"
    pure 0

/-- Print the CLI help text. -/
def cmdHelp : IO UInt32 := do
  IO.println "canon — Phase-5 runtime CLI"
  IO.println ""
  IO.println "Usage:"
  IO.println "  canon info"
  IO.println "  canon process    LOG IN [OUT]"
  IO.println "  canon replay     LOG"
  IO.println "  canon bootstrap  LOG"
  IO.println "  canon snapshot   LOG SNAP_PATH"
  IO.println "  canon help"
  IO.println ""
  IO.println "Where:"
  IO.println "  LOG       path to the append-only transition log."
  IO.println "  IN        path to a binary file of concatenated SignedAction CBE records."
  IO.println "  OUT       optional path to write the final state hash (8 LE bytes)."
  IO.println "  SNAP_PATH path to write the snapshot file."
  IO.println ""
  IO.println "See docs/abi.md for the on-disk and on-wire byte layouts."
  pure 0

/-- The Phase-5 `canon` runtime CLI's entry point.  Dispatches on the
    first argument; falls through to `cmdHelp` on missing / unknown
    subcommands. -/
def main (args : List String) : IO UInt32 :=
  match args with
  | [] => cmdHelp
  | ["info"] => cmdInfo
  | ["help"] => cmdHelp
  | "process" :: log :: inp :: rest =>
    let out := match rest with
      | []      => none
      | o :: _  => some (System.FilePath.mk o)
    cmdProcess (System.FilePath.mk log) (System.FilePath.mk inp) out
  | ["replay", log]   => cmdReplay (System.FilePath.mk log)
  | ["bootstrap", log] => cmdBootstrap (System.FilePath.mk log)
  | ["snapshot", log, snap] =>
    cmdSnapshot (System.FilePath.mk log) (System.FilePath.mk snap)
  | _ => do
    IO.eprintln "canon: unrecognised arguments; try `canon help`."
    pure 2
