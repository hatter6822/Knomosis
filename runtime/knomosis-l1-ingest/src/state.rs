// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Persistent watcher state.
//!
//! ## What's persisted
//!
//! Two pieces of state survive across restarts:
//!
//!   1. **Last confirmed block** — the highest block number whose
//!      events have been forwarded to `knomosis-host`.  On startup
//!      the watcher resumes from this block + 1.
//!   2. **Forwarded-event ledger** — the set of `(block_hash,
//!      tx_hash, log_index)` triples that have already been
//!      forwarded.  Used for idempotency: a duplicate event
//!      arriving (e.g. from a shallow re-org that puts an event
//!      back at a different block) is silently dropped.
//!
//! Also persisted, but in memory only between restarts:
//!
//!   3. **AddressBook** — the `EthAddress → ActorId` mapping
//!      maintained by `translation::ingest`.  Persisted to disk
//!      so the daemon resumes with the same `next_actor_id`.
//!
//! ## On-disk format
//!
//! JSONL (one JSON object per line) is the chosen format:
//!
//!   * Append-only writes (durable on each event).
//!   * Human-inspectable.
//!   * No DB dependency until RH-E.0 lands.
//!
//! Each line is one [`StateRecord`].  Current production writes
//! use TWO record kinds:
//!
//!   * `submitted` — the atomic post-submit record carrying the
//!     forwarded-key, new `next_nonce`, and (optional) address
//!     assignment in a single line write.  Replaces the
//!     pre-audit-pass three-record sequence
//!     (`address_assigned` + `nonce_progressed` + `forwarded`).
//!   * `forwarded` — used ONLY for `NoAction` events (`Revoked`,
//!     `DepositInitiated`) that don't bump the nonce.  Just
//!     records the dedup-key.
//!   * `confirmed` — block-number progress marker, appended
//!     after every successful `process_block`.
//!
//! Legacy record kinds (`address_assigned`, `nonce_progressed`)
//! remain in the [`StateRecord`] enum for replay-compatibility
//! with state files written by older daemons.  The watcher
//! NEVER writes these for new records.
//!
//! ```jsonc
//! {"event": "submitted", "block_hash": "0x...", "tx_hash": "0x...", "log_index": N,
//!  "next_nonce": "N", "assigned": {"address": "0x...", "actor_id": N}}
//! {"event": "forwarded", "block_hash": "0x...", "tx_hash": "0x...", "log_index": N}
//! {"event": "confirmed", "block_number": N}
//! ```
//!
//! Rebuilding state on startup walks the file and replays each
//! record into in-memory data structures.  Compaction (when the
//! file grows large) is out of scope for the RH-B landing; the
//! planned RH-E.0 SQLite layer will replace this entirely.
//!
//! ## Replay-time integrity checks
//!
//! Replay enforces several invariants and rejects corrupted
//! state files with [`StateError::Malformed`]:
//!
//!   * Hex-byte fields decode to the expected length
//!     (`block_hash` / `tx_hash` → 32 bytes; `address` → 20 bytes).
//!   * Duplicate `actor_id` records with conflicting addresses
//!     are rejected (would silently overwrite the BTreeMap).
//!   * The reconstructed address book's id sequence matches
//!     the persisted ids (catches gaps and out-of-order
//!     assignments).

