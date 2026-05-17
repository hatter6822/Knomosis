// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `canon-indexer` — RH-E.1.
//!
//! Long-running daemon that consumes events from a running
//! `canon-event-subscribe` (RH-D) and maintains a per-(actor,
//! resource) balance view in a `canon-storage` (RH-E.0) database.
//!
//! ## What this crate provides
//!
//!   * [`event`] — typed Rust `Event` enum mirroring Lean's
//!     `Events.Event` constructor list and frozen tag indices
//!     (0..15).  See `docs/abi.md` §5.3 and `LegalKernel/Events/Types.lean`.
//!   * [`decoder`] — CBE decoder for `Event` payload bytes.
//!     Mirrors the CBE conventions in `canon-l1-ingest/src/encoding.rs`
//!     so the decoder remains compatible once the Lean side ships
//!     an `Encodable Event` instance (Phase 5 follow-up).
//!   * [`balance`] — balance-view abstraction over the `Storage`
//!     trait.  Per-(actor, resource) cells keyed by fixed-length
//!     BE byte strings.
//!   * [`cursor`] — last-processed-seq tracker for idempotent
//!     restart.  Stored under a reserved meta-key in the same
//!     `Storage` so the indexer + cursor commit atomically.
//!   * [`indexer`] — orchestration: subscribe → decode → dispatch
//!     event to balance view → checkpoint cursor.  Each event
//!     batch is applied inside a single storage transaction so the
//!     balance updates + cursor advance commit atomically.
//!   * [`client`] — TCP client for the `canon-event-subscribe`
//!     wire protocol (see `docs/abi.md` §11 and
//!     `runtime/canon-event-subscribe/src/frame.rs`).
//!   * [`config`] — CLI flag parsing for the binary.
//!
//! ## Storage layout
//!
//! Three keyspaces co-exist in the storage:
//!
//! ```text
//! key prefix          | content                            | format
//! --------------------+------------------------------------+------------------
//! "b/" + actor(8BE) + | balance for this (actor, resource) | 16-byte BE u128
//! resource(8BE)        |                                    |
//! "c/cursor"          | last successfully-processed seq    | 8-byte BE u64
//! "c/identifier"      | indexer identifier string          | UTF-8 text
//! ```
//!
//! The prefixes use distinct first bytes so a `scan(b"b/")` enumerates
//! all balances without touching the cursor.  Future keyspaces
//! (e.g. per-(actor, key) identity registry) follow the same
//! prefix discipline; the choice of single-character prefixes
//! keeps SQLite's primary-key index scans tight.
//!
//! ## Idempotent restart
//!
//! On startup the indexer reads the `c/cursor` key.  If present,
//! the client subscribes with `resume_from = cursor_value`.  Per
//! the §11 wire format, the server then sends every event with
//! `seq > cursor_value`.  After processing each event batch, the
//! indexer atomically writes the updated balance rows + new
//! cursor value inside a single `Storage::transaction`.
//!
//! ## Event dispatch
//!
//! The indexer dispatches on `Event.tag`:
//!
//!   * `balanceChanged(r, a, _, newV)` (tag 0) → set
//!     `balance[(a, r)] = newV`.
//!   * `depositCredited(r, a, amount, _)` (tag 10) → increment
//!     `balance[(a, r)] += amount`.
//!   * `withdrawalRequested(r, a, amount, _, _)` (tag 9) →
//!     decrement `balance[(a, r)] -= amount`.
//!   * `rewardIssued(r, a, amount)` (tag 8) → increment
//!     `balance[(a, r)] += amount`.
//!   * Other tags (`nonceAdvanced`, `identityRegistered`, etc.)
//!     are no-ops at the balance-view layer.  Future indexers
//!     can extend the dispatch table to maintain additional
//!     views.
//!
//! **Mathematical contract.**  After processing every event in
//! the log, the indexer's balance view MUST equal `canon-host`'s
//! `getBalance(actor, resource)` for every (actor, resource) pair.
//! This invariant is the load-bearing correctness property of the
//! indexer; it is checked by the `--verify-against-canon` flag
//! (deferred Lean-side work; the indexer carries the flag in its
//! CLI now so the deployment integration lands without a flag
//! change later).
//!
//! ## Why mathematical soundness matters
//!
//! The indexer is a **derived view**, not part of the kernel TCB.
//! Bugs here produce wrong query answers but cannot violate kernel
//! invariants.  However, deployment-facing components (operator
//! dashboards, billing systems, regulators) consume the indexer's
//! balance view; an off-by-one or stale-snapshot bug propagates
//! to user-visible numbers.  The full property-test suite + the
//! per-event dispatch table contract above pin the math.
//!
//! ## Security posture
//!
//!   * `unsafe_code = "forbid"`.  Pure-Rust orchestration.
//!   * Every error path returns a typed enum; no `panic!` on
//!     attacker-supplied bytes.
//!   * Subscribe-client reads bounded-length frames; oversize
//!     frames return a typed error.
//!   * Database is opened read-write but the wire-format authority
//!     (canon-host) is the only writer to the canonical log; the
//!     indexer only reads from canon-event-subscribe (which itself
//!     opens the log read-only).
//!   * Balance arithmetic uses checked saturation: an overflow on
//!     deposit/reward credits the balance to `u128::MAX` and
//!     returns a typed error; an underflow on withdraw rejects
//!     the event with a typed error.  This defends against a
//!     malformed event source emitting nonsensical amounts.

#![doc(html_root_url = "https://docs.rs/canon-indexer/0.2.0")]

pub mod balance;
pub mod client;
pub mod config;
pub mod cursor;
pub mod decoder;
pub mod event;
pub mod indexer;

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "canon-indexer";

/// The crate's published version (auto-populated by `cargo` from
/// `Cargo.toml`).
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The implementation identifier this indexer publishes through
/// startup diagnostics and the storage's `c/identifier` cell.
/// Bumped if the storage layout changes incompatibly.
pub const INDEXER_IDENTIFIER: &str = "canon-indexer/v1";

#[cfg(test)]
mod tests {
    use super::{CRATE_NAME, INDEXER_IDENTIFIER, VERSION};

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "canon-indexer");
    }

    /// Identifier constant is the documented v1 string.
    #[test]
    fn identifier_constant() {
        assert_eq!(INDEXER_IDENTIFIER, "canon-indexer/v1");
    }

    /// Version constant non-empty (auto-populated by cargo).
    #[test]
    fn version_constant_non_empty() {
        #[allow(clippy::const_is_empty)]
        let v: &str = VERSION;
        assert!(v.chars().next().is_some_and(|c| c.is_ascii_digit()));
    }
}
