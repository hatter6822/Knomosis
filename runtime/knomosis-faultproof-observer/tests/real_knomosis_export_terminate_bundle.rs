// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! End-to-end cross-stack integration tests for `knomosis
//! export-terminate-bundle` — the load-bearing wire contract
//! between the Lean terminate-bundle emitter (Workstream SVC.3)
//! and the Rust observer's
//! [`knomosis_faultproof_observer::strategy::TerminateBundle`]
//! deserializer (Workstream SVC.4).
//!
//! ## Test discipline
//!
//! Each test is gated on the presence of the `knomosis` binary at
//! `<repo>/.lake/build/bin/knomosis`.  When absent (e.g. a Rust-only
//! CI run without a Lean toolchain), the test SKIPs with a clear
//! message rather than failing.
//!
//! ## What this validates
//!
//! Each test synthesises a CBE-framed log file with one action
//! entry, runs `knomosis export-terminate-bundle LOG 0`, and
//! round-trips the emitted JSON through the Rust
//! [`knomosis_faultproof_observer::strategy::parse_terminate_bundle_json`]
//! parser.  This is the end-to-end check that the cross-stack
//! JSON contract holds against the REAL knomosis binary — beyond
//! the hand-pinned unit tests in `strategy.rs`.
//!
//! ## Why these tests exist (Workstream SVC.4.f)
//!
//! Without them, a Lean-side regression that renamed a field
//! (e.g., `action_kind` → `actionKind`) or changed the byte
//! encoding of `action_fields_hex` would silently slip into
//! production at the Lean→Rust handoff.  These tests pin the
//! contract end-to-end.

use knomosis_faultproof_observer::strategy::parse_terminate_bundle_json;
use knomosis_l1_ingest::action::{Action, EthAddress};
use knomosis_l1_ingest::encoding::encode_signed_action;
use std::path::PathBuf;
use std::process::Command;

/// Locate the knomosis binary at the conventional path.
fn locate_knomosis_binary() -> Option<PathBuf> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let runtime = manifest.parent()?;
    let repo = runtime.parent()?;
    let knomosis = repo.join(".lake/build/bin/knomosis");
    if knomosis.exists() && knomosis.is_file() {
        Some(knomosis)
    } else {
        None
    }
}

/// FNV-1a-64 hash (matches Lean's `Runtime/Hash.lean::fnv1a64`).
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn u64_le(n: u64) -> [u8; 8] {
    n.to_le_bytes()
}

/// Encode a CBE byte string: tag 0x02, 8-byte LE length, payload.
fn cbe_bytes(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + 8 + payload.len());
    out.push(knomosis_l1_ingest::encoding::CBE_TAG_BYTES);
    out.extend_from_slice(&u64_le(u64::try_from(payload.len()).unwrap()));
    out.extend_from_slice(payload);
    out
}

/// Wrap a `LogEntry` payload in the knomosis log-file frame format.
fn wrap_frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + 8 + payload.len() + 8);
    out.extend_from_slice(b"KNOM");
    out.extend_from_slice(&u64_le(u64::try_from(payload.len()).unwrap()));
    out.extend_from_slice(payload);
    out.extend_from_slice(&u64_le(fnv1a64(payload)));
    out
}

/// Build a synthetic log with one signed `Action`.
fn build_log_with_action(action: &Action, signer: u64) -> Vec<u8> {
    let signed_action_bytes = encode_signed_action(action, signer, 0, &[0u8; 32]).unwrap();
    let mut payload = Vec::new();
    payload.extend_from_slice(&cbe_bytes(&[]));
    payload.extend_from_slice(&signed_action_bytes);
    payload.extend_from_slice(&cbe_bytes(&[]));
    wrap_frame(&payload)
}

