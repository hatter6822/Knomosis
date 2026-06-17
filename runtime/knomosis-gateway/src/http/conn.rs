// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The **transport-neutral** HTTP/1.1 connection handler, generic over any
//! `Read + Write` stream — a plaintext `TcpStream` (the [`crate::http::plain`]
//! listener) or a `rustls` `StreamOwned` (the [`crate::http::tls`] listener).
//!
//! Both listeners run **one thread per connection** and hand the (timeout-
//! armed) stream to [`run_connection`], which owns the socket — so a stalled
//! reader/writer is bounded by the socket's read/write timeout on *both*
//! transports (closing OQ-GW-14 + OQ-GW-15 for plaintext too).  The body of
//! the loop is the same [`crate::http::handler`] gate → route → dispatch core
//! as every other request, so the two transports cannot diverge in security
//! behaviour.
//!
//! ## Why a hand-rolled HTTP/1.1 reader is safe here
//!
//! The gateway is the **sole HTTP processor on the connection** (it is the
//! listener / TLS terminator — no intermediary disagrees about message
//! boundaries), so the request-smuggling / desync surface is closed by
//! *construction*, and the reader is deliberately **strict**:
//!
//!   * **`Transfer-Encoding` is rejected** (`501`) — no chunked decoding, so
//!     the entire TE.CL / CL.TE desync class is impossible.
//!   * **A duplicate / comma-listed `Content-Length` is rejected** (`400`); a
//!     single valid one is read **exactly**, so the next keep-alive request
//!     always starts at the right byte offset.
//!   * **Obsolete folding is rejected** (`400`); request-line, header-line,
//!     header-count, and header-section size are all bounded.
//!   * **An overall per-request read deadline** ([`DeadlineStream`]) bounds the
//!     *cumulative* read time — the slow-loris case the per-read socket
//!     timeout alone cannot catch (a drip just under each per-read timeout
//!     keeps every read "productive" while the cumulative time is unbounded).
//!   * **Any framing ambiguity closes the connection** rather than guessing.
//!   * **`Expect: 100-continue`** (RFC 7231 §5.1.1) is honoured: the head and
//!     body are read in two steps, so the interim `100 Continue` is written
//!     *before* the (validated, bounded) body — a waiting client is never
//!     stalled; any *other* expectation is rejected `417`.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::events::stream::{run_one_stream, StreamRequest, StreamSlot};
use crate::http::handler::{self, log_request, route_request, Handled, RequestParts};
use crate::http::router::RouteOutcome;
use crate::observability::next_request_id;
use crate::problem::Problem;
use crate::state::AppState;

/// Per-connection socket read / write timeout — the per-read slow-loris
/// backstop + the SSE write deadline + the handshake bound.  The *cumulative*
/// per-request read time is additionally bounded by [`DeadlineStream`].
pub(crate) const CONNECTION_TIMEOUT: Duration = Duration::from_secs(10);

/// How long an accept loop sleeps when no connection is ready (the listener is
/// non-blocking so the loop can poll the shutdown flag).
const ACCEPT_POLL: Duration = Duration::from_millis(50);

/// An RAII reservation of one connection slot.  It tracks **two** counters:
/// the per-listener `cap` (bounded by `--max-connections` /
/// `--tls-max-connections` — the spawn-storm DoS guard), and the process-wide
/// `gauge` ([`crate::state::AppState::active_connections`]) that
/// [`crate::http::serve`] waits on to **drain** on shutdown.  The guard's
/// `Drop` decrements both, releasing the slot on every connection-thread exit
/// path (including a panic).
pub(crate) struct ConnGuard {
    cap: Arc<AtomicUsize>,
    gauge: Arc<AtomicUsize>,
}

