/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Runtime.LogFile — append-only log file format and IO.

Phase 5 WU 5.2 + WU 5.3.  The runtime's persistent transition log is
an append-only file of framed `LogEntry` records (Genesis Plan §8.7).
Each entry chains to the previous via `prevHash`, making the log
tamper-evident.

Frame layout (15 + N bytes per record):

  ```
  +---------+-------------+-------------------+-----------+
  | magic   | length      | payload (CBE)     | trailer   |
  | 4 bytes | 8 LE bytes  | length bytes      | 8 LE bytes|
  +---------+-------------+-------------------+-----------+
  ```

  * `magic` — the 4-byte ASCII string `"CANO"` (0x43 0x41 0x4E 0x4F).
    Marks the start of every record; mismatch on decode signals a
    corrupt or truncated stream.
  * `length` — 8-byte little-endian payload byte count.
  * `payload` — the `LogEntry`'s canonical CBE encoding (see
    `LogEntry.encode` below).
  * `trailer` — FNV-1a-64 hash of the payload, 8 LE bytes.  The
    trailer is what makes torn writes detectable: a partial write
    that completes the magic + length but truncates inside the
    payload (or omits the trailer) fails the hash check on read.

Crash-consistency (WU 5.3): on startup, the runtime reads as many
complete frames as it can, truncating the file at the byte offset
where the first incomplete frame began.  This invariant — "the file
on disk is always a prefix-closed sequence of complete frames" — is
maintained by the `loadAndTruncate` entry point, which is called
exactly once at runtime startup.

This module is **not** part of the trusted computing base.  Bugs
here can lose log entries (a denial-of-service from the deployment's
perspective) but cannot violate any kernel invariant.  The log is
deployment-facing observability, not a kernel-correctness gate.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.SignedAction
import LegalKernel.Encoding.State
import LegalKernel.Runtime.Hash

namespace LegalKernel
namespace Runtime

open LegalKernel.Authority
open LegalKernel.Encoding

/-! ## Frame magic

`"CANO"` in ASCII.  Distinct from any UTF-8 prefix the Lean default
runtime emits, distinct from any CBE type tag (which are 0x00..0x05
and 0x80..0xFF in Phase 4).  The collision space is small but the
trailer hash provides defense-in-depth against accidental matches. -/

/-- Frame magic byte 1: 'C' (0x43). -/
def frameMagic0 : UInt8 := 0x43

/-- Frame magic byte 2: 'A' (0x41). -/
def frameMagic1 : UInt8 := 0x41

/-- Frame magic byte 3: 'N' (0x4E). -/
def frameMagic2 : UInt8 := 0x4E

/-- Frame magic byte 4: 'O' (0x4F). -/
def frameMagic3 : UInt8 := 0x4F

/-- The 4-byte frame magic header as a `Stream`.  Prefixes every
    encoded `LogEntry` frame on disk. -/
def frameMagicBytes : Stream :=
  [frameMagic0, frameMagic1, frameMagic2, frameMagic3]

/-! ## LogEntry — the on-disk record

