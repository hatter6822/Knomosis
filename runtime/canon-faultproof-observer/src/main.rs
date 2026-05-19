// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Binary entry-point for `canon-faultproof-observer`.
//!
//! Wires the CLI to the library's [`canon_faultproof_observer::observer::Observer`]:
//! parse CLI → initialise logging → load keystore → open
//! persistence → construct the L1 source → construct the
//! observer → run the loop until shutdown.
//!
//! Exit codes follow the
//! [`canon_cli_common::exit::OperatorExitCode`] discipline:
//!
//!   * 0 — clean shutdown (stop signal honoured).
//!   * 1 — general failure (libc default).
//!   * 2 — operator-actionable failure (config, deep re-org,
//!     crypto failure, invariant violation).
//!   * 69 — external service unavailable (L1 RPC permanently
//!     malformed).
//!   * 75 — transient failure (exhausted retries).

use std::process::ExitCode;

use canon_cli_common::exit::OperatorExitCode;
use canon_l1_ingest::key::BridgeActorKey;
use canon_l1_ingest::source::json_rpc::JsonRpcL1Source;
use tracing::{error, info};

use canon_faultproof_observer::config::{self, CliConfig, CliError};
use canon_faultproof_observer::error::ObserverError;
use canon_faultproof_observer::jsonrpc_submitter::{JsonRpcSubmitter, JsonRpcSubmitterConfig};
use canon_faultproof_observer::observer::{Observer, ObserverConfig};
use canon_faultproof_observer::persistence::Persistence;
use canon_faultproof_observer::strategy::{MemoryTruthOracle, SubprocessTruthOracle, TruthOracle};
use canon_faultproof_observer::submitter::mock::MockSubmitter;
use canon_faultproof_observer::watcher::WatcherConfig;

/// Convert an [`OperatorExitCode`] to the `u8` shape `ExitCode`
/// requires.  All defined exit codes fit in `u8` by construction
/// (the largest is 75), so the conversion is total.
fn exit_code_u8(code: OperatorExitCode) -> u8 {
    u8::try_from(code.as_i32()).unwrap_or(1)
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().collect();
    match CliConfig::parse_args(argv) {
        Ok(cfg) => match run(&cfg) {
            Ok(()) => ExitCode::from(exit_code_u8(OperatorExitCode::Success)),
            Err(e) => {
                error!(err = %e, "observer exited with error");
                ExitCode::from(exit_code_u8(e.exit_code()))
            }
        },
        Err(CliError::HelpRequested) => {
            config::print_help();
            ExitCode::from(exit_code_u8(OperatorExitCode::Success))
        }
        Err(CliError::VersionRequested) => {
            config::print_version();
            ExitCode::from(exit_code_u8(OperatorExitCode::Success))
        }
        Err(e) => {
            eprintln!("canon-faultproof-observer: CLI error: {e}");
            eprintln!("Run with --help for usage.");
            ExitCode::from(exit_code_u8(OperatorExitCode::OperatorAction))
        }
    }
}

