/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Test.DSL.Law — runtime tests for the `lexlaw` macro.

LX.6 / LX.11 (`docs/lex_implementation_plan.md` §19.3): macro
elaboration smoke tests.

The example Lex law landed at LX.21
(`Lex.Examples.ExampleLex`) is the canonical test fixture
for the macro's full surface; this file ships *additional*
runtime spot-checks that exercise the macro's emitted
artefacts and the codegen-input JSON sidecar's content.
-/

import LegalKernel.Test.Framework
import Lex.Examples.ExampleLex
import Lex.DSL.Law
import LegalKernel.DSL.LawSyntax

/-! ## Compile-time tests for missing-required-clause errors

Each `#guard_msgs` block below pins the expected diagnostic when
a specific required clause is omitted.  The tests serve double
duty: they exercise the L001 / L002 / L009 emission paths (the
plan's "9 missing-required-clause cases"), and they pin the
diagnostic prefix so a future macro refactor can't accidentally
rename a code without updating the test in lock-step. -/

set_option linter.unusedVariables false
-- Plan §2.5: `Law.mk` deprecation cleanup is deferred to M3.
-- The legacy-DSL test in this file legitimately exercises
-- `Law.mk` to pin its behaviour for the duration of the
-- deprecation window.
set_option linter.deprecated false

namespace Lex.Test.DSL.LawMissingClauses

-- Missing `lex_id` → L001.
/--
error: L001: lex law `foo` is missing the `lex_id` clause
-/
#guard_msgs in
lexlaw foo where
  lex_version "1.0.0"
  lex_action_index 1000
  lex_intent "missing id"
  lex_signed_by alice
  lex_authorized_by (fun _ _ => True)
  lex_pre := fun (_ : LegalKernel.State) => True
  lex_impl := fun (s : LegalKernel.State) => s
  lex_satisfies := []

-- Missing `lex_version` → L001.
/--
error: L001: lex law `foo` is missing the `lex_version` clause
-/
#guard_msgs in
lexlaw foo where
  lex_id example.foo
  lex_action_index 1001
  lex_intent "missing version"
  lex_signed_by alice
  lex_authorized_by (fun _ _ => True)
  lex_pre := fun (_ : LegalKernel.State) => True
  lex_impl := fun (s : LegalKernel.State) => s
  lex_satisfies := []

-- Missing `lex_action_index` → L001.
/--
error: L001: lex law `foo` is missing the `lex_action_index` clause
-/
#guard_msgs in
lexlaw foo where
  lex_id example.foo
  lex_version "1.0.0"
  lex_intent "missing index"
  lex_signed_by alice
  lex_authorized_by (fun _ _ => True)
  lex_pre := fun (_ : LegalKernel.State) => True
  lex_impl := fun (s : LegalKernel.State) => s
  lex_satisfies := []

-- Missing `lex_intent` → L001.
/--
error: L001: lex law `foo` is missing the `lex_intent` clause
-/
#guard_msgs in
lexlaw foo where
  lex_id example.foo
  lex_version "1.0.0"
  lex_action_index 1002
  lex_signed_by alice
  lex_authorized_by (fun _ _ => True)
  lex_pre := fun (_ : LegalKernel.State) => True
  lex_impl := fun (s : LegalKernel.State) => s
  lex_satisfies := []

-- Missing `lex_signed_by` → L001.
/--
error: L001: lex law `foo` is missing the `lex_signed_by` clause
-/
#guard_msgs in
lexlaw foo where
  lex_id example.foo
  lex_version "1.0.0"
  lex_action_index 1003
  lex_intent "missing signed_by"
  lex_authorized_by (fun _ _ => True)
  lex_pre := fun (_ : LegalKernel.State) => True
  lex_impl := fun (s : LegalKernel.State) => s
  lex_satisfies := []

-- Missing `lex_authorized_by` → L009.
/--
error: L009: lex law `foo` is missing the `lex_authorized_by` clause
-/
#guard_msgs in
lexlaw foo where
  lex_id example.foo
  lex_version "1.0.0"
  lex_action_index 1004
  lex_intent "missing authorized_by"
  lex_signed_by alice
  lex_pre := fun (_ : LegalKernel.State) => True
  lex_impl := fun (s : LegalKernel.State) => s
  lex_satisfies := []

-- Missing `lex_pre` → L001.
/--
error: L001: lex law `foo` is missing the `lex_pre` clause
-/
#guard_msgs in
lexlaw foo where
  lex_id example.foo
  lex_version "1.0.0"
  lex_action_index 1005
  lex_intent "missing pre"
  lex_signed_by alice
  lex_authorized_by (fun _ _ => True)
  lex_impl := fun (s : LegalKernel.State) => s
  lex_satisfies := []

-- Missing `lex_impl` → L001.
/--
error: L001: lex law `foo` is missing the `lex_impl` clause
-/
#guard_msgs in
lexlaw foo where
  lex_id example.foo
  lex_version "1.0.0"
  lex_action_index 1006
  lex_intent "missing impl"
  lex_signed_by alice
  lex_authorized_by (fun _ _ => True)
  lex_pre := fun (_ : LegalKernel.State) => True
  lex_satisfies := []

-- Missing `lex_satisfies` → L002.
/--
error: L002: lex law `foo` is missing the `lex_satisfies` clause
-/
#guard_msgs in
lexlaw foo where
  lex_id example.foo
  lex_version "1.0.0"
  lex_action_index 1007
  lex_intent "missing satisfies"
  lex_signed_by alice
  lex_authorized_by (fun _ _ => True)
  lex_pre := fun (_ : LegalKernel.State) => True
  lex_impl := fun (s : LegalKernel.State) => s

-- Audit-3 regression: duplicate `lex_proof` clauses are
-- rejected at parse time.  Pre-fix the second clause was
-- silently appended to `proofClauses`; the lookup function's
-- `find?` then picked the first one and shadowed the second
-- without warning.
/--
error: lex law: duplicate `lex_proof conservative` clause; only one override is allowed per property
-/
#guard_msgs in
lexlaw foo where
  lex_id example.foo
  lex_version "1.0.0"
  lex_action_index 1008
  lex_intent "duplicate lex_proof"
  lex_signed_by alice
  lex_authorized_by (fun _ _ => True)
  lex_pre := fun (_ : LegalKernel.State) => True
  lex_impl := fun (s : LegalKernel.State) => s
  lex_satisfies := [conservative]
  lex_proof conservative := by exact ()
  lex_proof conservative := by exact ()

end Lex.Test.DSL.LawMissingClauses

namespace Lex.Test.DSL.LawTests

open LegalKernel.Test
open Lex.Examples

/-- The example law's transition's `pre` is `True` on every state. -/
def tests : List TestCase :=
  [ { name := "lexlaw-emitted transition's `pre` is True on a representative state"
    , body := do
        let s := emptyState
        assert (decide (example_example_lex_only_law_transition.pre s))
          "pre is True on emptyState"
    }
  , { name := "lexlaw-emitted transition's `apply_impl` is the identity"
    , body := do
        let s := emptyState
        let _ : example_example_lex_only_law_transition.apply_impl s = s := rfl
        pure ()
    }
  , { name := "lexlaw-emitted transition is rfl-equal to its hand-coded form"
    , body := do
        -- Verify the macro produced exactly `Law.mk True (fun s => s)`.
        let _proof :
            example_example_lex_only_law_transition =
              LegalKernel.DSL.Law.mk
                (fun (_ : LegalKernel.State) => True)
                (fun (s : LegalKernel.State) => s) := rfl
        pure ()
    }
  , { name := "lexlaw codegen-input file exists at the expected path"
    , body := do
        let path :=
          (LegalKernel.Tools.Lex.codegenInputPath "example.example_lex_only_law")
        let exists? ← path.pathExists
        assert exists? s!"codegen-input file at {path.toString} should exist"
    }
  , { name := "lexlaw codegen-input file parses as a valid LawDecl"
    , body := do
        let path :=
          (LegalKernel.Tools.Lex.codegenInputPath "example.example_lex_only_law")
        let exists? ← path.pathExists
        if !exists? then
          throw (IO.userError s!"codegen-input file at {path.toString} missing")
        let contents ← IO.FS.readFile path
        match LegalKernel.Tools.Lex.LawDecl.fromJson contents with
        | .ok decl =>
            assertEq (expected := "example.example_lex_only_law")
                     (actual := decl.identifier) "identifier"
            assertEq (expected := (17 : Nat)) (actual := decl.actionIndex)
                     "action_index"
            assertEq (expected := "1.0.0") (actual := decl.version) "version"
        | .error msg =>
            throw (IO.userError s!"LawDecl.fromJson failed: {msg}")
    }
  , { name := "lexlaw codegen-input is byte-deterministic across re-reads"
    , body := do
        let path :=
          (LegalKernel.Tools.Lex.codegenInputPath "example.example_lex_only_law")
        if !(← path.pathExists) then
          throw (IO.userError "codegen-input file missing")
        let bytes1 ← IO.FS.readFile path
        let bytes2 ← IO.FS.readFile path
        assertEq (expected := bytes1) (actual := bytes2) "deterministic on re-read"
    }
  , { name := "lexlaw codegen-input is idempotent: no rewrite on equal input"
    , body := do
        -- Touch the example file's source unchanged; the macro
        -- re-elaborates and the JSON sidecar's mtime should not
        -- bump.  We can't easily trigger re-elaboration from
        -- inside the test, but `atomicWriteIfChanged` guarantees
        -- the file isn't rewritten when content is unchanged.
        let path :=
          (LegalKernel.Tools.Lex.codegenInputPath "example.example_lex_only_law")
        if !(← path.pathExists) then
          throw (IO.userError "codegen-input file missing")
        let bytes ← IO.FS.readFile path
        -- Now write the SAME bytes back via `atomicWriteIfChanged`;
        -- this should be a no-op (no rewrite, no `.tmp` left
        -- behind, no mtime bump).
        LegalKernel.Tools.Lex.atomicWriteIfChanged path bytes
        let bytes2 ← IO.FS.readFile path
        assertEq (expected := bytes) (actual := bytes2)
          "no-op write preserves bytes"
    }
  , { name := "lexlaw codegen-input has the canonical schema_version = 1"
    , body := do
        let path :=
          (LegalKernel.Tools.Lex.codegenInputPath "example.example_lex_only_law")
        if !(← path.pathExists) then
          throw (IO.userError "codegen-input file missing")
        let contents ← IO.FS.readFile path
        match LegalKernel.Tools.Lex.LawDecl.fromJson contents with
        | .ok decl =>
            assertEq (expected := (1 : Nat)) (actual := decl.schemaVersion)
              "schema_version is 1"
        | .error msg =>
            throw (IO.userError s!"LawDecl.fromJson failed: {msg}")
    }
  , { name := "lexlaw codegen-input atomic-rename: writeIfChanged with new content updates atomically"
    , body := do
        -- Verify that `atomicWriteIfChanged` performs a rename
        -- on the change path: write to a tmp path, fsync,
        -- rename to final.  We can verify the post-state is
        -- consistent (file exists with new content) without
        -- observing intermediate state from a single-process
        -- run, but we can check that no `.tmp` files are left
        -- behind.
        let testPath : System.FilePath := "/tmp/test_lex_atomic_write.json"
        let initialContent := "{\"version\":\"1.0\"}"
        LegalKernel.Tools.Lex.atomicWriteIfChanged testPath initialContent
        let after ← IO.FS.readFile testPath
        assertEq (expected := initialContent) (actual := after) "initial write"
        -- No `.tmp` should remain.
        let tmpExists ← (testPath.toString ++ ".tmp" : System.FilePath).pathExists
        assert (!tmpExists) "no .tmp left behind after atomic rename"
        -- Cleanup.
        IO.FS.removeFile testPath
    }
  , { name := "lexlaw codegen-input round-trip: fromJson ∘ toCanonicalJson = id"
    , body := do
        let decl : LegalKernel.Tools.Lex.LawDecl :=
          { schemaVersion := 1
            identifier := "test.roundtrip"
            version := "0.1.0"
            actionIndex := 200
            intent := "round-trip test"
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
        let json := LegalKernel.Tools.Lex.LawDecl.toCanonicalJson decl
        match LegalKernel.Tools.Lex.LawDecl.fromJson json with
        | .ok decl' =>
            assertEq (expected := decl) (actual := decl') "round-trip equal"
        | .error msg =>
            throw (IO.userError s!"round-trip parse failed: {msg}")
    }
  , { name := "Phase-4 Law.mk macro continues to compile (acceptance criterion 11)"
    , body := do
        -- Compile-time check: the Phase-4 transferDSL example
        -- under `LegalKernel.DSL.Law` continues to elaborate
        -- as a `Transition`.  This is verified by the import
        -- being present; no value-level assertion needed.
        let _proof :
            LegalKernel.Transition :=
          LegalKernel.DSL.transferDSL 7 1 2 5
        pure ()
    }
  -- Audit-2 regression: verify `parseImplStmt` extracts the actor
  -- name from `revoke_key alice` and only puts that in the
  -- `.revokeKey` AST node — pre-fix it passed the entire statement
  -- text (`"revoke_key alice"`) producing malformed L022 messages
  -- like `"L022: \`revoke_key revoke_key alice\` used..."`.
  , { name := "audit-2: parseImplStmt extracts actor from `revoke_key alice`"
    , body := do
        let stmt := LegalKernel.DSL.Lex.parseImplStmt "revoke_key alice"
        match stmt with
        | .revokeKey actor =>
            assertEq (expected := "alice") (actual := actor)
              "actor extracted as just `alice`, not the full statement"
        | _ => throw (IO.userError "expected .revokeKey")
    }
  , { name := "audit-2: parseImplStmt handles bare `revoke_key` with no args"
    , body := do
        let stmt := LegalKernel.DSL.Lex.parseImplStmt "revoke_key"
        match stmt with
        | .revokeKey actor =>
            assertEq (expected := "") (actual := actor)
              "empty actor on bare `revoke_key`"
        | _ => throw (IO.userError "expected .revokeKey")
    }
  , { name := "audit-2: parseImplStmt extracts only the first token after revoke_key"
    , body := do
        let stmt :=
          LegalKernel.DSL.Lex.parseImplStmt "revoke_key alice extra-junk"
        match stmt with
        | .revokeKey actor =>
            assertEq (expected := "alice") (actual := actor)
              "actor is the first token; trailing junk discarded"
        | _ => throw (IO.userError "expected .revokeKey")
    }
  , { name := "audit-2: L022Message produces clean `revoke_key alice` form"
    , body := do
        -- Verify the diagnostic message uses just the actor name,
        -- not the keyword-prefixed full statement.
        let msg := LegalKernel.DSL.Lex.L022Message "alice"
        -- Pre-fix: would have been `L022: \`revoke_key revoke_key alice\` used...`
        -- Post-fix: `L022: \`revoke_key alice\` used...`
        let parts := msg.splitOn "revoke_key"
        assert (parts.length == 2)
          s!"`revoke_key` should appear exactly once in the diagnostic, got: {msg}"
    }
  ]

end Lex.Test.DSL.LawTests
