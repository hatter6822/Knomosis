-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Runtime.AttestedSnapshot — Audit-3.2 test suite.

Exercises the `AttestedSnapshot` envelope:

  * Round-trip encode + decode preserves all fields.
  * `verifyAttestationWith mockVerify` accepts a properly-attested
    snapshot.
  * Verify rejects when the attestor is not in the registry.
  * Verify rejects when the signature is wrong.
  * Cross-protocol distinguishability: the attestation
    signing-input bytes differ from `signingInput` (SignedAction)
    and any verdict-shape signing input.
  * `loadAttestedSnapshot` returns a `DecodeError` on missing file
    (rather than throwing an IO exception).
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Runtime
namespace AttestedSnapshotTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-! ## Test fixtures -/

/-- Deployment id carried in every test attestation. -/
def testDeploymentId : ByteArray :=
  ByteArray.mk #[0xCA, 0xFE, 0xBA, 0xBE]

/-- Attestor actor id. -/
def attestorId : ActorId := 99

/-- A registry containing only the attestor's mock public key. -/
def attestorRegistry : KeyRegistry :=
  KeyRegistry.empty.register attestorId (mockPubKey 99)

/-- A small snapshot from an empty extended state. -/
def baseSnap : Snapshot :=
  takeSnapshot ExtendedState.empty zeroHash 0

/-- Build a properly-attested snapshot using `mockSign`. -/
def mkAttested : AttestedSnapshot :=
  let pk := mockPubKey 99
  let msg := attestationSigningInput baseSnap testDeploymentId
  let sig := mockSign pk msg
  { snap := baseSnap
  , deploymentId := testDeploymentId
  , attestor := attestorId
  , sig := sig }

/-! ## Tests -/

/-- AttestedSnapshot encode-decode round trip preserves all fields,
    including the inner Snapshot's stateHash, encodedState contents,
    logIndex, and seedHash. -/