/// Run the observer loop with the parsed CLI config.
///
/// # Errors
///
/// See [`ObserverError`].
#[allow(clippy::needless_pass_by_value)] // top-level CLI entry
fn run(cfg: &CliConfig) -> Result<(), ObserverError> {
    // Initialise logging.  `canon_cli_common::logging::init`
    // reads RUST_LOG if set; otherwise falls back to the
    // supplied default level.  We map `--log-level` to a
    // `tracing::Level` (info / debug / warn / error / trace).
    let default_level = parse_tracing_level(&cfg.log_level);
    canon_cli_common::logging::init(default_level)
        .map_err(|e| ObserverError::Config(format!("logging init: {e}")))?;

    info!(
        version = canon_faultproof_observer::VERSION,
        identifier = canon_faultproof_observer::OBSERVER_IDENTIFIER,
        protocol_version = canon_faultproof_observer::PROTOCOL_VERSION,
        "canon-faultproof-observer starting",
    );

    // Defence-in-depth: don't let the signing key leak via
    // tracing output by including it in any structured logs.
    // The Debug impl on BridgeActorKey redacts the private
    // bytes, but we still keep the binding behind `_`.
    // (Keystore is loaded per-submitter-path below.)

    // Open the persistence layer.
    let persistence = Persistence::open(&cfg.storage_path).map_err(|e| {
        ObserverError::Storage(canon_storage::storage::StorageError::Other(format!(
            "opening persistence at {:?}: {e}",
            cfg.storage_path
        )))
    })?;

    // Construct the L1 source.  Uses canon-l1-ingest's
    // hand-rolled HTTP JSON-RPC client (no async runtime).
    let source = JsonRpcL1Source::new(cfg.l1_rpc.clone())
        .map_err(|e| ObserverError::Config(format!("L1 RPC URL parse: {e}")))?;

    // Construct the watcher config from CLI.
    let watcher_cfg = WatcherConfig {
        game_contract: cfg.game_contract,
        state_root_submission_contract: cfg.state_root_contract,
        confirmation_depth: cfg.confirmation_depth,
        reorg_window_capacity: cfg.reorg_window as usize,
        blocks_per_iteration: cfg.blocks_per_iteration,
    };

    // Construct the observer config.
    let observer_cfg = ObserverConfig {
        watcher: watcher_cfg,
        poll_interval: cfg.poll_interval,
        play_as: cfg.play_as,
        deployment_id: cfg.deployment_id,
    };

    // Build the truth oracle.  When both `--canon-binary` and
    // `--canon-log` are supplied, the observer wires up the
    // production `SubprocessTruthOracle` that shells out to
    // `canon replay-up-to <log> <idx>` per bisection move.  The
    // canon binary's `--deployment-id <hex>` flag is supplied
    // automatically from `cfg.deployment_id` so cross-deployment-
    // replay defence is enforced uniformly.  When the flags are
    // omitted, the observer falls back to the empty
    // `MemoryTruthOracle` (cannot play moves; passive event-
    // watcher only).
    //
    // Audit-pass-4-round-6 fix: previously the `MemoryTruthOracle`
    // was hardcoded regardless of operator intent, making the
    // `SubprocessTruthOracle` dead code and the production
    // observer unable to play moves.
    //
    // Returns `Box<dyn TruthOracle>` so we have a single concrete
    // type to thread through the rest of the run() function — see
    // the `impl<T: TruthOracle + ?Sized> TruthOracle for Box<T>`
    // blanket impl in `strategy.rs`.
    let oracle: Box<dyn TruthOracle> = build_truth_oracle(cfg);

    // Build the submitter.  When `--chain-id` is supplied,
    // wire up the production `JsonRpcSubmitter` (signs +
    // broadcasts L1 transactions).  Otherwise default to the
    // in-memory `MockSubmitter` (records moves locally; does
    // NOT broadcast to L1).  Audit-pass-4-round-3: previously
    // MockSubmitter was hardcoded, making the production
    // submitter dead code.
    //
    // Clippy nudges to `if let Some / else`, but both branches
    // are 30+ lines and `match` keeps them visually parallel.
    #[allow(clippy::single_match_else)]
    match cfg.chain_id {
        Some(chain_id) => {
            // Production path: load the signing key, build the
            // JsonRpcSubmitter, cross-check chain_id with the
            // live RPC, then run.
            let signing_key = BridgeActorKey::from_file(&cfg.keystore_path).map_err(|e| {
                ObserverError::Crypto(format!("loading keystore at {:?}: {e}", cfg.keystore_path))
            })?;
            let submitter_cfg =
                JsonRpcSubmitterConfig::new(chain_id, cfg.game_contract.0, &signing_key)
                    .map_err(|e| ObserverError::Config(format!("JsonRpcSubmitterConfig: {e}")))?;
            // Build a second JsonRpcL1Source for the submitter
            // (it consumes its own — by-value).  The watcher's
            // source is owned by the observer.
            let submitter_rpc = JsonRpcL1Source::new(cfg.l1_rpc.clone())
                .map_err(|e| ObserverError::Config(format!("L1 RPC URL parse: {e}")))?;
            let submitter = JsonRpcSubmitter::new(signing_key, submitter_rpc, submitter_cfg);
            // Audit-pass-4-round-3 fix: cross-check chain_id at
            // startup.  Defends against operator misconfiguring
            // the wrong chain (e.g., Sepolia signed but mainnet
            // RPC) — would otherwise produce broadcast-reverted
            // txs but still leak signed bytes replayable on the
            // other chain.
            submitter
                .verify_rpc_chain_id()
                .map_err(|e| ObserverError::Config(format!("chain_id verification: {e}")))?;
            info!(
                chain_id = chain_id,
                "JSON-RPC submitter active; chain_id cross-check OK",
            );
            let mut observer = Observer::new(observer_cfg, source, submitter, oracle, persistence)?;
            if let Some(start) = cfg.start_block {
                observer.set_start_block(start);
                info!(
                    start_block = start,
                    "watcher cursor overridden via --start-block",
                );
            }
            observer.run()
        }
        None => {
            // Dev / observation path: mock submitter.  Records
            // moves locally; does NOT broadcast.
            //
            // Still validate the keystore (unreadable / corrupt
            // is a fail-fast condition regardless of submitter
            // mode).  Audit-pass-4-round-4: bind to `_` (true
            // wildcard, drops immediately) instead of
            // `_signing_key` (named binding that lives until
            // end of scope) so the private bytes don't sit in
            // memory for the whole observer.run() duration.
            let _ = BridgeActorKey::from_file(&cfg.keystore_path).map_err(|e| {
                ObserverError::Crypto(format!("loading keystore at {:?}: {e}", cfg.keystore_path))
            })?;
            info!(
                "running with MockSubmitter (no --chain-id supplied; moves \
                 are recorded but NOT broadcast to L1)"
            );
            let submitter = MockSubmitter::new();
            let mut observer = Observer::new(observer_cfg, source, submitter, oracle, persistence)?;
            if let Some(start) = cfg.start_block {
                observer.set_start_block(start);
                info!(
                    start_block = start,
                    "watcher cursor overridden via --start-block",
                );
            }
            observer.run()
        }
    }
}

