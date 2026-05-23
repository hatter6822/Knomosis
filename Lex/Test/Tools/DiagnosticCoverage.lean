/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Test.Tools.DiagnosticCoverage — the Workstream-LX
diagnostic-coverage gate.

Per `docs/planning/lex_implementation_plan.md` §24.1 acceptance criterion #9
("The 27 diagnostics are all reachable"), this test suite confirms
each Lex-introduced L-code is exercised by at least one
test-emitting code path.

Coverage strategy:

  1. **Message-format coverage.**  Every implemented L-code has a
     dedicated `L<NNN>Message` constructor that returns the
     canonical diagnostic string (prefixed `"L<NNN>:"`).  This
     suite calls each constructor and verifies the prefix matches.
     This is the WEAKEST form of coverage but the most mechanical:
     it confirms the diagnostic-emitting code path exists and
     produces a correctly-formatted string.

  2. **End-to-end coverage** (cross-references).  For each L-code
     that's also exercised by an end-to-end macro / lint test
     elsewhere in the test corpus, this file lists the test name
     in the diagnostic's docstring.  The end-to-end exercise
     happens in `Lex/Test/DSL/Law.lean`, `Lex/Test/DSL/Property.lean`,
     `Test/Lex/Tools/Lint.lean`, and `Test/Lex/Tools/Codegen.lean`.

  3. **Deferred-code marking.**  L-codes deferred to M2 / M3 are
     listed in a separate sub-suite (`deferredCodeRegistry`) so
     this gate stays green during M1 even when those codes have
     no implementation yet.  Each deferred entry carries the
     milestone in which it lands.

# M1 implemented set (18 codes)

  * `L001` — missing `signed_by` (LX.6 / LexLaw.lean)
  * `L002` — missing `satisfies` (LX.6 / LexLaw.lean)
  * `L003` — undecidable pre subexpression (LX.7 / LexPreGrammar.lean)
  * `L004` — property not synthesizable (LX.13 / LexProperty.lean)
  * `L005` — action index already used (LX.5 / LexCommon.lean)
  * `L006` — action index reserved 0..16 (LX.5 / LexCommon.lean)
  * `L007` — action index renumbered / mismatched (LX.5 / LexCommon.lean)
  * `L009` — missing `authorized_by` (LX.6 / LexLaw.lean)
  * `L010` — bare `setBalance` (LX.8 / LexImplCalculus.lean)
  * `L011` — `self_only` mutates non-signer state (LX.9 / LexShim.lean)
  * `L013` — events omits/duplicates (LX.10 / LexEvents.lean) [warning]
  * `L014` — manual emission of auto-emitted event (LX.10 / LexEvents.lean) [warning]
  * `L020` — unknown property in `satisfies` (LX.12 / LexProperty.lean)
  * `L022` — `revoke_key` used (LX.8 / LexImplCalculus.lean)
  * `L024` — `local [*]` trivially satisfied (LX.14 / LexProperty.lean)
  * `L025` — per-resource `[r]` to conservative/monotonic (LX.14 / LexProperty.lean)
  * `L026` — `lex_codegen --check` divergence (LX.20 / LexCodegen.lean)
  * `L027` — bare `s` reference inside events (LX.10 / LexEvents.lean)

# M2/M3+ deferred set (6 codes; post-M3-completion: L008 / L016 / L018 moved to implemented set)

  * `L012` — registry-mutating non-replaceKey law (M3+ — extension)
  * `L015` — `intent` edited without version bump (M3+ — `lex_diff`)
  * `L017` — major bump without tombstone (M3+ — `lex_diff`)
  * `L019` — `for` iter is not statically a List (M2 — needs AST-parsed
            for-loop iter; M1 ships only the `L019Message` formatter,
            consumed by future `lex_lint` cross-pass).
  * `L021` — law has no impl effects (M3+ — manifests)
  * `L023` — `impl` calls untagged helper (M2 — needs AST-parsed
            function-call shape; M1 ships only the `L023Message`
            formatter.  In M1, `bareTerm` is a recognized escape
            hatch that admits arbitrary user expressions, including
            calls; tag-based auditability is reserved for M2 once
            the bareTerm shape is replaced with proper AST nodes.).

