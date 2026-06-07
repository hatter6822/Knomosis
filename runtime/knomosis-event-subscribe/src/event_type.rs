// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Event-type registry — the Rust-side catalogue of the canonical
//! `Events.Event` constructor tags that flow across the
//! event-subscription wire (`docs/abi.md` §11 / §5.3).
//!
//! ## Why this module exists
//!
//! `knomosis-event-subscribe` is a *transport*: it tails the log,
//! delegates event extraction to the Lean wire-format authority
//! (see [`crate::extract`]), and streams the resulting opaque
//! CBE-encoded `Event` payloads to subscribers verbatim.  It
//! deliberately does NOT decode event *fields* — re-implementing
//! `Events.extractEvents` in Rust would risk drift from the Lean
//! reference, and field-level decoding is the *indexer*'s job
//! (`knomosis-indexer::decoder`), not the streamer's.
//!
//! What the streamer DOES benefit from is a lightweight, well-tested
//! catalogue of the canonical event *tags* — the constructor index
//! that leads every CBE `Event` payload.  This module provides that
//! catalogue plus a minimal, drift-safe "peek the leading tag"
//! primitive.  Concretely it powers:
//!
//!   * **Observability.**  The extractor loop classifies each
//!     streamed event by type for `trace`-level diagnostics
//!     ([`crate::server`]), so an operator can see the event-type
//!     mix flowing across the wire without standing up a separate
//!     indexer.
//!   * **Forward-compatibility contract.**  The registry is the
//!     Rust-side pin of the frozen `Event.tag` index space
//!     (`LegalKernel/Events/Types.lean`).  A future tag the Lean
//!     side appends classifies as [`EventClass::Unknown`] and is
//!     STILL streamed verbatim — the additive-extension policy is
//!     mechanised, not merely documented.
//!   * **Downstream reuse.**  The per-actor budget view
//!     (`knomosis-indexer`, WU GP.6.4) dispatches on the
//!     gas-pool-family tags this registry names
//!     ([`EventType::is_gas_pool_family`]).
//!
//! ## Wire format (leading tag only)
//!
//! Every CBE `Event` payload begins with a 9-byte CBE *uint head*
//! encoding the constructor index:
//!
//! ```text
//! offset  size  field
//! ------  ----  -------------------------------------------------
//!     0    1    CBE uint tag byte (0x00)
//!     1    8    constructor index (little-endian u64)
//! ```
//!
//! [`peek_event_tag`] reads exactly these 9 bytes and nothing more.
//! It does not decode the event's fields, so it cannot drift from
//! the (deferred) Lean `Encodable Event` field layout.  The 9-byte
//! head is the stable convention shared with
//! `knomosis-indexer::decoder` (`HEAD_LEN`) and
//! `knomosis-l1-ingest::encoding`.
//!
//! ## Workstream-GP additions (the focus of WU GP.6.3)
//!
//! Tags 16/17/18 are the unified-gas-pool §15E v1.0 events
//! (`depositWithFeeCredited`, `actionBudgetTopUp`, `gasPoolClaim`);
//! tag 19 (`delegatedActionBudgetTopUp`) was appended later by
//! GP.3.4.  All four fit in the existing 9-byte tag head, so they
//! stream additively with no protocol-version bump (the wire format
//! is unchanged; only the *set of values* the leading head may
//! carry grows).

use std::sync::atomic::{AtomicU64, Ordering};

/// CBE tag byte for an unsigned integer.  Matches Lean's
/// `Encoding.CBOR.cbeTagUint` and `knomosis-indexer::decoder`'s
/// `CBE_TAG_UINT`.  The constructor index that leads every `Event`
/// payload is encoded as a CBE uint, so the leading byte of a
/// well-formed payload is always this value.
pub const CBE_TAG_UINT: u8 = 0x00;

/// Length of a CBE uint head: 1-byte tag + 8-byte little-endian
/// u64.  The constructor tag that leads every `Event` payload
/// occupies exactly one head.  Matches `knomosis-indexer::decoder`'s
/// `HEAD_LEN`.
pub const EVENT_TAG_HEAD_LEN: usize = 9;

/// The number of frozen `Event` constructor tags currently defined
/// on the Lean side (`LegalKernel/Events/Types.lean::Event.tag`,
/// indices `0..=21`).  Bumped by amendment when the Lean inductive
/// grows; GP.11.4 widened it from 21 → 22 (adding `AmmSwapExecuted`
/// at tag 21).  The streaming path treats any tag
/// `>= KNOWN_EVENT_TAG_COUNT` as [`EventClass::Unknown`] and forwards
/// it verbatim (additive-extension policy, `docs/abi.md` §11).
pub const KNOWN_EVENT_TAG_COUNT: u64 = 22;

