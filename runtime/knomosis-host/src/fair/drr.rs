// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Pure Deficit-Round-Robin (DRR) scheduler core (Workstream GP.8,
//! Track A / FQ — Rungs 0 and 1).
//!
//! This module is the *pure*, I/O-free heart of the optional fair
//! scheduler.  It holds no lock, opens no socket, reads no clock, and
//! spawns no thread: it is a deterministic state machine over enqueue
//! and pick operations.  The concurrency wrapper that gives it a
//! `Mutex` + `Condvar` and feeds it the worker loop lives in
//! [`crate::queue::FairQueue`]; the connection wiring lives in
//! [`crate::server`] / [`crate::listener`].  Keeping the decision
//! logic pure has three payoffs:
//!
//!   * **Unit-testable in isolation.**  Every fairness, cap, and
//!     eviction property is exercised by driving `enqueue` / `pick`
//!     directly, with no thread scheduling to make tests flaky.
//!   * **Deterministic / replayable.**  Given the same enqueue/pick
//!     sequence the served order is reproducible — the seam a future
//!     accountable-fairness layer (`GP.8` §9) would replay against.
//!   * **One implementation, reused at both tiers.**  The round-robin
//!     discipline (`flows` / `active` / `enqueue` / `pick` / eviction)
//!     lives in the single generic `Tier`; Rung 0 keys it by `ConnId`,
//!     and the Rung-1 two-tier scheduler nests a `ConnId` tier whose
//!     per-connection store is itself a `SignerHint` tier (FQ.11).
//!
//! ## The algorithm (equal-weight DRR ≡ round-robin)
//!
//! Each *flow* (the requests sharing one routing key) owns a FIFO
//! store, a `deficit` counter, and a `quantum`.  A `cost` of one
//! credit is charged per dispatched request (one worker slot — no
//! payload inspection needed).  On a flow's turn the scheduler grants
//! it one `quantum` of credit; while `cost <= deficit` it serves the
//! head and debits `cost`.  Rung 0 uses `quantum = cost = 1`, so DRR
//! collapses to **strict per-flow round-robin**: serve one, rotate.
//! The `deficit` / `quantum` machinery is retained (not elided) so a
//! future budget-weighted quantum (`GP.8` §2.7 / §9) is a drop-in.
//!
//! ## Tiering (Rung 0 vs Rung 1)
//!
//! A `Tier<K, S>` is a round-robin scheduler over routing keys `K`,
//! where each flow's content is a `FlowStore` `S`:
//!
//!   * **Rung 0 (single tier):** `Tier<ConnId, RequestFifo>` — each
//!     connection's flow is a FIFO of requests.  `pick` serves one
//!     request per connection, round-robin across connections.
//!   * **Rung 1 (two tier):** [`DrrState`] wraps
//!     `Tier<ConnId, ConnBucket>` where `ConnBucket =
//!     Tier<SignerHint, RequestFifo>`.  The outer tier round-robins
//!     across *connections*; on a connection's turn the inner tier
//!     serves one request round-robin across that connection's
//!     *signer hints*.  This is exactly the spoof-confinement structure
//!     (`GP.8` §2.6 invariant 2): a connection multiplexing many
//!     (possibly forged) hints still receives only its single outer
//!     share, subdivided among its hints — self-harm, never theft.
//!
//! Because the outer round-robins across connections, a legacy
//! (un-hinted) connection — which routes every request to the single
//! sentinel hint [`crate::queue::LEGACY_SIGNER_HINT`] — has exactly one
//! inner flow, so its two-tier behaviour collapses to Rung-0
//! per-connection round-robin (`GP.8` §2.6 invariant 3).
//!
//! ## Invariants (checked by the test suite)
//!
//!   1. `total_depth == Σ flow.store.depth()` over all flows, at every
//!      tier.
//!   2. A key is in `active` **iff** it is in `flows`, exactly once
//!      each, and every flow in `flows` is non-empty (empty flows are
//!      evicted on drain).
//!   3. A drained flow is removed from BOTH maps and its residual
//!      deficit is discarded — no credit is banked across idle
//!      periods, so a returning burst starts fresh (the anti-burst
//!      property, `GP.8` §2.7).
//!
//! ## Capacity model (the enqueue-side dual of round-robin)
//!
//! Five integer caps live in [`Caps`] and are enforced by `enqueue`:
//! `global` bounds the total buffered requests, `max_flows` bounds the
//! distinct active connections, `max_signers` bounds the distinct
//! signer hints *within one connection* (the Rung-1 scheduler-DoS
//! bound, `GP.8` §2.6 invariant 4), `max_conn_backlog` bounds the
//! *aggregate* backlog summed across all of one connection's signer
//! flows (the per-connection dual of `per_flow`), and `per_flow` bounds
//! one (connection, signer) leaf flow's backlog.  On any breach
//! `enqueue` hands the request back (`Err(req)`) so the wrapper can
//! answer `Busy` — nothing is silently dropped.  The `per_flow` cap is
//! what makes a flooding *leaf* flow back-pressure *itself* while other
//! flows keep enqueuing (`GP.8` §2.4); `max_signers` confines a
//! hint-spamming connection to its own bounded slice of the scheduler's
//! map; and `max_conn_backlog` bounds a *single connection's* total
//! buffered share independently of how it is split across hints, so a
//! connection that spreads a flood across many distinct hints (each
//! individually under `per_flow`) is still confined to one bounded
//! aggregate rather than `max_signers × per_flow`.
//!
//! **Why `max_conn_backlog` exists and defaults to `per_flow`.**  In the
//! pre-two-tier (Rung 0) scheduler a connection's whole backlog WAS one
//! leaf FIFO, so `per_flow` capped a connection at one `per_flow`'s
//! worth.  The two-tier split would otherwise let a hint-rotating
//! connection buffer `max_signers × per_flow` (with the defaults,
//! 256 × 64 ≫ a single-connection share) and crowd the global queue.
//! Defaulting `max_conn_backlog` to `per_flow` restores the Rung-0
//! per-connection bound exactly, so spoofed hints stay self-confined out
//! of the box; an operator who genuinely multiplexes many signers behind
//! one (persistent / sequencer) connection raises it deliberately.  The
//! cap is checked AFTER the leaf `per_flow` cap (see [`DrrState::enqueue`]),
//! so a single-leaf flood is still reported as `per_flow` and the two
//! counters stay meaningful even when they coincide at the default.

use std::collections::btree_map::Entry;
use std::collections::{BTreeMap, VecDeque};

use crate::queue::{ConnId, QueuedRequest, SignerHint, HARD_MAX_QUEUE_DEPTH};

/// Default per-flow backlog cap (the `--per-flow-cap` default).
///
/// 64 buffered requests per (connection, signer) flow is generous for a
/// well-behaved client while still bounding a single flow's footprint.
pub const DEFAULT_PER_FLOW_CAP: usize = 64;

/// Default cap on distinct active flows (the `--max-flows` default).
///
/// 4096 distinct connections is ample for the canonical single-
/// sequencer + small-consumer-set topology; the cap bounds the
/// scheduler's own map growth (a flow map is an attack surface,
/// `GP.8` §2.6 invariant 4).
pub const DEFAULT_MAX_FLOWS: usize = 4096;

/// Hard ceiling on `max_flows`, mirroring
/// [`crate::queue::HARD_MAX_QUEUE_DEPTH`].  Defends-in-depth against a
/// library consumer constructing [`Caps`] with `max_flows =
/// usize::MAX`: [`DrrState::new`] clamps to this regardless of the
/// configured value, so the flow map can never grow without bound
/// even if the CLI validation layer is bypassed.
pub const HARD_MAX_FLOWS: usize = 65_536;

/// Default cap on distinct signer hints within one connection (the
/// `--max-signers-per-conn` default, FQ.12).
///
/// 256 distinct signer hints per connection is generous for a
/// multiplexing upstream sequencer while bounding the Rung-1
/// scheduler-DoS surface: a connection that spawns many (possibly
/// forged) hints can grow its inner map only to this bound before
/// further distinct hints are told `Busy` — confining the damage to
/// the offending connection (`GP.8` §2.6 invariant 4).
pub const DEFAULT_MAX_SIGNERS_PER_CONN: usize = 256;

/// Hard ceiling on `max_signers`, mirroring [`HARD_MAX_FLOWS`].  The
/// worst-case inner-map footprint of one connection is bounded by this
/// regardless of the configured value; [`Caps::with_max_signers`]
/// clamps to it as defence in depth.
pub const HARD_MAX_SIGNERS_PER_CONN: usize = 65_536;

/// The per-turn credit granted to a flow and the credit charged per
/// dispatched request.  Equal weight (`quantum == cost == 1`) makes
/// DRR collapse to strict round-robin (`GP.8` §2.7).
const QUANTUM: u64 = 1;

/// The credit one dispatched request consumes (one worker slot).
const COST: u64 = 1;

/// Capacity caps for the DRR scheduler.
///
/// All four are enforced atomically inside [`DrrState::enqueue`]
/// (under the caller's lock).  See the module docstring for the
/// capacity model.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Caps {
    /// Maximum requests buffered within a single (connection, signer)
    /// leaf flow.  A flooding flow that hits this cap is told `Busy` on
    /// its *own* over-submission while other flows still enqueue freely.
    pub per_flow: usize,
    /// Maximum number of distinct active connections.  Bounds the outer
    /// tier's map growth; enforced only when a *new* connection would be
    /// created.
    pub max_flows: usize,
    /// Maximum number of distinct signer hints buffered within ONE
    /// connection (Rung 1).  Bounds the inner tier's per-connection map
    /// growth; enforced only when a *new* signer hint would be created
    /// inside a connection.  A legacy connection (single sentinel hint)
    /// never approaches this.
    pub max_signers: usize,
    /// Maximum *aggregate* buffered requests within ONE connection,
    /// summed across all of that connection's signer flows (Rung 1.5).
    ///
    /// Where `per_flow` bounds one (connection, signer) *leaf* and
    /// `max_signers` bounds the *count* of a connection's distinct
    /// hints, this bounds their *product surface*: a connection that
    /// spreads a flood across many distinct hints — each leaf
    /// individually under `per_flow` — is still confined to this single
    /// aggregate rather than `max_signers × per_flow`.  Checked AFTER the
    /// leaf `per_flow` cap (so a single-leaf flood is still reported as
    /// `per_flow`) and BEFORE a new signer hint is admitted.  Defaults to
    /// `per_flow` (clamped to `global`), restoring the Rung-0
    /// per-connection backpressure that the two-tier split would
    /// otherwise relax to `max_signers × per_flow`; an operator raises it
    /// for a connection that legitimately multiplexes many signers (a
    /// persistent / sequencer-fronted topology).
    pub max_conn_backlog: usize,
    /// Maximum total buffered requests across all flows.  The
    /// scheduler-wide backpressure bound; Rung 0/1 reuses the host's
    /// `--max-queue-depth` for this value.
    pub global: usize,
}

