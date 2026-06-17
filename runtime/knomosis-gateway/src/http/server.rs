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
//! ([`crate::dispatch::dispatch`]), and written back.  Per-connection
//! read/idle timeouts are constrained by `tiny_http`'s API (a documented
//! G4.x follow-up).  **Graceful shutdown (G4.4):** `serve` registers a
//! SIGTERM/SIGINT trigger, then blocks until the shared shutdown flag is
//! set (by a signal, or — in tests — directly) and drains the handler pool
//! under a deadline; the mux + live SSE streams observe the same flag and
//! stop cleanly (the streams emit a `server_shutdown` close).

use std::io::Read;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use crate::config::Config;
use crate::http::handler::{self, log_request, route_request, Handled, RequestParts};
use crate::http::router::{Route, RouteOutcome};
use crate::problem::Problem;
use crate::state::AppState;

/// How often `serve` polls the shutdown flag while awaiting a signal.
const SHUTDOWN_POLL: Duration = Duration::from_millis(200);

/// The overall deadline for draining handler workers on shutdown — bounds
/// how long a stuck in-flight request can delay exit (§G4.4).
const DRAIN_DEADLINE: Duration = Duration::from_secs(10);

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
/// Builds the shared [`AppState`], binds the listener, spawns the SSE
/// fan-out multiplexer (if configured) and a bounded pool of
/// `config.handler_threads` worker threads (the concurrency governor —
/// [`spawn_handler_pool`]), registers the SIGTERM/SIGINT shutdown trigger,
/// then blocks until the shutdown flag is set and drains the pool under
/// [`DRAIN_DEADLINE`] (G4.4), returning `Ok(())` on a clean exit.
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
    let state = AppState::new(config.clone()).map_err(|e| ServeError::State {
        reason: e.to_string(),
    })?;
    // Fail-closed auth is loud: if no tokens are configured every
    // non-exempt request is rejected, so warn the operator at startup
    // (the token count, never a token value, §8.1).
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
    // Start the single SSE fan-out multiplexer (G3.4b) iff an
    // event-subscribe upstream is configured: one shared live-tail
    // subscription feeds the ring every `/v1/events/stream` client reads.
    // The thread is detached; it observes the shared shutdown flag and
    // stops on drain (G4.4).
    if let (Some(fanout), Some(addr)) = (&state.fanout, config.event_subscribe_addr) {
        let mux = crate::events::fanout::mux::Mux::new(
            addr,
            config.max_frame_size,
            std::time::Duration::from_secs(config.sse.stale_secs),
            Arc::clone(fanout),
        );
        let _ = mux.spawn(Arc::clone(&state.shutdown));
        tracing::info!(%addr, "SSE fan-out multiplexer started");
    }
    // Start the native in-process HTTPS listener (G4.2) iff `--tls-listen` is
    // configured.  It runs alongside the plaintext socket, sharing this
    // `state` + the same request core; it fails fast on a bad cert/key/CA
    // before the handler pool comes up.  Its accept thread observes the same
    // shutdown flag and is joined on drain.
    let tls_handle =
        crate::http::tls::spawn_tls_listener(config, &state).map_err(|e| ServeError::Tls {
            reason: e.to_string(),
        })?;
    let handles = spawn_handler_pool(&server, config.handler_threads, &state)?;
    // Register the graceful-shutdown trigger: SIGTERM / SIGINT set the
    // shared shutdown flag (G4.4), which the mux + every live SSE stream
    // also observe.
    register_shutdown_signals(&state.shutdown);
    // Block until shutdown is signalled, then drain.
    while !state.shutdown.load(Ordering::Relaxed) {
        std::thread::sleep(SHUTDOWN_POLL);
    }
    tracing::info!("shutdown signalled; draining in-flight requests + SSE streams");
    if drain_handlers(&server, handles, config.handler_threads, DRAIN_DEADLINE) {
        tracing::info!("gateway drained cleanly; exiting");
    } else {
        tracing::warn!(
            deadline_secs = DRAIN_DEADLINE.as_secs(),
            "drain deadline exceeded; exiting with handler workers still active"
        );
    }
    // Join the TLS accept thread (it polls the shutdown flag, so it exits
    // within one accept-poll; its per-connection threads observe the flag too
    // and are reclaimed at process exit, mirroring the host's TLS handlers).
    if let Some(handle) = tls_handle {
        if handle.join().is_err() {
            tracing::error!("the TLS accept thread panicked during shutdown");
        }
    }
    Ok(())
}

/// Register the SIGTERM / SIGINT graceful-shutdown trigger: each signal
/// sets the shared `shutdown` flag (a safe `signal_hook::flag::register` —
/// the crate forbids `unsafe`, so a hand-rolled `sigaction` is out).  A
/// registration failure is logged, not fatal: the gateway still runs, just
/// without signal-driven drain (a `SIGKILL` still stops it).
fn register_shutdown_signals(shutdown: &Arc<std::sync::atomic::AtomicBool>) {
    for signal in [signal_hook::consts::SIGTERM, signal_hook::consts::SIGINT] {
        if let Err(error) = signal_hook::flag::register(signal, Arc::clone(shutdown)) {
            tracing::warn!(signal, %error, "failed to register a shutdown signal handler");
        }
    }
}

