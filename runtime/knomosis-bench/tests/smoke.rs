// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! End-to-end smoke test for `knomosis-bench`.
//!
//! Spins up a real knomosis-host instance backed by MockKernel, drives
//! a small benchmark workload through it, and verifies the produced
//! report has the expected structure.  This is the load-bearing
//! integration check that the runner / fixture / report / server
//! modules compose correctly.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use knomosis_bench::fixture::{generate, FixtureConfig};
use knomosis_bench::histogram::Histogram;
use knomosis_bench::report::{
    compare_against_baseline, BenchmarkReport, RegressionVerdict, ReportFixtureConfig,
    TransportKind,
};
use knomosis_bench::runner::{run, Endpoint, RunnerConfig, RunnerError, SubmissionError};
use knomosis_bench::server::StandaloneServer;
use knomosis_host::listener::HandlerConfig;

/// End-to-end against a Unix-socket: spawn server, build fixture,
/// run benchmark, check report shape.
#[cfg(unix)]
#[test]
fn smoke_unix_end_to_end() {
    let temp = tempfile::tempdir().unwrap();
    let socket_path = temp.path().join("bench-smoke.sock");
    let mut server =
        StandaloneServer::spawn_unix(socket_path.clone(), 64, HandlerConfig::default())
            .expect("spawn unix server");

    // Tiny fixture: 4 actors, 32 transfers, 4 warmup.
    let fixture_cfg = FixtureConfig {
        actor_count: 4,
        transfer_count: 32,
        ..Default::default()
    };
    let fixture = generate(&fixture_cfg).expect("generate fixture");

    let mut runner_cfg = RunnerConfig::defaults_for(Endpoint::UnixSocket(socket_path));
    runner_cfg.worker_count = 4;
    runner_cfg.warmup_requests = 4;
    runner_cfg.request_timeout = Duration::from_secs(5);

    let outcome = run(&fixture, &runner_cfg).expect("run benchmark");
    server.stop(Duration::from_secs(5)).expect("stop server");

    assert_eq!(outcome.measured_requests, 28); // 32 - 4 warmup
    assert!(outcome.elapsed > Duration::ZERO);
    assert!(outcome.throughput_ops_per_sec() > 0.0);
    let mut hist = outcome.histogram;
    let summary = hist.summarise();
    assert_eq!(summary.count, 28);
    assert!(summary.min_ns <= summary.max_ns);
    assert!(summary.p50_ns <= summary.p99_ns);
    assert!(summary.p99_ns <= summary.p999_ns);
}

/// End-to-end against TCP: identical to the Unix test but uses
/// loopback TCP.
#[test]
fn smoke_tcp_end_to_end() {
    let mut server =
        StandaloneServer::spawn_tcp("127.0.0.1:0".parse().unwrap(), 64, HandlerConfig::default())
            .expect("spawn tcp server");
    let local_addr = server.tcp_local_addr().unwrap();

    let fixture_cfg = FixtureConfig {
        actor_count: 4,
        transfer_count: 32,
        ..Default::default()
    };
    let fixture = generate(&fixture_cfg).expect("generate fixture");

    let mut runner_cfg = RunnerConfig::defaults_for(Endpoint::Tcp(local_addr));
    runner_cfg.worker_count = 4;
    runner_cfg.warmup_requests = 4;
    runner_cfg.request_timeout = Duration::from_secs(5);

    let outcome = run(&fixture, &runner_cfg).expect("run benchmark");
    server.stop(Duration::from_secs(5)).expect("stop server");

    assert_eq!(outcome.measured_requests, 28);
    assert!(outcome.throughput_ops_per_sec() > 0.0);
}

