// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! eth_call-based reader for the `CanonFaultProofGame` contract's
//! per-game state.  Closes RH-G's "contract-state read" follow-up
//! by hydrating the observer's cold-start `state_known=false`
//! placeholders with the full on-chain state.
//!
//! ## Wire format
//!
//! The contract's auto-generated `games(uint256)` getter returns a
//! 15-field tuple matching the Solidity `Game` struct layout
//! (verified via `forge inspect CanonFaultProofGame abi --json`).
//! Three of the fields (`low`, `high`, `pendingMidpoint`) are
//! themselves 2-field tuples `(uint64 idx, bytes32 commit)`.
//!
//! Solidity ABI encoding flattens nested static tuples into their
//! component slots, so the wire layout is 18 × 32-byte slots
//! (576 bytes total):
//!
//! ```text
//!  Slot   Field
//!  ----   --------------------------------------------------------
//!  0      address sequencer (right-aligned in 32 bytes)
//!  1      address challenger
//!  2      uint64 low.idx (right-aligned)
//!  3      bytes32 low.commit
//!  4      uint64 high.idx
//!  5      bytes32 high.commit
//!  6      bool hasPendingMidpoint (0 or 1 in slot[31])
//!  7      uint64 pendingMidpoint.idx
//!  8      bytes32 pendingMidpoint.commit
//!  9      uint64 depth
//! 10      uint8 turn (slot[31] in {0, 1})
//! 11      uint64 turnDeadline
//! 12      uint128 sequencerBond (right-aligned)
//! 13      uint128 challengerBond
//! 14      uint8 status (slot[31] in {0..=4})
//! 15      bytes32 deploymentId
//! 16      uint64 lastStepBlock
//! 17      uint64 disputedLogIndex
//! ```
//!
//! All fields are STATIC (no dynamic types), so the response is
//! exactly 576 bytes regardless of payload values.
//!
//! Method selector: `keccak256("games(uint256)")[..4]` =
//! `0x117a5b90` (verified via `forge inspect CanonFaultProofGame
//! methods` and pinned in [`selector_matches_solidity_inspector_output`]).
//!
//! ## Cross-deployment-replay defence
//!
//! The reader's [`ContractGameReader::read_and_validate`] entry
//! point validates the returned `deploymentId` against the
//! observer's expected value BEFORE installing the state.
//! Mismatches surface as
//! [`GameStateReadError::DeploymentIdMismatch`].  This closes the
//! cross-deployment-replay gap documented in
//! `Observer::handle_game_opened`'s docstring at the RH-G
//! initial landing.

use crate::game::{Claim, DisputedRange, GameState, GameStatus, TurnSide};
use knomosis_l1_ingest::source::json_rpc::JsonRpcL1Source;
use serde_json::{json, Value};
use sha3::{Digest, Keccak256};

/// Number of 32-byte ABI slots in the `games(uint256)` response.
pub const GAMES_RESPONSE_SLOTS: usize = 18;

/// Total response byte length: `GAMES_RESPONSE_SLOTS × 32`.
pub const GAMES_RESPONSE_BYTES: usize = GAMES_RESPONSE_SLOTS * 32;

/// 4-byte selector for `games(uint256)`.  Pinned constant;
/// regression-tested against the keccak256 of the signature.
const GAMES_SELECTOR: [u8; 4] = [0x11, 0x7a, 0x5b, 0x90];

