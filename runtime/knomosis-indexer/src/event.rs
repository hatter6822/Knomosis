// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Rust mirror of Lean's `LegalKernel.Events.Event` inductive.
//!
//! ## Frozen constructor indices
//!
//! Per `LegalKernel/Events/Types.lean` (§8.9.2) and `docs/abi.md`
//! §5.3, the `Event` inductive has 21 constructors with frozen
//! indices.  This module exposes the same shape as a Rust enum so
//! the decoder can produce typed values without reaching into
//! raw bytes everywhere.
//!
//! | Tag | Constructor                    | Fields                                                            |
//! |-----|--------------------------------|-------------------------------------------------------------------|
//! | 0   | `BalanceChanged`               | `r, a, old_v, new_v`                                              |
//! | 1   | `NonceAdvanced`                | `a, old_n, new_n`                                                 |
//! | 2   | `IdentityRegistered`           | `a, key`                                                          |
//! | 3   | `IdentityRevoked`              | `a`                                                               |
//! | 4   | `TimeRecorded`                 | `t`                                                               |
//! | 5   | `DisputeFiled`                 | `challenger, target_idx`                                          |
//! | 6   | `DisputeWithdrawn`             | `dispute_idx`                                                     |
//! | 7   | `VerdictApplied`               | `dispute_idx, outcome_tag`                                        |
//! | 8   | `RewardIssued`                 | `r, a, amount`                                                    |
//! | 9   | `WithdrawalRequested`          | `r, a, amount, recipient_l1, withdrawal_id`                       |
//! | 10  | `DepositCredited`              | `r, a, amount, deposit_id`                                        |
//! | 11  | `LocalPolicyDeclared`          | `a, policy_bytes`                                                 |
//! | 12  | `LocalPolicyRevoked`           | `a`                                                               |
//! | 13  | `FaultProofGameOpened`         | `game_id, challenger, start, end, binding`                        |
//! | 14  | `FaultProofBisectionStep`      | `game_id, round, party, idx, commit`                              |
//! | 15  | `FaultProofGameSettled`        | `game_id, winner, loser, payout`                                  |
//! | 16  | `DepositWithFeeCredited`       | `r, recipient, pool_actor, user_amt, pool_amt, budget_grant, did` |
//! | 17  | `ActionBudgetTopUp`            | `signer, gas_resource, gas_amount, budget_increment, pool_actor`  |
//! | 18  | `GasPoolClaim`                 | `resource, sequencer, amount`                                     |
//! | 19  | `DelegatedActionBudgetTopUp`   | `recipient, signer, gas_resource, gas_amount, budget_inc, pool`   |
//! | 20  | `BudgetConsumed`               | `actor, amount`                                                   |
//! | 21  | `AmmSwapExecuted`              | `from_resource, to_resource, amount_in, amount_out, amm_actor`    |
//! | 22  | `AmmReservesReclaimed`         | `resource, amount, reserve_actor, pool_actor`                     |
//!
//! Tags 16..=20 are the Workstream-GP "gas pool" family (per
//! `LegalKernel/Events/Types.lean::Event.tag` 16..=20).  Tags
//! 16..=19 enable per-actor budget views; tag 20 (added in GP.6.4)
//! enables per-epoch consumption tracking, completing the
//! "N actions remaining this epoch" semantics.  Tag 21 (added in
//! GP.11.4) is the AMM swap execution event.
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

/// 128-bit budget unit mirroring Lean's per-actor `ActorBudget`
/// scalar (a `Nat` in Lean, bounded `< 2^64` by the canonical
/// `fieldsBounded` predicate but stored as `u128` in Rust for
/// arithmetic uniformity with [`Amount`]).
pub type BudgetUnits = u128;

/// Canonical L1 resource id for native ETH.  Mirrors
/// `solidity/src/contracts/KnomosisBridge.sol::RESOURCE_ID_ETH`
/// (implicit `0`) and `runtime/knomosis-l1-ingest`'s
/// `RESOURCE_ID_ETH = 0`.  Fed into the indexer's GP.6.4
/// per-resource pool-balance view to split ETH from BOLD in the
/// gas-pool drain accounting.
pub const RESOURCE_ID_ETH: ResourceId = 0;

