/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Bin.Lint — entry-point wrapper for the `lex_lint` Lake
executable.

Mirrors the `Main.lean` / `knomosis` and `Replay.lean` /
`knomosis-replay` pattern: a thin top-level `def main` that
delegates to the namespaced library function in
`Lex/Tools/Lint.lean`.

Splitting the entry-point glue from the library code lets tests
(`Lex/Test/Tools/Common.lean`) import the helpers without
colliding on top-level `def main` declarations across multiple
audit binaries.
-/

import Lex.Tools.Lint

/-- The `lex_lint` Lake executable's `main` function.  Delegates
    to `LegalKernel.Tools.Lex.main`.  (The library namespace is
    `LegalKernel.Tools.Lex`, preserved across the LX directory
    refactor so existing `open` statements continue to resolve.) -/
def main (args : List String) : IO UInt32 :=
  LegalKernel.Tools.Lex.main args