/// Errors the state reader can produce.
#[derive(Debug, thiserror::Error)]
pub enum GameStateReadError {
    /// The L1 RPC transport failed.
    #[error("L1 RPC error: {0}")]
    RpcTransport(String),
    /// The `eth_call` returned a non-hex / malformed response.
    #[error("malformed eth_call response: {0}")]
    Malformed(String),
    /// The response length was unexpected (not exactly
    /// `GAMES_RESPONSE_BYTES`).
    #[error("`eth_call` response wrong length: expected {expected} bytes, got {actual}")]
    WrongLength {
        /// The expected response length.
        expected: usize,
        /// The actual response length.
        actual: usize,
    },
    /// The returned `turn` byte was outside the legal `0..=1` range
    /// or the slot's high 31 bytes were non-zero (non-canonical
    /// Solidity encoding).
    #[error("`eth_call` returned invalid turn byte: {0}")]
    InvalidTurn(u8),
    /// The returned `status` byte was outside the legal `0..=4` range
    /// or the slot's high 31 bytes were non-zero.
    #[error("`eth_call` returned invalid status byte: {0}")]
    InvalidStatus(u8),
    /// The returned `bool` slot was non-canonical: either the slot's
    /// high 31 bytes were non-zero, or `slot[31]` was outside
    /// `{0, 1}`.  Solidity's `solc` only ever emits 0 or 1.  A
    /// non-canonical encoding indicates either a malicious RPC or a
    /// buggy contract upgrade.
    #[error("`eth_call` returned non-canonical bool encoding (byte={0})")]
    InvalidBool(u8),
    /// The returned `depth` exceeded `u32::MAX`.  The L1 contract
    /// enforces `depth <= MAX_BISECTION_DEPTH = 64`, so a value
    /// over `u32::MAX` indicates either a malicious RPC or contract
    /// state corruption.
    #[error("`eth_call` returned depth out of range: {0} > u32::MAX")]
    DepthOutOfRange(u64),
    /// The returned state has zero sequencer address.  Solidity's
    /// `initiateChallenge` rejects this via `ZeroAddress`.  A
    /// non-zero sequencer is a contract-level invariant.
    #[error("`eth_call` returned zero sequencer address")]
    ZeroSequencer,
    /// The returned state has zero challenger address.
    #[error("`eth_call` returned zero challenger address")]
    ZeroChallenger,
    /// Sequencer and challenger projected to the same actor ID.
    /// Solidity's `initiateChallenge` enforces
    /// `sequencer != challenger`; this defends against an RPC
    /// returning an inconsistent state.
    #[error("`eth_call` returned colliding sequencer/challenger (both project to {0})")]
    SequencerChallengerCollision(u64),
    /// The returned `deploymentId` does not match the observer's
    /// configured deployment ID.  Cross-deployment-replay defence.
    #[error("deployment ID mismatch: contract returned 0x{contract_hex}, observer expects 0x{observer_hex}")]
    DeploymentIdMismatch {
        /// The contract-returned deployment ID (hex, no `0x`).
        contract_hex: String,
        /// The observer's expected deployment ID (hex, no `0x`).
        observer_hex: String,
    },
    /// The returned state has `low.idx >= high.idx`, which is
    /// degenerate (the kernel reference rejects this at
    /// `applyTransition` time).
    #[error("`eth_call` returned degenerate range: low.idx={low_idx} >= high.idx={high_idx}")]
    DegenerateRange {
        /// The low-bound log index.
        low_idx: u64,
        /// The high-bound log index.
        high_idx: u64,
    },
}

/// A reader for the `CanonFaultProofGame` contract's per-game
/// state via the auto-generated `games(uint256)` getter.
///
/// Holds a reference to a `JsonRpcL1Source` (re-using the
/// knomosis-l1-ingest crate's audited HTTP/1.1 + JSON-RPC client).
pub struct ContractGameReader<'a> {
    rpc: &'a JsonRpcL1Source,
    game_contract_hex: String,
}

impl<'a> ContractGameReader<'a> {
    /// Construct a reader from an existing JSON-RPC source and the
    /// game contract's L1 address.
    ///
    /// `game_contract`: 20-byte L1 address.
    #[must_use]
    pub fn new(rpc: &'a JsonRpcL1Source, game_contract: [u8; 20]) -> Self {
        let game_contract_hex = format!("0x{}", hex::encode(game_contract));
        Self {
            rpc,
            game_contract_hex,
        }
    }

    /// Read the full per-game state via `eth_call` to
    /// `games(uint256)`.
    ///
    /// Returns the decoded `GameState` on success.  The returned
    /// state's `deployment_id` field is populated from the
    /// contract; callers MUST cross-check it against their
    /// expected value before installing.  Use
    /// [`Self::read_and_validate`] for the orchestrator-friendly
    /// variant that delegates this check.
    ///
    /// # Errors
    ///
    /// See [`GameStateReadError`].
    pub fn read_game(&self, game_id: u128) -> Result<GameState, GameStateReadError> {
        let calldata = encode_games_calldata(game_id);
        let calldata_hex = format!("0x{}", hex::encode(calldata));
        let params = json!([
            {
                "to": self.game_contract_hex,
                "data": calldata_hex,
            },
            "latest"
        ]);
        let response = self
            .rpc
            .rpc("eth_call", params)
            .map_err(|e| GameStateReadError::RpcTransport(e.to_string()))?;
        let hex_str = match response {
            Value::String(s) => s,
            other => {
                return Err(GameStateReadError::Malformed(format!(
                    "expected string response, got: {other}"
                )))
            }
        };
        let bytes = decode_hex_response(&hex_str)?;
        decode_game_state(&bytes)
    }

