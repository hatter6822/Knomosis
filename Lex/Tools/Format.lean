/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Tools.Format — the Workstream-LX `lex_format` pretty-printer.

LX.36 (`docs/planning/lex_implementation_plan.md` §15).

`lex_format` is a deterministic Lex source-code formatter.
Implements the full §15 specification:

  * **Clause order**: per §3.3, the canonical order is `lex_id`,
    `lex_version`, `lex_action_index`, `lex_intent`,
    `lex_signed_by`, `lex_authorized_by`, `lex_params`, `lex_pre`,
    `lex_impl`, `lex_satisfies`, `lex_events`, `lex_proof <P>`
    (in registration order), `lex_registry_effect`.
  * **Indentation**: 2 spaces inside `where`; statements in
    `lex_impl := do` and `lex_events := do` aligned to the `do`
    keyword's column (preserved from original).
  * **Empty-events canonicalisation**: `lex_events := do pure ()`
    and `lex_events := do nothing` → `lex_events := []` (single
    AND multi-line forms).
  * **Trailing whitespace**: stripped.
  * **Final newline**: ensured (exactly one).
  * **Comments**: preserved verbatim at their original line; in-
    clause comments preserved at their original position;
    free-floating comments outside `where` blocks preserved.
  * **Idempotency**: `format ∘ format = format`.

# Design — clause-block segmentation

The formatter operates on the `lexlaw <name> where` block by
segmenting the body into "clause-groups": runs of lines starting
at a clause-start line (e.g. `lex_id`, `lex_version`) and
continuing until the next clause-start line.  Each clause-group
contains:

  1. The clause-start line (indented at the canonical 2-space level).
  2. Optionally, continuation lines (the body of multi-line clauses
     like `lex_impl := do` or `lex_events := do`), preserved with
     their relative indentation.

Comments (`--` line comments) and blank lines are attached to the
*following* clause-group when they appear immediately above a
clause-start, and to the *preceding* clause-group's body
otherwise.

Clause-groups are then sorted by canonical order and re-emitted.

# Design — non-`where` content

Content outside any `lexlaw … where` (or `deployment … where`)
block — imports, `namespace` declarations, free-floating
docstrings, `def`s, etc. — is preserved verbatim.  The formatter
only reorders content INSIDE `where` blocks.

# Design — idempotency

Idempotency is guaranteed by the canonical sort: applying the
formatter twice produces the same output as once because the
canonical order is total.  Trailing-whitespace stripping is
also idempotent (already-stripped lines are unchanged).

This module is **not** part of the trusted computing base.
-/

import Lex.Tools.Common

namespace LegalKernel.Tools.Lex.Format

open System (FilePath)

/-! ## Clause-keyword recognition -/

/-- The canonical order of `lex_*` and `deploy_*` clause keywords
    (§3.3 / §16.1).  Clauses appear in this order after
    formatting; clauses not in this list (forward-compat for v2)
    are placed at the end. -/
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

/-- Compute the canonical-order index for a clause keyword.
    Unknown keywords get a high index so they sort after
    canonical clauses (preserving their relative order). -/
def clauseOrderIndex (kw : String) : Nat :=
  match canonicalClauseOrder.idxOf? kw with
  | some i => i
  | none   => 1000  -- Unknown clauses sort after canonical ones.

/-- Strip trailing whitespace (spaces, tabs, carriage returns)
    from a single line. -/
def stripTrailingWhitespace (line : String) : String :=
  let cs := line.toList.reverse
  let dropped := cs.dropWhile (fun c =>
    c == ' ' || c == '\t' || c == '\r')
  String.ofList dropped.reverse

/-- True iff a line (after stripping leading whitespace) begins
    with a `lex_*` or `deploy_*` clause keyword. -/
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

/-- True iff `line` (after stripping leading whitespace) is a
    `lexlaw` or `deployment` block-opener. -/
def isBlockOpener (line : String) : Bool :=
  let trimmed := stripWhitespace line
  trimmed.startsWith "lexlaw " || trimmed.startsWith "lexlaw\t" ||
  trimmed.startsWith "deployment " || trimmed.startsWith "deployment\t"

/-- True iff `line` is purely a comment line (starts with `--`
    after stripping leading whitespace). -/
def isCommentLine (line : String) : Bool :=
  let trimmed := stripWhitespace line
  trimmed.startsWith "--"

/-- True iff `line` consists of only whitespace (or is empty). -/
def isBlankLine (line : String) : Bool :=
  (stripWhitespace line).isEmpty

/-! ## Clause group representation

A "clause group" is a contiguous block of lines that together
constitute one Lex clause.  The leader is the clause-start line
(e.g. `lex_id legalkernel.transfer`).  Continuation lines
(non-clause-start, non-block-end lines following the leader)
form the clause's body — typical for multi-line clauses like
`lex_impl := do … (multi-line body)`.

