<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Per-Actor Fair Queuing / Burst Resistance — Workstream Plan (Workstream FQ)

> **Superseded for implementation by
> [`GP.8_SEQUENCER_INTEGRATION_PLAN.md`](GP.8_SEQUENCER_INTEGRATION_PLAN.md).**
> Workstream FQ is the sequencer's inbound-liveness layer; its full body
> (Rung 0 + Rung 1, every `FQ.*` work unit) is reproduced, optimised, and
> kept current in that unified document as **Track A**.  Treat the unified
> plan as canonical wherever the two disagree on any sequencer-facing
> matter; this document is retained for amendment history and as the
> standalone FQ reference.  The `FQ.*` identifiers are unchanged, and FQ
> remains its own roadmap row.

**Document version:** v1.1 (revised from v1.0).

**Changes from v1.0** (correctness + granularity pass against the
actual `runtime/knomosis-host` source):

  * **Correctness — shutdown/concurrency model.**  The existing
    `worker_loop` already shuts down via a stop-flag + 100 ms poll +
    a non-blocking final drain, wrapped in a `catch_unwind` panic
    firewall with mutex-poison recovery (`src/server.rs`).  The
    `FairQueue` therefore needs **no** knowledge of the stop flag:
    `next()` returns only `Dispatch`/`Idle`, and the fair worker
    mirrors the proven FIFO loop exactly.  v1.0's `ShuttingDown`
    return is removed.  See §2.7.
  * **Correctness — caps belong in the pure core.**  Capacity
    enforcement is integer logic, so it moves into the unit-testable
    pure module (`enqueue` returns the request back on a cap breach);
    the concurrency wrapper only translates that to `Busy`.  This
    removes v1.0's awkward "caps enforced by the wrapper" coupling.
  * **Correctness — wire negotiation is now collision-proof.**  The
    Rung-1 magic-vs-length disambiguation only holds if no valid v1
    frame length can equal the magic; v1.1 adds an explicit hard
    frame-size ceiling strictly below the magic's u32 value (FQ.9).
  * **Correctness — `pick` is deterministic + I/O-free, not "pure".**
    It mutates scheduler state (`&mut self`); replay needs
    determinism, which it has, not referential purity.  Wording
    corrected throughout.
  * **Design seam.**  A `QueueHandle` enum unifies the FIFO and fair
    submit paths so `ConnId` threading is additive, not a hand-waved
    "ignored argument" (FQ.4a).
  * **Granularity.**  The complex WUs are broken into 2–3 sub-units
    of 4–6 h each (FQ.1→1a–c, FQ.2→2a–c, FQ.4→4a–b, FQ.7→7a–c,
    FQ.10→10a–b, FQ.11→11a–b, FQ.13→13a–c, FQ.14→14a–b), matching the
    GP plan's sub-WU convention.
  * **New WU.**  FQ.7c adds a throughput-parity / perf-regression
    check (the global `Mutex` scheduler must not regress against the
    near-lock-free `sync_channel`).

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
kernel.  See §2.1 for the safety-vs-liveness rationale.

**Prerequisite.**  RH-C (`knomosis-host`) is Complete.  FQ extends
it; it does not depend on any in-flight kernel work.

