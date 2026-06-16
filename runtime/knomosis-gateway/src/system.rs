// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The system endpoints (G1.8): `GET /v1/info` (deployment + protocol
//! metadata) and `GET /readyz` (the upstream readiness probe).
//!
//! `/v1/info` reports the operator-configured deployment id + `Verdict::Ok`
//! admission stage, the live host / event-subscribe wire `PROTOCOL_VERSION`
//! constants (a single source of truth — no hardcoded version), and the
//! current indexer cursor.
//!
//! `/readyz` probes each configured upstream — the indexer (a fresh
//! cursor read over the read-only handle) and the host / event-subscribe
//! addresses (a bare TCP connect within [`READINESS_PROBE_TIMEOUT`]) —
//! and answers `200` iff every probe is satisfied, else `503`.  An
//! **unconfigured** upstream is treated as satisfied (not blocking): a
//! read-only deployment configures only `--indexer-db`, so its readiness
//! gates on the indexer alone; the submit (G2) / SSE (G3) upstreams
//! activate when their addresses are configured.  `/healthz` (liveness)
//! stays a static `200` in the dispatcher — it asserts only that the
//! process is up.

use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

use knomosis_indexer::cursor::read_cursor;
use serde::Serialize;

use crate::http::RouteOutcome;
use crate::problem::Problem;
use crate::state::AppState;

/// The TCP-connect deadline for an upstream readiness probe.  Kept short
/// so an orchestrator's readiness polling is not slowed by a dead
/// upstream; a configurable timeout lands with the full governor surface
/// (G1.3).
const READINESS_PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// The OpenAPI `Info` schema.  `submitProtocolVersion` /
/// `eventsProtocolVersion` / `indexerSchemaVersion` are integers;
/// `indexerSeq` is a decimal string (the §2 bigint-as-string
/// discipline).  `indexerSchemaVersion` is `null` when reads are
/// disabled (no indexer to report).
#[derive(Serialize)]
struct InfoDto {
    #[serde(rename = "deploymentId")]
    deployment_id: String,
    #[serde(rename = "okAdmissionStage")]
    ok_admission_stage: &'static str,
    #[serde(rename = "submitProtocolVersion")]
    submit_protocol_version: u32,
    #[serde(rename = "eventsProtocolVersion")]
    events_protocol_version: u32,
    #[serde(rename = "indexerSeq")]
    indexer_seq: String,
    #[serde(rename = "indexerSchemaVersion")]
    indexer_schema_version: Option<u32>,
    #[serde(rename = "budgetPolicy")]
    budget_policy: BudgetPolicyEcho,
}

/// The gateway's echoed budget / gas-pool configuration, surfaced in
/// `/v1/info` so an operator can diff it against the deployment's actual
/// policy and the indexer's `--gas-pool-actor` (these are operator
/// obligations the gateway cannot self-verify, §9.2; surfacing them
/// makes a config drift observable).
#[derive(Serialize)]
struct BudgetPolicyEcho {
    #[serde(rename = "freeTier")]
    free_tier: String,
    #[serde(rename = "actionCost")]
    action_cost: String,
    #[serde(rename = "epochLength")]
    epoch_length: String,
    #[serde(rename = "gasPoolActor")]
    gas_pool_actor: Option<String>,
}

/// `GET /v1/info` — deployment + protocol metadata.
#[must_use]
pub fn info_view(state: &AppState) -> RouteOutcome {
    // The indexer cursor + schema version the gateway currently reflects:
    // live reads when reads are enabled, else "0" / null (no --indexer-db;
    // a submit-only deployment has no indexer).  An absent cursor cell
    // reads as 0; only a genuine backend error surfaces as a 500.
    let (indexer_seq, indexer_schema_version) = match &state.reads {
        Some(reads) => {
            let seq = match read_cursor(&reads.storage) {
                Ok(seq) => seq,
                Err(e) => return read_failed("indexer cursor read failed", &e.to_string()),
            };
            let schema = match reads.storage.schema_version() {
                Ok(v) => v,
                Err(e) => return read_failed("indexer schema version read failed", &e.to_string()),
            };
            (seq, Some(schema))
        }
        None => (0, None),
    };
    let dto = InfoDto {
        deployment_id: state.config.deployment_id.clone(),
        ok_admission_stage: state.config.ok_admission_stage.as_str(),
        submit_protocol_version: knomosis_host::PROTOCOL_VERSION,
        events_protocol_version: knomosis_event_subscribe::PROTOCOL_VERSION,
        indexer_seq: indexer_seq.to_string(),
        indexer_schema_version,
        budget_policy: BudgetPolicyEcho {
            free_tier: state.config.free_tier.to_string(),
            action_cost: state.config.action_cost.to_string(),
            epoch_length: state.config.epoch_length.to_string(),
            gas_pool_actor: state.config.gas_pool_actor.map(|a| a.to_string()),
        },
    };
    let body = serde_json::to_string(&dto).unwrap_or_else(|_| "{}".to_string());
    RouteOutcome::json(200, body)
}

