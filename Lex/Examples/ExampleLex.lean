/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Examples.ExampleLex — the M1 acceptance Lex law.

LX.21 of `docs/planning/lex_implementation_plan.md`.

This file demonstrates the `lex_law` macro's full surface in M1
mode: it elaborates a single Lex law using the `lex_*` clause
keywords (cf. `Lex.DSL.Law` v1-deviation note), and
emits:

  * `def example_example_lex_only_law_transition : Transition`
  * `def example_example_lex_only_law_intent : String`
  * `def example_example_lex_only_law_action_index : Nat := 17`
  * `def example_example_lex_only_law_identifier : String`
  * `def example_example_lex_only_law_version : String`
  * a `Lex/Inputs/example_example_lex_only_law.json`
    file capturing the law's metadata for `lex_codegen` (Pass 2).

The example law is parameterless and kernel-impl-identity (the
`impl` returns the input state unchanged).  Its `pre` is `True`
on every state.  This minimal shape exercises every clause type
the M1 surface admits without depending on the full §6.1 calculus
(LX.7 / LX.8) or property synthesizer (LX.13 – LX.15), both of
which land in M1 incrementally — the full-surface example shifts
to M2 when those features are complete.

The codegen-input file at
`Lex/Inputs/example_example_lex_only_law.json`
demonstrates the deterministic JSON encoder; consult that file
for the schema-v1 byte layout. -/

import LegalKernel.Kernel
import Lex.DSL.Law

namespace Lex.Examples

open LegalKernel
open LegalKernel.DSL

-- A Lex-declared law inhabiting frozen index 17 (the next free
-- slot after the 17 kernel-built-in indices 0..16).  Its
-- kernel-impl is the identity transition; its precondition is
-- `True`.  The intent block records the deployment-policy reason
-- for the law's existence — in this illustrative case, simply
-- "M1 acceptance gate".
--
-- (We use a line-comment here because `/-- ... -/` docstring is
-- only attachable to recognised declaration kinds (`def`,
-- `theorem`, etc.); the Lex `lexlaw` command is a custom
-- elaborator and isn't in that list.  The `lex_intent` clause
-- below carries the human-readable narrative.)
lexlaw example_lex_only_law where
  lex_id              example.example_lex_only_law
  lex_version         "1.0.0"
  lex_action_index    17
  lex_intent          "M1 acceptance gate: a parameterless Lex-only law that exercises the full M1 macro surface."
  lex_signed_by       deployer
  lex_authorized_by   (fun _ _ => True)
  lex_pre             := fun (_ : LegalKernel.State) => True
  lex_impl            := fun (s : LegalKernel.State) => s
  lex_satisfies       := []
  lex_events          := []

/-! ## Regression `example`s (LX.21)

Confirm that the macro emitted the expected `Transition` def and
that the transition's structure matches the hand-coded form the
macro should produce.

The example uses the v1 macro's M1-mode emission: only the
transition def is emitted by the per-file Pass 1.  Convenience
metadata accessors (`<law>_intent`, `<law>_action_index`,
`<law>_identifier`, `<law>_version`) are deferred to Pass 2
(`lake exe lex_codegen`); the codegen-input JSON sidecar at
`Lex/Inputs/example_example_lex_only_law.json` is
the canonical record. -/

/-- The macro's transition has `True` precondition (every state is
    admissible).  Verified value-level. -/
example (s : LegalKernel.State) : example_example_lex_only_law_transition.pre s := by
  trivial

/-- The macro's transition has identity `apply_impl`.  Verified
    value-level on a particular state. -/
example (s : LegalKernel.State) :
    example_example_lex_only_law_transition.apply_impl s = s := rfl

end Lex.Examples
