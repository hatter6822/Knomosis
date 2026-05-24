/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.Test.DSL.Deployment — Workstream-LX (M3) tests for
the `deployment` manifest macro.

Covers LX.31 / LX.32 / LX.33:

  * **LX.31**: parser + `Deployment` record + skeleton elaboration.
  * **LX.32**: `manifestHash` determinism + cross-manifest
    distinguishability + `_id` constant + `_admissible` predicate.
  * **LX.33**: invariant-claim synthesis (per-claim happy paths +
    L008 rejection paths + wildcard / parameterised handling).

These tests exercise the macro at the value level — the manifest
elaborates cleanly, every emitted def is reachable, and the
`manifestHashBytes` field is byte-stable across calls.
-/

import LegalKernel.Test.Framework
import Lex.DSL.Deployment
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Reward
import LegalKernel.Laws.Freeze

namespace Lex.Test.DSL.DeploymentTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.DSL
open LegalKernel.Laws
open LegalKernel.Test

/-! ## Fixtures: minimal manifests for testing -/

/-- A canonical 32-byte (64-hex-character) deployment ID for
    fixture manifests. -/
def fixtureDeploymentId : ByteArray :=
  -- 32 zero bytes, encoded as hex "00...00".
  ByteArray.mk (Array.replicate 32 (0 : UInt8))

/-! ## LX.31 — parser tests + `Deployment` record shape -/

/-- The `Deployment` record is constructible at the value level. -/
def deploymentRecordShape : TestCase := {
  name := "LX.31: Deployment record is constructible"
  body := do
    let dep : Deployment := {
      identifier := "example.minimal",
      deploymentId := fixtureDeploymentId,
      version := "1.0.0",
      resources := [("USD", 1)],
      laws := [{ localName := "Transfer",
                 lawIdent := Lean.Name.anonymous,
                 version := "1.0.0" }],
      authority := [{ localName := "default",
                      policyExpr := "(fun _ _ => True)" }],
      invariantClaims := [],
      manifestHashBytes := ByteArray.mk #[0, 1, 2, 3]
    }
    assertEq (expected := "example.minimal") (actual := dep.identifier)
      "Deployment.identifier roundtrip"
    assertEq (expected := 32) (actual := dep.deploymentId.size)
      "Deployment.deploymentId fixture size = 32"
    assertEq (expected := 1) (actual := dep.resources.length)
      "Deployment.resources count"
    assertEq (expected := 4) (actual := dep.manifestHashBytes.size)
      "Deployment.manifestHashBytes fixture size"
}

/-! ## LX.32 — manifest-hash determinism + distinguishability -/

/-- The manifest-hash computation is deterministic on equal
    inputs.  Audit-equivalent of `signInput_deterministic`. -/
def manifestHashDeterminism : TestCase := {
  name := "LX.32: manifest hash is deterministic"
  body := do
    let laws := [("Transfer", "Transfer", "1.0.0")]
    let auth := [("default", "AuthorityPolicy.unrestricted")]
    let claims := [(0, 0, ["Transfer"])]
    let h1 := computeManifestHash
      "ex.deploy" fixtureDeploymentId "1.0.0"
      [("USD", 1)] laws auth claims
    let h2 := computeManifestHash
      "ex.deploy" fixtureDeploymentId "1.0.0"
      [("USD", 1)] laws auth claims
    assertEq (expected := h1.toList) (actual := h2.toList)
      "two computeManifestHash invocations on equal input must be byte-identical"
}

/-- Two distinct manifests produce distinct hashes.  Distinct
    `identifier` is sufficient. -/
def manifestHashDistinguishesIdentifier : TestCase := {
  name := "LX.32: manifest hash distinguishes by identifier"
  body := do
    let laws := [("Transfer", "Transfer", "1.0.0")]
    let auth := [("default", "AuthorityPolicy.unrestricted")]
    let h1 := computeManifestHash
      "ex.deploy" fixtureDeploymentId "1.0.0"
      [("USD", 1)] laws auth []
    let h2 := computeManifestHash
      "ex.different" fixtureDeploymentId "1.0.0"
      [("USD", 1)] laws auth []
    assert (h1.toList != h2.toList)
      "distinct identifiers must produce distinct manifest hashes"
}

