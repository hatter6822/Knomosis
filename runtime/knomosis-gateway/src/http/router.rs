// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Request routing — the pure, transport-agnostic core.
//!
//! [`route`] maps a `(method, path)` pair to a [`RouteOutcome`]
//! without referencing any `tiny_http` type, so the routing decisions
//! are unit-testable without standing up a listener.  The IO shell
//! ([`super::server`]) converts a `RouteOutcome` into a `tiny_http`
//! response, applying its status, content type, body, and any
//! response-specific [`RouteOutcome::headers`].
//!
//! **Surface (G1.1 + G1.2b).**  The operational endpoints
//! (`/healthz`, `/readyz`, `/v1/info`) plus the cross-cutting HTTP
//! discipline: a `405 Method Not Allowed` (with an `Allow` header) for
//! a known path hit with the wrong method, and an RFC 9457
//! `application/problem+json` body for `404` (and every later error,
//! via [`crate::problem`]).  The `/v1` resource paths (balances /
//! budget / pools / actions / events) attach to this table as their
//! work units land (G1.6b / G1.7 / G2 / G3).

use crate::problem::Problem;

/// The outcome of routing a request: an HTTP status, a `Content-Type`,
/// a body, and any response-specific headers (e.g. `Allow`,
/// `Retry-After`, `X-Knomosis-Seq`).  Deliberately free of any
/// `tiny_http` type so the routing core stays unit-testable in
/// isolation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RouteOutcome {
    /// HTTP status code (e.g. `200`, `404`).
    pub status: u16,
    /// `Content-Type` header value for the response.
    pub content_type: &'static str,
    /// Response body bytes (UTF-8 text / JSON / problem+json).
    pub body: String,
    /// Response-specific headers, applied in order by the IO shell.
    pub headers: Vec<(&'static str, String)>,
}

/// `Content-Type` for plain-text responses.
const TEXT_PLAIN: &str = "text/plain; charset=utf-8";
/// `Content-Type` for JSON responses.
const APPLICATION_JSON: &str = "application/json";
/// `Content-Type` for RFC 9457 problem-details responses.
pub(crate) const APPLICATION_PROBLEM_JSON: &str = "application/problem+json";

impl RouteOutcome {
    /// A plain-text outcome with no extra headers.
    fn text(status: u16, body: &str) -> Self {
        Self {
            status,
            content_type: TEXT_PLAIN,
            body: body.to_string(),
            headers: Vec::new(),
        }
    }

    /// A JSON outcome (body already serialized) with no extra headers.
    fn json(status: u16, body: String) -> Self {
        Self {
            status,
            content_type: APPLICATION_JSON,
            body,
            headers: Vec::new(),
        }
    }

    /// An RFC 9457 `application/problem+json` outcome.  Built by
    /// [`crate::problem::Problem::into_outcome`].
    pub(crate) fn problem(status: u16, body: String) -> Self {
        Self {
            status,
            content_type: APPLICATION_PROBLEM_JSON,
            body,
            headers: Vec::new(),
        }
    }

    /// Append a response header (e.g. `Allow` on a 405).  Builder
    /// style so call sites read as `outcome.with_header("Allow", "GET")`.
    #[must_use]
    pub fn with_header(mut self, name: &'static str, value: impl Into<String>) -> Self {
        self.headers.push((name, value.into()));
        self
    }
}

/// Route a request by `method` (canonical uppercase token, e.g.
/// `"GET"`) and `path` (request target with any query string already
/// stripped) to a [`RouteOutcome`].
///
/// Surface:
///   * `GET /healthz` → `200` liveness (the process is up).
///   * `GET /readyz`  → `200` readiness **stub** (G1.8 probes
///     upstreams + indexer-writer liveness).
///   * `GET /v1/info` → `200` metadata **stub** (identifier + version;
///     G1.8 adds the admission stage, protocol versions, indexer
///     cursor, and the echoed budget/pool config).
///   * a known path with a non-permitted method → `405` +
///     `Allow`, problem+json body.
///   * an unknown path → `404`, problem+json body.
#[must_use]
pub fn route(method: &str, path: &str) -> RouteOutcome {
    match path {
        "/healthz" => get_only(method, || RouteOutcome::text(200, "ok\n")),
        "/readyz" => get_only(method, || RouteOutcome::text(200, "ready\n")),
        "/v1/info" => get_only(method, || RouteOutcome::json(200, info_body())),
        _ => Problem::not_found(path).into_outcome(),
    }
}

/// Serve `ok()` for `GET`; otherwise a `405` problem carrying an
/// `Allow: GET` header — these scaffold endpoints are read-only, so
/// `GET` is the only permitted method.  (Endpoints with a richer
/// method set, e.g. `POST /v1/actions`, supply their own `Allow`
/// value as they land.)
fn get_only(method: &str, ok: impl FnOnce() -> RouteOutcome) -> RouteOutcome {
    if method == "GET" {
        ok()
    } else {
        Problem::method_not_allowed()
            .into_outcome()
            .with_header("Allow", "GET")
    }
}

/// The `/v1/info` stub body.  Hand-serialized over constant-shaped
/// string fields (the typed `Info` schema lands in G1.8); the values
/// are the crate constants, so no escaping is required.
fn info_body() -> String {
    format!(
        "{{\"identifier\":\"{}\",\"version\":\"{}\",\"status\":\"scaffold\"}}\n",
        crate::GATEWAY_IDENTIFIER,
        crate::VERSION
    )
}

#[cfg(test)]
mod tests {
    use super::{route, APPLICATION_JSON, APPLICATION_PROBLEM_JSON, TEXT_PLAIN};

    #[test]
    fn healthz_ok() {
        let r = route("GET", "/healthz");
        assert_eq!(r.status, 200);
        assert_eq!(r.content_type, TEXT_PLAIN);
        assert_eq!(r.body, "ok\n");
        assert!(r.headers.is_empty());
    }

    #[test]
    fn readyz_ok_stub() {
        let r = route("GET", "/readyz");
        assert_eq!(r.status, 200);
        assert_eq!(r.body, "ready\n");
    }

    #[test]
    fn info_is_json_with_identity() {
        let r = route("GET", "/v1/info");
        assert_eq!(r.status, 200);
        assert_eq!(r.content_type, APPLICATION_JSON);
        assert!(r.body.contains("knomosis-gateway/v1"));
        assert!(r.body.contains(crate::VERSION));
    }

    #[test]
    fn unknown_path_is_problem_json_404() {
        let r = route("GET", "/v1/balances");
        assert_eq!(r.status, 404);
        assert_eq!(r.content_type, APPLICATION_PROBLEM_JSON);
        assert!(r.body.contains("\"status\":404"));
        assert!(r.body.contains("not-found"));
    }

    #[test]
    fn non_get_on_known_path_is_405_with_allow() {
        let r = route("POST", "/healthz");
        assert_eq!(r.status, 405);
        assert_eq!(r.content_type, APPLICATION_PROBLEM_JSON);
        assert!(
            r.headers
                .iter()
                .any(|(name, value)| *name == "Allow" && value == "GET"),
            "405 must carry an Allow: GET header, got {:?}",
            r.headers
        );
    }
}
