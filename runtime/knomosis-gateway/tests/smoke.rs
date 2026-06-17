// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! End-to-end smoke test: the gateway's real listener
//! (`knomosis_gateway::http::spawn_plain_listener`) serves the routing table
//! over its **own** HTTP/1.1 stack (thread-per-connection, no `tiny_http`) on
//! an ephemeral port.  Proves the HTTP substrate works end-to-end, not just the
//! pure router.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread::{self, JoinHandle};

use knomosis_gateway::state::AppState;

/// The bearer token the smoke `test_state` accepts.  Authenticated
/// requests present `Authorization: Bearer {TEST_TOKEN}`.
const TEST_TOKEN: &str = "smoke-token";

/// Stand up a real gateway listener on an ephemeral loopback port; returns the
/// bound address, the shared state (whose `shutdown` flag stops the listener),
/// and the accept thread's join handle.
fn start_gateway() -> (SocketAddr, Arc<AppState>, JoinHandle<()>) {
    let state = test_state();
    let (addr, handle) = knomosis_gateway::http::spawn_plain_listener(&state.config, &state)
        .expect("spawn listener");
    (addr, state, handle)
}

/// Stop the listener (set `shutdown`) and join its accept thread.
fn stop_gateway(state: &Arc<AppState>, handle: JoinHandle<()>) {
    state.shutdown.store(true, Ordering::SeqCst);
    let _ = handle.join();
}

/// `GET <path>` with a valid bearer credential — the authenticated
/// happy path for a protected endpoint.
fn one_shot_get(path: &str) -> String {
    fetch(path, Some(TEST_TOKEN))
}

/// Stand up a listener, serve `GET <path>` over a real socket, tear the
/// listener down, and return the raw HTTP response.  When `token` is `Some`, an
/// `Authorization: Bearer` header is sent; when `None`, the request is
/// unauthenticated (exercises the fail-closed auth gate).
fn fetch(path: &str, token: Option<&str>) -> String {
    let (addr, state, handle) = start_gateway();
    let auth_line = match token {
        Some(t) => format!("Authorization: Bearer {t}\r\n"),
        None => String::new(),
    };
    let request =
        format!("GET {path} HTTP/1.1\r\nHost: localhost\r\n{auth_line}Connection: close\r\n\r\n");
    let mut stream = TcpStream::connect(addr).expect("connect to gateway");
    stream.write_all(request.as_bytes()).expect("write request");
    let mut response = String::new();
    stream.read_to_string(&mut response).expect("read response");
    stop_gateway(&state, handle);
    response
}

/// A minimal shared `AppState` for the smoke tests: a loopback config
/// (ephemeral `:0` listen) with no read backend, and a single accepted bearer
/// token ([`TEST_TOKEN`]).  The token file is loaded into memory by
/// `AppState::new`, so the tempdir can drop immediately afterwards.
fn test_state() -> Arc<AppState> {
    let dir = tempfile::tempdir().expect("tempdir");
    let token_path = dir.path().join("tokens");
    std::fs::write(&token_path, TEST_TOKEN).expect("write token file");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&token_path, std::fs::Permissions::from_mode(0o600))
            .expect("chmod token file");
    }
    Arc::new(
        AppState::new(knomosis_gateway::config::Config {
            listen: "127.0.0.1:0".parse().expect("loopback addr"),
            max_connections: 16,
            indexer_db: None,
            free_tier: 0,
            action_cost: 0,
            epoch_length: 0,
            gas_pool_actor: None,
            deployment_id: String::new(),
            ok_admission_stage: knomosis_gateway::config::AdmissionStage::Finalized,
            host_addr: None,
            event_subscribe_addr: None,
            auth_token_file: Some(token_path),
            rate_limit_rps: 0,
            host_pool_size: 8,
            host_max_inflight: 8,
            request_deadline_ms: 5000,
            max_frame_size: 1024 * 1024,
            idempotency_ttl_secs: 0,
            sse: knomosis_gateway::config::SseConfig::default(),
            tls: None,
            cors_origin: None,
            log_format: knomosis_gateway::config::LogFormat::Json,
            dev: false,
            upstream_subscriptions: 1,
        })
        .expect("load token file"),
    )
    // `dir` drops here: the token bytes are already loaded into `Auth`.
}

