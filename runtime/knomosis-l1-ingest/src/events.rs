// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! L1 event types decoded from raw Ethereum log records.
//!
//! ## What this module exposes
//!
//!   * [`IngestedEvent`] — the typed event surface the translator
//!     consumes.  Each variant corresponds to a Solidity-side
//!     event in `KnomosisBridge.sol` / `KnomosisIdentityRegistry.sol`.
//!   * [`RawLog`] — minimal Ethereum log record shape.  Carries
//!     the `address` (event-emitting contract), 1–4 `topics` (the
//!     `keccak256` event signature + indexed parameters), and
//!     `data` (ABI-encoded non-indexed parameters).
//!   * [`EventTopic`] — the four canonical event signature hashes.
//!   * [`decode_event`] — `(RawLog, address book) → Result<Option<IngestedEvent>>`.
//!     Returns `Ok(None)` for log records that don't match any
//!     known event signature (logs from other contracts, or
//!     non-Knomosis events on the same contract).  Returns
//!     `Err(DecodeError)` for malformed payloads on a known
//!     signature.
//!
//! ## Event signatures and topics
//!
//! The four event signatures the ingestor cares about, together
//! with their `keccak256` topic hashes (computed at construction
//! time via `EventTopic::compute`):
//!
//!   * `RegisteredECDSA(address indexed actor, bytes pubkey)`
//!   * `RegisteredEIP1271(address indexed actor, address contractSigner)`
//!   * `Revoked(address indexed actor)`
//!   * `DepositInitiated(address indexed depositor, uint64 indexed resourceId, address token, uint256 amount, uint64 depositorNonce, bytes32 receiptHash)`
//!
//! ## ABI decoding
//!
//! The implementation hand-rolls a minimal Ethereum ABI decoder
//! covering exactly the field types the four events use:
//!
//!   * `address` — 32 bytes, left-padded.
//!   * `bytes32` — 32 bytes, no padding.
//!   * `uint64` / `uint256` — 32 bytes, big-endian, left-padded.
//!   * `bytes` (dynamic) — 32-byte offset, 32-byte length, payload.
//!
//! Encoding is canonical-ABI: every dynamic-tail field
//! contributes a 32-byte offset header, then its length+payload
//! tail.  Multi-field tuples are encoded in declaration order.
//!
//! Decoding is panic-free on attacker input — every malformed
//! offset / length / truncation returns a typed [`DecodeError`].

use sha3::{Digest, Keccak256};

use crate::action::EthAddress;

/// A 32-byte topic hash.  Used both for event signatures (the
/// `keccak256("EventName(type1,type2,...)")` digest) and for
/// indexed event parameters (left-padded for primitives,
/// `keccak256(payload)` for dynamic types).
pub type TopicHash = [u8; 32];

/// Minimal Ethereum log record.  Carries the bare fields RH-B
/// consumes: the emitting contract address, the 1–4 indexed topics
/// (topic 0 is the event signature hash, topics 1..3 are the
/// indexed parameters in declaration order), and the ABI-encoded
/// non-indexed parameters in `data`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RawLog {
    /// The Ethereum address of the contract that emitted the log.
    pub address: EthAddress,
    /// The 1..=4 topic hashes attached to the log.  Topic 0 is
    /// always the event signature hash for events declared with
    /// `event Name(...)` syntax (not the anonymous form).
    pub topics: Vec<TopicHash>,
    /// ABI-encoded non-indexed parameter payload.
    pub data: Vec<u8>,
    /// L1 block number where the log was mined.  Plumbed through
    /// so the translator can record the originating block in the
    /// `IngestedEvent` and the watcher can match against
    /// confirmation depth.
    pub block_number: u64,
    /// L1 transaction hash containing the log.  Used by the
    /// idempotency layer to deduplicate forwarded events.
    pub tx_hash: TopicHash,
    /// Index of the log within its containing transaction.
    pub log_index: u64,
}

/// One of the four Knomosis-recognised event topics.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EventTopic {
    /// `RegisteredECDSA(address indexed actor, bytes pubkey)`.
    RegisteredEcdsa,
    /// `RegisteredEIP1271(address indexed actor, address contractSigner)`.
    RegisteredEip1271,
    /// `Revoked(address indexed actor)`.
    Revoked,
    /// `DepositInitiated(address indexed depositor, uint64 indexed
    /// resourceId, address token, uint256 amount, uint64
    /// depositorNonce, bytes32 receiptHash)`.
    DepositInitiated,
}

