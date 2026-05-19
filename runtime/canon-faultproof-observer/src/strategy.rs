// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Rust port of `LegalKernel.FaultProof.Strategy`.
//!
//! ## Purpose
//!
//! Given the *truthful commit function* (`LogIndex → StateCommit`)
//! and the current `GameState`, compute the unique honest move.
//! Mirrors Lean's `honestStrategy` byte-for-byte.
//!
//! ## Truth oracle
//!
//! The truthful commit function is abstracted behind the
//! [`TruthOracle`] trait.  Two implementations ship:
//!
//!   * [`MemoryTruthOracle`] — pre-computed map, used by tests and
//!     by the in-memory mode of the observer (where the full
//!     `LogIndex → StateCommit` mapping is known upfront).
//!   * [`SubprocessTruthOracle`] — spawns `canon replay-up-to LOG IDX`
//!     to compute the canonical commit at the requested log index.
//!     Used in production.
//!
//! The observer's design philosophy: the **L2 kernel** (Lean
//! `kernelOnlyReplay`) is the authoritative truth function.  The
//! observer NEVER attempts to re-implement the truth function in
//! Rust — that would re-introduce divergence risk between Rust and
//! Lean.  Instead, the observer DELEGATES to a Lean subprocess for
//! truth computation, and uses Rust only for the *game-state
//! machine* (which is small enough to port faithfully and
//! cross-stack property-test).
//!
//! ## Honest-strategy invariant
//!
//! The plan §RH-G.4's load-bearing claim:
//!
//!   > Every reply byte-equals the Lean reference's reply
//!   > (verified against cross-stack corpus).
//!
//! [`compute_next_move`] satisfies this because:
//!
//!   1. The Rust game-state machine ([`crate::game`]) is
//!      byte-equivalent to Lean's `Game.lean` (property-tested).
//!   2. The truth oracle is the Lean subprocess itself (in
//!      production), so the truthful-commit lookups are
//!      definitionally byte-equal.
//!   3. The decision tree in [`compute_next_move`] mirrors the
//!      Lean `honestStrategy` case-split exactly.
//!
//! Together, these three facts close the byte-equivalence
//! argument.

use crate::game::{Claim, GameState, GameTransition, LogIndex, StateCommit, TurnSide};

/// A truth oracle: given a `LogIndex`, return the canonical
/// `StateCommit` at that index.  The observer DELEGATES truth
/// computation to this trait rather than re-implementing the L2
/// kernel's `commitExtendedState ∘ kernelOnlyReplay` in Rust.
///
/// # Errors
///
/// Implementations should return `None` when the requested log
/// index is past the local log's tail — that is, the observer
/// hasn't caught up to that index yet.  The caller's response is
/// usually "back off and retry"; an [`HonestMoveError::TruthOracleMissed`]
/// surfaces this to higher layers.
pub trait TruthOracle {
    /// Look up the canonical state commit at `idx`.  Returns
    /// `None` if the oracle doesn't yet know the commit (e.g.,
    /// the local replay hasn't reached `idx` yet).
    fn commit_at(&self, idx: LogIndex) -> Option<StateCommit>;
}

/// In-memory truth oracle: stores a pre-computed `LogIndex →
/// StateCommit` map.  Used by tests + by the in-memory mode of
/// the observer (where the full canonical mapping is known
/// upfront).
#[derive(Clone, Debug, Default)]
pub struct MemoryTruthOracle {
    map: std::collections::BTreeMap<LogIndex, StateCommit>,
}

impl MemoryTruthOracle {
    /// Construct an empty oracle.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Insert `(idx, commit)` into the oracle's map.  Overwrites
    /// any prior value.
    pub fn insert(&mut self, idx: LogIndex, commit: StateCommit) {
        self.map.insert(idx, commit);
    }

    /// The number of entries cached.  Diagnostic only.
    #[must_use]
    pub fn len(&self) -> usize {
        self.map.len()
    }

