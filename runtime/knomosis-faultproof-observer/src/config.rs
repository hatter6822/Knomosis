// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! CLI argument parsing for the `knomosis-faultproof-observer`
//! binary.
//!
//! ## Flag matrix
//!
//! | Flag                       | Default | Description                          |
//! |----------------------------|---------|--------------------------------------|
//! | `--help`                   |         | Print help text and exit             |
//! | `--version`                |         | Print version + identifier and exit  |
//! | `--l1-rpc <URL>`           |         | (required) L1 JSON-RPC endpoint URL  |
//! | `--game-contract <ADDR>`   |         | (required) Fault-proof game contract |
//! | `--state-root-contract <A>`|         | (required) State-root submission     |
//! | `--storage <PATH>`         |         | (required) knomosis-storage DB path     |
//! | `--keystore <PATH>`        |         | (required) Observer's signing key    |
//! | `--deployment-id <HEX>`    |         | (required) 32-byte deployment-id     |
//! | `--play-as <SIDE>`         | challenger | `challenger` or `sequencer`       |
//! | `--confirmation-depth <N>` | 12      | L1 confirmation depth                |
//! | `--reorg-window <N>`       | 16      | Re-org-window capacity               |
//! | `--blocks-per-iter <N>`    | 64      | Per-iteration block budget           |
//! | `--poll-interval-ms <N>`   | 12000   | Polling interval between iterations  |
//! | `--start-block <N>`        |         | (optional) Override watcher cursor   |
//! | `--chain-id <N>`           |         | (optional) L1 chain id (enables `JsonRpcSubmitter`) |
//! | `--knomosis-binary <PATH>`    |         | (optional) Path to `knomosis` for replay-up-to |
//! | `--knomosis-log <PATH>`       |         | (optional) Knomosis log file (paired with `--knomosis-binary`) |
//! | `--log-level <LEVEL>`      | info    | tracing-subscriber filter directive  |
//!
//! ## Validation
//!
//! Beyond per-flag parse errors, the validate step enforces
//! cross-flag invariants:
//!
//!   * `reorg-window >= confirmation-depth`.
//!   * `confirmation-depth > 0`.
//!   * `blocks-per-iter > 0`.
//!   * `poll-interval-ms > 0`.
//!   * `deployment-id` is exactly 32 bytes (hex-encoded as 64
//!     chars, optional `0x` prefix).
//!   * `game-contract` and `state-root-contract` are exactly 20
//!     bytes each.
//!   * `--knomosis-binary` and `--knomosis-log` must be supplied
//!     together (both Some) or both omitted (both None).

use std::path::PathBuf;
use std::time::Duration;

use knomosis_l1_ingest::action::EthAddress;

use crate::game::TurnSide;

/// Default poll interval in milliseconds.
pub const DEFAULT_POLL_INTERVAL_MS: u64 = 12_000;

/// Default confirmation depth.
pub const DEFAULT_CONFIRMATION_DEPTH: u32 = 12;

/// Default re-org window capacity.
pub const DEFAULT_REORG_WINDOW: u32 = 16;

/// Default blocks-per-iteration budget.
pub const DEFAULT_BLOCKS_PER_ITER: u32 = 64;

/// Default log-level filter (matches `RUST_LOG` conventions).
pub const DEFAULT_LOG_LEVEL: &str = "info";

