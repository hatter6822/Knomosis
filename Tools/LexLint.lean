/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Tools.LexLint — the Lex audit binary.

LX.5 (`docs/lex_implementation_plan.md` §13).

Walks the codegen-input directory and the action-index registry,
parses each, and emits diagnostics for §13.1 rule violations.
This is a *fast-fail* surface: it runs in seconds and catches the
mechanical inconsistencies (registry well-formedness, codegen-
input vs registry consistency) before `lake build` invokes Lean's
elaborator.

Exit codes (§13.3):
  * `0` — every rule passes.
  * `1` — at least one rule fails.  Diagnostics printed to stdout
    in the canonical `<file>:<line>:<col>: error: L<NNN>: …` format.
  * `2` — internal binary failure (cannot read a file).

Initial check set (LX.5):
  1. Registry parses and validates against §13.1 rules 1–5 + 7.
  2. Each `LegalKernel/_lex_inputs/<id>.json` parses successfully.
  3. Every codegen-input file's declared `action_index` matches the
     registry's entry for that identifier (rule 6 / L007).

The macro-level checks (L001 / L002 / L003 / L004 / L009 / L010 /
L011 / L022 / L023 / L024 / L025) are enforced by the per-file
elaborator (`LegalKernel.DSL.LexLaw`) and `lex_codegen --check`.
This lint binary catches the `(registry, codegen-input)`
synchronization rules that don't have a Lean-elaboration
counterpart.
-/

import Tools.LexCommon

namespace LegalKernel.Tools.Lex

open System (FilePath)

/-! ## Diagnostic emission helpers (lint binary)

The lint binary's diagnostic surface differs slightly from the
macro's: lint diagnostics are file-level (no line/col known at
this layer for some checks; we use line 1 col 0 as a placeholder
when registry-level checks fire). -/

/-- A registry-level diagnostic (no per-clause source position). -/
def registryDiagnostic (code : String) (msg : String)
    (lineNum : Nat) (severity : Severity := .error)
    (hints : List String := []) : Diagnostic :=
  { code,
    severity,
    source := { fileName := registryPath.toString,
                startPos := { line := lineNum, column := 0 } },
    message := msg,
    notes := [],
    hints }

/-- A codegen-input file diagnostic. -/
def codegenInputDiagnostic (path : String) (code : String) (msg : String)
    (severity : Severity := .error)
    (hints : List String := []) : Diagnostic :=
  { code,
    severity,
    source := { fileName := path, startPos := { line := 1, column := 0 } },
    message := msg,
    notes := [],
    hints }

/-! ## Lint-pass implementations -/

/-- Read the registry file and validate it against the §13.1 rules.
    Returns the parsed entries plus any diagnostics encountered.
    On successful parse + validation, the diagnostics list is
    empty. -/
