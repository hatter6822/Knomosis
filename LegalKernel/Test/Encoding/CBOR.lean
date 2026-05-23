/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.CBOR — Phase-4 WU 4.1 / WU 4.2 tests.

Spot-checks the CBE byte-level head encoder and the natFromBytesLE
codec at concrete value-level inputs.  Term-level API stability for
the headline `cborHeadRoundtrip` theorem.
-/

import LegalKernel.Test.Framework
import LegalKernel.Encoding.CBOR

namespace LegalKernel.Test.Encoding
namespace CBORTests

open LegalKernel.Encoding

/-- Round-trip of a small Nat (2) through the CBE head: 9-byte
    sequence (1 type tag + 8 LE value bytes), decode recovers `2`. -/
def cborRoundtrip_2 : TestCase := {
  name := "cborHeadRoundtrip(2)"
  body := do
    let bytes := cborHeadEncode cbeTagUint 2
    -- 1 type byte + 8 value bytes = 9 bytes total.
    assertEq (9 : Nat) bytes.length "encoded length"
    -- First byte is the type tag.
    assertEq (some cbeTagUint) bytes.head? "type tag"
    -- Roundtrip recovers (2, []).
    match cborHeadDecode bytes cbeTagUint with
    | .ok (n, rest) =>
      assertEq (2 : Nat) n "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Round-trip of `2^32` (a value requiring 5 bytes of LE storage). -/
def cborRoundtrip_2pow32 : TestCase := {
  name := "cborHeadRoundtrip(2^32)"
  body := do
    let n : Nat := 4294967296
    let bytes := cborHeadEncode cbeTagUint n
    match cborHeadDecode bytes cbeTagUint with
    | .ok (m, rest) =>
      assertEq n m "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Decode rejects a wrong-tag input. -/
def cborWrongTag : TestCase := {
  name := "cborHeadDecode rejects wrong tag"
  body := do
    let bytes := cborHeadEncode cbeTagBytes 5
    match cborHeadDecode bytes cbeTagUint with
    | .ok _ => throw <| IO.userError "decoded wrong tag"
    | .error _ => pure ()
}

/-- Decode rejects a too-short input. -/
def cborShortInput : TestCase := {
  name := "cborHeadDecode rejects short input"
  body := do
    -- Only 4 bytes; need at least 9.
    let bytes : List UInt8 := [0x00, 0x00, 0x00, 0x00]
    match cborHeadDecode bytes cbeTagUint with
    | .ok _ => throw <| IO.userError "decoded short input"
    | .error _ => pure ()
}

/-- Term-level API check: `cborHeadRoundtrip` has the expected
    bounded round-trip signature. -/
def cborHeadRoundtripAPI : TestCase := {
  name := "cborHeadRoundtrip API stability"
  body := do
    let _proof : ∀ (major : UInt8) (n : Nat), n < 256 ^ 8 →
      cborHeadDecode (cborHeadEncode major n) major = .ok (n, []) :=
      cborHeadRoundtrip
    pure ()
}

/-- Term-level API check: `cborHeadRoundtrip_append` has the
    suffix-preserving round-trip signature. -/
def cborHeadRoundtripAppendAPI : TestCase := {
  name := "cborHeadRoundtrip_append API stability"
  body := do
    let _proof : ∀ (major : UInt8) (n : Nat) (rest : Stream), n < 256 ^ 8 →
      cborHeadDecode (cborHeadEncode major n ++ rest) major = .ok (n, rest) :=
      cborHeadRoundtrip_append
    pure ()
}

/-- All tests in this suite. -/
def tests : List TestCase :=
  [cborRoundtrip_2, cborRoundtrip_2pow32, cborWrongTag, cborShortInput,
   cborHeadRoundtripAPI, cborHeadRoundtripAppendAPI]

end CBORTests
end LegalKernel.Test.Encoding