**Effort estimate.**  ~17.0 engineer-days total (Rung 0 ≈ 9.0d;
Rung 1 ≈ 8.0d), one engineer familiar with the existing
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
    * §2.7 Concurrency and shutdown model (mirrors the FIFO worker)
  * §3 Work-unit dependency graph
  * §4 Work-unit specifications
    * Rung 0 — connection-keyed DRR (no wire change):
      FQ.0, FQ.1a–c, FQ.2a–c, FQ.3, FQ.4a–b, FQ.5, FQ.6, FQ.7a–c, FQ.8
    * Rung 1 — signer-hint header + two-tier DRR:
      FQ.9, FQ.10a–b, FQ.11a–b, FQ.12, FQ.13a–c, FQ.14a–b, FQ.15
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
     request is served within one round-robin cycle, whose length is
     bounded by the configured maximum number of flows.
  4. **Preserve the kernel safety boundary.**  The scheduler must
     never influence admissibility.  A scheduling bug may reorder or
     drop, never admit an inadmissible action nor reject an
     admissible one for a reason the kernel would not.  (This is the
     existing `knomosis-host` security property #1; FQ must keep it.)
  5. **Reversible rollout.**  The fair scheduler ships behind a
     config flag, defaulting OFF (FIFO), so it is A/B-testable and
     instantly revertible.  Rung 0 introduces no wire-format change.
  6. **Designed-in extensibility.**  Keep the scheduling decision
     deterministic and I/O-free so the future "accountable fairness"
     work (committed served-counts + fault-proof challenge) can
     replay it, and keep a per-flow weight field so budget-weighted
     quanta can be added without a structural change.
  7. **No throughput regression.**  The fair path must not materially
     reduce single-actor throughput versus FIFO (FQ.7c).

### §1.2 Non-goals

  * **Budget-weighted quanta.**  FQ ships equal-weight (quantum = 1).
    Weighting a flow's quantum by its prepaid GP budget requires a
    host-side budget read (the deferred `knomosis-host` getBalance /
    budget endpoint noted in the RH-E.1 closeout).  Deferred — the
    per-flow weight field is reserved but populated equal.
  * **Accountable fairness.**  Committing per-actor served-counts to
    state and letting a fault-proof observer challenge an unfair
    sequencer is a separate, larger effort (it touches committed
    state).  FQ only keeps the door open by keeping the decision
    deterministic and I/O-free (§2.6, FQ.1b).
  * **Wall-clock liveness guarantees.**  FQ allocates the worker
    fairly; it cannot promise inclusion against a censoring operator.
    The backstop for that is L1 forced inclusion (out of scope here;
    a fault-proof-rollup feature alongside Workstream H).
  * **Parsing CBE for admissibility at the host.**  The host remains
    a byte-opaque forwarder.  FQ reads at most an explicit, untrusted
    routing hint (Rung 1) — never the CBE body.
  * **An async runtime.**  FQ stays within the crate's synchronous
    `std::thread` + `Mutex`/`Condvar` model (no `tokio`).
  * **Deciding the production topology.**  Whether end users connect
    to `knomosis-host` directly or through an upstream sequencer is a
    deployment decision (§2.4 explains FQ's behaviour under each).

### §1.3 Reading guide

  * **Implementer:** read §2.2–§2.7 for the design, then work §4 in
    dependency order (§3).  Each WU is self-contained: Scope,
    Implementation steps, Acceptance criteria, Risk, Effort.
  * **Reviewer:** the load-bearing invariants are §2.5; the
    concurrency contract is §2.7.  Confirm every WU preserves them
    (especially FQ.2a–c, FQ.4b, FQ.10a–b, FQ.12).
  * **Operator:** new CLI flags arrive in FQ.0 and FQ.5; the
    wire-format change is FQ.9 (`docs/abi.md` §10).

### §1.4 Glossary

  * **Flow** — the unit of fairness: the queued requests sharing one
    routing key.  Rung 0: one flow per connection.  Rung 1: one flow
    per (connection, signer-hint).
  * **Routing key** — the value the scheduler buckets a request by.
    A *classification* hint only; never trusted for admissibility.
  * **DRR (Deficit Round Robin)** — a work-conserving fair scheduler.
    Each flow has a `deficit` counter; on its turn it gains a
    `quantum` of credit and serves requests whose cost is covered.
  * **Quantum** — the per-turn credit a flow receives; proportional
    to weight.  Equal for all flows in FQ (= 1).
  * **Cost** — the credit a request consumes.  FQ uses cost = 1 (one
    dispatch slot on the serial worker).
  * **Work-conserving** — the worker idles only when *all* flows are
    empty; spare capacity always goes to whoever has demand.
  * **Head-of-line (HOL) blocking** — a backlogged flow at the front
    of a FIFO delaying everything behind it.  The defect FQ removes.
  * **ConnId** — a monotonic per-accepted-connection identifier
    assigned at `accept()`; transport-authenticated, unspoofable.
  * **Signer-hint** — an explicit, untrusted 8-byte routing hint a
    Rung-1 client prepends per frame to declare the action's signer.
    Misuse is a fairness-only concern (§2.5).
  * **`QueueHandle`** — the enum that unifies the FIFO `BoundedQueue`
    and the `FairQueue` behind one `submit(conn, payload)` call so
    the connection handler is scheduler-agnostic (FQ.4a).

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
    actor's lifetime cost; prevents sustained/infinite DoS.  Shipped.
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
listener,config,frame,lib}.rs`:

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
    carries opaque CBE bytes plus a one-shot reply channel.  The
    worker `drain_one`s FIFO, dispatches, and replies.
  * **The host never parses the CBE payload** (lib.rs security
    property #1: framing/queue bugs "can drop or reorder but cannot
    violate any admissibility witness").
  * `admission.rs` already defines `AdmissionStage::Sequenced` — the
    conceptual slot a fair scheduler fills.
  * Config is a hand-rolled parser over a `Config` struct with
    `usize` fields defaulted from `DEFAULT_*` constants and a
    `ConfigError` enum for validation (the pattern FQ.0/FQ.5 follow).

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
flow) and the *sequencer itself* is where fairness must live — but
the FQ scheduler module is reusable there unchanged.  If users
connect to `knomosis-host` more directly, Rung 0 is immediately
meaningful and Rung 1 sharpens it.  FQ delivers the mechanism; the
deployment chooses where the contention point is.

### §2.5 Trust and safety invariants

Every WU must preserve these; reviewers check them explicitly.

  1. **Classification-only routing.**  The routing key influences
     *order and drop*, never admissibility.  A wrong or forged key
     can only mis-route, and mis-route ⊆ "reorder", which the
     existing security property #1 already tolerates.  **Safety is
     untouched by any routing decision.**
  2. **Spoofing is a fairness-only risk.**  A Rung-1 client that lies
     about its signer-hint can only disturb scheduling.  The two-tier
     structure confines the damage: a connection that spawns many
     fake hints still receives only its *one* connection's outer
     share, subdivided among its fakes — self-harm, not theft.  The
     ConnId outer tier is unspoofable, so a victim on another
     connection is unaffected.
  3. **Legacy clients degrade safely.**  A client that sends no hint
     is treated as a single implicit flow within its connection —
     i.e. Rung-0 behaviour.  Rung 1 is strictly additive.
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
    budget-weighted quanta (a concrete, planned extension — §1.2)
    drop in without restructuring.
  * **Caps live in the pure core.**  Capacity checks are integer
    logic, so `enqueue` enforces them and returns the request back on
    a breach; the concurrency wrapper merely maps that to `Busy`.
    This keeps cap behaviour unit-testable without any I/O.
  * **Reset deficit to 0 when a flow empties** (and evict it).  No
    banking of credit across idle periods — a returning whale cannot
    accumulate a burst allowance while quiet, which is precisely the
    anti-burst goal.
  * **Work-conserving.**  The worker blocks only when *all* flows are
    empty; any pending request is served.
  * **Bounded wait.**  A flow's head waits at most `(active_flows -
    1)` dispatches — bounded because `active_flows ≤ max_flows`.
  * **Deterministic, I/O-free decision.**  `pick(&mut self)` mutates
    scheduler state but reads no clock and performs no I/O; given the
    same enqueue/pick sequence it is reproducible.  That determinism
    (not referential purity) is what future accountable-fairness
    replay needs, and it is the unit-test surface.
  * **`BTreeMap` for the flow maps.**  Deterministic iteration and no
    hash-DoS / random-seed surface; scheduling order is driven by the
    `active` deque, not map iteration, so the log-factor cost is
    irrelevant at these sizes.

### §2.7 Concurrency and shutdown model (mirrors the FIFO worker)

The fair path must reuse the *proven* shape of the existing
`worker_loop` (`src/server.rs`) rather than invent a new one:

  * **The worker owns stop-checking, not the queue.**  The FIFO loop
    is `loop { if stop { drain non-blocking until empty; break }
    match drain_one(100ms) { Dispatched|Timeout => continue;
    Disconnected => break } }`.  The fair worker is identical with
    `FairQueue::next(100ms)` (returns `Dispatch`/`Idle`) and
    `FairQueue::try_next()` (non-blocking) in place of
    `drain_one`/`try_drain_one`.  `FairQueue` needs **no** reference
    to the stop flag.
  * **Bounded shutdown latency.**  The 100 ms `wait_timeout` means
    the worker notices `stop` within 100 ms even if parked; an
    optional `not_empty.notify_all()` on shutdown makes it immediate.
    Correctness does not depend on the notify.
  * **Dispatch happens outside the lock.**  `next()` pops the request
    under the lock and returns it by value (the `MutexGuard` drops at
    return); the slow `kernel.submit` call then runs lock-free.  This
    is the key throughput property (§ FQ.7c).
  * **Panic firewall + poison recovery preserved.**  The fair worker
    keeps the `catch_unwinding_submit` wrapper, and `FairQueue`'s own
    `Mutex` uses the same `lock().unwrap_or_else(|p| p.into_inner())`
    poison-recovery the kernel locks use — no `unwrap` that can panic
    a producer or worker thread.

## §3 Work-unit dependency graph

```
Rung 0:
  FQ.0 (skeleton + --scheduler flag)
   ├─> FQ.1a (core: structs + enqueue + caps) ─> FQ.1b (pick) ─> FQ.1c (core tests)
   │        FQ.1a,1b ─> FQ.2a (FairQueue + try_submit) ─> FQ.2b (next/try_next) ─> FQ.2c (concurrency tests)
   ├─> FQ.3  (ConnId assignment)
   └─> FQ.5  (caps config)
        FQ.2b + FQ.3 ─> FQ.4a (QueueHandle + Server branch) ─> FQ.4b (fair_worker_loop + shutdown)
        FQ.4b ─> FQ.6 (observability)
        FQ.4b ─> FQ.7a (fairness tests) ─> FQ.7b (stress/shutdown/parity) ─> FQ.7c (perf parity)
        FQ.7c ─> FQ.8 (docs + closeout)

Rung 1 (begins after FQ.8 lands):
  FQ.9 (wire amendment + abi.md + frame ceiling)
   ├─> FQ.10a (conn negotiation) ─> FQ.10b (per-frame hint read)
   ├─> FQ.11a (tier-parameterised core) ─> FQ.11b (two-tier pick + spoof test)   [FQ.11a needs FQ.1b]
   │        FQ.11b + FQ.2b ─> FQ.12 (FairQueue two-tier + per-signer caps)
   └─> FQ.13a (l1-ingest) ‖ FQ.13b (observer) ‖ FQ.13c (bench)                    [parallel; disjoint crates]
        FQ.12 + FQ.10b + FQ.13* ─> FQ.14a (fairness + spoof e2e) ─> FQ.14b (wire interop) ─> FQ.15 (docs + closeout)
```

**Critical path:** FQ.0 → FQ.1a → FQ.1b → FQ.2a → FQ.2b → FQ.4a →
FQ.4b → FQ.7a → FQ.7b → FQ.7c → FQ.8 → FQ.9 → FQ.11a → FQ.11b →
FQ.12 → FQ.14a → FQ.14b → FQ.15.  FQ.3 and FQ.5 parallelise with the
FQ.1/FQ.2 chain; FQ.13a–c parallelise with FQ.10–FQ.12.

**Parallelism + file-ownership (per CLAUDE.md background-agent
discipline).**  FQ.1a–c live in the new `src/fair/drr.rs` and are
disjoint from FQ.3 (`src/listener.rs` + `src/server.rs`) — safe to
work concurrently.  FQ.2a–c (`src/queue.rs`) and FQ.4a–b
(`src/server.rs`) both touch `server.rs`/`queue.rs`; serialise them.
FQ.13a/b/c each own a different downstream crate
(`knomosis-l1-ingest`, `knomosis-faultproof-observer`,
`knomosis-bench`) — fully parallelisable, one owner per crate.

**Effort roll-up.**  Rung 0: FQ.0 0.5 + FQ.1a 0.5 + FQ.1b 0.5 +
FQ.1c 0.5 + FQ.2a 0.5 + FQ.2b 0.5 + FQ.2c 0.5 + FQ.3 1.0 + FQ.4a 0.5
+ FQ.4b 0.5 + FQ.5 0.5 + FQ.6 0.5 + FQ.7a 0.75 + FQ.7b 0.75 + FQ.7c
0.5 + FQ.8 0.5 = **9.0d**.  Rung 1: FQ.9 1.0 + FQ.10a 0.5 + FQ.10b
0.5 + FQ.11a 0.75 + FQ.11b 0.75 + FQ.12 1.0 + FQ.13a 0.5 + FQ.13b 0.5
+ FQ.13c 0.5 + FQ.14a 0.75 + FQ.14b 0.75 + FQ.15 0.5 = **8.0d**.
Total **17.0 engineer-days**.

## §4 Work-unit specifications

### Rung 0 — connection-keyed DRR (no wire change)

#### FQ.0 — Workstream skeleton + scheduler selector

**Scope.**  `runtime/knomosis-host/src/config.rs`, `src/lib.rs`,
new module dir `src/fair/` (empty `mod.rs`).

**Implementation steps.**

  1. Add a `Scheduler` enum (`Fifo`, `Drr`) with `FromStr` +
     `Display`; default `Fifo`.
  2. Add `--scheduler {fifo|drr}` to the hand-rolled parser + a
     `scheduler: Scheduler` field on `Config`; add the row to the
     flag table in the module docstring; add a `ConfigError` variant
     for an invalid value.
  3. `pub mod fair;` in `lib.rs` with an empty `src/fair/mod.rs`
     (re-export point for FQ.1/FQ.2).
  4. No behavioural change yet: `Server::run` still builds the FIFO
     `BoundedQueue` regardless of the parsed value.

**Acceptance criteria.**

  * `--scheduler drr|fifo` parse; invalid value → clear
    `ConfigError`; default is `Fifo`.
  * `cargo build/test/clippy -D warnings/fmt` clean; existing tests
    pass unmodified (no behaviour change).

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

#### FQ.1a — Pure DRR core: data structures + `enqueue` + caps

**Scope.**  New `runtime/knomosis-host/src/fair/drr.rs` (pure; no
`std::sync`, no sockets, no clock).

**Implementation steps.**

  1. Types, generic over the routing `Key` (instantiated to `ConnId`
     in Rung 0): `Flow { deque: VecDeque<QueuedRequest>, deficit:
     u64, quantum: u64 }`; `Caps { per_flow: usize, max_flows:
     usize, global: usize }`; `DrrState { flows: BTreeMap<Key, Flow>,
     active: VecDeque<Key>, total_depth: usize, caps: Caps }`.
  2. `enqueue(&mut self, key, req) -> Result<(), QueuedRequest>`:
     enforce, atomically under the caller's lock, `global`,
     `max_flows` (only when the key is new), then `per_flow`;
     on any breach return `Err(req)` (the request flows back so the
     wrapper can answer `Busy` — nothing is silently dropped).  On
     success push to the flow; on an empty→non-empty transition push
     the key to `active`; bump `total_depth`.
  3. Single map lookup via the `entry` API (no check-then-insert
     TOCTOU).

**Acceptance criteria.**

  * Unit tests: `per_flow`, `max_flows`, `global` each independently
    return `Err`; the returned request is the one passed in;
    activation bookkeeping correct; `total_depth` exact.
  * `clippy::pedantic` clean; no `unsafe`; no `panic!` on any input.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### FQ.1b — Pure DRR core: the `pick` step

**Scope.**  `runtime/knomosis-host/src/fair/drr.rs` (continues
FQ.1a).

**Implementation steps.**

  1. `pick(&mut self) -> Option<QueuedRequest>`: if `active` empty
     return `None`; else peek its front key, top up `deficit +=
     quantum` once on entry to the flow's turn; if `cost (=1) <=
     deficit`, pop head, `deficit -= 1`, `total_depth -= 1`; if the
     flow is now empty **remove it from `active` and from `flows`,
     discarding its deficit**, else rotate the key to the back of
     `active`; return the popped request.
  2. Keep every branch deterministic and clock-free (the
     accountable-fairness seam, §2.6).
  3. Expose a read-only `len()/is_empty()/active_len()` for the
     wrapper's `Condvar` predicate and for FQ.6 stats.

**Acceptance criteria.**

  * Unit tests: round-robin order across N flows; one heavy flow
    does not starve a light flow (light flow's head served within N
    `pick`s); empty-flow eviction + deficit reset; `pick` on empty →
    `None`.
  * Property test: across arbitrary enqueue/pick interleavings, no
    active flow is served more than one request ahead of the
    least-served active flow (equal-weight fairness bound).

**Risk.**  Low–medium.  The activation/eviction bookkeeping is the
classic DRR fiddly part; the property test guards it.

**Effort.**  ~0.5 engineer-day.

#### FQ.1c — Pure DRR core: test hardening

**Scope.**  `runtime/knomosis-host/src/fair/drr.rs` (`#[cfg(test)]`).

**Implementation steps.**

  1. Determinism test: two identical enqueue/pick scripts yield
     identical served sequences (the replay guarantee).
  2. Fuzz/randomised soak (seeded): thousands of random
     enqueue/pick ops; assert no panic, `total_depth` invariant
     holds, `active` contains exactly the non-empty flows, evicted
     flows are absent from `flows`.
  3. Boundary cases: `per_flow = 1`; `max_flows = 1`; `global = 0`
     (everything `Busy`); single-flow saturation.

**Acceptance criteria.**

  * All tests deterministic (seed any randomness) and green under
    `ci-rust.yml`.
  * Coverage spans every `enqueue`/`pick` branch.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### FQ.2a — `FairQueue`: struct + `try_submit`

**Scope.**  `runtime/knomosis-host/src/queue.rs` (add alongside the
existing `BoundedQueue`; do not remove it).

**Implementation steps.**

  1. `FairQueue { inner: Arc<Mutex<DrrState<ConnId>>>, not_empty:
     Arc<Condvar> }`, `Clone` (shares the `Arc`s) to match
     `BoundedQueue`'s producer-handle ergonomics; the `Caps` live in
     the `DrrState` (FQ.1a).
  2. `try_submit(&self, conn: ConnId, payload: Vec<u8>) ->
     SubmitOutcome`: build the capacity-1 reply channel (as today);
     lock (poison-recovering: `unwrap_or_else(|p| p.into_inner())`);
     construct the `QueuedRequest`; call `state.enqueue(conn, req)`;
     on `Ok(())` `notify_one()` and return `Enqueued(reply_rx)`; on
     `Err(_req)` drop the request and return `Busy`.
  3. Reuse the existing `SubmitOutcome` enum; the reply mechanism and
     `QueuedRequest` are unchanged.

**Acceptance criteria.**

  * Per-flow cap: one flow saturating its cap gets `Busy`; a second
    flow still enqueues (targeted backpressure) — asserted via the
    `MockKernel`-free queue API directly.
  * `global`/`max_flows` breaches each return `Busy`.
  * Lock-poison path covered (a poisoned lock still serves).

**Risk.**  Low–medium.

**Effort.**  ~0.5 engineer-day.

#### FQ.2b — `FairQueue`: blocking `next` + non-blocking `try_next`

**Scope.**  `runtime/knomosis-host/src/queue.rs`.

**Implementation steps.**

  1. `next(&self, timeout: Duration) -> NextOutcome` where
     `NextOutcome { Dispatch(QueuedRequest), Idle }`: lock; if
     `active` empty, `not_empty.wait_timeout(guard, timeout)`; after
     waking, `pick()` — `Some(req)` → return `Dispatch(req)` (guard
     drops at return, so dispatch is lock-free), `None` → `Idle`.
     **No knowledge of any stop flag** (§2.7).
  2. `try_next(&self) -> Option<QueuedRequest>`: lock; `pick()`;
     return — the non-blocking analog of `try_drain_one`, used by the
     shutdown drain.
  3. Use the `Condvar` predicate-loop idiom to tolerate spurious
     wakeups; cap the wait at `timeout` so the worker re-checks
     `stop` every ~100 ms.

**Acceptance criteria.**

  * `next` blocks when empty and returns `Dispatch` promptly after a
    concurrent `try_submit` + `notify`; returns `Idle` within
    ~`timeout` when no work.
  * `try_next` returns immediately (`Some`/`None`), never blocks.
  * The dispatched request is returned by value with the lock
    already released (assert no lock held during a slow dispatch via
    a contention test).

**Risk.**  Medium.  `Condvar` wait/notify + spurious-wakeup handling.

**Effort.**  ~0.5 engineer-day.

#### FQ.2c — `FairQueue`: concurrency tests

**Scope.**  `runtime/knomosis-host/src/queue.rs` (`#[cfg(test)]`).

**Implementation steps.**

  1. Multi-producer / single-consumer: N producer threads
     `try_submit` across M conns; one consumer drains via `next`;
     assert every non-`Busy` request is dispatched exactly once and
     replies arrive.
  2. Targeted backpressure under concurrency: a saturating flow sees
     `Busy` while another flow makes progress concurrently.
  3. Wake/timeout: consumer parked on `next` wakes on a late
     `try_submit`; `next` returns `Idle` on an idle interval.
  4. Shutdown-drain shape: after producers stop, `try_next` empties
     the queue and then returns `None`.

**Acceptance criteria.**

  * Deterministic (bounded retries, seeded); green under
    `ci-rust.yml`; `queue_is_clone_send_sync`-style trait assertions
    extended to `FairQueue`.

**Risk.**  Medium (concurrency-test flakiness).  Prefer logical
assertions (exactly-once, served-set) over timing.

**Effort.**  ~0.5 engineer-day.

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
  3. The handler carries `conn_id` to its submit call (consumed by
     the `QueueHandle` in FQ.4a); ConnIds are never reused
     (monotonic), so an evicted flow cannot alias a later connection.

**Acceptance criteria.**

  * Distinct concurrent connections receive distinct, monotonic
    `ConnId`s across all three listeners.
  * Existing listener tests pass (the id is additive).

**Risk.**  Low.

**Effort.**  ~1.0 engineer-day.

#### FQ.4a — `QueueHandle` seam + `Server::run` branch

**Scope.**  `runtime/knomosis-host/src/queue.rs`, `src/server.rs`.

**Implementation steps.**

  1. Introduce `enum QueueHandle { Fifo(BoundedQueue),
     Fair(FairQueue) }` with `fn submit(&self, conn: ConnId, payload:
     Vec<u8>) -> SubmitOutcome`; the `Fifo` arm ignores `conn` and
     calls `BoundedQueue::try_submit(payload)`; the `Fair` arm calls
     `FairQueue::try_submit(conn, payload)`.  `Clone`.
  2. Connection handlers hold a `QueueHandle` and call
     `handle.submit(conn_id, payload)` — scheduler-agnostic, so the
     listener code is identical on both paths.
  3. `Server::run` branches on `config.scheduler`: `Fifo` builds the
     `BoundedQueue` + its `receiver`; `Drr` builds the `FairQueue`.
     Wrap the chosen producer side in a `QueueHandle` for the
     listeners.

**Acceptance criteria.**

  * `--scheduler fifo` is byte-for-byte the old path (same queue,
    same `worker_loop`); existing server/integration tests pass.
  * `--scheduler drr` constructs the `FairQueue`-backed handle.

**Risk.**  Low–medium (touches the `Server::run` wiring).

**Effort.**  ~0.5 engineer-day.

#### FQ.4b — `fair_worker_loop` + shutdown protocol

**Scope.**  `runtime/knomosis-host/src/server.rs`.

**Implementation steps.**

  1. `fair_worker_loop(queue: FairQueue, kernel, stop)` mirroring
     `worker_loop` exactly (§2.7): `loop { if stop { while let
     Some(req) = queue.try_next() { dispatch+reply }; break } match
     queue.next(100ms) { Dispatch(req) => dispatch+reply; Idle =>
     continue } }`.
  2. `dispatch+reply` reuses `catch_unwinding_submit(&*kernel,
     &req.payload)` then `req.reply.try_send(response)` — identical
     to the FIFO body.
  3. `Server::run` spawns `fair_worker_loop` on the `Drr` path; on
     shutdown it sets `stop`, waits for handlers to drain
     (`wait_for_handlers_drain`), then optionally
     `queue.not_empty.notify_all()` for prompt wake; the worker's
     `stop`-branch drains the remainder and exits; `worker.join()`
     as today.

**Acceptance criteria.**

  * End-to-end on `Drr`: connect, submit, receive verdict (parity
    with FIFO for a single actor).
  * Graceful shutdown under load: queued requests drain, worker
    joins, no `Condvar` hang, no lost in-flight replies; kill-during-
    load test passes.
  * Kernel-panic firewall still works on the fair path (debug build).

**Risk.**  Medium.  Shutdown wake/drain ordering is the most
error-prone part; test kill-during-load explicitly.

**Effort.**  ~0.5 engineer-day.

#### FQ.5 — Caps configuration + validation

**Scope.**  `runtime/knomosis-host/src/config.rs`.

**Implementation steps.**

  1. Add flags + `Config` fields with `DEFAULT_*` constants:
     `--per-flow-cap <n>` (default 64), `--max-flows <n>` (default
     4096); reuse `--max-queue-depth` as the DRR `global` cap.  Add
     the rows to the flag-table docstring (note: "ignored unless
     `--scheduler drr`").
  2. Validate via `ConfigError`: `per_flow_cap >= 1`; `per_flow_cap
     <= max_queue_depth`; `max_flows >= 1`; clamp `max_flows` and
     `max_queue_depth` to hard ceilings (mirror
     `HARD_MAX_QUEUE_DEPTH`) so worst-case memory (`global *
     max_frame_size`) is bounded.
  3. Plumb the three values into the `Caps` the `FairQueue` is built
     with (FQ.4a).

**Acceptance criteria.**

  * Defaults present; out-of-range rejected or clamped per spec;
    help text states FIFO ignores them; parse tests per new flag.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

#### FQ.6 — Observability

**Scope.**  `runtime/knomosis-host/src/queue.rs` (+ `tracing` call
sites).

**Implementation steps.**

  1. Counters: per-flow `Busy` rejections, `global`/`max_flows`
     rejections, active-flow gauge, total dispatches.
  2. Emit via the crate's existing `tracing` at `debug`/`info`; no
     new dependency.  Aggregate — never per-request `info` spam.
  3. `FairQueue::stats()` snapshot (reads the FQ.1b read-only
     accessors under the lock) for tests and a future status
     endpoint.

**Acceptance criteria.**

  * Under a synthetic flood the per-flow `Busy` counter and
    active-flow gauge move as expected; no log flooding at `info`.
  * `stats()` is consistent under concurrent load.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### FQ.7a — Behavioural fairness tests

**Scope.**  New `runtime/knomosis-host/tests/fair_queue.rs` (uses
`MockKernel`).

**Implementation steps.**

  1. **Fairness under contention:** one "whale" connection floods;
     one "small" connection sends a few requests.  Assert each small
     request is served within `O(active_flows)` dispatches — never
     stuck behind the whale's backlog.  Assert on served-*order*, not
     wall-clock.
  2. **Targeted backpressure:** the whale saturates `per_flow_cap`
     and receives `Busy`; the small connection still enqueues and is
     served.
  3. **Work-conserving:** with only the whale active (no
     contention), it is served at full worker rate — no artificial
     throttle.
  4. **No-starvation bound:** with `K` active flows, every flow's
     head is served within `K` dispatches (assert the bound).

**Acceptance criteria.**

  * All four behaviours pass deterministically (seed randomness).

**Risk.**  Medium (timing flakiness).  Mitigate via logical-order
assertions over a controlled `MockKernel` dispatch cadence.

**Effort.**  ~0.75 engineer-day.

#### FQ.7b — Stress, shutdown-under-load, FIFO parity

**Scope.**  `runtime/knomosis-host/tests/fair_queue.rs`.

**Implementation steps.**

  1. **Stress:** mirror RH-C.4's shape (many connections × many
     requests) on the `Drr` path; no OOM; correct verdicts.
  2. **Shutdown under load:** set `stop` mid-flood; assert clean
     drain, worker join, no lost in-flight replies, no hang.
  3. **FIFO parity:** the same workload on `--scheduler fifo` and
     `--scheduler drr` returns the same multiset of verdicts (FQ only
     reorders, never changes admissibility — §2.5(1)).

**Acceptance criteria.**

  * Stress green under `cargo test` + `ci-rust.yml`; shutdown test
    has no flaky hang; parity holds.

**Risk.**  Medium.

**Effort.**  ~0.75 engineer-day.

#### FQ.7c — Throughput-parity / perf-regression check

**Scope.**  `runtime/knomosis-host/` (a `criterion`-free microbench
or a `--scheduler`-parameterised reuse of `knomosis-bench`'s driver;
no new heavy dependency).

**Implementation steps.**

  1. Single-actor (one connection) throughput: `fifo` vs `drr`.
     Since there is no contention, DRR's only overhead is the
     `Mutex`/`Condvar` versus the `sync_channel`.  Assert `drr`
     throughput is within a documented tolerance of `fifo` (target:
     ≥ 90 %).
  2. Confirm the §2.7 "dispatch outside the lock" property holds
     under load (a slow `MockKernel` must not serialise enqueues).
  3. Record numbers in the FQ.8 closeout note (like the RH-F
     observed-throughput disclosure), not as a hard CI gate
     (microbench numbers are machine-dependent).

**Acceptance criteria.**

  * `drr` single-actor throughput ≥ 90 % of `fifo` on the dev
    workstation; if below, the gap is root-caused (lock contention
    on the hot path) before FQ.8.

**Risk.**  Medium.  A global `Mutex` can throttle the producer side;
this WU exists to catch exactly that before it ships.

**Effort.**  ~0.5 engineer-day.

#### FQ.8 — Rung 0 documentation + closeout

**Scope.**  `src/lib.rs` docstring, `docs/abi.md` (note only),
`CLAUDE.md` + `AGENTS.md`, `README.md`, `runtime/Cargo.toml`,
`lakefile.lean`.

**Implementation steps.**

  1. Update the lib.rs threading-model docstring: the optional fair
     scheduler, its flags, the §2.5 invariants, the §2.7 model.
  2. `docs/abi.md`: note that Rung 0 introduces **no** wire-format
     change (host-internal only).
  3. Roadmap/status: add an FQ row + a workstream snapshot to
     `CLAUDE.md` / `AGENTS.md` (keep them byte-identical); record the
     FQ.7c throughput numbers in the snapshot.
  4. Patch-version bump in lockstep: `runtime/Cargo.toml`
     `[workspace.package] version`, `lakefile.lean` `package
     knomosis version`, `README.md` banner — same new patch value;
     commit the regenerated `Cargo.lock`.

**Acceptance criteria.**

  * Docs match shipped behaviour; `CLAUDE.md` ≡ `AGENTS.md`; versions
    agree across surfaces; `ci-rust.yml` green.

**Risk.**  Trivial.

**Effort.**  ~0.5 engineer-day.

### Rung 0 — Rolled-up acceptance criteria

  * `--scheduler drr` yields per-connection fairness: a flooding
    connection delays only itself; honest connections keep their
    share and enqueue capacity.
  * Work-conserving: no throttle absent contention; single-actor
    throughput within 90 % of FIFO (FQ.7c).
  * No admissibility behaviour changes; FIFO remains the unchanged
    default; verdict-multiset parity holds (FQ.7b).
  * All four §2.5 invariants and the §2.7 concurrency contract hold;
    the DRR decision is deterministic, I/O-free, and unit + property
    tested.
  * Full `ci-rust.yml` gate green; version surfaces lockstepped.

### Rung 0 — Closeout checklist

  * [ ] FQ.0, FQ.1a–c, FQ.2a–c, FQ.3, FQ.4a–b, FQ.5, FQ.6, FQ.7a–c,
        FQ.8 merged, each its own commit.
  * [ ] `--scheduler` defaults to `fifo`; DRR opt-in.
  * [ ] Pure core (`src/fair/drr.rs`) has unit + property + fuzz
        tests; caps enforced and tested in the core.
  * [ ] Integration suite (`tests/fair_queue.rs`) green incl.
        shutdown-under-load + FIFO parity.
  * [ ] FQ.7c throughput numbers recorded; ≥ 90 % parity or
        root-caused.
  * [ ] lib.rs docstring + roadmap rows updated; CLAUDE.md ≡
        AGENTS.md; version lockstep.

### Rung 1 — signer-hint header + two-tier DRR (version-gated)

#### FQ.9 — Wire-format amendment + `docs/abi.md` §10 + frame ceiling

**Scope.**  `docs/abi.md` §10, `runtime/knomosis-host/src/lib.rs`
(`PROTOCOL_VERSION`), `src/frame.rs` (the hard ceiling constant).

**Implementation steps.**

  1. Define the optional per-frame signer-hint.  A Rung-1 client
     opens the connection with a 4-byte magic preamble (`b"KNH2"`);
     thereafter every request is `[8-byte signer-hint][4-byte BE
     length][payload]`.  A legacy client sends no preamble; its first
     4 bytes are the v1 length prefix.
  2. **Collision-proof disambiguation (the crux).**  The host peeks
     the first 4 bytes of a connection: equal to the magic ⇒ Rung-1
     hinted connection; otherwise ⇒ legacy.  This is sound **iff** no
     valid v1 length can equal the magic's big-endian u32 value.
     `b"KNH2"` = `0x4B4E4832` ≈ 1.26 GiB.  v1.1 therefore pins a
     compile-time **`HARD_MAX_FRAME_SIZE` strictly below the magic
     value** (e.g. 256 MiB) and rejects/clamps `--max-frame-size`
     above it, so a legal v1 length can never collide with the
     magic.  State this invariant explicitly in `abi.md`.
  3. Bump `PROTOCOL_VERSION` 1 → 2; document that v2 is a superset
     (v1 connections remain valid and get Rung-0 fairness).
  4. Specify the hint is **advisory**: the kernel authoritatively
     reads the real signer from the CBE body and verifies the
     signature; the hint never affects admissibility (restate
     §2.5(1)/(2)).

**Acceptance criteria.**

  * `docs/abi.md` §10 unambiguously specifies the preamble, the
    per-frame layout, the disambiguation rule, the
    `HARD_MAX_FRAME_SIZE < magic` invariant, and the
    advisory/untrusted status of the hint.
  * `PROTOCOL_VERSION == 2`; the version test updated; the ceiling
    constant has a unit test asserting `HARD_MAX_FRAME_SIZE < magic`.

**Risk.**  Medium.  The collision argument is the load-bearing
correctness claim; it must be pinned by the ceiling constant + test,
not left implicit.

**Effort.**  ~1.0 engineer-day.

#### FQ.10a — Connection negotiation state machine

**Scope.**  `runtime/knomosis-host/src/listener.rs`,
`src/frame.rs`.

**Implementation steps.**

  1. Per accepted connection, perform the one-time 4-byte magic peek
     (FQ.9 step 2) and record a `hinted: bool` on the connection's
     read state.
  2. If the 4 bytes equal the magic, consume them and set
     `hinted = true`.  Otherwise set `hinted = false` and treat those
     4 bytes as the first frame's length prefix (do not lose them —
     feed them into the v1 read path).
  3. A connection's `hinted` decision is fixed for its lifetime (no
     mid-connection renegotiation).

