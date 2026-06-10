<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# Sequencer Integration — Unified Workstream Plan (Workstream GP.8)

**Document version:** v1.0 (initial unification).

This document is the single, complete implementation plan for the
**Knomosis sequencer**.  It unifies two previously-separate planning
documents that each described one facet of the same component:

  * `docs/planning/fair_queuing_plan.md` (Workstream **FQ**, v1.1) —
    the sequencer's *inbound liveness* layer: per-actor fair queuing
    inside `knomosis-host` so one actor's burst cannot delay others.
  * `docs/planning/unified_gas_pool_plan.md` **§GP.8** (within
    Workstream GP, v1.5) — the sequencer's *outbound economic* layer
    (reimbursement claim), its *configuration* (free-tier / epoch
    policy), and its *operations* (the operator runbook).

**Supersession.**  Where this document disagrees with either source on
any sequencer-facing matter, **this document wins**; the two sources
should be updated to cross-reference it (FQ's body is reproduced and
optimised here in full; GP.8's four WUs are reproduced, corrected
against the shipped code, and extended).  This document does **not**
restate the non-sequencer parts of Workstream GP (the kernel budget
substrate, the L1 fee-split contract, the AMM, etc.); those remain
owned by `unified_gas_pool_plan.md`.

**Identifier policy.**  The established work-unit identifiers are
preserved so existing roadmap rows and cross-references keep resolving:
the fair-queuing WUs keep their `FQ.*` names (Track A), and the
economic / config / operations WUs keep their `GP.8.*` names (Tracks
B–D).  New sub-units introduced by this unification are numbered within
those namespaces (e.g. `GP.8.1a`, `GP.8.5`).  Workstream FQ remains its
own roadmap row; "GP.8" is the umbrella under which the complete
sequencer surface is now specified.

## Status

**Track A — Rung 0 (FQ.0 – FQ.8): Complete.**  The connection-keyed DRR
fair scheduler ships in `knomosis-host` behind the default-OFF
`--scheduler drr` flag, with no wire-format change (`PROTOCOL_VERSION`
stays 1).  Delivered: the pure DRR core (`src/fair/drr.rs`), the
`FairQueue` concurrency wrapper + `QueueHandle` seam (`src/queue.rs`),
the `ConnId` assignment + scheduler-branched `Server::run` /
`fair_worker_loop` (`src/server.rs`, `src/listener.rs`), the
`--scheduler` / `--per-flow-cap` / `--max-flows` config gate
(`src/config.rs`), and the unit + property + behavioural + stress +
shutdown + FIFO-parity + throughput suites.  All four §2.6 invariants
and the §2.8 concurrency contract hold; FIFO remains the unchanged
default.  See the workstream snapshot in `CLAUDE.md`.

**Track A — Rung 1 (FQ.9 – FQ.15): Complete.**  The signer-hint wire
amendment + two-tier DRR ship behind the same default-OFF `--scheduler
drr` flag, with `PROTOCOL_VERSION` bumped 1 → 2 for the additive,
opt-in wire superset.  Delivered: the `KNH2`-preamble negotiation +
per-frame hint readers + the canonical `encode_hinted_frame` client
primitive + the compile-time `HARD_MAX_FRAME_SIZE < KNH2_MAGIC`
collision invariant (`src/frame.rs`, FQ.9 / FQ.10a / FQ.10b); the DRR
core refactored into ONE generic `Tier<K, S>` reused at both tiers
(`Tier<ConnId, ConnBucket>` outer, `Tier<SignerHint, RequestFifo>`
inner — the single-tier FQ.1 suite runs green against the extracted
`Tier`), with the two-tier `pick` + spoof-confinement property test
(`src/fair/drr.rs`, FQ.11a / FQ.11b); the `(conn, signer)` routing
threaded through `FairQueue::try_submit` / `QueueHandle::submit` /
`handle_connection` + the `--max-signers-per-conn` cap (`src/queue.rs`,
`src/listener.rs`, `src/config.rs`, FQ.12); the client emitters
(`knomosis-bench --emit-hints`, FQ.13c, AND the FQ.13a
`knomosis-l1-ingest` raw-TCP submitter — `RawTcpSubmitter` + the opt-in
`--emit-signer-hints` / `--knomosis-host-tcp` daemon flags, the first
real l1-ingest → knomosis-host forwarder, byte-pinned against the
canonical `encode_hinted_frame` + driven end-to-end against a live host);
and the two-tier-fairness + spoof-resistance (queue-level) + v1/v2
wire-interop (`tests/fair_queue.rs`, `tests/wire_compat.rs`, FQ.14a /
FQ.14b) suites.  Every §2.6 invariant — including "forged hints are
self-confined" (invariant 2) and "legacy clients degrade safely"
(invariant 3) — holds, evidenced by tests.  FQ.13b is N/A as a literal
client edit: the `knomosis-faultproof-observer` submitters speak L1
JSON-RPC (game-move calldata), never a `SignedAction` to the host, so
there is nothing to hint; the reusable `encode_hinted_frame` primitive
remains the ready drop-in if it ever forwards to the host.  See the
workstream snapshot in `CLAUDE.md`.

**Track A — Rung 1 post-review hardening: Complete.**  Two gaps surfaced
by PR review of the Rung-1 landing are closed.  (1) *Per-connection
aggregate backlog cap.*  The two-tier split would otherwise let one
hint-rotating connection buffer `max_signers × per_flow` requests —
relaxing the Rung-0 per-connection bound (one `per_flow`, the
connection's single leaf) and letting a single connection crowd the
global queue.  A fourth DRR cap `--max-conn-backlog <N>` bounds a
connection's aggregate backlog across ALL its hints, checked AFTER the
leaf `per_flow` cap (so a single-leaf flood is still attributed to
`per_flow`) and BEFORE a new hint is admitted; it **defaults to
`--per-flow-cap`**, restoring the Rung-0 per-connection bound out of the
box (spoofed hints stay self-confined), and an operator RAISES it for a
legitimately-multiplexing connection (`src/fair/drr.rs`,
`src/config.rs`, `src/server.rs`; new `RejectReason::ConnBacklog` +
`DrrStats::rejected_conn_backlog`).  (2) *Benchmark wire-mode in
reports.*  `BenchmarkReport` gains an `emit_hints` field
(`#[serde(default)]` so a pre-Rung-1 baseline loads as the legacy v1
mode it was measured under), and `compare_against_baseline` returns a new
`RegressionVerdict::NotComparable` — mapped by the CLI to an
operator-action exit — when the candidate and baseline wire modes differ,
so a hinted-vs-legacy comparison can no longer silently hide or
misattribute a regression (`knomosis-bench/src/report.rs`,
`src/main.rs`).

**Track A — Persistent + pipelined connection mode: Complete.**  This
closes the §2.5 topology gap — the load-bearing one, surfaced by a
self-audit: under the one-shot connection lifecycle every connection holds
at most one in-flight request, so two-tier DRR and FIFO coincide
*end-to-end* and the fairness mechanism, though correct, never bit over
the wire.  The opt-in `--persistent-connections` flag (default off, like
`--scheduler drr`) wires a persistent, **pipelined** TCP / Unix connection
mode: a connection may send many frames back-to-back, and the host replies
one verdict per request in submission order (the §10.1 response frame is
unchanged).  This is the only condition under which a single flow holds
multiple simultaneously-queued requests — the prerequisite for DRR to
diverge from FIFO.  What ships:
  * **`ConnReader`'s persistent path is now wired** (`src/listener.rs`,
    `run_persistent`): the reader negotiates once, then loops
    `ConnReader::read_next` (previously this state machine was built +
    tested but unused by the one-shot server).  A dedicated writer thread
    delivers responses in submission order; the reader→writer hand-off is
    a BOUNDED `sync_channel` sized to the queue's per-connection in-flight
    capacity (`QueueHandle::pipeline_capacity` — `--max-conn-backlog` on
    DRR, `--max-queue-depth` on FIFO), so a client that pipelines frames
    but never reads its responses back-pressures the reader (OS recv-buffer
    + TCP flow control bound memory) instead of growing the channel without
    bound — an OOM DoS an unbounded channel would have allowed.  TLS stays
    one-shot (the rustls session is single-owner); a one-shot client is a
    degenerate subset and works unchanged.
  * **Fair scheduling under contention is exercised through the wire**
    (`tests/persistent.rs`): a deterministic, gated-kernel integration
    test stages a flood + honest contention over REAL TCP and asserts that
    under `--scheduler drr --persistent-connections` the honest
    connection's requests are interleaved into the first few dispatches
    (≤ ~half the flood precedes its last request), while the FIFO contrast
    test proves the flood buries the honest connection without DRR — so
    the property is real, not vacuous.  Graceful shutdown with an open
    persistent connection is covered too.
  * **A shipping client drives it** (`knomosis-bench --persistent`): each
    worker reuses one connection and pipelines requests in batches,
    measuring the actual fair-scheduling throughput path; the standalone
    host enables `--persistent-connections` automatically.  The benchmark
    report records the persistent dimension alongside `emit_hints`, and
    `compare_against_baseline` refuses to compare across either mode
    dimension (`RegressionVerdict::NotComparable`).

**Remaining: Tracks B–D.  Planned.  Not started.**  Every prerequisite
is met:

  * **RH-C (`knomosis-host`) — Complete.**  Track A (FQ) extends it.
  * **GP.6.2 (`knomosis-host` budget admission gate) — Complete.**
    Track C's free-tier / epoch flags already ship here (see §6); this
    plan corrects the original GP.8.2 against that shipped reality.
  * **GP.7.1 / GP.7.2 / GP.7.4 (`gasPoolActor` reservation, the
    `gasPoolPolicy` + `gasPoolAuthorityPolicy` governance, and the
    genesis ratification) — Complete (Lean side).**  Track B's claim is
    a `gasPoolActor → sequencerActor` transfer admitted under exactly
    that governance.
  * **Workstream H + RH-G (state-root submission + off-chain fault-proof
    observer) — Complete.**  The sequencer's state-root duties and the
    `TurnSide::Sequencer` adversary model live there; Track B only adds
    the *reimbursement* for the L1 gas those duties cost.

**Effort estimate.**  ~21.0 engineer-days total:

  * **Track A — Fair sequencing (FQ):** ~17.0 d (Rung 0 ≈ 9.0 d;
    Rung 1 ≈ 8.0 d).
  * **Track B — Reimbursement claims:** ~1.0 d (GP.8.1a–c ≈ 8 h;
    GP.8.5 v2 path is deferred / out of scope for v1).
  * **Track C — Configuration:** ~0.5 d (GP.8.2, mostly guidance now
    that the flags ship).
  * **Track D — Operations:** ~2.5 d (GP.8.3 ≈ 6 h; GP.8.4 ≈ 14 h).

Track A dominates and is independently shippable; Tracks B–D are small
and can land in any order after their stated dependencies.

## Table of contents

  * §1 What "sequencer integration" means
    * §1.1 The sequencer in the Knomosis architecture
    * §1.2 The four facets (liveness, economics, configuration, ops)
    * §1.3 Goals and non-goals
    * §1.4 Reading guide
    * §1.5 Glossary
  * §2 Architectural background
    * §2.1 The layering: safety vs liveness vs economics
    * §2.2 The sequencer lifecycle (ingest → admit → commit → claim)
    * §2.3 The current `knomosis-host` queue + the shipped budget gate
    * §2.4 Why FIFO is unfair at both ends
    * §2.5 The routing-key problem and the rung ladder
    * §2.6 Trust and safety invariants
    * §2.7 The DRR core
    * §2.8 Concurrency and shutdown model
    * §2.9 The reimbursement-claim mechanism (v1 honour-system → v2)
  * §3 Unified work-unit dependency graph
  * §4 Track A — Fair sequencing (Workstream FQ)
    * Rung 0 — connection-keyed DRR (no wire change)
    * Rung 1 — signer-hint header + two-tier DRR
  * §5 Track B — Reimbursement claims
  * §6 Track C — Configuration (free-tier / epoch policy)
  * §7 Track D — Operations (operator runbook)
  * §8 Risks and mitigations
  * §9 Explicitly out of scope / future work
  * §10 Workstream acceptance criteria
  * §11 Closeout checklists
  * Cross-references

## §1 What "sequencer integration" means

### §1.1 The sequencer in the Knomosis architecture

The **sequencer** is the L2 operator process that turns a stream of
user-submitted `SignedAction`s into a totalled, replayable log and a
sequence of L1 state-root commitments.  Three reserved actors anchor
it (`LegalKernel/Bridge/BridgeActor.lean`):

| Actor            | `ActorId` | Role in the sequencer story                                                                 |
| ---------------- | --------- | ------------------------------------------------------------------------------------------- |
| `bridgeActor`    | 0         | Signs `depositWithFee` / `registerIdentity` / `replaceKey` in response to L1 events.        |
| `gasPoolActor`   | 1         | Holds the deposit fee-split skim + top-up revenue; may emit only a capped `transfer` to `sequencerActor`. |
| `sequencerActor` | 2         | The deployment's sequencer key: receives the pool drain, and submits L2 state roots to L1.  |

The sequencer is the **single serial point** through which every
admitted action flows: the kernel holds mutable log state that requires
sequential access, so `knomosis-host` dispatches actions one at a time
through one worker (§2.3).  That serial worker is simultaneously:

  * the **contended resource** an unfair actor can monopolise — the
    subject of Track A (fair queuing); and
  * the producer of the log whose state roots the sequencer must pay L1
    gas to commit — the cost reimbursed by Track B (the claim).

Everything in this document is about bounding and operating that one
serial point: bounding what an actor can take *from* it (liveness), what
the sequencer can take *out of the pool* for running it (economics),
how it is *configured*, and how it is *operated*.

### §1.2 The four facets

A complete sequencer needs four things, each historically described in
a different place; this document is where they meet.

  1. **Inbound liveness (Track A — Workstream FQ).**  Under contention
     for the serial worker, no actor may occupy more than its fair
     share; a flooding actor delays only itself, and a productive burst
     on an idle host is throttled by nothing.  A work-conserving
     **Deficit Round Robin (DRR)** scheduler in `knomosis-host`,
     shipped behind a default-OFF flag, with a two-rung routing-key
     ladder (connection-keyed, then signer-hint-keyed).

  2. **Outbound economics (Track B — GP.8.1 / GP.8.5).**  The sequencer
     spends real ETH on L1 gas to submit state roots; it reimburses
     itself by draining the gas pool.  The drain is a
     `gasPoolActor → sequencerActor` `transfer`, admitted under the
     GP.7.2 `gasPoolPolicy` + `gasPoolAuthorityPolicy` (only that one
     transfer, only to `sequencerActor`, only the pool's own funds,
     capped per leg).  v1 is honour-system within the cap; v2 (deferred)
     makes the claim cryptographically L1-receipt-verified.

  3. **Configuration (Track C — GP.8.2).**  The free-tier / per-epoch
     budget policy that governs admission.  These flags **already ship**
     on `knomosis-host` from GP.6.2 (`--budget-policy` / `--free-tier`
     / `--action-cost` / `--current-epoch` / `--epoch-length`); Track C
     is now mostly the *operational guidance* for choosing their values,
     plus the explicit decision to keep the deterministic **action-clock**
     epoch model rather than a replay-breaking wall-clock one (§6).

  4. **Operations (Track D — GP.8.3 / GP.8.4).**  The operator runbook:
     deployment checklist, calibration, health checks, failure-mode
     response, and — new to the unification — a **fair-queuing
     operations** section covering Track A's flags and the Rung-1 wire
     negotiation.  This extends the existing `docs/gas_pool_runbook.md`
     (already covering GP.5.5 BOLD safety), not a new file.

