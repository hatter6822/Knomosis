-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Runtime.AttestedSnapshot — Audit-3.2.

Closes the self-attesting bootstrap gap.  The bare `Snapshot`
record's `restoreSnapshot` only checks that
`hashEncodable encodedState == stateHash`, which is meaningless
under an adversarial supplier — they recompute the hash from
their fake encoded state and the check trivially passes.

`AttestedSnapshot` wraps a `Snapshot` with an attestor's
signature over a domain-separated canonical encoding of
`(snapshot, deploymentId)`.  The `verifyAttestation` /
`verifyAttestationWith` functions check the signature against a
known attestor public key.  The `knomosis-replay
--require-attestation <pk-hex>` flag (in `Replay.lean`) enforces
the attestation; without the flag, bare `Snapshot` files are
still accepted (backwards-compatible).

Genesis Plan §13.2 + §8.8.5 amendment (Audit-3.2): documents
this envelope as deployment best practice for replica bootstrap.

This module is **not** part of the trusted computing base.  Bugs
here weaken the cross-replica trust property but cannot violate
any kernel invariant.  An attestor-key compromise remains out of
scope; attestation closes the self-attesting gap, not key-mgmt.
-/

import LegalKernel.Runtime.Snapshot
import LegalKernel.Runtime.Loop
import LegalKernel.Authority.SignedAction

namespace LegalKernel
namespace Runtime

open LegalKernel.Authority
open LegalKernel.Encoding

/-! ## AttestedSnapshot envelope

An outer envelope around `Snapshot` that carries an attestor
signature.  The signature is over the canonical
`attestationSigningInput` bytes; replicas verify the signature
against a deployment-supplied public key. -/

/-- Outer envelope for a snapshot, plus an attestor's signature.
    The signature covers `attestationSigningInput snap
    deploymentId` (domain-separated CBE encoding).  Replicas use
    `verifyAttestation` / `verifyAttestationWith` to check it. -/
structure AttestedSnapshot where
  /-- The wrapped snapshot. -/
  snap         : Snapshot
  /-- The deployment id this snapshot belongs to (typically the
      genesis-state hash; same value as Audit-3.4's deploymentId
      for the kernel-level admissibility predicate).  Carried in
      the envelope so cross-deployment-replay protection extends
      to snapshot bootstraps. -/
  deploymentId : ByteArray
  /-- The actor whose key signed the attestation. -/
  attestor     : ActorId
  /-- The signature over `attestationSigningInput snap deploymentId`. -/
  sig          : Signature
  deriving Repr

/-! ## Domain string

The cross-protocol domain prefix for attestation signing inputs.
Distinct from `signedActionDomain` and `verdictDomain` so that an
attestor's signature on a `Snapshot` cannot be re-interpreted as
a `SignedAction` or `Verdict` signature (the bytes differ). -/

/-- Domain-separation string for `AttestedSnapshot` signing inputs.
    Audit-3.2 cross-protocol replay protection. -/
def attestedSnapshotDomain : String := "legalkernel/v1/attested-snapshot"

/-! ## Sign-input construction

The bytes the attestor signs.  Layout (concatenation of CBE
encodings):

  1. CBE-encoded domain string `"legalkernel/v1/attested-snapshot"`
     (length-prefixed bytestring).
  2. CBE-encoded `deploymentId : ByteArray`.
  3. CBE-encoded `Snapshot` bytes (the inner snapshot's `encode`
     output, embedded as a length-prefixed bytestring so the
     concatenation is self-delimiting).

Each component is length-prefixed, so the concatenation is
injective in `(snap, deploymentId)` — distinct snapshots or
deployment ids yield distinct signing-input bytes. -/

/-- Audit-3.2: the bytes an attestor signs when attesting a
    snapshot.  Domain-separated to prevent cross-protocol replay
    against `signingInput` (SignedAction) or
    `verdictSigningInput` (Verdict). -/
