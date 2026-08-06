// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

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
//!   * [`SubprocessTruthOracle`] — spawns `knomosis replay-up-to LOG IDX`
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

/// Blanket impl: any [`Box`]ed [`TruthOracle`] is itself a
/// `TruthOracle`.  Required so that production callers can
/// runtime-select between [`MemoryTruthOracle`] and
/// [`SubprocessTruthOracle`] via `Box<dyn TruthOracle>` instead
/// of monomorphising the [`crate::observer::Observer`]
/// generic for every concrete combination.
impl<T: TruthOracle + ?Sized> TruthOracle for Box<T> {
    fn commit_at(&self, idx: LogIndex) -> Option<StateCommit> {
        (**self).commit_at(idx)
    }
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
/// `knomosis replay-up-to LOG IDX` Lean subcommand to obtain the
/// canonical state commit at a log index.  Closes the RH-G.4
/// plan's "Invoke `knomosis` subprocess with `--replay-up-to
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
/// whatever `knomosis` binary the operator points at via
/// `SubprocessTruthOracle::new(knomosis_path, log_path)`.  The
/// caller is responsible for ensuring the binary's
/// `knomosis replay-up-to` subcommand matches the deployment's
/// expected output format.  Mismatch (e.g., the operator
/// pointing at a pre-RH-G knomosis binary) surfaces as
/// `TruthOracleMissed`.
/// Default `knomosis replay-up-to` invocation timeout.  Per the
/// audit-pass-4-round-3 CRITICAL fix: prevent a wedged knomosis
/// binary from hanging the observer's orchestrator loop.
///
/// Defaults to 30 s, which is generous for any real-world log
/// replay (a 1-second poll loop with this oracle would have
/// already detected the hang).
pub const DEFAULT_SUBPROCESS_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Default stdout size cap.  Per audit-pass-4-round-3 CRITICAL
/// fix: the canonical `knomosis replay-up-to` output is exactly
/// 65 bytes ("0123…cdef\n" = 64 hex chars + newline).  We
/// reserve generous headroom for future format extensions
/// (e.g., a multiline output with diagnostic prefix).  An
/// adversarial / buggy knomosis binary that prints multi-MB
/// stdout would OOM the observer; this cap prevents that.
pub const DEFAULT_SUBPROCESS_STDOUT_CAP: usize = 4096;

/// Maximum time the post-exit stdout drain may take.  Audit-pass-
/// 4-round-4 CRITICAL: defends against the orphan-pipe scenario
/// where a subprocess child (an operator wrapping `knomosis` in a
/// shell without `exec`) inherits the stdout fd and keeps it open
/// even after the parent shell is killed.  Without this timeout,
/// the post-exit drain blocks until the orphan dies.
const DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(500);

/// Poll interval for the post-exit drain timeout loop.
const DRAIN_POLL: std::time::Duration = std::time::Duration::from_millis(10);

/// Production truth oracle that shells out to a `knomosis` binary
/// for `replay-up-to` truth computation.  Includes a subprocess
/// timeout and a stdout size cap (audit-pass-4-round-3
/// hardening: prevents a hung / misbehaving knomosis binary from
/// wedging or `OOM`-ing the observer).
#[allow(clippy::module_name_repetitions)]
pub struct SubprocessTruthOracle {
    knomosis_path: std::path::PathBuf,
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
    /// Construct from the knomosis binary path and the log file
    /// path.  Operators typically pre-stage both before
    /// starting the observer.
    #[must_use]
    pub fn new(knomosis_path: std::path::PathBuf, log_path: std::path::PathBuf) -> Self {
        Self {
            knomosis_path,
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
    /// with a knomosis binary that emits diagnostic prose should
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
        // Audit-pass-4-round-6 CRITICAL fix: spawn the stdout
        // drain BEFORE the wait-loop, not after.  Previously,
        // the parent waited for child exit BEFORE reading
        // stdout — but if the child wrote more than the pipe
        // buffer (~64 KiB on Linux), the child would block on
        // a full pipe and the parent's wait-loop would block
        // until the default 30 s timeout.  This deadlock applied
        // to ANY knomosis binary emitting >64 KiB stdout, not just
        // adversarial ones.
        //
        // The drain thread captures up to `cap+1` bytes and
        // then continues consuming (discarding) the remaining
        // stdout so the child can finish writing without
        // blocking.  We then evaluate the captured bytes
        // against the cap after the child exits.
        //
        // The knomosis binary is expected to run as a single
        // process that exits quickly (≪ DEFAULT_SUBPROCESS_TIMEOUT).
        // We put it in its own process group via
        // `process_group(0)` (Unix) so that `kill` on timeout
        // propagates to any subprocess children — defends against
        // a shell-wrapper that forks `sleep` or similar.
        use std::process::Stdio;
        let mut cmd = std::process::Command::new(&self.knomosis_path);
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

        // Spawn the drain thread IMMEDIATELY so the child can
        // write its full stdout without blocking on a full pipe
        // buffer.  The drain thread keeps consuming bytes after
        // hitting `cap+1` (in discard mode) so the child never
        // stalls — but it never grows the captured `Vec` past
        // `cap+1` bytes, defending against multi-MB outputs.
        let drain_handle: Option<std::thread::JoinHandle<Vec<u8>>> =
            child.stdout.take().map(|stdout_pipe| {
                let cap = self.stdout_cap;
                std::thread::spawn(move || -> Vec<u8> {
                    use std::io::Read;
                    let mut pipe = stdout_pipe;
                    let mut out: Vec<u8> = Vec::with_capacity(cap.saturating_add(1).min(8192));
                    let mut chunk = [0u8; 4096];
                    let target = cap.saturating_add(1);
                    loop {
                        match pipe.read(&mut chunk) {
                            Ok(0) | Err(_) => break, // EOF or read error
                            Ok(n) => {
                                if out.len() < target {
                                    let take = (target - out.len()).min(n);
                                    out.extend_from_slice(&chunk[..take]);
                                }
                                // Past `target`: keep consuming
                                // to unblock the writer, but don't
                                // grow `out` further.
                            }
                        }
                    }
                    out
                })
            });

        // Poll-loop with timeout for child exit.
        let poll_interval = std::time::Duration::from_millis(25);
        let exit_status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Some(status),
                Ok(None) => {
                    if start.elapsed() >= self.timeout {
                        // Timeout: SIGKILL the child.  The child
                        // was placed in its own process group via
                        // `process_group(0)` above (Unix) so the
                        // SIGKILL targets the leader cleanly.
                        //
                        // ## Operational assumption
                        //
                        // The production knomosis binary is a SINGLE
                        // PROCESS — not a shell wrapper that forks
                        // subprocesses.  Under this assumption,
                        // killing the leader is sufficient and the
                        // background drain gets a clean EOF
                        // because no other process holds the stdout
                        // pipe's write end.
                        //
                        // If a future operator wraps knomosis in a
                        // shell (e.g., `#!/bin/sh\n exec knomosis ...`),
                        // the `exec` must be present so the shell
                        // is REPLACED by knomosis — otherwise the
                        // shell would fork knomosis and SIGKILL on
                        // the shell would leave knomosis as an
                        // orphan, holding the stdout pipe open
                        // and blocking the drain for up to knomosis's
                        // full runtime (potentially defeating the
                        // timeout).  This is a documented operator
                        // contract, not a defensive check.
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
        // Join the drain thread after the child has exited (or
        // been SIGKILLed).  Audit-pass-4-round-4 CRITICAL: bound
        // the join via `DRAIN_TIMEOUT` so an orphan-pipe scenario
        // (an operator who wraps knomosis in a shell without `exec`,
        // with the inner process inheriting stdout) cannot block
        // this function indefinitely.
        let stdout_bytes: Vec<u8> = match drain_handle {
            None => Vec::new(),
            Some(handle) => {
                let drain_start = std::time::Instant::now();
                loop {
                    if handle.is_finished() {
                        // Safe to join: thread has exited, join is
                        // immediate.
                        break handle.join().unwrap_or_default();
                    }
                    if drain_start.elapsed() >= DRAIN_TIMEOUT {
                        // Drain stuck — orphan-pipe scenario.  Abandon
                        // the thread (it's blocked on read; the OS
                        // will reap it when the pipe eventually
                        // closes).  Return None to the caller.
                        return None;
                    }
                    std::thread::sleep(DRAIN_POLL);
                }
            }
        };

        let status = exit_status?;
        if !status.success() {
            return None;
        }
        if stdout_bytes.len() > self.stdout_cap {
            // Refuse to parse oversize output — defensive against
            // a misbehaving knomosis binary.
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

/// One cell-proof entry within a [`TerminateBundle`].  Mirrors
/// the JSON wire format the Lean side's
/// `LegalKernel.Runtime.CellProofJson.formatCellProofJson` emits
/// + the existing [`crate::submitter::CellProof`] struct.
///
/// We re-use [`crate::submitter::CellProof`] directly (since it
/// already deserializes the same JSON shape with the same
/// snake_case field names) so the bundle parser doesn't need a
/// parallel type.
///
/// Note: this docstring is informational; the actual type used
/// by [`TerminateBundle`] is [`crate::submitter::CellProof`].
#[doc(hidden)]
#[allow(dead_code)]
pub(crate) struct _TerminateBundleCellProofDocsAnchor;

/// A canonical bundle of inputs the off-chain observer submits
/// to `KnomosisFaultProofGame.terminateOnSingleStep` on L1.
///
/// Built from a `(pre-state, log-entry)` pair on the Lean side
/// via `LegalKernel.FaultProof.TerminateBundle.buildTerminateBundle`,
/// then emitted as JSON by the `knomosis export-terminate-bundle
/// LOG IDX` subcommand.  The Rust observer consumes the JSON via
/// [`TerminateBundleOracle::terminate_bundle_at`].
///
/// Field encodings (matches the Lean emitter, Workstream SVC.3):
///
///   * `fixture_id` — operator-supplied identifier, free-form.
///   * `action_kind` — 0..24 dispatcher byte (Solidity
///     `actionKind` parameter; widened from 0..18 by Workstream
///     GP — indices 19 (`DepositWithFee`), 20
///     (`TopUpActionBudget`), 21 (`TopUpActionBudgetFor`),
///     22 (`ClaimBudgetRefund`), and 23 (`AmmSwap`)).
///   * `action_fields` — canonical byte layout the L1 `_stepXX`
///     decoder consumes.
///   * `signer` — the action's signer's `ActorId` (`u64`).
///   * `expected_post_commit` — the Lean-computed step-VM hash
///     for the step.  Under the production keccak256 binding,
///     this byte-equals what `KnomosisStepVM.executeStep` returns.
///   * `cell_proofs` — cell-proof bundle for the action's
///     required cells, witnessed by the pre-state.
#[derive(Clone, Debug, Default, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct TerminateBundle {
    /// Operator-supplied identifier (e.g. `"log[7]"`).  Free-form;
    /// used for logging.
    pub fixture_id: String,
    /// Action dispatcher byte (0..24 post-Workstream-GP) — the
    /// Solidity `actionKind` argument.  The range widened from
    /// 0..18 by Workstream GP — indices 19 (`DepositWithFee`),
    /// 20 (`TopUpActionBudget`), 21 (`TopUpActionBudgetFor`),
    /// 22 (`ClaimBudgetRefund`), and 23 (`AmmSwap`).
    pub action_kind: u8,
    /// Canonical byte layout the L1 `_stepXX` decoder consumes.
    ///
    /// JSON wire format: Lean emits as a lowercase hex string
    /// (no `0x` prefix).
    #[serde(
        rename = "action_fields_hex",
        serialize_with = "serialize_bytes_hex_lower",
        deserialize_with = "deserialize_bytes_hex_or_array"
    )]
    pub action_fields: Vec<u8>,
    /// The action's signer's `ActorId` (`u64` per the kernel's
    /// 64-bit actor-id convention).
    pub signer: u64,
    /// The Lean-computed step-VM hash for this step.  Under the
    /// production keccak256 binding, this is what the L1 step VM
    /// returns on the same inputs.
    ///
    /// JSON wire format: Lean emits as a 64-hex-char string
    /// (lowercase, no `0x` prefix).
    #[serde(
        rename = "expected_post_commit_hex",
        serialize_with = "serialize_bytes32_hex_lower",
        deserialize_with = "deserialize_bytes32_hex_or_array"
    )]
    pub expected_post_commit: [u8; 32],
    /// The step's FRONTIER: every cell it opens, with its proven
    /// PRE-state value, in path order.
    ///
    /// Replaced a `policy_opening` + `cell_proofs` pair.  The
    /// read-only budget-policy cell is IN here rather than beside it —
    /// under a multiproof a read is a write of the same value — and a
    /// cell the step writes twice (a self-transfer, which anyone can
    /// submit) appears ONCE, because every opening is against the same
    /// root and the second carried no information the first did not.
    ///
    /// Order is free on the wire: the L1 sorts by path index.  The
    /// builder emits path order anyway, which is what the walk
    /// consumes.
    pub opened_cells: Vec<crate::submitter::OpenedCell>,
    /// The shared wire's gap mask: one bit per gap, LSB-first within
    /// each byte, set iff that gap's sibling is drawn from
    /// [`Self::siblings`] rather than being the canonical empty
    /// sub-tree at its level.
    ///
    /// Its length is `ceil(G/8)` for a gap count `G` the KEY SET
    /// determines, so the L1 derives the expected length before
    /// reading a byte and refuses a wire of any other size.
    ///
    /// JSON wire format: a lowercase hex string (no `0x` prefix).
    #[serde(
        rename = "gap_mask_hex",
        serialize_with = "serialize_bytes_hex_lower",
        deserialize_with = "deserialize_bytes_hex_or_array"
    )]
    pub gap_mask: Vec<u8>,
    /// The shared wire's siblings: the packed non-canonical-empty
    /// sub-tree roots, in gap order, 32 bytes each.
    ///
    /// One list for the whole bundle rather than one path per opening.
    /// Sound because every sibling is the root of a sub-tree holding no
    /// opened cell, so the step's writes cannot move it and the pre-
    /// and post-folds share it.
    ///
    /// JSON wire format: a lowercase hex string (no `0x` prefix).
    #[serde(
        rename = "siblings_hex",
        serialize_with = "serialize_bytes_hex_lower",
        deserialize_with = "deserialize_bytes_hex_or_array"
    )]
    pub siblings: Vec<u8>,

    // ---- The batch binding (Workstream SB ruling R7) ----------
    //
    // Emitted by `knomosis export-terminate-bundle LOG IDX
    // PREV_END END`; absent from a bundle exported without batch
    // bounds.  ALL-OR-NOTHING: `parse_terminate_bundle_json`
    // refuses a bundle carrying some of these fields but not all,
    // and `encode_calldata_with_bundle` refuses to build terminate
    // calldata without them — the L1 authenticates the disputed
    // action by inclusion proof, so calldata without the binding
    // reverts `ActionNotInBatch`.
    /// The batch's exclusive lower bound (the parent record's key).
    #[serde(default, rename = "prev_end")]
    pub prev_end: Option<u64>,
    /// The batch's end index (the disputed L1 record's key).
    #[serde(default, rename = "end")]
    pub end_index: Option<u64>,
    /// The disputed log index, in `[prev_end, end)`.  Cross-checked
    /// against the requested index.
    #[serde(default, rename = "batch_idx")]
    pub batch_idx: Option<u64>,
    /// The batch's actions root, as the L1 record committed it.
    /// Not calldata — retained so the observer can cross-check the
    /// inclusion wire against the on-chain record before
    /// broadcasting.
    #[serde(
        default,
        rename = "actions_root_hex",
        serialize_with = "serialize_opt_bytes32_hex_lower",
        deserialize_with = "deserialize_opt_bytes32_hex_or_array",
        skip_serializing_if = "Option::is_none"
    )]
    pub actions_root: Option<[u8; 32]>,
    /// The disputed action's SMT key (`actionKey idx`).  Not
    /// calldata — the L1 re-derives the key from the step index.
    #[serde(
        default,
        rename = "action_key_hex",
        serialize_with = "serialize_opt_bytes32_hex_lower",
        deserialize_with = "deserialize_opt_bytes32_hex_or_array",
        skip_serializing_if = "Option::is_none"
    )]
    pub action_key: Option<[u8; 32]>,
    /// The signature-bound leaf commit.  Not calldata — the L1
    /// re-derives the leaf from the `(kind, fields, signer, sig)`
    /// it is handed.
    #[serde(
        default,
        rename = "leaf_commit_hex",
        serialize_with = "serialize_opt_bytes32_hex_lower",
        deserialize_with = "deserialize_opt_bytes32_hex_or_array",
        skip_serializing_if = "Option::is_none"
    )]
    pub leaf_commit: Option<[u8; 32]>,
    /// The action's signature, verbatim from the log entry —
    /// CALLDATA (the leaf binds it, fixed 65-byte width).
    #[serde(
        default,
        rename = "action_sig_hex",
        serialize_with = "serialize_opt_bytes_hex_lower",
        deserialize_with = "deserialize_opt_action_wire_hex",
        skip_serializing_if = "Option::is_none"
    )]
    pub action_sig: Option<Vec<u8>>,
    /// The inclusion wire's 32-byte bitmask — CALLDATA (the first
    /// 32 bytes of the L1's single `actionProof` argument).
    #[serde(
        default,
        rename = "action_gap_mask_hex",
        serialize_with = "serialize_opt_bytes_hex_lower",
        deserialize_with = "deserialize_opt_action_wire_hex",
        skip_serializing_if = "Option::is_none"
    )]
    pub action_gap_mask: Option<Vec<u8>>,
    /// The inclusion wire's packed siblings — CALLDATA (the
    /// remainder of `actionProof`).
    #[serde(
        default,
        rename = "action_siblings_hex",
        serialize_with = "serialize_opt_bytes_hex_lower",
        deserialize_with = "deserialize_opt_action_wire_hex",
        skip_serializing_if = "Option::is_none"
    )]
    pub action_siblings: Option<Vec<u8>>,
}

