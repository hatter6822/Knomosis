// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! CLI flag parsing for `canon-indexer`.
//!
//! ## Subcommands
//!
//! Two subcommands ship with this binary:
//!
//!   * `daemon` (default if no subcommand given) — long-running
//!     daemon that subscribes to canon-event-subscribe and
//!     maintains the balance view in the configured storage
//!     database.
//!   * `query <actor> <resource>` — one-shot lookup against the
//!     storage database.  Useful for operators investigating a
//!     specific balance.
//!
//! ## Why hand-rolled (no clap dependency)
//!
//! Matches the workspace convention (canon-host, canon-l1-ingest,
//! canon-event-subscribe all hand-roll their parsers).  The
//! flag surface is small and stable; pulling clap in would add
//! a sizeable transitive dependency tree for marginal benefit.

use std::path::PathBuf;

/// Default subscribe endpoint.
pub const DEFAULT_SUBSCRIBE_ENDPOINT: &str = "127.0.0.1:7655";

/// Default poll interval (ms) when the subscriber returns
/// `ServerShutdown`/`LagExceeded` and we want to reconnect.
pub const DEFAULT_RECONNECT_BACKOFF_MS: u64 = 1000;

/// Default maximum number of reconnection attempts before
/// surfacing a hard failure.  Operators tune via
/// `--max-reconnects`.
pub const DEFAULT_MAX_RECONNECTS: u32 = 1000;

/// Default frame-size cap.
pub const DEFAULT_MAX_FRAME_SIZE: usize = 1024 * 1024;

/// Top-level subcommand.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Subcommand {
    /// Long-running daemon — subscribe + index + write.
    Daemon(DaemonConfig),
    /// One-shot query against the storage database.
    Query(QueryConfig),
}

/// Daemon-mode configuration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DaemonConfig {
    /// Path to the SQLite storage database.  Created if absent.
    pub storage_path: PathBuf,
    /// TCP endpoint of the canon-event-subscribe server.
    pub subscribe_endpoint: String,
    /// Maximum accepted event-payload size.
    pub max_frame_size: usize,
    /// Reconnect backoff (ms).
    pub reconnect_backoff_ms: u64,
    /// Maximum reconnects before surfacing a hard failure.  `0`
    /// disables the limit (loop forever).
    pub max_reconnects: u32,
    /// Optional `--verify-against-canon` URL.  When set, the
    /// daemon periodically queries canon-host for each indexed
    /// (actor, resource) and asserts equality.  Plumbed but not
    /// wired (the canon-host getBalance endpoint doesn't ship
    /// yet); operators set the flag to surface a clear
    /// "not-yet-implemented" message until the dependency lands.
    pub verify_against_canon: Option<String>,
}

/// Query-mode configuration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueryConfig {
    /// Path to the SQLite storage database.
    pub storage_path: PathBuf,
    /// Actor id to look up.
    pub actor: u64,
    /// Resource id to look up.
    pub resource: u64,
}

/// CLI-parse errors.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// Missing required flag.
    #[error("missing required flag: --{0}")]
    MissingFlag(String),
    /// Missing required positional argument.
    #[error("missing required argument: {0}")]
    MissingArg(String),
    /// Unknown subcommand or flag.
    #[error("unknown argument: {0}")]
    Unknown(String),
    /// Value cannot be parsed (number out of range, etc.).
    #[error("invalid value for {flag}: {value} ({reason})")]
    InvalidValue {
        /// Flag whose value was invalid.
        flag: String,
        /// The offending value.
        value: String,
        /// Parse-error reason.
        reason: String,
    },
    /// The user asked for `--help` (or `-h`).  Treated as a
    /// "soft" error: prints the help text and exits with `0`.
    #[error("help requested")]
    HelpRequested,
    /// The user asked for `--version`.  Soft error like help.
    #[error("version requested")]
    VersionRequested,
}

/// Parse the CLI arguments.  Used by `main` and (with synthesised
/// argv vectors) by the unit tests.
///
/// # Errors
///
/// See [`ConfigError`].
pub fn parse_args(args: &[String]) -> Result<Subcommand, ConfigError> {
    // First non-flag argument is the subcommand.  If absent, we
    // default to `daemon` to be operator-friendly (matches
    // canon-host's flag-first design).
    let mut iter = args.iter().peekable();
    // Skip argv[0] if present.
    if let Some(first) = iter.peek() {
        if first.starts_with("./") || first.starts_with('/') || first.contains("canon-indexer") {
            iter.next();
        }
    }
    // Handle top-level --help / --version before reading the
    // subcommand.
    let mut pending: Vec<String> = iter.cloned().collect();
    if pending.iter().any(|a| a == "--help" || a == "-h") {
        return Err(ConfigError::HelpRequested);
    }
    if pending.iter().any(|a| a == "--version" || a == "-V") {
        return Err(ConfigError::VersionRequested);
    }
    // Subcommand defaults to "daemon" if first positional isn't
    // present or starts with `-`.
    let subcommand = match pending.first().map(String::as_str) {
        Some("daemon") => {
            pending.remove(0);
            parse_daemon(&pending)?
        }
        Some("query") => {
            pending.remove(0);
            parse_query(&pending)?
        }
        Some(other) if !other.starts_with('-') => {
            return Err(ConfigError::Unknown(other.to_string()));
        }
        _ => parse_daemon(&pending)?,
    };
    Ok(subcommand)
}

