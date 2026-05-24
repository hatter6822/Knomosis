// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `knomosis-storage`-backed persistence layer for the observer.
//!
//! ## Schema
//!
//! Three keyspaces co-exist in a single knomosis-storage database:
//!
//! ```text
//! key prefix          | content                                     | format
//! --------------------+---------------------------------------------+----------------------
//! "g/" + gameId(16BE) | GameRecord (game state + observer metadata) | JSON
//! "r/" + txhash(32)   | ResponseRecord (submitted-tx tracking)      | JSON
//! "w/cursor"          | Last-processed L1 block                     | 8-byte BE u64
//! "w/identifier"      | Observer identifier string                   | UTF-8
//! ```
//!
//! The prefixes use distinct first bytes so a `scan(b"g/")`
//! enumerates only games without touching response records or
//! cursor.  This mirrors `knomosis-indexer`'s layout discipline.
//!
//! ## Atomic update boundary
//!
//! Every game-state update is committed atomically with the
//! watcher cursor advance via a single `Storage::transaction`.
//! On any error mid-batch, the transaction rolls back; the
//! cursor does NOT advance; the watcher's next pass re-delivers
//! the failing event.  This mirrors `knomosis-indexer`'s
//! batch-atomic discipline.
//!
//! ## Idempotency
//!
//! On startup, the observer reads the cursor + every game record
//! whose status is `InProgress`.  It re-subscribes to L1 from
//! `cursor + 1`; any events the L1 source replays that are
//! already reflected in the persisted game state are detected as
//! no-ops at the game-state-machine level (e.g., applying a
//! `RespondAgree` to a game whose pending midpoint is already
//! `None` returns `ResponseDuringSubmit`, which the watcher logs
//! and discards).
//!
//! ## Identifier discipline
//!
//! `w/identifier` is written on first open.  On subsequent
//! opens, the persistence layer reads the cell and rejects a
//! mismatch with the binary's `OBSERVER_IDENTIFIER` constant.
//! This defends against a deployment accidentally opening a
//! database written by a different observer (e.g., knomosis-indexer
//! sharing the same `SQLite` file by mistake).

use std::path::Path;

use knomosis_storage::sqlite::{SqliteOpenOptions, SqliteStorage};
use knomosis_storage::storage::{Storage, StorageError};
use serde::{Deserialize, Serialize};

use crate::game::{GameState, TurnSide};

/// Identifier the observer writes to its database on first open.
/// Bumped if the storage layout changes incompatibly.
pub const OBSERVER_IDENTIFIER: &str = "knomosis-faultproof-observer/v1";

/// Cursor cell key: 8-byte BE u64 of the last-processed L1 block.
pub const CURSOR_KEY: &[u8] = b"w/cursor";

/// Identifier cell key.
pub const IDENTIFIER_KEY: &[u8] = b"w/identifier";

/// Re-org window cell key.  Holds a serialised
/// `Vec<BlockHeader>` (JSON for now) of the recent block-hash
/// window, so on restart the observer can resume re-org
/// detection from the persisted window head rather than starting
/// from an empty window.  Per the original RH-G.2 plan:
/// "Persist watcher state (last-processed block, recent
/// block-hash window) in `knomosis-storage`".
pub const REORG_WINDOW_KEY: &[u8] = b"w/reorg_window";

/// Key prefix for game records.
pub const GAME_PREFIX: &[u8] = b"g/";

/// Key prefix for response records.
pub const RESPONSE_PREFIX: &[u8] = b"r/";

/// One persisted game record.  Carries the full game state plus
/// per-game observer metadata (last-observed L1 block, the side
/// we're playing).
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct GameRecord {
    /// The game's id (matches the L1 contract's `gameId`).
    pub game_id: u128,
    /// The full game state mirrored from the L1 contract.
    pub state: GameState,
    /// Which side this observer is playing (in production, the
    /// challenger; tests may swap).
    pub me: TurnSide,
    /// L1 block number when this record was last updated.
    pub last_updated_block: u64,
    /// True iff the observer knows the **full** game state (the
    /// `low.idx` and `high.idx` range bounds, the sequencer /
    /// challenger actor ids, the bond amounts).  The `FaultProofGameOpened`
    /// event carries only the disputed state roots, not the full
    /// game state; production deployments learn the full state
    /// via an `eth_call` to `games(uint256)` on the contract,
    /// which is deferred RH-G follow-up work.
    ///
    /// When `state_known == false`, the orchestrator's
    /// `maybe_play_move` refuses to compute or submit moves for
    /// this game.  The game record IS still persisted + updated
    /// from observed events (so `compute_next_move`'s eventual
    /// run produces correct results once the full state is
    /// learned), but no calldata is submitted in the interim.
    ///
    /// Default `false` for serde backward-compatibility with
    /// pre-v0.2.3 game records (which had no such field).
    #[serde(default)]
    pub state_known: bool,
}