    /// Read the per-game state AND validate the returned
    /// `deploymentId` against the observer's expected value, plus
    /// the range non-degeneracy invariant.  Returns the validated
    /// state or a typed error.
    ///
    /// # Errors
    ///
    /// See [`GameStateReadError`].  In particular:
    /// * [`GameStateReadError::DeploymentIdMismatch`] surfaces
    ///   when the contract returns a different deployment ID
    ///   than expected (cross-deployment-replay defence).
    /// * [`GameStateReadError::DegenerateRange`] surfaces when
    ///   `low.idx >= high.idx`, which would also be rejected by
    ///   the observer's `mark_state_known` API.
    pub fn read_and_validate(
        &self,
        game_id: u128,
        expected_deployment_id: [u8; 32],
    ) -> Result<GameState, GameStateReadError> {
        let calldata = encode_games_calldata(game_id);
        let calldata_hex = format!("0x{}", hex::encode(calldata));
        let params = json!([
            {
                "to": self.game_contract_hex,
                "data": calldata_hex,
            },
            "latest"
        ]);
        let response = self
            .rpc
            .rpc("eth_call", params)
            .map_err(|e| GameStateReadError::RpcTransport(e.to_string()))?;
        let hex_str = match response {
            Value::String(s) => s,
            other => {
                return Err(GameStateReadError::Malformed(format!(
                    "expected string response, got: {other}"
                )))
            }
        };
        let bytes = decode_hex_response(&hex_str)?;
        let (state, sequencer_addr, challenger_addr) = decode_game_state_with_addresses(&bytes)?;

        if state.deployment_id != expected_deployment_id {
            return Err(GameStateReadError::DeploymentIdMismatch {
                contract_hex: hex::encode(state.deployment_id),
                observer_hex: hex::encode(expected_deployment_id),
            });
        }
        if state.range.low.idx >= state.range.high.idx {
            return Err(GameStateReadError::DegenerateRange {
                low_idx: state.range.low.idx,
                high_idx: state.range.high.idx,
            });
        }
        // Audit-pass-4-round-3 fix: enforce Solidity-side
        // invariants on the FULL 20-byte L1 address, not on the
        // truncated `ActorId` projection.  An address like
        // `0x1234...0000000000000000` (high bytes non-zero, low 8
        // bytes zero) is a legitimate L1 address but would
        // falsely trigger `ZeroSequencer` under the previous
        // truncated check.  Similarly the collision check now
        // operates on the full address.  Defence-in-depth against
        // a misbehaving RPC.
        if sequencer_addr == [0u8; 20] {
            return Err(GameStateReadError::ZeroSequencer);
        }
        if challenger_addr == [0u8; 20] {
            return Err(GameStateReadError::ZeroChallenger);
        }
        if sequencer_addr == challenger_addr {
            return Err(GameStateReadError::SequencerChallengerCollision(
                state.sequencer,
            ));
        }
        Ok(state)
    }
}

/// Encode the `games(uint256)` calldata: 4-byte selector +
/// 32-byte big-endian gameId.
#[must_use]
pub fn encode_games_calldata(game_id: u128) -> Vec<u8> {
    let mut out = Vec::with_capacity(36);
    out.extend_from_slice(&GAMES_SELECTOR);
    // u128 left-padded into 32 bytes BE.
    out.extend_from_slice(&[0u8; 16]);
    out.extend_from_slice(&game_id.to_be_bytes());
    out
}

/// Compute `keccak256(signature)[..4]`.  Pure helper used by the
/// build-time selector pin.
#[must_use]
pub fn compute_selector(signature: &str) -> [u8; 4] {
    let mut hasher = Keccak256::new();
    hasher.update(signature.as_bytes());
    let digest = hasher.finalize();
    let mut out = [0u8; 4];
    out.copy_from_slice(&digest[..4]);
    out
}

fn decode_hex_response(hex_str: &str) -> Result<Vec<u8>, GameStateReadError> {
    let trimmed = hex_str.strip_prefix("0x").unwrap_or(hex_str);
    // Audit-pass-4 fix: upfront length cap (per `eth_call`'s known
    // 18-slot response shape) short-circuits oversize allocations
    // before `hex::decode` allocates a multi-MiB buffer against a
    // hostile RPC.
    if trimmed.len() > GAMES_RESPONSE_BYTES * 2 {
        return Err(GameStateReadError::WrongLength {
            expected: GAMES_RESPONSE_BYTES,
            actual: trimmed.len() / 2,
        });
    }
    if trimmed.len() % 2 != 0 {
        return Err(GameStateReadError::Malformed(format!(
            "odd-length hex string: {}",
            trimmed.len()
        )));
    }
    hex::decode(trimmed).map_err(|e| GameStateReadError::Malformed(e.to_string()))
}

