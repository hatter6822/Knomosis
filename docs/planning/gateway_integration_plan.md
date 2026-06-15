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
(first consumer: **Licio**, https://github.com/hatter6822/Licio) can
submit actions and read state without speaking the raw CBE wire protocols.

The companion machine-readable contract is
[`docs/api/gateway.openapi.yaml`](../api/gateway.openapi.yaml) (OpenAPI
3.1). This document owns the *rationale*, the *ABI mappings*, and the
*work breakdown*; the YAML owns the *shapes*. The two are kept consistent
(see §16).

## Status

> **DRAFT — not started, not ratified.** Contract sketch + engineering
> plan only. No `knomosis-gateway` crate exists; no roadmap table in
> `CLAUDE.md` / `README.md` / `GENESIS_PLAN.md` is amended. Promoting this
> to a sanctioned workstream requires sign-off (see §11 G0, §14).

There is currently **zero coupling** between the repositories: Knomosis's
source has no reference to Licio, and Licio references "Knomosis topics"
only behind a crypto feature flag that is OFF by default. This is
greenfield integration design, not the repair of an existing seam.

> **Correctness audit (this revision).** A grounding pass against `abi.md`
> §10/§11/§11A corrected five first-draft assumptions, now reflected
> throughout and in the spec: (a) the host verdict frame returns no `seq`
> (§5); (b) actor/resource are `u64` ids and balances `u128` (§3.6);
> (c) the indexer `budget.remaining` is a conservative lower bound, not the
> authoritative budget (§3.6); (d) pools are per-(pool-actor, resource∈
> {ETH,BOLD}) and net-vs-gross depends on indexer config (§3.6); (e) the
> `runtime/` workspace forbids `tokio`, so the gateway is a *synchronous*
> server (§3.2). See §16 for the full changelog.

## §1 Motivation and context

### §1.1 The impedance mismatch

| | Knomosis exposes | Licio expects |
|---|---|---|
| Transport | TCP / TLS / Unix sockets | HTTPS |
| Encoding | CBE (binary) frames | JSON |
| Write | length-prefixed `SignedAction` → verdict byte (§10) | `fetch` to an HTTP endpoint |
| Events | custom `SUBSCRIBE` framing (§11) | SSE / WebSocket |
| Read | `knomosis-indexer` CLI / SQLite (§11A) — no network API | HTTP GET |
| Consumer | sequencer / daemon | Hono BFF (TypeScript) |

A browser cannot speak Knomosis's protocols, and re-implementing CBE
encoding + action signing inside the BFF would duplicate the load-bearing
Lean↔Rust byte-equivalence contract in a third language. The gateway
terminates the binary protocols on the Knomosis side and exposes a thin,
stateless HTTP/JSON + SSE surface.

### §1.2 Why a Rust gateway crate (not a TypeScript client)

* **Byte-equivalence preserved.** Reuses the audited Rust CBE encoder and
  the host / event-subscribe / storage clients; signed bytes and event
  decoding stay on the verified stack.
* **Key custody stays server-side.** Signing material never reaches the
  browser-adjacent BFF; the gateway forwards pre-signed actions (§8.2).
* **Thin BFF.** Licio's Hono layer becomes a plain authenticated HTTP/SSE
  client (`fetch` + `EventSource`).

### §1.3 Non-goals

* **Not a signer.** The gateway never holds user keys or constructs
  signatures (§8.2).
* **Not a kernel.** No admissibility logic; it forwards to `knomosis-host`
  and reports the verdict verbatim.
* **Not an indexer.** It reads existing indexer views; it does not derive
  new state (the authoritative read path is a *separate* Lean/host change,
  G6).
* **Not a session/identity store.** End-user authN, sessions, and CORS for
  the browser live at the Licio BFF edge.
* **Not a public multi-tenant API (v1).** One trusted consumer; hardening
  for untrusted callers is explicitly scoped later (§8, OQ-GW-5).

## §2 Design principles

1. **REST for reads + submit, SSE for the live stream.** Pragmatic
   REST/HTTP+JSON (resource GETs + a command `POST /actions`) plus SSE for
   the tail, with `GET /events` cursor backfill as its complement. Not
   dogmatic HATEOAS — there is one trusted consumer.
2. **Verdict ≠ HTTP status.** HTTP status is the transport/validation
   outcome; the kernel verdict is a domain result in the body. A
   well-formed-but-declined action is `200 { accepted: false }` (§5).
3. **Opaque forwarding.** `POST /actions` forwards the client-signed CBE
   payload bytes unchanged; only the transport length-prefix frame (§10.1,
   not part of the signed content) is added/stripped.
4. **Eventual consistency, surfaced.** Reads come from the indexer view
   (§11A), which lags the log. Every read carries `X-Knomosis-Seq` (the
   cursor it reflects) plus a weak `ETag` for revalidation.
5. **Big integers as strings.** Amounts/balances (`u128`), ids (`u64`),
   nonces and sequence numbers are decimal strings end-to-end — JSON/JS
   loses precision past 2^53.
6. **Stateless by default.** No durable state of its own; cursors and
   idempotency keys are client-supplied. The two pragmatic exceptions
   (idempotency-response cache, SSE fan-out ring buffer) are bounded,
   in-memory, and TTL'd (§3.3, §8).
7. **Security-first, fail-closed.** AuthN is present from the first
   endpoint (not bolted on); unknown verdict/frame bytes, decode failures,
   and upstream faults fail closed (reject, never silently pass).
8. **Backpressure propagation.** The host's `Busy` and the
   event-subscribe lag/eviction signals are surfaced as first-class HTTP
   semantics (`503`+`Retry-After`, SSE `event: error`), never hidden.
9. **Minimal, auditable dependencies.** Honour the workspace ethos: no
   `tokio`; prefer std + a small vetted HTTP layer (or hand-rolled, as
   `knomosis-host` does); reuse `knomosis-host::tls` for TLS (§3.2).
10. **Observable.** Structured logs, request ids, and upstream-latency
    metrics from G1 (§7), so production behaviour is debuggable.
11. **Versioned contract.** `/v1` path prefix; the OpenAPI document is the
    single source of truth and the basis for a generated TS client.

## §3 Architecture

### §3.1 Component view

```
        Browser PWA (React 19)
              │  HTTPS / JSON, EventSource (SSE)
              ▼
        Licio Hono BFF  ── user sessions (Redis), CORS, user authN ──┐
              │  HTTPS / JSON + SSE   (bearer service token / mTLS)
              ▼
   ┌────────────────  knomosis-gateway (NEW Rust crate, runtime/)  ─────────────────┐
   │  synchronous (no tokio); reuses CBE encoder + host/storage clients; TLS via     │
   │  knomosis-host::tls; stateless except bounded idempotency cache + SSE ring       │
   │                                                                                  │
   │   POST /v1/actions ───────► knomosis-host        (CBE frame §10; pooled conns)   │
   │   GET  /v1/actors/.../*  ─► knomosis-storage      (indexer SQLite, read-only §11A)│
   │   GET  /v1/events ────────► knomosis-event-subscribe (SUBSCRIBE §11; backfill)   │
   │   GET  /v1/events/stream ► knomosis-event-subscribe (multiplexed fan-out → SSE)  │
   └──────────────────────────────────────────────────────────────────────────────────┘
```

### §3.2 Constraints inherited from the `runtime/` workspace

These are hard constraints (per `CLAUDE.md` workspace conventions and
`runtime/README.md`) that shape every work unit below:

* **No `tokio`.** The gateway is a **synchronous, thread-based** server
  (mirrors `knomosis-host`: one acceptor thread per transport + a bounded
  worker/handler pool). This rules out `axum`/`hyper`/`warp`. SSE is served
  by a dedicated handler thread per stream (bounded by a max-streams cap),
  fed by the fan-out ring (§3.3). The HTTP/1.1 layer is either a small
  vetted sync crate or hand-rolled on `std::net` + `knomosis-host::tls`
  (decision = OQ-GW-8; recommend hand-rolled for dep minimality + audit
  parity, scoped to the small surface this API needs).
* **Pinned toolchain + lints.** Inherits `rust-toolchain.toml` (stable
  1.83), `clippy::pedantic`, `unsafe_code = "forbid"`, `missing_docs`, and
  the four CI gates (`build`, `test`, `clippy -D warnings`, `fmt --check`).
* **Cross-stack discipline.** Any byte-level encode/decode the gateway
  performs (CBE framing, Event decode) reuses existing crates rather than
  re-implementing, preserving the `.cxsf` equivalence guarantees.

### §3.3 Upstream connection strategy

* **Host (write).** Maintain a **bounded pool of persistent connections**
  to `knomosis-host` (its `--persistent-connections` pipelined mode, §10.5)
  rather than connect-per-request. Cap in-flight requests to the host at or
  below its `--max-queue-depth`; surface saturation as `503` (§5). One-shot
  connect-per-request is the G2 fallback if pooling proves complex.
* **Reads.** Link `knomosis-storage` and open the indexer's SQLite database
  **read-only** (WAL deferred-read snapshots — concurrent with the live
  indexer writer). No subprocess, no new daemon. (Alternative: a future
  indexer *query server*; see §3.6 / OQ-GW-9.)
* **Events.** Do **not** open one upstream `SUBSCRIBE` per browser client —
  `knomosis-event-subscribe` enforces a subscriber-capacity cap (§11.7) and
  bounded-lag eviction (§11.6), so N browsers ⇒ N upstream subscribers would
  exhaust it. Instead **multiplex**: a small number of upstream subscriptions
  feed an in-gateway bounded ring buffer; each browser SSE stream is a cursor
  into the ring (§3.5, §6). This is the single most complex sub-system and is
  broken out into G3.4.

### §3.4 Submit request lifecycle (`POST /v1/actions`)

1. AuthN (bearer/mTLS); reject `401`/`403` on failure.
2. Enforce body size ≤ `max_frame_size` (default 1 MiB, ceiling 16 MiB,
   §10.1); else `413`.
3. Decode body: `application/json` → base64-decode `signedAction`, or
   `application/octet-stream` → raw bytes. Bad base64/JSON → `400`.
4. (Optional) Idempotency: if `Idempotency-Key` seen recently, return the
   cached response (§8.6); else proceed and record on completion.
5. Frame: prepend the 4-byte BE u32 length; write to a pooled host
   connection. The CBE payload is **not** re-encoded.
6. Read the response frame (1 verdict byte + 4-byte BE u32 reason len + M
   reason bytes, §10.1) under a deadline.
7. Map to HTTP per §5: `Ok`/`NotAdmissible` → `200` body; `ParseError` →
   `400`; `Busy` → `503`+`Retry-After`; deadline → `504`; conn error →
   `502`.
8. Note: the verdict frame has **no seq**, so `VerdictResponse.seq` is null
   today (OQ-GW-6); clients reconcile via the event stream (§7).

### §3.5 SSE stream lifecycle (`GET /v1/events/stream`)

1. AuthN; resolve start cursor = `Last-Event-ID` header (precedence) else
   `since` query else `0` (live-tail).
2. Register the client as a cursor into the fan-out ring (§3.3). If the
   requested cursor is older than the ring's oldest retained seq, the ring
   re-subscribes upstream with that `resume_from`; if upstream answers
   `TRUNCATED` (older than its keep-history window, §11.3), emit
   `event: error` (`{error:"truncated", oldestSeq}`) and close.
3. Stream records: `id: <seq>\nevent: <type>\ndata: <json>\n\n`. Events
   sharing a seq (within-frame, §11.4) are emitted as separate records with
   the same `id`, in `extractEvents` order.
4. Heartbeat `:\n` every `heartbeat_secs` to defeat idle-proxy timeouts.
5. If this client lags past `max_client_lag`, drop it (mirrors §11.6) with
   `event: error` (`lag_exceeded`); on upstream `SERVER_SHUTDOWN` (§11.2) or
   gateway graceful-shutdown, emit `event: error` (`server_shutdown`) and
   close so the browser's `EventSource` auto-reconnects elsewhere.

### §3.6 Read path and consistency model

* **Source of truth (today) = the indexer SQLite view** (§11A), eventually
  consistent with the canonical log. Every read returns `X-Knomosis-Seq` =
  the indexer `c/cursor` (§11A.3) it reflects.
* **Keys are numeric.** Balances are keyed by `(u64 actor, u64 resource)`
  with `u128` values (§11A.2); an absent cell is `"0"`. The API therefore
  models `actorId`/`resource` as decimal-string `u64` (well-known resources
  `0`=ETH, `1`=BOLD), **not** addresses. Address→id resolution (l1-ingest
  address book) is upstream and may become a gateway concern (OQ-GW-7).
* **Budget is a lower bound.** `BudgetView.remaining` =
  `freeTier + grants_this_epoch − consumed_this_epoch` (§11A.4); this equals
  the kernel's authoritative `currentBudget` only when `freeTier=0` or
  carryover ≤ `freeTier`, and is a **conservative lower bound** otherwise.
  The UI must not present it as exact until G6.
* **Pools** are per-(pool-actor, resource∈{ETH,BOLD}); the figure is *net*
  of drains only when the indexer runs with `--gas-pool-actor`, else *gross*
  (the `net` flag reports which; §11A.4).
* **Reconciliation pattern.** A client drives UI off the SSE stream and
  treats REST reads as a cold-start/refresh snapshot; to confirm a just-
  submitted change it polls until `X-Knomosis-Seq ≥ seq` (the seq learned
  from the event stream).
* **Authoritative reads (G6)** add a kernel/host `getBalance` so the gateway
  can optionally serve exact balances/budgets and label the read source.

## §4 Endpoint catalogue

| Method | Path | Purpose | Backed by | Consistency |
|---|---|---|---|---|
| POST | `/v1/actions` | Submit signed action → verdict | knomosis-host (§10) | synchronous |
| GET | `/v1/actors/{actorId}/balances` | All balances for an actor | indexer SQLite (§11A.2) | eventual |
| GET | `/v1/actors/{actorId}/balances/{resource}` | One balance | indexer SQLite (§11A.2) | eventual |
| GET | `/v1/actors/{actorId}/budget` | Epoch budget view (lower bound) | indexer SQLite (§11A.4) | eventual |
| GET | `/v1/pools/{poolId}` | Gas-pool view (net/gross flagged) | indexer SQLite (§11A.4) | eventual |
| GET | `/v1/events` | Cursor backfill | event-subscribe (§11.3) | ordered |
| GET | `/v1/events/stream` | Live SSE stream | event-subscribe (§11), fan-out | ordered |
| GET | `/v1/info` | Deployment + kernel metadata | host/§10.2.1 | live |
| GET | `/healthz`, `/readyz` | Liveness / readiness | gateway | live |

## §5 Verdict → HTTP status mapping (authoritative)

Grounded in the verdict byte table (§10.2). Rule: processing-succeeded-but-
kernel-declined is **200**, not 4xx.

| Verdict / condition | Byte | HTTP | Body |
|---|---|---|---|
| `Ok` | 0 | `200` | `{ accepted: true, verdict: "Ok", admissionStage }` |
| `NotAdmissible` (incl. `InsufficientBudget`) | 1 | `200` | `{ accepted: false, verdict: "NotAdmissible", reason }` |
| `ParseError` | 2 | `400` | problem+json |
| `Busy` | 3 | `503` + `Retry-After` | problem+json |
| auth/credential failure | — | `401` / `403` | problem+json |
| request too large (> max_frame_size) | — | `413` | problem+json |
| rate limit | — | `429` + `Retry-After` | problem+json |
| upstream unreachable / deadline | — | `502` / `504` | problem+json |

* **Why 200 for `NotAdmissible`.** A budget/policy rejection is a normal,
  displayable outcome; a 4xx would make client query libraries (TanStack
  Query) treat it as an error and retry a deterministic rejection. The
  reason string (`InsufficientBudget`, the `BudgetGate*` family, §10.2.2)
  is passed through. (422 is defensible if a consumer wants error-channel
  semantics — OQ-GW-2.)
* **No post-submit seq.** The host frame returns no seq (§10.1); `seq` is
  null until OQ-GW-6 is resolved.
* **Forward path (`AdmissionStage`, §10.2.1).** Today `CommandKernel`
  declares `ok_stage = Finalized`, so synchronous `200` is truthful. A
  future kernel returning `Ok` at `LocallyAdmitted`/`Sequenced` should
  switch to `202 Accepted` + a status resource or SSE finalization; the
  verdict-in-body design absorbs that non-breakingly.

## §6 Event streaming model

The §11 sequence-number invariants (monotonic, gap-free, never redelivered,
equal within a frame) map cleanly onto SSE + cursor pagination:

* **`id` = `seq`.** Each SSE record sets `id: <seq>`; the browser's
  automatic `Last-Event-ID` on reconnect is a valid `resume_from`.
* **`Last-Event-ID` → `resume_from`**, taking precedence over `since`;
  `0`/absent ⇒ live-tail.
* **`TRUNCATED` → 409 (REST) / `event: error` (SSE)** carrying `oldestSeq`
  (§11.3); the client restarts from `oldestSeq`.
* **`LAG_EXCEEDED` / `SERVER_SHUTDOWN`** (§11.2) → SSE `event: error`
  (`lag_exceeded` / `server_shutdown`) then close.
* **Within-frame equal seqs** (§11.4, e.g. a transfer's sender+receiver
  `balanceChanged`) → separate records, same `id`, in `extractEvents` order.
* **Event payloads.** The EVENT frame's bytes are a CBE `Event` with the
  9-byte tag head (§11.1); the gateway reuses
  `knomosis-event-subscribe::event_type` (`peek_event_tag`/`EventType`) +
  the `knomosis-indexer::decoder` mapping to render `{ seq, type, payload }`
  JSON for the frozen tags `0..=22` (§11A.5). Unknown future tags forward
  as `type: "unknown"` with raw base64 payload (forward-compatible, §11.1).

## §7 Cross-cutting concerns

* **Configuration.** All knobs are flags/env (no compiled-in addresses),
  mirroring `knomosis-host`/indexer style: listen addrs (HTTP + TLS), host
  upstream addr, indexer SQLite path (or query addr), credentials, TLS
  cert/key, timeouts/deadlines, `max_frame_size`, pool/queue caps,
  `heartbeat_secs`, `max_streams`, `max_client_lag`, rate-limit caps. Full
  table in §9.2.
* **Observability.** Structured logging via `tracing` (workspace-standard);
  a request id per call echoed in `problem+json` `instance`; counters +
  latency histograms for upstream calls and per-endpoint status; an
  operator-only metrics surface (OQ-GW-10: log-based vs `/metrics`).
* **Error taxonomy.** One `Problem` (RFC 9457) responder; every error path
  maps to a typed problem with a stable `type` URI. Verdict reasons ride in
  `knomosisReason`; truncation in `oldestSeq`.
* **Deadlines everywhere.** Connect/read/write timeouts on every upstream
  op; no unbounded waits. Submit has an end-to-end deadline → `504`.
* **Resource governors.** Max concurrent connections, max SSE streams,
  bounded handler pool, bounded idempotency cache, bounded fan-out ring —
  all configurable, all fail-closed to `503`.
* **Graceful shutdown.** Drain in-flight submits; emit SSE `server_shutdown`
  to stream clients; close pools cleanly.
* **Versioning/compat.** `/v1` prefix; additive changes only within v1;
  breaking changes ⇒ `/v2`. The OpenAPI `info.version` tracks the gateway
  crate; a CHANGELOG records contract deltas (G5).

## §8 Security model

1. **Service-to-service authN (from G1).** The BFF presents a bearer
   service token (constant-time compare) or mTLS. This is not a user
   credential; end-user authN/session stays at the BFF edge (Licio's
   `SESSION_SECRET`/Redis). Schemes: `bearerAuth`, `mtls`.
2. **Key custody.** The gateway accepts **pre-signed** `SignedAction` bytes
   and never holds user signing keys, preserving the kernel's opaque-
   `Verify` / EUF-CMA trust model. *Who* signs (user wallet vs custodial
   BFF-side signer) is a deployment decision (OQ-GW-3) the API does not
   foreclose.
3. **AuthZ.** v1 is single-credential, all-or-nothing. Scoped tokens
   (read-only vs submit) are a forward extension (OQ-GW-5).
4. **CORS.** Normally unnecessary (server-side BFF caller); if browser-
   direct, the allowed origin is config-driven (mirrors Licio's
   `CORS_ORIGIN`).
5. **TLS termination.** event-subscribe is plain-TCP-only (§11.5); the
   gateway terminates HTTPS for the web regardless (reuse
   `knomosis-host::tls` rustls config, TLS 1.3 min).
6. **Idempotency.** `Idempotency-Key` (the action nonce is a natural value)
   keys a bounded TTL response cache so retries return the *same* response;
   independently, the kernel's nonce gate (`nonce_uniqueness`,
   `replay_impossible`) guarantees no double-apply even with the cache off.
