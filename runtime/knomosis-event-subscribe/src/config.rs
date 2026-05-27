// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! CLI configuration parsing for `knomosis-event-subscribe`.
//!
//! No `clap` dependency — the flag set is small and stable; a
//! hand-rolled parser keeps the dependency surface narrow (same
//! choice as `knomosis-host::config`).
//!
//! ## Flag matrix
//!
//! | Flag                       | Required | Description                                                |
//! |----------------------------|----------|------------------------------------------------------------|
//! | `--log-path <PATH>`        | yes      | Knomosis log file to tail                                    |
//! | `--listen <ADDR>`          | yes      | TCP listen address (e.g. `127.0.0.1:7655`)                |
//! | `--max-subscriber-lag <N>` | optional | Lag threshold (default 256)                                |
//! | `--keep-history <N>`       | optional | Backfill cache depth (default 256)                         |
//! | `--max-frame-size <N>`     | optional | Maximum event payload (default 1 MiB)                      |
//! | `--max-subscribers <N>`    | optional | Cap on simultaneous subscribers (default 256)              |
//! | `--send-queue-depth <N>`   | optional | Per-subscriber outbound queue (default 64)                 |
//! | `--poll-interval-ms <N>`   | optional | Tail-reader poll interval (default 100 ms)                 |
//! | `--knomosis-binary <PATH>`    | optional | Path to knomosis binary for SubprocessExtractor               |
//! | `--mock`                   | optional | Use MockExtractor (test/dev only)                          |
//! | `--help` / `-h`            |          | Print usage                                                |
//! | `--version` / `-v`         |          | Print version                                              |

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use crate::event_cache::{DEFAULT_KEEP_HISTORY, HARD_MAX_KEEP_HISTORY};
use crate::frame::{DEFAULT_MAX_FRAME_SIZE, HARD_MAX_FRAME_SIZE};
use crate::server::{
    DEFAULT_HANDSHAKE_READ_TIMEOUT, DEFAULT_MAX_CONCURRENT_CONNECTIONS, DEFAULT_WRITE_TIMEOUT,
    HARD_MAX_CONCURRENT_CONNECTIONS,
};
use crate::subscription::{
    DEFAULT_MAX_SUBSCRIBER_LAG, DEFAULT_SEND_QUEUE_DEPTH, HARD_MAX_SEND_QUEUE_DEPTH,
    HARD_MAX_SUBSCRIBER_LAG,
};
use crate::tail::DEFAULT_POLL_INTERVAL;

/// Default maximum simultaneous subscribers.
pub const DEFAULT_MAX_SUBSCRIBERS: usize = 256;

/// Hard ceiling on simultaneous subscribers.  Above this the
/// operator is using the subscriber as a fanout layer rather than
/// a notification stream and should switch to a real pub-sub
/// system.
pub const HARD_MAX_SUBSCRIBERS: usize = 65_536;

/// Hard ceiling on operator-configurable poll interval in
/// milliseconds.  60 seconds is the longest reasonable interval;
/// above this notifications become eventually-consistent at
/// time scales no operator would accept.
pub const HARD_MAX_POLL_INTERVAL_MS: u64 = 60_000;

/// Hard ceiling on operator-configurable write timeout in
/// milliseconds.  Five minutes is the longest reasonable wait
/// for a client to drain a single frame.
pub const HARD_MAX_WRITE_TIMEOUT_MS: u64 = 300_000;

/// Hard ceiling on operator-configurable handshake read timeout
/// in milliseconds.  60 seconds is generous; longer windows
/// invite slowloris-style DoS via stalled handshakes.
pub const HARD_MAX_HANDSHAKE_READ_TIMEOUT_MS: u64 = 60_000;

