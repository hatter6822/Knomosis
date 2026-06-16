// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Gateway integration tests: the read **and** submit paths served
//! end-to-end over a real `tiny_http` listener + handler pool, against a
//! seeded read-only indexer SQLite database (reads) and a `MockHost`
//! (submit), through the full pipeline (auth → rate-limit → route →
//! dispatch → read / host round-trip).
//!
//! Covers: the `Balance` / `BalanceList` / `BudgetView` / `PoolView`
//! contract shapes over HTTP; `ETag` + `If-None-Match` → `304`; the
//! fail-closed auth gate (401 / 403) + rate-limit (429) on reads; a
//! concurrent-write chaos case (reads stay available, well-formed, and
//! cursor-monotonic — §3.6 eventual consistency); `POST /v1/actions`
//! (octet-stream / json+base64 intake, §5 verdict mapping, 503/415/413
//! backpressure); and the `Idempotency-Key` replay cache (a duplicate key
//! returns the cached response with no second host round-trip).

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use knomosis_gateway::config::{AdmissionStage, Config, SseConfig};
use knomosis_gateway::http::spawn_handler_pool;
use knomosis_gateway::state::AppState;
use knomosis_host::frame::{read_frame, DEFAULT_MAX_FRAME_SIZE};
use knomosis_host::verdict::{Verdict, VerdictResponse};
use knomosis_indexer::balance::balance_key;
use knomosis_indexer::budget_view::CURRENT_EPOCH_KEY;
use knomosis_indexer::client::KIND_EVENT;
use knomosis_indexer::cursor::CURSOR_KEY;
use knomosis_indexer::decoder::encode_event;
use knomosis_indexer::event::Event;
use knomosis_storage::sqlite::SqliteStorage;
use knomosis_storage::storage::Storage;

/// The bearer token the harness accepts.
const TOKEN: &str = "integration-token";

/// A running gateway over a seeded read-only indexer, with the live
/// writer kept open (WAL) so the chaos test can mutate concurrently.
struct Harness {
    _dir: tempfile::TempDir,
    writer: Arc<SqliteStorage>,
    server: Arc<tiny_http::Server>,
    // The worker `JoinHandle`s are detached on drop (we do not join):
    // `tiny_http::Server::unblock` wakes only one blocked `recv`, so
    // joining every worker would deadlock.  Any worker still blocked in
    // `recv` is reclaimed at process exit — there is no graceful pool
    // shutdown yet (G4.4), and this mirrors the smoke test's teardown.
    _workers: Vec<JoinHandle<()>>,
    addr: SocketAddr,
}

impl Drop for Harness {
    fn drop(&mut self) {
        // Best-effort nudge to the accept loop; the detached workers are
        // reclaimed at process exit.
        self.server.unblock();
    }
}

/// Start the gateway with rate limiting disabled and no submit host (the
/// common case for the read-path assertions).
fn start_harness() -> Harness {
    start_harness_full(0, None)
}

/// Start the gateway with the given rate cap and no submit host.
fn start_harness_rps(rate_limit_rps: u32) -> Harness {
    start_harness_full(rate_limit_rps, None)
}

/// Seed the indexer DB (balances, budget, pool, cursor) and start the
/// gateway over it (read-only) with a 4-thread handler pool, the given
/// per-credential rate cap (`0` = disabled), and an optional submit host
/// upstream (`--host-addr`).
fn start_harness_full(rate_limit_rps: u32, host_addr: Option<SocketAddr>) -> Harness {
    start_harness_cfg(rate_limit_rps, host_addr, None)
}

/// Start the gateway with an event-subscribe upstream wired (`G3.3`
/// backfill), no submit host, rate limiting disabled.  The seeded cursor
/// (`42`) is the backfill tip.
fn start_harness_events(event_subscribe_addr: SocketAddr) -> Harness {
    start_harness_cfg(0, None, Some(event_subscribe_addr))
}

