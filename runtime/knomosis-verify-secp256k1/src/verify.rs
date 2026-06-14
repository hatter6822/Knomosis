// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Pure-Rust secp256k1 ECDSA verification core.
//!
//! This module is the *cryptographic* surface of RH-A.1.  It exposes
//! two entry points:
//!
//!   * [`verify`] — safe Rust API.  Returns `bool`; never panics.
//!   * [`knomosis_verify_ecdsa_raw`] — C ABI surface called from
//!     `c/lean_shim.c`.  Wraps [`verify`] with raw-pointer slices.
//!
//! ## Wire-format contract (mirrors the engineering plan §RH-A.1)
//!
//! The adaptor enforces strict input validation per the plan
//! §RH-A.1.b:
//!
//! | Field | Length      | Format                                                |
//! |-------|-------------|-------------------------------------------------------|
//! | `pk`  | 33 bytes    | SEC1 compressed pubkey; first byte ∈ {0x02, 0x03}.    |
//! | `msg` | 32 bytes    | Pre-hashed message (typically keccak256 output).      |
//! | `sig` | 64 bytes    | Big-endian `(r, s)` concatenation; raw / non-DER.     |
//!
//! All four length checks are enforced up front.  Mismatched
//! lengths return `false` without touching `k256`.  This is
//! intentional: a length mismatch is *always* an input bug, and
//! routing it through `k256`'s parsing surface would surface
//! confusing error variants that compose poorly with the
//! Boolean-return contract of Lean's `Verify` opaque.
//!
//! ## Low-s canonicalisation (RH-A.1.c)
//!
//! After length validation, the adaptor parses `(r, s)` and rejects
//! the signature if `s > n / 2` (where `n` is the secp256k1 group
//! order).  This is the EIP-2 / BIP-62 canonical-form requirement.
//! Without it, an adversary can take any valid signature `(r, s)`
//! and produce a second valid signature `(r, n - s)` for the same
//! `(pk, msg)` pair — a malleability attack that would break the
//! kernel's `replay_impossible` precondition.
//!
//! `k256` exposes `is_high()` on `Scalar`; we use it to detect
//! high-s and reject.  The check is constant-time (per
//! `k256`'s documentation), so the adaptor leaks no timing
//! information about which side of the threshold an attacker-
//! supplied `s` falls on.
//!
//! ## Mathematical soundness
//!
//! ECDSA verification over secp256k1 is the textbook algorithm:
//!
//! ```text
//! Input: pk = (X, Y) ∈ E(F_p),  msg ∈ {0,1}^256,  (r, s) ∈ Z_n × Z_n
//!
//!   1. Check 1 ≤ r < n,  1 ≤ s < n        (zero / out-of-range reject)
//!   2. Check s ≤ n/2                       (low-s canonicalisation)
//!   3. Compute z = msg interpreted as an integer mod n
//!   4. Compute u₁ = z * s⁻¹ mod n;  u₂ = r * s⁻¹ mod n
//!   5. Compute (x, y) = u₁ * G + u₂ * pk    (point on E)
//!   6. Accept iff (x mod n) == r
//! ```
//!
//! Steps 1–6 (minus step 2) are delegated to
//! `k256::ecdsa::VerifyingKey::verify_prehash`.  Step 2 is
//! enforced explicitly via `k256::ecdsa::Signature::s().is_high()`
//! before delegating, so the production adaptor refuses
//! high-s signatures even when `k256` itself would accept them.
//!
//! The reference: SEC1 v2.0 §4.1.4 "Verifying Operation" + EIP-2
//! ("Homestead").

use k256::ecdsa::{signature::hazmat::PrehashVerifier, Signature, VerifyingKey};
use k256::elliptic_curve::scalar::IsHigh;
use subtle::ConstantTimeEq;

/// Length of a SEC1-compressed secp256k1 public key in bytes
/// (1-byte prefix + 32-byte x-coordinate).
pub const PUBKEY_LEN: usize = 33;

/// Length of an ECDSA pre-hashed message in bytes (a SHA-2 or
/// keccak256 digest).
pub const MESSAGE_LEN: usize = 32;

