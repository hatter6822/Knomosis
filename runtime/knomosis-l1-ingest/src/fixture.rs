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
}
