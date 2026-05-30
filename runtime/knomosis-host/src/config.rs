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
//! | `--max-queue-depth <N>`| optional | Bounded queue size (default 256)                     |
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

use crate::budget::BudgetPolicy;

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
            use_mock_kernel: false,
            budget_mode: None,
            budget_free_tier: None,
            budget_action_cost: None,
            budget_current_epoch: None,
            budget_epoch_length: None,
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
         \n\
         Tuning:\n\
         \x20 --max-queue-depth <N>     Bounded queue size (default 256)\n\
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
}