**Acceptance criteria.**

  * A v2 connection is detected; a v1 connection's first frame is
    read intact (no dropped/duplicated bytes).
  * Assorted leading-byte sequences classify correctly; values
    `>= HARD_MAX_FRAME_SIZE` that are not the magic are rejected as
    over-length (unchanged v1 behaviour).

**Risk.**  Medium.  Off-by-one between the peeked magic and the v1
length path.

**Effort.**  ~0.5 engineer-day.

#### FQ.10b — Per-frame hint extraction

**Scope.**  `runtime/knomosis-host/src/frame.rs`,
`src/listener.rs`.

**Implementation steps.**

  1. On a `hinted` connection, read the bounded 8-byte hint before
     each length prefix; never read beyond it into the CBE body.
  2. Surface the hint (or, for a legacy connection, a per-connection
     constant) to the submit call site as the inner routing key.
  3. A malformed/truncated hint is a `ParseError` before any body
     allocation.

**Acceptance criteria.**

  * Hinted frames: hint extracted; payload bytes byte-identical to
    the non-hinted case.
  * Fuzz: random leading bytes never panic and never mis-read the
    CBE body as a hint.

**Risk.**  Medium.

**Effort.**  ~0.5 engineer-day.

#### FQ.11a — Tier-parameterised core + `ConnBucket`