impl TerminateBundle {
    /// True iff the bundle carries the (validated, all-or-nothing)
    /// batch binding.  A `true` from a bundle that passed
    /// [`parse_terminate_bundle_json`] means every binding field is
    /// present and well-formed.
    #[must_use]
    pub fn has_batch_binding(&self) -> bool {
        self.action_sig.is_some()
    }
}

/// Maximum total bytes the bundle parser will admit from a
/// single JSON object.  Audit-pass-4-round-4 / SVC.4.f
/// defensive cap: a malicious / misconfigured knomosis subprocess
/// could emit a multi-megabyte JSON document and force a large
/// allocation in the observer.  Real terminate bundles ship
/// `≤ MAX_CELL_PROOFS_PER_STEP × ≤ 4 KiB ≈ 1 MiB` worst case;
/// we cap at 8 MiB for generous headroom while still bounding
/// pathological inputs.
pub const MAX_TERMINATE_BUNDLE_JSON_BYTES: usize = 8 * 1024 * 1024;

/// Maximum bytes in [`TerminateBundle::action_fields`].  The L1
/// step VM's `_decodeUint64BE` reads at most 32 bytes of header
/// plus a variable trailer (`newKey`/`pk`/`recipientL1`) capped
/// by the kernel's encoder.  Public-key trailers are 33 bytes
/// (`SEC1`-compressed); `EthAddress` is 20; `bindingHash` is 32.
/// We cap at 4 KiB as defense-in-depth.
pub const MAX_TERMINATE_BUNDLE_ACTION_FIELDS_BYTES: usize = 4 * 1024;