/// Parsed CLI configuration.
#[derive(Clone, Debug)]
#[allow(clippy::module_name_repetitions)]
pub struct CliConfig {
    /// L1 JSON-RPC URL (`http://host:port`).
    pub l1_rpc: String,
    /// Fault-proof game contract address.
    pub game_contract: EthAddress,
    /// State-root-submission contract address.
    pub state_root_contract: EthAddress,
    /// Path to the knomosis-storage `SQLite` DB.
    pub storage_path: PathBuf,
    /// Path to the keystore file (32-byte raw secp256k1 scalar).
    pub keystore_path: PathBuf,
    /// 32-byte deployment-id.
    pub deployment_id: [u8; 32],
    /// Which side this observer plays.
    pub play_as: TurnSide,
    /// L1 confirmation depth.
    pub confirmation_depth: u32,
    /// Re-org-window capacity.
    pub reorg_window: u32,
    /// Per-iteration block budget.
    pub blocks_per_iteration: u32,
    /// Polling interval between iterations.
    pub poll_interval: Duration,
    /// Optional override for the watcher's starting block.  When
    /// `Some(n)`, the watcher's `last_confirmed_block` is set to
    /// `n` BEFORE the first iteration, overriding any persisted
    /// cursor.
    pub start_block: Option<u64>,
    /// Optional L1 `chain_id`.  When `Some(n)`, the observer
    /// wires up the production `JsonRpcSubmitter` (signs +
    /// broadcasts L1 transactions).  When `None`, the observer
    /// uses the in-memory `MockSubmitter` (records moves
    /// locally; does NOT broadcast to L1).  Audit-pass-4-round-3
    /// fix: previously the mock was always used regardless of
    /// operator intent, making the `JsonRpcSubmitter` dead code.
    pub chain_id: Option<u64>,
    /// Optional path to the `knomosis` binary.  When `Some(p)` AND
    /// `knomosis_log_path` is also `Some(_)`, the observer wires up
    /// the production [`crate::strategy::SubprocessTruthOracle`]
    /// — shells out to `knomosis replay-up-to <log> <idx>` to
    /// compute the canonical state commit at each log index.
    /// When `None`, the observer falls back to the empty
    /// [`crate::strategy::MemoryTruthOracle`] (cannot play moves;
    /// passive event-watcher only).  Audit-pass-4-round-6 fix:
    /// previously the memory oracle was always used regardless
    /// of operator intent, making the `SubprocessTruthOracle`
    /// dead code and the observer unable to play moves in
    /// production.
    pub knomosis_binary: Option<PathBuf>,
    /// Path to the knomosis log file consumed by `replay-up-to`.
    /// Required when `knomosis_binary` is `Some(_)`, ignored
    /// otherwise.
    pub knomosis_log_path: Option<PathBuf>,
    /// tracing-subscriber filter directive.
    pub log_level: String,
}

/// CLI parsing errors.
#[derive(Debug, thiserror::Error)]
pub enum CliError {
    /// A required flag was missing.
    #[error("missing required flag: --{0}")]
    MissingFlag(String),
    /// A flag's value was malformed.
    #[error("invalid value for --{flag}: {reason}")]
    InvalidValue {
        /// The flag name.
        flag: String,
        /// What was wrong with the value.
        reason: String,
    },
    /// An unknown flag was encountered.
    #[error("unknown flag: {0}")]
    UnknownFlag(String),
    /// The user requested help.
    #[error("help requested")]
    HelpRequested,
    /// The user requested version info.
    #[error("version requested")]
    VersionRequested,
    /// A cross-flag invariant was violated.
    #[error("invalid configuration: {0}")]
    InvalidConfiguration(String),
}

impl CliConfig {
    /// Parse command-line arguments.  The first argument
    /// (program name) is skipped automatically.
    ///
    /// # Errors
    ///
    /// Returns [`CliError`] for parse failures, including
    /// `HelpRequested` / `VersionRequested` so the caller can
    /// exit with code 0.
    #[allow(clippy::too_many_lines)]
    pub fn parse_args<I, S>(args: I) -> Result<Self, CliError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut args = args.into_iter().map(Into::into);
        // Skip program name.
        let _ = args.next();
        let args_vec: Vec<String> = args.collect();

