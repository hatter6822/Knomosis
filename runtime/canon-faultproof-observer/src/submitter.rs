// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! L1 transaction submission for fault-proof game moves.
//!
//! ## Submission flow
//!
//! 1. The observer's orchestrator computes an [`HonestMove`].
//! 2. The submitter's [`encode_calldata`] converts the move +
//!    game id into the L1 transaction calldata (Solidity ABI
//!    encoded).
//! 3. The submitter wraps that calldata into a signed EIP-1559
//!    transaction (or legacy, depending on the L1 RPC's
//!    capability) and broadcasts via `eth_sendRawTransaction`.
//! 4. The submitter records the tx-hash in
//!    [`crate::persistence`] as `ResponseStatus::Pending`.
//! 5. On subsequent watcher iterations, the submitter checks the
//!    tx receipt; on inclusion + N confirmations, updates the
//!    record to `Confirmed`.
//!
//! ## What this RH-G landing ships
//!
//! The submitter ships with two implementations:
//!
//!   * [`mock::MockSubmitter`] — in-memory; the test harness uses
//!     this to drive the observer without an actual L1 RPC.
//!     Records every submission for inspection.
//!   * [`encode_calldata`] — pure-Rust ABI encoder for
//!     the four L1 contract methods (`submitMidpoint`,
//!     `respondToMidpoint`, `terminateOnSingleStep`,
//!     `claimTimeout`).  Production deployments use this
//!     calldata as the `data` field of their transaction.
//!
//! The full production `JsonRpcSubmitter` that signs
//! and broadcasts is sketched as a public trait API but its
//! actual `eth_sendRawTransaction` driver requires EIP-1559
//! transaction-encoding work that mirrors RH-B's
//! `JsonRpcL1Source`.  The mock + calldata encoder cover the
//! observer's *correctness* (the calldata bytes are what get
//! tested cross-stack); the production driver is RH-G follow-up
//! work that doesn't change the calldata contract.
//!
//! ## Key zeroization
//!
//! The signing key is wrapped in
//! [`canon_l1_ingest::key::BridgeActorKey`] which holds the raw
//! private bytes in `Zeroizing<[u8; 32]>`.  Drop scrubs the
//! memory.  This is the same key wrapper used by RH-B (L1
//! ingestor); we re-use it directly to keep the audit surface
//! narrow.

use sha3::{Digest, Keccak256};

use crate::game::StateCommit;
use crate::strategy::HonestMove;

/// The four method selectors the observer calls on the L1 game
/// contract.  Selector = first 4 bytes of `keccak256(signature)`.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum MethodSelector {
    /// `submitMidpoint(uint256 gameId, bytes32 midpointCommit)`.
    SubmitMidpoint,
    /// `respondToMidpoint(uint256 gameId, bool agree)`.
    RespondToMidpoint,
    /// MINIMUM-FORM `terminateOnSingleStep(uint256 gameId, bytes32 claimedPostCommit)`.
    /// **This selector does NOT match the deployed contract's
    /// full signature.**  Use [`Self::TerminateOnSingleStepFull`]
    /// for production calldata.  Kept for integration smoke tests
    /// that exercise the minimum encoding path.
    TerminateOnSingleStep,
    /// **FULL-FORM** `terminateOnSingleStep(uint256, uint8, bytes, uint64, (uint8,uint256,uint256,bytes,bytes32)[], bytes32)`.
    /// This is the production contract's actual signature — the
    /// fields are `(gameId, actionKind, actionFields, signer,
    /// cellProofs, claimedPostCommit)`.  Use this selector for
    /// any calldata the observer broadcasts to L1.
    TerminateOnSingleStepFull,
    /// `claimTimeout(uint256 gameId)`.
    ClaimTimeout,
}

impl MethodSelector {
    /// The canonical Solidity method signature.  We deliberately
    /// emit the **minimum** signature for `terminateOnSingleStep`
    /// because the full version requires per-action calldata
    /// + cell proofs that come from a separate (Lean subprocess)
    ///   pipeline.  The selector returned here is for the form
    ///   `terminateOnSingleStep(uint256, bytes32)` — useful for
    ///   integration smoke tests but NOT what the production
    ///   contract dispatches on.
    #[must_use]
    pub const fn signature(self) -> &'static str {
        match self {
            Self::SubmitMidpoint => "submitMidpoint(uint256,bytes32)",
            Self::RespondToMidpoint => "respondToMidpoint(uint256,bool)",
            Self::TerminateOnSingleStep => "terminateOnSingleStep(uint256,bytes32)",
            // Full-form Solidity signature (per
            // `solidity/src/contracts/CanonFaultProofGame.sol:383`):
            // `terminateOnSingleStep(uint256 gameId, uint8 actionKind,
            //                        bytes actionFields, uint64 signer,
            //                        CellProof[] cellProofs,
            //                        bytes32 claimedPostCommit)`
            // The `CellProof` struct's canonical ABI tuple is
            // `(uint8, uint256, uint256, bytes, bytes32)` — see
            // `CanonStepVM::CellProof`.
            Self::TerminateOnSingleStepFull => {
                "terminateOnSingleStep(uint256,uint8,bytes,uint64,(uint8,uint256,uint256,bytes,bytes32)[],bytes32)"
            }
            Self::ClaimTimeout => "claimTimeout(uint256)",
        }
    }

    /// The 4-byte method selector (first 4 bytes of
    /// `keccak256(signature)`).
    #[must_use]
    pub fn selector(self) -> [u8; 4] {
        let mut hasher = Keccak256::new();
        hasher.update(self.signature().as_bytes());
        let digest = hasher.finalize();
        let mut out = [0u8; 4];
        out.copy_from_slice(&digest[0..4]);
        out
    }
}

/// Errors specific to the submitter.
#[derive(Debug, thiserror::Error)]
pub enum SubmitError {
    /// The honest move is `NoMove`; cannot encode calldata for a
    /// no-op.
    #[error("cannot encode calldata for HonestMove::NoMove")]
    NoMove,

    /// The honest move is `TerminateOnSingleStep` but the
    /// production submitter's calldata builder is incomplete:
    /// the L1 `CanonFaultProofGame.terminateOnSingleStep(uint256,
    /// uint8, bytes, uint64, CellProof[], bytes32)` takes the
    /// full action variant + cell-proof bundle, which requires
    /// L1 step-VM cross-stack coherence across all 19 `Action`
    /// variants — currently proven only for Transfer + Mint via
    /// the `step_vm.json` cross-stack fixture.  See
    /// `docs/planning/step_vm_coherence_plan.md` (workstream
    /// SVC) for the engineering plan that closes this gap.  Until
    /// SVC lands, `encode_calldata` for `TerminateOnSingleStep`
    /// refuses to silently produce a calldata that would revert
    /// on-chain at the L1 contract's selector-dispatch layer.
    /// The minimum-form `encode_terminate_calldata` helper is
    /// available for integration smoke tests.
    #[error(
        "TerminateOnSingleStep calldata requires the full \
         (actionKind, actionFields, signer, cellProofs) form \
         which is gated on the SVC cross-stack-coherence \
         workstream (see docs/planning/step_vm_coherence_plan.md); \
         the off-chain observer cannot synthesise it from local \
         state alone"
    )]
    TerminateNotImplemented,

    /// Submission was rejected by the L1 RPC (e.g., invalid
    /// nonce, out-of-gas estimate).
    #[error("L1 RPC rejected submission: {0}")]
    RpcRejected(String),

    /// The submitter is in mock mode and was asked to perform a
    /// network call beyond what the mock can synthesise (e.g.,
    /// a fork-aware re-broadcast).
    #[error("mock submitter received unexpected network call")]
    MockUnsupported,

    /// The off-chain terminate-bundle oracle's `claimed_post_commit`
    /// disagrees with the strategy's `claimed_post_commit`.  This
    /// indicates the truth oracle and the bundle oracle have
    /// drifted (e.g., operator pointed at two different canon
    /// binaries / log files).  Workstream SVC.5 defence-in-depth:
    /// refuse to broadcast a calldata that would lose the game.
    #[error(
        "terminate-bundle oracle's claimed_post_commit disagrees with strategy's; \
         truth oracle and bundle oracle have drifted"
    )]
    BundleCommitMismatch,
}

