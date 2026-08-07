// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The Knomosis host workspace's 256-bit unsigned accounting scalar.
//!
//! # Why 256 bits exactly
//!
//! The kernel's credit ceiling is `Laws.maxAmount = 256 ^ 32 = 2^256`
//! (`LegalKernel/Laws/AmountBound.lean`), and `Laws.AmountBounded` —
//! a conjunct of every crediting law's precondition — is exactly
//! `< Laws.maxAmount`.  A kernel-legal balance is therefore precisely a
//! 256-bit unsigned integer: `Amount::MAX` is `2^256 - 1`, the largest
//! value the kernel will ever credit.
//!
//! That equality is load-bearing rather than decorative.  It means an
//! arithmetic overflow in this type is **unreachable under a truthful
//! event stream** — a `checked_add` that returns `None` proves the
//! event source disagrees with the kernel, which is why every consumer
//! is expected to treat it as a hard error rather than saturate.  The
//! predecessor representation was `u128`, which had no such property:
//! a balance could exceed `u128::MAX` by ordinary accumulation while
//! remaining perfectly kernel-legal, so a saturating write there
//! silently published a wrong number.
//!
//! # Representation and conventions
//!
//! [`Amount`] is a newtype over [`crypto_bigint::U256`], chosen because
//! that crate is already in the workspace's dependency graph (via
//! `k256`) and its arithmetic is widely reviewed.  The newtype exists
//! to give the workspace an accounting-shaped API over a
//! cryptography-shaped one:
//!
//!   * fallible arithmetic returns plain [`Option`], not the
//!     constant-time `CtOption` the engine returns.  Balances are not
//!     secret, so branching on them is fine and `?` should work;
//!   * [`Display`](core::fmt::Display) is **decimal**.  The engine's
//!     `Display` is hex, and the gateway's §6.2 envelope renders every
//!     bigint as a decimal string, so decimal is the workspace's
//!     canonical human form;
//!   * `serde` round-trips through that same decimal string, so a
//!     JSON amount is exact at any width (a JSON *number* would be
//!     read back as an `f64` by most clients and silently lose
//!     precision above `2^53`);
//!   * the byte codec is fixed-width 32-byte **big-endian**, matching
//!     both the Lean CBE amount payload and the EVM `uint256` word, so
//!     no consumer has to remember an endianness.
//!
//! # What this crate deliberately does not do
//!
//! No division, no modular arithmetic, and no operator overloads.  The
//! host workspace is a *view* over kernel-computed values: it adds
//! credits, subtracts debits, compares, and — in exactly one place —
//! multiplies a unit count by a rate.  Pricing (`AmmMath`) is the
//! kernel's job, and exposing a general numeric tower here would
//! invite a second, unproved implementation of it.
//!
//! [`Amount::checked_mul`] is the narrow exception, and it earns its
//! place: `knomosis-host`'s refund gate computes `budget_units ×
//! wei_per_budget_unit` from two operands it decodes off the wire, and
//! at `u128` that product could exceed the type and WRAP.  Both
//! operands together span at most `2^64 × 2^128 = 2^192`, so at this
//! width the product always fits and the wrap is unreachable rather
//! than merely guarded.  Arithmetic is offered as `checked_*` methods
//! only, never as `*`/`+`/`-`, so no caller can reach a wrapping or
//! panicking operation by writing the obvious thing.

#![doc(html_root_url = "https://docs.rs/knomosis-amount/0.17.0")]

use core::cmp::Ordering;
use core::fmt;
use core::str::FromStr;

