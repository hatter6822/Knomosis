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
//! configuration and the read-only indexer storage handle (G1.6b); the
//! auth token set (G1.4) attaches here next.
//!
//! Holding only `Send + Sync` data behind an `Arc` keeps the handler
//! path lock-free at the gateway level: every worker reads the same
//! state with no coordination.  (Concurrency *within* the read backend
//! is bounded by the storage layer's single connection mutex — a
//! connection-pool refactor is a future throughput optimisation,
//! OQ-GW-9.)

use knomosis_storage::sqlite::{ReadOnlyOpenOptions, SqliteStorage};

use crate::config::Config;

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
/// setup — opening the read-only indexer database (and, in G1.4,
/// loading the auth token file) — has a single home that `serve` /
/// `main` surface as a startup error rather than a per-request fault.
#[derive(Debug)]
pub struct AppState {
    /// The validated gateway configuration.  Handlers read deployment
    /// parameters (the budget-policy echo, the gas-pool actor, …) from
    /// here as the endpoints that need them land.
    pub config: Config,
    /// The read backend, present iff `--indexer-db` was configured.
    /// When `None`, the read endpoints answer `503` (reads disabled).
    pub reads: Option<ReadState>,
}

impl AppState {
    /// Build the shared state from the validated configuration.
    ///
    /// If `config.indexer_db` is set, opens that database READ-ONLY
    /// (the G1.6a path); a failure to open is surfaced as
    /// [`StateError::IndexerOpen`] so `serve` / `main` fail fast at
    /// startup rather than per-request.
    ///
    /// # Errors
    ///
    /// Returns [`StateError::IndexerOpen`] if the configured indexer
    /// database cannot be opened read-only.
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
        Ok(Self { config, reads })
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