/// ABI-encode an Ethereum transaction calldata for the given
/// game id + honest move.  Returns the calldata bytes ready to
/// be wrapped in a transaction's `data` field.
///
/// Encoding rules:
///
///   * Method selector (4 bytes) is the first 4 bytes of
///     `keccak256(method-signature)`.
///   * `uint256` arguments are encoded as 32-byte big-endian
///     left-padded.
///   * `bytes32` arguments are encoded as raw 32 bytes.
///   * `bool` arguments are encoded as 32-byte left-padded
///     {0, 1}.
///
/// # Errors
///
/// See [`SubmitError`].
pub fn encode_calldata(game_id: u128, mv: HonestMove) -> Result<Vec<u8>, SubmitError> {
    match mv {
        HonestMove::NoMove => Err(SubmitError::NoMove),
        HonestMove::Submit(claim) => Ok(encode_submit_calldata(game_id, claim.commit)),
        HonestMove::RespondAgree => Ok(encode_respond_calldata(game_id, true)),
        HonestMove::RespondDisagree => Ok(encode_respond_calldata(game_id, false)),
        // The minimum-form `encode_terminate_calldata` produces
        // a selector that does NOT match the deployed contract's
        // `terminateOnSingleStep(uint256, uint8, bytes, uint64,
        // CellProof[], bytes32)` signature; broadcasting that
        // calldata would revert on-chain at the selector-dispatch
        // layer.  Refuse to silently produce the wrong-selector
        // calldata.  Callers wanting to submit terminate calldata
        // must use [`encode_calldata_with_bundle`] which takes the
        // full bundle and dispatches to
        // [`encode_terminate_full_calldata`].
        HonestMove::TerminateOnSingleStep { .. } => Err(SubmitError::TerminateNotImplemented),
    }
}

/// ABI-encode an Ethereum transaction calldata for the given
/// game id + honest move + (optional) terminate bundle.  Mirrors
/// [`encode_calldata`] but accepts a [`TerminateBundle`] for the
/// `TerminateOnSingleStep` arm; uses
/// [`encode_terminate_full_calldata`] to produce production-shape
/// calldata that the L1 `CanonFaultProofGame.terminateOnSingleStep`
/// dispatcher accepts.
///
/// This is the entry point Workstream SVC.5 routes the
/// off-chain observer through.  Callers that don't have a bundle
/// pass `None` and accept the `TerminateNotImplemented` error
/// for terminate moves (e.g., during cold-start before the
/// canon subprocess responds).
///
/// # Errors
///
/// See [`SubmitError`].  Returns
/// [`SubmitError::TerminateNotImplemented`] iff the move is
/// `TerminateOnSingleStep` AND `bundle` is `None`.
#[allow(clippy::needless_pass_by_value)]
pub fn encode_calldata_with_bundle(
    game_id: u128,
    mv: HonestMove,
    bundle: Option<&crate::strategy::TerminateBundle>,
) -> Result<Vec<u8>, SubmitError> {
    match (mv, bundle) {
        (
            HonestMove::TerminateOnSingleStep {
                claimed_post_commit,
            },
            Some(b),
        ) => {
            // Defence-in-depth: cross-check the claimed commit
            // against the bundle's own claim.  If they disagree,
            // the off-chain truth oracle and the off-chain
            // terminate-bundle oracle have drifted (e.g.,
            // operator pointed at two different `canon` binaries
            // or two different log files).  Refuse to broadcast
            // a calldata that would lose the game.
            if b.claimed_post_commit != claimed_post_commit {
                return Err(SubmitError::BundleCommitMismatch);
            }
            Ok(encode_terminate_full_calldata(
                game_id,
                b.action_kind,
                &b.action_fields,
                b.signer,
                &b.cell_proofs,
                claimed_post_commit,
            ))
        }
        (mv, _) => encode_calldata(game_id, mv),
    }
}

/// Encode a `submitMidpoint(uint256 gameId, bytes32 midpointCommit)`
/// call.  The L1 contract uses this commit + a side-computed
/// midpoint index to record the new pending midpoint.
#[must_use]
pub fn encode_submit_calldata(game_id: u128, commit: StateCommit) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + 32 + 32);
    out.extend_from_slice(&MethodSelector::SubmitMidpoint.selector());
    out.extend_from_slice(&u256_be(game_id));
    out.extend_from_slice(&commit);
    out
}

/// Encode a `respondToMidpoint(uint256 gameId, bool agree)` call.
#[must_use]
pub fn encode_respond_calldata(game_id: u128, agree: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + 32 + 32);
    out.extend_from_slice(&MethodSelector::RespondToMidpoint.selector());
    out.extend_from_slice(&u256_be(game_id));
    out.extend_from_slice(&bool_word(agree));
    out
}

/// Encode the minimum form of `terminateOnSingleStep(uint256 gameId,
/// bytes32 claimedPostCommit)`.  Does NOT match the deployed
/// contract's signature; use [`encode_terminate_full_calldata`]
/// for production calldata.
#[must_use]
pub fn encode_terminate_calldata(game_id: u128, claimed_post_commit: StateCommit) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + 32 + 32);
    out.extend_from_slice(&MethodSelector::TerminateOnSingleStep.selector());
    out.extend_from_slice(&u256_be(game_id));
    out.extend_from_slice(&claimed_post_commit);
    out
}

/// One cell-proof for the L1 step VM's verification.  Mirrors
/// the Solidity `CanonStepVM::CellProof` struct.  See
/// `solidity/src/contracts/CanonStepVM.sol` for the canonical
/// definition.
///
/// The cell-proof bundle is produced by the Lean side's
/// `buildCellProof` (`LegalKernel.FaultProof.Cell`) and supplied
/// to the observer via an out-of-band channel (e.g., a `canon`
/// subprocess).  The observer's role is to ABI-encode the
/// bundle into calldata; it does NOT itself construct the
/// proofs.
#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct CellProof {
    /// The cell kind (uint8 in Solidity; values defined by the
    /// `CanonStepVM` `CellKind` enum, e.g. 0=Balance, 1=Nonce,
    /// 2=Registry, etc.).
    pub cell_kind: u8,
    /// The first key (resource id / actor id depending on
    /// `cell_kind`).  Encoded as uint256.
    ///
    /// JSON wire format: Lean emits this as a 16-hex-char
    /// big-endian string (left-zero-padded) per
    /// `LegalKernel.Runtime.CellProofJson`.  The custom
    /// deserializer parses both the hex-string form (Lean
    /// pipeline) and the native JSON-number form (round-trip
    /// from `Serialize`).
    #[serde(
        serialize_with = "serialize_u128_hex_lowpadded",
        deserialize_with = "deserialize_u128_hex_or_number"
    )]
    pub key_a: u128,
    /// The second key (actor id for Balance; usually 0 for
    /// other kinds).  Same encoding as `key_a`.
    #[serde(
        serialize_with = "serialize_u128_hex_lowpadded",
        deserialize_with = "deserialize_u128_hex_or_number"
    )]
    pub key_b: u128,
    /// The CBE-encoded cell value as opaque bytes (variable
    /// length).
    ///
    /// JSON wire format: Lean emits as a lowercase hex string
    /// (no `0x` prefix); the custom deserializer accepts both
    /// the hex-string form and the native JSON byte-array form
    /// (round-trip from `Serialize`).
    #[serde(
        serialize_with = "serialize_bytes_hex",
        deserialize_with = "deserialize_bytes_hex_or_array"
    )]
    pub cell_value: Vec<u8>,
    /// The pre-step state commit at which this cell value is
    /// witness-valid.  Must equal the
    /// `terminateOnSingleStep`'s implicit pre-state commit
    /// (the high-commit of the disputed range at the
    /// settle-time).
    ///
    /// JSON wire format: Lean emits as a 64-hex-char string
    /// (lowercase, no `0x` prefix).
    #[serde(
        serialize_with = "serialize_bytes32_hex",
        deserialize_with = "deserialize_bytes32_hex_or_array"
    )]
    pub witness_commit: [u8; 32],
}

/// Encode a `u128` as a 16-character lowercase big-endian hex
/// string (matches Lean's `formatCellTag::toHexU64`).
///
/// **Round-trip constraint.**  The Lean wire format pins
/// `key_a` / `key_b` at exactly 16 hex chars (low 64 bits).
/// If a caller constructs a `CellProof` in Rust with
/// `key_a > u64::MAX`, the high bits would be silently
/// truncated by this serializer, breaking round-trip.  We
/// `debug_assert!` against this in debug builds so the issue
/// surfaces in tests; in release builds the truncation is
/// silent (matching the existing Lean-side `% (1 << 64)`
/// projection convention).
fn serialize_u128_hex_lowpadded<S>(value: &u128, ser: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    debug_assert!(
        *value <= u128::from(u64::MAX),
        "serialize_u128_hex_lowpadded: value {value:#x} exceeds u64::MAX; \
         the 16-hex-char wire format cannot represent it.  If this is a \
         real production case (DepositId / WithdrawalId > 2^64), the wire \
         format itself needs widening on BOTH the Lean side and the Rust \
         side in coordinated PRs."
    );
    // Use only the low 64 bits for compatibility with the Lean
    // emitter (which projects DepositId / WithdrawalId through
    // `% (1 << 64)`).
    #[allow(clippy::cast_possible_truncation)]
    let low64 = *value as u64;
    ser.serialize_str(&format!("{low64:016x}"))
}

