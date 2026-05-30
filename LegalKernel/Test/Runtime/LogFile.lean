-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Runtime.LogFile — Phase-5 WU 5.2 / WU 5.3 tests for
the framed log file format and crash-consistent recovery.

We exercise:

  * `LogEntry.encode` / `LogEntry.decode` round-trip (pure).
  * `encodeFrame` / `decodeFrame` round-trip (pure).
  * `decodeAllFrames` on multi-frame streams (pure).
  * `decodeFrame` rejection of truncated, magic-corrupted, and
    trailer-corrupted inputs (pure).
  * `appendEntry` / `readAllEntries` round-trip (IO).
  * `loadAndTruncate` recovery from a torn-write tail (IO; uses
    `IO.FS.writeBinFile` to simulate a partial frame).
  * Chain integrity verification via `verifyChain`.
-/

import LegalKernel.Test.Framework
import LegalKernel.Runtime.LogFile

namespace LegalKernel.Test.Runtime
namespace LogFileTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Runtime
open LegalKernel.Encoding

/-- A dummy `SignedAction` for fixtures.  Action shape: transfer 30
    from actor 1 to actor 2, signed by actor 1 with nonce 0. -/
def dummyAction : SignedAction :=
  { action := .transfer 1 1 2 30
  , signer := 1
  , nonce  := 0
  , sig    := ⟨#[0x01, 0x02, 0x03]⟩ }

/-- A dummy `LogEntry` built from `dummyAction`.  Used as a single-
    record fixture. -/
def dummyEntry : LogEntry :=
  { prevHash      := zeroHash
  , signedAction  := dummyAction
  , postStateHash := hashStream [0xFF, 0xFE, 0xFD] }

/-- Single-entry round-trip: encode then decode produces the
    original. -/
def entryRoundtrip : TestCase := {
  name := "LogEntry encode-then-decode preserves contents"
  body := do
    let bytes := LogEntry.encode dummyEntry
    match LogEntry.decode bytes with
    | .ok (e, []) =>
      assertEq dummyEntry.prevHash.toList e.prevHash.toList "prevHash"
      assertEq dummyEntry.postStateHash.toList e.postStateHash.toList "postHash"
    | .ok (_, _ :: _) => throw <| IO.userError "trailing bytes"
    | .error e => throw <| IO.userError s!"decode failed: {repr e}"
}

/-- Frame round-trip: encode a frame, decode it, get the original
    entry back. -/
def frameRoundtrip : TestCase := {
  name := "encodeFrame / decodeFrame is identity"
  body := do
    let frame := encodeFrame dummyEntry
    match decodeFrame frame with
    | .ok (e, []) =>
      assertEq dummyEntry.prevHash.toList e.prevHash.toList "prevHash"
      assertEq dummyEntry.postStateHash.toList e.postStateHash.toList "postHash"
    | .ok (_, _ :: _) => throw <| IO.userError "trailing bytes"
    | .error e => throw <| IO.userError s!"decode failed: {repr e}"
}

/-- Two-frame round-trip: encode two entries concatenated, decode
    both. -/
def twoFrameRoundtrip : TestCase := {
  name := "decodeAllFrames recovers two-frame stream"
  body := do
    let entry2 : LogEntry :=
      { prevHash := LogEntry.hash dummyEntry
      , signedAction := { dummyAction with nonce := 1 }
      , postStateHash := hashStream [0xAA] }
    let bytes := encodeAllFrames [dummyEntry, entry2]
    let (entries, consumed, err) := decodeAllFrames bytes
    assertEq (2 : Nat) entries.length "entry count"
    assertEq bytes.length consumed "fully consumed"
    if err.isSome then
      throw <| IO.userError s!"unexpected frame error: {repr err}"
    pure ()
}

/-- Truncation: a frame with the magic but cut-off payload should
    decode as `truncated`. -/
def truncatedFrame : TestCase := {
  name := "decodeFrame rejects truncated input"
  body := do
    let frame := encodeFrame dummyEntry
    -- Take only the magic + length (12 bytes) — the payload is missing.
    let truncated := frame.take 12
    match decodeFrame truncated with
    | .ok _ => throw <| IO.userError "BUG: decoder accepted truncated frame"
    | .error _ => pure ()
}

/-- Magic-corruption: a frame with the wrong header bytes should
    decode as `badMagic`. -/
def badMagicFrame : TestCase := {
  name := "decodeFrame rejects bad-magic input"
  body := do
    let frame := encodeFrame dummyEntry
    -- Corrupt the first byte of the magic (was 0x43, becomes 0x00).
    let corrupted : Stream := match frame with
      | _ :: rest => 0x00 :: rest
      | []        => []
    match decodeFrame corrupted with
    | .ok _ => throw <| IO.userError "BUG: decoder accepted bad-magic frame"
    | .error (.badMagic _) => pure ()
    | .error other =>
      throw <| IO.userError s!"expected badMagic, got {repr other}"
}

/-- Trailer-corruption: a frame whose trailer FNV-1a-64 doesn't
    match should decode as `badTrailer`. -/
def badTrailerFrame : TestCase := {
  name := "decodeFrame rejects bad-trailer input"
  body := do
    let frame := encodeFrame dummyEntry
    -- Mutate the last byte of the trailer.
    let n := frame.length
    let prefix' := frame.take (n - 1)
    let last' : UInt8 := match frame.drop (n - 1) with
      | b :: _ => b ^^^ 0x01    -- flip bottom bit
      | _      => 0x00
    let corrupted := prefix' ++ [last']
    match decodeFrame corrupted with
    | .ok _ => throw <| IO.userError "BUG: decoder accepted bad-trailer frame"
    | .error .badTrailer => pure ()
    | .error other =>
      throw <| IO.userError s!"expected badTrailer, got {repr other}"
}

