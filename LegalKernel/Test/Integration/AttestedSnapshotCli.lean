-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto
import LegalKernel.Runtime.AttestedSnapshot
import LegalKernel.Runtime.Snapshot

/-!
LegalKernel.Test.Integration.AttestedSnapshotCli — AR.23.4.

Integration regression for the AR.3.2 attested-snapshot CLI gate:
`bootstrapFromAttestedSnapshot` must reject an attestation that
fails the registry/signature check, and must accept a
correctly-signed attestation.  Uses the `mockVerify` / `mockSign`
adaptor from `LegalKernel.Test.MockCrypto` so the verifier is
reachable at the Lean level (production `Verify` returns `false`).

The CLI surface itself lives in `Main.lean` (the `knomosis` binary)
and `Replay.lean` (the `knomosis-replay` binary); per the AR.23.4
plan, this integration covers the *Lean-side* gate at
`bootstrapFromAttestedSnapshot`, which is what the CLI dispatches
to.  CLI-level invocation tests would require subprocess
scaffolding that isn't currently part of the Lean test harness;
the Lean-level integration is the operational contract that the
CLI delegates to.
-/

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Integration.AttestedSnapshotCli

/-! ## Fixtures -/

/-- An attestor actor id. -/
def attestorActor : ActorId := 42

/-- The attestor's public key, registered in the runtime's
    registry.  `mockPubKey 42` produces a canonical mock 32-byte
    key. -/
def attestorPk : Authority.PublicKey := mockPubKey attestorActor.toNat

/-- A deployment id for the attestation envelope.  AR.3.2: the
    attestation binds the snapshot to a specific deployment, so
    cross-deployment replay of a snapshot is rejected at the
    bytes-comparison level (different `deploymentId` → different
    signing input → mockSign produces a different "signature" the
    next mockVerify won't accept under the alternative did,
    although mockVerify ignores msg). -/
def cliDeploymentId : ByteArray :=
  ByteArray.mk (((0xAB : UInt8) :: List.replicate 31 (0 : UInt8))).toArray

/-- A registry containing the attestor's public key.  Used as the
    `attestorRegistry` parameter of `bootstrapFromAttestedSnapshot`. -/
def attestorRegistry : KeyRegistry :=
  (∅ : KeyRegistry).insert attestorActor attestorPk

/-- A `Snapshot` of the empty genesis state at log index 0.  Used
    for the genesis-anchor case (the AR.3.1 anchor check passes
    when `seedHash = zeroHash` at `baseIdx = 0`). -/
def genesisSnap : Snapshot :=
  let encodedState : ByteArray :=
    ByteArray.mk
      (Encodable.encode (T := ExtendedState) ExtendedState.empty).toArray
  { encodedState := encodedState
  , stateHash    := hashEncodable ExtendedState.empty
  , seedHash     := zeroHash
  , logIndex     := 0 }

/-- A properly-signed `AttestedSnapshot` for `genesisSnap` under
    `cliDeploymentId`.  `mockSign` returns a signature shape that
    `mockVerify` accepts. -/
def goodAttestation : AttestedSnapshot :=
  let msg := attestationSigningInput genesisSnap cliDeploymentId
  { snap         := genesisSnap
  , deploymentId := cliDeploymentId
  , attestor     := attestorActor
  , sig          := mockSign attestorPk msg }

/-- A *tampered* `AttestedSnapshot`: same envelope, but with a
    signature that's not in mockSign's accepted shape (just 64
    zero bytes, no `0xFF` leading byte → mockVerify rejects). -/
def tamperedAttestation : AttestedSnapshot :=
  { goodAttestation with
    sig := ByteArray.mk (List.replicate 64 (0 : UInt8)).toArray }

/-! ## Tests -/

/-- AR.23.4 — under a registry that doesn't know the attestor,
    `verifyAttestation` rejects. -/
def unknownAttestorRejection : TestCase := {
  name := "AR.23.4: verifyAttestationWith rejects unknown attestor"
  body := do
    -- Empty registry: attestor 42 isn't registered.
    let result := verifyAttestationWith mockVerify (∅ : KeyRegistry) goodAttestation
    if result then
      throw <| IO.userError "BUG: accepted attestation under empty registry"
    else pure ()
}

/-- AR.23.4 — under the correct registry + signature, the
    attestation verifies. -/
def goodAttestationAccepted : TestCase := {
  name := "AR.23.4: verifyAttestationWith accepts correctly-signed attestation"
  body := do
    let result := verifyAttestationWith mockVerify attestorRegistry goodAttestation
    if result then pure ()
    else
      throw <| IO.userError
        "BUG: rejected a correctly-signed attestation under attestorRegistry"
}

/-- AR.23.4 — under the correct registry but a tampered signature,
    the attestation is rejected.  Mirrors the AR.3.2
    `.unattested` arm. -/
def tamperedSignatureRejection : TestCase := {
  name := "AR.23.4: verifyAttestationWith rejects tampered signature"
  body := do
    let result :=
      verifyAttestationWith mockVerify attestorRegistry tamperedAttestation
    if result then
      throw <| IO.userError "BUG: accepted a tampered attestation"
    else pure ()
}

/-- AR.23.4 — `bootstrapFromAttestedSnapshotWith mockVerify`
    rejects an unattested envelope with `.unattested`.  This is
    the `knomosis bootstrap --snapshot ...` CLI gate's Lean-side
    contract.  Uses the parameterised entry so the test is
    reachable at the Lean level (the production `Verify` opaque
    returns `false`, so the back-compat alias can only
    demonstrate the `.unattested` path). -/
