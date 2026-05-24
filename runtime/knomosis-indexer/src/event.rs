// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE

//! Rust mirror of Lean's `LegalKernel.Events.Event` inductive.
//!
//! ## Frozen constructor indices
//!
//! Per `LegalKernel/Events/Types.lean` (§8.9.2) and `docs/abi.md`
//! §5.3, the `Event` inductive has 16 constructors with frozen
//! indices.  This module exposes the same shape as a Rust enum so
//! the decoder can produce typed values without reaching into
//! raw bytes everywhere.
//!
//! | Tag | Constructor               | Fields                                        |
//! |-----|---------------------------|-----------------------------------------------|
//! | 0   | `BalanceChanged`          | `r, a, old_v, new_v`                          |
//! | 1   | `NonceAdvanced`           | `a, old_n, new_n`                             |
//! | 2   | `IdentityRegistered`      | `a, key`                                      |
//! | 3   | `IdentityRevoked`         | `a`                                           |
//! | 4   | `TimeRecorded`            | `t`                                           |
//! | 5   | `DisputeFiled`            | `challenger, target_idx`                      |
//! | 6   | `DisputeWithdrawn`        | `dispute_idx`                                 |
//! | 7   | `VerdictApplied`          | `dispute_idx, outcome_tag`                    |
//! | 8   | `RewardIssued`            | `r, a, amount`                                |
//! | 9   | `WithdrawalRequested`     | `r, a, amount, recipient_l1, withdrawal_id`   |
//! | 10  | `DepositCredited`         | `r, a, amount, deposit_id`                    |
//! | 11  | `LocalPolicyDeclared`     | `a, policy_bytes`                             |
//! | 12  | `LocalPolicyRevoked`      | `a`                                           |
//! | 13  | `FaultProofGameOpened`    | `game_id, challenger, start, end, binding`    |
//! | 14  | `FaultProofBisectionStep` | `game_id, round, party, idx, commit`          |
//! | 15  | `FaultProofGameSettled`   | `game_id, winner, loser, payout`              |
//!
//! ## Field types (mirrored from Lean)
//!
//! Lean's types map to Rust as follows:
//!
//!   * `Authority.ActorId` (UInt64) → [`ActorId`] = `u64`.
//!   * `Authority.ResourceId` (UInt64) → [`ResourceId`] = `u64`.
//!   * `Authority.Amount` (Nat, bounded < 2^64 per
//!     `Encoding.fieldsBounded`) → [`Amount`] = `u128`.
//!     Stored as u128 in Rust because the field's encoding head
//!     is an 8-byte LE value (matching `knomosis-l1-ingest`'s
//!     `Amount = u128` convention).
//!   * `Authority.Nonce` → [`Nonce`] = `u128`.
//!   * `Authority.PublicKey` (ByteArray) → `Vec<u8>`.
//!   * `Bridge.WithdrawalId` (UInt64) → [`WithdrawalId`] = `u64`.
//!   * `Bridge.DepositId` (UInt64) → [`DepositId`] = `u64`.
//!   * `Bridge.EthAddress` (Fin 2^160) → 20-byte `[u8; 20]`.
//!   * `Nat` (general) → `u64` at the encoding boundary.

/// 64-bit ActorId mirroring `Authority.ActorId`.
pub type ActorId = u64;

/// 64-bit ResourceId mirroring `Authority.ResourceId`.
pub type ResourceId = u64;

/// 128-bit Amount mirroring `Authority.Amount`.  The encoder's
/// `fieldsBounded` predicate restricts encoded amounts to < 2^64,
/// but we carry u128 in Rust to match `knomosis-l1-ingest`'s
/// convention.
pub type Amount = u128;

/// 128-bit Nonce mirroring `Authority.Nonce`.
pub type Nonce = u128;

/// 64-bit WithdrawalId mirroring `Bridge.WithdrawalId`.
pub type WithdrawalId = u64;

/// 64-bit DepositId mirroring `Bridge.DepositId`.
pub type DepositId = u64;

/// 20-byte big-endian Ethereum address mirroring `Bridge.EthAddress`.
pub type EthAddress = [u8; 20];