**Why one document.**  The facets are not independent.  The two bounds
on the sequencer are duals: Track A bounds what an actor can take *from*
the worker (liveness), and Track B + GP.7 bound what the sequencer can
take *from the pool* (economics) — together they fence the sequencer on
both sides.  The configuration (Track C) is the very budget state that a
future budget-weighted scheduler (§9, FQ-W) would read.  And the
operations (Track D) must cover both the scheduler flags and the claim
procedure for an operator to run the component at all.  Splitting them
across two plans left seams — most visibly FQ's unresolved "where does
fairness live if everyone funnels through one sequencer connection?"
(its §2.4 topology note), which Track B answers outright: the sequencer
*is* that connection, and the DRR module is exactly what it runs there.

### §1.3 Goals and non-goals

**Goals.**

  1. **Targeted burst resistance (Track A).**  Under contention, a
     flooding actor delays only itself; honest actors keep their share
     and their enqueue capacity.
  2. **Work-conserving (Track A).**  Absent contention, any actor may
     use the full worker; fair shares bind only when demand exceeds
     capacity.
  3. **Bounded wait / no starvation (Track A).**  Every active flow's
     head is served within one round-robin cycle, bounded by the
     configured maximum number of flows.
  4. **Bounded, governed reimbursement (Track B).**  The sequencer can
     reimburse itself for L1 gas, but only via the GP.7.2-governed
     capped transfer to `sequencerActor`; the per-action cap and the
     GP.7.3 per-trace drain bound fence the worst case.
  5. **Preserve the kernel safety boundary (all tracks).**  Nothing here
     may influence admissibility.  A scheduling bug may reorder or drop,
     never admit an inadmissible action nor reject an admissible one for
     a reason the kernel would not; a claim is an ordinary signed action
     subject to the ordinary admission gate.
  6. **Reversible, additive rollout.**  The fair scheduler ships behind a
     default-OFF flag (FIFO stays the baseline); Rung 0 adds no wire
     change; the claim is opt-in tooling around an action the kernel
     already admits.
  7. **Designed-in extensibility.**  Keep the scheduling decision
     deterministic and I/O-free (so future accountable-fairness can
     replay it) and keep a per-flow weight field (so budget-weighted
     quanta drop in once the trust question of §9 is settled).
  8. **No throughput regression (Track A).**  The fair path must not
     materially reduce single-actor throughput versus FIFO (FQ.7c).

**Non-goals.**

  * **Budget-weighted quanta now.**  FQ ships equal-weight (quantum = 1).
    GP.6.2 makes the budget *data* available host-side, but sound
    weighting still needs a *trusted* per-actor identity at scheduling
    time, which the byte-opaque host lacks pre-admission (§9, FQ-W).
  * **Accountable fairness.**  Committing per-actor served-counts to
    state for fault-proof challenge is a separate, larger effort; this
    plan only keeps the door open by keeping `pick` deterministic and
    I/O-free.
  * **Wall-clock liveness / forced inclusion.**  Fair allocation of the
    worker cannot promise inclusion against a censoring operator; the
    backstop is L1 forced inclusion (a fault-proof-rollup feature
    alongside Workstream H), out of scope here.
  * **Cryptographic claim verification in v1.**  GP.8.1 is honour-system
    within `capAmount`; the v2 L1-receipt verifier (GP.8.5) is specified
    but deferred.
  * **Wall-clock budget epochs.**  The shipped epoch model is
    action-indexed for replay determinism; a seconds-based epoch is an
    explicit non-goal (§6.3).
  * **Parsing CBE for admissibility at the host.**  The host stays a
    byte-opaque forwarder; it reads at most an explicit, untrusted
    routing hint (Rung 1), never the CBE body.
  * **An async runtime.**  Everything stays within the crate's
    synchronous `std::thread` + `Mutex`/`Condvar` model (no `tokio`).
  * **Deciding the production topology.**  Whether users reach
    `knomosis-host` directly or through an upstream sequencer is a
    deployment choice (§2.5 covers both); this plan delivers mechanism.

### §1.4 Reading guide

  * **Implementer (Track A):** read §2.3–§2.8 for the design, then work
    §4 in dependency order (§3).  Each WU is self-contained.
  * **Implementer (Tracks B–D):** read §2.2 + §2.9 for the claim model,
    then §5–§7.  Track B depends on the GP.7 governance being in place.
  * **Reviewer:** the load-bearing invariants are §2.6; the concurrency
    contract is §2.8; the claim's safety argument is §2.9.  Confirm every
    Track-A WU preserves §2.6 (especially FQ.2a–c, FQ.4b, FQ.10a–b,
    FQ.12) and that Track B never widens the GP.7.2 governance.
  * **Operator:** Track-A flags arrive in FQ.0 and FQ.5; the wire change
    is FQ.9 (`docs/abi.md` §10); the claim procedure and all
    configuration guidance live in §6–§7 and `docs/gas_pool_runbook.md`.

