// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G4.2 native in-process HTTPS — the public-facing TLS front-end.
//!
//! This terminates TLS **in the gateway process** with the workspace's
//! `rustls 0.23` (TLS 1.3, the `ring` backend) — the same audited stack
//! `knomosis-host` uses, **not** `tiny_http`'s bundled `rustls 0.20`.  It runs
//! **alongside** the plaintext `tiny_http` `--listen` socket (so an operator
//! can offer HTTPS directly *or* keep terminating TLS at a co-located edge),
//! and it reuses the **exact** shared request core
//! ([`crate::http::handler`]): the same fail-closed auth gate, the same
//! per-credential rate cap, the same router, the same dispatch, and the same
//! SSE fan-out ([`crate::events::stream::run_one_stream`] over the same
//! [`StreamSlot`] capacity bound).  The two transports therefore **cannot
//! diverge in security behaviour** — only the wire I/O differs.
//!
//! ## Why a hand-rolled HTTP/1.1 reader is safe here
//!
//! `tiny_http` cannot consume an externally-`rustls`-decrypted stream (its
//! `from_listener` only accepts a `TcpListener`/`UnixListener`), so the TLS
//! path reads HTTP/1.1 off the `rustls` `StreamOwned` itself.  The reader is
//! deliberately **strict and unambiguous** — the request-smuggling / desync
//! surface that motivated choosing `tiny_http` (G1.0) is closed by
//! *construction*, because the gateway is the sole HTTP processor on the
//! connection (it is the TLS terminator — there is no intermediary to disagree
//! with about message boundaries):
//!
//!   * **`Transfer-Encoding` is rejected** (`501`) — no chunked decoding, so
//!     the entire TE.CL / CL.TE desync class is impossible.
//!   * **A duplicate or comma-listed `Content-Length` is rejected** (`400`);
//!     a single valid `Content-Length` is read **exactly**, so the next
//!     keep-alive request always starts at the right byte offset.
//!   * **Obsolete line folding is rejected** (`400`); request line, header
//!     line, header count, and header-section size are all bounded.
//!   * **Any framing ambiguity closes the connection** rather than guessing a
//!     boundary — a desync cannot persist across requests.
//!
//! Each accepted connection runs on its **own thread** (bounded by
//! `--tls-max-connections`), so a long-lived SSE stream never starves request
//! processing and a slow client only blocks itself.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use rustls::{ServerConfig, ServerConnection, StreamOwned};

/// The **hot-swappable** server config.  The accept loop clones the current
/// `Arc<ServerConfig>` under a brief lock for each new connection; a `SIGHUP`
/// reload ([`reload_server_config`]) swaps in a freshly-loaded one, so a
/// certificate can be rotated **without dropping the listener or any existing
/// session** (G4.2 zero-downtime rotation).
type SharedConfig = Arc<Mutex<Arc<ServerConfig>>>;

use crate::config::{Config, TlsConfig};
use crate::events::stream::{run_one_stream, StreamRequest, StreamSlot};
use crate::http::handler::{self, log_request, route_request, Handled, RequestParts};
use crate::http::router::RouteOutcome;
use crate::observability::next_request_id;
use crate::problem::Problem;
use crate::state::AppState;

/// Per-connection socket read / write timeout — the slow-loris bound (the peer
/// of `knomosis_host`'s `DEFAULT_CONNECTION_TIMEOUT`).  It also bounds the TLS
/// handshake (a stalled handshake read/write trips it) and a keep-alive idle
/// gap (an idle connection is closed after this, freeing its thread).
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(10);

/// How long the accept loop sleeps when no connection is ready (the listener
/// is non-blocking so the loop can poll the shutdown flag).
const ACCEPT_POLL: Duration = Duration::from_millis(50);

/// Maximum request-line length (method + target + version).  A longer line is
/// `414 URI Too Long`.
const MAX_REQUEST_LINE_BYTES: usize = 8 * 1024;

/// Maximum single header-line length.  A longer line is `431`.
const MAX_HEADER_LINE_BYTES: usize = 8 * 1024;

/// Maximum number of request header lines.  More is `431`.
const MAX_HEADERS: usize = 100;

/// Maximum total request-header-section size.  Larger is `431`.
const MAX_HEADER_SECTION_BYTES: usize = 64 * 1024;

/// The concrete `rustls` server stream the connection loop reads and writes.
type TlsStream = StreamOwned<ServerConnection, TcpStream>;

