-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Deployments.UsdClearing — Workstream-LX (M3)
acceptance tests for the worked example USD-clearing deployment.

LX.37 of `docs/planning/lex_implementation_plan.md`.

These tests verify:

  * The deployment manifest elaborates cleanly.
  * Its `deploymentId` is the expected 32-byte byte sequence.
  * Its `manifest_hash` is byte-stable across reads.
  * The `monotonic_law_set` invariant claim's `isMonotonic` field
    is provable from the per-law `IsMonotonic` instance bag.
  * The deployment's `Deployment` record is well-formed.
  * The deployment's `_admissible` predicate has the expected
    type signature.
-/

import LegalKernel.Test.Framework
import Deployments.Examples.UsdClearing

namespace LegalKernel.Test.Deployments
namespace UsdClearingTests

open LegalKernel.Test
open Deployments.Examples.UsdClearing

/-! ## Manifest record acceptance -/

/-- The deployment's `Deployment` record is constructible. -/
def manifestElaborates : TestCase := {
  name := "LX.37: usd_clearing manifest elaborates"
  body := do
    let dep := usd_clearing_deployment
    assertEq (expected := "example.usd_clearing")
             (actual := dep.identifier)
      "identifier matches deploy_id"
    assertEq (expected := "1.0.0") (actual := dep.version)
      "version matches deploy_version"
    assertEq (expected := 1) (actual := dep.resources.length)
      "resources count = 1 (USD)"
    assertEq (expected := 4) (actual := dep.laws.length)
      "laws count = 4 (Transfer, Mint, Freeze, ReplaceKey)"
}

/-- The `deploymentId` field is exactly 32 bytes. -/
def deploymentIdSize : TestCase := {
  name := "LX.37: usd_clearing deploymentId is 32 bytes"
  body := do
    let id := usd_clearing_id
    assertEq (expected := 32) (actual := id.size)
      "deploymentId is 32 bytes (256-bit binding for replay protection)"
}

/-- The `deploymentId` matches the design-doc fixture
    (`0xDEADBEEF...01234567`). -/
def deploymentIdMatchesFixture : TestCase := {
  name := "LX.37: usd_clearing deploymentId matches design-doc fixture"
  body := do
    let id := usd_clearing_id
    -- First few bytes of the canonical fixture.
    assertEq (expected := 0xDE) (actual := id.get! 0) "byte 0 = 0xDE"
    assertEq (expected := 0xAD) (actual := id.get! 1) "byte 1 = 0xAD"
    assertEq (expected := 0xBE) (actual := id.get! 2) "byte 2 = 0xBE"
    assertEq (expected := 0xEF) (actual := id.get! 3) "byte 3 = 0xEF"
    -- Last byte of the fixture.
    assertEq (expected := 0x67) (actual := id.get! 31) "byte 31 = 0x67"
}

/-- The `manifest_hash` is byte-stable across reads.  This is the
    LX.32 determinism guarantee. -/
def manifestHashByteStable : TestCase := {
  name := "LX.37: usd_clearing manifest_hash is byte-stable"
  body := do
    let h1 := usd_clearing_manifest_hash
    let h2 := usd_clearing_manifest_hash
    assertEq (expected := h1.toList) (actual := h2.toList)
      "two reads of manifest_hash byte-equal"
    assertEq (expected := 32) (actual := h1.size)
      "manifest_hash is 32 bytes"
}

/-- The `manifest_hash` field of the `Deployment` record matches
    the standalone `_manifest_hash` constant. -/
def manifestHashRecordConsistency : TestCase := {
  name := "LX.37: Deployment.manifestHashBytes = _manifest_hash"
  body := do
    let dep := usd_clearing_deployment
    let mh := usd_clearing_manifest_hash
    assertEq (expected := dep.manifestHashBytes.toList) (actual := mh.toList)
      "manifest hash consistency between Deployment record and standalone def"
}

/-! ## Invariant-claims acceptance -/

/-- The `monotonic_law_set` invariant claim's `MonotonicLawSet`
    value is constructible (i.e., elaboration succeeded — every
    named law inhabits `IsMonotonic`).  This is the LX.33
    type-level firewall acceptance check. -/
