/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Runtime.Hash — Phase-5 WU 5.1 / WU 5.5 / WU 5.12
tests for the deterministic content-hash module.

We verify three properties:

  1. Determinism (`hash(x) = hash(x)` and equal inputs → equal outputs).
  2. Output shape (8 bytes for FNV-1a-64).
  3. Avalanche-style: small input changes produce different hashes.
     (Not a strong cryptographic property — just enough to confirm
     the FNV-1a-64 implementation isn't degenerately constant.)

Plus value-level checks against well-known FNV-1a-64 vectors.
-/

import LegalKernel.Test.Framework
import LegalKernel.Runtime.Hash

namespace LegalKernel.Test.Runtime
namespace HashTests

open LegalKernel.Runtime
open LegalKernel.Encoding

/-- The FNV-1a-64 hash of the empty stream is the offset basis. -/
def fnvEmpty : TestCase := {
  name := "fnv1a64Stream of empty stream is offset basis"
  body := do
    assertEq fnvOffsetBasis (fnv1a64Stream []) "offset-basis"
}

/-- FNV-1a-64 of `[0x00]` is well-known: offset XOR 0 then * prime
    = offset * prime.  Direct sanity check. -/
def fnvSingleZero : TestCase := {
  name := "fnv1a64Stream of [0x00] is offset * prime"
  body := do
    let expected := fnvOffsetBasis * fnvPrime
    assertEq expected (fnv1a64Stream [0x00]) "offset*prime"
}

/-- Determinism: the same byte sequence always hashes to the same
    value. -/
def determinism : TestCase := {
  name := "hashStream is deterministic"
  body := do
    let s : Stream := [0x12, 0x34, 0x56, 0x78]
    let h1 := hashStream s
    let h2 := hashStream s
    if h1.toList == h2.toList then pure ()
    else throw <| IO.userError "non-deterministic hash"
}

/-- Output shape: every `hashBytes` output is exactly 32 bytes
    (Audit-3.1 unified width). -/
def hashSize : TestCase := {
  name := "hashBytes output has size 32"
  body := do
    assertEq (32 : Nat) (hashBytes (ByteArray.mk #[1, 2, 3])).size "size"
    assertEq (32 : Nat) (hashBytes (ByteArray.mk #[])).size "size empty"
}

/-- Audit-3.1: bytes 8..31 of the fallback hash output are zero
    (the FNV-1a-64 payload occupies bytes 0..7; padding fills the rest). -/
def fallbackPaddingZero : TestCase := {
  name := "fallback hashBytes padding bytes are zero"
  body := do
    let h := hashBytes (ByteArray.mk #[1, 2, 3])
    for i in [8:32] do
      if h.get! i ≠ 0 then
        throw <| IO.userError s!"byte {i} is non-zero in padded fallback hash"
}

/-- The zero hash has size 32 (matching the unified hash width). -/
def zeroHashSize : TestCase := {
  name := "zeroHash has size 32"
  body := do
    assertEq (32 : Nat) zeroHash.size "size"
}

/-- Audit-3.1: the fallback identifier reports the documented
    string.  Production deployments override this via
    `@[extern knomosis_hash_identifier]`. -/
def fallbackIdentifier : TestCase := {
  name := "hashImplementationIdentifier returns fallback string"
  body := do
    assertEq "fnv1a64-padded-32" (hashImplementationIdentifier ())
      "fallback identifier mismatch"
    assertEq "fnv1a64-padded-32" fallbackHashIdentifier
      "fallbackHashIdentifier constant mismatch"
}

/-- Audit-3.1: the Lean fallback reports `isProductionHash = false`.
    Production deployments override the identifier and this returns
    `true`. -/
def fallbackNotProduction : TestCase := {
  name := "isProductionHash returns false on fallback"
  body := do
    if isProductionHash then
      throw <| IO.userError "isProductionHash returned true on Lean fallback"
}

/-- Avalanche-ish: changing a single byte should change the hash.
    FNV-1a-64 isn't a strong cryptographic hash, but it's expected
    to differ on most single-byte perturbations.  We just check
    one specific case. -/
def avalanche : TestCase := {
  name := "hashStream differs for distinct inputs"
  body := do
    let h1 := hashStream [0x00]
    let h2 := hashStream [0x01]
    if h1.toList != h2.toList then pure ()
    else throw <| IO.userError "hash collision on small inputs"
}

/-- Empty-stream hash differs from single-byte stream hash. -/
def emptyVsSingle : TestCase := {
  name := "hashStream of empty differs from single-byte"
  body := do
    let h1 := hashStream []
    let h2 := hashStream [0x00]
    if h1.toList != h2.toList then pure ()
    else throw <| IO.userError "empty and single-byte hashed identically"
}

/-- Term-level API: `hashBytes_deterministic`. -/
def hashDeterministicAPI : TestCase := {
  name := "hashBytes_deterministic API stability"
  body := do
    let _proof : ∀ (b₁ b₂ : ByteArray), b₁ = b₂ → hashBytes b₁ = hashBytes b₂ :=
      hashBytes_deterministic
    pure ()
}

/-- Term-level API: `hashBytes_size`. -/
def hashBytesSizeAPI : TestCase := {
  name := "hashBytes_size API stability"
  body := do
    let _proof : ∀ (bs : ByteArray), (hashBytes bs).size = 32 :=
      hashBytes_size
    pure ()
}

/-- Term-level API: `hashStream_size`. -/
def hashStreamSizeAPI : TestCase := {
  name := "hashStream_size API stability"
  body := do
    let _proof : ∀ (s : Stream), (hashStream s).size = 32 :=
      hashStream_size
    pure ()
}

/-- Term-level API: `padTo32_size`. -/
def padTo32SizeAPI : TestCase := {
  name := "padTo32_size API stability"
  body := do
    let _proof : ∀ (n : UInt64), (padTo32 n).size = 32 :=
      padTo32_size
    pure ()
}

/-- Term-level API: `hashStream_deterministic`. -/
def hashStreamDeterministicAPI : TestCase := {
  name := "hashStream_deterministic API stability"
  body := do
    let _proof : ∀ (s₁ s₂ : Stream), s₁ = s₂ → hashStream s₁ = hashStream s₂ :=
      hashStream_deterministic
    pure ()
}

/-- All tests in this suite. -/
def tests : List TestCase :=
  [fnvEmpty, fnvSingleZero, determinism, hashSize, fallbackPaddingZero,
   zeroHashSize, fallbackIdentifier, fallbackNotProduction, avalanche,
   emptyVsSingle, hashDeterministicAPI, hashBytesSizeAPI, hashStreamSizeAPI,
   padTo32SizeAPI, hashStreamDeterministicAPI]

end HashTests
end LegalKernel.Test.Runtime
