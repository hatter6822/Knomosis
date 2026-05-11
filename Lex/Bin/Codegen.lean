/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Bin.Codegen — entry-point wrapper for the `lex_codegen` Lake
executable.

Mirrors the `Main.lean` / `canon`, `Replay.lean` /
`canon-replay`, and `Lex/Bin/Lint.lean` / `lex_lint` pattern: a
thin top-level `def main` that delegates to the namespaced
library function in `Lex/Tools/Codegen.lean`.

Splitting the entry-point glue from the library code lets tests
(`Lex/Test/Tools/Codegen.lean`) import the helpers without
colliding on top-level `def main` declarations across multiple
audit binaries.
-/

import Lex.Tools.Codegen

/-- The `lex_codegen` Lake executable's `main` function.
    Delegates to `LegalKernel.Tools.Lex.Codegen.main`.  (The
    library namespace is `LegalKernel.Tools.Lex.Codegen`,
    preserved across the LX directory refactor.) -/
def main (args : List String) : IO UInt32 :=
  LegalKernel.Tools.Lex.Codegen.main args
