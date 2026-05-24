// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! L1 event types and decoding for the bisection-game contract.
//!
//! ## Event signatures
//!
//! The five Knomosis-recognised events the observer cares about are
//! emitted by `solidity/src/contracts/KnomosisFaultProofGame.sol` and
//! `solidity/src/contracts/KnomosisStateRootSubmission.sol`.
//!
//! ### From `KnomosisFaultProofGame.sol`
//!
//!   * `FaultProofGameOpened(uint256 indexed gameId, address indexed challenger, bytes32 disputedStateRoot, bytes32 challengerStateRoot)`
//!   * `BisectionMidpointSubmitted(uint256 indexed gameId, address indexed party, uint64 idx, bytes32 commit)`
//!   * `BisectionResponseSubmitted(uint256 indexed gameId, address indexed party, bool agree)`
//!   * `FaultProofGameSettled(uint256 indexed gameId, GameStatus status, address indexed winner, uint128 winnerPayout)`
//!
//! ### From `KnomosisStateRootSubmission.sol`
//!
//!   * `StateRootSubmitted(uint64 indexed logIndex, bytes32 stateCommit, address indexed sequencer)`
//!
//! ## ABI decoding discipline
//!
//! Mirrors `knomosis-l1-ingest/src/events.rs`: every malformed
//! payload returns a typed `EventDecodeError`; no `panic!` on
//! attacker-supplied bytes.
//!
//! ## Cross-stack alignment with knomosis-l1-ingest
//!
//! We re-use [`knomosis_l1_ingest::events::TopicHash`] and
//! [`knomosis_l1_ingest::events::RawLog`] so the observer consumes
//! the same `L1Source` trait surface and the same JSON-RPC client
//! as the L1 ingestor.  Adapter functions live in
//! [`super::watcher`] for wiring the trait.

use knomosis_l1_ingest::events::{RawLog, TopicHash};
use sha3::{Digest, Keccak256};

use crate::game::{ActorId, GameStatus, LogIndex, StateCommit};

/// One of the five Knomosis-recognised event topics.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum GameEventTopic {
    /// `FaultProofGameOpened(uint256,address,bytes32,bytes32)`.
    GameOpened,
    /// `BisectionMidpointSubmitted(uint256,address,uint64,bytes32)`.
    MidpointSubmitted,
    /// `BisectionResponseSubmitted(uint256,address,bool)`.
    ResponseSubmitted,
    /// `FaultProofGameSettled(uint256,uint8,address,uint128)`.
    GameSettled,
    /// `StateRootSubmitted(uint64,bytes32,address)`.
    StateRootSubmitted,
}

impl GameEventTopic {
    /// The canonical event-signature string.  Used to compute the
    /// keccak256 topic-0 hash at runtime.  Follows Solidity's
    /// canonical ABI: lowercase type names, no spaces, no
    /// parameter names.
    ///
    /// **Note on `GameStatus`**: Solidity emits the `GameStatus`
    /// enum's underlying `uint8` in the topic.  The event
    /// signature on the wire is therefore `(uint256, uint8,
    /// address, uint128)` — matching what `keccak256` over the
    /// canonical type tuple produces.
    #[must_use]
    pub const fn signature(self) -> &'static str {
        match self {
            Self::GameOpened => "FaultProofGameOpened(uint256,address,bytes32,bytes32)",
            Self::MidpointSubmitted => "BisectionMidpointSubmitted(uint256,address,uint64,bytes32)",
            Self::ResponseSubmitted => "BisectionResponseSubmitted(uint256,address,bool)",
            Self::GameSettled => "FaultProofGameSettled(uint256,uint8,address,uint128)",
            Self::StateRootSubmitted => "StateRootSubmitted(uint64,bytes32,address)",
        }
    }

    /// The keccak256 of [`Self::signature`] — the topic-0 hash
    /// an Ethereum node attaches to a log emitted under this
    /// event.
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
    /// recognised.
    #[must_use]
    pub fn from_hash(hash: &TopicHash) -> Option<Self> {
        [
            Self::GameOpened,
            Self::MidpointSubmitted,
            Self::ResponseSubmitted,
            Self::GameSettled,
            Self::StateRootSubmitted,
        ]
        .into_iter()
        .find(|variant| &variant.hash() == hash)
    }
}

