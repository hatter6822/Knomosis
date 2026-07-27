-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
CountSorries — entrypoint wrapper for the `count_sorries`
executable.  See `Tools/CountSorries.lean` for the masking lexer,
the sorry-in-proof-position patterns, and the kernel-TCB file list.

The audit logic lives in the `LegalKernel.Tools.CountSorries`
namespace so that the test driver can import it alongside the other
audit libraries; a root-level `main` in the library module would
collide with every sibling gate's entry point.  This wrapper is the
`lean_exe` root, mirroring `NamingAudit.lean` / `DeferralAudit.lean`.

Exit codes:
  * 0 — every kernel-TCB module has zero `sorry` occurrences.
  * 1 — at least one kernel-TCB module has a `sorry`, or the
    pattern-detector self-check regressed.
-/

import Tools.CountSorries

open LegalKernel.Tools.CountSorries
open LegalKernel.Tools

/-- CLI entrypoint.  Reports per-file sorry counts; fails (exit 1) if
    any kernel-TCB file has a non-zero count, in which case the
    matching lines are echoed to stderr for the failing reviewer.

    AR.14: runs the pattern-detector self-check before the file
    scan so a regression in `isSorryProofPosition` fails fast
    rather than scanning the codebase under a broken detector. -/
def main : IO UInt32 := do
  -- AR.14 self-check.
  let failures := selfCheckPatternDetector
  if !failures.isEmpty then
    IO.eprintln "count_sorries: FAIL — pattern-detector self-check regressed:"
    for f in failures do
      IO.eprintln f
    return 1
  let counts ← aggregate
  let total := counts.foldl (fun acc p => acc + p.snd) 0
  IO.println s!"count_sorries: {total} sorry/sorries across {counts.length} file(s)."
  for (path, n) in counts do
    IO.println s!"  {path}: {n}"
  let mut tcbFail := false
  for tcbPath in kernelTcbFiles do
    let ms ← fileMatches tcbPath
    if ms.length > 0 then
      IO.eprintln s!"count_sorries: FAIL — kernel-TCB file '{tcbPath}' has {ms.length} sorry/sorries:"
      for (n, line) in ms do
        IO.eprintln s!"{tcbPath}:{n}: {line}"
      tcbFail := true
  if tcbFail then
    pure 1
  else
    IO.println "count_sorries: PASS — every kernel-TCB module has zero sorries."
    pure 0
