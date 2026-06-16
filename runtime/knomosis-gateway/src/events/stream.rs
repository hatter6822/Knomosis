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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::events::fanout::dispatch::{run_stream, write_stream_error, StreamConfig};
use crate::events::fanout::resume::{classify_resume, parse_resume, ResumeAction};
use crate::events::fanout::FanoutState;
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
        );
        return;
    };
    // Reserve a stream slot (lock-free admission via the atomic counter):
    // a `fetch_add` whose prior value is at the cap is over-budget, so undo
    // and reject.  At most `max_streams` are admitted; a transient overshoot
    // during concurrent rejects is corrected by the matching `fetch_sub`.
    let prev = state.active_streams.fetch_add(1, Ordering::SeqCst);
    if prev >= state.config.sse.max_streams {
        state.active_streams.fetch_sub(1, Ordering::SeqCst);
        respond_problem(
            request,
            "too-many-streams",
            "Too Many Streams",
            503,
            "the gateway is at its configured SSE stream capacity; retry shortly",
            Some(1000),
        );
        return;
    }

    // Slot reserved.  Hijack the connection and run the stream on its own
    // thread; the handler-pool worker returns immediately.
    let fanout = Arc::clone(fanout);
    let active = Arc::clone(&state.active_streams);
    let shutdown = Arc::clone(&state.shutdown);
    let sse = state.config.sse;
    let mut writer = request.into_writer();
    let spawned = std::thread::Builder::new()
        .name("knx-gw-sse".to_string())
        .spawn(move || {
            run_one_stream(
                &mut writer,
                &fanout,
                since,
                &types,
                last_event_id.as_deref(),
                &sse,
                &shutdown,
            );
            active.fetch_sub(1, Ordering::SeqCst);
        });
    if spawned.is_err() {
        // The thread could not be spawned: release the reserved slot. The
        // connection writer was moved into the (failed) closure and is
        // dropped, closing the socket — the client reconnects.
        state.active_streams.fetch_sub(1, Ordering::SeqCst);
        tracing::error!("failed to spawn an SSE stream thread");
    }
}

/// Write the SSE response head, classify the resume point, then either
/// stream live records or emit the terminal `behind` / `truncated` error.
fn run_one_stream<W: Write>(
    writer: &mut W,
    fanout: &FanoutState,
    since: Option<u64>,
    types: &[String],
    last_event_id: Option<&str>,
    sse: &crate::config::SseConfig,
    shutdown: &AtomicBool,
) {
    if write_sse_head(writer).is_err() {
        return; // the client hung up before we could respond
    }
    let point = parse_resume(last_event_id, since);
    // `upstream_oldest = None`: the SSE path steers a behind-ring cursor to
    // the backfill (`behind`), never an SSE `truncated` (finding #7).
    let action = {
        let ring = fanout.ring();
        classify_resume(&ring, point, None)
    };
    match action {
        ResumeAction::Stream(cursor) => {
            let config = StreamConfig {
                max_client_lag: sse.max_client_lag,
                heartbeat: Duration::from_secs(sse.heartbeat_secs),
                poll: STREAM_POLL,
            };
            let _ = run_stream(writer, fanout, cursor, types, &config, shutdown);
        }
        ResumeAction::Behind { oldest_seq } => {
            let _ = write_stream_error(writer, "behind", Some(oldest_seq));
        }
        ResumeAction::Truncated => {
            let _ = write_stream_error(writer, "truncated", None);
        }
    }
}

/// Write the raw HTTP/1.1 SSE response head over the hijacked socket: a
/// `200` with `text/event-stream`, `Cache-Control: no-store`, and
/// `X-Accel-Buffering: no` (defeats intermediary buffering).  No
/// `Content-Length` — the body streams until the connection closes.
fn write_sse_head<W: Write>(writer: &mut W) -> std::io::Result<()> {
    writer.write_all(
        b"HTTP/1.1 200 OK\r\n\
          Content-Type: text/event-stream\r\n\
          Cache-Control: no-store\r\n\
          Connection: keep-alive\r\n\
          X-Accel-Buffering: no\r\n\
          \r\n",
    )?;
    writer.flush()
}

/// Answer a non-stream error (`503`) with a normal `application/problem+json`
/// response (no hijack), optionally carrying a `Retry-After`.
fn respond_problem(
    request: tiny_http::Request,
    type_suffix: &str,
    title: &str,
    status: u16,
    detail: &str,
    retry_after_ms: Option<u64>,
) {
    let mut problem = Problem::new(type_suffix, title, status).with_detail(detail.to_string());
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
