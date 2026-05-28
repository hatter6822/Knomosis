// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Rust mirror of Lean's `LegalKernel.Authority.Action`.
//!
//! ## Frozen constructor indices
//!
//! The constructor indices on the Lean side (`Encoding/Action.lean`)
//! are FROZEN at the inductive level — the runtime decoder reads the
//! first CBE uint as the constructor tag and matches against these
//! exact values:
//!
//! | Tag | Constructor               | Fields                                     |
//! |-----|---------------------------|--------------------------------------------|
//! | 0   | `Transfer`                | `r, sender, receiver, amount`             |
//! | 1   | `Mint`                    | `r, to, amount`                            |
//! | 2   | `Burn`                    | `r, from_actor, amount`                    |
//! | 3   | `FreezeResource`          | `r`                                        |
//! | 4   | `ReplaceKey`              | `actor, new_key`                           |
//! | 5   | `Reward`                  | `r, to, amount`                            |
//! | 6   | `DistributeOthers`        | `r, excluded, amount`                      |
//! | 7   | `ProportionalDilute`      | `r, excluded, total_reward`                |
//! | 8   | `Dispute`                 | (encoded via `Encoding.Disputes`)         |
//! | 9   | `DisputeWithdraw`         | `idx`                                      |
//! | 10  | `Verdict`                 | (encoded via `Encoding.Disputes`)         |
//! | 11  | `Rollback`                | `target_idx`                               |
//! | 12  | `RegisterIdentity`        | `actor, pk`                                |
//! | 13  | `Deposit`                 | `r, recipient, amount, deposit_id`         |
//! | 14  | `Withdraw`                | `r, sender, amount, recipient_l1`          |
//! | 15  | `DeclareLocalPolicy`      | (encoded via `Encoding.LocalPolicy`)      |
//! | 16  | `RevokeLocalPolicy`       | (no fields)                                |
//! | 17  | `FaultProofChallenge`     | `binding_hash, start, end, commit`         |
//! | 18  | `FaultProofResolution`    | `binding_hash, game_id, winner, revert_from` |
//! | 19  | `DepositWithFee`          | `r, recipient, pool_actor, user_amount, pool_amount, budget_grant, deposit_id` |
//! | 20  | `TopUpActionBudget`       | `gas_resource, gas_amount, budget_increment, pool_actor` |
//! | 21  | `TopUpActionBudgetFor`    | `recipient, gas_resource, gas_amount, budget_increment, pool_actor` |
//!
//! ## What this crate models
//!
//! The L1 ingestor only ever emits two Action variants:
//! `RegisterIdentity` (for first-time identity registrations) and
//! `ReplaceKey` (for key rotations).  Even so, we include every
//! constructor's tag definition so the byte-level encoder can
//! validate decoded fixtures via the full tag table, and so future
//! work units (deposit translation, withdraw translation) extend
//! this enum without breaking ABI.
//!
//! `Deposit` and `Withdraw` (tags 13 / 14) are sketched here as
//! constructors for forward-compatibility — the
//! `Bridge/Ingest.lean::ingest` function returns `none` for
//! deposit events in MVP scope (deposit translation goes
//! through `applyActionToBridgeState` at the kernel level, not
//! through `ingest`).  The ingestor never emits these today; the
//! variants live here to keep the action-tag map complete and
//! make the encoder's exhaustive match obviously total.
//!
//! `DepositWithFee`, `TopUpActionBudget`, `TopUpActionBudgetFor`
//! (tags 19 / 20 / 21, Workstream GP) are similarly sketched here
//! for encoder completeness.  Like `Deposit`, `Bridge/Ingest.lean::
//! ingest` returns `none` for `DepositWithFeeInitiated` events
//! (deposit materialisation is the sequencer's responsibility,
//! chain-level follow-up) so the ingestor never emits them, but
//! the encoder must be able to produce their CBE bytes
//! byte-equivalent to Lean for the kernel-layer admission path
//! that `bridgeActor` uses with these constructors.
//!
//! ## Mathematical contract
//!
//! For every `Action` constructed via this enum, the byte output of
//! `encoding::encode_action(&a)` is byte-equal to the Lean
//! reference `LegalKernel.Encoding.Action.encode a` (under the
//! `Action.fieldsBounded` precondition).  This equality is the
//! load-bearing cross-stack property; it is checked by every
//! record in `runtime/tests/cross-stack/l1_ingest.cxsf`.

