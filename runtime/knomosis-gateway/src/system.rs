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
use std::sync::Mutex;
use std::time::{Duration, Instant};

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

/// How long a readiness result is served from cache before the probes
/// are run again.
///
/// **Why a cache is required rather than an optimisation.**  `/readyz`
/// is exempt from BOTH the auth gate ([`crate::auth::is_exempt_path`])
/// and the rate limiter (which returns early on the same exempt set),
/// so it is reachable by anyone who can open a socket, without a
/// credential and without a budget.  Each uncached call opens TWO TCP
/// connections to internal upstreams and reads the indexer — so an
/// unauthenticated caller could turn a cheap request stream into a
/// connection flood pointed at `knomosis-host` and
/// `knomosis-event-subscribe`, which is amplification in the plain
/// sense: the attacker spends one connection and the gateway spends
/// three.
///
/// It is worse than the connection count alone suggests, because
/// [`probe_tcp`] BLOCKS for up to [`READINESS_PROBE_TIMEOUT`] and the
/// server is thread-per-connection: probing a DEAD upstream pins a
/// thread for two seconds per request, so the flood costs threads as
/// well as sockets, and costs most exactly when the system is already
/// unhealthy.
///
/// One second is chosen against the consumer rather than the
/// attacker: orchestrators poll readiness on a 1–10 s period, so a
/// result at most this stale changes no scheduling decision, while the
/// probe rate becomes independent of the request rate.
const READINESS_CACHE_TTL: Duration = Duration::from_secs(1);

/// The OpenAPI `Info` schema.  `submitProtocolVersion` /
/// `eventsProtocolVersion` / `indexerSchemaVersion` are integers;
/// `indexerSeq` is a decimal string (the §2 bigint-as-string
/// discipline).  `indexerSchemaVersion` is `null` when reads are
/// disabled (no indexer to report).
#[derive(Serialize)]
struct InfoDto {
    #[serde(rename = "deploymentId")]
    deployment_id: String,
    #[serde(rename = "l2ChainId")]
    l2_chain_id: u64,
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
        l2_chain_id: state.config.l2_chain_id,
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

/// The cached readiness result and when it was taken.
///
/// Lives in [`crate::state::AppState`] so every connection thread
/// shares one.  See [`READINESS_CACHE_TTL`] for why this exists.
///
/// Two locks, deliberately: the SAMPLE lock is held only for the
/// microseconds a read or write takes and NEVER across a probe, so a
/// caller can always read the last sample immediately; the PROBE
/// permit is what one thread holds for the duration of a probe round,
/// so at most one probe is in flight.  A single mutex protecting both
/// cannot provide "serve the stale sample while a probe runs" — the
/// prober would hold the only lock for up to the 2 s connect timeout
/// per dead upstream, and every reader would queue behind it, which is
/// the thread-pinning this cache exists to remove.
#[derive(Debug, Default)]
pub struct ReadinessCache {
    /// The last taken sample.  `None` until the first probe completes.
    sample: Mutex<Option<CachedReadiness>>,
    /// The probe permit.  Held across a probe; acquired with
    /// `try_lock` so a caller that loses the race serves the stale
    /// sample instead of waiting.
    probing: Mutex<()>,
}

/// One taken readiness sample.
#[derive(Clone, Copy, Debug)]
struct CachedReadiness {
    taken_at: Instant,
    host: bool,
    subscribe: bool,
    indexer: bool,
}

impl ReadinessCache {
    /// Read the last sample, if any.  The lock is held only for the
    /// copy; a poisoned lock (a panic while writing) still yields the
    /// value, because readiness must keep answering.
    fn read(&self) -> Option<CachedReadiness> {
        match self.sample.lock() {
            Ok(guard) => *guard,
            Err(poisoned) => *poisoned.into_inner(),
        }
    }

    /// Publish a fresh sample.  Same momentary-lock discipline.
    fn write(&self, value: CachedReadiness) {
        match self.sample.lock() {
            Ok(mut guard) => *guard = Some(value),
            Err(poisoned) => *poisoned.into_inner() = Some(value),
        }
    }

