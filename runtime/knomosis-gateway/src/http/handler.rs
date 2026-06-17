// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The **transport-agnostic** request core, shared by the HTTP
//! (`tiny_http`) and HTTPS (`rustls`) front-ends.
//!
//! Keeping a single source of truth for the gate → route → dispatch →
//! finalise sequence means the two transports **cannot diverge in security
//! behaviour**: both run the same fail-closed auth gate, the same
//! per-credential rate cap, the same router, the same dispatch, and the
//! same `X-Request-Id` / `problem.instance` finalisation.  Only the wire I/O
//! (reading the request, writing the response, hijacking for SSE) differs.
//!
//! The request body is read through a caller-supplied closure so the
//! **gate-before-body** ordering is preserved: an unauthenticated request
//! is denied *before* its (bounded) body is read, so an attacker cannot make
//! the gateway buffer a large body for a request it will reject.

use std::time::Duration;

use crate::auth;
use crate::dispatch::{dispatch, RequestPayload};
use crate::http::router::{apply_conditional, route, Route, RouteOutcome};
use crate::observability::REQUEST_ID_HEADER;
use crate::state::AppState;

/// The borrowed request line + headers the core consumes (the body is read
/// lazily via the closure passed to [`handle`]).
pub struct RequestParts<'a> {
    /// The canonical method token (e.g. `"GET"`).
    pub method: &'a str,
    /// The request path (query stripped).
    pub path: &'a str,
    /// The raw query string (after `?`, or `""`).
    pub query: &'a str,
    /// The `Authorization` header value, if present.
    pub auth_header: Option<&'a str>,
    /// The `Content-Type` header value, if present.
    pub content_type: Option<&'a str>,
    /// The `If-None-Match` header value, if present.
    pub if_none_match: Option<&'a str>,
    /// The `Idempotency-Key` header value, if present.
    pub idempotency_key: Option<&'a str>,
    /// The `Last-Event-ID` header value, if present.
    pub last_event_id: Option<&'a str>,
}

/// The decision the core reaches for one request: a finalised response to
/// write, or an SSE-stream directive the transport hijacks the connection
/// for.
pub enum Handled {
    /// Write this finalised response (it already carries the `X-Request-Id`
    /// header + the RFC 9457 `instance`).
    Respond(RouteOutcome),
    /// Hijack the connection for a live SSE stream with these resume inputs.
    Stream {
        /// The `since` cursor (absent ⇒ `Last-Event-ID` / live tail).
        since: Option<u64>,
        /// The repeatable event-type filter.
        types: Vec<String>,
        /// The `Last-Event-ID` header value, if present.
        last_event_id: Option<String>,
    },
}

/// Route a request (pure) — the transport computes this once and passes it
/// to [`handle`] (so a body-reader closure can be route-aware).
#[must_use]
pub fn route_request(parts: &RequestParts) -> Route {
    route(parts.method, parts.path, parts.query)
}

/// The shared request core: run the auth + rate gates; if they pass and the
/// route is the live SSE stream, return a [`Handled::Stream`] directive;
/// otherwise dispatch (reading the body via `read_body` **after** the gate,
/// bounded by `--max-frame-size`), apply any `If-None-Match`, and finalise.
///
/// `read_body(max)` returns the request body (bounded to `max`) or a
/// ready-made `413` outcome; it is invoked **only** when the request is
/// authorised and routed to a body-consuming endpoint.
pub fn handle(
    routed: &Route,
    parts: &RequestParts,
    read_body: impl FnOnce(usize) -> Result<Vec<u8>, RouteOutcome>,
    state: &AppState,
    request_id: &str,
) -> Handled {
    // Auth first; the per-credential rate cap only if authenticated.
    let gate = auth::gate(&state.auth, parts.path, parts.auth_header)
        .or_else(|| auth::rate_limit_check(&state.rate_limiter, parts.path, parts.auth_header));

    // A live SSE stream hijacks the connection — but only once the gates
    // pass (a denied stream gets a normal 401/429 below, never a hijack).
    if gate.is_none() {
        if let Route::EventStream { since, types } = routed {
            return Handled::Stream {
                since: *since,
                types: types.clone(),
                last_event_id: parts.last_event_id.map(str::to_string),
            };
        }
    }

    // A denial short-circuits; otherwise read the (gated, bounded) body and
    // dispatch.  Either way the response is finalised with the request id.
    let Some(denied) = gate else {
        let body = match read_body(state.config.max_frame_size) {
            Ok(body) => body,
            Err(too_large) => return Handled::Respond(finalize(too_large, request_id)),
        };
        let payload = RequestPayload {
            content_type: parts.content_type,
            body: &body,
            idempotency_key: parts.idempotency_key,
        };
        let outcome = apply_conditional(dispatch(routed, state, &payload), parts.if_none_match);
        return Handled::Respond(finalize(outcome, request_id));
    };
    Handled::Respond(finalize(denied, request_id))
}