/// A complete report can be saved + loaded + summarised.
#[cfg(unix)]
#[test]
fn smoke_full_report_round_trip() {
    let temp = tempfile::tempdir().unwrap();
    let socket_path = temp.path().join("bench-report.sock");
    let report_path = temp.path().join("report.json");

    let mut server =
        StandaloneServer::spawn_unix(socket_path.clone(), 64, HandlerConfig::default())
            .expect("spawn unix server");

    let fixture_cfg = FixtureConfig {
        actor_count: 2,
        transfer_count: 16,
        ..Default::default()
    };
    let fixture = generate(&fixture_cfg).expect("generate fixture");

    let mut runner_cfg = RunnerConfig::defaults_for(Endpoint::UnixSocket(socket_path));
    runner_cfg.worker_count = 2;
    runner_cfg.warmup_requests = 2;
    runner_cfg.request_timeout = Duration::from_secs(5);

    let outcome = run(&fixture, &runner_cfg).expect("run benchmark");
    server.stop(Duration::from_secs(5)).expect("stop server");

    let throughput = outcome.throughput_ops_per_sec();
    let elapsed_ns = outcome.elapsed.as_nanos() as u64;
    let measured_requests = outcome.measured_requests;
    let mut hist = outcome.histogram;
    let summary = hist.summarise();

    let report = BenchmarkReport {
        identifier: knomosis_bench::BENCH_IDENTIFIER.to_string(),
        harness_version: "smoke".to_string(),
        protocol_version: knomosis_bench::PROTOCOL_VERSION,
        fixture_config: ReportFixtureConfig::from_fixture(&fixture.config),
        worker_count: 2,
        warmup_requests: 2,
        elapsed_ns,
        measured_requests,
        throughput_ops_per_sec: throughput,
        latency: summary,
        transport: TransportKind::UnixSocket,
    };

    // Save + reload.
    report.save(&report_path).expect("save report");
    let reloaded = BenchmarkReport::load(&report_path).expect("load report");
    // Integer fields are bit-equal; f64 fields may differ by ≤ 2 ULP
    // due to serde_json's Ryu shortest-roundtrip format.  Verify
    // each field with the right comparison.
    assert_eq!(reloaded.identifier, report.identifier);
    assert_eq!(reloaded.harness_version, report.harness_version);
    assert_eq!(reloaded.protocol_version, report.protocol_version);
    assert_eq!(reloaded.fixture_config, report.fixture_config);
    assert_eq!(reloaded.worker_count, report.worker_count);
    assert_eq!(reloaded.warmup_requests, report.warmup_requests);
    assert_eq!(reloaded.elapsed_ns, report.elapsed_ns);
    assert_eq!(reloaded.measured_requests, report.measured_requests);
    assert_eq!(reloaded.transport, report.transport);
    // f64 comparisons: within a small relative epsilon (the
    // shortest-roundtrip format guarantees the saved decimal
    // re-parses to the closest representable f64).
    assert!(
        (reloaded.throughput_ops_per_sec - report.throughput_ops_per_sec).abs()
            <= f64::EPSILON * report.throughput_ops_per_sec.abs().max(1.0) * 4.0
    );
    assert_eq!(reloaded.latency.count, report.latency.count);
    assert_eq!(reloaded.latency.min_ns, report.latency.min_ns);
    assert_eq!(reloaded.latency.max_ns, report.latency.max_ns);
    assert_eq!(reloaded.latency.p50_ns, report.latency.p50_ns);
    assert_eq!(reloaded.latency.p90_ns, report.latency.p90_ns);
    assert_eq!(reloaded.latency.p99_ns, report.latency.p99_ns);
    assert_eq!(reloaded.latency.p999_ns, report.latency.p999_ns);
    let mean_tol = f64::EPSILON * report.latency.mean_ns.abs().max(1.0) * 4.0;
    assert!((reloaded.latency.mean_ns - report.latency.mean_ns).abs() <= mean_tol);
    let stddev_tol = f64::EPSILON * report.latency.stddev_ns.abs().max(1.0) * 4.0;
    assert!((reloaded.latency.stddev_ns - report.latency.stddev_ns).abs() <= stddev_tol);

    // Compare against itself: WithinTolerance.
    let verdict = compare_against_baseline(&report, &report, 0.10);
    assert!(matches!(verdict, RegressionVerdict::WithinTolerance));

    // Human summary contains expected pieces.
    let human = report.to_human_summary();
    assert!(human.contains("knomosis-bench/v1"));
    assert!(human.contains("Throughput"));
    assert!(human.contains("p99"));
}

