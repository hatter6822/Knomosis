/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Test.Tools.Format — Workstream-LX (M3) tests for
the `lex_format` pretty-printer.

Covers LX.36:

  * Trailing-whitespace stripping.
  * Empty-events canonicalisation
    (`lex_events := do pure ()` → `lex_events := []`).
  * Idempotency: format ∘ format = format.
  * Final-newline normalisation (exactly one trailing newline).
  * Clause-keyword recognition.
-/

import LegalKernel.Test.Framework
import Lex.Tools.Format

namespace Lex.Test.Tools.FormatTests

open LegalKernel.Test
open LegalKernel.Tools.Lex
open LegalKernel.Tools.Lex.Format

/-! ## Trailing whitespace + final newline -/

/-- Trailing whitespace is stripped from every line. -/
def trailingWhitespaceStripped : TestCase := {
  name := "LX.36: trailing whitespace is stripped"
  body := do
    let input := "lex_id ex   \nlex_version \"1.0\"  \n"
    let output := formatLexSource input
    -- Each line should have no trailing whitespace.
    for line in output.splitOn "\n" do
      -- Check by inspecting the last character of each line.
      let chars := line.toList
      if !chars.isEmpty then
        let last := chars[chars.length - 1]!
        assert (last != ' ' && last != '\t' && last != '\r')
          s!"line `{line}` has trailing whitespace `{last}`"
}

/-- The output ends with exactly one trailing newline. -/
def singleTrailingNewline : TestCase := {
  name := "LX.36: output has exactly one trailing newline"
  body := do
    -- Test 1: input with no trailing newline gets one added.
    let input1 := "lex_id ex"
    let output1 := formatLexSource input1
    assert (output1.endsWith "\n") "output ends with newline"
    -- Test 2: input with multiple trailing newlines is normalised.
    let input2 := "lex_id ex\n\n\n\n"
    let output2 := formatLexSource input2
    assert (output2.endsWith "\n") "output ends with one newline"
    -- Verify we don't have multiple trailing newlines: the second-
    -- to-last char should not be '\n'.
    let chars := output2.toList
    if chars.length ≥ 2 then
      let secondToLast := chars[chars.length - 2]!
      assert (secondToLast != '\n')
        s!"second-to-last char is `{secondToLast}` (should not be newline)"
}

/-! ## Empty-events canonicalisation -/

/-- `lex_events := do pure ()` → `lex_events := []`.  Empty-events
    canonicalisation operates on clause-bodies inside `lexlaw …
    where` blocks, so the test fixture wraps the empty-events
    line in a minimal block. -/
def canonicaliseEventsPureUnit : TestCase := {
  name := "LX.36: lex_events := do pure () canonicalises to lex_events := []"
  body := do
    let input := "lexlaw t where\n  lex_events := do pure ()\n"
    let output := formatLexSource input
    assert (output.contains '[' && output.contains ']')
      "output contains `[]`"
    assert (!output.contains '(')
      "output does not contain `()`"
}

/-- `lex_events := do nothing` → `lex_events := []`. -/
def canonicaliseEventsDoNothing : TestCase := {
  name := "LX.36: lex_events := do nothing canonicalises to lex_events := []"
  body := do
    let input := "lexlaw t where\n  lex_events := do nothing\n"
    let output := formatLexSource input
    assert (output.contains '[' && output.contains ']')
      "output contains `[]`"
    let containsNothing :=
      "nothing".isPrefixOf output ||
      (output.splitOn "nothing").length > 1
    assert (!containsNothing)
      "output does not contain `nothing`"
}

/-- `lex_events := []` (already canonical) is preserved. -/
def canonicalEventsPreserved : TestCase := {
  name := "LX.36: already-canonical lex_events := [] is preserved"
  body := do
    let input := "  lex_events := []\n"
    let output := formatLexSource input
    assert (output.contains '[' && output.contains ']')
      "output preserves the `[]`"
}

/-! ## Idempotency: format ∘ format = format -/

/-- Applying format twice yields the same result. -/
def idempotency : TestCase := {
  name := "LX.36: format ∘ format = format"
  body := do
    let input := "lex_id ex   \nlex_events := do pure ()\nlex_pre := True   \n"
    let once := formatLexSource input
    let twice := formatLexSource once
    assertEq (expected := once) (actual := twice)
      "format ∘ format = format"
}

