/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

import LegalKernel
import LegalKernel.FaultProof.TerminateBundle
import LegalKernel.Runtime.CellProofJson

/-!
Phase-5 `knomosis` runtime CLI.

The Phase-5 / Workstream-D binary multiplexes seven subcommands via
its first argument (plus the `help` alias):

  * `knomosis info`         — print the kernel build tag.
  * `knomosis process LOG IN [OUT]`
                        — process the binary `SignedAction` records in
                          `IN` against the (initially empty) genesis
                          state, persisting log entries to `LOG`.  If
                          `OUT` is provided, the final state's hash is
                          written to it (handy for CI).
  * `knomosis replay LOG`   — replay `LOG` against the empty genesis state
                          using the `unrestricted` policy and print the
                          final state hash.  Equivalent to
                          `knomosis-replay LOG`.
  * `knomosis bootstrap LOG` — load + truncate `LOG`, replay it, then print
                          the runtime state and final hash.  Used by
                          ops to verify a log file is parseable.
  * `knomosis snapshot LOG SNAP_PATH`
                        — load + replay `LOG`, then write a snapshot
                          of the final state to `SNAP_PATH`.
  * `knomosis withdrawal-proof SNAP_PATH ID`  (Workstream D.2)
                        — load `SNAP_PATH`, extract the canonical
                          withdrawal proof for `ID`, and print the
                          hex-encoded leaf + sibling path to stdout.
                          Suitable for piping into `CanonBridge.sol`'s
                          L1 redemption call.
  * `knomosis help`         — show the per-subcommand usage text.

The CLI uses the `unrestricted` `AuthorityPolicy` (every signer can
issue every action) and an empty genesis state — sufficient for
demoing the end-to-end flow without committing to a particular
deployment's authority configuration.  Production deployments wire
their own `policy` via a Lean-level configuration module.

Genesis Plan §12 WU 5.1 acceptance criteria:

  * "single transfer round-trip" — exercised by `knomosis process` with a
    one-record input file containing a transfer.
  * "log-replay produces matching post-state hashes" — exercised by
    `knomosis replay` on the same log file, comparing against the hash
    `knomosis process` printed.
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

    For Phase 5 we pre-fuel the loop with the input length + 1 to
    avoid needing a Lean termination proof on the `Encodable.decode`
    boundary; production deployments wire a real streaming parser.

    Fuel-exhaustion handling: the empty-stream case takes priority
    over fuel-exhaustion — so `(0, [], acc)` returns success.  But
    `(0, byte::_, _)` is unreachable in practice (fuel was set to
    a strict upper bound on iteration count) and surfaces a clear
    `invalidLength` error if hit, rather than silently truncating
    the input.  This makes the function's contract honest: either
    the entire stream parses or we report exactly why we stopped. -/
def decodeSignedActionStream :
    Nat → Stream → List SignedAction → Except DecodeError (List SignedAction)
  | _,        [],     acc => .ok acc.reverse
  | 0,        _ :: _, _   =>
    .error (.invalidLength "decodeSignedActionStream: fuel exhausted (internal bug)")
  | fuel + 1, s,      acc =>
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

/-- Format a `ContentHash` as a hex string (re-export from
    `LegalKernel.Runtime.CellProofJson` for backward compatibility
    of in-file callers). -/
def formatHashHex (h : ContentHash) : String :=
  LegalKernel.Runtime.CellProofJson.formatHashHex h

/-- Subcommand: `knomosis info`.  Prints the build tag and the
    hash-implementation identity (Audit-3.1).  Operators reading
    this output can tell at a glance whether a binary is running
    with the Lean fallback hash (FNV-1a-64 padded to 32 bytes —
    NOT for production) or a production-grade implementation. -/
def cmdInfo : IO UInt32 := do
  IO.println s!"knomosis: legal-kernel runtime"
  IO.println s!"  build tag: {LegalKernel.kernelBuildTag}"
  IO.println s!"  Phase 6: Disputes and Adjudication (WU 6.1 – 6.12)"
  IO.println s!"  hash:        {hashImplementationIdentifier ()}"
  if isProductionHash then
    IO.println s!"  hash-grade:  production"
  else
    IO.println s!"  hash-grade:  fallback (FNV-1a-64 padded to 32, NOT FOR PRODUCTION)"
  pure 0

