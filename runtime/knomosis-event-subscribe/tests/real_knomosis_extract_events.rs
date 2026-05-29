// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! WU GP.6.3 — end-to-end smoke test of the real `knomosis
//! extract-events` subcommand (the subprocess the production
//! `SubprocessExtractor` shells out to).
//!
//! Gated on the Lean binary's presence at `<repo>/.lake/build/bin/
//! knomosis` (built by `lake build`).  When absent — e.g. the
//! Rust-only `ci-rust.yml` job, which never builds the Lean side —
//! these tests SKIP rather than fail, mirroring the observer crate's
//! `real_knomosis_*` tests.
//!
//! The dev binary links the Lean-level `Verify` opaque (returns
//! `false`), so it cannot admit signed frames; the meaningful
//! event-extraction logic is verified Lean-side
//! (`runtime-extract-events`).  What these tests verify is the
//! subprocess *plumbing* the extractor depends on: the subcommand
//! exists, parses `--log`, performs the budget-sidecar check, reads
//! the stdin request framing, and terminates cleanly (exit 0, empty
//! stdout) on a clean EOF at a frame boundary.

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

/// Locate the knomosis binary at the conventional build path.
fn locate_knomosis_binary() -> Option<PathBuf> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // <repo>/runtime/knomosis-event-subscribe -> <repo>
    let repo = manifest.parent()?.parent()?;
    let knomosis = repo.join(".lake/build/bin/knomosis");
    if knomosis.exists() && knomosis.is_file() {
        Some(knomosis)
    } else {
        None
    }
}

/// `extract-events` exits 0 with empty stdout when stdin is closed
/// immediately (clean EOF at a frame boundary, no frames sent).
#[test]
fn extract_events_clean_eof_exits_zero() {
    let Some(bin) = locate_knomosis_binary() else {
        eprintln!("[SKIP] knomosis binary not found; run `lake build` to enable this test.");
        return;
    };
    let log = tempfile::NamedTempFile::new().expect("temp log");
    let mut child = Command::new(&bin)
        .arg("extract-events")
        .arg("--log")
        .arg(log.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn knomosis extract-events");
    // Close stdin immediately → EOF at a frame boundary → clean exit.
    drop(child.stdin.take());
    let output = child
        .wait_with_output()
        .expect("wait for knomosis extract-events");
    assert!(
        output.status.success(),
        "extract-events should exit 0 on clean EOF; status={:?}, stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        output.stdout.is_empty(),
        "no frames sent ⇒ no response bytes expected, got {} bytes",
        output.stdout.len()
    );
}

/// `extract-events` rejects a truncated request (a partial 12-byte
/// header) with a non-zero exit rather than hanging or panicking —
/// the "no silent gap" discipline the `SubprocessExtractor` relies on
/// to detect a broken subprocess.
#[test]
fn extract_events_truncated_header_exits_nonzero() {
    let Some(bin) = locate_knomosis_binary() else {
        eprintln!("[SKIP] knomosis binary not found; run `lake build` to enable this test.");
        return;
    };
    let log = tempfile::NamedTempFile::new().expect("temp log");
    let mut child = Command::new(&bin)
        .arg("extract-events")
        .arg("--log")
        .arg(log.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn knomosis extract-events");
    {
        // Write only 5 of the 12 header bytes, then close stdin: a
        // truncated request observed mid-frame.
        let mut stdin = child.stdin.take().expect("child stdin");
        stdin
            .write_all(&[0u8, 0, 0, 0, 0])
            .expect("write partial header");
        // stdin dropped here → EOF mid-header.
    }
    let output = child
        .wait_with_output()
        .expect("wait for knomosis extract-events");
    assert!(
        !output.status.success(),
        "truncated request should make extract-events exit non-zero; stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );
}