/// Parsed configuration.
#[derive(Clone, Debug)]
pub struct Config {
    /// Path to the Knomosis log file we tail.
    pub log_path: Option<PathBuf>,
    /// TCP listen address.
    pub listen: Option<SocketAddr>,
    /// Lag threshold above which a subscriber is disconnected.
    pub max_subscriber_lag: u64,
    /// Backfill cache depth.
    pub keep_history: usize,
    /// Maximum event payload size on the wire.
    pub max_frame_size: usize,
    /// Cap on simultaneous subscribers.
    pub max_subscribers: usize,
    /// Cap on simultaneous active dispatch threads (DoS guard
    /// independent of `max_subscribers`).  Per H-1 audit.
    pub max_concurrent_connections: usize,
    /// Per-subscriber outbound queue depth.
    pub send_queue_depth: usize,
    /// Tail-reader poll interval.
    pub poll_interval: Duration,
    /// TCP write timeout for outbound frames (slowloris DoS
    /// guard).  Per C-3 audit.
    pub write_timeout: Duration,
    /// TCP read timeout for the SUBSCRIBE handshake.
    pub handshake_read_timeout: Duration,
    /// Path to the `knomosis` binary for SubprocessExtractor (if
    /// configured).
    pub knomosis_binary: Option<PathBuf>,
    /// Use in-memory MockExtractor (test/dev only).
    pub use_mock_extractor: bool,
}

impl Config {
    /// Construct a default config.
    #[must_use]
    pub fn defaults() -> Self {
        Self {
            log_path: None,
            listen: None,
            max_subscriber_lag: DEFAULT_MAX_SUBSCRIBER_LAG,
            keep_history: DEFAULT_KEEP_HISTORY,
            max_frame_size: DEFAULT_MAX_FRAME_SIZE,
            max_subscribers: DEFAULT_MAX_SUBSCRIBERS,
            max_concurrent_connections: DEFAULT_MAX_CONCURRENT_CONNECTIONS,
            send_queue_depth: DEFAULT_SEND_QUEUE_DEPTH,
            poll_interval: DEFAULT_POLL_INTERVAL,
            write_timeout: DEFAULT_WRITE_TIMEOUT,
            handshake_read_timeout: DEFAULT_HANDSHAKE_READ_TIMEOUT,
            knomosis_binary: None,
            use_mock_extractor: false,
        }
    }