use std::collections::{BTreeMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::action::{ActorId, EthAddress};
use crate::address_book::AddressBook;
use crate::events::TopicHash;

/// Errors surfaced by the persistent state layer.
#[derive(Debug, thiserror::Error)]
pub enum StateError {
    /// An I/O error from the underlying filesystem.
    #[error("state I/O error at {path}: {source}")]
    Io {
        /// The path that errored.
        path: PathBuf,
        /// The underlying I/O error.
        #[source]
        source: std::io::Error,
    },
    /// A line in the state file could not be parsed as JSON or
    /// the JSON did not match the expected schema.
    #[error("malformed state record at line {line_number}: {message}")]
    Malformed {
        /// Line number (1-indexed) of the offending record.
        line_number: usize,
        /// Diagnostic message.
        message: String,
    },
}

/// One record in the on-disk state file.  Tagged enum so the
/// JSON form has a discriminating `event` field.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event")]
pub enum StateRecord {
    /// An event was forwarded to `knomosis-host`.  Identified by
    /// the `(block_hash, tx_hash, log_index)` triple.
    #[serde(rename = "forwarded")]
    Forwarded {
        /// The L1 block hash the event was originally observed
        /// in.  Used for re-org-tolerant dedup keying.
        block_hash: HexBytes,
        /// The L1 transaction hash.
        tx_hash: HexBytes,
        /// The log index within the transaction.
        log_index: u64,
    },
    /// Confirmed-progress marker.  Records the highest block
    /// number whose events have all been processed.
    #[serde(rename = "confirmed")]
    Confirmed {
        /// The block number.
        block_number: u64,
    },
    /// Address-book assignment record.  Records that
    /// `address` was assigned `actor_id`.
    #[serde(rename = "address_assigned")]
    AddressAssigned {
        /// The Ethereum address.
        address: HexBytes,
        /// The assigned `ActorId`.
        actor_id: ActorId,
    },
    /// Nonce-progressed record.  Records the watcher's
    /// `next_nonce` value AFTER successfully submitting an
    /// action.  On replay, the maximum `next_nonce` across all
    /// `NonceProgressed` records is used to seed the watcher's
    /// nonce counter — preventing the over-counting bug where
    /// `Forwarded` records (which include non-submitting events
    /// like `Revoked` / `DepositInitiated`) were used as the
    /// nonce proxy.
    ///
    /// The nonce is serialised as a decimal string because
    /// `serde_json` cannot round-trip `u128` natively (its
    /// `Number` type is bounded at `i64` / `u64` / `f64`).  A
    /// decimal string preserves arbitrary precision and is
    /// human-inspectable.
    #[serde(rename = "nonce_progressed")]
    NonceProgressed {
        /// The watcher's `next_nonce` value AFTER the
        /// submission that triggered this record.
        #[serde(with = "u128_as_decimal_string")]
        next_nonce: u128,
    },
    /// Atomic "successful submission" record.  Combines the
    /// three post-submit state mutations into a single JSONL
    /// line so they are persisted atomically at the OS level:
    ///
    ///   * The forwarded-key triple (for idempotency dedup).
    ///   * The new `next_nonce` (for the watcher's counter).
    ///   * The optional address assignment (for the address
    ///     book).
    ///
    /// On replay, this record's effects are applied in order:
    /// forwarded set updated, nonce counter updated, address
    /// book updated.  If the line is truncated (mid-write
    /// failure), the JSON parser rejects it and the replay
    /// fails loudly — the operator must repair the state file
    /// rather than silently accept partial progress.
    ///
    /// Replaces the previous three-record sequence
    /// (`AddressAssigned` + `NonceProgressed` + `Forwarded`).
    /// The three-record variants are retained for backward-
    /// compatibility with previously-written state files, but
    /// new writes always use `Submitted`.
    #[serde(rename = "submitted")]
    Submitted {
        /// The L1 block hash where the event was observed.
        block_hash: HexBytes,
        /// The L1 transaction hash.
        tx_hash: HexBytes,
        /// The log index within the transaction.
        log_index: u64,
        /// The watcher's `next_nonce` value AFTER the
        /// successful submit.
        #[serde(with = "u128_as_decimal_string")]
        next_nonce: u128,
        /// `Some(addr, id)` if this submission produced a
        /// `RegisterIdentity` action; `None` otherwise (a
        /// `ReplaceKey` rotation, or any submission that
        /// didn't mutate the address book).
        #[serde(default)]
        assigned: Option<AddressAssignment>,
    },
}

/// Sub-record for [`StateRecord::Submitted::assigned`].  Carries
/// the address-id pair that becomes part of the address book
/// post-commit.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AddressAssignment {
    /// The Ethereum address.
    pub address: HexBytes,
    /// The actor id it was assigned.
    pub actor_id: ActorId,
}

/// `serde` adapter that round-trips `u128` through a decimal
/// string.  Used by [`StateRecord::NonceProgressed`].
mod u128_as_decimal_string {
    use serde::{Deserialize, Deserializer, Serializer};

    pub(super) fn serialize<S: Serializer>(v: &u128, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&v.to_string())
    }

    pub(super) fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<u128, D::Error> {
        let s = String::deserialize(d)?;
        s.parse::<u128>().map_err(serde::de::Error::custom)
    }
}

/// Hex-encoded byte buffer.  Used in `StateRecord` to make the
/// on-disk JSON human-readable.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HexBytes(pub Vec<u8>);

impl Serialize for HexBytes {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut s = String::with_capacity(2 + self.0.len() * 2);
        s.push_str("0x");
        for b in &self.0 {
            s.push(hex_char(b >> 4));
            s.push(hex_char(b & 0x0f));
        }
        serializer.serialize_str(&s)
    }
}

impl<'de> Deserialize<'de> for HexBytes {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        let stripped = s
            .strip_prefix("0x")
            .ok_or_else(|| serde::de::Error::custom("expected 0x-prefixed hex string"))?;
        if stripped.len() % 2 != 0 {
            return Err(serde::de::Error::custom("hex string has odd length"));
        }
        let mut out = Vec::with_capacity(stripped.len() / 2);
        for chunk in stripped.as_bytes().chunks(2) {
            let hi = hex_value(chunk[0]).ok_or_else(|| {
                serde::de::Error::custom(format!("invalid hex char: {}", chunk[0] as char))
            })?;
            let lo = hex_value(chunk[1]).ok_or_else(|| {
                serde::de::Error::custom(format!("invalid hex char: {}", chunk[1] as char))
            })?;
            out.push((hi << 4) | lo);
        }
        Ok(Self(out))
    }
}

/// Map nibble (0..=15) to ASCII hex character.
fn hex_char(n: u8) -> char {
    match n {
        0..=9 => (b'0' + n) as char,
        10..=15 => (b'a' + (n - 10)) as char,
        _ => '?',
    }
}

/// Map ASCII hex character to nibble.
fn hex_value(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(10 + c - b'a'),
        b'A'..=b'F' => Some(10 + c - b'A'),
        _ => None,
    }
}

