<!--
Knomosis  - A Societal Kernel
Copyright (C) 2026  Adam Hall
This program comes with ABSOLUTELY NO WARRANTY.
This is free software, and you are welcome to redistribute it
under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Gateway TLS decision memo (G4.2)

This resolves the TLS hardening unit (G4.2) the HTTP-layer spike deferred
(`docs/audits/gateway_http_spike.md` §"TLS is deferred to G4.2", options
i / ii / iii).  It is a **decision**, not an implementation: native
in-process HTTPS in the gateway process is **deferred**, and TLS is
terminated **at a co-located vetted edge** for v1.

## The question

Should `knomosis-gateway` terminate TLS **in-process** (a native HTTPS
listener), or rely on an **external / co-located TLS edge** that hands it
loopback-plaintext HTTP?

## The hard constraint

The HTTP transport is `tiny_http 0.12` (the G1.0 / OQ-GW-8 decision: a
vetted *synchronous* server, no `tokio`).  Two facts box in the TLS choice:

  1. **`tiny_http 0.12`'s bundled TLS is `rustls 0.20`** (its `ssl-rustls`
     feature pins `rustls = "0.20"`, `rustls-pemfile = "0.2"`) — a
     2021-era TLS stack.  The workspace's own TLS (`knomosis_host::tls`)
     is the current **`rustls 0.23`** (ring backend, TLS 1.3 default).
  2. **`tiny_http` cannot consume an externally-terminated stream.** Its
     `Server::from_listener` accepts only a `TcpListener` / `UnixListener`
     (`Listener: From<TcpListener>`); it reads **plaintext HTTP** off the
     accepted `TcpStream`s itself.  There is no hook to feed it a
     `rustls`-decrypted stream.

## Options

### (i) Enable `tiny_http`'s bundled `rustls 0.20` — REJECTED

This is a **security downgrade on the most exposed surface**: it would run
the public TLS endpoint on a TLS library three years older than the one the
rest of the system is audited against (`rustls 0.23`), and put **two
`rustls` major versions** in the dependency tree — exactly the
"audit-surface bloat" the §2 principle-9 minimal-dependency ethos and the
G4.5 supply-chain policy guard against (risk R14).  Running old TLS to
front a system whose internal TLS is current is indefensible.

### (ii) Co-located / edge TLS termination — CHOSEN for v1

A vetted TLS edge — an L7 load balancer / reverse proxy (nginx, Envoy, a
cloud LB), **or** a co-located terminator built on the workspace's own
`knomosis_host::tls` (`rustls 0.23`, TLS 1.3, ring) — terminates TLS and
forwards loopback-plaintext HTTP to the gateway.  This is:

  * **Secure** — TLS is handled by a battle-tested, current stack
    (`rustls 0.23` / the edge's TLS), not a 2021 bundle nor a hand-roll.
  * **Standard** — the overwhelming majority of production HTTP services
    terminate TLS at the edge and run the app server plaintext on loopback.
    It matches the gateway's design: the `--listen` default is
    `127.0.0.1:8080`, and §9.1 places the gateway **behind the BFF / an L7
    edge**.
  * **mTLS-capable** — client-certificate verification is configured at the
    edge (or the co-located terminator's `rustls` `ClientCertVerifier`),
    where the cert chain + revocation policy already live.

The operator runbook (`docs/gateway_runbook.md` §4, §11) documents this as
the deployment model.

### (iii) Native in-process HTTP-over-`rustls 0.23` — DEFERRED

Doing native HTTPS *correctly* (current `rustls 0.23`, no proxy) needs one
of three things, none a safe quick win:

  * **`tiny_http` gains `rustls 0.23` support** — an upstream release we do
    not control.  When it lands, native HTTPS is a small wiring unit reusing
    `knomosis_host::tls::TlsConfigBuilder` for the `ServerConfig`.
  * **Hand-roll HTTP/1.1 over a `rustls 0.23` stream** — re-introduces the
    request-parsing surface (request smuggling / desync / header edge
    cases) that G1.0 *explicitly chose `tiny_http` to avoid*.  Hand-rolling
    HTTP on the **public TLS** path is a security regression, not a
    hardening.
  * **An in-process `rustls 0.23` terminating proxy to `tiny_http`'s
    loopback port** — needs bidirectional TLS streaming (concurrent
    encrypt/decrypt) for long-lived SSE, which `rustls`'s `StreamOwned`
    does not split cleanly; an event-loop / manual-buffering proxy is
    error-prone and duplicates what the edge already does.

None improves security or simplicity over (ii).

## Decision

**TLS is terminated at a co-located vetted edge for v1 (option ii).** The
gateway stays loopback-plaintext (`--listen 127.0.0.1:8080` default); the
bundled-`rustls-0.20` path (i) is rejected as a security downgrade; native
in-process HTTPS (iii) is deferred until a vetted sync HTTP-over-`rustls
0.23` integration exists (a `tiny_http` upstream release, or a re-evaluation
of the G1.0 HTTP-layer choice), at which point it reuses
`knomosis_host::tls` for the `ServerConfig` + the mTLS verifier.

Consequences, all already in place:

  * **No `--tls-*` / `--mtls-*` flags are added** — adding flags with no
    implementation would be a stub (forbidden); the runbook records native
    TLS as not-yet-implemented, and the §9.2 flag table is the *planned*
    surface.
  * The gateway's bounded governors (max streams, pool, body size, ring)
    and the fail-closed auth gate are unchanged — they sit behind whatever
    terminates TLS.
  * `weak-protocol rejection` + `unknown-client-cert rejection` (the G4.2
    acceptance) are enforced **at the edge** (TLS 1.3 floor; the edge's
    mTLS verifier), per the deployment's edge configuration.

## Acceptance

  * The G4.2 TLS question is resolved (recorded here): edge termination for
    v1; bundled `rustls 0.20` rejected; native in-process HTTPS deferred
    with the path documented.
  * No new dependency is added (the bundled-`rustls` path is *not* enabled).
  * The runbook (§4 security model, §11 known limitations) and the §9.2 flag
    table already reflect this model.
