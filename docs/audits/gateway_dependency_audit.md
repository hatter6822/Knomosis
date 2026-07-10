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

The gateway is **pure-Rust orchestration** over the workspace's `rustls 0.23`,
the std network stack, and the sibling runtime crates: `unsafe_code = "forbid"`,
no FFI, no `tokio`.  **The G4.2/G4.6 own-HTTP-stack unification retired the
former `tiny_http` dependency** — the gateway now owns its whole HTTP/1.1 stack
(the plaintext + native-TLS accept loops, a strict hand-rolled reader/writer,
and a thread-per-connection model) over `rustls 0.23`.  Its only new
*production* third-party dependencies beyond the workspace-standard set
(`serde`, `serde_json`, `thiserror`, `tracing`) are:

| Crate | Kind | Role | Justification |
|-------|------|------|---------------|
| `rustls` | normal | Native in-process HTTPS / mTLS (G4.2, `src/http/tls.rs`) **and** the gateway's whole HTTP stack (after the `tiny_http` retirement). | The **workspace-pinned `rustls 0.23`** (TLS 1.3, the `ring` backend) — the SAME audited stack `knomosis-host` already uses.  Adds **no new crate** to the graph (rustls 0.23 + its transitive deps were already present via `knomosis-host`).  PEM cert/key/CA loading reuses `knomosis_host::tls`'s vetted loaders, and the `--mtls-crl` CRL parsing goes through rustls's re-exported `pki_types::pem::PemObject` — the maintained parser that replaced the retired `rustls-pemfile` (RUSTSEC-2025-0134). |
| `tracing-subscriber` (feature `json`) | normal | The gateway installs its own structured-log subscriber (`src/logging.rs`, `--log-format json\|text`); cli-common is text-only and the gateway is the first WU needing JSON. | The same workspace-pinned crate the sibling crates use, with the additive `json` feature.  That feature pulls two new transitive crates — `tracing-serde` and `valuable`, both MIT (on the allow-list, §below). |
| `subtle` | normal | Constant-time bearer-token comparison (G1.4 auth gate). | The same audited, `no_std`, constant-time crate the secp256k1 verifier already uses workspace-wide; eliminates an early-return timing oracle on the secret token. |
| `signal-hook` | normal | SIGTERM/SIGINT graceful-shutdown trigger (G4.4). | A safe `sigaction` wrapper — the crate's `unsafe = forbid` rules out a hand-rolled handler.  `default-features = false` pulls only the atomic-flag registration (`flag::register`), not the channel/iterator helpers. |

New **dev-only** dependencies (never in the shipped binary):

| Crate | Role |
|-------|------|
| `tempfile` | Isolated on-disk SQLite databases the read tests seed + open read-only (and the TLS handshake tests' PKI dir). |
| `proptest` | The G3.4 fan-out-ring property tests (ordering / gap-freeness / seq-group integrity / watermark) — the same workspace-pinned crate the host / indexer / event-subscribe suites use. |

Both dev deps were already present at the workspace level (used by sibling
crates), so they add **no new crate** to the dependency graph — only a new
*edge* from the gateway.  (`tracing-subscriber` moved from a dev-only to a
*production* dependency when the gateway took over its own log subscriber.)

## Licence policy (verified)

`runtime/deny.toml`'s allow-list was derived from, and verified against, the
**actual** licence expressions in the resolved dependency tree (via
`cargo metadata`).  Every expression in the tree is satisfiable by the
allow-list `{ MIT, Apache-2.0, ISC, BSD-3-Clause, Unicode-3.0,
GPL-3.0-or-later }`:

| Expression (as resolved) | Satisfied by | Example crates |
|--------------------------|--------------|----------------|
| `MIT OR Apache-2.0` / `Apache-2.0 OR MIT` / `MIT/Apache-2.0` / `Apache-2.0/MIT` | MIT | ~90 crates (most of the tree, incl. `signal-hook`) |
| `MIT` | MIT | `rusqlite`, `generic-array`, `tracing-serde`, `valuable` (the latter two new via `tracing-subscriber`'s `json` feature), … |
| `(MIT OR Apache-2.0) AND Unicode-3.0` | MIT **+ Unicode-3.0** | `unicode-ident` |
| `Apache-2.0 AND ISC` | Apache-2.0 **+ ISC** | `ring` |
| `Apache-2.0 OR ISC OR MIT` | MIT | `rustls`, `rustls-pki-types` |
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
    hard failure; a yanked version fails.  The advisory-database match is
    performed by `cargo deny` (pinned `^0.19` so its `cvss` crate can parse the
    CVSS-4.0 advisories now present upstream) in CI against the live RUSTSEC DB
    (it cannot be evaluated offline).  **No advisory is ignored.**  (The
    formerly-ignored `RUSTSEC-2025-0134` — `rustls-pemfile` unmaintained,
    archived Aug 2025 — was retired by completing the tracked follow-up:
    the `knomosis-host` cert/key loaders and the gateway's `--mtls-crl` CRL
    parser now use the maintained `rustls_pki_types::pem::PemObject` API
    (the same PEM parsing code `rustls-pemfile` 2.x wrapped), and the
    `rustls-pemfile` crate left the dependency tree entirely.)
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
**G4.2 (native TLS/mTLS)** is now shipped: it makes the workspace's
already-present `rustls 0.23` a **direct** gateway dependency (`Apache-2.0 OR
ISC OR MIT`, already on the allow-list) without adding any new crate to the
graph, so the supply-chain surface is unchanged and this audit's policy holds
as-is.