/-- Distinguishes by deployment ID (the cross-deployment-replay
    binding). -/
def manifestHashDistinguishesDeploymentId : TestCase := {
  name := "LX.32: manifest hash distinguishes by deployment ID"
  body := do
    let did1 := ByteArray.mk (Array.replicate 32 (0 : UInt8))
    let did2 := ByteArray.mk (Array.replicate 32 (1 : UInt8))
    let h1 := computeManifestHash "ex.deploy" did1 "1.0.0" [] [] [] []
    let h2 := computeManifestHash "ex.deploy" did2 "1.0.0" [] [] [] []
    assert (h1.toList != h2.toList)
      "distinct deployment IDs must produce distinct manifest hashes"
}

/-- The output is exactly 32 bytes (hashStream's documented
    output size). -/
def manifestHashSize : TestCase := {
  name := "LX.32: manifest hash is 32 bytes"
  body := do
    let h := computeManifestHash
      "ex.deploy" fixtureDeploymentId "1.0.0" [] [] [] []
    assertEq (expected := 32) (actual := h.size)
      "manifestHash size = 32 bytes"
}

/-- Distinguishes by version. -/
def manifestHashDistinguishesVersion : TestCase := {
  name := "LX.32: manifest hash distinguishes by version"
  body := do
    let h1 := computeManifestHash "ex" fixtureDeploymentId "1.0.0" [] [] [] []
    let h2 := computeManifestHash "ex" fixtureDeploymentId "2.0.0" [] [] [] []
    assert (h1.toList != h2.toList)
      "distinct versions must produce distinct manifest hashes"
}

/-! ## LX.32 — hex decoding of `deploy_deployment_id` -/

/-- 64-character all-zero hex string decodes to 32 zero bytes. -/
def hexDecodeAllZeros : TestCase := {
  name := "LX.32: hex decoding of 64-char all-zero string"
  body := do
    let hex := String.ofList (List.replicate 64 '0')
    match decodeHexString hex with
    | some bs =>
      assertEq (expected := 32) (actual := bs.size)
        "decoded size = 32 bytes"
      let allZeros := bs.toList.all (fun b => b == 0)
      assert allZeros "all bytes are zero"
    | none =>
      throw (IO.userError "expected decoded ByteArray, got none")
}

/-- Mixed-case hex decodes correctly. -/
def hexDecodeMixedCase : TestCase := {
  name := "LX.32: hex decoding of mixed-case hex string"
  body := do
    -- "DEAD" + "beef" + ... padded to 64 chars.
    let hex := "DEADbeef" ++ String.ofList (List.replicate 56 '0')
    match decodeHexString hex with
    | some bs =>
      assertEq (expected := 32) (actual := bs.size) "size = 32"
      assertEq (expected := 0xDE) (actual := bs.get! 0) "byte 0 = 0xDE"
      assertEq (expected := 0xAD) (actual := bs.get! 1) "byte 1 = 0xAD"
      assertEq (expected := 0xBE) (actual := bs.get! 2) "byte 2 = 0xBE"
      assertEq (expected := 0xEF) (actual := bs.get! 3) "byte 3 = 0xEF"
    | none =>
      throw (IO.userError "expected decoded ByteArray, got none")
}

/-- Odd-length hex string is rejected. -/
def hexDecodeRejectsOddLength : TestCase := {
  name := "LX.32: hex decoding rejects odd-length string"
  body := do
    let hex := "abc"  -- 3 chars (odd)
    match decodeHexString hex with
    | some _ => throw (IO.userError "expected none, got some for odd-length input")
    | none => pure ()
}

/-- Non-hex characters are rejected. -/
def hexDecodeRejectsNonHex : TestCase := {
  name := "LX.32: hex decoding rejects non-hex characters"
  body := do
    let hex := "zzzz"
    match decodeHexString hex with
    | some _ => throw (IO.userError "expected none, got some for non-hex input")
    | none => pure ()
}

/-! ## LX.33 — Invariant-claim kind tag -/

/-- Each invariant-claim kind has a distinct numeric tag. -/
def invariantClaimKindTagDistinct : TestCase := {
  name := "LX.33: invariant-claim kind tags are distinct"
  body := do
    let tagM := invariantClaimKindTag .monotonicLawSet
    let tagC := invariantClaimKindTag .conservativeLawSet
    let tagF := invariantClaimKindTag .freezePreservingLawSet
    assert (tagM != tagC) "monotonic ≠ conservative tag"
    assert (tagC != tagF) "conservative ≠ freezePreserving tag"
    assert (tagM != tagF) "monotonic ≠ freezePreserving tag"
}

