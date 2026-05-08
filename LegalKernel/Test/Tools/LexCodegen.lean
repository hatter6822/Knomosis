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
  -- Renderers (determinism).  M1 emission policy returns `false`
  -- for every Lex law (the renderers all return `""`); these tests
  -- pin determinism + the M1 emission contract.
  , { name := "renderActionInductive is deterministic on equal input"
    , body := do
        let a1 := renderActionInductive [fixtureLaw]
        let a2 := renderActionInductive [fixtureLaw]
        assertEq (expected := a1) (actual := a2) "deterministic"
    }
  , { name := "renderCompileTransition is deterministic on equal input"
    , body := do
        let a1 := renderCompileTransition [fixtureLaw]
        let a2 := renderCompileTransition [fixtureLaw]
        assertEq (expected := a1) (actual := a2) "deterministic"
    }
  , { name := "renderActionFieldsBounded is deterministic on equal input"
    , body := do
        let e1 := renderActionFieldsBounded [fixtureLaw]
        let e2 := renderActionFieldsBounded [fixtureLaw]
        assertEq (expected := e1) (actual := e2) "deterministic"
    }
  , { name := "renderActionEncode is deterministic on equal input"
    , body := do
        let e1 := renderActionEncode [fixtureLaw]
        let e2 := renderActionEncode [fixtureLaw]
        assertEq (expected := e1) (actual := e2) "deterministic"
    }
  , { name := "renderActionDecode is deterministic on equal input"
    , body := do
        let d1 := renderActionDecode [fixtureLaw]
        let d2 := renderActionDecode [fixtureLaw]
        assertEq (expected := d1) (actual := d2) "deterministic"
    }
  , { name := "renderActionEvents is deterministic on equal input"
    , body := do
        let v1 := renderActionEvents [fixtureLaw]
        let v2 := renderActionEvents [fixtureLaw]
        assertEq (expected := v1) (actual := v2) "deterministic"
    }
  , { name := "renderApplyActionToRegistry is deterministic on equal input"
    , body := do
        let s1 := renderApplyActionToRegistry [fixtureLaw]
        let s2 := renderApplyActionToRegistry [fixtureLaw]
        assertEq (expected := s1) (actual := s2) "deterministic"
    }
  , { name := "renderNonRegistryMutating is deterministic on equal input"
    , body := do
        let s1 := renderNonRegistryMutating [fixtureLaw]
        let s2 := renderNonRegistryMutating [fixtureLaw]
        assertEq (expected := s1) (actual := s2) "deterministic"
    }
  , { name := "M1 renderers emit empty strings (skeleton scope)"
    , body := do
        -- Per the §LX.21 plan note, "no Lex declaration extends
        -- Action with a real constructor" until M2.  M1's
        -- `requiresEmission` returns `false` for every Lex law,
        -- so every renderer returns the empty string.
        assertEq (expected := "") (actual := renderActionInductive [fixtureLaw]) "actionInductive empty"
        assertEq (expected := "") (actual := renderCompileTransition [fixtureLaw]) "compileTransition empty"
        assertEq (expected := "") (actual := renderActionFieldsBounded [fixtureLaw]) "fieldsBounded empty"
        assertEq (expected := "") (actual := renderActionEncode [fixtureLaw]) "encode empty"
        assertEq (expected := "") (actual := renderActionDecode [fixtureLaw]) "decode empty"
        assertEq (expected := "") (actual := renderActionEvents [fixtureLaw]) "events empty"
        assertEq (expected := "") (actual := renderApplyActionToRegistry [fixtureLaw]) "applyActionToRegistry empty"
        assertEq (expected := "") (actual := renderNonRegistryMutating [fixtureLaw]) "nonRegistryMutating empty"
    }
  , { name := "requiresEmission returns false on every input (M1 scope)"
    , body := do
        assert (!requiresEmission fixtureLaw) "fixtureLaw"
        assertEq (expected := (0 : Nat)) (actual := (emittedDecls [fixtureLaw]).length)
          "emittedDecls is empty in M1"
    }
  , { name := "ctorOf composes lex_-prefixed underscored identifier"
    , body := do
        assertEq (expected := "lex_example_demo") (actual := ctorOf "example.demo") "dot to underscore"
        assertEq (expected := "lex_a_b_c_d") (actual := ctorOf "a.b.c.d") "multi-dot"
    }
  , { name := "transitionDefName composes _transition-suffixed name"
    , body := do
        assertEq (expected := "example_demo_transition") (actual := transitionDefName "example.demo")
          "transition def name"
    }
  -- Multi-fence locator (LX.20).
  , { name := "locateAllFences finds two fence pairs in document order"
    , body := do
        let contents := "h\n" ++ beginFenceMarker ++ "\nb1\n" ++ endFenceMarker
                      ++ "\nm\n" ++ beginFenceMarker ++ "\nb2\n" ++ endFenceMarker ++ "\nfoot"
        match locateAllFences contents with
        | .ok [(b1, e1), (b2, e2)] =>
            assert (b1 < e1) "first pair ordered"
            assert (e1 < b2) "fence 1 ends before fence 2 begins"
            assert (b2 < e2) "second pair ordered"
        | _ => throw (IO.userError "expected two fence pairs")
    }
  , { name := "locateAllFences returns empty list for fenceless file"
    , body := do
        match locateAllFences "header\nfooter" with
        | .ok [] => pure ()
        | _ => throw (IO.userError "expected empty fence list")
    }
  , { name := "locateAllFences rejects unpaired BEGIN"
    , body := do
        match locateAllFences (beginFenceMarker ++ "\nbody") with
        | .error .noEnd => pure ()
        | _ => throw (IO.userError "expected noEnd")
    }
  , { name := "locateAllFences rejects multiple BEGIN before END"
    , body := do
        match locateAllFences (beginFenceMarker ++ "\n" ++ beginFenceMarker ++ "\n" ++ endFenceMarker) with
        | .error .multipleBegin => pure ()
        | _ => throw (IO.userError "expected multipleBegin")
    }
  -- replaceFenceAt preserves indentation.
  , { name := "replaceFenceAt preserves marker indentation"
    , body := do
        let contents := "header\n  " ++ beginFenceMarker ++ "\n  body line\n  " ++ endFenceMarker ++ "\nfooter"
        match locateFence contents with
        | .ok (b, e) =>
            let rewritten := replaceFenceAt contents b e ""
            -- The BEGIN/END markers should still have their 2-space indentation.
            assert (containsSubstr rewritten ("  " ++ beginFenceMarker)) "BEGIN indentation preserved"
            assert (containsSubstr rewritten ("  " ++ endFenceMarker)) "END indentation preserved"
        | .error _ => throw (IO.userError "expected ok locate")
    }
  -- extractFenceContent.
  , { name := "extractFenceContent extracts body strictly between markers"
    , body := do
        let contents := beginFenceMarker ++ "\nbody1\nbody2\n" ++ endFenceMarker
        match locateFence contents with
        | .ok (b, e) =>
            let extracted := extractFenceContent contents b e
            assertEq (expected := "body1\nbody2") (actual := extracted) "body extracted"
        | .error _ => throw (IO.userError "expected ok locate")
    }
  , { name := "extractFenceContent on empty fence returns empty string"
    , body := do
        let contents := beginFenceMarker ++ "\n" ++ endFenceMarker
        match locateFence contents with
        | .ok (b, e) =>
            assertEq (expected := "") (actual := extractFenceContent contents b e)
              "empty fence body"
        | .error _ => throw (IO.userError "expected ok locate")
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
