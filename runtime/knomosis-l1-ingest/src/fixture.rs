// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Cross-stack fixture format for RH-B.
//!
//! ## What this module provides
//!
//! A simple serialised form of the `(IngestedEvent, AddressBook
//! snapshot, current_nonce)` triple — the input of the
//! `translation::ingest` function — plus a serialiser for the
//! expected output (`Option<UnsignedAction>`).
//!
//! These records become the inner bytes of the
//! `FixtureKind::L1Ingest` `.cxsf` corpus.
//!
//! ## Why this isn't CBE
//!
//! The cross-stack corpus's `input` field is freely-shaped — the
//! consumer (the test or fixture generator) deserialises it and
//! drives a Rust function with it.  The Lean side doesn't need
//! to read the input; only the `expected` field is byte-compared
//! with the Lean reference.
//!
//! That said, we use a length-prefixed binary form rather than
//! JSON for two reasons:
//!
//!   1. Determinism — JSON whitespace is non-canonical; the
//!      length-prefixed binary form is byte-stable.
//!   2. Compactness — the corpus may grow large; binary is
//!      smaller.
//!
//! ## On-disk layout
//!
//! Each input record:
//!
//! ```text
//!   offset    size   field
//!   0         1      event tag (0=RegisteredEcdsa, 1=RegisteredEip1271,
//!                                2=Revoked, 3=DepositInitiated)
//!   1         8      block_number (BE)
//!   9         32     tx_hash
//!   41        8      log_index (BE)
//!   49+       ...    event-specific payload
//! ```
//!
//! Event-specific payloads:
//!
//!   * **RegisteredEcdsa**: 20-byte actor + 4-byte pubkey length
//!     (BE) + pubkey bytes.
//!   * **RegisteredEip1271**: 20-byte actor + 20-byte contract_signer.
//!   * **Revoked**: 20-byte actor.
//!   * **DepositInitiated**: 20-byte depositor + 8-byte resource_id +
//!     20-byte token + 32-byte amount + 8-byte nonce + 32-byte receipt_hash.
//!
//! After the event-specific payload, the input also carries:
//!
//!   * 8-byte address-book size (BE).
//!   * For each entry: 20-byte address + 8-byte actor id.
//!   * 16-byte current_nonce (BE).

use crate::action::EthAddress;
use crate::events::IngestedEvent;
use crate::translation::UnsignedAction;

/// Tag bytes for the event variants in the fixture input format.
const EVENT_TAG_REGISTERED_ECDSA: u8 = 0;
const EVENT_TAG_REGISTERED_EIP1271: u8 = 1;
const EVENT_TAG_REVOKED: u8 = 2;
const EVENT_TAG_DEPOSIT_INITIATED: u8 = 3;
const EVENT_TAG_DEPOSIT_WITH_FEE: u8 = 4;

/// Defensive bound on the address-book length field decoded
/// from a fixture input.  Production bridges have ≤ ~10k
/// registered identities; one million is well past any
/// realistic value but small enough to fit in available memory
/// (one million entries × 28 bytes = 28 MiB).  Adjust upward
/// only if a deployment scenario justifies it.
pub const MAX_DECODED_ADDRESS_BOOK_ENTRIES: usize = 1_000_000;

/// Errors surfaced by the fixture encoders / decoders.
#[derive(Debug, Eq, PartialEq, thiserror::Error)]
pub enum FixtureError {
    /// The input ran out of bytes during decoding.
    #[error("unexpected end of fixture input at offset {offset}")]
    UnexpectedEnd {
        /// Where the decoder stopped.
        offset: usize,
    },
    /// An unrecognised event tag byte.
    #[error("unknown event tag {tag} at offset {offset}")]
    UnknownEventTag {
        /// The tag byte.
        tag: u8,
        /// Where it was located.
        offset: usize,
    },
    /// Encoding overflow.  Unreachable on any realistic input.
    #[error("encoding length overflow: {0}")]
    Overflow(String),
    /// A fixed-width payload had trailing bytes the decoder did not
    /// consume — i.e. the input was longer than the canonical
    /// representation.  Distinct from `UnexpectedEnd` (input too
    /// short) so a producer that drifted in either direction is
    /// surfaced with the right diagnostic.
    #[error("trailing bytes after fixed-width payload: consumed {consumed}, total {total}")]
    TrailingBytes {
        /// How many bytes the decoder actually consumed.
        consumed: usize,
        /// The full input length.
        total: usize,
    },
}

/// One synthesised fixture input: an event + a snapshot of the
/// address book (encoded as a sorted list) + the current nonce.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FixtureInput {
    /// The `L1Event` to ingest.
    pub event: IngestedEvent,
    /// A snapshot of the address book at the time of ingest.
    /// `Vec` (rather than `BTreeMap`) so the order is stable in
    /// the on-disk form.
    pub address_book: Vec<(EthAddress, u64)>,
    /// The signer's next-expected nonce at the time of ingest.
    pub current_nonce: u128,
}

/// Encode a `FixtureInput` to a deterministic byte stream.
///
/// # Errors
///
/// Returns `FixtureError::Overflow` for unrealistically large
/// inputs.
pub fn encode_input(input: &FixtureInput) -> Result<Vec<u8>, FixtureError> {
    let mut out = Vec::new();
    // Event tag + (block_number, tx_hash, log_index).
    match &input.event {
        IngestedEvent::RegisteredEcdsa {
            actor,
            pubkey,
            block_number,
            tx_hash,
            log_index,
        } => {
            out.push(EVENT_TAG_REGISTERED_ECDSA);
            out.extend_from_slice(&block_number.to_be_bytes());
            out.extend_from_slice(tx_hash);
            out.extend_from_slice(&log_index.to_be_bytes());
            out.extend_from_slice(actor.as_bytes());
            let len_u32 = u32::try_from(pubkey.len())
                .map_err(|_| FixtureError::Overflow(format!("pubkey len {}", pubkey.len())))?;
            out.extend_from_slice(&len_u32.to_be_bytes());
            out.extend_from_slice(pubkey);
        }
        IngestedEvent::RegisteredEip1271 {
            actor,
            contract_signer,
            block_number,
            tx_hash,
            log_index,
        } => {
            out.push(EVENT_TAG_REGISTERED_EIP1271);
            out.extend_from_slice(&block_number.to_be_bytes());
            out.extend_from_slice(tx_hash);
            out.extend_from_slice(&log_index.to_be_bytes());
            out.extend_from_slice(actor.as_bytes());
            out.extend_from_slice(contract_signer.as_bytes());
        }
        IngestedEvent::Revoked {
            actor,
            block_number,
            tx_hash,
            log_index,
        } => {
            out.push(EVENT_TAG_REVOKED);
            out.extend_from_slice(&block_number.to_be_bytes());
            out.extend_from_slice(tx_hash);
            out.extend_from_slice(&log_index.to_be_bytes());
            out.extend_from_slice(actor.as_bytes());
        }
        IngestedEvent::DepositInitiated {
            depositor,
            resource_id,
            token,
            amount,
            depositor_nonce,
            receipt_hash,
            block_number,
            tx_hash,
            log_index,
        } => {
            out.push(EVENT_TAG_DEPOSIT_INITIATED);
            out.extend_from_slice(&block_number.to_be_bytes());
            out.extend_from_slice(tx_hash);
            out.extend_from_slice(&log_index.to_be_bytes());
            out.extend_from_slice(depositor.as_bytes());
            out.extend_from_slice(&resource_id.to_be_bytes());
            out.extend_from_slice(token.as_bytes());
            out.extend_from_slice(amount);
            out.extend_from_slice(&depositor_nonce.to_be_bytes());
            out.extend_from_slice(receipt_hash);
        }
        IngestedEvent::DepositWithFeeInitiated {
            sender,
            resource_id,
            token,
            user_amount,
            pool_amount,
            budget_grant,
            depositor_nonce,
            receipt_hash,
            block_number,
            tx_hash,
            log_index,
        } => {
            out.push(EVENT_TAG_DEPOSIT_WITH_FEE);
            out.extend_from_slice(&block_number.to_be_bytes());
            out.extend_from_slice(tx_hash);
            out.extend_from_slice(&log_index.to_be_bytes());
            out.extend_from_slice(sender.as_bytes());
            out.extend_from_slice(&resource_id.to_be_bytes());
            out.extend_from_slice(token.as_bytes());
            out.extend_from_slice(user_amount);
            out.extend_from_slice(pool_amount);
            out.extend_from_slice(&budget_grant.to_be_bytes());
            out.extend_from_slice(&depositor_nonce.to_be_bytes());
            out.extend_from_slice(receipt_hash);
        }
    }
    // Address book.
    let book_len = u64::try_from(input.address_book.len()).map_err(|_| {
        FixtureError::Overflow(format!("address book len {}", input.address_book.len()))
    })?;
    out.extend_from_slice(&book_len.to_be_bytes());
    for (addr, id) in &input.address_book {
        out.extend_from_slice(addr.as_bytes());
        out.extend_from_slice(&id.to_be_bytes());
    }
    // Current nonce (16 bytes BE).
    out.extend_from_slice(&input.current_nonce.to_be_bytes());
    Ok(out)
}