/// Deserialize `u128` from either a hex string (Lean's wire form)
/// OR a JSON number (e.g., direct construction in Rust tests).
fn deserialize_u128_hex_or_number<'de, D>(de: D) -> Result<u128, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::{de::Error, Deserialize};
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum HexOrNumber {
        Str(String),
        Num(u128),
    }
    match HexOrNumber::deserialize(de)? {
        HexOrNumber::Str(s) => {
            let trimmed = s.strip_prefix("0x").unwrap_or(&s);
            u128::from_str_radix(trimmed, 16)
                .map_err(|e| D::Error::custom(format!("invalid hex u128 {trimmed:?}: {e}")))
        }
        HexOrNumber::Num(n) => Ok(n),
    }
}

/// Encode a `Vec<u8>` as a lowercase hex string (no `0x` prefix).
fn serialize_bytes_hex<S>(value: &Vec<u8>, ser: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    ser.serialize_str(&hex::encode(value))
}

/// Upper bound on the decoded length of a `CellProof::cell_value`
/// field.  Audit-pass-4-round-4 MEDIUM defence: a malicious JSON
/// source could send a multi-MB hex string and force a large
/// allocation.  Real cell values are bounded by the kernel's CBE
/// encoding limits: tens of bytes for `balance`/`nonce`/`registry`
/// (single Nat or 33-byte pubkey), low-hundreds for bridge records,
/// up to a few KB for the largest `localPolicy`.  Audit-pass-4-
/// round-5 tightening: cap at 64 KiB (well over the realistic max
/// of ~4 KiB) to fail fast on pathological inputs without
/// constraining legitimate use.
pub const MAX_CELL_VALUE_BYTES: usize = 64 * 1024;

/// Deserialize `Vec<u8>` from either a hex string (Lean's wire
/// form) OR a JSON array of bytes (direct Rust round-trip).
/// Caps at `MAX_CELL_VALUE_BYTES` to defend against allocation
/// `DoS`.
fn deserialize_bytes_hex_or_array<'de, D>(de: D) -> Result<Vec<u8>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::{de::Error, Deserialize};
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum HexOrBytes {
        Str(String),
        Bytes(Vec<u8>),
    }
    let bytes = match HexOrBytes::deserialize(de)? {
        HexOrBytes::Str(s) => {
            let trimmed = s.strip_prefix("0x").unwrap_or(&s);
            // Pre-check: cap the hex string length BEFORE
            // hex::decode allocates.
            if trimmed.len() > MAX_CELL_VALUE_BYTES * 2 {
                return Err(D::Error::custom(format!(
                    "cell_value hex exceeds cap: {} chars > {} max",
                    trimmed.len(),
                    MAX_CELL_VALUE_BYTES * 2,
                )));
            }
            hex::decode(trimmed).map_err(|e| D::Error::custom(format!("invalid hex bytes: {e}")))?
        }
        HexOrBytes::Bytes(b) => b,
    };
    if bytes.len() > MAX_CELL_VALUE_BYTES {
        return Err(D::Error::custom(format!(
            "cell_value exceeds cap: {} bytes > {} max",
            bytes.len(),
            MAX_CELL_VALUE_BYTES,
        )));
    }
    Ok(bytes)
}

/// Encode a `[u8; 32]` as a 64-character lowercase hex string.
fn serialize_bytes32_hex<S>(value: &[u8; 32], ser: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    ser.serialize_str(&hex::encode(value))
}

