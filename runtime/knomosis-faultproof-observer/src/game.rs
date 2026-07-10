// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Rust port of `LegalKernel.FaultProof.Game`.
//!
//! ## Purpose
//!
//! This module mirrors the Lean reference state machine
//! (`LegalKernel/FaultProof/Game.lean`) byte-for-byte: identical
//! data shapes, identical transition function, identical error
//! taxonomy.  The off-chain observer uses this state machine as
//! its in-memory model of every active L1 game.
//!
//! ## Cross-stack contract
//!
//! For every legal `(GameState, GameTransition)` pair, the Rust
//! [`apply_transition`] MUST produce a result byte-equivalent to
//! the Lean reference `applyTransition`.  This is the load-bearing
//! correctness property of the observer; the property test in
//! `tests/property.rs` exercises it on random traces.
//!
//! ## Why we re-implement instead of subprocessing knomosis
//!
//! Two reasons:
//!
//!   1. The state machine is small (~100 lines of pure logic) and
//!      every transition is a simple case-split on the transition
//!      constructor.  Re-implementing in Rust gives the observer
//!      a stable, fast in-memory model without paying per-call
//!      subprocess overhead.
//!   2. The Rust port is verified against the Lean reference at
//!      property-test time.  Once the cross-stack corpus passes,
//!      Rust and Lean are operationally interchangeable for this
//!      state machine.
//!
//! ## Type mapping (Lean → Rust)
//!
//! | Lean                  | Rust                                      |
//! |-----------------------|-------------------------------------------|
//! | `LogIndex` (`Nat`)    | `u64` (matches Solidity's `uint64`)       |
//! | `StateCommit`         | `[u8; 32]` (matches `bytes32`)            |
//! | `ActorId` (`Nat`)     | `u64`                                     |
//! | `Claim`               | [`Claim`]                                 |
//! | `DisputedRange`       | [`DisputedRange`]                         |
//! | `TurnSide`            | [`TurnSide`]                              |
//! | `GameStatus`          | [`GameStatus`]                            |
//! | `GameState`           | [`GameState`]                             |
//! | `GameTransition`      | [`GameTransition`]                        |
//! | `GameError`           | [`GameError`]                             |
//!
//! ## Non-goals
//!
//! The Rust port omits the Lean-side `KernelStep` evaluation
//! inside `terminateOnSingleStep`: the L1 step VM is the
//! authoritative evaluator on-chain, and the off-chain observer
//! merely chooses *which* `terminateOnSingleStep` to submit.  The
//! state-machine model marks the game `inProgress` until the L1
//! contract emits the `FaultProofGameSettled` event, at which
//! point the observer updates the cached state from the on-chain
//! status.  See [`apply_settlement`] for the post-settlement
//! transition.

use serde::{Deserialize, Serialize};

/// Maximum bisection depth, mirroring Lean's
/// `LegalKernel.FaultProof.Game.MAX_BISECTION_DEPTH`.  Caps the
/// worst-case L1 game length at `2 × 64 + ε` transactions per
/// dispute.  Covers log lengths up to `2^64`, which is
/// essentially unbounded for any realistic Knomosis deployment.
pub const MAX_BISECTION_DEPTH: u32 = 64;

/// 64-bit log index — abbreviation for Lean's
/// `Disputes.LogIndex`.
pub type LogIndex = u64;

/// 32-byte state-root commit — abbreviation for Lean's
/// `Disputes.StateCommit` (`ByteArray`).  Fixed at 32 bytes here
/// because the L1 contract types it as `bytes32`.
pub type StateCommit = [u8; 32];

/// 64-bit actor id — abbreviation for Lean's `Authority.ActorId`.
pub type ActorId = u64;

/// A state-root assertion: at log index `idx`, the state root is
/// `commit`.  Mirrors Lean's `LegalKernel.FaultProof.Game.Claim`.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct Claim {
    /// The log index this claim covers.
    pub idx: LogIndex,
    /// The claimed state-root commit at `idx`.
    pub commit: StateCommit,
}

/// The disputed range at any point in the game.  Mirrors Lean's
/// `LegalKernel.FaultProof.Game.DisputedRange`.
///
/// Both parties have agreed on the commits at `low` and `high`
/// (the disagreement was already at the previous level); they
/// disagree about the commit at the midpoint.
///
/// `low.idx < high.idx`; equality means the bisection has narrowed
/// to a single step.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct DisputedRange {
    /// The lower bound (both parties agree on this commit).
    pub low: Claim,
    /// The upper bound (parties may disagree on this commit).
    pub high: Claim,
}