/// Errors standing up the native-TLS listener at startup (surfaced by
/// [`crate::http::serve`] as a fatal `ServeError`, so a misconfigured TLS
/// surface fails fast before the gateway announces readiness).
#[derive(Debug, thiserror::Error)]
pub enum TlsSetupError {
    /// The server certificate chain (`--tls-cert`) could not be loaded.
    #[error("loading the TLS certificate ({0}) failed")]
    Cert(#[source] knomosis_host::tls::TlsConfigError),
    /// The server private key (`--tls-key`) could not be loaded.
    #[error("loading the TLS private key ({0}) failed")]
    Key(#[source] knomosis_host::tls::TlsConfigError),
    /// The mTLS client-CA bundle (`--mtls-client-ca`) could not be loaded.
    #[error("loading the mTLS client CA ({0}) failed")]
    ClientCa(#[source] knomosis_host::tls::TlsConfigError),
    /// `rustls` rejected the assembled server configuration (e.g. the key
    /// does not match the certificate, or a client-CA cert is not a valid
    /// trust anchor).
    #[error("building the rustls server config failed: {0}")]
    Build(String),
    /// Binding the TLS listen socket failed (address in use, permission …).
    #[error("failed to bind the TLS listener on {addr}: {reason}")]
    Bind {
        /// The address that could not be bound.
        addr: String,
        /// The OS diagnostic.
        reason: String,
    },
    /// The TLS accept thread could not be spawned.
    #[error("failed to spawn the TLS accept thread: {0}")]
    Spawn(String),
}

/// Start the native-TLS accept loop on its own thread **iff** `--tls-listen`
/// is configured.  Returns `Ok(None)` when TLS is disabled, or the accept
/// thread's join handle (the caller joins it on drain).
///
/// The `rustls` `ServerConfig` is built and the socket bound **here**, before
/// returning, so a bad cert / key / CA / address is a fatal startup error
/// rather than a per-connection fault.
///
/// # Errors
///
/// Returns a [`TlsSetupError`] if the certificate / key / client-CA cannot be
/// loaded, `rustls` rejects the configuration, the socket cannot be bound, or
/// the accept thread cannot be spawned.
pub(crate) fn spawn_tls_listener(
    config: &Config,
    state: &Arc<AppState>,
) -> Result<Option<JoinHandle<()>>, TlsSetupError> {
    let Some(tls) = &config.tls else {
        return Ok(None);
    };
    // Built + bound up front so a bad cert / key / CA / address is a fatal
    // startup error; then wrapped for hot-swap on SIGHUP.
    let server_config: SharedConfig = Arc::new(Mutex::new(build_server_config(tls)?));
    let listener = TcpListener::bind(tls.listen).map_err(|e| TlsSetupError::Bind {
        addr: tls.listen.to_string(),
        reason: e.to_string(),
    })?;
    listener
        .set_nonblocking(true)
        .map_err(|e| TlsSetupError::Bind {
            addr: tls.listen.to_string(),
            reason: e.to_string(),
        })?;
    // SIGHUP triggers a zero-downtime certificate reload (handled between
    // accepts in the loop below).
    let reload = Arc::new(AtomicBool::new(false));
    register_reload_signal(&reload);
    tracing::info!(
        listen = %tls.listen,
        mtls = tls.client_ca.is_some(),
        max_connections = tls.max_connections,
        "knomosis-gateway native TLS listener started (SIGHUP reloads the certificate)"
    );
    let state = Arc::clone(state);
    let shutdown = Arc::clone(&state.shutdown);
    let tls = tls.clone();
    let handle = thread::Builder::new()
        .name("knx-gw-tls-accept".to_string())
        .spawn(move || {
            accept_loop(&listener, &server_config, &reload, &tls, &state, &shutdown);
        })
        .map_err(|e| TlsSetupError::Spawn(e.to_string()))?;
    Ok(Some(handle))
}

/// Register `SIGHUP` as the certificate-reload trigger (zero-downtime
/// rotation): each `SIGHUP` sets the shared `reload` flag, which the accept
/// loop observes and acts on between accepts.  A registration failure is
/// logged, not fatal — the gateway keeps serving with the loaded certificate.
fn register_reload_signal(reload: &Arc<AtomicBool>) {
    #[cfg(unix)]
    if let Err(error) = signal_hook::flag::register(signal_hook::consts::SIGHUP, Arc::clone(reload))
    {
        tracing::warn!(%error, "failed to register the SIGHUP certificate-reload handler");
    }
    #[cfg(not(unix))]
    let _ = reload; // no SIGHUP off Unix; the certificate is reloaded on restart
}

/// Reload the certificate / key / client-CA from disk and **hot-swap** the
/// shared `ServerConfig` (the `SIGHUP` rotation).  On any load / build error
/// the **current** certificate is kept, so a fat-fingered rotation never
/// breaks serving; the swap is atomic from a new connection's view (existing
/// sessions keep their old config).
fn reload_server_config(current: &SharedConfig, tls: &TlsConfig) {
    match build_server_config(tls) {
        Ok(new_config) => {
            *current.lock().unwrap_or_else(PoisonError::into_inner) = new_config;
            tracing::info!(cert = %tls.cert.display(), "TLS certificate hot-reloaded (SIGHUP)");
        }
        Err(error) => {
            tracing::error!(
                %error,
                "TLS certificate reload failed; keeping the current certificate"
            );
        }
    }
}

/// Build the `rustls 0.23` `ServerConfig`: TLS 1.3 only, the `ring` backend
/// (pinned per-config so any process-global default is irrelevant), the
/// gateway's server cert + key, and — iff `--mtls-client-ca` is set — a WebPKI
/// client-certificate verifier **requiring** a chain to that CA.
fn build_server_config(tls: &TlsConfig) -> Result<Arc<ServerConfig>, TlsSetupError> {
    use knomosis_host::tls::{load_certs, load_private_key};

    let certs = load_certs(&tls.cert).map_err(TlsSetupError::Cert)?;
    let key = load_private_key(&tls.key).map_err(TlsSetupError::Key)?;

    // Per-config crypto-provider pinning (mirrors `knomosis_host::tls`): the
    // resulting config always uses `ring`, regardless of any process default a
    // downstream consumer may have installed.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let provider = Arc::new(rustls::crypto::ring::default_provider());

    let builder = ServerConfig::builder_with_provider(Arc::clone(&provider))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|e| TlsSetupError::Build(e.to_string()))?;

    let config = match &tls.client_ca {
        None => builder
            .with_no_client_auth()
            .with_single_cert(certs, key)
            .map_err(|e| TlsSetupError::Build(e.to_string()))?,
        Some(ca_path) => {
            let mut roots = rustls::RootCertStore::empty();
            for cert in load_certs(ca_path).map_err(TlsSetupError::ClientCa)? {
                roots
                    .add(cert)
                    .map_err(|e| TlsSetupError::Build(format!("client CA rejected: {e}")))?;
            }
            let verifier = rustls::server::WebPkiClientVerifier::builder_with_provider(
                Arc::new(roots),
                provider,
            )
            .build()
            .map_err(|e| TlsSetupError::Build(format!("client verifier: {e}")))?;
            builder
                .with_client_cert_verifier(verifier)
                .with_single_cert(certs, key)
                .map_err(|e| TlsSetupError::Build(e.to_string()))?
        }
    };
    Ok(Arc::new(config))
}

/// An RAII reservation of one TLS connection slot, bounded by
/// `--tls-max-connections` — the native-TLS spawn-storm DoS guard (the peer of
/// `knomosis_host`'s `ConnectionSlot`).  [`ConnGuard::try_acquire`] increments
/// the shared counter and returns the guard, or `None` at capacity (the accept
/// loop then closes the socket without a handshake); the guard's `Drop`
/// decrements, releasing the slot on every connection-thread exit path.
struct ConnGuard {
    active: Arc<AtomicUsize>,
}

impl ConnGuard {
    /// Reserve a slot, or `None` if already at `max`.
    fn try_acquire(active: &Arc<AtomicUsize>, max: usize) -> Option<Self> {
        let prev = active.fetch_add(1, Ordering::SeqCst);
        if prev >= max {
            active.fetch_sub(1, Ordering::SeqCst);
            return None;
        }
        Some(Self {
            active: Arc::clone(active),
        })
    }
}

impl Drop for ConnGuard {
    fn drop(&mut self) {
        self.active.fetch_sub(1, Ordering::SeqCst);
    }
}

/// The accept loop: non-blocking `accept`, a `SIGHUP` certificate hot-reload
/// (between accepts), a connection-count guard (`--tls-max-connections`), and
/// one handler thread per admitted connection.  Exits when the shared
/// `shutdown` flag is set.  `max_connections` is read from `tls`.
fn accept_loop(
    listener: &TcpListener,
    current_config: &SharedConfig,
    reload: &Arc<AtomicBool>,
    tls: &TlsConfig,
    state: &Arc<AppState>,
    shutdown: &Arc<AtomicBool>,
) {
    let active = Arc::new(AtomicUsize::new(0));
    let mut consecutive_errors = 0u32;
    while !shutdown.load(Ordering::Relaxed) {
        // A SIGHUP since the last iteration → hot-reload the certificate, here
        // (between accepts) so no in-flight handshake is disturbed.
        if reload.swap(false, Ordering::Relaxed) {
            reload_server_config(current_config, tls);
        }
        match listener.accept() {
            Ok((stream, _peer)) => {
                consecutive_errors = 0;
                let Some(guard) = ConnGuard::try_acquire(&active, tls.max_connections) else {
                    // Over the connection cap: close without a handshake (a
                    // plaintext message would be unreadable to a TLS client).
                    let _ = stream.shutdown(Shutdown::Both);
                    continue;
                };
                // Clone the CURRENT config under a brief lock — a SIGHUP reload
                // swaps it, but an in-flight connection keeps the one it took.
                let server_config = current_config
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone();
                let state = Arc::clone(state);
                let shutdown = Arc::clone(shutdown);
                let spawned = thread::Builder::new()
                    .name("knx-gw-tls-conn".to_string())
                    .spawn(move || {
                        // The guard rides the connection thread; its `Drop`
                        // releases the slot on every exit path (incl. a panic).
                        let _guard = guard;
                        handle_connection(stream, server_config, &state, &shutdown);
                    });
                if spawned.is_err() {
                    // The closure (and with it the guard) is dropped, releasing
                    // the slot; the socket closes and the client reconnects.
                    tracing::error!("failed to spawn a TLS connection thread");
                }
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                consecutive_errors = 0;
                thread::sleep(ACCEPT_POLL);
            }
            Err(e) => {
                consecutive_errors = consecutive_errors.saturating_add(1);
                tracing::warn!(error = %e, consecutive_errors, "TLS accept failed");
                let exp = consecutive_errors.saturating_sub(1).min(5);
                thread::sleep(Duration::from_millis(100u64 << exp));
            }
        }
    }
    tracing::debug!("TLS accept loop exiting (shutdown signalled)");
}

/// Complete the TLS handshake and run the keep-alive request loop on one
/// accepted connection.  Consumes `stream` (moved into the `rustls`
/// `StreamOwned`); the socket closes when this returns.
fn handle_connection(
    stream: TcpStream,
    server_config: Arc<ServerConfig>,
    state: &AppState,
    shutdown: &AtomicBool,
) {
    let _ = stream.set_nodelay(true);
    // Blocking mode is required by the synchronous `rustls::StreamOwned`
    // adapter; the read/write timeouts bound slow-loris + the handshake.
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(CONNECTION_TIMEOUT));
    let _ = stream.set_write_timeout(Some(CONNECTION_TIMEOUT));
    let connection = match ServerConnection::new(server_config) {
        Ok(c) => c,
        Err(e) => {
            // Only a rustls mis-configuration reaches here (impossible once the
            // config was built by `build_server_config`); a *handshake* failure
            // (e.g. a missing client cert under mTLS) surfaces later, on first
            // read, and closes the connection.
            tracing::warn!(error = %e, "TLS session setup failed");
            return;
        }
    };
    let mut reader = BufReader::new(StreamOwned::new(connection, stream));
    connection_loop(&mut reader, state, shutdown);
}

/// One connection's keep-alive request loop: read a request, serve it via the
/// shared core, and either loop (keep-alive) or return (close).  A framing
/// reject is answered once and then closes the connection (no resync).
fn connection_loop(reader: &mut BufReader<TlsStream>, state: &AppState, shutdown: &AtomicBool) {
    loop {
        if shutdown.load(Ordering::Relaxed) {
            return;
        }
        let request_id = next_request_id();
        let start = Instant::now();
        match read_request(reader, state.config.max_frame_size) {
            Ok(parsed) => {
                if matches!(
                    serve_parsed(reader, state, parsed, &request_id, start),
                    ConnControl::Close
                ) {
                    return;
                }
            }
            // A clean EOF (idle keep-alive closed) or a socket error / timeout:
            // close quietly, nothing owed.
            Err(RequestError::ConnectionClosed | RequestError::Io) => return,
            // A malformed / oversized / ambiguous request: answer once, close.
            Err(RequestError::Reject {
                status,
                title,
                detail,
            }) => {
                let outcome = handler::finalize(
                    Problem::new(reject_slug(status), title, status)
                        .with_detail(detail)
                        .into_outcome(),
                    &request_id,
                );
                log_request("-", "-", status, start.elapsed(), &request_id);
                let _ = write_response(reader.get_mut(), &outcome, false);
                return;
            }
        }
    }
}

/// Whether the connection loop should keep the connection alive or close it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ConnControl {
    /// Loop for another request on this connection.
    KeepAlive,
    /// Close the connection.
    Close,
}