/// Stamp the per-request correlation id onto the outcome (§G4.3): an
/// `X-Request-Id` header on every response, plus — for an RFC 9457 problem
/// body — the `instance` member, injected via a safe `serde_json`
/// round-trip (problem responses are infrequent, so the round-trip cost is
/// negligible; a malformed body is left untouched).
#[must_use]
pub fn finalize(mut outcome: RouteOutcome, request_id: &str) -> RouteOutcome {
    outcome
        .headers
        .push((REQUEST_ID_HEADER, request_id.to_string()));
    if outcome.content_type == "application/problem+json" {
        if let Ok(mut value) = serde_json::from_str::<serde_json::Value>(&outcome.body) {
            if let Some(object) = value.as_object_mut() {
                object
                    .entry("instance")
                    .or_insert_with(|| serde_json::Value::String(request_id.to_string()));
                if let Ok(rendered) = serde_json::to_string(&value) {
                    outcome.body = rendered;
                }
            }
        }
    }
    outcome
}

/// Emit the single structured per-request log line — the §G4.3 log-based
/// metrics surface (an aggregator derives per-endpoint status / latency
/// from it).  Records only the method, path, status, latency, and id;
/// **never** the `Authorization` header / token, an `Idempotency-Key`, or a
/// body (§8.1).
pub fn log_request(method: &str, path: &str, status: u16, latency: Duration, request_id: &str) {
    tracing::info!(
        request_id,
        method,
        path,
        status,
        latency_us = u64::try_from(latency.as_micros()).unwrap_or(u64::MAX),
        "request"
    );
}

#[cfg(test)]
mod tests {
    use super::{finalize, log_request};
    use crate::http::RouteOutcome;
    use crate::problem::Problem;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    #[test]
    fn finalize_stamps_request_id_header_and_problem_instance() {
        // A problem body gains the X-Request-Id header AND the RFC 9457
        // `instance` member.
        let problem = Problem::not_found("/v1/nope").into_outcome();
        let out = finalize(problem, "req-test-1");
        assert!(out
            .headers
            .iter()
            .any(|(n, v)| *n == "X-Request-Id" && v == "req-test-1"));
        let v: serde_json::Value = serde_json::from_str(&out.body).unwrap();
        assert_eq!(v["instance"], "req-test-1");

        // A non-problem (JSON) body gains only the header — no body rewrite.
        let json = RouteOutcome::json(200, r#"{"ok":true}"#.to_string());
        let out = finalize(json, "req-test-2");
        assert!(out
            .headers
            .iter()
            .any(|(n, v)| *n == "X-Request-Id" && v == "req-test-2"));
        assert_eq!(out.body, r#"{"ok":true}"#); // unchanged
    }

    /// A buffer-backed `MakeWriter` so the redaction test can capture the
    /// structured request log line.
    #[derive(Clone)]
    struct BufWriter(Arc<Mutex<Vec<u8>>>);

    impl std::io::Write for BufWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for BufWriter {
        type Writer = BufWriter;
        fn make_writer(&'a self) -> Self::Writer {
            self.clone()
        }
    }

    #[test]
    fn request_log_records_only_safe_fields_no_secret() {
        let buf = Arc::new(Mutex::new(Vec::new()));
        let subscriber = tracing_subscriber::fmt()
            .with_writer(BufWriter(Arc::clone(&buf)))
            .with_max_level(tracing::Level::INFO)
            .without_time()
            .finish();
        tracing::subscriber::with_default(subscriber, || {
            log_request(
                "GET",
                "/v1/actors/7/balances",
                200,
                Duration::from_micros(123),
                "req-abc-1",
            );
        });
        let out = String::from_utf8(buf.lock().unwrap().clone()).unwrap();
        assert!(out.contains("request"));
        assert!(out.contains("GET"));
        assert!(out.contains("/v1/actors/7/balances"));
        assert!(out.contains("status=200"));
        assert!(out.contains("req-abc-1"));
        assert!(out.contains("123")); // latency_us
                                      // A bearer token / Authorization value could never appear: the
                                      // structured request log takes no such argument (§8.1).
        assert!(
            !out.contains("Bearer"),
            "no bearer token in the request log"
        );
        assert!(
            !out.contains("Authorization"),
            "no Authorization header in the request log"
        );
    }
}