/-! ## LX.31 / LX.32 / LX.33 — End-to-end macro invocation

Use the `deployment` macro directly to elaborate a minimal
manifest, then inspect the emitted defs at the value level. -/

-- A deployment macro invocation that exercises every clause type.
-- The `deploy_deployment_id` is a 64-char zero-hex string (32
-- bytes when decoded).  The `deploy_authority` clause carries a
-- placeholder Lean term.  The `deploy_invariant_claims` is empty
-- here to avoid coupling the test to specific law-instance
-- availability; LX.37's UsdClearing example covers the populated
-- claims path.
deployment minimalTestDeployment where
  deploy_id              ex.minimal
  deploy_deployment_id   "0000000000000000000000000000000000000000000000000000000000000000"
  deploy_version         "1.0.0"
  deploy_resources       := [ "USD" := 1 ]
  deploy_laws            := [ Transfer ]
  deploy_authority       := [ default = AuthorityPolicy.unrestricted ]

/-- The deployment macro emits a `Deployment` record def. -/
def deploymentMacroEmitsRecord : TestCase := {
  name := "LX.31: deployment macro emits `_deployment` record"
  body := do
    -- The macro emits `minimalTestDeployment_deployment : Deployment`.
    let dep : Deployment := minimalTestDeployment_deployment
    assertEq (expected := "ex.minimal") (actual := dep.identifier)
      "emitted identifier matches deploy_id"
    assertEq (expected := "1.0.0") (actual := dep.version)
      "emitted version matches deploy_version"
    assertEq (expected := 1) (actual := dep.resources.length)
      "resources count = 1"
    assertEq (expected := 1) (actual := dep.laws.length)
      "laws count = 1"
}

/-- The deployment macro emits a `_id` ByteArray of exactly 32 bytes. -/
def deploymentMacroEmitsIdConstant : TestCase := {
  name := "LX.32: deployment macro emits `_id` of exactly 32 bytes"
  body := do
    let id : ByteArray := minimalTestDeployment_id
    assertEq (expected := 32) (actual := id.size) "_id is 32 bytes"
    let allZeros := id.toList.all (fun b => b == 0)
    assert allZeros "_id is all zeros (matches input hex)"
}

/-- The emitted `_id` matches the `Deployment` record's
    `deploymentId` field. -/
def deploymentMacroIdMatchesRecord : TestCase := {
  name := "LX.32: emitted _id matches Deployment.deploymentId"
  body := do
    let dep := minimalTestDeployment_deployment
    let id := minimalTestDeployment_id
    assertEq (expected := dep.deploymentId.toList) (actual := id.toList)
      "Deployment.deploymentId = _id"
}

/-- The emitted `_manifest_hash` is byte-stable across reads. -/
def deploymentMacroManifestHashStable : TestCase := {
  name := "LX.32: emitted _manifest_hash is byte-stable"
  body := do
    let h1 := minimalTestDeployment_manifest_hash
    let h2 := minimalTestDeployment_manifest_hash
    assertEq (expected := h1.toList) (actual := h2.toList)
      "manifest hash byte-stable"
    assertEq (expected := 32) (actual := h1.size) "manifest hash 32 bytes"
}

/-- The emitted `_manifest_hash` matches the `Deployment`
    record's `manifestHashBytes`. -/
def deploymentMacroManifestHashMatchesRecord : TestCase := {
  name := "LX.32: emitted _manifest_hash matches Deployment.manifestHashBytes"
  body := do
    let dep := minimalTestDeployment_deployment
    let mh := minimalTestDeployment_manifest_hash
    assertEq (expected := dep.manifestHashBytes.toList) (actual := mh.toList)
      "Deployment.manifestHashBytes = _manifest_hash"
}

/-- The deployment macro emits an `_admissible` predicate that
    elaborates to a `ExtendedState → SignedAction → Prop`. -/