impl DisputedRange {
    /// Canonical midpoint of the range.  Floor-divides to the
    /// lower half on odd-length ranges, mirroring Solidity's
    /// `(low.idx + high.idx) / 2` and Lean's
    /// `DisputedRange.midpointIdx`.
    #[must_use]
    pub fn midpoint_idx(&self) -> LogIndex {
        // Safety: `low.idx` and `high.idx` are both `u64`; their
        // sum may overflow.  Use `wrapping_add` semantics?  No —
        // `u128` upcast avoids overflow entirely and matches
        // Solidity's behaviour on the EVM (which would overflow
        // and revert).  The L1 contract checks `low.idx < high.idx`
        // upfront, so a legitimate range can never have a midpoint
        // outside `[0, u64::MAX]`.
        let low = u128::from(self.low.idx);
        let high = u128::from(self.high.idx);
        // Floor-divide.  Cast back to u64; safe because
        // (low + high) / 2 <= max(low, high) <= u64::MAX.
        let mid = u128::midpoint(low, high);
        // Defensive: clamp to u64 range.  Mathematically
        // unnecessary but guards against a future change to the
        // bound.
        u64::try_from(mid).unwrap_or(u64::MAX)
    }

    /// True iff the range is single-step (`high.idx = low.idx + 1`).
    /// When this holds, no further bisection is possible; the
    /// responding party must call `terminateOnSingleStep`.  Mirrors
    /// Lean's `DisputedRange.isSingleStep`.
    #[must_use]
    pub fn is_single_step(&self) -> bool {
        self.high.idx == self.low.idx.saturating_add(1)
    }

    /// The width of the range as a `u64` saturating difference.
    /// Used by the bisection convergence assertion in tests.
    #[must_use]
    pub fn width(&self) -> u64 {
        self.high.idx.saturating_sub(self.low.idx)
    }
}

/// Whose turn it is to act in the current round.  Mirrors Lean's
/// `LegalKernel.FaultProof.Game.TurnSide`.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum TurnSide {
    /// The sequencer's turn.
    Sequencer,
    /// The challenger's turn.
    Challenger,
}

impl TurnSide {
    /// The next turn after the current one.  Mirrors Lean's
    /// `TurnSide.flip`.
    #[must_use]
    pub const fn flip(self) -> Self {
        match self {
            Self::Sequencer => Self::Challenger,
            Self::Challenger => Self::Sequencer,
        }
    }
}

/// The terminal status of a fault-proof game.  Mirrors Lean's
/// `LegalKernel.FaultProof.Game.GameStatus`.
#[allow(clippy::module_name_repetitions)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum GameStatus {
    /// The game is still in progress.
    InProgress,
    /// The challenger lost; bonds redistribute to the sequencer.
    SequencerWon,
    /// The sequencer lost; bonds redistribute to the challenger.
    ChallengerWon,
    /// The sequencer timed out (was responsible and missed the
    /// deadline).
    TimedOutSequencer,
    /// The challenger timed out (was responsible and missed the
    /// deadline).
    TimedOutChallenger,
}

impl GameStatus {
    /// True iff the game is still actively being played.
    #[must_use]
    pub const fn is_in_progress(self) -> bool {
        matches!(self, Self::InProgress)
    }

    /// True iff the game is terminal (won, lost, or timed out).
    #[must_use]
    pub const fn is_terminal(self) -> bool {
        !self.is_in_progress()
    }
}

/// The bisection game's state.  Mirrors Lean's
/// `LegalKernel.FaultProof.Game.GameState`.
#[allow(clippy::module_name_repetitions)]
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct GameState {
    /// The sequencer's identity.
    pub sequencer: ActorId,
    /// The challenger's identity.
    pub challenger: ActorId,
    /// The current disputed range.
    pub range: DisputedRange,
    /// The midpoint commit submitted in the current round (if
    /// any).  When `None`, the responding party owes a midpoint
    /// submission; when `Some(_)`, the opposing party owes an
    /// accept/reject response.
    pub pending_midpoint: Option<Claim>,
    /// The bisection depth so far.  Capped at
    /// `MAX_BISECTION_DEPTH = 64` by the legality predicate.
    pub depth: u32,
    /// Whose turn it is.
    pub turn: TurnSide,
    /// The sequencer's bond (in deployment-supplied units; wei on
    /// L1).  Slashed in full to the challenger if the sequencer
    /// loses.  Tracked as `u128` to match the Solidity contract's
    /// `uint128` field.
    pub sequencer_bond: u128,
    /// The challenger's bond.  Slashed in full to the sequencer
    /// if the challenger loses.
    pub challenger_bond: u128,
    /// Game status.
    pub status: GameStatus,
    /// The deployment-id binding the game to a specific Knomosis
    /// deployment.  Prevents cross-deployment replay of game
    /// transcripts.  Stored as a 32-byte hash to match the
    /// Solidity contract's `bytes32 deploymentId`.
    pub deployment_id: [u8; 32],
}

