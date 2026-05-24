// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Path helpers shared across the Knomosis Rust binaries.
//!
//! The functions in this module surface a small set of
//! workspace-relative paths the Rust binaries need a common
//! definition of (otherwise each binary re-derives the same path
//! independently, with drift potential).

use std::path::{Path, PathBuf};

/// The default Unix-socket path Knomosis's runtime exposes for local
/// IPC.  Production deployments may override via CLI flag; this
/// constant is the documented default referenced by the network ABI
/// (`docs/abi.md` §10).
pub const DEFAULT_UNIX_SOCKET_PATH: &str = "/var/run/knomosis.sock";

/// The default TCP listen address Knomosis's network adaptor binds to.
/// Local-only by default (loopback) so that a misconfigured
/// deployment does not accidentally expose the host to the
/// internet.  Production operators override via `--listen`.
pub const DEFAULT_LISTEN_ADDR: &str = "127.0.0.1:7654";

/// The default L1 confirmation depth used by the ingest /
/// fault-proof-observer crates.  Documented in the engineering plan
/// §4 RH-B.1 / §4 RH-G.2.
pub const DEFAULT_L1_CONFIRMATION_DEPTH: u32 = 12;

/// Look up the workspace's `runtime/tests/cross-stack/` directory.
///
/// The path is resolved by walking upward from `start` until a
/// directory containing `tests/cross-stack/` is found; the function
/// returns the resolved path or `None` if no ancestor matches
/// within a small bounded search depth.  Callers typically pass
/// `env!("CARGO_MANIFEST_DIR")` as the starting point.
///
/// This is the dev-time entry point used by member crates' test
/// modules to locate the shared fixture directory without hard-coding
/// `../tests/cross-stack/` relative paths.
#[must_use]
pub fn locate_cross_stack_dir(start: &Path) -> Option<PathBuf> {
    let mut current = start.to_path_buf();
    // Bounded ascent: 8 levels is generous for any sane crate layout.
    // The actual answer is always at most two levels up
    // (`runtime/<crate>/` → `runtime/tests/cross-stack/`).
    for _ in 0..8 {
        let candidate = current.join("tests").join("cross-stack");
        if candidate.is_dir() {
            return Some(candidate);
        }
        if !current.pop() {
            break;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{
        locate_cross_stack_dir, DEFAULT_L1_CONFIRMATION_DEPTH, DEFAULT_LISTEN_ADDR,
        DEFAULT_UNIX_SOCKET_PATH,
    };
    use std::fs;

    /// The published constants don't drift silently.  CI catches a
    /// change at review time; the assertion ensures any drift is
    /// surfaced as a test failure not a silent value change.
    #[test]
    fn constants_stable() {
        assert_eq!(DEFAULT_UNIX_SOCKET_PATH, "/var/run/knomosis.sock");
        assert_eq!(DEFAULT_LISTEN_ADDR, "127.0.0.1:7654");
        assert_eq!(DEFAULT_L1_CONFIRMATION_DEPTH, 12);
    }

    /// `locate_cross_stack_dir` returns `Some` when the target
    /// directory exists in an ancestor; `None` otherwise.  The test
    /// fabricates a temp directory tree to keep the test isolated
    /// from the workspace's actual cross-stack directory (which may
    /// or may not exist at test time).
    #[test]
    fn locate_returns_some_when_present() {
        let temp = tempfile::tempdir().expect("create tempdir");
        let nested = temp.path().join("crate-a").join("src");
        let target = temp.path().join("tests").join("cross-stack");
        fs::create_dir_all(&nested).expect("mkdir nested");
        fs::create_dir_all(&target).expect("mkdir target");

        let result = locate_cross_stack_dir(&nested);
        assert_eq!(result.as_deref(), Some(target.as_path()));
    }

    /// Returns `None` when no ancestor contains `tests/cross-stack/`.
    #[test]
    fn locate_returns_none_when_absent() {
        let temp = tempfile::tempdir().expect("create tempdir");
        let isolated = temp.path().join("isolated").join("nested").join("path");
        fs::create_dir_all(&isolated).expect("mkdir isolated");

        let result = locate_cross_stack_dir(&isolated);
        assert_eq!(result, None);
    }
}