/// Maximum opened cells per terminate bundle.  Mirrors Solidity's
/// `KnomosisStepVMRoot.MAX_CELL_OPENINGS = 32`, which the contract's
/// `assertConsistent` in turn checks against the widest write set any
/// adjudicable variant produces (seven, including the policy cell).
///
/// Far below the chained path's 272: that bound counted per-WRITE
/// openings for the bulk variants, and a frontier counts distinct
/// cells for the adjudicable ones only.
pub const MAX_TERMINATE_BUNDLE_OPENED_CELLS: usize = 32;

/// Maximum gap-mask bytes.  The gap count is at most
/// `(256 + 1) - m + 255 * (m - 1)` — one full path per cell, less the
/// merges — so `ceil(G/8)` tops out just under `32 * m`.  Capped
/// generously against `MAX_TERMINATE_BUNDLE_OPENED_CELLS`.
pub const MAX_TERMINATE_BUNDLE_GAP_MASK_BYTES: usize = 32 * MAX_TERMINATE_BUNDLE_OPENED_CELLS;

/// Maximum sibling bytes: 32 per set mask bit, and at most every gap
/// is set.
pub const MAX_TERMINATE_BUNDLE_SIBLINGS_BYTES: usize = 8 * 32 * MAX_TERMINATE_BUNDLE_GAP_MASK_BYTES;

/// The fixed action-signature width the batch leaf binds (SB ruling
/// R7): `r ‖ s ‖ v`.  The L1 (`ActionsRoot.actionLeafCommit`)
/// REVERTS on any other width — the fixed width is what keeps the
/// leaf pre-image's `fields ‖ sig` split injective — so a bundle
/// carrying a different width is refused before it can become
/// calldata that loses the game.
pub const TERMINATE_BUNDLE_ACTION_SIG_BYTES: usize = 65;

/// Maximum bytes any single batch-binding wire field
/// (`action_sig_hex` / `action_gap_mask_hex` /
/// `action_siblings_hex`) may carry.  The inclusion wire is one
/// 256-level SMT path: a 32-byte bitmask plus at most 256 32-byte
/// siblings (8 KiB).  Deliberately its own bound rather than a
/// reuse of the 4 KiB `action_fields` cap: a full-depth sibling
/// list does not fit under that one, and its error text names the
/// wrong field.
pub const MAX_TERMINATE_BUNDLE_ACTION_WIRE_BYTES: usize = 256 * 32;

/// Errors the [`TerminateBundleOracle`] surfaces.
#[derive(Debug, thiserror::Error)]
pub enum TerminateBundleError {
    /// The oracle does not yet have the bundle for the requested
    /// log index (e.g., the knomosis subprocess hasn't been invoked
    /// or returned an empty response).  Caller should defer.
    #[error("terminate bundle oracle missed at log index {idx}")]
    Missed {
        /// The requested log index.
        idx: LogIndex,
    },
    /// The subprocess returned malformed JSON.
    #[error("subprocess returned malformed JSON for log index {idx}: {detail}")]
    Malformed {
        /// The requested log index.
        idx: LogIndex,
        /// Brief diagnostic.
        detail: String,
    },
    /// The subprocess returned a bundle whose declared size
    /// exceeded a defensive cap.
    #[error(
        "subprocess returned oversize bundle for log index {idx}: {observed} bytes \
         exceeds cap {cap}"
    )]
    Oversize {
        /// The requested log index.
        idx: LogIndex,
        /// The observed JSON size.
        observed: usize,
        /// The cap that was exceeded.
        cap: usize,
    },
}

/// Serialize a `Vec<u8>` as a lowercase hex string (no `0x`
/// prefix).  Same shape as Lean's `bytesHex`.
fn serialize_bytes_hex_lower<S: serde::Serializer>(
    value: &[u8],
    ser: S,
) -> Result<S::Ok, S::Error> {
    ser.serialize_str(&hex::encode(value))
}

/// Deserialize a `Vec<u8>` from either a hex string (Lean's wire
/// form) or a JSON byte-array (Rust round-trip).
fn deserialize_bytes_hex_or_array<'de, D: serde::Deserializer<'de>>(
    de: D,
) -> Result<Vec<u8>, D::Error> {
    use serde::de::Error as _;
    use serde::Deserialize as _;
    #[derive(serde::Deserialize)]
    #[serde(untagged)]
    enum HexOrArray {
        Str(String),
        Arr(Vec<u8>),
    }
    let value = HexOrArray::deserialize(de)?;
    let bytes = match value {
        HexOrArray::Str(s) => {
            let trimmed = s.strip_prefix("0x").unwrap_or(&s);
            if trimmed.len() > MAX_TERMINATE_BUNDLE_ACTION_FIELDS_BYTES.saturating_mul(2) {
                return Err(D::Error::custom(format!(
                    "action_fields hex string exceeds cap: {} > {}",
                    trimmed.len(),
                    MAX_TERMINATE_BUNDLE_ACTION_FIELDS_BYTES.saturating_mul(2)
                )));
            }
            hex::decode(trimmed)
                .map_err(|e| D::Error::custom(format!("invalid hex action_fields: {e}")))?
        }
        HexOrArray::Arr(v) => v,
    };
    if bytes.len() > MAX_TERMINATE_BUNDLE_ACTION_FIELDS_BYTES {
        return Err(D::Error::custom(format!(
            "action_fields bytes exceed cap: {} > {}",
            bytes.len(),
            MAX_TERMINATE_BUNDLE_ACTION_FIELDS_BYTES
        )));
    }
    Ok(bytes)
}

/// Serialize a 32-byte commit as a lowercase hex string (no
/// `0x` prefix).
fn serialize_bytes32_hex_lower<S: serde::Serializer>(
    value: &[u8; 32],
    ser: S,
) -> Result<S::Ok, S::Error> {
    ser.serialize_str(&hex::encode(value))
}

/// Deserialize a 32-byte commit from hex (Lean wire form) or
/// array (Rust round-trip).
fn deserialize_bytes32_hex_or_array<'de, D: serde::Deserializer<'de>>(
    de: D,
) -> Result<[u8; 32], D::Error> {
    use serde::de::Error as _;
    use serde::Deserialize as _;
    #[derive(serde::Deserialize)]
    #[serde(untagged)]
    enum HexOrArray {
        Str(String),
        Arr(Vec<u8>),
    }
    let value = HexOrArray::deserialize(de)?;
    let bytes = match value {
        HexOrArray::Str(s) => {
            let trimmed = s.strip_prefix("0x").unwrap_or(&s);
            if trimmed.len() != 64 {
                return Err(D::Error::custom(format!(
                    "expected_post_commit hex must be 64 chars, got {}",
                    trimmed.len()
                )));
            }
            hex::decode(trimmed)
                .map_err(|e| D::Error::custom(format!("invalid hex commit: {e}")))?
        }
        HexOrArray::Arr(v) => v,
    };
    let arr: [u8; 32] = bytes
        .try_into()
        .map_err(|_| D::Error::custom("expected_post_commit must be exactly 32 bytes"))?;
    Ok(arr)
}

/// Serialize an optional byte vector as a lowercase hex string.
/// Paired with `skip_serializing_if = "Option::is_none"`, so the
/// `None` arm is unreachable in practice but total anyway.
///
/// The `&Option<_>` parameter is serde's `serialize_with`
/// calling convention (a reference to the FIELD type), not a
/// style choice — hence the lint allowance.
#[allow(clippy::ref_option)]
fn serialize_opt_bytes_hex_lower<S: serde::Serializer>(
    value: &Option<Vec<u8>>,
    ser: S,
) -> Result<S::Ok, S::Error> {
    match value {
        Some(v) => ser.serialize_str(&hex::encode(v)),
        None => ser.serialize_none(),
    }
}

/// Serialize an optional 32-byte word as a lowercase hex string.
/// `&Option<_>` per serde's `serialize_with` calling convention.
#[allow(clippy::ref_option)]
fn serialize_opt_bytes32_hex_lower<S: serde::Serializer>(
    value: &Option<[u8; 32]>,
    ser: S,
) -> Result<S::Ok, S::Error> {
    match value {
        Some(v) => ser.serialize_str(&hex::encode(v)),
        None => ser.serialize_none(),
    }
}

/// Deserialize an optional 32-byte word: absent keys take the serde
/// default (`None`, this fn not called); a present key must be a
/// well-formed 32-byte hex string or byte array.
fn deserialize_opt_bytes32_hex_or_array<'de, D: serde::Deserializer<'de>>(
    de: D,
) -> Result<Option<[u8; 32]>, D::Error> {
    deserialize_bytes32_hex_or_array(de).map(Some)
}

