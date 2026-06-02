// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! CLI flag parser for the `knomosis-bench` binary.
//!
//! No `clap` dependency — the flag set is small, stable, and a
//! hand-rolled parser keeps the dependency surface narrow (same
//! discipline as `knomosis-host::config` and `knomosis-l1-ingest::main`).
//!
//! ## Flag matrix
//!
//! Every flag is optional.  `--standalone` and `--connect` are
//! mutually exclusive; `--standalone` is the default if neither is
//! supplied.
//!
//! | Flag                       | Default            | Description                                                |
//! |----------------------------|--------------------|------------------------------------------------------------|
//! | `--standalone`             | (implicit default) | Spawn an in-process knomosis-host (default if no `--connect`).|
//! | `--connect <ENDPOINT>`     | (none)             | Connect to an existing knomosis-host (excludes `--standalone`).|
//! | `--unix-socket <PATH>`     | auto tempdir       | Standalone-mode Unix-socket path.                          |
//! | `--listen-tcp <ADDR>`      | (Unix sock)        | Standalone-mode TCP bind (overrides default Unix-sock).    |
//! | `--actor-count <N>`        | 1000               | Pre-funded actors.                                         |
//! | `--transfer-count <N>`     | 10000              | Pre-signed transfers.                                      |
//! | `--worker-count <N>`       | 64                 | Concurrent submitter threads.                              |
//! | `--warmup-requests <N>`    | 1000               | Warmup requests excluded from latency.                     |
//! | `--seed <N>`               | 0xC4..C4 (8B)      | Fixture seed (decimal or `0x`-prefixed hex).               |
//! | `--queue-depth <N>`        | knomosis-host default | Server queue depth.                                        |
//! | `--max-frame-size <N>`     | knomosis-host default | Server max frame size.                                     |
//! | `--report <PATH>`          | (none)             | Write JSON report sidecar.                                 |
//! | `--baseline <PATH>`        | (none)             | Compare against an existing JSON baseline.                 |
//! | `--threshold <FRAC>`       | 0.10               | Regression threshold (10%).                                |
//! | `--target-tps <N>`         | (none)             | Absolute throughput target; non-zero exit if not met.      |
//! | `--target-p99-ms <N>`      | (none)             | Absolute p99 target (ms); non-zero exit if not met.        |
//! | `--quiet`                  | (false)            | Suppress human-readable summary stdout.                    |
//! | `--help` / `-h`            |                    | Print usage and exit.                                      |
//! | `--version` / `-V` / `-v`  |                    | Print version and exit.                                    |
//!
//! ## Mode selection
//!
//! - `--standalone` (default): the binary spawns its own knomosis-host
//!   instance backed by `MockKernel` on a tempdir Unix socket (or
//!   on a TCP loopback if `--listen-tcp` is supplied).
//! - `--connect <ENDPOINT>`: the binary connects to an existing
//!   knomosis-host.  `ENDPOINT` is either a socket path
//!   (`unix:/tmp/knomosis.sock`) or a TCP address
//!   (`tcp:127.0.0.1:7654`).  No prefix means TCP.
//!
//! ## Regression thresholds
//!
//! When `--baseline` is supplied, the binary computes the
//! [`crate::report::RegressionVerdict`] against the baseline and
//! exits with `1` on regression.  When `--target-tps` or
//! `--target-p99-ms` are supplied, the binary checks the absolute
//! targets and exits with `1` on miss.

use std::net::SocketAddr;
use std::path::PathBuf;

/// Parsed CLI configuration.
#[derive(Clone, Debug)]
pub struct CliConfig {
    /// Mode.
    pub mode: BenchMode,
    /// Number of pre-funded actors.
    pub actor_count: usize,
    /// Number of pre-signed transfers.
    pub transfer_count: usize,
    /// Number of concurrent submitter threads.
    pub worker_count: usize,
    /// Warmup requests.
    pub warmup_requests: usize,
    /// Fixture seed.
    pub seed: u64,
    /// Server queue depth.
    pub queue_depth: Option<usize>,
    /// Server max frame size.
    pub max_frame_size: Option<usize>,
    /// JSON report sidecar path.
    pub report_path: Option<PathBuf>,
    /// Baseline JSON path for regression detection.
    pub baseline_path: Option<PathBuf>,
    /// Regression threshold (0..1).
    pub threshold: f64,
    /// Optional absolute throughput target (ops/sec).
    pub target_tps: Option<f64>,
    /// Optional absolute p99 latency target (ms).
    pub target_p99_ms: Option<f64>,
    /// Suppress stdout human summary.
    pub quiet: bool,
    /// Emit Rung-1 (v2) signer hints on the wire (FQ.13c).  When set,
    /// the harness opens each connection with the `KNH2` preamble and
    /// prepends each frame's 8-byte signer hint (the sender `ActorId`
    /// the fixture already determines), exercising the two-tier DRR
    /// path.  Default OFF emits byte-identical legacy v1 frames (no
    /// regression).
    pub emit_hints: bool,
}