/// Run `knomosis export-terminate-bundle LOG IDX` and return the
/// stdout JSON string.
fn run_export_terminate_bundle(knomosis_path: &PathBuf, log_path: &PathBuf, idx: u64) -> String {
    let output = Command::new(knomosis_path)
        .arg("--allow-fallback-hash")
        .arg("--deployment-id")
        .arg("0000000000000000000000000000000000000000000000000000000000000000")
        .arg("export-terminate-bundle")
        .arg(log_path)
        .arg(idx.to_string())
        .output()
        .expect("failed to spawn knomosis");
    assert!(
        output.status.success(),
        "knomosis export-terminate-bundle failed: status={:?}, stdout={}, stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("knomosis stdout must be UTF-8")
}

/// End-to-end happy path: a Transfer log entry round-trips
/// through the knomosis binary's `export-terminate-bundle` and the
/// Rust `parse_terminate_bundle_json` parser.
#[test]
fn real_knomosis_export_terminate_bundle_transfer_round_trip() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_terminate_bundle_transfer_round_trip: knomosis binary not built. \
             Run `lake build knomosis`."
        );
        return;
    };

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("transfer.log");
    let action = Action::Transfer {
        r: 1,
        sender: 1,
        receiver: 2,
        amount: 100,
    };
    let log_bytes = build_log_with_action(&action, 1);
    std::fs::write(&log_path, &log_bytes).unwrap();

    let stdout = run_export_terminate_bundle(&knomosis_path, &log_path, 0);
    // The first non-warning line should be the JSON object.
    let json_line = stdout
        .lines()
        .find(|l| l.trim_start().starts_with('{'))
        .expect("no JSON line in stdout");
    let bundle = parse_terminate_bundle_json(0, json_line)
        .expect("parse_terminate_bundle_json failed for Transfer");

    // Per `actionKindByte`, Transfer dispatches to 0.
    assert_eq!(bundle.action_kind, 0, "Transfer's action_kind is 0");
    // Per `actionFieldsForL1`, Transfer fields are 4 × 8 = 32
    // bytes BE: r=1, sender=1, receiver=2, amount=100.
    assert_eq!(
        bundle.action_fields.len(),
        32,
        "Transfer fields = 4 × uint64BE = 32 bytes"
    );
    // r at bytes [0..8]: BE-encoded 1 → bytes[7] = 1.
    assert_eq!(bundle.action_fields[7], 1, "r=1 in BE last byte");
    // sender at bytes [8..16]: BE-encoded 1 → bytes[15] = 1.
    assert_eq!(bundle.action_fields[15], 1, "sender=1 in BE last byte");
    // receiver at bytes [16..24]: BE-encoded 2 → bytes[23] = 2.
    assert_eq!(bundle.action_fields[23], 2, "receiver=2 in BE last byte");
    // amount at bytes [24..32]: BE-encoded 100 → bytes[31] = 100.
    assert_eq!(bundle.action_fields[31], 100, "amount=100 in BE last byte");
    assert_eq!(bundle.signer, 1, "Transfer signer is 1");
    assert_eq!(
        bundle.claimed_post_commit.len(),
        32,
        "claimed_post_commit is 32 bytes"
    );
    // Transfer's cell-proof bundle has 4 cells (registry,
    // balance×2, nonce).
    assert_eq!(
        bundle.cell_proofs.len(),
        4,
        "Transfer bundle has 4 cell proofs"
    );
}

/// Idempotency: two invocations produce identical stdout.
#[test]
fn real_knomosis_export_terminate_bundle_deterministic() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_terminate_bundle_deterministic: knomosis binary not built."
        );
        return;
    };

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("mint.log");
    let action = Action::Mint {
        r: 5,
        to: 7,
        amount: 50,
    };
    let log_bytes = build_log_with_action(&action, 7);
    std::fs::write(&log_path, &log_bytes).unwrap();

    let r1 = run_export_terminate_bundle(&knomosis_path, &log_path, 0);
    let r2 = run_export_terminate_bundle(&knomosis_path, &log_path, 0);
    assert_eq!(
        r1, r2,
        "knomosis export-terminate-bundle must be deterministic"
    );
}

/// Mint variant: `action_kind` = 1, fields are 3 × `uint64BE`.
#[test]
fn real_knomosis_export_terminate_bundle_mint_variant() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_terminate_bundle_mint_variant: knomosis binary not built."
        );
        return;
    };

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("mint.log");
    let action = Action::Mint {
        r: 3,
        to: 11,
        amount: 42,
    };
    let log_bytes = build_log_with_action(&action, 11);
    std::fs::write(&log_path, &log_bytes).unwrap();

    let stdout = run_export_terminate_bundle(&knomosis_path, &log_path, 0);
    let json_line = stdout
        .lines()
        .find(|l| l.trim_start().starts_with('{'))
        .unwrap();
    let bundle = parse_terminate_bundle_json(0, json_line).unwrap();

    assert_eq!(bundle.action_kind, 1, "Mint's action_kind is 1");
    assert_eq!(
        bundle.action_fields.len(),
        24,
        "Mint fields = 3 × uint64BE = 24 bytes"
    );
    assert_eq!(bundle.action_fields[7], 3, "r=3 in BE last byte");
    assert_eq!(bundle.action_fields[15], 11, "to=11 in BE last byte");
    assert_eq!(bundle.action_fields[23], 42, "amount=42 in BE last byte");
    assert_eq!(bundle.signer, 11, "Mint signer is 11");
    // Mint bundle: 3 cells (registry, balance, nonce).
    assert_eq!(bundle.cell_proofs.len(), 3, "Mint bundle has 3 cell proofs");
}

