// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G1.9 read-path integration tests: the read endpoints served end-to-end
//! over a real `tiny_http` listener + handler pool, against a seeded
//! **read-only** indexer SQLite database, through the full pipeline
//! (auth gate → route → dispatch → read).  This is the first shippable
//! read-only slice.
//!
//! Covers: the `Balance` / `BalanceList` / `BudgetView` / `PoolView`
//! contract shapes over HTTP; `ETag` + `If-None-Match` → `304`; the
//! fail-closed auth gate (401 / 403) on a read; and a
//! snapshot-consistency chaos case (a concurrent writer cannot make the
//! balance list tear).

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

use knomosis_gateway::config::{AdmissionStage, Config};
use knomosis_gateway::http::spawn_handler_pool;
use knomosis_gateway::state::AppState;
use knomosis_indexer::balance::balance_key;
use knomosis_indexer::budget_view::CURRENT_EPOCH_KEY;
use knomosis_indexer::cursor::CURSOR_KEY;
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

/// Seed the indexer DB (balances, budget, pool, cursor) and start the
/// gateway over it (read-only) with a 4-thread handler pool.
fn start_harness() -> Harness {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("index.db");
    let token_path = dir.path().join("tokens");
    std::fs::write(&token_path, TOKEN).expect("write token file");

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
        gas_pool_actor: Some(161),
        deployment_id: "knx-integration".to_string(),
        ok_admission_stage: AdmissionStage::Finalized,
        host_addr: None,
        event_subscribe_addr: None,
        auth_token_file: Some(token_path),
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

    // Read incrementally until the header block plus exactly
    // `Content-Length` body bytes have arrived (or EOF).
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

#[test]
fn concurrent_writer_does_not_tear_balance_list() {
    let h = start_harness();
    let writer = Arc::clone(&h.writer);
    let stop = Arc::new(AtomicBool::new(false));

    // Writer thread: atomically (one transaction) keep the invariant
    // balance(7,1) == balance(7,0) + 1 while advancing the cursor.  A
    // torn (non-snapshot) read would observe a state violating it.
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
        }
    });

    // Reader: hammer the list; every response must be a consistent
    // snapshot — both balances present and satisfying the writer's
    // atomic invariant (res1 == res0 + 1).
    for _ in 0..300 {
        let r = get(h.addr, "/v1/actors/7/balances");
        assert_eq!(r.status, 200);
        let v = r.json();
        let mut res0: Option<u128> = None;
        let mut res1: Option<u128> = None;
        for b in v["balances"].as_array().unwrap() {
            let amount: u128 = b["amount"].as_str().unwrap().parse().unwrap();
            match b["resource"].as_str().unwrap() {
                "0" => res0 = Some(amount),
                "1" => res1 = Some(amount),
                other => panic!("unexpected resource {other}"),
            }
        }
        let (res0, res1) = (res0.expect("res0"), res1.expect("res1"));
        assert_eq!(
            res1,
            res0 + 1,
            "snapshot tore: res1 ({res1}) != res0 ({res0}) + 1"
        );
    }

    stop.store(true, Ordering::Relaxed);
    writer_thread.join().unwrap();
}