impl Caps {
    /// Construct caps from the three Rung-0 bounds, applying the
    /// defence-in-depth ceilings ([`HARD_MAX_FLOWS`] on `max_flows`,
    /// [`crate::queue::HARD_MAX_QUEUE_DEPTH`] on `global`).  The
    /// per-connection signer cap defaults to
    /// [`DEFAULT_MAX_SIGNERS_PER_CONN`]; override it with
    /// [`Caps::with_max_signers`].
    ///
    /// The CLI validation layer ([`crate::config`]) rejects out-of-range
    /// values *loudly* before reaching here; this clamp is the
    /// belt-and-braces guard for direct library consumers, parallel
    /// to [`crate::frame::read_frame`]'s frame-size clamp.
    #[must_use]
    pub fn new(per_flow: usize, max_flows: usize, global: usize) -> Self {
        let global = global.min(HARD_MAX_QUEUE_DEPTH);
        Self {
            per_flow,
            max_flows: max_flows.min(HARD_MAX_FLOWS),
            max_signers: DEFAULT_MAX_SIGNERS_PER_CONN,
            // Default the per-connection aggregate cap to the leaf cap,
            // never exceeding the global cap.  This restores the Rung-0
            // per-connection backpressure (one connection ≈ one
            // `per_flow`'s worth) that the two-tier split would otherwise
            // relax to `max_signers × per_flow`; `with_max_conn_backlog`
            // raises it for a legitimately-multiplexing connection.
            max_conn_backlog: per_flow.min(global),
            global,
        }
    }

    /// Set the per-connection distinct-signer cap (Rung 1, FQ.12),
    /// clamped to [`HARD_MAX_SIGNERS_PER_CONN`] as defence in depth.
    #[must_use]
    pub fn with_max_signers(mut self, max_signers: usize) -> Self {
        self.max_signers = max_signers.min(HARD_MAX_SIGNERS_PER_CONN);
        self
    }

    /// Set the per-connection aggregate backlog cap (Rung 1.5), clamped
    /// to [`crate::queue::HARD_MAX_QUEUE_DEPTH`] as defence in depth (a
    /// single connection can never buffer more than the scheduler-wide
    /// hard ceiling, regardless of the configured value).
    #[must_use]
    pub fn with_max_conn_backlog(mut self, max_conn_backlog: usize) -> Self {
        self.max_conn_backlog = max_conn_backlog.min(HARD_MAX_QUEUE_DEPTH);
        self
    }
}

/// Which cap a *routed* enqueue breached.  Carried alongside the
/// returned request so the top-level [`DrrState::enqueue`] tallies the
/// right per-reason counter (FQ.6) before answering `Busy`.
///
/// The scheduler-wide `global` cap is NOT here: it is enforced at the
/// top of [`DrrState::enqueue`] (before routing), so the routed path
/// only ever reports the four tier-local caps (`max_flows`,
/// `max_conn_backlog`, `max_signers`, `per_flow`).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RejectReason {
    /// The outer tier's `max_flows` distinct-connection cap.
    MaxFlows,
    /// The inner tier's `max_signers` distinct-signer-per-connection
    /// cap (Rung 1).
    MaxSigners,
    /// The per-connection `max_conn_backlog` aggregate-backlog cap
    /// (Rung 1.5) — the inner tier's total depth across all hints.
    ConnBacklog,
    /// A leaf flow's `per_flow` backlog cap.
    PerFlow,
}

/// A rejected enqueue: the breached cap plus the request handed back
/// unchanged (so nothing is silently dropped — the wrapper maps it to
/// `Busy`).
#[derive(Debug)]
struct Rejected {
    /// Which cap was breached.
    reason: RejectReason,
    /// The original request, returned to the caller.
    req: QueuedRequest,
}

/// The content of one flow in a [`Tier`].
///
/// A leaf flow stores a FIFO of requests ([`RequestFifo`]); an outer
/// flow stores a whole inner [`Tier`] (a `ConnBucket`).  The shared
/// round-robin `pick` only ever needs to *serve one request* from a
/// flow and ask *how deep* it still is — exactly this trait — so the
/// same `pick` drives both tiers.
trait FlowStore {
    /// Serve (remove and return) the next request from this store in
    /// its own fair order.  Returns `None` only if the store is empty,
    /// which a [`Tier`] never lets happen for a *present* flow (drained
    /// flows are evicted).
    fn serve(&mut self) -> Option<QueuedRequest>;

    /// Total buffered requests in this store.
    fn depth(&self) -> usize;

    /// `true` iff this store holds no requests.
    fn is_empty(&self) -> bool {
        self.depth() == 0
    }
}

/// A leaf flow's content: a FIFO of requests for one (connection,
/// signer) pair (or, in Rung 0, one connection).
#[derive(Debug, Default)]
struct RequestFifo {
    /// FIFO backlog.  Never empty while the flow is present in a tier's
    /// `flows` map (drained flows are evicted).
    deque: VecDeque<QueuedRequest>,
}

impl RequestFifo {
    /// A fresh empty FIFO.
    fn new() -> Self {
        Self::default()
    }

    /// Push `req` onto the backlog, enforcing the `per_flow` cap.  On a
    /// breach the request is handed back via `Err(Rejected)` (nothing
    /// dropped).  The degenerate `per_flow == 0` case (CLI validation
    /// forbids it, but the core stays robust) rejects every push.
    fn push(&mut self, req: QueuedRequest, per_flow: usize) -> Result<(), Rejected> {
        if self.deque.len() >= per_flow {
            return Err(Rejected {
                reason: RejectReason::PerFlow,
                req,
            });
        }
        self.deque.push_back(req);
        Ok(())
    }
}

impl FlowStore for RequestFifo {
    fn serve(&mut self) -> Option<QueuedRequest> {
        self.deque.pop_front()
    }

    fn depth(&self) -> usize {
        self.deque.len()
    }
}

/// One flow's store plus its DRR accounting.
///
/// The `quantum` field is per-flow so a future weighted scheduler can
/// vary it; Rungs 0/1 always set it to [`QUANTUM`] (= 1).
#[derive(Debug)]
struct FlowEntry<S> {
    /// The flow's content (a FIFO leaf, or an inner tier).
    store: S,
    /// Accumulated DRR credit.  Topped up by `quantum` on each turn;
    /// debited by [`COST`] per served request; discarded on eviction.
    deficit: u64,
    /// Per-turn credit grant.  Always [`QUANTUM`] in Rungs 0/1.
    quantum: u64,
}

impl<S> FlowEntry<S> {
    /// A fresh flow entry wrapping `store`, with zero deficit and the
    /// equal-weight quantum.
    fn new(store: S) -> Self {
        Self {
            store,
            deficit: 0,
            quantum: QUANTUM,
        }
    }
}

/// A single round-robin scheduling tier over keys `K`, each mapping to
/// a [`FlowStore`] `S`.
///
/// This is the **one** DRR implementation reused at both tiers
/// (FQ.11a): the inner tier is `Tier<SignerHint, RequestFifo>`, the
/// outer tier is `Tier<ConnId, ConnBucket>`.  All scheduling mutation
/// happens through [`Tier::enqueue_routed`] (and its leaf convenience
/// [`Tier::enqueue_leaf`]) and [`Tier::pick`]; the rest of the surface
/// is read-only accessors for the wrapper's `Condvar` predicate and for
/// observability.
#[derive(Debug)]
struct Tier<K: Ord + Clone, S: FlowStore> {
    /// Per-key flows.  Every value is non-empty (invariant 2).
    flows: BTreeMap<K, FlowEntry<S>>,
    /// Round-robin order of the active (non-empty) flow keys.  Drives
    /// the dispatch order; `pick` serves the front and rotates it to
    /// the back (or evicts it on drain).
    active: VecDeque<K>,
    /// Cached `Σ flow.store.depth()` (invariant 1) so `len` is O(1).
    total_depth: usize,
}

impl<K: Ord + Clone, S: FlowStore> Tier<K, S> {
    /// An empty tier.
    fn new() -> Self {
        Self {
            flows: BTreeMap::new(),
            active: VecDeque::new(),
            total_depth: 0,
        }
    }

    /// Number of distinct active (non-empty) flows in this tier.
    fn active_len(&self) -> usize {
        self.active.len()
    }

    /// Route `req` to flow `key`, creating the flow (capped at
    /// `max_keys` distinct keys for THIS tier) via `make` if absent and
    /// pushing into it via `push`.
    ///
    /// This is the **shared** structural core of enqueue at every tier:
    /// it owns the activation bookkeeping (a new key joins the
    /// round-robin order exactly once) and the cap-breach handling
    /// (nothing inserted on a sub-cap reject, nothing silently dropped).
    /// The leaf push (`per_flow` cap) or the inner-tier push
    /// (`max_signers` + `per_flow`) is supplied by `push`; the
    /// distinct-key cap reason for THIS tier is `max_keys_reason`.
    ///
    /// Runs under the wrapper's lock, so the cap check is atomic with
    /// the mutation.  A single [`Entry`] lookup (no check-then-insert).
    fn enqueue_routed(
        &mut self,
        key: K,
        max_keys: usize,
        max_keys_reason: RejectReason,
        req: QueuedRequest,
        make: impl FnOnce() -> S,
        push: impl FnOnce(&mut S, QueuedRequest) -> Result<(), Rejected>,
    ) -> Result<(), Rejected> {
        // Snapshot the distinct-key count before borrowing the map via
        // `entry` (O(1), needs no tree walk).
        let key_count = self.flows.len();
        match self.flows.entry(key) {
            Entry::Occupied(mut occ) => {
                // Existing flow ⇒ already in `active` (invariant 2) and
                // non-empty.  Only the inner push's caps apply.
                push(&mut occ.get_mut().store, req)?;
                self.total_depth += 1;
                Ok(())
            }
            Entry::Vacant(vac) => {
                // New flow ⇒ enforce this tier's distinct-key cap first.
                if key_count >= max_keys {
                    return Err(Rejected {
                        reason: max_keys_reason,
                        req,
                    });
                }
                // Build the store and push into it.  If the push is
                // rejected (a degenerate per_flow == 0, or a nested cap),
                // do NOT insert an empty flow — return the request back.
                let mut store = make();
                push(&mut store, req)?;
                let activated_key = vac.key().clone();
                vac.insert(FlowEntry::new(store));
                // Empty → non-empty transition: register the key in the
                // round-robin order exactly once.
                self.active.push_back(activated_key);
                self.total_depth += 1;
                Ok(())
            }
        }
    }

