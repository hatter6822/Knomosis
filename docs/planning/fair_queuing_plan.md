<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Per-Actor Fair Queuing / Burst Resistance — Workstream Plan (Workstream FQ)

**Document version:** v1.0 (initial).

## Status

**Planned.**  Not started.  Workstream FQ adds per-actor fair
scheduling to `runtime/knomosis-host` (the RH-C network adaptor) so
that one actor's short-burst flood cannot delay other actors'
admitted actions, while productive bursts on an idle/underutilised
host pass through unthrottled.

FQ is the **liveness / quality-of-service complement** to Workstream
GP (`docs/planning/unified_gas_pool_plan.md`).  GP bounds the
*stock* an actor can spend (a safety property: pay-per-action,
bounded lifetime cost, proven in the Lean kernel).  FQ bounds the
*flow* — the share of the serial dispatch worker any one actor can
occupy under contention — which is a *liveness* property and
therefore lives at the sequencing layer, not in the proof-carrying
kernel.  See §2.1 for the safety-vs-liveness rationale that scopes
this split.

**Prerequisite.**  RH-C (`knomosis-host`) is Complete.  FQ extends
it; it does not depend on any in-flight kernel work.

**Effort estimate.**  ~16.5 engineer-days total (Rung 0 ≈ 8.5d;
Rung 1 ≈ 8d), one engineer, assuming familiarity with the existing
`knomosis-host` threading model.

## Table of contents

  * §1 Goals and non-goals
  * §2 Architectural background
    * §2.1 Where FQ sits: safety vs liveness
    * §2.2 The current `knomosis-host` queue
    * §2.3 Why FIFO is unfair at both ends
    * §2.4 The routing-key problem and the rung ladder
    * §2.5 Trust and safety invariants
    * §2.6 The DRR core
  * §3 Work-unit dependency graph
  * §4 Work-unit specifications
    * Rung 0 — connection-keyed DRR (no wire change): FQ.0 – FQ.8
    * Rung 1 — signer-hint header + two-tier DRR: FQ.9 – FQ.15
  * §5 Risks and mitigations
  * §6 Explicitly out of scope / future work
  * §7 Workstream acceptance criteria

## §1 Goals and non-goals

