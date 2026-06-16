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
//! **Surface (G1.2b → G1.7).**  The operational endpoints plus the 405 +
//! `Allow` discipline and the `/v1` prefix, and the read routes —
//! balances (G1.6b), budget + pools (G1.7).  The remaining `/v1`
//! resource routes (actions / events) attach to the [`Route`] enum as
//! their work units land (G2 / G3).
//!
//! [`route`] takes the request's `query` string (the part after `?`, or
//! `""`) alongside the method + path, so query-parameter selectors —
//! currently `GET /v1/pools/{id}?resource={0|1}` — are parsed in this
//! pure, testable layer rather than in the IO shell.

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
    /// `GET /v1/actors/{actor}/balances` — all balances for an actor.
    ActorBalances {
        /// The actor id from the path.
        actor: u64,
    },
    /// `GET /v1/actors/{actor}/balances/{resource}` — one balance.
    ActorBalance {
        /// The actor id from the path.
        actor: u64,
        /// The resource id from the path.
        resource: u64,
    },
    /// `GET /v1/actors/{actor}/budget` — the actor's epoch budget view.
    ActorBudget {
        /// The actor id from the path.
        actor: u64,
    },
    /// `GET /v1/pools/{pool}?resource={0|1}` — one gas-pool resource
    /// view (a single `PoolView`).  `resource` defaults to `0` (ETH)
    /// when the query parameter is absent.
    Pool {
        /// The gas-pool actor id from the path.
        pool: u64,
        /// The selected resource (`0` = ETH, `1` = BOLD); the dispatcher
        /// maps it to `get_pool_eth` / `get_pool_bold` and rejects any
        /// other value as a `400`.
        resource: u64,
    },
    /// A structurally-matched path with a malformed parameter (e.g. a
    /// non-numeric id).  Carries the problem `detail`.
    BadRequest {
        /// The problem detail describing the malformed parameter.
        detail: String,
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

/// Apply an `If-None-Match` conditional to a computed [`RouteOutcome`]:
/// when the request carried an `If-None-Match` that matches the
/// response's weak `ETag` (or `*`), collapse a `200` into a `304 Not
/// Modified` with an empty body, preserving the `ETag` for revalidation
/// (RFC 9110 §13.1.2 / §15.4.5).  A non-`200` outcome, a response with no
/// `ETag`, or an absent / non-matching `If-None-Match` is returned
/// unchanged.
#[must_use]
pub fn apply_conditional(outcome: RouteOutcome, if_none_match: Option<&str>) -> RouteOutcome {
    let Some(inm) = if_none_match else {
        return outcome;
    };
    if outcome.status != 200 {
        return outcome;
    }
    let Some((_, etag)) = outcome
        .headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("etag"))
    else {
        return outcome;
    };
    let etag = etag.clone();
    // Weak comparison (RFC 9110 §8.8.3.2): the client echoes the exact
    // ETag it received; `*` matches any current representation.
    let trimmed = inm.trim();
    if trimmed == "*" || trimmed == etag {
        RouteOutcome {
            status: 304,
            content_type: outcome.content_type,
            body: String::new(),
            headers: vec![("ETag", etag)],
        }
    } else {
        outcome
    }
}

/// Route a request by `method` (canonical uppercase token, e.g.
/// `"GET"`), `path` (request target with any query string stripped),
/// and `query` (the raw query string after `?`, or `""`) to a [`Route`].
///
/// Surface:
///   * `GET /healthz` / `/readyz` / `/v1/info` → the respective route.
///   * `GET /v1/actors/{id}/{balances|budget}[/{resource}]` → the reads.
///   * `GET /v1/pools/{id}?resource={0|1}` → [`Route::Pool`].
///   * a known path with a non-permitted method → [`Route::MethodNotAllowed`].
///   * an unknown path → [`Route::NotFound`].
#[must_use]
pub fn route(method: &str, path: &str, query: &str) -> Route {
    match path {
        "/healthz" => get_only(method, Route::Health),
        "/readyz" => get_only(method, Route::Ready),
        "/v1/info" => get_only(method, Route::Info),
        _ => route_v1_actors(method, path)
            .or_else(|| route_v1_pools(method, path, query))
            .unwrap_or_else(|| Route::NotFound {
                path: path.to_string(),
            }),
    }
}

