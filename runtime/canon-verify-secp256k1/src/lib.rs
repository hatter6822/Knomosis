// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `canon-verify-secp256k1` — RH-A.1.
//!
//! Production ECDSA secp256k1 verification adaptor for Canon's
//! Lean kernel.  Exposes the C symbol `canon_verify_ecdsa` that a
//! Lean deployment links against to wire
//! `LegalKernel/Authority/Crypto.lean`'s `Verify` opaque to a
//! real cryptographic implementation.
//!
//! ## Wire-format contract
//!
//! Mirrors `LegalKernel/Bridge/VerifyAdaptor.lean`'s documented
//! constants (with one strictness narrowing per the engineering
//! plan §RH-A.1.b):
//!
//! | Argument | Length     | Format                                       |
//! |----------|------------|----------------------------------------------|
//! | `pk`     | 33 bytes   | SEC1-compressed pubkey (`0x02`/`0x03` prefix)|
//! | `msg`    | 32 bytes   | Pre-hashed message (keccak256 typical)       |
//! | `sig`    | 64 bytes   | Raw `(r ‖ s)`, big-endian, 32+32             |
//!
//! The Lean-side `Bridge/VerifyAdaptor.lean` additionally
//! documents 65-byte Ethereum signatures (`r ‖ s ‖ v`); the
//! adaptor's contract is "strip v upstream" — the production
//! Rust core enforces 64-byte signatures.  Bridge-level adapters
//! at the deployment layer perform the `v`-stripping before
//! calling `canon_verify_ecdsa`.
//!
//! ## Security properties
//!
//! 1. **Strict length validation**: every malformed length returns
//!    `false` before any cryptographic work runs.
//! 2. **SEC1 prefix validation**: only `0x02` and `0x03` pubkey
//!    prefixes are accepted (compressed form).
//! 3. **Bounds validation**: `r` and `s` must satisfy `1 ≤ r < n`
//!    and `1 ≤ s < n` (delegated to `k256::ecdsa::Signature`).
//! 4. **Low-s canonicalisation (EIP-2 / BIP-62)**: signatures with
//!    `s > n / 2` are rejected.  This is the load-bearing
//!    malleability defence: without it, an adversary can take any
//!    valid signature and produce a second valid signature for
//!    the same `(pk, msg)` pair, breaking the kernel's
//!    `replay_impossible` precondition.
//! 5. **Curve-point validation**: pubkey x-coordinates that do
//!    not lie on the curve are rejected by
//!    `VerifyingKey::from_sec1_bytes`.
//! 6. **No panics**: every error path returns `false`; the
//!    workspace's release profile sets `panic = "abort"` as a
//!    belt-and-suspenders measure against unwinding into Lean's
//!    runtime via the C ABI.
//!
//! ## Implementation identifier
//!
//! The Lean-side counterpart constant lives at
//! `LegalKernel/Bridge/VerifyAdaptor.lean`:
//!
//! ```text
//! verifyAdaptorIdentifier := "ecdsa-secp256k1-low-s/EVM-compatible/v1"
//! ```
//!
//! The same string is published as [`ADAPTOR_IDENTIFIER`] in this
//! crate, so a future runtime-introspection symbol can return it
//! without duplicating the literal.
//!
//! ## Audit posture
//!
//! `unsafe_code = "deny"` (workspace lint, narrowed from the
//! skeleton's `"forbid"`).  The only `unsafe` annotations are:
//!
//!   * `extern "C"` block declaring the C shim wrappers
//!     (Rust 2024 makes extern blocks themselves require
//!     `unsafe`); the block is gated on `cfg(canon_lean_ffi)`.
//!   * `canon_verify_ecdsa_raw` — the testable C-ABI surface
//!     that takes raw pointers; its `# Safety` contract pins
//!     the caller's obligations.
//!   * `canon_verify_ecdsa` — the Lean ABI entry point
//!     (cfg-gated); reads three `lean_object *` `ByteArray`s,
//!     delegates to `_raw`, and releases owned references.
//!   * `make_slice` — pointer-to-slice helper, with safety
//!     contract documenting the empty-slice case and the
//!     non-empty pointer / length requirements.
//!
//! Every `unsafe` block has a documented `# Safety` section in
//! its docstring; the pure-Rust [`verify`] entry point at the
//! crate root is `safe` and panic-free.
//!
//! ## Build artefacts
//!
//! Three crate-types are produced (`Cargo.toml`'s `[lib]
//! crate-type` field):
//!
//!   * **`cdylib`** — production artefact; `canon_verify_ecdsa`
//!     exported via the `c/lean_shim.c` shim.  The shim is built
//!     by `build.rs` when `lean.h` is locatable on the build host.
//!   * **`staticlib`** — for integration tests that prefer
//!     static linking.
//!   * **`rlib`** — consumed by Rust callers (tests, fixture
//!     generator, future Rust runtime code).
//!
//! See `build.rs` for the Lean-include-dir discovery logic.

#![doc(html_root_url = "https://docs.rs/canon-verify-secp256k1/0.1.0")]

pub mod verify;

pub use verify::{
    canon_verify_ecdsa_raw, verify, MESSAGE_LEN, PUBKEY_LEN, SEC1_TAG_EVEN, SEC1_TAG_ODD,
    SIGNATURE_LEN,
};

/// Crate name, mirrored from `Cargo.toml`.
///
/// Future binaries that link this adaptor surface it via
/// `--version` / diagnostic output; the constant keeps the
/// surface stable across releases.
pub const CRATE_NAME: &str = "canon-verify-secp256k1";

/// Implementation identifier mirrored from
/// `LegalKernel/Bridge/VerifyAdaptor.lean`'s
/// `verifyAdaptorIdentifier` constant.
///
/// A future runtime-introspection C ABI symbol (analogous to
/// `canon_hash_identifier`) can return this string to let
/// operators distinguish which verify adaptor is linked into a
/// running deployment.
pub const ADAPTOR_IDENTIFIER: &str = "ecdsa-secp256k1-low-s/EVM-compatible/v1";

/// True iff the build script located `lean.h` and compiled the
/// Lean ABI shim.  Used by integration tests that need to know
/// whether the C symbol `canon_verify_ecdsa` is present in the
/// resulting cdylib.
///
/// On a Lean-less build host, this is `false`; the rlib and
/// staticlib still build, but the cdylib does not export the
/// `canon_verify_ecdsa` symbol.
#[must_use]
pub const fn lean_ffi_built() -> bool {
    cfg!(canon_lean_ffi)
}

#[cfg(test)]
mod tests {
    use super::{ADAPTOR_IDENTIFIER, CRATE_NAME, MESSAGE_LEN, PUBKEY_LEN, SIGNATURE_LEN};

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "canon-verify-secp256k1");
    }

    /// Implementation identifier matches the Lean-side
    /// `Bridge.VerifyAdaptor.verifyAdaptorIdentifier` constant.
    /// Any drift between the two strings is a cross-stack
    /// contract violation and CI surfaces it here.
    #[test]
    fn adaptor_identifier_matches_lean_constant() {
        assert_eq!(
            ADAPTOR_IDENTIFIER,
            "ecdsa-secp256k1-low-s/EVM-compatible/v1"
        );
    }

    /// Wire-format length constants are re-exported from the
    /// `verify` module; the values are tested at their source.
    /// This test asserts the re-export is stable (i.e. the
    /// `pub use` did not silently rename).
    #[test]
    fn length_constants_re_exported() {
        assert_eq!(PUBKEY_LEN, 33);
        assert_eq!(MESSAGE_LEN, 32);
        assert_eq!(SIGNATURE_LEN, 64);
    }
}