### §1.1 Goals

  1. **Targeted burst resistance.**  Under contention for the serial
     dispatch worker, no actor may occupy more than its fair share;
     a flooding actor delays only itself.  Honest actors retain
     their share and their enqueue capacity.
  2. **Work-conserving.**  When the host is idle or underutilised,
     any actor may use the full worker — a productive burst is
     throttled by *nothing*.  Fair shares bind only when demand
     exceeds capacity.
  3. **Bounded wait / no starvation.**  Every active flow's head
     request is served within one round-robin cycle, whose length
     is bounded by the configured maximum number of flows.
  4. **Preserve the kernel safety boundary.**  The scheduler must
     never influence admissibility.  A scheduling bug may reorder or
     drop, never admit an inadmissible action nor reject an
     admissible one for a reason the kernel would not.  (This is the
     existing `knomosis-host` security property #1; FQ must keep it.)
  5. **Reversible rollout.**  The fair scheduler ships behind a
     config flag, defaulting OFF (FIFO), so it is A/B-testable and
     instantly revertible.  Rung 0 introduces no wire-format change.
  6. **Designed-in extensibility.**  Keep the scheduling decision a
     pure function so the future "accountable fairness" work
     (committed served-counts + fault-proof challenge) can replay it,
     and keep a per-flow weight field so budget-weighted quanta can
     be added without a structural change.

### §1.2 Non-goals

  * **Budget-weighted quanta.**  FQ ships equal-weight (quantum = 1).
    Weighting a flow's quantum by its prepaid GP budget requires a
    host-side budget read (the deferred `knomosis-host` getBalance /
    budget endpoint noted in the RH-E.1 closeout).  Deferred — the
    per-flow weight field is reserved but populated equal.
  * **Accountable fairness.**  Committing per-actor served-counts to
    state and letting a fault-proof observer challenge an unfair
    sequencer is a separate, larger effort (it touches committed
    state).  FQ only keeps the door open by isolating the pure
    decision function (§2.6, FQ.1).
  * **Wall-clock liveness guarantees.**  FQ allocates the worker
    fairly; it cannot promise inclusion against a censoring operator.
    The backstop for that is L1 forced inclusion (out of scope here;
    a fault-proof-rollup feature alongside Workstream H).
  * **Parsing CBE for admissibility at the host.**  The host remains
    a byte-opaque forwarder.  FQ reads at most an explicit,
    untrusted routing hint (Rung 1) — never the CBE body.
  * **An async runtime.**  FQ stays within the crate's synchronous
    `std::thread` + `Mutex`/`Condvar` model (no `tokio`).
  * **Deciding the production topology.**  Whether end users connect
    to `knomosis-host` directly or through an upstream sequencer is a
    deployment decision (§2.4 explains how FQ behaves under each).
    FQ delivers a reusable scheduler that is correct wherever the
    per-actor contention actually lands.

### §1.3 Reading guide

  * **Implementer:** read §2.2–§2.6 for the design, then work §4 in
    dependency order (§3).  Each WU is self-contained: Scope,
    Implementation steps, Acceptance criteria, Risk, Effort.
  * **Reviewer:** the load-bearing invariants are in §2.5.  Confirm
    every WU preserves them (especially FQ.2, FQ.4, FQ.10, FQ.12).
  * **Operator:** the new CLI flags are introduced in FQ.0 and FQ.5;
    the wire-format change is FQ.9 (`docs/abi.md` §10).

### §1.4 Glossary

  * **Flow** — the unit of fairness: the set of queued requests
    sharing one routing key.  Rung 0: one flow per connection.
    Rung 1: one flow per (connection, signer-hint).
  * **Routing key** — the value the scheduler buckets a request by.
    A *classification* hint only; never trusted for admissibility.
  * **DRR (Deficit Round Robin)** — a work-conserving fair scheduler.
    Each flow has a `deficit` counter; on its turn it gains a
    `quantum` of credit and serves requests whose cost is covered.
  * **Quantum** — the per-turn credit a flow receives; proportional
    to its weight.  Equal for all flows in FQ (= 1).
  * **Cost** — the credit a request consumes.  FQ uses cost = 1
    (one dispatch slot on the serial worker).
  * **Work-conserving** — the worker idles only when *all* flows are
    empty; spare capacity always goes to whoever has demand.
  * **Head-of-line (HOL) blocking** — a slow/large flow at the front
    of a FIFO delaying everything behind it.  The defect FQ removes.
  * **ConnId** — a monotonic per-accepted-connection identifier
    assigned at `accept()`; transport-authenticated and unspoofable.
  * **Signer-hint** — an explicit, untrusted 8-byte routing hint a
    Rung-1 client prepends to each frame to declare the action's
    signer.  Misuse is a fairness-only concern (§2.5).

## §2 Architectural background

### §2.1 Where FQ sits: safety vs liveness

Everything the Lean kernel proves is a **safety** property
(determinism, refinement, no-silent-illegality, conservation,
replay-impossibility): violated by a finite trace, established by
invariants.  Burst-fairness — "honest actors keep getting served
while a whale floods" — is a **liveness** property: established by
scheduling, fairness assumptions, and incentives, not by state
invariants.  The kernel has no notion of contention or ordering and
does not produce schedules, so burst-fairness cannot be a kernel
theorem.  This is a classification fact, not an engineering gap.

The correct division is therefore:

  * **Kernel (safety):** the GP per-action stock bound.  Bounds an
    actor's lifetime cost; prevents sustained/infinite DoS.  Already
    shipped.
  * **Sequencer (liveness):** FQ's work-conserving fair scheduler.
    Bounds an actor's *share of the worker under contention*;
    prevents short-burst overwhelm without penalising productive
    bursts.  This document.
  * **L1 (liveness backstop):** forced inclusion defeats a censoring
    operator.  Out of scope here.

FQ does not weaken any kernel guarantee: the proof-carrying safety
core is untouched.  It scopes a property the kernel provably cannot
deliver to the layer that can.

### §2.2 The current `knomosis-host` queue

Established by reading `runtime/knomosis-host/src/{queue,server,
listener,lib}.rs`:

  * `Server::run` builds **one** `BoundedQueue` — a
    `std::sync::mpsc::sync_channel(max_queue_depth)` — and spawns a
    single `worker_loop(receiver, kernel, stop)`.  The worker is
    serial *by design*: the kernel holds mutable log state requiring
    sequential access.  **The contended resource is exactly this one
    worker's dispatch slots.**
  * Each accepted connection runs in its own thread; the handler
    calls `queue.try_submit(payload)` → `Enqueued(reply_rx)` or
    `Busy`, then blocks on `reply_rx.recv()`.
  * A `QueuedRequest { payload: Vec<u8>, reply: SyncSender<KernelResponse> }`
    carries the opaque CBE bytes plus a one-shot reply channel.  The
    worker `drain_one`s FIFO, dispatches, and replies.
  * **The host never parses the CBE payload** (lib.rs security
    property #1: framing/queue bugs "can drop or reorder but cannot
    violate any admissibility witness").
  * `admission.rs` already defines `AdmissionStage::Sequenced` —
    the conceptual slot a fair scheduler fills.

### §2.3 Why FIFO is unfair at both ends

A single FIFO into a single shared bounded buffer is unfair in two
independent ways, and FQ must fix both:

  * **Dequeue (HOL blocking).**  A whale's 10k requests form a
    contiguous FIFO run; a small actor's single request waits behind
    all of them.  DRR fixes the dequeue order.
  * **Enqueue (shared-buffer starvation).**  The whale fills all 256
    buffer slots, so honest requests receive `Busy` *before*
    scheduling can help them.  FQ therefore also needs **per-flow
    buffer caps**: a flooding flow gets `Busy` on its *own*
    over-submission while other flows still enqueue freely.  This
    per-flow `Busy` is the enqueue-side dual of DRR.

### §2.4 The routing-key problem and the rung ladder

To bucket by actor the host needs a per-request key, but the signer
is not cheaply available: `SignedAction.encode = action ++ signer ++
nonce ++ sig`, so the signer sits *after* the variable-length
`Action`.  Reading it would require parsing the whole Action — i.e.
exactly the CBE interpretation the host must not do.  Resolve as a
ladder:

  * **Rung 0 (no wire change): key = ConnId.**  The connection is
    transport-authenticated, so unspoofable.  DRR across
    connections.  Zero CBE parsing.  Meaningful whenever distinct
    actors arrive on distinct connections.
  * **Rung 1 (additive, version-gated): key = (ConnId, signer-hint).**
    The client prepends an explicit 8-byte signer hint per frame; the
    host buckets by it for *scheduling only*.  The kernel still reads
    the real signer from the CBE and verifies the signature, so a
    forged hint cannot affect admissibility.  Two-tier: outer
    round-robin across connections, inner across signer-hints within
    a connection.
  * **Ruled out: a full `Action` parser in the host.**  It would
    replicate kernel decode logic and couple the host to every future
    `Action` constructor.  Never do this.

**Topology note.**  If end users funnel through a single upstream
sequencer connection, Rung 0 is degenerate (one connection = one
flow) and the *sequencer itself* is the place fairness must live —
but the FQ scheduler module is reusable there unchanged.  If users
connect to `knomosis-host` more directly, Rung 0 is immediately
meaningful and Rung 1 sharpens it.  FQ delivers the mechanism; the
deployment chooses where the contention point is.

### §2.5 Trust and safety invariants

These are the invariants every WU must preserve; reviewers check
them explicitly.

  1. **Classification-only routing.**  The routing key influences
     *order and drop*, never admissibility.  A wrong or forged key
     can only mis-route, and mis-route ⊆ "reorder", which the
     existing security property #1 already tolerates.  **Safety is
     untouched by any routing decision.**
  2. **Spoofing is a fairness-only risk.**  A Rung-1 client that
     lies about its signer-hint can only disturb scheduling.  The
     two-tier structure confines the damage: a connection that
     spawns many fake hints still receives only its *one*
     connection's outer share, subdivided among its fakes — self-harm,
     not theft from others.  The ConnId outer tier is unspoofable, so
     a victim on another connection is unaffected.
  3. **Legacy clients degrade safely.**  A client that sends no hint
     is treated as a single implicit flow within its connection —
     i.e. Rung-0 behaviour for that connection.  Rung 1 is strictly
     additive.
  4. **The scheduler is itself bounded.**  Distinct flows are an
     attack surface (unbounded map growth).  Bounded by `max_flows`
     (and, in Rung 1, a per-connection distinct-signer cap), plus
     immediate eviction of empty flows.

### §2.6 The DRR core

  * **Cost = 1 per request** (one dispatch slot).  No payload
    inspection needed to compute cost.
  * **Quantum = 1, equal weight.**  At cost = 1 / quantum = 1, DRR
    collapses to strict per-actor **round-robin**: serve one, rotate.
    The `deficit` accounting and per-flow `quantum` field are kept so
    that budget-weighted quanta (a concrete, planned extension —
    §1.2) drop in without restructuring.
  * **Reset deficit to 0 when a flow empties** (and evict it).  No
    banking of credit across idle periods — a returning whale cannot
    accumulate a burst allowance while quiet, which is precisely the
    anti-burst goal.
  * **Work-conserving.**  The worker blocks only when *all* flows are
    empty (`Condvar` wait); any pending request is served.
  * **Bounded wait.**  A flow's head waits at most `(active_flows -
    1)` dispatches — bounded because `active_flows ≤ max_flows`.
  * **Pure decision.**  The selection is a pure function
    `pick(&DrrState) -> Option<Key>`; the only nondeterminism is
    arrival order.  This is the seam for future accountable-fairness
    replay and the unit-test surface.

## §3 Work-unit dependency graph

```
Rung 0:
  FQ.0 (skeleton + --scheduler flag)
   ├─> FQ.1 (pure DRR core)            ─┐
   ├─> FQ.3 (ConnId assignment)         ├─> FQ.4 (worker/Server wiring)
   └─> FQ.5 (caps config)              ─┘        │
        FQ.1 ─> FQ.2 (FairQueue wrapper) ────────┘
                                          FQ.4 ─> FQ.6 (observability)
                                          FQ.4 ─> FQ.7 (integration tests)
                                          FQ.7 ─> FQ.8 (docs + closeout)

Rung 1 (begins after FQ.8 lands):
  FQ.9 (wire amendment + abi.md)
   ├─> FQ.10 (frame hint parser)
   ├─> FQ.11 (two-tier pure core)  [also needs FQ.1]
   │      └─> FQ.12 (FairQueue two-tier)  [also needs FQ.2]
   └─> FQ.13 (client emitters)
        FQ.12 + FQ.13 ─> FQ.14 (Rung-1 tests) ─> FQ.15 (docs + closeout)
```

**Critical path:** FQ.0 → FQ.1 → FQ.2 → FQ.4 → FQ.7 → FQ.8 → FQ.9 →
FQ.11 → FQ.12 → FQ.14 → FQ.15.  FQ.3 and FQ.5 parallelise with the
FQ.1/FQ.2 chain; FQ.13 parallelises with FQ.10–FQ.12.

**Parallelism note (per CLAUDE.md background-agent discipline):**
FQ.1 (pure core, new file `src/fair/drr.rs`) and FQ.3 (ConnId, in
`src/listener.rs` + `src/server.rs`) touch disjoint files and may be
worked concurrently.  FQ.2 and FQ.4 touch `src/queue.rs` /
`src/server.rs` and must be serialised against FQ.3's `server.rs`
edits — partition by hand or do them sequentially.

**Effort roll-up.**  Rung 0: FQ.0 0.5 + FQ.1 1.5 + FQ.2 1.5 + FQ.3
1.0 + FQ.4 1.0 + FQ.5 0.5 + FQ.6 0.5 + FQ.7 1.5 + FQ.8 0.5 = **8.5d**.
Rung 1: FQ.9 1.0 + FQ.10 1.0 + FQ.11 1.5 + FQ.12 1.0 + FQ.13 1.5 +
FQ.14 1.5 + FQ.15 0.5 = **8.0d**.  Total **16.5 engineer-days**.

## §4 Work-unit specifications

### Rung 0 — connection-keyed DRR (no wire change)

#### FQ.0 — Workstream skeleton + scheduler selector

**Scope.**  `runtime/knomosis-host/src/config.rs`,
`src/lib.rs`, new module dir `src/fair/` (empty `mod.rs`).

**Implementation steps.**

  1. Add a `Scheduler` enum (`Fifo`, `Drr`) with `FromStr` +
     `Display`; default `Fifo`.
  2. Add `--scheduler {fifo|drr}` CLI flag + a `scheduler:
     Scheduler` field on the host config; parse + validate.
  3. Declare `pub mod fair;` in `lib.rs` with an empty `src/fair/
     mod.rs` (re-export point for FQ.1/FQ.2).
  4. No behavioural change yet: the value is parsed and stored;
     `Server::run` still builds the FIFO `BoundedQueue` regardless.

**Acceptance criteria.**

  * `--scheduler drr` and `--scheduler fifo` parse; an invalid value
    errors with a clear message; default is `Fifo`.
  * `cargo build/test/clippy -D warnings/fmt` clean.  No behaviour
    change (existing tests pass unmodified).

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

#### FQ.1 — Pure DRR core (single-tier)

**Scope.**  New `runtime/knomosis-host/src/fair/drr.rs` (pure; no
I/O, no `std::sync`, no sockets).

**Implementation steps.**

  1. Types: `Flow { deque: VecDeque<QueuedRequest>, deficit: u64,
     quantum: u64 }` and `DrrState { flows: BTreeMap<Key, Flow>,
     active: VecDeque<Key>, total_depth: usize }`, generic over the
     routing `Key` (instantiated to `ConnId` in Rung 0).
  2. `enqueue(&mut self, key, req) -> Result<(), QueuedRequest>`:
     push to the flow; on an empty→non-empty transition append the
     key to `active`; bump `total_depth`.  (Caps are enforced by the
     FQ.2 wrapper, not here — this module stays policy-pure about
     capacity, returning the request back on a caller-detected cap
     so no request is silently dropped.)
  3. `pick(&mut self) -> Option<QueuedRequest>`: the DRR step.  Peek
     `active` front; top up `deficit += quantum` once on entry to the
     flow's turn; if `cost(=1) <= deficit`, pop head, `deficit -= 1`,
     `total_depth -= 1`; if the flow is now empty **remove it from
     `active` and from `flows`, discarding its deficit**; else rotate
     the key to the back of `active`.  Return the popped request.
  4. Keep every decision branch deterministic and free of wall-clock
     reads (the accountable-fairness seam, §2.6).

**Acceptance criteria.**

  * Unit tests: round-robin order across N flows; one heavy flow
    does not starve a light flow (light flow's head served within N
    dispatches); empty-flow eviction + deficit reset; `total_depth`
    accounting exact; `pick` on empty state returns `None`.
  * Property test: for any interleaving of enqueues, no flow is
    served more than one request ahead of the least-served active
    flow (equal-weight fairness bound).
  * `clippy::pedantic` clean; no `unsafe`; no `panic!` on any input.

**Risk.**  Low–medium.  The activation/eviction bookkeeping is the
classic DRR fiddly part; the property test guards it.

**Effort.**  ~1.5 engineer-days.

#### FQ.2 — `FairQueue` wrapper (caps + blocking handoff)

**Scope.**  `runtime/knomosis-host/src/queue.rs` (add `FairQueue`
alongside the existing `BoundedQueue`; do not remove the latter).

**Implementation steps.**

  1. `FairQueue { inner: Arc<Mutex<DrrState<ConnId>>>, not_empty:
     Arc<Condvar>, per_flow_cap, global_cap, max_flows: usize }`,
     `Clone` (shares the `Arc`s) to match `BoundedQueue`'s
     producer-handle ergonomics.
  2. `try_submit(&self, conn: ConnId, payload: Vec<u8>) ->
     SubmitOutcome`: build the one-shot reply channel (capacity 1,
     as today); lock; enforce, in order, `global_cap`, `max_flows`
     (only when creating a new flow), `per_flow_cap` → return
     `Busy` on any breach (per-flow breach affects only the
     offending flow); else `enqueue` + `notify_one`; return
     `Enqueued(reply_rx)`.
  3. `next(&self, timeout: Duration) -> NextOutcome`: lock; if no
     active flow, `not_empty.wait_timeout(timeout)`; return
     `Idle` on timeout (so the worker re-checks its stop flag),
     `Dispatch(QueuedRequest)` when `pick` yields one, and
     `ShuttingDown` when the stop flag is set and the queue is
     drained (see FQ.4 for the stop wiring).
  4. Reuse the existing `SubmitOutcome` (`Enqueued` / `Busy`); the
     reply mechanism and `QueuedRequest` are unchanged.

**Acceptance criteria.**

  * Per-flow cap: a single flow saturating its cap gets `Busy`; a
    second flow still enqueues (targeted backpressure).
  * `global_cap` and `max_flows` each independently produce `Busy`.
  * `next` blocks when empty and wakes on `notify`; `wait_timeout`
    returns `Idle` promptly so shutdown polling works.
  * Lock-poison handled explicitly (no `unwrap` that can panic a
    producer thread); no `unsafe`.

**Risk.**  Medium.  `Condvar` + shutdown wake-up ordering (see FQ.4).

**Effort.**  ~1.5 engineer-days.

#### FQ.3 — ConnId assignment + threading

**Scope.**  `runtime/knomosis-host/src/listener.rs`,
`src/server.rs`.

**Implementation steps.**

  1. Add a monotonic `conn_seq: Arc<AtomicU64>` created in
     `Server::run` (separate from the existing `connection_counter`
     gauge, which is inc/dec for the concurrency cap and is NOT a
     stable unique id).
  2. Pass `conn_seq` into each `accept_loop` (TCP, TLS, Unix).  On
     each accepted connection, `let conn_id = conn_seq.fetch_add(1,
     Relaxed);` and thread it into the per-connection handler.
  3. Change the handler's submit call site to carry `conn_id`.  On
     the FIFO path, `conn_id` is accepted and ignored (additive
     signature change; FIFO still compiles and behaves identically).
  4. ConnIds are never reused (monotonic), so a closed connection's
     evicted DRR flow cannot alias a later connection.

**Acceptance criteria.**

  * Distinct concurrent connections receive distinct `ConnId`s;
    values are monotonic.
  * FIFO path behaviour unchanged (existing listener tests pass).
  * All three listeners (TCP/TLS/Unix) thread the id identically.

**Risk.**  Low.

**Effort.**  ~1.0 engineer-day.

#### FQ.4 — Worker-loop + `Server::run` integration

**Scope.**  `runtime/knomosis-host/src/server.rs`,
`src/queue.rs` (worker loop helper).

**Implementation steps.**

  1. In `Server::run`, branch on `config.scheduler`: `Fifo` builds
     the `BoundedQueue` + existing `worker_loop` (unchanged path);
     `Drr` builds a `FairQueue` + a `fair_worker_loop`.
  2. `fair_worker_loop(queue, kernel, stop)`: loop calling
     `queue.next(timeout)`; on `Dispatch(req)` call `kernel.submit`
     and `req.reply.try_send(response)` (identical to `drain_one`'s
     body); on `Idle` re-check `stop`; on `ShuttingDown` break.
  3. **Shutdown protocol** (the correctness-critical step): the
     `Mutex`/`Condvar` queue has no automatic "all producers
     dropped" signal like the channel did.  After the listener
     accept-loops exit and in-flight handlers drain, `Server::run`
     sets `stop` and calls `not_empty.notify_all()` to wake a parked
     worker; the worker then drains any remaining buckets and exits
     when `stop && total_depth == 0`.
  4. Preserve the existing `SHUTDOWN_DRAIN_TIMEOUT` semantics.

**Acceptance criteria.**

  * End-to-end on the `Drr` path: connect, submit, receive verdict
    (parity with the FIFO path for a single actor).
  * Graceful shutdown: queued requests drain; the worker joins; no
    hang on the `Condvar`; no lost replies for in-flight requests.
  * `--scheduler fifo` is byte-for-byte the old behaviour.

**Risk.**  Medium.  Shutdown wake-up + drain ordering is the most
error-prone part; test kill-during-load explicitly.

**Effort.**  ~1.0 engineer-day.

#### FQ.5 — Caps configuration + validation

**Scope.**  `runtime/knomosis-host/src/config.rs`.

**Implementation steps.**

  1. Add flags + config fields: `--per-flow-cap <n>` (default 64),
     `--max-flows <n>` (default 4096), and reuse `--max-queue-depth`
     as the DRR `global_cap`.
  2. Validate: `per_flow_cap >= 1`, `per_flow_cap <= global_cap`,
     `max_flows >= 1`; clamp `max_flows` and `global_cap` to
     hard ceilings (mirror `HARD_MAX_QUEUE_DEPTH`'s style) to bound
     worst-case memory (`global_cap * max_frame_size`).
  3. These fields are inert unless `--scheduler drr`; document that
     in the flag help text.

**Acceptance criteria.**

  * Defaults present; out-of-range values rejected or clamped per
    spec; help text states FIFO ignores them.
  * Config round-trip / parse tests cover each new flag.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

#### FQ.6 — Observability

**Scope.**  `runtime/knomosis-host/src/queue.rs` (+ `tracing`
call sites).

**Implementation steps.**

  1. Counters: per-flow `Busy` rejections, `global_cap`/`max_flows`
     rejections, active-flow gauge, total dispatches.
  2. Emit via the crate's existing `tracing` usage at
     `debug`/`info`; no new dependency.  Avoid per-request `info`
     spam — aggregate and log periodically or at thresholds.
  3. Expose a cheap `FairQueue::stats()` snapshot for tests and a
     future status endpoint.

**Acceptance criteria.**

  * Under a synthetic flood, the per-flow `Busy` counter and
    active-flow gauge move as expected; no log flooding at `info`.
  * `stats()` returns a consistent snapshot under concurrent load.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### FQ.7 — Integration + fairness tests

**Scope.**  `runtime/knomosis-host/tests/` (new
`fair_queue.rs`), using `MockKernel`.

**Implementation steps.**

  1. **Fairness under contention:** one "whale" connection floods;
     one "small" connection sends a few requests.  Assert the small
     connection's requests are each served within `O(active_flows)`
     dispatches — never stuck behind the whale's backlog.
  2. **Targeted backpressure:** whale saturates its `per_flow_cap`
     and receives `Busy`; the small connection still enqueues and is
     served.
  3. **Work-conserving:** with only the whale active (no
     contention), it is served at full worker rate — no artificial
     throttle.
  4. **No starvation bound:** with `K` active flows, every flow's
     head is served within `K` dispatches (assert the bound).
  5. **Stress / parity:** mirror RH-C.4's stress shape (many
     connections × many requests); no OOM; FIFO vs DRR both return
     correct verdicts; shutdown drains cleanly mid-load.

**Acceptance criteria.**

  * All five behaviours pass deterministically (seed any randomness).
  * Stress test green under `cargo test` and the `ci-rust.yml`
    gates.

**Risk.**  Medium.  Timing-based fairness assertions can be flaky;
prefer logical-order assertions (served-sequence) over wall-clock.

**Effort.**  ~1.5 engineer-days.

#### FQ.8 — Rung 0 documentation + closeout

**Scope.**  `runtime/knomosis-host/src/lib.rs` docstring,
`docs/abi.md` (note only), `CLAUDE.md` + `AGENTS.md`, `README.md`,
`runtime/Cargo.toml`, `lakefile.lean`.

**Implementation steps.**

  1. Update the lib.rs threading-model docstring: document the
     optional fair scheduler, its flags, and the §2.5 invariants.
  2. `docs/abi.md`: add a note that Rung 0 introduces **no**
     wire-format change (the scheduler is purely host-internal).
  3. Update the roadmap/status surfaces: add an FQ row to the
     `CLAUDE.md` / `AGENTS.md` implementation-roadmap table and a
     workstream snapshot; keep the two files byte-identical.
  4. Patch-version bump in lockstep per the repo release discipline:
     `runtime/Cargo.toml` `[workspace.package] version`,
     `lakefile.lean` `package knomosis version`, and the `README.md`
     version banner — all to the same new patch value; commit the
     regenerated `Cargo.lock`.

**Acceptance criteria.**

  * Docs reflect shipped behaviour; `CLAUDE.md` and `AGENTS.md`
    identical; version fields agree across all surfaces.
  * `ci-rust.yml` green.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

### Rung 0 — Rolled-up acceptance criteria

  * `--scheduler drr` yields per-connection fairness: a flooding
    connection delays only itself; honest connections keep their
    share and their enqueue capacity.
  * Work-conserving: no throttle absent contention.
  * No admissibility behaviour changes; FIFO remains the default and
    is unchanged.
  * All four §2.5 invariants hold; the DRR decision is a pure,
    unit-tested function.
  * Full `ci-rust.yml` gate (build/test/clippy -D warnings/fmt)
    green; version surfaces bumped in lockstep.

### Rung 0 — Closeout checklist

  * [ ] FQ.0 – FQ.8 merged, each its own commit.
  * [ ] `--scheduler` defaults to `fifo`; DRR opt-in.
  * [ ] Pure core (`src/fair/drr.rs`) has unit + property tests.
  * [ ] Integration suite (`tests/fair_queue.rs`) green.
  * [ ] lib.rs docstring + roadmap rows updated; CLAUDE.md ≡
        AGENTS.md; version lockstep.

### Rung 1 — signer-hint header + two-tier DRR (version-gated)

#### FQ.9 — Wire-format amendment + `docs/abi.md` §10

**Scope.**  `docs/abi.md` §10, `runtime/knomosis-host/src/lib.rs`
(`PROTOCOL_VERSION`).

**Implementation steps.**

  1. Define the optional per-frame signer-hint.  A Rung-1 client
     opens the connection by sending a 4-byte magic preamble
     (`b"KNH2"`); thereafter every request is `[8-byte signer-hint]
     [4-byte BE length][payload]`.  A legacy client sends no
     preamble and its first 4 bytes are the v1 length prefix.
  2. **Back-compatible disambiguation:** a valid v1 length is
     `<= max_frame_size` (≤ ~1 MiB ⇒ high bytes zero), whereas the
     `KNH2` magic's first byte is `0x4B` ⇒ a >1 GiB "length" that v1
     already rejects.  The host peeks the first 4 bytes: equal to the
     magic ⇒ Rung-1 hinted connection; otherwise ⇒ legacy
     (connection-keyed, Rung 0).
  3. Bump `PROTOCOL_VERSION` 1 → 2; document that v2 is a superset
     (v1 connections remain valid and get Rung-0 fairness).
  4. Specify that the hint is advisory: the kernel authoritatively
     reads the signer from the CBE body and verifies the signature;
     the hint never affects admissibility (restate §2.5).

**Acceptance criteria.**

  * `docs/abi.md` §10 unambiguously specifies the preamble, the
    per-frame layout, the disambiguation rule, and the
    advisory/untrusted status of the hint.
  * `PROTOCOL_VERSION == 2`; the version test updated.

**Risk.**  Medium.  The negotiation must be provably unambiguous
against legacy frames; the magic-vs-length argument (step 2) is the
crux and must be stated precisely in the ABI doc.

**Effort.**  ~1.0 engineer-day.

#### FQ.10 — Frame parser extension (read the hint)

**Scope.**  `runtime/knomosis-host/src/frame.rs`,
`src/listener.rs`.

**Implementation steps.**

  1. Per connection, perform the one-time magic peek (FQ.9 step 2)
     and record `hinted: bool` for that connection.
  2. For a hinted connection, read the bounded 8-byte hint before
     each length prefix; for a legacy connection, behave exactly as
     today.  Never read beyond the hint into the CBE body.
  3. Surface the hint (or a per-connection constant for legacy) to
     the submit call site as the inner routing key.

**Acceptance criteria.**

  * Hinted frames parse: hint extracted, payload bytes byte-identical
    to the non-hinted case.
  * Legacy frames parse unchanged; a malformed/truncated hint is
    rejected with `ParseError` before any allocation of the body.
  * Fuzz: random leading bytes never cause a panic; never mis-read
    the CBE body as a hint.

**Risk.**  Medium.  Off-by-one between the hint and the length
prefix; the fuzz test guards it.

**Effort.**  ~1.0 engineer-day.

#### FQ.11 — Two-tier pure core

**Scope.**  `runtime/knomosis-host/src/fair/drr.rs` (extend; reuse
the FQ.1 single-tier logic as the inner tier).

**Implementation steps.**

  1. Introduce `ConnBucket { signers: BTreeMap<SignerHint, Flow>,
     active: VecDeque<SignerHint>, deficit: u64, depth: usize }` and
     a two-tier `DrrState { conns: BTreeMap<ConnId, ConnBucket>,
     active: VecDeque<ConnId>, total_depth }`.
  2. `pick` runs DRR at the **outer** tier across connections; on a
     connection's turn it runs DRR at the **inner** tier across that
     connection's signer-hints (the FQ.1 logic, parameterised).
     Empty inner flow ⇒ evict signer; empty connection ⇒ evict conn.
  3. Express the single-tier core (FQ.1) as the inner-tier instance
     so there is one DRR implementation, not two.

**Acceptance criteria.**

  * Outer fairness: with two connections, each gets ~1/2 the worker
    regardless of how many signer-hints each multiplexes.
  * **Spoof-confinement property test:** a connection spawning `M`
    distinct (possibly forged) hints still receives only its single
    outer share, subdivided among its `M` — never more than a
    one-hint connection's share.  This is the §2.5(2) guarantee.
  * Inner fairness within a connection across its hints.
  * No `unsafe`; no `panic`; `clippy::pedantic` clean.

**Risk.**  Medium.  Nested activation/eviction; the spoof-confinement
property test is the key guard.

**Effort.**  ~1.5 engineer-days.

#### FQ.12 — `FairQueue` two-tier wiring + per-signer caps

**Scope.**  `runtime/knomosis-host/src/queue.rs`, `src/config.rs`.

**Implementation steps.**

  1. Extend `FairQueue::try_submit` to take `(conn, signer_hint,
     payload)` and route through the two-tier `DrrState`.
  2. Add a per-connection distinct-signer cap
     (`--max-signers-per-conn`, default 256) and a per-(conn,signer)
     buffer cap; both produce targeted `Busy`.  These bound the
     Rung-1 scheduler-DoS surface (§2.5(4)).
  3. Keep the Rung-0 call shape working: a legacy connection routes
     under a single implicit hint constant (so its requests form one
     inner flow ⇒ Rung-0 behaviour).

**Acceptance criteria.**

  * Two-tier routing works end-to-end with `MockKernel`.
  * `--max-signers-per-conn` enforced; breach is targeted `Busy` to
    the offending connection only.
  * Legacy (un-hinted) connection still behaves as Rung 0.

**Risk.**  Low–medium.

**Effort.**  ~1.0 engineer-day.

#### FQ.13 — Client emitters

**Scope.**  `runtime/knomosis-l1-ingest/src/submitter.rs`,
`runtime/knomosis-bench/`, `runtime/knomosis-faultproof-observer/
src/{submitter,jsonrpc_submitter}.rs` (whichever speak the
`knomosis-host` wire format).

**Implementation steps.**

  1. Add an opt-in "emit signer-hint" mode: send the `KNH2`
     preamble at connection open and prepend the 8-byte hint
     (the signer `ActorId` the client already knows) per frame.
  2. Default OFF (emit legacy v1 frames) so no client regresses; a
     flag/config turns it on.
  3. For `knomosis-bench`, hinting on makes the throughput harness
     exercise the two-tier path; keep a hinted-vs-legacy bench knob.

**Acceptance criteria.**

  * With hinting ON, frames carry the preamble + hint and the host
    routes per-signer; with hinting OFF, byte-identical to today.
  * Existing client tests pass; new tests cover the hinted path.

**Risk.**  Low–medium.  Touches multiple crates; partition edits per
the background-agent discipline (each crate is a disjoint file set).

**Effort.**  ~1.5 engineer-days.

#### FQ.14 — Rung 1 integration + spoof-resistance tests

**Scope.**  `runtime/knomosis-host/tests/fair_queue.rs` (extend),
new `tests/wire_compat.rs`.

**Implementation steps.**

  1. **Two-tier fairness:** one connection multiplexing many
     signer-hints does not starve a second connection.
  2. **Spoof-resistance (end-to-end):** connection C floods with
     hints spoofing victim V's id; the real V on connection C' sends
     one request and is served within the bounded outer cycle —
     unaffected by C's flood.
  3. **Back-compat:** a legacy (v1) client and a v2 client on
     separate connections both work; the legacy one gets Rung-0
     fairness.
  4. **Negotiation robustness:** assorted leading-byte sequences
     classify correctly (magic vs length) and never mis-parse.

**Acceptance criteria.**

  * All four behaviours pass deterministically.
  * `wire_compat.rs` proves v1 and v2 clients interoperate against
    the same host instance.

**Risk.**  Medium.  Spoof and negotiation tests are the proof that
§2.5(2)/(3) hold in practice.

**Effort.**  ~1.5 engineer-days.

#### FQ.15 — Rung 1 documentation + closeout

**Scope.**  `docs/abi.md` §10 (finalise), `src/lib.rs`,
`CLAUDE.md` + `AGENTS.md`, `README.md`, client `README`s,
`runtime/Cargo.toml`, `lakefile.lean`.

**Implementation steps.**

  1. Finalise `docs/abi.md` §10 with the shipped v2 layout +
     negotiation + invariants.
  2. Update lib.rs + roadmap rows + workstream snapshot (CLAUDE.md ≡
     AGENTS.md); note the client opt-in flags in their READMEs.
  3. Patch-version bump across all surfaces in lockstep (and the
     already-bumped `PROTOCOL_VERSION` from FQ.9); commit
     `Cargo.lock`.

**Acceptance criteria.**

  * ABI doc matches shipped behaviour; docs/versions consistent;
    `ci-rust.yml` green.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

### Rung 1 — Rolled-up acceptance criteria

  * Hinted (v2) connections get per-(connection, signer) fairness;
    legacy (v1) connections transparently get Rung-0 fairness on the
    same host.
  * Forged hints are confined to the forging connection's own outer
    share (§2.5(2)), proven by the spoof-resistance test.
  * No admissibility behaviour changes; the hint is advisory only.
  * `PROTOCOL_VERSION == 2`; v1/v2 interoperate; version surfaces
    bumped in lockstep.

### Rung 1 — Closeout checklist

  * [ ] FQ.9 – FQ.15 merged, each its own commit.
  * [ ] One DRR implementation reused at both tiers.
  * [ ] Spoof-confinement property test + end-to-end spoof test green.
  * [ ] v1/v2 wire interop test green; legacy clients unaffected.
  * [ ] abi.md §10 + roadmap updated; CLAUDE.md ≡ AGENTS.md; versions
        lockstepped; `PROTOCOL_VERSION == 2`.

## §5 Risks and mitigations

| # | Risk | Mitigation |
| - | ---- | ---------- |
| 1 | `Condvar` shutdown wake-up / drain ordering causes a hang or a lost in-flight reply | Explicit stop-flag + `notify_all` on shutdown; drain-until-`stop && empty`; kill-during-load test (FQ.4, FQ.7) |
| 2 | DRR activation/eviction bookkeeping bug starves or double-serves a flow | Pure core isolated in `src/fair/drr.rs` with unit + property tests, incl. the equal-weight fairness bound (FQ.1) |
| 3 | Wire negotiation mis-classifies a legacy frame as hinted (or vice-versa) | Magic-vs-length disambiguation proven against `max_frame_size`; `wire_compat.rs` interop test; fuzz (FQ.9, FQ.10, FQ.14) |
| 4 | Hint spoofing lets an actor steal another's share | Two-tier structure confines a forged hint to the forger's own outer share; spoof-confinement property test + end-to-end test (FQ.11, FQ.14); §2.5(2) |
| 5 | Scheduler maps grow unboundedly (flow-count DoS) | `max_flows`, per-conn distinct-signer cap, immediate empty-flow eviction (FQ.2, FQ.5, FQ.12); §2.5(4) |
| 6 | Flaky timing-based fairness assertions | Assert logical served-order / bounds, not wall-clock; seed all randomness (FQ.7, FQ.14) |
| 7 | Fairness is meaningless if all users funnel through one upstream sequencer connection | Documented topology note (§2.4); the same DRR module is reusable inside a sequencer; not a code risk, a deployment fact |
| 8 | A scheduling change is perceived as weakening the proof-carrying story | §2.1 framing: safety stays in the kernel; FQ is a liveness layer the kernel provably cannot supply; default-OFF flag keeps the baseline intact |

## §6 Explicitly out of scope / future work

  * **Budget-weighted quanta (FQ-W, future).**  Set a flow's
    `quantum` proportional to its prepaid GP budget so prepaid value
    buys priority-under-contention (Sybil-neutral, since weight
    tracks a conserved quantity).  Blocked on a host-side budget-read
    endpoint (the deferred `knomosis-host` getBalance/budget surface).
    The per-flow `quantum` field is already present (FQ.1).
  * **Accountable fairness (future).**  Commit per-actor served-counts
    to state; let a fault-proof observer replay the pure `pick`
    function against committed arrivals and challenge an unfair
    sequencer.  FQ keeps the decision pure (§2.6) precisely to enable
    this; the commitment + challenge path is a separate workstream.
  * **L1 forced inclusion.**  The wall-clock-liveness backstop against
    a censoring operator; a fault-proof-rollup feature alongside
    Workstream H.  Not a `knomosis-host` concern.
  * **Cost models beyond cost = 1.**  Per-action-kind or
    measured-dispatch-time cost, only if profiling shows per-request
    cost variance matters; would extend the Rung-1 header with a
    cheap kind byte rather than parse CBE.
  * **A persistent `knomosis serve` subprocess.**  Orthogonal RH-C
    closeout item; FQ is independent of it but benefits from it
    (lower per-dispatch cost makes the worker the clear bottleneck
    fairness targets).

## §7 Workstream acceptance criteria

FQ is Complete when:

  1. `--scheduler drr` delivers targeted, work-conserving fairness:
     a flooding actor delays only itself; honest actors keep their
     share; idle/underutilised load is unthrottled.
  2. Both rungs ship: Rung 0 (connection-keyed, no wire change) and
     Rung 1 (signer-hint, two-tier, `PROTOCOL_VERSION == 2`,
     v1/v2 interop).
  3. Every §2.5 invariant holds, evidenced by tests — especially
     "routing never affects admissibility" and "forged hints are
     self-confined".
  4. The DRR decision is a single, pure, unit + property-tested
     function reused at both tiers.
  5. FIFO remains the default and is behaviourally unchanged; the
     fair scheduler is fully reversible via the flag.
  6. `ci-rust.yml` (build / test / clippy `-D warnings` / fmt) is
     green; all version surfaces are bumped in lockstep across the
     landing PRs; `CLAUDE.md` and `AGENTS.md` stay byte-identical.

---

**Cross-references.**  Builds on
`docs/planning/rust_host_runtime_plan.md` §RH-C (the `knomosis-host`
adaptor).  Complements `docs/planning/unified_gas_pool_plan.md`
(Workstream GP — the kernel-side stock/safety bound).  Wire format:
`docs/abi.md` §10.  Code: `runtime/knomosis-host/src/{queue,server,
listener,frame,config,lib}.rs` and the new `src/fair/drr.rs`.
