/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.DSL.ImplCalculus — the §8 `impl` calculus
enforcer.

LX.8 of `docs/planning/lex_implementation_plan.md`.

Exports:

  * `inductive ImplStmt` — the §8.1 calculus' statement sort
    (`flow`, `mint`, `burn`, `reward`, `freeze_resource`,
    `register_key`, `register_identity`, `for`, `if`, `let`, the
    bare-term escape hatch).
  * `inductive EffectKind` — kernel-impl / authority / host
    classification per §8.2.
  * `parseImplCalculus : Lean.Syntax → List ImplStmt` — a
    *conservative* shape-classifier (cf. `parsePreExpr` in
    `LexPreGrammar.lean`).  Falls back to `bareTerm` for shapes
    outside the §8.1 calculus.
  * `@[lex_impl]` attribute (`Lean.TagAttribute`) for tagging
    user-defined helper functions admissible inside `lex_impl`
    blocks.
  * `isLexImplTagged` predicate consumed by the walker.

# Forbidden shapes (§8.5)

The walker classifies each statement's shape; the macro layer
emits diagnostics:

| Shape                                     | Diagnostic |
|-------------------------------------------|------------|
| Bare `setBalance` call                    | L010       |
| `revoke_key` invocation                   | L022       |
| Helper not tagged `@[lex_impl]`           | L023       |
| `for x in <iter>:` where iter ≠ List      | L019       |

This module is **non-TCB**.
-/

import Lean.Elab.Command
import Lean.Elab.Term
import Lean.Attributes

namespace LegalKernel.DSL.Lex

open Lean

/-! ## AST types (§8.1) -/

/-- Per-statement effect classification (§8.2).  Used by the
    macro to route a statement to either the kernel-impl chain
    (state → state) or the authority-layer chain (registry →
    registry). -/
inductive EffectKind where
  /-- Kernel-impl effect (`flow`, `mint`, `burn`, `reward`,
      `freeze_resource`, bare term).  Flows through
      `Transition.apply_impl`. -/
  | kernelImpl
  /-- Authority-layer effect (`register_key`,
      `register_identity`).  Flows through
      `applyActionToRegistry`. -/
  | authority
  /-- Host primitive (`for`, `if`, `let`).  The body's effect
      kind propagates through. -/
  | host
  deriving Repr, DecidableEq, Inhabited

/-- The §8.1 calculus' statement sort.  M1 captures parameters
    as surface-text snippets; the synthesizer library
    (`LexProperty.lean`) inspects the kind tag for dispatch and
    the synthesizer authors are responsible for parsing the
    surface text into the typed form. -/
inductive ImplStmt where
  /-- `flow r amt from a to b` — the post-debit re-read pattern. -/
  | flow (r : String) (amt : String) (from_ : String) (to_ : String) : ImplStmt
  /-- `mint r amt to b` — additive supply increase. -/
  | mint (r : String) (amt : String) (to_ : String) : ImplStmt
  /-- `burn r amt from a` — Nat-truncated supply decrease. -/
  | burn (r : String) (amt : String) (from_ : String) : ImplStmt
  /-- `reward r amt to b`. -/
  | reward (r : String) (amt : String) (to_ : String) : ImplStmt
  /-- `freeze_resource r` — kernel-level identity. -/
  | freezeResource (r : String) : ImplStmt
  /-- `register_key a as k`. -/
  | registerKey (actor : String) (key : String) : ImplStmt
  /-- `register_identity a as k`. -/
  | registerIdentity (actor : String) (key : String) : ImplStmt
  /-- `for x in <list>: <body>` — bounded iteration. -/
  | forLoop (binder : String) (iter : String) (body : List ImplStmt) : ImplStmt
  /-- `if <pre> then <s₁> else <s₂>` — conditional. -/
  | ifStmt (cond : String) (thenStmts : List ImplStmt) (elseStmts : List ImplStmt) : ImplStmt
  /-- `let x := e` — local binding. -/
  | letBind (name : String) (expr : String) : ImplStmt
  /-- A bare-term escape hatch (`fun s => ...`).  v1 only;
      removed in v2. -/
  | bareTerm (text : String) : ImplStmt
  /-- Forbidden: `revoke_key` invocation (L022).  The kernel
      doesn't yet ship `Action.revokeKey`; v3. -/
  | revokeKey (actor : String) : ImplStmt
  /-- Forbidden: bare `setBalance` call (L010).  Indicates a
      raw kernel-level mutation that bypasses the calculus
      primitives. -/
  | bareSetBalance (text : String) : ImplStmt
  deriving Repr, Inhabited

