// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! CLI flag parsing for `knomosis-indexer`.
//!
//! ## Subcommands
//!
//! Two subcommands ship with this binary:
//!
//!   * `daemon` (default if no subcommand given) — long-running
//!     daemon that subscribes to knomosis-event-subscribe and
//!     maintains the balance view in the configured storage
//!     database.
//!   * `query <actor> <resource>` — one-shot lookup against the
//!     storage database.  Useful for operators investigating a
//!     specific balance.
//!
//! ## Why hand-rolled (no clap dependency)
//!
//! Matches the workspace convention (knomosis-host, knomosis-l1-ingest,
//! knomosis-event-subscribe all hand-roll their parsers).  The
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
    /// One-shot balance query against the storage database.
    Query(QueryConfig),
    /// GP.6.4: one-shot per-actor budget query (lifetime + per-epoch).
    QueryBudget(QueryBudgetConfig),
    /// GP.6.4: one-shot per-pool-actor ETH balance query.
    QueryPoolEth(QueryPoolConfig),
    /// GP.6.4: one-shot per-pool-actor BOLD balance query.
    QueryPoolBold(QueryPoolConfig),
}

/// Daemon-mode configuration.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DaemonConfig {
    /// Path to the SQLite storage database.  Created if absent.
    pub storage_path: PathBuf,
    /// TCP endpoint of the knomosis-event-subscribe server.
    pub subscribe_endpoint: String,
    /// Maximum accepted event-payload size.
    pub max_frame_size: usize,
    /// Reconnect backoff (ms).
    pub reconnect_backoff_ms: u64,
    /// Maximum reconnects before surfacing a hard failure.  `0`
    /// disables the limit (loop forever).
    pub max_reconnects: u32,
    /// Optional `--verify-against-knomosis` URL.  When set, the
    /// daemon periodically queries knomosis-host for each indexed
    /// (actor, resource) and asserts equality.  Plumbed but not
    /// wired (the knomosis-host getBalance endpoint doesn't ship
    /// yet); operators set the flag to surface a clear
    /// "not-yet-implemented" message until the dependency lands.
    pub verify_against_knomosis: Option<String>,
    /// GP.6.4: optional `--verify-budget-against-knomosis` URL.
    /// Symmetric stub for budget-view verification; surfaces a
    /// NotImplemented exit when set (until the knomosis-host
    /// budget endpoint lands).
    pub verify_budget_against_knomosis: Option<String>,
    /// GP.6.4: `--gas-pool-actor <id>` — when set, the daemon's
    /// apply_batch decrements `pool_balances_{eth,bold}[id]` on
    /// every `Event.gasPoolClaim` (matching its resource); when
    /// unset, GasPoolClaim is a no-op and the pool views track
    /// only gross inflows.
    pub gas_pool_actor: Option<u64>,
    /// GP.6.4: `--epoch-length <N>` — when `> 0`, the daemon's
    /// apply_batch resets the per-epoch tables at every
    /// `epoch_length` seqs (mirroring the Lean runtime's
    /// `BudgetPolicy.advanceEpoch`); when `0`, epoch advancement
    /// is disabled.
    pub epoch_length: u64,
}

/// Query-mode configuration (balance view).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueryConfig {
    /// Path to the SQLite storage database.
    pub storage_path: PathBuf,
    /// Actor id to look up.
    pub actor: u64,
    /// Resource id to look up.
    pub resource: u64,
}

/// GP.6.4: query-budget configuration (per-actor budget view).
/// Prints lifetime cumulative grants + current-epoch grants +
/// current-epoch consumed + (if `--free-tier <N>` supplied)
/// `remaining_this_epoch`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueryBudgetConfig {
    /// Path to the SQLite storage database.
    pub storage_path: PathBuf,
    /// Actor id to look up.
    pub actor: u64,
    /// Optional `--free-tier <N>`.  When supplied, the output
    /// includes `remaining_this_epoch = free_tier +
    /// current_epoch_grants - current_epoch_consumed`.
    pub free_tier: Option<u128>,
}

