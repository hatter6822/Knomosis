// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `knomosis-bench` — RH-F binary entry point.
//!
//! See [`knomosis_bench`] for the library API and architectural
//! overview.  This binary glues CLI parsing to the runner +
//! report flow and maps every error to an
//! [`OperatorExitCode`].
//!
//! ## Exit-code matrix
//!
//! | Code | Meaning                                                                    |
//! |------|----------------------------------------------------------------------------|
//! |   0  | Benchmark completed; thresholds (if any) met; baseline (if any) WithinTolerance. |
//! |   1  | General failure (CLI parse error, tracing init, runner error).             |
//! |   2  | Operator action required (invalid config; baseline regression; target miss). |
//! |   3  | Reserved for `NotImplemented` skeleton mode (no longer used at this landing). |

use std::process::ExitCode;
use std::time::Duration;

use knomosis_bench::config::{
    help_text, parse_args, BenchMode, CliConfig, ParseError, StandaloneListener,
};
use knomosis_bench::fixture::{generate, FixtureConfig};
use knomosis_bench::report::{
    compare_against_baseline, BenchmarkReport, RegressionVerdict, ReportFixtureConfig,
    TransportKind,
};
use knomosis_bench::runner::{run, Endpoint, RunnerConfig};
use knomosis_bench::server::StandaloneServer;
use knomosis_bench::{BENCH_IDENTIFIER, PROTOCOL_VERSION};

use knomosis_cli_common::exit::OperatorExitCode;
use knomosis_host::listener::HandlerConfig;
use tracing::{error, info, warn, Level};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let program_name = args
        .first()
        .cloned()
        .unwrap_or_else(|| "knomosis-bench".into());

    // 1. Parse args.  Help / version short-circuit.
    let cfg = match parse_args(&args) {
        Ok(c) => c,
        Err(ParseError::HelpRequested) => {
            println!("{}", help_text(&program_name));
            return ExitCode::from(OperatorExitCode::Success.as_i32() as u8);
        }
        Err(ParseError::VersionRequested) => {
            println!(
                "{BENCH_IDENTIFIER} v{} (protocol v{PROTOCOL_VERSION})",
                env!("CARGO_PKG_VERSION")
            );
            return ExitCode::from(OperatorExitCode::Success.as_i32() as u8);
        }
        Err(e) => {
            eprintln!("knomosis-bench: {e}");
            eprintln!("Use --help for usage.");
            return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
        }
    };

    // 2. Validate.
    if let Err(e) = cfg.validate() {
        eprintln!("knomosis-bench: invalid configuration: {e}");
        return ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8);
    }

    // 3. Initialise tracing.  The benchmark is a tool for
    //    operators / CI, so INFO-level startup banners are
    //    appropriate; lower the level via RUST_LOG to silence.
    if let Err(e) = knomosis_cli_common::logging::init(Level::INFO) {
        eprintln!("knomosis-bench: failed to initialise tracing: {e}");
        return ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8);
    }

    info!(
        identifier = BENCH_IDENTIFIER,
        version = env!("CARGO_PKG_VERSION"),
        protocol = PROTOCOL_VERSION,
        actor_count = cfg.actor_count,
        transfer_count = cfg.transfer_count,
        worker_count = cfg.worker_count,
        warmup_requests = cfg.warmup_requests,
        seed = format!("0x{:016X}", cfg.seed),
        "knomosis-bench starting"
    );

    match run_benchmark(&cfg) {
        Ok(exit) => exit,
        Err(BenchmarkRunError::Setup(msg)) => {
            error!(error = %msg, "benchmark setup failed");
            ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8)
        }
        Err(BenchmarkRunError::Run(msg)) => {
            error!(error = %msg, "benchmark run failed");
            ExitCode::from(OperatorExitCode::GeneralFailure.as_i32() as u8)
        }
        Err(BenchmarkRunError::TargetMiss(msg)) => {
            error!(error = %msg, "benchmark missed target");
            ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8)
        }
        Err(BenchmarkRunError::Regression(msg)) => {
            error!(error = %msg, "benchmark regressed against baseline");
            ExitCode::from(OperatorExitCode::OperatorAction.as_i32() as u8)
        }
    }
}

/// Internal benchmark-driver error categorisation.  Each variant
/// maps to a different exit code per the matrix above.
#[derive(Debug)]
enum BenchmarkRunError {
    /// Pre-flight setup error (server bind, fixture build).
    Setup(String),
    /// Benchmark run error (transport failure, worker panic).
    Run(String),
    /// Absolute target miss (--target-tps, --target-p99-ms).
    TargetMiss(String),
    /// Baseline regression.
    Regression(String),
}

