// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Cross-stack integration tests that invoke the REAL `knomosis`
//! binary built by `lake build knomosis`.  These tests catch
//! interface-level drift between the Lean side's
//! `knomosis replay-up-to` subcommand and the Rust side's
//! [`knomosis_faultproof_observer::strategy::SubprocessTruthOracle`]
//! parser.
//!
//! ## Test discipline
//!
//! Each test is gated on the presence of the `knomosis` binary at
//! the conventional path (`<repo>/.lake/build/bin/knomosis`).  If
//! the binary is absent (e.g., a Rust-only CI run without a
//! Lean toolchain), the test SKIPS with a clear message rather
//! than failing.  This matches the existing knomosis-cross-stack
//! crate's pattern.
//!
//! ## Why both mock + real tests
//!
//! The strategy module's `tests` (`src/strategy.rs::tests`) ship
//! mock-script-based tests that exercise edge cases (subprocess
//! crash, malformed output, flag pass-through) that the real
//! `knomosis` binary won't easily reproduce.  THIS file's tests
//! exercise the actual cross-stack interface: the real binary's
//! actual output format must be parseable by the real Rust
//! oracle.  Interface drift (e.g., the Lean side changing
//! `\n` to `\r\n` or adding a prefix) breaks here loudly.

use knomosis_faultproof_observer::strategy::{SubprocessTruthOracle, TruthOracle};
use std::path::PathBuf;

/// Locate the knomosis binary at the conventional path.  Returns
/// `Some(path)` if the binary exists (built via `lake build
/// knomosis`); `None` otherwise.  Tests gate their bodies on this.
fn locate_knomosis_binary() -> Option<PathBuf> {
    // Crate is `runtime/knomosis-faultproof-observer`; knomosis binary
    // is at `<repo>/.lake/build/bin/knomosis`.  Walk up from
    // CARGO_MANIFEST_DIR to find the repo root.
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // <repo>/runtime/knomosis-faultproof-observer
    let runtime = manifest.parent()?;
    // <repo>/runtime
    let repo = runtime.parent()?;
    let knomosis = repo.join(".lake/build/bin/knomosis");
    if knomosis.exists() && knomosis.is_file() {
        Some(knomosis)
    } else {
        None
    }
}

/// Real-knomosis smoke test: spawn `knomosis replay-up-to /tmp/<empty-log> 0`
/// and verify the output parses as a 32-byte commit.
///
/// This is the load-bearing cross-stack integration test for
/// the RH-G.4 deliverable.  If the Lean side changes the
/// subcommand's output format, this test breaks.
#[test]
fn real_knomosis_replay_up_to_empty_log() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_replay_up_to_empty_log: knomosis binary not built at \
             <repo>/.lake/build/bin/knomosis.  Run `lake build knomosis` to enable this test."
        );
        return;
    };
    // Create an empty log file in a tempdir.
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("empty.log");
    std::fs::write(&log_path, b"").unwrap();

    // Construct the oracle with the deployment-id flag set to
    // a deterministic value (silences the dev-mode warning).
    let oracle = SubprocessTruthOracle::new(knomosis_path, log_path)
        .with_flag("--allow-fallback-hash", "")
        .with_flag(
            "--deployment-id",
            "0000000000000000000000000000000000000000000000000000000000000000",
        );
    // `--allow-fallback-hash` takes no value but our with_flag
    // API expects a pair.  Use empty string; knomosis's arg parser
    // treats unknown adjacent args benignly (the next token
    // is consumed as the value for the deployment-id flag
    // anyway).  This is a wart of the with_flag API; we'll
    // revisit in a follow-up.
    let _ = oracle;
    // Re-construct without the flag pair workaround; knomosis's
    // global-flag parser handles `--allow-fallback-hash` as a
    // boolean flag without a value.  We'll skip it here and
    // tolerate the WARN line on stderr — our parser ignores
    // stderr.
    let knomosis_path = locate_knomosis_binary().unwrap();
    let dir2 = tempfile::tempdir().unwrap();
    let log_path2 = dir2.path().join("empty.log");
    std::fs::write(&log_path2, b"").unwrap();
    let oracle2 = SubprocessTruthOracle::new(knomosis_path, log_path2).with_flag(
        "--deployment-id",
        "0000000000000000000000000000000000000000000000000000000000000000",
    );
    let commit = oracle2.commit_at(0);
    assert!(
        commit.is_some(),
        "real knomosis should return Some(32-byte commit) for empty log + idx 0",
    );
    let bytes = commit.unwrap();
    assert_eq!(bytes.len(), 32);
    // The actual commit value depends on the kernel's
    // commitExtendedState(ExtendedState.empty) — under the
    // fallback hash it's deterministic but not hand-pinnable
    // (the hash is FNV-1a-64 padded; under a production
    // keccak256 it'd be different).  We verify only the
    // shape: non-zero and 32 bytes.
    assert_ne!(bytes, [0u8; 32], "commit should not be all-zero");
}

/// Real-knomosis out-of-range test: idx > log length returns
/// `None` (exit code 2 → `SubprocessTruthOracle`'s failure path).
#[test]
fn real_knomosis_replay_up_to_out_of_range() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!("[SKIP] real_knomosis_replay_up_to_out_of_range: knomosis binary not built.");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("empty.log");
    std::fs::write(&log_path, b"").unwrap();
    let oracle = SubprocessTruthOracle::new(knomosis_path, log_path).with_flag(
        "--deployment-id",
        "0000000000000000000000000000000000000000000000000000000000000000",
    );
    // idx 9999 > log length 0; knomosis exits 2; oracle returns None.
    let commit = oracle.commit_at(9999);
    assert!(commit.is_none());
}

/// Real-knomosis nonexistent-log test: missing log file should
/// cause knomosis to emit a parse error (or empty entries),
/// either way the oracle returns None or a deterministic
/// genesis commit.  We just verify it doesn't panic.
#[test]
fn real_knomosis_replay_up_to_missing_log() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!("[SKIP] real_knomosis_replay_up_to_missing_log: knomosis binary not built.");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("does-not-exist.log");
    // Don't create the file.
    let oracle = SubprocessTruthOracle::new(knomosis_path, log_path).with_flag(
        "--deployment-id",
        "0000000000000000000000000000000000000000000000000000000000000000",
    );
    // Whatever knomosis does, the oracle handles it gracefully.
    let _ = oracle.commit_at(0);
}

/// Cross-stack determinism: two calls with the same args
/// produce the same commit.
#[test]
fn real_knomosis_replay_up_to_deterministic() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!("[SKIP] real_knomosis_replay_up_to_deterministic: knomosis binary not built.");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("empty.log");
    std::fs::write(&log_path, b"").unwrap();
    let oracle = SubprocessTruthOracle::new(knomosis_path, log_path).with_flag(
        "--deployment-id",
        "0000000000000000000000000000000000000000000000000000000000000000",
    );
    let c1 = oracle.commit_at(0).unwrap();
    let c2 = oracle.commit_at(0).unwrap();
    assert_eq!(
        c1, c2,
        "two replay-up-to calls with same args must be deterministic"
    );
}
