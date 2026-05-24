// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Unix-socket integration tests for `knomosis-host`.
//!
//! Separated from `tests/integration.rs` because Unix-socket
//! support is `#[cfg(unix)]` only.

#![cfg(unix)]

use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use knomosis_host::frame::encode_frame;
use knomosis_host::kernel::mock::MockKernel;
use knomosis_host::kernel::KernelResponse;
use knomosis_host::listener::unix::UnixListener;
use knomosis_host::listener::HandlerConfig;
use knomosis_host::server::{Server, ServerConfigBuilder};
use knomosis_host::verdict::Verdict;

/// Submit one frame over a Unix socket and read the response.
fn submit_one_unix(path: &std::path::Path, payload: &[u8]) -> Vec<u8> {
    let mut stream = UnixStream::connect(path).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let frame = encode_frame(payload).unwrap();
    stream.write_all(&frame).unwrap();
    stream.flush().unwrap();
    stream
        .shutdown(std::net::Shutdown::Write)
        .expect("shutdown write");
    let mut response = Vec::new();
    stream.read_to_end(&mut response).unwrap();
    response
}

fn parse_response(bytes: &[u8]) -> (u8, String) {
    assert!(bytes.len() >= 5, "response too short: {bytes:?}");
    let verdict_byte = bytes[0];
    let reason_len = u32::from_be_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
    let reason = String::from_utf8_lossy(&bytes[5..5 + reason_len]).into_owned();
    (verdict_byte, reason)
}

fn join_server(stop: Arc<AtomicBool>, handle: std::thread::JoinHandle<()>) {
    stop.store(true, Ordering::Relaxed);
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if handle.is_finished() {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    handle.join().expect("server join");
}

/// End-to-end over Unix socket: bind, submit, get Ok.
#[test]
fn unix_socket_request_response() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knomosis.sock");
    let unix_listener = UnixListener::bind(&path).unwrap();
    let kernel = Box::new(MockKernel::new());
    let cfg = ServerConfigBuilder::new()
        .unix(unix_listener)
        .max_queue_depth(4)
        .handler(HandlerConfig::default())
        .build(kernel)
        .unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let server_stop = Arc::clone(&stop);
    let handle = std::thread::spawn(move || Server::new(cfg).run(server_stop));
    std::thread::sleep(Duration::from_millis(100));

    let response = submit_one_unix(&path, b"hello");
    let (verdict, reason) = parse_response(&response);
    assert_eq!(verdict, Verdict::Ok.to_byte());
    assert!(reason.is_empty());

    join_server(stop, handle);
}

/// Unix socket file is created with mode 0600.
#[test]
fn unix_socket_has_mode_0600() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knomosis.sock");
    let _unix_listener = UnixListener::bind(&path).unwrap();
    let meta = std::fs::metadata(&path).unwrap();
    let mode = meta.permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "socket mode = {mode:o}, expected 0o600");
}

/// Re-binding to a stale socket path (file exists from prev run)
/// succeeds.  Defends against the "must restart daemon" foot-gun
/// where a previous run's socket file blocks rebind.
#[test]
fn rebind_unlinks_stale_socket() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knomosis.sock");

    // First bind: creates the socket file.
    let listener1 = UnixListener::bind(&path).unwrap();
    drop(listener1);
    // Some Unix-domain socket files persist after Drop; verify
    // that re-binding succeeds (whether or not the file is
    // present at this moment).
    let _listener2 = UnixListener::bind(&path).unwrap();
}

/// Re-binding refuses to delete a non-socket file at the target
/// path.  Defends against accidentally deleting an operator's
/// data file.
#[test]
fn rebind_refuses_to_unlink_regular_file() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("not-a-socket.txt");
    // Create a regular file at the target path.
    std::fs::write(&path, b"important operator data").unwrap();
    match UnixListener::bind(&path) {
        Err(e) => {
            assert_eq!(e.kind(), std::io::ErrorKind::AlreadyExists, "got {e:?}");
        }
        Ok(_) => panic!("UnixListener::bind must refuse to clobber a regular file"),
    }
    // Verify the file is still intact.
    assert_eq!(
        std::fs::read(&path).unwrap(),
        b"important operator data",
        "regular file was clobbered"
    );
}

/// NotAdmissible verdict with reason round-trips over Unix socket.
#[test]
fn unix_socket_not_admissible_with_reason() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knomosis.sock");
    let unix_listener = UnixListener::bind(&path).unwrap();
    let kernel = MockKernel::new();
    kernel.set_responses(vec![KernelResponse::with_reason(
        Verdict::NotAdmissible,
        "policy denied",
    )]);
    let cfg = ServerConfigBuilder::new()
        .unix(unix_listener)
        .build(Box::new(kernel))
        .unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let server_stop = Arc::clone(&stop);
    let handle = std::thread::spawn(move || Server::new(cfg).run(server_stop));
    std::thread::sleep(Duration::from_millis(100));

    let response = submit_one_unix(&path, b"x");
    let (verdict, reason) = parse_response(&response);
    assert_eq!(verdict, Verdict::NotAdmissible.to_byte());
    assert_eq!(reason, "policy denied");

    join_server(stop, handle);
}

/// Many sequential Unix-socket requests all succeed.
#[test]
fn many_unix_requests_sequential() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knomosis.sock");
    let unix_listener = UnixListener::bind(&path).unwrap();
    let kernel = Box::new(MockKernel::new());
    let cfg = ServerConfigBuilder::new()
        .unix(unix_listener)
        .max_queue_depth(16)
        .build(kernel)
        .unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let server_stop = Arc::clone(&stop);
    let handle = std::thread::spawn(move || Server::new(cfg).run(server_stop));
    std::thread::sleep(Duration::from_millis(100));

    for i in 0..20u8 {
        let response = submit_one_unix(&path, &[i; 8]);
        let (verdict, _) = parse_response(&response);
        assert_eq!(verdict, Verdict::Ok.to_byte(), "request {i} failed");
    }

    join_server(stop, handle);
}

/// Concurrent Unix-socket clients all succeed.
#[test]
fn concurrent_unix_clients() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("knomosis.sock");
    let unix_listener = UnixListener::bind(&path).unwrap();
    let kernel = Box::new(MockKernel::new());
    let cfg = ServerConfigBuilder::new()
        .unix(unix_listener)
        .max_queue_depth(32)
        .build(kernel)
        .unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let server_stop = Arc::clone(&stop);
    let handle = std::thread::spawn(move || Server::new(cfg).run(server_stop));
    std::thread::sleep(Duration::from_millis(100));

    let mut threads = Vec::new();
    for i in 0..8u8 {
        let p = path.clone();
        threads.push(std::thread::spawn(move || {
            let response = submit_one_unix(&p, &[i; 4]);
            parse_response(&response).0
        }));
    }
    let verdicts: Vec<u8> = threads.into_iter().map(|t| t.join().unwrap()).collect();
    // Using a manual fold rather than `.filter().count()` to
    // avoid clippy's `naive_bytecount` suggestion (which would
    // require adding the `bytecount` crate to the dev-dep tree).
    let ok_byte = Verdict::Ok.to_byte();
    let ok_count = verdicts
        .iter()
        .fold(0usize, |acc, &v| acc + usize::from(v == ok_byte));
    assert_eq!(ok_count, 8, "expected 8 Ok verdicts, got: {verdicts:?}");

    join_server(stop, handle);
}
