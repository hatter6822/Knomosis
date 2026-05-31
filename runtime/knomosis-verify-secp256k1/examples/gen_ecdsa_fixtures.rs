// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `gen-ecdsa-fixtures` — RH-A.1.d corpus generator.
//!
//! Deterministically produces the `.cxsf` fixture file consumed
//! by `knomosis-verify-secp256k1`'s cross-stack tests.  The output is
//! committed under `runtime/tests/cross-stack/ecdsa_secp256k1.cxsf`
//! and re-generated whenever the corpus changes.
//!
//! The corpus comprises three classes of vectors:
//!
//!   1. **Valid signatures.**  Signatures produced by signing
//!      a fixed message corpus with deterministic ECDSA (RFC 6979)
//!      under fixed secret keys.  Each vector's `expected` byte
//!      is `0x01` (accept).
//!   2. **High-s signatures.**  Each high-s case starts from a
//!      valid low-s signature `(r, s)` and substitutes `s' = n - s`,
//!      which is still a valid ECDSA signature on the curve but
//!      is rejected by the adaptor's EIP-2 / BIP-62 low-s gate.
//!      Each vector's `expected` byte is `0x00` (reject).
//!   3. **Tampered signatures.**  Single-byte mutations to the
//!      message, signature, or pubkey of a known-good vector;
//!      every mutation should fail verification.  Each vector's
//!      `expected` byte is `0x00`.
//!
//! ## Fixture record layout
//!
//! Each record's `input` field is the concatenation:
//!
//! ```text
//! pk_len (u16 BE) ‖ pk bytes ‖ msg_len (u16 BE) ‖ msg bytes ‖ sig_len (u16 BE) ‖ sig bytes
//! ```
//!
//! The `expected` field is a single byte: `0x01` for accept, `0x00`
//! for reject.  Test consumers parse `input` into the three
//! constituent slices and call [`verify`].
//!
//! ## Determinism
//!
//! ECDSA signing requires a per-signature nonce `k`.  The k256
//! `SigningKey::sign_prehash` uses RFC 6979 deterministic nonces
//! by default, so two calls with the same `(sk, msg)` produce
//! byte-identical signatures.  This makes the corpus fully
//! reproducible: anyone re-running this binary against the same
//! seeds gets a byte-identical `.cxsf` output.
//!
//! ## Usage
//!
//! ```text
//! cargo run --example gen_ecdsa_fixtures -- <output-path>
//! ```
//!
//! If `<output-path>` is omitted, the default is
//! `runtime/tests/cross-stack/ecdsa_secp256k1.cxsf` relative to
//! the workspace root.
//!
//! ## Why this lives under `examples/` rather than `src/bin/`
//!
//! The generator needs `knomosis-cross-stack` (a dev-dep) and the
//! `std`-enabled signing feature set of `k256`.  Cargo allows
//! examples to consume dev-dependencies and dev-feature-flags
//! transparently, while `src/bin/` targets cannot.  The generator
//! is also not a production runtime artefact — it's a developer
//! tool — so the `examples/` convention is the right one.

use k256::ecdsa::signature::hazmat::PrehashSigner;
use k256::ecdsa::{Signature, SigningKey, VerifyingKey};
use k256::elliptic_curve::scalar::IsHigh;
use knomosis_cross_stack::{FixtureFile, FixtureKind, FixtureRecord};
use knomosis_verify_secp256k1::{verify, MESSAGE_LEN, PUBKEY_LEN, SIGNATURE_LEN};
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

/// Number of distinct secret keys to generate signatures under.
const KEY_COUNT: usize = 10;

/// Number of messages signed per key (so the corpus has at least
/// `KEY_COUNT * MSGS_PER_KEY` valid signatures).
const MSGS_PER_KEY: usize = 3;

/// secp256k1 group order `n`, big-endian 32 bytes.  Mirrored from
/// `LegalKernel/Bridge/VerifyAdaptor.lean`'s `secp256k1OrderBytes`.
const SECP256K1_N_BE: [u8; 32] = [
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
    0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B, 0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
];