    /// Serve the next request in round-robin order, or `None` if no
    /// flow is active.
    ///
    /// Pops the front flow's head — by delegating to the flow's
    /// [`FlowStore::serve`], which is a FIFO `pop_front` at a leaf and a
    /// nested round-robin `pick` at the outer tier — debiting one
    /// [`COST`] from its deficit (which was just topped up by one
    /// [`QUANTUM`]).  With the equal-weight quantum the credit always
    /// covers exactly one request, so a flow serves its head on every
    /// turn.  A drained flow is evicted from both maps (its deficit
    /// discarded); a flow that still has work is rotated to the back of
    /// the round.
    ///
    /// Deterministic and I/O-free: reads no clock, performs no I/O.
    fn pick(&mut self) -> Option<QueuedRequest> {
        let key = self.active.front()?.clone();
        let entry = self
            .flows
            .get_mut(&key)
            .expect("invariant: every key in `active` maps to a non-empty flow");

        // DRR turn entry: grant one quantum of credit (saturating, so a
        // pathological weighted future can never overflow).
        entry.deficit = entry.deficit.saturating_add(entry.quantum);
        // With `quantum == COST == 1` the credit always covers exactly
        // one request, so the flow serves its head every turn — DRR is
        // strict round-robin.  The invariant `quantum >= COST` (which
        // guarantees forward progress) is asserted, not assumed, so a
        // future weighted quantum is a safe drop-in.
        debug_assert!(
            entry.deficit >= COST,
            "quantum must be >= cost so every turn makes progress"
        );

        let req = entry
            .store
            .serve()
            .expect("invariant: an active flow is non-empty");
        entry.deficit -= COST;
        self.total_depth -= 1;

        if entry.store.is_empty() {
            // Drained: drop from BOTH `active` (front) and `flows`,
            // discarding the residual deficit (invariant 3).
            self.active.pop_front();
            self.flows.remove(&key);
        } else {
            // Still backlogged: rotate this flow to the back of the
            // round (front → back) so the next turn serves a different
            // flow.
            self.active.rotate_left(1);
        }
        Some(req)
    }
}

/// Any [`Tier`] is itself a [`FlowStore`]: serving it picks one request
/// in its own round-robin order, and its depth is the cached
/// `total_depth`.  This is exactly what lets the outer tier nest an
/// inner tier as a connection's per-flow content (the Rung-1 two-tier
/// structure) using the same `pick` (FQ.11a).
impl<K: Ord + Clone, S: FlowStore> FlowStore for Tier<K, S> {
    fn serve(&mut self) -> Option<QueuedRequest> {
        self.pick()
    }

    fn depth(&self) -> usize {
        self.total_depth
    }
}

impl<K: Ord + Clone> Tier<K, RequestFifo> {
    /// Leaf enqueue convenience: route `req` to leaf flow `key`, capped
    /// by `max_keys` (distinct keys, with reason `max_keys_reason`) and
    /// `per_flow` (this leaf's backlog).  Used by the inner tier
    /// (keyed by `SignerHint`, `max_keys = max_signers`) and by the
    /// single-tier Rung-0 instantiation / unit tests (keyed by `ConnId`,
    /// `max_keys = max_flows`).
    fn enqueue_leaf(
        &mut self,
        key: K,
        req: QueuedRequest,
        per_flow: usize,
        max_keys: usize,
        max_keys_reason: RejectReason,
    ) -> Result<(), Rejected> {
        self.enqueue_routed(
            key,
            max_keys,
            max_keys_reason,
            req,
            RequestFifo::new,
            |fifo, req| fifo.push(req, per_flow),
        )
    }
}

/// One connection's inner scheduler: a [`Tier`] of leaf FIFOs keyed by
/// signer hint (Rung 1).  The outer tier stores one of these per active
/// connection; serving it picks one request round-robin across that
/// connection's signer hints (`GP.8` §2.6 invariant 2).
type ConnBucket = Tier<SignerHint, RequestFifo>;

impl ConnBucket {
    /// Enqueue `req` under `signer` within this connection, enforcing the
    /// three per-connection caps in priority order:
    ///
    ///   1. `per_flow` — if `signer`'s leaf already exists and is full,
    ///      reject `PerFlow`.  Checking the leaf cap FIRST keeps it the
    ///      innermost cap, so a single-leaf flood is attributed to
    ///      `per_flow` even when `max_conn_backlog == per_flow` (the
    ///      default), and the two counters stay distinct + meaningful.
    ///   2. `max_conn_backlog` — else if this connection's AGGREGATE
    ///      depth (summed across all its hints) is at the cap, reject
    ///      `ConnBacklog`.  This is the per-connection dual of
    ///      `per_flow`: it confines a hint-rotating flood to one bounded
    ///      share no matter how many distinct hints it spreads across.
    ///   3. `max_signers` + the leaf push — admit into the leaf,
    ///      rejecting `MaxSigners` if a NEW hint would exceed the
    ///      distinct-hint cap.  The push re-checks `per_flow`
    ///      defensively; step 1 already guaranteed headroom for an
    ///      existing leaf, and a fresh leaf starts at depth 0.
    fn enqueue_signer(
        &mut self,
        signer: SignerHint,
        req: QueuedRequest,
        per_flow: usize,
        max_signers: usize,
        max_conn_backlog: usize,
    ) -> Result<(), Rejected> {
        // 1. Leaf `per_flow` cap (innermost): a full existing leaf is a
        //    `PerFlow` reject, checked before the aggregate cap so the
        //    leaf cap stays attributable at the default
        //    (`max_conn_backlog == per_flow`).
        if let Some(entry) = self.flows.get(&signer) {
            if entry.store.depth() >= per_flow {
                return Err(Rejected {
                    reason: RejectReason::PerFlow,
                    req,
                });
            }
        }
        // 2. Per-connection aggregate cap (the Rung-1.5 bound).
        if self.total_depth >= max_conn_backlog {
            return Err(Rejected {
                reason: RejectReason::ConnBacklog,
                req,
            });
        }
        // 3. Distinct-hint cap + leaf push.
        self.enqueue_leaf(signer, req, per_flow, max_signers, RejectReason::MaxSigners)
    }
}

/// Aggregate scheduler counters, returned by [`DrrState::stats`].
///
/// All fields are maintained under the same lock that guards the
/// scheduler, so a snapshot is internally consistent (FQ.6).
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct DrrStats {
    /// Current total buffered requests across all flows.
    pub total_depth: usize,
    /// Current number of distinct active connections (outer tier).
    pub active_flows: usize,
    /// Current total distinct active signer flows across all
    /// connections (Σ inner active flows) — Rung-1 observability.
    pub active_signers: usize,
    /// Lifetime count of requests dispatched via `pick`.
    pub dispatched: u64,
    /// Lifetime count of enqueue rejections due to the `per_flow` cap.
    pub rejected_per_flow: u64,
    /// Lifetime count of enqueue rejections due to the `max_flows` cap.
    pub rejected_max_flows: u64,
    /// Lifetime count of enqueue rejections due to the per-connection
    /// `max_signers` cap (Rung 1).
    pub rejected_max_signers: u64,
    /// Lifetime count of enqueue rejections due to the per-connection
    /// `max_conn_backlog` aggregate-backlog cap (Rung 1.5).
    pub rejected_conn_backlog: u64,
    /// Lifetime count of enqueue rejections due to the `global` cap.
    pub rejected_global: u64,
}

/// The pure two-tier DRR scheduler state (Rung 1, with Rung-0 as the
/// degenerate single-signer case).
///
/// The outer `Tier` round-robins across connections (`ConnId`); each
/// connection's flow is a `ConnBucket` inner tier that round-robins
/// across that connection's signer hints.  A legacy connection routes
/// every request to the single [`crate::queue::LEGACY_SIGNER_HINT`], so
/// its inner tier has one flow and the scheduler behaves exactly like
/// Rung 0 for it.
#[derive(Debug)]
pub struct DrrState {
    /// The outer connection tier; each flow is a per-connection inner
    /// signer tier.
    outer: Tier<ConnId, ConnBucket>,
    /// The capacity caps (already clamped via [`Caps::new`] /
    /// [`Caps::with_max_signers`]).
    caps: Caps,
    /// Lifetime dispatch count (FQ.6).
    dispatched: u64,
    /// Lifetime `per_flow`-cap rejection count (FQ.6).
    rejected_per_flow: u64,
    /// Lifetime `max_flows`-cap rejection count (FQ.6).
    rejected_max_flows: u64,
    /// Lifetime `max_signers`-cap rejection count (FQ.6).
    rejected_max_signers: u64,
    /// Lifetime `max_conn_backlog`-cap rejection count (FQ.6).
    rejected_conn_backlog: u64,
    /// Lifetime `global`-cap rejection count (FQ.6).
    rejected_global: u64,
    /// Whether the queue has been closed (the worker has shut down).
    /// Lives inside the scheduler state — and is therefore read/written
    /// under the wrapper's single `Mutex` together with `enqueue` /
    /// `pick` — so the closed check and an enqueue are atomic with the
    /// worker's `close` + drain: a `try_submit` either observes `closed`
    /// (and rejects) or enqueues a request the drain will still serve,
    /// with no TOCTOU window in between.
    closed: bool,
}