        let mut l1_rpc: Option<String> = None;
        let mut game_contract: Option<EthAddress> = None;
        let mut state_root_contract: Option<EthAddress> = None;
        let mut storage_path: Option<PathBuf> = None;
        let mut keystore_path: Option<PathBuf> = None;
        let mut deployment_id: Option<[u8; 32]> = None;
        let mut play_as: TurnSide = TurnSide::Challenger;
        let mut confirmation_depth: u32 = DEFAULT_CONFIRMATION_DEPTH;
        let mut reorg_window: u32 = DEFAULT_REORG_WINDOW;
        let mut blocks_per_iteration: u32 = DEFAULT_BLOCKS_PER_ITER;
        let mut poll_interval_ms: u64 = DEFAULT_POLL_INTERVAL_MS;
        let mut start_block: Option<u64> = None;
        let mut chain_id: Option<u64> = None;
        let mut knomosis_binary: Option<PathBuf> = None;
        let mut knomosis_log_path: Option<PathBuf> = None;
        let mut log_level: String = DEFAULT_LOG_LEVEL.to_string();

        let mut i = 0;
        while i < args_vec.len() {
            let flag = &args_vec[i];
            match flag.as_str() {
                "--help" | "-h" => return Err(CliError::HelpRequested),
                "--version" | "-V" => return Err(CliError::VersionRequested),
                "--l1-rpc" => l1_rpc = Some(read_value(&args_vec, &mut i, "l1-rpc")?),
                "--game-contract" => {
                    let v = read_value(&args_vec, &mut i, "game-contract")?;
                    game_contract = Some(parse_address(&v, "game-contract")?);
                }
                "--state-root-contract" => {
                    let v = read_value(&args_vec, &mut i, "state-root-contract")?;
                    state_root_contract = Some(parse_address(&v, "state-root-contract")?);
                }
                "--storage" => {
                    storage_path = Some(PathBuf::from(read_value(&args_vec, &mut i, "storage")?));
                }
                "--keystore" => {
                    keystore_path = Some(PathBuf::from(read_value(&args_vec, &mut i, "keystore")?));
                }
                "--deployment-id" => {
                    let v = read_value(&args_vec, &mut i, "deployment-id")?;
                    deployment_id = Some(parse_32_byte_hex(&v, "deployment-id")?);
                }
                "--play-as" => {
                    let v = read_value(&args_vec, &mut i, "play-as")?;
                    play_as = parse_turn_side(&v)?;
                }
                "--confirmation-depth" => {
                    let v = read_value(&args_vec, &mut i, "confirmation-depth")?;
                    confirmation_depth = parse_u32(&v, "confirmation-depth")?;
                }
                "--reorg-window" => {
                    let v = read_value(&args_vec, &mut i, "reorg-window")?;
                    reorg_window = parse_u32(&v, "reorg-window")?;
                }
                "--blocks-per-iter" => {
                    let v = read_value(&args_vec, &mut i, "blocks-per-iter")?;
                    blocks_per_iteration = parse_u32(&v, "blocks-per-iter")?;
                }
                "--poll-interval-ms" => {
                    let v = read_value(&args_vec, &mut i, "poll-interval-ms")?;
                    poll_interval_ms = parse_u64(&v, "poll-interval-ms")?;
                }
                "--start-block" => {
                    let v = read_value(&args_vec, &mut i, "start-block")?;
                    start_block = Some(parse_u64(&v, "start-block")?);
                }
                "--chain-id" => {
                    let v = read_value(&args_vec, &mut i, "chain-id")?;
                    let parsed = parse_u64(&v, "chain-id")?;
                    if parsed == 0 {
                        return Err(CliError::InvalidConfiguration(
                            "chain-id must be non-zero (EIP-155 reserves 0)".to_string(),
                        ));
                    }
                    chain_id = Some(parsed);
                }
                "--knomosis-binary" => {
                    knomosis_binary = Some(PathBuf::from(read_value(
                        &args_vec,
                        &mut i,
                        "knomosis-binary",
                    )?));
                }
                "--knomosis-log" => {
                    knomosis_log_path = Some(PathBuf::from(read_value(
                        &args_vec,
                        &mut i,
                        "knomosis-log",
                    )?));
                }
                "--log-level" => {
                    log_level = read_value(&args_vec, &mut i, "log-level")?;
                }
                other => return Err(CliError::UnknownFlag(other.to_string())),
            }
            i += 1;
        }

