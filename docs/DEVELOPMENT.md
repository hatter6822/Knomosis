<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Knomosis — Developer Guide (`DEVELOPMENT.md`)

This document is the **end-to-end developer handbook** for Knomosis: how to
provision a working environment, the day-to-day build/test/audit loop for each
language stack, the conventions every change must follow, and the path a change
takes from local edit to merged pull request.

## 1. About this document

Knomosis is a **proof-carrying state-transition kernel** written in Lean 4, with
mechanically mirrored **Solidity** (L1 contracts) and **Rust** (host-runtime)
implementations, plus **Python** developer tooling. Because correctness here is
*mechanised* — guaranteed by Lean theorems and a battery of CI gates rather than
by convention — the development workflow is unusually strict. This guide exists
so that strictness is **predictable**: if you follow it, your change will pass
CI on the first try.

### How this fits with the other canonical documents

Knomosis keeps a deliberate separation of ownership between its top-level
documents. Read this one for *workflow*; defer to the others where they own a
topic:

| Document | Owns | Read it when |
|----------|------|--------------|
| [`GENESIS_PLAN.md`](GENESIS_PLAN.md) | The design: formal model, threat model, phase roadmap. **Authoritative — wins all conflicts.** | Before starting any new feature or workstream. |
| [`../CLAUDE.md`](../CLAUDE.md) / [`../AGENTS.md`](../AGENTS.md) | Engineering conventions and the agent/developer rulebook. (Byte-identical twins.) | For the canonical statement of any rule summarised here. |
| [`../README.md`](../README.md) | The top-level project introduction and quick start. | For a first-contact overview. |
| **`DEVELOPMENT.md`** (this file) | The practical, expanded developer workflow. | Day to day, for setup, the inner loop, and the PR path. |
| [`../runtime/README.md`](../runtime/README.md) / [`../solidity/README.md`](../solidity/README.md) | Stack-specific deep dives. | When working inside `runtime/` or `solidity/`. |

> **Precedence.** Where this guide and `CLAUDE.md` appear to disagree, `CLAUDE.md`
> is authoritative for conventions; where `CLAUDE.md` and the Genesis Plan
> disagree, the **Genesis Plan wins**. This document never introduces a *new*
> rule — it expands and operationalises the rules those documents already set.

## 2. At a glance

| Attribute | Value |
|-----------|-------|
| Project version | `v0.7.0` (Lean + Rust in lockstep) |
| Build tag | `knomosis-step-vm-coherence` (`kernelBuildTag` in `LegalKernel.lean`) |
| Lean toolchain | `leanprover/lean4:v4.29.1` (pinned in [`../lean-toolchain`](../lean-toolchain)) |
| Rust toolchain | stable **1.83** (pinned in `runtime/rust-toolchain.toml`; MSRV `1.83`) |
| Solidity toolchain | Foundry **v1.7.0** + solc **0.8.20** (`evm_version = shanghai`, `via_ir`, `optimizer_runs = 200`) |
| Vendored Solidity deps | OpenZeppelin **v5.0.2**, forge-std **v1.9.4** |
| Kernel TCB | `LegalKernel/Kernel.lean`, `LegalKernel/RBMapLemmas.lean` (Lean core + Std core only) |
| Kernel axioms | exactly `propext`, `Classical.choice`, `Quot.sound` — **no custom axioms** |
| License | GPL-3.0-or-later |

**The single command that provisions everything:**

```bash
./scripts/setup.sh            # idempotent: Lean + Solidity toolchains, SHA-256 verified
source ~/.elan/env            # put lean/lake on PATH for the current shell
```

**The three canonical "did I break anything?" queries:**

```bash
lake test                                   # Lean — ~3 050 tests across ~150 suites
(cd runtime  && cargo test --workspace)     # Rust — ~1 960 tests across 11 crates
(cd solidity && forge test)                 # Solidity — ~867 tests across 58 suites
```

## 3. Repository topology

Knomosis is **one formal source of truth (Lean) plus two deployment mirrors
(Solidity, Rust)**, glued together by cross-stack fixture corpora that prove the
three stacks agree byte-for-byte.

```text
Lean 4 kernel (source of truth)
  ├─ LegalKernel/Kernel.lean + RBMapLemmas.lean   ← the Trusted Computing Base
  ├─ Laws / Authority / Encoding / DSL / Events
  ├─ Bridge / FaultProof / LocalPolicy / Disputes
  └─ Lex language + governance tooling
        │  byte-equivalent commitments + fixture-verified behaviour
        ▼
Solidity mirror (L1 contracts)          Rust mirror (host runtime)
  solidity/ : bridge, fault-proof,        runtime/ : network host, L1 ingest,
              dispute, AMM contracts                  indexer, observer, crypto adaptors
```

| Path | Stack | What lives here |
|------|-------|-----------------|
| `LegalKernel/` | Lean | Kernel (TCB), laws, authority, encoding, bridge, fault-proof, disputes, runtime, tests |
| `Lex/` | Lean | The Lex programming language (DSL macros, audit tools, codegen inputs) |
| `Deployments/` | Lean | Worked example deployments |
| `Tools/` | Lean | Non-Lex audit binaries + shared `Tools.Common` library |
| `Main.lean`, `Replay.lean`, `Tests.lean` | Lean | The `knomosis` CLI, the `knomosis-replay` audit binary, the `lake test` driver |
| `runtime/` | Rust | 11-crate Cargo workspace (host runtime + crypto adaptors + observers) |
| `solidity/` | Solidity | 11 contracts + 7 libraries + 7 interfaces (Foundry project) |
| `scripts/` | Bash/Python | `setup.sh`, codemap regen, cross-stack orchestration, economic simulation |
| `codemaps/` | JSON | Generated per-language navigation maps (a CI gate) |
| `docs/` | Markdown | The Genesis Plan, planning docs, audits, runbooks, and this guide |
| `.github/workflows/` | YAML | Five CI workflows (one per stack + two cross-stack) |

The per-file purpose is documented in each file's own `/-! … -/` module
docstring; it is intentionally **not** duplicated across documents.

## 4. Prerequisites

Knomosis targets **Linux** and **macOS** (x86-64 and arm64). The setup script
is written for both; CI runs on `ubuntu-latest`.

**You must have, before running setup:**

- `bash`, `curl`, `git`, and a C toolchain (`cc`/`clang` + system `libc-dev`):
  Lean's compiler links native code, so the C runtime startup objects
  (`crti.o`, `crt1.o`) must be present. `setup.sh` will attempt to repair a
  toolchain missing these, but a working host compiler is assumed.