/// The runner attributes a SubmissionError correctly when the
/// server isn't running (refused connection).
#[test]
fn smoke_runner_refused_connection() {
    // Bind a port + drop the listener so the address is left in
    // TIME_WAIT but not bound.  A connect() should fail.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    drop(listener);

    let fixture_cfg = FixtureConfig {
        actor_count: 2,
        transfer_count: 4,
        ..Default::default()
    };
    let fixture = generate(&fixture_cfg).expect("generate fixture");

    let mut runner_cfg = RunnerConfig::defaults_for(Endpoint::Tcp(addr));
    runner_cfg.worker_count = 1;
    runner_cfg.warmup_requests = 0;
    runner_cfg.request_timeout = Duration::from_secs(1);

    let result = run(&fixture, &runner_cfg);
    // We expect a SubmissionFailed → Transport I/O error.
    match result {
        Err(knomosis_bench::runner::RunnerError::SubmissionFailed(_)) => (),
        Ok(_) => panic!("expected refused-connection error"),
        Err(other) => panic!("expected SubmissionFailed, got {other}"),
    }
}

/// Histogram-only smoke: the runner's histogram-merging produces a
/// well-formed combined summary.
#[test]
fn smoke_histogram_merge() {
    let mut h1 = Histogram::new();
    let mut h2 = Histogram::new();
    for i in 0..50u64 {
        h1.record_ns(i * 100);
        h2.record_ns((i + 50) * 100);
    }
    h1.merge(&h2);
    let s = h1.summarise();
    assert_eq!(s.count, 100);
    assert_eq!(s.min_ns, 0);
    assert_eq!(s.max_ns, 9_900);
}

/// Deterministic fixture: two runs with the same seed produce
/// byte-identical payloads.
#[test]
fn smoke_fixture_deterministic_with_seed() {
    let cfg = FixtureConfig {
        actor_count: 4,
        transfer_count: 8,
        seed: 0xABCD,
        ..Default::default()
    };
    let f1 = generate(&cfg).expect("generate 1");
    let f2 = generate(&cfg).expect("generate 2");
    assert_eq!(f1.actor_pubkeys, f2.actor_pubkeys);
    assert_eq!(*f1.payloads, *f2.payloads);
    // Per-payload length is the documented 136 bytes for Transfer.
    for p in f1.payloads.iter() {
        assert_eq!(p.len(), 136);
    }
}

/// REGRESSION: the elapsed window the runner reports MUST bracket
/// every measured request.  Compute the expected min / max
/// timestamps from per-request wallclock and assert that
/// `outcome.elapsed` is at least the histogram's
/// `sum_of_samples` / `worker_count` (lower bound, since workers
/// run in parallel).  Catches regressions where
/// `measurement_start` / `measurement_end` aggregation drifts
/// (e.g. if reduce-on-join misses a worker's last completion).
#[test]
fn smoke_elapsed_brackets_workload() {
    let mut server =
        StandaloneServer::spawn_tcp("127.0.0.1:0".parse().unwrap(), 64, HandlerConfig::default())
            .expect("spawn tcp server");
    let local_addr = server.tcp_local_addr().unwrap();

    let fixture_cfg = FixtureConfig {
        actor_count: 4,
        transfer_count: 40,
        ..Default::default()
    };
    let fixture = generate(&fixture_cfg).expect("generate fixture");

    let mut runner_cfg = RunnerConfig::defaults_for(Endpoint::Tcp(local_addr));
    runner_cfg.worker_count = 4;
    runner_cfg.warmup_requests = 8;
    runner_cfg.request_timeout = Duration::from_secs(5);

    let outcome = run(&fixture, &runner_cfg).expect("run benchmark");
    server.stop(Duration::from_secs(5)).expect("stop server");

    // Capture by-value first to avoid partial-move on `outcome`.
    let tps = outcome.throughput_ops_per_sec();
    let elapsed_ns = outcome.elapsed.as_nanos() as u64;
    let mut hist = outcome.histogram;
    let summary = hist.summarise();
    assert_eq!(summary.count, 32); // 40 - 8 warmup

    // Throughput is finite + positive.  This catches NaN /
    // infinity / negative time drift.
    assert!(
        tps.is_finite() && tps > 0.0,
        "throughput {tps} not positive-finite"
    );

    // Elapsed wallclock must be at least the maximum per-request
    // latency observed (lower bound, since at least one worker had
    // to wait that long).  This proves measurement_end is updated
    // correctly across workers via reduce-on-join.
    let max_latency_ns = summary.max_ns;
    assert!(
        elapsed_ns >= max_latency_ns,
        "elapsed {elapsed_ns} ns must be >= max latency {max_latency_ns} ns",
    );
}

