-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
StubAudit — entrypoint wrapper for the `stub_audit` executable.
See `Tools/StubAudit.lean` for the placeholder-body patterns, the
red-flag docstring tokens, and the allowlist format.

The audit logic lives in the `LegalKernel.Tools.StubAudit` namespace
so that the test driver can import it alongside the other audit
libraries; a root-level `main` in the library module would collide
with every sibling gate's entry point.  This wrapper is the
`lean_exe` root, mirroring `NamingAudit.lean` / `DeferralAudit.lean`.

Exit codes:
  * 0 — no unallowlisted stub matches found.
  * 1 — at least one unallowlisted stub match found.
-/

import Tools.StubAudit

open LegalKernel.Tools.StubAudit

/-- CLI entrypoint.  Reports any stub matches with red-flag docstrings.
    Exits 1 if any unallowlisted match exists. -/
def main : IO UInt32 := do
  let violations ← aggregate
  if violations.isEmpty then
    IO.println "stub_audit: PASS — no unallowlisted stub matches found."
    pure 0
  else
    IO.eprintln s!"stub_audit: FAIL — {violations.length} unallowlisted stub match(es):"
    for v in violations do
      IO.eprintln s!"  {v.path}:{v.lineNo}: {stripWhitespace v.rawLine}"
      IO.eprintln s!"    allowlist key: {v.canonicalKey}"
    IO.eprintln "Add the canonical key (path:line|raw-line) to tools/stub_allowlist.txt"
    IO.eprintln "after reviewer sign-off, OR remove the stub."
    pure 1