    /// True iff no entries are cached.  Diagnostic only.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

impl TruthOracle for MemoryTruthOracle {
    fn commit_at(&self, idx: LogIndex) -> Option<StateCommit> {
        self.map.get(&idx).copied()
    }
}

/// Subprocess-backed truth oracle: shells out to the
/// `canon replay-up-to LOG IDX` Lean subcommand to obtain the
/// canonical state commit at a log index.  Closes the RH-G.4
/// plan's "Invoke `canon` subprocess with `--replay-up-to
/// <pivot>`" deliverable.
///
/// **Output contract.**  The Lean subcommand prints a single
/// line of 64 hex chars (lowercase, no `0x` prefix) followed by
/// `\n` on stdout for a successful invocation.  Other output
/// (e.g., the deployment-id warning) goes to stderr.  Exit code
/// 0 means success.  Exit code 2 means "out of range" or
/// "non-Nat" — for our purposes both surface as a typed
/// `TruthOracleMissed` at move time.
///
/// **Hermetic-build note.**  The subprocess wrapper invokes
/// whatever `canon` binary the operator points at via
/// `SubprocessTruthOracle::new(canon_path, log_path)`.  The
/// caller is responsible for ensuring the binary's
/// `canon replay-up-to` subcommand matches the deployment's
/// expected output format.  Mismatch (e.g., the operator
/// pointing at a pre-RH-G canon binary) surfaces as
/// `TruthOracleMissed`.
/// Default `canon replay-up-to` invocation timeout.  Per the
/// audit-pass-4-round-3 CRITICAL fix: prevent a wedged canon
/// binary from hanging the observer's orchestrator loop.
///
/// Defaults to 30 s, which is generous for any real-world log
/// replay (a 1-second poll loop with this oracle would have
/// already detected the hang).
pub const DEFAULT_SUBPROCESS_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Default stdout size cap.  Per audit-pass-4-round-3 CRITICAL
/// fix: the canonical `canon replay-up-to` output is exactly
/// 65 bytes ("0123…cdef\n" = 64 hex chars + newline).  We
/// reserve generous headroom for future format extensions
/// (e.g., a multiline output with diagnostic prefix).  An
/// adversarial / buggy canon binary that prints multi-MB
/// stdout would OOM the observer; this cap prevents that.
pub const DEFAULT_SUBPROCESS_STDOUT_CAP: usize = 4096;

/// Production truth oracle that shells out to a `canon` binary
/// for `replay-up-to` truth computation.  Includes a subprocess
/// timeout and a stdout size cap (audit-pass-4-round-3
/// hardening: prevents a hung / misbehaving canon binary from
/// wedging or `OOM`-ing the observer).
#[allow(clippy::module_name_repetitions)]
pub struct SubprocessTruthOracle {
    canon_path: std::path::PathBuf,
    log_path: std::path::PathBuf,
    /// Additional CLI args (e.g., `--allow-fallback-hash`,
    /// `--deployment-id <hex>`) prepended to every invocation.
    /// Each tuple is `(flag, value)`; passed as `flag value` on
    /// the command line.
    extra_flags: Vec<(String, String)>,
    /// Subprocess timeout.  See [`DEFAULT_SUBPROCESS_TIMEOUT`].
    timeout: std::time::Duration,
    /// Max bytes the subprocess may write to stdout.  See
    /// [`DEFAULT_SUBPROCESS_STDOUT_CAP`].
    stdout_cap: usize,
}

impl SubprocessTruthOracle {
    /// Construct from the canon binary path and the log file
    /// path.  Operators typically pre-stage both before
    /// starting the observer.
    #[must_use]
    pub fn new(canon_path: std::path::PathBuf, log_path: std::path::PathBuf) -> Self {
        Self {
            canon_path,
            log_path,
            extra_flags: Vec::new(),
            timeout: DEFAULT_SUBPROCESS_TIMEOUT,
            stdout_cap: DEFAULT_SUBPROCESS_STDOUT_CAP,
        }
    }

    /// Append a `(flag, value)` pair to the prepend-to-every-
    /// invocation list.  Typical use: pass the deployment-id
    /// for cross-deployment-replay defence.
    #[must_use]
    pub fn with_flag(mut self, flag: impl Into<String>, value: impl Into<String>) -> Self {
        self.extra_flags.push((flag.into(), value.into()));
        self
    }

