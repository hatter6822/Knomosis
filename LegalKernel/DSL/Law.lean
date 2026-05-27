/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.DSL.Law — `Law.mk` combinator (function-only).

Phase 4 WU 4.9.  Defines the `Law.mk` combinator that constructs
a `Transition` value with the canonical `decPre := fun _ =>
inferInstance` discipline (Genesis Plan §13.6 step 2)
automatically applied.

# LX-M2 audit-2 split

This file used to also declare a `law pre := … ; impl := …`
syntactic-sugar macro that registered `pre` and `impl` as global
Lean tokens.  Those tokens conflicted with the structure-field
syntax used in hand-written `def transfer ... where pre := ...`
blocks: any file that transitively imported the macro could no
longer parse `where pre := ...` because `pre` was tokenised as
a keyword rather than an identifier.

The fix splits this module: this file (`DSL/Law.lean`) now
contains ONLY the `Law.mk` function (no parser-keyword pollution).
The macro syntax has been moved to `DSL/LawSyntax.lean`.
Downstream modules import `DSL.Law` to use `Law.mk` without
activating the `pre`/`impl` tokens, and import `DSL.LawSyntax`
only when they want the `law pre := … ; impl := …` macro form.

This unblocks the LX-M2 in-place migration (Lex declarations
co-located with the hand-written law files, per plan §19.4).

# Original elaboration contract (preserved)

  * `Law.mk` produces a `Transition` value definitionally equal
    to the hand-written form
    (`Transition.mk pre (fun _ => inferInstance) impl`).
  * The `[DecidablePred pre]` instance argument enforces the
    decidability discipline: elaboration FAILS at the call site
    if the precondition is not `Decidable` via instance
    resolution.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Kernel

namespace LegalKernel
namespace DSL

/-! ## The `Law.mk` combinator -/

/-- The DSL's `Law.mk` combinator.  Takes a `pre` predicate and
    an `impl` transformer and constructs a `Transition` with the
    canonical `decPre := fun _ => inferInstance` discipline.

    The `[DecidablePred pre]` instance argument enforces the
    discipline: elaboration FAILS at the call site if the
    precondition is not `Decidable` via instance resolution.

    # LX-M2 deprecation note

    Marked `@[deprecated]` since LX-M2: the canonical surface
    for declaring laws is the `lexlaw` macro in `DSL/LexLaw.lean`
    (which expands internally to `Law.mk` references, with the
    deprecation suppressed at the macro emission site via a
    targeted `set_option`).  New deployments should use `lexlaw`
    instead of calling `Law.mk` directly.

    The `transferDSL` example in `DSL/LawSyntax.lean` is preserved
    as a regression test for `Law.mk` until v2; it carries a
    targeted `set_option linter.deprecated false` to suppress the
    deprecation warning in that specific test artefact. -/
@[deprecated "Use Lex's `lexlaw` macro instead.  `Law.mk` is preserved for backward compatibility but will be removed in v2.  See `Lex/DSL/Law.lean` for the canonical M2 surface." (since := "lex-m2-canonical")]
def Law.mk (pre : State → Prop) [DecidablePred pre]
    (impl : State → State) : Transition where
  pre        := pre
  decPre     := fun _ => inferInstance
  apply_impl := impl

end DSL
end LegalKernel