def monotonicLawSetSynthesises : TestCase := {
  name := "LX.37: monotonic_law_set claim synthesises (LX.33 firewall)"
  body := do
    -- The claim def was emitted by the macro at index 0:
    -- `usd_clearing_monotonic_law_set_0 : MonotonicLawSet`.
    let mls : LegalKernel.MonotonicLawSet :=
      usd_clearing_monotonic_law_set_0
    -- The list of laws should have 4 elements (matching the
    -- claim's argument list).
    assertEq (expected := 4) (actual := mls.laws.length)
      "MonotonicLawSet has 4 laws"
}

/-- The `MonotonicLawSet`'s `isMonotonic` field is constructible
    (verifies the typeclass-resolution at elaboration time). -/
def isMonotonicFieldConstructible : TestCase := {
  name := "LX.37: monotonic_law_set's isMonotonic witness is constructible"
  body := do
    let mls : LegalKernel.MonotonicLawSet :=
      usd_clearing_monotonic_law_set_0
    -- Can we project the witness?  (If elaboration failed,
    -- this def wouldn't exist and the build would have errored
    -- before reaching this test.)
    let _w : ∀ t ∈ mls.laws, LegalKernel.IsMonotonic t :=
      mls.isMonotonic
    pure ()
}

/-! ## Admissibility predicate acceptance -/

/-- The `_admissible` predicate has the expected type. -/
def admissiblePredicateTypeSig : TestCase := {
  name := "LX.37: _admissible predicate has expected type signature"
  body := do
    let _check :
        LegalKernel.Authority.ExtendedState →
          LegalKernel.Authority.SignedAction → Prop :=
      usd_clearing_admissible
    pure ()
}

/-! ## End-to-end smoke tests for the M3 acceptance gate -/

/-- LX.37 acceptance: every emitted def is reachable. -/
def m3AcceptanceGate : TestCase := {
  name := "LX.37: M3 acceptance gate (every emitted def is reachable)"
  body := do
    -- Touch every emitted def at least once.
    let _ := usd_clearing_deployment
    let _ := usd_clearing_id
    let _ := usd_clearing_manifest_hash
    let _ := usd_clearing_admissible
    let _ := usd_clearing_monotonic_law_set_0
    pure ()
}

/-- Audit-5: spec-faithful test of the `[all_laws]` wildcard
    expansion (LX.33).  The worked example's
    `monotonic_law_set [all_laws]` should expand to the full
    `deploy_laws` localName list.  Since synthesis succeeds
    (the deployment elaborates cleanly), we infer wildcard
    expansion produced the four wrapper laws.  This regression
    test pins the wildcard's *successful* elaboration.  The
    L008 firewall (when `Burn` would be added) is value-level
    proven by `burnNotMonotonicRegression` below. -/
def wildcardDemoElaborates : TestCase := {
  name := "audit-5: wildcard [all_laws] demo elaborates"
  body := do
    -- The wildcard claim's def is named
    -- `usd_clearing_monotonic_law_set_0` (claim index 0).
    -- Reference it to confirm elaboration succeeded.
    let _ := usd_clearing_monotonic_law_set_0
    pure ()
}

/-- Audit-5: regression for the L008 firewall foundation.
    `burn_not_monotonic` (in `Laws/Burn.lean`) is the kernel-
    level negative witness.  When a manifest writer attempts
    to add `Burn` to the deployment's `monotonic_law_set`, the
    synthesizer calls `MonotonicLawSet.cons _ _ Laws.burn rest`
    which requires synthesizing `IsMonotonic Laws.burn`.  No
    such instance exists (its absence is precisely what
    `burn_not_monotonic` proves negatively).  The synthesis
    fails with "failed to synthesize IsMonotonic Laws.burn",
    which the deployment macro converts into L008.

    This test pins the negative witness at the term level: a
    compiled proof that no monotonicity instance exists for
    burn at every parameter combination.  If a future change
    silently added the instance, this test would fail to
    elaborate. -/
def burnNotMonotonicRegression : TestCase := {
  name := "audit-5: Laws.burn lacks IsMonotonic (L008 firewall foundation)"
  body := do
    -- `LegalKernel.Laws.burn_not_monotonic` is a kernel-level
    -- theorem.  Term-level API stability check: its signature
    -- is `(r) (a) (amount) (h : amount > 0) → ¬IsMonotonic
    -- (Laws.burn r a amount)`.  Instantiating at `(0, 0, 1)`
    -- with the trivial `Nat.lt_succ_of_le (Nat.zero_le _)`
    -- proof produces a closed term witnessing the absence
    -- of the instance.  If a future change silently added
    -- `IsMonotonic Laws.burn`, this proof would no longer
    -- type-check.
    let _proof : ¬ LegalKernel.IsMonotonic (LegalKernel.Laws.burn 0 0 1) :=
      LegalKernel.Laws.burn_not_monotonic 0 0 1 (by decide)
    pure ()
}

/-- The complete LX.37 test suite. -/
def tests : List TestCase :=
  [ manifestElaborates,
    deploymentIdSize,
    deploymentIdMatchesFixture,
    manifestHashByteStable,
    manifestHashRecordConsistency,
    monotonicLawSetSynthesises,
    isMonotonicFieldConstructible,
    admissiblePredicateTypeSig,
    m3AcceptanceGate,
    wildcardDemoElaborates,
    burnNotMonotonicRegression ]

end UsdClearingTests
end LegalKernel.Test.Deployments