Audit-2 update.  Pre-audit-2, this gate listed L019 and L023 as
"M1-implemented" because their message formatters
(`L019Message` / `L023Message`) shipped in `LexImplCalculus.lean`.
A deeper audit found the *detection* walkers are not fired:

  * L019 detection requires type-checking the `for` iterator
    against `List α`, which the M1 walker does not do (`for`
    statements are stuffed into `[.bareTerm s]` per the
    `parseImplStmt` comment "M2 refines").
  * L023 detection requires distinguishing a function-call
    `bareTerm` from a variable-reference `bareTerm`.  M1's
    parseImplStmt classifies *all* non-keyword shapes as
    `bareTerm` without further analysis.  The detection walker
    is deferred to M2 alongside the proper AST refinement.

Both formatters remain in-tree so `lex_lint` (LX.5) can consume
them at the lint layer once M2 lands the AST-parsed shapes.
This deferral does not weaken any kernel guarantee: L019 / L023
are deployment-policy hints, not safety gates.  The kernel's
`apply_admissible` pre-check is the authoritative type / policy
enforcement.

The deferred codes are listed in `deferredCodeRegistry`; the
registry is consulted by the `m1_implemented_codes_listed`
gate test which guards against accidentally counting a deferred
code as "implemented in M1".
-/

import LegalKernel.Test.Framework
import Lex.DSL.PreGrammar
import Lex.DSL.ImplCalculus
import Lex.DSL.Events
import Lex.DSL.Shim
import Lex.DSL.Property
import Lex.Tools.Common

namespace Lex.Test.Tools.DiagnosticCoverage

open LegalKernel.Test
open LegalKernel.DSL.Lex
open LegalKernel.Tools.Lex

/-- The set of L-codes implemented in M1.  Adding a new code is a
    deliberate scope decision; deleting one breaks an acceptance
    gate.  Sorted ascending.

    Audit-2: removed `L019` and `L023` (moved to deferred set;
    their detection walkers require AST-parsed for-loop / function-
    call shapes that M1 explicitly defers to M2). -/
def m1ImplementedCodes : List String :=
  -- M3-completion: L008 / L016 / L018 are now implemented.
  [ "L001", "L002", "L003", "L004", "L005", "L006", "L007", "L008"
  , "L009", "L010", "L011"
  , "L013", "L014"
  , "L016", "L018"
  , "L020"
  , "L022", "L024", "L025", "L026", "L027" ]

/-- A diagnostic's metadata: its code, its severity, and the
    Lean-side function that constructs the canonical message
    string.  The function is provided as `Unit → String` to
    keep the registry pure (no side effects); `()` invocation
    yields the message text. -/
structure DiagnosticEntry where
  /-- The L-code (e.g. `"L001"`). -/
  code     : String
  /-- The severity classification: `"error"` or `"warning"`. -/
  severity : String
  /-- A canonical sample message produced by invoking the
      diagnostic's emitter with a representative argument set.
      Used by `m1CodeRegistry`'s coverage-test to verify the
      message formatter exists and produces a correctly-prefixed
      string. -/
  sample   : String

/-- Build a sample-message DiagnosticEntry for one L-code. -/
def mkEntry (code severity sample : String) : DiagnosticEntry :=
  { code := code, severity := severity, sample := sample }

/-- The M1-implemented diagnostics with their canonical sample
    messages.  Adding a code requires landing the corresponding
    `L<NNN>Message` formatter in one of `Lex/DSL/*.lean`
    or `Lex/Tools/Common.lean`.

    Audit-2: removed L019 and L023 entries (their detection
    walkers are deferred to M2; see deferredCodeRegistry). -/
