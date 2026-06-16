// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The `tiny_http` IO shell: bind, the bounded accept pool, and the
//! request→response glue — the *write* step of the parse → dispatch →
//! write pipeline.
//!
//! **G1.2d:** a bounded pool of `--handler-threads` worker threads,
//! each blocking on `tiny_http::Server::recv` — the gateway's
//! concurrency governor (it caps the number of requests processed in
//! parallel).  Each request is parsed ([`crate::http::route`]),
//! dispatched against the shared [`AppState`]
//! ([`crate::dispatch::dispatch`]), and written back.  The request-body
//! size limit lands with G2.2; per-connection read/idle timeouts are
//! constrained by `tiny_http`'s API (a documented G4.x follow-up); the
//! graceful-drain shutdown lands in G4.4.

use std::sync::Arc;
use std::thread::JoinHandle;

use crate::config::Config;
use crate::dispatch::dispatch;
use crate::http::router::{route, RouteOutcome};
use crate::state::AppState;

/// Errors from running the gateway HTTP server.
#[derive(Debug, thiserror::Error)]
pub enum ServeError {
    /// Binding the listen socket failed (address in use, permission
    /// denied, …).
    #[error("failed to bind HTTP listener on {addr}: {reason}")]
    Bind {
        /// The address that could not be bound.
        addr: String,
        /// The backend's diagnostic.
        reason: String,
    },
    /// A request-handler worker thread could not be spawned.
    #[error("failed to spawn a handler thread: {reason}")]
    Spawn {
        /// The OS thread-spawn diagnostic.
        reason: String,
    },
}

/// Run the gateway HTTP server, blocking the calling thread.
///
/// Builds the shared [`AppState`], binds the listener, then spawns a
/// bounded pool of `config.handler_threads` worker threads (the
/// concurrency governor — [`spawn_handler_pool`]) and blocks until a
/// worker exits.  Under normal operation the workers loop forever; this
/// only *returns* on a bind/spawn failure.  Graceful shutdown is G4.4.
///
/// # Errors
///
/// Returns [`ServeError::Bind`] if the listen socket cannot be bound,
/// or [`ServeError::Spawn`] if a worker thread cannot be spawned.
pub fn serve(config: &Config) -> Result<(), ServeError> {
    let server =
        Arc::new(
            tiny_http::Server::http(config.listen).map_err(|e| ServeError::Bind {
                addr: config.listen.to_string(),
                reason: e.to_string(),
            })?,
        );
    tracing::info!(
        identifier = crate::GATEWAY_IDENTIFIER,
        version = crate::VERSION,
        listen = %config.listen,
        handler_threads = config.handler_threads,
        "knomosis-gateway listening"
    );
    let state = Arc::new(AppState::new(config.clone()));
    let handles = spawn_handler_pool(&server, config.handler_threads, &state)?;
    // Block until a worker exits.  Under normal operation the workers
    // loop forever on `recv`; graceful shutdown is G4.4.
    for handle in handles {
        if handle.join().is_err() {
            tracing::error!("a gateway handler thread panicked");
        }
    }
    Ok(())
}

/// Spawn a bounded pool of `threads` request-handler workers, each
/// blocking on `tiny_http::Server::recv` and dispatching through
/// [`handle_request`] against the shared `state`.  This is the
/// gateway's concurrency governor: it caps the number of requests
/// processed in parallel.  Returns the workers' join handles.
///
/// `tiny_http`'s `Server` is `Send + Sync` and distributes incoming
/// requests across every thread that calls `recv`, so this is the
/// crate's documented multi-threaded serving pattern.
///
/// # Errors
///
/// Returns [`ServeError::Spawn`] if a worker thread cannot be spawned.
pub fn spawn_handler_pool(
    server: &Arc<tiny_http::Server>,
    threads: usize,
    state: &Arc<AppState>,
) -> Result<Vec<JoinHandle<()>>, ServeError> {
    let mut handles = Vec::with_capacity(threads);
    for worker_id in 0..threads {
        let server = Arc::clone(server);
        let state = Arc::clone(state);
        let handle = std::thread::Builder::new()
            .name(format!("knx-gw-handler-{worker_id}"))
            .spawn(move || worker_loop(&server, &state))
            .map_err(|e| ServeError::Spawn {
                reason: e.to_string(),
            })?;
        handles.push(handle);
    }
    Ok(handles)
}

