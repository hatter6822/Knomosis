// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `canon-faultproof-observer` — RH-G.
//!
//! Long-running daemon that watches Ethereum L1 for fault-proof
//! bisection-game events, computes the honest response via a
//! Lean-mirrored game-state machine + a deployment-supplied
//! truth oracle, and submits responses on-chain.  See
//! `docs/planning/rust_host_runtime_plan.md` §RH-G,
//! `docs/fault_proof_runbook.md` §7, and the seven sub-sub-units
//! RH-G.1 .. RH-G.7 documented in the planning file.
//!
//! ## What this crate provides
//!
//!   * [`game`] — Rust port of `LegalKernel.FaultProof.Game`.
//!     Game-state machine + transition function, byte-equivalent
//!     to Lean's `applyTransition`.
//!   * [`strategy`] — Rust port of `LegalKernel.FaultProof.Strategy`.
//!     Honest-strategy computation: given the truthful commit
//!     function and a game state, compute the unique honest
//!     move.
//!   * [`events`] — L1 event-topic registry + decoder for the
//!     bisection-game contract's five events (`FaultProofGameOpened`,
//!     `BisectionMidpointSubmitted`, `BisectionResponseSubmitted`,
//!     `FaultProofGameSettled`, `StateRootSubmitted`).
//!   * [`watcher`] — L1 event-watch subsystem.  Reuses
//!     `canon-l1-ingest`'s sliding-window re-org tracker and
//!     `L1Source` trait surface; adds game-event-specific
//!     decoding.
//!   * [`submitter`] — L1 transaction calldata encoder + a
//!     submission trait with a mock implementation for tests.
//!     The production JSON-RPC submitter is sketched as a public
//!     trait API but the actual `eth_sendRawTransaction` driver
//!     is RH-G follow-up work (the calldata contract is
//!     stable; the transport layer is fungible).
//!   * [`persistence`] — `canon-storage`-backed persistence
//!     layer.  Three keyspaces: games, response records, watcher
//!     cursor.  Atomic batch commits.
//!   * [`observer`] — Top-level orchestrator.  Ties the watcher,
//!     game state, strategy, submitter, and persistence together
//!     into a single long-running daemon.
//!   * [`config`] — CLI argument parsing for the binary.
//!   * [`error`] — Top-level error type + exit-code mapping.
//!
//! ## Mathematical contract
//!
//! For every legal `(GameState, GameTransition)` pair, the Rust
//! [`game::apply_transition`] MUST produce the same byte
//! representation as the Lean reference `applyTransition`.  This
//! is the load-bearing correctness property of the observer; the
//! property tests (see `tests/property.rs`) verify it on random
//! traces.  Conjecturally (and verifiable at SC.3 corpus time),
//! every honest move's calldata equals the corresponding Lean-
//! computed calldata.
//!
//! ## Security properties
//!
//!   1. **Re-org tolerance.**  Events are only processed after
//!      reaching `confirmation_depth` blocks of confirmation
//!      (default 12).  Shallow re-orgs (depth ≤ `reorg_window`)
//!      are absorbed by the sliding window; deeper re-orgs halt
//!      the daemon with an operator alert.  Defence-in-depth:
//!      the watcher fetches logs by **block hash**, not by
//!      number, so an L1 re-org racing the header→logs fetch
//!      sequence resolves to a typed error rather than wrong-fork
//!      logs being processed.
//!   2. **Idempotency.**  Every persisted update goes through an
//!      atomic `canon_storage::Storage::transaction` together
//!      with the watcher cursor advance.  A crash mid-batch
//!      leaves the cursor at its pre-batch value; the next
//!      iteration re-delivers the failing events.  Per-pivot
//!      submission deduplication defends against duplicate
//!      submissions on restart.
//!   3. **Cross-deployment-replay defence — INCOMPLETE.**  The
//!      observer's
//!      [`ObserverConfig::deployment_id`](observer::ObserverConfig)
//!      is stamped onto each adopted game's record, but the
//!      `FaultProofGameOpened` event payload does NOT carry the
//!      contract's `deploymentId` field — actual cross-deployment
//!      validation requires an `eth_call` to `games(uint256)` on
//!      the contract to read the persisted state.  That contract
//!      read is deferred RH-G follow-up work.  Until it lands,
//!      operators MUST point the observer at the correct game
//!      contract address for their deployment (the `deploymentId`
//!      embedded in the contract is the runtime authority).
//!   4. **Cold-start game safety.**  Games opened before the
//!      observer started watching are adopted into the in-memory
//!      map with `state_known = false` (the full range bounds /
//!      sequencer / challenger / bonds are not in the event
//!      payload).  The orchestrator's `maybe_play_move` REFUSES
//!      to compute or submit moves for `state_known = false`
//!      games until the contract-state read lands.  This
//!      defends against the observer broadcasting wrong-shape
//!      calldata derived from placeholder range bounds.
//!   5. **Key zeroization.**  The signing key is held behind
//!      `Zeroizing<[u8; 32]>` (via
//!      [`canon_l1_ingest::key::BridgeActorKey`]) and scrubs on
//!      drop.
//!   6. **Loud failure modes.**  Configuration errors, deep
//!      re-orgs, persistent state corruption, and invariant
//!      violations all map to
//!      [`canon_cli_common::exit::OperatorExitCode::OperatorAction`]
//!      so a supervisor can distinguish them from transient
//!      failures (which retry with backoff).  Transient L1-RPC
//!      issues (transport, `NonMonotone` block gaps) map to
//!      `Transient` and trigger retry with backoff.
//!   7. **No panics on attacker input.**  Every L1 event-decoder
//!      error path returns a typed
//!      [`events::EventDecodeError`]; every state-machine
//!      transition rejection returns a typed [`game::GameError`].
//!   8. **No `unsafe`.**  `unsafe_code = "forbid"` workspace
//!      lint.  The observer is a pure-Rust orchestrator; the
//!      crypto primitives live behind the `canon-l1-ingest`'s
//!      audited `k256`-based key wrapper.
//!   9. **Bounded configuration.**  Every operator-tunable
//!      parameter (confirmation depth, reorg window capacity,
//!      blocks per iteration) is bounded above by a hard
//!      compile-time constant in [`watcher`].  Defends against
//!      operator-typo-induced OOM / memory-bomb scenarios.
//!  10. **Wrong-selector calldata refused.**  The
//!      `TerminateOnSingleStep` honest move requires a full-form
//!      calldata (action variant + cell-proof bundle) that the
//!      off-chain observer cannot synthesise alone.  The minimum-
//!      form calldata's selector does NOT match the deployed
//!      contract; [`submitter::encode_calldata`] refuses to
//!      silently emit it.  Operators submit the full-form
//!      transaction manually until the canon-subprocess pipeline
//!      lands.
//!
//! ## What this RH-G landing ships
//!
//!   * RH-G.1 — Crate skeleton + dependency vendoring.
//!     **Complete**.
//!   * RH-G.2 — L1 event-watch with re-org handling.
//!     **Complete** (mock + JSON-RPC source via
//!     `canon-l1-ingest`).
//!   * RH-G.3 — Game-state machine.  **Complete** (Rust port +
//!     property tests against the Lean reference's invariants).
//!   * RH-G.4 — Honest-strategy computation.  **Complete**
//!     (memory + subprocess truth oracle traits + the strategy
//!     decision tree mirroring Lean's `honestStrategy`).  The
//!     subprocess-truth-oracle implementation is sketched as
//!     `SubprocessTruthOracle` but the actual `canon
//!     --replay-up-to` subcommand is deferred Lean-side work
//!     (mirrors the pattern for RH-D's `extract-events`
//!     subcommand).
//!   * RH-G.5 — Response submission + signing.  **Complete**
//!     (calldata encoder + mock submitter; the JSON-RPC submitter
//!     is sketched and the EIP-1559 transaction encoder is RH-G
//!     follow-up work).
//!   * RH-G.6 — Persistence + crash recovery.  **Complete**
//!     (canon-storage-backed games + responses + cursor;
//!     atomic-batch commits; identifier-cell discipline).
//!   * RH-G.7 — Cross-stack equivalence corpus + chaos suite.
//!     **Partial** — the property tests exercise re-org +
//!     bisection convergence + idempotency; the corpus-driven
//!     cross-stack tests (Lean-generated game traces) are
//!     deferred to a future cross-stack landing once the
//!     Lean side ships an equivalent generator.