/// The OpenAPI `Readiness` schema: the overall `ready` flag plus the
/// per-upstream booleans.  The four-boolean shape is fixed by the
/// contract (`{ready, host, subscribe, indexer}`), so the
/// `struct_excessive_bools` heuristic (which suggests a state machine)
/// does not apply — this is a wire DTO, not control flow.
#[allow(clippy::struct_excessive_bools)]
#[derive(Serialize)]
struct ReadinessDto {
    ready: bool,
    host: bool,
    subscribe: bool,
    indexer: bool,
}

/// `GET /readyz` — probe every configured upstream.  Answers `200` when
/// all probes are satisfied, else `503`; the `Readiness` body carries
/// the per-probe booleans in both cases (per the contract).
#[must_use]
pub fn readyz(state: &AppState) -> RouteOutcome {
    let indexer = probe_indexer(state);
    let host = probe_tcp(state.config.host_addr);
    let subscribe = probe_tcp(state.config.event_subscribe_addr);
    let ready = indexer && host && subscribe;
    let dto = ReadinessDto {
        ready,
        host,
        subscribe,
        indexer,
    };
    let body = serde_json::to_string(&dto).unwrap_or_else(|_| "{}".to_string());
    let status = if ready { 200 } else { 503 };
    RouteOutcome::json(status, body)
}

/// Probe the indexer: a fresh cursor read over the held read-only
/// handle confirms the database is still queryable.  An unconfigured
/// indexer (no `--indexer-db`) is satisfied (not blocking).
fn probe_indexer(state: &AppState) -> bool {
    match &state.reads {
        Some(reads) => read_cursor(&reads.storage).is_ok(),
        None => true,
    }
}

/// Probe an upstream by a bare TCP connect within
/// [`READINESS_PROBE_TIMEOUT`].  An unconfigured address (`None`) is
/// satisfied (not blocking).
fn probe_tcp(addr: Option<SocketAddr>) -> bool {
    match addr {
        None => true,
        Some(a) => TcpStream::connect_timeout(&a, READINESS_PROBE_TIMEOUT).is_ok(),
    }
}

/// A `500` problem for an unexpected read-backend failure.
fn read_failed(title: &str, detail: &str) -> RouteOutcome {
    Problem::new("read-failed", title, 500)
        .with_detail(detail.to_string())
        .into_outcome()
}

#[cfg(test)]
mod tests {
    use super::{info_view, readyz};
    use crate::config::{AdmissionStage, Config};
    use crate::state::AppState;
    use knomosis_indexer::cursor::CURSOR_KEY;
    use knomosis_storage::sqlite::SqliteStorage;
    use knomosis_storage::storage::Storage;
    use std::net::{SocketAddr, TcpListener};

    /// A config with no indexer + no upstreams, overridable by the caller.
    fn config() -> Config {
        Config {
            listen: "127.0.0.1:0".parse().expect("loopback addr"),
            handler_threads: 1,
            indexer_db: None,
            free_tier: 0,
            action_cost: 0,
            epoch_length: 0,
            gas_pool_actor: None,
            deployment_id: String::new(),
            ok_admission_stage: AdmissionStage::Finalized,
            host_addr: None,
            event_subscribe_addr: None,
            auth_token_file: None,
            rate_limit_rps: 0,
            host_pool_size: 8,
            host_max_inflight: 8,
            request_deadline_ms: 5000,
        }
    }

    /// Seed an indexer DB with the given cursor; return the tempdir, the
    /// LIVE writer, and the on-disk path (opened read-only by `AppState`).
    fn seeded_indexer(cursor: u64) -> (tempfile::TempDir, SqliteStorage, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.db");
        let writer = SqliteStorage::open(&path).unwrap();
        writer.put(CURSOR_KEY, &cursor.to_be_bytes()).unwrap();
        (dir, writer, path)
    }