/-- Classify a statement by effect kind. -/
def ImplStmt.effectKind : ImplStmt → EffectKind
  | .flow _ _ _ _              => .kernelImpl
  | .mint _ _ _                => .kernelImpl
  | .burn _ _ _                => .kernelImpl
  | .reward _ _ _              => .kernelImpl
  | .freezeResource _          => .kernelImpl
  | .registerKey _ _           => .authority
  | .registerIdentity _ _      => .authority
  | .forLoop _ _ _             => .host
  | .ifStmt _ _ _              => .host
  | .letBind _ _               => .host
  | .bareTerm _                => .kernelImpl
  | .revokeKey _               => .authority
  | .bareSetBalance _          => .kernelImpl

/-- True iff a statement is forbidden by §8.5 (fires a hard L-code
    diagnostic). -/
def ImplStmt.isForbidden : ImplStmt → Bool
  | .revokeKey _               => true   -- L022
  | .bareSetBalance _          => true   -- L010
  | _                          => false

/-- Return the L-code that an `isForbidden` statement triggers.
    `none` for non-forbidden statements. -/
def ImplStmt.forbiddenCode : ImplStmt → Option String
  | .revokeKey _               => some "L022"
  | .bareSetBalance _          => some "L010"
  | _                          => none

/-! ## `@[lex_impl]` attribute (§8.6)

Helper functions called from `lex_impl` blocks are tagged with
`@[lex_impl]`.  Unlike `@[lex_pre]`, no decidability requirement
is imposed at attach time. -/

/-- The `@[lex_impl]` tag attribute.  Tagged helper functions
    are admissible inside Lex `lex_impl` blocks.  Unlike
    `@[lex_pre]`, no decidability requirement is imposed. -/