7. **Abuse controls.** Per-credential rate limit (`429`+`Retry-After`),
   request size cap (`413`), max connections/streams. These also shield the
   host's bounded queue (whose own overflow is `Busy`/`503`).
8. **Fail-closed decoding.** Unknown verdict/frame bytes, malformed CBE, or
   ambiguous input are rejected, never passed through.

## §9 Configuration and deployment topology

This is the dev/staging/prod *service* architecture the gateway introduces
(distinct from the build/test toolchain). The gateway is one process in a
small fleet; it adds no new persistence of its own.

### §9.1 Service topology

```
            ┌───────────────┐   L1 JSON-RPC
   L1  ────►│ knomosis-l1-   │──────────────┐
            │ ingest         │              │ CBE SignedAction (§10)
            └───────────────┘              ▼
   ┌──────────────┐  log file   ┌──────────────────┐
   │ knomosis-host │◄───────────│ (sequencer / log) │
   └──────┬───────┘  advances    └─────────┬────────┘
          │ verdict                         │ tails
          │                        ┌────────▼─────────────┐
          │                        │ knomosis-event-       │
          │                        │ subscribe (§11)       │
          │                        └───┬──────────────┬────┘
          │                            │ subscribe    │ subscribe
          │                     ┌──────▼──────┐  ┌────▼─────────────┐
          │                     │ knomosis-   │  │ knomosis-gateway │
          │                     │ indexer     │  │  (fan-out → SSE) │
          │                     │ (SQLite)    │  └────┬─────────────┘
          │                     └──────┬──────┘       │ reads SQLite (RO)
          └─────────── pooled host conns ─────────────┘
                                       ▲                │
                                       └── HTTPS/JSON+SSE┘  ◄── Licio BFF
```