/// Decode a `GAMES_RESPONSE_BYTES`-long ABI-encoded `games(uint256)`
/// response into a `GameState`.
///
/// # Errors
///
/// See [`GameStateReadError`].
///
/// # Panics
///
/// Cannot panic in practice — every `try_into()` is on a slice
/// whose length is structurally guaranteed by the per-slot
/// indexing arithmetic.  The `debug_assert!` checks in the
/// `read_*_from_slot` helpers add a defensive layer in debug
/// builds.
pub fn decode_game_state(bytes: &[u8]) -> Result<GameState, GameStateReadError> {
    decode_game_state_with_addresses(bytes).map(|(gs, _, _)| gs)
}

/// Decode the `eth_call` response into a [`GameState`] PLUS the
/// full 20-byte sequencer and challenger L1 addresses.  The
/// addresses are NOT carried in `GameState` (which uses the
/// truncated `ActorId` projection); this entry point exposes
/// them so callers can perform invariant checks on the full
/// address before projection.  Audit-pass-4-round-3 fix for
/// the address-truncation bug in the previous `read_and_validate`.
///
/// # Errors
///
/// See [`GameStateReadError`].
///
/// # Panics
///
/// Cannot panic in practice — see [`decode_game_state`].
pub fn decode_game_state_with_addresses(
    bytes: &[u8],
) -> Result<(GameState, [u8; 20], [u8; 20]), GameStateReadError> {
    if bytes.len() != GAMES_RESPONSE_BYTES {
        return Err(GameStateReadError::WrongLength {
            expected: GAMES_RESPONSE_BYTES,
            actual: bytes.len(),
        });
    }
    // Helper: extract slot i.
    let slot = |i: usize| -> &[u8] { &bytes[i * 32..(i + 1) * 32] };

    let sequencer = read_address_as_actor_id(slot(0));
    let challenger = read_address_as_actor_id(slot(1));
    let low_idx = read_u64_from_slot(slot(2));
    let low_commit: [u8; 32] = slot(3).try_into().unwrap();
    let high_idx = read_u64_from_slot(slot(4));
    let high_commit: [u8; 32] = slot(5).try_into().unwrap();
    let has_pending =
        read_strict_bool_from_slot(slot(6)).map_err(GameStateReadError::InvalidBool)?;
    let pending_idx = read_u64_from_slot(slot(7));
    let pending_commit: [u8; 32] = slot(8).try_into().unwrap();
    let pending_midpoint = if has_pending {
        Some(Claim {
            idx: pending_idx,
            commit: pending_commit,
        })
    } else {
        None
    };
    let depth_u64 = read_u64_from_slot(slot(9));
    // Audit-pass-4 fix: the contract enforces depth <=
    // MAX_BISECTION_DEPTH = 64, so a u64 over u32::MAX is
    // structurally impossible under honest L1 state.  Reject
    // loudly rather than silently clamp.
    let depth =
        u32::try_from(depth_u64).map_err(|_| GameStateReadError::DepthOutOfRange(depth_u64))?;
    // Audit-pass-4 fix: validate slot 10's full layout (must be
    // 31 zero bytes + a turn byte in {0, 1}).  A non-canonical
    // encoding may indicate a misbehaving RPC.
    if slot(10)[..31].iter().any(|b| *b != 0) {
        return Err(GameStateReadError::InvalidTurn(slot(10)[31]));
    }
    let turn_byte = slot(10)[31];
    let turn = match turn_byte {
        0 => TurnSide::Sequencer,
        1 => TurnSide::Challenger,
        other => return Err(GameStateReadError::InvalidTurn(other)),
    };
    let _turn_deadline = read_u64_from_slot(slot(11));
    let sequencer_bond = read_u128_from_slot(slot(12));
    let challenger_bond = read_u128_from_slot(slot(13));
    // Audit-pass-4 fix: validate slot 14's full layout.
    if slot(14)[..31].iter().any(|b| *b != 0) {
        return Err(GameStateReadError::InvalidStatus(slot(14)[31]));
    }
    let status_byte = slot(14)[31];
    let status = match status_byte {
        0 => GameStatus::InProgress,
        1 => GameStatus::SequencerWon,
        2 => GameStatus::ChallengerWon,
        3 => GameStatus::TimedOutSequencer,
        4 => GameStatus::TimedOutChallenger,
        other => return Err(GameStateReadError::InvalidStatus(other)),
    };
    let deployment_id: [u8; 32] = slot(15).try_into().unwrap();
    let _last_step_block = read_u64_from_slot(slot(16));
    let _disputed_log_index = read_u64_from_slot(slot(17));

    // Extract full 20-byte L1 addresses for callers that need
    // to perform invariant checks (zero-address, collision)
    // BEFORE the truncating projection to `ActorId`.
    let sequencer_addr = read_full_address_from_slot(slot(0));
    let challenger_addr = read_full_address_from_slot(slot(1));

    Ok((
        GameState {
            sequencer,
            challenger,
            range: DisputedRange {
                low: Claim {
                    idx: low_idx,
                    commit: low_commit,
                },
                high: Claim {
                    idx: high_idx,
                    commit: high_commit,
                },
            },
            pending_midpoint,
            depth,
            turn,
            sequencer_bond,
            challenger_bond,
            status,
            deployment_id,
        },
        sequencer_addr,
        challenger_addr,
    ))
}