fn main() -> ExitCode {
    let output_path: PathBuf = env::args()
        .nth(1)
        .map_or_else(default_output_path, PathBuf::from);

    let records = build_corpus();

    // Sanity check: every record's `expected` field must match the
    // crate's actual `verify` output.  This is the load-bearing
    // invariant that downstream cross-stack tests depend on; if
    // the generator and the verifier disagree, the corpus is
    // worthless.  Fail fast here rather than emit a broken fixture.
    for (index, record) in records.iter().enumerate() {
        let Some((pk, msg, sig)) = parse_input(&record.input) else {
            eprintln!(
                "internal: malformed input record at index {index}; the generator emitted \
                 a record whose `input` field cannot be parsed."
            );
            return ExitCode::from(1);
        };
        let expected = record.expected.first().copied().unwrap_or(0xFF);
        let actual = u8::from(verify(pk, msg, sig));
        if actual != expected {
            eprintln!(
                "internal: record {index} disagrees with verifier: expected={expected}, \
                 actual={actual}.  Fix the generator before regenerating fixtures."
            );
            return ExitCode::from(1);
        }
    }

    let fixture = FixtureFile::from_records(FixtureKind::Ecdsa, records);
    if let Some(parent) = output_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            eprintln!("failed to create output directory {parent:?}: {e}");
            return ExitCode::from(1);
        }
    }
    if let Err(e) = fixture.write_to(&output_path) {
        eprintln!("failed to write fixture file {output_path:?}: {e}");
        return ExitCode::from(1);
    }
    println!(
        "wrote {} records ({} bytes) to {}",
        fixture.records().len(),
        fixture.to_bytes().len(),
        output_path.display()
    );
    ExitCode::SUCCESS
}

/// Default output path: `runtime/tests/cross-stack/ecdsa_secp256k1.cxsf`
/// relative to the workspace root.
fn default_output_path() -> PathBuf {
    // `CARGO_MANIFEST_DIR` is `runtime/knomosis-verify-secp256k1/`;
    // climbing one directory yields `runtime/`.
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.pop();
    p.push("tests");
    p.push("cross-stack");
    p.push("ecdsa_secp256k1.cxsf");
    p
}

/// Build the full corpus of fixture records.
///
/// Records are produced in a deterministic order:
///   * Block A: every valid signature, in `(key, msg)` lexicographic order.
///   * Block B: high-s variants of every block-A signature.
///   * Block C: tampered variants of every block-A signature.
///
/// Total expected: `KEY_COUNT * MSGS_PER_KEY * (1 + 1 + 5) = 210`
/// records (30 valid + 30 high-s + 150 tampered = 210), well above
/// the plan's "≥ 50 fixture vectors" floor.  `KEY_COUNT * MSGS_PER_KEY`
/// is 30 (10 keys × 3 messages each), each contributing one valid +
/// one high-s + five tampered records.
fn build_corpus() -> Vec<FixtureRecord> {
    let mut records = Vec::new();

    // Block A: valid signatures.
    let valid_vectors = build_valid_vectors();
    for vec in &valid_vectors {
        records.push(make_record(&vec.pk, &vec.msg, &vec.sig, true));
    }

    // Block B: high-s variants.  For each valid (r, s), substitute
    // s' = n - s and re-verify (it should fail the low-s gate).
    for vec in &valid_vectors {
        let high_s_sig = to_high_s(&vec.sig);
        records.push(make_record(&vec.pk, &vec.msg, &high_s_sig, false));
    }

    // Block C: tampered variants.  For each valid signature, emit
    // five mutations: first byte of msg, last byte of msg, first
    // byte of r, last byte of s, first byte of pk (skipping the
    // prefix).  Each mutation should fail verification.
    for vec in &valid_vectors {
        // 1. Flip the first byte of the message.
        let mut bad_msg = vec.msg;
        bad_msg[0] ^= 0x01;
        records.push(make_record(&vec.pk, &bad_msg, &vec.sig, false));

        // 2. Flip the last byte of the message.
        let mut bad_msg = vec.msg;
        bad_msg[MESSAGE_LEN - 1] ^= 0x01;
        records.push(make_record(&vec.pk, &bad_msg, &vec.sig, false));

        // 3. Flip a byte in r (the high byte of `r`).
        let mut bad_sig = vec.sig;
        bad_sig[0] ^= 0x01;
        records.push(make_record(&vec.pk, &vec.msg, &bad_sig, false));

        // 4. Flip a byte in s (the low byte of `s`).
        let mut bad_sig = vec.sig;
        bad_sig[SIGNATURE_LEN - 1] ^= 0x01;
        records.push(make_record(&vec.pk, &vec.msg, &bad_sig, false));

        // 5. Flip a byte in the pubkey's x-coordinate.  The result
        //    may be a non-curve x; either way verification fails.
        let mut bad_pk = vec.pk;
        bad_pk[1] ^= 0x01;
        records.push(make_record(&bad_pk, &vec.msg, &vec.sig, false));
    }

    records
}

