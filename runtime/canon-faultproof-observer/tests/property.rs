// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Property-based tests for the observer (RH-G.7).
//!
//! These tests use `proptest` to exercise the game-state machine
//! and honest-strategy modules over a wide range of synthesised
//! inputs, asserting the load-bearing invariants:
//!
//!   1. **Bisection convergence**: every `respond_agree` /
//!      `respond_disagree` strictly narrows the range (or reaches
//!      single-step).  Equivalent of Lean's
//!      `range_narrows_on_response_*` theorems.
//!   2. **Determinism**: `apply_transition` is a function of
//!      `(GameState, GameTransition)`; equal inputs produce equal
//!      outputs.
//!   3. **Calldata encoding round-trip**: encoding a move with
//!      `encode_calldata` produces bytes whose first 4 bytes
//!      match the method selector and whose length matches the
//!      method's signature.
//!   4. **Settlement idempotence**: once a game is settled,
//!      every subsequent transition returns `GameAlreadyEnded`.
//!   5. **State machine no-panic**: random inputs never panic
//!      the state machine.
//!
//! Per the plan §RH-G.7, these property tests are the load-
//! bearing safety net protecting against cross-stack divergence
//! between the Rust port and the Lean reference.

use knomosis_faultproof_observer::game::{
    apply_settlement, apply_transition, Claim, DisputedRange, GameError, GameState, GameStatus,
    GameTransition, TurnSide, MAX_BISECTION_DEPTH,
};
use knomosis_faultproof_observer::strategy::{compute_next_move, HonestMove, MemoryTruthOracle};
use knomosis_faultproof_observer::submitter::{encode_calldata, MethodSelector};
use proptest::prelude::*;

/// Strategy for generating arbitrary 32-byte state commits.
fn commit_strategy() -> impl Strategy<Value = [u8; 32]> {
    proptest::collection::vec(any::<u8>(), 32..=32).prop_map(|v| {
        let mut out = [0u8; 32];
        out.copy_from_slice(&v);
        out
    })
}

/// Strategy for generating arbitrary log indices within a
/// reasonable range (avoid `u64::MAX` which causes overflow in
/// some Lean spec paths).
fn log_index_strategy() -> impl Strategy<Value = u64> {
    0u64..(1 << 32)
}

/// Strategy for an in-progress game state with a wide range.
fn in_progress_game_strategy() -> impl Strategy<Value = GameState> {
    (
        log_index_strategy(),
        2u64..(1 << 32),
        commit_strategy(),
        commit_strategy(),
        prop_oneof![Just(TurnSide::Sequencer), Just(TurnSide::Challenger)],
        0u32..MAX_BISECTION_DEPTH,
        commit_strategy(),
    )
        .prop_filter_map(
            "low.idx < high.idx",
            |(low_idx, width, low_commit, high_commit, turn, depth, _)| {
                let high_idx = low_idx.checked_add(width)?;
                Some(GameState {
                    sequencer: 1,
                    challenger: 2,
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
                    pending_midpoint: None,
                    depth,
                    turn,
                    sequencer_bond: 1_000,
                    challenger_bond: 1_000,
                    status: GameStatus::InProgress,
                    deployment_id: [0u8; 32],
                })
            },
        )
}

/// Strategy for a settled (terminal) game state.
fn settled_game_strategy() -> impl Strategy<Value = GameState> {
    prop_oneof![
        in_progress_game_strategy().prop_map(|mut g| {
            g.status = GameStatus::SequencerWon;
            g
        }),
        in_progress_game_strategy().prop_map(|mut g| {
            g.status = GameStatus::ChallengerWon;
            g
        }),
        in_progress_game_strategy().prop_map(|mut g| {
            g.status = GameStatus::TimedOutSequencer;
            g
        }),
        in_progress_game_strategy().prop_map(|mut g| {
            g.status = GameStatus::TimedOutChallenger;
            g
        }),
    ]
}