/// Deserialize `[u8; 32]` from either a hex string (Lean's wire
/// form) OR a 32-element JSON byte array.
fn deserialize_bytes32_hex_or_array<'de, D>(de: D) -> Result<[u8; 32], D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::{de::Error, Deserialize};
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum HexOrBytes {
        Str(String),
        Bytes(Vec<u8>),
    }
    let bytes = match HexOrBytes::deserialize(de)? {
        HexOrBytes::Str(s) => {
            let trimmed = s.strip_prefix("0x").unwrap_or(&s);
            hex::decode(trimmed)
                .map_err(|e| D::Error::custom(format!("invalid hex bytes32 {trimmed:?}: {e}")))?
        }
        HexOrBytes::Bytes(b) => b,
    };
    if bytes.len() != 32 {
        return Err(D::Error::custom(format!(
            "expected 32 bytes, got {}",
            bytes.len()
        )));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

/// `ActionKind` values supported by `CanonStepVM` (mirror of
/// the Lean `Authority.Action` constructor tags).  See
/// `LegalKernel/Encoding/Action.lean` and `CanonStepVM.sol`
/// for the canonical table.  This enum just gives names to
/// the byte values; encoding is via `as u8`.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
#[repr(u8)]
pub enum ActionKind {
    /// `Transfer(r, sender, receiver, amount)`.
    Transfer = 0,
    /// `Mint(r, to, amount)`.
    Mint = 1,
    /// `Burn(r, from_actor, amount)`.
    Burn = 2,
    /// `FreezeResource(r)`.
    FreezeResource = 3,
    /// `ReplaceKey(actor, new_key)`.
    ReplaceKey = 4,
    /// `Reward(r, to, amount)`.
    Reward = 5,
    /// `DistributeOthers(r, excluded, amount)`.
    DistributeOthers = 6,
    /// `ProportionalDilute(r, excluded, total_reward)`.
    ProportionalDilute = 7,
    /// `Dispute(...)`.
    Dispute = 8,
    /// `DisputeWithdraw(idx)`.
    DisputeWithdraw = 9,
    /// `Verdict(...)`.
    Verdict = 10,
    /// `Rollback(target_idx)`.
    Rollback = 11,
    /// `RegisterIdentity(actor, pk)`.
    RegisterIdentity = 12,
    /// `Deposit(r, recipient, amount, deposit_id)`.
    Deposit = 13,
    /// `Withdraw(r, sender, amount, recipient_l1)`.
    Withdraw = 14,
    /// `DeclareLocalPolicy(...)`.
    DeclareLocalPolicy = 15,
    /// `RevokeLocalPolicy`.
    RevokeLocalPolicy = 16,
    /// `FaultProofChallenge(...)`.
    FaultProofChallenge = 17,
    /// `FaultProofResolution(...)`.
    FaultProofResolution = 18,
}

/// Encode the FULL-FORM `terminateOnSingleStep` calldata.  The
/// Solidity signature is:
///
/// ```text
/// terminateOnSingleStep(
///     uint256 gameId,
///     uint8 actionKind,
///     bytes actionFields,
///     uint64 signer,
///     CellProof[] cellProofs,
///     bytes32 claimedPostCommit
/// )
/// ```
///
/// The encoding follows Solidity's ABI rules:
/// * Method selector (4 bytes) = first 4 bytes of `keccak256(signature)`.
/// * Head section: each fixed-size param contributes its 32-byte
///   word in-place; each dynamic-size param contributes a 32-byte
///   offset (pointing into the tail).
/// * Tail section: dynamic data laid out in declaration order;
///   each `bytes` carries `(length:uint256, payload, padding to 32 bytes)`;
///   each `T[]` carries `(length:uint256, elements...)`.
/// * Struct `(t1, ..., tN)` is encoded as the head/tail of its
///   constituent tuple.
///
/// This implementation is hand-rolled to match the Solidity
/// encoder byte-for-byte.  Property tests verify the head/tail
/// alignment and the per-cell-proof tuple encoding.
///
/// # Panics
///
/// Does not panic on any input.  Numeric fields that don't fit
/// their ABI bounds (e.g., `signer > u64::MAX` is impossible
/// in Rust's type system since `signer: u64`) are not validated.
#[must_use]
pub fn encode_terminate_full_calldata(
    game_id: u128,
    action_kind: u8,
    action_fields: &[u8],
    signer: u64,
    cell_proofs: &[CellProof],
    claimed_post_commit: StateCommit,
) -> Vec<u8> {
    // Header layout (6 head words, 32 bytes each = 192 bytes):
    //   word 0: gameId            (uint256)
    //   word 1: actionKind        (uint8 in uint256 slot)
    //   word 2: actionFields offset (relative to start of args)
    //   word 3: signer            (uint64 in uint256 slot)
    //   word 4: cellProofs offset (relative to start of args)
    //   word 5: claimedPostCommit (bytes32)
    const HEAD_WORDS: usize = 6;
    const WORD: usize = 32;
    let head_bytes: usize = HEAD_WORDS * WORD;

    // First, encode the dynamic tails so we know their offsets
    // and lengths.
    //
    // Tail entry 1: actionFields as `bytes`.
    let action_fields_tail = encode_dynamic_bytes(action_fields);
    // Tail entry 2: cellProofs as `CellProof[]`.
    let cell_proofs_tail = encode_cell_proof_array(cell_proofs);

    // Offsets are computed relative to the start of the args
    // (right after the 4-byte selector).
    let action_fields_offset: u128 = head_bytes as u128;
    let cell_proofs_offset: u128 = (head_bytes + action_fields_tail.len()) as u128;

    let mut out =
        Vec::with_capacity(4 + head_bytes + action_fields_tail.len() + cell_proofs_tail.len());
    out.extend_from_slice(&MethodSelector::TerminateOnSingleStepFull.selector());
    // word 0: gameId
    out.extend_from_slice(&u256_be(game_id));
    // word 1: actionKind (uint8 → left-padded 32 bytes)
    out.extend_from_slice(&u256_be(u128::from(action_kind)));
    // word 2: actionFields offset
    out.extend_from_slice(&u256_be(action_fields_offset));
    // word 3: signer
    out.extend_from_slice(&u256_be(u128::from(signer)));
    // word 4: cellProofs offset
    out.extend_from_slice(&u256_be(cell_proofs_offset));
    // word 5: claimedPostCommit
    out.extend_from_slice(&claimed_post_commit);
    // Tails.
    out.extend_from_slice(&action_fields_tail);
    out.extend_from_slice(&cell_proofs_tail);
    out
}

/// Encode a `bytes` value: 32-byte length + payload + zero
/// padding to the next 32-byte boundary.
fn encode_dynamic_bytes(payload: &[u8]) -> Vec<u8> {
    let len = payload.len();
    let padded_len = (len + 31) & !31; // round up to multiple of 32
    let mut out = Vec::with_capacity(32 + padded_len);
    out.extend_from_slice(&u256_be(len as u128));
    out.extend_from_slice(payload);
    // Zero padding.
    out.extend(std::iter::repeat_n(0u8, padded_len - len));
    out
}

/// Encode a `CellProof[]` value: 32-byte length + each element
/// encoded as a tuple `(uint8, uint256, uint256, bytes, bytes32)`.
///
/// Since the tuple contains a dynamic `bytes` field, each tuple
/// is itself dynamic; the array encoding is:
///   * length: uint256
///   * for each element: offset:uint256 into the elements blob
///   * elements blob: concatenation of per-element encodings.
///
/// Wait — that's the encoding for `T[]` where `T` is a dynamic
/// type.  Each element of a dynamic-element array is encoded
/// as a (offset, data) pair within the array's encoded region.
///
/// Let me follow the strict Solidity ABI:
///   `T[]` where T is dynamic:
///     - length (32 bytes)
///     - N pointers (32 bytes each) into the per-element data
///     - per-element data laid out in declaration order
///
/// The pointers are RELATIVE TO THE START OF THE ELEMENTS
/// BLOB (i.e., after the length word).
fn encode_cell_proof_array(proofs: &[CellProof]) -> Vec<u8> {
    let n = proofs.len();
    // Pre-encode each element so we know per-element lengths.
    let per_element: Vec<Vec<u8>> = proofs.iter().map(encode_cell_proof_tuple).collect();
    // Compute pointers: each element's offset within the
    // pointers+data region.  Pointers come first (N×32 bytes),
    // then the elements concatenated.
    let mut pointers = Vec::with_capacity(n * 32);
    let mut data_offset: u128 = (n as u128) * 32;
    for elem in &per_element {
        pointers.extend_from_slice(&u256_be(data_offset));
        data_offset += elem.len() as u128;
    }
    let data: Vec<u8> = per_element.into_iter().flatten().collect();
    // Top-level: length + pointers + data.
    let mut out = Vec::with_capacity(32 + pointers.len() + data.len());
    out.extend_from_slice(&u256_be(n as u128));
    out.extend_from_slice(&pointers);
    out.extend_from_slice(&data);
    out
}

/// Encode a single `CellProof` tuple
/// `(uint8 cellKind, uint256 keyA, uint256 keyB, bytes cellValue, bytes32 witnessCommit)`.
///
/// The tuple contains a dynamic field (`bytes cellValue`), so
/// the encoding uses the head/tail discipline:
/// * Head (5 words = 160 bytes):
///     word 0: cellKind          (uint8 left-padded)
///     word 1: keyA              (uint256)
///     word 2: keyB              (uint256)
///     word 3: cellValue offset  (160 bytes, relative to tuple start)
///     word 4: witnessCommit     (bytes32)
/// * Tail: cellValue dynamic-bytes encoding.
fn encode_cell_proof_tuple(p: &CellProof) -> Vec<u8> {
    const HEAD_WORDS: usize = 5;
    const WORD: usize = 32;
    let head_bytes: usize = HEAD_WORDS * WORD;

    let cell_value_tail = encode_dynamic_bytes(&p.cell_value);
    let mut out = Vec::with_capacity(head_bytes + cell_value_tail.len());
    // word 0: cellKind
    out.extend_from_slice(&u256_be(u128::from(p.cell_kind)));
    // word 1: keyA
    out.extend_from_slice(&u256_be(p.key_a));
    // word 2: keyB
    out.extend_from_slice(&u256_be(p.key_b));
    // word 3: cellValue offset (head_bytes = 160 bytes from tuple start)
    out.extend_from_slice(&u256_be(head_bytes as u128));
    // word 4: witnessCommit
    out.extend_from_slice(&p.witness_commit);
    // Tail.
    out.extend_from_slice(&cell_value_tail);
    out
}

/// Encode a `claimTimeout(uint256 gameId)` call.
#[must_use]
pub fn encode_claim_timeout_calldata(game_id: u128) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + 32);
    out.extend_from_slice(&MethodSelector::ClaimTimeout.selector());
    out.extend_from_slice(&u256_be(game_id));
    out
}

/// Encode a `u128` as a 32-byte big-endian left-padded ABI word
/// (matching Solidity's `uint256` encoding).
fn u256_be(v: u128) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[16..32].copy_from_slice(&v.to_be_bytes());
    out
}

/// Encode a `bool` as a 32-byte left-padded ABI word.
fn bool_word(v: bool) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[31] = u8::from(v);
    out
}

/// A signed L1 transaction ready for broadcast.  The `tx_hash`
/// is the canonical Ethereum transaction hash (keccak256 of
/// the serialized signed bytes for legacy txs, or the EIP-2718
/// type-prefixed bytes for typed txs); it is knowable BEFORE
/// the L1 broadcast, which is the load-bearing property that
/// lets the observer persist a pre-submit intent record.
#[derive(Clone, Debug)]
pub struct PreparedTx {
    /// The 32-byte canonical Ethereum tx hash.
    pub tx_hash: [u8; 32],
    /// The serialized signed transaction bytes ready for
    /// `eth_sendRawTransaction`.
    pub raw_bytes: Vec<u8>,
}

/// Submitter trait — abstracts L1 transaction signing +
/// broadcasting.  Production deployments use the JSON-RPC impl;
/// tests use the mock.
///
/// ## Pre-submit intent discipline
///
/// The two-step `build_and_sign` + `broadcast` split lets the
/// observer:
///
///   1. Build + sign the tx — knows `tx_hash` before any L1
///      contact.
///   2. Persist a `ResponseRecord` with the known `tx_hash` and
///      `status = Pending` (intent recorded).
///   3. `commit_batch` — persistence is durable.
///   4. Broadcast — actually hit the L1 RPC.
///
/// On a crash between steps 3 and 4, the next process restart
/// sees the intent record and can re-broadcast (using the
/// stored `raw_bytes`).  This closes the H-1 audit-pass-3
/// gap where the previous single-step `submit` API could
/// silently lose the intent under a `commit_batch` failure
/// between submission and persistence.
pub trait Submitter {
    /// Build and sign a transaction carrying `calldata`.
    /// Returns a [`PreparedTx`] whose `tx_hash` is the
    /// canonical Ethereum tx hash and whose `raw_bytes` are
    /// ready for `eth_sendRawTransaction`.
    ///
    /// **No network I/O.**  The mock implementation is purely
    /// computational; the production implementation may need
    /// `eth_estimateGas` / `eth_feeHistory` to set gas limits
    /// and fee tiers — those are network calls but the actual
    /// transaction is NOT broadcast at this stage.
    ///
    /// # Errors
    ///
    /// See [`SubmitError`].
    fn build_and_sign(&self, calldata: &[u8]) -> Result<PreparedTx, SubmitError>;