initialize lexImplAttr : Lean.TagAttribute ←
  Lean.registerTagAttribute `lex_impl
    "Marks a helper function as admissible inside a Lex `lex_impl` block.  No decidability requirement."

/-- True iff the function `n` is tagged `@[lex_impl]`. -/
def isLexImplTagged (env : Lean.Environment) (n : Lean.Name) : Bool :=
  lexImplAttr.hasTag env n

/-! ## L-code diagnostic helpers -/

/-- Format an L010 message ("bare `setBalance` call"). -/
def L010Message (text : String) : String :=
  s!"L010: bare `setBalance` call (`{text}`) in `lex_impl`; use `flow` / `mint` / `burn` / `reward` instead"

/-- Format an L019 message ("for-iter is not a List"). -/
def L019Message (iter : String) : String :=
  s!"L019: `for` loop's iterator (`{iter}`) is not statically a `List α`; convert via `.toList` or use a different bounded iterator"

/-- Format an L022 message ("`revoke_key` not yet supported"). -/
def L022Message (actor : String) : String :=
  s!"L022: `revoke_key {actor}` is not yet supported (the kernel does not ship an `Action.revokeKey` constructor; deferred to v3)"

/-- Format an L023 message ("untagged `lex_impl` helper"). -/
def L023Message (name : String) : String :=
  s!"L023: helper `{name}` is called from `lex_impl` but is not tagged `@[lex_impl]`; tag it or inline its body"

/-! ## Walker (§8 / LX.8)

A line-and-token-based parser that classifies the surface text of
the `lex_impl` clause.  Operates on the *captured surface text*
the macro stores in `LawDecl.implBlock`, not on `Lean.Syntax`
directly.  This trades term-level precision for stability: a
Lean toolchain bump that renames internal `Syntax` node kinds
won't break our walker, and the synthesizer library has a
predictable input shape.

The walker recognises:

  * `flow r amt from a to b`
  * `mint r amt to b`
  * `burn r amt from a`
  * `reward r amt to b`
  * `freeze_resource r`
  * `register_key a as k`
  * `register_identity a as k`
  * `revoke_key a`        — forbidden; classified as `revokeKey`
  * `setBalance ...`      — forbidden; classified as `bareSetBalance`
  * `for x in <iter>: <body>`
  * `if <pre> then <s₁> else <s₂>`
  * `let x := e`
  * Anything else        — `bareTerm`

Statements are separated by `;` (semicolons) or newlines inside
a `do`-style block.  Leading/trailing whitespace and `do` /
`fun s =>` / surrounding braces are stripped before tokenising. -/

/-- Strip a leading `do` / `fun s =>` / `(`/`)` from the impl
    block text.  Best-effort cleanup so the rest of the parser
    sees a flat statement list. -/
private def stripImplWrappers (s : String) : String :=
  let trimmed := s.trimAscii.toString
  let dropDo :=
    if trimmed.startsWith "do" then
      (trimmed.drop 2).trimAscii.toString
    else trimmed
  let dropFun :=
    if dropDo.startsWith "fun" then
      -- Drop everything up to and including the first `=>`.
      match (dropDo.splitOn "=>").tail? with
      | some (rest :: _) => rest.trimAscii.toString
      | _ => dropDo
    else dropDo
  dropFun

/-- Tokenise a stmt-block text into per-statement strings,
    splitting on `;` and balanced newlines.  M1 keeps it simple:
    split on `;` and on newline boundaries, drop empty
    fragments. -/
private def tokeniseStmts (s : String) : List String :=
  let lines := s.replace ";" "\n" |>.splitOn "\n"
  lines.filterMap (fun l =>
    let t := l.trimAscii.toString
    if t.isEmpty then none else some t)

/-- Token-match: does `stmt` start with the given keyword
    (case-sensitive, whitespace-bounded)?  Used to dispatch on
    the §8.1 primitives. -/
private def startsWithKeyword (stmt : String) (kw : String) : Bool :=
  stmt.startsWith (kw ++ " ") || stmt == kw

/-- Strip a leading keyword and any whitespace that follows it,
    returning the trimmed remainder (the "argument list" the
    statement carries after the keyword).  E.g.,
    `"revoke_key alice"` ↦ `"alice"`,
    `"revoke_key "` ↦ `""` (no actor named).

    Used by `parseImplStmt` to extract the per-statement payload
    (e.g. the actor name in `revoke_key`) from the raw textual
    statement, so per-keyword diagnostics show only the relevant
    sub-text rather than the full leading keyword. -/
private def stripKeyword (stmt : String) (kw : String) : String :=
  if stmt.startsWith (kw ++ " ") then
    (stmt.drop (kw.length + 1)).trimAscii.toString
  else if stmt == kw then ""
  else stmt

/-- Take the first whitespace-bounded token from `s`, or `s`
    itself if there's no internal whitespace.  Used to extract
    e.g. the actor name from `"alice ..."`.

    Audit-4: handles `\r` (carriage return) too, so a CRLF-line-
    ending source file's parsed statement doesn't leak `\r` into
    the actor name on Windows-checked-out repos. -/
private def firstToken (s : String) : String :=
  let chars := s.toList.takeWhile (fun c =>
    c != ' ' && c != '\t' && c != '\n' && c != '\r')
  String.ofList chars

/-- Parse a single statement string into an `ImplStmt`.  Falls
    back to `.bareTerm` on shapes outside the §8.1 calculus. -/
def parseImplStmt (stmt : String) : ImplStmt :=
  let s := stmt.trimAscii.toString
  if startsWithKeyword s "flow" then
    .flow s "" "" ""  -- M1: capture the raw text; field-level parsing in M2
  else if startsWithKeyword s "mint" then
    .mint s "" ""
  else if startsWithKeyword s "burn" then
    .burn s "" ""
  else if startsWithKeyword s "reward" then
    .reward s "" ""
  else if startsWithKeyword s "freeze_resource" then
    .freezeResource s
  else if startsWithKeyword s "register_key" then
    .registerKey s ""
  else if startsWithKeyword s "register_identity" then
    .registerIdentity s ""
  else if startsWithKeyword s "revoke_key" then
    -- Audit-2 fix: extract the actor name from the statement
    -- text; the pre-fix code passed the full statement
    -- (`"revoke_key alice"`) as the actor parameter, producing
    -- malformed L022 messages like `"revoke_key revoke_key alice"`.
    .revokeKey (firstToken (stripKeyword s "revoke_key"))
  else if s.startsWith "setBalance" then
    .bareSetBalance s
  else if startsWithKeyword s "for" then
    -- Naive: treat the entire `for x in <iter>: <body>` as a
    -- single bareTerm.  M2 refines.
    .forLoop "" "" [.bareTerm s]
  else if startsWithKeyword s "if" then
    .ifStmt s [] []
  else if startsWithKeyword s "let" then
    .letBind s ""
  else
    .bareTerm s

/-- Top-level walker: parses the full impl-block text into a
    list of `ImplStmt`s. -/
def parseImplCalculus (text : String) : List ImplStmt :=
  let stripped := stripImplWrappers text
  let tokens := tokeniseStmts stripped
  tokens.map parseImplStmt

/-! ## Helpers for synthesizers + tests -/

/-- Project a list of `ImplStmt`s onto their `EffectKind` tags. -/
def ImplStmt.effectKindList (stmts : List ImplStmt) : List EffectKind :=
  stmts.map (·.effectKind)

/-- True iff a list of statements contains any forbidden shape. -/
def ImplStmt.containsForbidden (stmts : List ImplStmt) : Bool :=
  stmts.any (·.isForbidden)

/-- Return all forbidden statements with their L-codes (used by
    the macro to emit diagnostics in batch). -/
def ImplStmt.forbiddenWithCodes (stmts : List ImplStmt) :
    List (String × ImplStmt) :=
  stmts.filterMap (fun stmt =>
    match stmt.forbiddenCode with
    | some code => some (code, stmt)
    | none      => none)

end LegalKernel.DSL.Lex