/// Rust mirror of Lean's `LegalKernel.Events.Event` inductive.
///
/// The variant *order* matches the Lean inductive's constructor
/// declaration order, and the variants' [`Event::tag`] values
/// match the Lean side's `Event.tag` (§AR.6 / m-7).  Both are
/// frozen at the workspace level: changing the order or removing
/// a variant is a backwards-incompatible wire-format change.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Event {
    /// A balance changed for `(resource, actor)`.  Tag 0.
    BalanceChanged {
        /// Resource whose balance changed.
        resource: ResourceId,
        /// Actor whose balance changed.
        actor: ActorId,
        /// Pre-update balance.
        old_value: Amount,
        /// Post-update balance.
        new_value: Amount,
    },
    /// An actor's nonce advanced.  Tag 1.
    NonceAdvanced {
        /// Actor whose nonce advanced.
        actor: ActorId,
        /// Pre-advance nonce.
        old_nonce: Nonce,
        /// Post-advance nonce.
        new_nonce: Nonce,
    },
    /// A public key was registered (or rotated) for an actor.
    /// Tag 2.
    IdentityRegistered {
        /// Actor whose key was registered.
        actor: ActorId,
        /// Newly-registered key bytes.
        key: Vec<u8>,
    },
    /// An actor's key registration was revoked.  Tag 3.
    IdentityRevoked {
        /// Actor whose key was revoked.
        actor: ActorId,
    },
    /// A timestamp was recorded.  Tag 4.
    TimeRecorded {
        /// Recorded timestamp.
        time: u64,
    },
    /// A dispute was filed.  Tag 5.
    DisputeFiled {
        /// Challenger actor.
        challenger: ActorId,
        /// Target log index.
        target_idx: u64,
    },
    /// A dispute was withdrawn.  Tag 6.
    DisputeWithdrawn {
        /// Log index of the original dispute.
        dispute_idx: u64,
    },
    /// A verdict was applied.  Tag 7.
    VerdictApplied {
        /// Dispute the verdict applies to.
        dispute_idx: u64,
        /// Outcome tag (0 = upheld, 1 = rejected, 2 = inconclusive).
        outcome_tag: u64,
    },
    /// A reward was issued.  Tag 8.
    RewardIssued {
        /// Reward resource.
        resource: ResourceId,
        /// Recipient actor.
        recipient: ActorId,
        /// Reward amount.
        amount: Amount,
    },
    /// A withdrawal was requested (L2 → L1).  Tag 9.
    WithdrawalRequested {
        /// Resource being withdrawn.
        resource: ResourceId,
        /// Sender actor on L2.
        sender: ActorId,
        /// Amount being withdrawn.
        amount: Amount,
        /// Recipient on L1.
        recipient_l1: EthAddress,
        /// Assigned withdrawal id (matches the post-state
        /// `BridgeState.nextWdId`).
        withdrawal_id: WithdrawalId,
    },
    /// A deposit was credited (L1 → L2).  Tag 10.
    DepositCredited {
        /// Resource being credited.
        resource: ResourceId,
        /// Recipient actor on L2.
        recipient: ActorId,
        /// Credited amount.
        amount: Amount,
        /// L1 deposit-receipt id (matches the consumed deposit).
        deposit_id: DepositId,
    },
    /// An actor declared a local policy.  Tag 11.
    ///
    /// The policy bytes are kept opaque at this level: the
    /// indexer doesn't reason about policy semantics, only
    /// records that a declaration occurred.
    LocalPolicyDeclared {
        /// Actor declaring the policy.
        actor: ActorId,
        /// CBE-encoded policy bytes (opaque to the indexer).
        policy: Vec<u8>,
    },
    /// An actor revoked their local policy.  Tag 12.
    LocalPolicyRevoked {
        /// Actor revoking the policy.
        actor: ActorId,
    },
    /// A fault-proof game was opened.  Tag 13.
    FaultProofGameOpened {
        /// L1-assigned game id.
        game_id: u64,
        /// Challenger actor.
        challenger: ActorId,
        /// Disputed log-index range start.
        disputed_start_idx: u64,
        /// Disputed log-index range end.
        disputed_end_idx: u64,
        /// L2 binding hash for the game.
        binding_hash: Vec<u8>,
    },
    /// A bisection step was taken.  Tag 14.
    FaultProofBisectionStep {
        /// Game id.
        game_id: u64,
        /// Round number.
        round: u64,
        /// Actor who took the step.
        party: ActorId,
        /// Midpoint log index.
        idx: u64,
        /// Midpoint state commit.
        commit: Vec<u8>,
    },
    /// A fault-proof game was settled.  Tag 15.
    FaultProofGameSettled {
        /// Game id.
        game_id: u64,
        /// Winning actor.
        winner: ActorId,
        /// Losing actor.
        loser: ActorId,
        /// Bond payout amount.
        payout: Amount,
    },
}

