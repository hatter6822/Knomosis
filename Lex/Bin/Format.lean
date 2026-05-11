/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Bin.Format — entry-point wrapper for the `lex_format` Lake
executable.

LX.36.

Mirrors `Lex/Bin/Lint.lean` / `Lex/Bin/Codegen.lean` /
`Lex/Bin/Diff.lean`: keeps the entry-point glue out of the
library module so test files can import `Lex.Tools.Format`'s
helpers without colliding with other binaries' top-level `main`.
-/

import Lex.Tools.Format

/-- Entry point for the `lex_format` Lake executable.  Forwards
    to `LegalKernel.Tools.Lex.Format.main`.  (The library namespace
    is `LegalKernel.Tools.Lex.Format`, preserved across the LX
    directory refactor.) -/
def main (args : List String) : IO UInt32 :=
  LegalKernel.Tools.Lex.Format.main args
