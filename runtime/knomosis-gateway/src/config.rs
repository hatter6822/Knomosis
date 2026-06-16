// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Gateway CLI / environment configuration.
//!
//! **Surface (G1.1 + G1.2d):** the HTTP listen address (`--listen` /
//! `KNX_GW_LISTEN`) and the bounded handler-pool size
//! (`--handler-threads` / `KNX_GW_HANDLER_THREADS`).  The full §9.2
//! flag surface — auth token file, host/event-subscribe/indexer
//! upstreams, budget-policy echo, the remaining governors, TLS,
//! timeouts, rate limits — lands in **G1.3**, whose validation
//! discipline (fail-fast with a typed `OperatorAction` error naming the
//! offending knob) this module's shape anticipates.

use std::net::SocketAddr;
use std::path::PathBuf;

/// Default HTTP listen address — loopback-safe per §9.2 (the gateway
/// sits behind the BFF / an L7 edge; it is not bound to `0.0.0.0` by
/// default).
pub const DEFAULT_LISTEN: &str = "127.0.0.1:8080";

/// Environment variable mirroring `--listen` (§9.2).  The CLI flag
/// takes precedence over the environment.
pub const LISTEN_ENV: &str = "KNX_GW_LISTEN";

/// Default size of the bounded request-handler thread pool (G1.2d).
/// The gateway is a synchronous server: this many worker threads each
/// block on `tiny_http::Server::recv`, so the pool caps concurrent
/// request *processing* — the practical resource governor.
pub const DEFAULT_HANDLER_THREADS: usize = 16;

/// Sanity ceiling on `--handler-threads` (far above any reasonable
/// single-host deployment; rejects a fat-finger that would exhaust
/// the thread table).
pub const MAX_HANDLER_THREADS: usize = 4096;

/// Environment variable mirroring `--handler-threads`.  The CLI flag
/// takes precedence over the environment.
pub const HANDLER_THREADS_ENV: &str = "KNX_GW_HANDLER_THREADS";

/// Environment variable mirroring `--indexer-db`.  The CLI flag takes
/// precedence over the environment.
pub const INDEXER_DB_ENV: &str = "KNX_GW_INDEXER_DB";

/// `--help` text for the scaffold surface (expanded in G1.3).
pub const HELP_TEXT: &str = "\
knomosis-gateway — HTTP/JSON + SSE gateway for the Knomosis runtime

USAGE:
    knomosis-gateway [OPTIONS]

OPTIONS:
    --listen <ADDR>    HTTP listen address (env KNX_GW_LISTEN)
                       [default: 127.0.0.1:8080]
    --handler-threads <N>
                       Bounded request-handler pool size; caps
                       concurrent request processing
                       (env KNX_GW_HANDLER_THREADS) [default: 16]
    --indexer-db <PATH>
                       Path to the knomosis-indexer SQLite database,
                       opened READ-ONLY for balance/budget/pool reads
                       (env KNX_GW_INDEXER_DB) [default: reads disabled]
    -h, --help         Print this help and exit
    -V, --version      Print version and exit

NOTE: this is the G1.1 scaffold; the full configuration surface
(auth, upstreams, governors, TLS) lands in G1.3.
";

/// Errors from parsing the gateway's CLI / environment configuration.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// `-h` / `--help` was requested.  Not a failure: `main` prints
    /// [`HELP_TEXT`] and exits `Success`.
    #[error("help requested")]
    HelpRequested,
    /// `-V` / `--version` was requested.
    #[error("version requested")]
    VersionRequested,
    /// A flag that requires a value was given none.
    #[error("flag {flag} requires a value")]
    MissingValue {
        /// The flag missing its argument.
        flag: String,
    },
    /// A flag value failed to parse.
    #[error("invalid value for {flag}: {value:?} ({reason})")]
    InvalidValue {
        /// The flag whose value was invalid.
        flag: String,
        /// The offending value.
        value: String,
        /// The parser's diagnostic.
        reason: String,
    },
    /// An unrecognised argument was supplied.
    #[error("unknown argument: {0:?}")]
    UnknownArgument(String),
}