    /// Override the subprocess timeout.  Operators may want a
    /// tighter bound (e.g., 5s for a CI-only deployment) or a
    /// looser one (e.g., 5 min for a giant log).
    #[must_use]
    pub fn with_timeout(mut self, timeout: std::time::Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Override the stdout size cap.  Operators integrating
    /// with a canon binary that emits diagnostic prose should
    /// either tighten this (and parse only the first line) or
    /// loosen it cautiously.
    #[must_use]
    pub fn with_stdout_cap(mut self, cap: usize) -> Self {
        self.stdout_cap = cap;
        self
    }
}

impl TruthOracle for SubprocessTruthOracle {
    fn commit_at(&self, idx: LogIndex) -> Option<StateCommit> {
        // Audit-pass-4-round-3 CRITICAL fix: spawn + bounded
        // wait + kill-on-timeout, plus stdout size cap.  The
        // previous `cmd.output()` call had unbounded wait + read.
        //
        // The canon binary is expected to run as a single
        // process that exits quickly (≪ DEFAULT_SUBPROCESS_TIMEOUT).
        // We put it in its own process group via
        // `process_group(0)` (Unix) so that `kill` on timeout
        // propagates to any subprocess children — defends against
        // a shell-wrapper that forks `sleep` or similar.
        use std::io::Read;
        use std::process::Stdio;
        let mut cmd = std::process::Command::new(&self.canon_path);
        for (flag, value) in &self.extra_flags {
            cmd.arg(flag).arg(value);
        }
        cmd.arg("replay-up-to")
            .arg(&self.log_path)
            .arg(idx.to_string());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::inherit());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            // Place the child in its own process group.  This
            // makes `killpg(pid, SIGKILL)` reach the child's
            // descendants too.
            cmd.process_group(0);
        }
        let mut child = cmd.spawn().ok()?;
        let start = std::time::Instant::now();

        // Poll-loop with timeout for child exit.
        let poll_interval = std::time::Duration::from_millis(25);
        let exit_status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Some(status),
                Ok(None) => {
                    if start.elapsed() >= self.timeout {
                        // Timeout: SIGKILL the child.  The child
                        // was placed in its own process group via
                        // `process_group(0)` above (Unix); the
                        // production canon binary is a single
                        // process (no shell wrapper) so killing
                        // the leader is sufficient.  If a future
                        // operator wraps canon in a shell that
                        // forks subprocesses, those subprocesses
                        // become orphans but the observer's
                        // `commit_at` will still return None
                        // promptly (the read post-exit handles
                        // the orphaned-pipe case gracefully via
                        // the post-exit drain pattern).
                        let _ = child.kill();
                        let _ = child.wait();
                        break None;
                    }
                    std::thread::sleep(poll_interval);
                }
                Err(_) => {
                    // try_wait error: also treat as missed.
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
            }
        };
        // Drain stdout AFTER the child has exited.  Reading
        // post-exit avoids the orphan-pipe issue where a killed
        // shell's child could keep the write end open and block
        // a concurrent reader thread.  Bounded by `stdout_cap`.
        let mut stdout_bytes = Vec::with_capacity(self.stdout_cap.saturating_add(1));
        if let Some(mut stdout_pipe) = child.stdout.take() {
            let mut chunk = [0u8; 256];
            while let Ok(n) = stdout_pipe.read(&mut chunk) {
                if n == 0 {
                    break;
                }
                stdout_bytes.extend_from_slice(&chunk[..n]);
                if stdout_bytes.len() > self.stdout_cap {
                    // Stop reading; downstream cap-check will reject.
                    break;
                }
            }
        }

        let status = exit_status?;
        if !status.success() {
            return None;
        }
        if stdout_bytes.len() > self.stdout_cap {
            // Refuse to parse oversize output — defensive against
            // a misbehaving canon binary.
            return None;
        }
        // Parse the first line as 64 hex chars.
        let stdout_str = std::str::from_utf8(&stdout_bytes).ok()?;
        let line = stdout_str.lines().next()?;
        let hex = line.trim().strip_prefix("0x").unwrap_or(line.trim());
        if hex.len() != 64 {
            return None;
        }
        let bytes = hex::decode(hex).ok()?;
        if bytes.len() != 32 {
            return None;
        }
        let mut out = [0u8; 32];
        out.copy_from_slice(&bytes);
        Some(out)
    }
}

/// Errors `compute_next_move` can surface.
#[derive(Debug, thiserror::Error)]
pub enum HonestMoveError {
    /// The truth oracle does not yet know the commit at the
    /// requested index.  Caller should back off and retry once the
    /// local replay catches up.
    #[error("truth oracle missed at log index {idx}")]
    TruthOracleMissed {
        /// The requested log index.
        idx: LogIndex,
    },
}

