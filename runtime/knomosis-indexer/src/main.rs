// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-indexer` binary entry point.
//!
//! See `runtime/knomosis-indexer/src/lib.rs` for the library
//! architecture and `runtime/knomosis-indexer/src/config.rs` for the
//! CLI surface.  The event-consumption loop lives in
//! `runtime/knomosis-indexer/src/daemon.rs` (extracted into the
//! library so it can be unit-tested).
//!
//! ## Exit codes
//!
//!   * `0` — clean exit.
//!   * `1` — CLI parse error.
//!   * `2` — operator-actionable failure (DB open, subscribe
//!     connect, identifier mismatch).
//!   * `3` — NotImplemented (e.g. `--verify-against-knomosis` with
//!     no knomosis-host endpoint).
//!   * `75` — transient (subscribe server temporarily down beyond
//!     `--max-reconnects`).

use std::process::ExitCode;
use std::time::Duration;

use knomosis_cli_common::exit::OperatorExitCode;
use knomosis_cli_common::logging;
use knomosis_indexer::balance::BalanceView;
use knomosis_indexer::budget_view::BudgetReadView;
use knomosis_indexer::client::SubscribeClient;
use knomosis_indexer::config::{
    parse_args, ConfigError, DaemonConfig, QueryBudgetConfig, QueryConfig, QueryPoolConfig,
    Subcommand, HELP_TEXT,
};
use knomosis_indexer::daemon::{consume_stream, ConsumeOutcome};
use knomosis_indexer::indexer::Indexer;
use knomosis_indexer::{INDEXER_IDENTIFIER, VERSION};
use knomosis_storage::sqlite::SqliteStorage;
use tracing::Level;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let cmd = match parse_args(&args) {
        Ok(c) => c,
        Err(ConfigError::HelpRequested) => {
            print!("{HELP_TEXT}");
            return ExitCode::from(OperatorExitCode::Success.as_i32() as u8);
        }
        Err(ConfigError::VersionRequested) => {
            println!("{INDEXER_IDENTIFIER} (version {VERSION})");
            return ExitCode::from(OperatorExitCode::Success.as_i32() as u8);
        }
        Err(e) => {
            eprintln!("knomosis-indexer: error parsing arguments: {e}");
            eprintln!("Run with --help for usage.");
            return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
        }
    };
    if let Err(e) = logging::init(Level::INFO) {
        eprintln!("knomosis-indexer: logging init failed: {e}");
        return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
    }
    let exit_code = match cmd {
        Subcommand::Daemon(cfg) => run_daemon(cfg),
        Subcommand::Query(cfg) => run_query(cfg),
        Subcommand::QueryBudget(cfg) => run_query_budget(cfg),
        Subcommand::QueryPoolEth(cfg) => run_query_pool_eth(cfg),
        Subcommand::QueryPoolBold(cfg) => run_query_pool_bold(cfg),
    };
    ExitCode::from(exit_code.as_i32() as u8)
}

