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

/// Environment variable mirroring `--free-tier`.
pub const FREE_TIER_ENV: &str = "KNX_GW_FREE_TIER";

/// Environment variable mirroring `--action-cost`.
pub const ACTION_COST_ENV: &str = "KNX_GW_ACTION_COST";

/// Environment variable mirroring `--gas-pool-actor`.
pub const GAS_POOL_ACTOR_ENV: &str = "KNX_GW_GAS_POOL_ACTOR";

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
    --free-tier <N>    Per-epoch free budget units echoed in the budget
                       view; MUST match the deployment policy
                       (env KNX_GW_FREE_TIER) [default: 0]
    --action-cost <N>  Per-action budget cost echoed in the budget view
                       (env KNX_GW_ACTION_COST) [default: 0]
    --gas-pool-actor <ID>
                       Gas-pool actor id (GP.6.4) whose pool view the
                       indexer drains; MUST match the indexer's
                       --gas-pool-actor.  A pool view for THIS id is
                       reported net of drains (net=true); any other id
                       is gross inflows (net=false)
                       (env KNX_GW_GAS_POOL_ACTOR) [default: unset]
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
    /// Per-epoch free budget units, echoed in the `BudgetView` and used
    /// in `remaining = freeTier + grants − consumed` (G1.7).  MUST match
    /// the deployment's budget policy (the gateway cannot self-check
    /// this — an operator obligation, §9.2).  Default `0`.
    pub free_tier: u128,
    /// Per-action budget cost, echoed in the `BudgetView` (G1.7).
    /// Default `0`.
    pub action_cost: u128,
    /// The gas-pool actor id whose pool view the indexer drains
    /// (GP.6.4); `Some(id)` makes `GET /v1/pools/{id}` report `net =
    /// true` (net of drains) and every other pool id `net = false`
    /// (gross inflows).  MUST match the indexer's `--gas-pool-actor`:
    /// the indexer does not persist this in the database, so the
    /// gateway cannot self-verify the match (an operator obligation,
    /// §9.2, exactly as for the budget echo).  `None` (the default)
    /// reports every pool view as `net = false`.
    pub gas_pool_actor: Option<u64>,
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
        let raw = RawArgs::scan(args)?;

        // Precedence (applied here): CLI flag > environment > default.
        let listen_str = raw
            .listen
            .or_else(|| std::env::var(LISTEN_ENV).ok())
            .unwrap_or_else(|| DEFAULT_LISTEN.to_string());
        let listen = listen_str
            .parse::<SocketAddr>()
            .map_err(|e| ConfigError::InvalidValue {
                flag: "--listen".to_string(),
                value: listen_str.clone(),
                reason: e.to_string(),
            })?;

        let handler_threads = resolve_handler_threads(raw.handler_threads)?;

        let indexer_db = raw
            .indexer_db
            .or_else(|| std::env::var(INDEXER_DB_ENV).ok())
            .map(PathBuf::from);

        let free_tier = parse_u128_flag("--free-tier", raw.free_tier, FREE_TIER_ENV)?;
        let action_cost = parse_u128_flag("--action-cost", raw.action_cost, ACTION_COST_ENV)?;
        let gas_pool_actor =
            parse_optional_u64_flag("--gas-pool-actor", raw.gas_pool_actor, GAS_POOL_ACTOR_ENV)?;

        Ok(Self {
            listen,
            handler_threads,
            indexer_db,
            free_tier,
            action_cost,
            gas_pool_actor,
        })
    }
}

/// The raw, unresolved CLI strings collected from argv, before the
/// environment fallback + type validation that [`Config::parse`]
/// applies.  Splitting the argv scan out of `parse` keeps each step a
/// single, reviewable concern (and each function within the linter's
/// length budget).
#[derive(Default)]
struct RawArgs {
    listen: Option<String>,
    handler_threads: Option<String>,
    indexer_db: Option<String>,
    free_tier: Option<String>,
    action_cost: Option<String>,
    gas_pool_actor: Option<String>,
}

impl RawArgs {
    /// Scan argv (`args[0]` is the program name; parsing starts at
    /// `args[1]`) into the raw option strings.  `-h`/`--help` and
    /// `-V`/`--version` short-circuit as their typed sentinels.
    fn scan(args: &[String]) -> Result<Self, ConfigError> {
        let mut raw = RawArgs::default();
        let mut i = 1;
        while let Some(arg) = args.get(i) {
            match arg.as_str() {
                "-h" | "--help" => return Err(ConfigError::HelpRequested),
                "-V" | "--version" => return Err(ConfigError::VersionRequested),
                "--listen" => raw.listen = Some(take_value(args, &mut i, "--listen")?),
                "--handler-threads" => {
                    raw.handler_threads = Some(take_value(args, &mut i, "--handler-threads")?);
                }
                "--indexer-db" => raw.indexer_db = Some(take_value(args, &mut i, "--indexer-db")?),
                "--free-tier" => raw.free_tier = Some(take_value(args, &mut i, "--free-tier")?),
                "--action-cost" => {
                    raw.action_cost = Some(take_value(args, &mut i, "--action-cost")?);
                }
                "--gas-pool-actor" => {
                    raw.gas_pool_actor = Some(take_value(args, &mut i, "--gas-pool-actor")?);
                }
                other => return Err(ConfigError::UnknownArgument(other.to_string())),
            }
            i += 1;
        }
        Ok(raw)
    }
}