The gateway depends on three upstreams: `knomosis-host` (submit),
`knomosis-event-subscribe` (events), and the `knomosis-indexer` SQLite file
(reads). For reads it co-locates with the indexer (shared volume) or moves
to an indexer query server (OQ-GW-9) when they must run on separate hosts.

### §9.2 Configuration surface (flags / env)

| Flag (env) | Default | Purpose |
|---|---|---|
| `--listen` (`KNX_GW_LISTEN`) | `127.0.0.1:8080` | HTTP listen addr (loopback-safe default) |
| `--tls-listen` / `--tls-cert` / `--tls-key` | off | HTTPS listener (rustls, TLS 1.3 min) |
| `--host-addr` (`KNX_GW_HOST_ADDR`) | `127.0.0.1:7654` | knomosis-host upstream |
| `--host-pool-size` | `8` | persistent host connections |
| `--subscribe-addr` (`KNX_GW_SUBSCRIBE_ADDR`) | `127.0.0.1:7655` | event-subscribe upstream |
| `--indexer-db` (`KNX_GW_INDEXER_DB`) | — | indexer SQLite path (read-only) |
| `--auth-token-file` (`KNX_GW_AUTH_TOKEN_FILE`) | — | bearer token(s); file (not argv) for secrecy |
| `--max-frame-size` | `1 MiB` | submit body cap (ceiling 16 MiB) |
| `--request-deadline-ms` | `5000` | end-to-end submit deadline |
| `--max-connections` / `--max-streams` | `1024` / `256` | resource governors |
| `--heartbeat-secs` / `--max-client-lag` | `15` / `1024` | SSE keepalive / per-client lag bound |
| `--ring-capacity` | `4096` | SSE fan-out ring buffer depth |
| `--rate-limit-rps` | `100` | per-credential rate cap |
| `--idempotency-ttl-secs` | `120` (`0`=off) | idempotency-key response cache TTL |
| `--log-format` | `json` | structured logging |

