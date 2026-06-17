// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The server orchestration shell: build the shared [`AppState`], start the
//! plaintext ([`crate::http::plain`]) + native-TLS ([`crate::http::tls`])
//! listeners + the SSE fan-out multiplexer, and run them under one graceful
//! shutdown.
//!
//! The gateway owns its **own** HTTP stack (the transport-neutral
//! [`crate::http::conn`] handler, **no** `tiny_http`): each listener runs one
//! thread per connection, bounded by its connection cap, with a socket-owned
//! read/write timeout + a per-request read deadline.
//!
//! **Graceful shutdown (G4.4):** `serve` registers a SIGTERM/SIGINT trigger,
//! then blocks until the shared shutdown flag is set (by a signal, or — in
//! tests — directly).  On shutdown it joins the listeners' accept threads (so
//! no new connection is accepted), then **drains** the in-flight connections
//! by waiting for [`AppState::active_connections`] to reach `0` under
//! [`DRAIN_DEADLINE`] (each connection thread + the mux + every live SSE stream
//! observe the same flag and stop cleanly — the streams emit a
//! `server_shutdown` close).

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::config::Config;
use crate::state::AppState;

/// How often `serve` polls the shutdown flag while awaiting a signal, and the
/// active-connection gauge while draining.
const SHUTDOWN_POLL: Duration = Duration::from_millis(100);

/// The overall deadline for draining in-flight connections on shutdown —
/// bounds how long a stuck connection can delay exit (§G4.4).  A connection
/// blocked reading an idle keep-alive request drains within its per-read
/// socket timeout (`conn::CONNECTION_TIMEOUT`).
const DRAIN_DEADLINE: Duration = Duration::from_secs(15);

/// Errors from running the gateway HTTP server.
#[derive(Debug, thiserror::Error)]
pub enum ServeError {
    /// Binding a listen socket failed (address in use, permission denied, …).
    #[error("failed to bind HTTP listener on {addr}: {reason}")]
    Bind {
        /// The address that could not be bound.
        addr: String,
        /// The OS diagnostic.
        reason: String,
    },
    /// A listener accept thread could not be spawned.
    #[error("failed to spawn a listener thread: {reason}")]
    Spawn {
        /// The OS thread-spawn diagnostic.
        reason: String,
    },
    /// Building the shared application state failed (e.g. the read-only
    /// indexer database could not be opened).
    #[error("failed to initialise gateway state: {reason}")]
    State {
        /// The state-layer diagnostic.
        reason: String,
    },
    /// The native-TLS listener (`--tls-listen`, G4.2) could not be stood up:
    /// a bad certificate / key / client-CA, a `rustls` config rejection, a
    /// bind failure, or a thread-spawn failure.  Fatal at startup so a
    /// misconfigured public TLS surface never serves.
    #[error("failed to start the TLS listener: {reason}")]
    Tls {
        /// The TLS-setup diagnostic.
        reason: String,
    },
}

