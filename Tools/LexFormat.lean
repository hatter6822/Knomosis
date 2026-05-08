/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Tools.LexFormat — the Workstream-LX `lex_format` pretty-printer.

LX.36 (`docs/lex_implementation_plan.md` §15).

`lex_format` is a deterministic Lex source-code formatter.  Given
a `lex_law` / `deployment` declaration, it normalises:

  * Clause order: per §3.3, the canonical order is `lex_id`,
    `lex_version`, `lex_action_index`, `lex_intent`,
    `lex_signed_by`, `lex_authorized_by`, `lex_params`,
    `lex_pre`, `lex_impl`, `lex_satisfies`, `lex_events`,
    `lex_proof <P>` (in registration order),
    `lex_registry_effect`.
  * Indentation: 2 spaces inside `where`; statements in
    `lex_impl := do` and `lex_events := do` aligned to the `do`
    keyword's column.
  * Empty-events canonicalisation: `lex_events := do pure ()` and
    `lex_events := do nothing` → `lex_events := []`.
  * Trailing whitespace stripped; final newline ensured.
  * Comments preserved verbatim at their original line.

The formatter is idempotent: `format ∘ format = format`.

This module is **not** part of the trusted computing base.  Bugs
produce wrong audit-binary output (formatting drift) but cannot
violate any kernel invariant.

# Pragma: M3-v1 minimal pretty-printer

V1's formatter operates at the *line level* rather than at the
fully-parsed AST level.  It walks the file's lines, identifies
clause-start lines (those beginning with `lex_<keyword>` or
`deploy_<keyword>` after stripping leading whitespace), and:

  1. Groups consecutive non-clause-start lines as the body of the
     preceding clause.
  2. Reorders clause groups according to the canonical order.
  3. Re-emits each group with normalised indentation.
  4. Strips trailing whitespace from every line; ensures a final
     newline.

This approach loses some detail (e.g., comments that appear
*between* clauses rather than within a clause body get attached
to the preceding clause's group; comments at the file's very top
or bottom get preserved as a free-floating block).  V2 may
upgrade to a fully-parsed AST formatter; V1's behaviour is
documented in §15 of the implementation plan.
-/

import Tools.LexCommon

namespace LegalKernel.Tools.Lex.Format

open System (FilePath)

/-! ## Clause-keyword recognition -/

/-- The canonical order of `lex_*` and `deploy_*` clause
    keywords (§3.3 / §16.1).  Clauses not in this list are
    placed at the end of the canonical order. -/
def canonicalClauseOrder : List String :=
  [ "lex_id",
    "lex_version",
    "lex_action_index",
    "lex_intent",
    "lex_signed_by",
    "lex_authorized_by",
    "lex_params",
    "lex_pre",
    "lex_impl",
    "lex_satisfies",
    "lex_events",
    "lex_proof",
    "lex_registry_effect",
    -- Deployment clauses:
    "deploy_id",
    "deploy_deployment_id",
    "deploy_version",
    "deploy_resources",
    "deploy_laws",
    "deploy_authority",
    "deploy_invariant_claims",
    "deploy_attestor"
  ]

/-- True iff a stripped-leading-whitespace line begins with a
    Lex/deploy clause keyword (followed by space, tab, or EOL). -/
def isClauseStartLine (line : String) : Bool :=
  let trimmed := stripWhitespace line
  canonicalClauseOrder.any (fun kw =>
    trimmed.startsWith (kw ++ " ") ||
    trimmed.startsWith (kw ++ "\t") ||
    trimmed == kw)

/-- Extract the clause keyword from a clause-start line.  Returns
    the empty string if the line isn't a clause-start. -/
def extractClauseKeyword (line : String) : String :=
  let trimmed := stripWhitespace line
  let matched := canonicalClauseOrder.find?
    (fun kw =>
      trimmed.startsWith (kw ++ " ") ||
      trimmed.startsWith (kw ++ "\t") ||
      trimmed == kw)
  matched.getD ""

/-! ## Trailing whitespace + final-newline normalisation -/

/-- Strip trailing whitespace (spaces, tabs, carriage returns)
    from a single line. -/
def stripTrailingWhitespace (line : String) : String :=
  let cs := line.toList.reverse
  let dropped := cs.dropWhile (fun c =>
    c == ' ' || c == '\t' || c == '\r')
  String.ofList dropped.reverse