/// The reconstructed in-memory state from a state file.
#[derive(Clone, Debug)]
pub struct WatcherState {
    /// Block number up to and including which the watcher has
    /// processed all events.  Resumed-from on startup.
    pub last_confirmed_block: Option<u64>,
    /// Set of `(block_hash, tx_hash, log_index)` triples already
    /// forwarded.  Used for idempotency.
    pub forwarded: HashSet<ForwardedKey>,
    /// The reconstructed `AddressBook`.
    pub address_book: AddressBook,
    /// The watcher's next-nonce counter.  Bumped by one for each
    /// successful submission; persisted via
    /// [`StateRecord::NonceProgressed`].
    pub next_nonce: u128,
}

impl Default for WatcherState {
    fn default() -> Self {
        Self {
            last_confirmed_block: None,
            forwarded: HashSet::new(),
            address_book: AddressBook::new(),
            next_nonce: 0,
        }
    }
}

/// Key in the forwarded-events set.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct ForwardedKey {
    /// The L1 block hash.
    pub block_hash: TopicHash,
    /// The L1 transaction hash.
    pub tx_hash: TopicHash,
    /// The log index.
    pub log_index: u64,
}

/// Persistent watcher-state store.
///
/// The store is append-only — every state change writes one new
/// JSONL record.  On startup, [`Self::load`] walks the file and
/// rebuilds the in-memory state.
///
/// ## Thread-safety
///
/// `StateStore` is **not** `Sync`-shared.  The watcher loop is
/// single-threaded by design: every state mutation happens on
/// the same thread that holds the `&mut StateStore`.  Re-orgs do
/// not preempt the mutation thread.
#[derive(Debug)]
pub struct StateStore {
    path: PathBuf,
    writer: BufWriter<File>,
}

