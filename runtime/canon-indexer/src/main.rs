// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `canon-indexer` binary entry point.
//!
//! See `runtime/canon-indexer/src/lib.rs` for the library
//! architecture and `runtime/canon-indexer/src/config.rs` for the
//! CLI surface.
//!
//! ## Exit codes
//!
//!   * `0` — clean exit.
//!   * `1` — CLI parse error.
//!   * `2` — operator-actionable failure (DB open, subscribe
//!     connect, identifier mismatch).
//!   * `3` — NotImplemented (e.g. `--verify-against-canon` with
//!     no canon-host endpoint).
//!   * `75` — transient (subscribe server temporarily down beyond
//!     `--max-reconnects`).

use std::process::ExitCode;
use std::time::Duration;

use canon_cli_common::exit::OperatorExitCode;
use canon_cli_common::logging;
use canon_indexer::balance::BalanceView;
use canon_indexer::client::{ClientError, ServerFrame, SubscribeClient};
use canon_indexer::config::{
    parse_args, ConfigError, DaemonConfig, QueryConfig, Subcommand, HELP_TEXT,
};
use canon_indexer::decoder::decode_event;
use canon_indexer::indexer::Indexer;
use canon_indexer::{INDEXER_IDENTIFIER, VERSION};
use canon_storage::sqlite::SqliteStorage;
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
            eprintln!("canon-indexer: error parsing arguments: {e}");
            eprintln!("Run with --help for usage.");
            return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
        }
    };
    if let Err(e) = logging::init(Level::INFO) {
        eprintln!("canon-indexer: logging init failed: {e}");
        return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
    }
    let exit_code = match cmd {
        Subcommand::Daemon(cfg) => run_daemon(cfg),
        Subcommand::Query(cfg) => run_query(cfg),
    };
    ExitCode::from(exit_code.as_i32() as u8)
}

fn run_daemon(cfg: DaemonConfig) -> OperatorExitCode {
    tracing::info!(
        identifier = INDEXER_IDENTIFIER,
        version = VERSION,
        storage = %cfg.storage_path.display(),
        subscribe = %cfg.subscribe_endpoint,
        "canon-indexer daemon starting"
    );

    if cfg.verify_against_canon.is_some() {
        tracing::error!(
            "--verify-against-canon is set but the verification path is not yet implemented; \
             see docs/planning/rust_host_runtime_plan.md §RH-E.1"
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

    let mut indexer = match Indexer::open(&storage) {
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
            "connecting to canon-event-subscribe"
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
                tracing::error!(error = %e, "indexer error; surfacing operator action");
                return OperatorExitCode::OperatorAction;
            }
        }
        std::thread::sleep(Duration::from_millis(cfg.reconnect_backoff_ms));
    }
}

/// Outcome of consuming the server's event stream.
enum ConsumeOutcome {
    /// Server closed cleanly (no terminal frame).
    CleanEof,
    /// Server sent `ServerShutdown`.
    ServerShutdown { last_seq: u64 },
    /// Server sent `LagExceeded`.
    LagExceeded { last_seq: u64 },
    /// Server sent `Truncated` (data loss).
    Truncated { oldest_seq: u64 },
    /// Server sent `InvalidRequest` (handshake mismatch).
    InvalidRequest,
    /// Wire-level error.
    ClientError(ClientError),
    /// Indexer-level error (transaction commit / balance arithmetic).
    IndexerError(canon_indexer::indexer::IndexerError),
}

/// Consume the server's event stream, dispatching each event to
/// the indexer.  Returns when the connection drops or a terminal
/// frame arrives.
///
/// The function reads the first frame, then delegates to
/// [`consume_batched`] which implements the proper
/// multi-event-per-seq batching semantics from `docs/abi.md`
/// §11.4.
fn consume_stream(
    indexer: &mut Indexer<'_, SqliteStorage>,
    client: &mut SubscribeClient,
) -> ConsumeOutcome {
    // Read the first frame; if it's a terminal control frame,
    // return immediately.  If it's an Event, delegate to
    // `consume_batched` which keeps reading frames and grouping
    // by seq.
    let frame = match client.read_frame() {
        Ok(f) => f,
        Err(ClientError::Eof) => return ConsumeOutcome::CleanEof,
        Err(e) => return ConsumeOutcome::ClientError(e),
    };
    match frame {
        ServerFrame::Event { seq, payload } => consume_batched(indexer, client, seq, payload),
        ServerFrame::ServerShutdown { last_delivered_seq } => ConsumeOutcome::ServerShutdown {
            last_seq: last_delivered_seq,
        },
        ServerFrame::LagExceeded { last_delivered_seq } => ConsumeOutcome::LagExceeded {
            last_seq: last_delivered_seq,
        },
        ServerFrame::Truncated {
            oldest_available_seq,
        } => ConsumeOutcome::Truncated {
            oldest_seq: oldest_available_seq,
        },
        ServerFrame::InvalidRequest => ConsumeOutcome::InvalidRequest,
    }
}

