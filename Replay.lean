-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Replay — entry point for the `knomosis-replay` audit binary.

The flag parser, the usage text, and the replay driver live in
`LegalKernel.Runtime.ReplayCli` so they are importable by the test
driver; a root-level `main` here cannot coexist with any sibling
binary's `main` in a single module.  See that module's docstring.
-/

import LegalKernel.Runtime.ReplayCli

open LegalKernel.Runtime.ReplayCli

/-- The `knomosis-replay` entry point.  Dispatches on argv.

    AR.2.6 / M-1: the auditor binary REFUSES to run without an
    explicit `--deployment-id <hex>` flag.  The audit-binary's
    soundness guarantee is meaningless if cross-deployment-replay
    rejection is silently disabled by an empty default
    deploymentId.  The dev-mode `knomosis` binary remains permissive
    (warns but proceeds); only `knomosis-replay` is strict. -/
def main (args : List String) : IO UInt32 := do
  let flags := parseGlobalFlags args
  match flags.flagError with
  | some msg =>
    IO.println "FLAG_ERROR"
    IO.eprintln s!"knomosis-replay: {msg}"
    let _ ← usage
    return 1
  | none => pure ()
  let allowFallbackHash := flags.allowFallbackHash
  let depId? := flags.deploymentId
  let rest := flags.positional
  if !(← checkHashGrade allowFallbackHash) then
    pure 1
  else
    -- AR.2.6: strict deploymentId gate.  Absent flag → exit 1
    -- with a clear diagnostic; the operator must explicitly
    -- supply the deploymentId for the audit to be sound.
    match depId? with
    | none =>
      IO.println "DEPLOYMENT_ID_MISSING"
      IO.eprintln
        "knomosis-replay refuses to run without --deployment-id <hex>. \
         The audit binary's cross-deployment-replay-rejection \
         guarantee is meaningless under the empty default; supply \
         the deployment's id explicitly (32-byte BLAKE3 of genesis)."
      pure 1
    | some depId =>
      match rest with
      | [log] => runReplay (System.FilePath.mk log) none depId flags.requiredAttestor
      | [log, snap] =>
          runReplay (System.FilePath.mk log) (some (System.FilePath.mk snap)) depId
            flags.requiredAttestor
      | _ =>
        -- A wrong ARGUMENT COUNT is a usage error, not a successful
        -- audit.  `usage` prints to stdout and returns 0 (it is also
        -- the `--help` path); the exit code here must be non-zero so a
        -- CI job or a shell `set -e` sees the failure.
        IO.println "USAGE_ERROR"
        IO.eprintln
          s!"knomosis-replay expects LOG [SNAPSHOT]; got {rest.length} positional argument(s)."
        let _ ← usage
        pure 1