/// Benchmark mode: spawn an in-process server or connect to an
/// existing one.
#[derive(Clone, Debug)]
pub enum BenchMode {
    /// Spawn an in-process knomosis-host with the configured listener.
    Standalone(StandaloneListener),
    /// Connect to an existing knomosis-host.
    Connect(ConnectTarget),
}

/// Listener flavour for standalone mode.
#[derive(Clone, Debug)]
pub enum StandaloneListener {
    /// Unix socket at the given path.  `None` means "auto-allocate
    /// in a tempdir".
    UnixSocket(Option<PathBuf>),
    /// TCP bind at the given address.
    Tcp(SocketAddr),
}

/// Connect target for `--connect` mode.
#[derive(Clone, Debug)]
pub enum ConnectTarget {
    /// Unix-socket path.
    #[cfg(unix)]
    UnixSocket(PathBuf),
    /// TCP address.
    Tcp(SocketAddr),
}

impl CliConfig {
    /// Construct default config values (no listener mode set; the
    /// caller usually overrides via [`parse_args`]).
    #[must_use]
    pub fn defaults() -> Self {
        Self {
            mode: BenchMode::Standalone(StandaloneListener::UnixSocket(None)),
            actor_count: crate::DEFAULT_ACTOR_COUNT,
            transfer_count: crate::DEFAULT_TRANSFER_COUNT,
            worker_count: crate::DEFAULT_WORKER_COUNT,
            warmup_requests: crate::DEFAULT_WARMUP_REQUESTS,
            seed: crate::DEFAULT_SEED,
            queue_depth: None,
            max_frame_size: None,
            report_path: None,
            baseline_path: None,
            threshold: crate::DEFAULT_REGRESSION_THRESHOLD,
            target_tps: None,
            target_p99_ms: None,
            quiet: false,
            emit_hints: false,
        }
    }

    /// Validate the parsed config.  Returns the first
    /// inconsistency found.
    ///
    /// ## Float-validity discipline
    ///
    /// The float-valued fields (`threshold`, `target_tps`,
    /// `target_p99_ms`) are validated against **both** range
    /// constraints AND `is_finite()`.  Pure-range checks like
    /// `threshold <= 0.0` silently let NaN through (every IEEE-754
    /// comparison against NaN is `false`), which would cause
    /// downstream regression-check arithmetic to produce NaN
    /// verdicts.  The `is_finite()` guard rejects NaN and ±∞.
    ///
    /// # Errors
    ///
    /// Returns [`ConfigError`] variants for any rule violation.
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.actor_count == 0 {
            return Err(ConfigError::ZeroActorCount);
        }
        if self.transfer_count == 0 {
            return Err(ConfigError::ZeroTransferCount);
        }
        if self.worker_count == 0 {
            return Err(ConfigError::ZeroWorkerCount);
        }
        if self.warmup_requests >= self.transfer_count {
            return Err(ConfigError::WarmupExceedsTransferCount {
                warmup: self.warmup_requests,
                transfer_count: self.transfer_count,
            });
        }
        // Reject NaN / ±∞ BEFORE the range check: `NaN <= 0.0` is
        // false, so a pure range check would silently pass NaN.
        if !self.threshold.is_finite() || self.threshold <= 0.0 || self.threshold >= 1.0 {
            return Err(ConfigError::ThresholdOutOfRange(self.threshold));
        }
        if let Some(tps) = self.target_tps {
            if !tps.is_finite() || tps <= 0.0 {
                return Err(ConfigError::TargetTpsNonPositive(tps));
            }
        }
        if let Some(p99) = self.target_p99_ms {
            if !p99.is_finite() || p99 <= 0.0 {
                return Err(ConfigError::TargetP99NonPositive(p99));
            }
        }
        Ok(())
    }
}

