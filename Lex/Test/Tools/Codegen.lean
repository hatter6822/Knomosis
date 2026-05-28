/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
Lex.Test.Tools.CodegenTests — runtime tests for the
`lex_codegen` audit binary's helpers.

LX.17 / LX.18 / LX.19 / LX.20 (`docs/planning/lex_implementation_plan.md`
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
import Lex.Tools.Codegen

namespace Lex.Test.Tools.CodegenTests

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

/-- The complete LX-tests suite for `Lex.Tools.Codegen`. -/
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
  -- Audit-2: advisory-lock acquire / release semantics.  Pre-fix
  -- `appendToTargetFile`'s early-return paths (e.g. on a fence-
  -- count mismatch) leaked the advisory lock, so subsequent
  -- invocations failed with "another invocation holds the lock"
  -- even when no other process was running.  The post-fix
  -- `withFileLock` wrapper releases on every exit path (success,
  -- structured error, exception).
  , { name := "audit-2: tryAcquireLock returns true on fresh path"
    , body := do
        let testPath : System.FilePath := "/tmp/knomosis_lex_test_lock_target"
        -- Cleanup any stale lock from prior test runs.
        let lockPath : System.FilePath :=
          System.FilePath.mk (testPath.toString ++ ".lex_codegen.lock")
        if (← lockPath.pathExists) then IO.FS.removeFile lockPath
        let acquired ← tryAcquireLock testPath
        assert acquired "first acquire should succeed"
        -- Cleanup.
        releaseLock testPath
        let stillLocked ← lockPath.pathExists
        assert (!stillLocked) "lock file should be removed after release"
    }
  , { name := "audit-2: tryAcquireLock returns false when lock is held"
    , body := do
        let testPath : System.FilePath := "/tmp/knomosis_lex_test_lock_target_2"
        let lockPath : System.FilePath :=
          System.FilePath.mk (testPath.toString ++ ".lex_codegen.lock")
        if (← lockPath.pathExists) then IO.FS.removeFile lockPath
        let _ ← tryAcquireLock testPath
        let secondTry ← tryAcquireLock testPath
        assert (!secondTry) "second acquire should fail while first held"
        releaseLock testPath
    }
  , { name := "audit-2: releaseLock is idempotent (missing file silently OK)"
    , body := do
        let testPath : System.FilePath := "/tmp/knomosis_lex_test_lock_target_3"
        -- Pre-condition: no lock.
        let lockPath : System.FilePath :=
          System.FilePath.mk (testPath.toString ++ ".lex_codegen.lock")
        if (← lockPath.pathExists) then IO.FS.removeFile lockPath
        -- releaseLock on an absent lock should silently succeed.
        releaseLock testPath
        pure ()
    }
  , { name := "audit-2: withFileLock releases on success path"
    , body := do
        let testPath : System.FilePath := "/tmp/knomosis_lex_test_lock_target_4"
        let lockPath : System.FilePath :=
          System.FilePath.mk (testPath.toString ++ ".lex_codegen.lock")
        if (← lockPath.pathExists) then IO.FS.removeFile lockPath
        let result ← withFileLock testPath (pure 42)
        assertEq (expected := some 42) (actual := result)
          "body ran and returned its result"
        let stillLocked ← lockPath.pathExists
        assert (!stillLocked)
          "lock file should be removed after withFileLock returns"
    }
  , { name := "audit-2: withFileLock releases on exception path"
    , body := do
        let testPath : System.FilePath := "/tmp/knomosis_lex_test_lock_target_5"
        let lockPath : System.FilePath :=
          System.FilePath.mk (testPath.toString ++ ".lex_codegen.lock")
        if (← lockPath.pathExists) then IO.FS.removeFile lockPath
        let caught ← try
          let _ ← withFileLock (α := Unit) testPath (throw (IO.userError "test error"))
          pure false
        catch _ => pure true
        assert caught "exception was propagated"
        let stillLocked ← lockPath.pathExists
        assert (!stillLocked)
          "lock file should be removed even on exception"
    }
  , { name := "audit-2: withFileLock returns none when lock is already held"
    , body := do
        let testPath : System.FilePath := "/tmp/knomosis_lex_test_lock_target_6"
        let lockPath : System.FilePath :=
          System.FilePath.mk (testPath.toString ++ ".lex_codegen.lock")
        if (← lockPath.pathExists) then IO.FS.removeFile lockPath
        -- Hold the lock externally.
        let _ ← tryAcquireLock testPath
        -- withFileLock should report contention.
        let result ← withFileLock testPath (pure 42)
        match result with
        | none => pure ()
        | some _ => throw (IO.userError "expected none on contention")
        releaseLock testPath
    }
  -- LX-M2 audit-3: emitCanonicalManifest produces a structured
  -- summary that's byte-stable on equal inputs.
  , { name := "emitCanonicalManifest produces stable output for empty input"
    , body := do
        let manifest1 := emitCanonicalManifest []
        let manifest2 := emitCanonicalManifest []
        assert (manifest1 == manifest2) "manifest output is deterministic"
    }
  , { name := "emitCanonicalManifest contains the law-count header"
    , body := do
        let manifest := emitCanonicalManifest []
        -- Must contain the canonical header preamble for downstream
        -- diff tooling to recognise the file.
        assert (manifest.startsWith "# Knomosis — Lex law canonical manifest")
          "manifest has stable header"
    }
  , { name := "emitCanonicalManifest sorts laws by action_index"
    , body := do
        let decl1 : LawDecl :=
          { schemaVersion := 1, identifier := "test.b",
            version := "v1.0.0", actionIndex := 5, intent := "second",
            params := [], signedBy := { name := "x" },
            authorizedBy := { expr := "x" },
            preExpr := "", implBlock := "",
            satisfies := [], eventsBlock := "[]",
            registryEffect := .none_, proofOverrides := [],
            sourceLocation := { fileName := "x", startPos := { line := 0, column := 0 } } }
        let decl2 : LawDecl := { decl1 with identifier := "test.a", actionIndex := 1, intent := "first" }
        -- Pass them out of order; the manifest should sort.
        let manifest := emitCanonicalManifest [decl1, decl2]
        let aPos := manifest.splitOn "test.a"
        let bPos := manifest.splitOn "test.b"
        -- "test.a" must appear before "test.b" in the output.
        assert (aPos.length > 1) "test.a appears in manifest"
        assert (bPos.length > 1) "test.b appears in manifest"
        let aPrefix := aPos.headD ""
        assert (!aPrefix.contains 'b' ||
                aPrefix.length < (bPos.headD "").length)
          "test.a appears before test.b (sorted by action_index)"
    }
  -- Audit-5: realistic-input canonical-manifest determinism.
  -- The audit-3 trivial test only exercised empty input; this
  -- test loads the actual 17 kernel-built-in law sidecars and
  -- verifies byte-stability across multiple regeneration runs.
  , { name := "audit-5: emitCanonicalManifest is byte-stable on real M2 corpus"
    , body := do
        match (← loadCodegenInputs codegenInputsDir) with
        | .ok decls =>
          assert (decls.length ≥ 17)
            s!"expected ≥ 17 codegen inputs, got {decls.length}"
          let m1 := emitCanonicalManifest decls
          let m2 := emitCanonicalManifest decls
          let m3 := emitCanonicalManifest decls
          assert (m1 == m2) "manifest is deterministic (1 vs 2)"
          assert (m2 == m3) "manifest is deterministic (2 vs 3)"
          -- Manifest is non-trivially long (more than just header).
          assert (m1.length > 1000)
            s!"manifest should be > 1000 bytes for 17 laws, got {m1.length}"
        | .error msg => throw (IO.userError s!"loadCodegenInputs: {msg}")
    }
  -- Audit-5: emitCanonicalManifest sorts by action_index even
  -- when inputs are unsorted.  Pin this property at value level:
  -- shuffle the input list and verify the output stays sorted.
  , { name := "audit-5: emitCanonicalManifest sorts even when input unsorted"
    , body := do
        match (← loadCodegenInputs codegenInputsDir) with
        | .ok decls =>
          -- Reverse the input order; manifest should produce
          -- byte-identical output.
          let m_normal := emitCanonicalManifest decls
          let m_reversed := emitCanonicalManifest decls.reverse
          assertEq (expected := m_normal) (actual := m_reversed)
            "sort is invariant under input order"
        | .error msg => throw (IO.userError s!"loadCodegenInputs: {msg}")
    }
  -- Audit-5: validateAgainstRegistry catches a corrupted sidecar.
  -- This is the lex_codegen --check failure path.  Pin at value
  -- level by constructing a synthetic decl with a wrong
  -- action_index and verifying the violation message.
  , { name := "audit-5: validateAgainstRegistry catches mismatched action_index"
    , body := do
        let decl : LawDecl :=
          { schemaVersion := 1
          , identifier := "legalkernel.transfer"
          , version := "1.0.0"
          , actionIndex := 999  -- Wrong; registry says 0.
          , intent := "synthetic"
          , params := []
          , signedBy := { name := "x" }
          , authorizedBy := { expr := "x" }
          , preExpr := ""
          , implBlock := ""
          , satisfies := []
          , eventsBlock := "[]"
          , registryEffect := .none_
          , proofOverrides := []
          , sourceLocation := { fileName := "x", startPos := { line := 0, column := 0 } }
          }
        let regContents ← IO.FS.readFile registryPath
        match parseRegistry regContents with
        | .ok entries =>
          let violations := validateAgainstRegistry [decl] entries
          assert (violations.length ≥ 1)
            "expected ≥ 1 violation for mismatched action_index"
          -- Verify the diagnostic mentions the wrong index.
          let v := violations.headD ""
          let parts := v.splitOn "999"
          assert (parts.length > 1) s!"violation should mention 999: {v}"
        | .error errs => throw (IO.userError s!"registry parse failed: {errs}")
    }
  -- Audit-5 (H1): emitCanonicalManifest must produce a totally
  -- ordered sort even when two decls share an actionIndex.  Pre-fix
  -- `Array.qsort` was the underlying sort and is NOT stable, so a
  -- corrupt input (two laws on the same frozen index — itself a
  -- registry-validity bug, but still a possible input shape) would
  -- produce non-deterministic manifest order, breaking the
  -- byte-stability claim asserted by `--check`.  The fix: tie-break
  -- on `identifier` so the order is total.
  , { name := "audit-5: emitCanonicalManifest is deterministic on shared-index input"
    , body := do
        let base : LawDecl :=
          { schemaVersion := 1, identifier := "alpha.law",
            version := "v1.0.0", actionIndex := 7, intent := "shared-index test",
            params := [], signedBy := { name := "x" },
            authorizedBy := { expr := "x" },
            preExpr := "", implBlock := "",
            satisfies := [], eventsBlock := "[]",
            registryEffect := .none_, proofOverrides := [],
            sourceLocation := { fileName := "x", startPos := { line := 0, column := 0 } } }
        let declA : LawDecl := base
        let declB : LawDecl := { base with identifier := "zeta.law" }
        let declC : LawDecl := { base with identifier := "mu.law" }
        -- All three share actionIndex = 7.  Verify the manifest output
        -- is byte-identical across three different input orderings.
        let m1 := emitCanonicalManifest [declA, declB, declC]
        let m2 := emitCanonicalManifest [declC, declB, declA]
        let m3 := emitCanonicalManifest [declB, declA, declC]
        assertEq (expected := m1) (actual := m2)
          "shared-index manifest is order-invariant (1 vs 2)"
        assertEq (expected := m2) (actual := m3)
          "shared-index manifest is order-invariant (2 vs 3)"
        -- And the secondary key is lexicographic identifier:
        -- alpha < mu < zeta, so they should appear in that order.
        let alphaIdx := (m1.splitOn "alpha.law").headD ""
        let muIdx    := (m1.splitOn "mu.law").headD ""
        let zetaIdx  := (m1.splitOn "zeta.law").headD ""
        assert (alphaIdx.length < muIdx.length)
          "alpha.law appears before mu.law in lexicographic order"
        assert (muIdx.length < zetaIdx.length)
          "mu.law appears before zeta.law in lexicographic order"
    }
  -- Audit-5: validateAgainstRegistry catches an unknown identifier.
  , { name := "audit-5: validateAgainstRegistry catches unknown identifier"
    , body := do
        let decl : LawDecl :=
          { schemaVersion := 1
          , identifier := "unknown.identifier_not_in_registry"
          , version := "1.0.0"
          , actionIndex := 999
          , intent := "synthetic"
          , params := []
          , signedBy := { name := "x" }
          , authorizedBy := { expr := "x" }
          , preExpr := ""
          , implBlock := ""
          , satisfies := []
          , eventsBlock := "[]"
          , registryEffect := .none_
          , proofOverrides := []
          , sourceLocation := { fileName := "x", startPos := { line := 0, column := 0 } }
          }
        let regContents ← IO.FS.readFile registryPath
        match parseRegistry regContents with
        | .ok entries =>
          let violations := validateAgainstRegistry [decl] entries
          assert (violations.length ≥ 1)
            "expected ≥ 1 violation for unknown identifier"
        | .error errs => throw (IO.userError s!"registry parse failed: {errs}")
    }
  -- LX.38 +4 cases (auto-generation logic).
  , { name := "LX.38: emitAutoGenLean produces non-empty output"
    , body := do
        let decls : List LawDecl := [
          { schemaVersion := 1, identifier := "legalkernel.transfer",
            version := "1.0.0", actionIndex := 0, intent := "",
            params := [], signedBy := { name := "sender" },
            authorizedBy := { expr := "" }, preExpr := "True",
            implBlock := "fun s => s",
            satisfies := [{ name := "conservative", args := [] }],
            eventsBlock := "[]", registryEffect := .none_,
            proofOverrides := [],
            sourceLocation := { fileName := "T.lean", startPos := { line := 1, column := 0 } } }
        ]
        let src := emitAutoGenLean decls
        assert (!src.isEmpty) "auto-gen output is non-empty"
        let containsTransfer :=
          (src.splitOn "legalkernel_transferConservativeProperty").length > 1
        assert containsTransfer
          "auto-gen output contains the expected test name"
    }
  , { name := "LX.38: emitAutoGenLean is deterministic on equal input"
    , body := do
        let decls : List LawDecl := [
          { schemaVersion := 1, identifier := "legalkernel.transfer",
            version := "1.0.0", actionIndex := 0, intent := "",
            params := [], signedBy := { name := "sender" },
            authorizedBy := { expr := "" }, preExpr := "True",
            implBlock := "fun s => s",
            satisfies := [{ name := "monotonic", args := [] }],
            eventsBlock := "[]", registryEffect := .none_,
            proofOverrides := [],
            sourceLocation := { fileName := "T.lean", startPos := { line := 1, column := 0 } } }
        ]
        let src1 := emitAutoGenLean decls
        let src2 := emitAutoGenLean decls
        assertEq (expected := src1) (actual := src2)
          "two emitAutoGenLean invocations on equal input must be byte-identical"
    }
  , { name := "LX.38: emitAutoGenLean records unsupported (law,property) pairs in coverage comments"
    , body := do
        let decls : List LawDecl := [
          { schemaVersion := 1, identifier := "legalkernel.transfer",
            version := "1.0.0", actionIndex := 0, intent := "",
            params := [], signedBy := { name := "sender" },
            authorizedBy := { expr := "" }, preExpr := "True",
            implBlock := "fun s => s",
            satisfies := [{ name := "nonce_advances", args := [] }],
            eventsBlock := "[]", registryEffect := .none_,
            proofOverrides := [],
            sourceLocation := { fileName := "T.lean", startPos := { line := 1, column := 0 } } }
        ]
        let src := emitAutoGenLean decls
        let containsCoverageNote :=
          (src.splitOn "out-of-scope for v1 auto-generator").length > 1
        assert containsCoverageNote
          "unsupported pair recorded in coverage notes"
    }
  , { name := "LX.38: emitAutoGenLean handles laws with no satisfies claims"
    , body := do
        let decls : List LawDecl := [
          { schemaVersion := 1, identifier := "legalkernel.transfer",
            version := "1.0.0", actionIndex := 0, intent := "",
            params := [], signedBy := { name := "sender" },
            authorizedBy := { expr := "" }, preExpr := "True",
            implBlock := "fun s => s",
            satisfies := [],  -- no claims
            eventsBlock := "[]", registryEffect := .none_,
            proofOverrides := [],
            sourceLocation := { fileName := "T.lean", startPos := { line := 1, column := 0 } } }
        ]
        let src := emitAutoGenLean decls
        assert (!src.isEmpty) "output non-empty even with no claims"
        -- Should NOT contain a per-property test for this law.
        let containsTransferTest :=
          (src.splitOn "legalkernel_transferConservativeProperty").length > 1
        assert (!containsTransferTest)
          "no test emitted for a law with no satisfies"
    }
  ]

end Lex.Test.Tools.CodegenTests
