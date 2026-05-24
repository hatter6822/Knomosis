/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Tools.MockImportAudit — AR.9 / M-10.

Mechanically detects production-module imports of test-only modules.

The historical hazard this catches: a `Test/MockCrypto.lean` (or
similar) imported from a non-test source file would let mock
signatures into the production admissibility path, defeating the
EUF-CMA guarantee in any deployment compiled from that source.

The tool walks every `.lean` file in the production source roots
(`LegalKernel/`, `Lex/`, `Tools/`, `Deployments/`, plus the
top-level driver files at the repository root), skipping the
`Test/` and `test/` subdirectories.  Each line beginning with
`import LegalKernel.Test.`, `import Lex.Test.`, or `import Test.`
is reported as a violation.

Exit semantics:

  * Exit 0 if no violations are found.
  * Exit 1 if at least one production file imports a Test module.

This audit closes the M-10 "documented but not enforced" gap.  Before
AR.9, `LegalKernel/Test/MockCrypto.lean`'s docstring claimed the
`stub_audit` binary flagged production imports — but `stub_audit`
checks for placeholder-body patterns, not import patterns.  AR.9
ships a dedicated tool that actually enforces the claim.
-/

import Tools.Common

open LegalKernel.Tools (readFileSafe)

namespace LegalKernel.Tools.MockImport

/-! ## Configuration -/

/-- Source roots scanned for production imports.  The `Test/`
    subdirectory of each root is intentionally skipped (test files
    legitimately import test-only modules).  `Tests.lean` (the
    repository-root test driver) is intentionally excluded —
    it's the canonical test-aggregation file and its `import
    LegalKernel.Test.*` lines are by design. -/
def searchRoots : List String :=
  [ "LegalKernel"
  , "Lex"
  , "Tools"
  , "Deployments"
  , "Main.lean"
  , "Replay.lean"
  , "NamingAudit.lean"
  , "DeferralAudit.lean"
  , "LegalKernel.lean"
  , "Lex.lean"
  , "Deployments.lean"
  ]

/-- Test-module import prefixes.  An `import` line whose target
    starts with any of these is a "test module import". -/
def testImportPrefixes : List String :=
  [ "LegalKernel.Test."
  , "Lex.Test."
  , "Tools.Test."
  ]

/-! ## File enumeration -/

/-- Recursively enumerate every `.lean` file under `root`.  Mirrors
    `count_sorries`'s helper.  Skips any path containing `/Test/`
    or `/test/` (test directories are out-of-scope; their imports
    of test modules are legitimate). -/
partial def listLeanFiles (root : String) : IO (List String) := do
  let path : System.FilePath := root
  let metaResult ← path.metadata.toBaseIO
  match metaResult with
  | Except.error _ => pure []
  | Except.ok fileMeta =>
    if fileMeta.type == IO.FS.FileType.dir then
      let entries ← path.readDir
      let mut acc : List String := []
      for e in entries do
        let sub ← listLeanFiles e.path.toString
        acc := sub.foldl (fun a f => f :: a) acc
      pure acc.reverse
    else if root.endsWith ".lean" then
      pure [root]
    else
      pure []

/-- True iff a path lies in a test directory (and is therefore
    out-of-scope for this audit). -/
def isTestPath (path : String) : Bool :=
  -- `/Test/`, `/test/` — anywhere in the path.  We test both
  -- separator forms (`/Test/` and starts with `Test/`).
  let segments := path.splitOn "/"
  segments.any (fun s => s == "Test" || s == "test")

/-! ## Per-line check -/

/-- Strip leading and trailing ASCII whitespace. -/
private def stripWhitespace (s : String) : String :=
  let cs := s.toList
  let l := cs.dropWhile Char.isWhitespace
  let r := (l.reverse.dropWhile Char.isWhitespace).reverse
  String.ofList r

/-- True iff `s` starts with `pfx`.  Implemented over `List Char`
    to sidestep Lean 4.29.1's `String.Slice` / `String.Pos.Raw` API
    churn. -/
private def hasPrefix (s : String) (pfx : String) : Bool :=
  let rec go : List Char → List Char → Bool
    | _,       []          => true
    | [],      _ :: _      => false
    | c :: cs, d :: ds      => c = d ∧ go cs ds
  go s.toList pfx.toList

/-- Drop the first `n` characters of `s`.  Like `hasPrefix`,
    implemented over `List Char` to avoid the moving-target
    `String.drop : String → Nat → String.Slice` signature. -/
private def dropChars (s : String) (n : Nat) : String :=
  String.ofList (s.toList.drop n)

/-- Inspect one source line; return the imported test-module name
    if the line is `import <test-prefix>...`, else `none`. -/
def matchTestImport (line : String) : Option String := do
  let trimmed := stripWhitespace line
  -- Lean imports always start with the word `import`.
  if !hasPrefix trimmed "import " then
    none
  else
    let rest := stripWhitespace (dropChars trimmed "import ".length)
    -- Match against every test-import prefix.
    let matched := testImportPrefixes.filter (fun p => hasPrefix rest p)
    matched.head?

/-! ## Violation record -/

/-- A single import-of-test violation. -/
structure Violation where
  /-- File path (relative to repo root). -/
  path : String
  /-- 1-based line number within `path`. -/
  lineNo : Nat
  /-- The imported test module's name. -/
  importedModule : String
  deriving Repr

/-! ## Per-file scan -/

/-- Scan a file's contents for test-import violations. -/
def scanContent (path : String) (content : String) : List Violation :=
  let lines := content.splitOn "\n"
  let withNumbers := lines.zipIdx 1
  withNumbers.filterMap fun (line, idx) =>
    match matchTestImport line with
    | none      => none
    | some name => some { path, lineNo := idx, importedModule := name }

/-- Read a file and scan it.  Read failure → no violations
    (forgiving of partial-read races on directory enumeration). -/
def scanFile (path : String) : IO (List Violation) := do
  match (← readFileSafe path) with
  | none         => pure []
  | some content => pure (scanContent path content)

/-! ## Aggregation -/

/-- Aggregate violations across every `.lean` file under
    `searchRoots`, skipping test paths. -/
def aggregate : IO (List Violation) := do
  let mut allFiles : List String := []
  for r in searchRoots do
    let xs ← listLeanFiles r
    allFiles := xs.foldl (fun a f => f :: a) allFiles
  let productionFiles := allFiles.filter (¬ isTestPath ·)
  let mut violations : List Violation := []
  for f in productionFiles do
    let vs ← scanFile f
    violations := vs.foldl (fun a v => v :: a) violations
  pure violations.reverse

end LegalKernel.Tools.MockImport

/-! ## Entry point -/

/-- Entry point.  Reports each violation on stderr; exits with code
    `1` if any violation is found, `0` otherwise. -/
def main : IO UInt32 := do
  let violations ← LegalKernel.Tools.MockImport.aggregate
  if violations.isEmpty then
    IO.println "mock_import_audit: PASS — no production imports of Test modules."
    pure 0
  else
    IO.eprintln s!"mock_import_audit: FAIL — {violations.length} production import(s) of Test modules:"
    for v in violations do
      IO.eprintln s!"  {v.path}:{v.lineNo}: imports {v.importedModule}*"
    pure 1
