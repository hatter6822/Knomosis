// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Benchmark report + optional baseline regression detector.
//!
//! ## Report shape
//!
//! A [`BenchmarkReport`] carries:
//!
//!   * The benchmark identifier + the harness version + the
//!     protocol version (for forward-compatibility detection).
//!   * The [`crate::fixture::FixtureConfig`] used to derive the
//!     workload (seed, actor count, transfer count, ...).
//!   * The per-run measurement: total elapsed wallclock, total
//!     completed requests, sustained throughput (ops/sec), and
//!     the latency [`crate::histogram::LatencySummary`].
//!
//! ## JSON format
//!
//! All public fields are `#[derive(Serialize, Deserialize)]` so the
//! report serialises to deterministic, machine-readable JSON.  The
//! `protocol_version` field is the schema-evolution anchor:
//!
//!   * v1 (current) — fields exactly as defined here.
//!   * vN — to be defined by future amendment.  A reader that
//!     sees `protocol_version > known_version` MUST refuse to
//!     interpret the file (a forward-incompatible report could
//!     silently mismatch baseline comparisons).
//!
//! ## Baseline regression detection
//!
//! Given a baseline report + a candidate report,
//! [`compare_against_baseline`] returns a [`RegressionVerdict`] enum:
//!
//!   * `WithinTolerance` — every guarded metric is within the
//!     configured threshold of the baseline.
//!   * `Regression { ... }` — at least one metric drifted
//!     outside the threshold in the worse direction (throughput
//!     dropped, p99 grew).  Carries a typed `RegressionDetail`
//!     per metric so callers can report each independently.
//!
//! "Worse" is direction-aware:
//!
//!   * Throughput regression: candidate `< baseline × (1 - threshold)`.
//!     A higher throughput is always acceptable.
//!   * Latency (p50 / p99 / p999) regression: candidate
//!     `> baseline × (1 + threshold)`.  A lower latency is always
//!     acceptable.
//!
//! ## Why a separate report module
//!
//! The benchmark `Runner` writes raw histograms + elapsed
//! durations; the [`BenchmarkReport`] is the *publication-ready*
//! artefact: JSON-pretty-printable, baseline-comparable, and
//! versioned.  Decoupling avoids the runner needing to know how to
//! format / persist its output, and keeps the schema-evolution
//! surface narrow.

use crate::fixture::FixtureConfig;
use crate::histogram::LatencySummary;

/// A complete benchmark report.  Serialises to versioned JSON.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct BenchmarkReport {
    /// Identifier of the benchmark harness that produced this
    /// report (e.g. `"canon-bench/v1"`).  Compared against the
    /// current `BENCH_IDENTIFIER` on read.
    pub identifier: String,
    /// The crate version (from `Cargo.toml`).  Used for
    /// information-only context in human-readable reports.
    pub harness_version: String,
    /// The benchmark protocol version.  Mismatched versions cause
    /// `BenchmarkReport::load` to refuse the read.
    pub protocol_version: u32,
    /// The fixture configuration the workload was generated from.
    /// Identical configs produce identical workloads, so two
    /// reports with the same `fixture_config` are directly
    /// comparable.
    pub fixture_config: ReportFixtureConfig,
    /// The number of worker threads driving submissions.
    pub worker_count: usize,
    /// The number of warmup requests excluded from the
    /// measurement window.
    pub warmup_requests: usize,
    /// Total wallclock elapsed during the measurement phase, in
    /// nanoseconds.  Warmup time is excluded.
    pub elapsed_ns: u64,
    /// Number of requests counted in the measurement phase.
    pub measured_requests: usize,
    /// Sustained throughput: `measured_requests / elapsed_seconds`.
    pub throughput_ops_per_sec: f64,
    /// Per-request latency summary.
    pub latency: LatencySummary,
    /// The transport the benchmark used.
    pub transport: TransportKind,
}

