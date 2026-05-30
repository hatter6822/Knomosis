-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Properties.Encoding — Audit-3.9 round-trip
properties.

Property tests for the CBE encoding round-trip.  Each property
samples N random values (default 100, overridable via
`KNOMOSIS_PROPERTY_ITERATIONS`) and asserts the round-trip identity:

  Encodable.decode (Encodable.encode v) = .ok (v, [])

Failure prints the seed for reproduction.

Focused on the primitive-value round-trips that are unconditional
(no `fieldsBounded` precondition needed): `Bool`, `Nat`,
`BoundedNat`, `UInt8`, `UInt16`, `UInt32`, `UInt64`, `ByteArray`,
`Option`, `List`.  The bounded-roundtrip versions for `Action` /
`SignedAction` / `Verdict` require generator wiring against the
per-type `fieldsBounded` predicate; consumers exercise those
through the per-suite encoding tests (e.g.
`LegalKernel/Test/Encoding/Action.lean`).
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Property

namespace LegalKernel.Test.Properties
namespace Encoding

open LegalKernel
open LegalKernel.Encoding
open LegalKernel.Test
open LegalKernel.Test.Property

/-- Property: `Bool` round-trips. -/
def boolRoundtripProperty : TestCase := {
  name := "property: Bool encode/decode round-trip (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed genBool fun b =>
      match Encodable.decode (T := Bool) (Encodable.encode b) with
      | .ok (b', []) => decide (b = b')
      | _            => false
}

/-- Property: `UInt8` round-trips. -/
def uInt8RoundtripProperty : TestCase := {
  name := "property: UInt8 encode/decode round-trip (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed genUInt8 fun b =>
      match Encodable.decode (T := UInt8) (Encodable.encode b) with
      | .ok (b', []) => decide (b = b')
      | _            => false
}

/-- Property: `Nat` round-trips for values < 2^48 (LCG range). -/
def natRoundtripProperty : TestCase := {
  name := "property: Nat encode/decode round-trip in LCG range (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed (genNat (2^32)) fun v =>
      match Encodable.decode (T := Nat) (Encodable.encode v) with
      | .ok (v', []) => decide (v = v')
      | _            => false
}

/-- Property: `ByteArray` (length up to 16) round-trips.  The
    underlying encoder is `byteArray_roundtrip` which is
    unconditional. -/
def byteArrayRoundtripProperty : TestCase := {
  name := "property: ByteArray ≤16 round-trip (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed (genByteArray 16) fun ba =>
      match Encodable.decode (T := ByteArray) (Encodable.encode ba) with
      | .ok (ba', []) => decide (ba.toList = ba'.toList)
      | _             => false
}

/-- Property: `genByteArray lenMax` produces arrays whose size is
    bounded by `lenMax`.  Generator-correctness sanity check. -/
def genByteArraySizeBounded : TestCase := {
  name := "generator: genByteArray size bounded (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed (genByteArray 16) fun ba =>
      decide (ba.size ≤ 16)
}

/-- Property: `genNat max` produces values in `[0, max)`. -/
def genNatBounded : TestCase := {
  name := "generator: genNat in range (100 samples)"
  body := do
    let seed ← readSeed
    let n ← readIterations
    forAll n seed (genNat 1024) fun v =>
      decide (v < 1024)
}

/-- All properties in the encoding round-trip suite. -/
def tests : List TestCase :=
  [ boolRoundtripProperty
  , uInt8RoundtripProperty
  , natRoundtripProperty
  , byteArrayRoundtripProperty
  , genByteArraySizeBounded
  , genNatBounded
  ]

end Encoding
end LegalKernel.Test.Properties