impl StateStore {
    /// Open or create the state file at `path`, replay every
    /// record, and return the reconstructed [`WatcherState`]
    /// alongside the open store.
    ///
    /// On a missing file, returns an empty `WatcherState`.
    ///
    /// # Errors
    ///
    /// Returns `StateError::Io` on filesystem errors and
    /// `StateError::Malformed` on a corrupted record.
    pub fn open(path: &Path) -> Result<(Self, WatcherState), StateError> {
        let state = if path.exists() {
            Self::replay(path)?
        } else {
            WatcherState::default()
        };
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|source| StateError::Io {
                path: path.to_path_buf(),
                source,
            })?;
        Ok((
            Self {
                path: path.to_path_buf(),
                writer: BufWriter::new(file),
            },
            state,
        ))
    }

    /// Walk the file and rebuild the in-memory state.
    fn replay(path: &Path) -> Result<WatcherState, StateError> {
        let file = File::open(path).map_err(|source| StateError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        let reader = BufReader::new(file);
        let mut state = WatcherState::default();
        // For replay, track addresses in insertion order so we can
        // rebuild the address book deterministically.
        let mut pending_assignments: BTreeMap<ActorId, EthAddress> = BTreeMap::new();
        for (i, line_result) in reader.lines().enumerate() {
            let line_number = i + 1;
            let line = line_result.map_err(|source| StateError::Io {
                path: path.to_path_buf(),
                source,
            })?;
            if line.trim().is_empty() {
                continue;
            }
            let record: StateRecord =
                serde_json::from_str(&line).map_err(|e| StateError::Malformed {
                    line_number,
                    message: format!("JSON parse: {e}"),
                })?;
            match record {
                StateRecord::Forwarded {
                    block_hash,
                    tx_hash,
                    log_index,
                } => {
                    let bh: TopicHash =
                        block_hash.0.try_into().map_err(|_| StateError::Malformed {
                            line_number,
                            message: "block_hash must be 32 bytes".into(),
                        })?;
                    let th: TopicHash =
                        tx_hash.0.try_into().map_err(|_| StateError::Malformed {
                            line_number,
                            message: "tx_hash must be 32 bytes".into(),
                        })?;
                    state.forwarded.insert(ForwardedKey {
                        block_hash: bh,
                        tx_hash: th,
                        log_index,
                    });
                }
                StateRecord::Confirmed { block_number } => {
                    state.last_confirmed_block = Some(block_number);
                }
                StateRecord::AddressAssigned { address, actor_id } => {
                    let bytes: [u8; 20] =
                        address.0.try_into().map_err(|_| StateError::Malformed {
                            line_number,
                            message: "address must be 20 bytes".into(),
                        })?;
                    let addr = EthAddress(bytes);
                    // Reject duplicate actor-id entries.  The
                    // `BTreeMap::insert` would silently overwrite,
                    // hiding a corrupted state file.  Using
                    // `try_insert`-style logic catches it.
                    if let Some(prior) = pending_assignments.get(&actor_id) {
                        if *prior != addr {
                            return Err(StateError::Malformed {
                                line_number,
                                message: format!(
                                    "duplicate actor_id {actor_id} with conflicting \
                                     addresses {prior:?} and {addr:?}"
                                ),
                            });
                        }
                    }
                    pending_assignments.insert(actor_id, addr);
                }
                StateRecord::NonceProgressed { next_nonce } => {
                    // Take the maximum across all records; a
                    // resumed daemon honours the highest committed
                    // nonce regardless of record order.
                    if next_nonce > state.next_nonce {
                        state.next_nonce = next_nonce;
                    }
                }
                StateRecord::Submitted {
                    block_hash,
                    tx_hash,
                    log_index,
                    next_nonce,
                    assigned,
                } => {
                    // Atomic post-submit record.  Decompose into
                    // the three pre-existing replay effects.
                    let bh: TopicHash =
                        block_hash.0.try_into().map_err(|_| StateError::Malformed {
                            line_number,
                            message: "block_hash must be 32 bytes".into(),
                        })?;
                    let th: TopicHash =
                        tx_hash.0.try_into().map_err(|_| StateError::Malformed {
                            line_number,
                            message: "tx_hash must be 32 bytes".into(),
                        })?;
                    state.forwarded.insert(ForwardedKey {
                        block_hash: bh,
                        tx_hash: th,
                        log_index,
                    });
                    if next_nonce > state.next_nonce {
                        state.next_nonce = next_nonce;
                    }
                    if let Some(assignment) = assigned {
                        let bytes: [u8; 20] =
                            assignment
                                .address
                                .0
                                .try_into()
                                .map_err(|_| StateError::Malformed {
                                    line_number,
                                    message: "submitted.assigned.address must be 20 bytes".into(),
                                })?;
                        let addr = EthAddress(bytes);
                        // Reject duplicate actor-id entries (see
                        // the analogous check in the legacy
                        // `AddressAssigned` arm above).
                        if let Some(prior) = pending_assignments.get(&assignment.actor_id) {
                            if *prior != addr {
                                return Err(StateError::Malformed {
                                    line_number,
                                    message: format!(
                                        "duplicate actor_id {} with conflicting addresses \
                                         {prior:?} and {addr:?}",
                                        assignment.actor_id
                                    ),
                                });
                            }
                        }
                        pending_assignments.insert(assignment.actor_id, addr);
                    }
                }
            }
        }
        // Reconstruct the address book by replaying assignments
        // in actor-id order.  The order matters because Lean's
        // `assign` issues ids monotonically; we must reproduce
        // the same mapping.  We also verify the replayed ids
        // match the persisted values — any mismatch indicates a
        // corrupted state file (e.g. gaps or duplicates).
        //
        // Uses `try_assign` (the fallible variant) so an
        // overflowing counter surfaces as a typed Malformed
        // error rather than a panic.  Overflow is unreachable
        // on any realistic workload but the typed-error path
        // is the operator-friendly failure mode.
        for (&id, addr) in &pending_assignments {
            let (assigned_id, _is_new) =
                state
                    .address_book
                    .try_assign(addr)
                    .map_err(|e| StateError::Malformed {
                        line_number: 0,
                        message: format!("address_book replay overflow at id {id}: {e}"),
                    })?;
            if assigned_id != id {
                return Err(StateError::Malformed {
                    line_number: 0,
                    message: format!(
                        "address_book replay: address {addr:?} expected actor_id {id} \
                         but assigned {assigned_id} (state file gap or duplicate)"
                    ),
                });
            }
        }
        Ok(state)
    }

    /// Append a record to the state file and flush.
    ///
    /// ## Durability semantics
    ///
    /// `flush` is called after every record — the bytes leave
    /// our `BufWriter` and enter the OS page cache.  We do
    /// **NOT** call `sync_data` / fsync; a hard crash (OOM,
    /// panic-abort, OS reboot) before the OS flushes the cache
    /// can lose up to ~5-30 seconds of recent records.
    ///
    /// This trade-off keeps per-record latency low at the cost
    /// of "best-effort" durability.  On a graceful exit (the
    /// process returns from main without crashing) the OS will
    /// sync the cache and all records are durable.
    ///
    /// RH-E.0 (SQLite-backed storage) will add a proper
    /// transactional / WAL durability boundary.
    ///
    /// # Errors
    ///
    /// Returns `StateError::Io` on write failure.
    pub fn append(&mut self, record: &StateRecord) -> Result<(), StateError> {
        let line = serde_json::to_string(record).map_err(|e| StateError::Io {
            path: self.path.clone(),
            source: std::io::Error::new(std::io::ErrorKind::InvalidData, e),
        })?;
        self.writer
            .write_all(line.as_bytes())
            .map_err(|source| StateError::Io {
                path: self.path.clone(),
                source,
            })?;
        self.writer
            .write_all(b"\n")
            .map_err(|source| StateError::Io {
                path: self.path.clone(),
                source,
            })?;
        self.writer.flush().map_err(|source| StateError::Io {
            path: self.path.clone(),
            source,
        })?;
        Ok(())
    }

    /// Path of the underlying state file.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

#[cfg(test)]
mod tests {
    use super::{AddressAssignment, ForwardedKey, HexBytes, StateError, StateRecord, StateStore};
    use crate::action::{ActorId, EthAddress};

    /// `HexBytes` round-trips through JSON.
    #[test]
    fn hex_bytes_round_trip() {
        let hb = HexBytes(vec![0x00, 0xff, 0xab, 0xcd]);
        let s = serde_json::to_string(&hb).unwrap();
        assert_eq!(s, "\"0x00ffabcd\"");
        let parsed: HexBytes = serde_json::from_str(&s).unwrap();
        assert_eq!(parsed, hb);
    }

    /// `HexBytes` rejects malformed input.
    #[test]
    fn hex_bytes_rejects_malformed() {
        assert!(serde_json::from_str::<HexBytes>("\"no_prefix\"").is_err());
        assert!(serde_json::from_str::<HexBytes>("\"0xZZ\"").is_err());
        assert!(serde_json::from_str::<HexBytes>("\"0x0\"").is_err()); // odd length
    }

    /// Round-trip `Forwarded` record through JSON.
    #[test]
    fn forwarded_record_round_trip() {
        let r = StateRecord::Forwarded {
            block_hash: HexBytes(vec![0xaa; 32]),
            tx_hash: HexBytes(vec![0xbb; 32]),
            log_index: 5,
        };
        let s = serde_json::to_string(&r).unwrap();
        let parsed: StateRecord = serde_json::from_str(&s).unwrap();
        assert_eq!(parsed, r);
        // Check JSON shape contains the discriminator field.
        assert!(s.contains("\"event\":\"forwarded\""));
    }

    /// Round-trip `Confirmed` record.
    #[test]
    fn confirmed_record_round_trip() {
        let r = StateRecord::Confirmed { block_number: 42 };
        let s = serde_json::to_string(&r).unwrap();
        let parsed: StateRecord = serde_json::from_str(&s).unwrap();
        assert_eq!(parsed, r);
    }

    /// Round-trip `AddressAssigned` record.
    #[test]
    fn address_assigned_record_round_trip() {
        let r = StateRecord::AddressAssigned {
            address: HexBytes(vec![0xcd; 20]),
            actor_id: 7,
        };
        let s = serde_json::to_string(&r).unwrap();
        let parsed: StateRecord = serde_json::from_str(&s).unwrap();
        assert_eq!(parsed, r);
    }

    /// `StateStore::open` on a non-existent path returns an
    /// empty state and creates the file.
    #[test]
    fn open_creates_new_file() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        assert!(!path.exists());
        let (_store, state) = StateStore::open(&path).unwrap();
        assert!(path.exists());
        assert!(state.last_confirmed_block.is_none());
        assert!(state.forwarded.is_empty());
        // Genesis `next_actor_id` is 3 post-GP.7.1 (ids 0/1/2 reserved).
        assert_eq!(state.address_book.next_actor_id(), 3);
    }

    /// Append + replay round-trips state.
    #[test]
    fn append_replay_round_trip() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        {
            let (mut store, _) = StateStore::open(&path).unwrap();
            store
                .append(&StateRecord::Confirmed { block_number: 100 })
                .unwrap();
            store
                .append(&StateRecord::Forwarded {
                    block_hash: HexBytes(vec![0x11; 32]),
                    tx_hash: HexBytes(vec![0x22; 32]),
                    log_index: 3,
                })
                .unwrap();
            store
                .append(&StateRecord::AddressAssigned {
                    address: HexBytes(vec![0xab; 20]),
                    // `3` is the first id a fresh adaptor issues
                    // (genesis `next_actor_id`, post-GP.7.1); the
                    // replay re-assigns from an empty book and verifies
                    // the issued id matches this persisted value.
                    actor_id: 3,
                })
                .unwrap();
        }
        let (_, state) = StateStore::open(&path).unwrap();
        assert_eq!(state.last_confirmed_block, Some(100));
        assert_eq!(state.forwarded.len(), 1);
        let key = ForwardedKey {
            block_hash: [0x11; 32],
            tx_hash: [0x22; 32],
            log_index: 3,
        };
        assert!(state.forwarded.contains(&key));
        // Address book has the assigned mapping.
        let addr = EthAddress::from_bytes(&[0xab; 20]).unwrap();
        assert_eq!(state.address_book.lookup(&addr), Some(3));
        // Address book's next_actor_id reflects the replayed
        // single assignment (3 issued → next is 4).
        assert_eq!(state.address_book.next_actor_id(), 4);
    }

    /// GP.7.1 — a persisted `AddressAssigned` record that claims a user
    /// was issued a *reserved* `ActorId` (here `1`, `gasPoolActor`'s
    /// slot) is rejected on replay.  A fresh adaptor allocates from
    /// `INITIAL_NEXT_ACTOR_ID` (3), so the re-assignment yields `3` and
    /// the id-match check (`assigned_id != id`) fails loudly rather
    /// than silently reconstructing a book that violates the
    /// reservation.  Such a state file can only originate from a
    /// pre-GP.7.1 deployment, whose migration is owned by Phase GP.10.
    #[test]
    fn replay_rejects_reserved_actor_id() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        {
            let (mut store, _) = StateStore::open(&path).unwrap();
            store
                .append(&StateRecord::AddressAssigned {
                    address: HexBytes(vec![0xcd; 20]),
                    actor_id: 1, // reserved for gasPoolActor
                })
                .unwrap();
        }
        match StateStore::open(&path) {
            Err(StateError::Malformed { message, .. }) => {
                assert!(
                    message.contains("expected actor_id 1"),
                    "unexpected rejection message: {message}"
                );
            }
            Err(e) => panic!("expected Malformed rejection, got different error: {e:?}"),
            Ok(_) => panic!("replay must reject a persisted reserved actor_id, but it succeeded"),
        }
    }

    /// Multiple `Confirmed` records: last one wins.
    #[test]
    fn confirmed_overrides() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        {
            let (mut store, _) = StateStore::open(&path).unwrap();
            store
                .append(&StateRecord::Confirmed { block_number: 50 })
                .unwrap();
            store
                .append(&StateRecord::Confirmed { block_number: 100 })
                .unwrap();
            store
                .append(&StateRecord::Confirmed { block_number: 75 })
                .unwrap();
        }
        let (_, state) = StateStore::open(&path).unwrap();
        assert_eq!(state.last_confirmed_block, Some(75));
    }

    /// Address-book replay preserves assignment order.
    #[test]
    fn address_book_replay_order() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        {
            let (mut store, _) = StateStore::open(&path).unwrap();
            // Ids are consecutive from the genesis `next_actor_id` (3,
            // post-GP.7.1); the replay re-assigns in id order and
            // verifies each issued id matches the persisted value.
            store
                .append(&StateRecord::AddressAssigned {
                    address: HexBytes(vec![0x01; 20]),
                    actor_id: 3,
                })
                .unwrap();
            store
                .append(&StateRecord::AddressAssigned {
                    address: HexBytes(vec![0x02; 20]),
                    actor_id: 4,
                })
                .unwrap();
            store
                .append(&StateRecord::AddressAssigned {
                    address: HexBytes(vec![0x03; 20]),
                    actor_id: 5,
                })
                .unwrap();
        }
        let (_, state) = StateStore::open(&path).unwrap();
        assert_eq!(state.address_book.len(), 3);
        assert_eq!(
            state
                .address_book
                .lookup(&EthAddress::from_bytes(&[0x01; 20]).unwrap()),
            Some(3)
        );
        assert_eq!(
            state
                .address_book
                .lookup(&EthAddress::from_bytes(&[0x02; 20]).unwrap()),
            Some(4)
        );
        assert_eq!(
            state
                .address_book
                .lookup(&EthAddress::from_bytes(&[0x03; 20]).unwrap()),
            Some(5)
        );
    }

    /// Empty lines in the state file are skipped silently.
    #[test]
    fn empty_lines_skipped() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        std::fs::write(
            &path,
            "\n\n{\"event\":\"confirmed\",\"block_number\":42}\n\n\n",
        )
        .unwrap();
        let (_, state) = StateStore::open(&path).unwrap();
        assert_eq!(state.last_confirmed_block, Some(42));
    }

    /// A malformed line yields `StateError::Malformed`.
    #[test]
    fn malformed_line_returns_error() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        std::fs::write(&path, "{not json}\n").unwrap();
        match StateStore::open(&path) {
            Err(StateError::Malformed { line_number, .. }) => {
                assert_eq!(line_number, 1);
            }
            other => panic!("expected Malformed error, got {other:?}"),
        }
    }

    /// Forwarded record with wrong-size block hash yields
    /// `Malformed`.
    #[test]
    fn wrong_size_block_hash_returns_error() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        // 31-byte block hash instead of 32.
        let hex31 = "0x".to_string() + &"00".repeat(31);
        let hex32 = "0x".to_string() + &"00".repeat(32);
        let line = format!(
            r#"{{"event":"forwarded","block_hash":"{hex31}","tx_hash":"{hex32}","log_index":0}}"#
        );
        std::fs::write(&path, line + "\n").unwrap();
        match StateStore::open(&path) {
            Err(StateError::Malformed { message, .. }) => {
                assert!(message.contains("block_hash"));
            }
            other => panic!("expected Malformed error, got {other:?}"),
        }
    }

    /// Two `ForwardedKey`s with the same fields are equal.
    #[test]
    fn forwarded_key_equality() {
        let k1 = ForwardedKey {
            block_hash: [1u8; 32],
            tx_hash: [2u8; 32],
            log_index: 3,
        };
        let k2 = ForwardedKey {
            block_hash: [1u8; 32],
            tx_hash: [2u8; 32],
            log_index: 3,
        };
        assert_eq!(k1, k2);
    }

    /// `actor_id` is the same `u64`-typed `ActorId`.
    #[test]
    fn actor_id_type_check() {
        let _: ActorId = 0;
    }

    /// `NonceProgressed` round-trips through JSON via the
    /// decimal-string adapter.
    #[test]
    fn nonce_progressed_round_trip() {
        let r = StateRecord::NonceProgressed { next_nonce: 42 };
        let s = serde_json::to_string(&r).unwrap();
        // Verify the decimal-string serialisation.
        assert!(s.contains("\"next_nonce\":\"42\""));
        let parsed: StateRecord = serde_json::from_str(&s).unwrap();
        assert_eq!(parsed, r);
    }

    /// `NonceProgressed` round-trips a `u128` value beyond
    /// `u64::MAX`.  Demonstrates the decimal-string adapter is
    /// load-bearing for >64-bit nonces.
    #[test]
    fn nonce_progressed_large_value() {
        let large = u128::from(u64::MAX) + 1;
        let r = StateRecord::NonceProgressed { next_nonce: large };
        let s = serde_json::to_string(&r).unwrap();
        let parsed: StateRecord = serde_json::from_str(&s).unwrap();
        assert_eq!(parsed, r);
    }

    /// Replay rebuilds `next_nonce` from the maximum
    /// `NonceProgressed` record (not from `forwarded.len()`).
    #[test]
    fn replay_rebuilds_next_nonce_from_nonce_progressed() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        {
            let (mut store, _) = StateStore::open(&path).unwrap();
            // Two Forwarded records (one is "None"-event, simulating Revoked).
            store
                .append(&StateRecord::Forwarded {
                    block_hash: HexBytes(vec![1u8; 32]),
                    tx_hash: HexBytes(vec![2u8; 32]),
                    log_index: 0,
                })
                .unwrap();
            // Bump nonce once.
            store
                .append(&StateRecord::NonceProgressed { next_nonce: 1 })
                .unwrap();
            store
                .append(&StateRecord::Forwarded {
                    block_hash: HexBytes(vec![3u8; 32]),
                    tx_hash: HexBytes(vec![4u8; 32]),
                    log_index: 1,
                })
                .unwrap();
            // No nonce-progressed for this one (simulating a Revoked event).
            store
                .append(&StateRecord::Forwarded {
                    block_hash: HexBytes(vec![5u8; 32]),
                    tx_hash: HexBytes(vec![6u8; 32]),
                    log_index: 2,
                })
                .unwrap();
            store
                .append(&StateRecord::NonceProgressed { next_nonce: 2 })
                .unwrap();
        }
        let (_, state) = StateStore::open(&path).unwrap();
        // 3 forwarded records, but only 2 nonce-bumps.
        assert_eq!(state.forwarded.len(), 3);
        assert_eq!(
            state.next_nonce, 2,
            "next_nonce must be the highest NonceProgressed value (2), \
             not the forwarded count (3)"
        );
    }

    /// Replay takes the maximum nonce across out-of-order
    /// `NonceProgressed` records (e.g. a record that arrives
    /// later but contains an earlier value).
    #[test]
    fn replay_takes_max_nonce_across_records() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        {
            let (mut store, _) = StateStore::open(&path).unwrap();
            store
                .append(&StateRecord::NonceProgressed { next_nonce: 5 })
                .unwrap();
            store
                .append(&StateRecord::NonceProgressed { next_nonce: 3 }) // older value
                .unwrap();
            store
                .append(&StateRecord::NonceProgressed { next_nonce: 7 })
                .unwrap();
        }
        let (_, state) = StateStore::open(&path).unwrap();
        assert_eq!(state.next_nonce, 7);
    }

    /// `Submitted` (the new atomic post-submit record) round-
    /// trips through JSON.
    #[test]
    fn submitted_record_round_trip() {
        let r = StateRecord::Submitted {
            block_hash: HexBytes(vec![0xaa; 32]),
            tx_hash: HexBytes(vec![0xbb; 32]),
            log_index: 5,
            next_nonce: 7,
            assigned: Some(AddressAssignment {
                address: HexBytes(vec![0xcc; 20]),
                actor_id: 3,
            }),
        };
        let s = serde_json::to_string(&r).unwrap();
        assert!(s.contains("\"event\":\"submitted\""));
        assert!(s.contains("\"next_nonce\":\"7\""));
        let parsed: StateRecord = serde_json::from_str(&s).unwrap();
        assert_eq!(parsed, r);
    }

    /// `Submitted` without assignment (the `ReplaceKey` path)
    /// round-trips.
    #[test]
    fn submitted_record_without_assignment_round_trip() {
        let r = StateRecord::Submitted {
            block_hash: HexBytes(vec![0xaa; 32]),
            tx_hash: HexBytes(vec![0xbb; 32]),
            log_index: 0,
            next_nonce: 1,
            assigned: None,
        };
        let s = serde_json::to_string(&r).unwrap();
        let parsed: StateRecord = serde_json::from_str(&s).unwrap();
        assert_eq!(parsed, r);
    }

    /// Replay applies a `Submitted` record's three effects:
    /// forwarded-key insertion, nonce update, and (optional)
    /// address-book assignment.
    #[test]
    fn replay_applies_submitted_record_effects() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        {
            let (mut store, _) = StateStore::open(&path).unwrap();
            store
                .append(&StateRecord::Submitted {
                    block_hash: HexBytes(vec![0x11; 32]),
                    tx_hash: HexBytes(vec![0x22; 32]),
                    log_index: 0,
                    next_nonce: 1,
                    assigned: Some(AddressAssignment {
                        address: HexBytes(vec![0xab; 20]),
                        // First fresh id post-GP.7.1 is 3 (0/1/2 reserved).
                        actor_id: 3,
                    }),
                })
                .unwrap();
        }
        let (_, state) = StateStore::open(&path).unwrap();
        // Forwarded set has the key.
        assert_eq!(state.forwarded.len(), 1);
        // Nonce was advanced.
        assert_eq!(state.next_nonce, 1);
        // Address book has the assignment.
        let addr = EthAddress::from_bytes(&[0xab; 20]).unwrap();
        assert_eq!(state.address_book.lookup(&addr), Some(3));
    }

    /// Replay tolerates a mix of legacy three-record format and
    /// new atomic `Submitted` records (backwards compatibility).
    #[test]
    fn replay_tolerates_legacy_and_submitted_mix() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        {
            let (mut store, _) = StateStore::open(&path).unwrap();
            // Legacy three-record format for event 1.  Ids start at
            // the genesis `next_actor_id` (3, post-GP.7.1).
            store
                .append(&StateRecord::AddressAssigned {
                    address: HexBytes(vec![0x01; 20]),
                    actor_id: 3,
                })
                .unwrap();
            store
                .append(&StateRecord::NonceProgressed { next_nonce: 1 })
                .unwrap();
            store
                .append(&StateRecord::Forwarded {
                    block_hash: HexBytes(vec![0x11; 32]),
                    tx_hash: HexBytes(vec![0x22; 32]),
                    log_index: 0,
                })
                .unwrap();
            // New atomic format for event 2.
            store
                .append(&StateRecord::Submitted {
                    block_hash: HexBytes(vec![0x33; 32]),
                    tx_hash: HexBytes(vec![0x44; 32]),
                    log_index: 0,
                    next_nonce: 2,
                    assigned: Some(AddressAssignment {
                        address: HexBytes(vec![0x02; 20]),
                        actor_id: 4,
                    }),
                })
                .unwrap();
        }
        let (_, state) = StateStore::open(&path).unwrap();
        assert_eq!(state.forwarded.len(), 2);
        assert_eq!(state.next_nonce, 2);
        assert_eq!(state.address_book.len(), 2);
    }

    /// Replay rejects state files with gaps / duplicates in the
    /// `AddressAssigned` records.
    #[test]
    fn replay_rejects_gapped_address_assignments() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        // Manually write a state file with a gap: assign actor id 3
        // (genesis start, post-GP.7.1) then 5 (skipping 4).  The replay
        // re-assigns 3 ✓ then 4 ✗≠5 → gap detected.
        let line1 = serde_json::to_string(&StateRecord::AddressAssigned {
            address: HexBytes(vec![0x01; 20]),
            actor_id: 3,
        })
        .unwrap();
        let line2 = serde_json::to_string(&StateRecord::AddressAssigned {
            address: HexBytes(vec![0x02; 20]),
            actor_id: 5,
        })
        .unwrap();
        std::fs::write(&path, format!("{line1}\n{line2}\n")).unwrap();
        let result = StateStore::open(&path);
        match result {
            Err(StateError::Malformed { message, .. }) => {
                assert!(
                    message.contains("address_book replay"),
                    "unexpected error: {message}"
                );
            }
            other => panic!("expected Malformed error, got {other:?}"),
        }
    }

    /// Replay rejects state files with the same `actor_id`
    /// assigned to different addresses (duplicate-key
    /// corruption that would previously have silently
    /// overwritten in the `BTreeMap`).
    #[test]
    fn replay_rejects_duplicate_actor_id_with_different_addresses() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        let line1 = serde_json::to_string(&StateRecord::AddressAssigned {
            address: HexBytes(vec![0x01; 20]),
            actor_id: 3,
        })
        .unwrap();
        let line2 = serde_json::to_string(&StateRecord::AddressAssigned {
            address: HexBytes(vec![0x02; 20]), // different address
            actor_id: 3,                       // same id
        })
        .unwrap();
        std::fs::write(&path, format!("{line1}\n{line2}\n")).unwrap();
        let result = StateStore::open(&path);
        match result {
            Err(StateError::Malformed { message, .. }) => {
                assert!(
                    message.contains("duplicate actor_id"),
                    "unexpected error: {message}"
                );
            }
            other => panic!("expected Malformed error, got {other:?}"),
        }
    }

    /// Replay TOLERATES a duplicate `actor_id` with the SAME
    /// address (idempotent re-assertion, possibly from operator
    /// recovery procedures).
    #[test]
    fn replay_tolerates_duplicate_actor_id_with_same_address() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        let line1 = serde_json::to_string(&StateRecord::AddressAssigned {
            address: HexBytes(vec![0x01; 20]),
            actor_id: 3,
        })
        .unwrap();
        // Same address + id as line1.  This is benign repetition.
        let line2 = line1.clone();
        std::fs::write(&path, format!("{line1}\n{line2}\n")).unwrap();
        let (_, state) = StateStore::open(&path).unwrap();
        assert_eq!(state.address_book.len(), 1);
    }

    /// Submitted records with conflicting actor_ids are also
    /// rejected.
    #[test]
    fn replay_rejects_submitted_records_with_duplicate_actor_id() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("state.jsonl");
        {
            let (mut store, _) = StateStore::open(&path).unwrap();
            store
                .append(&StateRecord::Submitted {
                    block_hash: HexBytes(vec![0x11; 32]),
                    tx_hash: HexBytes(vec![0x22; 32]),
                    log_index: 0,
                    next_nonce: 1,
                    assigned: Some(AddressAssignment {
                        address: HexBytes(vec![0xaa; 20]),
                        actor_id: 3,
                    }),
                })
                .unwrap();
            store
                .append(&StateRecord::Submitted {
                    block_hash: HexBytes(vec![0x33; 32]),
                    tx_hash: HexBytes(vec![0x44; 32]),
                    log_index: 0,
                    next_nonce: 2,
                    assigned: Some(AddressAssignment {
                        address: HexBytes(vec![0xbb; 20]), // DIFFERENT address
                        actor_id: 3,                       // SAME id
                    }),
                })
                .unwrap();
        }
        let result = StateStore::open(&path);
        match result {
            Err(StateError::Malformed { message, .. }) => {
                assert!(
                    message.contains("duplicate actor_id"),
                    "unexpected error: {message}"
                );
            }
            other => panic!("expected Malformed error, got {other:?}"),
        }
    }
}
