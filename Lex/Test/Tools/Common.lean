/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Lex.Test.Tools.Common — runtime tests for `Lex.Tools.Common`.

LX.4 (`docs/planning/lex_implementation_plan.md` §19.3): registry parsing,
JSON round-trip, diagnostic formatting.

Tests cover:
  * Registry parser positive + negative paths.
  * Registry validator (rules 1, 4, 5, 7).
  * `LawDecl` JSON round-trip.
  * `Diagnostic` formatting.
-/

import LegalKernel.Test.Framework
import Lex.Tools.Common

namespace Lex.Test.Tools.CommonTests

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

/-- The complete LX-tests suite for `Lex.Tools.Common`. -/
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
        let leanPath : System.FilePath := "Lex/Tools/Common.lean"
        let exists? ← leanPath.pathExists
        if exists? then
          let files ← walkLeanFiles leanPath
          assertEq (expected := (1 : Nat)) (actual := files.length)
            "single-file walk returns the file itself"
        let nonLean : System.FilePath := "Lex/IndexRegistry.txt"
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
  -- Audit-3 regression: PropertyClaim codec is structurally
  -- invariant.  Pre-fix the encoder tried to parse each `args`
  -- string as JSON and embed the parsed value; the decoder then
  -- compress-ed each value back to a string.  The asymmetry
  -- caused `decode (encode x).args ≠ x.args` for raw-string
  -- args, even though the byte-encode-twice property held.
  , { name := "audit-3: PropertyClaim with raw-string args round-trips structurally"
    , body := do
        let original : PropertyClaim :=
          { name := "local", args := ["r1", "alice", "raw_string"] }
        let json := encodePropertyClaim original
        match decodePropertyClaim json with
        | .ok decoded =>
            assertEq (expected := original) (actual := decoded)
              "structural equality after encode → decode"
        | .error msg =>
            throw (IO.userError s!"decode failed: {msg}")
    }
  , { name := "audit-3: PropertyClaim empty args round-trips"
    , body := do
        let original : PropertyClaim := { name := "conservative", args := [] }
        let json := encodePropertyClaim original
        match decodePropertyClaim json with
        | .ok decoded =>
            assertEq (expected := original) (actual := decoded) "empty args"
        | .error msg =>
            throw (IO.userError s!"decode failed: {msg}")
    }
  , { name := "audit-3: PropertyClaim args containing JSON-special chars round-trip"
    , body := do
        -- Pre-fix, args containing `"`/`{`/`[` etc. would have
        -- been *parsed* as JSON, normalised, and re-emitted in
        -- a different form.  The post-fix encoder treats args
        -- as opaque strings, preserving every byte.
        let original : PropertyClaim :=
          { name := "complex", args := ["{key: value}", "[1,2,3]", "\"quoted\""] }
        let json := encodePropertyClaim original
        match decodePropertyClaim json with
        | .ok decoded =>
            assertEq (expected := original) (actual := decoded)
              "JSON-special-char preservation"
        | .error msg =>
            throw (IO.userError s!"decode failed: {msg}")
    }
  , { name := "audit-3: PropertyClaim decode rejects non-string args (audit-3 invariant)"
    , body := do
        -- Construct a JSON object with a numeric arg; decoder
        -- must reject it (audit-3 invariant: every arg must be
        -- a JSON string).
        let json : Lean.Json := Lean.Json.mkObj [
          ("name", Lean.Json.str "x"),
          ("args", Lean.Json.arr #[Lean.Json.num 42])
        ]
        match decodePropertyClaim json with
        | .error _ => pure ()  -- expected
        | .ok _ => throw (IO.userError "expected error on non-string arg")
    }
  -- Audit-3 regression: LawDecl.fromJson schema_version validation.
  , { name := "audit-3: LawDecl.fromJson rejects schema_version != 1"
    , body := do
        let invalid := "{\"schema_version\": 2, \"identifier\": \"x\"}"
        match LawDecl.fromJson invalid with
        | .error msg =>
            -- The error should mention the version.  Pre-audit
            -- the diagnostic was vague.
            let schemaParts := msg.splitOn "schema_version"
            let versionParts := msg.splitOn "version"
            assert (schemaParts.length > 1 || versionParts.length > 1)
              s!"diagnostic should reference schema_version; got: {msg}"
        | .ok _ => throw (IO.userError "expected error on bad schema_version")
    }
  -- Audit-3 regression: atomicWriteIfChanged is no-op on equal content.
  , { name := "audit-3: atomicWriteIfChanged is no-op when content matches"
    , body := do
        let testPath : System.FilePath := "/tmp/knomosis_audit3_atomic_test"
        let content := "stable bytes"
        atomicWriteIfChanged testPath content
        atomicWriteIfChanged testPath content  -- second call: no-op
        let read ← IO.FS.readFile testPath
        assertEq (expected := content) (actual := read) "content preserved"
        IO.FS.removeFile testPath
    }
  -- Audit-4 regression: BinderKind.inst variant round-trips.
  -- Pre-audit-4, the BinderKind enum had only 3 variants
  -- (explicit/implicit/strictImplicit); the macro's
  -- paramSpecsFromBinder silently dropped instance binders
  -- ([Inhabited α]) on M3 deployment-private laws.  Audit-4
  -- adds the `inst` variant so the JSON sidecar's `params`
  -- field captures every binder.
  , { name := "audit-4: BinderKind.inst encode round-trip"
    , body := do
        let kind : BinderKind := .inst
        let json := encodeBinderKind kind
        match decodeBinderKind json with
        | .ok decoded =>
          assertEq (expected := BinderKind.inst) (actual := decoded) "round-trip"
        | .error e => throw (IO.userError s!"decode failed: {e}")
    }
  , { name := "audit-4: encodeBinderKind .inst → \"inst\""
    , body := do
        match encodeBinderKind .inst with
        | Lean.Json.str "inst" => pure ()
        | other => throw (IO.userError s!"unexpected encoding: {other.compress}")
    }
  , { name := "audit-4: decodeBinderKind handles all four variants"
    , body := do
        for variant in ["explicit", "implicit", "strict_implicit", "inst"] do
          match decodeBinderKind (Lean.Json.str variant) with
          | .ok _ => pure ()
          | .error e => throw (IO.userError s!"variant {variant} failed: {e}")
    }
  -- Audit-5: verify each kernel-built-in law's `satisfies` array
  -- correctly OMITS the claims that don't apply (per plan §19.4).
  -- This is a regression test against accidentally adding wrong
  -- claims (e.g. claiming `conservative` for `mint`).
  , { name := "audit-5: mint sidecar OMITS conservative claim"
    , body := do
        let path : System.FilePath := "Lex/Inputs/legalkernel_mint.json"
        let content ← IO.FS.readFile path
        match LawDecl.fromJson content with
        | .ok decl =>
          assert (decl.satisfies.find? (fun c => c.name == "conservative") |>.isNone)
            "mint should NOT claim conservative (mint is non-conservative by design)"
        | .error e => throw (IO.userError s!"sidecar parse failed: {e}")
    }
  , { name := "audit-5: burn sidecar OMITS both conservative and monotonic"
    , body := do
        let path : System.FilePath := "Lex/Inputs/legalkernel_burn.json"
        let content ← IO.FS.readFile path
        match LawDecl.fromJson content with
        | .ok decl =>
          assert (decl.satisfies.find? (fun c => c.name == "conservative") |>.isNone)
            "burn should NOT claim conservative"
          assert (decl.satisfies.find? (fun c => c.name == "monotonic") |>.isNone)
            "burn should NOT claim monotonic"
        | .error e => throw (IO.userError s!"sidecar parse failed: {e}")
    }
  , { name := "audit-5: withdraw sidecar OMITS both conservative and monotonic"
    , body := do
        let path : System.FilePath := "Lex/Inputs/legalkernel_withdraw.json"
        let content ← IO.FS.readFile path
        match LawDecl.fromJson content with
        | .ok decl =>
          assert (decl.satisfies.find? (fun c => c.name == "conservative") |>.isNone)
            "withdraw should NOT claim conservative"
          assert (decl.satisfies.find? (fun c => c.name == "monotonic") |>.isNone)
            "withdraw should NOT claim monotonic"
        | .error e => throw (IO.userError s!"sidecar parse failed: {e}")
    }
  , { name := "audit-5: replaceKey sidecar OMITS registry_preserving"
    , body := do
        let path : System.FilePath := "Lex/Inputs/legalkernel_replaceKey.json"
        let content ← IO.FS.readFile path
        match LawDecl.fromJson content with
        | .ok decl =>
          assert (decl.satisfies.find? (fun c => c.name == "registry_preserving") |>.isNone)
            "replaceKey should NOT claim registry_preserving (mutates registry)"
        | .error e => throw (IO.userError s!"sidecar parse failed: {e}")
    }
  , { name := "audit-5: registerIdentity sidecar OMITS registry_preserving"
    , body := do
        let path : System.FilePath := "Lex/Inputs/legalkernel_registerIdentity.json"
        let content ← IO.FS.readFile path
        match LawDecl.fromJson content with
        | .ok decl =>
          assert (decl.satisfies.find? (fun c => c.name == "registry_preserving") |>.isNone)
            "registerIdentity should NOT claim registry_preserving (mutates registry)"
        | .error e => throw (IO.userError s!"sidecar parse failed: {e}")
    }
  , { name := "audit-5: transfer sidecar CLAIMS all six properties"
    , body := do
        let path : System.FilePath := "Lex/Inputs/legalkernel_transfer.json"
        let content ← IO.FS.readFile path
        match LawDecl.fromJson content with
        | .ok decl =>
          for prop in ["conservative", "monotonic", "local",
                       "freeze_preserving", "nonce_advances",
                       "registry_preserving"] do
            assert (decl.satisfies.find? (fun c => c.name == prop) |>.isSome)
              s!"transfer should claim {prop}"
        | .error e => throw (IO.userError s!"sidecar parse failed: {e}")
    }
  -- Audit-5: verify the «local» French-quoted parser path produces
  -- the unquoted name "local" in the satisfies array.
  , { name := "audit-5: «local» French-quoted form parses to name \"local\""
    , body := do
        let path : System.FilePath := "Lex/Inputs/legalkernel_transfer.json"
        let content ← IO.FS.readFile path
        match LawDecl.fromJson content with
        | .ok decl =>
          let localClaim := decl.satisfies.find? (fun c => c.name == "local")
          assert localClaim.isSome
            "transfer should have a `local` claim with the unquoted name"
          -- Negative: there should NOT be a claim with the name «local» (with quotes).
          let quoted := decl.satisfies.find? (fun c => c.name == "«local»")
          assert quoted.isNone
            "the French-quote chars must NOT appear in the JSON name"
        | .error e => throw (IO.userError s!"sidecar parse failed: {e}")
    }
  -- Audit-5: every kernel-built-in law's sidecar action_index
  -- matches the registry entry.  This is a defense-in-depth
  -- check against accidental drift.
  , { name := "audit-5: every sidecar's action_index matches its filename"
    , body := do
        let pairs : List (String × Nat) :=
          [("transfer", 0), ("mint", 1), ("burn", 2),
           ("freezeResource", 3), ("replaceKey", 4), ("reward", 5),
           ("distributeOthers", 6), ("proportionalDilute", 7),
           ("dispute", 8), ("disputeWithdraw", 9), ("verdict", 10),
           ("rollback", 11), ("registerIdentity", 12),
           ("deposit", 13), ("withdraw", 14),
           ("declareLocalPolicy", 15), ("revokeLocalPolicy", 16)]
        for (name, expectedIdx) in pairs do
          let path : System.FilePath :=
            "Lex/Inputs" / s!"legalkernel_{name}.json"
          let content ← IO.FS.readFile path
          match LawDecl.fromJson content with
          | .ok decl =>
            assertEq (expected := expectedIdx) (actual := decl.actionIndex)
              s!"{name} action_index"
            assertEq (expected := s!"legalkernel.{name}") (actual := decl.identifier)
              s!"{name} identifier"
          | .error e => throw (IO.userError s!"{name} parse failed: {e}")
    }
  -- Audit-6: cross-check `registry_effect` field per law.  M2 has
  -- exactly four laws with non-`none` registry effects (replaceKey,
  -- registerIdentity, declareLocalPolicy, revokeLocalPolicy);
  -- every other law must have `registry_effect = none`.  A
  -- regression that drops a `lex_registry_effect` clause would
  -- silently default to `none`, breaking the synthesizer's M3
  -- registry-mutation routing.  This test pins the per-law
  -- expected effect at the value level.
  , { name := "audit-6: registry_effect field correctly populated per law"
    , body := do
        let expected : List (String × LegalKernel.Tools.Lex.RegistryEffectKind) :=
          [("transfer", .none_), ("mint", .none_), ("burn", .none_),
           ("freezeResource", .none_),
           ("replaceKey", .replaceKey),
           ("reward", .none_),
           ("distributeOthers", .none_), ("proportionalDilute", .none_),
           ("dispute", .none_), ("disputeWithdraw", .none_),
           ("verdict", .none_), ("rollback", .none_),
           ("registerIdentity", .registerIdentity),
           ("deposit", .none_), ("withdraw", .none_),
           ("declareLocalPolicy", .localPolicy),
           ("revokeLocalPolicy", .localPolicy)]
        for (name, expectedKind) in expected do
          let path : System.FilePath :=
            "Lex/Inputs" / s!"legalkernel_{name}.json"
          let content ← IO.FS.readFile path
          match LawDecl.fromJson content with
          | .ok decl =>
            -- `RegistryEffectKind` is non-`DecidableEq` by default,
            -- so compare by encoded string form.
            let actualStr := match decl.registryEffect with
              | .none_            => "none"
              | .replaceKey       => "replaceKey"
              | .registerIdentity => "registerIdentity"
              | .localPolicy      => "localPolicy"
            let expectedStr := match expectedKind with
              | .none_            => "none"
              | .replaceKey       => "replaceKey"
              | .registerIdentity => "registerIdentity"
              | .localPolicy      => "localPolicy"
            assertEq (expected := expectedStr) (actual := actualStr)
              s!"{name} registry_effect mismatch (expected {expectedStr}, got {actualStr})"
          | .error e =>
            throw (IO.userError s!"{name} parse failed: {e}")
    }
  ]

end Lex.Test.Tools.CommonTests