/// A typed L1 game event decoded from a raw log record.  Each
/// variant carries the L1 metadata (`block_number`, `tx_hash`,
/// `log_index`) for idempotency-keyed deduplication.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GameEvent {
    /// `FaultProofGameOpened` — a new game was opened.
    GameOpened {
        /// The new game's id.
        game_id: u128,
        /// The challenger's L1 address (encoded as the lower 20
        /// bytes of the topic; preserved as a 32-byte topic
        /// payload to avoid information loss).
        challenger_topic: TopicHash,
        /// The disputed state root (the sequencer's claimed
        /// commit at the disputed log index).
        disputed_state_root: StateCommit,
        /// The challenger's claimed state root.
        challenger_state_root: StateCommit,
        /// L1 block number.
        block_number: u64,
        /// L1 transaction hash.
        tx_hash: TopicHash,
        /// Log index within the transaction.
        log_index: u64,
    },
    /// `BisectionMidpointSubmitted` — a party submitted a
    /// midpoint commit.
    MidpointSubmitted {
        /// The game's id.
        game_id: u128,
        /// The submitting party's L1 address (raw topic).
        party_topic: TopicHash,
        /// The log index of the midpoint.
        idx: LogIndex,
        /// The claimed midpoint commit.
        commit: StateCommit,
        /// L1 block number.
        block_number: u64,
        /// L1 transaction hash.
        tx_hash: TopicHash,
        /// Log index within the transaction.
        log_index: u64,
    },
    /// `BisectionResponseSubmitted` — a party agreed or
    /// disagreed with the pending midpoint.
    ResponseSubmitted {
        /// The game's id.
        game_id: u128,
        /// The responding party's L1 address (raw topic).
        party_topic: TopicHash,
        /// `true` for agree, `false` for disagree.
        agree: bool,
        /// L1 block number.
        block_number: u64,
        /// L1 transaction hash.
        tx_hash: TopicHash,
        /// Log index within the transaction.
        log_index: u64,
    },
    /// `FaultProofGameSettled` — the game reached terminal
    /// state.
    GameSettled {
        /// The game's id.
        game_id: u128,
        /// The terminal status (decoded from the Solidity enum's
        /// underlying `uint8`).
        status: GameStatus,
        /// The winner's L1 address (raw topic).
        winner_topic: TopicHash,
        /// The wei amount paid to the winner.
        winner_payout: u128,
        /// L1 block number.
        block_number: u64,
        /// L1 transaction hash.
        tx_hash: TopicHash,
        /// Log index within the transaction.
        log_index: u64,
    },
    /// `StateRootSubmitted` — the sequencer posted a new state
    /// root.  Watched to detect state-root mismatches against the
    /// local L2 replay.
    StateRootSubmitted {
        /// The log index this root claims to cover.
        log_index_claim: LogIndex,
        /// The sequencer's claimed state-root commit.
        state_commit: StateCommit,
        /// The sequencer's L1 address (raw topic).
        sequencer_topic: TopicHash,
        /// L1 block number.
        block_number: u64,
        /// L1 transaction hash.
        tx_hash: TopicHash,
        /// Log index within the transaction.
        log_index: u64,
    },
}

impl GameEvent {
    /// Return the (`block_number`, `tx_hash`, `log_index`) idempotency
    /// key for this event.  Used by the watcher's forwarded-set
    /// dedup discipline (mirrors RH-B's
    /// `state::ForwardedKey`).
    #[must_use]
    pub fn idempotency_key(&self) -> (u64, TopicHash, u64) {
        match self {
            Self::GameOpened {
                block_number,
                tx_hash,
                log_index,
                ..
            }
            | Self::MidpointSubmitted {
                block_number,
                tx_hash,
                log_index,
                ..
            }
            | Self::ResponseSubmitted {
                block_number,
                tx_hash,
                log_index,
                ..
            }
            | Self::GameSettled {
                block_number,
                tx_hash,
                log_index,
                ..
            }
            | Self::StateRootSubmitted {
                block_number,
                tx_hash,
                log_index,
                ..
            } => (*block_number, *tx_hash, *log_index),
        }
    }

    /// Return the L1 block number this event was emitted in.
    #[must_use]
    pub fn block_number(&self) -> u64 {
        self.idempotency_key().0
    }

    /// Return the game id this event refers to, or `None` for
    /// non-game events (`StateRootSubmitted`).
    #[must_use]
    pub fn game_id(&self) -> Option<u128> {
        match self {
            Self::GameOpened { game_id, .. }
            | Self::MidpointSubmitted { game_id, .. }
            | Self::ResponseSubmitted { game_id, .. }
            | Self::GameSettled { game_id, .. } => Some(*game_id),
            Self::StateRootSubmitted { .. } => None,
        }
    }
}

/// Errors `decode_event` can produce.
#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum EventDecodeError {
    /// The log's `topics` array did not have the expected length.
    #[error("topics length {got} did not match expected {expected} for event {variant}")]
    WrongTopicsLength {
        /// The event variant being decoded.
        variant: &'static str,
        /// Topics length received.
        got: usize,
        /// Topics length expected.
        expected: usize,
    },
    /// The log's `data` did not have the expected length (each
    /// event's non-indexed parameters encode to a fixed 32×N byte
    /// payload).
    #[error("data length {got} did not match expected {expected} for event {variant}")]
    WrongDataLength {
        /// The event variant being decoded.
        variant: &'static str,
        /// Data length received.
        got: usize,
        /// Data length expected.
        expected: usize,
    },
    /// A numeric field exceeded its declared bit width.  Mirrors
    /// `knomosis-l1-ingest`'s `DecodeError::NumericTooLarge`.
    #[error("numeric field '{field}' exceeded bound (value too large for {bound} bits)")]
    NumericTooLarge {
        /// The field name.
        field: &'static str,
        /// The bit width of the field type.
        bound: u32,
    },
    /// A boolean field contained a non-{0, 1} value.
    #[error("boolean field '{field}' contained non-{{0,1}} value")]
    NonCanonicalBool {
        /// The field name.
        field: &'static str,
    },
    /// A `GameStatus` byte did not match any known variant.  Bytes
    /// 0..=4 are valid; anything else is rejected.
    #[error("unknown GameStatus byte {byte}")]
    UnknownGameStatus {
        /// The unrecognised byte.
        byte: u8,
    },
}

