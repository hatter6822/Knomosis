// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Latency histogram + percentile reporter.
//!
//! ## Why store all samples
//!
//! For `transfer_count = 10 000` samples × 8 bytes per `u64` = 80 KiB
//! per histogram.  Trivial; no need for a streaming approximate
//! percentile algorithm (HDR-histogram, t-digest) at this scale.
//! When the benchmark scales to millions of samples, the storage
//! cost would warrant a streaming variant — that's a follow-up.
//!
//! ## Percentile definition
//!
//! For a sorted Vec `s[0..N]`, given `num / den` ∈ `[0, ∞)`:
//!
//!   * `p_{num/den}` = `s[max(ceil(num * N / den) - 1, 0)]` for
//!     `num > 0`.
//!   * `p_0` = `s[0]` (special case so the formula doesn't
//!     underflow).
//!   * `p_{num/den}` for `num/den > 1.0` saturates the rank to
//!     `s[N - 1]`.
//!   * The empty-input case returns `0` (mirrors the
//!     `LatencySummary::default()` shape).
//!
//! Matches the "Nearest Rank" method (NIST 1.3.5.6.10).  Equivalent
//! to "the smallest observed value that exceeds X% of the samples,"
//! the convention Criterion / HdrHistogram use.
//!
//! ## Mean / stddev
//!
//! Computed via the [Welford online algorithm][welford-link] for
//! numerical stability.  We accumulate `(n, mean, M2)` over each
//! sample, where:
//!
//!   ```text
//!   n          = current count
//!   mean       = current mean (running)
//!   M2         = sum of squared differences from current mean
//!   variance   = M2 / n  (population variance)
//!   stddev     = sqrt(variance)
//!   ```
//!
//! `mean` and `M2` accumulate in f64 throughout.  At the bench's
//! scale (`N` in the thousands; latency means in the tens of
//! microseconds), `mean` stays well below `2^53` (the f64 integer-
//! representation ceiling), so the running mean is exactly
//! representable.  `M2` may grow but the Welford rule's
//! `delta * delta2` formulation avoids the catastrophic
//! cancellation a naive "sum-of-squares minus square-of-sums"
//! formula exhibits.
//!
//! [welford-link]: https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance#Welford%27s_online_algorithm

use std::time::Duration;

/// A growing collection of `u64` latency samples (nanoseconds).
/// Insertion is O(1); percentile / mean / stddev reports are
/// computed lazily in O(N log N).
#[derive(Clone, Debug, Default)]
pub struct Histogram {
    samples: Vec<u64>,
}

impl Histogram {
    /// Construct an empty histogram.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Construct a histogram with pre-allocated capacity.  Avoids
    /// re-allocation in the hot path of the runner loop.
    #[must_use]
    pub fn with_capacity(cap: usize) -> Self {
        Self {
            samples: Vec::with_capacity(cap),
        }
    }

    /// Record one latency sample in nanoseconds.  Saturating: if
    /// the supplied `Duration` exceeds `u64::MAX` nanoseconds
    /// (~584 years), saturates to `u64::MAX`.
    pub fn record(&mut self, latency: Duration) {
        let ns = u64::try_from(latency.as_nanos()).unwrap_or(u64::MAX);
        self.samples.push(ns);
    }

    /// Record one latency sample directly as nanoseconds.
    pub fn record_ns(&mut self, ns: u64) {
        self.samples.push(ns);
    }

    /// Merge another histogram into this one.  Used to combine
    /// per-worker-thread histograms into a single report.
    pub fn merge(&mut self, other: &Histogram) {
        self.samples.extend_from_slice(&other.samples);
    }

    /// Number of recorded samples.
    #[must_use]
    pub fn len(&self) -> usize {
        self.samples.len()
    }

    /// True iff no samples have been recorded.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    /// Borrow the underlying samples (in insertion order).  Used
    /// by tests; production callers go through `summarise`.
    #[must_use]
    pub fn samples(&self) -> &[u64] {
        &self.samples
    }

