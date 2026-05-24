// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Shared CLI and logging helpers for the Knomosis Rust host workspace.
//!
//! This crate centralises a small, stable set of helpers that every
//! binary in the `runtime/` workspace depends on:
//!
//!   * [`logging::init`] — initialise `tracing` with a uniform
//!     human-readable line-oriented format whose filter directive is
//!     read from the `RUST_LOG` environment variable (structured-JSON
//!     emission is intentionally not implemented at the RH-H landing;
//!     see [`logging`]'s module docstring for the rationale).
//!   * [`exit::OperatorExitCode`] — the canonical exit-code discipline
//!     used by every Knomosis Rust binary.
//!   * [`paths`] — workspace-relative path utilities (fixture corpus
//!     locations, default Unix-socket paths, etc.).
//!
//! These helpers are intentionally minimal: each adds shared, stable
//! infrastructure consumed by the downstream binaries (RH-A through
//! RH-G).  See `docs/planning/rust_host_runtime_plan.md` §2.2 for the
//! workspace layout.

#![doc(html_root_url = "https://docs.rs/knomosis-cli-common/0.1.0")]

pub mod exit;
pub mod logging;
pub mod paths;

/// The crate's published version (auto-populated by `cargo` from
/// `Cargo.toml`).
///
/// Binaries fan this out via their `--version` flag.  Centralising
/// the constant means every Knomosis binary reports the same workspace
/// version when invoked.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
