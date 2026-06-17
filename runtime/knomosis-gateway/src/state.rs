// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Shared application state for the gateway's request handlers.
//!
//! An `Arc<AppState>` is built once at startup ([`crate::http::serve`])
//! and shared **immutably** across every worker thread in the handler
//! pool.  It is the seam through which stateful handlers reach
//! configuration, the read-only indexer storage handle (G1.6b), and the
//! accepted bearer-token set (G1.4).
//!
//! Holding only `Send + Sync` data behind an `Arc` keeps the handler
//! path lock-free at the gateway level: every worker reads the same
//! state with no coordination.  (Concurrency *within* the read backend
//! is bounded by the storage layer's single connection mutex — a
//! connection-pool refactor is a future throughput optimisation,
//! OQ-GW-9.)

use std::sync::atomic::{AtomicBool, AtomicUsize};
use std::sync::Arc;

use knomosis_storage::sqlite::{ReadOnlyOpenOptions, SqliteStorage};

use crate::auth::Auth;
use crate::config::{Config, IDEMPOTENCY_MAX_ENTRIES};
use crate::events::fanout::FanoutState;
use crate::rate_limit::RateLimiter;
use crate::submit::idempotency::IdempotencyCache;
use crate::submit::pool::HostPool;

/// Errors building the shared application state at startup.
#[derive(Debug, thiserror::Error)]
pub enum StateError {
    /// The read-only indexer database (`--indexer-db`) could not be
    /// opened.
    #[error("failed to open the read-only indexer database at {path}: {reason}")]
    IndexerOpen {
        /// The configured database path.
        path: String,
        /// The storage-layer diagnostic.
        reason: String,
    },
    /// The bearer-token file (`--auth-token-file`) could not be loaded.
    #[error("failed to load the auth token file: {reason}")]
    AuthLoad {
        /// The auth-layer diagnostic (the path, never a token value).
        reason: String,
    },
}

/// The read-side backend: the read-only indexer storage handle that the
/// balance / budget / pool endpoints query (G1.6b+).
///
/// Opened ONCE at startup via `SqliteStorage::open_read_only` (the
/// G1.6a path — pure `SQLITE_OPEN_READ_ONLY`, so a gateway logic bug
/// *cannot* mutate the indexer's database).  Shared immutably across
/// handler threads; the storage layer's internal mutex serialises
/// concurrent reads.
#[derive(Debug)]
pub struct ReadState {
    /// The read-only handle on the indexer's SQLite database.
    pub storage: SqliteStorage,
}

/// Process-wide state shared (immutably) across all handler threads.
///
/// Construction is centralised in [`AppState::new`] so the fallible
/// setup — opening the read-only indexer database + loading the auth
/// token file — has a single home that `serve` / `main` surface as a
/// startup error rather than a per-request fault.
#[derive(Debug)]
pub struct AppState {
    /// The validated gateway configuration.  Handlers read deployment
    /// parameters (the budget-policy echo, the gas-pool actor, …) from
    /// here as the endpoints that need them land.
    pub config: Config,
    /// The read backend, present iff `--indexer-db` was configured.
    /// When `None`, the read endpoints answer `503` (reads disabled).
    pub reads: Option<ReadState>,
    /// The accepted bearer-token set (G1.4).  Empty when no
    /// `--auth-token-file` is configured — **fail-closed**: every
    /// non-exempt request is then denied.
    pub auth: Auth,
    /// The per-credential request-rate limiter (G1.3).  Disabled when
    /// `--rate-limit-rps` is `0`.
    pub rate_limiter: RateLimiter,
    /// The bounded host-connection pool for the submit path (G2.1b),
    /// present iff `--host-addr` was configured.  `None` makes
    /// `POST /v1/actions` answer `503` (submit disabled).
    pub host_pool: Option<HostPool>,
    /// The `Idempotency-Key` response cache (G2.4); disabled when
    /// `--idempotency-ttl-secs` is `0`.
    pub idempotency: IdempotencyCache,
    /// The shared SSE fan-out ring (G3.4), present iff
    /// `--event-subscribe-addr` was configured.  `serve` spawns the single
    /// upstream multiplexer ([`crate::events::fanout::mux::Mux`]) feeding
    /// it; the `GET /v1/events/stream` handlers read it.  `None` makes the
    /// stream endpoint answer `503` (events disabled).
    pub fanout: Option<Arc<FanoutState>>,
    /// The count of live SSE streams, bounded by `config.sse.max_streams`
    /// (an over-cap connect is `503`).  Each stream runs on its own thread
    /// and decrements this on exit (G3.5).
    pub active_streams: Arc<AtomicUsize>,
    /// The process-wide shutdown flag shared by the mux + every live SSE
    /// stream; setting it stops them (graceful drain is G4.4 — today it is
    /// only ever set on test teardown).
    pub shutdown: Arc<AtomicBool>,
}