### §1.5 Glossary

  * **Flow** — the unit of fairness: the queued requests sharing one
    routing key.  Rung 0: one flow per connection.  Rung 1: one flow per
    (connection, signer-hint).
  * **Routing key** — the value the scheduler buckets a request by.  A
    *classification* hint only; never trusted for admissibility.
  * **DRR (Deficit Round Robin)** — a work-conserving fair scheduler.
    Each flow has a `deficit` counter; on its turn it gains a `quantum`
    of credit and serves requests whose cost is covered.
  * **Quantum / Cost** — the per-turn credit a flow receives / the credit
    a request consumes.  FQ uses quantum = cost = 1, so DRR collapses to
    strict per-actor round-robin.
  * **Work-conserving** — the worker idles only when *all* flows are
    empty; spare capacity always goes to whoever has demand.
  * **Head-of-line (HOL) blocking** — a backlogged flow at the front of a
    FIFO delaying everything behind it.  The defect Track A removes.
  * **ConnId** — a monotonic per-accepted-connection identifier assigned
    at `accept()`; transport-authenticated, unspoofable.
  * **Signer-hint** — an explicit, untrusted 8-byte routing hint a
    Rung-1 client prepends per frame to declare the action's signer.
    Misuse is a fairness-only concern (§2.6).
  * **`QueueHandle`** — the enum unifying the FIFO `BoundedQueue` and the
    `FairQueue` behind one `submit(conn, payload)` call so the connection
    handler is scheduler-agnostic (FQ.4a).
  * **Sequencer claim** — the `gasPoolActor → sequencerActor` `transfer`
    by which the sequencer reimburses itself for L1 gas (Track B).
  * **`gasPoolPolicy` / `gasPoolAuthorityPolicy`** — the GP.7.2
    `LocalPolicy` + `AuthorityPolicy` pair governing `gasPoolActor`
    outflow (only a capped `transfer` to `sequencerActor`, only the
    pool's own funds, no meta-actions).  Track B's claim is admitted by
    exactly this pair.
  * **Action-clock epoch** — the shipped budget epoch model:
    `epoch = logIndex / epochLength`, a deterministic function of the
    admitted-action count, so deterministic replay reproduces every
    epoch (§6).
  * **Honour-system claim (v1) / receipt-verified claim (v2)** — the two
    rungs of Track B: v1 trusts the operator to claim only what it spent
    (bounded by the cap); v2 proves it with an L1 gas receipt (§2.9).

## §2 Architectural background

### §2.1 The layering: safety vs liveness vs economics

Everything the Lean kernel proves is a **safety** property
(determinism, refinement, no-silent-illegality, conservation,
replay-impossibility): violated by a finite trace, established by
invariants.  The sequencer adds two properties the kernel provably
*cannot* express, plus the controls to operate them:

  * **Liveness (Track A).**  "Honest actors keep getting served while a
    whale floods" is established by scheduling and fairness assumptions,
    not by state invariants.  The kernel has no notion of contention or
    ordering and produces no schedule, so burst-fairness cannot be a
    kernel theorem.  This is a classification fact, not an engineering
    gap — it lives at the sequencing layer.
  * **Economics (Track B).**  "The sequencer is reimbursed for L1 gas
    but cannot loot the pool" is half kernel-proved and half operational.
    The kernel + GP.7 prove the *bound* (the drain is a capped
    `gasPoolActor → sequencerActor` transfer, and `pool_drain_bounded_by_action_count`
    bounds a whole trace); the *honesty* of the claimed amount within
    that bound is, in v1, an operator-trust assumption (§2.9).

The correct division is therefore three-layered:

  * **Kernel (safety):** the GP per-action stock bound — bounds an
    actor's lifetime cost; prevents sustained/infinite DoS.  Shipped.
  * **Sequencer (liveness + bounded economics):**
    * Track A's work-conserving fair scheduler bounds an actor's *share
      of the worker under contention* — prevents short-burst overwhelm
      without penalising productive bursts.
    * Track B's governed claim bounds the sequencer's *outflow from the
      pool* — the GP.7.2 policy fences which action, recipient, sender,
      and per-leg amount are even admissible.
  * **L1 (liveness backstop):** forced inclusion defeats a censoring
    operator.  Out of scope here.

No track weakens any kernel guarantee: the proof-carrying safety core is
untouched.  Each scopes a property the kernel provably cannot deliver to
the layer that can.  The two sequencer-side bounds are duals — one fences
what flows *in* to the worker, the other what flows *out* of the pool —
which is exactly why they belong in one plan.

### §2.2 The sequencer lifecycle (ingest → admit → commit → claim)

A single admitted action threads the whole component; the tracks attach
at distinct stages.

```
  user SignedAction
        │  (TCP/TLS/Unix frame; opaque CBE bytes)
        ▼
  ┌─────────────────────────── knomosis-host ───────────────────────────┐
  │  accept() ─ assign ConnId ─ (Rung-1: read 8-byte signer-hint)        │
  │        │                                                             │
  │        ▼   ┌──────── Track A: fair sequencing (FQ) ────────┐         │
  │   QueueHandle.submit(conn, payload)                        │         │
  │        │   FIFO BoundedQueue  ──or──  FairQueue (DRR)       │         │
  │        ▼   per-flow caps + work-conserving pick             │         │
  │   serial worker ── dispatch one ──────────────────────────┘         │
  │        │                                                             │
  │        ▼   Track C: budget admission gate (GP.6.2, shipped)          │
  │   AdmissibleWith / BridgeAdmissibleWith + budget consume/grant       │
  │        │  (free-tier / epoch policy from --free-tier/--epoch-length) │
  └────────┼─────────────────────────────────────────────────────────────┘
           ▼
     append to the transition log  (Replay / LogFile)
           │
           ▼
     periodic state-root commit ──► L1 KnomosisStateRootSubmission
           │                          (Workstream H; sequencerActor signs)
           │                          └─ challenged by RH-G observer
           │                             (TurnSide::Sequencer)
           ▼
     L1 gas spent on the commit
           │
           ▼   Track B: reimbursement claim (GP.8.1)
     gasPoolActor ── transfer(r, gasPoolActor → sequencerActor, amount) ──► sequencerActor
           (admitted under gasPoolPolicy + gasPoolAuthorityPolicy; capped per leg)
```

Reading the stages:

  * **Ingest + fair sequencing (Track A).**  The host frames bytes,
    assigns a `ConnId`, optionally reads a signer-hint, and enqueues via
    the `QueueHandle`.  Either the FIFO queue (default) or the DRR
    `FairQueue` decides dispatch order.  **No CBE parsing happens here.**
  * **Admission + configuration (Track C).**  The serial worker hands the
    opaque bytes to the kernel, which decodes, verifies the signature,
    runs the budget gate (free-tier / epoch policy), and either admits
    (consuming budget and applying `step_impl`) or rejects.  This gate is
    already shipped (GP.6.2); Track C is its configuration + guidance.
  * **Commit + state root (Workstream H, cross-referenced).**  The
    sequencer periodically commits a state root to L1 as `sequencerActor`;
    the RH-G observer can challenge it.  This plan does **not** re-specify
    H/RH-G; it only notes the L1 gas this stage costs.
  * **Claim (Track B).**  The sequencer reimburses the L1 gas by signing,
    as `gasPoolActor`, a capped `transfer` to `sequencerActor`.

The lifecycle makes the unification concrete: Track A governs the *first*
stage, Track C the *second*, Track B the *last*, and Track D documents
operating all of them.

### §2.3 The current `knomosis-host` queue + the shipped budget gate

Established by reading `runtime/knomosis-host/src/{queue,server,listener,
config,frame,budget,kernel,lib}.rs`:

  * `Server::run` builds **one** `BoundedQueue` — a
    `std::sync::mpsc::sync_channel(max_queue_depth)` — and spawns a
    single `worker_loop(receiver, kernel, stop)`.  The worker is serial
    *by design*: the kernel holds mutable log state requiring sequential
    access.  **The contended resource is exactly this one worker's
    dispatch slots.**
  * Each accepted connection runs in its own thread; the handler calls
    `queue.try_submit(payload)` → `Enqueued(reply_rx)` or `Busy`, then
    blocks on `reply_rx.recv()`.
  * A `QueuedRequest { payload: Vec<u8>, reply: SyncSender<KernelResponse> }`
    carries opaque CBE bytes plus a one-shot reply channel.  The worker
    `drain_one`s FIFO, dispatches, and replies.
  * **The host never parses the CBE payload** (lib.rs security property
    #1: framing/queue bugs "can drop or reorder but cannot violate any
    admissibility witness").
  * `admission.rs` already defines `AdmissionStage::Sequenced` — the
    conceptual slot a fair scheduler fills.
  * **`budget.rs` already ships the GP.6.2 admission gate** —
    `BudgetPolicy` / `ActorBudget` / `EpochBudgetState` mirrors of the
    Lean ledger, a `BudgetGate`, and the `--budget-policy` /
    `--free-tier` / `--action-cost` / `--current-epoch` / `--epoch-length`
    flags.  This is the *configuration substrate* Track C documents and
    the *budget data* a future weighted scheduler (§9) would read.
  * Config is a hand-rolled parser over a `Config` struct with fields
    defaulted from `DEFAULT_*` constants and a `ConfigError` enum for
    validation — the pattern FQ.0 / FQ.5 / GP.8.2 follow.

### §2.4 Why FIFO is unfair at both ends

A single FIFO into a single shared bounded buffer is unfair in two
independent ways, and Track A must fix both:

  * **Dequeue (HOL blocking).**  A whale's 10k requests form a contiguous
    FIFO run; a small actor's single request waits behind all of them.
    DRR fixes the dequeue order.
  * **Enqueue (shared-buffer starvation).**  The whale fills all buffer
    slots, so honest requests receive `Busy` *before* scheduling can help
    them.  Track A therefore also needs **per-flow buffer caps**: a
    flooding flow gets `Busy` on its *own* over-submission while other
    flows still enqueue freely.  This per-flow `Busy` is the enqueue-side
    dual of DRR.

### §2.5 The routing-key problem and the rung ladder

To bucket by actor the host needs a per-request key, but the signer is
not cheaply available: `SignedAction.encode = action ++ signer ++ nonce
++ sig`, so the signer sits *after* the variable-length `Action`.
Reading it would require parsing the whole `Action` — exactly the CBE
interpretation the host must not do.  Resolve as a ladder:

  * **Rung 0 (no wire change): key = ConnId.**  The connection is
    transport-authenticated, so unspoofable.  DRR across connections.
    Zero CBE parsing.  Meaningful whenever distinct actors arrive on
    distinct connections.
  * **Rung 1 (additive, version-gated): key = (ConnId, signer-hint).**
    The client prepends an explicit 8-byte signer hint per frame; the
    host buckets by it for *scheduling only*.  The kernel still reads the
    real signer from the CBE and verifies the signature, so a forged hint
    cannot affect admissibility.  Two-tier: outer round-robin across
    connections, inner across signer-hints within a connection.
  * **Ruled out: a full `Action` parser in the host.**  It would
    replicate kernel decode logic and couple the host to every future
    `Action` constructor.  Never do this.

**Topology note (resolved by this unification).**  If end users funnel
through a single upstream sequencer connection, Rung 0 is degenerate (one
connection = one flow) and the *sequencer itself* is where fairness must
live.  The original FQ plan left this as an open caveat; here it is
answered directly: **the sequencer is that contention point, and the DRR
module is exactly what it runs there** — `knomosis-host` *is* the
sequencer's admission front-end in the canonical topology, so Track A's
scheduler runs at precisely the place Track B's claim later drains.  If
users connect more directly, Rung 0 is immediately meaningful and Rung 1
sharpens it.  Either way the mechanism is the same code; the deployment
chooses where the contention point sits.

### §2.6 Trust and safety invariants

Every Track-A WU must preserve these; reviewers check them explicitly.
Invariant 5 extends the set to cover Track B.

  1. **Classification-only routing.**  The routing key influences *order
     and drop*, never admissibility.  A wrong or forged key can only
     mis-route, and mis-route ⊆ "reorder", which the existing security
     property #1 already tolerates.  **Safety is untouched by any routing
     decision.**
  2. **Spoofing is a fairness-only risk.**  A Rung-1 client that lies
     about its signer-hint can only disturb scheduling.  The two-tier
     structure confines the damage: a connection that spawns many fake
     hints still receives only its *one* connection's outer share,
     subdivided among its fakes — self-harm, not theft.  The ConnId outer
     tier is unspoofable, so a victim on another connection is
     unaffected.
  3. **Legacy clients degrade safely.**  A client that sends no hint is
     treated as a single implicit flow within its connection — i.e.
     Rung-0 behaviour.  Rung 1 is strictly additive.
  4. **The scheduler is itself bounded.**  Distinct flows are an attack
     surface (unbounded map growth).  Bounded by `max_flows` (and, in
     Rung 1, a per-connection distinct-signer cap), plus immediate
     eviction of empty flows.
  5. **The claim is an ordinary governed action (Track B).**  The
     reimbursement claim is a normal `SignedAction` that passes the
     ordinary admission gate; it gains nothing the kernel does not
     already permit.  Its *entire* extra-kernel privilege is bounded by
     the GP.7.2 `gasPoolPolicy` + `gasPoolAuthorityPolicy`: only a
     `transfer`, only `gasPoolActor → sequencerActor`, only the pool's
     own funds (`sender = gasPoolActor`), capped per leg, and never a
     meta-action.  Track B may **never** widen this governance; it only
     supplies the tooling that emits an action the governance already
     admits.  A buggy claim tool can over- or under-claim *within the
     cap* (a v1 honour-system limit, §2.9) but can never exceed it.

### §2.7 The DRR core

  * **Cost = 1 per request** (one dispatch slot).  No payload inspection
    needed to compute cost.
  * **Quantum = 1, equal weight.**  At cost = 1 / quantum = 1, DRR
    collapses to strict per-actor **round-robin**: serve one, rotate.
    The `deficit` accounting and per-flow `quantum` field are kept so
    budget-weighted quanta (a concrete, planned extension — §9) drop in
    without restructuring.
  * **Caps live in the pure core.**  Capacity checks are integer logic,
    so `enqueue` enforces them and returns the request back on a breach;
    the concurrency wrapper merely maps that to `Busy`.  This keeps cap
    behaviour unit-testable without any I/O.
  * **Reset deficit to 0 when a flow empties** (and evict it).  No
    banking of credit across idle periods — a returning whale cannot
    accumulate a burst allowance while quiet, which is precisely the
    anti-burst goal.
  * **Work-conserving.**  The worker blocks only when *all* flows are
    empty; any pending request is served.
  * **Bounded wait.**  A flow's head waits at most `(active_flows - 1)`
    dispatches — bounded because `active_flows ≤ max_flows`.
  * **Deterministic, I/O-free decision.**  `pick(&mut self)` mutates
    scheduler state but reads no clock and performs no I/O; given the same
    enqueue/pick sequence it is reproducible.  That determinism (not
    referential purity) is what future accountable-fairness replay needs,
    and it is the unit-test surface.
  * **`BTreeMap` for the flow maps.**  Deterministic iteration and no
    hash-DoS / random-seed surface; scheduling order is driven by the
    `active` deque, not map iteration, so the log-factor cost is
    irrelevant at these sizes.

### §2.8 Concurrency and shutdown model (mirrors the FIFO worker)

The fair path must reuse the *proven* shape of the existing `worker_loop`
(`src/server.rs`) rather than invent a new one:

  * **The worker owns stop-checking, not the queue.**  The FIFO loop is
    `loop { if stop { drain non-blocking until empty; break } match
    drain_one(100ms) { Dispatched|Timeout => continue; Disconnected =>
    break } }`.  The fair worker is identical with `FairQueue::next(100ms)`
    (returns `Dispatch`/`Idle`) and `FairQueue::try_next()` (non-blocking)
    in place of `drain_one`/`try_drain_one`.  `FairQueue` needs **no**
    reference to the stop flag.
  * **Bounded shutdown latency.**  The 100 ms `wait_timeout` means the
    worker notices `stop` within 100 ms even if parked; an optional
    `not_empty.notify_all()` on shutdown makes it immediate.  Correctness
    does not depend on the notify.
  * **Dispatch happens outside the lock.**  `next()` pops the request
    under the lock and returns it by value (the `MutexGuard` drops at
    return); the slow `kernel.submit` call then runs lock-free.  This is
    the key throughput property (§ FQ.7c).
  * **Panic firewall + poison recovery preserved.**  The fair worker
    keeps the `catch_unwinding_submit` wrapper, and `FairQueue`'s own
    `Mutex` uses the same `lock().unwrap_or_else(|p| p.into_inner())`
    poison-recovery the kernel locks use — no `unwrap` that can panic a
    producer or worker thread.

### §2.9 The reimbursement-claim mechanism (v1 honour-system → v2)

**The problem.**  The sequencer pays real L1 ETH to submit state roots
(Workstream H).  It funds that from the gas pool, which accrues the
deposit fee-split skim and per-actor top-up revenue at `gasPoolActor`
(`ActorId 1`).  The pool must be drainable *to the sequencer* but to
nobody else, and not without bound.

**The mechanism (v1, GP.8.1).**  The claim is a single kernel action:

```
Action.transfer resource gasPoolActor sequencerActor amount
  signer = gasPoolActor          -- the pool's own registered key
```

signed by the key registered to `gasPoolActor` (held by the sequencer
operator), where `resource ∈ {0 = ETH, 1 = BOLD}` and `amount` is the
operator's estimate of L1 gas spent since the last claim on that leg.
It is admitted under the GP.7.4 genesis-ratified governance:

  * `gasPoolPolicy` (a `LocalPolicy`): denies every Action tag except
    `transfer`; on each gas leg requires `recipient = sequencerActor` and
    caps `amount ≤ maxDrainPerAction{Eth,Bold}`.
  * `gasPoolAuthorityPolicy` (an `AuthorityPolicy`, intersected at
    genesis): binds `sender = gasPoolActor` (so the pool moves only its
    own funds, never a victim's — the GP.7.2 PR-#106 fix), and — having
    no meta-action exemption — bars `gasPoolActor` from rewriting its own
    `LocalPolicy`.

So the *shape* of a claim is fully kernel-governed and proof-bounded:
`gasPoolPolicy_denies_all_non_transfer`, `…_requires_sequencer_recipient_{eth,bold}`,
`…_caps_per_action_{eth,bold}`, and the GP.7.3 per-trace bound
`pool_drain_bounded_by_action_count` together prove that across any
admitted trace of `n` claims the pool's leg-`r` balance falls by at most
`n × legCap`.  **What v1 does *not* prove is that `amount` equals the gas
actually spent.**  A fully-malicious operator can claim up to the cap on
every epoch regardless of real spend.  This is accepted because:

  1. the cap bounds the absolute loss per claim and (via GP.7.3) per
     trace;
  2. the dispute pipeline can challenge sustained over-claims
     (deployment-level enforcement);
  3. the sequencer is a single party already trusted for liveness (it
     can censor or stall regardless); and
  4. the v2 cryptographic mechanism is a clean drop-in once it becomes
     operationally important.

**The claim consumes `gasPoolActor`'s budget (a provisioning
requirement).**  `gasPoolActor` is *not* budget-exempt — only
`bridgeActor` is (`SignedAction.lean`: the consume step is skipped iff
`st.signer = Bridge.bridgeActor`, per OQ-GP-6).  And the production kernel
always runs in *bounded* budget mode (the `.unlimited` variant was dropped
in the GP.3 wiring closure; the genesis default `.bounded 0 1 0` is
deny-by-default, and there is no "budget-off" fallback outside the
test-only mock kernel).  So each admitted claim debits one action-cost
unit from `gasPoolActor`'s per-epoch budget, exactly like any other
non-bridge actor.  Three consequences the implementer and operator must
honour, or claims fail closed:

  * The **deny-by-default genesis** (`.bounded 0 1 0`, `freeTier = 0`)
    rejects *every* claim for `InsufficientBudget`.  A claiming deployment
    MUST run with `freeTier ≥ 1` (and `currentEpoch ≥ 1`), which Track C
    already requires for users; the point here is that the requirement
    extends to `gasPoolActor` itself.
  * **Claim frequency per epoch must stay within `gasPoolActor`'s budget**
    (`freeTier` + any top-ups).  Since claims are periodic and infrequent,
    a modest `freeTier` suffices; a deployment that claims more often than
    `freeTier` per epoch must top `gasPoolActor`'s budget up (an ordinary
    `topUpActionBudget`) or it will hit `InsufficientBudget`.
  * `gasPoolActor` needs a **registered key** (so it can sign) and a
    **tracked nonce** (`AdmissibleWith` requires `nonce = expectsNonce es
    signer` plus a valid signature).  The operator registers the
    `gasPoolActor` key (e.g. a `bridgeActor`-signed `registerIdentity`, or
    at genesis) and monotonically advances its nonce per claim.

This is a fail-closed property, not a vulnerability — a mis-provisioned
pool actor simply cannot claim — but it is a real prerequisite, so Track B
(GP.8.1b) lists GP.6.2 as a dependency and Track D (GP.8.3) documents it.

**The forward path (v2, GP.8.5 — deferred).**  Make `amount` *provable*.
The sequencer's state-root submissions are L1 transactions with on-chain
gas receipts; an L1 receipt verifier (the same trust-pattern as the
fault-proof `l1FaultProofVerifier` opaque in
`LegalKernel/FaultProof/Witness.lean`) can attest "`sequencerActor` spent
`G` wei of L1 gas on state-root submissions in `[block_a, block_b]`", and
the claim's admissibility can be gated on `amount ≤ priceOf(G)`.  This
turns the honour-system bound into a cryptographic one.  It is specified
in §5 but **out of scope for v1** — it needs an L1 receipt-proof surface
and a price oracle, both larger than the v1 deliverable.  Crucially, the
v1 action shape is forward-compatible: v2 adds a *gate*, not a new
action, so v1 claims remain valid and v2 simply refuses to admit ones
that exceed the proven spend.

## §3 Unified work-unit dependency graph

The two tracks are nearly independent — Track A touches only the
`knomosis-host` scheduling path; Tracks B–D touch the claim tool, the
config guidance, and the runbook.  Their only coupling is documentation
(Track D documents both) and the §9 forward link (Track C's budget data
feeds a future weighted scheduler).

```
PREREQUISITES (all Complete):
  RH-C (knomosis-host) ─────────┐
  GP.6.2 (host budget gate) ────┤
  GP.7.4 (gasPoolPolicy genesis)┤
  Workstream H + RH-G ──────────┘

TRACK A — Fair sequencing (Workstream FQ):
  Rung 0 (no wire change):
    FQ.0 (skeleton + --scheduler flag)
     ├─> FQ.1a (core: structs + enqueue + caps) ─> FQ.1b (pick) ─> FQ.1c (core tests)
     │        FQ.1a,1b ─> FQ.2a (FairQueue + try_submit) ─> FQ.2b (next/try_next) ─> FQ.2c (concurrency tests)
     ├─> FQ.3  (ConnId assignment)
     └─> FQ.5  (caps config)
          FQ.2b + FQ.3 ─> FQ.4a (QueueHandle + Server branch) ─> FQ.4b (fair_worker_loop + shutdown)
          FQ.4b ─> FQ.6 (observability)
          FQ.4b ─> FQ.7a (fairness tests) ─> FQ.7b (stress/shutdown/parity) ─> FQ.7c (perf parity)
          FQ.7c ─> FQ.8 (Rung-0 docs + closeout)

  Rung 1 (begins after FQ.8 lands):
    FQ.9 (wire amendment + abi.md + frame ceiling)
     ├─> FQ.10a (conn negotiation) ─> FQ.10b (per-frame hint read)
     ├─> FQ.11a (tier-parameterised core) ─> FQ.11b (two-tier pick + spoof test)  [FQ.11a needs FQ.1b]
     │        FQ.11b + FQ.2b ─> FQ.12 (FairQueue two-tier + per-signer caps)
     └─> FQ.13a (l1-ingest) ‖ FQ.13b (observer) ‖ FQ.13c (bench)                   [parallel; disjoint crates]
          FQ.12 + FQ.10b + FQ.13* ─> FQ.14a (fairness + spoof e2e) ─> FQ.14b (wire interop) ─> FQ.15 (Rung-1 docs + closeout)

TRACK B — Reimbursement claims:
  GP.7.4 + GP.6.2 ─> GP.8.1a (sequencer_claim.rs core) ─> GP.8.1b (signing + pool-key wiring) ─> GP.8.1c (tests + abi.md)
  GP.8.1c ┄┄(deferred)┄┄> GP.8.5 (v2 receipt-verified claim)   [needs an L1 receipt-proof surface + price oracle]

TRACK C — Configuration:
  GP.6.2 (flags already shipped) ─> GP.8.2 (operational guidance + action-clock decision)

TRACK D — Operations:
  GP.8.1c + GP.8.2 + FQ.8 ─> GP.8.3 (runbook baseline: claim ops + config + fair-queuing ops)
  GP.8.3 + GP.11.{3,4,9,10} ─> GP.8.4 (runbook v1.3+ expansion: AMM / BOLD / monitoring)

LANDING:
  FQ.15 (Track A done) + GP.8.1c + GP.8.2 + GP.8.4  ─────► GP.10.x (Workstream-GP docs/audits/landing)
```

**Critical path (Track A).**  FQ.0 → FQ.1a → FQ.1b → FQ.2a → FQ.2b →
FQ.4a → FQ.4b → FQ.7a → FQ.7b → FQ.7c → FQ.8 → FQ.9 → FQ.11a → FQ.11b →
FQ.12 → FQ.14a → FQ.14b → FQ.15.  FQ.3 and FQ.5 parallelise with the
FQ.1/FQ.2 chain; FQ.13a–c parallelise with FQ.10–FQ.12.

**Critical path (Tracks B–D).**  GP.8.1a → GP.8.1b → GP.8.1c → GP.8.3 →
GP.8.4.  GP.8.2 parallelises (depends only on the shipped GP.6.2).
Track D's GP.8.3 also needs FQ.8 to land so its fair-queuing-operations
section documents a shipped feature.

**Parallelism + file ownership** (per the CLAUDE.md background-agent
discipline).  Track A's `src/fair/drr.rs` (FQ.1a–c) is disjoint from
FQ.3 (`src/listener.rs` + `src/server.rs`) — safe concurrently.  FQ.2a–c
(`src/queue.rs`) and FQ.4a–b (`src/server.rs`) both touch
`server.rs`/`queue.rs`; serialise them.  FQ.13a/b/c each own a different
downstream crate — fully parallelisable.  Track B's `src/sequencer_claim.rs`
is a brand-new file disjoint from every Track-A file — Tracks A and B can
proceed fully in parallel by different contributors.  Track D edits only
`docs/`.

**Effort roll-up.**

  * **Track A — Rung 0:** FQ.0 0.5 + FQ.1a 0.5 + FQ.1b 0.5 + FQ.1c 0.5 +
    FQ.2a 0.5 + FQ.2b 0.5 + FQ.2c 0.5 + FQ.3 1.0 + FQ.4a 0.5 + FQ.4b 0.5
    + FQ.5 0.5 + FQ.6 0.5 + FQ.7a 0.75 + FQ.7b 0.75 + FQ.7c 0.5 + FQ.8
    0.5 = **9.0 d**.
  * **Track A — Rung 1:** FQ.9 1.0 + FQ.10a 0.5 + FQ.10b 0.5 + FQ.11a
    0.75 + FQ.11b 0.75 + FQ.12 1.0 + FQ.13a 0.5 + FQ.13b 0.5 + FQ.13c 0.5
    + FQ.14a 0.75 + FQ.14b 0.75 + FQ.15 0.5 = **8.0 d**.
  * **Track B:** GP.8.1a ~3 h + GP.8.1b ~3 h + GP.8.1c ~2 h = ~8 h ≈
    **1.0 d** (v1); GP.8.5 deferred.
  * **Track C:** GP.8.2 ~3 h ≈ **0.5 d**.
  * **Track D:** GP.8.3 ~6 h + GP.8.4 ~14 h = ~20 h ≈ **2.5 d**.

**Total: ~21.0 engineer-days** (Track A 17.0 + Track B 1.0 + Track C 0.5
+ Track D 2.5; the deferred GP.8.5 is excluded).

## §4 Track A — Fair sequencing (Workstream FQ)

Track A is Workstream FQ in full: per-actor fair scheduling in
`knomosis-host` so one actor's short-burst flood cannot delay other
actors' admitted actions, while productive bursts on an idle host pass
through unthrottled.  It ships in two rungs behind a default-OFF flag.

### Rung 0 — connection-keyed DRR (no wire change)

#### FQ.0 — Workstream skeleton + scheduler selector

**Scope.**  `runtime/knomosis-host/src/config.rs`, `src/lib.rs`, new
module dir `src/fair/` (empty `mod.rs`).

**Implementation steps.**

  1. Add a `Scheduler` enum (`Fifo`, `Drr`) with `FromStr` + `Display`;
     default `Fifo`.
  2. Add `--scheduler {fifo|drr}` to the hand-rolled parser + a
     `scheduler: Scheduler` field on `Config`; add the row to the flag
     table in the module docstring; add a `ConfigError` variant for an
     invalid value.
  3. `pub mod fair;` in `lib.rs` with an empty `src/fair/mod.rs`
     (re-export point for FQ.1/FQ.2).
  4. No behavioural change yet: `Server::run` still builds the FIFO
     `BoundedQueue` regardless of the parsed value.

**Acceptance criteria.**

  * `--scheduler drr|fifo` parse; invalid value → clear `ConfigError`;
    default is `Fifo`.
  * `cargo build/test/clippy -D warnings/fmt` clean; existing tests pass
    unmodified (no behaviour change).

**Risk.**  Trivial.  **Effort.**  ~0.5 engineer-day.

#### FQ.1a — Pure DRR core: data structures + `enqueue` + caps

**Scope.**  New `runtime/knomosis-host/src/fair/drr.rs` (pure; no
`std::sync`, no sockets, no clock).

**Implementation steps.**

  1. Types, generic over the routing `Key` (instantiated to `ConnId` in
     Rung 0): `Flow { deque: VecDeque<QueuedRequest>, deficit: u64,
     quantum: u64 }`; `Caps { per_flow: usize, max_flows: usize, global:
     usize }`; `DrrState { flows: BTreeMap<Key, Flow>, active:
     VecDeque<Key>, total_depth: usize, caps: Caps }`.
  2. `enqueue(&mut self, key, req) -> Result<(), QueuedRequest>`: enforce,
     atomically under the caller's lock, `global`, `max_flows` (only when
     the key is new), then `per_flow`; on any breach return `Err(req)`
     (the request flows back so the wrapper can answer `Busy` — nothing is
     silently dropped).  On success push to the flow; on an
     empty→non-empty transition push the key to `active`; bump
     `total_depth`.
  3. Single map lookup via the `entry` API (no check-then-insert TOCTOU).

