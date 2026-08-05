-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Tools.AuditBinaries — self-tests for the non-Lex audit
binaries (`count_sorries`, `naming_audit`, `stub_audit`,
`deferral_audit`).

**Why this module exists.**  These four gates run in CI on every PR and
report PASS, which is what a working gate and a gate that cannot fire
look like from the outside.  An audit pass found that all four had
matcher bugs that made whole categories of violation invisible:

  * `deferral_audit` lowercased the haystack but NOT the needle, while
    storing `TODO:` / `FIXME:` / `XXX:` uppercase — so those three
    patterns could never match anything.
  * `count_sorries`' masking lexer treated the `"` inside a Lean
    CHARACTER literal `'"'` as a string opener, so an odd number of
    them blanked the rest of the file and hid every subsequent `sorry`
    from the zero-sorry gate.
  * `naming_audit`'s declaration parser recognised only a bare
    `noncomputable`/`private`/`protected` prefix, so every attributed
    (`@[extern] def …`), `partial`, `unsafe` or `opaque` declaration
    was invisible — a forbidden provenance token in any of them passed.
  * `stub_audit` only recognised a docstring whose opening delimiter
    sits at column 0, so a stub documented by an INDENTED docstring
    (i.e. any stub inside a namespace or structure) was never flagged.

Every case below is written to fail against the pre-fix matcher.  A
gate's own test suite is the only thing that distinguishes "nothing to
report" from "cannot report anything".

This module is test-only and non-TCB.
-/

import LegalKernel.Test.Framework
import Tools.CountSorries
import Tools.DeferralAudit
import Tools.NamingAudit
import Tools.ApiStabilityAudit
import Tools.StubAudit

namespace LegalKernel.Test.Tools.AuditBinaries

open LegalKernel.Test

/-! ## `deferral_audit` — case-folded matching -/

/-- The three uppercase deferral markers are detected.

    Pre-fix, `containsLower` folded only the haystack while the needles
    were stored uppercase, so `TODO:` / `FIXME:` / `XXX:` matched
    nothing at all and the gate passed every file containing them. -/
def deferralDetectsUppercaseMarkers : TestCase := {
  name := "deferral_audit: uppercase TODO/FIXME/XXX markers are detected"
  body := do
    for marker in ["TODO:", "FIXME:", "XXX:", "todo:", "FiXmE:"] do
      let content := s!"-- {marker} finish this later\n"
      let violations := Tools.DeferralAudit.auditFile "sample.lean" content
      if violations.isEmpty then
        throw <| IO.userError
          s!"BUG: `{marker}` was not flagged — the matcher is case-sensitive \
             in the needle again"
}

/-- A file with no deferral markers produces no violations, so the
    case-folding above did not make the matcher fire on everything. -/
def deferralAcceptsCleanContent : TestCase := {
  name := "deferral_audit: clean content produces no violations"
  body := do
    let content := "-- An ordinary comment about a todoist integration.\n\
                    def f (x : Nat) : Nat := x + 1\n"
    let violations := Tools.DeferralAudit.auditFile "sample.lean" content
    assertEq (expected := 0) (actual := violations.length)
      "clean content must not be flagged"
}

/-! ## `count_sorries` — character-literal masking -/

/-- A `sorry` after a `'"'` character literal is still visible.

    Pre-fix, the `"` inside the char literal opened a string, so
    everything after it was blanked and the `sorry` disappeared from the
    gate's view. -/
def countSorriesSeesPastCharLiteral : TestCase := {
  name := "count_sorries: a char literal containing a quote does not blank the file"
  body := do
    let survives (src : String) : Bool :=
      let masked := String.ofList (Tools.maskNonCode src.toList)
      decide ((masked.splitOn "sorry").length > 1)
    -- One `'"'` literal (odd count) followed by a real `sorry`.
    if !survives "def quoteChar : Char := '\"'\ntheorem t : True := sorry\n" then
      throw <| IO.userError
        "BUG: the `sorry` was masked away — a char literal is opening a string again"
    -- The escaped four-character form too.
    if !survives "def q : Char := '\\\"'\ntheorem t : True := sorry\n" then
      throw <| IO.userError
        "BUG: an escaped char literal is opening a string again"
    -- And the real masking still works: a `sorry` inside an actual
    -- string literal, line comment, or block comment must NOT survive.
    if survives "def s : String := \"sorry\"\n" then
      throw <| IO.userError "BUG: a `sorry` inside a string literal survived masking"
    if survives "-- sorry, not today\n" then
      throw <| IO.userError "BUG: a `sorry` inside a line comment survived masking"
    if survives "/- sorry, not today -/\n" then
      throw <| IO.userError "BUG: a `sorry` inside a block comment survived masking"
    -- A prime in an identifier must not be read as a literal opener.
    if !survives "theorem t' : True := sorry\n" then
      throw <| IO.userError "BUG: a primed identifier is being read as a char literal"
}