/// Read the last 8 bytes of a 32-byte ABI slot as a big-endian u64.
fn read_u64_from_slot(slot: &[u8]) -> u64 {
    debug_assert_eq!(slot.len(), 32);
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&slot[24..32]);
    u64::from_be_bytes(buf)
}

/// Read the last 16 bytes of a 32-byte ABI slot as a big-endian u128.
fn read_u128_from_slot(slot: &[u8]) -> u128 {
    debug_assert_eq!(slot.len(), 32);
    let mut buf = [0u8; 16];
    buf.copy_from_slice(&slot[16..32]);
    u128::from_be_bytes(buf)
}

/// Project a 20-byte L1 address to a u64 `ActorId` via the low
/// 8 bytes.  This matches the observer's existing convention for
/// mapping L1 EOAs to kernel actor IDs.  Production deployments
/// with multi-actor binding via the address book may need a
/// different projection; for the observer's purposes (identity
/// for turn-tracking only), the low-8 projection suffices.
fn read_address_as_actor_id(slot: &[u8]) -> u64 {
    debug_assert_eq!(slot.len(), 32);
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&slot[24..32]);
    u64::from_be_bytes(buf)
}

/// Read the FULL 20-byte L1 address from a 32-byte ABI slot.
/// Addresses are right-aligned in the slot (slot[12..32]).
/// Used for invariant checks that must operate on the full
/// address, not the truncated `ActorId` projection (audit-
/// pass-4-round-3 fix: the zero-address and sequencer ==
/// challenger collision checks were operating on the projection
/// and could miss or falsely flag legitimate L1 addresses).
fn read_full_address_from_slot(slot: &[u8]) -> [u8; 20] {
    debug_assert_eq!(slot.len(), 32);
    let mut out = [0u8; 20];
    out.copy_from_slice(&slot[12..32]);
    out
}

