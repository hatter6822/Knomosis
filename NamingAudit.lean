/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
NamingAudit — entrypoint wrapper for the `naming_audit`
executable.  See `Tools/NamingAudit.lean` for the audit logic +
forbidden-token list + allowlist format.

Exit codes:
  * 0 — every file name and declaration identifier is content-driven.
  * 1 — at least one forbidden-token match found (and not allowlisted).
-/

import Tools.NamingAudit

open LegalKernel.Tools.NamingAudit

/-- CLI entrypoint. -/
def main : IO UInt32 := do
  IO.println "naming_audit: scanning for provenance / process tokens..."
  let violations ← runAudit
  if violations.isEmpty then
    IO.println "naming_audit: PASS — every file + identifier is content-driven."
    return 0
  else
    IO.println s!"naming_audit: FAIL — {violations.length} violation(s):"
    for v in violations do
      IO.println v.format
    IO.println ""
    IO.println "Fix: rename the file or identifier to describe its content."
    IO.println "Allowlist: add an entry to `tools/naming_allowlist.txt` only"
    IO.println "if the match is a content word that the audit's substring"
    IO.println "check mis-classifies (rare; review carefully)."
    return 1
