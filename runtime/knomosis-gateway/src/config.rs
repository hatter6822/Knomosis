// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Gateway CLI / environment configuration.
//!
//! **Scaffold surface (G1.1):** only the HTTP listen address
//! (`--listen` / `KNX_GW_LISTEN`).  The full §9.2 flag surface — auth
//! token file, host/event-subscribe/indexer upstreams, budget-policy
//! echo, governors, TLS, timeouts, rate limits — lands in **G1.3**,
//! whose validation discipline (fail-fast with a typed
//! `OperatorAction` error naming the offending knob) this module's
//! shape anticipates.

use std::net::SocketAddr;

/// Default HTTP listen address — loopback-safe per §9.2 (the gateway
/// sits behind the BFF / an L7 edge; it is not bound to `0.0.0.0` by
/// default).
pub const DEFAULT_LISTEN: &str = "127.0.0.1:8080";

/// Environment variable mirroring `--listen` (§9.2).  The CLI flag
/// takes precedence over the environment.
pub const LISTEN_ENV: &str = "KNX_GW_LISTEN";

/// `--help` text for the scaffold surface (expanded in G1.3).
pub const HELP_TEXT: &str = "\
knomosis-gateway — HTTP/JSON + SSE gateway for the Knomosis runtime

USAGE:
    knomosis-gateway [OPTIONS]

OPTIONS:
    --listen <ADDR>    HTTP listen address (env KNX_GW_LISTEN)
                       [default: 127.0.0.1:8080]
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

        Ok(Self { listen })
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
}
