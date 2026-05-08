/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.DSL.LexLaw — runtime tests for the `lexlaw` macro.

LX.6 / LX.11 (`docs/lex_implementation_plan.md` §19.3): macro
elaboration smoke tests.

The example Lex law landed at LX.21
(`LegalKernel.Laws.ExampleLex`) is the canonical test fixture
for the macro's full surface; this file ships *additional*
runtime spot-checks that exercise the macro's emitted
artefacts and the codegen-input JSON sidecar's content.
-/

import LegalKernel.Test.Framework
import LegalKernel.Laws.ExampleLex

namespace LegalKernel.Test.DSL.LexLawTests

open LegalKernel.Test
open LegalKernel.Laws.Example

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
  ]

end LegalKernel.Test.DSL.LexLawTests
