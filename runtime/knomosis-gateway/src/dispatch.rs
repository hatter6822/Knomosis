// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The dispatch layer: turn a [`Route`] (what was requested) into a
//! [`RouteOutcome`] (the response), reading [`AppState`] where the
//! endpoint needs it.  Sits between the pure router
//! ([`crate::http::router`]) and the IO shell ([`crate::http::server`])
//! — the *dispatch* step of the parse → dispatch → write pipeline.
//!
//! The static endpoints (`/healthz`, `/readyz`, `/v1/info`) ignore the
//! state; the stateful endpoints attach here as they land (the reads
//! over the read-only indexer handle in G1.6b, the auth gate in G1.4).

use crate::http::{Route, RouteOutcome};
use crate::problem::Problem;
use crate::state::AppState;

/// Dispatch a routed request to its response.
///
/// Total over [`Route`]: every variant maps to a concrete outcome, so
/// adding a route forces a dispatch arm (the compiler enforces it).
#[must_use]
pub fn dispatch(route: &Route, _state: &AppState) -> RouteOutcome {
    match route {
        Route::Health => RouteOutcome::text(200, "ok\n"),
        Route::Ready => RouteOutcome::text(200, "ready\n"),
        Route::Info => RouteOutcome::json(200, info_body()),
        Route::MethodNotAllowed { allow } => Problem::method_not_allowed()
            .into_outcome()
            .with_header("Allow", *allow),
        Route::NotFound { path } => Problem::not_found(path).into_outcome(),
    }
}

/// The `/v1/info` stub body.  Hand-serialized over constant-shaped
/// string fields; the typed `Info` schema (deployment id, admission
/// stage, protocol versions, indexer cursor, budget/pool echo) lands in
/// G1.8.  The values are crate constants, so no escaping is required.
fn info_body() -> String {
    format!(
        "{{\"identifier\":\"{}\",\"version\":\"{}\",\"status\":\"scaffold\"}}\n",
        crate::GATEWAY_IDENTIFIER,
        crate::VERSION
    )
}

#[cfg(test)]
mod tests {
    use super::{dispatch, info_body};
    use crate::config::Config;
    use crate::http::Route;
    use crate::state::AppState;

    fn state() -> AppState {
        AppState::new(Config {
            listen: "127.0.0.1:0".parse().expect("loopback addr"),
            handler_threads: 1,
            indexer_db: None,
        })
        .expect("no DB to open")
    }

    #[test]
    fn health_is_text_200() {
        let o = dispatch(&Route::Health, &state());
        assert_eq!(o.status, 200);
        assert_eq!(o.content_type, "text/plain; charset=utf-8");
        assert_eq!(o.body, "ok\n");
        assert!(o.headers.is_empty());
    }

    #[test]
    fn info_is_json_with_identity() {
        let o = dispatch(&Route::Info, &state());
        assert_eq!(o.status, 200);
        assert_eq!(o.content_type, "application/json");
        assert!(o.body.contains("knomosis-gateway/v1"));
        assert!(info_body().contains(crate::VERSION));
    }

    #[test]
    fn method_not_allowed_carries_allow_header() {
        let o = dispatch(&Route::MethodNotAllowed { allow: "GET" }, &state());
        assert_eq!(o.status, 405);
        assert_eq!(o.content_type, "application/problem+json");
        assert!(o.headers.iter().any(|(n, v)| *n == "Allow" && v == "GET"));
    }

    #[test]
    fn not_found_is_problem_json_404_with_path() {
        let o = dispatch(
            &Route::NotFound {
                path: "/v1/x".to_string(),
            },
            &state(),
        );
        assert_eq!(o.status, 404);
        assert_eq!(o.content_type, "application/problem+json");
        assert!(o.body.contains("/v1/x"));
    }
}