impl ConnGuard {
    /// Reserve a slot, or `None` if the per-listener `cap` is already at `max`.
    fn try_acquire(cap: &Arc<AtomicUsize>, max: usize, gauge: &Arc<AtomicUsize>) -> Option<Self> {
        let prev = cap.fetch_add(1, Ordering::SeqCst);
        if prev >= max {
            cap.fetch_sub(1, Ordering::SeqCst);
            return None;
        }
        gauge.fetch_add(1, Ordering::SeqCst);
        Some(Self {
            cap: Arc::clone(cap),
            gauge: Arc::clone(gauge),
        })
    }
}

impl Drop for ConnGuard {
    fn drop(&mut self) {
        self.cap.fetch_sub(1, Ordering::SeqCst);
        self.gauge.fetch_sub(1, Ordering::SeqCst);
    }
}

/// The shared non-blocking accept loop, used by both the plaintext
/// ([`crate::http::plain`]) and TLS ([`crate::http::tls`]) listeners.  Each
/// iteration runs `pre_accept` (the TLS cert-reload hook; a no-op for
/// plaintext), accepts a connection under the per-listener `max_connections`
/// cap (a fresh local counter), incrementing the shared `gauge` for the drain,
/// and calls `on_connection(stream, guard)` — which spawns the per-connection
/// handler thread, the guard riding it so the slot releases on exit.  Exits
/// when `shutdown` is set.
pub(crate) fn accept_loop(
    listener: &TcpListener,
    shutdown: &AtomicBool,
    max_connections: usize,
    gauge: &Arc<AtomicUsize>,
    mut pre_accept: impl FnMut(),
    on_connection: impl Fn(TcpStream, ConnGuard),
) {
    let cap = Arc::new(AtomicUsize::new(0));
    let mut consecutive_errors = 0u32;
    while !shutdown.load(Ordering::Relaxed) {
        pre_accept();
        match listener.accept() {
            Ok((stream, _peer)) => {
                consecutive_errors = 0;
                let Some(guard) = ConnGuard::try_acquire(&cap, max_connections, gauge) else {
                    // Over the connection cap: close without serving (a TLS
                    // client could not read a plaintext message anyway).
                    let _ = stream.shutdown(Shutdown::Both);
                    continue;
                };
                on_connection(stream, guard);
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                consecutive_errors = 0;
                std::thread::sleep(ACCEPT_POLL);
            }
            Err(e) => {
                consecutive_errors = consecutive_errors.saturating_add(1);
                tracing::warn!(error = %e, consecutive_errors, "accept failed");
                let exp = consecutive_errors.saturating_sub(1).min(5);
                std::thread::sleep(Duration::from_millis(100u64 << exp));
            }
        }
    }
}

/// Arm a freshly-accepted `TcpStream` for the synchronous connection handler:
/// `TCP_NODELAY`, blocking mode (required by the `rustls` adapter), and the
/// per-read / per-write socket timeouts.
pub(crate) fn arm_socket(stream: &TcpStream) {
    let _ = stream.set_nodelay(true);
    let _ = stream.set_nonblocking(false);
    let _ = stream.set_read_timeout(Some(CONNECTION_TIMEOUT));
    let _ = stream.set_write_timeout(Some(CONNECTION_TIMEOUT));
}

/// Maximum request-line length (method + target + version).  A longer line is
/// `414 URI Too Long`.
const MAX_REQUEST_LINE_BYTES: usize = 8 * 1024;

/// Maximum single header-line length.  A longer line is `431`.
const MAX_HEADER_LINE_BYTES: usize = 8 * 1024;

/// Maximum number of request header lines.  More is `431`.
const MAX_HEADERS: usize = 100;

/// Maximum total request-header-section size.  Larger is `431`.
const MAX_HEADER_SECTION_BYTES: usize = 64 * 1024;

/// Overall wallclock budget for reading **one** complete request (head + body).
/// Enforced by [`DeadlineStream`] regardless of how the bytes are dripped.
pub(crate) const REQUEST_READ_DEADLINE: Duration = Duration::from_secs(30);

