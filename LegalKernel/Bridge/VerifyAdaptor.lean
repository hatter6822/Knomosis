/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.VerifyAdaptor — Workstream A.1 (Ethereum integration plan §5.1).

The Lean-side documentation, constants, and stability theorems for
the ECDSA secp256k1 verify adaptor.  The actual cryptographic
implementation is a Rust crate (`runtime/canon-verify-secp256k1`)
linked at runtime via the C ABI symbol `canon_verify`; this module
captures the Lean-visible contract:

  * The opaque `Verify : PublicKey → ByteArray → Signature → Bool`
    (declared in `LegalKernel/Authority/Crypto.lean`) is the
    swap-point.  Production deployments wire `canon_verify` to that
    opaque via `@[extern]` linkage.
  * The Rust adaptor enforces low-s canonicalisation (the EIP-2 /
    BIP-62 malleability mitigation).  At the Lean level we expose
    the secp256k1 curve order constant (`secp256k1Order`) and the
    half-curve-order constant (`secp256k1HalfOrder`) that the
    adaptor uses to reject high-s signatures.
  * The Rust adaptor parses an Ethereum-style 65-byte
    `(r ‖ s ‖ v)` signature.  We export the expected sizes
    (`ecdsaSignatureSize`, `ecdsaPublicKeyCompressedSize`,
    `ecdsaPublicKeyUncompressedSize`) so downstream code (and
    fuzzers) can produce well-shaped fixtures without re-deriving
    the magic numbers.

This module is **not** part of the trusted computing base.  Bugs
here are documentation drift; the kernel's authority guarantees
hold for any `Verify` implementation, and the EUF-CMA assumption
on the linked binding is a *trust assumption*, not a Lean axiom.

Coverage map:

  * §5.1 (WU A.1) — `secp256k1Order`, `secp256k1HalfOrder`,
    `secp256k1OrderBytes`, `ecdsaSignatureSize`,
    `ecdsaPublicKeyCompressedSize`, `ecdsaPublicKeyUncompressedSize`,
    `verifyAdaptorIdentifier`, `Verify_deterministic`,
    `isLowS`, `isLowSDecidable`.
  * §12.14 (test obligations) — exercised via
    `Test/Bridge/VerifyAdaptor.lean`.

The §5.1 acceptance test ("100/100 signs round-trip;
0/100 random triples accept") runs in the Rust adaptor's test
suite (`runtime/canon-verify-secp256k1/tests/`).  At the Lean
level we exercise the *interface* contract: the symbol resolves,
its signature is unchanged, and the documented behaviours
(determinism, low-s reasoning) compose with the rest of the
project.
-/

import LegalKernel.Authority.Crypto
import LegalKernel.Authority.SignedAction

namespace LegalKernel.Bridge

open LegalKernel.Authority

/-! ## secp256k1 curve constants

The secp256k1 group order `n` is fixed by the curve's parameters:

```
n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
```

Low-s canonicalisation (EIP-2 / BIP-62) requires `s ≤ n / 2`;
signatures with `s > n / 2` are malleable (negating `s` modulo
`n` yields a second valid signature for the same `(r, message,
key)` triple, which would let an attacker forge two distinct
admissible `SignedAction`s with the same nonce — breaking
`replay_impossible`'s precondition that distinct admissibility
witnesses arise from distinct verification calls).

These constants are reference material for the Rust adaptor
(which performs the actual reduction) and for any fuzzer / test
generator that needs to construct boundary cases.  They are
**not** consumed by any kernel proof; the kernel treats `Verify`
as opaque. -/

/-- The secp256k1 group order `n`.  Standard curve constant.

    Decimal expansion:
    `115792089237316195423570985008687907852837564279074904382605163141518161494337`. -/
def secp256k1Order : Nat :=
  0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

/-- Half the secp256k1 group order, rounded down: `⌊n/2⌋`.  A
    signature `(r, s)` is *low-s* iff `s ≤ secp256k1HalfOrder`. -/
def secp256k1HalfOrder : Nat := secp256k1Order / 2

/-- The secp256k1 group order encoded as 32 big-endian bytes —
    the on-the-wire form an Ethereum-style adaptor compares
    against to check the low-s constraint.  Lifted from the
    ANSI X9.62 / SEC2 curve specification. -/
def secp256k1OrderBytes : ByteArray :=
  ByteArray.mk #[
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
    0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
    0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41
  ]

/-- The byte length of an Ethereum-style ECDSA signature:
    `(r ‖ s ‖ v)` = 32 + 32 + 1 = 65 bytes.  The Rust adaptor
    rejects any signature whose length differs. -/
def ecdsaSignatureSize : Nat := 65

/-- The byte length of a SEC1 compressed secp256k1 public key:
    1 prefix byte (0x02 / 0x03 indicating y parity) + 32 x-coordinate
    bytes.  The Rust adaptor accepts both compressed and
    uncompressed keys. -/