def attestedSnapshotRoundtrip : TestCase := {
  name := "AttestedSnapshot encode/decode round-trip (all fields)"
  body := do
    let att := mkAttested
    let bytes := AttestedSnapshot.encode att
    match AttestedSnapshot.decode bytes with
    | .ok (att', _) =>
      -- Outer envelope fields
      assertEq (expected := att.deploymentId.toList)
                (actual := att'.deploymentId.toList) "deploymentId roundtrip"
      assertEq (expected := att.attestor) (actual := att'.attestor)
        "attestor roundtrip"
      assertEq (expected := att.sig.toList) (actual := att'.sig.toList)
        "sig roundtrip"
      -- Inner Snapshot fields — strengthen audit-3.2 coverage to
      -- verify the outer-envelope decode actually recovers the
      -- inner snapshot bit-for-bit.
      assertEq (expected := att.snap.stateHash.toList)
                (actual := att'.snap.stateHash.toList)
                "inner snapshot stateHash roundtrip"
      assertEq (expected := att.snap.encodedState.toList)
                (actual := att'.snap.encodedState.toList)
                "inner snapshot encodedState roundtrip"
      assertEq (expected := att.snap.logIndex)
                (actual := att'.snap.logIndex)
                "inner snapshot logIndex roundtrip"
      assertEq (expected := att.snap.seedHash.toList)
                (actual := att'.snap.seedHash.toList)
                "inner snapshot seedHash roundtrip"
    | .error e =>
      throw <| IO.userError s!"decode failed: {repr e}"
}

/-- `verifyAttestationWith mockVerify` accepts a valid attestation. -/
def verifyAcceptsValid : TestCase := {
  name := "verifyAttestationWith mockVerify accepts valid attestation"
  body := do
    let att := mkAttested
    if verifyAttestationWith mockVerify attestorRegistry att then
      pure ()
    else
      throw <| IO.userError "valid attestation was rejected"
}

/-- `verifyAttestationWith` rejects when the attestor is not in the
    registry. -/
def verifyRejectsUnregistered : TestCase := {
  name := "verifyAttestationWith rejects unregistered attestor"
  body := do
    let att := mkAttested
    -- Empty registry: attestor not registered.
    if verifyAttestationWith mockVerify KeyRegistry.empty att then
      throw <| IO.userError "unregistered attestor was accepted"
    else
      pure ()
}

/-- `verifyAttestationWith` rejects when the signature is wrong
    (here: empty bytes — `mockVerify` rejects everything except the
    canonical 64-byte 0xFF-prefixed form). -/
def verifyRejectsBadSignature : TestCase := {
  name := "verifyAttestationWith rejects bad signature"
  body := do
    let bad : AttestedSnapshot :=
      { snap := baseSnap
      , deploymentId := testDeploymentId
      , attestor := attestorId
      , sig := ByteArray.empty }
    if verifyAttestationWith mockVerify attestorRegistry bad then
      throw <| IO.userError "bad signature was accepted"
    else
      pure ()
}

/-- The attestation signing-input bytes differ from a SignedAction
    `signingInput`'s bytes for any (action, signer, nonce, d).  This
    is the cross-protocol replay-rejection guarantee. -/
def attestationSigningInputDistinctFromSignedAction : TestCase := {
  name := "attestationSigningInput distinct from SignedAction signingInput"
  body := do
    let attBytes := attestationSigningInput baseSnap testDeploymentId
    -- Pick any action / signer / nonce; the signingInput bytes begin
    -- with `signedActionDomain` not `attestedSnapshotDomain`.
    let saBytes := signingInput (.transfer 1 10 20 30) 10 0 testDeploymentId
    if attBytes.toList = saBytes.toList then
      throw <| IO.userError
        "attestationSigningInput collides with signingInput — cross-protocol replay possible"
    else
      pure ()
}

/-- The attestation signing-input bytes begin with the canonical
    `attestedSnapshotDomain` ASCII bytes (after the CBE bytestring
    head). -/
def attestationDomainPrefixPresent : TestCase := {
  name := "attestationSigningInput begins with attestedSnapshotDomain"
  body := do
    let bytes := (attestationSigningInput baseSnap testDeploymentId).toList
    -- Skip the 9-byte CBE bytestring head (1 tag + 8 LE length).
    let domainPart := bytes.drop 9 |>.take attestedSnapshotDomain.toUTF8.size
    let expectedDomain := attestedSnapshotDomain.toUTF8.data.toList
    assert (domainPart = expectedDomain)
      s!"attested-snapshot domain prefix missing"
}

/-- Distinct deployment ids produce distinct attestation signing
    inputs (binds attestation to deployment). -/
def attestationSigningInputDistinguishesDeployments : TestCase := {
  name := "attestationSigningInput distinguishes deployments"
  body := do
    let b1 := attestationSigningInput baseSnap testDeploymentId
    let b2 := attestationSigningInput baseSnap (ByteArray.mk #[0xDE, 0xAD])
    if b1.toList = b2.toList then
      throw <| IO.userError "deployment id is not distinguished in attestation bytes"
    else
      pure ()
}

/-- `loadAttestedSnapshot` on a missing file returns a
    `DecodeError` rather than throwing an IO exception. -/
def loadMissingFileGraceful : TestCase := {
  name := "loadAttestedSnapshot on missing file returns DecodeError"
  body := do
    let path := s!"/tmp/knomosis-audit3-attested-missing-{(← IO.monoNanosNow)}.snap"
    let result ← loadAttestedSnapshot (System.FilePath.mk path)
    match result with
    | .error _ => pure ()
    | .ok _    =>
      throw <| IO.userError "loadAttestedSnapshot accepted a missing file"
}

/-- Save + load round trip via the IO helpers. -/
def saveLoadRoundtrip : TestCase := {
  name := "saveAttestedSnapshot then loadAttestedSnapshot round-trips"
  body := do
    let att := mkAttested
    let path := s!"/tmp/knomosis-audit3-attested-saveload-{(← IO.monoNanosNow)}.snap"
    saveAttestedSnapshot (System.FilePath.mk path) att
    match (← loadAttestedSnapshot (System.FilePath.mk path)) with
    | .ok att' =>
      assertEq (expected := att.attestor) (actual := att'.attestor)
        "save/load attestor"
      assertEq (expected := att.sig.toList) (actual := att'.sig.toList)
        "save/load sig"
    | .error e =>
      throw <| IO.userError s!"loadAttestedSnapshot failed: {repr e}"
    IO.FS.removeFile path
}

/-! ## Term-level API stability -/

/-- Term-level: `attestationSigningInput` is callable. -/
def attestationSigningInputAPI : TestCase := {
  name := "attestationSigningInput API stability"
  body := do
    let _proof : Snapshot → ByteArray → ByteArray := attestationSigningInput
    pure ()
}

/-- Term-level: `verifyAttestationWith` is callable. -/
def verifyAttestationWithAPI : TestCase := {
  name := "verifyAttestationWith API stability"
  body := do
    let _proof : (PublicKey → ByteArray → Signature → Bool) → KeyRegistry →
                  AttestedSnapshot → Bool :=
      verifyAttestationWith
    pure ()
}

/-- All tests in the AttestedSnapshot suite. -/
def tests : List TestCase :=
  [ attestedSnapshotRoundtrip
  , verifyAcceptsValid
  , verifyRejectsUnregistered
  , verifyRejectsBadSignature
  , attestationSigningInputDistinctFromSignedAction
  , attestationDomainPrefixPresent
  , attestationSigningInputDistinguishesDeployments
  , loadMissingFileGraceful
  , saveLoadRoundtrip
  , attestationSigningInputAPI
  , verifyAttestationWithAPI
  ]

end AttestedSnapshotTests
end LegalKernel.Test.Runtime