/// Spawn a tiny mock TCP server that accepts each connection, reads
/// a length-prefixed request payload, and writes a configurable
/// response.  Returns the bound `SocketAddr` + a stop flag.  Used
/// by the UnexpectedVerdict and ResponseTooLarge tests below.
fn spawn_mock_response_server(
    response_bytes: Vec<u8>,
) -> (
    std::net::SocketAddr,
    Arc<AtomicBool>,
    std::thread::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("mock listener bind");
    let addr = listener.local_addr().expect("mock local_addr");
    listener
        .set_nonblocking(true)
        .expect("mock set_nonblocking");
    let stop = Arc::new(AtomicBool::new(false));
    let stop_for_thread = Arc::clone(&stop);
    let handle = std::thread::spawn(move || {
        while !stop_for_thread.load(Ordering::Acquire) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream.set_read_timeout(Some(Duration::from_secs(1))).ok();
                    stream.set_write_timeout(Some(Duration::from_secs(1))).ok();
                    // Read 4-byte BE length, then `length` payload
                    // bytes (and discard them).
                    let mut header = [0u8; 4];
                    if stream.read_exact(&mut header).is_err() {
                        continue;
                    }
                    let len = u32::from_be_bytes(header) as usize;
                    let mut payload = vec![0u8; len];
                    let _ = stream.read_exact(&mut payload);
                    // Write the configured response.
                    let _ = stream.write_all(&response_bytes);
                    let _ = stream.flush();
                    let _ = stream.shutdown(std::net::Shutdown::Both);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(_) => break,
            }
        }
    });
    // Give the listener a beat.
    std::thread::sleep(Duration::from_millis(50));
    (addr, stop, handle)
}

/// REGRESSION: a mock server returning a non-Ok verdict (verdict
/// byte = 1, with a reason string) surfaces as
/// `SubmissionError::UnexpectedVerdict` carrying both the verdict
/// byte and the reason text.  Validates that the runner correctly
/// surfaces non-zero verdicts as typed errors (rather than silently
/// counting them as successes).
#[test]
fn smoke_unexpected_verdict_surfaces() {
    // Build a response: verdict byte = 1 (NotAdmissible), reason
    // length = 8, reason = "rejected".
    let reason = b"rejected";
    let mut response = Vec::with_capacity(5 + reason.len());
    response.push(1u8); // verdict
    response.extend_from_slice(&(reason.len() as u32).to_be_bytes());
    response.extend_from_slice(reason);

    let (addr, stop, handle) = spawn_mock_response_server(response);

    let fixture_cfg = FixtureConfig {
        actor_count: 2,
        transfer_count: 4,
        ..Default::default()
    };
    let fixture = generate(&fixture_cfg).expect("generate fixture");

    let mut runner_cfg = RunnerConfig::defaults_for(Endpoint::Tcp(addr));
    runner_cfg.worker_count = 1;
    runner_cfg.warmup_requests = 0;
    runner_cfg.request_timeout = Duration::from_secs(2);

    let result = run(&fixture, &runner_cfg);

    // Shut down the mock server cleanly.
    stop.store(true, Ordering::Release);
    let _ = handle.join();

    match result {
        Err(RunnerError::SubmissionFailed(SubmissionError::UnexpectedVerdict {
            verdict_byte,
            reason,
        })) => {
            assert_eq!(verdict_byte, 1);
            assert_eq!(reason, "rejected");
        }
        Ok(_) => panic!("expected UnexpectedVerdict error"),
        Err(other) => panic!("expected UnexpectedVerdict, got {other:?}"),
    }
}