/// 64-bit ActorId — abbreviation for Lean's `Authority.ActorId`.
pub type ActorId = u64;

/// 64-bit ResourceId — abbreviation for Lean's
/// `Authority.ResourceId`.
pub type ResourceId = u64;

/// `Nat`-valued Amount — abbreviation for Lean's
/// `Authority.Amount`.  Mirrors `Lean.Nat`'s unbounded representation
/// at the type level; the CBE encoder enforces `< 2^64` at the
/// boundary (per `Encoding.Action.fieldsBounded`).
pub type Amount = u128;

/// Per-actor monotone counter — abbreviation for Lean's
/// `Authority.Nonce`.
pub type Nonce = u128;

/// 64-bit log-index — abbreviation for Lean's
/// `Disputes.LogIndex`.
pub type LogIndex = u64;

/// 64-bit deposit-id — abbreviation for Lean's
/// `Bridge.DepositId`.
pub type DepositId = u64;

/// 64-bit withdrawal-id — abbreviation for Lean's
/// `Bridge.WithdrawalId`.
pub type WithdrawalId = u64;

/// A 20-byte big-endian Ethereum address.  Mirrors Lean's
/// `Bridge.EthAddress` (`Fin (2^160)`).  Stored as a `[u8; 20]` so
/// the byte layout is unambiguous at the encoding boundary; the
/// `Fin (2^160)` bound is enforced at the type level by this
/// fixed-size array (every 20-byte slice maps to a unique
/// `EthAddress`, and vice-versa).
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct EthAddress(pub [u8; 20]);

impl EthAddress {
    /// The zero EthAddress (`0x000...`).
    pub const ZERO: Self = Self([0u8; 20]);

    /// Construct from a 20-byte slice; returns `None` if `bytes`
    /// is not exactly 20 bytes.
    #[must_use]
    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != 20 {
            return None;
        }
        let mut out = [0u8; 20];
        out.copy_from_slice(bytes);
        Some(Self(out))
    }

    /// Return the underlying 20 bytes.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8; 20] {
        &self.0
    }

    /// Hex representation (no `0x` prefix, lowercase) — used by
    /// diagnostic logging.
    #[must_use]
    pub fn to_hex(&self) -> String {
        let mut s = String::with_capacity(40);
        for b in self.0 {
            // `format!` would allocate; manual is exact-length.
            s.push(hex_nibble(b >> 4));
            s.push(hex_nibble(b & 0x0f));
        }
        s
    }
}

/// A 33-byte SEC1-compressed secp256k1 public key.  Lean's
/// `PublicKey` is `ByteArray`-typed (unbounded); the bridge-actor
/// flow always uses 33-byte compressed keys, but the type stays
/// open-ended in this crate to mirror the Lean unbounded form
/// and let test fixtures cover sub-/over-length keys.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct PublicKey(pub Vec<u8>);

impl PublicKey {
    /// Construct from a borrowed byte slice.
    #[must_use]
    pub fn from_bytes(bytes: &[u8]) -> Self {
        Self(bytes.to_vec())
    }