/// Decode a `FixtureInput` from a byte stream.
///
/// # Errors
///
/// Returns `FixtureError::UnexpectedEnd` if the stream is too
/// short; `FixtureError::UnknownEventTag` if the leading byte
/// doesn't match a known event; `FixtureError::Overflow` if
/// the address-book length field exceeds
/// [`MAX_DECODED_ADDRESS_BOOK_ENTRIES`].
pub fn decode_input(bytes: &[u8]) -> Result<FixtureInput, FixtureError> {
    let mut cursor = 0usize;
    let event = decode_event(bytes, &mut cursor)?;
    let book_len_u64 = read_u64_be(bytes, &mut cursor)?;
    // Defence against an attacker-controlled fixture claiming a
    // huge `book_len`: bound the address-book length BEFORE
    // calling `Vec::with_capacity`, which would otherwise abort
    // the process on allocation failure.  One million addresses
    // is well above any realistic deployment's bridge actor
    // count (production Ethereum bridges typically have ≤ 10k
    // registered identities).
    if book_len_u64 > MAX_DECODED_ADDRESS_BOOK_ENTRIES as u64 {
        return Err(FixtureError::Overflow(format!(
            "decoded address-book length {book_len_u64} exceeds bound \
             {MAX_DECODED_ADDRESS_BOOK_ENTRIES}",
        )));
    }
    // Additional defence: refuse to allocate beyond what the
    // remaining input could possibly populate.  Each entry is at
    // least 28 bytes (20-byte address + 8-byte id); if the
    // remaining buffer can't hold them, refuse early.
    let remaining = bytes.len().saturating_sub(cursor);
    let max_entries_from_input = remaining / 28;
    let book_len = (book_len_u64 as usize).min(max_entries_from_input);
    let mut address_book = Vec::with_capacity(book_len);
    // But we still need to consume EXACTLY `book_len_u64`
    // entries from the stream (the input might have padding /
    // we're not the only consumer).  Use the u64 value, not
    // the bounded one, so a too-large entry count surfaces as
    // UnexpectedEnd rather than silently truncating.
    for _ in 0..book_len_u64 {
        let addr_bytes = read_bytes(bytes, &mut cursor, 20)?;
        let mut addr = [0u8; 20];
        addr.copy_from_slice(addr_bytes);
        let id = read_u64_be(bytes, &mut cursor)?;
        address_book.push((EthAddress(addr), id));
    }
    let current_nonce = read_u128_be(bytes, &mut cursor)?;
    Ok(FixtureInput {
        event,
        address_book,
        current_nonce,
    })
}

fn decode_event(bytes: &[u8], cursor: &mut usize) -> Result<IngestedEvent, FixtureError> {
    let tag_offset = *cursor;
    let tag = *bytes
        .get(tag_offset)
        .ok_or(FixtureError::UnexpectedEnd { offset: tag_offset })?;
    *cursor += 1;
    // Validate the tag before consuming the metadata fields so
    // that "unknown tag" is distinguishable from "valid tag but
    // truncated payload" in the error report.
    if !matches!(
        tag,
        EVENT_TAG_REGISTERED_ECDSA
            | EVENT_TAG_REGISTERED_EIP1271
            | EVENT_TAG_REVOKED
            | EVENT_TAG_DEPOSIT_INITIATED
            | EVENT_TAG_DEPOSIT_WITH_FEE
    ) {
        return Err(FixtureError::UnknownEventTag {
            tag,
            offset: tag_offset,
        });
    }
    let block_number = read_u64_be(bytes, cursor)?;
    let mut tx_hash = [0u8; 32];
    tx_hash.copy_from_slice(read_bytes(bytes, cursor, 32)?);
    let log_index = read_u64_be(bytes, cursor)?;
    match tag {
        EVENT_TAG_REGISTERED_ECDSA => {
            let mut actor = [0u8; 20];
            actor.copy_from_slice(read_bytes(bytes, cursor, 20)?);
            let pubkey_len = read_u32_be(bytes, cursor)? as usize;
            let pubkey = read_bytes(bytes, cursor, pubkey_len)?.to_vec();
            Ok(IngestedEvent::RegisteredEcdsa {
                actor: EthAddress(actor),
                pubkey,
                block_number,
                tx_hash,
                log_index,
            })
        }
        EVENT_TAG_REGISTERED_EIP1271 => {
            let mut actor = [0u8; 20];
            actor.copy_from_slice(read_bytes(bytes, cursor, 20)?);
            let mut contract = [0u8; 20];
            contract.copy_from_slice(read_bytes(bytes, cursor, 20)?);
            Ok(IngestedEvent::RegisteredEip1271 {
                actor: EthAddress(actor),
                contract_signer: EthAddress(contract),
                block_number,
                tx_hash,
                log_index,
            })
        }
        EVENT_TAG_REVOKED => {
            let mut actor = [0u8; 20];
            actor.copy_from_slice(read_bytes(bytes, cursor, 20)?);
            Ok(IngestedEvent::Revoked {
                actor: EthAddress(actor),
                block_number,
                tx_hash,
                log_index,
            })
        }
        EVENT_TAG_DEPOSIT_INITIATED => {
            let mut depositor = [0u8; 20];
            depositor.copy_from_slice(read_bytes(bytes, cursor, 20)?);
            let resource_id = read_u64_be(bytes, cursor)?;
            let mut token = [0u8; 20];
            token.copy_from_slice(read_bytes(bytes, cursor, 20)?);
            let mut amount = [0u8; 32];
            amount.copy_from_slice(read_bytes(bytes, cursor, 32)?);
            let depositor_nonce = read_u64_be(bytes, cursor)?;
            let mut receipt_hash = [0u8; 32];
            receipt_hash.copy_from_slice(read_bytes(bytes, cursor, 32)?);
            Ok(IngestedEvent::DepositInitiated {
                depositor: EthAddress(depositor),
                resource_id,
                token: EthAddress(token),
                amount,
                depositor_nonce,
                receipt_hash,
                block_number,
                tx_hash,
                log_index,
            })
        }
        EVENT_TAG_DEPOSIT_WITH_FEE => {
            let mut sender = [0u8; 20];
            sender.copy_from_slice(read_bytes(bytes, cursor, 20)?);
            let resource_id = read_u64_be(bytes, cursor)?;
            let mut token = [0u8; 20];
            token.copy_from_slice(read_bytes(bytes, cursor, 20)?);
            let mut user_amount = [0u8; 32];
            user_amount.copy_from_slice(read_bytes(bytes, cursor, 32)?);
            let mut pool_amount = [0u8; 32];
            pool_amount.copy_from_slice(read_bytes(bytes, cursor, 32)?);
            let budget_grant = read_u64_be(bytes, cursor)?;
            let depositor_nonce = read_u64_be(bytes, cursor)?;
            let mut receipt_hash = [0u8; 32];
            receipt_hash.copy_from_slice(read_bytes(bytes, cursor, 32)?);
            Ok(IngestedEvent::DepositWithFeeInitiated {
                sender: EthAddress(sender),
                resource_id,
                token: EthAddress(token),
                user_amount,
                pool_amount,
                budget_grant,
                depositor_nonce,
                receipt_hash,
                block_number,
                tx_hash,
                log_index,
            })
        }
        // Unreachable: the tag was validated against the five
        // recognised values at the top of this function.
        _ => unreachable!("unreachable: invalid tag {tag} reached match after validation"),
    }
}

