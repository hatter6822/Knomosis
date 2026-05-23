// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! End-to-end demonstration of the downstream-crate usage pattern.
//!
//! This integration test is the canonical example of how RH-A.1 (or
//! any other downstream crate with a cross-stack contract) consumes
//! the fixture loader.  Future work units copy this shape verbatim;
//! reviewing this file is the fastest way to understand the
//! dev-dependency contract.

use canon_cross_stack::{FixtureFile, FixtureKind, FixtureRecord};

/// The "downstream crate" simulates RH-A.2's keccak hash adaptor.
/// Its production implementation byte-hashes the input via
/// `Keccak256`; the simulation here just XOR-fingerprints the input
/// so the cross-stack equivalence check has something to compare.
fn simulated_hash(input: &[u8]) -> Vec<u8> {
    // A deterministic, byte-exact function the test can predict.
    // The real RH-A.2 implementation replaces this with Keccak256.
    let mut out = vec![0u8; 32];
    for (i, byte) in input.iter().enumerate() {
        out[i % 32] ^= *byte;
    }
    out
}

#[test]
fn downstream_crate_consumption_pattern() {
    // The fixture-generation step would normally run in Lean and
    // produce the .cxsf file as a build artefact under
    // `runtime/tests/cross-stack/`.  For RH-H's self-test we
    // generate the fixture inline so the integration test is
    // self-contained.
    let inputs: Vec<Vec<u8>> = vec![
        b"".to_vec(),
        b"a".to_vec(),
        b"abc".to_vec(),
        b"the quick brown fox jumps over the lazy dog".to_vec(),
    ];

    let records: Vec<FixtureRecord> = inputs
        .iter()
        .map(|i| FixtureRecord::new(i.clone(), simulated_hash(i)))
        .collect();
    let fixture = FixtureFile::from_records(FixtureKind::Hash, records);

    // Serialise + deserialise to model the on-disk path.
    let serialised = fixture.to_bytes();
    let loaded = FixtureFile::from_bytes(&serialised).expect("loader accepts our fixture");

    assert_eq!(loaded.kind(), FixtureKind::Hash);
    assert_eq!(loaded.records().len(), inputs.len());

    // Run the cross-stack equivalence assertion: for every loaded
    // record, the downstream crate's implementation must
    // byte-equal the expected output.
    for (index, record) in loaded.records().iter().enumerate() {
        let actual = simulated_hash(&record.input);
        assert_eq!(
            actual, record.expected,
            "cross-stack mismatch at fixture record {index}: input = {:?}",
            record.input
        );
    }
}

#[test]
fn fixture_file_is_self_describing() {
    // Tag-based discrimination: a downstream crate that loads a
    // fixture intended for another consumer can refuse via
    // `kind()` rather than silently mis-comparing.
    let f = FixtureFile::from_records(
        FixtureKind::Ecdsa,
        vec![FixtureRecord::new(vec![0xAB], vec![0x01])],
    );
    let serialised = f.to_bytes();
    let loaded = FixtureFile::from_bytes(&serialised).expect("decode");
    // Downstream "RH-A.2" would do something like:
    //   assert!(matches!(loaded.kind(), FixtureKind::Hash));
    // and refuse to proceed if it isn't.  Here we simulate the
    // *positive* match case to keep the test deterministic.
    assert_eq!(loaded.kind(), FixtureKind::Ecdsa);
}
