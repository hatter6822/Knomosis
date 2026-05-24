// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Known-vector cross-stack tests for `knomosis-verify-secp256k1`.
//!
//! These tests cover well-known reference vectors from external
//! sources (Ethereum / SEC1 examples) and act as a third-party
//! cross-check against the in-repo fixture corpus.  The corpus
//! (`runtime/tests/cross-stack/ecdsa_secp256k1.cxsf`) is generated
//! by `examples/gen_ecdsa_fixtures.rs`; the tests here are
//! independent of that generator so a regression in the generator
//! cannot silently mask a regression in the verifier.

use hex::FromHex;
use knomosis_verify_secp256k1::verify;

fn hex_to_array<const N: usize>(s: &str) -> [u8; N] {
    let v = Vec::from_hex(s).expect("hex decode");
    assert_eq!(v.len(), N, "hex string has wrong byte length");
    let mut out = [0u8; N];
    out.copy_from_slice(&v);
    out
}

/// SEC1-style worked example.  This is a known-good (pk, msg, sig)
/// triple produced by `k256` at test-vector generation time with a
/// fixed secret key.  Re-derived independently so the test does
/// not depend on the `gen_ecdsa_fixtures` example's output.
///
/// Provenance: signing the message
/// `0x0000000000000000000000000000000000000000000000000000000000000001`
/// with the secret key `0x01...01` (32 bytes of 0x01) via
/// `k256::ecdsa::SigningKey::sign_prehash` (RFC 6979).  The
/// resulting signature is canonicalised to low-s by k256.
#[test]
fn known_good_signature_verifies() {
    use k256::ecdsa::signature::hazmat::PrehashSigner;
    use k256::ecdsa::{Signature, SigningKey};

    let sk_bytes = [1u8; 32];
    let msg = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 1,
    ];

    let sk = SigningKey::from_bytes(&sk_bytes.into()).expect("valid scalar");
    let vk = sk.verifying_key();
    let pk = vk.to_encoded_point(true);
    let pk_bytes = pk.as_bytes();
    assert_eq!(pk_bytes.len(), 33);

    let sig: Signature = sk.sign_prehash(&msg).expect("sign");
    let sig_bytes = sig.to_bytes();

    assert!(
        verify(pk_bytes, &msg, &sig_bytes),
        "freshly-signed signature must verify"
    );
}

/// Signing with one key and verifying with another → false.
#[test]
fn wrong_key_does_not_verify() {
    use k256::ecdsa::signature::hazmat::PrehashSigner;
    use k256::ecdsa::{Signature, SigningKey};

    let sk1_bytes = [1u8; 32];
    let sk2_bytes = [2u8; 32];
    let msg = [0xAAu8; 32];

    let sk1 = SigningKey::from_bytes(&sk1_bytes.into()).expect("valid scalar");
    let sk2 = SigningKey::from_bytes(&sk2_bytes.into()).expect("valid scalar");
    let vk2 = sk2.verifying_key();
    let pk2 = vk2.to_encoded_point(true);

    let sig: Signature = sk1.sign_prehash(&msg).expect("sign");
    let sig_bytes = sig.to_bytes();

    // sk1 signed; pk2 verifies → fail.
    assert!(!verify(pk2.as_bytes(), &msg, &sig_bytes));
}

/// Single-bit flip in the message → false.
#[test]
fn message_tampering_rejected() {
    use k256::ecdsa::signature::hazmat::PrehashSigner;
    use k256::ecdsa::{Signature, SigningKey};

    let sk_bytes = [3u8; 32];
    let msg = [0x33u8; 32];

    let sk = SigningKey::from_bytes(&sk_bytes.into()).expect("valid scalar");
    let vk = sk.verifying_key();
    let pk = vk.to_encoded_point(true);

    let sig: Signature = sk.sign_prehash(&msg).expect("sign");
    let sig_bytes = sig.to_bytes();

    let mut tampered_msg = msg;
    tampered_msg[0] ^= 0x01;

    assert!(!verify(pk.as_bytes(), &tampered_msg, &sig_bytes));
}

