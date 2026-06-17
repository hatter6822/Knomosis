<!--
Knomosis  - A Societal Kernel
Copyright (C) 2026  Adam Hall
This program comes with ABSOLUTELY NO WARRANTY.
This is free software, and you are welcome to redistribute it
under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Knomosis Gateway Operator Runbook

The operator reference for `knomosis-gateway` (Workstream GW) — the
synchronous HTTP/JSON + Server-Sent-Events service that fronts the Knomosis
binary host (§10, submit), event-subscribe (§11, the live event stream), and
indexer SQLite (§11A, reads) for a browser-facing BFF.

Design + rationale: `docs/planning/gateway_integration_plan.md`.
Contract: `docs/api/gateway.openapi.yaml`.
Supply-chain review: `docs/audits/gateway_dependency_audit.md`.

This runbook describes the **currently-shipped** surface — including native
in-process HTTPS / mTLS (G4.2, §3 / §4).  The remaining deferred items (the
SSE-tuning flags, the throughput bench, cert hot-reload) are called out in
§11.

---

## 1. Roles and topology

The gateway is one stateless process in a small fleet; it adds **no
persistence of its own** (only a per-instance idempotency cache + SSE ring,
both in-memory and bounded).

```
  L1 ─► knomosis-l1-ingest ─► (sequencer / log) ─► knomosis-host (submit)
                                      │ tails
                                      ▼
                          knomosis-event-subscribe (§11)
                             │ subscribe        │ subscribe (O(1) shared)
                             ▼                  ▼
                       knomosis-indexer    knomosis-gateway ──HTTP/JSON+SSE──► Licio BFF
                       (SQLite, RO read)   (fan-out → SSE)
```

Three upstreams: **host** (submit, loopback plaintext), **event-subscribe**
(events, TCP), and the **indexer SQLite file** (reads, read-only, **same
host** — WAL shared memory is host-local).

  * **App / platform engineer** — deploys + configures the gateway, owns the
    config-consistency obligations (§10), watches the dashboards (§9).
  * **On-call** — responds to the failure signatures (§8).
  * The gateway holds **no signing keys** (the submit path forwards
    client-signed `SignedAction` bytes opaquely); bridge/pool keys live in
    l1-ingest / the observer, never here.

---

## 2. Endpoint surface

| Method + path | Purpose | Auth |
|---|---|---|
| `GET /healthz` | Liveness (always `200` while the process runs). | exempt |
| `GET /readyz` | Readiness: probes each configured upstream. | exempt |
| `GET /v1/info` | Deployment + protocol metadata + the config echo. | required |
| `GET /v1/actors/{id}/balances[/{resource}]` | Balance view(s). | required |
| `GET /v1/actors/{id}/budget` | Epoch budget view. | required |
| `GET /v1/pools/{pool}?resource={0\|1}` | Gas-pool resource view. | required |
| `POST /v1/actions` | Submit a client-signed `SignedAction` to the host. | required |
| `GET /v1/events?since=&limit=&type=` | Cursor-paginated event backfill. | required |
| `GET /v1/events/stream?since=&type=` | Live SSE event stream. | required |

Every response carries an `X-Request-Id` correlation token (§6).  Errors are
RFC 9457 `application/problem+json` with a stable `type` URI.

---

## 3. Configuration reference (implemented flags)

Every flag has a `KNX_GW_*` environment fallback (CLI > env > default); `--help`
documents them all.  Validation **fails fast** at startup with a typed error
naming the offending knob (`OperatorExitCode::OperatorAction`, exit `2`).
Secrets (the auth token file) are passed **by path, never argv/env value**.