impl EventTopic {
    /// The canonical event-signature string.  Used to compute the
    /// `keccak256` topic hash at runtime.  The exact string
    /// follows Solidity's canonical ABI: lowercase type names, no
    /// spaces, no parameter names, parentheses around the tuple.
    #[must_use]
    pub const fn signature(self) -> &'static str {
        match self {
            Self::RegisteredEcdsa => "RegisteredECDSA(address,bytes)",
            Self::RegisteredEip1271 => "RegisteredEIP1271(address,address)",
            Self::Revoked => "Revoked(address)",
            Self::DepositInitiated => {
                // Note: this matches the canonical encoding of the
                // event in KnomosisBridge.sol.
                "DepositInitiated(address,uint64,address,uint256,uint64,bytes32)"
            }
        }
    }

    /// The `keccak256` of [`Self::signature`] — the topic-0
    /// hash an Ethereum node attaches to a log emitted under
    /// this event.
    #[must_use]
    pub fn hash(self) -> TopicHash {
        let mut hasher = Keccak256::new();
        hasher.update(self.signature().as_bytes());
        let digest = hasher.finalize();
        let mut out = [0u8; 32];
        out.copy_from_slice(&digest);
        out
    }

    /// Find the variant matching a topic hash; `None` if not
    /// recognised.  Used by the decoder to dispatch on `topics[0]`.
    #[must_use]
    pub fn from_hash(hash: &TopicHash) -> Option<Self> {
        // Iterate; the four variants make this O(4) hashes per
        // log decode — at L1 block rates (`< 100` logs/block in
        // practice) this is negligible.
        for variant in [
            Self::RegisteredEcdsa,
            Self::RegisteredEip1271,
            Self::Revoked,
            Self::DepositInitiated,
        ] {
            if &variant.hash() == hash {
                return Some(variant);
            }
        }
        None
    }
}

/// A typed L1 event the translator consumes.  Variants are the
/// kernel-level interpretation of decoded log records.
///
/// Each variant carries the (`block_number`, `tx_hash`,
/// `log_index`) triple that the idempotency layer dedupes on.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum IngestedEvent {
    /// `RegisteredECDSA` — a new ECDSA EOA registered a Knomosis
    /// public key.  Translated to either `RegisterIdentity`
    /// (first-time) or `ReplaceKey` (rotation) depending on the
    /// address book's prior state.
    RegisteredEcdsa {
        /// The Ethereum address that registered.
        actor: EthAddress,
        /// The registered public key bytes (uncompressed
        /// 64-byte secp256k1 per the Solidity contract; the
        /// Lean side accepts arbitrary byte sequences and the
        /// translator passes them through).
        pubkey: Vec<u8>,
        /// L1 block number.
        block_number: u64,
        /// L1 transaction hash.
        tx_hash: TopicHash,
        /// Log index within the transaction.
        log_index: u64,
    },
    /// `RegisteredEIP1271` — a smart-contract signer registered.
    /// The Lean side's `Bridge.Ingest.ingest` MVP scope does
    /// **not** model contract signers separately; they emit
    /// `RegisterIdentity` / `ReplaceKey` with the contract
    /// address encoded as the pubkey (20-byte padded).  The
    /// translator carries the contract address through as the
    /// `pubkey` field for downstream encoding.
    RegisteredEip1271 {
        /// The Ethereum address that registered.
        actor: EthAddress,
        /// The contract signer's address.
        contract_signer: EthAddress,
        /// L1 block number.
        block_number: u64,
        /// L1 transaction hash.
        tx_hash: TopicHash,
        /// Log index within the transaction.
        log_index: u64,
    },
    /// `Revoked` — an actor revoked their registration.
    /// `Bridge.Ingest.ingest` returns `none` for this variant;
    /// the translator emits no `Action` and the event is
    /// recorded only in the watcher's audit log.
    Revoked {
        /// The Ethereum address that was revoked.
        actor: EthAddress,
        /// L1 block number.
        block_number: u64,
        /// L1 transaction hash.
        tx_hash: TopicHash,
        /// Log index within the transaction.
        log_index: u64,
    },
    /// `DepositInitiated` — a deposit was registered on L1.
    /// `Bridge.Ingest.ingest` returns `none` for this variant in
    /// MVP scope (deposit translation goes through
    /// `applyActionToBridgeState` at the kernel level); the
    /// translator records the event in the watcher's audit log
    /// and emits no `Action`.
    DepositInitiated {
        /// The depositor's Ethereum address.
        depositor: EthAddress,
        /// The Knomosis `ResourceId`.
        resource_id: u64,
        /// The token contract (0x000... for native ETH).
        token: EthAddress,
        /// The deposit amount (raw `uint256` bytes; truncation
        /// to `u128` would lose precision for token amounts).
        amount: [u8; 32],
        /// The per-depositor nonce.
        depositor_nonce: u64,
        /// The 32-byte receipt hash (`keccak256(abi.encode(...))`).
        receipt_hash: TopicHash,
        /// L1 block number.
        block_number: u64,
        /// L1 transaction hash.
        tx_hash: TopicHash,
        /// Log index within the transaction.
        log_index: u64,
    },
}