#![doc(html_root_url = "https://docs.rs/canon-faultproof-observer/0.2.5")]

pub mod config;
pub mod error;
pub mod events;
pub mod game;
pub mod jsonrpc_submitter;
pub mod observer;
pub mod persistence;
pub mod state_reader;
pub mod strategy;
pub mod submitter;
pub mod watcher;

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "canon-faultproof-observer";

/// The crate's published version (auto-populated by `cargo` from
/// `Cargo.toml`).
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The implementation identifier this observer publishes through
/// startup diagnostics and the storage's `w/identifier` cell.
/// Bumped if the storage layout or game-state representation
/// changes incompatibly.  Mirrored from
/// [`persistence::OBSERVER_IDENTIFIER`].
pub const OBSERVER_IDENTIFIER: &str = persistence::OBSERVER_IDENTIFIER;

/// The observer's protocol version.  Bumped if the wire-format
/// contract between this crate and the Lean reference (game-
/// state machine, honest strategy, calldata encoding) changes.
pub const PROTOCOL_VERSION: u32 = 1;

#[cfg(test)]
mod tests {
    use super::{CRATE_NAME, OBSERVER_IDENTIFIER, PROTOCOL_VERSION, VERSION};

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "canon-faultproof-observer");
    }

    /// Identifier constant is the documented v1 string.
    #[test]
    fn identifier_constant() {
        assert_eq!(OBSERVER_IDENTIFIER, "canon-faultproof-observer/v1");
    }

    /// Protocol version starts at 1 and is bumped by amendment.
    #[test]
    fn protocol_version_constant() {
        assert_eq!(PROTOCOL_VERSION, 1);
    }

    /// Version constant matches the workspace package version.
    #[test]
    fn version_constant_non_empty() {
        #[allow(clippy::const_is_empty)]
        let v: &str = VERSION;
        assert!(v.chars().next().is_some_and(|c| c.is_ascii_digit()));
    }
}