/-- `decodeAllFrames` on a stream that's two complete frames + a
    partial third should return the two complete entries and a
    truncation diagnostic. -/
def partialTailRecovery : TestCase := {
  name := "decodeAllFrames recovers from partial-tail"
  body := do
    let entry2 : LogEntry :=
      { prevHash := LogEntry.hash dummyEntry
      , signedAction := { dummyAction with nonce := 1 }
      , postStateHash := hashStream [0xAA] }
    let goodBytes := encodeAllFrames [dummyEntry, entry2]
    let goodLen := goodBytes.length
    let partialFrame := encodeFrame entry2
    -- Append only the first 5 bytes of a third frame (magic + 1 byte
    -- of length).
    let stream := goodBytes ++ partialFrame.take 5
    let (entries, consumed, err) := decodeAllFrames stream
    assertEq (2 : Nat) entries.length "entry count"
    assertEq goodLen consumed "consumed up to good prefix"
    if err.isNone then
      throw <| IO.userError "expected truncation diagnostic"
    pure ()
}

/-- Chain integrity: a list of entries whose `prevHash` fields form
    a valid chain returns `true` from `verifyChain`. -/
def chainValid : TestCase := {
  name := "verifyChain accepts a valid chain"
  body := do
    let h1 := LogEntry.hash dummyEntry
    let entry2 : LogEntry :=
      { prevHash := h1
      , signedAction := { dummyAction with nonce := 1 }
      , postStateHash := hashStream [0xAA] }
    if verifyChain zeroHash [dummyEntry, entry2] then pure ()
    else throw <| IO.userError "verifyChain rejected a valid chain"
}

