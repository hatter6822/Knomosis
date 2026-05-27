// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Structured-logging initialisation for the Knomosis Rust binaries.
//!
//! Wraps `tracing-subscriber` so every binary inherits the same log
//! discipline:
//!
//!   * Filter directive read from the `RUST_LOG` environment
//!     variable, falling back to the level supplied at initialisation
//!     time when `RUST_LOG` is unset.
//!   * Human-readable single-line records with target / span-close
//!     metadata.
//!   * [`init`] is idempotent — calling it twice from the same
//!     process is a no-op rather than a panic.  The plan §7 risk
//!     register notes that misconfigured loggers are an operational
//!     pain-point, so the API tolerates a redundant call rather than
//!     crashing.
//!
//! Structured-JSON emission is intentionally **not** implemented in
//! the RH-H skeleton.  Adding it requires turning on the
//! `tracing-subscriber/json` feature plus a `serde_json` dependency
//! and changing the formatter's type; that's an operator-grade
//! follow-up scoped to whichever downstream WU first needs JSON
//! output (typically `knomosis-l1-ingest` or `knomosis-faultproof-observer`).

use std::sync::OnceLock;

use tracing::Level;
use tracing_subscriber::fmt::format::FmtSpan;
use tracing_subscriber::EnvFilter;

/// Memoised initialisation flag.  Set on the first successful
/// `init()`; subsequent calls return early.
static INITIALISED: OnceLock<()> = OnceLock::new();

/// Logger-initialisation errors surfaced to the caller.
///
/// `init()` returns `Err` only when the `RUST_LOG` environment
/// variable contains a malformed filter directive that
/// `EnvFilter::try_new` rejects.  Every other failure (e.g.
/// "logger already installed") is converted to a no-op rather than
/// an error.
#[derive(Debug, thiserror::Error)]
pub enum LoggingError {
    /// The `RUST_LOG` environment variable contained a directive
    /// the `tracing-subscriber` parser could not parse.
    #[error("invalid RUST_LOG directive: {0}")]
    InvalidFilter(#[from] tracing_subscriber::filter::ParseError),
}

/// Initialise the global tracing subscriber.
///
/// `default_level` is used when the `RUST_LOG` environment variable
/// is unset.  Standard binaries pass [`tracing::Level::INFO`]; the
/// audit binaries pass [`tracing::Level::WARN`].
///
/// Idempotent: returns `Ok(())` immediately on the second and
/// subsequent calls within a process.  The first call's
/// configuration is the one that takes effect.
pub fn init(default_level: Level) -> Result<(), LoggingError> {
    if INITIALISED.get().is_some() {
        return Ok(());
    }

    let filter = match std::env::var("RUST_LOG") {
        Ok(spec) => EnvFilter::try_new(spec)?,
        Err(_) => EnvFilter::new(default_level.to_string()),
    };

    // `try_init` returns `Err` only if a subscriber is already
    // installed; we collapse that to success below to preserve
    // idempotency under concurrent first-call races.
    let init_result = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_span_events(FmtSpan::CLOSE)
        .with_target(true)
        .try_init();

    if init_result.is_ok() {
        let _ = INITIALISED.set(());
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{init, LoggingError};
    use tracing::Level;
    use tracing_subscriber::EnvFilter;

    /// First-call init succeeds.  Second-call init is a no-op (does
    /// not panic, does not error).
    #[test]
    fn init_is_idempotent() {
        // Both calls must succeed.  The second is observably a no-op
        // because the global subscriber is already installed.
        let first = init(Level::INFO);
        let second = init(Level::INFO);
        assert!(first.is_ok());
        assert!(second.is_ok());
    }

    /// `LoggingError::InvalidFilter` round-trips through `From` and
    /// produces a non-empty `Display`.
    ///
    /// The test forces a parse failure via a deterministically-
    /// invalid filter string ("=" with no target — rejected by the
    /// `EnvFilter` parser).  Compared to the previous implementation
    /// that used a conditional `if let Err = parse(...)`, this form
    /// asserts the error path actually fires.
    #[test]
    fn invalid_filter_error_wraps_and_displays() {
        // Construct a real `EnvFilter::try_new` parse failure.  The
        // unwrap on `expect_err` is the load-bearing assertion: if
        // `tracing-subscriber` ever accepts this string, the test
        // fails loudly rather than silently skipping the error path
        // (the previous version's failure mode).
        let parse_err =
            EnvFilter::try_new("=").expect_err("EnvFilter must reject `=` as a filter directive");
        let wrapped: LoggingError = parse_err.into();
        let displayed = wrapped.to_string();
        assert!(displayed.starts_with("invalid RUST_LOG directive: "));
        assert!(displayed.len() > "invalid RUST_LOG directive: ".len());
    }

    /// `LoggingError` is `Send + Sync` (required for cross-thread
    /// use; the audit binaries spawn worker threads).
    #[test]
    fn logging_error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<LoggingError>();
    }
}