/// One persisted response-submission record.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ResponseRecord {
    /// The L1 transaction hash (32 bytes, hex-encoded for JSON
    /// portability).  Canonicalised by `store_response` to
    /// lowercase + no `0x` prefix.
    pub tx_hash_hex: String,
    /// The serialized signed transaction bytes, hex-encoded.
    /// Stored so a crashed observer can RE-BROADCAST on
    /// restart (the L1 RPC's `eth_sendRawTransaction` is
    /// idempotent at the `tx_hash` level).  Closes the
    /// audit-pass-3 H-1 gap where the previous design persisted
    /// only the `tx_hash`, making re-broadcast impossible.
    ///
    /// `None` for pre-`raw_tx_hex` records (loaded with
    /// `#[serde(default)]` from old persisted state).
    #[serde(default)]
    pub raw_tx_hex: Option<String>,
    /// The game id this response is part of.
    pub game_id: u128,
    /// The submission status.
    pub status: ResponseStatus,
    /// L1 block number where the tx was submitted.
    pub submitted_at_block: u64,
    /// Optional response-specific bookkeeping (e.g. the depth at
    /// which this response was made).
    pub depth: u32,
    /// The bisection pivot index this response covers (used by
    /// the idempotency check "have we already submitted at this
    /// pivot?").
    pub pivot_idx: Option<u64>,
}

/// Serializable mirror of `knomosis_l1_ingest::reorg::BlockHeader`
/// — the upstream type doesn't derive serde, so we mirror it
/// here for the persisted re-org window.  The fields are
/// 1:1 with the upstream type; round-trip via the [`From`]
/// impls below.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PersistedHeader {
    /// L1 block number.
    pub number: u64,
    /// 32-byte block hash (hex-string-friendly via serde).
    pub hash: [u8; 32],
    /// The parent block's 32-byte hash.
    pub parent_hash: [u8; 32],
}

impl From<knomosis_l1_ingest::reorg::BlockHeader> for PersistedHeader {
    fn from(h: knomosis_l1_ingest::reorg::BlockHeader) -> Self {
        Self {
            number: h.number,
            hash: h.hash,
            parent_hash: h.parent_hash,
        }
    }
}

impl From<PersistedHeader> for knomosis_l1_ingest::reorg::BlockHeader {
    fn from(p: PersistedHeader) -> Self {
        Self {
            number: p.number,
            hash: p.hash,
            parent_hash: p.parent_hash,
        }
    }
}

/// Submission status.
///
/// State transitions:
///
/// ```text
///   ┌────────────┐ broadcast    ┌────────────┐ confirm  ┌────────────┐
///   │ Intent     │─────────────▶│ Pending    │─────────▶│ Confirmed  │
///   └────────────┘   success    └────────────┘   incl.  └────────────┘
///         │                            │
///         │ broadcast error            │ dropped (re-org / timeout)
///         ▼                            ▼
///   ┌────────────┐                ┌────────────┐
///   │ Failed     │                │ Dropped    │── re-broadcast ───▶ (back to Pending)
///   └────────────┘                └────────────┘
/// ```
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ResponseStatus {
    /// **Pre-broadcast intent.**  The observer has built and
    /// signed the transaction and persisted the record; it has
    /// NOT yet been broadcast to L1.  Set during the
    /// audit-pass-3 H-1 pre-submit-intent persist step.  Cleared
    /// to `Pending` after the broadcast succeeds, or to
    /// `Failed` if the broadcast errors.
    ///
    /// On a crashed-mid-broadcast restart, records in `Intent`
    /// status are re-broadcast (the L1 RPC's
    /// `eth_sendRawTransaction` is idempotent at the `tx_hash`
    /// level).
    Intent,
    /// Pending — broadcast OK, not yet confirmed.
    Pending,
    /// Confirmed at N blocks.
    Confirmed,
    /// Dropped — submitter detected a re-org or timeout.  Caller
    /// re-submits with bumped gas.
    Dropped,
    /// Failed — irrecoverable submission error.
    Failed,
}