fn parse_daemon(args: &[String]) -> Result<Subcommand, ConfigError> {
    let mut storage_path: Option<PathBuf> = None;
    let mut subscribe_endpoint = DEFAULT_SUBSCRIBE_ENDPOINT.to_string();
    let mut max_frame_size = DEFAULT_MAX_FRAME_SIZE;
    let mut reconnect_backoff_ms = DEFAULT_RECONNECT_BACKOFF_MS;
    let mut max_reconnects = DEFAULT_MAX_RECONNECTS;
    let mut verify_against_canon: Option<String> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--storage" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("storage".to_string()))?;
                storage_path = Some(PathBuf::from(v));
            }
            "--subscribe" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("subscribe".to_string()))?;
                subscribe_endpoint.clone_from(v);
            }
            "--max-frame-size" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("max-frame-size".to_string()))?;
                max_frame_size = parse_usize(v, "max-frame-size")?;
            }
            "--reconnect-backoff-ms" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("reconnect-backoff-ms".to_string()))?;
                reconnect_backoff_ms = parse_u64(v, "reconnect-backoff-ms")?;
            }
            "--max-reconnects" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("max-reconnects".to_string()))?;
                max_reconnects = parse_u32(v, "max-reconnects")?;
            }
            "--verify-against-canon" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("verify-against-canon".to_string()))?;
                verify_against_canon = Some(v.clone());
            }
            "--help" | "-h" => return Err(ConfigError::HelpRequested),
            "--version" | "-V" => return Err(ConfigError::VersionRequested),
            other => return Err(ConfigError::Unknown(other.to_string())),
        }
    }
    let storage_path =
        storage_path.ok_or_else(|| ConfigError::MissingFlag("storage".to_string()))?;
    Ok(Subcommand::Daemon(DaemonConfig {
        storage_path,
        subscribe_endpoint,
        max_frame_size,
        reconnect_backoff_ms,
        max_reconnects,
        verify_against_canon,
    }))
}

fn parse_query(args: &[String]) -> Result<Subcommand, ConfigError> {
    let mut storage_path: Option<PathBuf> = None;
    let mut actor: Option<u64> = None;
    let mut resource: Option<u64> = None;
    let mut iter = args.iter();
    let mut positional = 0u8;
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--storage" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("storage".to_string()))?;
                storage_path = Some(PathBuf::from(v));
            }
            "--help" | "-h" => return Err(ConfigError::HelpRequested),
            "--version" | "-V" => return Err(ConfigError::VersionRequested),
            other if !other.starts_with("--") => {
                // Positional argument.
                match positional {
                    0 => {
                        actor = Some(parse_u64(other, "actor")?);
                        positional = 1;
                    }
                    1 => {
                        resource = Some(parse_u64(other, "resource")?);
                        positional = 2;
                    }
                    _ => return Err(ConfigError::Unknown(other.to_string())),
                }
            }
            other => return Err(ConfigError::Unknown(other.to_string())),
        }
    }
    let storage_path =
        storage_path.ok_or_else(|| ConfigError::MissingFlag("storage".to_string()))?;
    let actor = actor.ok_or_else(|| ConfigError::MissingArg("actor".to_string()))?;
    let resource = resource.ok_or_else(|| ConfigError::MissingArg("resource".to_string()))?;
    Ok(Subcommand::Query(QueryConfig {
        storage_path,
        actor,
        resource,
    }))
}

fn parse_usize(value: &str, flag: &str) -> Result<usize, ConfigError> {
    value
        .parse::<usize>()
        .map_err(|e| ConfigError::InvalidValue {
            flag: flag.to_string(),
            value: value.to_string(),
            reason: e.to_string(),
        })
}

fn parse_u64(value: &str, flag: &str) -> Result<u64, ConfigError> {
    value.parse::<u64>().map_err(|e| ConfigError::InvalidValue {
        flag: flag.to_string(),
        value: value.to_string(),
        reason: e.to_string(),
    })
}

