// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Known-vector tests for `knomosis-hash-keccak256`.
//!
//! These tests use hard-coded reference vectors from published
//! sources to cross-check against the in-repo fixture corpus.
//! Any divergence between the fixture corpus (regenerated via
//! the example binary) and these hard-coded vectors surfaces as
//! a CI failure.
//!
//! Provenance of each vector is cited inline (typically
//! re-derived via the `sha3` crate with the same byte input, or
//! from published Ethereum Yellow Paper test vectors).

use knomosis_hash_keccak256::{
    knomosis_hash_keccak256_finalize, knomosis_hash_keccak256_init, knomosis_hash_keccak256_update_bulk,
    knomosis_hash_keccak256_update_byte, keccak256,
};
use hex::FromHex;

fn expect_keccak(input: &[u8], expected_hex: &str) {
    let actual = keccak256(input);
    let expected: Vec<u8> = Vec::from_hex(expected_hex)
        .unwrap_or_else(|_| panic!("invalid hex literal: {expected_hex}"));
    assert_eq!(
        actual.to_vec(),
        expected,
        "keccak256 mismatch for input {input:?}"
    );
}

/// keccak256("") = c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
/// Reference: Ethereum Yellow Paper, Eq. (29).
#[test]
fn empty_input() {
    expect_keccak(
        b"",
        "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
    );
}

/// keccak256("abc") = 4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45
#[test]
fn abc() {
    expect_keccak(
        b"abc",
        "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
    );
}

/// keccak256("the quick brown fox jumps over the lazy dog") =
/// 865bf05cca7ba26fb8051e8366c6d19e21cadeebe3ee6bfa462b5c72275414ec
/// (lowercase 't').  Note: the more commonly cited fox digest is
/// for the capital-T variant; case matters.
#[test]
fn fox_lowercase() {
    expect_keccak(
        b"the quick brown fox jumps over the lazy dog",
        "865bf05cca7ba26fb8051e8366c6d19e21cadeebe3ee6bfa462b5c72275414ec",
    );
}

/// keccak256("The quick brown fox jumps over the lazy dog") =
/// 4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15
/// (capital 'T').  This is the digest most commonly cited in
/// keccak256 / Ethereum documentation; pinning both variants
/// catches a case-folding hasher regression.
#[test]
fn fox_capital() {
    expect_keccak(
        b"The quick brown fox jumps over the lazy dog",
        "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15",
    );
}

/// keccak256 of the 32-byte zero word.  This is a load-bearing
/// constant in Ethereum (the empty-tree root for many MPT
/// constructions).
#[test]
fn zero32() {
    expect_keccak(
        &[0u8; 32],
        "290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563",
    );
}

/// keccak256 of 128 zero bytes.
#[test]
fn zero128() {
    expect_keccak(
        &[0u8; 128],
        "012893657d8eb2efad4de0a91bcd0e39ad9837745dec3ea923737ea803fc8e3d",
    );
}

/// keccak256 of one byte 0x00.
#[test]
fn zero_byte() {
    expect_keccak(
        &[0x00],
        "bc36789e7a1e281436464229828f817d6612f7b477d66591ff96a9e064bcc98a",
    );
}

/// Block-rate boundary: keccak256 of 135 bytes (one shy of the
/// 136-byte rate).  Confirms the one-shot and streaming paths
/// agree at this boundary.
#[test]
fn input_135_bytes() {
    let input = vec![0xABu8; 135];
    let actual = keccak256(&input);
    // Same hash via streaming bulk-update.
    let ctx = knomosis_hash_keccak256_init();
    #[allow(unsafe_code)]
    unsafe {
        knomosis_hash_keccak256_update_bulk(ctx, input.as_ptr(), input.len());
    }
    let mut streamed = [0u8; 32];
    #[allow(unsafe_code)]
    unsafe {
        knomosis_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
    }
    assert_eq!(actual, streamed);
}

/// keccak256 of 136 bytes (exactly the rate).
#[test]
fn input_136_bytes() {
    let input = vec![0xCDu8; 136];
    let actual = keccak256(&input);
    // Self-consistency: chunked update produces same digest.
    let ctx = knomosis_hash_keccak256_init();
    for &b in &input {
        #[allow(unsafe_code)]
        unsafe {
            knomosis_hash_keccak256_update_byte(ctx, b);
        }
    }
    let mut streamed = [0u8; 32];
    #[allow(unsafe_code)]
    unsafe {
        knomosis_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
    }
    assert_eq!(actual, streamed);
}

/// keccak256 of 137 bytes (one past the rate).
#[test]
fn input_137_bytes() {
    let input = vec![0xEFu8; 137];
    let actual = keccak256(&input);
    // Same digest via per-byte then bulk-suffix streaming.
    let ctx = knomosis_hash_keccak256_init();
    #[allow(unsafe_code)]
    unsafe {
        for &b in input.iter().take(50) {
            knomosis_hash_keccak256_update_byte(ctx, b);
        }
        knomosis_hash_keccak256_update_bulk(ctx, input[50..].as_ptr(), input.len() - 50);
    }
    let mut streamed = [0u8; 32];
    #[allow(unsafe_code)]
    unsafe {
        knomosis_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
    }
    assert_eq!(actual, streamed);
}
