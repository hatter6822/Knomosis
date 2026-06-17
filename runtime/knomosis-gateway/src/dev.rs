// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The `--dev` mock-upstream profile (§9.3).
//!
//! Running with `--dev` stands up **in-process** mock upstreams so a Licio
//! developer can iterate the BFF against a single gateway binary with no full
//! Knomosis stack:
//!
//!   * a **mock host** — a real [`knomosis_host::server::Server`] over a
//!     [`knomosis_host::kernel::mock::MockKernel`] (every submit returns
//!     `Verdict::Ok`) on an ephemeral loopback port, so `POST /v1/actions`
//!     succeeds;
//!   * a **seeded indexer DB** — a temp `SqliteStorage` migrated to the real
//!     indexer schema and seeded with demo balances / a gas pool / a cursor,
//!     opened **read-only** by the gateway exactly as in production (so the
//!     G1.6a read-only open path is exercised even in dev); the writer handle
//!     is held alive for the WAL;
//!   * a **mock event-subscribe** — a real
//!     [`knomosis_event_subscribe::server::Server`] over a
//!     [`knomosis_event_subscribe::extract::mock::MockExtractor`] driven by a
//!     seeded log, emitting real CBE-encoded events (including a multi-event
//!     seq-group — a transfer's sender + receiver `balanceChanged`), so
//!     `GET /v1/events` + `/v1/events/stream` return real data.
//!
//! [`start`] binds the three mocks, **rewrites** the config's
//! `host_addr` / `event_subscribe_addr` / `indexer_db` to point at them, and
//! returns a [`DevProfile`] handle the gateway holds for its lifetime; the
//! handle's `Drop` stops every mock server and removes the temp directory.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use knomosis_event_subscribe::event_cache::EventCache;
use knomosis_event_subscribe::extract::mock::{MockExtractor, MockResponse};
use knomosis_event_subscribe::server::{Server as EventServer, ServerConfig as EventServerConfig};
use knomosis_event_subscribe::subscription::SubscriberRegistry;
use knomosis_event_subscribe::tail::TailReader;
use knomosis_host::kernel::mock::MockKernel;
use knomosis_host::listener::tcp::TcpListener as HostTcpListener;
use knomosis_host::server::{Server as HostServer, ServerConfigBuilder};
use knomosis_indexer::balance::balance_key;
use knomosis_indexer::cursor::{ensure_identifier, CURSOR_KEY};
use knomosis_indexer::decoder::encode_event;
use knomosis_indexer::event::Event;
use knomosis_indexer::INDEXER_IDENTIFIER;
use knomosis_storage::sqlite::SqliteStorage;
use knomosis_storage::storage::Storage;

use crate::config::Config;

/// The demo gas-pool actor id the seeded pool view is attributed to (so a
/// `GET /v1/pools/{id}` against it reports `net = true` when the gateway is
/// also started `--dev`-implied `--gas-pool-actor`).
const DEV_GAS_POOL_ACTOR: u64 = 161;

/// Demo `(actor, resource, balance)` rows seeded into the indexer DB.
const DEV_BALANCES: &[(u64, u64, u128)] = &[
    (1, 0, 900),    // actor 1, ETH
    (2, 0, 100),    // actor 2, ETH
    (3, 0, 500),    // actor 3, ETH (minted)
    (1, 1, 25_000), // actor 1, BOLD
];

/// The indexer cursor seq the seeded DB advertises (the newest demo event seq);
/// `/readyz` reads it and the `/v1/events` backfill uses it as the tip.
const DEV_CURSOR_SEQ: u64 = 3;

/// The in-memory event cache depth for the mock event-subscribe server.
const DEV_EVENT_CACHE_CAPACITY: usize = 256;

/// A live handle to the `--dev` mock upstreams.  Dropping it stops every mock
/// server (via the shared `stop` flag) and removes the temp directory; the
/// gateway holds it for the whole of [`crate::http::serve`].
pub struct DevProfile {
    /// The shared stop flag every mock server observes.
    stop: Arc<AtomicBool>,
    /// The mock-server threads (host + event-subscribe), joined on drop.
    threads: Vec<JoinHandle<()>>,
    /// The seeded-DB writer handle, held so the WAL stays live for the
    /// gateway's read-only reader (never used directly after seeding).
    _writer: SqliteStorage,
    /// The temp directory holding the seeded DB + event log, removed on drop.
    tempdir: PathBuf,
}

