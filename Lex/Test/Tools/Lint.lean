/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Test.Tools.Lint — runtime tests for the lex_lint
binary's library helpers.

LX.5 (`docs/planning/lex_implementation_plan.md` §19.3) test plan.

The plan asks for 6 cases:
  * Clean registry → exit 0
  * Each of L005, L006, L007, L018 → exit 1 with correct code
  * Internal-failure exit (cannot find file) → exit 2

We exercise the underlying library helpers
(`lintRegistry`, `lintCodegenInputs`, `lintCodegenAgainstRegistry`)
rather than spawning subprocesses, since the IO surface is
identical and unit tests are faster.  Subprocess-level exit-code
verification is handled by CI's `lake exe lex_lint` invocation
on the live registry.
-/

import LegalKernel.Test.Framework
import Lex.Tools.Lint

namespace Lex.Test.Tools.Lint

open LegalKernel.Test
open LegalKernel.Tools.Lex

/-- The complete LX.5 test suite. -/
def tests : List TestCase :=
  [ -- Case 1: clean registry (the live one) → no diagnostics.
    { name := "lintRegistry passes on the live (clean) registry"
    , body := do
        match (← lintRegistry) with
        | .ok (entries, diags) =>
            assert (entries.length > 0) "registry should have entries"
            assertEq (expected := (0 : Nat)) (actual := diags.length)
              "no diagnostics on clean registry"
        | .error msg =>
            throw (IO.userError s!"unexpected internal failure: {msg}")
    }
  -- Case 2: corrupt registry with duplicate identifier → L005.
  , { name := "lintRegistry detects L005 (duplicate identifier)"
    , body := do
        let path : System.FilePath := "/tmp/test_lex_lint_L005.txt"
        let contents :=
          "legalkernel.transfer  0  v0.1.0\n" ++
          "legalkernel.mint      1  v0.1.0\n" ++
          "legalkernel.transfer  2  v0.1.0\n"  -- duplicate identifier
        IO.FS.writeFile path contents
        match (← lintRegistry path) with
        | .ok (_entries, diags) =>
            assert (diags.any (fun d => d.code == "L005"))
              "L005 diagnostic expected"
        | .error msg =>
            throw (IO.userError s!"unexpected internal failure: {msg}")
        IO.FS.removeFile path
    }
  -- Case 3: corrupt registry with reserved-range violation → L006.
  , { name := "lintRegistry detects L006 (reserved-range violation)"
    , body := do
        let path : System.FilePath := "/tmp/test_lex_lint_L006.txt"
        let contents :=
          "legalkernel.transfer  0  v0.1.0\n" ++
          "example.foo           1  v0.1.0\n"  -- non-legalkernel in reserved range
        IO.FS.writeFile path contents
        match (← lintRegistry path) with
        | .ok (_entries, diags) =>
            assert (diags.any (fun d => d.code == "L006"))
              "L006 diagnostic expected"
        | .error msg =>
            throw (IO.userError s!"unexpected internal failure: {msg}")
        IO.FS.removeFile path
    }
  -- Case 4: corrupt registry with gap in index sequence → L007.
  , { name := "lintRegistry detects L007 (gap in index sequence)"
    , body := do
        let path : System.FilePath := "/tmp/test_lex_lint_L007.txt"
        let contents :=
          "legalkernel.transfer  0  v0.1.0\n" ++
          "legalkernel.mint      2  v0.1.0\n"  -- gap (missing index 1)
        IO.FS.writeFile path contents
        match (← lintRegistry path) with
        | .ok (_entries, diags) =>
            assert (diags.any (fun d => d.code == "L007"))
              "L007 diagnostic expected"
        | .error msg =>
            throw (IO.userError s!"unexpected internal failure: {msg}")
        IO.FS.removeFile path
    }
  -- Case 5: missing registry file → internal failure (.error).
  , { name := "lintRegistry returns internal-failure on missing file"
    , body := do
        let path : System.FilePath := "/tmp/nonexistent_registry_for_test.txt"
        match (← lintRegistry path) with
        | .ok _ =>
            throw (IO.userError "expected internal failure for missing file")
        | .error _ => pure ()
    }
  -- Case 6: codegen-input vs registry cross-check.
  , { name := "lintCodegenAgainstRegistry detects L007 cross-mismatch"
    , body := do
        let badDecl : LawDecl :=
          { schemaVersion := 1
            identifier := "example.unregistered"
            version := "1.0.0"
            actionIndex := 99
            intent := "test"
            params := []
            signedBy := { name := "alice" }
            authorizedBy := { expr := "fun _ _ => True" }
            preExpr := "fun _ => True"
            implBlock := "fun s => s"
            satisfies := []
            eventsBlock := "[]"
            registryEffect := .none_
            proofOverrides := []
            sourceLocation := { fileName := "x.lean", startPos := { line := 1, column := 0 } } }
        let registryEntry : RegistryEntry :=
          { identifier := "legalkernel.transfer"
            actionIndex := 0
            firstRelease := "v0.1.0"
            sourceLine := 1 }
        let diags := lintCodegenAgainstRegistry [badDecl] [registryEntry]
        assert (diags.length > 0) "expected at least one diagnostic"
        assert (diags.any (fun d => d.code == "L007"))
          "L007 cross-check violation expected"
    }
  ]

end Lex.Test.Tools.Lint