**Scope.**  `runtime/knomosis-host/src/fair/drr.rs` (generalise
FQ.1a/1b; one DRR implementation, not two).

**Implementation steps.**

  1. Refactor the FQ.1 single-tier logic into a reusable inner-tier
     `Tier<K>` (the `flows`/`active`/`enqueue`/`pick`/eviction logic),
     so both tiers share one implementation.
  2. `ConnBucket = Tier<SignerHint>` plus an outer `deficit`/`depth`;
     the two-tier `DrrState` is `Tier<ConnId>` whose per-key payload
     is a `ConnBucket`.
  3. `enqueue(conn, signer, req)` routes through the outer tier to
     the connection's inner tier; outer `max_flows` bounds distinct
     connections, a new per-connection `max_signers` (FQ.12) bounds
     inner flows; empty inner ⇒ evict signer; empty connection ⇒
     evict conn.

**Acceptance criteria.**

  * The single-tier tests (FQ.1b/1c) still pass against the extracted
    `Tier<K>` (proving the refactor is behaviour-preserving).
  * Two-tier `enqueue` accounting + eviction correct at both tiers.

**Risk.**  Medium.  The refactor must not regress the single-tier
behaviour; run FQ.1's suite against `Tier<K>` unchanged.

**Effort.**  ~0.75 engineer-day.