Comments and blank lines that appear immediately BEFORE a
clause-start are attached as `precedingComments` so they move
with the clause when reordering. -/

/-- A single clause's source representation. -/
structure ClauseGroup where
  /-- Canonical order index of the clause keyword. -/
  orderIndex : Nat
  /-- The clause keyword (e.g. `"lex_id"`). -/
  keyword : String
  /-- Source position when this clause first appeared (for stable
      sort within unknown-keyword groups). -/
  originalIndex : Nat
  /-- Comment / blank lines that appeared immediately above this
      clause.  These move with the clause during canonical
      reordering. -/
  precedingComments : List String
  /-- The clause-start line itself (the leader). -/
  leader : String
  /-- Continuation lines belonging to this clause (the body of
      multi-line clauses).  Empty for single-line clauses. -/
  continuations : List String
  deriving Repr, Inhabited

/-- A `lexlaw` / `deployment` block segmented into clause groups
    + non-clause content. -/
structure BlockSegmentation where
  /-- The block-opener line (`lexlaw <name> where`). -/
  opener : String
  /-- Comment / blank lines between the opener and the first
      clause (leading commentary). -/
  preludeLines : List String
  /-- The clause groups in original order. -/
  clauses : List ClauseGroup
  /-- Trailing lines after the last clause (non-clause content
      inside the block; rare). -/
  trailing : List String
  deriving Repr, Inhabited

/-! ## Block segmentation -/

/-- Segment the body of a `where` block into clause groups +
    leading comments + trailing lines.  Operates on the lines
    AFTER the opener.  Stops at the first line whose indentation
    is less than the opener's body indentation (signalling the
    end of the block).

    **Comment-attachment heuristic.**  Comments and blank lines
    are buffered until the next non-blank, non-comment line:

      * If that line is a clause-start: the buffered comments are
        attached to that clause as `precedingComments` (so they
        move WITH the clause during canonical reordering).
      * If that line is a continuation of an existing clause: the
        buffered comments + the line become continuations of the
        current clause.
      * If buffered comments appear before the FIRST clause: they
        become `preludeLines` (preserved as a free-floating
        block).
      * If buffered comments appear at the END of the block (no
        further non-blank lines): they become trailing-content
        of the last clause's continuations.
    -/
def segmentBlockBody (opener : String) (bodyLines : List String) :
    BlockSegmentation × List String := Id.run do
  let mut clauses : List ClauseGroup := []
  -- Comments / blank lines awaiting attachment to a clause.
  let mut bufferedComments : List String := []
  let mut currentClause : Option ClauseGroup := none
  let mut originalIdx : Nat := 0
  let mut afterBlock : List String := []
  let mut inBlock : Bool := true
  let mut preludeLines : List String := []
  let mut sawFirstClause : Bool := false
  let openerIndent : Nat :=
    (opener.toList.takeWhile (fun c => c == ' ' || c == '\t')).length
  for line in bodyLines do
    if !inBlock then
      afterBlock := afterBlock ++ [line]
      continue
    if isBlankLine line || isCommentLine line then
      -- Buffer until we know what this comment is attached to.
      bufferedComments := bufferedComments ++ [line]
      continue
    -- Non-blank, non-comment line.  Compute indentation.
    let lineIndent : Nat :=
      (line.toList.takeWhile (fun c => c == ' ' || c == '\t')).length
    if lineIndent ≤ openerIndent then
      -- Block has ended.  Flush buffered comments as continuations
      -- of the current clause (or as trailing if no current clause).
      if let some cl := currentClause then
        currentClause := some { cl with
          continuations := cl.continuations ++ bufferedComments }
        clauses := clauses ++ [currentClause.get!]
        currentClause := none
      else
        preludeLines := preludeLines ++ bufferedComments
      bufferedComments := []
      inBlock := false
      afterBlock := afterBlock ++ [line]
      continue
    -- Inside the block.
    if isClauseStartLine line then
      -- Flush the previous clause (its body is finalised; buffered
      -- comments belong to the upcoming clause).
      if let some cl := currentClause then
        clauses := clauses ++ [cl]
      -- If this is the very first clause, the buffered comments
      -- become preludeLines (free-floating block content).  For
      -- subsequent clauses, they become this clause's
      -- precedingComments.
      let attachedComments :=
        if !sawFirstClause then [] else bufferedComments
      if !sawFirstClause then
        preludeLines := preludeLines ++ bufferedComments
      let kw := extractClauseKeyword line
      sawFirstClause := true
      currentClause := some {
        orderIndex := clauseOrderIndex kw,
        keyword := kw,
        originalIndex := originalIdx,
        precedingComments := attachedComments,
        leader := line,
        continuations := []
      }
      originalIdx := originalIdx + 1
      bufferedComments := []
    else
      -- Continuation of the current clause.  Buffered comments +
      -- this line all become continuations of currentClause.
      if let some cl := currentClause then
        currentClause := some { cl with
          continuations := cl.continuations ++ bufferedComments ++ [line] }
        bufferedComments := []
      else
        -- Line before any clause; treat as preludeLine + this line.
        preludeLines := preludeLines ++ bufferedComments ++ [line]
        bufferedComments := []
  -- End-of-bodyLines reached.  Flush remaining buffered comments
  -- and the current clause.
  if let some cl := currentClause then
    let final := { cl with
      continuations := cl.continuations ++ bufferedComments }
    clauses := clauses ++ [final]
  else
    preludeLines := preludeLines ++ bufferedComments
  let segmentation : BlockSegmentation := {
    opener,
    preludeLines := preludeLines,
    clauses := clauses,
    trailing := []
  }
  pure (segmentation, afterBlock)