/// Length of a raw `(r, s)` ECDSA signature in bytes (32 + 32).
pub const SIGNATURE_LEN: usize = 64;

/// Leading byte of a SEC1-compressed pubkey with even y-coordinate.
pub const SEC1_TAG_EVEN: u8 = 0x02;

/// Leading byte of a SEC1-compressed pubkey with odd y-coordinate.
pub const SEC1_TAG_ODD: u8 = 0x03;

/// Verify an ECDSA secp256k1 signature against a message hash and
/// public key.
///
/// Returns `true` iff:
///
///   1. `pk` is exactly 33 bytes long and begins with `0x02` or
///      `0x03` (SEC1-compressed format).
///   2. `msg` is exactly 32 bytes long.
///   3. `sig` is exactly 64 bytes long.
///   4. The parsed `(r, s)` pair satisfies `1 ≤ r < n` and
///      `1 ≤ s < n` (`k256` enforces this on `Signature::from_slice`).
///   5. `s ≤ n / 2` (low-s canonicalisation, EIP-2 / BIP-62).
///   6. The signature verifies against `pk` and `msg` per SEC1
///      §4.1.4.
///
/// Returns `false` for every other case, including malformed
/// inputs, parse failures, high-s signatures, and invalid
/// signatures.  Never panics.
#[must_use]
pub fn verify(pk: &[u8], msg: &[u8], sig: &[u8]) -> bool {
    // Length validation up front.  All three checks must pass
    // before any cryptographic operation runs.
    if pk.len() != PUBKEY_LEN {
        return false;
    }
    if msg.len() != MESSAGE_LEN {
        return false;
    }
    if sig.len() != SIGNATURE_LEN {
        return false;
    }

    // SEC1 prefix discipline.  The plan §RH-A.1.b enforces this
    // explicitly to refuse any non-compressed pubkey format
    // (uncompressed 0x04, hybrid 0x06 / 0x07, infinity 0x00, etc.).
    //
    // Constant-time comparison is overkill here (the prefix byte
    // is not a secret), but `subtle::ConstantTimeEq` is the
    // crate-standard primitive and keeps the discipline uniform
    // across the adaptor's input-validation surface.
    let prefix = pk[0];
    let is_even: u8 = prefix.ct_eq(&SEC1_TAG_EVEN).unwrap_u8();
    let is_odd: u8 = prefix.ct_eq(&SEC1_TAG_ODD).unwrap_u8();
    // The two bits are mutually exclusive (the prefix is a single
    // byte and the constants are distinct), so the OR is the same
    // as XOR; we use OR for clarity.
    if (is_even | is_odd) == 0 {
        return false;
    }

    // Parse the public key.  `from_sec1_bytes` accepts both
    // compressed (33 bytes) and uncompressed (65 bytes) forms; we
    // already gated the length to 33 above, so only compressed
    // keys reach this call.  The parser internally validates that
    // the encoded x-coordinate corresponds to a point on the
    // curve, rejecting forged inputs.
    let Ok(verifying_key) = VerifyingKey::from_sec1_bytes(pk) else {
        return false;
    };

    // Parse the signature.  `from_slice` rejects:
    //   * Lengths != 64 (already gated above).
    //   * `r == 0` or `r >= n`.
    //   * `s == 0` or `s >= n`.
    // It does NOT enforce low-s; we do that below.
    let Ok(signature) = Signature::from_slice(sig) else {
        return false;
    };

    // Low-s canonicalisation (EIP-2 / BIP-62).  `k256`'s
    // `IsHigh` trait returns `Choice::from(1)` if `s > n / 2`.
    // We use the constant-time `unwrap_u8` to extract; a `1`
    // means high-s and is rejected.
    //
    // Mathematical note: `IsHigh` is defined as `s > (n - 1) / 2`
    // in `k256`, which for the odd-order secp256k1 group equals
    // `s > n / 2` (the BIP-62 threshold).  Signatures with
    // `s == n / 2` exactly do not exist (n is odd), so the
    // boundary case is empty.
    if signature.s().is_high().unwrap_u8() != 0 {
        return false;
    }

    // Final cryptographic verification.  `verify_prehash` runs
    // the textbook ECDSA verification equation; returns
    // `Err(Error)` on any failure.
    verifying_key.verify_prehash(msg, &signature).is_ok()
}

