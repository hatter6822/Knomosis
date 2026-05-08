/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LexCodegen — entry-point wrapper for the `lex_codegen` Lake
executable.

Mirrors the `Main.lean` / `canon`, `Replay.lean` /
`canon-replay`, and `LexLint.lean` / `lex_lint` pattern: a thin
top-level `def main` that delegates to the namespaced library
function in `Tools/LexCodegen.lean`.

Splitting the entry-point glue from the library code lets tests
(`LegalKernel/Test/Tools/LexCodegen.lean`) import the helpers
without colliding on top-level `def main` declarations across
multiple audit binaries.
-/

import Tools.LexCodegen

/-- The `lex_codegen` Lake executable's `main` function.
    Delegates to `LegalKernel.Tools.Lex.Codegen.main`. -/
def main (args : List String) : IO UInt32 :=
  LegalKernel.Tools.Lex.Codegen.main args
