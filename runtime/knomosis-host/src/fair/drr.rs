// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Pure Deficit-Round-Robin (DRR) scheduler core (Workstream GP.8,
//! Track A / FQ — Rung 0).
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
//!   * **Generic over the routing key.**  Rung 0 instantiates
//!     `DrrState<ConnId>`; the Rung-1 two-tier extension (FQ.11)
//!     reuses the same logic for the inner signer-hint tier.
//!
//! ## The algorithm (equal-weight DRR ≡ round-robin)
//!
//! Each *flow* (the requests sharing one routing key) owns a FIFO
//! `deque`, a `deficit` counter, and a `quantum`.  A `cost` of one
//! credit is charged per dispatched request (one worker slot — no
//! payload inspection needed).  On a flow's turn the scheduler grants
//! it one `quantum` of credit; while `cost <= deficit` it serves the
//! head and debits `cost`.  Rung 0 uses `quantum = cost = 1`, so DRR
//! collapses to **strict per-flow round-robin**: serve one, rotate.
//! The `deficit` / `quantum` machinery is retained (not elided) so a
//! future budget-weighted quantum (`GP.8` §2.7 / §9) is a drop-in.
//!
//! ## Invariants (checked by the test suite)
//!
//!   1. `total_depth == Σ flow.deque.len()` over all flows.
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
//! Three integer caps live in [`Caps`] and are enforced by `enqueue`:
//! `global` bounds the total buffered requests, `max_flows` bounds the
//! distinct active flows, and `per_flow` bounds one flow's backlog.
//! On any breach `enqueue` hands the request back (`Err(req)`) so the
//! wrapper can answer `Busy` — nothing is silently dropped.  The
//! `per_flow` cap is what makes a flooding flow back-pressure *itself*
//! while other flows keep enqueuing (`GP.8` §2.4).

use std::collections::btree_map::Entry;
use std::collections::{BTreeMap, VecDeque};

use crate::queue::{QueuedRequest, HARD_MAX_QUEUE_DEPTH};

/// Default per-flow backlog cap (the `--per-flow-cap` default).
///
/// 64 buffered requests per flow is generous for a well-behaved
/// client while still bounding a single flow's footprint.
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

/// The per-turn credit granted to a flow and the credit charged per
/// dispatched request.  Equal weight (`quantum == cost == 1`) makes
/// DRR collapse to strict round-robin (`GP.8` §2.7).
const QUANTUM: u64 = 1;

/// The credit one dispatched request consumes (one worker slot).
const COST: u64 = 1;

/// Capacity caps for the DRR scheduler.
///
/// All three are enforced atomically inside [`DrrState::enqueue`]
/// (under the caller's lock).  See the module docstring for the
/// capacity model.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Caps {
    /// Maximum requests buffered within a single flow.  A flooding
    /// flow that hits this cap is told `Busy` on its *own*
    /// over-submission while other flows still enqueue freely.
    pub per_flow: usize,
    /// Maximum number of distinct active flows.  Bounds the
    /// scheduler's map growth; enforced only when a *new* key would
    /// be created.
    pub max_flows: usize,
    /// Maximum total buffered requests across all flows.  The
    /// scheduler-wide backpressure bound; Rung 0 reuses the host's
    /// `--max-queue-depth` for this value.
    pub global: usize,
}

impl Caps {
    /// Construct caps from the three bounds, applying the
    /// defence-in-depth ceilings ([`HARD_MAX_FLOWS`] on `max_flows`,
    /// [`crate::queue::HARD_MAX_QUEUE_DEPTH`] on `global`).  The CLI
    /// validation layer ([`crate::config`]) rejects out-of-range
    /// values *loudly* before reaching here; this clamp is the
    /// belt-and-braces guard for direct library consumers, parallel
    /// to [`crate::frame::read_frame`]'s frame-size clamp.
    #[must_use]
    pub fn new(per_flow: usize, max_flows: usize, global: usize) -> Self {
        Self {
            per_flow,
            max_flows: max_flows.min(HARD_MAX_FLOWS),
            global: global.min(HARD_MAX_QUEUE_DEPTH),
        }
    }
}