**Acceptance criteria.**

  * Unit tests: `per_flow`, `max_flows`, `global` each independently
    return `Err`; the returned request is the one passed in; activation
    bookkeeping correct; `total_depth` exact.
  * `clippy::pedantic` clean; no `unsafe`; no `panic!` on any input.

**Risk.**  Low.  **Effort.**  ~0.5 engineer-day.

#### FQ.1b — Pure DRR core: the `pick` step

**Scope.**  `runtime/knomosis-host/src/fair/drr.rs` (continues FQ.1a).

**Implementation steps.**

  1. `pick(&mut self) -> Option<QueuedRequest>`: if `active` empty return
     `None`; else peek its front key, top up `deficit += quantum` once on
     entry to the flow's turn; if `cost (=1) <= deficit`, pop head,
     `deficit -= 1`, `total_depth -= 1`; if the flow is now empty **remove
     it from `active` and from `flows`, discarding its deficit**, else
     rotate the key to the back of `active`; return the popped request.
  2. Keep every branch deterministic and clock-free (the
     accountable-fairness seam, §2.7).
  3. Expose a read-only `len()/is_empty()/active_len()` for the wrapper's
     `Condvar` predicate and for FQ.6 stats.

**Acceptance criteria.**

  * Unit tests: round-robin order across N flows; one heavy flow does not
    starve a light flow (light flow's head served within N `pick`s);
    empty-flow eviction + deficit reset; `pick` on empty → `None`.
  * Property test: across arbitrary enqueue/pick interleavings, no active
    flow is served more than one request ahead of the least-served active
    flow (equal-weight fairness bound).

**Risk.**  Low–medium.  The activation/eviction bookkeeping is the
classic DRR fiddly part; the property test guards it.  **Effort.**  ~0.5
engineer-day.

#### FQ.1c — Pure DRR core: test hardening

**Scope.**  `runtime/knomosis-host/src/fair/drr.rs` (`#[cfg(test)]`).

**Implementation steps.**

  1. Determinism test: two identical enqueue/pick scripts yield identical
     served sequences (the replay guarantee).
  2. Fuzz/randomised soak (seeded): thousands of random enqueue/pick ops;
     assert no panic, `total_depth` invariant holds, `active` contains
     exactly the non-empty flows, evicted flows are absent from `flows`.
  3. Boundary cases: `per_flow = 1`; `max_flows = 1`; `global = 0`
     (everything `Busy`); single-flow saturation.

**Acceptance criteria.**

  * All tests deterministic (seed any randomness) and green under
    `ci-rust.yml`.
  * Coverage spans every `enqueue`/`pick` branch.

**Risk.**  Low.  **Effort.**  ~0.5 engineer-day.

#### FQ.2a — `FairQueue`: struct + `try_submit`

**Scope.**  `runtime/knomosis-host/src/queue.rs` (add alongside the
existing `BoundedQueue`; do not remove it).

**Implementation steps.**

  1. `FairQueue { inner: Arc<Mutex<DrrState<ConnId>>>, not_empty:
     Arc<Condvar> }`, `Clone` (shares the `Arc`s) to match
     `BoundedQueue`'s producer-handle ergonomics; the `Caps` live in the
     `DrrState` (FQ.1a).
  2. `try_submit(&self, conn: ConnId, payload: Vec<u8>) -> SubmitOutcome`:
     build the capacity-1 reply channel (as today); lock
     (poison-recovering: `unwrap_or_else(|p| p.into_inner())`); construct
     the `QueuedRequest`; call `state.enqueue(conn, req)`; on `Ok(())`
     `notify_one()` and return `Enqueued(reply_rx)`; on `Err(_req)` drop
     the request and return `Busy`.
  3. Reuse the existing `SubmitOutcome` enum; the reply mechanism and
     `QueuedRequest` are unchanged.

**Acceptance criteria.**

  * Per-flow cap: one flow saturating its cap gets `Busy`; a second flow
    still enqueues (targeted backpressure) — asserted via the
    `MockKernel`-free queue API directly.
  * `global`/`max_flows` breaches each return `Busy`.
  * Lock-poison path covered (a poisoned lock still serves).

**Risk.**  Low–medium.  **Effort.**  ~0.5 engineer-day.

#### FQ.2b — `FairQueue`: blocking `next` + non-blocking `try_next`

**Scope.**  `runtime/knomosis-host/src/queue.rs`.

**Implementation steps.**

  1. `next(&self, timeout: Duration) -> NextOutcome` where `NextOutcome {
     Dispatch(QueuedRequest), Idle }`: lock; if `active` empty,
     `not_empty.wait_timeout(guard, timeout)`; after waking, `pick()` —
     `Some(req)` → return `Dispatch(req)` (guard drops at return, so
     dispatch is lock-free), `None` → `Idle`.  **No knowledge of any stop
     flag** (§2.8).
  2. `try_next(&self) -> Option<QueuedRequest>`: lock; `pick()`; return —
     the non-blocking analog of `try_drain_one`, used by the shutdown
     drain.
  3. Use the `Condvar` predicate-loop idiom to tolerate spurious wakeups;
     cap the wait at `timeout` so the worker re-checks `stop` every ~100
     ms.

**Acceptance criteria.**

  * `next` blocks when empty and returns `Dispatch` promptly after a
    concurrent `try_submit` + `notify`; returns `Idle` within ~`timeout`
    when no work.
  * `try_next` returns immediately (`Some`/`None`), never blocks.
  * The dispatched request is returned by value with the lock already
    released (assert no lock held during a slow dispatch via a contention
    test).

**Risk.**  Medium.  `Condvar` wait/notify + spurious-wakeup handling.
**Effort.**  ~0.5 engineer-day.

#### FQ.2c — `FairQueue`: concurrency tests

**Scope.**  `runtime/knomosis-host/src/queue.rs` (`#[cfg(test)]`).

**Implementation steps.**

  1. Multi-producer / single-consumer: N producer threads `try_submit`
     across M conns; one consumer drains via `next`; assert every
     non-`Busy` request is dispatched exactly once and replies arrive.
  2. Targeted backpressure under concurrency: a saturating flow sees
     `Busy` while another flow makes progress concurrently.
  3. Wake/timeout: consumer parked on `next` wakes on a late `try_submit`;
     `next` returns `Idle` on an idle interval.
  4. Shutdown-drain shape: after producers stop, `try_next` empties the
     queue and then returns `None`.

**Acceptance criteria.**

  * Deterministic (bounded retries, seeded); green under `ci-rust.yml`;
    `queue_is_clone_send_sync`-style trait assertions extended to
    `FairQueue`.

**Risk.**  Medium (concurrency-test flakiness).  Prefer logical
assertions (exactly-once, served-set) over timing.  **Effort.**  ~0.5
engineer-day.

#### FQ.3 — ConnId assignment + threading

**Scope.**  `runtime/knomosis-host/src/listener.rs`, `src/server.rs`.

**Implementation steps.**

  1. Add a monotonic `conn_seq: Arc<AtomicU64>` created in `Server::run`
     (separate from the existing `connection_counter` gauge, which is
     inc/dec for the concurrency cap and is NOT a stable unique id).
  2. Pass `conn_seq` into each `accept_loop` (TCP, TLS, Unix).  On each
     accepted connection, `let conn_id = conn_seq.fetch_add(1, Relaxed);`
     and thread it into the per-connection handler.
  3. The handler carries `conn_id` to its submit call (consumed by the
     `QueueHandle` in FQ.4a); ConnIds are never reused (monotonic), so an
     evicted flow cannot alias a later connection.

**Acceptance criteria.**

  * Distinct concurrent connections receive distinct, monotonic `ConnId`s
    across all three listeners.
  * Existing listener tests pass (the id is additive).

**Risk.**  Low.  **Effort.**  ~1.0 engineer-day.

#### FQ.4a — `QueueHandle` seam + `Server::run` branch

**Scope.**  `runtime/knomosis-host/src/queue.rs`, `src/server.rs`.

**Implementation steps.**

  1. Introduce `enum QueueHandle { Fifo(BoundedQueue), Fair(FairQueue) }`
     with `fn submit(&self, conn: ConnId, payload: Vec<u8>) ->
     SubmitOutcome`; the `Fifo` arm ignores `conn` and calls
     `BoundedQueue::try_submit(payload)`; the `Fair` arm calls
     `FairQueue::try_submit(conn, payload)`.  `Clone`.
  2. Connection handlers hold a `QueueHandle` and call
     `handle.submit(conn_id, payload)` — scheduler-agnostic, so the
     listener code is identical on both paths.
  3. `Server::run` branches on `config.scheduler`: `Fifo` builds the
     `BoundedQueue` + its `receiver`; `Drr` builds the `FairQueue`.  Wrap
     the chosen producer side in a `QueueHandle` for the listeners.

**Acceptance criteria.**

  * `--scheduler fifo` is byte-for-byte the old path (same queue, same
    `worker_loop`); existing server/integration tests pass.
  * `--scheduler drr` constructs the `FairQueue`-backed handle.

**Risk.**  Low–medium (touches the `Server::run` wiring).  **Effort.**
~0.5 engineer-day.

#### FQ.4b — `fair_worker_loop` + shutdown protocol

**Scope.**  `runtime/knomosis-host/src/server.rs`.

**Implementation steps.**

  1. `fair_worker_loop(queue: FairQueue, kernel, stop)` mirroring
     `worker_loop` exactly (§2.8): `loop { if stop { while let Some(req) =
     queue.try_next() { dispatch+reply }; break } match queue.next(100ms)
     { Dispatch(req) => dispatch+reply; Idle => continue } }`.
  2. `dispatch+reply` reuses `catch_unwinding_submit(&*kernel,
     &req.payload)` then `req.reply.try_send(response)` — identical to the
     FIFO body.
  3. `Server::run` spawns `fair_worker_loop` on the `Drr` path; on
     shutdown it sets `stop`, waits for handlers to drain
     (`wait_for_handlers_drain`), then optionally
     `queue.not_empty.notify_all()` for prompt wake; the worker's
     `stop`-branch drains the remainder and exits; `worker.join()` as
     today.

**Acceptance criteria.**

  * End-to-end on `Drr`: connect, submit, receive verdict (parity with
    FIFO for a single actor).
  * Graceful shutdown under load: queued requests drain, worker joins, no
    `Condvar` hang, no lost in-flight replies; kill-during-load test
    passes.
  * Kernel-panic firewall still works on the fair path (debug build).

**Risk.**  Medium.  Shutdown wake/drain ordering is the most error-prone
part; test kill-during-load explicitly.  **Effort.**  ~0.5 engineer-day.

#### FQ.5 — Caps configuration + validation

**Scope.**  `runtime/knomosis-host/src/config.rs`.

**Implementation steps.**

  1. Add flags + `Config` fields with `DEFAULT_*` constants:
     `--per-flow-cap <n>` (default 64), `--max-flows <n>` (default 4096);
     reuse `--max-queue-depth` as the DRR `global` cap.  Add the rows to
     the flag-table docstring (note: "ignored unless `--scheduler drr`").
  2. Validate via `ConfigError`: `per_flow_cap >= 1`; `per_flow_cap <=
     max_queue_depth`; `max_flows >= 1`; clamp `max_flows` and
     `max_queue_depth` to hard ceilings (mirror `HARD_MAX_QUEUE_DEPTH`) so
     worst-case memory (`global * max_frame_size`) is bounded.
  3. Plumb the three values into the `Caps` the `FairQueue` is built with
     (FQ.4a).

**Acceptance criteria.**

  * Defaults present; out-of-range rejected or clamped per spec; help text
    states FIFO ignores them; parse tests per new flag.

**Risk.**  Trivial.  **Effort.**  ~0.5 engineer-day.

#### FQ.6 — Observability

**Scope.**  `runtime/knomosis-host/src/queue.rs` (+ `tracing` call sites).

**Implementation steps.**

  1. Counters: per-flow `Busy` rejections, `global`/`max_flows`
     rejections, active-flow gauge, total dispatches.
  2. Emit via the crate's existing `tracing` at `debug`/`info`; no new
     dependency.  Aggregate — never per-request `info` spam.
  3. `FairQueue::stats()` snapshot (reads the FQ.1b read-only accessors
     under the lock) for tests and a future status endpoint.

**Acceptance criteria.**

  * Under a synthetic flood the per-flow `Busy` counter and active-flow
    gauge move as expected; no log flooding at `info`.
  * `stats()` is consistent under concurrent load.

**Risk.**  Low.  **Effort.**  ~0.5 engineer-day.

#### FQ.7a — Behavioural fairness tests

**Scope.**  New `runtime/knomosis-host/tests/fair_queue.rs` (uses
`MockKernel`).

**Implementation steps.**

  1. **Fairness under contention:** one "whale" connection floods; one
     "small" connection sends a few requests.  Assert each small request
     is served within `O(active_flows)` dispatches — never stuck behind
     the whale's backlog.  Assert on served-*order*, not wall-clock.
  2. **Targeted backpressure:** the whale saturates `per_flow_cap` and
     receives `Busy`; the small connection still enqueues and is served.
  3. **Work-conserving:** with only the whale active (no contention), it
     is served at full worker rate — no artificial throttle.
  4. **No-starvation bound:** with `K` active flows, every flow's head is
     served within `K` dispatches (assert the bound).

**Acceptance criteria.**

  * All four behaviours pass deterministically (seed randomness).

**Risk.**  Medium (timing flakiness).  Mitigate via logical-order
assertions over a controlled `MockKernel` dispatch cadence.  **Effort.**
~0.75 engineer-day.

#### FQ.7b — Stress, shutdown-under-load, FIFO parity

**Scope.**  `runtime/knomosis-host/tests/fair_queue.rs`.

**Implementation steps.**

  1. **Stress:** mirror RH-C.4's shape (many connections × many requests)
     on the `Drr` path; no OOM; correct verdicts.
  2. **Shutdown under load:** set `stop` mid-flood; assert clean drain,
     worker join, no lost in-flight replies, no hang.
  3. **FIFO parity:** the same workload on `--scheduler fifo` and
     `--scheduler drr` returns the same multiset of verdicts (Track A only
     reorders, never changes admissibility — §2.6(1)).

**Acceptance criteria.**

  * Stress green under `cargo test` + `ci-rust.yml`; shutdown test has no
    flaky hang; parity holds.

**Risk.**  Medium.  **Effort.**  ~0.75 engineer-day.

#### FQ.7c — Throughput-parity / perf-regression check

**Scope.**  `runtime/knomosis-host/` (a `criterion`-free microbench or a
`--scheduler`-parameterised reuse of `knomosis-bench`'s driver; no new
heavy dependency).

**Implementation steps.**

  1. Single-actor (one connection) throughput: `fifo` vs `drr`.  Since
     there is no contention, DRR's only overhead is the `Mutex`/`Condvar`
     versus the `sync_channel`.  Assert `drr` throughput is within a
     documented tolerance of `fifo` (target: ≥ 90 %).
  2. Confirm the §2.8 "dispatch outside the lock" property holds under
     load (a slow `MockKernel` must not serialise enqueues).
  3. Record numbers in the FQ.8 closeout note (like the RH-F
     observed-throughput disclosure), not as a hard CI gate (microbench
     numbers are machine-dependent).

**Acceptance criteria.**

  * `drr` single-actor throughput ≥ 90 % of `fifo` on the dev
    workstation; if below, the gap is root-caused (lock contention on the
    hot path) before FQ.8.

**Risk.**  Medium.  A global `Mutex` can throttle the producer side; this
WU exists to catch exactly that before it ships.  **Effort.**  ~0.5
engineer-day.

#### FQ.8 — Rung 0 documentation + closeout

**Scope.**  `src/lib.rs` docstring, `docs/abi.md` (note only),
`docs/gas_pool_runbook.md` (the fair-queuing-operations section — see
GP.8.3), `CLAUDE.md` + `AGENTS.md`, `README.md`, `runtime/Cargo.toml`,
`lakefile.lean`.

**Implementation steps.**

  1. Update the lib.rs threading-model docstring: the optional fair
     scheduler, its flags, the §2.6 invariants, the §2.8 model.
  2. `docs/abi.md`: note that Rung 0 introduces **no** wire-format change
     (host-internal only).
  3. Roadmap/status: keep the FQ row + workstream snapshot in `CLAUDE.md`
     / `AGENTS.md` (keep them byte-identical); record the FQ.7c throughput
     numbers in the snapshot.  Cross-link this unified plan from the FQ
     row.
  4. Patch-version bump in lockstep: `runtime/Cargo.toml`
     `[workspace.package] version`, `lakefile.lean` `package knomosis
     version`, `README.md` banner — same new patch value; commit the
     regenerated `Cargo.lock`.

**Acceptance criteria.**

  * Docs match shipped behaviour; `CLAUDE.md` ≡ `AGENTS.md`; versions
    agree across surfaces; `ci-rust.yml` green.

**Risk.**  Trivial.  **Effort.**  ~0.5 engineer-day.

#### Rung 0 — rolled-up acceptance criteria

  * `--scheduler drr` yields per-connection fairness: a flooding
    connection delays only itself; honest connections keep their share and
    enqueue capacity.
  * Work-conserving: no throttle absent contention; single-actor
    throughput within 90 % of FIFO (FQ.7c).
  * No admissibility behaviour changes; FIFO remains the unchanged
    default; verdict-multiset parity holds (FQ.7b).
  * All four §2.6 invariants and the §2.8 concurrency contract hold; the
    DRR decision is deterministic, I/O-free, and unit + property tested.
  * Full `ci-rust.yml` gate green; version surfaces lockstepped.

### Rung 1 — signer-hint header + two-tier DRR (version-gated)

#### FQ.9 — Wire-format amendment + `docs/abi.md` §10 + frame ceiling

**Scope.**  `docs/abi.md` §10, `runtime/knomosis-host/src/lib.rs`
(`PROTOCOL_VERSION`), `src/frame.rs` (the hard ceiling constant).

**Implementation steps.**

  1. Define the optional per-frame signer-hint.  A Rung-1 client opens the
     connection with a 4-byte magic preamble (`b"KNH2"`); thereafter every
     request is `[8-byte signer-hint][4-byte BE length][payload]`.  A
     legacy client sends no preamble; its first 4 bytes are the v1 length
     prefix.
  2. **Collision-proof disambiguation (the crux).**  The host peeks the
     first 4 bytes of a connection: equal to the magic ⇒ Rung-1 hinted
     connection; otherwise ⇒ legacy.  This is sound **iff** no valid v1
     length can equal the magic's big-endian u32 value.  `b"KNH2"` =
     `0x4B4E4832` = 1 263 421 490 ≈ 1.26 × 10⁹ bytes (≈ 1.18 GiB).  This
     rung therefore pins a compile-time **`HARD_MAX_FRAME_SIZE` strictly
     below the magic value** (e.g. 256 MiB = 268 435 456, comfortably
     below) and rejects/clamps `--max-frame-size` above it, so a legal v1
     length can never collide with the magic.  State this invariant
     explicitly in `abi.md`.
  3. Bump `PROTOCOL_VERSION` 1 → 2; document that v2 is a superset (v1
     connections remain valid and get Rung-0 fairness).
  4. Specify the hint is **advisory**: the kernel authoritatively reads
     the real signer from the CBE body and verifies the signature; the
     hint never affects admissibility (restate §2.6(1)/(2)).

**Acceptance criteria.**

  * `docs/abi.md` §10 unambiguously specifies the preamble, the per-frame
    layout, the disambiguation rule, the `HARD_MAX_FRAME_SIZE < magic`
    invariant, and the advisory/untrusted status of the hint.
  * `PROTOCOL_VERSION == 2`; the version test updated; the ceiling
    constant has a unit test asserting `HARD_MAX_FRAME_SIZE < magic`.

**Risk.**  Medium.  The collision argument is the load-bearing
correctness claim; it must be pinned by the ceiling constant + test, not
left implicit.  **Effort.**  ~1.0 engineer-day.

#### FQ.10a — Connection negotiation state machine

**Scope.**  `runtime/knomosis-host/src/listener.rs`, `src/frame.rs`.

**Implementation steps.**

  1. Per accepted connection, perform the one-time 4-byte magic peek
     (FQ.9 step 2) and record a `hinted: bool` on the connection's read
     state.
  2. If the 4 bytes equal the magic, consume them and set `hinted = true`.
     Otherwise set `hinted = false` and treat those 4 bytes as the first
     frame's length prefix (do not lose them — feed them into the v1 read
     path).
  3. A connection's `hinted` decision is fixed for its lifetime (no
     mid-connection renegotiation).

