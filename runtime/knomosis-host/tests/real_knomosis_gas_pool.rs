// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! WU GP.7.4 — end-to-end smoke test of the real `knomosis` binary's
//! unified-gas-pool CLI flags (`--gas-pool-eth-cap` /
//! `--gas-pool-bold-cap`) — the exact flags `knomosis-host`'s
//! `CommandKernel::with_gas_pool_policy` forwards to the spawned
//! subprocess.
//!
//! Gated on the Lean binary's presence at `<repo>/.lake/build/bin/
//! knomosis` (built by `lake build`).  When absent — e.g. the
//! Rust-only `ci-rust.yml` job, which never builds the Lean side —
//! these tests SKIP rather than fail, mirroring the observer /
//! event-subscribe crates' `real_knomosis_*` tests.
//!
//! These tests need NO signed actions (so the dev binary's `Verify`
//! opaque returning `false` is irrelevant): the gas-pool genesis wiring
//! is crypto-independent, and the lifecycle exercised here is
//! `process` (empty input → writes the `<log>.gaspoolcfg` sidecar) →
//! `replay` (matching caps → exit 0; wrong / disabled caps → exit 2).
//! This is the binary-level counterpart to the Lean
//! `runtime-gas-pool-sidecar` + `deployments-gas-pool-example` suites
//! and the `gas_pool_caps_flags_passed_to_subprocess` host unit test.

use std::path::PathBuf;
use std::process::Command;

/// Locate the knomosis binary at the conventional build path.
fn locate_knomosis_binary() -> Option<PathBuf> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // <repo>/runtime/knomosis-host -> <repo>
    let repo = manifest.parent()?.parent()?;
    let knomosis = repo.join(".lake/build/bin/knomosis");
    if knomosis.exists() && knomosis.is_file() {
        Some(knomosis)
    } else {
        None
    }
}

/// Run the knomosis binary with the given args, returning its exit code
/// (or `None` if killed by a signal).
fn run(bin: &std::path::Path, args: &[&str]) -> Option<i32> {
    Command::new(bin)
        .args(args)
        .output()
        .expect("spawn knomosis")
        .status
        .code()
}