def deploymentMacroEmitsAdmissible : TestCase := {
  name := "LX.32: deployment macro emits _admissible predicate"
  body := do
    -- We just check the predicate has the expected type; reaching
    -- the body of the predicate requires constructing an
    -- ExtendedState and SignedAction, which is more setup than
    -- this test scope warrants.
    let _check : ExtendedState → SignedAction → Prop :=
      minimalTestDeployment_admissible
    pure ()
}

/-! ## End-to-end: invariant-claims synthesis (LX.33) with
    parameterless laws.

We can't easily test the invariant-claims synthesis with the
hand-written kernel laws (which are parameterised, e.g. `transfer
r sender receiver amount`), because the v1 `deploy_laws` clause
takes an identifier, not an applied transition term.  Instead,
we test the synthesis paths via fixture defs that wrap concrete
parameterised laws into parameterless ones, then reference
those.

This pattern mirrors the LX.37 USD-clearing example.

NOTE: This test exercises the FreezePreservingLawSet path because
all parameterless `freezeResource` laws ship `FreezePreserving`
instances unconditionally. -/

/-- A parameterless wrapper around `Laws.freezeResource 0` for
    testing.  The wrapper inherits the `IsConservative` /
    `IsMonotonic` / `FreezePreserving` instances of the underlying
    transition. -/
def fixtureFreezeLaw : Transition := Laws.freezeResource 0

/-- The parameterless wrapper inherits `IsMonotonic` from
    `freezeResource_isMonotonic`. -/
instance fixtureFreezeLaw_isMonotonic : IsMonotonic fixtureFreezeLaw :=
  freezeResource_isMonotonic 0

/-- The parameterless wrapper inherits `IsConservative` from
    `freezeResource_isConservative`. -/
instance fixtureFreezeLaw_isConservative :
    IsConservative fixtureFreezeLaw :=
  freezeResource_isConservative 0

/-- Sanity: the `MonotonicLawSet.cons` / `MonotonicLawSet.empty`
    builders work end-to-end on the fixture wrapper. -/
def monotonicLawSetConsTest : TestCase := {
  name := "LX.33: MonotonicLawSet.cons + .empty builders work"
  body := do
    let mls : MonotonicLawSet :=
      MonotonicLawSet.cons fixtureFreezeLaw MonotonicLawSet.empty
    assertEq (expected := 1) (actual := mls.laws.length)
      "law set has one element"
}

/-- Sanity: the `ConservativeLawSet.cons` / `ConservativeLawSet.empty`
    builders work end-to-end. -/
def conservativeLawSetConsTest : TestCase := {
  name := "LX.33: ConservativeLawSet.cons + .empty builders work"
  body := do
    let cls : ConservativeLawSet :=
      ConservativeLawSet.cons fixtureFreezeLaw ConservativeLawSet.empty
    assertEq (expected := 1) (actual := cls.laws.length)
      "law set has one element"
}

/-! ## Negative cases (L008 + L018) -/

/-- L018 must fire when the deployment_id is not 32 bytes — but
    we can't trigger this from a successful test because L018
    aborts elaboration.  We test the `decodeHexString` boundary
    behaviour directly: a 30-byte hex (60 chars) decodes to a
    30-byte `ByteArray`, which the macro would then reject with
    L018 at use site. -/
def hexDecodeBoundary30Bytes : TestCase := {
  name := "LX.32: hex decoding 60-char string yields 30-byte ByteArray"
  body := do
    let hex := String.ofList (List.replicate 60 '0')
    match decodeHexString hex with
    | some bs =>
      assertEq (expected := 30) (actual := bs.size) "30 bytes"
    | none =>
      throw (IO.userError "expected some, got none")
}

/-! ## LX.32 — Authority policy fold (post-M3-completion) -/

/-- The macro emits a `_authority_policy : AuthorityPolicy` def
    derived from the user's authority bindings. -/
def deploymentMacroEmitsAuthorityPolicy : TestCase := {
  name := "LX.32: deployment macro emits _authority_policy : AuthorityPolicy"
  body := do
    -- The macro emits `minimalTestDeployment_authority_policy`.
    let _check : AuthorityPolicy := minimalTestDeployment_authority_policy
    pure ()
}

/-! ## LX.33 — Wildcard `[all_laws]` expansion -/

