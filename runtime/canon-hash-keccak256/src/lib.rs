// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `knomosis-hash-keccak256` — RH-A.2.
//!
//! Production Keccak-256 (Ethereum-flavoured) hash adaptor for
//! Knomosis's Lean kernel.  Exposes three C ABI symbols matching
//! Lean's `@[extern]` declarations in
//! `LegalKernel/Runtime/Hash.lean`:
//!
//!   * `canon_hash_bytes(bs)` — one-shot over a `ByteArray`.
//!   * `canon_hash_stream(bs)` — streaming over a `List UInt8`.
//!   * `canon_hash_identifier(u)` — returns the implementation
//!     identifier string.
//!
//! When a Knomosis binary is linked against this crate's cdylib
//! AHEAD of the default `runtime/knomosis-hash-fallback.o`, these
//! symbols override the FNV-1a-64 fallback forwarders and the
//! runtime hashes with production Keccak-256.  See
//! `LegalKernel/Runtime/Hash.lean`'s docstring for the
//! swap-point discipline.
//!
//! ## Variant: Keccak-256 (Ethereum), NOT FIPS-202 SHA3-256
//!
//! Documented common foot-gun: the two share the underlying
//! `Keccak-f[1600]` permutation but use different padding (0x01
//! for Keccak, 0x06 for SHA3-256), producing DIFFERENT digests
//! for the same input.  This crate uses `sha3::Keccak256` (the
//! correct Ethereum-canonical variant).  See plan §RH-A.2.a.
//!
//! ## Implementation identifier
//!
//! Published as [`IDENTIFIER`] and returned from the
//! `canon_hash_identifier` C symbol.  Operators read this at
//! startup to confirm which hash adaptor is linked; the Lean
//! side's `isProductionHash` check (`Runtime/Hash.lean`) reads
//! this string and decides whether to emit the fallback warning.
//!
//! ## Audit posture
//!
//! `unsafe_code = "deny"` workspace lint (narrowed from the
//! skeleton's `"forbid"`).  `unsafe` is restricted to:
//!
//!   * The `extern "C"` block declaring the C shim wrappers in
//!     `src/hash.rs` (cfg-gated on `canon_lean_ffi`).
//!   * `canon_hash_keccak256_bytes_raw` and the four
//!     streaming primitives (`_init`, `_update_byte`,
//!     `_update_bulk`, `_finalize`) — the testable C ABI surface
//!     with documented `# Safety` contracts.
//!   * `canon_hash_bytes`, `canon_hash_stream`,
//!     `canon_hash_identifier` — the Lean ABI entry points
//!     (cfg-gated).
//!   * Test-only `unsafe` blocks exercising the C ABI
//!     functions on stack-allocated buffers (always
//!     stack-allocated, never attacker-controlled).
//!
//! Build artefacts (cdylib / staticlib / rlib) never contain
//! any other `unsafe` code.  The pure-Rust [`keccak256`] entry
//! point is `safe` and panic-free for any input.
//!
//! ## Build artefacts
//!
//! Three crate-types are produced:
//!   * **`cdylib`** — production shared library with the three
//!     C ABI symbols.  Requires `lean.h` at build time (see
//!     `build.rs`); the symbols are exported by the
//!     `c/lean_shim.c` shim.
//!   * **`staticlib`** — for static-link integration tests.
//!   * **`rlib`** — consumed by Rust callers (the fixture
//!     generator, future host crates).
//!
//! For Rust callers, the safe API surface is the [`keccak256`]
//! function plus the streaming primitives in `hash`.

#![doc(html_root_url = "https://docs.rs/knomosis-hash-keccak256/0.1.0")]

pub mod hash;

pub use hash::{
    canon_hash_keccak256_bytes_raw, canon_hash_keccak256_finalize, canon_hash_keccak256_init,
    canon_hash_keccak256_update_bulk, canon_hash_keccak256_update_byte, keccak256, keccak256_vec,
    DIGEST_LEN,
};

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "knomosis-hash-keccak256";

/// The implementation identifier this adaptor returns from the
/// `canon_hash_identifier` C ABI symbol.
///
/// MUST match the `IDENTIFIER_BYTES` byte-string literal in
/// `src/hash.rs` exactly (the latter is the value
/// `canon_hash_identifier` actually returns at the FFI boundary).
/// The integration test
/// (`tests/integration.rs::identifier_constant_matches_hash_module`)
/// grep-validates this redundancy.
///
/// Operators read this string to confirm which adaptor is wired
/// into the running binary.  Compare against the Lean fallback
/// (`Runtime/Hash.lean`'s `fallbackHashIdentifier =
/// "fnv1a64-padded-32"`); deployments that need to refuse the
/// fallback gate on `isProductionHash` at startup.
pub const IDENTIFIER: &str = "keccak256/EVM-compatible/v1";

/// True iff the build script located `lean.h` and compiled the
/// Lean ABI shim.  Used by integration tests that need to know
/// whether the C symbols `canon_hash_*` are present in the
/// resulting cdylib.
#[must_use]
pub const fn lean_ffi_built() -> bool {
    cfg!(canon_lean_ffi)
}

#[cfg(test)]
mod tests {
    use super::{CRATE_NAME, DIGEST_LEN, IDENTIFIER};

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "knomosis-hash-keccak256");
    }

    /// The implementation identifier is the documented string;
    /// must not drift silently between releases.
    #[test]
    fn identifier_constant() {
        assert_eq!(IDENTIFIER, "keccak256/EVM-compatible/v1");
    }

    /// Output digest width is fixed at 32 bytes (matches Lean's
    /// `ContentHash` width per Audit-3.1).
    #[test]
    fn digest_len_is_32() {
        assert_eq!(DIGEST_LEN, 32);
    }
}
