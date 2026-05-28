// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Property-based and fuzz-style tests for `knomosis-verify-secp256k1`.
//!
//! Covers two complementary properties (per plan §RH-A.1.d):
//!
//!   1. **Malformed inputs always return `false` — never panic.**
//!      We sample random byte sequences for each input slot and
//!      assert that `verify` is total (returns `bool`, never
//!      panics).  This is the load-bearing robustness property
//!      against attacker-controlled input from Lean's runtime.
//!   2. **Round-trip determinism on freshly-signed inputs.**  For
//!      randomly-generated `(sk, msg)` pairs, signing with k256
//!      and immediately verifying with our adaptor must succeed.

use knomosis_verify_secp256k1::{verify, MESSAGE_LEN, PUBKEY_LEN, SIGNATURE_LEN};
use proptest::collection::vec as prop_vec;
use proptest::prelude::*;

proptest! {
    // Property 1.a: random byte sequences in the pk slot never
    // cause a panic; the function returns false (or true if by
    // pure chance the bytes encode a valid (pk, msg, sig) — astronomically
    // unlikely, but we assert no-panic regardless).
    #[test]
    fn random_pk_never_panics(pk in prop_vec(any::<u8>(), 0..200)) {
        let msg = [0u8; MESSAGE_LEN];
        let sig = [0u8; SIGNATURE_LEN];
        let _ = verify(&pk, &msg, &sig);
    }

    // Property 1.b: random msg slot never panics.
    #[test]
    fn random_msg_never_panics(msg in prop_vec(any::<u8>(), 0..200)) {
        let pk = [0x02u8; PUBKEY_LEN];
        let sig = [0u8; SIGNATURE_LEN];
        let _ = verify(&pk, &msg, &sig);
    }

    // Property 1.c: random sig slot never panics.
    #[test]
    fn random_sig_never_panics(sig in prop_vec(any::<u8>(), 0..200)) {
        let pk = [0x02u8; PUBKEY_LEN];
        let msg = [0u8; MESSAGE_LEN];
        let _ = verify(&pk, &msg, &sig);
    }

    // Property 1.d: completely random (pk, msg, sig) triples never panic.
    #[test]
    fn random_triple_never_panics(
        pk in prop_vec(any::<u8>(), 0..100),
        msg in prop_vec(any::<u8>(), 0..100),
        sig in prop_vec(any::<u8>(), 0..100),
    ) {
        let _ = verify(&pk, &msg, &sig);
    }

    // Property 1.e: random 33-byte pubkey + 32-byte message +
    // 64-byte signature.  Astronomically unlikely to verify by
    // chance; the assertion is the boundary case.
    #[test]
    fn random_correct_length_inputs_almost_never_accept(
        pk in prop_vec(any::<u8>(), PUBKEY_LEN..=PUBKEY_LEN),
        msg in prop_vec(any::<u8>(), MESSAGE_LEN..=MESSAGE_LEN),
        sig in prop_vec(any::<u8>(), SIGNATURE_LEN..=SIGNATURE_LEN),
    ) {
        // A random (pk, msg, sig) of correct lengths is
        // overwhelmingly unlikely to verify — probability ≈ 2⁻²⁵⁶.
        // The test just exercises the verify path with random
        // inputs; the assertion is just that no panic occurs.
        // We do NOT assert false because a freak collision would
        // be a true result and panicking on it is bad form.
        let _ = verify(&pk, &msg, &sig);
    }
}

proptest! {
    // Property 2: round-trip on freshly-signed inputs.  Always
    // succeeds (modulo the astronomical chance of the message
    // hashing to a curve-edge value, which `k256` handles internally).
    #[test]
    fn fresh_sign_verify_roundtrip(
        sk_seed in prop_vec(any::<u8>(), 32..=32),
        msg in prop_vec(any::<u8>(), 32..=32),
    ) {
        use k256::ecdsa::signature::hazmat::PrehashSigner;
        use k256::ecdsa::{Signature, SigningKey};

        // Force the first byte non-zero so the scalar is valid.
        let mut sk_bytes = [0u8; 32];
        sk_bytes.copy_from_slice(&sk_seed);
        if sk_bytes[0] == 0 {
            sk_bytes[0] = 1;
        }

        // The secret key may still be ≥ n; SigningKey::from_bytes
        // rejects that case.  Skip the test on rejection — this
        // is the standard proptest pattern for inputs that don't
        // satisfy a pre-condition (1 / 2^128 probability).
        let Ok(sk) = SigningKey::from_bytes(&sk_bytes.into()) else {
            return Ok(());
        };
        let vk = sk.verifying_key();
        let pk = vk.to_encoded_point(true);
        let mut msg_arr = [0u8; MESSAGE_LEN];
        msg_arr.copy_from_slice(&msg);

        let sig: Signature = sk.sign_prehash(&msg_arr).expect("sign succeeds for valid sk");
        let sig_bytes = sig.to_bytes();

        prop_assert!(
            verify(pk.as_bytes(), &msg_arr, &sig_bytes),
            "round-trip failed: sk={sk_bytes:02x?}, msg={msg_arr:02x?}"
        );
    }
}

proptest! {
    // Property 3: a high-s mate of a valid signature always fails.
    // We sign, transform to high-s, and assert rejection.
    #[test]
    fn high_s_mate_always_rejected(
        sk_seed in prop_vec(any::<u8>(), 32..=32),
        msg in prop_vec(any::<u8>(), 32..=32),
    ) {
        use k256::ecdsa::signature::hazmat::PrehashSigner;
        use k256::ecdsa::{Signature, SigningKey};

        let mut sk_bytes = [0u8; 32];
        sk_bytes.copy_from_slice(&sk_seed);
        if sk_bytes[0] == 0 {
            sk_bytes[0] = 1;
        }
        let Ok(sk) = SigningKey::from_bytes(&sk_bytes.into()) else {
            return Ok(());
        };
        let vk = sk.verifying_key();
        let pk = vk.to_encoded_point(true);
        let mut msg_arr = [0u8; MESSAGE_LEN];
        msg_arr.copy_from_slice(&msg);

        let sig: Signature = sk.sign_prehash(&msg_arr).expect("sign succeeds");
        let sig_bytes = sig.to_bytes();

        // Transform to high-s: s' = n - s.
        let n_be: [u8; 32] = [
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFE, 0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B, 0xBF, 0xD2, 0x5E, 0x8C,
            0xD0, 0x36, 0x41, 0x41,
        ];
        let mut high_s_sig = sig_bytes;
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
        prop_assert_eq!(borrow, 0);

        prop_assert!(
            !verify(pk.as_bytes(), &msg_arr, &high_s_sig),
            "high-s mate unexpectedly verified: sk={:02x?}, msg={:02x?}",
            sk_bytes,
            msg_arr
        );
    }
}