/-- Audit-3.1: emit a single-line stderr warning at the start of
    every chain-touching subcommand if the binary is running with
    the Lean fallback hash and the operator did not explicitly opt
    in via `--allow-fallback-hash`.  Returns immediately on
    production-grade implementations. -/
def warnIfFallbackHash (allowFallback : Bool) : IO Unit := do
  if !isProductionHash && !allowFallback then
    IO.eprintln "WARN: running with non-production hash; \
                 pass --allow-fallback-hash to suppress this warning"

/-- Subcommand: `knomosis process LOG IN [OUT]`.  Loads `LOG` (truncating
    any partial tail), replays it, then processes each `SignedAction`
    in `IN`, appending log entries to `LOG`.  If `OUT` is provided,
    writes the final state hash to it. -/
def cmdProcess (logPath : System.FilePath) (inputPath : System.FilePath)
    (outputPath : Option System.FilePath)
    (deploymentId : ByteArray := ByteArray.empty) : IO UInt32 := do
  -- 1. Bootstrap: load existing log (if any), truncate partial tail.
  IO.println s!"bootstrapping from log {logPath}"
  match (← bootstrap demoPolicy demoGenesis logPath deploymentId) with
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

/-- Subcommand: `knomosis replay LOG`.  Replays `LOG` and prints the
    final state hash.  AR.2.6: `deploymentId` is threaded so the
    replay's admissibility check uses the same domain-separated
    signing input as the runtime that produced the log. -/
def cmdReplay (logPath : System.FilePath)
    (deploymentId : ByteArray := ByteArray.empty) : IO UInt32 := do
  IO.println s!"replaying log {logPath}"
  let (entries, _, frameErr?) ← readAllEntries logPath
  if let some err := frameErr? then
    IO.eprintln s!"warning: log has partial tail ({repr err})"
  IO.println s!"  parsed {entries.length} entries"
  -- AR.2.4 entry: route the admissibility check through the
  -- deploymentId-aware variant.  The result is hashed identically
  -- to the legacy path.
  match replayWith Verify deploymentId demoPolicy demoGenesis entries with
  | .ok finalState =>
    IO.println s!"  final state hash: {formatHashHex (hashEncodable finalState)}"
    pure 0
  | .error e =>
    IO.eprintln s!"  replay failed: {repr e}"
    pure 1

/-- Subcommand: `knomosis bootstrap LOG`.  Validates `LOG` parseability,
    truncates partial tails, and reports the final state.  AR.2.6:
    `deploymentId` is threaded into the `RuntimeState`. -/
def cmdBootstrap (logPath : System.FilePath)
    (deploymentId : ByteArray := ByteArray.empty) : IO UInt32 := do
  IO.println s!"bootstrapping from log {logPath}"
  match (← bootstrap demoPolicy demoGenesis logPath deploymentId) with
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

/-- Subcommand: `knomosis snapshot LOG SNAP_PATH`.  Replays `LOG`, then
    writes a snapshot to `SNAP_PATH`.  AR.2.6: `deploymentId` is
    threaded into the bootstrap step. -/
def cmdSnapshot (logPath : System.FilePath) (snapPath : System.FilePath)
    (deploymentId : ByteArray := ByteArray.empty) : IO UInt32 := do
  IO.println s!"taking snapshot from log {logPath}"
  match (← bootstrap demoPolicy demoGenesis logPath deploymentId) with
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

/-- Subcommand: `knomosis replay-up-to LOG IDX`.  Replays the log
    prefix `entries[0..idx]` against the genesis state via
    `replayWith Verify deploymentId` and writes the resulting
    `commitExtendedState` output (32-byte hex, no `0x` prefix,
    terminated by `\n`) to stdout.

    **Purpose.**  The off-chain `knomosis-faultproof-observer` Rust
    crate's `SubprocessTruthOracle` shells out to this subcommand
    to obtain the canonical state commit at an arbitrary log
    index — closes the RH-G.4 plan deliverable that previously
    deferred the Lean side.

    **Exit codes.**
      * 0 — success; commit printed to stdout.
      * 2 — `idx` not a Nat OR `idx > entries.length`.
      * (Log read errors propagate as Lean IO exceptions, which
        the runtime translates to a non-zero exit; the precise
        code is platform-dependent.)

    **Idempotency / determinism.**  Pure replay over the log
    prefix; two invocations against the same log + idx produce
    the same commit byte-for-byte. -/