impl AppState {
    /// Build the shared state from the validated configuration.
    ///
    /// If `config.indexer_db` is set, opens that database READ-ONLY
    /// (the G1.6a path); if `config.auth_token_file` is set, loads the
    /// bearer-token set (else fail-closed [`Auth::empty`]).  A failure in
    /// either is surfaced as a [`StateError`] so `serve` / `main` fail
    /// fast at startup rather than per-request.
    ///
    /// # Errors
    ///
    /// Returns [`StateError::IndexerOpen`] if the configured indexer
    /// database cannot be opened read-only, or [`StateError::AuthLoad`]
    /// if the configured token file cannot be read.
    pub fn new(config: Config) -> Result<Self, StateError> {
        let reads = match &config.indexer_db {
            None => None,
            Some(path) => {
                let storage = SqliteStorage::open_read_only(path, &ReadOnlyOpenOptions::new())
                    .map_err(|e| StateError::IndexerOpen {
                        path: path.display().to_string(),
                        reason: e.to_string(),
                    })?;
                Some(ReadState { storage })
            }
        };
        let auth = match &config.auth_token_file {
            None => Auth::empty(),
            Some(path) => Auth::load(path).map_err(|e| StateError::AuthLoad {
                reason: e.to_string(),
            })?,
        };
        let rate_limiter = RateLimiter::new(config.rate_limit_rps);
        // The submit pool exists iff a host upstream is configured.
        let host_pool = config.host_addr.map(|addr| {
            HostPool::new(
                addr,
                config.host_pool_size,
                config.host_max_inflight,
                std::time::Duration::from_millis(config.request_deadline_ms),
            )
        });
        let idempotency =
            IdempotencyCache::new(config.idempotency_ttl_secs, IDEMPOTENCY_MAX_ENTRIES);
        // The fan-out ring exists iff an event-subscribe upstream is
        // configured; `serve` spawns the mux that feeds it.
        let fanout = config
            .event_subscribe_addr
            .map(|_| FanoutState::new(config.sse.ring_capacity));
        Ok(Self {
            config,
            reads,
            auth,
            rate_limiter,
            host_pool,
            idempotency,
            fanout,
            active_streams: Arc::new(AtomicUsize::new(0)),
            shutdown: Arc::new(AtomicBool::new(false)),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{AppState, StateError};
    use crate::config::Config;

    fn config(indexer_db: Option<std::path::PathBuf>) -> Config {
        Config {
            listen: "127.0.0.1:0".parse().expect("loopback addr"),
            handler_threads: 1,
            indexer_db,
            free_tier: 0,
            action_cost: 0,
            epoch_length: 0,
            gas_pool_actor: None,
            deployment_id: String::new(),
            ok_admission_stage: crate::config::AdmissionStage::Finalized,
            host_addr: None,
            event_subscribe_addr: None,
            auth_token_file: None,
            rate_limit_rps: 0,
            host_pool_size: 8,
            host_max_inflight: 8,
            request_deadline_ms: 5000,
            max_frame_size: 1024 * 1024,
            idempotency_ttl_secs: 0,
            sse: crate::config::SseConfig::default(),
            tls: None,
        }
    }

    /// No `--indexer-db` → reads disabled (`reads` is `None`); the open
    /// succeeds.
    #[test]
    fn no_indexer_db_disables_reads() {
        let state = AppState::new(config(None)).expect("no DB to open");
        assert!(state.reads.is_none());
    }

    /// A non-existent `--indexer-db` path fails fast at startup (the
    /// read-only open never creates the file).
    #[test]
    fn nonexistent_indexer_db_fails_fast() {
        let result = AppState::new(config(Some("/nonexistent/knomosis/index.db".into())));
        assert!(matches!(result, Err(StateError::IndexerOpen { .. })));
    }
}