/// The full harness builder: a seeded read-only indexer + a 4-thread pool,
/// with optional submit-host and event-subscribe upstreams.
fn start_harness_cfg(
    rate_limit_rps: u32,
    host_addr: Option<SocketAddr>,
    event_subscribe_addr: Option<SocketAddr>,
) -> Harness {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("index.db");
    let token_path = dir.path().join("tokens");
    std::fs::write(&token_path, TOKEN).expect("write token file");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&token_path, std::fs::Permissions::from_mode(0o600))
            .expect("chmod token file");
    }

    let writer = SqliteStorage::open(&db_path).expect("open writer");
    // Balances: actor 7 holds resources 0 (1000) and 1 (250); actor 9 a
    // distinct balance (must be excluded from actor 7's list).
    writer
        .put(&balance_key(7, 0), &1000u128.to_be_bytes())
        .unwrap();
    writer
        .put(&balance_key(7, 1), &250u128.to_be_bytes())
        .unwrap();
    writer
        .put(&balance_key(9, 0), &5u128.to_be_bytes())
        .unwrap();
    // Budget: epoch 3, grants 100, consumed 30.
    let mut tx = writer.combined_transaction().unwrap();
    tx.credit_actor_budget_current_epoch_grants(7, 100).unwrap();
    tx.credit_actor_budget_current_epoch_consumed(7, 30)
        .unwrap();
    tx.commit().unwrap();
    writer.put(CURRENT_EPOCH_KEY, &3u64.to_be_bytes()).unwrap();
    // Pool 161: ETH 1000.
    let mut tx = writer.combined_transaction().unwrap();
    tx.credit_pool_eth(161, 1000).unwrap();
    tx.commit().unwrap();
    // Cursor.
    writer.put(CURSOR_KEY, &42u64.to_be_bytes()).unwrap();

    let config = Config {
        listen: "127.0.0.1:0".parse().unwrap(),
        handler_threads: 4,
        indexer_db: Some(db_path),
        free_tier: 50,
        action_cost: 5,
        epoch_length: 0,
        gas_pool_actor: Some(161),
        deployment_id: "knx-integration".to_string(),
        ok_admission_stage: AdmissionStage::Finalized,
        host_addr,
        event_subscribe_addr,
        auth_token_file: Some(token_path),
        rate_limit_rps,
        host_pool_size: 8,
        host_max_inflight: 8,
        request_deadline_ms: 5000,
        max_frame_size: 1024 * 1024,
        idempotency_ttl_secs: 60,
        sse: SseConfig::default(),
    };
    let state = Arc::new(AppState::new(config).expect("open read-only state + load tokens"));
    let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind"));
    let addr = server.server_addr().to_ip().expect("ip addr");
    let workers = spawn_handler_pool(&server, 4, &state).expect("spawn pool");

    Harness {
        _dir: dir,
        writer: Arc::new(writer),
        server,
        _workers: workers,
        addr,
    }
}

/// A parsed HTTP response.
struct Resp {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
}

impl Resp {
    /// The first header value matching `name` (case-insensitive).
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    /// The body parsed as JSON.
    fn json(&self) -> serde_json::Value {
        serde_json::from_str(&self.body).expect("response body is JSON")
    }
}

/// `GET path` against the harness with optional bearer token + optional
/// `If-None-Match`, returning the parsed response.
///
/// Reads the response by its `Content-Length` rather than waiting for the
/// socket to close, so it is correct whether or not the (persistent)
/// server keeps the connection alive.  A `304` (no body) is recognised by
/// an absent / zero `Content-Length`.
fn http_get(addr: SocketAddr, path: &str, token: Option<&str>, inm: Option<&str>) -> Resp {
    let mut stream = TcpStream::connect(addr).expect("connect");
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(10)))
        .ok();
    let mut req = format!("GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n");
    if let Some(t) = token {
        req.push_str(&format!("Authorization: Bearer {t}\r\n"));
    }
    if let Some(m) = inm {
        req.push_str(&format!("If-None-Match: {m}\r\n"));
    }
    req.push_str("\r\n");
    stream.write_all(req.as_bytes()).expect("write request");
    read_http_response(&mut stream)
}

/// `POST path` with a `Content-Type` + body and an optional bearer token.
fn http_post(
    addr: SocketAddr,
    path: &str,
    content_type: &str,
    body: &[u8],
    token: Option<&str>,
) -> Resp {
    http_post_full(addr, path, content_type, body, token, None)
}