/// A canonical `Events.Event` constructor, identified by its frozen
/// wire tag.
///
/// The variant *order* and the [`EventType::tag`] values match the
/// Lean inductive's `Event.tag` projection
/// (`LegalKernel/Events/Types.lean`, §AR.6 / m-7) and the §5.3 ABI
/// table.  Both are frozen at the workspace level: changing the
/// order or a tag value is a backwards-incompatible wire-format
/// change.
///
/// This is a *tag* catalogue, not a structural decoder — it carries
/// no field data.  The streamer never needs the fields; the indexer
/// (`knomosis-indexer::event::Event`) is the field-level mirror.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum EventType {
    /// A balance changed for `(resource, actor)`.  Tag 0.
    BalanceChanged,
    /// An actor's nonce advanced.  Tag 1.
    NonceAdvanced,
    /// A public key was registered (or rotated) for an actor.  Tag 2.
    IdentityRegistered,
    /// An actor's key registration was revoked.  Tag 3.
    IdentityRevoked,
    /// A timestamp was recorded.  Tag 4.
    TimeRecorded,
    /// A dispute was filed.  Tag 5.
    DisputeFiled,
    /// A dispute was withdrawn.  Tag 6.
    DisputeWithdrawn,
    /// A verdict was applied.  Tag 7.
    VerdictApplied,
    /// A reward was issued.  Tag 8.
    RewardIssued,
    /// A withdrawal was requested (L2 → L1).  Tag 9.
    WithdrawalRequested,
    /// A deposit was credited (L1 → L2).  Tag 10.
    DepositCredited,
    /// An actor declared a local policy.  Tag 11.
    LocalPolicyDeclared,
    /// An actor revoked their local policy.  Tag 12.
    LocalPolicyRevoked,
    /// A fault-proof game was opened.  Tag 13.
    FaultProofGameOpened,
    /// A bisection step was taken in a fault-proof game.  Tag 14.
    FaultProofBisectionStep,
    /// A fault-proof game was settled.  Tag 15.
    FaultProofGameSettled,
    /// A bridge `depositWithFee` was credited on L2 with its
    /// budget-grant breakdown (Workstream GP §15E v1.0).  Tag 16.
    DepositWithFeeCredited,
    /// An L2 actor topped up their own action budget (Workstream
    /// GP §15E v1.0).  Tag 17.
    ActionBudgetTopUp,
    /// The gas pool was drained to a sequencer actor (Workstream GP
    /// §15E v1.0).  Tag 18.
    GasPoolClaim,
    /// A delegate topped up *another* actor's action budget
    /// (Workstream GP / GP.3.4 `topUpActionBudgetFor`).  Tag 19.
    DelegatedActionBudgetTopUp,
    /// An actor's per-epoch action budget was consumed
    /// (Workstream GP / GP.6.4).  Emitted by the Lean kernel's
    /// `extractEvents` on every admitted action whose signer is
    /// NOT exempt from consumption (i.e., signer ≠ bridgeActor)
    /// and whose `BudgetPolicy.bounded.actionCost > 0`.
    /// Indexers consume this event to compute current-epoch
    /// budget remaining.  Tag 20.
    BudgetConsumed,
    /// An AMM swap was executed (ETH↔BOLD exchange against the
    /// gas-pool reserves; Workstream GP / GP.11.4).  Tag 21.
    AmmSwapExecuted,
}

/// Every [`EventType`] in frozen tag order.  `ALL[i].tag() == i`
/// for every index, so iterating this array enumerates the tag
/// space `0..KNOWN_EVENT_TAG_COUNT`.  Used by exhaustive coverage
/// tests and by tooling that needs to walk the registry.
pub const ALL_EVENT_TYPES: [EventType; 22] = [
    EventType::BalanceChanged,
    EventType::NonceAdvanced,
    EventType::IdentityRegistered,
    EventType::IdentityRevoked,
    EventType::TimeRecorded,
    EventType::DisputeFiled,
    EventType::DisputeWithdrawn,
    EventType::VerdictApplied,
    EventType::RewardIssued,
    EventType::WithdrawalRequested,
    EventType::DepositCredited,
    EventType::LocalPolicyDeclared,
    EventType::LocalPolicyRevoked,
    EventType::FaultProofGameOpened,
    EventType::FaultProofBisectionStep,
    EventType::FaultProofGameSettled,
    EventType::DepositWithFeeCredited,
    EventType::ActionBudgetTopUp,
    EventType::GasPoolClaim,
    EventType::DelegatedActionBudgetTopUp,
    EventType::BudgetConsumed,
    EventType::AmmSwapExecuted,
];