/// Serve one fully-parsed request through the shared request core, then write
/// the response (or hijack the connection for SSE).  Returns whether the
/// connection may be kept alive.
fn serve_parsed(
    reader: &mut BufReader<TlsStream>,
    state: &AppState,
    parsed: ParsedRequest,
    request_id: &str,
    start: Instant,
) -> ConnControl {
    let ParsedRequest {
        method,
        path,
        query,
        body,
        authorization,
        content_type,
        if_none_match,
        idempotency_key,
        last_event_id,
        keep_alive,
    } = parsed;
    let parts = RequestParts {
        method: &method,
        path: &path,
        query: &query,
        auth_header: authorization.as_deref(),
        content_type: content_type.as_deref(),
        if_none_match: if_none_match.as_deref(),
        idempotency_key: idempotency_key.as_deref(),
        last_event_id: last_event_id.as_deref(),
    };
    let routed = route_request(&parts);
    // The body was already read off the wire (bounded by `--max-frame-size`
    // while reading), so the handler's gated body closure just hands it back.
    let handled = handler::handle(&routed, &parts, move |_max| Ok(body), state, request_id);
    match handled {
        Handled::Respond(outcome) => {
            log_request(&method, &path, outcome.status, start.elapsed(), request_id);
            if write_response(reader.get_mut(), &outcome, keep_alive).is_err() {
                return ConnControl::Close;
            }
            if keep_alive {
                ConnControl::KeepAlive
            } else {
                ConnControl::Close
            }
        }
        Handled::Stream {
            since,
            types,
            last_event_id,
        } => {
            log_request(&method, &path, 200, start.elapsed(), request_id);
            serve_stream(
                reader.get_mut(),
                state,
                since,
                &types,
                last_event_id.as_deref(),
                request_id,
            );
            // An SSE stream owns the connection until it closes.
            ConnControl::Close
        }
    }
}

/// Drive a live SSE stream over the hijacked `rustls` writer, reusing the exact
/// fan-out core ([`run_one_stream`]) and capacity bound ([`StreamSlot`]) as the
/// `tiny_http` path.  Answers `503` (a raw HTTP response) when events streaming
/// is disabled or the stream cap is reached.
fn serve_stream<W: Write>(
    writer: &mut W,
    state: &AppState,
    since: Option<u64>,
    types: &[String],
    last_event_id: Option<&str>,
    request_id: &str,
) {
    let Some(fanout) = &state.fanout else {
        let _ = write_raw_problem(
            writer,
            503,
            "events-unavailable",
            "Events Unavailable",
            "event streaming is disabled: the gateway was started without --event-subscribe-addr",
            None,
            request_id,
        );
        return;
    };
    let Some(_slot) = StreamSlot::try_acquire(&state.active_streams, state.config.sse.max_streams)
    else {
        let _ = write_raw_problem(
            writer,
            503,
            "too-many-streams",
            "Too Many Streams",
            "the gateway is at its configured SSE stream capacity; retry shortly",
            Some(1),
            request_id,
        );
        return;
    };
    // Bind deref'd references so the `StreamRequest` field types line up.
    let fanout: &crate::events::fanout::FanoutState = fanout;
    let sse: &crate::config::SseConfig = &state.config.sse;
    let shutdown: &AtomicBool = &state.shutdown;
    let request = StreamRequest {
        fanout,
        since,
        types,
        last_event_id,
        sse,
        shutdown,
        request_id,
    };
    let end = run_one_stream(writer, &request);
    tracing::info!(request_id, ?end, "tls sse stream closed");
    // `_slot` drops here → `active_streams` is decremented.
}

// ---------------------------------------------------------------------------
// Strict HTTP/1.1 request reader
// ---------------------------------------------------------------------------

/// A fully-read, framing-unambiguous request.
struct ParsedRequest {
    method: String,
    path: String,
    query: String,
    body: Vec<u8>,
    authorization: Option<String>,
    content_type: Option<String>,
    if_none_match: Option<String>,
    idempotency_key: Option<String>,
    last_event_id: Option<String>,
    keep_alive: bool,
}

/// Why [`read_request`] did not yield a request.
#[derive(Debug)]
enum RequestError {
    /// A clean EOF before any request bytes — a closed idle keep-alive.
    ConnectionClosed,
    /// A socket I/O error / timeout, or a truncated request — close quietly.
    Io,
    /// A malformed / oversized / ambiguous request — answer `status`, then
    /// close (a framing reject is never kept alive).
    Reject {
        /// The HTTP status to answer.
        status: u16,
        /// The RFC 9457 problem title.
        title: &'static str,
        /// The problem detail.
        detail: String,
    },
}

/// Build a [`RequestError::Reject`].
fn reject(status: u16, title: &'static str, detail: impl Into<String>) -> RequestError {
    RequestError::Reject {
        status,
        title,
        detail: detail.into(),
    }
}

/// The recognised request-line HTTP versions.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Version {
    /// `HTTP/1.0` — defaults to connection-close.
    Http10,
    /// `HTTP/1.1` — defaults to keep-alive.
    Http11,
}