/// `POST path` with an `Idempotency-Key` header.
fn http_post_idem(
    addr: SocketAddr,
    path: &str,
    content_type: &str,
    body: &[u8],
    token: Option<&str>,
    idem: &str,
) -> Resp {
    http_post_full(addr, path, content_type, body, token, Some(idem))
}

/// The shared POST core: `Content-Type` + body + optional bearer token +
/// optional `Idempotency-Key`.
fn http_post_full(
    addr: SocketAddr,
    path: &str,
    content_type: &str,
    body: &[u8],
    token: Option<&str>,
    idem: Option<&str>,
) -> Resp {
    let mut stream = TcpStream::connect(addr).expect("connect");
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(10)))
        .ok();
    let mut head = format!(
        "POST {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\
         Content-Type: {content_type}\r\nContent-Length: {}\r\n",
        body.len()
    );
    if let Some(t) = token {
        head.push_str(&format!("Authorization: Bearer {t}\r\n"));
    }
    if let Some(k) = idem {
        head.push_str(&format!("Idempotency-Key: {k}\r\n"));
    }
    head.push_str("\r\n");
    let mut bytes = head.into_bytes();
    bytes.extend_from_slice(body);
    stream.write_all(&bytes).expect("write request");
    read_http_response(&mut stream)
}

/// Read a `Content-Length`-framed HTTP response (correct whether or not
/// the persistent server keeps the connection alive).
fn read_http_response(stream: &mut TcpStream) -> Resp {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        if let Some(resp) = try_parse(&buf) {
            return resp;
        }
        match stream.read(&mut chunk) {
            // EOF, or a read timeout — stop and parse what we have.
            Ok(0) | Err(_) => break,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
    try_parse(&buf).expect("a complete HTTP response")
}

/// Parse a raw response buffer iff it holds the full header block plus
/// `Content-Length` body bytes; otherwise `None` (read more).
fn try_parse(buf: &[u8]) -> Option<Resp> {
    let raw = String::from_utf8_lossy(buf);
    let (head, rest) = raw.split_once("\r\n\r\n")?;
    let mut lines = head.lines();
    let status = lines
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse::<u16>().ok())?;
    let headers: Vec<(String, String)> = lines
        .filter_map(|l| {
            l.split_once(": ")
                .map(|(n, v)| (n.to_string(), v.to_string()))
        })
        .collect();
    let content_length: usize = headers
        .iter()
        .find(|(n, _)| n.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.trim().parse().ok())
        .unwrap_or(0);
    // Only complete once the body has fully arrived.
    if rest.len() < content_length {
        return None;
    }
    Some(Resp {
        status,
        headers,
        body: rest[..content_length].to_string(),
    })
}

/// An authenticated GET (the common case).
fn get(addr: SocketAddr, path: &str) -> Resp {
    http_get(addr, path, Some(TOKEN), None)
}

#[test]
fn balance_list_endpoint_serves_contract_json() {
    let h = start_harness();
    let r = get(h.addr, "/v1/actors/7/balances");
    assert_eq!(r.status, 200);
    assert_eq!(r.header("Content-Type"), Some("application/json"));
    assert_eq!(r.header("X-Knomosis-Seq"), Some("42"));
    let v = r.json();
    assert_eq!(v["actorId"], "7");
    assert_eq!(v["seq"], "42");
    let balances = v["balances"].as_array().unwrap();
    assert_eq!(balances.len(), 2); // actor 9 excluded
    let amounts: Vec<&str> = balances
        .iter()
        .map(|b| b["amount"].as_str().unwrap())
        .collect();
    assert!(amounts.contains(&"1000"));
    assert!(amounts.contains(&"250"));
}

#[test]
fn single_balance_and_budget_and_pool_endpoints() {
    let h = start_harness();

    let r = get(h.addr, "/v1/actors/7/balances/0");
    assert_eq!(r.status, 200);
    assert_eq!(r.json()["amount"], "1000");

    // Budget: remaining = freeTier(50) + grants(100) − consumed(30) = 120.
    let r = get(h.addr, "/v1/actors/7/budget");
    assert_eq!(r.status, 200);
    let v = r.json();
    assert_eq!(v["epoch"], "3");
    assert_eq!(v["remaining"], "120");
    assert_eq!(v["freeTier"], "50");
    assert_eq!(v["actionCost"], "5");

    // Pool 161 is the configured gas-pool actor → net = true.
    let r = get(h.addr, "/v1/pools/161?resource=0");
    assert_eq!(r.status, 200);
    let v = r.json();
    assert_eq!(v["poolId"], "161");
    assert_eq!(v["balance"], "1000");
    assert_eq!(v["net"], true);

    // A different pool → net = false (gross).
    let r = get(h.addr, "/v1/pools/999?resource=0");
    assert_eq!(r.json()["net"], false);
}