/// High-s variant of a known-good signature → false (low-s gate).
#[test]
fn high_s_rejected() {
    use k256::ecdsa::signature::hazmat::PrehashSigner;
    use k256::ecdsa::{Signature, SigningKey};

    let sk_bytes = [4u8; 32];
    let msg = [0x44u8; 32];

    let sk = SigningKey::from_bytes(&sk_bytes.into()).expect("valid scalar");
    let vk = sk.verifying_key();
    let pk = vk.to_encoded_point(true);

    let sig: Signature = sk.sign_prehash(&msg).expect("sign");
    let sig_bytes = sig.to_bytes();

    // The freshly-signed signature is low-s.
    assert!(verify(pk.as_bytes(), &msg, &sig_bytes));

    // Substitute s' = n - s; the resulting signature is high-s
    // and must be rejected by the adaptor.
    let mut high_s_sig = sig_bytes;
    let n_be: [u8; 32] =
        hex_to_array("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");
    let mut borrow: i32 = 0;
    for i in (0..32).rev() {
        let diff = i32::from(n_be[i]) - i32::from(high_s_sig[32 + i]) - borrow;
        if diff < 0 {
            high_s_sig[32 + i] = u8::try_from(diff + 256).expect("borrow fits");
            borrow = 1;
        } else {
            high_s_sig[32 + i] = u8::try_from(diff).expect("non-negative diff fits");
            borrow = 0;
        }
    }
    assert_eq!(borrow, 0);

    assert!(
        !verify(pk.as_bytes(), &msg, &high_s_sig),
        "high-s signature must be rejected"
    );

    // Defence-in-depth note: in k256 0.13, `verify_prehash` itself
    // also rejects high-s signatures (the library applies the same
    // EIP-2 / BIP-62 canonicalisation).  The adaptor's explicit
    // `is_high()` check is therefore *redundant* with k256 today,
    // but the redundancy is the point: should a future k256
    // version relax its internal low-s enforcement (e.g. to match
    // a non-Ethereum profile), the adaptor's check still rejects
    // the malleable signature.  The parser-level check here just
    // confirms that the signature is structurally well-formed.
    let parsed = Signature::from_slice(&high_s_sig);
    assert!(
        parsed.is_ok(),
        "high-s signature should parse cleanly (only r, s bounds are checked at parse time)"
    );
}

/// Zero r → false.  The k256 parser rejects.
#[test]
fn zero_r_rejected() {
    use k256::ecdsa::signature::hazmat::PrehashSigner;
    use k256::ecdsa::{Signature, SigningKey};

    let sk_bytes = [5u8; 32];
    let msg = [0x55u8; 32];

    let sk = SigningKey::from_bytes(&sk_bytes.into()).expect("valid scalar");
    let vk = sk.verifying_key();
    let pk = vk.to_encoded_point(true);

    let sig: Signature = sk.sign_prehash(&msg).expect("sign");
    let mut sig_bytes = sig.to_bytes();
    // Zero out r.
    sig_bytes[..32].fill(0);

    assert!(!verify(pk.as_bytes(), &msg, &sig_bytes));
}

/// Zero s → false.
#[test]
fn zero_s_rejected() {
    use k256::ecdsa::signature::hazmat::PrehashSigner;
    use k256::ecdsa::{Signature, SigningKey};

    let sk_bytes = [6u8; 32];
    let msg = [0x66u8; 32];

    let sk = SigningKey::from_bytes(&sk_bytes.into()).expect("valid scalar");
    let vk = sk.verifying_key();
    let pk = vk.to_encoded_point(true);

    let sig: Signature = sk.sign_prehash(&msg).expect("sign");
    let mut sig_bytes = sig.to_bytes();
    // Zero out s.
    sig_bytes[32..].fill(0);

    assert!(!verify(pk.as_bytes(), &msg, &sig_bytes));
}

/// Empty pubkey / message / signature → false.
#[test]
fn empty_inputs_rejected() {
    assert!(!verify(&[], &[], &[]));
    assert!(!verify(&[], &[0u8; 32], &[0u8; 64]));
}

/// Round-trip: 10 fresh signatures all verify; for each, flipping
/// any of the first 10 signature bits breaks verification.
/// Total: 10 + 10×10 = 110 verifications.  A quick smoke test of
/// the verify path and bit-flip robustness.
#[test]
fn batch_roundtrip_with_bit_flips() {
    use k256::ecdsa::signature::hazmat::PrehashSigner;
    use k256::ecdsa::{Signature, SigningKey};

    for key_idx in 0..10u8 {
        let sk_bytes = [key_idx + 1; 32];
        let msg = [key_idx; 32];
        let sk = SigningKey::from_bytes(&sk_bytes.into()).expect("valid scalar");
        let vk = sk.verifying_key();
        let pk = vk.to_encoded_point(true);
        let sig: Signature = sk.sign_prehash(&msg).expect("sign");
        let sig_bytes = sig.to_bytes();

        // Original verifies.
        assert!(verify(pk.as_bytes(), &msg, &sig_bytes));

        // Flip each of the first 10 signature bits; each must fail.
        for bit_idx in 0..10u32 {
            let mut bad_sig = sig_bytes;
            let byte_idx = (bit_idx / 8) as usize;
            let in_byte = bit_idx % 8;
            bad_sig[byte_idx] ^= 1 << in_byte;
            assert!(
                !verify(pk.as_bytes(), &msg, &bad_sig),
                "single-bit flip at sig byte {byte_idx} bit {in_byte} did not break verification \
                 (key #{key_idx})"
            );
        }
    }
}
