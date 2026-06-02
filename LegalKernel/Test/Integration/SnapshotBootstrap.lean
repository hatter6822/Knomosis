-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

import LegalKernel.Test.Framework
import LegalKernel.Runtime.Loop
import LegalKernel.Runtime.Snapshot

/-!
LegalKernel.Test.Integration.SnapshotBootstrap — AR.23.2 + AR.23.3.

Integration regression for the AR.3.1 snapshot chain-anchor check.

AR.23.2 — exercise the rejection arm: a snapshot whose `seedHash`
does NOT match the actual hash of the pre-snapshot log prefix
must trigger `.anchorMismatch`.

AR.23.3 — exercise the acceptance arm: a snapshot whose `seedHash`
DOES match the actual hash of the pre-snapshot log prefix must
bootstrap cleanly and produce a `RuntimeState` whose state equals
the from-genesis replay's final state (extensional equality
sufficient — see CLAUDE.md footnote 1 for the toList-equality
discipline).
-/

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding
open LegalKernel.Test

namespace LegalKernel.Test.Integration.SnapshotBootstrap

/-- A deliberately-wrong seed hash: 32 bytes of `0xCC` (cannot equal
    any genuine hash output by sheer construction). -/
def wrongSeedHash : ContentHash :=
  ByteArray.mk ((List.replicate 32 (0xCC : UInt8))).toArray

/-- AR.23.2 — `bootstrapFromSnapshot` rejects a snapshot whose
    `seedHash` doesn't match the log's anchor.  This is the
    "wrong snapshot for this log" case the AR.3.1 anchor check
    was added to catch. -/