/// One flow's queue plus its DRR accounting.
///
/// Private: the scheduler owns the only instances and maintains the
/// "a flow in the map is always non-empty" invariant.  The `quantum`
/// field is per-flow so a future weighted scheduler can vary it; Rung
/// 0 always sets it to [`QUANTUM`] (= 1).
#[derive(Debug)]
struct Flow {
    /// FIFO backlog of requests for this flow.  Never empty while the
    /// flow is present in [`DrrState::flows`] (drained flows are
    /// evicted).
    deque: VecDeque<QueuedRequest>,
    /// Accumulated DRR credit.  Topped up by `quantum` on each turn;
    /// debited by [`COST`] per served request; discarded on eviction.
    deficit: u64,
    /// Per-turn credit grant.  Always [`QUANTUM`] in Rung 0.
    quantum: u64,
}

impl Flow {
    /// A fresh flow holding its first request, with zero deficit and
    /// the equal-weight quantum.
    fn new(first: QueuedRequest) -> Self {
        let mut deque = VecDeque::new();
        deque.push_back(first);
        Self {
            deque,
            deficit: 0,
            quantum: QUANTUM,
        }
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
    /// Current number of distinct active (non-empty) flows.
    pub active_flows: usize,
    /// Lifetime count of requests dispatched via `pick`.
    pub dispatched: u64,
    /// Lifetime count of enqueue rejections due to the `per_flow` cap.
    pub rejected_per_flow: u64,
    /// Lifetime count of enqueue rejections due to the `max_flows` cap.
    pub rejected_max_flows: u64,
    /// Lifetime count of enqueue rejections due to the `global` cap.
    pub rejected_global: u64,
}

/// The pure DRR scheduler state, generic over the routing `Key`.
///
/// Rung 0 instantiates `DrrState<ConnId>`.  All mutation happens
/// through [`DrrState::enqueue`] and [`DrrState::pick`]; the rest of
/// the surface is read-only accessors for the wrapper's `Condvar`
/// predicate and for observability.
#[derive(Debug)]
pub struct DrrState<Key: Ord + Clone> {
    /// Per-key flows.  Every value is non-empty (invariant 2).
    flows: BTreeMap<Key, Flow>,
    /// Round-robin order of the active (non-empty) flow keys.  Drives
    /// the dispatch order; `pick` serves the front and rotates it to
    /// the back (or evicts it on drain).
    active: VecDeque<Key>,
    /// Cached `Σ flow.deque.len()` (invariant 1) so `len` is O(1).
    total_depth: usize,
    /// The capacity caps (already clamped via [`Caps::new`]).
    caps: Caps,
    /// Lifetime dispatch count (FQ.6).
    dispatched: u64,
    /// Lifetime `per_flow`-cap rejection count (FQ.6).
    rejected_per_flow: u64,
    /// Lifetime `max_flows`-cap rejection count (FQ.6).
    rejected_max_flows: u64,
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

impl<Key: Ord + Clone> DrrState<Key> {
    /// Construct an empty scheduler with the given caps.  The caps are
    /// passed through [`Caps::new`] so the defence-in-depth ceilings
    /// always apply.
    #[must_use]
    pub fn new(caps: Caps) -> Self {
        Self {
            flows: BTreeMap::new(),
            active: VecDeque::new(),
            total_depth: 0,
            caps: Caps::new(caps.per_flow, caps.max_flows, caps.global),
            dispatched: 0,
            rejected_per_flow: 0,
            rejected_max_flows: 0,
            rejected_global: 0,
            closed: false,
        }
    }