/// A `Read + Write` wrapper that fails **reads** once a per-request wallclock
/// deadline passes — the slow-loris bound the per-read socket timeout alone
/// cannot provide.  Because every buffer refill (every socket read) goes
/// through here, a drip-feed that evades the per-read timeout is still bounded
/// to the deadline.  **Writes pass through unbounded** — an SSE write is
/// bounded by the socket's *write* timeout instead, and the read deadline must
/// never abort a long-lived stream's writes.
pub(crate) struct DeadlineStream<S> {
    inner: S,
    deadline: Instant,
}

impl<S> DeadlineStream<S> {
    /// Wrap `inner`; the deadline starts expired and is reset per request by
    /// [`run_connection`].
    pub(crate) fn new(inner: S) -> Self {
        Self {
            inner,
            deadline: Instant::now(),
        }
    }
}

impl<S: Read> Read for DeadlineStream<S> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if Instant::now() >= self.deadline {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "request read deadline exceeded",
            ));
        }
        self.inner.read(buf)
    }
}

impl<S: Write> Write for DeadlineStream<S> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.inner.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// Run one accepted connection's keep-alive request loop until it closes,
/// errors, is evicted, or `shutdown` is set.  Each request resets the
/// [`DeadlineStream`]'s read deadline, so the cumulative read time per request
/// is bounded (slow-loris).
pub(crate) fn run_connection<S: Read + Write>(
    reader: &mut BufReader<DeadlineStream<S>>,
    socket: Option<&TcpStream>,
    state: &AppState,
    shutdown: &AtomicBool,
) {
    loop {
        if shutdown.load(Ordering::Relaxed) {
            return;
        }
        let request_id = next_request_id();
        let start = Instant::now();
        // Reset the overall per-request read deadline (slow-loris bound).
        reader.get_mut().deadline = Instant::now() + REQUEST_READ_DEADLINE;
        let head = match read_head(reader, state.config.max_frame_size) {
            Ok(head) => head,
            // A clean EOF (idle keep-alive closed) or a socket error / timeout
            // (incl. the read-deadline breach): close quietly, nothing owed.
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
                let _ = write_response(reader.get_mut(), &outcome, false, false);
                return;
            }
        };
        // The body is read LAZILY by `serve_parsed` (inside the handler's
        // body closure, invoked only *after* the auth + rate gates pass), so an
        // unauthenticated / rate-limited request never makes the gateway buffer
        // its (up to `--max-frame-size`) body — the documented gate-before-body
        // ordering + DoS boundary.  `Expect: 100-continue` is likewise honoured
        // post-gate, just before the body is read.
        if matches!(
            serve_parsed(reader, socket, state, &head, &request_id, start),
            ConnControl::Close
        ) {
            return;
        }
    }
}

/// Write the interim `100 Continue` status line (RFC 7231 §5.1.1).
fn write_continue<W: Write>(w: &mut W) -> std::io::Result<()> {
    w.write_all(b"HTTP/1.1 100 Continue\r\n\r\n")?;
    w.flush()
}

/// Whether the connection loop should keep the connection alive or close it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ConnControl {
    /// Loop for another request on this connection.
    KeepAlive,
    /// Close the connection.
    Close,
}