    /// Return the underlying byte slice.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

/// Knomosis Action — Rust mirror of Lean's `Authority.Action`
/// inductive.  Tag-equivalent: the encoder writes the constructor
/// tag as a CBE uint matching the table above.
///
/// The L1 ingestor only constructs `RegisterIdentity` /
/// `ReplaceKey` variants today; the remaining variants are
/// included so the encoder's match is exhaustive and the type
/// surface mirrors the Lean side exactly.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Action {
    /// `transfer(r, sender, receiver, amount)`.  Tag 0.
    Transfer {
        /// The resource id whose balance map is touched.
        r: ResourceId,
        /// The actor whose balance is debited.
        sender: ActorId,
        /// The actor whose balance is credited.
        receiver: ActorId,
        /// The amount moved.
        amount: Amount,
    },
    /// `mint(r, to, amount)`.  Tag 1.
    Mint {
        /// The resource id whose balance map is touched.
        r: ResourceId,
        /// The actor whose balance is credited.
        to: ActorId,
        /// The amount minted.
        amount: Amount,
    },
    /// `burn(r, fromActor, amount)`.  Tag 2.
    Burn {
        /// The resource id whose balance map is touched.
        r: ResourceId,
        /// The actor whose balance is debited.
        from_actor: ActorId,
        /// The amount burned.
        amount: Amount,
    },
    /// `freezeResource(r)`.  Tag 3.
    FreezeResource {
        /// The resource id to mark frozen.
        r: ResourceId,
    },
    /// `replaceKey(actor, newKey)`.  Tag 4.
    ReplaceKey {
        /// The actor whose key is being rotated.
        actor: ActorId,
        /// The new public key.
        new_key: PublicKey,
    },
    /// `reward(r, to, amount)`.  Tag 5.
    Reward {
        /// The resource id whose balance map is credited.
        r: ResourceId,
        /// The actor whose balance is credited.
        to: ActorId,
        /// The amount rewarded.
        amount: Amount,
    },
    /// `distributeOthers(r, excluded, amount)`.  Tag 6.
    DistributeOthers {
        /// The resource id whose balance map is touched.
        r: ResourceId,
        /// The actor whose balance is unchanged.
        excluded: ActorId,
        /// The per-recipient amount.
        amount: Amount,
    },
    /// `proportionalDilute(r, excluded, totalReward)`.  Tag 7.
    ProportionalDilute {
        /// The resource id whose balance map is touched.
        r: ResourceId,
        /// The actor whose balance is unchanged.
        excluded: ActorId,
        /// The total reward to distribute proportionally.
        total_reward: Amount,
    },
    /// `disputeWithdraw(idx)`.  Tag 9.  (Tag 8 = `Dispute` and
    /// tag 10 = `Verdict` carry first-order data the ingestor
    /// never emits; we model the `LogIndex`-typed Tag 9 / 11
    /// variants here for symmetry.)
    DisputeWithdraw {
        /// The log index of the dispute being withdrawn.
        idx: LogIndex,
    },
    /// `rollback(targetIdx)`.  Tag 11.
    Rollback {
        /// The replay-target log index.
        target_idx: LogIndex,
    },
    /// `registerIdentity(actor, pk)`.  Tag 12.  Emitted by the
    /// ingestor on first-time `RegisteredECDSA` events.
    RegisterIdentity {
        /// The newly-assigned actor id.
        actor: ActorId,
        /// The actor's initial public key.
        pk: PublicKey,
    },
    /// `deposit(r, recipient, amount, depositId)`.  Tag 13.  The
    /// L1 ingestor does *not* emit this — deposit translation
    /// goes through `applyActionToBridgeState` at the kernel
    /// layer.  Included for encoder completeness.
    Deposit {
        /// The resource id being credited.
        r: ResourceId,
        /// The recipient on L2.
        recipient: ActorId,
        /// The amount deposited.
        amount: Amount,
        /// The L1 deposit id.
        deposit_id: DepositId,
    },
    /// `withdraw(r, sender, amount, recipientL1)`.  Tag 14.  The
    /// L1 ingestor does *not* emit this; included for encoder
    /// completeness.
    Withdraw {
        /// The resource id being debited.
        r: ResourceId,
        /// The L2 sender being debited.
        sender: ActorId,
        /// The amount withdrawn.
        amount: Amount,
        /// The L1 recipient.
        recipient_l1: EthAddress,
    },
    /// `revokeLocalPolicy`.  Tag 16.  No fields.
    RevokeLocalPolicy,
    /// `faultProofChallenge(bindingHash, startIdx, endIdx,
    /// commit)`.  Tag 17.
    FaultProofChallenge {
        /// The 32-byte binding hash.
        binding_hash: Vec<u8>,
        /// The start log index.
        disputed_start_idx: LogIndex,
        /// The end log index.
        disputed_end_idx: LogIndex,
        /// The challenger's commit.
        challenger_commit: Vec<u8>,
    },
    /// `faultProofResolution(bindingHash, gameId, winner,
    /// revertFromIdx)`.  Tag 18.
    FaultProofResolution {
        /// The 32-byte binding hash.
        binding_hash: Vec<u8>,
        /// The L1-assigned game id.
        game_id: u128,
        /// The settlement winner.
        winner: ActorId,
        /// The revert-from log index.
        revert_from_idx: LogIndex,
    },
    /// `depositWithFee(r, recipient, poolActor, userAmount,
    /// poolAmount, budgetGrant, depositId)`.  Tag 19 (Workstream
    /// GP).  The fee-split deposit credits the recipient with
    /// `userAmount` of resource `r` and the gas-pool actor with
    /// `poolAmount` of resource `r`, AND grants the recipient
    /// `budgetGrant` units of action-budget headroom.  Currently
    /// not emitted by the ingestor (deposit materialisation is
    /// the sequencer's responsibility); included for encoder
    /// completeness because the kernel admission path produces
    /// `bridgeActor`-signed `DepositWithFee` actions internally.
    DepositWithFee {
        /// The resource id being credited (0 = native ETH, 1 = BOLD).
        r: ResourceId,
        /// The L2 actor receiving the user-facing credit.
        recipient: ActorId,
        /// The gas-pool actor receiving the pool credit.
        pool_actor: ActorId,
        /// The portion of the deposit credited to the recipient.
        user_amount: Amount,
        /// The portion of the deposit credited to the gas pool.
        pool_amount: Amount,
        /// The action-budget headroom granted to the recipient.
        /// `u64` on the L1 wire; bounded `≤ MAX_BUDGET_PER_DEPOSIT
        /// = 10^12` by the contract; the Lean side stores it as a
        /// `Nat`, encoded byte-equivalently via the standard CBE
        /// uint head.
        budget_grant: u64,
        /// The L1 deposit id (per-depositor nonce).
        deposit_id: DepositId,
    },
    /// `topUpActionBudget(gasResource, gasAmount, budgetIncrement,
    /// poolActor)`.  Tag 20 (Workstream GP).  Lets an actor pay
    /// `gasAmount` of `gasResource` into the gas pool in exchange
    /// for `budgetIncrement` units of additional action-budget
    /// headroom.  Currently not emitted by the ingestor; included
    /// for encoder completeness.
    TopUpActionBudget {
        /// The resource used to pay gas (typically the deployment's
        /// native gas resource).
        gas_resource: ResourceId,
        /// The gas amount debited from the signer.
        gas_amount: Amount,
        /// The budget headroom credited to the signer.
        budget_increment: u64,
        /// The gas-pool actor receiving the gas payment.
        pool_actor: ActorId,
    },
    /// `topUpActionBudgetFor(recipient, gasResource, gasAmount,
    /// budgetIncrement, poolActor)`.  Tag 21 (Workstream GP.3.4).
    /// Like `TopUpActionBudget`, but the signer (delegate) pays
    /// gas on behalf of a *different* actor (`recipient`) whose
    /// budget gets credited.  Requires the recipient's prior
    /// consent (the `allowTopUpFrom` local-policy clause).
    /// Currently not emitted by the ingestor; included for
    /// encoder completeness.
    TopUpActionBudgetFor {
        /// The L2 actor whose budget gets credited.
        recipient: ActorId,
        /// The resource used to pay gas.
        gas_resource: ResourceId,
        /// The gas amount debited from the signer (delegate).
        gas_amount: Amount,
        /// The budget headroom credited to the recipient.
        budget_increment: u64,
        /// The gas-pool actor receiving the gas payment.
        pool_actor: ActorId,
    },
}