/// Validated gateway configuration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    /// HTTP listen address.
    pub listen: SocketAddr,
    /// Bounded request-handler thread-pool size (G1.2d): the number of
    /// worker threads each blocking on `Server::recv`, capping
    /// concurrent request processing.  Always in `1..=MAX_HANDLER_THREADS`.
    pub handler_threads: usize,
    /// Path to the indexer SQLite database, opened READ-ONLY for the
    /// balance / budget / pool reads (G1.6b).  `None` disables the read
    /// endpoints (they answer `503`); set via `--indexer-db`.
    pub indexer_db: Option<PathBuf>,
}

impl Config {
    /// Parse configuration from the full process argument vector
    /// (`args[0]` is the program name, parsing starts at `args[1]`),
    /// with an environment-variable fallback for `--listen`.
    ///
    /// # Errors
    ///
    /// Returns [`ConfigError::HelpRequested`] /
    /// [`ConfigError::VersionRequested`] for the respective flags (the
    /// caller treats these as a clean exit), or a parse error
    /// ([`ConfigError::MissingValue`] / [`ConfigError::InvalidValue`] /
    /// [`ConfigError::UnknownArgument`]) the caller surfaces as
    /// `OperatorAction`.
    pub fn parse(args: &[String]) -> Result<Self, ConfigError> {
        let mut listen_raw: Option<String> = None;
        let mut handler_threads_raw: Option<String> = None;
        let mut indexer_db_raw: Option<String> = None;
        let mut i = 1;
        while let Some(arg) = args.get(i) {
            match arg.as_str() {
                "-h" | "--help" => return Err(ConfigError::HelpRequested),
                "-V" | "--version" => return Err(ConfigError::VersionRequested),
                "--listen" => {
                    let value = args.get(i + 1).ok_or_else(|| ConfigError::MissingValue {
                        flag: "--listen".to_string(),
                    })?;
                    listen_raw = Some(value.clone());
                    i += 1;
                }
                "--handler-threads" => {
                    let value = args.get(i + 1).ok_or_else(|| ConfigError::MissingValue {
                        flag: "--handler-threads".to_string(),
                    })?;
                    handler_threads_raw = Some(value.clone());
                    i += 1;
                }
                "--indexer-db" => {
                    let value = args.get(i + 1).ok_or_else(|| ConfigError::MissingValue {
                        flag: "--indexer-db".to_string(),
                    })?;
                    indexer_db_raw = Some(value.clone());
                    i += 1;
                }
                other => return Err(ConfigError::UnknownArgument(other.to_string())),
            }
            i += 1;
        }

        // Precedence: CLI flag > environment > compiled default.
        let listen_str = listen_raw
            .or_else(|| std::env::var(LISTEN_ENV).ok())
            .unwrap_or_else(|| DEFAULT_LISTEN.to_string());
        let listen = listen_str
            .parse::<SocketAddr>()
            .map_err(|e| ConfigError::InvalidValue {
                flag: "--listen".to_string(),
                value: listen_str.clone(),
                reason: e.to_string(),
            })?;

        let handler_threads =
            match handler_threads_raw.or_else(|| std::env::var(HANDLER_THREADS_ENV).ok()) {
                None => DEFAULT_HANDLER_THREADS,
                Some(raw) => {
                    let n = raw
                        .parse::<usize>()
                        .map_err(|e| ConfigError::InvalidValue {
                            flag: "--handler-threads".to_string(),
                            value: raw.clone(),
                            reason: e.to_string(),
                        })?;
                    if n == 0 || n > MAX_HANDLER_THREADS {
                        return Err(ConfigError::InvalidValue {
                            flag: "--handler-threads".to_string(),
                            value: raw,
                            reason: format!("must be in 1..={MAX_HANDLER_THREADS}"),
                        });
                    }
                    n
                }
            };

        let indexer_db = indexer_db_raw
            .or_else(|| std::env::var(INDEXER_DB_ENV).ok())
            .map(PathBuf::from);

        Ok(Self {
            listen,
            handler_threads,
            indexer_db,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{Config, ConfigError, DEFAULT_LISTEN};

    fn argv(extra: &[&str]) -> Vec<String> {
        let mut v = vec!["knomosis-gateway".to_string()];
        v.extend(extra.iter().map(|s| (*s).to_string()));
        v
    }

    /// No args → the loopback default listen address.
    #[test]
    fn defaults_to_loopback() {
        // Ensure the env override is absent for a deterministic test.
        std::env::remove_var(super::LISTEN_ENV);
        let cfg = Config::parse(&argv(&[])).unwrap();
        assert_eq!(cfg.listen.to_string(), DEFAULT_LISTEN);
    }

    /// `--listen` overrides the default and parses a SocketAddr.
    #[test]
    fn listen_flag_parsed() {
        let cfg = Config::parse(&argv(&["--listen", "127.0.0.1:9999"])).unwrap();
        assert_eq!(cfg.listen.to_string(), "127.0.0.1:9999");
    }

    /// `--help` / `--version` surface as their typed sentinels.
    #[test]
    fn help_and_version_sentinels() {
        assert!(matches!(
            Config::parse(&argv(&["--help"])),
            Err(ConfigError::HelpRequested)
        ));
        assert!(matches!(
            Config::parse(&argv(&["-h"])),
            Err(ConfigError::HelpRequested)
        ));
        assert!(matches!(
            Config::parse(&argv(&["--version"])),
            Err(ConfigError::VersionRequested)
        ));
        assert!(matches!(
            Config::parse(&argv(&["-V"])),
            Err(ConfigError::VersionRequested)
        ));
    }

    /// `--listen` with no value → `MissingValue`.
    #[test]
    fn listen_missing_value() {
        assert!(matches!(
            Config::parse(&argv(&["--listen"])),
            Err(ConfigError::MissingValue { .. })
        ));
    }

    /// A malformed listen address → `InvalidValue`.
    #[test]
    fn listen_invalid_value() {
        assert!(matches!(
            Config::parse(&argv(&["--listen", "not-an-addr"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// An unknown flag → `UnknownArgument`.
    #[test]
    fn unknown_argument_rejected() {
        assert!(matches!(
            Config::parse(&argv(&["--nope"])),
            Err(ConfigError::UnknownArgument(_))
        ));
    }

    /// `--handler-threads` defaults to [`super::DEFAULT_HANDLER_THREADS`]
    /// and is overridable on the CLI.
    #[test]
    fn handler_threads_default_and_override() {
        std::env::remove_var(super::HANDLER_THREADS_ENV);
        let cfg = Config::parse(&argv(&[])).unwrap();
        assert_eq!(cfg.handler_threads, super::DEFAULT_HANDLER_THREADS);
        let cfg = Config::parse(&argv(&["--handler-threads", "4"])).unwrap();
        assert_eq!(cfg.handler_threads, 4);
    }

    /// `--handler-threads 0` is rejected (the pool must be non-empty).
    #[test]
    fn handler_threads_zero_rejected() {
        assert!(matches!(
            Config::parse(&argv(&["--handler-threads", "0"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--handler-threads` above the ceiling is rejected.
    #[test]
    fn handler_threads_above_ceiling_rejected() {
        let too_many = (super::MAX_HANDLER_THREADS + 1).to_string();
        assert!(matches!(
            Config::parse(&argv(&["--handler-threads", &too_many])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// A non-numeric `--handler-threads` value is rejected.
    #[test]
    fn handler_threads_non_numeric_rejected() {
        assert!(matches!(
            Config::parse(&argv(&["--handler-threads", "lots"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--indexer-db` is parsed to a path; absent → `None`.
    #[test]
    fn indexer_db_optional() {
        std::env::remove_var(super::INDEXER_DB_ENV);
        assert_eq!(Config::parse(&argv(&[])).unwrap().indexer_db, None);
        let cfg = Config::parse(&argv(&["--indexer-db", "/var/lib/knomosis/index.db"])).unwrap();
        assert_eq!(
            cfg.indexer_db,
            Some(std::path::PathBuf::from("/var/lib/knomosis/index.db"))
        );
    }
}
