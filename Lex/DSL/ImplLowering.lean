-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Lex.DSL.ImplLowering — §6.2 impl-calculus → Lean term
lowering.

LX-M2 implementation of plan §6.2 / §8.1 / §15.x.  Provides the
`lex_do` syntax that lowers a sequence of impl-calculus statements
into a `State → State` Lean term, threading state through the
sequence of mutations.

# Calculus statements supported (M2)

Each statement is a single-state-update operation.  Statements
are composed sequentially via `lex_do`, with the result of one
statement becoming the input state of the next.

  * `flow r amt from a to b`   — debit `a` by `amt` at `r`,
                                 then credit `b` by `amt` at `r`,
                                 reading `b`'s balance from the
                                 post-debit state (§4.11
                                 self-transfer-safe sequencing).
  * `mint r amt to b`          — credit `b` by `amt` at `r`.
  * `burn r amt from a`        — debit `a` by `amt` at `r`.
  * `reward r amt to b`        — credit `b` by `amt` at `r`
                                 (definitionally equal to `mint`
                                 at the kernel level; distinct at
                                 the action layer).
  * `freeze_resource r`        — kernel-level identity (§4.10).
  * `register_key _a _k`       — kernel-level identity (registry
                                 mutation lives in the authority
                                 layer).
  * `register_identity _a _k`  — kernel-level identity.
  * `nop`                      — kernel-level identity (no-op).

# Compositional semantics

`lex_do <stmts>` lowers to `fun s => <stmt_n> (... (<stmt_2>
(<stmt_1> s)))`, threading state from left to right through the
statement sequence.

A single statement `lex_do <stmt>` lowers to `fun s => <stmt> s`.

The empty body `lex_do nop` lowers to `fun s => s`.

# Compatibility with the current macro

The `lex_law` macro accepts both:
  * Lean-term `lex_impl := fun s => <body>` (the existing M1
    surface).
  * §6.2 calculus `lex_impl := lex_do <stmts>` (this module's
    surface).

Both produce definitionally-equivalent `State → State` terms.

# Mathematical soundness

The lowering is purely syntactic: each calculus statement maps to
a Lean term that captures the documented semantics.  The byte-
equivalence regression `example`s in each `Laws/<Law>.lean` file
verify that the lowered form equals the hand-written form.  No
new theorems are introduced; the existing kernel-level theorems
(`transfer_conserves`, etc.) continue to apply unchanged.

This module is **not** part of the trusted computing base.
-/

import LegalKernel.Kernel
import Lean.Elab.Term

namespace LegalKernel.DSL.Lex

open Lean

/-! ## Calculus-statement syntax category -/

set_option linter.missingDocs false in
/-- A `lex_calc_stmt` is a single impl-calculus statement.  The
    parser recognises the §6.2 primitives plus an `id` no-op. -/
declare_syntax_cat lex_calc_stmt

set_option linter.missingDocs false in
syntax (name := lexCalcFlow)
  "flow" term "amt" term "from" term "to" term : lex_calc_stmt

set_option linter.missingDocs false in
syntax (name := lexCalcMint)
  "mint" term "amt" term "to" term : lex_calc_stmt

set_option linter.missingDocs false in
syntax (name := lexCalcBurn)
  "burn" term "amt" term "from" term : lex_calc_stmt

set_option linter.missingDocs false in
syntax (name := lexCalcReward)
  "reward" term "amt" term "to" term : lex_calc_stmt

set_option linter.missingDocs false in
syntax (name := lexCalcFreezeResource)
  "freeze_resource" term : lex_calc_stmt

set_option linter.missingDocs false in
syntax (name := lexCalcRegisterKey)
  "register_key" term "as" term : lex_calc_stmt

set_option linter.missingDocs false in
syntax (name := lexCalcRegisterIdentity)
  "register_identity" term "as" term : lex_calc_stmt

set_option linter.missingDocs false in
syntax (name := lexCalcNop)
  "nop" : lex_calc_stmt

/-! ## `lex_do` — calculus block elaborator -/

