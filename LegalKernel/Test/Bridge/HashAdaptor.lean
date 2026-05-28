/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.HashAdaptor — Workstream A.2 stability tests.

The Lean-level acceptance contract for the keccak256 hash adaptor
(see `LegalKernel/Bridge/HashAdaptor.lean`).  Like the verify
adaptor's tests (§5.1), the actual cryptographic correctness lives
in the Rust crate's test suite (`runtime/knomosis-hash-keccak256/tests/`)
and runs against `geth`'s keccak256 outputs; the Lean side cannot
exercise this directly because the production binding swaps in
keccak256 only at runtime via `@[extern]`.

What this suite covers:

  * **Identifier-distinctness tests.**  The keccak256 adaptor
    identifier and the fallback identifier are different strings —
    catches a future bug where the adaptor accidentally reports
    the fallback identifier.
  * **KAT-vector shape tests.**  Each reference KAT vector is 32
    bytes (matching keccak256's output width).
  * **Output-shape tests.**  `hashBytes` always produces 32-byte
    output for every input (the §5.2 invariant
    `hashAdaptor_thirty_two_byte_output`).
  * **Determinism tests.**  Equal inputs to `hashBytes` produce
    equal outputs.
  * **Conditional KAT-match tests.**  When the production binding
    is linked (`isKeccak256Linked = true`), the empty-input output
    matches `kat_empty`; when on the fallback (the Lean-level
    case), the empty-input output matches
    `expectedFallbackEmptyHash`.  This closes the loop on "what
    does *this* binding actually compute?".
  * **Term-level API stability** for the bridge-namespace stability
    theorems.
-/

import LegalKernel
import LegalKernel.Bridge.HashAdaptor
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge
namespace HashAdaptorTests

open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Encoding
open LegalKernel.Test

/-! ## Identifier-distinctness tests -/

/-- The keccak256 adaptor identifier is distinct from the fallback. -/
def keccak256IdDistinct : TestCase := {
  name := "keccak256AdaptorIdentifier ≠ fallbackHashIdentifier"
  body := do
    if keccak256AdaptorIdentifier = fallbackHashIdentifier then
      throw <| IO.userError "keccak256 and fallback identifiers collided"
}

/-- The keccak256 adaptor identifier has the documented value. -/
def keccak256IdValue : TestCase := {
  name := "keccak256AdaptorIdentifier value matches §5.2 spec"
  body := do
    assertEq (expected := "keccak256/EVM-compatible/v1")
      (actual := keccak256AdaptorIdentifier) "identifier value"
}

/-- At the Lean level, `isKeccak256Linked` is `false` (since the
    production binding is wired only at runtime via `@[extern]`). -/
def isKeccak256LinkedLean : TestCase := {
  name := "isKeccak256Linked = false at the Lean level"
  body := do
    if isKeccak256Linked then
      throw <| IO.userError
        "isKeccak256Linked returned true at the Lean level — production binding leaked"
}

/-! ## KAT-vector shape tests -/

/-- All four reference KAT vectors are 32 bytes. -/
def katEmptySize : TestCase := {
  name := "kat_empty is 32 bytes"
  body := assertEq (expected := 32) (actual := kat_empty.size) "kat_empty size"
}

/-- `kat_abc` is 32 bytes. -/
def katAbcSize : TestCase := {
  name := "kat_abc is 32 bytes"
  body := assertEq (expected := 32) (actual := kat_abc.size) "kat_abc size"
}

/-- `kat_helloWorld` is 32 bytes. -/
def katHelloWorldSize : TestCase := {
  name := "kat_helloWorld is 32 bytes"
  body := assertEq (expected := 32) (actual := kat_helloWorld.size) "kat_helloWorld size"
}

/-- `kat_singleZero` is 32 bytes. -/
def katSingleZeroSize : TestCase := {
  name := "kat_singleZero is 32 bytes"
  body := assertEq (expected := 32) (actual := kat_singleZero.size) "kat_singleZero size"
}

/-- `expectedFallbackEmptyHash` is 32 bytes. -/
def fallbackEmptyHashSize : TestCase := {
  name := "expectedFallbackEmptyHash is 32 bytes"
  body := assertEq (expected := 32) (actual := expectedFallbackEmptyHash.size)
    "fallback hash size"
}

/-! ## KAT-vector value sanity (a shifted byte would surface here)

We sample a single byte from each KAT vector to pin its leading
byte.  This catches a copy-paste bug where the same constant was
duplicated under two names. -/

/-- `kat_empty` starts with `0xc5` (the leading byte of
    keccak256("") = c5d2…). -/
def katEmptyLeadingByte : TestCase := {
  name := "kat_empty starts with 0xc5"
  body := do
    match kat_empty.toList with
    | head :: _ => assertEq (expected := (0xc5 : UInt8)) (actual := head) "kat_empty[0]"
    | [] => throw <| IO.userError "kat_empty is empty"
}

/-- `kat_abc` starts with `0x4e` (the leading byte of
    keccak256("abc") = 4e03…). -/
def katAbcLeadingByte : TestCase := {
  name := "kat_abc starts with 0x4e"
  body := do
    match kat_abc.toList with
    | head :: _ => assertEq (expected := (0x4e : UInt8)) (actual := head) "kat_abc[0]"
    | [] => throw <| IO.userError "kat_abc is empty"
}

/-- `kat_helloWorld` starts with `0xac`. -/
def katHelloLeadingByte : TestCase := {
  name := "kat_helloWorld starts with 0xac"
  body := do
    match kat_helloWorld.toList with
    | head :: _ => assertEq (expected := (0xac : UInt8)) (actual := head) "kat_helloWorld[0]"
    | [] => throw <| IO.userError "kat_helloWorld is empty"
}

/-- `kat_singleZero` starts with `0xbc`. -/
def katSingleZeroLeadingByte : TestCase := {
  name := "kat_singleZero starts with 0xbc"
  body := do
    match kat_singleZero.toList with
    | head :: _ => assertEq (expected := (0xbc : UInt8)) (actual := head) "kat_singleZero[0]"
    | [] => throw <| IO.userError "kat_singleZero is empty"
}

/-! ## Output-shape tests (always pass under any linked binding) -/

/-- `hashBytes` always produces 32-byte output (§5.2 invariant). -/
def hashOutputAlways32 : TestCase := {
  name := "hashBytes output is always 32 bytes"
  body := do
    -- Empty input.
    assertEq (expected := 32) (actual := (hashBytes ByteArray.empty).size) "empty"
    -- Single-byte input.
    assertEq (expected := 32) (actual := (hashBytes (ByteArray.mk #[0x00])).size) "0x00"
    -- 32-byte input (e.g. a pre-image at typical chain hash size).
    let input32 := ByteArray.mk (Array.replicate 32 (0x42 : UInt8))
    assertEq (expected := 32) (actual := (hashBytes input32).size) "32-byte input"
    -- 1024-byte input (well above the inner block size of any keccak variant).
    let input1024 := ByteArray.mk (Array.replicate 1024 (0xAB : UInt8))
    assertEq (expected := 32) (actual := (hashBytes input1024).size) "1024-byte input"
}

/-- `hashStream` always produces 32-byte output. -/
def hashStreamOutputAlways32 : TestCase := {
  name := "hashStream output is always 32 bytes"
  body := do
    assertEq (expected := 32) (actual := (hashStream ([] : Stream)).size) "empty"
    assertEq (expected := 32) (actual := (hashStream [0x01, 0x02, 0x03]).size) "3-byte"
}

/-! ## Determinism tests -/

/-- Equal inputs to `hashBytes` produce equal outputs. -/
def hashBytesDeterminism : TestCase := {
  name := "hashBytes is deterministic"
  body := do
    let bs := ByteArray.mk #[0xDE, 0xAD, 0xBE, 0xEF]
    let h1 := hashBytes bs
    let h2 := hashBytes bs
    if h1.toList == h2.toList then pure ()
    else throw <| IO.userError "non-deterministic hashBytes"
}

/-- Equal inputs to `hashStream` produce equal outputs. -/
def hashStreamDeterminism : TestCase := {
  name := "hashStream is deterministic"
  body := do
    let s : Stream := [0xC0, 0xFF, 0xEE]
    let h1 := hashStream s
    let h2 := hashStream s
    if h1.toList == h2.toList then pure ()
    else throw <| IO.userError "non-deterministic hashStream"
}

/-! ## Conditional KAT-match tests

When the production binding is linked, we expect `hashBytes input
= kat_input` for each KAT.  At the Lean level the binding is the
fallback (FNV-1a-64 padded to 32), so we expect
`hashBytes ByteArray.empty = expectedFallbackEmptyHash` instead.

The conditional structure documents the §5.2 acceptance criterion
without requiring the production binding to be wired at the Lean
level. -/

/-- The current binding produces the expected output for the empty
    input.  Branches on `isKeccak256Linked`. -/
def hashAdaptorMatchesL1Keccak : TestCase := {
  name := "hashAdaptor_matches_l1_keccak (or fallback) on empty input"
  body := do
    let h := hashBytes ByteArray.empty
    if isKeccak256Linked then
      -- Production binding: expect keccak256("") = kat_empty.
      (if h.toList == kat_empty.toList then pure ()
       else throw <| IO.userError
         "production keccak256 binding produced unexpected output for empty input")
    else
      -- Lean fallback: expect FNV-1a-64 of empty = offset basis padded.
      (if h.toList == expectedFallbackEmptyHash.toList then pure ()
       else throw <| IO.userError
         "Lean fallback produced unexpected output for empty input")
}

/-- Single-byte input case: under fallback, the leading byte must
    match FNV-1a-64 of `[0x00]` = `(offset XOR 0) * prime`.  Under
    production keccak256, the output equals `kat_singleZero`. -/
def hashAdaptorSingleZeroBranches : TestCase := {
  name := "hashAdaptor on single zero byte: fallback or keccak256"
  body := do
    let h := hashBytes (ByteArray.mk #[0x00])
    if isKeccak256Linked then
      (if h.toList == kat_singleZero.toList then pure ()
       else throw <| IO.userError
         "production keccak256 binding produced unexpected output for [0x00]")
    else
      -- Lean fallback: FNV-1a-64 of [0x00] = (offset XOR 0) * prime
      -- = offset * prime = 0xcbf29ce484222325 * 0x100000001b3
      -- = 0xaf63bd4c8601b7df (mod 2^64).  We don't recompute the
      -- full bytes here — we only verify the size and determinism
      -- (size is already covered above; determinism just below).
      assertEq (expected := 32) (actual := h.size) "fallback single-zero size"
}

/-! ## Conditional KAT-vector tests for all four reference vectors

When the production keccak256 binding is linked, every reference
KAT must match the linked binding's output.  These tests fire
*conditionally* — they're vacuously satisfied at the Lean level
(where `isKeccak256Linked = false`) and become real assertions
when the binding is wired in.

Authoritative source for the KAT values: NIST SHA-3 KAT files
+ Keccak Team's ShortMsgKAT_256.txt + cross-checked against
`pycryptodome`'s `Crypto.Hash.keccak.new(digest_bits=256)`.

Each test inputs the documented preimage and asserts the linked
hash output matches the corresponding `kat_*` constant. -/

/-- `kat_abc` matches the production binding's `keccak256("abc")`. -/
def hashAdaptorMatchesL1KeccakAbc : TestCase := {
  name := "hashAdaptor matches kat_abc when production binding linked"
  body := do
    let h := hashBytes "abc".toUTF8
    if isKeccak256Linked then
      (if h.toList == kat_abc.toList then pure ()
       else throw <| IO.userError
         "production keccak256 binding produced unexpected output for \"abc\"")
    else
      -- Lean fallback: skip the KAT check (FNV ≠ keccak256), but
      -- still verify the output size is 32 bytes.
      assertEq (expected := 32) (actual := h.size) "fallback abc size"
}

/-- `kat_helloWorld` matches the production binding's
    `keccak256("Hello, World!")`.  The KAT value is verified
    against `pycryptodome`'s output. -/
def hashAdaptorMatchesL1KeccakHelloWorld : TestCase := {
  name := "hashAdaptor matches kat_helloWorld when production binding linked"
  body := do
    let h := hashBytes "Hello, World!".toUTF8
    if isKeccak256Linked then
      (if h.toList == kat_helloWorld.toList then pure ()
       else throw <| IO.userError
         "production keccak256 binding produced unexpected output for \"Hello, World!\"")
    else
      assertEq (expected := 32) (actual := h.size) "fallback helloWorld size"
}

/-- All four KAT vectors are pairwise distinct at their leading
    byte.  Catches a copy-paste error where one vector's bytes
    were duplicated under another vector's name. -/
def katVectorsLeadingBytesDistinct : TestCase := {
  name := "all four KAT vectors have pairwise distinct leading bytes"
  body := do
    let leads : List UInt8 := [
      kat_empty.toList.headD 0x00,
      kat_abc.toList.headD 0x00,
      kat_helloWorld.toList.headD 0x00,
      kat_singleZero.toList.headD 0x00 ]
    -- Verify all distinct: since these are 0xc5, 0x4e, 0xac, 0xbc,
    -- a copy-paste duplicate would surface here.
    let uniqued := leads.eraseDups
    assertEq (expected := leads.length) (actual := uniqued.length)
      "leading bytes pairwise distinct"
}

/-! ## Term-level API stability -/

/-- `hashAdaptor_thirty_two_byte_output` is reachable as a
    term-level proof. -/
def hashOutput32API : TestCase := {
  name := "hashAdaptor_thirty_two_byte_output API stability"
  body := do
    let _proof : ∀ (bs : ByteArray), (hashBytes bs).size = 32 :=
      hashAdaptor_thirty_two_byte_output
    pure ()
}

/-- `hashAdaptor_deterministic` is reachable as a term-level proof. -/
def hashDeterministicAPI : TestCase := {
  name := "hashAdaptor_deterministic API stability"
  body := do
    let _proof : ∀ (bs₁ bs₂ : ByteArray), bs₁ = bs₂ → hashBytes bs₁ = hashBytes bs₂ :=
      hashAdaptor_deterministic
    pure ()
}

/-- `hashAdaptor_identifier_distinct` is reachable as a term-level
    proof. -/
def identifierDistinctAPI : TestCase := {
  name := "hashAdaptor_identifier_distinct API stability"
  body := do
    let _proof : keccak256AdaptorIdentifier ≠ fallbackHashIdentifier :=
      hashAdaptor_identifier_distinct
    pure ()
}

/-- `kat_empty_size` is reachable as a term-level proof. -/
def katEmptySizeAPI : TestCase := {
  name := "kat_empty_size API stability"
  body := do
    let _proof : kat_empty.size = 32 := kat_empty_size
    pure ()
}

/-- `expectedFallbackEmptyHash_size` is reachable as a term-level
    proof. -/
def fallbackHashSizeAPI : TestCase := {
  name := "expectedFallbackEmptyHash_size API stability"
  body := do
    let _proof : expectedFallbackEmptyHash.size = 32 :=
      expectedFallbackEmptyHash_size
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [ keccak256IdDistinct, keccak256IdValue, isKeccak256LinkedLean,
    katEmptySize, katAbcSize, katHelloWorldSize, katSingleZeroSize,
    fallbackEmptyHashSize,
    katEmptyLeadingByte, katAbcLeadingByte, katHelloLeadingByte,
    katSingleZeroLeadingByte,
    hashOutputAlways32, hashStreamOutputAlways32,
    hashBytesDeterminism, hashStreamDeterminism,
    hashAdaptorMatchesL1Keccak, hashAdaptorSingleZeroBranches,
    hashAdaptorMatchesL1KeccakAbc, hashAdaptorMatchesL1KeccakHelloWorld,
    katVectorsLeadingBytesDistinct,
    hashOutput32API, hashDeterministicAPI, identifierDistinctAPI,
    katEmptySizeAPI, fallbackHashSizeAPI ]

end HashAdaptorTests
end LegalKernel.Test.Bridge
