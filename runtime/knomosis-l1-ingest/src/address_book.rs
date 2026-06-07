// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Rust mirror of Lean's `LegalKernel.Bridge.AddressBook`.
//!
//! Maps Ethereum 20-byte addresses (`EthAddress`) to Knomosis
//! `ActorId`s.  The discipline:
//!
//!   * Forward map: `EthAddress → ActorId`.
//!   * Reverse map: `ActorId → EthAddress`.
//!   * Monotone counter: `next_actor_id`.
//!
//! Operations:
//!
//!   * [`AddressBook::lookup`] — read-only `O(log n)` forward
//!     lookup.  Returns `None` for unknown addresses.
//!   * [`AddressBook::assign`] — assigns `next_actor_id` to a
//!     previously-unknown address, bumping the counter.
//!     `O(log n)` insertion.
//!
//! The `assign` semantics match Lean's
//! `Bridge.AddressBook.assign`: passing an *already-known*
//! address is a no-op that returns the existing actor id.  The
//! reverse direction never overwrites — once an `ActorId` is
//! issued, it points at the same `EthAddress` forever.
//!
//! ## Consistency invariant
//!
//! Lean's `Consistent` invariant pairs the forward / reverse
//! maps: `forward[addr] = id ↔ reverse[id] = addr`.  This Rust
//! mirror preserves the invariant by construction — every
//! `assign` updates both directions atomically (within a single
//! method call; the type is not thread-safe by design, mirroring
//! the Lean side's purely-functional `AddressBook`).
//!
//! ## Where this is used
//!
//! `translation::ingest` consumes an `AddressBook` to decide
//! between `RegisterIdentity` (fresh) and `ReplaceKey` (rotation).
//! The watcher loop maintains the book across iterations, with
//! state persisted to disk by `state.rs`.

use std::collections::BTreeMap;

use crate::action::{ActorId, EthAddress};

/// Maps Ethereum addresses to Knomosis `ActorId`s.  Mirrors Lean's
/// `Bridge.AddressBook` structure.
///
/// `BTreeMap` is the chosen Rust equivalent of Lean's
/// `Std.TreeMap`: deterministic iteration order, `O(log n)`
/// lookups, and no allocation churn under monotone inserts.
#[derive(Clone, Debug)]
pub struct AddressBook {
    /// Forward map (address → id).
    forward: BTreeMap<EthAddress, ActorId>,
    /// Reverse map (id → address).
    reverse: BTreeMap<ActorId, EthAddress>,
    /// Monotone counter for fresh-id allocation.  Starts at 4
    /// (mirroring Lean's `Bridge.AddressBook` genesis after Workstream
    /// GP.11.5; actor ids 0 / 1 / 2 / 3 are reserved for the bridge /
    /// gas-pool / sequencer / AMM-reserve actors respectively).
    next_actor_id: ActorId,
}

impl Default for AddressBook {
    /// Default impl identical to [`Self::new`].  We hand-roll
    /// rather than `#[derive(Default)]` because the derived
    /// default would set `next_actor_id` to `0` (the bridge
    /// actor's reserved id) — leading to a silent reuse of the
    /// bridge id at the first `assign` call.
    fn default() -> Self {
        Self::new()
    }
}

/// The reserved bridge-actor `ActorId`.  Matches Lean's
/// `Bridge.bridgeActor` constant.
pub const BRIDGE_ACTOR_ID: ActorId = 0;

/// The reserved gas-pool-actor `ActorId` (Workstream GP.7.1).  Matches
/// Lean's `Bridge.gasPoolActor` constant.  Holds the deposit fee-split
/// skim + per-actor budget top-up payments; its outflow is bounded by
/// the canonical `gasPoolPolicy`.
pub const GAS_POOL_ACTOR_ID: ActorId = 1;

/// The reserved sequencer-actor `ActorId` (Workstream GP.7.1).  Matches
/// Lean's `Bridge.sequencerActor` constant — the sole authorised
/// recipient of `gasPoolActor` outflow.
pub const SEQUENCER_ACTOR_ID: ActorId = 2;

