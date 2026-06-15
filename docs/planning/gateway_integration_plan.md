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
(see §15B for the spec-delta ledger and §16 for the changelog).

## Status

> **DRAFT — not started, not ratified.** Contract sketch + engineering
> plan only. No `knomosis-gateway` crate exists; no roadmap table in
> `CLAUDE.md` / `README.md` / `GENESIS_PLAN.md` is amended. Promoting this
> to a sanctioned workstream requires sign-off (see §11 G0, §14, and the
> promotion checklist in §15A).

There is currently **zero code coupling** between the repositories:
Knomosis has no reference to Licio, and a reconciliation against Licio's
actual `apps/api` BFF (§1.4) confirms it has **no Knomosis client,
package, or route** — the integration is a *dark feature* gated by a
fail-closed `/v1/feature-flags` "crypto" flag that withholds Knomosis
topics while off. This is greenfield integration design, not the repair
of an existing seam.

> **Correctness audit (v0.4; event-streaming hardened in v0.5 after the
> #129 review — see §16).** A second grounding pass —
> this time against the *actual Rust crate surfaces* (`knomosis-host`,
> `knomosis-storage`, `knomosis-indexer`, `knomosis-event-subscribe`,
> `knomosis-cli-common`), not just `abi.md` — corrected or sharpened five
> load-bearing assumptions and is now reflected throughout:
>
>   1. **No read-only SQLite open exists.** Every `SqliteStorage::open*`
>      uses `SQLITE_OPEN_READ_WRITE | SQLITE_OPEN_CREATE` *and* runs
>      migrations. A read-only consumer therefore needs a **new
>      `knomosis-storage` open path** (G1.6a) — the gateway must not
>      create, migrate, or write the indexer's database. (§3.3, §3.6, R3.)
>   2. **SSE resume was latently lossy.** The v0.3 design attached the
>      same `id: <seq>` to every within-frame event (§11.4 equal-seq
>      groups). Per the WHATWG SSE spec the browser's last-event-ID
>      buffer only advances on an `id:` line, so a disconnect *mid-group*
>      resumes from that seq and **drops the group's tail**. v0.4 adopts a
>      **composite `id: "<seq>.<index>"`** with an intra-seq skip on
>      resume (§3.5, §6, G3.4a/d, R12).
>   3. **Reuse is deeper than v0.3 claimed.** `knomosis-indexer::decoder`
>      already richly decodes **all 23 frozen tags** (0..=22) into a typed
>      `Event`, and `knomosis-indexer::client::SubscribeClient` already
>      implements the §11 subscribe protocol. So event decode (G3.2) is a
>      JSON-rendering layer over `decode_event`, and the subscribe client
>      (G3.1) is reuse + reconnect orchestration — not a re-implementation
>      (§1.2, §3.7).
>   4. **CI must not duplicate.** `ci-rust.yml` already runs
>      `cargo build/test/clippy/fmt --workspace` on any `runtime/**`
>      change, so once the gateway is a workspace member those gates cover
>      it for free. `ci-gateway.yml` therefore carries only the
>      gateway-specific gates (OpenAPI lint + contract validation) (§10,
>      G0.3, G5.1).
>   5. **Concrete reuse points are now named with real signatures**
>      (`knomosis_host::{tls,frame,verdict,admission,kernel}`,
>      `knomosis_indexer::{client,decoder,balance,budget_view,cursor}`,
>      `knomosis_storage::{Storage,SqliteStorage,StorageSnapshot}`,
>      `knomosis_cli_common::{exit,logging}`) so the work units cite the
>      exact APIs they consume (§3.7).
>
> The v0.2 `abi.md` corrections still hold: (a) the host verdict frame
> returns no `seq` (§5); (b) actor/resource are `u64` ids and balances
> `u128` (§3.6); (c) the indexer `budget.remaining` is a conservative
> lower bound (§3.6); (d) pools are per-(pool-actor, resource∈{ETH,BOLD})
> and net-vs-gross depends on indexer config (§3.6); (e) `runtime/`
> forbids `tokio`, so the gateway is a *synchronous* server (§3.2). See
> §16 for the full changelog.

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

* **Byte-equivalence preserved, by reuse not re-implementation.** The
  gateway links the audited Rust crates rather than re-encoding anything:
  it **forwards** client-signed action bytes verbatim (no CBE *encode* on
  the write path — only the §10.1 length-prefix frame, via
  `knomosis_host::frame::encode_frame`), and it **decodes** events through
  `knomosis_indexer::decoder::decode_event` (the same typed `Event` the
  indexer uses, cross-stack-pinned against the Lean reference for all 23
  tags). The only new bytes the gateway authors are JSON. This keeps every
  CBE byte on the verified stack and out of a third language.
* **Key custody stays server-side.** Signing material never reaches the
  browser-adjacent BFF; the gateway forwards pre-signed actions (§8.2).
* **Thin BFF.** Licio's Hono layer becomes a plain authenticated HTTP/SSE
  client (`fetch` + `EventSource`).

### §1.3 Non-goals

* **Not a signer.** The gateway never holds user keys or constructs
  signatures (§8.2).
* **Not a kernel.** No admissibility logic; it forwards to `knomosis-host`
  and reports the verdict verbatim.
* **Not an indexer, and never a writer.** It reads existing indexer views
  through a **read-only** database handle (G1.6a); it does not derive new
  state, run migrations, or open the database read-write. The
  authoritative read path is a *separate* Lean/host change (G6).
* **Not a session/identity store.** End-user authN, sessions, and CORS for
  the browser live at the Licio BFF edge.
* **Not a public multi-tenant API (v1).** One trusted consumer; hardening
  for untrusted callers is explicitly scoped later (§8, OQ-GW-5).

### §1.4 Reconciliation with Licio's actual BFF (WS-D … WS-I)

Read directly from Licio's `apps/api` (Hono BFF), not its README. Findings
that shape this plan:

* **Structure.** A pnpm monorepo; the BFF is `apps/api` (entry `index.ts` →
  `app.ts`), routes mounted under `/v1` (`routes/v1.ts`), organised by
  workstreams WS-D (identity/auth) … WS-I (ranking). Packages: `db`,
  `invariants`, `ranking`, `shared` — **no `knomosis`/crypto package**, and
  no HTTP client/adapter in `lib/`. The integration is genuinely unbuilt.
* **The gate is real and fail-closed.** A `/v1/feature-flags` endpoint
  serves "fail-closed crypto/governance flags"; the crypto flag withholds
  every Knomosis topic while off. So the gateway can be **dark-launched** —
  deployed and validated end-to-end while Licio's flag stays off (§12).
* **Identity is SIWE.** Sessions are WebAuthn + email-OTP + **Sign-In With
  Ethereum**; `identity/crypto.ts` exposes an `accountRef`. Every user thus
  already has an Ethereum address — the anchor for actor-id resolution
  (resolves OQ-GW-7) and for client-side action signing (informs OQ-GW-3).
* **The product is attention-ranking.** "Pay-to-rank" is an *additive*,
  crypto-gated ranking signal layered on Licio's privacy-weighted attention
  model (`ranking/` + `pwatt/`), not a separate app.
* **Typed RPC.** The BFF exports a Hono RPC `AppType` and consumes typed
  clients; the gateway's OpenAPI-generated TS client (G5.2) slots in as one
  more typed dependency. (License: a GPL-3.0 client is compatible with
  Licio's AGPL-3.0-or-later app.)

**Integration mapping — the answer to OQ-GW-11.** No Knomosis routes exist
to map onto today; the realistic, evidence-based seams are:

| Licio seam (real) | Direction | Gateway endpoint | Knomosis ABI | Phase |
|---|---|---|---|---|
| Pay-to-rank / topic-gating consults Knomosis standing | **read** | `GET /v1/actors/{id}/balances/{resource}` · `/budget` · `/pools/{id}` | indexer §11A | **G1** |
| Identity (SIWE `accountRef`) → Knomosis actor id | resolve | BFF maps address→id (gateway helper optional) | l1-ingest address book | G1 / G6 |
| User "pays to rank" (stake/deposit) | **write** | `POST /v1/actions` (client-wallet-signed via SIWE) | host §10 | G2 |
| Topic-event surfacing into Licio's event pipeline | **stream** | `GET /v1/events/stream` (type-filtered) | event-subscribe §11 | G3 |

The decisive consequence: **Licio's first concrete consumer is read-only
pay-to-rank/topic-gating** — exactly the G1 slice — so the existing
sequencing (§12) is correct and now evidence-backed, and writes/streams
(key custody, SSE) are genuinely deferrable.

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
   not part of the signed content) is added/stripped. The gateway never
   decodes the action body — not even to read the nonce (which is why the
   idempotency key is *client-supplied*, §8.6).
4. **Eventual consistency, surfaced.** Reads come from the indexer view
   (§11A), which lags the log. Every read carries `X-Knomosis-Seq` (the
   cursor it reflects) plus a weak `ETag` for revalidation, and — for
   multi-key reads — a **snapshot** so the value and the seq it advertises
   are torn-read-free (§3.6).
5. **Big integers as strings.** Amounts/balances (`u128`), ids (`u64`),
   nonces and sequence numbers are decimal strings end-to-end; opaque byte
   fields (keys, commits, L1 addresses, policy blobs) are `0x`-hex strings.
   JSON/JS loses integer precision past 2^53, so *every* 64-bit-or-wider
   integer is a string, uniformly (§6.2).
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
   `tokio`; prefer std + reuse (`knomosis_host::tls` for TLS,
   `subtle` for constant-time compare, `serde_json` for JSON — all already
   in the workspace). New third-party crates are limited to a vetted
   `base64` and, if the §G1.0 spike chooses it, one small sync HTTP crate;
   each is justified in §3.7 and gated by the dep-audit (G4.5).
10. **Observable from G1.** Structured logs (`tracing`), request ids, and
    upstream-latency metrics from the first endpoint (§7), so production
    behaviour is debuggable; secrets are redacted at the logging boundary.
11. **Versioned contract.** `/v1` path prefix; the OpenAPI document is the
    single source of truth and the basis for a generated TS client. Spec
    and implementation are kept consistent by a CI contract gate (G5.1) and
    the spec-delta ledger (§15B).

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
   │  synchronous (no tokio); reuses CBE frame/decoder + host/storage clients; TLS   │
   │  via knomosis-host::tls; stateless except bounded idempotency cache + SSE ring   │
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
  vetted sync crate or hand-rolled on `std::net` + `knomosis_host::tls`
  (decision = OQ-GW-8, made by the **G1.0 spike**; recommendation:
  hand-rolled, for dep minimality + audit parity, scoped to the narrow
  surface this API needs — see §3.2.1).
* **Pinned toolchain + lints.** Inherits `rust-toolchain.toml` (stable
  1.83), `clippy::pedantic`, `unsafe_code = "forbid"`, `missing_docs`, and
  the four CI gates (`build`, `test`, `clippy -D warnings`, `fmt --check`)
  via `ci-rust.yml`'s `--workspace` run.
* **`panic = "abort"` ⇒ panic-free handlers (hard constraint).** The
  workspace `[profile.release]` sets `panic = "abort"`, and Cargo forbids a
  per-crate override, so in a production (release) build a panic in *any*
  handler thread aborts the **entire process** — every in-flight submit and
  every open SSE stream dies at once. `std::panic::catch_unwind` cannot
  rescue this (there is no unwinding under `abort`), so a server isolation
  boundary is *not* available; the only defense is **panic-freedom by
  construction**. Request-path code touching client-derived data uses
  checked operations (`get`/`?`/`checked_*` arithmetic) and never
  `unwrap`/`expect`/slice-indexing/`unreachable!`. The crate denies the
  `clippy::restriction` lints `unwrap_used`, `expect_used`,
  `indexing_slicing`, `panic`, and `unreachable` on the request-path
  modules, and the parser/decoder are adversarially `proptest`ed. (Tests
  run under the `dev`/`test` profile's `panic = "unwind"`, so a panic
  surfaces as a CI *failure* rather than a silent prod abort — making the
  no-panic property something CI actively proves, not assumes.) See R16.
* **MSRV + version lockstep.** `[workspace.package] version` (currently
  `0.7.2`) propagates to the new crate via `version.workspace = true`;
  per CLAUDE.md every PR bumps the patch component, and the Lean
  `lakefile.lean` version is bumped to the same value in lockstep (§15A).
* **Cross-stack discipline.** Any byte-level encode/decode the gateway
  performs (CBE framing, Event decode) reuses existing crates rather than
  re-implementing, preserving the `.cxsf` equivalence guarantees.

#### §3.2.1 The HTTP/1.1 feature subset (scoping the hand-rolled surface)

The gateway fronts a *single trusted server-to-server caller* (the BFF),
not the open web, so the HTTP surface it must implement is small and
explicitly bounded. The G1.0 spike validates this subset against both a
hand-rolled implementation and one candidate sync crate:

**Must support**

* HTTP/1.1 request line + headers, `Host`, `Content-Length`-delimited
  request bodies, `Connection: keep-alive`/`close`, persistent
  connections (one acceptor thread → bounded handler pool).
* `Content-Type` negotiation for `POST /actions` (`application/json`
  and `application/octet-stream`).
* Streaming responses with no `Content-Length` for SSE
  (`Content-Type: text/event-stream`, the connection held open, records
  flushed as they arrive — see §3.5).
* Standard status codes used by the contract (200/304/400/401/403/404/
  409/413/429/500/502/503/504) and the method/path error codes a router
  owes (404 unknown path, 405 + `Allow` for wrong method, 414 URI too
  long, 431 headers too large, 411/400 for a body without
  `Content-Length`).

**Explicitly reject / out of scope (v1)**

* `Transfer-Encoding: chunked` *request* bodies → `411 Length Required`
  (the BFF always knows its body length; chunked uploads are refused).
  Chunked *response* encoding is unnecessary because SSE streams use the
  connection-close-delimited identity body.
* HTTP/2 / HTTP/3. The BFF↔gateway hop is HTTP/1.1; the browser↔BFF hop
  (where HTTP/2's higher SSE connection ceiling matters) is Licio's edge,
  not ours. Browser-direct exposure (CORS path, §8.4) would want HTTP/2
  and is deferred (OQ-GW-5).
* `Expect: 100-continue` negotiation — the gateway may send an early
  `100 Continue` or simply read the body; the BFF does not depend on it.
* Trailers, pipelining of multiple in-flight requests per client
  connection (keep-alive sequential reuse is supported; true pipelining
  is not required).

**Reuse vs hand-roll boundary.** Even on the hand-rolled path the gateway
reuses `knomosis_host::tls` (rustls `ServerConfig` from PEM, TLS 1.3 min)
for TLS termination and evaluates reusing `knomosis_host::listener`'s
TCP/TLS/Unix acceptor + `--max-concurrent-connections` cap (the accept
loop is protocol-agnostic; only the *frame* it reads differs). The spike's
deliverable records whether the listener layer is reused or the gateway
hand-rolls its own acceptor (§G1.0).

### §3.3 Upstream connection strategy

* **Host (write) — pooled, one in-flight per connection.** Maintain a
  **bounded pool of persistent connections** to `knomosis-host` over its
  loopback **plaintext** TCP listener (the gateway co-locates with the
  host, so no TLS-to-host is needed; recall TLS-to-host is one-shot only,
  §10.5). Pooling requires the deployment to run `knomosis-host` with
  `--persistent-connections` (a *host*-side flag — the gateway is the
  client and cannot set it) so a connection survives across requests; if
  the host is one-shot, the pool degrades transparently to
  connect-per-request (the G2.1b fallback, and `/readyz` notes the mode).
  Each pooled connection is used **synchronously**: check out → write one
  v1 frame (`encode_frame`; no signer hint — the gateway is a single
  trusted client, §10.4.2 interop) → read one verdict frame → return to
  pool. This holds
  at most one in-flight request per connection, so it never relies on the
  host's pipelined response-ordering and is correct against both FIFO and
  DRR hosts. Cap concurrent checkouts at or below the host's
  `--max-queue-depth`; surface saturation as `503` (§5). Connect-per-
  request is the G2 fallback if pooling proves complex; pipelining several
  in-flight requests per connection is a deferred throughput optimization
  (G2.1c).
* **Reads — read-only, co-located SQLite.** Link `knomosis-storage` and
  open the indexer's SQLite database through a **new read-only open path**
  (G1.6a) — the existing `open*` functions are read-write + migrating and
  must not be used. WAL mode lets the gateway's reader run concurrently
  with the live indexer writer, but **only same-host** (WAL uses a shared-
  memory `-shm` file; it does not work over a network filesystem). So the
  gateway co-locates with the indexer (shared volume), and `/readyz`
  requires the indexer writer to be live (read-only WAL access needs the
  writer's `-shm`; §3.6, §9.4). No subprocess, no new daemon. A future
  indexer *query server* decouples the hosts (OQ-GW-9).
* **Events — multiplex, never one upstream sub per browser.** Do **not**
  open one upstream `SUBSCRIBE` per browser client —
  `knomosis-event-subscribe` enforces a subscriber-capacity cap (§11.7) and
  bounded-lag eviction (§11.6), so N browsers ⇒ N upstream subscribers would
  exhaust it. Instead **multiplex**: a *single* upstream live-tail
  subscription (default; `--upstream-subscriptions`) feeds an in-gateway
  bounded ring buffer, and each browser SSE stream is a cursor into the ring
  (§3.5, §6). One sub suffices because every subscriber to the §11 broadcast
  receives every event, so a second would double-ingest unless the mux dedups
  on `(seq, index)` (G3.4b, finding #6). A client whose
  resume point predates the ring is steered to the `GET /events` backfill
  path (§3.5 step 2) rather than rewinding the *shared* upstream — keeping
  upstream subscriber count O(1) in the number of browsers. This is the
  single most complex sub-system and is broken out into G3.4. The §11
  subscribe client itself is reused from
  `knomosis_indexer::client::SubscribeClient` (§3.7).

### §3.4 Submit request lifecycle (`POST /v1/actions`)

1. AuthN (bearer constant-time / mTLS); reject `401`/`403` on failure.
2. Enforce body size ≤ `max_frame_size` (default 1 MiB, ceiling 16 MiB,
   §10.1) *while reading* (stop at the cap, do not buffer unboundedly);
   else `413`.
3. Decode the request body to raw `SignedAction` bytes: `application/json`
   → base64-decode the `signedAction` field; `application/octet-stream` →
   the body verbatim. Bad base64 / bad JSON / empty body → `400`.
4. (Optional) Idempotency: if a client-supplied `Idempotency-Key` was seen
   within the TTL, return the cached response (§8.6); else proceed and
   record on completion. The key is opaque to the gateway (it never reads
   the action's nonce — §2 principle 3).
5. Frame: prepend the 4-byte BE u32 length (`encode_frame`); write to a
   pooled host connection under write/read deadlines. The CBE payload is
   **not** re-encoded.
6. Read the response frame: 1 verdict byte (`Verdict::from_byte`) + 4-byte
   BE u32 reason len + M reason bytes (§10.1), under the end-to-end
   deadline. An unknown verdict byte fails closed (`502`/`500`, never a
   silent pass).
7. Map to HTTP per §5: `Ok`/`NotAdmissible` → `200` body; `ParseError` →
   `400`; `Busy` → `503`+`Retry-After`; read/write deadline → `504`; conn
   error → `502`.
8. Note: the verdict frame has **no seq**, so `VerdictResponse.seq` is null
   today (OQ-GW-6); clients reconcile via the event stream (§7). The
   `admissionStage` reported is the kernel's declared `ok_admission_stage`
   (read from `/info`, today `Finalized`).

### §3.5 SSE stream lifecycle (`GET /v1/events/stream`)

The within-frame equal-seq invariant (§11.4) makes naïve `id: <seq>`
resume **lossy** (see the v0.4 audit note and §6.1). The gateway therefore
uses a **composite event id** `"<seq>.<index>"`, where `index` is the
0-based position of the record within its seq-group (the `extractEvents`
order). Lifecycle:

1. AuthN; resolve the start cursor. Precedence: `Last-Event-ID` header
   (browser auto-reconnect) → `since` query → `0`/absent (live-tail).
   * A composite `Last-Event-ID = "<seq>.<index>"` (the only id form the
     gateway ever emits) means "resume strictly **after** record
     `(resume_seq, resume_index)`" — so the next record is
     `(resume_seq, resume_index + 1)` if the seq-group continues, else the
     start of a later seq.
   * A `since=<seq>` query (or, defensively, a malformed bare
     `Last-Event-ID = "<seq>"`) is **seq-granular**: resume at `seq >
     since`, i.e. that seq's *whole* group is excluded (matching the §11.3 /
     OpenAPI `SinceCursor` "strictly greater than" contract — a client that
     already read seq `S` via REST does not want `S` re-streamed). The
     internal `(seq, index)` lower bound is therefore `(since, +∞)`, never
     `(since, −1)` (which would wrongly re-include the group).
2. Register the client as a cursor into the fan-out ring (§3.3). The live
   stream is served *only* from the shared ring — it holds **no** per-client
   upstream `SUBSCRIBE` — so it distinguishes exactly two cases (it cannot
   itself observe an upstream `TRUNCATED`; finding #7):
   * **resume point within the ring window** → serve directly from the
     ring starting just after `(resume_seq, resume_index)`.
   * **older than the ring's oldest retained seq** → the client is *behind
     the live ring*. The stream emits `event: error{behind, oldestSeq}`
     (`oldestSeq` = the ring's oldest) and closes; the client catches up via
     the `GET /events` backfill (a recent seq) and reconnects into the
     now-covering ring. This keeps upstream subscriber count O(1) and avoids
     a merge seam. **Whether the resume point predates *upstream* history
     (the real `truncated`/409) is decided by `GET /events`** — which is the
     only path that opens a per-request upstream `SUBSCRIBE` — not by the
     stream. (A seamless dedicated catch-up subscription that drains
     `[resume, ringOldest)` then hands off to the ring is a documented future
     optimization — OQ-GW-12.) Recovery (switch to backfill, then reconnect)
     is a *client*-side responsibility — a raw browser `EventSource` would
     merely retry the same cursor and loop, so the generated TS client
     (G5.2) encapsulates it.
3. Stream records as `id: <seq>.<index>\nevent: <type>\ndata: <json>\n\n`.
   Events sharing a seq (within-frame, §11.4) are emitted as consecutive
   records, each with its own `<index>`, so the browser's last-event-ID
   buffer advances per-record and a mid-group disconnect resumes *exactly*.
   For an in-window reconnect the gateway positions the client's ring cursor
   just after `(resume_seq, resume_index)`; because the ring holds each
   record discretely (G3.4a), "skip records with `index ≤ resume_index`" is
   a cursor comparison, **not** an upstream re-read (the upstream-reread form
   exists only in the deferred dedicated-catch-up path, §6.1, OQ-GW-12). The
   `index` is also carried inside the JSON `data` so a consumer doing its
   own accounting can dedup precisely.
4. Heartbeat `:\n` every `heartbeat_secs` to defeat idle-proxy timeouts;
   the heartbeat carries no `id:` (it must not move the resume cursor).
5. A per-record **write deadline** bounds a stalled browser (mirrors §11.5.1
   `--write-timeout-ms`); if this client lags past `max_client_lag`, drop
   it (mirrors §11.6) with `event: error` (`lag_exceeded`). On upstream
   `SERVER_SHUTDOWN` (§11.2) or gateway graceful-shutdown, emit
   `event: error` (`server_shutdown`) and close so the browser's
   `EventSource` auto-reconnects (carrying its last composite id).

### §3.6 Read path and consistency model

* **Source of truth (today) = the indexer SQLite view** (§11A), eventually
  consistent with the canonical log. Every read returns `X-Knomosis-Seq` =
  the indexer `c/cursor` (§11A.3) it reflects.
* **Read-only, snapshot-consistent.** The gateway opens the database via
  the **read-only** path (G1.6a; never read-write, never migrating). For a
  multi-key read (the all-balances list; the budget view, which combines
  grants + consumed + the cursor) it uses a single **`StorageSnapshot`**
  (`BEGIN DEFERRED`, the existing torn-read-free read path) so the value
  and the `X-Knomosis-Seq` it advertises are mutually consistent. A
  single-cell read (`/balances/{resource}`) is one atomic `get` plus a
  cursor read and tolerates the documented eventual-consistency window.
* **Keys are numeric.** Balances are keyed by `(u64 actor, u64 resource)`
  with `u128` values (§11A.2); an absent cell is `"0"`. The API therefore
  models `actorId`/`resource` as decimal-string `u64` (well-known resources
  `0`=ETH, `1`=BOLD), **not** addresses. Address→id resolution (l1-ingest
  address book) is upstream and may become a gateway concern (OQ-GW-7).
* **Budget is a lower bound, and `freeTier` is gateway-config-sourced.**
  `remaining = freeTier + grants_this_epoch − consumed_this_epoch`
  (§11A.4). The indexer DB stores `grants_this_epoch`,
  `consumed_this_epoch`, and the epoch (`c/current_epoch`), but **not**
  `freeTier`/`actionCost` (those are deployment-policy parameters absent
  from the indexer CLI). The gateway therefore takes `--free-tier` /
  `--action-cost` in its own config (which must match the deployment's
  budget policy) and combines them with the indexer counters via
  `knomosis_indexer::budget_view::BudgetReadView::remaining_this_epoch`.
  This `remaining` equals the kernel's authoritative `currentBudget` only
  when `freeTier=0` or carryover ≤ `freeTier`, and is a **conservative
  lower bound** otherwise; the UI must not present it as exact until G6.
* **Pools** are per-(pool-actor, resource∈{ETH,BOLD}); the figure is *net*
  of drains only when the *indexer* runs with `--gas-pool-actor`, else
  *gross*. The gateway reports which via the `net` flag; to know the value
  of `net` it reads its own `--gas-pool-actor` config (which must match the
  indexer's) — the indexer DB does not record whether drains were netted.
* **Reconciliation pattern.** A client drives UI off the SSE stream and
  treats REST reads as a cold-start/refresh snapshot; to confirm a just-
  submitted change it polls until `X-Knomosis-Seq ≥ seq` (the seq learned
  from the event stream).
* **Authoritative reads (G6)** add a kernel/host `getBalance` so the gateway
  can optionally serve exact balances/budgets and label the read source
  (`readSource: indexed | authoritative`, §15B).

### §3.7 Reuse map and crate dependency graph

The gateway is mostly *integration glue*. The table below is the
authoritative list of what it links and the exact APIs it consumes
(verified against the crate sources, not inferred). New code is the HTTP
layer, the verdict/event JSON mapping, the SSE fan-out, and the CLI.

| Sibling crate | Module / API consumed | Used by |
|---|---|---|
| `knomosis-host` (lib) | `tls::TlsConfigBuilder::load_pem_files` (rustls `ServerConfig`, TLS 1.3) | G1.2d |
| | `frame::{encode_frame, HARD_MAX_FRAME_SIZE, DEFAULT_MAX_FRAME_SIZE}` | G2.1a |
| | `verdict::Verdict::{from_byte,name}` (0=Ok,1=NotAdmissible,2=ParseError,3=Busy) | G2.1a, G2.2 |
| | `admission::AdmissionStage` (Received<LocallyAdmitted<Sequenced<Finalized) | G1.8, G2.2 |
| | `kernel::{Kernel, mock::MockKernel}` — dev profile only | G7.2 |
| | (evaluate) `listener` TCP/TLS/Unix acceptor + max-conn cap | G1.0/G1.2d |
| `knomosis-storage` (lib) | `Storage`, `StorageSnapshot`, `SqliteStorage` + **new** read-only open (G1.6a) | G1.6a |
| `knomosis-indexer` (lib) | `client::SubscribeClient::{connect, read_frame}` → `ServerFrame` (§11 client) | G3.1 |
| | `decoder::decode_event` → `event::Event` (all 23 tags, typed) | G3.2 |
| | `balance::BalanceView::{get, scan_all}` (`b/` keyspace) | G1.6b |
| | `budget_view::BudgetReadView::{get_actor_budget*, get_pool_eth/bold, remaining_this_epoch}` | G1.7 |
| | `cursor::read_cursor` (`c/cursor`); `c/current_epoch` | all reads |
| `knomosis-event-subscribe` (lib) | `event_type::{EventClass::classify, EventType, peek_event_tag}` (tag name + forward-unknown) | G3.2 |
| `knomosis-cli-common` (lib) | `exit::OperatorExitCode`, `logging::init` | G1.1, G1.3 |
| `subtle` (workspace) | `ConstantTimeEq` for bearer-token compare | G1.4 |
| `serde` / `serde_json` (workspace) | JSON request/response (de)serialization | G1.5, G2.2, G3.2 |
| `tracing` (workspace) | structured logs + spans | G4.3 |
| `thiserror` (workspace) | typed error enums | all |
| `proptest`, `tempfile` (workspace, dev) | property tests; seeded temp DBs | G1.9, G3.4 |
| **NEW** `base64` | decode the JSON `signedAction` wrapper (§3.4 step 3) | G2.2 |
| **NEW (opt)** `signal-hook` *or* self-pipe | SIGTERM/SIGINT → graceful drain (§7, G4.4) | G4.4 |
| **NEW (spike-gated)** small sync HTTP crate | only if G1.0 rejects hand-rolled | G1.2 |

```
                       knomosis-cli-common ──┐
 knomosis-host ──┐                           │
 knomosis-storage├─► knomosis-gateway ◄──────┘   + base64, subtle, serde_json,
 knomosis-indexer┘        ▲                          tracing, thiserror
 knomosis-event-subscribe ┘     (no tokio; no axum/hyper/warp)
```

Depending on `knomosis-indexer` (a lib+bin) links only its `rlib`, which
also transitively gives the gateway the `SubscribeClient` *and* the event
decoder — the two heaviest event-path pieces — for one dependency. This is
why the v0.4 plan **reuses** rather than re-implements both (§16).

## §4 Endpoint catalogue

| Method | Path | Purpose | Backed by | Consistency |
|---|---|---|---|---|
| POST | `/v1/actions` | Submit signed action → verdict | knomosis-host (§10) | synchronous |
| GET | `/v1/actors/{actorId}/balances` | All balances for an actor | indexer SQLite (§11A.2) | eventual (snapshot) |
| GET | `/v1/actors/{actorId}/balances/{resource}` | One balance | indexer SQLite (§11A.2) | eventual |
| GET | `/v1/actors/{actorId}/budget` | Epoch budget view (lower bound) | indexer SQLite (§11A.4) + config `freeTier` | eventual (snapshot) |
| GET | `/v1/pools/{poolId}` | Gas-pool view (net/gross flagged) | indexer SQLite (§11A.4) | eventual |
| GET | `/v1/events` | Cursor backfill | event-subscribe (§11.3) | ordered |
| GET | `/v1/events/stream` | Live SSE stream | event-subscribe (§11), fan-out | ordered |
| GET | `/v1/info` | Deployment + kernel metadata | host/§10.2.1 + indexer cursor | live |
| GET | `/healthz`, `/readyz` | Liveness / readiness | gateway | live |

## §5 Verdict → HTTP status mapping (authoritative)

Grounded in the verdict byte table (§10.2) and `knomosis_host::verdict`.
Rule: processing-succeeded-but-kernel-declined is **200**, not 4xx.

| Verdict / condition | Byte | HTTP | Body |
|---|---|---|---|
| `Ok` | 0 | `200` | `{ accepted: true, verdict: "Ok", admissionStage }` |
| `NotAdmissible` (incl. `InsufficientBudget`, the `BudgetGate*` family) | 1 | `200` | `{ accepted: false, verdict: "NotAdmissible", reason }` |
| `ParseError` | 2 | `400` | problem+json |
| `Busy` | 3 | `503` + `Retry-After` | problem+json |
| unknown verdict byte (forward-incompat) | — | `502` | problem+json (fail closed) |
| auth/credential failure | — | `401` / `403` | problem+json |
| request too large (> max_frame_size) | — | `413` | problem+json |
| rate limit | — | `429` + `Retry-After` | problem+json |
| upstream unreachable / deadline | — | `502` / `504` | problem+json |

* **Why 200 for `NotAdmissible`.** A budget/policy rejection is a normal,
  displayable outcome; a 4xx would make client query libraries (TanStack
  Query) treat it as an error and retry a deterministic rejection. The
  reason string (`InsufficientBudget`, the `BudgetGate*` family, §10.2.2)
  is passed through verbatim. (422 is defensible if a consumer wants
  error-channel semantics — OQ-GW-2.)
* **No post-submit seq.** The host frame returns no seq (§10.1); `seq` is
  null until OQ-GW-6 is resolved.
* **Forward path (`AdmissionStage`, §10.2.1).** Today `CommandKernel`
  declares `ok_stage = Finalized`, so synchronous `200` is truthful. A
  future kernel returning `Ok` at `LocallyAdmitted`/`Sequenced` should
  switch to `202 Accepted` + a status resource or SSE finalization; the
  verdict-in-body design absorbs that non-breakingly. The gateway reads the
  live stage from `/info` (the kernel's declared `ok_admission_stage`) and
  echoes it, rather than hard-coding `Finalized`.

## §6 Event streaming model

The §11 sequence-number invariants (monotonic, gap-free, never redelivered,
equal within a frame) map onto SSE + cursor pagination — but the within-
frame equal-seq case needs care (§6.1).

* **`id` = `<seq>.<index>` (composite).** Each SSE record sets
  `id: <seq>.<index>`; the browser's automatic `Last-Event-ID` on reconnect
  is decomposed to `(resume_seq, resume_index)` and re-resolved precisely
  (§6.1). For the *REST* backfill the cursor is the bare `seq` (`since`).
* **`Last-Event-ID` → resume**, taking precedence over `since`;
  `0`/absent ⇒ live-tail.
* **`TRUNCATED` → 409 (REST `/events` only)** carrying `oldestSeq` (§11.3);
  the client restarts from `oldestSeq`. Only the REST backfill opens a
  per-request upstream `SUBSCRIBE`, so only it can observe `TRUNCATED`; the
  live SSE stream — served from the shared ring with **no** per-client
  upstream sub — never emits `truncated` (a resume older than the ring is
  always `behind`, see below and finding #7).
* **`LAG_EXCEEDED` / `SERVER_SHUTDOWN`** (§11.2) → SSE `event: error`
  (`lag_exceeded` / `server_shutdown`) then close.
* **`decode_error`** (a known-tag payload fails to decode — corruption,
  §6.2 / G3.2b) → SSE `event: error` (`decode_error`) / REST problem, then
  close; fail-closed, never a silent skip.
* **Behind-the-ring** (gateway-internal, §3.5 step 2) → SSE `event: error`
  (`behind`, `oldestSeq` = the oldest seq the gateway ring still holds)
  steering the client to `GET /events` (which then surfaces a real
  `truncated`/409 if the point predates upstream history).

### §6.1 Within-frame equal seqs (the correctness centre)

Per §11.4, a single log frame can emit several events at the *same* seq
(e.g. a transfer's sender + receiver `balanceChanged`; the multi-actor
`distributeOthers` emits one per affected actor). Per the
[WHATWG SSE spec](https://html.spec.whatwg.org/multipage/server-sent-events.html),
the browser's *last-event-ID buffer* advances **only** when it parses an
`id:` line and **persists** across records otherwise. Consequences:

* **Naïve `id: <seq>` on every record is lossy.** If records `e0, e1`
  (both seq `S`) are sent and the connection drops after `e0`, the browser
  reconnects with `Last-Event-ID: S`; the server resumes at `seq > S` and
  **`e1` is never redelivered**. This is a silent gap — unacceptable for an
  ordered, gap-free stream.
* **Composite `id: "S.k"` is exact.** Each record carries its intra-seq
  index `k`. The *observable* contract on reconnect with `Last-Event-ID:
  "S.k"` is simply: the client receives **every record after `(S, k)` in
  `(seq, index)` order, with no loss and no duplication**. Two mechanisms
  realise it, by resume tier (§3.5 step 2):
  1. **In-window (the common case) — ring cursor.** The record is still in
     the fan-out ring, which holds each record discretely with its
     `(seq, index)` (G3.4a). The gateway positions the client's cursor just
     after `(S, k)` and streams forward; the "skip `index ≤ k`" is a single
     cursor comparison, with **no upstream I/O** (the shared live-tail subs
     keep feeding the ring — keeping upstream subscriptions O(1), §3.3).
  2. **Behind-window — backfill, then rejoin.** The record predates the
     ring; the client is steered to `GET /events?since=S-1` (seq-granular,
     whole groups; the REST `index` lives only in the body for dedup, not in
     the cursor) and reconnects into the now-covering ring. The optional
     *dedicated catch-up subscription* (OQ-GW-12) is the only path that
     would re-read the seq-`S` group from a fresh upstream `resume_from =
     S − 1` and skip `index ≤ k` itself; v1 does not use it.
  Either way: no loss, no spurious redelivery. The intra-seq index is
  bounded by `HARD_MAX_EVENT_COUNT` (§11.10), so a group is always finite.
* **`index` is also in the JSON `data`** (`{ seq, index, type, … }`) so a
  consumer maintaining its own ledger off non-idempotent typed events can
  dedup on `(seq, index)` independently of the transport.

This is the one place the gateway must *understand* the stream's structure
rather than relay it; it is split across G3.4a (ring records carry
`(seq, index)`), G3.4c (dispatch emits composite ids), and G3.4d (the
resume + intra-seq-skip algorithm), each property-tested against an oracle.

### §6.2 Event payload → JSON contract (all 23 frozen tags)

The gateway renders `{ seq, index, type, actor?, resource?, payload }` by:
(1) `event_type::classify` on the raw bytes to get the type *name* and to
forward unknown/future tags verbatim; (2) for a known tag,
`decoder::decode_event` → typed `Event`; (3) serialize the typed fields to
JSON under uniform rules. Serialization rules (§2 principle 5):

* `ActorId`, `ResourceId`, `Nonce`, ids (`WithdrawalId`, `DepositId`,
  `game_id`, `target_idx`, …) → **decimal strings**.
* `Amount` (`u128`), `BudgetUnits` → **decimal strings**.
* opaque byte fields (`key`, `commit`, `binding_hash`, `policy`,
  `recipient_l1`/`EthAddress`) → **`0x`-hex strings**.
* `outcome_tag` is surfaced both as the number and a name
  (`upheld`/`rejected`/`inconclusive`).

The per-tag JSON shapes (field names mirror
`knomosis_indexer::event::Event`, frozen against Lean):

| Tag | `type` | `payload` fields |
|---|---|---|
| 0 | `balanceChanged` | `resource, actor, oldValue, newValue` |
| 1 | `nonceAdvanced` | `actor, oldNonce, newNonce` |
| 2 | `identityRegistered` | `actor, key(hex)` |
| 3 | `identityRevoked` | `actor` |
| 4 | `timeRecorded` | `time` |
| 5 | `disputeFiled` | `challenger, targetIdx` |
| 6 | `disputeWithdrawn` | `disputeIdx` |
| 7 | `verdictApplied` | `disputeIdx, outcomeTag, outcome(name)` |
| 8 | `rewardIssued` | `resource, recipient, amount` |
| 9 | `withdrawalRequested` | `resource, sender, amount, recipientL1(hex), withdrawalId` |
| 10 | `depositCredited` | `resource, recipient, amount, depositId` |
| 11 | `localPolicyDeclared` | `actor, policy(hex)` |
| 12 | `localPolicyRevoked` | `actor` |
| 13 | `faultProofGameOpened` | `gameId, challenger, disputedStartIdx, disputedEndIdx, bindingHash(hex)` |
| 14 | `faultProofBisectionStep` | `gameId, round, party, idx, commit(hex)` |
| 15 | `faultProofGameSettled` | `gameId, winner, loser, payout` |
| 16 | `depositWithFeeCredited` | `resource, recipient, poolActor, userAmount, poolAmount, budgetGrant, depositId` |
| 17 | `actionBudgetTopUp` | `signer, gasResource, gasAmount, budgetIncrement, poolActor` |
| 18 | `gasPoolClaim` | `resource, sequencer, amount` |
| 19 | `delegatedActionBudgetTopUp` | `recipient, signer, gasResource, gasAmount, budgetIncrement, poolActor` |
| 20 | `budgetConsumed` | `actor, amount` |
| 21 | `ammSwapExecuted` | `fromResource, toResource, amountIn, amountOut, ammReserveActor` |
| 22 | `ammReservesReclaimed` | `resource, amount, reserveActor, poolActor` |
| ≥23 | `unknown` | `{ tag, raw(base64) }` (forward-compatible, §11.1) |

The top-level `actor`/`resource` projection (for the `EventTypeFilter` and
the OpenAPI `Event` schema) is the event's *subject* where one exists
(e.g. tag 0 → `actor`/`resource`; tag 8 → `recipient`/`resource`); absent
otherwise. The full fields always live in `payload`. A cross-stack test
(G3.2c) pins this rendering against `knomosis extract-events` output for
every tag.

## §7 Cross-cutting concerns

* **Configuration.** All knobs are flags/env (no compiled-in addresses),
  mirroring `knomosis-host`/indexer style: listen addrs (HTTP + TLS), host
  upstream addr, indexer SQLite path (or query addr), the budget-policy
  echo (`--free-tier`/`--action-cost`/`--epoch-length`) and
  `--gas-pool-actor` (for the pool `net` flag), credentials, TLS cert/key,
  timeouts/deadlines, `max_frame_size`, pool/queue caps, `heartbeat_secs`,
  `max_streams`, `max_client_lag`, `ring_capacity`, rate-limit caps. Full
  table in §9.2.
* **Observability.** Structured logging via `tracing` (workspace-standard,
  `knomosis_cli_common::logging::init`); a request id per call echoed in
  `problem+json` `instance` and on every log line; counters + latency
  histograms for upstream calls and per-endpoint status; an operator-only
  metrics surface (OQ-GW-10: log-based vs `/metrics`). **Secret redaction**
  at the logging boundary: the bearer token, TLS key bytes, and request
  bodies (which carry signed actions) are never logged.
* **Error taxonomy.** One `Problem` (RFC 9457) responder; every error path
  maps to a typed problem with a stable `type` URI under
  `https://knomosis/errors/…`. Verdict reasons ride in `knomosisReason`;
  truncation in `oldestSeq`; backpressure in `retryAfterMs`.
* **Deadlines everywhere.** Connect/read/write timeouts on every upstream
  op; no unbounded waits. Submit has an end-to-end deadline → `504`; SSE
  has a per-record write deadline (§3.5 step 5).
* **Resource governors.** Max concurrent connections, max SSE streams,
  bounded handler pool, bounded idempotency cache, bounded fan-out ring,
  bounded in-flight to host — all configurable, all fail-closed to `503`.
* **Graceful shutdown.** A SIGTERM/SIGINT handler flips an
  `Arc<AtomicBool>` stop flag; the server then drains in-flight submits,
  emits SSE `server_shutdown` to stream clients, closes pools cleanly, and
  exits `OperatorExitCode::Success`. This is a *justified deviation* from
  the other binaries (which rely on the Ctrl-C default, §10.6/§11.8) — the
  gateway holds long-lived SSE connections that warrant a clean
  `server_shutdown` rather than an abrupt FIN. Because the workspace sets
  `unsafe_code = "forbid"`, a raw `libc::signal` handler is not an option;
  **`signal-hook`** (which encapsulates the `unsafe` and is widely vetted)
  is the natural choice, justified in the G4.5 dep audit (R15). The drain is
  itself bounded by a deadline so a stuck stream cannot block shutdown
  indefinitely (G4.4).
* **Versioning/compat.** `/v1` prefix; additive changes only within v1;
  breaking changes ⇒ `/v2`. The OpenAPI `info.version` tracks the gateway
  crate; a CHANGELOG records contract deltas (G5.3); the spec-delta ledger
  (§15B) is the staging area for in-flight shape changes.

## §8 Security model

1. **Service-to-service authN (from G1).** The BFF presents a bearer
   service token (constant-time compare via `subtle::ConstantTimeEq`) or
   mTLS. This is not a user credential; end-user authN/session stays at the
   BFF edge (Licio's `SESSION_SECRET`/Redis). Schemes: `bearerAuth`,
   `mtls`. The token is read from a file (not argv/env value, §9.2) and
   redacted from logs.
2. **Key custody.** The gateway accepts **pre-signed** `SignedAction` bytes
   and never holds user signing keys, preserving the kernel's opaque-
   `Verify` / EUF-CMA trust model. *Who* signs (user wallet vs custodial
   BFF-side signer) is a deployment decision (OQ-GW-3) the API does not
   foreclose.
3. **AuthZ.** v1 is single-credential, all-or-nothing. Scoped tokens
   (read-only vs submit) are a forward extension (OQ-GW-5).
4. **CORS.** Normally unnecessary (server-side BFF caller); if browser-
   direct, the allowed origin is config-driven (mirrors Licio's
   `CORS_ORIGIN`) and `OPTIONS` preflight is answered for the documented
   methods/headers.
5. **TLS termination.** event-subscribe is plain-TCP-only (§11.5); the
   gateway terminates HTTPS for the web regardless (reuse
   `knomosis_host::tls`, rustls + `ring`, TLS 1.3 min). mTLS client-cert
   verification is the G4.2 hardening option.
6. **Idempotency.** A client-supplied `Idempotency-Key` (the BFF, which
   built the action, can use the action nonce) keys a bounded TTL response
   cache so retries return the *same* response; independently, the kernel's
   nonce gate (`nonce_uniqueness`, `replay_impossible`) guarantees no
   double-apply even with the cache off. The gateway never derives the key
   from the (opaque) body.
7. **Abuse controls.** Per-credential rate limit (`429`+`Retry-After`),
   request size cap (`413`), max connections/streams. These also shield the
   host's bounded queue (whose own overflow is `Busy`/`503`).
8. **Fail-closed decoding.** Unknown verdict/frame bytes, malformed CBE, or
   ambiguous input are rejected, never passed through (§5, §3.4 step 6).
9. **Read isolation.** The database handle is read-only (G1.6a) — the
   gateway *cannot* mutate the indexer's state even under a logic bug. The
   **preferred** mechanism is a pure `SQLITE_OPEN_READ_ONLY` open, where the
   OS / SQLite layer refuses writes *structurally* (the strongest guarantee,
   and it works in WAL when the indexer writer is live — which `/readyz`
   already requires). The documented **fallback** — read-write-without-
   `CREATE` + `PRAGMA query_only = ON`, used only if a storage read path
   provably needs a lock `READ_ONLY` cannot take, or to tolerate
   gateway-before-writer startup — blocks writes at runtime instead; G1.6a
   determines empirically which the storage read views require (§G1.6a).

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
          │                            │ subscribe    │ subscribe (O(1))
          │                     ┌──────▼──────┐  ┌────▼─────────────┐
          │                     │ knomosis-   │  │ knomosis-gateway │
          │                     │ indexer     │  │  (fan-out → SSE) │
          │                     │ (SQLite)    │  └────┬─────────────┘
          │                     └──────┬──────┘       │ reads SQLite (RO, same host)
          └─────────── pooled host conns ─────────────┘
                                       ▲                │
                                       └── HTTPS/JSON+SSE┘  ◄── Licio BFF
```

The gateway depends on three upstreams: `knomosis-host` (submit, loopback
plaintext), `knomosis-event-subscribe` (events, TCP), and the
`knomosis-indexer` SQLite file (reads, **read-only, same host**). For reads
it co-locates with the indexer (shared volume — WAL needs same-host shared
memory) or moves to an indexer query server (OQ-GW-9) when they must run on
separate hosts.

### §9.2 Configuration surface (flags / env)

| Flag (env) | Default | Purpose |
|---|---|---|
| `--listen` (`KNX_GW_LISTEN`) | `127.0.0.1:8080` | HTTP listen addr (loopback-safe default) |
| `--tls-listen` / `--tls-cert` / `--tls-key` | off | HTTPS listener (rustls, TLS 1.3 min) |
| `--mtls-client-ca` | off | require + verify client certs (G4.2) |
| `--host-addr` (`KNX_GW_HOST_ADDR`) | `127.0.0.1:7654` | knomosis-host upstream (loopback plaintext) |
| `--host-pool-size` | `8` | persistent host connections (one in-flight each) |
| `--host-max-inflight` | = pool size | cap concurrent host checkouts (≤ host `--max-queue-depth`) |
| `--subscribe-addr` (`KNX_GW_SUBSCRIBE_ADDR`) | `127.0.0.1:7655` | event-subscribe upstream |
| `--upstream-subscriptions` | `1` | shared live-tail subs feeding the ring (O(1) in clients); `>1` requires `(seq,index)` dedup in the mux (G3.4b, finding #6) |
| `--indexer-db` (`KNX_GW_INDEXER_DB`) | — | indexer SQLite path (opened read-only) |
| `--free-tier` / `--action-cost` / `--epoch-length` | `0`/`0`/`0` | budget-view rendering (must match the deployment policy) |
| `--gas-pool-actor` | off | sets the pool-view `net` flag (must match the indexer's) |
| `--auth-token-file` (`KNX_GW_AUTH_TOKEN_FILE`) | — | bearer token(s); file (not argv) for secrecy |
| `--max-frame-size` | `1 MiB` | submit body cap (ceiling 16 MiB) |
| `--request-deadline-ms` | `5000` | end-to-end submit deadline |
| `--max-connections` / `--max-streams` | `1024` / `256` | resource governors |
| `--heartbeat-secs` / `--max-client-lag` | `15` / `1024` | SSE keepalive / per-client lag bound |
| `--sse-write-timeout-ms` | `30000` | per-record SSE write deadline (stalled-browser drop) |
| `--ring-capacity` | `4096` | SSE fan-out ring buffer depth |
| `--rate-limit-rps` | `100` | per-credential rate cap |
| `--idempotency-ttl-secs` | `120` (`0`=off) | idempotency-key response cache TTL |
| `--cors-origin` | off | allowed origin if browser-direct (else no CORS) |
| `--log-format` | `json` | structured logging |
| `--dev` | off | mock-upstream profile (§9.3) |

Validation fails fast (`OperatorExitCode::OperatorAction`) with a typed
error naming the offending knob; `--help` documents every flag. Secrets
(auth tokens, TLS keys) are passed by file path, never argv/env value, and
read with restrictive permissions — consistent with the l1-ingest
`Zeroizing` key handling. Config consistency that the gateway *cannot*
self-check (e.g. `--free-tier`/`--gas-pool-actor` matching the deployment)
is documented as an operator obligation in the runbook (G4.7) and surfaced
in `/info` so a mismatch is observable.

### §9.3 Dev mode

A `--dev` profile runs against **mock upstreams** (an in-process MockHost
built on `knomosis_host::kernel::mock::MockKernel` returning a configurable
verdict, an in-memory event generator that exercises multi-event seq-groups,
and a seeded temp SQLite created by the gateway's *own* schema-compatible
seeder) so a Licio developer can run the BFF against a single gateway binary
with no full Knomosis stack — mirroring Licio's own in-memory dev fallback
(which seeds demo data when `DATABASE_URL`/`REDIS_URL` are absent). This
makes local end-to-end Licio↔gateway iteration cheap. The seeder writes a
real indexer-shaped DB (schema v2) so the read-only open path is exercised
even in dev.

### §9.4 Staging / production

* TLS on; auth required; rate limits + governors tuned; metrics scraped.
* Horizontally scalable: the gateway is stateless apart from per-instance
  idempotency cache and SSE ring, so instances sit behind an L7 LB.
  Idempotency across instances is best-effort unless a shared store is
  added (OQ-GW-4); SSE clients pin to an instance for a connection's life.
* **Read co-location.** Each gateway instance reads the indexer DB on its
  *own host* (WAL shared memory is host-local); the indexer writer must be
  live for read-only WAL access to see committed data (`/readyz` enforces
  this). Cross-host reads require the OQ-GW-9 query server.
* Secrets via the platform secret manager; bridge/pool keys live in
  l1-ingest/observer, never the gateway.
* Health-gated rollout: `/readyz` must pass (host + event-subscribe
  reachable, indexer DB openable + writer live) before an instance receives
  traffic.

### §9.5 Runbook

A `docs/gateway_runbook.md` (G4.7 deliverable) follows the
`fault_proof_runbook.md` / `gas_pool_runbook.md` template (Roles · safety
posture · config reference · health/readiness · monitoring checklist ·
common failure signatures · dashboards · rollback). Failure signatures it
must cover: host `Busy` storms, event truncation, indexer lag / writer
death (read-only WAL goes stale), SSE fan-out saturation, config drift
(`--free-tier`/`--gas-pool-actor` mismatch).

## §10 Testing strategy

Testing is **continuous per work unit**, not a final phase. Layers:

1. **Unit** — framing/codec, verdict→status mapping, composite-id cursor
   math, ring buffer, idempotency cache, auth compare, config validation,
   HTTP request parser. Pure, fast, property-tested (`proptest`, as
   elsewhere in the workspace).
2. **Integration vs mock upstreams** — MockHost (verdict matrix:
   `Ok`/`NotAdmissible`+reason/`ParseError`/`Busy`/unknown-byte), mock
   event-subscribe (resume/truncation/lag/shutdown/multi-event-seq-group),
   seeded read-only SQLite. End-to-end through the real HTTP layer over an
   ephemeral socket (mirrors `knomosis-host`'s `tests/integration.rs`).
3. **OpenAPI contract tests** — validate live response *bodies* against the
   `gateway.openapi.yaml` component schemas; a CI gate fails on drift
   (G5.1). Implemented as Rust integration tests that assert responses
   against committed JSON-Schemas extracted from the OpenAPI components
   (no Node runtime dep), complemented by the structural OpenAPI lint
   (G0.3, Node-based, the one external tool).
4. **Cross-stack** — decode real `knomosis extract-events` output and assert
   the gateway's event JSON matches the Lean reference for tags `0..=22`
   (reuse the `.cxsf` corpus pattern; this is the §6.2 pin).
5. **Load / soak** — a bench (mirroring `knomosis-bench`) for submit
   throughput and concurrent-SSE fan-out; soak for fd/memory leaks (the SSE
   ring + handler-per-stream model is the prime leak suspect).
6. **Chaos** — upstream kill/restart (host, event-subscribe, indexer-
   writer-death), reorg-style cursor jumps, slow SSE clients, conn drops,
   mid-seq-group disconnect/resume (the §6.1 correctness case) — mirroring
   `knomosis-faultproof-observer`'s `tests/chaos.rs`.

**CI wiring (optimized).** Because `ci-rust.yml` already runs
`cargo build/test/clippy/fmt --workspace` on any `runtime/**` change, it
covers the gateway's Rust gates *for free* once it is a member. The new
`ci-gateway.yml` therefore adds only the **gateway-specific** gates and
triggers on `runtime/knomosis-gateway/**`, `docs/api/gateway.openapi.yaml`,
and itself:

* **openapi-lint** job (Node, e.g. `@redocly/cli lint` / Spectral, pinned
  by SHA per CLAUDE.md) — structural spec validity on every spec touch.
* **contract** job (optional second job) — black-box schema validation if
  the cargo-side contract tests are judged insufficient; default off, since
  layer 3 above runs under `ci-rust.yml`.

Lean-only PRs trigger neither workflow.

## §11 Work breakdown

Each work unit is independently landable, reviewable, and tested (§10).
Size: **S** ≈ ≤1 day, **M** ≈ 2–4 days, **L** ≈ ≥1 week. `deps` lists
prerequisite WUs. Acceptance criteria are the definition-of-done. File
paths are under `runtime/knomosis-gateway/` unless noted. The proposed
module layout the WUs reference:

```
src/lib.rs · main.rs · config.rs · problem.rs · auth.rs · ratelimit.rs
src/observability.rs · shutdown.rs · info.rs
src/http/{mod,request,response,router,server,sse}.rs
src/submit/{mod,client,pool,verdict_map,idempotency}.rs
src/reads/{mod,store,balances,budget,pools}.rs
src/events/{mod,subscribe,decode,backfill,stream}.rs
src/events/fanout/{mod,ring,mux,dispatch,resume}.rs
tests/{integration,contract,cross_stack_events,chaos}.rs
```

### G0 — Contract and plan

* **G0.1 — OpenAPI 3.1 sketch** · S · deps: — · **DONE.**
  *Deliverable:* `docs/api/gateway.openapi.yaml`. *Acceptance:* parses;
  all `$ref`s resolve.
* **G0.2 — Integration plan** · S · deps: — · **DONE (this doc, v0.4).**
  *Acceptance:* every endpoint mapped to an ABI section *and* a reused
  crate API; risk register + WU breakdown + spec-delta ledger present.
* **G0.3 — OpenAPI lint CI gate** · S · deps: G0.1.
  *Deliverable:* `.github/workflows/ci-gateway.yml` `openapi-lint` job (a
  SHA-pinned Redocly/Spectral lint), triggered by `docs/api/**` +
  `runtime/knomosis-gateway/**`. *Acceptance:* CI fails on an invalid /
  edited-without-lint spec; passes on the committed spec.

### G1 — Crate skeleton + read path + auth + health

* **G1.0 — HTTP-layer spike (resolves OQ-GW-8)** · S · deps: G0.
  *Deliverable:* a timeboxed (≤2 day) decision memo
  (`docs/audits/gateway_http_spike.md`) comparing (a) a hand-rolled
  HTTP/1.1 subset (§3.2.1) on `std::net` + `knomosis_host::tls`, (b) one
  small vetted sync crate, and (c) reusing `knomosis_host::listener`'s
  acceptor; each prototyped to "accept → parse request line → 200 over
  HTTP and TLS." *Acceptance:* a recommendation (default: hand-rolled +
  reuse `knomosis_host::tls`, evaluate reusing the listener acceptor) with
  LoC / dep / audit-surface evidence; the chosen path is what G1.2 builds.
  *De-risks R1 up front rather than discovering it mid-G1.2.*
* **G1.1 — Crate scaffold** · S · deps: G0.
  *Deliverable:* `runtime/knomosis-gateway/` (lib+bin); added to
  `runtime/Cargo.toml` `members`; `[lints.*]` inherited;
  `version.workspace = true`; `lib.rs`/`main.rs` skeleton wired to
  `knomosis_cli_common::{exit,logging}`; `--help`/config skeleton; the
  `ci-gateway.yml` shell (lint job from G0.3). *Acceptance:* `cargo
  build/test/clippy/fmt` green under `ci-rust.yml`'s `--workspace` run for
  the new crate.
* **G1.2 — Sync HTTP/TLS foundation** · M · deps: G1.0, G1.1. Broken into:
  * **G1.2a — Request parser** · S. `http/request.rs`: request line +
    header parsing with hard limits (max request-line length → 414, max
    header bytes/count → 431, `Content-Length` required for bodies else
    411/400), `application/json` + `application/octet-stream` body intake
    capped at `max_frame_size`. **Request-smuggling defenses:** reject
    duplicate / conflicting `Content-Length`, reject any request carrying
    both `Content-Length` and `Transfer-Encoding`, and reject bare `CR`/`LF`
    or control bytes in the request line and header names (header lines must
    be exactly `CRLF`-delimited). *Acceptance:* `proptest` over malformed +
    smuggling-shaped inputs all map to the right 4xx; the parser **never
    panics** (the `clippy::restriction` panic-lints of §3.2 are denied on
    this module) and never unbounded-buffers.
  * **G1.2b — Router + method dispatch** · S. `http/router.rs`: path +
    method table for §4; 404 unknown path, 405 + `Allow` for wrong method,
    `/v1` prefix. *Acceptance:* table-driven tests cover every route + the
    negative cases.
  * **G1.2c — Response writer + problem plumbing** · S. `http/response.rs`:
    status line, headers, `application/json` + `application/problem+json`,
    keep-alive vs close, `X-Knomosis-Seq`/`ETag`/`Retry-After` headers.
    *Acceptance:* golden-byte tests for representative responses.
  * **G1.2d — Acceptor + TLS + governors** · S. `http/server.rs`: acceptor
    thread(s) + bounded handler pool; TLS via
    `knomosis_host::tls::TlsConfigBuilder::load_pem_files`;
    `--max-connections` cap → `503`/close; per-connection read/idle
    timeouts. Reuse `knomosis_host::listener` if G1.0 recommended it.
    *Acceptance:* `/healthz` 200 over HTTP **and** TLS; max-conn cap
    enforced; integration test over an ephemeral port for both transports.
  * **G1.2e — Streaming response primitive** · S. `http/sse.rs`: a
    flush-after-each-write `text/event-stream` body with no `Content-
    Length`, `Cache-Control: no-store` + `X-Accel-Buffering: no` (defeat
    reverse-proxy response buffering of the stream), a per-write deadline,
    and heartbeat support — the substrate G3.5 builds on. *Acceptance:* a
    unit stream emits records a reader sees incrementally (not buffered to
    EOF); write-deadline drop tested; the anti-buffering headers present.
* **G1.3 — Config + wiring** · S · deps: G1.1.
  *Deliverable:* `config.rs` — the full §9.2 flag/env surface with
  validation and typed errors; secrets via file with permission checks;
  the budget-echo (`--free-tier`/`--action-cost`/`--epoch-length`) and
  `--gas-pool-actor` knobs. *Acceptance:* invalid config fails fast with a
  typed `OperatorAction` error; `--help` documents every knob; a unit test
  per validation rule.
* **G1.4 — AuthN middleware** · S · deps: G1.2.
  *Deliverable:* `auth.rs` — bearer via `subtle::ConstantTimeEq` (multiple
  tokens from the file supported), optional mTLS hook; `security:[]`
  exemption for `/healthz`/`/readyz`. *Acceptance:* unauthenticated
  non-health request → 401; wrong token → 403; timing-safe compare
  unit-tested (no early-return on length/first-mismatch); token never
  logged.
* **G1.5 — Problem responder + error taxonomy** · S · deps: G1.2.
  *Deliverable:* `problem.rs` — one RFC 9457 `Problem` type; stable `type`
  URIs; request-id `instance`; `knomosisReason`/`oldestSeq`/`retryAfterMs`
  extension members matching the spec. *Acceptance:* every error path emits
  a typed `Problem` whose JSON validates against the spec's `Problem`
  schema (contract test).
* **G1.6 — Read: balances** · M · deps: G1.2, G1.3. Broken into:
  * **G1.6a — `knomosis-storage` read-only open** · S · deps: — (lands in
    `runtime/knomosis-storage/`). *Deliverable:* a new
    `SqliteStorage::open_read_only(path, &options)` that opens an **existing**
    database (never `SQLITE_OPEN_CREATE`) and **without running migrations**,
    then **verifies** the on-disk `_meta.schema_version` is in the gateway's
    explicit **supported set** (currently exactly `{2}`) — **not** a `≥ 2`
    lower bound — and that `c/identifier` matches, failing with a typed error
    otherwise. A lower bound would let a v2-built gateway silently read a
    future v3+ indexer DB whose table *semantics* may have changed (the
    storage migration runner itself treats `> target_schema_version()` as a
    mismatch), returning wrong balances/budgets (finding #9); so the gateway
    rejects an unrecognised-newer schema and is bumped deliberately when it
    learns a new version. (Reading an *unmigrated* / foreign DB is refused the
    same way.)
    *Open-flag decision (resolve in this WU, do not pre-assume):* **prefer a
    pure `SQLITE_OPEN_READ_ONLY` connection** — it refuses writes
    *structurally* at the OS/SQLite layer (the strongest isolation, §8.9),
    and in WAL mode it reads correctly **provided the indexer writer is
    live** (so the `-shm`/`-wal` are present), which `/readyz` already
    requires (§3.3, §9.4). The **fallback** — `SQLITE_OPEN_READ_WRITE`
    *without* `CREATE` + `PRAGMA query_only = ON` (writes runtime-blocked) —
    is taken **only if** the WU empirically finds a storage read path
    `READ_ONLY` cannot serve (e.g. one that takes a `BEGIN IMMEDIATE` lock
    rather than a `DEFERRED` read), *or* if gateway-before-writer startup
    robustness is needed (a read-write open can bootstrap `-shm`). The
    storage read views (`StorageSnapshot` = `BEGIN DEFERRED`,
    `BalanceView`, `BudgetReadView`) are believed to be DEFERRED-read-only
    and thus `READ_ONLY`-compatible; the WU's first task is to confirm this
    by running all three over a `READ_ONLY` handle against a live-writer DB.
    *Acceptance:* opens a real indexer DB and reads balances byte-identical
    to a read-write open; refuses to create a missing file; refuses a
    schema-v1 / wrong-identifier DB; a write attempt errors; `BalanceView`
    *and* `BudgetReadView` both function over the chosen handle (incl. their
    internal deferred reads); the open-flag choice + its empirical basis is
    recorded in the module docs. *This is the prerequisite the v0.3 plan
    assumed existed (v0.4 audit finding 1).*
  * **G1.6b — Balances endpoints** · S · deps: G1.6a. *Deliverable:*
    `reads/store.rs` (open + snapshot helper) + `reads/balances.rs`:
    `GET /actors/{id}/balances` (via `BalanceView::scan_all` filtered to
    the actor, over one `StorageSnapshot` together with `c/cursor`) and
    `…/balances/{resource}` (via `BalanceView::get`); `X-Knomosis-Seq` from
    `cursor::read_cursor`; weak `ETag` from `(actor, cursor)` +
    `If-None-Match`→304; absent cell → `"0"`. *Acceptance:* values
    byte-match `knomosis-indexer query` on a seeded DB; unknown actor →
    empty list / `"0"`; the list + its seq come from one snapshot (no torn
    read under a concurrent writer — chaos-tested).
* **G1.7 — Read: budget + pools** · M · deps: G1.6.
  *Deliverable:* `reads/budget.rs` — `GET /actors/{id}/budget` via
  `BudgetReadView::remaining_this_epoch(actor, free_tier)` (combining the
  config `freeTier`/`actionCost`, the indexer grants/consumed tables, and
  `c/current_epoch`) with the lower-bound label; `reads/pools.rs` —
  `GET /pools/{poolId}` via `get_pool_eth`/`get_pool_bold` with the `net`
  flag from `--gas-pool-actor`. *Acceptance:* match `query-budget` /
  `query-pool-{eth,bold}`; the budget caveat is documented in the response
  schema; verify `BudgetReadView`'s internal read is deferred/read-only-
  compatible over the G1.6a handle (else fall back to `query_only`).
* **G1.8 — `/info`, `/readyz`** · S · deps: G1.2, G1.6a.
  *Deliverable:* `info.rs` — `/info` (deployment id; the kernel's declared
  `ok_admission_stage` from **config**, default `Finalized` — a host
  metadata wire op is a G6-era extension, so no submit-track dependency;
  submit/events protocol versions; indexer seq + schema version; the echoed
  budget/pool config so drift is observable); `/readyz` probes all
  upstreams — host + event-subscribe via a bare TCP-connect liveness check
  (no frame, so no G2.1/G3.1 dependency) and the indexer via DB-openable +
  writer-live (G1.6a). *Acceptance:* `/readyz` flips 503 when any upstream
  is down or the indexer writer is dead; `/info` reports the configured
  stage + the live indexer cursor.
* **G1.9 — Read-path tests** · S · deps: G1.6, G1.7.
  *Deliverable:* `tests/integration.rs` (seeded read-only SQLite) +
  contract tests for the read endpoints + `If-None-Match`/304 +
  snapshot-consistency chaos case. *Acceptance:* `ci-gateway`/`ci-rust`
  gates green. **First shippable slice (read-only Licio integration).**

### G2 — Submit path

* **G2.1 — Host client + connection pool** · M · deps: G1.2. Broken into:
  * **G2.1a — Frame codec + response parser** · S. `submit/client.rs`:
    request framing via `knomosis_host::frame::encode_frame` (v1, no signer
    hint); a response-frame reader mirroring `VerdictResponse::encode`
    (`Verdict::from_byte` + 4-byte BE reason len + bytes; unknown byte →
    typed error → `502`). *Acceptance:* round-trips every verdict byte +
    reason against golden bytes; unknown byte fails closed.
  * **G2.1b — Bounded persistent pool** · S · deps: G2.1a. `submit/pool.rs`:
    `--host-pool-size` persistent connections, one in-flight each;
    checkout/return; reconnect-on-drop; connect/read/write deadlines;
    `--host-max-inflight` cap → `503`. *Acceptance:* round-trips against a
    MockHost; pool reuse + reconnect-on-drop + saturation→503 tested; no fd
    leak under churn (soak).
  * **G2.1c — (deferred) pipelining** · S · deps: G2.1b. Optional
    multiple-in-flight-per-connection mode (§10.5) behind a flag, for
    throughput. *Not on the critical path; default off.* *Acceptance:*
    in-order response correlation holds under load; off by default.
* **G2.2 — `POST /actions` + verdict mapping** · M · deps: G2.1, G1.4,
  G1.5. *Deliverable:* `http` intake (`application/json`+base64 — the
  `base64` decoder is a small hand-roll *or* a vetted `base64` crate,
  decided here, since `application/octet-stream` is the zero-dependency
  canonical path; any other `Content-Type` → `415`) → opaque forward →
  `submit/verdict_map.rs` (§5 status mapping; reason pass-through;
  `admissionStage` from `/info`). *Acceptance:* the full verdict matrix
  (incl. the `BudgetGate*` reasons and the unknown-byte fail-closed) maps to
  §5 (integration vs MockHost); a wrong `Content-Type` → `415`; the signed
  bytes reach the host **byte-identical** (a forwarding-fidelity test).
* **G2.3 — Backpressure + limits** · S · deps: G2.2.
  *Deliverable:* `Busy`→`503`+`Retry-After`; deadline→`504`; conn-fail→
  `502`; `413` size cap (enforced while reading); bounded in-flight to
  host. *Acceptance:* each condition produces the mapped status + correct
  headers under test.
* **G2.4 — Idempotency cache** · S · deps: G2.2.
  *Deliverable:* `submit/idempotency.rs` — bounded TTL `Idempotency-Key`→
  response cache (off when ttl=0); LRU eviction; key is opaque/client-
  supplied. *Acceptance:* duplicate key within TTL returns the cached
  response (not a second host round-trip); eviction + disable paths tested;
  cache is bounded (no unbounded growth under unique keys).
* **G2.5 — Submit tests** · S · deps: G2.2.
  *Deliverable:* integration + contract + idempotency + forwarding-fidelity
  tests. *Acceptance:* gates green.

### G3 — Events: backfill + SSE

* **G3.1 — event-subscribe client orchestration** · S · deps: G1.1.
  *Deliverable:* `events/subscribe.rs` — wrap
  `knomosis_indexer::client::SubscribeClient::{connect, read_frame}` with
  reconnect/backoff, terminal-frame handling (`Truncated`/`LagExceeded`/
  `ServerShutdown`/`InvalidRequest` → typed gateway events), and a liveness
  check (the upstream read has no idle timeout by default — add a keepalive
  / staleness watchdog). *Acceptance:* drives a mock server through every
  frame kind; reconnects with the right `resume_from` after each terminal
  frame. *(Reuse shrinks this from M→S vs v0.3 — audit finding 3.)*
* **G3.2 — Event decode → JSON** · M · deps: G3.1. Broken into:
  * **G3.2a — Classify + forward-unknown** · S. `events/decode.rs`:
    `event_type::classify` → type name; tags ≥23 → `type:"unknown"` +
    base64 `raw` (never reject — additive-extension policy, §11.1).
    *Acceptance:* an injected future tag forwards verbatim with the right
    shape.
  * **G3.2b — Typed render (all 23 tags)** · M. For known tags,
    `decoder::decode_event` → `Event` → the §6.2 JSON table (bigint→string,
    bytes→`0x`-hex, `outcome` name). A *decode failure on a known tag*
    (truncated/over-long payload — not an unknown tag, which G3.2a forwards)
    is a corruption signal and **fails closed**: drop the SSE stream with
    `event: error` carrying the dedicated `decode_error` value (added to
    `EventStreamError.error`, §15B) / fail the REST page with a problem,
    never silently skip the record and never mislabel it as
    `server_shutdown`/`lag_exceeded` (no silent gaps, §2 principle 7).
    *Acceptance:* a unit test per tag asserts the exact JSON shape;
    round-trips a decoded `Event`; a truncated known-tag payload yields a
    `decode_error` close (does not panic — §3.2).
  * **G3.2c — Cross-stack pin** · S · deps: G3.2b. `tests/
    cross_stack_events.rs`: decode real `knomosis extract-events` output
    and assert the gateway JSON matches the Lean reference for tags
    `0..=22` (reuse the `.cxsf` corpus pattern). *Acceptance:* CI gate
    green; a deliberate field-rename breaks it.
* **G3.3 — `GET /events` backfill** · M · deps: G3.1, G3.2.
  `events/backfill.rs` builds a *bounded page* API over the *unbounded*
  `SUBSCRIBE` stream — which needs three things the naïve "open a sub, drain
  to `limit`" misses (findings #2, #5):
  * **Capture a `tip` first.** At request start, read the current tip seq
    (the ring's newest, falling back to the indexer `c/cursor`); the drain
    stops when it reaches `tip` (→ `hasMore=false`) so it **never blocks
    waiting for live events** the subscription would otherwise hand back.
  * **`since` semantics.** `since=S` (`S ≥ 1`) ⇒ `resume_from = S` (events
    with `seq > S` from the keep-history cache, up to `tip`). `since=0` means
    "from the oldest retained" — because §11.3 reserves `resume_from = 0` for
    *live-tail*, the gateway instead resumes from the oldest cached seq and
    returns `409`+`oldestSeq` if genuine from-genesis history was truncated
    (the realistic caller passes a concrete recent `since`, e.g. the
    behind-ring cursor). Any `TRUNCATED` (`since < oldest_cached`) → `409`.
  * **Group-complete pages.** A page never ends mid seq-group: the drain
    rounds up to the next seq boundary at-or-after `limit` (a group is
    bounded by `HARD_MAX_EVENT_COUNT`, §11.10), so `nextCursor` is always a
    *completed-group* seq — resuming from it neither skips a group's tail nor
    redelivers its head (finding #2). `limit` is thus a soft lower bound on
    page size. Type filter applied gateway-side.
  *Acceptance:* paginates a mock history with multi-event seq-groups
  **without splitting a group across pages**; reaches `hasMore=false` at the
  captured tip without hanging; `since < oldest` → 409; the steered "behind"
  SSE client (§3.5) catches up end-to-end. *(Upsized S→M: a bounded page over
  an unbounded stream is more than a drain.)*
* **G3.4 — SSE fan-out (the complex sub-system)** · L · deps: G3.1, G3.2.
  The §6.1 composite-id correctness lives here; each sub-WU is property-
  tested against an oracle stream.
  * **G3.4a — Ring buffer + cursor registry** · M. `events/fanout/ring.rs`:
    a bounded ring of recent **`(seq, index, type, json)`** records (not
    bare seqs — the intra-seq index is load-bearing, §6.1); per-client
    cursor as `(seq, index)`; oldest-retained tracking; and a
    **last-complete-group watermark** = the highest seq `S` for which a
    record with `seq > S` has been ingested (so group `S` is provably whole —
    a group is only known complete once the *next* seq begins, §11.4). The
    watermark, not the newest seq, is the safe resubscribe point (G3.4b,
    finding #4). *Acceptance:* property tests for ordering, gap-freeness,
    **seq-group integrity** (no record of a group is dropped while a later
    group is retained), and **watermark correctness** (it never advances into
    a still-open group) against an oracle; a client cursor advances exactly
    one record at a time.
  * **G3.4b — Upstream multiplexing** · M · deps: G3.4a, G3.1.
    `events/fanout/mux.rs`: a **single** shared live-tail subscription
    (`--upstream-subscriptions` default **1**, finding #6) feeds the ring;
    **resubscribe-on-drop from the last-complete-group watermark** (G3.4a) —
    **not** the newest seq, which (if the socket dropped mid-group) would ask
    for `seq > S` and skip that group's unseen tail for every downstream
    client (finding #4, P1). Resuming from the watermark re-delivers the open
    group's already-ingested head, so the mux **de-duplicates on
    `(seq, index)`** on re-insert. `--upstream-subscriptions > 1` (operator
    opt-in for redundancy) is correct *only* with that same `(seq, index)`
    dedup, since every subscriber to the §11 broadcast receives every event
    (a naïve 2 would double-ingest — finding #6). *Acceptance:* N SSE clients
    ⇒ O(1) upstream subscribers (asserted by counting upstream connects),
    independent of N; an upstream drop **mid seq-group** loses no record for
    any downstream client (the headline #4 chaos test); no event is delivered
    twice across a resubscribe (dedup test).
  * **G3.4c — Per-client dispatch + eviction** · M · deps: G3.4a.
    `events/fanout/dispatch.rs`: one handler thread per stream (bounded by
    `--max-streams`); emits `id: <seq>.<index>` records (composite, §6.1) +
    heartbeats; type-filtered; per-record write deadline; drops clients
    past `--max-client-lag` with `event: error` (`lag_exceeded`).
    *Acceptance:* slow-client eviction does not stall fast clients (chaos
    test); a heartbeat carries no `id:` (resume cursor unmoved).
  * **G3.4d — Resume semantics + intra-seq skip** · M · deps: G3.4a/b.
    `events/fanout/resume.rs`: decompose `Last-Event-ID = "<seq>.<index>"`
    (or bare `since`, §3.5 step 1); for an **in-window** point position the
    ring cursor just after `(resume_seq, resume_index)` (the intra-seq skip
    is the cursor comparison `(seq,index) > (resume_seq, resume_index)` —
    **no upstream re-read**, §6.1); for a **behind-ring** point emit
    `event: error{behind, oldestSeq}` (the oldest ring seq; steer to
    backfill — never an SSE `truncated`, which only `GET /events` can
    determine, finding #7); for
    **older-than-upstream** emit `truncated`. *Acceptance:* the
    mid-seq-group disconnect/resume case redelivers **exactly** the unseen
    records (no loss, no dup) against the oracle — the headline correctness
    test; each resume tier (in-window / behind / truncated) behaves
    correctly; upstream-subscription count is unchanged by a resume (the
    O(1) invariant of G3.4b holds across reconnects).
* **G3.5 — `GET /events/stream` wiring + tests** · S · deps: G3.4.
  *Deliverable:* `events/stream.rs` atop `http/sse.rs` + the fan-out;
  `Cache-Control: no-store`; auth; `Last-Event-ID`/`since` precedence.
  *Acceptance:* reconnect/resume/truncation/lag/multi-event-seq-group
  integration + contract tests green.

### G4 — Hardening + runbook

* **G4.1 — Rate limiting** · S · deps: G2, G3. `ratelimit.rs`: per-
  credential token bucket → `429`+`Retry-After`; bounded bucket map.
  *Acceptance:* limit enforced; headers correct; bucket map bounded.
* **G4.2 — TLS/mTLS hardening** · S · deps: G1.2d. mTLS client-cert verify
  (`--mtls-client-ca`); cipher/proto floor (TLS 1.3 default); cert-rotation
  note. *Acceptance:* mTLS round-trip; weak-proto / unknown-client-cert
  rejected.
* **G4.3 — Observability** · M · deps: G1–G3. `observability.rs`: `tracing`
  spans + per-request id (propagated to `problem.instance` and logs);
  upstream-latency + per-endpoint-status counters/histograms; **secret
  redaction** (token, key, bodies). *Acceptance:* metrics exposed (per
  OQ-GW-10 decision); log-correlation by request id verified; a token never
  appears in logs (redaction test).
* **G4.4 — Resource governors + graceful shutdown** · S · deps: G1–G3.
  `shutdown.rs`: SIGTERM/SIGINT (signal-hook or self-pipe) → stop flag →
  drain submits, emit SSE `server_shutdown`, close pools, exit
  `Success`. Confirm all caps (streams/conns/ring/idempotency/in-flight)
  are enforced. *Acceptance:* shutdown drains in-flight submits and closes
  streams cleanly (no truncated mid-record SSE); a stuck stream cannot
  block shutdown past a deadline.
* **G4.5 — Security review + dep audit** · S · deps: G1–G4. Threat-model
  pass; introduce `runtime/deny.toml` (`cargo-deny`: advisories, licenses,
  bans) — none exists yet — and wire `cargo audit`/`cargo deny` into
  `ci-gateway.yml`; justify the new `base64`/HTTP/`signal-hook` deps.
  *Acceptance:* no advisories; license/ban policy passes; review sign-off
  recorded in `docs/audits/`.
* **G4.6 — Load/soak/chaos** · M · deps: G1–G3. A `knomosis-gateway`-bench
  (mirroring `knomosis-bench`) for submit throughput + concurrent-SSE
  fan-out; `tests/chaos.rs` (upstream kill/restart incl. indexer-writer-
  death, cursor jumps, slow clients, mid-group resume). *Acceptance:*
  throughput target met; **no fd/memory leak under soak** (the per-stream-
  thread + ring model); chaos cases recover.
* **G4.7 — `docs/gateway_runbook.md`** · S · deps: G4.1–G4.4.
  *Acceptance:* covers roles, start/stop, config (incl. the
  operator-obligation consistency knobs §9.2), health/readiness, the §9.5
  failure signatures, dashboards, rollback — to the
  `gas_pool_runbook.md` standard.

### G5 — Client + contract CI + versioning

* **G5.1 — Contract-test gate** · S · deps: G1–G3. The layer-3 contract
  tests (committed JSON-Schemas from the OpenAPI components, validated in
  Rust integration tests) run under `ci-rust.yml`; `ci-gateway.yml` keeps
  the structural lint (G0.3). *Acceptance:* a response-shape change not
  reflected in the spec fails the gate; a spec edit without a matching
  impl change fails it too.
* **G5.2 — Typed TS client** · M · deps: G0.1, G2, G3. Generate (e.g.
  `openapi-typescript` + a thin fetch/EventSource wrapper) and publish a
  typed client for the Licio BFF; a CI smoke that the client compiles +
  example calls type-check. *Acceptance:* a sample BFF file compiles
  against it; `OQ-GW-11` confirms no residual blocker beyond codegen.
* **G5.3 — Versioning + CHANGELOG** · S · deps: G5.1. `docs/api/CHANGELOG`
  for contract deltas; the `/v1` additive-only compat policy documented;
  `info.version` bump discipline. *Acceptance:* the §15B ledger items are
  recorded as they land; `/v1` policy stated.

### G6 — Authoritative read path (closes the §3.6 gap)

Independent Lean/host track (no dependency on G1–G5 until G6.3). Closes
the gap that indexer `remaining` is a lower bound and balances are
eventually consistent.

* **G6.1 — Lean `query`/`getBalance` subcommand** · M · deps: —.
  *Deliverable:* a `knomosis query <actor> <resource>` (and
  `query-budget <actor>`) subcommand in `Main.lean` that reconstructs the
  canonical `ExtendedState` at the log tip (reuse `Runtime/Snapshot` +
  `Runtime/Replay`: load latest snapshot, replay the tail under the
  deployment config) and reads `getBalance` / the `EpochBudgetState`;
  cross-stack tests vs the indexer invariant (§11A.5b). *Acceptance:*
  matches the kernel on a replayed log; **axiom-clean** (`#print axioms` ⊆
  the canonical three); the pinning tests + `count_sorries` stay green.
* **G6.2 — host `getBalance` read op** · M · deps: G6.1. *Deliverable:* a
  host protocol read op (a new request kind or a side channel) returning
  exact balances/budgets; an `abi.md` §10 amendment (additive, no existing
  byte repositioned) + docs. *Acceptance:* host returns exact values;
  backward-compatible framing (existing clients unaffected); a new
  cross-stack vector.
* **G6.3 — Gateway authoritative-read mode** · M · deps: G6.2, G1.6.
  *Deliverable:* an optional exact-read mode that reconciles vs the indexer
  and labels the source; wire the indexer `--verify-against-knomosis`
  plumbing. *Acceptance:* exact == indexer at quiescence; divergence
  surfaced (logged + a problem/flag), not hidden.
* **G6.4 — Read-source labelling** · S · deps: G6.3. *Deliverable:* a
  `readSource: indexed | authoritative` field on the read schemas (the
  §15B ledger item) + a header. *Acceptance:* clients can distinguish; the
  spec delta lands with the impl.

### G7 — Deployment and ops

* **G7.1 — Service topology manifests** · M · deps: G1. Compose/k8s for
  {host, event-subscribe, indexer, gateway} with the **read co-location**
  constraint encoded (gateway + indexer share a host/volume), per-env
  config + secrets wiring. *Acceptance:* one-command dev bring-up; the
  manifest enforces co-location.
* **G7.2 — Dev profile** · S · deps: G1, G2, G3. The `--dev` mock-upstream
  mode (§9.3) incl. the schema-shaped temp-DB seeder. *Acceptance:* the
  Licio BFF runs against a single gateway binary, no full stack.
* **G7.3 — Staging/prod rollout** · M · deps: G4, G7.1. TLS, scaling,
  health-gated rollout, secret manager, the indexer-writer-liveness gate.
  *Acceptance:* readiness-gated deploy works; documented.
* **G7.4 — Dashboards + alerts** · S · deps: G4.3, G7.3. *Acceptance:*
  alerts fire on upstream-down / indexer-writer-death / error-rate / SSE
  lag / config-drift.

## §12 Dependency graph and sequencing

```
G0 ─► G1.0 (spike) ─► G1.1 ─► G1.2 ─┬─► G1.6(a→b) ─► G1.7 ─► G1.9  ── first shippable (read-only)
                                     ├─► G1.3, G1.4, G1.5, G1.8
                                     ├─► G2 (submit) ─┐
                                     ├─► G3 (events) ─┼─► G4 ─► G5
                                     └─► G7.2         │
G1.6a (knomosis-storage read-only) is a leaf prerequisite of G1.6b.
G6 (independent Lean/host track) ─► G6.3 (needs G1.6) ─► G6.4
G7.1 (needs G1) ──────────────────► G7.3 (needs G4)
```

* **Critical path:** G0 → G1.0 → G1.1 → G1.2 → {G2, G3} → G4 → G5. The
  G1.0 spike is short but gates G1.2 (the riskiest WU), so it is deliberately
  first.
* **Leaf prerequisite:** G1.6a (the `knomosis-storage` read-only open) has
  no gateway dependency and can land first of all the code WUs — it is also
  reusable by any future read-only consumer.
* **Parallelisable after G1.2:** G2 (submit) and G3 (events) are
  independent tracks; G7.2 (dev profile) can start once G1 exists.
* **Independent track:** G6 (Lean `getBalance` + host endpoint) has no
  dependency on G1–G5 until it integrates at G6.3, so it can proceed in
  parallel from day one.
* **First shippable slice:** G1 (through G1.9) gives Licio a **read-only**
  integration (balances/budget/pools + health) — the fastest path to value,
  with no key custody and no write risk. G3 adds live UI; G2 adds writes.
  The §1.4 reconciliation confirms read-only pay-to-rank/topic-gating is
  Licio's first real consumer, so this ordering is evidence-backed.
* **Dark launch:** Licio gates Knomosis behind a fail-closed
  `/v1/feature-flags` crypto flag, so every phase can be deployed and
  validated against Licio's BFF while the flag stays off — no big-bang
  cutover.
* **Definition of done (per PR):** the sub-WU acceptance criteria met;
  `ci-rust.yml` + `ci-gateway.yml` green; contract tests pass; docs updated
  in the same PR; the patch version bumped in lockstep
  (`runtime/Cargo.toml` + `lakefile.lean`, §15A); the §15B ledger updated
  for any shape change.

## §13 Risk register

| # | Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|---|
| R1 | No-tokio HTTP layer is more work than expected | Schedule | Med | **G1.0 spike up front** (decision memo); keep the §3.2.1 surface minimal; reuse `knomosis_host::{tls,listener}`; evaluate a small vetted sync crate |
| R2 | SSE fan-out correctness (ordering/eviction/multiplex) | Correctness | Med | Split into G3.4a–d; property + chaos tests vs an oracle; O(1)-upstream assertion |
| R3 | Coupling to indexer SQLite schema | Maintenance | Med | Read via `knomosis-indexer` views + the new read-only open (G1.6a), not raw SQL; verify `schema_version`/identifier on open; or move to a query server (OQ-GW-9) |
| R4 | Budget lower-bound shown as exact | Correctness/UX | Med | Schema label (done); `freeTier` from gateway config; authoritative read in G6 |
| R5 | No post-submit seq → confusing client reconciliation | UX | High | Reconcile via event stream (§7); revisit host extension (OQ-GW-6) |
| R6 | Gateway accidentally holds user keys | Security | Low | Principle §8.2: pre-signed bytes only; opaque forward (never decode the body); review gate (G4.5) |
| R7 | event-subscribe subscriber cap exhausted by many browsers | Availability | Med | Multiplexed fan-out (G3.4b) — O(1) upstream subs; behind-ring clients steered to backfill not a rewind |
| R8 | Host queue saturation under load | Availability | Med | Pooling + bounded in-flight; `Busy`→`503`+`Retry-After` |
| R9 | Spec/impl drift | Integration | Med | Contract-test gate (G5.1) + OpenAPI lint (G0.3); spec is the source of truth; §15B ledger |
| R10 | Cross-instance idempotency gaps | Correctness (minor) | Low | Document best-effort; shared store optional (OQ-GW-4); kernel nonce still prevents double-apply |
| R11 | Licio's real needs differ from its README | Rework | Low | RESOLVED via §1.4 reconciliation: read-first behind a fail-closed flag, dark-launchable. Re-check on any Licio BFF change |
| R12 | SSE within-frame multi-event resume loses the group tail | Correctness | High (if naïve) | **Composite `id: "<seq>.<index>"`** + intra-seq skip (§6.1, G3.4a/d); the headline mid-group resume test |
| R13 | Read-only WAL goes stale if the indexer writer dies | Availability/Correctness | Med | `/readyz` requires the writer live (read-only WAL access needs the writer's `-shm`); same-host co-location; runbook failure signature; `/info` exposes the indexer cursor so staleness is observable |
| R14 | New `base64`/HTTP/`signal-hook` deps widen the audit surface | Security | Low | Minimal, vetted choices; `cargo-deny`/`cargo audit` gate (G4.5); hand-rolled HTTP preferred (G1.0) |
| R15 | Signal-handler deviation from workspace convention | Maintenance | Low | Justified (long-lived SSE needs clean shutdown); documented in §7 + the runbook; bounded-deadline drain; `signal-hook` (vetted) since `unsafe_code=forbid` bars raw libc |
| R16 | `panic = "abort"` (workspace-global, non-overridable) turns any handler panic into a whole-process abort — a single malformed request could take down all submits + SSE streams | Availability/DoS | Med (if unguarded) | **Panic-free handlers by construction** (§3.2): `clippy::restriction` panic-lints denied on request-path modules; adversarial `proptest` on the parser/decoder (tests run under `panic=unwind`, so a panic is a CI failure, not a silent prod abort); `catch_unwind` is *not* a usable boundary under `abort` |

## §14 Open questions

Format mirrors `docs/planning/open_questions.md`; promote there on sign-off.

* **OQ-GW-1 — Authoritative reads.** Build a kernel/host `getBalance`
  (+budget/pool) read path, or accept indexer-only reads? *Rec:* build it
  (G6); ship indexer-only first.
* **OQ-GW-2 — `NotAdmissible` status.** `200 {accepted:false}` vs `422`.
  *Rec:* `200` + body; revisit if a consumer needs error-channel semantics.
* **OQ-GW-3 — Signing / key custody.** User-wallet vs custodial BFF-side
  signer. *Informed by reconciliation (§1.4):* Licio already uses SIWE
  (client-side Ethereum signatures), so **client/user-wallet signing** is the
  natural fit — the BFF forwards pre-signed actions and the gateway holds no
  keys (§8.2). Custodial signing stays a fallback for non-wallet
  (email-OTP/WebAuthn) users.
* **OQ-GW-4 — Cross-instance idempotency.** Per-instance cache vs a shared
  store (e.g. Licio's Redis). *Rec:* per-instance best-effort for v1; kernel
  nonce is the safety backstop.
* **OQ-GW-5 — AuthZ scopes / multi-tenancy / browser-direct.** Single
  all-or-nothing token vs read/submit scopes vs per-deployment tenancy; and
  whether to ever expose the gateway browser-direct (CORS + HTTP/2). *Rec:*
  single token, BFF-fronted, HTTP/1.1 for v1; scopes + HTTP/2 when a second
  consumer or browser-direct need appears.
* **OQ-GW-6 — Post-submit seq.** Host extension to return the advanced seq
  vs gateway correlation via the event stream. *Rec:* stream correlation v1;
  measure demand before extending the host wire format.
* **OQ-GW-7 — Address→id resolution.** Does the gateway resolve on-chain
  addresses to `u64` actor ids (needs the l1-ingest address book) or does the
  BFF pass ids? *Informed by reconciliation (§1.4):* Licio's SIWE
  `identity/crypto.ts::accountRef` already holds each user's Ethereum address,
  so the BFF can supply it. *Rec:* ids remain the canonical key; offer an
  optional gateway address→id helper (backed by the l1-ingest address book) so
  the BFF need not duplicate the mapping.
* **OQ-GW-8 — HTTP library.** Hand-rolled HTTP/1.1 (dep-minimal, audit
  parity) vs a small vetted sync crate vs reusing `knomosis_host::listener`.
  *Rec:* **resolved by the G1.0 spike**; default to hand-rolled + reuse
  `knomosis_host::tls`, evaluate reusing the listener acceptor.
* **OQ-GW-9 — Read source.** Direct indexer-SQLite (co-located, read-only)
  vs a new indexer network query server (decoupled hosts). *Rec:* SQLite-
  direct, read-only, same-host v1 (WAL constraint); query server when host
  separation is required.
* **OQ-GW-10 — Metrics surface.** Log-based vs a `/metrics` endpoint. *Rec:*
  both behind config; default log-based, opt-in `/metrics`.
* **OQ-GW-11 — Licio contract surface. RESOLVED (§1.4).** Reconciled against
  Licio's `apps/api` BFF: there are **no Knomosis routes yet**; the integration
  is a dark feature behind the fail-closed `/v1/feature-flags` crypto flag.
  Concrete seams: read-side pay-to-rank/topic-gating (G1), SIWE→actor-id
  resolution (OQ-GW-7), optional stake submission via `POST /actions` with
  client-wallet signing (G2), optional topic-event surfacing via SSE (G3). No
  residual blocker on G5.2 beyond the typed-client codegen itself.
* **OQ-GW-12 — Seamless catch-up (new).** Should a behind-the-ring SSE
  client get a *dedicated* upstream catch-up subscription that drains
  `[resume, ringOldest)` then hands off to the ring (seamless, but a merge
  seam + extra upstream subs), or be steered to `GET /events` backfill then
  reconnect (simpler, O(1) upstream)? *Rec:* backfill-then-reconnect for v1
  (§3.5 step 2); dedicated catch-up as a measured optimization.

## §15 References

* Contract: [`docs/api/gateway.openapi.yaml`](../api/gateway.openapi.yaml).
* Wire ABIs: `docs/abi.md` §10 (network), §11 (event subscription), §11A
  (indexer storage); §10.2.1 (admission stages); §10.4 (backpressure);
  §11.1/§11.4 (event frames + seq invariants); §11A.2/§11A.4 (read views).
* Runtime crates (verified surfaces, §3.7):
  `knomosis_host::{tls,frame,verdict,admission,kernel,listener}`,
  `knomosis_storage::{Storage,SqliteStorage,StorageSnapshot}`,
  `knomosis_indexer::{client::SubscribeClient,decoder::decode_event,event::Event,balance::BalanceView,budget_view::BudgetReadView,cursor}`,
  `knomosis_event_subscribe::event_type`, `knomosis_cli_common::{exit,logging}`.
  Crate maturity + conventions: `runtime/README.md`;
  `docs/planning/rust_host_runtime_plan.md`.
* Licio: https://github.com/hatter6822/Licio (React 19 PWA + Hono BFF +
  Postgres/pgvector + Redis).
* Standards: RFC 9457 (Problem Details); WHATWG HTML §9.2 "Server-sent
  events" (the last-event-ID buffer semantics underpinning §6.1); OpenAPI
  3.1; SQLite WAL mode (same-host shared-memory constraint).

## §15A Promotion / ratification checklist

Promoting this DRAFT to a sanctioned workstream (the sign-off gate in the
Status banner) is mechanical once approved; land these in the promoting PR:

1. **Roadmap tables.** Add a `GW` row to the `CLAUDE.md` *and* `AGENTS.md`
   "Implementation roadmap" tables (keep the two files byte-identical), and
   to `docs/GENESIS_PLAN.md` §12 if the gateway is treated as a phase-7
   capability; add a "Knomosis Gateway (Workstream GW)" subsection under the
   `CLAUDE.md` "Workstream reference" pointing here.
2. **Workspace member.** Add `knomosis-gateway` to `runtime/Cargo.toml`
   `members` (G1.1) and a `ci-gateway.yml` (G0.3) with SHA-pinned actions.
3. **Build commands.** Add the gateway's `cargo`/dev-mode commands to the
   `CLAUDE.md`/`AGENTS.md` "Build and run" Rust block.
4. **Version bump.** Bump `[workspace.package] version` and `lakefile.lean`
   `version` in lockstep (patch by default) per the per-PR DoD; regenerate
   `Cargo.lock`.
5. **Docs.** `README.md` status/quickstart if the gateway changes the
   project's surface; `docs/gateway_runbook.md` (G4.7); the
   `docs/api/CHANGELOG` (G5.3).
6. **Open questions.** Promote the resolved OQ-GW-* into
   `docs/planning/open_questions.md`; leave the live ones (OQ-GW-1/3/4/5/6/
   7/9/10/12) tracked there.

No kernel TCB file is touched by G1–G5/G7 (one-reviewer rule); **G6 touches
Lean** (`Main.lean`, `Runtime/*`) and `abi.md` — additive, axiom-clean, and
under the standard Lean change discipline (`count_sorries`, the API-stability
pins, `#print axioms`), but not `Kernel.lean`/`RBMapLemmas.lean`, so it does
not trigger the two-reviewer TCB gate.

## §15B OpenAPI spec-delta ledger

The plan owns rationale; the YAML owns shapes; this ledger is the staging
area that keeps them consistent (§16). Deltas this revision *commits* to the
spec (applied alongside this doc):

* **`Event.index`** — an integer `index` (0-based intra-seq record position)
  on the `Event` schema; required for the §6.1 composite-id correctness and
  consumer-side dedup.
* **`streamEvents` description** — the SSE `id` is the composite
  `"<seq>.<index>"`, stating the *observable* exact-resume contract (no
  loss / no dup), the `behind` steer-to-backfill, and `since=S` = `seq > S`.
* **`LastEventId` parameter schema** — widened from `Cursor` (`^[0-9]+$`,
  which would reject the composite header the stream emits) to
  `^[0-9]+(\.[0-9]+)?$`, accepting both the composite and a bare seq /`0`
  (review finding #1).
* **`EventStreamError.error`** — enum is `[truncated, lag_exceeded,
  server_shutdown, behind, decode_error]`; `behind` (steer-to-backfill) and
  `decode_error` (fail-closed on a corrupt known-tag payload, finding #8)
  are both committed, and `oldestSeq` documents its `behind` meaning.
* **`listEvents` description** — group-complete paging (so the bare-seq
  `nextCursor` can never split a seq-group, finding #2), tip-bounded scan
  (no blocking for live events, finding #5), and `since=0` = oldest-retained
  (not live-tail).

Deltas *staged for the phase that introduces them* (not yet applied, to keep
the DRAFT spec minimal):

* **`readSource: [indexed, authoritative]`** on `Balance`/`BalanceList`/
  `BudgetView`/`PoolView` — lands with **G6.4**.
* **`Info` config echo** (`freeTier`, `actionCost`, `gasPoolActor`,
  `indexerSchemaVersion`) so drift is observable — lands with **G1.8**.

Each staged delta is applied in the WU's PR and recorded in the
`docs/api/CHANGELOG` (G5.3).

## §16 Revision history

* **v0.5 (this revision).** Addressed an automated PR review of #129 (nine
  findings, all valid, against the §11.4 equal-seq invariant and the §11.3
  `SUBSCRIBE` semantics) — every fix sharpened the event-streaming
  correctness the v0.4 design under-specified, with no architecture change.
  *Spec/plan consistency:* widened the `Last-Event-ID` schema to the
  composite `^[0-9]+(\.[0-9]+)?$` (#1); unified the SSE error field on
  `oldestSeq` (#3); added an `decode_error` `EventStreamError` value for a
  corrupt known-tag payload (#8). *Event-streaming design:* `GET /events`
  now uses **group-complete paging** + a **tip-bounded** scan + explicit
  `since=0` semantics (so a page can't split a seq-group and the drain
  can't hang on the unbounded `SUBSCRIBE`, #2/#5); the **mux resubscribes
  from a last-complete-group watermark** with `(seq,index)` dedup instead of
  the newest seq (closing a P1 mid-group data-loss path, #4); the default
  **`--upstream-subscriptions` is `1`** (a second sub double-ingests absent
  dedup, #6); and the live SSE stream emits only `behind` for an
  older-than-ring resume — `truncated`/409 is decided solely by `GET /events`
  (the only per-request upstream sub, #7). *Reads:* G1.6a now validates the
  **exact supported `schema_version`** set, not a `≥ 2` lower bound, so a
  v2-built gateway won't silently misread a future v3 DB (#9). YAML kept in
  lockstep (§15B). No endpoint added or removed.
* **v0.4.** Grounded the plan against the *actual Rust
  crate surfaces* and corrected five load-bearing assumptions (see the
  Status "Correctness audit"): (1) added **G1.6a** — there is no read-only
  SQLite open, so the gateway needs a new `knomosis-storage` open path
  (the v0.3 plan assumed one); (2) fixed a **latent SSE data-loss bug** —
  within-frame equal-seq groups (§11.4) make naïve `id: <seq>` resume lose
  the group tail, replaced by a **composite `id: "<seq>.<index>"`** with an
  intra-seq skip (§6.1, R12); (3) **deepened reuse** — `knomosis-indexer`
  already provides a full 23-tag event decoder *and* the §11 subscribe
  client, shrinking G3.1/G3.2 to reuse + orchestration (§3.7); (4)
  **de-duplicated CI** — `ci-rust.yml`'s `--workspace` run covers the Rust
  gates, so `ci-gateway.yml` is spec/contract-only (§10); (5) **named every
  reuse point with its real signature** (§3.7). Also: added the **G1.0 HTTP
  spike** to de-risk R1 up front; broke G1.2/G1.6/G2.1/G3.2/G3.4 into sized
  sub-WUs with file paths + acceptance + tests; added the §3.2.1 HTTP
  feature subset, the §6.2 23-tag event-JSON contract, signal-handling +
  redaction + read-isolation to §7/§8, the `--free-tier`/`--gas-pool-actor`/
  `--sse-write-timeout-ms` config, the WAL co-location constraint (§3.3,
  §9.4, R13), the §15A promotion checklist, and the §15B spec-delta ledger;
  expanded the risk register (R12–R15) and open questions (OQ-GW-12); and
  applied the `Event.index` + SSE-id spec deltas to the YAML. A subsequent
  hardening pass (same revision) then: surfaced the **`panic = "abort"`**
  workspace constraint as a hard *panic-free-handlers* rule (§3.2, R16);
  sharpened the **SSE resume mechanism** — the in-window case is *ring-cursor
  positioning*, not a per-client upstream re-read, and bare `since=S`
  excludes seq `S`'s group (was an ambiguous `(seq, −1)`; §3.5, §6.1, G3.4d)
  — and made the YAML's stream description state the observable contract
  rather than leak the (then-inaccurate) mechanism; reframed **G1.6a** to
  *prefer pure `SQLITE_OPEN_READ_ONLY`* (strongest isolation) with the
  `query_only` open as an empirically-gated fallback (§8.9); clarified that
  host-pool persistence is a *host*-side flag with a connect-per-request
  fallback (§3.3); and added **request-smuggling defenses** (G1.2a),
  `415`/`X-Accel-Buffering` handling (G2.2/G1.2e), and fail-closed
  known-tag decode (G3.2b). No endpoint was removed; the contract is a
  strict superset of v0.3.
* **v0.3.** Reconciled OQ-GW-11 against Licio's actual
  `apps/api` Hono BFF (read from source, not the README): added §1.4 with the
  monorepo structure, the fail-closed `/v1/feature-flags` crypto gate, SIWE
  identity, and the concrete read-first integration mapping. Resolved
  OQ-GW-11; refined OQ-GW-3 (SIWE ⇒ client-wallet signing) and OQ-GW-7 (SIWE
  address anchor + optional gateway resolver); downgraded risk R11; added
  dark-launch sequencing (§12). No spec shape changes — the reconciliation
  confirmed the existing schemas.
* **v0.2.** End-to-end refinement. Correctness audit
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
