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
    /// Monotone counter for fresh-id allocation.  Starts at 1
    /// (mirroring Lean's `Bridge.AddressBook` default; actor id 0
    /// is reserved for the bridge actor itself).
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

/// The initial `next_actor_id` value in a fresh AddressBook.
/// `1` is the first non-reserved id; `0` is the bridge actor's.
pub const INITIAL_NEXT_ACTOR_ID: ActorId = 1;

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
    /// Construct an empty AddressBook with `next_actor_id = 1`.
    /// Mirrors Lean's `Bridge.AddressBook.empty`.
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
    use super::{AddressBook, BRIDGE_ACTOR_ID, INITIAL_NEXT_ACTOR_ID};
    use crate::action::{ActorId, EthAddress};

    /// Fresh AddressBook is empty and starts at `next = 1`.
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

    /// First `assign` returns `(1, true)`.  Mirrors Lean's
    /// `assign_fresh_actorId` (the actor id is `nextActorId` at
    /// call time).
    #[test]
    fn first_assign_is_fresh() {
        let mut book = AddressBook::new();
        let addr = EthAddress::from_bytes(&[1u8; 20]).unwrap();
        let (id, is_new) = book.assign(&addr);
        assert_eq!(id, 1);
        assert!(is_new);
        assert_eq!(book.len(), 1);
        assert_eq!(book.next_actor_id(), 2);
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
        assert_eq!(book.next_actor_id(), 2);
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
        assert_eq!(id_a, 1);
        assert_eq!(id_b, 2);
        assert_eq!(id_c, 3);
        assert_eq!(book.next_actor_id(), 4);
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
    /// and `assign` starts allocating at `1`.
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
        assert_eq!(id_a, 1);
        assert_eq!(id_b, 2);
        // Now corrupt the counter.
        unsafe_inject_counter(&mut book, ActorId::MAX);
        let c = EthAddress::from_bytes(&[3u8; 20]).unwrap();
        let result = book.try_assign(&c);
        assert!(result.is_err());
        // Prior assignments still hold.
        assert_eq!(book.lookup(&a), Some(1));
        assert_eq!(book.lookup(&b), Some(2));
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