    /// Validate the configuration.  Returns the first
    /// inconsistency found.
    ///
    /// # Errors
    ///
    /// See [`ConfigError`].
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.log_path.is_none() {
            return Err(ConfigError::NoLogPath);
        }
        if self.listen.is_none() {
            return Err(ConfigError::NoListenAddr);
        }
        // Extractor: must pick one.
        let mock = self.use_mock_extractor;
        let subprocess = self.knomosis_binary.is_some();
        if !mock && !subprocess {
            return Err(ConfigError::NoExtractor);
        }
        if mock && subprocess {
            return Err(ConfigError::ConflictingExtractor);
        }
        // Numeric bound checks.
        if self.max_subscriber_lag == 0 {
            return Err(ConfigError::MaxLagZero);
        }
        if self.max_subscriber_lag > HARD_MAX_SUBSCRIBER_LAG {
            return Err(ConfigError::MaxLagTooLarge(self.max_subscriber_lag));
        }
        if self.keep_history == 0 {
            return Err(ConfigError::KeepHistoryZero);
        }
        if self.keep_history > HARD_MAX_KEEP_HISTORY {
            return Err(ConfigError::KeepHistoryTooLarge(self.keep_history));
        }
        if self.max_frame_size == 0 {
            return Err(ConfigError::FrameSizeZero);
        }
        if self.max_frame_size > HARD_MAX_FRAME_SIZE {
            return Err(ConfigError::FrameSizeTooLarge(self.max_frame_size));
        }
        if self.max_subscribers == 0 {
            return Err(ConfigError::MaxSubscribersZero);
        }
        if self.max_subscribers > HARD_MAX_SUBSCRIBERS {
            return Err(ConfigError::MaxSubscribersTooLarge(self.max_subscribers));
        }
        if self.send_queue_depth == 0 {
            return Err(ConfigError::SendQueueDepthZero);
        }
        if self.send_queue_depth > HARD_MAX_SEND_QUEUE_DEPTH {
            return Err(ConfigError::SendQueueDepthTooLarge(self.send_queue_depth));
        }
        if self.poll_interval.is_zero() {
            return Err(ConfigError::PollIntervalZero);
        }
        if self.poll_interval > Duration::from_millis(HARD_MAX_POLL_INTERVAL_MS) {
            return Err(ConfigError::PollIntervalTooLarge(
                self.poll_interval.as_millis(),
            ));
        }
        if self.max_concurrent_connections == 0 {
            return Err(ConfigError::MaxConcurrentConnectionsZero);
        }
        if self.max_concurrent_connections > HARD_MAX_CONCURRENT_CONNECTIONS {
            return Err(ConfigError::MaxConcurrentConnectionsTooLarge(
                self.max_concurrent_connections,
            ));
        }
        // H-NEW-3 audit fix: max_concurrent_connections must be
        // at least max_subscribers.  Otherwise a successful
        // SUBSCRIBE could be refused at the slot cap even
        // though the registry has room.
        if self.max_concurrent_connections < self.max_subscribers {
            return Err(ConfigError::MaxConcurrentConnectionsBelowMaxSubscribers {
                max_concurrent_connections: self.max_concurrent_connections,
                max_subscribers: self.max_subscribers,
            });
        }
        if self.write_timeout.is_zero() {
            return Err(ConfigError::WriteTimeoutZero);
        }
        if self.write_timeout > Duration::from_millis(HARD_MAX_WRITE_TIMEOUT_MS) {
            return Err(ConfigError::WriteTimeoutTooLarge(
                self.write_timeout.as_millis(),
            ));
        }
        if self.handshake_read_timeout.is_zero() {
            return Err(ConfigError::HandshakeReadTimeoutZero);
        }
        if self.handshake_read_timeout > Duration::from_millis(HARD_MAX_HANDSHAKE_READ_TIMEOUT_MS) {
            return Err(ConfigError::HandshakeReadTimeoutTooLarge(
                self.handshake_read_timeout.as_millis(),
            ));
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
    /// Help was requested.
    #[error("help requested")]
    HelpRequested,
    /// Version was requested.
    #[error("version requested")]
    VersionRequested,
}

/// Validation-time errors.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// `--log-path` not supplied.
    #[error("--log-path <PATH> is required")]
    NoLogPath,
    /// `--listen` not supplied.
    #[error("--listen <ADDR> is required")]
    NoListenAddr,
    /// No extractor configured.
    #[error("no extractor configured; specify --mock OR --knomosis-binary <PATH>")]
    NoExtractor,
    /// Both `--mock` and `--knomosis-binary` supplied.
    #[error("--mock and --knomosis-binary are mutually exclusive")]
    ConflictingExtractor,
    /// `--max-subscriber-lag 0` rejected.
    #[error("--max-subscriber-lag cannot be zero")]
    MaxLagZero,
    /// `--max-subscriber-lag` above hard ceiling.
    #[error("--max-subscriber-lag {0} exceeds hard ceiling")]
    MaxLagTooLarge(u64),
    /// `--keep-history 0` rejected.
    #[error("--keep-history cannot be zero")]
    KeepHistoryZero,
    /// `--keep-history` above hard ceiling.
    #[error("--keep-history {0} exceeds hard ceiling")]
    KeepHistoryTooLarge(usize),
    /// `--max-frame-size 0` rejected.
    #[error("--max-frame-size cannot be zero")]
    FrameSizeZero,
    /// `--max-frame-size` above hard ceiling.
    #[error("--max-frame-size {0} exceeds hard ceiling")]
    FrameSizeTooLarge(usize),
    /// `--max-subscribers 0` rejected.
    #[error("--max-subscribers cannot be zero")]
    MaxSubscribersZero,
    /// `--max-subscribers` above hard ceiling.
    #[error("--max-subscribers {0} exceeds hard ceiling")]
    MaxSubscribersTooLarge(usize),
    /// `--send-queue-depth 0` rejected.
    #[error("--send-queue-depth cannot be zero")]
    SendQueueDepthZero,
    /// `--send-queue-depth` above hard ceiling.
    #[error("--send-queue-depth {0} exceeds hard ceiling")]
    SendQueueDepthTooLarge(usize),
    /// `--poll-interval-ms 0` rejected.
    #[error("--poll-interval-ms cannot be zero")]
    PollIntervalZero,
    /// `--poll-interval-ms` above hard ceiling.
    #[error("--poll-interval-ms {0} ms exceeds hard ceiling")]
    PollIntervalTooLarge(u128),
    /// `--max-concurrent-connections 0` rejected.
    #[error("--max-concurrent-connections cannot be zero")]
    MaxConcurrentConnectionsZero,
    /// `--max-concurrent-connections` above hard ceiling.
    #[error("--max-concurrent-connections {0} exceeds hard ceiling")]
    MaxConcurrentConnectionsTooLarge(usize),
    /// `--max-concurrent-connections` is below `--max-subscribers`.
    /// Per H-NEW-3 audit fix: every successfully-registered
    /// subscriber needs a connection slot; setting the slot cap
    /// below the registry cap would refuse otherwise-valid
    /// SUBSCRIBE requests.
    #[error(
        "--max-concurrent-connections ({max_concurrent_connections}) must be \
         >= --max-subscribers ({max_subscribers})"
    )]
    MaxConcurrentConnectionsBelowMaxSubscribers {
        /// Configured slot cap.
        max_concurrent_connections: usize,
        /// Configured registry cap.
        max_subscribers: usize,
    },
    /// `--write-timeout-ms 0` rejected.
    #[error("--write-timeout-ms cannot be zero")]
    WriteTimeoutZero,
    /// `--write-timeout-ms` above hard ceiling.
    #[error("--write-timeout-ms {0} ms exceeds hard ceiling")]
    WriteTimeoutTooLarge(u128),
    /// `--handshake-read-timeout-ms 0` rejected.
    #[error("--handshake-read-timeout-ms cannot be zero")]
    HandshakeReadTimeoutZero,
    /// `--handshake-read-timeout-ms` above hard ceiling.
    #[error("--handshake-read-timeout-ms {0} ms exceeds hard ceiling")]
    HandshakeReadTimeoutTooLarge(u128),
}