/// Snapshot of `FixtureConfig` fields included in the report.  We
/// don't serialise `FixtureConfig` directly because (a) its
/// `deployment_id: Vec<u8>` becomes a JSON array which is
/// non-human-readable, and (b) future `FixtureConfig` fields
/// shouldn't auto-propagate to the report schema (which is a
/// stability surface).
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ReportFixtureConfig {
    /// Fixture seed.
    pub seed: u64,
    /// Number of pre-funded actors.
    pub actor_count: usize,
    /// Number of pre-signed transfers (== `measured_requests +
    /// warmup_requests` modulo any incomplete worker quotas).
    pub transfer_count: usize,
    /// Resource id used for transfers.
    pub resource_id: u64,
    /// Per-transfer amount.
    pub transfer_amount: u128,
    /// Hex-encoded deployment id.  Hex-encoded (not raw bytes) so
    /// the JSON stays human-readable.
    pub deployment_id_hex: String,
}

impl ReportFixtureConfig {
    /// Project a [`FixtureConfig`] into its report-friendly snapshot.
    #[must_use]
    pub fn from_fixture(cfg: &FixtureConfig) -> Self {
        let mut hex = String::with_capacity(cfg.deployment_id.len() * 2);
        for b in &cfg.deployment_id {
            // Inline hex without dragging in `hex` as a runtime
            // dep.  Lowercase to match the rest of the workspace.
            const HEX: &[u8; 16] = b"0123456789abcdef";
            hex.push(HEX[(b >> 4) as usize] as char);
            hex.push(HEX[(b & 0x0f) as usize] as char);
        }
        Self {
            seed: cfg.seed,
            actor_count: cfg.actor_count,
            transfer_count: cfg.transfer_count,
            resource_id: cfg.resource_id,
            transfer_amount: cfg.transfer_amount,
            deployment_id_hex: hex,
        }
    }
}

/// Transport used by the runner.  Recorded so reports document
/// which path was measured.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TransportKind {
    /// Unix domain socket (recommended on Unix hosts; the plan
    /// §RH-F's "TCP adds spurious latency" rationale).
    UnixSocket,
    /// Plain TCP (loopback for fairness).
    Tcp,
}

impl TransportKind {
    /// Human-readable name suitable for logs.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::UnixSocket => "unix-socket",
            Self::Tcp => "tcp",
        }
    }
}

/// Errors surfaced by report load / save.
#[derive(Debug, thiserror::Error)]
pub enum ReportError {
    /// The file could not be opened or read.
    #[error("report I/O error at {path}: {source}")]
    Io {
        /// The file path that failed.
        path: String,
        /// The underlying I/O error.
        #[source]
        source: std::io::Error,
    },
    /// The file's JSON could not be parsed.
    #[error("report JSON parse error at {path}: {source}")]
    ParseJson {
        /// The file path whose contents failed to parse.
        path: String,
        /// The underlying serde_json error.
        #[source]
        source: serde_json::Error,
    },
    /// The file's `protocol_version` doesn't match the current
    /// runtime's understanding.  Refusing the read keeps baseline
    /// comparisons honest.
    #[error("report protocol_version {found} does not match current {expected} at {path}")]
    ProtocolMismatch {
        /// The file path that failed.
        path: String,
        /// The version recorded in the file.
        found: u32,
        /// The version this runtime supports.
        expected: u32,
    },
    /// The file's JSON could not be re-serialised (unreachable for
    /// owned data).
    #[error("report JSON encode error: {0}")]
    EncodeJson(#[from] serde_json::Error),
}

impl BenchmarkReport {
    /// Write this report as pretty-printed JSON to the given file.
    /// The output is byte-identical for byte-identical inputs.
    ///
    /// # Errors
    ///
    /// Returns `ReportError::Io` if the file cannot be written.
    pub fn save(&self, path: &std::path::Path) -> Result<(), ReportError> {
        let json = serde_json::to_string_pretty(self).map_err(ReportError::EncodeJson)?;
        std::fs::write(path, json).map_err(|source| ReportError::Io {
            path: path.display().to_string(),
            source,
        })
    }

