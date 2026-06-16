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
//! **G1.1 crate scaffold.**  This landing wires the crate into the
//! workspace and stands up the HTTP substrate (the vetted synchronous
//! `tiny_http` server, per the G1.0 decision in
//! `docs/audits/gateway_http_spike.md`) serving:
//!
//!   * `GET /healthz` — liveness (always 200 while the process runs).
//!   * `GET /readyz`  — readiness (200 **stub**; G1.8 probes the host,
//!     event-subscribe, and the indexer DB/writer-liveness).
//!   * `GET /v1/info` — deployment metadata (200 **stub**; G1.8 fills
//!     in the kernel admission stage, protocol versions, indexer
//!     cursor, and the echoed budget/pool config).
//!
//! The request parser + limits, the full routing table (405 + `Allow`,
//! the `/v1` resource surface), the RFC 9457 problem responder,
//! AuthN, the bounded acceptor + governors, the read endpoints (over
//! `knomosis_storage::sqlite::SqliteStorage::open_read_only`, the
//! G1.6a path), the submit path, and the SSE fan-out land in G1.2–G3.
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

pub mod config;
pub mod dispatch;
pub mod http;
pub mod problem;
pub mod reads;
pub mod state;

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
