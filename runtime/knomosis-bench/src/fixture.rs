// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Synthetic fixture generator for the RH-F benchmark.
//!
//! ## What this module produces
//!
//! Given a `(seed, actor_count, transfer_count)` triple, this module
//! deterministically produces:
//!
//!   * **Actor keys.**  `actor_count` secp256k1 keypairs, derived
//!     from `(seed, actor_index)` via the documented hash-chain
//!     in [`actor_private_scalar`].  Each actor is assigned the
//!     monotonically-increasing `ActorId` `actor_index as u64`,
//!     so the lookup `actor_id → key` is `O(1)`.
//!   * **Pre-funded balances.**  A symbolic genesis: every actor
//!     starts with [`DEFAULT_PER_ACTOR_BALANCE`] units of resource
//!     `0`.  The genesis is not emitted as bytes by this module —
//!     it's a logical pre-condition the benchmark assumes the
//!     kernel honours.  Under MockKernel (the default), the
//!     assumption is trivially true (every submission returns
//!     Ok).  Under a future real kernel, the harness would need
//!     to ship a `--genesis-log <FILE>` flag that pre-loads
//!     matching genesis state.
//!   * **Pre-signed transfers.**  `transfer_count` valid
//!     [`knomosis_l1_ingest::action::Action::Transfer`] payloads,
//!     each signed with the sender's actor key.  Senders /
//!     receivers / amounts cycle deterministically so the workload
//!     is uniform over the actor set.  Each transfer's nonce is
//!     the sender's monotonically-advancing per-actor counter so
//!     the kernel's nonce-uniqueness gate is exactly satisfied.
//!
//! ## Why deterministic
//!
//! Reproducibility is the load-bearing CI property: two runs with
//! the same `(seed, actor_count, transfer_count)` produce identical
//! payload bytes.  This lets the benchmark's *outputs* be regression-
//! tested (a fixture-generation bug surfaces as a test failure, not
//! as a flaky throughput number).
//!
//! ## Mathematical contract
//!
//!   * `actor_private_scalar(seed, i)` is non-zero and `< n`
//!     (secp256k1 order) for every `(seed, i)` pair via rejection
//!     sampling.  Practical loop iteration count is `< 2^-128` on
//!     average; we cap at 256 attempts before returning an error.
//!   * The signing-input bytes for each generated transfer match
//!     Lean's `Authority.SignedAction.signingInput` byte-for-byte
//!     (via `knomosis-l1-ingest::encoding::signing_input`).  The
//!     emitted `SignedAction` bytes are therefore wire-compatible
//!     with a real Lean-side kernel.

use std::sync::Arc;

use knomosis_l1_ingest::action::{Action, ActorId, Amount, Nonce, ResourceId};
use knomosis_l1_ingest::encoding::{encode_signed_action, signing_input, EncodeError};
use knomosis_l1_ingest::key::{BridgeActorKey, KeyError};
use sha3::{Digest, Keccak256};

/// Default per-actor genesis balance.  Each transfer moves `1` unit;
/// `transfer_count = actor_count × balance` keeps every transfer
/// well-funded for the duration of the benchmark (every sender
/// would need to send `transfer_count / actor_count` times to
/// exhaust their balance; under `DEFAULT_PER_ACTOR_BALANCE = 2^32`
/// this is unreachable for any realistic `transfer_count`).
pub const DEFAULT_PER_ACTOR_BALANCE: u128 = 1u128 << 32;

/// Domain-separation prefix for actor private-scalar derivation.
/// Distinct from any production key-derivation tag so that compromise
/// of a benchmark fixture cannot be substituted into a real
/// deployment's address book.
pub const ACTOR_SCALAR_DOMAIN: &[u8] = b"knomosis-bench/v1/actor-scalar";