fn read_u32_be(bytes: &[u8], cursor: &mut usize) -> Result<u32, FixtureError> {
    let raw = read_bytes(bytes, cursor, 4)?;
    let mut buf = [0u8; 4];
    buf.copy_from_slice(raw);
    Ok(u32::from_be_bytes(buf))
}

fn read_u64_be(bytes: &[u8], cursor: &mut usize) -> Result<u64, FixtureError> {
    let raw = read_bytes(bytes, cursor, 8)?;
    let mut buf = [0u8; 8];
    buf.copy_from_slice(raw);
    Ok(u64::from_be_bytes(buf))
}

fn read_u128_be(bytes: &[u8], cursor: &mut usize) -> Result<u128, FixtureError> {
    let raw = read_bytes(bytes, cursor, 16)?;
    let mut buf = [0u8; 16];
    buf.copy_from_slice(raw);
    Ok(u128::from_be_bytes(buf))
}

fn read_bytes<'a>(
    bytes: &'a [u8],
    cursor: &mut usize,
    len: usize,
) -> Result<&'a [u8], FixtureError> {
    let start = *cursor;
    let end = start
        .checked_add(len)
        .ok_or(FixtureError::UnexpectedEnd { offset: start })?;
    if end > bytes.len() {
        return Err(FixtureError::UnexpectedEnd { offset: start });
    }
    *cursor = end;
    Ok(&bytes[start..end])
}

/// The expected output of `translation::ingest` for a fixture
/// input.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FixtureExpected {
    /// `ingest` returned `None`.  Encoded as a single `0` byte.
    None,
    /// `ingest` returned `Some(UnsignedAction)`.  Encoded as
    /// `1` byte followed by the CBE encoding of the underlying
    /// Action plus the signer/nonce.
    Some {
        /// The CBE bytes of the produced Action.
        action_bytes: Vec<u8>,
        /// The signer ActorId.
        signer: u64,
        /// The nonce.
        nonce: u128,
    },
}

/// Encode a `FixtureExpected`.  Deterministic; the exact bytes
/// are what the cross-stack consumer byte-compares against the
/// Lean reference.
///
/// # Errors
///
/// Propagates `EncodeError` from the underlying `encode_action`
/// call.
pub fn encode_expected(
    expected: &Option<UnsignedAction>,
) -> Result<Vec<u8>, crate::encoding::EncodeError> {
    match expected {
        None => Ok(vec![0]),
        Some(unsigned) => {
            let mut out = vec![1];
            let action_bytes = crate::encoding::encode_action(&unsigned.action)?;
            let len = u32::try_from(action_bytes.len()).map_err(|_| {
                crate::encoding::EncodeError::LengthExceedsBound {
                    len: action_bytes.len(),
                }
            })?;
            out.extend_from_slice(&len.to_be_bytes());
            out.extend_from_slice(&action_bytes);
            out.extend_from_slice(&unsigned.signer.to_be_bytes());
            out.extend_from_slice(&unsigned.nonce.to_be_bytes());
            Ok(out)
        }
    }
}

/// One Workstream-GP fee-split fixture input.  Carries the L1
/// inputs to `KnomosisBridge.depositETHWithFee` /
/// `depositBoldWithFee`, plus the L2-side action-field placements
/// (`recipient`, `pool_actor`, `deposit_id`) that the kernel-layer
/// admission produces.  The expected output is the CBE-encoded
/// `Action::DepositWithFee` bytes for the derived split.
///
/// ## On-disk layout (deterministic, byte-stable)
///
/// ```text
///   offset    size   field
///   0         16     msg_value (u128 BE; the user's `msg.value` deposit)
///   16        2      chosen_fee_bps (u16 BE; the user-chosen fee in bps)
///   18        8      wei_per_budget_unit (u64 BE; deployment-set rate)
///   26        8      r / resource_id (u64 BE; 0 = ETH, 1 = BOLD)
///   34        8      recipient (u64 BE)
///   42        8      pool_actor (u64 BE)
///   50        8      deposit_id (u64 BE)
/// ```
///
/// Total: 58 bytes.  The decoder rejects truncated input via the
/// typed `FixtureError::UnexpectedEnd`.
///
/// ## Mathematical contract
///
/// Given `(msg_value, chosen_fee_bps, wei_per_budget_unit)`, the
/// fee-split arithmetic is:
///
/// ```text
///   pool_amount  = floor(msg_value * chosen_fee_bps / 10000)
///   user_amount  = msg_value - pool_amount
///   raw_budget   = floor(pool_amount / wei_per_budget_unit)
///   budget_grant = min(raw_budget, MAX_BUDGET_PER_DEPOSIT)
/// ```
///
/// where `MAX_BUDGET_PER_DEPOSIT = 10^12`.  The expected CBE bytes
/// are produced by `encode_action(Action::DepositWithFee { r,
/// recipient, pool_actor, user_amount, pool_amount, budget_grant,
/// deposit_id })`.  Mathematical soundness (mirrored from Lean's
/// `feeSplit_conserves` / `feeSplit_pool_le` /
/// `feeSplit_budget_le_max`):
///
///   * `user_amount + pool_amount = msg_value` exactly
///     (conservation; load-bearing for the L1 contract's
///     `userAmount + poolAmount == msg.value` invariant).
///   * `pool_amount <= msg_value` (consequence of
///     `chosen_fee_bps <= 10000`).
///   * `budget_grant <= MAX_BUDGET_PER_DEPOSIT`.
///
/// **Bound contract.**  `user_amount` and `pool_amount` must each
/// fit in `u64` for the CBE encoder to not lose precision (the
/// Lean side's `Action.fieldsBounded` requires
/// `userAmount < 2^64 ∧ poolAmount < 2^64`).  In practice that
/// caps `msg_value` at slightly above 10^19 wei (~ 18 ETH).  The
/// fixture corpus uses a max `msg_value` of `10^18` (1 ETH); a
/// `msg_value` near `2^64` is included for boundary coverage.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FeeSplitInput {
    /// The L1 `msg.value` deposit amount in wei.
    pub msg_value: u128,
    /// The user-chosen fee in basis points (`<= maxFeeBps <= 5000`
    /// per the L1 contract).
    pub chosen_fee_bps: u16,
    /// The deployment-set exchange rate (wei per budget unit).
    pub wei_per_budget_unit: u64,
    /// The Knomosis resource id (`0` = native ETH, `1` = BOLD,
    /// other = deployment-managed token).
    pub resource_id: u64,
    /// The L2 actor receiving the user-facing credit.
    pub recipient: u64,
    /// The gas-pool actor receiving the pool credit.
    pub pool_actor: u64,
    /// The L1 per-depositor deposit id.
    pub deposit_id: u64,
}

/// Per-deposit budget-grant ceiling.  Mirrors
/// `KnomosisBridge.MAX_BUDGET_PER_DEPOSIT` and the Lean side's
/// `LegalKernel.Test.Bridge.CrossCheck.DepositFeeSplit.maxBudgetPerDeposit`.
/// Changing this is a constitutional amendment per GP.5.2 (the
/// fee-split-cap audit gate); the value is also pinned at the
/// Solidity layer.
pub const MAX_BUDGET_PER_DEPOSIT: u64 = 1_000_000_000_000;

/// The encoded length of a `FeeSplitInput`: a fixed 58 bytes
/// regardless of the values stored.
pub const FEE_SPLIT_INPUT_BYTES: usize = 58;

/// Compile-time guard: the declared on-disk width MUST equal the
/// sum of the field widths the encoder writes (16-byte msg_value +
/// 2-byte fee_bps + 8 × 5 for the four u64s + resource + the two
/// L2 ids + deposit_id).  A future field-width change that forgets
/// to update `FEE_SPLIT_INPUT_BYTES` fails the build here rather
/// than silently corrupting the wire format.
const _: () = assert!(
    16 + 2 + 8 + 8 + 8 + 8 + 8 == FEE_SPLIT_INPUT_BYTES,
    "FeeSplitInput field widths must sum to FEE_SPLIT_INPUT_BYTES"
);

