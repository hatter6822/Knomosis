// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Cross-stack fixture-driven tests for `canon-verify-secp256k1`.
//!
//! Loads `runtime/tests/cross-stack/ecdsa_secp256k1.cxsf` (generated
//! by `examples/gen_ecdsa_fixtures.rs`) and asserts that every
//! record's `expected` byte matches the `verify` function's actual
//! output.  This is the load-bearing cross-stack contract: the
//! committed corpus is what every future regression test runs
//! against, and any drift between the verifier and the corpus
//! generator surfaces here.

use canon_cross_stack::{FixtureFile, FixtureKind};
use canon_verify_secp256k1::verify;
use std::path::PathBuf;

fn fixture_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.pop();
    p.push("tests");
    p.push("cross-stack");
    p.push("ecdsa_secp256k1.cxsf");
    p
}

/// The fixture file is present and parses cleanly.
#[test]
fn fixture_file_loads() {
    let p = fixture_path();
    let fixture = FixtureFile::load(&p).unwrap_or_else(|e| {
        panic!(
            "Fixture file not found or unreadable at {}: {e}.  Re-generate via \
             `cargo run --example gen_ecdsa_fixtures` from the workspace root.",
            p.display()
        );
    });
    assert_eq!(fixture.kind(), FixtureKind::Ecdsa);
    assert!(
        fixture.records().len() >= 50,
        "RH-A.1.d plan requires ≥ 50 fixture vectors; corpus has {}",
        fixture.records().len()
    );
}

/// Every fixture record's `expected` byte matches the verifier's
/// actual output.  This is the load-bearing cross-stack contract.
#[test]
fn fixture_records_match_verifier() {
    let p = fixture_path();
    let fixture = FixtureFile::load(&p).expect("fixture present");

    let mut accept_count = 0usize;
    let mut reject_count = 0usize;
    for (index, record) in fixture.records().iter().enumerate() {
        let (pk, msg, sig) = parse_input(&record.input).unwrap_or_else(|| {
            panic!(
                "Record {index}: input field malformed; cannot parse pk/msg/sig.  \
                 The fixture format expects three length-prefixed slices."
            );
        });
        let expected_byte = *record.expected.first().unwrap_or_else(|| {
            panic!(
                "Record {index}: expected field is empty; should contain a single \
                 0x00 / 0x01 byte."
            );
        });
        assert!(
            record.expected.len() == 1,
            "Record {index}: expected field length {} (must be 1)",
            record.expected.len()
        );
        let actual = u8::from(verify(pk, msg, sig));
        assert_eq!(
            actual, expected_byte,
            "Record {index}: verify={actual}, expected={expected_byte}.  \
             pk: {pk:02x?}; msg: {msg:02x?}; sig: {sig:02x?}"
        );
        if expected_byte == 0x01 {
            accept_count += 1;
        } else {
            reject_count += 1;
        }
    }

    // Sanity: the corpus is balanced — both accept and reject
    // cases are present, and reject cases substantially outnumber
    // accept cases (the generator emits ~3x more rejects per
    // accept).
    assert!(
        accept_count > 0,
        "corpus has zero accept records; the generator must have miscoded the corpus"
    );
    assert!(
        reject_count > accept_count,
        "corpus has {accept_count} accept and {reject_count} reject records; \
         expected reject > accept per the generator's design"
    );
}

/// Helper to parse the corpus's input field back into the three
/// constituent byte slices.  Mirrors `gen_ecdsa_fixtures.rs`'s
/// layout.
fn parse_input(input: &[u8]) -> Option<(&[u8], &[u8], &[u8])> {
    let mut cursor = 0;
    let pk_len = read_u16_be(input, &mut cursor)?;
    let pk = read_slice(input, &mut cursor, pk_len)?;
    let msg_len = read_u16_be(input, &mut cursor)?;
    let msg = read_slice(input, &mut cursor, msg_len)?;
    let sig_len = read_u16_be(input, &mut cursor)?;
    let sig = read_slice(input, &mut cursor, sig_len)?;
    if cursor == input.len() {
        Some((pk, msg, sig))
    } else {
        None
    }
}

fn read_u16_be(input: &[u8], cursor: &mut usize) -> Option<usize> {
    let next = cursor.checked_add(2)?;
    let bytes = input.get(*cursor..next)?;
    let arr: [u8; 2] = bytes.try_into().ok()?;
    *cursor = next;
    Some(usize::from(u16::from_be_bytes(arr)))
}

fn read_slice<'a>(input: &'a [u8], cursor: &mut usize, len: usize) -> Option<&'a [u8]> {
    let next = cursor.checked_add(len)?;
    let bytes = input.get(*cursor..next)?;
    *cursor = next;
    Some(bytes)
}