#### FQ.11b — Two-tier `pick` + spoof-confinement property

**Scope.**  `runtime/knomosis-host/src/fair/drr.rs`.

**Implementation steps.**

  1. `pick` runs DRR at the **outer** tier across connections; on a
     connection's turn it runs the inner `Tier<SignerHint>::pick` for
     one served request, then rotates connections.  Empty inner ⇒
     evict signer; empty conn ⇒ evict conn.
  2. **Spoof-confinement property test (the §2.5(2) guarantee):** a
     connection spawning `M` distinct (possibly forged) hints
     receives only its single outer share, subdivided among its `M` —
     never more than a one-hint connection's share.
  3. Inner-fairness test: within one connection, its signer-hints are
     served round-robin.

**Acceptance criteria.**

  * Outer fairness: two connections each get ~1/2 the worker
    regardless of how many hints each multiplexes.
  * Spoof-confinement property holds across randomised interleavings.
  * No `unsafe`; no `panic`; `clippy::pedantic` clean.

**Risk.**  Medium.  Nested activation/eviction; the spoof-confinement
property test is the key guard.

**Effort.**  ~0.75 engineer-day.

#### FQ.12 — `FairQueue` two-tier wiring + per-signer caps

**Scope.**  `runtime/knomosis-host/src/queue.rs`, `src/config.rs`.