fn parse_u32(value: &str, flag: &str) -> Result<u32, ConfigError> {
    value.parse::<u32>().map_err(|e| ConfigError::InvalidValue {
        flag: flag.to_string(),
        value: value.to_string(),
        reason: e.to_string(),
    })
}

/// Help text printed when the user passes `--help`.  Centralised
/// so the test suite can pin its prefix.
pub const HELP_TEXT: &str = "\
canon-indexer — Canon SQLite event indexer (RH-E.1)

USAGE:
    canon-indexer [SUBCOMMAND] [OPTIONS]

SUBCOMMANDS:
    daemon (default)   Long-running daemon: subscribe to canon-event-subscribe
                       and maintain the balance view.
    query <actor> <resource>
                       One-shot lookup against the storage database.

DAEMON OPTIONS:
    --storage <PATH>                  SQLite database path (required).
    --subscribe <ADDR>                canon-event-subscribe endpoint
                                      (default: 127.0.0.1:7655).
    --max-frame-size <BYTES>          Max event payload size (default: 1 MiB).
    --reconnect-backoff-ms <MS>       Backoff between reconnects (default: 1000).
    --max-reconnects <N>              Max reconnects before giving up
                                      (default: 1000; 0 = infinite).
    --verify-against-canon <URL>      Periodically verify against canon-host's
                                      getBalance (not yet wired; will surface
                                      a NotImplemented message).

QUERY OPTIONS:
    --storage <PATH>                  SQLite database path (required).
    <actor>                           Actor id (decimal u64).
    <resource>                        Resource id (decimal u64).

GLOBAL OPTIONS:
    --help, -h                        Print this help text.
    --version, -V                     Print version and exit.

EXIT CODES:
    0   Clean exit.
    1   General failure (CLI parse error).
    2   Operator-actionable failure (DB open, connect, identifier mismatch).
    3   NotImplemented (e.g. --verify-against-canon with no canon-host endpoint).
   75   Transient failure (server temporarily unavailable; retry).
";

#[cfg(test)]
mod tests {
    use super::{
        parse_args, ConfigError, DaemonConfig, QueryConfig, Subcommand, DEFAULT_MAX_FRAME_SIZE,
        DEFAULT_MAX_RECONNECTS, DEFAULT_RECONNECT_BACKOFF_MS, DEFAULT_SUBSCRIBE_ENDPOINT,
        HELP_TEXT,
    };
    use std::path::PathBuf;

    fn args(s: &[&str]) -> Vec<String> {
        s.iter().map(|x| (*x).to_string()).collect()
    }

    /// Defaults pinned.
    #[test]
    fn defaults_stable() {
        assert_eq!(DEFAULT_SUBSCRIBE_ENDPOINT, "127.0.0.1:7655");
        assert_eq!(DEFAULT_RECONNECT_BACKOFF_MS, 1000);
        assert_eq!(DEFAULT_MAX_RECONNECTS, 1000);
        assert_eq!(DEFAULT_MAX_FRAME_SIZE, 1024 * 1024);
    }

    /// Help text starts with the documented prefix.
    #[test]
    fn help_text_prefix() {
        assert!(HELP_TEXT.starts_with("canon-indexer"));
    }

    /// Implicit daemon (no subcommand) requires --storage.
    #[test]
    fn implicit_daemon_requires_storage() {
        match parse_args(&args(&["canon-indexer"])) {
            Err(ConfigError::MissingFlag(f)) => assert_eq!(f, "storage"),
            other => panic!("expected MissingFlag, got {other:?}"),
        }
    }

    /// Explicit daemon subcommand with defaults.
    #[test]
    fn daemon_defaults() {
        let parsed = parse_args(&args(&[
            "canon-indexer",
            "daemon",
            "--storage",
            "/tmp/i.db",
        ]))
        .unwrap();
        match parsed {
            Subcommand::Daemon(cfg) => {
                assert_eq!(cfg.storage_path, PathBuf::from("/tmp/i.db"));
                assert_eq!(cfg.subscribe_endpoint, DEFAULT_SUBSCRIBE_ENDPOINT);
                assert_eq!(cfg.max_frame_size, DEFAULT_MAX_FRAME_SIZE);
                assert_eq!(cfg.reconnect_backoff_ms, DEFAULT_RECONNECT_BACKOFF_MS);
                assert_eq!(cfg.max_reconnects, DEFAULT_MAX_RECONNECTS);
                assert_eq!(cfg.verify_against_canon, None);
            }
            _ => panic!("expected Daemon variant"),
        }
    }