impl Default for CliConfig {
    fn default() -> Self {
        Self::defaults()
    }
}

/// Errors during CLI argument parsing.
#[derive(Clone, Debug, PartialEq, thiserror::Error)]
pub enum ParseError {
    /// User asked for help.  Not really an error; the binary
    /// handles this by short-circuiting to print help.
    #[error("help requested")]
    HelpRequested,
    /// User asked for version.  Not an error.
    #[error("version requested")]
    VersionRequested,
    /// A flag was supplied without its argument.
    #[error("flag {0} requires an argument")]
    MissingValue(String),
    /// A flag's argument could not be parsed as the expected type.
    #[error("flag {flag} value {value:?} is not a valid {kind}")]
    InvalidValue {
        /// The flag.
        flag: String,
        /// The value the user supplied.
        value: String,
        /// The expected kind (e.g. `"u64"`).
        kind: String,
    },
    /// An unknown flag was supplied.
    #[error("unknown flag {0}")]
    UnknownFlag(String),
    /// Mutually-exclusive flags were both supplied.
    #[error("flags {0} and {1} are mutually exclusive")]
    Conflict(String, String),
    /// `--connect <ENDPOINT>` couldn't be parsed.
    #[error("--connect {0:?} has invalid endpoint format (expected unix:PATH or tcp:HOST:PORT)")]
    InvalidConnectEndpoint(String),
}

/// Validation errors for a parsed config.
#[derive(Clone, Debug, PartialEq, thiserror::Error)]
pub enum ConfigError {
    /// `actor_count == 0`.
    #[error("actor-count must be >= 1")]
    ZeroActorCount,
    /// `transfer_count == 0`.
    #[error("transfer-count must be >= 1")]
    ZeroTransferCount,
    /// `worker_count == 0`.
    #[error("worker-count must be >= 1")]
    ZeroWorkerCount,
    /// Warmup requests >= transfer count.
    #[error("warmup-requests {warmup} must be less than transfer-count {transfer_count}")]
    WarmupExceedsTransferCount {
        /// Configured warmup requests.
        warmup: usize,
        /// Configured transfer count.
        transfer_count: usize,
    },
    /// Threshold out of (0, 1).
    #[error("threshold must be in (0.0, 1.0); got {0}")]
    ThresholdOutOfRange(f64),
    /// Target TPS not positive.
    #[error("target-tps must be > 0; got {0}")]
    TargetTpsNonPositive(f64),
    /// Target p99 not positive.
    #[error("target-p99-ms must be > 0; got {0}")]
    TargetP99NonPositive(f64),
}