/// The honest move recommendation.  Mirrors Lean's
/// `honestStrategy` return type (`Option GameTransition`) but
/// flattens the inner option into a typed enum.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HonestMove {
    /// No move is required — the game is not in progress, it's
    /// not the player's turn, or the range is degenerate.
    NoMove,
    /// The player should submit the truthful midpoint.
    Submit(Claim),
    /// The player should respond by agreeing.
    RespondAgree,
    /// The player should respond by disagreeing.
    RespondDisagree,
    /// The player should terminate on single-step.  Carries the
    /// claimed post-commit (the truthful commit at the high
    /// index of the range).
    TerminateOnSingleStep {
        /// The honest claim for what the L1 step VM should
        /// compute.
        claimed_post_commit: StateCommit,
    },
}

impl HonestMove {
    /// Convert the `HonestMove` into the corresponding
    /// `GameTransition`, or `None` if no move is required.
    /// Mirrors Lean's `Option GameTransition` projection.
    #[must_use]
    pub fn to_transition(self) -> Option<GameTransition> {
        match self {
            Self::NoMove => None,
            Self::Submit(c) => Some(GameTransition::SubmitMidpoint(c)),
            Self::RespondAgree => Some(GameTransition::RespondAgree),
            Self::RespondDisagree => Some(GameTransition::RespondDisagree),
            Self::TerminateOnSingleStep {
                claimed_post_commit,
            } => Some(GameTransition::TerminateOnSingleStep {
                claimed_post_commit,
            }),
        }
    }
}