    /// All daemon flags parse.
    #[test]
    fn daemon_all_flags() {
        let parsed = parse_args(&args(&[
            "canon-indexer",
            "daemon",
            "--storage",
            "/tmp/i.db",
            "--subscribe",
            "10.0.0.1:1234",
            "--max-frame-size",
            "2097152",
            "--reconnect-backoff-ms",
            "500",
            "--max-reconnects",
            "10",
            "--verify-against-canon",
            "http://localhost:7654",
        ]))
        .unwrap();
        match parsed {
            Subcommand::Daemon(cfg) => {
                assert_eq!(cfg.storage_path, PathBuf::from("/tmp/i.db"));
                assert_eq!(cfg.subscribe_endpoint, "10.0.0.1:1234");
                assert_eq!(cfg.max_frame_size, 2097152);
                assert_eq!(cfg.reconnect_backoff_ms, 500);
                assert_eq!(cfg.max_reconnects, 10);
                assert_eq!(
                    cfg.verify_against_canon.as_deref(),
                    Some("http://localhost:7654")
                );
            }
            _ => panic!("expected Daemon variant"),
        }
    }

    /// `query` subcommand requires positional args.
    #[test]
    fn query_positional_args() {
        let parsed = parse_args(&args(&[
            "canon-indexer",
            "query",
            "--storage",
            "/tmp/i.db",
            "42",
            "99",
        ]))
        .unwrap();
        match parsed {
            Subcommand::Query(QueryConfig {
                storage_path,
                actor,
                resource,
            }) => {
                assert_eq!(storage_path, PathBuf::from("/tmp/i.db"));
                assert_eq!(actor, 42);
                assert_eq!(resource, 99);
            }
            _ => panic!("expected Query variant"),
        }
    }

    /// `query` missing positional args.
    #[test]
    fn query_missing_actor() {
        match parse_args(&args(&["canon-indexer", "query", "--storage", "/tmp/i.db"])) {
            Err(ConfigError::MissingArg(arg)) => assert_eq!(arg, "actor"),
            other => panic!("expected MissingArg, got {other:?}"),
        }
    }

    #[test]
    fn query_missing_resource() {
        match parse_args(&args(&[
            "canon-indexer",
            "query",
            "--storage",
            "/tmp/i.db",
            "42",
        ])) {
            Err(ConfigError::MissingArg(arg)) => assert_eq!(arg, "resource"),
            other => panic!("expected MissingArg, got {other:?}"),
        }
    }

    /// Invalid integer surface as `InvalidValue`.
    #[test]
    fn invalid_integer() {
        match parse_args(&args(&[
            "canon-indexer",
            "daemon",
            "--storage",
            "/tmp/i.db",
            "--max-frame-size",
            "not-a-number",
        ])) {
            Err(ConfigError::InvalidValue { flag, value, .. }) => {
                assert_eq!(flag, "max-frame-size");
                assert_eq!(value, "not-a-number");
            }
            other => panic!("expected InvalidValue, got {other:?}"),
        }
    }

    /// Help request.
    #[test]
    fn help_requested() {
        for h in ["--help", "-h"] {
            match parse_args(&args(&["canon-indexer", h])) {
                Err(ConfigError::HelpRequested) => {}
                other => panic!("expected HelpRequested for {h}, got {other:?}"),
            }
        }
    }

    /// Version request.
    #[test]
    fn version_requested() {
        for v in ["--version", "-V"] {
            match parse_args(&args(&["canon-indexer", v])) {
                Err(ConfigError::VersionRequested) => {}
                other => panic!("expected VersionRequested for {v}, got {other:?}"),
            }
        }
    }

    /// Unknown subcommand.
    #[test]
    fn unknown_subcommand() {
        match parse_args(&args(&["canon-indexer", "foo"])) {
            Err(ConfigError::Unknown(s)) => assert_eq!(s, "foo"),
            other => panic!("expected Unknown, got {other:?}"),
        }
    }

    /// Unknown flag.
    #[test]
    fn unknown_flag() {
        match parse_args(&args(&["canon-indexer", "daemon", "--bogus"])) {
            Err(ConfigError::Unknown(s)) => assert_eq!(s, "--bogus"),
            other => panic!("expected Unknown, got {other:?}"),
        }
    }

    /// `DaemonConfig` and `QueryConfig` are PartialEq / Clone.
    #[test]
    fn config_traits() {
        let a = DaemonConfig {
            storage_path: PathBuf::from("/a"),
            subscribe_endpoint: "127.0.0.1:7655".to_string(),
            max_frame_size: 1024,
            reconnect_backoff_ms: 100,
            max_reconnects: 10,
            verify_against_canon: None,
        };
        let b = a.clone();
        assert_eq!(a, b);

        let q = QueryConfig {
            storage_path: PathBuf::from("/q"),
            actor: 1,
            resource: 2,
        };
        let q2 = q.clone();
        assert_eq!(q, q2);
    }
}
