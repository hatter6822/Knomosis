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

/// Bind an ephemeral listener, serve exactly one request with the
/// crate's real handler in a background thread, and return the raw
/// HTTP response the client reads back for `GET <path>`.
fn one_shot_get(path: &str) -> String {
    let server = Arc::new(tiny_http::Server::http("127.0.0.1:0").expect("bind ephemeral port"));
    let addr = server
        .server_addr()
        .to_ip()
        .expect("listener bound to a TCP address");

    let server_thread = Arc::clone(&server);
    let handle = thread::spawn(move || {
        if let Ok(request) = server_thread.recv() {
            knomosis_gateway::http::handle_request(request);
        }
    });

    let mut stream = TcpStream::connect(addr).expect("connect to gateway");
    let request = format!("GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).expect("write request");
    let mut response = String::new();
    stream.read_to_string(&mut response).expect("read response");

    handle.join().expect("server thread joined");
    response
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
    assert!(
        response.contains("knomosis-gateway/v1"),
        "expected the gateway identifier, got: {response:?}"
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