/// Decode a `RawLog` into a typed `GameEvent` if its topic-0
/// matches one of the known game-event signatures.
///
/// Returns `Ok(None)` for log records whose topic-0 doesn't
/// match any known signature — typically logs from other
/// contracts captured by an over-broad RPC filter.
///
/// Returns `Err(EventDecodeError)` for known-signature events
/// whose payload is malformed.
///
/// # Errors
///
/// See [`EventDecodeError`].
pub fn decode_event(log: &RawLog) -> Result<Option<GameEvent>, EventDecodeError> {
    let Some(topic0) = log.topics.first() else {
        return Ok(None);
    };
    let Some(variant) = GameEventTopic::from_hash(topic0) else {
        return Ok(None);
    };
    match variant {
        GameEventTopic::GameOpened => decode_game_opened(log).map(Some),
        GameEventTopic::MidpointSubmitted => decode_midpoint_submitted(log).map(Some),
        GameEventTopic::ResponseSubmitted => decode_response_submitted(log).map(Some),
        GameEventTopic::GameSettled => decode_game_settled(log).map(Some),
        GameEventTopic::StateRootSubmitted => decode_state_root_submitted(log).map(Some),
    }
}

/// Decode `FaultProofGameOpened`:
///   * topics[0] = sig hash
///   * topics[1] = uint256 indexed gameId (32 bytes)
///   * topics[2] = address indexed challenger (lower 20 bytes of 32)
///   * data: bytes32 disputedStateRoot ++ bytes32 challengerStateRoot
fn decode_game_opened(log: &RawLog) -> Result<GameEvent, EventDecodeError> {
    expect_topics(log, "FaultProofGameOpened", 3)?;
    expect_data_len(log, "FaultProofGameOpened", 64)?;
    let game_id = decode_topic_uint128(&log.topics[1], "FaultProofGameOpened.gameId")?;
    let challenger_topic = log.topics[2];
    let mut disputed = [0u8; 32];
    disputed.copy_from_slice(&log.data[0..32]);
    let mut challenger_root = [0u8; 32];
    challenger_root.copy_from_slice(&log.data[32..64]);
    Ok(GameEvent::GameOpened {
        game_id,
        challenger_topic,
        disputed_state_root: disputed,
        challenger_state_root: challenger_root,
        block_number: log.block_number,
        tx_hash: log.tx_hash,
        log_index: log.log_index,
    })
}

/// Decode `BisectionMidpointSubmitted`:
///   * topics[0] = sig hash
///   * topics[1] = uint256 indexed gameId
///   * topics[2] = address indexed party
///   * data: uint64 idx (left-padded to 32 bytes) ++ bytes32 commit
fn decode_midpoint_submitted(log: &RawLog) -> Result<GameEvent, EventDecodeError> {
    expect_topics(log, "BisectionMidpointSubmitted", 3)?;
    expect_data_len(log, "BisectionMidpointSubmitted", 64)?;
    let game_id = decode_topic_uint128(&log.topics[1], "BisectionMidpointSubmitted.gameId")?;
    let party_topic = log.topics[2];
    // First 32-byte word is uint64 left-padded.
    let mut idx_word = [0u8; 32];
    idx_word.copy_from_slice(&log.data[0..32]);
    let idx = decode_word_uint64(&idx_word, "BisectionMidpointSubmitted.idx")?;
    let mut commit = [0u8; 32];
    commit.copy_from_slice(&log.data[32..64]);
    Ok(GameEvent::MidpointSubmitted {
        game_id,
        party_topic,
        idx,
        commit,
        block_number: log.block_number,
        tx_hash: log.tx_hash,
        log_index: log.log_index,
    })
}

/// Decode `BisectionResponseSubmitted`:
///   * topics[0] = sig hash
///   * topics[1] = uint256 indexed gameId
///   * topics[2] = address indexed party
///   * data: bool agree (left-padded to 32 bytes)
fn decode_response_submitted(log: &RawLog) -> Result<GameEvent, EventDecodeError> {
    expect_topics(log, "BisectionResponseSubmitted", 3)?;
    expect_data_len(log, "BisectionResponseSubmitted", 32)?;
    let game_id = decode_topic_uint128(&log.topics[1], "BisectionResponseSubmitted.gameId")?;
    let party_topic = log.topics[2];
    let agree = decode_word_bool(&log.data[0..32], "BisectionResponseSubmitted.agree")?;
    Ok(GameEvent::ResponseSubmitted {
        game_id,
        party_topic,
        agree,
        block_number: log.block_number,
        tx_hash: log.tx_hash,
        log_index: log.log_index,
    })
}