    /// Serve a readiness sample, probing only if the cache is cold or
    /// stale.
    ///
    /// Concurrency contract, pinned by
    /// `a_probe_in_flight_does_not_block_other_callers`:
    ///
    ///   * at most ONE probe is in flight at a time (the permit);
    ///   * while it is, every other caller is served the previous
    ///     sample IMMEDIATELY — it does not queue behind the probe,
    ///     because queueing would reintroduce the thread-pinning this
    ///     cache exists to remove, just on a mutex instead of a
    ///     socket.  A slightly older sample is the right trade: those
    ///     callers were going to receive a sample from within the TTL
    ///     regardless;
    ///   * the single case that waits is a COLD cache (no sample ever
    ///     taken), where there is nothing to serve.  That happens once
    ///     per process.
    fn sample<F: FnOnce() -> CachedReadiness>(&self, probe: F) -> CachedReadiness {
        // Fast path: a fresh sample.
        if let Some(cached) = self.read() {
            if cached.taken_at.elapsed() < READINESS_CACHE_TTL {
                return cached;
            }
        }
        // Stale or cold: try to become the prober.
        match self.probing.try_lock() {
            Ok(_permit) => {
                // Re-check under the permit: another prober may have
                // refreshed between the fast path and here.
                if let Some(cached) = self.read() {
                    if cached.taken_at.elapsed() < READINESS_CACHE_TTL {
                        return cached;
                    }
                }
                let fresh = probe();
                self.write(fresh);
                fresh
            }
            Err(std::sync::TryLockError::Poisoned(poisoned)) => {
                // A prior prober panicked while holding the permit.
                // Take it over and probe afresh.
                let _permit = poisoned.into_inner();
                let fresh = probe();
                self.write(fresh);
                fresh
            }
            Err(std::sync::TryLockError::WouldBlock) => {
                // A probe is in flight on another thread.  Serve the
                // stale sample immediately.
                if let Some(cached) = self.read() {
                    return cached;
                }
                // Cold cache: nothing to serve, so wait for the
                // in-flight probe and read its result.
                let _permit = match self.probing.lock() {
                    Ok(guard) => guard,
                    Err(poisoned) => poisoned.into_inner(),
                };
                if let Some(cached) = self.read() {
                    return cached;
                }
                // The prober died before publishing; probe ourselves
                // (still holding the permit, so no stampede).
                let fresh = probe();
                self.write(fresh);
                fresh
            }
        }
    }
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
    let sample = state.readiness.sample(|| CachedReadiness {
        taken_at: Instant::now(),
        indexer: probe_indexer(state),
        host: probe_tcp(state.config.host_addr),
        subscribe: probe_tcp(state.config.event_subscribe_addr),
    });
    let (indexer, host, subscribe) = (sample.indexer, sample.host, sample.subscribe);
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
    use super::{info_view, readyz, READINESS_CACHE_TTL};
    use crate::config::{AdmissionStage, Config};
    use crate::state::AppState;
    use knomosis_indexer::cursor::{ensure_identifier, CURSOR_KEY};
    use knomosis_indexer::INDEXER_IDENTIFIER;
    use knomosis_storage::sqlite::SqliteStorage;
    use knomosis_storage::storage::Storage;
    use std::net::{SocketAddr, TcpListener};
    use std::time::{Duration, Instant};

    /// A config with no indexer + no upstreams, overridable by the caller.
    fn config() -> Config {
        Config {
            listen: "127.0.0.1:0".parse().expect("loopback addr"),
            max_connections: 1,
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
            max_frame_size: 1024 * 1024,
            idempotency_ttl_secs: 0,
            sse: crate::config::SseConfig::default(),
            tls: None,
            cors_origin: None,
            log_format: crate::config::LogFormat::Json,
            dev: false,
            upstream_subscriptions: 1,
            l2_chain_id: 83572,
        }
    }

    /// Seed an indexer DB with the given cursor; return the tempdir, the
    /// LIVE writer, and the on-disk path (opened read-only by `AppState`).
    fn seeded_indexer(cursor: u64) -> (tempfile::TempDir, SqliteStorage, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.db");
        let writer = SqliteStorage::open(&path).unwrap();
        ensure_identifier(&writer, INDEXER_IDENTIFIER).expect("seed indexer identity");
        writer.put(CURSOR_KEY, &cursor.to_be_bytes()).unwrap();
        (dir, writer, path)
    }

