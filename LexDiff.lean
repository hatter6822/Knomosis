/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LexDiff.lean — entry-point wrapper for the `lex_diff` Lake
executable.

LX.34 / LX.35.

This file imports `Tools.LexDiff` (the library module containing
helpers + `main` def) and re-exports `main` at the project-root
namespace so Lake's `lean_exe lex_diff` declaration can find it.

Mirrors the `Main.lean` / `LexLint.lean` / `LexCodegen.lean`
pattern: keeping the entry-point glue out of the library module
(`Tools/LexDiff.lean`) lets test files import the helpers
without colliding with other binaries' top-level `main`.
-/

import Tools.LexDiff

/-- Project-root entry point for the `lex_diff` Lake
    executable.  Forwards to `LegalKernel.Tools.Lex.Diff.main`. -/
def main (args : List String) : IO UInt32 :=
  LegalKernel.Tools.Lex.Diff.main args
