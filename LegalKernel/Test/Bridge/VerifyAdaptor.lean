-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.VerifyAdaptor — Workstream A.1 stability tests.

The Lean-level acceptance contract for the ECDSA secp256k1 verify
adaptor (see `LegalKernel/Bridge/VerifyAdaptor.lean`).  The actual
cryptographic correctness lives in the Rust crate's test suite
(`runtime/knomosis-verify-secp256k1/tests/`), which this Lean side
cannot exercise directly because the production `Verify` opaque
returns `false` at the Lean level (the body is a placeholder; the
runtime adaptor wires the real implementation via `@[extern]`).

What this suite covers:

  * **Symbol-resolution tests.**  The constants exposed by
    `Bridge/VerifyAdaptor.lean` have the expected values.  Catches
    typos and accidental drift in the curve-order / signature-size
    constants.
  * **Low-s reasoning tests.**  `isLowS` rejects high-s signatures
    at every boundary (zero, threshold, just-below-order).
  * **Term-level API stability.**  The `Verify_deterministic`,
    `secp256k1HalfOrder_eq`, etc. theorems are ascribed at the
    term level so a signature change anywhere in the API surface
    fails the build.
  * **Happy-path admissibility via `mockVerify`.**  The §5.1 spec
    asks for `verifyAdaptor_accepts_canonical : Verify pk msg sig
    = true`.  The production `Verify` cannot satisfy this at the
    Lean level (returns `false`); we instead use `mockVerify`
    (Audit-3.3), which is a genuine value-level verifier and
    accepts a deterministic test signature.  The Rust adaptor's
    own test suite exercises the same property against a real
    Ethereum testnet signature.
-/

import LegalKernel
import LegalKernel.Bridge.VerifyAdaptor
import LegalKernel.Test.Framework
import LegalKernel.Test.MockCrypto

namespace LegalKernel.Test.Bridge
namespace VerifyAdaptorTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Test
open LegalKernel.Test.MockCrypto

/-! ## Constant-shape tests -/

/-- The secp256k1 group order has the documented 32-byte big-endian
    encoding.  Catches accidental drift in the constant wiring. -/
def orderBytesShape : TestCase := {
  name := "secp256k1OrderBytes is 32 bytes"
  body := do
    assertEq (expected := 32) (actual := secp256k1OrderBytes.size) "order bytes size"
}

/-- The first byte of the order encoding is `0xFF` (most-significant
    byte of `n`); the last byte is `0x41`. -/
def orderBytesEndpoints : TestCase := {
  name := "secp256k1OrderBytes endpoints match curve spec"
  body := do
    let bs := secp256k1OrderBytes.toList
    match bs with
    | head :: _ => assertEq (expected := (0xFF : UInt8)) (actual := head) "MSB"
    | [] => throw <| IO.userError "order bytes empty"
    -- Last byte:
    match bs.getLast? with
    | some last => assertEq (expected := (0x41 : UInt8)) (actual := last) "LSB"
    | none => throw <| IO.userError "order bytes had no last"
}

/-- The Ethereum signature has 65 bytes. -/
def signatureSize : TestCase := {
  name := "ecdsaSignatureSize = 65"
  body := assertEq (expected := 65) (actual := ecdsaSignatureSize) "signature size"
}

/-- A SEC1-compressed public key is 33 bytes (1 prefix + 32 x). -/
def pkCompressedSize : TestCase := {
  name := "ecdsaPublicKeyCompressedSize = 33"
  body := assertEq (expected := 33) (actual := ecdsaPublicKeyCompressedSize) "pk compressed"
}

/-- An uncompressed public key is 65 bytes. -/
def pkUncompressedSize : TestCase := {
  name := "ecdsaPublicKeyUncompressedSize = 65"
  body := assertEq (expected := 65) (actual := ecdsaPublicKeyUncompressedSize) "pk uncompressed"
}

/-- The fallback identifier is distinct from the production
    identifier.  Catches a future bug where the production
    adaptor accidentally reports the fallback identifier. -/