/// The reserved AMM-reserve-actor `ActorId` (Workstream GP.11.5).
/// Matches Lean's `Bridge.ammReserveActor` constant — the L2 reflection
/// of the L1 bridge's AMM liquidity (`ammReserveEth` / `ammReserveBold`)
/// at both `ResourceId 0` (ETH) and `ResourceId 1` (BOLD).  Its balances
/// are mutated only by bridge-attested `ammSwap` actions (action index
/// 23); the runtime adaptor never issues this slot to a user identity.
pub const AMM_RESERVE_ACTOR_ID: ActorId = 3;

/// The initial `next_actor_id` value in a fresh AddressBook.  `4` is
/// the first non-reserved id; `0` / `1` / `2` / `3` are reserved for the
/// bridge / gas-pool / sequencer / AMM-reserve actors respectively
/// (Workstream GP.7.1 + GP.11.5).  Mirrors Lean's
/// `Bridge.AddressBook.empty.nextActorId = 4`
/// (`addressBook_empty_nextActorId`), so the Rust runtime adaptor
/// honours the reservation: a fresh registration is never issued a
/// reserved slot.
pub const INITIAL_NEXT_ACTOR_ID: ActorId = 4;

/// Errors surfaced by [`AddressBook::try_assign`].
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum AssignError {
    /// The monotone counter has reached `u64::MAX`.  This is
    /// unreachable on any realistic workload (2⁶⁴ unique
    /// addresses) but the explicit error variant prevents
    /// silent ID-collision corruption.
    #[error("address-book counter overflow: next_actor_id reached u64::MAX")]
    Overflow,
}

impl AddressBook {
    /// Construct an empty AddressBook with `next_actor_id = 4`.
    /// Mirrors Lean's `Bridge.AddressBook.empty` (post-GP.11.5).
    #[must_use]
    pub fn new() -> Self {
        Self {
            forward: BTreeMap::new(),
            reverse: BTreeMap::new(),
            next_actor_id: INITIAL_NEXT_ACTOR_ID,
        }
    }

    /// Forward lookup.  Returns the `ActorId` mapped to `addr`,
    /// or `None` if `addr` has not been assigned.  Mirrors Lean's
    /// `AddressBook.lookup`.
    #[must_use]
    pub fn lookup(&self, addr: &EthAddress) -> Option<ActorId> {
        self.forward.get(addr).copied()
    }

    /// Reverse lookup.  Returns the `EthAddress` an `ActorId` was
    /// originally assigned to, or `None` if the id has never been
    /// issued.  Mirrors Lean's `AddressBook.lookupRev`.
    #[must_use]
    pub fn lookup_reverse(&self, id: ActorId) -> Option<EthAddress> {
        self.reverse.get(&id).copied()
    }

    /// Errors surfaced by [`AddressBook::assign`].
    ///
    /// `Overflow` fires if the book's monotone counter has
    /// reached `u64::MAX` and another fresh assignment is
    /// requested.  This is unreachable on any realistic
    /// deployment (2⁶⁴ unique addresses), but is enforced here
    /// rather than silently producing duplicate `ActorId`s.
    ///
    /// Re-using [`AssignError`] via `Result` lets the
    /// production caller (the watcher) surface the failure as
    /// `WatcherError::Config` rather than crashing.
    pub fn try_assign(&mut self, addr: &EthAddress) -> Result<(ActorId, bool), AssignError> {
        if let Some(existing) = self.forward.get(addr).copied() {
            return Ok((existing, false));
        }
        let fresh = self.next_actor_id;
        // Compute the next counter BEFORE inserting so we can
        // reject overflow without leaving the book in a
        // half-mutated state.
        let next = fresh.checked_add(1).ok_or(AssignError::Overflow)?;
        self.forward.insert(*addr, fresh);
        self.reverse.insert(fresh, *addr);
        self.next_actor_id = next;
        Ok((fresh, true))
    }