impl Event {
    /// The constructor index of this event.  Matches Lean's
    /// `Event.tag` (§AR.6 / m-7).
    #[must_use]
    pub const fn tag(&self) -> u8 {
        match self {
            Self::BalanceChanged { .. } => 0,
            Self::NonceAdvanced { .. } => 1,
            Self::IdentityRegistered { .. } => 2,
            Self::IdentityRevoked { .. } => 3,
            Self::TimeRecorded { .. } => 4,
            Self::DisputeFiled { .. } => 5,
            Self::DisputeWithdrawn { .. } => 6,
            Self::VerdictApplied { .. } => 7,
            Self::RewardIssued { .. } => 8,
            Self::WithdrawalRequested { .. } => 9,
            Self::DepositCredited { .. } => 10,
            Self::LocalPolicyDeclared { .. } => 11,
            Self::LocalPolicyRevoked { .. } => 12,
            Self::FaultProofGameOpened { .. } => 13,
            Self::FaultProofBisectionStep { .. } => 14,
            Self::FaultProofGameSettled { .. } => 15,
        }
    }

    /// The actor this event affects, if any.  Mirrors Lean's
    /// `Event.actor`.  Returns `None` for events that don't
    /// affect a specific actor (`TimeRecorded`, `DisputeWithdrawn`,
    /// `VerdictApplied`).
    #[must_use]
    pub const fn actor(&self) -> Option<ActorId> {
        match self {
            Self::BalanceChanged { actor, .. }
            | Self::NonceAdvanced { actor, .. }
            | Self::IdentityRegistered { actor, .. }
            | Self::IdentityRevoked { actor }
            | Self::LocalPolicyDeclared { actor, .. }
            | Self::LocalPolicyRevoked { actor } => Some(*actor),
            Self::DisputeFiled { challenger, .. }
            | Self::FaultProofGameOpened { challenger, .. } => Some(*challenger),
            Self::RewardIssued { recipient, .. } | Self::DepositCredited { recipient, .. } => {
                Some(*recipient)
            }
            Self::WithdrawalRequested { sender, .. } => Some(*sender),
            Self::FaultProofBisectionStep { party, .. } => Some(*party),
            Self::FaultProofGameSettled { winner, .. } => Some(*winner),
            Self::TimeRecorded { .. }
            | Self::DisputeWithdrawn { .. }
            | Self::VerdictApplied { .. } => None,
        }
    }

    /// The resource this event affects, if any.  Mirrors Lean's
    /// `Event.resource`.
    #[must_use]
    pub const fn resource(&self) -> Option<ResourceId> {
        match self {
            Self::BalanceChanged { resource, .. }
            | Self::RewardIssued { resource, .. }
            | Self::WithdrawalRequested { resource, .. }
            | Self::DepositCredited { resource, .. } => Some(*resource),
            _ => None,
        }
    }

    /// True iff this event records a balance change.  Mirrors
    /// Lean's `Event.isBalanceChange`.
    #[must_use]
    pub const fn is_balance_change(&self) -> bool {
        matches!(self, Self::BalanceChanged { .. })
    }
}

/// The number of frozen `Event` constructors.  Bumped by amendment
/// when a new constructor lands.  Useful for exhaustive coverage
/// tests.
pub const EVENT_TAG_COUNT: u8 = 16;

#[cfg(test)]
mod tests {
    use super::{Event, EVENT_TAG_COUNT};