/// Parse the `/v1/actors/{actor}/{balances|budget}[/{resource}]` family.
/// Returns `None` if the path is not in this family (→ 404); a matched
/// shape with a non-permitted method yields [`Route::MethodNotAllowed`]
/// and a malformed id yields [`Route::BadRequest`].
fn route_v1_actors(method: &str, path: &str) -> Option<Route> {
    let rest = path.strip_prefix("/v1/actors/")?;
    let mut segs = rest.split('/').filter(|s| !s.is_empty());
    let actor_str = segs.next()?;
    let sub = segs.next()?;
    let resource_str = segs.next();
    if segs.next().is_some() {
        // A trailing extra segment is not part of this route family.
        return None;
    }
    match sub {
        "balances" => {
            if method != "GET" {
                return Some(Route::MethodNotAllowed { allow: "GET" });
            }
            let Ok(actor) = actor_str.parse::<u64>() else {
                return Some(Route::BadRequest {
                    detail: format!("invalid actor id {actor_str:?}"),
                });
            };
            match resource_str {
                None => Some(Route::ActorBalances { actor }),
                Some(resource_str) => match resource_str.parse::<u64>() {
                    Ok(resource) => Some(Route::ActorBalance { actor, resource }),
                    Err(_) => Some(Route::BadRequest {
                        detail: format!("invalid resource id {resource_str:?}"),
                    }),
                },
            }
        }
        "budget" => {
            // `/budget` takes no further path segment.
            if resource_str.is_some() {
                return None;
            }
            if method != "GET" {
                return Some(Route::MethodNotAllowed { allow: "GET" });
            }
            let Ok(actor) = actor_str.parse::<u64>() else {
                return Some(Route::BadRequest {
                    detail: format!("invalid actor id {actor_str:?}"),
                });
            };
            Some(Route::ActorBudget { actor })
        }
        _ => None,
    }
}

/// Parse the `/v1/pools/{pool}` family with its optional `?resource=`
/// selector.  Returns `None` if the path is not in this family (→ 404);
/// a matched shape with a non-permitted method yields
/// [`Route::MethodNotAllowed`], and a malformed pool id or `resource`
/// value yields [`Route::BadRequest`].  The `resource` parameter
/// defaults to `0` (ETH) when absent; the dispatcher enforces the
/// `{0, 1}` domain.
fn route_v1_pools(method: &str, path: &str, query: &str) -> Option<Route> {
    let rest = path.strip_prefix("/v1/pools/")?;
    let mut segs = rest.split('/').filter(|s| !s.is_empty());
    let pool_str = segs.next()?;
    if segs.next().is_some() {
        // `/pools/{id}` takes no further path segment (the resource is a
        // query parameter, not a path segment).
        return None;
    }
    if method != "GET" {
        return Some(Route::MethodNotAllowed { allow: "GET" });
    }
    let Ok(pool) = pool_str.parse::<u64>() else {
        return Some(Route::BadRequest {
            detail: format!("invalid pool id {pool_str:?}"),
        });
    };
    // `?resource=` selects ETH (0) or BOLD (1); absent → 0.
    let resource_raw = query_param(query, "resource").unwrap_or("0");
    let Ok(resource) = resource_raw.parse::<u64>() else {
        return Some(Route::BadRequest {
            detail: format!("invalid resource selector {resource_raw:?}"),
        });
    };
    Some(Route::Pool { pool, resource })
}