impl EventType {
    /// The frozen wire tag (constructor index) of this event type.
    /// Mirrors Lean's `Event.tag`.
    #[must_use]
    pub const fn tag(self) -> u64 {
        match self {
            Self::BalanceChanged => 0,
            Self::NonceAdvanced => 1,
            Self::IdentityRegistered => 2,
            Self::IdentityRevoked => 3,
            Self::TimeRecorded => 4,
            Self::DisputeFiled => 5,
            Self::DisputeWithdrawn => 6,
            Self::VerdictApplied => 7,
            Self::RewardIssued => 8,
            Self::WithdrawalRequested => 9,
            Self::DepositCredited => 10,
            Self::LocalPolicyDeclared => 11,
            Self::LocalPolicyRevoked => 12,
            Self::FaultProofGameOpened => 13,
            Self::FaultProofBisectionStep => 14,
            Self::FaultProofGameSettled => 15,
            Self::DepositWithFeeCredited => 16,
            Self::ActionBudgetTopUp => 17,
            Self::GasPoolClaim => 18,
            Self::DelegatedActionBudgetTopUp => 19,
            Self::BudgetConsumed => 20,
            Self::AmmSwapExecuted => 21,
        }
    }

    /// The canonical Lean constructor name (lowerCamelCase),
    /// matching `LegalKernel/Events/Types.lean` and the §5.3 ABI
    /// table.  Used as the stable diagnostic label for the event
    /// type in logs and tooling.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::BalanceChanged => "balanceChanged",
            Self::NonceAdvanced => "nonceAdvanced",
            Self::IdentityRegistered => "identityRegistered",
            Self::IdentityRevoked => "identityRevoked",
            Self::TimeRecorded => "timeRecorded",
            Self::DisputeFiled => "disputeFiled",
            Self::DisputeWithdrawn => "disputeWithdrawn",
            Self::VerdictApplied => "verdictApplied",
            Self::RewardIssued => "rewardIssued",
            Self::WithdrawalRequested => "withdrawalRequested",
            Self::DepositCredited => "depositCredited",
            Self::LocalPolicyDeclared => "localPolicyDeclared",
            Self::LocalPolicyRevoked => "localPolicyRevoked",
            Self::FaultProofGameOpened => "faultProofGameOpened",
            Self::FaultProofBisectionStep => "faultProofBisectionStep",
            Self::FaultProofGameSettled => "faultProofGameSettled",
            Self::DepositWithFeeCredited => "depositWithFeeCredited",
            Self::ActionBudgetTopUp => "actionBudgetTopUp",
            Self::GasPoolClaim => "gasPoolClaim",
            Self::DelegatedActionBudgetTopUp => "delegatedActionBudgetTopUp",
            Self::BudgetConsumed => "budgetConsumed",
            Self::AmmSwapExecuted => "ammSwapExecuted",
        }
    }

    /// Resolve a wire tag to its [`EventType`], or `None` if the tag
    /// is not (yet) a known constructor.  An unknown tag is NOT an
    /// error at this layer — the additive-extension policy requires
    /// the streamer to forward unrecognised (future) tags verbatim
    /// (see [`EventClass`]).
    ///
    /// Derived from [`ALL_EVENT_TYPES`] + [`EventType::tag`] (a
    /// `const fn` linear scan), so it CANNOT drift from `tag()`: a
    /// reordered or omitted variant is caught by construction, not
    /// just by the round-trip test.
    #[must_use]
    pub const fn from_tag(tag: u64) -> Option<Self> {
        let mut i = 0;
        while i < ALL_EVENT_TYPES.len() {
            if ALL_EVENT_TYPES[i].tag() == tag {
                return Some(ALL_EVENT_TYPES[i]);
            }
            i += 1;
        }
        None
    }

    /// True iff this event type is one of the Workstream-GP
    /// unified-gas-pool events (`depositWithFeeCredited`,
    /// `actionBudgetTopUp`, `gasPoolClaim`, or
    /// `delegatedActionBudgetTopUp`; tags 16..=19).  The
    /// per-actor budget view (WU GP.6.4) dispatches on this
    /// family.
    #[must_use]
    pub const fn is_gas_pool_family(self) -> bool {
        matches!(
            self,
            Self::DepositWithFeeCredited
                | Self::ActionBudgetTopUp
                | Self::GasPoolClaim
                | Self::DelegatedActionBudgetTopUp
                | Self::BudgetConsumed
        )
    }
}