use crypto_bigint::{CheckedAdd, CheckedMul, CheckedSub, Encoding, NonZero, U256};
use serde::de::{self, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Width of the canonical big-endian byte encoding of an [`Amount`].
///
/// Fixed, never length-prefixed: an amount is always exactly these
/// many bytes on the wire and in storage.  Matches the Lean CBE amount
/// payload (`Encoding/CBOR.lean`) and the EVM `uint256` word.
pub const AMOUNT_BYTES: usize = 32;

/// Maximum number of decimal digits an [`Amount`] can require.
///
/// `2^256 - 1` is a 78-digit decimal number.  Used to bound parsing
/// work and to pre-size formatting buffers.
pub const AMOUNT_MAX_DECIMAL_DIGITS: usize = 78;

/// Errors produced when building an [`Amount`] from an external
/// representation.
#[derive(Debug, thiserror::Error, Clone, Eq, PartialEq)]
pub enum AmountError {
    /// A byte slice was not exactly [`AMOUNT_BYTES`] long.
    ///
    /// The codec is fixed-width by design, so a short *or* long slice
    /// is a malformed encoding rather than something to zero-pad: a
    /// consumer that padded a short slice would silently reinterpret a
    /// truncated value as a valid smaller one.
    #[error("amount encoding must be exactly {AMOUNT_BYTES} bytes, got {got}")]
    WrongLength {
        /// Length actually supplied.
        got: usize,
    },
    /// A decimal string was empty.
    #[error("amount string is empty")]
    Empty,
    /// A decimal string contained a byte outside `0..=9`.
    #[error("amount string contains a non-digit at byte offset {offset}")]
    NonDigit {
        /// Offset of the first offending byte.
        offset: usize,
    },
    /// A decimal string denoted a value greater than [`Amount::MAX`].
    #[error("amount string denotes a value exceeding 2^256 - 1")]
    Overflow,
}

/// A 256-bit unsigned accounting scalar.
///
/// See the [crate docs](crate) for why the width is exactly 256 bits
/// and what that buys.
///
/// `Ord` is a plain total order on the numeric value — the engine's
/// constant-time comparison is not needed here and is not what callers
/// mean when they write `balance < delta`.
#[derive(Copy, Clone, Default, Eq, PartialEq, Hash)]
pub struct Amount(U256);

impl Amount {
    /// Zero.
    pub const ZERO: Self = Self(U256::ZERO);

    /// One.
    pub const ONE: Self = Self(U256::ONE);

    /// `2^256 - 1` — the largest representable amount, and exactly one
    /// less than the kernel's `Laws.maxAmount` ceiling.
    pub const MAX: Self = Self(U256::MAX);

    /// Build an amount from a `u128`.
    ///
    /// Total: every `u128` fits.  `const` so callers can build table
    /// constants.
    #[must_use]
    pub const fn from_u128(value: u128) -> Self {
        Self(U256::from_u128(value))
    }

    /// Build an amount from a `u64`.
    #[must_use]
    pub const fn from_u64(value: u64) -> Self {
        Self(U256::from_u64(value))
    }

    /// The value as a `u128`, or `None` if it does not fit.
    ///
    /// Deliberately fallible rather than truncating: a caller that
    /// needs a `u128` (an FFI boundary, a legacy column) must decide
    /// what to do about a value that does not fit, and the one thing
    /// it must never do is publish the low 128 bits as if they were
    /// the whole number.
    #[must_use]
    pub fn to_u128(self) -> Option<u128> {
        let bytes = self.to_be_bytes();
        // The high 16 bytes must all be zero for the value to fit.
        if bytes[..16].iter().any(|b| *b != 0) {
            return None;
        }
        let mut low = [0u8; 16];
        low.copy_from_slice(&bytes[16..]);
        Some(u128::from_be_bytes(low))
    }

    /// `true` if the amount is zero.
    #[must_use]
    pub fn is_zero(self) -> bool {
        self.0 == U256::ZERO
    }

    /// Checked addition — `None` on overflow past [`Amount::MAX`].
    ///
    /// Under a kernel-truthful event stream this never returns `None`:
    /// the kernel refuses any credit that would reach `2^256`, so a
    /// sum that overflows here proves the event source is wrong.
    /// Consumers should surface that as an error, not saturate.
    #[must_use]
    pub fn checked_add(self, rhs: Self) -> Option<Self> {
        Option::<U256>::from(self.0.checked_add(&rhs.0)).map(Self)
    }

    /// Checked subtraction — `None` on underflow below zero.
    #[must_use]
    pub fn checked_sub(self, rhs: Self) -> Option<Self> {
        Option::<U256>::from(self.0.checked_sub(&rhs.0)).map(Self)
    }

    /// Checked multiplication — `None` on overflow past
    /// [`Amount::MAX`].
    ///
    /// The one multiplication the workspace needs (see the crate
    /// docs): a unit count times a per-unit rate, both decoded from an
    /// untrusted wire.  Provided so no caller has to hand-roll
    /// 256-bit multiplication, and `checked_` so no caller can reach a
    /// wrapping `*` — which is precisely the shape of the defect this
    /// width closes, where a `u64 × u128` product wrapped `u128` and a
    /// solvency check read the wrapped remainder as the real cost.
    #[must_use]
    pub fn checked_mul(self, rhs: Self) -> Option<Self> {
        Option::<U256>::from(self.0.checked_mul(&rhs.0)).map(Self)
    }

    /// Saturating addition — clamps to [`Amount::MAX`] on overflow.
    ///
    /// **Not for stored balances.**  Use [`checked_add`] there: a
    /// stored balance that overflows proves the event source
    /// disagrees with the kernel, and clamping would publish a number
    /// that is simply wrong (see the crate docs).
    ///
    /// This exists for DERIVED read-side aggregates — quantities
    /// computed for display from operator configuration plus stored
    /// state, where the alternative to a clamp is failing a read over
    /// a value nobody can act on anyway.
    ///
    /// [`checked_add`]: Amount::checked_add
    #[must_use]
    pub fn saturating_add(self, rhs: Self) -> Self {
        self.checked_add(rhs).unwrap_or(Self::MAX)
    }

    /// Saturating subtraction — clamps to zero on underflow.
    ///
    /// Unlike [`saturating_add`], the floor here is usually the
    /// intended arithmetic rather than a fallback: "how much of an
    /// allowance is left" is zero once consumption exceeds the grant,
    /// not an error.
    ///
    /// [`saturating_add`]: Amount::saturating_add
    #[must_use]
    pub fn saturating_sub(self, rhs: Self) -> Self {
        self.checked_sub(rhs).unwrap_or(Self::ZERO)
    }

    /// The canonical fixed-width big-endian encoding.
    #[must_use]
    pub fn to_be_bytes(self) -> [u8; AMOUNT_BYTES] {
        self.0.to_be_bytes()
    }

    /// Decode from the canonical fixed-width big-endian encoding.
    ///
    /// Total on `[u8; 32]`: every 32-byte array denotes a valid
    /// amount, which is exactly the property that makes the widened
    /// decoder infallible where the `u128` one had to reject.
    #[must_use]
    pub fn from_be_bytes(bytes: [u8; AMOUNT_BYTES]) -> Self {
        Self(U256::from_be_bytes(bytes))
    }

    /// The canonical fixed-width LITTLE-endian encoding.
    ///
    /// The CBE amount payload is little-endian
    /// (`Encoding/CBOR.lean`), so wire codecs want this form while
    /// storage keyspaces want the big-endian one (whose byte order
    /// sorts numerically, which `SQLite`'s `BLOB` comparison relies on).
    /// Both are provided so no caller hand-rolls a reversal.
    #[must_use]
    pub fn to_le_bytes(self) -> [u8; AMOUNT_BYTES] {
        self.0.to_le_bytes()
    }

    /// Decode from the canonical fixed-width little-endian encoding.
    #[must_use]
    pub fn from_le_bytes(bytes: [u8; AMOUNT_BYTES]) -> Self {
        Self(U256::from_le_bytes(bytes))
    }

    /// Decode from a big-endian slice, requiring exactly
    /// [`AMOUNT_BYTES`] bytes.
    pub fn from_be_slice(bytes: &[u8]) -> Result<Self, AmountError> {
        let arr: [u8; AMOUNT_BYTES] = bytes
            .try_into()
            .map_err(|_| AmountError::WrongLength { got: bytes.len() })?;
        Ok(Self::from_be_bytes(arr))
    }
}

impl Ord for Amount {
    fn cmp(&self, other: &Self) -> Ordering {
        // `U256`'s own `Ord` is the numeric order; delegate rather
        // than re-deriving it over the limb array (whose in-memory
        // limb order is little-endian and would compare wrongly).
        self.0.cmp(&other.0)
    }
}

impl PartialOrd for Amount {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl From<u128> for Amount {
    fn from(value: u128) -> Self {
        Self::from_u128(value)
    }
}

impl From<u64> for Amount {
    fn from(value: u64) -> Self {
        Self::from_u64(value)
    }
}

impl TryFrom<Amount> for u128 {
    type Error = AmountError;

    fn try_from(value: Amount) -> Result<Self, Self::Error> {
        value.to_u128().ok_or(AmountError::Overflow)
    }
}

impl fmt::Display for Amount {
    /// Decimal, no separators, no leading zeros, `"0"` for zero.
    ///
    /// Hand-written because `crypto_bigint`'s own `Display` is
    /// hexadecimal, and decimal is the workspace's canonical human and
    /// wire form (the gateway §6.2 envelope renders every bigint this
    /// way).
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_zero() {
            return f.write_str("0");
        }
        // Repeated division by ten, least-significant digit first.
        // At most `AMOUNT_MAX_DECIMAL_DIGITS` iterations.
        let ten = NonZero::new(U256::from_u64(10)).expect("10 is non-zero");
        let mut digits = [0u8; AMOUNT_MAX_DECIMAL_DIGITS];
        let mut used = 0usize;
        let mut n = self.0;
        while n != U256::ZERO {
            let (quotient, remainder) = n.div_rem(&ten);
            // The remainder is < 10, so its least-significant byte is
            // the digit and every other byte is zero.
            let digit = remainder.to_be_bytes()[AMOUNT_BYTES - 1];
            digits[used] = b'0' + digit;
            used += 1;
            n = quotient;
        }
        // Reverse into most-significant-first order.
        digits[..used].reverse();
        let text = core::str::from_utf8(&digits[..used]).expect("ASCII digits are valid UTF-8");
        f.write_str(text)
    }
}

impl fmt::Debug for Amount {
    /// Decimal, matching `Display`.
    ///
    /// A separate hex `Debug` would mean a test failure printed a
    /// number in a different base than the assertion that produced it,
    /// which is a reliable way to waste an afternoon.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Amount({self})")
    }
}

