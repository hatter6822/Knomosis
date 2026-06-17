// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The plaintext HTTP listener on `--listen`.
//!
//! It uses the gateway's **own** thread-per-connection model (the same as the
//! TLS listener) over the transport-neutral [`crate::http::conn`] handler —
//! **not** `tiny_http`.  That gives each connection its own thread and a
//! socket-owned read/write timeout, which is precisely what closes the
//! plaintext SSE gaps `tiny_http`'s hijack API could not: the concurrent-SSE
//! ceiling (OQ-GW-14) and the stalled-reader write-deadline hole (OQ-GW-15).
//! Concurrency is bounded by `--max-connections` (the spawn-storm guard).

use std::io::BufReader;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::thread::JoinHandle;

use crate::config::Config;
use crate::http::conn::{self, DeadlineStream};
use crate::http::ServeError;
use crate::state::AppState;

/// Bind the plaintext `--listen` socket and start its accept loop on its own
/// thread.  Returns the **bound** address (resolving an ephemeral `:0` port)
/// and the accept thread's join handle (the caller joins it on drain after
/// setting `state.shutdown`).
///
/// This is the embedding entry point the benchmark + the integration tests use
/// to stand up a real gateway listener on an ephemeral port; production goes
/// through [`crate::http::serve`].
///
/// # Errors
///
/// [`ServeError::Bind`] if the socket cannot be bound, or [`ServeError::Spawn`]
/// if the accept thread cannot be spawned.
pub fn spawn_plain_listener(
    config: &Config,
    state: &Arc<AppState>,
) -> Result<(SocketAddr, JoinHandle<()>), ServeError> {
    let listener = TcpListener::bind(config.listen).map_err(|e| ServeError::Bind {
        addr: config.listen.to_string(),
        reason: e.to_string(),
    })?;
    listener
        .set_nonblocking(true)
        .map_err(|e| ServeError::Bind {
            addr: config.listen.to_string(),
            reason: e.to_string(),
        })?;
    let addr = listener.local_addr().map_err(|e| ServeError::Bind {
        addr: config.listen.to_string(),
        reason: e.to_string(),
    })?;
    let state = Arc::clone(state);
    let shutdown = Arc::clone(&state.shutdown);
    let gauge = Arc::clone(&state.active_connections);
    let max_connections = config.max_connections;
    std::thread::Builder::new()
        .name("knx-gw-accept".to_string())
        .spawn(move || {
            conn::accept_loop(
                &listener,
                &shutdown,
                max_connections,
                &gauge,
                || {}, // plaintext has no per-iteration hook (no cert reload)
                |stream, guard| {
                    let state = Arc::clone(&state);
                    let shutdown = Arc::clone(&shutdown);
                    let spawned = std::thread::Builder::new()
                        .name("knx-gw-conn".to_string())
                        .spawn(move || {
                            // The guard rides the connection thread; its `Drop`
                            // releases the slot on every exit path.
                            let _guard = guard;
                            handle_connection(stream, &state, &shutdown);
                        });
                    if spawned.is_err() {
                        // The closure (and the guard) is dropped, releasing the
                        // slot; the socket closes and the client reconnects.
                        tracing::error!("failed to spawn a connection thread");
                    }
                },
            );
            tracing::debug!("plaintext accept loop exiting (shutdown signalled)");
        })
        .map(|handle| (addr, handle))
        .map_err(|e| ServeError::Spawn {
            reason: e.to_string(),
        })
}

/// Arm the accepted socket and run the keep-alive request loop over it (wrapped
/// in the per-request read-deadline stream).  A cloned control handle on the
/// same socket is passed alongside so the SSE path can apply the
/// `--sse-write-timeout-ms` write deadline.  The socket closes when this
/// returns.
fn handle_connection(stream: TcpStream, state: &AppState, shutdown: &AtomicBool) {
    conn::arm_socket(&stream);
    // A second handle on the same socket, used only to tune the write timeout
    // for a live SSE stream; a clone failure simply leaves the default in force.
    let control = stream.try_clone().ok();
    let mut reader = BufReader::new(DeadlineStream::new(stream));
    conn::run_connection(&mut reader, control.as_ref(), state, shutdown);
}