/// Read one strict HTTP/1.1 request: the request line, the header section, and
/// exactly `Content-Length` body bytes (bounded by `max_body`).  See the
/// module docstring for the anti-smuggling rules.
fn read_request<R: BufRead>(
    reader: &mut R,
    max_body: usize,
) -> Result<ParsedRequest, RequestError> {
    let line = match read_line(reader, MAX_REQUEST_LINE_BYTES) {
        LineRead::Line(l) => l,
        LineRead::Eof => return Err(RequestError::ConnectionClosed),
        LineRead::TooLong => return Err(reject(414, "URI Too Long", "request line too long")),
        LineRead::Invalid => return Err(reject(400, "Bad Request", "non-UTF-8 request line")),
        LineRead::Io => return Err(RequestError::Io),
    };
    let (method, target, version) = parse_request_line(&line)?;
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target, String::new()),
    };

    let headers = read_headers(reader)?;

    if headers.transfer_encoding {
        return Err(reject(
            501,
            "Not Implemented",
            "Transfer-Encoding is not supported; use Content-Length",
        ));
    }
    let content_length = match headers.content_length {
        None => 0,
        Some(n) => usize::try_from(n)
            .map_err(|_| reject(413, "Payload Too Large", "Content-Length out of range"))?,
    };
    if content_length > max_body {
        return Err(reject(
            413,
            "Payload Too Large",
            format!("request body exceeds the {max_body}-byte limit"),
        ));
    }
    let body = read_body(reader, content_length)?;

    let keep_alive = match version {
        _ if headers.connection_close => false,
        Version::Http11 => true,
        Version::Http10 => headers.connection_keep_alive,
    };

    Ok(ParsedRequest {
        method,
        path,
        query,
        body,
        authorization: headers.authorization,
        content_type: headers.content_type,
        if_none_match: headers.if_none_match,
        idempotency_key: headers.idempotency_key,
        last_event_id: headers.last_event_id,
        keep_alive,
    })
}

/// Parse `METHOD SP request-target SP HTTP-version`.  Requires an origin-form
/// target (`/...`) and HTTP/1.0 or /1.1; anything else is rejected.
fn parse_request_line(line: &str) -> Result<(String, String, Version), RequestError> {
    let line = strip_eol(line);
    let mut parts = line.split(' ');
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("");
    let version = parts.next().unwrap_or("");
    if parts.next().is_some() {
        return Err(reject(400, "Bad Request", "malformed request line"));
    }
    if method.is_empty() || method.bytes().any(|b| !is_tchar(b)) {
        return Err(reject(400, "Bad Request", "malformed request method"));
    }
    if !target.starts_with('/') {
        return Err(reject(
            400,
            "Bad Request",
            "only origin-form request targets are supported",
        ));
    }
    let version = match version {
        "HTTP/1.1" => Version::Http11,
        "HTTP/1.0" => Version::Http10,
        _ => {
            return Err(reject(
                505,
                "HTTP Version Not Supported",
                "only HTTP/1.0 and HTTP/1.1 are supported",
            ))
        }
    };
    Ok((method.to_string(), target.to_string(), version))
}

/// The subset of request headers the gateway reads, plus the framing-relevant
/// ones.  Field-name matching is case-insensitive; the first occurrence of a
/// value header wins (matching the `tiny_http` path's header selection).
#[derive(Default)]
struct HeaderSet {
    authorization: Option<String>,
    content_type: Option<String>,
    if_none_match: Option<String>,
    idempotency_key: Option<String>,
    last_event_id: Option<String>,
    content_length: Option<u64>,
    transfer_encoding: bool,
    connection_close: bool,
    connection_keep_alive: bool,
}

/// Read the header section (lines until a blank line), bounded in count + size,
/// rejecting obsolete folding and a duplicate / comma-listed `Content-Length`.
fn read_headers<R: BufRead>(reader: &mut R) -> Result<HeaderSet, RequestError> {
    let mut headers = HeaderSet::default();
    let mut section_bytes = 0usize;
    let mut count = 0usize;
    loop {
        let line = match read_line(reader, MAX_HEADER_LINE_BYTES) {
            LineRead::Line(l) => l,
            LineRead::Eof | LineRead::Io => return Err(RequestError::Io),
            LineRead::TooLong => {
                return Err(reject(
                    431,
                    "Request Header Fields Too Large",
                    "header line too long",
                ))
            }
            LineRead::Invalid => return Err(reject(400, "Bad Request", "non-UTF-8 header line")),
        };
        // Obsolete line folding (a continuation line starting with SP/HTAB) is
        // a smuggling vector — reject it.
        if line.starts_with(' ') || line.starts_with('\t') {
            return Err(reject(400, "Bad Request", "obsolete header folding"));
        }
        let trimmed = strip_eol(&line);
        if trimmed.is_empty() {
            return Ok(headers); // end of header section
        }
        section_bytes = section_bytes.saturating_add(line.len());
        count += 1;
        if count > MAX_HEADERS || section_bytes > MAX_HEADER_SECTION_BYTES {
            return Err(reject(
                431,
                "Request Header Fields Too Large",
                "too many request headers",
            ));
        }
        let (name, value) = trimmed
            .split_once(':')
            .ok_or_else(|| reject(400, "Bad Request", "header line without a colon"))?;
        if name.is_empty() || name.bytes().any(|b| !is_tchar(b)) {
            return Err(reject(400, "Bad Request", "malformed header field name"));
        }
        insert_header(&mut headers, name, value.trim())?;
    }
}

/// Record one header into [`HeaderSet`], applying the framing rules.
fn insert_header(headers: &mut HeaderSet, name: &str, value: &str) -> Result<(), RequestError> {
    if name.eq_ignore_ascii_case("content-length") {
        // A duplicate (even with the same value) or a comma-list is a
        // request-smuggling vector — reject rather than guess.
        if headers.content_length.is_some() {
            return Err(reject(400, "Bad Request", "duplicate Content-Length"));
        }
        if value.contains(',') {
            return Err(reject(400, "Bad Request", "multiple Content-Length values"));
        }
        let n = value
            .parse::<u64>()
            .map_err(|_| reject(400, "Bad Request", "malformed Content-Length"))?;
        headers.content_length = Some(n);
    } else if name.eq_ignore_ascii_case("transfer-encoding") {
        headers.transfer_encoding = true;
    } else if name.eq_ignore_ascii_case("connection") {
        for token in value.split(',') {
            let token = token.trim();
            if token.eq_ignore_ascii_case("close") {
                headers.connection_close = true;
            } else if token.eq_ignore_ascii_case("keep-alive") {
                headers.connection_keep_alive = true;
            }
        }
    } else if name.eq_ignore_ascii_case("authorization") {
        set_first(&mut headers.authorization, value);
    } else if name.eq_ignore_ascii_case("content-type") {
        set_first(&mut headers.content_type, value);
    } else if name.eq_ignore_ascii_case("if-none-match") {
        set_first(&mut headers.if_none_match, value);
    } else if name.eq_ignore_ascii_case("idempotency-key") {
        set_first(&mut headers.idempotency_key, value);
    } else if name.eq_ignore_ascii_case("last-event-id") {
        set_first(&mut headers.last_event_id, value);
    }
    // Every other header is ignored (the gateway reads only the set above).
    Ok(())
}

/// Set `slot` to `value` iff it is still empty (first-occurrence-wins).
fn set_first(slot: &mut Option<String>, value: &str) {
    if slot.is_none() {
        *slot = Some(value.to_string());
    }
}

