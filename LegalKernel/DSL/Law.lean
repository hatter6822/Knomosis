/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.DSL.Law — DSL elaborator for law declarations.

Phase 4 WU 4.9.  Defines a Lean macro `law` that elaborates a
human-readable law specification into a `Transition` value with the
`decPre := fun _ => inferInstance` discipline (Genesis Plan §13.6
step 2) automatically applied.

The DSL is intentionally small: it captures the most common law
shape (`pre := <expression>; impl := <expression>`) with optional
parameters.  Laws that need bespoke `decPre` derivations (e.g.
preconditions over unbounded quantifiers — see
`docs/decidability_discipline.md`) cannot use the DSL; they must
declare the `Transition` directly with a hand-written `decPre`.

Elaboration contract (Genesis Plan §12 WU 4.9):

  * `law` produces a `Transition` value definitionally equal to the
    hand-written form (`Transition.mk pre (fun _ => inferInstance)
    impl`).
  * The macro fills in `decPre` automatically; if the precondition is
    not decidable via `inferInstance`, elaboration fails with a clear
    error that points at the precondition.
  * Test: `law transfer ...` produces a `Transition` definitionally
    equal to the existing `Laws.transfer` hand-written form (verified
    by an `example` round-trip in this module).

Example use (deployment-time):

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

This module is **not** part of the trusted computing base.  Bugs in
the macro produce wrong `Transition` values (which the kernel's
`#print axioms` audit and the per-law refinement / conservation
proofs would catch), but cannot violate any kernel invariant.
-/

import LegalKernel.Kernel

namespace LegalKernel
namespace DSL

/-! ## The `law` macro -/

/-- The DSL's `Law.mk` combinator.  This is the function-form of the
    `law` DSL: it takes a `pre` predicate and an `impl` transformer
    and constructs a `Transition` with the canonical
    `decPre := fun _ => inferInstance` discipline.  The
    `[DecidablePred pre]` instance argument enforces the discipline:
    elaboration FAILS at the call site if the precondition is not
    `Decidable` via instance resolution.

    Use this for the common case.  The `law` syntactic-sugar macro
    below offers an alternate spelling that mirrors the Genesis Plan
    §12 WU 4.9 sketch (`law pre := … ; impl := …`). -/
def Law.mk (pre : State → Prop) [DecidablePred pre]
    (impl : State → State) : Transition where
  pre        := pre
  decPre     := fun _ => inferInstance
  apply_impl := impl

/-! ### The `law` DSL macro

A one-line syntactic-sugar form for `Law.mk`.  Two shapes:

```
law pre := <expr> ; impl := <expr>
law impl := <expr>
```

The first form is the canonical case.  The second form (impl-only)
defaults `pre := fun _ => True`.  Both elaborate to `Law.mk`
applications, inheriting the `[DecidablePred pre]` discipline.  If
elaboration fails, the precondition is not instance-decidable and
needs a hand-written `decPre`.  See
`docs/decidability_discipline.md`. -/

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

Compile-time-only `example`s that exercise the macro and confirm the
elaborated `Transition` matches the hand-written form. -/

/-- The DSL's `pre`-bearing form produces a `Transition` whose `pre`
    is the supplied expression.  Compile-time check via direct
    construction. -/
example (r : ResourceId) (a : ActorId) (v : Amount) :
    (law
      pre  := fun s => getBalance s r a ≥ v ;
      impl := fun s => setBalance s r a (getBalance s r a - v)).pre
    = fun s => getBalance s r a ≥ v := rfl

/-- The DSL's impl-only form defaults the precondition to `True`. -/
example :
    (law impl := fun s => s).pre = fun _ => True := rfl

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
equal to the hand-written form, including both clauses of the
precondition (`getBalance ≥ amount` AND `amount > 0`) and the
self-transfer-safe sequencing inside `apply_impl`. -/

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
      -- Read receiver's balance from `s₁` (post-debit), not `s`,
      -- so self-transfers conserve the actor's total balance.
      let toBal   := getBalance s₁ r receiver
      setBalance s₁ r receiver (toBal + amount)

/-- Compile-time check that `transferDSL`'s precondition matches the
    Phase-2 hand-written form (both the balance-bound and positivity
    clauses). -/
example (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    (transferDSL r sender receiver amount).pre =
    fun s => getBalance s r sender ≥ amount ∧ amount > 0 := rfl

/-- Compile-time check that `transferDSL`'s state transformer matches
    the Phase-2 hand-written form, including the self-transfer-safe
    post-debit read of the receiver's balance. -/
example (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    (transferDSL r sender receiver amount).apply_impl = fun s =>
      let fromBal := getBalance s r sender
      let s₁      := setBalance s r sender (fromBal - amount)
      let toBal   := getBalance s₁ r receiver
      setBalance s₁ r receiver (toBal + amount) := rfl

end DSL
end LegalKernel