        let cfg = Self {
            l1_rpc: l1_rpc.ok_or_else(|| CliError::MissingFlag("l1-rpc".to_string()))?,
            game_contract: game_contract
                .ok_or_else(|| CliError::MissingFlag("game-contract".to_string()))?,
            state_root_contract: state_root_contract
                .ok_or_else(|| CliError::MissingFlag("state-root-contract".to_string()))?,
            storage_path: storage_path
                .ok_or_else(|| CliError::MissingFlag("storage".to_string()))?,
            keystore_path: keystore_path
                .ok_or_else(|| CliError::MissingFlag("keystore".to_string()))?,
            deployment_id: deployment_id
                .ok_or_else(|| CliError::MissingFlag("deployment-id".to_string()))?,
            play_as,
            confirmation_depth,
            reorg_window,
            blocks_per_iteration,
            poll_interval: Duration::from_millis(poll_interval_ms),
            start_block,
            chain_id,
            knomosis_binary,
            knomosis_log_path,
            log_level,
        };
        cfg.validate()?;
        Ok(cfg)
    }

    /// Validate cross-flag invariants.  Called by
    /// [`Self::parse_args`] after individual flag parsing.
    ///
    /// # Errors
    ///
    /// Returns [`CliError::InvalidConfiguration`] for invariant
    /// violations.
    pub fn validate(&self) -> Result<(), CliError> {
        if self.confirmation_depth == 0 {
            return Err(CliError::InvalidConfiguration(
                "confirmation-depth must be > 0".into(),
            ));
        }
        if self.confirmation_depth > crate::watcher::MAX_CONFIRMATION_DEPTH {
            return Err(CliError::InvalidConfiguration(format!(
                "confirmation-depth ({}) exceeds hard upper bound ({})",
                self.confirmation_depth,
                crate::watcher::MAX_CONFIRMATION_DEPTH,
            )));
        }
        if self.reorg_window == 0 {
            return Err(CliError::InvalidConfiguration(
                "reorg-window must be > 0".into(),
            ));
        }
        // `reorg_window` is `u32` (per the CLI flag) but the
        // watcher's underlying capacity is `usize`.  Cast and
        // bound against MAX_REORG_WINDOW_CAPACITY for parity.
        if (self.reorg_window as usize) > crate::watcher::MAX_REORG_WINDOW_CAPACITY {
            return Err(CliError::InvalidConfiguration(format!(
                "reorg-window ({}) exceeds hard upper bound ({})",
                self.reorg_window,
                crate::watcher::MAX_REORG_WINDOW_CAPACITY,
            )));
        }
        if self.blocks_per_iteration == 0 {
            return Err(CliError::InvalidConfiguration(
                "blocks-per-iter must be > 0".into(),
            ));
        }
        if self.blocks_per_iteration > crate::watcher::MAX_BLOCKS_PER_ITERATION {
            return Err(CliError::InvalidConfiguration(format!(
                "blocks-per-iter ({}) exceeds hard upper bound ({})",
                self.blocks_per_iteration,
                crate::watcher::MAX_BLOCKS_PER_ITERATION,
            )));
        }
        if self.poll_interval.as_millis() == 0 {
            return Err(CliError::InvalidConfiguration(
                "poll-interval-ms must be > 0".into(),
            ));
        }
        if self.reorg_window < self.confirmation_depth {
            return Err(CliError::InvalidConfiguration(format!(
                "reorg-window ({}) must be >= confirmation-depth ({})",
                self.reorg_window, self.confirmation_depth
            )));
        }
        // `--knomosis-binary` and `--knomosis-log` must be supplied
        // together (both Some) or both omitted (both None).  A
        // half-configured oracle (just one of them) is an
        // operator misconfiguration that we surface immediately
        // rather than silently falling back to the memory oracle.
        match (&self.knomosis_binary, &self.knomosis_log_path) {
            (Some(_), Some(_)) | (None, None) => {}
            (Some(_), None) => {
                return Err(CliError::InvalidConfiguration(
                    "--knomosis-binary requires --knomosis-log to be set".into(),
                ));
            }
            (None, Some(_)) => {
                return Err(CliError::InvalidConfiguration(
                    "--knomosis-log requires --knomosis-binary to be set".into(),
                ));
            }
        }
        Ok(())
    }
}