    /// Enqueue `req` under `key`.
    ///
    /// Enforces, in order, the `global`, `max_flows` (only when `key`
    /// is new), and `per_flow` caps.  On any breach the request is
    /// handed back unchanged via `Err(req)` — the wrapper maps this to
    /// `Busy`; nothing is silently dropped.  On success the request is
    /// appended to its flow, a brand-new flow's key is pushed to the
    /// `active` round, and `total_depth` is bumped.
    ///
    /// The map is touched via a single [`Entry`] lookup (no
    /// check-then-insert), and the whole call is intended to run under
    /// the wrapper's lock, so the cap checks are atomic with the
    /// mutation.
    ///
    /// # Errors
    ///
    /// Returns `Err(req)` (the original request) when `global`,
    /// `max_flows`, or `per_flow` would be exceeded.
    pub fn enqueue(&mut self, key: Key, req: QueuedRequest) -> Result<(), QueuedRequest> {
        // Snapshot the caps + the current flow count before borrowing
        // the map via `entry` (both are O(1) and need no tree walk).
        let Caps {
            per_flow,
            max_flows,
            global,
        } = self.caps;

        // 1. Global cap: bounds total buffered requests.  Checked
        //    first so a saturated host rejects uniformly regardless of
        //    which flow the request targets.
        if self.total_depth >= global {
            self.rejected_global = self.rejected_global.saturating_add(1);
            return Err(req);
        }

        let flow_count = self.flows.len();
        match self.flows.entry(key) {
            Entry::Occupied(mut occ) => {
                // Existing flow ⇒ already in `active` (invariant 2) and
                // non-empty.  Only the `per_flow` cap applies.
                if occ.get().deque.len() >= per_flow {
                    self.rejected_per_flow = self.rejected_per_flow.saturating_add(1);
                    return Err(req);
                }
                occ.get_mut().deque.push_back(req);
                self.total_depth += 1;
                Ok(())
            }
            Entry::Vacant(vac) => {
                // New flow ⇒ enforce `max_flows`, then the degenerate
                // `per_flow == 0` case (a zero-cap flow can hold
                // nothing).  CLI validation forbids `per_flow == 0`,
                // but the pure core stays robust regardless.
                if flow_count >= max_flows {
                    self.rejected_max_flows = self.rejected_max_flows.saturating_add(1);
                    return Err(req);
                }
                if per_flow == 0 {
                    self.rejected_per_flow = self.rejected_per_flow.saturating_add(1);
                    return Err(req);
                }
                let activated_key = vac.key().clone();
                vac.insert(Flow::new(req));
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
    /// Pops the front flow's head, debiting one [`COST`] from its
    /// deficit (which was just topped up by one [`QUANTUM`]). With the
    /// equal-weight quantum the credit always covers exactly one
    /// request, so a flow serves its head on every turn. A drained
    /// flow is evicted from both maps (its deficit discarded); a flow
    /// that still has work is rotated to the back of the round.
    ///
    /// Deterministic and I/O-free: reads no clock, performs no I/O.
    pub fn pick(&mut self) -> Option<QueuedRequest> {
        let key = self.active.front()?.clone();
        let flow = self
            .flows
            .get_mut(&key)
            .expect("invariant: every key in `active` maps to a non-empty flow");

        // DRR turn entry: grant one quantum of credit (saturating, so a
        // pathological weighted future can never overflow).
        flow.deficit = flow.deficit.saturating_add(flow.quantum);
        // With `quantum == COST == 1` the credit always covers exactly
        // one request, so the flow serves its head every turn — DRR is
        // strict round-robin.  The invariant `quantum >= COST` (which
        // guarantees forward progress) is asserted, not assumed, so a
        // future weighted quantum is a safe drop-in.
        debug_assert!(
            flow.deficit >= COST,
            "quantum must be >= cost so every turn makes progress"
        );

        let req = flow
            .deque
            .pop_front()
            .expect("invariant: an active flow is non-empty");
        flow.deficit -= COST;
        self.total_depth -= 1;
        self.dispatched = self.dispatched.saturating_add(1);

        if flow.deque.is_empty() {
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

    /// Total buffered requests across all flows (== `Σ deque.len()`).
    #[must_use]
    pub fn len(&self) -> usize {
        self.total_depth
    }

    /// `true` iff no request is buffered (the `Condvar` wait
    /// predicate).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.total_depth == 0
    }

    /// Number of distinct active (non-empty) flows.
    #[must_use]
    pub fn active_len(&self) -> usize {
        self.active.len()
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
            total_depth: self.total_depth,
            active_flows: self.active.len(),
            dispatched: self.dispatched,
            rejected_per_flow: self.rejected_per_flow,
            rejected_max_flows: self.rejected_max_flows,
            rejected_global: self.rejected_global,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Caps, DrrState, DEFAULT_MAX_FLOWS, DEFAULT_PER_FLOW_CAP, HARD_MAX_FLOWS};
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
        Caps::new(1_000, 1_000, 1_000_000)
    }

    /// Assert the three structural invariants on a scheduler.
    fn assert_invariants<K: Ord + Clone>(state: &DrrState<K>) {
        // Invariant 1: total_depth == Σ deque.len().
        let summed: usize = state.flows.values().map(|f| f.deque.len()).sum();
        assert_eq!(state.total_depth, summed, "total_depth drifted from Σ len");
        assert_eq!(state.len(), state.total_depth);
        assert_eq!(state.is_empty(), state.total_depth == 0);
        // Invariant 2: active set == flow keys, once each, all non-empty.
        assert_eq!(
            state.active.len(),
            state.flows.len(),
            "active/flows cardinality mismatch"
        );
        assert_eq!(state.active_len(), state.active.len());
        let active_set: BTreeSet<&K> = state.active.iter().collect();
        assert_eq!(
            active_set.len(),
            state.active.len(),
            "duplicate key in active"
        );
        for key in &state.active {
            let flow = state.flows.get(key).expect("active key absent from flows");
            assert!(!flow.deque.is_empty(), "active flow is empty (not evicted)");
        }
        // stats() agrees with the live accessors.
        let s = state.stats();
        assert_eq!(s.total_depth, state.total_depth);
        assert_eq!(s.active_flows, state.active.len());
    }

    // ----- enqueue: caps + bookkeeping (FQ.1a) -----------------------

    /// `per_flow` cap independently returns the request back.
    #[test]
    fn per_flow_cap_rejects_and_returns_request() {
        let mut s = DrrState::new(Caps::new(2, 10, 100));
        assert!(s.enqueue(7u64, req(7)).is_ok());
        assert!(s.enqueue(7, req(7)).is_ok());
        // Third on the same flow breaches per_flow = 2.
        let err = s.enqueue(7, req(999)).expect_err("per_flow breach");
        assert_eq!(tag_of(&err), 999, "the rejected request must flow back");
        assert_eq!(s.stats().rejected_per_flow, 1);
        assert_eq!(s.len(), 2);
        assert_invariants(&s);
    }

    /// `max_flows` cap independently returns the request back, but only
    /// when the key is new (an existing flow is unaffected).
    #[test]
    fn max_flows_cap_rejects_new_keys_only() {
        let mut s = DrrState::new(Caps::new(10, 2, 100));
        assert!(s.enqueue(1u64, req(1)).is_ok());
        assert!(s.enqueue(2, req(2)).is_ok());
        // Third DISTINCT key breaches max_flows = 2.
        let err = s.enqueue(3, req(3)).expect_err("max_flows breach");
        assert_eq!(tag_of(&err), 3);
        assert_eq!(s.stats().rejected_max_flows, 1);
        // An existing key still enqueues (cap is on distinct flows).
        assert!(s.enqueue(1, req(1)).is_ok());
        assert_eq!(s.len(), 3);
        assert_invariants(&s);
    }

    /// `global` cap independently returns the request back.
    #[test]
    fn global_cap_rejects_and_returns_request() {
        let mut s = DrrState::new(Caps::new(10, 10, 2));
        assert!(s.enqueue(1u64, req(1)).is_ok());
        assert!(s.enqueue(2, req(2)).is_ok());
        // Third request (any flow) breaches global = 2.
        let err = s.enqueue(3, req(42)).expect_err("global breach");
        assert_eq!(tag_of(&err), 42);
        assert_eq!(s.stats().rejected_global, 1);
        assert_eq!(s.len(), 2);
        assert_invariants(&s);
    }

    /// Activation bookkeeping: a new key registers exactly one active
    /// entry; repeated enqueues on it do not duplicate it.
    #[test]
    fn activation_bookkeeping_is_exact() {
        let mut s = DrrState::new(open_caps());
        s.enqueue(5u64, req(5)).unwrap();
        assert_eq!(s.active_len(), 1);
        s.enqueue(5, req(5)).unwrap();
        s.enqueue(5, req(5)).unwrap();
        assert_eq!(s.active_len(), 1, "same key must not re-activate");
        s.enqueue(6, req(6)).unwrap();
        assert_eq!(s.active_len(), 2);
        assert_eq!(s.len(), 4);
        assert_invariants(&s);
    }

    // ----- pick: order, starvation, eviction (FQ.1b) -----------------

    /// `pick` on an empty scheduler is `None`.
    #[test]
    fn pick_empty_is_none() {
        let mut s: DrrState<u64> = DrrState::new(open_caps());
        assert!(s.pick().is_none());
    }

    /// Round-robin order across N flows (one request each → exactly the
    /// `active` insertion order, then exhausted).
    #[test]
    fn round_robin_order_across_flows() {
        let mut s = DrrState::new(open_caps());
        for k in 0..4u64 {
            s.enqueue(k, req(k)).unwrap();
        }
        let served: Vec<u64> = std::iter::from_fn(|| s.pick().map(|r| tag_of(&r))).collect();
        assert_eq!(served, vec![0, 1, 2, 3]);
        assert!(s.is_empty());
        assert_invariants(&s);
    }

    /// A heavy flow does not starve a light flow: the light flow's lone
    /// request is served within `active_flows` picks, NOT behind the
    /// whole backlog (the §2.4 head-of-line defect FIFO would exhibit).
    #[test]
    fn heavy_flow_does_not_starve_light_flow() {
        let mut s = DrrState::new(open_caps());
        // Whale (key 1) enqueues 5; small (key 2) enqueues 1.  Whale
        // first, so under FIFO the small request would be 6th.
        for _ in 0..5 {
            s.enqueue(1u64, req(1)).unwrap();
        }
        s.enqueue(2, req(2)).unwrap();
        let served: Vec<u64> = std::iter::from_fn(|| s.pick().map(|r| tag_of(&r))).collect();
        // DRR serves: whale, small, whale, whale, whale, whale.
        let small_pos = served.iter().position(|&k| k == 2).expect("small served");
        assert!(
            small_pos < s.active_len().max(2),
            "small served at {small_pos}, expected within active_flows"
        );
        assert_eq!(served[0], 1);
        assert_eq!(served[1], 2, "small request served on its first turn");
        assert_eq!(served.iter().filter(|&&k| k == 1).count(), 5);
        assert_invariants(&s);
    }

    /// With K active flows, every flow's head is served within the
    /// first K picks (the no-starvation bound, FQ.1b/FQ.7a).
    #[test]
    fn every_head_served_within_k_picks() {
        let k = 6u64;
        let mut s = DrrState::new(open_caps());
        for key in 0..k {
            // Two requests each so no flow drains within the first K.
            s.enqueue(key, req(key)).unwrap();
            s.enqueue(key, req(key)).unwrap();
        }
        let first_round: HashSet<u64> = (0..k).map(|_| tag_of(&s.pick().expect("pick"))).collect();
        assert_eq!(
            first_round.len() as u64,
            k,
            "each of the K flows served exactly once in the first K picks"
        );
        assert_invariants(&s);
    }

    /// Draining a flow evicts it (gone from both maps) and discards its
    /// deficit; a re-appearing key starts a fresh flow.
    #[test]
    fn drain_evicts_and_resets_deficit() {
        let mut s = DrrState::new(open_caps());
        s.enqueue(9u64, req(9)).unwrap();
        assert_eq!(s.active_len(), 1);
        let _ = s.pick().expect("served");
        // Flow 9 drained: evicted from both structures.
        assert_eq!(s.active_len(), 0);
        assert!(!s.flows.contains_key(&9), "drained flow not removed");
        assert!(s.is_empty());
        // Re-appearing key: brand-new flow, fresh (zero) deficit.
        s.enqueue(9, req(9)).unwrap();
        assert_eq!(s.flows.get(&9).expect("re-created").deficit, 0);
        assert_invariants(&s);
    }

    // ----- boundary caps (FQ.1c) -------------------------------------

    /// `per_flow = 1`: each flow holds at most one queued request.
    #[test]
    fn boundary_per_flow_one() {
        let mut s = DrrState::new(Caps::new(1, 10, 100));
        assert!(s.enqueue(1u64, req(1)).is_ok());
        assert!(s.enqueue(1, req(1)).is_err(), "second on flow exceeds 1");
        assert!(s.enqueue(2, req(2)).is_ok(), "other flow still enqueues");
        assert_invariants(&s);
    }

    /// `max_flows = 1`: exactly one distinct flow at a time.
    #[test]
    fn boundary_max_flows_one() {
        let mut s = DrrState::new(Caps::new(10, 1, 100));
        assert!(s.enqueue(1u64, req(1)).is_ok());
        assert!(s.enqueue(2, req(2)).is_err(), "second flow exceeds 1");
        // After the sole flow drains, a different key may take the slot.
        let _ = s.pick().unwrap();
        assert!(s.enqueue(2, req(2)).is_ok());
        assert_invariants(&s);
    }

    /// `global = 0`: every enqueue is rejected (everything `Busy`).
    #[test]
    fn boundary_global_zero_rejects_all() {
        let mut s = DrrState::new(Caps::new(10, 10, 0));
        assert!(s.enqueue(1u64, req(1)).is_err());
        assert_eq!(s.stats().rejected_global, 1);
        assert!(s.is_empty());
    }

    /// `per_flow = 0`: a degenerate flow can hold nothing (defence in
    /// depth; CLI validation forbids this value).
    #[test]
    fn boundary_per_flow_zero_rejects_all() {
        let mut s = DrrState::new(Caps::new(0, 10, 100));
        assert!(s.enqueue(1u64, req(1)).is_err());
        assert_eq!(s.stats().rejected_per_flow, 1);
        assert!(s.is_empty());
    }

    /// Single-flow saturation then drain: a lone flow can be filled to
    /// `per_flow` and fully drained in FIFO order.
    #[test]
    fn single_flow_saturation_and_drain() {
        let mut s = DrrState::new(Caps::new(4, 10, 100));
        for i in 0..4u64 {
            s.enqueue(1u64, req(i)).unwrap();
        }
        assert!(s.enqueue(1, req(99)).is_err(), "5th exceeds per_flow = 4");
        // Drains in FIFO order within the flow.
        let order: Vec<u64> = std::iter::from_fn(|| s.pick().map(|r| tag_of(&r))).collect();
        assert_eq!(order, vec![0, 1, 2, 3]);
        assert_invariants(&s);
    }

    /// `set_closed` / `is_closed` toggle the lifecycle flag, and `pick`
    /// STILL drains a closed scheduler — `closed` gates only the
    /// wrapper's enqueue (so post-shutdown submissions get `Busy`), never
    /// the drain of already-buffered requests.
    #[test]
    fn closed_flag_toggles_and_pick_still_drains() {
        let mut s = DrrState::new(open_caps());
        assert!(!s.is_closed());
        s.enqueue(1u64, req(1)).unwrap();
        s.enqueue(1, req(1)).unwrap();
        s.set_closed();
        assert!(s.is_closed());
        // Closed does NOT block draining: the scheduler still serves the
        // already-buffered requests (the worker drains after close()).
        assert!(s.pick().is_some());
        assert!(s.pick().is_some());
        assert!(s.pick().is_none());
        assert!(s.is_closed(), "closed stays set across picks");
        assert_invariants(&s);
    }

    /// The defence-in-depth clamps apply even when [`Caps::new`] is fed
    /// absurd values.
    #[test]
    fn caps_clamp_to_hard_ceilings() {
        let caps = Caps::new(usize::MAX, usize::MAX, usize::MAX);
        assert_eq!(caps.max_flows, HARD_MAX_FLOWS);
        assert_eq!(caps.global, HARD_MAX_QUEUE_DEPTH);
        // per_flow is intentionally un-clamped (it is bounded by global
        // in practice and validated by the CLI layer).
        assert_eq!(caps.per_flow, usize::MAX);
    }

    /// The CLI defaults are the documented values.
    #[test]
    fn default_constants_stable() {
        assert_eq!(DEFAULT_PER_FLOW_CAP, 64);
        assert_eq!(DEFAULT_MAX_FLOWS, 4096);
        assert_eq!(HARD_MAX_FLOWS, 65_536);
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
        let mut s = DrrState::new(caps);
        let mut out = Vec::new();
        for op in script {
            match *op {
                Op::Enqueue(k) => {
                    // Drop a rejected request (returned via Err).
                    let _ = s.enqueue(k, req(k));
                }
                Op::Pick => out.push(s.pick().map(|r| tag_of(&r))),
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
            let mut s = DrrState::new(caps);
            for op in ops {
                match op {
                    Op::Enqueue(k) => {
                        let _ = s.enqueue(k, req(k));
                    }
                    Op::Pick => {
                        // A served request always belongs to the flow
                        // that was at the front (it was popped from it).
                        if let Some(r) = s.pick() {
                            prop_assert!(tag_of(&r) < 6);
                        }
                    }
                }
                // Invariant 1: total_depth == Σ deque.len().
                let summed: usize = s.flows.values().map(|f| f.deque.len()).sum();
                prop_assert_eq!(s.total_depth, summed);
                // Invariant 2: active set == flow keys, once each, all
                // non-empty.
                prop_assert_eq!(s.active.len(), s.flows.len());
                let active_set: BTreeSet<u64> = s.active.iter().copied().collect();
                prop_assert_eq!(active_set.len(), s.active.len());
                for key in &s.active {
                    let flow = s.flows.get(key).expect("active key present");
                    prop_assert!(!flow.deque.is_empty());
                    prop_assert!(flow.deque.len() <= caps.per_flow);
                }
                // Caps respected.
                prop_assert!(s.total_depth <= caps.global);
                prop_assert!(s.flows.len() <= caps.max_flows);
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
            let mut s = DrrState::new(open_caps());
            // Batch-enqueue every flow before any pick.
            for &(key, count) in &flows {
                for _ in 0..count {
                    s.enqueue(key, req(key)).expect("open caps never reject");
                }
            }
            let mut served: BTreeMap<u64, u64> = BTreeMap::new();
            while let Some(r) = s.pick() {
                *served.entry(tag_of(&r)).or_insert(0) += 1;
                // Among flows STILL active, the served counts are within
                // one of each other.
                let counts: Vec<u64> = s
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
            prop_assert!(s.is_empty());
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
            let mut s = DrrState::new(caps);
            // (key served by the previous pick, active_len just before it)
            let mut prev: Option<(u64, usize)> = None;
            for op in ops {
                match op {
                    Op::Enqueue(k) => {
                        let _ = s.enqueue(k, req(k));
                    }
                    Op::Pick => {
                        let active_before = s.active_len();
                        match s.pick() {
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
}