/// Parse command-line arguments into a `Config`.
///
/// `args` is the full argv including `argv[0]`.
///
/// # Errors
///
/// See [`ParseError`].
pub fn parse_args(args: &[String]) -> Result<Config, ParseError> {
    let mut cfg = Config::defaults();
    let mut iter = args.iter().skip(1);
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--help" | "-h" => return Err(ParseError::HelpRequested),
            "--version" | "-v" => return Err(ParseError::VersionRequested),
            "--mock" => cfg.use_mock_extractor = true,
            "--log-path" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--log-path".into()))?;
                cfg.log_path = Some(PathBuf::from(value));
            }
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
                cfg.listen = Some(addr);
            }
            "--knomosis-binary" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--knomosis-binary".into()))?;
                cfg.knomosis_binary = Some(PathBuf::from(value));
            }
            "--max-subscriber-lag" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--max-subscriber-lag".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--max-subscriber-lag".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.max_subscriber_lag = n;
            }
            "--keep-history" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--keep-history".into()))?;
                let n = value
                    .parse::<usize>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--keep-history".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.keep_history = n;
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
            "--max-subscribers" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--max-subscribers".into()))?;
                let n = value
                    .parse::<usize>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--max-subscribers".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.max_subscribers = n;
            }
            "--send-queue-depth" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--send-queue-depth".into()))?;
                let n = value
                    .parse::<usize>()
                    .map_err(|e| ParseError::InvalidValue {
                        flag: "--send-queue-depth".into(),
                        value: value.clone(),
                        reason: e.to_string(),
                    })?;
                cfg.send_queue_depth = n;
            }
            "--poll-interval-ms" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--poll-interval-ms".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--poll-interval-ms".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.poll_interval = Duration::from_millis(n);
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
            "--write-timeout-ms" => {
                let value = iter
                    .next()
                    .ok_or_else(|| ParseError::MissingValue("--write-timeout-ms".into()))?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--write-timeout-ms".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.write_timeout = Duration::from_millis(n);
            }
            "--handshake-read-timeout-ms" => {
                let value = iter.next().ok_or_else(|| {
                    ParseError::MissingValue("--handshake-read-timeout-ms".into())
                })?;
                let n = value.parse::<u64>().map_err(|e| ParseError::InvalidValue {
                    flag: "--handshake-read-timeout-ms".into(),
                    value: value.clone(),
                    reason: e.to_string(),
                })?;
                cfg.handshake_read_timeout = Duration::from_millis(n);
            }
            other => return Err(ParseError::UnknownFlag(other.to_string())),
        }
    }
    Ok(cfg)
}