impl std::fmt::Display for EventType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

/// Errors from [`peek_event_tag`].  Surfaced only as diagnostics —
/// a malformed leading head NEVER causes the streamer to drop or
/// reject an event (the extractor is the trusted wire-format
/// authority; the streamer forwards its bytes verbatim).
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum EventTagError {
    /// The payload is shorter than a single 9-byte CBE uint head,
    /// so the constructor tag cannot be read.
    #[error("event payload too short for a CBE tag head: {len} bytes available, need 9")]
    Truncated {
        /// Number of bytes actually present in the payload.
        len: usize,
    },
    /// The payload's leading byte is not the CBE uint tag (`0x00`),
    /// so it is not a well-formed `Event` payload.
    #[error(
        "event payload leading head tag is 0x{actual:02x}, expected 0x{expected:02x} (CBE uint)"
    )]
    BadHeadTag {
        /// The tag byte the decoder expected (`CBE_TAG_UINT`).
        expected: u8,
        /// The tag byte actually present at offset 0.
        actual: u8,
    },
}

/// Read the constructor tag from the leading 9-byte CBE uint head of
/// an `Event` payload, WITHOUT decoding any fields.
///
/// This is the minimal, drift-safe parse: it inspects only the head
/// (a stable convention shared with `knomosis-indexer::decoder`), so
/// it remains correct regardless of the (deferred) Lean
/// `Encodable Event` field layout.
///
/// # Errors
///
/// Returns [`EventTagError::Truncated`] if the payload is shorter
/// than [`EVENT_TAG_HEAD_LEN`], or [`EventTagError::BadHeadTag`] if
/// the leading byte is not [`CBE_TAG_UINT`].
pub fn peek_event_tag(payload: &[u8]) -> Result<u64, EventTagError> {
    if payload.len() < EVENT_TAG_HEAD_LEN {
        return Err(EventTagError::Truncated { len: payload.len() });
    }
    let head_tag = payload[0];
    if head_tag != CBE_TAG_UINT {
        return Err(EventTagError::BadHeadTag {
            expected: CBE_TAG_UINT,
            actual: head_tag,
        });
    }
    let mut n_buf = [0u8; 8];
    n_buf.copy_from_slice(&payload[1..EVENT_TAG_HEAD_LEN]);
    Ok(u64::from_le_bytes(n_buf))
}

/// The classification of an `Event` payload's leading tag.
///
/// Classification is **total and non-rejecting**: every payload maps
/// to exactly one of these variants and the streaming path forwards
/// the payload verbatim in ALL three cases.  The distinction exists
/// purely for observability and the additive-extension contract:
///
///   * [`EventClass::Known`] — a recognised constructor.
///   * [`EventClass::Unknown`] — a syntactically valid head whose
///     tag is not (yet) a known constructor.  A future Lean tag
///     lands here and STILL streams (forward compatibility).
///   * [`EventClass::Unparseable`] — the leading head was malformed
///     (truncated or wrong tag byte).  Logged, then still streamed —
///     the extractor, not the streamer, owns wire-format validity.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EventClass {
    /// A recognised event constructor.
    Known(EventType),
    /// A syntactically valid leading head carrying an unrecognised
    /// (future / out-of-range) constructor tag.
    Unknown {
        /// The raw tag value read from the head.
        tag: u64,
    },
    /// The leading head could not be parsed at all.
    Unparseable(EventTagError),
}

impl EventClass {
    /// Classify an `Event` payload by peeking its leading tag.
    /// Never panics and never rejects: an unrecognised or malformed
    /// payload classifies as [`EventClass::Unknown`] /
    /// [`EventClass::Unparseable`] respectively, and the caller
    /// still forwards the bytes verbatim.
    #[must_use]
    pub fn classify(payload: &[u8]) -> Self {
        match peek_event_tag(payload) {
            Ok(tag) => match EventType::from_tag(tag) {
                Some(event_type) => Self::Known(event_type),
                None => Self::Unknown { tag },
            },
            Err(err) => Self::Unparseable(err),
        }
    }

    /// The recognised [`EventType`], if this is [`EventClass::Known`].
    #[must_use]
    pub const fn event_type(self) -> Option<EventType> {
        match self {
            Self::Known(event_type) => Some(event_type),
            Self::Unknown { .. } | Self::Unparseable(_) => None,
        }
    }

