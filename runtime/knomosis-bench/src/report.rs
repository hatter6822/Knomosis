// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

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
    /// report (e.g. `"knomosis-bench/v1"`).  Compared against the
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
    /// The file's JSON parsed but contains a malformed field value
    /// (e.g., a non-finite f64 like `1e500`-as-infinity, or a
    /// negative throughput).  Hand-edited or corrupted reports
    /// could otherwise contaminate downstream regression-check
    /// arithmetic.
    #[error("report field {field} has invalid value {value} at {path}")]
    InvalidFieldValue {
        /// The file path whose contents validate-failed.
        path: String,
        /// Which field surfaced the invalid value.
        field: &'static str,
        /// The offending value (formatted for diagnostics).
        value: String,
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
    /// ## Pre-write validation
    ///
    /// Before serialising, `save()` validates that the report's
    /// f64 fields are finite + non-negative.  Without this check,
    /// `serde_json` would **silently** convert `f64::INFINITY` /
    /// `f64::NAN` to the JSON literal `null`, producing a file
    /// that fails to re-load (since the `f64` deserializer rejects
    /// `null`).  Validating upfront converts the silent data-loss
    /// path into a typed `ReportError::InvalidFieldValue` at save
    /// time, before any partial-write artifacts hit disk.
    ///
    /// ## Atomicity
    ///
    /// Writes are atomic-by-rename: the JSON is first written to a
    /// sibling file with a `.tmp` suffix, then `rename(2)`-ed into
    /// place.  On POSIX `rename(2)` is atomic with respect to other
    /// readers of the destination path — readers see either the old
    /// file or the new one, never a half-written one.  This
    /// protects CI baseline persistence against the (rare)
    /// mid-write process crash.  On rename failure the `.tmp` file
    /// is left behind for operator inspection rather than removed
    /// (so the partial data can be salvaged if the rename failure
    /// indicates filesystem corruption rather than transient I/O).
    ///
    /// # Errors
    ///
    /// Returns `ReportError::InvalidFieldValue` if a f64 field is
    /// non-finite or negative.  Returns `ReportError::Io` if the
    /// temp file cannot be written or the rename fails.  Returns
    /// `ReportError::EncodeJson` if serialisation fails
    /// (unreachable for owned data that passed validation).
    pub fn save(&self, path: &std::path::Path) -> Result<(), ReportError> {
        self.validate_loaded(path)?;
        let json = serde_json::to_string_pretty(self).map_err(ReportError::EncodeJson)?;
        // Write to a sibling `.tmp` first, then atomically rename
        // into place.  The temp filename derives from the target's
        // file_name + ".tmp" suffix; if `path` has no file name
        // (e.g. it's a directory), we fall back to writing
        // directly — that error path is the same as the original
        // non-atomic `fs::write`.
        let tmp_path = match path.file_name() {
            Some(name) => {
                let mut name_with_suffix = name.to_os_string();
                name_with_suffix.push(".tmp");
                path.with_file_name(name_with_suffix)
            }
            None => {
                return std::fs::write(path, json).map_err(|source| ReportError::Io {
                    path: path.display().to_string(),
                    source,
                });
            }
        };
        std::fs::write(&tmp_path, json).map_err(|source| ReportError::Io {
            path: tmp_path.display().to_string(),
            source,
        })?;
        std::fs::rename(&tmp_path, path).map_err(|source| ReportError::Io {
            path: path.display().to_string(),
            source,
        })
    }

    /// Read a report from a JSON file.  Refuses to interpret a
    /// file whose `protocol_version` doesn't match the current
    /// `PROTOCOL_VERSION`, OR whose f64 fields contain non-finite
    /// or negative values (which would contaminate regression
    /// arithmetic downstream).
    ///
    /// # Errors
    ///
    /// Returns `ReportError::Io` if the file cannot be read,
    /// `ReportError::ParseJson` if the JSON is malformed,
    /// `ReportError::ProtocolMismatch` if the schema version
    /// drifted, and `ReportError::InvalidFieldValue` if a parsed
    /// field value is out-of-range.
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
        report.validate_loaded(path)?;
        Ok(report)
    }

    /// Validate the f64 fields of a loaded report.  Used by
    /// [`Self::load`] to defend downstream arithmetic against
    /// hand-edited or corrupted JSON files that smuggled in
    /// non-finite values (e.g. `1e500` parses to
    /// `f64::INFINITY` via `f64::from_str`) or negative
    /// metrics.
    ///
    /// The validation contract:
    ///   * `throughput_ops_per_sec` MUST be finite + non-negative.
    ///   * `latency.mean_ns` MUST be finite + non-negative.
    ///   * `latency.stddev_ns` MUST be finite + non-negative.
    ///
    /// Integer fields are inherently finite + bounded by their
    /// type; no further validation needed.
    fn validate_loaded(&self, path: &std::path::Path) -> Result<(), ReportError> {
        let path_str = path.display().to_string();
        check_finite_nonneg(
            self.throughput_ops_per_sec,
            "throughput_ops_per_sec",
            &path_str,
        )?;
        check_finite_nonneg(self.latency.mean_ns, "latency.mean_ns", &path_str)?;
        check_finite_nonneg(self.latency.stddev_ns, "latency.stddev_ns", &path_str)?;
        Ok(())
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
///
/// ## Non-finite defense
///
/// If `threshold` is non-finite (NaN / ±∞) the result is
/// `WithinTolerance` (we can't compute a meaningful bound).
/// `BenchmarkReport::load` validates the report's f64 fields are
/// finite + non-negative; this function trusts that contract for
/// knomosis-bench-produced reports.  Defensive non-finite handling
/// inside the function would mask data-integrity bugs upstream.
#[must_use]
pub fn compare_against_baseline(
    baseline: &BenchmarkReport,
    candidate: &BenchmarkReport,
    threshold: f64,
) -> RegressionVerdict {
    let mut details: Vec<RegressionDetail> = Vec::new();

    // Defensive: a non-finite threshold can't produce a meaningful
    // verdict; treat as "no regression detected" rather than
    // producing NaN-laden drift values.  `CliConfig::validate`
    // already rejects non-finite thresholds at the CLI; this is
    // defence-in-depth for library callers that bypass the CLI.
    if !threshold.is_finite() {
        return RegressionVerdict::WithinTolerance;
    }

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

/// Helper: validate that an f64 field is finite + non-negative.
/// Used by [`BenchmarkReport::validate_loaded`].
fn check_finite_nonneg(value: f64, field: &'static str, path: &str) -> Result<(), ReportError> {
    if !value.is_finite() || value < 0.0 {
        return Err(ReportError::InvalidFieldValue {
            path: path.to_string(),
            field,
            value: format!("{value}"),
        });
    }
    Ok(())
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

    /// REGRESSION: `save` writes atomically (via tmp + rename), so
    /// the destination file always reflects a complete document.
    /// We verify by inspecting the post-save tempdir: it should
    /// contain `report.json` (the target) and NOT `report.json.tmp`
    /// (which was renamed away).
    #[test]
    fn save_uses_atomic_rename() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("report.json");
        let report = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        report.save(&path).unwrap();
        // Target file exists.
        assert!(path.exists());
        // The `.tmp` sibling has been renamed away.
        let tmp_path = path.with_file_name("report.json.tmp");
        assert!(!tmp_path.exists());
        // The directory has exactly one file (the target).
        let entries: Vec<_> = std::fs::read_dir(temp.path())
            .unwrap()
            .filter_map(Result::ok)
            .collect();
        assert_eq!(entries.len(), 1, "expected exactly one file in tempdir");
    }

    /// REGRESSION: `save` to a target whose parent directory
    /// doesn't exist returns an `Io` error without leaving any
    /// partial-state artefact behind.
    #[test]
    fn save_rejects_missing_parent_directory() {
        let report = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        // Parent /nonexistent/missing/path does not exist; tmp
        // write will fail with ENOENT.
        let bad_path = std::path::PathBuf::from("/nonexistent/missing/path/report.json");
        let result = report.save(&bad_path);
        assert!(matches!(result, Err(ReportError::Io { .. })));
    }

    /// `save` to a path with no file name (e.g. a directory) is
    /// handled gracefully — falls back to non-atomic write whose
    /// I/O error surfaces correctly.
    #[test]
    fn save_no_filename_falls_back_to_direct_write() {
        let temp = tempfile::tempdir().unwrap();
        // The tempdir's path has a file_name (the random temp
        // directory name itself), but it IS a directory, so
        // fs::write will fail.
        let report = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let result = report.save(temp.path());
        // Either path the test traverses (the temp::write fallback
        // or the rename failure) surfaces as Io.
        assert!(matches!(result, Err(ReportError::Io { .. })));
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

    /// REGRESSION: `BenchmarkReport::load` rejects hand-edited
    /// JSON where a numeric field overflows to `f64::INFINITY` —
    /// the rejection happens at serde_json's parser layer (it
    /// surfaces as `Error("number out of range")`) BEFORE our
    /// `validate_loaded` check fires.  Defense-in-depth: even
    /// without our check, serde_json blocks the infinity-via-
    /// decimal-overflow injection.
    ///
    /// This test pins serde_json's behaviour so a future
    /// dependency bump that changes the parser's overflow handling
    /// surfaces here.
    #[test]
    fn load_rejects_infinity_overflow_via_serde() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("inf.json");
        // `1e500` exceeds f64::MAX; serde_json rejects via
        // ParseJson.
        let json = r#"{
            "identifier": "knomosis-bench/v1",
            "harness_version": "0.2.1",
            "protocol_version": 1,
            "fixture_config": {
                "seed": 1,
                "actor_count": 10,
                "transfer_count": 100,
                "resource_id": 0,
                "transfer_amount": 1,
                "deployment_id_hex": "00"
            },
            "worker_count": 64,
            "warmup_requests": 1000,
            "elapsed_ns": 1000000000,
            "measured_requests": 9000,
            "throughput_ops_per_sec": 1e500,
            "latency": {
                "count": 9000,
                "min_ns": 100,
                "max_ns": 1000000,
                "mean_ns": 500.0,
                "stddev_ns": 100.0,
                "p50_ns": 500,
                "p90_ns": 900,
                "p99_ns": 990,
                "p999_ns": 999
            },
            "transport": "unix-socket"
        }"#;
        std::fs::write(&path, json).unwrap();
        let result = BenchmarkReport::load(&path);
        // serde_json rejects at parse time; our defense-in-depth
        // `validate_loaded` is unreachable for this case (but
        // remains correct for direct-API callers that construct
        // BenchmarkReport with infinity values).
        assert!(matches!(result, Err(ReportError::ParseJson { .. })));
    }

    /// REGRESSION: `BenchmarkReport::load` rejects negative
    /// throughput (impossible from knomosis-bench but possible from
    /// hand-edits).
    #[test]
    fn load_rejects_negative_throughput() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("negative.json");
        let json = r#"{
            "identifier": "knomosis-bench/v1",
            "harness_version": "0.2.1",
            "protocol_version": 1,
            "fixture_config": {
                "seed": 1,
                "actor_count": 10,
                "transfer_count": 100,
                "resource_id": 0,
                "transfer_amount": 1,
                "deployment_id_hex": "00"
            },
            "worker_count": 64,
            "warmup_requests": 1000,
            "elapsed_ns": 1000000000,
            "measured_requests": 9000,
            "throughput_ops_per_sec": -100.0,
            "latency": {
                "count": 9000,
                "min_ns": 100,
                "max_ns": 1000000,
                "mean_ns": 500.0,
                "stddev_ns": 100.0,
                "p50_ns": 500,
                "p90_ns": 900,
                "p99_ns": 990,
                "p999_ns": 999
            },
            "transport": "unix-socket"
        }"#;
        std::fs::write(&path, json).unwrap();
        let result = BenchmarkReport::load(&path);
        match result {
            Err(ReportError::InvalidFieldValue { field, .. }) => {
                assert_eq!(field, "throughput_ops_per_sec");
            }
            other => panic!("expected InvalidFieldValue, got {other:?}"),
        }
    }

    /// REGRESSION: `BenchmarkReport::load` rejects negative
    /// `latency.mean_ns`.  Mean of non-negative samples must be
    /// non-negative; a negative value indicates corruption.
    #[test]
    fn load_rejects_negative_mean_ns() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("neg_mean.json");
        let json = r#"{
            "identifier": "knomosis-bench/v1",
            "harness_version": "0.2.1",
            "protocol_version": 1,
            "fixture_config": {
                "seed": 1,
                "actor_count": 10,
                "transfer_count": 100,
                "resource_id": 0,
                "transfer_amount": 1,
                "deployment_id_hex": "00"
            },
            "worker_count": 64,
            "warmup_requests": 1000,
            "elapsed_ns": 1000000000,
            "measured_requests": 9000,
            "throughput_ops_per_sec": 1000.0,
            "latency": {
                "count": 9000,
                "min_ns": 100,
                "max_ns": 1000000,
                "mean_ns": -500.0,
                "stddev_ns": 100.0,
                "p50_ns": 500,
                "p90_ns": 900,
                "p99_ns": 990,
                "p999_ns": 999
            },
            "transport": "unix-socket"
        }"#;
        std::fs::write(&path, json).unwrap();
        let result = BenchmarkReport::load(&path);
        match result {
            Err(ReportError::InvalidFieldValue { field, .. }) => {
                assert_eq!(field, "latency.mean_ns");
            }
            other => panic!("expected InvalidFieldValue, got {other:?}"),
        }
    }

    /// REGRESSION: `BenchmarkReport::save` validates f64 fields
    /// upfront BEFORE serialising.  Without this, `serde_json`
    /// silently converts `f64::INFINITY` / `f64::NAN` to the JSON
    /// literal `null`, producing a file that fails to re-load —
    /// silent data corruption.  Validating upfront converts the
    /// silent path into a typed `InvalidFieldValue` error at save
    /// time, before any disk write occurs.
    #[test]
    fn save_rejects_infinity_throughput() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("inf_save.json");
        let mut report = make_report(1.0, 100, 200, 300);
        report.throughput_ops_per_sec = f64::INFINITY;
        let result = report.save(&path);
        match result {
            Err(ReportError::InvalidFieldValue { field, .. }) => {
                assert_eq!(field, "throughput_ops_per_sec");
            }
            other => panic!("expected InvalidFieldValue, got {other:?}"),
        }
        // No partial-state artifacts: neither the target nor the
        // .tmp sibling should exist (validation fails before any
        // disk write).
        assert!(!path.exists());
        let tmp_path = path.with_file_name("inf_save.json.tmp");
        assert!(!tmp_path.exists());
    }

    /// REGRESSION: `BenchmarkReport::save` rejects NaN f64 fields
    /// (same silent-corruption defense as the infinity case).
    #[test]
    fn save_rejects_nan_stddev() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("nan_save.json");
        let mut report = make_report(1000.0, 100, 200, 300);
        report.latency.stddev_ns = f64::NAN;
        let result = report.save(&path);
        match result {
            Err(ReportError::InvalidFieldValue { field, .. }) => {
                assert_eq!(field, "latency.stddev_ns");
            }
            other => panic!("expected InvalidFieldValue, got {other:?}"),
        }
        assert!(!path.exists());
    }

    /// REGRESSION: `BenchmarkReport::save` rejects negative f64
    /// fields (mean_ns / stddev_ns must be non-negative).
    #[test]
    fn save_rejects_negative_mean_ns() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("neg_save.json");
        let mut report = make_report(1000.0, 100, 200, 300);
        report.latency.mean_ns = -1.0;
        let result = report.save(&path);
        match result {
            Err(ReportError::InvalidFieldValue { field, .. }) => {
                assert_eq!(field, "latency.mean_ns");
            }
            other => panic!("expected InvalidFieldValue, got {other:?}"),
        }
        assert!(!path.exists());
    }

    /// `BenchmarkReport::load` rejects negative `latency.stddev_ns`.
    /// Variance is mathematically non-negative; a negative stddev
    /// indicates data corruption.
    #[test]
    fn load_rejects_negative_stddev() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("negstd.json");
        let json = r#"{
            "identifier": "knomosis-bench/v1",
            "harness_version": "0.2.1",
            "protocol_version": 1,
            "fixture_config": {
                "seed": 1,
                "actor_count": 10,
                "transfer_count": 100,
                "resource_id": 0,
                "transfer_amount": 1,
                "deployment_id_hex": "00"
            },
            "worker_count": 64,
            "warmup_requests": 1000,
            "elapsed_ns": 1000000000,
            "measured_requests": 9000,
            "throughput_ops_per_sec": 1000.0,
            "latency": {
                "count": 9000,
                "min_ns": 100,
                "max_ns": 1000000,
                "mean_ns": 500.0,
                "stddev_ns": -50.0,
                "p50_ns": 500,
                "p90_ns": 900,
                "p99_ns": 990,
                "p999_ns": 999
            },
            "transport": "unix-socket"
        }"#;
        std::fs::write(&path, json).unwrap();
        let result = BenchmarkReport::load(&path);
        match result {
            Err(ReportError::InvalidFieldValue { field, .. }) => {
                assert_eq!(field, "latency.stddev_ns");
            }
            other => panic!("expected InvalidFieldValue, got {other:?}"),
        }
    }

    /// `compare_against_baseline` with a non-finite threshold
    /// returns `WithinTolerance` rather than producing NaN-laden
    /// drift values.  Defence-in-depth for library callers that
    /// bypass the CLI's NaN validation.
    #[test]
    fn compare_with_nan_threshold_returns_within_tolerance() {
        let baseline = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let candidate = make_report(1.0, 999_999_999, 999_999_999, 999_999_999);
        let v = compare_against_baseline(&baseline, &candidate, f64::NAN);
        assert!(matches!(v, RegressionVerdict::WithinTolerance));
    }

    /// `compare_against_baseline` with +∞ threshold also returns
    /// `WithinTolerance` (any candidate is within ∞ × baseline).
    #[test]
    fn compare_with_inf_threshold_returns_within_tolerance() {
        let baseline = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let candidate = make_report(1.0, 999_999_999, 999_999_999, 999_999_999);
        let v = compare_against_baseline(&baseline, &candidate, f64::INFINITY);
        assert!(matches!(v, RegressionVerdict::WithinTolerance));
    }

    /// `to_human_summary` includes the identifier and key metrics.
    #[test]
    fn human_summary_contains_key_fields() {
        let report = make_report(10_000.0, 100_000, 500_000, 1_000_000);
        let s = report.to_human_summary();
        assert!(s.contains("knomosis-bench"));
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