/// Decode `FaultProofGameSettled`:
///   * topics[0] = sig hash
///   * topics[1] = uint256 indexed gameId
///   * topics[2] = address indexed winner
///   * data: uint8 status (left-padded to 32 bytes) ++ uint128 winnerPayout (left-padded to 32 bytes)
fn decode_game_settled(log: &RawLog) -> Result<GameEvent, EventDecodeError> {
    expect_topics(log, "FaultProofGameSettled", 3)?;
    expect_data_len(log, "FaultProofGameSettled", 64)?;
    let game_id = decode_topic_uint128(&log.topics[1], "FaultProofGameSettled.gameId")?;
    let winner_topic = log.topics[2];
    // First word: uint8 status; check zero-padding then read low
    // byte.
    let mut status_word = [0u8; 32];
    status_word.copy_from_slice(&log.data[0..32]);
    let status_byte = decode_word_uint8(&status_word, "FaultProofGameSettled.status")?;
    let status = match status_byte {
        0 => GameStatus::InProgress,
        1 => GameStatus::SequencerWon,
        2 => GameStatus::ChallengerWon,
        3 => GameStatus::TimedOutSequencer,
        4 => GameStatus::TimedOutChallenger,
        other => return Err(EventDecodeError::UnknownGameStatus { byte: other }),
    };
    let mut payout_word = [0u8; 32];
    payout_word.copy_from_slice(&log.data[32..64]);
    let winner_payout = decode_word_uint128(&payout_word, "FaultProofGameSettled.winnerPayout")?;
    Ok(GameEvent::GameSettled {
        game_id,
        status,
        winner_topic,
        winner_payout,
        block_number: log.block_number,
        tx_hash: log.tx_hash,
        log_index: log.log_index,
    })
}

/// Decode `StateRootSubmitted`:
///   * topics[0] = sig hash
///   * topics[1] = uint64 indexed logIndex
///   * topics[2] = address indexed sequencer
///   * data: bytes32 stateCommit
fn decode_state_root_submitted(log: &RawLog) -> Result<GameEvent, EventDecodeError> {
    expect_topics(log, "StateRootSubmitted", 3)?;
    expect_data_len(log, "StateRootSubmitted", 32)?;
    let log_index_claim = decode_topic_uint64(&log.topics[1], "StateRootSubmitted.logIndex")?;
    let sequencer_topic = log.topics[2];
    let mut state_commit = [0u8; 32];
    state_commit.copy_from_slice(&log.data[0..32]);
    Ok(GameEvent::StateRootSubmitted {
        log_index_claim,
        state_commit,
        sequencer_topic,
        block_number: log.block_number,
        tx_hash: log.tx_hash,
        log_index: log.log_index,
    })
}

/// Helper: enforce `log.topics.len() == expected`.
fn expect_topics(
    log: &RawLog,
    variant: &'static str,
    expected: usize,
) -> Result<(), EventDecodeError> {
    if log.topics.len() == expected {
        Ok(())
    } else {
        Err(EventDecodeError::WrongTopicsLength {
            variant,
            got: log.topics.len(),
            expected,
        })
    }
}

/// Helper: enforce `log.data.len() == expected`.
fn expect_data_len(
    log: &RawLog,
    variant: &'static str,
    expected: usize,
) -> Result<(), EventDecodeError> {
    if log.data.len() == expected {
        Ok(())
    } else {
        Err(EventDecodeError::WrongDataLength {
            variant,
            got: log.data.len(),
            expected,
        })
    }
}

/// Decode a 32-byte ABI word as a uint128.  Enforces the upper
/// 16 bytes are zero.
fn decode_word_uint128(word: &[u8; 32], field: &'static str) -> Result<u128, EventDecodeError> {
    // Upper 16 bytes must be zero.
    if word[0..16].iter().any(|b| *b != 0) {
        return Err(EventDecodeError::NumericTooLarge { field, bound: 128 });
    }
    let mut out = [0u8; 16];
    out.copy_from_slice(&word[16..32]);
    Ok(u128::from_be_bytes(out))
}

/// Decode an indexed-topic 32-byte payload as a uint128 (the
/// Solidity ABI left-pads indexed uintN into the topic).
fn decode_topic_uint128(topic: &TopicHash, field: &'static str) -> Result<u128, EventDecodeError> {
    decode_word_uint128(topic, field)
}

/// Decode a 32-byte ABI word as a uint64.  Enforces the upper
/// 24 bytes are zero.
fn decode_word_uint64(word: &[u8; 32], field: &'static str) -> Result<u64, EventDecodeError> {
    if word[0..24].iter().any(|b| *b != 0) {
        return Err(EventDecodeError::NumericTooLarge { field, bound: 64 });
    }
    let mut out = [0u8; 8];
    out.copy_from_slice(&word[24..32]);
    Ok(u64::from_be_bytes(out))
}

/// Decode an indexed-topic 32-byte payload as a uint64.
fn decode_topic_uint64(topic: &TopicHash, field: &'static str) -> Result<u64, EventDecodeError> {
    decode_word_uint64(topic, field)
}

/// Decode a 32-byte ABI word as a uint8.  Enforces the upper
/// 31 bytes are zero.
fn decode_word_uint8(word: &[u8; 32], field: &'static str) -> Result<u8, EventDecodeError> {
    if word[0..31].iter().any(|b| *b != 0) {
        return Err(EventDecodeError::NumericTooLarge { field, bound: 8 });
    }
    Ok(word[31])
}