impl Action {
    /// The constructor tag (frozen index) for this action.
    /// Matches Lean's `Encoding.Action.encode`'s first CBE uint.
    #[must_use]
    pub fn tag(&self) -> u64 {
        match self {
            Self::Transfer { .. } => 0,
            Self::Mint { .. } => 1,
            Self::Burn { .. } => 2,
            Self::FreezeResource { .. } => 3,
            Self::ReplaceKey { .. } => 4,
            Self::Reward { .. } => 5,
            Self::DistributeOthers { .. } => 6,
            Self::ProportionalDilute { .. } => 7,
            Self::DisputeWithdraw { .. } => 9,
            Self::Rollback { .. } => 11,
            Self::RegisterIdentity { .. } => 12,
            Self::Deposit { .. } => 13,
            Self::Withdraw { .. } => 14,
            Self::RevokeLocalPolicy => 16,
            Self::FaultProofChallenge { .. } => 17,
            Self::FaultProofResolution { .. } => 18,
            Self::DepositWithFee { .. } => 19,
            Self::TopUpActionBudget { .. } => 20,
            Self::TopUpActionBudgetFor { .. } => 21,
        }
    }
}

/// Hex nibble (0..=15 → '0'..='9' | 'a'..='f').  Standalone helper
/// so neither `format!` nor `to_string` is on the hot path of
/// the `to_hex` printer.
fn hex_nibble(n: u8) -> char {
    match n {
        0..=9 => (b'0' + n) as char,
        10..=15 => (b'a' + (n - 10)) as char,
        _ => '?', // unreachable: `n` is constructed as `byte & 0x0f` or `byte >> 4`
    }
}

