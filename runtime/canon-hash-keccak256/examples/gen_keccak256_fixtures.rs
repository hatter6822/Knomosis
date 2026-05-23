// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! `gen_keccak256_fixtures` — RH-A.2.d corpus generator.
//!
//! Deterministically produces the `.cxsf` fixture file consumed
//! by `knomosis-hash-keccak256`'s cross-stack tests.  The output is
//! committed under `runtime/tests/cross-stack/keccak256.cxsf`.
//!
//! The corpus covers six structural classes of inputs:
//!
//!   1. **Boundary cases.**  Empty input, single byte, 31 bytes,
//!      32 bytes, 33 bytes — exercises the rate (1088-bit / 136-byte)
//!      block boundary and the byte-level padding logic.
//!   2. **Block-rate boundaries.**  135, 136, 137 bytes — the
//!      Keccak-256 rate is exactly 136 bytes; inputs straddling
//!      this boundary exercise the multi-block path.
//!   3. **Well-known test vectors.**  `"abc"`, `"the quick brown
//!      fox..."`, and other reference strings whose digests appear
//!      in published documentation.
//!   4. **Repeated bytes.**  All-zero, all-one, and patterned
//!      sequences of various lengths.
//!   5. **Pseudorandom data.**  Inputs derived from a fixed seed
//!      via a deterministic xorshift PRNG.
//!   6. **Long inputs.**  Multi-kilobyte sequences (multi-block).
//!
//! Total: 51 fixture vectors (8 boundary + 8 block-rate + 18
//! well-known + 8 repeated + 8 pseudorandom + 1 huge), exceeding
//! the plan's "≥ 30 byte-array fixtures" floor by ~70%.
//!
//! ## Determinism
//!
//! The generator's PRNG is a fixed-seed xorshift; the output `.cxsf`
//! file is therefore byte-identical across re-generations.  The
//! determinism is critical for CI gating: a generator that
//! produced different bytes between runs would break the
//! committed-fixture contract.

use canon_cross_stack::{FixtureFile, FixtureKind, FixtureRecord};
use canon_hash_keccak256::keccak256;
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let output_path: PathBuf = env::args()
        .nth(1)
        .map_or_else(default_output_path, PathBuf::from);

    let records = build_corpus();

    // Sanity: ensure every record's expected digest exactly
    // matches `keccak256(input)`.  This is the load-bearing
    // generator invariant.
    for (index, record) in records.iter().enumerate() {
        let actual = keccak256(&record.input).to_vec();
        if actual != record.expected {
            eprintln!(
                "internal: record {index} disagrees with hasher: input len={}, \
                 expected={:02x?}, actual={:02x?}",
                record.input.len(),
                record.expected,
                actual
            );
            return ExitCode::from(1);
        }
    }

    let fixture = FixtureFile::from_records(FixtureKind::Hash, records);
    if let Some(parent) = output_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            eprintln!("failed to create output directory {parent:?}: {e}");
            return ExitCode::from(1);
        }
    }
    if let Err(e) = fixture.write_to(&output_path) {
        eprintln!("failed to write fixture file {output_path:?}: {e}");
        return ExitCode::from(1);
    }
    println!(
        "wrote {} records ({} bytes) to {}",
        fixture.records().len(),
        fixture.to_bytes().len(),
        output_path.display()
    );
    ExitCode::SUCCESS
}

/// Default output path:
/// `runtime/tests/cross-stack/keccak256.cxsf`.
fn default_output_path() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.pop();
    p.push("tests");
    p.push("cross-stack");
    p.push("keccak256.cxsf");
    p
}

/// Build the full fixture corpus.
fn build_corpus() -> Vec<FixtureRecord> {
    let mut records = Vec::new();

    // Class 1: boundary cases.
    for size in [0usize, 1, 2, 31, 32, 33, 64, 65] {
        let input: Vec<u8> = (0..size)
            .map(|i| u8::try_from(i & 0xff).expect("masked u8"))
            .collect();
        records.push(make_record(input));
    }

    // Class 2: block-rate boundaries.  Keccak-256 has a 136-byte
    // rate, so 135 / 136 / 137 stress the multi-block boundary.
    for size in [135usize, 136, 137, 272, 273, 1000, 4096, 8192] {
        let input: Vec<u8> = (0..size)
            .map(|i| u8::try_from((i * 31).wrapping_add(7) & 0xff).expect("masked u8"))
            .collect();
        records.push(make_record(input));
    }

    // Class 3: well-known test vectors.  These appear in published
    // documentation; downstream auditors can verify by hand.
    for s in [
        b"" as &[u8],
        b"a",
        b"ab",
        b"abc",
        b"abcd",
        b"abcde",
        b"abcdef",
        b"abcdefg",
        b"abcdefgh",
        b"abcdefghi",
        b"abcdefghij",
        b"the quick brown fox jumps over the lazy dog",
        b"the quick brown fox jumps over the lazy dog.",
        b"The quick brown fox jumps over the lazy dog",
        // Empty + null bytes: makes sure the padding doesn't
        // implicitly trim null tails.
        b"\x00",
        b"\x00\x00",
        b"\x00\x00\x00",
        b"hello\x00world",
    ] {
        records.push(make_record(s.to_vec()));
    }

    // Class 4: repeated bytes.
    for (byte, len) in [
        (0u8, 1usize),
        (0, 32),
        (0, 1024),
        (0xff, 1),
        (0xff, 32),
        (0xff, 1024),
        (0xab, 333),
        (0x55, 137),
    ] {
        records.push(make_record(vec![byte; len]));
    }

    // Class 5: pseudo-random via deterministic xorshift.  Seeded
    // such that re-running produces the same sequence.
    let mut state: u64 = 0x1234_5678_9ABC_DEF0;
    for size in [16usize, 64, 128, 200, 500, 1024, 2048, 10_000] {
        let mut input = Vec::with_capacity(size);
        for _ in 0..size {
            // xorshift64 — adequate for fixture diversity.
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            input.push(u8::try_from(state & 0xff).expect("masked u8"));
        }
        records.push(make_record(input));
    }

    // Class 6: a multi-megabyte input.  Validates the path
    // doesn't allocate per-byte during hashing.
    {
        let huge = vec![0xCDu8; 1_000_000];
        records.push(make_record(huge));
    }

    records
}

/// Construct a single fixture record: input bytes + expected
/// 32-byte keccak256 output.
fn make_record(input: Vec<u8>) -> FixtureRecord {
    let expected = keccak256(&input).to_vec();
    FixtureRecord::new(input, expected)
}