**Acceptance criteria.**

  * A v2 connection is detected; a v1 connection's first frame is read
    intact (no dropped/duplicated bytes).
  * Assorted leading-byte sequences classify correctly; values `>=
    HARD_MAX_FRAME_SIZE` that are not the magic are rejected as
    over-length (unchanged v1 behaviour).

**Risk.**  Medium.  Off-by-one between the peeked magic and the v1 length
path.  **Effort.**  ~0.5 engineer-day.

#### FQ.10b — Per-frame hint extraction

**Scope.**  `runtime/knomosis-host/src/frame.rs`, `src/listener.rs`.

**Implementation steps.**

  1. On a `hinted` connection, read the bounded 8-byte hint before each
     length prefix; never read beyond it into the CBE body.
  2. Surface the hint (or, for a legacy connection, a per-connection
     constant) to the submit call site as the inner routing key.
  3. A malformed/truncated hint is a `ParseError` before any body
     allocation.

**Acceptance criteria.**

  * Hinted frames: hint extracted; payload bytes byte-identical to the
    non-hinted case.
  * Fuzz: random leading bytes never panic and never mis-read the CBE body
    as a hint.

**Risk.**  Medium.  **Effort.**  ~0.5 engineer-day.

#### FQ.11a — Tier-parameterised core + `ConnBucket`

**Scope.**  `runtime/knomosis-host/src/fair/drr.rs` (generalise FQ.1a/1b;
one DRR implementation, not two).

**Implementation steps.**

  1. Refactor the FQ.1 single-tier logic into a reusable inner-tier
     `Tier<K>` (the `flows`/`active`/`enqueue`/`pick`/eviction logic), so
     both tiers share one implementation.
  2. `ConnBucket = Tier<SignerHint>` plus an outer `deficit`/`depth`; the
     two-tier `DrrState` is `Tier<ConnId>` whose per-key payload is a
     `ConnBucket`.
  3. `enqueue(conn, signer, req)` routes through the outer tier to the
     connection's inner tier; outer `max_flows` bounds distinct
     connections, a new per-connection `max_signers` (FQ.12) bounds inner
     flows; empty inner ⇒ evict signer; empty connection ⇒ evict conn.