#[cfg(test)]
mod tests {
    use super::{Action, EthAddress, PublicKey};

    /// Tag indices match the frozen Lean table.
    #[test]
    fn tags_match_lean_frozen_table() {
        // Each constructor's expected index from `Encoding/Action.lean`.
        assert_eq!(
            Action::Transfer {
                r: 0,
                sender: 0,
                receiver: 0,
                amount: 0,
            }
            .tag(),
            0
        );
        assert_eq!(
            Action::Mint {
                r: 0,
                to: 0,
                amount: 0
            }
            .tag(),
            1
        );
        assert_eq!(
            Action::Burn {
                r: 0,
                from_actor: 0,
                amount: 0
            }
            .tag(),
            2
        );
        assert_eq!(Action::FreezeResource { r: 0 }.tag(), 3);
        assert_eq!(
            Action::ReplaceKey {
                actor: 0,
                new_key: PublicKey::from_bytes(&[])
            }
            .tag(),
            4
        );
        assert_eq!(
            Action::Reward {
                r: 0,
                to: 0,
                amount: 0
            }
            .tag(),
            5
        );
        assert_eq!(
            Action::DistributeOthers {
                r: 0,
                excluded: 0,
                amount: 0
            }
            .tag(),
            6
        );
        assert_eq!(
            Action::ProportionalDilute {
                r: 0,
                excluded: 0,
                total_reward: 0
            }
            .tag(),
            7
        );
        assert_eq!(Action::DisputeWithdraw { idx: 0 }.tag(), 9);
        assert_eq!(Action::Rollback { target_idx: 0 }.tag(), 11);
        assert_eq!(
            Action::RegisterIdentity {
                actor: 0,
                pk: PublicKey::from_bytes(&[])
            }
            .tag(),
            12
        );
        assert_eq!(
            Action::Deposit {
                r: 0,
                recipient: 0,
                amount: 0,
                deposit_id: 0
            }
            .tag(),
            13
        );
        assert_eq!(
            Action::Withdraw {
                r: 0,
                sender: 0,
                amount: 0,
                recipient_l1: EthAddress::ZERO
            }
            .tag(),
            14
        );
        assert_eq!(Action::RevokeLocalPolicy.tag(), 16);
        assert_eq!(
            Action::FaultProofChallenge {
                binding_hash: vec![0u8; 32],
                disputed_start_idx: 0,
                disputed_end_idx: 0,
                challenger_commit: vec![],
            }
            .tag(),
            17
        );
        assert_eq!(
            Action::FaultProofResolution {
                binding_hash: vec![0u8; 32],
                game_id: 0,
                winner: 0,
                revert_from_idx: 0,
            }
            .tag(),
            18
        );
        assert_eq!(
            Action::DepositWithFee {
                r: 0,
                recipient: 0,
                pool_actor: 0,
                user_amount: 0,
                pool_amount: 0,
                budget_grant: 0,
                deposit_id: 0,
            }
            .tag(),
            19
        );
        assert_eq!(
            Action::TopUpActionBudget {
                gas_resource: 0,
                gas_amount: 0,
                budget_increment: 0,
                pool_actor: 0,
            }
            .tag(),
            20
        );
        assert_eq!(
            Action::TopUpActionBudgetFor {
                recipient: 0,
                gas_resource: 0,
                gas_amount: 0,
                budget_increment: 0,
                pool_actor: 0,
            }
            .tag(),
            21
        );
    }

