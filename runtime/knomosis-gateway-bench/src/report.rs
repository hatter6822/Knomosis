// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The benchmark report: a versioned, JSON-serialisable artefact + an optional
//! **baseline regression detector**.
//!
//! Two reports are comparable iff they were measured over the **same fixture
//! workload** (different actor / resource counts measure different things).
//! "Worse" is direction-aware: throughput regresses when the candidate falls
//! below `baseline × (1 − threshold)`; a latency percentile regresses when the
//! candidate rises above `baseline × (1 + threshold)`.

use std::path::Path;

use knomosis_bench::histogram::{Histogram, LatencySummary};

use crate::fixture::FixtureConfig;
use crate::runner::{RunOutcome, RunParams};
use crate::{BENCH_IDENTIFIER, PROTOCOL_VERSION};

/// A complete, versioned benchmark report.  Serialises to deterministic JSON.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct BenchReport {
    /// The harness identifier (`knomosis-gateway-bench/v1`).
    pub identifier: String,
    /// The harness crate version (information-only).
    pub harness_version: String,
    /// The report-schema protocol version (refused on a forward mismatch).
    pub protocol_version: u32,
    /// The fixture workload (two reports are comparable iff this matches).
    pub fixture: FixtureConfig,
    /// Concurrent client workers.
    pub workers: usize,
    /// Gateway handler-pool threads (the server side).
    pub handler_threads: usize,
    /// Warmup requests excluded from the measurement window.
    pub warmup_requests: usize,
    /// Measured requests that succeeded (HTTP 200).
    pub measured_requests: usize,
    /// Requests that failed (a healthy run reports `0`).
    pub errors: usize,
    /// Wallclock across the measured window (nanoseconds).
    pub elapsed_ns: u64,
    /// Sustained throughput (requests/second).
    pub throughput_ops_per_sec: f64,
    /// Per-request latency summary.
    pub latency: LatencySummary,
}

/// Errors loading / saving a report.
#[derive(Debug, thiserror::Error)]
pub enum ReportError {
    /// The report file could not be read / written.
    #[error("report I/O error: {0}")]
    Io(String),
    /// The report JSON could not be (de)serialised.
    #[error("report JSON error: {0}")]
    Json(String),
    /// The report's protocol version is newer than this harness understands.
    #[error("report protocol version {found} is newer than supported ({supported})")]
    Incompatible {
        /// The version found in the file.
        found: u32,
        /// The version this harness supports.
        supported: u32,
    },
}

impl BenchReport {
    /// Assemble a report from a [`RunOutcome`] + the run inputs.
    #[must_use]
    pub fn new(outcome: &RunOutcome, fixture: FixtureConfig, params: RunParams) -> Self {
        // `summarise` sorts a clone's samples; the outcome's histogram is not
        // mutated (the caller may still want it).
        let mut hist: Histogram = outcome.latency.clone();
        let latency = hist.summarise();
        Self {
            identifier: BENCH_IDENTIFIER.to_string(),
            harness_version: env!("CARGO_PKG_VERSION").to_string(),
            protocol_version: PROTOCOL_VERSION,
            fixture,
            workers: params.workers,
            handler_threads: params.handler_threads,
            warmup_requests: params.warmup,
            measured_requests: outcome.measured,
            errors: outcome.errors,
            elapsed_ns: u64::try_from(outcome.elapsed.as_nanos()).unwrap_or(u64::MAX),
            throughput_ops_per_sec: outcome.throughput,
            latency,
        }
    }

    /// Serialise to pretty JSON.
    ///
    /// # Errors
    ///
    /// [`ReportError::Json`] if serialisation fails (it never does for this
    /// `#[derive(Serialize)]` shape).
    pub fn to_json(&self) -> Result<String, ReportError> {
        serde_json::to_string_pretty(self).map_err(|e| ReportError::Json(e.to_string()))
    }

    /// Write the report to `path` as pretty JSON.
    ///
    /// # Errors
    ///
    /// [`ReportError::Json`] / [`ReportError::Io`].
    pub fn save(&self, path: &Path) -> Result<(), ReportError> {
        std::fs::write(path, self.to_json()?).map_err(|e| ReportError::Io(e.to_string()))
    }