/// secp256k1 group order (`n`) in big-endian bytes.  Used by the
/// rejection-sampling loop in [`actor_private_scalar`] to reject
/// candidate scalars `>= n` (which `k256` rejects as
/// `KeyError::InvalidScalar` anyway, but checking upfront avoids
/// the wasted k256 round-trip).
const SECP256K1_ORDER_BE: [u8; 32] = [
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
    0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B, 0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
];

/// Maximum rejection-sampling attempts per actor.  The loop runs
/// `attempt ∈ 0..=MAX_SCALAR_ATTEMPT_INDEX`, so the total number
/// of attempts is `MAX_SCALAR_ATTEMPT_INDEX + 1` (= 256 here).
/// Probability of all 256 attempts rejecting is approximately
/// `(1 - 1 / 2^128) ^ 256 ≈ 1 - 2^-120`; the probability of NEEDING
/// any rejection at all per actor is approximately `2^-128`.
/// Practical loop iteration count: 1.
const MAX_SCALAR_ATTEMPT_INDEX: u8 = 255;

/// Total number of rejection-sampling attempts (one greater than
/// the highest index used in the loop).  Reported in the error
/// variant so it matches the number of hashes actually computed.
const MAX_SCALAR_ATTEMPTS: u16 = MAX_SCALAR_ATTEMPT_INDEX as u16 + 1;

