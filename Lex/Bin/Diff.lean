-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Lex.Bin.Diff — entry-point wrapper for the `lex_diff` Lake
executable.

LX.34 / LX.35.

This file imports `Lex.Tools.Diff` (the library module containing
helpers + `main` def) and re-exports `main` so Lake's
`lean_exe lex_diff` declaration can find it.

Mirrors the `Main.lean` / `Lex/Bin/Lint.lean` /
`Lex/Bin/Codegen.lean` pattern: keeping the entry-point glue out
of the library module (`Lex/Tools/Diff.lean`) lets test files
import the helpers without colliding with other binaries'
top-level `main`.
-/

import Lex.Tools.Diff

/-- Entry point for the `lex_diff` Lake executable.  Forwards to
    `LegalKernel.Tools.Lex.Diff.main`.  (The library namespace is
    `LegalKernel.Tools.Lex.Diff`, preserved across the LX directory
    refactor.) -/
def main (args : List String) : IO UInt32 :=
  LegalKernel.Tools.Lex.Diff.main args
