// Canon  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Admission stages for actions submitted to `canon-host`.
//!
//! ## Motivation
//!
//! The single-sequencer model that `canon-host`'s MVP targets has
//! exactly two terminal outcomes for any submitted action: the
//! kernel either admits it (`Verdict::Ok`, L2 state advanced) or
//! rejects it (`NotAdmissible` / `ParseError` / `Busy`).  No
//! intermediate stage exists: by the time the host writes its
//! response byte, the action is fully canonical or fully rejected.
//!
//! Future decentralized-sequencing work breaks this binary picture.
//! An action may be **locally admitted** by one sequencer's kernel
//! before consensus has agreed on canonical ordering; it may be
//! **sequenced** (ordering committed by the sequencer set) before
//! L1 has **finalized** the containing block.  Without a typed
//! stage ladder, the meaning of "`Verdict::Ok`" silently shifts
//! between deployment modes, which is a wire-format hazard.
//!
//! This module introduces the [`AdmissionStage`] enum — a typed
//! total order over the four meaningful states — and the
//! [`AdmissionReceipt`] struct that bundles the stage with an
//! optional kernel-assigned action identifier.  Together they let
//! the kernel API carry stage information internally **without
//! changing the wire-format byte for `Verdict::Ok`**.  Clients that
//! need finer-grained progress will subscribe via the future RH-D
//! event-subscription protocol; clients that don't will continue
//! to read a single verdict byte exactly as today.
//!
//! ## Mathematical model
//!
//! Stages form a strict total order under the natural numeric
//! ordering of their `repr(u8)` discriminants:
//!
//! ```text
//!     Received < LocallyAdmitted < Sequenced < Finalized
//! ```
//!
//! The order is reflexive (`s ≤ s`), antisymmetric (`s ≤ t ∧ t ≤ s
//! ⟹ s = t`), transitive (`s ≤ t ∧ t ≤ u ⟹ s ≤ u`), and total
//! (every pair is comparable).  Rust's derived `Ord` on a
//! `#[repr(u8)]` enum gives exactly this ordering from the
//! declaration order; verified by the unit tests below.
//!
//! ## Monotonicity invariant (operational)
//!
//! For any action `a` processed by any kernel, the sequence of
//! stages reported for `a` over time must be **monotonically
//! non-decreasing**.  Formally, if the kernel reports stage `s₁`
//! at time `t₁` and stage `s₂` at time `t₂` with `t₁ < t₂`, then
//! `s₁ ≤ s₂`.
//!
//! This is the *operational* contract on kernel implementations,
//! enforced by code review (not by the type system, which can't
//! observe time).  The contract aligns with the Genesis Plan's
//! treatment of admissibility: once an action is admitted by the
//! kernel, it stays admitted under the same authority policy
//! (`apply_admissible` is a pure function of the state, signed
//! action, and admissibility witness).  Regression from a higher
//! stage to a lower stage would be observable by clients and
//! considered a correctness bug.
//!
//! The only way an action can "lose" a stage is for the *entire
//! action* to be invalidated by an L1-level intervention (e.g. a
//! successful fault-proof challenge), at which point the kernel
//! treats it as `NotAdmissible` rather than reporting a lower
//! stage.  The stage ladder reflects forward progress only.
//!
//! ## Wire-format implications
//!
//! The wire-format `Verdict` byte (`docs/abi.md` §10) does NOT
//! directly encode `AdmissionStage`.  Instead:
//!
//!   * Each [`crate::kernel::Kernel`] implementation declares its
//!     [`crate::kernel::Kernel::ok_admission_stage`] — the stage
//!     reached when the kernel returns `Verdict::Ok`.
//!   * Centralized kernels (`MockKernel`, `CommandKernel`) return
//!     [`AdmissionStage::Finalized`]: synchronous admission is
//!     final.
//!   * Future consensus-aware kernels return
//!     [`AdmissionStage::Sequenced`] or
//!     [`AdmissionStage::LocallyAdmitted`] depending on whether
//!     they wait for consensus before responding.
//!
//! Operators query the kernel's commitment stage at startup via
//! the host's diagnostic log ("kernel=X, ok_stage=Y"); clients
//! query it via the future RH-D `getInfo` event-subscription
//! preamble.  The wire byte itself is unchanged.