/// Construct the production truth oracle from the parsed CLI
/// config.  Returns a [`Box<dyn TruthOracle>`] so the rest of
/// `run()` can stay generic-free.
///
/// When both `--canon-binary` and `--canon-log` are supplied,
/// returns a [`SubprocessTruthOracle`] pre-configured with the
/// canon binary path, the log path, and the deployment-id flag
/// (sourced from `cfg.deployment_id` so cross-deployment-replay
/// defence is enforced uniformly).
///
/// Otherwise returns an empty [`MemoryTruthOracle`] — the
/// observer detects this via [`HonestMoveError::TruthOracleMissed`]
/// at move time and logs a "deferring move" warning; no incorrect
/// moves are submitted.  This is the dev / read-only mode.
fn build_truth_oracle(cfg: &CliConfig) -> Box<dyn TruthOracle> {
    if let (Some(canon), Some(log_path)) = (&cfg.canon_binary, &cfg.canon_log_path) {
        // Format the deployment-id as 64-char lowercase hex via
        // the workspace's pre-audited `hex` crate (canon's
        // `--deployment-id` parser accepts hex with optional `0x`
        // prefix; we emit unprefixed).
        let deployment_id_hex = hex::encode(cfg.deployment_id);
        info!(
            canon_binary = %canon.display(),
            canon_log = %log_path.display(),
            "SubprocessTruthOracle active; observer can play bisection moves",
        );
        Box::new(
            SubprocessTruthOracle::new(canon.clone(), log_path.clone())
                .with_flag("--deployment-id", deployment_id_hex),
        )
    } else {
        info!(
            "running with empty MemoryTruthOracle (no --canon-binary supplied; \
             observer will defer moves — passive event-watcher mode)"
        );
        Box::new(MemoryTruthOracle::new())
    }
}

/// Map the `--log-level` string to a `tracing::Level`.  Unknown
/// values fall back to `Info` with a stderr warning.
fn parse_tracing_level(s: &str) -> tracing::Level {
    match s.to_ascii_lowercase().as_str() {
        "trace" => tracing::Level::TRACE,
        "debug" => tracing::Level::DEBUG,
        "info" => tracing::Level::INFO,
        "warn" => tracing::Level::WARN,
        "error" => tracing::Level::ERROR,
        other => {
            eprintln!(
                "canon-faultproof-observer: unknown --log-level '{other}'; defaulting to 'info'"
            );
            tracing::Level::INFO
        }
    }
}