    /// Compute the percentile / mean / stddev summary of this
    /// histogram.  Sorts the underlying Vec (in-place; mutates
    /// `self` but is conceptually idempotent — repeated calls
    /// produce identical output).
    ///
    /// Returns the default empty summary if no samples were
    /// recorded.
    pub fn summarise(&mut self) -> LatencySummary {
        if self.samples.is_empty() {
            return LatencySummary::default();
        }
        self.samples.sort_unstable();
        let n = self.samples.len();

        // Percentiles via the "nearest rank" method.
        let p50_ns = percentile_nearest_rank(&self.samples, 50, 100);
        let p90_ns = percentile_nearest_rank(&self.samples, 90, 100);
        let p99_ns = percentile_nearest_rank(&self.samples, 99, 100);
        let p999_ns = percentile_nearest_rank(&self.samples, 999, 1000);
        let min_ns = self.samples[0];
        let max_ns = self.samples[n - 1];

        // Mean + variance via Welford.  Accumulating in f64 from
        // the start avoids u128 → f64 precision loss on the final
        // conversion.
        let mut count: f64 = 0.0;
        let mut mean: f64 = 0.0;
        let mut m2: f64 = 0.0;
        for &x_ns in &self.samples {
            let x = x_ns as f64;
            count += 1.0;
            let delta = x - mean;
            mean += delta / count;
            let delta2 = x - mean;
            m2 += delta * delta2;
        }
        let variance = if count > 1.0 { m2 / count } else { 0.0 };
        let stddev = variance.sqrt();

        LatencySummary {
            count: n,
            min_ns,
            max_ns,
            mean_ns: mean,
            stddev_ns: stddev,
            p50_ns,
            p90_ns,
            p99_ns,
            p999_ns,
        }
    }
}

/// Compute the `numerator / denominator`-th percentile via the
/// nearest-rank method.  For a sorted array `s[0..N]`:
///
///   `p_{numerator/denominator} = s[ceil(numerator * N / denominator) - 1]`
///
/// for non-zero numerator; `s[0]` for zero.  Saturates the index
/// to `N - 1` if the computed rank exceeds the array length.
///
/// # Panics
///
/// Debug-builds panic if `denominator == 0`.  In release builds the
/// caller's contract (callers must pass a non-zero denominator)
/// would result in integer division-by-zero behaviour; the
/// debug-assertion surfaces the contract violation at test time.
/// Production callers in this crate pass literal `100` and `1000`.
fn percentile_nearest_rank(sorted: &[u64], numerator: u64, denominator: u64) -> u64 {
    debug_assert!(
        denominator > 0,
        "percentile_nearest_rank: denominator must be non-zero"
    );
    let n = sorted.len();
    if n == 0 {
        return 0;
    }
    if numerator == 0 {
        return sorted[0];
    }
    // Compute `ceil(numerator * N / denominator) - 1` in u128 to
    // avoid u64 overflow.
    let n_u128 = n as u128;
    let num_u128 = u128::from(numerator);
    let den_u128 = u128::from(denominator);
    // ceil(a / b) = (a + b - 1) / b
    let rank = (num_u128 * n_u128 + den_u128 - 1) / den_u128;
    let idx = rank.saturating_sub(1);
    let idx_usize = if idx >= n_u128 { n - 1 } else { idx as usize };
    sorted[idx_usize]
}

/// Summary statistics for a latency histogram.  All durations are
/// in nanoseconds.  Floating-point counts (mean, stddev) preserve
/// the post-Welford precision.
#[derive(Clone, Copy, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct LatencySummary {
    /// Number of samples summarised.
    pub count: usize,
    /// Minimum observed latency.
    pub min_ns: u64,
    /// Maximum observed latency.
    pub max_ns: u64,
    /// Arithmetic mean.  Computed via the Welford one-pass
    /// algorithm.
    pub mean_ns: f64,
    /// Standard deviation.  Computed via Welford.
    pub stddev_ns: f64,
    /// 50th-percentile latency.
    pub p50_ns: u64,
    /// 90th-percentile latency.
    pub p90_ns: u64,
    /// 99th-percentile latency.
    pub p99_ns: u64,
    /// 99.9th-percentile latency.
    pub p999_ns: u64,
}