/// Parse `argv`-style arguments into a [`CliConfig`].
///
/// The first element of `args` is the program name (per `std::env::args`
/// convention) and is ignored.  All remaining elements are
/// interpreted as flags.
///
/// # Errors
///
/// See [`ParseError`].
pub fn parse_args(args: &[String]) -> Result<CliConfig, ParseError> {
    let mut cfg = CliConfig::defaults();
    let mut explicit_standalone = false;
    let mut explicit_connect: Option<ConnectTarget> = None;
    let mut explicit_unix_socket: Option<PathBuf> = None;
    let mut explicit_tcp_listen: Option<SocketAddr> = None;

    let mut i = 1; // skip program name
    while i < args.len() {
        let arg = &args[i];
        match arg.as_str() {
            "--help" | "-h" => return Err(ParseError::HelpRequested),
            "--version" | "-V" | "-v" => return Err(ParseError::VersionRequested),
            "--standalone" => {
                explicit_standalone = true;
                i += 1;
            }
            "--connect" => {
                let value = next_value(args, &mut i, "--connect")?;
                explicit_connect = Some(parse_connect(value)?);
            }
            "--unix-socket" => {
                let value = next_value(args, &mut i, "--unix-socket")?;
                explicit_unix_socket = Some(PathBuf::from(value));
            }
            "--listen-tcp" => {
                let value = next_value(args, &mut i, "--listen-tcp")?;
                explicit_tcp_listen = Some(parse_socket_addr(value, "--listen-tcp")?);
            }
            "--actor-count" => {
                let value = next_value(args, &mut i, "--actor-count")?;
                cfg.actor_count = parse_usize(value, "--actor-count")?;
            }
            "--transfer-count" => {
                let value = next_value(args, &mut i, "--transfer-count")?;
                cfg.transfer_count = parse_usize(value, "--transfer-count")?;
            }
            "--worker-count" => {
                let value = next_value(args, &mut i, "--worker-count")?;
                cfg.worker_count = parse_usize(value, "--worker-count")?;
            }
            "--warmup-requests" => {
                let value = next_value(args, &mut i, "--warmup-requests")?;
                cfg.warmup_requests = parse_usize(value, "--warmup-requests")?;
            }
            "--seed" => {
                let value = next_value(args, &mut i, "--seed")?;
                cfg.seed = parse_u64(value, "--seed")?;
            }
            "--queue-depth" => {
                let value = next_value(args, &mut i, "--queue-depth")?;
                cfg.queue_depth = Some(parse_usize(value, "--queue-depth")?);
            }
            "--max-frame-size" => {
                let value = next_value(args, &mut i, "--max-frame-size")?;
                cfg.max_frame_size = Some(parse_usize(value, "--max-frame-size")?);
            }
            "--report" => {
                let value = next_value(args, &mut i, "--report")?;
                cfg.report_path = Some(PathBuf::from(value));
            }
            "--baseline" => {
                let value = next_value(args, &mut i, "--baseline")?;
                cfg.baseline_path = Some(PathBuf::from(value));
            }
            "--threshold" => {
                let value = next_value(args, &mut i, "--threshold")?;
                cfg.threshold = parse_f64(value, "--threshold")?;
            }
            "--target-tps" => {
                let value = next_value(args, &mut i, "--target-tps")?;
                cfg.target_tps = Some(parse_f64(value, "--target-tps")?);
            }
            "--target-p99-ms" => {
                let value = next_value(args, &mut i, "--target-p99-ms")?;
                cfg.target_p99_ms = Some(parse_f64(value, "--target-p99-ms")?);
            }
            "--quiet" => {
                cfg.quiet = true;
                i += 1;
            }
            "--emit-hints" => {
                cfg.emit_hints = true;
                i += 1;
            }
            other => return Err(ParseError::UnknownFlag(other.to_string())),
        }
    }

    // Mode resolution.  Order of precedence:
    //   1. --connect explicit (mutually exclusive with --standalone)
    //   2. --standalone explicit (or default)
    //
    // Inside standalone mode, --unix-socket and --listen-tcp are
    // mutually exclusive.  If neither is supplied, default is
    // Unix-socket auto-allocated in tempdir.
    if let Some(target) = explicit_connect {
        if explicit_standalone {
            return Err(ParseError::Conflict(
                "--standalone".into(),
                "--connect".into(),
            ));
        }
        if explicit_unix_socket.is_some() {
            return Err(ParseError::Conflict(
                "--unix-socket".into(),
                "--connect".into(),
            ));
        }
        if explicit_tcp_listen.is_some() {
            return Err(ParseError::Conflict(
                "--listen-tcp".into(),
                "--connect".into(),
            ));
        }
        cfg.mode = BenchMode::Connect(target);
    } else {
        if explicit_unix_socket.is_some() && explicit_tcp_listen.is_some() {
            return Err(ParseError::Conflict(
                "--unix-socket".into(),
                "--listen-tcp".into(),
            ));
        }
        let listener = if let Some(p) = explicit_unix_socket {
            StandaloneListener::UnixSocket(Some(p))
        } else if let Some(a) = explicit_tcp_listen {
            StandaloneListener::Tcp(a)
        } else {
            StandaloneListener::UnixSocket(None)
        };
        cfg.mode = BenchMode::Standalone(listener);
    }

    Ok(cfg)
}

/// Consume the next argument as a string value for `flag`.
fn next_value<'a>(args: &'a [String], i: &mut usize, flag: &str) -> Result<&'a str, ParseError> {
    *i += 1;
    if *i >= args.len() {
        return Err(ParseError::MissingValue(flag.to_string()));
    }
    let value = &args[*i];
    *i += 1;
    Ok(value)
}

/// Parse a `usize` decimal string with a typed error.
fn parse_usize(value: &str, flag: &str) -> Result<usize, ParseError> {
    value
        .parse::<usize>()
        .map_err(|_| ParseError::InvalidValue {
            flag: flag.to_string(),
            value: value.to_string(),
            kind: "usize".to_string(),
        })
}