def unattestedBootstrapRejection : TestCase := {
  name := "AR.23.4: bootstrapFromAttestedSnapshotWith rejects unattested envelope"
  body := do
    -- The attestor's key is NOT registered → verification fails →
    -- the bootstrap function returns `.error .unattested` without
    -- proceeding to the inner snapshot bootstrap.
    let logPath := System.FilePath.mk "/tmp/knomosis-ar234-unattested.log"
    if (← logPath.pathExists) then IO.FS.removeFile logPath
    IO.FS.writeBinFile logPath (ByteArray.mk #[])
    match (← bootstrapFromAttestedSnapshotWith mockVerify
                                                AuthorityPolicy.unrestricted
                                                (∅ : KeyRegistry)
                                                goodAttestation logPath) with
    | .ok _ =>
        throw <| IO.userError
          "BUG: bootstrapFromAttestedSnapshot accepted unattested envelope"
    | .error .unattested => pure ()
    | .error other =>
        throw <| IO.userError
          s!"expected .unattested, got {repr other}"
}

/-- AR.23.4 — `bootstrapFromAttestedSnapshotWith mockVerify`
    accepts a properly-signed envelope and delegates to the inner
    snapshot bootstrap, which performs the AR.3.1 anchor check +
    replay. -/
def goodAttestationBootstrapAccepted : TestCase := {
  name := "AR.23.4: bootstrapFromAttestedSnapshotWith accepts properly-signed envelope"
  body := do
    let logPath := System.FilePath.mk "/tmp/knomosis-ar234-good.log"
    if (← logPath.pathExists) then IO.FS.removeFile logPath
    IO.FS.writeBinFile logPath (ByteArray.mk #[])
    match (← bootstrapFromAttestedSnapshotWith mockVerify
                                                AuthorityPolicy.unrestricted
                                                attestorRegistry
                                                goodAttestation logPath) with
    | .ok (rs, _) =>
        -- Sanity: the resulting RuntimeState reflects the snapshot's
        -- genesis (empty) state.
        if (hashEncodable rs.state).data == (hashEncodable ExtendedState.empty).data
        then pure ()
        else
          throw <| IO.userError
            "bootstrap state diverged from snapshot's recorded state"
    | .error e =>
        throw <| IO.userError
          s!"expected accepted bootstrap, got {repr e}"
}

/-- AR.23.4 — `bootstrapFromAttestedSnapshotWith mockVerify`
    rejects a tampered envelope with `.unattested` (signature
    gate fires before the anchor / replay gates). -/
def tamperedBootstrapRejection : TestCase := {
  name := "AR.23.4: bootstrapFromAttestedSnapshotWith rejects tampered signature"
  body := do
    let logPath := System.FilePath.mk "/tmp/knomosis-ar234-tampered.log"
    if (← logPath.pathExists) then IO.FS.removeFile logPath
    IO.FS.writeBinFile logPath (ByteArray.mk #[])
    match (← bootstrapFromAttestedSnapshotWith mockVerify
                                                AuthorityPolicy.unrestricted
                                                attestorRegistry
                                                tamperedAttestation logPath) with
    | .ok _ =>
        throw <| IO.userError
          "BUG: bootstrapFromAttestedSnapshot accepted tampered envelope"
    | .error .unattested => pure ()
    | .error other =>
        throw <| IO.userError
          s!"expected .unattested on tampered envelope, got {repr other}"
}

/-- AR.23.4 — the production alias `bootstrapFromAttestedSnapshot`
    is `bootstrapFromAttestedSnapshotWith Verify`.  Under
    production Verify (returns `false` at Lean level), every
    envelope is rejected as `.unattested`.  This pins the alias
    to its parameterised body. -/
def productionAliasMatchesParameterised : TestCase := {
  name := "AR.23.4: bootstrapFromAttestedSnapshot ≡ With Verify"
  body := do
    let logPath := System.FilePath.mk "/tmp/knomosis-ar234-alias.log"
    if (← logPath.pathExists) then IO.FS.removeFile logPath
    IO.FS.writeBinFile logPath (ByteArray.mk #[])
    let r1 ← bootstrapFromAttestedSnapshot AuthorityPolicy.unrestricted
                                            attestorRegistry
                                            goodAttestation logPath
    let r2 ← bootstrapFromAttestedSnapshotWith Verify
                                                AuthorityPolicy.unrestricted
                                                attestorRegistry
                                                goodAttestation logPath
    -- Both should return .error .unattested (production Verify
    -- returns false on the mock signature).
    match r1, r2 with
    | .error .unattested, .error .unattested => pure ()
    | _, _ =>
        throw <| IO.userError "alias diverged from With Verify"
}

/-- AR.23.4 — term-level API stability for the canonical
    bootstrap entry-point.  Pins the named-argument call shape
    (deploymentId has a default; the test fixes it explicitly to
    detect any future reorder of the leading positional
    parameters). -/
def apiStability : TestCase := {
  name := "AR.23.4: bootstrapFromAttestedSnapshot API stability"
  body := do
    let _proof : AuthorityPolicy → KeyRegistry → AttestedSnapshot →
                 System.FilePath →
                 IO (Except AttestedBootstrapError
                       (RuntimeState × Option FrameError)) :=
      fun p kr att path =>
        bootstrapFromAttestedSnapshot p kr att path
          (deploymentId := ByteArray.empty)
    pure ()
}

/-- All AR.23.4 AttestedSnapshot integration tests. -/
def tests : List TestCase :=
  [ unknownAttestorRejection
  , goodAttestationAccepted
  , tamperedSignatureRejection
  , unattestedBootstrapRejection
  , goodAttestationBootstrapAccepted
  , tamperedBootstrapRejection
  , productionAliasMatchesParameterised
  , apiStability
  ]

end LegalKernel.Test.Integration.AttestedSnapshotCli
