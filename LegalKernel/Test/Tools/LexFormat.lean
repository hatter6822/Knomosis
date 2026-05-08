/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Tools.LexFormat — Workstream-LX (M3) tests for
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
import Tools.LexFormat

namespace LegalKernel.Test.Tools
namespace LexFormatTests

open LegalKernel.Test
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

/-- `lex_events := do pure ()` → `lex_events := []`. -/
def canonicaliseEventsPureUnit : TestCase := {
  name := "LX.36: lex_events := do pure () canonicalises to lex_events := []"
  body := do
    let input := "  lex_events := do pure ()\n"
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
    let input := "  lex_events := do nothing\n"
    let output := formatLexSource input
    assert (output.contains '[' && output.contains ']')
      "output contains `[]`"
    -- Check that the output doesn't contain "nothing" — the
    -- canonical form has eliminated the do-nothing pattern.
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
    crlfHandling ]

end LexFormatTests
end LegalKernel.Test.Tools
