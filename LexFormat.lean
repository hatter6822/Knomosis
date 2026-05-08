/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LexFormat.lean — entry-point wrapper for the `lex_format` Lake
executable.

LX.36.

Mirrors `LexLint.lean` / `LexCodegen.lean` / `LexDiff.lean`:
keeps the entry-point glue out of the library module so test
files can import `Tools.LexFormat`'s helpers without colliding
with other binaries' top-level `main`.
-/

import Tools.LexFormat

/-- Project-root entry point for the `lex_format` Lake
    executable.  Forwards to `LegalKernel.Tools.Lex.Format.main`. -/
def main (args : List String) : IO UInt32 :=
  LegalKernel.Tools.Lex.Format.main args