/// GP.6.4: query-pool-* configuration (per-pool-actor view).
/// Used by both `query-pool-eth` and `query-pool-bold`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueryPoolConfig {
    /// Path to the SQLite storage database.
    pub storage_path: PathBuf,
    /// Pool actor id to look up.
    pub actor: u64,
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
    // knomosis-host's flag-first design).
    let mut iter = args.iter().peekable();
    // Skip argv[0] if present.
    if let Some(first) = iter.peek() {
        if first.starts_with("./") || first.starts_with('/') || first.contains("knomosis-indexer") {
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
    // present or starts with `-`.  GP.6.4 adds three new
    // subcommands: query-budget, query-pool-eth, query-pool-bold.
    let subcommand = match pending.first().map(String::as_str) {
        Some("daemon") => {
            pending.remove(0);
            parse_daemon(&pending)?
        }
        Some("query") => {
            pending.remove(0);
            parse_query(&pending)?
        }
        Some("query-budget") => {
            pending.remove(0);
            parse_query_budget(&pending)?
        }
        Some("query-pool-eth") => {
            pending.remove(0);
            parse_query_pool(&pending, /*bold=*/ false)?
        }
        Some("query-pool-bold") => {
            pending.remove(0);
            parse_query_pool(&pending, /*bold=*/ true)?
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
    let mut verify_against_knomosis: Option<String> = None;
    let mut verify_budget_against_knomosis: Option<String> = None;
    let mut gas_pool_actor: Option<u64> = None;
    let mut epoch_length: u64 = 0;
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
            "--verify-against-knomosis" => {
                let v = iter.next().ok_or_else(|| {
                    ConfigError::MissingFlag("verify-against-knomosis".to_string())
                })?;
                verify_against_knomosis = Some(v.clone());
            }
            "--verify-budget-against-knomosis" => {
                let v = iter.next().ok_or_else(|| {
                    ConfigError::MissingFlag("verify-budget-against-knomosis".to_string())
                })?;
                verify_budget_against_knomosis = Some(v.clone());
            }
            "--gas-pool-actor" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("gas-pool-actor".to_string()))?;
                gas_pool_actor = Some(parse_u64(v, "gas-pool-actor")?);
            }
            "--epoch-length" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("epoch-length".to_string()))?;
                epoch_length = parse_u64(v, "epoch-length")?;
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
        verify_against_knomosis,
        verify_budget_against_knomosis,
        gas_pool_actor,
        epoch_length,
    }))
}

/// GP.6.4: parse `query-budget` arguments.
fn parse_query_budget(args: &[String]) -> Result<Subcommand, ConfigError> {
    let mut storage_path: Option<PathBuf> = None;
    let mut actor: Option<u64> = None;
    let mut free_tier: Option<u128> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--storage" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("storage".to_string()))?;
                storage_path = Some(PathBuf::from(v));
            }
            "--free-tier" => {
                let v = iter
                    .next()
                    .ok_or_else(|| ConfigError::MissingFlag("free-tier".to_string()))?;
                free_tier = Some(parse_u128(v, "free-tier")?);
            }
            "--help" | "-h" => return Err(ConfigError::HelpRequested),
            "--version" | "-V" => return Err(ConfigError::VersionRequested),
            other if !other.starts_with("--") => {
                if actor.is_some() {
                    return Err(ConfigError::Unknown(other.to_string()));
                }
                actor = Some(parse_u64(other, "actor")?);
            }
            other => return Err(ConfigError::Unknown(other.to_string())),
        }
    }
    let storage_path =
        storage_path.ok_or_else(|| ConfigError::MissingFlag("storage".to_string()))?;
    let actor = actor.ok_or_else(|| ConfigError::MissingArg("actor".to_string()))?;
    Ok(Subcommand::QueryBudget(QueryBudgetConfig {
        storage_path,
        actor,
        free_tier,
    }))
}

