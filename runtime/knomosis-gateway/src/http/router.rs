// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Request routing — the pure, transport-agnostic core.
//!
//! [`route`] maps a `(method, path)` pair to a [`Route`] — a typed
//! description of *what was requested*, free of any `tiny_http` type
//! and of any application state — so the routing decisions are
//! unit-testable in isolation.  Turning a [`Route`] into a concrete
//! response (which may read state) is the dispatcher's job
//! ([`crate::dispatch`]); writing that response to the socket is the IO
//! shell's ([`super::server`]).  This three-way split — *parse →
//! dispatch → write* — is the seam every later endpoint extends.
//!
//! **Surface (G1.2b).**  The operational endpoints plus the 405 + `Allow`
//! discipline and the `/v1` prefix.  The `/v1` resource routes
//! (balances / budget / pools / actions / events) attach to the
//! [`Route`] enum as their work units land (G1.6b / G1.7 / G2 / G3).

/// A typed description of a routed request — *what* was requested,
/// independent of *how* it is answered (that is [`crate::dispatch`]).
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Route {
    /// `GET /healthz` — liveness.
    Health,
    /// `GET /readyz` — readiness.
    Ready,
    /// `GET /v1/info` — deployment metadata.
    Info,
    /// A known path hit with a method it does not permit.  `allow` is
    /// the value for the `Allow` header (the methods the path accepts).
    MethodNotAllowed {
        /// The `Allow` header value (e.g. `"GET"`).
        allow: &'static str,
    },
    /// No route matched the path.  Carries the requested path for the
    /// problem `detail`.
    NotFound {
        /// The unmatched request path.
        path: String,
    },
}

/// The outcome of dispatching a [`Route`]: an HTTP status, a
/// `Content-Type`, a body, and any response-specific headers (e.g.
/// `Allow`, `Retry-After`, `X-Knomosis-Seq`).  Deliberately free of any
/// `tiny_http` type so the dispatcher stays unit-testable in isolation.
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
const APPLICATION_PROBLEM_JSON: &str = "application/problem+json";

impl RouteOutcome {
    /// A plain-text outcome with no extra headers.
    pub(crate) fn text(status: u16, body: &str) -> Self {
        Self {
            status,
            content_type: TEXT_PLAIN,
            body: body.to_string(),
            headers: Vec::new(),
        }
    }

    /// A JSON outcome (body already serialized) with no extra headers.
    pub(crate) fn json(status: u16, body: String) -> Self {
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
/// stripped) to a [`Route`].
///
/// Surface:
///   * `GET /healthz` / `/readyz` / `/v1/info` → the respective route.
///   * a known path with a non-permitted method → [`Route::MethodNotAllowed`].
///   * an unknown path → [`Route::NotFound`].
#[must_use]
pub fn route(method: &str, path: &str) -> Route {
    match path {
        "/healthz" => get_only(method, Route::Health),
        "/readyz" => get_only(method, Route::Ready),
        "/v1/info" => get_only(method, Route::Info),
        _ => Route::NotFound {
            path: path.to_string(),
        },
    }
}

/// Return `route` for `GET`; otherwise [`Route::MethodNotAllowed`] with
/// an `Allow: GET` hint — these endpoints are read-only, so `GET` is the
/// only permitted method.  (Endpoints with a richer method set, e.g.
/// `POST /v1/actions`, supply their own `allow` value as they land.)
fn get_only(method: &str, route: Route) -> Route {
    if method == "GET" {
        route
    } else {
        Route::MethodNotAllowed { allow: "GET" }
    }
}

#[cfg(test)]
mod tests {
    use super::{route, Route};

    #[test]
    fn static_get_routes() {
        assert_eq!(route("GET", "/healthz"), Route::Health);
        assert_eq!(route("GET", "/readyz"), Route::Ready);
        assert_eq!(route("GET", "/v1/info"), Route::Info);
    }

    #[test]
    fn unknown_path_is_not_found_with_path() {
        assert_eq!(
            route("GET", "/v1/balances"),
            Route::NotFound {
                path: "/v1/balances".to_string()
            }
        );
    }

    #[test]
    fn non_get_on_known_path_is_method_not_allowed() {
        assert_eq!(
            route("POST", "/healthz"),
            Route::MethodNotAllowed { allow: "GET" }
        );
        // An unknown path takes precedence as NotFound regardless of
        // method (there is no path to disallow a method on).
        assert!(matches!(route("POST", "/nope"), Route::NotFound { .. }));
    }
}