/// Errors specific to the persistence layer.
#[allow(clippy::module_name_repetitions)]
#[derive(Debug, thiserror::Error)]
pub enum PersistenceError {
    /// Underlying storage error.
    #[error(transparent)]
    Storage(#[from] StorageError),

    /// JSON serialisation / deserialisation error.
    #[error("JSON error: {0}")]
    Json(String),

    /// Identifier mismatch: the database was written by a
    /// different observer or different version.
    #[error("identifier mismatch: expected '{expected}', found '{found}'")]
    IdentifierMismatch {
        /// The expected identifier (the binary's
        /// `OBSERVER_IDENTIFIER` constant).
        expected: String,
        /// The identifier read from the database.
        found: String,
    },

    /// Cursor cell exists but is not 8 bytes.
    #[error("cursor cell malformed: expected 8 bytes, got {got}")]
    CursorMalformed {
        /// Length read from the cell.
        got: usize,
    },

    /// A game-record key did not have the expected
    /// "g/<16-byte BE>" shape.
    #[error("game key malformed: expected 'g/<16-byte BE>', got {got_len} bytes")]
    GameKeyMalformed {
        /// The malformed key's length.
        got_len: usize,
    },
}

impl From<serde_json::Error> for PersistenceError {
    fn from(e: serde_json::Error) -> Self {
        Self::Json(e.to_string())
    }
}

/// Persistence handle wrapping the knomosis-storage layer.
#[derive(Debug)]
pub struct Persistence {
    storage: SqliteStorage,
}

impl Persistence {
    /// Open or create the observer's storage at `db_path`.  On
    /// first open, writes the `IDENTIFIER_KEY` cell.  On
    /// subsequent opens, verifies the identifier matches.
    ///
    /// # Errors
    ///
    /// Returns [`PersistenceError::Storage`] on I/O failure,
    /// [`PersistenceError::IdentifierMismatch`] if the database
    /// was written by a different observer.
    pub fn open(db_path: &Path) -> Result<Self, PersistenceError> {
        let storage = SqliteStorage::open_with_options(db_path, &SqliteOpenOptions::default())?;
        let p = Self { storage };
        p.verify_or_initialise_identifier()?;
        Ok(p)
    }

    /// Read the identifier cell.  If present, verify it matches
    /// `OBSERVER_IDENTIFIER`.  If absent AND the DB contains no
    /// observer cells, write the identifier (genuinely fresh
    /// DB).  If absent AND any observer cells exist, fail loudly
    /// — the DB was written by something else or got
    /// partially-corrupted and silently adopting it could mingle
    /// data with another daemon's state.
    ///
    /// Audit-pass-4-round-5 HIGH fix: previously the "identifier
    /// absent" path unconditionally wrote the identifier and
    /// proceeded, silently adopting orphan databases (operator
    /// typo pointing at another tool's DB; partial-crash
    /// corruption).
    fn verify_or_initialise_identifier(&self) -> Result<(), PersistenceError> {
        if let Some(bytes) = self.storage.get(IDENTIFIER_KEY)? {
            let found = String::from_utf8(bytes).map_err(|e| {
                PersistenceError::Storage(StorageError::Other(format!(
                    "identifier cell not UTF-8: {e}"
                )))
            })?;
            if found != OBSERVER_IDENTIFIER {
                return Err(PersistenceError::IdentifierMismatch {
                    expected: OBSERVER_IDENTIFIER.to_string(),
                    found,
                });
            }
            Ok(())
        } else {
            // Identifier absent.  Confirm the DB is empty (no
            // observer cells).  If ANY observer cell exists, the
            // DB was written by something else or partially
            // corrupted — fail loudly rather than silently adopt.
            let has_games = !self.storage.scan(GAME_PREFIX)?.is_empty();
            let has_responses = !self.storage.scan(RESPONSE_PREFIX)?.is_empty();
            let has_cursor = self.storage.get(CURSOR_KEY)?.is_some();
            let has_reorg = self.storage.get(REORG_WINDOW_KEY)?.is_some();
            if has_games || has_responses || has_cursor || has_reorg {
                return Err(PersistenceError::IdentifierMismatch {
                    expected: OBSERVER_IDENTIFIER.to_string(),
                    found: format!(
                        "<absent; DB contains observer cells without identifier: \
                         games={has_games}, responses={has_responses}, \
                         cursor={has_cursor}, reorg={has_reorg}>"
                    ),
                });
            }
            // Genuinely fresh DB: write the identifier.
            self.storage
                .put(IDENTIFIER_KEY, OBSERVER_IDENTIFIER.as_bytes())?;
            Ok(())
        }
    }

    /// Read the last-processed L1 block number from the cursor
    /// cell.  Returns `None` if the cursor has never been set.
    ///
    /// # Errors
    ///
    /// Returns [`PersistenceError::CursorMalformed`] if the cell
    /// exists but is not 8 bytes; [`PersistenceError::Storage`]
    /// on I/O failure.
    pub fn read_cursor(&self) -> Result<Option<u64>, PersistenceError> {
        match self.storage.get(CURSOR_KEY)? {
            None => Ok(None),
            Some(bytes) => {
                if bytes.len() != 8 {
                    return Err(PersistenceError::CursorMalformed { got: bytes.len() });
                }
                let mut out = [0u8; 8];
                out.copy_from_slice(&bytes);
                Ok(Some(u64::from_be_bytes(out)))
            }
        }
    }

