/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Lex.DSL.Events — the §11 `events` block elaborator.

LX.10 of `docs/planning/lex_implementation_plan.md`.

Exports:

  * `inductive EventStmt` — the §11.3 calculus' statement sort
    (`let`, `emit`, `ifEmit`, `for`).
  * `parseEventBlock : String → List EventStmt` — text-level
    walker, mirroring `parseImplCalculus`.
  * `@[lex_event_ctor]` attribute (`Lean.TagAttribute`) for
    tagging `Event`-constructor names admissible inside `emit`.
  * `isLexEventCtorTagged` predicate.
  * Diagnostic helpers for L013, L014, L020, L027.

The §11 events block desugars to a `List Event` value
threading through `(preState, postState : LegalKernel.State)`.
M1 captures the AST + diagnostics; the codegen pass (LX.19)
performs the actual desugaring at Pass 2.

This module is **non-TCB**.
-/

import Lean.Elab.Command
import Lean.Attributes

namespace LegalKernel.DSL.Lex

open Lean

/-! ## AST types (§11.3) -/

/-- The §11.3 events-calculus' statement sort. -/
inductive EventStmt where
  /-- `let x := e` — local binding (no event emission). -/
  | letBind (name : String) (expr : String) : EventStmt
  /-- `emit Event.<ctor> <args>` — append a single event. -/
  | emitOne (ctor : String) (args : List String) : EventStmt
  /-- `if <pred> then emit ... (else emit ...)?` — conditional
      emission. -/
  | ifEmit (cond : String) (thenStmts : List EventStmt) (elseStmts : List EventStmt) : EventStmt
  /-- `for x in <list>: <body>` — bounded fold-emit. -/
  | forEmit (binder : String) (iter : String) (body : List EventStmt) : EventStmt
  /-- A bare statement (catch-all for shapes outside the §11.3
      calculus; classified as `bareTerm`). -/
  | bareTerm (text : String) : EventStmt
  /-- An empty events block (`events := []` or `do pure ()`). -/
  | empty : EventStmt
  deriving Repr, Inhabited

/-! ## `@[lex_event_ctor]` attribute (§11.5)

`Event`-constructor names that are admissible inside `emit` are
tagged with `@[lex_event_ctor]`.  The 13 existing `Event`
constructors (post-LP) ARE conceptually tagged; M1 reads the
tags from the attribute table.

The plan §11.5 admits a `lex_format` canonicalisation of three
`events := ...` empty-form variants into the canonical
`events := []`; M1's parser accepts all three. -/

/-- The `@[lex_event_ctor]` tag attribute. -/
initialize lexEventCtorAttr : Lean.TagAttribute ←
  Lean.registerTagAttribute `lex_event_ctor
    "Marks an `Event` constructor as admissible inside a Lex `emit` clause."

/-- True iff the constructor `n` is tagged `@[lex_event_ctor]`. -/
def isLexEventCtorTagged (env : Lean.Environment) (n : Lean.Name) : Bool :=
  lexEventCtorAttr.hasTag env n

/-! ## L-code diagnostic helpers -/

/-- Format an L013 message ("events block omits / duplicates a
    touched cell"). -/
def L013Message (cell : String) : String :=
  s!"L013: `events` block does not match the `lex_impl` block's mutated cells: `{cell}`.  Align `events` with the cells `lex_impl` touches, or accept the auto-filter (zero-delta `balanceChanged` events are dropped)."

/-- Format an L014 message ("manual emission of auto-emitted
    event"). -/
def L014Message (ctor : String) : String :=
  s!"L014: manual `emit {ctor}` overlaps the auto-emitted event for `{ctor}`.  Remove the manual `emit`; the elaborator adds the canonical form via `extractEvents`."

/-- Format an L020 message ("emit of an untagged Event
    constructor"). -/
def L020EmitMessage (ctor : String) : String :=
  s!"L020: `emit {ctor}` references an `Event` constructor not tagged `@[lex_event_ctor]`.  Tag the constructor or use one of the 13 built-in constructors."

/-- Format an L027 message ("bare `s` reference inside `events
    := do …`"). -/
def L027Message : String :=
  "L027: bare `s` reference inside `events := do …`.  Use the explicit `preState` or `postState` name; `s` is ambiguous (the events block executes after the kernel-level transition has already produced `postState`)."

/-! ## Walker (§11 / LX.10)

A line-and-token-based parser, mirroring `parseImplCalculus`.
The empty-form variants `events := []`, `events := do pure ()`,
`events := do nothing` all produce an `[.empty]`. -/

/-- Strip a leading `do` from the events block text. -/
private def stripEventsWrappers (s : String) : String :=
  let trimmed := s.trimAscii.toString
  if trimmed.startsWith "do" then
    (trimmed.drop 2).trimAscii.toString
  else trimmed

/-- Tokenise an events-block text into per-statement strings.
    Same semicolon/newline split as the impl-calculus walker. -/
private def tokeniseEventStmts (s : String) : List String :=
  let lines := s.replace ";" "\n" |>.splitOn "\n"
  lines.filterMap (fun l =>
    let t := l.trimAscii.toString
    if t.isEmpty then none else some t)

/-- True iff a stmt-text starts with a given keyword. -/
private def startsWithKeyword (stmt : String) (kw : String) : Bool :=
  stmt.startsWith (kw ++ " ") || stmt == kw

/-- Parse a single events-block statement string.  M1 captures
    surface text per-statement; M2 refines into typed args. -/
def parseEventStmt (stmt : String) : EventStmt :=
  let s := stmt.trimAscii.toString
  if s.isEmpty || s == "pure ()" || s == "nothing" || s == "[]" then
    .empty
  else if startsWithKeyword s "let" then
    .letBind s ""
  else if startsWithKeyword s "emit" then
    -- `emit Event.<ctor> <args>` or `emit <ctor> <args>`.
    -- M1 captures the rest of the line as the (ctor + args)
    -- payload; M2 splits at the constructor / arg boundary.
    .emitOne s []
  else if startsWithKeyword s "if" then
    .ifEmit s [] []
  else if startsWithKeyword s "for" then
    .forEmit "" "" [.bareTerm s]
  else
    .bareTerm s

/-- Top-level walker: parse the full events-block text. -/
def parseEventBlock (text : String) : List EventStmt :=
  let stripped := stripEventsWrappers text
  -- Empty-form: `[]` after stripping is the canonical empty.
  if stripped == "[]" || stripped.isEmpty || stripped == "pure ()" || stripped == "nothing" then
    [.empty]
  else
    let tokens := tokeniseEventStmts stripped
    if tokens.isEmpty then [.empty]
    else tokens.map parseEventStmt

/-! ## Helpers -/

/-- True iff a list of `EventStmt`s is the canonical empty form. -/
def EventStmt.isEmptyBlock : List EventStmt → Bool
  | []         => true
  | [.empty]   => true
  | _          => false

/-- Extract the `emit` constructor names from a list of stmts.
    Used by the synthesizer / codegen layer to detect L014
    overlaps with auto-emitted events. -/
def EventStmt.emittedConstructors : List EventStmt → List String
  | []                       => []
  | (.emitOne ctor _) :: rest =>
    ctor :: EventStmt.emittedConstructors rest
  | (.ifEmit _ t e) :: rest  =>
    EventStmt.emittedConstructors t ++
    EventStmt.emittedConstructors e ++
    EventStmt.emittedConstructors rest
  | (.forEmit _ _ b) :: rest =>
    EventStmt.emittedConstructors b ++ EventStmt.emittedConstructors rest
  | _ :: rest                => EventStmt.emittedConstructors rest

end LegalKernel.DSL.Lex
