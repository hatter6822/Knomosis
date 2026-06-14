// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! CLI configuration parsing for `knomosis-host`.
//!
//! No `clap` dependency — the flag set is small and stable; a
//! hand-rolled parser keeps the dependency surface narrow (same
//! choice as `knomosis-l1-ingest::main`).
//!
//! ## Flag matrix
//!
//! | Flag                   | Required | Description                                          |
//! |------------------------|----------|------------------------------------------------------|
//! | `--listen <ADDR>`      | one of   | TCP listen address (`host:port`)                     |
//! | `--unix-socket <PATH>` | one of   | Unix-socket path                                     |
//! | `--tls-cert <PATH>`    | optional | PEM-encoded TLS cert (requires `--tls-key`)          |
//! | `--tls-key <PATH>`     | optional | PEM-encoded TLS key (requires `--tls-cert`)          |
//! | `--tls-listen <ADDR>`  | optional | TLS-on-TCP listen address (requires cert/key)        |
//! | `--knomosis-binary <PATH>`| optional | Path to knomosis binary for `CommandKernel`             |
//! | `--knomosis-log <PATH>`   | optional | Persistent log file for `CommandKernel`              |
//! | `--knomosis-work-dir <P>` | optional | Temp work dir for `CommandKernel` (defaults next to LOG) |
//! | `--deployment-id <H>`  | optional | Hex-encoded deployment id passed to knomosis binary     |
//! | `--budget-policy bounded`| optional | Enable the GP.6.2 per-actor budget admission gate    |
//! | `--free-tier <N>`      | optional | Per-epoch budget floor (with `--budget-policy`)      |
//! | `--action-cost <C>`    | optional | Per-action budget debit (clamped `>= 1`; default 1)  |
//! | `--current-epoch <E>`  | optional | Current epoch index (default 0; free tier needs E≥1) |
//! | `--epoch-length <N>`   | optional | Admitted actions per budget epoch (0 = no advance)   |
//! | `--gas-pool-eth-cap <N>`| optional | GP.7.4 gas-pool genesis: ETH-leg per-action cap     |
//! | `--gas-pool-bold-cap <N>`| optional | GP.7.4 gas-pool genesis: BOLD-leg per-action cap   |
//! | `--wei-per-budget-unit-eth <N>` | optional | GP.9.1 refund-on-exit: ETH-leg rate (0 = off) |
//! | `--wei-per-budget-unit-bold <N>`| optional | GP.9.1 refund-on-exit: BOLD-leg rate (0 = off) |
//! | `--scheduler {fifo\|drr}`| optional | Worker scheduler (FQ Rung 0/1; default `fifo`)      |
//! | `--per-flow-cap <N>`   | optional | DRR per-(conn,signer) backlog cap (default 64; drr only)|
//! | `--max-flows <N>`      | optional | DRR distinct-connection cap (default 4096; drr only) |
//! | `--max-signers-per-conn <N>`| optional | Rung-1 distinct-signer-per-conn cap (default 256; drr only)|
//! | `--max-conn-backlog <N>`| optional | Rung-1.5 per-connection aggregate backlog cap (default = `--per-flow-cap`; drr only)|
//! | `--persistent-connections`| optional | Pipeline many requests per TCP/Unix connection (default off; makes DRR bite over the wire)|
//! | `--max-queue-depth <N>`| optional | Bounded queue size / DRR global cap (default 256)    |
//! | `--max-frame-size <N>` | optional | Max request frame size in bytes (default 1 MiB)      |
//! | `--mock`               | optional | Use `MockKernel` (always returns Ok)                 |
//! | `--help` / `-h`        |          | Print usage                                          |
//! | `--version` / `-v`     |          | Print version                                        |
//!
//! At least one listener flag is required (`--listen`,
//! `--tls-listen`, or `--unix-socket`).  At least one kernel
//! configuration is required (`--mock` or `--knomosis-binary` +
//! `--knomosis-log`).

use std::net::SocketAddr;
use std::path::PathBuf;
use std::str::FromStr;

use crate::budget::BudgetPolicy;
use crate::fair::drr::{
    Caps, DEFAULT_MAX_FLOWS, DEFAULT_MAX_SIGNERS_PER_CONN, DEFAULT_PER_FLOW_CAP, HARD_MAX_FLOWS,
    HARD_MAX_SIGNERS_PER_CONN,
};

/// Which worker scheduler the host runs (Workstream GP.8, Track A /
/// FQ).  `Fifo` is the unchanged default baseline; `Drr` selects the
/// optional per-connection fair scheduler (Rung 0).
///
/// Parsed from `--scheduler {fifo|drr}` via [`FromStr`]; an
/// unrecognised value is a CLI usage error
/// ([`ParseError::InvalidValue`]), consistent with every other typed
/// value flag (a malformed enum value is a parse error, not a
/// cross-field semantic [`ConfigError`]).
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Scheduler {
    /// FIFO bounded queue — the historical, default behaviour.  No
    /// fairness, no wire change, lowest overhead.
    #[default]
    Fifo,
    /// Deficit-Round-Robin per-connection fair scheduler (Rung 0).
    /// Bounds, under contention, the share any one connection takes of
    /// the serial worker.  Default-OFF; opt in with `--scheduler drr`.
    Drr,
}

impl Scheduler {
    /// Stable lowercase name for flags / diagnostics (the inverse of
    /// [`FromStr`]).  Downstream log scrapers may rely on these exact
    /// strings.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Fifo => "fifo",
            Self::Drr => "drr",
        }
    }
}

impl std::fmt::Display for Scheduler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

/// Error returned when a `--scheduler` value is neither `fifo` nor
/// `drr`.
#[derive(Debug, thiserror::Error)]
#[error("unknown scheduler '{0}'; valid values are 'fifo' or 'drr'")]
pub struct SchedulerParseError(String);

impl FromStr for Scheduler {
    type Err = SchedulerParseError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "fifo" => Ok(Self::Fifo),
            "drr" => Ok(Self::Drr),
            other => Err(SchedulerParseError(other.to_string())),
        }
    }
}