#[test]
fn healthz_returns_200() {
    let response = fetch("/healthz", None); // /healthz is auth-exempt
    assert!(
        response.starts_with("HTTP/1.1 200"),
        "expected a 200 status line, got: {response:?}"
    );
    assert!(
        response.contains("ok"),
        "expected the body 'ok', got: {response:?}"
    );
}

#[test]
fn info_returns_json() {
    let response = one_shot_get("/v1/info");
    assert!(response.starts_with("HTTP/1.1 200"), "got: {response:?}");
    assert!(
        response.contains("application/json"),
        "expected a JSON content type, got: {response:?}"
    );
    // The typed `Info` schema (G1.8): the default admission stage + the
    // host wire protocol version are present end-to-end over the socket.
    assert!(
        response.contains("\"okAdmissionStage\":\"Finalized\""),
        "expected the typed Info body, got: {response:?}"
    );
    assert!(
        response.contains("\"submitProtocolVersion\":2"),
        "expected the host protocol version, got: {response:?}"
    );
}

#[test]
fn readyz_returns_json_ready() {
    // No upstreams configured in the smoke `test_state` → readiness is
    // satisfied; `/readyz` answers 200 with the `Readiness` body.
    // `/readyz` is auth-exempt, so no credential is sent.
    let response = fetch("/readyz", None);
    assert!(response.starts_with("HTTP/1.1 200"), "got: {response:?}");
    assert!(
        response.contains("application/json"),
        "expected a JSON content type, got: {response:?}"
    );
    assert!(
        response.contains("\"ready\":true"),
        "expected ready=true, got: {response:?}"
    );
}

#[test]
fn protected_endpoint_without_token_is_401() {
    // /v1/info is not auth-exempt; with no credential the fail-closed
    // gate answers 401 (with a bearer challenge) before routing.
    let response = fetch("/v1/info", None);
    assert!(response.starts_with("HTTP/1.1 401"), "got: {response:?}");
    assert!(
        response.contains("application/problem+json"),
        "expected a problem body, got: {response:?}"
    );
    assert!(
        response
            .to_ascii_lowercase()
            .contains("www-authenticate: bearer"),
        "expected a bearer challenge header, got: {response:?}"
    );
}

#[test]
fn protected_endpoint_with_wrong_token_is_403() {
    // A well-formed but non-matching bearer token → 403.
    let response = fetch("/v1/info", Some("not-the-smoke-token"));
    assert!(response.starts_with("HTTP/1.1 403"), "got: {response:?}");
    assert!(
        response.contains("application/problem+json"),
        "expected a problem body, got: {response:?}"
    );
}

#[test]
fn unknown_path_returns_404() {
    let response = one_shot_get("/v1/does-not-exist");
    assert!(
        response.starts_with("HTTP/1.1 404"),
        "expected a 404 status line, got: {response:?}"
    );
}

/// The thread-per-connection model serves many concurrent requests (more
/// in-flight clients than would fit a fixed worker pool) — proves the
/// own-HTTP-stack acceptor works end-to-end, not just the single-shot path.
#[test]
fn listener_serves_concurrent_requests() {
    let (addr, state, handle) = start_gateway();
    let mut clients = Vec::new();
    for _ in 0..12 {
        clients.push(thread::spawn(move || {
            let mut stream = TcpStream::connect(addr).expect("connect");
            stream
                .write_all(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                .expect("write");
            let mut response = String::new();
            stream.read_to_string(&mut response).expect("read");
            response
        }));
    }
    for client in clients {
        let response = client.join().expect("client thread");
        assert!(
            response.starts_with("HTTP/1.1 200"),
            "every concurrent request must get 200, got: {response:?}"
        );
    }
    stop_gateway(&state, handle);
}
