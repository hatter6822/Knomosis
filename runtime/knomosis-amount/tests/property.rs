// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Property tests for [`knomosis_amount::Amount`].
//!
//! # The oracle
//!
//! Most of these properties are checked against `u128` as an
//! **independent oracle**: for any two values that fit in a `u128`,
//! `Amount`'s arithmetic, ordering and formatting must agree with the
//! language's own, which is not derived from `crypto-bigint` in any
//! way.  That is what makes the suite non-vacuous — a bug in the
//! newtype's limb handling, endianness or digit extraction shows up as
//! a disagreement with a primitive nobody can get wrong.
//!
//! The oracle only covers the low 2^128 of the range, so the
//! properties that must hold ABOVE it (round-tripping, ordering,
//! overflow refusal) are stated over full-width 32-byte inputs
//! separately, where the invariants are self-contained rather than
//! comparative.
//!
//! Rides the stable toolchain (`cargo test --workspace`), unlike the
//! libFuzzer targets under `runtime/fuzz/`.

use core::str::FromStr;

use knomosis_amount::{Amount, AmountError, AMOUNT_BYTES};
use proptest::prelude::*;

/// Strategy producing a full-width amount from raw bytes, so the whole
/// 256-bit range is reachable (a `u128`-derived strategy could only
/// ever produce values below `2^128`).
fn any_amount() -> impl Strategy<Value = Amount> {
    any::<[u8; AMOUNT_BYTES]>().prop_map(Amount::from_be_bytes)
}