impl DrrState {
    /// Construct an empty scheduler with the given caps.  The caps are
    /// passed through [`Caps::new`] + [`Caps::with_max_signers`] so the
    /// defence-in-depth ceilings always apply.
    #[must_use]
    pub fn new(caps: Caps) -> Self {
        let caps = Caps::new(caps.per_flow, caps.max_flows, caps.global)
            .with_max_signers(caps.max_signers)
            .with_max_conn_backlog(caps.max_conn_backlog);
        Self {
            outer: Tier::new(),
            caps,
            dispatched: 0,
            rejected_per_flow: 0,
            rejected_max_flows: 0,
            rejected_max_signers: 0,
            rejected_conn_backlog: 0,
            rejected_global: 0,
            closed: false,
        }
    }

    /// Enqueue `req` under `(conn, signer)`.
    ///
    /// Enforces, in order, the `global` (total depth) cap, then routes
    /// through the outer connection tier (`max_flows` for a new
    /// connection) into that connection's inner signer tier, where
    /// [`ConnBucket::enqueue_signer`] applies the three per-connection
    /// caps in priority order (`per_flow` leaf cap, then
    /// `max_conn_backlog` aggregate cap, then `max_signers` distinct-hint
    /// cap).  On any breach the request is handed back unchanged via
    /// `Err(req)` — the wrapper maps this to `Busy`; nothing is silently
    /// dropped — and the matching per-reason counter is tallied (FQ.6).
    ///
    /// The whole call runs under the wrapper's lock, so every cap check
    /// is atomic with the mutation.
    ///
    /// # Errors
    ///
    /// Returns `Err(req)` (the original request) when `global`,
    /// `max_flows`, `per_flow`, `max_conn_backlog`, or `max_signers`
    /// would be exceeded.
    pub fn enqueue(
        &mut self,
        conn: ConnId,
        signer: SignerHint,
        req: QueuedRequest,
    ) -> Result<(), QueuedRequest> {
        // 1. Global cap: bounds total buffered requests.  Checked first
        //    so a saturated host rejects uniformly regardless of which
        //    (connection, signer) the request targets.
        if self.outer.total_depth >= self.caps.global {
            self.rejected_global = self.rejected_global.saturating_add(1);
            return Err(req);
        }

        // 2. Route through the outer connection tier into the inner
        //    signer tier.  `max_flows` caps distinct connections; the
        //    inner `enqueue_signer` then applies the leaf `per_flow`,
        //    per-connection `max_conn_backlog`, and distinct-hint
        //    `max_signers` caps in priority order.
        let per_flow = self.caps.per_flow;
        let max_signers = self.caps.max_signers;
        let max_conn_backlog = self.caps.max_conn_backlog;
        match self.outer.enqueue_routed(
            conn,
            self.caps.max_flows,
            RejectReason::MaxFlows,
            req,
            ConnBucket::new,
            |bucket, req| {
                bucket.enqueue_signer(signer, req, per_flow, max_signers, max_conn_backlog)
            },
        ) {
            Ok(()) => Ok(()),
            Err(Rejected { reason, req }) => {
                match reason {
                    RejectReason::MaxFlows => {
                        self.rejected_max_flows = self.rejected_max_flows.saturating_add(1);
                    }
                    RejectReason::MaxSigners => {
                        self.rejected_max_signers = self.rejected_max_signers.saturating_add(1);
                    }
                    RejectReason::ConnBacklog => {
                        self.rejected_conn_backlog = self.rejected_conn_backlog.saturating_add(1);
                    }
                    RejectReason::PerFlow => {
                        self.rejected_per_flow = self.rejected_per_flow.saturating_add(1);
                    }
                }
                Err(req)
            }
        }
    }

    /// Serve the next request in two-tier round-robin order, or `None`
    /// if no flow is active.  Picks a connection (outer round-robin),
    /// then one of that connection's signer hints (inner round-robin),
    /// then rotates/evicts at both tiers.
    ///
    /// Deterministic and I/O-free.
    pub fn pick(&mut self) -> Option<QueuedRequest> {
        let req = self.outer.pick()?;
        self.dispatched = self.dispatched.saturating_add(1);
        Some(req)
    }

    /// Total buffered requests across all flows (== `Σ store.depth()`).
    #[must_use]
    pub fn len(&self) -> usize {
        self.outer.total_depth
    }

