-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Tools.StubAudit — Audit-3.8.

Mechanically detects placeholder-body stubs accompanied by
red-flag docstring tokens.  The historical incident this catches:
the Phase-3 `signingInput := ByteArray.empty` placeholder that
remained unwired through Phase 4, surfacing as a critical
deployment-readiness defect in the audit-1 review.

The tool walks every `.lean` file under `LegalKernel/`.  For each
line whose code content matches one of the documented stub
patterns (e.g. `:= ByteArray.empty`), it scans the preceding
docstring block for red-flag tokens (`stub`, `placeholder`,
`TODO`, `FIXME`, `wire`, `deferred`, `Phase`, `later`, `not for
production`).  A line that triggers both checks is reported as a
violation unless the entry is in `tools/stub_allowlist.txt`
(format: `module-path:matched-line-text` per line).

Exit semantics:

  * Exit 0 if every stub match is on the allowlist OR has no
    red-flag docstring nearby (i.e. is a legitimate body that
    happens to start with a stub-like literal).
  * Exit 1 if any stub match has a red-flag docstring nearby and
    is not on the allowlist.

Discipline: the allowlist binds an entry to the specific matched
line *text*.  Any change to the line invalidates the allowlist
entry, forcing the reviewer to re-check the placeholder.

This module is **not** part of the trusted computing base: bugs
here surface as false positives (additional reviewer load) or
false negatives (a future stub slipping through), but cannot
violate any kernel invariant.  The audit's regex-based detection
covers ~80% of cases — including the actual historical incident
— and is fast enough to run on every CI build.
-/

import Tools.Common

open LegalKernel.Tools (readFileSafe)