/// The legal transitions from one game state to the next.  Mirrors
/// Lean's `LegalKernel.FaultProof.Game.GameTransition`.
#[allow(clippy::module_name_repetitions)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GameTransition {
    /// The party whose turn it is submits a midpoint commit.
    SubmitMidpoint(Claim),
    /// The opposing party agrees with the pending midpoint; range
    /// narrows to `[mid.idx, high.idx]`.
    RespondAgree,
    /// The opposing party disagrees; range narrows to
    /// `[low.idx, mid.idx]`.
    RespondDisagree,
    /// Single-step termination.  Carries the *claimed* post-commit;
    /// the L1 step VM determines correctness.  The Rust port does
    /// NOT evaluate the step itself — the observer's role is to
    /// SELECT which `terminateOnSingleStep` to submit; the L1
    /// contract is the authoritative evaluator.  After submission
    /// the observer observes the resulting `FaultProofGameSettled`
    /// event and applies it via [`apply_settlement`].
    TerminateOnSingleStep {
        /// The claimed post-commit (what we believe the L1 step VM
        /// will compute).
        claimed_post_commit: StateCommit,
    },
    /// A party times out (`BISECTION_RESPONSE_TIMEOUT` exceeded).
    /// The loser is *derived* from `gs.turn` at apply-time: the
    /// party whose turn it is when the deadline elapses is the one
    /// who failed to respond.  Mirrors Solidity's `claimTimeout`
    /// semantics.
    TimeoutLoss,
}

/// Errors `apply_transition` can produce.  Each variant maps to a
/// precise revert reason in the L1 game contract.  Mirrors Lean's
/// `LegalKernel.FaultProof.Game.GameError`.
///
/// The Lean inductive includes two additional constructors —
/// `wrongTurn` and `terminationDuringBisection` — that Lean's
/// `applyTransition` never actually emits (no code path returns
/// them).  We mirror them here as `WrongTurn` /
/// `TerminationDuringBisection` for byte-equivalence with the
/// Lean reference's `Repr` instance, even though the Rust port
/// also never emits them.  An external caller round-tripping a
/// Lean `Except GameError` payload that carried one of these
/// tags can decode it as the matching Rust variant.
#[allow(clippy::module_name_repetitions)]
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum GameError {
    /// The game has already ended.
    #[error("game has already ended")]
    GameAlreadyEnded,
    /// Wrong turn (the caller is not the responding party).
    /// Present for parity with the Lean reference; the Rust port
    /// does not emit this variant directly (the L1 contract is
    /// the authoritative turn-validator; off-chain we trust the
    /// caller passed `me` correctly).
    #[error("wrong turn")]
    WrongTurn,
    /// The submitted midpoint is outside the disputed range.
    #[error("midpoint out of range")]
    MidpointOutOfRange,
    /// A midpoint is already pending; cannot submit another until
    /// the opposing party responds.
    #[error("midpoint already pending; cannot submit another")]
    MidpointDuringResponse,
    /// No midpoint pending; cannot accept/reject.
    #[error("no midpoint pending; cannot respond")]
    ResponseDuringSubmit,
    /// The bisection depth cap has been exceeded.
    #[error("bisection depth cap (64) exceeded")]
    BisectionDepthExceeded,
    /// The range is not single-step yet; bisect more first.
    #[error("range is not single-step; bisect more first")]
    RangeNotSingleStep,
    /// Termination attempted during an active bisection.  Present
    /// for parity with the Lean reference; the Rust port never
    /// emits this variant directly (the single-step check in
    /// `apply_terminate_on_single_step` returns `RangeNotSingleStep`
    /// for the same observable failure).
    #[error("termination attempted during active bisection")]
    TerminationDuringBisection,
    /// A settlement transition was applied with `InProgress` as
    /// the requested final status.  Distinct from
    /// `GameAlreadyEnded` (which surfaces when the game is
    /// already terminal).  Diagnostic-only.
    #[error("invalid settlement: cannot finalise with InProgress status")]
    InvalidSettlement,
}

/// Apply a transition.  Returns the new game state if the
/// transition is legal, an error otherwise.  Total function;
/// deterministic.  Mirrors Lean's `applyTransition` byte-for-byte
/// (modulo the `TerminateOnSingleStep` evaluation, see module
/// docstring's "Non-goals").
///
/// # Errors
///
/// See [`GameError`].
pub fn apply_transition(gs: &GameState, t: GameTransition) -> Result<GameState, GameError> {
    match t {
        GameTransition::SubmitMidpoint(mp) => apply_submit_midpoint(gs, mp),
        GameTransition::RespondAgree => apply_respond(gs, /* agree = */ true),
        GameTransition::RespondDisagree => apply_respond(gs, /* agree = */ false),
        GameTransition::TerminateOnSingleStep { .. } => apply_terminate_on_single_step(gs),
        GameTransition::TimeoutLoss => apply_timeout(gs),
    }
}

