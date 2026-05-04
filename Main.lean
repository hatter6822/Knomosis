/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

import LegalKernel

/-!
Phase-0 placeholder runtime.

This binary exists so that `lake build` produces a default executable
target and so that the Phase-5 runtime work units (`Runtime/Loop.lean`,
`Runtime/LogFile.lean`, `Runtime/Replay.lean`) have a concrete file to
extend.  It deliberately does *not* invoke the kernel: in Phase 0 the
kernel is exercised only through the test driver and through Lean's
elaborator (which checks every theorem at build time).
-/

/-- Placeholder `canon` runtime entry point.  Prints the kernel build
    tag and a pointer to where the real runtime will live (Phase 5,
    Genesis Plan §12).  Replaced wholesale by `Runtime/Loop.lean` once
    Phase 5 lands. -/
def main : IO Unit := do
  IO.println "canon: legal-kernel placeholder runtime."
  IO.println s!"  kernel build tag: {LegalKernel.kernelBuildTag}"
  IO.println "  See docs/GENESIS_PLAN.md §12 Phase 5 for the real runtime."
