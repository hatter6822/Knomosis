// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! G1.1 scaffold smoke test: the gateway's real request handler
//! (`knomosis_gateway::http::handle_request`) serves the routing table
//! over an actual `tiny_http` listener on an ephemeral port.  Proves
//! the HTTP substrate works end-to-end, not just the pure router.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::thread;

/// The bearer token the smoke `test_state` accepts.  Authenticated
/// requests present `Authorization: Bearer {TEST_TOKEN}`.
const TEST_TOKEN: &str = "smoke-token";

/// `GET <path>` with a valid bearer credential — the authenticated
/// happy path for a protected endpoint.
fn one_shot_get(path: &str) -> String {
    fetch(path, Some(TEST_TOKEN))
}

/// Bind an ephemeral listener, serve exactly one request with the
/// crate's real handler in a background thread, and return the raw HTTP
/// response for `GET <path>`.  When `token` is `Some`, an
/// `Authorization: Bearer` header is sent; when `None`, the request is
/// unauthenticated (exercises the fail-closed auth gate).
fn fetch(path: &str, token: Option<&str>) -> String {
    let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind ephemeral port"));
    let addr = server
        .server_addr()
        .to_ip()
        .expect("listener bound to a TCP address");

    let server_thread = Arc::clone(&server);
    let state = test_state();
    let handle = thread::spawn(move || {
        if let Ok(request) = server_thread.recv() {
            knomosis_gateway::http::handle_request(request, &state);
        }
    });

    let mut stream = TcpStream::connect(addr).expect("connect to gateway");
    let auth_line = match token {
        Some(t) => format!("Authorization: Bearer {t}\r\n"),
        None => String::new(),
    };
    let request =
        format!("GET {path} HTTP/1.1\r\nHost: localhost\r\n{auth_line}Connection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).expect("write request");
    let mut response = String::new();
    stream.read_to_string(&mut response).expect("read response");

    handle.join().expect("server thread joined");
    response
}

/// A minimal shared `AppState` for the smoke tests: a loopback config
/// with no read backend, and a single accepted bearer token
/// ([`TEST_TOKEN`]).  The token file is loaded into memory by
/// `AppState::new`, so the tempdir can drop immediately afterwards.
fn test_state() -> Arc<knomosis_gateway::state::AppState> {
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
        knomosis_gateway::state::AppState::new(knomosis_gateway::config::Config {
            listen: "127.0.0.1:0".parse().expect("loopback addr"),
            handler_threads: 1,
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
        })
        .expect("load token file"),
    )
    // `dir` drops here: the token bytes are already loaded into `Auth`.
}

#[test]
fn healthz_returns_200() {
    let response = one_shot_get("/healthz");
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

/// G1.2d: the bounded handler pool serves multiple concurrent requests
/// (more in-flight clients than pool threads) — proves the pool model
/// works end-to-end, not just the single-shot path.
#[test]
fn handler_pool_serves_concurrent_requests() {
    let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind ephemeral port"));
    let addr = server
        .server_addr()
        .to_ip()
        .expect("listener bound to a TCP address");
    // A pool of 4 workers; fire 12 concurrent clients at it.
    let _workers =
        knomosis_gateway::http::spawn_handler_pool(&server, 4, &test_state()).expect("spawn pool");

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
    // Drop the server so the detached workers' `recv` errors and they
    // exit.  (The test holds the only non-worker Arc, so this is
    // best-effort; the OS reclaims any still-blocked workers at process
    // exit — acceptable for a test.)
    drop(server);
}