/// Decode a 32-byte ABI slice as a bool.  Enforces the value is
/// strictly 0 or 1 (the Solidity ABI guarantees this; we
/// defensively reject anything else).
fn decode_word_bool(word: &[u8], field: &'static str) -> Result<bool, EventDecodeError> {
    if word.len() != 32 {
        return Err(EventDecodeError::WrongDataLength {
            variant: field,
            got: word.len(),
            expected: 32,
        });
    }
    // Upper 31 bytes must be zero.
    if word[0..31].iter().any(|b| *b != 0) {
        return Err(EventDecodeError::NonCanonicalBool { field });
    }
    match word[31] {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(EventDecodeError::NonCanonicalBool { field }),
    }
}

/// Convert a 32-byte topic to a Knomosis `ActorId`.  The Solidity
/// contract indexes party / challenger / sequencer addresses as
/// `address indexed _`, which left-pads to 32 bytes (zero-padded
/// in the upper 12 bytes; the lower 20 bytes are the address).
///
/// The Knomosis kernel's `ActorId` is a `u64`.  Production
/// deployments map the L1 address to the kernel actor-id via the
/// address-book (see `knomosis-l1-ingest/src/address_book.rs`).  The
/// observer does NOT replicate that map — it works in L1 address
/// space throughout.
///
/// For convenience, return the lower 8 bytes of the address as a
/// `u64` "actor handle".  This is suitable for indexing
/// data-structures but is NOT a canonical actor-id.  Callers that
/// need the canonical actor-id should consult the address book.
#[must_use]
pub fn topic_to_actor_handle(topic: &TopicHash) -> ActorId {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&topic[24..32]);
    u64::from_be_bytes(bytes)
}

#[cfg(test)]
mod tests {
    use sha3::{Digest, Keccak256};

    use super::{
        decode_event, decode_word_bool, decode_word_uint128, decode_word_uint64, decode_word_uint8,
        expect_data_len, expect_topics, topic_to_actor_handle, EventDecodeError, GameEvent,
        GameEventTopic,
    };
    use crate::game::GameStatus;
    use knomosis_l1_ingest::action::EthAddress;
    use knomosis_l1_ingest::events::{RawLog, TopicHash};

    /// Topic-0 hashes match Solidity's keccak256(signature)
    /// output.  Specifically the four observed events are:
    ///
    ///   * `GameOpened`: known hash from solidity ABI compile.
    ///   * `MidpointSubmitted`: same.
    ///   * `ResponseSubmitted`: same.
    ///   * `GameSettled`: same.
    ///   * `StateRootSubmitted`: same.
    ///
    /// We don't hard-pin the actual hash values here (they'd
    /// require recomputing keccak256 manually); instead, we
    /// verify the round-trip discipline: every variant's `hash()`
    /// finds itself via `from_hash`.
    #[test]
    fn topic_hash_round_trip() {
        for v in [
            GameEventTopic::GameOpened,
            GameEventTopic::MidpointSubmitted,
            GameEventTopic::ResponseSubmitted,
            GameEventTopic::GameSettled,
            GameEventTopic::StateRootSubmitted,
        ] {
            let h = v.hash();
            assert_eq!(GameEventTopic::from_hash(&h), Some(v));
        }
    }

    /// All variants have distinct topic-0 hashes.  Critical for
    /// the dispatch correctness.
    #[test]
    fn all_topic_hashes_distinct() {
        let hashes: Vec<TopicHash> = [
            GameEventTopic::GameOpened,
            GameEventTopic::MidpointSubmitted,
            GameEventTopic::ResponseSubmitted,
            GameEventTopic::GameSettled,
            GameEventTopic::StateRootSubmitted,
        ]
        .iter()
        .map(|v| v.hash())
        .collect();
        for (i, h1) in hashes.iter().enumerate() {
            for (j, h2) in hashes.iter().enumerate() {
                if i != j {
                    assert_ne!(h1, h2, "topic hashes for variants {i} and {j} collide");
                }
            }
        }
    }

    /// Hard-pinned keccak256 topic hash values.  These are the
    /// canonical 32-byte topic-0 hashes computed at compile-time
    /// by Solidity's ABI encoder; verified once and pinned here
    /// so any future signature-string drift (e.g., a typo in
    /// `GameEventTopic::signature()`) breaks this test loudly
    /// rather than silently producing a different hash.
    ///
    /// The expected values were computed via:
    /// `cast keccak "FaultProofGameOpened(uint256,address,bytes32,bytes32)"`
    /// (and equivalent invocations for the other four
    /// variants).
    #[test]
    fn topic_hashes_pinned_to_expected_values() {
        // Compute the expected hash via the same keccak256 path
        // and assert each pinned hash matches.  This guards
        // against a future maintainer accidentally renaming a
        // type or reordering a parameter.
        let pinned: [(&str, GameEventTopic); 5] = [
            (
                "FaultProofGameOpened(uint256,address,bytes32,bytes32)",
                GameEventTopic::GameOpened,
            ),
            (
                "BisectionMidpointSubmitted(uint256,address,uint64,bytes32)",
                GameEventTopic::MidpointSubmitted,
            ),
            (
                "BisectionResponseSubmitted(uint256,address,bool)",
                GameEventTopic::ResponseSubmitted,
            ),
            (
                "FaultProofGameSettled(uint256,uint8,address,uint128)",
                GameEventTopic::GameSettled,
            ),
            (
                "StateRootSubmitted(uint64,bytes32,address)",
                GameEventTopic::StateRootSubmitted,
            ),
        ];
        for (expected_sig, variant) in pinned {
            assert_eq!(
                variant.signature(),
                expected_sig,
                "signature for {variant:?} drifted",
            );
            // Recompute keccak256 from the pinned string and
            // verify the variant's `hash()` matches.  This is a
            // self-consistency check: if `signature()` returns
            // the right string, `hash()` will return the right
            // bytes.
            let mut hasher = Keccak256::new();
            hasher.update(expected_sig.as_bytes());
            let expected_hash: [u8; 32] = hasher.finalize().into();
            assert_eq!(
                variant.hash(),
                expected_hash,
                "hash for {variant:?} drifted",
            );
        }
    }