    /// Load a report from `path`, refusing a forward-incompatible protocol
    /// version.
    ///
    /// # Errors
    ///
    /// [`ReportError::Io`] / [`ReportError::Json`] / [`ReportError::Incompatible`].
    pub fn load(path: &Path) -> Result<Self, ReportError> {
        let text = std::fs::read_to_string(path).map_err(|e| ReportError::Io(e.to_string()))?;
        let report: Self =
            serde_json::from_str(&text).map_err(|e| ReportError::Json(e.to_string()))?;
        if report.protocol_version > PROTOCOL_VERSION {
            return Err(ReportError::Incompatible {
                found: report.protocol_version,
                supported: PROTOCOL_VERSION,
            });
        }
        Ok(report)
    }

    /// A human-readable summary table.
    #[must_use]
    pub fn human_table(&self) -> String {
        let l = &self.latency;
        format!(
            "knomosis-gateway-bench  (GET /v1/actors/{{id}}/balances)\n\
             ────────────────────────────────────────────────────────\n\
             fixture        : {actors} actors × {resources} resources (seed {seed})\n\
             concurrency    : {workers} clients → {handler} handler threads\n\
             requests       : {measured} measured (+{warmup} warmup), {errors} errors\n\
             elapsed        : {elapsed_ms:.1} ms\n\
             throughput     : {tput:.0} req/sec\n\
             latency p50    : {p50}\n\
             latency p90    : {p90}\n\
             latency p99    : {p99}\n\
             latency p99.9  : {p999}\n\
             latency min/max: {min} / {max}\n\
             latency mean   : {mean}\n",
            actors = self.fixture.actors,
            resources = self.fixture.resources,
            seed = self.fixture.seed,
            workers = self.workers,
            handler = self.handler_threads,
            measured = self.measured_requests,
            warmup = self.warmup_requests,
            errors = self.errors,
            elapsed_ms = self.elapsed_ns as f64 / 1e6,
            tput = self.throughput_ops_per_sec,
            p50 = fmt_ns(l.p50_ns),
            p90 = fmt_ns(l.p90_ns),
            p99 = fmt_ns(l.p99_ns),
            p999 = fmt_ns(l.p999_ns),
            min = fmt_ns(l.min_ns),
            max = fmt_ns(l.max_ns),
            mean = fmt_ns(l.mean_ns as u64),
        )
    }

    /// Compare this (candidate) report against a `baseline`.  See the module
    /// docstring for the direction-aware semantics.
    #[must_use]
    pub fn compare_against_baseline(
        &self,
        baseline: &BenchReport,
        threshold: f64,
    ) -> RegressionVerdict {
        if self.fixture != baseline.fixture {
            return RegressionVerdict::NotComparable {
                reason: "the candidate and baseline fixtures differ; re-baseline on the same \
                         workload"
                    .to_string(),
            };
        }
        let mut details = Vec::new();
        // Throughput: a DROP below baseline × (1 − threshold) regresses.
        if self.throughput_ops_per_sec < baseline.throughput_ops_per_sec * (1.0 - threshold) {
            details.push(RegressionDetail {
                metric: "throughput_ops_per_sec".to_string(),
                baseline: baseline.throughput_ops_per_sec,
                candidate: self.throughput_ops_per_sec,
            });
        }
        // Latency: a RISE above baseline × (1 + threshold) regresses.
        for (metric, base, cand) in [
            (
                "latency_p50_ns",
                baseline.latency.p50_ns,
                self.latency.p50_ns,
            ),
            (
                "latency_p99_ns",
                baseline.latency.p99_ns,
                self.latency.p99_ns,
            ),
        ] {
            if cand as f64 > base as f64 * (1.0 + threshold) {
                details.push(RegressionDetail {
                    metric: metric.to_string(),
                    baseline: base as f64,
                    candidate: cand as f64,
                });
            }
        }
        if details.is_empty() {
            RegressionVerdict::WithinTolerance
        } else {
            RegressionVerdict::Regression { details }
        }
    }
}

/// Format a nanosecond latency as a human string with an adaptive unit.
fn fmt_ns(ns: u64) -> String {
    if ns >= 1_000_000 {
        format!("{:.2} ms", ns as f64 / 1e6)
    } else if ns >= 1_000 {
        format!("{:.1} µs", ns as f64 / 1e3)
    } else {
        format!("{ns} ns")
    }
}

