// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-gateway-bench` CLI binary.
//!
//! Parses the benchmark configuration, seeds a read-only indexer fixture,
//! drives a real gateway listener with concurrent HTTP clients, prints a
//! human report (+ an optional JSON sidecar), and optionally compares against
//! a baseline — exiting non-zero on a regression.  Exit codes follow
//! [`OperatorExitCode`].

use knomosis_cli_common::exit::OperatorExitCode;

use knomosis_gateway_bench::config::{BenchConfig, ConfigError};
use knomosis_gateway_bench::fixture::{self, FixtureConfig};
use knomosis_gateway_bench::report::{BenchReport, RegressionVerdict};
use knomosis_gateway_bench::runner::{self, RunParams};
use knomosis_gateway_bench::{BENCH_IDENTIFIER, BENCH_TOKEN};

fn main() {
    run().terminate();
}

/// The benchmark's main flow, returning the process exit code.
fn run() -> OperatorExitCode {
    let args: Vec<String> = std::env::args().collect();
    let config = match BenchConfig::parse(&args) {
        Ok(config) => config,
        Err(ConfigError::HelpRequested) => {
            print!("{}", knomosis_gateway_bench::config::HELP_TEXT);
            return OperatorExitCode::Success;
        }
        Err(ConfigError::VersionRequested) => {
            println!("{BENCH_IDENTIFIER} {}", env!("CARGO_PKG_VERSION"));
            return OperatorExitCode::Success;
        }
        Err(e) => {
            eprintln!("configuration error: {e}");
            return OperatorExitCode::OperatorAction;
        }
    };

    // WARN by default: the gateway emits an INFO log line PER request (G4.3
    // observability), which would both flood the output and skew the
    // measurement (per-request formatting overhead).  The level filter
    // short-circuits those before formatting.  `RUST_LOG` still overrides for
    // debugging.
    if knomosis_cli_common::logging::init(tracing::Level::WARN).is_err() {
        eprintln!("failed to initialise logging");
        return OperatorExitCode::GeneralFailure;
    }
    // The bench token is a throwaway, loopback-only credential; surface it so
    // an operator reading the logs knows the gateway under test is ephemeral.
    tracing::debug!(
        token = BENCH_TOKEN,
        "benchmark gateway credential (throwaway)"
    );

    let fixture = match fixture::build(FixtureConfig {
        actors: config.actors,
        resources: config.resources,
        seed: config.seed,
    }) {
        Ok(fixture) => fixture,
        Err(e) => {
            eprintln!("fixture error: {e}");
            return OperatorExitCode::OperatorAction;
        }
    };
    tracing::info!(
        actors = config.actors,
        resources = config.resources,
        requests = config.requests,
        warmup = config.warmup,
        workers = config.workers,
        handler_threads = config.handler_threads,
        "starting benchmark"
    );

    let params = RunParams {
        requests: config.requests,
        warmup: config.warmup,
        workers: config.workers,
        handler_threads: config.handler_threads,
    };
    let outcome = match runner::run(&fixture, params) {
        Ok(outcome) => outcome,
        Err(e) => {
            eprintln!("benchmark run failed: {e}");
            return OperatorExitCode::Unavailable;
        }
    };

    let report = BenchReport::new(
        &outcome,
        FixtureConfig {
            actors: config.actors,
            resources: config.resources,
            seed: config.seed,
        },
        params,
    );
    print!("{}", report.human_table());
    if outcome.errors > 0 {
        eprintln!(
            "warning: {} request(s) failed during the run; the figures may be unreliable",
            outcome.errors
        );
    }

    if let Some(path) = &config.report {
        if let Err(e) = report.save(path) {
            eprintln!("failed to write the report to {}: {e}", path.display());
            return OperatorExitCode::GeneralFailure;
        }
        tracing::info!(path = %path.display(), "wrote JSON report");
    }

    if let Some(path) = &config.baseline {
        return compare_baseline(&report, path, config.threshold);
    }
    OperatorExitCode::Success
}

/// Load `baseline` and compare `report` against it, printing the verdict and
/// returning the matching exit code.
fn compare_baseline(
    report: &BenchReport,
    baseline_path: &std::path::Path,
    threshold: f64,
) -> OperatorExitCode {
    let baseline = match BenchReport::load(baseline_path) {
        Ok(baseline) => baseline,
        Err(e) => {
            eprintln!(
                "failed to load the baseline {}: {e}",
                baseline_path.display()
            );
            return OperatorExitCode::OperatorAction;
        }
    };
    match report.compare_against_baseline(&baseline, threshold) {
        RegressionVerdict::WithinTolerance => {
            println!(
                "baseline comparison: WITHIN TOLERANCE (±{:.0}%)",
                threshold * 100.0
            );
            OperatorExitCode::Success
        }
        RegressionVerdict::NotComparable { reason } => {
            eprintln!("baseline comparison: NOT COMPARABLE — {reason}");
            OperatorExitCode::OperatorAction
        }
        RegressionVerdict::Regression { details } => {
            eprintln!(
                "baseline comparison: REGRESSION (threshold ±{:.0}%)",
                threshold * 100.0
            );
            for d in &details {
                eprintln!(
                    "  {}: baseline {:.2} → candidate {:.2}",
                    d.metric, d.baseline, d.candidate
                );
            }
            OperatorExitCode::GeneralFailure
        }
    }
}