**Implementation steps.**

  1. Extend `FairQueue::try_submit` to `(conn, signer_hint, payload)`
     routing through the two-tier `DrrState`; extend `QueueHandle`'s
     `Fair` arm + the handler call site accordingly (legacy
     connections pass a constant hint ⇒ one inner flow ⇒ Rung-0
     behaviour).
  2. Add `--max-signers-per-conn` (default 256) + `Config` field +
     `ConfigError` validation; plumb into the outer tier's
     per-connection `max_signers`.  Breach ⇒ targeted `Busy` to the
     offending connection only (bounds the Rung-1 scheduler-DoS
     surface, §2.5(4)).

**Acceptance criteria.**

  * Two-tier routing works end-to-end with `MockKernel`.
  * `--max-signers-per-conn` enforced; breach is targeted `Busy`.
  * A legacy (un-hinted) connection still behaves exactly as Rung 0.

**Risk.**  Low–medium.

**Effort.**  ~1.0 engineer-day.

#### FQ.13a — Client emitter: `knomosis-l1-ingest`

**Scope.**  `runtime/knomosis-l1-ingest/src/submitter.rs`.

**Implementation steps.**

  1. Add an opt-in "emit signer-hint" mode (config/flag, default
     OFF): on connection open send the `KNH2` preamble; per frame
     prepend the 8-byte hint (the signer `ActorId` the submitter
     already holds).
  2. Default OFF emits legacy v1 frames byte-identically (no
     regression).