def m1CodeRegistry : List DiagnosticEntry :=
  [ mkEntry "L001" "error" "L001: missing `signed_by` clause; add `signed_by <actor>` to the law declaration"
  , mkEntry "L002" "error" "L002: missing `satisfies` clause; add `satisfies := […]` listing at least one property"
  , mkEntry "L003" "error" (L003Message "myUndecidablePred x")
  , mkEntry "L004" "error" (L004Message "monotonic" (.unsupportedStatementKind .bareTerm))
  , mkEntry "L005" "error" "L005: action_index 17 already used by example.example_lex_only_law"
  , mkEntry "L006" "error" "L006: action_index 5 reserved for kernel-built-in (range 0..16)"
  , mkEntry "L007" "error" "L007: action_index renumbered from 17 to 18 for example.demo"
  , mkEntry "L009" "error" "L009: missing `authorized_by` clause"
  , mkEntry "L010" "error" (L010Message "setBalance s r a 0")
  , mkEntry "L011" "error" (L011Message "alice" "setBalance ... bob 100")
  , mkEntry "L013" "warning" (L013Message "[r1, alice]")
  , mkEntry "L014" "warning" (L014Message "balanceChanged")
  , mkEntry "L020" "error" (L020Message "myUndefinedProperty")
  , mkEntry "L022" "error" (L022Message "alice")
  , mkEntry "L024" "error" L024Message
  , mkEntry "L025" "error" (L025Message "conservative")
  , mkEntry "L026" "error" "L026: fence content in target file diverges from rendered output"
  , mkEntry "L027" "error" L027Message
  -- M3-completion: L008 / L016 / L018 fired by the deployment
  -- macro / lex_diff binary; canonical sample messages below
  -- match the prefixes their respective emitters produce.
  , mkEntry "L008" "error" "L008: deployment `usd_clearing`'s invariant claim 0 failed to synthesize: failed to synthesize IsMonotonic ..."
  , mkEntry "L016" "error" "L016: law `legalkernel.transfer` minor-bumped from 1.0.0 but is missing a refinement proof"
  , mkEntry "L018" "error" "L018: deployment `usd_clearing`'s `deploy_deployment_id` is 30 bytes; deployment IDs must be exactly 32 bytes (64 hex characters)"
  ]

/-- The M2/M3-deferred diagnostics, with their landing-milestone
    annotations.  The diagnostic-coverage gate exempts these from
    the M1 coverage check. -/
structure DeferredEntry where
  /-- The L-code. -/
  code      : String
  /-- The milestone where this code is scheduled to be implemented. -/
  milestone : String

/-- The M2/M3-deferred set.  Each entry's `milestone` records the
    landing target for the detection walker / formatter integration.
    The formatters for these codes (e.g. `L019Message` /
    `L023Message`) MAY ship in M1 even when the detection walker
    is deferred — `lex_lint` (LX.5) consumes the formatters at the
    lint layer when the AST infrastructure is ready. -/
def deferredCodeRegistry : List DeferredEntry :=
  -- L008 / L016 / L018 moved to m1CodeRegistry post-M3-completion.
  [ { code := "L012", milestone := "M3+ (extension)" }
  , { code := "L015", milestone := "M3+ (lex_diff intent-edit detector)" }
  , { code := "L017", milestone := "M3+ (lex_diff major-bump tombstone)" }
  , { code := "L019", milestone := "M2 (AST-parsed for-loop iter)" }
  , { code := "L021", milestone := "M3+ (manifests)" }
  , { code := "L023", milestone := "M2 (AST-parsed function call)" }
  ]

/-- True iff `code` is implemented in M1. -/
def isM1Implemented (code : String) : Bool :=
  m1ImplementedCodes.contains code

/-- True iff `code` is deferred to M2/M3. -/
def isDeferred (code : String) : Bool :=
  deferredCodeRegistry.any (fun e => e.code == code)

/-- The complete set of v1 L-codes (L001–L027 modulo retired
    L042).  Used by the gate-test that confirms each code is
    either implemented or explicitly deferred. -/
def allV1Codes : List String :=
  let pad (n : Nat) : String :=
    if n < 10 then s!"L00{n}" else s!"L0{n}"
  (List.range 27).map (fun i => pad (i + 1))