/// Parsed knomosis-host configuration.
#[derive(Clone, Debug)]
pub struct Config {
    /// Plain TCP listen address (if configured).
    pub tcp_listen: Option<SocketAddr>,
    /// TLS-on-TCP listen address (if configured).
    pub tls_listen: Option<SocketAddr>,
    /// Path to TLS certificate (PEM).
    pub tls_cert: Option<PathBuf>,
    /// Path to TLS private key (PEM).
    pub tls_key: Option<PathBuf>,
    /// Unix-socket path (if configured).
    pub unix_socket: Option<PathBuf>,
    /// Path to the `knomosis` binary (for `CommandKernel`).
    pub knomosis_binary: Option<PathBuf>,
    /// Path to the persistent log file.
    pub knomosis_log: Option<PathBuf>,
    /// Temp work directory for per-request files.  Defaults to
    /// `<knomosis-log dir>/knomosis-host-work/`.
    pub knomosis_work_dir: Option<PathBuf>,
    /// Hex-encoded deployment id (no `0x` prefix).
    pub deployment_id: Option<String>,
    /// Maximum queue depth.
    pub max_queue_depth: usize,
    /// Maximum frame size in bytes.
    pub max_frame_size: usize,
    /// Maximum simultaneous connection handler threads (DoS cap).
    pub max_concurrent_connections: usize,
    /// `--persistent-connections`: run TCP / Unix connections in
    /// persistent + pipelined mode (default `false` ⇒ one-shot per
    /// connection).  When enabled, a single connection may pipeline many
    /// in-flight requests and receives one verdict per request in
    /// submission order; this is the mode under which two-tier DRR
    /// actually diverges from FIFO over the wire (`GP.8` §2.5).  TLS
    /// connections are always one-shot.  Pairs with `--scheduler drr` +
    /// `--max-conn-backlog` (the per-connection pipelining-depth bound).
    pub persistent_connections: bool,
    /// Use the in-memory mock kernel.
    pub use_mock_kernel: bool,
    /// Raw `--budget-policy <mode>` value (GP.6.2).  The only
    /// recognised mode is `"bounded"`; any other value is rejected
    /// by [`Config::validate`].
    pub budget_mode: Option<String>,
    /// `--free-tier <N>` value (GP.6.2): the per-epoch budget floor.
    pub budget_free_tier: Option<u64>,
    /// `--action-cost <C>` value (GP.6.2): the per-action debit
    /// (clamped to `>= 1` by [`BudgetPolicy::mk_bounded`]).
    pub budget_action_cost: Option<u64>,
    /// `--current-epoch <E>` value (GP.6.2): the current epoch index.
    pub budget_current_epoch: Option<u64>,
    /// `--epoch-length <N>` value (GP.6.2 epoch advancement): admitted
    /// actions per budget epoch (`None` / `0` disables advancement).
    pub budget_epoch_length: Option<u64>,
    /// `--gas-pool-eth-cap <N>` value (GP.7.4): the ETH-leg per-action
    /// drain cap.  Supplying this OR `--gas-pool-bold-cap` enables the
    /// gas-pool genesis wiring; a missing cap defaults to `0`.
    pub gas_pool_eth_cap: Option<u64>,
    /// `--gas-pool-bold-cap <N>` value (GP.7.4): the BOLD-leg per-action
    /// drain cap.  See `gas_pool_eth_cap`.
    pub gas_pool_bold_cap: Option<u64>,
    /// `--wei-per-budget-unit-eth <N>` value (GP.9.1): the ETH-leg
    /// refund-on-exit rate.  Supplying this OR `--wei-per-budget-unit-bold`
    /// enables `claimBudgetRefund` admission (forwarded to the `knomosis`
    /// binary, which does the authoritative gating); a missing rate
    /// defaults to `0` (refunds disabled at that leg).
    pub refund_rate_eth: Option<u64>,
    /// `--wei-per-budget-unit-bold <N>` value (GP.9.1): the BOLD-leg
    /// refund-on-exit rate.  See `refund_rate_eth`.
    pub refund_rate_bold: Option<u64>,
    /// `--scheduler {fifo|drr}` (FQ Rung 0): the resolved worker
    /// scheduler.  Default [`Scheduler::Fifo`] preserves the historical
    /// behaviour byte-for-byte.  An unrecognised value leaves this at
    /// the default and records the offending string in
    /// [`Config::scheduler_unrecognized`] for [`Config::validate`] to
    /// reject (the same defer-to-validate pattern `--budget-policy`
    /// uses, so the error surfaces as a [`ConfigError`]).
    pub scheduler: Scheduler,
    /// The raw `--scheduler` value when it was NOT `fifo` / `drr`
    /// (`None` when unset or valid).  Held so [`Config::validate`] can
    /// reject it with a clear [`ConfigError::UnknownScheduler`] rather
    /// than the parser silently defaulting to FIFO.
    pub scheduler_unrecognized: Option<String>,
    /// `--per-flow-cap <N>` (FQ.5): the DRR per-connection backlog cap.
    /// Ignored at runtime unless `scheduler == Drr`, but its basic
    /// sanity (`>= 1`) is validated regardless.
    pub per_flow_cap: usize,
    /// `--max-flows <N>` (FQ.5): the DRR cap on distinct active flows.
    /// Ignored at runtime unless `scheduler == Drr`, but its basic
    /// sanity (`1 ..= HARD_MAX_FLOWS`) is validated regardless.
    pub max_flows: usize,
    /// `--max-signers-per-conn <N>` (FQ.12): the Rung-1 cap on distinct
    /// signer hints buffered WITHIN one connection (the inner DRR tier).
    /// Bounds the per-connection scheduler-DoS surface a hint-spamming
    /// connection can create (`GP.8` §2.6 invariant 4).  Ignored at
    /// runtime unless `scheduler == Drr`, but its basic sanity
    /// (`1 ..= HARD_MAX_SIGNERS_PER_CONN`) is validated regardless.
    pub max_signers_per_conn: usize,
    /// `--max-conn-backlog <N>` (Rung 1.5): the cap on a single
    /// connection's AGGREGATE buffered backlog, summed across all of its
    /// signer hints — the per-connection dual of `per_flow_cap`.  `None`
    /// (the default) resolves to `per_flow_cap` in [`Config::caps`],
    /// restoring the Rung-0 per-connection backpressure (one connection ≈
    /// one `per_flow`'s worth) that the two-tier split would otherwise
    /// relax to `max_signers × per_flow`.  An operator RAISES it to allow
    /// a connection that legitimately multiplexes many signers (a
    /// persistent / sequencer-fronted topology).  Ignored at runtime
    /// unless `scheduler == Drr`; when present its basic sanity
    /// (`1 ..= HARD_MAX_QUEUE_DEPTH`) is validated regardless, and under
    /// `--scheduler drr` it must not exceed `--max-queue-depth`.
    pub max_conn_backlog: Option<usize>,
}

impl Config {
    /// Construct a default config.  Defaults match the documented
    /// values in `docs/abi.md` §10.
    #[must_use]
    pub fn defaults() -> Self {
        Self {
            tcp_listen: None,
            tls_listen: None,
            tls_cert: None,
            tls_key: None,
            unix_socket: None,
            knomosis_binary: None,
            knomosis_log: None,
            knomosis_work_dir: None,
            deployment_id: None,
            max_queue_depth: crate::queue::DEFAULT_MAX_QUEUE_DEPTH,
            max_frame_size: crate::frame::DEFAULT_MAX_FRAME_SIZE,
            max_concurrent_connections: crate::listener::DEFAULT_MAX_CONCURRENT_CONNECTIONS,
            persistent_connections: false,
            use_mock_kernel: false,
            budget_mode: None,
            budget_free_tier: None,
            budget_action_cost: None,
            budget_current_epoch: None,
            budget_epoch_length: None,
            gas_pool_eth_cap: None,
            gas_pool_bold_cap: None,
            refund_rate_eth: None,
            refund_rate_bold: None,
            scheduler: Scheduler::Fifo,
            scheduler_unrecognized: None,
            per_flow_cap: DEFAULT_PER_FLOW_CAP,
            max_flows: DEFAULT_MAX_FLOWS,
            max_signers_per_conn: DEFAULT_MAX_SIGNERS_PER_CONN,
            max_conn_backlog: None,
        }
    }

    /// The configured per-actor budget policy (GP.6.2), if any.
    ///
    /// A policy is assembled when `--budget-policy bounded` is
    /// supplied OR any of the three budget sub-flags is present
    /// (with `bounded` the only mode).  `BudgetPolicy::mk_bounded`
    /// clamps `action_cost` to `>= 1`, matching the Lean smart
    /// constructor.  A non-`"bounded"` mode yields `None` (rejected
    /// by [`Config::validate`]).
    #[must_use]
    pub fn budget_policy(&self) -> Option<BudgetPolicy> {
        match self.budget_mode.as_deref() {
            Some("bounded") => Some(self.assemble_bounded()),
            // A non-`bounded` explicit mode yields no policy (and is
            // rejected by `validate`).
            Some(_) => None,
            // No explicit mode: a bare budget sub-flag still enables
            // bounded mode (with the other fields defaulted).
            None => {
                let any_sub = self.budget_free_tier.is_some()
                    || self.budget_action_cost.is_some()
                    || self.budget_current_epoch.is_some();
                if any_sub {
                    Some(self.assemble_bounded())
                } else {
                    None
                }
            }
        }
    }

    /// Assemble a bounded policy from the parsed sub-flags, defaulting
    /// each to the genesis-default field value.
    fn assemble_bounded(&self) -> BudgetPolicy {
        BudgetPolicy::mk_bounded(
            self.budget_free_tier.unwrap_or(0),
            self.budget_action_cost.unwrap_or(1),
            self.budget_current_epoch.unwrap_or(0),
        )
    }

    /// The configured GP.7.4 gas-pool caps `(eth_cap, bold_cap)`, if the
    /// gas pool is enabled.  `Some((eth, bold))` when EITHER
    /// `--gas-pool-eth-cap` or `--gas-pool-bold-cap` is supplied (a
    /// missing cap defaults to `0`, i.e. that leg cannot drain); `None`
    /// when neither is supplied (gas pool disabled).  Forwarded to the
    /// `CommandKernel` via `with_gas_pool_policy`, which passes the two
    /// caps to the `knomosis` binary's gas-pool genesis wiring.
    #[must_use]
    pub fn gas_pool_caps(&self) -> Option<(u64, u64)> {
        match (self.gas_pool_eth_cap, self.gas_pool_bold_cap) {
            (None, None) => None,
            (eth, bold) => Some((eth.unwrap_or(0), bold.unwrap_or(0))),
        }
    }

    /// The configured GP.9.1 refund-on-exit rate `(eth_rate, bold_rate)`,
    /// if refunds are enabled.  `Some((eth, bold))` when EITHER
    /// `--wei-per-budget-unit-eth` or `--wei-per-budget-unit-bold` is
    /// supplied (a missing rate defaults to `0`, i.e. refunds disabled at
    /// that leg); `None` when neither is supplied (refunds fully
    /// disabled).  Forwarded to the `CommandKernel` via
    /// `with_refund_rate`, which passes the two rates to the `knomosis`
    /// binary's `claimBudgetRefund` admission gate.
    #[must_use]
    pub fn refund_rate(&self) -> Option<(u64, u64)> {
        match (self.refund_rate_eth, self.refund_rate_bold) {
            (None, None) => None,
            (eth, bold) => Some((eth.unwrap_or(0), bold.unwrap_or(0))),
        }
    }