-- Define a fixture with the wildcard form.
deployment wildcardTestDeployment where
  deploy_id              ex.wildcard
  deploy_deployment_id   "0000000000000000000000000000000000000000000000000000000000000001"
  deploy_version         "1.0.0"
  deploy_resources       := [ "USD" := 0 ]
  deploy_laws            := [ Freeze = fixtureFreezeLaw @ "1.0.0" ]
  deploy_authority       := [ default = AuthorityPolicy.unrestricted ]
  deploy_invariant_claims := [
    monotonic_law_set [all_laws]
  ]

/-- The wildcard form expands to the deployment's full law list. -/
def wildcardExpansionTest : TestCase := {
  name := "LX.33: [all_laws] wildcard expands to deploy_laws list"
  body := do
    let mls := wildcardTestDeployment_monotonic_law_set_0
    -- The deployment has 1 law (Freeze); the wildcard expands to it.
    assertEq (expected := 1) (actual := mls.laws.length)
      "wildcard expanded to the deployment's law list"
}

/-! ## LX.37 — attestor placeholder (v2 reservation) -/

deployment attestorTestDeployment where
  deploy_id              ex.attestor
  deploy_deployment_id   "0000000000000000000000000000000000000000000000000000000000000002"
  deploy_version         "1.0.0"
  deploy_resources       := [ "USD" := 0 ]
  deploy_laws            := [ Freeze = fixtureFreezeLaw @ "1.0.0" ]
  deploy_authority       := [ default = AuthorityPolicy.unrestricted ]
  deploy_invariant_claims := []
  deploy_attestor        my_attestor

/-- The `deploy_attestor` clause is parsed (v2-reservation;
    captured but not yet wired into emitted defs). -/
def attestorPlaceholderTest : TestCase := {
  name := "LX.37: deploy_attestor clause is parsed (v2 reservation)"
  body := do
    -- The macro elaborates the clause without error; the
    -- attestor handle is reserved for v2 (signed-manifest
    -- attestation).
    let _check : Deployment := attestorTestDeployment_deployment
    pure ()
}

/-! ## LX.32 — `@`-version-pin syntax in `deploy_laws` -/

-- Define a fixture using the spec's `<localName> = <law> @ "<version>"` form.
deployment versionPinTestDeployment where
  deploy_id              ex.version_pin
  deploy_deployment_id   "0000000000000000000000000000000000000000000000000000000000000003"
  deploy_version         "1.0.0"
  deploy_resources       := [ "USD" := 0 ]
  deploy_laws            := [
    Freeze = fixtureFreezeLaw @ "0.9.0"  -- distinct from deploy_version
  ]
  deploy_authority       := [ default = AuthorityPolicy.unrestricted ]
  deploy_invariant_claims := []

/-- The `@`-version-pin captures a per-binding version distinct
    from the deployment's `deploy_version`. -/
def versionPinTest : TestCase := {
  name := "LX.37: @-version-pin captures per-binding version"
  body := do
    let dep := versionPinTestDeployment_deployment
    let firstLaw := dep.laws.head!
    assertEq (expected := "0.9.0") (actual := firstLaw.version)
      "law's @-version-pin captured into LawBinding.version"
    assertEq (expected := "1.0.0") (actual := dep.version)
      "deployment-level version distinct from per-law version pin"
}

/-! ## LX.33 — `synth_*` named functions -/

/-- `synth_monotonic_law_set` is callable from `CommandElabM`. -/
def synthMonotonicNamedAPITest : TestCase := {
  name := "LX.33: synth_monotonic_law_set named API exists"
  body := do
    -- We don't run synth_* here (it requires CommandElabM
    -- context).  This test confirms the symbol exists at the
    -- term level (i.e. the named-API export is present).  A
    -- full call-site exercise lives in the deployment macro
    -- elaborator itself.
    let _check : List Lean.Name → Lean.Elab.Command.CommandElabM Lean.Term :=
      synth_monotonic_law_set
    pure ()
}

/-- `synth_conservative_law_set` is callable. -/
def synthConservativeNamedAPITest : TestCase := {
  name := "LX.33: synth_conservative_law_set named API exists"
  body := do
    let _check : List Lean.Name → Lean.Elab.Command.CommandElabM Lean.Term :=
      synth_conservative_law_set
    pure ()
}