/// Parse a `u64` decimal OR `0x`-prefixed hex string.
fn parse_u64(value: &str, flag: &str) -> Result<u64, ParseError> {
    let parsed = if let Some(hex) = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
    {
        u64::from_str_radix(hex, 16)
    } else {
        value.parse::<u64>()
    };
    parsed.map_err(|_| ParseError::InvalidValue {
        flag: flag.to_string(),
        value: value.to_string(),
        kind: "u64".to_string(),
    })
}

/// Parse an `f64` decimal string.
fn parse_f64(value: &str, flag: &str) -> Result<f64, ParseError> {
    value.parse::<f64>().map_err(|_| ParseError::InvalidValue {
        flag: flag.to_string(),
        value: value.to_string(),
        kind: "f64".to_string(),
    })
}

/// Parse a `SocketAddr` (e.g. `127.0.0.1:7654`).
fn parse_socket_addr(value: &str, flag: &str) -> Result<SocketAddr, ParseError> {
    value
        .parse::<SocketAddr>()
        .map_err(|_| ParseError::InvalidValue {
            flag: flag.to_string(),
            value: value.to_string(),
            kind: "socket address (host:port)".to_string(),
        })
}

/// Parse a `--connect <ENDPOINT>` value.  Accepted forms:
///   * `unix:PATH` — Unix-socket
///   * `tcp:HOST:PORT` — TCP
///   * `HOST:PORT` — TCP (no prefix, recognised for ergonomics)
fn parse_connect(value: &str) -> Result<ConnectTarget, ParseError> {
    if let Some(path) = value.strip_prefix("unix:") {
        #[cfg(unix)]
        return Ok(ConnectTarget::UnixSocket(PathBuf::from(path)));
        #[cfg(not(unix))]
        {
            let _ = path;
            return Err(ParseError::InvalidConnectEndpoint(value.to_string()));
        }
    }
    if let Some(rest) = value.strip_prefix("tcp:") {
        let addr = rest
            .parse::<SocketAddr>()
            .map_err(|_| ParseError::InvalidConnectEndpoint(value.to_string()))?;
        return Ok(ConnectTarget::Tcp(addr));
    }
    // Bare `HOST:PORT` — assume TCP.
    if let Ok(addr) = value.parse::<SocketAddr>() {
        return Ok(ConnectTarget::Tcp(addr));
    }
    Err(ParseError::InvalidConnectEndpoint(value.to_string()))
}