    /// `true` iff no request is buffered (the `Condvar` wait
    /// predicate).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.outer.total_depth == 0
    }

    /// Number of distinct active connections (outer tier).
    #[must_use]
    pub fn active_len(&self) -> usize {
        self.outer.active_len()
    }

    /// Total distinct active signer flows across all connections (Σ
    /// inner active flows) — Rung-1 observability.
    #[must_use]
    pub fn active_signers(&self) -> usize {
        self.outer
            .flows
            .values()
            .map(|entry| entry.store.active_len())
            .sum()
    }

    /// Whether the queue has been closed.  Read by the wrapper under its
    /// lock to reject submissions after shutdown.
    #[must_use]
    pub fn is_closed(&self) -> bool {
        self.closed
    }

    /// Mark the queue closed (idempotent).  Set by the wrapper under its
    /// lock so it is serialized with `enqueue` / `pick`.  Does not touch
    /// the buffered requests — `pick` still drains them.
    pub fn set_closed(&mut self) {
        self.closed = true;
    }

    /// Snapshot the aggregate counters (FQ.6).  Consistent because the
    /// caller holds the scheduler's lock.
    #[must_use]
    pub fn stats(&self) -> DrrStats {
        DrrStats {
            total_depth: self.outer.total_depth,
            active_flows: self.outer.active_len(),
            active_signers: self.active_signers(),
            dispatched: self.dispatched,
            rejected_per_flow: self.rejected_per_flow,
            rejected_max_flows: self.rejected_max_flows,
            rejected_max_signers: self.rejected_max_signers,
            rejected_conn_backlog: self.rejected_conn_backlog,
            rejected_global: self.rejected_global,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Caps, ConnBucket, DrrState, FlowStore, RejectReason, RequestFifo, Tier, DEFAULT_MAX_FLOWS,
        DEFAULT_MAX_SIGNERS_PER_CONN, DEFAULT_PER_FLOW_CAP, HARD_MAX_FLOWS,
        HARD_MAX_SIGNERS_PER_CONN,
    };
    use crate::queue::{QueuedRequest, HARD_MAX_QUEUE_DEPTH};
    use std::collections::{BTreeMap, BTreeSet, HashSet};
    use std::sync::mpsc::sync_channel;

    /// Build a request whose payload encodes `tag` (little-endian
    /// u64), with a throwaway reply channel.  Tests recover the tag
    /// with [`tag_of`] to confirm *which* flow served a request.
    fn req(tag: u64) -> QueuedRequest {
        let (reply, _rx) = sync_channel(1);
        QueuedRequest {
            payload: tag.to_le_bytes().to_vec(),
            reply,
        }
    }

    /// Recover the tag a request was built with.
    fn tag_of(r: &QueuedRequest) -> u64 {
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(&r.payload[..8]);
        u64::from_le_bytes(bytes)
    }

    /// Generous caps that never reject — isolates scheduling logic.
    fn open_caps() -> Caps {
        Caps::new(1_000, 1_000, 1_000_000).with_max_signers(1_000)
    }

    // ===================================================================
    // Single-tier core: FQ.1b/1c run UNCHANGED against the extracted
    // `Tier<ConnId, RequestFifo>` (FQ.11a — proving the refactor is
    // behaviour-preserving).  A tiny `enqueue` helper drives the leaf
    // tier with the Rung-0 cap shape (`max_keys = max_flows`).
    // ===================================================================

    /// A single-tier leaf tier (the extracted Rung-0 core).
    type LeafTier = Tier<u64, RequestFifo>;

    /// Enqueue into the extracted single-tier core with `caps`'
    /// per-flow / max-flows bounds, returning the rejected request on a
    /// breach (the `Err` shape the wrapper maps to `Busy`).
    ///
    /// A thin wrapper over the REAL [`Tier::enqueue_leaf`] — no synthetic
    /// logic — so the FQ.1 suite is genuine behaviour-preservation
    /// evidence for the extracted core.  The single-tier `Tier` has no
    /// `global` cap (that lives in the two-tier [`DrrState`]), so `global`
    /// is exercised at the `DrrState` level instead (`two_tier_global_cap`
    /// / `drr_state_global_zero_rejects_all`).
    fn leaf_enqueue(
        t: &mut LeafTier,
        caps: Caps,
        key: u64,
        r: QueuedRequest,
    ) -> Result<(), QueuedRequest> {
        t.enqueue_leaf(
            key,
            r,
            caps.per_flow,
            caps.max_flows,
            RejectReason::MaxFlows,
        )
        .map_err(|rej| rej.req)
    }

    /// Assert the three structural invariants on a leaf tier.
    fn assert_leaf_invariants(t: &LeafTier) {
        // Invariant 1: total_depth == Σ store.depth().
        let summed: usize = t.flows.values().map(|f| f.store.depth()).sum();
        assert_eq!(t.total_depth, summed, "total_depth drifted from Σ depth");
        // Invariant 2: active set == flow keys, once each, all non-empty.
        assert_eq!(
            t.active.len(),
            t.flows.len(),
            "active/flows cardinality mismatch"
        );
        let active_set: BTreeSet<&u64> = t.active.iter().collect();
        assert_eq!(active_set.len(), t.active.len(), "duplicate key in active");
        for key in &t.active {
            let flow = t.flows.get(key).expect("active key absent from flows");
            assert!(flow.store.depth() > 0, "active flow is empty (not evicted)");
        }
    }

    /// `per_flow` cap independently returns the request back.
    #[test]
    fn per_flow_cap_rejects_and_returns_request() {
        let caps = Caps::new(2, 10, 100);
        let mut t = LeafTier::new();
        assert!(leaf_enqueue(&mut t, caps, 7, req(7)).is_ok());
        assert!(leaf_enqueue(&mut t, caps, 7, req(7)).is_ok());
        // Third on the same flow breaches per_flow = 2.
        let err = leaf_enqueue(&mut t, caps, 7, req(999)).expect_err("per_flow breach");
        assert_eq!(tag_of(&err), 999, "the rejected request must flow back");
        assert_eq!(t.total_depth, 2);
        assert_leaf_invariants(&t);
    }

    /// `max_flows` cap independently returns the request back, but only
    /// when the key is new (an existing flow is unaffected).
    #[test]
    fn max_flows_cap_rejects_new_keys_only() {
        let caps = Caps::new(10, 2, 100);
        let mut t = LeafTier::new();
        assert!(leaf_enqueue(&mut t, caps, 1, req(1)).is_ok());
        assert!(leaf_enqueue(&mut t, caps, 2, req(2)).is_ok());
        // Third DISTINCT key breaches max_flows = 2.
        let err = leaf_enqueue(&mut t, caps, 3, req(3)).expect_err("max_flows breach");
        assert_eq!(tag_of(&err), 3);
        // An existing key still enqueues (cap is on distinct flows).
        assert!(leaf_enqueue(&mut t, caps, 1, req(1)).is_ok());
        assert_eq!(t.total_depth, 3);
        assert_leaf_invariants(&t);
    }

    // (The `global` cap is NOT a single-tier concern — it lives in the
    // two-tier `DrrState` — so it is exercised by `two_tier_global_cap`
    // and `drr_state_global_zero_rejects_all`, not against the extracted
    // leaf `Tier`.)

    /// Activation bookkeeping: a new key registers exactly one active
    /// entry; repeated enqueues on it do not duplicate it.
    #[test]
    fn activation_bookkeeping_is_exact() {
        let caps = open_caps();
        let mut t = LeafTier::new();
        leaf_enqueue(&mut t, caps, 5, req(5)).unwrap();
        assert_eq!(t.active_len(), 1);
        leaf_enqueue(&mut t, caps, 5, req(5)).unwrap();
        leaf_enqueue(&mut t, caps, 5, req(5)).unwrap();
        assert_eq!(t.active_len(), 1, "same key must not re-activate");
        leaf_enqueue(&mut t, caps, 6, req(6)).unwrap();
        assert_eq!(t.active_len(), 2);
        assert_eq!(t.total_depth, 4);
        assert_leaf_invariants(&t);
    }

    /// `pick` on an empty tier is `None`.
    #[test]
    fn pick_empty_is_none() {
        let mut t = LeafTier::new();
        assert!(t.pick().is_none());
    }

    /// Round-robin order across N flows (one request each → exactly the
    /// `active` insertion order, then exhausted).
    #[test]
    fn round_robin_order_across_flows() {
        let caps = open_caps();
        let mut t = LeafTier::new();
        for k in 0..4u64 {
            leaf_enqueue(&mut t, caps, k, req(k)).unwrap();
        }
        let served: Vec<u64> = std::iter::from_fn(|| t.pick().map(|r| tag_of(&r))).collect();
        assert_eq!(served, vec![0, 1, 2, 3]);
        assert!(t.total_depth == 0);
        assert_leaf_invariants(&t);
    }

    /// A heavy flow does not starve a light flow: the light flow's lone
    /// request is served within `active_flows` picks, NOT behind the
    /// whole backlog (the §2.4 head-of-line defect FIFO would exhibit).
    #[test]
    fn heavy_flow_does_not_starve_light_flow() {
        let caps = open_caps();
        let mut t = LeafTier::new();
        // Whale (key 1) enqueues 5; small (key 2) enqueues 1.  Whale
        // first, so under FIFO the small request would be 6th.
        for _ in 0..5 {
            leaf_enqueue(&mut t, caps, 1, req(1)).unwrap();
        }
        leaf_enqueue(&mut t, caps, 2, req(2)).unwrap();
        let served: Vec<u64> = std::iter::from_fn(|| t.pick().map(|r| tag_of(&r))).collect();
        let small_pos = served.iter().position(|&k| k == 2).expect("small served");
        assert!(
            small_pos < 2,
            "small served at {small_pos}, expected within active_flows"
        );
        assert_eq!(served[0], 1);
        assert_eq!(served[1], 2, "small request served on its first turn");
        assert_eq!(served.iter().filter(|&&k| k == 1).count(), 5);
    }

    /// With K active flows, every flow's head is served within the
    /// first K picks (the no-starvation bound, FQ.1b/FQ.7a).
    #[test]
    fn every_head_served_within_k_picks() {
        let k = 6u64;
        let caps = open_caps();
        let mut t = LeafTier::new();
        for key in 0..k {
            // Two requests each so no flow drains within the first K.
            leaf_enqueue(&mut t, caps, key, req(key)).unwrap();
            leaf_enqueue(&mut t, caps, key, req(key)).unwrap();
        }
        let first_round: HashSet<u64> = (0..k).map(|_| tag_of(&t.pick().expect("pick"))).collect();
        assert_eq!(
            first_round.len() as u64,
            k,
            "each of the K flows served exactly once in the first K picks"
        );
    }

    /// Draining a flow evicts it (gone from both maps) and discards its
    /// deficit; a re-appearing key starts a fresh flow.
    #[test]
    fn drain_evicts_and_resets_deficit() {
        let caps = open_caps();
        let mut t = LeafTier::new();
        leaf_enqueue(&mut t, caps, 9, req(9)).unwrap();
        assert_eq!(t.active_len(), 1);
        let _ = t.pick().expect("served");
        // Flow 9 drained: evicted from both structures.
        assert_eq!(t.active_len(), 0);
        assert!(!t.flows.contains_key(&9), "drained flow not removed");
        assert!(t.total_depth == 0);
        // Re-appearing key: brand-new flow, fresh (zero) deficit.
        leaf_enqueue(&mut t, caps, 9, req(9)).unwrap();
        assert_eq!(t.flows.get(&9).expect("re-created").deficit, 0);
        assert_leaf_invariants(&t);
    }

    /// `per_flow = 1`: each flow holds at most one queued request.
    #[test]
    fn boundary_per_flow_one() {
        let caps = Caps::new(1, 10, 100);
        let mut t = LeafTier::new();
        assert!(leaf_enqueue(&mut t, caps, 1, req(1)).is_ok());
        assert!(
            leaf_enqueue(&mut t, caps, 1, req(1)).is_err(),
            "second on flow exceeds 1"
        );
        assert!(
            leaf_enqueue(&mut t, caps, 2, req(2)).is_ok(),
            "other flow still enqueues"
        );
        assert_leaf_invariants(&t);
    }

    /// `max_flows = 1`: exactly one distinct flow at a time.
    #[test]
    fn boundary_max_flows_one() {
        let caps = Caps::new(10, 1, 100);
        let mut t = LeafTier::new();
        assert!(leaf_enqueue(&mut t, caps, 1, req(1)).is_ok());
        assert!(
            leaf_enqueue(&mut t, caps, 2, req(2)).is_err(),
            "second flow exceeds 1"
        );
        // After the sole flow drains, a different key may take the slot.
        let _ = t.pick().unwrap();
        assert!(leaf_enqueue(&mut t, caps, 2, req(2)).is_ok());
        assert_leaf_invariants(&t);
    }

    /// `per_flow = 0`: a degenerate flow can hold nothing (defence in
    /// depth; CLI validation forbids this value).
    #[test]
    fn boundary_per_flow_zero_rejects_all() {
        let caps = Caps::new(0, 10, 100);
        let mut t = LeafTier::new();
        assert!(leaf_enqueue(&mut t, caps, 1, req(1)).is_err());
        // No empty flow was inserted (invariant 2 preserved).
        assert!(t.flows.is_empty());
        assert!(t.total_depth == 0);
    }

    /// Single-flow saturation then drain: a lone flow can be filled to
    /// `per_flow` and fully drained in FIFO order.
    #[test]
    fn single_flow_saturation_and_drain() {
        let caps = Caps::new(4, 10, 100);
        let mut t = LeafTier::new();
        for i in 0..4u64 {
            leaf_enqueue(&mut t, caps, 1, req(i)).unwrap();
        }
        assert!(
            leaf_enqueue(&mut t, caps, 1, req(99)).is_err(),
            "5th exceeds per_flow = 4"
        );
        // Drains in FIFO order within the flow.
        let order: Vec<u64> = std::iter::from_fn(|| t.pick().map(|r| tag_of(&r))).collect();
        assert_eq!(order, vec![0, 1, 2, 3]);
        assert_leaf_invariants(&t);
    }

    /// The defence-in-depth clamps apply even when [`Caps::new`] is fed
    /// absurd values.
    #[test]
    fn caps_clamp_to_hard_ceilings() {
        let caps = Caps::new(usize::MAX, usize::MAX, usize::MAX)
            .with_max_signers(usize::MAX)
            .with_max_conn_backlog(usize::MAX);
        assert_eq!(caps.max_flows, HARD_MAX_FLOWS);
        assert_eq!(caps.max_signers, HARD_MAX_SIGNERS_PER_CONN);
        assert_eq!(caps.max_conn_backlog, HARD_MAX_QUEUE_DEPTH);
        assert_eq!(caps.global, HARD_MAX_QUEUE_DEPTH);
        // per_flow is intentionally un-clamped (it is bounded by global
        // in practice and validated by the CLI layer).
        assert_eq!(caps.per_flow, usize::MAX);
    }

    /// `max_conn_backlog` defaults to `per_flow` (clamped to `global`),
    /// restoring the Rung-0 per-connection backpressure: a
    /// freshly-constructed [`Caps`] caps a connection's aggregate at one
    /// `per_flow`'s worth, not `max_signers × per_flow`.
    #[test]
    fn max_conn_backlog_defaults_to_per_flow() {
        let caps = Caps::new(64, 4096, 1024);
        assert_eq!(caps.max_conn_backlog, caps.per_flow);
        assert_eq!(caps.max_conn_backlog, 64);
        // The default survives a `with_max_signers` chain (different field).
        let caps = caps.with_max_signers(256);
        assert_eq!(caps.max_conn_backlog, 64);
        // Clamped to `global` when `per_flow` would exceed it (a
        // per-connection cap can never beat the whole-scheduler cap).
        let tight = Caps::new(1000, 4096, 100);
        assert_eq!(tight.global, 100);
        assert_eq!(tight.max_conn_backlog, 100, "clamped to global");
    }

    /// The CLI defaults are the documented values.
    #[test]
    fn default_constants_stable() {
        assert_eq!(DEFAULT_PER_FLOW_CAP, 64);
        assert_eq!(DEFAULT_MAX_FLOWS, 4096);
        assert_eq!(HARD_MAX_FLOWS, 65_536);
        assert_eq!(DEFAULT_MAX_SIGNERS_PER_CONN, 256);
        assert_eq!(HARD_MAX_SIGNERS_PER_CONN, 65_536);
    }

    // ----- determinism + soak (FQ.1c) --------------------------------

    /// Op script for the property tests.
    #[derive(Clone, Copy, Debug)]
    enum Op {
        Enqueue(u64),
        Pick,
    }

    /// Run a script against fresh caps, returning the served-tag
    /// sequence.  Used for the determinism property.
    fn run_script(caps: Caps, script: &[Op]) -> Vec<Option<u64>> {
        let mut t = LeafTier::new();
        let mut out = Vec::new();
        for op in script {
            match *op {
                Op::Enqueue(k) => {
                    // Drop a rejected request (returned via Err).
                    let _ = leaf_enqueue(&mut t, caps, k, req(k));
                }
                Op::Pick => out.push(t.pick().map(|r| tag_of(&r))),
            }
        }
        out
    }

    use proptest::prelude::*;

    /// Strategy: a random op over a small key space (so flows collide
    /// and the caps fire) with picks interleaved.
    fn op_strategy() -> impl Strategy<Value = Op> {
        prop_oneof![(0u64..6).prop_map(Op::Enqueue), Just(Op::Pick)]
    }

    proptest! {
        /// Soak: arbitrary enqueue/pick interleavings never panic and
        /// the three structural invariants + the caps hold after every
        /// op.  (Fairness is exercised separately by the batch property
        /// below and the deterministic order tests above, because under
        /// *arbitrary* interleaving a late-arriving flow legitimately
        /// joins the back of the round behind an already-active flow —
        /// standard DRR, not unfairness.)
        #[test]
        fn structural_invariants_under_arbitrary_ops(
            ops in proptest::collection::vec(op_strategy(), 0..400)
        ) {
            // Moderate caps so rejections DO fire (state must survive
            // them) and stay within bounds.
            let caps = Caps::new(8, 4, 20);
            let mut t = LeafTier::new();
            for op in ops {
                match op {
                    Op::Enqueue(k) => {
                        let _ = leaf_enqueue(&mut t, caps, k, req(k));
                    }
                    Op::Pick => {
                        // A served request always belongs to the flow
                        // that was at the front (it was popped from it).
                        if let Some(r) = t.pick() {
                            prop_assert!(tag_of(&r) < 6);
                        }
                    }
                }
                // Invariant 1: total_depth == Σ store.depth().
                let summed: usize = t.flows.values().map(|f| f.store.depth()).sum();
                prop_assert_eq!(t.total_depth, summed);
                // Invariant 2: active set == flow keys, once each, all
                // non-empty.
                prop_assert_eq!(t.active.len(), t.flows.len());
                let active_set: BTreeSet<u64> = t.active.iter().copied().collect();
                prop_assert_eq!(active_set.len(), t.active.len());
                for key in &t.active {
                    let flow = t.flows.get(key).expect("active key present");
                    prop_assert!(flow.store.depth() > 0);
                    prop_assert!(flow.store.depth() <= caps.per_flow);
                }
                // Caps respected.  The single-tier `Tier` enforces
                // `max_flows` (distinct keys) and `per_flow` (backlog),
                // so its depth is bounded by their product; `global` is a
                // two-tier `DrrState` cap and is asserted there.
                prop_assert!(t.flows.len() <= caps.max_flows);
                prop_assert!(t.total_depth <= caps.per_flow * caps.max_flows);
            }
        }

        /// Equal-weight fairness bound: enqueue a random multiset of
        /// flows UP FRONT (all present before any pick — no late
        /// joiners), then drain.  After every pick, among the flows
        /// still active the per-flow served counts differ by at most 1
        /// (the §2.7 / FQ.1b bound).  This is the rigorous statement of
        /// "no active flow is served more than one request ahead of the
        /// least-served active flow."
        #[test]
        fn equal_weight_fairness_bound(
            flows in proptest::collection::vec((0u64..6, 1usize..6), 1..12)
        ) {
            let caps = open_caps();
            let mut t = LeafTier::new();
            // Batch-enqueue every flow before any pick.
            for &(key, count) in &flows {
                for _ in 0..count {
                    leaf_enqueue(&mut t, caps, key, req(key)).expect("open caps never reject");
                }
            }
            let mut served: BTreeMap<u64, u64> = BTreeMap::new();
            while let Some(r) = t.pick() {
                *served.entry(tag_of(&r)).or_insert(0) += 1;
                // Among flows STILL active, the served counts are within
                // one of each other.
                let counts: Vec<u64> = t
                    .active
                    .iter()
                    .map(|k| *served.get(k).unwrap_or(&0))
                    .collect();
                if let (Some(&mn), Some(&mx)) = (counts.iter().min(), counts.iter().max()) {
                    prop_assert!(
                        mx - mn <= 1,
                        "served spread {} exceeds equal-weight bound (counts {:?})",
                        mx - mn,
                        counts
                    );
                }
            }
            // Everything drained.
            prop_assert!(t.total_depth == 0);
        }

        /// Bounded-overtaking fairness under ARBITRARY interleavings —
        /// the general form of FQ.1b's equal-weight bound that holds even
        /// with late-joining flows.  Invariant: if two CONSECUTIVE picks
        /// return the same key X, then at the FIRST of those two picks X
        /// was the ONLY active flow.  Equivalently, the scheduler never
        /// serves X twice in a row while a *distinct* already-active flow
        /// waits; a second flow can only be "jumped" by joining the round
        /// AFTER X was last served (standard DRR: arrivals join the back).
        ///
        /// A `None` pick (empty queue) resets the relation: once every
        /// flow has drained, a later same-key service is a fresh flow
        /// instance, unrelated to the previous one.
        #[test]
        fn bounded_overtaking_under_arbitrary_ops(
            ops in proptest::collection::vec(op_strategy(), 0..400)
        ) {
            let caps = Caps::new(8, 4, 20);
            let mut t = LeafTier::new();
            // (key served by the previous pick, active_len just before it)
            let mut prev: Option<(u64, usize)> = None;
            for op in ops {
                match op {
                    Op::Enqueue(k) => {
                        let _ = leaf_enqueue(&mut t, caps, k, req(k));
                    }
                    Op::Pick => {
                        let active_before = t.active_len();
                        match t.pick() {
                            Some(r) => {
                                let k = tag_of(&r);
                                if let Some((pk, p_active_before)) = prev {
                                    if pk == k {
                                        prop_assert_eq!(
                                            p_active_before, 1,
                                            "served {} twice consecutively while {} flows \
                                             were active at the first service (overtaking)",
                                            k, p_active_before
                                        );
                                    }
                                }
                                prev = Some((k, active_before));
                            }
                            None => prev = None,
                        }
                    }
                }
            }
        }

        /// Determinism / replay: the same script yields the same served
        /// sequence on two independent runs.
        #[test]
        fn same_script_is_deterministic(
            ops in proptest::collection::vec(op_strategy(), 0..300)
        ) {
            let caps = Caps::new(8, 4, 20);
            let a = run_script(caps, &ops);
            let b = run_script(caps, &ops);
            prop_assert_eq!(a, b);
        }
    }

    // ===================================================================
    // Two-tier scheduler (Rung 1, FQ.11a/b): the production `DrrState`
    // routed by (ConnId, SignerHint).
    // ===================================================================

    /// Assert the two-tier structural invariants on a `DrrState`.
    fn assert_two_tier_invariants(s: &DrrState) {
        // Outer invariant 1: total_depth == Σ conn.store.depth().
        let outer_sum: usize = s.outer.flows.values().map(|f| f.store.depth()).sum();
        assert_eq!(s.outer.total_depth, outer_sum, "outer total_depth drifted");
        assert_eq!(s.len(), s.outer.total_depth);
        // Outer invariant 2: active conns == flow keys, once each,
        // all non-empty.
        assert_eq!(s.outer.active.len(), s.outer.flows.len());
        let outer_active: BTreeSet<&u64> = s.outer.active.iter().collect();
        assert_eq!(outer_active.len(), s.outer.active.len());
        for conn in &s.outer.active {
            let bucket = &s.outer.flows.get(conn).expect("active conn present").store;
            assert!(bucket.depth() > 0, "active conn is empty (not evicted)");
            // Inner invariant 1: bucket.total_depth == Σ leaf.depth().
            let inner_sum: usize = bucket.flows.values().map(|f| f.store.depth()).sum();
            assert_eq!(bucket.total_depth, inner_sum, "inner total_depth drifted");
            // Inner invariant 2.
            assert_eq!(bucket.active.len(), bucket.flows.len());
            for signer in &bucket.active {
                let leaf = bucket.flows.get(signer).expect("active signer present");
                assert!(leaf.store.depth() > 0, "active signer empty (not evicted)");
            }
        }
        // stats() agrees with the live accessors.
        let st = s.stats();
        assert_eq!(st.total_depth, s.outer.total_depth);
        assert_eq!(st.active_flows, s.outer.active.len());
        assert_eq!(st.active_signers, s.active_signers());
    }

    /// FQ.11a — two-tier enqueue accounting + eviction at both tiers:
    /// one connection with two signers drains by inner round-robin and
    /// the connection is evicted only when its last signer drains.
    #[test]
    fn two_tier_enqueue_and_eviction() {
        let mut s = DrrState::new(open_caps());
        // conn 1: signer 10 (×2), signer 11 (×1).
        s.enqueue(1, 10, req(10)).unwrap();
        s.enqueue(1, 10, req(10)).unwrap();
        s.enqueue(1, 11, req(11)).unwrap();
        assert_eq!(s.len(), 3);
        assert_eq!(s.active_len(), 1, "one active connection");
        assert_eq!(s.active_signers(), 2, "two active signers within it");
        assert_two_tier_invariants(&s);
        // Inner round-robin: 10, 11, 10 (signer 11 drains after one).
        let served: Vec<u64> = std::iter::from_fn(|| s.pick().map(|r| tag_of(&r))).collect();
        assert_eq!(served, vec![10, 11, 10]);
        assert!(s.is_empty());
        assert_eq!(
            s.active_len(),
            0,
            "connection evicted when last signer drained"
        );
        assert_two_tier_invariants(&s);
    }

    /// FQ.11b — outer fairness: two connections each get ~1/2 the worker
    /// regardless of how many signer hints each multiplexes.  conn A
    /// floods 6 requests under ONE signer; conn B sends 2 requests
    /// across TWO signers.  The outer round-robin alternates A, B, A,
    /// B, ... so B's two requests are served within the first 4 picks
    /// (not buried behind A's backlog).
    #[test]
    fn two_tier_outer_fairness_across_connections() {
        let mut s = DrrState::new(open_caps());
        for _ in 0..6 {
            s.enqueue(1, 100, req(1)).unwrap(); // conn A (one signer)
        }
        s.enqueue(2, 200, req(2)).unwrap(); // conn B, signer 200
        s.enqueue(2, 201, req(2)).unwrap(); // conn B, signer 201
        let served: Vec<u64> = std::iter::from_fn(|| s.pick().map(|r| tag_of(&r))).collect();
        // Both of conn B's requests are served within the first 4 picks
        // (outer alternation A,B,A,B), never queued behind A's backlog.
        let b_positions: Vec<usize> = served
            .iter()
            .enumerate()
            .filter(|(_, &k)| k == 2)
            .map(|(i, _)| i)
            .collect();
        assert_eq!(b_positions.len(), 2, "both of conn B's requests served");
        assert!(
            b_positions.iter().all(|&p| p < 4),
            "conn B served within the outer cycle, got positions {b_positions:?}"
        );
        assert_eq!(served.iter().filter(|&&k| k == 1).count(), 6);
    }

    /// FQ.11b — the spoof-confinement guarantee (`GP.8` §2.6 invariant
    /// 2): a connection spawning M distinct (forged) signer hints
    /// receives only its single OUTER share, subdivided among its M —
    /// never more than a one-hint connection's share.  Here the
    /// "attacker" conn 1 floods with M=8 distinct hints; the victim
    /// conn 2 uses one.  Over any window, conn 1 is served no more than
    /// once per conn-2 service (its outer turn yields exactly one
    /// request regardless of how many hints it multiplexes).
    #[test]
    fn two_tier_spoof_is_confined_to_forger_share() {
        let mut s = DrrState::new(open_caps());
        let m = 8u64;
        // Attacker conn 1: 4 requests under EACH of M distinct hints.
        for hint in 0..m {
            for _ in 0..4 {
                s.enqueue(1, 1000 + hint, req(1)).unwrap();
            }
        }
        // Victim conn 2: 4 requests under a single hint.
        for _ in 0..4 {
            s.enqueue(2, 9000, req(2)).unwrap();
        }
        // Drain and check: between any two consecutive victim services,
        // the attacker is served at most once (its single outer share).
        let served: Vec<u64> = std::iter::from_fn(|| s.pick().map(|r| tag_of(&r))).collect();
        // While BOTH connections are active, the outer round-robin
        // strictly alternates, so attacker count never exceeds victim
        // count by more than one at any prefix.
        let mut attacker = 0i64;
        let mut victim = 0i64;
        for &k in &served {
            if k == 1 {
                attacker += 1;
            } else {
                victim += 1;
            }
            // The attacker can lead the victim by at most one while both
            // are active (after the victim drains it legitimately runs
            // out its remaining backlog, so we stop checking then).
            if victim < 4 {
                assert!(
                    attacker - victim <= 1,
                    "attacker overtook victim ({attacker} vs {victim}) despite M hints"
                );
            }
        }
        // The victim got all four of its requests within the first 8
        // picks (one per outer cycle), NOT buried behind the attacker's
        // 32-request multi-hint backlog.
        let victim_positions: Vec<usize> = served
            .iter()
            .enumerate()
            .filter(|(_, &k)| k == 2)
            .map(|(i, _)| i)
            .collect();
        assert_eq!(victim_positions.len(), 4);
        assert!(
            victim_positions.iter().max().unwrap() < &8,
            "victim buried behind the spoofer: {victim_positions:?}"
        );
    }

    /// FQ.12 — `max_signers` caps distinct hints WITHIN one connection
    /// and is targeted: the offending connection's (M+1)-th distinct
    /// hint is `Busy`, while a second connection still opens new hints
    /// freely.
    #[test]
    fn max_signers_cap_is_targeted_per_connection() {
        let caps = Caps::new(64, 64, 1000).with_max_signers(2);
        let mut s = DrrState::new(caps);
        // conn 1: two distinct hints OK, third distinct hint Busy.
        s.enqueue(1, 10, req(10)).unwrap();
        s.enqueue(1, 11, req(11)).unwrap();
        let err = s
            .enqueue(1, 12, req(12))
            .expect_err("3rd hint breaches max_signers");
        assert_eq!(tag_of(&err), 12);
        assert_eq!(s.stats().rejected_max_signers, 1);
        // But an EXISTING hint on conn 1 still enqueues (cap is on
        // distinct hints, not backlog).
        s.enqueue(1, 10, req(10)).unwrap();
        // And conn 2 opens its own two hints freely (per-connection cap).
        s.enqueue(2, 20, req(20)).unwrap();
        s.enqueue(2, 21, req(21)).unwrap();
        assert_eq!(s.stats().rejected_max_signers, 1, "conn 2 unaffected");
        assert_two_tier_invariants(&s);
    }

    /// FQ.12 — `max_flows` caps distinct CONNECTIONS at the outer tier.
    #[test]
    fn two_tier_max_flows_caps_connections() {
        let caps = Caps::new(64, 2, 1000);
        let mut s = DrrState::new(caps);
        s.enqueue(1, 10, req(1)).unwrap();
        s.enqueue(2, 10, req(2)).unwrap();
        let err = s
            .enqueue(3, 10, req(3))
            .expect_err("3rd conn breaches max_flows");
        assert_eq!(tag_of(&err), 3);
        assert_eq!(s.stats().rejected_max_flows, 1);
        // Existing connection still enqueues.
        s.enqueue(1, 10, req(1)).unwrap();
        assert_two_tier_invariants(&s);
    }

    /// FQ.12 — the `global` cap bounds total depth across all
    /// (conn, signer) flows.
    #[test]
    fn two_tier_global_cap() {
        let caps = Caps::new(64, 64, 2);
        let mut s = DrrState::new(caps);
        s.enqueue(1, 10, req(1)).unwrap();
        s.enqueue(2, 20, req(2)).unwrap();
        let err = s.enqueue(3, 30, req(3)).expect_err("global breach");
        assert_eq!(tag_of(&err), 3);
        assert_eq!(s.stats().rejected_global, 1);
    }

    /// `global = 0`: every enqueue is rejected (everything `Busy`) — the
    /// boundary case, at the `DrrState` level where `global` lives
    /// (relocated from the single-tier suite, which has no `global` cap).
    #[test]
    fn drr_state_global_zero_rejects_all() {
        let mut s = DrrState::new(Caps::new(10, 10, 0));
        let err = s.enqueue(1, 10, req(1)).expect_err("global = 0 rejects");
        assert_eq!(tag_of(&err), 1, "the rejected request flows back");
        assert!(s.is_empty());
        assert_eq!(s.stats().rejected_global, 1);
    }

    /// Rung 1.5 — `max_conn_backlog` caps a connection's AGGREGATE
    /// backlog (summed across all its signer hints), independently of
    /// how the flood is split across hints, while a SECOND connection is
    /// unaffected (the cap is per-connection).  Here `max_conn_backlog =
    /// 3` with a generous `per_flow = 64` and `max_signers = 64`: conn 1
    /// spreads three requests across three distinct hints (each leaf far
    /// under `per_flow`), and the FOURTH — a fourth distinct hint, still
    /// under both `per_flow` and `max_signers` — is rejected because the
    /// connection's aggregate has hit the cap.
    #[test]
    fn max_conn_backlog_caps_connection_aggregate() {
        let caps = Caps::new(64, 64, 1000)
            .with_max_signers(64)
            .with_max_conn_backlog(3);
        let mut s = DrrState::new(caps);
        // conn 1: three requests across three DISTINCT hints — each leaf
        // depth 1 (far under per_flow), three distinct hints (under
        // max_signers) — yet the aggregate reaches the cap.
        s.enqueue(1, 10, req(10)).unwrap();
        s.enqueue(1, 11, req(11)).unwrap();
        s.enqueue(1, 12, req(12)).unwrap();
        // A fourth distinct hint: under per_flow AND max_signers, but the
        // connection's AGGREGATE is at the cap ⇒ ConnBacklog reject.
        let err = s
            .enqueue(1, 13, req(13))
            .expect_err("4th request breaches max_conn_backlog");
        assert_eq!(tag_of(&err), 13);
        assert_eq!(s.stats().rejected_conn_backlog, 1);
        // Neither the leaf nor the signer-count cap fired.
        assert_eq!(s.stats().rejected_per_flow, 0);
        assert_eq!(s.stats().rejected_max_signers, 0);
        // A SECOND connection is wholly unaffected (per-connection cap).
        s.enqueue(2, 20, req(20)).unwrap();
        s.enqueue(2, 21, req(21)).unwrap();
        s.enqueue(2, 22, req(22)).unwrap();
        assert_eq!(s.stats().rejected_conn_backlog, 1, "conn 2 unaffected");
        assert_two_tier_invariants(&s);
    }

    /// Rung 1.5 — a single-signer connection that floods past `per_flow`
    /// is reported as `rejected_per_flow`, NOT `rejected_conn_backlog`,
    /// EVEN when `max_conn_backlog == per_flow` (the default).  The leaf
    /// `per_flow` cap is checked first, so it stays the attributable
    /// binding constraint for a single-leaf flood and the two counters
    /// never collapse into one — the load-bearing property of the
    /// leaf-first check ordering.
    #[test]
    fn max_conn_backlog_does_not_shadow_per_flow_at_default() {
        // Default max_conn_backlog == per_flow == 2 (the coinciding case).
        let caps = Caps::new(2, 64, 1000).with_max_signers(64);
        assert_eq!(caps.max_conn_backlog, 2, "default == per_flow");
        assert_eq!(caps.per_flow, 2);
        let mut s = DrrState::new(caps);
        s.enqueue(1, 10, req(10)).unwrap();
        s.enqueue(1, 10, req(10)).unwrap();
        let err = s
            .enqueue(1, 10, req(10))
            .expect_err("3rd request breaches per_flow");
        assert_eq!(tag_of(&err), 10);
        assert_eq!(s.stats().rejected_per_flow, 1);
        assert_eq!(
            s.stats().rejected_conn_backlog,
            0,
            "leaf cap checked first ⇒ single-leaf flood is PerFlow, not ConnBacklog"
        );
        assert_two_tier_invariants(&s);
    }

    /// Rung-0 collapse: with every request on a connection routed to the
    /// SAME (sentinel) signer hint, the two-tier scheduler is exactly
    /// the Rung-0 per-connection round-robin (`GP.8` §2.6 invariant 3).
    /// This is what a legacy (un-hinted) connection does.
    #[test]
    fn single_signer_collapses_to_rung0() {
        // The legacy sentinel hint every un-hinted connection routes to.
        const SENTINEL: u64 = 0;
        let mut s = DrrState::new(open_caps());
        // conn 1 (whale): 3 requests; conn 2 (small): 1 — all under the
        // sentinel hint, mirroring legacy connections.
        for _ in 0..3 {
            s.enqueue(1, SENTINEL, req(1)).unwrap();
        }
        s.enqueue(2, SENTINEL, req(2)).unwrap();
        let served: Vec<u64> = std::iter::from_fn(|| s.pick().map(|r| tag_of(&r))).collect();
        // Identical to the Rung-0 `fair_drr_order_does_not_bury_small_flow`
        // expectation: 1, 2, 1, 1.
        assert_eq!(served, vec![1, 2, 1, 1]);
    }

    /// `set_closed` / `is_closed` toggle the lifecycle flag, and `pick`
    /// STILL drains a closed scheduler — `closed` gates only the
    /// wrapper's enqueue (so post-shutdown submissions get `Busy`), never
    /// the drain of already-buffered requests.
    #[test]
    fn closed_flag_toggles_and_pick_still_drains() {
        let mut s = DrrState::new(open_caps());
        assert!(!s.is_closed());
        s.enqueue(1, 10, req(1)).unwrap();
        s.enqueue(1, 10, req(1)).unwrap();
        s.set_closed();
        assert!(s.is_closed());
        // Closed does NOT block draining.
        assert!(s.pick().is_some());
        assert!(s.pick().is_some());
        assert!(s.pick().is_none());
        assert!(s.is_closed(), "closed stays set across picks");
    }

    /// `stats()` tracks dispatches and every per-reason rejection across
    /// both tiers.  An explicit loose `max_conn_backlog` (10 == global)
    /// keeps the aggregate cap out of the way so this test isolates the
    /// `per_flow` / `max_signers` / `max_flows` counters; the dedicated
    /// `max_conn_backlog_*` tests cover the aggregate-cap counter.
    #[test]
    fn two_tier_stats_track_all_reasons() {
        let caps = Caps::new(2, 2, 10)
            .with_max_signers(1)
            .with_max_conn_backlog(10);
        let mut s = DrrState::new(caps);
        // conn 1, signer 10: two OK, third per_flow reject.
        s.enqueue(1, 10, req(1)).unwrap();
        s.enqueue(1, 10, req(1)).unwrap();
        let _ = s.enqueue(1, 10, req(1)); // per_flow reject (leaf full)
                                          // conn 1, signer 11: max_signers reject (cap 1 per conn).
        let _ = s.enqueue(1, 11, req(1)); // max_signers reject (new hint)
                                          // conn 2 OK, conn 3 max_flows reject.
        s.enqueue(2, 20, req(2)).unwrap();
        let _ = s.enqueue(3, 30, req(3)); // max_flows reject
                                          // Dispatch two.
        let _ = s.pick();
        let _ = s.pick();
        let st = s.stats();
        assert_eq!(st.rejected_per_flow, 1);
        assert_eq!(st.rejected_max_signers, 1);
        assert_eq!(st.rejected_max_flows, 1);
        // The loose aggregate cap (10) never fired.
        assert_eq!(st.rejected_conn_backlog, 0);
        assert_eq!(st.dispatched, 2);
    }

    proptest! {
        /// Two-tier soak: arbitrary (conn, signer) enqueue / pick
        /// interleavings never panic and preserve both tiers' structural
        /// invariants + the caps.
        #[test]
        fn two_tier_structural_invariants_under_arbitrary_ops(
            ops in proptest::collection::vec(
                prop_oneof![
                    (0u64..3, 0u64..4).prop_map(|(c, sgn)| Some((c, sgn))),
                    Just(None),
                ],
                0..500,
            )
        ) {
            // A tight max_conn_backlog (5) sits strictly between per_flow
            // (4) and the implicit per-connection ceiling
            // max_signers × per_flow (8), so the aggregate cap genuinely
            // bites under some interleavings and is exercised here.
            let caps = Caps::new(4, 3, 30).with_max_signers(2).with_max_conn_backlog(5);
            let mut s = DrrState::new(caps);
            for op in ops {
                match op {
                    Some((c, sgn)) => {
                        let _ = s.enqueue(c, sgn, req(c));
                    }
                    None => {
                        let _ = s.pick();
                    }
                }
                // Outer invariant 1.
                let outer_sum: usize =
                    s.outer.flows.values().map(|f| f.store.depth()).sum();
                prop_assert_eq!(s.outer.total_depth, outer_sum);
                // Outer invariant 2 + inner invariants.
                prop_assert_eq!(s.outer.active.len(), s.outer.flows.len());
                for conn in &s.outer.active {
                    let bucket = &s.outer.flows.get(conn).expect("conn present").store;
                    prop_assert!(bucket.depth() > 0);
                    // Per-connection aggregate cap respected (Rung 1.5):
                    // the bucket's total depth never exceeds the configured
                    // aggregate bound, no matter how the flood is split.
                    prop_assert!(bucket.depth() <= caps.max_conn_backlog);
                    let inner_sum: usize =
                        bucket.flows.values().map(|f| f.store.depth()).sum();
                    prop_assert_eq!(bucket.total_depth, inner_sum);
                    prop_assert_eq!(bucket.active.len(), bucket.flows.len());
                    prop_assert!(bucket.flows.len() <= caps.max_signers);
                    for signer in &bucket.active {
                        let leaf = bucket.flows.get(signer).expect("signer present");
                        prop_assert!(leaf.store.depth() > 0);
                        prop_assert!(leaf.store.depth() <= caps.per_flow);
                    }
                }
                // Caps respected.
                prop_assert!(s.outer.total_depth <= caps.global);
                prop_assert!(s.outer.flows.len() <= caps.max_flows);
            }
        }

        /// Spoof-confinement under ARBITRARY interleavings (the §2.6(2)
        /// property): a forged-hint flood on the "attacker" connection
        /// cannot steal more than its single OUTER share from the
        /// "victim" connection.  Concretely, in the two-connection
        /// round-robin the attacker gets AT MOST ONE service between two
        /// consecutive victim services WHILE the victim is contending —
        /// no matter how many distinct hints the attacker multiplexes.
        ///
        /// We track `atk_since_vic`, the attacker services since the
        /// victim's last service.  It is reset to 0 whenever the victim
        /// is served OR the victim has no backlog (then the attacker may
        /// legitimately run the worker alone — work-conserving, §2.7 —
        /// and a fresh contention window starts clean).  The absolute
        /// served counts can diverge (the attacker may have run for ages
        /// before the victim ever connected); what spoof-confinement
        /// bounds is the FORWARD share once the victim contends.
        #[test]
        fn two_tier_spoof_confinement_property(
            ops in proptest::collection::vec(
                prop_oneof![
                    // attacker conn 1 with one of 6 distinct hints
                    (0u64..6).prop_map(EnqOp::Atk),
                    // victim conn 2, single hint
                    Just(EnqOp::Vic),
                    Just(EnqOp::Pick),
                ],
                0..600,
            )
        ) {
            let caps = Caps::new(16, 16, 400).with_max_signers(16);
            let mut s = DrrState::new(caps);
            let mut vic_enq = 0i64;
            let mut vic_served = 0i64;
            // Attacker services since the victim's last service.
            let mut atk_since_vic = 0i64;
            for op in ops {
                match op {
                    EnqOp::Atk(h) => {
                        let _ = s.enqueue(1, 100 + h, req(1));
                    }
                    EnqOp::Vic => {
                        if s.enqueue(2, 9999, req(2)).is_ok() {
                            vic_enq += 1;
                        }
                    }
                    EnqOp::Pick => {
                        if let Some(r) = s.pick() {
                            if tag_of(&r) == 1 {
                                atk_since_vic += 1;
                                // The bound bites only while the victim is
                                // actually waiting (has outstanding work):
                                // then the attacker must not have taken two
                                // turns in a row past the victim.
                                let vic_backlog = vic_enq - vic_served;
                                if vic_backlog > 0 {
                                    prop_assert!(
                                        atk_since_vic <= 1,
                                        "attacker took {} turns since the victim's last \
                                         service while the victim waited (spoof leaked)",
                                        atk_since_vic
                                    );
                                }
                            } else {
                                // Victim served: the window resets.
                                vic_served += 1;
                                atk_since_vic = 0;
                            }
                        }
                    }
                }
                // The victim isn't contending: the attacker may run the
                // worker freely (work-conserving), so start the next
                // contention window clean.
                if vic_enq - vic_served == 0 {
                    atk_since_vic = 0;
                }
            }
        }
    }

    /// Op for the spoof-confinement property test.
    #[derive(Clone, Copy, Debug)]
    enum EnqOp {
        /// Attacker (conn 1) enqueue under hint `h`.
        Atk(u64),
        /// Victim (conn 2) enqueue under its single hint.
        Vic,
        /// Pick one request.
        Pick,
    }

    /// `ConnBucket` (the inner tier alias) is exercised directly: a
    /// fresh bucket round-robins its signers and reports depth.
    #[test]
    fn conn_bucket_inner_round_robin() {
        let mut bucket = ConnBucket::new();
        // (per_flow, max_signers, max_conn_backlog) all generous here.
        bucket.enqueue_signer(1, req(1), 64, 64, 64).unwrap();
        bucket.enqueue_signer(2, req(2), 64, 64, 64).unwrap();
        bucket.enqueue_signer(1, req(1), 64, 64, 64).unwrap();
        assert_eq!(bucket.depth(), 3);
        let a = bucket.serve().map(|r| tag_of(&r));
        let b = bucket.serve().map(|r| tag_of(&r));
        let c = bucket.serve().map(|r| tag_of(&r));
        // Round-robin: 1, 2, 1.
        assert_eq!((a, b, c), (Some(1), Some(2), Some(1)));
        assert_eq!(bucket.depth(), 0);
    }
}
