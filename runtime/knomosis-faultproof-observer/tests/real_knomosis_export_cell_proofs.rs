// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! End-to-end cross-stack integration tests for `knomosis
//! export-cell-proofs` — the load-bearing wire contract between
//! the Lean cell-proof emitter and the Rust observer's
//! [`knomosis_faultproof_observer::submitter::CellProof`] deserializer.
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
//! Unlike `real_knomosis_subprocess.rs` (which only exercises
//! `replay-up-to`), THIS file synthesises a CBE-framed log file
//! with one `Transfer` entry, then runs
//! `knomosis export-cell-proofs LOG 0 SIGNER` and round-trips the
//! emitted JSON through the Rust `CellProof` deserializer.  This is
//! the only end-to-end check that the cross-stack JSON contract
//! actually holds against the REAL knomosis binary (rather than
//! hand-pinned JSON examples in `submitter.rs::tests`).

use knomosis_faultproof_observer::submitter::CellProof;
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

/// FNV-1a-64 hash (matches Lean's `Runtime/Hash.lean::fnv1a64`,
/// used by the log-frame trailer).
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// Encode a `u64` as 8 little-endian bytes.
fn u64_le(n: u64) -> [u8; 8] {
    n.to_le_bytes()
}

/// Encode a CBE byte string: tag 0x02, 8-byte LE length, payload.
/// (Mirrors Lean `Encoding.CBOR.cbeTagBytes`; see
/// `knomosis-l1-ingest::encoding::CBE_TAG_BYTES`.)
fn cbe_bytes(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(1 + 8 + payload.len());
    out.push(knomosis_l1_ingest::encoding::CBE_TAG_BYTES);
    out.extend_from_slice(&u64_le(u64::try_from(payload.len()).unwrap()));
    out.extend_from_slice(payload);
    out
}

/// Wrap a `LogEntry` payload in the knomosis log-file frame format:
///   `magic (KNOM) || 8-byte LE length || payload || 8-byte LE FNV-1a-64`
fn wrap_frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + 8 + payload.len() + 8);
    out.extend_from_slice(b"KNOM");
    out.extend_from_slice(&u64_le(u64::try_from(payload.len()).unwrap()));
    out.extend_from_slice(payload);
    out.extend_from_slice(&u64_le(fnv1a64(payload)));
    out
}

/// Build a synthetic log file with one Transfer entry.  The
/// signature is invalid (32 zero bytes) but `kernelOnlyReplay`
/// (which `export-cell-proofs` calls) does not verify signatures.
fn build_synthetic_log_with_transfer() -> Vec<u8> {
    // Action: Transfer(resource=1, sender=1, receiver=2, amount=100)
    let action = Action::Transfer {
        r: 1,
        sender: 1,
        receiver: 2,
        amount: 100,
    };
    // SignedAction: signer=1, nonce=0, sig=zeros
    let signed_action_bytes = encode_signed_action(&action, 1, 0, &[0u8; 32]).unwrap();
    // LogEntry: prevHash=empty, signedAction, postStateHash=empty
    // Note: the on-disk LogEntry encoder writes:
    //   encode(ByteArray prevHash) ++ encode(SignedAction) ++ encode(ByteArray postStateHash)
    let mut payload = Vec::new();
    payload.extend_from_slice(&cbe_bytes(&[])); // prevHash = empty
    payload.extend_from_slice(&signed_action_bytes); // signed action
    payload.extend_from_slice(&cbe_bytes(&[])); // postStateHash = empty
    wrap_frame(&payload)
}

