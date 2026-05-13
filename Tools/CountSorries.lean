/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Tools.CountSorries — Phase 1 WU 1.12.

Counts `sorry` occurrences in proof position across the project.  The
tool walks every `.lean` file under `searchRoots` and, per file,
counts lines that contain a `sorry` term in a code context — i.e. not
inside a `--` line comment, a `/- … -/` block comment, a `/-- … -/`
docstring, or a `"…"` string literal.

Exit semantics:

  * Exit 0 if every kernel-TCB module (the `kernelTcbFiles` list in
    `Tools.Common`) has *zero* `sorry` occurrences.
  * Exit 1 otherwise.

The tool is intentionally regex-flavoured, mirroring the manual check in
CLAUDE.md:

  grep -rnE '(:= sorry|by sorry|exact sorry|refine sorry|apply sorry|· sorry|\(sorry[ :]|^[[:space:]]*sorry[[:space:]]*$)' LegalKernel/

Comments referencing the *word* "sorry" (e.g. "no `sorry` in this file"
in a docstring) are allowed; only the *term* `sorry` in proof position
is forbidden.

The implementation has two stages:
  1. A character-level preprocessor walks the file and overwrites every
     character inside a comment or string literal with a space,
     preserving newlines.  Block comments are tracked with depth (Lean
     allows nesting); string literals respect `\"` escapes.
  2. The sorry patterns are searched on the preprocessed line-by-line
     view, where comments and string contents have been blanked out.
     The pattern set covers: `:=` assignment, `by` tactic body,
     `exact`/`refine`/`apply` tactic invocations, the `· sorry`
     bullet form, the `(sorry : T)` / `(sorry: T)` ascription forms,
     and the bare `sorry` on a line of its own (AR.14 / m-2).

A full check would invoke Lean's elaborator and inspect `sorryAx`
axiom usage; the present tool catches the common-case violations and
is fast enough to run on every CI build.
-/

import Tools.Common

open LegalKernel.Tools (kernelTcbFiles readFileSafe)

/-- Files-and-directories search root.  Covers the kernel
    (`LegalKernel`) and the Lex programming language (`Lex`)
    source trees, while avoiding the lake build cache and the
    audit tool's own pattern strings.  CI scans the kernel-
    adjacent surface; non-TCB auxiliary tooling is out of scope. -/
def searchRoots : List String :=
  [ "LegalKernel"
  , "Lex"
  ]

/-- Recursively enumerate every `.lean` file under `root`. -/
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

/-- Lexical state of the character-level preprocessor. -/
inductive LexState
  /-- Ordinary code; characters pass through unchanged. -/
  | code
  /-- Inside a `"…"` string literal; characters become spaces.
      `escaped` is `true` immediately after a backslash, so the next
      `"` does not close the string. -/
  | inString (escaped : Bool)
  /-- Inside a `/- … -/` block comment (or `/-- … -/` docstring) at
      the given nesting depth.  Lean allows nested block comments. -/
  | inBlockComment (depth : Nat)
  /-- Inside a `-- …` line comment; characters become spaces until
      the next newline. -/
  | inLineComment

/-- Mask one character given the current state, returning the
    `(replacement, newState)` pair.  `'\n'` is preserved verbatim in
    every state so line numbering matches the original file. -/
def maskStep : LexState → Char → Char → Char × LexState
  | .code, '/', '-'           => (' ', .inBlockComment 1)
  | .code, '-', '-'           => (' ', .inLineComment)
  | .code, '"', _             => (' ', .inString false)
  | .code, c, _               => (c, .code)
  | .inString true, _, _      => (' ', .inString false)
  | .inString false, '\\', _  => (' ', .inString true)
  | .inString false, '"', _   => (' ', .code)
  | .inString false, '\n', _  => ('\n', .inString false)
  | .inString false, _, _     => (' ', .inString false)
  | .inLineComment, '\n', _   => ('\n', .code)
  | .inLineComment, _, _      => (' ', .inLineComment)
  | .inBlockComment d, '/', '-' => (' ', .inBlockComment (d + 1))
  | .inBlockComment 1, '-', '/' => (' ', .code)
  | .inBlockComment (d + 1), '-', '/' => (' ', .inBlockComment d)
  | .inBlockComment d, '\n', _ => ('\n', .inBlockComment d)
  | .inBlockComment d, _, _   => (' ', .inBlockComment d)