#[test]
fn etag_revalidation_returns_304() {
    let h = start_harness();
    // First read: capture the weak ETag.
    let first = get(h.addr, "/v1/actors/7/balances");
    assert_eq!(first.status, 200);
    let etag = first.header("ETag").expect("ETag present").to_string();
    assert_eq!(etag, "W/\"7-42\"");

    // Re-request with If-None-Match → 304 Not Modified, empty body, ETag
    // preserved.
    let second = http_get(h.addr, "/v1/actors/7/balances", Some(TOKEN), Some(&etag));
    assert_eq!(second.status, 304);
    assert!(second.body.is_empty());
    assert_eq!(second.header("ETag"), Some(etag.as_str()));

    // A stale validator does NOT 304.
    let stale = http_get(
        h.addr,
        "/v1/actors/7/balances",
        Some(TOKEN),
        Some("W/\"7-1\""),
    );
    assert_eq!(stale.status, 200);
}

#[test]
fn auth_gate_enforced_on_reads() {
    let h = start_harness();
    // No credential → 401.
    let unauth = http_get(h.addr, "/v1/actors/7/balances", None, None);
    assert_eq!(unauth.status, 401);
    // Wrong credential → 403.
    let wrong = http_get(h.addr, "/v1/actors/7/balances", Some("nope"), None);
    assert_eq!(wrong.status, 403);
    // An unknown path is gated too (401, not 404 — no enumeration).
    let unknown = http_get(h.addr, "/v1/actors/7/nope", None, None);
    assert_eq!(unknown.status, 401);
}

/// The balance list endpoint stays **available, well-formed, and
/// cursor-monotonic** while the indexer writes concurrently.
///
/// The indexer-backed reads are **eventually-consistent** (§3.6): a
/// read-only SQLite connection cannot participate in WAL checkpointing,
/// so under heavy concurrent writes a `BEGIN DEFERRED` snapshot can lag
/// (and, at pathological checkpoint rates, briefly tear) the writer — a
/// momentarily-stale balance that self-corrects on the next read, which
/// the contract accepts (the kernel, not the indexer view, is
/// authoritative).  This test therefore asserts what the read endpoint
/// *guarantees* under concurrency — every read succeeds, returns a
/// well-formed `BalanceList` (no corruption / missing rows), and never
/// advertises a `seq` that goes backwards (the cursor is monotonic) —
/// rather than strict intra-snapshot atomicity (a storage-layer
/// hardening item tracked separately, outside the gateway).
#[test]
fn concurrent_writer_keeps_reads_well_formed_and_monotonic() {
    let h = start_harness();
    let writer = Arc::clone(&h.writer);
    let stop = Arc::new(AtomicBool::new(false));

    // Writer thread: advance both balances + the cursor at an
    // indexer-like rate while the reader hammers the list.
    let w_stop = Arc::clone(&stop);
    let writer_thread = thread::spawn(move || {
        let mut v: u128 = 1000;
        while !w_stop.load(Ordering::Relaxed) {
            let mut tx = writer.combined_transaction().unwrap();
            tx.kv_put(&balance_key(7, 0), &v.to_be_bytes()).unwrap();
            tx.kv_put(&balance_key(7, 1), &(v + 1).to_be_bytes())
                .unwrap();
            #[allow(clippy::cast_possible_truncation)]
            tx.kv_put(CURSOR_KEY, &(v as u64).to_be_bytes()).unwrap();
            tx.commit().unwrap();
            v += 1;
            thread::sleep(Duration::from_millis(1));
        }
    });

    let mut last_seq: u64 = 0;
    for _ in 0..300 {
        let r = get(h.addr, "/v1/actors/7/balances");
        assert_eq!(r.status, 200, "read failed under concurrent writes");
        let v = r.json();
        // The cursor (advertised seq) never goes backwards.
        let seq: u64 = v["seq"].as_str().unwrap().parse().unwrap();
        assert!(seq >= last_seq, "seq went backwards: {seq} < {last_seq}");
        last_seq = seq;
        // Well-formed: actor 7 always has both resources, valid amounts
        // (no corruption / dropped rows mid-write).
        let balances = v["balances"].as_array().unwrap();
        assert_eq!(balances.len(), 2, "actor 7 must always show both resources");
        for b in balances {
            let _amount: u128 = b["amount"].as_str().unwrap().parse().unwrap();
        }
    }

    stop.store(true, Ordering::Relaxed);
    writer_thread.join().unwrap();
}