/// Run the gateway HTTP server, blocking the calling thread.
///
/// Builds the shared [`AppState`], starts the SSE fan-out multiplexer (if
/// configured), the native-TLS listener (G4.2, if `--tls-listen` is set — fail-
/// fast on a bad cert/key/CA), and the plaintext `--listen` listener; registers
/// the SIGTERM/SIGINT shutdown trigger; then blocks until the shutdown flag is
/// set, joins the accept threads, and drains the in-flight connections under
/// [`DRAIN_DEADLINE`], returning `Ok(())` on a clean exit.
///
/// # Errors
///
/// [`ServeError::State`] if the shared state cannot be built, [`ServeError::Tls`]
/// if the native-TLS listener cannot be stood up, [`ServeError::Bind`] if the
/// plaintext socket cannot be bound, or [`ServeError::Spawn`] if a listener
/// thread cannot be spawned.
pub fn serve(config: &Config) -> Result<(), ServeError> {
    // `--dev`: stand up the in-process mock upstreams (§9.3) and rewrite the
    // config to point at them; the profile handle is held for the gateway's
    // whole lifetime — its `Drop` stops every mock server + removes the temp
    // directory after the drain below.
    let (config, _dev_profile) = if config.dev {
        let (rewritten, profile) =
            crate::dev::start(config.clone()).map_err(|e| ServeError::State {
                reason: e.to_string(),
            })?;
        (rewritten, Some(profile))
    } else {
        (config.clone(), None)
    };
    let config = &config;

    let state = AppState::new(config.clone()).map_err(|e| ServeError::State {
        reason: e.to_string(),
    })?;
    // Fail-closed auth is loud: warn the operator at startup if no tokens are
    // configured (the count, never a value, §8.1).
    if state.auth.token_count() == 0 {
        tracing::warn!(
            "no --auth-token-file configured: the bearer auth gate is fail-closed, so \
             every request except /healthz and /readyz will be rejected (401/403)"
        );
    } else {
        tracing::info!(
            auth_tokens = state.auth.token_count(),
            "bearer auth gate enabled"
        );
    }
    let state = Arc::new(state);
    // The SSE fan-out multiplexer(s) (G3.4b), iff an event-subscribe upstream
    // is configured.  `--upstream-subscriptions` shared live-tail subscriptions
    // feed the SINGLE ring; the ring dedups on `(seq, index)`, so `N > 1` is a
    // redundancy / availability knob that loses + duplicates no record.
    // Detached; each observes the shutdown flag.
    if let (Some(fanout), Some(addr)) = (&state.fanout, config.event_subscribe_addr) {
        for _ in 0..config.upstream_subscriptions {
            let mux = crate::events::fanout::mux::Mux::new(
                addr,
                config.max_frame_size,
                std::time::Duration::from_secs(config.sse.stale_secs),
                Arc::clone(fanout),
            );
            let _ = mux.spawn(Arc::clone(&state.shutdown));
        }
        tracing::info!(
            %addr,
            subscriptions = config.upstream_subscriptions,
            "SSE fan-out multiplexer(s) started"
        );
    }
    // The native HTTPS listener (G4.2), iff `--tls-listen` is set — built +
    // bound here so a bad cert/key/CA is fatal before the plaintext socket.
    let tls_handle =
        crate::http::tls::spawn_tls_listener(config, &state).map_err(|e| ServeError::Tls {
            reason: e.to_string(),
        })?;
    // The plaintext listener.
    let (addr, plain_handle) = crate::http::spawn_plain_listener(config, &state)?;
    tracing::info!(
        identifier = crate::GATEWAY_IDENTIFIER,
        version = crate::VERSION,
        listen = %addr,
        max_connections = config.max_connections,
        tls = config.tls.is_some(),
        "knomosis-gateway listening"
    );
    // Register the graceful-shutdown trigger.
    register_shutdown_signals(&state.shutdown);
    // Block until shutdown is signalled.
    while !state.shutdown.load(Ordering::Relaxed) {
        std::thread::sleep(SHUTDOWN_POLL);
    }
    tracing::info!("shutdown signalled; draining in-flight connections + SSE streams");
    // Stop accepting: the accept loops exit on the flag.
    let _ = plain_handle.join();
    if let Some(handle) = tls_handle {
        let _ = handle.join();
    }
    // Drain the in-flight connections: each observes the flag and exits
    // (bounded by its per-read socket timeout); wait for the gauge → 0.
    let drain_start = Instant::now();
    while state.active_connections.load(Ordering::SeqCst) > 0
        && drain_start.elapsed() < DRAIN_DEADLINE
    {
        std::thread::sleep(SHUTDOWN_POLL);
    }
    let remaining = state.active_connections.load(Ordering::SeqCst);
    if remaining == 0 {
        tracing::info!("gateway drained cleanly; exiting");
    } else {
        tracing::warn!(
            remaining,
            deadline_secs = DRAIN_DEADLINE.as_secs(),
            "drain deadline exceeded; exiting with connections still active"
        );
    }
    Ok(())
}

/// Register the SIGTERM / SIGINT graceful-shutdown trigger: each signal sets
/// the shared `shutdown` flag (a safe `signal_hook::flag::register` — the crate
/// forbids `unsafe`).  A registration failure is logged, not fatal: the gateway
/// still runs, just without signal-driven drain (a `SIGKILL` still stops it).
fn register_shutdown_signals(shutdown: &Arc<std::sync::atomic::AtomicBool>) {
    for signal in [signal_hook::consts::SIGTERM, signal_hook::consts::SIGINT] {
        if let Err(error) = signal_hook::flag::register(signal, Arc::clone(shutdown)) {
            tracing::warn!(signal, %error, "failed to register a shutdown signal handler");
        }
    }
}