    /// The DRR capacity caps (FQ.5 / FQ.12 / Rung 1.5), built from the
    /// per-flow / max-flows / max-signers-per-conn / max-conn-backlog
    /// flags with the host's `--max-queue-depth` reused as the global
    /// cap.  Passed to [`crate::queue::FairQueue`] when `scheduler ==
    /// Drr`.  [`Caps::new`] + [`Caps::with_max_signers`] +
    /// [`Caps::with_max_conn_backlog`] apply the defence-in-depth
    /// ceilings on top of the CLI validation.  An absent
    /// `--max-conn-backlog` resolves to `per_flow_cap` (matching
    /// [`Caps::new`]'s default), restoring the Rung-0 per-connection
    /// backpressure (one connection ≈ one `per_flow`'s worth) rather than
    /// the relaxed `max_signers × per_flow`.
    #[must_use]
    pub fn caps(&self) -> Caps {
        Caps::new(self.per_flow_cap, self.max_flows, self.max_queue_depth)
            .with_max_signers(self.max_signers_per_conn)
            .with_max_conn_backlog(self.max_conn_backlog.unwrap_or(self.per_flow_cap))
    }

    /// Returns true if at least one listener is configured.
    #[must_use]
    pub fn has_any_listener(&self) -> bool {
        self.tcp_listen.is_some() || self.tls_listen.is_some() || self.unix_socket.is_some()
    }

    /// Returns true if a kernel implementation is configured
    /// (either MockKernel via `--mock` or CommandKernel via
    /// `--knomosis-binary` + `--knomosis-log`).
    #[must_use]
    pub fn has_kernel_choice(&self) -> bool {
        self.use_mock_kernel || (self.knomosis_binary.is_some() && self.knomosis_log.is_some())
    }

    /// Validate the configuration.  Returns the first
    /// inconsistency found.
    ///
    /// # Errors
    ///
    /// See [`ConfigError`].
    pub fn validate(&self) -> Result<(), ConfigError> {
        if !self.has_any_listener() {
            return Err(ConfigError::NoListenerConfigured);
        }
        if !self.has_kernel_choice() {
            return Err(ConfigError::NoKernelConfigured);
        }
        // TLS sub-options: tls_listen requires both cert + key.
        if self.tls_listen.is_some() && (self.tls_cert.is_none() || self.tls_key.is_none()) {
            return Err(ConfigError::TlsListenWithoutCertKey);
        }
        // If cert/key are supplied, tls_listen should be set too
        // (otherwise the certs go unused, which is operator
        // confusion).
        if (self.tls_cert.is_some() || self.tls_key.is_some()) && self.tls_listen.is_none() {
            return Err(ConfigError::TlsCertKeyWithoutListen);
        }
        // Mock + knomosis-binary is contradictory (which kernel are
        // you actually running?).
        if self.use_mock_kernel && self.knomosis_binary.is_some() {
            return Err(ConfigError::ConflictingKernelChoice);
        }
        // Bounds check on numeric flags.
        if self.max_queue_depth == 0 {
            return Err(ConfigError::QueueDepthZero);
        }
        if self.max_queue_depth > crate::queue::HARD_MAX_QUEUE_DEPTH {
            return Err(ConfigError::QueueDepthTooLarge(self.max_queue_depth));
        }
        if self.max_frame_size == 0 {
            return Err(ConfigError::FrameSizeZero);
        }
        if self.max_frame_size > crate::frame::HARD_MAX_FRAME_SIZE {
            return Err(ConfigError::FrameSizeTooLarge(self.max_frame_size));
        }
        if self.max_concurrent_connections == 0 {
            return Err(ConfigError::ConcurrentConnectionsZero);
        }
        if self.max_concurrent_connections > crate::listener::HARD_MAX_CONCURRENT_CONNECTIONS {
            return Err(ConfigError::ConcurrentConnectionsTooLarge(
                self.max_concurrent_connections,
            ));
        }
        // GP.6.2: the only recognised budget mode is `bounded`.  A
        // sub-flag without an explicit `--budget-policy` defaults to
        // bounded mode, so only an explicit non-`bounded` value is an
        // error.
        if let Some(mode) = self.budget_mode.as_deref() {
            if mode != "bounded" {
                return Err(ConfigError::UnknownBudgetMode(mode.to_string()));
            }
        }
        // FQ.0: an unrecognised `--scheduler` value (deferred from the
        // parser) is a configuration error, like `--budget-policy <bad>`.
        if let Some(mode) = self.scheduler_unrecognized.as_deref() {
            return Err(ConfigError::UnknownScheduler(mode.to_string()));
        }
        // FQ.5: cap validation has two tiers.
        //
        // (a) INTRINSIC sanity is checked ALWAYS: a `per_flow_cap` of 0
        //     or a `max_flows` outside `1 ..= HARD_MAX_FLOWS` is nonsense
        //     for any scheduler, so it fails fast even in FIFO mode.
        //     This never regresses a normal FIFO deployment — the
        //     defaults (64 / 4096) are well within range — it only flags
        //     an explicit nonsense value.
        if self.per_flow_cap == 0 {
            return Err(ConfigError::PerFlowCapZero);
        }
        if self.max_flows == 0 {
            return Err(ConfigError::MaxFlowsZero);
        }
        if self.max_flows > HARD_MAX_FLOWS {
            return Err(ConfigError::MaxFlowsTooLarge(self.max_flows));
        }
        // FQ.12: the per-connection distinct-signer cap (Rung 1).  A
        // value of 0 is nonsense for any scheduler (a connection could
        // route no requests), so — like `per_flow_cap` / `max_flows` —
        // its intrinsic sanity is checked regardless of scheduler.
        if self.max_signers_per_conn == 0 {
            return Err(ConfigError::MaxSignersPerConnZero);
        }
        if self.max_signers_per_conn > HARD_MAX_SIGNERS_PER_CONN {
            return Err(ConfigError::MaxSignersPerConnTooLarge(
                self.max_signers_per_conn,
            ));
        }
        // Rung 1.5: the per-connection aggregate-backlog cap.  Only
        // meaningful when explicitly supplied (an absent flag resolves to
        // `max_queue_depth`, a no-op).  When present, a value of 0 is
        // nonsense for any scheduler (a connection could buffer nothing),
        // so — like the sibling caps — its intrinsic sanity is checked
        // regardless of scheduler.
        if let Some(max_conn_backlog) = self.max_conn_backlog {
            if max_conn_backlog == 0 {
                return Err(ConfigError::MaxConnBacklogZero);
            }
            if max_conn_backlog > crate::queue::HARD_MAX_QUEUE_DEPTH {
                return Err(ConfigError::MaxConnBacklogTooLarge(max_conn_backlog));
            }
        }
        // (b) The CROSS-FIELD relationships are enforced ONLY under
        //     `--scheduler drr`, so a FIFO deployment with a small
        //     `--max-queue-depth` and the default (ignored) caps is
        //     byte-for-byte unaffected.  `Caps::new` additionally clamps
        //     to the hard ceilings as defence in depth.
        if self.scheduler == Scheduler::Drr {
            if self.per_flow_cap > self.max_queue_depth {
                return Err(ConfigError::PerFlowCapExceedsQueueDepth {
                    per_flow_cap: self.per_flow_cap,
                    max_queue_depth: self.max_queue_depth,
                });
            }
            // A per-connection aggregate cap larger than the global cap is
            // a contradiction (a single connection cannot be allowed more
            // backlog than the whole scheduler buffers); `Caps::new` would
            // silently clamp it, but a loud error is friendlier than a
            // surprising clamp.
            if let Some(max_conn_backlog) = self.max_conn_backlog {
                if max_conn_backlog > self.max_queue_depth {
                    return Err(ConfigError::MaxConnBacklogExceedsQueueDepth {
                        max_conn_backlog,
                        max_queue_depth: self.max_queue_depth,
                    });
                }
            }
        }
        Ok(())
    }
}

/// Parse-time errors.
#[derive(Debug, thiserror::Error)]
pub enum ParseError {
    /// Unknown flag.
    #[error("unknown flag: {0}")]
    UnknownFlag(String),
    /// Flag requires a value but none was supplied.
    #[error("flag '{0}' requires a value")]
    MissingValue(String),
    /// Flag's value could not be parsed as the expected type.
    #[error("flag '{flag}' value '{value}' invalid: {reason}")]
    InvalidValue {
        /// Flag name.
        flag: String,
        /// Supplied value.
        value: String,
        /// Parse-failure reason.
        reason: String,
    },
    /// Help was requested.  Not technically an error, but
    /// surfaces so `main` can print usage and exit cleanly.
    #[error("help requested")]
    HelpRequested,
    /// Version was requested.  Surfaces so `main` can print
    /// version and exit cleanly.
    #[error("version requested")]
    VersionRequested,
}

