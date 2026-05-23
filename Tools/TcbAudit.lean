/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Tools.TcbAudit — Phase 1 WU 1.11.

Enumerates the *direct imports* of the trusted-core modules
(`LegalKernel.Kernel`, `LegalKernel.RBMapLemmas`) and compares
each against an allowlist at `tcb_allowlist.txt` in the project root.
A non-empty intersection of "imports actually used" \ "imports allowed"
is a CI-blocking failure: an un-allowlisted dependency has been
introduced into the TCB.

Usage:

  lake exe tcb_audit          # exits 0 on success, 1 on violation

Implementation notes:

* The tool reads the source files directly and parses the
  `import X.Y.Z` lines.  It does *not* compute the transitive import
  closure; for that, every kernel-TCB module must itself be on the
  allowlist, and the rule is enforced module-by-module.

* The allowlist file format is one import per line, with `#`-prefixed
  comments and blank lines ignored.

* The audit is intentionally pessimistic: any `import` line that
  appears in a TCB source file but does not appear on the allowlist
  fails the audit, even if Lean would have accepted the import.

* The kernel-TCB file list and the safe file reader live in
  `Tools.Common` so they're shared with `Tools.CountSorries`.

Parser limits (gap analysis, AR.13.1 / m-1).  The narrow `parseImport`
grammar above is deliberate, but the cost is silent acceptance of
non-standard import forms.  In particular, these forms are NOT parsed:

  * `prelude`                  — only legal in Lean stdlib roots; not
                                 used by Knomosis.
  * `import all`               — bulk import; not used by Knomosis.
  * `meta import X`            — meta-import qualifier; not used by
                                 Knomosis.

A TCB-core file using any of these forms would silently bypass the
audit (the line is treated as a non-import).  This is acceptable today
because none of the listed forms appears in the codebase; the
maintenance contract is: if a future toolchain bump or refactor
introduces one of them into a TCB-core file, extend `parseImport` (and
re-verify the audit) in the same PR.
-/

import Tools.Common

open LegalKernel.Tools (tcbCoreFiles tcbInternalImports tcbAllowlistPath readFileSafe)

/-- Convert a list of characters back into a `String`.  Uses
    `String.ofList`, the modern non-deprecated entry point.  All of
    the line-manipulation logic below operates on `List Char`
    intermediates and re-converts only at the very end, sidestepping
    the `String.Slice` / `String.Pos`-with-path-dependent-type
    changes that arrived in Lean 4.29.1. -/
def listToString (l : List Char) : String := String.ofList l

/-- Manual whitespace trim implemented directly on `List Char`. -/
def trimChars (cs : List Char) : List Char :=
  let leftTrimmed := cs.dropWhile Char.isWhitespace
  (leftTrimmed.reverse.dropWhile Char.isWhitespace).reverse

/-- Strip a `#`-style line comment from a list of characters. -/
def stripComment (cs : List Char) : List Char :=
  cs.takeWhile (· ≠ '#')

/-- Strip a single line comment and trailing whitespace.  A blank
    result means "ignore this line". -/
def cleanLine (s : String) : String :=
  listToString (trimChars (stripComment s.toList))

/-- Parse `import X.Y.Z` from a source line, returning the imported
    module name (`X.Y.Z`).  Returns `none` for lines that aren't
    imports.

    The grammar is intentionally narrow: the line must start with the
    word `import` (after leading whitespace), followed by exactly one
    module name.  Lean accepts more forms (`prelude`, `import all`,
    `meta import`), but Knomosis's TCB does not use them, and ruling
    them out keeps the parser simple. -/
def parseImport (line : String) : Option String :=
  let cs := trimChars line.toList
  let importKeyword := "import ".toList
  if cs.take importKeyword.length = importKeyword then
    let rest := trimChars (cs.drop importKeyword.length)
    let modChars := rest.takeWhile (fun c => c.isAlphanum || c = '.' || c = '_')
    if modChars.isEmpty then none else some (listToString modChars)
  else
    none

/-- Extract every `import X` line from a file's content.  Comments and
    blank lines are skipped. -/
def importsOf (content : String) : List String :=
  content.splitOn "\n"
    |>.filterMap (fun line =>
        let cleaned := cleanLine line
        if cleaned.isEmpty then none else parseImport cleaned)

/-- Read the allowlist file into a `List String`.  Each non-blank,
    non-comment line is an allowed import. -/
def readAllowlist : IO (List String) := do
  match (← readFileSafe tcbAllowlistPath) with
  | none =>
      throw <| IO.userError s!"tcb_audit: cannot read allowlist '{tcbAllowlistPath}'"
  | some s =>
      pure <| s.splitOn "\n" |>.filterMap (fun line =>
        let cleaned := cleanLine line
        if cleaned.isEmpty then none else some cleaned)

/-- An import is *allowed* if it appears in the allowlist or is one of
    the explicitly-enumerated TCB-internal modules
    (`LegalKernel.Kernel`, `LegalKernel.RBMapLemmas`).

    Important: we do **not** whitelist the entire `LegalKernel.*`
    namespace; that would let a TCB core file silently depend on a
    non-TCB module (e.g. `LegalKernel.Laws.Transfer`), expanding the
    trusted base without the §13.6 amendment process. -/
def isAllowed (allowlist : List String) (imp : String) : Bool :=
  imp ∈ allowlist || imp ∈ tcbInternalImports

/-- Audit one TCB module.  Returns the list of un-allowlisted imports
    (empty on success, non-empty on failure). -/
def auditModule (allowlist : List String) (path : String) :
    IO (List String) := do
  match (← readFileSafe path) with
  | none =>
      throw <| IO.userError s!"tcb_audit: cannot read TCB module '{path}'"
  | some content =>
      pure ((importsOf content).filter (fun imp => !isAllowed allowlist imp))

/-- Entry point.  Loads the allowlist, audits every core TCB module,
    and exits non-zero on any violation. -/
def main : IO UInt32 := do
  let allowlist ← readAllowlist
  IO.println s!"tcb_audit: {tcbCoreFiles.length} TCB module(s); allowlist has {allowlist.length} entrie(s)."
  let mut violations : List (String × String) := []
  for path in tcbCoreFiles do
    let badImps ← auditModule allowlist path
    for imp in badImps do
      violations := (path, imp) :: violations
  if violations.isEmpty then
    IO.println "tcb_audit: PASS — every TCB import is allowlisted."
    pure 0
  else
    IO.eprintln "tcb_audit: FAIL — un-allowlisted imports:"
    for (path, imp) in violations.reverse do
      IO.eprintln s!"  {path}: imports '{imp}' (not on allowlist)"
    IO.eprintln ""
    IO.eprintln s!"To fix: add the import to '{tcbAllowlistPath}' (and have it reviewed per §13.6)."
    pure 1