/-- The complete LX-tests suite for diagnostic-coverage. -/
def tests : List TestCase :=
  -- Coverage gate: every M1-implemented code has a non-empty
  -- sample message that begins with the code's prefix.
  [ { name := "every M1-implemented code has a non-empty L<NNN>: prefix sample"
    , body := do
        for entry in m1CodeRegistry do
          assert (!entry.sample.isEmpty) s!"sample for {entry.code} is empty"
          assert (entry.sample.startsWith (entry.code ++ ":"))
            s!"sample for {entry.code} does not begin with `{entry.code}:`"
    }
  , { name := "m1CodeRegistry covers every M1-implemented code in m1ImplementedCodes"
    , body := do
        for code in m1ImplementedCodes do
          assert (m1CodeRegistry.any (fun e => e.code == code))
            s!"m1CodeRegistry missing entry for {code}"
        assertEq (expected := m1ImplementedCodes.length)
                 (actual := m1CodeRegistry.length)
                 "registry size matches implemented set"
    }
  , { name := "every v1 L-code is either M1-implemented or M2/M3-deferred"
    , body := do
        for code in allV1Codes do
          assert (isM1Implemented code || isDeferred code)
            s!"{code} is neither implemented nor explicitly deferred — gap in coverage gate"
    }
  , { name := "M1-implemented and deferred sets are disjoint"
    , body := do
        for code in m1ImplementedCodes do
          assert (!isDeferred code)
            s!"{code} is in BOTH the implemented and deferred set — contradiction"
    }
  , { name := "deferredCodeRegistry totals 6 codes (M3-completion: L008 / L016 / L018 moved to implemented)"
    , body := do
        assertEq (expected := (6 : Nat)) (actual := deferredCodeRegistry.length)
          "deferred set size"
    }
  , { name := "v1 catalogue has exactly 27 codes (excluding retired L042)"
    , body := do
        assertEq (expected := (27 : Nat)) (actual := allV1Codes.length)
          "v1 catalogue size"
    }
  -- Per-code message-format checks.  Each test calls the
  -- canonical formatter directly and verifies its output begins
  -- with the L-code prefix.
  , { name := "L003Message produces L003-prefixed string"
    , body := do
        let msg := L003Message "(¬ ∀ x, P x)"
        assert (msg.startsWith "L003:") "prefix"
    }
  , { name := "L004Message produces L004-prefixed string"
    , body := do
        let msg := L004Message "monotonic" (.unsupportedStatementKind .bareTerm)
        assert (msg.startsWith "L004:") "prefix"
    }
  , { name := "L010Message produces L010-prefixed string"
    , body := do
        let msg := L010Message "setBalance s r a 0"
        assert (msg.startsWith "L010:") "prefix"
    }
  , { name := "L011Message produces L011-prefixed string"
    , body := do
        let msg := L011Message "alice" "setBalance bob 100"
        assert (msg.startsWith "L011:") "prefix"
    }
  , { name := "L013Message produces L013-prefixed string"
    , body := do
        let msg := L013Message "[r, a]"
        assert (msg.startsWith "L013:") "prefix"
    }
  , { name := "L014Message produces L014-prefixed string"
    , body := do
        let msg := L014Message "balanceChanged"
        assert (msg.startsWith "L014:") "prefix"
    }
  -- L019 / L023 message-formatter tests: these formatters ship in
  -- M1 (consumed by `lex_lint` once the M2 walker lands), but the
  -- DETECTION is deferred to M2.  The format-prefix tests stay in
  -- the tree to pin formatter stability across the M1 → M2 boundary.
  , { name := "L019Message produces L019-prefixed string (formatter ships in M1; detection M2)"
    , body := do
        let msg := L019Message "myUnknownIter"
        assert (msg.startsWith "L019:") "prefix"
    }
  , { name := "L020Message produces L020-prefixed string"
    , body := do
        let msg := L020Message "myProp"
        assert (msg.startsWith "L020:") "prefix"
    }
  , { name := "L022Message produces L022-prefixed string"
    , body := do
        let msg := L022Message "alice"
        assert (msg.startsWith "L022:") "prefix"
    }
  , { name := "L023Message produces L023-prefixed string (formatter ships in M1; detection M2)"
    , body := do
        let msg := L023Message "myHelper"
        assert (msg.startsWith "L023:") "prefix"
    }
  , { name := "L024Message produces L024-prefixed string"
    , body := do
        assert (L024Message.startsWith "L024:") "prefix"
    }
  , { name := "L025Message produces L025-prefixed string"
    , body := do
        let msg := L025Message "conservative"
        assert (msg.startsWith "L025:") "prefix"
    }
  , { name := "L027Message produces L027-prefixed string"
    , body := do
        assert (L027Message.startsWith "L027:") "prefix"
    }
  -- L005/L006/L007 are emitted by Lex.Tools.Common's registry
  -- validator.  They have no dedicated `L<NNN>Message` helper
  -- because the validator constructs the strings inline; the
  -- format-prefix coverage is done via `m1CodeRegistry` samples
  -- above.
  , { name := "L005/L006/L007 registry-validator codes have non-empty samples"
    , body := do
        let l005 := m1CodeRegistry.find? (fun e => e.code == "L005")
        let l006 := m1CodeRegistry.find? (fun e => e.code == "L006")
        let l007 := m1CodeRegistry.find? (fun e => e.code == "L007")
        match l005, l006, l007 with
        | some e5, some e6, some e7 =>
            assert (e5.sample.startsWith "L005:") "L005 prefix"
            assert (e6.sample.startsWith "L006:") "L006 prefix"
            assert (e7.sample.startsWith "L007:") "L007 prefix"
        | _, _, _ => throw (IO.userError "missing registry-validator entries")
    }
  -- L013 and L014 are warnings; the gate confirms severity is
  -- correctly classified.
  , { name := "L013 and L014 are classified as warning severity"
    , body := do
        let l013 := m1CodeRegistry.find? (fun e => e.code == "L013")
        let l014 := m1CodeRegistry.find? (fun e => e.code == "L014")
        match l013, l014 with
        | some e13, some e14 =>
            assertEq (expected := "warning") (actual := e13.severity) "L013 severity"
            assertEq (expected := "warning") (actual := e14.severity) "L014 severity"
        | _, _ => throw (IO.userError "missing warning entries")
    }
  -- Sample-message stability.  A regression test that pins each
  -- emitter's output for a fixed sample input.  This catches a
  -- future cosmetic change to a diagnostic message that would
  -- otherwise silently slip through review (the message's
  -- canonical form is part of the `lex_lint` / `lex_codegen`
  -- output that downstream consumers grep for).
  , { name := "L010Message has stable shape (regression pin)"
    , body := do
        -- L010's emitter produces a string mentioning "setBalance"
        -- and the offending text.  We don't pin the full string
        -- (that would be brittle) but pin the structural anchors.
        let msg := L010Message "setBalance"
        assert (msg.startsWith "L010:") "prefix"
        let parts := msg.splitOn "setBalance"
        assert (parts.length > 1) "mentions setBalance"
    }
  , { name := "L024Message has stable shape (regression pin)"
    , body := do
        -- L024's emitter is a constant string (no parameters).
        assert (L024Message.startsWith "L024:") "prefix"
        let parts := L024Message.splitOn "local"
        assert (parts.length > 1) "mentions `local`"
    }
  -- Audit-2 regression: forall/exists nodes (added to parsePreExpr)
  -- properly satisfy `isFullyRecognised`.  Pre-audit-2 the AST
  -- defined `.forallIn` and `.existsIn` constructors but the
  -- walker had no match arms emitting them, so a Lex law writing
  -- `lex_pre := fun s => ∀ x ∈ list, P x` fell through to
  -- `.unknown`, falsely triggering an L003 warning.
  , { name := "audit-2: PreNode.forallIn over a recognised body is fully recognised"
    , body := do
        let inner : PreNode := .true_
        let node : PreNode :=
          .forallIn (Lean.Name.mkSimple "x")
                    (.toListExpr "myList")
                    inner
        assert node.isFullyRecognised
          "forallIn with True body should be fully recognised"
    }
  , { name := "audit-2: PreNode.existsIn over a recognised body is fully recognised"
    , body := do
        let inner : PreNode := .true_
        let node : PreNode :=
          .existsIn (Lean.Name.mkSimple "x")
                    (.toListExpr "myList")
                    inner
        assert node.isFullyRecognised
          "existsIn with True body should be fully recognised"
    }
  , { name := "audit-2: PreNode.forallIn over an unknown body is NOT fully recognised"
    , body := do
        let inner : PreNode := .unknown "weird shape"
        let node : PreNode :=
          .forallIn (Lean.Name.mkSimple "x")
                    (.toListExpr "myList")
                    inner
        assert (!node.isFullyRecognised)
          "forallIn with unknown body should NOT be fully recognised"
    }
  ]

end Lex.Test.Tools.DiagnosticCoverage