/// Serve one parsed request **head** through the shared request core, reading
/// the body **lazily** (only after the gate passes), then write the response
/// (or hijack the connection for SSE).  Returns whether the connection may be
/// kept alive.
///
/// **Gate-before-body (DoS boundary).** The body is read inside the handler's
/// gated closure, so an unauthenticated / rate-limited request never makes the
/// gateway buffer its (up to `--max-frame-size`) body.  When the gate denies a
/// request that carried a body, that body is left unread — so the connection
/// **cannot** be kept alive (the unread bytes would desync the next keep-alive
/// request); the response is sent with `Connection: close`.
fn serve_parsed<S: Read + Write>(
    reader: &mut BufReader<DeadlineStream<S>>,
    socket: Option<&TcpStream>,
    state: &AppState,
    head: &RequestHead,
    request_id: &str,
    start: Instant,
) -> ConnControl {
    let parts = RequestParts {
        method: &head.method,
        path: &head.path,
        query: &head.query,
        auth_header: head.authorization.as_deref(),
        content_type: head.content_type.as_deref(),
        if_none_match: head.if_none_match.as_deref(),
        idempotency_key: head.idempotency_key.as_deref(),
        last_event_id: head.last_event_id.as_deref(),
        origin: head.origin.as_deref(),
    };
    // HEAD is GET-routed (the router maps it), but the response carries no body
    // (RFC 9110 §9.3.2) and an SSE stream is never hijacked for a HEAD.
    let is_head = head.method == "HEAD";
    let keep_alive = head.keep_alive;
    let content_length = head.content_length;
    let expect_continue = head.expect_continue;
    let routed = route_request(&parts);

    // The gated body reader: invoked by `handler::handle` ONLY after the auth +
    // rate gates pass.  It honours `Expect: 100-continue` (RFC 7231 §5.1.1) just
    // before reading (so the interim `100 Continue` is sent only once we commit
    // to the body), then reads the validated, bounded body.  `body_read` /
    // `body_failed` let the caller decide whether the connection can survive.
    let mut body_read = false;
    let mut body_failed = false;
    let read_body_fn = |_max: usize| -> Result<Vec<u8>, RouteOutcome> {
        body_read = true;
        if expect_continue && content_length > 0 && write_continue(reader.get_mut()).is_err() {
            body_failed = true;
            return Err(body_unreadable_outcome());
        }
        read_body(reader, content_length).map_err(|_| {
            body_failed = true;
            body_unreadable_outcome()
        })
    };
    let handled = handler::handle(&routed, &parts, read_body_fn, state, request_id);

    // A request denied (or routed to SSE) before its body was read, OR whose
    // body read failed mid-stream, leaves the connection unsafe to keep alive.
    let must_close = body_failed || (!body_read && content_length > 0);

    match handled {
        Handled::Respond(outcome) => {
            log_request(
                &head.method,
                &head.path,
                outcome.status,
                start.elapsed(),
                request_id,
            );
            let keep = keep_alive && !must_close;
            if write_response(reader.get_mut(), &outcome, keep, is_head).is_err() {
                return ConnControl::Close;
            }
            if keep {
                ConnControl::KeepAlive
            } else {
                ConnControl::Close
            }
        }
        // A HEAD on the SSE endpoint returns the stream's response headers with
        // no body and **no hijack** (the GET would stream indefinitely).
        Handled::Stream { cors_headers, .. } if is_head => {
            log_request(&head.method, &head.path, 200, start.elapsed(), request_id);
            let stream_head = stream_head_outcome(&cors_headers, request_id);
            // A GET stream carries no request body, so keep-alive is unaffected.
            if write_response(reader.get_mut(), &stream_head, keep_alive, true).is_err() {
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
            cors_headers,
        } => {
            log_request(&head.method, &head.path, 200, start.elapsed(), request_id);
            serve_stream(
                reader.get_mut(),
                socket,
                state,
                StreamArgs {
                    since,
                    types: &types,
                    last_event_id: last_event_id.as_deref(),
                    cors_headers: &cors_headers,
                },
                request_id,
            );
            // An SSE stream owns the connection until it closes.
            ConnControl::Close
        }
    }
}

/// The `400` response when the request body could not be read off the wire (a
/// truncated body, a socket error, or the read-deadline breach during the
/// gated body read).  The connection is closed afterwards (`must_close`).
fn body_unreadable_outcome() -> RouteOutcome {
    Problem::new("bad-request", "Bad Request", 400)
        .with_detail("the request body could not be read".to_string())
        .into_outcome()
}

/// Build the headers-only response a HEAD on `GET /v1/events/stream` returns:
/// the `200 text/event-stream` head a GET would open (with `Cache-Control:
/// no-store`, the anti-buffering hint, any browser-CORS headers, and the
/// request id), but no streamed body.
fn stream_head_outcome(cors_headers: &[(&'static str, String)], request_id: &str) -> RouteOutcome {
    let mut outcome = RouteOutcome::event_stream_head()
        .with_header("Cache-Control", "no-store")
        .with_header("X-Accel-Buffering", "no");
    for (name, value) in cors_headers {
        outcome = outcome.with_header(name, value.clone());
    }
    handler::finalize(outcome, request_id)
}

/// The per-request SSE inputs [`serve_stream`] forwards into a [`StreamRequest`]
/// (bundled to stay within the argument-count budget).  All fields are `Copy`
/// (references + small scalars), so the bundle is too.
#[derive(Clone, Copy)]
struct StreamArgs<'a> {
    /// The `since` cursor (absent ⇒ `Last-Event-ID` / live tail).
    since: Option<u64>,
    /// The repeatable event-type filter.
    types: &'a [String],
    /// The `Last-Event-ID` header value, if present.
    last_event_id: Option<&'a str>,
    /// The browser-CORS headers to stamp on the SSE head (+ the `503`s).
    cors_headers: &'a [(&'static str, String)],
}

