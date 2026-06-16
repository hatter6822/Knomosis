<!--
Knomosis  - A Societal Kernel
Copyright (C) 2026  Adam Hall
This program comes with ABSOLUTELY NO WARRANTY.
This is free software, and you are welcome to redistribute it
under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Gateway dependency audit (Workstream GW §G4.5)

This is the supply-chain review for the `knomosis-gateway` crate and the
new third-party dependencies the Gateway workstream introduced into the
`runtime/` Cargo workspace.  It is the human sign-off companion to the
machine-enforced policy in `runtime/deny.toml` (run by
`.github/workflows/ci-cargo-deny.yml`).

## Scope

The gateway is **pure-Rust orchestration** over `tiny_http` and the sibling
runtime crates: `unsafe_code = "forbid"`, no FFI, no `tokio`.  Its only new
*production* third-party dependencies beyond the workspace-standard set
(`serde`, `serde_json`, `thiserror`, `tracing`) are:

| Crate | Kind | Role | Justification |
|-------|------|------|---------------|
| `tiny_http` | normal | The synchronous HTTP/1.1 server (G1.0 decision). | Vetted in `docs/audits/gateway_http_spike.md`; chosen precisely to avoid `tokio`.  `default-features = false` keeps its (version-stale) bundled TLS out — HTTPS is the G4.2 unit. |
| `subtle` | normal | Constant-time bearer-token comparison (G1.4 auth gate). | The same audited, `no_std`, constant-time crate the secp256k1 verifier already uses workspace-wide; eliminates an early-return timing oracle on the secret token. |
| `signal-hook` | normal | SIGTERM/SIGINT graceful-shutdown trigger (G4.4). | A safe `sigaction` wrapper — the crate's `unsafe = forbid` rules out a hand-rolled handler.  `default-features = false` pulls only the atomic-flag registration (`flag::register`), not the channel/iterator helpers. |

New **dev-only** dependencies (never in the shipped binary):

| Crate | Role |
|-------|------|
| `tempfile` | Isolated on-disk SQLite databases the read tests seed + open read-only. |
| `proptest` | The G3.4 fan-out-ring property tests (ordering / gap-freeness / seq-group integrity / watermark) — the same workspace-pinned crate the host / indexer / event-subscribe suites use. |
| `tracing-subscriber` | The G4.3 redaction test captures the structured request log into a buffer and asserts no bearer token appears — the same workspace-pinned crate `knomosis-cli-common` uses. |

All three dev deps were already present at the workspace level (used by
sibling crates), so they add **no new crate** to the dependency graph — only
a new *edge* from the gateway.

## Licence policy (verified)

`runtime/deny.toml`'s allow-list was derived from, and verified against, the
**actual** licence expressions in the resolved dependency tree (via
`cargo metadata`).  Every expression in the tree is satisfiable by the
allow-list `{ MIT, Apache-2.0, ISC, BSD-3-Clause, Unicode-3.0,
GPL-3.0-or-later }`:

| Expression (as resolved) | Satisfied by | Example crates |
|--------------------------|--------------|----------------|
| `MIT OR Apache-2.0` / `Apache-2.0 OR MIT` / `MIT/Apache-2.0` / `Apache-2.0/MIT` | MIT | ~90 crates (most of the tree, incl. `signal-hook`) |
| `MIT` | MIT | `rusqlite`, `generic-array`, … |
| `(MIT OR Apache-2.0) AND Unicode-3.0` | MIT **+ Unicode-3.0** | `unicode-ident` |
| `Apache-2.0 AND ISC` | Apache-2.0 **+ ISC** | `ring` |
| `Apache-2.0 OR ISC OR MIT` | MIT | `rustls`, `rustls-pemfile` |
| `ISC` | ISC | `rustls-webpki`, `untrusted` |
| `BSD-3-Clause` | **BSD-3-Clause** | `subtle` |
| `BSD-2-Clause OR Apache-2.0 OR MIT` | MIT | `zerocopy` |
| `Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT` | MIT | `rustix`, `wasi` |
| `Unlicense OR MIT` | MIT | `aho-corasick`, `memchr` |
| `GPL-3.0-or-later` | GPL-3.0-or-later | the project's own workspace crates |

The three load-bearing single-/conjunctive-licence entries are
`BSD-3-Clause` (`subtle`, sole licence), `ISC` (`ring`'s `AND` conjunct),
and `Unicode-3.0` (`unicode-ident`'s `AND` conjunct) — none is reachable via
an `OR` alternative, so each is mandatory.  `GPL-3.0-or-later` covers the
project's own crates (Knomosis is GPL-3.0-or-later); there is **no
third-party copyleft dependency** in the tree.

## Advisory / ban / source policy

  * **Advisories** (`[advisories] version = 2`): every RUSTSEC advisory is a
    hard failure (no `ignore` entries); a yanked version fails.  The
    advisory-database match is performed by `cargo deny` in CI against the
    live RUSTSEC DB (it cannot be evaluated offline).
  * **Bans**: a wildcard (`*`) version requirement is denied (every
    dependency carries a concrete constraint); duplicate versions are
    *warned*, not failed (benign, but surfaced for tracking).
  * **Sources**: only the canonical crates.io registry is allowed; any
    unknown registry or git source is denied.

## Threat-model notes (gateway-specific)

  * **No key custody.** The submit path forwards client-signed `SignedAction`
    bytes opaquely; the gateway never holds a signing key.
  * **Fail-closed auth.** No token file ⇒ every non-exempt request is denied;
    the token file must not be world-readable (a startup permission check).
  * **Read isolation.** Reads use a pure `SQLITE_OPEN_READ_ONLY` handle — a
    gateway logic bug cannot mutate the indexer database.
  * **Secret redaction.** The structured request log (G4.3) records only the
    method / path / status / latency / request-id — never the token, an
    `Idempotency-Key`, or a body (enforced by a log-capture test).
  * **Resource bounds.** Concurrent streams, the host connection pool,
    in-flight submits, the fan-out ring, and the idempotency cache are all
    bounded; an over-cap request is a `503`, not unbounded growth.

## Sign-off

The dependency set is minimal, the licence allow-list is verified against
the resolved tree, and the advisory/ban/source policy is enforced in CI.
The lone deferred hardening item is **G4.2 (TLS/mTLS)**, which will
introduce a TLS dependency (rustls is already in the workspace tree) and
extend this audit.