    /// Read a report from a JSON file.  Refuses to interpret a
    /// file whose `protocol_version` doesn't match the current
    /// `PROTOCOL_VERSION`.
    ///
    /// # Errors
    ///
    /// Returns `ReportError::Io` if the file cannot be read,
    /// `ReportError::ParseJson` if the JSON is malformed, and
    /// `ReportError::ProtocolMismatch` if the schema version drifted.
    pub fn load(path: &std::path::Path) -> Result<Self, ReportError> {
        let bytes = std::fs::read(path).map_err(|source| ReportError::Io {
            path: path.display().to_string(),
            source,
        })?;
        let report: Self =
            serde_json::from_slice(&bytes).map_err(|source| ReportError::ParseJson {
                path: path.display().to_string(),
                source,
            })?;
        if report.protocol_version != crate::PROTOCOL_VERSION {
            return Err(ReportError::ProtocolMismatch {
                path: path.display().to_string(),
                found: report.protocol_version,
                expected: crate::PROTOCOL_VERSION,
            });
        }
        Ok(report)
    }

    /// Format the report as a human-readable multi-line summary.
    /// Used by the CLI binary's stdout output.
    #[must_use]
    pub fn to_human_summary(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "{} v{} (proto v{})\n",
            self.identifier, self.harness_version, self.protocol_version
        ));
        out.push_str(&format!("  Transport       : {}\n", self.transport.name()));
        out.push_str(&format!("  Workers         : {}\n", self.worker_count));
        out.push_str(&format!(
            "  Actors          : {}\n",
            self.fixture_config.actor_count
        ));
        out.push_str(&format!(
            "  Transfers       : {}\n",
            self.fixture_config.transfer_count
        ));
        out.push_str(&format!("  Warmup requests : {}\n", self.warmup_requests));
        out.push_str(&format!("  Measured reqs   : {}\n", self.measured_requests));
        out.push_str(&format!(
            "  Elapsed         : {:.3} s\n",
            self.elapsed_ns as f64 / 1e9
        ));
        out.push_str(&format!(
            "  Throughput      : {:.1} ops/sec\n",
            self.throughput_ops_per_sec
        ));
        out.push_str("  Latency:\n");
        out.push_str(&format!(
            "    min  : {:>9.3} µs\n",
            self.latency.min_ns as f64 / 1_000.0
        ));
        out.push_str(&format!(
            "    p50  : {:>9.3} µs\n",
            self.latency.p50_ns as f64 / 1_000.0
        ));
        out.push_str(&format!(
            "    p90  : {:>9.3} µs\n",
            self.latency.p90_ns as f64 / 1_000.0
        ));
        out.push_str(&format!(
            "    p99  : {:>9.3} µs\n",
            self.latency.p99_ns as f64 / 1_000.0
        ));
        out.push_str(&format!(
            "    p999 : {:>9.3} µs\n",
            self.latency.p999_ns as f64 / 1_000.0
        ));
        out.push_str(&format!(
            "    max  : {:>9.3} µs\n",
            self.latency.max_ns as f64 / 1_000.0
        ));
        out.push_str(&format!(
            "    mean : {:>9.3} µs (± {:.3} µs stddev)\n",
            self.latency.mean_ns / 1_000.0,
            self.latency.stddev_ns / 1_000.0
        ));
        out
    }
}

/// Comparison result between a candidate and baseline report.
#[derive(Clone, Debug, PartialEq)]
pub enum RegressionVerdict {
    /// Every guarded metric is within `threshold` of the baseline.
    WithinTolerance,
    /// At least one metric regressed (worse than baseline by more
    /// than `threshold`).
    Regression {
        /// Per-metric regression details.  Always non-empty (if
        /// it were empty, the verdict would be
        /// `WithinTolerance`).
        details: Vec<RegressionDetail>,
    },
}

