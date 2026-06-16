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
pub fn dispatch(route: &Route, state: &AppState) -> RouteOutcome {
    match route {
        Route::Health => RouteOutcome::text(200, "ok\n"),
        Route::Ready => RouteOutcome::text(200, "ready\n"),
        Route::Info => RouteOutcome::json(200, info_body()),
        Route::ActorBalances { actor } => with_reads(state, |reads| {
            crate::reads::balances::actor_balances(reads, *actor)
        }),
        Route::ActorBalance { actor, resource } => with_reads(state, |reads| {
            crate::reads::balances::actor_balance(reads, *actor, *resource)
        }),
        Route::ActorBudget { actor } => {
            let free_tier = state.config.free_tier;
            let action_cost = state.config.action_cost;
            with_reads(state, |reads| {
                crate::reads::budget::actor_budget(reads, *actor, free_tier, action_cost)
            })
        }
        Route::Pool { pool, resource } => {
            // The pool view is net of drains iff this is the configured
            // gas-pool actor (the indexer drains only that one actor; see
            // `reads::pools` for the operator-echo rationale).
            let net = state.config.gas_pool_actor == Some(*pool);
            with_reads(state, |reads| {
                crate::reads::pools::pool_view(reads, *pool, *resource, net)
            })
        }
        Route::MethodNotAllowed { allow } => Problem::method_not_allowed()
            .into_outcome()
            .with_header("Allow", *allow),
        Route::BadRequest { detail } => Problem::new("bad-request", "Bad Request", 400)
            .with_detail(detail.clone())
            .into_outcome(),
        Route::NotFound { path } => Problem::not_found(path).into_outcome(),
    }
}

/// Run `f` against the read backend, or answer `503` if reads are
/// disabled (the gateway was started without `--indexer-db`).
fn with_reads(
    state: &AppState,
    f: impl FnOnce(&crate::state::ReadState) -> RouteOutcome,
) -> RouteOutcome {
    match &state.reads {
        Some(reads) => f(reads),
        None => Problem::new("reads-unavailable", "Reads Unavailable", 503)
            .with_detail("reads are disabled: the gateway was started without --indexer-db")
            .into_outcome(),
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
            free_tier: 0,
            action_cost: 0,
            gas_pool_actor: None,
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

    #[test]
    fn read_route_without_indexer_db_is_503() {
        // `state()` configures no --indexer-db, so reads are disabled.
        let o = dispatch(&Route::ActorBalances { actor: 7 }, &state());
        assert_eq!(o.status, 503);
        assert_eq!(o.content_type, "application/problem+json");
        let o = dispatch(
            &Route::ActorBalance {
                actor: 7,
                resource: 0,
            },
            &state(),
        );
        assert_eq!(o.status, 503);
        let o = dispatch(&Route::ActorBudget { actor: 7 }, &state());
        assert_eq!(o.status, 503);
        let o = dispatch(
            &Route::Pool {
                pool: 7,
                resource: 0,
            },
            &state(),
        );
        assert_eq!(o.status, 503);
    }

    #[test]
    fn bad_request_is_problem_json_400() {
        let o = dispatch(
            &Route::BadRequest {
                detail: "invalid actor id".to_string(),
            },
            &state(),
        );
        assert_eq!(o.status, 400);
        assert_eq!(o.content_type, "application/problem+json");
        assert!(o.body.contains("invalid actor id"));
    }

    /// The dispatcher derives `PoolView.net` from the `--gas-pool-actor`
    /// echo: `net = true` exactly for the configured pool actor, `false`
    /// for any other.  Exercised end-to-end through a seeded read-only
    /// indexer DB so the config → `net` wiring is covered (the read
    /// itself is unit-tested in `reads::pools`).
    #[test]
    fn pool_net_flag_follows_configured_gas_pool_actor() {
        use knomosis_indexer::cursor::CURSOR_KEY;
        use knomosis_storage::sqlite::SqliteStorage;
        use knomosis_storage::storage::Storage;

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("index.db");
        // Seed pool 161 with an ETH balance; keep the writer alive so the
        // read-only reader can map the WAL sidecars.
        let writer = SqliteStorage::open(&path).expect("open writer");
        let mut tx = writer.combined_transaction().expect("begin");
        tx.credit_pool_eth(161, 500).expect("credit eth");
        tx.commit().expect("commit");
        writer.put(CURSOR_KEY, &7u64.to_be_bytes()).expect("cursor");

        // Gateway configured with --gas-pool-actor 161.
        let state = AppState::new(Config {
            listen: "127.0.0.1:0".parse().expect("loopback addr"),
            handler_threads: 1,
            indexer_db: Some(path.clone()),
            free_tier: 0,
            action_cost: 0,
            gas_pool_actor: Some(161),
        })
        .expect("open read-only state");

        // The configured pool → net = true.
        let o = dispatch(
            &Route::Pool {
                pool: 161,
                resource: 0,
            },
            &state,
        );
        assert_eq!(o.status, 200);
        let v: serde_json::Value = serde_json::from_str(&o.body).expect("json");
        assert_eq!(v["poolId"], "161");
        assert_eq!(v["balance"], "500");
        assert_eq!(v["net"], true);

        // A different pool → net = false (gross inflows).
        let o = dispatch(
            &Route::Pool {
                pool: 999,
                resource: 0,
            },
            &state,
        );
        let v: serde_json::Value = serde_json::from_str(&o.body).expect("json");
        assert_eq!(v["net"], false);
        assert_eq!(v["balance"], "0");

        drop(writer);
    }
}