impl FeeSplitInput {
    /// Compute the derived `(user_amount, pool_amount, budget_grant)`
    /// triple from the inputs.  Mirrors the L1 contract's split
    /// arithmetic exactly: `pool = floor(value * bps / 10000)`,
    /// `user = value - pool`, `raw = floor(pool / weiPerUnit)`,
    /// `budget = min(raw, MAX_BUDGET_PER_DEPOSIT)`.
    ///
    /// **Determinism.**  Floor division and saturating-subtraction-
    /// via-non-overflow path produce identical results across
    /// implementations.  The conservation property
    /// `user_amount + pool_amount = msg_value` holds for every
    /// `chosen_fee_bps <= 10000` (proven by Lean's
    /// `feeSplit_conserves`).
    ///
    /// **Faithful domain vs. Lean.**  Lean's `feeSplit` computes
    /// `pool = (v * feeBps) / 10000` over UNBOUNDED `Nat`, so its
    /// multiply is always exact.  In `u128` the multiply is exact
    /// for every *encodable* deposit: a `DepositWithFee` Action
    /// requires `user, pool < 2^64`, hence `msg_value < 2^65`,
    /// hence `msg_value * chosen_fee_bps < 2^65 * 2^16 = 2^81`,
    /// which is far below `u128::MAX` (`~2^128`).  So within the
    /// domain that can ever produce an Action, this function is
    /// byte-identical to Lean.  For `msg_value` so large the
    /// multiply WOULD overflow `u128` (far beyond any encodable
    /// deposit), the `checked_mul` `None` arm surfaces a
    /// `pool_amount >= 2^64`, which [`Self::to_action`] rejects —
    /// such an input is REJECTED, never silently mis-encoded, and
    /// the function never panics (load-bearing because
    /// `decode_fee_split_input` can read an arbitrary `msg_value`
    /// from a corrupt fixture).
    ///
    /// **Bound contract.**  This function does NOT enforce
    /// `user_amount < 2^64` / `pool_amount < 2^64`.  Callers feeding
    /// the result to `encode_action` are responsible for ensuring
    /// the values fit; the encoder returns
    /// `EncodeError::FieldExceedsBound` on out-of-range inputs, and
    /// [`Self::to_action`] performs the bound check up front.
    #[must_use]
    pub fn split(self) -> (u128, u128, u64) {
        // pool = floor(value * bps / 10000).  Use `checked_mul` so
        // the overflow branch is explicit rather than relying on a
        // comment to justify a `saturating_mul`.  The `None` arm is
        // unreachable for any input that could yield an encodable
        // Action (see the "Faithful domain" doc above); when it is
        // reached we return a `pool >= 2^64` so `to_action` rejects
        // the input rather than mis-encoding it.
        let pool_amount = match self.msg_value.checked_mul(u128::from(self.chosen_fee_bps)) {
            Some(product) => product / 10000,
            // Out-of-domain: `>= 2^64`, forcing `to_action` to reject.
            None => u128::MAX / 10000,
        };
        // user = value - pool.  This is the EXACT mirror of Lean's
        // `Nat` subtraction, which is TRUNCATED (`a - b = 0` when
        // `b > a`): `saturating_sub` gives the same `0` floor.  For
        // the validated range `bps <= 10000` we always have `pool <=
        // value` (no overflow), so the subtraction is exact; for a
        // pathological `bps > 10000` both Lean and this mirror
        // truncate to 0 identically.
        let user_amount = self.msg_value.saturating_sub(pool_amount);
        // budget = min(floor(pool / weiPerUnit), MAX).  Use `u128`
        // division so the divisor (u64) is widened; the result fits
        // in u128.  Then cap at MAX and downcast to u64.
        let raw_budget = if self.wei_per_budget_unit == 0 {
            // Mirror Lean's `Nat.div_zero` (`n / 0 = 0`) EXACTLY.
            // Rust's `/` panics on a zero divisor, so we must guard,
            // but the guard MUST return 0 — not the cap — to stay
            // byte-equivalent with the Lean reference `feeSplit`,
            // whose `rawBudget := poolAmount / weiPerBudgetUnit`
            // evaluates to 0 when `weiPerBudgetUnit = 0`.  (The case
            // is unreachable on realistic deployments: the L1
            // constructor enforces `weiPerBudgetUnit >=
            // MIN_WEI_PER_BUDGET_UNIT = 1`.  We mirror Lean rather
            // than panic so a malformed input degrades gracefully and
            // identically on both stacks.)
            0u128
        } else {
            pool_amount / u128::from(self.wei_per_budget_unit)
        };
        let budget_grant = raw_budget.min(u128::from(MAX_BUDGET_PER_DEPOSIT));
        // `budget_grant <= MAX_BUDGET_PER_DEPOSIT <= u64::MAX` so
        // the downcast cannot truncate.
        #[allow(clippy::cast_possible_truncation)] // bound-checked above
        let budget_grant = budget_grant as u64;
        (user_amount, pool_amount, budget_grant)
    }

    /// The universal fee-bps admissibility ceiling.  A fee at or
    /// below this conserves the deposit (`pool <= msg_value`); above
    /// it, the pool leg would exceed `msg_value`.  Matches Lean's
    /// `feeSplit_conserves` hypothesis (`feeBps <= 10000`).  The L1
    /// contract enforces the stricter `chosenFeeBps <= maxFeeBps <=
    /// 5000`.
    pub const MAX_ADMISSIBLE_FEE_BPS: u16 = 10000;

    /// Build the corresponding `Action::DepositWithFee` constructor
    /// for the input.  Returns `None` when the input cannot yield a
    /// well-formed, value-conserving Action:
    ///
    ///   * `chosen_fee_bps > MAX_ADMISSIBLE_FEE_BPS` (10000) — the
    ///     pool leg `(v * bps)/10000` would exceed `msg_value`, and
    ///     the truncating user leg collapses to 0, so the Action
    ///     would credit MORE than the deposit (a violation of the GP
    ///     fee-split conservation invariant `userAmount + poolAmount
    ///     == msg.value`).  The L1 contract rejects such a deposit
    ///     (`chosenFeeBps <= maxFeeBps <= 5000`); this mirrors that
    ///     guard so the `pub` helper can never construct a
    ///     fund-creating Action from an arbitrary decoded payload.
    ///   * `user_amount >= 2^64` or `pool_amount >= 2^64` — exceeds
    ///     the Lean-side `Action.fieldsBounded` encoder bound.
    ///     Production deployments prevent this via the L1 TVL cap.
    ///
    /// Note: the rejection lives HERE, not in [`Self::split`].
    /// `split` stays byte-faithful to Lean's `feeSplit` for ALL
    /// inputs (including the truncating `bps > 10000` case); only
    /// the Action *constructor* enforces conservation, because only
    /// an emitted Action can mis-credit funds.
    #[must_use]
    pub fn to_action(self) -> Option<crate::action::Action> {
        // Conservation gate: reject a non-conservative fee before
        // building any Action bytes.
        if self.chosen_fee_bps > Self::MAX_ADMISSIBLE_FEE_BPS {
            return None;
        }
        let (user_amount, pool_amount, budget_grant) = self.split();
        // Both amounts must fit in u64 (the Lean encoder's bound).
        if user_amount >= 1u128 << 64 || pool_amount >= 1u128 << 64 {
            return None;
        }
        Some(crate::action::Action::DepositWithFee {
            r: self.resource_id,
            recipient: self.recipient,
            pool_actor: self.pool_actor,
            user_amount,
            pool_amount,
            budget_grant,
            deposit_id: self.deposit_id,
        })
    }
}