/// Canonical L1 resource id for BOLD.  Mirrors
/// `solidity/src/contracts/KnomosisBridge.sol::RESOURCE_ID_BOLD = 1`.
/// Fed into the indexer's GP.6.4 per-resource pool-balance view to
/// split BOLD from ETH in the gas-pool drain accounting.
pub const RESOURCE_ID_BOLD: ResourceId = 1;

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
    /// A deposit with fee was credited (Workstream GP §15E v1.0).
    /// Carries the resource credited, the recipient's actor id,
    /// the gas-pool actor's id, the user-leg amount credited to
    /// `recipient`, the pool-leg amount credited to `pool_actor`,
    /// the recipient's budget grant (in budget units), and the L1
    /// deposit-receipt id.  Tag 16.
    DepositWithFeeCredited {
        /// Resource being credited.
        resource: ResourceId,
        /// Recipient actor on L2 (receives `user_amount`).
        recipient: ActorId,
        /// Gas-pool actor (receives `pool_amount`).
        pool_actor: ActorId,
        /// Amount credited to `recipient`.
        user_amount: Amount,
        /// Amount credited to `pool_actor`.
        pool_amount: Amount,
        /// Budget units granted to `recipient`.
        budget_grant: BudgetUnits,
        /// L1 deposit-receipt id (matches the consumed deposit).
        deposit_id: DepositId,
    },
    /// An L2 actor topped up their own action budget
    /// (Workstream GP §15E v1.0).  Carries the signer (whose
    /// budget is incremented), the gas resource debited, the gas
    /// amount, the budget increment, and the pool actor receiving
    /// the gas.  Tag 17.
    ActionBudgetTopUp {
        /// Signer actor whose budget was incremented.
        signer: ActorId,
        /// Resource debited from `signer` (the gas resource).
        gas_resource: ResourceId,
        /// Gas amount paid to the pool.
        gas_amount: Amount,
        /// Budget units credited to `signer`.
        budget_increment: BudgetUnits,
        /// Gas-pool actor (receives `gas_amount`).
        pool_actor: ActorId,
    },
    /// The gas pool was drained by `amount` units of `resource`
    /// to `sequencer` (Workstream GP §15E v1.0).  Reserved for
    /// future GP.7 work — the gas-pool actor's transfer policy
    /// authorises this drain via `gasPoolPolicy`.  Tag 18.
    GasPoolClaim {
        /// Resource drained.
        resource: ResourceId,
        /// Sequencer actor receiving the drain.
        sequencer: ActorId,
        /// Amount drained.
        amount: Amount,
    },
    /// A delegate topped up *another* actor's action budget
    /// (Workstream GP / GP.3.4 `topUpActionBudgetFor`).  Carries
    /// the `recipient` (whose budget is incremented), the
    /// `signer` (delegate/payer), the gas resource debited from
    /// the signer, the gas amount, the budget increment credited
    /// to the recipient, and the pool actor receiving the gas.
    /// Distinct from `ActionBudgetTopUp` because the budget
    /// target (`recipient`) differs from the payer (`signer`);
    /// indexers maintaining a per-actor budget view must credit
    /// the recipient, not the signer.  Tag 19.
    DelegatedActionBudgetTopUp {
        /// Recipient whose budget is incremented.
        recipient: ActorId,
        /// Delegate/payer actor whose balance is debited.
        signer: ActorId,
        /// Resource debited from `signer`.
        gas_resource: ResourceId,
        /// Gas amount paid to the pool.
        gas_amount: Amount,
        /// Budget units credited to `recipient`.
        budget_increment: BudgetUnits,
        /// Gas-pool actor (receives `gas_amount`).
        pool_actor: ActorId,
    },
    /// An actor's per-epoch action budget was consumed by
    /// `amount` units (Workstream GP / GP.6.4).  Emitted by the
    /// Lean kernel's `extractEvents` on every successful
    /// admission whose signer is NOT exempt from consumption
    /// (i.e., signer ≠ bridgeActor) and whose
    /// `BudgetPolicy.bounded.actionCost > 0`.  Indexers consume
    /// this event to compute "current-epoch budget remaining" =
    /// `freeTier + grants_this_epoch − consumed_this_epoch`.
    /// Tag 20.
    BudgetConsumed {
        /// Actor whose budget was debited.
        actor: ActorId,
        /// Number of budget units consumed (exactly
        /// `BudgetPolicy.bounded.actionCost` for non-bridge
        /// signers).
        amount: BudgetUnits,
    },
    /// An AMM swap was executed (ETH↔BOLD exchange against the
    /// gas-pool reserves; Workstream GP / GP.11.4).  Tag 21.
    AmmSwapExecuted {
        /// Source resource (the one the swapper pays in).
        from_resource: ResourceId,
        /// Destination resource (the one the swapper receives).
        to_resource: ResourceId,
        /// Amount paid in by the swapper.
        amount_in: Amount,
        /// Amount received by the swapper.
        amount_out: Amount,
        /// The AMM reserve actor.
        amm_reserve_actor: ActorId,
    },
    /// The disabled AMM's frozen L2 reserve balance was swept into
    /// the gas-pool actor (Workstream GP.11.10 post-disable
    /// reclamation; the exact sweep drains the reserve to zero).
    /// Tag 22.
    AmmReservesReclaimed {
        /// The swept resource.
        resource: ResourceId,
        /// The swept amount (the reserve's entire balance).
        amount: Amount,
        /// The drained AMM reserve actor.
        reserve_actor: ActorId,
        /// The credited gas-pool actor.
        pool_actor: ActorId,
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
            Self::DepositWithFeeCredited { .. } => 16,
            Self::ActionBudgetTopUp { .. } => 17,
            Self::GasPoolClaim { .. } => 18,
            Self::DelegatedActionBudgetTopUp { .. } => 19,
            Self::BudgetConsumed { .. } => 20,
            Self::AmmSwapExecuted { .. } => 21,
            Self::AmmReservesReclaimed { .. } => 22,
        }
    }

    /// The actor this event affects, if any.  Mirrors Lean's
    /// `Event.actor` (`LegalKernel/Events/Types.lean`).  Returns
    /// `None` for events that don't affect a specific actor
    /// (`TimeRecorded`, `DisputeWithdrawn`, `VerdictApplied`).
    ///
    /// For the GP family (tags 16..=19), `actor` returns the
    /// "primary affected" actor as per the Lean projection:
    /// `recipient` for `DepositWithFeeCredited`,
    /// `signer` for `ActionBudgetTopUp`,
    /// `sequencer` for `GasPoolClaim`,
    /// `recipient` for `DelegatedActionBudgetTopUp`.
    #[must_use]
    pub const fn actor(&self) -> Option<ActorId> {
        match self {
            // Tags 0/1/2/3/11/12/20 — events whose first-class
            // affected actor is the `actor` field.  (Tag 20
            // `BudgetConsumed` joins this set: its `actor` field
            // is the actor whose budget was debited.)
            Self::BalanceChanged { actor, .. }
            | Self::NonceAdvanced { actor, .. }
            | Self::IdentityRegistered { actor, .. }
            | Self::IdentityRevoked { actor }
            | Self::LocalPolicyDeclared { actor, .. }
            | Self::LocalPolicyRevoked { actor }
            | Self::BudgetConsumed { actor, .. } => Some(*actor),
            Self::DisputeFiled { challenger, .. }
            | Self::FaultProofGameOpened { challenger, .. } => Some(*challenger),
            // Tags 8 (RewardIssued), 10 (DepositCredited),
            // 16 (DepositWithFeeCredited), 19 (DelegatedActionBudgetTopUp):
            // all project `recipient` to the primary actor.
            Self::RewardIssued { recipient, .. }
            | Self::DepositCredited { recipient, .. }
            | Self::DepositWithFeeCredited { recipient, .. }
            | Self::DelegatedActionBudgetTopUp { recipient, .. } => Some(*recipient),
            Self::WithdrawalRequested { sender, .. } => Some(*sender),
            Self::FaultProofBisectionStep { party, .. } => Some(*party),
            Self::FaultProofGameSettled { winner, .. } => Some(*winner),
            Self::ActionBudgetTopUp { signer, .. } => Some(*signer),
            Self::GasPoolClaim { sequencer, .. } => Some(*sequencer),
            Self::AmmSwapExecuted {
                amm_reserve_actor, ..
            } => Some(*amm_reserve_actor),
            Self::AmmReservesReclaimed { reserve_actor, .. } => Some(*reserve_actor),
            Self::TimeRecorded { .. }
            | Self::DisputeWithdrawn { .. }
            | Self::VerdictApplied { .. } => None,
        }
    }

    /// The resource this event affects, if any.  Mirrors Lean's
    /// `Event.resource` (`LegalKernel/Events/Types.lean`).
    #[must_use]
    pub const fn resource(&self) -> Option<ResourceId> {
        match self {
            Self::BalanceChanged { resource, .. }
            | Self::RewardIssued { resource, .. }
            | Self::WithdrawalRequested { resource, .. }
            | Self::DepositCredited { resource, .. }
            | Self::DepositWithFeeCredited { resource, .. }
            | Self::GasPoolClaim { resource, .. }
            | Self::AmmReservesReclaimed { resource, .. } => Some(*resource),
            Self::ActionBudgetTopUp { gas_resource, .. }
            | Self::DelegatedActionBudgetTopUp { gas_resource, .. } => Some(*gas_resource),
            _ => None,
        }
    }

    /// True iff this event records a balance change.  Mirrors
    /// Lean's `Event.isBalanceChange`.
    #[must_use]
    pub const fn is_balance_change(&self) -> bool {
        matches!(self, Self::BalanceChanged { .. })
    }

    /// True iff this event belongs to the Workstream-GP gas-pool
    /// family (tags 16..=20).  Useful for filtering at the
    /// dispatch layer.  Tag 20 (`BudgetConsumed`) is the GP.6.4
    /// addition that enables current-epoch budget tracking.
    #[must_use]
    pub const fn is_gas_pool_family(&self) -> bool {
        matches!(
            self,
            Self::DepositWithFeeCredited { .. }
                | Self::ActionBudgetTopUp { .. }
                | Self::GasPoolClaim { .. }
                | Self::DelegatedActionBudgetTopUp { .. }
                | Self::BudgetConsumed { .. }
        )
    }
}

