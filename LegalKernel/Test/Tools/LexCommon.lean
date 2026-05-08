/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Tools.LexCommon — runtime tests for `Tools.LexCommon`.

LX.4 (`docs/lex_implementation_plan.md` §19.3): registry parsing,
JSON round-trip, diagnostic formatting.

Tests cover:
  * Registry parser positive + negative paths.
  * Registry validator (rules 1, 4, 5, 7).
  * `LawDecl` JSON round-trip.
  * `Diagnostic` formatting.
-/

import LegalKernel.Test.Framework
import Tools.LexCommon

namespace LegalKernel.Test.Tools.LexCommonTests

open LegalKernel.Test
open LegalKernel.Tools.Lex

/-- A canonical fixture: the M1 registry contents. -/
def fixtureRegistry : String :=
  "# comment\nlegalkernel.transfer            0   v0.1.0\n" ++
  "legalkernel.mint                1   v0.1.0\n"

/-- A registry with a duplicate index (to exercise rule 1 / rule 3). -/
def fixtureBadRegistry : String :=
  "legalkernel.transfer            0   v0.1.0\n" ++
  "legalkernel.mint                0   v0.1.0\n"

/-- A registry with a non-`legalkernel.*` identifier in the
    reserved range (rule 7 / L006). -/
def fixtureReservedRange : String :=
  "legalkernel.transfer  0  v0.1.0\n" ++
  "example.foo           1  v0.1.0\n"

/-- A registry with a gap in the index sequence (rule 1 / L007:
    indices must increment by 1 starting from 0). -/
def fixtureGap : String :=
  "legalkernel.transfer  0  v0.1.0\n" ++
  "legalkernel.mint      2  v0.1.0\n"

/-- A registry with out-of-order entries (rule 1 / L007: the
    declared index decreases from one row to the next). -/
def fixtureOutOfOrder : String :=
  "legalkernel.transfer  1  v0.1.0\n" ++
  "legalkernel.mint      0  v0.1.0\n"