def identifiersDistinct : TestCase := {
  name := "verifyAdaptorIdentifier ≠ fallbackVerifyAdaptorIdentifier"
  body := do
    if verifyAdaptorIdentifier == fallbackVerifyAdaptorIdentifier then
      throw <| IO.userError "verify adaptor identifiers collided"
    else pure ()
}

/-- The half-order is exactly `secp256k1Order / 2`. -/
def halfOrderEq : TestCase := {
  name := "secp256k1HalfOrder = secp256k1Order / 2"
  body := assertEq (expected := secp256k1Order / 2) (actual := secp256k1HalfOrder) "half order"
}

/-- The 32-byte BE encoding of `secp256k1OrderBytes` decodes to exactly
    `secp256k1Order`.  Cross-check that the Nat constant and the byte
    array constant agree — guards against a future copy-paste error
    that desyncs them.

    Decode by `bs.foldl (acc * 256 + b) 0` (the canonical BE→Nat
    decoder for fixed-width arrays). -/
def orderBytesDecodesToOrder : TestCase := {
  name := "secp256k1OrderBytes decodes (BE) to secp256k1Order"
  body := do
    let decoded : Nat := secp256k1OrderBytes.toList.foldl
      (fun acc b => acc * 256 + b.toNat) 0
    assertEq (expected := secp256k1Order) (actual := decoded) "BE decode"
}

/-- The well-known `secp256k1HalfOrder` constant matches the
    documented EIP-2 / BIP-62 threshold value
    `0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0`. -/
def halfOrderMatchesEip2 : TestCase := {
  name := "secp256k1HalfOrder matches EIP-2 / BIP-62 threshold"
  body := do
    let expected : Nat :=
      0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
    assertEq (expected := expected) (actual := secp256k1HalfOrder) "half order matches EIP-2"
}

/-! ## Low-s boundary tests -/

/-- `isLowS 0 = true`. -/
def lowSZero : TestCase := {
  name := "isLowS rejects nothing at s = 0"
  body := assertEq (expected := true) (actual := isLowS 0) "isLowS 0"
}

/-- `isLowS secp256k1HalfOrder = true`. -/
def lowSAtThreshold : TestCase := {
  name := "isLowS accepts at the half-order threshold"
  body := assertEq (expected := true) (actual := isLowS secp256k1HalfOrder) "isLowS half"
}

/-- `isLowS (secp256k1HalfOrder + 1) = false` — just-above the
    boundary is high-s.  This is the EIP-2 reject test. -/
def lowSJustAboveThreshold : TestCase := {
  name := "isLowS rejects just above the half-order threshold"
  body := assertEq (expected := false) (actual := isLowS (secp256k1HalfOrder + 1))
    "isLowS half+1"
}

/-- `isLowS (secp256k1Order - 1)` is high-s (the largest possible
    valid `s` value, which any Ethereum-style adaptor would
    reject as malleable). -/
def lowSJustBelowOrder : TestCase := {
  name := "isLowS rejects just-below-order (the malleability vector)"
  body := assertEq (expected := false) (actual := isLowS (secp256k1Order - 1))
    "isLowS n-1"
}

/-! ## High-s complement tests

For any low-s signature `(r, s)` with `s ∈ (0, n/2]`, the complement
`s' := n - s` is high-s and would be rejected by the Rust adaptor.
This is the malleability vector EIP-2 closes — the §5.1 spec asks
for `verifyAdaptor_rejects_high_s : Verify pk msg sigHighS = false`,
which we model at the Lean level via the `isLowS` predicate. -/

/-- The complement of a sample low-s value is high-s. -/
def highSComplementSmallValue : TestCase := {
  name := "complement of a small low-s s' = n - s is high-s"
  body := do
    -- pick s = 1 (low-s, since 1 ≤ n/2)
    let s : Nat := 1
    assertEq (expected := true) (actual := isLowS s) "s=1 is low-s"
    -- complement: s' = n - 1 (high-s, since n - 1 > n/2)
    let sPrime := secp256k1Order - s
    assertEq (expected := false) (actual := isLowS sPrime) "complement is high-s"
}