/-! ## `naming_audit` — declaration parsing -/

/-- Attributed and modifier-prefixed declarations are parsed.

    Pre-fix the parser handled only `noncomputable` / `private` /
    `protected`, and nothing behind an `@[...]` attribute, so a
    forbidden provenance token in any of these forms was invisible. -/
def namingAuditParsesAttributedDeclarations : TestCase := {
  name := "naming_audit: attributed and modifier-prefixed declarations are parsed"
  body := do
    let cases : List (String × String) :=
      [ ("def plainName : Nat := 0", "plainName")
      , ("@[simp] theorem attributedName : True := trivial", "attributedName")
      , ("@[extern \"knomosis_hash_bytes\"] def externName : Nat := 0", "externName")
      , ("@[simp, inline] def multiAttrName : Nat := 0", "multiAttrName")
      , ("partial def partialName : Nat := 0", "partialName")
      , ("unsafe def unsafeName : Nat := 0", "unsafeName")
      , ("opaque opaqueName : Nat", "opaqueName")
      , ("private noncomputable def stackedName : Nat := 0", "stackedName")
      , ("protected partial def stackedName2 : Nat := 0", "stackedName2")
      ]
    for (line, expected) in cases do
      match Tools.NamingAudit.parseDeclName line with
      | some got => assertEq (expected := expected) (actual := got) s!"parsing `{line}`"
      | none =>
        throw <| IO.userError
          s!"BUG: `{line}` was not recognised as a declaration — a forbidden \
             token here would pass the gate silently"
}

/-- A non-declaration line is still not parsed as one, so widening the
    parser did not make it match arbitrary text. -/
def namingAuditRejectsNonDeclarations : TestCase := {
  name := "naming_audit: non-declaration lines are not parsed as declarations"
  body := do
    for line in ["  -- def notADeclaration", "  x + y", "namespace Foo", ""] do
      match Tools.NamingAudit.parseDeclName line with
      | none => pure ()
      | some got =>
        throw <| IO.userError s!"BUG: `{line}` parsed as a declaration named `{got}`"
}

/-! ## `stub_audit` — indented docstrings -/

/-- An INDENTED docstring above a declaration is found.

    Pre-fix, `docstringAbove` required the opening delimiter at column
    0, so any stub inside a namespace or structure — which is nearly all
    of them — carried an invisible docstring and could not be flagged. -/
def stubAuditFindsIndentedDocstring : TestCase := {
  name := "stub_audit: an indented docstring above a declaration is found"
  body := do
    -- `docstringAbove` takes a 1-BASED line number of the declaration.
    let mentions (block needle : String) : Bool :=
      decide ((block.splitOn needle).length > 1)
    let indented : Array String :=
      #[ "namespace Foo"
       , "  /-- Placeholder: not yet implemented. -/"
       , "  def f : Nat := 0"
       ]
    if !mentions (Tools.StubAudit.docstringAbove indented 3) "Placeholder" then
      throw <| IO.userError
        "BUG: an indented docstring was not picked up — a stub inside any \
         namespace is invisible to the gate again"
    -- The column-0 form must still work.
    let atColumnZero : Array String :=
      #[ "/-- Placeholder: not yet implemented. -/"
       , "def g : Nat := 0"
       ]
    if !mentions (Tools.StubAudit.docstringAbove atColumnZero 2) "Placeholder" then
      throw <| IO.userError "BUG: a column-0 docstring is no longer picked up"
    -- A single-line docstring must close on its own line, so an
    -- unrelated later comment cannot leak into the block and produce a
    -- false positive.
    let leaky : Array String :=
      #[ "  /-- An ordinary, fully implemented helper. -/"
       , "  -- Placeholder: unrelated note on the next declaration."
       , "  def h : Nat := 0"
       ]
    if mentions (Tools.StubAudit.docstringAbove leaky 3) "Placeholder" then
      throw <| IO.userError
        "BUG: a single-line docstring ran on past its closing `-/`, so an \
         unrelated comment leaked into the block"
    -- A declaration with no docstring above it yields no block.
    let bare : Array String := #[ "namespace Foo", "  def k : Nat := 0" ]
    if !(Tools.StubAudit.docstringAbove bare 2).isEmpty then
      throw <| IO.userError "BUG: a block was reported where no docstring exists"
}

/-! ## `stub_audit` — comment masking -/