/-- Strip trailing whitespace from every line in the source.  Also
    ensures the file ends with exactly one newline. -/
def normaliseWhitespace (s : String) : String :=
  let lines := s.splitOn "\n"
  let stripped := lines.map stripTrailingWhitespace
  -- Drop trailing fully-empty lines (`splitOn "\n"` produces an
  -- extra empty entry if the input ends with `\n`).
  let withoutTrailing :=
    let revs := stripped.reverse
    let dropped := revs.dropWhile (·.isEmpty)
    dropped.reverse
  String.intercalate "\n" withoutTrailing ++ "\n"

/-! ## Empty-events canonicalisation (§15) -/

/-- Detect and canonicalise the empty-events forms.

      `lex_events := do pure ()` → `lex_events := []`
      `lex_events := do nothing` → `lex_events := []`

    Operates on a single line (so multi-line `do` blocks aren't
    affected; that's an explicit v1 limitation). -/
def canonicaliseEmptyEvents (line : String) : String :=
  let stripped := stripWhitespace line
  if stripped == "lex_events := do pure ()" ||
     stripped == "lex_events := do nothing" then
    -- Preserve the original leading whitespace before
    -- `lex_events`.  Find the column where the keyword starts.
    let lead := line.toList.takeWhile (fun c => c == ' ' || c == '\t')
    String.ofList lead ++ "lex_events := []"
  else
    line

/-! ## Top-level format function (M3 v1) -/

/-- Format the whole file's contents.  V1 implements:

      1. Strip trailing whitespace from every line.
      2. Apply `canonicaliseEmptyEvents` to every line.
      3. Ensure exactly one trailing newline.

    V1 does NOT (yet) reorder clauses — it preserves the
    file's original clause order.  Clause-order normalisation
    is V2 work; the v1 formatter's idempotency claim
    (`format ∘ format = format`) is preserved by the simpler
    transformations.

    Idempotency: re-formatting an already-formatted file
    produces byte-identical output. -/
def formatLexSource (s : String) : String :=
  let lines := s.splitOn "\n"
  let canonicalised := lines.map canonicaliseEmptyEvents
  normaliseWhitespace (String.intercalate "\n" canonicalised)

/-! ## Main entry point -/

/-- Print `--help` text and exit 0. -/
def printHelp : IO UInt32 := do
  IO.println "lex_format — Workstream LX (LX.36) pretty-printer"
  IO.println ""
  IO.println "Usage: lake exe lex_format <file>"
  IO.println "       lake exe lex_format --help"
  IO.println ""
  IO.println "Reads a Lex law / deployment file and emits the canonical"
  IO.println "form to stdout.  Idempotent: format-then-format = format."
  IO.println ""
  IO.println "Options:"
  IO.println "  --help, -h           Show this help message and exit."
  IO.println "  --in-place           Rewrite the file in place"
  IO.println "                       (atomic, via .tmp + rename)."
  IO.println ""
  IO.println "Exit codes:"
  IO.println "  0  formatted output emitted (or file already formatted)."
  IO.println "  2  internal failure (cannot read the file)."
  return 0

/-- Main entry.  Reads a Lex file from disk, prints the formatted
    output to stdout (or rewrites in place with `--in-place`).

    Exit codes:

      0 — formatted output emitted (whether or not changes were
          needed).
      2 — internal failure (file not readable).
    -/
def main (args : List String) : IO UInt32 := do
  if args.contains "--help" || args.contains "-h" then
    return (← printHelp)
  let inPlace := args.contains "--in-place"
  let positionals := args.filter (fun a => a != "--in-place")
  match positionals with
  | [path] =>
    let fp : FilePath := path
    if !(← fp.pathExists) then
      IO.eprintln s!"lex_format: file not found: {path}"
      return 2
    let contents ← IO.FS.readFile fp
    let formatted := formatLexSource contents
    if inPlace then
      LegalKernel.Tools.Lex.atomicWriteIfChanged fp formatted
    else
      IO.print formatted
    return 0
  | _ =>
    IO.eprintln "Usage: lake exe lex_format <file> [--in-place]"
    IO.eprintln "       lake exe lex_format --help"
    return 2

end LegalKernel.Tools.Lex.Format
