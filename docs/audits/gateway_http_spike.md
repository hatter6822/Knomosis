<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Gateway HTTP-layer spike — decision memo (G1.0 / OQ-GW-8)

**Status: DECIDED.** The `knomosis-gateway` HTTP/1.1 layer is built on a
**vetted synchronous HTTP crate — `tiny_http` 0.12** — not a hand-rolled
parser. This resolves **OQ-GW-8** and is the foundation `G1.2` builds on.
See `docs/planning/gateway_integration_plan.md` §3.2 / §3.2.1 for the
constraints this memo answers.

## The question (OQ-GW-8 / §3.2.1)

The `runtime/` workspace forbids `tokio` (and therefore `axum`/`hyper`/
`warp`), so the gateway is a **synchronous, thread-based** server. The
plan framed three options for the HTTP/1.1 substrate:

1. **Hand-rolled** HTTP/1.1 subset on `std::net` (+ reuse
   `knomosis_host::tls`).
2. **A small vetted synchronous HTTP crate.**
3. **Reuse `knomosis_host::listener`'s** TCP/TLS/Unix acceptor and
   hand-roll only the HTTP framing on top.

## Decision

**Option 2 — `tiny_http` 0.12.** The request line + header parsing, the
keep-alive connection lifecycle, and the request-smuggling-adjacent edge
cases (duplicate/conflicting `Content-Length`, `CR`/`LF` handling, header
limits) are exactly the surface where a hand-rolled parser accrues
security bugs. Delegating them to a widely-deployed, battle-tested parser
removes that class of risk from code we would otherwise have to write,
fuzz, and own. This is a deliberate trade of **one vetted dependency** for
**a smaller bespoke-parser attack surface** — the safer default for a
network-facing service.

### Why `tiny_http` specifically

* **No async runtime.** `tiny_http` is a pure `std`-threads server (one
  acceptor + a handler pool); it pulls **no** `tokio`/`async-std`. With
  `default-features = []` its only core dependencies are `ascii`,
  `chunked_transfer`, `httpdate`, and `log` — all small and synchronous.
  This is the only mature, pure-`std`-threads HTTP **server** crate in the
  ecosystem (`may_minihttp` uses `may` coroutines + `unsafe`; `astra`/
  `hyper`-based options pull the async stack we forbid).
* **Streaming responses (SSE).** `tiny_http` serves a response from any
  `Read` body and, for an unknown-length body, frames it with
  `Transfer-Encoding: chunked` — the substrate `G3.5`'s SSE stream needs
  (connection held open, records flushed as they arrive, no
  `Content-Length`). For finer flush/disconnect control it also exposes a
  raw-stream `Request::upgrade`/writer path; the exact SSE mechanism is
  finalised in `G1.2e`/`G3.4` and validated by the `G3.4d` mid-group-resume
  oracle test.
* **Maturity / vetting.** `tiny_http` underpins `rouille` and a large
  number of production tools; "vetted" here means *widely exercised*, not
  *formally audited*. It is added to the `cargo-deny` advisory/license/ban
  policy when `G4.5` introduces `runtime/deny.toml` (closes risk **R14**).

### Options not taken

* **Hand-rolled (option 1).** Rejected: re-implementing an HTTP/1.1 parser
  — including the smuggling defenses of `G1.2a` — is precisely the work a
  vetted parser removes. Lower dependency count, but a larger bespoke
  security surface to own and fuzz.
* **Reuse `knomosis_host::listener` (option 3).** The listener is a
  protocol-agnostic *acceptor* (TCP/TLS/Unix + a max-connections cap); it
  still leaves the HTTP *framing* to be hand-rolled on top, so it does not
  by itself avoid option 1's parser surface. We may still reuse its accept
  loop underneath `tiny_http` if the TLS path (below) calls for taking over
  accept; recorded as a `G4.2` option, not a `G1.2` dependency.

## TLS is deferred to G4.2 (not a G1 blocker)

`tiny_http`'s TLS (`ssl-rustls` feature) depends on an **older `rustls`**
than the workspace's pinned `rustls 0.23` (`knomosis_host::tls`). Enabling
it would put **two `rustls` versions** in the tree — audit-surface bloat
and a direct conflict with the §2 principle 9 "minimal, auditable
dependencies" ethos (risk **R14**).

This does **not** block `G1`: per §9.2 the gateway's default listener is
**loopback plaintext** (`--listen 127.0.0.1:8080`); `--tls-listen` is
**off by default** and HTTPS termination is the `G4.2` hardening unit. In a
dark-launch / co-located deployment the BFF↔gateway hop is internal and an
L7 edge (or the BFF) terminates TLS. The `G4.2` TLS decision therefore
chooses between: **(i)** accept `tiny_http`'s bundled `rustls`; **(ii)**
front the gateway with a co-located TLS proxy; or **(iii)** take over the
accept loop to wrap streams with the workspace's `rustls 0.23`
(`knomosis_host::tls`) and feed plaintext to the parser. Decision deferred
to `G4.2` with this trade-off recorded.

## Constraints carried forward (unchanged by the crate choice)

* **Panic-freedom by construction (R16).** The workspace `[profile.release]`
  sets `panic = "abort"` (non-overridable), so a panic in **our** handler
  aborts the whole process regardless of the HTTP crate — `tiny_http`
  cannot rescue it and `catch_unwind` is unavailable under `abort`. The
  request-path modules therefore keep the §3.2 rule: `clippy::restriction`
  panic-lints (`unwrap_used`, `expect_used`, `indexing_slicing`, `panic`,
  `unreachable`) **denied**, checked arithmetic only, and the
  request-derived parsing adversarially `proptest`ed. The crate handles
  *transport* parsing; *our* per-request logic is what these lints guard.
* **Bounded everything.** Max connections / handler-pool size / request
  body size (`max_frame_size`) / SSE streams are gateway-side governors
  layered over `tiny_http`'s accept loop (`G1.2d`, `G2.3`, `G3.4c`).

## Acceptance

* OQ-GW-8 is resolved (recorded here; promote into
  `docs/planning/open_questions.md` with the rest of the OQ-GW-* set on
  workstream promotion, §15A).
* `G1.1` adds `tiny_http` to `runtime/Cargo.toml` `[workspace.dependencies]`
  and the new `knomosis-gateway` crate; `G1.2` builds the request parser,
  router, response writer, acceptor + governors, and the SSE streaming
  primitive on it.