/// Format the help text.
#[must_use]
pub fn help_text(program_name: &str) -> String {
    format!(
        "{program_name} — Knomosis event subscription server (RH-D)\n\
         \n\
         Usage:\n\
         \x20 {program_name} --log-path /var/lib/knomosis/log.bin --listen 127.0.0.1:7655 --mock\n\
         \x20 {program_name} --log-path /var/lib/knomosis/log.bin --listen 127.0.0.1:7655 \\\n\
         \x20\x20\x20\x20\x20\x20 --knomosis-binary /usr/bin/knomosis\n\
         \n\
         Required:\n\
         \x20 --log-path <PATH>             Knomosis log file to tail\n\
         \x20 --listen <ADDR>               TCP listen address (e.g. 127.0.0.1:7655)\n\
         \n\
         Extractor (exactly one required):\n\
         \x20 --mock                        Use MockExtractor (test/dev only)\n\
         \x20 --knomosis-binary <PATH>         Path to the `knomosis` binary\n\
         \n\
         Tuning:\n\
         \x20 --max-subscriber-lag <N>      Lag threshold (default 256)\n\
         \x20 --keep-history <N>            Backfill cache depth (default 256)\n\
         \x20 --max-frame-size <N>          Maximum event payload bytes (default 1 MiB)\n\
         \x20 --max-subscribers <N>         Cap on simultaneous subscribers (default 256)\n\
         \x20 --max-concurrent-connections <N>\n\
         \x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20Cap on simultaneous dispatch threads (default 1024)\n\
         \x20 --send-queue-depth <N>        Per-subscriber outbound queue (default 64)\n\
         \x20 --poll-interval-ms <N>        Tail-reader poll interval (default 100)\n\
         \x20 --write-timeout-ms <N>        TCP write timeout (default 30000)\n\
         \x20 --handshake-read-timeout-ms <N>\n\
         \x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20\x20SUBSCRIBE handshake read timeout (default 10000)\n\
         \n\
         Other:\n\
         \x20 --help / -h                   Print this help text\n\
         \x20 --version / -v                Print the subscriber version\n\
         \n\
         See `docs/abi.md` §11 for the wire-format specification and\n\
         `docs/planning/rust_host_runtime_plan.md` §RH-D for the design.\n",
    )
}

#[cfg(test)]
mod tests {
    use super::{parse_args, Config, ConfigError, ParseError, DEFAULT_MAX_SUBSCRIBERS};

    fn args(items: &[&str]) -> Vec<String> {
        let mut v = vec!["knomosis-event-subscribe".to_string()];
        v.extend(items.iter().map(|s| (*s).to_string()));
        v
    }