/// End-to-end cross-stack test: build a real log file with one
/// Transfer entry, run knomosis's `export-cell-proofs` against it,
/// and verify the emitted JSON deserialises into the Rust
/// `CellProof` struct.
#[test]
fn real_knomosis_export_cell_proofs_transfer_round_trip() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_cell_proofs_transfer_round_trip: knomosis binary not built. \
             Run `lake build knomosis`."
        );
        return;
    };

    // 1. Build a synthetic log file with one Transfer entry.
    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("transfer.log");
    let log_bytes = build_synthetic_log_with_transfer();
    std::fs::write(&log_path, &log_bytes).unwrap();

    // 2. Run knomosis export-cell-proofs LOG 0 1.
    let output = Command::new(&knomosis_path)
        .arg("--allow-fallback-hash")
        .arg("--deployment-id")
        .arg("0000000000000000000000000000000000000000000000000000000000000000")
        .arg("export-cell-proofs")
        .arg(&log_path)
        .arg("0")
        .arg("1")
        .output()
        .expect("failed to spawn knomosis");
    assert!(
        output.status.success(),
        "knomosis export-cell-proofs failed: status={:?}, stdout={}, stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    // 3. Parse the JSON-array output.  The format is:
    //   `[\n`
    //   `  {<obj 1>}\n`
    //   `, {<obj 2>}\n`
    //   ...
    //   `]\n`
    let stdout = String::from_utf8(output.stdout).expect("knomosis stdout must be UTF-8");
    let lines: Vec<&str> = stdout.lines().collect();
    assert!(
        lines.len() >= 3,
        "expected at least 3 lines (open-bracket + ≥1 obj + close-bracket), got: {stdout}"
    );
    assert_eq!(lines[0], "[", "first line must be '[': {stdout}");
    assert_eq!(
        lines[lines.len() - 1],
        "]",
        "last line must be ']': {stdout}"
    );

    // 4. Each middle line starts with "  " (first) or ", " (rest).
    //    Strip the lead-in and parse each object.
    let mut parsed_proofs: Vec<CellProof> = Vec::new();
    for (i, &line) in lines.iter().enumerate() {
        if i == 0 || i == lines.len() - 1 {
            continue;
        }
        let stripped = if let Some(rest) = line.strip_prefix("  ") {
            rest
        } else if let Some(rest) = line.strip_prefix(", ") {
            rest
        } else {
            panic!("line {i} has unexpected prefix: {line:?}");
        };
        let proof: CellProof = serde_json::from_str(stripped)
            .unwrap_or_else(|e| panic!("line {i} did not parse as CellProof: {stripped:?}: {e}"));
        parsed_proofs.push(proof);
    }

    // 5. Verify the expected cell-proof bundle for a Transfer:
    //    [registry signer=1, balance r=1 sender=1, balance r=1 receiver=2, nonce signer=1]
    assert_eq!(
        parsed_proofs.len(),
        4,
        "Transfer bundle should have 4 cell proofs, got {}: {parsed_proofs:?}",
        parsed_proofs.len()
    );

    // Cell 0: registry of signer=1.  cell_kind=2, key_a=1, key_b=0.
    let p0 = &parsed_proofs[0];
    assert_eq!(p0.cell_kind, 2, "cell 0 should be registry (kind 2)");
    assert_eq!(p0.key_a, 1, "cell 0 key_a should be signer=1");
    assert_eq!(p0.key_b, 0, "cell 0 key_b should be 0 for registry");

    // Cell 1: balance of (resource=1, actor=sender=1).  kind=0, key_a=1, key_b=1.
    let p1 = &parsed_proofs[1];
    assert_eq!(p1.cell_kind, 0, "cell 1 should be balance (kind 0)");
    assert_eq!(p1.key_a, 1, "cell 1 key_a should be resource=1");
    assert_eq!(p1.key_b, 1, "cell 1 key_b should be sender=1");

    // Cell 2: balance of (resource=1, actor=receiver=2).  kind=0, key_a=1, key_b=2.
    let p2 = &parsed_proofs[2];
    assert_eq!(p2.cell_kind, 0, "cell 2 should be balance (kind 0)");
    assert_eq!(p2.key_a, 1, "cell 2 key_a should be resource=1");
    assert_eq!(p2.key_b, 2, "cell 2 key_b should be receiver=2");

    // Cell 3: nonce of signer=1.  cell_kind=1, key_a=1, key_b=0.
    let p3 = &parsed_proofs[3];
    assert_eq!(p3.cell_kind, 1, "cell 3 should be nonce (kind 1)");
    assert_eq!(p3.key_a, 1, "cell 3 key_a should be signer=1");
    assert_eq!(p3.key_b, 0, "cell 3 key_b should be 0 for nonce");

    // 6. All cell proofs should have a 32-byte witness_commit.
    for (i, p) in parsed_proofs.iter().enumerate() {
        assert_eq!(
            p.witness_commit.len(),
            32,
            "cell {i} witness_commit should be 32 bytes, got {}",
            p.witness_commit.len()
        );
    }

    // 7. All four cell proofs share the same witness_commit
    //    (they all witness the SAME pre-state).
    for (i, p) in parsed_proofs.iter().enumerate().skip(1) {
        assert_eq!(
            p.witness_commit, parsed_proofs[0].witness_commit,
            "cell {i} witness_commit should match cell 0 (same pre-state)",
        );
    }
}