/// The outcome of a baseline comparison.
#[derive(Clone, Debug, PartialEq)]
pub enum RegressionVerdict {
    /// Every guarded metric is within tolerance.
    WithinTolerance,
    /// At least one metric drifted outside tolerance in the worse direction.
    Regression {
        /// One entry per regressed metric.
        details: Vec<RegressionDetail>,
    },
    /// The two reports measured different workloads (incomparable).
    NotComparable {
        /// Why they are not comparable.
        reason: String,
    },
}

/// One regressed metric: the baseline + candidate values (so the caller can
/// report each independently).
#[derive(Clone, Debug, PartialEq)]
pub struct RegressionDetail {
    /// The metric name (e.g. `"throughput_ops_per_sec"`).
    pub metric: String,
    /// The baseline value.
    pub baseline: f64,
    /// The candidate value.
    pub candidate: f64,
}

#[cfg(test)]
mod tests {
    use super::{BenchReport, RegressionVerdict};
    use crate::fixture::FixtureConfig;
    use knomosis_bench::histogram::LatencySummary;

    fn report(throughput: f64, p50_ns: u64, p99_ns: u64) -> BenchReport {
        BenchReport {
            identifier: crate::BENCH_IDENTIFIER.to_string(),
            harness_version: "0.0.0".to_string(),
            protocol_version: crate::PROTOCOL_VERSION,
            fixture: FixtureConfig {
                actors: 100,
                resources: 2,
                seed: 7,
            },
            workers: 8,
            handler_threads: 8,
            warmup_requests: 10,
            measured_requests: 1000,
            errors: 0,
            elapsed_ns: 1_000_000_000,
            throughput_ops_per_sec: throughput,
            latency: LatencySummary {
                count: 1000,
                min_ns: 1_000,
                max_ns: p99_ns,
                mean_ns: p50_ns as f64,
                stddev_ns: 0.0,
                p50_ns,
                p90_ns: p99_ns,
                p99_ns,
                p999_ns: p99_ns,
            },
        }
    }

    #[test]
    fn json_round_trips_and_refuses_a_future_version() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("report.json");
        let r = report(5000.0, 50_000, 200_000);
        r.save(&path).unwrap();
        let loaded = BenchReport::load(&path).unwrap();
        assert_eq!(r, loaded);
        // A forward-incompatible version is refused.
        let mut future = r.clone();
        future.protocol_version = crate::PROTOCOL_VERSION + 1;
        future.save(&path).unwrap();
        assert!(matches!(
            BenchReport::load(&path),
            Err(super::ReportError::Incompatible { .. })
        ));
    }

    #[test]
    fn within_tolerance_when_metrics_hold() {
        let base = report(5000.0, 50_000, 200_000);
        // A small improvement (higher throughput, lower latency) is fine.
        let cand = report(5200.0, 48_000, 190_000);
        assert_eq!(
            cand.compare_against_baseline(&base, 0.10),
            RegressionVerdict::WithinTolerance
        );
        // A small (within ±10%) degradation is still within tolerance.
        let cand = report(4700.0, 54_000, 215_000);
        assert_eq!(
            cand.compare_against_baseline(&base, 0.10),
            RegressionVerdict::WithinTolerance
        );
    }

    #[test]
    fn detects_throughput_and_latency_regressions() {
        let base = report(5000.0, 50_000, 200_000);
        // Throughput down 30%, p99 up 50% → both flagged.
        let cand = report(3500.0, 50_000, 300_000);
        let RegressionVerdict::Regression { details } = cand.compare_against_baseline(&base, 0.10)
        else {
            panic!("expected a regression");
        };
        let metrics: Vec<&str> = details.iter().map(|d| d.metric.as_str()).collect();
        assert!(metrics.contains(&"throughput_ops_per_sec"));
        assert!(metrics.contains(&"latency_p99_ns"));
    }

    #[test]
    fn different_fixtures_are_not_comparable() {
        let base = report(5000.0, 50_000, 200_000);
        let mut cand = report(5000.0, 50_000, 200_000);
        cand.fixture.actors = 200; // different workload
        assert!(matches!(
            cand.compare_against_baseline(&base, 0.10),
            RegressionVerdict::NotComparable { .. }
        ));
    }
}