Secrets (auth tokens, TLS keys) are passed by file path, never argv/env
value, and are read with restrictive permissions — consistent with the
l1-ingest `Zeroizing` key handling.

### §9.3 Dev mode

A `--dev` profile runs against **mock upstreams** (an in-process MockHost
returning a configurable verdict, an in-memory event generator, and a
seeded temp SQLite) so a Licio developer can run the BFF against a single
gateway binary with no full Knomosis stack — mirroring Licio's own
in-memory dev fallback (which seeds demo data when `DATABASE_URL`/`REDIS_URL`
are absent). This makes local end-to-end Licio↔gateway iteration cheap.

### §9.4 Staging / production

* TLS on; auth required; rate limits + governors tuned; metrics scraped.
* Horizontally scalable: the gateway is stateless apart from per-instance
  idempotency cache and SSE ring, so instances sit behind an L7 LB.
  Idempotency across instances is best-effort unless a shared store is
  added (OQ-GW-4); SSE clients pin to an instance for a connection's life.
* Secrets via the platform secret manager; bridge/pool keys live in
  l1-ingest/observer, never the gateway.
* Health-gated rollout: `/readyz` must pass (all upstreams reachable)
  before an instance receives traffic.

### §9.5 Runbook

A `docs/gateway_runbook.md` (G4 deliverable) follows the
`fault_proof_runbook.md` / `gas_pool_runbook.md` template: start/stop,
config reference, health/readiness, common failure signatures (host
`Busy`, event truncation, indexer lag), dashboards, and rollback.