    /// Write the cursor cell.  Used by tests directly; production
    /// always batches the cursor write with game-state updates
    /// inside a single transaction (see [`Self::commit_batch`]).
    ///
    /// # Errors
    ///
    /// See [`PersistenceError`].
    pub fn write_cursor(&self, block: u64) -> Result<(), PersistenceError> {
        self.storage
            .put(CURSOR_KEY, &block.to_be_bytes())
            .map_err(Into::into)
    }

    /// Read the persisted re-org window headers.  Returns an
    /// empty `Vec` if no window has been persisted yet (fresh
    /// observer).
    ///
    /// # Errors
    ///
    /// Returns [`PersistenceError::Storage`] on I/O failure or
    /// [`PersistenceError::Json`] on a corrupted cell.
    pub fn read_reorg_window(&self) -> Result<Vec<PersistedHeader>, PersistenceError> {
        match self.storage.get(REORG_WINDOW_KEY)? {
            None => Ok(Vec::new()),
            Some(bytes) => {
                // Audit-pass-4-round-5 HIGH defence: cap the
                // pre-deserialization byte size to prevent OOM
                // from a corrupted or tampered cell.  A
                // PersistedHeader is ~200 bytes JSON-encoded;
                // the cap at MAX_REORG_WINDOW_CAPACITY * 1 KiB
                // gives 4 MiB at the hard upper bound — well
                // over any legitimate use, but bounded.
                const MAX_REORG_CELL_BYTES: usize =
                    crate::watcher::MAX_REORG_WINDOW_CAPACITY * 1024;
                if bytes.len() > MAX_REORG_CELL_BYTES {
                    return Err(PersistenceError::Storage(StorageError::Other(format!(
                        "reorg window cell oversize: {} bytes (cap {MAX_REORG_CELL_BYTES})",
                        bytes.len()
                    ))));
                }
                let headers: Vec<PersistedHeader> = serde_json::from_slice(&bytes)?;
                // Defence-in-depth: cap deserialized count too.
                if headers.len() > crate::watcher::MAX_REORG_WINDOW_CAPACITY {
                    return Err(PersistenceError::Storage(StorageError::Other(format!(
                        "reorg window contains {} headers; cap {}",
                        headers.len(),
                        crate::watcher::MAX_REORG_WINDOW_CAPACITY,
                    ))));
                }
                Ok(headers)
            }
        }
    }

    /// Write the re-org window headers.  Production code paths
    /// fold this into the `commit_batch` atomic write (via
    /// [`PersistBatch::set_reorg_window`]) so the cursor + the
    /// window advance atomically.  This helper is for direct
    /// test access only.
    ///
    /// # Errors
    ///
    /// See [`PersistenceError`].
    pub fn write_reorg_window(&self, headers: &[PersistedHeader]) -> Result<(), PersistenceError> {
        let bytes = serde_json::to_vec(headers)?;
        self.storage
            .put(REORG_WINDOW_KEY, &bytes)
            .map_err(Into::into)
    }

    /// Load a game record by id.
    ///
    /// # Errors
    ///
    /// See [`PersistenceError`].
    pub fn load_game(&self, game_id: u128) -> Result<Option<GameRecord>, PersistenceError> {
        let key = game_key(game_id);
        match self.storage.get(&key)? {
            None => Ok(None),
            Some(bytes) => {
                let rec: GameRecord = serde_json::from_slice(&bytes)?;
                Ok(Some(rec))
            }
        }
    }

    /// Store a game record.  Production code uses
    /// [`Self::commit_batch`] instead; this helper exists for
    /// tests.
    ///
    /// # Errors
    ///
    /// See [`PersistenceError`].
    pub fn store_game(&self, rec: &GameRecord) -> Result<(), PersistenceError> {
        let key = game_key(rec.game_id);
        let bytes = serde_json::to_vec(rec)?;
        self.storage.put(&key, &bytes).map_err(Into::into)
    }

    /// Enumerate every game record currently in storage.  Used at
    /// startup to rebuild the in-memory game map.
    ///
    /// # Errors
    ///
    /// See [`PersistenceError`].
    pub fn list_games(&self) -> Result<Vec<GameRecord>, PersistenceError> {
        let pairs = self.storage.scan(GAME_PREFIX)?;
        let mut out = Vec::with_capacity(pairs.len());
        for (_key, value) in pairs {
            let rec: GameRecord = serde_json::from_slice(&value)?;
            out.push(rec);
        }
        Ok(out)
    }

    /// Load a response record by tx-hash.
    ///
    /// # Errors
    ///
    /// See [`PersistenceError`].
    pub fn load_response(
        &self,
        tx_hash: &[u8; 32],
    ) -> Result<Option<ResponseRecord>, PersistenceError> {
        let key = response_key(tx_hash);
        match self.storage.get(&key)? {
            None => Ok(None),
            Some(bytes) => {
                let rec: ResponseRecord = serde_json::from_slice(&bytes)?;
                Ok(Some(rec))
            }
        }
    }

