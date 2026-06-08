<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/dark_logo.png" />
    <source media="(prefers-color-scheme: light)" srcset="assets/light_logo.png" />
    <img src="assets/dark_logo.png" alt="Knomosis logo" width="200" />
  </picture>
</p>

<h1 align="center">Knomosis — A Societal Kernel</h1>

<p align="center">
  <div align="center">
    Created thoughtfully with the help of:
  </div>
  <div align="center">
    claude :robot: :heart: :robot: codex
  </div>
  <div align="center">
    <strong>TREAT THIS KERNEL ACCORDINGLY</strong>
  </div>
</p>

<p align="center">
  <a href="https://github.com/hatter6822/Knomosis/actions/workflows/ci.yml">
    <img alt="Lean CI" src="https://img.shields.io/github/actions/workflow/status/hatter6822/Knomosis/ci.yml?branch=main&label=Lean%20CI" />
  </a>
  <a href="https://github.com/hatter6822/Knomosis/actions/workflows/ci-rust.yml">
    <img alt="Rust CI" src="https://img.shields.io/github/actions/workflow/status/hatter6822/Knomosis/ci-rust.yml?branch=main&label=Rust%20CI" />
  </a>
  <a href="https://github.com/hatter6822/Knomosis/actions/workflows/ci-solidity.yml">
    <img alt="Solidity CI" src="https://img.shields.io/github/actions/workflow/status/hatter6822/Knomosis/ci-solidity.yml?branch=main&label=Solidity%20CI" />
  </a>
  <img alt="Version" src="https://img.shields.io/badge/version-v0.5.4-blue" />
  <img alt="Lean" src="https://img.shields.io/badge/Lean-4.29.1-10b981" />
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0--or--later-informational" />
</p>

Knomosis is a **proof-carrying state-transition kernel** in Lean 4 with mechanically mirrored Solidity (L1) and Rust (host-runtime) implementations. It does not hardcode one economy; it formalizes legality itself as a type-level contract so every accepted state transition is accompanied by machine-checkable evidence.

## What Knomosis guarantees

- **Legality as a type**: transitions carry preconditions and executable witnesses, and `step_impl` refines the specification exactly.
- **Tiny trusted core (TCB)**: only `LegalKernel/Kernel.lean` and `LegalKernel/RBMapLemmas.lean` are trusted kernel files.
- **No custom axioms in kernel reasoning**: kernel theorems reduce to Lean built-ins only (`propext`, `Classical.choice`, `Quot.sound`).
- **Cross-stack determinism discipline**: Lean, Solidity, and Rust are kept aligned through explicit fixture corpora and CI gates.
- **Zero-sorry policy where it matters most**: kernel-adjacent safety checks are continuously audited.