    fn good_args() -> Vec<&'static str> {
        vec![
            "--log-path",
            "/tmp/log.bin",
            "--listen",
            "127.0.0.1:7655",
            "--mock",
        ]
    }

    /// Constants are documented values.
    #[test]
    fn constants_stable() {
        assert_eq!(DEFAULT_MAX_SUBSCRIBERS, 256);
    }

    /// Default config has nothing set; validate fails.
    #[test]
    fn defaults_fail_validation() {
        let cfg = Config::defaults();
        match cfg.validate() {
            Err(ConfigError::NoLogPath) => {}
            other => panic!("expected NoLogPath, got {other:?}"),
        }
    }

    /// Good args + mock validates.
    #[test]
    fn good_args_validate() {
        let cfg = parse_args(&args(&good_args())).unwrap();
        cfg.validate().unwrap();
        assert!(cfg.use_mock_extractor);
        assert_eq!(cfg.listen.unwrap().port(), 7655);
    }

    /// `--knomosis-binary` instead of `--mock`.
    #[test]
    fn knomosis_binary_validates() {
        let cfg = parse_args(&args(&[
            "--log-path",
            "/tmp/log.bin",
            "--listen",
            "127.0.0.1:7655",
            "--knomosis-binary",
            "/usr/bin/knomosis",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert!(cfg.knomosis_binary.is_some());
        assert!(!cfg.use_mock_extractor);
    }

    /// `--mock` and `--knomosis-binary` both set: conflict.
    #[test]
    fn mock_plus_knomosis_binary_conflicts() {
        let cfg = parse_args(&args(&[
            "--log-path",
            "/tmp/log.bin",
            "--listen",
            "127.0.0.1:7655",
            "--mock",
            "--knomosis-binary",
            "/usr/bin/knomosis",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::ConflictingExtractor) => {}
            other => panic!("expected ConflictingExtractor, got {other:?}"),
        }
    }

    /// Missing extractor fails.
    #[test]
    fn no_extractor_fails() {
        let cfg = parse_args(&args(&[
            "--log-path",
            "/tmp/log.bin",
            "--listen",
            "127.0.0.1:7655",
        ]))
        .unwrap();
        match cfg.validate() {
            Err(ConfigError::NoExtractor) => {}
            other => panic!("expected NoExtractor, got {other:?}"),
        }
    }

    /// Missing log-path fails.
    #[test]
    fn no_log_path_fails() {
        let cfg = parse_args(&args(&["--listen", "127.0.0.1:7655", "--mock"])).unwrap();
        match cfg.validate() {
            Err(ConfigError::NoLogPath) => {}
            other => panic!("expected NoLogPath, got {other:?}"),
        }
    }

    /// Missing listen fails.
    #[test]
    fn no_listen_addr_fails() {
        let cfg = parse_args(&args(&["--log-path", "/tmp/log.bin", "--mock"])).unwrap();
        match cfg.validate() {
            Err(ConfigError::NoListenAddr) => {}
            other => panic!("expected NoListenAddr, got {other:?}"),
        }
    }

    /// `--help` returns `HelpRequested`.
    #[test]
    fn help_returns_help_requested() {
        match parse_args(&args(&["--help"])) {
            Err(ParseError::HelpRequested) => {}
            other => panic!("expected HelpRequested, got {other:?}"),
        }
    }

    /// `-h` short form.
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

    /// Unknown flag is reported.
    #[test]
    fn unknown_flag_returns_error() {
        match parse_args(&args(&["--bogus"])) {
            Err(ParseError::UnknownFlag(s)) => assert_eq!(s, "--bogus"),
            other => panic!("expected UnknownFlag, got {other:?}"),
        }
    }

    /// Missing value is reported.
    #[test]
    fn missing_value_returns_error() {
        match parse_args(&args(&["--log-path"])) {
            Err(ParseError::MissingValue(s)) => assert_eq!(s, "--log-path"),
            other => panic!("expected MissingValue, got {other:?}"),
        }
    }

    /// Invalid listen address is reported.
    #[test]
    fn invalid_listen_returns_error() {
        match parse_args(&args(&[
            "--log-path",
            "/tmp/log.bin",
            "--listen",
            "not-an-addr",
            "--mock",
        ])) {
            Err(ParseError::InvalidValue { flag, .. }) => assert_eq!(flag, "--listen"),
            other => panic!("expected InvalidValue, got {other:?}"),
        }
    }

    /// `--max-subscriber-lag 0` fails validation.
    #[test]
    fn max_lag_zero_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--max-subscriber-lag");
        args_vec.push("0");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxLagZero) => {}
            other => panic!("expected MaxLagZero, got {other:?}"),
        }
    }

    /// `--max-subscriber-lag` above hard ceiling fails.
    #[test]
    fn max_lag_too_large_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--max-subscriber-lag");
        args_vec.push("99999999999");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxLagTooLarge(_)) => {}
            other => panic!("expected MaxLagTooLarge, got {other:?}"),
        }
    }

    /// `--keep-history 0` fails.
    #[test]
    fn keep_history_zero_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--keep-history");
        args_vec.push("0");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::KeepHistoryZero) => {}
            other => panic!("expected KeepHistoryZero, got {other:?}"),
        }
    }

    /// `--keep-history` above hard ceiling fails.
    #[test]
    fn keep_history_too_large_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--keep-history");
        args_vec.push("999999999");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::KeepHistoryTooLarge(_)) => {}
            other => panic!("expected KeepHistoryTooLarge, got {other:?}"),
        }
    }

    /// `--max-frame-size 0` fails.
    #[test]
    fn frame_size_zero_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--max-frame-size");
        args_vec.push("0");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::FrameSizeZero) => {}
            other => panic!("expected FrameSizeZero, got {other:?}"),
        }
    }

    /// `--max-frame-size` above hard ceiling fails.
    #[test]
    fn frame_size_too_large_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--max-frame-size");
        args_vec.push("999999999");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::FrameSizeTooLarge(_)) => {}
            other => panic!("expected FrameSizeTooLarge, got {other:?}"),
        }
    }

    /// `--max-subscribers 0` fails.
    #[test]
    fn max_subscribers_zero_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--max-subscribers");
        args_vec.push("0");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxSubscribersZero) => {}
            other => panic!("expected MaxSubscribersZero, got {other:?}"),
        }
    }

    /// `--max-subscribers` above hard ceiling fails.
    #[test]
    fn max_subscribers_too_large_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--max-subscribers");
        args_vec.push("999999");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxSubscribersTooLarge(_)) => {}
            other => panic!("expected MaxSubscribersTooLarge, got {other:?}"),
        }
    }

    /// `--send-queue-depth 0` fails.
    #[test]
    fn send_queue_depth_zero_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--send-queue-depth");
        args_vec.push("0");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::SendQueueDepthZero) => {}
            other => panic!("expected SendQueueDepthZero, got {other:?}"),
        }
    }

    /// `--send-queue-depth` above hard ceiling fails.
    #[test]
    fn send_queue_depth_too_large_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--send-queue-depth");
        args_vec.push("999999");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::SendQueueDepthTooLarge(_)) => {}
            other => panic!("expected SendQueueDepthTooLarge, got {other:?}"),
        }
    }

    /// `--poll-interval-ms 0` fails.
    #[test]
    fn poll_interval_zero_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--poll-interval-ms");
        args_vec.push("0");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::PollIntervalZero) => {}
            other => panic!("expected PollIntervalZero, got {other:?}"),
        }
    }

    /// `--poll-interval-ms` above ceiling fails.
    #[test]
    fn poll_interval_too_large_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--poll-interval-ms");
        args_vec.push("999999");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::PollIntervalTooLarge(_)) => {}
            other => panic!("expected PollIntervalTooLarge, got {other:?}"),
        }
    }

    /// **H-NEW-3 audit regression: `--max-concurrent-connections`
    /// below `--max-subscribers` is rejected at config-validation
    /// time.**  Otherwise SUBSCRIBE requests could be refused at
    /// the slot cap even though the registry has room.
    #[test]
    fn max_concurrent_below_max_subscribers_fails() {
        let mut args_vec: Vec<&str> = good_args();
        args_vec.push("--max-subscribers");
        args_vec.push("100");
        args_vec.push("--max-concurrent-connections");
        args_vec.push("50");
        let cfg = parse_args(&args(&args_vec)).unwrap();
        match cfg.validate() {
            Err(ConfigError::MaxConcurrentConnectionsBelowMaxSubscribers {
                max_concurrent_connections,
                max_subscribers,
            }) => {
                assert_eq!(max_concurrent_connections, 50);
                assert_eq!(max_subscribers, 100);
            }
            other => panic!("expected MaxConcurrentConnectionsBelowMaxSubscribers, got {other:?}"),
        }
    }

    /// All flags exercised together.
    #[test]
    fn all_flags_together() {
        let cfg = parse_args(&args(&[
            "--log-path",
            "/var/log/knomosis.bin",
            "--listen",
            "127.0.0.1:7655",
            "--mock",
            "--max-subscriber-lag",
            "100",
            "--keep-history",
            "128",
            "--max-frame-size",
            "2048",
            "--max-subscribers",
            "64",
            "--send-queue-depth",
            "32",
            "--poll-interval-ms",
            "50",
        ]))
        .unwrap();
        cfg.validate().unwrap();
        assert_eq!(cfg.max_subscriber_lag, 100);
        assert_eq!(cfg.keep_history, 128);
        assert_eq!(cfg.max_frame_size, 2048);
        assert_eq!(cfg.max_subscribers, 64);
        assert_eq!(cfg.send_queue_depth, 32);
        assert_eq!(cfg.poll_interval.as_millis(), 50);
    }

    /// Help text mentions every required flag.
    #[test]
    fn help_text_non_empty() {
        let text = super::help_text("knomosis-event-subscribe");
        assert!(!text.is_empty());
        assert!(text.contains("knomosis-event-subscribe"));
        assert!(text.contains("--listen"));
        assert!(text.contains("--log-path"));
        assert!(text.contains("--mock"));
        assert!(text.contains("--knomosis-binary"));
        assert!(text.contains("--keep-history"));
        assert!(text.contains("--max-subscriber-lag"));
    }

    /// `ParseError` and `ConfigError` are `Send + Sync`.
    #[test]
    fn errors_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ParseError>();
        assert_send_sync::<ConfigError>();
        assert_send_sync::<Config>();
    }

    /// `Config::defaults()` round-trips through Debug.
    #[test]
    fn defaults_debug() {
        let cfg = Config::defaults();
        let _ = format!("{cfg:?}");
    }
}