/// Deserialize an optional batch-binding wire field
/// (`action_sig_hex` / `action_gap_mask_hex` /
/// `action_siblings_hex`), capped at
/// [`MAX_TERMINATE_BUNDLE_ACTION_WIRE_BYTES`].  Exact per-field
/// widths (65-byte signature, 32-byte bitmask, whole 32-byte
/// siblings) are enforced by [`parse_terminate_bundle_json`].
fn deserialize_opt_action_wire_hex<'de, D: serde::Deserializer<'de>>(
    de: D,
) -> Result<Option<Vec<u8>>, D::Error> {
    use serde::de::Error as _;
    use serde::Deserialize as _;
    #[derive(serde::Deserialize)]
    #[serde(untagged)]
    enum HexOrArray {
        Str(String),
        Arr(Vec<u8>),
    }
    let value = HexOrArray::deserialize(de)?;
    let bytes = match value {
        HexOrArray::Str(s) => {
            let trimmed = s.strip_prefix("0x").unwrap_or(&s);
            if trimmed.len() > MAX_TERMINATE_BUNDLE_ACTION_WIRE_BYTES.saturating_mul(2) {
                return Err(D::Error::custom(format!(
                    "batch-binding wire hex string exceeds cap: {} > {}",
                    trimmed.len(),
                    MAX_TERMINATE_BUNDLE_ACTION_WIRE_BYTES.saturating_mul(2)
                )));
            }
            hex::decode(trimmed)
                .map_err(|e| D::Error::custom(format!("invalid batch-binding wire hex: {e}")))?
        }
        HexOrArray::Arr(v) => v,
    };
    if bytes.len() > MAX_TERMINATE_BUNDLE_ACTION_WIRE_BYTES {
        return Err(D::Error::custom(format!(
            "batch-binding wire bytes exceed cap: {} > {}",
            bytes.len(),
            MAX_TERMINATE_BUNDLE_ACTION_WIRE_BYTES
        )));
    }
    Ok(Some(bytes))
}

/// Parse a JSON document into a [`TerminateBundle`].  Caps the
/// declared JSON size at [`MAX_TERMINATE_BUNDLE_JSON_BYTES`], the
/// frontier at [`MAX_TERMINATE_BUNDLE_OPENED_CELLS`], and both wire
/// regions at their own caps, as defense-in-depth.
///
/// The wire caps are not the L1's check and do not try to be: the
/// contract derives the EXACT mask length and sibling count from the
/// key set and refuses anything else.  These bound what a
/// misconfigured or hostile `knomosis` subprocess can make the
/// observer allocate before that check ever runs.
///
/// # Errors
///
/// Returns [`TerminateBundleError::Malformed`] on any parser
/// failure or oversize frontier / wire; returns
/// [`TerminateBundleError::Oversize`] if the JSON document
/// itself exceeds the size cap.
pub fn parse_terminate_bundle_json(
    idx: LogIndex,
    json: &str,
) -> Result<TerminateBundle, TerminateBundleError> {
    if json.len() > MAX_TERMINATE_BUNDLE_JSON_BYTES {
        return Err(TerminateBundleError::Oversize {
            idx,
            observed: json.len(),
            cap: MAX_TERMINATE_BUNDLE_JSON_BYTES,
        });
    }
    let bundle: TerminateBundle =
        serde_json::from_str(json).map_err(|e| TerminateBundleError::Malformed {
            idx,
            detail: format!("serde_json: {e}"),
        })?;
    if bundle.opened_cells.len() > MAX_TERMINATE_BUNDLE_OPENED_CELLS {
        return Err(TerminateBundleError::Malformed {
            idx,
            detail: format!(
                "opened_cells count {} exceeds cap {}",
                bundle.opened_cells.len(),
                MAX_TERMINATE_BUNDLE_OPENED_CELLS
            ),
        });
    }
    if bundle.gap_mask.len() > MAX_TERMINATE_BUNDLE_GAP_MASK_BYTES {
        return Err(TerminateBundleError::Malformed {
            idx,
            detail: format!(
                "gap_mask {} bytes exceeds cap {}",
                bundle.gap_mask.len(),
                MAX_TERMINATE_BUNDLE_GAP_MASK_BYTES
            ),
        });
    }
    if bundle.siblings.len() > MAX_TERMINATE_BUNDLE_SIBLINGS_BYTES {
        return Err(TerminateBundleError::Malformed {
            idx,
            detail: format!(
                "siblings {} bytes exceeds cap {}",
                bundle.siblings.len(),
                MAX_TERMINATE_BUNDLE_SIBLINGS_BYTES
            ),
        });
    }
    // Whole 32-byte siblings.  The L1 checks the exact COUNT against
    // the mask's popcount; this catches a truncated region before the
    // observer broadcasts calldata that would lose the game.
    if !bundle.siblings.len().is_multiple_of(32) {
        return Err(TerminateBundleError::Malformed {
            idx,
            detail: format!(
                "siblings region {} bytes is not whole 32-byte siblings",
                bundle.siblings.len()
            ),
        });
    }
    validate_batch_binding(idx, &bundle)?;
    Ok(bundle)
}

/// The batch-binding half of [`parse_terminate_bundle_json`]'s
/// validation (Workstream SB).  The binding is ALL-OR-NOTHING: the
/// CLI emits either every binding field or none, so a partial set
/// means a truncated / hand-edited document, and silently treating
/// it as unbound would turn a data error into an on-chain
/// `ActionNotInBatch` loss.
///
/// # Errors
///
/// Returns [`TerminateBundleError::Malformed`] on a partial
/// binding, a signature of any width but the fixed 65 bytes, a
/// bitmask of any width but 32, a ragged sibling region, or batch
/// bounds that exclude / contradict the requested index.
fn validate_batch_binding(
    idx: LogIndex,
    bundle: &TerminateBundle,
) -> Result<(), TerminateBundleError> {
    let binding_present = [
        bundle.prev_end.is_some(),
        bundle.end_index.is_some(),
        bundle.batch_idx.is_some(),
        bundle.actions_root.is_some(),
        bundle.action_key.is_some(),
        bundle.leaf_commit.is_some(),
        bundle.action_sig.is_some(),
        bundle.action_gap_mask.is_some(),
        bundle.action_siblings.is_some(),
    ];
    if binding_present.iter().any(|p| *p) && !binding_present.iter().all(|p| *p) {
        return Err(TerminateBundleError::Malformed {
            idx,
            detail: "partial batch binding: some batch fields present but not all".to_string(),
        });
    }
    if let Some(sig) = &bundle.action_sig {
        if sig.len() != TERMINATE_BUNDLE_ACTION_SIG_BYTES {
            return Err(TerminateBundleError::Malformed {
                idx,
                detail: format!(
                    "action_sig is {} bytes; the leaf binds a fixed {}-byte signature",
                    sig.len(),
                    TERMINATE_BUNDLE_ACTION_SIG_BYTES
                ),
            });
        }
    }
    if let Some(mask) = &bundle.action_gap_mask {
        if mask.len() != 32 {
            return Err(TerminateBundleError::Malformed {
                idx,
                detail: format!(
                    "action_gap_mask is {} bytes; the inclusion wire's bitmask is exactly 32",
                    mask.len()
                ),
            });
        }
    }
    if let Some(sibs) = &bundle.action_siblings {
        if !sibs.len().is_multiple_of(32) {
            return Err(TerminateBundleError::Malformed {
                idx,
                detail: format!(
                    "action_siblings region {} bytes is not whole 32-byte siblings",
                    sibs.len()
                ),
            });
        }
    }
    if let (Some(prev_end), Some(end), Some(batch_idx)) =
        (bundle.prev_end, bundle.end_index, bundle.batch_idx)
    {
        if !(prev_end <= batch_idx && batch_idx < end) {
            return Err(TerminateBundleError::Malformed {
                idx,
                detail: format!("batch_idx {batch_idx} outside batch [{prev_end}, {end})"),
            });
        }
        if batch_idx != idx {
            return Err(TerminateBundleError::Malformed {
                idx,
                detail: format!("batch_idx {batch_idx} does not match the requested index {idx}"),
            });
        }
    }
    Ok(())
}

/// An oracle that returns the canonical terminate bundle for a
/// given log index.  The observer's
/// [`crate::observer::Observer::maybe_play_move`] consumes this
/// when computing terminate-on-single-step calldata.
///
/// # Errors
///
/// Implementations return [`TerminateBundleError::Missed`] when
/// the bundle is not yet known (the knomosis subprocess hasn't been
/// invoked, or the observer's local log hasn't caught up to the
/// requested index).  Other errors indicate operator
/// misconfiguration (malformed JSON, oversize input) and the
/// caller should surface them rather than retry.
pub trait TerminateBundleOracle {
    /// Look up the canonical terminate bundle at the given log
    /// index.  Returns [`TerminateBundleError::Missed`] if the
    /// bundle is not yet known.
    ///
    /// `batch` carries the disputed batch's `(prev_end, end)`
    /// bounds (Workstream SB): when `Some`, the produced bundle
    /// must additionally carry the action's batch binding — the
    /// signature and the inclusion wire against the batch's
    /// actions root — which the batched `terminateOnSingleStep`
    /// requires.  `None` requests a bare (pre-batching) bundle;
    /// the observer's production path always passes `Some`.
    ///
    /// # Errors
    ///
    /// See [`TerminateBundleError`].
    fn terminate_bundle_at(
        &self,
        idx: LogIndex,
        batch: Option<(LogIndex, LogIndex)>,
    ) -> Result<TerminateBundle, TerminateBundleError>;
}

