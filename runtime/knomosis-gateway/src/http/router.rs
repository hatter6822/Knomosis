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
//! response.
//!
//! **Scaffold table (G1.1).**  Only the operational endpoints are
//! wired; the `/v1` resource surface (balances / budget / pools /
//! actions / events), the 405-with-`Allow` discipline, and the RFC
//! 9457 problem bodies land in G1.2b / G1.5.

/// The outcome of routing a request: an HTTP status, a `Content-Type`,
/// and a body.  Deliberately free of any `tiny_http` type so the
/// routing core stays unit-testable in isolation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RouteOutcome {
    /// HTTP status code (e.g. `200`, `404`).
    pub status: u16,
    /// `Content-Type` header value for the response.
    pub content_type: &'static str,
    /// Response body bytes (UTF-8 text or JSON for the scaffold
    /// surface).
    pub body: String,
}

/// `Content-Type` for plain-text responses.
const TEXT_PLAIN: &str = "text/plain; charset=utf-8";
/// `Content-Type` for JSON responses.
const APPLICATION_JSON: &str = "application/json";

impl RouteOutcome {
    /// A plain-text outcome.
    fn text(status: u16, body: &str) -> Self {
        Self {
            status,
            content_type: TEXT_PLAIN,
            body: body.to_string(),
        }
    }

    /// A JSON outcome (body already serialized).
    fn json(status: u16, body: String) -> Self {
        Self {
            status,
            content_type: APPLICATION_JSON,
            body,
        }
    }
}

/// Route a request by `method` (canonical uppercase token, e.g.
/// `"GET"`) and `path` (request target with any query string already
/// stripped) to a [`RouteOutcome`].
///
/// Scaffold surface (G1.1):
///   * `GET /healthz` → `200` liveness (the process is up).
///   * `GET /readyz`  → `200` readiness **stub** (G1.8 probes
///     upstreams + indexer-writer liveness).
///   * `GET /v1/info` → `200` metadata **stub** (identifier + version;
///     G1.8 adds the admission stage, protocol versions, indexer
///     cursor, and the echoed budget/pool config).
///   * anything else  → `404`.
#[must_use]
pub fn route(method: &str, path: &str) -> RouteOutcome {
    match (method, path) {
        ("GET", "/healthz") => RouteOutcome::text(200, "ok\n"),
        ("GET", "/readyz") => RouteOutcome::text(200, "ready\n"),
        ("GET", "/v1/info") => RouteOutcome::json(200, info_body()),
        _ => RouteOutcome::text(404, "not found\n"),
    }
}

/// The `/v1/info` stub body.  Hand-serialized (no `serde` dependency
/// at the scaffold stage) over two constant-shaped string fields; G1.8
/// replaces this with the full typed `Info` schema.
fn info_body() -> String {
    format!(
        "{{\"identifier\":\"{}\",\"version\":\"{}\",\"status\":\"scaffold\"}}\n",
        crate::GATEWAY_IDENTIFIER,
        crate::VERSION
    )
}

#[cfg(test)]
mod tests {
    use super::{route, APPLICATION_JSON, TEXT_PLAIN};

    #[test]
    fn healthz_ok() {
        let r = route("GET", "/healthz");
        assert_eq!(r.status, 200);
        assert_eq!(r.content_type, TEXT_PLAIN);
        assert_eq!(r.body, "ok\n");
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
    fn unknown_path_404() {
        let r = route("GET", "/v1/balances");
        assert_eq!(r.status, 404);
    }

    /// A non-GET method on a known path is not yet special-cased
    /// (`405` + `Allow` is G1.2b); for now it falls through to 404, so
    /// the scaffold pins the behaviour and the G1.2b upgrade becomes a
    /// visible, intentional change.
    #[test]
    fn non_get_on_known_path_is_404_for_now() {
        assert_eq!(route("POST", "/healthz").status, 404);
    }
}