/// GP.6.4: parse `query-pool-eth` / `query-pool-bold` arguments.
fn parse_query_pool(args: &[String], bold: bool) -> Result<Subcommand, ConfigError> {
    let mut storage_path: Option<PathBuf> = None;
    let mut actor: Option<u64> = None;
    let mut iter = args.iter();
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
                if actor.is_some() {
                    return Err(ConfigError::Unknown(other.to_string()));
                }
                actor = Some(parse_u64(other, "actor")?);
            }
            other => return Err(ConfigError::Unknown(other.to_string())),
        }
    }
    let storage_path =
        storage_path.ok_or_else(|| ConfigError::MissingFlag("storage".to_string()))?;
    let actor = actor.ok_or_else(|| ConfigError::MissingArg("actor".to_string()))?;
    let cfg = QueryPoolConfig {
        storage_path,
        actor,
    };
    Ok(if bold {
        Subcommand::QueryPoolBold(cfg)
    } else {
        Subcommand::QueryPoolEth(cfg)
    })
}

fn parse_u128(value: &str, flag: &str) -> Result<u128, ConfigError> {
    value
        .parse::<u128>()
        .map_err(|e| ConfigError::InvalidValue {
            flag: flag.to_string(),
            value: value.to_string(),
            reason: e.to_string(),
        })
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
knomosis-indexer — Knomosis SQLite event indexer (RH-E.1)

USAGE:
    knomosis-indexer [SUBCOMMAND] [OPTIONS]

SUBCOMMANDS:
    daemon (default)   Long-running daemon: subscribe to knomosis-event-subscribe
                       and maintain the balance + GP.6.4 budget views.
    query <actor> <resource>
                       One-shot balance lookup.
    query-budget <actor>
                       GP.6.4: one-shot per-actor budget query (lifetime +
                       current-epoch grants + current-epoch consumed;
                       optionally `remaining_this_epoch` if --free-tier set).
    query-pool-eth <actor>
                       GP.6.4: per-pool-actor ETH (resource 0) balance.
    query-pool-bold <actor>
                       GP.6.4: per-pool-actor BOLD (resource 1) balance.

DAEMON OPTIONS:
    --storage <PATH>                       SQLite database path (required).
    --subscribe <ADDR>                     knomosis-event-subscribe endpoint
                                           (default: 127.0.0.1:7655).
    --max-frame-size <BYTES>               Max event payload size (default: 1 MiB).
    --reconnect-backoff-ms <MS>            Backoff between reconnects (default: 1000).
    --max-reconnects <N>                   Max reconnects before giving up
                                           (default: 1000; 0 = infinite).
    --verify-against-knomosis <URL>        Periodically verify balance view
                                           against knomosis-host (not yet wired).
    --verify-budget-against-knomosis <URL> GP.6.4: same, for the budget view (not
                                           yet wired).
    --gas-pool-actor <ID>                  GP.6.4: actor id whose pool view is
                                           DECREMENTED on Event.gasPoolClaim.
                                           Unset = gross-inflow semantics (no
                                           drain wiring).
    --epoch-length <N>                     GP.6.4: per-epoch table reset every N
                                           seqs.  0 (default) = epoch
                                           advancement disabled.

QUERY OPTIONS (balance / pool):
    --storage <PATH>                       SQLite database path (required).
    <actor>                                Actor id (decimal u64).
    <resource>                             (balance only) Resource id (decimal u64).

QUERY-BUDGET OPTIONS:
    --storage <PATH>                       SQLite database path (required).
    --free-tier <N>                        (Optional) free-tier from the
                                           deployment's BudgetPolicy; when
                                           supplied, the output includes
                                           `remaining_this_epoch`.
    <actor>                                Actor id (decimal u64).

GLOBAL OPTIONS:
    --help, -h                             Print this help text.
    --version, -V                          Print version and exit.

EXIT CODES:
    0   Clean exit.
    1   General failure (CLI parse error).
    2   Operator-actionable failure (DB open, connect, identifier mismatch).
    3   NotImplemented (e.g. --verify-against-knomosis with no knomosis-host endpoint).
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
        assert!(HELP_TEXT.starts_with("knomosis-indexer"));
    }

    /// Implicit daemon (no subcommand) requires --storage.
    #[test]
    fn implicit_daemon_requires_storage() {
        match parse_args(&args(&["knomosis-indexer"])) {
            Err(ConfigError::MissingFlag(f)) => assert_eq!(f, "storage"),
            other => panic!("expected MissingFlag, got {other:?}"),
        }
    }

    /// Explicit daemon subcommand with defaults.
    #[test]
    fn daemon_defaults() {
        let parsed = parse_args(&args(&[
            "knomosis-indexer",
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
                assert_eq!(cfg.verify_against_knomosis, None);
            }
            _ => panic!("expected Daemon variant"),
        }
    }

    /// All daemon flags parse.
    #[test]
    fn daemon_all_flags() {
        let parsed = parse_args(&args(&[
            "knomosis-indexer",
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
            "--verify-against-knomosis",
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
                    cfg.verify_against_knomosis.as_deref(),
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
            "knomosis-indexer",
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
        match parse_args(&args(&[
            "knomosis-indexer",
            "query",
            "--storage",
            "/tmp/i.db",
        ])) {
            Err(ConfigError::MissingArg(arg)) => assert_eq!(arg, "actor"),
            other => panic!("expected MissingArg, got {other:?}"),
        }
    }

    #[test]
    fn query_missing_resource() {
        match parse_args(&args(&[
            "knomosis-indexer",
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
            "knomosis-indexer",
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
            match parse_args(&args(&["knomosis-indexer", h])) {
                Err(ConfigError::HelpRequested) => {}
                other => panic!("expected HelpRequested for {h}, got {other:?}"),
            }
        }
    }

    /// Version request.
    #[test]
    fn version_requested() {
        for v in ["--version", "-V"] {
            match parse_args(&args(&["knomosis-indexer", v])) {
                Err(ConfigError::VersionRequested) => {}
                other => panic!("expected VersionRequested for {v}, got {other:?}"),
            }
        }
    }

    /// Unknown subcommand.
    #[test]
    fn unknown_subcommand() {
        match parse_args(&args(&["knomosis-indexer", "foo"])) {
            Err(ConfigError::Unknown(s)) => assert_eq!(s, "foo"),
            other => panic!("expected Unknown, got {other:?}"),
        }
    }

    /// Unknown flag.
    #[test]
    fn unknown_flag() {
        match parse_args(&args(&["knomosis-indexer", "daemon", "--bogus"])) {
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
            verify_against_knomosis: None,
            verify_budget_against_knomosis: None,
            gas_pool_actor: None,
            epoch_length: 0,
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

    /// GP.6.4: daemon parses new flags.
    #[test]
    fn daemon_gp_6_4_flags() {
        let parsed = parse_args(&args(&[
            "knomosis-indexer",
            "daemon",
            "--storage",
            "/tmp/i.db",
            "--gas-pool-actor",
            "1",
            "--epoch-length",
            "1000",
            "--verify-budget-against-knomosis",
            "http://localhost:7654",
        ]))
        .unwrap();
        match parsed {
            Subcommand::Daemon(cfg) => {
                assert_eq!(cfg.gas_pool_actor, Some(1));
                assert_eq!(cfg.epoch_length, 1000);
                assert_eq!(
                    cfg.verify_budget_against_knomosis.as_deref(),
                    Some("http://localhost:7654")
                );
            }
            _ => panic!("expected Daemon variant"),
        }
    }

    /// GP.6.4: daemon defaults — gas_pool_actor None,
    /// epoch_length 0, verify_budget None.
    #[test]
    fn daemon_gp_6_4_flag_defaults() {
        let parsed = parse_args(&args(&[
            "knomosis-indexer",
            "daemon",
            "--storage",
            "/tmp/i.db",
        ]))
        .unwrap();
        match parsed {
            Subcommand::Daemon(cfg) => {
                assert_eq!(cfg.gas_pool_actor, None);
                assert_eq!(cfg.epoch_length, 0);
                assert_eq!(cfg.verify_budget_against_knomosis, None);
            }
            _ => panic!("expected Daemon variant"),
        }
    }

    /// GP.6.4: `query-budget` subcommand parses.
    #[test]
    fn query_budget_parses() {
        let parsed = parse_args(&args(&[
            "knomosis-indexer",
            "query-budget",
            "--storage",
            "/tmp/i.db",
            "42",
        ]))
        .unwrap();
        match parsed {
            Subcommand::QueryBudget(cfg) => {
                assert_eq!(cfg.storage_path, PathBuf::from("/tmp/i.db"));
                assert_eq!(cfg.actor, 42);
                assert_eq!(cfg.free_tier, None);
            }
            _ => panic!("expected QueryBudget"),
        }
    }

    /// GP.6.4: `query-budget --free-tier <N>` parses.
    #[test]
    fn query_budget_with_free_tier_parses() {
        let parsed = parse_args(&args(&[
            "knomosis-indexer",
            "query-budget",
            "--storage",
            "/tmp/i.db",
            "--free-tier",
            "100",
            "42",
        ]))
        .unwrap();
        match parsed {
            Subcommand::QueryBudget(cfg) => {
                assert_eq!(cfg.actor, 42);
                assert_eq!(cfg.free_tier, Some(100));
            }
            _ => panic!("expected QueryBudget"),
        }
    }

    /// GP.6.4: `query-budget` missing actor.
    #[test]
    fn query_budget_missing_actor() {
        match parse_args(&args(&[
            "knomosis-indexer",
            "query-budget",
            "--storage",
            "/tmp/i.db",
        ])) {
            Err(ConfigError::MissingArg(arg)) => assert_eq!(arg, "actor"),
            other => panic!("expected MissingArg, got {other:?}"),
        }
    }

    /// GP.6.4: `query-pool-eth` subcommand parses.
    #[test]
    fn query_pool_eth_parses() {
        let parsed = parse_args(&args(&[
            "knomosis-indexer",
            "query-pool-eth",
            "--storage",
            "/tmp/i.db",
            "1",
        ]))
        .unwrap();
        match parsed {
            Subcommand::QueryPoolEth(cfg) => {
                assert_eq!(cfg.storage_path, PathBuf::from("/tmp/i.db"));
                assert_eq!(cfg.actor, 1);
            }
            _ => panic!("expected QueryPoolEth"),
        }
    }

    /// GP.6.4: `query-pool-bold` subcommand parses.
    #[test]
    fn query_pool_bold_parses() {
        let parsed = parse_args(&args(&[
            "knomosis-indexer",
            "query-pool-bold",
            "--storage",
            "/tmp/i.db",
            "1",
        ]))
        .unwrap();
        match parsed {
            Subcommand::QueryPoolBold(cfg) => {
                assert_eq!(cfg.actor, 1);
            }
            _ => panic!("expected QueryPoolBold"),
        }
    }

    /// GP.6.4: HELP_TEXT mentions all new subcommands + flags.
    #[test]
    fn help_text_lists_gp_6_4_surfaces() {
        assert!(HELP_TEXT.contains("query-budget"));
        assert!(HELP_TEXT.contains("query-pool-eth"));
        assert!(HELP_TEXT.contains("query-pool-bold"));
        assert!(HELP_TEXT.contains("--gas-pool-actor"));
        assert!(HELP_TEXT.contains("--epoch-length"));
        assert!(HELP_TEXT.contains("--free-tier"));
        assert!(HELP_TEXT.contains("--verify-budget-against-knomosis"));
    }
}