impl std::fmt::Debug for DevProfile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DevProfile")
            .field("threads", &self.threads.len())
            .field("tempdir", &self.tempdir)
            .finish_non_exhaustive()
    }
}

impl Drop for DevProfile {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        for handle in self.threads.drain(..) {
            let _ = handle.join();
        }
        // Best-effort temp cleanup (the OS reclaims it regardless on reboot).
        let _ = std::fs::remove_dir_all(&self.tempdir);
    }
}

/// Errors standing up the `--dev` mock upstreams.
#[derive(Debug, thiserror::Error)]
pub enum DevError {
    /// A filesystem operation (temp dir / event log) failed.
    #[error("dev profile filesystem error: {0}")]
    Io(#[from] std::io::Error),
    /// Seeding the temp indexer database failed.
    #[error("dev profile indexer seed failed: {0}")]
    Seed(String),
    /// Building the mock event-subscribe server failed.
    #[error("dev profile event-subscribe setup failed: {0}")]
    Events(String),
}

/// Stand up the mock upstreams and **rewrite** `config` to point at them.
///
/// Returns the rewritten config alongside the live [`DevProfile`] the caller
/// must keep alive for the gateway's lifetime (its `Drop` stops the mocks).
///
/// # Errors
///
/// [`DevError`] if a temp file cannot be created, the indexer DB cannot be
/// seeded, or a mock server cannot be bound / built.
pub fn start(mut config: Config) -> Result<(Config, DevProfile), DevError> {
    let stop = Arc::new(AtomicBool::new(false));
    let mut threads = Vec::new();

    // A unique temp directory (pid + a monotonic salt) for this dev run.
    let tempdir =
        std::env::temp_dir().join(format!("knx-gw-dev-{}-{}", std::process::id(), dev_salt()));
    std::fs::create_dir_all(&tempdir)?;

    // 1) Seed a real indexer-shaped DB and keep the writer alive for the WAL.
    let db_path = tempdir.join("index.db");
    let writer = seed_indexer_db(&db_path).map_err(DevError::Seed)?;
    config.indexer_db = Some(db_path);

    // 2) Mock host (submit) — a MockKernel over an ephemeral loopback port.
    let host_addr = spawn_mock_host(&stop, &mut threads)?;
    config.host_addr = Some(host_addr);

    // 3) Mock event-subscribe (events / SSE) over a seeded log.
    let event_log = tempdir.join("events.log");
    let event_addr =
        spawn_mock_event_subscribe(&event_log, &stop, &mut threads).map_err(DevError::Events)?;
    config.event_subscribe_addr = Some(event_addr);

    // A pool view for the demo actor reads net-of-drains when the operator did
    // not override `--gas-pool-actor`.
    if config.gas_pool_actor.is_none() {
        config.gas_pool_actor = Some(DEV_GAS_POOL_ACTOR);
    }

    tracing::warn!(
        host = %host_addr,
        events = %event_addr,
        indexer_db = ?config.indexer_db,
        "running in --dev mode against IN-PROCESS MOCK upstreams (not for production)"
    );
    Ok((
        config,
        DevProfile {
            stop,
            threads,
            _writer: writer,
            tempdir,
        },
    ))
}

/// A process-monotonic salt so repeated dev runs in one process never collide
/// on the temp-directory name.
fn dev_salt() -> u64 {
    use std::sync::atomic::AtomicU64;
    static SALT: AtomicU64 = AtomicU64::new(0);
    SALT.fetch_add(1, Ordering::Relaxed)
}

/// Open + migrate a temp `SqliteStorage`, seed demo balances / a gas pool / the
/// cursor, and return the **writer** handle (kept alive so the gateway's
/// read-only reader sees the committed WAL data).
fn seed_indexer_db(path: &std::path::Path) -> Result<SqliteStorage, String> {
    let writer = SqliteStorage::open(path).map_err(|e| e.to_string())?;
    // Stamp the indexer identity cell so the gateway's read-only open (which
    // now verifies `c/identifier`) accepts this seeded DB as a real indexer DB.
    ensure_identifier(&writer, INDEXER_IDENTIFIER).map_err(|e| e.to_string())?;
    // Seed the gas pool (ETH + BOLD) in one combined transaction.
    let mut tx = writer.combined_transaction().map_err(|e| e.to_string())?;
    tx.credit_pool_eth(DEV_GAS_POOL_ACTOR, 1_000_000)
        .map_err(|e| e.to_string())?;
    tx.credit_pool_bold(DEV_GAS_POOL_ACTOR, 500_000)
        .map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())?;
    // Seed demo balances (16-byte big-endian u128 cells, the read view's codec).
    for &(actor, resource, amount) in DEV_BALANCES {
        writer
            .put(&balance_key(actor, resource), &amount.to_be_bytes())
            .map_err(|e| e.to_string())?;
    }
    // Seed the indexer cursor (the `/readyz` + backfill tip).
    writer
        .put(CURSOR_KEY, &DEV_CURSOR_SEQ.to_be_bytes())
        .map_err(|e| e.to_string())?;
    Ok(writer)
}

