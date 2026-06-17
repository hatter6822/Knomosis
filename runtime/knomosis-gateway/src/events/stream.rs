// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G3.5 `GET /v1/events/stream` HTTP wiring — the live Server-Sent-Events
//! endpoint atop the G3.4 fan-out.
//!
//! Unlike every other endpoint (which returns a `RouteOutcome` the IO shell
//! writes), an SSE stream is open-ended, so it **hijacks the connection**:
//! [`serve`] takes the `tiny_http::Request`, reserves a stream slot (bounded
//! by `--sse` `max_streams`), extracts the raw socket with
//! `Request::into_writer`, and runs the per-client dispatch on **its own
//! thread** — returning the handler-pool worker immediately so a long-lived
//! stream never starves request processing.
//!
//! Resume precedence (§3.5): the `Last-Event-ID` header over the `since`
//! query (decoded by [`parse_resume`]); the ring then classifies it
//! ([`classify_resume`]) into a live stream, a `behind` steer-to-backfill,
//! or a `truncated` error.  `Cache-Control: no-store` and the auth gate (run
//! before the hijack, in the IO shell) round out the contract.

use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::events::fanout::dispatch::{run_stream, write_stream_error, StreamConfig, StreamEnd};
use crate::events::fanout::resume::{classify_resume, parse_resume, ResumeAction};
use crate::events::fanout::FanoutState;
use crate::observability::REQUEST_ID_HEADER;
use crate::problem::Problem;
use crate::state::AppState;

/// The per-client ring poll cadence while a stream is caught up.
const STREAM_POLL: Duration = Duration::from_millis(100);

/// Serve `GET /v1/events/stream`, consuming the request (the auth + rate
/// gates already ran in the IO shell).  Answers `503` when events streaming
/// is disabled or the stream cap is reached; otherwise hijacks the
/// connection and runs the stream on its own thread.
pub fn serve(
    request: tiny_http::Request,
    state: &AppState,
    since: Option<u64>,
    types: Vec<String>,
    last_event_id: Option<String>,
    request_id: &str,
) {
    let Some(fanout) = &state.fanout else {
        respond_problem(
            request,
            "events-unavailable",
            "Events Unavailable",
            503,
            "event streaming is disabled: the gateway was started without \
             --event-subscribe-addr",
            None,
            request_id,
        );
        return;
    };
    // Reserve a stream slot (RAII; released when the guard drops).  At the
    // configured capacity → 503 + a short `Retry-After`.
    let Some(slot) = StreamSlot::try_acquire(&state.active_streams, state.config.sse.max_streams)
    else {
        respond_problem(
            request,
            "too-many-streams",
            "Too Many Streams",
            503,
            "the gateway is at its configured SSE stream capacity; retry shortly",
            Some(1000),
            request_id,
        );
        return;
    };

    // Slot reserved.  Hijack the connection and run the stream on its own
    // thread; the handler-pool worker returns immediately.
    let fanout = Arc::clone(fanout);
    let shutdown = Arc::clone(&state.shutdown);
    let sse = state.config.sse;
    let request_id = request_id.to_string();
    let mut writer = request.into_writer();
    let spawned = std::thread::Builder::new()
        .name("knx-gw-sse".to_string())
        .spawn(move || {
            // The slot guard rides the stream thread; its `Drop` releases the
            // reservation on every exit path (clean close, eviction, fault).
            let _slot = slot;
            let request = StreamRequest {
                fanout: &fanout,
                since,
                types: &types,
                last_event_id: last_event_id.as_deref(),
                sse: &sse,
                shutdown: &shutdown,
                request_id: &request_id,
            };
            let end = run_one_stream(&mut writer, &request);
            tracing::info!(request_id, ?end, "sse stream closed");
        });
    if spawned.is_err() {
        // The thread could not be spawned: the closure — and with it the slot
        // guard *and* the connection writer — is dropped, releasing the
        // reservation and closing the socket; the client reconnects.
        tracing::error!("failed to spawn an SSE stream thread");
    }
}

/// An RAII reservation of one live-SSE-stream slot, bounded by the configured
/// `--sse` `max_streams`.  [`StreamSlot::try_acquire`] increments the shared
/// `active_streams` counter and returns the guard, or `None` when the cap is
/// already reached (the caller answers `503`); the guard's `Drop` decrements
/// the counter, so a slot is released on **every** exit path — a clean close,
/// an eviction, a fault, *or* a failed thread spawn.  Shared by the
/// `tiny_http` ([`serve`]) and native-TLS ([`crate::http::tls`]) stream paths
/// so both honour the same single capacity bound.
pub(crate) struct StreamSlot {
    active: Arc<AtomicUsize>,
}