/-- **The stub pattern is matched on code, not on prose — and the gate
    still fires on real code.**

    Both halves matter, and only together.  `stub_audit` used to match
    the raw line, so a docstring EXPLAINING a placeholder (or explaining
    that a field deliberately has no default) read as the placeholder
    itself; the only ways out were to allowlist a comment or to not
    write it.  Masking fixes that — and could just as easily blank the
    gate entirely, since a mask that is too eager leaves no code to
    match.  This asserts the two directions against each other. -/
def stubAuditMasksCommentsButStillFires : TestCase := {
  name := "stub_audit: masking hides prose without disarming the gate"
  body := do
    let masked (src : String) : String :=
      String.ofList (Tools.maskNonCode src.toList)
    -- (1) A placeholder written inside a docstring is NOT code.
    let inDoc := "  /-- It carried `:= ByteArray.empty` once. -/"
    if Tools.StubAudit.lineHasStubPattern (masked inDoc) then
      throw <| IO.userError
        "BUG: a placeholder expression inside a docstring matched as \
         code — documenting a fix trips the gate for the thing fixed"
    -- (2) ...nor is one inside a line comment.
    let inLine := "  -- proofData := ByteArray.empty"
    if Tools.StubAudit.lineHasStubPattern (masked inLine) then
      throw <| IO.userError "BUG: a line comment matched as code"
    -- (3) But the same text in CODE position still matches.  Without
    -- this the mask could be blanking everything and (1)/(2) would
    -- pass vacuously.
    let inCode := "  proofData := ByteArray.empty"
    if !Tools.StubAudit.lineHasStubPattern (masked inCode) then
      throw <| IO.userError
        "BUG: the gate no longer fires on a real placeholder body — \
         masking disarmed it"
    -- (4) A block comment spanning lines is masked throughout, not
    -- just on its opening line.
    let block := masked "/- opening\n  x := sorry\n-/\ndef f := 0"
    if Tools.StubAudit.lineHasStubPattern
        ((block.splitOn "\n").getD 1 "") then
      throw <| IO.userError
        "BUG: a block comment's interior lines were not masked"
}

/-! ## `api_stability_audit` — ascription detection -/

/-- The unascribed API-pin shape is detected and the ascribed one is
    not.

    The gate exists because CLAUDE.md's API-stability guarantee rests
    entirely on the type ascription: `let _ := @thm` elaborates against
    whatever type `thm` happens to have, so a signature change still
    passes.  A matcher that confused the two forms would either freeze
    the wrong set or block correct code. -/
def apiStabilityDetectsUnascribedPins : TestCase := {
  name := "api_stability_audit: unascribed pins detected, ascribed ones are not"
  body := do
    let broken : List String :=
      [ "        let _ := @some_theorem"
      , "let _ := @some_theorem"
      , "  let _proof := @Foo.bar_baz"
      , "        let _name := @a.b.c"
      ]
    for line in broken do
      if !Tools.ApiStabilityAudit.isUnascribedPin line then
        throw <| IO.userError
          s!"BUG: `{line}` was NOT flagged — a signature change here would \
             elaborate and the test would still report PASS"
    let fine : List String :=
      [ -- Ascribed: the whole point.
        "        let _proof : Nat → Nat := @id"
      , "        let _proof : ∀ (n : Nat), n = n := fun _ => rfl"
        -- Not an `@`-pin at all.
      , "        let x := 5"
      , "        let _ := foo bar"
        -- Not a `let` binding.
      , "        exact @some_theorem"
      , "  -- let _ := @commented_out"
      , ""
      ]
    for line in fine do
      if Tools.ApiStabilityAudit.isUnascribedPin line then
        throw <| IO.userError s!"BUG: `{line}` was flagged; it is not a broken pin"
}

/-- The allowlist key is `path:line` and omits the line text, so a
    binding that gains its ascription stops matching and one that moves
    is re-reported — the correct direction for a burn-down list. -/
def apiStabilityAllowlistKeyShape : TestCase := {
  name := "api_stability_audit: allowlist key is path:line only"
  body := do
    let v : Tools.ApiStabilityAudit.Violation :=
      { path := "LegalKernel/Test/Foo.lean", lineNo := 42, rawLine := "let _ := @bar" }
    assertEq (expected := "LegalKernel/Test/Foo.lean:42")
      (actual := Tools.ApiStabilityAudit.Violation.key v)
      "the key must not embed the line text"
}

/-- All audit-binary self-tests. -/
def tests : List TestCase :=
  [ deferralDetectsUppercaseMarkers
  , deferralAcceptsCleanContent
  , countSorriesSeesPastCharLiteral
  , namingAuditParsesAttributedDeclarations
  , namingAuditRejectsNonDeclarations
  , stubAuditFindsIndentedDocstring
  , stubAuditMasksCommentsButStillFires
  , apiStabilityDetectsUnascribedPins
  , apiStabilityAllowlistKeyShape
  ]

end LegalKernel.Test.Tools.AuditBinaries