/// Consume an event batch that begins with `(first_seq,
/// first_payload)`.  Reads ahead one frame at a time; on a
/// seq-change frame, dispatches the accumulated batch and
/// returns the new frame for the next iteration of the outer
/// loop.
///
/// This path implements the "multi-event-per-seq" semantics from
/// §11.4 (sequence-number invariants): multiple events that
/// share a seq are delivered as a contiguous sequence of frames
/// with identical seq numbers.
fn consume_batched(
    indexer: &mut Indexer<'_, SqliteStorage>,
    client: &mut SubscribeClient,
    first_seq: u64,
    first_payload: Vec<u8>,
) -> ConsumeOutcome {
    let mut current_seq = first_seq;
    let mut batch = match decode_event(&first_payload) {
        Ok(e) => vec![e],
        Err(e) => {
            return ConsumeOutcome::IndexerError(canon_indexer::indexer::IndexerError::Storage(
                canon_storage::storage::StorageError::Other(format!(
                    "decode failure at seq {current_seq}: {e}"
                )),
            ));
        }
    };
    loop {
        let frame = match client.read_frame() {
            Ok(f) => f,
            Err(ClientError::Eof) => {
                // Flush the in-flight batch, then return.
                if let Err(e) = indexer.apply_batch(current_seq, &batch) {
                    return ConsumeOutcome::IndexerError(e);
                }
                return ConsumeOutcome::CleanEof;
            }
            Err(e) => {
                return ConsumeOutcome::ClientError(e);
            }
        };
        match frame {
            ServerFrame::Event { seq, payload } => match seq.cmp(&current_seq) {
                std::cmp::Ordering::Equal => {
                    // Same batch — accumulate.
                    match decode_event(&payload) {
                        Ok(e) => batch.push(e),
                        Err(e) => {
                            return ConsumeOutcome::IndexerError(
                                canon_indexer::indexer::IndexerError::Storage(
                                    canon_storage::storage::StorageError::Other(format!(
                                        "decode failure at seq {seq}: {e}"
                                    )),
                                ),
                            );
                        }
                    }
                }
                std::cmp::Ordering::Greater => {
                    // Different seq — dispatch the current batch
                    // first, then start a new batch.
                    if let Err(e) = indexer.apply_batch(current_seq, &batch) {
                        return ConsumeOutcome::IndexerError(e);
                    }
                    current_seq = seq;
                    batch.clear();
                    match decode_event(&payload) {
                        Ok(e) => batch.push(e),
                        Err(e) => {
                            return ConsumeOutcome::IndexerError(
                                canon_indexer::indexer::IndexerError::Storage(
                                    canon_storage::storage::StorageError::Other(format!(
                                        "decode failure at seq {seq}: {e}"
                                    )),
                                ),
                            );
                        }
                    }
                }
                std::cmp::Ordering::Less => {
                    // seq < current_seq is a protocol violation.
                    tracing::error!(
                        current_seq,
                        offending_seq = seq,
                        "server delivered out-of-order event"
                    );
                    return ConsumeOutcome::IndexerError(
                        canon_indexer::indexer::IndexerError::Storage(
                            canon_storage::storage::StorageError::Other(format!(
                                "out-of-order seq: current {current_seq}, got {seq}"
                            )),
                        ),
                    );
                }
            },
            ServerFrame::ServerShutdown { last_delivered_seq } => {
                // Flush in-flight batch.
                if let Err(e) = indexer.apply_batch(current_seq, &batch) {
                    return ConsumeOutcome::IndexerError(e);
                }
                return ConsumeOutcome::ServerShutdown {
                    last_seq: last_delivered_seq,
                };
            }
            ServerFrame::LagExceeded { last_delivered_seq } => {
                if let Err(e) = indexer.apply_batch(current_seq, &batch) {
                    return ConsumeOutcome::IndexerError(e);
                }
                return ConsumeOutcome::LagExceeded {
                    last_seq: last_delivered_seq,
                };
            }
            ServerFrame::Truncated {
                oldest_available_seq,
            } => {
                return ConsumeOutcome::Truncated {
                    oldest_seq: oldest_available_seq,
                };
            }
            ServerFrame::InvalidRequest => return ConsumeOutcome::InvalidRequest,
        }
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
            // Output format: "<actor> <resource> <balance>\n"
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