def attestationSigningInput (snap : Snapshot) (deploymentId : ByteArray) : ByteArray :=
  let domainBytes : Stream :=
    cborHeadEncode cbeTagBytes attestedSnapshotDomain.toUTF8.size ++
      attestedSnapshotDomain.toUTF8.data.toList
  -- Embed the snapshot's bytes as a CBE bytestring (length-prefixed).
  -- This makes the concatenation self-delimiting: a decoder can read
  -- the length, slice the snapshot bytes, and pass the residual to the
  -- next component (here: nothing, since deploymentId is already encoded).
  let snapBytes := Snapshot.encode snap
  let snapByteArray : ByteArray := ByteArray.mk snapBytes.toArray
  ByteArray.mk
    (domainBytes ++
     Encodable.encode (T := ByteArray) deploymentId ++
     Encodable.encode (T := ByteArray) snapByteArray).toArray

/-! ## Verification

`verifyAttestationWith` is parameterised over the verifier
function (consistent with Audit-3.3); `verifyAttestation` is the
back-compat default that uses the production `Verify`. -/

/-- Audit-3.2 + 3.3: parameterised verification.  Returns `true`
    iff the registry maps `att.attestor` to some public key and
    the supplied signature verifies under that key against the
    canonical attestation signing input. -/
def verifyAttestationWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (registry : KeyRegistry) (att : AttestedSnapshot) : Bool :=
  match registry[att.attestor]? with
  | none    => false
  | some pk =>
    verify pk (attestationSigningInput att.snap att.deploymentId) att.sig

/-- Production-default verifier: uses the linked `Verify` opaque. -/
def verifyAttestation (registry : KeyRegistry) (att : AttestedSnapshot) : Bool :=
  verifyAttestationWith Verify registry att

/-! ## Encoding

CBE encoding for `AttestedSnapshot` mirrors `Snapshot`'s pattern:
length-prefixed bytestring for the embedded `snap`, then
deploymentId, attestor (as Nat), and sig. -/

/-- CBE encode an `AttestedSnapshot` to a byte stream. -/
def AttestedSnapshot.encode (att : AttestedSnapshot) : Stream :=
  let snapBytes := Snapshot.encode att.snap
  let snapByteArray : ByteArray := ByteArray.mk snapBytes.toArray
  Encodable.encode (T := ByteArray) snapByteArray ++
  Encodable.encode (T := ByteArray) att.deploymentId ++
  Encodable.encode (T := Nat) att.attestor.toNat ++
  Encodable.encode (T := ByteArray) att.sig

/-- CBE decode a byte stream into an `AttestedSnapshot`.  Returns
    the parsed value and the residual stream, or a `DecodeError`. -/
def AttestedSnapshot.decode (s : Stream) :
    Except DecodeError (AttestedSnapshot × Stream) := do
  let (snapByteArray, s₁) ← Encodable.decode (T := ByteArray) s
  let (snapValue, _) ← Snapshot.decode snapByteArray.toList
  let (depId, s₂) ← Encodable.decode (T := ByteArray) s₁
  let (attestor, s₃) ← Encodable.decode (T := Nat) s₂
  let (sig, s₄) ← Encodable.decode (T := ByteArray) s₃
  pure (⟨snapValue, depId, UInt64.ofNat attestor, sig⟩, s₄)

/-- IO: write an `AttestedSnapshot` to a file. -/
def saveAttestedSnapshot
    (path : System.FilePath) (att : AttestedSnapshot) : IO Unit := do
  let bytes := AttestedSnapshot.encode att
  IO.FS.writeBinFile path (ByteArray.mk bytes.toArray)

