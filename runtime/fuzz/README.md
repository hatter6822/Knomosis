<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# `knomosis-fuzz` — libFuzzer harness for the untrusted-input boundaries

This crate continuously fuzzes the network / on-chain-feed decoders that
the production security review (`docs/audits/20-…` §4.3) names as the
untrusted-input boundaries — the paths a hostile peer, L1 RPC, or re-org
can hand arbitrary bytes. Each target asserts the load-bearing property

> returns `Ok`/`Err` on **any** input — never panics, aborts,
> over-allocates, or hangs

because an unchecked index / slice / `unwrap` / unbounded allocation on
these paths would be a denial-of-service on the L2 daemons (and, on the
deposit-decode path, potentially a mis-credit).

| Target | Boundary under test | Public entry point |
|--------|---------------------|--------------------|
| `host_read_request` | `knomosis-host` wire-frame reader — the Rung-1 negotiation + v1/v2-hinted request the sequencer reads on every accepted socket | `knomosis_host::frame::read_request` |
| `l1_ingest_decode_event` | `knomosis-l1-ingest` L1-log ABI decoder — biases `topic0` to a real event-signature hash so the deep per-event decode arm (the deposit paths that credit L2 balances) is reached | `knomosis_l1_ingest::events::decode_event` |
| `indexer_decode_event` | `knomosis-indexer` event decoder — the CBE-frame → typed `Event` reconstruction the read model runs on the subscription stream | `knomosis_indexer::decoder::decode_event` |

These are the **nightly-only** counterpart to the stable-toolchain
proptest fuzz that already rides `ci-rust.yml`
(`read_request_never_panics_*`, `decode_event_with_valid_topic0_*`,
`decoder_fuzz_*`): the proptests give a bounded, deterministic,
CI-on-every-PR smoke; libFuzzer gives coverage-guided depth.

## Why a separate workspace

`libfuzzer-sys` needs a **nightly** toolchain plus the LLVM sanitizer
runtime, which the pinned stable `1.83` workspace toolchain
(`runtime/rust-toolchain.toml`) cannot build. So this crate carries its
own (empty) `[workspace]` table and is `exclude`d from
`runtime/Cargo.toml` — the stable gates (`cargo build/test/clippy
--workspace`) never touch it. It is driven only by `cargo +nightly fuzz`
and the dedicated `.github/workflows/ci-fuzz.yml` lane.

## Running locally

```bash
# One-time: a nightly toolchain + the cargo-fuzz driver.
rustup toolchain install nightly --component rust-src
cargo install cargo-fuzz --locked        # pin: 0.13.2 (see ci-fuzz.yml)

# From the runtime workspace root (the dir that contains fuzz/):
cd runtime

cargo +nightly fuzz list                 # the three targets above

# Run one target (Ctrl-C to stop; add -max_total_time=<s> to bound it).
# The committed dictionaries seed the branch-guarding magic bytes (the
# KNH2 preamble / the CBE tag head) so the engine reaches the deep paths.
cargo +nightly fuzz run host_read_request -- -dict=fuzz/dictionaries/host.dict
cargo +nightly fuzz run l1_ingest_decode_event
cargo +nightly fuzz run indexer_decode_event -- -dict=fuzz/dictionaries/indexer.dict

# Just compile every target (the API-drift guard CI runs on every PR):
cargo +nightly fuzz build
```

A finding is written to `fuzz/artifacts/<target>/crash-<hash>` (a
crash / OOM / hang reproducer) and `fuzz/corpus/<target>/` grows the
coverage corpus. Both directories — plus `fuzz/target/` and the
generated `Cargo.lock` — are git-ignored (scratch); only the targets,
the dictionaries, and this manifest are tracked.

### Reproducing a finding

```bash
cargo +nightly fuzz run <target> fuzz/artifacts/<target>/crash-<hash>
```

## CI

`.github/workflows/ci-fuzz.yml`:

* **`fuzz-build`** compiles every target on every PR / push touching
  `runtime/**` — the API-drift guard (a decoder signature change the
  path-pinned targets no longer match fails here).
* **`fuzz-smoke`** runs a bounded libFuzzer session per target (60 s on
  PR / push, 600 s on the weekly `schedule`), seeded by the committed
  dictionaries, with `-timeout` / `-rss_limit_mb` so a hang or
  memory-balloon is a finding, not just a crash. A reproducer is
  uploaded as a build artifact on failure.

## Adding a target

1. Add `fuzz_targets/<name>.rs` with a `fuzz_target!(|…| { … })` body
   that calls the boundary and discards the result.
2. Register it as a `[[bin]]` in `Cargo.toml`.
3. Add it to the `fuzz-smoke` matrix in `ci-fuzz.yml` (with a dictionary
   if the entry point is guarded by magic bytes).
4. Keep the target thin — mirror an existing stable proptest so the
   invariant is also checked deterministically on every PR.