/// Encode a `FeeSplitInput` to the canonical 58-byte form.  The
/// layout is documented on [`FeeSplitInput`].
#[must_use]
pub fn encode_fee_split_input(input: &FeeSplitInput) -> Vec<u8> {
    let mut out = Vec::with_capacity(FEE_SPLIT_INPUT_BYTES);
    out.extend_from_slice(&input.msg_value.to_be_bytes()); // 16 bytes
    out.extend_from_slice(&input.chosen_fee_bps.to_be_bytes()); // 2 bytes
    out.extend_from_slice(&input.wei_per_budget_unit.to_be_bytes()); // 8 bytes
    out.extend_from_slice(&input.resource_id.to_be_bytes()); // 8 bytes
    out.extend_from_slice(&input.recipient.to_be_bytes()); // 8 bytes
    out.extend_from_slice(&input.pool_actor.to_be_bytes()); // 8 bytes
    out.extend_from_slice(&input.deposit_id.to_be_bytes()); // 8 bytes
    debug_assert_eq!(out.len(), FEE_SPLIT_INPUT_BYTES);
    out
}

/// Decode a `FeeSplitInput` from the canonical 58-byte form.
///
/// **Strict length contract.**  The decoder requires the input
/// to be EXACTLY `FEE_SPLIT_INPUT_BYTES` bytes — not just "at least
/// that many".  A producer that emits an oversized payload is a
/// schema-drift bug, surfaced here as `FixtureError::TrailingBytes`
/// rather than silently truncated.  (For dynamic-length payloads
/// like `decode_input` the contract is necessarily looser; this
/// shape is fixed-width so strict equality is the correct
/// invariant.)
///
/// # Errors
///
/// Returns `FixtureError::UnexpectedEnd` if the input is too short,
/// `FixtureError::TrailingBytes` if the input is longer than the
/// canonical fixed-width payload.
pub fn decode_fee_split_input(bytes: &[u8]) -> Result<FeeSplitInput, FixtureError> {
    if bytes.len() < FEE_SPLIT_INPUT_BYTES {
        return Err(FixtureError::UnexpectedEnd {
            offset: bytes.len(),
        });
    }
    if bytes.len() > FEE_SPLIT_INPUT_BYTES {
        return Err(FixtureError::TrailingBytes {
            consumed: FEE_SPLIT_INPUT_BYTES,
            total: bytes.len(),
        });
    }
    let mut buf16 = [0u8; 16];
    buf16.copy_from_slice(&bytes[0..16]);
    let msg_value = u128::from_be_bytes(buf16);
    let mut buf2 = [0u8; 2];
    buf2.copy_from_slice(&bytes[16..18]);
    let chosen_fee_bps = u16::from_be_bytes(buf2);
    let mut buf8 = [0u8; 8];
    buf8.copy_from_slice(&bytes[18..26]);
    let wei_per_budget_unit = u64::from_be_bytes(buf8);
    buf8.copy_from_slice(&bytes[26..34]);
    let resource_id = u64::from_be_bytes(buf8);
    buf8.copy_from_slice(&bytes[34..42]);
    let recipient = u64::from_be_bytes(buf8);
    buf8.copy_from_slice(&bytes[42..50]);
    let pool_actor = u64::from_be_bytes(buf8);
    buf8.copy_from_slice(&bytes[50..58]);
    let deposit_id = u64::from_be_bytes(buf8);
    Ok(FeeSplitInput {
        msg_value,
        chosen_fee_bps,
        wei_per_budget_unit,
        resource_id,
        recipient,
        pool_actor,
        deposit_id,
    })
}