/// C ABI surface for the verification core.  Exposed as
/// `knomosis_verify_ecdsa_raw` so the Lean-side shim
/// (`c/lean_shim.c`) can call into it from a `lean_object *`
/// argument convention.
///
/// # Safety
///
/// The caller must guarantee that, for each `(ptr, len)` pair:
///   * If `len == 0`, `ptr` may be dangling but must be a valid
///     pointer for zero-length reads (any non-null pointer
///     satisfies this).
///   * If `len > 0`, `ptr` points to a contiguous `len`-byte
///     region of initialised memory that is valid for reads for
///     the duration of the call.
///   * The three slices do not need to be aliased-distinct; they
///     are only read, never modified.
///
/// Returns `1` if the signature is valid (all checks pass); `0`
/// otherwise.  Never panics (the release profile sets
/// `panic = "abort"` as a defence-in-depth measure against
/// unwinding into Lean's runtime).
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn knomosis_verify_ecdsa_raw(
    pk_ptr: *const u8,
    pk_len: usize,
    msg_ptr: *const u8,
    msg_len: usize,
    sig_ptr: *const u8,
    sig_len: usize,
) -> u8 {
    // `core::slice::from_raw_parts` requires:
    //   * the pointer is non-null (or `len == 0` with a
    //     dangling pointer — both cases produce a valid empty
    //     slice).
    //   * the total size `len * size_of::<T>()` does not exceed
    //     `isize::MAX`.
    //
    // For `len > 0`, we accept a non-null pointer (the caller's
    // contract).  For `len == 0`, we substitute a known-good
    // dangling pointer so we always have a valid empty slice
    // regardless of the caller's pointer value.
    let pk = make_slice(pk_ptr, pk_len);
    let msg = make_slice(msg_ptr, msg_len);
    let sig = make_slice(sig_ptr, sig_len);

    u8::from(verify(pk, msg, sig))
}

/// Build a byte slice from a `(ptr, len)` pair, substituting a
/// dangling-but-valid pointer when `len == 0` so the resulting
/// slice is always sound regardless of the caller's pointer.
///
/// # Safety
///
/// When `len > 0`, the caller must guarantee that `ptr` is
/// non-null and points to a contiguous `len`-byte region of
/// initialised memory valid for the slice's lifetime.
#[allow(unsafe_code)]
unsafe fn make_slice<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        // Returning `&[]` (a slice of a compiler-synthesized
        // static empty array) avoids any dependence on the
        // caller's pointer for the empty case — even a NULL or
        // dangling `ptr` is safe when `len == 0`.
        &[]
    } else {
        // Caller guarantees `ptr` is valid for `len` bytes.
        core::slice::from_raw_parts(ptr, len)
    }
}

// ============================================================
// Lean ABI entry point
// ============================================================
//
// This module's full production responsibility is materialising
// the `knomosis_verify_ecdsa` C symbol that a Lean deployment links
// against to override the `LegalKernel/Authority/Crypto.lean`
// `Verify` opaque.  The Lean ABI uses `lean_object *` arguments;
// extracting their byte slices requires Lean runtime helpers
// (`lean_sarray_size` / `lean_sarray_cptr`) which are
// `static inline` in `lean.h` and therefore not directly
// callable from Rust.
//
// The C shim (`c/lean_shim.c`) exposes non-inline wrappers
// (`knomosis_lean_*`) that this Rust code binds to via `extern "C"`.
// Defining the entry point in Rust (rather than C) ensures
// `rustc`'s cdylib export discipline puts the symbol in the
// dynamic-symbol table — see `src/lib.rs`'s docstring for the
// rationale.
//
// Gating: this code only compiles when `build.rs` has located
// `lean.h` and the C shim has been built (cfg `knomosis_lean_ffi`).
// Without the shim, the `extern "C"` declarations below would
// produce undefined references at link time.