/// Implementation of [`apply_transition`] for `SubmitMidpoint`.
fn apply_submit_midpoint(gs: &GameState, mp: Claim) -> Result<GameState, GameError> {
    if !gs.status.is_in_progress() {
        return Err(GameError::GameAlreadyEnded);
    }
    if gs.pending_midpoint.is_some() {
        return Err(GameError::MidpointDuringResponse);
    }
    if gs.depth >= MAX_BISECTION_DEPTH {
        return Err(GameError::BisectionDepthExceeded);
    }
    if mp.idx <= gs.range.low.idx || gs.range.high.idx <= mp.idx {
        return Err(GameError::MidpointOutOfRange);
    }
    Ok(GameState {
        pending_midpoint: Some(mp),
        turn: gs.turn.flip(),
        ..gs.clone()
    })
}

/// Implementation of [`apply_transition`] for `RespondAgree` /
/// `RespondDisagree`.  Mirrors Lean's two response arms exactly:
/// the depth is incremented post-response and the cap is checked
/// pre-response (Solidity's pattern).
fn apply_respond(gs: &GameState, agree: bool) -> Result<GameState, GameError> {
    if !gs.status.is_in_progress() {
        return Err(GameError::GameAlreadyEnded);
    }
    if gs.depth >= MAX_BISECTION_DEPTH {
        return Err(GameError::BisectionDepthExceeded);
    }
    let mp = gs.pending_midpoint.ok_or(GameError::ResponseDuringSubmit)?;
    let new_range = if agree {
        // Range narrows to [mid.idx, high.idx].
        DisputedRange {
            low: mp,
            high: gs.range.high,
        }
    } else {
        // Range narrows to [low.idx, mid.idx].
        DisputedRange {
            low: gs.range.low,
            high: mp,
        }
    };
    Ok(GameState {
        range: new_range,
        pending_midpoint: None,
        depth: gs.depth.saturating_add(1),
        turn: gs.turn.flip(),
        ..gs.clone()
    })
}

/// Implementation of [`apply_transition`] for
/// `TerminateOnSingleStep`.  In the Rust port we DO NOT evaluate
/// the kernel step — the L1 contract is the authoritative
/// evaluator.  The Rust state machine validates only the structural
/// preconditions:
///
///   * Game is still in progress.
///   * Range is single-step.
///
/// On success, the state stays `InProgress`; the observer later
/// observes the L1 settlement event and applies it via
/// [`apply_settlement`].
fn apply_terminate_on_single_step(gs: &GameState) -> Result<GameState, GameError> {
    if !gs.status.is_in_progress() {
        return Err(GameError::GameAlreadyEnded);
    }
    if !gs.range.is_single_step() {
        return Err(GameError::RangeNotSingleStep);
    }
    // The observer's role is to SELECT this transition; the L1
    // contract evaluates it and emits `FaultProofGameSettled`.
    // The Rust state machine leaves the game `InProgress`; the
    // settlement event will update the status via
    // [`apply_settlement`].
    Ok(gs.clone())
}

/// Implementation of [`apply_transition`] for `TimeoutLoss`.  The
/// loser is derived from `gs.turn`: the party whose turn it is
/// when the deadline elapses is the one who failed to respond.
fn apply_timeout(gs: &GameState) -> Result<GameState, GameError> {
    if !gs.status.is_in_progress() {
        return Err(GameError::GameAlreadyEnded);
    }
    let new_status = match gs.turn {
        TurnSide::Sequencer => GameStatus::TimedOutSequencer,
        TurnSide::Challenger => GameStatus::TimedOutChallenger,
    };
    Ok(GameState {
        status: new_status,
        ..gs.clone()
    })
}

/// Apply a settlement transition.  Called by the observer when the
/// L1 contract emits a `FaultProofGameSettled` event.  Updates the
/// in-memory game state to reflect the final on-chain status.
///
/// Unlike [`apply_transition`], this is NOT a Lean-mirrored
/// transition — it's the observer's bookkeeping update for the L1
/// side's authoritative settlement.  Returns an error if the game
/// has already been settled (idempotency violation).
///
/// # Errors
///
/// Returns [`GameError::GameAlreadyEnded`] if the game is already
/// terminal.
pub fn apply_settlement(gs: &GameState, final_status: GameStatus) -> Result<GameState, GameError> {
    if !gs.status.is_in_progress() {
        return Err(GameError::GameAlreadyEnded);
    }
    if final_status.is_in_progress() {
        // Caller passed `InProgress` as the "final" status — a
        // logic error.  Surface as a typed error rather than
        // silently no-op.
        return Err(GameError::InvalidSettlement);
    }
    Ok(GameState {
        status: final_status,
        ..gs.clone()
    })
}

#[cfg(test)]
mod tests {
    use super::{
        apply_settlement, apply_transition, Claim, DisputedRange, GameError, GameState, GameStatus,
        GameTransition, LogIndex, StateCommit, TurnSide, MAX_BISECTION_DEPTH,
    };

    /// Build a deterministic test commit from a single seed byte.
    fn commit(seed: u8) -> StateCommit {
        let mut out = [0u8; 32];
        out[0] = seed;
        out
    }

