// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Structured-logging setup for the gateway binary (`--log-format`).
//!
//! `knomosis-cli-common::logging` installs a **text-only** subscriber and
//! explicitly defers JSON output "to whichever downstream WU first needs it".
//! The gateway is that WU — its `--log-format` defaults to `json` (the format
//! the G4.3 log-based metrics surface + a log aggregator consume) — so it
//! installs its **own** subscriber here, supporting both `json` and `text`.
//!
//! The filter follows the same `RUST_LOG`-or-`default_level` convention as the
//! shared initialiser, so operator overrides behave identically; only the
//! formatter differs.

use tracing::Level;
use tracing_subscriber::fmt::format::FmtSpan;
use tracing_subscriber::EnvFilter;

use crate::config::LogFormat;

/// Install the global tracing subscriber in the configured `format`.
///
/// `default_level` is used when `RUST_LOG` is unset (the gateway passes
/// [`tracing::Level::INFO`]).  Installing a subscriber twice in one process is
/// a no-op (the second `try_init` fails and is ignored), mirroring the
/// idempotency of the shared initialiser.
///
/// # Errors
///
/// Returns the `tracing-subscriber` parse error if `RUST_LOG` is set to a
/// directive the `EnvFilter` parser rejects (an operator-actionable misconfig).
pub fn init(
    format: LogFormat,
    default_level: Level,
) -> Result<(), tracing_subscriber::filter::ParseError> {
    let filter = match std::env::var("RUST_LOG") {
        Ok(spec) => EnvFilter::try_new(spec)?,
        Err(_) => EnvFilter::new(default_level.to_string()),
    };
    let builder = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_span_events(FmtSpan::CLOSE)
        .with_target(true);
    // `try_init` returns `Err` only if a subscriber is already installed; that
    // is collapsed to success (idempotent under a double-init / test races).
    match format {
        LogFormat::Json => {
            let _ = builder.json().try_init();
        }
        LogFormat::Text => {
            let _ = builder.try_init();
        }
    }
    Ok(())
}