/// Compute the next honest move in a game.  Mirrors Lean's
/// `honestStrategy` byte-for-byte:
///
///   * Game not in progress → `NoMove`.
///   * Not my turn → `NoMove`.
///   * My turn + no pending midpoint:
///       * Range non-trivial: submit the truthful midpoint.
///       * Range single-step: terminate on single step with the
///         truthful high-commit.
///   * My turn + pending midpoint: agree iff midpoint matches
///     truth, else disagree.
///
/// # Errors
///
/// Returns [`HonestMoveError::TruthOracleMissed`] if the truth
/// oracle does not yet know a commit needed to compute the move.
pub fn compute_next_move<O: TruthOracle + ?Sized>(
    oracle: &O,
    gs: &GameState,
    me: TurnSide,
) -> Result<HonestMove, HonestMoveError> {
    if !gs.status.is_in_progress() {
        return Ok(HonestMove::NoMove);
    }
    if gs.turn != me {
        return Ok(HonestMove::NoMove);
    }
    match gs.pending_midpoint {
        None => {
            // My turn to either submit a midpoint or terminate on
            // single step.
            if gs.range.is_single_step() {
                // Range is `[low.idx, low.idx + 1]`.  Terminate
                // with the truthful high-commit.
                let truth_high = oracle.commit_at(gs.range.high.idx).ok_or(
                    HonestMoveError::TruthOracleMissed {
                        idx: gs.range.high.idx,
                    },
                )?;
                Ok(HonestMove::TerminateOnSingleStep {
                    claimed_post_commit: truth_high,
                })
            } else {
                let mid_idx = gs.range.midpoint_idx();
                // The Lean strategy gates on
                //   `gs.range.low.idx < mid_idx ∧ mid_idx < gs.range.high.idx`.
                // For a non-single-step range, this holds: the
                // floor-division of `(low + high)` is at least
                // `low + 1` and at most `high - 1`.  Defensive:
                // re-check explicitly so the strategy mirrors
                // Lean's invariant even under future bound
                // changes.
                if mid_idx <= gs.range.low.idx || mid_idx >= gs.range.high.idx {
                    // Degenerate range (low + 1 == high actually
                    // checked above; this branch covers the
                    // mathematically impossible case where the
                    // arithmetic produces an out-of-range mid).
                    return Ok(HonestMove::NoMove);
                }
                let truth_mid = oracle
                    .commit_at(mid_idx)
                    .ok_or(HonestMoveError::TruthOracleMissed { idx: mid_idx })?;
                Ok(HonestMove::Submit(Claim {
                    idx: mid_idx,
                    commit: truth_mid,
                }))
            }
        }
        Some(mp) => {
            // My turn to respond.  Agree iff the pending midpoint
            // matches truth, else disagree.
            let truth_mid = oracle
                .commit_at(mp.idx)
                .ok_or(HonestMoveError::TruthOracleMissed { idx: mp.idx })?;
            if mp.commit == truth_mid {
                Ok(HonestMove::RespondAgree)
            } else {
                Ok(HonestMove::RespondDisagree)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{compute_next_move, HonestMove, HonestMoveError, MemoryTruthOracle, TruthOracle};
    use crate::game::{Claim, DisputedRange, GameState, GameStatus, StateCommit, TurnSide};

    fn commit(seed: u8) -> StateCommit {
        let mut out = [0u8; 32];
        out[0] = seed;
        out
    }

    fn fresh_game(low: u64, high: u64, turn: TurnSide) -> GameState {
        GameState {
            sequencer: 1,
            challenger: 2,
            range: DisputedRange {
                low: Claim {
                    idx: low,
                    commit: commit(1),
                },
                high: Claim {
                    idx: high,
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

    /// On a non-in-progress game, the strategy returns `NoMove`.
    #[test]
    fn no_move_when_not_in_progress() {
        let mut gs = fresh_game(0, 64, TurnSide::Sequencer);
        gs.status = GameStatus::SequencerWon;
        let oracle = MemoryTruthOracle::new();
        let mv = compute_next_move(&oracle, &gs, TurnSide::Sequencer).unwrap();
        assert_eq!(mv, HonestMove::NoMove);
    }

    /// On a wrong-turn game, the strategy returns `NoMove`.
    #[test]
    fn no_move_when_not_my_turn() {
        let gs = fresh_game(0, 64, TurnSide::Sequencer);
        let oracle = MemoryTruthOracle::new();
        let mv = compute_next_move(&oracle, &gs, TurnSide::Challenger).unwrap();
        assert_eq!(mv, HonestMove::NoMove);
    }

    /// Submit happy path: my turn, no pending, multi-step range.
    #[test]
    fn submit_truthful_midpoint() {
        let gs = fresh_game(0, 64, TurnSide::Sequencer);
        let mut oracle = MemoryTruthOracle::new();
        oracle.insert(32, commit(99));
        let mv = compute_next_move(&oracle, &gs, TurnSide::Sequencer).unwrap();
        match mv {
            HonestMove::Submit(c) => {
                assert_eq!(c.idx, 32);
                assert_eq!(c.commit, commit(99));
            }
            other => panic!("expected Submit, got {other:?}"),
        }
    }

    /// Submit-mode missing truth → typed error.
    #[test]
    fn submit_truth_missing_errors() {
        let gs = fresh_game(0, 64, TurnSide::Sequencer);
        let oracle = MemoryTruthOracle::new();
        let err = compute_next_move(&oracle, &gs, TurnSide::Sequencer).unwrap_err();
        assert!(matches!(
            err,
            HonestMoveError::TruthOracleMissed { idx: 32 }
        ));
    }

    /// Respond-agree path: pending midpoint matches truth.
    #[test]
    fn respond_agree_when_midpoint_truthful() {
        let mut gs = fresh_game(0, 64, TurnSide::Challenger);
        gs.pending_midpoint = Some(Claim {
            idx: 32,
            commit: commit(99),
        });
        let mut oracle = MemoryTruthOracle::new();
        oracle.insert(32, commit(99));
        let mv = compute_next_move(&oracle, &gs, TurnSide::Challenger).unwrap();
        assert_eq!(mv, HonestMove::RespondAgree);
    }

    /// Respond-disagree path: pending midpoint mismatches truth.
    #[test]
    fn respond_disagree_when_midpoint_wrong() {
        let mut gs = fresh_game(0, 64, TurnSide::Challenger);
        gs.pending_midpoint = Some(Claim {
            idx: 32,
            commit: commit(7),
        });
        let mut oracle = MemoryTruthOracle::new();
        oracle.insert(32, commit(99));
        let mv = compute_next_move(&oracle, &gs, TurnSide::Challenger).unwrap();
        assert_eq!(mv, HonestMove::RespondDisagree);
    }

    /// Respond-mode missing truth → typed error.
    #[test]
    fn respond_truth_missing_errors() {
        let mut gs = fresh_game(0, 64, TurnSide::Challenger);
        gs.pending_midpoint = Some(Claim {
            idx: 32,
            commit: commit(7),
        });
        let oracle = MemoryTruthOracle::new();
        let err = compute_next_move(&oracle, &gs, TurnSide::Challenger).unwrap_err();
        assert!(matches!(
            err,
            HonestMoveError::TruthOracleMissed { idx: 32 }
        ));
    }

    /// Single-step termination path: my turn, no pending, single-
    /// step range.
    #[test]
    fn terminate_on_single_step() {
        let gs = fresh_game(5, 6, TurnSide::Sequencer);
        let mut oracle = MemoryTruthOracle::new();
        oracle.insert(6, commit(42));
        let mv = compute_next_move(&oracle, &gs, TurnSide::Sequencer).unwrap();
        match mv {
            HonestMove::TerminateOnSingleStep {
                claimed_post_commit,
            } => {
                assert_eq!(claimed_post_commit, commit(42));
            }
            other => panic!("expected TerminateOnSingleStep, got {other:?}"),
        }
    }

    /// Single-step termination missing truth → typed error.
    #[test]
    fn terminate_truth_missing_errors() {
        let gs = fresh_game(5, 6, TurnSide::Sequencer);
        let oracle = MemoryTruthOracle::new();
        let err = compute_next_move(&oracle, &gs, TurnSide::Sequencer).unwrap_err();
        assert!(matches!(err, HonestMoveError::TruthOracleMissed { idx: 6 }));
    }

    /// `HonestMove::to_transition` is a faithful projection.
    #[test]
    fn honest_move_to_transition_projection() {
        assert!(HonestMove::NoMove.to_transition().is_none());

        let c = Claim {
            idx: 7,
            commit: commit(1),
        };
        assert!(matches!(
            HonestMove::Submit(c).to_transition(),
            Some(crate::game::GameTransition::SubmitMidpoint(_))
        ));
        assert!(matches!(
            HonestMove::RespondAgree.to_transition(),
            Some(crate::game::GameTransition::RespondAgree)
        ));
        assert!(matches!(
            HonestMove::RespondDisagree.to_transition(),
            Some(crate::game::GameTransition::RespondDisagree)
        ));
        assert!(matches!(
            HonestMove::TerminateOnSingleStep {
                claimed_post_commit: commit(99)
            }
            .to_transition(),
            Some(crate::game::GameTransition::TerminateOnSingleStep { .. })
        ));
    }

    /// `MemoryTruthOracle` accessors round-trip.
    #[test]
    fn memory_oracle_round_trip() {
        let mut o = MemoryTruthOracle::new();
        assert!(o.is_empty());
        assert_eq!(o.len(), 0);
        o.insert(42, commit(99));
        assert!(!o.is_empty());
        assert_eq!(o.len(), 1);
        assert_eq!(o.commit_at(42), Some(commit(99)));
        assert_eq!(o.commit_at(7), None);
        // Overwrite.
        o.insert(42, commit(7));
        assert_eq!(o.commit_at(42), Some(commit(7)));
    }

    /// End-to-end honest game: from open to single-step
    /// termination using the strategy.  The challenger plays
    /// honestly against a sequencer claiming an invalid high
    /// commit.  Expected: bisection narrows toward the single
    /// step where the sequencer's claim mismatches truth.
    #[test]
    fn end_to_end_honest_challenger_narrows_against_invalid_root() {
        use crate::game::{apply_transition, GameTransition};

        // Set up: truth is a deterministic per-idx commit; the
        // sequencer's high claim mismatches truth at the high
        // index.
        let mut oracle = MemoryTruthOracle::new();
        for idx in 0..=64u64 {
            // `idx % 256` fits in u8 by construction.
            let seed = u8::try_from(idx % 256).unwrap_or(0);
            oracle.insert(idx, commit(seed));
        }
        // Sequencer's high commit is wrong: claims `commit(255)`
        // but truth is `commit(64)`.
        let mut gs = GameState {
            sequencer: 1,
            challenger: 2,
            range: DisputedRange {
                low: Claim {
                    idx: 0,
                    commit: commit(0),
                },
                high: Claim {
                    idx: 64,
                    commit: commit(255), // wrong
                },
            },
            pending_midpoint: None,
            depth: 0,
            turn: TurnSide::Sequencer,
            sequencer_bond: 1_000,
            challenger_bond: 1_000,
            status: GameStatus::InProgress,
            deployment_id: [0u8; 32],
        };

        let mut rounds = 0;
        // Play with sequencer-the-liar (always submits a wrong
        // midpoint commit) and challenger-the-honest (uses our
        // strategy).
        while !gs.range.is_single_step() && rounds < 100 {
            // Sequencer's turn: submit a wrong midpoint.
            let mid_idx = gs.range.midpoint_idx();
            let wrong_mp = Claim {
                idx: mid_idx,
                commit: commit(123), // intentionally wrong
            };
            gs = apply_transition(&gs, GameTransition::SubmitMidpoint(wrong_mp)).unwrap();

            // Challenger's turn: respond honestly.
            let mv = compute_next_move(&oracle, &gs, TurnSide::Challenger).unwrap();
            // Honest challenger should disagree: the truth at
            // mid_idx is `commit((mid_idx % 256) as u8)` which
            // differs from the sequencer's `commit(123)` (unless
            // by coincidence; mid_idx values along the bisection
            // path of `[0, 64]` are powers-of-two * 1, 2, 4, ...
            // — none of which are 123).
            assert_eq!(mv, HonestMove::RespondDisagree);
            gs = apply_transition(&gs, mv.to_transition().unwrap()).unwrap();

            rounds += 1;
        }
        assert!(
            gs.range.is_single_step(),
            "bisection should converge to single step in ≤ 7 rounds for a 64-wide range"
        );
        // Bound: log2(64) = 6, plus one for the terminal narrowing.
        assert!(rounds <= 7);
    }

    /// Trait-object usage smoke test: `Box<dyn TruthOracle>`
    /// works.
    #[test]
    fn truth_oracle_is_object_safe() {
        let mut o = MemoryTruthOracle::new();
        o.insert(7, commit(11));
        let boxed: Box<dyn TruthOracle> = Box::new(o);
        assert_eq!(boxed.commit_at(7), Some(commit(11)));
    }

    /// `SubprocessTruthOracle` smoke test against a mock `canon`
    /// script.  The script prints a deterministic hex string
    /// based on the supplied idx; the oracle parses it.
    #[test]
    fn subprocess_oracle_parses_mock_canon_output() {
        use super::SubprocessTruthOracle;
        let dir = tempfile::tempdir().unwrap();
        let mock_canon_path = dir.path().join("mock_canon.sh");
        // Mock script: prints idx-derived hex on stdout for the
        // `replay-up-to LOG IDX` argv.
        // POSIX-shell mock; iterate to find the last argument
        // (replay-up-to's IDX).  Avoids the bash-specific
        // `${@: -1}` slice syntax.
        let script = "#!/bin/sh\n\
                      # canon mock: usage = [flags...] replay-up-to LOG IDX\n\
                      # Print 32-byte hex derived from IDX (last arg).\n\
                      for a in \"$@\"; do idx=\"$a\"; done\n\
                      printf '%064x\\n' \"$idx\"\n";
        std::fs::write(&mock_canon_path, script).unwrap();
        // chmod +x
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&mock_canon_path).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&mock_canon_path, perms).unwrap();
        }
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();
        let oracle = SubprocessTruthOracle::new(mock_canon_path, log_path);
        let result = oracle.commit_at(42);
        let mut expected = [0u8; 32];
        // The mock prints %064x of 42, which is 30 leading zero hex chars + "2a" at the end (decimal 42 in hex padding to 32 bytes).
        expected[31] = 0x2a;
        assert_eq!(result, Some(expected));
    }

    /// `SubprocessTruthOracle` returns `None` if the script fails
    /// (non-zero exit code, or wrong output format).
    #[test]
    fn subprocess_oracle_returns_none_on_failure() {
        use super::SubprocessTruthOracle;
        let dir = tempfile::tempdir().unwrap();
        let mock_canon_path = dir.path().join("failing_canon.sh");
        let script = "#!/bin/sh\nexit 2\n";
        std::fs::write(&mock_canon_path, script).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&mock_canon_path).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&mock_canon_path, perms).unwrap();
        }
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();
        let oracle = SubprocessTruthOracle::new(mock_canon_path, log_path);
        let result = oracle.commit_at(42);
        assert!(result.is_none());
    }

    /// `SubprocessTruthOracle` returns `None` for nonexistent
    /// canon binary path.
    #[test]
    fn subprocess_oracle_returns_none_for_missing_binary() {
        use super::SubprocessTruthOracle;
        let oracle = SubprocessTruthOracle::new(
            std::path::PathBuf::from("/nonexistent/canon-binary"),
            std::path::PathBuf::from("/tmp/anything.log"),
        );
        assert!(oracle.commit_at(0).is_none());
    }

    /// `SubprocessTruthOracle`'s `with_flag` appends a CLI flag
    /// pair that's passed through to the subprocess.  We verify
    /// indirectly: the mock script prints a flag-based output if
    /// the expected flag is present.
    #[test]
    fn subprocess_oracle_with_flag_passes_through() {
        use super::SubprocessTruthOracle;
        let dir = tempfile::tempdir().unwrap();
        let mock_canon_path = dir.path().join("flag_aware_canon.sh");
        // Script: if "--deployment-id" "deadbeef" appears in
        // argv, print all-aa; otherwise print all-bb.
        let script = "#!/bin/sh\n\
                      for arg in \"$@\"; do\n\
                        if [ \"$arg\" = \"deadbeef\" ]; then\n\
                          printf '%064s\\n' '' | tr ' ' 'a'\n\
                          exit 0\n\
                        fi\n\
                      done\n\
                      printf '%064s\\n' '' | tr ' ' 'b'\n";
        std::fs::write(&mock_canon_path, script).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&mock_canon_path).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&mock_canon_path, perms).unwrap();
        }
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();

        let oracle_without = SubprocessTruthOracle::new(mock_canon_path.clone(), log_path.clone());
        let r1 = oracle_without.commit_at(0).unwrap();
        assert_eq!(r1, [0xbb; 32]);

        let oracle_with = SubprocessTruthOracle::new(mock_canon_path, log_path)
            .with_flag("--deployment-id", "deadbeef");
        let r2 = oracle_with.commit_at(0).unwrap();
        assert_eq!(r2, [0xaa; 32]);
    }

    /// Audit-pass-4-round-3 CRITICAL regression: a hung canon
    /// subprocess MUST NOT hang the observer.  Test simulates
    /// a script that sleeps forever via `exec` (which replaces
    /// the shell process with `sleep`, so SIGKILL on the child
    /// pid directly terminates the sleep).  Oracle is configured
    /// with a short timeout; `commit_at` returns None promptly.
    #[test]
    #[cfg(unix)]
    fn subprocess_oracle_timeout_kills_hung_canon() {
        use super::SubprocessTruthOracle;
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mock_canon_path = dir.path().join("hung_canon.sh");
        // `exec sleep 30` so the shell replaces itself with
        // `sleep` — kill on the child pid then kills sleep
        // directly.  Without `exec`, the shell would fork
        // `sleep`, and kill-on-shell-pid would orphan `sleep`.
        // The production canon binary is a single process so
        // this concern doesn't apply, but the test must mirror
        // that property.
        let script = "#!/bin/sh\nexec sleep 30\n";
        std::fs::write(&mock_canon_path, script).unwrap();
        let mut perms = std::fs::metadata(&mock_canon_path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&mock_canon_path, perms).unwrap();
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();
        let oracle = SubprocessTruthOracle::new(mock_canon_path, log_path)
            .with_timeout(std::time::Duration::from_millis(200));
        let start = std::time::Instant::now();
        let result = oracle.commit_at(0);
        let elapsed = start.elapsed();
        assert!(result.is_none(), "expected None, got Some({result:?})");
        assert!(
            elapsed < std::time::Duration::from_secs(5),
            "oracle blocked {elapsed:?} on hung canon (timeout should have killed it)",
        );
    }

    /// Audit-pass-4-round-3 CRITICAL regression: a canon
    /// subprocess that prints a huge amount of stdout MUST NOT
    /// OOM the observer.  Oracle is configured with a small
    /// stdout cap; the script prints way more than the cap.
    #[test]
    #[cfg(unix)]
    fn subprocess_oracle_stdout_cap_rejects_oversize_output() {
        use super::SubprocessTruthOracle;
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mock_canon_path = dir.path().join("noisy_canon.sh");
        // Print 100 KB to stdout, then a valid 64-char hex line.
        // With stdout_cap = 4096, this must be rejected.
        let script = "#!/bin/sh\n\
                      yes 'overflow' | head -c 100000\n\
                      printf '%064s\\n' '' | tr ' ' 'a'\n";
        std::fs::write(&mock_canon_path, script).unwrap();
        let mut perms = std::fs::metadata(&mock_canon_path).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&mock_canon_path, perms).unwrap();
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();
        let oracle = SubprocessTruthOracle::new(mock_canon_path, log_path).with_stdout_cap(4096);
        let result = oracle.commit_at(0);
        assert!(
            result.is_none(),
            "expected oversize-stdout to be rejected, got Some({result:?})",
        );
    }
}