/-- A multi-clause manifest is idempotently formatted. -/
def idempotencyManifest : TestCase := {
  name := "LX.36: deployment manifest formatting is idempotent"
  body := do
    let input := "deployment myDeploy where\n  deploy_id ex.foo\n  deploy_version \"1.0.0\"   \n"
    let once := formatLexSource input
    let twice := formatLexSource once
    assertEq (expected := once) (actual := twice) "idempotent"
}

/-! ## Clause-keyword recognition -/

/-- Every canonical clause keyword is recognised by
    `isClauseStartLine`. -/
def clauseRecognition : TestCase := {
  name := "LX.36: every canonical clause keyword is recognised"
  body := do
    for kw in canonicalClauseOrder do
      let line := s!"  {kw} foo"
      assert (isClauseStartLine line)
        s!"`{kw}` should be recognised as a clause-start"
}

/-- Non-clause lines are not flagged as clause-starts. -/
def nonClauseRecognition : TestCase := {
  name := "LX.36: non-clause lines are not flagged"
  body := do
    let lines := [
      "deployment myDeploy where",
      "lexlaw exampleLaw where",
      "  -- a comment",
      "  fun s => s",
      ""
    ]
    for line in lines do
      assert (!isClauseStartLine line)
        s!"`{line}` should NOT be flagged as a clause-start"
}

/-- `extractClauseKeyword` extracts the keyword. -/
def extractClauseKeywordTest : TestCase := {
  name := "LX.36: extractClauseKeyword returns the keyword"
  body := do
    assertEq (expected := "lex_id")
             (actual := extractClauseKeyword "  lex_id foo")
      "lex_id"
    assertEq (expected := "deploy_version")
             (actual := extractClauseKeyword "deploy_version \"1.0\"")
      "deploy_version"
    assertEq (expected := "")
             (actual := extractClauseKeyword "  not_a_clause")
      "non-clause returns empty string"
}

/-! ## Empty input handling -/

/-- An empty input produces a minimal output (just `\n`). -/
def emptyInputProducesNewline : TestCase := {
  name := "LX.36: empty input produces a single newline"
  body := do
    let output := formatLexSource ""
    assertEq (expected := "\n") (actual := output)
      "empty input → single newline"
}

/-! ## Trailing whitespace independence: no-op on already-clean input -/

/-- A correctly-formatted input is unchanged. -/
def cleanInputUnchanged : TestCase := {
  name := "LX.36: clean input is byte-stable"
  body := do
    let input := "lex_id ex.foo\nlex_version \"1.0\"\n"
    let output := formatLexSource input
    assertEq (expected := input) (actual := output)
      "already-clean input is unchanged"
}

/-! ## CRLF handling -/

/-- CRLF line endings are handled (CR stripped from each line). -/
def crlfHandling : TestCase := {
  name := "LX.36: CRLF line endings are normalised"
  body := do
    let input := "lex_id ex\r\nlex_version \"1.0\"\r\n"
    let output := formatLexSource input
    assert (!output.contains '\r')
      "output contains no CR characters"
}

/-! ## LX.36 — Clause-order canonicalisation -/

/-- Out-of-order clauses are reordered to canonical sequence. -/
def clauseOrderCanonicalisation : TestCase := {
  name := "LX.36: clauses reordered to canonical sequence"
  body := do
    let input :=
      "lexlaw t where\n" ++
      "  lex_satisfies := []\n" ++
      "  lex_intent \"foo\"\n" ++
      "  lex_id legalkernel.t\n" ++
      "  lex_version \"1.0\"\n"
    let output := formatLexSource input
    -- Verify lex_id appears before lex_version, which appears before
    -- lex_intent, which appears before lex_satisfies.
    let lines := output.splitOn "\n"
    let idIdx :=
      lines.idxOf? "  lex_id legalkernel.t" |>.getD 999
    let versionIdx :=
      lines.idxOf? "  lex_version \"1.0\"" |>.getD 999
    let intentIdx :=
      lines.idxOf? "  lex_intent \"foo\"" |>.getD 999
    let satIdx :=
      lines.idxOf? "  lex_satisfies := []" |>.getD 999
    assert (idIdx < versionIdx) s!"lex_id at {idIdx} should precede lex_version at {versionIdx}"
    assert (versionIdx < intentIdx) s!"lex_version should precede lex_intent"
    assert (intentIdx < satIdx) s!"lex_intent should precede lex_satisfies"
}