    #[test]
    fn info_reports_config_and_protocol_versions() {
        let (_dir, writer, path) = seeded_indexer(4242);
        let mut cfg = config();
        cfg.indexer_db = Some(path);
        cfg.deployment_id = "knx-devnet".to_string();
        cfg.l2_chain_id = 8357;
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
        assert_eq!(v["l2ChainId"], 8357);
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
        assert_eq!(v["l2ChainId"], 83572); // the test-default L2 chain id
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

    /// **The non-blocking contract.**  A caller arriving while a
    /// probe is in flight is served the previous sample immediately —
    /// it does not queue behind the probe.
    ///
    /// This is the property the two-lock design exists for, and the
    /// one a single-mutex cache cannot provide: there, the prober
    /// holds the only lock for up to the 2 s connect timeout per dead
    /// upstream, and every concurrent `/readyz` pins a thread behind
    /// it — worst exactly when an upstream is down and readiness is
    /// being polled hardest.  The probe here blocks on a channel until
    /// the test releases it, so "in flight" is a certainty rather than
    /// a race; the reader's result arrives through a watchdog channel
    /// so a regression fails with a message instead of deadlocking the
    /// suite.
    #[test]
    fn a_probe_in_flight_does_not_block_other_callers() {
        use std::sync::mpsc;
        use std::sync::Arc;

        let cache = Arc::new(super::ReadinessCache::default());
        // Seed a STALE sample (twice the TTL old) so the next caller
        // must probe rather than hit the fast path.
        cache.write(super::CachedReadiness {
            taken_at: Instant::now()
                .checked_sub(READINESS_CACHE_TTL * 2)
                .expect("the monotonic clock has more than 2s of history"),
            host: true,
            subscribe: true,
            indexer: true,
        });

        let (started_tx, started_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let prober = {
            let cache = Arc::clone(&cache);
            std::thread::spawn(move || {
                cache.sample(|| {
                    started_tx.send(()).expect("test alive");
                    release_rx.recv().expect("released");
                    super::CachedReadiness {
                        taken_at: Instant::now(),
                        host: false,
                        subscribe: true,
                        indexer: true,
                    }
                })
            })
        };
        started_rx.recv().expect("the probe is in flight");

        // A second caller must be served the STALE sample now, without
        // waiting for the probe.  Its own probe closure must never run
        // -- one probe at a time is the other half of the contract.
        let (served_tx, served_rx) = mpsc::channel();
        let reader = {
            let cache = Arc::clone(&cache);
            std::thread::spawn(move || {
                let served = cache.sample(|| panic!("a second probe ran while one was in flight"));
                served_tx.send(served).expect("test alive");
            })
        };
        if let Ok(served) = served_rx.recv_timeout(Duration::from_secs(2)) {
            assert!(served.host, "the STALE sample is what gets served");
        } else {
            let _ = release_tx.send(());
            panic!(
                "the caller queued behind the in-flight probe instead of \
                 being served the stale sample"
            );
        }
        reader.join().expect("reader exits");

        release_tx.send(()).expect("prober alive");
        let fresh = prober.join().expect("prober exits");
        assert!(!fresh.host, "the prober received its own fresh sample");
        assert!(
            !cache.read().expect("published").host,
            "...and published it for the next caller"
        );
    }

    /// **The amplification bound.**  Repeated `/readyz` calls inside
    /// the TTL probe the upstream ONCE.
    ///
    /// `/readyz` is exempt from auth and from the rate limiter, so
    /// without the cache each call opens a fresh TCP connection to
    /// every configured upstream and an unauthenticated caller turns
    /// one request into three.  Counted at the LISTENER — the number
    /// of accepted connections is the amplification factor, so this
    /// measures the property directly rather than asserting the cache
    /// was consulted.
    #[test]
    fn readyz_probes_are_coalesced_within_the_ttl() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let live: SocketAddr = listener.local_addr().expect("addr");
        listener.set_nonblocking(true).expect("nonblocking");

        let mut cfg = config();
        cfg.host_addr = Some(live);
        let state = AppState::new(cfg).expect("open state");

        for _ in 0..25 {
            let o = readyz(&state);
            assert_eq!(o.status, 200, "every call still answers");
        }

        let mut accepted = 0;
        while listener.accept().is_ok() {
            accepted += 1;
        }
        assert_eq!(
            accepted, 1,
            "25 calls must cost ONE upstream connection, not 25"
        );
    }

    /// ...and the cache expires, so readiness is not frozen.
    ///
    /// The negative control for the case above: a cache that never
    /// re-probed would pass it while reporting a dead upstream as
    /// healthy forever, which is worse than the amplification it
    /// fixes.
    #[test]
    fn readyz_reprobes_after_the_ttl_expires() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let live: SocketAddr = listener.local_addr().expect("addr");
        listener.set_nonblocking(true).expect("nonblocking");

        let mut cfg = config();
        cfg.host_addr = Some(live);
        let state = AppState::new(cfg).expect("open state");

        let _ = readyz(&state);
        std::thread::sleep(READINESS_CACHE_TTL + Duration::from_millis(50));
        let _ = readyz(&state);

        let mut accepted = 0;
        while listener.accept().is_ok() {
            accepted += 1;
        }
        assert_eq!(accepted, 2, "a call after the TTL probes again");
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
