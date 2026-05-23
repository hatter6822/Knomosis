/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Runtime.Snapshot — state snapshot + incremental log shipping.

Phase 5 WU 5.12.  Snapshots let new replicas (or recovering nodes
that fell behind) start from a recent state hash and apply only
subsequent log entries, rather than replaying the entire history
from genesis.  This is the production deployment story: as the log
grows from megabytes to gigabytes, replay-from-genesis becomes
infeasible; snapshots keep the recovery cost bounded.

Genesis Plan §13.2 acceptance: "A snapshot is a `(StateHash,
encoded State)` pair plus the log index from which it was taken.
New replicas can start from a snapshot and apply only subsequent
log entries.  Acceptance: replica started from snapshot reaches
same final state as one started from genesis."

Phase 5 implementation:

  * `Snapshot` carries `(stateHash, encodedState, logIndex,
    seedHash)`.  `seedHash` is the predecessor hash for replay
    starting from this snapshot — it equals the `LogEntry.hash` of
    the entry at `logIndex - 1` (or `zeroHash` if the snapshot is
    of genesis).
  * `takeSnapshot` produces a snapshot from the current
    `(state, prevHash, index)`.
  * `restoreSnapshot` decodes the snapshot back into a usable
    `(state, prevHash, index)` triple.
  * `Snapshot.encode` / `decode` provide the canonical bytes for
    on-disk persistence.
  * `replicaFromSnapshot` is the headline operation: load
    `(snapshot, log_after_snapshot_index)`, replay, return the
    final state.

This module is **not** part of the trusted computing base.  Bugs
here can produce wrong replica states (a deployment-level
diagnostic problem) but cannot violate any kernel invariant.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.State
import LegalKernel.Runtime.Hash
import LegalKernel.Runtime.LogFile
import LegalKernel.Runtime.Replay

namespace LegalKernel
namespace Runtime

open LegalKernel.Authority
open LegalKernel.Encoding

/-! ## The Snapshot record

A `Snapshot` carries everything a fresh replica needs to resume
processing without replaying from genesis:

  * `stateHash`     — the hash of the snapshotted `ExtendedState`.
                       Lets the replica verify the snapshot bytes
                       are the ones it expected.
  * `encodedState`  — the canonical CBE bytes of the
                       `ExtendedState` as of `logIndex` entries.
                       The replica decodes this to recover the
                       starting state.
  * `logIndex`      — the number of log entries that had been
                       applied when the snapshot was taken.  The
                       replica then reads log entries `[logIndex,
                       …)` from the canonical log to advance past
                       the snapshot.
  * `seedHash`      — the `LogEntry.hash` of the entry at index
                       `logIndex - 1` (or `zeroHash` when
                       `logIndex = 0`).  Used as the predecessor
                       hash for the chain check on the first
                       post-snapshot log entry. -/
/-- A snapshot of the runtime's `ExtendedState` at a specific log
    index.  Lets a fresh replica resume processing without replaying
    from genesis: the replica decodes `encodedState`, verifies the
    hash, and then replays only `[logIndex, …)` from the canonical
    log.  Genesis Plan §13.2 / Phase 5 WU 5.12. -/
structure Snapshot where
  /-- Hash of the snapshotted state.  Replica integrity check. -/
  stateHash    : ContentHash
  /-- CBE-encoded `ExtendedState` bytes. -/
  encodedState : ByteArray
  /-- Number of log entries applied at snapshot time. -/
  logIndex     : Nat
  /-- Predecessor `LogEntry.hash` for the first post-snapshot entry. -/
  seedHash     : ContentHash
  deriving Repr

/-! ## Snapshot encoding (CBE)

Field order: `[stateHash, encodedState, logIndex, seedHash]`.  We
encode `logIndex` as a CBE uint, the two hashes as CBE bytestrings,
and `encodedState` as a CBE bytestring (it is an opaque byte blob
from the snapshot's perspective). -/

/-- Encode a `Snapshot` to its canonical byte stream. -/
def Snapshot.encode (snap : Snapshot) : Stream :=
  Encodable.encode (T := ByteArray) snap.stateHash ++
  Encodable.encode (T := ByteArray) snap.encodedState ++
  Encodable.encode (T := Nat)       snap.logIndex ++
  Encodable.encode (T := ByteArray) snap.seedHash

/-- Decode a `Snapshot` from the front of a byte stream. -/
def Snapshot.decode (s : Stream) : Except DecodeError (Snapshot × Stream) :=
  match Encodable.decode (T := ByteArray) s with
  | .ok (stateHash, s₁) =>
    match Encodable.decode (T := ByteArray) s₁ with
    | .ok (encodedState, s₂) =>
      match Encodable.decode (T := Nat) s₂ with
      | .ok (logIndex, s₃) =>
        match Encodable.decode (T := ByteArray) s₃ with
        | .ok (seedHash, s₄) =>
          .ok ({ stateHash, encodedState, logIndex, seedHash }, s₄)
        | .error e => .error e
      | .error e => .error e
    | .error e => .error e
  | .error e => .error e

instance instEncodableSnapshot : Encodable Snapshot where
  encode := Snapshot.encode
  decode := Snapshot.decode

/-! ## Building / reading snapshots -/

/-- Take a snapshot of the current `(state, predecessorHash,
    logIndex)`.  Returns the snapshot record; the caller persists
    it via `IO.FS.writeBinFile` or similar. -/
def takeSnapshot (state : ExtendedState) (seedHash : ContentHash)
    (logIndex : Nat) : Snapshot :=
  { stateHash    := hashEncodable state
  , encodedState := Encodable.encodeBytes (T := ExtendedState) state
  , logIndex     := logIndex
  , seedHash     := seedHash }

/-! ## Restoring from a snapshot

`restoreSnapshot` decodes the snapshot's `encodedState` field and
verifies that its hash matches `stateHash`.  Failure indicates
either a corrupt snapshot file or a mismatched hash function (e.g.
the snapshot was produced by a build that used BLAKE3 but the
restore is happening on a build that uses FNV-1a-64). -/

/-- Errors during snapshot restoration. -/
inductive SnapshotError where
  /-- The `encodedState` bytes failed to parse as an
      `ExtendedState`.  Indicates a corrupt snapshot or schema
      mismatch. -/
  | decode (e : DecodeError)
  /-- The decoded state's hash does not match the snapshot's
      recorded `stateHash`.  Indicates either snapshot tampering
      or a hash-function mismatch between snapshot creator and
      consumer. -/
  | hashMismatch
  deriving Repr

/-- Restore a snapshot to a usable `(state, seedHash, logIndex)`
    triple.  Verifies the state hash before returning. -/
def restoreSnapshot (snap : Snapshot) :
    Except SnapshotError (ExtendedState × ContentHash × Nat) :=
  match Encodable.decodeAllBytes (T := ExtendedState) snap.encodedState with
  | .ok state =>
    if (hashEncodable state).toList = snap.stateHash.toList then
      .ok (state, snap.seedHash, snap.logIndex)
    else
      .error .hashMismatch
  | .error e => .error (.decode e)

/-! ## Replica bootstrap from snapshot

The headline operation: take a snapshot + log tail, produce the
final state.  Acceptance criterion (Genesis Plan §13.2): the
replica's final state matches that of a node that replayed from
genesis.

Implementation: restore the snapshot, then call
`Replay.replayFromSeed` on the log tail. -/

/-- Errors during replica bootstrap from a snapshot.  Disambiguated
    from `Loop.BootstrapError` by name (`ReplicaError`) — they share
    the `LegalKernel.Runtime` namespace, and replica bootstrap is
    only one of two possible startup paths the runtime can take. -/
inductive ReplicaError where
  /-- Snapshot restoration failed. -/
  | snapshot (e : SnapshotError)
  /-- Replay of the post-snapshot log tail failed. -/
  | replay (e : ReplayError)
  deriving Repr

/-- Bootstrap a fresh replica from `snap` plus the log entries
    written *after* the snapshot was taken (i.e. log entries from
    index `snap.logIndex` onwards).

    Returns the final `ExtendedState` on success.  Failure can
    come from either snapshot restoration or replay. -/
def replicaFromSnapshot
    (P : AuthorityPolicy) (snap : Snapshot) (logTail : List LogEntry) :
    Except ReplicaError ExtendedState :=
  match restoreSnapshot snap with
  | .ok (state, seedHash, _idx) =>
    match replayFromSeed P seedHash state logTail with
    | .ok finalState => .ok finalState
    | .error e       => .error (.replay e)
  | .error e => .error (.snapshot e)

/-! ## Snapshot file IO

Convenience wrappers for persisting / loading snapshots from a
single file.  The file format is just `Snapshot.encode` bytes — no
framing (a snapshot file is read as a single record, not as a
stream). -/

/-- Write a snapshot to `path`.  Overwrites any existing file. -/
def saveSnapshot (path : System.FilePath) (snap : Snapshot) : IO Unit := do
  let bytes := ByteArray.mk (Snapshot.encode snap).toArray
  IO.FS.writeBinFile path bytes

/-- Read a snapshot from `path`.  Returns either the parsed snapshot
    or a `DecodeError` if the file's bytes failed to parse.

    A non-existent file is reported as `DecodeError.unexpectedEof`
    rather than letting the underlying `readBinFile` throw an
    `IO.Error`; this makes the caller's error surface uniform
    (every recoverable failure is a `DecodeError`, and only IO
    errors that the snapshot logic genuinely cannot handle —
    e.g. permission denied — propagate as exceptions). -/
def loadSnapshot (path : System.FilePath) :
    IO (Except DecodeError Snapshot) := do
  let present ← path.pathExists
  if present then
    let bytes ← IO.FS.readBinFile path
    pure (Encodable.decodeAllBytes (T := Snapshot) bytes)
  else
    pure (.error .unexpectedEof)

/-! ## Determinism (the WU 5.12 acceptance gate)

`takeSnapshot` is a function and trivially deterministic.  The
acceptance "replica started from snapshot reaches the same final
state as a fresh-replay-from-genesis replica" is the
`replicaFromSnapshot` value-level test in
`LegalKernel/Test/Runtime/Snapshot.lean`. -/

/-- Determinism: equal inputs to `takeSnapshot` produce equal
    snapshot records. -/
theorem takeSnapshot_deterministic
    (state₁ state₂ : ExtendedState) (seed₁ seed₂ : ContentHash)
    (idx₁ idx₂ : Nat)
    (h_s : state₁ = state₂) (h_h : seed₁ = seed₂) (h_i : idx₁ = idx₂) :
    takeSnapshot state₁ seed₁ idx₁ = takeSnapshot state₂ seed₂ idx₂ := by
  rw [h_s, h_h, h_i]

end Runtime
end LegalKernel