**Acceptance criteria.**

  * Hinting ON: frames carry preamble + hint; OFF: byte-identical to
    today.  New tests cover the hinted path; existing tests pass.

**Risk.**  Low–medium.

**Effort.**  ~0.5 engineer-day.

#### FQ.13b — Client emitter: `knomosis-faultproof-observer`

**Scope.**  `runtime/knomosis-faultproof-observer/src/{submitter,
jsonrpc_submitter}.rs` (whichever speak the `knomosis-host` wire
format; the L1 JSON-RPC submitter is unaffected).

**Implementation steps.**

  1. Same opt-in hint emission as FQ.13a for any path that submits to
     `knomosis-host`.
  2. Default OFF; legacy behaviour preserved.

**Acceptance criteria.**

  * Hinted/legacy parity as FQ.13a; observer tests pass.

**Risk.**  Low–medium.

**Effort.**  ~0.5 engineer-day.

#### FQ.13c — Client emitter: `knomosis-bench`

**Scope.**  `runtime/knomosis-bench/`.

**Implementation steps.**

  1. Add a `--emit-hints` knob so the throughput harness exercises
     the two-tier path; default OFF.
  2. Lets FQ.14/FQ.7c measure hinted vs legacy throughput.

**Acceptance criteria.**

  * Hinted mode drives per-signer routing; bench numbers comparable
    across modes; existing bench tests pass.

**Risk.**  Low.

**Effort.**  ~0.5 engineer-day.

#### FQ.14a — Rung 1 fairness + spoof-resistance (end-to-end)

**Scope.**  `runtime/knomosis-host/tests/fair_queue.rs` (extend).

**Implementation steps.**

  1. **Two-tier fairness:** one connection multiplexing many
     signer-hints does not starve a second connection.
  2. **Spoof-resistance (end-to-end):** connection C floods with
     hints spoofing victim V's id; the real V on connection C' sends
     one request and is served within the bounded outer cycle —
     unaffected by C's flood.  (The end-to-end counterpart to FQ.11b's
     unit property.)

**Acceptance criteria.**

  * Both behaviours pass deterministically against `MockKernel`.

**Risk.**  Medium.

**Effort.**  ~0.75 engineer-day.

#### FQ.14b — Wire back-compat / negotiation interop

**Scope.**  new `runtime/knomosis-host/tests/wire_compat.rs`.

**Implementation steps.**

  1. **Back-compat:** a legacy (v1) client and a v2 client on
     separate connections both work against one host; the legacy one
     gets Rung-0 fairness.
  2. **Negotiation robustness:** assorted leading-byte sequences
     classify correctly (magic vs length); a non-magic value
     `>= HARD_MAX_FRAME_SIZE` is rejected as over-length; the
     `HARD_MAX_FRAME_SIZE < magic` invariant is asserted.
  3. **Mixed load:** v1 and v2 connections concurrently; verdicts
     correct for both.

**Acceptance criteria.**

  * v1/v2 interop proven against the same host instance; negotiation
    never mis-parses; green under `ci-rust.yml`.

**Risk.**  Medium.  This suite is the evidence that §2.5(3) + the
FQ.9 collision argument hold in practice.

**Effort.**  ~0.75 engineer-day.

#### FQ.15 — Rung 1 documentation + closeout

**Scope.**  `docs/abi.md` §10 (finalise), `src/lib.rs`, `CLAUDE.md`
+ `AGENTS.md`, `README.md`, client `README`s, `runtime/Cargo.toml`,
`lakefile.lean`.