/// Read exactly `content_length` body bytes, growing the buffer only by what
/// actually arrives (no pre-allocation amplification on a lying length).  A
/// short read (the client hung up) is an [`RequestError::Io`].
fn read_body<R: Read>(reader: &mut R, content_length: usize) -> Result<Vec<u8>, RequestError> {
    let mut body = Vec::new();
    let mut remaining = content_length;
    let mut chunk = [0u8; 8192];
    while remaining > 0 {
        let want = remaining.min(chunk.len());
        match reader.read(&mut chunk[..want]) {
            Ok(0) => return Err(RequestError::Io), // EOF before the full body
            Ok(n) => {
                body.extend_from_slice(&chunk[..n]);
                remaining -= n;
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return Err(RequestError::Io),
        }
    }
    Ok(body)
}

/// The outcome of [`read_line`].
enum LineRead {
    /// A complete line (terminated by `\n`), as UTF-8.
    Line(String),
    /// A clean EOF with no bytes read.
    Eof,
    /// The line exceeded its byte budget before a `\n`.
    TooLong,
    /// The line was not valid UTF-8.
    Invalid,
    /// A socket I/O error, or EOF mid-line.
    Io,
}

/// Read one `\n`-terminated line, bounded to `cap` bytes (so a newline-less
/// flood cannot allocate without bound).  Bytes after the `\n` stay buffered
/// in `reader` for the next call (keep-alive framing is preserved).
fn read_line<R: BufRead>(reader: &mut R, cap: usize) -> LineRead {
    let mut buf = Vec::new();
    let limit = u64::try_from(cap).unwrap_or(u64::MAX);
    let Ok(n) = (&mut *reader).take(limit).read_until(b'\n', &mut buf) else {
        return LineRead::Io;
    };
    if n == 0 {
        return LineRead::Eof;
    }
    if buf.last() == Some(&b'\n') {
        match String::from_utf8(buf) {
            Ok(s) => LineRead::Line(s),
            Err(_) => LineRead::Invalid,
        }
    } else if n >= cap {
        LineRead::TooLong
    } else {
        LineRead::Io // underlying EOF mid-line (truncated)
    }
}

/// Strip a trailing `\r\n` / `\n` from a line.
fn strip_eol(s: &str) -> &str {
    s.strip_suffix('\n')
        .map_or(s, |s| s.strip_suffix('\r').unwrap_or(s))
}

/// RFC 7230 token character (for method + header-field-name validation).
fn is_tchar(b: u8) -> bool {
    b.is_ascii_alphanumeric()
        || matches!(
            b,
            b'!' | b'#'
                | b'$'
                | b'%'
                | b'&'
                | b'\''
                | b'*'
                | b'+'
                | b'-'
                | b'.'
                | b'^'
                | b'_'
                | b'`'
                | b'|'
                | b'~'
        )
}

// ---------------------------------------------------------------------------
// HTTP/1.1 response writer
// ---------------------------------------------------------------------------

/// Write a [`RouteOutcome`] as a framed HTTP/1.1 response (an explicit
/// `Content-Length` + a `Connection` token, so keep-alive framing is exact).
/// A header whose name/value carries a control character is skipped
/// (response-splitting guard) — defensive: the gateway's headers are
/// controlled.
fn write_response<W: Write>(
    w: &mut W,
    outcome: &RouteOutcome,
    keep_alive: bool,
) -> std::io::Result<()> {
    write!(
        w,
        "HTTP/1.1 {} {}\r\n",
        outcome.status,
        reason_phrase(outcome.status)
    )?;
    write!(w, "Content-Type: {}\r\n", outcome.content_type)?;
    write!(w, "Content-Length: {}\r\n", outcome.body.len())?;
    for (name, value) in &outcome.headers {
        if header_is_safe(name, value) {
            write!(w, "{name}: {value}\r\n")?;
        }
    }
    write!(
        w,
        "Connection: {}\r\n\r\n",
        if keep_alive { "keep-alive" } else { "close" }
    )?;
    w.write_all(outcome.body.as_bytes())?;
    w.flush()
}

/// Build + write a framing-time problem (`503` events / over-cap) as a raw
/// HTTP/1.1 response, carrying the `X-Request-Id` (via [`handler::finalize`])
/// and an optional `Retry-After`.
fn write_raw_problem<W: Write>(
    w: &mut W,
    status: u16,
    slug: &str,
    title: &str,
    detail: &str,
    retry_after_secs: Option<u64>,
    request_id: &str,
) -> std::io::Result<()> {
    let mut problem = Problem::new(slug, title, status).with_detail(detail.to_string());
    if let Some(secs) = retry_after_secs {
        problem = problem.with_retry_after_ms(secs.saturating_mul(1000));
    }
    let mut outcome = handler::finalize(problem.into_outcome(), request_id);
    if let Some(secs) = retry_after_secs {
        outcome = outcome.with_header("Retry-After", secs.max(1).to_string());
    }
    write_response(w, &outcome, false)
}

/// Whether a header name + value is safe to write (no CR/LF/`:` injection).
fn header_is_safe(name: &str, value: &str) -> bool {
    !name.is_empty()
        && name.bytes().all(|b| !matches!(b, b'\r' | b'\n' | b':'))
        && value.bytes().all(|b| !matches!(b, b'\r' | b'\n'))
}

/// The reason phrase for a status code (informational; clients do not parse
/// it).  Covers the gateway's emitted set; anything else is a generic token.
fn reason_phrase(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        _ => "Status",
    }
}

/// The RFC 9457 problem `type` slug for a framing-reject status.
fn reject_slug(status: u16) -> &'static str {
    match status {
        413 => "payload-too-large",
        414 => "uri-too-long",
        431 => "request-header-fields-too-large",
        501 => "not-implemented",
        505 => "http-version-not-supported",
        _ => "bad-request",
    }
}

#[cfg(test)]
mod tests {
    use super::{
        read_request, reason_phrase, reject_slug, write_response, ConnControl, RequestError,
        Version,
    };
    use crate::http::RouteOutcome;
    use std::io::BufReader;

    /// Parse a request from a byte slice (the reader is generic over
    /// `BufRead`, so the strict HTTP/1.1 parser is unit-testable with no TLS).
    fn parse(raw: &[u8], max_body: usize) -> Result<super::ParsedRequest, RequestError> {
        let mut reader = BufReader::new(raw);
        read_request(&mut reader, max_body)
    }