impl FromStr for Amount {
    type Err = AmountError;

    /// Parse a decimal string.
    ///
    /// Strict by design: no sign, no underscores, no whitespace, no
    /// `0x` prefix, no empty string.  Leading zeros ARE accepted
    /// (`"007"` is seven) because they carry no ambiguity, but every
    /// other deviation is an error rather than a silent
    /// reinterpretation.
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if s.is_empty() {
            return Err(AmountError::Empty);
        }
        let ten = U256::from_u64(10);
        let mut acc = U256::ZERO;
        for (offset, byte) in s.bytes().enumerate() {
            if !byte.is_ascii_digit() {
                return Err(AmountError::NonDigit { offset });
            }
            let digit = U256::from_u64(u64::from(byte - b'0'));
            let scaled =
                Option::<U256>::from(acc.checked_mul(&ten)).ok_or(AmountError::Overflow)?;
            acc = Option::<U256>::from(scaled.checked_add(&digit)).ok_or(AmountError::Overflow)?;
        }
        Ok(Self(acc))
    }
}

impl Serialize for Amount {
    /// Serialise as a decimal STRING.
    ///
    /// Not as a JSON number: JSON numbers are `f64` in most clients,
    /// so any amount above `2^53` would round on the way back in.  A
    /// string round-trips exactly at every width, and matches how the
    /// gateway already renders bigints (§6.2).
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for Amount {
    /// Accepts either the decimal-string form (what we emit) or a bare
    /// JSON integer.
    ///
    /// `deserialize_any` rather than `deserialize_str` specifically to
    /// keep the integer form readable: every document this workspace
    /// has already written to disk stored amounts as JSON NUMBERS,
    /// because the predecessor type was a `u128`.  A strings-only
    /// reader would fail on all of them, turning a representation
    /// widening into a data-loss event for existing observer and
    /// indexer state.
    ///
    /// Safe here because the workspace serialises exclusively through
    /// `serde_json`, which is self-describing; `deserialize_any` would
    /// be wrong under a format like `bincode`, and the workspace
    /// depends on no such format.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(AmountVisitor)
    }
}