#[cfg(knomosis_lean_ffi)]
#[allow(unsafe_code)]
extern "C" {
    /// Non-inline wrapper around `lean_sarray_size`.  Defined in
    /// `c/lean_shim.c`.
    fn knomosis_lean_sarray_size(o: *const u8) -> usize;
    /// Non-inline wrapper around `lean_sarray_cptr`.
    fn knomosis_lean_sarray_cptr(o: *const u8) -> *const u8;
    /// Non-inline wrapper around `lean_dec`.
    fn knomosis_lean_dec(o: *const u8);
    /// Non-inline wrapper around `lean_mk_string_from_bytes`.  Defined
    /// in `c/lean_shim.c`; used by `knomosis_verify_identifier`.
    fn knomosis_lean_mk_string_from_bytes(s: *const u8, sz: usize) -> *mut u8;
}

/// `knomosis_verify_ecdsa(pk, msg, sig) -> Bool` — Lean ABI entry
/// point for ECDSA secp256k1 verification.
///
/// The three arguments are Lean `ByteArray`s passed as owned
/// `lean_object *`.  This function reads their byte payloads,
/// delegates verification to [`verify`], decrements the
/// reference counts (per Lean's `@[extern]` owned-transfer
/// ABI), and returns the result as a `u8` (Lean's C
/// representation for `Bool`).
///
/// # Safety
///
/// Each argument must be a valid owned `lean_object *` of Lean
/// type `ByteArray`.  The function dereferences each pointer
/// once to extract the payload, then `knomosis_lean_dec`-releases
/// it.  Callers must not pass the same pointer to two
/// arguments unless the pointer's underlying object's reference
/// count is at least 2 (because each argument is owned-consumed
/// independently).
///
/// Returns `1` if the signature is valid; `0` for every other
/// case including malformed inputs and verification failure.
#[cfg(knomosis_lean_ffi)]
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn knomosis_verify_ecdsa(
    pk: *const u8,
    msg: *const u8,
    sig: *const u8,
) -> u8 {
    let pk_len = knomosis_lean_sarray_size(pk);
    let pk_ptr = knomosis_lean_sarray_cptr(pk);
    let msg_len = knomosis_lean_sarray_size(msg);
    let msg_ptr = knomosis_lean_sarray_cptr(msg);
    let sig_len = knomosis_lean_sarray_size(sig);
    let sig_ptr = knomosis_lean_sarray_cptr(sig);

    let result = knomosis_verify_ecdsa_raw(pk_ptr, pk_len, msg_ptr, msg_len, sig_ptr, sig_len);

    // Release the three owned references AFTER reading the byte
    // data: `lean_dec` may deallocate the buffer, invalidating
    // the pointer.
    knomosis_lean_dec(pk);
    knomosis_lean_dec(msg);
    knomosis_lean_dec(sig);

    result
}

/// The verifier identifier bytes — single-sourced from
/// [`crate::ADAPTOR_IDENTIFIER`] so it cannot drift from the Lean-side
/// `Bridge.VerifyAdaptor.verifyAdaptorIdentifier` constant it mirrors.
#[cfg(knomosis_lean_ffi)]
const IDENTIFIER_BYTES: &[u8] = crate::ADAPTOR_IDENTIFIER.as_bytes();

/// `knomosis_verify_identifier(u) -> String` — Lean ABI entry point
/// reporting the linked verifier's identifier (security-review F-2).
/// When this adaptor is linked ahead of `knomosis-hash-fallback.o`, it
/// overrides the default fallback forwarder so `knomosis verify-check`
/// reports `production` (the gate's true-positive path).
///
/// # Safety
///
/// `u` must be a valid owned `lean_object *` (the Lean `Unit`
/// argument).  It is `knomosis_lean_dec`-released; a fresh owned Lean
/// `String` is returned (owned-transfer ABI, matching the hash adaptor's
/// `knomosis_hash_identifier`).
#[cfg(knomosis_lean_ffi)]
#[no_mangle]
#[allow(unsafe_code)]
pub unsafe extern "C" fn knomosis_verify_identifier(u: *const u8) -> *mut u8 {
    knomosis_lean_dec(u);
    knomosis_lean_mk_string_from_bytes(IDENTIFIER_BYTES.as_ptr(), IDENTIFIER_BYTES.len())
}