    /// Broadcast a previously-prepared transaction via
    /// `eth_sendRawTransaction`.  Idempotent at the
    /// `tx_hash` level: re-broadcasting the same prepared tx
    /// after a crash recovery is safe (the L1 RPC will return
    /// "already known" rather than error).
    ///
    /// # Errors
    ///
    /// See [`SubmitError`].
    fn broadcast(&self, prepared: &PreparedTx) -> Result<(), SubmitError>;

    /// Check whether a previously-broadcast tx has been
    /// included on L1.  Returns `Some(true)` if confirmed,
    /// `Some(false)` if pending, `None` if dropped (the tx was
    /// re-orged out or never mined).
    ///
    /// # Errors
    ///
    /// See [`SubmitError`].
    fn check_inclusion(&self, tx_hash: &[u8; 32]) -> Result<Option<bool>, SubmitError>;

    /// Signal to the submitter that a previous `broadcast` call
    /// failed.  The submitter MAY use this to invalidate any
    /// in-memory state (e.g., a nonce cache) so that the next
    /// `build_and_sign` re-discovers the canonical state from
    /// the RPC.
    ///
    /// **Why this exists.**  The audit-pass-4 peek/commit nonce
    /// discipline ensures the cache is only bumped after a
    /// SIGN-time success.  But a BROADCAST-time failure (e.g.,
    /// RPC connection refused, "underpriced", etc.) still leaves
    /// the cache pointing at `N+1` while nonce `N` was never
    /// consumed on L1.  Without re-syncing, the next sign would
    /// pick `N+1` and L1 would reject it with "nonce too high".
    /// This trait method is the cross-cutting hook that lets the
    /// observer's `broadcast_and_update_status` recover.
    ///
    /// The default implementation is a no-op (sufficient for the
    /// `MockSubmitter`, which has no live nonce state).
    /// Production submitters (`JsonRpcSubmitter`) override it.
    fn invalidate_nonce_cache(&self) {
        // Default: no-op.
    }
}

/// In-memory mock submitter.  Records every submission for
/// inspection; reports tx-hashes derived from
/// `keccak256(calldata)` so tests get deterministic ids.
pub mod mock {
    use std::sync::Mutex;

    use sha3::{Digest, Keccak256};

    use super::{PreparedTx, SubmitError, Submitter};

    /// A recorded mock submission.
    #[allow(clippy::module_name_repetitions)]
    #[derive(Clone, Debug, Eq, PartialEq)]
    pub struct MockSubmission {
        /// The calldata bytes submitted.
        pub calldata: Vec<u8>,
        /// The synthesised tx-hash.
        pub tx_hash: [u8; 32],
    }

    /// Mock submitter — records every submission and reports
    /// configurable inclusion-check results.
    #[allow(clippy::module_name_repetitions)]
    #[derive(Debug)]
    pub struct MockSubmitter {
        inner: Mutex<MockInner>,
    }

    #[derive(Debug, Default)]
    struct MockInner {
        submitted: Vec<MockSubmission>,
        /// If `true`, `submit` returns `RpcRejected("mock rejection")`.
        next_reject: bool,
        /// Map from `tx_hash` → inclusion-check result.  Defaults
        /// to `Some(true)` (confirmed).
        inclusion_map: std::collections::HashMap<[u8; 32], Option<bool>>,
        /// Counter — number of times `invalidate_nonce_cache` has
        /// been called.  Used by tests to verify the observer
        /// correctly signals broadcast failures to the submitter.
        invalidate_count: usize,
    }

    impl Default for MockSubmitter {
        fn default() -> Self {
            Self::new()
        }
    }

    impl MockSubmitter {
        /// Construct an empty mock submitter.
        #[must_use]
        pub fn new() -> Self {
            Self {
                inner: Mutex::new(MockInner::default()),
            }
        }

        /// Read-accessor for the submission history.
        #[must_use]
        pub fn submissions(&self) -> Vec<MockSubmission> {
            self.inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .submitted
                .clone()
        }

        /// Configure the next `submit` to return `RpcRejected`.
        pub fn set_next_reject(&self) {
            self.inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .next_reject = true;
        }

        /// Configure a specific tx-hash's inclusion outcome.
        pub fn set_inclusion(&self, tx_hash: [u8; 32], inclusion: Option<bool>) {
            self.inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .inclusion_map
                .insert(tx_hash, inclusion);
        }

        /// Read the `invalidate_nonce_cache` call count.  Tests
        /// use this to verify the observer correctly signals
        /// broadcast failures via the trait hook.
        #[must_use]
        pub fn invalidate_count(&self) -> usize {
            self.inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .invalidate_count
        }
    }

    impl Submitter for MockSubmitter {
        fn build_and_sign(&self, calldata: &[u8]) -> Result<PreparedTx, SubmitError> {
            // The mock's `tx_hash` is deterministic per calldata
            // for test reproducibility.  The `raw_bytes` is the
            // calldata itself — the mock has no real transaction
            // envelope.  Production submitters override.
            let mut hasher = Keccak256::new();
            hasher.update(calldata);
            let digest = hasher.finalize();
            let mut tx_hash = [0u8; 32];
            tx_hash.copy_from_slice(&digest);
            Ok(PreparedTx {
                tx_hash,
                raw_bytes: calldata.to_vec(),
            })
        }

        fn broadcast(&self, prepared: &PreparedTx) -> Result<(), SubmitError> {
            let mut inner = self
                .inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if inner.next_reject {
                inner.next_reject = false;
                return Err(SubmitError::RpcRejected("mock rejection".into()));
            }
            inner.submitted.push(MockSubmission {
                calldata: prepared.raw_bytes.clone(),
                tx_hash: prepared.tx_hash,
            });
            Ok(())
        }

        fn check_inclusion(&self, tx_hash: &[u8; 32]) -> Result<Option<bool>, SubmitError> {
            let inner = self
                .inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            Ok(inner
                .inclusion_map
                .get(tx_hash)
                .copied()
                .unwrap_or(Some(true)))
        }

        fn invalidate_nonce_cache(&self) {
            let mut inner = self
                .inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            inner.invalidate_count += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        encode_calldata, encode_claim_timeout_calldata, encode_respond_calldata,
        encode_submit_calldata, encode_terminate_calldata, CellProof, MethodSelector, SubmitError,
    };
    use crate::game::{Claim, StateCommit};
    use crate::strategy::{HonestMove, TerminateBundle};
    use crate::submitter::mock::MockSubmitter;
    use crate::submitter::Submitter;

    fn commit(seed: u8) -> StateCommit {
        let mut out = [0u8; 32];
        out[0] = seed;
        out
    }

    /// Method selectors are distinct.
    #[test]
    fn method_selectors_distinct() {
        let selectors = [
            MethodSelector::SubmitMidpoint.selector(),
            MethodSelector::RespondToMidpoint.selector(),
            MethodSelector::TerminateOnSingleStep.selector(),
            MethodSelector::ClaimTimeout.selector(),
        ];
        for (i, a) in selectors.iter().enumerate() {
            for (j, b) in selectors.iter().enumerate() {
                if i != j {
                    assert_ne!(a, b, "selectors {i} and {j} collide");
                }
            }
        }
    }

    /// Audit-pass-4-round-3 regression: pin every method
    /// selector against the canonical value `forge inspect`
    /// reports for the deployed `CanonFaultProofGame`.  A
    /// Solidity-side rename / signature change would silently
    /// produce wrong calldata on-chain; this test breaks the
    /// build instead.
    #[test]
    fn method_selectors_pinned_against_solidity_abi() {
        // Verified via `forge inspect CanonFaultProofGame methods`
        // (run in `solidity/`).  Per the audit pass: the
        // `terminateOnSingleStep` MINIMUM-form is observer-
        // internal-only (selector `e0e5c8ba`); production
        // calldata uses the FULL-form selector below.
        assert_eq!(
            MethodSelector::SubmitMidpoint.selector(),
            [0x11, 0xd9, 0x25, 0xb3],
            "SubmitMidpoint selector drift",
        );
        assert_eq!(
            MethodSelector::RespondToMidpoint.selector(),
            [0x7e, 0x4d, 0x30, 0xfc],
            "RespondToMidpoint selector drift",
        );
        assert_eq!(
            MethodSelector::ClaimTimeout.selector(),
            [0x86, 0xe7, 0x73, 0xf1],
            "ClaimTimeout selector drift",
        );
        assert_eq!(
            MethodSelector::TerminateOnSingleStepFull.selector(),
            [0x2f, 0x32, 0xc7, 0x98],
            "TerminateOnSingleStepFull selector drift; \
             check Solidity signature in CanonFaultProofGame.sol line 383",
        );
    }