**Implementation steps.**

  1. Finalise `docs/abi.md` §10 with the shipped v2 layout +
     negotiation + the `HARD_MAX_FRAME_SIZE` invariant + advisory
     semantics.
  2. Update lib.rs + roadmap rows + workstream snapshot (CLAUDE.md ≡
     AGENTS.md); document the client opt-in flags in their READMEs.
  3. Patch-version bump across all surfaces in lockstep (the
     `PROTOCOL_VERSION` bump already landed in FQ.9); commit
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
    share (§2.5(2)), proven by FQ.11b (unit) + FQ.14a (end-to-end).
  * No admissibility behaviour changes; the hint is advisory only.
  * `PROTOCOL_VERSION == 2`; v1/v2 interoperate; the
    `HARD_MAX_FRAME_SIZE < magic` collision invariant is pinned by a
    test; version surfaces bumped in lockstep.

### Rung 1 — Closeout checklist

  * [ ] FQ.9, FQ.10a–b, FQ.11a–b, FQ.12, FQ.13a–c, FQ.14a–b, FQ.15
        merged, each its own commit.
  * [ ] One DRR implementation (`Tier<K>`) reused at both tiers; the
        single-tier suite runs green against it.
  * [ ] Spoof-confinement property test (FQ.11b) + end-to-end spoof
        test (FQ.14a) green.
  * [ ] v1/v2 wire interop (FQ.14b) green; legacy clients unaffected.
  * [ ] abi.md §10 + roadmap updated; CLAUDE.md ≡ AGENTS.md; versions
        lockstepped; `PROTOCOL_VERSION == 2`.

## §5 Risks and mitigations

| # | Risk | Mitigation |
| - | ---- | ---------- |
| 1 | `Condvar` shutdown wake/drain causes a hang or a lost in-flight reply | Mirror the proven FIFO `worker_loop` exactly: stop-flag + 100 ms poll + non-blocking final drain; optional `notify_all`; kill-during-load test (§2.7, FQ.4b, FQ.7b) |
| 2 | DRR activation/eviction bug starves or double-serves a flow | Pure core isolated in `src/fair/drr.rs` with unit + property + fuzz tests, incl. the equal-weight fairness bound (FQ.1b/1c) |
| 3 | The global scheduler `Mutex` regresses throughput vs the near-lock-free `sync_channel` | Dispatch happens outside the lock (§2.7); FQ.7c measures single-actor `drr` vs `fifo` and gates on ≥ 90 % parity or a root-cause |
| 4 | Wire negotiation mis-classifies a legacy frame as hinted (or vice-versa) | `HARD_MAX_FRAME_SIZE < magic` invariant pinned by a constant + test; per-connection state machine (FQ.10a); fuzz + interop suite (FQ.14b) |
| 5 | Hint spoofing lets an actor steal another's share | Two-tier structure confines a forged hint to the forger's own outer share; property test (FQ.11b) + end-to-end test (FQ.14a); §2.5(2) |
| 6 | Scheduler maps grow unboundedly (flow-count DoS) | `max_flows`, per-conn `max_signers`, immediate empty-flow eviction (FQ.1a, FQ.5, FQ.12); §2.5(4) |
| 7 | Flaky timing-based fairness assertions | Assert logical served-order / exactly-once / bounds, not wall-clock; seed all randomness (FQ.1c, FQ.7a, FQ.14a) |
| 8 | Two-tier refactor regresses the single-tier behaviour | FQ.11a runs FQ.1's unchanged suite against the extracted `Tier<K>` |
| 9 | Fairness is meaningless if all users funnel through one upstream sequencer connection | Documented topology note (§2.4); the DRR module is reusable inside a sequencer; a deployment fact, not a code defect |
| 10 | A scheduling change is perceived as weakening the proof-carrying story | §2.1 framing: safety stays in the kernel; FQ is a liveness layer the kernel provably cannot supply; default-OFF flag keeps the baseline intact |

## §6 Explicitly out of scope / future work

  * **Budget-weighted quanta (FQ-W, future).**  Set a flow's
    `quantum` proportional to its prepaid GP budget so prepaid value
    buys priority-under-contention (Sybil-neutral, since weight
    tracks a conserved quantity).  Blocked on a host-side
    budget-read endpoint (the deferred `knomosis-host`
    getBalance/budget surface).  The per-flow `quantum` field already
    exists (FQ.1a).
  * **Accountable fairness (future).**  Commit per-actor
    served-counts to state; let a fault-proof observer replay the
    deterministic `pick` decision against committed arrivals and
    challenge an unfair sequencer.  FQ keeps the decision
    deterministic + I/O-free (§2.6) precisely to enable this.
  * **L1 forced inclusion.**  The wall-clock-liveness backstop
    against a censoring operator; a fault-proof-rollup feature
    alongside Workstream H.  Not a `knomosis-host` concern.
  * **Cost models beyond cost = 1.**  Per-action-kind, frame-size, or
    measured-dispatch-time cost — only if profiling shows per-request
    cost variance matters; would extend the Rung-1 header with a
    cheap kind byte rather than parse CBE.
  * **A persistent `knomosis serve` subprocess.**  Orthogonal RH-C
    closeout item; FQ is independent of it but benefits (a cheaper
    per-dispatch cost makes the worker the clear bottleneck fairness
    targets).

## §7 Workstream acceptance criteria

FQ is Complete when:

  1. `--scheduler drr` delivers targeted, work-conserving fairness:
     a flooding actor delays only itself; honest actors keep their
     share; idle/underutilised load is unthrottled; single-actor
     throughput stays within 90 % of FIFO.
  2. Both rungs ship: Rung 0 (connection-keyed, no wire change) and
     Rung 1 (signer-hint, two-tier, `PROTOCOL_VERSION == 2`, v1/v2
     interop with the collision-proof negotiation).
  3. Every §2.5 invariant and the §2.7 concurrency contract hold,
     evidenced by tests — especially "routing never affects
     admissibility" (verdict-multiset parity) and "forged hints are
     self-confined".
  4. The DRR decision is a single, deterministic, I/O-free,
     unit + property + fuzz-tested `Tier<K>` reused at both tiers.
  5. FIFO remains the default and is behaviourally unchanged; the
     fair scheduler is fully reversible via the flag.
  6. `ci-rust.yml` (build / test / clippy `-D warnings` / fmt) green;
     all version surfaces bumped in lockstep across the landing PRs;
     `CLAUDE.md` and `AGENTS.md` stay byte-identical.

---

**Cross-references.**  Builds on
`docs/planning/rust_host_runtime_plan.md` §RH-C (the `knomosis-host`
adaptor).  Complements `docs/planning/unified_gas_pool_plan.md`
(Workstream GP — the kernel-side stock/safety bound).  Wire format:
`docs/abi.md` §10.  Code: `runtime/knomosis-host/src/{queue,server,
listener,frame,config,lib}.rs` and the new `src/fair/drr.rs`.