/-- Walk a list of characters, blanking out comments and string
    literals.  After this pass, the only `sorry` substrings remaining
    are those in code position. -/
def maskNonCode (cs : List Char) : List Char :=
  let rec go (st : LexState) (acc : List Char) : List Char → List Char
    | []           => acc.reverse
    | [c]          =>
        -- Last character: no lookahead.  Mask under the current state
        -- treating the lookahead as a non-special placeholder.
        let (c', _) := maskStep st c ' '
        go st (c' :: acc) []
    | c₁ :: c₂ :: rest =>
        let (c', st') := maskStep st c₁ c₂
        match st, st', c₁, c₂ with
        | .code, .inBlockComment _, '/', '-'  => go st' (' ' :: ' ' :: acc) rest
        | .code, .inLineComment, '-', '-'      => go st' (' ' :: ' ' :: acc) rest
        | .inBlockComment _, .code, '-', '/'   => go st' (' ' :: ' ' :: acc) rest
        | .inBlockComment _, .inBlockComment _, '/', '-' =>
            go st' (' ' :: ' ' :: acc) rest
        | _, _, _, _                            => go st' (c' :: acc) (c₂ :: rest)
  go .code [] cs

/-- Test whether `needle` appears as a contiguous substring of `haystack`.
    Naive `O(n·m)` scan, sufficient for the short patterns the audit uses. -/
def listContains (haystack needle : List Char) : Bool :=
  match needle with
  | []      => true
  | _ :: _  =>
    let rec go (h : List Char) : Bool :=
      if h.take needle.length = needle then true
      else
        match h with
        | []      => false
        | _ :: rest => go rest
    go haystack

/-- Drop leading whitespace from a `List Char`. -/
def dropLeadingWs (cs : List Char) : List Char :=
  cs.dropWhile Char.isWhitespace

/-- Drop trailing whitespace from a `List Char`.  Reverses, drops
    leading whitespace, reverses back. -/
def dropTrailingWs (cs : List Char) : List Char :=
  (cs.reverse.dropWhile Char.isWhitespace).reverse

/-- Detect a `sorry` in proof position on this line.  The patterns
    cover the documented CLAUDE.md categories plus the AR.14 / m-2
    extensions: proof body via `:=`, tactic body via `by`, terminal
    `exact sorry`, tactic-call forms (`refine sorry`, `apply sorry`,
    `· sorry`), and the `(sorry : T)` / `(sorry: T)` ascription
    pattern, plus a line whose only non-whitespace content is the
    term `sorry`.

    Caller must pre-mask comments and string literals (i.e. pass the
    output of `maskNonCode` segmented by newline). -/
def isSorryProofPosition (codeLine : List Char) : Bool :=
  let trimmed    := dropTrailingWs (dropLeadingWs codeLine)
  let pAssign    := listContains codeLine ":= sorry".toList
  let pBy        := listContains codeLine "by sorry".toList
  let pExact     := listContains codeLine "exact sorry".toList
  -- AR.14 / m-2: additional tactic-call patterns.
  let pRefine    := listContains codeLine "refine sorry".toList
  let pApply     := listContains codeLine "apply sorry".toList
  let pBullet    := listContains codeLine "· sorry".toList
  -- The `(sorry : T)` ascription form.  Matches with or without
  -- whitespace before the colon.
  let pAscribe1  := listContains codeLine "(sorry : ".toList
  let pAscribe2  := listContains codeLine "(sorry: ".toList
  let pAscribe3  := listContains codeLine "(sorry :)".toList
  let pAscribe4  := listContains codeLine "(sorry:)".toList
  let pBare      := trimmed = "sorry".toList
  pAssign || pBy || pExact ||
  pRefine || pApply || pBullet ||
  pAscribe1 || pAscribe2 || pAscribe3 || pAscribe4 ||
  pBare

/-- Split a `List Char` at every `'\n'`, dropping the newline character
    from the resulting segments.  Equivalent to
    `(String.ofList cs).splitOn "\n" |>.map String.toList` but avoids
    round-tripping through `String`. -/
def splitOnNewline (cs : List Char) : List (List Char) :=
  let rec go (acc : List Char) (out : List (List Char)) :
      List Char → List (List Char)
    | []        => (acc.reverse :: out).reverse
    | '\n' :: rest => go [] (acc.reverse :: out) rest
    | c :: rest    => go (c :: acc) out rest
  go [] [] cs

/-- For each line in `content`, decide whether it carries a proof-position
    `sorry` and emit `(lineNumber, rawLine)` when it does.  The match
    is performed on the pre-masked code (so comments and string-literal
    contents are inert), but the *reported* line is the original
    source line, for diagnostic clarity. -/
def matchesInContent (content : String) : List (Nat × String) := Id.run do
  let maskedLines  := splitOnNewline (maskNonCode content.toList)
  let originalLines := content.splitOn "\n"
  -- Walk both lists in lock-step: `Option.zip` would be cleaner but the
  -- `for` loop on `List.zip` reads more naturally here.
  let mut acc : List (Nat × String) := []
  let mut idx : Nat := 0
  for (codeLine, rawLine) in maskedLines.zip originalLines do
    idx := idx + 1
    if isSorryProofPosition codeLine then
      acc := (idx, rawLine) :: acc
  pure acc.reverse

/-- Read the file at `path`, returning its `matchesInContent` result.
    A read failure becomes the empty list, so the tool is forgiving on
    directory partial-read races. -/
def fileMatches (path : String) : IO (List (Nat × String)) := do
  match (← readFileSafe path) with
  | none         => pure []
  | some content => pure (matchesInContent content)

/-- Aggregate sorry counts across every `.lean` file under
    `searchRoots`.  The result is keyed by file path and only
    files with at least one match appear. -/
def aggregate : IO (List (String × Nat)) := do
  let mut allFiles : List String := []
  for r in searchRoots do
    let xs ← listLeanFiles r
    allFiles := xs.foldl (fun a f => f :: a) allFiles
  let allFilesUnique := (allFiles.reverse.foldl
    (fun acc f => if f ∈ acc then acc else f :: acc)
    ([] : List String)).reverse
  let mut result : List (String × Nat) := []
  for f in allFilesUnique do
    let ms ← fileMatches f
    if ms.length > 0 then
      result := (f, ms.length) :: result
  pure result.reverse

/-- Entry point.  Reports per-file sorry counts; fails (exit 1) if
    any kernel-TCB file has a non-zero count, in which case the
    matching lines are echoed to stderr for the failing reviewer. -/
def main : IO UInt32 := do
  let counts ← aggregate
  let total := counts.foldl (fun acc p => acc + p.snd) 0
  IO.println s!"count_sorries: {total} sorry/sorries across {counts.length} file(s)."
  for (path, n) in counts do
    IO.println s!"  {path}: {n}"
  let mut tcbFail := false
  for tcbPath in kernelTcbFiles do
    let ms ← fileMatches tcbPath
    if ms.length > 0 then
      IO.eprintln s!"count_sorries: FAIL — kernel-TCB file '{tcbPath}' has {ms.length} sorry/sorries:"
      for (n, line) in ms do
        IO.eprintln s!"{tcbPath}:{n}: {line}"
      tcbFail := true
  if tcbFail then
    pure 1
  else
    IO.println "count_sorries: PASS — every kernel-TCB module has zero sorries."
    pure 0
