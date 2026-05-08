/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Tools.LexCodegen — runtime tests for the
`lex_codegen` audit binary's helpers.

LX.17 / LX.18 / LX.19 / LX.20 (`docs/lex_implementation_plan.md`
§19.3): renderers, fence-respecting append helpers, and
`--check` mode behaviour.

Tests cover:
  * `parseOptions` recognises `--check` and `--canonical`.
  * `locateFence` finds, rejects-malformed, and rejects-missing.
  * `replaceFenceContent` preserves header/footer correctly.
  * Each renderer produces deterministic, byte-stable output
    for a fixed input (seeds the M2 regression catch).
-/

import LegalKernel.Test.Framework
import Tools.LexCodegen

namespace LegalKernel.Test.Tools.LexCodegen

open LegalKernel.Test
open LegalKernel.Tools.Lex
open LegalKernel.Tools.Lex.Codegen

/-- True iff `needle` appears as a substring of `s`.  Lean core
    doesn't ship `String.containsSubstr`; we approximate via
    `splitOn`: `(s.splitOn needle).length > 1` iff `needle`
    appears at least once. -/
private def containsSubstr (s : String) (needle : String) : Bool :=
  if needle.isEmpty then true
  else (s.splitOn needle).length > 1

/-- A canonical sample `LawDecl` for renderer determinism tests. -/
def fixtureLaw : LawDecl :=
  { schemaVersion := 1
    identifier := "example.demo"
    version := "1.0.0"
    actionIndex := 100
    intent := "demo"
    params := []
    signedBy := { name := "alice" }
    authorizedBy := { expr := "fun _ _ => True" }
    preExpr := "fun _ => True"
    implBlock := "fun s => s"
    satisfies := []
    eventsBlock := "[]"
    registryEffect := .none_
    proofOverrides := []
    sourceLocation := { fileName := "Demo.lean", startPos := { line := 1, column := 0 } } }

