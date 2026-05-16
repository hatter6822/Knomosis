// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `canon-l1-ingest` — RH-B.
//!
//! Long-running daemon that watches Ethereum L1, translates the
//! relevant `CanonBridge.sol` / `CanonIdentityRegistry.sol` events
//! into Canon `SignedAction`s via the bridge-actor signing flow,
//! and forwards them to `canon-host` for L2 admission.
//!
//! ## What this crate provides
//!
//!   * [`action`] — Rust mirror of Lean's `Authority.Action`
//!     inductive (`registerIdentity`, `replaceKey`, `deposit`, ...).
//!     Only the constructor indices the ingestor actually emits
//!     have first-class enum variants; others (deposit / withdraw)
//!     live in the encoding module as expected forward-extension
//!     points.
//!   * [`address_book`] — `EthAddress → ActorId` map matching
//!     Lean's `Bridge/AddressBook.lean`.  The `assign` /
//!     `lookup` discipline is the byte-identical Rust counterpart.
//!   * [`encoding`] — CBE / signing-input encoder matching Lean's
//!     `Encoding/Action.lean` + `Authority/SignedAction.lean`.
//!     Hand-rolled to avoid pulling in a generic CBOR library —
//!     every wire byte is intentional.
//!   * [`events`] — typed `IngestedEvent` enum: decoded from raw
//!     Ethereum log records by the JSON-RPC layer.
//!   * [`key`] — bridge-actor keystore.  Private-key material
//!     lives behind `zeroize::Zeroizing<Vec<u8>>` so it scrubs on
//!     drop.
//!   * [`reorg`] — sliding-window block-hash tracker for re-org
//!     detection.  Documented to be reused by RH-G (fault-proof
//!     observer) once that work unit lands.
//!   * [`source`] — `L1Source` trait + a JSON-RPC implementation.
//!     Production deployments instantiate the JSON-RPC variant;
//!     tests use the in-memory mock.
//!   * [`state`] — persistent watcher state (last confirmed
//!     block, forwarded-event ledger).  JSONL on disk so it is
//!     human-inspectable.
//!   * [`submitter`] — `Submitter` trait + a sketched HTTP-to-
//!     `canon-host` impl.  The plan's RH-C wire format is the
//!     downstream contract; we ship a stub that buffers actions
//!     for replay until RH-C lands.
//!   * [`translation`] — pure `ingest(book, event)` function
//!     matching Lean's `Bridge/Ingest.lean::ingest`.  This is the
//!     byte-equivalence boundary checked by the cross-stack
//!     corpus.
//!   * [`watcher`] — top-level orchestrator: pulls confirmed
//!     blocks from `L1Source`, decodes events, runs translation,
//!     signs, submits.
//!
//! ## Wire-format contract
//!
//! Two byte-level contracts bind this crate to the Lean kernel:
//!
//!   1. **Action encoding.** Each [`action::Action`] encodes to
//!      identical bytes as the matching `LegalKernel.Encoding.
//!      Action.encode`.  Verified by every cross-stack fixture
//!      (`FixtureKind::L1Ingest`).
//!   2. **Signing input.** Each `(action, signer, nonce,
//!      deploymentId)` quadruple's signing-input bytes are
//!      identical to the Lean `Authority.signingInput` output.
//!      This is the load-bearing security property — a mismatch
//!      would make every signed action fail verification on the
//!      L2 side.
//!
//! ## Security properties
//!
//!   1. **Re-org tolerance.**  Events are only forwarded after
//!      reaching `confirmation_depth` blocks of confirmation
//!      (default `DEFAULT_L1_CONFIRMATION_DEPTH = 12`).  Shallow
//!      re-orgs (depth ≤ confirmation_depth) are absorbed by the
//!      sliding window; deeper re-orgs halt the daemon with an
//!      operator alert.  Defence-in-depth: the watcher fetches
//!      logs by **block hash**, not by number, so an L1 re-org
//!      racing the header→logs fetch sequence resolves to a
//!      typed error rather than wrong-fork logs being processed.
//!   2. **Idempotency.**  Every forwarded event is recorded by
//!      `(block_hash, tx_hash, log_index)` triple; duplicates
//!      are silently dropped at the watcher boundary.  The
//!      forwarded set survives restarts via the JSONL state
//!      file's `Submitted` records.
//!   3. **Atomic state mutations.**  Each successful submission
//!      writes a single atomic `Submitted` JSONL record carrying
//!      the new forwarded-key, new `next_nonce`, and (optional)
//!      address-book assignment.  Line-level atomicity at the
//!      OS prevents the partial-failure window that the previous
//!      three-record sequence (`AddressAssigned` +
//!      `NonceProgressed` + `Forwarded`) was vulnerable to.
//!   4. **Address book preview/commit.**  Translation is
//!      peek-only via `preview_ingest`; the address book is only
//!      mutated AFTER submission succeeds.  This prevents the
//!      bug where a failed submission left the book in a
//!      half-mutated state, causing retries to emit `ReplaceKey`
//!      instead of `RegisterIdentity`.
//!   5. **Nonce tracking from explicit records.**  The watcher
//!      reconstructs `next_nonce` at startup from the maximum
//!      `Submitted::next_nonce` value across the state file —
//!      NOT from `forwarded.len()`, which over-counts by the
//!      number of `None`-translating events (`Revoked`,
//!      `DepositInitiated`).
//!   6. **Key zeroization.**  The bridge-actor private key is
//!      wrapped in `Zeroizing<[u8; 32]>` and scrubs on drop.
//!      The transient `SigningKey` derived in each `sign_prehash`
//!      call also zeroizes on drop (via `ecdsa`'s
//!      `ZeroizeOnDrop` impl).  The key is never written to
//!      disk in our code path and never exposed through public
//!      APIs.
//!   7. **No panics on attacker input.**  The HTTP / JSON-RPC
//!      parser's malformed-input paths return typed errors; the
//!      ABI decoder's malformed-event paths return typed errors.
//!      The daemon halts on permanent errors with
//!      `OperatorExitCode::OperatorAction`.
//!   8. **Low-s ECDSA signing.**  `BridgeActorKey::sign_prehash`
//!      emits low-s signatures (`s ≤ n/2`) by both relying on
//!      `k256` v0.13's default behaviour and applying a
//!      belt-and-suspenders `normalize_s` post-sign.  This is
//!      the load-bearing contract with `canon-verify-secp256k1`
//!      (RH-A.1): the verifier rejects high-s signatures.
//!
//! ## Cross-stack corpus
//!
//! Two kinds of fixtures live in `runtime/tests/cross-stack/`:
//!
//!   * `l1_ingest.cxsf` — `FixtureKind::L1Ingest`.  Each record's
//!     `input` is a serialised `(IngestedEvent, AddressBook
//!     snapshot, current_nonce)` triple; the `expected` field is
//!     the CBE-encoded Action that the Rust translator must
//!     produce.
//!
//! The fixture file is regenerated by the binary at
//! `examples/gen_ingest_fixtures.rs`.  CI verifies byte-equality
//! against the committed corpus on every PR.