/// Extract the first value of query parameter `key` from a raw query
/// string (`a=1&b=2`), or `None` if the key is absent.  Performs no
/// percent-decoding: the only query parameters this gateway reads are
/// short numeric selectors (`?resource=0`), for which percent-encoding
/// does not arise; a future parameter that needs decoding adds it here.
fn query_param<'q>(query: &'q str, key: &str) -> Option<&'q str> {
    query.split('&').find_map(|pair| {
        let (k, v) = pair.split_once('=')?;
        (k == key).then_some(v)
    })
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
    use super::{apply_conditional, query_param, route, Route, RouteOutcome};

    /// Route with an empty query string (the common case in these
    /// tests; the pool tests that exercise `?resource=` call `route`
    /// with an explicit query directly).
    fn r(method: &str, path: &str) -> Route {
        route(method, path, "")
    }

    #[test]
    fn static_get_routes() {
        assert_eq!(r("GET", "/healthz"), Route::Health);
        assert_eq!(r("GET", "/readyz"), Route::Ready);
        assert_eq!(r("GET", "/v1/info"), Route::Info);
    }

    #[test]
    fn unknown_path_is_not_found_with_path() {
        assert_eq!(
            r("GET", "/v1/balances"),
            Route::NotFound {
                path: "/v1/balances".to_string()
            }
        );
    }

    #[test]
    fn non_get_on_known_path_is_method_not_allowed() {
        assert_eq!(
            r("POST", "/healthz"),
            Route::MethodNotAllowed { allow: "GET" }
        );
        // An unknown path takes precedence as NotFound regardless of
        // method (there is no path to disallow a method on).
        assert!(matches!(r("POST", "/nope"), Route::NotFound { .. }));
    }

    #[test]
    fn actor_balances_list_route() {
        assert_eq!(
            r("GET", "/v1/actors/7/balances"),
            Route::ActorBalances { actor: 7 }
        );
        // A trailing slash normalises to the list route.
        assert_eq!(
            r("GET", "/v1/actors/7/balances/"),
            Route::ActorBalances { actor: 7 }
        );
    }

    #[test]
    fn actor_balance_single_route() {
        assert_eq!(
            r("GET", "/v1/actors/7/balances/0"),
            Route::ActorBalance {
                actor: 7,
                resource: 0
            }
        );
    }

    #[test]
    fn malformed_id_is_bad_request() {
        assert!(matches!(
            r("GET", "/v1/actors/abc/balances"),
            Route::BadRequest { .. }
        ));
        assert!(matches!(
            r("GET", "/v1/actors/7/balances/xyz"),
            Route::BadRequest { .. }
        ));
    }

    #[test]
    fn non_get_balances_is_method_not_allowed() {
        assert_eq!(
            r("POST", "/v1/actors/7/balances"),
            Route::MethodNotAllowed { allow: "GET" }
        );
    }

    #[test]
    fn unrelated_or_overlong_actors_path_is_not_found() {
        // Right prefix, wrong shape → 404 (not this route family).
        assert!(matches!(
            r("GET", "/v1/actors/7/nonsense"),
            Route::NotFound { .. }
        ));
        // A trailing extra segment → 404.
        assert!(matches!(
            r("GET", "/v1/actors/7/balances/0/extra"),
            Route::NotFound { .. }
        ));
    }

    #[test]
    fn actor_budget_route() {
        assert_eq!(
            r("GET", "/v1/actors/7/budget"),
            Route::ActorBudget { actor: 7 }
        );
        // `/budget` takes no sub-segment.
        assert!(matches!(
            r("GET", "/v1/actors/7/budget/extra"),
            Route::NotFound { .. }
        ));
        // A malformed actor id on `/budget` → 400.
        assert!(matches!(
            r("GET", "/v1/actors/abc/budget"),
            Route::BadRequest { .. }
        ));
        // An unknown sub-resource → 404.
        assert!(matches!(
            r("GET", "/v1/actors/7/widgets"),
            Route::NotFound { .. }
        ));
    }

    #[test]
    fn pool_route_defaults_to_eth() {
        // No `?resource=` → ETH (resource 0).
        assert_eq!(
            route("GET", "/v1/pools/161", ""),
            Route::Pool {
                pool: 161,
                resource: 0
            }
        );
    }

    #[test]
    fn pool_route_resource_selector() {
        assert_eq!(
            route("GET", "/v1/pools/161", "resource=0"),
            Route::Pool {
                pool: 161,
                resource: 0
            }
        );
        assert_eq!(
            route("GET", "/v1/pools/161", "resource=1"),
            Route::Pool {
                pool: 161,
                resource: 1
            }
        );
        // The selector is found among other query parameters.
        assert_eq!(
            route("GET", "/v1/pools/161", "foo=bar&resource=1"),
            Route::Pool {
                pool: 161,
                resource: 1
            }
        );
    }

    #[test]
    fn pool_route_malformed_id_or_selector_is_bad_request() {
        // A non-numeric pool id → 400.
        assert!(matches!(
            route("GET", "/v1/pools/abc", ""),
            Route::BadRequest { .. }
        ));
        // A non-numeric `?resource=` → 400.
        assert!(matches!(
            route("GET", "/v1/pools/161", "resource=eth"),
            Route::BadRequest { .. }
        ));
    }

    #[test]
    fn pool_route_method_and_shape() {
        // Non-GET on a well-formed pool path → 405 + Allow.
        assert_eq!(
            route("POST", "/v1/pools/161", ""),
            Route::MethodNotAllowed { allow: "GET" }
        );
        // A trailing path segment (the resource is a query param, not a
        // path segment) → 404.
        assert!(matches!(
            route("GET", "/v1/pools/161/0", ""),
            Route::NotFound { .. }
        ));
    }

    #[test]
    fn query_param_extraction() {
        assert_eq!(query_param("resource=1", "resource"), Some("1"));
        assert_eq!(query_param("a=1&resource=2&b=3", "resource"), Some("2"));
        assert_eq!(query_param("a=1&b=2", "resource"), None);
        assert_eq!(query_param("", "resource"), None);
        // A bare key with no `=` is not a value-bearing match.
        assert_eq!(query_param("resource", "resource"), None);
        // The first occurrence wins.
        assert_eq!(query_param("resource=1&resource=2", "resource"), Some("1"));
    }

    #[test]
    fn conditional_collapses_matching_etag_to_304() {
        let outcome = RouteOutcome::json(200, "{}".to_string()).with_header("ETag", "W/\"7-42\"");
        // A matching If-None-Match → 304, empty body, ETag preserved.
        let r = apply_conditional(outcome.clone(), Some("W/\"7-42\""));
        assert_eq!(r.status, 304);
        assert!(r.body.is_empty());
        assert!(r
            .headers
            .iter()
            .any(|(n, v)| *n == "ETag" && v == "W/\"7-42\""));
        // `*` matches any current representation.
        assert_eq!(apply_conditional(outcome.clone(), Some("*")).status, 304);
        // A non-matching validator leaves the 200 intact.
        assert_eq!(
            apply_conditional(outcome.clone(), Some("W/\"7-99\"")).status,
            200
        );
        // An absent If-None-Match is unchanged.
        assert_eq!(apply_conditional(outcome, None).status, 200);
    }

    #[test]
    fn conditional_ignores_non_200_and_etagless() {
        // A non-200 outcome is never collapsed, even with `*`.
        let not_found = RouteOutcome::problem(404, "{}".to_string());
        assert_eq!(apply_conditional(not_found, Some("*")).status, 404);
        // A 200 carrying no ETag is returned unchanged.
        let no_etag = RouteOutcome::json(200, "{}".to_string());
        assert_eq!(apply_conditional(no_etag, Some("anything")).status, 200);
    }
}