use std::fmt;

/// Stage of the admissibility pipeline an action has reached.
///
/// The four stages form a strict total order:
/// `Received < LocallyAdmitted < Sequenced < Finalized`.
///
/// See the module-level docstring for the full mathematical model
/// and the wire-format implications.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Ord, PartialOrd)]
#[repr(u8)]
pub enum AdmissionStage {
    /// The host has received and length-prefix-parsed the request
    /// frame.  Signature has not yet been verified by the kernel.
    /// **Diagnostic-only stage**: never reported to clients via
    /// the wire format or via the future subscription protocol.
    /// Used internally by the kernel for tracing.
    Received = 0,
    /// The local kernel has admitted the action under §8.2 of the
    /// Genesis Plan: the §8.2 admissibility predicate
    /// (`Admissible` / `AdmissibleWith`) returned `True` for
    /// `(state, signedAction)`.  In a centralized deployment this
    /// is also the final stage (the local kernel IS the canonical
    /// kernel).  In a decentralized deployment consensus may
    /// re-order before sequencing.
    LocallyAdmitted = 1,
    /// The sequencer set (or singleton sequencer) has committed
    /// the block containing this action to canonical ordering.
    /// In a centralized deployment this collapses with
    /// `LocallyAdmitted` (single sequencer = trivial consensus).
    /// In a decentralized deployment this is the strongest stage
    /// reachable without waiting for L1 finalization.
    Sequenced = 2,
    /// L1 has finalized the block containing this action up to
    /// L1 finalization assumptions (~12 blocks for Ethereum
    /// mainnet, per `canon-cli-common::paths::
    /// DEFAULT_L1_CONFIRMATION_DEPTH`).  Strongest stage: the
    /// action is irreversible under L1's safety model.
    Finalized = 3,
}

impl AdmissionStage {
    /// Encode to a single byte.  Bijective with the named
    /// variants on `0..=3`; clients receiving a stage on the
    /// wire (when RH-D ships) match against the documented
    /// values.
    #[must_use]
    pub const fn to_byte(self) -> u8 {
        self as u8
    }

    /// Decode from a byte.  Returns `None` for unknown bytes
    /// (i.e. anything outside `0..=3`).  Defensive against
    /// protocol-version drift between client and host.
    #[must_use]
    pub const fn from_byte(b: u8) -> Option<Self> {
        match b {
            0 => Some(Self::Received),
            1 => Some(Self::LocallyAdmitted),
            2 => Some(Self::Sequenced),
            3 => Some(Self::Finalized),
            _ => None,
        }
    }

    /// Human-readable stable name suitable for `tracing` logs and
    /// operator-facing diagnostics.  Lowercase snake_case to
    /// match the rest of canon-host's logging discipline.
    /// Stable across versions; downstream log scrapers may rely
    /// on these exact strings.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Received => "received",
            Self::LocallyAdmitted => "locally_admitted",
            Self::Sequenced => "sequenced",
            Self::Finalized => "finalized",
        }
    }

    /// Predicate: does this stage imply at least `other`?
    ///
    /// Mathematically equivalent to `self >= other` in the total
    /// order documented above.  Provided as a named method for
    /// call-site readability (`stage.implies(LocallyAdmitted)`
    /// reads more clearly than `stage >= LocallyAdmitted` at
    /// kernel-API boundaries).
    #[must_use]
    pub fn implies(self, other: Self) -> bool {
        self >= other
    }

    /// The next stage in the ladder, or `None` if `self` is
    /// already `Finalized`.  Used by kernel implementations to
    /// drive the stage machine forward.
    #[must_use]
    pub const fn next(self) -> Option<Self> {
        match self {
            Self::Received => Some(Self::LocallyAdmitted),
            Self::LocallyAdmitted => Some(Self::Sequenced),
            Self::Sequenced => Some(Self::Finalized),
            Self::Finalized => None,
        }
    }

    /// All defined stages in ascending order.  Useful for
    /// iterating in tests and for diagnostic dumps.
    pub const ALL: [Self; 4] = [
        Self::Received,
        Self::LocallyAdmitted,
        Self::Sequenced,
        Self::Finalized,
    ];
}