    #[test]
    fn parses_a_simple_get() {
        let req = parse(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n", 1024).unwrap();
        assert_eq!(req.method, "GET");
        assert_eq!(req.path, "/healthz");
        assert_eq!(req.query, "");
        assert!(req.keep_alive); // HTTP/1.1 default
        assert!(req.body.is_empty());
    }

    #[test]
    fn splits_path_and_query_and_reads_known_headers() {
        let raw = b"GET /v1/pools/161?resource=1 HTTP/1.1\r\n\
                    Authorization: Bearer tok\r\n\
                    If-None-Match: W/\"7-42\"\r\n\
                    Last-Event-ID: 5.0\r\n\r\n";
        let req = parse(raw, 1024).unwrap();
        assert_eq!(req.path, "/v1/pools/161");
        assert_eq!(req.query, "resource=1");
        assert_eq!(req.authorization.as_deref(), Some("Bearer tok"));
        assert_eq!(req.if_none_match.as_deref(), Some("W/\"7-42\""));
        assert_eq!(req.last_event_id.as_deref(), Some("5.0"));
    }

    #[test]
    fn reads_post_body_exactly() {
        let raw = b"POST /v1/actions HTTP/1.1\r\n\
                    Content-Type: application/octet-stream\r\n\
                    Content-Length: 5\r\n\r\n\
                    helloTRAILING";
        let req = parse(raw, 1024).unwrap();
        assert_eq!(req.body, b"hello");
        assert_eq!(
            req.content_type.as_deref(),
            Some("application/octet-stream")
        );
    }

    #[test]
    fn rejects_transfer_encoding() {
        let raw = b"POST /v1/actions HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
        assert!(matches!(
            parse(raw, 1024),
            Err(RequestError::Reject { status: 501, .. })
        ));
    }

    #[test]
    fn rejects_duplicate_content_length() {
        let raw =
            b"POST /v1/actions HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello";
        assert!(matches!(
            parse(raw, 1024),
            Err(RequestError::Reject { status: 400, .. })
        ));
    }

    #[test]
    fn rejects_comma_listed_content_length() {
        let raw = b"POST /v1/actions HTTP/1.1\r\nContent-Length: 5, 5\r\n\r\nhello";
        assert!(matches!(
            parse(raw, 1024),
            Err(RequestError::Reject { status: 400, .. })
        ));
    }

    #[test]
    fn rejects_oversized_body() {
        let raw = b"POST /v1/actions HTTP/1.1\r\nContent-Length: 100\r\n\r\n";
        // max_body = 10 < declared 100 → 413 (without reading the body).
        assert!(matches!(
            parse(raw, 10),
            Err(RequestError::Reject { status: 413, .. })
        ));
    }

    #[test]
    fn rejects_obsolete_folding_and_bad_version_and_target() {
        let folded = b"GET / HTTP/1.1\r\nX-A: a\r\n b\r\n\r\n";
        assert!(matches!(
            parse(folded, 1024),
            Err(RequestError::Reject { status: 400, .. })
        ));
        let bad_version = b"GET / HTTP/2.0\r\n\r\n";
        assert!(matches!(
            parse(bad_version, 1024),
            Err(RequestError::Reject { status: 505, .. })
        ));
        let absolute = b"GET http://evil/ HTTP/1.1\r\n\r\n";
        assert!(matches!(
            parse(absolute, 1024),
            Err(RequestError::Reject { status: 400, .. })
        ));
    }

    #[test]
    fn keep_alive_rules() {
        // HTTP/1.1 + Connection: close → close.
        let close = parse(b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n", 16).unwrap();
        assert!(!close.keep_alive);
        // HTTP/1.0 defaults to close…
        let h10 = parse(b"GET / HTTP/1.0\r\n\r\n", 16).unwrap();
        assert!(!h10.keep_alive);
        // …unless it opts in.
        let h10_ka = parse(b"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", 16).unwrap();
        assert!(h10_ka.keep_alive);
    }

    #[test]
    fn eof_and_truncation() {
        // No bytes at all → a clean idle close.
        assert!(matches!(
            parse(b"", 16),
            Err(RequestError::ConnectionClosed)
        ));
        // A declared body that never arrives → Io (truncated), not a hang.
        let raw = b"POST /v1/actions HTTP/1.1\r\nContent-Length: 5\r\n\r\nhi";
        assert!(matches!(parse(raw, 16), Err(RequestError::Io)));
    }

    #[test]
    fn writes_a_framed_response() {
        let outcome =
            RouteOutcome::json(200, r#"{"ok":true}"#.to_string()).with_header("ETag", "W/\"7-42\"");
        let mut buf = Vec::new();
        write_response(&mut buf, &outcome, true).unwrap();
        let text = String::from_utf8(buf).unwrap();
        assert!(text.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(text.contains("Content-Type: application/json\r\n"));
        assert!(text.contains("Content-Length: 11\r\n"));
        assert!(text.contains("ETag: W/\"7-42\"\r\n"));
        assert!(text.contains("Connection: keep-alive\r\n"));
        assert!(text.ends_with("\r\n\r\n{\"ok\":true}"));
    }

    #[test]
    fn response_writer_blocks_header_injection() {
        // A header value carrying CRLF is dropped, never written (so a
        // response cannot be split).  (Defensive — gateway headers are
        // controlled.)
        let outcome =
            RouteOutcome::json(200, "{}".to_string()).with_header("X-Evil", "a\r\nInjected: 1");
        let mut buf = Vec::new();
        write_response(&mut buf, &outcome, false).unwrap();
        let text = String::from_utf8(buf).unwrap();
        assert!(!text.contains("Injected"));
        assert!(text.contains("Connection: close\r\n"));
    }

    #[test]
    fn reason_and_slug_tables() {
        assert_eq!(reason_phrase(200), "OK");
        assert_eq!(reason_phrase(503), "Service Unavailable");
        assert_eq!(reason_phrase(599), "Status");
        assert_eq!(reject_slug(413), "payload-too-large");
        assert_eq!(reject_slug(400), "bad-request");
        assert_eq!(reject_slug(999), "bad-request");
    }

    #[test]
    fn enum_smoke() {
        // Keep the small marker enums exercised (they gate the connection loop).
        assert_ne!(ConnControl::KeepAlive, ConnControl::Close);
        assert_ne!(Version::Http10, Version::Http11);
    }
}

/// End-to-end TLS handshake tests: a real `rustls 0.23` client drives the real
/// accept loop + `build_server_config` over openssl-generated certificates.
/// These exercise the wire path the pure-parser tests above cannot — the
/// handshake, the response framing over `rustls`, keep-alive, and mTLS
/// client-certificate enforcement.  Skipped (with a notice) where `openssl` is
/// unavailable; CI (`ubuntu-latest`) always has it.
#[cfg(test)]
mod handshake_tests {
    use std::io::{Read, Write};
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use super::{accept_loop, build_server_config, reload_server_config, SharedConfig};
    use crate::config::{AdmissionStage, Config, SseConfig, TlsConfig};
    use crate::state::AppState;

    /// The bearer token the test `AppState` accepts.
    const TOKEN: &str = "tls-token";

    /// Run an `openssl` command; `true` iff it exists and succeeded.
    fn openssl(args: &[&str]) -> bool {
        match Command::new("openssl").args(args).output() {
            Ok(out) if out.status.success() => true,
            Ok(out) => {
                eprintln!(
                    "openssl {args:?} failed: {}",
                    String::from_utf8_lossy(&out.stderr)
                );
                false
            }
            Err(_) => false, // openssl not installed
        }
    }

    /// A path inside `dir`, as an owned `String` (for openssl argv).
    fn at(dir: &Path, name: &str) -> String {
        dir.join(name).to_string_lossy().into_owned()
    }

    /// Generate a test PKI into `dir`: a self-signed **v3** CA, a server
    /// certificate (SAN `IP:127.0.0.1`, `serverAuth`) signed by it, and a
    /// client certificate (`clientAuth`) signed by it (for mTLS).  webpki
    /// requires v3 certificates (a CA must carry `basicConstraints=CA:TRUE`),
    /// so every cert gets explicit extensions.  Returns `false` (skip) if
    /// openssl is unavailable.
    fn gen_pki(dir: &Path) -> bool {
        std::fs::write(
            dir.join("server.ext"),
            "subjectAltName=IP:127.0.0.1\n\
             basicConstraints=CA:FALSE\n\
             keyUsage=digitalSignature,keyEncipherment\n\
             extendedKeyUsage=serverAuth\n",
        )
        .unwrap();
        std::fs::write(
            dir.join("client.ext"),
            "basicConstraints=CA:FALSE\n\
             keyUsage=digitalSignature\n\
             extendedKeyUsage=clientAuth\n",
        )
        .unwrap();
        // Self-signed CA — v3, with basicConstraints=CA:TRUE (a webpki trust
        // anchor cannot be a v1 / non-CA certificate).
        if !openssl(&[
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            &at(dir, "ca.key"),
            "-out",
            &at(dir, "ca.crt"),
            "-days",
            "3650",
            "-subj",
            "/CN=Knomosis Test CA",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
        ]) {
            return false;
        }
        // Server leaf (CSR → CA-signed cert with the IP SAN + serverAuth).
        let ok = openssl(&[
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            &at(dir, "server.key"),
            "-out",
            &at(dir, "server.csr"),
            "-subj",
            "/CN=knomosis-gateway",
        ]) && openssl(&[
            "x509",
            "-req",
            "-in",
            &at(dir, "server.csr"),
            "-CA",
            &at(dir, "ca.crt"),
            "-CAkey",
            &at(dir, "ca.key"),
            "-CAcreateserial",
            "-out",
            &at(dir, "server.crt"),
            "-days",
            "3650",
            "-extfile",
            &at(dir, "server.ext"),
        ]);
        if !ok {
            return false;
        }
        // Client leaf (CSR → CA-signed cert with clientAuth) for the mTLS path.
        openssl(&[
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            &at(dir, "client.key"),
            "-out",
            &at(dir, "client.csr"),
            "-subj",
            "/CN=knomosis-client",
        ]) && openssl(&[
            "x509",
            "-req",
            "-in",
            &at(dir, "client.csr"),
            "-CA",
            &at(dir, "ca.crt"),
            "-CAkey",
            &at(dir, "ca.key"),
            "-CAcreateserial",
            "-out",
            &at(dir, "client.crt"),
            "-days",
            "3650",
            "-extfile",
            &at(dir, "client.ext"),
        ])
    }

    /// Build a minimal authenticated `AppState` (a token file, no indexer / host
    /// / events — so reads/submit/SSE answer their disabled statuses, which is
    /// exactly what the TLS-path assertions check).
    fn make_state(dir: &Path) -> Arc<AppState> {
        let token_path = dir.join("tokens");
        std::fs::write(&token_path, TOKEN).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&token_path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let config = Config {
            listen: "127.0.0.1:0".parse().unwrap(),
            handler_threads: 1,
            indexer_db: None,
            free_tier: 0,
            action_cost: 0,
            epoch_length: 0,
            gas_pool_actor: None,
            deployment_id: "knx-tls".to_string(),
            ok_admission_stage: AdmissionStage::Finalized,
            host_addr: None,
            event_subscribe_addr: None,
            auth_token_file: Some(token_path),
            rate_limit_rps: 0,
            host_pool_size: 8,
            host_max_inflight: 8,
            request_deadline_ms: 5000,
            max_frame_size: 1024 * 1024,
            idempotency_ttl_secs: 0,
            sse: SseConfig::default(),
            tls: None,
        };
        Arc::new(AppState::new(config).expect("build AppState"))
    }

    /// A running TLS test listener; dropping it stops the accept loop.
    struct TlsServer {
        addr: SocketAddr,
        shutdown: Arc<AtomicBool>,
        handle: Option<std::thread::JoinHandle<()>>,
    }

    impl Drop for TlsServer {
        fn drop(&mut self) {
            self.shutdown.store(true, Ordering::SeqCst);
            if let Some(h) = self.handle.take() {
                let _ = h.join();
            }
        }
    }

    /// Bind an ephemeral TLS listener serving `state` with `tls` config, and run
    /// the real `accept_loop` on its own thread.  Returns the running server
    /// **and** the hot-swappable [`SharedConfig`] so a test can rotate the
    /// certificate via [`reload_server_config`].
    fn serve(tls: &TlsConfig, state: &Arc<AppState>) -> (TlsServer, SharedConfig) {
        let shared: SharedConfig = Arc::new(Mutex::new(
            build_server_config(tls).expect("build rustls server config"),
        ));
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.set_nonblocking(true).unwrap();
        let addr = listener.local_addr().unwrap();
        let shutdown = Arc::new(AtomicBool::new(false));
        let reload = Arc::new(AtomicBool::new(false));
        let (cfg, state, sd, tls_owned) = (
            Arc::clone(&shared),
            Arc::clone(state),
            Arc::clone(&shutdown),
            tls.clone(),
        );
        let handle = std::thread::spawn(move || {
            accept_loop(&listener, &cfg, &reload, &tls_owned, &state, &sd);
        });
        (
            TlsServer {
                addr,
                shutdown,
                handle: Some(handle),
            },
            shared,
        )
    }

    /// Load a PEM file into a fresh `RootCertStore`.
    fn roots(path: &Path) -> rustls::RootCertStore {
        let mut store = rustls::RootCertStore::empty();
        for cert in knomosis_host::tls::load_certs(path).expect("load CA") {
            store.add(cert).expect("add CA");
        }
        store
    }

    /// Connect a `rustls 0.23` client (trusting `ca`, optionally presenting a
    /// client certificate for mTLS), send `request`, and return the raw HTTP
    /// response bytes.  A handshake failure (e.g. mTLS with no client cert)
    /// surfaces as `Err`.
    fn request(
        addr: SocketAddr,
        ca: &Path,
        client_auth: Option<(&Path, &Path)>,
        req: &[u8],
    ) -> std::io::Result<Vec<u8>> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let builder = rustls::ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .with_root_certificates(roots(ca));
        let config = match client_auth {
            None => builder.with_no_client_auth(),
            Some((cert, key)) => builder
                .with_client_auth_cert(
                    knomosis_host::tls::load_certs(cert).unwrap(),
                    knomosis_host::tls::load_private_key(key).unwrap(),
                )
                .unwrap(),
        };
        let name = rustls::pki_types::ServerName::try_from("127.0.0.1").unwrap();
        let conn = rustls::ClientConnection::new(Arc::new(config), name)
            .map_err(|e| std::io::Error::other(e.to_string()))?;
        let sock = TcpStream::connect(addr)?;
        sock.set_read_timeout(Some(Duration::from_secs(5))).ok();
        sock.set_write_timeout(Some(Duration::from_secs(5))).ok();
        let mut tls = rustls::StreamOwned::new(conn, sock);
        // The handshake completes on first write; an mTLS rejection errors here.
        tls.write_all(req)?;
        tls.flush()?;
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            match tls.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => buf.extend_from_slice(&chunk[..n]),
                // A clean response followed by an unclean close (the server
                // drops without close_notify) ends the read; an error *before*
                // any byte is a real failure (propagate it).
                Err(e) => {
                    if buf.is_empty() {
                        return Err(e);
                    }
                    break;
                }
            }
        }
        Ok(buf)
    }

    fn text(bytes: &std::io::Result<Vec<u8>>) -> String {
        String::from_utf8_lossy(bytes.as_ref().expect("response")).into_owned()
    }

    /// A server-auth-only `TlsConfig` over the generated `dir` PKI.
    fn server_tls(dir: &Path) -> TlsConfig {
        TlsConfig {
            listen: "127.0.0.1:0".parse().unwrap(),
            cert: PathBuf::from(at(dir, "server.crt")),
            key: PathBuf::from(at(dir, "server.key")),
            client_ca: None,
            max_connections: 64,
        }
    }

    /// The native-TLS request surface end-to-end over a real handshake: the
    /// shared gate → route → dispatch core answers correctly over `rustls`, the
    /// strict reader rejects a bad version, a POST body is framed exactly, an
    /// SSE request without fan-out is `503`, and keep-alive serves pipelined
    /// requests.
    #[test]
    fn native_tls_server_auth_surface() {
        let dir = tempfile::tempdir().unwrap();
        if !gen_pki(dir.path()) {
            eprintln!("skipping native_tls_server_auth_surface: openssl unavailable");
            return;
        }
        let state = make_state(dir.path());
        let (server, _shared) = serve(&server_tls(dir.path()), &state);
        let ca = dir.path().join("ca.crt");
        let authed = format!("Authorization: Bearer {TOKEN}\r\n");

        // /healthz is exempt → 200 over TLS.
        let health = request(
            server.addr,
            &ca,
            None,
            b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert!(
            text(&health).starts_with("HTTP/1.1 200 OK"),
            "{}",
            text(&health)
        );
        assert!(text(&health).trim_end().ends_with("ok"));

        // /v1/info with the bearer token → 200 JSON over TLS (full gate→dispatch).
        let info = request(
            server.addr,
            &ca,
            None,
            format!("GET /v1/info HTTP/1.1\r\nHost: x\r\n{authed}Connection: close\r\n\r\n")
                .as_bytes(),
        );
        assert!(text(&info).contains("HTTP/1.1 200 OK"));
        assert!(text(&info).contains("\"submitProtocolVersion\""));

        // /v1/info with NO credential → fail-closed 401 over TLS.
        let unauth = request(
            server.addr,
            &ca,
            None,
            b"GET /v1/info HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert!(text(&unauth).contains("HTTP/1.1 401"));
        assert!(text(&unauth).contains("WWW-Authenticate: Bearer"));

        // A bad HTTP version is a strict-framing reject (505) — the connection
        // closes without desync.
        let bad = request(server.addr, &ca, None, b"GET / HTTP/2.0\r\nHost: x\r\n\r\n");
        assert!(text(&bad).contains("HTTP/1.1 505"));

        // A POST body is read off the wire (exact framing); submit is disabled
        // (no --host-addr) → 503 over TLS.
        let submit = request(
            server.addr,
            &ca,
            None,
            format!(
                "POST /v1/actions HTTP/1.1\r\nHost: x\r\n{authed}\
                 Content-Type: application/octet-stream\r\nContent-Length: 4\r\n\
                 Connection: close\r\n\r\nbody"
            )
            .as_bytes(),
        );
        assert!(text(&submit).contains("HTTP/1.1 503"));

        // An SSE stream with no fan-out configured → 503 events-unavailable
        // (the TLS serve_stream raw-503 path).
        let stream = request(
            server.addr,
            &ca,
            None,
            format!(
                "GET /v1/events/stream HTTP/1.1\r\nHost: x\r\n{authed}Connection: close\r\n\r\n"
            )
            .as_bytes(),
        );
        assert!(text(&stream).contains("HTTP/1.1 503"));
        assert!(text(&stream).contains("events-unavailable"));

        // Keep-alive: two pipelined requests on ONE connection (the first
        // without `Connection: close`) → two framed 200s, exact framing.
        let pipelined = request(
            server.addr,
            &ca,
            None,
            b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n\
              GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert_eq!(
            text(&pipelined).matches("HTTP/1.1 200 OK").count(),
            2,
            "keep-alive served both pipelined requests"
        );

        // Keep-alive WITH a body: a POST whose exact Content-Length body is
        // consumed, then a GET on the SAME connection.  This is the
        // smuggling-resistance crux — if the body were under- or over-read by
        // a single byte, the GET would be parsed from the wrong offset (a
        // desync).  Both responses must appear, in request order.
        let body_pipelined = request(
            server.addr,
            &ca,
            None,
            format!(
                "POST /v1/actions HTTP/1.1\r\nHost: x\r\n{authed}\
                 Content-Type: application/octet-stream\r\nContent-Length: 4\r\n\r\nbody\
                 GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
            )
            .as_bytes(),
        );
        let bt = text(&body_pipelined);
        let submit_at = bt.find("HTTP/1.1 503").expect("submit 503 after the body");
        let health_at = bt
            .find("HTTP/1.1 200 OK")
            .expect("health 200 after the body");
        assert!(
            submit_at < health_at,
            "the body was consumed exactly: the next request parsed cleanly, \
             in order — submit 503 then health 200:\n{bt}"
        );
        drop(server);
    }

    /// mTLS enforcement over a real handshake: a client with no certificate is
    /// rejected at the handshake, and a CA-signed client certificate is
    /// accepted.
    #[test]
    fn native_tls_mutual_auth_enforced() {
        let dir = tempfile::tempdir().unwrap();
        if !gen_pki(dir.path()) {
            eprintln!("skipping native_tls_mutual_auth_enforced: openssl unavailable");
            return;
        }
        let state = make_state(dir.path());
        // A client certificate chaining to the CA is required.
        let mtls = TlsConfig {
            client_ca: Some(PathBuf::from(at(dir.path(), "ca.crt"))),
            ..server_tls(dir.path())
        };
        let (server, _shared) = serve(&mtls, &state);
        let ca = dir.path().join("ca.crt");

        // No client certificate → the handshake is rejected (Err, no response).
        let rejected = request(
            server.addr,
            &ca,
            None,
            b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert!(
            rejected.is_err(),
            "mTLS must reject a client with no certificate"
        );

        // The CA-signed client certificate → the handshake completes, 200.
        let client_crt = dir.path().join("client.crt");
        let client_key = dir.path().join("client.key");
        let accepted = request(
            server.addr,
            &ca,
            Some((&client_crt, &client_key)),
            b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
        );
        assert!(
            text(&accepted).starts_with("HTTP/1.1 200 OK"),
            "mTLS must accept a CA-signed client certificate: {}",
            text(&accepted)
        );
        drop(server);
    }

    /// The hot-reload mechanism in isolation: a successful reload swaps in a
    /// new `Arc<ServerConfig>` (pointer changes), and a failing reload (a bad
    /// path) keeps the current one — so a fat-fingered rotation never breaks
    /// serving.
    #[test]
    fn cert_reload_swaps_on_success_keeps_on_failure() {
        let dir = tempfile::tempdir().unwrap();
        if !gen_pki(dir.path()) {
            eprintln!(
                "skipping cert_reload_swaps_on_success_keeps_on_failure: openssl unavailable"
            );
            return;
        }
        let tls = server_tls(dir.path());
        let initial = build_server_config(&tls).expect("initial config");
        let shared: SharedConfig = Arc::new(Mutex::new(Arc::clone(&initial)));

        // A valid reload swaps the config (a different `Arc`).
        reload_server_config(&shared, &tls);
        let after_ok = shared.lock().unwrap().clone();
        assert!(
            !Arc::ptr_eq(&initial, &after_ok),
            "a successful reload swaps in a new config"
        );

        // A reload with a bad cert path fails and KEEPS the current config.
        let bad = TlsConfig {
            cert: dir.path().join("does-not-exist.crt"),
            ..tls
        };
        reload_server_config(&shared, &bad);
        let after_err = shared.lock().unwrap().clone();
        assert!(
            Arc::ptr_eq(&after_ok, &after_err),
            "a failed reload keeps the current config (serving never breaks)"
        );
    }

    /// End-to-end zero-downtime rotation: a live listener serving cert A is
    /// hot-reloaded to a cert from a *different* CA (B); a new connection then
    /// presents B (a CA-B client succeeds) and the old CA-A no longer
    /// validates — proving the accept loop serves the swapped certificate.
    #[test]
    fn cert_hot_reload_serves_the_new_certificate() {
        let dir_a = tempfile::tempdir().unwrap();
        let dir_b = tempfile::tempdir().unwrap();
        if !gen_pki(dir_a.path()) || !gen_pki(dir_b.path()) {
            eprintln!("skipping cert_hot_reload_serves_the_new_certificate: openssl unavailable");
            return;
        }
        let state = make_state(dir_a.path());
        let (server, shared) = serve(&server_tls(dir_a.path()), &state);
        let ca_a = dir_a.path().join("ca.crt");
        let ca_b = dir_b.path().join("ca.crt");
        let health = b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n";

        // Initially the server presents cert A.
        assert!(text(&request(server.addr, &ca_a, None, health)).starts_with("HTTP/1.1 200 OK"));

        // Hot-reload to cert B (a different CA).
        reload_server_config(&shared, &server_tls(dir_b.path()));

        // A CA-B client now succeeds…
        let rb = request(server.addr, &ca_b, None, health);
        assert!(
            text(&rb).starts_with("HTTP/1.1 200 OK"),
            "the reloaded cert B is served: {}",
            text(&rb)
        );
        // …and the old CA-A no longer validates the presented (B) certificate.
        assert!(
            request(server.addr, &ca_a, None, health).is_err(),
            "after the hot-reload, a CA-A-only client must fail to validate cert B"
        );
        drop(server);
    }
}