/// A minimal submit-host stand-in: serves every framed request on every
/// connection with a fixed verdict (counting the frames it serves), until
/// dropped.
struct MockHost {
    addr: SocketAddr,
    served: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl MockHost {
    fn start(verdict: Verdict, reason: &'static str) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let addr = listener.local_addr().unwrap();
        let served = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let halt = Arc::clone(&stop);
        let frames = Arc::clone(&served);
        let handle = thread::spawn(move || {
            let mut conns = Vec::new();
            while !halt.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_millis(200)))
                            .ok();
                        let conn_frames = Arc::clone(&frames);
                        conns.push(thread::spawn(move || loop {
                            match read_frame(&mut stream, DEFAULT_MAX_FRAME_SIZE) {
                                Ok(_payload) => {
                                    conn_frames.fetch_add(1, Ordering::Relaxed);
                                    let resp =
                                        VerdictResponse::with_reason(verdict, reason).encode();
                                    if stream
                                        .write_all(&resp)
                                        .and_then(|()| stream.flush())
                                        .is_err()
                                    {
                                        return;
                                    }
                                }
                                Err(_) => return,
                            }
                        }));
                    }
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });
        Self {
            addr,
            served,
            stop,
            handle: Some(handle),
        }
    }
}

impl Drop for MockHost {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

#[test]
fn submit_octet_stream_round_trips_to_host() {
    let mock = MockHost::start(Verdict::Ok, "");
    let h = start_harness_full(0, Some(mock.addr));
    // The canonical octet-stream path: the body is the opaque CBE bytes.
    let resp = http_post(
        h.addr,
        "/v1/actions",
        "application/octet-stream",
        b"opaque-signed-action",
        Some(TOKEN),
    );
    assert_eq!(resp.status, 200);
    let v = resp.json();
    assert_eq!(v["accepted"], true);
    assert_eq!(v["verdict"], "Ok");
    assert_eq!(v["admissionStage"], "Finalized");
}

#[test]
fn submit_json_base64_round_trips_and_maps_not_admissible() {
    let mock = MockHost::start(Verdict::NotAdmissible, "InsufficientBudget");
    let h = start_harness_full(0, Some(mock.addr));
    // The JSON convenience path: signedAction is base64("foobar").
    let body = br#"{"signedAction":"Zm9vYmFy","encoding":"cbe"}"#;
    let resp = http_post(h.addr, "/v1/actions", "application/json", body, Some(TOKEN));
    // A kernel decline is still 200 (processing succeeded).
    assert_eq!(resp.status, 200);
    let v = resp.json();
    assert_eq!(v["accepted"], false);
    assert_eq!(v["verdict"], "NotAdmissible");
    assert_eq!(v["reason"], "InsufficientBudget");
}

#[test]
fn submit_without_host_is_503() {
    // No --host-addr configured → submit disabled.
    let h = start_harness();
    let resp = http_post(
        h.addr,
        "/v1/actions",
        "application/octet-stream",
        b"x",
        Some(TOKEN),
    );
    assert_eq!(resp.status, 503);
}

#[test]
fn submit_unsupported_content_type_is_415() {
    let mock = MockHost::start(Verdict::Ok, "");
    let h = start_harness_full(0, Some(mock.addr));
    let resp = http_post(h.addr, "/v1/actions", "text/plain", b"x", Some(TOKEN));
    assert_eq!(resp.status, 415);
}

#[test]
fn submit_oversize_body_is_413() {
    let mock = MockHost::start(Verdict::Ok, "");
    let h = start_harness_full(0, Some(mock.addr));
    // One byte over the 1 MiB --max-frame-size cap → 413, enforced while
    // reading (the body is bounded before the host is ever contacted).
    let big = vec![0u8; 1024 * 1024 + 1];
    let resp = http_post(
        h.addr,
        "/v1/actions",
        "application/octet-stream",
        &big,
        Some(TOKEN),
    );
    assert_eq!(resp.status, 413);
}

#[test]
fn submit_requires_auth() {
    let mock = MockHost::start(Verdict::Ok, "");
    let h = start_harness_full(0, Some(mock.addr));
    // No credential → 401 (the submit path is not auth-exempt).
    let resp = http_post(
        h.addr,
        "/v1/actions",
        "application/octet-stream",
        b"x",
        None,
    );
    assert_eq!(resp.status, 401);
}

#[test]
fn idempotency_key_replays_cached_response_without_resubmit() {
    let mock = MockHost::start(Verdict::Ok, "");
    let h = start_harness_full(0, Some(mock.addr)); // ttl=60 (enabled)
    let ct = "application/octet-stream";

    // First submit with Idempotency-Key "abc" reaches the host.
    let r1 = http_post_idem(h.addr, "/v1/actions", ct, b"action", Some(TOKEN), "abc");
    assert_eq!(r1.status, 200);
    assert_eq!(r1.json()["accepted"], true);
    assert_eq!(mock.served.load(Ordering::Relaxed), 1);

    // A duplicate key returns the byte-identical CACHED response with NO
    // second host round-trip (the served-frame count stays 1).
    let r2 = http_post_idem(h.addr, "/v1/actions", ct, b"action", Some(TOKEN), "abc");
    assert_eq!(r2.status, 200);
    assert_eq!(
        r2.body, r1.body,
        "duplicate key returns the cached response"
    );
    assert_eq!(
        mock.served.load(Ordering::Relaxed),
        1,
        "the cached retry did NOT re-submit"
    );

    // A DIFFERENT key is a fresh request → a second host round-trip.
    let r3 = http_post_idem(h.addr, "/v1/actions", ct, b"action", Some(TOKEN), "xyz");
    assert_eq!(r3.status, 200);
    assert_eq!(mock.served.load(Ordering::Relaxed), 2);
}

#[test]
fn rate_limit_returns_429_with_retry_after() {
    // A 1-rps cap: the first authed read is admitted, but a rapid burst
    // exhausts the credential's bucket and yields a 429 with Retry-After.
    let h = start_harness_rps(1);
    let first = get(h.addr, "/v1/actors/7/balances");
    assert_eq!(first.status, 200);

    // Hammer until a 429 appears (the burst is one token at 1 rps).
    let mut saw_429 = false;
    for _ in 0..10 {
        let r = get(h.addr, "/v1/actors/7/balances");
        if r.status == 429 {
            assert_eq!(r.header("Content-Type"), Some("application/problem+json"));
            assert!(r.header("Retry-After").is_some(), "expected a Retry-After");
            assert!(
                r.body.contains("retryAfterMs"),
                "expected the retry extension"
            );
            saw_429 = true;
            break;
        }
    }
    assert!(saw_429, "a rapid burst over a 1-rps cap must yield a 429");

    // The exempt probes are never rate-limited.
    let ready = http_get(h.addr, "/readyz", None, None);
    assert_eq!(ready.status, 200);
}

/// Encode one event-subscribe `EVENT` frame:
/// `[KIND_EVENT, seq(8 BE), len(4 BE), payload]` carrying a real CBE
/// `BalanceChanged`.
fn event_frame(seq: u64, actor: u64) -> Vec<u8> {
    let payload = encode_event(&Event::BalanceChanged {
        resource: 0,
        actor,
        old_value: 1000,
        new_value: 900,
    });
    let mut v = vec![KIND_EVENT];
    v.extend_from_slice(&seq.to_be_bytes());
    v.extend_from_slice(&u32::try_from(payload.len()).unwrap().to_be_bytes());
    v.extend_from_slice(&payload);
    v
}

/// A minimal event-subscribe stand-in: on each connection it reads the
/// 9-byte handshake, writes the scripted frames, then **holds the
/// connection open** (idle) until test stop.  Holding (rather than closing)
/// suits both consumers: the backfill stops on the first `seq > tip` before
/// reaching EOF, and the SSE fan-out mux keeps its single live-tail
/// subscription open without reconnect churn.
struct MockEventSubscribe {
    addr: SocketAddr,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl MockEventSubscribe {
    fn start(frames: Vec<Vec<u8>>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let addr = listener.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let halt = Arc::clone(&stop);
        let handle = thread::spawn(move || {
            while !halt.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        let mut handshake = [0u8; 9];
                        if stream.read_exact(&mut handshake).is_err() {
                            continue;
                        }
                        for frame in &frames {
                            if stream.write_all(frame).is_err() {
                                break;
                            }
                        }
                        // Hold the connection open + idle until stop (no
                        // reconnect churn for the live-tail mux).
                        while !halt.load(Ordering::Relaxed) {
                            thread::sleep(Duration::from_millis(5));
                        }
                    }
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => break,
                }
            }
        });
        Self {
            addr,
            stop,
            handle: Some(handle),
        }
    }
}

