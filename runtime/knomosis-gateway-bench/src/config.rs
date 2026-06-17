// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! The benchmark CLI configuration.  Hand-rolled parser (no `clap`), mirroring
//! the workspace's minimal-dependency posture and the sibling crates' style.

use std::path::PathBuf;

use crate::{
    DEFAULT_ACTOR_COUNT, DEFAULT_HANDLER_THREADS, DEFAULT_REGRESSION_THRESHOLD,
    DEFAULT_REQUEST_COUNT, DEFAULT_RESOURCE_COUNT, DEFAULT_WARMUP_REQUESTS, DEFAULT_WORKER_COUNT,
};

/// `--help` text.
pub const HELP_TEXT: &str = "\
knomosis-gateway-bench — read-path throughput / latency benchmark for knomosis-gateway

USAGE:
    knomosis-gateway-bench [OPTIONS]

OPTIONS:
    --actors <N>          Seeded actors (each with --resources balances) [default: 1000]
    --resources <N>       Resources seeded per actor [default: 2]
    --requests <N>        Measured requests (after warmup) [default: 10000]
    --warmup <N>          Warmup requests (latency discarded) [default: 1000]
    --workers <N>         Concurrent client worker threads [default: 32]
    --handler-threads <N> Gateway handler-pool threads (server side) [default: 16]
    --seed <N>            Deterministic fixture seed [default: 0]
    --report <PATH>       Write the JSON report to PATH (for --baseline)
    --baseline <PATH>     Compare against a prior report; exit 1 on a regression
    --threshold <F>       Regression threshold (fraction, e.g. 0.10) [default: 0.10]
    -h, --help            Print this help and exit
    -V, --version         Print version and exit

NOTE: throughput numbers vary by machine — this is a MANUAL tool, not a CI
gate.  --baseline only compares two runs taken on the SAME host + workload.
";

/// Validated benchmark configuration.
#[derive(Clone, Debug, PartialEq)]
pub struct BenchConfig {
    /// Seeded actor count.
    pub actors: usize,
    /// Resources per actor.
    pub resources: usize,
    /// Measured request count.
    pub requests: usize,
    /// Warmup request count.
    pub warmup: usize,
    /// Concurrent client workers.
    pub workers: usize,
    /// Gateway handler-pool threads.
    pub handler_threads: usize,
    /// Deterministic fixture seed.
    pub seed: u64,
    /// JSON report output path, if any.
    pub report: Option<PathBuf>,
    /// Baseline report to compare against, if any.
    pub baseline: Option<PathBuf>,
    /// Regression threshold (fraction).
    pub threshold: f64,
}

impl Default for BenchConfig {
    fn default() -> Self {
        Self {
            actors: DEFAULT_ACTOR_COUNT,
            resources: DEFAULT_RESOURCE_COUNT,
            requests: DEFAULT_REQUEST_COUNT,
            warmup: DEFAULT_WARMUP_REQUESTS,
            workers: DEFAULT_WORKER_COUNT,
            handler_threads: DEFAULT_HANDLER_THREADS,
            seed: 0,
            report: None,
            baseline: None,
            threshold: DEFAULT_REGRESSION_THRESHOLD,
        }
    }
}

/// Errors parsing the benchmark CLI.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// `-h` / `--help` requested (not a failure).
    #[error("help requested")]
    HelpRequested,
    /// `-V` / `--version` requested.
    #[error("version requested")]
    VersionRequested,
    /// A flag that requires a value was given none.
    #[error("flag {0} requires a value")]
    MissingValue(String),
    /// A flag value failed to parse / validate.
    #[error("invalid value for {flag}: {value:?} ({reason})")]
    InvalidValue {
        /// The offending flag.
        flag: String,
        /// The offending value.
        value: String,
        /// The diagnostic.
        reason: String,
    },
    /// An unrecognised argument.
    #[error("unknown argument: {0:?}")]
    UnknownArgument(String),
}

impl BenchConfig {
    /// Parse from the process argv (`args[0]` is the program name).
    ///
    /// # Errors
    ///
    /// [`ConfigError::HelpRequested`] / [`ConfigError::VersionRequested`] for
    /// those flags, else a parse / validation error.
    pub fn parse(args: &[String]) -> Result<Self, ConfigError> {
        let mut cfg = Self::default();
        let mut i = 1;
        while let Some(arg) = args.get(i) {
            match arg.as_str() {
                "-h" | "--help" => return Err(ConfigError::HelpRequested),
                "-V" | "--version" => return Err(ConfigError::VersionRequested),
                "--actors" => cfg.actors = parse_usize(args, &mut i, "--actors")?,
                "--resources" => cfg.resources = parse_usize(args, &mut i, "--resources")?,
                "--requests" => cfg.requests = parse_usize(args, &mut i, "--requests")?,
                "--warmup" => cfg.warmup = parse_usize(args, &mut i, "--warmup")?,
                "--workers" => cfg.workers = parse_usize(args, &mut i, "--workers")?,
                "--handler-threads" => {
                    cfg.handler_threads = parse_usize(args, &mut i, "--handler-threads")?;
                }
                "--seed" => cfg.seed = parse_u64(args, &mut i, "--seed")?,
                "--report" => cfg.report = Some(PathBuf::from(take(args, &mut i, "--report")?)),
                "--baseline" => {
                    cfg.baseline = Some(PathBuf::from(take(args, &mut i, "--baseline")?));
                }
                "--threshold" => cfg.threshold = parse_threshold(args, &mut i)?,
                other => return Err(ConfigError::UnknownArgument(other.to_string())),
            }
            i += 1;
        }
        cfg.validate()?;
        Ok(cfg)
    }