/// Read the value of a `--<flag>` argument.  Advances `i` so the
/// caller's `i += 1` after the match consumes the next arg.
fn read_value(args: &[String], i: &mut usize, flag: &str) -> Result<String, CliError> {
    *i += 1;
    args.get(*i).cloned().ok_or_else(|| CliError::InvalidValue {
        flag: flag.to_string(),
        reason: "missing value".to_string(),
    })
}

/// Parse a hex-encoded 20-byte Ethereum address.  `0x` prefix
/// is optional.
fn parse_address(s: &str, flag: &str) -> Result<EthAddress, CliError> {
    let trimmed = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(trimmed).map_err(|e| CliError::InvalidValue {
        flag: flag.to_string(),
        reason: format!("invalid hex: {e}"),
    })?;
    EthAddress::from_bytes(&bytes).ok_or_else(|| CliError::InvalidValue {
        flag: flag.to_string(),
        reason: format!("expected 20 bytes, got {}", bytes.len()),
    })
}

/// Parse a hex-encoded 32-byte hash.  `0x` prefix is optional.
fn parse_32_byte_hex(s: &str, flag: &str) -> Result<[u8; 32], CliError> {
    let trimmed = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(trimmed).map_err(|e| CliError::InvalidValue {
        flag: flag.to_string(),
        reason: format!("invalid hex: {e}"),
    })?;
    if bytes.len() != 32 {
        return Err(CliError::InvalidValue {
            flag: flag.to_string(),
            reason: format!("expected 32 bytes, got {}", bytes.len()),
        });
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

/// Parse a `TurnSide` from a string.  Case-insensitive.
fn parse_turn_side(s: &str) -> Result<TurnSide, CliError> {
    match s.to_ascii_lowercase().as_str() {
        "challenger" => Ok(TurnSide::Challenger),
        "sequencer" => Ok(TurnSide::Sequencer),
        other => Err(CliError::InvalidValue {
            flag: "play-as".to_string(),
            reason: format!("expected 'challenger' or 'sequencer', got '{other}'"),
        }),
    }
}

/// Parse a `u32` from a string.
fn parse_u32(s: &str, flag: &str) -> Result<u32, CliError> {
    s.parse::<u32>().map_err(|e| CliError::InvalidValue {
        flag: flag.to_string(),
        reason: format!("invalid u32: {e}"),
    })
}

/// Parse a `u64` from a string.
fn parse_u64(s: &str, flag: &str) -> Result<u64, CliError> {
    s.parse::<u64>().map_err(|e| CliError::InvalidValue {
        flag: flag.to_string(),
        reason: format!("invalid u64: {e}"),
    })
}

/// Print the CLI help text to stdout.
pub fn print_help() {
    println!(
        r"knomosis-faultproof-observer — RH-G off-chain fault-proof game observer.

USAGE:
    knomosis-faultproof-observer [OPTIONS] --l1-rpc <URL> \
        --game-contract <ADDR> --state-root-contract <ADDR> \
        --storage <PATH> --keystore <PATH> --deployment-id <HEX>

REQUIRED FLAGS:
    --l1-rpc <URL>              L1 JSON-RPC endpoint (http://host:port)
    --game-contract <ADDR>      Bisection-game contract (20-byte hex)
    --state-root-contract <A>   State-root-submission contract (20-byte hex)
    --storage <PATH>            knomosis-storage SQLite database path
    --keystore <PATH>           Observer's secp256k1 signing key file
                                (raw 32-byte scalar; see knomosis-l1-ingest
                                for the production keystore format)
    --deployment-id <HEX>       32-byte deployment-id (hex, 64 chars,
                                optional 0x prefix)

OPTIONS:
    --play-as <SIDE>            'challenger' or 'sequencer' (default: challenger)
    --confirmation-depth <N>    L1 confirmation depth (default: 12)
    --reorg-window <N>          Re-org-window capacity (default: 16)
    --blocks-per-iter <N>       Per-iteration block budget (default: 64)
    --poll-interval-ms <N>      Polling interval in ms (default: 12000)
    --start-block <N>           Override watcher cursor at startup
                                (advanced operator-only escape hatch;
                                bypasses the persisted-cursor recovery —
                                use only when resuming from a known
                                historic block on a fresh deployment)
    --chain-id <N>              L1 chain id.  When supplied, enables the
                                production JSON-RPC submitter (signs +
                                broadcasts L1 transactions; verifies the
                                chain_id against the live RPC at startup).
                                When omitted, uses the in-memory mock
                                submitter (records moves locally; does
                                NOT broadcast to L1).
    --knomosis-binary <PATH>       Path to the `knomosis` executable.  When
                                supplied with --knomosis-log, the observer
                                wires up the production SubprocessTruthOracle
                                (shells out to `knomosis replay-up-to` per
                                bisection move).  When omitted, the
                                observer uses the empty MemoryTruthOracle
                                (cannot play moves; passive event-watcher
                                only — logs FaultProofGameOpened etc.
                                but never bisects or settles).
    --knomosis-log <PATH>          Path to the knomosis log file consumed by
                                `knomosis replay-up-to`.  Required when
                                --knomosis-binary is supplied.
    --log-level <LEVEL>         tracing filter (default: info)
    -h, --help                  Print this help text
    -V, --version               Print version and exit
"
    );
}

/// Print the version + identifier to stdout.
pub fn print_version() {
    println!(
        "knomosis-faultproof-observer v{} ({})",
        env!("CARGO_PKG_VERSION"),
        crate::persistence::OBSERVER_IDENTIFIER,
    );
}

#[cfg(test)]
mod tests {
    use super::{
        parse_32_byte_hex, parse_address, parse_turn_side, parse_u32, parse_u64, CliConfig,
        CliError,
    };
    use crate::game::TurnSide;
    use std::path::PathBuf;

    fn args(s: &[&str]) -> Vec<String> {
        std::iter::once("knomosis-faultproof-observer".to_string())
            .chain(s.iter().map(|x| (*x).to_string()))
            .collect()
    }

    /// `--help` returns `HelpRequested`.
    #[test]
    fn help_short_and_long() {
        let err = CliConfig::parse_args(args(&["--help"])).unwrap_err();
        assert!(matches!(err, CliError::HelpRequested));
        let err = CliConfig::parse_args(args(&["-h"])).unwrap_err();
        assert!(matches!(err, CliError::HelpRequested));
    }

    /// `--version` returns `VersionRequested`.
    #[test]
    fn version_short_and_long() {
        let err = CliConfig::parse_args(args(&["--version"])).unwrap_err();
        assert!(matches!(err, CliError::VersionRequested));
        let err = CliConfig::parse_args(args(&["-V"])).unwrap_err();
        assert!(matches!(err, CliError::VersionRequested));
    }

    /// `parse_address` happy path.
    #[test]
    fn parse_address_happy() {
        let addr = parse_address("0x0102030405060708091011121314151617181920", "test").unwrap();
        assert_eq!(addr.0[0], 0x01);
        assert_eq!(addr.0[19], 0x20);
    }

    /// `parse_address` rejects wrong length.
    #[test]
    fn parse_address_wrong_length() {
        let err = parse_address("0x0102", "test").unwrap_err();
        assert!(matches!(err, CliError::InvalidValue { .. }));
    }

    /// `parse_address` rejects invalid hex.
    #[test]
    fn parse_address_invalid_hex() {
        let err = parse_address("zz", "test").unwrap_err();
        assert!(matches!(err, CliError::InvalidValue { .. }));
    }

    /// `parse_address` accepts no-`0x` prefix.
    #[test]
    fn parse_address_no_0x_prefix() {
        let addr = parse_address("0102030405060708091011121314151617181920", "test").unwrap();
        assert_eq!(addr.0[0], 0x01);
    }

    /// `parse_32_byte_hex` happy path.
    #[test]
    fn parse_32_byte_hex_happy() {
        let h = parse_32_byte_hex(&format!("0x{}", "ab".repeat(32)), "test").unwrap();
        assert_eq!(h, [0xab; 32]);
    }

    /// `parse_32_byte_hex` rejects wrong length.
    #[test]
    fn parse_32_byte_hex_wrong_length() {
        let err = parse_32_byte_hex("0xab", "test").unwrap_err();
        assert!(matches!(err, CliError::InvalidValue { .. }));
    }

    /// `parse_turn_side` happy path.
    #[test]
    fn parse_turn_side_happy() {
        assert_eq!(parse_turn_side("challenger").unwrap(), TurnSide::Challenger);
        assert_eq!(parse_turn_side("Challenger").unwrap(), TurnSide::Challenger);
        assert_eq!(parse_turn_side("CHALLENGER").unwrap(), TurnSide::Challenger);
        assert_eq!(parse_turn_side("sequencer").unwrap(), TurnSide::Sequencer);
    }

    /// `parse_turn_side` rejects unknown.
    #[test]
    fn parse_turn_side_rejects_unknown() {
        let err = parse_turn_side("nobody").unwrap_err();
        assert!(matches!(err, CliError::InvalidValue { .. }));
    }

    /// `parse_u32` / `parse_u64` happy path.
    #[test]
    fn parse_integers_happy() {
        assert_eq!(parse_u32("42", "test").unwrap(), 42);
        assert_eq!(parse_u64("123456789", "test").unwrap(), 123_456_789);
    }

    /// Integer parsing rejects negatives.
    #[test]
    fn parse_integers_reject_negatives() {
        assert!(parse_u32("-1", "test").is_err());
        assert!(parse_u64("-1", "test").is_err());
    }

    /// Full parse happy path.
    #[test]
    fn full_parse_happy() {
        let cfg = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
        ]))
        .unwrap();
        assert_eq!(cfg.l1_rpc, "http://localhost:8545");
        assert_eq!(cfg.play_as, TurnSide::Challenger);
        assert_eq!(cfg.confirmation_depth, 12);
        assert_eq!(cfg.reorg_window, 16);
    }

    /// Missing required flag → typed error.
    #[test]
    fn missing_required_flag() {
        let err = CliConfig::parse_args(args(&[
            // No --l1-rpc
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
        ]))
        .unwrap_err();
        assert!(matches!(err, CliError::MissingFlag(s) if s == "l1-rpc"));
    }

    /// Unknown flag → typed error.
    #[test]
    fn unknown_flag() {
        let err = CliConfig::parse_args(args(&["--what-is-this"])).unwrap_err();
        assert!(matches!(err, CliError::UnknownFlag(_)));
    }

    /// Missing value after a flag → typed error.
    #[test]
    fn missing_value_after_flag() {
        let err = CliConfig::parse_args(args(&["--l1-rpc"])).unwrap_err();
        assert!(matches!(err, CliError::InvalidValue { .. }));
    }

    /// Cross-flag validation rejects bad combos.
    #[test]
    fn cross_flag_validation_rejects_inconsistent() {
        let err = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
            "--confirmation-depth",
            "20",
            "--reorg-window",
            "10",
        ]))
        .unwrap_err();
        assert!(matches!(err, CliError::InvalidConfiguration(_)));
    }

    /// Custom options override defaults.
    #[test]
    fn custom_options_override_defaults() {
        let cfg = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
            "--play-as",
            "sequencer",
            "--confirmation-depth",
            "20",
            "--reorg-window",
            "30",
            "--blocks-per-iter",
            "128",
            "--poll-interval-ms",
            "5000",
            "--start-block",
            "12345",
            "--log-level",
            "debug",
        ]))
        .unwrap();
        assert_eq!(cfg.play_as, TurnSide::Sequencer);
        assert_eq!(cfg.confirmation_depth, 20);
        assert_eq!(cfg.reorg_window, 30);
        assert_eq!(cfg.blocks_per_iteration, 128);
        assert_eq!(cfg.poll_interval.as_millis(), 5000);
        assert_eq!(cfg.start_block, Some(12345));
        assert_eq!(cfg.log_level, "debug");
    }

    /// Zero confirmation depth → invalid.
    #[test]
    fn zero_confirmation_depth_rejected() {
        let err = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
            "--confirmation-depth",
            "0",
        ]))
        .unwrap_err();
        assert!(matches!(err, CliError::InvalidConfiguration(_)));
    }

    /// Audit-pass-4-round-4 MEDIUM regression: pin `--chain-id`
    /// flag parsing across the four cases (valid, zero, hex,
    /// omitted).
    #[test]
    fn chain_id_parses_decimal_value() {
        let cfg = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
            "--chain-id",
            "1",
        ]))
        .unwrap();
        assert_eq!(cfg.chain_id, Some(1));
    }

    #[test]
    fn chain_id_omitted_defaults_to_none() {
        let cfg = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
        ]))
        .unwrap();
        assert_eq!(cfg.chain_id, None);
    }

    #[test]
    fn chain_id_zero_rejected_per_eip155() {
        let err = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
            "--chain-id",
            "0",
        ]))
        .unwrap_err();
        assert!(
            matches!(err, CliError::InvalidConfiguration(_)),
            "expected InvalidConfiguration for chain-id=0, got: {err:?}",
        );
    }

    #[test]
    fn chain_id_hex_rejected_decimal_only_parser() {
        // `parse_u64` is decimal-only; --chain-id 0x1 should
        // fail at the parse stage.
        let err = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
            "--chain-id",
            "0x1",
        ]))
        .unwrap_err();
        assert!(
            matches!(err, CliError::InvalidValue { .. }),
            "expected InvalidValue for hex chain-id, got: {err:?}",
        );
    }

    /// Audit-pass-4-round-6 production-wiring fix: pin the new
    /// `--knomosis-binary` + `--knomosis-log` CLI flags' happy path.
    #[test]
    fn knomosis_binary_and_log_parse_together() {
        let cfg = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
            "--knomosis-binary",
            "/usr/local/bin/knomosis",
            "--knomosis-log",
            "/var/lib/knomosis/knomosis.log",
        ]))
        .unwrap();
        assert_eq!(
            cfg.knomosis_binary,
            Some(PathBuf::from("/usr/local/bin/knomosis"))
        );
        assert_eq!(
            cfg.knomosis_log_path,
            Some(PathBuf::from("/var/lib/knomosis/knomosis.log"))
        );
    }

    #[test]
    fn knomosis_binary_and_log_omitted_defaults_to_none() {
        let cfg = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
        ]))
        .unwrap();
        assert_eq!(cfg.knomosis_binary, None);
        assert_eq!(cfg.knomosis_log_path, None);
    }

    #[test]
    fn knomosis_binary_without_log_rejected() {
        let err = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
            "--knomosis-binary",
            "/usr/local/bin/knomosis",
        ]))
        .unwrap_err();
        assert!(
            matches!(err, CliError::InvalidConfiguration(ref msg)
                if msg.contains("--knomosis-binary requires --knomosis-log")),
            "expected InvalidConfiguration about missing --knomosis-log, got: {err:?}",
        );
    }

    #[test]
    fn knomosis_log_without_binary_rejected() {
        let err = CliConfig::parse_args(args(&[
            "--l1-rpc",
            "http://localhost:8545",
            "--game-contract",
            "0x0102030405060708091011121314151617181920",
            "--state-root-contract",
            "0xa102030405060708091011121314151617181920",
            "--storage",
            "/tmp/test.db",
            "--keystore",
            "/tmp/key",
            "--deployment-id",
            &format!("0x{}", "ab".repeat(32)),
            "--knomosis-log",
            "/var/lib/knomosis/knomosis.log",
        ]))
        .unwrap_err();
        assert!(
            matches!(err, CliError::InvalidConfiguration(ref msg)
                if msg.contains("--knomosis-log requires --knomosis-binary")),
            "expected InvalidConfiguration about missing --knomosis-binary, got: {err:?}",
        );
    }
}