/// Blanket impl: any [`Box`]ed [`TerminateBundleOracle`] is itself
/// a `TerminateBundleOracle`.  Mirrors the analogous impl for
/// [`TruthOracle`] so the observer can hold the oracle as a
/// `Box<dyn TerminateBundleOracle>` without monomorphisation
/// pressure.
impl<T: TerminateBundleOracle + ?Sized> TerminateBundleOracle for Box<T> {
    fn terminate_bundle_at(
        &self,
        idx: LogIndex,
        batch: Option<(LogIndex, LogIndex)>,
    ) -> Result<TerminateBundle, TerminateBundleError> {
        (**self).terminate_bundle_at(idx, batch)
    }
}

/// In-memory `TerminateBundleOracle`: stores a pre-computed
/// `LogIndex → TerminateBundle` map.  Used by tests + by the
/// in-memory mode of the observer (where the operator pre-stages
/// every bundle the observer might need).
#[derive(Clone, Debug, Default)]
pub struct MemoryTerminateBundleOracle {
    map: std::collections::BTreeMap<LogIndex, TerminateBundle>,
}

impl MemoryTerminateBundleOracle {
    /// Construct an empty oracle.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Insert `(idx, bundle)` into the oracle's map.  Overwrites
    /// any prior value.
    pub fn insert(&mut self, idx: LogIndex, bundle: TerminateBundle) {
        self.map.insert(idx, bundle);
    }

    /// The number of bundles cached.  Diagnostic only.
    #[must_use]
    pub fn len(&self) -> usize {
        self.map.len()
    }

    /// True iff no bundles are cached.  Diagnostic only.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

impl TerminateBundleOracle for MemoryTerminateBundleOracle {
    /// The memory oracle keys by index alone: the operator
    /// pre-stages exactly the bundle (batch-bound or not) the
    /// observer should broadcast, so the bounds are advisory here.
    fn terminate_bundle_at(
        &self,
        idx: LogIndex,
        _batch: Option<(LogIndex, LogIndex)>,
    ) -> Result<TerminateBundle, TerminateBundleError> {
        self.map
            .get(&idx)
            .cloned()
            .ok_or(TerminateBundleError::Missed { idx })
    }
}

impl SubprocessTruthOracle {
    /// Drain the subprocess's stdout into a bounded `Vec`,
    /// capped at `bundle_cap + 1` bytes.  Reads continuously so
    /// the subprocess can finish writing without blocking on a
    /// full pipe buffer (mirrors the audit-pass-4-round-6
    /// deadlock-prevention pattern from `commit_at`).
    fn spawn_bundle_drain_thread(
        stdout_pipe: std::process::ChildStdout,
        bundle_cap: usize,
    ) -> std::thread::JoinHandle<Vec<u8>> {
        std::thread::spawn(move || -> Vec<u8> {
            use std::io::Read;
            let mut pipe = stdout_pipe;
            let mut out: Vec<u8> = Vec::with_capacity(8192);
            let mut chunk = [0u8; 4096];
            let target = bundle_cap.saturating_add(1);
            loop {
                match pipe.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if out.len() < target {
                            let take = (target - out.len()).min(n);
                            out.extend_from_slice(&chunk[..take]);
                        }
                    }
                }
            }
            out
        })
    }

    /// Wait for the child to exit, bounded by `self.timeout`.
    /// On timeout / error, SIGKILL the child.  Returns `Some(status)`
    /// on clean exit, `None` on timeout or wait error.
    fn wait_for_bundle_child(
        &self,
        child: &mut std::process::Child,
    ) -> Option<std::process::ExitStatus> {
        let start = std::time::Instant::now();
        let poll_interval = std::time::Duration::from_millis(25);
        loop {
            match child.try_wait() {
                Ok(Some(status)) => return Some(status),
                Ok(None) => {
                    if start.elapsed() >= self.timeout {
                        let _ = child.kill();
                        let _ = child.wait();
                        return None;
                    }
                    std::thread::sleep(poll_interval);
                }
                Err(_) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
            }
        }
    }

    /// Join the drain thread, bounded by `DRAIN_TIMEOUT`.  Returns
    /// the captured bytes on success or an `Err` on the
    /// orphan-pipe scenario.
    fn join_bundle_drain(
        idx: LogIndex,
        drain_handle: Option<std::thread::JoinHandle<Vec<u8>>>,
    ) -> Result<Vec<u8>, TerminateBundleError> {
        match drain_handle {
            None => Ok(Vec::new()),
            Some(handle) => {
                let drain_start = std::time::Instant::now();
                loop {
                    if handle.is_finished() {
                        return Ok(handle.join().unwrap_or_default());
                    }
                    if drain_start.elapsed() >= DRAIN_TIMEOUT {
                        return Err(TerminateBundleError::Malformed {
                            idx,
                            detail:
                                "drain thread did not finish before DRAIN_TIMEOUT (orphan pipe)"
                                    .to_string(),
                        });
                    }
                    std::thread::sleep(DRAIN_POLL);
                }
            }
        }
    }

    /// Build the [`std::process::Command`] that invokes
    /// `knomosis export-terminate-bundle LOG IDX` with the configured
    /// extra flags.  Extracted so the spawn step can be tested in
    /// isolation.
    fn build_bundle_command(
        &self,
        idx: LogIndex,
        batch: Option<(LogIndex, LogIndex)>,
    ) -> std::process::Command {
        use std::process::Stdio;
        let mut cmd = std::process::Command::new(&self.knomosis_path);
        for (flag, value) in &self.extra_flags {
            cmd.arg(flag).arg(value);
        }
        cmd.arg("export-terminate-bundle")
            .arg(&self.log_path)
            .arg(idx.to_string());
        // The optional batch bounds (Workstream SB): `knomosis
        // export-terminate-bundle LOG IDX PREV_END END` makes the
        // CLI additionally emit the action's batch binding — the
        // inclusion wire the batched terminate calldata carries.
        if let Some((prev_end, end)) = batch {
            cmd.arg(prev_end.to_string()).arg(end.to_string());
        }
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::inherit());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            cmd.process_group(0);
        }
        cmd
    }
}

impl TerminateBundleOracle for SubprocessTruthOracle {
    /// Shell out to `knomosis export-terminate-bundle LOG IDX
    /// [PREV_END END]`, parse the JSON, return the bundle.
    ///
    /// Reuses the same defensive pattern as
    /// [`SubprocessTruthOracle::commit_at`]:
    ///   * Spawn the drain thread BEFORE the wait loop (audit-
    ///     pass-4-round-6 deadlock fix).
    ///   * Bounded timeout via `with_timeout`.
    ///   * Stdout cap of [`MAX_TERMINATE_BUNDLE_JSON_BYTES`] since
    ///     bundle JSON is much larger than the 64-hex-char truth
    ///     output.
    fn terminate_bundle_at(
        &self,
        idx: LogIndex,
        batch: Option<(LogIndex, LogIndex)>,
    ) -> Result<TerminateBundle, TerminateBundleError> {
        let mut cmd = self.build_bundle_command(idx, batch);
        let mut child = cmd.spawn().map_err(|e| TerminateBundleError::Malformed {
            idx,
            detail: format!("spawn failed: {e}"),
        })?;
        let drain_handle = child
            .stdout
            .take()
            .map(|pipe| Self::spawn_bundle_drain_thread(pipe, MAX_TERMINATE_BUNDLE_JSON_BYTES));
        let exit_status = self.wait_for_bundle_child(&mut child);
        let stdout_bytes = Self::join_bundle_drain(idx, drain_handle)?;

        let status = exit_status.ok_or(TerminateBundleError::Missed { idx })?;
        if !status.success() {
            return Err(TerminateBundleError::Missed { idx });
        }
        if stdout_bytes.len() > MAX_TERMINATE_BUNDLE_JSON_BYTES {
            return Err(TerminateBundleError::Oversize {
                idx,
                observed: stdout_bytes.len(),
                cap: MAX_TERMINATE_BUNDLE_JSON_BYTES,
            });
        }
        let stdout_str =
            std::str::from_utf8(&stdout_bytes).map_err(|e| TerminateBundleError::Malformed {
                idx,
                detail: format!("non-UTF-8 output: {e}"),
            })?;
        // Find the first line that starts with `{` (skip any
        // stderr-style warnings the binary might emit on stdout).
        let json_line = stdout_str
            .lines()
            .find(|l| l.trim_start().starts_with('{'))
            .ok_or(TerminateBundleError::Malformed {
                idx,
                detail: "no JSON object found in subprocess stdout".to_string(),
            })?;
        parse_terminate_bundle_json(idx, json_line)
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
        /// The honest expectation for what the L1 step VM will
        /// compute.  Local only: `terminateOnSingleStep` takes no
        /// claimed post-commit (the contract compares its own fold
        /// against the on-chain `g.high.commit`), so this never
        /// reaches the calldata — it feeds the observer's own
        /// pre-broadcast `BundleCommitMismatch` cross-check.
        expected_post_commit: StateCommit,
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
            // Only the commit: the transition derives the index.
            Self::Submit(c) => Some(GameTransition::SubmitMidpoint(c.commit)),
            Self::RespondAgree => Some(GameTransition::RespondAgree),
            Self::RespondDisagree => Some(GameTransition::RespondDisagree),
            Self::TerminateOnSingleStep {
                expected_post_commit,
            } => Some(GameTransition::TerminateOnSingleStep {
                expected_post_commit,
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
                    expected_post_commit: truth_high,
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

    /// Call `commit_at` against a freshly-written + chmod'd mock script,
    /// retrying to absorb a transient `ETXTBSY` ("text file busy") exec
    /// race.  Under parallel test execution a *different* test thread's
    /// `fork` (for its own subprocess) can momentarily hold a writable
    /// file descriptor to the just-written script, so the `spawn` inside
    /// `commit_at` fails and surfaces as `None`.  The mock script is
    /// valid, so any `None` here is that purely-environmental race — we
    /// retry a bounded number of times with a short backoff.  (Production
    /// never hits this: the real `knomosis` binary is not freshly written
    /// next to its own exec, so `commit_at` is left to fail fast there.)
    fn commit_at_retrying(oracle: &super::SubprocessTruthOracle, idx: u64) -> Option<StateCommit> {
        for _ in 0..10 {
            if let Some(c) = oracle.commit_at(idx) {
                return Some(c);
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        None
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
                expected_post_commit,
            } => {
                assert_eq!(expected_post_commit, commit(42));
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
                expected_post_commit: commit(99)
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
            // Sequencer's turn: submit a wrong midpoint COMMIT.
            // The index is not the sequencer's to choose — the
            // transition derives it — so only the commit can lie.
            gs = apply_transition(&gs, GameTransition::SubmitMidpoint(commit(123))).unwrap();

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

    /// `SubprocessTruthOracle` smoke test against a mock `knomosis`
    /// script.  The script prints a deterministic hex string
    /// based on the supplied idx; the oracle parses it.
    #[test]
    fn subprocess_oracle_parses_mock_knomosis_output() {
        use super::SubprocessTruthOracle;
        let dir = tempfile::tempdir().unwrap();
        let mock_knomosis_path = dir.path().join("mock_knomosis.sh");
        // Mock script: prints idx-derived hex on stdout for the
        // `replay-up-to LOG IDX` argv.
        // POSIX-shell mock; iterate to find the last argument
        // (replay-up-to's IDX).  Avoids the bash-specific
        // `${@: -1}` slice syntax.
        let script = "#!/bin/sh\n\
                      # knomosis mock: usage = [flags...] replay-up-to LOG IDX\n\
                      # Print 32-byte hex derived from IDX (last arg).\n\
                      for a in \"$@\"; do idx=\"$a\"; done\n\
                      printf '%064x\\n' \"$idx\"\n";
        std::fs::write(&mock_knomosis_path, script).unwrap();
        // chmod +x
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&mock_knomosis_path)
                .unwrap()
                .permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&mock_knomosis_path, perms).unwrap();
        }
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();
        let oracle = SubprocessTruthOracle::new(mock_knomosis_path, log_path);
        let result = commit_at_retrying(&oracle, 42);
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
        let mock_knomosis_path = dir.path().join("failing_knomosis.sh");
        let script = "#!/bin/sh\nexit 2\n";
        std::fs::write(&mock_knomosis_path, script).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&mock_knomosis_path)
                .unwrap()
                .permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&mock_knomosis_path, perms).unwrap();
        }
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();
        let oracle = SubprocessTruthOracle::new(mock_knomosis_path, log_path);
        let result = oracle.commit_at(42);
        assert!(result.is_none());
    }