#[cfg(test)]
mod tests {
    use super::{verify, MESSAGE_LEN, PUBKEY_LEN, SEC1_TAG_EVEN, SEC1_TAG_ODD, SIGNATURE_LEN};

    /// Length constants match the documented contract.  Belt-and-
    /// suspenders against an accidental value change.
    #[test]
    fn length_constants_match_contract() {
        assert_eq!(PUBKEY_LEN, 33);
        assert_eq!(MESSAGE_LEN, 32);
        assert_eq!(SIGNATURE_LEN, 64);
    }

    /// Wrong-length public key → false.
    #[test]
    fn rejects_short_pubkey() {
        assert!(!verify(&[0x02; 32], &[0u8; 32], &[1u8; 64]));
    }

    /// Wrong-length public key (too long) → false.
    #[test]
    fn rejects_long_pubkey() {
        assert!(!verify(&[0x02; 34], &[0u8; 32], &[1u8; 64]));
    }

    /// Wrong-length message → false.
    #[test]
    fn rejects_short_message() {
        let mut pk = [0x02u8; 33];
        pk[1] = 0xAA;
        assert!(!verify(&pk, &[0u8; 31], &[1u8; 64]));
    }

    /// Wrong-length message (too long) → false.
    #[test]
    fn rejects_long_message() {
        let mut pk = [0x02u8; 33];
        pk[1] = 0xAA;
        assert!(!verify(&pk, &[0u8; 33], &[1u8; 64]));
    }