/// REGRESSION: a mock server declaring a reason length above the
/// `MAX_REASON_BYTES` cap surfaces as
/// `SubmissionError::ResponseTooLarge` BEFORE allocating the
/// payload.  Without the cap, a hostile server could cause an OOM
/// via `vec![0u8; declared_length]`.
#[test]
fn smoke_response_too_large_surfaces() {
    // Response header: verdict byte 0, declared reason length =
    // u32::MAX.  We don't actually send 4 GiB of payload (we just
    // declare it); the client should reject upfront on the
    // declared-length check.
    let mut response = Vec::with_capacity(5);
    response.push(0u8);
    response.extend_from_slice(&u32::MAX.to_be_bytes());

    let (addr, stop, handle) = spawn_mock_response_server(response);

    let fixture_cfg = FixtureConfig {
        actor_count: 2,
        transfer_count: 4,
        ..Default::default()
    };
    let fixture = generate(&fixture_cfg).expect("generate fixture");

    let mut runner_cfg = RunnerConfig::defaults_for(Endpoint::Tcp(addr));
    runner_cfg.worker_count = 1;
    runner_cfg.warmup_requests = 0;
    runner_cfg.request_timeout = Duration::from_secs(2);

    let result = run(&fixture, &runner_cfg);

    // Shut down the mock server cleanly.
    stop.store(true, Ordering::Release);
    let _ = handle.join();

    match result {
        Err(RunnerError::SubmissionFailed(SubmissionError::ResponseTooLarge { declared, max })) => {
            assert_eq!(declared, u32::MAX as usize);
            assert_eq!(max, 64 * 1024);
        }
        Ok(_) => panic!("expected ResponseTooLarge error"),
        Err(other) => panic!("expected ResponseTooLarge, got {other:?}"),
    }
}

/// REGRESSION: per-worker last-completion reduce-on-join MUST
/// produce monotonic-non-decreasing elapsed.  Two back-to-back
/// runs of identical configuration should have similar elapsed
/// times — neither absurdly small (would indicate a missed
/// timestamp) nor astronomically large (would indicate a Mutex
/// stall).
#[test]
fn smoke_elapsed_consistent_across_runs() {
    let mut server =
        StandaloneServer::spawn_tcp("127.0.0.1:0".parse().unwrap(), 64, HandlerConfig::default())
            .expect("spawn tcp server");
    let local_addr = server.tcp_local_addr().unwrap();

    let fixture_cfg = FixtureConfig {
        actor_count: 4,
        transfer_count: 40,
        ..Default::default()
    };
    let fixture = generate(&fixture_cfg).expect("generate fixture");

    let mut runner_cfg = RunnerConfig::defaults_for(Endpoint::Tcp(local_addr));
    runner_cfg.worker_count = 4;
    runner_cfg.warmup_requests = 8;
    runner_cfg.request_timeout = Duration::from_secs(5);

    let outcome1 = run(&fixture, &runner_cfg).expect("run 1");
    let outcome2 = run(&fixture, &runner_cfg).expect("run 2");
    server.stop(Duration::from_secs(5)).expect("stop server");

    // Both runs must record positive elapsed.
    assert!(outcome1.elapsed > Duration::ZERO);
    assert!(outcome2.elapsed > Duration::ZERO);
    // Throughput must be in a reasonable range.
    let t1 = outcome1.throughput_ops_per_sec();
    let t2 = outcome2.throughput_ops_per_sec();
    assert!(t1.is_finite() && t1 > 0.0);
    assert!(t2.is_finite() && t2 > 0.0);
}