impl StreamSlot {
    /// Try to reserve a slot.  A `fetch_add` whose prior value is already at
    /// (or above) `max` is over budget, so it is immediately undone and `None`
    /// returned; otherwise the reservation stands and the guard is returned.
    /// A transient overshoot during concurrent rejects is corrected by the
    /// matching `fetch_sub` (lock-free admission via the atomic counter).
    pub(crate) fn try_acquire(active: &Arc<AtomicUsize>, max: usize) -> Option<Self> {
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

impl Drop for StreamSlot {
    fn drop(&mut self) {
        self.active.fetch_sub(1, Ordering::SeqCst);
    }
}

/// The per-stream inputs (bundled to keep [`run_one_stream`] within the
/// argument-count budget): the shared ring, the resume request, the SSE
/// tunables, the shutdown flag, and the correlation id.  `pub(crate)` so the
/// native-TLS front-end ([`crate::http::tls`]) can drive the same streaming
/// core over its hijacked `rustls` writer.
pub(crate) struct StreamRequest<'a> {
    /// The shared fan-out ring + decode-fault flag.
    pub(crate) fanout: &'a FanoutState,
    /// The `since` cursor (absent ⇒ `Last-Event-ID` / live tail).
    pub(crate) since: Option<u64>,
    /// The repeatable event-type filter (empty = all).
    pub(crate) types: &'a [String],
    /// The `Last-Event-ID` header value, if present.
    pub(crate) last_event_id: Option<&'a str>,
    /// The SSE fan-out tunables (lag bound, heartbeat, poll cadence).
    pub(crate) sse: &'a crate::config::SseConfig,
    /// The process-wide shutdown flag (a clean `server_shutdown` close).
    pub(crate) shutdown: &'a AtomicBool,
    /// The per-request correlation id (stamped on the SSE head).
    pub(crate) request_id: &'a str,
}

/// Write the SSE response head, classify the resume point, then either
/// stream live records or emit the terminal `behind` / `truncated` error.
/// `pub(crate)` so both the `tiny_http` ([`serve`]) and native-TLS
/// ([`crate::http::tls`]) front-ends share one streaming implementation.
pub(crate) fn run_one_stream<W: Write>(writer: &mut W, request: &StreamRequest) -> StreamEnd {
    if write_sse_head(writer, request.request_id).is_err() {
        return StreamEnd::Disconnected; // the client hung up before we could respond
    }
    let point = parse_resume(request.last_event_id, request.since);
    // `upstream_oldest = None`: the SSE path steers a behind-ring cursor to
    // the backfill (`behind`), never an SSE `truncated` (finding #7).
    let action = {
        let ring = request.fanout.ring();
        classify_resume(&ring, point, None)
    };
    match action {
        ResumeAction::Stream(cursor) => {
            let config = StreamConfig {
                max_client_lag: request.sse.max_client_lag,
                heartbeat: Duration::from_secs(request.sse.heartbeat_secs),
                poll: STREAM_POLL,
            };
            run_stream(
                writer,
                request.fanout,
                cursor,
                request.types,
                &config,
                request.shutdown,
            )
        }
        ResumeAction::Behind { oldest_seq } => {
            let _ = write_stream_error(writer, "behind", Some(oldest_seq));
            StreamEnd::Evicted
        }
        ResumeAction::Truncated => {
            let _ = write_stream_error(writer, "truncated", None);
            StreamEnd::Evicted
        }
    }
}

/// Write the raw HTTP/1.1 SSE response head over the hijacked socket: a
/// `200` with `text/event-stream`, `Cache-Control: no-store`,
/// `X-Accel-Buffering: no` (defeats intermediary buffering), and the
/// `X-Request-Id` correlation token.  No `Content-Length` — the body streams
/// until the connection closes.
fn write_sse_head<W: Write>(writer: &mut W, request_id: &str) -> std::io::Result<()> {
    write!(
        writer,
        "HTTP/1.1 200 OK\r\n\
         Content-Type: text/event-stream\r\n\
         Cache-Control: no-store\r\n\
         Connection: keep-alive\r\n\
         X-Accel-Buffering: no\r\n\
         X-Request-Id: {request_id}\r\n\
         \r\n"
    )?;
    writer.flush()
}

/// Answer a non-stream error (`503`) with a normal `application/problem+json`
/// response (no hijack), carrying the `X-Request-Id` correlation token and
/// optionally a `Retry-After`.
fn respond_problem(
    request: tiny_http::Request,
    type_suffix: &str,
    title: &str,
    status: u16,
    detail: &str,
    retry_after_ms: Option<u64>,
    request_id: &str,
) {
    let mut problem = Problem::new(type_suffix, title, status)
        .with_detail(detail.to_string())
        .with_instance(request_id.to_string());
    if let Some(ms) = retry_after_ms {
        problem = problem.with_retry_after_ms(ms);
    }
    let outcome = problem.into_outcome();
    let mut response =
        tiny_http::Response::from_string(outcome.body).with_status_code(outcome.status);
    if let Ok(header) =
        tiny_http::Header::from_bytes(b"Content-Type".as_ref(), outcome.content_type.as_bytes())
    {
        response = response.with_header(header);
    }
    if let Ok(header) =
        tiny_http::Header::from_bytes(REQUEST_ID_HEADER.as_bytes(), request_id.as_bytes())
    {
        response = response.with_header(header);
    }
    if let Some(ms) = retry_after_ms {
        let secs = ms.div_ceil(1000).max(1);
        if let Ok(header) =
            tiny_http::Header::from_bytes(b"Retry-After".as_ref(), secs.to_string().as_bytes())
        {
            response = response.with_header(header);
        }
    }
    let _ = request.respond(response);
}
