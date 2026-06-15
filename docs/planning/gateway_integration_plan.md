<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Knomosis Gateway — HTTP/JSON + SSE Integration Plan (DRAFT)

This document plans a `knomosis-gateway` service that bridges Knomosis's
binary, socket-based runtime surfaces to a browser-friendly HTTP/JSON +
Server-Sent-Events (SSE) contract, so a TypeScript Backend-for-Frontend
(the first consumer being **Licio**, https://github.com/hatter6822/Licio)
can submit actions and read state without speaking the raw CBE wire
protocols.

The companion machine-readable contract is
[`docs/api/gateway.openapi.yaml`](../api/gateway.openapi.yaml) (OpenAPI
3.1). This document owns the *rationale* and the *mappings* from each
endpoint to the underlying Knomosis ABI; the YAML owns the *shapes*.

## Status

> **DRAFT — not started, not yet ratified.** This is a contract sketch
> and engineering plan only. No `knomosis-gateway` crate exists yet; no
> roadmap table in `CLAUDE.md` / `README.md` / `GENESIS_PLAN.md` has been
> amended. Wiring this into the roadmap is a follow-up that requires
> explicit sign-off (see §10, §11).

There is currently **zero coupling** between the two repositories:
Knomosis's source has no reference to Licio, and Licio references
"Knomosis topics" only behind a crypto feature flag that is OFF by
default. This plan is therefore greenfield integration design, not a
repair of an existing seam.

## §1 Motivation and context

### §1.1 The impedance mismatch

| | Knomosis exposes | Licio expects |
|---|---|---|
| Transport | TCP / TLS / Unix sockets | HTTPS |
| Encoding | CBE (binary) frames | JSON |
| Write | length-prefixed `SignedAction` → verdict byte (abi.md §10) | `fetch` to an HTTP endpoint |
| Events | custom `SUBSCRIBE` framing (abi.md §11) | SSE / WebSocket |
| Read | `knomosis-indexer query` CLI over SQLite (abi.md §11A) | HTTP GET |
| Consumer | sequencer / daemon | Hono BFF (TypeScript) |

A browser cannot speak Knomosis's protocols, and re-implementing CBE
encoding + action signing inside the Hono BFF would duplicate the
load-bearing Lean↔Rust byte-equivalence contract in a third language.
The gateway resolves this by terminating the binary protocols on the
Knomosis side and exposing a thin, stateless HTTP/JSON + SSE surface.

### §1.2 Why a Rust gateway crate (not a TypeScript client)

* **Byte-equivalence preserved.** The gateway reuses the existing Rust
  CBE encoder and the `knomosis-host` / `knomosis-event-subscribe`
  clients, so the signed bytes and event decoding stay on the audited
  stack.
* **Key custody stays server-side.** Signing material never reaches the
  browser-adjacent BFF; the gateway forwards pre-signed actions and
  holds no user keys (§8.2).
* **Thin BFF.** Licio's Hono layer becomes a plain authenticated HTTP/SSE
  client — `fetch` + `EventSource`.

## §2 Design principles

1. **REST for reads + submit, SSE for the live stream.** Pragmatic
   REST/HTTP+JSON (resource GETs + a command `POST /actions`), plus SSE
   for the event tail with `GET /events` cursor backfill as its
   complement. Not dogmatic HATEOAS — there is exactly one trusted
   consumer.
2. **Verdict ≠ HTTP status.** HTTP status describes the request's
   transport/validation fate; the kernel verdict is a first-class domain
   result returned in the body. A well-formed-but-declined action is
   `200 { accepted: false }`, never a 4xx (§5).
3. **Opaque forwarding.** `POST /actions` forwards the client-signed CBE
   bytes verbatim. The signature is over the canonical CBE encoding, so
   the gateway must never re-serialize.
4. **Eventual consistency, surfaced.** Reads come from the indexer view
   (abi.md §11A), which lags the log. Every read carries
   `X-Knomosis-Seq` (the cursor it reflects) so clients can reconcile
   against the event stream and cache with `ETag`.
5. **Big integers as strings.** Amounts, balances, budgets, nonces and
   sequence numbers are decimal strings end-to-end, avoiding IEEE-754
   precision loss in JSON/JS (wei-scale values exceed 2^53).
6. **Stateless gateway.** No session state of its own; idempotency keys
   and cursors are client-supplied. Horizontal-scalable behind the BFF.
7. **Versioned contract.** `/v1` path prefix; the OpenAPI document is the
   versioned source of truth and the basis for a generated TS client.

## §3 Architecture

```
        Browser PWA (React 19)
              │  HTTPS / JSON, EventSource (SSE)
              ▼
        Licio Hono BFF  ── sessions (Redis), CORS, user authN ──┐
              │  HTTPS / JSON + SSE   (bearer service token / mTLS)
              ▼
   ┌──────────────────  knomosis-gateway (NEW Rust crate, runtime/)  ──────────────────┐
   │  stateless; reuses CBE encoder + host/subscribe clients; terminates TLS for web    │
   │                                                                                    │
   │   POST /v1/actions ───────────► knomosis-host        (CBE SignedAction, abi.md §10)│
   │   GET  /v1/actors/.../balances ► knomosis-indexer    (SQLite view, abi.md §11A)    │
   │   GET  /v1/events  (backfill) ─► knomosis-event-subscribe (SUBSCRIBE, abi.md §11)  │
   │   GET  /v1/events/stream (SSE) ► knomosis-event-subscribe                          │
   └────────────────────────────────────────────────────────────────────────────────────┘
```

The gateway is a new member of the `runtime/` workspace (§9), inheriting
the workspace toolchain pin, lint discipline (`clippy::pedantic`,
`unsafe_code = "forbid"`), and CI gates.

## §4 Endpoint catalogue

| Method | Path | Purpose | Backed by | Consistency |
|---|---|---|---|---|
| POST | `/v1/actions` | Submit signed action → verdict | knomosis-host (§10) | synchronous |
| GET | `/v1/actors/{actorId}/balances` | All balances for an actor | indexer (§11A.2) | eventual |
| GET | `/v1/actors/{actorId}/balances/{resource}` | One balance | indexer (§11A.2) | eventual |
| GET | `/v1/actors/{actorId}/budget` | Epoch budget view | indexer (§11A.4) | eventual |
| GET | `/v1/pools/{poolId}` | Gas-pool view | indexer (§11A.4) | eventual |
| GET | `/v1/events` | Cursor backfill | event-subscribe (§11.3) | ordered |
| GET | `/v1/events/stream` | Live SSE stream | event-subscribe (§11) | ordered |
| GET | `/v1/info` | Deployment + kernel metadata | host/§10.2.1 | live |
| GET | `/healthz`, `/readyz` | Liveness / readiness | gateway | live |

## §5 Verdict → HTTP status mapping (authoritative)

Grounded in the verdict byte table (abi.md §10.2). The critical rule:
processing-succeeded-but-kernel-declined is **200**, not 4xx.

| Verdict / condition | Byte | HTTP | Body |
|---|---|---|---|
| `Ok` | 0 | `200` | `{ accepted: true, verdict: "Ok", admissionStage, seq }` |
| `NotAdmissible` (incl. `InsufficientBudget`) | 1 | `200` | `{ accepted: false, verdict: "NotAdmissible", reason }` |
| `ParseError` | 2 | `400` | `application/problem+json` |
| `Busy` | 3 | `503` + `Retry-After` | `application/problem+json` |
| auth/credential failure | — | `401` / `403` | problem+json |
| request too large | — | `413` | problem+json |
| rate limit | — | `429` + `Retry-After` | problem+json |
| upstream unreachable / timeout | — | `502` / `504` | problem+json |

**Why 200 for `NotAdmissible`.** A budget or policy rejection is a normal,
displayable outcome ("your stake was declined: insufficient budget"). If
mapped to 4xx, client query libraries (TanStack Query) treat it as an
error and may retry a deterministic rejection. The reason string is
passed through verbatim. (422 is a defensible alternative if a team
prefers error-channel semantics; this plan recommends 200 + body. See
OQ-GW-2, §11.)

**Forward path (`AdmissionStage`, §10.2.1).** Today `CommandKernel`
declares `ok_stage = Finalized`, so a synchronous `200` is truthful. A
future kernel that returns `Ok` at `LocallyAdmitted`/`Sequenced` should
switch the submit response to `202 Accepted` and either expose a status
resource to poll or push finalization over SSE. The verdict-in-body
design absorbs this without breaking clients.

## §6 Event streaming model

`GET /v1/events/stream` proxies an event-subscribe `SUBSCRIBE` session
(abi.md §11) as SSE. The §11 sequence-number invariants map onto SSE and
cursor pagination cleanly:

* **`id` = `seq`.** Each SSE record sets `id: <seq>`. Because seqs are
  monotonic and gap-free (§11.4), the browser's automatic `Last-Event-ID`
  on reconnect is a valid `resume_from`.
* **`Last-Event-ID` → `resume_from`.** The header takes precedence over
  the `since` query param. `0` (or absent) ⇒ live-tail.
* **`TRUNCATED` → stream error then close.** If the resume cursor predates
  the keep-history window (§11.3), the gateway emits `event: error` with
  an `EventStreamError { error: "truncated", oldestSeq }` payload and
  closes; the client restarts from `oldestSeq`. The same condition on the
  REST `GET /events` backfill is a `409` carrying `oldestSeq`.
* **Within-frame equal seqs.** Multiple events sharing one seq (e.g. a
  transfer's sender+receiver `balanceChanged`, §11.4) are emitted as
  separate SSE records with the same `id`, in `extractEvents` push order.
* **Heartbeat.** Periodic `:\n` comment lines defeat idle-proxy timeouts.
* **`LAG_EXCEEDED` / `SERVER_SHUTDOWN`** (§11.2) surface as `event: error`
  records (`lag_exceeded` / `server_shutdown`) before close.

## §7 Consistency and caching

* **Source of truth for reads is the indexer**, which is eventually
  consistent with the canonical log. Every read returns `X-Knomosis-Seq`
  = the indexer cursor it reflects.
* **Reconciliation pattern.** A client that just submitted an action
  (and learned the resulting `seq` from the verdict, or from the event
  stream) can poll a balance until `X-Knomosis-Seq >= that seq`, or
  simply drive UI off the SSE stream and treat REST reads as a
  cold-start/refresh snapshot.
* **Caching.** Read responses carry a weak `ETag` derived from
  `(resource-key, cursor)` and a short `Cache-Control`; `If-None-Match`
  yields `304`. SSE responses are `no-store`.
* **Authoritative-read gap (known).** There is no kernel/host
  `getBalance` today — `runtime/README.md` flags it as the open follow-up
  blocking `knomosis-indexer --verify-against-knomosis`. Until it exists,
  `/v1/actors/.../balances*` is **indexer-only**. Building that read path
  is phase G6 (§10) and tracked as OQ-GW-1 (§11). Per the project's
  implement-the-improvement rule this is a real deliverable, not a caveat
  to document away.

## §8 Security model

1. **Service-to-service auth.** The BFF presents a bearer service token
   (or mTLS). This is not a user credential; end-user authN/session stays
   at the BFF edge (Licio's `SESSION_SECRET` / Redis). Schemes:
   `bearerAuth`, `mtls` in the OpenAPI `securitySchemes`.
2. **Key custody.** The gateway accepts **pre-signed** `SignedAction`
   bytes and never holds user signing keys, preserving the kernel's
   opaque-`Verify` / EUF-CMA trust model. *Who* signs — the user's
   wallet, or a custodial BFF-side signer — is a deployment decision
   (OQ-GW-3) that the API shape does not foreclose.
3. **CORS.** The gateway is called server-side by the BFF, so CORS is
   normally unnecessary at the gateway; if a deployment calls it from the
   browser, the allowed origin is config-driven (mirrors Licio's
   `CORS_ORIGIN`).
4. **TLS termination.** `knomosis-event-subscribe` is plain-TCP-only in
   v1 (abi.md §11.5); the gateway terminates HTTPS for the web regardless
   (`knomosis-host::tls` rustls config is reusable).
5. **Rate limiting + size caps.** Per-credential limits → `429` +
   `Retry-After`; oversized submissions → `413`. Both defend the bounded
   host queue (whose own overflow surfaces as `Busy`/`503`).
6. **Idempotency.** `Idempotency-Key` (the action nonce is a natural
   choice) lets the gateway dedup in-flight retries; `replay_impossible`
   guarantees a replayed action is a deterministic `NotAdmissible`.

## §9 Mapping to Knomosis internals

| Gateway concern | Reuses | ABI |
|---|---|---|
| Submit forwarding | `knomosis-host` client + CBE encoder | §10.1 frames, §10.2 verdicts |
| Verdict reasons (e.g. `InsufficientBudget`) | host reason field | §10.2.2 |
| Admission stage in `/info` | host `ok_admission_stage` | §10.2.1 |
| Event backfill + SSE | `knomosis-event-subscribe` client | §11.2–§11.6 |
| Balances / budgets / pools | `knomosis-indexer` / `knomosis-storage` views | §11A.2, §11A.4 |
| Event-type names | event-type registry (tags 0..22) | §11A.5 |

New crate: `runtime/knomosis-gateway/` (binary + lib), added to
`runtime/Cargo.toml` `[workspace] members` with the standard
`[lints.*]` blocks (per `runtime/README.md` "Adding a new crate").

## §10 Implementation phases

| Phase | Deliverable |
|---|---|
| G0 | This plan + the OpenAPI 3.1 sketch (THIS PR). |
| G1 | `knomosis-gateway` crate skeleton; read-only endpoints over the indexer view; `/healthz` `/readyz` `/info`. |
| G2 | `POST /v1/actions` forwarding to knomosis-host; verdict mapping; idempotency. |
| G3 | `GET /v1/events` backfill + `GET /v1/events/stream` SSE over event-subscribe. |
| G4 | Hardening: auth (bearer/mTLS), TLS termination, rate limits, size caps, structured logging/metrics. |
| G5 | OpenAPI codegen → typed TS client published for the Licio BFF; contract tests. |
| G6 | Authoritative `getBalance` read path (host/kernel), closing the §7 gap and wiring indexer `--verify-against-knomosis`. |

## §11 Open questions (candidates for `open_questions.md`)

* **OQ-GW-1 — Authoritative reads.** Build a kernel/host `getBalance` (and
  budget/pool) read path, or accept indexer-only reads for the front end?
  (Recommendation: build it — phase G6.)
* **OQ-GW-2 — `NotAdmissible` status.** `200 { accepted: false }` vs `422`.
  (Recommendation: `200` + body; revisit if a consumer needs error-channel
  semantics.)
* **OQ-GW-3 — Signing / key custody.** User-wallet signing vs custodial
  BFF-side signer; determines where keys live and the submit payload's
  provenance.
* **OQ-GW-4 — Licio contract surface.** Which concrete operations does
  Licio's "pay-to-rank firewall" need (submit a stake/rank action? read a
  topic's standing? subscribe to topic events?), and how do they map to
  Knomosis `Action`/`Event` tags? Requires reconciling against Licio's
  actual BFF routes, not its README.
* **OQ-GW-5 — Multi-deployment / tenancy.** One gateway per deployment id,
  or a multiplexing gateway keyed on deployment id?

## §12 References

* Contract: [`docs/api/gateway.openapi.yaml`](../api/gateway.openapi.yaml).
* Wire ABIs: `docs/abi.md` §10 (network), §11 (event subscription), §11A
  (indexer storage).
* Runtime crates: `runtime/README.md`; `docs/planning/rust_host_runtime_plan.md`.
* Admission stages: `docs/abi.md` §10.2.1; `runtime/knomosis-host/src/admission.rs`.
* Licio: https://github.com/hatter6822/Licio (React 19 PWA + Hono BFF + Postgres/pgvector + Redis).
* Problem details: RFC 9457. SSE: WHATWG HTML "Server-sent events". Contract format: OpenAPI 3.1.