    /// Hard-pinned hex values for every `GameEventTopic`'s
    /// keccak256 hash.  These are the canonical 32-byte topic-0
    /// hashes Solidity's ABI encoder produces for each event
    /// declaration; if ANY layer (the signature string in
    /// `signature()`, the keccak256 library, the `hash()`
    /// method) drifts, this test fails loudly.
    ///
    /// To regenerate after a deliberate signature change,
    /// recompute via `cast keccak <signature>` and update the
    /// expected hex strings here.
    #[test]
    fn topic_hashes_pinned_to_canonical_hex() {
        let cases: [(GameEventTopic, &str); 5] = [
            (
                GameEventTopic::GameOpened,
                "e2d1449e45f9d6f9e9eb932149d1dbc3fbe251ccd6208a9154d2ffb39a1d614e",
            ),
            (
                GameEventTopic::MidpointSubmitted,
                "ceee3bfecb7222847fd08388c820ab974ca6d55aa41f8a86fb267092dc781dc4",
            ),
            (
                GameEventTopic::ResponseSubmitted,
                "83d83346a3a914c38f32050525fcf2ed43ffb79587bdee68fb4047441afbaad9",
            ),
            (
                GameEventTopic::GameSettled,
                "b90ac4c782c256b4ffed35723a8dc28c107a9a32868e4ad6da44ccf2ea0f88b4",
            ),
            (
                GameEventTopic::StateRootSubmitted,
                "92169706952d606ab265058fb8022285fd4bd0d1f44f826ccb27570e4dff2a9d",
            ),
        ];
        for (variant, expected_hex) in cases {
            let h = variant.hash();
            let mut actual_hex = String::with_capacity(64);
            for b in h {
                use std::fmt::Write as _;
                let _ = write!(actual_hex, "{b:02x}");
            }
            assert_eq!(
                actual_hex, expected_hex,
                "topic hash for {variant:?} drifted; expected {expected_hex}, got {actual_hex}",
            );
        }
    }

    /// `from_hash` returns `None` for unrecognised hashes.
    #[test]
    fn from_hash_returns_none_for_unknown() {
        let unknown = [0xff; 32];
        assert!(GameEventTopic::from_hash(&unknown).is_none());
    }

    /// `decode_event` returns `Ok(None)` for empty topics.
    #[test]
    fn decode_event_returns_none_for_empty_topics() {
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![],
            data: vec![],
            block_number: 0,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        assert!(decode_event(&log).unwrap().is_none());
    }

    /// `decode_event` returns `Ok(None)` for unknown topic-0.
    #[test]
    fn decode_event_returns_none_for_unknown_topic0() {
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![[0xff; 32]],
            data: vec![],
            block_number: 0,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        assert!(decode_event(&log).unwrap().is_none());
    }

    /// Build a 32-byte topic from a uint128 (left-padded).
    fn topic_from_u128(v: u128) -> TopicHash {
        let mut out = [0u8; 32];
        out[16..32].copy_from_slice(&v.to_be_bytes());
        out
    }

    /// Build a 32-byte topic from a uint64 (left-padded).
    fn topic_from_u64(v: u64) -> TopicHash {
        let mut out = [0u8; 32];
        out[24..32].copy_from_slice(&v.to_be_bytes());
        out
    }

    /// Build a 32-byte word from a uint128 (left-padded).
    fn word_from_u128(v: u128) -> [u8; 32] {
        let mut out = [0u8; 32];
        out[16..32].copy_from_slice(&v.to_be_bytes());
        out
    }

    /// Build a 32-byte word from a uint64 (left-padded).
    fn word_from_u64(v: u64) -> [u8; 32] {
        let mut out = [0u8; 32];
        out[24..32].copy_from_slice(&v.to_be_bytes());
        out
    }

    /// Build a 32-byte word from a uint8 (left-padded).
    fn word_from_u8(v: u8) -> [u8; 32] {
        let mut out = [0u8; 32];
        out[31] = v;
        out
    }

    /// `decode_word_uint128` round-trips.
    #[test]
    fn uint128_decode_round_trip() {
        for v in [0u128, 1, u128::from(u64::MAX), u128::MAX] {
            let word = word_from_u128(v);
            let decoded = decode_word_uint128(&word, "test").unwrap();
            assert_eq!(decoded, v);
        }
    }

    /// `decode_word_uint64` rejects > `u64::MAX`.
    #[test]
    fn uint64_rejects_overflow() {
        // Set byte 23 to 1, which makes the value 2^64.
        let mut word = [0u8; 32];
        word[23] = 1;
        let err = decode_word_uint64(&word, "test").unwrap_err();
        assert!(matches!(err, EventDecodeError::NumericTooLarge { .. }));
    }