- `sha256sum` **or** `shasum` (every download is checksum-verified).
- For the optional Solidity stack: nothing extra — `setup.sh` installs Foundry
  and solc for you.
- For the Rust stack: `rustup` (the base container image ships it; otherwise
  install from <https://rustup.rs>). The pinned 1.83 channel is auto-resolved
  from `runtime/rust-toolchain.toml`.

**Disk / network.** A full three-stack setup downloads the Lean toolchain
(~hundreds of MB extracted), Foundry, solc, and the Rust crate cache. All
downloads are SHA-256-pinned; an outbound network policy must permit
`github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`,
`index.crates.io`, and `static.crates.io` (see
[§5.7](#57-remote--claude-code-on-the-web-environments)).

**Editor.** Any editor works, but the Lean experience is best with the official
**Lean 4 VS Code extension** (or the JetBrains/Emacs/Neovim LSP clients). The
language server consumes the same `lake`-built `.olean` files as the CLI, so a
warm `lake build` makes the editor responsive. Lean editor scratch files
(`*.olean`, `*.ilean`, `.vscode/`, `.idea/`) are git-ignored.

## 5. Environment setup

### 5.1 One-command setup (recommended)

```bash
./scripts/setup.sh            # idempotent; installs Lean + Solidity toolchains
./scripts/setup.sh --build    # ...then runs a full all-targets lake build
./scripts/setup.sh --quiet    # suppress informational logs (errors still print)
```

This is the **canonical, SHA-256-verified** path. It is safe to re-run: every
already-present, hash-verified artefact is fast-pathed (~50 ms), so it doubles
as a "is my environment still intact?" check.

### 5.2 What `setup.sh` does, and its integrity model

The script is deliberately security-hardened — the toolchain *is* part of the
trust story:

1. Reads [`../lean-toolchain`](../lean-toolchain) to learn the pinned Lean
   release (`leanprover/lean4:v4.29.1`).
2. **Fast-path:** if the toolchain is already installed *and* the on-disk
   `bin/lean` / `bin/lake` content hashes match the snapshot recorded at install
   time (`.bin_sha256.lock`), it skips straight to the Solidity step. A hash
   mismatch is treated as **fatal** (possible post-install tampering): the
   script refuses to proceed and tells you to `rm -rf` the toolchain directory
   and re-run, which re-downloads from a checksum-verified archive.
3. Otherwise it downloads the toolchain archive **from the GitHub release** (not
   an unauthenticated mirror) and verifies its SHA-256 against the per-arch pin
   baked into the script.
4. Installs `elan` (also SHA-256-pinned to a specific commit, never `master`) so
   you can switch toolchains later.
5. Installs the Solidity toolchain: Foundry v1.7.0 + solc 0.8.20 (each
   checksum-pinned) and vendors OpenZeppelin + forge-std via
   `solidity/scripts/vendor-deps.sh`.
6. Records the binary-integrity snapshot for step 2's future fast-paths.

Every pinned URL/version has a matching SHA-256 constant; **bumping any version
requires recomputing its checksum in the same commit** (the regeneration
commands are documented inline in the script next to each constant).

### 5.3 `setup.sh` flags

| Flag | Effect |
|------|--------|
| *(none)* | Install **both** the Lean and Solidity toolchains. |
| `--build` | After setup, build every Lake target (warms the full build cache). |
| `--quiet` / `-q` | Suppress informational logs. |
| `--skip-solidity` | Lean-only setup (no Foundry/solc). |
| `--solidity-only` | Only install Foundry/solc/vendored deps (skip Lean). |
| `-h` / `--help` | Print usage. |

> The Rust toolchain is **not** installed by `setup.sh` — `cargo` resolves the
> pinned 1.83 channel automatically from `runtime/rust-toolchain.toml` on first
> use. The web SessionStart hook additionally runs `cargo fetch --locked` to
> warm the registry cache (see §5.7).

### 5.4 Activating the toolchains in your shell

After setup, make the tools visible in your current shell:

```bash
source ~/.elan/env                          # lean, lake, leanc, leanmake
export PATH="/usr/local/foundry/bin:$PATH"  # forge, cast, anvil, chisel
# cargo / rustup are at ~/.cargo/bin (add to PATH if not already there)
```

Add the `source ~/.elan/env` line to your shell profile for persistence. On the
web/remote environment this is handled for you by the SessionStart hook.

### 5.5 Per-stack manual setup (when you skip `setup.sh`)

If you must bypass the verified installer (you generally should not):

```bash
# Lean toolchain (skips integrity verification):
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none
elan toolchain install "$(cat lean-toolchain)"

# Solidity (from solidity/):
cd solidity && ./scripts/vendor-deps.sh     # one-time OZ + forge-std vendoring

# Rust (from runtime/):
cd runtime && cargo fetch --locked          # warm the crate cache
```

### 5.6 Verifying the installation

```bash
source ~/.elan/env
lake --version            # expect a Lean 4 / Lake banner
lake build                # build the default LegalKernel library
lake test                 # run the full Lean test driver
.lake/build/bin/knomosis info   # runtime CLI smoke test

(cd runtime  && cargo build --workspace --all-targets && cargo test --workspace)
(cd solidity && forge build && forge test)
```

A green `lake test` + `cargo test --workspace` + `forge test` means you are
ready to develop.

### 5.7 Remote / Claude-Code-on-the-web environments

When running in the managed web/remote execution environment, the container is
**ephemeral and freshly cloned** — anything not committed and pushed is lost
when the container is reclaimed. A [SessionStart hook](../.claude/hooks/session-start.sh)
(registered in [`../.claude/settings.json`](../.claude/settings.json)) runs
**before** the first tool call and provisions all three stacks synchronously, so
`lake`, `forge`, and `cargo` are immediately usable:

- Runs `scripts/setup.sh --quiet` (Lean + Solidity, hash-verified, idempotent).
- Persists `PATH` (Foundry, cargo, elan env) into the session env file.
- Runs `cargo fetch --locked` to warm the Rust registry cache.

The environment's **network policy** (chosen when the environment was created)
governs outbound access; the toolchain hosts above must be permitted. The
options, triggers, and configuration are documented at
<https://code.claude.com/docs/en/claude-code-on-the-web>.

## 6. The Lean inner development loop

[`../lakefile.lean`](../lakefile.lean) is the **single source of truth** for
every build target, executable, and `lean_lib`. Consult it before adding a new
target. Every library and executable is marked `@[default_target]`, so a bare
`lake build` compiles *every* first-party module — no module's warnings can hide.

### 6.1 Module-level build verification (mandatory)

Before committing any `.lean` file, build the **specific module** you touched —
this is the fastest feedback loop and is required by project convention:

```bash
lake build LegalKernel.<Module.Path>     # e.g. lake build LegalKernel.Laws.Transfer
lake build Lex.<Module.Path>             # for Lex DSL / tools / examples / tests
```

### 6.2 Whole-project build & test

```bash
lake build                       # default target (the LegalKernel library)
lake test                        # the @[test_driver] in Tests.lean — full suite
```

`lake test` is the canonical Lean regression query. It catches semantic
regressions that elaboration-only checks miss. **Every change must pass both
`lake build` and `lake test`** before it is committed (this is a hard rule, and
CI enforces it).

> **Strict linters are on, project-wide** (set in `lakefile.lean`):
> `autoImplicit := false`, `relaxedAutoImplicit := false`,
> `linter.unusedVariables := true`, `linter.missingDocs := true`. CI fails the
> build on **any** Lean `warning:` line — including a missing docstring on a
> public surface or an unused binding. Treat warnings as errors locally.

### 6.3 The kernel-integrity audit gates

After any source change, run the relevant gates. These are real `lean_exe`
binaries (so they are themselves type-checked) that mechanically enforce the
project's invariants. CI (`.github/workflows/ci.yml`) runs **all** of them on
every PR; running them locally first saves a round-trip.

```bash
lake exe count_sorries        # zero-sorry gate for kernel-adjacent modules
lake exe tcb_audit            # TCB import-allowlist gate
lake exe stub_audit           # placeholder-stub detection
lake exe naming_audit         # content-name discipline (no provenance tokens)
lake exe deferral_audit       # no-deferrals policy
lake exe mock_import_audit    # no Test/* import in production modules
lake exe lex_lint             # Lex action-index registry + sidecar discipline
lake exe lex_codegen --check  # Lex codegen-consistency (committed == generated)
python3 scripts/regenerate_codemaps.py   # regenerate navigation maps (CI gate)
```

| Gate | What it enforces | What trips it | Allowlist |
|------|------------------|---------------|-----------|
| `count_sorries` | No `sorry` in **proof position** in kernel-adjacent files: `Kernel.lean`, `RBMapLemmas.lean`, `Laws/Transfer.lean` (the `Tools.Common.kernelTcbFiles` set). Masks comments, block comments, strings. | Any `sorry` reaching those files. | — (absolute) |
| `tcb_audit` | The TCB-core files import only modules on [`../tcb_allowlist.txt`](../tcb_allowlist.txt) (currently just `Std.Data.TreeMap`) plus the two TCB files themselves. | An un-allowlisted import in `Kernel.lean` / `RBMapLemmas.lean`. | `tcb_allowlist.txt` (editing it is a §13.6 TCB expansion → two reviewers) |
| `stub_audit` | No placeholder body (`:= ByteArray.empty`, `:= []`, …) paired with a red-flag docstring token (`stub`, `placeholder`, `TODO`, `wire`, …). | The historical `signingInput := ByteArray.empty` class of regression. | `tools/stub_allowlist.txt` |
| `naming_audit` | "Names describe content, never provenance." Scans file names + declaration identifiers for forbidden tokens (`wu1`, `phase0`, `audit`, `f02`, `_v2`, `_old`, `_tmp`, `_todo`, `claude_`, `session_`, …). | A provenance/process token in any identifier or filename. | `tools/naming_allowlist.txt` |
| `deferral_audit` | No-deferrals policy: ship the proof or don't ship the theorem. Scans docstrings/comments for `DEFERRED`, `PARTIAL`, `TODO:`, `FIXME:`, `not yet provable`, etc. | Any deferral marker under `LegalKernel/` or `Tools/`. | **none** — fix it or rewrite the comment |
| `mock_import_audit` | No production module imports a `*.Test.*` module. | `import LegalKernel.Test.*` (etc.) from a production root. | — |
| `lex_lint` | The frozen Lex action-index registry (`Lex/IndexRegistry.txt`) is well-formed, append-only, strictly increasing, and consistent with the codegen-input sidecars under `Lex/Inputs/`. | Registry corruption or a sidecar/registry mismatch. | — |
| `lex_codegen --check` | The committed cross-module artefacts (e.g. `Authority/Action.lean`) match what codegen would regenerate, byte-for-byte. | Editing a generated fence by hand, or forgetting to re-run `lake exe lex_codegen`. | — |
| codemap gate | `codemaps/{lean,solidity,rust}/codemap.json` are in sync with tracked source. | A source change without a `regenerate_codemaps.py` re-run. | — |

> **On allowlists.** The `stub_allowlist.txt` / `naming_allowlist.txt` /
> `deferral_allowlist.txt` files hold rare, explicitly-reviewed exceptions; they
> are empty (absent) by default, which is the desired state. Reach for an
> allowlist entry only when the gate has a genuine false positive — and expect a
> reviewer to question it. The correct fix is almost always to change the code,
> not the allowlist (see [§11.7](#117-the-implement-the-improvement-rule)).

### 6.4 Recommended fast-feedback ordering

Order your local loop from cheapest to most expensive so failures surface early:

1. `lake build LegalKernel.<Module>` — the module you just edited (seconds).
2. `lake build` — the whole project (catches downstream breakage + warnings).
3. `lake test` — semantic regressions.
4. The audit gates that touch your change (always `count_sorries` + `tcb_audit`
   for kernel-adjacent work; `naming_audit` + `deferral_audit` for any new
   declarations; `lex_lint` + `lex_codegen --check` for Lex changes).
5. `python3 scripts/regenerate_codemaps.py` — last, then commit the result.

## 7. The Rust workflow (`runtime/`)

The Rust workspace materialises Knomosis's deployment-supplied substrates
(crypto adaptors, L1 watcher, fault-proof observer) and host services. Its
design deep-dive is [`../runtime/README.md`](../runtime/README.md) and
[`planning/rust_host_runtime_plan.md`](planning/rust_host_runtime_plan.md).

Run all four gates from `runtime/` before pushing any Rust change — they mirror
`.github/workflows/ci-rust.yml` exactly:

```bash
cd runtime
cargo fmt --all -- --check                              # style gate (run first)
cargo build --workspace --all-targets --locked          # compile gate
cargo test --workspace --locked                          # ~1 960 tests, 11 crates
cargo clippy --workspace --all-targets --locked -- -D warnings   # every lint is an error
```

Workspace conventions:

- **Pinned channel:** stable 1.83 in `runtime/rust-toolchain.toml`; MSRV `1.83`
  in `runtime/Cargo.toml` `[workspace.package]`. Bumping the channel is a
  workspace-level PR — sub-streams cannot silently drift it.
- **`--locked`** everywhere: builds use exactly the committed `Cargo.lock`
  (which **is** committed — these are reproducible binaries). A dependency bump
  must regenerate and commit `Cargo.lock`.
- **`unsafe_code = "forbid"`** by default; crates with a genuine FFI boundary
  (the crypto adaptors) relax to `"deny"` and keep `unsafe` minimal.
- **`clippy::pedantic`** workspace-wide; `missing_docs` is a rustc-level lint
  promoted to error by `-D warnings`.
- Centralised dependency versions live in `[workspace.dependencies]`; member
  crates reference them with `dependency.workspace = true`.

The Rust CI workflow is **path-filtered** to `runtime/**` (plus one shared
fixture), so Lean-only PRs do not trigger it. To regenerate a cross-stack
fixture corpus, use the per-crate `examples/gen_*` generators (deterministic;
commit the resulting `.cxsf` files) — see `runtime/README.md`.

## 8. The Solidity workflow (`solidity/`)

The Solidity tree is the **L1 mirror** of the kernel: 11 immutable contracts, 7
libraries, 7 interfaces. Its deep-dive is
[`../solidity/README.md`](../solidity/README.md); design rationale is in
[`planning/ethereum_integration_plan.md`](planning/ethereum_integration_plan.md)
and the fault-proof / SMT / step-VM plans.

```bash
cd solidity
./scripts/vendor-deps.sh        # one-time: vendor OZ v5.0.2 + forge-std v1.9.4
forge build
forge test                      # ~867 tests across 58 suites
make test-cross-stack           # CrossCheck/ only (Lean ↔ Solidity equivalence)
make audit-caps                 # GP.5.2 constitutional fee-split-cap gate
make audit-caps-selftest        # proves the cap gate actually trips
make snapshot-gas-check         # GP.11.9 gas-benchmark regression gate
make snapshot-gas               # regenerate the gas baseline + runbook table
make testnet-acceptance-dryrun  # in-memory deploy dry-run
```

`solidity/foundry.toml` pins `solc 0.8.20`, `evm_version = shanghai`,
`via_ir = true` (required: a few functions are stack-too-deep without it), and
`optimizer_runs = 200`. CI's `forge` job uses `FOUNDRY_PROFILE=ci` so fuzz tests
run at 1000 iterations instead of the local default.

**Immutability discipline (enforced by tests).** Every contract is deployed
immutably — no proxy, no `initialize`, no generic admin role, no `pause()`.
Whole-system halts use automatic, public-predicate circuit breakers; recovery is
via the dispute pipeline / fault-proof game, not via code. A
`test_no_admin_surface` assertion on every contract confirms admin selectors
(`pause()`, `transferOwnership(...)`, `upgradeTo(...)`, …) are not callable. Keep
new contracts inside this discipline.

**Constitutional caps.** Fee-split and AMM caps (`MAX_FEE_BPS_CAP`, etc.) are
protected by a dual layer: a source-level grep gate (`make audit-caps`, runs
without a toolchain) and a runtime pin (`test_compileTimeCaps_pinned`). Changing
a cap is a Genesis-Plan §13.6 amendment (two reviewers) and must update the
gate's `CAPS` table in the same PR.

**Gas baseline.** `make snapshot-gas-check` re-runs the deterministic
`BenchmarkGasV1_3` suite under forge `--isolate` and fails on any per-benchmark
gas **increase** beyond 5% over the committed baseline, on benchmark-set drift,
or on a stale runbook table. A deliberate gas change runs `make snapshot-gas`
(regenerates baseline **and** the runbook §9.2 table together) in the same PR.

## 9. Python tooling

Two first-party Python scripts; both run on stdlib only (no `pip install`):

```bash
python3 scripts/regenerate_codemaps.py   # regenerate codemaps/*/codemap.json (CI gate)
python3 scripts/economic_simulation.py   # IC-1..IC-6 economic-incentive simulation
```

- **`regenerate_codemaps.py`** is deterministic — it reads only tracked source
  (`git ls-files`) and source-independent metadata, runs a built-in self-test of
  its masker/extractor, and is byte-identical on any checkout. Run it before
  every PR and commit the result; CI re-runs it and fails on any diff. See
  [`../codemaps/README.md`](../codemaps/README.md) for the schema.
- **`economic_simulation.py`** is a self-asserting quantitative companion to
  [`economic_incentive_analysis.md`](economic_incentive_analysis.md).

## 10. Cross-stack verification & deploy-readiness gates

The load-bearing contract between the three stacks is **byte-equality**. Two
orchestration scripts and two deploy gates make this checkable.

### 10.1 Keccak-linked cross-stack verification

By default the Lean kernel is **hash-agnostic**: `Runtime.Hash.hashBytes` is an
`@[extern]` swap-point whose default body is a dependency-free FNV-1a-64
fallback, so `lake build`/`lake test` run with no Rust/keccak dependency, and
keccak-gated cross-stack assertions are skipped (`isKeccak256Linked = false`).
To close the loop and prove Lean's hashing equals the EVM's `keccak256`
byte-for-byte:

```bash
./scripts/verify_keccak_crossstack.sh    # links the real keccak adaptor, regenerates
                                         # corpora with isKeccak256Linked = true,
                                         # runs the Solidity consumers, restores defaults
```

This needs all three toolchains, which is why it is its own CI workflow
(`ci-keccak-crossstack.yml`), not a step in `ci.yml`.

### 10.2 Production verifier link proof

```bash
./scripts/verify_secp256k1_link.sh           # build + record + prove the production flip
./scripts/verify_secp256k1_link.sh --check    # build + verify the staticlib SHA-256 snapshot
```

Proves that linking the real secp256k1 adaptor flips `verify-check` from
fallback (exit 1) to production (exit 0). Mirrored by CI's
`ci-verify-secp256k1.yml`.

### 10.3 Deploy-readiness gates (F-1 / F-2) — fail-closed by design

The default build links **non-production fallbacks** for the two non-Lean trust
primitives, and two CLI gates assert this loudly so a fallback can never reach
production silently:

```bash
.lake/build/bin/knomosis hash-check     # F-1: exit 1 on the FNV-1a-64 fallback hash
.lake/build/bin/knomosis verify-check   # F-2: exit 1 on the Lean-opaque verifier fallback
```

Both **must exit non-zero on the default build** — `ci.yml` asserts exactly this
fail-closed property. They flip to exit 0 only when a production BLAKE3/keccak
hash and the secp256k1 adaptor are `@[extern]`-linked (and, for `verify-check`, a
functional self-test on a known secp256k1 vector passes).

### 10.4 Runtime smoke tests

```bash
.lake/build/bin/knomosis info
.lake/build/bin/knomosis bootstrap /tmp/test.log
.lake/build/bin/knomosis-replay /tmp/test.log     # reproduces the final StateHash
.lake/build/bin/knomosis gas-pool-demo            # end-to-end unified-gas-pool deployment
.lake/build/bin/knomosis extract-events --log /tmp/test.log < /dev/null
```

The on-disk frame formats and the full CLI ABI are specified in
[`abi.md`](abi.md).

## 11. Coding conventions

These are the rules every change is held to. The canonical statement lives in
[`../CLAUDE.md`](../CLAUDE.md); this section operationalises them.

### 11.1 The Trusted Computing Base (TCB)

Only **two files** are trusted kernel core: `LegalKernel/Kernel.lean` and
`LegalKernel/RBMapLemmas.lean`. Everything else is non-TCB,
deployment-facing infrastructure. The TCB equals exactly *Lean core + Std core*
— no Mathlib, no batteries, no external Lake package.

- **Two-reviewer rule (absolute).** Any change to `Kernel.lean` or
  `RBMapLemmas.lean` requires **two** reviewers (Genesis Plan §13.6). Law
  modules and tests require one. [`../.github/CODEOWNERS`](../.github/CODEOWNERS)
  auto-requests reviewers for TCB-core files, `tcb_allowlist.txt`,
  `Tools/Common.lean`, the workflows, `lakefile.lean`, and the Genesis Plan.
- Expanding the TCB's import set (editing `tcb_allowlist.txt`) is itself a §13.6
  amendment and must update [`std_dependencies.md`](std_dependencies.md) in the
  same PR.

### 11.2 No `sorry`, no custom axioms (absolute)

- **No `sorry`** in proof position in kernel-adjacent files — `count_sorries`
  blocks the merge.
- **No custom `axiom` declarations.** The kernel may use only Lean's built-ins:
  `propext`, `Classical.choice`, `Quot.sound`. `#print axioms` on any kernel
  theorem must return a subset of those three. Non-Lean assumptions are exposed
  as `opaque` declarations (`Verify`, `hashBytes`, `l1FaultProofVerifier`), never
  as axioms, so the axiom set stays pristine. Adding an `axiom` is a Genesis-Plan
  amendment and triggers the two-reviewer gate.

### 11.3 Naming discipline

**Names describe content, never provenance.** Forbidden tokens in declaration
names and filenames: `wu`, `phase`, `audit`, `finding`, `f02`, `claude_`,
`session_`, `old`, `new`, `v2`, `legacy`, `tmp`, `todo`, `fixme`. Process markers
belong in docstrings and commit messages — never in identifiers. The
`naming_audit` gate enforces this; you can pre-check a staged diff with:

```bash
git diff --cached -U0 -- '*.lean' \
  | grep -E '^\+(def|theorem|structure|class|instance|abbrev|lemma|noncomputable)' \
  | grep -iE 'workstream|\bws[0-9]|\bwu[0-9]|\bphase[0-9_]|audit|\bf[0-9]{2}\b|\btmp\b|\btodo\b|\bfixme\b|claude_|session_|_v[2-5]\b'
```

A non-empty result is a review-blocking violation.

Other naming rules:

- Theorems / lemmas: `snake_case` (`impl_refines_spec`).
- Structures / types: `CamelCase` (`Transition`, `Legal`).
- Type variables `α β γ`; states `s`, `s'`; transitions `t`.
- Hypotheses are `h`-prefixed (`hpre`, `hreach`, `h_init`).
- Namespaces: `LegalKernel`, `LegalKernel.Laws`, `LegalKernel.Test`, ….

### 11.4 Proof style

- Prefer tactic mode (`by …`) for non-trivial proofs.
- Use `calc` blocks for equational chains; `have` for named intermediate steps.
- Comment the proof strategy at the top of each non-obvious theorem.
- Avoid `decide` on large finite types (a performance trap).

### 11.5 Documentation & docstrings

- Every `.lean` file begins with a `/-! … -/` module docstring naming the
  Genesis-Plan section it implements.
- Every public `def` / `theorem` / `structure` / `instance` has a `/-- … -/`
  docstring (`linter.missingDocs` makes this a build-time requirement).
- Where a definition tracks a Genesis-Plan section, say so in the docstring.

### 11.6 Decidability discipline (§13.6)

Every `Transition.decPre` field should be definable as
`fun _ => inferInstance` whenever the precondition is built from arithmetic
comparisons, `Nat` operations, and finite conjunctions. See
[`decidability_discipline.md`](decidability_discipline.md) and the worked
`transfer` law (`decPre := fun _ => inferInstance`).

### 11.7 The implement-the-improvement rule

This is the project's most distinctive convention, and it is **mandatory**.

> When any reading of the codebase surfaces a gap between the **code** and the
> **documentation / docstring / comment / type signature / design intent** that
> describes it — and the description is the *better* artefact (a more complete
> behaviour, a stronger invariant, a routed dispatch where the code stubs, an
> API that "should" exist) — the remediation is **always to implement the
> improvement so the description becomes true.**

It is **forbidden** to weaken, dilute, or rewrite documentation to match
inferior code. Concretely: a comment referencing a function `X` that doesn't
exist → *implement `X`*; a stub returning `NotImplemented` where the design says
route to a verified entry point → *wire up the routing*; an invariant maintained
only by convention → *enforce it structurally*. The single legitimate exception
is when the documentation describes a *worse* state than the code (e.g. a stale
`STATUS` marker) — there, updating the docs to match the better code is correct.

In-source `TODO`/`FIXME` are not how debt is tracked: fix it now if scope
permits, otherwise lift it into the debt register
([`planning/deferred_work_index.md`](planning/deferred_work_index.md) or
[`audits/`](audits/)). The `deferral_audit` gate enforces this.

### 11.8 Import discipline

Import by full path within the project (`import LegalKernel.Kernel`). Re-export
top-level definitions via the umbrella module `LegalKernel.lean`. Production
modules must never import a `*.Test.*` module (`mock_import_audit` enforces this).

## 12. Testing conventions

Tests use **two complementary patterns**, and meaningful changes should add both
where applicable:

1. **Value-level.** Assert `==` between an expected and an actual result, to
   catch definitional drift at runtime. Use the micro harness's `assertEq` /
   `assert` (`LegalKernel/Test/Framework.lean`):

   ```lean
   open LegalKernel.Test in
   def myTests : List TestCase :=
     [ { name := "transfer moves the right amount"
       , body := assertEq expected actual "transfer" } ]
   ```

2. **Term-level API stability.** Ascribe a binding whose type *is* the theorem
   signature, so elaboration fails if the signature changes:

   ```lean
   -- Fails to elaborate if `transfer_conserves` changes shape:
   def _stability : ∀ …, … := @LegalKernel.Laws.transfer_conserves
   ```

Key facts about the harness:

- It is a **deliberately tiny, dependency-free** runner: each test is an
  `IO Unit` that throws `IO.userError` on failure; the umbrella prints a
  PASS/FAIL banner and exits non-zero on any failure. No LSpec, no Plausible —
  Phase 0's acceptance gate is "no external deps beyond Lean core".
- `lake test` runs the `@[test_driver]` in [`../Tests.lean`](../Tests.lean),
  which imports every suite. **Add new suites to `Tests.lean`** or they will not
  run.
- `LegalKernel/Test/MockCrypto.lean` supplies `mockVerify` / `mockSign` for
  happy-path coverage the production *opaque* `Verify` cannot exercise.
- Test growth is monotonic but **not** pinned by a global count gate — there is
  no magic number to bump.

> **Build-tag pinning.** The `kernelBuildTag` constant in `LegalKernel.lean`
> (currently `"knomosis-step-vm-coherence"`) is pinned by three regression
> tests: `LegalKernel/Test/Umbrella.lean`, `Lex/Test/M2.lean`, and
> `Lex/Test/ExampleLex.lean`. Any phase/milestone bump of that constant **must**
> update all three pinning tests in the same PR, or `lake test` fails.

## 13. Worked walkthroughs (adding code)

These are the common change shapes. Each ends in the same place: green local
gates, one commit, a PR.

### 13.1 Adding or changing a kernel law

A "law" is a `Transition` value with a precondition, a decidability witness, and
an executable effect, accompanied by the theorems that make it admissible. Use
[`LegalKernel/Laws/Transfer.lean`](../LegalKernel/Laws/Transfer.lean) as the
template — it is the canonical §4.11 worked example.

1. Create `LegalKernel/Laws/<YourLaw>.lean` with the license + module docstring
   header, then `import LegalKernel.Kernel` (and `LegalKernel.Conservation` if
   the law must conserve supply).
2. Define the `Transition`: `pre`, `decPre := fun _ => inferInstance` (when the
   precondition is decidable arithmetic), and `apply_impl`.
3. Prove the law's invariants (e.g. conservation) and provide the typeclass
   instances downstream code consumes (`IsConservative`, `LocalTo`,
   `FreezePreserving`, …).
4. Add the law to the `LegalKernel.lean` umbrella re-export.
5. Add a test suite under `LegalKernel/Test/Laws/<YourLaw>.lean` (value-level +
   term-level), and **import it in `Tests.lean`**.
6. Local gates: `lake build LegalKernel.Laws.<YourLaw>` → `lake build` →
   `lake test` → `count_sorries` → `naming_audit` → `deferral_audit` →
   `regenerate_codemaps.py`.

> Changing the `transfer` law specifically touches a `count_sorries`-gated file;
> treat it with kernel-level care.

### 13.2 Adding a Lex action (codegen path)

The Lex action-index registry is **append-only and frozen**; new actions extend
it through a disciplined codegen flow (Workstream LX). The registry is
`Lex/IndexRegistry.txt`; codegen inputs are JSON sidecars under `Lex/Inputs/`.

1. Append the new action to the registry and add its codegen-input JSON under
   `Lex/Inputs/` (strictly increasing `action_index`; respect reserved ranges).
2. Run the generator to regenerate the cross-module artefacts (it edits inside
   `-- BEGIN LEX-GENERATED` / `-- END LEX-GENERATED` fences in
   `Authority/Action.lean`, `Encoding/Action.lean`, `Events/Extract.lean`,
   `Authority/SignedAction.lean`):

   ```bash
   lake exe lex_codegen           # regenerate the fenced artefacts
   lake exe lex_codegen --check   # verify committed == generated
   lake exe lex_lint              # registry + sidecar discipline
   ```

3. `lakefile.lean` registers the registry and `Lex/Inputs/` as build inputs, so
   `lake build` re-fires when either changes — rebuild and run `lake test`.
4. If the action has L1/host mirrors, propagate to the Solidity step-VM handler
   and the Rust encoders/indexer **in the same PR** (cross-stack lockstep), and
   widen the cross-stack corpus.

Never hand-edit inside the generated fences — `lex_codegen --check` will reject
it. The Lex pretty-printer (`lake exe lex_format <file>`) and semantic-diff
(`lake exe lex_diff <before> <after>`) help review registry-touching PRs.

### 13.3 Adding a Rust crate (uncommon)

The documented architecture is complete, so new crates are rare. If one is truly
needed:

1. Create `runtime/<crate-name>/` and add it to `[workspace] members` in
   `runtime/Cargo.toml`.
2. Inherit shared metadata (`version.workspace = true`, etc.) and add
   `[lints.clippy]` / `[lints.rust]` blocks matching the existing crates'
   discipline (`unsafe_code = "forbid"`, pedantic clippy).
3. Run all four gates (fmt, build, test, clippy) before pushing.
4. Bump `Cargo.lock` (committed) and the codemaps.

### 13.4 Adding a Solidity contract

1. Add `solidity/src/contracts/<Name>.sol`, keeping the immutability discipline
   (no proxy / `initialize` / admin role / `pause()`).
2. Add a `test_no_admin_surface` assertion and a per-contract `*.t.sol` suite;
   add cross-stack `CrossCheck/*.t.sol` if it mirrors Lean behaviour.
3. If it introduces a constitutional constant, extend `make audit-caps` and add
   a runtime `test_*_pinned` (a §13.6 change → two reviewers).
4. If it changes gas, run `make snapshot-gas` and commit the new baseline +
   runbook table.
5. `forge build` → `forge test` → `make test-cross-stack` → `make audit-caps` →
   `make snapshot-gas-check`.

## 14. Versioning & version bumps

Knomosis uses **semver**, and **every PR bumps the patch component by default**
(unless the change is doc-only within an in-progress workstream that will bump on
its own PR — standalone doc-only PRs still bump). Use minor for new
backwards-compatible functionality; major for breaking changes.

The Lean and Rust versions move **in lockstep to the same value in every PR**:

| Surface | Bump location |
|---------|---------------|
| Lean kernel | [`../lakefile.lean`](../lakefile.lean) — `package knomosis where version := v!"X.Y.Z"` |
| Rust workspace | `runtime/Cargo.toml` — `[workspace.package] version = "X.Y.Z"` (members inherit) |
| Solidity | `solidity/foundry.toml` `version` field *if present* (currently none) |
| README banner | [`../README.md`](../README.md) — the version badge + the "at a glance" table |

After a Rust bump, `Cargo.lock` regenerates automatically and **must be
committed**. Current version: `v0.7.0` (Lean + Rust).

## 15. Git & branch workflow

- **Branch off the default branch** for any change; never commit straight to
  `main`. Use a descriptive branch name.
- **One commit per completed work unit.** Every commit must pass `lake build`
  **and** `lake test`. Commit messages may reference a workstream/WU number —
  process markers are allowed in commit messages (just not in identifiers).
- **Push** with upstream tracking, retrying only on transient network errors:

  ```bash
  git push -u origin <branch-name>
  # On network failure only, retry up to 4× with exponential backoff: 2s, 4s, 8s, 16s.
  ```

- For fetch/pull, prefer specific branches (`git fetch origin <branch>`,
  `git pull origin <branch>`), with the same backoff on transient failures.
- **Do not open a pull request unless it is explicitly requested.**

> **Pre-commit checklist (Lean change):** `lake build LegalKernel.<Module>` →
> `lake build` (no warnings) → `lake test` → `count_sorries` + `tcb_audit` +
> `naming_audit` + `deferral_audit` (+ `lex_lint` / `lex_codegen --check` for
> Lex) → `regenerate_codemaps.py` → stage → name-discipline grep → commit.

## 16. Pull requests & code review

- **Reviewers.** TCB-core changes need **two** reviewers (§13.6); everything else
  needs one. `CODEOWNERS` routes the requests automatically. Full merge-blocking
  is a branch-protection rule (repo-admin territory); the two-reviewer rule is
  also enforced as a process rule by maintainers.
- **PR authoring policy (absolute).** Never put an agent-harness session
  permalink (the `session_…` URLs some agent harnesses emit, or any equivalent)
  in a PR summary, description, body, or review comment — they are opaque to
  readers, rot when sessions expire, and leak provenance. Scrub the body before
  creating/updating a PR. Use Genesis-Plan section numbers, headline theorem
  names + file paths, and workstream-plan documents under `docs/` as references
  instead. (This restriction is scoped to PR-facing text; it does not apply to
  local commit messages.)
- **What a green PR looks like.** All applicable CI workflows pass (§17); the
  version is bumped; codemaps are regenerated; docs that the change affects are
  updated in the same PR (§21).
- **Be frugal with external comments.** Comment on a PR only when a reply is
  genuinely necessary.

## 17. Continuous integration reference

Five workflows live in [`../.github/workflows/`](../.github/workflows/). The
single-stack workflows are **path-filtered**, so a PR triggers only the stacks it
touches (the Lean `ci.yml` always runs).

| Workflow | Triggers on | Gates |
|----------|-------------|-------|
| `ci.yml` | every PR (always) | `lake build` (full project) · strict-warnings gate · `lake test` · F-1/F-2 fail-closed assertion · `count_sorries` · `tcb_audit` · `stub_audit` · `lex_lint` · `lex_codegen --check` · `naming_audit` · `deferral_audit` · codemap-sync · `mock_import_audit` |
| `ci-rust.yml` | `runtime/**` (+ shared fixture) | `cargo fmt --check` · `cargo build --workspace --all-targets --locked` · `cargo test --workspace --locked` · fee-split fixture drift · `cargo clippy -- -D warnings` |
| `ci-solidity.yml` | `solidity/**` (+ gas runbook) | **caps-audit job:** `make audit-caps` + self-test + gas-gate self-tests + runbook sync (toolchain-free, fast). **forge job:** vendor deps · `forge build` · `forge test` (CI profile, fuzz 1000) · `make snapshot-gas-check` |
| `ci-keccak-crossstack.yml` | hash-interface + cross-stack surface | Links the real keccak adaptor and runs the Lean↔EVM `keccak256` byte-equivalence corpora (all three toolchains). |
| `ci-verify-secp256k1.yml` | verifier surface | Proves linking the real secp256k1 adaptor flips `verify-check` to exit 0 with the production identifier. |

Operational notes:

- All third-party actions are **pinned to a full-length commit SHA** (GitHub
  supply-chain guidance); the adjacent comment records the human-readable tag.
  Bump the SHA and the comment together.
- Concurrency is set so a force-push cancels the superseded run.
- Workflow tokens are read-only except `ci-rust.yml`'s narrow `actions: write`
  (build-artifact cache only — never repo contents).
- The strict-warnings gate re-runs `lake build` and fails on any `warning:`
  line; since every target is `@[default_target]`, no module's warnings can hide.

## 18. Trust assumptions & security posture

Knomosis's guarantees are conditional on exactly **two** non-Lean assumptions,
each isolated behind an `opaque` declaration (not an axiom), so `#print axioms`
stays at `propext, Classical.choice, Quot.sound`:

1. **`Authority.Crypto.Verify`** — the deployment-supplied signature scheme is
   EUF-CMA secure. `@[extern "knomosis_verify_ecdsa"]` routes the compiled call
   to the secp256k1 adaptor (fail-closed reject-all fallback for tests); the
   logical value stays opaque, preserving the assumption.
2. **`Runtime.Hash.hashBytes`** — the production hash function (BLAKE3 via
   `@[extern]`; FNV-1a-64 fallback for tests) is collision-resistant.

A third opaque, `l1FaultProofVerifier`, follows the same pattern for the
fault-proof layer. Kernel theorems and replay guarantees are *conditional* on
these assumptions — and on nothing else.

**Reporting a kernel-soundness bug.** A logic bug in the kernel (e.g. a
counterexample to `impl_noop_if_not_pre`, or a state advance bypassing the `if`
in `step_impl`) is the highest-severity class. Open an issue with the
`kernel-soundness` label; such reports **gate any in-flight PR**, and the
two-reviewer rule applies to the fix. Non-kernel issues (laws, tooling, docs)
follow the standard tracker workflow.

## 19. Troubleshooting & FAQ

| Symptom | Likely cause & fix |
|---------|--------------------|
| `lake: command not found` | You didn't activate elan: `source ~/.elan/env`. |
| `setup.sh` aborts with a SHA-256 mismatch on the toolchain | Possible tampering or a partial download. `rm -rf ~/.elan/toolchains/<toolchain-dir>` and re-run `./scripts/setup.sh` to reinstall from a verified archive. |
| `lake build` link errors about `crti.o` / `crt1.o` | The Lean archive shipped without CRT startup stubs. `setup.sh` tries to repair this; otherwise install your system `libc-dev`. |
| CI fails the strict-warnings gate but the build "succeeded" locally | A Lean `warning:` (often a missing docstring on a public surface, or an unused variable). Re-run `lake build` and read the warnings — they are merge-blocking. |
| `count_sorries` fails | A `sorry` reached `Kernel.lean`, `RBMapLemmas.lean`, or `Laws/Transfer.lean`. Finish the proof — there is no allowlist. |
| `tcb_audit` fails | A new import in a TCB-core file. Either remove it or pursue a §13.6 TCB expansion (two reviewers + `tcb_allowlist.txt` + `std_dependencies.md`). |
| `naming_audit` fails | A provenance/process token in an identifier or filename. Rename to describe *content*. Pre-check with the staged-diff grep in §11.3. |
| `deferral_audit` fails | A `TODO:`/`DEFERRED`/`PARTIAL`-class marker. Implement it, or lift it into the debt register and rewrite the comment without deferral language. |
| `lex_codegen --check` fails | You hand-edited a generated fence or forgot to regenerate. Run `lake exe lex_codegen` and commit. |
| codemap gate fails | Run `python3 scripts/regenerate_codemaps.py` and commit the result. |
| `forge build` can't find the pinned solc | `foundry.toml` pins `/usr/local/bin/solc`; install solc 0.8.20 there (or re-run `./scripts/setup.sh`). |
| `cargo` builds a different toolchain | Run from inside `runtime/` so `rust-toolchain.toml` (1.83) applies; use `--locked`. |
| `hash-check` / `verify-check` exit 1 | **Expected** on the default build — they fail closed on the fallback primitives. They flip to 0 only with the production adaptors linked (§10.2/§10.3). |
| Cross-stack keccak assertions are "skipped" | Expected under the FNV fallback; run `./scripts/verify_keccak_crossstack.sh` to execute them against real keccak. |

## 20. Directory reference

```text
knomosis/
├── lakefile.lean            Lake config — source of truth for all targets
├── lean-toolchain           pinned Lean version
├── tcb_allowlist.txt        TCB import allowlist (tcb_audit)
├── Main.lean / Replay.lean  the knomosis CLI / knomosis-replay binary
├── Tests.lean               @[test_driver] — imports every test suite
├── LegalKernel.lean         umbrella re-export + kernelBuildTag
├── Lex.lean / Deployments.lean   umbrella modules
├── LegalKernel/             kernel (TCB) + laws + authority + encoding +
│                            events + runtime + disputes + bridge + faultproof +
│                            localpolicy + Test/
├── Lex/                     the Lex language (DSL, Tools, Bin, Inputs, Examples, Test)
├── Deployments/Examples/    worked example deployments
├── Tools/                   audit-binary libraries + Tools.Common
├── solidity/                Foundry L1 mirror (contracts, libs, interfaces, tests)
├── runtime/                 Rust host-runtime Cargo workspace (11 crates)
├── scripts/                 setup.sh, codemap regen, cross-stack scripts, econ sim
├── codemaps/                generated per-language navigation maps (CI gate)
├── .github/workflows/       five CI workflows
├── .github/CODEOWNERS       review routing (TCB two-reviewer surface)
├── .claude/                 SessionStart hook + settings (web/remote provisioning)
└── docs/                    GENESIS_PLAN.md, abi.md, planning/, audits/, runbooks,
                             and this DEVELOPMENT.md
```

Per-file purpose lives in each file's `/-! … -/` module docstring; the module
dependency graph and the headline-theorem catalogue are in `CLAUDE.md`.

## 21. Keeping documentation in sync (required in the same PR)

When a change affects behaviour, theorems, or formalisation status, update — in
the **same PR**:

1. [`GENESIS_PLAN.md`](GENESIS_PLAN.md) — if the architecture, formal model,
   threat model, or roadmap changes.
2. [`../README.md`](../README.md) — if project status, build commands, or
   quickstart change.
3. [`../CLAUDE.md`](../CLAUDE.md) **and** [`../AGENTS.md`](../AGENTS.md) — if
   conventions, build commands, or the current-status summary change. **Keep
   these two byte-identical** (they are twins; CI/readers rely on it).

Ownership boundaries: the Genesis Plan owns the design; `CLAUDE.md` owns
engineering conventions; `README.md` owns the introduction; this file owns the
practical workflow. Do **not** extend per-audit or per-WU completion narratives
in `CLAUDE.md` or here — those belong in commit messages, PR descriptions, and
the planning/audit docs. These documents describe the *current state*, not the
path that produced it.

## 22. Further reading

- Design blueprint: [`GENESIS_PLAN.md`](GENESIS_PLAN.md) (≈4 200 lines — read in
  chunks via its table of contents).
- On-disk frame formats + CLI ABI: [`abi.md`](abi.md).
- Std-core dependency audit: [`std_dependencies.md`](std_dependencies.md).
- Decidability discipline: [`decidability_discipline.md`](decidability_discipline.md).
- Workstream plans: [`planning/`](planning/) (Ethereum integration, fault-proof
  migration, unified gas pool, Lex, Rust host runtime, encoder injectivity, …).
- Audit reports & open questions: [`audits/`](audits/),
  [`planning/open_questions.md`](planning/open_questions.md),
  [`planning/deferred_work_index.md`](planning/deferred_work_index.md).
- Operator runbooks: [`fault_proof_runbook.md`](fault_proof_runbook.md),
  [`gas_pool_runbook.md`](gas_pool_runbook.md).
- Stack guides: [`../runtime/README.md`](../runtime/README.md),
  [`../solidity/README.md`](../solidity/README.md).

---

*This guide owns the practical developer workflow. Where it and `CLAUDE.md`
disagree on a convention, `CLAUDE.md` is authoritative; where `CLAUDE.md` and the
Genesis Plan disagree, the Genesis Plan wins.*