    /// Convenience wrapper for [`Self::try_assign`] that panics
    /// on overflow.  Preserved for code paths that prove
    /// (statically or by precondition) that overflow cannot
    /// occur — typically the cross-stack fixture generator and
    /// replay code.
    ///
    /// Production callers (the watcher) MUST use `try_assign`.
    ///
    /// # Panics
    ///
    /// Panics if the book's monotone counter has reached
    /// `u64::MAX`.
    pub fn assign(&mut self, addr: &EthAddress) -> (ActorId, bool) {
        self.try_assign(addr)
            .expect("AddressBook::assign: monotone counter exhausted (next_actor_id == u64::MAX)")
    }

    /// The next actor id this book will issue.  Diagnostic only.
    #[must_use]
    pub fn next_actor_id(&self) -> ActorId {
        self.next_actor_id
    }

    /// Number of address↔id pairs in the book.  Diagnostic only.
    #[must_use]
    pub fn len(&self) -> usize {
        self.forward.len()
    }

    /// `true` iff the book contains no pairs.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.forward.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        AddressBook, AMM_RESERVE_ACTOR_ID, BRIDGE_ACTOR_ID, GAS_POOL_ACTOR_ID,
        INITIAL_NEXT_ACTOR_ID, SEQUENCER_ACTOR_ID,
    };
    use crate::action::{ActorId, EthAddress};

    /// Fresh AddressBook is empty and starts at `next = 4`
    /// (`INITIAL_NEXT_ACTOR_ID`, post-GP.11.5).
    #[test]
    fn new_book_is_empty() {
        let book = AddressBook::new();
        assert_eq!(book.len(), 0);
        assert!(book.is_empty());
        assert_eq!(book.next_actor_id(), INITIAL_NEXT_ACTOR_ID);
    }

    /// `lookup` on an unknown address is `None`.
    #[test]
    fn lookup_unknown_is_none() {
        let book = AddressBook::new();
        let addr = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        assert!(book.lookup(&addr).is_none());
    }

    /// First `assign` returns `(4, true)`.  Mirrors Lean's
    /// `assign_fresh_actorId` (the actor id is `nextActorId` at
    /// call time; the genesis `nextActorId` is `4` post-GP.11.5).
    #[test]
    fn first_assign_is_fresh() {
        let mut book = AddressBook::new();
        let addr = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let (id, is_new) = book.assign(&addr);
        assert_eq!(id, 4);
        assert!(is_new);
        assert_eq!(book.len(), 1);
        assert_eq!(book.next_actor_id(), 5);
    }

    /// `assign` on a known address is idempotent: returns the same
    /// id without bumping `next_actor_id`.  Mirrors Lean's
    /// `assign_idempotent_for_known`.
    #[test]
    fn second_assign_is_idempotent() {
        let mut book = AddressBook::new();
        let addr = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let (id1, _) = book.assign(&addr);
        let (id2, is_new) = book.assign(&addr);
        assert_eq!(id1, id2);
        assert!(!is_new);
        assert_eq!(book.len(), 1);
        assert_eq!(book.next_actor_id(), 5);
    }

    /// Distinct addresses get distinct ids in arrival order.
    #[test]
    fn distinct_addresses_get_distinct_ids() {
        let mut book = AddressBook::new();
        let a = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let b = EthAddress::from_bytes(&[2u8; 20]).unwrap();
        let c = EthAddress::from_bytes(&[3u8; 20]).unwrap();
        let (id_a, _) = book.assign(&a);
        let (id_b, _) = book.assign(&b);
        let (id_c, _) = book.assign(&c);
        assert_eq!(id_a, 4);
        assert_eq!(id_b, 5);
        assert_eq!(id_c, 6);
        assert_eq!(book.next_actor_id(), 7);
    }

    /// `lookup` returns the assigned id after `assign`.
    #[test]
    fn lookup_after_assign() {
        let mut book = AddressBook::new();
        let addr = EthAddress::from_bytes(&[0xabu8; 20]).unwrap();
        let (id, _) = book.assign(&addr);
        assert_eq!(book.lookup(&addr), Some(id));
    }

    /// `lookup_reverse` returns the assigned address.
    #[test]
    fn reverse_after_assign() {
        let mut book = AddressBook::new();
        let addr = EthAddress::from_bytes(&[0xab; 20]).unwrap();
        let (id, _) = book.assign(&addr);
        assert_eq!(book.lookup_reverse(id), Some(addr));
    }

    /// `BRIDGE_ACTOR_ID` is reserved and never assigned by
    /// `assign`.  Mirrors Lean: `bridgeActor` is `ActorId 0`,
    /// and `assign` starts allocating at `4` (post-GP.11.5).
    #[test]
    fn bridge_actor_id_is_reserved() {
        assert_eq!(BRIDGE_ACTOR_ID, 0);
        let mut book = AddressBook::new();
        let addr = EthAddress::from_bytes(&[0u8; 20]).unwrap();
        let (id, _) = book.assign(&addr);
        assert_ne!(
            id, BRIDGE_ACTOR_ID,
            "assign must never issue the bridge actor id"
        );
    }

    /// GP.7.1 — `GAS_POOL_ACTOR_ID` (1) and `SEQUENCER_ACTOR_ID` (2)
    /// are reserved alongside the bridge actor (0) and are never
    /// issued by `assign`.  Mirrors Lean's `gasPoolActor` /
    /// `sequencerActor` reservation and the
    /// `empty_assign_id_avoids_reserved` theorem: a fresh registration
    /// is issued `INITIAL_NEXT_ACTOR_ID` (4 post-GP.11.5), distinct from
    /// every reserved slot, and no reserved slot appears in the reverse
    /// map.  The GP.11.5 `AMM_RESERVE_ACTOR_ID` (3) slot has its own
    /// dedicated coverage in `amm_reserve_id_is_reserved` + the
    /// chain-level `assign_chain_never_issues_reserved_id`.
    #[test]
    fn gas_pool_and_sequencer_ids_are_reserved() {
        // The three reserved constants match the Lean ActorIds and are
        // pairwise distinct.
        assert_eq!(BRIDGE_ACTOR_ID, 0);
        assert_eq!(GAS_POOL_ACTOR_ID, 1);
        assert_eq!(SEQUENCER_ACTOR_ID, 2);
        assert_ne!(GAS_POOL_ACTOR_ID, BRIDGE_ACTOR_ID);
        assert_ne!(SEQUENCER_ACTOR_ID, BRIDGE_ACTOR_ID);
        assert_ne!(SEQUENCER_ACTOR_ID, GAS_POOL_ACTOR_ID);
        // A fresh registration is issued id 4 (post-GP.11.5), distinct
        // from these reserved slots, and never populates a reserved slot.
        let mut book = AddressBook::new();
        // Every reserved slot is strictly below the first issuable id.
        // (Compare against the runtime `next_actor_id()` so the bound is
        // genuinely checked rather than const-folded away.)
        let genesis = book.next_actor_id();
        assert!(BRIDGE_ACTOR_ID < genesis);
        assert!(GAS_POOL_ACTOR_ID < genesis);
        assert!(SEQUENCER_ACTOR_ID < genesis);
        let addr = EthAddress::from_bytes(&[0xau8; 20]).unwrap();
        let (id, _) = book.assign(&addr);
        assert_eq!(id, INITIAL_NEXT_ACTOR_ID);
        assert_ne!(id, BRIDGE_ACTOR_ID);
        assert_ne!(id, GAS_POOL_ACTOR_ID);
        assert_ne!(id, SEQUENCER_ACTOR_ID);
        assert!(book.lookup_reverse(BRIDGE_ACTOR_ID).is_none());
        assert!(book.lookup_reverse(GAS_POOL_ACTOR_ID).is_none());
        assert!(book.lookup_reverse(SEQUENCER_ACTOR_ID).is_none());
    }

    /// GP.11.5 — `AMM_RESERVE_ACTOR_ID` (3) is reserved for the L2
    /// reflection of the L1 AMM reserves and is the slot the genesis
    /// `next_actor_id` advance (3 → 4) re-homes away from user
    /// allocation.  Mirrors Lean's `ammReserveActor` constant + the
    /// three disjointness theorems (`ammReserveActor_ne_bridgeActor`
    /// / `_ne_gasPoolActor` / `_ne_sequencerActor`): the slot is
    /// pairwise-distinct from every other reserved actor and is never
    /// issued by `assign`.
    #[test]
    fn amm_reserve_id_is_reserved() {
        assert_eq!(AMM_RESERVE_ACTOR_ID, 3);
        // Distinct from the three GP.7.1 reserved slots.
        assert_ne!(AMM_RESERVE_ACTOR_ID, BRIDGE_ACTOR_ID);
        assert_ne!(AMM_RESERVE_ACTOR_ID, GAS_POOL_ACTOR_ID);
        assert_ne!(AMM_RESERVE_ACTOR_ID, SEQUENCER_ACTOR_ID);
        // The genesis advance to 4 reserves slot 3: a fresh `assign`
        // issues 4, never the AMM-reserve slot, and never populates it.
        let mut book = AddressBook::new();
        assert!(AMM_RESERVE_ACTOR_ID < book.next_actor_id());
        let addr = EthAddress::from_bytes(&[0xab; 20]).unwrap();
        let (id, _) = book.assign(&addr);
        assert_ne!(id, AMM_RESERVE_ACTOR_ID);
        assert!(book.lookup_reverse(AMM_RESERVE_ACTOR_ID).is_none());
    }

    /// GP.7.1 + GP.11.5 chain-level guarantee — a whole *sequence* of
    /// fresh `assign`s never issues a reserved id (0/1/2/3).  This is the
    /// value-level mirror of Lean's invariant decomposition (the
    /// `empty_nextActorId_ge_reserved`, `assign_preserves_reserved_invariant`,
    /// and `fresh_assign_avoids_reserved` theorems): the genesis counter
    /// starts at 4 and `assign` only ever advances it, so every id issued
    /// across the chain is at or above `INITIAL_NEXT_ACTOR_ID` and therefore
    /// distinct from every reserved slot.
    #[test]
    fn assign_chain_never_issues_reserved_id() {
        let reserved = [
            BRIDGE_ACTOR_ID,
            GAS_POOL_ACTOR_ID,
            SEQUENCER_ACTOR_ID,
            AMM_RESERVE_ACTOR_ID,
        ];
        let mut book = AddressBook::new();
        let mut prev_next = book.next_actor_id();
        // Drive 64 distinct fresh registrations.
        for i in 0..64u8 {
            let addr = EthAddress::from_bytes(&[i.wrapping_add(1); 20]).unwrap();
            let (id, is_new) = book.assign(&addr);
            assert!(is_new, "each distinct address is a fresh assignment");
            // The issued id is at or above the genesis floor ...
            assert!(
                id >= INITIAL_NEXT_ACTOR_ID,
                "issued id {id} is below the genesis floor {INITIAL_NEXT_ACTOR_ID}"
            );
            // ... hence distinct from every reserved slot.
            assert!(!reserved.contains(&id), "chain issued a reserved id {id}");
            // The counter is monotone non-decreasing (the invariant-preservation
            // step) and a fresh assign advances it by exactly one.
            assert_eq!(book.next_actor_id(), prev_next + 1);
            prev_next = book.next_actor_id();
        }
        // No reserved slot was ever populated in the reverse map.
        for r in reserved {
            assert!(
                book.lookup_reverse(r).is_none(),
                "reserved slot {r} must never appear in the reverse map"
            );
        }
    }

    /// Inserts at non-overlapping addresses preserve previously-
    /// assigned ids — the locality invariant of Lean's
    /// `assign_other_address_untouched`.
    #[test]
    fn assign_preserves_other_addresses() {
        let mut book = AddressBook::new();
        let a = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let b = EthAddress::from_bytes(&[2u8; 20]).unwrap();
        let (id_a, _) = book.assign(&a);
        assert_eq!(book.lookup(&a), Some(id_a));
        let (id_b, _) = book.assign(&b);
        // `a`'s id is unchanged.
        assert_eq!(book.lookup(&a), Some(id_a));
        // `b`'s id is fresh.
        assert_ne!(id_a, id_b);
    }

    /// `try_assign` returns `Err(AssignError::Overflow)` when
    /// the monotone counter has reached `u64::MAX`.  This is
    /// the load-bearing safeguard against silent ID reuse: the
    /// previous `saturating_add` returned the same id for
    /// successive assignments past `u64::MAX`, violating the
    /// `forward[a] = id ↔ reverse[id] = a` invariant.
    #[test]
    fn try_assign_rejects_overflow() {
        use super::AssignError;
        let mut book = AddressBook::new();
        // Forcibly set the counter to `u64::MAX`.  This is a
        // test-only manoeuvre — production code only ever
        // monotonically bumps via `assign`.
        unsafe_inject_counter(&mut book, ActorId::MAX);
        let addr = EthAddress::from_bytes(&[0xaa; 20]).unwrap();
        // First try_assign should succeed (counter = MAX, the
        // would-be next is MAX+1 which would overflow — but we
        // bump POST-insert, so the check would be on next call).
        // Actually with the new logic, the bump happens BEFORE
        // the insert: we compute `next = fresh.checked_add(1)`.
        // For fresh = MAX, next = None → return Err.
        match book.try_assign(&addr) {
            Err(AssignError::Overflow) => {}
            other => panic!("expected Overflow, got {other:?}"),
        }
        // Book is unchanged (we rejected before inserting).
        assert!(book.is_empty());
        assert!(book.lookup(&addr).is_none());
    }

    /// `assign` (the panic-on-overflow shim) panics rather than
    /// silently corrupting the book.
    #[test]
    #[should_panic(expected = "monotone counter exhausted")]
    fn assign_panics_on_overflow() {
        let mut book = AddressBook::new();
        unsafe_inject_counter(&mut book, ActorId::MAX);
        let addr = EthAddress::from_bytes(&[0xaa; 20]).unwrap();
        let _ = book.assign(&addr);
    }

    /// `try_assign` returning Err leaves the book unmutated —
    /// the post-rejection book passes the same invariant checks
    /// as a fresh book.
    #[test]
    fn try_assign_failure_does_not_corrupt_book() {
        let mut book = AddressBook::new();
        // Pre-load with some valid assignments.
        let a = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let b = EthAddress::from_bytes(&[2u8; 20]).unwrap();
        let (id_a, _) = book.assign(&a);
        let (id_b, _) = book.assign(&b);
        assert_eq!(id_a, 4);
        assert_eq!(id_b, 5);
        // Now corrupt the counter.
        unsafe_inject_counter(&mut book, ActorId::MAX);
        let c = EthAddress::from_bytes(&[3u8; 20]).unwrap();
        let result = book.try_assign(&c);
        assert!(result.is_err());
        // Prior assignments still hold.
        assert_eq!(book.lookup(&a), Some(4));
        assert_eq!(book.lookup(&b), Some(5));
        assert!(book.lookup(&c).is_none());
        assert_eq!(book.next_actor_id(), ActorId::MAX);
    }

    /// Test-only helper: inject a specific counter value into a
    /// book's `next_actor_id`.  Used to drive overflow tests
    /// without performing 2⁶⁴ real assignments.
    ///
    /// Despite the name, this function is `safe` — there is no
    /// UB; just an invariant violation if the caller misuses
    /// it (e.g. setting the counter to a value lower than the
    /// already-issued ids).  The `unsafe_` prefix is a comment
    /// in the function name that the caller is bypassing the
    /// monotone-bump invariant.
    fn unsafe_inject_counter(book: &mut AddressBook, new_value: ActorId) {
        book.next_actor_id = new_value;
    }
}