def wrongAnchorRejection : TestCase := {
  name := "AR.23.2: bootstrapFromSnapshot rejects wrong seedHash at empty log"
  body := do
    -- Construct an empty log file.
    let logPath := System.FilePath.mk "/tmp/knomosis-ar232-empty.log"
    if (← logPath.pathExists) then IO.FS.removeFile logPath
    IO.FS.writeBinFile logPath (ByteArray.mk #[])
    -- Construct a `Snapshot` with `baseIdx = 0` (so the genesis
    -- branch fires) but a wrong (non-zero) seedHash.  The AR.3.1
    -- anchor check should reject this because the genesis arm
    -- compares against `zeroHash`.
    let encodedState : ByteArray :=
      ByteArray.mk (Encodable.encode (T := ExtendedState) ExtendedState.empty).toArray
    let stateHash : ContentHash := hashEncodable ExtendedState.empty
    let snap : Snapshot :=
      { encodedState := encodedState
      , stateHash    := stateHash
      , seedHash     := wrongSeedHash
      , logIndex     := 0 }
    -- Bootstrap must reject with `.anchorMismatch`.
    match (← bootstrapFromSnapshot AuthorityPolicy.unrestricted snap logPath) with
    | .ok _ =>
      throw <| IO.userError
        "BUG: bootstrapFromSnapshot accepted a wrong-anchor snapshot"
    | .error .anchorMismatch => pure ()
    | .error other =>
      throw <| IO.userError s!"expected .anchorMismatch, got {repr other}"
}

/-- AR.23.3 — `bootstrapFromSnapshot` accepts a snapshot whose
    `seedHash = zeroHash` at the genesis anchor.  This is the
    counterpart to the rejection test: under the correct anchor,
    bootstrap should succeed and produce a `RuntimeState`
    equivalent to the genesis state. -/
def correctAnchorAcceptance : TestCase := {
  name := "AR.23.3: bootstrapFromSnapshot accepts genesis snapshot (anchor=zeroHash)"
  body := do
    -- Construct an empty log file.
    let logPath := System.FilePath.mk "/tmp/knomosis-ar233-empty.log"
    if (← logPath.pathExists) then IO.FS.removeFile logPath
    IO.FS.writeBinFile logPath (ByteArray.mk #[])
    -- Construct a `Snapshot` with `baseIdx = 0` and
    -- `seedHash = zeroHash` (the correct genesis anchor).
    let encodedState : ByteArray :=
      ByteArray.mk (Encodable.encode (T := ExtendedState) ExtendedState.empty).toArray
    let stateHash : ContentHash := hashEncodable ExtendedState.empty
    let snap : Snapshot :=
      { encodedState := encodedState
      , stateHash    := stateHash
      , seedHash     := zeroHash
      , logIndex     := 0 }
    match (← bootstrapFromSnapshot AuthorityPolicy.unrestricted snap logPath) with
    | .ok (rs, _) =>
      -- The bootstrapped RuntimeState's state has the same state
      -- hash as a fresh genesis bootstrap.
      let expectedHash := hashEncodable ExtendedState.empty
      if (hashEncodable rs.state).data == expectedHash.data then pure ()
      else throw <| IO.userError "bootstrap state hash diverged from genesis"
    | .error e =>
      throw <| IO.userError s!"correct-anchor bootstrap rejected: {repr e}"
}

/-- AR.23.3 — final-state equality between bootstrap-from-snapshot
    and replay-from-genesis at the empty-log baseline.  This is
    the AR.3.1 soundness counterpart: when the anchor matches,
    `bootstrapFromSnapshot` produces a state that's
    indistinguishable (by state-hash) from
    `bootstrap`-from-genesis.

    Workstream EI (EI.8.b) shipped the extensional-equality
    lemma `commitExtendedState_subcommits_extensional_eq_under_collision_free`
    that lifts hash-equality to per-sub-state `Equiv` equality.
    This baseline test continues to use the hash-equality check
    because it covers the empty-log path where the two states
    are structurally equal (and therefore both extensionally
    equal); a non-empty-log variant exercising the full
    `ExtendedState.extEq` chain would also rely on a deployment-
    side `Bridge.CollisionFree hashBytes` assumption that is
    out of scope for the integration suite. -/
def finalStateEqualsGenesis : TestCase := {
  name := "AR.23.3: bootstrap from genesis snapshot matches bootstrap from-genesis"
  body := do
    let logPath := System.FilePath.mk "/tmp/knomosis-ar233-final.log"
    if (← logPath.pathExists) then IO.FS.removeFile logPath
    IO.FS.writeBinFile logPath (ByteArray.mk #[])
    -- Path 1: bootstrap from genesis directly.
    let result1 ← bootstrap AuthorityPolicy.unrestricted ExtendedState.empty logPath
    -- Path 2: bootstrap from a genesis snapshot (baseIdx=0, seed=zeroHash).
    let encodedState : ByteArray :=
      ByteArray.mk (Encodable.encode (T := ExtendedState) ExtendedState.empty).toArray
    let snap : Snapshot :=
      { encodedState := encodedState
      , stateHash    := hashEncodable ExtendedState.empty
      , seedHash     := zeroHash
      , logIndex     := 0 }
    let result2 ← bootstrapFromSnapshot AuthorityPolicy.unrestricted snap logPath
    match result1, result2 with
    | .ok (rs1, _), .ok (rs2, _) =>
      -- State hashes must agree (the kernel observers see the
      -- same state extensionally).
      let h1 := hashEncodable rs1.state
      let h2 := hashEncodable rs2.state
      if h1.data == h2.data then pure ()
      else
        throw <| IO.userError
          "bootstrap-from-genesis and bootstrap-from-snapshot diverged"
    | _, _ =>
      throw <| IO.userError "one or both bootstrap paths failed"
}

/-- All AR.23.2 + AR.23.3 snapshot-bootstrap integration tests. -/
def tests : List TestCase :=
  [ wrongAnchorRejection
  , correctAnchorAcceptance
  , finalStateEqualsGenesis
  ]

end LegalKernel.Test.Integration.SnapshotBootstrap