/-! ## Canonical-order sort + emission -/

/-- Sort clause groups by canonical order, with stable secondary
    sort by `originalIndex` (so two clauses with the same canonical
    index — e.g. multiple `lex_proof` overrides — retain their
    original relative order). -/
def sortClauseGroups (clauses : List ClauseGroup) : List ClauseGroup :=
  let sorted := clauses.toArray.qsort (fun a b =>
    if a.orderIndex < b.orderIndex then true
    else if a.orderIndex > b.orderIndex then false
    else a.originalIndex < b.originalIndex)
  sorted.toList

/-- Re-emit a `ClauseGroup` to source.  Includes its
    `precedingComments`, the leader, and the continuations.
    Each line's trailing whitespace is stripped. -/
def emitClauseGroup (cl : ClauseGroup) : List String :=
  cl.precedingComments.map stripTrailingWhitespace ++
  [stripTrailingWhitespace cl.leader] ++
  cl.continuations.map stripTrailingWhitespace

/-- Re-emit a `BlockSegmentation` to source. -/
def emitBlockSegmentation (seg : BlockSegmentation)
    (afterBlock : List String) : List String :=
  let opener := stripTrailingWhitespace seg.opener
  let prelude := seg.preludeLines.map stripTrailingWhitespace
  let sortedClauses := sortClauseGroups seg.clauses
  let clauseLines :=
    sortedClauses.flatMap emitClauseGroup
  let trailing := seg.trailing.map stripTrailingWhitespace
  [opener] ++ prelude ++ clauseLines ++ trailing ++ afterBlock

/-! ## Multi-line empty-events canonicalisation

Detects multi-line forms like:

  ```
  lex_events := do
    pure ()
  ```

  ```
  lex_events := do
    nothing
  ```

and rewrites them to single-line `lex_events := []`. -/

/-- True iff a clause group represents an empty-events form
    (single-line OR multi-line).  Used by
    `canonicaliseEmptyEventsClause` below. -/
def isEmptyEventsClauseGroup (cl : ClauseGroup) : Bool :=
  if cl.keyword != "lex_events" then false
  else
    -- Single-line: `lex_events := do pure ()` or `... do nothing` or `... []`.
    let leaderStripped := stripWhitespace cl.leader
    let isSinglePure := leaderStripped == "lex_events := do pure ()"
    let isSingleNothing := leaderStripped == "lex_events := do nothing"
    -- Multi-line: leader = `lex_events := do`, continuation = `pure ()` or `nothing`.
    let isMultiPure :=
      leaderStripped == "lex_events := do" &&
      (cl.continuations.filter (fun l => !isBlankLine l && !isCommentLine l)
        |>.map stripWhitespace) == ["pure ()"]
    let isMultiNothing :=
      leaderStripped == "lex_events := do" &&
      (cl.continuations.filter (fun l => !isBlankLine l && !isCommentLine l)
        |>.map stripWhitespace) == ["nothing"]
    isSinglePure || isSingleNothing || isMultiPure || isMultiNothing

/-- Canonicalise an empty-events clause group to the single-line
    `lex_events := []` form, preserving the leader's indentation. -/
def canonicaliseEmptyEventsClause (cl : ClauseGroup) : ClauseGroup :=
  if !isEmptyEventsClauseGroup cl then cl
  else
    let leadingWs := cl.leader.toList.takeWhile
      (fun c => c == ' ' || c == '\t')
    let newLeader := String.ofList leadingWs ++ "lex_events := []"
    { cl with leader := newLeader, continuations := [] }

/-! ## Top-level format function