def cmdReplayUpTo (logPath : System.FilePath) (idxStr : String)
    (deploymentId : ByteArray := ByteArray.empty) : IO UInt32 := do
  match idxStr.toNat? with
  | none =>
    IO.eprintln s!"knomosis replay-up-to: idx '{idxStr}' is not a Nat"
    pure 2
  | some idx =>
    let (entries, _, frameErr?) ← readAllEntries logPath
    if let some err := frameErr? then
      IO.eprintln s!"warning: log has partial tail ({repr err})"
    if idx > entries.length then
      IO.eprintln
        s!"knomosis replay-up-to: idx {idx} > log length {entries.length}"
      pure 2
    else
      let prefix_ := entries.take idx
      match replayWith Verify deploymentId demoPolicy demoGenesis prefix_ with
      | .error e =>
        IO.eprintln s!"replay-up-to failed: {repr e}"
        pure 1
      | .ok st =>
        let commit := LegalKernel.FaultProof.commitExtendedState st
        -- The commit is 32 bytes of hex (64 chars).  Print exactly
        -- those + a newline; the Rust subprocess wrapper expects
        -- the byte form to be parseable as such.
        IO.println (formatHashHex commit)
        pure 0

/-- Re-export of the library `formatCellProofJson` so in-file
    callers can use the unqualified name.  Definition lives in
    `LegalKernel.Runtime.CellProofJson` to enable testing from
    `LegalKernel.Test.Integration.ExportCellProofsCli`. -/
def formatCellProofJson (p : LegalKernel.FaultProof.CellProof) : String :=
  LegalKernel.Runtime.CellProofJson.formatCellProofJson p

/-- Subcommand: `knomosis export-cell-proofs LOG IDX SIGNER`.

    Replays the log prefix `entries[0..idx]` to obtain the
    pre-state for the action at log index `idx`, decodes that
    action (via `entries[idx]`), and emits the cell-proof bundle
    for that action's required cells.

    Output: a JSON array of cell-proof objects, one per line in
    the bundle, terminated by a closing `]`.  The off-chain
    observer's [`canon_faultproof_observer::submitter::CellProof`]
    type consumes this format.

    Exit codes:
    * 0 — success.
    * 1 — log parse error.
    * 2 — idx out of range or signer not a Nat. -/
def cmdExportCellProofs (logPath : System.FilePath) (idxStr : String)
    (signerStr : String) (deploymentId : ByteArray := ByteArray.empty) :
    IO UInt32 := do
  match idxStr.toNat?, signerStr.toNat? with
  | none, _ =>
    IO.eprintln s!"knomosis export-cell-proofs: idx '{idxStr}' is not a Nat"
    pure 2
  | _, none =>
    IO.eprintln s!"knomosis export-cell-proofs: signer '{signerStr}' is not a Nat"
    pure 2
  | some idx, some signerNat =>
    let (entries, _, frameErr?) ← readAllEntries logPath
    if let some err := frameErr? then
      IO.eprintln s!"warning: log has partial tail ({repr err})"
    if idx >= entries.length then
      IO.eprintln
        s!"knomosis export-cell-proofs: idx {idx} >= log length {entries.length}"
      pure 2
    else
      let prefix_ := entries.take idx
      match replayWith Verify deploymentId demoPolicy demoGenesis prefix_ with
      | .error e =>
        IO.eprintln
          s!"knomosis export-cell-proofs: prefix replay failed at idx {idx} ({repr e})"
        pure 1
      | .ok preState =>
      -- `Inhabited LogEntry` is not derived; use `Option`
      -- accessor + match to defend.  The `idx < entries.length`
      -- guard above ensures `entries[idx]?` is `some`.
        match entries[idx]? with
        | none =>
          IO.eprintln "knomosis export-cell-proofs: internal error (idx within bounds but list access failed)"
          pure 1
        | some entry =>
          let action := entry.signedAction.action
          -- Audit-pass-4-round-4 HIGH fix: derive `signer` from the
          -- LOG ENTRY's signed action, NOT from the CLI argument.
          -- The CLI arg is preserved for backward-compat (operators
          -- already typed it) but a mismatch surfaces as a typed
          -- error: passing the wrong signer would build a bundle
          -- whose cells point at an actor the action doesn't
          -- mention, which the L1 step VM would reject AFTER the
          -- operator paid gas.
          --
          -- Audit-pass-4-round-5 LOW fix: reject signerNat ≥ 2^64
          -- explicitly so the operator gets a clear error rather
          -- than a spurious "match" against a smaller entry signer
          -- whose value happens to equal `signerNat % 2^64`.
          if signerNat ≥ (1 <<< 64) then
            IO.eprintln
              s!"knomosis export-cell-proofs: signer {signerNat} exceeds u64::MAX; ActorIds are u64-sized."
            return 2
          -- ActorId = UInt64 abbreviation (per Kernel.lean:51).
          let entrySigner : ActorId := entry.signedAction.signer
          let cliSigner : ActorId := UInt64.ofNat signerNat
          if entrySigner ≠ cliSigner then
            IO.eprintln
              s!"knomosis export-cell-proofs: signer mismatch (CLI supplied {cliSigner}, log entry has {entrySigner}).  Re-run with the correct SIGNER for log index {idx}."
            pure 2
          else
            let signer : ActorId := entrySigner
            let bundle :=
              LegalKernel.FaultProof.Observer.buildObserverCellProofs preState action signer
            -- Emit as a JSON array.
            IO.println "["
            let mut first := true
            for p in bundle.proofs do
              let leadIn := if first then "  " else ", "
              IO.println s!"{leadIn}{formatCellProofJson p}"
              first := false
            IO.println "]"
            pure 0