/// `serde` visitor accepting the decimal-string form.
struct AmountVisitor;

impl Visitor<'_> for AmountVisitor {
    type Value = Amount;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a decimal string denoting an integer in 0 ..= 2^256 - 1")
    }

    fn visit_str<E: de::Error>(self, value: &str) -> Result<Self::Value, E> {
        Amount::from_str(value).map_err(de::Error::custom)
    }

    /// Accept a bare JSON integer too, so a document written by the
    /// predecessor `u128` representation still parses.  Emission is
    /// always the string form.
    fn visit_u64<E: de::Error>(self, value: u64) -> Result<Self::Value, E> {
        Ok(Amount::from_u64(value))
    }

    fn visit_u128<E: de::Error>(self, value: u128) -> Result<Self::Value, E> {
        Ok(Amount::from_u128(value))
    }

    /// A negative integer is not an amount.  Handled explicitly so the
    /// rejection reads as "negative" rather than as a generic
    /// type mismatch.
    fn visit_i64<E: de::Error>(self, value: i64) -> Result<Self::Value, E> {
        u64::try_from(value)
            .map(Amount::from_u64)
            .map_err(|_| de::Error::custom("amount must not be negative"))
    }
}

#[cfg(test)]
mod tests {
    use super::{Amount, AmountError, AMOUNT_BYTES, AMOUNT_MAX_DECIMAL_DIGITS};
    use core::str::FromStr;