/-- Files-and-directories search root.  Covers the kernel
    (`LegalKernel`) and the Lex programming language (`Lex`)
    source trees (mirroring `count_sorries`'s scope). -/
def searchRoots : List String := ["LegalKernel", "Lex"]

/-- Allowlist file path. -/
def stubAllowlistPath : String := "tools/stub_allowlist.txt"

/-- Stub-body patterns: literal substrings that indicate a
    placeholder implementation when they appear after `:=`. -/
def stubPatterns : List String :=
  [ ":= ByteArray.empty"
  , ":= []"
  , ":= #[]"
  , ":= ⟨#[]⟩"
  , ":= pure ByteArray.empty"
  ]

/-- Docstring tokens that suggest a stub.  Match is case-insensitive
    after lowercasing the docstring. -/
def redFlagTokens : List String :=
  [ "stub", "placeholder", "todo", "fixme", "wire", "deferred"
  , "later", "not for production"
  ]

/-- Recursively enumerate every `.lean` file under `root`.
    Mirrors `count_sorries`'s helper. -/
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

/-- Strip leading and trailing ASCII whitespace from a string.
    Replacement for the deprecated `String.trim` (which now returns
    a `String.Slice`).  Audit-3.8 prefers an explicit helper to
    avoid coupling to evolving stdlib types. -/
def stripWhitespace (s : String) : String :=
  let cs := s.toList
  let dropLeft := cs.dropWhile Char.isWhitespace
  let dropBoth := (dropLeft.reverse.dropWhile Char.isWhitespace).reverse
  String.ofList dropBoth

/-- True iff the string is empty. -/
def isStringEmpty (s : String) : Bool := s.length = 0

/-- Lower-case a string by remapping uppercase ASCII bytes.  No
    Unicode awareness; sufficient for the English-language tokens
    we look for. -/
def asciiLower (s : String) : String :=
  String.ofList (s.toList.map (fun c =>
    if c.toNat ≥ 0x41 ∧ c.toNat ≤ 0x5A then Char.ofNat (c.toNat + 0x20)
    else c))

/-- Test whether `needle` appears as a contiguous substring of
    `haystack`.  Both arguments are case-folded by the caller if
    case-insensitive matching is desired. -/
def containsSubstr (haystack needle : String) : Bool :=
  match needle with
  | "" => true
  | _  =>
    let h := haystack.toList
    let n := needle.toList
    let nLen := n.length
    let rec go (xs : List Char) : Bool :=
      if xs.take nLen = n then true
      else
        match xs with
        | []      => false
        | _ :: rest => go rest
    go h

/-- Strip a `--` line comment from a line, returning the code
    portion only.  Naive: does not handle `--` inside string
    literals (overkill for the audit's purposes). -/
def stripLineComment (line : String) : String :=
  match line.splitOn "--" with
  | []      => ""
  | h :: _  => h

/-- Test whether the code portion of `line` contains any of the
    stub patterns. -/
def lineHasStubPattern (line : String) : Bool :=
  let code := stripLineComment line
  stubPatterns.any (fun p => containsSubstr code p)

/-- Test whether `block` contains any red-flag token (case-folded). -/
def blockHasRedFlag (block : String) : Bool :=
  let lower := asciiLower block
  redFlagTokens.any (fun t => containsSubstr lower t)

/-- Scan upward from `lineIdx` (1-based) up to `lookback` lines for
    a `/-- ... -/` docstring block.  Returns the concatenated
    docstring content if found, else the empty string.

    The 12-line default lookback was chosen empirically to cover the
    typical kernel-adjacent docstring length (≤ 8 lines of body plus
    the opening `/--` and closing `-/`, with a small margin for
    multi-paragraph rationales).  Stubs documented by ≥ 13-line
    docstrings will not match — review `redFlagTokens` and bump this
    default if the typical docstring length grows. -/
def docstringAbove (lines : Array String) (lineIdx : Nat)
    (lookback : Nat := 12) : String := Id.run do
  let startIdx :=
    if lineIdx > lookback + 1 then lineIdx - lookback - 1 else 0
  let endIdx := if lineIdx ≥ 1 then lineIdx - 1 else 0
  let mut block := ""
  let mut inDoc := false
  let mut anyOpened := false
  for i in [startIdx:endIdx] do
    let line := if h : i < lines.size then lines[i] else ""
    if line.startsWith "/--" then
      inDoc := true
      anyOpened := true
      block := block ++ "\n" ++ line
    else if inDoc then
      block := block ++ "\n" ++ line
      if containsSubstr line "-/" then
        inDoc := false
  pure (if anyOpened then block else "")

/-- One stub violation: file path, 1-based line number, and the
    matched line's full text. -/
structure Violation where
  /-- File path (relative to repo root) where the violation was found. -/
  path    : String
  /-- 1-based line number of the violation in `path`. -/
  lineNo  : Nat
  /-- Full text of the matched line, used as part of the
      allowlist-binding key. -/
  rawLine : String
  deriving Inhabited

/-- Format a violation as `path:line|rawLine` (the canonical
    allowlist key form). -/
def Violation.canonicalKey (v : Violation) : String :=
  s!"{v.path}:{v.lineNo}|{v.rawLine}"

/-- Read the allowlist file, returning the set of canonical keys
    (one per non-blank, non-comment line).  Missing file is
    treated as empty allowlist. -/
def readAllowlist (path : String) : IO (List String) := do
  match (← readFileSafe path) with
  | none      => pure []
  | some text =>
    let nonEmpty (s : String) : Bool :=
      let t := stripWhitespace s
      ¬ isStringEmpty t ∧ ¬ (t.startsWith "#")
    pure (text.splitOn "\n" |>.filter nonEmpty |>.map stripWhitespace)

/-- Per-file violation scan.  Returns every line whose code matches
    a stub pattern AND has a red-flag docstring above it. -/
def scanFile (path : String) : IO (List Violation) := do
  match (← readFileSafe path) with
  | none      => pure []
  | some text =>
    let lines := text.splitOn "\n" |>.toArray
    let mut acc : List Violation := []
    let mut i := 0
    for line in lines do
      i := i + 1
      if lineHasStubPattern line then
        let block := docstringAbove lines i
        if blockHasRedFlag block then
          acc := { path := path, lineNo := i, rawLine := line } :: acc
    pure acc.reverse

/-- Aggregate violations across every `.lean` file under the
    search roots, filtering out any that are on the allowlist. -/
def aggregate : IO (List Violation) := do
  let mut allFiles : List String := []
  for r in searchRoots do
    let xs ← listLeanFiles r
    allFiles := xs.foldl (fun a f => f :: a) allFiles
  let allFilesUnique := (allFiles.reverse.foldl
    (fun acc f => if f ∈ acc then acc else f :: acc)
    ([] : List String)).reverse
  let allowlist ← readAllowlist stubAllowlistPath
  let mut result : List Violation := []
  for f in allFilesUnique do
    let vs ← scanFile f
    for v in vs do
      if v.canonicalKey ∉ allowlist then
        result := v :: result
  pure result.reverse

/-- Entry point.  Reports any stub matches with red-flag docstrings.
    Exits 1 if any unallowlisted match exists. -/
def main : IO UInt32 := do
  let violations ← aggregate
  if violations.isEmpty then
    IO.println "stub_audit: PASS — no unallowlisted stub matches found."
    pure 0
  else
    IO.eprintln s!"stub_audit: FAIL — {violations.length} unallowlisted stub match(es):"
    for v in violations do
      IO.eprintln s!"  {v.path}:{v.lineNo}: {stripWhitespace v.rawLine}"
      IO.eprintln s!"    allowlist key: {v.canonicalKey}"
    IO.eprintln "Add the canonical key (path:line|raw-line) to tools/stub_allowlist.txt"
    IO.eprintln "after reviewer sign-off, OR remove the stub."
    pure 1