/-- Subcommand: `knomosis export-terminate-bundle LOG IDX`.

    Replays the log prefix `entries[0..idx]` to obtain the
    pre-state for the action at log index `idx`, decodes that
    action (via `entries[idx]`), and emits the canonical
    terminate-on-single-step bundle as a single line of JSON.

    The off-chain observer (`knomosis-faultproof-observer`) consumes
    this JSON to construct calldata for the L1 contract's
    `terminateOnSingleStep(uint256, uint8, bytes, uint64,
    CellProof[], bytes32)` entry point.

    Output: a single JSON object on stdout containing
    `action_kind`, `action_fields_hex`, `signer`,
    `claimed_post_commit_hex`, and `cell_proofs` (an array of
    cell-proof objects).  See
    `LegalKernel/FaultProof/TerminateBundle.lean` for the
    canonical wire format.

    Exit codes:
    * 0 — success.
    * 1 — log parse error.
    * 2 — idx out of range. -/
def cmdExportTerminateBundle (logPath : System.FilePath) (idxStr : String)
    (deploymentId : ByteArray := ByteArray.empty) : IO UInt32 := do
  let _ := deploymentId
  match idxStr.toNat? with
  | none =>
    IO.eprintln s!"knomosis export-terminate-bundle: idx '{idxStr}' is not a Nat"
    pure 2
  | some idx =>
    let (entries, _, frameErr?) ← readAllEntries logPath
    if let some err := frameErr? then
      IO.eprintln s!"warning: log has partial tail ({repr err})"
    if idx >= entries.length then
      IO.eprintln
        s!"knomosis export-terminate-bundle: idx {idx} >= log length {entries.length}"
      pure 2
    else
      let prefix_ := entries.take idx
      let preState := LegalKernel.Disputes.kernelOnlyReplay demoGenesis prefix_
      match entries[idx]? with
      | none =>
        IO.eprintln "knomosis export-terminate-bundle: internal error (idx within bounds but list access failed)"
        pure 1
      | some entry =>
        let bundle :=
          LegalKernel.FaultProof.TerminateBundle.buildTerminateBundle preState entry
        let fixtureId := s!"log[{idx}]"
        IO.println
          (LegalKernel.FaultProof.TerminateBundle.formatTerminateBundleJson
            fixtureId bundle)
        pure 0

/-- Format a `WithdrawalProof` as a hex-encoded summary string —
    leaf bytes + index + 64 sibling hashes.  Suitable for piping to
    a Solidity test driver via stdout. -/