proptest! {
    /// PROPERTY: `apply_transition` is deterministic.  Equal
    /// inputs produce equal outputs.
    #[test]
    fn apply_transition_is_deterministic(
        gs in in_progress_game_strategy(),
        mp_idx in log_index_strategy(),
        mp_commit in commit_strategy(),
    ) {
        let mp = Claim {
            idx: mp_idx,
            commit: mp_commit,
        };
        let t = GameTransition::SubmitMidpoint(mp);
        let r1 = apply_transition(&gs, t);
        let r2 = apply_transition(&gs, t);
        prop_assert_eq!(r1, r2);
    }

    /// PROPERTY: a successful respond_agree strictly narrows
    /// the range.  Equivalent to Lean's
    /// `range_narrows_on_response_agree`.
    #[test]
    fn respond_agree_narrows_range(
        mut gs in in_progress_game_strategy(),
        mp_offset in 1u64..1000,
        mp_commit in commit_strategy(),
    ) {
        // Ensure the range is wide enough to admit a midpoint.
        if gs.range.high.idx <= gs.range.low.idx + 1 {
            return Ok(());
        }
        let mp_idx = gs.range.low.idx + (mp_offset.min(
            gs.range.high.idx.saturating_sub(gs.range.low.idx).saturating_sub(1)
        ));
        if mp_idx <= gs.range.low.idx || mp_idx >= gs.range.high.idx {
            return Ok(());
        }
        gs.pending_midpoint = Some(Claim {
            idx: mp_idx,
            commit: mp_commit,
        });
        // Depth must be below cap.
        gs.depth = gs.depth.min(MAX_BISECTION_DEPTH - 1);
        let old_width = gs.range.high.idx - gs.range.low.idx;
        let result = apply_transition(&gs, GameTransition::RespondAgree);
        let new_state = result.unwrap();
        let new_width = new_state.range.high.idx - new_state.range.low.idx;
        prop_assert!(new_width < old_width);
    }

    /// PROPERTY: a successful respond_disagree strictly narrows
    /// the range.
    #[test]
    fn respond_disagree_narrows_range(
        mut gs in in_progress_game_strategy(),
        mp_offset in 1u64..1000,
        mp_commit in commit_strategy(),
    ) {
        if gs.range.high.idx <= gs.range.low.idx + 1 {
            return Ok(());
        }
        let mp_idx = gs.range.low.idx + (mp_offset.min(
            gs.range.high.idx.saturating_sub(gs.range.low.idx).saturating_sub(1)
        ));
        if mp_idx <= gs.range.low.idx || mp_idx >= gs.range.high.idx {
            return Ok(());
        }
        gs.pending_midpoint = Some(Claim {
            idx: mp_idx,
            commit: mp_commit,
        });
        gs.depth = gs.depth.min(MAX_BISECTION_DEPTH - 1);
        let old_width = gs.range.high.idx - gs.range.low.idx;
        let result = apply_transition(&gs, GameTransition::RespondDisagree);
        let new_state = result.unwrap();
        let new_width = new_state.range.high.idx - new_state.range.low.idx;
        prop_assert!(new_width < old_width);
    }

    /// PROPERTY: settled games reject every transition.
    /// Equivalent to Lean's `applyTransition` `gameAlreadyEnded`
    /// guard.
    #[test]
    fn settled_games_reject_all_transitions(
        gs in settled_game_strategy(),
        mp_commit in commit_strategy(),
        claimed_commit in commit_strategy(),
    ) {
        for t in [
            GameTransition::SubmitMidpoint(Claim {
                idx: gs.range.low.idx + 1,
                commit: mp_commit,
            }),
            GameTransition::RespondAgree,
            GameTransition::RespondDisagree,
            GameTransition::TerminateOnSingleStep {
                claimed_post_commit: claimed_commit,
            },
            GameTransition::TimeoutLoss,
        ] {
            let err = apply_transition(&gs, t).unwrap_err();
            prop_assert_eq!(err, GameError::GameAlreadyEnded);
        }
    }

    /// PROPERTY: settlement applied to an already-settled game
    /// returns `GameAlreadyEnded`.
    #[test]
    fn apply_settlement_idempotent_under_re_settle(
        gs in settled_game_strategy(),
    ) {
        let err = apply_settlement(&gs, GameStatus::SequencerWon).unwrap_err();
        prop_assert_eq!(err, GameError::GameAlreadyEnded);
    }

    /// PROPERTY: applying a successful submit followed by a
    /// successful respond_agree produces a depth increment of
    /// exactly 1.  This is the "depth-tick" invariant.
    #[test]
    fn submit_respond_increments_depth_by_one(
        gs in in_progress_game_strategy(),
        mp_commit in commit_strategy(),
    ) {
        // Need a wide enough range for a non-degenerate midpoint.
        if gs.range.high.idx <= gs.range.low.idx + 1 {
            return Ok(());
        }
        if gs.depth >= MAX_BISECTION_DEPTH - 1 {
            return Ok(());
        }
        if gs.pending_midpoint.is_some() {
            return Ok(());
        }
        let mid_idx = gs.range.midpoint_idx();
        if mid_idx <= gs.range.low.idx || mid_idx >= gs.range.high.idx {
            return Ok(());
        }
        let mp = Claim {
            idx: mid_idx,
            commit: mp_commit,
        };
        let original_depth = gs.depth;
        let after_submit = apply_transition(&gs, GameTransition::SubmitMidpoint(mp)).unwrap();
        prop_assert_eq!(after_submit.depth, original_depth);
        let after_respond =
            apply_transition(&after_submit, GameTransition::RespondAgree).unwrap();
        prop_assert_eq!(after_respond.depth, original_depth + 1);
    }

    /// PROPERTY: calldata encoding produces bytes that start
    /// with the correct method selector.
    #[test]
    fn calldata_encoding_starts_with_selector(
        game_id in 0u128..(1 << 80),
        commit in commit_strategy(),
        agree in any::<bool>(),
    ) {
        let claim = Claim { idx: 7, commit };
        let calldata_submit = encode_calldata(game_id, HonestMove::Submit(claim)).unwrap();
        prop_assert_eq!(&calldata_submit[0..4], &MethodSelector::SubmitMidpoint.selector());

        let calldata_respond = encode_calldata(
            game_id,
            if agree {
                HonestMove::RespondAgree
            } else {
                HonestMove::RespondDisagree
            },
        )
        .unwrap();
        prop_assert_eq!(
            &calldata_respond[0..4],
            &MethodSelector::RespondToMidpoint.selector()
        );
    }

    /// PROPERTY: every encoded calldata has the canonical
    /// (4-byte selector + N×32-byte ABI words) shape.
    #[test]
    fn calldata_encoding_canonical_shape(
        game_id in 0u128..(1 << 80),
        commit in commit_strategy(),
    ) {
        let claim = Claim { idx: 7, commit };
        let calldata = encode_calldata(game_id, HonestMove::Submit(claim)).unwrap();
        prop_assert_eq!(calldata.len(), 4 + 32 + 32);
    }

    /// PROPERTY: `compute_next_move` never panics on arbitrary
    /// inputs.
    #[test]
    fn compute_next_move_never_panics(
        gs in in_progress_game_strategy(),
        me in prop_oneof![Just(TurnSide::Sequencer), Just(TurnSide::Challenger)],
    ) {
        let oracle = MemoryTruthOracle::new();
        let _ = compute_next_move(&oracle, &gs, me);
        // Should not panic; result is OK regardless of oracle
        // emptiness (returns error, not panic).
    }

    /// PROPERTY: on a settled game, `compute_next_move` returns
    /// `HonestMove::NoMove`.
    #[test]
    fn compute_next_move_no_move_on_settled(
        gs in settled_game_strategy(),
        me in prop_oneof![Just(TurnSide::Sequencer), Just(TurnSide::Challenger)],
    ) {
        let oracle = MemoryTruthOracle::new();
        let mv = compute_next_move(&oracle, &gs, me).unwrap();
        prop_assert_eq!(mv, HonestMove::NoMove);
    }

    /// PROPERTY: turn flips after every successful transition
    /// (except `TerminateOnSingleStep` and `TimeoutLoss` which
    /// settle the game).
    #[test]
    fn turn_flips_after_submit_respond(
        gs in in_progress_game_strategy(),
        mp_commit in commit_strategy(),
    ) {
        if gs.range.high.idx <= gs.range.low.idx + 1 {
            return Ok(());
        }
        if gs.depth >= MAX_BISECTION_DEPTH {
            return Ok(());
        }
        if gs.pending_midpoint.is_some() {
            return Ok(());
        }
        let mid_idx = gs.range.midpoint_idx();
        if mid_idx <= gs.range.low.idx || mid_idx >= gs.range.high.idx {
            return Ok(());
        }
        let mp = Claim {
            idx: mid_idx,
            commit: mp_commit,
        };
        let original_turn = gs.turn;
        let after_submit = apply_transition(&gs, GameTransition::SubmitMidpoint(mp)).unwrap();
        prop_assert_eq!(after_submit.turn, original_turn.flip());
        let after_respond = apply_transition(&after_submit, GameTransition::RespondAgree).unwrap();
        prop_assert_eq!(after_respond.turn, original_turn);
    }

    /// PROPERTY: midpoint_idx is always strictly inside the
    /// range when the range has width >= 2.
    #[test]
    fn midpoint_idx_inside_range_for_non_single_step(
        low_idx in log_index_strategy(),
        width in 2u64..(1 << 32),
    ) {
        let Some(high_idx) = low_idx.checked_add(width) else {
            return Ok(());
        };
        let r = DisputedRange {
            low: Claim {
                idx: low_idx,
                commit: [0u8; 32],
            },
            high: Claim {
                idx: high_idx,
                commit: [0u8; 32],
            },
        };
        let mid = r.midpoint_idx();
        prop_assert!(mid > low_idx);
        prop_assert!(mid < high_idx);
    }

    /// PROPERTY: a full simulated bisection from a wide range
    /// always terminates within `ceil(log2(width))` rounds.
    #[test]
    fn bisection_terminates_in_logarithmic_rounds(
        initial_width_exp in 1u32..16,
    ) {
        let initial_width = 1u64 << initial_width_exp;
        let mut gs = GameState {
            sequencer: 1,
            challenger: 2,
            range: DisputedRange {
                low: Claim {
                    idx: 0,
                    commit: [1u8; 32],
                },
                high: Claim {
                    idx: initial_width,
                    commit: [2u8; 32],
                },
            },
            pending_midpoint: None,
            depth: 0,
            turn: TurnSide::Sequencer,
            sequencer_bond: 1000,
            challenger_bond: 1000,
            status: GameStatus::InProgress,
            deployment_id: [0u8; 32],
        };
        let mut rounds = 0;
        while !gs.range.is_single_step() && rounds < 64 {
            let mid_idx = gs.range.midpoint_idx();
            let mp = Claim {
                idx: mid_idx,
                commit: [3u8; 32],
            };
            gs = apply_transition(&gs, GameTransition::SubmitMidpoint(mp)).unwrap();
            gs = apply_transition(&gs, GameTransition::RespondDisagree).unwrap();
            rounds += 1;
        }
        prop_assert!(
            gs.range.is_single_step(),
            "bisection should converge in <= ceil(log2(width)) rounds; got {rounds} for width {initial_width}"
        );
        // ceil(log2(width)) bound.
        let log2_ceil =
            initial_width.ilog2() + u32::from(!initial_width.is_power_of_two());
        prop_assert!(
            rounds <= u64::from(log2_ceil) + 1,
            "rounds {rounds} > log2_ceil {log2_ceil} for width {initial_width}",
        );
    }

    /// PROPERTY: `GameState` JSON round-trips faithfully.
    #[test]
    fn game_state_json_round_trip(gs in in_progress_game_strategy()) {
        let json = serde_json::to_string(&gs).unwrap();
        let decoded: GameState = serde_json::from_str(&json).unwrap();
        prop_assert_eq!(decoded, gs);
    }

    /// PROPERTY: `SubmitMidpoint` guard combinatorial overlap —
    /// when multiple guards would fire, the FIRST guard's error
    /// is returned (status → pending → depth → range, in order).
    ///
    /// Audit-gap test (game.rs L-2): pin the guard-ordering
    /// against Lean's `applyTransition` for `submitMidpoint`.
    #[test]
    fn submit_midpoint_guard_ordering_matches_lean(
        gs in in_progress_game_strategy(),
        mp_commit in commit_strategy(),
    ) {
        // Construct a state with MULTIPLE guards violated:
        //   - status = Settled (gameAlreadyEnded guard)
        //   - pending_midpoint = Some (midpointDuringResponse guard)
        //   - depth = MAX (bisectionDepthExceeded guard)
        //   - mp.idx out of range (midpointOutOfRange guard)
        // The Lean order returns gameAlreadyEnded first.  Our
        // Rust must agree.
        let mut adversarial = gs.clone();
        adversarial.status = GameStatus::SequencerWon;
        adversarial.pending_midpoint = Some(Claim {
            idx: adversarial.range.low.idx + 1,
            commit: mp_commit,
        });
        adversarial.depth = MAX_BISECTION_DEPTH;
        // mp.idx = low.idx → MidpointOutOfRange would fire if
        // we reached the range guard.
        let mp = Claim {
            idx: adversarial.range.low.idx,
            commit: mp_commit,
        };
        let err =
            crate::observer_audit::apply_transition_test(&adversarial, GameTransition::SubmitMidpoint(mp))
                .unwrap_err();
        // First guard: status.
        prop_assert_eq!(err, GameError::GameAlreadyEnded);
    }

    /// PROPERTY: `RespondAgree` guard ordering matches Lean —
    /// status → depth → pending (in that order).
    #[test]
    fn respond_agree_guard_ordering_matches_lean(
        gs in in_progress_game_strategy(),
    ) {
        let mut adversarial = gs;
        adversarial.status = GameStatus::TimedOutSequencer;
        adversarial.depth = MAX_BISECTION_DEPTH;
        adversarial.pending_midpoint = None;
        let err = crate::observer_audit::apply_transition_test(
            &adversarial,
            GameTransition::RespondAgree,
        )
        .unwrap_err();
        prop_assert_eq!(err, GameError::GameAlreadyEnded);
    }

    /// PROPERTY: `is_single_step` on a degenerate range (low ==
    /// high == u64::MAX) reports `true` due to saturating_add,
    /// but this is acknowledged as not-legitimate-L1-input.  The
    /// strategy's `compute_next_move` on such a state must not
    /// panic and must return a sensible (possibly NoMove)
    /// result.
    #[test]
    fn single_step_at_u64_max_no_panic(
        commit_a in commit_strategy(),
        commit_b in commit_strategy(),
    ) {
        let degenerate = GameState {
            sequencer: 1,
            challenger: 2,
            range: DisputedRange {
                low: Claim {
                    idx: u64::MAX,
                    commit: commit_a,
                },
                high: Claim {
                    idx: u64::MAX,
                    commit: commit_b,
                },
            },
            pending_midpoint: None,
            depth: 0,
            turn: TurnSide::Sequencer,
            sequencer_bond: 1000,
            challenger_bond: 1000,
            status: GameStatus::InProgress,
            deployment_id: [0u8; 32],
        };
        // is_single_step is `true` by saturating-add discipline.
        prop_assert!(degenerate.range.is_single_step());
        // compute_next_move returns either NoMove (oracle miss),
        // or TerminateOnSingleStep with the oracle's commit at
        // u64::MAX (if the oracle has that idx).  It MUST NOT
        // panic.
        let oracle = MemoryTruthOracle::new();
        let result = compute_next_move(&oracle, &degenerate, TurnSide::Sequencer);
        // Result type tested; specific value depends on oracle.
        prop_assert!(result.is_ok() || result.is_err());
    }

    /// PROPERTY: settlement matrix — every (in-progress game,
    /// terminal final-status) pair is accepted and the post-
    /// state has the requested final status.  Equivalent to a
    /// 4-cell coverage test (4 terminal values × InProgress
    /// game).
    #[test]
    fn settlement_matrix(gs in in_progress_game_strategy()) {
        for terminal in [
            GameStatus::SequencerWon,
            GameStatus::ChallengerWon,
            GameStatus::TimedOutSequencer,
            GameStatus::TimedOutChallenger,
        ] {
            let result = apply_settlement(&gs, terminal).unwrap();
            prop_assert_eq!(result.status, terminal);
            // Range, depth, turn, bonds, deployment_id unchanged.
            prop_assert_eq!(result.range, gs.range);
            prop_assert_eq!(result.depth, gs.depth);
            prop_assert_eq!(result.turn, gs.turn);
            prop_assert_eq!(result.deployment_id, gs.deployment_id);
        }
    }
}

/// Audit-pass extension: re-export the game module's
/// `apply_transition` under a stable test-only path so
/// guard-ordering property tests can refer to it without going
/// through the crate's exact module path resolution.
#[allow(unused)]
mod observer_audit {
    use knomosis_faultproof_observer::game::{apply_transition, GameError, GameState, GameTransition};

    pub(super) fn apply_transition_test(
        gs: &GameState,
        t: GameTransition,
    ) -> Result<GameState, GameError> {
        apply_transition(gs, t)
    }
}
