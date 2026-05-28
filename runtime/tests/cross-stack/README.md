<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Cross-stack fixture corpus

This directory holds the byte-level reference vectors that bind the
Rust host-runtime crates to the Lean kernel.  Each fixture file
(`*.cxsf`) is a [Knomosis Cross-Stack Fixture](#fixture-file-format)
that the Lean side emits and the Rust side consumes via the
`knomosis-cross-stack` dev-dependency
([`runtime/knomosis-cross-stack/src/lib.rs`](../../knomosis-cross-stack/src/lib.rs)).

## Why this directory exists

The Knomosis project has two byte-level-equivalent implementations of
several primitives:

  * **Hash function** — Lean's `LegalKernel/Runtime/Hash.lean` plus
    the deployment-supplied `knomosis_hash_*` symbols (RH-A.2's Rust
    crate).
  * **ECDSA verifier** — Lean's `LegalKernel/Authority/Crypto.lean`
    plus the deployment-supplied `knomosis_verify_ecdsa` symbol (RH-A.1's
    Rust crate).
  * **Action / Verdict encoding** — Lean's `LegalKernel/Encoding/*.lean`
    plus the Rust `knomosis-host` / `knomosis-l1-ingest` wire-format
    consumers.
  * **Bisection-game state machine** — Lean's
    `LegalKernel/FaultProof/Game.lean` plus the Rust
    `knomosis-faultproof-observer` mirror.

Byte-equality across these stacks is the load-bearing contract.  The
fixtures in this directory are the *machine-checkable* statement of
that contract: a sequence of `(input, expected)` pairs where the
expected output is whatever the Lean side produces, and the Rust
crates' tests assert their implementations match.

## Fixture file format

Each fixture file is a binary `.cxsf` (Knomosis Cross-Stack Fixture)
record.  The byte layout is documented in
[`knomosis-cross-stack/src/lib.rs`](../../knomosis-cross-stack/src/lib.rs);
the headline points:

  * 16-byte header: `"CXSF"` magic, format version, kind tag, record
    count.
  * Each record: `(u32 BE input-length, input bytes, u32 BE
    expected-length, expected bytes)`.
  * Magic / version mismatches return typed errors; truncated
    records return typed errors; oversize records (> 16 MiB) return
    typed errors.

The format is intentionally a thin framing layer over opaque
payloads: the inner bytes are usually CBE-encoded but the loader
does not parse them.  Byte-equality is the contract.

## Currently shipped fixtures

| File | Kind | Generator | Consumer |
|------|------|-----------|----------|
| `ecdsa_secp256k1.cxsf` | `Ecdsa` | `knomosis-verify-secp256k1`'s `examples/gen_ecdsa_fixtures.rs` | `knomosis-verify-secp256k1`'s `tests/cross_stack.rs` |
| `keccak256.cxsf` | `Hash` | `knomosis-hash-keccak256`'s `examples/gen_keccak256_fixtures.rs` | `knomosis-hash-keccak256`'s `tests/cross_stack.rs` |
| `l1_ingest.cxsf` | `L1Ingest` | `knomosis-l1-ingest`'s `examples/gen_ingest_fixtures.rs` | `knomosis-l1-ingest`'s `tests/cross_stack.rs` |
| `l1_ingest_fee_split.cxsf` | `L1IngestFeeSplit` | `knomosis-l1-ingest`'s `examples/gen_fee_split_fixtures.rs` | `knomosis-l1-ingest`'s `tests/cross_stack_fee_split.rs` |

Each downstream work unit's fixtures are committed alongside the
implementing PR.  See
[`docs/planning/rust_host_runtime_plan.md`](../../../docs/planning/rust_host_runtime_plan.md)
§4 for the per-WU corpus specifications.

### Fixture-kind details

  * **`Ecdsa`** (RH-A.1) — 210 records.  `(input bytes = (33-byte
    pubkey ‖ 32-byte message ‖ 64-byte signature), expected =
    1-byte verification verdict)`.
  * **`Hash`** (RH-A.2) — 51 records.  `(input bytes, expected =
    32-byte keccak-256 digest)`.
  * **`L1Ingest`** (RH-B) — 12 records.  `(input bytes = encoded
    (IngestedEvent, AddressBook snapshot, current_nonce), expected
    = 1-byte discriminator (0 = None, 1 = Some) followed by the
    CBE-encoded Action plus signer / nonce for the `Some` branch)`.
  * **`L1IngestFeeSplit`** (GP.6.1) — 248 records.  `(input bytes =
    fixed 58-byte FeeSplitInput tuple (msg_value, chosen_fee_bps,
    wei_per_budget_unit, resource_id, recipient, pool_actor,
    deposit_id), expected = CBE-encoded
    `Action::DepositWithFee` bytes)`.  Sweeps over the
    operator-relevant fee-split parameter space (6 fee values × 5
    msg.value magnitudes × 4 exchange-rate magnitudes × 2
    resource ids = 240 grid entries plus 8 boundary cases).
    Pins the GP-family encoder's byte-equivalence with the Lean
    reference.

## Generating new fixtures

Fixture generation is a Lean-side responsibility: the Lean test
harness runs the canonical primitive over the input corpus,
writes the `(input, expected)` pair stream out in the
[fixture file format](#fixture-file-format), and commits the
resulting `.cxsf` file to this directory.

The Lean-side generator entry-point is added by the implementing
work unit — for RH-A.2 it'll live near
`LegalKernel/Test/Encoding/*` with a small Rust-side
`gen-fixtures` binary that wraps the Lean output.

## Consuming fixtures from a Rust crate

```rust
use knomosis_cross_stack::{FixtureFile, FixtureKind};

#[test]
fn cross_stack_keccak256() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../tests/cross-stack/keccak256_inputs.cxsf"
    );
    let fixture = FixtureFile::load(path).expect("fixture present");
    assert!(matches!(fixture.kind(), FixtureKind::Hash));

    for record in fixture.records() {
        let actual = my_keccak256(&record.input);
        assert_eq!(actual, record.expected.as_slice());
    }
}
```

The dev-dep declaration in the consumer's `Cargo.toml`:

```toml
[dev-dependencies]
knomosis-cross-stack = { workspace = true }
```

## What this directory is **not**

  * **Not a Cargo test target.** The fixtures here are *data*; the
    tests that consume them live inside each member crate's
    `tests/` directory.
  * **Not a substitute for fresh fixture generation.** When the Lean
    primitive changes, the fixtures get regenerated — committing a
    Rust implementation against stale fixtures is a CI failure.