    /// True iff this is a recognised Workstream-GP gas-pool-family
    /// event (see [`EventType::is_gas_pool_family`]).
    #[must_use]
    pub const fn is_gas_pool_family(self) -> bool {
        match self {
            Self::Known(event_type) => event_type.is_gas_pool_family(),
            Self::Unknown { .. } | Self::Unparseable(_) => false,
        }
    }
}

impl std::fmt::Display for EventClass {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Known(event_type) => f.write_str(event_type.name()),
            Self::Unknown { tag } => write!(f, "unknown({tag})"),
            Self::Unparseable(_) => f.write_str("unparseable"),
        }
    }
}

/// Per-event-type streaming counters for operator observability.
///
/// The event-subscription server records every streamed event's
/// [`EventClass`] here (via [`EventStreamStats::record_payload`]), so
/// an operator can see the event-type mix — including the gas-pool
/// family — flowing across the wire without standing up a separate
/// indexer.  The server logs a [`EventStreamStats::summary`] at
/// shutdown and exposes the live tallies for tooling / tests.
///
/// All counters are `Relaxed` atomics: they are monotone
/// observability tallies, not synchronisation state.  Recording is
/// O(1) and allocation-free, and NEVER affects which events stream —
/// an unknown or unparseable payload is tallied and still forwarded
/// verbatim (the additive-extension policy).
#[derive(Debug)]
pub struct EventStreamStats {
    /// Per-known-tag counters, indexed by tag `0..KNOWN_EVENT_TAG_COUNT`.
    known: [AtomicU64; KNOWN_EVENT_TAG_COUNT as usize],
    /// Tally of syntactically-valid-but-unrecognised (future) tags.
    unknown: AtomicU64,
    /// Tally of payloads whose leading head could not be parsed.
    unparseable: AtomicU64,
}

impl Default for EventStreamStats {
    fn default() -> Self {
        Self::new()
    }
}

impl EventStreamStats {
    /// A fresh all-zero counter set.
    #[must_use]
    pub fn new() -> Self {
        Self {
            known: std::array::from_fn(|_| AtomicU64::new(0)),
            unknown: AtomicU64::new(0),
            unparseable: AtomicU64::new(0),
        }
    }

    /// Record one already-classified event.
    pub fn record(&self, class: EventClass) {
        match class {
            EventClass::Known(event_type) => {
                // `tag() < KNOWN_EVENT_TAG_COUNT` by construction, so
                // the index is always in range; `get` is belt-and-braces.
                if let Some(counter) = self.known.get(event_type.tag() as usize) {
                    counter.fetch_add(1, Ordering::Relaxed);
                }
            }
            EventClass::Unknown { .. } => {
                self.unknown.fetch_add(1, Ordering::Relaxed);
            }
            EventClass::Unparseable(_) => {
                self.unparseable.fetch_add(1, Ordering::Relaxed);
            }
        }
    }

    /// Classify `payload` and record it in one call (the hot-path
    /// entry the server uses).
    pub fn record_payload(&self, payload: &[u8]) {
        self.record(EventClass::classify(payload));
    }

    /// The number of events recorded for a known event type.
    #[must_use]
    pub fn count(&self, event_type: EventType) -> u64 {
        self.known
            .get(event_type.tag() as usize)
            .map_or(0, |c| c.load(Ordering::Relaxed))
    }

    /// The number of unrecognised (future) tags recorded.
    #[must_use]
    pub fn unknown_count(&self) -> u64 {
        self.unknown.load(Ordering::Relaxed)
    }

    /// The number of unparseable payloads recorded.
    #[must_use]
    pub fn unparseable_count(&self) -> u64 {
        self.unparseable.load(Ordering::Relaxed)
    }

    /// Total events recorded across every class.
    #[must_use]
    pub fn total(&self) -> u64 {
        let known: u64 = self.known.iter().map(|c| c.load(Ordering::Relaxed)).sum();
        known + self.unknown_count() + self.unparseable_count()
    }