/// The `--help` output.  Pretty-printed; matches knomosis-host's
/// help-text style.
#[must_use]
pub fn help_text(program: &str) -> String {
    format!(
        "{program} — knomosis-host transfer throughput benchmark (RH-F)

USAGE:
    {program} [OPTIONS]

MODE:
    --standalone               Spawn an in-process knomosis-host (default).
    --connect <ENDPOINT>       Connect to an existing knomosis-host.
                                ENDPOINT: unix:PATH or tcp:HOST:PORT or HOST:PORT.

LISTENER (standalone mode):
    --unix-socket <PATH>       Bind a Unix socket at PATH (default: tempdir).
    --listen-tcp <ADDR>        Bind TCP at ADDR (default: 127.0.0.1:0).

WORKLOAD:
    --actor-count <N>          Pre-funded actors (default 1000).
    --transfer-count <N>       Pre-signed transfers (default 10000).
    --worker-count <N>         Concurrent submitter threads (default 64).
    --warmup-requests <N>      Warmup requests excluded from latency (default 1000).
    --seed <N>                 Fixture seed (decimal or 0x-prefixed hex).
    --emit-hints               Emit Rung-1 (v2) signer hints on the wire (default off;
                               exercises the two-tier DRR path under --scheduler drr).

SERVER (standalone mode):
    --queue-depth <N>          Server queue depth (default knomosis-host's default).
    --max-frame-size <N>       Server max frame size (default knomosis-host's default).

REPORT:
    --report <PATH>            Write JSON report sidecar to PATH.
    --baseline <PATH>          Compare against an existing JSON baseline.
    --threshold <FRAC>         Regression threshold (default 0.10 = 10%).
    --target-tps <N>           Target throughput (ops/sec); non-zero exit on miss.
    --target-p99-ms <N>        Target p99 latency (ms); non-zero exit on miss.
    --quiet                    Suppress stdout human summary.

OUTPUT:
    --help, -h                 Print this help and exit.
    --version, -V, -v          Print version and exit.

See `docs/planning/rust_host_runtime_plan.md` §RH-F for the engineering plan."
    )
}

#[cfg(test)]
mod tests {
    use super::{
        parse_args, parse_connect, parse_f64, parse_u64, parse_usize, BenchMode, CliConfig,
        ConfigError, ConnectTarget, ParseError, StandaloneListener,
    };

    fn argv(args: &[&str]) -> Vec<String> {
        std::iter::once("knomosis-bench")
            .chain(args.iter().copied())
            .map(String::from)
            .collect()
    }

    /// Empty argv yields defaults.
    #[test]
    fn empty_argv_yields_defaults() {
        let args = argv(&[]);
        let cfg = parse_args(&args).unwrap();
        assert_eq!(cfg.actor_count, crate::DEFAULT_ACTOR_COUNT);
        assert_eq!(cfg.transfer_count, crate::DEFAULT_TRANSFER_COUNT);
        assert_eq!(cfg.worker_count, crate::DEFAULT_WORKER_COUNT);
        assert_eq!(cfg.warmup_requests, crate::DEFAULT_WARMUP_REQUESTS);
        assert_eq!(cfg.seed, crate::DEFAULT_SEED);
        assert!(matches!(
            cfg.mode,
            BenchMode::Standalone(StandaloneListener::UnixSocket(None))
        ));
        // FQ.13c: hint emission is OFF by default (legacy v1 frames).
        assert!(!cfg.emit_hints);
    }

    /// FQ.13c: `--emit-hints` sets the flag.
    #[test]
    fn emit_hints_flag_parses() {
        let cfg = parse_args(&argv(&["--emit-hints"])).unwrap();
        assert!(cfg.emit_hints);
    }

    /// `--help` returns the typed error.
    #[test]
    fn help_returns_typed_error() {
        let args = argv(&["--help"]);
        let result = parse_args(&args);
        assert!(matches!(result, Err(ParseError::HelpRequested)));
    }

    /// `--version` returns the typed error.
    #[test]
    fn version_returns_typed_error() {
        let args = argv(&["--version"]);
        let result = parse_args(&args);
        assert!(matches!(result, Err(ParseError::VersionRequested)));
        let args = argv(&["-V"]);
        let result = parse_args(&args);
        assert!(matches!(result, Err(ParseError::VersionRequested)));
        let args = argv(&["-v"]);
        let result = parse_args(&args);
        assert!(matches!(result, Err(ParseError::VersionRequested)));
    }

    /// Unknown flag is rejected.
    #[test]
    fn unknown_flag_rejected() {
        let args = argv(&["--unknown"]);
        let result = parse_args(&args);
        assert!(matches!(result, Err(ParseError::UnknownFlag(_))));
    }

    /// Missing value is rejected.
    #[test]
    fn missing_value_rejected() {
        let args = argv(&["--actor-count"]);
        let result = parse_args(&args);
        assert!(matches!(result, Err(ParseError::MissingValue(_))));
    }

    /// Invalid value is rejected.
    #[test]
    fn invalid_value_rejected() {
        let args = argv(&["--actor-count", "not-a-number"]);
        let result = parse_args(&args);
        assert!(matches!(result, Err(ParseError::InvalidValue { .. })));
    }

    /// Seed parses both decimal and hex.
    #[test]
    fn seed_parses_decimal_and_hex() {
        let args = argv(&["--seed", "42"]);
        let cfg = parse_args(&args).unwrap();
        assert_eq!(cfg.seed, 42);
        let args = argv(&["--seed", "0xCAFEBABE"]);
        let cfg = parse_args(&args).unwrap();
        assert_eq!(cfg.seed, 0xCAFEBABE);
        let args = argv(&["--seed", "0XCAFE"]);
        let cfg = parse_args(&args).unwrap();
        assert_eq!(cfg.seed, 0xCAFE);
    }

    /// `--connect` with `unix:` prefix.
    #[cfg(unix)]
    #[test]
    fn connect_unix_prefix() {
        let result = parse_connect("unix:/tmp/foo.sock").unwrap();
        match result {
            ConnectTarget::UnixSocket(p) => {
                assert_eq!(p.to_str(), Some("/tmp/foo.sock"));
            }
            _ => panic!("expected unix"),
        }
    }

    /// `--connect` with `tcp:` prefix.
    #[test]
    fn connect_tcp_prefix() {
        let result = parse_connect("tcp:127.0.0.1:1234").unwrap();
        match result {
            ConnectTarget::Tcp(addr) => {
                assert_eq!(addr.port(), 1234);
            }
            _ => panic!("expected tcp"),
        }
    }

    /// `--connect` bare HOST:PORT defaults to TCP.
    #[test]
    fn connect_bare_host_port() {
        let result = parse_connect("127.0.0.1:5678").unwrap();
        match result {
            ConnectTarget::Tcp(addr) => {
                assert_eq!(addr.port(), 5678);
            }
            _ => panic!("expected tcp"),
        }
    }

    /// `--connect` rejects malformed values.
    #[test]
    fn connect_rejects_malformed() {
        let result = parse_connect("garbage");
        assert!(matches!(result, Err(ParseError::InvalidConnectEndpoint(_))));
    }

    /// `--standalone` and `--connect` are mutually exclusive.
    #[test]
    fn standalone_and_connect_conflict() {
        let args = argv(&["--standalone", "--connect", "tcp:127.0.0.1:1"]);
        let result = parse_args(&args);
        assert!(matches!(result, Err(ParseError::Conflict(_, _))));
    }

    /// `--unix-socket` and `--listen-tcp` are mutually exclusive.
    #[test]
    fn unix_and_tcp_conflict() {
        let args = argv(&[
            "--unix-socket",
            "/tmp/x.sock",
            "--listen-tcp",
            "127.0.0.1:1234",
        ]);
        let result = parse_args(&args);
        assert!(matches!(result, Err(ParseError::Conflict(_, _))));
    }

    /// `--threshold` accepts and rejects values.
    #[test]
    fn threshold_validation() {
        let args = argv(&["--threshold", "0.05"]);
        let cfg = parse_args(&args).unwrap();
        assert!((cfg.threshold - 0.05).abs() < f64::EPSILON);
        // Out of range.
        let mut cfg = cfg.clone();
        cfg.threshold = 0.0;
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::ThresholdOutOfRange(_))
        ));
        cfg.threshold = 1.5;
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::ThresholdOutOfRange(_))
        ));
    }

    /// `validate` catches every zero-count case.
    #[test]
    fn validate_zero_counts() {
        let mut cfg = CliConfig::defaults();
        cfg.actor_count = 0;
        assert!(matches!(cfg.validate(), Err(ConfigError::ZeroActorCount)));
        cfg = CliConfig::defaults();
        cfg.transfer_count = 0;
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::ZeroTransferCount)
        ));
        cfg = CliConfig::defaults();
        cfg.worker_count = 0;
        assert!(matches!(cfg.validate(), Err(ConfigError::ZeroWorkerCount)));
    }

    /// `validate` catches warmup >= transfer_count.
    #[test]
    fn validate_warmup_overflow() {
        let mut cfg = CliConfig::defaults();
        cfg.warmup_requests = cfg.transfer_count;
        let result = cfg.validate();
        assert!(matches!(
            result,
            Err(ConfigError::WarmupExceedsTransferCount { .. })
        ));
    }

    /// `validate` catches non-positive target-tps / p99.
    #[test]
    fn validate_target_targets() {
        let mut cfg = CliConfig::defaults();
        cfg.target_tps = Some(-1.0);
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::TargetTpsNonPositive(_))
        ));
        cfg = CliConfig::defaults();
        cfg.target_p99_ms = Some(-1.0);
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::TargetP99NonPositive(_))
        ));
    }

    /// REGRESSION: `validate` rejects NaN thresholds.  A pure
    /// `threshold <= 0.0 || threshold >= 1.0` comparison silently
    /// passes NaN (every comparison vs NaN is false), causing
    /// downstream regression checks to produce NaN verdicts.  The
    /// `is_finite()` guard is the load-bearing defence.
    #[test]
    fn validate_rejects_nan_threshold() {
        let mut cfg = CliConfig::defaults();
        cfg.threshold = f64::NAN;
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::ThresholdOutOfRange(_))
        ));
    }

    /// REGRESSION: `validate` rejects infinity thresholds for the
    /// same reason as NaN — IEEE-754 infinity comparisons silently
    /// pass our range check (`f64::INFINITY >= 1.0` is true, so
    /// the existing check covers `+∞`; but `-∞ <= 0.0` is also
    /// true, so `-∞` is caught too).  The `is_finite()` guard is
    /// belt-and-suspenders defence-in-depth.
    #[test]
    fn validate_rejects_inf_threshold() {
        let mut cfg = CliConfig::defaults();
        cfg.threshold = f64::INFINITY;
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::ThresholdOutOfRange(_))
        ));
        cfg.threshold = f64::NEG_INFINITY;
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::ThresholdOutOfRange(_))
        ));
    }

    /// REGRESSION: `validate` rejects NaN target-tps / target-p99.
    /// Same NaN-bypass concern as `validate_rejects_nan_threshold`.
    #[test]
    fn validate_rejects_nan_targets() {
        let mut cfg = CliConfig::defaults();
        cfg.target_tps = Some(f64::NAN);
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::TargetTpsNonPositive(_))
        ));
        cfg = CliConfig::defaults();
        cfg.target_p99_ms = Some(f64::NAN);
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::TargetP99NonPositive(_))
        ));
    }

    /// REGRESSION: `validate` rejects infinity targets.  Positive
    /// infinity would silently pass `tps <= 0.0`, causing the
    /// runner's later `throughput < target` check to be a tautology
    /// (any finite throughput < +∞), forcing a target-miss exit.
    #[test]
    fn validate_rejects_inf_targets() {
        let mut cfg = CliConfig::defaults();
        cfg.target_tps = Some(f64::INFINITY);
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::TargetTpsNonPositive(_))
        ));
        cfg = CliConfig::defaults();
        cfg.target_p99_ms = Some(f64::INFINITY);
        assert!(matches!(
            cfg.validate(),
            Err(ConfigError::TargetP99NonPositive(_))
        ));
    }

    /// `parse_usize` parses valid input.
    #[test]
    fn parse_usize_valid() {
        assert_eq!(parse_usize("42", "--flag").unwrap(), 42);
    }

    /// `parse_f64` parses valid input.
    #[test]
    fn parse_f64_valid() {
        assert!((parse_f64("0.5", "--flag").unwrap() - 0.5).abs() < f64::EPSILON);
    }

    /// `parse_u64` accepts both decimal and hex.
    #[test]
    fn parse_u64_decimal_and_hex() {
        assert_eq!(parse_u64("123", "--flag").unwrap(), 123);
        assert_eq!(parse_u64("0xff", "--flag").unwrap(), 255);
    }

    /// Help text contains documented flags.
    #[test]
    fn help_text_includes_flags() {
        let s = super::help_text("knomosis-bench");
        assert!(s.contains("--standalone"));
        assert!(s.contains("--connect"));
        assert!(s.contains("--actor-count"));
        assert!(s.contains("--target-tps"));
        assert!(s.contains("--emit-hints"));
    }

    /// `--unix-socket` sets the standalone listener correctly.
    #[test]
    fn unix_socket_sets_standalone_listener() {
        let args = argv(&["--unix-socket", "/tmp/x.sock"]);
        let cfg = parse_args(&args).unwrap();
        match cfg.mode {
            BenchMode::Standalone(StandaloneListener::UnixSocket(Some(p))) => {
                assert_eq!(p.to_str(), Some("/tmp/x.sock"));
            }
            _ => panic!("expected standalone unix"),
        }
    }

    /// `--listen-tcp` sets the standalone listener correctly.
    #[test]
    fn listen_tcp_sets_standalone_listener() {
        let args = argv(&["--listen-tcp", "127.0.0.1:7777"]);
        let cfg = parse_args(&args).unwrap();
        match cfg.mode {
            BenchMode::Standalone(StandaloneListener::Tcp(addr)) => {
                assert_eq!(addr.port(), 7777);
            }
            _ => panic!("expected standalone tcp"),
        }
    }

    /// `--quiet` is captured.
    #[test]
    fn quiet_flag_captured() {
        let args = argv(&["--quiet"]);
        let cfg = parse_args(&args).unwrap();
        assert!(cfg.quiet);
    }

    /// Multiple value-bearing flags compose correctly.
    #[test]
    fn multi_flag_composition() {
        let args = argv(&[
            "--actor-count",
            "10",
            "--transfer-count",
            "100",
            "--worker-count",
            "4",
            "--warmup-requests",
            "5",
            "--seed",
            "0xDEAD",
            "--quiet",
        ]);
        let cfg = parse_args(&args).unwrap();
        assert_eq!(cfg.actor_count, 10);
        assert_eq!(cfg.transfer_count, 100);
        assert_eq!(cfg.worker_count, 4);
        assert_eq!(cfg.warmup_requests, 5);
        assert_eq!(cfg.seed, 0xDEAD);
        assert!(cfg.quiet);
    }
}