    /// Validate the resolved configuration (non-zero counts, sane threshold).
    fn validate(&self) -> Result<(), ConfigError> {
        for (value, flag) in [
            (self.actors, "--actors"),
            (self.resources, "--resources"),
            (self.requests, "--requests"),
            (self.workers, "--workers"),
            (self.handler_threads, "--handler-threads"),
        ] {
            if value == 0 {
                return Err(ConfigError::InvalidValue {
                    flag: flag.to_string(),
                    value: "0".to_string(),
                    reason: "must be at least 1".to_string(),
                });
            }
        }
        if !(self.threshold.is_finite() && self.threshold >= 0.0 && self.threshold < 1.0) {
            return Err(ConfigError::InvalidValue {
                flag: "--threshold".to_string(),
                value: self.threshold.to_string(),
                reason: "must be in [0.0, 1.0)".to_string(),
            });
        }
        Ok(())
    }
}

/// Take the value following the flag at `*i`, advancing `*i` past it.
fn take(args: &[String], i: &mut usize, flag: &str) -> Result<String, ConfigError> {
    let value = args
        .get(*i + 1)
        .ok_or_else(|| ConfigError::MissingValue(flag.to_string()))?;
    *i += 1;
    Ok(value.clone())
}

/// Parse the `usize`-valued flag at `*i`.
fn parse_usize(args: &[String], i: &mut usize, flag: &str) -> Result<usize, ConfigError> {
    let raw = take(args, i, flag)?;
    raw.parse::<usize>().map_err(|e| ConfigError::InvalidValue {
        flag: flag.to_string(),
        value: raw,
        reason: e.to_string(),
    })
}

/// Parse the `u64`-valued flag at `*i`.
fn parse_u64(args: &[String], i: &mut usize, flag: &str) -> Result<u64, ConfigError> {
    let raw = take(args, i, flag)?;
    raw.parse::<u64>().map_err(|e| ConfigError::InvalidValue {
        flag: flag.to_string(),
        value: raw,
        reason: e.to_string(),
    })
}

/// Parse the `--threshold` flag (a finite fraction).
fn parse_threshold(args: &[String], i: &mut usize) -> Result<f64, ConfigError> {
    let raw = take(args, i, "--threshold")?;
    raw.parse::<f64>().map_err(|e| ConfigError::InvalidValue {
        flag: "--threshold".to_string(),
        value: raw,
        reason: e.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::{BenchConfig, ConfigError};

    fn argv(extra: &[&str]) -> Vec<String> {
        let mut v = vec!["knomosis-gateway-bench".to_string()];
        v.extend(extra.iter().map(|s| (*s).to_string()));
        v
    }

    #[test]
    fn defaults_when_no_args() {
        assert_eq!(
            BenchConfig::parse(&argv(&[])).unwrap(),
            BenchConfig::default()
        );
    }

    #[test]
    fn flags_override_fields() {
        let cfg = BenchConfig::parse(&argv(&[
            "--actors",
            "10",
            "--resources",
            "3",
            "--requests",
            "500",
            "--warmup",
            "50",
            "--workers",
            "8",
            "--handler-threads",
            "4",
            "--seed",
            "42",
            "--threshold",
            "0.2",
            "--report",
            "/tmp/r.json",
            "--baseline",
            "/tmp/b.json",
        ]))
        .unwrap();
        assert_eq!(cfg.actors, 10);
        assert_eq!(cfg.resources, 3);
        assert_eq!(cfg.requests, 500);
        assert_eq!(cfg.warmup, 50);
        assert_eq!(cfg.workers, 8);
        assert_eq!(cfg.handler_threads, 4);
        assert_eq!(cfg.seed, 42);
        assert!((cfg.threshold - 0.2).abs() < f64::EPSILON);
        assert_eq!(cfg.report.unwrap().to_str().unwrap(), "/tmp/r.json");
        assert_eq!(cfg.baseline.unwrap().to_str().unwrap(), "/tmp/b.json");
    }

    #[test]
    fn help_and_version_sentinels() {
        assert!(matches!(
            BenchConfig::parse(&argv(&["--help"])),
            Err(ConfigError::HelpRequested)
        ));
        assert!(matches!(
            BenchConfig::parse(&argv(&["-V"])),
            Err(ConfigError::VersionRequested)
        ));
    }

    #[test]
    fn rejects_zero_counts_and_bad_threshold_and_unknown() {
        assert!(matches!(
            BenchConfig::parse(&argv(&["--actors", "0"])),
            Err(ConfigError::InvalidValue { .. })
        ));
        assert!(matches!(
            BenchConfig::parse(&argv(&["--threshold", "1.5"])),
            Err(ConfigError::InvalidValue { .. })
        ));
        assert!(matches!(
            BenchConfig::parse(&argv(&["--threshold", "nope"])),
            Err(ConfigError::InvalidValue { .. })
        ));
        assert!(matches!(
            BenchConfig::parse(&argv(&["--nope"])),
            Err(ConfigError::UnknownArgument(_))
        ));
        assert!(matches!(
            BenchConfig::parse(&argv(&["--actors"])),
            Err(ConfigError::MissingValue(_))
        ));
    }
}
