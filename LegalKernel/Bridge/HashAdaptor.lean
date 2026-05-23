/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.HashAdaptor — Workstream A.2 (Ethereum integration plan §5.2).

The Lean-side documentation, constants, and stability theorems for
the keccak256 hash adaptor.  Mirrors the verify adaptor (§5.1):
the Rust crate `runtime/knomosis-hash-keccak256` exports the C ABI
symbols `canon_hash_bytes`, `canon_hash_stream`, and
`canon_hash_identifier` (already documented in `docs/abi.md §11`,
post-Audit-3.1); production deployments wire these to the
`hashBytes` / `hashStream` swap-points in `Runtime/Hash.lean` via
`@[extern]` linkage.

This module:

  * Names the canonical adaptor identifier
    (`keccak256AdaptorIdentifier := "keccak256/EVM-compatible/v1"`),
    matching the §5.2 spec.
  * Exposes the `isKeccak256Linked` predicate that lets downstream
    callers detect at runtime whether the production binding is in
    place (the runtime CLI uses this to decide whether
    `--allow-fallback-hash` is required, per Audit-3.1).
  * Provides reference keccak256 KAT vectors as Lean constants —
    the Rust adaptor's golden tests consume these via FFI; the
    Lean-level tests exercise them only when the production
    binding is linked (which never happens at the Lean level
    today, since the `@[extern]` swap is a runtime concern).
  * Re-states `hashBytes_size` / `hashBytes_deterministic` in the
    Bridge namespace so downstream Bridge-layer callers can ascribe
    them as term-level API stability checks without crossing a
    namespace boundary.

This module is **not** part of the trusted computing base.  The
collision-resistance assumption on the linked binding is a *trust
assumption*, not a Lean axiom; the kernel's state-root guarantees
hold for any `hashBytes` implementation that respects the
`hashBytes_size` and `hashBytes_deterministic` contracts.

Coverage map:

  * §5.2 (WU A.2) — `keccak256AdaptorIdentifier`, KAT vectors
    (`kat_*`), `isKeccak256Linked`, `expectedFallbackEmptyHash`,
    `hashAdaptor_thirty_two_byte_output`,
    `hashAdaptor_deterministic`, `hashAdaptor_identifier_distinct`.
  * §12.14 (test obligations) — exercised via
    `Test/Bridge/HashAdaptor.lean`.

The §5.2 acceptance test ("32/32 goldens match against `geth`'s
keccak256 output") runs in the Rust adaptor's test suite when the
production binding is linked.  At the Lean level the tests cover
the *interface* contract: the symbol resolves with the right
signature, output size is 32 bytes, and identical inputs produce
identical outputs.
-/

import LegalKernel.Runtime.Hash

namespace LegalKernel.Bridge

open LegalKernel.Runtime
open LegalKernel.Encoding

/-! ## Canonical adaptor identifiers -/

/-- The 27-byte ASCII identifier the Rust keccak256 adaptor reports
    via the `canon_hash_identifier` C ABI symbol.  Audit-3.1
    mandates that the runtime introspect this identifier at startup
    and fail-fast on auditor binaries unless the production
    keccak256 binding is linked.

    The identifier embeds the protocol version (`v1`) so future
    changes to the keccak parameters or output width can be
    distinguished at the deployment boundary. -/
def keccak256AdaptorIdentifier : String := "keccak256/EVM-compatible/v1"

/-- Predicate: is the production keccak256 binding linked?  At the
    Lean level always returns `false` (the fallback identifier
    `"fnv1a64-padded-32"` is what `hashImplementationIdentifier`
    reports without `@[extern]` override).  Production deployments
    override `hashImplementationIdentifier` via the
    `canon_hash_identifier` C ABI symbol; this predicate then
    returns `true`. -/
def isKeccak256Linked : Bool :=
  decide (hashImplementationIdentifier () = keccak256AdaptorIdentifier)

/-! ## Reference keccak256 KAT vectors

Standard NIST / EVM keccak256 test vectors, supplied here as Lean
constants so the Rust adaptor's golden tests can consume them via
FFI without each test re-deriving the bytes.  Lean-level tests
that compare against these vectors are gated on
`isKeccak256Linked` (always `false` at the Lean level today).

Source: NIST SHA-3 KAT files, FIPS-202 Appendix A, and direct
`geth` outputs cross-checked against the EVM `KECCAK256` opcode. -/

/-- keccak256("") = c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470. -/
def kat_empty : ByteArray :=
  ByteArray.mk #[
    0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
    0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
    0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
    0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70
  ]