fn run_daemon(cfg: DaemonConfig) -> OperatorExitCode {
    tracing::info!(
        identifier = INDEXER_IDENTIFIER,
        version = VERSION,
        storage = %cfg.storage_path.display(),
        subscribe = %cfg.subscribe_endpoint,
        gas_pool_actor = ?cfg.gas_pool_actor,
        epoch_length = cfg.epoch_length,
        "knomosis-indexer daemon starting"
    );

    if cfg.verify_against_knomosis.is_some() {
        tracing::error!(
            "--verify-against-knomosis is set but the verification path is not yet implemented; \
             see docs/planning/rust_host_runtime_plan.md §RH-E.1"
        );
        return OperatorExitCode::NotImplemented;
    }

    if cfg.verify_budget_against_knomosis.is_some() {
        tracing::error!(
            "--verify-budget-against-knomosis is set but the budget-verification path is \
             not yet implemented; see docs/planning/unified_gas_pool_plan.md §GP.6.4"
        );
        return OperatorExitCode::NotImplemented;
    }

    let storage = match SqliteStorage::open(&cfg.storage_path) {
        Ok(s) => s,
        Err(e) => {
            tracing::error!(error = %e, "failed to open storage");
            return OperatorExitCode::OperatorAction;
        }
    };

    let mut indexer =
        match Indexer::open_with_config(&storage, cfg.gas_pool_actor, cfg.epoch_length) {
            Ok(i) => i,
            Err(e) => {
                tracing::error!(error = %e, "failed to open indexer");
                return OperatorExitCode::OperatorAction;
            }
        };

    let mut reconnects: u32 = 0;
    loop {
        if cfg.max_reconnects != 0 && reconnects >= cfg.max_reconnects {
            tracing::error!(
                attempts = reconnects,
                "exceeded --max-reconnects; surfacing transient failure"
            );
            return OperatorExitCode::Transient;
        }
        tracing::info!(
            cursor = indexer.cursor(),
            endpoint = %cfg.subscribe_endpoint,
            "connecting to knomosis-event-subscribe"
        );
        let mut client = match SubscribeClient::connect(
            &cfg.subscribe_endpoint,
            indexer.cursor(),
            cfg.max_frame_size,
        ) {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!(error = %e, "connect failed; sleeping before retry");
                std::thread::sleep(Duration::from_millis(cfg.reconnect_backoff_ms));
                reconnects = reconnects.saturating_add(1);
                continue;
            }
        };
        reconnects = 0; // reset on successful connect
        match consume_stream(&mut indexer, &mut client) {
            ConsumeOutcome::CleanEof => {
                tracing::info!("server closed connection cleanly; reconnecting");
            }
            ConsumeOutcome::ServerShutdown { last_seq } => {
                tracing::info!(
                    last_seq,
                    "server reported shutdown; sleeping then reconnecting"
                );
            }
            ConsumeOutcome::LagExceeded { last_seq } => {
                tracing::warn!(
                    last_seq,
                    "server evicted us for lag; reconnecting to resume from cursor"
                );
            }
            ConsumeOutcome::Truncated { oldest_seq } => {
                tracing::error!(
                    oldest_seq,
                    cursor = indexer.cursor(),
                    "subscribe server's keep-history is shorter than our gap; data loss"
                );
                return OperatorExitCode::OperatorAction;
            }
            ConsumeOutcome::InvalidRequest => {
                tracing::error!("server rejected our handshake — protocol mismatch");
                return OperatorExitCode::OperatorAction;
            }
            ConsumeOutcome::ClientError(e) => {
                tracing::warn!(error = %e, "client error; sleeping then retry");
                reconnects = reconnects.saturating_add(1);
            }
            ConsumeOutcome::IndexerError(e) => {
                // Distinguish recoverable from terminal indexer errors:
                //   * `CommitAmbiguous` → commit succeeded but report
                //     was ambiguous; the in-memory cursor has been
                //     resynced from disk.  Safe to retry: the next
                //     subscribe will resume from the corrected cursor.
                //     Log at WARN so operators see it without halting.
                //   * `Poisoned` and `CursorRecoveryFailed` → unsafe to
                //     continue; halt and require operator action.
                //   * All other indexer errors (decode, balance,
                //     protocol violation, etc.) → halt with operator
                //     action.
                match &e {
                    knomosis_indexer::indexer::IndexerError::CommitAmbiguous {
                        seq,
                        disk_cursor,
                    } => {
                        tracing::warn!(
                            seq,
                            disk_cursor,
                            "commit ambiguous; cursor resynced from disk, continuing"
                        );
                        // Treat like CleanEof: re-subscribe with the
                        // (now-correct) cursor and continue.
                    }
                    _ => {
                        tracing::error!(error = %e, "indexer error; surfacing operator action");
                        return OperatorExitCode::OperatorAction;
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(cfg.reconnect_backoff_ms));
    }
}

fn run_query(cfg: QueryConfig) -> OperatorExitCode {
    let storage = match SqliteStorage::open(&cfg.storage_path) {
        Ok(s) => s,
        Err(e) => {
            tracing::error!(error = %e, "failed to open storage");
            return OperatorExitCode::OperatorAction;
        }
    };
    let view = BalanceView::new(&storage);
    match view.get(cfg.actor, cfg.resource) {
        Ok(balance) => {
            println!("{} {} {}", cfg.actor, cfg.resource, balance);
            OperatorExitCode::Success
        }
        Err(e) => {
            tracing::error!(
                actor = cfg.actor,
                resource = cfg.resource,
                error = %e,
                "balance lookup failed"
            );
            OperatorExitCode::OperatorAction
        }
    }
}

/// GP.6.4: `query-budget <actor>` — prints lifetime cumulative
/// grants, current-epoch grants, current-epoch consumed, and (if
/// `--free-tier <N>` supplied) `remaining_this_epoch = free_tier
/// + current_epoch_grants - current_epoch_consumed`.
///
/// Output format (space-separated):
///   ```text
///   <actor> lifetime=<N> grants_this_epoch=<N> consumed_this_epoch=<N>
///   [remaining_this_epoch=<N>]
///   ```
fn run_query_budget(cfg: QueryBudgetConfig) -> OperatorExitCode {
    let storage = match SqliteStorage::open(&cfg.storage_path) {
        Ok(s) => s,
        Err(e) => {
            tracing::error!(error = %e, "failed to open storage");
            return OperatorExitCode::OperatorAction;
        }
    };
    let view = BudgetReadView::new(&storage);
    let lifetime = match view.get_actor_budget(cfg.actor) {
        Ok(v) => v,
        Err(e) => {
            tracing::error!(actor = cfg.actor, error = %e, "lifetime budget lookup failed");
            return OperatorExitCode::OperatorAction;
        }
    };
    let grants = match view.get_actor_budget_current_epoch_grants(cfg.actor) {
        Ok(v) => v,
        Err(e) => {
            tracing::error!(
                actor = cfg.actor,
                error = %e,
                "current-epoch grants lookup failed"
            );
            return OperatorExitCode::OperatorAction;
        }
    };
    let consumed = match view.get_actor_budget_current_epoch_consumed(cfg.actor) {
        Ok(v) => v,
        Err(e) => {
            tracing::error!(
                actor = cfg.actor,
                error = %e,
                "current-epoch consumed lookup failed"
            );
            return OperatorExitCode::OperatorAction;
        }
    };
    let line = if let Some(free_tier) = cfg.free_tier {
        let remaining = match view.remaining_this_epoch(cfg.actor, free_tier) {
            Ok(v) => v,
            Err(e) => {
                tracing::error!(
                    actor = cfg.actor,
                    error = %e,
                    "remaining_this_epoch computation failed"
                );
                return OperatorExitCode::OperatorAction;
            }
        };
        format!(
            "{} lifetime={lifetime} grants_this_epoch={grants} consumed_this_epoch={consumed} remaining_this_epoch={remaining}",
            cfg.actor
        )
    } else {
        format!(
            "{} lifetime={lifetime} grants_this_epoch={grants} consumed_this_epoch={consumed}",
            cfg.actor
        )
    };
    println!("{line}");
    OperatorExitCode::Success
}

/// GP.6.4: `query-pool-eth <actor>` — prints the per-pool-actor
/// ETH balance (resource 0).
///
/// Output format: `<actor> pool_eth=<N>`
fn run_query_pool_eth(cfg: QueryPoolConfig) -> OperatorExitCode {
    let storage = match SqliteStorage::open(&cfg.storage_path) {
        Ok(s) => s,
        Err(e) => {
            tracing::error!(error = %e, "failed to open storage");
            return OperatorExitCode::OperatorAction;
        }
    };
    let view = BudgetReadView::new(&storage);
    match view.get_pool_eth(cfg.actor) {
        Ok(v) => {
            println!("{} pool_eth={v}", cfg.actor);
            OperatorExitCode::Success
        }
        Err(e) => {
            tracing::error!(actor = cfg.actor, error = %e, "pool-ETH lookup failed");
            OperatorExitCode::OperatorAction
        }
    }
}

/// GP.6.4: `query-pool-bold <actor>` — prints the per-pool-actor
/// BOLD balance (resource 1).
///
/// Output format: `<actor> pool_bold=<N>`
fn run_query_pool_bold(cfg: QueryPoolConfig) -> OperatorExitCode {
    let storage = match SqliteStorage::open(&cfg.storage_path) {
        Ok(s) => s,
        Err(e) => {
            tracing::error!(error = %e, "failed to open storage");
            return OperatorExitCode::OperatorAction;
        }
    };
    let view = BudgetReadView::new(&storage);
    match view.get_pool_bold(cfg.actor) {
        Ok(v) => {
            println!("{} pool_bold={v}", cfg.actor);
            OperatorExitCode::Success
        }
        Err(e) => {
            tracing::error!(actor = cfg.actor, error = %e, "pool-BOLD lookup failed");
            OperatorExitCode::OperatorAction
        }
    }
}
