-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
ApiStabilityAudit — entrypoint wrapper for the
`api_stability_audit` executable.  See `Tools/ApiStabilityAudit.lean`
for the detection rule and the frozen-debt allowlist format.

Exit codes:
  * 0 — every unascribed API pin is on the allowlist.
  * 1 — at least one unallowlisted unascribed pin.
-/

import Tools.ApiStabilityAudit

open LegalKernel.Tools.ApiStabilityAudit

/-- CLI entrypoint. -/
def main : IO UInt32 := do
  let (violations, total) ← aggregate
  let frozen := total - violations.length
  if violations.isEmpty then
    IO.println s!"api_stability_audit: PASS — {total} API pin(s) scanned; \
                  {frozen} unascribed and allowlisted, 0 new."
    if frozen > 0 then
      IO.println s!"  {frozen} allowlisted binding(s) remain to be given type \
                    ascriptions (tools/api_stability_allowlist.txt)."
    pure 0
  else
    IO.eprintln s!"api_stability_audit: FAIL — {violations.length} \
                   unallowlisted API pin(s) with no type ascription:"
    for v in violations do
      IO.eprintln v.format
    IO.eprintln ""
    IO.eprintln "A `let _ := @thm` binding pins only that the NAME exists."
    IO.eprintln "CLAUDE.md's API-stability guarantee is that elaboration"
    IO.eprintln "fails when a signature changes, which requires the type:"
    IO.eprintln ""
    IO.eprintln "    let _proof : <the theorem's full type> := thm"
    IO.eprintln ""
    IO.eprintln "Add the ascription.  The allowlist freezes the pre-existing"
    IO.eprintln "debt so it burns down; do not extend it for new code."
    pure 1
