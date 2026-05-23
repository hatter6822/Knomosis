/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Test.DSL.Property — runtime tests for the
synthesizer-library skeleton.

LX.12 / LX.13 / LX.14 / LX.15
(`docs/planning/lex_implementation_plan.md` §19.3): synthesizer dispatch
table.

The M1 synthesizer library ships as a skeleton: dispatch logic
is correct but emitted instance bodies are placeholder strings
that M2's codegen substitutes with canonical hand-written
shapes.  These tests exercise the dispatch correctness on
every entry of the §10.4 dispatch table.
-/

import LegalKernel.Test.Framework
import Lex.DSL.Property

namespace Lex.Test.DSL.PropertyTests

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
  , { name := "synth_conservative fails on reward (audit-2 regression)"
    , body := do
        -- Audit-2 finding: pre-fix the test suite had no explicit
        -- test for `reward` rejection by `synth_conservative`,
        -- relying only on the `mint` and `burn` cases.  A regression
        -- in `buildConservativeProof` could have silently let
        -- `reward` through.  This test pins the rejection.
        match synth_conservative [.reward] with
        | .error .nonConservativeStmt => pure ()
        | _ => throw (IO.userError "expected nonConservativeStmt on reward")
    }
  -- Audit-3 regressions: distinct error variants per condition.
  , { name := "audit-3: synth_freeze_preserving fires resourceInFreezeSet (not resourceNotInLocalSet)"
    , body := do
        -- Pre-fix this returned `.resourceNotInLocalSet`, whose
        -- diagnostic message references the `local` set even
        -- though the failing claim was `freeze_preserving`.
        match synth_freeze_preserving ["r1"] [(.flow, some "r1")] with
        | .error (.resourceInFreezeSet "r1") => pure ()
        | .error other =>
            throw (IO.userError s!"expected resourceInFreezeSet r1; got {repr other}")
        | _ => throw (IO.userError "expected error")
    }
  , { name := "audit-3: synth_nonce_advances rejects empty signed-by name"
    , body := do
        -- Pre-fix, an empty `signedByName` and empty `actorName`
        -- both equal "" and the function returned .ok — silently
        -- discharging the claim despite no valid lex_signed_by.
        match synth_nonce_advances "" "alice" with
        | .error (.emptySignedBy "alice") => pure ()
        | .error other =>
            throw (IO.userError s!"expected emptySignedBy alice; got {repr other}")
        | _ => throw (IO.userError "expected error on empty signedBy")
    }
  , { name := "audit-3: synth_nonce_advances rejects empty-vs-empty (was false-success pre-fix)"
    , body := do
        match synth_nonce_advances "" "" with
        | .error (.emptySignedBy "") => pure ()
        | .ok _ =>
            throw (IO.userError "pre-audit-3 false-success regressed: empty-vs-empty must NOT succeed")
        | _ => throw (IO.userError "expected emptySignedBy")
    }
  , { name := "audit-3: dispatchSynthesizer fires userDefinedNoOverride on user property"
    , body := do
        -- Pre-fix this returned `.unsupportedStatementKind .bareTerm`
        -- (a domain-mismatched error variant).  Now it correctly
        -- carries the user-property name in `.userDefinedNoOverride`.
        match dispatchSynthesizer (.userDefined "MyProp") "alice" [] with
        | .error (.userDefinedNoOverride "MyProp") => pure ()
        | .error other =>
            throw (IO.userError s!"expected userDefinedNoOverride MyProp; got {repr other}")
        | _ => throw (IO.userError "expected error")
    }
  , { name := "audit-3: SynthError.toString for resourceInFreezeSet mentions freeze"
    , body := do
        let msg := SynthError.toString (.resourceInFreezeSet "r1")
        let parts := msg.splitOn "freeze"
        assert (parts.length > 1)
          s!"diagnostic should mention freeze; got: {msg}"
    }
  , { name := "audit-3: SynthError.toString for emptySignedBy mentions lex_signed_by"
    , body := do
        let msg := SynthError.toString (.emptySignedBy "alice")
        let parts := msg.splitOn "lex_signed_by"
        assert (parts.length > 1)
          s!"diagnostic should mention lex_signed_by; got: {msg}"
    }
  , { name := "audit-3: SynthError.toString for userDefinedNoOverride mentions lex_proof"
    , body := do
        let msg := SynthError.toString (.userDefinedNoOverride "Foo")
        let parts := msg.splitOn "lex_proof"
        assert (parts.length > 1)
          s!"diagnostic should mention lex_proof override; got: {msg}"
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
  -- AR.11 / M+2: post-AR, synth_local_kindOnly REFUSES to admit
  -- resource-bearing statements without resource info.  The
  -- "structurally-clean calculus" test now exercises the strict
  -- rejection path; callers with resource info should use
  -- `synth_local` (the resource-aware entry) directly.
  , { name := "synth_local_kindOnly rejects resource-bearing statements without resource info"
    , body := do
        match synth_local_kindOnly ["7"] [.flow, .mint] with
        | .error (.resourceNotInLocalSet "<unknown>") => pure ()
        | _ => throw (IO.userError "expected .resourceNotInLocalSet <unknown> on kind-only flow")
    }
  , { name := "synth_local_kindOnly accepts registry-only statements"
    , body := do
        -- registry / freeze statements don't carry a resource, so
        -- they're correctly admitted by the kind-only synthesizer.
        match synth_local_kindOnly ["7"] [.registerKey, .freezeResource] with
        | .ok _ => pure ()
        | .error e => throw (IO.userError s!"expected ok on registry-only stmts, got {repr e}")
    }
  , { name := "synth_local fails on for-loop"
    , body := do
        match synth_local_kindOnly ["7"] [.forLoop] with
        | .error .foldOfFlow => pure ()
        | _ => throw (IO.userError "expected foldOfFlow on for-loop")
    }
  -- LX.14: resource-aware synth_local checks.
  , { name := "synth_local rejects flow with resource outside the local set"
    , body := do
        let stmts : List (ImplStmtKind × Option String) :=
          [(.flow, some "7")]
        match synth_local ["3"] stmts with
        | .error (.resourceNotInLocalSet "7") => pure ()
        | .error _ => throw (IO.userError "expected resourceNotInLocalSet 7")
        | .ok _ => throw (IO.userError "expected error on out-of-set resource")
    }
  , { name := "synth_local accepts flow with resource in the local set"
    , body := do
        let stmts : List (ImplStmtKind × Option String) :=
          [(.flow, some "7"), (.mint, some "7")]
        match synth_local ["7"] stmts with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok with all resources in set")
    }
  , { name := "synth_freeze_preserving rejects flow at a frozen resource"
    , body := do
        let stmts : List (ImplStmtKind × Option String) :=
          [(.flow, some "5")]
        match synth_freeze_preserving ["5"] stmts with
        | .error _ => pure ()
        | .ok _ => throw (IO.userError "expected error: resource is frozen")
    }
  , { name := "synth_freeze_preserving accepts flow at non-frozen resource"
    , body := do
        let stmts : List (ImplStmtKind × Option String) :=
          [(.flow, some "7"), (.mint, some "7")]
        match synth_freeze_preserving ["3", "5"] stmts with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok: r=7 not in freeze set")
    }
  -- synth_freeze_preserving dispatch.
  , { name := "synth_freeze_preserving succeeds on a structurally-clean calculus"
    , body := do
        match synth_freeze_preserving_kindOnly ["7"] [.flow, .mint] with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok")
    }
  , { name := "synth_freeze_preserving fails on bareTerm"
    , body := do
        match synth_freeze_preserving_kindOnly ["7"] [.bareTerm] with
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
  -- LX.15: more synth_nonce_advances + synth_registry_preserving tests.
  , { name := "synth_nonce_advances accepts an exact match"
    , body := do
        match synth_nonce_advances "alice" "alice" with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok on exact match")
    }
  , { name := "synth_registry_preserving accepts an empty calculus"
    , body := do
        match synth_registry_preserving [] with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected ok on empty calculus")
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
  -- LX.16: override mechanism.
  , { name := "lookupProofOverride finds a matching override"
    , body := do
        let overrides : List LegalKernel.Tools.Lex.ProofOverride :=
          [{ property := "monotonic", tacticBlock := "exact distributeOthers_isMonotonic _ _ _" }]
        match lookupProofOverride overrides "monotonic" with
        | some src =>
            assert (src.length > 0) "override source non-empty"
        | none => throw (IO.userError "expected override hit")
    }
  , { name := "lookupProofOverride returns none on miss"
    , body := do
        let overrides : List LegalKernel.Tools.Lex.ProofOverride :=
          [{ property := "monotonic", tacticBlock := "..." }]
        match lookupProofOverride overrides "conservative" with
        | none => pure ()
        | some _ => throw (IO.userError "expected miss")
    }
  , { name := "dispatchWithOverrides bypasses synthesizer when an override is present"
    , body := do
        -- Without an override, synth_conservative on `[burn]`
        -- fails L004.  WITH an override, the dispatcher emits
        -- the override and returns ok.
        let stmts : List ImplStmtKind := [.burn]
        let overrides : List LegalKernel.Tools.Lex.ProofOverride :=
          [{ property := "conservative", tacticBlock := "by sorry" }]
        match dispatchWithOverrides .conservative "conservative" overrides
                "alice" stmts with
        | .ok _ => pure ()
        | .error _ => throw (IO.userError "expected override to bypass synth")
    }
  , { name := "dispatchWithOverrides falls through when no override is present"
    , body := do
        let stmts : List ImplStmtKind := [.burn]
        match dispatchWithOverrides .conservative "conservative" [] "alice" stmts with
        | .error .nonConservativeStmt => pure ()
        | _ => throw (IO.userError "expected synth fail without override")
    }
  -- AR.11 / M+2: resource-aware dispatcher tests.
  , { name := "dispatchSynthesizerResourceAware admits local-claim with in-set resource"
    , body := do
        let stmts : List (ImplStmtKind × Option String) :=
          [(.flow, some "7"), (.mint, some "7")]
        match dispatchSynthesizerResourceAware .localTo "sender" stmts
                (localSet := ["7"]) with
        | .ok _ => pure ()
        | .error e => throw (IO.userError s!"expected ok for local [7] over flow@7, got {repr e}")
    }
  , { name := "dispatchSynthesizerResourceAware rejects local-claim with out-of-set resource"
    , body := do
        let stmts : List (ImplStmtKind × Option String) :=
          [(.flow, some "8")]  -- targets resource 8
        match dispatchSynthesizerResourceAware .localTo "sender" stmts
                (localSet := ["7"]) with  -- local set is {7}
        | .error (.resourceNotInLocalSet "8") => pure ()
        | _ => throw (IO.userError "expected resourceNotInLocalSet 8")
    }
  , { name := "dispatchSynthesizerResourceAware routes conservative/monotonic identically"
    , body := do
        let stmts : List (ImplStmtKind × Option String) := [(.flow, some "7")]
        match dispatchSynthesizerResourceAware .conservative "sender" stmts with
        | .ok _ => pure ()
        | .error e => throw (IO.userError s!"conservative should pass on flow, got {repr e}")
    }
  -- LX.12: parsePropertyList.
  , { name := "parsePropertyList recognises built-in names as ParsedProperty.ok"
    , body := do
        let env : Lean.Environment ← Lean.mkEmptyEnvironment
        let parsed := parsePropertyList env ["conservative", "monotonic", "registry_preserving"]
        assertEq (expected := (3 : Nat)) (actual := parsed.length) "3 entries"
        for p in parsed do
          match p with
          | .ok _ => pure ()
          | _ => throw (IO.userError "expected all .ok")
    }
  , { name := "parsePropertyList rejects `local [*]` wildcard with L024"
    , body := do
        let env : Lean.Environment ← Lean.mkEmptyEnvironment
        let parsed := parsePropertyList env ["local[*]"]
        match parsed.head? with
        | some .wildcardLocal => pure ()
        | _ => throw (IO.userError "expected wildcardLocal")
    }
  , { name := "parsePropertyList rejects per-resource arg on conservative (L025)"
    , body := do
        let env : Lean.Environment ← Lean.mkEmptyEnvironment
        let parsed := parsePropertyList env ["conservative[r]"]
        match parsed.head? with
        | some (.perResourceOnConservativeOrMonotonic _) => pure ()
        | _ => throw (IO.userError "expected perResourceOnConservativeOrMonotonic")
    }
  , { name := "parsePropertyList flags untagged user names as unknownName (L020)"
    , body := do
        let env : Lean.Environment ← Lean.mkEmptyEnvironment
        let parsed := parsePropertyList env ["KYC_compliant"]
        match parsed.head? with
        | some (.unknownName "KYC_compliant") => pure ()
        | _ => throw (IO.userError "expected unknownName for untagged user property")
    }
  , { name := "dispatchSynthesizer routes registry_preserving correctly"
    , body := do
        match dispatchSynthesizer .registryPreserving "sender" [.registerKey] with
        | .error .mutatesRegistry => pure ()
        | _ => throw (IO.userError "expected mutatesRegistry")
    }
  ]

end Lex.Test.DSL.PropertyTests
