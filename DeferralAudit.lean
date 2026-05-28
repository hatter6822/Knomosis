/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
DeferralAudit — entrypoint wrapper for the `deferral_audit`
executable.  See `Tools/DeferralAudit.lean` for the audit logic.

Exit codes:
  * 0 — no deferral markers found.
  * 1 — at least one deferral marker found (and not allowlisted).
-/

import Tools.DeferralAudit

open LegalKernel.Tools.DeferralAudit

/-- CLI entrypoint. -/
def main : IO UInt32 := do
  IO.println "deferral_audit: scanning for deferral markers..."
  let violations ← runAudit
  if violations.isEmpty then
    IO.println "deferral_audit: PASS — no deferral markers."
    return 0
  else
    IO.println s!"deferral_audit: FAIL — {violations.length} violation(s):"
    for v in violations do
      IO.println v.format
    IO.println ""
    IO.println "Fix: ship the missing proof / implementation, OR rewrite the"
    IO.println "comment without deferral language.  There is no allowlist."
    return 1