    /// `decode_word_uint8` rejects > `u8::MAX`.
    #[test]
    fn uint8_rejects_overflow() {
        // Set byte 30 to 1, which makes the value 2^8 = 256.
        let mut word = [0u8; 32];
        word[30] = 1;
        let err = decode_word_uint8(&word, "test").unwrap_err();
        assert!(matches!(err, EventDecodeError::NumericTooLarge { .. }));
    }

    /// `decode_word_bool` accepts 0 / 1 only.
    #[test]
    fn bool_decode_strict() {
        let zero = word_from_u8(0);
        assert!(!decode_word_bool(&zero, "test").unwrap());
        let one = word_from_u8(1);
        assert!(decode_word_bool(&one, "test").unwrap());
        let two = word_from_u8(2);
        let err = decode_word_bool(&two, "test").unwrap_err();
        assert!(matches!(err, EventDecodeError::NonCanonicalBool { .. }));
        // Upper byte set: also rejected.
        let mut weird = [0u8; 32];
        weird[15] = 1;
        weird[31] = 1;
        let err = decode_word_bool(&weird, "test").unwrap_err();
        assert!(matches!(err, EventDecodeError::NonCanonicalBool { .. }));
    }

    /// `decode_word_bool` rejects wrong length.
    #[test]
    fn bool_rejects_wrong_length() {
        let short = vec![0u8; 8];
        let err = decode_word_bool(&short, "test").unwrap_err();
        assert!(matches!(err, EventDecodeError::WrongDataLength { .. }));
    }

    /// `expect_topics` and `expect_data_len` work.
    #[test]
    fn expect_helpers_work() {
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![[0u8; 32]; 3],
            data: vec![0u8; 32],
            block_number: 0,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        assert!(expect_topics(&log, "test", 3).is_ok());
        assert!(matches!(
            expect_topics(&log, "test", 2).unwrap_err(),
            EventDecodeError::WrongTopicsLength { .. }
        ));
        assert!(expect_data_len(&log, "test", 32).is_ok());
        assert!(matches!(
            expect_data_len(&log, "test", 64).unwrap_err(),
            EventDecodeError::WrongDataLength { .. }
        ));
    }