/// Validation-time errors.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// No listener flag was supplied.
    #[error(
        "no listener configured; specify at least one of \
         --listen <ADDR>, --tls-listen <ADDR>, or --unix-socket <PATH>"
    )]
    NoListenerConfigured,
    /// No kernel implementation was configured.
    #[error(
        "no kernel configured; specify --mock OR \
         (--knomosis-binary <PATH> AND --knomosis-log <PATH>)"
    )]
    NoKernelConfigured,
    /// `--tls-listen` requires both `--tls-cert` and `--tls-key`.
    #[error("--tls-listen requires both --tls-cert and --tls-key")]
    TlsListenWithoutCertKey,
    /// `--tls-cert` / `--tls-key` supplied but no `--tls-listen`.
    #[error("--tls-cert / --tls-key require a corresponding --tls-listen")]
    TlsCertKeyWithoutListen,
    /// Both `--mock` and `--knomosis-binary` supplied.
    #[error("--mock and --knomosis-binary are mutually exclusive")]
    ConflictingKernelChoice,
    /// `--max-queue-depth 0` rejected (would always return Busy).
    #[error("--max-queue-depth cannot be zero")]
    QueueDepthZero,
    /// `--max-queue-depth` above the hard ceiling.
    #[error("--max-queue-depth {0} exceeds hard ceiling")]
    QueueDepthTooLarge(usize),
    /// `--max-frame-size 0` rejected.
    #[error("--max-frame-size cannot be zero")]
    FrameSizeZero,
    /// `--max-frame-size` above the hard ceiling.
    #[error("--max-frame-size {0} exceeds hard ceiling")]
    FrameSizeTooLarge(usize),
    /// `--max-concurrent-connections 0` rejected.
    #[error("--max-concurrent-connections cannot be zero")]
    ConcurrentConnectionsZero,
    /// `--max-concurrent-connections` above the hard ceiling.
    #[error("--max-concurrent-connections {0} exceeds hard ceiling")]
    ConcurrentConnectionsTooLarge(usize),
    /// `--budget-policy` supplied with a value other than `bounded`.
    #[error("--budget-policy '{0}' unrecognised; the only supported mode is 'bounded'")]
    UnknownBudgetMode(String),
    /// `--scheduler` supplied with a value other than `fifo` / `drr`.
    #[error("--scheduler '{0}' unrecognised; valid values are 'fifo' or 'drr'")]
    UnknownScheduler(String),
    /// `--per-flow-cap 0` (a flow could buffer nothing).  Intrinsically
    /// invalid, so rejected under any scheduler.
    #[error("--per-flow-cap cannot be zero")]
    PerFlowCapZero,
    /// `--scheduler drr` with `--per-flow-cap` exceeding the global
    /// `--max-queue-depth` (a per-flow cap above the global cap can
    /// never bind).  This cross-field check is enforced only under
    /// `--scheduler drr`.
    #[error(
        "--per-flow-cap {per_flow_cap} exceeds --max-queue-depth {max_queue_depth} \
         under --scheduler drr (the per-flow cap must not exceed the global cap)"
    )]
    PerFlowCapExceedsQueueDepth {
        /// The configured per-flow cap.
        per_flow_cap: usize,
        /// The configured global (queue-depth) cap.
        max_queue_depth: usize,
    },
    /// `--max-flows 0` (no flow could ever be admitted).  Intrinsically
    /// invalid, so rejected under any scheduler.
    #[error("--max-flows cannot be zero")]
    MaxFlowsZero,
    /// `--max-flows` above the hard ceiling.  Intrinsically invalid, so
    /// rejected under any scheduler.
    #[error("--max-flows {0} exceeds hard ceiling")]
    MaxFlowsTooLarge(usize),
    /// `--max-signers-per-conn 0` (a connection could route no
    /// requests).  Intrinsically invalid, so rejected under any
    /// scheduler (Rung 1).
    #[error("--max-signers-per-conn cannot be zero")]
    MaxSignersPerConnZero,
    /// `--max-signers-per-conn` above the hard ceiling.  Intrinsically
    /// invalid, so rejected under any scheduler (Rung 1).
    #[error("--max-signers-per-conn {0} exceeds hard ceiling")]
    MaxSignersPerConnTooLarge(usize),
    /// `--max-conn-backlog 0` (a connection could buffer nothing).
    /// Intrinsically invalid, so rejected under any scheduler (Rung 1.5).
    #[error("--max-conn-backlog cannot be zero")]
    MaxConnBacklogZero,
    /// `--max-conn-backlog` above the hard ceiling.  Intrinsically
    /// invalid, so rejected under any scheduler (Rung 1.5).
    #[error("--max-conn-backlog {0} exceeds hard ceiling")]
    MaxConnBacklogTooLarge(usize),
    /// `--scheduler drr` with `--max-conn-backlog` exceeding the global
    /// `--max-queue-depth` (a single connection cannot be permitted more
    /// backlog than the whole scheduler buffers).  This cross-field check
    /// is enforced only under `--scheduler drr`.
    #[error(
        "--max-conn-backlog {max_conn_backlog} exceeds --max-queue-depth {max_queue_depth} \
         under --scheduler drr (a connection's aggregate cap must not exceed the global cap)"
    )]
    MaxConnBacklogExceedsQueueDepth {
        /// The configured per-connection aggregate cap.
        max_conn_backlog: usize,
        /// The configured global (queue-depth) cap.
        max_queue_depth: usize,
    },
}

/// Parse command-line arguments into a `Config`.
///
/// `args` is the full argv including `argv[0]` (the binary name);
/// the first element is ignored.
///
/// # Errors
///
/// See [`ParseError`].  Help / version requests surface as
/// `HelpRequested` / `VersionRequested` so the caller can decide
/// to print usage and exit cleanly.
pub fn parse_args(args: &[String]) -> Result<Config, ParseError> {
    let mut cfg = Config::defaults();
    let mut iter = args.iter().skip(1);
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--help" | "-h" => return Err(ParseError::HelpRequested),
            "--version" | "-v" => return Err(ParseError::VersionRequested),
            "--mock" => cfg.use_mock_kernel = true,
            "--persistent-connections" => cfg.persistent_connections = true,
            "--listen" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--listen".into()))?;
                let addr = value
                    .parse::<SocketAddr>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--listen".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.tcp_listen = Some(addr);
            }
            "--tls-listen" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--tls-listen".into()))?;
                let addr = value
                    .parse::<SocketAddr>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--tls-listen".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.tls_listen = Some(addr);
            }
            "--tls-cert" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--tls-cert".into()))?;
                cfg.tls_cert = Some(PathBuf::from(value));
            }
            "--tls-key" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--tls-key".into()))?;
                cfg.tls_key = Some(PathBuf::from(value));
            }
            "--unix-socket" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--unix-socket".into()))?;
                cfg.unix_socket = Some(PathBuf::from(value));
            }
            "--knomosis-binary" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--knomosis-binary".into()))?;
                cfg.knomosis_binary = Some(PathBuf::from(value));
            }
            "--knomosis-log" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--knomosis-log".into()))?;
                cfg.knomosis_log = Some(PathBuf::from(value));
            }
            "--knomosis-work-dir" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--knomosis-work-dir".into()))?;
                cfg.knomosis_work_dir = Some(PathBuf::from(value));
            }
            "--deployment-id" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--deployment-id".into()))?;
                cfg.deployment_id = Some(value.clone());
            }
            "--budget-policy" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--budget-policy".into()))?;
                cfg.budget_mode = Some(value.clone());
            }
            "--free-tier" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--free-tier".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--free-tier".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.budget_free_tier = Some(n);
            }
            "--action-cost" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--action-cost".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--action-cost".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.budget_action_cost = Some(n);
            }
            "--current-epoch" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--current-epoch".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--current-epoch".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.budget_current_epoch = Some(n);
            }
            "--epoch-length" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--epoch-length".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--epoch-length".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.budget_epoch_length = Some(n);
            }
            "--gas-pool-eth-cap" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--gas-pool-eth-cap".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--gas-pool-eth-cap".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.gas_pool_eth_cap = Some(n);
            }
            "--gas-pool-bold-cap" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--gas-pool-bold-cap".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--gas-pool-bold-cap".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.gas_pool_bold_cap = Some(n);
            }
            "--wei-per-budget-unit-eth" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--wei-per-budget-unit-eth".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--wei-per-budget-unit-eth".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.refund_rate_eth = Some(n);
            }
            "--wei-per-budget-unit-bold" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--wei-per-budget-unit-bold".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--wei-per-budget-unit-bold".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.refund_rate_bold = Some(n);
            }
            "--scheduler" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--scheduler".into()))?;
                // An unrecognised scheduler mode is a *configuration*
                // error (like `--budget-policy <bad>`), not a parse
                // error: defer it to `validate` so it surfaces as a clear
                // `ConfigError::UnknownScheduler`.  On a valid value set
                // the resolved field and clear any earlier bad value
                // (last-flag-wins for repeated `--scheduler`).
                match value.parse::<Scheduler>() {
                    Ok(s) => {
                        cfg.scheduler = s;
                        cfg.scheduler_unrecognized = None;
                    }
                    Err(_) => cfg.scheduler_unrecognized = Some(value.clone()),
                }
            }
            "--per-flow-cap" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--per-flow-cap".into()))?;
                let n = value
                    .parse::<usize>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--per-flow-cap".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.per_flow_cap = n;
            }
            "--max-flows" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--max-flows".into()))?;
                let n = value
                    .parse::<usize>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--max-flows".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.max_flows = n;
            }
            "--max-signers-per-conn" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--max-signers-per-conn".into()))?;
                let n = value
                    .parse::<usize>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--max-signers-per-conn".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.max_signers_per_conn = n;
            }
            "--max-conn-backlog" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--max-conn-backlog".into()))?;
                let n = value
                    .parse::<usize>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--max-conn-backlog".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.max_conn_backlog = Some(n);
            }
            "--max-queue-depth" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--max-queue-depth".into()))?;
                let n = value
                    .parse::<usize>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--max-queue-depth".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.max_queue_depth = n;
            }
            "--max-frame-size" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--max-frame-size".into()))?;
                let n = value
                    .parse::<usize>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--max-frame-size".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.max_frame_size = n;
            }
            "--max-concurrent-connections" => {
                let value = iter.next().ok_or_else(|| {
                    ParseError::MissingValue("--max-concurrent-connections".into())
                })?;
                let n = value
                    .parse::<usize>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--max-concurrent-connections".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.max_concurrent_connections = n;
            }
            other => return Err(ParseError::UnknownFlag(other.to_string())),
        }
    }
    Ok(cfg)
}

