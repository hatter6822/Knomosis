/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.DSL.LexProperty — runtime tests for the
synthesizer-library skeleton.

LX.12 / LX.13 / LX.14 / LX.15
(`docs/lex_implementation_plan.md` §19.3): synthesizer dispatch
table.

The M1 synthesizer library ships as a skeleton: dispatch logic
is correct but emitted instance bodies are placeholder strings
that M2's codegen substitutes with canonical hand-written
shapes.  These tests exercise the dispatch correctness on
every entry of the §10.4 dispatch table.
-/

import LegalKernel.Test.Framework
import LegalKernel.DSL.LexProperty

namespace LegalKernel.Test.DSL.LexPropertyTests

open LegalKernel.Test
open LegalKernel.DSL.Lex

/-- The complete LX-tests suite for the synthesizer library. -/
def tests : List TestCase :=
  -- PropertyKind parsing.
  [ { name := "PropertyKind.ofString recognises every v1 property name"
    , body := do
        assertEq (expected := PropertyKind.conservative)
                 (actual := PropertyKind.ofString "conservative") "conservative"
        assertEq (expected := PropertyKind.monotonic)
                 (actual := PropertyKind.ofString "monotonic") "monotonic"
        assertEq (expected := PropertyKind.localTo)
                 (actual := PropertyKind.ofString "local") "local"
        assertEq (expected := PropertyKind.freezePreserving)
                 (actual := PropertyKind.ofString "freeze_preserving") "freeze_preserving"
        assertEq (expected := PropertyKind.nonceAdvances)
                 (actual := PropertyKind.ofString "nonce_advances") "nonce_advances"
        assertEq (expected := PropertyKind.registryPreserving)
                 (actual := PropertyKind.ofString "registry_preserving") "registry_preserving"
    }
  , { name := "PropertyKind.ofString routes unknown names to userDefined"
    , body := do
        assertEq (expected := PropertyKind.userDefined "KYC_compliant")
                 (actual := PropertyKind.ofString "KYC_compliant") "user-defined"
    }
  -- synth_conservative dispatch.
  , { name := "synth_conservative succeeds on empty calculus"
    , body := do
        match synth_conservative [] with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok on empty list")
    }
  , { name := "synth_conservative succeeds on flow + freeze_resource"
    , body := do
        match synth_conservative [.flow, .freezeResource] with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok on flow / freeze_resource")
    }
  , { name := "synth_conservative fails on mint"
    , body := do
        match synth_conservative [.mint] with
        | .error .nonConservativeStmt => pure ()
        | _ => throw (IO.userError "expected nonConservativeStmt on mint")
    }
  , { name := "synth_conservative fails on burn"
    , body := do
        match synth_conservative [.burn] with
        | .error .nonConservativeStmt => pure ()
        | _ => throw (IO.userError "expected nonConservativeStmt on burn")
    }
  , { name := "synth_conservative fails on bareTerm"
    , body := do
        match synth_conservative [.bareTerm] with
        | .error .bareTermOpaque => pure ()
        | _ => throw (IO.userError "expected bareTermOpaque on bareTerm")
    }
  , { name := "synth_conservative fails on for-loop (fold-of-flow)"
    , body := do
        match synth_conservative [.forLoop] with
        | .error .foldOfFlow => pure ()
        | _ => throw (IO.userError "expected foldOfFlow on for-loop")
    }
  -- synth_monotonic dispatch.
  , { name := "synth_monotonic succeeds on flow + mint + reward"
    , body := do
        match synth_monotonic [.flow, .mint, .reward] with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok on flow / mint / reward")
    }
  , { name := "synth_monotonic fails on burn"
    , body := do
        match synth_monotonic [.burn] with
        | .error .burnNotMonotonic => pure ()
        | _ => throw (IO.userError "expected burnNotMonotonic")
    }
  , { name := "synth_monotonic fails on for-loop"
    , body := do
        match synth_monotonic [.forLoop] with
        | .error .foldOfFlow => pure ()
        | _ => throw (IO.userError "expected foldOfFlow")
    }
  -- synth_local dispatch.
  , { name := "synth_local succeeds on a structurally-clean calculus"
    , body := do
        match synth_local ["7"] [.flow, .mint] with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok on flow + mint")
    }
  , { name := "synth_local fails on for-loop"
    , body := do
        match synth_local ["7"] [.forLoop] with
        | .error .foldOfFlow => pure ()
        | _ => throw (IO.userError "expected foldOfFlow on for-loop")
    }
  -- synth_freeze_preserving dispatch.
  , { name := "synth_freeze_preserving succeeds on a structurally-clean calculus"
    , body := do
        match synth_freeze_preserving ["7"] [.flow, .mint] with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok")
    }
  , { name := "synth_freeze_preserving fails on bareTerm"
    , body := do
        match synth_freeze_preserving ["7"] [.bareTerm] with
        | .error .bareTermOpaque => pure ()
        | _ => throw (IO.userError "expected bareTermOpaque")
    }
  -- synth_nonce_advances dispatch.
  , { name := "synth_nonce_advances succeeds when name matches signed_by"
    , body := do
        match synth_nonce_advances "sender" "sender" with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok on matching name")
    }
  , { name := "synth_nonce_advances fails when name mismatches signed_by (precise variant)"
    , body := do
        match synth_nonce_advances "sender" "other" with
        | .error (.nonceActorMismatch "other" "sender") => pure ()
        | .error _ => throw (IO.userError "expected nonceActorMismatch error variant")
        | .ok _ => throw (IO.userError "expected error on mismatching name")
    }
  -- synth_registry_preserving dispatch.
  , { name := "synth_registry_preserving succeeds on flow + mint + burn"
    , body := do
        match synth_registry_preserving [.flow, .mint, .burn] with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok on non-mutating calculus")
    }
  , { name := "synth_registry_preserving fails on register_key"
    , body := do
        match synth_registry_preserving [.registerKey] with
        | .error .mutatesRegistry => pure ()
        | _ => throw (IO.userError "expected mutatesRegistry")
    }
  , { name := "synth_registry_preserving fails on register_identity"
    , body := do
        match synth_registry_preserving [.registerIdentity] with
        | .error .mutatesRegistry => pure ()
        | _ => throw (IO.userError "expected mutatesRegistry")
    }
  -- Dispatcher.
  , { name := "dispatchSynthesizer routes conservative correctly"
    , body := do
        match dispatchSynthesizer .conservative "sender" [.flow] with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok")
    }
  , { name := "dispatchSynthesizer routes monotonic correctly"
    , body := do
        match dispatchSynthesizer .monotonic "sender" [.mint] with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok on mint for monotonic")
    }
  , { name := "dispatchSynthesizer routes registry_preserving correctly"
    , body := do
        match dispatchSynthesizer .registryPreserving "sender" [.registerKey] with
        | .error .mutatesRegistry => pure ()
        | _ => throw (IO.userError "expected mutatesRegistry")
    }
  ]

end LegalKernel.Test.DSL.LexPropertyTests