/-- Idempotency on a multi-clause out-of-order input. -/
def clauseOrderIdempotent : TestCase := {
  name := "LX.36: clause-order canonicalisation is idempotent"
  body := do
    let input :=
      "lexlaw t where\n" ++
      "  lex_satisfies := []\n" ++
      "  lex_id legalkernel.t\n" ++
      "  lex_version \"1.0\"\n"
    let once := formatLexSource input
    let twice := formatLexSource once
    assertEq (expected := once) (actual := twice)
      "idempotent on out-of-order input"
}

/-! ## LX.36 — Comment preservation -/

/-- A comment immediately preceding a clause moves WITH the
    clause during reordering. -/
def commentPreservationOnReorder : TestCase := {
  name := "LX.36: comments move with clauses during reordering"
  body := do
    let input :=
      "lexlaw t where\n" ++
      "  lex_version \"1.0\"\n" ++
      "  -- comment for lex_id\n" ++
      "  lex_id legalkernel.t\n"
    let output := formatLexSource input
    -- After reordering, lex_id is first; the comment should
    -- appear immediately before lex_id.
    let lines := output.splitOn "\n"
    let commentIdx :=
      lines.idxOf? "  -- comment for lex_id" |>.getD 999
    let idIdx :=
      lines.idxOf? "  lex_id legalkernel.t" |>.getD 999
    assert (commentIdx + 1 == idIdx)
      s!"comment at {commentIdx} should immediately precede lex_id at {idIdx}"
}

/-- Free-floating comments before the first clause are
    preserved as preludeLines. -/
def commentPreludePreserved : TestCase := {
  name := "LX.36: comments before first clause are preserved as prelude"
  body := do
    let input :=
      "lexlaw t where\n" ++
      "  -- prelude comment\n" ++
      "  lex_id legalkernel.t\n" ++
      "  lex_version \"1.0\"\n"
    let output := formatLexSource input
    assert (output.contains '-')
      "output preserves comment characters"
    let containsPrelude :=
      ("prelude comment".splitOn output.toList.toString).length > 1 ||
      (output.splitOn "prelude").length > 1
    assert containsPrelude
      "output contains the prelude comment"
}

/-! ## LX.36 — Multi-line empty-events -/

/-- Multi-line `lex_events := do\n  pure ()` → `lex_events := []`. -/
def multiLineEmptyEventsPureUnit : TestCase := {
  name := "LX.36: multi-line lex_events do pure () canonicalises"
  body := do
    let input :=
      "lexlaw t where\n" ++
      "  lex_events := do\n" ++
      "    pure ()\n"
    let output := formatLexSource input
    assert (output.contains '[' && output.contains ']')
      "output contains `[]`"
    let outputLines := output.splitOn "\n"
    let hasEventsCanonical := outputLines.any
      (fun line => stripWhitespace line == "lex_events := []")
    assert hasEventsCanonical
      "output has canonicalised lex_events := []"
}

/-- Multi-line `lex_events := do\n  nothing` → `lex_events := []`. -/
def multiLineEmptyEventsNothing : TestCase := {
  name := "LX.36: multi-line lex_events do nothing canonicalises"
  body := do
    let input :=
      "lexlaw t where\n" ++
      "  lex_events := do\n" ++
      "    nothing\n"
    let output := formatLexSource input
    let outputLines := output.splitOn "\n"
    let hasEventsCanonical := outputLines.any
      (fun line => stripWhitespace line == "lex_events := []")
    assert hasEventsCanonical
      "output has canonicalised lex_events := []"
}

/-! ## LX.36 — Indentation preservation -/

/-- Multi-line clause continuations preserve their relative
    indentation. -/
def indentationPreserved : TestCase := {
  name := "LX.36: continuation indentation preserved"
  body := do
    let input :=
      "lexlaw t where\n" ++
      "  lex_id legalkernel.t\n" ++
      "  lex_pre := fun s =>\n" ++
      "    True ∧ True\n"
    let output := formatLexSource input
    -- Verify the continuation line starts with 4+ spaces (indented
    -- relative to the leader).
    let outputLines := output.splitOn "\n"
    let hasIndentedContinuation := outputLines.any
      (fun line => line.startsWith "    True")
    assert hasIndentedContinuation
      "continuation line preserved with its indentation"
}

/-! ## LX.36 — Block-aware behaviour -/

/-- Lines outside any `lexlaw`/`deployment` block are preserved
    verbatim. -/