def formatWithdrawalProof (proof : LegalKernel.Bridge.WithdrawalProof) : String :=
  let leafHex := formatHashHex proof.leaf
  let sibsHex := proof.siblings.toList.map formatHashHex
  let lines :=
    s!"leaf    : {leafHex}\n" ++
    s!"index   : {proof.index}\n" ++
    s!"siblings:\n" ++
    String.join (sibsHex.map (fun s => s!"  {s}\n"))
  lines

/-- Subcommand: `knomosis withdrawal-proof SNAPSHOT_FILE WITHDRAWAL_ID`.
    Reads the snapshot file, extracts the withdrawal proof for the
    given id, and prints a hex-encoded summary to stdout.  Exits
    non-zero if the snapshot fails to load or the id is not in the
    snapshot's pending set. -/
def cmdWithdrawalProof (snapPath : System.FilePath) (idStr : String) :
    IO UInt32 := do
  match idStr.toNat? with
  | none =>
    IO.eprintln s!"withdrawal-proof: '{idStr}' is not a valid Nat"
    pure 2
  | some idx =>
    match (← loadSnapshot snapPath) with
    | .error e =>
      IO.eprintln s!"snapshot load failed: {repr e}"
      pure 1
    | .ok snap =>
      match LegalKernel.Bridge.extractProof snap idx with
      | none =>
        IO.eprintln s!"withdrawal-proof: id {idx} is not in snapshot's pending set"
        pure 1
      | some proof =>
        IO.println (formatWithdrawalProof proof)
        IO.println s!"root    : {formatHashHex snap.bridgeWithdrawalRoot}"
        pure 0

/-- Print the CLI help text. -/
def cmdHelp : IO UInt32 := do
  IO.println "knomosis — Phase-5 runtime CLI"
  IO.println ""
  IO.println "Usage:"
  IO.println "  knomosis [GLOBAL_FLAGS] info"
  IO.println "  knomosis [GLOBAL_FLAGS] process          LOG IN [OUT]"
  IO.println "  knomosis [GLOBAL_FLAGS] replay           LOG"
  IO.println "  knomosis [GLOBAL_FLAGS] bootstrap        LOG"
  IO.println "  knomosis [GLOBAL_FLAGS] snapshot         LOG SNAP_PATH"
  IO.println "  knomosis [GLOBAL_FLAGS] withdrawal-proof SNAP_PATH ID"
  IO.println "  knomosis [GLOBAL_FLAGS] replay-up-to      LOG IDX"
  IO.println "  knomosis [GLOBAL_FLAGS] export-cell-proofs LOG IDX SIGNER"
  IO.println "  knomosis [GLOBAL_FLAGS] export-terminate-bundle LOG IDX"
  IO.println "  knomosis help"
  IO.println ""
  IO.println "Global flags:"
  IO.println "  --allow-fallback-hash"
  IO.println "        Suppress the WARN-on-startup line emitted when the binary"
  IO.println "        is running with the Lean fallback hash function (FNV-1a-64"
  IO.println "        padded to 32 bytes).  Use only for explicit test runs."
  IO.println ""
  IO.println "Where:"
  IO.println "  LOG       path to the append-only transition log."
  IO.println "  IN        path to a binary file of concatenated SignedAction CBE records."
  IO.println "  OUT       optional path to write the final state hash (32 bytes)."
  IO.println "  SNAP_PATH path to write or read the snapshot file."
  IO.println "  ID        a `WithdrawalId` (Nat) to look up in the snapshot."
  IO.println "  IDX       a `LogIndex` (Nat) for the replay-up-to subcommand."
  IO.println "  SIGNER    an `ActorId` (Nat) for the export-cell-proofs subcommand."
  IO.println ""
  IO.println "See docs/abi.md for the on-disk and on-wire byte layouts."
  pure 0

/-- AR.2.6 / M-1.  Convert a hex character to its 0..15 nibble
    value, or `none` if non-hex.  Shared hex-decoding helper for
    the `--deployment-id` flag parsers in `Main` and `Replay`. -/
def hexCharToNibble (c : Char) : Option Nat :=
  if c ≥ '0' && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if c ≥ 'a' && c ≤ 'f' then some (10 + c.toNat - 'a'.toNat)
  else if c ≥ 'A' && c ≤ 'F' then some (10 + c.toNat - 'A'.toNat)
  else none