    /// `2^256 - 1` in decimal — 78 digits.
    const MAX_DECIMAL: &str =
        "115792089237316195423570985008687907853269984665640564039457584007913129639935";

    /// `2^128` in decimal.  The first value the retired `u128`
    /// representation could NOT hold.
    const TWO_POW_128_DECIMAL: &str = "340282366920938463463374607431768211456";

    /// `2^128` as an [`Amount`], built from its byte encoding so the
    /// construction does not itself go through a `u128`.
    fn two_pow_128() -> Amount {
        let mut bytes = [0u8; AMOUNT_BYTES];
        // Big-endian: bit 128 is the low bit of byte index 15.
        bytes[15] = 1;
        Amount::from_be_bytes(bytes)
    }

    // ---------------------------------------------------------------
    // The point of the widening
    // ---------------------------------------------------------------

    /// The regression test the whole crate exists for: a value at
    /// `2^128` is representable, round-trips through every codec, and
    /// prints as the right decimal number.
    ///
    /// The retired `u128` representation rejected this value in the
    /// decoder and saturated on it in the balance store, so this case
    /// failing means the widening did nothing.
    #[test]
    fn two_pow_128_is_representable_and_exact() {
        let value = two_pow_128();
        assert_eq!(value.to_string(), TWO_POW_128_DECIMAL);
        assert_eq!(Amount::from_str(TWO_POW_128_DECIMAL).unwrap(), value);
        assert_eq!(Amount::from_be_bytes(value.to_be_bytes()), value);
        // And it is genuinely out of `u128` range, so the test is not
        // silently exercising the narrow path.
        assert_eq!(value.to_u128(), None);
    }

    /// `u128::MAX` — the largest value the retired representation
    /// could hold — is the boundary, and the value one above it is
    /// where `to_u128` starts refusing.
    #[test]
    fn u128_boundary_is_exactly_where_narrowing_fails() {
        let max_u128 = Amount::from_u128(u128::MAX);
        assert_eq!(max_u128.to_u128(), Some(u128::MAX));

        let one_past = max_u128.checked_add(Amount::ONE).unwrap();
        assert_eq!(one_past, two_pow_128());
        assert_eq!(one_past.to_u128(), None);
    }

    /// `Amount::MAX` is `2^256 - 1`, exactly one below the kernel's
    /// `Laws.maxAmount = 256^32` ceiling.
    #[test]
    fn max_is_two_pow_256_minus_one() {
        assert_eq!(Amount::MAX.to_string(), MAX_DECIMAL);
        assert_eq!(MAX_DECIMAL.len(), AMOUNT_MAX_DECIMAL_DIGITS);
        assert_eq!(Amount::MAX.to_be_bytes(), [0xffu8; AMOUNT_BYTES]);
        assert_eq!(Amount::from_str(MAX_DECIMAL).unwrap(), Amount::MAX);
    }

    // ---------------------------------------------------------------
    // Arithmetic
    // ---------------------------------------------------------------