/// Take the value argument that follows the flag at index `*i`,
/// advancing `*i` past it.  Returns [`ConfigError::MissingValue`] if the
/// flag is the last token.
fn take_value(args: &[String], i: &mut usize, flag: &str) -> Result<String, ConfigError> {
    let value = args.get(*i + 1).ok_or_else(|| ConfigError::MissingValue {
        flag: flag.to_string(),
    })?;
    *i += 1;
    Ok(value.clone())
}

/// Resolve `--handler-threads`: CLI value > env var > the compiled
/// default, validating the `1..=MAX_HANDLER_THREADS` range.
fn resolve_handler_threads(cli_raw: Option<String>) -> Result<usize, ConfigError> {
    match cli_raw.or_else(|| std::env::var(HANDLER_THREADS_ENV).ok()) {
        None => Ok(DEFAULT_HANDLER_THREADS),
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
            Ok(n)
        }
    }
}

/// Resolve a `u128` flag: CLI value > env var > `0`.  Returns a typed
/// [`ConfigError::InvalidValue`] on a non-numeric value.
fn parse_u128_flag(
    flag: &str,
    cli_raw: Option<String>,
    env_var: &str,
) -> Result<u128, ConfigError> {
    match cli_raw.or_else(|| std::env::var(env_var).ok()) {
        None => Ok(0),
        Some(raw) => raw.parse::<u128>().map_err(|e| ConfigError::InvalidValue {
            flag: flag.to_string(),
            value: raw,
            reason: e.to_string(),
        }),
    }
}

/// Resolve an OPTIONAL `u64` flag: CLI value > env var > `None`
/// (absent).  A present-but-non-numeric value is a hard
/// [`ConfigError::InvalidValue`] rather than a silent `None`, so a
/// fat-fingered id is never mistaken for "feature disabled".
fn parse_optional_u64_flag(
    flag: &str,
    cli_raw: Option<String>,
    env_var: &str,
) -> Result<Option<u64>, ConfigError> {
    match cli_raw.or_else(|| std::env::var(env_var).ok()) {
        None => Ok(None),
        Some(raw) => raw
            .parse::<u64>()
            .map(Some)
            .map_err(|e| ConfigError::InvalidValue {
                flag: flag.to_string(),
                value: raw,
                reason: e.to_string(),
            }),
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

    /// `--free-tier` / `--action-cost` default to 0 and parse as `u128`.
    #[test]
    fn budget_knobs_default_and_parse() {
        std::env::remove_var(super::FREE_TIER_ENV);
        std::env::remove_var(super::ACTION_COST_ENV);
        let cfg = Config::parse(&argv(&[])).unwrap();
        assert_eq!(cfg.free_tier, 0);
        assert_eq!(cfg.action_cost, 0);
        let cfg = Config::parse(&argv(&["--free-tier", "1000", "--action-cost", "5"])).unwrap();
        assert_eq!(cfg.free_tier, 1000);
        assert_eq!(cfg.action_cost, 5);
    }

    /// A non-numeric budget knob → `InvalidValue`.
    #[test]
    fn budget_knob_non_numeric_rejected() {
        assert!(matches!(
            Config::parse(&argv(&["--free-tier", "lots"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }

    /// `--gas-pool-actor` is optional (`None` by default) and parses to
    /// `Some(id)` when supplied.
    #[test]
    fn gas_pool_actor_optional_and_parsed() {
        std::env::remove_var(super::GAS_POOL_ACTOR_ENV);
        assert_eq!(Config::parse(&argv(&[])).unwrap().gas_pool_actor, None);
        let cfg = Config::parse(&argv(&["--gas-pool-actor", "161"])).unwrap();
        assert_eq!(cfg.gas_pool_actor, Some(161));
    }

    /// A present-but-non-numeric `--gas-pool-actor` is a hard error, not
    /// a silent disable.
    #[test]
    fn gas_pool_actor_non_numeric_rejected() {
        assert!(matches!(
            Config::parse(&argv(&["--gas-pool-actor", "pool"])),
            Err(ConfigError::InvalidValue { .. })
        ));
    }
}