/-- keccak256("abc") = 4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45. -/
def kat_abc : ByteArray :=
  ByteArray.mk #[
    0x4e, 0x03, 0x65, 0x7a, 0xea, 0x45, 0xa9, 0x4f,
    0xc7, 0xd4, 0x7b, 0xa8, 0x26, 0xc8, 0xd6, 0x67,
    0xc0, 0xd1, 0xe6, 0xe3, 0x3a, 0x64, 0xa0, 0x36,
    0xec, 0x44, 0xf5, 0x8f, 0xa1, 0x2d, 0x6c, 0x45
  ]

/-- keccak256("Hello, World!") = acaf3289d7b601cbd114fb36c4d29c85bbfd5e133f14cb355c3fd8d99367964f. -/
def kat_helloWorld : ByteArray :=
  ByteArray.mk #[
    0xac, 0xaf, 0x32, 0x89, 0xd7, 0xb6, 0x01, 0xcb,
    0xd1, 0x14, 0xfb, 0x36, 0xc4, 0xd2, 0x9c, 0x85,
    0xbb, 0xfd, 0x5e, 0x13, 0x3f, 0x14, 0xcb, 0x35,
    0x5c, 0x3f, 0xd8, 0xd9, 0x93, 0x67, 0x96, 0x4f
  ]

/-- keccak256(0x00) = bc36789e7a1e281436464229828f817d6612f7b477d66591ff96a9e064bcc98a. -/
def kat_singleZero : ByteArray :=
  ByteArray.mk #[
    0xbc, 0x36, 0x78, 0x9e, 0x7a, 0x1e, 0x28, 0x14,
    0x36, 0x46, 0x42, 0x29, 0x82, 0x8f, 0x81, 0x7d,
    0x66, 0x12, 0xf7, 0xb4, 0x77, 0xd6, 0x65, 0x91,
    0xff, 0x96, 0xa9, 0xe0, 0x64, 0xbc, 0xc9, 0x8a
  ]

/-! ## Fallback expected outputs

The Lean fallback (FNV-1a-64 padded to 32) produces deterministic
bytes that are NOT keccak256-compatible.  We export the expected
fallback outputs here so the Lean-level tests can verify the
fallback wiring (closing the "what *does* the Lean fallback
produce?" loop without leaving the bytes implicit). -/

/-- The fallback FNV-1a-64 hash of the empty input is the offset
    basis (0xcbf29ce484222325 in little-endian, padded with 24
    zero bytes to 32 bytes).  This is what `hashBytes
    ByteArray.empty` returns at the Lean level. -/
def expectedFallbackEmptyHash : ByteArray :=
  ByteArray.mk #[
    -- offset basis 0xcbf29ce484222325 in little-endian:
    0x25, 0x23, 0x22, 0x84, 0xe4, 0x9c, 0xf2, 0xcb,
    -- 24 zero padding bytes:
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  ]

/-! ## Bridge-namespace stability theorems

Re-state the Runtime.Hash theorems in the Bridge namespace so
Bridge-layer callers can ascribe them as term-level API stability
checks without crossing the namespace boundary.  Each is a thin
forwarder; the proofs are inherited from `Runtime/Hash.lean`. -/

/-- The hash output is exactly 32 bytes (the §5.2 acceptance
    criterion `hashAdaptor_thirty_two_byte_output`). -/
theorem hashAdaptor_thirty_two_byte_output (bs : ByteArray) :
    (hashBytes bs).size = 32 :=
  hashBytes_size bs

/-- Equal inputs to the hash adaptor produce equal outputs (the
    §5.2 acceptance criterion `hashAdaptor_deterministic`). -/
theorem hashAdaptor_deterministic (bs₁ bs₂ : ByteArray) (h : bs₁ = bs₂) :
    hashBytes bs₁ = hashBytes bs₂ :=
  hashBytes_deterministic bs₁ bs₂ h

/-- The keccak256 adaptor identifier is distinct from the fallback
    identifier — guarantees the runtime can distinguish the two
    bindings without ambiguity. -/
theorem hashAdaptor_identifier_distinct :
    keccak256AdaptorIdentifier ≠ fallbackHashIdentifier := by
  decide

/-! ### KAT vector size invariants

Each reference vector is a 32-byte `ByteArray` (matching keccak256's
output width).  Stated as theorems so a future bug shrinking or
expanding any constant fails the build. -/

/-- `kat_empty` is 32 bytes. -/
theorem kat_empty_size : kat_empty.size = 32 := rfl

/-- `kat_abc` is 32 bytes. -/
theorem kat_abc_size : kat_abc.size = 32 := rfl

/-- `kat_helloWorld` is 32 bytes. -/
theorem kat_helloWorld_size : kat_helloWorld.size = 32 := rfl

/-- `kat_singleZero` is 32 bytes. -/
theorem kat_singleZero_size : kat_singleZero.size = 32 := rfl

/-- `expectedFallbackEmptyHash` is 32 bytes. -/
theorem expectedFallbackEmptyHash_size :
    expectedFallbackEmptyHash.size = 32 := rfl

end LegalKernel.Bridge
