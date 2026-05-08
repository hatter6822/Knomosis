/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LexLint — entry-point wrapper for the `lex_lint` Lake executable.

Mirrors the `Main.lean` / `canon` and `Replay.lean` /
`canon-replay` pattern: a thin top-level `def main` that
delegates to the namespaced library function in
`Tools/LexLint.lean`.

Splitting the entry-point glue from the library code lets tests
(`LegalKernel/Test/Tools/LexCommon.lean`) import the helpers
without colliding on top-level `def main` declarations across
multiple audit binaries.
-/

import Tools.LexLint

/-- The `lex_lint` Lake executable's `main` function.  Delegates
    to `LegalKernel.Tools.Lex.main`. -/
def main (args : List String) : IO UInt32 :=
  LegalKernel.Tools.Lex.main args