/// One worker's loop: block on `recv`, dispatch, repeat.  Exits when
/// the listener errors (e.g. the `Server` has been dropped), which is
/// how the pool unwinds on shutdown.
fn worker_loop(server: &tiny_http::Server, state: &AppState) {
    loop {
        match server.recv() {
            Ok(request) => handle_request(request, state),
            Err(e) => {
                tracing::debug!(error = %e, "listener closed; handler thread exiting");
                break;
            }
        }
    }
}

/// Parse, dispatch, and write the response for one request.
///
/// **Panic-free by construction** (the §3.2 `panic = "abort"`
/// constraint): the method/path extraction uses only checked
/// operations, and a write failure — the client hung up before the
/// response was flushed — is logged at `debug` and dropped, since there
/// is nothing else to do.
pub fn handle_request(request: tiny_http::Request, state: &AppState) {
    let method = method_token(request.method());
    // Strip any query string; `split` always yields at least one item,
    // but `unwrap_or` keeps this provably panic-free regardless.
    let path = request.url().split('?').next().unwrap_or("");
    let routed = route(method, path);
    let outcome = dispatch(&routed, state);
    respond(request, &outcome);
}

/// Convert a [`RouteOutcome`] into a `tiny_http` response and write it.
/// Consumes the request (which owns the connection).
fn respond(request: tiny_http::Request, outcome: &RouteOutcome) {
    let mut response =
        tiny_http::Response::from_string(outcome.body.clone()).with_status_code(outcome.status);
    // `Header::from_bytes` only fails on a malformed name/value; our
    // content types are compile-time constants, so this never fails —
    // but we handle the `Err` without panicking regardless.
    if let Ok(header) =
        tiny_http::Header::from_bytes(b"Content-Type", outcome.content_type.as_bytes())
    {
        response = response.with_header(header);
    }
    // Response-specific headers (e.g. `Allow` on 405, `Retry-After` on
    // 429/503, `X-Knomosis-Seq` / `ETag` on reads).  A malformed
    // name/value is skipped rather than panicking; our names/values are
    // controlled, so this never drops a header in practice.
    for (name, value) in &outcome.headers {
        if let Ok(header) = tiny_http::Header::from_bytes(name.as_bytes(), value.as_bytes()) {
            response = response.with_header(header);
        }
    }
    if let Err(e) = request.respond(response) {
        tracing::debug!(error = %e, "client closed connection before the response was written");
    }
}

/// Map a `tiny_http::Method` to the canonical uppercase token the
/// router matches on.  Unknown / non-standard methods map to
/// `"OTHER"`, which the router answers as 405 + `Allow` on a known path
/// (or 404 on an unknown one).
fn method_token(method: &tiny_http::Method) -> &'static str {
    match method {
        tiny_http::Method::Get => "GET",
        tiny_http::Method::Head => "HEAD",
        tiny_http::Method::Post => "POST",
        tiny_http::Method::Put => "PUT",
        tiny_http::Method::Delete => "DELETE",
        tiny_http::Method::Options => "OPTIONS",
        tiny_http::Method::Patch => "PATCH",
        _ => "OTHER",
    }
}

#[cfg(test)]
mod tests {
    use super::method_token;

    #[test]
    fn method_token_maps_common_verbs() {
        assert_eq!(method_token(&tiny_http::Method::Get), "GET");
        assert_eq!(method_token(&tiny_http::Method::Post), "POST");
        assert_eq!(method_token(&tiny_http::Method::Delete), "DELETE");
        // A method outside the explicit arms maps to the catch-all
        // token (the router answers it as 405 + `Allow`).
        assert_eq!(method_token(&tiny_http::Method::Trace), "OTHER");
        assert_eq!(method_token(&tiny_http::Method::Connect), "OTHER");
    }
}