    /// `SubprocessTruthOracle` returns `None` for nonexistent
    /// knomosis binary path.
    #[test]
    fn subprocess_oracle_returns_none_for_missing_binary() {
        use super::SubprocessTruthOracle;
        let oracle = SubprocessTruthOracle::new(
            std::path::PathBuf::from("/nonexistent/knomosis-binary"),
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
        let mock_knomosis_path = dir.path().join("flag_aware_knomosis.sh");
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
        std::fs::write(&mock_knomosis_path, script).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&mock_knomosis_path)
                .unwrap()
                .permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&mock_knomosis_path, perms).unwrap();
        }
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();

        let oracle_without =
            SubprocessTruthOracle::new(mock_knomosis_path.clone(), log_path.clone());
        let r1 = commit_at_retrying(&oracle_without, 0).unwrap();
        assert_eq!(r1, [0xbb; 32]);

        let oracle_with = SubprocessTruthOracle::new(mock_knomosis_path, log_path)
            .with_flag("--deployment-id", "deadbeef");
        let r2 = commit_at_retrying(&oracle_with, 0).unwrap();
        assert_eq!(r2, [0xaa; 32]);
    }

    /// Audit-pass-4-round-3 CRITICAL regression: a hung knomosis
    /// subprocess MUST NOT hang the observer.  Test simulates
    /// a script that sleeps forever via `exec` (which replaces
    /// the shell process with `sleep`, so SIGKILL on the child
    /// pid directly terminates the sleep).  Oracle is configured
    /// with a short timeout; `commit_at` returns None promptly.
    #[test]
    #[cfg(unix)]
    fn subprocess_oracle_timeout_kills_hung_knomosis() {
        use super::SubprocessTruthOracle;
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mock_knomosis_path = dir.path().join("hung_knomosis.sh");
        // `exec sleep 30` so the shell replaces itself with
        // `sleep` — kill on the child pid then kills sleep
        // directly.  Without `exec`, the shell would fork
        // `sleep`, and kill-on-shell-pid would orphan `sleep`.
        // The production knomosis binary is a single process so
        // this concern doesn't apply, but the test must mirror
        // that property.
        let script = "#!/bin/sh\nexec sleep 30\n";
        std::fs::write(&mock_knomosis_path, script).unwrap();
        let mut perms = std::fs::metadata(&mock_knomosis_path)
            .unwrap()
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&mock_knomosis_path, perms).unwrap();
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();
        let oracle = SubprocessTruthOracle::new(mock_knomosis_path, log_path)
            .with_timeout(std::time::Duration::from_millis(200));
        let start = std::time::Instant::now();
        let result = oracle.commit_at(0);
        let elapsed = start.elapsed();
        assert!(result.is_none(), "expected None, got Some({result:?})");
        assert!(
            elapsed < std::time::Duration::from_secs(5),
            "oracle blocked {elapsed:?} on hung knomosis (timeout should have killed it)",
        );
    }

    /// Audit-pass-4-round-3 CRITICAL regression: a knomosis
    /// subprocess that prints a huge amount of stdout MUST NOT
    /// OOM the observer.  Oracle is configured with a small
    /// stdout cap; the script prints way more than the cap.
    ///
    /// Audit-pass-4-round-6 CRITICAL regression: this test ALSO
    /// pins the deadlock-prevention property — before the round-6
    /// fix, the parent's wait-loop blocked on the child's exit
    /// while the child blocked on a full pipe buffer (~64 KiB on
    /// Linux), so 100 KiB of stdout caused a 30 s timeout
    /// deadlock.  After the fix, the drain thread reads
    /// continuously and the test completes in well under 1 s.
    #[test]
    #[cfg(unix)]
    fn subprocess_oracle_stdout_cap_rejects_oversize_output() {
        use super::SubprocessTruthOracle;
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mock_knomosis_path = dir.path().join("noisy_knomosis.sh");
        // Print 100 KiB to stdout (well above the typical 64 KiB
        // pipe-buffer ceiling), then a valid 64-char hex line.
        // With stdout_cap = 4096, this must be rejected.
        let script = "#!/bin/sh\n\
                      yes 'overflow' | head -c 100000\n\
                      printf '%064s\\n' '' | tr ' ' 'a'\n";
        std::fs::write(&mock_knomosis_path, script).unwrap();
        let mut perms = std::fs::metadata(&mock_knomosis_path)
            .unwrap()
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&mock_knomosis_path, perms).unwrap();
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();
        let oracle = SubprocessTruthOracle::new(mock_knomosis_path, log_path).with_stdout_cap(4096);
        let start = std::time::Instant::now();
        let result = oracle.commit_at(0);
        let elapsed = start.elapsed();
        assert!(
            result.is_none(),
            "expected oversize-stdout to be rejected, got Some({result:?})",
        );
        // Pin the round-6 deadlock fix.  The default subprocess
        // timeout is 30 s; before round-6, this test took the
        // full 30 s.  After round-6, it completes in ≪ 1 s.  A
        // 10 s ceiling leaves generous slack for slow CI runners
        // while still flagging a regression decisively.
        assert!(
            elapsed < std::time::Duration::from_secs(10),
            "deadlock regression: oversize-stdout took {elapsed:?} \
             (expected ≪ 10 s — drain must run concurrently with wait)",
        );
    }

    /// Audit-pass-4-round-6 CRITICAL regression: a knomosis
    /// subprocess that legitimately emits stdout larger than
    /// the OS pipe buffer (~64 KiB on Linux) MUST NOT block
    /// the observer.  Before the round-6 fix (drain-during-
    /// wait), the parent's wait-loop blocked on the child's
    /// exit, which blocked on the full pipe buffer.  This
    /// test exercises 256 KiB of stdout — comfortably over
    /// any pipe buffer — and confirms the call completes
    /// promptly.  256 KiB strikes a balance: large enough
    /// to demonstrate the deadlock fix, small enough to
    /// run cheaply under heavy parallel-test load on slow
    /// CI runners.
    #[test]
    #[cfg(unix)]
    fn subprocess_oracle_does_not_deadlock_on_large_stdout() {
        use super::SubprocessTruthOracle;
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mock_knomosis_path = dir.path().join("oversize_knomosis.sh");
        // Print 256 KiB to stdout (4× the typical Linux pipe
        // buffer of 64 KiB), then a valid 64-char hex line.
        let script = "#!/bin/sh\n\
                      yes 'spew' | head -c 262144\n\
                      printf '%064s\\n' '' | tr ' ' 'a'\n";
        std::fs::write(&mock_knomosis_path, script).unwrap();
        let mut perms = std::fs::metadata(&mock_knomosis_path)
            .unwrap()
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&mock_knomosis_path, perms).unwrap();
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();
        // Use the default 4096-byte cap — the 256 KiB output
        // is way over.  Test asserts: (1) returns None due to
        // the cap rejection, (2) completes in well under the
        // 30 s default timeout.  10 s upper bound leaves
        // generous slack for the slowest CI runner.
        let oracle = SubprocessTruthOracle::new(mock_knomosis_path, log_path);
        let start = std::time::Instant::now();
        let result = oracle.commit_at(0);
        let elapsed = start.elapsed();
        assert!(
            result.is_none(),
            "expected oversize-stdout to be rejected, got Some({result:?})",
        );
        assert!(
            elapsed < std::time::Duration::from_secs(10),
            "deadlock regression: 256 KiB stdout took {elapsed:?} \
             (expected ≪ 10 s — drain must run concurrently with wait)",
        );
    }

    /// Audit-pass-4-round-4 CRITICAL regression: an operator
    /// who wraps `knomosis` in a shell WITHOUT `exec` would have
    /// the shell fork knomosis as a child.  SIGKILL on the shell
    /// would leave the knomosis child as an orphan holding the
    /// stdout pipe write end open, blocking the post-exit
    /// drain indefinitely.
    ///
    /// This test simulates exactly that: a shell that forks a
    /// long-running subprocess (without `exec`) which holds
    /// the stdout pipe.  The drain MUST time out and the
    /// oracle MUST return None promptly.
    #[test]
    #[cfg(unix)]
    fn subprocess_oracle_drain_timeout_handles_orphan_pipe() {
        use super::SubprocessTruthOracle;
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mock_knomosis_path = dir.path().join("orphan_knomosis.sh");
        // Shell that forks `sleep 2` (NO `exec`!) which
        // inherits stdout.  The shell exits immediately; the
        // forked sleep keeps the pipe open.  We use `sleep 2`
        // (short) instead of `sleep 30` (long) so the orphaned
        // sleep cleans up promptly after the test exits,
        // avoiding leaked processes accumulating across parallel
        // test runs (CI flake hardening).  2 seconds is well
        // over the 500ms DRAIN_TIMEOUT so the test still
        // exercises the orphan-pipe scenario.
        //
        // Without the drain-timeout fix, the parent's drain
        // would block for ~2s waiting for the orphaned sleep
        // to release its end of the pipe.
        let script = "#!/bin/sh\nsleep 2 &\n";
        std::fs::write(&mock_knomosis_path, script).unwrap();
        let mut perms = std::fs::metadata(&mock_knomosis_path)
            .unwrap()
            .permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&mock_knomosis_path, perms).unwrap();
        let log_path = dir.path().join("empty.log");
        std::fs::write(&log_path, b"").unwrap();
        let oracle = SubprocessTruthOracle::new(mock_knomosis_path, log_path);
        let start = std::time::Instant::now();
        let result = oracle.commit_at(0);
        let elapsed = start.elapsed();
        // The shell exits quickly; the drain must time out
        // (500ms default) and we return None.  Generous slack
        // for CI scheduler (allow up to 5s).
        assert!(result.is_none(), "expected None, got Some({result:?})");
        assert!(
            elapsed < std::time::Duration::from_secs(5),
            "drain blocked {elapsed:?} on orphan pipe (drain-timeout should have fired)",
        );
    }
}