/// Format the help text.  Returned as a `String` so the caller
/// can decide whether to print to stdout (success) or stderr
/// (parse error context).
#[must_use]
pub fn help_text(program_name: &str) -> String {
    format!(
        "{program_name} — Knomosis host network adaptor (RH-C)\n\
         \n\
         Usage:\n\
         \x20 {program_name} --listen 127.0.0.1:7654 --mock\n\
         \x20 {program_name} --unix-socket /var/run/knomosis.sock --knomosis-binary /path/to/knomosis \\\n\
         \x20\x20\x20\x20\x20\x20 --knomosis-log /var/lib/knomosis/log.bin\n\
         \n\
         Listener flags (at least one required):\n\
         \x20 --listen <ADDR>           TCP listen address (e.g. 127.0.0.1:7654)\n\
         \x20 --tls-listen <ADDR>       TLS-on-TCP listen address (requires --tls-cert/--tls-key)\n\
         \x20 --unix-socket <PATH>      Unix-socket path (mode 0600)\n\
         \n\
         TLS:\n\
         \x20 --tls-cert <PATH>         PEM-encoded TLS certificate\n\
         \x20 --tls-key <PATH>          PEM-encoded TLS private key\n\
         \n\
         Kernel (at least one required):\n\
         \x20 --mock                    Use in-memory MockKernel (test / dev only)\n\
         \x20 --knomosis-binary <PATH>     Path to the `knomosis` binary\n\
         \x20 --knomosis-log <PATH>        Persistent log file shared across requests\n\
         \x20 --knomosis-work-dir <PATH>   Per-request temp work directory\n\
         \x20 --deployment-id <HEX>     32-byte deployment id (hex) passed to knomosis\n\
         \n\
         Budget gate (GP.6.2; optional):\n\
         \x20 --budget-policy bounded   Enable the per-actor epoch-budget admission gate\n\
         \x20 --free-tier <N>           Per-epoch budget floor (default 0)\n\
         \x20 --action-cost <C>         Per-action budget debit (clamped >= 1; default 1)\n\
         \x20 --current-epoch <E>       Current epoch index (default 0; free tier needs E >= 1)\n\
         \x20 --epoch-length <N>        Admitted actions per budget epoch (0 = no advancement)\n\
         \x20 --gas-pool-eth-cap <N>    Enable the GP.7.4 gas-pool genesis (ETH-leg per-action cap)\n\
         \x20 --gas-pool-bold-cap <N>   Gas-pool BOLD-leg per-action cap (enables if either is set)\n\
         \x20 --wei-per-budget-unit-eth <N>  Enable GP.9.1 refund-on-exit (ETH-leg rate; 0 = off)\n\
         \x20 --wei-per-budget-unit-bold <N> Refund-on-exit BOLD-leg rate (enables if either is set)\n\
         \n\
         Fair sequencing (FQ Rung 0/1; optional, default off):\n\
         \x20 --scheduler <fifo|drr>    Worker scheduler (default fifo; drr = two-tier DRR)\n\
         \x20 --per-flow-cap <N>        DRR per-(conn,signer) backlog cap (default 64; drr only)\n\
         \x20 --max-flows <N>           DRR cap on distinct active connections (default 4096; drr only)\n\
         \x20 --max-signers-per-conn <N>\n\
         \x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20Rung-1 cap on distinct signer hints within one connection (default 256; drr only)\n\
         \x20 --max-conn-backlog <N>    Per-connection aggregate backlog cap (default = --per-flow-cap; drr only)\n\
         \x20 --persistent-connections  Pipeline many requests per TCP/Unix connection (default off; makes DRR bite over the wire)\n\
         \n\
         Tuning:\n\
         \x20 --max-queue-depth <N>     Bounded queue size / DRR global cap (default 256)\n\
         \x20 --max-frame-size <N>      Max accepted frame size in bytes (default 1 MiB)\n\
         \x20 --max-concurrent-connections <N>\n\
         \x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20Cap on simultaneous connection handlers (default 1024)\n\
         \n\
         Other:\n\
         \x20 --help / -h               Print this help text\n\
         \x20 --version / -v            Print the host version\n\
         \n\
         See `docs/abi.md` §10 for the wire-format specification and\n\
         `docs/planning/rust_host_runtime_plan.md` §RH-C for the design.\n",
    )
}

#[cfg(test)]
mod tests {
    use super::{parse_args, Config, ConfigError, ParseError};

    fn args(items: &[&str]) -> Vec<String> {
        let mut v = vec!["knomosis-host".to_string()];
        v.extend(items.iter().map(|s| (*s).to_string()));
        v
    }

    /// Default config has nothing set; validate fails.
    #[test]
    fn defaults_fail_validation() {
        let cfg = Config::defaults();
        match cfg.validate() {
            Err(ConfigError::NoListenerConfigured) => {}
            other => panic!("expected NoListenerConfigured, got {other:?}"),
        }
    }

    /// `--listen --mock` parses + validates.
    #[test]
    fn listen_plus_mock_validates() {
        let cfg = parse_args(&args(&["--listen", "127.0.0.1:7654", "--mock"])).unwrap();
        assert_eq!(cfg.tcp_listen.unwrap().port(), 7654);
        assert!(cfg.use_mock_kernel);
        cfg.validate().unwrap();
    }

    /// `--unix-socket --mock` parses + validates.
    #[test]
    fn unix_plus_mock_validates() {
        let cfg = parse_args(&args(&["--unix-socket", "/tmp/x.sock", "--mock"])).unwrap();
        assert_eq!(
            cfg.unix_socket.as_deref(),
            Some(std::path::Path::new("/tmp/x.sock"))
        );
        cfg.validate().unwrap();
    }

    /// `--help` returns `HelpRequested`.
    #[test]
    fn help_returns_help_requested() {
        match parse_args(&args(&["--help"])) {
            Err(ParseError::HelpRequested) => {}
            other => panic!("expected HelpRequested, got {other:?}"),
        }
    }

    /// `-h` short form returns `HelpRequested`.
    #[test]
    fn h_short_returns_help_requested() {
        match parse_args(&args(&["-h"])) {
            Err(ParseError::HelpRequested) => {}
            other => panic!("expected HelpRequested, got {other:?}"),
        }
    }

    /// `--version` returns `VersionRequested`.
    #[test]
    fn version_returns_version_requested() {
        match parse_args(&args(&["--version"])) {
            Err(ParseError::VersionRequested) => {}
            other => panic!("expected VersionRequested, got {other:?}"),
        }
    }

    /// Unknown flag returns `UnknownFlag`.
    #[test]
    fn unknown_flag_returns_error() {
        match parse_args(&args(&["--bogus"])) {
            Err(ParseError::UnknownFlag(s)) => assert_eq!(s, "--bogus"),
            other => panic!("expected UnknownFlag, got {other:?}"),
        }
    }

    /// GP.8 Track C: the epoch clock is an **action** clock (epochs
    /// advance by `--current-epoch` / `--epoch-length`, not by
    /// wall-clock seconds).  Pin that no `--epoch-duration-seconds`
    /// flag exists, so a wall-clock epoch policy can never be
    /// silently introduced.
    #[test]
    fn epoch_duration_seconds_flag_does_not_exist() {
        match parse_args(&args(&["--epoch-duration-seconds", "60"])) {
            Err(ParseError::UnknownFlag(s)) => assert_eq!(s, "--epoch-duration-seconds"),
            other => panic!("expected UnknownFlag for the wall-clock flag, got {other:?}"),
        }
    }

    /// Missing value returns `MissingValue`.
    #[test]
    fn missing_value_returns_error() {
        match parse_args(&args(&["--listen"])) {
            Err(ParseError::MissingValue(s)) => assert_eq!(s, "--listen"),
            other => panic!("expected MissingValue, got {other:?}"),
        }
    }