/// Per-metric regression detail.
#[derive(Clone, Debug, PartialEq)]
pub struct RegressionDetail {
    /// Which metric regressed.
    pub metric: RegressionMetric,
    /// The baseline value for this metric.
    pub baseline: f64,
    /// The candidate value for this metric.
    pub candidate: f64,
    /// The relative drift (candidate / baseline) - 1 for latency
    /// metrics; 1 - (candidate / baseline) for throughput.
    /// Positive = worse, negative = better.
    pub relative_drift: f64,
    /// The configured threshold for this metric (0..1).
    pub threshold: f64,
}

/// The metric that regressed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RegressionMetric {
    /// Throughput dropped by more than `threshold`.
    ThroughputDropped,
    /// p50 latency grew by more than `threshold`.
    P50LatencyGrew,
    /// p99 latency grew by more than `threshold`.
    P99LatencyGrew,
    /// p999 latency grew by more than `threshold`.
    P999LatencyGrew,
}

impl RegressionMetric {
    /// Human-readable name.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::ThroughputDropped => "throughput",
            Self::P50LatencyGrew => "p50_latency",
            Self::P99LatencyGrew => "p99_latency",
            Self::P999LatencyGrew => "p999_latency",
        }
    }
}

/// Compare a candidate report against a baseline, returning a
/// verdict.  The `threshold` argument is a fraction in `(0, 1)`;
/// drift greater than this is reported as a regression.
///
/// Direction-aware comparison:
///
///   * Throughput regresses if `candidate < baseline × (1 - threshold)`.
///   * Latency metrics regress if `candidate > baseline × (1 + threshold)`.
///
/// Speed improvements (lower latency, higher throughput) NEVER
/// trigger a regression.
#[must_use]
pub fn compare_against_baseline(
    baseline: &BenchmarkReport,
    candidate: &BenchmarkReport,
    threshold: f64,
) -> RegressionVerdict {
    let mut details: Vec<RegressionDetail> = Vec::new();

    // Throughput: candidate must be >= baseline × (1 - threshold).
    let throughput_floor = baseline.throughput_ops_per_sec * (1.0 - threshold);
    if candidate.throughput_ops_per_sec < throughput_floor {
        let drift = if baseline.throughput_ops_per_sec > 0.0 {
            1.0 - (candidate.throughput_ops_per_sec / baseline.throughput_ops_per_sec)
        } else {
            0.0
        };
        details.push(RegressionDetail {
            metric: RegressionMetric::ThroughputDropped,
            baseline: baseline.throughput_ops_per_sec,
            candidate: candidate.throughput_ops_per_sec,
            relative_drift: drift,
            threshold,
        });
    }

    // Latency metrics: candidate must be <= baseline × (1 + threshold).
    check_latency_ceiling(
        baseline.latency.p50_ns,
        candidate.latency.p50_ns,
        threshold,
        RegressionMetric::P50LatencyGrew,
        &mut details,
    );
    check_latency_ceiling(
        baseline.latency.p99_ns,
        candidate.latency.p99_ns,
        threshold,
        RegressionMetric::P99LatencyGrew,
        &mut details,
    );
    check_latency_ceiling(
        baseline.latency.p999_ns,
        candidate.latency.p999_ns,
        threshold,
        RegressionMetric::P999LatencyGrew,
        &mut details,
    );

    if details.is_empty() {
        RegressionVerdict::WithinTolerance
    } else {
        RegressionVerdict::Regression { details }
    }
}

