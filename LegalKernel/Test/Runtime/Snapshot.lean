-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Runtime.Snapshot — Phase-5 WU 5.12 tests for
state snapshots and replica bootstrap.

We exercise:

  * `takeSnapshot` produces a record whose `stateHash` matches the
    state's `hashEncodable` value.
  * `restoreSnapshot` round-trips: a snapshot encoding the genesis
    state restores to a state with the same balances and the
    correct seed hash + log index.
  * `Snapshot.encode` / `decode` round-trip preserves the
    `(stateHash, encodedState, logIndex, seedHash)` quadruple.
  * `restoreSnapshot` rejects a tampered `encodedState` with
    `hashMismatch`.
  * Replica bootstrap from a snapshot + empty tail reaches the same
    state as the snapshot itself.
-/

import LegalKernel.Test.Framework
import LegalKernel.Runtime.Snapshot

namespace LegalKernel.Test.Runtime
namespace SnapshotTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding

/-- Test policy: unrestricted. -/
def policy : AuthorityPolicy := AuthorityPolicy.unrestricted

/-- A populated genesis state: actor 1 holds 100 of resource 1. -/
def populatedGenesis : ExtendedState :=
  { base    := setBalance ({ balances := ∅ }) 1 1 100
  , nonces  := { next := ∅ }
  , registry := KeyRegistry.empty }

/-- `takeSnapshot` correctly populates the four fields. -/
def takeSnapshotShape : TestCase := {
  name := "takeSnapshot populates fields correctly"
  body := do
    let snap := takeSnapshot populatedGenesis zeroHash 5
    assertEq (5 : Nat) snap.logIndex "logIndex"
    assertEq (zeroHash.toList) (snap.seedHash.toList) "seedHash"
    let expectedStateHash := hashEncodable populatedGenesis
    assertEq (expectedStateHash.toList) (snap.stateHash.toList) "stateHash"
}