set_option linter.missingDocs false in
/-- The `lex_do` block: parses a single `lex_calc_stmt` and
    lowers it to a `State → State` Lean term.

    M2 supports SINGLE-statement form only.  Multi-statement
    composition is achieved at the Lean term level via function
    composition (`fun s => stmt2 (stmt1 s)`) or by defining helpers
    with the desired sequence.  All 17 kernel-built-in laws fit in
    single-statement form (see `Laws/<Law>.lean`'s `lex_impl`
    bodies), so this restriction is non-binding for M2 acceptance.
    M3 (per `docs/planning/lex_implementation_plan.md` §19.5) introduces a
    multi-statement variant. -/
syntax (name := lexDoBlock) "lex_do" lex_calc_stmt : term

/-- Lower a single `lex_calc_stmt` to a Lean term of type
    `LegalKernel.State → LegalKernel.State`. -/
private partial def lowerStmt (stmt : Syntax) : MacroM Term :=
  match stmt with
  | `(lex_calc_stmt| flow $r:term amt $v:term from $a:term to $b:term) =>
    -- Self-transfer-safe sequencing (§4.11): read receiver's
    -- balance from the post-debit state.  Variable names match
    -- the hand-written `Laws.transfer.apply_impl` shape (`fromBal`,
    -- `s1`, `toBal`) so the lowered term is byte-equivalent.
    `(fun s =>
        let fromBal := LegalKernel.getBalance s $r $a
        let s1      := LegalKernel.setBalance s $r $a (fromBal - $v)
        let toBal   := LegalKernel.getBalance s1 $r $b
        LegalKernel.setBalance s1 $r $b (toBal + $v))
  | `(lex_calc_stmt| mint $r:term amt $v:term to $b:term) =>
    `(fun s => LegalKernel.setBalance s $r $b
        (LegalKernel.getBalance s $r $b + $v))
  | `(lex_calc_stmt| burn $r:term amt $v:term from $a:term) =>
    `(fun s => LegalKernel.setBalance s $r $a
        (LegalKernel.getBalance s $r $a - $v))
  | `(lex_calc_stmt| reward $r:term amt $v:term to $b:term) =>
    -- Definitionally equal to `mint` at the kernel level; the
    -- semantic distinction lives at the action layer.
    `(fun s => LegalKernel.setBalance s $r $b
        (LegalKernel.getBalance s $r $b + $v))
  | `(lex_calc_stmt| freeze_resource $r:term) =>
    -- Kernel-level identity.  The action-layer effect (deployment
    -- commitment to never mutate the resource) is a separate
    -- concern.  We bind `r` and discard it via `let _` so the
    -- pattern still elaborates the parameter.
    `(fun s => let _ := $r; s)
  | `(lex_calc_stmt| register_key $a:term as $k:term) =>
    -- Kernel-level identity.  Registry mutation is authority-
    -- layer (`applyActionToRegistry` in `apply_admissible`).
    `(fun s => let _ := $a; let _ := $k; s)
  | `(lex_calc_stmt| register_identity $a:term as $k:term) =>
    -- Kernel-level identity.  Registry insertion is authority-
    -- layer.
    `(fun s => let _ := $a; let _ := $k; s)
  | `(lex_calc_stmt| nop) =>
    `(fun s => s)
  | _ =>
    Macro.throwErrorAt stmt
      s!"lex_do: unrecognised calculus statement; admissible \
         primitives are `flow`, `mint`, `burn`, `reward`, \
         `freeze_resource`, `register_key`, `register_identity`, \
         `nop`."

-- Audit-6: removed the dead `composeStmts` helper that scaffolded
-- multi-statement composition.  M2's `lex_do` macro only handles
-- single-statement form (per the syntax declaration above); M3
-- will reintroduce composition once a multi-statement
-- `lex_calc_stmt+` syntax is added (see plan §19.5).  The dead
-- helper was `private partial def`, so Lean's unused-decl linter
-- could not catch it.

/-- The `lex_do` macro: lowers a single `lex_calc_stmt` to a
    `State → State` Lean term. -/
macro_rules
  | `(lex_do $stmt:lex_calc_stmt) => lowerStmt stmt.raw

end LegalKernel.DSL.Lex