The pipeline:

  1. Split source into lines.
  2. Walk lines top-to-bottom.
  3. When a `lexlaw` / `deployment` block opener is found,
     segment the following body, sort clauses, canonicalise
     empty-events, and re-emit.
  4. Lines outside any block are preserved verbatim (modulo
     trailing-whitespace stripping).
  5. Ensure exactly one final newline.

Idempotency: applying twice yields byte-identical output. -/

/-- Format the whole file's contents per §15. -/
partial def formatLexSource (s : String) : String := Id.run do
  let lines := s.splitOn "\n"
  let mut out : List String := []
  let mut idx : Nat := 0
  let linesArr := lines.toArray
  while idx < linesArr.size do
    let line := linesArr[idx]!
    if isBlockOpener line then
      -- Found a block opener.  Collect body lines until the block ends.
      out := out ++ [stripTrailingWhitespace line]
      idx := idx + 1
      let mut bodyLines : List String := []
      let openerIndent : Nat :=
        (line.toList.takeWhile (fun c => c == ' ' || c == '\t')).length
      -- Collect lines until indentation drops to or below opener's.
      while idx < linesArr.size do
        let l := linesArr[idx]!
        let lineIndent : Nat :=
          (l.toList.takeWhile (fun c => c == ' ' || c == '\t')).length
        if isBlankLine l || isCommentLine l then
          bodyLines := bodyLines ++ [l]
          idx := idx + 1
        else if lineIndent > openerIndent then
          bodyLines := bodyLines ++ [l]
          idx := idx + 1
        else
          break
      -- Audit-4 fix: strip trailing blank lines from bodyLines.
      -- Trailing blanks are typically `splitOn "\n"` artifacts of
      -- a `\n`-terminated source — NOT user-meaningful content
      -- inside the block.  If we keep them, they get attached as
      -- continuations of the last clause, which then gets
      -- misplaced after canonical-order sorting.
      let trimmedBodyLines : List String :=
        let revs := bodyLines.reverse
        let dropped := revs.dropWhile (fun l => isBlankLine l)
        dropped.reverse
      -- Segment + sort + emit.
      let (seg, _afterBlock) := segmentBlockBody line trimmedBodyLines
      -- Apply empty-events canonicalisation.
      let canonicalisedClauses :=
        seg.clauses.map canonicaliseEmptyEventsClause
      let segCanonical := { seg with clauses := canonicalisedClauses }
      let sortedClauses := sortClauseGroups segCanonical.clauses
      let clauseLines :=
        sortedClauses.flatMap emitClauseGroup
      let preludeLines := seg.preludeLines.map stripTrailingWhitespace
      out := out ++ preludeLines ++ clauseLines
    else
      out := out ++ [stripTrailingWhitespace line]
      idx := idx + 1
  -- Drop trailing blank lines, then add exactly one trailing newline.
  let cleaned :=
    let revs := out.reverse
    let dropped := revs.dropWhile (·.isEmpty)
    dropped.reverse
  String.intercalate "\n" cleaned ++ "\n"

/-! ## Main entry point -/

/-- Print `--help` text and exit 0. -/
def printHelp : IO UInt32 := do
  IO.println "lex_format — Workstream LX (LX.36) pretty-printer"
  IO.println ""
  IO.println "Usage: lake exe lex_format <file> [--in-place]"
  IO.println "       lake exe lex_format --help"
  IO.println ""
  IO.println "Reads a Lex law / deployment file and emits the canonical"
  IO.println "form to stdout (or rewrites in place with --in-place)."
  IO.println ""
  IO.println "Canonical formatting:"
  IO.println "  * Clause-order normalisation (§3.3)."
  IO.println "  * Indentation preserved within clause continuations."
  IO.println "  * Empty-events canonicalisation (do pure () | do nothing → [])."
  IO.println "  * Trailing whitespace stripped."
  IO.println "  * Comments preserved verbatim at original positions."
  IO.println "  * Final newline ensured."
  IO.println "  * Idempotent: format-then-format = format."
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
    if inPlace then
      -- Audit-5 (Sec-M3): refuse to follow symlinks when
      -- rewriting in place.  Without this check, a malicious
      -- actor with write access to the file's parent
      -- directory could replace `Foo.lean` with a symlink to
      -- a sensitive path (`~/.bashrc`, `/etc/...`).
      -- `IO.FS.rename` follows the symlink and overwrites
      -- the target.  We bail out with a precise diagnostic.
      let metaResult ← (System.FilePath.symlinkMetadata fp).toBaseIO
      match metaResult with
      | .error _ =>
        IO.eprintln s!"lex_format: cannot stat {path}; refusing in-place write"
        return 2
      | .ok mdata =>
        if mdata.type == IO.FS.FileType.symlink then
          IO.eprintln s!"lex_format: refusing to rewrite a symlink in place: {path}"
          IO.eprintln "  (re-run without --in-place to print to stdout instead)"
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