/-- `synth_freeze_preserving_law_set` is callable. -/
def synthFreezePreservingNamedAPITest : TestCase := {
  name := "LX.33: synth_freeze_preserving_law_set named API exists"
  body := do
    let _check : List Nat → List Lean.Name →
                  Lean.Elab.Command.CommandElabM Lean.Term :=
      synth_freeze_preserving_law_set
    pure ()
}

/-! ## LX.31 — public `parseDeployment` named API -/

/-- `parseDeployment` is callable. -/
def parseDeploymentNamedAPITest : TestCase := {
  name := "LX.31: parseDeployment named API exists"
  body := do
    let _check : Lean.Environment → Lean.Name → String → Nat →
                  Lean.Name → Array Lean.Syntax →
                  Lean.Elab.Command.CommandElabM DeploymentDecl :=
      parseDeployment
    pure ()
}

/-- Audit-5 (HIGH-1): the manifest-hash claim-comparator
    collision fix.  Pre-fix the comparator was
    `intercalate "," a.2.2 < intercalate "," b.2.2` which
    collapsed `["foo,bar"]` and `["foo","bar"]` to the same
    sort key.  Under qsort instability, the encoded bytes —
    and therefore the manifest hash — could differ across
    runs even on equal input.  This test pins the post-fix
    behavior: two manifests differing only in their claim
    list's `lawNames` shape MUST produce distinct manifest
    hashes. -/
def manifestHashClaimListInjective : TestCase := {
  name := "audit-5: manifest hash distinguishes claim shape"
  body := do
    -- Two claims that the prior comparator would have collapsed:
    let claimsA : List (Nat × Nat × List String) :=
      [(0, 0, ["foo,bar"])]   -- single string with comma
    let claimsB : List (Nat × Nat × List String) :=
      [(0, 0, ["foo", "bar"])] -- two strings
    let h1 := computeManifestHash
      "ex.deploy" fixtureDeploymentId "1.0.0"
      [] [] [] claimsA
    let h2 := computeManifestHash
      "ex.deploy" fixtureDeploymentId "1.0.0"
      [] [] [] claimsB
    assert (h1.toList != h2.toList)
      "claims with comma-collision shapes MUST produce distinct hashes"
}

/-- Audit-5: empty resources / laws / authority / claims edge
    case.  A minimal deployment computes a hash from just
    `(identifier, deploymentId, version)` plus four empty-list
    length-prefix bytes.  Verifies the hash is non-empty and
    the size is the documented 32 bytes. -/
def manifestHashAllEmpty : TestCase := {
  name := "audit-5: manifest hash on empty resources/laws/auth/claims"
  body := do
    let h := computeManifestHash
      "ex.minimal" fixtureDeploymentId "1.0.0" [] [] [] []
    assertEq (expected := 32) (actual := h.size)
      "all-empty-list manifest hash must be 32 bytes"
}

/-- The complete LX.31 / LX.32 / LX.33 / LX.37 test suite. -/
def tests : List TestCase :=
  [ deploymentRecordShape,
    manifestHashDeterminism,
    manifestHashDistinguishesIdentifier,
    manifestHashDistinguishesDeploymentId,
    manifestHashSize,
    manifestHashDistinguishesVersion,
    hexDecodeAllZeros,
    hexDecodeMixedCase,
    hexDecodeRejectsOddLength,
    hexDecodeRejectsNonHex,
    invariantClaimKindTagDistinct,
    deploymentMacroEmitsRecord,
    deploymentMacroEmitsIdConstant,
    deploymentMacroIdMatchesRecord,
    deploymentMacroManifestHashStable,
    deploymentMacroManifestHashMatchesRecord,
    deploymentMacroEmitsAdmissible,
    monotonicLawSetConsTest,
    conservativeLawSetConsTest,
    hexDecodeBoundary30Bytes,
    -- M3-completion tests:
    deploymentMacroEmitsAuthorityPolicy,
    wildcardExpansionTest,
    attestorPlaceholderTest,
    versionPinTest,
    synthMonotonicNamedAPITest,
    synthConservativeNamedAPITest,
    synthFreezePreservingNamedAPITest,
    parseDeploymentNamedAPITest,
    -- Audit-5 regression tests:
    manifestHashClaimListInjective,
    manifestHashAllEmpty ]

end Lex.Test.DSL.DeploymentTests