    #[test]
    fn checked_add_refuses_to_wrap_at_the_ceiling() {
        assert_eq!(Amount::MAX.checked_add(Amount::ONE), None);
        assert_eq!(Amount::MAX.checked_add(Amount::ZERO), Some(Amount::MAX));
        assert_eq!(
            Amount::MAX.checked_add(Amount::MAX),
            None,
            "a doubling overflow must be refused, not wrapped"
        );
    }

    #[test]
    fn checked_sub_refuses_to_wrap_at_zero() {
        assert_eq!(Amount::ZERO.checked_sub(Amount::ONE), None);
        assert_eq!(Amount::ZERO.checked_sub(Amount::ZERO), Some(Amount::ZERO));
        assert_eq!(Amount::ONE.checked_sub(Amount::ONE), Some(Amount::ZERO));
    }

    /// Addition and subtraction are inverse across the `u128`
    /// boundary, which is where a half-widened implementation would
    /// break.
    #[test]
    fn add_then_sub_round_trips_across_the_u128_boundary() {
        let base = Amount::from_u128(u128::MAX);
        let delta = Amount::from_u128(1_000_000);
        let sum = base.checked_add(delta).unwrap();
        assert!(sum > base, "the sum must exceed the base");
        assert_eq!(sum.to_u128(), None, "the sum must be out of u128 range");
        assert_eq!(sum.checked_sub(delta), Some(base));
    }

    // ---------------------------------------------------------------
    // Ordering
    // ---------------------------------------------------------------

    /// Ordering must be numeric, not limb-array-lexicographic.
    ///
    /// `U256` stores limbs least-significant-first, so a derived
    /// ordering over the limb array would compare the LOW limb first
    /// and get this pair backwards.  That is the specific bug this
    /// case exists to catch.
    #[test]
    fn ordering_is_numeric_not_limb_order() {
        let high = two_pow_128();
        let low = Amount::from_u128(u128::MAX);
        assert!(high > low);
        assert!(low < high);
        assert!(Amount::ZERO < Amount::ONE);
        assert!(Amount::MAX > two_pow_128());

        let mut sorted = [Amount::MAX, Amount::ZERO, high, low, Amount::ONE];
        sorted.sort_unstable();
        assert_eq!(sorted, [Amount::ZERO, Amount::ONE, low, high, Amount::MAX]);
    }

    // ---------------------------------------------------------------
    // Byte codec
    // ---------------------------------------------------------------

    #[test]
    fn be_codec_is_fixed_width_and_big_endian() {
        let one = Amount::ONE.to_be_bytes();
        assert_eq!(one[AMOUNT_BYTES - 1], 1, "one is in the LAST byte (BE)");
        assert!(one[..AMOUNT_BYTES - 1].iter().all(|b| *b == 0));
    }

    #[test]
    fn from_be_slice_refuses_any_length_but_32() {
        assert_eq!(
            Amount::from_be_slice(&[0u8; 16]),
            Err(AmountError::WrongLength { got: 16 }),
            "a 16-byte slice must NOT be zero-extended -- that is how a \
             truncated encoding reads as a valid smaller value"
        );
        assert_eq!(
            Amount::from_be_slice(&[0u8; 33]),
            Err(AmountError::WrongLength { got: 33 })
        );
        assert_eq!(
            Amount::from_be_slice(&[]),
            Err(AmountError::WrongLength { got: 0 })
        );
        assert!(Amount::from_be_slice(&[0u8; AMOUNT_BYTES]).is_ok());
    }

    /// Every 32-byte array denotes a valid amount.  This totality is
    /// what lets the widened decoder drop its `AmountTooWide` branch.
    #[test]
    fn every_32_byte_array_decodes() {
        for probe in [[0x00u8; 32], [0xffu8; 32], [0xa5u8; 32], [0x01u8; 32]] {
            let value = Amount::from_be_bytes(probe);
            assert_eq!(value.to_be_bytes(), probe);
        }
    }

    // ---------------------------------------------------------------
    // Decimal formatting and parsing
    // ---------------------------------------------------------------