    /// Wrong-length signature → false.
    #[test]
    fn rejects_short_signature() {
        let mut pk = [0x02u8; 33];
        pk[1] = 0xAA;
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 63]));
    }

    /// Wrong-length signature (too long) → false.  Notably this
    /// covers the 65-byte Ethereum `(r || s || v)` form: callers
    /// must strip `v` before calling.
    #[test]
    fn rejects_65byte_signature() {
        let mut pk = [0x02u8; 33];
        pk[1] = 0xAA;
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 65]));
    }

    /// Empty inputs → false (don't panic).
    #[test]
    fn rejects_empty_inputs() {
        assert!(!verify(&[], &[], &[]));
    }

    /// Wrong SEC1 prefix (uncompressed 0x04) → false.  Even though
    /// the length gate would already reject a 65-byte uncompressed
    /// pubkey, a forged 33-byte buffer starting with `0x04` is
    /// otherwise well-formed; the prefix check catches it.
    #[test]
    fn rejects_uncompressed_prefix_at_compressed_length() {
        let pk = [0x04u8; 33];
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 64]));
    }

    /// Wrong SEC1 prefix (hybrid 0x06) → false.
    #[test]
    fn rejects_hybrid_even_prefix() {
        let pk = [0x06u8; 33];
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 64]));
    }

    /// Wrong SEC1 prefix (hybrid 0x07) → false.
    #[test]
    fn rejects_hybrid_odd_prefix() {
        let pk = [0x07u8; 33];
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 64]));
    }

    /// Zero r component → false (`Signature::from_slice` rejects).
    #[test]
    fn rejects_zero_r() {
        let pk = make_valid_pk();
        let mut sig = [0u8; 64];
        // r = 0, s = 1: parser rejects.
        sig[63] = 1;
        assert!(!verify(&pk, &[0u8; 32], &sig));
    }

    /// Zero s component → false.
    #[test]
    fn rejects_zero_s() {
        let pk = make_valid_pk();
        let mut sig = [0u8; 64];
        sig[31] = 1; // r = 1, s = 0
        assert!(!verify(&pk, &[0u8; 32], &sig));
    }

    /// r == curve order → false.  `Signature::from_slice` enforces
    /// `1 ≤ r < n`.
    #[test]
    fn rejects_r_equals_order() {
        let pk = make_valid_pk();
        let mut sig = [0u8; 64];
        // Big-endian curve order (n) in the r field.
        let n_be: [u8; 32] = [
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFE, 0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B, 0xBF, 0xD2, 0x5E, 0x8C,
            0xD0, 0x36, 0x41, 0x41,
        ];
        sig[0..32].copy_from_slice(&n_be);
        sig[63] = 1; // s = 1
        assert!(!verify(&pk, &[0u8; 32], &sig));
    }

    /// s == curve order → false.
    #[test]
    fn rejects_s_equals_order() {
        let pk = make_valid_pk();
        let mut sig = [0u8; 64];
        sig[31] = 1; // r = 1
        let n_be: [u8; 32] = [
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFE, 0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B, 0xBF, 0xD2, 0x5E, 0x8C,
            0xD0, 0x36, 0x41, 0x41,
        ];
        sig[32..64].copy_from_slice(&n_be);
        assert!(!verify(&pk, &[0u8; 32], &sig));
    }

    /// SEC1-prefixed pubkey with `x = 0` → false.
    ///
    /// `x = 0` is not on secp256k1: `y² = x³ + 7 = 7 (mod p)`, and
    /// `7` is a quadratic non-residue mod the secp256k1 prime, so
    /// no `y` solves the curve equation.  `from_sec1_bytes` rejects
    /// at parse time, so `verify` returns `false` regardless of
    /// the signature value.
    #[test]
    fn rejects_pubkey_with_zero_x() {
        let mut pk = [0u8; 33];
        pk[0] = 0x02; // valid SEC1 prefix; x = 0 in pk[1..33]
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 64]));
    }

    /// SEC1-prefixed pubkey with arbitrary 32-byte x (`[0x02; 33]`,
    /// where x = 0x0202...02) → false.  Either off-curve (parse
    /// fails) or on-curve but signature fails to verify against a
    /// random sig.  Either way, `verify` returns `false`.
    #[test]
    fn rejects_arbitrary_x_with_random_signature() {
        let pk = [0x02u8; 33];
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 64]));
    }

    /// SEC1 prefix `0x00` (infinity / invalid encoding) → false.
    #[test]
    fn rejects_zero_prefix() {
        let pk = [0x00u8; 33];
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 64]));
    }

    /// SEC1 prefix `0x01` (unassigned / invalid) → false.
    #[test]
    fn rejects_prefix_one() {
        let pk = [0x01u8; 33];
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 64]));
    }

    /// SEC1 prefix `0x05` (unassigned / invalid; falls between
    /// hybrid 0x04 and 0x06) → false.
    #[test]
    fn rejects_prefix_five() {
        let pk = [0x05u8; 33];
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 64]));
    }

    /// SEC1 prefix `0xFF` (max byte; invalid) → false.
    #[test]
    fn rejects_prefix_max() {
        let pk = [0xFFu8; 33];
        assert!(!verify(&pk, &[0u8; 32], &[1u8; 64]));
    }

    /// Exhaustively test every prefix byte in `0..=255` excluding
    /// the two accepted values (`0x02`, `0x03`).  All 254 invalid
    /// prefixes must be rejected by the prefix gate before any
    /// cryptographic work runs.
    ///
    /// This complements the property tests by providing
    /// deterministic coverage of every byte value rather than
    /// the 256-sample proptest default.
    #[test]
    fn rejects_every_invalid_prefix_exhaustively() {
        for prefix in u8::MIN..=u8::MAX {
            if prefix == SEC1_TAG_EVEN || prefix == SEC1_TAG_ODD {
                continue;
            }
            let mut pk = [0u8; 33];
            pk[0] = prefix;
            pk[1] = 0xAA; // arbitrary non-zero x byte
            assert!(
                !verify(&pk, &[0u8; 32], &[1u8; 64]),
                "prefix 0x{prefix:02X} should be rejected by the SEC1 gate"
            );
        }
    }

    /// Helper: a syntactically-valid 33-byte compressed pubkey
    /// (does not necessarily decode to a curve point; sufficient
    /// for tests that only check prefix / length).
    fn make_valid_pk() -> [u8; 33] {
        // Generator G's x-coordinate is the canonical valid x.
        // SEC1-compressed encoding: 0x02 (even y) || x.
        const GX: [u8; 32] = [
            0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC, 0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87,
            0x0B, 0x07, 0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9, 0x59, 0xF2, 0x81, 0x5B,
            0x16, 0xF8, 0x17, 0x98,
        ];
        let mut pk = [0u8; 33];
        pk[0] = 0x02;
        pk[1..33].copy_from_slice(&GX);
        pk
    }
}