/// Decode a `FixtureExpected` from bytes.
///
/// # Errors
///
/// Returns `FixtureError::UnexpectedEnd` on truncated input,
/// `FixtureError::UnknownEventTag` on unrecognised discriminant
/// (1 = Some, 0 = None).
pub fn decode_expected(bytes: &[u8]) -> Result<FixtureExpected, FixtureError> {
    let mut cursor = 0usize;
    let tag = *bytes
        .first()
        .ok_or(FixtureError::UnexpectedEnd { offset: 0 })?;
    cursor += 1;
    match tag {
        0 => Ok(FixtureExpected::None),
        1 => {
            let len = read_u32_be(bytes, &mut cursor)? as usize;
            let action_bytes = read_bytes(bytes, &mut cursor, len)?.to_vec();
            let signer = read_u64_be(bytes, &mut cursor)?;
            let nonce = read_u128_be(bytes, &mut cursor)?;
            Ok(FixtureExpected::Some {
                action_bytes,
                signer,
                nonce,
            })
        }
        other => Err(FixtureError::UnknownEventTag {
            tag: other,
            offset: 0,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        decode_expected, decode_input, encode_expected, encode_input, FixtureError,
        FixtureExpected, FixtureInput,
    };
    use crate::action::{Action, EthAddress, PublicKey};
    use crate::events::IngestedEvent;
    use crate::translation::UnsignedAction;

    fn sample_registered_ecdsa() -> IngestedEvent {
        IngestedEvent::RegisteredEcdsa {
            actor: EthAddress::from_bytes(&[0xaa; 20]).unwrap(),
            pubkey: vec![0x02, 0xab, 0xcd],
            block_number: 100,
            tx_hash: [0x77; 32],
            log_index: 5,
        }
    }

    /// `RegisteredEcdsa` input round-trips byte-for-byte.
    #[test]
    fn registered_ecdsa_round_trip() {
        let input = FixtureInput {
            event: sample_registered_ecdsa(),
            address_book: vec![],
            current_nonce: 0,
        };
        let encoded = encode_input(&input).unwrap();
        let decoded = decode_input(&encoded).unwrap();
        assert_eq!(decoded, input);
    }

    /// `Revoked` input round-trips.
    #[test]
    fn revoked_round_trip() {
        let input = FixtureInput {
            event: IngestedEvent::Revoked {
                actor: EthAddress::from_bytes(&[0xbb; 20]).unwrap(),
                block_number: 200,
                tx_hash: [0x99; 32],
                log_index: 3,
            },
            address_book: vec![
                (EthAddress::from_bytes(&[0x01; 20]).unwrap(), 1),
                (EthAddress::from_bytes(&[0x02; 20]).unwrap(), 2),
            ],
            current_nonce: 42,
        };
        let encoded = encode_input(&input).unwrap();
        let decoded = decode_input(&encoded).unwrap();
        assert_eq!(decoded, input);
    }

    /// `DepositInitiated` input round-trips.
    #[test]
    fn deposit_initiated_round_trip() {
        let input = FixtureInput {
            event: IngestedEvent::DepositInitiated {
                depositor: EthAddress::from_bytes(&[0xcc; 20]).unwrap(),
                resource_id: 7,
                token: EthAddress::from_bytes(&[0xdd; 20]).unwrap(),
                amount: [0xee; 32],
                depositor_nonce: 13,
                receipt_hash: [0xff; 32],
                block_number: 300,
                tx_hash: [0x12; 32],
                log_index: 0,
            },
            address_book: vec![],
            current_nonce: 1000,
        };
        let encoded = encode_input(&input).unwrap();
        let decoded = decode_input(&encoded).unwrap();
        assert_eq!(decoded, input);
    }

    /// `DepositWithFeeInitiated` input round-trips (GP.5.1).
    #[test]
    fn deposit_with_fee_round_trip() {
        let input = FixtureInput {
            event: IngestedEvent::DepositWithFeeInitiated {
                sender: EthAddress::from_bytes(&[0xcc; 20]).unwrap(),
                resource_id: 7,
                token: EthAddress::from_bytes(&[0xdd; 20]).unwrap(),
                user_amount: [0xee; 32],
                pool_amount: [0x77; 32],
                budget_grant: 123_456,
                depositor_nonce: 13,
                receipt_hash: [0xff; 32],
                block_number: 300,
                tx_hash: [0x12; 32],
                log_index: 0,
            },
            address_book: vec![(EthAddress::from_bytes(&[0x01; 20]).unwrap(), 1)],
            current_nonce: 1000,
        };
        let encoded = encode_input(&input).unwrap();
        let decoded = decode_input(&encoded).unwrap();
        assert_eq!(decoded, input);
    }

    /// `RegisteredEip1271` input round-trips.
    #[test]
    fn registered_eip1271_round_trip() {
        let input = FixtureInput {
            event: IngestedEvent::RegisteredEip1271 {
                actor: EthAddress::from_bytes(&[0x11; 20]).unwrap(),
                contract_signer: EthAddress::from_bytes(&[0x22; 20]).unwrap(),
                block_number: 400,
                tx_hash: [0x33; 32],
                log_index: 1,
            },
            address_book: vec![(EthAddress::from_bytes(&[0xab; 20]).unwrap(), 1)],
            current_nonce: 7,
        };
        let encoded = encode_input(&input).unwrap();
        let decoded = decode_input(&encoded).unwrap();
        assert_eq!(decoded, input);
    }

    /// Truncated input returns `UnexpectedEnd`.
    #[test]
    fn truncated_input_returns_unexpected_end() {
        let input = FixtureInput {
            event: sample_registered_ecdsa(),
            address_book: vec![],
            current_nonce: 0,
        };
        let mut encoded = encode_input(&input).unwrap();
        encoded.truncate(encoded.len() - 1);
        assert!(matches!(
            decode_input(&encoded),
            Err(FixtureError::UnexpectedEnd { .. })
        ));
    }

    /// Unknown event tag returns `UnknownEventTag`.
    #[test]
    fn unknown_event_tag_returns_error() {
        let bytes = vec![0xff, 0, 0, 0, 0, 0, 0, 0, 0];
        assert!(matches!(
            decode_input(&bytes),
            Err(FixtureError::UnknownEventTag { tag: 0xff, .. })
        ));
    }

    /// `FixtureExpected::None` round-trips.
    #[test]
    fn expected_none_round_trip() {
        let encoded = encode_expected(&None).unwrap();
        assert_eq!(encoded, vec![0]);
        let decoded = decode_expected(&encoded).unwrap();
        assert_eq!(decoded, FixtureExpected::None);
    }

    /// `FixtureExpected::Some` round-trips.
    #[test]
    fn expected_some_round_trip() {
        let unsigned = UnsignedAction {
            action: Action::RegisterIdentity {
                actor: 1,
                pk: PublicKey::from_bytes(&[0xab, 0xcd]),
            },
            signer: 0,
            nonce: 7,
        };
        let encoded = encode_expected(&Some(unsigned.clone())).unwrap();
        // 1-byte discriminant + 4-byte len + N action bytes + 8-byte signer + 16-byte nonce.
        assert_eq!(encoded[0], 1);
        let decoded = decode_expected(&encoded).unwrap();
        match decoded {
            FixtureExpected::Some {
                action_bytes,
                signer,
                nonce,
            } => {
                assert_eq!(
                    action_bytes,
                    crate::encoding::encode_action(&unsigned.action).unwrap()
                );
                assert_eq!(signer, 0);
                assert_eq!(nonce, 7);
            }
            _ => panic!("expected Some variant"),
        }
    }

    /// Deterministic encoding: same input twice produces same bytes.
    #[test]
    fn encoding_deterministic() {
        let input = FixtureInput {
            event: sample_registered_ecdsa(),
            address_book: vec![(EthAddress::from_bytes(&[0xab; 20]).unwrap(), 1)],
            current_nonce: 7,
        };
        let e1 = encode_input(&input).unwrap();
        let e2 = encode_input(&input).unwrap();
        assert_eq!(e1, e2);
    }

    /// REGRESSION: decoder rejects unreasonably large
    /// address-book lengths to defend against memory-exhaustion
    /// attacks via crafted fixtures.  The pre-fix decoder would
    /// blindly call `Vec::with_capacity` with the attacker-
    /// supplied value and abort on allocation failure.
    #[test]
    fn decode_input_rejects_huge_address_book_length() {
        // Build a minimal valid `RegisteredEcdsa` prefix, then
        // a fabricated address-book length of u64::MAX.
        let mut bytes = Vec::new();
        bytes.push(super::EVENT_TAG_REGISTERED_ECDSA);
        bytes.extend_from_slice(&0u64.to_be_bytes()); // block_number
        bytes.extend_from_slice(&[0x00; 32]); // tx_hash
        bytes.extend_from_slice(&0u64.to_be_bytes()); // log_index
        bytes.extend_from_slice(&[0x00; 20]); // actor
        bytes.extend_from_slice(&0u32.to_be_bytes()); // pubkey_len (0)
                                                      // Now the address-book length: a malicious u64::MAX.
        bytes.extend_from_slice(&u64::MAX.to_be_bytes());
        let result = decode_input(&bytes);
        match result {
            Err(FixtureError::Overflow(msg)) => {
                assert!(
                    msg.contains("address-book length"),
                    "unexpected overflow message: {msg}"
                );
            }
            other => panic!("expected Overflow, got {other:?}"),
        }
    }

    /// REGRESSION: decoder rejects address-book lengths just
    /// above the bound.
    #[test]
    fn decode_input_rejects_at_threshold() {
        let mut bytes = Vec::new();
        bytes.push(super::EVENT_TAG_REVOKED);
        bytes.extend_from_slice(&0u64.to_be_bytes()); // block_number
        bytes.extend_from_slice(&[0x00; 32]); // tx_hash
        bytes.extend_from_slice(&0u64.to_be_bytes()); // log_index
        bytes.extend_from_slice(&[0x00; 20]); // actor
                                              // book_len = MAX + 1.
        let bad_len = super::MAX_DECODED_ADDRESS_BOOK_ENTRIES as u64 + 1;
        bytes.extend_from_slice(&bad_len.to_be_bytes());
        match decode_input(&bytes) {
            Err(FixtureError::Overflow(_)) => {}
            other => panic!("expected Overflow, got {other:?}"),
        }
    }

    /// Address-book length at the boundary (MAX) is accepted in
    /// principle; the decoder fails later via UnexpectedEnd if
    /// the input is too short to actually populate that many
    /// entries (which it always will be in practice).
    #[test]
    fn decode_input_accepts_at_threshold_but_fails_on_truncation() {
        let mut bytes = Vec::new();
        bytes.push(super::EVENT_TAG_REVOKED);
        bytes.extend_from_slice(&0u64.to_be_bytes());
        bytes.extend_from_slice(&[0x00; 32]);
        bytes.extend_from_slice(&0u64.to_be_bytes());
        bytes.extend_from_slice(&[0x00; 20]);
        // book_len = MAX exactly.
        let at_bound = super::MAX_DECODED_ADDRESS_BOOK_ENTRIES as u64;
        bytes.extend_from_slice(&at_bound.to_be_bytes());
        // Insufficient data for the entries → UnexpectedEnd.
        match decode_input(&bytes) {
            Err(FixtureError::UnexpectedEnd { .. }) => {}
            other => panic!("expected UnexpectedEnd, got {other:?}"),
        }
    }

    // ============ FeeSplitInput tests (Workstream GP.6.1) ============

    /// A canonical sample input — 1 ETH deposit at 10% fee with
    /// rate 10^9 wei/budget_unit.  Reused across the tests.
    fn sample_fee_split() -> super::FeeSplitInput {
        super::FeeSplitInput {
            msg_value: 1_000_000_000_000_000_000u128, // 1 ETH = 10^18 wei
            chosen_fee_bps: 1000,                     // 10%
            wei_per_budget_unit: 1_000_000_000,       // 10^9 wei/unit
            resource_id: 0,
            recipient: 7,
            pool_actor: 2,
            deposit_id: 42,
        }
    }

    /// `encode_fee_split_input` produces exactly 58 bytes — the
    /// canonical fixed-width form.
    #[test]
    fn encode_fee_split_input_length() {
        let input = sample_fee_split();
        let encoded = super::encode_fee_split_input(&input);
        assert_eq!(encoded.len(), super::FEE_SPLIT_INPUT_BYTES);
        assert_eq!(encoded.len(), 58);
    }

    /// `FeeSplitInput` round-trips through encode/decode byte-stably.
    #[test]
    fn fee_split_input_round_trip() {
        let input = sample_fee_split();
        let encoded = super::encode_fee_split_input(&input);
        let decoded = super::decode_fee_split_input(&encoded).unwrap();
        assert_eq!(decoded, input);
    }

    /// Truncated `FeeSplitInput` bytes return `UnexpectedEnd`.
    #[test]
    fn fee_split_input_truncated_returns_unexpected_end() {
        let input = sample_fee_split();
        let mut encoded = super::encode_fee_split_input(&input);
        encoded.truncate(encoded.len() - 1);
        assert!(matches!(
            super::decode_fee_split_input(&encoded),
            Err(FixtureError::UnexpectedEnd { .. })
        ));
    }

    /// Oversized `FeeSplitInput` bytes return `TrailingBytes`.
    /// Pins the strict-length contract — a producer that emits a
    /// payload longer than 58 bytes is a schema-drift bug, NOT
    /// silently truncated.
    #[test]
    fn fee_split_input_oversized_returns_trailing_bytes() {
        let input = sample_fee_split();
        let mut encoded = super::encode_fee_split_input(&input);
        encoded.push(0xAB); // 59 bytes — one byte too long
        match super::decode_fee_split_input(&encoded) {
            Err(FixtureError::TrailingBytes { consumed, total }) => {
                assert_eq!(consumed, super::FEE_SPLIT_INPUT_BYTES);
                assert_eq!(total, super::FEE_SPLIT_INPUT_BYTES + 1);
            }
            other => panic!("expected TrailingBytes, got {other:?}"),
        }
    }

    /// Exact-length input decodes cleanly (the strict contract
    /// accepts the canonical width — the round-trip test above
    /// already exercises this, but pinning it explicitly makes the
    /// boundary regression-visible).
    #[test]
    fn fee_split_input_exact_length_decodes_cleanly() {
        let input = sample_fee_split();
        let encoded = super::encode_fee_split_input(&input);
        assert_eq!(encoded.len(), super::FEE_SPLIT_INPUT_BYTES);
        let decoded = super::decode_fee_split_input(&encoded).expect("exact width");
        assert_eq!(decoded, input);
    }

    /// `FeeSplitInput::split` produces the expected `(user, pool,
    /// budget)` triple for the canonical sample.  At 1 ETH × 10%
    /// fee × 10^9 rate: pool = 10^17 = 0.1 ETH; user = 9 × 10^17;
    /// raw_budget = 10^17 / 10^9 = 10^8; budget = min(10^8, 10^12)
    /// = 10^8.
    #[test]
    fn fee_split_canonical_sample() {
        let input = sample_fee_split();
        let (user, pool, budget) = input.split();
        assert_eq!(pool, 100_000_000_000_000_000u128); // 0.1 ETH = 10^17
        assert_eq!(user, 900_000_000_000_000_000u128); // 0.9 ETH = 9 × 10^17
        assert_eq!(budget, 100_000_000u64); // 10^8
                                            // Conservation: user + pool = msg_value.
        assert_eq!(user + pool, input.msg_value);
        // budget <= MAX.
        assert!(budget <= super::MAX_BUDGET_PER_DEPOSIT);
    }

    /// At zero fee, `pool = 0`, `user = msg_value`, `budget = 0`.
    #[test]
    fn fee_split_zero_fee() {
        let input = super::FeeSplitInput {
            chosen_fee_bps: 0,
            ..sample_fee_split()
        };
        let (user, pool, budget) = input.split();
        assert_eq!(pool, 0);
        assert_eq!(user, input.msg_value);
        assert_eq!(budget, 0);
    }

    /// At max realistic fee (5000 bps = 50%), `pool = floor(value/2)`,
    /// `user = ceil(value/2)`, and conservation holds.
    #[test]
    fn fee_split_max_fee_50_percent() {
        let input = super::FeeSplitInput {
            chosen_fee_bps: 5000,
            msg_value: 1000,
            ..sample_fee_split()
        };
        let (user, pool, _) = input.split();
        assert_eq!(pool, 500); // 1000 × 0.5 = 500
        assert_eq!(user, 500);
        assert_eq!(user + pool, input.msg_value);
    }

    /// Residue favours the user: `floor(value × bps / 10000)` rounds
    /// down, so `user_amount` gets the rounding residue.
    #[test]
    fn fee_split_residue_favours_user() {
        // msg.value = 1, bps = 100 (1%).
        //   pool = floor(1 × 100 / 10000) = floor(0.01) = 0
        //   user = 1 - 0 = 1 (whole deposit stays with user).
        let input = super::FeeSplitInput {
            msg_value: 1,
            chosen_fee_bps: 100,
            ..sample_fee_split()
        };
        let (user, pool, _) = input.split();
        assert_eq!(pool, 0);
        assert_eq!(user, 1);
    }

    /// Budget grant is clamped at `MAX_BUDGET_PER_DEPOSIT` for
    /// large pool credits with tiny exchange rates.
    #[test]
    fn fee_split_budget_clamp() {
        // pool = 10^17 wei; weiPerUnit = 1 → raw_budget = 10^17
        // → clamped at 10^12.
        let input = super::FeeSplitInput {
            wei_per_budget_unit: 1,
            ..sample_fee_split()
        };
        let (_, _, budget) = input.split();
        assert_eq!(budget, super::MAX_BUDGET_PER_DEPOSIT);
    }

    /// Conservation: `user + pool = msg_value` for any `bps <= 10000`.
    /// Tests at the boundary `bps = 10000` (the universal admissible
    /// max; the contract caps at 5000).
    #[test]
    fn fee_split_conservation_boundary() {
        let input = super::FeeSplitInput {
            msg_value: 123_456_789_012_345u128,
            chosen_fee_bps: 10000,
            ..sample_fee_split()
        };
        let (user, pool, _) = input.split();
        assert_eq!(user, 0);
        assert_eq!(pool, input.msg_value);
        assert_eq!(user + pool, input.msg_value);
    }

    /// `FeeSplitInput::to_action` produces a constructed
    /// `Action::DepositWithFee` with the right tag and fields.
    #[test]
    fn fee_split_to_action_produces_correct_constructor() {
        let input = sample_fee_split();
        let action = input.to_action().expect("in-bounds input encodes");
        match action {
            crate::action::Action::DepositWithFee {
                r,
                recipient,
                pool_actor,
                user_amount,
                pool_amount,
                budget_grant,
                deposit_id,
            } => {
                assert_eq!(r, 0);
                assert_eq!(recipient, 7);
                assert_eq!(pool_actor, 2);
                assert_eq!(deposit_id, 42);
                let (eu, ep, eb) = input.split();
                assert_eq!(user_amount, eu);
                assert_eq!(pool_amount, ep);
                assert_eq!(budget_grant, eb);
            }
            _ => panic!("expected DepositWithFee constructor"),
        }
    }

    /// `to_action` returns `None` when `user_amount >= 2^64`.
    #[test]
    fn fee_split_to_action_rejects_oversized() {
        let input = super::FeeSplitInput {
            // 10^20 wei = ~100 ETH; user_amount > 2^64
            // (since 2^64 = ~1.8 × 10^19).
            msg_value: 100_000_000_000_000_000_000u128,
            chosen_fee_bps: 0,
            ..sample_fee_split()
        };
        // user_amount = 10^20 > 2^64 → encoder bound violated.
        assert!(input.to_action().is_none());
    }

    /// REGRESSION (PR #99 review): `to_action` MUST reject a
    /// non-conservative fee (`chosen_fee_bps > 10000`).  For such an
    /// input the pool leg exceeds `msg_value` and the truncating
    /// user leg collapses to 0, so an emitted Action would credit
    /// MORE than the deposit.  `split` stays Lean-faithful (it still
    /// mirrors `feeSplit`'s truncating result); only the Action
    /// constructor enforces conservation.
    #[test]
    fn fee_split_to_action_rejects_over_max_bps() {
        let input = super::FeeSplitInput {
            msg_value: 1000,
            chosen_fee_bps: 20000, // 200% — pool would be 2000 > 1000
            wei_per_budget_unit: 1,
            resource_id: 0,
            recipient: 1,
            pool_actor: 2,
            deposit_id: 3,
        };
        // `split` remains Lean-faithful: pool = floor(1000*20000/10000)
        // = 2000, user = 1000 - 2000 = 0 (truncated, matching Lean's
        // Nat.sub) — a NON-conservative split.
        let (user, pool, _) = input.split();
        assert_eq!(pool, 2000);
        assert_eq!(user, 0);
        assert!(
            pool > input.msg_value,
            "the > 10000 bps split is non-conservative (pool > msg_value)"
        );
        // `to_action` REJECTS it — no fund-creating Action is built.
        assert!(
            input.to_action().is_none(),
            "to_action must reject chosen_fee_bps > 10000"
        );
        // Boundary: exactly 10000 is the conservative ceiling
        // (pool == msg_value, user == 0, user + pool == msg_value),
        // so it IS admitted.
        let at_bound = super::FeeSplitInput {
            chosen_fee_bps: 10000,
            ..input
        };
        let (ub, pb, _) = at_bound.split();
        assert_eq!(ub + pb, at_bound.msg_value, "10000 bps still conserves");
        assert!(
            at_bound.to_action().is_some(),
            "chosen_fee_bps == 10000 is the conservative ceiling, admitted"
        );
    }

    /// REGRESSION (audit): the multiply-overflow / saturation path
    /// must NOT panic and must NOT produce an Action.  With
    /// `msg_value = u128::MAX` and `chosen_fee_bps = u16::MAX`, the
    /// product `msg_value * chosen_fee_bps` overflows `u128`; the
    /// `checked_mul` `None` arm returns `pool >= 2^64`, so
    /// `to_action` rejects the input.  This pins the "out-of-domain
    /// input is rejected, never mis-encoded, never panics" safety —
    /// the load-bearing reason the non-Lean-faithful `u128`
    /// multiply is sound (a corrupt fixture could decode an
    /// arbitrary `msg_value`, and `split` is then called on it).
    #[test]
    fn fee_split_overflow_path_rejects_without_panic() {
        let input = super::FeeSplitInput {
            msg_value: u128::MAX,
            chosen_fee_bps: u16::MAX, // 65535 — product overflows u128
            wei_per_budget_unit: 1,
            resource_id: 0,
            recipient: 1,
            pool_actor: 2,
            deposit_id: 3,
        };
        // Must not panic.
        let (user, pool, budget) = input.split();
        // The overflow arm yields a pool >= 2^64 (so to_action rejects).
        assert!(
            pool >= 1u128 << 64,
            "overflow arm must surface pool >= 2^64"
        );
        // budget is still clamped (never exceeds the cap).
        assert!(budget <= super::MAX_BUDGET_PER_DEPOSIT);
        // user is whatever the saturating subtraction yields; the
        // only property we rely on is that to_action rejects.
        let _ = user;
        // to_action returns None — no Action is ever produced.
        assert!(
            input.to_action().is_none(),
            "saturation-range input must be rejected by to_action"
        );
    }

    /// Companion: across the entire ENCODABLE domain (`msg_value <
    /// 2^64`), the multiply never overflows, so `checked_mul`
    /// always takes the `Some` arm and the result is the exact
    /// Lean value.  Spot-check the boundary `msg_value = 2^64 - 1`
    /// at the max fee: both legs stay `< 2^64` and conserve.
    #[test]
    fn fee_split_encodable_boundary_is_exact_and_conserves() {
        let input = super::FeeSplitInput {
            msg_value: u128::from(u64::MAX), // 2^64 - 1, the encodable ceiling
            chosen_fee_bps: 5000,            // 50% — the contract's max
            wei_per_budget_unit: 1,
            resource_id: 0,
            recipient: 1,
            pool_actor: 2,
            deposit_id: 3,
        };
        let (user, pool, budget) = input.split();
        // Exact split of u64::MAX at 50%: pool = floor((2^64-1)/2),
        // user = (2^64-1) - pool.  Both < 2^64 (encodable).
        let expected_pool = (u128::from(u64::MAX) * 5000) / 10000;
        assert_eq!(pool, expected_pool);
        assert_eq!(user, u128::from(u64::MAX) - expected_pool);
        // Conservation holds exactly (no saturation occurred).
        assert_eq!(user + pool, u128::from(u64::MAX));
        // Both legs fit in u64, so this input IS encodable.
        assert!(user < (1u128 << 64) && pool < (1u128 << 64));
        assert!(input.to_action().is_some());
        // budget clamped (10^12).
        assert_eq!(budget, super::MAX_BUDGET_PER_DEPOSIT);
    }

    /// The BOLD path differs from the ETH path only in `resource_id`,
    /// not in the split arithmetic.  Identical inputs with flipped
    /// `resource_id` produce identical `(user, pool, budget)`.
    #[test]
    fn fee_split_resource_id_does_not_affect_arithmetic() {
        let eth_input = super::FeeSplitInput {
            resource_id: 0,
            ..sample_fee_split()
        };
        let bold_input = super::FeeSplitInput {
            resource_id: 1,
            ..sample_fee_split()
        };
        assert_eq!(eth_input.split(), bold_input.split());
    }

    /// `MAX_BUDGET_PER_DEPOSIT` matches the L1 contract / Lean
    /// reference constant (`10^12`).  Pins the cross-stack
    /// constitutional constant.
    #[test]
    fn max_budget_per_deposit_constitutional_pin() {
        assert_eq!(super::MAX_BUDGET_PER_DEPOSIT, 1_000_000_000_000);
        assert_eq!(super::MAX_BUDGET_PER_DEPOSIT, 10u64.pow(12));
    }

    /// Decode an explicitly-laid-out byte stream matches the
    /// in-memory representation.  Pins the wire-format byte layout
    /// against drift.
    #[test]
    fn fee_split_input_decode_explicit_bytes() {
        // Construct: msg_value = 0x01020304, chosen_fee_bps = 1000,
        // wei_per_budget_unit = 10^9, resource_id = 0, recipient = 7,
        // pool_actor = 2, deposit_id = 42.
        let mut bytes = Vec::with_capacity(58);
        // 16 bytes BE for msg_value = 0x01020304:
        bytes.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x02, 0x03, 0x04]);
        // 2 bytes BE for chosen_fee_bps = 1000 = 0x03e8:
        bytes.extend_from_slice(&[0x03, 0xe8]);
        // 8 bytes BE for wei_per_budget_unit = 10^9 = 0x3b9aca00:
        bytes.extend_from_slice(&1_000_000_000u64.to_be_bytes());
        // 8 bytes BE for resource_id = 0:
        bytes.extend_from_slice(&[0u8; 8]);
        // 8 bytes BE for recipient = 7:
        bytes.extend_from_slice(&7u64.to_be_bytes());
        // 8 bytes BE for pool_actor = 2:
        bytes.extend_from_slice(&2u64.to_be_bytes());
        // 8 bytes BE for deposit_id = 42:
        bytes.extend_from_slice(&42u64.to_be_bytes());
        assert_eq!(bytes.len(), 58);
        let decoded = super::decode_fee_split_input(&bytes).unwrap();
        assert_eq!(decoded.msg_value, 0x01020304);
        assert_eq!(decoded.chosen_fee_bps, 1000);
        assert_eq!(decoded.wei_per_budget_unit, 1_000_000_000);
        assert_eq!(decoded.resource_id, 0);
        assert_eq!(decoded.recipient, 7);
        assert_eq!(decoded.pool_actor, 2);
        assert_eq!(decoded.deposit_id, 42);
    }

    /// Encoding is deterministic: two encodings of the same input
    /// produce byte-identical output.
    #[test]
    fn fee_split_input_encoding_deterministic() {
        let input = sample_fee_split();
        let e1 = super::encode_fee_split_input(&input);
        let e2 = super::encode_fee_split_input(&input);
        assert_eq!(e1, e2);
    }

    /// Division-by-zero defence: a `wei_per_budget_unit = 0` does
    /// not panic, and the budget grant is `0` — byte-equivalent to
    /// Lean's `Nat.div_zero` (`poolAmount / 0 = 0`, then
    /// `min 0 MAX = 0`).  This is the corrected behaviour: an
    /// earlier draft returned the cap, which DIVERGED from the Lean
    /// reference (a cross-stack soundness bug).  The case is
    /// unreachable in production (the L1 constructor enforces
    /// `weiPerBudgetUnit >= 1`), but the two stacks must agree even
    /// on the pathological input.
    #[test]
    fn fee_split_division_by_zero_yields_zero_like_lean() {
        let input = super::FeeSplitInput {
            wei_per_budget_unit: 0,
            ..sample_fee_split()
        };
        // Should NOT panic, and budget MUST be 0 (Lean parity).
        let (_, _, budget) = input.split();
        assert_eq!(
            budget, 0,
            "wei_per_budget_unit = 0 must yield budget 0 (Lean Nat.div_zero parity)"
        );
    }
}