#![doc(html_root_url = "https://docs.rs/canon-l1-ingest/0.1.0")]

pub mod action;
pub mod address_book;
pub mod encoding;
pub mod events;
pub mod fixture;
pub mod key;
pub mod reorg;
pub mod source;
pub mod state;
pub mod submitter;
pub mod translation;
pub mod watcher;

/// Crate name, mirrored from `Cargo.toml`.
pub const CRATE_NAME: &str = "canon-l1-ingest";

/// The implementation identifier this ingestor publishes through
/// startup diagnostics.  Mirrors the
/// `LegalKernel.Bridge.Ingest`-side coverage tag so operators can
/// confirm at startup which translation table is linked.
pub const INGEST_IDENTIFIER: &str = "canon-l1-ingest/v1";

/// The L1 ingest workstream's protocol version.  Bumped if the
/// wire-format contract between this crate and the Lean kernel
/// changes (e.g. a new constructor frozen index lands on the
/// Lean side and the translator emits it).
pub const PROTOCOL_VERSION: u32 = 1;

#[cfg(test)]
mod tests {
    use super::{CRATE_NAME, INGEST_IDENTIFIER, PROTOCOL_VERSION};

    /// Crate-name constant doesn't drift silently.
    #[test]
    fn crate_name_constant() {
        assert_eq!(CRATE_NAME, "canon-l1-ingest");
    }

    /// Identifier constant is the documented v1 string.
    #[test]
    fn identifier_constant() {
        assert_eq!(INGEST_IDENTIFIER, "canon-l1-ingest/v1");
    }

    /// Protocol version starts at 1 and is bumped by amendment.
    #[test]
    fn protocol_version_constant() {
        assert_eq!(PROTOCOL_VERSION, 1);
    }
}
