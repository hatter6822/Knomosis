// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-indexer` — RH-E.1.
//!
//! Long-running daemon that consumes events from a running
//! `knomosis-event-subscribe` (RH-D) and maintains a per-(actor,
//! resource) balance view in a `knomosis-storage` (RH-E.0) database.
//!
//! ## What this crate provides
//!
//!   * [`event`] — typed Rust `Event` enum mirroring Lean's
//!     `Events.Event` constructor list and frozen tag indices
//!     (0..19).  See `docs/abi.md` §5.3 and
//!     `LegalKernel/Events/Types.lean`.  Tags 16..=19 are the
//!     Workstream-GP gas-pool family (`DepositWithFeeCredited`,
//!     `ActionBudgetTopUp`, `GasPoolClaim`,
//!     `DelegatedActionBudgetTopUp`) added in GP.6.4.
//!   * [`decoder`] — CBE decoder for `Event` payload bytes.
//!     Mirrors the CBE conventions in `knomosis-l1-ingest/src/encoding.rs`
//!     and the Lean `Encoding/Event.lean` authority.
//!   * [`balance`] — balance-view abstraction over the `Storage`
//!     trait.  Per-(actor, resource) cells keyed by fixed-length
//!     BE byte strings.
//!   * [`budget_view`] (GP.6.4) — per-actor cumulative budget
//!     view + per-resource gas-pool inflow views (ETH and BOLD
//!     legs tracked separately).  Sourced from the GP-family
//!     events; updates atomically alongside the balance view.
//!   * [`cursor`] — last-processed-seq tracker for idempotent
//!     restart.  Stored under a reserved meta-key in the same
//!     `Storage` so the indexer + cursor commit atomically.
//!   * [`indexer`] — orchestration: subscribe → decode → dispatch
//!     event to balance view + budget view → checkpoint cursor.
//!     Each event batch is applied inside a single storage
//!     transaction so the balance updates, budget updates, and
//!     cursor advance commit atomically.
//!   * [`client`] — TCP client for the `knomosis-event-subscribe`
//!     wire protocol (see `docs/abi.md` §11 and
//!     `runtime/knomosis-event-subscribe/src/frame.rs`).
//!   * [`config`] — CLI flag parsing for the binary.
//!
//! ## Storage layout
//!
//! Five keyspaces co-exist in the storage:
//!
//! ```text
//! key prefix          | content                            | format
//! --------------------+------------------------------------+------------------
//! "b/" + actor(8BE) + | balance for this (actor, resource) | 16-byte BE u128
//! resource(8BE)        |                                    |
//! "c/cursor"          | last successfully-processed seq    | 8-byte BE u64
//! "c/identifier"      | indexer identifier string          | UTF-8 text
//! "u/" + actor(8BE)   | cumulative budget grants (GP.6.4)  | 16-byte BE u128
//! "pe/" + actor(8BE)  | cumulative ETH pool inflows        | 16-byte BE u128
//! "pb/" + actor(8BE)  | cumulative BOLD pool inflows       | 16-byte BE u128
//! ```
//!
//! The prefixes use distinct leading bytes so a `scan(b"b/")` enumerates
//! all balances without touching the cursor, budget, or pool views.
//! Future keyspaces (e.g. per-(actor, key) identity registry) follow
//! the same prefix discipline; the choice of single-/three-character
//! prefixes keeps SQLite's primary-key index scans tight.
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
//! The indexer dispatches on `Event.tag` to two complementary
//! views: the canonical balance view (always on) and the GP.6.4
//! budget / pool view (in scope only for the GP family).
//!
//! **Balance view (tags 0/8/9/10):**
//!
//!   * `balanceChanged(r, a, _, newV)` (tag 0) → set
//!     `balance[(a, r)] = newV`.
//!   * `depositCredited(r, a, amount, _)` (tag 10) → increment
//!     `balance[(a, r)] += amount`.
//!   * `withdrawalRequested(r, a, amount, _, _)` (tag 9) →
//!     decrement `balance[(a, r)] -= amount`.
//!   * `rewardIssued(r, a, amount)` (tag 8) → increment
//!     `balance[(a, r)] += amount`.
//!
//! **Budget / pool view (tags 16/17/19; tag 18 is a future
//! drain event):**
//!
//!   * `depositWithFeeCredited(r, recipient, p, _, pa, bg, _)`
//!     (tag 16) → `actor_budgets[recipient] += bg`; and if
//!     `r ∈ {0, 1}` then `pool_balances_{eth|bold}[p] += pa`.
//!   * `actionBudgetTopUp(signer, gr, ga, bi, p)` (tag 17) →
//!     `actor_budgets[signer] += bi`; and if `gr ∈ {0, 1}`
//!     then `pool_balances_{eth|bold}[p] += ga`.
//!   * `delegatedActionBudgetTopUp(recipient, _, gr, ga, bi, p)`
//!     (tag 19) → `actor_budgets[recipient] += bi`
//!     (NOT the signer); and if `gr ∈ {0, 1}` then
//!     `pool_balances_{eth|bold}[p] += ga`.
//!   * `gasPoolClaim(_, _, _)` (tag 18) → no-op at this WU.
//!     Drain semantics deferred to GP.7.
//!
//! Other tags (`nonceAdvanced`, `identityRegistered`, dispute /
//! verdict / fault-proof / local-policy events) are no-ops at
//! both view layers.  Future indexers can extend the dispatch
//! table to maintain additional views.
//!
//! **Mathematical contract.**  After processing every event in
//! the log, the indexer's balance view MUST equal `knomosis-host`'s
//! `getBalance(actor, resource)` for every (actor, resource) pair.
//! This invariant is the load-bearing correctness property of the
//! indexer; it is checked by the `--verify-against-knomosis` flag
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
//!     (knomosis-host) is the only writer to the canonical log; the
//!     indexer only reads from knomosis-event-subscribe (which itself
//!     opens the log read-only).
//!   * Balance arithmetic uses checked saturation: an overflow on
//!     deposit/reward credits the balance to `u128::MAX` and
//!     returns a typed error; an underflow on withdraw rejects
//!     the event with a typed error.  This defends against a
//!     malformed event source emitting nonsensical amounts.

#![doc(html_root_url = "https://docs.rs/knomosis-indexer/0.2.0")]

pub mod balance;
pub mod budget_view;
pub mod client;
pub mod config;
pub mod cursor;
pub mod daemon;
pub mod decoder;
pub mod event;
pub mod indexer;

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "knomosis-indexer";

/// The crate's published version (auto-populated by `cargo` from
/// `Cargo.toml`).
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The implementation identifier this indexer publishes through
/// startup diagnostics and the storage's `c/identifier` cell.
/// Bumped if the storage layout changes incompatibly.
pub const INDEXER_IDENTIFIER: &str = "knomosis-indexer/v1";

#[cfg(test)]
mod tests {
    use super::{CRATE_NAME, INDEXER_IDENTIFIER, VERSION};

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "knomosis-indexer");
    }

    /// Identifier constant is the documented v1 string.
    #[test]
    fn identifier_constant() {
        assert_eq!(INDEXER_IDENTIFIER, "knomosis-indexer/v1");
    }

    /// Version constant non-empty (auto-populated by cargo).
    #[test]
    fn version_constant_non_empty() {
        #[allow(clippy::const_is_empty)]
        let v: &str = VERSION;
        assert!(v.chars().next().is_some_and(|c| c.is_ascii_digit()));
    }
}