    /// Store a response record.
    ///
    /// # Errors
    ///
    /// See [`PersistenceError`].
    pub fn store_response(&self, rec: &ResponseRecord) -> Result<(), PersistenceError> {
        let tx_hash_bytes = parse_hex_tx_hash(&rec.tx_hash_hex)?;
        let key = response_key(&tx_hash_bytes);
        // Canonicalise the JSON-stored `tx_hash_hex` to the
        // round-trip form (lowercase, no `0x` prefix) so that
        // two writes for the same hash with different surface
        // formats don't produce two distinct JSON payloads
        // pointing at the same key.
        let canonical_rec = ResponseRecord {
            tx_hash_hex: hex::encode(tx_hash_bytes),
            ..rec.clone()
        };
        let bytes = serde_json::to_vec(&canonical_rec)?;
        self.storage.put(&key, &bytes).map_err(Into::into)
    }

    /// Enumerate every response record currently in storage.
    ///
    /// # Errors
    ///
    /// See [`PersistenceError`].
    pub fn list_responses(&self) -> Result<Vec<ResponseRecord>, PersistenceError> {
        let pairs = self.storage.scan(RESPONSE_PREFIX)?;
        let mut out = Vec::with_capacity(pairs.len());
        for (_key, value) in pairs {
            let rec: ResponseRecord = serde_json::from_slice(&value)?;
            out.push(rec);
        }
        Ok(out)
    }

    /// Commit a batch of game / response updates + a cursor
    /// advance atomically.  This is the load-bearing
    /// "either-everything-or-nothing" boundary the watcher uses
    /// after processing each L1 block batch.
    ///
    /// # Errors
    ///
    /// See [`PersistenceError`].
    pub fn commit_batch(&self, batch: &PersistBatch) -> Result<(), PersistenceError> {
        let mut tx = self.storage.transaction()?;
        for rec in &batch.games {
            let key = game_key(rec.game_id);
            let value = serde_json::to_vec(rec)?;
            tx.put(&key, &value)?;
        }
        for rec in &batch.responses {
            let tx_hash_bytes = parse_hex_tx_hash(&rec.tx_hash_hex)?;
            let key = response_key(&tx_hash_bytes);
            // Canonicalise stored hex; see `store_response` for
            // rationale.
            let canonical_rec = ResponseRecord {
                tx_hash_hex: hex::encode(tx_hash_bytes),
                ..rec.clone()
            };
            let value = serde_json::to_vec(&canonical_rec)?;
            tx.put(&key, &value)?;
        }
        if let Some(cursor) = batch.cursor {
            tx.put(CURSOR_KEY, &cursor.to_be_bytes())?;
        }
        if let Some(headers) = &batch.reorg_window {
            let bytes = serde_json::to_vec(headers)?;
            tx.put(REORG_WINDOW_KEY, &bytes)?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Read accessor for the underlying storage handle.  Tests
    /// only.
    #[cfg(test)]
    pub(crate) fn storage(&self) -> &SqliteStorage {
        &self.storage
    }
}

/// A batched persistence update.  Construct, push updates, then
/// commit.
#[derive(Clone, Debug, Default)]
pub struct PersistBatch {
    /// Game records to upsert.
    pub games: Vec<GameRecord>,
    /// Response records to upsert.
    pub responses: Vec<ResponseRecord>,
    /// New cursor value (or `None` to leave the cursor alone).
    pub cursor: Option<u64>,
    /// New re-org window snapshot (or `None` to leave the
    /// persisted window unchanged).  The watcher folds the
    /// current window state into the batch each iteration so
    /// the cursor + window advance atomically.
    pub reorg_window: Option<Vec<PersistedHeader>>,
}

impl PersistBatch {
    /// Construct an empty batch.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Append a game-record upsert.
    pub fn upsert_game(&mut self, rec: GameRecord) {
        self.games.push(rec);
    }

    /// Append a response-record upsert.
    pub fn upsert_response(&mut self, rec: ResponseRecord) {
        self.responses.push(rec);
    }

    /// Set the cursor advance.  If called more than once, the
    /// last call wins.
    pub fn set_cursor(&mut self, block: u64) {
        self.cursor = Some(block);
    }

    /// Set the re-org window snapshot to be persisted alongside
    /// the cursor advance.  If called more than once, the last
    /// call wins.
    pub fn set_reorg_window(&mut self, headers: Vec<PersistedHeader>) {
        self.reorg_window = Some(headers);
    }

    /// True iff the batch carries no updates.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.games.is_empty()
            && self.responses.is_empty()
            && self.cursor.is_none()
            && self.reorg_window.is_none()
    }
}

/// Build the storage key for a game record from its game id.
///
/// Layout: `b"g/" || u128_to_be(game_id)` (2 + 16 = 18 bytes).
fn game_key(game_id: u128) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + 16);
    out.extend_from_slice(GAME_PREFIX);
    out.extend_from_slice(&game_id.to_be_bytes());
    out
}