## §10 Testing strategy

Testing is **continuous per work unit**, not a final phase. Layers:

1. **Unit** — framing/codec, verdict→status mapping, cursor math, ring
   buffer, idempotency cache, auth compare. Pure, fast, property-tested
   (`proptest`, as elsewhere in the workspace).
2. **Integration vs mock upstreams** — MockHost (verdict matrix:
   `Ok`/`NotAdmissible`+reason/`ParseError`/`Busy`), mock event-subscribe
   (resume/truncation/lag/shutdown), seeded SQLite. End-to-end through the
   real HTTP layer over an ephemeral socket (mirrors `knomosis-host`'s
   `tests/integration.rs`).
3. **OpenAPI contract tests** — validate live responses against
   `gateway.openapi.yaml` schemas; a CI gate fails on drift (G5).
4. **Cross-stack** — decode real `knomosis extract-events` output and assert
   the gateway's event JSON matches the Lean reference for tags `0..=22`
   (reuse the `.cxsf` corpus pattern).
5. **Load / soak** — a bench (mirroring `knomosis-bench`) for submit
   throughput and concurrent-SSE fan-out; soak for fd/memory leaks.
6. **Chaos** — upstream kill/restart, reorg-style cursor jumps, slow
   clients, conn drops (mirroring `knomosis-faultproof-observer`'s
   `tests/chaos.rs`).

CI: a new `.github/workflows/ci-gateway.yml` runs build/test/clippy/fmt on
`runtime/knomosis-gateway/**` changes plus the OpenAPI lint + contract
gate; Lean-only PRs do not trigger it.

## §11 Work breakdown

Each work unit is independently landable, reviewable, and tested (§10).
Size: **S** ≈ ≤1 day, **M** ≈ 2–4 days, **L** ≈ ≥1 week. `deps` lists
prerequisite WUs. Acceptance criteria are the definition-of-done.

### G0 — Contract and plan

* **G0.1 — OpenAPI 3.1 sketch** · S · deps: — · **DONE.**
  *Deliverable:* `docs/api/gateway.openapi.yaml`. *Acceptance:* parses;
  all `$ref`s resolve.
* **G0.2 — Integration plan** · S · deps: — · **DONE (this doc).**
  *Acceptance:* every endpoint mapped to an ABI section; risk register +
  WU breakdown present.
* **G0.3 — OpenAPI lint CI gate** · S · deps: G0.1.
  *Deliverable:* a spec linter (Spectral/Redocly) wired into CI; spec is a
  committed artifact checked for validity on every PR touching it.
  *Acceptance:* CI fails on an invalid/edited-without-lint spec.

### G1 — Crate skeleton + read path + auth + health

