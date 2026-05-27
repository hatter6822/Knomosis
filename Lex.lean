/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Lex — umbrella module for the Lex programming language.

Re-exports the runtime-relevant Lex DSL surface (the `lex_law`,
`lex_deployment`, and `lex_property` macros plus their supporting
infrastructure) so downstream consumers can `import Lex` once
instead of enumerating every `Lex.DSL.*` submodule.

The umbrella deliberately omits `Lex.DSL.ImplLowering` because
that module registers `to`, `from`, `as`, `amt`, `nop` as global
Lean tokens (the §6.2 calculus keywords).  Files that consume
the calculus-form `lex_do <stmt>` import `Lex.DSL.ImplLowering`
explicitly; everywhere else (test suites, hand-written law files
using common `(to : ActorId)` parameters) is unaffected.

The Lex audit binaries (`lex_lint`, `lex_codegen`, `lex_diff`,
`lex_format`) live in `Lex.Tools.*` and have their own `lean_lib`
declarations in `lakefile.lean`; they are NOT re-exported here
because consumers of the macro surface should not pay the
import cost of the tool libraries.

See `docs/planning/lex_implementation_plan.md` for the full Lex
implementation plan and `docs/law_language_design.md` for the
language design rationale.
-/

import Lex.DSL.PreGrammar
import Lex.DSL.ImplCalculus
import Lex.DSL.Events
import Lex.DSL.Shim
import Lex.DSL.Law
import Lex.DSL.Property
import Lex.DSL.Deployment