impl LatencySummary {
    /// Return the p50 latency as a `Duration`.
    #[must_use]
    pub fn p50(&self) -> Duration {
        Duration::from_nanos(self.p50_ns)
    }

    /// Return the p99 latency as a `Duration`.
    #[must_use]
    pub fn p99(&self) -> Duration {
        Duration::from_nanos(self.p99_ns)
    }

    /// Return the p999 latency as a `Duration`.
    #[must_use]
    pub fn p999(&self) -> Duration {
        Duration::from_nanos(self.p999_ns)
    }

    /// Return the min latency as a `Duration`.
    #[must_use]
    pub fn min(&self) -> Duration {
        Duration::from_nanos(self.min_ns)
    }

    /// Return the max latency as a `Duration`.
    #[must_use]
    pub fn max(&self) -> Duration {
        Duration::from_nanos(self.max_ns)
    }
}

#[cfg(test)]
mod tests {
    use super::{percentile_nearest_rank, Histogram, LatencySummary};
    use std::time::Duration;

    /// `Histogram::new` is empty.
    #[test]
    fn empty_histogram() {
        let h = Histogram::new();
        assert!(h.is_empty());
        assert_eq!(h.len(), 0);
    }

    /// Empty histogram summarises to an all-zero default.
    #[test]
    fn empty_summary() {
        let mut h = Histogram::new();
        let s = h.summarise();
        assert_eq!(s, LatencySummary::default());
    }

    /// Single-sample summary has all percentiles equal.
    #[test]
    fn single_sample() {
        let mut h = Histogram::new();
        h.record(Duration::from_nanos(42));
        let s = h.summarise();
        assert_eq!(s.count, 1);
        assert_eq!(s.min_ns, 42);
        assert_eq!(s.max_ns, 42);
        assert_eq!(s.p50_ns, 42);
        assert_eq!(s.p90_ns, 42);
        assert_eq!(s.p99_ns, 42);
        assert_eq!(s.p999_ns, 42);
        assert!((s.mean_ns - 42.0).abs() < 1e-9);
        assert!(s.stddev_ns.abs() < 1e-9);
    }

    /// Known-value percentile check: values 1..=100.
    #[test]
    fn percentiles_known_values() {
        let mut h = Histogram::new();
        for i in 1..=100u64 {
            h.record_ns(i);
        }
        let s = h.summarise();
        assert_eq!(s.count, 100);
        assert_eq!(s.min_ns, 1);
        assert_eq!(s.max_ns, 100);
        // p50 of 100 values: ceil(50 * 100 / 100) - 1 = 49,
        // i.e., sorted[49] = 50.
        assert_eq!(s.p50_ns, 50);
        // p90: ceil(90) - 1 = 89, sorted[89] = 90.
        assert_eq!(s.p90_ns, 90);
        // p99: ceil(99) - 1 = 98, sorted[98] = 99.
        assert_eq!(s.p99_ns, 99);
        // p999: ceil(999 * 100 / 1000) - 1 = 99, sorted[99] = 100.
        assert_eq!(s.p999_ns, 100);
        // Mean of 1..=100 is 50.5.
        assert!((s.mean_ns - 50.5).abs() < 1e-6);
    }

    /// Unsorted insertion still produces sorted-derived percentiles.
    #[test]
    fn unsorted_insertion() {
        let mut h = Histogram::new();
        h.record_ns(5);
        h.record_ns(1);
        h.record_ns(3);
        h.record_ns(2);
        h.record_ns(4);
        let s = h.summarise();
        assert_eq!(s.min_ns, 1);
        assert_eq!(s.max_ns, 5);
        // p50 of 5 values: ceil(50 * 5 / 100) - 1 = 2, sorted[2] = 3.
        assert_eq!(s.p50_ns, 3);
    }

    /// `summarise` is idempotent: calling twice yields the same
    /// result.
    #[test]
    fn summarise_idempotent() {
        let mut h = Histogram::new();
        for i in 0..10u64 {
            h.record_ns(i * 10);
        }
        let s1 = h.summarise();
        let s2 = h.summarise();
        assert_eq!(s1, s2);
    }