/// Idempotency check: running knomosis twice produces identical
/// output byte-for-byte.
#[test]
fn real_knomosis_export_cell_proofs_deterministic() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_cell_proofs_deterministic: knomosis binary not built."
        );
        return;
    };

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("transfer.log");
    let log_bytes = build_synthetic_log_with_transfer();
    std::fs::write(&log_path, &log_bytes).unwrap();

    let run = || {
        let output = Command::new(&knomosis_path)
            .arg("--allow-fallback-hash")
            .arg("--deployment-id")
            .arg("0000000000000000000000000000000000000000000000000000000000000000")
            .arg("export-cell-proofs")
            .arg(&log_path)
            .arg("0")
            .arg("1")
            .output()
            .expect("spawn knomosis");
        assert!(output.status.success());
        output.stdout
    };

    let r1 = run();
    let r2 = run();
    assert_eq!(
        r1, r2,
        "knomosis export-cell-proofs must be deterministic; got differing stdouts",
    );
}

/// Multi-action variant: a Withdraw entry exercises a different
/// cell layout (registry, balance, nonce, bridgeNextWdId).
#[test]
fn real_knomosis_export_cell_proofs_withdraw() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!("[SKIP] real_knomosis_export_cell_proofs_withdraw: knomosis binary not built.");
        return;
    };

    // Action: Withdraw(resource=2, sender=3, amount=50, recipient_l1=[0xAB; 20])
    let recipient_l1 = EthAddress::from_bytes(&[0xABu8; 20]).unwrap();
    let action = Action::Withdraw {
        r: 2,
        sender: 3,
        amount: 50,
        recipient_l1,
    };
    let signed_action_bytes = encode_signed_action(&action, 3, 0, &[0u8; 32]).unwrap();
    let mut payload = Vec::new();
    payload.extend_from_slice(&cbe_bytes(&[]));
    payload.extend_from_slice(&signed_action_bytes);
    payload.extend_from_slice(&cbe_bytes(&[]));
    let log_bytes = wrap_frame(&payload);

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("withdraw.log");
    std::fs::write(&log_path, &log_bytes).unwrap();

    let output = Command::new(&knomosis_path)
        .arg("--allow-fallback-hash")
        .arg("--deployment-id")
        .arg("0000000000000000000000000000000000000000000000000000000000000000")
        .arg("export-cell-proofs")
        .arg(&log_path)
        .arg("0")
        .arg("3")
        .output()
        .expect("spawn knomosis");
    assert!(
        output.status.success(),
        "knomosis export-cell-proofs failed: status={:?}, stderr={}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );

    let stdout = String::from_utf8(output.stdout).unwrap();
    let lines: Vec<&str> = stdout.lines().collect();
    let mut parsed_proofs: Vec<CellProof> = Vec::new();
    for (i, &line) in lines.iter().enumerate() {
        if i == 0 || i == lines.len() - 1 {
            continue;
        }
        let stripped = line
            .strip_prefix("  ")
            .or_else(|| line.strip_prefix(", "))
            .expect("recognised lead-in");
        parsed_proofs.push(serde_json::from_str(stripped).unwrap());
    }

    // Withdraw cell layout:
    //   readOnly: [registry signer]
    //   write:    [balance r sender, nonce signer, bridgeNextWdId]
    assert_eq!(
        parsed_proofs.len(),
        4,
        "Withdraw bundle should have 4 cell proofs"
    );

    // Cell 0: registry signer=3.
    assert_eq!(parsed_proofs[0].cell_kind, 2);
    assert_eq!(parsed_proofs[0].key_a, 3);
    assert_eq!(parsed_proofs[0].key_b, 0);

    // Cell 1: balance (r=2, sender=3).
    assert_eq!(parsed_proofs[1].cell_kind, 0);
    assert_eq!(parsed_proofs[1].key_a, 2);
    assert_eq!(parsed_proofs[1].key_b, 3);

    // Cell 2: nonce signer=3.
    assert_eq!(parsed_proofs[2].cell_kind, 1);
    assert_eq!(parsed_proofs[2].key_a, 3);
    assert_eq!(parsed_proofs[2].key_b, 0);

    // Cell 3: bridgeNextWdId.  kind=6, key_a=0, key_b=0.
    assert_eq!(parsed_proofs[3].cell_kind, 6);
    assert_eq!(parsed_proofs[3].key_a, 0);
    assert_eq!(parsed_proofs[3].key_b, 0);
}