    /// A space-separated `name=count` summary of the non-zero known
    /// tallies plus any `unknown` / `unparseable` counts — for an
    /// info-level shutdown log.  Empty when nothing was recorded.
    #[must_use]
    pub fn summary(&self) -> String {
        let mut parts: Vec<String> = Vec::new();
        for event_type in ALL_EVENT_TYPES {
            let c = self.count(event_type);
            if c > 0 {
                parts.push(format!("{}={c}", event_type.name()));
            }
        }
        let u = self.unknown_count();
        if u > 0 {
            parts.push(format!("unknown={u}"));
        }
        let p = self.unparseable_count();
        if p > 0 {
            parts.push(format!("unparseable={p}"));
        }
        parts.join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::{
        peek_event_tag, EventClass, EventStreamStats, EventTagError, EventType, ALL_EVENT_TYPES,
        CBE_TAG_UINT, EVENT_TAG_HEAD_LEN, KNOWN_EVENT_TAG_COUNT,
    };

    /// Build a well-formed CBE uint head for a given tag value
    /// (matches the wire format the indexer's `write_uint` emits).
    fn head(tag: u64) -> Vec<u8> {
        let mut v = Vec::with_capacity(EVENT_TAG_HEAD_LEN);
        v.push(CBE_TAG_UINT);
        v.extend_from_slice(&tag.to_le_bytes());
        v
    }

    /// Constants are pinned (no silent drift).
    #[test]
    fn constants_pinned() {
        assert_eq!(CBE_TAG_UINT, 0x00);
        assert_eq!(EVENT_TAG_HEAD_LEN, 9);
        // GP.11.4 widened 21 → 22 by adding `AmmSwapExecuted`.
        assert_eq!(KNOWN_EVENT_TAG_COUNT, 22);
    }

    /// `ALL_EVENT_TYPES[i].tag() == i` — the array is in frozen tag
    /// order, and its length matches `KNOWN_EVENT_TAG_COUNT`.
    #[test]
    fn all_array_is_in_tag_order() {
        assert_eq!(ALL_EVENT_TYPES.len() as u64, KNOWN_EVENT_TAG_COUNT);
        for (i, ty) in ALL_EVENT_TYPES.iter().enumerate() {
            assert_eq!(ty.tag(), i as u64, "tag mismatch at index {i}");
        }
    }

    /// `from_tag` round-trips every known tag back to the same
    /// `EventType`.
    #[test]
    fn from_tag_round_trips_all_known() {
        for ty in ALL_EVENT_TYPES {
            assert_eq!(EventType::from_tag(ty.tag()), Some(ty));
        }
    }

    /// `from_tag` returns `None` for tags beyond the known set
    /// (forward-compatibility: future tags are not errors here).
    /// GP.11.4 widened known tags 0..=20 → 0..=21.
    #[test]
    fn from_tag_unknown_returns_none() {
        for tag in [22u64, 23, 99, 1_000, u64::MAX] {
            assert_eq!(
                EventType::from_tag(tag),
                None,
                "tag {tag} should be unknown"
            );
        }
    }

    /// The Workstream-GP §15E v1.0 events sit at the documented tags
    /// 16/17/18, with the GP.3.4 delegated top-up at 19.
    #[test]
    fn gas_pool_family_tags_are_frozen() {
        assert_eq!(EventType::DepositWithFeeCredited.tag(), 16);
        assert_eq!(EventType::ActionBudgetTopUp.tag(), 17);
        assert_eq!(EventType::GasPoolClaim.tag(), 18);
        assert_eq!(EventType::DelegatedActionBudgetTopUp.tag(), 19);
    }

    /// `is_gas_pool_family` is true for exactly tags 16..=20.
    /// GP.6.4 widened from 16..=19 to 16..=20 by adding
    /// `BudgetConsumed`.
    #[test]
    fn gas_pool_family_classification() {
        for ty in ALL_EVENT_TYPES {
            let expected = (16..=20).contains(&ty.tag());
            assert_eq!(
                ty.is_gas_pool_family(),
                expected,
                "gas-pool-family mismatch for {} (tag {})",
                ty.name(),
                ty.tag()
            );
        }
    }

    /// `name()` matches the canonical Lean constructor names for the
    /// GP-family events (the focus of WU GP.6.3) plus a few anchors.
    #[test]
    fn names_match_lean_constructors() {
        assert_eq!(EventType::BalanceChanged.name(), "balanceChanged");
        assert_eq!(EventType::DepositCredited.name(), "depositCredited");
        assert_eq!(
            EventType::DepositWithFeeCredited.name(),
            "depositWithFeeCredited"
        );
        assert_eq!(EventType::ActionBudgetTopUp.name(), "actionBudgetTopUp");
        assert_eq!(EventType::GasPoolClaim.name(), "gasPoolClaim");
        assert_eq!(
            EventType::DelegatedActionBudgetTopUp.name(),
            "delegatedActionBudgetTopUp"
        );
    }

    /// All tags and all names are distinct (catches a copy-paste
    /// drift in the `tag` / `name` / `from_tag` matches).
    #[test]
    fn tags_and_names_are_distinct() {
        let mut tags: Vec<u64> = ALL_EVENT_TYPES.iter().map(|t| t.tag()).collect();
        tags.sort_unstable();
        tags.dedup();
        assert_eq!(tags.len(), ALL_EVENT_TYPES.len(), "duplicate tag detected");

        let mut names: Vec<&str> = ALL_EVENT_TYPES.iter().map(|t| t.name()).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(
            names.len(),
            ALL_EVENT_TYPES.len(),
            "duplicate name detected"
        );
    }

    /// `peek_event_tag` reads the tag from a well-formed head, for
    /// every known tag including the GP-family.
    #[test]
    fn peek_event_tag_reads_every_known_tag() {
        for ty in ALL_EVENT_TYPES {
            let payload = head(ty.tag());
            assert_eq!(peek_event_tag(&payload), Ok(ty.tag()));
        }
    }

    /// `peek_event_tag` reads ONLY the head — trailing field bytes
    /// are ignored (it is not a structural decoder).
    #[test]
    fn peek_event_tag_ignores_trailing_field_bytes() {
        // A realistic gasPoolClaim-shaped payload: tag head (18)
        // followed by three CBE uint fields.  peek reads just 18.
        let mut payload = head(18);
        for field in [7u64, 42, 1_000_000] {
            payload.push(CBE_TAG_UINT);
            payload.extend_from_slice(&field.to_le_bytes());
        }
        assert_eq!(peek_event_tag(&payload), Ok(18));
    }

    /// `peek_event_tag` reports `Truncated` for payloads shorter
    /// than one head (empty and a one-byte-short boundary).
    #[test]
    fn peek_event_tag_truncated() {
        assert_eq!(
            peek_event_tag(&[]),
            Err(EventTagError::Truncated { len: 0 })
        );
        let eight = [CBE_TAG_UINT, 0, 0, 0, 0, 0, 0, 0];
        assert_eq!(
            peek_event_tag(&eight),
            Err(EventTagError::Truncated { len: 8 })
        );
    }

    /// `peek_event_tag` reports `BadHeadTag` when the leading byte
    /// is not the CBE uint tag.
    #[test]
    fn peek_event_tag_bad_head_tag() {
        let mut payload = head(16);
        payload[0] = 0x02; // CBE byte-string tag, not a uint.
        assert_eq!(
            peek_event_tag(&payload),
            Err(EventTagError::BadHeadTag {
                expected: 0x00,
                actual: 0x02,
            })
        );
    }

    /// Non-circular wire-format pin: hand-spelled head bytes (NOT
    /// built via `to_le_bytes`) decode to the expected tag, proving
    /// the `0x00` tag byte + 8-byte little-endian convention matches
    /// Lean's `cborHeadEncode cbeTagUint` ground truth byte-for-byte.
    #[test]
    fn peek_event_tag_head_byte_layout_pinned() {
        // gasPoolClaim's neighbour depositWithFeeCredited (tag 16):
        // 0x00 head tag, then 0x10 in the lowest LE byte.
        let tag16 = [0x00u8, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
        assert_eq!(peek_event_tag(&tag16), Ok(16));
        // tag 0 (balanceChanged): all-zero head after the tag byte.
        let tag0 = [0x00u8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
        assert_eq!(peek_event_tag(&tag0), Ok(0));
        // Little-endianness across a byte boundary: 0x0102 = 258, with
        // the low byte first.  A big-endian bug would read 0x0201.
        let le = [0x00u8, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
        assert_eq!(peek_event_tag(&le), Ok(258));
    }

    /// `classify` recognises the GP-family payloads as `Known`.
    #[test]
    fn classify_known_gas_pool_family() {
        for ty in [
            EventType::DepositWithFeeCredited,
            EventType::ActionBudgetTopUp,
            EventType::GasPoolClaim,
            EventType::DelegatedActionBudgetTopUp,
        ] {
            let class = EventClass::classify(&head(ty.tag()));
            assert_eq!(class, EventClass::Known(ty));
            assert!(class.is_gas_pool_family());
            assert_eq!(class.event_type(), Some(ty));
        }
    }

    /// `classify` maps a valid-but-unrecognised tag to `Unknown`
    /// (forward compatibility) and a malformed head to
    /// `Unparseable` — never a hard error.
    #[test]
    fn classify_unknown_and_unparseable() {
        match EventClass::classify(&head(50)) {
            EventClass::Unknown { tag } => assert_eq!(tag, 50),
            other => panic!("expected Unknown, got {other:?}"),
        }
        assert!(matches!(
            EventClass::classify(&[]),
            EventClass::Unparseable(EventTagError::Truncated { len: 0 })
        ));
        let mut bad = head(16);
        bad[0] = 0xFF;
        assert!(matches!(
            EventClass::classify(&bad),
            EventClass::Unparseable(EventTagError::BadHeadTag { .. })
        ));
        // Neither non-Known class is a gas-pool-family event, and
        // neither yields an `event_type` — so a consumer that only
        // dispatches on `Known` cannot accidentally act on a future
        // or malformed tag.
        assert!(!EventClass::classify(&head(50)).is_gas_pool_family());
        assert!(!EventClass::classify(&[]).is_gas_pool_family());
        assert_eq!(EventClass::classify(&head(50)).event_type(), None);
        assert_eq!(EventClass::classify(&[]).event_type(), None);
        assert_eq!(EventClass::classify(&bad).event_type(), None);
        // The malformed-head `Display` is the stable "unparseable"
        // label (no panic, no internal-error leakage).
        assert_eq!(EventClass::classify(&bad).to_string(), "unparseable");
    }

    /// `classify` never panics on adversarial inputs.
    #[test]
    fn classify_never_panics() {
        let patterns: &[&[u8]] = &[
            &[],
            &[0x00],
            &[0xFF; 100],
            &[0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            &[0x02, 0, 0, 0, 0, 0, 0, 0, 0],
            &[0xFF; 1024],
        ];
        for p in patterns {
            let _ = EventClass::classify(p);
        }
    }

    /// `Display` for `EventType` is the canonical name.
    #[test]
    fn display_event_type() {
        assert_eq!(
            EventType::DepositWithFeeCredited.to_string(),
            "depositWithFeeCredited"
        );
        assert_eq!(EventType::GasPoolClaim.to_string(), "gasPoolClaim");
    }

    /// `Display` for `EventClass` renders the name / `unknown(tag)` /
    /// `unparseable` forms.
    #[test]
    fn display_event_class() {
        assert_eq!(
            EventClass::Known(EventType::ActionBudgetTopUp).to_string(),
            "actionBudgetTopUp"
        );
        assert_eq!(EventClass::Unknown { tag: 50 }.to_string(), "unknown(50)");
        assert_eq!(
            EventClass::Unparseable(EventTagError::Truncated { len: 0 }).to_string(),
            "unparseable"
        );
    }

    /// `EventTagError`'s `Display` strings carry the diagnostic
    /// fields (catches a swapped / dropped field in the `#[error]`
    /// format).
    #[test]
    fn error_message_format() {
        assert_eq!(
            EventTagError::Truncated { len: 5 }.to_string(),
            "event payload too short for a CBE tag head: 5 bytes available, need 9"
        );
        assert_eq!(
            EventTagError::BadHeadTag {
                expected: 0x00,
                actual: 0x02,
            }
            .to_string(),
            "event payload leading head tag is 0x02, expected 0x00 (CBE uint)"
        );
    }

    /// `EventStreamStats` tallies each class correctly via
    /// `record_payload`, leaves untouched types at zero, and reports
    /// the right total.
    #[test]
    fn event_stream_stats_records_by_class() {
        let stats = EventStreamStats::new();
        // 2 gasPoolClaim (tag 18), 1 depositWithFeeCredited (16),
        // 1 unknown (tag 50), 1 unparseable (empty).
        stats.record_payload(&head(18));
        stats.record_payload(&head(18));
        stats.record_payload(&head(16));
        stats.record_payload(&head(50));
        stats.record_payload(&[]);
        assert_eq!(stats.count(EventType::GasPoolClaim), 2);
        assert_eq!(stats.count(EventType::DepositWithFeeCredited), 1);
        assert_eq!(stats.count(EventType::BalanceChanged), 0);
        assert_eq!(stats.unknown_count(), 1);
        assert_eq!(stats.unparseable_count(), 1);
        assert_eq!(stats.total(), 5);
    }

    /// `EventStreamStats::summary` renders the non-zero tallies and is
    /// empty for a fresh counter.
    #[test]
    fn event_stream_stats_summary() {
        let stats = EventStreamStats::new();
        assert_eq!(stats.summary(), "");
        stats.record_payload(&head(16)); // depositWithFeeCredited
        stats.record_payload(&head(50)); // unknown
        stats.record_payload(&[0xFF]); // unparseable (bad head / short)
        let s = stats.summary();
        assert!(s.contains("depositWithFeeCredited=1"), "summary: {s}");
        assert!(s.contains("unknown=1"), "summary: {s}");
        assert!(s.contains("unparseable=1"), "summary: {s}");
    }

    /// `EventStreamStats` is `Send + Sync` (shared across the server's
    /// threads via `Arc`).
    #[test]
    fn event_stream_stats_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<EventStreamStats>();
    }
}