/-- The complete LX-tests suite for `Tools.LexCommon`. -/
def tests : List TestCase :=
  [ { name := "stripWhitespace removes leading + trailing ASCII whitespace"
    , body := do
        assertEq (expected := "hello") (actual := stripWhitespace "  hello  ") "trim both sides"
        assertEq (expected := "hello") (actual := stripWhitespace "\thello\t") "trim tabs"
        assertEq (expected := "")      (actual := stripWhitespace "   ")     "all whitespace"
    }
  , { name := "parseRegistryLine parses a valid line"
    , body := do
        match parseRegistryLine 1 "legalkernel.transfer  0  v0.1.0" with
        | some (.ok e) =>
            assertEq (expected := "legalkernel.transfer") (actual := e.identifier) "ident"
            assertEq (expected := (0 : Nat)) (actual := e.actionIndex) "idx"
            assertEq (expected := "v0.1.0") (actual := e.firstRelease) "release"
        | _ => throw (IO.userError "expected ok parse")
    }
  , { name := "parseRegistryLine skips blank and comment lines"
    , body := do
        match parseRegistryLine 1 "" with
        | none => pure ()
        | _ => throw (IO.userError "expected none for blank line")
        match parseRegistryLine 1 "# this is a comment" with
        | none => pure ()
        | _ => throw (IO.userError "expected none for comment line")
    }
  , { name := "parseRegistryLine returns error for malformed input"
    , body := do
        match parseRegistryLine 5 "this is bad" with
        | some (.error _) => pure ()
        | _ => throw (IO.userError "expected error for malformed line")
    }
  , { name := "parseRegistry parses a multi-line fixture"
    , body := do
        match parseRegistry fixtureRegistry with
        | .ok entries =>
            assertEq (expected := (2 : Nat)) (actual := entries.length) "two entries"
        | .error _ => throw (IO.userError "expected ok parse")
    }
  , { name := "validateRegistry passes on a clean fixture"
    , body := do
        match parseRegistry fixtureRegistry with
        | .ok entries =>
            let violations := validateRegistry entries
            assertEq (expected := (0 : Nat)) (actual := violations.length) "no violations"
        | .error _ => throw (IO.userError "expected ok parse")
    }
  , { name := "validateRegistry detects duplicate index (rule 1 / rule 3)"
    , body := do
        match parseRegistry fixtureBadRegistry with
        | .ok entries =>
            let violations := validateRegistry entries
            assert (violations.length > 0) "duplicate-index registry should violate"
        | .error _ => throw (IO.userError "expected ok parse")
    }
  , { name := "validateRegistry rejects non-legalkernel.* in reserved range (L006 / rule 7)"
    , body := do
        match parseRegistry fixtureReservedRange with
        | .ok entries =>
            let violations := validateRegistry entries
            assert (violations.any (fun v => v.code == "L006"))
              "L006 violation expected"
        | .error _ => throw (IO.userError "expected ok parse")
    }
  , { name := "validateRegistry detects gap in index sequence (L007)"
    , body := do
        match parseRegistry fixtureGap with
        | .ok entries =>
            let violations := validateRegistry entries
            assert (violations.any (fun v => v.code == "L007"))
              "L007 gap violation expected"
            -- Verify the line number is correctly captured (line 2,
            -- where `legalkernel.mint` has index 2 instead of 1).
            assert (violations.any (fun v => v.code == "L007" && v.line == 2))
              "violation should anchor at line 2"
        | .error _ => throw (IO.userError "expected ok parse")
    }
  , { name := "validateRegistry detects out-of-order entries (L007)"
    , body := do
        match parseRegistry fixtureOutOfOrder with
        | .ok entries =>
            let violations := validateRegistry entries
            assert (violations.any (fun v => v.code == "L007"))
              "L007 out-of-order violation expected"
        | .error _ => throw (IO.userError "expected ok parse")
    }
  , { name := "Diagnostic.warning produces a warning-severity diagnostic"
    , body := do
        let d : Diagnostic :=
          Diagnostic.warning "L013"
            { fileName := "x.lean", startPos := { line := 4, column := 12 } }
            "events block omits a touched cell"
        assertEq (expected := Severity.warning) (actual := d.severity)
          "severity field is warning"
        let formatted := d.format
        assert (formatted.startsWith "x.lean:4:12: warning: L013:") "warning prefix"
    }
  , { name := "walkLeanFiles handles a non-existent directory"
    , body := do
        let files ← walkLeanFiles "/tmp/lex_nonexistent_directory_for_test"
        assertEq (expected := (0 : Nat)) (actual := files.length) "no files"
    }
  , { name := "walkLeanFiles is a single-file pass-through for a .lean file path"
    , body := do
        -- `walkLeanFiles` on a single .lean file path returns
        -- a singleton list (the file itself).  For a non-.lean
        -- path it returns the empty list.
        let leanPath : System.FilePath := "Tools/LexCommon.lean"
        let exists? ← leanPath.pathExists
        if exists? then
          let files ← walkLeanFiles leanPath
          assertEq (expected := (1 : Nat)) (actual := files.length)
            "single-file walk returns the file itself"
        let nonLean : System.FilePath := "lex_index_registry.txt"
        let exists2? ← nonLean.pathExists
        if exists2? then
          let files ← walkLeanFiles nonLean
          assertEq (expected := (0 : Nat)) (actual := files.length)
            "non-.lean file is skipped"
    }
  , { name := "Diagnostic.atSyntax helper builds a position-aware diagnostic"
    , body := do
        let fileMap : Lean.FileMap := Lean.FileMap.ofString "line 1\nline 2\n"
        -- Synthesise a `Lean.Syntax` with no position info; the
        -- helper falls back to (0, 0).
        let stx : Lean.Syntax := Lean.Syntax.atom (Lean.SourceInfo.synthetic ⟨0⟩ ⟨0⟩) "test"
        let d := Diagnostic.atSyntax "L001" .error stx fileMap "x.lean"
                   "missing clause"
        assertEq (expected := "L001") (actual := d.code) "code field"
        assertEq (expected := "x.lean") (actual := d.source.fileName) "file name"
    }
  , { name := "formatRegistry round-trips on a single entry"
    , body := do
        let entry : RegistryEntry :=
          { identifier := "legalkernel.transfer"
            actionIndex := 0
            firstRelease := "v0.1.0"
            sourceLine := 0 }
        let text := formatRegistry [entry]
        match parseRegistry text with
        | .ok entries =>
            assertEq (expected := (1 : Nat)) (actual := entries.length) "single entry"
            assertEq (expected := entry.identifier) (actual := entries.head!.identifier) "ident matches"
        | .error _ => throw (IO.userError "round-trip failed")
    }
  , { name := "Diagnostic.format produces the canonical `<file>:<line>:<col>: error: L<NNN>: <msg>` shape"
    , body := do
        let d : Diagnostic :=
          Diagnostic.error "L007"
            { fileName := "x.lean", startPos := { line := 4, column := 12 } }
            "msg"
        let formatted := d.format
        assert (formatted.startsWith "x.lean:4:12: error: L007: msg") "header shape"
    }
  , { name := "LawDecl JSON round-trip produces equal canonical bytes"
    , body := do
        let decl : LawDecl :=
          { schemaVersion := 1
            identifier := "example.foo"
            version := "1.0.0"
            actionIndex := 17
            intent := "Demo law"
            params := []
            signedBy := { name := "actor" }
            authorizedBy := { expr := "fun _ _ => True" }
            preExpr := "fun _ => True"
            implBlock := "fun s => s"
            satisfies := []
            eventsBlock := "[]"
            registryEffect := .none_
            proofOverrides := []
            sourceLocation := { fileName := "x.lean", startPos := { line := 1, column := 0 } } }
        let json1 := LawDecl.toCanonicalJson decl
        let json2 := LawDecl.toCanonicalJson decl
        assertEq (expected := json1) (actual := json2) "deterministic encoding"
        match LawDecl.fromJson json1 with
        | .ok decl' =>
            assertEq (expected := decl.identifier) (actual := decl'.identifier) "round-trip ident"
            assertEq (expected := decl.actionIndex) (actual := decl'.actionIndex) "round-trip idx"
            assertEq (expected := decl.version) (actual := decl'.version) "round-trip ver"
        | .error _ => throw (IO.userError "round-trip parse failed")
    }
  , { name := "codegenInputFileName replaces dots with underscores"
    , body := do
        assertEq (expected := "legalkernel_transfer.json")
                 (actual   := codegenInputFileName "legalkernel.transfer")
                 "transfer file name"
        assertEq (expected := "example_example_lex_only_law.json")
                 (actual   := codegenInputFileName "example.example_lex_only_law")
                 "example file name"
    }
  , { name := "codegenInputPath joins under the canonical directory"
    , body := do
        let path := codegenInputPath "legalkernel.transfer"
        assert (path.toString.endsWith "legalkernel_transfer.json") "path suffix"
    }
  ]

end LegalKernel.Test.Tools.LexCommonTests