/// Read a strict Solidity bool from a 32-byte ABI slot.  Returns
/// `Ok(true)` for `0x000…001`, `Ok(false)` for `0x000…000`, and
/// `Err(byte_seen)` for any non-canonical encoding.  Solidity's
/// `solc` only ever emits 0 or 1; a non-canonical encoding
/// (high bytes nonzero, or `slot[31]` outside `{0, 1}`) indicates
/// either a malicious RPC, a buggy contract upgrade emitting raw
/// assembly bools, or a transport-layer corruption.  Returning a
/// typed error closes the audit-pass-4 cross-stack-drift gap.
fn read_strict_bool_from_slot(slot: &[u8]) -> Result<bool, u8> {
    debug_assert_eq!(slot.len(), 32);
    // Every byte except the last MUST be zero (canonical
    // left-padded Solidity bool).
    if slot[..31].iter().any(|b| *b != 0) {
        return Err(slot[31]);
    }
    match slot[31] {
        0 => Ok(false),
        1 => Ok(true),
        other => Err(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selector_matches_solidity_inspector_output() {
        // `forge inspect CanonFaultProofGame methods` reports
        // `games(uint256) = 0x117a5b90`.  Verify our constant
        // matches the keccak256 derivation.
        let computed = compute_selector("games(uint256)");
        assert_eq!(computed, GAMES_SELECTOR);
    }

    #[test]
    fn calldata_layout_is_36_bytes() {
        let cd = encode_games_calldata(42);
        assert_eq!(cd.len(), 36);
        assert_eq!(&cd[..4], &GAMES_SELECTOR);
        let mut expected_tail = [0u8; 32];
        expected_tail[16..].copy_from_slice(&42u128.to_be_bytes());
        assert_eq!(&cd[4..], &expected_tail);
    }

    #[test]
    fn calldata_preserves_full_u128_range() {
        let cd = encode_games_calldata(u128::MAX);
        assert_eq!(cd.len(), 36);
        assert_eq!(&cd[4..20], &[0u8; 16]);
        assert_eq!(&cd[20..], &u128::MAX.to_be_bytes());
    }

    fn synth_response_bytes() -> Vec<u8> {
        let mut out = vec![0u8; GAMES_RESPONSE_BYTES];
        // Slot 0: sequencer address (low 8 bytes = 0x0001020304050607).
        out[24..32].copy_from_slice(&0x0001_0203_0405_0607u64.to_be_bytes());
        // Slot 1: challenger address.
        out[32 + 24..32 + 32].copy_from_slice(&0x1011_1213_1415_1617u64.to_be_bytes());
        // Slot 2: low.idx = 10.
        out[2 * 32 + 24..2 * 32 + 32].copy_from_slice(&10u64.to_be_bytes());
        // Slot 3: low.commit.
        out[3 * 32..4 * 32].copy_from_slice(&[0x42u8; 32]);
        // Slot 4: high.idx = 100.
        out[4 * 32 + 24..4 * 32 + 32].copy_from_slice(&100u64.to_be_bytes());
        // Slot 5: high.commit.
        out[5 * 32..6 * 32].copy_from_slice(&[0x43u8; 32]);
        // Slot 6: hasPendingMidpoint = true.
        out[6 * 32 + 31] = 1;
        // Slot 7: pendingMidpoint.idx = 50.
        out[7 * 32 + 24..7 * 32 + 32].copy_from_slice(&50u64.to_be_bytes());
        // Slot 8: pendingMidpoint.commit.
        out[8 * 32..9 * 32].copy_from_slice(&[0x44u8; 32]);
        // Slot 9: depth = 5.
        out[9 * 32 + 24..9 * 32 + 32].copy_from_slice(&5u64.to_be_bytes());
        // Slot 10: turn = 1 (Challenger).
        out[10 * 32 + 31] = 1;
        // Slot 11: turnDeadline = 12345.
        out[11 * 32 + 24..11 * 32 + 32].copy_from_slice(&12345u64.to_be_bytes());
        // Slot 12: sequencerBond = 1_000_000.
        out[12 * 32 + 16..12 * 32 + 32].copy_from_slice(&1_000_000u128.to_be_bytes());
        // Slot 13: challengerBond = 2_000_000.
        out[13 * 32 + 16..13 * 32 + 32].copy_from_slice(&2_000_000u128.to_be_bytes());
        // Slot 14: status = 0 (InProgress).  Already zero.
        // Slot 15: deploymentId.
        out[15 * 32..16 * 32].copy_from_slice(&[0xABu8; 32]);
        // Slot 16: lastStepBlock = 100_000.
        out[16 * 32 + 24..16 * 32 + 32].copy_from_slice(&100_000u64.to_be_bytes());
        // Slot 17: disputedLogIndex = 75.
        out[17 * 32 + 24..17 * 32 + 32].copy_from_slice(&75u64.to_be_bytes());
        out
    }

    #[test]
    fn decode_game_state_rejects_short_response() {
        let bytes = vec![0u8; 480];
        let err = decode_game_state(&bytes);
        assert!(matches!(
            err,
            Err(GameStateReadError::WrongLength {
                expected: GAMES_RESPONSE_BYTES,
                actual: 480
            })
        ));
    }

    #[test]
    fn decode_game_state_rejects_long_response() {
        let bytes = vec![0u8; GAMES_RESPONSE_BYTES + 32];
        let err = decode_game_state(&bytes);
        assert!(matches!(err, Err(GameStateReadError::WrongLength { .. })));
    }

    #[test]
    fn decode_game_state_decodes_typical_response() {
        let bytes = synth_response_bytes();
        let gs = decode_game_state(&bytes).expect("decode");
        assert_eq!(gs.sequencer, 0x0001_0203_0405_0607);
        assert_eq!(gs.challenger, 0x1011_1213_1415_1617);
        assert_eq!(gs.range.low.idx, 10);
        assert_eq!(gs.range.low.commit, [0x42u8; 32]);
        assert_eq!(gs.range.high.idx, 100);
        assert_eq!(gs.range.high.commit, [0x43u8; 32]);
        assert_eq!(
            gs.pending_midpoint,
            Some(Claim {
                idx: 50,
                commit: [0x44u8; 32]
            })
        );
        assert_eq!(gs.depth, 5);
        assert_eq!(gs.turn, TurnSide::Challenger);
        assert_eq!(gs.sequencer_bond, 1_000_000);
        assert_eq!(gs.challenger_bond, 2_000_000);
        assert_eq!(gs.status, GameStatus::InProgress);
        assert_eq!(gs.deployment_id, [0xABu8; 32]);
    }

    #[test]
    fn decode_game_state_handles_no_pending_midpoint() {
        let mut bytes = synth_response_bytes();
        // Clear hasPendingMidpoint.
        bytes[6 * 32 + 31] = 0;
        let gs = decode_game_state(&bytes).expect("decode");
        assert!(gs.pending_midpoint.is_none());
    }

    #[test]
    fn decode_game_state_rejects_invalid_turn() {
        let mut bytes = synth_response_bytes();
        bytes[10 * 32 + 31] = 2;
        let err = decode_game_state(&bytes);
        assert!(matches!(err, Err(GameStateReadError::InvalidTurn(2))));
    }

    #[test]
    fn decode_game_state_rejects_invalid_status() {
        let mut bytes = synth_response_bytes();
        bytes[14 * 32 + 31] = 5;
        let err = decode_game_state(&bytes);
        assert!(matches!(err, Err(GameStateReadError::InvalidStatus(5))));
    }

    #[test]
    fn decode_game_state_decodes_every_valid_status() {
        for s in 0u8..=4u8 {
            let mut bytes = synth_response_bytes();
            bytes[14 * 32 + 31] = s;
            let gs = decode_game_state(&bytes).expect("decode");
            match s {
                0 => assert_eq!(gs.status, GameStatus::InProgress),
                1 => assert_eq!(gs.status, GameStatus::SequencerWon),
                2 => assert_eq!(gs.status, GameStatus::ChallengerWon),
                3 => assert_eq!(gs.status, GameStatus::TimedOutSequencer),
                4 => assert_eq!(gs.status, GameStatus::TimedOutChallenger),
                _ => unreachable!(),
            }
        }
    }

    #[test]
    fn decode_hex_response_strips_prefix() {
        let bytes = decode_hex_response("0xdeadbeef").unwrap();
        assert_eq!(bytes, vec![0xDE, 0xAD, 0xBE, 0xEF]);
        let bytes2 = decode_hex_response("deadbeef").unwrap();
        assert_eq!(bytes2, vec![0xDE, 0xAD, 0xBE, 0xEF]);
    }

    #[test]
    fn decode_hex_response_rejects_odd_length() {
        let err = decode_hex_response("0xa");
        assert!(matches!(err, Err(GameStateReadError::Malformed(_))));
    }

    #[test]
    fn read_helpers_extract_expected_widths() {
        let mut slot = [0u8; 32];
        slot[24..32].copy_from_slice(&0xDEAD_BEEF_DEAD_BEEFu64.to_be_bytes());
        assert_eq!(read_u64_from_slot(&slot), 0xDEAD_BEEF_DEAD_BEEF);
        slot[16..32].copy_from_slice(&0xCAFE_BABE_DEAD_BEEF_CAFE_BABE_DEAD_BEEFu128.to_be_bytes());
        assert_eq!(
            read_u128_from_slot(&slot),
            0xCAFE_BABE_DEAD_BEEF_CAFE_BABE_DEAD_BEEFu128
        );
        let mut bslot = [0u8; 32];
        bslot[31] = 0;
        assert_eq!(read_strict_bool_from_slot(&bslot), Ok(false));
        bslot[31] = 1;
        assert_eq!(read_strict_bool_from_slot(&bslot), Ok(true));
        // Audit-pass-4 strict-bool fix: non-canonical bytes now
        // return Err instead of lenient `true`.
        bslot[31] = 42;
        assert_eq!(read_strict_bool_from_slot(&bslot), Err(42));
        // Non-zero high byte → Err even if slot[31] is canonical.
        let mut nb = [0u8; 32];
        nb[0] = 1;
        nb[31] = 1;
        assert_eq!(read_strict_bool_from_slot(&nb), Err(1));
    }

    /// Audit-pass-4 regression: pin every newly-introduced error
    /// variant in `decode_game_state`.
    #[test]
    fn decode_game_state_rejects_non_canonical_bool() {
        let mut bytes = synth_response_bytes();
        // Slot 6 byte 0 is non-zero → InvalidBool.
        bytes[6 * 32] = 0x01;
        let err = decode_game_state(&bytes);
        assert!(matches!(err, Err(GameStateReadError::InvalidBool(_))));
    }

    #[test]
    fn decode_game_state_rejects_non_canonical_turn() {
        let mut bytes = synth_response_bytes();
        // Slot 10 byte 0 is non-zero → InvalidTurn.
        bytes[10 * 32] = 0x01;
        let err = decode_game_state(&bytes);
        assert!(matches!(err, Err(GameStateReadError::InvalidTurn(_))));
    }

    #[test]
    fn decode_game_state_rejects_non_canonical_status() {
        let mut bytes = synth_response_bytes();
        // Slot 14 byte 0 is non-zero → InvalidStatus.
        bytes[14 * 32] = 0x01;
        let err = decode_game_state(&bytes);
        assert!(matches!(err, Err(GameStateReadError::InvalidStatus(_))));
    }

    #[test]
    fn decode_game_state_rejects_overflowing_depth() {
        let mut bytes = synth_response_bytes();
        // Slot 9: write a u64 over u32::MAX in the low 8 bytes.
        bytes[9 * 32 + 24..9 * 32 + 32].copy_from_slice(&(u64::from(u32::MAX) + 1).to_be_bytes());
        let err = decode_game_state(&bytes);
        assert!(matches!(err, Err(GameStateReadError::DepthOutOfRange(_))));
    }

    #[test]
    fn decode_hex_response_rejects_oversize_string() {
        // (GAMES_RESPONSE_BYTES * 2) + 2 chars → over the cap.
        let oversize = "0x".to_string() + &"a".repeat(GAMES_RESPONSE_BYTES * 2 + 2);
        let err = decode_hex_response(&oversize);
        assert!(matches!(err, Err(GameStateReadError::WrongLength { .. })));
    }

    #[test]
    fn read_address_uses_low_8_bytes() {
        let mut slot = [0u8; 32];
        // Right-aligned 20-byte address; only low 8 bytes are read.
        slot[24..32].copy_from_slice(&0xAA_BB_CC_DD_EE_FF_01_02u64.to_be_bytes());
        assert_eq!(read_address_as_actor_id(&slot), 0xAA_BB_CC_DD_EE_FF_01_02);
    }

    #[test]
    fn games_response_bytes_constant_is_576() {
        assert_eq!(GAMES_RESPONSE_BYTES, 576);
        assert_eq!(GAMES_RESPONSE_SLOTS, 18);
    }

    /// Audit-pass-4-round-4 MEDIUM regression: pin the full-
    /// address extraction.  An address with high bytes set
    /// but low-8 bytes zero is a legitimate L1 address; the
    /// round-3 fix must read the FULL 20 bytes, not just the
    /// low-8 `ActorId` projection.
    #[test]
    fn read_full_address_extracts_all_20_bytes() {
        let mut slot = [0u8; 32];
        // L1 address slot layout: 12 zero bytes (left padding) +
        // 20 address bytes.  Use a recognisable pattern.
        slot[12..32].copy_from_slice(&[
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE,
            0xFF, 0x01, 0x02, 0x03, 0x04, 0x05,
        ]);
        let addr = read_full_address_from_slot(&slot);
        assert_eq!(
            addr,
            [
                0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE,
                0xFF, 0x01, 0x02, 0x03, 0x04, 0x05,
            ]
        );
    }

    /// Audit-pass-4-round-4 MEDIUM regression: an L1 address
    /// like `0x11223344...00000000` (high bytes non-zero, low-8
    /// bytes zero) is LEGITIMATE.  Under the round-3 fix, this
    /// must NOT trigger `ZeroSequencer` / `ZeroChallenger`
    /// (which would happen under the old low-8 projection check).
    #[test]
    fn decode_game_state_with_addresses_accepts_low_8_zero_address() {
        let mut bytes = synth_response_bytes();
        // Slot 0 (sequencer): set high bytes (slot[12..24]) to
        // non-zero, low-8 (slot[24..32]) to zero.
        for b in &mut bytes[12..24] {
            *b = 0xAB;
        }
        for b in &mut bytes[24..32] {
            *b = 0;
        }
        // The decoded sequencer ActorId is 0 (low-8 projection),
        // but the FULL address [0xAB; 12] + [0; 8] is non-zero.
        let (gs, seq_addr, _ch_addr) = decode_game_state_with_addresses(&bytes).unwrap();
        assert_eq!(gs.sequencer, 0); // low-8 projection
        assert_ne!(seq_addr, [0u8; 20]); // full address is non-zero
                                         // Verify the high bytes are preserved.
        for b in &seq_addr[0..12] {
            assert_eq!(*b, 0xAB);
        }
    }
}