* **G1.1 — Crate scaffold** · S · deps: G0.
  *Deliverable:* `runtime/knomosis-gateway/` (lib+bin); workspace member;
  `[lints.*]`; CI workflow `ci-gateway.yml`; `--help`/config skeleton.
  *Acceptance:* `cargo build/test/clippy/fmt` green in CI for the crate.
* **G1.2 — Sync HTTP/TLS foundation** · M · deps: G1.1, OQ-GW-8.
  *Deliverable:* a no-tokio HTTP/1.1 server (acceptor thread + bounded
  handler pool), routing, `application/json` + `problem+json` plumbing, TLS
  via `knomosis-host::tls`. *Acceptance:* `/healthz` returns 200 over both
  HTTP and TLS; max-connections cap enforced; integration test over an
  ephemeral port.
* **G1.3 — Config + wiring** · S · deps: G1.1.
  *Deliverable:* the §9.2 flag/env surface with validation; secrets via
  file. *Acceptance:* invalid config fails fast with a typed error;
  `--help` documents every knob.
* **G1.4 — AuthN middleware** · S · deps: G1.2.
  *Deliverable:* bearer (constant-time) + optional mTLS; `security:[]`
  exemption for health. *Acceptance:* unauthenticated non-health request →
  401; wrong token → 403; timing-safe compare unit-tested.
* **G1.5 — Problem responder + error taxonomy** · S · deps: G1.2.
  *Deliverable:* one RFC 9457 responder; request-id `instance`.
  *Acceptance:* every error path emits a typed `Problem` matching the spec.
* **G1.6 — Read: balances** · M · deps: G1.2, G1.3.
  *Deliverable:* link `knomosis-storage`; open indexer SQLite read-only;
  `GET /actors/{id}/balances[/{resource}]`; `X-Knomosis-Seq` from
  `c/cursor`; weak `ETag`/`If-None-Match`→304; absent cell → `"0"`.
  *Acceptance:* values byte-match `knomosis-indexer query` on a seeded DB;
  unknown actor → empty list / `"0"`.
* **G1.7 — Read: budget + pools** · M · deps: G1.6.
  *Deliverable:* `GET /actors/{id}/budget` (with the lower-bound label) +
  `GET /pools/{poolId}` (with `net` flag). *Acceptance:* match
  `query-budget`/`query-pool-{eth,bold}`; budget caveat documented in the
  response schema.
* **G1.8 — `/info`, `/readyz`** · S · deps: G1.2.
  *Deliverable:* `/info` (deployment id, `ok_admission_stage`, protocol
  versions, indexer seq); `/readyz` probes all upstreams. *Acceptance:*
  `/readyz` flips 503 when an upstream is down.
* **G1.9 — Read-path tests** · S · deps: G1.6, G1.7.
  *Deliverable:* integration over seeded SQLite + contract tests for read
  endpoints. *Acceptance:* CI gate green.

### G2 — Submit path

* **G2.1 — Host client + connection pool** · M · deps: G1.2.
  *Deliverable:* §10.1 framing (4-byte BE len; verdict+reason parse);
  bounded persistent-connection pool; deadlines. *Acceptance:* round-trips
  against a MockHost; pool reuse + reconnect-on-drop tested.
* **G2.2 — `POST /actions` + verdict mapping** · M · deps: G2.1, G1.4,
  G1.5. *Deliverable:* json/base64 + octet-stream intake; opaque forward;
  §5 status mapping; reason pass-through. *Acceptance:* the full verdict
  matrix maps to the table in §5 (integration vs MockHost).
* **G2.3 — Backpressure + limits** · S · deps: G2.2.
  *Deliverable:* `Busy`→`503`+`Retry-After`; deadline→`504`; conn-fail→
  `502`; `413` size cap; bounded in-flight to host. *Acceptance:* each
  condition produces the mapped status under test.
* **G2.4 — Idempotency cache** · S · deps: G2.2.
  *Deliverable:* bounded TTL `Idempotency-Key`→response cache (off when
  ttl=0). *Acceptance:* duplicate key within TTL returns the cached
  response; eviction + disable paths tested.
* **G2.5 — Submit tests** · S · deps: G2.2.
  *Deliverable:* integration + contract + idempotency tests. *Acceptance:*
  CI gate green.

### G3 — Events: backfill + SSE

* **G3.1 — event-subscribe client** · M · deps: G1.2.
  *Deliverable:* §11.1/§11.2 framing (SUBSCRIBE `resume_from`; EVENT
  decode; TRUNCATED/LAG_EXCEEDED/SERVER_SHUTDOWN/INVALID_REQUEST handling).
  *Acceptance:* drives a mock server through every frame kind.
* **G3.2 — Event decode → JSON** · M · deps: G3.1.
  *Deliverable:* reuse `event_type::peek_event_tag` + indexer `decoder` to
  render `{seq,type,payload}` for tags `0..=22`; unknown→`type:"unknown"`+
  base64. *Acceptance:* cross-stack match vs `extract-events` output.
* **G3.3 — `GET /events` backfill** · S · deps: G3.1, G3.2.
  *Deliverable:* `since`/`limit`/`type`; cursor pagination; `409`+`oldestSeq`
  on truncation. *Acceptance:* paginates a mock history; truncation maps to
  409.
* **G3.4 — SSE fan-out (the complex sub-system)** · L · deps: G3.1, G3.2.
  * **G3.4a — Ring buffer + cursor registry** · M. Bounded ring of recent
    events; per-client cursor; oldest-retained tracking. *Acceptance:*
    property tests for ordering/gap-freeness vs an oracle.
  * **G3.4b — Upstream multiplexing** · M · deps: G3.4a. A small pool of
    upstream subscriptions feeds the ring; reference-counted; resubscribe on
    drop. *Acceptance:* N SSE clients ⇒ O(1) upstream subscribers (not N);
    verified under a concurrency test.
  * **G3.4c — Per-client dispatch + eviction** · M · deps: G3.4a. Stream
    records; heartbeat; drop clients past `max_client_lag` with
    `event: error`. *Acceptance:* slow-client eviction does not stall fast
    clients (chaos test).
  * **G3.4d — Resume semantics** · S · deps: G3.4a/b. `Last-Event-ID`/`since`
    served from ring; if older than ring window, resubscribe upstream; if
    older than upstream history, `event: error{truncated, oldestSeq}`.
    *Acceptance:* reconnect from each tier behaves correctly.