/// End-to-end benchmark driver.
fn run_benchmark(cfg: &CliConfig) -> Result<ExitCode, BenchmarkRunError> {
    // 1. Build fixture.  Cost is bounded by `transfer_count`
    //    ECDSA signatures: ~25 µs each on modern hardware, so
    //    10000 signatures ~= 250 ms.
    let fixture_cfg = FixtureConfig {
        seed: cfg.seed,
        actor_count: cfg.actor_count,
        transfer_count: cfg.transfer_count,
        ..Default::default()
    };
    let fixture_build_started = std::time::Instant::now();
    let fixture =
        generate(&fixture_cfg).map_err(|e| BenchmarkRunError::Setup(format!("fixture: {e}")))?;
    let fixture_build_elapsed = fixture_build_started.elapsed();
    info!(
        elapsed_ms = fixture_build_elapsed.as_millis() as u64,
        avg_payload_bytes = fixture.average_payload_bytes(),
        max_payload_bytes = fixture.max_payload_bytes(),
        "fixture built"
    );

    // 2. Resolve mode → standalone server + endpoint OR direct
    //    connect endpoint.
    let (endpoint, transport, mut standalone) = match &cfg.mode {
        BenchMode::Standalone(listener) => spawn_standalone(cfg, listener)?,
        BenchMode::Connect(target) => connect_endpoint(target),
    };

    // 3. Run.
    let mut runner_cfg = RunnerConfig::defaults_for(endpoint);
    runner_cfg.worker_count = cfg.worker_count;
    runner_cfg.warmup_requests = cfg.warmup_requests;

    info!(
        transport = %transport.name(),
        "running benchmark"
    );

    let outcome = run(&fixture, &runner_cfg).map_err(|e| BenchmarkRunError::Run(format!("{e}")))?;
    info!(
        elapsed_ms = outcome.elapsed.as_millis() as u64,
        measured_requests = outcome.measured_requests,
        throughput_ops_per_sec = outcome.throughput_ops_per_sec(),
        "benchmark complete"
    );

    // 4. Stop standalone server (best-effort).
    if let Some(server) = standalone.as_mut() {
        if let Err(e) = server.stop(Duration::from_secs(5)) {
            warn!(error = ?e, "standalone server stop timed out (continuing)");
        }
    }

    // 5. Summarise histogram + build report.
    let throughput = outcome.throughput_ops_per_sec();
    let mut histogram = outcome.histogram;
    let summary = histogram.summarise();

    let report = BenchmarkReport {
        identifier: BENCH_IDENTIFIER.to_string(),
        harness_version: env!("CARGO_PKG_VERSION").to_string(),
        protocol_version: PROTOCOL_VERSION,
        fixture_config: ReportFixtureConfig::from_fixture(&fixture.config),
        worker_count: cfg.worker_count,
        warmup_requests: cfg.warmup_requests,
        elapsed_ns: u64::try_from(outcome.elapsed.as_nanos()).unwrap_or(u64::MAX),
        measured_requests: outcome.measured_requests,
        throughput_ops_per_sec: throughput,
        latency: summary,
        transport,
    };

    // 6. Emit human + JSON output.
    if !cfg.quiet {
        println!("{}", report.to_human_summary());
    }
    if let Some(report_path) = cfg.report_path.as_deref() {
        if let Err(e) = report.save(report_path) {
            warn!(error = ?e, "failed to write report sidecar (continuing)");
        } else {
            info!(path = ?report_path, "wrote report sidecar");
        }
    }

    // 7. Absolute-target check.
    if let Some(target) = cfg.target_tps {
        if throughput < target {
            return Err(BenchmarkRunError::TargetMiss(format!(
                "throughput {throughput:.1} ops/sec < target {target:.1} ops/sec"
            )));
        }
    }
    if let Some(target_ms) = cfg.target_p99_ms {
        let p99_ms = summary.p99_ns as f64 / 1_000_000.0;
        if p99_ms > target_ms {
            return Err(BenchmarkRunError::TargetMiss(format!(
                "p99 {p99_ms:.3} ms > target {target_ms:.3} ms"
            )));
        }
    }

    // 8. Baseline regression check.
    if let Some(baseline_path) = cfg.baseline_path.as_deref() {
        let baseline = BenchmarkReport::load(baseline_path)
            .map_err(|e| BenchmarkRunError::Setup(format!("failed to load baseline: {e}")))?;
        let verdict = compare_against_baseline(&baseline, &report, cfg.threshold);
        match verdict {
            RegressionVerdict::WithinTolerance => {
                info!("baseline regression check: within tolerance");
            }
            RegressionVerdict::Regression { details } => {
                let mut msg = String::from("regression details:");
                for detail in &details {
                    msg.push_str(&format!(
                        "\n  {} : baseline {:.3}, candidate {:.3} (drift {:+.2}%; threshold {:.0}%)",
                        detail.metric.name(),
                        detail.baseline,
                        detail.candidate,
                        detail.relative_drift * 100.0,
                        detail.threshold * 100.0,
                    ));
                }
                return Err(BenchmarkRunError::Regression(msg));
            }
        }
    }

    Ok(ExitCode::from(OperatorExitCode::Success.as_i32() as u8))
}