    /// Distinct GP-family constructors have distinct tags so a
    /// `DepositWithFee` log can never collide with a
    /// `TopUpActionBudget` or `TopUpActionBudgetFor` on the wire.
    #[test]
    fn gp_family_tags_pairwise_distinct() {
        let deposit_with_fee = Action::DepositWithFee {
            r: 0,
            recipient: 0,
            pool_actor: 0,
            user_amount: 0,
            pool_amount: 0,
            budget_grant: 0,
            deposit_id: 0,
        };
        let top_up = Action::TopUpActionBudget {
            gas_resource: 0,
            gas_amount: 0,
            budget_increment: 0,
            pool_actor: 0,
        };
        let top_up_for = Action::TopUpActionBudgetFor {
            recipient: 0,
            gas_resource: 0,
            gas_amount: 0,
            budget_increment: 0,
            pool_actor: 0,
        };
        let tags = [deposit_with_fee.tag(), top_up.tag(), top_up_for.tag()];
        for i in 0..tags.len() {
            for j in (i + 1)..tags.len() {
                assert_ne!(tags[i], tags[j], "GP-family tag collision: {i} vs {j}");
            }
        }
        // And the values are exactly the Lean-side frozen indices.
        assert_eq!(tags, [19, 20, 21]);
    }

    /// `EthAddress::from_bytes` rejects non-20-byte inputs.
    #[test]
    fn eth_address_from_bytes_rejects_wrong_length() {
        assert!(EthAddress::from_bytes(&[]).is_none());
        assert!(EthAddress::from_bytes(&[0u8; 19]).is_none());
        assert!(EthAddress::from_bytes(&[0u8; 20]).is_some());
        assert!(EthAddress::from_bytes(&[0u8; 21]).is_none());
        assert!(EthAddress::from_bytes(&[0u8; 32]).is_none());
    }

    /// `EthAddress::from_bytes` round-trips through `as_bytes`.
    #[test]
    fn eth_address_roundtrip() {
        let bs: [u8; 20] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
            0x0f, 0x10, 0x11, 0x12, 0x13, 0x14,
        ];
        let addr = EthAddress::from_bytes(&bs).unwrap();
        assert_eq!(addr.as_bytes(), &bs);
    }

    /// `EthAddress::to_hex` produces 40-character lowercase hex.
    #[test]
    fn eth_address_hex_format() {
        let addr = EthAddress::from_bytes(&[
            0x00, 0xff, 0xab, 0xcd, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xde, 0xad,
            0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe,
        ])
        .unwrap();
        let hex = addr.to_hex();
        assert_eq!(hex.len(), 40);
        assert_eq!(hex, "00ffabcd0123456789abcdefdeadbeefcafebabe");
        assert!(hex
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()));
    }

    /// `EthAddress::ZERO` is all zero bytes.
    #[test]
    fn eth_address_zero() {
        assert_eq!(EthAddress::ZERO.as_bytes(), &[0u8; 20]);
        assert_eq!(EthAddress::ZERO.to_hex(), "0".repeat(40));
    }

    /// `PublicKey::from_bytes` round-trips through `as_bytes`.
    #[test]
    fn public_key_roundtrip() {
        let bs = [0x02u8, 0x03, 0x04, 0x05];
        let pk = PublicKey::from_bytes(&bs);
        assert_eq!(pk.as_bytes(), &bs);
    }
}
