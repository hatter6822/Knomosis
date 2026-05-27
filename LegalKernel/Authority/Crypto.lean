/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Authority.Crypto — the cryptographic primitive interface.

Phase 3 WU 3.4.  Defines the opaque `PublicKey` and `Signature`
types and the uninterpreted `Verify` function.  The kernel makes
*no* assumption about `Verify`'s implementation beyond determinism
(`Verify pk msg sig` always returns the same `Bool` for fixed
arguments), which is automatic since `Verify` is declared via Lean's
`opaque` keyword (not `axiom`) — the Lean-level body returns `false`,
the runtime adaptor links the real implementation.

The deployment supplies the actual signature scheme (Ed25519,
ECDSA secp256k1, ML-DSA, …) via a runtime-level adaptor (Phase 5
WU 3.9 / 5.4).  At the Lean level, all Phase 3 proofs treat
`Verify` as a black box.

This module is **not** part of the kernel TCB in the strict
"`tcb_audit`" sense — it lives under `LegalKernel/Authority/`, not
in the audited `LegalKernel/Kernel.lean` or
`LegalKernel/RBMapLemmas.lean`.  However, the `Verify` opaque is a
*trust assumption*: the kernel's authority guarantees only hold
under EUF-CMA on the supplied `Verify` adaptor.  See Genesis Plan
§8.2 and §10.3 for the threat model.

Coverage map:

  * WU 3.4 — `PublicKey`, `Signature`, `Verify` opaque.

The naming convention `verify_impl` in the runtime adaptor (Phase 5)
gives the FFI a fixed symbol; Lean's `Verify` is an `opaque` constant
that the runtime supplies an implementation for at link time.  This
mirrors the way the kernel treats `Std.TreeMap`'s implementation
(opaque at the Lean level, real C++ at link time).
-/

namespace LegalKernel
namespace Authority

/-- An opaque public key.  Phase 3 makes no assumption about its
    structure; the deployment-supplied `Verify` adaptor is responsible
    for parsing the bytes (e.g. as a 32-byte Ed25519 point).

    Stored as `ByteArray` to keep the kernel agnostic to the signature
    scheme.  The TCB grows by zero bytes when a deployment swaps in a
    new scheme: only the runtime adaptor changes. -/
abbrev PublicKey : Type := ByteArray

/-- An opaque signature.  Same comments as `PublicKey`: opaque bytes,
    deployment-defined parsing. -/
abbrev Signature : Type := ByteArray

/-- A `Repr` instance for `PublicKey` (i.e. for `ByteArray`).  Needed
    for `deriving Repr` on `Action`, which has a `PublicKey` field in
    the `replaceKey` constructor.  `ByteArray` does not ship a `Repr`
    instance in Lean core; we provide a hex-string one here. -/
instance : Repr PublicKey where
  reprPrec ba _ :=
    "PublicKey:bytes(" ++ toString ba.size ++ ")"

/-- Equality on `PublicKey` (i.e. on `ByteArray`).  Needed for
    `deriving DecidableEq` on `Action`, which has a `PublicKey` field.
    `ByteArray` ships `BEq` but not `DecidableEq`; we lift the former
    to the latter via `decEq`. -/
instance : DecidableEq PublicKey := fun b₁ b₂ =>
  -- ByteArray has DecidableEq under the abbreviation, but Lean's
  -- typeclass elaborator sometimes fails to find it through `abbrev`.
  -- This explicit instance forces resolution.
  inferInstanceAs (Decidable (b₁ = b₂))

/-- An opaque per-actor counter for replay protection.  Phase 3 uses
    `Nat` (unbounded) rather than `UInt64` to make overflow absence a
    theorem rather than a runtime bound; the canonical encoding in
    Phase 4 will marshal `Nat → UInt64` with an explicit bound check
    at the deployment boundary.

    The `expectsNonce` function (`Authority/Nonce.lean`) returns a
    `Nonce` that signers must match exactly; mismatched nonces fail
    admissibility condition 4 (Genesis Plan §8.2). -/
abbrev Nonce : Type := Nat

/-! ## The `Verify` interface (§8.2 / WU 3.4)

`Verify pk msg sig` returns `true` iff the signature `sig` is a valid
signature of message `msg` under public key `pk`.  Declared as an
`opaque` constant (rather than `axiom`) so that Lean's standard
extraction pipeline can wire it to a runtime-supplied implementation
without introducing a custom axiom; the kernel's axiom audit
therefore continues to return exactly
`[propext, Classical.choice, Quot.sound]` (the Lean built-ins
CLAUDE.md explicitly allows).

