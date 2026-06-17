// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! `knomosis-gateway` binary entry point.
//!
//! See `runtime/knomosis-gateway/src/lib.rs` for the crate
//! architecture and `runtime/knomosis-gateway/src/config.rs` for the
//! CLI surface.
//!
//! ## Exit codes (the shared `OperatorExitCode` discipline)
//!
//!   * `0` — clean exit (`--help` / `--version`, or the accept loop
//!     ending).
//!   * `2` — operator-actionable failure: a CLI parse error, or the
//!     listen socket could not be bound.

use std::process::ExitCode;

use knomosis_cli_common::exit::OperatorExitCode;
use knomosis_gateway::config::{Config, ConfigError, HELP_TEXT};
use knomosis_gateway::{logging, GATEWAY_IDENTIFIER, VERSION};
use tracing::Level;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let config = match Config::parse(&args) {
        Ok(c) => c,
        Err(ConfigError::HelpRequested) => {
            print!("{HELP_TEXT}");
            return exit(OperatorExitCode::Success);
        }
        Err(ConfigError::VersionRequested) => {
            println!("{GATEWAY_IDENTIFIER} (version {VERSION})");
            return exit(OperatorExitCode::Success);
        }
        Err(e) => {
            eprintln!("knomosis-gateway: error parsing arguments: {e}");
            eprintln!("Run with --help for usage.");
            return exit(OperatorExitCode::OperatorAction);
        }
    };

    if let Err(e) = logging::init(config.log_format, Level::INFO) {
        eprintln!("knomosis-gateway: logging init failed: {e}");
        return exit(OperatorExitCode::GeneralFailure);
    }

    match knomosis_gateway::http::serve(&config) {
        Ok(()) => exit(OperatorExitCode::Success),
        Err(e) => {
            tracing::error!(error = %e, "gateway server terminated with error");
            exit(OperatorExitCode::OperatorAction)
        }
    }
}

/// Convert an [`OperatorExitCode`] into a process [`ExitCode`].
fn exit(code: OperatorExitCode) -> ExitCode {
    // `OperatorExitCode` is `#[repr(u8)]`, so this enum-to-`u8` cast is
    // exact — no truncation or sign loss (unlike `as_i32() as u8`,
    // which the sibling binaries silence with clippy `allow`s).
    ExitCode::from(code as u8)
}
