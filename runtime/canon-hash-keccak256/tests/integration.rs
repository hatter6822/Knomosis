// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Integration tests for `knomosis-hash-keccak256`.
//!
//! Covers cross-file consistency invariants between the public
//! [`IDENTIFIER`] constant in `src/lib.rs` (the Rust API surface)
//! and the internal `IDENTIFIER_BYTES` byte-slice literal in
//! `src/hash.rs` (used by the `canon_hash_identifier` Lean ABI
//! entry point).  Both must agree byte-for-byte; CI surfaces a
//! drift here.

use canon_hash_keccak256::IDENTIFIER;

/// The Rust-side public `IDENTIFIER` constant (in `lib.rs`) is
/// also encoded as a byte-string literal `IDENTIFIER_BYTES` in
/// `hash.rs`, where the `canon_hash_identifier` Lean ABI entry
/// point returns it.  We grep `hash.rs` for the byte-literal form
/// of IDENTIFIER to catch silent drift between the two views.
/// The Lean fallback identifier
/// (`LegalKernel/Runtime/Hash.lean::fallbackHashIdentifier =
/// "fnv1a64-padded-32"`) is the counterpart — operators compare
/// the runtime-reported identifier against IDENTIFIER to confirm
/// the production adaptor is wired.
#[test]
fn identifier_constant_matches_hash_module() {
    use std::path::PathBuf;
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("src");
    p.push("hash.rs");
    let contents = std::fs::read_to_string(&p).unwrap_or_else(|e| {
        panic!("failed to read hash.rs at {}: {e}", p.display());
    });
    let needle = format!("b\"{IDENTIFIER}\"");
    assert!(
        contents.contains(&needle),
        "IDENTIFIER {IDENTIFIER:?} not found in {} as a byte string literal {needle:?}.  \
         The Lean ABI entry point `canon_hash_identifier` returns the IDENTIFIER_BYTES \
         slice in hash.rs, which must match the IDENTIFIER constant in lib.rs.",
        p.display()
    );
}
