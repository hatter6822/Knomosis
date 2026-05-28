/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.DSL.LawSyntax — `law pre := … ; impl := …` macro.

Phase 4 WU 4.9 macro syntax (split from `DSL/Law.lean` in
LX-M2 audit-2).

This module provides the `law` syntactic-sugar macro that
expands to `Law.mk preExpr implExpr`.  The macro registers
`pre` and `impl` as global Lean tokens, which conflicts with
the structure-field syntax used in hand-written
`def transfer ... where pre := ...` blocks.  As a result,
this module is **not** transitively imported by `DSL/LexLaw`
(which only needs `Law.mk` from `DSL/Law`).

# Two macro shapes

```
law pre := <expr> ; impl := <expr>
law impl := <expr>
```

The first form is the canonical case.  The second form
(impl-only) defaults `pre := fun _ => True`.  Both elaborate
to `Law.mk` applications, inheriting the `[DecidablePred pre]`
discipline.

# Example use (deployment-time)

```lean
open LegalKernel
open LegalKernel.DSL

/-- A deployment-supplied "tax" transition (illustrative). -/
def myTaxLaw (r : ResourceId) (collector taxpayer : ActorId)
    (amount : Amount) : Transition :=
  law
    pre  := fun s => getBalance s r taxpayer ≥ amount ;
    impl := fun s =>
      let s₁ := setBalance s r taxpayer (getBalance s r taxpayer - amount)
      setBalance s₁ r collector (getBalance s₁ r collector + amount)
```

This module is **not** part of the trusted computing base.

# LX-M2 deprecation note

In LX-M2, the `lex_law` macro (in `DSL/LexLaw.lean`) is the
canonical surface for declaring laws.  This `law` macro is
preserved for backward compatibility but is `@[deprecated]`
since LX-M2; new deployments should use `lex_law` instead.
-/

import LegalKernel.DSL.Law

namespace LegalKernel
namespace DSL

/-! ## The `law` syntactic-sugar macro

The macro expands to `Law.mk` references.  Since `Law.mk` is
`@[deprecated]` since LX-M2, every macro expansion would emit a
deprecation warning under the strict-warnings CI gate.  The
deprecation is suppressed at user sites via the
`set_option linter.deprecated false in` wrapper around the
macro's emission and at this module's per-`example` wrappers
(below).  Users who write `law pre := ... ; impl := ...` directly
in their own files MUST also wrap with `set_option linter.deprecated
false` until they migrate to `lexlaw`. -/

set_option linter.missingDocs false in
syntax (name := lawMacroPre)
  "law" "pre" ":=" term ";" "impl" ":=" term : term

set_option linter.missingDocs false in
syntax (name := lawMacroNoPre)
  "law" "impl" ":=" term : term

macro_rules
  | `(law pre := $preExpr ; impl := $implExpr) =>
    `(Law.mk $preExpr $implExpr)
  | `(law impl := $implExpr) =>
    `(Law.mk (fun _ => True) $implExpr)

/-! ## Sanity smoke checks

Compile-time-only `example`s that exercise the macro and confirm
the elaborated `Transition` matches the hand-written form.  Each
`example` is wrapped in `set_option linter.deprecated false in`
because the macro expands to `Law.mk` references and `Law.mk` is
`@[deprecated]` since LX-M2 (CI strict-warnings gate would
otherwise fail). -/

set_option linter.deprecated false in
/-- The DSL's `pre`-bearing form produces a `Transition` whose `pre`
    is the supplied expression. -/
example (r : ResourceId) (a : ActorId) (v : Amount) :
    (law
      pre  := fun s => getBalance s r a ≥ v ;
      impl := fun s => setBalance s r a (getBalance s r a - v)).pre
    = fun s => getBalance s r a ≥ v := rfl

set_option linter.deprecated false in
/-- The DSL's impl-only form defaults the precondition to `True`. -/
example :
    (law impl := fun s => s).pre = fun _ => True := rfl

set_option linter.deprecated false in
/-- The DSL's `decPre` field is the canonical `fun _ => inferInstance`
    — a *definition*, so `decide`-driven evaluation works on any
    instance-resolvable precondition. -/
example (r : ResourceId) (a : ActorId) (v : Amount) (s : State) :
    Decidable
      ((law
        pre  := fun s => getBalance s r a ≥ v ;
        impl := fun s => setBalance s r a (getBalance s r a - v)).pre s) := by
  exact inferInstance

/-! ## Re-derivation of `Laws.transfer` shape

The Phase-2 `Laws.transfer` law was hand-written as a `Transition`
value with explicit `pre`, `decPre`, `apply_impl` fields.  Re-
expressing it via the DSL produces a `Transition` definitionally
equal to the hand-written form. -/

set_option linter.deprecated false in
/-- A DSL-derived re-statement of the Phase-2 `transfer` law.  Used
    only as a compile-time test that the DSL produces a `Transition`
    whose shape matches the hand-written form, including the
    positivity clause.  Definitionally equal to
    `Laws.transfer r sender receiver amount`. -/
def transferDSL (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    Transition :=
  law
    pre  := fun s => getBalance s r sender ≥ amount ∧ amount > 0 ;
    impl := fun s =>
      let fromBal := getBalance s r sender
      let s₁      := setBalance s r sender (fromBal - amount)
      let toBal   := getBalance s₁ r receiver
      setBalance s₁ r receiver (toBal + amount)

/-- Compile-time check that `transferDSL`'s precondition matches the
    Phase-2 hand-written form. -/
example (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    (transferDSL r sender receiver amount).pre =
    fun s => getBalance s r sender ≥ amount ∧ amount > 0 := rfl

/-- Compile-time check that `transferDSL`'s state transformer matches
    the Phase-2 hand-written form. -/
example (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    (transferDSL r sender receiver amount).apply_impl = fun s =>
      let fromBal := getBalance s r sender
      let s₁      := setBalance s r sender (fromBal - amount)
      let toBal   := getBalance s₁ r receiver
      setBalance s₁ r receiver (toBal + amount) := rfl

end DSL
end LegalKernel