/// One valid `(pk, msg, sig)` triple.
struct ValidVector {
    pk: [u8; PUBKEY_LEN],
    msg: [u8; MESSAGE_LEN],
    sig: [u8; SIGNATURE_LEN],
}

/// Produce the canonical block-A list of valid signatures.
///
/// Iteration order:
///   * For `key_idx` in `0..KEY_COUNT`:
///       * For `msg_idx` in `0..MSGS_PER_KEY`:
///           * sign `derive_msg(key_idx, msg_idx)` with
///             `derive_key(key_idx)`.
fn build_valid_vectors() -> Vec<ValidVector> {
    let mut out = Vec::with_capacity(KEY_COUNT * MSGS_PER_KEY);
    for key_idx in 0..KEY_COUNT {
        let sk_bytes = derive_key(key_idx);
        let sk = SigningKey::from_bytes(&sk_bytes.into())
            .expect("derived 32-byte scalar yields a valid SigningKey");
        let vk: &VerifyingKey = sk.verifying_key();
        let pk_point = vk.to_encoded_point(true);
        let pk_slice = pk_point.as_bytes();
        assert_eq!(
            pk_slice.len(),
            PUBKEY_LEN,
            "compressed pubkey must be 33 bytes",
        );
        let mut pk = [0u8; PUBKEY_LEN];
        pk.copy_from_slice(pk_slice);

        for msg_idx in 0..MSGS_PER_KEY {
            let msg = derive_msg(key_idx, msg_idx);
            // `sign_prehash` uses RFC 6979 deterministic nonces;
            // the same `(sk, msg)` pair always yields the same
            // signature.  This is what makes the corpus
            // bit-stable across regenerations.
            let signature: Signature = sk
                .sign_prehash(&msg)
                .expect("signing a 32-byte prehash with a valid key cannot fail");
            // `Signature::to_bytes` returns the 64-byte raw form
            // `(r || s)`; this is exactly what the adaptor's
            // verify function expects.
            let sig_bytes = signature.to_bytes();
            // k256's `sign_prehash` already produces low-s
            // signatures by default; assert this so the corpus's
            // "valid" block reflects the canonical form.
            assert!(
                signature.s().is_high().unwrap_u8() == 0,
                "k256 must produce low-s signatures by default; signing key #{key_idx} \
                 message #{msg_idx} produced a high-s signature, indicating a k256 API \
                 regression"
            );
            let mut sig = [0u8; SIGNATURE_LEN];
            sig.copy_from_slice(&sig_bytes);

            out.push(ValidVector { pk, msg, sig });
        }
    }
    out
}

/// Derive the secret key for a given `key_idx`.  Uses a
/// reproducible scheme: `sk[i] = (key_idx + 1)` byte-repeated to
/// 32 bytes, with a small offset so each byte position is
/// different (preventing accidental zero-y or curve-degenerate
/// keys).
fn derive_key(key_idx: usize) -> [u8; 32] {
    let mut sk = [0u8; 32];
    for (pos, byte) in sk.iter_mut().enumerate() {
        // Hash-like mixing: `(key_idx + 1) * 17 + pos * 31` mod 256.
        // Wrapping arithmetic keeps the result in `u8`.
        let v: u32 = u32::try_from(key_idx + 1).expect("KEY_COUNT < u32::MAX") * 17
            + u32::try_from(pos).expect("32 < u32::MAX") * 31;
        let byte_value = u8::try_from(v & 0xff).expect("masked u8");
        // Ensure the first byte is non-zero so the key is never
        // all-zero (which would be an invalid scalar).
        *byte = if pos == 0 && byte_value == 0 {
            1
        } else {
            byte_value
        };
    }
    sk
}

/// Derive the message hash for a given `(key_idx, msg_idx)` pair.
/// Same mixing scheme as `derive_key`, with the additional
/// `msg_idx` factor.
fn derive_msg(key_idx: usize, msg_idx: usize) -> [u8; MESSAGE_LEN] {
    let mut msg = [0u8; MESSAGE_LEN];
    let k = u32::try_from(key_idx).expect("KEY_COUNT < u32::MAX");
    let m = u32::try_from(msg_idx).expect("MSGS_PER_KEY < u32::MAX");
    for (pos, byte) in msg.iter_mut().enumerate() {
        let p = u32::try_from(pos).expect("32 < u32::MAX");
        let v = k.wrapping_mul(13) ^ m.wrapping_mul(7) ^ p.wrapping_mul(41);
        *byte = u8::try_from(v & 0xff).expect("masked u8");
    }
    msg
}

