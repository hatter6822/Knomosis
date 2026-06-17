// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G3.5 `GET /v1/events/stream` streaming core — the live Server-Sent-Events
//! engine atop the G3.4 fan-out.
//!
//! Unlike every other endpoint (which returns a `RouteOutcome` the IO shell
//! writes), an SSE stream is open-ended, so the [`crate::http::conn`] handler
//! **hijacks the connection** and hands the raw (timeout-armed) socket writer
//! to [`run_one_stream`] on its own thread.  This module owns the
//! transport-neutral streaming logic — the response head, resume
//! classification, and the per-client dispatch — driven identically over a
//! plaintext `TcpStream` and a `rustls` `StreamOwned`.
//!
//! Resume precedence (§3.5): the `Last-Event-ID` header over the `since`
//! query (decoded by [`parse_resume`]); the ring then classifies it
//! ([`classify_resume`]) into a live stream, a `behind` steer-to-backfill,
//! or a `truncated` error.  `Cache-Control: no-store`, any browser-CORS
//! headers, and the auth gate (run before the hijack, in the shared core)
//! round out the contract.

use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::events::fanout::dispatch::{run_stream, write_stream_error, StreamConfig, StreamEnd};
use crate::events::fanout::resume::{classify_resume, parse_resume, ResumeAction};
use crate::events::fanout::FanoutState;

/// The per-client ring poll cadence while a stream is caught up.
const STREAM_POLL: Duration = Duration::from_millis(100);

/// An RAII reservation of one live-SSE-stream slot, bounded by the configured
/// `--sse` `max_streams`.  [`StreamSlot::try_acquire`] increments the shared
/// `active_streams` counter and returns the guard, or `None` when the cap is
/// already reached (the caller answers `503`); the guard's `Drop` decrements
/// the counter, so a slot is released on **every** exit path — a clean close,
/// an eviction, a fault, *or* a failed thread spawn.  Acquired by
/// [`crate::http::conn`]'s stream path (over either transport) so both honour
/// the same single capacity bound.
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
/// tunables, the shutdown flag, the correlation id, and any browser-CORS
/// headers.  `pub(crate)` so [`crate::http::conn`] can drive the same
/// streaming core over either transport's hijacked writer.
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
    /// Browser-CORS response headers to stamp on the SSE head (empty when CORS
    /// is disabled or the origin is not allowed).
    pub(crate) cors_headers: &'a [(&'static str, String)],
}

/// Write the SSE response head, classify the resume point, then either
/// stream live records or emit the terminal `behind` / `truncated` error.
/// `pub(crate)` so [`crate::http::conn`]'s stream path shares one streaming
/// implementation across both transports.
pub(crate) fn run_one_stream<W: Write>(writer: &mut W, request: &StreamRequest) -> StreamEnd {
    if write_sse_head(writer, request.request_id, request.cors_headers).is_err() {
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
/// `X-Accel-Buffering: no` (defeats intermediary buffering), the
/// `X-Request-Id` correlation token, and any browser-CORS headers.  No
/// `Content-Length` — the body streams until the connection closes.  A
/// CORS header carrying a control character is skipped (response-splitting
/// guard, defensive — the gateway controls these values).
fn write_sse_head<W: Write>(
    writer: &mut W,
    request_id: &str,
    cors_headers: &[(&'static str, String)],
) -> std::io::Result<()> {
    write!(
        writer,
        "HTTP/1.1 200 OK\r\n\
         Content-Type: text/event-stream\r\n\
         Cache-Control: no-store\r\n\
         Connection: keep-alive\r\n\
         X-Accel-Buffering: no\r\n\
         X-Request-Id: {request_id}\r\n"
    )?;
    for (name, value) in cors_headers {
        if !value.bytes().any(|b| matches!(b, b'\r' | b'\n')) {
            write!(writer, "{name}: {value}\r\n")?;
        }
    }
    write!(writer, "\r\n")?;
    writer.flush()
}