/-- IO: read an `AttestedSnapshot` from a file.  Returns
    `DecodeError` on missing-file or parse failure (matches
    `loadSnapshot`'s pattern in `Snapshot.lean`). -/
def loadAttestedSnapshot (path : System.FilePath) :
    IO (Except DecodeError AttestedSnapshot) := do
  let res ← (IO.FS.readBinFile path).toBaseIO
  match res with
  | .error _ => pure (.error .unexpectedEof)
  | .ok bytes =>
    match AttestedSnapshot.decode bytes.toList with
    | .ok (att, _) => pure (.ok att)
    | .error e     => pure (.error e)

/-! ## AR.3.2 / M-2 — AttestedSnapshot CLI gate

`bootstrapFromAttestedSnapshot` is the production entry-point for
snapshot-based bootstrap.  It enforces TWO gates ahead of the
underlying `bootstrapFromSnapshot`:

  1. **Attestor signature check** — the embedded snapshot's
     attestor signature must verify against the supplied
     `verifyKey`.  Without this, an adversary could supply a
     hand-crafted snapshot of a deployment-distinct state.
  2. **Chain anchor check (AR.3.1)** — the snapshot's
     `seedHash` must match the actual hash of the pre-snapshot
     log prefix.  This is inherited from
     `bootstrapFromSnapshot`'s `.anchorMismatch` arm.

Errors are surfaced via a dedicated `AttestedBootstrapError`
enum that distinguishes attestor-side failures (`.unattested`)
from the inner `BootstrapError`.  The `knomosis` CLI gate (AR.2.6)
calls this entry; the `--unsafe-self-attested` flag bypasses the
attestor check for single-replica dev mode. -/

/-- Failure modes specific to attested-snapshot bootstrap.  Wraps
    the inner `BootstrapError` plus the additional
    attestor-signature variant. -/
inductive AttestedBootstrapError where
  /-- The attestor signature on the snapshot envelope failed
      verification.  Either the registry doesn't map
      `att.attestor` to a public key, or the supplied signature is
      not a valid signature on the canonical attestation input
      under the registered key.  Production deployments treat
      this as a hard rejection. -/
  | unattested
  /-- The inner `bootstrapFromSnapshot` returned an error
      (anchor-mismatch, log-index-overrun, snapshot-decode,
      replay).  Wrapping preserves the precise diagnostic. -/
  | inner (e : BootstrapError)
  deriving Repr

/-- AR.3.2 parameterised entry: bootstrap from an attested
    snapshot under an explicit `verify` function.  Mirrors the
    deploymentId-aware parameterisation pattern (AR.2.4 /
    AR.2.5): test harnesses use the `MockCrypto` adaptor;
    production callers pass `Verify` via the
    `bootstrapFromAttestedSnapshot` alias below.

    Verifies the attestor signature against `attestorRegistry`
    using `verify`, then delegates to `bootstrapFromSnapshot`
    (which performs the AR.3.1 anchor check + the replay).

    Production callers supply the deployment's attestor public-key
    registry as `attestorRegistry`; for cross-replica scenarios
    this is typically the snapshot's own embedded
    `state.registry`, with the attestor's key registered ahead of
    the snapshot. -/
def bootstrapFromAttestedSnapshotWith
    (verify : Authority.PublicKey → ByteArray → Authority.Signature → Bool)
    (policy : AuthorityPolicy)
    (attestorRegistry : KeyRegistry)
    (att : AttestedSnapshot)
    (logPath : System.FilePath)
    (deploymentId : ByteArray := ByteArray.empty) :
    IO (Except AttestedBootstrapError (RuntimeState × Option FrameError)) := do
  -- 1. Attestor-signature gate.
  if ¬ verifyAttestationWith verify attestorRegistry att then
    pure (.error .unattested)
  else
    -- 2. Delegate to the inner bootstrap (which carries the
    --    AR.3.1 anchor check).
    match (← bootstrapFromSnapshot policy att.snap logPath deploymentId) with
    | .ok result => pure (.ok result)
    | .error e   => pure (.error (.inner e))

/-- AR.3.2 production entry: bootstrap from an attested snapshot
    using the production `Verify` opaque.  Back-compat alias for
    `bootstrapFromAttestedSnapshotWith Verify`. -/
def bootstrapFromAttestedSnapshot
    (policy : AuthorityPolicy)
    (attestorRegistry : KeyRegistry)
    (att : AttestedSnapshot)
    (logPath : System.FilePath)
    (deploymentId : ByteArray := ByteArray.empty) :
    IO (Except AttestedBootstrapError (RuntimeState × Option FrameError)) :=
  bootstrapFromAttestedSnapshotWith Verify policy attestorRegistry
                                    att logPath deploymentId

end Runtime
end LegalKernel