| Flag (env) | Default | Purpose |
|---|---|---|
| `--listen` (`KNX_GW_LISTEN`) | `127.0.0.1:8080` | HTTP listen address (loopback-safe). |
| `--handler-threads` (`…_HANDLER_THREADS`) | `16` | Bounded request-handler pool; the concurrency governor for request *processing*. |
| `--indexer-db` (`…_INDEXER_DB`) | unset → reads `503` | Indexer SQLite path, opened **read-only**. |
| `--free-tier` / `--action-cost` / `--epoch-length` | `0` | Budget-view rendering + `/v1/info` echo (**must match the deployment policy**, §10). |
| `--gas-pool-actor` (`…_GAS_POOL_ACTOR`) | unset | Sets the pool-view `net` flag (**must match the indexer's**, §10). |
| `--deployment-id` / `--ok-admission-stage` | `""` / `Finalized` | `/v1/info` metadata echo. |
| `--host-addr` (`…_HOST_ADDR`) | unset → submit `503` | Host upstream (loopback plaintext); probed by `/readyz`. |
| `--host-pool-size` / `--host-max-inflight` | `8` / = pool | Persistent host connections / concurrent-checkout cap. |
| `--request-deadline-ms` | `5000` | End-to-end submit deadline (host connect/read/write). |
| `--max-frame-size` | `1 MiB` (ceiling 16 MiB) | `POST /v1/actions` body cap → `413`. |
| `--event-subscribe-addr` (`…_EVENT_SUBSCRIBE_ADDR`) | unset → events `503` | Event-subscribe upstream; probed by `/readyz`; feeds the SSE fan-out + the backfill. |
| `--auth-token-file` (`…_AUTH_TOKEN_FILE`) | unset → **fail-closed** | Bearer token(s), one per line.  Must **not** be world-readable. |
| `--rate-limit-rps` (`…_RATE_LIMIT_RPS`) | `100` (`0`=off) | Per-credential token-bucket cap → `429` + `Retry-After`. |
| `--idempotency-ttl-secs` | `120` (`0`=off) | `Idempotency-Key` response-cache TTL. |
| `--tls-listen` (`…_TLS_LISTEN`) | unset → HTTPS off | Native HTTPS listen address (rustls 0.23, TLS 1.3); runs **alongside** `--listen`. Requires `--tls-cert` + `--tls-key`. |
| `--tls-cert` / `--tls-key` (`…_TLS_CERT` / `…_TLS_KEY`) | unset | PEM cert chain (leaf first) + private key (PKCS#8 / RSA / SEC1) for `--tls-listen`. Required when it is set. Key bytes by **path**, never argv/env. |
| `--mtls-client-ca` (`…_MTLS_CLIENT_CA`) | unset → no client auth | PEM CA bundle; presence **requires** a client cert chaining to it (mTLS). |
| `--tls-max-connections` (`…_TLS_MAX_CONNECTIONS`) | `1024` | Cap on concurrent TLS connections (each on its own thread); the spawn-storm bound. |
| `--sse-ring-capacity` (`…_SSE_RING_CAPACITY`) | `4096` | SSE fan-out ring depth (records retained for replay / resume). Range `2..=1048576`. |
| `--sse-max-streams` (`…_SSE_MAX_STREAMS`) | `256` | Max concurrent SSE streams; an over-cap connect is `503`. |
| `--sse-max-client-lag` (`…_SSE_MAX_CLIENT_LAG`) | `2048` | Per-client lag bound (records) before a `lag_exceeded` eviction. **Must be `< --sse-ring-capacity`** (the default auto-fits a smaller ring). |
| `--sse-heartbeat-secs` (`…_SSE_HEARTBEAT_SECS`) | `15` | SSE heartbeat-comment interval when a stream is idle. |
| `--sse-stale-secs` (`…_SSE_STALE_SECS`) | `55` | Fan-out upstream-read staleness timeout (quiet live-tail reconnect cadence). |

The SSE knobs above are honoured **identically** on the plaintext and
native-TLS stream paths (they share one `config::SseConfig` through the
`AppState`).  `--sse-max-client-lag` is validated **below** `--sse-ring-capacity`
so the proactive `lag_exceeded` eviction fires before the ring drops a client's
unseen records.

---

## 4. Security model

  * **Fail-closed bearer auth.**  With **no** `--auth-token-file`, every
    non-exempt request is denied (`401`); only `/healthz` + `/readyz` stay
    open.  The token compare is constant-time (`subtle`); the gateway
    **refuses to start** if the token file is world-readable (`other`
    permission bits set).  Tokens never appear in logs (§6).
  * **No key custody.**  `POST /v1/actions` forwards the client's signed
    bytes opaquely; the gateway cannot forge or alter an action.
  * **Read isolation.**  Reads use a pure `SQLITE_OPEN_READ_ONLY` handle — a
    gateway logic bug *cannot* mutate the indexer database.
  * **Per-credential rate limiting.**  A token-bucket per credential →
    `429` + `Retry-After` + a `retryAfterMs` problem extension.
  * **Resource bounds.**  Concurrent streams, host connections, in-flight
    submits, the fan-out ring, and the idempotency cache are all bounded;
    an over-cap request is a `503`, never unbounded growth.
  * **TLS termination.**  Two supported models: **native in-process HTTPS**
    (`--tls-listen`, rustls 0.23, TLS 1.3 floor, the `ring` backend), which
    runs **alongside** the plaintext `--listen` socket and can additionally
    **require client certificates** via `--mtls-client-ca` (mTLS); **or** an
    **L7 edge** that terminates TLS and forwards loopback-plaintext HTTP (then
    leave `--tls-listen` unset and keep `--listen` loopback).  The native path
    feeds the **same** auth / rate / dispatch core through a strict,
    smuggling-proof HTTP/1.1 reader (TLS 1.3 only; `Transfer-Encoding` and
    ambiguous `Content-Length` rejected), and **fails fast at startup** on a
    bad cert / key / CA.  Bind `--tls-listen` to a public interface only when
    you intend the gateway to face clients directly.

---

## 5. Start / stop, health, and readiness

  * **Start:** `knomosis-gateway --listen … --indexer-db … --auth-token-file
    … [--host-addr …] [--event-subscribe-addr …]`.  Startup logs the
    identifier + version + listen addr, and **warns loudly** if no auth token
    file is configured (fail-closed).
  * **Liveness (`/healthz`):** a static `200` — the process is up.
  * **Readiness (`/readyz`):** probes each *configured* upstream — a fresh
    indexer cursor read, and a TCP connect to the host / event-subscribe
    addresses — and answers `200` iff all pass, else `503` with a
    per-upstream boolean body.  **An unconfigured upstream is treated as
    satisfied** (not blocking).  Health-gate rollout on `/readyz` before
    sending traffic.
  * **`/v1/info`:** the deployment id, the `Verdict::Ok` admission stage, the
    host + event-subscribe wire `PROTOCOL_VERSION`s, the live indexer cursor
    + schema version, and the **budget/pool config echo** (so a §10 drift is
    observable).
  * **Graceful stop:** send **SIGTERM** or **SIGINT** (§7).

---

## 6. Observability

  * **Per-request correlation id** (`X-Request-Id: req-<nonce>-<seq>`) on
    every response, mirrored into the RFC 9457 `problem.instance` on error
    bodies — so a client's error maps to a server log line.
  * **Structured per-request log** (one line at completion): `request_id`,
    `method`, `path`, `status`, `latency_us`.  This is the **log-based
    metrics** surface (OQ-GW-10): derive per-endpoint rate / status / latency
    from it.  A `/metrics` endpoint is a deferred alternative.
  * **Secret redaction (§8.1):** the request log records **only** the method
    / path / status / latency / id — never the `Authorization` header /
    token, an `Idempotency-Key`, or a body (a log-capture test guards this).
  * **SSE stream lifecycle** is logged at open + close (with the close
    reason: disconnected / evicted / fault / shutting-down).

---

## 7. Graceful shutdown

SIGTERM / SIGINT set the shared shutdown flag; `serve` then drains:

  1. New requests stop being accepted; in-flight requests **complete**
     (bounded by `--request-deadline-ms`).
  2. The handler pool is drained under a **10 s deadline** — a stuck worker
     cannot hang shutdown past it.
  3. The SSE fan-out mux stops; every live SSE stream emits a clean
     `event: error` `{"error":"server_shutdown"}` close (checked **between
     whole records**, so a record is never truncated) and exits.

Process exit is clean (`OperatorExitCode::Success`, `0`).  A `SIGKILL` still
stops the process (without the drain).

---

## 8. Failure signatures and remediation

| Signature | Likely cause | Remediation |
|---|---|---|
| `503` `events-unavailable` on `/v1/events*` | No `--event-subscribe-addr`. | Configure the upstream; restart. |
| `503` `reads-unavailable` on read endpoints | No `--indexer-db`. | Configure the read DB; restart. |
| `503` `upstream-unavailable` storms | Host / event-subscribe upstream down or rejecting; `/readyz` red. | Check the upstream; the gateway recovers automatically when it returns. |
| `503` `Busy` storms on `POST /v1/actions` | Host worker queue saturated (`Verdict::Busy`) or the connection pool exhausted. | Honour `Retry-After`; raise host capacity / `--host-pool-size`; investigate the host. |
| `409` `truncated-cursor` on `/v1/events` | A backfill cursor predates the upstream history window. | Client re-requests from the returned `oldestSeq` (the gateway does the right thing; this is informational). |
| SSE `event: error{behind}` | A live client fell behind the fan-out ring. | Client follows the steer to `GET /events` backfill, then reconnects with `Last-Event-ID`. |
| SSE `event: error{lag_exceeded}` | A slow client exceeded `max_client_lag` or stalled its socket. | Client reconnects; if chronic, the consumer is too slow / the network is degraded. |
| SSE `event: error{decode_error}` then close | A **known-tag** upstream event failed to decode (corruption). | **Fail-closed by design** (never a silent skip).  Investigate the upstream / extractor; this should not occur with a healthy stack. |
| Stale / lagging reads | Read-only WAL goes stale when the **indexer writer dies** (OQ-GW-13). | `/readyz` enforces a live cursor read; restart the indexer writer.  Reads are §3.6 eventually-consistent — the kernel is authoritative. |
| New SSE connections hang / are not served at high fan-out | The `tiny_http` per-connection-task ceiling (**OQ-GW-14**) — long-lived streams pin internal tasks below `max_streams`. | Keep concurrent-SSE fan-out modest (a browser-BFF scale); the no-leak soak confirms slots are never *leaked*.  Raising the ceiling is a transport change (OQ-GW-14). |
| Startup refuses with a permission error | The `--auth-token-file` is world-readable. | `chmod 600` the token file. |
| Every request `401` despite a token | No `--auth-token-file` configured (fail-closed) — see the startup warning. | Configure the token file. |
| Config drift (wrong budget / pool numbers) | `--free-tier` / `--gas-pool-actor` mismatch the deployment (§10). | Diff `/v1/info`'s echo against the indexer's config; reconcile. |

---

## 9. Monitoring checklist

  * **`/readyz`** green (host + event-subscribe reachable; indexer openable +
    cursor advancing).
  * **Request-log metrics** (per endpoint): rate, `status` distribution
    (watch `5xx` / `429`), `latency_us` p50/p99.
  * **Indexer cursor** (`/v1/info.indexerSeq`) advancing — a flat cursor =
    writer death / lag.
  * **SSE**: live-stream count vs `max_streams`; `lag_exceeded` / `behind`
    rates; the mux's `Reconnecting` log frequency (upstream churn).
  * **Submit**: `Busy` / `503` rate; the idempotency-cache hit rate.

---

## 10. Operator obligations (config the gateway can't self-check)

The gateway **cannot** verify these against the live deployment; a mismatch
silently renders the wrong numbers.  Keep them in lockstep and verify via
`/v1/info`:

  * `--free-tier` / `--action-cost` / `--epoch-length` == the deployment's
    budget policy.
  * `--gas-pool-actor` == the indexer's `--gas-pool-actor` (drives the
    pool-view `net` flag).
  * `--indexer-db` points at the **same** indexer the host/upstreams feed,
    on the **same host** (WAL is host-local), with the **writer live**.

---

## 11. Known limitations / deferred

  * **Native TLS / mTLS (G4.2)** — **implemented** (`--tls-listen` /
    `--tls-cert` / `--tls-key` / `--mtls-client-ca`, rustls 0.23, TLS 1.3,
    §3 / §4).  Edge termination stays a supported alternative.  *Residual:*
    the TLS path's per-read timeout bounds slow-loris per read (not an overall
    per-request deadline) — parity with `knomosis-host`; and certificate
    **rotation** requires a process restart (no hot-reload of the
    `ServerConfig` yet).
  * **SSE-tuning flags** — the ring / stream / heartbeat knobs are
    compile-time defaults (`SseConfig`); `--sse-*` flags are a follow-up.
  * **Concurrent-SSE ceiling (OQ-GW-14)** — bounded by `tiny_http`'s
    connection model below `max_streams`; adequate for a browser-BFF fan-out.
  * **Throughput bench (G4.6)** — the `knomosis-gateway`-bench perf tool is
    deferred (the no-leak soak validates correctness, not a throughput
    target).
  * **Cross-instance idempotency** (OQ-GW-4) + **cross-host reads**
    (OQ-GW-9, the indexer query server) are out of v1 scope.