/// Drive a live SSE stream over the hijacked writer, reusing the exact fan-out
/// core ([`run_one_stream`]) and capacity bound ([`StreamSlot`]).  Answers
/// `503` (a raw HTTP response) when events streaming is disabled or the stream
/// cap is reached — both carrying any browser-CORS headers so a cross-origin
/// `EventSource` can read the rejection.  Before streaming, the per-record SSE
/// write deadline (`--sse-write-timeout-ms`) is applied to the socket (a longer
/// bound than the per-request `CONNECTION_TIMEOUT`, tuned for live tails).
fn serve_stream<W: Write>(
    writer: &mut W,
    socket: Option<&TcpStream>,
    state: &AppState,
    args: StreamArgs,
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
            args.cors_headers,
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
            args.cors_headers,
            request_id,
        );
        return;
    };
    // Apply the configured per-record SSE write deadline to the socket (a
    // stalled browser that stops reading drops within this bound rather than
    // pinning the stream thread).  Best-effort: a clone/setsockopt failure
    // leaves the `arm_socket` `CONNECTION_TIMEOUT` write timeout in force.
    if let Some(socket) = socket {
        let _ = socket.set_write_timeout(Some(Duration::from_millis(
            state.config.sse.write_timeout_ms,
        )));
    }
    // Bind deref'd references so the `StreamRequest` field types line up.
    let fanout: &crate::events::fanout::FanoutState = fanout;
    let sse: &crate::config::SseConfig = &state.config.sse;
    let shutdown: &AtomicBool = &state.shutdown;
    let request = StreamRequest {
        fanout,
        since: args.since,
        types: args.types,
        last_event_id: args.last_event_id,
        sse,
        shutdown,
        request_id,
        cors_headers: args.cors_headers,
    };
    let end = run_one_stream(writer, &request);
    tracing::info!(request_id, ?end, "sse stream closed");
    // `_slot` drops here → `active_streams` is decremented.
}

// ---------------------------------------------------------------------------
// Strict HTTP/1.1 request reader
// ---------------------------------------------------------------------------

/// A fully-read, framing-unambiguous request — the head combined with its
/// (eagerly-read) body.  Used **only by the parser tests** (the live path reads
/// the body lazily, post-gate, via [`serve_parsed`]'s closure).
#[cfg(test)]
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
    origin: Option<String>,
    keep_alive: bool,
}

/// The parsed request **head** (request line + headers + the validated framing
/// decision), read *before* the body so the connection loop can gate an
/// `Expect: 100-continue` body behind a `100 Continue` (RFC 7231 §5.1.1).
struct RequestHead {
    method: String,
    path: String,
    query: String,
    authorization: Option<String>,
    content_type: Option<String>,
    if_none_match: Option<String>,
    idempotency_key: Option<String>,
    last_event_id: Option<String>,
    origin: Option<String>,
    keep_alive: bool,
    /// The validated body length (already in `0 ..= max_body`).
    content_length: usize,
    /// Whether the client gated the body behind `Expect: 100-continue`.
    expect_continue: bool,
}