/-- Snapshot encode / decode round-trip. -/
def snapshotRoundtrip : TestCase := {
  name := "Snapshot encode / decode preserves all fields"
  body := do
    let snap := takeSnapshot populatedGenesis zeroHash 5
    let bytes := Snapshot.encode snap
    match Snapshot.decode bytes with
    | .ok (snap', []) =>
      assertEq snap.stateHash.toList snap'.stateHash.toList "stateHash"
      assertEq snap.logIndex snap'.logIndex "logIndex"
      assertEq snap.seedHash.toList snap'.seedHash.toList "seedHash"
      -- encodedState bytes should be byte-identical
      assertEq snap.encodedState.toList snap'.encodedState.toList "encodedState"
    | .ok (_, _ :: _) => throw <| IO.userError "trailing bytes"
    | .error e => throw <| IO.userError s!"decode failed: {repr e}"
}

/-- `restoreSnapshot` recovers the original state. -/
def restoreSnapshotState : TestCase := {
  name := "restoreSnapshot recovers state at every probed cell"
  body := do
    let snap := takeSnapshot populatedGenesis zeroHash 0
    match restoreSnapshot snap with
    | .ok (state, seedHash, idx) =>
      assertEq (LegalKernel.getBalance populatedGenesis.base 1 1)
        (LegalKernel.getBalance state.base 1 1) "balance for (1, 1)"
      assertEq (LegalKernel.getBalance populatedGenesis.base 5 5)
        (LegalKernel.getBalance state.base 5 5) "balance for (5, 5)"
      assertEq (zeroHash.toList) (seedHash.toList) "seedHash"
      assertEq (0 : Nat) idx "logIndex"
    | .error e => throw <| IO.userError s!"restore failed: {repr e}"
}

/-- `restoreSnapshot` rejects a tampered state hash. -/
def restoreSnapshotTampered : TestCase := {
  name := "restoreSnapshot rejects tampered stateHash"
  body := do
    let snap := takeSnapshot populatedGenesis zeroHash 0
    let tampered := { snap with stateHash := hashStream [0xDE, 0xAD] }
    match restoreSnapshot tampered with
    | .ok _ =>
      throw <| IO.userError "BUG: accepted tampered snapshot"
    | .error .hashMismatch => pure ()
    | .error e =>
      throw <| IO.userError s!"expected hashMismatch, got {repr e}"
}

/-- Replica bootstrap from snapshot + empty tail reaches the same
    state. -/
def bootstrapEmptyTail : TestCase := {
  name := "replicaFromSnapshot with empty tail reproduces state"
  body := do
    let snap := takeSnapshot populatedGenesis zeroHash 0
    match replicaFromSnapshot policy snap [] with
    | .ok finalState =>
      assertEq (LegalKernel.getBalance populatedGenesis.base 1 1)
        (LegalKernel.getBalance finalState.base 1 1) "balance"
    | .error e => throw <| IO.userError s!"bootstrap failed: {repr e}"
}

/-- IO test: save snapshot, load it back, verify equality. -/
def snapshotFileRoundtrip : TestCase := {
  name := "saveSnapshot / loadSnapshot IO round-trip"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-snapshot.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    let snap := takeSnapshot populatedGenesis zeroHash 7
    saveSnapshot path snap
    match (← loadSnapshot path) with
    | .ok snap' =>
      assertEq snap.stateHash.toList snap'.stateHash.toList "stateHash"
      assertEq snap.logIndex snap'.logIndex "logIndex"
    | .error e => throw <| IO.userError s!"loadSnapshot failed: {repr e}"
    IO.FS.removeFile path
}

/-- Term-level API: `takeSnapshot_deterministic`. -/
def deterministicAPI : TestCase := {
  name := "takeSnapshot_deterministic API stability"
  body := do
    let _proof : ∀ (s₁ s₂ : ExtendedState) (h₁ h₂ : ContentHash) (i₁ i₂ : Nat),
                   s₁ = s₂ → h₁ = h₂ → i₁ = i₂ →
                   takeSnapshot s₁ h₁ i₁ = takeSnapshot s₂ h₂ i₂ :=
      takeSnapshot_deterministic
    pure ()
}

/-- Encoding determinism: `Snapshot.encode` is a pure function. -/
def encodeDeterministic : TestCase := {
  name := "Snapshot.encode is byte-deterministic"
  body := do
    let snap := takeSnapshot populatedGenesis zeroHash 5
    let bytes1 := Snapshot.encode snap
    let bytes2 := Snapshot.encode snap
    if bytes1 == bytes2 then pure ()
    else throw <| IO.userError "non-deterministic Snapshot.encode"
}

/-- Snapshot file format detects truncation: a partially-written
    snapshot file should fail to decode rather than silently
    producing a wrong snapshot. -/
def truncatedSnapshotFile : TestCase := {
  name := "loadSnapshot rejects truncated file"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-snap-truncated.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    let snap := takeSnapshot populatedGenesis zeroHash 0
    let fullBytes := Snapshot.encode snap
    -- Truncate to half size — definitely incomplete.
    let truncated := fullBytes.take (fullBytes.length / 2)
    IO.FS.writeBinFile path (ByteArray.mk truncated.toArray)
    match (← loadSnapshot path) with
    | .ok _ =>
      throw <| IO.userError "BUG: loadSnapshot accepted truncated file"
    | .error _ => pure ()
    IO.FS.removeFile path
}

/-- `replicaFromSnapshot` preserves the snapshot's state at the
    correct seed hash, so a downstream replay continues correctly. -/
def replicaFromSnapshotPreservesState : TestCase := {
  name := "replicaFromSnapshot preserves snapshot state"
  body := do
    let seed := hashStream [0x42, 0x42]
    let snap := takeSnapshot populatedGenesis seed 7
    match replicaFromSnapshot policy snap [] with
    | .ok finalState =>
      assertEq (LegalKernel.getBalance populatedGenesis.base 1 1)
        (LegalKernel.getBalance finalState.base 1 1) "actor 1 balance"
      let hash1 := hashEncodable populatedGenesis
      let hash2 := hashEncodable finalState
      if hash1.toList != hash2.toList then
        throw <| IO.userError "state hashes differ after empty-tail bootstrap"
    | .error e => throw <| IO.userError s!"replicaFromSnapshot failed: {repr e}"
}

/-- `loadSnapshot` on a missing file returns `.unexpectedEof`
    instead of throwing.  Audit fix: makes the caller's error
    surface uniform. -/
def loadSnapshotMissingFile : TestCase := {
  name := "loadSnapshot on missing file returns DecodeError"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-snap-nonexistent.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    match (← loadSnapshot path) with
    | .ok _ =>
      throw <| IO.userError "BUG: accepted nonexistent snapshot file"
    | .error _ => pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [takeSnapshotShape, snapshotRoundtrip, restoreSnapshotState,
   restoreSnapshotTampered, bootstrapEmptyTail, snapshotFileRoundtrip,
   encodeDeterministic, truncatedSnapshotFile, replicaFromSnapshotPreservesState,
   loadSnapshotMissingFile, deterministicAPI]

end SnapshotTests
end LegalKernel.Test.Runtime
