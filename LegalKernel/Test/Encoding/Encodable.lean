/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Encoding.Encodable — Phase-4 WU 4.1 / WU 4.2 tests.

Tests the primitive `Encodable` instances (`Bool`, `Nat`,
`ByteArray`, `BoundedNat`, `UInt8`, `UInt64`).  Both value-level
round-trip checks and term-level API stability for the headline
theorems.
-/

import LegalKernel.Test.Framework
import LegalKernel.Encoding.Encodable

namespace LegalKernel.Test.Encoding
namespace EncodableTests

open LegalKernel.Encoding

/-- Bool round-trip: false. -/
def boolFalseRT : TestCase := {
  name := "Bool false roundtrip"
  body := do
    match Encodable.decode (T := Bool) (Encodable.encode false) with
    | .ok (b, rest) =>
      assertEq false b "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Bool round-trip: true. -/
def boolTrueRT : TestCase := {
  name := "Bool true roundtrip"
  body := do
    match Encodable.decode (T := Bool) (Encodable.encode true) with
    | .ok (b, rest) =>
      assertEq true b "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Nat round-trip: small value. -/
def natRT_42 : TestCase := {
  name := "Nat 42 roundtrip"
  body := do
    match Encodable.decode (T := Nat) (Encodable.encode (T := Nat) 42) with
    | .ok (n, rest) =>
      assertEq (42 : Nat) n "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Nat round-trip: 2^33 (requires 5+ bytes). -/
def natRT_large : TestCase := {
  name := "Nat 2^33 roundtrip"
  body := do
    let n : Nat := 8589934592
    match Encodable.decode (T := Nat) (Encodable.encode (T := Nat) n) with
    | .ok (m, rest) =>
      assertEq n m "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- BoundedNat round-trip. -/
def boundedNatRT : TestCase := {
  name := "BoundedNat roundtrip"
  body := do
    let v : BoundedNat := ⟨100, by decide⟩
    match Encodable.decode (T := BoundedNat) (Encodable.encode v) with
    | .ok (b, rest) =>
      assertEq (100 : Nat) b.val "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- ByteArray round-trip: small bytes. -/
def byteArrayRT : TestCase := {
  name := "ByteArray roundtrip"
  body := do
    let bs : ByteArray := ⟨#[0x01, 0x02, 0x03, 0x04, 0x05]⟩
    match Encodable.decode (T := ByteArray) (Encodable.encode bs) with
    | .ok (bs', rest) =>
      assertEq bs.size bs'.size "decoded size"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- ByteArray empty round-trip. -/
def byteArrayEmptyRT : TestCase := {
  name := "ByteArray empty roundtrip"
  body := do
    let bs : ByteArray := ByteArray.empty
    match Encodable.decode (T := ByteArray) (Encodable.encode bs) with
    | .ok (bs', rest) =>
      assertEq (0 : Nat) bs'.size "decoded size"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- UInt8 round-trip via Nat. -/
def uInt8RT : TestCase := {
  name := "UInt8 0xFE roundtrip"
  body := do
    let n : UInt8 := 0xFE
    match Encodable.decode (T := UInt8) (Encodable.encode n) with
    | .ok (m, rest) =>
      assertEq n m "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- UInt64 round-trip via Nat. -/
def uInt64RT : TestCase := {
  name := "UInt64 large roundtrip"
  body := do
    let n : UInt64 := 0xDEADBEEFCAFE0001
    match Encodable.decode (T := UInt64) (Encodable.encode n) with
    | .ok (m, rest) =>
      assertEq n m "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Term-level API: `nat_roundtrip` shape. -/
def natRoundtripAPI : TestCase := {
  name := "nat_roundtrip API stability"
  body := do
    let _proof : ∀ (n : Nat) (rest : Stream), n < 256 ^ 8 →
      Encodable.decode (T := Nat) (Encodable.encode n ++ rest) = .ok (n, rest) :=
      nat_roundtrip
    pure ()
}

/-- Term-level API: `byteArray_roundtrip` shape. -/
def byteArrayRoundtripAPI : TestCase := {
  name := "byteArray_roundtrip API stability"
  body := do
    let _proof : ∀ (bs : ByteArray) (rest : Stream), bs.size < 256 ^ 8 →
      Encodable.decode (T := ByteArray) (Encodable.encode bs ++ rest) = .ok (bs, rest) :=
      byteArray_roundtrip
    pure ()
}

/-- Term-level API: `bool_encode_injective` shape. -/
def boolInjectiveAPI : TestCase := {
  name := "bool_encode_injective API stability"
  body := do
    let _proof : Function.Injective (Encodable.encode : Bool → Stream) :=
      bool_encode_injective
    pure ()
}

/-- UInt16 round-trip via Nat. -/
def uInt16RT : TestCase := {
  name := "UInt16 0xCAFE roundtrip"
  body := do
    let n : UInt16 := 0xCAFE
    match Encodable.decode (T := UInt16) (Encodable.encode n) with
    | .ok (m, rest) =>
      assertEq n m "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- UInt32 round-trip via Nat. -/
def uInt32RT : TestCase := {
  name := "UInt32 0xDEADBEEF roundtrip"
  body := do
    let n : UInt32 := 0xDEADBEEF
    match Encodable.decode (T := UInt32) (Encodable.encode n) with
    | .ok (m, rest) =>
      assertEq n m "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Term-level API: `uInt16_roundtrip` signature. -/
def uInt16RoundtripAPI : TestCase := {
  name := "uInt16_roundtrip API stability"
  body := do
    let _proof : ∀ (n : UInt16) (rest : Stream),
        Encodable.decode (T := UInt16) (Encodable.encode n ++ rest) = .ok (n, rest) :=
      uInt16_roundtrip
    pure ()
}

/-- Term-level API: `uInt32_roundtrip` signature. -/
def uInt32RoundtripAPI : TestCase := {
  name := "uInt32_roundtrip API stability"
  body := do
    let _proof : ∀ (n : UInt32) (rest : Stream),
        Encodable.decode (T := UInt32) (Encodable.encode n ++ rest) = .ok (n, rest) :=
      uInt32_roundtrip
    pure ()
}

/-- `List Bool` round-trip (via parameterised list_roundtrip).
    Verifies that the parameterised round-trip lemma actually
    discharges a concrete `[Bool]` instance using `bool_roundtrip`
    as the per-element evidence. -/
def listBoolRT : TestCase := {
  name := "List Bool roundtrip via list_roundtrip"
  body := do
    let xs : List Bool := [true, false, true, true]
    match Encodable.decode (T := List Bool) (Encodable.encode xs) with
    | .ok (ys, rest) =>
      assertEq xs.length ys.length "decoded length"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Term-level API: `list_roundtrip` parameterised signature. -/
def listRoundtripAPI : TestCase := {
  name := "list_roundtrip API stability"
  body := do
    let _proof : ∀ {α : Type} [Encodable α], ElemRoundtrip α →
        ∀ (xs : List α) (rest : Stream), xs.length < 256 ^ 8 →
        Encodable.decode (T := List α) (Encodable.encode xs ++ rest) = .ok (xs, rest) :=
      @list_roundtrip
    pure ()
}

/-- `Option Bool` round-trip (none case). -/
def optionNoneRT : TestCase := {
  name := "Option Bool none roundtrip"
  body := do
    let v : Option Bool := none
    match Encodable.decode (T := Option Bool) (Encodable.encode v) with
    | .ok (v', rest) =>
      assertEq v v' "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- `Option Bool` round-trip (some case). -/
def optionSomeRT : TestCase := {
  name := "Option Bool some true roundtrip"
  body := do
    let v : Option Bool := some true
    match Encodable.decode (T := Option Bool) (Encodable.encode v) with
    | .ok (v', rest) =>
      assertEq v v' "decoded value"
      assertEq (0 : Nat) rest.length "no residual"
    | .error _ => throw <| IO.userError "decode failed"
}

/-- Term-level API: `option_roundtrip` parameterised signature. -/
def optionRoundtripAPI : TestCase := {
  name := "option_roundtrip API stability"
  body := do
    let _proof : ∀ {α : Type} [Encodable α], ElemRoundtrip α →
        ∀ (v : Option α) (rest : Stream),
        Encodable.decode (T := Option α) (Encodable.encode v ++ rest) = .ok (v, rest) :=
      @option_roundtrip
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [boolFalseRT, boolTrueRT, natRT_42, natRT_large, boundedNatRT,
   byteArrayRT, byteArrayEmptyRT, uInt8RT, uInt16RT, uInt32RT, uInt64RT,
   listBoolRT, optionNoneRT, optionSomeRT,
   natRoundtripAPI, byteArrayRoundtripAPI, boolInjectiveAPI,
   uInt16RoundtripAPI, uInt32RoundtripAPI,
   listRoundtripAPI, optionRoundtripAPI]

end EncodableTests
end LegalKernel.Test.Encoding
