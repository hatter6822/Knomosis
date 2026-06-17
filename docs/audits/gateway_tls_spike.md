<!--
Knomosis  - A Societal Kernel
Copyright (C) 2026  Adam Hall
This program comes with ABSOLUTELY NO WARRANTY.
This is free software, and you are welcome to redistribute it
under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Gateway TLS decision + implementation record (G4.2)

This resolves the TLS hardening unit (G4.2) the HTTP-layer spike deferred
(`docs/audits/gateway_http_spike.md` §"TLS is deferred to G4.2", options
i / ii / iii).  **Decision: implement native in-process HTTPS** with the
workspace's `rustls 0.23` (option iii), while keeping edge termination
(option ii) a supported alternative.  This document records the constraints,
why the bundled-`rustls-0.20` path stays rejected, and how the native path is
built **without** re-introducing the request-parsing surface that the original
"option iii" flagged.

## The question

Should `knomosis-gateway` terminate TLS **in-process** (a native HTTPS
listener), or rely only on an **external / co-located TLS edge** that hands it
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

So a native HTTPS path cannot reuse `tiny_http` for the TLS connections: it
must read HTTP/1.1 off the `rustls` stream itself.

## Options

### (i) Enable `tiny_http`'s bundled `rustls 0.20` — REJECTED

A **security downgrade on the most exposed surface**: it would run the public
TLS endpoint on a TLS library three years older than the one the rest of the
system is audited against (`rustls 0.23`), and put **two `rustls` major
versions** in the dependency tree — exactly the "audit-surface bloat" the §2
principle-9 minimal-dependency ethos and the G4.5 supply-chain policy guard
against (risk R14).  Running old TLS to front a system whose internal TLS is
current is indefensible.

### (ii) Co-located / edge TLS termination — SUPPORTED (alternative)

A vetted TLS edge — an L7 load balancer / reverse proxy, or a co-located
terminator on `knomosis_host::tls` (`rustls 0.23`, TLS 1.3, ring) — terminates
TLS and forwards loopback-plaintext HTTP to the gateway.  This stays fully
supported: the `--listen` default is `127.0.0.1:8080`, §9.1 places the gateway
behind the BFF / an L7 edge, and an operator who already runs an edge can keep
the gateway plaintext behind it.  The runbook documents this model.

### (iii) Native in-process HTTP-over-`rustls 0.23` — IMPLEMENTED (G4.2)

`src/http/tls.rs` adds a native HTTPS front-end on its own `--tls-listen`
socket, running **alongside** the plaintext `--listen` socket.  The original
spike flagged three sub-paths for "doing native HTTPS correctly"; the shipped
design takes the third and **neutralises its stated risk**:

  * It does **not** wait on a `tiny_http` upstream release, and it does **not**
    proxy to a loopback `tiny_http` port (which would need bidirectional TLS
    streaming `rustls`'s `StreamOwned` does not split cleanly — the SSE
    problem).  Each TLS connection reads HTTP/1.1 **directly** off its own
    `StreamOwned` on its own thread, so a long-lived SSE stream just owns its
    thread and never needs a split session.
  * The flagged risk of "hand-rolling HTTP/1.1 re-introduces the
    request-smuggling / desync surface `tiny_http` was chosen to avoid" is
    closed by **construction**, because the gateway is the **sole HTTP
    processor on the connection** — it *is* the TLS terminator, so there is no
    intermediary to disagree with about message boundaries (request smuggling
    fundamentally requires two disagreeing processors in a chain).  On top of
    that the reader is deliberately strict:
      - `Transfer-Encoding` is **rejected** (`501`) — no chunked decoding, so
        the entire TE.CL / CL.TE desync class is impossible.
      - A duplicate / comma-listed `Content-Length` is **rejected** (`400`); a
        single valid length is read **exactly**, so the next keep-alive
        request always starts at the right byte offset.
      - Obsolete header folding is **rejected**; request-line, header-line,
        header-count, and header-section size are all **bounded**.
      - **Any** framing ambiguity closes the connection rather than guessing a
        boundary — a desync cannot persist across requests.
  * The TLS comes from the **workspace's `rustls 0.23`** (TLS 1.3 floor, ring),
    reusing `knomosis_host::tls`'s vetted PEM loaders; **no new crate** enters
    the dependency graph (`rustls 0.23` is already present via
    `knomosis-host`), so the G4.5 supply-chain surface is unchanged.

Crucially, the native front-end reuses the **exact** shared request core
(`http::handler`) — the same fail-closed auth gate, per-credential rate cap,
router, dispatch, and SSE fan-out (`run_one_stream` over the same `StreamSlot`
bound) — so the HTTP and HTTPS transports **cannot diverge in security
behaviour**.  Only the wire I/O differs.

## Decision

**Native in-process HTTPS is implemented (option iii)**, with edge termination
(option ii) kept as a supported alternative; the bundled-`rustls-0.20` path
(i) stays rejected as a security downgrade.

Surface (`src/http/tls.rs`, `--tls-*` / `--mtls-*` flags):

  * `--tls-listen <ADDR>` enables the HTTPS listener (requires `--tls-cert` +
    `--tls-key`); it runs alongside the plaintext `--listen`.
  * `--mtls-client-ca <PATH>` enables mTLS — a `WebPkiClientVerifier`
    **requires** a client certificate chaining to the CA.
  * `--tls-max-connections <N>` bounds concurrent TLS connections (the
    spawn-storm DoS guard; each connection runs on its own thread).
  * TLS 1.3 floor; the `ring` backend, pinned per-config.
  * The `ServerConfig` is built + the socket bound at **startup**, so a bad
    cert / key / CA / address is a fatal `ServeError::Tls`, never a
    per-connection fault.
  * The accept thread + every connection observe the graceful-shutdown flag.

## Acceptance

  * **Weak-protocol floor:** TLS 1.3 only (no 1.2/1.1/1.0 negotiation).
  * **mTLS:** a real `rustls 0.23` client handshake is **rejected** with no
    client certificate and **accepted** with a CA-signed one
    (`native_tls_mutual_auth_enforced`).
  * **Round-trip:** server-auth handshake serves `/healthz` `200`, an authed
    `/v1/info` `200`, an unauthed `401`, a bad-version `505`, a body-framed
    submit `503`, an SSE `503`, and keep-alive pipelining
    (`native_tls_server_auth_surface`).
  * **Strict reader:** 30 pure-parser unit tests cover the smuggling guards
    (TE reject, duplicate/comma `Content-Length`, obsolete folding, exact-body
    framing, bounded lines) and the response writer's response-splitting guard.
  * **No new dependency:** the bundled-`rustls-0.20` path is *not* enabled; the
    native path reuses the in-tree `rustls 0.23`.