/// Bind an ephemeral loopback `knomosis-host` listener over a `MockKernel`
/// (every submit → `Verdict::Ok`) and run it on a thread.  Returns the bound
/// address for the gateway's submit pool.
fn spawn_mock_host(
    stop: &Arc<AtomicBool>,
    threads: &mut Vec<JoinHandle<()>>,
) -> Result<SocketAddr, DevError> {
    let listener = HostTcpListener::bind("127.0.0.1:0".parse().expect("loopback addr"))?;
    let addr = listener.local_addr()?;
    let config = ServerConfigBuilder::new()
        .tcp(listener)
        .build(Box::new(MockKernel::new()))
        .map_err(|e| DevError::Events(format!("mock host build: {e}")))?;
    let stop = Arc::clone(stop);
    let handle = std::thread::Builder::new()
        .name("knx-gw-dev-host".to_string())
        .spawn(move || HostServer::new(config).run(stop))?;
    threads.push(handle);
    Ok(addr)
}

/// Write the seeded event log, bind an ephemeral loopback
/// `knomosis-event-subscribe` listener over a `MockExtractor` programmed with
/// the demo events, and run it on a thread.  Returns the bound address.
fn spawn_mock_event_subscribe(
    event_log: &std::path::Path,
    stop: &Arc<AtomicBool>,
    threads: &mut Vec<JoinHandle<()>>,
) -> Result<SocketAddr, String> {
    let (responses, frame_count) = demo_event_responses();
    write_seeded_log(event_log, frame_count).map_err(|e| e.to_string())?;

    let listener = EventServer::bind("127.0.0.1:0".parse().expect("loopback addr"))
        .map_err(|e| e.to_string())?;
    let addr = listener.local_addr().map_err(|e| e.to_string())?;

    let tail = TailReader::open(event_log).map_err(|e| e.to_string())?;
    let extractor = MockExtractor::new();
    extractor.set_responses(responses);
    let cache = Arc::new(Mutex::new(
        EventCache::new(DEV_EVENT_CACHE_CAPACITY).map_err(|e| e.to_string())?,
    ));
    let registry = Arc::new(SubscriberRegistry::new());
    let config =
        EventServerConfig::with_defaults(listener, tail, Box::new(extractor), registry, cache);
    let stop = Arc::clone(stop);
    let handle = std::thread::Builder::new()
        .name("knx-gw-dev-events".to_string())
        .spawn(move || EventServer::new(config).run(stop))
        .map_err(|e| e.to_string())?;
    threads.push(handle);
    Ok(addr)
}