def lintRegistry (path : FilePath := registryPath) :
    IO (Except String (List RegistryEntry × List Diagnostic)) := do
  let exists? ← path.pathExists
  if !exists? then
    return .error s!"registry file not found: {path.toString}"
  let contents ← IO.FS.readFile path
  match parseRegistry contents with
  | .error msgs =>
    -- Each parser-level error is a generic L007 (file-level
    -- violation; line number is embedded in the message via the
    -- parser's `line N: ...` prefix).
    let diags := msgs.map (fun m =>
      registryDiagnostic "L007" m 0
        (hints := ["check the file's syntax against `docs/lex_implementation_plan.md` §4.1"]))
    return .ok ([], diags)
  | .ok entries =>
    let violations := validateRegistry entries
    let diags := violations.map (fun v =>
      registryDiagnostic v.code v.message v.line
        (hints := ["see `docs/lex_implementation_plan.md` §13.1 for the full rule set"]))
    return .ok (entries, diags)

/-- Read every JSON file under `LegalKernel/_lex_inputs/` and check
    each parses to a `LawDecl`.  Returns the parsed declarations
    plus any per-file diagnostics. -/
def lintCodegenInputs (dir : FilePath := codegenInputsDir) :
    IO (List LawDecl × List Diagnostic) := do
  if !(← dir.pathExists) then
    -- Empty input set: no codegen-input files.  This is the
    -- pre-LX.21 state.  Not an error.
    return ([], [])
  let entries ← dir.readDir
  let mut decls : List LawDecl := []
  let mut diags : List Diagnostic := []
  for entry in entries do
    let path := entry.path
    if path.extension == some "json" then
      let contents ← IO.FS.readFile path
      match LawDecl.fromJson contents with
      | .ok decl => decls := decls ++ [decl]
      | .error msg =>
        diags := diags ++ [codegenInputDiagnostic path.toString "L007"
          s!"failed to parse codegen-input JSON: {msg}"
          (hints := ["regenerate with `lake build` (Pass 1 macro emits canonical JSON)"])]
  return (decls, diags)

/-- Cross-check: every codegen-input file's `(identifier,
    actionIndex)` pair matches an entry in the registry.  Flags
    L007 (renumbered / divergent) when they don't. -/
def lintCodegenAgainstRegistry
    (decls : List LawDecl) (entries : List RegistryEntry) :
    List Diagnostic := Id.run do
  let mut diags : List Diagnostic := []
  for d in decls do
    match entries.find? (fun e => e.identifier == d.identifier) with
    | none =>
      diags := diags ++ [codegenInputDiagnostic
        (codegenInputPath d.identifier).toString "L007"
        s!"identifier `{d.identifier}` is not registered in `{registryPath.toString}`"
        (hints := [s!"append `{d.identifier}  {d.actionIndex}  v<release>` to the registry"])]
    | some entry =>
      if entry.actionIndex != d.actionIndex then
        diags := diags ++ [codegenInputDiagnostic
          (codegenInputPath d.identifier).toString "L007"
          s!"action_index for `{d.identifier}` is {d.actionIndex} in codegen-input but {entry.actionIndex} in registry"
          (hints := ["restore the original index; renumbering is forbidden (§13.1 rule 1)"])]
  pure diags

/-! ## Main entry point -/

/-- Print a single diagnostic to stdout in the canonical format. -/
def printDiagnostic (d : Diagnostic) : IO Unit :=
  IO.print d.format

/-- Print the lint binary's startup banner.  Mirrors the
    other audit binaries' style (`tcb_audit`, `count_sorries`,
    `stub_audit`). -/
def printBanner : IO Unit := do
  IO.println "lex_lint — Workstream LX (LX.5) audit binary"
  IO.println s!"  registry:        {registryPath.toString}"
  IO.println s!"  codegen-inputs:  {codegenInputsDir.toString}"

/-- Main entry.  Parses arguments (currently none accepted),
    runs the lint passes, prints diagnostics, returns:

      0 — every check passed;
      1 — at least one check failed (printed diagnostic);
      2 — internal failure. -/
def main (_args : List String) : IO UInt32 := do
  printBanner
  match (← lintRegistry) with
  | .error msg =>
    IO.eprintln s!"lex_lint: internal error: {msg}"
    return 2
  | .ok (entries, regDiags) =>
    let mut totalDiags : List Diagnostic := regDiags
    -- Codegen-input pass.
    let (decls, ciDiags) ← lintCodegenInputs
    totalDiags := totalDiags ++ ciDiags
    -- Cross-check pass.
    let crossDiags := lintCodegenAgainstRegistry decls entries
    totalDiags := totalDiags ++ crossDiags
    -- Print diagnostics in encountered order.
    for d in totalDiags do
      printDiagnostic d
    if totalDiags.any (fun d => d.severity = .error) then
      IO.println s!"lex_lint: {totalDiags.length} diagnostic(s); FAILED"
      return 1
    else
      IO.println s!"lex_lint: registry has {entries.length} entries; \
                    {decls.length} codegen-input files; OK"
      return 0

end LegalKernel.Tools.Lex

-- Entry-point glue for the `lex_lint` Lake executable lives in
-- the project-root `LexLint.lean` file (mirrors the
-- `Main.lean`/`canon` pattern).  Keeping `def main` out of this
-- module lets tests import the helpers as a library without
-- clashing with `Tools.LexCodegen`'s entry-point glue.