/// Negative test: out-of-range idx should exit code 2 with the
/// expected stderr message.
#[test]
fn real_knomosis_export_cell_proofs_out_of_range_exits_2() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_cell_proofs_out_of_range_exits_2: knomosis binary not built."
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
        .arg("export-cell-proofs")
        .arg(&log_path)
        .arg("0")
        .arg("1")
        .output()
        .expect("spawn knomosis");
    assert_eq!(
        output.status.code(),
        Some(2),
        "expected exit 2 for out-of-range idx, got {:?}",
        output.status.code()
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("idx 0 >= log length 0"),
        "stderr should mention out-of-range, got: {stderr}",
    );
}

/// Negative test: non-Nat idx should exit code 2.
#[test]
fn real_knomosis_export_cell_proofs_non_nat_idx_exits_2() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_cell_proofs_non_nat_idx_exits_2: knomosis binary not built."
        );
        return;
    };

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("any.log");
    std::fs::write(&log_path, b"").unwrap();

    let output = Command::new(&knomosis_path)
        .arg("--allow-fallback-hash")
        .arg("--deployment-id")
        .arg("0000000000000000000000000000000000000000000000000000000000000000")
        .arg("export-cell-proofs")
        .arg(&log_path)
        .arg("not-a-nat")
        .arg("1")
        .output()
        .expect("spawn knomosis");
    assert_eq!(output.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("idx 'not-a-nat' is not a Nat"),
        "stderr should mention idx parse error, got: {stderr}",
    );
}

/// Negative test: non-Nat signer should exit code 2.
#[test]
fn real_knomosis_export_cell_proofs_non_nat_signer_exits_2() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_cell_proofs_non_nat_signer_exits_2: knomosis binary not built."
        );
        return;
    };

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("any.log");
    std::fs::write(&log_path, b"").unwrap();

    let output = Command::new(&knomosis_path)
        .arg("--allow-fallback-hash")
        .arg("--deployment-id")
        .arg("0000000000000000000000000000000000000000000000000000000000000000")
        .arg("export-cell-proofs")
        .arg(&log_path)
        .arg("0")
        .arg("not-a-nat")
        .output()
        .expect("spawn knomosis");
    assert_eq!(output.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("signer 'not-a-nat' is not a Nat"),
        "stderr should mention signer parse error, got: {stderr}",
    );
}

/// Audit-pass-4-round-5 HIGH regression: the round-4 CRITICAL
/// fix derives `signer` from the log entry; a CLI-supplied
/// signer that mismatches must surface a typed error (exit
/// code 2) with a clear diagnostic.  Without this fix, the
/// operator would build a bundle for the wrong actor and L1
/// would reject the calldata AFTER paying gas.
#[test]
fn real_knomosis_export_cell_proofs_signer_mismatch_exits_2() {
    let Some(knomosis_path) = locate_knomosis_binary() else {
        eprintln!(
            "[SKIP] real_knomosis_export_cell_proofs_signer_mismatch_exits_2: knomosis binary not built."
        );
        return;
    };

    let dir = tempfile::tempdir().unwrap();
    let log_path = dir.path().join("transfer.log");
    // The fixture log has a SignedAction with signer=1.
    std::fs::write(&log_path, build_synthetic_log_with_transfer()).unwrap();

    // Pass signer=99 (wrong); entry signer is 1.
    let output = Command::new(&knomosis_path)
        .arg("--allow-fallback-hash")
        .arg("--deployment-id")
        .arg("0000000000000000000000000000000000000000000000000000000000000000")
        .arg("export-cell-proofs")
        .arg(&log_path)
        .arg("0")
        .arg("99")
        .output()
        .expect("spawn knomosis");
    assert_eq!(
        output.status.code(),
        Some(2),
        "expected exit 2 for signer mismatch, got {:?}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stderr),
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("signer mismatch") || stderr.contains("Re-run"),
        "stderr should mention signer mismatch, got: {stderr}",
    );
    // The correct signer (1) should succeed (exit 0).
    let output_ok = Command::new(&knomosis_path)
        .arg("--allow-fallback-hash")
        .arg("--deployment-id")
        .arg("0000000000000000000000000000000000000000000000000000000000000000")
        .arg("export-cell-proofs")
        .arg(&log_path)
        .arg("0")
        .arg("1")
        .output()
        .expect("spawn knomosis");
    assert_eq!(output_ok.status.code(), Some(0));
}