/// The number of frozen `Event` constructors.  Bumped by amendment
/// when a new constructor lands.  Useful for exhaustive coverage
/// tests.  GP.11.4 widened 21 → 22 by adding `AmmSwapExecuted`;
/// GP.11.10 widened 22 → 23 by adding `AmmReservesReclaimed`.
pub const EVENT_TAG_COUNT: u8 = 23;

#[cfg(test)]
mod tests {
    use super::{Event, EVENT_TAG_COUNT, RESOURCE_ID_BOLD, RESOURCE_ID_ETH};

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
        // GP family tags 16..=19 (Workstream GP / GP.6.4).
        assert_eq!(
            Event::DepositWithFeeCredited {
                resource: 0,
                recipient: 0,
                pool_actor: 0,
                user_amount: 0,
                pool_amount: 0,
                budget_grant: 0,
                deposit_id: 0,
            }
            .tag(),
            16
        );
        assert_eq!(
            Event::ActionBudgetTopUp {
                signer: 0,
                gas_resource: 0,
                gas_amount: 0,
                budget_increment: 0,
                pool_actor: 0,
            }
            .tag(),
            17
        );
        assert_eq!(
            Event::GasPoolClaim {
                resource: 0,
                sequencer: 0,
                amount: 0,
            }
            .tag(),
            18
        );
        assert_eq!(
            Event::DelegatedActionBudgetTopUp {
                recipient: 0,
                signer: 0,
                gas_resource: 0,
                gas_amount: 0,
                budget_increment: 0,
                pool_actor: 0,
            }
            .tag(),
            19
        );
        // GP.6.4: tag 20 (BudgetConsumed).
        assert_eq!(
            Event::BudgetConsumed {
                actor: 0,
                amount: 0,
            }
            .tag(),
            20
        );
    }

    /// `EVENT_TAG_COUNT` matches the number of constructors.
    /// GP.11.4 widened 21 → 22.
    #[test]
    fn tag_count_constant() {
        assert_eq!(EVENT_TAG_COUNT, 23);
    }

    /// Canonical resource-id constants pinned.
    #[test]
    fn resource_id_constants() {
        assert_eq!(RESOURCE_ID_ETH, 0);
        assert_eq!(RESOURCE_ID_BOLD, 1);
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

    /// GP family `actor()` projections match the Lean
    /// `Event.actor` convention.
    #[test]
    fn gp_family_actor_projection() {
        // DepositWithFeeCredited → recipient.
        assert_eq!(
            Event::DepositWithFeeCredited {
                resource: 0,
                recipient: 42,
                pool_actor: 1,
                user_amount: 100,
                pool_amount: 10,
                budget_grant: 50,
                deposit_id: 7,
            }
            .actor(),
            Some(42)
        );
        // ActionBudgetTopUp → signer.
        assert_eq!(
            Event::ActionBudgetTopUp {
                signer: 99,
                gas_resource: 0,
                gas_amount: 10,
                budget_increment: 100,
                pool_actor: 1,
            }
            .actor(),
            Some(99)
        );
        // GasPoolClaim → sequencer.
        assert_eq!(
            Event::GasPoolClaim {
                resource: 0,
                sequencer: 2,
                amount: 1000,
            }
            .actor(),
            Some(2)
        );
        // DelegatedActionBudgetTopUp → recipient (not signer).
        assert_eq!(
            Event::DelegatedActionBudgetTopUp {
                recipient: 55,
                signer: 77,
                gas_resource: 0,
                gas_amount: 10,
                budget_increment: 100,
                pool_actor: 1,
            }
            .actor(),
            Some(55)
        );
        // BudgetConsumed → actor.
        assert_eq!(
            Event::BudgetConsumed {
                actor: 99,
                amount: 1
            }
            .actor(),
            Some(99)
        );
    }

    /// GP family `resource()` projections.
    #[test]
    fn gp_family_resource_projection() {
        assert_eq!(
            Event::DepositWithFeeCredited {
                resource: 1,
                recipient: 0,
                pool_actor: 0,
                user_amount: 0,
                pool_amount: 0,
                budget_grant: 0,
                deposit_id: 0,
            }
            .resource(),
            Some(1)
        );
        // ActionBudgetTopUp returns gas_resource.
        assert_eq!(
            Event::ActionBudgetTopUp {
                signer: 0,
                gas_resource: 7,
                gas_amount: 0,
                budget_increment: 0,
                pool_actor: 0,
            }
            .resource(),
            Some(7)
        );
        assert_eq!(
            Event::GasPoolClaim {
                resource: 9,
                sequencer: 0,
                amount: 0,
            }
            .resource(),
            Some(9)
        );
        // DelegatedActionBudgetTopUp returns gas_resource.
        assert_eq!(
            Event::DelegatedActionBudgetTopUp {
                recipient: 0,
                signer: 0,
                gas_resource: 3,
                gas_amount: 0,
                budget_increment: 0,
                pool_actor: 0,
            }
            .resource(),
            Some(3)
        );
    }

    /// `is_gas_pool_family` selects exactly tags 16..=19.
    #[test]
    fn is_gas_pool_family_selects_gp_tags() {
        // Tags 16..=19 are gas-pool family.
        assert!(Event::DepositWithFeeCredited {
            resource: 0,
            recipient: 0,
            pool_actor: 0,
            user_amount: 0,
            pool_amount: 0,
            budget_grant: 0,
            deposit_id: 0,
        }
        .is_gas_pool_family());
        assert!(Event::ActionBudgetTopUp {
            signer: 0,
            gas_resource: 0,
            gas_amount: 0,
            budget_increment: 0,
            pool_actor: 0,
        }
        .is_gas_pool_family());
        assert!(Event::GasPoolClaim {
            resource: 0,
            sequencer: 0,
            amount: 0,
        }
        .is_gas_pool_family());
        assert!(Event::DelegatedActionBudgetTopUp {
            recipient: 0,
            signer: 0,
            gas_resource: 0,
            gas_amount: 0,
            budget_increment: 0,
            pool_actor: 0,
        }
        .is_gas_pool_family());
        // BudgetConsumed (tag 20) is also gas-pool family (GP.6.4).
        assert!(Event::BudgetConsumed {
            actor: 0,
            amount: 0,
        }
        .is_gas_pool_family());
        // Other tags are NOT gas-pool family.
        assert!(!Event::BalanceChanged {
            resource: 0,
            actor: 0,
            old_value: 0,
            new_value: 0
        }
        .is_gas_pool_family());
        assert!(!Event::DepositCredited {
            resource: 0,
            recipient: 0,
            amount: 0,
            deposit_id: 0,
        }
        .is_gas_pool_family());
    }
}