    /// Method-selector encoding matches expected calldata-prefix
    /// shape.  We don't pin the actual selector bytes here (they'd
    /// require computing keccak256 by hand); instead, check the
    /// selector length and that `signature()` round-trips.
    #[test]
    fn method_selector_length_4() {
        for m in [
            MethodSelector::SubmitMidpoint,
            MethodSelector::RespondToMidpoint,
            MethodSelector::TerminateOnSingleStep,
            MethodSelector::ClaimTimeout,
        ] {
            assert_eq!(m.selector().len(), 4);
            assert!(!m.signature().is_empty());
        }
    }

    /// `encode_calldata(NoMove)` errors.
    #[test]
    fn no_move_errors() {
        let err = encode_calldata(1, HonestMove::NoMove).unwrap_err();
        assert!(matches!(err, SubmitError::NoMove));
    }

    /// `encode_calldata(Submit(_))` uses the submit calldata
    /// encoding.
    #[test]
    fn submit_uses_submit_calldata() {
        let c = Claim {
            idx: 32,
            commit: commit(99),
        };
        let bytes = encode_calldata(42, HonestMove::Submit(c)).unwrap();
        // 4-byte selector + 32 (u256 game id) + 32 (bytes32 commit).
        assert_eq!(bytes.len(), 68);
        assert_eq!(&bytes[0..4], &MethodSelector::SubmitMidpoint.selector());
    }

    /// `encode_calldata(RespondAgree)` uses the respond calldata.
    #[test]
    fn respond_agree_uses_respond_calldata() {
        let bytes = encode_calldata(42, HonestMove::RespondAgree).unwrap();
        assert_eq!(bytes.len(), 68);
        assert_eq!(&bytes[0..4], &MethodSelector::RespondToMidpoint.selector());
        // Last byte is the bool: 1 = true.
        assert_eq!(bytes[67], 1);
    }

    /// `encode_calldata(RespondDisagree)` uses the respond
    /// calldata with `agree=false`.
    #[test]
    fn respond_disagree_uses_respond_calldata() {
        let bytes = encode_calldata(42, HonestMove::RespondDisagree).unwrap();
        assert_eq!(bytes.len(), 68);
        assert_eq!(&bytes[0..4], &MethodSelector::RespondToMidpoint.selector());
        assert_eq!(bytes[67], 0);
    }

    /// `encode_calldata(TerminateOnSingleStep)` refuses to
    /// silently emit wrong-selector calldata.  The full-form
    /// calldata (with actionKind + actionFields + cellProofs)
    /// requires a `canon` subprocess pipeline that is deferred
    /// RH-G follow-up work.
    #[test]
    fn terminate_calldata_refuses_minimum_form() {
        let err = encode_calldata(
            42,
            HonestMove::TerminateOnSingleStep {
                claimed_post_commit: commit(7),
            },
        )
        .unwrap_err();
        assert!(matches!(err, SubmitError::TerminateNotImplemented));
    }

    /// The minimum-form `encode_terminate_calldata` helper is
    /// still callable for integration smoke tests.  It produces
    /// the 4-byte selector + 32-byte gameId + 32-byte commit
    /// shape.  Production callers should NOT broadcast this —
    /// the selector doesn't match the deployed contract's
    /// full-form signature.
    #[test]
    fn encode_terminate_calldata_minimum_form_shape() {
        let bytes = encode_terminate_calldata(42, commit(7));
        assert_eq!(bytes.len(), 68);
        assert_eq!(
            &bytes[0..4],
            &MethodSelector::TerminateOnSingleStep.selector()
        );
        assert_eq!(&bytes[36..68], &commit(7));
    }

    /// `encode_claim_timeout_calldata` length is 4 + 32 = 36.
    #[test]
    fn claim_timeout_calldata_length() {
        let bytes = encode_claim_timeout_calldata(42);
        assert_eq!(bytes.len(), 36);
        assert_eq!(&bytes[0..4], &MethodSelector::ClaimTimeout.selector());
    }

    /// Full-form `terminateOnSingleStep` calldata layout
    /// verification.  Encodes a tiny example with one
    /// `CellProof` and verifies the head/tail boundaries and
    /// pointer values.
    #[test]
    fn encode_terminate_full_calldata_shape() {
        use super::{encode_terminate_full_calldata, ActionKind, CellProof};

        let cell = CellProof {
            cell_kind: 0, // Balance
            key_a: 7,
            key_b: 11,
            cell_value: vec![0xAA, 0xBB, 0xCC],
            witness_commit: [0x42u8; 32],
        };
        let bytes = encode_terminate_full_calldata(
            123_u128,
            ActionKind::Transfer as u8,
            &[1, 2, 3, 4],
            999_u64,
            std::slice::from_ref(&cell),
            commit(0xAB),
        );

        // Length sanity: 4-byte selector + 6×32-byte head + tails.
        // actionFields tail: 32 (length) + 32 (4 bytes padded) = 64.
        // cellProofs tail: 32 (length) + 32 (1 pointer) + per-cell tuple.
        //   per-cell: 5×32 head + 32 (cellValue length) + 32 (padded 3 bytes) = 224.
        // Total tail: 64 + 32 + 32 + 224 = 352.
        // Total: 4 + 192 + 352 = 548.
        assert_eq!(bytes.len(), 4 + 192 + 64 + 32 + 32 + 224);

        // Selector matches the full-form signature's hash.
        assert_eq!(
            &bytes[0..4],
            &MethodSelector::TerminateOnSingleStepFull.selector()
        );

        // Word 0 (offset 4..36): gameId = 123.
        let mut expected_gid = [0u8; 32];
        expected_gid[31] = 123;
        assert_eq!(&bytes[4..36], &expected_gid);

        // Word 5 (offset 4+5*32 = 164..196): claimedPostCommit.
        assert_eq!(&bytes[164..196], &commit(0xAB));
    }

    /// `MethodSelector::TerminateOnSingleStepFull` produces a
    /// DIFFERENT 4-byte selector than the minimum form, because
    /// they have different Solidity signatures.
    #[test]
    fn terminate_full_vs_minimum_selectors_differ() {
        let minimum = MethodSelector::TerminateOnSingleStep.selector();
        let full = MethodSelector::TerminateOnSingleStepFull.selector();
        assert_ne!(minimum, full);
    }

    /// `CellProof`-tuple encoding: head/tail boundary checked.
    /// One cell with empty `cell_value` produces a tuple of
    /// exactly 5×32 + 32 (length only, no payload) + 0 padding
    /// = 192 bytes.
    #[test]
    fn cell_proof_tuple_with_empty_cell_value() {
        use super::{encode_cell_proof_tuple, CellProof};
        let cell = CellProof {
            cell_kind: 1,
            key_a: 0,
            key_b: 0,
            cell_value: vec![],
            witness_commit: [0u8; 32],
        };
        let bytes = encode_cell_proof_tuple(&cell);
        assert_eq!(bytes.len(), 5 * 32 + 32);
        // The cellValue offset (word 3) is `5 * 32 = 160`.
        let mut expected_offset = [0u8; 32];
        expected_offset[31] = 160;
        assert_eq!(&bytes[3 * 32..4 * 32], &expected_offset);
        // The cellValue length (at offset 5*32 = 160) is 0.
        let expected_len = [0u8; 32];
        assert_eq!(&bytes[160..192], expected_len.as_slice());
    }

    /// Empty `cell_proofs` array: encoded as length=0 + no
    /// pointers + no data.  Total 32 bytes for the array.
    #[test]
    fn encode_cell_proof_array_empty() {
        use super::encode_cell_proof_array;
        let bytes = encode_cell_proof_array(&[]);
        assert_eq!(bytes.len(), 32);
        // Length word is all-zero.
        assert_eq!(bytes, vec![0u8; 32]);
    }