def ecdsaPublicKeyCompressedSize : Nat := 33

/-- The byte length of a SEC1 uncompressed secp256k1 public key:
    1 prefix byte (0x04) + 32 x-coordinate bytes + 32 y-coordinate
    bytes. -/
def ecdsaPublicKeyUncompressedSize : Nat := 65

/-- Implementation identifier the Rust adaptor returns from the
    runtime introspection symbol (mirrors `canon_hash_identifier`
    from the hash adaptor; same Audit-3.1 discipline).
    Production deployments override this constant by linking the
    runtime adaptor; the Lean-level value names the *contract*
    that the linked binding agrees to honour. -/
def verifyAdaptorIdentifier : String := "ecdsa-secp256k1-low-s/EVM-compatible/v1"

/-- The fallback identifier — what the Lean-level `Verify` opaque
    reports when no production binding is linked.  The opaque
    body returns `false` for every input (the Phase-3 trust-
    assumption disclaimer); the fallback identifier disambiguates
    "no adaptor linked" from "adaptor linked but signature
    invalid". -/
def fallbackVerifyAdaptorIdentifier : String := "lean-opaque-fallback"

/-! ## Low-s predicate

A signature `(r, s)` is *low-s* iff `s ≤ n / 2`.  The Rust adaptor
rejects high-s signatures by extracting the 32 BE bytes of `s`
from the 65-byte `(r ‖ s ‖ v)` payload and comparing against
`secp256k1HalfOrder`.

At the Lean level we expose:
  * `isLowS : Nat → Bool` — for callers that already have `s` as
    a `Nat` (e.g. fuzzers).
  * `secp256k1HalfOrder` — the comparison threshold.

The actual byte-level extraction lives in the Rust adaptor and is
not modelled in Lean; the kernel's authority guarantees do not
depend on the malleability mitigation (the proofs of
`replay_impossible` and `nonce_uniqueness` reason purely about
nonces, not signatures).  The malleability mitigation is a
*defence-in-depth* property of the production adaptor. -/

/-- True iff `s ≤ secp256k1HalfOrder`.  The EIP-2 / BIP-62
    canonical form. -/
def isLowS (s : Nat) : Bool := decide (s ≤ secp256k1HalfOrder)

/-- `isLowS` is decidable.  Mechanical wrapper around `decide`
    that lets downstream callers obtain a `Decidable` instance
    without explicit `inferInstance`. -/
instance isLowSDecidable (s : Nat) : Decidable (s ≤ secp256k1HalfOrder) :=
  inferInstance

/-! ## Stability theorems

These are the Lean-level contract checks: the symbol exists,
its signature is fixed, and the trivially-true properties
(determinism on equal inputs, the low-s threshold value) are
re-asserted as theorems so that downstream callers can ascribe
them as term-level API stability checks. -/

/-- Determinism: equal inputs to `Verify` produce equal outputs.
    Trivially true for any pure Lean `opaque`; restated here
    so that the §12.14 contract ("the runtime adaptor must be
    deterministic") has a Lean-level witness. -/
theorem Verify_deterministic
    (pk : PublicKey) (msg : ByteArray) (sig : Signature) :
    Verify pk msg sig = Verify pk msg sig := rfl

/-- The low-s threshold is exactly half the curve order
    (rounded down).  Sanity check that the constant is wired
    correctly. -/
theorem secp256k1HalfOrder_eq : secp256k1HalfOrder = secp256k1Order / 2 := rfl

/-- The 32-byte BE encoding of `n` has size 32.  Sanity check
    against accidental zero-padding shifts. -/
theorem secp256k1OrderBytes_size : secp256k1OrderBytes.size = 32 := rfl

/-- `isLowS 0 = true` (the smallest signature is canonical). -/
theorem isLowS_zero : isLowS 0 = true := by
  show decide (0 ≤ secp256k1HalfOrder) = true
  simp [Nat.zero_le]

/-- A signature with `s = secp256k1HalfOrder` is low-s
    (boundary case).  The strict-vs-non-strict inequality
    matches EIP-2's `s ≤ n/2` formulation. -/
theorem isLowS_at_threshold : isLowS secp256k1HalfOrder = true := by
  show decide (secp256k1HalfOrder ≤ secp256k1HalfOrder) = true
  simp

/-- A signature with `s = secp256k1Order - 1` (just below the
    full curve order) is *not* low-s — it would round to a
    valid lower-s mate via `s' = n - s`.  Concrete witness
    that the threshold actually rejects high-s. -/
theorem isLowS_just_below_order : isLowS (secp256k1Order - 1) = false := by
  show decide (secp256k1Order - 1 ≤ secp256k1HalfOrder) = false
  -- secp256k1Order - 1 > secp256k1HalfOrder = secp256k1Order / 2
  -- since secp256k1Order > 1, secp256k1Order - 1 ≥ secp256k1Order / 2 + 1 > secp256k1Order / 2.
  decide

end LegalKernel.Bridge