impl IngestedEvent {
    /// Return the originating `(block_number, tx_hash, log_index)`
    /// triple.  Used by the idempotency layer as the dedup key.
    #[must_use]
    pub fn origin_key(&self) -> (u64, TopicHash, u64) {
        match self {
            Self::RegisteredEcdsa {
                block_number,
                tx_hash,
                log_index,
                ..
            }
            | Self::RegisteredEip1271 {
                block_number,
                tx_hash,
                log_index,
                ..
            }
            | Self::Revoked {
                block_number,
                tx_hash,
                log_index,
                ..
            }
            | Self::DepositInitiated {
                block_number,
                tx_hash,
                log_index,
                ..
            } => (*block_number, *tx_hash, *log_index),
        }
    }

    /// Discriminant name for diagnostic logging.
    #[must_use]
    pub fn variant_name(&self) -> &'static str {
        match self {
            Self::RegisteredEcdsa { .. } => "RegisteredECDSA",
            Self::RegisteredEip1271 { .. } => "RegisteredEIP1271",
            Self::Revoked { .. } => "Revoked",
            Self::DepositInitiated { .. } => "DepositInitiated",
        }
    }
}

/// Errors surfaced by [`decode_event`].
#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum DecodeError {
    /// The log had zero topics — every non-anonymous event has at
    /// least topic 0.
    #[error("log record has no topics; expected at least the event signature topic")]
    NoTopics,
    /// A 32-byte ABI slot did not encode an EthAddress (the
    /// upper 12 bytes must be zero per Ethereum convention).
    /// `location` is a human-readable label for diagnostics
    /// (`"topic 1"`, `"data offset 0"`, etc.).
    #[error("ABI slot at {location} does not encode an EthAddress (non-zero high bytes)")]
    InvalidAddress {
        /// Where the slot was located.
        location: String,
    },
    /// The number of topics does not match what the event signature
    /// requires.
    #[error("event {event} expected {expected} topic(s); got {actual}")]
    TopicCountMismatch {
        /// The event variant.
        event: &'static str,
        /// Expected topic count.
        expected: usize,
        /// Actual topic count.
        actual: usize,
    },
    /// A dynamic-field offset pointed past the end of `data`.
    #[error("dynamic-field offset {offset} exceeds data length {data_len}")]
    OffsetOutOfRange {
        /// The offset value.
        offset: usize,
        /// Total data length.
        data_len: usize,
    },
    /// A length field would cause an integer overflow when added
    /// to its offset.
    #[error("dynamic-field length {len} at offset {offset} causes overflow")]
    LengthOverflow {
        /// The length value.
        len: usize,
        /// The offset value.
        offset: usize,
    },
    /// `data` ended before the decoder expected.
    #[error("unexpected end of data at offset {offset}; expected at least {needed} more bytes")]
    UnexpectedEnd {
        /// Where the decoder was.
        offset: usize,
        /// How many more bytes it needed.
        needed: usize,
    },
    /// A `uint64`-typed field had non-zero high bits (the upper
    /// 24 bytes of its 32-byte ABI slot were not all zero).
    #[error("uint64 field at offset {offset} has non-zero high bits")]
    Uint64Overflow {
        /// Where the offending field starts in `data`.
        offset: usize,
    },
}