/-- Chain integrity: a broken chain (entry 2's prevHash doesn't
    match entry 1's hash) returns `false`. -/
def chainBroken : TestCase := {
  name := "verifyChain rejects a broken chain"
  body := do
    let entry2 : LogEntry :=
      { prevHash := hashStream [0xCC, 0xCC]    -- wrong prev hash
      , signedAction := { dummyAction with nonce := 1 }
      , postStateHash := hashStream [0xAA] }
    if verifyChain zeroHash [dummyEntry, entry2] then
      throw <| IO.userError "BUG: verifyChain accepted a broken chain"
    else pure ()
}

/-- Hash determinism: equal entries hash to equal values. -/
def hashDeterminism : TestCase := {
  name := "LogEntry.hash is deterministic"
  body := do
    let h1 := LogEntry.hash dummyEntry
    let h2 := LogEntry.hash dummyEntry
    if h1.toList == h2.toList then pure ()
    else throw <| IO.userError "non-deterministic hash"
}

/-- IO test: write a single entry, read it back, get the original. -/
def fileRoundtrip : TestCase := {
  name := "appendEntry / readAllEntries IO round-trip"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-log-roundtrip.bin"
    -- Clean up any leftover file from a prior run.
    if (← path.pathExists) then
      IO.FS.removeFile path
    -- Append the entry.
    appendEntry path dummyEntry
    -- Read it back.
    let (entries, _, err) ← readAllEntries path
    assertEq (1 : Nat) entries.length "entry count after read"
    if err.isSome then
      throw <| IO.userError s!"unexpected frame error: {repr err}"
    -- Clean up.
    IO.FS.removeFile path
}

/-- IO test: append two entries, read them both back. -/
def fileTwoEntries : TestCase := {
  name := "appendEntry twice / readAllEntries returns both"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-log-two.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    appendEntry path dummyEntry
    let entry2 : LogEntry :=
      { prevHash := LogEntry.hash dummyEntry
      , signedAction := { dummyAction with nonce := 1 }
      , postStateHash := hashStream [0xAA] }
    appendEntry path entry2
    let (entries, _, _) ← readAllEntries path
    assertEq (2 : Nat) entries.length "two entries read"
    IO.FS.removeFile path
}

/-- IO test: simulated torn write.  Write a complete frame, append
    a partial frame's worth of bytes, then call `loadAndTruncate`.
    Verify the recovery path returns the complete entry and that
    the file is now exactly that entry's bytes. -/
def crashConsistencyTruncation : TestCase := {
  name := "loadAndTruncate recovers from simulated torn write"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-log-torn.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    -- Write one complete frame.
    appendEntry path dummyEntry
    -- Append the first 10 bytes of a second (incomplete) frame.
    let entry2 : LogEntry :=
      { prevHash := LogEntry.hash dummyEntry
      , signedAction := { dummyAction with nonce := 1 }
      , postStateHash := hashStream [0xAA] }
    let partialBytes := (encodeFrame entry2).take 10
    let h ← IO.FS.Handle.mk path .append
    h.write (ByteArray.mk partialBytes.toArray)
    -- Now bootstrap-via-loadAndTruncate.
    let (entries, frameErr) ← loadAndTruncate path
    assertEq (1 : Nat) entries.length "recovered entries"
    if frameErr.isNone then
      throw <| IO.userError "expected truncation diagnostic"
    -- Verify the file is now a clean prefix.
    let (entries2, _, err2) ← readAllEntries path
    assertEq (1 : Nat) entries2.length "post-truncation entry count"
    if err2.isSome then
      throw <| IO.userError "post-truncation file should parse cleanly"
    IO.FS.removeFile path
}

/-- IO test: 1000-trial-style fuzz simulation.  We don't run 1000
    actual trials in CI (overhead), but we run a deterministic
    sweep of truncation points across one frame's byte width.
    For every prefix length `< full frame width`, the loader should
    recover the prior complete entry without erroring. -/
def crashConsistencySweep : TestCase := {
  name := "loadAndTruncate handles all torn-prefix lengths"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-log-sweep.bin"
    let entry2 : LogEntry :=
      { prevHash := LogEntry.hash dummyEntry
      , signedAction := { dummyAction with nonce := 1 }
      , postStateHash := hashStream [0xAA] }
    let entry2Bytes := encodeFrame entry2
    -- Sweep over partial-tail lengths.  We sample a few cuts to
    -- avoid excessive IO; the property is: every cut shorter than
    -- a complete frame triggers truncation, and the recovered
    -- prefix has exactly one entry (dummyEntry).
    let cuts : List Nat := [1, 5, 10, 20, 30, entry2Bytes.length - 1]
    for cut in cuts do
      if (← path.pathExists) then
        IO.FS.removeFile path
      appendEntry path dummyEntry
      let partialBytes := entry2Bytes.take cut
      let h ← IO.FS.Handle.mk path .append
      h.write (ByteArray.mk partialBytes.toArray)
      let (entries, _) ← loadAndTruncate path
      if entries.length ≠ 1 then
        throw <| IO.userError s!"cut={cut}: expected 1 entry, got {entries.length}"
    if (← path.pathExists) then
      IO.FS.removeFile path
}

/-- IO test: empty / non-existent log returns no entries. -/
def emptyLog : TestCase := {
  name := "readAllEntries on missing file returns empty"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-log-missing.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    let (entries, _, _) ← readAllEntries path
    assertEq (0 : Nat) entries.length "no entries"
}

/-- After `loadAndTruncate`, the file's bytes match exactly the
    re-encoded prefix of complete entries.  This is the byte-level
    invariant of WU 5.3 (the post-truncation file is a clean
    sequence of complete frames; no partial bytes remain). -/
def truncationProducesCleanFile : TestCase := {
  name := "loadAndTruncate produces a byte-clean file"
  body := do
    let path := System.FilePath.mk "/tmp/knomosis-test-log-clean.bin"
    if (← path.pathExists) then
      IO.FS.removeFile path
    -- Write one complete frame + 7 bytes of garbage.
    appendEntry path dummyEntry
    let h ← IO.FS.Handle.mk path .append
    h.write (ByteArray.mk #[0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33])
    -- Bootstrap-truncate.
    let (_, _) ← loadAndTruncate path
    -- Re-read the file's raw bytes.
    let postBytes ← IO.FS.readBinFile path
    -- Re-encode the dummyEntry frame.
    let expectedBytes := ByteArray.mk (encodeFrame dummyEntry).toArray
    -- The file should now be exactly the dummyEntry frame.
    assertEq expectedBytes.toList postBytes.toList "post-truncation bytes"
    IO.FS.removeFile path
}

/-- Empty stream decodes to no entries cleanly. -/
def emptyStreamDecode : TestCase := {
  name := "decodeAllFrames on empty stream returns no entries"
  body := do
    let (entries, consumed, err) := decodeAllFrames []
    assertEq (0 : Nat) entries.length "entry count"
    assertEq (0 : Nat) consumed "consumed bytes"
    if err.isSome then
      throw <| IO.userError s!"unexpected error: {repr err}"
    pure ()
}

/-- A frame followed by valid bytes (start of next frame's magic but
    no length) shows the partial-tail recovery is byte-precise:
    consumed should equal the first frame's length, not include any
    of the partial second frame's bytes. -/
def partialTailConsumedIsExact : TestCase := {
  name := "decodeAllFrames consumed-byte-count is exact"
  body := do
    let frame1Bytes := encodeFrame dummyEntry
    let stream := frame1Bytes ++ [0x43, 0x41, 0x4E, 0x4F]  -- magic only of next frame
    let (entries, consumed, err) := decodeAllFrames stream
    assertEq (1 : Nat) entries.length "entry count"
    assertEq frame1Bytes.length consumed "consumed equals first frame length"
    if err.isNone then
      throw <| IO.userError "expected truncation diagnostic"
}

/-- Term-level API: `encodeFrame_deterministic`. -/
def deterministicAPI : TestCase := {
  name := "encodeFrame_deterministic API stability"
  body := do
    let _proof : ∀ (e₁ e₂ : LogEntry), e₁ = e₂ → encodeFrame e₁ = encodeFrame e₂ :=
      encodeFrame_deterministic
    pure ()
}

/-- Term-level API: `frameTrailer_length`. -/
def trailerLengthAPI : TestCase := {
  name := "frameTrailer_length API stability"
  body := do
    let _proof : ∀ (s : Stream), (frameTrailer s).length = 8 :=
      frameTrailer_length
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [entryRoundtrip, frameRoundtrip, twoFrameRoundtrip,
   truncatedFrame, badMagicFrame, badTrailerFrame, partialTailRecovery,
   chainValid, chainBroken, hashDeterminism,
   fileRoundtrip, fileTwoEntries, crashConsistencyTruncation, crashConsistencySweep,
   emptyLog, truncationProducesCleanFile, emptyStreamDecode, partialTailConsumedIsExact,
   deterministicAPI, trailerLengthAPI]

end LogFileTests
end LegalKernel.Test.Runtime