impl RequestHead {
    /// Combine this head with its (already-read) `body` into a full
    /// [`ParsedRequest`] — **test-only** (the live path reads the body lazily).
    #[cfg(test)]
    fn into_request(self, body: Vec<u8>) -> ParsedRequest {
        ParsedRequest {
            method: self.method,
            path: self.path,
            query: self.query,
            body,
            authorization: self.authorization,
            content_type: self.content_type,
            if_none_match: self.if_none_match,
            idempotency_key: self.idempotency_key,
            last_event_id: self.last_event_id,
            origin: self.origin,
            keep_alive: self.keep_alive,
        }
    }
}

/// Why [`read_head`] did not yield a request.
#[derive(Debug)]
enum RequestError {
    /// A clean EOF before any request bytes — a closed idle keep-alive.
    ConnectionClosed,
    /// A socket I/O error / timeout (incl. the read-deadline breach), or a
    /// truncated request — close quietly.
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

/// Read one strict HTTP/1.1 request **head**: the request line, the header
/// section, and the validated framing decision (`Content-Length` bounded by
/// `max_body`).  The body is read separately by the caller (so an
/// `Expect: 100-continue` body can be gated behind a `100 Continue`).
fn read_head<R: BufRead>(reader: &mut R, max_body: usize) -> Result<RequestHead, RequestError> {
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

    let keep_alive = match version {
        _ if headers.connection_close => false,
        Version::Http11 => true,
        Version::Http10 => headers.connection_keep_alive,
    };

    Ok(RequestHead {
        method,
        path,
        query,
        authorization: headers.authorization,
        content_type: headers.content_type,
        if_none_match: headers.if_none_match,
        idempotency_key: headers.idempotency_key,
        last_event_id: headers.last_event_id,
        origin: headers.origin,
        keep_alive,
        content_length,
        expect_continue: headers.expect_continue,
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
/// value header wins.
// A flat parse-accumulator of independent flags (not a state machine), so the
// >3-bool lint does not apply.
#[allow(clippy::struct_excessive_bools)]
#[derive(Default)]
struct HeaderSet {
    authorization: Option<String>,
    content_type: Option<String>,
    if_none_match: Option<String>,
    idempotency_key: Option<String>,
    last_event_id: Option<String>,
    origin: Option<String>,
    content_length: Option<u64>,
    transfer_encoding: bool,
    connection_close: bool,
    connection_keep_alive: bool,
    /// The client sent `Expect: 100-continue` (RFC 7231 §5.1.1): the body must
    /// be gated behind an interim `100 Continue`.
    expect_continue: bool,
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
    } else if name.eq_ignore_ascii_case("origin") {
        set_first(&mut headers.origin, value);
    } else if name.eq_ignore_ascii_case("expect") {
        // RFC 7231 §5.1.1: recognise the `100-continue` expectation (a
        // comma-list); any *other* expectation is rejected `417` (the strict,
        // spec-compliant behaviour — the client knows we could not satisfy it).
        let mut saw_continue = false;
        for token in value.split(',') {
            let token = token.trim();
            if token.eq_ignore_ascii_case("100-continue") {
                saw_continue = true;
            } else if !token.is_empty() {
                return Err(reject(
                    417,
                    "Expectation Failed",
                    "the only supported expectation is 100-continue",
                ));
            }
        }
        headers.expect_continue = saw_continue;
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
/// short read (the client hung up) or the read-deadline breach is an
/// [`RequestError::Io`].
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
    /// A socket I/O error, the read-deadline breach, or EOF mid-line.
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
pub(crate) fn write_response<W: Write>(
    w: &mut W,
    outcome: &RouteOutcome,
    keep_alive: bool,
    head_only: bool,
) -> std::io::Result<()> {
    write!(
        w,
        "HTTP/1.1 {} {}\r\n",
        outcome.status,
        reason_phrase(outcome.status)
    )?;
    write!(w, "Content-Type: {}\r\n", outcome.content_type)?;
    // The `Content-Length` is always that of the GET body — for a HEAD the
    // header set is identical to GET (RFC 9110 §9.3.2), only the body is
    // omitted, so a client can read the size without the payload.
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
    if !head_only {
        w.write_all(outcome.body.as_bytes())?;
    }
    w.flush()
}

/// Build + write a framing-time problem (`503` events / over-cap) as a raw
/// HTTP/1.1 response, carrying the `X-Request-Id` (via [`handler::finalize`]),
/// any browser-CORS headers, and an optional `Retry-After`.
#[allow(clippy::too_many_arguments)] // a thin one-shot writer; bundling would obscure it
fn write_raw_problem<W: Write>(
    w: &mut W,
    status: u16,
    slug: &str,
    title: &str,
    detail: &str,
    retry_after_secs: Option<u64>,
    cors_headers: &[(&'static str, String)],
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
    for (name, value) in cors_headers {
        outcome = outcome.with_header(name, value.clone());
    }
    write_response(w, &outcome, false, false)
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
        417 => "Expectation Failed",
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
        417 => "expectation-failed",
        431 => "request-header-fields-too-large",
        501 => "not-implemented",
        505 => "http-version-not-supported",
        _ => "bad-request",
    }
}

#[cfg(test)]
mod tests {
    use super::{
        read_body, read_head, reason_phrase, reject_slug, write_response, ConnControl,
        DeadlineStream, RequestError, Version,
    };
    use crate::http::RouteOutcome;
    use std::io::{BufReader, Read};
    use std::time::{Duration, Instant};

    /// Parse a full request (head + body) from a byte slice — the same
    /// `read_head` → `read_body` sequence the connection loop runs (minus the
    /// `Expect: 100-continue` write).  The reader is generic over `BufRead`, so
    /// the strict HTTP/1.1 parser is unit-testable with no socket.
    fn parse(raw: &[u8], max_body: usize) -> Result<super::ParsedRequest, RequestError> {
        let mut reader = BufReader::new(raw);
        let head = read_head(&mut reader, max_body)?;
        let body = read_body(&mut reader, head.content_length)?;
        Ok(head.into_request(body))
    }

    /// Read just the head (for `Expect`/framing assertions).
    fn head(raw: &[u8], max_body: usize) -> Result<super::RequestHead, RequestError> {
        let mut reader = BufReader::new(raw);
        read_head(&mut reader, max_body)
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
                    Idempotency-Key: idem-123\r\n\
                    Origin: https://app.example.com\r\n\
                    Last-Event-ID: 5.0\r\n\r\n";
        let req = parse(raw, 1024).unwrap();
        assert_eq!(req.path, "/v1/pools/161");
        assert_eq!(req.query, "resource=1");
        assert_eq!(req.authorization.as_deref(), Some("Bearer tok"));
        assert_eq!(req.if_none_match.as_deref(), Some("W/\"7-42\""));
        assert_eq!(req.idempotency_key.as_deref(), Some("idem-123"));
        assert_eq!(req.origin.as_deref(), Some("https://app.example.com"));
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
    fn expect_100_continue_is_recognised_and_unknown_expectations_rejected() {
        let h = head(
            b"POST /v1/actions HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\nbody",
            1024,
        )
        .unwrap();
        assert!(h.expect_continue);
        assert_eq!(h.content_length, 4);
        // The case-insensitive scheme is accepted.
        let h = head(
            b"POST / HTTP/1.1\r\nExpect: 100-Continue\r\nContent-Length: 0\r\n\r\n",
            1024,
        )
        .unwrap();
        assert!(h.expect_continue);
        // An UNKNOWN expectation is rejected 417 (spec-compliant strict mode).
        assert!(matches!(
            parse(b"GET / HTTP/1.1\r\nExpect: other-thing\r\n\r\n", 1024),
            Err(RequestError::Reject { status: 417, .. })
        ));
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
        let close = parse(b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n", 16).unwrap();
        assert!(!close.keep_alive);
        let h10 = parse(b"GET / HTTP/1.0\r\n\r\n", 16).unwrap();
        assert!(!h10.keep_alive);
        let h10_ka = parse(b"GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", 16).unwrap();
        assert!(h10_ka.keep_alive);
    }

    #[test]
    fn eof_and_truncation() {
        assert!(matches!(
            parse(b"", 16),
            Err(RequestError::ConnectionClosed)
        ));
        let raw = b"POST /v1/actions HTTP/1.1\r\nContent-Length: 5\r\n\r\nhi";
        assert!(matches!(parse(raw, 16), Err(RequestError::Io)));
    }

    #[test]
    fn deadline_stream_fails_reads_once_expired() {
        // Reads succeed before the deadline, fail (TimedOut) after — the
        // mechanism that bounds the cumulative request-read time.
        let mut s = DeadlineStream::new(&b"hello"[..]);
        s.deadline = Instant::now() + Duration::from_secs(60);
        let mut buf = [0u8; 5];
        assert_eq!(s.read(&mut buf).unwrap(), 5);
        // Now expire it: the next read errors regardless of available bytes.
        let mut s = DeadlineStream::new(&b"hello"[..]);
        s.deadline = Instant::now()
            .checked_sub(Duration::from_secs(1))
            .expect("a deadline one second in the past");
        assert_eq!(
            s.read(&mut buf).unwrap_err().kind(),
            std::io::ErrorKind::TimedOut
        );
    }

    #[test]
    fn writes_a_framed_response() {
        let outcome =
            RouteOutcome::json(200, r#"{"ok":true}"#.to_string()).with_header("ETag", "W/\"7-42\"");
        let mut buf = Vec::new();
        write_response(&mut buf, &outcome, true, false).unwrap();
        let text = String::from_utf8(buf).unwrap();
        assert!(text.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(text.contains("Content-Type: application/json\r\n"));
        assert!(text.contains("Content-Length: 11\r\n"));
        assert!(text.contains("ETag: W/\"7-42\"\r\n"));
        assert!(text.contains("Connection: keep-alive\r\n"));
        assert!(text.ends_with("\r\n\r\n{\"ok\":true}"));
    }

    #[test]
    fn head_only_omits_body_but_keeps_content_length() {
        // A HEAD response carries the GET's status + headers + Content-Length
        // (RFC 9110 §9.3.2) but NO body, so a keep-alive HEAD does not desync.
        let outcome = RouteOutcome::json(200, r#"{"ok":true}"#.to_string());
        let mut buf = Vec::new();
        write_response(&mut buf, &outcome, true, true).unwrap();
        let text = String::from_utf8(buf).unwrap();
        assert!(
            text.contains("Content-Length: 11\r\n"),
            "GET body length kept"
        );
        assert!(
            text.ends_with("\r\n\r\n"),
            "no body after the head: {text:?}"
        );
        assert!(!text.contains("\"ok\":true"), "the body must be omitted");
    }

    #[test]
    fn response_writer_blocks_header_injection() {
        let outcome =
            RouteOutcome::json(200, "{}".to_string()).with_header("X-Evil", "a\r\nInjected: 1");
        let mut buf = Vec::new();
        write_response(&mut buf, &outcome, false, false).unwrap();
        let text = String::from_utf8(buf).unwrap();
        assert!(!text.contains("Injected"));
        assert!(text.contains("Connection: close\r\n"));
    }

    #[test]
    fn reason_and_slug_tables() {
        assert_eq!(reason_phrase(200), "OK");
        assert_eq!(reason_phrase(503), "Service Unavailable");
        assert_eq!(reason_phrase(417), "Expectation Failed");
        assert_eq!(reason_phrase(599), "Status");
        assert_eq!(reject_slug(413), "payload-too-large");
        assert_eq!(reject_slug(417), "expectation-failed");
        assert_eq!(reject_slug(999), "bad-request");
    }

    #[test]
    fn enum_smoke() {
        assert_ne!(ConnControl::KeepAlive, ConnControl::Close);
        assert_ne!(Version::Http10, Version::Http11);
    }
}