/// Spawn a standalone knomosis-host backed by MockKernel.  Returns
/// the resulting endpoint + transport kind + server handle (to
/// stop on bench completion).
fn spawn_standalone(
    cfg: &CliConfig,
    listener: &StandaloneListener,
) -> Result<(Endpoint, TransportKind, Option<StandaloneServer>), BenchmarkRunError> {
    let queue_depth = cfg
        .queue_depth
        .unwrap_or(knomosis_host::queue::DEFAULT_MAX_QUEUE_DEPTH);
    let max_frame_size = cfg
        .max_frame_size
        .unwrap_or(knomosis_host::frame::DEFAULT_MAX_FRAME_SIZE);
    // Allow far more concurrent connections than the bench's
    // worker count so the host's DoS cap doesn't reject our
    // submitters.  4× worker count is plenty.
    let max_concurrent = (cfg.worker_count.saturating_mul(4)).max(1024);
    let handler = HandlerConfig {
        max_frame_size,
        max_concurrent_connections: max_concurrent,
        ..HandlerConfig::default()
    };

    match listener {
        #[cfg(unix)]
        StandaloneListener::UnixSocket(maybe_path) => {
            let path = resolve_unix_socket_path(maybe_path.as_deref());
            let server = StandaloneServer::spawn_unix(path.clone(), queue_depth, handler)
                .map_err(|e| BenchmarkRunError::Setup(format!("standalone unix server: {e}")))?;
            Ok((
                Endpoint::UnixSocket(path),
                TransportKind::UnixSocket,
                Some(server),
            ))
        }
        #[cfg(not(unix))]
        StandaloneListener::UnixSocket(_) => Err(BenchmarkRunError::Setup(
            "unix-socket transport unsupported on this platform; pass --listen-tcp".into(),
        )),
        StandaloneListener::Tcp(addr) => {
            let server = StandaloneServer::spawn_tcp(*addr, queue_depth, handler)
                .map_err(|e| BenchmarkRunError::Setup(format!("standalone tcp server: {e}")))?;
            let local_addr = server
                .tcp_local_addr()
                .ok_or_else(|| BenchmarkRunError::Setup("server bound but no local_addr".into()))?;
            Ok((Endpoint::Tcp(local_addr), TransportKind::Tcp, Some(server)))
        }
    }
}

/// Resolve the Unix-socket path: caller-supplied or auto-allocated
/// in a tempdir.  When auto-allocated, the tempdir's lifetime is
/// extended to the process's via `Box::leak` (the leaked `TempDir`
/// drops at process exit, releasing the directory back to the OS).
/// We rely on the parent tempdir's mode being 0700 (the workspace
/// default) so a non-root local user cannot trivially access the
/// socket — same discipline as knomosis-host's Unix-socket listener.
#[cfg(unix)]
fn resolve_unix_socket_path(maybe_path: Option<&std::path::Path>) -> std::path::PathBuf {
    if let Some(path) = maybe_path {
        return path.to_path_buf();
    }
    let dir = tempfile::Builder::new()
        .prefix("knomosis-bench-")
        .tempdir()
        .expect("create tempdir for unix socket");
    let path = dir.path().join("bench.sock");
    // Leak the TempDir so the directory survives until process exit.
    // The OS-side `unlink` on process termination is the cleanup
    // contract; this matches knomosis-host's listener::unix path.
    Box::leak(Box::new(dir));
    path
}

/// Resolve the `--connect <ENDPOINT>` target into an [`Endpoint`].
///
/// Returns a tuple of `(endpoint, transport, standalone_server)`.  The
/// standalone-server handle is `None` in connect mode because no
/// in-process server was spawned; the caller is responsible for the
/// remote knomosis-host's lifecycle.
fn connect_endpoint(
    target: &knomosis_bench::config::ConnectTarget,
) -> (Endpoint, TransportKind, Option<StandaloneServer>) {
    match target {
        #[cfg(unix)]
        knomosis_bench::config::ConnectTarget::UnixSocket(path) => (
            Endpoint::UnixSocket(path.clone()),
            TransportKind::UnixSocket,
            None,
        ),
        knomosis_bench::config::ConnectTarget::Tcp(addr) => {
            (Endpoint::Tcp(*addr), TransportKind::Tcp, None)
        }
    }
}