The canonical design specification is [`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md). Day-to-day engineering rules and validation workflow are in [`AGENTS.md`](AGENTS.md) / [`CLAUDE.md`](CLAUDE.md).

## Current state at a glance

| Attribute | Value |
|---|---|
| Version | `v0.5.4` |
| Lean toolchain | `v4.29.1` (pinned in `lean-toolchain`) |
| Build tag | `knomosis-step-vm-coherence` |
| TCB core | `LegalKernel/Kernel.lean`, `LegalKernel/RBMapLemmas.lean` |
| Lean ecosystem dependency policy | Lean core + Std core only in kernel TCB |
| Primary language stacks | Lean 4, Solidity (Foundry), Rust (stable 1.83 in `runtime/`) |

## Architecture overview

Knomosis is organized as one formal source of truth (Lean) plus two deployment mirrors (Solidity and Rust).

```text
Lean 4 kernel (source of truth)
  ├─ LegalKernel/Kernel.lean + RBMapLemmas.lean (TCB)
  ├─ Laws / Authority / Encoding / DSL / Events
  ├─ Bridge / FaultProof / LocalPolicy / Disputes
  └─ Lex language + governance tooling
       ↓ byte-equivalent commitments + fixture-verified behavior
Solidity mirror (L1 contracts)         Rust mirror (host runtime)
  ├─ bridge/fault-proof contracts         ├─ network host, ingest, indexer
  └─ cross-stack test suites              └─ cross-stack verification crates
```

Key repository surfaces:

- Lean kernel and laws: `LegalKernel/`
- Lex language and tools: `Lex/`
- Solidity contracts/tests: `solidity/`
- Rust runtime workspace: `runtime/`
- System plans/audits/specs: `docs/`

## Quick start

### 1) Setup

```bash
# Recommended (verifies toolchain artifacts)
./scripts/setup.sh

# Optional: setup + full Lean build
./scripts/setup.sh --build
```

### 2) Build and test (Lean)

```bash
source ~/.elan/env
lake build
lake test
```

### 3) Required audit gates

```bash
lake exe count_sorries
lake exe tcb_audit
lake exe stub_audit
lake exe naming_audit
lake exe deferral_audit
lake exe lex_lint
lake exe lex_codegen --check
python3 scripts/regenerate_codemaps.py
```

### 4) Runtime smoke test

```bash
.lake/build/bin/knomosis info
.lake/build/bin/knomosis bootstrap /tmp/test.log
.lake/build/bin/knomosis-replay /tmp/test.log
# GP.7.4 worked unified-gas-pool deployment, end-to-end
# (genesis wiring → ETH + BOLD deposits → dual sequencer claim →
#  log persist → replay round-trip):
.lake/build/bin/knomosis gas-pool-demo
```

## Solidity and Rust mirrors

### Solidity (Workstreams E/H)

```bash
cd solidity
./scripts/vendor-deps.sh
forge build
forge test
make test-cross-stack
```

### Rust host runtime (Workstream RH)

```bash
cd runtime
cargo build --workspace --all-targets
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all -- --check
```

## Correctness enforcement model

Knomosis uses layered checks so regressions fail fast:

1. **Elaboration and theorem checking** via `lake build`.
2. **Behavioral regression tests** via `lake test`.
3. **Kernel-integrity gates** (`count_sorries`, `tcb_audit`, `stub_audit`, naming/deferral audits).
4. **Lex governance consistency** (`lex_lint`, `lex_codegen --check`).
5. **Cross-stack verification** in Solidity and Rust test corpora.

CI workflows under `.github/workflows/` run these gates on pull requests.

## Trust assumptions

Knomosis isolates two non-Lean cryptographic/runtime assumptions behind opaque declarations:

1. `Authority.Crypto.Verify`: the configured signature system is EUF-CMA secure.
2. `Runtime.Hash.hashBytes`: the production hash adapter is collision-resistant.

Kernel theorems and replay guarantees are conditional on these assumptions.

## Documentation map

- Project blueprint: [`docs/GENESIS_PLAN.md`](docs/GENESIS_PLAN.md)
- Ethereum integration plan: [`docs/planning/ethereum_integration_plan.md`](docs/planning/ethereum_integration_plan.md)
- Fault-proof migration plan: [`docs/planning/fault_proof_migration_plan.md`](docs/planning/fault_proof_migration_plan.md)
- Workstream-G amendment plan: [`docs/planning/ethereum_workstream_g_plan.md`](docs/planning/ethereum_workstream_g_plan.md)
- Runtime architecture and operations: [`runtime/README.md`](runtime/README.md)
- Solidity package notes: [`solidity/README.md`](solidity/README.md)

## Contributing

1. Read [`AGENTS.md`](AGENTS.md) first (coding, proof, naming, audit, and validation rules).
2. Build the exact module you changed: `lake build LegalKernel.<Module.Path>` (or `Lex.<Module.Path>`).
3. Run project gates before opening a PR (at least `lake test` + required audits).
4. Keep declaration names content-based and stable (no process-tag names like `phaseX`, `_v2`, `tmp`).

## License

Knomosis source code is released under GPL-3.0-or-later. See [`LICENSE`](LICENSE).

Project artwork that incorporates third-party marks/symbols is documented in
[`THIRD_PARTY_ASSETS.md`](THIRD_PARTY_ASSETS.md), including attribution and
license terms for the Ethereum symbol used in the feather logo.