/// Helper: append a regression detail if a candidate latency
/// exceeds `baseline × (1 + threshold)`.
fn check_latency_ceiling(
    baseline_ns: u64,
    candidate_ns: u64,
    threshold: f64,
    metric: RegressionMetric,
    details: &mut Vec<RegressionDetail>,
) {
    if baseline_ns == 0 {
        // Without a baseline we can't compute a relative drift; skip.
        return;
    }
    let baseline = baseline_ns as f64;
    let candidate = candidate_ns as f64;
    let ceiling = baseline * (1.0 + threshold);
    if candidate > ceiling {
        let drift = (candidate / baseline) - 1.0;
        details.push(RegressionDetail {
            metric,
            baseline,
            candidate,
            relative_drift: drift,
            threshold,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::{
        compare_against_baseline, BenchmarkReport, RegressionDetail, RegressionMetric,
        RegressionVerdict, ReportError, ReportFixtureConfig, TransportKind,
    };
    use crate::fixture::FixtureConfig;
    use crate::histogram::LatencySummary;
    use std::path::PathBuf;

    /// Construct a baseline report with fixed values.
    fn make_report(throughput: f64, p50_ns: u64, p99_ns: u64, p999_ns: u64) -> BenchmarkReport {
        BenchmarkReport {
            identifier: crate::BENCH_IDENTIFIER.to_string(),
            harness_version: env!("CARGO_PKG_VERSION").to_string(),
            protocol_version: crate::PROTOCOL_VERSION,
            fixture_config: ReportFixtureConfig {
                seed: 1,
                actor_count: 10,
                transfer_count: 100,
                resource_id: 0,
                transfer_amount: 1,
                deployment_id_hex: "00".repeat(16),
            },
            worker_count: 64,
            warmup_requests: 1000,
            elapsed_ns: 1_000_000_000,
            measured_requests: 9_000,
            throughput_ops_per_sec: throughput,
            latency: LatencySummary {
                count: 9_000,
                min_ns: 100,
                max_ns: p999_ns,
                mean_ns: p50_ns as f64,
                stddev_ns: 100.0,
                p50_ns,
                p90_ns: p99_ns,
                p99_ns,
                p999_ns,
            },
            transport: TransportKind::UnixSocket,
        }
    }

    /// `ReportFixtureConfig::from_fixture` hex-encodes deployment id.
    #[test]
    fn fixture_config_hex_encodes_deployment_id() {
        let mut cfg = FixtureConfig::default();
        cfg.deployment_id = vec![0xab, 0xcd, 0xef];
        let snap = ReportFixtureConfig::from_fixture(&cfg);
        assert_eq!(snap.deployment_id_hex, "abcdef");
    }

    /// `TransportKind` names are stable.
    #[test]
    fn transport_kind_names() {
        assert_eq!(TransportKind::UnixSocket.name(), "unix-socket");
        assert_eq!(TransportKind::Tcp.name(), "tcp");
    }

    /// Within-tolerance: identical reports return `WithinTolerance`.
    #[test]
    fn within_tolerance_for_identical_reports() {
        let baseline = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let candidate = baseline.clone();
        let v = compare_against_baseline(&baseline, &candidate, 0.10);
        assert!(matches!(v, RegressionVerdict::WithinTolerance));
    }

    /// Throughput drop just within threshold: WithinTolerance.
    #[test]
    fn throughput_drop_within_threshold() {
        let baseline = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let candidate = make_report(9_500.0, 100_000, 500_000, 1_000_000);
        // 5% drop < 10% threshold.
        let v = compare_against_baseline(&baseline, &candidate, 0.10);
        assert!(matches!(v, RegressionVerdict::WithinTolerance));
    }

    /// Throughput drop beyond threshold triggers regression.
    #[test]
    fn throughput_drop_beyond_threshold() {
        let baseline = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let candidate = make_report(8_500.0, 100_000, 500_000, 1_000_000);
        // 15% drop > 10% threshold.
        let v = compare_against_baseline(&baseline, &candidate, 0.10);
        match v {
            RegressionVerdict::Regression { details } => {
                assert_eq!(details.len(), 1);
                assert_eq!(details[0].metric, RegressionMetric::ThroughputDropped);
                assert!(details[0].relative_drift > 0.10);
            }
            _ => panic!("expected regression"),
        }
    }

    /// Throughput improvement never triggers a regression.
    #[test]
    fn throughput_improvement_no_regression() {
        let baseline = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let candidate = make_report(20_000.0, 100_000, 500_000, 1_000_000);
        let v = compare_against_baseline(&baseline, &candidate, 0.10);
        assert!(matches!(v, RegressionVerdict::WithinTolerance));
    }

    /// p99 latency growth triggers a regression.
    #[test]
    fn p99_latency_growth_triggers_regression() {
        let baseline = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let candidate = make_report(10_000.0, 100_000, 700_000, 1_000_000);
        // 40% growth > 10% threshold.
        let v = compare_against_baseline(&baseline, &candidate, 0.10);
        match v {
            RegressionVerdict::Regression { details } => {
                let metrics: Vec<_> = details.iter().map(|d| d.metric).collect();
                assert!(metrics.contains(&RegressionMetric::P99LatencyGrew));
            }
            _ => panic!("expected regression"),
        }
    }

    /// p50 latency improvement never triggers a regression.
    #[test]
    fn p50_latency_improvement_no_regression() {
        let baseline = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let candidate = make_report(10_000.0, 50_000, 500_000, 1_000_000);
        let v = compare_against_baseline(&baseline, &candidate, 0.10);
        assert!(matches!(v, RegressionVerdict::WithinTolerance));
    }

    /// Multiple regressions surface multiple details.
    #[test]
    fn multiple_regressions() {
        let baseline = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let candidate = make_report(5_000.0, 100_000, 1_000_000, 2_000_000);
        let v = compare_against_baseline(&baseline, &candidate, 0.10);
        match v {
            RegressionVerdict::Regression { details } => {
                assert!(details.len() >= 3); // throughput + p99 + p999
            }
            _ => panic!("expected regression"),
        }
    }

    /// `BenchmarkReport::save` then `load` round-trips.
    #[test]
    fn save_load_round_trip() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("report.json");
        let report = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        report.save(&path).unwrap();
        let loaded = BenchmarkReport::load(&path).unwrap();
        assert_eq!(report, loaded);
    }

    /// `BenchmarkReport::load` refuses a future protocol version.
    #[test]
    fn load_refuses_future_protocol_version() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("report.json");
        let mut report = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        report.protocol_version = crate::PROTOCOL_VERSION + 1;
        report.save(&path).unwrap();
        let result = BenchmarkReport::load(&path);
        assert!(matches!(result, Err(ReportError::ProtocolMismatch { .. })));
    }

    /// `BenchmarkReport::load` rejects malformed JSON.
    #[test]
    fn load_rejects_malformed_json() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("malformed.json");
        std::fs::write(&path, "not valid json").unwrap();
        let result = BenchmarkReport::load(&path);
        assert!(matches!(result, Err(ReportError::ParseJson { .. })));
    }

    /// `BenchmarkReport::load` reports `Io` for missing files.
    #[test]
    fn load_reports_io_for_missing() {
        let path = PathBuf::from("/non/existent/path.json");
        let result = BenchmarkReport::load(&path);
        assert!(matches!(result, Err(ReportError::Io { .. })));
    }

    /// `to_human_summary` includes the identifier and key metrics.
    #[test]
    fn human_summary_contains_key_fields() {
        let report = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let s = report.to_human_summary();
        assert!(s.contains("canon-bench"));
        assert!(s.contains("ops/sec"));
        assert!(s.contains("p99"));
        assert!(s.contains("p999"));
        assert!(s.contains("unix-socket"));
    }

    /// `RegressionDetail` carries the documented fields.
    #[test]
    fn regression_detail_fields() {
        let d = RegressionDetail {
            metric: RegressionMetric::ThroughputDropped,
            baseline: 100.0,
            candidate: 50.0,
            relative_drift: 0.5,
            threshold: 0.10,
        };
        assert_eq!(d.metric.name(), "throughput");
        assert!((d.relative_drift - 0.5).abs() < f64::EPSILON);
    }

    /// `RegressionMetric` names are stable and distinct.
    #[test]
    fn regression_metric_names_distinct() {
        let names = [
            RegressionMetric::ThroughputDropped.name(),
            RegressionMetric::P50LatencyGrew.name(),
            RegressionMetric::P99LatencyGrew.name(),
            RegressionMetric::P999LatencyGrew.name(),
        ];
        let mut seen = std::collections::HashSet::new();
        for n in names {
            assert!(seen.insert(n), "duplicate metric name: {n}");
        }
    }
}