/// Transform a low-s signature `(r, s)` to its high-s mate `(r, n - s)`.
///
/// `n - s` modulo `n` is just `n - s` for `s < n`, and `k256`'s
/// `Signature::from_slice` rejects `s == 0`, so the result is
/// always in `(0, n)`.
fn to_high_s(sig: &[u8; SIGNATURE_LEN]) -> [u8; SIGNATURE_LEN] {
    // Compute (n - s) using a manual big-endian subtraction.
    // `s` is bytes [32..64]; `n` is `SECP256K1_N_BE`.
    let mut result = *sig;
    let s = &sig[32..64];

    let mut borrow: i32 = 0;
    let mut new_s = [0u8; 32];
    for i in (0..32).rev() {
        let n_byte = i32::from(SECP256K1_N_BE[i]);
        let s_byte = i32::from(s[i]);
        let diff = n_byte - s_byte - borrow;
        if diff < 0 {
            new_s[i] = u8::try_from(diff + 256).expect("borrow-corrected byte fits in u8");
            borrow = 1;
        } else {
            new_s[i] = u8::try_from(diff).expect("non-negative diff < 256 fits in u8");
            borrow = 0;
        }
    }
    // `n - s` should be < n (because s > 0), so borrow == 0 here.
    debug_assert_eq!(borrow, 0, "n - s underflowed; s was outside (0, n)");

    result[32..64].copy_from_slice(&new_s);
    result
}

/// Construct a single fixture record.  The input layout is:
///
/// ```text
/// pk_len (u16 BE) || pk bytes || msg_len (u16 BE) || msg bytes || sig_len (u16 BE) || sig bytes
/// ```
fn make_record(pk: &[u8], msg: &[u8], sig: &[u8], expected_accept: bool) -> FixtureRecord {
    let mut input = Vec::with_capacity(6 + pk.len() + msg.len() + sig.len());
    let pk_len_u16 = u16::try_from(pk.len()).expect("pk length fits in u16");
    let msg_len_u16 = u16::try_from(msg.len()).expect("msg length fits in u16");
    let sig_len_u16 = u16::try_from(sig.len()).expect("sig length fits in u16");
    input.extend_from_slice(&pk_len_u16.to_be_bytes());
    input.extend_from_slice(pk);
    input.extend_from_slice(&msg_len_u16.to_be_bytes());
    input.extend_from_slice(msg);
    input.extend_from_slice(&sig_len_u16.to_be_bytes());
    input.extend_from_slice(sig);

    let expected = vec![u8::from(expected_accept)];
    FixtureRecord::new(input, expected)
}

/// Parse a fixture record's `input` field back into `(pk, msg, sig)`
/// slices.  Used by `main`'s sanity check.  Returns `None` if the
/// layout is malformed (which would be a generator bug).
fn parse_input(input: &[u8]) -> Option<(&[u8], &[u8], &[u8])> {
    let mut cursor = 0;
    let pk_len = read_u16_be(input, &mut cursor)?;
    let pk = read_slice(input, &mut cursor, pk_len)?;
    let msg_len = read_u16_be(input, &mut cursor)?;
    let msg = read_slice(input, &mut cursor, msg_len)?;
    let sig_len = read_u16_be(input, &mut cursor)?;
    let sig = read_slice(input, &mut cursor, sig_len)?;
    if cursor == input.len() {
        Some((pk, msg, sig))
    } else {
        None
    }
}

fn read_u16_be(input: &[u8], cursor: &mut usize) -> Option<usize> {
    let next = cursor.checked_add(2)?;
    let bytes = input.get(*cursor..next)?;
    let arr: [u8; 2] = bytes.try_into().ok()?;
    *cursor = next;
    Some(usize::from(u16::from_be_bytes(arr)))
}

fn read_slice<'a>(input: &'a [u8], cursor: &mut usize, len: usize) -> Option<&'a [u8]> {
    let next = cursor.checked_add(len)?;
    let bytes = input.get(*cursor..next)?;
    *cursor = next;
    Some(bytes)
}