    /// Build a fresh in-progress game state with the supplied
    /// range and turn.
    fn fresh_game(low_idx: LogIndex, high_idx: LogIndex, turn: TurnSide) -> GameState {
        GameState {
            sequencer: 1,
            challenger: 2,
            range: DisputedRange {
                low: Claim {
                    idx: low_idx,
                    commit: commit(1),
                },
                high: Claim {
                    idx: high_idx,
                    commit: commit(2),
                },
            },
            pending_midpoint: None,
            depth: 0,
            turn,
            sequencer_bond: 1_000,
            challenger_bond: 1_000,
            status: GameStatus::InProgress,
            deployment_id: [0u8; 32],
        }
    }

    /// `MAX_BISECTION_DEPTH` mirrors Lean's value `64`.
    #[test]
    fn max_bisection_depth_is_64() {
        assert_eq!(MAX_BISECTION_DEPTH, 64);
    }

    /// `midpoint_idx` floor-divides to the lower half.
    #[test]
    fn midpoint_floor_div() {
        let r = DisputedRange {
            low: Claim {
                idx: 0,
                commit: commit(1),
            },
            high: Claim {
                idx: 64,
                commit: commit(2),
            },
        };
        assert_eq!(r.midpoint_idx(), 32);
        let r2 = DisputedRange {
            low: Claim {
                idx: 0,
                commit: commit(1),
            },
            high: Claim {
                idx: 7,
                commit: commit(2),
            },
        };
        assert_eq!(r2.midpoint_idx(), 3);
    }

    /// `midpoint_idx` doesn't overflow on extreme indices.
    #[test]
    fn midpoint_no_overflow_on_extreme_indices() {
        let r = DisputedRange {
            low: Claim {
                idx: u64::MAX - 1,
                commit: commit(1),
            },
            high: Claim {
                idx: u64::MAX,
                commit: commit(2),
            },
        };
        // (u64::MAX - 1 + u64::MAX) / 2 = u64::MAX - 1.
        assert_eq!(r.midpoint_idx(), u64::MAX - 1);
    }

    /// `is_single_step` returns true iff high = low + 1.
    #[test]
    fn is_single_step_only_when_adjacent() {
        let r = DisputedRange {
            low: Claim {
                idx: 5,
                commit: commit(1),
            },
            high: Claim {
                idx: 6,
                commit: commit(2),
            },
        };
        assert!(r.is_single_step());
        let r2 = DisputedRange {
            low: Claim {
                idx: 5,
                commit: commit(1),
            },
            high: Claim {
                idx: 7,
                commit: commit(2),
            },
        };
        assert!(!r2.is_single_step());
    }

    /// `is_single_step` doesn't panic at `u64::MAX` low.
    #[test]
    fn is_single_step_saturating_at_max() {
        let r = DisputedRange {
            low: Claim {
                idx: u64::MAX,
                commit: commit(1),
            },
            high: Claim {
                idx: u64::MAX,
                commit: commit(2),
            },
        };
        // low + 1 saturates to u64::MAX, so high (u64::MAX) ==
        // low.saturating_add(1) (u64::MAX) → reports single_step.
        // This is a degenerate range (low == high); not legitimate
        // L1 input.  The saturating behaviour just prevents panic.
        assert!(r.is_single_step());
    }

    /// `width` is `high.idx - low.idx`.
    #[test]
    fn width_is_difference() {
        let r = DisputedRange {
            low: Claim {
                idx: 10,
                commit: commit(1),
            },
            high: Claim {
                idx: 100,
                commit: commit(2),
            },
        };
        assert_eq!(r.width(), 90);
    }

    /// `TurnSide::flip` toggles.
    #[test]
    fn turn_flip_toggles() {
        assert_eq!(TurnSide::Sequencer.flip(), TurnSide::Challenger);
        assert_eq!(TurnSide::Challenger.flip(), TurnSide::Sequencer);
    }

    /// `flip` is involutive.
    #[test]
    fn turn_flip_involution() {
        assert_eq!(TurnSide::Sequencer.flip().flip(), TurnSide::Sequencer);
        assert_eq!(TurnSide::Challenger.flip().flip(), TurnSide::Challenger);
    }

    /// `GameStatus::is_in_progress` / `is_terminal` are
    /// complementary.
    #[test]
    fn status_in_progress_terminal_complementary() {
        for s in [
            GameStatus::InProgress,
            GameStatus::SequencerWon,
            GameStatus::ChallengerWon,
            GameStatus::TimedOutSequencer,
            GameStatus::TimedOutChallenger,
        ] {
            assert_eq!(s.is_in_progress(), !s.is_terminal());
        }
    }

    /// `submitMidpoint` happy path.
    #[test]
    fn submit_midpoint_happy_path() {
        let gs = fresh_game(0, 64, TurnSide::Sequencer);
        let mp = Claim {
            idx: 32,
            commit: commit(99),
        };
        let next = apply_transition(&gs, GameTransition::SubmitMidpoint(mp)).unwrap();
        assert_eq!(next.pending_midpoint, Some(mp));
        assert_eq!(next.turn, TurnSide::Challenger);
        assert_eq!(next.range, gs.range, "range unchanged after submit");
        assert_eq!(next.depth, gs.depth, "depth unchanged after submit");
    }