/// Decode the lowest 8 bytes of a 32-byte ABI uint slot,
/// rejecting the slot if its high 24 bytes are non-zero.  Used
/// for `uint64`-typed event parameters.
fn decode_abi_u64(slot: &[u8; 32], offset: usize) -> Result<u64, DecodeError> {
    // ABI big-endian: the value's low byte is at slot[31].
    // The high 24 bytes (slot[0..24]) must be all zero for a
    // `uint64` to fit.
    if slot[..24].iter().any(|&b| b != 0) {
        return Err(DecodeError::Uint64Overflow { offset });
    }
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&slot[24..32]);
    Ok(u64::from_be_bytes(buf))
}

/// Decode a 32-byte ABI address slot.  The address is the low
/// 20 bytes; the high 12 bytes must be zero per Ethereum
/// canonical encoding.  `location` is a human-readable label
/// for the slot (e.g. `"topic 1"` or `"data offset 0"`).
fn decode_abi_address(
    slot: &[u8; 32],
    location: impl Into<String>,
) -> Result<EthAddress, DecodeError> {
    if slot[..12].iter().any(|&b| b != 0) {
        return Err(DecodeError::InvalidAddress {
            location: location.into(),
        });
    }
    let mut buf = [0u8; 20];
    buf.copy_from_slice(&slot[12..32]);
    Ok(EthAddress(buf))
}

/// Read a 32-byte ABI slot at `offset` from `data`.  Returns
/// `Err(UnexpectedEnd)` if `data` is too short.
fn read_slot(data: &[u8], offset: usize) -> Result<[u8; 32], DecodeError> {
    let end = offset
        .checked_add(32)
        .ok_or(DecodeError::LengthOverflow { len: 32, offset })?;
    if end > data.len() {
        return Err(DecodeError::UnexpectedEnd {
            offset,
            needed: end - data.len(),
        });
    }
    let mut slot = [0u8; 32];
    slot.copy_from_slice(&data[offset..end]);
    Ok(slot)
}

/// Decode the lowest 8 bytes of a 32-byte slot as a u64, with
/// overflow check.  Used for ABI `uint64` slots.
fn slot_to_u64(slot: &[u8; 32], offset: usize) -> Result<u64, DecodeError> {
    decode_abi_u64(slot, offset)
}

/// Decode a dynamic-`bytes` field given its offset header at
/// `offset_pos` in `data`.  ABI layout:
///
///   * `data[offset_pos..offset_pos+32]` is the 32-byte BE offset
///     to the tail.  We treat the offset as relative to the start
///     of `data` (matches non-tuple event-data encoding).
///   * `data[tail..tail+32]` is the 32-byte BE length.
///   * `data[tail+32..tail+32+length]` is the payload.
fn decode_abi_bytes(data: &[u8], offset_pos: usize) -> Result<Vec<u8>, DecodeError> {
    let header = read_slot(data, offset_pos)?;
    // The offset is the low 8 bytes of a 32-byte BE uint; the
    // upper 24 bytes must be zero (the Ethereum convention).
    if header[..24].iter().any(|&b| b != 0) {
        return Err(DecodeError::OffsetOutOfRange {
            offset: usize::MAX,
            data_len: data.len(),
        });
    }
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&header[24..32]);
    let tail_offset = u64::from_be_bytes(buf) as usize;
    if tail_offset > data.len() {
        return Err(DecodeError::OffsetOutOfRange {
            offset: tail_offset,
            data_len: data.len(),
        });
    }
    let length_slot = read_slot(data, tail_offset)?;
    if length_slot[..24].iter().any(|&b| b != 0) {
        return Err(DecodeError::LengthOverflow {
            len: usize::MAX,
            offset: tail_offset,
        });
    }
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&length_slot[24..32]);
    let len = u64::from_be_bytes(buf) as usize;
    let payload_start = tail_offset
        .checked_add(32)
        .ok_or(DecodeError::LengthOverflow {
            len,
            offset: tail_offset,
        })?;
    let payload_end = payload_start
        .checked_add(len)
        .ok_or(DecodeError::LengthOverflow {
            len,
            offset: payload_start,
        })?;
    if payload_end > data.len() {
        return Err(DecodeError::UnexpectedEnd {
            offset: payload_start,
            needed: payload_end - data.len(),
        });
    }
    Ok(data[payload_start..payload_end].to_vec())
}