/-- The complement of the half-order itself is just-above the
    threshold by 1 (proving the boundary is correctly handled —
    `n - n/2 = n - n/2`, which is one above n/2 when n is odd). -/
def highSComplementHalfOrder : TestCase := {
  name := "complement of the half-order is high-s (boundary)"
  body := do
    let s := secp256k1HalfOrder
    assertEq (expected := true) (actual := isLowS s) "s=half is low-s"
    let sPrime := secp256k1Order - s
    -- Since secp256k1Order is odd, n - n/2 = n/2 + 1 (high-s).
    assertEq (expected := false) (actual := isLowS sPrime)
      "complement of half-order is high-s"
}

/-! ## Production `Verify` opaque safe-default behaviour

Every call to the production `Verify` opaque returns `false` at the
Lean level (the body returns `false` regardless of inputs; the
production binding wires the real implementation via `@[extern]`).
This is the safe default: the Lean evaluator never accepts any
signature, so a future test that mistakenly calls `Verify` directly
(rather than `mockVerify`) gets a deterministic "rejected" outcome
rather than an unsound "accepted" outcome.

We assert this behaviour as a value-level test so any future change
to the opaque body would be caught here. -/

/-- The production `Verify` opaque returns `false` for a sample
    input.  Documents the Lean-level safe-default behaviour. -/
def productionVerifyRejectsAtLeanLevel : TestCase := {
  name := "production Verify returns false at the Lean level"
  body := do
    let pk : PublicKey := ByteArray.mk #[0xAA]
    let msg : ByteArray := ByteArray.mk #[0xBB]
    let sig : Signature := ByteArray.mk #[0xCC]
    -- The production opaque always returns false at the Lean level;
    -- the runtime adaptor wires the real verifier via @[extern].
    if Verify pk msg sig then
      throw <| IO.userError
        "production Verify returned true at the Lean level — production adaptor leaked into Lean"
    else pure ()
}

/-! ## Mock-verifier happy path (substitutes for §5.1 acceptance)

The §5.1 spec asks for a `verifyAdaptor_accepts_canonical` test on a
hardcoded `(pk, msg, sig)` triple lifted from an Ethereum testnet
transaction.  At the Lean level the production `Verify` cannot
satisfy this (returns `false`); we substitute the §Audit-3.3
`mockVerify`, which is a genuine value-level verifier and accepts a
deterministic test signature.

The Rust adaptor's own test suite exercises the real-signature
property against a hardcoded testnet triple — see
`runtime/knomosis-verify-secp256k1/tests/golden_testnet.rs`. -/

/-- The mock verifier accepts a mock-signed input — the Lean-level
    substitute for `verifyAdaptor_accepts_canonical`. -/
def mockAcceptsCanonical : TestCase := {
  name := "mockVerify accepts mockSign output (substitutes accepts_canonical)"
  body := do
    let pk := mockPubKey 10
    let msg : ByteArray := ByteArray.mk #[0x01, 0x02, 0x03, 0x04]
    let sig := mockSign pk msg
    if mockVerify pk msg sig then pure ()
    else throw <| IO.userError "mockVerify rejected its own canonical signature"
}

/-- The mock verifier rejects a corrupted signature.  Substitutes for
    `verifyAdaptor_rejects_corrupt`: a single-byte flip in the signature
    bytes breaks verification. -/