impl fmt::Display for AdmissionStage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// Receipt bundling a stage with an optional kernel-assigned
/// action identifier.  Returned by [`crate::kernel::Kernel`]
/// implementations alongside the `Verdict` to communicate the
/// precise stage reached.
///
/// The `action_id` field is opaque kernel-defined bytes — its
/// semantics are documented by the implementing kernel.  Typical
/// formats include a 32-byte keccak-256 of the signed-action
/// bytes (for content-addressed lookup) or a `(signer, nonce)`
/// pair (for stateful lookup).  Empty for kernels that don't
/// support stage-transition subscription.
///
/// The receipt is carried INSIDE the kernel API (Kernel ↔
/// canon-host); it is NOT serialised on the wire by the existing
/// frame format.  When the future RH-D event-subscription
/// protocol lands, it will define its own framing for receipts
/// flowing back over the wire.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct AdmissionReceipt {
    /// Highest stage this action has reached at the time the
    /// receipt was issued.
    pub stage: AdmissionStage,
    /// Kernel-assigned action identifier.  Empty bytes mean
    /// "this kernel does not support subscription for this
    /// action."
    pub action_id: Vec<u8>,
}

impl AdmissionReceipt {
    /// Construct a `Finalized` receipt with no action id — the
    /// canonical "centralized synchronous kernel" case.
    #[must_use]
    pub fn finalized() -> Self {
        Self {
            stage: AdmissionStage::Finalized,
            action_id: Vec::new(),
        }
    }

    /// Construct a receipt at the supplied stage with no action
    /// id.  Use when the kernel knows its stage but doesn't issue
    /// per-action identifiers.
    #[must_use]
    pub fn at_stage(stage: AdmissionStage) -> Self {
        Self {
            stage,
            action_id: Vec::new(),
        }
    }