impl Drop for MockEventSubscribe {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

#[test]
fn events_backfill_endpoint_serves_a_group_complete_page() {
    // The seeded cursor (42) is the tip.  The upstream serves seq 41, 42,
    // then 43 (> tip) — so the backfill stops at the tip with the page
    // [41, 42], hasMore = false, nextCursor = 42, end-to-end through the
    // full auth → route(query) → dispatch → drain → EventPage pipeline.
    let mock = MockEventSubscribe::start(vec![
        event_frame(41, 7),
        event_frame(42, 9),
        event_frame(43, 1), // beyond the tip → stop
    ]);
    let h = start_harness_events(mock.addr);

    let r = get(h.addr, "/v1/events?since=40&limit=100");
    assert_eq!(r.status, 200);
    assert_eq!(r.header("Content-Type"), Some("application/json"));
    let v = r.json();
    assert_eq!(v["nextCursor"], "42");
    assert_eq!(v["hasMore"], false);
    let events = v["events"].as_array().unwrap();
    assert_eq!(events.len(), 2, "seq 43 (> tip 42) is excluded");
    assert_eq!(events[0]["seq"], "41");
    assert_eq!(events[0]["type"], "balanceChanged");
    assert_eq!(events[0]["actor"], "7");
    assert_eq!(events[1]["seq"], "42");
    assert_eq!(events[1]["actor"], "9");
}

#[test]
fn events_backfill_requires_auth_and_validates_query() {
    let mock = MockEventSubscribe::start(vec![event_frame(43, 1)]);
    let h = start_harness_events(mock.addr);

    // Unauthenticated → 401 (the auth gate covers /v1/events before
    // routing); the upstream is never touched.
    let unauth = http_get(h.addr, "/v1/events", None, None);
    assert_eq!(unauth.status, 401);

    // A malformed limit → 400 (validated in the pure router layer).
    let bad = get(h.addr, "/v1/events?limit=0");
    assert_eq!(bad.status, 400);
    assert_eq!(bad.header("Content-Type"), Some("application/problem+json"));
}

/// A running gateway with the SSE fan-out mux started (mirroring `serve`),
/// fed by a mock event-subscribe upstream.  No indexer is needed: the SSE
/// path reads only the fan-out ring.
struct SseHarness {
    _dir: tempfile::TempDir,
    state: Arc<AppState>,
    server: Arc<tiny_http::Server>,
    _workers: Vec<JoinHandle<()>>,
    addr: SocketAddr,
}

impl Drop for SseHarness {
    fn drop(&mut self) {
        // Stop the mux + every live SSE stream, then nudge the accept loop.
        self.state.shutdown.store(true, Ordering::Relaxed);
        self.server.unblock();
    }
}

/// Build a gateway wired to `event_subscribe_addr`, start the single fan-out
/// mux (a long staleness timeout → one persistent subscription for the
/// test), and spawn the handler pool.  The mux thread is detached; dropping
/// the harness (then the mock) tears everything down.
fn start_sse_harness(event_subscribe_addr: SocketAddr) -> SseHarness {
    let dir = tempfile::tempdir().expect("tempdir");
    let token_path = dir.path().join("tokens");
    std::fs::write(&token_path, TOKEN).expect("write token file");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&token_path, std::fs::Permissions::from_mode(0o600))
            .expect("chmod token file");
    }
    let config = Config {
        listen: "127.0.0.1:0".parse().unwrap(),
        handler_threads: 4,
        indexer_db: None,
        free_tier: 0,
        action_cost: 0,
        epoch_length: 0,
        gas_pool_actor: None,
        deployment_id: "knx-sse".to_string(),
        ok_admission_stage: AdmissionStage::Finalized,
        host_addr: None,
        event_subscribe_addr: Some(event_subscribe_addr),
        auth_token_file: Some(token_path),
        rate_limit_rps: 0,
        host_pool_size: 8,
        host_max_inflight: 8,
        request_deadline_ms: 5000,
        max_frame_size: 1024 * 1024,
        idempotency_ttl_secs: 0,
        sse: SseConfig::default(),
    };
    let state = Arc::new(AppState::new(config).expect("open SSE state"));
    // Start the mux (mirrors `serve`), with a long staleness timeout so the
    // single subscription persists for the whole test (no reconnect churn).
    let mux = knomosis_gateway::events::fanout::mux::Mux::new(
        event_subscribe_addr,
        1024 * 1024,
        Duration::from_secs(10),
        Arc::clone(state.fanout.as_ref().expect("fanout present")),
    );
    let _mux = mux.spawn(Arc::clone(&state.shutdown)); // detached
    let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind"));
    let addr = server.server_addr().to_ip().expect("ip addr");
    let workers = spawn_handler_pool(&server, 4, &state).expect("spawn pool");
    SseHarness {
        _dir: dir,
        state,
        server,
        _workers: workers,
        addr,
    }
}