**Acceptance criteria.**

  * The single-tier tests (FQ.1b/1c) still pass against the extracted
    `Tier<K>` (proving the refactor is behaviour-preserving).
  * Two-tier `enqueue` accounting + eviction correct at both tiers.

**Risk.**  Medium.  The refactor must not regress the single-tier
behaviour; run FQ.1's suite against `Tier<K>` unchanged.  **Effort.**
~0.75 engineer-day.

#### FQ.11b — Two-tier `pick` + spoof-confinement property

**Scope.**  `runtime/knomosis-host/src/fair/drr.rs`.

**Implementation steps.**

  1. `pick` runs DRR at the **outer** tier across connections; on a
     connection's turn it runs the inner `Tier<SignerHint>::pick` for one
     served request, then rotates connections.  Empty inner ⇒ evict
     signer; empty conn ⇒ evict conn.
  2. **Spoof-confinement property test (the §2.6(2) guarantee):** a
     connection spawning `M` distinct (possibly forged) hints receives
     only its single outer share, subdivided among its `M` — never more
     than a one-hint connection's share.
  3. Inner-fairness test: within one connection, its signer-hints are
     served round-robin.

**Acceptance criteria.**

  * Outer fairness: two connections each get ~1/2 the worker regardless of
    how many hints each multiplexes.
  * Spoof-confinement property holds across randomised interleavings.
  * No `unsafe`; no `panic`; `clippy::pedantic` clean.

**Risk.**  Medium.  Nested activation/eviction; the spoof-confinement
property test is the key guard.  **Effort.**  ~0.75 engineer-day.

#### FQ.12 — `FairQueue` two-tier wiring + per-signer caps

**Scope.**  `runtime/knomosis-host/src/queue.rs`, `src/config.rs`.

**Implementation steps.**

  1. Extend `FairQueue::try_submit` to `(conn, signer_hint, payload)`
     routing through the two-tier `DrrState`; extend `QueueHandle`'s
     `Fair` arm + the handler call site accordingly (legacy connections
     pass a constant hint ⇒ one inner flow ⇒ Rung-0 behaviour).
  2. Add `--max-signers-per-conn` (default 256) + `Config` field +
     `ConfigError` validation; plumb into the outer tier's per-connection
     `max_signers`.  Breach ⇒ targeted `Busy` to the offending connection
     only (bounds the Rung-1 scheduler-DoS surface, §2.6(4)).

**Acceptance criteria.**

  * Two-tier routing works end-to-end with `MockKernel`.
  * `--max-signers-per-conn` enforced; breach is targeted `Busy`.
  * A legacy (un-hinted) connection still behaves exactly as Rung 0.

**Risk.**  Low–medium.  **Effort.**  ~1.0 engineer-day.

#### FQ.13a — Client emitter: `knomosis-l1-ingest`

**Scope.**  `runtime/knomosis-l1-ingest/src/submitter.rs` (the path that
forwards to `knomosis-host`, if/where the ingestor submits there).

**Implementation steps.**

  1. Add an opt-in "emit signer-hint" mode (config/flag, default OFF): on
     connection open send the `KNH2` preamble; per frame prepend the
     8-byte hint (the signer `ActorId` the submitter already holds).
  2. Default OFF emits legacy v1 frames byte-identically (no regression).

**Acceptance criteria.**

  * Hinting ON: frames carry preamble + hint; OFF: byte-identical to
    today.  New tests cover the hinted path; existing tests pass.

**Risk.**  Low–medium.  **Effort.**  ~0.5 engineer-day.

#### FQ.13b — Client emitter: `knomosis-faultproof-observer`

**Scope.**  `runtime/knomosis-faultproof-observer/src/{submitter,
jsonrpc_submitter}.rs` (whichever speak the `knomosis-host` wire format;
the L1 JSON-RPC submitter is unaffected).

**Implementation steps.**

  1. Same opt-in hint emission as FQ.13a for any path that submits to
     `knomosis-host`.
  2. Default OFF; legacy behaviour preserved.

**Acceptance criteria.**

  * Hinted/legacy parity as FQ.13a; observer tests pass.

**Risk.**  Low–medium.  **Effort.**  ~0.5 engineer-day.

#### FQ.13c — Client emitter: `knomosis-bench`

**Scope.**  `runtime/knomosis-bench/`.

**Implementation steps.**

  1. Add a `--emit-hints` knob so the throughput harness exercises the
     two-tier path; default OFF.
  2. Lets FQ.14/FQ.7c measure hinted vs legacy throughput.

**Acceptance criteria.**

  * Hinted mode drives per-signer routing; bench numbers comparable across
    modes; existing bench tests pass.

**Risk.**  Low.  **Effort.**  ~0.5 engineer-day.

#### FQ.14a — Rung 1 fairness + spoof-resistance (end-to-end)

**Scope.**  `runtime/knomosis-host/tests/fair_queue.rs` (extend).

**Implementation steps.**

  1. **Two-tier fairness:** one connection multiplexing many signer-hints
     does not starve a second connection.
  2. **Spoof-resistance (end-to-end):** connection C floods with hints
     spoofing victim V's id; the real V on connection C' sends one request
     and is served within the bounded outer cycle — unaffected by C's
     flood.  (The end-to-end counterpart to FQ.11b's unit property.)

**Acceptance criteria.**

  * Both behaviours pass deterministically against `MockKernel`.

**Risk.**  Medium.  **Effort.**  ~0.75 engineer-day.

#### FQ.14b — Wire back-compat / negotiation interop

**Scope.**  new `runtime/knomosis-host/tests/wire_compat.rs`.

**Implementation steps.**

  1. **Back-compat:** a legacy (v1) client and a v2 client on separate
     connections both work against one host; the legacy one gets Rung-0
     fairness.
  2. **Negotiation robustness:** assorted leading-byte sequences classify
     correctly (magic vs length); a non-magic value `>=
     HARD_MAX_FRAME_SIZE` is rejected as over-length; the
     `HARD_MAX_FRAME_SIZE < magic` invariant is asserted.
  3. **Mixed load:** v1 and v2 connections concurrently; verdicts correct
     for both.

**Acceptance criteria.**

  * v1/v2 interop proven against the same host instance; negotiation never
    mis-parses; green under `ci-rust.yml`.

**Risk.**  Medium.  This suite is the evidence that §2.6(3) + the FQ.9
collision argument hold in practice.  **Effort.**  ~0.75 engineer-day.

#### FQ.15 — Rung 1 documentation + closeout

**Scope.**  `docs/abi.md` §10 (finalise), `src/lib.rs`, `CLAUDE.md` +
`AGENTS.md`, `README.md`, client `README`s, `runtime/Cargo.toml`,
`lakefile.lean`.

**Implementation steps.**

  1. Finalise `docs/abi.md` §10 with the shipped v2 layout + negotiation +
     the `HARD_MAX_FRAME_SIZE` invariant + advisory semantics.
  2. Update lib.rs + roadmap rows + workstream snapshot (CLAUDE.md ≡
     AGENTS.md); document the client opt-in flags in their READMEs.
  3. Patch-version bump across all surfaces in lockstep (the
     `PROTOCOL_VERSION` bump already landed in FQ.9); commit `Cargo.lock`.

**Acceptance criteria.**

  * ABI doc matches shipped behaviour; docs/versions consistent;
    `ci-rust.yml` green.

**Risk.**  Trivial.  **Effort.**  ~0.5 engineer-day.

#### Rung 1 — rolled-up acceptance criteria

  * Hinted (v2) connections get per-(connection, signer) fairness; legacy
    (v1) connections transparently get Rung-0 fairness on the same host.
  * Forged hints are confined to the forging connection's own outer share
    (§2.6(2)), proven by FQ.11b (unit) + FQ.14a (end-to-end).
  * No admissibility behaviour changes; the hint is advisory only.
  * `PROTOCOL_VERSION == 2`; v1/v2 interoperate; the `HARD_MAX_FRAME_SIZE
    < magic` collision invariant is pinned by a test; version surfaces
    bumped in lockstep.

## §5 Track B — Reimbursement claims

Track B is the optimised, code-grounded successor of the original
GP.8.1.  Two corrections over the v1.5 sketch:

  * **Signing model.**  The sketch said the claim is "signed by the
    sequencer's pool-control key (a separately registered key with
    authority over `gasPoolActor` via a deployment-specific policy
    override)".  The shipped GP.7.2 model has no such delegation: the
    pool moves its own funds, so the claim's `signer` **is**
    `gasPoolActor`, signed by the key registered to `ActorId 1` (held by
    the sequencer operator).  `gasPoolAuthorityPolicy` enforces `sender =
    gasPoolActor`; a "policy override" granting a third actor authority
    over the pool does not exist and is not needed.  This plan specifies
    the correct shape (§2.9).
  * **Granularity.**  The 8-hour WU is split into three 2–3 h sub-WUs
    matching the GP-plan convention, plus a deferred v2 forward unit.

#### WU GP.8.1a — Sequencer-claim core (`sequencer_claim.rs`)

  * **Goal.**  A small, testable helper that constructs the canonical
    claim action and the framed `SignedAction` request bytes the
    sequencer submits to `knomosis-host`.
  * **Files.**
    * `runtime/knomosis-host/src/sequencer_claim.rs` (**new** — confirmed
      absent today).
    * `src/lib.rs` (`pub mod sequencer_claim;`).
  * **Deliverables.**
    * A `ClaimLeg { resource: u64, amount: u64 }` and a
      `build_claim(leg, nonce) -> Action::Transfer { resource,
      sender: GAS_POOL_ACTOR_ID (1), recipient: SEQUENCER_ACTOR_ID (2),
      amount }` constructor, reusing the `knomosis-l1-ingest::encoding`
      CBE primitives so the emitted bytes are cross-stack-equivalent to
      Lean's `Encoding.Action.encode` (the same discipline FQ.13 and
      `knomosis-bench` follow).
    * A pure `estimate_claimable(spent_wei, price, cap) -> u64` that
      clamps the operator's L1-gas estimate to `gasPoolPolicy`'s per-leg
      `maxDrainPerAction{Eth,Bold}` cap (the v1 honour-system bound is
      *the cap*, so the helper makes over-cap requests impossible to
      construct rather than relying on the host to reject them).
    * The two reserved-actor id constants imported from / cross-checked
      against `knomosis-l1-ingest` (`GAS_POOL_ACTOR_ID = 1`,
      `SEQUENCER_ACTOR_ID = 2`) so the genesis-3 reservation (GP.7.1)
      stays consistent across crates.
  * **Tests.**  ~6 cases: per-leg construction (ETH / BOLD); the clamp at
    exactly the cap, below the cap, and above (clamped down); a CBE
    round-trip / byte-pin against a known vector; `sender == recipient`
    is *never* produced (the pool never pays itself); a zero-amount claim
    is rejected at construction (no point submitting a no-op).
  * **Acceptance criteria.**  One reviewer.  `cargo
    build/test/clippy -D warnings/fmt` clean.  The constructor cannot
    emit an action `gasPoolPolicy` would reject for shape (wrong tag,
    wrong recipient, wrong sender) — only the *amount honesty* is left to
    the operator, by design.
  * **Dependencies.**  GP.7.4 (the policy is genesis-ratified), GP.6.1
    (the Rust CBE encoder mirror it reuses).
  * **Estimated effort.**  ~3 hours.