The contract:

  * **Determinism.**  For fixed `(pk, msg, sig)`, `Verify` returns the
    same `Bool` value across every invocation.  Built-in for any
    pure Lean `opaque`.
  * **EUF-CMA.**  The deployment-supplied implementation is
    existentially-unforgeable under chosen-message attack.  This is a
    *cryptographic* assumption, not a Lean theorem; the Phase-3 proofs
    of `replay_impossible` and `nonce_uniqueness` do not depend on
    it.
  * **No assumption on shape.**  The kernel does not require that
    `pk`, `msg`, or `sig` have any particular length or format.

Because `Verify` is `opaque` rather than `axiom`, Lean's type checker
treats it as a plain definition with no body, so:

  * Equational reasoning about `Verify pk msg sig = true` is
    impossible without an explicit hypothesis (correct: the kernel
    must accept any verification result the runtime returns).
  * `#print axioms` does *not* attribute `Verify` to a custom axiom
    in the kernel theorems; instead, theorems that reach `Verify`
    pull it in as an opaque dependency.

The runtime adaptor (Phase 5, WU 3.9) supplies a concrete
implementation via `@[extern]` linkage to Rust / C code; for
property-based tests at the Lean level (Phase 3 tests), we model
`Verify` via injected hypotheses (`hSig : Verify pk msg sig =
true`). -/

/-- `Verify pk msg sig = true` iff `sig` is a valid signature on `msg`
    under public key `pk`.  Treated as an uninterpreted `opaque` at
    the Lean level; the runtime adaptor supplies the concrete
    implementation (Ed25519 by default — see Genesis Plan §8.2 for
    algorithmic agility).

    Declared `opaque` (with a placeholder body of `false`) rather than
    `axiom` so the kernel's `#print axioms` audit continues to return
    exactly the three Lean built-in axioms.  The placeholder body is
    *never* used in deployment: the runtime adaptor wires the symbol
    to a real implementation at link time. -/
opaque Verify (pk : PublicKey) (msg : ByteArray) (sig : Signature) : Bool

/-! ## Canonical signing input (§8.2 / §8.8 stub)

The full canonical encoding lives in Phase 4 (CBOR + sign-input
domain separation).  Phase 3 needs *some* function from `(action,
signer, nonce)` triples to `ByteArray` so that the `Admissible`
predicate can refer to "the message under signature".  We declare it
as `opaque` for now; Phase 4 supplies a concrete (CBOR-based)
implementation.

The Phase-3 proofs of `nonce_uniqueness` and `replay_impossible` do
not depend on the encoding's structure — they reason purely about
nonces — so leaving this opaque costs nothing.  Phase 4's
`canonicalEncode_injective` theorem will then provide the byte-level
basis for cross-deployment-replay rejection. -/

/-- An opaque type representing the bytes that a signature is
    computed over, namely the canonical encoding of `(action, signer,
    nonce, deployment_id)`.  Phase 3 treats this as a black box;
    Phase 4 will define the CBOR-based concrete encoding (§8.8) and
    prove the associated round-trip and injectivity theorems. -/
abbrev SigningInput : Type := ByteArray

/-! ## Domain-separation prefix (§8.8.5 / AR.1)

The shared domain-separation prefix `"legalkernel/v1/signedaction"`
used by both `Authority.SignedAction.signingInput` (the kernel's
pre-image function for signature verification) and
`Encoding.SignInput.signInput` (the runtime-facing CBE encoder
for the signing input).  AR.1 / M-7 consolidates the previously-
duplicated string literals at two sites into one canonical
definition. -/

/-- The ASCII domain-separation prefix included in every signing
    input.  27 bytes: `"legalkernel/v1/signedaction"`.  Reused by
    `LegalKernel/Encoding/SignInput.lean` (via the `Encoding`
    re-export) and `LegalKernel/Authority/SignedAction.lean`. -/
def signedActionDomain : String := "legalkernel/v1/signedaction"

/-- The ASCII bytes of `signedActionDomain`, pre-computed for the
    encoders that need a `ByteArray` (vs. the `String` form). -/
def signedActionDomainBytes : ByteArray := signedActionDomain.toUTF8

end Authority
end LegalKernel