/// Drain the handler pool on shutdown: wake each blocked worker (`tiny_http`
/// unblocks one `recv` per call, so `n_workers` calls wake them all) so it
/// finishes its in-flight request and exits, then join them under an overall
/// `deadline` so a stuck worker cannot hang shutdown.  Returns whether every
/// worker joined within the deadline (the un-joined remainder, if any, is
/// reclaimed at process exit).
fn drain_handlers(
    server: &Arc<tiny_http::Server>,
    handles: Vec<JoinHandle<()>>,
    n_workers: usize,
    deadline: std::time::Duration,
) -> bool {
    for _ in 0..n_workers {
        server.unblock();
    }
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for handle in handles {
            if handle.join().is_err() {
                tracing::error!("a gateway handler thread panicked during drain");
            }
        }
        let _ = tx.send(());
    });
    rx.recv_timeout(deadline).is_ok()
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
/// The **auth gate** ([`crate::auth::gate`]) runs *before* routing: a
/// non-exempt path with no / a wrong credential is answered `401` / `403`
/// without ever routing, so an unauthenticated caller cannot enumerate
/// paths (only `/healthz` + `/readyz` are exempt).
///
/// **Panic-free by construction** (the §3.2 `panic = "abort"`
/// constraint): the method/path/header extraction uses only checked
/// operations, and a write failure — the client hung up before the
/// response was flushed — is logged at `debug` and dropped, since there
/// is nothing else to do.
pub fn handle_request(mut request: tiny_http::Request, state: &AppState) {
    let request_id = crate::observability::next_request_id();
    let start = std::time::Instant::now();
    let method = method_token(request.method());
    // Extract the request line + headers as OWNED values up front, so the
    // body-reader closure can take `&mut request` without a borrow conflict.
    // (`split_once` is total + panic-free; an absent `?` yields the whole
    // target as the path and an empty query.)
    let (path, query, content_type, auth_header, if_none_match, idempotency_key, last_event_id) = {
        let url = request.url();
        let (path, query) = url.split_once('?').unwrap_or((url, ""));
        (
            path.to_string(),
            query.to_string(),
            header_value(&request, "Content-Type").map(str::to_string),
            header_value(&request, "Authorization").map(str::to_string),
            header_value(&request, "If-None-Match").map(str::to_string),
            header_value(&request, "Idempotency-Key").map(str::to_string),
            header_value(&request, "Last-Event-ID").map(str::to_string),
        )
    };
    let parts = RequestParts {
        method,
        path: &path,
        query: &query,
        auth_header: auth_header.as_deref(),
        content_type: content_type.as_deref(),
        if_none_match: if_none_match.as_deref(),
        idempotency_key: idempotency_key.as_deref(),
        last_event_id: last_event_id.as_deref(),
    };
    let routed = route_request(&parts);

    // Hand off to the shared core; the submit-body read is injected (bounded,
    // and only invoked after the gate, so an unauthenticated request never
    // makes us buffer its body).
    match handler::handle(
        &routed,
        &parts,
        |max| read_submit_body(&mut request, &routed, max),
        state,
        &request_id,
    ) {
        Handled::Respond(outcome) => {
            log_request(method, &path, outcome.status, start.elapsed(), &request_id);
            respond(request, &outcome);
        }
        // The live SSE stream takes over the connection (G3.5).
        Handled::Stream {
            since,
            types,
            last_event_id,
        } => {
            crate::events::stream::serve(request, state, since, types, last_event_id, &request_id);
        }
    }
}

/// Read the request body for a submit route, bounded by `max` bytes.
///
/// A non-submit route has no body (`Ok(empty)`).  For
/// [`Route::SubmitAction`] the body is read **bounded**: at most `max + 1`
/// bytes are taken, so a body over the cap is detected *while reading*
/// (no unbounded allocation) and returned as a `413`.  A read error (the
/// client hung up mid-body) yields the partial body — the submit handler
/// then rejects an empty / malformed action.
fn read_submit_body(
    request: &mut tiny_http::Request,
    routed: &Route,
    max: usize,
) -> Result<Vec<u8>, RouteOutcome> {
    if !matches!(routed, Route::SubmitAction) {
        return Ok(Vec::new());
    }
    let cap = u64::try_from(max).unwrap_or(u64::MAX).saturating_add(1);
    let mut body = Vec::new();
    let mut limited = request.as_reader().take(cap);
    // A read error is non-fatal here: keep whatever arrived; the handler
    // rejects an empty / malformed action downstream.
    let _ = limited.read_to_end(&mut body);
    if body.len() > max {
        return Err(Problem::new("payload-too-large", "Payload Too Large", 413)
            .with_detail(format!("request body exceeds the {max}-byte limit"))
            .into_outcome());
    }
    Ok(body)
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

/// The value of the first request header whose field name matches `name`
/// (case-insensitively, per RFC 7230 §3.2), or `None` if absent.
fn header_value<'r>(request: &'r tiny_http::Request, name: &'static str) -> Option<&'r str> {
    request
        .headers()
        .iter()
        .find(|h| h.field.equiv(name))
        .map(|h| h.value.as_str())
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
    use super::{drain_handlers, method_token};
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn drain_handlers_wakes_and_joins_every_worker() {
        // Graceful drain (§G4.4): `n` workers block on `recv`; `drain_handlers`
        // unblocks each (tiny_http wakes one `recv` per `unblock`) so they
        // all exit and join within the deadline.
        let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind"));
        let n = 4;
        let mut handles = Vec::new();
        for _ in 0..n {
            let s = Arc::clone(&server);
            // Mirrors `worker_loop` without the `AppState` dependency: block
            // on `recv` until unblocked (→ `Err`), then exit.
            handles.push(std::thread::spawn(move || while s.recv().is_ok() {}));
        }
        // Let the workers reach their blocking `recv`.
        std::thread::sleep(Duration::from_millis(50));
        assert!(
            drain_handlers(&server, handles, n, Duration::from_secs(2)),
            "unblock-N woke and joined every worker within the deadline"
        );
    }

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