    /// `submitMidpoint` rejects out-of-range mid.
    #[test]
    fn submit_midpoint_out_of_range() {
        let gs = fresh_game(10, 20, TurnSide::Sequencer);
        let mp_low_oor = Claim {
            idx: 10,
            commit: commit(99),
        };
        let err = apply_transition(&gs, GameTransition::SubmitMidpoint(mp_low_oor)).unwrap_err();
        assert_eq!(err, GameError::MidpointOutOfRange);

        let mp_high_oor = Claim {
            idx: 20,
            commit: commit(99),
        };
        let err = apply_transition(&gs, GameTransition::SubmitMidpoint(mp_high_oor)).unwrap_err();
        assert_eq!(err, GameError::MidpointOutOfRange);

        let mp_above = Claim {
            idx: 21,
            commit: commit(99),
        };
        let err = apply_transition(&gs, GameTransition::SubmitMidpoint(mp_above)).unwrap_err();
        assert_eq!(err, GameError::MidpointOutOfRange);
    }

    /// `submitMidpoint` rejects when game is settled.
    #[test]
    fn submit_midpoint_rejects_settled_game() {
        let mut gs = fresh_game(0, 64, TurnSide::Sequencer);
        gs.status = GameStatus::SequencerWon;
        let mp = Claim {
            idx: 32,
            commit: commit(99),
        };
        let err = apply_transition(&gs, GameTransition::SubmitMidpoint(mp)).unwrap_err();
        assert_eq!(err, GameError::GameAlreadyEnded);
    }

    /// `submitMidpoint` rejects when one is already pending.
    #[test]
    fn submit_midpoint_rejects_during_response() {
        let mut gs = fresh_game(0, 64, TurnSide::Sequencer);
        gs.pending_midpoint = Some(Claim {
            idx: 32,
            commit: commit(7),
        });
        let mp = Claim {
            idx: 16,
            commit: commit(99),
        };
        let err = apply_transition(&gs, GameTransition::SubmitMidpoint(mp)).unwrap_err();
        assert_eq!(err, GameError::MidpointDuringResponse);
    }

    /// `submitMidpoint` rejects at the depth cap.
    #[test]
    fn submit_midpoint_rejects_at_depth_cap() {
        let mut gs = fresh_game(0, u64::from(MAX_BISECTION_DEPTH) * 2, TurnSide::Sequencer);
        gs.depth = MAX_BISECTION_DEPTH;
        let mp = Claim {
            idx: u64::from(MAX_BISECTION_DEPTH),
            commit: commit(99),
        };
        let err = apply_transition(&gs, GameTransition::SubmitMidpoint(mp)).unwrap_err();
        assert_eq!(err, GameError::BisectionDepthExceeded);
    }

    /// `respondAgree` narrows range upward.
    #[test]
    fn respond_agree_narrows_upward() {
        let mut gs = fresh_game(0, 64, TurnSide::Challenger);
        gs.pending_midpoint = Some(Claim {
            idx: 32,
            commit: commit(7),
        });
        let next = apply_transition(&gs, GameTransition::RespondAgree).unwrap();
        assert_eq!(next.range.low.idx, 32);
        assert_eq!(next.range.high.idx, 64);
        assert!(next.pending_midpoint.is_none());
        assert_eq!(next.depth, 1);
        assert_eq!(next.turn, TurnSide::Sequencer);
    }

    /// `respondDisagree` narrows range downward.
    #[test]
    fn respond_disagree_narrows_downward() {
        let mut gs = fresh_game(0, 64, TurnSide::Challenger);
        gs.pending_midpoint = Some(Claim {
            idx: 32,
            commit: commit(7),
        });
        let next = apply_transition(&gs, GameTransition::RespondDisagree).unwrap();
        assert_eq!(next.range.low.idx, 0);
        assert_eq!(next.range.high.idx, 32);
        assert!(next.pending_midpoint.is_none());
        assert_eq!(next.depth, 1);
        assert_eq!(next.turn, TurnSide::Sequencer);
    }

    /// `respond*` reject when no midpoint is pending.
    #[test]
    fn respond_rejects_without_pending_midpoint() {
        let gs = fresh_game(0, 64, TurnSide::Sequencer);
        let err = apply_transition(&gs, GameTransition::RespondAgree).unwrap_err();
        assert_eq!(err, GameError::ResponseDuringSubmit);
        let err = apply_transition(&gs, GameTransition::RespondDisagree).unwrap_err();
        assert_eq!(err, GameError::ResponseDuringSubmit);
    }