def nonBlockContentPreserved : TestCase := {
  name := "LX.36: non-block content preserved verbatim"
  body := do
    let input :=
      "import Foo\n\nnamespace Bar\n\nlexlaw t where\n  lex_id x\n\nend Bar\n"
    let output := formatLexSource input
    assert (output.contains 'i' && output.contains 'B')
      "import + namespace preserved"
    let lines := output.splitOn "\n"
    let hasImport := lines.any (fun l => l == "import Foo")
    let hasNamespace := lines.any (fun l => l == "namespace Bar")
    let hasEnd := lines.any (fun l => l == "end Bar")
    assert hasImport "import preserved"
    assert hasNamespace "namespace preserved"
    assert hasEnd "end preserved"
}

/-! ## Audit-4 amendment: trailing-newline regression -/

/-- Regression: a `\n`-terminated source no longer inserts a
    spurious blank line between clauses after sorting.

    Pre-fix, the trailing `\n` from `splitOn "\n"` produced an
    empty string in `bodyLines` that was attached as a continuation
    of the LAST clause in source order; after canonical-order
    sorting, that blank line ended up in the WRONG place
    (between the source-last and canonically-last clauses). -/
def noSpuriousTrailingBlank : TestCase := {
  name := "audit-4: no spurious blank line from \\n-terminated source"
  body := do
    -- Input has clauses out of canonical order; will sort.
    let input :=
      "lexlaw foo where\n" ++
      "  lex_id x\n" ++
      "  lex_pre := True\n" ++
      "  lex_version \"1.0\"\n"  -- ends with \n
    let output := formatLexSource input
    -- Output should NOT contain blank lines between clauses.
    let lines := output.splitOn "\n"
    -- Drop the trailing empty entry that comes from splitOn on
    -- a `\n`-terminated string (the final newline canonicalisation).
    let interior :=
      match lines.reverse with
      | "" :: rest => rest.reverse
      | _ => lines
    -- Look for adjacent blank lines anywhere in the interior.
    let mut hasInternalBlank := false
    let mut prev := "X"  -- sentinel non-empty, so first iter never matches
    for line in interior do
      if line.isEmpty ∧ !prev.isEmpty then
        hasInternalBlank := true
      prev := line
    let nonEmpty := lines.filter (fun l => !l.isEmpty)
    -- Verify all 4 entries are present in canonical order.
    assert (nonEmpty.contains "lexlaw foo where") "opener present"
    assert (nonEmpty.contains "  lex_id x") "lex_id present"
    assert (nonEmpty.contains "  lex_version \"1.0\"") "lex_version present"
    assert (nonEmpty.contains "  lex_pre := True") "lex_pre present"
    -- Verify they're contiguous (no blank between them) by
    -- checking the position-difference is 1.
    let idIdx := nonEmpty.idxOf? "  lex_id x" |>.getD 999
    let verIdx := nonEmpty.idxOf? "  lex_version \"1.0\"" |>.getD 999
    let preIdx := nonEmpty.idxOf? "  lex_pre := True" |>.getD 999
    -- nonEmpty is [opener, lex_id, lex_version, lex_pre]
    assertEq (expected := 1) (actual := idIdx) "lex_id at position 1"
    assertEq (expected := 2) (actual := verIdx) "lex_version at position 2"
    assertEq (expected := 3) (actual := preIdx) "lex_pre at position 3"
    -- And verify NO internal blanks (indicates the audit-4 fix
    -- correctly stripped the trailing newline before segmenting).
    assert (!hasInternalBlank)
      "no internal blank lines between sorted clauses"
}

/-- The complete LX.36 test suite. -/
def tests : List TestCase :=
  [ trailingWhitespaceStripped,
    singleTrailingNewline,
    canonicaliseEventsPureUnit,
    canonicaliseEventsDoNothing,
    canonicalEventsPreserved,
    idempotency,
    idempotencyManifest,
    clauseRecognition,
    nonClauseRecognition,
    extractClauseKeywordTest,
    emptyInputProducesNewline,
    cleanInputUnchanged,
    crlfHandling,
    -- New M3-completion tests:
    clauseOrderCanonicalisation,
    clauseOrderIdempotent,
    commentPreservationOnReorder,
    commentPreludePreserved,
    multiLineEmptyEventsPureUnit,
    multiLineEmptyEventsNothing,
    indentationPreserved,
    nonBlockContentPreserved,
    -- Audit-4 amendment: trailing-newline regression
    noSpuriousTrailingBlank ]

end Lex.Test.Tools.FormatTests