/// The number of records currently retained in the harness's fan-out ring.
fn ring_len(h: &SseHarness) -> usize {
    use knomosis_gateway::events::fanout::ring::Cursor;
    h.state
        .fanout
        .as_ref()
        .unwrap()
        .ring()
        .records_after(Cursor::ORIGIN)
        .len()
}

#[test]
fn event_stream_serves_live_records_over_sse() {
    // The mux ingests these live events into the ring; the SSE client then
    // resumes from since=40 and streams 41.0 + 42.0 as composite-id records.
    let mock = MockEventSubscribe::start(vec![event_frame(41, 7), event_frame(42, 9)]);
    let h = start_sse_harness(mock.addr);

    // Wait for the mux to ingest both events.
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while ring_len(&h) < 2 && std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(ring_len(&h), 2, "the mux ingested the live events");

    // Open the SSE stream (authenticated) resuming from since=40.
    let mut stream = TcpStream::connect(h.addr).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .expect("read timeout");
    stream
        .write_all(
            format!(
                "GET /v1/events/stream?since=40 HTTP/1.1\r\nHost: localhost\r\n\
                 Authorization: Bearer {TOKEN}\r\n\r\n"
            )
            .as_bytes(),
        )
        .expect("write request");

    // Read until both records have arrived (or the deadline).
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while std::time::Instant::now() < deadline {
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if String::from_utf8_lossy(&buf).contains("id: 42.0") {
                    break;
                }
            }
        }
    }
    let out = String::from_utf8_lossy(&buf);
    // The SSE response head.
    assert!(out.contains("HTTP/1.1 200 OK"));
    assert!(out.contains("Content-Type: text/event-stream"));
    assert!(out.contains("Cache-Control: no-store"));
    // The composite-id records (§6.1).
    assert!(
        out.contains("id: 41.0\nevent: balanceChanged\ndata: {"),
        "first record; got:\n{out}"
    );
    assert!(out.contains("id: 42.0\nevent: balanceChanged\ndata: {"));
    // The §6.2 envelope carries the actor.
    assert!(out.contains("\"actor\":\"9\""));

    drop(stream);
    drop(h);
    drop(mock);
}

#[test]
fn event_stream_without_upstream_is_503() {
    // The default harness configures no --event-subscribe-addr → no fan-out
    // → the stream endpoint answers 503 (events disabled), not a hijack.
    let h = start_harness();
    let r = get(h.addr, "/v1/events/stream");
    assert_eq!(r.status, 503);
    assert_eq!(r.header("Content-Type"), Some("application/problem+json"));
    assert!(r.body.contains("events-unavailable"));
}