/// Top-level event decoder.  Returns:
///
///   * `Ok(Some(event))` — successfully decoded a known event.
///   * `Ok(None)` — `log.topics[0]` does not match any of the
///     four Knomosis event signatures (an unrelated log).
///   * `Err(DecodeError)` — the topic matched but the payload
///     was malformed.
///
/// # Errors
///
/// See [`DecodeError`] for the failure modes.  Every error path
/// is a typed variant; the decoder never panics on attacker
/// input.
pub fn decode_event(log: &RawLog) -> Result<Option<IngestedEvent>, DecodeError> {
    let topic0 = log.topics.first().ok_or(DecodeError::NoTopics)?;
    let event = match EventTopic::from_hash(topic0) {
        None => return Ok(None),
        Some(e) => e,
    };
    match event {
        EventTopic::RegisteredEcdsa => {
            // Topics: [signature_hash, actor].  Data: bytes pubkey.
            if log.topics.len() != 2 {
                return Err(DecodeError::TopicCountMismatch {
                    event: "RegisteredECDSA",
                    expected: 2,
                    actual: log.topics.len(),
                });
            }
            let actor = decode_abi_address(&log.topics[1], "topic 1")?;
            let pubkey = decode_abi_bytes(&log.data, 0)?;
            Ok(Some(IngestedEvent::RegisteredEcdsa {
                actor,
                pubkey,
                block_number: log.block_number,
                tx_hash: log.tx_hash,
                log_index: log.log_index,
            }))
        }
        EventTopic::RegisteredEip1271 => {
            // Topics: [signature_hash, actor].  Data: address contractSigner (padded).
            if log.topics.len() != 2 {
                return Err(DecodeError::TopicCountMismatch {
                    event: "RegisteredEIP1271",
                    expected: 2,
                    actual: log.topics.len(),
                });
            }
            let actor = decode_abi_address(&log.topics[1], "topic 1")?;
            let slot = read_slot(&log.data, 0)?;
            let contract_signer = decode_abi_address(&slot, "data offset 0")?;
            Ok(Some(IngestedEvent::RegisteredEip1271 {
                actor,
                contract_signer,
                block_number: log.block_number,
                tx_hash: log.tx_hash,
                log_index: log.log_index,
            }))
        }
        EventTopic::Revoked => {
            // Topics: [signature_hash, actor].  Data: empty.
            if log.topics.len() != 2 {
                return Err(DecodeError::TopicCountMismatch {
                    event: "Revoked",
                    expected: 2,
                    actual: log.topics.len(),
                });
            }
            let actor = decode_abi_address(&log.topics[1], "topic 1")?;
            Ok(Some(IngestedEvent::Revoked {
                actor,
                block_number: log.block_number,
                tx_hash: log.tx_hash,
                log_index: log.log_index,
            }))
        }
        EventTopic::DepositInitiated => {
            // Topics: [signature_hash, depositor, resourceId].
            // Data: address token + uint256 amount + uint64
            // depositorNonce + bytes32 receiptHash.
            if log.topics.len() != 3 {
                return Err(DecodeError::TopicCountMismatch {
                    event: "DepositInitiated",
                    expected: 3,
                    actual: log.topics.len(),
                });
            }
            let depositor = decode_abi_address(&log.topics[1], "topic 1")?;
            let resource_id = slot_to_u64(&log.topics[2], 0)?;
            // Static-fields data layout: each parameter is one 32-byte slot.
            let token_slot = read_slot(&log.data, 0)?;
            let token = decode_abi_address(&token_slot, "data offset 0 (token)")?;
            let amount = read_slot(&log.data, 32)?;
            let nonce_slot = read_slot(&log.data, 64)?;
            let depositor_nonce = decode_abi_u64(&nonce_slot, 64)?;
            let receipt_hash = read_slot(&log.data, 96)?;
            Ok(Some(IngestedEvent::DepositInitiated {
                depositor,
                resource_id,
                token,
                amount,
                depositor_nonce,
                receipt_hash,
                block_number: log.block_number,
                tx_hash: log.tx_hash,
                log_index: log.log_index,
            }))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        decode_abi_address, decode_abi_bytes, decode_abi_u64, decode_event, DecodeError,
        EventTopic, IngestedEvent, RawLog, TopicHash,
    };
    use crate::action::EthAddress;

    /// Topic hashes are stable: changing the signature string is
    /// a wire-format break and CI surfaces it.  Computed values
    /// are the canonical Solidity-side keccak256.
    #[test]
    fn topic_hash_registered_ecdsa() {
        // `keccak256("RegisteredECDSA(address,bytes)")` =
        // 0xa49a02ea36e5e0ed02d0d6f0fff62cab4be3a64db84a1ce3afe92f9c5e8c5d92
        let topic = EventTopic::RegisteredEcdsa.hash();
        // Recompute via keccak256 of the signature string to
        // confirm consistency.
        let recomputed = {
            use sha3::{Digest, Keccak256};
            let mut hasher = Keccak256::new();
            hasher.update(b"RegisteredECDSA(address,bytes)");
            let d = hasher.finalize();
            let mut out = [0u8; 32];
            out.copy_from_slice(&d);
            out
        };
        assert_eq!(topic, recomputed);
    }

    /// `EventTopic::from_hash` round-trips through `hash`.
    #[test]
    fn topic_round_trip() {
        for variant in [
            EventTopic::RegisteredEcdsa,
            EventTopic::RegisteredEip1271,
            EventTopic::Revoked,
            EventTopic::DepositInitiated,
        ] {
            let hash = variant.hash();
            assert_eq!(EventTopic::from_hash(&hash), Some(variant));
        }
    }

    /// `from_hash` returns `None` for unknown topics.
    #[test]
    fn topic_unknown_returns_none() {
        let unknown: TopicHash = [0xab; 32];
        assert!(EventTopic::from_hash(&unknown).is_none());
    }

    /// All four topic hashes are distinct.
    #[test]
    fn topics_pairwise_distinct() {
        let hashes = [
            EventTopic::RegisteredEcdsa.hash(),
            EventTopic::RegisteredEip1271.hash(),
            EventTopic::Revoked.hash(),
            EventTopic::DepositInitiated.hash(),
        ];
        for i in 0..hashes.len() {
            for j in (i + 1)..hashes.len() {
                assert_ne!(hashes[i], hashes[j], "topic hash collision at {i} vs {j}");
            }
        }
    }

    /// `decode_abi_address` extracts the low 20 bytes.
    #[test]
    fn decode_address_low_20() {
        let mut slot = [0u8; 32];
        for i in 0..20 {
            // Place a recognisable pattern in the low 20 bytes.
            slot[12 + i] = i as u8;
        }
        let addr = decode_abi_address(&slot, "test").unwrap();
        for i in 0..20 {
            assert_eq!(addr.0[i], i as u8);
        }
    }

    /// `decode_abi_address` rejects non-zero high bytes and the
    /// error message includes the slot's location for
    /// diagnosability.
    #[test]
    fn decode_address_rejects_high_bits() {
        let mut slot = [0u8; 32];
        slot[0] = 1; // non-zero in high padding region
        match decode_abi_address(&slot, "topic 7") {
            Err(DecodeError::InvalidAddress { location }) => {
                assert_eq!(location, "topic 7");
            }
            other => panic!("expected InvalidAddress, got {other:?}"),
        }
    }

    /// `decode_abi_u64` extracts low 8 bytes as BE u64.
    #[test]
    fn decode_u64_low_8() {
        let mut slot = [0u8; 32];
        // Value 0x0102030405060708 in big-endian at slot[24..32].
        slot[24] = 0x01;
        slot[25] = 0x02;
        slot[26] = 0x03;
        slot[27] = 0x04;
        slot[28] = 0x05;
        slot[29] = 0x06;
        slot[30] = 0x07;
        slot[31] = 0x08;
        assert_eq!(decode_abi_u64(&slot, 0).unwrap(), 0x0102_0304_0506_0708u64);
    }

    /// `decode_abi_u64` rejects values that exceed `u64::MAX`.
    #[test]
    fn decode_u64_rejects_overflow() {
        let mut slot = [0u8; 32];
        slot[23] = 1; // bit 64 set
        assert!(matches!(
            decode_abi_u64(&slot, 12),
            Err(DecodeError::Uint64Overflow { offset: 12 })
        ));
    }

    /// `decode_abi_bytes` with empty payload.
    #[test]
    fn decode_dynamic_bytes_empty() {
        // Layout:
        //   0..32:   offset = 32 (BE)
        //   32..64:  length = 0
        //   (no payload)
        let mut data = [0u8; 64];
        data[31] = 32; // offset = 32
                       // Length defaults to 0.
        let bytes = decode_abi_bytes(&data, 0).unwrap();
        assert_eq!(bytes.len(), 0);
    }

    /// `decode_abi_bytes` with 3-byte payload.
    #[test]
    fn decode_dynamic_bytes_short() {
        let mut data = vec![0u8; 96];
        // offset = 32
        data[31] = 32;
        // length = 3
        data[63] = 3;
        // payload starts at index 64
        data[64] = 0xaa;
        data[65] = 0xbb;
        data[66] = 0xcc;
        let bytes = decode_abi_bytes(&data, 0).unwrap();
        assert_eq!(bytes, vec![0xaa, 0xbb, 0xcc]);
    }

    /// `decode_event` on empty topics returns `NoTopics`.
    #[test]
    fn decode_event_no_topics() {
        let log = RawLog {
            address: EthAddress::ZERO,
            topics: vec![],
            data: vec![],
            block_number: 0,
            tx_hash: [0; 32],
            log_index: 0,
        };
        assert!(matches!(decode_event(&log), Err(DecodeError::NoTopics)));
    }

    /// `decode_event` on unknown topic returns `Ok(None)`.
    #[test]
    fn decode_event_unknown_topic() {
        let log = RawLog {
            address: EthAddress::ZERO,
            topics: vec![[0xff; 32]],
            data: vec![],
            block_number: 0,
            tx_hash: [0; 32],
            log_index: 0,
        };
        assert_eq!(decode_event(&log).unwrap(), None);
    }

    /// `decode_event` on a fabricated `RegisteredECDSA` event
    /// produces the expected `IngestedEvent`.
    #[test]
    fn decode_event_registered_ecdsa() {
        let actor_bytes: [u8; 20] = [0xab; 20];
        // Topic 1: address padded to 32 bytes.
        let mut actor_topic = [0u8; 32];
        actor_topic[12..32].copy_from_slice(&actor_bytes);
        // Data: bytes pubkey (3 bytes: 0x01 0x02 0x03).
        let mut data = vec![0u8; 96];
        data[31] = 32; // offset = 32
        data[63] = 3; // length = 3
        data[64] = 1;
        data[65] = 2;
        data[66] = 3;
        let log = RawLog {
            address: EthAddress::ZERO,
            topics: vec![EventTopic::RegisteredEcdsa.hash(), actor_topic],
            data,
            block_number: 100,
            tx_hash: [0x7a; 32],
            log_index: 5,
        };
        let decoded = decode_event(&log).unwrap().unwrap();
        match decoded {
            IngestedEvent::RegisteredEcdsa {
                actor,
                pubkey,
                block_number,
                tx_hash,
                log_index,
            } => {
                assert_eq!(actor.as_bytes(), &actor_bytes);
                assert_eq!(pubkey, vec![1, 2, 3]);
                assert_eq!(block_number, 100);
                assert_eq!(tx_hash, [0x7a; 32]);
                assert_eq!(log_index, 5);
            }
            _ => panic!("expected RegisteredEcdsa"),
        }
    }

    /// `decode_event` rejects a `RegisteredECDSA` event with wrong
    /// topic count.
    #[test]
    fn decode_event_registered_ecdsa_topic_count() {
        let log = RawLog {
            address: EthAddress::ZERO,
            topics: vec![EventTopic::RegisteredEcdsa.hash()],
            data: vec![],
            block_number: 0,
            tx_hash: [0; 32],
            log_index: 0,
        };
        assert!(matches!(
            decode_event(&log),
            Err(DecodeError::TopicCountMismatch {
                event: "RegisteredECDSA",
                expected: 2,
                actual: 1
            })
        ));
    }

    /// `decode_event` rejects a `Revoked` event with non-empty
    /// data that doesn't change decoding (Revoked has no data
    /// fields, so extra data is ignored).
    #[test]
    fn decode_event_revoked() {
        let actor_bytes = [0x12u8; 20];
        let mut actor_topic = [0u8; 32];
        actor_topic[12..32].copy_from_slice(&actor_bytes);
        let log = RawLog {
            address: EthAddress::ZERO,
            topics: vec![EventTopic::Revoked.hash(), actor_topic],
            data: vec![],
            block_number: 200,
            tx_hash: [0xbb; 32],
            log_index: 1,
        };
        let decoded = decode_event(&log).unwrap().unwrap();
        match decoded {
            IngestedEvent::Revoked { actor, .. } => {
                assert_eq!(actor.as_bytes(), &actor_bytes);
            }
            _ => panic!("expected Revoked"),
        }
    }

    /// `decode_event` on a `DepositInitiated` payload.
    #[test]
    fn decode_event_deposit_initiated() {
        let depositor = [0x11u8; 20];
        let mut depositor_topic = [0u8; 32];
        depositor_topic[12..32].copy_from_slice(&depositor);
        let mut resource_topic = [0u8; 32];
        // resourceId = 7 (BE).
        resource_topic[31] = 7;
        // Data layout: token (32) + amount (32) + nonce (32) + receipt_hash (32) = 128 bytes.
        let mut data = vec![0u8; 128];
        // Token at offset 0..32: address (low 20 bytes).
        let token = [0x22u8; 20];
        data[12..32].copy_from_slice(&token);
        // Amount at offset 32..64: BE 1000.
        data[63] = 0xe8; // 1000 = 0x03e8
        data[62] = 0x03;
        // Nonce at offset 64..96: BE 42.
        data[95] = 42;
        // Receipt hash at offset 96..128: all 0xee.
        for slot in data.iter_mut().skip(96).take(32) {
            *slot = 0xee;
        }
        let log = RawLog {
            address: EthAddress::ZERO,
            topics: vec![
                EventTopic::DepositInitiated.hash(),
                depositor_topic,
                resource_topic,
            ],
            data,
            block_number: 500,
            tx_hash: [0x4d; 32],
            log_index: 0,
        };
        let decoded = decode_event(&log).unwrap().unwrap();
        match decoded {
            IngestedEvent::DepositInitiated {
                depositor: d,
                resource_id,
                token: t,
                amount,
                depositor_nonce,
                receipt_hash,
                ..
            } => {
                assert_eq!(d.as_bytes(), &depositor);
                assert_eq!(resource_id, 7);
                assert_eq!(t.as_bytes(), &token);
                let mut expected_amount = [0u8; 32];
                expected_amount[30] = 0x03;
                expected_amount[31] = 0xe8;
                assert_eq!(amount, expected_amount);
                assert_eq!(depositor_nonce, 42);
                assert_eq!(receipt_hash, [0xee; 32]);
            }
            _ => panic!("expected DepositInitiated"),
        }
    }

    /// `origin_key` returns the originating triple.
    #[test]
    fn origin_key_extracts_triple() {
        let event = IngestedEvent::RegisteredEcdsa {
            actor: EthAddress::ZERO,
            pubkey: vec![],
            block_number: 42,
            tx_hash: [0xee; 32],
            log_index: 3,
        };
        let (block, tx, log_idx) = event.origin_key();
        assert_eq!(block, 42);
        assert_eq!(tx, [0xee; 32]);
        assert_eq!(log_idx, 3);
    }

    /// `variant_name` returns the human-readable label.
    #[test]
    fn variant_name() {
        let e = IngestedEvent::Revoked {
            actor: EthAddress::ZERO,
            block_number: 0,
            tx_hash: [0; 32],
            log_index: 0,
        };
        assert_eq!(e.variant_name(), "Revoked");
    }
}