/// Build the storage key for a response record from its tx-hash.
///
/// Layout: `b"r/" || tx_hash` (2 + 32 = 34 bytes).
fn response_key(tx_hash: &[u8; 32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(2 + 32);
    out.extend_from_slice(RESPONSE_PREFIX);
    out.extend_from_slice(tx_hash);
    out
}

/// Parse a hex-encoded tx-hash into a 32-byte array.
fn parse_hex_tx_hash(hex_str: &str) -> Result<[u8; 32], PersistenceError> {
    let trimmed = hex_str.strip_prefix("0x").unwrap_or(hex_str);
    let bytes = hex::decode(trimmed).map_err(|e| {
        PersistenceError::Storage(StorageError::Other(format!(
            "tx_hash_hex not valid hex: {e}"
        )))
    })?;
    if bytes.len() != 32 {
        return Err(PersistenceError::Storage(StorageError::Other(format!(
            "tx_hash_hex decodes to {} bytes, expected 32",
            bytes.len()
        ))));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::{
        GameRecord, PersistBatch, Persistence, PersistenceError, ResponseRecord, ResponseStatus,
        CURSOR_KEY, GAME_PREFIX, IDENTIFIER_KEY, OBSERVER_IDENTIFIER, RESPONSE_PREFIX,
    };
    use crate::game::{Claim, DisputedRange, GameState, GameStatus, TurnSide};
    use knomosis_storage::storage::Storage;

    /// Build a sample game state.
    fn sample_game(game_id: u128) -> GameRecord {
        GameRecord {
            game_id,
            state: GameState {
                sequencer: 1,
                challenger: 2,
                range: DisputedRange {
                    low: Claim {
                        idx: 0,
                        commit: [1u8; 32],
                    },
                    high: Claim {
                        idx: 64,
                        commit: [2u8; 32],
                    },
                },
                pending_midpoint: None,
                depth: 0,
                turn: TurnSide::Sequencer,
                sequencer_bond: 1_000,
                challenger_bond: 1_000,
                status: GameStatus::InProgress,
                deployment_id: [0u8; 32],
            },
            me: TurnSide::Challenger,
            last_updated_block: 100,
            state_known: true,
        }
    }

    /// Build a sample response record.
    fn sample_response(tx_seed: u8, game_id: u128) -> ResponseRecord {
        let tx_hex = format!("0x{:02x}{}", tx_seed, "0".repeat(62));
        ResponseRecord {
            tx_hash_hex: tx_hex,
            raw_tx_hex: None,
            game_id,
            status: ResponseStatus::Pending,
            submitted_at_block: 100,
            depth: 1,
            pivot_idx: Some(32),
        }
    }

    /// Constants are stable strings.
    #[test]
    fn constants_stable() {
        assert_eq!(OBSERVER_IDENTIFIER, "knomosis-faultproof-observer/v1");
        assert_eq!(GAME_PREFIX, b"g/");
        assert_eq!(RESPONSE_PREFIX, b"r/");
        assert_eq!(CURSOR_KEY, b"w/cursor");
        assert_eq!(IDENTIFIER_KEY, b"w/identifier");
    }

    /// First open writes the identifier; second open verifies.
    #[test]
    fn identifier_first_open_then_verify() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p1 = Persistence::open(&db).unwrap();
        // Read it back via the raw storage interface.
        let ident = p1.storage().get(IDENTIFIER_KEY).unwrap().unwrap();
        assert_eq!(ident, OBSERVER_IDENTIFIER.as_bytes());
        drop(p1);
        // Re-open succeeds.
        let _p2 = Persistence::open(&db).unwrap();
    }

    /// Identifier mismatch surfaces a typed error.
    #[test]
    fn identifier_mismatch_typed_error() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        // Corrupt the identifier cell.
        p.storage()
            .put(IDENTIFIER_KEY, b"some-other-version/v9")
            .unwrap();
        drop(p);
        let err = Persistence::open(&db).unwrap_err();
        assert!(matches!(err, PersistenceError::IdentifierMismatch { .. }));
    }

    /// Cursor round-trips.
    #[test]
    fn cursor_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        // No cursor on fresh DB.
        assert!(p.read_cursor().unwrap().is_none());
        p.write_cursor(12345).unwrap();
        assert_eq!(p.read_cursor().unwrap(), Some(12345));
        // Overwrite.
        p.write_cursor(67890).unwrap();
        assert_eq!(p.read_cursor().unwrap(), Some(67890));
    }

    /// Cursor malformed → typed error.
    #[test]
    fn cursor_malformed_typed_error() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        // Corrupt the cursor cell with non-8-byte data.
        p.storage().put(CURSOR_KEY, b"hi").unwrap();
        let err = p.read_cursor().unwrap_err();
        assert!(matches!(err, PersistenceError::CursorMalformed { got: 2 }));
    }

    /// Game record round-trips via store/load.
    #[test]
    fn game_record_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        let rec = sample_game(42);
        p.store_game(&rec).unwrap();
        let loaded = p.load_game(42).unwrap().unwrap();
        assert_eq!(loaded, rec);
    }

    /// `load_game` returns `None` for missing.
    #[test]
    fn load_game_returns_none_for_missing() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        assert!(p.load_game(99).unwrap().is_none());
    }

    /// `list_games` enumerates all games (and only games).
    #[test]
    fn list_games_enumerates_all() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        for gid in [1u128, 7, 100] {
            p.store_game(&sample_game(gid)).unwrap();
        }
        // Add a non-game record to confirm prefix discipline.
        p.write_cursor(50).unwrap();
        let games = p.list_games().unwrap();
        assert_eq!(games.len(), 3);
        let ids: std::collections::HashSet<_> = games.iter().map(|g| g.game_id).collect();
        assert_eq!(ids, [1u128, 7, 100].iter().copied().collect());
    }

    /// Response record round-trips.  The stored `tx_hash_hex`
    /// is canonicalised to lowercase + no-prefix on write (see
    /// `store_response`); the loaded record has the canonical
    /// form regardless of the input format.
    #[test]
    fn response_record_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        let rec = sample_response(0xab, 42);
        p.store_response(&rec).unwrap();
        let mut hash_bytes = [0u8; 32];
        hash_bytes[0] = 0xab;
        let loaded = p.load_response(&hash_bytes).unwrap().unwrap();
        // The non-`tx_hash_hex` fields round-trip identically.
        assert_eq!(loaded.game_id, rec.game_id);
        assert_eq!(loaded.status, rec.status);
        assert_eq!(loaded.submitted_at_block, rec.submitted_at_block);
        assert_eq!(loaded.depth, rec.depth);
        assert_eq!(loaded.pivot_idx, rec.pivot_idx);
        // The `tx_hash_hex` is canonicalised: lowercase + no
        // `0x` prefix.  `sample_response`'s input has the form
        // `"0xab" + "0".repeat(62)` which canonicalises to the
        // same bytes with the 0x stripped.
        assert!(!loaded.tx_hash_hex.starts_with("0x"));
        assert_eq!(loaded.tx_hash_hex.len(), 64);
    }

    /// `list_responses` only enumerates responses.
    #[test]
    fn list_responses_enumerates_only_responses() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        for seed in [1u8, 2, 3] {
            p.store_response(&sample_response(seed, 42)).unwrap();
        }
        p.store_game(&sample_game(99)).unwrap();
        let responses = p.list_responses().unwrap();
        assert_eq!(responses.len(), 3);
    }

    /// `commit_batch` applies all updates atomically.
    #[test]
    fn commit_batch_atomic_apply() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        let mut batch = PersistBatch::new();
        batch.upsert_game(sample_game(1));
        batch.upsert_game(sample_game(2));
        batch.upsert_response(sample_response(0x11, 1));
        batch.set_cursor(500);
        p.commit_batch(&batch).unwrap();
        assert_eq!(p.list_games().unwrap().len(), 2);
        assert_eq!(p.list_responses().unwrap().len(), 1);
        assert_eq!(p.read_cursor().unwrap(), Some(500));
    }

    /// `PersistBatch::is_empty` works.
    #[test]
    fn persist_batch_is_empty() {
        let batch = PersistBatch::new();
        assert!(batch.is_empty());
        let mut batch = PersistBatch::new();
        batch.set_cursor(1);
        assert!(!batch.is_empty());
    }

    /// `PersistBatch::set_cursor` last-write-wins.
    #[test]
    fn persist_batch_cursor_overwrite() {
        let mut batch = PersistBatch::new();
        batch.set_cursor(1);
        batch.set_cursor(2);
        assert_eq!(batch.cursor, Some(2));
    }

    /// Response record with malformed hex tx-hash → error.
    #[test]
    fn malformed_tx_hash_hex_errors() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        let mut rec = sample_response(0xab, 42);
        rec.tx_hash_hex = "not-hex".to_string();
        let err = p.store_response(&rec).unwrap_err();
        assert!(matches!(err, PersistenceError::Storage(_)));
    }

    /// Response record with wrong-length hex → error.
    #[test]
    fn wrong_length_tx_hash_hex_errors() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        let mut rec = sample_response(0xab, 42);
        rec.tx_hash_hex = "0xabcd".to_string(); // 2 bytes, not 32
        let err = p.store_response(&rec).unwrap_err();
        assert!(matches!(err, PersistenceError::Storage(_)));
    }

    /// `0x`-prefix is accepted on input and canonicalised
    /// (stripped) on store.  Two writes with `0xab...` and
    /// `ab...` (uppercase / lowercase / prefix variations) all
    /// produce the same canonical stored form, eliminating
    /// case-drift between the JSON value and the storage key.
    #[test]
    fn tx_hash_hex_accepts_0x_prefix() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        let mut rec = sample_response(0xcd, 42);
        // Build a properly formatted 32-byte hex with 0x prefix.
        rec.tx_hash_hex = format!("0x{}", "ab".repeat(32));
        p.store_response(&rec).unwrap();
        // Confirm it loads and has the canonical (no-prefix,
        // lowercase) form.
        let key_hash_bytes = [0xabu8; 32];
        let loaded = p.load_response(&key_hash_bytes).unwrap().unwrap();
        assert_eq!(loaded.tx_hash_hex, "ab".repeat(32));
        assert!(!loaded.tx_hash_hex.starts_with("0x"));
    }

    /// Uppercase hex input is canonicalised to lowercase.
    #[test]
    fn tx_hash_hex_uppercase_canonicalised_to_lowercase() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        let mut rec = sample_response(0xcd, 42);
        rec.tx_hash_hex = "AB".repeat(32);
        p.store_response(&rec).unwrap();
        let key_hash_bytes = [0xabu8; 32];
        let loaded = p.load_response(&key_hash_bytes).unwrap().unwrap();
        assert_eq!(loaded.tx_hash_hex, "ab".repeat(32));
    }

    /// Two writes with different surface formats produce the
    /// same canonical storage value.
    #[test]
    fn tx_hash_hex_surface_drift_canonicalised() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();

        let mut rec_lower = sample_response(0xcd, 42);
        rec_lower.tx_hash_hex = "ab".repeat(32);
        let mut rec_upper_prefixed = rec_lower.clone();
        rec_upper_prefixed.tx_hash_hex = format!("0x{}", "AB".repeat(32));

        p.store_response(&rec_lower).unwrap();
        let key_hash_bytes = [0xabu8; 32];
        let loaded_a = p.load_response(&key_hash_bytes).unwrap().unwrap();

        p.store_response(&rec_upper_prefixed).unwrap();
        let loaded_b = p.load_response(&key_hash_bytes).unwrap().unwrap();

        // Both loads produce the same canonical hex string.
        assert_eq!(loaded_a.tx_hash_hex, loaded_b.tx_hash_hex);
        assert_eq!(loaded_a.tx_hash_hex, "ab".repeat(32));
    }

    /// Game-state JSON round-trips through `SQLite`.
    #[test]
    fn game_state_full_persistence_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();

        // Create a game with pending midpoint set.
        let mut rec = sample_game(7);
        rec.state.pending_midpoint = Some(Claim {
            idx: 16,
            commit: [3u8; 32],
        });
        rec.state.depth = 1;
        rec.state.turn = TurnSide::Challenger;
        p.store_game(&rec).unwrap();
        drop(p);

        // Re-open and reload.
        let p = Persistence::open(&db).unwrap();
        let loaded = p.load_game(7).unwrap().unwrap();
        assert_eq!(loaded, rec);
        assert_eq!(loaded.state.pending_midpoint.unwrap().idx, 16);
    }

    /// `commit_batch` rolls back on serde error.  We construct a
    /// response record whose `tx_hash_hex` parsing fails after
    /// some upserts have been staged.  The commit should fail
    /// and NO upserts should be visible.
    #[test]
    fn commit_batch_rolls_back_on_error() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();

        let mut batch = PersistBatch::new();
        batch.upsert_game(sample_game(1));
        let mut bad_response = sample_response(0xff, 1);
        bad_response.tx_hash_hex = "not-hex".to_string();
        batch.upsert_response(bad_response);
        batch.set_cursor(99);

        let err = p.commit_batch(&batch).unwrap_err();
        assert!(matches!(err, PersistenceError::Storage(_)));

        // Verify nothing was committed.
        assert!(p.load_game(1).unwrap().is_none());
        assert!(p.read_cursor().unwrap().is_none());
    }

    /// Empty batch is a no-op.
    #[test]
    fn commit_batch_empty_is_noop() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("test.db");
        let p = Persistence::open(&db).unwrap();
        let batch = PersistBatch::new();
        p.commit_batch(&batch).unwrap();
        assert!(p.read_cursor().unwrap().is_none());
        assert!(p.list_games().unwrap().is_empty());
    }
}