proptest! {
    // ------------------------------------------------------------------
    // Against the u128 oracle
    // ------------------------------------------------------------------

    /// Addition agrees with `u128` wherever `u128` can represent the
    /// result.
    #[test]
    fn add_agrees_with_u128_oracle(a: u128, b: u128) {
        let widened = Amount::from_u128(a).checked_add(Amount::from_u128(b));
        if let Some(expected) = a.checked_add(b) {
            prop_assert_eq!(widened, Some(Amount::from_u128(expected)));
        } else {
            // The oracle overflowed but `Amount` must NOT: the sum of
            // two u128s always fits in 256 bits.  This is the headline
            // improvement, so assert it rather than skipping the case.
            let sum = widened.expect("a u128 + u128 sum always fits in 256 bits");
            prop_assert!(sum > Amount::from_u128(a.max(b)));
            prop_assert_eq!(sum.to_u128(), None);
        }
    }

    /// Subtraction agrees with `u128`, including on underflow.
    #[test]
    fn sub_agrees_with_u128_oracle(a: u128, b: u128) {
        let widened = Amount::from_u128(a).checked_sub(Amount::from_u128(b));
        prop_assert_eq!(widened, a.checked_sub(b).map(Amount::from_u128));
    }

    /// Ordering agrees with `u128`.
    #[test]
    fn ordering_agrees_with_u128_oracle(a: u128, b: u128) {
        prop_assert_eq!(
            Amount::from_u128(a).cmp(&Amount::from_u128(b)),
            a.cmp(&b)
        );
    }

    /// Decimal formatting agrees with `u128`'s own.
    #[test]
    fn display_agrees_with_u128_oracle(a: u128) {
        prop_assert_eq!(Amount::from_u128(a).to_string(), a.to_string());
    }

    /// Decimal parsing agrees with `u128`'s own.
    #[test]
    fn from_str_agrees_with_u128_oracle(a: u128) {
        let text = a.to_string();
        prop_assert_eq!(Amount::from_str(&text).unwrap(), Amount::from_u128(a));
    }

    /// The big-endian codec agrees with `u128`'s, zero-extended into
    /// the high half.  Catches an endianness or limb-order slip that a
    /// pure round-trip test cannot see.
    #[test]
    fn be_bytes_agree_with_u128_oracle(a: u128) {
        let bytes = Amount::from_u128(a).to_be_bytes();
        prop_assert_eq!(&bytes[..16], &[0u8; 16][..], "high half must be zero");
        prop_assert_eq!(&bytes[16..], &a.to_be_bytes()[..]);
    }

    /// `to_u128` is exactly the inverse of `from_u128`.
    #[test]
    fn u128_narrowing_round_trips(a: u128) {
        prop_assert_eq!(Amount::from_u128(a).to_u128(), Some(a));
    }

    // ------------------------------------------------------------------
    // Full-width invariants (above the oracle's reach)
    // ------------------------------------------------------------------

    /// The byte codec round-trips over the WHOLE 256-bit range.
    #[test]
    fn be_codec_round_trips_full_width(value in any_amount()) {
        prop_assert_eq!(Amount::from_be_bytes(value.to_be_bytes()), value);
    }

    /// Decimal formatting and parsing round-trip over the whole range.
    #[test]
    fn decimal_round_trips_full_width(value in any_amount()) {
        let text = value.to_string();
        prop_assert!(!text.is_empty());
        prop_assert!(text.bytes().all(|b| b.is_ascii_digit()));
        prop_assert!(
            text == "0" || !text.starts_with('0'),
            "no leading zeros except for zero itself: {}", text
        );
        prop_assert_eq!(Amount::from_str(&text).unwrap(), value);
    }

    /// `serde` round-trips over the whole range, through the decimal
    /// string form.
    #[test]
    fn serde_round_trips_full_width(value in any_amount()) {
        let json = serde_json::to_string(&value).unwrap();
        prop_assert!(json.starts_with('"') && json.ends_with('"'),
            "amounts must serialise as strings, got {}", json);
        prop_assert_eq!(serde_json::from_str::<Amount>(&json).unwrap(), value);
    }

    /// Ordering is consistent with the big-endian byte order — which
    /// is exactly the property SQLite's `BLOB` comparison relies on
    /// when it scans a balance keyspace.
    #[test]
    fn ordering_matches_big_endian_byte_order(a in any_amount(), b in any_amount()) {
        prop_assert_eq!(a.cmp(&b), a.to_be_bytes().cmp(&b.to_be_bytes()));
    }

    /// Addition never wraps: if it returns a sum, that sum is at least
    /// each operand.
    #[test]
    fn add_never_wraps(a in any_amount(), b in any_amount()) {
        if let Some(sum) = a.checked_add(b) {
            prop_assert!(sum >= a);
            prop_assert!(sum >= b);
        }
    }

    /// Subtraction is the left inverse of addition wherever the sum
    /// exists.
    #[test]
    fn sub_inverts_add(a in any_amount(), b in any_amount()) {
        if let Some(sum) = a.checked_add(b) {
            prop_assert_eq!(sum.checked_sub(b), Some(a));
            prop_assert_eq!(sum.checked_sub(a), Some(b));
        }
    }

    /// Subtraction returns `None` exactly when the subtrahend is
    /// larger — no other condition may refuse.
    #[test]
    fn sub_refuses_exactly_on_underflow(a in any_amount(), b in any_amount()) {
        prop_assert_eq!(a.checked_sub(b).is_none(), b > a);
    }

    /// A slice of any length but 32 is refused, and never zero-padded
    /// into a valid smaller value.
    #[test]
    fn from_be_slice_refuses_wrong_lengths(len in 0usize..80) {
        let bytes = vec![0xffu8; len];
        let result = Amount::from_be_slice(&bytes);
        if len == AMOUNT_BYTES {
            prop_assert_eq!(result, Ok(Amount::MAX));
        } else {
            prop_assert_eq!(result, Err(AmountError::WrongLength { got: len }));
        }
    }

    /// Parsing never panics on arbitrary input, and only ever accepts
    /// an all-digit string.
    #[test]
    fn from_str_never_panics(text in ".{0,120}") {
        if Amount::from_str(&text).is_ok() {
            prop_assert!(!text.is_empty());
            prop_assert!(text.bytes().all(|b| b.is_ascii_digit()));
        }
    }

    /// Leading zeros do not change the value, at any width.
    #[test]
    fn leading_zeros_are_value_preserving(value in any_amount(), pad in 0usize..8) {
        let padded = format!("{}{}", "0".repeat(pad), value);
        prop_assert_eq!(Amount::from_str(&padded).unwrap(), value);
    }
}