    /// Construct a receipt at the supplied stage with a kernel-
    /// assigned identifier.  The identifier is opaque to the host;
    /// kernels that emit ids should document their format.
    #[must_use]
    pub fn with_id(stage: AdmissionStage, action_id: impl Into<Vec<u8>>) -> Self {
        Self {
            stage,
            action_id: action_id.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{AdmissionReceipt, AdmissionStage};

    /// Stage ordering matches the documented chain.  This is the
    /// load-bearing property the rest of the module depends on.
    #[test]
    fn total_order_matches_declaration() {
        use AdmissionStage::{Finalized, LocallyAdmitted, Received, Sequenced};
        assert!(Received < LocallyAdmitted);
        assert!(LocallyAdmitted < Sequenced);
        assert!(Sequenced < Finalized);
        // Transitivity
        assert!(Received < Finalized);
        assert!(Received < Sequenced);
        assert!(LocallyAdmitted < Finalized);
    }

    /// Reflexivity: every stage is `<= itself`.
    #[test]
    fn ordering_reflexive() {
        for s in AdmissionStage::ALL {
            assert!(s <= s, "{s:?} not <= itself");
            assert!(s >= s, "{s:?} not >= itself");
            assert_eq!(s.cmp(&s), std::cmp::Ordering::Equal);
        }
    }

    /// Antisymmetry: `s <= t ∧ t <= s` ⟹ `s = t`.  Exhaustively
    /// checked over the small finite domain.
    #[test]
    fn ordering_antisymmetric() {
        for &s in &AdmissionStage::ALL {
            for &t in &AdmissionStage::ALL {
                if s <= t && t <= s {
                    assert_eq!(s, t, "antisymmetry violated for {s:?} vs {t:?}");
                }
            }
        }
    }

    /// Transitivity: `s <= t ∧ t <= u` ⟹ `s <= u`.  Exhaustive
    /// check over the 64-element triple-domain.
    #[test]
    fn ordering_transitive() {
        for &s in &AdmissionStage::ALL {
            for &t in &AdmissionStage::ALL {
                for &u in &AdmissionStage::ALL {
                    if s <= t && t <= u {
                        assert!(s <= u, "transitivity violated for {s:?}, {t:?}, {u:?}");
                    }
                }
            }
        }
    }

    /// Totality: every pair is comparable in one direction or the
    /// other.
    #[test]
    fn ordering_total() {
        for &s in &AdmissionStage::ALL {
            for &t in &AdmissionStage::ALL {
                assert!(s <= t || t <= s, "totality violated for {s:?}, {t:?}");
            }
        }
    }

    /// `to_byte` matches the documented discriminants.
    #[test]
    fn to_byte_table() {
        assert_eq!(AdmissionStage::Received.to_byte(), 0);
        assert_eq!(AdmissionStage::LocallyAdmitted.to_byte(), 1);
        assert_eq!(AdmissionStage::Sequenced.to_byte(), 2);
        assert_eq!(AdmissionStage::Finalized.to_byte(), 3);
    }

    /// `from_byte ∘ to_byte = Some` on the named variants
    /// (round-trip).
    #[test]
    fn byte_round_trip() {
        for &s in &AdmissionStage::ALL {
            assert_eq!(AdmissionStage::from_byte(s.to_byte()), Some(s));
        }
    }

    /// `from_byte` returns `None` for every byte outside `0..=3`.
    #[test]
    fn from_byte_rejects_unknown() {
        for b in 4u8..=255 {
            assert_eq!(
                AdmissionStage::from_byte(b),
                None,
                "byte {b} unexpectedly accepted"
            );
        }
    }

    /// Names are stable and unique.
    #[test]
    fn names_unique_and_stable() {
        assert_eq!(AdmissionStage::Received.name(), "received");
        assert_eq!(AdmissionStage::LocallyAdmitted.name(), "locally_admitted");
        assert_eq!(AdmissionStage::Sequenced.name(), "sequenced");
        assert_eq!(AdmissionStage::Finalized.name(), "finalized");
        let names: Vec<&'static str> = AdmissionStage::ALL.iter().map(|s| s.name()).collect();
        let unique: std::collections::HashSet<_> = names.iter().collect();
        assert_eq!(unique.len(), names.len(), "names not unique");
    }

    /// `Display` matches `name()`.
    #[test]
    fn display_matches_name() {
        for &s in &AdmissionStage::ALL {
            assert_eq!(format!("{s}"), s.name());
        }
    }

    /// `implies` is equivalent to `>=` on the total order.
    /// Exhaustive check over the 16-pair domain.
    #[test]
    fn implies_matches_ge() {
        for &s in &AdmissionStage::ALL {
            for &t in &AdmissionStage::ALL {
                assert_eq!(
                    s.implies(t),
                    s >= t,
                    "implies({s:?}, {t:?}) disagrees with `>=`"
                );
            }
        }
    }

    /// `implies` is reflexive.
    #[test]
    fn implies_reflexive() {
        for &s in &AdmissionStage::ALL {
            assert!(s.implies(s));
        }
    }

    /// `implies` is transitive: a ⇒ b ∧ b ⇒ c ⟹ a ⇒ c.
    #[test]
    fn implies_transitive() {
        for &a in &AdmissionStage::ALL {
            for &b in &AdmissionStage::ALL {
                for &c in &AdmissionStage::ALL {
                    if a.implies(b) && b.implies(c) {
                        assert!(a.implies(c));
                    }
                }
            }
        }
    }

    /// `next()` advances by exactly one step, terminating at
    /// `Finalized`.
    #[test]
    fn next_chains_through_ladder() {
        assert_eq!(
            AdmissionStage::Received.next(),
            Some(AdmissionStage::LocallyAdmitted)
        );
        assert_eq!(
            AdmissionStage::LocallyAdmitted.next(),
            Some(AdmissionStage::Sequenced)
        );
        assert_eq!(
            AdmissionStage::Sequenced.next(),
            Some(AdmissionStage::Finalized)
        );
        assert_eq!(AdmissionStage::Finalized.next(), None);
    }

    /// `next` is strictly increasing where defined.
    #[test]
    fn next_strictly_increasing() {
        for &s in &AdmissionStage::ALL {
            if let Some(t) = s.next() {
                assert!(s < t, "next({s:?}) = {t:?} is not strictly greater");
            }
        }
    }

    /// `ALL` enumerates exactly the four variants in ascending
    /// order.
    #[test]
    fn all_is_sorted_and_complete() {
        assert_eq!(AdmissionStage::ALL.len(), 4);
        for window in AdmissionStage::ALL.windows(2) {
            assert!(window[0] < window[1]);
        }
        // Discriminants 0..=3 are all covered.
        let discriminants: Vec<u8> = AdmissionStage::ALL.iter().map(|s| s.to_byte()).collect();
        assert_eq!(discriminants, vec![0, 1, 2, 3]);
    }

    /// `AdmissionStage` is `Copy + Send + Sync`.
    #[test]
    fn stage_is_send_sync_copy() {
        fn assert_send_sync_copy<T: Send + Sync + Copy>() {}
        assert_send_sync_copy::<AdmissionStage>();
    }

    /// `AdmissionReceipt::finalized` is the canonical centralized-
    /// kernel constructor.
    #[test]
    fn finalized_constructor() {
        let r = AdmissionReceipt::finalized();
        assert_eq!(r.stage, AdmissionStage::Finalized);
        assert!(r.action_id.is_empty());
    }

    /// `AdmissionReceipt::at_stage` carries the stage and leaves
    /// `action_id` empty.
    #[test]
    fn at_stage_constructor() {
        for &s in &AdmissionStage::ALL {
            let r = AdmissionReceipt::at_stage(s);
            assert_eq!(r.stage, s);
            assert!(r.action_id.is_empty());
        }
    }

    /// `AdmissionReceipt::with_id` carries both stage and id.
    #[test]
    fn with_id_constructor() {
        let id = vec![0xaa, 0xbb, 0xcc, 0xdd];
        let r = AdmissionReceipt::with_id(AdmissionStage::Sequenced, id.clone());
        assert_eq!(r.stage, AdmissionStage::Sequenced);
        assert_eq!(r.action_id, id);
    }

    /// `AdmissionReceipt` is `Send + Sync + Clone`.
    #[test]
    fn receipt_is_send_sync_clone() {
        fn assert_traits<T: Send + Sync + Clone>() {}
        assert_traits::<AdmissionReceipt>();
    }

    /// Receipt equality + hashability preserve byte-identity of
    /// `action_id`.
    #[test]
    fn receipt_eq_hash_byte_identical() {
        use std::collections::HashSet;
        let r1 = AdmissionReceipt::with_id(AdmissionStage::Sequenced, vec![1, 2, 3]);
        let r2 = AdmissionReceipt::with_id(AdmissionStage::Sequenced, vec![1, 2, 3]);
        let r3 = AdmissionReceipt::with_id(AdmissionStage::Sequenced, vec![1, 2, 4]);
        assert_eq!(r1, r2);
        assert_ne!(r1, r3);
        let mut set = HashSet::new();
        set.insert(r1.clone());
        assert!(set.contains(&r2));
        assert!(!set.contains(&r3));
    }
}