* **G3.5 — `GET /events/stream` wiring + tests** · S · deps: G3.4.
  *Deliverable:* the SSE endpoint atop fan-out; `no-store`. *Acceptance:*
  reconnect/resume/truncation/lag integration + contract tests green.

### G4 — Hardening + runbook

* **G4.1 — Rate limiting** · S · deps: G2, G3. Per-credential token bucket →
  `429`+`Retry-After`. *Acceptance:* limit enforced; headers correct.
* **G4.2 — TLS/mTLS hardening** · S · deps: G1.2. mTLS option; cipher/proto
  floor; cert rotation note. *Acceptance:* mTLS round-trip; weak-proto
  rejected.
* **G4.3 — Observability** · M · deps: G1–G3. `tracing` logs, request ids,
  upstream-latency + status metrics. *Acceptance:* metrics exposed;
  log-correlation by request id verified.
* **G4.4 — Resource governors + graceful shutdown** · S · deps: G1–G3.
  Max streams/conns; drain on shutdown; SSE `server_shutdown`. *Acceptance:*
  shutdown drains submits and closes streams cleanly.
* **G4.5 — Security review + dep audit** · S · deps: G1–G4. Threat-model
  pass; `cargo-deny`/audit. *Acceptance:* no advisories; review sign-off.
* **G4.6 — Load/soak/chaos** · M · deps: G1–G3. Bench + chaos suites
  (§10.5–§10.6). *Acceptance:* throughput target met; no leaks under soak.
* **G4.7 — `docs/gateway_runbook.md`** · S · deps: G4.1–G4.4. *Acceptance:*
  covers start/stop, config, health, failure signatures, rollback.

### G5 — Client + contract CI + versioning

* **G5.1 — Contract-test gate** · S · deps: G1–G3. Spin gateway w/ mock
  upstreams; schema-validate responses in CI. *Acceptance:* gate fails on
  drift.
* **G5.2 — Typed TS client** · M · deps: G0.1, G2, G3. Generate + publish a
  typed client for the Licio BFF. *Acceptance:* BFF compiles against it;
  example calls in CI.
* **G5.3 — Versioning + CHANGELOG** · S · deps: G5.1. *Acceptance:* contract
  deltas recorded; `/v1` compat policy documented.

### G6 — Authoritative read path (closes the §3.6 gap)

* **G6.1 — Lean `getBalance`/query subcommand** · M · deps: —. Kernel-state
  read (balance/budget) from the canonical log; cross-stack tests.
  *Acceptance:* matches the kernel; axiom-clean (no new axioms).
* **G6.2 — host `getBalance` endpoint** · M · deps: G6.1. Host protocol read
  op; `abi.md` §10 amendment + docs. *Acceptance:* host returns exact
  balances; backward-compatible framing.
* **G6.3 — Gateway authoritative-read mode** · M · deps: G6.2, G1.6. Optional
  exact reads; reconcile vs indexer; wire indexer `--verify-against-knomosis`.
  *Acceptance:* exact == indexer at quiescence; divergence surfaced.
* **G6.4 — Read-source labelling** · S · deps: G6.3. A header/field marks
  `indexed` vs `authoritative`. *Acceptance:* clients can distinguish.

### G7 — Deployment and ops

* **G7.1 — Service topology manifests** · M · deps: G1. Compose/k8s for
  {host, event-subscribe, indexer, gateway} + per-env config + secrets
  wiring. *Acceptance:* one-command bring-up in dev.
* **G7.2 — Dev profile** · S · deps: G1, G2, G3. `--dev` mock-upstream mode
  (§9.3). *Acceptance:* Licio BFF runs against a single gateway binary, no
  full stack.
* **G7.3 — Staging/prod rollout** · M · deps: G4, G7.1. TLS, scaling,
  health-gated rollout, secret manager. *Acceptance:* readiness-gated deploy
  works; documented.
* **G7.4 — Dashboards + alerts** · S · deps: G4.3, G7.3. *Acceptance:*
  alerts fire on upstream-down / error-rate / lag.

## §12 Dependency graph and sequencing

```
G0 ─► G1 ─┬─► G2 ─┐
          ├─► G3 ─┼─► G4 ─► G5
          └─► G7.2 │
G6 (independent Lean/host track) ─► G6.3 (needs G1.6) ─► G6.4
G7.1 (needs G1) ──────────────────► G7.3 (needs G4)
```

* **Critical path:** G0 → G1 → {G2, G3} → G4 → G5.
* **Parallelisable after G1:** G2 (submit) and G3 (events) are independent
  tracks; G7.2 (dev profile) can start once G1 exists.
* **Independent track:** G6 (Lean `getBalance` + host endpoint) has no
  dependency on G1–G5 until it integrates at G6.3, so it can proceed in
  parallel from day one.
* **First shippable slice:** G1 alone gives Licio a **read-only** integration
  (balances/budget/pools + health) — the fastest path to value, with no key
  custody and no write risk. G3 adds live UI; G2 adds writes.
* **Definition of done (per phase):** all sub-WU acceptance criteria met;
  `ci-gateway.yml` green; contract tests pass; docs updated in the same PR.

## §13 Risk register

| # | Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|---|
| R1 | No-tokio HTTP layer is more work than expected | Schedule | Med | Keep surface minimal; evaluate a small vetted sync crate (OQ-GW-8); reuse `knomosis-host` patterns |
| R2 | SSE fan-out correctness (ordering/eviction) | Correctness | Med | Split into G3.4a–d; property + chaos tests vs an oracle |
| R3 | Coupling to indexer SQLite schema | Maintenance | Med | Read via `knomosis-storage` lib, not raw SQL; pin schema; or move to a query server (OQ-GW-9) |
| R4 | Budget lower-bound shown as exact | Correctness/UX | Med | Schema label (done); authoritative read in G6 |
| R5 | No post-submit seq → confusing client reconciliation | UX | High | Reconcile via event stream (§7); revisit host extension (OQ-GW-6) |
| R6 | Gateway accidentally holds user keys | Security | Low | Principle §8.2: pre-signed bytes only; review gate (G4.5) |
| R7 | event-subscribe subscriber cap exhausted by many browsers | Availability | Med | Multiplexed fan-out (G3.4b) — O(1) upstream subs |
| R8 | Host queue saturation under load | Availability | Med | Pooling + bounded in-flight; `Busy`→`503`+`Retry-After` |
| R9 | Spec/impl drift | Integration | Med | Contract-test CI gate (G5.1); spec is the source of truth |
| R10 | Cross-instance idempotency gaps | Correctness (minor) | Low | Document best-effort; shared store optional (OQ-GW-4); kernel nonce still prevents double-apply |
| R11 | Licio's real needs differ from its README | Rework | Med | Resolve OQ-GW-11 (reconcile against actual BFF routes) before G5.2 |

## §14 Open questions

Format mirrors `docs/planning/open_questions.md`; promote there on sign-off.

* **OQ-GW-1 — Authoritative reads.** Build a kernel/host `getBalance`
  (+budget/pool) read path, or accept indexer-only reads? *Rec:* build it
  (G6); ship indexer-only first.
* **OQ-GW-2 — `NotAdmissible` status.** `200 {accepted:false}` vs `422`.
  *Rec:* `200` + body; revisit if a consumer needs error-channel semantics.
* **OQ-GW-3 — Signing / key custody.** User-wallet vs custodial BFF-side
  signer; determines where keys live and submit-payload provenance.
* **OQ-GW-4 — Cross-instance idempotency.** Per-instance cache vs a shared
  store (e.g. Licio's Redis). *Rec:* per-instance best-effort for v1; kernel
  nonce is the safety backstop.
* **OQ-GW-5 — AuthZ scopes / multi-tenancy.** Single all-or-nothing token vs
  read/submit scopes vs per-deployment tenancy. *Rec:* single token v1;
  scopes when a second consumer appears.
* **OQ-GW-6 — Post-submit seq.** Host extension to return the advanced seq
  vs gateway correlation via the event stream. *Rec:* stream correlation v1;
  measure demand before extending the host wire format.
* **OQ-GW-7 — Address→id resolution.** Does the gateway resolve on-chain
  addresses to `u64` actor ids (needs the l1-ingest address book) or does
  the BFF pass ids? *Rec:* BFF passes ids v1; revisit if the BFF lacks them.
* **OQ-GW-8 — HTTP library.** Hand-rolled HTTP/1.1 (dep-minimal, audit
  parity) vs a small vetted sync crate. *Rec:* prototype both for the narrow
  surface; default to hand-rolled if effort is comparable.
* **OQ-GW-9 — Read source.** Direct indexer-SQLite (co-located) vs a new
  indexer network query server (decoupled hosts). *Rec:* SQLite-direct v1;
  query server when host separation is required.
* **OQ-GW-10 — Metrics surface.** Log-based vs a `/metrics` endpoint. *Rec:*
  both behind config; default log-based, opt-in `/metrics`.
* **OQ-GW-11 — Licio contract surface.** Which concrete operations does the
  "pay-to-rank firewall" need (submit a stake/rank action? read a topic's
  standing? subscribe to topic events?), and how do they map to Knomosis
  `Action`/`Event` tags? Requires reconciling against Licio's actual BFF
  routes, not its README. *Blocks:* G5.2.

## §15 References

* Contract: [`docs/api/gateway.openapi.yaml`](../api/gateway.openapi.yaml).
* Wire ABIs: `docs/abi.md` §10 (network), §11 (event subscription), §11A
  (indexer storage); §10.2.1 (admission stages); §10.4 (backpressure);
  §11.1/§11.4 (event frames + seq invariants); §11A.2/§11A.4 (read views).
* Runtime crates: `runtime/README.md`; `docs/planning/rust_host_runtime_plan.md`.
* Reuse points: `knomosis-host::tls`, `knomosis-host` listener/queue,
  `knomosis-storage` SQLite, `knomosis-event-subscribe::event_type`,
  `knomosis-indexer::decoder`.
* Licio: https://github.com/hatter6822/Licio (React 19 PWA + Hono BFF +
  Postgres/pgvector + Redis).
* Standards: RFC 9457 (Problem Details); WHATWG HTML "Server-sent events";
  OpenAPI 3.1.

## §16 Revision history

* **v0.2 (this revision).** End-to-end refinement. Correctness audit
  against `abi.md` corrected: (a) verdict frame returns no `seq`; (b)
  actor/resource are `u64` ids, balances `u128`; (c) budget `remaining` is a
  conservative lower bound; (d) pools are per-(pool-actor, resource∈
  {ETH,BOLD}), net/gross by config; (e) no-tokio ⇒ synchronous server.
  Expanded the complex sub-systems (submit + SSE fan-out lifecycles, upstream
  connection strategy) and broke every phase into sized, dependency-ordered
  work units (G0–G7). Added: non-goals, constraints, cross-cutting concerns,
  configuration + dev/staging/prod topology, testing strategy, dependency
  graph, risk register, and OQ-GW-1..11. Spec updated in lockstep (§schemas
  for ActorId/Resource/BudgetView/PoolView/VerdictResponse).
* **v0.1.** Initial contract sketch + plan (phases G0–G6, OQ-GW-1..5).