#### WU GP.8.1b — Signing + pool-key wiring + periodic driver

  * **Goal.**  Sign the claim with the `gasPoolActor` key and submit it on
    a cadence.
  * **Files.**
    * `runtime/knomosis-host/src/sequencer_claim.rs` (extend).
    * `runtime/knomosis-host/src/main.rs` (CLI flags + the periodic
      driver).
  * **Deliverables.**
    * Reuse `knomosis-l1-ingest::key::BridgeActorKey` (the
      `Zeroizing`-protected, low-s `(r ‖ s)` secp256k1 signer) to sign
      the claim's `SignInput` as the `gasPoolActor` key — i.e. the
      operator supplies the pool key via a keystore path, exactly as the
      bridge actor key is supplied today.  Name the wrapper neutrally
      (`PoolControlKey`) — it is the `gasPoolActor` key, not a distinct
      "override" identity.
    * A periodic claim driver: every `--claim-interval-seconds` (or on an
      operator-triggered one-shot subcommand `knomosis-host claim
      --eth <wei> --bold <wei>`), construct → sign → submit the claim
      frame to the configured `knomosis-host` listener, log the verdict.
      The driver is opt-in (absent flags ⇒ no claims; the pool simply
      accrues).
    * CLI flags: `--pool-key-keystore <path>`, `--sequencer-listen <addr>`
      (where to submit), `--claim-interval-seconds <n>`,
      `--claim-eth-cap <wei>` / `--claim-bold-cap <wei>` (the operator's
      local mirror of `gasPoolPolicy`'s caps, for the GP.8.1a clamp).
  * **Tests.**  ~5 cases: sign→verify round-trip with a test key; the
    driver builds the right frame for a given `(eth, bold)` spend; the
    one-shot subcommand parses; absent flags ⇒ zero claims emitted; a
    submit that returns `NotAdmissible` is logged, not retried in a tight
    loop (no claim-storm on a misconfigured cap).
  * **Acceptance criteria.**  One reviewer.  The pool key never leaves the
    `Zeroizing` wrapper; no key material in logs.  On a host running the
    budget gate, the driver provisions / assumes `gasPoolActor`'s budget
    per the §2.9 provisioning requirement (a claim consumes one
    action-cost unit of `gasPoolActor`'s budget; `freeTier ≥ 1` is
    required and an over-budget claim is logged as `InsufficientBudget`,
    not retried in a tight loop).
  * **Dependencies.**  GP.8.1a; GP.6.2 (the claim is admitted through the
    budget gate when enabled — `gasPoolActor` is not budget-exempt, §2.9).
  * **Estimated effort.**  ~3 hours.

#### WU GP.8.1c — Claim tests + ABI documentation

  * **Goal.**  End-to-end coverage against a mock host + the wire-level
    documentation.
  * **Files.**
    * `runtime/knomosis-host/tests/sequencer_claim.rs` (**new**).
    * `docs/abi.md` (extend §10, or add §11C "Sequencer claim").
  * **Deliverables.**
    * An end-to-end test: stand up a `MockKernel`-backed host that admits
      `gasPoolActor → sequencerActor` transfers and rejects anything else;
      drive the GP.8.1b driver against it; assert the pool balance moves
      to the sequencer by exactly the claimed (clamped) amount on each
      leg, and that an over-cap request is clamped *before* submission
      (never reaches the host as a rejection).
    * A negative test: a claim with a tampered recipient (not
      `sequencerActor`) is `NotAdmissible` (the host's kernel rejects it
      under `gasPoolPolicy`) — proving the safety boundary §2.6(5) holds
      end-to-end.
    * `docs/abi.md`: document the claim as a normal framed `SignedAction`
      (no new wire shape), name the canonical action
      (`transfer`, `gasPoolActor → sequencerActor`), state explicitly that
      v1 is **honour-system within `capAmount`**, and forward-reference
      GP.8.5 for the v2 receipt-verified gate.
  * **Tests.**  ~4 cases (the two above + a both-legs-in-one-cycle case +
    a host-`Busy` backpressure case proving the driver tolerates a full
    queue without dropping the claim silently).
  * **Acceptance criteria.**  One reviewer; documentation explicit that
    v1 is honour-system bounded by `capAmount`, and that the *shape* is
    nevertheless fully kernel-governed (GP.7.2 theorems cited).
  * **Dependencies.**  GP.8.1b.
  * **Estimated effort.**  ~2 hours.

#### WU GP.8.5 — Receipt-verified claim (v2) — DEFERRED

  * **Status.**  **Deferred / out of scope for v1.**  Specified here so it
    can be picked up without re-litigating the design; it replaces the
    vague "v2 mechanism" references scattered through
    `unified_gas_pool_plan.md` with one concrete home.
  * **Goal.**  Make the claimed `amount` cryptographically provable, so
    the honour-system trust assumption of §2.9 is retired.
  * **Sketch.**
    * The sequencer's state-root submissions are L1 transactions with
      on-chain gas receipts.  Introduce an L1 receipt-proof surface (same
      opaque-verifier trust pattern as the fault-proof
      `l1FaultProofVerifier` in `LegalKernel/FaultProof/Witness.lean`)
      attesting "`sequencerActor` spent `G` wei of L1 gas on state-root
      submissions in block range `[a, b]`".
    * Gate the claim's admissibility on `amount ≤ priceOf(G)` for a
      deployment-supplied ETH/leg price oracle, so a claim exceeding the
      proven spend is *inadmissible*, not merely disputable.
    * **Forward-compatibility.**  v2 adds a *gate*, not a new action: the
      v1 claim shape is unchanged, v1 claims stay valid, and v2 simply
      refuses to admit ones that exceed the proven spend.  No `Action`
      constructor index changes.
  * **Why deferred.**  It needs (a) an L1 receipt-proof surface and (b) a
    price oracle — each larger than the entire v1 deliverable, and
    neither operationally pressing while the cap + dispute pipeline bound
    the loss.  Track as `OQ-GP-8b` in `docs/planning/open_questions.md`
    (sibling to the existing OQ-GP-8 dynamic-fee question).
  * **Dependencies.**  GP.8.1c; an L1 receipt-proof surface (new); a price
    oracle (new).
  * **Estimated effort.**  Not estimated (v2 workstream).

## §6 Track C — Configuration (free-tier / epoch policy)

#### WU GP.8.2 — Free-tier / epoch policy: guidance + action-clock decision

This WU is substantially **smaller than the original GP.8.2 sketch**,
because grounding it against the code revealed the flags it proposed to
"expose" are already shipped.

##### §6.1 What already ships (GP.6.2)

`knomosis-host` already exposes the per-actor budget admission gate and
its configuration (`runtime/knomosis-host/src/{config,budget}.rs`):

| Flag                  | Meaning                                                     |
| --------------------- | ---------------------------------------------------------- |
| `--budget-policy bounded` | Enable the GP.6.2 per-actor budget admission gate.     |
| `--free-tier <N>`     | Per-epoch budget floor (the original GP.8.2 deliverable).  |
| `--action-cost <C>`   | Per-action budget debit (clamped `>= 1`; default 1).       |
| `--current-epoch <E>` | Current epoch index (default 0; the free tier needs E ≥ 1).|
| `--epoch-length <N>`  | Admitted actions per budget epoch (0 = no advancement).    |

So the original GP.8.2 line item "expose `--free-tier`" is **done**.
What remains is (a) the operational guidance for choosing the values,
and (b) one genuine design decision the sketch got wrong.

##### §6.2 The genuine deliverable: operational guidance

Add a runbook subsection (landed as part of GP.8.3, §7) that explains how
to set the budget policy from:

  * **deposit volume** — a higher steady deposit rate sustains a higher
    `freeTier` (more pool inflow to drain against);
  * **the sequencer's L1 budget** — `freeTier × admittedActorCount` per
    epoch must stay within what the sequencer can afford to sequence for
    free (cross-link the Appendix-B attack-tree row 2 bound);
  * **acceptable user-facing latency** — a longer `--epoch-length`
    smooths replenishment but lengthens the window before a throttled
    actor recovers its free tier.

Pin the cross-link to GP.6.4's indexer view: an operator monitors the
`InsufficientBudget` rejection rate (alert > 5 %) to tell whether
`freeTier` is too low for current usage (Track D, §7).

##### §6.3 The design decision: keep the action-clock epoch (correct the sketch)

The original GP.8.2 proposed a flag named `--epoch-duration-seconds`
(a **wall-clock** epoch).  The shipped model is an **action-clock** epoch:
`--epoch-length N` advances the epoch every `N` admitted actions, where
the advance is *a deterministic function of the log index*
(`epoch = logIndex / epochLength`), so deterministic replay reproduces
every epoch exactly.  This is backed by the `replay_deterministic`
theorem (`LegalKernel/Runtime/Replay.lean`) and the
`replenishment_via_epoch_advance` theorem
(`LegalKernel/Authority/SignedAction.lean`), and exercised end-to-end at
value level by the `epochAdvanceReplenishesAndReplays` test
(`LegalKernel/Test/Runtime/LoopHappyPath.lean`); the indexer mirrors the
formula via the `epoch_for_seq(seq) = (seq − 1) / epoch_length` function
(`runtime/knomosis-indexer/src/budget_view.rs`).

A wall-clock epoch would **break replay determinism**: re-running the log
later would land actions in different epochs (different budgets, different
admit/reject verdicts), so the off-chain truth oracle, the indexer, and
the fault-proof observer could disagree with the sequencer on whether an
action was admitted.  That is a regression of a load-bearing property the
GP.6.2 post-audit specifically established.

**Decision.**  Keep the action-clock model; expose it with clearer
operator guidance; treat a wall-clock epoch as an **explicit non-goal**
(§9) with the replay caveat recorded.  If a deployment genuinely needs
wall-clock semantics, it can approximate them by choosing `--epoch-length`
≈ (target seconds × observed admit rate), accepting that the mapping is
load-dependent — but it must not introduce a real clock into the admission
path.  Record this as the resolution of the dangling
`--epoch-duration-seconds` reference; no such flag is added.

  * **Files.**  `runtime/knomosis-host/README.md` (document the shipped
    flags + the action-clock rationale), `docs/gas_pool_runbook.md` (the
    guidance, via GP.8.3).
  * **Tests.**  ~3 cases (mostly already covered by GP.6.2's suite): the
    README flag table matches the parser; a documentation test or a small
    assertion that no `--epoch-duration-seconds` flag exists (so the
    sketch's name cannot silently reappear); the guidance example values
    parse.
  * **Acceptance criteria.**  One reviewer.  No new admission-path
    behaviour (the gate is unchanged); the only code change is
    documentation + possibly a help-text clarification.
  * **Dependencies.**  GP.6.2 (Complete).
  * **Estimated effort.**  ~3 hours.

## §7 Track D — Operations (operator runbook)

Track D extends the **existing** `docs/gas_pool_runbook.md` (which already
covers the GP.5.5 BOLD safety surface).  The original GP.8.3 listed the
file as "new"; it is not — these WUs add sections to it.  Two new things
the unification contributes: a **sequencer-claim operations** section
(Track B) and a **fair-queuing operations** section (Track A) that the
original GP.8.3 lacked because FQ was a separate document.

#### WU GP.8.3 — Operator runbook: baseline sequencer sections

  * **Goal.**  The day-one operator sections for running a GP-enabled
    sequencer.
  * **File.**  `docs/gas_pool_runbook.md` (extend; **not** new).
  * **Deliverables (new sections, additive to the GP.5.5 content).**
    1. **Deployment checklist.**  `minFeeBps`, `maxFeeBps`,
       `weiPerBudgetUnit{Eth,Bold}`, `freeTier`, `epochLength`,
       `gasPoolActor` `LocalPolicy` parameters
       (`maxDrainPerAction{Eth,Bold}`), and the two reserved actor keys
       (`gasPoolActor` / `sequencerActor`) the operator must hold.
       **Pool-actor provisioning (claim prerequisite, §2.9).**  Register
       the `gasPoolActor` key in the key registry (so it can sign claims)
       and run with `freeTier ≥ 1`: `gasPoolActor` is *not* budget-exempt,
       so each claim consumes one action-cost unit of its per-epoch
       budget, and the deny-by-default genesis (`freeTier = 0`) would
       reject every claim.  Size `freeTier` (or plan `topUpActionBudget`s)
       so the per-epoch claim count stays within `gasPoolActor`'s budget.
    2. **`weiPerBudgetUnit` calibration.**  Typical range `[10⁹, 10¹⁵]`;
       choose so one budget unit costs ~$0.001–$0.01 in equivalent ETH at
       deployment time (so a UI can show "your N budget units ≈ $X of
       service").  Note the action-clock epoch model (§6.3) when relating
       budget to wall-clock spend.
    3. **Sequencer-claim operations (Track B).**  How to run the GP.8.1
       claim driver: key custody for the `gasPoolActor` key, the
       `--claim-interval-seconds` cadence, the per-leg cap mirror, and the
       honour-system caveat (claim only what you spent; the cap and the
       dispute pipeline bound abuse, §2.9).  Health check: pool balance
       should trend toward the sequencer at roughly the L1-gas-spend rate;
       a pool that only grows means the operator is under-claiming, one
       that hits the cap every epoch means caps are too tight or spend is
       too high.
    4. **Fair-queuing operations (Track A).**  When to enable
       `--scheduler drr` (multi-tenant hosts where one actor's burst can
       starve others), the cap flags (`--per-flow-cap`, `--max-flows`,
       and Rung-1 `--max-signers-per-conn`), the Rung-1 wire negotiation
       (clients opt in via the `KNH2` preamble; legacy clients keep
       working), and the FQ.6 observability counters to watch (per-flow
       `Busy` rate, active-flow gauge).  Note the topology decision (§2.5):
       if users funnel through one upstream connection, fairness must run
       at *that* upstream sequencer (the same DRR module), not only at the
       host.
    5. **Health checks.**  Pool balance trajectory per leg, claim
       frequency, `InsufficientBudget` rejection rate, per-flow `Busy`
       rate.
    6. **Failure-mode response.**  Pool drained (raise caps / pause
       claims / investigate spend), free-tier too low (raise `freeTier`),
       attacker flooding (enable `--scheduler drr`; tighten caps).
    7. **Migration note.**  Cross-link GP.10.4 (`gas_pool_migration_guide.md`)
       for legacy → GP-enabled migration, including the GP.7.1 reserved-id
       (`ActorId 1`/`2`) reservation.
  * **Acceptance criteria.**  One reviewer.
  * **Dependencies.**  GP.8.1c (claim ops), GP.8.2 (config guidance),
    FQ.8 (so the fair-queuing section documents a shipped Rung-0 feature).
  * **Estimated effort.**  ~6 hours.

#### WU GP.8.4 — Operator runbook: v1.3+ mechanism expansion

  * **Goal.**  Expand the runbook to cover the v1.3+ mechanism additions
    (multi-resource pool with BOLD, embedded AMM, Liquity-V2
    branch-shutdown circuit breaker, delegated top-ups) and the v1.4
    hardening (AMM disaster recovery, gas benchmarks).
  * **File.**  `docs/gas_pool_runbook.md` (extend further).
  * **Deliverables (additive sections).**
    1. **Multi-resource deployment checklist (BOLD).**  Pre-deploy: verify
       the canonical Liquity-V2 BOLD address + the three TroveManager
       pins on the target chain.  Constructor-argument table with the
       USD-parity formula `weiPerBudgetUnitBold = weiPerBudgetUnitEth ×
       usdPerEth / usdPerBold`.  `ammSeedRatioBps`: start at 3000 (30 %),
       observe AMM depth vs claim rate, adjust via `KnomosisMigration` if
       needed.  `enableLiquityAutoCircuitTrigger`: typically `true` for
       production, `false` for staging/testnet.  (Cross-link the existing
       §3–§5 BOLD-circuit / TVL-cap content already in the runbook.)
    2. **AMM operational guidance.**  Arbitrage-health monitoring (spot
       `ammReserveEth / ammReserveBold` vs external ETH/BOLD price ≥
       hourly; > 1 % drift is a signal); swap-volume monitoring via
       `AmmSwapExecuted`; fee-revenue tracking from `k = R_eth × R_bold`
       growth.
    3. **Liquity-V2 branch-shutdown trigger operations.**  Path A
       (manual: monitor each TroveManager's `shutdownTime()`); Path B
       (auto: anyone calls `closeBoldCircuitIfAnyLiquityBranchShutdown()`);
       re-open procedure (the monotonic-`shutdownTime` risk-acceptance
       decision).  (This refines / supersedes the v1.3 redemption-rate
       sketch — cross-link the runbook's existing §4 which already
       documents the shipped branch-shutdown trigger.)
    4. **AMM disaster recovery.**  Conditions to invoke
       `emergencyDisableAmm()` (GP.11.10); the within-7-days post-mortem
       decision tree (redeploy via `KnomosisMigration` vs degraded mode
       with external L1 DEXes for ETH↔BOLD, documenting the MEV-cost
       increase per claim).
    5. **Gas-cost projections.**  MEASURED baseline numbers from
       GP.11.9 (landed — the generated table in
       `docs/gas_pool_runbook.md` §9.2 is the canonical source,
       CI-gated via `solidity/test/BenchmarkGasV1_3.gas-baseline.json`).
       Measured user-tx envelopes (forge isolated mode — full
       transaction gas, refunds netted): depositETHWithFee ~49–66k;
       depositBoldWithFee ~77–94k; ammSwap ETH→BOLD ~59–76k; BOLD→ETH
       ~68–70k; closeBoldCircuit ~45k;
       closeBoldCircuitIfAnyLiquityBranchShutdown ~54k (ETH-branch
       fast close) to ~69k (last-branch close), ~47k for the
       no-shutdown 3-branch keeper probe; migration-wired deployments
       add ~3.1k per circuit-gated operation; the withdrawWithProof
       exit legs ~861–878k (the round trip's dominant cost).  UI guidance: estimated bridge-gas cost at
       current gas price by chosen fee currency.
    6. **Delegated-top-up deployment guidance.**  Recipients opt in via
       `Action.declareLocalPolicy` with an `allowTopUpFrom` clause
       (default-deny, GP.3.4); the service-provider integration pattern;
       the `Action.revokeLocalPolicy` revocation procedure.
    7. **Monitoring + alerting checklist.**  AMM reserve depth (alert if
       either < `MIN_VIABLE_DEPTH_USD` = $10 000); per-resource pool
       balance (alert on > 50 % deviation from the rolling 7-day average);
       claim frequency (alert on zero claims for > 48 h — pool starved or
       sequencer down); `InsufficientBudget` rate (> 5 %); any
       `LiquityV2ReadFailed` (integration drift); circuit-breaker state
       (`BoldCircuitClosed`).  Plus the Track-A counters from GP.8.3's
       fair-queuing-operations section (per-flow `Busy` rate,
       active-flow gauge).
  * **Acceptance criteria.**  Two reviewers (one engineering, one
    operations); reviewed by an actual deployment operator if available.
  * **Dependencies.**  GP.8.3; GP.11.{3,4,9,10}.
  * **Estimated effort.**  ~14 hours.

## §8 Risks and mitigations

| #  | Track | Risk | Mitigation |
| -- | ----- | ---- | ---------- |
| 1  | A | `Condvar` shutdown wake/drain causes a hang or a lost in-flight reply | Mirror the proven FIFO `worker_loop` exactly: stop-flag + 100 ms poll + non-blocking final drain; optional `notify_all`; kill-during-load test (§2.8, FQ.4b, FQ.7b) |
| 2  | A | DRR activation/eviction bug starves or double-serves a flow | Pure core isolated in `src/fair/drr.rs` with unit + property + fuzz tests, incl. the equal-weight fairness bound (FQ.1b/1c) |
| 3  | A | The global scheduler `Mutex` regresses throughput vs the near-lock-free `sync_channel` | Dispatch happens outside the lock (§2.8); FQ.7c measures single-actor `drr` vs `fifo` and gates on ≥ 90 % parity or a root-cause |
| 4  | A | Wire negotiation mis-classifies a legacy frame as hinted (or vice-versa) | `HARD_MAX_FRAME_SIZE < magic` invariant pinned by a constant + test; per-connection state machine (FQ.10a); fuzz + interop suite (FQ.14b) |
| 5  | A | Hint spoofing lets an actor steal another's share | Two-tier structure confines a forged hint to the forger's own outer share; property test (FQ.11b) + end-to-end test (FQ.14a); §2.6(2) |
| 6  | A | Scheduler maps grow unboundedly (flow-count DoS) | `max_flows`, per-conn `max_signers`, immediate empty-flow eviction (FQ.1a, FQ.5, FQ.12); §2.6(4) |
| 7  | A | Flaky timing-based fairness assertions | Assert logical served-order / exactly-once / bounds, not wall-clock; seed all randomness (FQ.1c, FQ.7a, FQ.14a) |
| 8  | A | Two-tier refactor regresses the single-tier behaviour | FQ.11a runs FQ.1's unchanged suite against the extracted `Tier<K>` |
| 9  | A | Fairness is meaningless if all users funnel through one upstream sequencer connection | Resolved topology note (§2.5): the sequencer *is* the contention point and runs the same DRR module; a deployment fact, not a code defect |
| 10 | All | A scheduling / claim change is perceived as weakening the proof-carrying story | §2.1 layering: safety stays in the kernel; Track A is a liveness layer and Track B is a kernel-*governed* action; default-OFF flag + cap-bounded claim keep the baseline intact |
| 11 | B | A buggy claim tool over-claims and drains the pool | The claim's *shape* is kernel-governed (only `transfer`, only to `sequencerActor`, only the pool's own funds, capped per leg — §2.9); GP.8.1a makes over-cap requests unconstructible; the GP.7.3 per-trace bound + dispute pipeline bound residual honour-system abuse |
| 12 | B | The pool key is mishandled / leaked | Reuse the `Zeroizing` `BridgeActorKey` discipline (GP.8.1b); no key material in logs; key custody documented in GP.8.3 |
| 13 | B | The honour-system claim is trusted where it should not be | Documented explicitly as honour-system within the cap (§2.9, GP.8.1c); GP.8.5 specifies the v2 receipt-verified upgrade path; the residual trust is the *amount*, never the *shape* |
| 14 | C | An operator silently reintroduces a replay-breaking wall-clock epoch | The action-clock model is the only one shipped; `--epoch-duration-seconds` is explicitly *not* a flag (§6.3) and a test pins its absence; the rationale is recorded so a future contributor does not re-add it |
| 15 | C | `freeTier` mis-set locks out new actors or invites free-DoS | Deny-by-default genesis (`.bounded 0 1 0`) forces a deliberate choice; GP.8.3 guidance ties `freeTier` to deposit volume + sequencer L1 budget; the `InsufficientBudget` alert (Track D) surfaces a too-low setting |
| 16 | D | Runbook drifts from shipped behaviour | Track D WUs depend on the corresponding code WUs landing first (GP.8.3 ⇐ GP.8.1c/8.2/FQ.8); two-reviewer gate on GP.8.4 |

## §9 Explicitly out of scope / future work

  * **Budget-weighted quanta (FQ-W, future) — partially unblocked by this
    unification.**  Set a flow's `quantum` proportional to its prepaid GP
    budget so prepaid value buys priority-under-contention (Sybil-neutral,
    since weight tracks a conserved quantity).  The per-flow `quantum`
    field already exists (FQ.1a), and the original FQ plan listed this as
    "blocked on a host-side budget-read endpoint."  **The unification
    reveals that GP.6.2 already ships that budget view in `budget.rs`** —
    so the *data* is now present.  What remains blocked is the *trust*
    binding: the host buckets by the untrusted ConnId / signer-hint, while
    the authoritative budget is keyed by the real CBE signer the host does
    not parse.  Sound weighting therefore still needs either a
    connection-authenticated identity (e.g. mTLS-bound) or an explicit
    "weighting is advisory and self-griefing-only" acceptance on the
    Rung-1 hint.  Promote FQ-W from "blocked" to "data-available,
    trust-gated"; track the trust decision as an open question before
    implementing.
  * **Accountable fairness (future).**  Commit per-actor served-counts to
    state; let a fault-proof observer replay the deterministic `pick`
    decision against committed arrivals and challenge an unfair sequencer.
    Track A keeps `pick` deterministic + I/O-free (§2.7) precisely to
    enable this.
  * **Receipt-verified sequencer claim (v2 / GP.8.5).**  Specified in §5;
    deferred pending an L1 receipt-proof surface + price oracle.
  * **L1 forced inclusion.**  The wall-clock-liveness backstop against a
    censoring operator; a fault-proof-rollup feature alongside Workstream
    H.  Not a `knomosis-host` concern.
  * **Wall-clock budget epochs.**  Explicitly rejected (§6.3): the
    action-clock model is load-bearing for replay determinism.
  * **Cost models beyond cost = 1.**  Per-action-kind, frame-size, or
    measured-dispatch-time cost — only if profiling shows per-request cost
    variance matters; would extend the Rung-1 header with a cheap kind
    byte rather than parse CBE.
  * **A persistent `knomosis serve` subprocess.**  Orthogonal RH-C
    closeout item; Track A is independent of it but benefits (a cheaper
    per-dispatch cost makes the worker the clear bottleneck fairness
    targets, and a persistent kernel would let GP.8.1's claim driver reuse
    one connection).

## §10 Workstream acceptance criteria

The unified sequencer integration is **Complete** when:

  1. **Fair sequencing (Track A).**  `--scheduler drr` delivers targeted,
     work-conserving fairness: a flooding actor delays only itself; honest
     actors keep their share; idle/underutilised load is unthrottled;
     single-actor throughput stays within 90 % of FIFO.  Both rungs ship —
     Rung 0 (connection-keyed, no wire change) and Rung 1 (signer-hint,
     two-tier, `PROTOCOL_VERSION == 2`, v1/v2 interop with the
     collision-proof negotiation).  Every §2.6 invariant and the §2.8
     concurrency contract hold, evidenced by tests — especially
     "routing never affects admissibility" (verdict-multiset parity) and
     "forged hints are self-confined".  The DRR decision is a single,
     deterministic, I/O-free, unit + property + fuzz-tested `Tier<K>`
     reused at both tiers.  FIFO remains the default and is behaviourally
     unchanged; the fair scheduler is fully reversible via the flag.
  2. **Reimbursement claims (Track B).**  The GP.8.1 claim driver
     constructs, signs (as `gasPoolActor`), and submits the capped
     `gasPoolActor → sequencerActor` transfer; the claim's shape is
     kernel-governed (GP.7.2) and cannot be constructed over-cap; the
     end-to-end + negative tests prove the safety boundary §2.6(5).
     Documentation states explicitly that v1 is honour-system within
     `capAmount`, with GP.8.5 as the specified v2 upgrade.
  3. **Configuration (Track C).**  The shipped GP.6.2 flags are documented
     with operator guidance; the action-clock epoch decision is recorded;
     no replay-breaking wall-clock flag is introduced (pinned by a test).
  4. **Operations (Track D).**  `docs/gas_pool_runbook.md` covers the
     deployment checklist, calibration, claim ops, fair-queuing ops,
     health checks, failure modes, and the v1.3+ mechanism expansion.
  5. **Gates.**  `ci-rust.yml` (build / test / clippy `-D warnings` / fmt)
     green; all version surfaces bumped in lockstep across the landing
     PRs; `CLAUDE.md` and `AGENTS.md` stay byte-identical; the FQ + GP
     roadmap rows and the deferred-work index are updated.

## §11 Closeout checklists

### Track A — Rung 0

  * [ ] FQ.0, FQ.1a–c, FQ.2a–c, FQ.3, FQ.4a–b, FQ.5, FQ.6, FQ.7a–c, FQ.8
        merged, each its own commit.
  * [ ] `--scheduler` defaults to `fifo`; DRR opt-in.
  * [ ] Pure core (`src/fair/drr.rs`) has unit + property + fuzz tests;
        caps enforced and tested in the core.
  * [ ] Integration suite (`tests/fair_queue.rs`) green incl.
        shutdown-under-load + FIFO parity.
  * [ ] FQ.7c throughput numbers recorded; ≥ 90 % parity or root-caused.
  * [ ] lib.rs docstring + roadmap rows updated; CLAUDE.md ≡ AGENTS.md;
        version lockstep.

### Track A — Rung 1

  * [x] FQ.9, FQ.10a–b, FQ.11a–b, FQ.12, FQ.13a, FQ.13c, FQ.14a–b, FQ.15
        landed.  FQ.13a = the `knomosis-l1-ingest` `RawTcpSubmitter` (the
        canonical raw-TCP forwarder + opt-in `--emit-signer-hints`,
        byte-pinned against `encode_hinted_frame` + driven end-to-end
        against a live host); FQ.13c = `knomosis-bench --emit-hints`.
        FQ.13b is N/A (the observer speaks L1 JSON-RPC, never a
        `SignedAction` to the host), with `encode_hinted_frame` the ready
        drop-in if that ever changes.
  * [x] One DRR implementation (`Tier<K, S>`) reused at both tiers; the
        single-tier FQ.1 suite runs green against the extracted `Tier`.
  * [x] Spoof-confinement property test (FQ.11b, `drr.rs`) +
        queue-level end-to-end spoof test (FQ.14a, `tests/fair_queue.rs`)
        green.
  * [x] v1/v2 wire interop (FQ.14b, `tests/wire_compat.rs`) green on both
        FIFO and DRR schedulers; legacy clients unaffected.
  * [x] abi.md §10.4.2 + roadmap updated; CLAUDE.md ≡ AGENTS.md; versions
        lockstepped (0.3.21); `PROTOCOL_VERSION == 2`.

### Track B — Reimbursement claims

  * [ ] GP.8.1a–c merged, each its own commit; `sequencer_claim.rs`
        created.
  * [ ] The claim constructor cannot emit an action `gasPoolPolicy` would
        reject for shape; over-cap is unconstructible.
  * [ ] End-to-end test (mock host) + negative (wrong-recipient) test
        green.
  * [ ] `docs/abi.md` documents the claim + the honour-system caveat +
        the GP.8.5 forward reference.
  * [ ] Pool key handled via `Zeroizing`; no key material in logs.
  * [ ] GP.8.5 (v2) tracked as an open question; not implemented in v1.

### Track C — Configuration

  * [ ] GP.8.2 merged; README documents the shipped GP.6.2 flags + the
        action-clock rationale.
  * [ ] No `--epoch-duration-seconds` flag exists; a test pins its
        absence.

### Track D — Operations

  * [ ] GP.8.3 + GP.8.4 merged; `docs/gas_pool_runbook.md` extended (not a
        new file).
  * [ ] Claim-ops + fair-queuing-ops sections present.
  * [ ] GP.8.4 reviewed by two reviewers (engineering + operations).

---

## Cross-references

  * **Source documents unified here.**
    `docs/planning/fair_queuing_plan.md` (Workstream FQ — Track A);
    `docs/planning/unified_gas_pool_plan.md` §GP.8 (Tracks B–D) and its
    §15E / Appendix B (attack tree) / Appendix C (dependency graph).
  * **Prerequisites.**  `docs/planning/rust_host_runtime_plan.md` §RH-C
    (`knomosis-host`); Workstream GP §GP.6.2 (host budget gate), §GP.7
    (`gasPoolActor` / `gasPoolPolicy` governance); Workstream H +
    `docs/planning/rust_host_runtime_plan.md` §RH-G (state-root submission
    + fault-proof observer).
  * **Kernel anchors.**  `LegalKernel/Bridge/BridgeActor.lean`
    (`gasPoolActor` = 1, `sequencerActor` = 2);
    `LegalKernel/Bridge/GasPoolPolicy.lean` (`gasPoolPolicy`,
    `gasPoolAuthorityPolicy`, `gasPoolActorAuthorized`);
    `LegalKernel/Bridge/PoolDrainBound.lean`
    (`pool_drain_bounded_by_action_count`);
    `LegalKernel/FaultProof/Witness.lean` (`l1FaultProofVerifier`, the v2
    trust-pattern for GP.8.5).
  * **Wire format.**  `docs/abi.md` §10 (host wire format; Rung-1 v2
    amendment in FQ.9) and the new claim documentation (GP.8.1c).
  * **Operations.**  `docs/gas_pool_runbook.md` (extended by Tracks C–D).
  * **Code.**  `runtime/knomosis-host/src/{queue,server,listener,frame,
    config,budget,kernel,lib}.rs`, the new `src/fair/drr.rs` (Track A) and
    `src/sequencer_claim.rs` (Track B).
  * **Navigator.**  `docs/planning/deferred_work_index.md` (FQ row);
    `docs/planning/open_questions.md` (OQ-GP-8 dynamic fee; the proposed
    OQ-GP-8b receipt-verified claim).

---

**End of plan.**  This document is the single source of truth for the
Knomosis sequencer: its inbound fair-sequencing liveness (Track A /
Workstream FQ), its outbound governed reimbursement economics (Track B),
its configuration (Track C), and its operations (Track D).  Each track
stands alone for landing; together they specify the sequencer optimally
and completely.