/// Errors returned by the fixture generator.
#[derive(Debug, thiserror::Error)]
pub enum FixtureError {
    /// Could not derive a valid secp256k1 scalar for an actor after
    /// [`MAX_SCALAR_ATTEMPTS`] rejection attempts.  Mathematically
    /// improbable; would indicate a Keccak-256 implementation bug.
    #[error("scalar derivation failed for actor {actor_index} after {attempts} attempts")]
    ScalarDerivation {
        /// The 0-based actor index that failed.
        actor_index: usize,
        /// Number of rejection-sampling attempts that elapsed.
        attempts: u16,
    },
    /// `actor_count` is zero.  At least one actor is required for
    /// the benchmark to have valid sender / receiver pairs.
    #[error("actor_count must be >= 1, got 0")]
    NoActors,
    /// `transfer_count` is zero.  At least one transfer is required.
    #[error("transfer_count must be >= 1, got 0")]
    NoTransfers,
    /// `transfer_amount` exceeds the CBE-encoder canonical bound
    /// (`< 2^64`).  Surfaces upfront at validation rather than
    /// late at encoding time (where the error would surface only on
    /// the first transfer encoding, after we've already paid the
    /// secp256k1 key-derivation cost).
    #[error("transfer_amount {0} exceeds the 2^64 canonical-encoding bound")]
    TransferAmountTooLarge(u128),
    /// `deployment_id.len()` exceeds the CBE byte-string canonical
    /// bound.  Unreachable on 64-bit hosts.
    #[error("deployment_id length {0} exceeds canonical-encoding bound")]
    DeploymentIdTooLarge(usize),
    /// Wraps a `KeyError` from `knomosis-l1-ingest::key`.
    #[error("key construction failed: {0}")]
    Key(#[from] KeyError),
    /// Wraps an `EncodeError` from `knomosis-l1-ingest::encoding`.
    #[error("encoding failed: {0}")]
    Encode(#[from] EncodeError),
}

/// Configuration for fixture generation.
#[derive(Clone, Debug)]
pub struct FixtureConfig {
    /// Fixture seed.  Two runs with the same seed + counts produce
    /// byte-identical output.
    pub seed: u64,
    /// Number of pre-funded actors (default `DEFAULT_ACTOR_COUNT`).
    pub actor_count: usize,
    /// Number of pre-signed transfers (default
    /// `DEFAULT_TRANSFER_COUNT`).
    pub transfer_count: usize,
    /// Genesis balance per actor.  Each Transfer moves 1 unit;
    /// `actor_count × balance` must exceed `transfer_count / actor_count`
    /// to avoid any sender running out of funds mid-bench.
    pub per_actor_balance: u128,
    /// Resource id the transfers move (default 0).
    pub resource_id: ResourceId,
    /// Per-transfer amount in resource units (default 1).
    pub transfer_amount: Amount,
    /// Deployment id (raw bytes).  Mirrors the kernel's
    /// `RuntimeState.deploymentId`.  Defaults to a fixed 16-byte
    /// `"knomosis-bench-dpl0"` sentinel.
    pub deployment_id: Vec<u8>,
}

impl Default for FixtureConfig {
    fn default() -> Self {
        Self {
            seed: crate::DEFAULT_SEED,
            actor_count: crate::DEFAULT_ACTOR_COUNT,
            transfer_count: crate::DEFAULT_TRANSFER_COUNT,
            per_actor_balance: DEFAULT_PER_ACTOR_BALANCE,
            resource_id: 0,
            transfer_amount: 1,
            deployment_id: b"knomosis-bench-dpl0".to_vec(),
        }
    }
}

impl FixtureConfig {
    /// Validate this configuration.  Returns the first
    /// inconsistency found.
    ///
    /// # Errors
    ///
    /// Returns `FixtureError::NoActors` /
    /// `FixtureError::NoTransfers` for empty counts,
    /// `FixtureError::TransferAmountTooLarge` if `transfer_amount`
    /// would overflow CBE's `< 2^64` canonical bound, and
    /// `FixtureError::DeploymentIdTooLarge` for oversized
    /// `deployment_id`.
    pub fn validate(&self) -> Result<(), FixtureError> {
        if self.actor_count == 0 {
            return Err(FixtureError::NoActors);
        }
        if self.transfer_count == 0 {
            return Err(FixtureError::NoTransfers);
        }
        // Pre-check the transfer amount against CBE's `< 2^64`
        // canonical bound.  Without this, the failure would surface
        // only at first-transfer-encoding time inside `generate`,
        // AFTER we've spent O(actor_count) on key derivation.
        if self.transfer_amount >= 1u128 << 64 {
            return Err(FixtureError::TransferAmountTooLarge(self.transfer_amount));
        }
        if self.deployment_id.len() > (1usize << 32) {
            return Err(FixtureError::DeploymentIdTooLarge(self.deployment_id.len()));
        }
        Ok(())
    }
}

/// A generated benchmark fixture.  Holds the actor keypairs (for
/// debugging / verification) and the pre-encoded SignedAction wire
/// bytes (the actual benchmark workload).
///
/// `Arc`-wrapping the `payloads` Vec lets every submitter thread
/// share a single immutable copy of the workload without copying
/// hundreds of MiB.  The runner indexes into the Vec atomically
/// via an `AtomicUsize` cursor.
#[derive(Clone, Debug)]
pub struct Fixture {
    /// Per-actor public keys (33-byte SEC1-compressed).  Indexed by
    /// `ActorId`.  Length == `config.actor_count`.
    pub actor_pubkeys: Vec<[u8; 33]>,
    /// The pre-encoded SignedAction CBE bytes.  One entry per
    /// transfer.  Total length == `config.transfer_count`.  Shared
    /// via `Arc` so submitter threads see an immutable snapshot.
    pub payloads: Arc<Vec<Vec<u8>>>,
    /// The configuration used to generate this fixture.  Carried
    /// for reporting (the report records `(actor_count,
    /// transfer_count, seed)` so the run is reproducible).
    pub config: FixtureConfig,
}

impl Fixture {
    /// Number of pre-encoded payloads.
    #[must_use]
    pub fn len(&self) -> usize {
        self.payloads.len()
    }

    /// True iff `len() == 0`.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.payloads.is_empty()
    }

    /// Average payload size in bytes.  Useful for sanity-checking
    /// that the workload fits the host's `max_frame_size`.
    #[must_use]
    pub fn average_payload_bytes(&self) -> f64 {
        if self.payloads.is_empty() {
            return 0.0;
        }
        let total: usize = self.payloads.iter().map(Vec::len).sum();
        total as f64 / self.payloads.len() as f64
    }

    /// Maximum payload size in bytes.  Used to surface frame-size
    /// configuration drift at fixture-generation time rather than
    /// at the first oversize-frame rejection in-flight.
    #[must_use]
    pub fn max_payload_bytes(&self) -> usize {
        self.payloads.iter().map(Vec::len).max().unwrap_or(0)
    }
}

/// Derive an actor's 32-byte secp256k1 private scalar from
/// `(seed, actor_index)` via the documented hash chain:
///
///   `scalar_i = keccak256(ACTOR_SCALAR_DOMAIN ‖ seed_BE ‖ index_LE ‖ attempt)`
///
/// Rejection-samples until the resulting scalar is non-zero and
/// `< n` (secp256k1 order).  Probability per attempt is
/// approximately `1 - 2^-128`, so the first attempt almost always
/// succeeds.
///
/// # Errors
///
/// Returns `FixtureError::ScalarDerivation` after
/// [`MAX_SCALAR_ATTEMPTS`] failed attempts.
pub fn actor_private_scalar(seed: u64, actor_index: usize) -> Result<[u8; 32], FixtureError> {
    for attempt in 0..=MAX_SCALAR_ATTEMPT_INDEX {
        let mut hasher = Keccak256::new();
        hasher.update(ACTOR_SCALAR_DOMAIN);
        hasher.update(seed.to_be_bytes());
        hasher.update((actor_index as u64).to_le_bytes());
        hasher.update([attempt]);
        let digest = hasher.finalize();
        let mut out = [0u8; 32];
        out.copy_from_slice(&digest);
        if scalar_in_range(&out) {
            return Ok(out);
        }
    }
    Err(FixtureError::ScalarDerivation {
        actor_index,
        attempts: MAX_SCALAR_ATTEMPTS,
    })
}

/// Big-endian byte comparison: `scalar > 0 ∧ scalar < n`.  The
/// secp256k1 spec mandates this range; both `k256` and `signer`
/// libraries enforce it at construction time, but pre-checking
/// here avoids the wasted round-trip on a rejected candidate.
fn scalar_in_range(scalar: &[u8; 32]) -> bool {
    // Reject zero.
    if scalar.iter().all(|&b| b == 0) {
        return false;
    }
    // Reject `>= n`: lex-compare big-endian bytes.
    for (s, n) in scalar.iter().zip(SECP256K1_ORDER_BE.iter()) {
        if *s < *n {
            return true; // strictly less: in range.
        }
        if *s > *n {
            return false; // strictly greater: out of range.
        }
    }
    // All bytes equal: scalar == n exactly; out of range.
    false
}

/// Generate a [`Fixture`] from a [`FixtureConfig`].  Deterministic
/// in `(config.seed, config.actor_count, config.transfer_count,
/// config.deployment_id)`.
///
/// ## Cost
///
/// `O(actor_count)` Keccak-256 hashes + secp256k1 keypair
/// derivations + `O(transfer_count)` Keccak-256 signing-input
/// hashes + ECDSA signatures.  On a modern x86_64 the ECDSA
/// signatures dominate at ~25 µs / sig; 10000 signatures ≈ 250 ms.
/// The fixture is generated **once** at the start of a benchmark
/// run; per-iteration cost is the wire-write only.
///
/// # Errors
///
/// See [`FixtureError`].  All error paths are deterministic given
/// the config; a returned error is reproducible.
pub fn generate(config: &FixtureConfig) -> Result<Fixture, FixtureError> {
    config.validate()?;

    // 1. Build the actor keys.  Stored on the stack (small;
    //    33 bytes × actor_count) so we can iterate fast.
    let mut actor_keys: Vec<BridgeActorKey> = Vec::with_capacity(config.actor_count);
    let mut actor_pubkeys: Vec<[u8; 33]> = Vec::with_capacity(config.actor_count);
    for actor_index in 0..config.actor_count {
        let scalar = actor_private_scalar(config.seed, actor_index)?;
        let key = BridgeActorKey::from_private_bytes(&scalar)?;
        actor_pubkeys.push(key.public_key_compressed());
        actor_keys.push(key);
    }

    // 2. Per-actor monotonic nonce counter.  Each Transfer the
    //    actor signs bumps this; nonce uniqueness is mandatory
    //    per the kernel's §8.5 admissibility gate.
    let mut per_actor_nonce: Vec<Nonce> = vec![0u128; config.actor_count];

    // 3. Generate the transfers.  Round-robin senders / receivers
    //    so the workload is uniform over the actor set.  Each
    //    sender's nonce strictly increases.
    let mut payloads: Vec<Vec<u8>> = Vec::with_capacity(config.transfer_count);
    for i in 0..config.transfer_count {
        let sender_index = i % config.actor_count;
        // Receiver = sender + 1 mod actor_count (so sender != receiver
        // for actor_count > 1; for actor_count == 1 self-transfer is
        // the only option, which the §4.11 amendment now accepts).
        let receiver_index = if config.actor_count > 1 {
            (sender_index + 1) % config.actor_count
        } else {
            sender_index
        };

        let sender = sender_index as ActorId;
        let receiver = receiver_index as ActorId;
        let action = Action::Transfer {
            r: config.resource_id,
            sender,
            receiver,
            amount: config.transfer_amount,
        };

        let nonce = per_actor_nonce[sender_index];
        per_actor_nonce[sender_index] = nonce
            .checked_add(1)
            .expect("nonce overflow is mathematically impossible at u128");

        // Compute the signing input (mirrors Lean's
        // `Authority.SignedAction.signingInput`).
        let input_bytes = signing_input(&action, sender, nonce, &config.deployment_id)?;

        // Sign keccak256(signing_input).
        let sig = actor_keys[sender_index].sign_keccak256(&input_bytes)?;

        // Emit the SignedAction CBE bytes.
        let wire = encode_signed_action(&action, sender, nonce, &sig)?;
        payloads.push(wire);
    }

    Ok(Fixture {
        actor_pubkeys,
        payloads: Arc::new(payloads),
        config: config.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::{
        actor_private_scalar, generate, scalar_in_range, Fixture, FixtureConfig, FixtureError,
        DEFAULT_PER_ACTOR_BALANCE, MAX_SCALAR_ATTEMPTS, MAX_SCALAR_ATTEMPT_INDEX,
        SECP256K1_ORDER_BE,
    };

    /// Default config has the documented per-actor balance.
    #[test]
    fn default_config_has_documented_balance() {
        let cfg = FixtureConfig::default();
        assert_eq!(cfg.per_actor_balance, DEFAULT_PER_ACTOR_BALANCE);
        assert_eq!(cfg.resource_id, 0);
        assert_eq!(cfg.transfer_amount, 1);
    }

    /// Default config's deployment-id is the documented 16-byte
    /// sentinel.  Two runs with default config thus produce
    /// identical bytes.
    #[test]
    fn default_config_deployment_id_stable() {
        let cfg1 = FixtureConfig::default();
        let cfg2 = FixtureConfig::default();
        assert_eq!(cfg1.deployment_id, cfg2.deployment_id);
        assert_eq!(cfg1.deployment_id, b"knomosis-bench-dpl0");
    }

    /// `validate` rejects zero counts.
    #[test]
    fn validate_rejects_zero_actor_count() {
        let mut cfg = FixtureConfig::default();
        cfg.actor_count = 0;
        assert!(matches!(cfg.validate(), Err(FixtureError::NoActors)));
    }

    /// `validate` rejects zero transfers.
    #[test]
    fn validate_rejects_zero_transfer_count() {
        let mut cfg = FixtureConfig::default();
        cfg.transfer_count = 0;
        assert!(matches!(cfg.validate(), Err(FixtureError::NoTransfers)));
    }

    /// REGRESSION: `validate` rejects `transfer_amount >= 2^64`
    /// upfront, before fixture generation pays the per-actor
    /// key-derivation cost.  CBE's canonical-encoding contract
    /// bounds Amount at `< 2^64`; passing a larger value used to
    /// fail late at first-transfer-encoding inside `generate`.
    #[test]
    fn validate_rejects_oversize_transfer_amount() {
        let mut cfg = FixtureConfig::default();
        cfg.transfer_amount = 1u128 << 64;
        assert!(matches!(
            cfg.validate(),
            Err(FixtureError::TransferAmountTooLarge(_))
        ));
        cfg.transfer_amount = u128::MAX;
        assert!(matches!(
            cfg.validate(),
            Err(FixtureError::TransferAmountTooLarge(_))
        ));
    }

    /// `validate` accepts `transfer_amount = 2^64 - 1` (the
    /// largest legal value).
    #[test]
    fn validate_accepts_max_transfer_amount() {
        let mut cfg = FixtureConfig::default();
        cfg.transfer_amount = (1u128 << 64) - 1;
        assert!(cfg.validate().is_ok());
    }

    /// `scalar_in_range` accepts a known-good scalar (the
    /// big-endian `1`).
    #[test]
    fn scalar_in_range_accepts_one() {
        let mut s = [0u8; 32];
        s[31] = 1;
        assert!(scalar_in_range(&s));
    }

    /// `scalar_in_range` rejects the zero scalar.
    #[test]
    fn scalar_in_range_rejects_zero() {
        assert!(!scalar_in_range(&[0u8; 32]));
    }

    /// `scalar_in_range` rejects exactly `n` (the curve order).
    #[test]
    fn scalar_in_range_rejects_n_exactly() {
        assert!(!scalar_in_range(&SECP256K1_ORDER_BE));
    }

    /// `scalar_in_range` rejects `n + 1` (just above the order).
    /// We construct this by incrementing the LSB of n.
    #[test]
    fn scalar_in_range_rejects_just_above_n() {
        let mut s = SECP256K1_ORDER_BE;
        s[31] = s[31].wrapping_add(1);
        // Note: this wraps to 0x42, which is _less_ than the original
        // last byte (0x41).  But all higher bytes match exactly until
        // index 31, so the comparison is on the last byte: 0x42 > 0x41
        // means "out of range".
        assert!(!scalar_in_range(&s));
    }

    /// `scalar_in_range` accepts `n - 1`.
    #[test]
    fn scalar_in_range_accepts_just_below_n() {
        let mut s = SECP256K1_ORDER_BE;
        s[31] = s[31].wrapping_sub(1);
        assert!(scalar_in_range(&s));
    }

    /// `actor_private_scalar` is deterministic for the same input.
    #[test]
    fn actor_scalar_deterministic() {
        let s1 = actor_private_scalar(42, 7).unwrap();
        let s2 = actor_private_scalar(42, 7).unwrap();
        assert_eq!(s1, s2);
    }

    /// `actor_private_scalar` produces distinct scalars for distinct
    /// indices (with overwhelming probability).
    #[test]
    fn actor_scalar_distinct_indices() {
        let s1 = actor_private_scalar(42, 0).unwrap();
        let s2 = actor_private_scalar(42, 1).unwrap();
        assert_ne!(s1, s2);
    }

    /// `actor_private_scalar` produces distinct scalars for distinct
    /// seeds.
    #[test]
    fn actor_scalar_distinct_seeds() {
        let s1 = actor_private_scalar(42, 0).unwrap();
        let s2 = actor_private_scalar(43, 0).unwrap();
        assert_ne!(s1, s2);
    }

    /// `actor_private_scalar` always returns a scalar in range.
    #[test]
    fn actor_scalar_always_in_range() {
        for actor_index in 0..32 {
            let s = actor_private_scalar(0xDEAD_BEEF, actor_index).unwrap();
            assert!(scalar_in_range(&s), "actor {actor_index} out of range");
        }
    }

    /// Small-scale fixture generation succeeds.
    #[test]
    fn generate_small_fixture() {
        let mut cfg = FixtureConfig::default();
        cfg.actor_count = 4;
        cfg.transfer_count = 8;
        let fixture = generate(&cfg).unwrap();
        assert_eq!(fixture.actor_pubkeys.len(), 4);
        assert_eq!(fixture.payloads.len(), 8);
        // Each pubkey is 33 bytes (SEC1-compressed).
        for pk in &fixture.actor_pubkeys {
            assert!(pk[0] == 0x02 || pk[0] == 0x03);
        }
    }

    /// Fixture generation is deterministic for the same config.
    #[test]
    fn generate_deterministic() {
        let mut cfg = FixtureConfig::default();
        cfg.actor_count = 3;
        cfg.transfer_count = 5;
        let f1 = generate(&cfg).unwrap();
        let f2 = generate(&cfg).unwrap();
        assert_eq!(f1.actor_pubkeys, f2.actor_pubkeys);
        assert_eq!(*f1.payloads, *f2.payloads);
    }

    /// Different seeds produce different payloads.
    #[test]
    fn generate_seed_changes_payloads() {
        let mut cfg1 = FixtureConfig::default();
        cfg1.actor_count = 3;
        cfg1.transfer_count = 5;
        let mut cfg2 = cfg1.clone();
        cfg2.seed = cfg1.seed.wrapping_add(1);
        let f1 = generate(&cfg1).unwrap();
        let f2 = generate(&cfg2).unwrap();
        // Pubkeys differ.
        assert_ne!(f1.actor_pubkeys, f2.actor_pubkeys);
        // Payloads differ (signature bytes differ).
        assert_ne!(*f1.payloads, *f2.payloads);
    }

    /// Each transfer's payload starts with the transfer constructor
    /// tag (CBE-uint head: 0x00 0x00 0x00 ...).
    #[test]
    fn payloads_start_with_transfer_tag() {
        let mut cfg = FixtureConfig::default();
        cfg.actor_count = 2;
        cfg.transfer_count = 2;
        let fixture = generate(&cfg).unwrap();
        // CBE uint head for `0` (Transfer's tag): 0x00 + 0x00 × 8.
        for payload in fixture.payloads.iter() {
            assert!(payload.len() >= 9);
            assert_eq!(payload[0], 0x00); // CBE_TAG_UINT
            assert_eq!(&payload[1..9], &[0u8; 8]); // Transfer tag = 0 in LE
        }
    }

    /// Per-actor nonces strictly increase per sender.
    #[test]
    fn per_actor_nonces_strictly_increase() {
        let mut cfg = FixtureConfig::default();
        cfg.actor_count = 3;
        cfg.transfer_count = 9; // 3 per actor
        let fixture = generate(&cfg).unwrap();
        // Decode each payload's (sender, nonce) and verify each
        // sender's nonces are 0, 1, 2 in arrival order.
        let mut seen_per_actor: Vec<Vec<u128>> = vec![Vec::new(); cfg.actor_count];
        for payload in fixture.payloads.iter() {
            // We use a known layout from knomosis-l1-ingest's encoder
            // to extract the sender + nonce: this is brittle to
            // encoder changes, but the test enforces a contract
            // we want to know about if it drifts.  See encoding.rs
            // for the structure.  Transfer = tag(9) + r(9) +
            // sender(9) + receiver(9) + amount(9) + signer(9) +
            // nonce(9) + sig_head(9) + sig(64).
            assert!(payload.len() >= 9 * 7 + 9 + 64);
            // sender field offset = 9 (after tag) + 9 (r) = 18; then
            // we want bytes [19..27] for the LE u64 sender.
            let sender_le = &payload[19..27];
            let sender_u64 = u64::from_le_bytes(sender_le.try_into().unwrap());
            // signer offset = 9 (tag) + 9 (r) + 9 (sender) + 9 (receiver)
            //               + 9 (amount) + 1 (signer tag) = 46 ... wait
            // Actually: encode_signed_action layout is:
            //   action_bytes ‖ encode_u64(signer) ‖ encode_amount(nonce)
            //                ‖ encode_byte_string(sig)
            // Transfer's action_bytes is: tag + r + sender + receiver +
            // amount = 5 × 9 = 45 bytes.  Then:
            //   signer at offset 45..54 (CBE uint, 9 bytes)
            //   nonce at offset 54..63 (CBE uint, 9 bytes)
            //   sig head at offset 63..72 (CBE bytes head, 9 bytes)
            //   sig at offset 72..136 (64 raw bytes)
            // Total = 136 bytes.
            assert_eq!(payload.len(), 136);
            // signer u64 (bytes 46..54, little-endian)
            let signer_le = &payload[46..54];
            let signer_u64 = u64::from_le_bytes(signer_le.try_into().unwrap());
            assert_eq!(sender_u64, signer_u64);
            // nonce u64 (bytes 55..63)
            let nonce_le = &payload[55..63];
            let nonce_u64 = u64::from_le_bytes(nonce_le.try_into().unwrap());
            seen_per_actor[sender_u64 as usize].push(u128::from(nonce_u64));
        }
        for (i, ns) in seen_per_actor.iter().enumerate() {
            assert_eq!(ns, &[0u128, 1u128, 2u128], "actor {i} nonce sequence");
        }
    }

    /// `Fixture::is_empty` / `len` / `average_payload_bytes` /
    /// `max_payload_bytes` work as documented.
    #[test]
    fn fixture_size_accessors() {
        let mut cfg = FixtureConfig::default();
        cfg.actor_count = 2;
        cfg.transfer_count = 4;
        let fixture = generate(&cfg).unwrap();
        assert!(!fixture.is_empty());
        assert_eq!(fixture.len(), 4);
        // Every Transfer payload is 136 bytes (proved in
        // `per_actor_nonces_strictly_increase`).
        assert!((fixture.average_payload_bytes() - 136.0).abs() < 0.001);
        assert_eq!(fixture.max_payload_bytes(), 136);
    }

    /// `MAX_SCALAR_ATTEMPT_INDEX` and `MAX_SCALAR_ATTEMPTS` are
    /// documented; pin the values to catch accidental drift.  The
    /// index is the highest `attempt` value the loop reaches; the
    /// count is the total number of hashes computed in the
    /// worst case (= index + 1).  A pinned value below 1 would be
    /// a bug (no rejection-sampling at all); above ~255 is
    /// meaningless (single-iteration rejection probability is
    /// already `< 2^-128`).
    #[test]
    fn max_scalar_attempts_documented() {
        assert_eq!(MAX_SCALAR_ATTEMPT_INDEX, 255);
        assert_eq!(MAX_SCALAR_ATTEMPTS, 256);
        assert_eq!(MAX_SCALAR_ATTEMPTS, u16::from(MAX_SCALAR_ATTEMPT_INDEX) + 1);
    }

    /// Empty `Fixture` accessors degrade gracefully.  We construct
    /// one by directly invoking the struct (not via `generate`
    /// which rejects zero counts).
    #[test]
    fn empty_fixture_accessors() {
        let f = Fixture {
            actor_pubkeys: Vec::new(),
            payloads: std::sync::Arc::new(Vec::new()),
            config: FixtureConfig::default(),
        };
        assert!(f.is_empty());
        assert_eq!(f.len(), 0);
        assert!((f.average_payload_bytes() - 0.0).abs() < f64::EPSILON);
        assert_eq!(f.max_payload_bytes(), 0);
    }
}