/// Workstream SVC.4 tests for the `TerminateBundleOracle`
/// surface.  Lives in a separate `cfg(test)` module so the
/// `super::*` imports don't pollute the existing tests.
#[cfg(test)]
mod terminate_bundle_tests {
    use super::{
        parse_terminate_bundle_json, MemoryTerminateBundleOracle, SubprocessTruthOracle,
        TerminateBundle, TerminateBundleError, TerminateBundleOracle,
        MAX_TERMINATE_BUNDLE_JSON_BYTES,
    };
    use crate::submitter::OpenedCell;

    fn sample_bundle(idx_str: &str) -> TerminateBundle {
        TerminateBundle {
            fixture_id: format!("log[{idx_str}]"),
            action_kind: 1,
            action_fields: vec![0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2],
            signer: 5,
            expected_post_commit: [0xCD; 32],
            opened_cells: vec![OpenedCell {
                cell_kind: 14,
                key_a: 0,
                key_b: 0,
                pre_value: vec![0u8; 36],
            }],
            gap_mask: vec![0u8; 32],
            siblings: vec![],
            // No batch binding: the pre-batching bundle shape,
            // which must keep parsing (a bundle exported without
            // batch bounds).
            ..TerminateBundle::default()
        }
    }

    /// A bundle carrying a well-formed batch binding for disputed
    /// index `idx` inside batch `[0, 4)`.
    fn batch_bound_bundle(idx: u64) -> TerminateBundle {
        TerminateBundle {
            prev_end: Some(0),
            end_index: Some(4),
            batch_idx: Some(idx),
            actions_root: Some([0xA0; 32]),
            action_key: Some([0xA1; 32]),
            leaf_commit: Some([0xA2; 32]),
            action_sig: Some(vec![0x11; 65]),
            action_gap_mask: Some(vec![0u8; 32]),
            action_siblings: Some(vec![0xBB; 64]),
            ..sample_bundle(&idx.to_string())
        }
    }

    /// `MemoryTerminateBundleOracle` returns `Missed` for an
    /// unknown index.
    #[test]
    fn memory_bundle_oracle_missed_default() {
        let oracle = MemoryTerminateBundleOracle::new();
        let result = oracle.terminate_bundle_at(7, None);
        assert!(matches!(
            result,
            Err(TerminateBundleError::Missed { idx: 7 })
        ));
    }

    /// `MemoryTerminateBundleOracle::insert` then lookup
    /// round-trips.
    #[test]
    fn memory_bundle_oracle_roundtrip() {
        let mut oracle = MemoryTerminateBundleOracle::new();
        let bundle = sample_bundle("7");
        oracle.insert(7, bundle.clone());
        let result = oracle.terminate_bundle_at(7, None).unwrap();
        assert_eq!(result, bundle);
        assert_eq!(oracle.len(), 1);
        assert!(!oracle.is_empty());
    }

    /// `MemoryTerminateBundleOracle::insert` overwrites the
    /// existing entry.
    #[test]
    fn memory_bundle_oracle_overwrite() {
        let mut oracle = MemoryTerminateBundleOracle::new();
        let b1 = sample_bundle("1");
        let mut b2 = sample_bundle("2");
        b2.action_kind = 5;
        oracle.insert(0, b1);
        oracle.insert(0, b2.clone());
        let result = oracle.terminate_bundle_at(0, None).unwrap();
        assert_eq!(result, b2);
        assert_eq!(oracle.len(), 1);
    }

    /// `Box<dyn TerminateBundleOracle>` blanket impl dispatches
    /// correctly.
    #[test]
    fn box_dyn_terminate_oracle_dispatches() {
        let mut inner = MemoryTerminateBundleOracle::new();
        let bundle = sample_bundle("99");
        inner.insert(99, bundle.clone());
        let boxed: Box<dyn TerminateBundleOracle + Send + Sync> = Box::new(inner);
        let result = boxed.terminate_bundle_at(99, None).unwrap();
        assert_eq!(result, bundle);
    }

    /// Parser round-trips a minimal valid bundle.
    #[test]
    fn parse_minimal_bundle_round_trip() {
        let bundle = sample_bundle("0");
        let json = serde_json::to_string(&bundle).unwrap();
        let parsed = parse_terminate_bundle_json(0, &json).unwrap();
        assert_eq!(parsed, bundle);
    }

    /// A batch-bound bundle (Workstream SB) round-trips: every
    /// binding field survives serialize → parse.
    #[test]
    fn parse_batch_bound_bundle_round_trip() {
        let bundle = batch_bound_bundle(2);
        let json = serde_json::to_string(&bundle).unwrap();
        let parsed = parse_terminate_bundle_json(2, &json).unwrap();
        assert_eq!(parsed, bundle);
        assert!(parsed.has_batch_binding());
    }

    /// The binding is ALL-OR-NOTHING: a bundle carrying some batch
    /// fields but not all is refused (a truncated / hand-edited
    /// document, not an unbound bundle).
    #[test]
    fn parse_rejects_partial_batch_binding() {
        let mut bundle = batch_bound_bundle(2);
        bundle.action_sig = None;
        let json = serde_json::to_string(&bundle).unwrap();
        let err = parse_terminate_bundle_json(2, &json).unwrap_err();
        assert!(
            matches!(err, TerminateBundleError::Malformed { .. }),
            "expected Malformed for a partial binding, got {err:?}",
        );
    }

    /// The leaf binds a FIXED 65-byte signature (ruling R7); the L1
    /// reverts on any other width, so the parser refuses first.
    #[test]
    fn parse_rejects_wrong_signature_width() {
        let mut bundle = batch_bound_bundle(2);
        bundle.action_sig = Some(vec![0x11; 64]);
        let json = serde_json::to_string(&bundle).unwrap();
        let err = parse_terminate_bundle_json(2, &json).unwrap_err();
        assert!(
            matches!(err, TerminateBundleError::Malformed { .. }),
            "expected Malformed for a 64-byte signature, got {err:?}",
        );
    }