    /// `ActionKind` byte values match the documented
    /// constructor tags (mirror of Lean's `Authority.Action`).
    #[test]
    fn action_kind_byte_values() {
        use super::ActionKind;
        assert_eq!(ActionKind::Transfer as u8, 0);
        assert_eq!(ActionKind::Mint as u8, 1);
        assert_eq!(ActionKind::Burn as u8, 2);
        assert_eq!(ActionKind::FaultProofResolution as u8, 18);
    }

    /// Game id is encoded as 32-byte big-endian.
    #[test]
    fn game_id_encoded_as_32_byte_be() {
        let bytes = encode_submit_calldata(0xFEED_BEEF, commit(1));
        // Selector + u256(0xFEEDBEEF padded) + commit
        // u256 of 0xFEEDBEEF: 28 zero bytes then 4 bytes BE.
        let id_word = &bytes[4..36];
        assert_eq!(&id_word[28..32], &0xFEED_BEEFu32.to_be_bytes());
        for b in &id_word[..28] {
            assert_eq!(*b, 0);
        }
    }

    /// Game id `u128::MAX` is encoded correctly.
    #[test]
    fn game_id_u128_max_encoded() {
        let bytes = encode_submit_calldata(u128::MAX, commit(1));
        // u128::MAX = upper 16 bytes zero, lower 16 bytes 0xFF.
        let id_word = &bytes[4..36];
        for b in &id_word[..16] {
            assert_eq!(*b, 0);
        }
        for b in &id_word[16..32] {
            assert_eq!(*b, 0xFF);
        }
    }

    /// Bool encoding pads correctly.
    #[test]
    fn bool_encoding_padded() {
        let bytes = encode_respond_calldata(1, true);
        // The bool word is the last 32 bytes.
        let bool_word = &bytes[36..68];
        for b in &bool_word[..31] {
            assert_eq!(*b, 0);
        }
        assert_eq!(bool_word[31], 1);
    }

    /// `encode_terminate_calldata` puts the commit at the end.
    #[test]
    fn terminate_commit_at_end() {
        let bytes = encode_terminate_calldata(42, commit(0xAA));
        let commit_word = &bytes[36..68];
        assert_eq!(commit_word, &commit(0xAA));
    }

    /// Mock submitter records broadcasts via the new two-step
    /// `build_and_sign` + `broadcast` API.
    #[test]
    fn mock_submitter_records_broadcast() {
        let m = MockSubmitter::new();
        let calldata = vec![1u8, 2, 3, 4];
        let prepared = m.build_and_sign(&calldata).unwrap();
        // The prepared `tx_hash` is the deterministic
        // keccak256(calldata).  The `raw_bytes` is calldata.
        assert_eq!(prepared.raw_bytes, calldata);
        // build_and_sign should NOT record into `submissions`
        // (it's a build-only step; broadcast records).
        assert_eq!(m.submissions().len(), 0);
        m.broadcast(&prepared).unwrap();
        let recorded = m.submissions();
        assert_eq!(recorded.len(), 1);
        assert_eq!(recorded[0].calldata, calldata);
        assert_eq!(recorded[0].tx_hash, prepared.tx_hash);
    }

    /// Mock submitter's tx-hash is deterministic
    /// (keccak256(calldata)).
    #[test]
    fn mock_submitter_tx_hash_deterministic() {
        let m1 = MockSubmitter::new();
        let m2 = MockSubmitter::new();
        let calldata = vec![5u8, 6, 7];
        let p1 = m1.build_and_sign(&calldata).unwrap();
        let p2 = m2.build_and_sign(&calldata).unwrap();
        assert_eq!(p1.tx_hash, p2.tx_hash);
    }

    /// Mock submitter `set_next_reject` triggers a typed
    /// error on the next broadcast call.
    #[test]
    fn mock_submitter_set_next_reject() {
        let m = MockSubmitter::new();
        m.set_next_reject();
        let p1 = m.build_and_sign(&[1u8]).unwrap();
        let err = m.broadcast(&p1).unwrap_err();
        assert!(matches!(err, SubmitError::RpcRejected(_)));
        // Subsequent broadcasts succeed.
        let p2 = m.build_and_sign(&[2u8]).unwrap();
        m.broadcast(&p2).unwrap();
    }

    /// Mock submitter inclusion-check default: `Some(true)`.
    #[test]
    fn mock_submitter_inclusion_default_confirmed() {
        let m = MockSubmitter::new();
        let p = m.build_and_sign(&[1u8]).unwrap();
        m.broadcast(&p).unwrap();
        assert_eq!(m.check_inclusion(&p.tx_hash).unwrap(), Some(true));
    }

    /// Mock submitter inclusion-check honors `set_inclusion`.
    #[test]
    fn mock_submitter_inclusion_configurable() {
        let m = MockSubmitter::new();
        let p = m.build_and_sign(&[1u8]).unwrap();
        m.broadcast(&p).unwrap();
        m.set_inclusion(p.tx_hash, Some(false));
        assert_eq!(m.check_inclusion(&p.tx_hash).unwrap(), Some(false));
        m.set_inclusion(p.tx_hash, None);
        assert_eq!(m.check_inclusion(&p.tx_hash).unwrap(), None);
    }

    /// `build_and_sign` is purely computational — no network
    /// I/O — so it never fails for the mock.  Property of the
    /// trait contract.
    #[test]
    fn mock_build_and_sign_is_pure() {
        let m = MockSubmitter::new();
        let p = m.build_and_sign(&[]).unwrap();
        assert_eq!(p.raw_bytes.len(), 0);
        // Tx hash for empty calldata is keccak256("") =
        // 0xc5d2... which is the canonical empty-input hash.
        // Just verify it's non-zero.
        assert_ne!(p.tx_hash, [0u8; 32]);
    }

    /// `build_and_sign` + `broadcast` separation: the broadcast can
    /// happen multiple times for the same prepared tx without
    /// computing the hash twice (idempotent at the tx-hash level).
    #[test]
    fn mock_broadcast_idempotent_at_tx_hash_level() {
        let m = MockSubmitter::new();
        let p = m.build_and_sign(&[1u8, 2, 3]).unwrap();
        m.broadcast(&p).unwrap();
        m.broadcast(&p).unwrap();
        // Both broadcasts are recorded — the mock doesn't
        // dedup.  Production submitters MAY dedup at the
        // network layer (eth_sendRawTransaction returns
        // "already known"), but the mock is intentionally
        // dumb so tests can observe re-broadcast attempts.
        assert_eq!(m.submissions().len(), 2);
    }

    /// Selectors for different methods are non-zero.
    #[test]
    fn selectors_non_zero() {
        for m in [
            MethodSelector::SubmitMidpoint,
            MethodSelector::RespondToMidpoint,
            MethodSelector::TerminateOnSingleStep,
            MethodSelector::ClaimTimeout,
        ] {
            assert_ne!(m.selector(), [0u8; 4]);
        }
    }

    /// Audit-pass-4-round-3 CRITICAL regression: pin that the
    /// Rust `CellProof` struct can deserialize the EXACT JSON
    /// shape the Lean `canon export-cell-proofs` subcommand
    /// emits.  Before this round, the Rust struct had a bare
    /// `serde::Deserialize` derive that EXPECTED `u128` as a
    /// JSON number and `[u8; 32]` as a JSON array — but the
    /// Lean side emits both as hex strings.  Cross-stack
    /// deserialization was silently broken at the type
    /// boundary.  This test pins the exact wire format the
    /// Lean emitter produces and verifies the Rust struct
    /// decodes it byte-equivalently.
    #[test]
    fn cell_proof_deserialize_matches_lean_emitter_format() {
        // The byte-string produced by `formatCellProofJson` for
        // a minimal balance cell with resource=7, actor=1, an
        // empty cellValue, and a witness commit of 0xAB
        // repeating (synthesized by Lean's `commitExtendedState`
        // — but we pin to a concrete 32-byte string for byte
        // stability).
        let lean_json = r#"{
            "cell_kind": 0,
            "key_a": "0000000000000007",
            "key_b": "0000000000000001",
            "cell_value": "",
            "witness_commit": "abababababababababababababababababababababababababababababababab"
        }"#;
        let parsed: CellProof = serde_json::from_str(lean_json)
            .expect("Lean cell-proof JSON must deserialize into Rust CellProof");
        assert_eq!(parsed.cell_kind, 0);
        assert_eq!(parsed.key_a, 7);
        assert_eq!(parsed.key_b, 1);
        assert_eq!(parsed.cell_value, Vec::<u8>::new());
        assert_eq!(parsed.witness_commit, [0xABu8; 32]);
    }