    /// `merge` adds samples from another histogram.
    #[test]
    fn merge_combines_histograms() {
        let mut h1 = Histogram::new();
        h1.record_ns(1);
        h1.record_ns(2);
        let mut h2 = Histogram::new();
        h2.record_ns(3);
        h2.record_ns(4);
        h1.merge(&h2);
        assert_eq!(h1.len(), 4);
        let s = h1.summarise();
        assert_eq!(s.count, 4);
        assert_eq!(s.min_ns, 1);
        assert_eq!(s.max_ns, 4);
    }

    /// `percentile_nearest_rank` for empty input.
    #[test]
    fn percentile_empty() {
        assert_eq!(percentile_nearest_rank(&[], 50, 100), 0);
    }

    /// `percentile_nearest_rank` for k=0 returns first element.
    #[test]
    fn percentile_zero() {
        let s = [10u64, 20, 30];
        assert_eq!(percentile_nearest_rank(&s, 0, 100), 10);
    }

    /// `percentile_nearest_rank` for k > 100 saturates to last
    /// element.
    #[test]
    fn percentile_oversaturation() {
        let s = [10u64, 20, 30];
        assert_eq!(percentile_nearest_rank(&s, 200, 100), 30);
    }

    /// `LatencySummary` accessors return matching `Duration`s.
    #[test]
    fn summary_accessors() {
        let s = LatencySummary {
            count: 1,
            min_ns: 1_000,
            max_ns: 2_000,
            mean_ns: 1_500.0,
            stddev_ns: 500.0,
            p50_ns: 1_500,
            p90_ns: 1_800,
            p99_ns: 1_950,
            p999_ns: 1_990,
        };
        assert_eq!(s.p50(), Duration::from_nanos(1_500));
        assert_eq!(s.p99(), Duration::from_nanos(1_950));
        assert_eq!(s.p999(), Duration::from_nanos(1_990));
        assert_eq!(s.min(), Duration::from_nanos(1_000));
        assert_eq!(s.max(), Duration::from_nanos(2_000));
    }

    /// JSON round-trip preserves every field byte-for-byte.
    #[test]
    fn summary_json_roundtrip() {
        let s = LatencySummary {
            count: 100,
            min_ns: 10,
            max_ns: 1_000,
            mean_ns: 500.5,
            stddev_ns: 250.25,
            p50_ns: 500,
            p90_ns: 900,
            p99_ns: 990,
            p999_ns: 999,
        };
        let json = serde_json::to_string(&s).unwrap();
        let decoded: LatencySummary = serde_json::from_str(&json).unwrap();
        assert_eq!(s, decoded);
    }

    /// Property-style check: stddev is non-negative.
    #[test]
    fn stddev_nonnegative() {
        let mut h = Histogram::new();
        // Wide-spread sample set.
        for i in 0..100u64 {
            h.record_ns(i * i);
        }
        let s = h.summarise();
        assert!(s.stddev_ns >= 0.0);
    }

    /// Constant samples produce zero stddev.
    #[test]
    fn constant_samples_zero_stddev() {
        let mut h = Histogram::new();
        for _ in 0..10 {
            h.record_ns(7);
        }
        let s = h.summarise();
        assert!(s.stddev_ns.abs() < 1e-9);
    }

    /// Two-sample stddev matches the textbook population formula.
    /// For samples `[x, y]`, mean = `(x + y) / 2`, variance =
    /// `((x - mean)² + (y - mean)²) / 2`.  Using x=10, y=20:
    /// mean=15, variance=25, stddev=5.
    #[test]
    fn two_sample_stddev() {
        let mut h = Histogram::new();
        h.record_ns(10);
        h.record_ns(20);
        let s = h.summarise();
        assert!((s.mean_ns - 15.0).abs() < 1e-9);
        assert!((s.stddev_ns - 5.0).abs() < 1e-9);
    }

    /// `with_capacity` pre-allocates without recording samples.
    #[test]
    fn with_capacity_empty() {
        let h = Histogram::with_capacity(1000);
        assert!(h.is_empty());
        assert_eq!(h.len(), 0);
        assert!(h.samples().is_empty());
    }
}