    #[test]
    fn display_is_decimal_with_no_leading_zeros() {
        assert_eq!(Amount::ZERO.to_string(), "0");
        assert_eq!(Amount::ONE.to_string(), "1");
        assert_eq!(Amount::from_u64(10).to_string(), "10");
        assert_eq!(Amount::from_u64(1_000_000).to_string(), "1000000");
        assert_eq!(
            Amount::from_u128(u128::MAX).to_string(),
            "340282366920938463463374607431768211455"
        );
    }

    /// `Debug` prints the same base as `Display`, so a failing
    /// assertion does not report the value in hex while the assertion
    /// was written in decimal.
    #[test]
    fn debug_matches_display_base() {
        assert_eq!(format!("{:?}", Amount::from_u64(255)), "Amount(255)");
    }

    #[test]
    fn from_str_accepts_leading_zeros_but_nothing_else_odd() {
        assert_eq!(Amount::from_str("007").unwrap(), Amount::from_u64(7));
        assert_eq!(Amount::from_str("0").unwrap(), Amount::ZERO);

        assert_eq!(Amount::from_str(""), Err(AmountError::Empty));
        assert_eq!(
            Amount::from_str("12a4"),
            Err(AmountError::NonDigit { offset: 2 })
        );
        assert_eq!(
            Amount::from_str("-1"),
            Err(AmountError::NonDigit { offset: 0 }),
            "a sign is not a digit"
        );
        assert_eq!(
            Amount::from_str(" 1"),
            Err(AmountError::NonDigit { offset: 0 }),
            "whitespace is not trimmed"
        );
        assert_eq!(
            Amount::from_str("0x10"),
            Err(AmountError::NonDigit { offset: 1 }),
            "hex is not accepted -- decimal is the one form"
        );
        assert_eq!(
            Amount::from_str("1_000"),
            Err(AmountError::NonDigit { offset: 1 })
        );
    }

    /// One past `Amount::MAX` overflows rather than wrapping to zero.
    #[test]
    fn from_str_overflows_one_past_max() {
        let one_past =
            "115792089237316195423570985008687907853269984665640564039457584007913129639936";
        assert_eq!(Amount::from_str(one_past), Err(AmountError::Overflow));
        // And a wildly longer string does too, without looping
        // unboundedly.
        assert_eq!(
            Amount::from_str(&"9".repeat(100)),
            Err(AmountError::Overflow)
        );
    }

    // ---------------------------------------------------------------
    // serde
    // ---------------------------------------------------------------

    #[test]
    fn serde_round_trips_as_a_decimal_string() {
        let value = two_pow_128();
        let json = serde_json::to_string(&value).unwrap();
        assert_eq!(
            json,
            format!("\"{TWO_POW_128_DECIMAL}\""),
            "amounts serialise as STRINGS -- a JSON number would be read \
             back as an f64 and lose precision above 2^53"
        );
        assert_eq!(serde_json::from_str::<Amount>(&json).unwrap(), value);
    }

    #[test]
    fn serde_round_trips_the_maximum() {
        let json = serde_json::to_string(&Amount::MAX).unwrap();
        assert_eq!(json, format!("\"{MAX_DECIMAL}\""));
        assert_eq!(serde_json::from_str::<Amount>(&json).unwrap(), Amount::MAX);
    }

    /// A bare JSON integer is accepted on the way in, so a
    /// hand-written fixture or a legacy document still parses.
    #[test]
    fn serde_accepts_a_bare_integer_on_input() {
        assert_eq!(
            serde_json::from_str::<Amount>("42").unwrap(),
            Amount::from_u64(42)
        );
    }

    #[test]
    fn serde_rejects_a_malformed_string() {
        assert!(serde_json::from_str::<Amount>("\"12a\"").is_err());
        assert!(serde_json::from_str::<Amount>("\"\"").is_err());
    }

    /// A negative number is not an amount, and the error says so.
    #[test]
    fn serde_rejects_a_negative_integer() {
        let err = serde_json::from_str::<Amount>("-1").unwrap_err();
        assert!(
            err.to_string().contains("negative"),
            "expected a negative-specific message, got: {err}"
        );
    }

    /// A JSON float is not an amount either -- accepting one would be
    /// the precision loss the string form exists to avoid.
    #[test]
    fn serde_rejects_a_float() {
        assert!(serde_json::from_str::<Amount>("1.5").is_err());
    }
}