/// Build the demo event payloads the mock extractor emits, one `MockResponse`
/// per log frame.  Frame 1 is a **multi-event seq-group** (the sender's and
/// receiver's `balanceChanged` from one transfer); frames 2 and 3 are single
/// events.  Returns the responses and the matching frame count.
fn demo_event_responses() -> (Vec<MockResponse>, usize) {
    let responses = vec![
        // seq 1: transfer 100 ETH from actor 1 → actor 2 (two events, one group).
        MockResponse::Ok(vec![
            encode_event(&Event::BalanceChanged {
                resource: 0,
                actor: 1,
                old_value: 1000,
                new_value: 900,
            }),
            encode_event(&Event::BalanceChanged {
                resource: 0,
                actor: 2,
                old_value: 0,
                new_value: 100,
            }),
        ]),
        // seq 2: actor 1's nonce advances.
        MockResponse::Ok(vec![encode_event(&Event::NonceAdvanced {
            actor: 1,
            old_nonce: 0,
            new_nonce: 1,
        })]),
        // seq 3: actor 3 minted 500 ETH.
        MockResponse::Ok(vec![encode_event(&Event::BalanceChanged {
            resource: 0,
            actor: 3,
            old_value: 0,
            new_value: 500,
        })]),
    ];
    let frame_count = responses.len();
    (responses, frame_count)
}

/// Write `frame_count` valid log frames (each a tiny dummy payload — the mock
/// extractor maps frame *position* to the demo events, ignoring the payload) so
/// the tail reader drives exactly `frame_count` extract calls.
fn write_seeded_log(path: &std::path::Path, frame_count: usize) -> std::io::Result<()> {
    let mut bytes = Vec::new();
    for i in 0..frame_count {
        // A distinct 1-byte payload per frame (content is irrelevant to the mock).
        bytes.extend_from_slice(&encode_log_frame(&[u8::try_from(i & 0xff).unwrap_or(0)]));
    }
    std::fs::write(path, bytes)
}

/// Encode one event-log frame in the `knomosis-event-subscribe` tail format:
/// `"KNOM"` magic, an 8-byte little-endian payload length, the payload, then an
/// 8-byte little-endian FNV-1a-64 trailer over the payload (mirrors the private
/// encoder the tail reader validates against).
fn encode_log_frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(12 + payload.len() + 8);
    out.extend_from_slice(b"KNOM");
    out.extend_from_slice(&(payload.len() as u64).to_le_bytes());
    out.extend_from_slice(payload);
    out.extend_from_slice(&fnv1a64(payload).to_le_bytes());
    out
}

/// FNV-1a-64 over `bytes` (the tail frame trailer hash).
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for &b in bytes {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::{demo_event_responses, encode_log_frame, fnv1a64, start};
    use crate::config::Config;

    /// The seeded log frame round-trips the documented format: `KNOM` magic, a
    /// little-endian length, the payload, and a little-endian FNV-1a-64 trailer.
    #[test]
    fn log_frame_format() {
        let frame = encode_log_frame(b"hi");
        assert_eq!(&frame[0..4], b"KNOM");
        assert_eq!(u64::from_le_bytes(frame[4..12].try_into().unwrap()), 2);
        assert_eq!(&frame[12..14], b"hi");
        let trailer = u64::from_le_bytes(frame[14..22].try_into().unwrap());
        assert_eq!(trailer, fnv1a64(b"hi"));
    }

    /// The demo generator emits one multi-event seq-group (2 events) then two
    /// single events — three frames total.
    #[test]
    fn demo_events_have_a_multi_event_group() {
        let (responses, frames) = demo_event_responses();
        assert_eq!(frames, 3);
        let super::MockResponse::Ok(first) = &responses[0] else {
            panic!("first response is an Ok event list");
        };
        assert_eq!(first.len(), 2, "frame 1 is a multi-event seq-group");
    }

    /// `start` stands up all three mocks, rewrites the upstream config, and the
    /// dropped handle stops them cleanly.
    #[test]
    fn start_rewrites_config_and_seeds() {
        let base = Config::parse(&["knomosis-gateway".to_string()]).expect("default config");
        assert!(base.host_addr.is_none());
        let (config, profile) = start(base).expect("dev start");
        assert!(config.host_addr.is_some(), "mock host wired");
        assert!(config.event_subscribe_addr.is_some(), "mock events wired");
        assert!(config.indexer_db.is_some(), "seeded DB wired");
        // The seeded DB opens read-only (the gateway's own path).
        let db = config.indexer_db.clone().unwrap();
        assert!(db.exists(), "seeded DB file exists");
        drop(profile); // stops the mock servers + removes the temp dir
    }
}