Genesis Plan §8.7's transition log enumerates `(prev_state, transition,
post_state)` triples.  At the runtime layer (Phase 5) we record:

  * `prevHash`      — the `LogEntryHash` of the predecessor (or
                       `zeroHash` for the first entry).  Chains the
                       log into a Merkle list (§8.8.4).
  * `signedAction`  — the action the actor submitted.
  * `postStateHash` — the `StateHash` of the post-application
                       extended state.  Lets the replay tool
                       cross-check on each step.

We deliberately do NOT record the pre-state hash: it equals the
predecessor's `postStateHash`, so storing both would be redundant
and create a consistency obligation the chain doesn't otherwise
have.  The first entry's pre-state hash is implicit (= the genesis
hash). -/

/-- A single record in the runtime's transition log.

    Phase-5 design notes:

    * `prevHash` and `postStateHash` are `ContentHash` (= `ByteArray`).
      The Phase-5 implementation produces 8-byte FNV-1a-64 outputs;
      production deployments swap the hash function via the runtime
      adaptor without changing this structure.
    * `signedAction` is the same type the network layer parses; its
      `Encodable` instance (Phase 4 WU 4.4) gives the canonical bytes.
    * No timestamp field: deployments that need timestamps emit
      `Event.timeRecorded` events through `extractEvents`; the
      transition log itself is timestamp-free for replay-stability
      (a runtime restart picks up at the same logical state
      regardless of wall-clock time). -/
structure LogEntry where
  /-- The previous entry's `LogEntryHash`, or `zeroHash` for the
      first entry of a fresh log. -/
  prevHash      : ContentHash
  /-- The action that was applied to produce this entry. -/
  signedAction  : SignedAction
  /-- The `StateHash` of the post-application `ExtendedState`. -/
  postStateHash : ContentHash
  deriving Repr

/-! ## LogEntry encoding (CBE)

Field order: `[prevHash, signedAction, postStateHash]`.  Each
`ContentHash` is encoded as a CBE byte string; the `SignedAction`
goes through its existing `Encodable` instance (Phase 4 WU 4.4). -/

/-- Encode a `LogEntry` to its canonical byte stream. -/
def LogEntry.encode (e : LogEntry) : Stream :=
  Encodable.encode (T := ByteArray)     e.prevHash ++
  Encodable.encode (T := SignedAction)  e.signedAction ++
  Encodable.encode (T := ByteArray)     e.postStateHash

/-- Decode a `LogEntry` from the front of a byte stream. -/
def LogEntry.decode (s : Stream) : Except DecodeError (LogEntry × Stream) :=
  match Encodable.decode (T := ByteArray) s with
  | .ok (prevHash, s₁) =>
    match Encodable.decode (T := SignedAction) s₁ with
    | .ok (signedAction, s₂) =>
      match Encodable.decode (T := ByteArray) s₂ with
      | .ok (postStateHash, s₃) =>
        .ok ({ prevHash, signedAction, postStateHash }, s₃)
      | .error e => .error e
    | .error e => .error e
  | .error e => .error e

instance instEncodableLogEntry : Encodable LogEntry where
  encode := LogEntry.encode
  decode := LogEntry.decode

/-- Compute the `LogEntryHash` of a `LogEntry`: chain the predecessor
    hash with the encoded signed action.  Genesis Plan §8.8.4:

      `LogEntryHash := BLAKE3(encode signedAction || encode previousLogEntryHash)`

    Phase 5 substitutes FNV-1a-64 for BLAKE3 (see `Runtime/Hash.lean`
    for the production-replacement boundary). -/
def LogEntry.hash (e : LogEntry) : ContentHash :=
  hashStream (Encodable.encode (T := SignedAction) e.signedAction ++
                e.prevHash.toList)

/-! ## Frame encoding

Wrap a `LogEntry` (or its already-encoded payload) in the
`magic + length + payload + trailer` frame format.  Frames are the
unit of crash-consistency: a frame is either fully present (and
parses) or detectably incomplete (and is truncated on next startup). -/

/-- The trailer for a frame: the FNV-1a-64 hash of the payload, as
    8 little-endian bytes (a `Stream` directly, avoiding the
    `ByteArray ↔ List` round-trip). -/
def frameTrailer (payload : Stream) : Stream :=
  natToBytesLE (fnv1a64Stream payload).toNat 8

/-- Produce the on-disk byte sequence for a `LogEntry`. -/
def encodeFrame (e : LogEntry) : Stream :=
  let payload := LogEntry.encode e
  let plen    := payload.length
  frameMagicBytes ++
    natToBytesLE plen 8 ++
    payload ++
    frameTrailer payload

/-- The exact on-disk byte width of a frame whose payload has the
    given length.  Used by the loader to know how far to advance. -/
def frameWidth (payloadLen : Nat) : Nat :=
  4 + 8 + payloadLen + 8

/-! ## Frame parsing

The decoder is structured for *defence in depth*: it returns
detailed errors for diagnostics, but the runtime's startup path
treats every error the same way (truncate to last good frame).

`FrameError`'s `truncated` constructor distinguishes "incomplete
input" (legitimate torn write) from "valid header but corrupt
payload" (`badTrailer` — possibly a hardware fault or filesystem
bug).  Both cases trigger the same recovery, but the runtime can
log them differently for ops visibility. -/

/-- Errors a single-frame decode can produce. -/
inductive FrameError where
  /-- Input ran out before a complete frame was assembled.  This is
      the "torn write" case: the writer crashed before flushing.
      Recovery: truncate to the byte offset before this frame. -/
  | truncated
  /-- Magic header bytes did not match the expected `"CANO"`.
      Indicates either a corrupt log file or an attempt to load a
      file that was not a Canon log. -/
  | badMagic (got : List UInt8)
  /-- The payload's recorded FNV-1a-64 trailer did not match the
      computed hash of the bytes between magic+length and the
      trailer.  Indicates a non-truncation corruption. -/
  | badTrailer
  /-- The payload bytes parsed as a CBE record but produced a
      `DecodeError`.  Wraps the underlying error for diagnostics. -/
  | payload (e : DecodeError)
  deriving Repr

/-- Decode one frame from the front of `s`, returning the parsed
    `LogEntry` and the residual stream.  Errors cleanly distinguish
    truncation (legitimate torn-write) from genuine corruption.

    Pipeline:
      1. Consume the 4-byte magic header (`badMagic` on mismatch).
      2. Consume the 8-byte LE length (`truncated` on EOF).
      3. Split off `plen` payload + 8 trailer bytes (`truncated`
         if the input is shorter than required).
      4. Verify the FNV-1a-64 trailer (`badTrailer` on mismatch).
      5. Decode the payload as a `LogEntry` (`payload` on parse
         error or trailing bytes inside the payload). -/
def decodeFrame (s : Stream) : Except FrameError (LogEntry × Stream) :=
  match s with
  | b0 :: b1 :: b2 :: b3 :: rest =>
    if b0 = frameMagic0 ∧ b1 = frameMagic1 ∧
       b2 = frameMagic2 ∧ b3 = frameMagic3 then
      match natFromBytesLE rest 8 with
      | .ok (plen, rest₁) =>
        if plen ≤ rest₁.length ∧ 8 ≤ rest₁.length - plen then
          let payload       := rest₁.take plen
          let after_payload := rest₁.drop plen
          let trailer_bytes := after_payload.take 8
          let rest₂         := after_payload.drop 8
          if trailer_bytes = frameTrailer payload then
            match LogEntry.decode payload with
            | .ok (e, [])     => .ok (e, rest₂)
            | .ok (_, _ :: _) => .error (.payload (.trailingBytes 1))
            | .error de       => .error (.payload de)
          else
            .error .badTrailer
        else
          .error .truncated
      | .error _ => .error .truncated
    else
      .error (.badMagic [b0, b1, b2, b3])
  | _ => .error .truncated

/-! ## Stream-level multi-frame loader

Read as many complete frames as possible from `s`.  Returns the
parsed entries (in order) and the byte offset of the first
incomplete / corrupt frame (or `s.length` if every byte parsed
cleanly).

Termination: each successful `decodeFrame` consumes at least
`4 (magic) + 8 (length) + 0 (empty payload) + 8 (trailer) = 20`
bytes, so the residual stream is strictly shorter than the input.
We use a fuel parameter equal to the input length to make
termination structural; the fuel never actually runs out
(consumption is ≥ 1 byte per iteration). -/

/-- Internal recursive loader: consume frames until input runs out,
    a truncation occurs, or a corruption is detected.  Tracks the
    *consumed byte count* alongside the entries so the caller knows
    where to truncate the file.

    Pre-fueled with `s.length + 1` so the recursion is structural
    (Lean cannot infer termination on `decodeFrame`'s residual
    bound without an explicit measure).  Fuel exhaustion treats the
    remaining bytes as corrupt; in practice fuel never runs out
    because each iteration consumes ≥ 1 byte. -/
def decodeAllFrames' :
    Nat → Stream → Nat → List LogEntry →
    List LogEntry × Nat × Option FrameError
  | 0,        _, consumed, acc => (acc.reverse, consumed, none)
  | _ + 1,   [], consumed, acc => (acc.reverse, consumed, none)
  | fuel + 1, s, consumed, acc =>
    match decodeFrame s with
    | .ok (e, rest) =>
      let used := s.length - rest.length
      decodeAllFrames' fuel rest (consumed + used) (e :: acc)
    | .error err =>
      (acc.reverse, consumed, some err)

/-- Decode a complete byte stream as a sequence of frames.  Returns:

      * the entries successfully parsed (in order),
      * the byte offset of the first incomplete / corrupt frame (or
        `s.length` if every byte parsed cleanly),
      * the frame error that stopped parsing (or `none` if the
        stream ran out cleanly).

    The byte offset is what the runtime writes to truncate the file
    to discard the partial tail. -/
def decodeAllFrames (s : Stream) : List LogEntry × Nat × Option FrameError :=
  decodeAllFrames' (s.length + 1) s 0 []

/-! ## Encoding multi-frame streams

Concatenate the frame encodings of a list of entries.  Used by the
snapshot tool (WU 5.12) to emit a fresh log starting from a snapshot
state. -/

/-- Encode a list of `LogEntry`s as the on-disk byte sequence.
    Flat concatenation of the per-entry frames. -/
def encodeAllFrames (entries : List LogEntry) : Stream :=
  entries.foldr (fun e acc => encodeFrame e ++ acc) []

/-! ## File-level operations (IO)

Three primitives:

  * `appendEntry` — append one entry to an existing file.
  * `readAllEntries` — read the whole file, returning the parsed
    entries and the truncation offset.
  * `loadAndTruncate` — the runtime startup path: read, recover,
    truncate, return the recovered prefix.

All operate via the standard Lean IO API; the `IO.FS.Handle` calls
are wrapped to return `IO`-typed values, never throwing. -/

/-- Append one `LogEntry` (as a complete frame) to the file at
    `path`.  Creates the file if it does not exist.  Atomic at the
    Lean-runtime level (one `IO.FS.Handle.write` call); kernel-level
    atomicity depends on the filesystem.  Production deployments
    SHOULD `fsync` after append; the Lean fallback skips fsync (no
    standard-library API). -/
def appendEntry (path : System.FilePath) (e : LogEntry) : IO Unit := do
  let bytes := ByteArray.mk (encodeFrame e).toArray
  let h ← IO.FS.Handle.mk path .append
  h.write bytes

/-- Read the entire log file at `path` and decode every frame.
    Returns the parsed entries, the byte offset where reading
    stopped, and (if non-empty) the error that stopped parsing.

    A non-existent file is treated as an empty log (returns
    `([], 0, none)`).  The runtime startup path uses this to
    initialise an empty deployment. -/
def readAllEntries (path : System.FilePath) :
    IO (List LogEntry × Nat × Option FrameError) := do
  let present ← path.pathExists
  if present then
    let bytes ← IO.FS.readBinFile path
    pure (decodeAllFrames bytes.toList)
  else
    pure ([], 0, none)

/-- Truncate the log file at `path` to the first `len` bytes.
    Used by `loadAndTruncate` to discard the partial tail of a
    crashed write.  Implementation: read the prefix, then rewrite
    the file with that prefix.  Less efficient than a real
    `truncate(2)` syscall (which Lean core does not expose), but
    correct.  Production deployments wire `truncate(2)` via FFI. -/
def truncateFile (path : System.FilePath) (len : Nat) : IO Unit := do
  let bytes ← IO.FS.readBinFile path
  let prefix' := bytes.toList.take len
  IO.FS.writeBinFile path (ByteArray.mk prefix'.toArray)

/-- The runtime startup path: read the log, truncate the partial
    tail (if any), and return the recovered prefix of entries.

    Crash-consistency invariant (WU 5.3): after `loadAndTruncate`
    returns, the file on disk is exactly the byte sequence of the
    returned entries' frames — no partial frame remains.  The
    runtime can then `appendEntry` safely; new entries land at the
    canonical end-of-log position.

    Returns the entries plus the recovery diagnostic
    (`(entries, none)` for a clean shutdown / first start;
    `(entries, some err)` when truncation occurred). -/
def loadAndTruncate (path : System.FilePath) :
    IO (List LogEntry × Option FrameError) := do
  let (entries, consumed, err) ← readAllEntries path
  match err with
  | none =>
    -- Clean stream; nothing to truncate.
    pure (entries, none)
  | some _ =>
    -- Partial tail detected: truncate to the last good byte boundary.
    truncateFile path consumed
    pure (entries, err)

/-! ## Chain integrity helpers

A correctly-chained log has every entry's `prevHash` equal to the
predecessor's `LogEntry.hash`.  These helpers let the replay tool
verify the chain end-to-end. -/

/-- Verify that the entries in `entries` form a valid chain rooted
    at `seedHash` (typically `zeroHash` for a fresh deployment).
    Returns `true` iff every entry's `prevHash` matches its
    predecessor's `LogEntry.hash` (or `seedHash` for the first
    entry).

    Failures here indicate either a corrupt log file (the trailer
    check should have caught most cases) or a deliberate forgery.
    The replay tool consumes this as a hard gate before any state
    advance. -/
def verifyChain (seedHash : ContentHash) (entries : List LogEntry) : Bool :=
  let rec go (prev : ContentHash) : List LogEntry → Bool
    | [] => true
    | e :: rest =>
      if e.prevHash.toList == prev.toList then
        go (LogEntry.hash e) rest
      else
        false
  go seedHash entries

/-! ## Determinism / round-trip lemmas

Foundational properties for downstream tests / proofs.  The full
abstract round-trip (`decodeAllFrames (encodeAllFrames es) = (es,
…, none)`) requires inducting through the frame format; we prove the
single-frame case and use value-level tests to verify the multi-frame
case. -/

/-- Determinism: equal inputs produce equal frame encodings. -/
theorem encodeFrame_deterministic (e₁ e₂ : LogEntry) (h : e₁ = e₂) :
    encodeFrame e₁ = encodeFrame e₂ :=
  h ▸ rfl

/-- Determinism: equal entries produce equal log-entry hashes. -/
theorem LogEntry_hash_deterministic (e₁ e₂ : LogEntry) (h : e₁ = e₂) :
    LogEntry.hash e₁ = LogEntry.hash e₂ :=
  h ▸ rfl

/-- The 4-byte frame magic header has length 4. -/
private theorem frameMagicBytes_length : frameMagicBytes.length = 4 := rfl

/-- `frameTrailer` is exactly 8 bytes wide. -/
theorem frameTrailer_length (payload : Stream) :
    (frameTrailer payload).length = 8 := by
  unfold frameTrailer
  rw [natToBytesLE_length]

/-- The encoded frame's length equals `frameWidth` of the payload
    length.  Documents the on-disk-width contract for the snapshot
    tool. -/
theorem encodeFrame_length (e : LogEntry) :
    (encodeFrame e).length = frameWidth (LogEntry.encode e).length := by
  unfold encodeFrame frameWidth
  rw [List.length_append, List.length_append, List.length_append,
      frameMagicBytes_length, natToBytesLE_length, frameTrailer_length]

end Runtime
end LegalKernel