---

## 12. Quick reference

```bash
# Minimal read-only deployment (TLS at the edge):
knomosis-gateway --listen 127.0.0.1:8080 \
  --indexer-db /var/lib/knomosis/index.db \
  --auth-token-file /etc/knomosis/gw.tokens     # chmod 600

# Native HTTPS (rustls 0.23, TLS 1.3) + mTLS, alongside the plaintext socket:
knomosis-gateway --listen 127.0.0.1:8080 \
  --tls-listen 0.0.0.0:8443 \
  --tls-cert /etc/knomosis/tls/server.crt \
  --tls-key  /etc/knomosis/tls/server.key \      # chmod 600
  --mtls-client-ca /etc/knomosis/tls/clients-ca.crt \
  --indexer-db /var/lib/knomosis/index.db \
  --auth-token-file /etc/knomosis/gw.tokens     # chmod 600

# Full surface (reads + submit + events):
knomosis-gateway --listen 127.0.0.1:8080 \
  --indexer-db /var/lib/knomosis/index.db \
  --host-addr 127.0.0.1:7654 \
  --event-subscribe-addr 127.0.0.1:7655 \
  --auth-token-file /etc/knomosis/gw.tokens \
  --gas-pool-actor 161 --free-tier 1000 --action-cost 5 --epoch-length 7200

# Health / readiness / metadata:
curl -fsS localhost:8080/healthz
curl -fsS localhost:8080/readyz | jq
curl -fsS -H 'Authorization: Bearer <tok>' localhost:8080/v1/info | jq

# Graceful stop:
kill -TERM <pid>     # drains in-flight requests + closes SSE streams cleanly
```
