// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Property-based tests for `knomosis-hash-keccak256`.
//!
//! Covers four complementary properties:
//!
//!   1. **No panics on arbitrary input.**  Random byte slices of
//!      any length up to 100 KB never panic; the function is total.
//!   2. **Streaming == one-shot.**  For every random input,
//!      hashing via the streaming context (per-byte updates)
//!      produces the same digest as the one-shot `keccak256`.
//!   3. **Bulk == one-shot.**  Same but via bulk update.
//!   4. **Determinism.**  Repeated hashing produces the same digest.

use knomosis_hash_keccak256::{
    keccak256, knomosis_hash_keccak256_finalize, knomosis_hash_keccak256_init,
    knomosis_hash_keccak256_update_bulk, knomosis_hash_keccak256_update_byte,
};
use proptest::collection::vec as prop_vec;
use proptest::prelude::*;

proptest! {
    /// Property 1: keccak256 is total — never panics — for any
    /// byte slice up to 100 KB.
    #[test]
    fn never_panics_on_arbitrary_input(input in prop_vec(any::<u8>(), 0..100_000)) {
        let _ = keccak256(&input);
    }
}

proptest! {
    /// Property 2: streaming per-byte produces the same digest
    /// as one-shot.
    #[test]
    fn streaming_byte_matches_oneshot(input in prop_vec(any::<u8>(), 0..2000)) {
        let one_shot = keccak256(&input);
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
        prop_assert_eq!(one_shot, streamed);
    }
}

proptest! {
    /// Property 3: streaming bulk produces the same digest as
    /// one-shot.
    #[test]
    fn streaming_bulk_matches_oneshot(input in prop_vec(any::<u8>(), 0..10_000)) {
        let one_shot = keccak256(&input);
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
        prop_assert_eq!(one_shot, streamed);
    }
}

proptest! {
    /// Property 4: hashing the same input twice yields the same
    /// digest.
    #[test]
    fn deterministic(input in prop_vec(any::<u8>(), 0..10_000)) {
        let h1 = keccak256(&input);
        let h2 = keccak256(&input);
        prop_assert_eq!(h1, h2);
    }
}

proptest! {
    /// Property 5: random chunking of the input produces the
    /// same digest as one-shot.  Chunk lengths are in `[1, 64]` so
    /// the loop is guaranteed to terminate; interleaved empty
    /// bulk-updates are tested by `empty_bulk_update_is_noop` in
    /// `src/hash.rs` and don't need to repeat here.
    #[test]
    fn random_chunking_matches_oneshot(
        input in prop_vec(any::<u8>(), 0..2000),
        chunk_seed in any::<u64>(),
    ) {
        let one_shot = keccak256(&input);

        // Deterministic chunk lengths from a tiny xorshift.  Each
        // chunk is in [1, 64] so we make at least 1 byte of
        // progress per iteration, guaranteeing termination in
        // O(input.len()) iterations regardless of the seed.
        let mut state = chunk_seed.max(1);
        let mut chunks: Vec<usize> = Vec::new();
        let mut remaining = input.len();
        while remaining > 0 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            // `state % 64` is in [0, 63]; adding 1 yields [1, 64].
            // Guarantees progress every iteration.
            let take_max: usize = 1 + usize::try_from(state % 64).unwrap_or(0);
            let take = take_max.min(remaining);
            chunks.push(take);
            remaining -= take;
        }

        let ctx = knomosis_hash_keccak256_init();
        let mut cursor = 0;
        for chunk_len in &chunks {
            #[allow(unsafe_code)]
            unsafe {
                knomosis_hash_keccak256_update_bulk(ctx, input[cursor..].as_ptr(), *chunk_len);
            }
            cursor += chunk_len;
        }
        let mut streamed = [0u8; 32];
        #[allow(unsafe_code)]
        unsafe {
            knomosis_hash_keccak256_finalize(ctx, streamed.as_mut_ptr());
        }
        prop_assert_eq!(one_shot, streamed);
    }
}
