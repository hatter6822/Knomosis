// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-gateway` — Workstream GW.
//!
//! A synchronous HTTP/JSON + Server-Sent-Events service that bridges
//! Knomosis's binary, socket-based runtime surfaces to a
//! browser-friendly contract.  See
//! `docs/planning/gateway_integration_plan.md` for the rationale and
//! ABI mappings, and `docs/api/gateway.openapi.yaml` for the
//! machine-readable contract.
//!
//! ## Status
//!
//! The gateway owns its **whole** HTTP stack (the transport-neutral
//! [`http::conn`] handler over the workspace's `rustls 0.23` — **no**
//! `tiny_http`): one thread per connection on both the plaintext
//! ([`http::plain`]) and native-TLS ([`http::tls`]) listeners, each with a
//! socket-owned read/write timeout + a per-request read deadline.  The full
//! surface is in place:
//!
//!   * `GET /healthz` — liveness (always 200 while the process runs).
//!   * `GET /readyz`  — readiness: probes the indexer (a fresh cursor
//!     read) and the host / event-subscribe upstreams (a TCP connect),
//!     `200` iff all configured probes pass else `503` (G1.8).
//!   * `GET /v1/info` — deployment metadata: deployment id + admission
//!     stage (config echo), the host / event-subscribe wire protocol
//!     versions, and the live indexer cursor (G1.8).
//!   * the read endpoints — `GET /v1/actors/{id}/balances[/{resource}]`,
//!     `/budget`, and `GET /v1/pools/{pool}?resource=` (G1.6b / G1.7).
//!   * the submit path — `POST /v1/actions` (G2), forwarding client-signed
//!     `SignedAction` bytes opaquely to the host.
//!   * the events track — `GET /v1/events` backfill + `GET /v1/events/stream`
//!     SSE fan-out (G3).
//!   * `POST /rpc` — a minimal, read-only Ethereum JSON-RPC shim
//!     ([`rpc`]): `eth_chainId` / `net_version` / `eth_blockNumber` /
//!     `web3_clientVersion`, so a browser wallet can "Add Network" and sign
//!     L2 actions against the Knomosis L2 chain id (auth-exempt; Knomosis is
//!     not an EVM chain, so there is no transaction surface here).
//!   * the G4 hardening — auth (G1.4), rate limiting (G1.3), observability
//!     (G4.3), graceful shutdown (G4.4), native TLS + mTLS (+ CRL revocation)
//!     (G4.2), browser CORS ([`cors`]), and the `--dev` mock-upstream profile
//!     ([`dev`]).
//!
//! ## Constraints (inherited from `runtime/`)
//!
//!   * **No `tokio`.**  Synchronous, thread-based (mirrors
//!     `knomosis-host`).
//!   * **`panic = "abort"` ⇒ panic-free request handlers.**  Under the
//!     workspace release profile a handler panic aborts the whole
//!     process, so request-path code is panic-free by construction
//!     (the `clippy::restriction` panic-lints are denied on those
//!     modules as they land in G1.2a).
//!   * **`unsafe_code = "forbid"`.**

/// The gateway crate version, injected at build time by cargo from
/// `Cargo.toml` (which inherits the workspace package version).
/// Mirrors the `*::VERSION` convention of the sibling crates.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The operator-facing identifier string this service publishes
/// through `/v1/info` and startup logs.  Mirrors the sibling crates'
/// `*_IDENTIFIER` constants; operators grep logs for it to confirm the
/// deployed gateway's lineage.
pub const GATEWAY_IDENTIFIER: &str = "knomosis-gateway/v1";

pub mod auth;
pub mod config;
pub mod cors;
pub mod dev;
pub mod dispatch;
pub mod events;
pub mod http;
pub mod logging;
pub mod observability;
pub mod problem;
pub mod rate_limit;
pub mod reads;
pub mod rpc;
pub mod state;
pub mod submit;
pub mod system;

#[cfg(test)]
mod tests {
    use super::{GATEWAY_IDENTIFIER, VERSION};

    /// The identifier constant is the documented v1 string.
    #[test]
    fn identifier_constant() {
        assert_eq!(GATEWAY_IDENTIFIER, "knomosis-gateway/v1");
    }

    /// The version constant is a non-empty semver-shaped string
    /// (cargo injects it from `Cargo.toml` at build time).
    #[test]
    fn version_constant_non_empty() {
        #[allow(clippy::const_is_empty)]
        let v: &str = VERSION;
        assert!(v.chars().next().is_some_and(|c| c.is_ascii_digit()));
    }
}