def mockRejectsCorrupt : TestCase := {
  name := "mockVerify rejects corrupted signature (substitutes rejects_corrupt)"
  body := do
    let pk := mockPubKey 10
    let msg : ByteArray := ByteArray.mk #[0x01, 0x02, 0x03, 0x04]
    let sig := mockSign pk msg
    -- Sanity: the unmutated signature is accepted (load-bearing for the
    -- "corruption is what causes rejection" reading of this test).
    if ! mockVerify pk msg sig then
      throw <| IO.userError "mockVerify rejected its own canonical signature"
    -- Build a corrupted signature by replacing the leading 0xFF byte with
    -- 0x00 (every other byte is already 0x00 in mockSign's output).
    let corrupted := ByteArray.mk
      ((List.replicate 64 (0 : UInt8))).toArray
    if mockVerify pk msg corrupted then
      throw <| IO.userError "mockVerify accepted a corrupted signature"
    else pure ()
}

/-- The mock verifier rejects a signature whose size differs from
    the documented 64 bytes.  Substitutes for the byte-shape part
    of `verifyAdaptor_rejects_corrupt`. -/
def mockRejectsWrongSize : TestCase := {
  name := "mockVerify rejects wrong-size signature"
  body := do
    let pk := mockPubKey 10
    let msg : ByteArray := ByteArray.mk #[0xAA]
    -- 32-byte sig (wrong size).
    let badSig := ByteArray.mk
      (((List.replicate 32 (0 : UInt8)).set 0 0xFF)).toArray
    if mockVerify pk msg badSig then
      throw <| IO.userError "mockVerify accepted wrong-size signature"
    else pure ()
}

/-! ## Term-level API stability -/

/-- `Verify_deterministic` is reachable as a term-level proof. -/
def verifyDeterministicAPI : TestCase := {
  name := "Verify_deterministic API stability"
  body := do
    let _proof :
        ∀ (pk : PublicKey) (msg : ByteArray) (sig : Signature),
          Verify pk msg sig = Verify pk msg sig :=
      Verify_deterministic
    pure ()
}

/-- `secp256k1HalfOrder_eq` is reachable as a term-level proof. -/
def halfOrderEqAPI : TestCase := {
  name := "secp256k1HalfOrder_eq API stability"
  body := do
    let _proof : secp256k1HalfOrder = secp256k1Order / 2 :=
      secp256k1HalfOrder_eq
    pure ()
}

/-- `secp256k1OrderBytes_size` is reachable as a term-level proof. -/
def orderBytesSizeAPI : TestCase := {
  name := "secp256k1OrderBytes_size API stability"
  body := do
    let _proof : secp256k1OrderBytes.size = 32 := secp256k1OrderBytes_size
    pure ()
}

/-- `isLowS_zero` is reachable as a term-level proof. -/
def isLowSZeroAPI : TestCase := {
  name := "isLowS_zero API stability"
  body := do
    let _proof : isLowS 0 = true := isLowS_zero
    pure ()
}

/-- `isLowS_at_threshold` is reachable as a term-level proof. -/
def isLowSAtThresholdAPI : TestCase := {
  name := "isLowS_at_threshold API stability"
  body := do
    let _proof : isLowS secp256k1HalfOrder = true := isLowS_at_threshold
    pure ()
}

/-- `isLowS_just_below_order` is reachable as a term-level proof. -/
def isLowSJustBelowAPI : TestCase := {
  name := "isLowS_just_below_order API stability"
  body := do
    let _proof : isLowS (secp256k1Order - 1) = false := isLowS_just_below_order
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [ orderBytesShape, orderBytesEndpoints, signatureSize,
    pkCompressedSize, pkUncompressedSize, identifiersDistinct,
    halfOrderEq, orderBytesDecodesToOrder, halfOrderMatchesEip2,
    lowSZero, lowSAtThreshold, lowSJustAboveThreshold, lowSJustBelowOrder,
    highSComplementSmallValue, highSComplementHalfOrder,
    productionVerifyRejectsAtLeanLevel,
    mockAcceptsCanonical, mockRejectsCorrupt, mockRejectsWrongSize,
    verifyDeterministicAPI, halfOrderEqAPI, orderBytesSizeAPI,
    isLowSZeroAPI, isLowSAtThresholdAPI, isLowSJustBelowAPI ]

end VerifyAdaptorTests
end LegalKernel.Test.Bridge