    /// Audit-pass-4-round-3 CRITICAL regression: non-empty
    /// cellValue round-trip.
    #[test]
    fn cell_proof_deserialize_non_empty_cell_value() {
        let lean_json = r#"{
            "cell_kind": 1,
            "key_a": "0000000000000005",
            "key_b": "0000000000000000",
            "cell_value": "deadbeef",
            "witness_commit": "0000000000000000000000000000000000000000000000000000000000000000"
        }"#;
        let parsed: CellProof = serde_json::from_str(lean_json).unwrap();
        assert_eq!(parsed.cell_value, vec![0xDE, 0xAD, 0xBE, 0xEF]);
    }

    /// Pin that Rust `CellProof::serialize` round-trips through
    /// Lean's wire format byte-equivalently.  Catches drift in
    /// either direction.
    #[test]
    fn cell_proof_serialize_then_deserialize_round_trips() {
        let original = CellProof {
            cell_kind: 2,
            key_a: 0xABCD_EF01,
            key_b: 0x0011_2233,
            cell_value: vec![1, 2, 3, 4, 5],
            witness_commit: [0xCC; 32],
        };
        let serialized = serde_json::to_string(&original).unwrap();
        let parsed: CellProof = serde_json::from_str(&serialized).unwrap();
        assert_eq!(parsed, original);
    }

    /// The Lean side emits 16-hex-char zero-padded strings.
    /// Verify Rust's `Serialize` produces the same shape.
    #[test]
    fn cell_proof_serialize_matches_lean_emitter_format() {
        let cp = CellProof {
            cell_kind: 3,
            key_a: 7,
            key_b: 1,
            cell_value: vec![],
            witness_commit: [0xABu8; 32],
        };
        let json = serde_json::to_string(&cp).unwrap();
        // key_a / key_b are 16-hex-char zero-padded.
        assert!(
            json.contains("\"key_a\":\"0000000000000007\""),
            "expected zero-padded key_a hex, got: {json}"
        );
        assert!(
            json.contains("\"key_b\":\"0000000000000001\""),
            "expected zero-padded key_b hex, got: {json}"
        );
        // cell_value is lowercase hex (empty here).
        assert!(json.contains("\"cell_value\":\"\""), "got: {json}");
        // witness_commit is 64-hex-char lowercase.
        assert!(
            json.contains("\"witness_commit\":\"abababababababababababababababababababababababababababababababab\""),
            "got: {json}"
        );
    }

    /// Malformed hex string surfaces a typed serde error.
    #[test]
    fn cell_proof_deserialize_rejects_malformed_hex() {
        let bad = r#"{
            "cell_kind": 0,
            "key_a": "notvalidhex",
            "key_b": "0000000000000001",
            "cell_value": "",
            "witness_commit": "0000000000000000000000000000000000000000000000000000000000000000"
        }"#;
        let err = serde_json::from_str::<CellProof>(bad).unwrap_err();
        assert!(
            err.to_string().contains("invalid hex"),
            "expected hex-decode error, got: {err}"
        );
    }

    /// Audit-pass-4-round-4 MEDIUM regression: oversize
    /// `cell_value` hex MUST surface a typed error (not OOM).
    /// Pin the cap at `MAX_CELL_VALUE_BYTES = 1 MiB`.
    #[test]
    fn cell_proof_deserialize_rejects_oversize_cell_value() {
        // Construct a hex string longer than 2 * MAX_CELL_VALUE_BYTES.
        let oversize_hex = "ff".repeat(super::MAX_CELL_VALUE_BYTES + 1);
        let bad = format!(
            r#"{{
                "cell_kind": 0,
                "key_a": "0000000000000007",
                "key_b": "0000000000000001",
                "cell_value": "{oversize_hex}",
                "witness_commit": "0000000000000000000000000000000000000000000000000000000000000000"
            }}"#
        );
        let err = serde_json::from_str::<CellProof>(&bad).unwrap_err();
        assert!(
            err.to_string().contains("cell_value")
                && (err.to_string().contains("cap") || err.to_string().contains("exceeds")),
            "expected oversize cell_value rejection, got: {err}"
        );
    }

    /// Witness commit wrong length surfaces a typed serde error.
    #[test]
    fn cell_proof_deserialize_rejects_short_witness_commit() {
        let bad = r#"{
            "cell_kind": 0,
            "key_a": "0000000000000007",
            "key_b": "0000000000000001",
            "cell_value": "",
            "witness_commit": "deadbeef"
        }"#;
        let err = serde_json::from_str::<CellProof>(bad).unwrap_err();
        assert!(
            err.to_string().contains("32 bytes"),
            "expected 32-byte length error, got: {err}"
        );
    }

    // -------------------------------------------------------------
    // Workstream SVC.5 tests: `encode_calldata_with_bundle`
    // -------------------------------------------------------------

    fn sample_bundle(commit_bytes: [u8; 32]) -> TerminateBundle {
        TerminateBundle {
            fixture_id: "log[0]".to_string(),
            action_kind: 1,
            action_fields: vec![0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2],
            signer: 5,
            claimed_post_commit: commit_bytes,
            cell_proofs: vec![],
        }
    }

    /// `encode_calldata_with_bundle` for non-terminate moves
    /// delegates to `encode_calldata`.
    #[test]
    fn encode_with_bundle_delegates_for_non_terminate() {
        let c = commit(7);
        let claim = crate::game::Claim { idx: 42, commit: c };
        let with_bundle =
            crate::submitter::encode_calldata_with_bundle(10, HonestMove::Submit(claim), None)
                .unwrap();
        let without_bundle = encode_submit_calldata(10, c);
        assert_eq!(with_bundle, without_bundle);
    }

    /// `encode_calldata_with_bundle` for terminate WITHOUT a
    /// bundle returns `TerminateNotImplemented`.
    #[test]
    fn encode_with_bundle_terminate_without_bundle_errors() {
        let c = commit(7);
        let result = crate::submitter::encode_calldata_with_bundle(
            10,
            HonestMove::TerminateOnSingleStep {
                claimed_post_commit: c,
            },
            None,
        );
        assert!(matches!(result, Err(SubmitError::TerminateNotImplemented)));
    }

    /// `encode_calldata_with_bundle` for terminate WITH a bundle
    /// returns full-form calldata.
    #[test]
    fn encode_with_bundle_terminate_with_bundle_succeeds() {
        let c = commit(7);
        let bundle = sample_bundle(c);
        let calldata = crate::submitter::encode_calldata_with_bundle(
            10,
            HonestMove::TerminateOnSingleStep {
                claimed_post_commit: c,
            },
            Some(&bundle),
        )
        .unwrap();
        // Calldata must start with the full-form selector.
        assert!(calldata.len() >= 4);
        assert_eq!(
            &calldata[0..4],
            MethodSelector::TerminateOnSingleStepFull.selector()
        );
    }

    /// `encode_calldata_with_bundle` refuses when the bundle's
    /// `claimed_post_commit` disagrees with the strategy's
    /// `claimed_post_commit` (defence-in-depth against oracle
    /// drift).
    #[test]
    fn encode_with_bundle_terminate_commit_mismatch_errors() {
        let c1 = commit(7);
        let c2 = commit(8);
        let bundle = sample_bundle(c1);
        let result = crate::submitter::encode_calldata_with_bundle(
            10,
            HonestMove::TerminateOnSingleStep {
                claimed_post_commit: c2,
            },
            Some(&bundle),
        );
        assert!(matches!(result, Err(SubmitError::BundleCommitMismatch)));
    }

    /// Cross-stack regression: the full-form `terminateOnSingleStep`
    /// selector matches the keccak256 of the canonical Solidity
    /// signature.  Load-bearing pin against signature drift on
    /// either side; if a renamed parameter changes the canonical
    /// signature string, the selector changes and this test fails.
    #[test]
    fn full_form_terminate_selector_pinned() {
        use sha3::{Digest as _, Keccak256};
        let actual = MethodSelector::TerminateOnSingleStepFull.selector();
        let mut h = Keccak256::new();
        h.update(
            b"terminateOnSingleStep(uint256,uint8,bytes,uint64,(uint8,uint256,uint256,bytes,bytes32)[],bytes32)",
        );
        let digest = h.finalize();
        let mut expected = [0u8; 4];
        expected.copy_from_slice(&digest[0..4]);
        assert_eq!(
            actual, expected,
            "terminateOnSingleStep full-form selector drift; \
             actual={actual:02x?}, expected={expected:02x?}",
        );
    }
}