/// Withdraw variant: `action_kind` = 14, fields include the
/// variable `recipient_l1` trailer (20 bytes).
#[test]
fn real_knomosis_export_terminate_bundle_withdraw_variant() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_terminate_bundle_withdraw_variant: knomosis binary not built."
        );
        return;
    };

    let recipient_l1 = EthAddress::from_bytes(&[0xABu8; 20]).unwrap();
    let action = Action::Withdraw {
        r: 2,
        sender: 3,
        amount: 50,
        recipient_l1,
    };
    let log_bytes = build_log_with_action(&action, 3);

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("withdraw.log");
    std::fs::write(&log_path, &log_bytes).unwrap();

    let stdout = run_export_terminate_bundle(&knomosis_path, &log_path, 0);
    let json_line = stdout
        .lines()
        .find(|l| l.trim_start().starts_with('{'))
        .unwrap();
    let bundle = parse_terminate_bundle_json(0, json_line).unwrap();

    assert_eq!(bundle.action_kind, 14, "Withdraw's action_kind is 14");
    // Withdraw fields = 3 × uint64BE (24 bytes) + 20-byte EthAddress = 44 bytes.
    assert_eq!(
        bundle.action_fields.len(),
        44,
        "Withdraw fields = 24 + 20 = 44 bytes"
    );
    assert_eq!(bundle.action_fields[7], 2, "r=2 in BE last byte");
    assert_eq!(bundle.action_fields[15], 3, "sender=3 in BE last byte");
    assert_eq!(bundle.action_fields[23], 50, "amount=50 in BE last byte");
    // Trailing 20 bytes are the recipient_l1.  All bytes 0xAB.
    for i in 24..44 {
        assert_eq!(
            bundle.action_fields[i], 0xAB,
            "recipient_l1 byte {i} should be 0xAB"
        );
    }
    assert_eq!(bundle.signer, 3, "Withdraw signer is 3");
}

/// Out-of-range idx: exit code 2.
#[test]
fn real_knomosis_export_terminate_bundle_out_of_range_exits_2() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_terminate_bundle_out_of_range_exits_2: knomosis binary not built."
        );
        return;
    };

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("empty.log");
    std::fs::write(&log_path, b"").unwrap();

    let output = Command::new(&knomosis_path)
        .arg("--allow-fallback-hash")
        .arg("--deployment-id")
        .arg("0000000000000000000000000000000000000000000000000000000000000000")
        .arg("export-terminate-bundle")
        .arg(&log_path)
        .arg("999")
        .output()
        .expect("spawn knomosis");
    assert!(
        !output.status.success(),
        "expected non-zero exit, got success: stdout={:?}, stderr={:?}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let code = output.status.code().expect("expected exit code");
    assert_eq!(code, 2, "expected exit code 2 for out-of-range idx");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("idx 999"),
        "stderr should mention out-of-range idx 999: {stderr}"
    );
}

/// Non-Nat idx: exit code 2.
#[test]
fn real_knomosis_export_terminate_bundle_non_nat_idx_exits_2() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_terminate_bundle_non_nat_idx_exits_2: knomosis binary not built."
        );
        return;
    };

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("empty.log");
    std::fs::write(&log_path, b"").unwrap();

    let output = Command::new(&knomosis_path)
        .arg("--allow-fallback-hash")
        .arg("--deployment-id")
        .arg("0000000000000000000000000000000000000000000000000000000000000000")
        .arg("export-terminate-bundle")
        .arg(&log_path)
        .arg("not-a-number")
        .output()
        .expect("spawn knomosis");
    assert!(!output.status.success(), "expected non-zero exit");
    assert_eq!(
        output.status.code(),
        Some(2),
        "expected exit code 2 for non-Nat idx"
    );
}

/// The knomosis-emitted JSON is well-formed (single object on a
/// single line).
#[test]
fn real_knomosis_export_terminate_bundle_json_is_single_line_object() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_terminate_bundle_json_is_single_line_object: knomosis binary not built."
        );
        return;
    };

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("transfer.log");
    let action = Action::Transfer {
        r: 1,
        sender: 1,
        receiver: 2,
        amount: 100,
    };
    let log_bytes = build_log_with_action(&action, 1);
    std::fs::write(&log_path, &log_bytes).unwrap();

    let stdout = run_export_terminate_bundle(&knomosis_path, &log_path, 0);
    let json_line = stdout
        .lines()
        .find(|l| l.trim_start().starts_with('{'))
        .expect("no JSON line");
    assert!(json_line.starts_with('{'), "starts with {{");
    assert!(json_line.ends_with('}'), "ends with }}");
}