    /// `respond*` reject at the depth cap.
    #[test]
    fn respond_rejects_at_depth_cap() {
        let mut gs = fresh_game(0, u64::from(MAX_BISECTION_DEPTH) * 2, TurnSide::Challenger);
        gs.depth = MAX_BISECTION_DEPTH;
        gs.pending_midpoint = Some(Claim {
            idx: u64::from(MAX_BISECTION_DEPTH),
            commit: commit(7),
        });
        let err = apply_transition(&gs, GameTransition::RespondAgree).unwrap_err();
        assert_eq!(err, GameError::BisectionDepthExceeded);
    }

    /// `terminateOnSingleStep` rejects when range is multi-step.
    #[test]
    fn terminate_rejects_multi_step_range() {
        let gs = fresh_game(0, 64, TurnSide::Sequencer);
        let t = GameTransition::TerminateOnSingleStep {
            claimed_post_commit: commit(99),
        };
        let err = apply_transition(&gs, t).unwrap_err();
        assert_eq!(err, GameError::RangeNotSingleStep);
    }

    /// `terminateOnSingleStep` accepts single-step ranges and
    /// leaves status `InProgress` (the L1 contract evaluates).
    #[test]
    fn terminate_accepts_single_step() {
        let gs = fresh_game(5, 6, TurnSide::Sequencer);
        let t = GameTransition::TerminateOnSingleStep {
            claimed_post_commit: commit(99),
        };
        let next = apply_transition(&gs, t).unwrap();
        // Rust port leaves status unchanged; settlement is
        // applied via `apply_settlement` when the L1 event lands.
        assert_eq!(next.status, GameStatus::InProgress);
    }

    /// `timeoutLoss` settles to the current turn-holder's loss.
    #[test]
    fn timeout_settles_to_current_turn_holder() {
        let gs_seq = fresh_game(0, 64, TurnSide::Sequencer);
        let next = apply_transition(&gs_seq, GameTransition::TimeoutLoss).unwrap();
        assert_eq!(next.status, GameStatus::TimedOutSequencer);

        let gs_chal = fresh_game(0, 64, TurnSide::Challenger);
        let next = apply_transition(&gs_chal, GameTransition::TimeoutLoss).unwrap();
        assert_eq!(next.status, GameStatus::TimedOutChallenger);
    }

    /// `timeoutLoss` rejects already-settled games.
    #[test]
    fn timeout_rejects_settled() {
        let mut gs = fresh_game(0, 64, TurnSide::Sequencer);
        gs.status = GameStatus::ChallengerWon;
        let err = apply_transition(&gs, GameTransition::TimeoutLoss).unwrap_err();
        assert_eq!(err, GameError::GameAlreadyEnded);
    }

    /// `apply_settlement` updates status.
    #[test]
    fn apply_settlement_updates_status() {
        let gs = fresh_game(0, 64, TurnSide::Sequencer);
        let next = apply_settlement(&gs, GameStatus::ChallengerWon).unwrap();
        assert_eq!(next.status, GameStatus::ChallengerWon);
    }

    /// `apply_settlement` rejects already-settled games.
    #[test]
    fn apply_settlement_idempotent_rejected() {
        let mut gs = fresh_game(0, 64, TurnSide::Sequencer);
        gs.status = GameStatus::SequencerWon;
        let err = apply_settlement(&gs, GameStatus::ChallengerWon).unwrap_err();
        assert_eq!(err, GameError::GameAlreadyEnded);
    }

    /// `apply_settlement` rejects passing `InProgress` as the
    /// final status.
    #[test]
    fn apply_settlement_rejects_in_progress_final() {
        let gs = fresh_game(0, 64, TurnSide::Sequencer);
        let err = apply_settlement(&gs, GameStatus::InProgress).unwrap_err();
        assert_eq!(err, GameError::InvalidSettlement);
    }

    /// Full bisection trace: ten `respond_disagree` narrow the
    /// range to a single step.
    #[test]
    fn full_bisection_trace_to_single_step() {
        let mut gs = fresh_game(0, 1024, TurnSide::Sequencer);
        let mut current_width = gs.range.width();
        let mut step: u8 = 0;
        while !gs.range.is_single_step() && step < 100 {
            let mid_idx = gs.range.midpoint_idx();
            let mp = Claim {
                idx: mid_idx,
                commit: commit(step.wrapping_add(7)),
            };
            gs = apply_transition(&gs, GameTransition::SubmitMidpoint(mp)).unwrap();
            gs = apply_transition(&gs, GameTransition::RespondDisagree).unwrap();
            // Each respond_disagree must strictly narrow.
            let new_width = gs.range.width();
            assert!(
                new_width < current_width,
                "bisection round {step} did not narrow: {current_width} → {new_width}"
            );
            current_width = new_width;
            step += 1;
        }
        assert!(
            gs.range.is_single_step(),
            "bisection should have narrowed to single step in <= 10 rounds for 1024-wide range"
        );
    }

