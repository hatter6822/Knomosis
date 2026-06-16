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
//! configuration and — as their work units land — the read-only
//! indexer storage handle (G1.6b, via
//! `knomosis_storage::sqlite::SqliteStorage::open_read_only`) and the
//! auth token set (G1.4).
//!
//! Holding only `Send + Sync` data behind an `Arc` keeps the handler
//! path lock-free: every worker reads the same state with no
//! coordination.

use crate::config::Config;

/// Process-wide state shared (immutably) across all handler threads.
///
/// Construction is centralised in [`AppState::new`] so the (future)
/// fallible setup — opening the read-only indexer database, loading the
/// auth token file — has a single home that `main`/`serve` can surface
/// as a startup error.
#[derive(Debug)]
pub struct AppState {
    /// The validated gateway configuration.  Handlers read deployment
    /// parameters (the budget-policy echo, the gas-pool actor, …) from
    /// here as the endpoints that need them land.
    pub config: Config,
}

impl AppState {
    /// Build the shared state from the validated configuration.
    ///
    /// (G1.6b opens the read-only indexer database here and makes this
    /// fallible; the read endpoints and the auth token set attach to
    /// this struct as their work units land.)
    #[must_use]
    pub fn new(config: Config) -> Self {
        Self { config }
    }
}