/// Run the knomosis binary, returning `(exit code, captured stderr)`.
fn run_stderr(bin: &std::path::Path, args: &[&str]) -> (Option<i32>, String) {
    let out = Command::new(bin)
        .args(args)
        .output()
        .expect("spawn knomosis");
    (
        out.status.code(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

/// `process` with gas-pool flags writes the `<log>.gaspoolcfg` sidecar,
/// and a subsequent `replay` with the SAME caps replays cleanly (exit 0);
/// a WRONG cap or a gas-pool-DISABLED run is rejected (exit 2) by the
/// sidecar cross-check.
#[test]
fn gas_pool_process_sidecar_and_replay_cross_check() {
    let Some(bin) = locate_knomosis_binary() else {
        eprintln!("[SKIP] knomosis binary not found; run `lake build` to enable this test.");
        return;
    };
    let dir = tempfile::tempdir().expect("temp dir");
    let log = dir.path().join("gp.log");
    let log_s = log.to_str().unwrap();
    let empty_in = dir.path().join("empty.in");
    std::fs::write(&empty_in, b"").expect("write empty input");
    let in_s = empty_in.to_str().unwrap();

    // 1. process with gas-pool flags (empty input ⇒ 0 actions) → exit 0.
    let code = run(
        &bin,
        &[
            "--allow-fallback-hash",
            "--gas-pool-eth-cap",
            "1000",
            "--gas-pool-bold-cap",
            "3000",
            "process",
            log_s,
            in_s,
        ],
    );
    assert_eq!(code, Some(0), "process with gas-pool flags should exit 0");

    // 2. The sidecar was written with the exact caps.
    let sidecar = dir.path().join("gp.log.gaspoolcfg");
    let contents = std::fs::read_to_string(&sidecar).expect("gaspoolcfg sidecar must exist");
    assert!(
        contents.contains("knomosis-gaspool/v1 1000 3000"),
        "sidecar content unexpected: {contents:?}"
    );

    // 3. replay with MATCHING caps → exit 0.
    let code = run(
        &bin,
        &[
            "--allow-fallback-hash",
            "--gas-pool-eth-cap",
            "1000",
            "--gas-pool-bold-cap",
            "3000",
            "replay",
            log_s,
        ],
    );
    assert_eq!(code, Some(0), "replay with matching caps should exit 0");

    // 4. replay with a WRONG eth cap → exit 2 (gas-pool-config error).
    let code = run(
        &bin,
        &[
            "--allow-fallback-hash",
            "--gas-pool-eth-cap",
            "999",
            "--gas-pool-bold-cap",
            "3000",
            "replay",
            log_s,
        ],
    );
    assert_eq!(
        code,
        Some(2),
        "replay with a wrong cap must be rejected (exit 2)"
    );

    // 5. replay with the gas pool DISABLED (no flags) → exit 2 (the log
    //    was created WITH the gas pool).
    let code = run(&bin, &["--allow-fallback-hash", "replay", log_s]);
    assert_eq!(
        code,
        Some(2),
        "replay with the gas pool disabled must be rejected against an enabled log (exit 2)"
    );
}

/// The gas-pool genesis (with the `gasPoolPolicy` declaration) yields a
/// DIFFERENT bootstrap state hash than the plain genesis — confirming
/// the CLI flags actually wire the genesis (not a no-op).
#[test]
fn gas_pool_genesis_distinct_from_plain() {
    let Some(bin) = locate_knomosis_binary() else {
        eprintln!("[SKIP] knomosis binary not found; run `lake build` to enable this test.");
        return;
    };
    let dir = tempfile::tempdir().expect("temp dir");
    let gp_log = dir.path().join("gp.log");
    let plain_log = dir.path().join("plain.log");

    let gp_out = Command::new(&bin)
        .args([
            "--allow-fallback-hash",
            "--gas-pool-eth-cap",
            "1000",
            "--gas-pool-bold-cap",
            "3000",
            "bootstrap",
            gp_log.to_str().unwrap(),
        ])
        .output()
        .expect("spawn knomosis bootstrap (gas-pool)");
    let plain_out = Command::new(&bin)
        .args([
            "--allow-fallback-hash",
            "bootstrap",
            plain_log.to_str().unwrap(),
        ])
        .output()
        .expect("spawn knomosis bootstrap (plain)");
    assert!(gp_out.status.success() && plain_out.status.success());

    // The "state hash:" line differs between the two genesis shapes.
    let gp = String::from_utf8_lossy(&gp_out.stdout);
    let plain = String::from_utf8_lossy(&plain_out.stdout);
    let line = |s: &str| -> String {
        s.lines()
            .find(|l| l.contains("state hash:"))
            .unwrap_or("")
            .to_string()
    };
    let gp_hash = line(&gp);
    let plain_hash = line(&plain);
    assert!(
        !gp_hash.is_empty(),
        "gas-pool bootstrap printed no state hash"
    );
    assert_ne!(
        gp_hash, plain_hash,
        "gas-pool genesis must differ from the plain genesis (wiring is not a no-op)"
    );
}

/// `export-terminate-bundle` cross-checks the gas-pool sidecar BEFORE
/// the idx check: a wrong / disabled gas-pool config against a gas-pool
/// log is rejected with a `gas-pool-config error` (exit 2).  This guards
/// the observer's terminate calldata, whose `claimedPostCommit` +
/// `cellProofs` are computed against `commitExtendedState` (which
/// includes the gas-pool `localPolicies` declaration) — so a mismatched
/// config would build the bundle against the WRONG state commit.
#[test]
fn gas_pool_export_terminate_bundle_config_checked() {
    let Some(bin) = locate_knomosis_binary() else {
        eprintln!("[SKIP] knomosis binary not found; run `lake build` to enable this test.");
        return;
    };
    let dir = tempfile::tempdir().expect("temp dir");
    let log = dir.path().join("gp.log");
    let log_s = log.to_str().unwrap();
    let empty_in = dir.path().join("empty.in");
    std::fs::write(&empty_in, b"").expect("write empty input");

    // Create a gas-pool log (writes the sidecar).
    let code = run(
        &bin,
        &[
            "--allow-fallback-hash",
            "--gas-pool-eth-cap",
            "1000",
            "--gas-pool-bold-cap",
            "3000",
            "process",
            log_s,
            empty_in.to_str().unwrap(),
        ],
    );
    assert_eq!(code, Some(0), "gas-pool process should exit 0");

    // export-terminate-bundle with a WRONG cap → gas-pool-config error
    // (the sidecar check fires before the idx bound check).
    let (code, stderr) = run_stderr(
        &bin,
        &[
            "--allow-fallback-hash",
            "--gas-pool-eth-cap",
            "999",
            "--gas-pool-bold-cap",
            "3000",
            "export-terminate-bundle",
            log_s,
            "0",
        ],
    );
    assert_eq!(
        code,
        Some(2),
        "wrong-cap export-terminate-bundle must exit 2"
    );
    assert!(
        stderr.contains("gas-pool-config"),
        "expected a gas-pool-config error, got stderr: {stderr}"
    );

    // … and with the gas pool DISABLED (no flags) → same rejection.
    let (code, stderr) = run_stderr(
        &bin,
        &[
            "--allow-fallback-hash",
            "export-terminate-bundle",
            log_s,
            "0",
        ],
    );
    assert_eq!(
        code,
        Some(2),
        "gas-pool-disabled export-terminate-bundle must exit 2"
    );
    assert!(
        stderr.contains("gas-pool-config"),
        "expected a gas-pool-config error, got stderr: {stderr}"
    );
}