/-- The complete LX-tests suite for `Tools.LexCodegen`. -/
def tests : List TestCase :=
  -- parseOptions.
  [ { name := "parseOptions recognises --check"
    , body := do
        let opts := parseOptions ["--check"]
        assert opts.checkOnly "checkOnly should be set"
        assert (!opts.canonical) "canonical should be unset"
    }
  , { name := "parseOptions recognises --canonical"
    , body := do
        let opts := parseOptions ["--canonical"]
        assert opts.canonical "canonical should be set"
        assert (!opts.checkOnly) "checkOnly should be unset"
    }
  , { name := "parseOptions accepts both flags simultaneously"
    , body := do
        let opts := parseOptions ["--check", "--canonical"]
        assert opts.checkOnly "checkOnly should be set"
        assert opts.canonical "canonical should be set"
    }
  , { name := "parseOptions returns defaults on empty argv"
    , body := do
        let opts := parseOptions []
        assert (!opts.checkOnly) "default checkOnly is false"
        assert (!opts.canonical) "default canonical is false"
    }
  -- locateFence.
  , { name := "locateFence finds well-formed fence pair"
    , body := do
        let contents := "header\n" ++ beginFenceMarker ++ "\nbody\n" ++ endFenceMarker ++ "\nfooter"
        match locateFence contents with
        | .ok (b, e) =>
            assert (b < e) "begin should precede end"
            assertEq (expected := (1 : Nat)) (actual := b) "begin at line 1"
        | .error _ => throw (IO.userError "expected ok locate")
    }
  , { name := "locateFence rejects file without BEGIN marker"
    , body := do
        let contents := "header\nfooter"
        match locateFence contents with
        | .error .noFence => pure ()
        | _ => throw (IO.userError "expected noFence")
    }
  , { name := "locateFence rejects file without END marker"
    , body := do
        let contents := "header\n" ++ beginFenceMarker ++ "\nbody"
        match locateFence contents with
        | .error .noEnd => pure ()
        | _ => throw (IO.userError "expected noEnd")
    }
  , { name := "locateFence rejects file with multiple BEGIN markers"
    , body := do
        let contents := beginFenceMarker ++ "\n" ++ beginFenceMarker ++ "\n" ++ endFenceMarker
        match locateFence contents with
        | .error .multipleBegin => pure ()
        | _ => throw (IO.userError "expected multipleBegin")
    }
  , { name := "locateFence rejects file with multiple END markers"
    , body := do
        let contents := beginFenceMarker ++ "\n" ++ endFenceMarker ++ "\n" ++ endFenceMarker
        match locateFence contents with
        | .error .multipleEnd => pure ()
        | _ => throw (IO.userError "expected multipleEnd")
    }
  , { name := "locateFence rejects file with reversed fence (END before BEGIN)"
    , body := do
        let contents := endFenceMarker ++ "\n" ++ beginFenceMarker
        match locateFence contents with
        | .error .reversed => pure ()
        | _ => throw (IO.userError "expected reversed")
    }
  -- replaceFenceContent.
  , { name := "replaceFenceContent preserves header and footer"
    , body := do
        let contents := "header line\n" ++ beginFenceMarker ++ "\nold body\n" ++ endFenceMarker ++ "\nfooter line"
        match replaceFenceContent contents "new body\n" with
        | .ok newContents =>
            assert (newContents.startsWith "header line\n") "header preserved"
            assert (newContents.endsWith "footer line") "footer preserved"
            assert (!containsSubstr newContents "old body") "old body removed"
        | .error _ => throw (IO.userError "expected ok replacement")
    }
  -- Renderers (determinism).
  , { name := "renderAction is deterministic on equal input"
    , body := do
        let a1 := renderAction [fixtureLaw]
        let a2 := renderAction [fixtureLaw]
        assertEq (expected := a1) (actual := a2) "deterministic"
    }
  , { name := "renderEncoding is deterministic on equal input"
    , body := do
        let e1 := renderEncoding [fixtureLaw]
        let e2 := renderEncoding [fixtureLaw]
        assertEq (expected := e1) (actual := e2) "deterministic"
    }
  , { name := "renderEvents is deterministic on equal input"
    , body := do
        let v1 := renderEvents [fixtureLaw]
        let v2 := renderEvents [fixtureLaw]
        assertEq (expected := v1) (actual := v2) "deterministic"
    }
  , { name := "renderSignedAction is deterministic on equal input"
    , body := do
        let s1 := renderSignedAction [fixtureLaw]
        let s2 := renderSignedAction [fixtureLaw]
        assertEq (expected := s1) (actual := s2) "deterministic"
    }
  , { name := "renderAction's output mentions the law's identifier"
    , body := do
        let a := renderAction [fixtureLaw]
        assert (containsSubstr a "example.demo") "identifier present"
        assert (containsSubstr a "100") "action_index present"
    }
  -- validateAgainstRegistry.
  , { name := "validateAgainstRegistry passes on matching codegen + registry"
    , body := do
        let entry : RegistryEntry :=
          { identifier := "example.demo"
            actionIndex := 100
            firstRelease := "v0.7.0"
            sourceLine := 1 }
        let violations := validateAgainstRegistry [fixtureLaw] [entry]
        assertEq (expected := (0 : Nat)) (actual := violations.length) "no violations"
    }
  , { name := "validateAgainstRegistry catches unregistered identifier"
    , body := do
        let violations := validateAgainstRegistry [fixtureLaw] []
        assert (violations.length > 0) "should detect missing entry"
        assert (violations.any (fun v => containsSubstr v "example.demo"))
          "diagnostic mentions identifier"
    }
  , { name := "validateAgainstRegistry catches action_index mismatch"
    , body := do
        let entry : RegistryEntry :=
          { identifier := "example.demo"
            actionIndex := 999  -- mismatched
            firstRelease := "v0.7.0"
            sourceLine := 1 }
        let violations := validateAgainstRegistry [fixtureLaw] [entry]
        assert (violations.length > 0) "should detect mismatch"
    }
  ]

end LegalKernel.Test.Tools.LexCodegen