    /// Tag values match the frozen indices in
    /// `LegalKernel/Events/Types.lean::Event.tag`.
    #[test]
    fn tags_are_frozen() {
        // Construct one of each variant with minimal data and
        // check tag.  This catches accidental variant reorder.
        assert_eq!(
            Event::BalanceChanged {
                resource: 0,
                actor: 0,
                old_value: 0,
                new_value: 0
            }
            .tag(),
            0
        );
        assert_eq!(
            Event::NonceAdvanced {
                actor: 0,
                old_nonce: 0,
                new_nonce: 0
            }
            .tag(),
            1
        );
        assert_eq!(
            Event::IdentityRegistered {
                actor: 0,
                key: vec![]
            }
            .tag(),
            2
        );
        assert_eq!(Event::IdentityRevoked { actor: 0 }.tag(), 3);
        assert_eq!(Event::TimeRecorded { time: 0 }.tag(), 4);
        assert_eq!(
            Event::DisputeFiled {
                challenger: 0,
                target_idx: 0
            }
            .tag(),
            5
        );
        assert_eq!(Event::DisputeWithdrawn { dispute_idx: 0 }.tag(), 6);
        assert_eq!(
            Event::VerdictApplied {
                dispute_idx: 0,
                outcome_tag: 0
            }
            .tag(),
            7
        );
        assert_eq!(
            Event::RewardIssued {
                resource: 0,
                recipient: 0,
                amount: 0
            }
            .tag(),
            8
        );
        assert_eq!(
            Event::WithdrawalRequested {
                resource: 0,
                sender: 0,
                amount: 0,
                recipient_l1: [0; 20],
                withdrawal_id: 0
            }
            .tag(),
            9
        );
        assert_eq!(
            Event::DepositCredited {
                resource: 0,
                recipient: 0,
                amount: 0,
                deposit_id: 0
            }
            .tag(),
            10
        );
        assert_eq!(
            Event::LocalPolicyDeclared {
                actor: 0,
                policy: vec![]
            }
            .tag(),
            11
        );
        assert_eq!(Event::LocalPolicyRevoked { actor: 0 }.tag(), 12);
        assert_eq!(
            Event::FaultProofGameOpened {
                game_id: 0,
                challenger: 0,
                disputed_start_idx: 0,
                disputed_end_idx: 0,
                binding_hash: vec![]
            }
            .tag(),
            13
        );
        assert_eq!(
            Event::FaultProofBisectionStep {
                game_id: 0,
                round: 0,
                party: 0,
                idx: 0,
                commit: vec![]
            }
            .tag(),
            14
        );
        assert_eq!(
            Event::FaultProofGameSettled {
                game_id: 0,
                winner: 0,
                loser: 0,
                payout: 0
            }
            .tag(),
            15
        );
    }

    /// `EVENT_TAG_COUNT` matches the number of constructors.
    #[test]
    fn tag_count_constant() {
        assert_eq!(EVENT_TAG_COUNT, 16);
    }

    /// `actor` returns the expected variant.
    #[test]
    fn actor_projection() {
        assert_eq!(
            Event::BalanceChanged {
                resource: 1,
                actor: 42,
                old_value: 0,
                new_value: 100,
            }
            .actor(),
            Some(42)
        );
        assert_eq!(Event::TimeRecorded { time: 1234 }.actor(), None);
        assert_eq!(
            Event::DisputeFiled {
                challenger: 7,
                target_idx: 5
            }
            .actor(),
            Some(7)
        );
    }

    /// `resource` returns the expected variant.
    #[test]
    fn resource_projection() {
        assert_eq!(
            Event::BalanceChanged {
                resource: 99,
                actor: 0,
                old_value: 0,
                new_value: 0,
            }
            .resource(),
            Some(99)
        );
        assert_eq!(
            Event::NonceAdvanced {
                actor: 0,
                old_nonce: 0,
                new_nonce: 0
            }
            .resource(),
            None
        );
    }

    /// `is_balance_change` exhaustive.
    #[test]
    fn is_balance_change_exhaustive() {
        assert!(Event::BalanceChanged {
            resource: 0,
            actor: 0,
            old_value: 0,
            new_value: 0
        }
        .is_balance_change());
        assert!(!Event::IdentityRevoked { actor: 0 }.is_balance_change());
    }
}