    /// Cross-stack: floor-div midpoint must MATCH the Solidity
    /// formula `(low + high) / 2` (NOT (high - low) / 2 + low,
    /// which would mathematically agree but use a different rep
    /// in the EVM and produce different overflow behaviour).
    #[test]
    fn midpoint_matches_solidity_formula() {
        // The Solidity formula `(g.low.idx + g.high.idx) / 2`
        // overflows at `low + high >= 2^64`; the Solidity contract
        // works around this by typing both idx as `uint64` and
        // using `uint256` arithmetic.  Our Rust port upcasts to
        // u128 explicitly to match.  Pin one extreme value.
        let r = DisputedRange {
            low: Claim {
                idx: 1_000_000,
                commit: commit(1),
            },
            high: Claim {
                idx: 1_000_001,
                commit: commit(2),
            },
        };
        assert_eq!(r.midpoint_idx(), 1_000_000);
    }

    /// Game state JSON round-trip pins the serde layout.
    #[test]
    fn game_state_json_round_trip() {
        let gs = fresh_game(0, 64, TurnSide::Sequencer);
        let json = serde_json::to_string(&gs).expect("serialise");
        let decoded: GameState = serde_json::from_str(&json).expect("deserialise");
        assert_eq!(decoded, gs);
    }

    /// Sequencer-turn after submitMidpoint flips to challenger.
    #[test]
    fn turn_flips_after_submit() {
        let gs = fresh_game(0, 16, TurnSide::Sequencer);
        let mp = Claim {
            idx: 8,
            commit: commit(7),
        };
        let next = apply_transition(&gs, GameTransition::SubmitMidpoint(mp)).unwrap();
        assert_eq!(next.turn, TurnSide::Challenger);
    }

    /// Challenger-turn after respondAgree flips to sequencer.
    #[test]
    fn turn_flips_after_respond() {
        let mut gs = fresh_game(0, 16, TurnSide::Challenger);
        gs.pending_midpoint = Some(Claim {
            idx: 8,
            commit: commit(7),
        });
        let next = apply_transition(&gs, GameTransition::RespondAgree).unwrap();
        assert_eq!(next.turn, TurnSide::Sequencer);
    }

    /// Settled status types do not advance the game.
    #[test]
    fn settled_statuses_reject_every_transition() {
        for terminal in [
            GameStatus::SequencerWon,
            GameStatus::ChallengerWon,
            GameStatus::TimedOutSequencer,
            GameStatus::TimedOutChallenger,
        ] {
            let mut gs = fresh_game(0, 64, TurnSide::Sequencer);
            gs.status = terminal;
            gs.pending_midpoint = Some(Claim {
                idx: 32,
                commit: commit(7),
            });
            assert_eq!(
                apply_transition(
                    &gs,
                    GameTransition::SubmitMidpoint(Claim {
                        idx: 16,
                        commit: commit(99)
                    })
                )
                .unwrap_err(),
                GameError::GameAlreadyEnded
            );
            assert_eq!(
                apply_transition(&gs, GameTransition::RespondAgree).unwrap_err(),
                GameError::GameAlreadyEnded
            );
            assert_eq!(
                apply_transition(&gs, GameTransition::RespondDisagree).unwrap_err(),
                GameError::GameAlreadyEnded
            );
            assert_eq!(
                apply_transition(
                    &gs,
                    GameTransition::TerminateOnSingleStep {
                        claimed_post_commit: commit(99),
                    },
                )
                .unwrap_err(),
                GameError::GameAlreadyEnded
            );
            assert_eq!(
                apply_transition(&gs, GameTransition::TimeoutLoss).unwrap_err(),
                GameError::GameAlreadyEnded
            );
        }
    }

    /// `apply_transition` is deterministic: equal inputs produce
    /// equal outputs.
    #[test]
    fn apply_transition_deterministic() {
        let gs = fresh_game(0, 64, TurnSide::Sequencer);
        let mp = Claim {
            idx: 32,
            commit: commit(99),
        };
        let t = GameTransition::SubmitMidpoint(mp);
        let r1 = apply_transition(&gs, t);
        let r2 = apply_transition(&gs, t);
        assert_eq!(r1, r2);
    }

    /// Range-width invariant: every successful `respond_agree` /
    /// `respond_disagree` strictly reduces the width.
    #[test]
    fn respond_strictly_narrows() {
        let mut gs = fresh_game(0, 32, TurnSide::Challenger);
        gs.pending_midpoint = Some(Claim {
            idx: 16,
            commit: commit(7),
        });
        let next = apply_transition(&gs, GameTransition::RespondAgree).unwrap();
        assert!(next.range.width() < gs.range.width());

        let mut gs2 = fresh_game(0, 32, TurnSide::Challenger);
        gs2.pending_midpoint = Some(Claim {
            idx: 16,
            commit: commit(7),
        });
        let next2 = apply_transition(&gs2, GameTransition::RespondDisagree).unwrap();
        assert!(next2.range.width() < gs2.range.width());
    }
}