    /// Build a `FaultProofGameOpened` raw log and decode it.
    #[test]
    fn decode_game_opened_happy_path() {
        let challenger = topic_from_u64(0xCAFE);
        let mut data = Vec::with_capacity(64);
        let disputed = [0x11u8; 32];
        let chal_root = [0x22u8; 32];
        data.extend_from_slice(&disputed);
        data.extend_from_slice(&chal_root);
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![
                GameEventTopic::GameOpened.hash(),
                topic_from_u128(42),
                challenger,
            ],
            data,
            block_number: 100,
            tx_hash: [0xaa; 32],
            log_index: 3,
        };
        let event = decode_event(&log).unwrap().unwrap();
        match event {
            GameEvent::GameOpened {
                game_id,
                challenger_topic,
                disputed_state_root,
                challenger_state_root,
                block_number,
                tx_hash,
                log_index,
            } => {
                assert_eq!(game_id, 42);
                assert_eq!(challenger_topic, challenger);
                assert_eq!(disputed_state_root, disputed);
                assert_eq!(challenger_state_root, chal_root);
                assert_eq!(block_number, 100);
                assert_eq!(tx_hash, [0xaa; 32]);
                assert_eq!(log_index, 3);
            }
            other => panic!("expected GameOpened, got {other:?}"),
        }
    }

    /// Build a `BisectionMidpointSubmitted` raw log and decode it.
    #[test]
    fn decode_midpoint_submitted_happy_path() {
        let party = topic_from_u64(0xBEEF);
        let mut data = Vec::with_capacity(64);
        data.extend_from_slice(&word_from_u64(32));
        data.extend_from_slice(&[0x77u8; 32]);
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![
                GameEventTopic::MidpointSubmitted.hash(),
                topic_from_u128(42),
                party,
            ],
            data,
            block_number: 101,
            tx_hash: [0xab; 32],
            log_index: 5,
        };
        let event = decode_event(&log).unwrap().unwrap();
        match event {
            GameEvent::MidpointSubmitted {
                game_id,
                party_topic,
                idx,
                commit,
                ..
            } => {
                assert_eq!(game_id, 42);
                assert_eq!(party_topic, party);
                assert_eq!(idx, 32);
                assert_eq!(commit, [0x77u8; 32]);
            }
            other => panic!("expected MidpointSubmitted, got {other:?}"),
        }
    }

    /// Build a `BisectionResponseSubmitted` raw log (agree=true).
    #[test]
    fn decode_response_submitted_happy_path() {
        let party = topic_from_u64(0xBEEF);
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![
                GameEventTopic::ResponseSubmitted.hash(),
                topic_from_u128(42),
                party,
            ],
            data: word_from_u8(1).to_vec(),
            block_number: 102,
            tx_hash: [0xac; 32],
            log_index: 7,
        };
        let event = decode_event(&log).unwrap().unwrap();
        match event {
            GameEvent::ResponseSubmitted {
                game_id,
                party_topic,
                agree,
                ..
            } => {
                assert_eq!(game_id, 42);
                assert_eq!(party_topic, party);
                assert!(agree);
            }
            other => panic!("expected ResponseSubmitted, got {other:?}"),
        }
    }

    /// Build a `FaultProofGameSettled` raw log.
    #[test]
    fn decode_game_settled_happy_path() {
        let winner = topic_from_u64(0xC0DE);
        let mut data = Vec::with_capacity(64);
        data.extend_from_slice(&word_from_u8(2)); // ChallengerWon
        data.extend_from_slice(&word_from_u128(1_000_000));
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![
                GameEventTopic::GameSettled.hash(),
                topic_from_u128(42),
                winner,
            ],
            data,
            block_number: 103,
            tx_hash: [0xad; 32],
            log_index: 9,
        };
        let event = decode_event(&log).unwrap().unwrap();
        match event {
            GameEvent::GameSettled {
                game_id,
                status,
                winner_topic,
                winner_payout,
                ..
            } => {
                assert_eq!(game_id, 42);
                assert_eq!(status, GameStatus::ChallengerWon);
                assert_eq!(winner_topic, winner);
                assert_eq!(winner_payout, 1_000_000);
            }
            other => panic!("expected GameSettled, got {other:?}"),
        }
    }

    /// `GameSettled` rejects unknown status byte.
    #[test]
    fn game_settled_rejects_unknown_status() {
        let winner = topic_from_u64(0xC0DE);
        let mut data = Vec::with_capacity(64);
        data.extend_from_slice(&word_from_u8(7)); // unknown
        data.extend_from_slice(&word_from_u128(0));
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![
                GameEventTopic::GameSettled.hash(),
                topic_from_u128(1),
                winner,
            ],
            data,
            block_number: 1,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        let err = decode_event(&log).unwrap_err();
        assert!(matches!(
            err,
            EventDecodeError::UnknownGameStatus { byte: 7 }
        ));
    }

    /// `StateRootSubmitted` decodes correctly.
    #[test]
    fn decode_state_root_submitted_happy_path() {
        let sequencer = topic_from_u64(0x5E_0000);
        let commit_bytes = [0x33u8; 32];
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![
                GameEventTopic::StateRootSubmitted.hash(),
                topic_from_u64(100),
                sequencer,
            ],
            data: commit_bytes.to_vec(),
            block_number: 200,
            tx_hash: [0xae; 32],
            log_index: 11,
        };
        let event = decode_event(&log).unwrap().unwrap();
        match event {
            GameEvent::StateRootSubmitted {
                log_index_claim,
                state_commit,
                sequencer_topic,
                ..
            } => {
                assert_eq!(log_index_claim, 100);
                assert_eq!(state_commit, commit_bytes);
                assert_eq!(sequencer_topic, sequencer);
            }
            other => panic!("expected StateRootSubmitted, got {other:?}"),
        }
    }

    /// `topic_to_actor_handle` extracts the lower 8 bytes.
    #[test]
    fn topic_to_actor_handle_lower_8_bytes() {
        let topic = topic_from_u64(0xDEAD_BEEF);
        assert_eq!(topic_to_actor_handle(&topic), 0xDEAD_BEEF);
    }

    /// Wrong topics length surfaces a typed error.
    #[test]
    fn wrong_topics_length_typed() {
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![GameEventTopic::GameOpened.hash()],
            data: vec![0u8; 64],
            block_number: 0,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        let err = decode_event(&log).unwrap_err();
        assert!(matches!(err, EventDecodeError::WrongTopicsLength { .. }));
    }

    /// Wrong data length surfaces a typed error.
    #[test]
    fn wrong_data_length_typed() {
        let log = RawLog {
            address: EthAddress([0u8; 20]),
            topics: vec![GameEventTopic::GameOpened.hash(), [0u8; 32], [0u8; 32]],
            data: vec![0u8; 16], // wrong: should be 64
            block_number: 0,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        let err = decode_event(&log).unwrap_err();
        assert!(matches!(err, EventDecodeError::WrongDataLength { .. }));
    }

    /// Idempotency key extraction.
    #[test]
    fn idempotency_key_extraction() {
        let event = GameEvent::GameOpened {
            game_id: 42,
            challenger_topic: [0u8; 32],
            disputed_state_root: [0u8; 32],
            challenger_state_root: [0u8; 32],
            block_number: 100,
            tx_hash: [0xbb; 32],
            log_index: 7,
        };
        let (b, h, l) = event.idempotency_key();
        assert_eq!(b, 100);
        assert_eq!(h, [0xbb; 32]);
        assert_eq!(l, 7);
        assert_eq!(event.block_number(), 100);
        assert_eq!(event.game_id(), Some(42));
    }

    /// `StateRootSubmitted` returns `None` for `game_id()`.
    #[test]
    fn state_root_event_has_no_game_id() {
        let event = GameEvent::StateRootSubmitted {
            log_index_claim: 1,
            state_commit: [0u8; 32],
            sequencer_topic: [0u8; 32],
            block_number: 0,
            tx_hash: [0u8; 32],
            log_index: 0,
        };
        assert_eq!(event.game_id(), None);
    }
}