    /// Invalid listener addr returns `InvalidValue`.
    #[test]
    fn invalid_listen_returns_error() {
        match parse_args(&args(&["--listen", "not-an-addr", "--mock"])) {
            Err(ParseError::InvalidValue { flag, .. }) => assert_eq!(flag, "--listen"),
            other => panic!("expected InvalidValue, got {other:?}"),
        }
    }

    /// `--tls-listen` without cert/key fails validation.
    #[test]
    fn tls_listen_without_cert_key_fails() {
        let cfg = parse_args(&args(&["--tls-listen", "127.0.0.1:8443", "--mock"])).unwrap();
        match cfg.validate() {
            Err(ConfigError::TlsListenWithoutCertKey) => {}
            other => panic!("expected TlsListenWithoutCertKey, got {other:?}"),
        }
    }

    /// `--tls-cert` without `--tls-listen` fails validation.
    #[test]
    fn tls_cert_without_listen_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--tls-cert",
            "/tmp/cert.pem",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::TlsCertKeyWithoutListen) => {}
            other => panic!("expected TlsCertKeyWithoutListen, got {other:?}"),
        }
    }

    /// `--mock` + `--knomosis-binary` is contradictory.
    #[test]
    fn mock_plus_knomosis_binary_conflicts() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--knomosis-binary",
            "/bin/true",
            "--knomosis-log",
            "/tmp/log",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::ConflictingKernelChoice) => {}
            other => panic!("expected ConflictingKernelChoice, got {other:?}"),
        }
    }

    /// `--max-queue-depth 0` fails.
    #[test]
    fn queue_depth_zero_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--max-queue-depth",
            "0",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::QueueDepthZero) => {}
            other => panic!("expected QueueDepthZero, got {other:?}"),
        }
    }

    /// `--max-queue-depth` above hard cap fails.
    #[test]
    fn queue_depth_too_large_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--max-queue-depth",
            "999999999",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::QueueDepthTooLarge(_)) => {}
            other => panic!("expected QueueDepthTooLarge, got {other:?}"),
        }
    }

    /// `--max-frame-size 0` fails.
    #[test]
    fn frame_size_zero_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--max-frame-size",
            "0",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::FrameSizeZero) => {}
            other => panic!("expected FrameSizeZero, got {other:?}"),
        }
    }

    /// `--max-concurrent-connections 0` fails.
    #[test]
    fn concurrent_connections_zero_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--max-concurrent-connections",
            "0",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::ConcurrentConnectionsZero) => {}
            other => panic!("expected ConcurrentConnectionsZero, got {other:?}"),
        }
    }

    /// `--max-concurrent-connections` above hard cap fails.
    #[test]
    fn concurrent_connections_too_large_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--max-concurrent-connections",
            "9999999",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::ConcurrentConnectionsTooLarge(_)) => {}
            other => panic!("expected ConcurrentConnectionsTooLarge, got {other:?}"),
        }
    }

    /// `--max-concurrent-connections` is plumbed through.
    #[test]
    fn concurrent_connections_plumbed() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--max-concurrent-connections",
            "512",
        ]))
        .unwrap();
        assert_eq!(cfg.max_concurrent_connections, 512);
        cfg.validate().unwrap();
    }

    /// `--max-frame-size` above hard cap fails.
    #[test]
    fn frame_size_too_large_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--max-frame-size",
            "999999999",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::FrameSizeTooLarge(_)) => {}
            other => panic!("expected FrameSizeTooLarge, got {other:?}"),
        }
    }

    /// `--knomosis-binary` + `--knomosis-log` is a valid kernel choice.
    #[test]
    fn knomosis_binary_plus_log_validates() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--knomosis-binary",
            "/bin/true",
            "--knomosis-log",
            "/tmp/log",
        ]))
        .unwrap();
        cfg.validate().unwrap();
    }

    /// Missing kernel choice fails.
    #[test]
    fn no_kernel_choice_fails() {
        let cfg = parse_args(&args(&["--listen", "127.0.0.1:7654"])).unwrap();
        match cfg.validate() {
            Err(ConfigError::NoKernelConfigured) => {}
            other => panic!("expected NoKernelConfigured, got {other:?}"),
        }
    }

    /// All flags exercised together.
    #[test]
    fn all_flags_together() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--unix-socket",
            "/tmp/x.sock",
            "--mock",
            "--max-queue-depth",
            "16",
            "--max-frame-size",
            "2048",
            "--deployment-id",
            "deadbeef",
        ]))
        .unwrap();
        assert!(cfg.tcp_listen.is_some());
        assert!(cfg.unix_socket.is_some());
        assert!(cfg.use_mock_kernel);
        assert_eq!(cfg.max_queue_depth, 16);
        assert_eq!(cfg.max_frame_size, 2048);
        assert_eq!(cfg.deployment_id.as_deref(), Some("deadbeef"));
        cfg.validate().unwrap();
    }

    /// Help text is non-empty and mentions the binary name.
    #[test]
    fn help_text_non_empty() {
        let text = super::help_text("knomosis-host");
        assert!(!text.is_empty());
        assert!(text.contains("knomosis-host"));
        assert!(text.contains("--listen"));
        assert!(text.contains("--mock"));
        assert!(text.contains("--tls-cert"));
    }

    /// `ParseError` and `ConfigError` are `Send + Sync`.
    #[test]
    fn errors_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ParseError>();
        assert_send_sync::<ConfigError>();
    }

    /// GP.6.2: the budget flags parse and assemble a bounded policy.
    #[test]
    fn budget_flags_parse_and_assemble() {
        use crate::budget::BudgetPolicy;
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--budget-policy",
            "bounded",
            "--free-tier",
            "5",
            "--action-cost",
            "2",
            "--current-epoch",
            "1",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.budget_policy(), Some(BudgetPolicy::mk_bounded(5, 2, 1)));
    }

    /// No budget flags → no policy (back-compat: genesis default).
    #[test]
    fn no_budget_flags_no_policy() {
        let cfg = parse_args(&args(&["--listen", "127.0.0.1:7654", "--mock"])).unwrap();
        assert!(cfg.budget_policy().is_none());
        cfg.validate().unwrap();
    }

    /// A budget sub-flag without an explicit `--budget-policy`
    /// defaults to bounded mode (with the other fields defaulted).
    #[test]
    fn budget_subflag_defaults_to_bounded() {
        use crate::budget::BudgetPolicy;
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--free-tier",
            "7",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.budget_policy(), Some(BudgetPolicy::mk_bounded(7, 1, 0)));
    }

    /// `--action-cost` is clamped to `>= 1` (matching the Lean
    /// smart constructor).
    #[test]
    fn budget_action_cost_clamped() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--budget-policy",
            "bounded",
            "--action-cost",
            "0",
        ]))
        .unwrap();
        assert_eq!(cfg.budget_policy().unwrap().action_cost(), 1);
    }

    /// A non-`bounded` budget mode fails validation.
    #[test]
    fn unknown_budget_mode_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--budget-policy",
            "unlimited",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::UnknownBudgetMode(m)) => assert_eq!(m, "unlimited"),
            other => panic!("expected UnknownBudgetMode, got {other:?}"),
        }
    }

    /// A non-numeric `--free-tier` value is a parse error.
    #[test]
    fn budget_free_tier_non_numeric_fails() {
        match parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--free-tier",
            "lots",
        ])) {
            Err(ParseError::InvalidValue { flag, .. }) => assert_eq!(flag, "--free-tier"),
            other => panic!("expected InvalidValue, got {other:?}"),
        }
    }

    /// Help text mentions the budget flags.
    #[test]
    fn help_text_mentions_budget_flags() {
        let text = super::help_text("knomosis-host");
        assert!(text.contains("--budget-policy"));
        assert!(text.contains("--free-tier"));
        assert!(text.contains("--action-cost"));
        assert!(text.contains("--current-epoch"));
        assert!(text.contains("--epoch-length"));
        // GP.9.1 refund-on-exit rate flags.
        assert!(text.contains("--wei-per-budget-unit-eth"));
        assert!(text.contains("--wei-per-budget-unit-bold"));
    }

    /// GP.9.1: both refund-rate flags parse and assemble into
    /// `refund_rate()`.
    #[test]
    fn refund_rate_flags_parse_and_assemble() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--wei-per-budget-unit-eth",
            "1000",
            "--wei-per-budget-unit-bold",
            "3000",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.refund_rate(), Some((1000, 3000)));
    }

    /// GP.9.1: no refund-rate flags → refunds disabled (back-compat).
    #[test]
    fn no_refund_rate_flags_disabled() {
        let cfg = parse_args(&args(&["--listen", "127.0.0.1:7654", "--mock"])).unwrap();
        assert!(cfg.refund_rate().is_none());
        cfg.validate().unwrap();
    }

    /// GP.9.1: supplying ONLY one rate enables refunds with the other
    /// leg defaulting to `0` (refunds disabled at that leg).
    #[test]
    fn refund_rate_single_leg_defaults_other_to_zero() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--wei-per-budget-unit-bold",
            "3000",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.refund_rate(), Some((0, 3000)));
    }

    /// GP.9.1: a non-numeric refund rate is a parse error.
    #[test]
    fn refund_rate_invalid_rejected() {
        match parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--wei-per-budget-unit-eth",
            "lots",
        ])) {
            Err(ParseError::InvalidValue { flag, .. }) => {
                assert_eq!(flag, "--wei-per-budget-unit-eth");
            }
            other => panic!("expected InvalidValue, got {other:?}"),
        }
    }

    /// GP.7.4: both gas-pool caps parse and assemble into
    /// `gas_pool_caps()`.
    #[test]
    fn gas_pool_flags_parse_and_assemble() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--gas-pool-eth-cap",
            "1000",
            "--gas-pool-bold-cap",
            "3000",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.gas_pool_caps(), Some((1000, 3000)));
    }

    /// GP.7.4: no gas-pool flags → gas pool disabled (back-compat).
    #[test]
    fn no_gas_pool_flags_disabled() {
        let cfg = parse_args(&args(&["--listen", "127.0.0.1:7654", "--mock"])).unwrap();
        assert!(cfg.gas_pool_caps().is_none());
        cfg.validate().unwrap();
    }

    /// GP.7.4: supplying ONLY one cap enables the gas pool with the
    /// other leg defaulting to `0` (that leg cannot drain).
    #[test]
    fn gas_pool_single_cap_defaults_other_to_zero() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--gas-pool-eth-cap",
            "1000",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.gas_pool_caps(), Some((1000, 0)));
    }

    /// GP.7.4: a non-numeric gas-pool cap is a parse error.
    #[test]
    fn gas_pool_invalid_cap_rejected() {
        match parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--gas-pool-eth-cap",
            "not-a-number",
        ])) {
            Err(ParseError::InvalidValue { flag, .. }) => assert_eq!(flag, "--gas-pool-eth-cap"),
            other => panic!("expected InvalidValue, got {other:?}"),
        }
    }

    /// GP.7.4: help text mentions the gas-pool flags.
    #[test]
    fn help_text_mentions_gas_pool_flags() {
        let text = super::help_text("knomosis-host");
        assert!(text.contains("--gas-pool-eth-cap"));
        assert!(text.contains("--gas-pool-bold-cap"));
    }

    /// GP.6.2: `--epoch-length` parses into `budget_epoch_length`.
    #[test]
    fn epoch_length_parses() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--budget-policy",
            "bounded",
            "--free-tier",
            "1",
            "--current-epoch",
            "1",
            "--epoch-length",
            "3",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.budget_epoch_length, Some(3));
    }

    /// A non-numeric `--epoch-length` is a parse error.
    #[test]
    fn epoch_length_non_numeric_fails() {
        match parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--epoch-length",
            "soon",
        ])) {
            Err(ParseError::InvalidValue { flag, .. }) => assert_eq!(flag, "--epoch-length"),
            other => panic!("expected InvalidValue, got {other:?}"),
        }
    }

    // ----- FQ Rung 0: scheduler + DRR caps ---------------------------

    /// The default scheduler is FIFO (the unchanged baseline).
    #[test]
    fn scheduler_defaults_to_fifo() {
        use super::Scheduler;
        let cfg = parse_args(&args(&["--listen", "127.0.0.1:7654", "--mock"])).unwrap();
        assert_eq!(cfg.scheduler, Scheduler::Fifo);
        cfg.validate().unwrap();
    }

    /// `--scheduler drr` / `--scheduler fifo` parse to the right variant.
    #[test]
    fn scheduler_flag_parses_both_values() {
        use super::Scheduler;
        let drr = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
        ]))
        .unwrap();
        assert_eq!(drr.scheduler, Scheduler::Drr);
        drr.validate().unwrap();
        let fifo = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "fifo",
        ]))
        .unwrap();
        assert_eq!(fifo.scheduler, Scheduler::Fifo);
        fifo.validate().unwrap();
    }

    /// An unrecognised scheduler value parses (deferred) but fails
    /// validation with a clear `ConfigError::UnknownScheduler` — the
    /// same defer-to-validate discipline `--budget-policy` uses.
    #[test]
    fn scheduler_invalid_value_is_config_error() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "bogus",
        ]))
        .unwrap();
        // Resolved field stays at the safe default until validation runs.
        assert_eq!(cfg.scheduler, super::Scheduler::Fifo);
        assert_eq!(cfg.scheduler_unrecognized.as_deref(), Some("bogus"));
        match cfg.validate() {
            Err(ConfigError::UnknownScheduler(v)) => assert_eq!(v, "bogus"),
            other => panic!("expected UnknownScheduler, got {other:?}"),
        }
    }

    /// Last-flag-wins: a valid `--scheduler` after an invalid one clears
    /// the recorded bad value, so validation passes.
    #[test]
    fn scheduler_last_valid_value_wins() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "bogus",
            "--scheduler",
            "drr",
        ]))
        .unwrap();
        assert_eq!(cfg.scheduler, super::Scheduler::Drr);
        assert!(cfg.scheduler_unrecognized.is_none());
        cfg.validate().unwrap();
    }

    /// `Scheduler` round-trips through `FromStr` / `Display` / `name`.
    #[test]
    fn scheduler_fromstr_display_roundtrip() {
        use super::Scheduler;
        for (s, name) in [(Scheduler::Fifo, "fifo"), (Scheduler::Drr, "drr")] {
            assert_eq!(s.name(), name);
            assert_eq!(format!("{s}"), name);
            assert_eq!(name.parse::<Scheduler>().unwrap(), s);
        }
        assert!("nope".parse::<Scheduler>().is_err());
    }

    /// The DRR cap flags parse and `caps()` assembles them (global =
    /// max-queue-depth).
    #[test]
    fn drr_caps_parse_and_assemble() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
            "--per-flow-cap",
            "8",
            "--max-flows",
            "100",
            "--max-queue-depth",
            "200",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.per_flow_cap, 8);
        assert_eq!(cfg.max_flows, 100);
        let caps = cfg.caps();
        assert_eq!(caps.per_flow, 8);
        assert_eq!(caps.max_flows, 100);
        assert_eq!(caps.global, 200);
    }

    /// The DRR caps default to the documented values.
    #[test]
    fn drr_caps_have_documented_defaults() {
        use super::{DEFAULT_MAX_FLOWS, DEFAULT_PER_FLOW_CAP};
        let cfg = parse_args(&args(&["--listen", "127.0.0.1:7654", "--mock"])).unwrap();
        assert_eq!(cfg.per_flow_cap, DEFAULT_PER_FLOW_CAP);
        assert_eq!(cfg.max_flows, DEFAULT_MAX_FLOWS);
    }

    /// A non-numeric `--per-flow-cap` / `--max-flows` is a parse error.
    #[test]
    fn drr_caps_non_numeric_are_parse_errors() {
        for flag in ["--per-flow-cap", "--max-flows"] {
            match parse_args(&args(&[
                "--listen",
                "127.0.0.1:7654",
                "--mock",
                flag,
                "lots",
            ])) {
                Err(ParseError::InvalidValue { flag: f, .. }) => assert_eq!(f, flag),
                other => panic!("expected InvalidValue for {flag}, got {other:?}"),
            }
        }
    }

    /// `--scheduler drr --per-flow-cap 0` is rejected.
    #[test]
    fn drr_per_flow_cap_zero_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
            "--per-flow-cap",
            "0",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::PerFlowCapZero) => {}
            other => panic!("expected PerFlowCapZero, got {other:?}"),
        }
    }

    /// `--scheduler drr` with per-flow-cap above the global queue depth
    /// is rejected.
    #[test]
    fn drr_per_flow_cap_above_queue_depth_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
            "--per-flow-cap",
            "500",
            "--max-queue-depth",
            "256",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::PerFlowCapExceedsQueueDepth {
                per_flow_cap,
                max_queue_depth,
            }) => {
                assert_eq!(per_flow_cap, 500);
                assert_eq!(max_queue_depth, 256);
            }
            other => panic!("expected PerFlowCapExceedsQueueDepth, got {other:?}"),
        }
    }

    /// `--scheduler drr --max-flows 0` is rejected.
    #[test]
    fn drr_max_flows_zero_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
            "--max-flows",
            "0",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxFlowsZero) => {}
            other => panic!("expected MaxFlowsZero, got {other:?}"),
        }
    }

    /// `--scheduler drr --max-flows <huge>` is rejected.
    #[test]
    fn drr_max_flows_too_large_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
            "--max-flows",
            "99999999",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxFlowsTooLarge(_)) => {}
            other => panic!("expected MaxFlowsTooLarge, got {other:?}"),
        }
    }

    /// FQ.5 regression: a FIFO deployment with a small `--max-queue-depth`
    /// and the *default* per-flow cap still validates — the cap checks
    /// are gated on `--scheduler drr`, so FIFO behaviour is unchanged.
    #[test]
    fn fifo_small_queue_depth_unaffected_by_caps() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--max-queue-depth",
            "8",
        ]))
        .unwrap();
        // Default per_flow_cap (64) > max_queue_depth (8), but FIFO mode
        // never validates it.
        assert!(cfg.per_flow_cap > cfg.max_queue_depth);
        cfg.validate().unwrap();
    }

    /// FIFO mode skips the CROSS-FIELD check (`per_flow_cap` may exceed
    /// `max_queue_depth` when it is going to be ignored anyway).
    #[test]
    fn fifo_mode_skips_cross_field_cap_check() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "fifo",
            "--per-flow-cap",
            "500",
            "--max-queue-depth",
            "256",
        ]))
        .unwrap();
        assert!(cfg.per_flow_cap > cfg.max_queue_depth);
        cfg.validate().unwrap();
    }

    /// INTRINSIC cap sanity (`per_flow_cap >= 1`) is enforced regardless
    /// of scheduler — a value of 0 is nonsense for any scheduler and
    /// fails fast even in FIFO mode.
    #[test]
    fn intrinsic_per_flow_cap_zero_rejected_even_in_fifo() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "fifo",
            "--per-flow-cap",
            "0",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::PerFlowCapZero) => {}
            other => panic!("expected PerFlowCapZero, got {other:?}"),
        }
    }

    /// INTRINSIC cap sanity (`max_flows >= 1`) is enforced regardless of
    /// scheduler.
    #[test]
    fn intrinsic_max_flows_zero_rejected_even_in_fifo() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "fifo",
            "--max-flows",
            "0",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxFlowsZero) => {}
            other => panic!("expected MaxFlowsZero, got {other:?}"),
        }
    }

    /// Help text mentions the FQ scheduler / cap flags.
    #[test]
    fn help_text_mentions_scheduler_flags() {
        let text = super::help_text("knomosis-host");
        assert!(text.contains("--scheduler"));
        assert!(text.contains("--per-flow-cap"));
        assert!(text.contains("--max-flows"));
        assert!(text.contains("--max-signers-per-conn"));
        assert!(text.contains("--max-conn-backlog"));
    }

    // ----- FQ.12: --max-signers-per-conn (the Rung-1 inner cap) -------

    /// `--max-signers-per-conn <N>` parses and plumbs into `caps()`.
    #[test]
    fn max_signers_per_conn_parses_and_assembles() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
            "--max-signers-per-conn",
            "128",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.max_signers_per_conn, 128);
        assert_eq!(cfg.caps().max_signers, 128);
    }

    /// The default is `DEFAULT_MAX_SIGNERS_PER_CONN`.
    #[test]
    fn max_signers_per_conn_default() {
        use super::DEFAULT_MAX_SIGNERS_PER_CONN;
        let cfg = parse_args(&args(&["--listen", "127.0.0.1:7654", "--mock"])).unwrap();
        assert_eq!(cfg.max_signers_per_conn, DEFAULT_MAX_SIGNERS_PER_CONN);
        assert_eq!(cfg.caps().max_signers, DEFAULT_MAX_SIGNERS_PER_CONN);
    }

    /// A non-numeric value is a parse error.
    #[test]
    fn max_signers_per_conn_non_numeric_is_parse_error() {
        match parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--max-signers-per-conn",
            "lots",
        ])) {
            Err(ParseError::InvalidValue { flag, .. }) => {
                assert_eq!(flag, "--max-signers-per-conn");
            }
            other => panic!("expected InvalidValue, got {other:?}"),
        }
    }

    /// `--max-signers-per-conn 0` is rejected — INTRINSICALLY, under ANY
    /// scheduler (a connection could route nothing), mirroring
    /// `--per-flow-cap` / `--max-flows`.
    #[test]
    fn max_signers_per_conn_zero_rejected_even_in_fifo() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "fifo",
            "--max-signers-per-conn",
            "0",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxSignersPerConnZero) => {}
            other => panic!("expected MaxSignersPerConnZero, got {other:?}"),
        }
    }

    /// `--max-signers-per-conn <huge>` is rejected (above the hard
    /// ceiling), under any scheduler.
    #[test]
    fn max_signers_per_conn_too_large_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
            "--max-signers-per-conn",
            "99999999",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxSignersPerConnTooLarge(n)) => assert_eq!(n, 99_999_999),
            other => panic!("expected MaxSignersPerConnTooLarge, got {other:?}"),
        }
    }

    // ----- Rung 1.5: --max-conn-backlog (per-connection aggregate) ----

    /// `--max-conn-backlog <N>` parses and plumbs into `caps()`.
    #[test]
    fn max_conn_backlog_parses_and_assembles() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
            "--max-conn-backlog",
            "32",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.max_conn_backlog, Some(32));
        assert_eq!(cfg.caps().max_conn_backlog, 32);
    }

    /// The default is absent (`None`), resolving in `caps()` to
    /// `per_flow_cap` (the Rung-0 per-connection bound), NOT the global
    /// cap — so the two-tier split doesn't relax per-connection
    /// backpressure to `max_signers × per_flow`.
    #[test]
    fn max_conn_backlog_default_is_per_flow_cap() {
        let cfg = parse_args(&args(&["--listen", "127.0.0.1:7654", "--mock"])).unwrap();
        assert_eq!(cfg.max_conn_backlog, None);
        // Resolves to per_flow_cap (== 64 by default), the restored
        // Rung-0 per-connection bound.
        assert_eq!(cfg.caps().max_conn_backlog, cfg.per_flow_cap);
        assert_eq!(cfg.caps().max_conn_backlog, cfg.caps().per_flow);
    }

    /// A non-numeric value is a parse error.
    #[test]
    fn max_conn_backlog_non_numeric_is_parse_error() {
        match parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--max-conn-backlog",
            "many",
        ])) {
            Err(ParseError::InvalidValue { flag, .. }) => {
                assert_eq!(flag, "--max-conn-backlog");
            }
            other => panic!("expected InvalidValue, got {other:?}"),
        }
    }

    /// `--max-conn-backlog 0` is rejected — INTRINSICALLY, under ANY
    /// scheduler (a connection could buffer nothing), mirroring the
    /// sibling caps.
    #[test]
    fn max_conn_backlog_zero_rejected_even_in_fifo() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "fifo",
            "--max-conn-backlog",
            "0",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxConnBacklogZero) => {}
            other => panic!("expected MaxConnBacklogZero, got {other:?}"),
        }
    }

    /// `--max-conn-backlog <huge>` is rejected (above the hard ceiling),
    /// under any scheduler.
    #[test]
    fn max_conn_backlog_too_large_fails() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
            "--max-conn-backlog",
            "99999999",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxConnBacklogTooLarge(n)) => assert_eq!(n, 99_999_999),
            other => panic!("expected MaxConnBacklogTooLarge, got {other:?}"),
        }
    }

    /// Under `--scheduler drr`, a `--max-conn-backlog` exceeding the
    /// global `--max-queue-depth` is a loud cross-field error (a single
    /// connection cannot be permitted more backlog than the whole
    /// scheduler buffers).
    #[test]
    fn max_conn_backlog_exceeds_queue_depth_under_drr() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "drr",
            "--max-queue-depth",
            "100",
            "--max-conn-backlog",
            "200",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxConnBacklogExceedsQueueDepth {
                max_conn_backlog,
                max_queue_depth,
            }) => {
                assert_eq!(max_conn_backlog, 200);
                assert_eq!(max_queue_depth, 100);
            }
            other => panic!("expected MaxConnBacklogExceedsQueueDepth, got {other:?}"),
        }
    }

    // ----- --persistent-connections (pipelined wire mode) ------------

    /// `--persistent-connections` parses to `true` and plumbs into the
    /// handler config; the default is `false`.
    #[test]
    fn persistent_connections_flag_parses() {
        let default = parse_args(&args(&["--listen", "127.0.0.1:7654", "--mock"])).unwrap();
        assert!(!default.persistent_connections, "default is one-shot");

        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--persistent-connections",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert!(cfg.persistent_connections);
    }

    /// The help text mentions `--persistent-connections`.
    #[test]
    fn help_text_mentions_persistent_connections() {
        let text = super::help_text("knomosis-host");
        assert!(text.contains("--persistent-connections"));
    }

    /// The same `--max-conn-backlog > --max-queue-depth` shape is NOT a
    /// cross-field error under FIFO (the DRR caps are ignored there); only
    /// the intrinsic ceiling applies, so it validates clean.
    #[test]
    fn max_conn_backlog_exceeds_queue_depth_ignored_under_fifo() {
        let cfg = parse_args(&args(&[
            "--listen",
            "127.0.0.1:7654",
            "--mock",
            "--scheduler",
            "fifo",
            "--max-queue-depth",
            "100",
            "--max-conn-backlog",
            "200",
        ]))
        .unwrap();
        cfg.validate()
            .expect("DRR cross-field check skipped under fifo");
    }
}