    /// The inclusion wire's bitmask is exactly 32 bytes.
    #[test]
    fn parse_rejects_wrong_action_gap_mask_width() {
        let mut bundle = batch_bound_bundle(2);
        bundle.action_gap_mask = Some(vec![0u8; 31]);
        let json = serde_json::to_string(&bundle).unwrap();
        let err = parse_terminate_bundle_json(2, &json).unwrap_err();
        assert!(
            matches!(err, TerminateBundleError::Malformed { .. }),
            "expected Malformed for a 31-byte bitmask, got {err:?}",
        );
    }

    /// The inclusion wire's sibling region is whole 32-byte words.
    #[test]
    fn parse_rejects_ragged_action_siblings() {
        let mut bundle = batch_bound_bundle(2);
        bundle.action_siblings = Some(vec![0u8; 33]);
        let json = serde_json::to_string(&bundle).unwrap();
        let err = parse_terminate_bundle_json(2, &json).unwrap_err();
        assert!(
            matches!(err, TerminateBundleError::Malformed { .. }),
            "expected Malformed for ragged action siblings, got {err:?}",
        );
    }

    /// `batch_idx` must sit inside `[prev_end, end)` AND match the
    /// requested index — a bundle for the wrong step is refused
    /// rather than broadcast.
    #[test]
    fn parse_rejects_batch_idx_out_of_range_or_mismatched() {
        // Outside the bounds.
        let mut outside = batch_bound_bundle(2);
        outside.batch_idx = Some(4);
        let json = serde_json::to_string(&outside).unwrap();
        assert!(matches!(
            parse_terminate_bundle_json(4, &json),
            Err(TerminateBundleError::Malformed { .. })
        ));
        // In-bounds but not the requested index.
        let mismatched = batch_bound_bundle(2);
        let json = serde_json::to_string(&mismatched).unwrap();
        assert!(matches!(
            parse_terminate_bundle_json(3, &json),
            Err(TerminateBundleError::Malformed { .. })
        ));
    }

    /// The subprocess oracle's argv carries the batch bounds when
    /// supplied — `export-terminate-bundle LOG IDX PREV_END END` —
    /// and omits them when not.
    #[test]
    fn subprocess_bundle_command_carries_batch_bounds() {
        let oracle = SubprocessTruthOracle::new(
            std::path::PathBuf::from("/usr/bin/knomosis"),
            std::path::PathBuf::from("/tmp/test.log"),
        );
        let with_bounds = oracle.build_bundle_command(3, Some((0, 4)));
        let args: Vec<String> = with_bounds
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            args,
            vec!["export-terminate-bundle", "/tmp/test.log", "3", "0", "4"],
            "bounds appended after the index",
        );
        let without_bounds = oracle.build_bundle_command(3, None);
        let args: Vec<String> = without_bounds
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            args,
            vec!["export-terminate-bundle", "/tmp/test.log", "3"],
            "no bounds ⇒ the bare three-argument form",
        );
    }

    /// Parser rejects oversize JSON.
    #[test]
    fn parse_rejects_oversize_json() {
        let huge = "x".repeat(MAX_TERMINATE_BUNDLE_JSON_BYTES + 1);
        let err = parse_terminate_bundle_json(0, &huge).unwrap_err();
        assert!(matches!(err, TerminateBundleError::Oversize { idx: 0, .. }));
    }

    /// Parser rejects malformed JSON.
    #[test]
    fn parse_rejects_malformed_json() {
        let err = parse_terminate_bundle_json(0, "not-json").unwrap_err();
        assert!(matches!(err, TerminateBundleError::Malformed { .. }));
    }

    /// Parser rejects missing fields.
    #[test]
    fn parse_rejects_missing_fields() {
        let json = r#"{"fixture_id":"log[0]"}"#;
        let err = parse_terminate_bundle_json(0, json).unwrap_err();
        assert!(matches!(err, TerminateBundleError::Malformed { .. }));
    }

    /// Parser accepts hex-encoded `action_fields` (Lean wire form).
    #[test]
    fn parse_hex_action_fields() {
        let json = r#"{
            "fixture_id": "log[0]",
            "action_kind": 0,
            "action_fields_hex": "deadbeef",
            "signer": 0,
            "expected_post_commit_hex": "0000000000000000000000000000000000000000000000000000000000000001",
            "opened_cells": [{
                "cell_kind": 14,
                "key_a": "0000000000000000",
                "key_b": "0000000000000000",
                "pre_value": ""
            }],
            "gap_mask_hex": "",
            "siblings_hex": ""
        }"#;
        let parsed = parse_terminate_bundle_json(0, json).unwrap();
        assert_eq!(parsed.action_fields, vec![0xde, 0xad, 0xbe, 0xef]);
        assert_eq!(parsed.expected_post_commit[31], 0x01);
    }

    /// Parser rejects an oversize frontier.
    ///
    /// The cap is the contract's `MAX_CELL_OPENINGS`, which
    /// `assertConsistent` in turn checks against the widest write set
    /// any adjudicable variant produces.  A `knomosis` subprocess
    /// emitting more than that is misconfigured or hostile, and the
    /// observer refuses before allocating for it.
    #[test]
    fn parse_rejects_oversize_opened_cell_count() {
        let cell = OpenedCell {
            cell_kind: 0,
            key_a: 0,
            key_b: 0,
            pre_value: vec![],
        };
        let cells: Vec<OpenedCell> = (0..=super::MAX_TERMINATE_BUNDLE_OPENED_CELLS)
            .map(|_| cell.clone())
            .collect();
        let bundle = TerminateBundle {
            fixture_id: "log[0]".to_string(),
            action_kind: 0,
            action_fields: vec![],
            signer: 0,
            expected_post_commit: [0; 32],
            opened_cells: cells,
            gap_mask: vec![0u8; 32],
            siblings: vec![],
            ..TerminateBundle::default()
        };
        let json = serde_json::to_string(&bundle).unwrap();
        let err = parse_terminate_bundle_json(0, &json).unwrap_err();
        assert!(
            matches!(err, TerminateBundleError::Malformed { .. }),
            "expected Malformed for oversize frontier, got {err:?}",
        );
    }

    /// Parser rejects a sibling region that is not whole 32-byte
    /// siblings.
    ///
    /// Not the L1's check — the contract derives the EXACT count from
    /// the key set — but a truncated region caught here is one the
    /// observer never broadcasts calldata for, and broadcasting a
    /// bundle the L1 reverts on costs the responsible party the game
    /// by timeout.
    #[test]
    fn parse_rejects_ragged_sibling_region() {
        let bundle = TerminateBundle {
            fixture_id: "log[0]".to_string(),
            action_kind: 0,
            action_fields: vec![],
            signer: 0,
            expected_post_commit: [0; 32],
            opened_cells: vec![],
            gap_mask: vec![0u8; 32],
            siblings: vec![0u8; 33],
            ..TerminateBundle::default()
        };
        let json = serde_json::to_string(&bundle).unwrap();
        let err = parse_terminate_bundle_json(0, &json).unwrap_err();
        assert!(
            matches!(err, TerminateBundleError::Malformed { .. }),
            "expected Malformed for a ragged sibling region, got {err:?}",
        );
    }

    /// Serialize → deserialize round-trip preserves equality.
    #[test]
    fn serde_round_trip_equality() {
        let bundle = sample_bundle("42");
        let json = serde_json::to_string(&bundle).unwrap();
        let parsed: TerminateBundle = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, bundle);
    }

    /// Lean-emitted JSON (hex strings everywhere) parses to the
    /// same bundle as a Rust-constructed equivalent.
    #[test]
    fn lean_emitted_json_compatible_with_rust_construction() {
        // Synthesize a Lean-shape JSON (hex strings, snake_case
        // fields, expected_post_commit_hex as 64-char lowercase
        // hex).
        let lean_json = r#"{
            "fixture_id": "log[7]",
            "action_kind": 3,
            "action_fields_hex": "0000000000000005",
            "signer": 42,
            "expected_post_commit_hex": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            "opened_cells": [
                {
                    "cell_kind": 14,
                    "key_a": "0000000000000000",
                    "key_b": "0000000000000000",
                    "pre_value": ""
                },
                {
                    "cell_kind": 1,
                    "key_a": "000000000000002a",
                    "key_b": "0000000000000000",
                    "pre_value": "1b00000000000000"
                }
            ],
            "gap_mask_hex": "0102",
            "siblings_hex": "00000000000000000000000000000000000000000000000000000000000000ff"
        }"#;
        let parsed = parse_terminate_bundle_json(7, lean_json).unwrap();
        assert_eq!(parsed.fixture_id, "log[7]");
        assert_eq!(parsed.action_kind, 3);
        assert_eq!(parsed.action_fields.len(), 8);
        assert_eq!(parsed.signer, 42);
        // The commit hex decodes to 0xde repeated.
        assert_eq!(parsed.expected_post_commit[0], 0xde);
        assert_eq!(parsed.expected_post_commit[31], 0xef);
        // The frontier and the wire survive the hex decode.
        assert_eq!(parsed.opened_cells.len(), 2);
        assert_eq!(parsed.opened_cells[0].cell_kind, 14);
        assert_eq!(parsed.opened_cells[1].key_a, 42);
        assert_eq!(parsed.gap_mask, vec![0x01, 0x02]);
        assert_eq!(parsed.siblings.len(), 32);
        assert_eq!(parsed.siblings[31], 0xff);
    }
}