    #[test]
    fn info_reports_config_and_protocol_versions() {
        let (_dir, writer, path) = seeded_indexer(4242);
        let mut cfg = config();
        cfg.indexer_db = Some(path);
        cfg.deployment_id = "knx-devnet".to_string();
        cfg.ok_admission_stage = AdmissionStage::Sequenced;
        cfg.free_tier = 1000;
        cfg.action_cost = 5;
        cfg.epoch_length = 7200;
        cfg.gas_pool_actor = Some(161);
        let state = AppState::new(cfg).expect("open state");

        let o = info_view(&state);
        assert_eq!(o.status, 200);
        assert_eq!(o.content_type, "application/json");
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["deploymentId"], "knx-devnet");
        assert_eq!(v["okAdmissionStage"], "Sequenced");
        // The real wire constants (host = 2, event-subscribe = 1).
        assert_eq!(v["submitProtocolVersion"], knomosis_host::PROTOCOL_VERSION);
        assert_eq!(
            v["eventsProtocolVersion"],
            knomosis_event_subscribe::PROTOCOL_VERSION
        );
        assert_eq!(v["indexerSeq"], "4242");
        // The indexer schema version is reported when reads are enabled.
        assert_eq!(
            v["indexerSchemaVersion"],
            knomosis_storage::migration::target_schema_version()
        );
        // The budget/pool config echo (drift observability).
        assert_eq!(v["budgetPolicy"]["freeTier"], "1000");
        assert_eq!(v["budgetPolicy"]["actionCost"], "5");
        assert_eq!(v["budgetPolicy"]["epochLength"], "7200");
        assert_eq!(v["budgetPolicy"]["gasPoolActor"], "161");
        drop(writer);
    }

    #[test]
    fn info_without_indexer_reports_zero_seq_and_finalized_default() {
        let state = AppState::new(config()).expect("open state");
        let o = info_view(&state);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["indexerSeq"], "0");
        assert_eq!(v["okAdmissionStage"], "Finalized"); // the default
        assert_eq!(v["deploymentId"], "");
        // No indexer → null schema version; the budget echo defaults to 0s.
        assert!(v["indexerSchemaVersion"].is_null());
        assert_eq!(v["budgetPolicy"]["freeTier"], "0");
        assert_eq!(v["budgetPolicy"]["actionCost"], "0");
        assert!(v["budgetPolicy"]["gasPoolActor"].is_null());
        drop(state);
    }

    #[test]
    fn readyz_with_no_upstreams_is_ready() {
        // No indexer, no host, no subscribe → every probe is "not
        // blocking" → ready.
        let state = AppState::new(config()).expect("open state");
        let o = readyz(&state);
        assert_eq!(o.status, 200);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["ready"], true);
        assert_eq!(v["host"], true);
        assert_eq!(v["subscribe"], true);
        assert_eq!(v["indexer"], true);
        drop(state);
    }

    #[test]
    fn readyz_probes_configured_indexer() {
        let (_dir, writer, path) = seeded_indexer(7);
        let mut cfg = config();
        cfg.indexer_db = Some(path);
        let state = AppState::new(cfg).expect("open state");
        let o = readyz(&state);
        assert_eq!(o.status, 200);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["indexer"], true);
        assert_eq!(v["ready"], true);
        drop(writer);
    }

    #[test]
    fn readyz_live_host_probe_succeeds_dead_one_fails() {
        // A bound listener accepts the probe's connect → host = true.
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let live: SocketAddr = listener.local_addr().expect("addr");
        let mut cfg = config();
        cfg.host_addr = Some(live);
        let state = AppState::new(cfg).expect("open state");
        let o = readyz(&state);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["host"], true);
        assert_eq!(v["ready"], true);
        drop(state);

        // Bind then drop a listener to obtain an address nothing listens
        // on → the connect fails → host = false → 503.
        let probe = TcpListener::bind("127.0.0.1:0").expect("bind");
        let dead: SocketAddr = probe.local_addr().expect("addr");
        drop(probe);
        let mut cfg = config();
        cfg.host_addr = Some(dead);
        let state = AppState::new(cfg).expect("open state");
        let o = readyz(&state);
        assert_eq!(o.status, 503);
        let v: serde_json::Value = serde_json::from_str(&o.body).unwrap();
        assert_eq!(v["host"], false);
        assert_eq!(v["ready"], false);
        // The other probes remain satisfied.
        assert_eq!(v["subscribe"], true);
        assert_eq!(v["indexer"], true);
        drop(state);

        // Keep the live listener alive until the end so its port is not
        // reused by the "dead" bind above.
        drop(listener);
    }
}