/-- AR.2.6 / M-1.  Decode a hex string (no `0x` prefix; even-length;
    lowercase or uppercase) into a `ByteArray`.  Returns `none` on
    odd length or any non-hex character. -/
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

/-- Pre-parse global flags from the argument list.  Returns the
    flag values and the remaining args (with flags stripped).
    Audit-3.1 introduces `--allow-fallback-hash`; AR.2.6 adds
    `--deployment-id <hex>`. -/
def parseGlobalFlags (args : List String) : Bool × Option ByteArray × List String :=
  let rec go (xs : List String) : Bool × Option ByteArray × List String :=
    match xs with
    | [] => (false, none, [])
    | "--allow-fallback-hash" :: rest =>
      -- Pre-Audit-3.1 the destructured `allow` was unused
      -- because we always return `true` here.  Use `_` to
      -- silence the unused-variable linter.
      let (_, did, tail) := go rest
      (true, did, tail)
    | "--deployment-id" :: hex :: rest =>
      let (allow, _, tail) := go rest
      (allow, decodeHexString hex, tail)
    | x :: rest =>
      let (allow, did, tail) := go rest
      (allow, did, x :: tail)
  go args

/-- AR.2.6 / M-1.  Emit a stderr warning when `--deployment-id` is
    absent.  The dev-mode `knomosis` binary continues to use the
    empty sentinel, but the operator is nudged to wire up a
    production deploymentId. -/
def warnIfNoDeploymentId (did : Option ByteArray) : IO Unit :=
  match did with
  | some _ => pure ()
  | none =>
    IO.eprintln
      "warning: --deployment-id <hex> not supplied; using empty sentinel (dev mode)"

/-- The Phase-5 `knomosis` runtime CLI's entry point.  Dispatches on the
    first argument; falls through to `cmdHelp` on missing / unknown
    subcommands.  Global flags are pre-parsed before the subcommand
    dispatcher (Audit-3.1 + AR.2.6). -/
def main (args : List String) : IO UInt32 := do
  let (allowFallbackHash, depId?, rest) := parseGlobalFlags args
  let depId : ByteArray := depId?.getD ByteArray.empty
  match rest with
  | [] => cmdHelp
  | ["info"] => cmdInfo
  | ["help"] => cmdHelp
  | "process" :: log :: inp :: tail =>
    warnIfFallbackHash allowFallbackHash
    warnIfNoDeploymentId depId?
    let out := match tail with
      | []      => none
      | o :: _  => some (System.FilePath.mk o)
    cmdProcess (System.FilePath.mk log) (System.FilePath.mk inp) out depId
  | ["replay", log]   => do
    warnIfFallbackHash allowFallbackHash
    warnIfNoDeploymentId depId?
    cmdReplay (System.FilePath.mk log) depId
  | ["bootstrap", log] => do
    warnIfFallbackHash allowFallbackHash
    warnIfNoDeploymentId depId?
    cmdBootstrap (System.FilePath.mk log) depId
  | ["snapshot", log, snap] => do
    warnIfFallbackHash allowFallbackHash
    warnIfNoDeploymentId depId?
    cmdSnapshot (System.FilePath.mk log) (System.FilePath.mk snap) depId
  | ["withdrawal-proof", snap, idStr] => do
    warnIfFallbackHash allowFallbackHash
    cmdWithdrawalProof (System.FilePath.mk snap) idStr
  | ["replay-up-to", log, idxStr] => do
    warnIfFallbackHash allowFallbackHash
    warnIfNoDeploymentId depId?
    cmdReplayUpTo (System.FilePath.mk log) idxStr depId
  | ["export-cell-proofs", log, idxStr, signerStr] => do
    warnIfFallbackHash allowFallbackHash
    warnIfNoDeploymentId depId?
    cmdExportCellProofs (System.FilePath.mk log) idxStr signerStr depId
  | ["export-terminate-bundle", log, idxStr] => do
    warnIfFallbackHash allowFallbackHash
    warnIfNoDeploymentId depId?
    cmdExportTerminateBundle (System.FilePath.mk log) idxStr depId
  | _ => do
    IO.eprintln "knomosis: unrecognised arguments; try `knomosis help`."
    pure 2
