// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Per-actor budget admission gate (Workstream GP.6.2).
//!
//! ## What this module provides
//!
//! A byte-equivalent Rust mirror of the Lean kernel's per-actor
//! epoch-budget ledger plus the budget-consumption portion of the
//! GP.3.2 admission gate, so the `knomosis-host` network adaptor can
//! reason about budgets without a Lean toolchain in the loop:
//!
//!   * [`BudgetPolicy`] — mirror of
//!     `LegalKernel.Authority.BudgetPolicy` (`Authority/Nonce.lean`):
//!     the per-deployment `bounded freeTier actionCost currentEpoch`
//!     mode.  CBE-encodes byte-for-byte against Lean's
//!     `BudgetPolicy.encode` (`Encoding/State.lean`).
//!   * [`ActorBudget`] — mirror of
//!     `LegalKernel.Authority.ActorBudget`: a per-actor epoch cell
//!     `(lastSeenEpoch, budgetBalance)` with the `normalise` /
//!     `consume` / `topUp` transitions copied from
//!     `Authority/ActorBudget.lean`.  CBE-encodes byte-for-byte
//!     against `ActorBudget.encode`.
//!   * [`EpochBudgetState`] — mirror of
//!     `LegalKernel.Authority.EpochBudgetState` (a `TreeMap ActorId
//!     ActorBudget`): the per-actor ledger with `currentBudget` /
//!     `consume` / `topUp`.  CBE-encodes byte-for-byte against the
//!     `encodeSortedPairs` map form embedded in
//!     `ExtendedState.encode`.
//!   * [`BudgetGate`] — the budget-ledger portion of the GP.3.2
//!     admission gate `apply_admissible_with_budget`
//!     (`Authority/SignedAction.lean`), driving a [`SignedActionBudgetView`]
//!     decoded from the wire bytes.  Used by
//!     [`crate::kernel::mock::MockKernel`] so tests can exercise the
//!     `InsufficientBudget` rejection path end-to-end.
//!
//! ## Scope boundary — what the mock gate does and does NOT model
//!
//! The Lean admission gate's `topUpActionBudget` /
//! `topUpActionBudgetFor` safety checks include two conjuncts that
//! depend on state this in-memory mirror does NOT carry:
//!
//!   * `getBalance es.base gasResource signer >= gasAmount` — depends
//!     on the kernel balance map.
//!   * `delegatedTopUpConsentBool` — depends on the recipient's
//!     declared `LocalPolicy`.
//!
//! The [`BudgetGate`] always enforces every *balance- and
//! policy-independent* conjunct of the Lean gate (the bridge-actor /
//! self-pool / zero-gas / self-recipient correlation guards, the
//! per-action consume, and the budget-grant arms).  The two
//! state-dependent conjuncts have two modes:
//!
//!   * **Default (permissive).**  They are DEFERRED to the
//!     authoritative Lean kernel reached through
//!     [`crate::kernel::command::CommandKernel`].  The gate is then a
//!     faithful but *strictly weaker* predicate: it never admits an
//!     ordinary action the kernel would reject for budget reasons,
//!     but it may admit a gas-funding action whose gas-balance /
//!     consent precondition only the kernel can check.  This is the
//!     lightweight posture for the test/dev `MockKernel`.
//!   * **Strict ([`BudgetGate::with_strict_checks`]).**  The gate
//!     ALSO enforces `getBalance >= gasAmount` (via the
//!     [`BudgetGate::set_balance`] oracle) and
//!     `delegatedTopUpConsentBool` (via [`BudgetGate::allow_delegate`]),
//!     making the mock a *faithful* (no longer merely weaker)
//!     realisation of `apply_admissible_with_budget`.
//!
//! Production budget enforcement remains the Lean kernel's
//! responsibility (see `docs/planning/unified_gas_pool_plan.md`
//! §GP.3.2 / §GP.6.2).
//!
//! ## Integer width
//!
//! Lean models every budget quantity as an unbounded `Nat`; the CBE
//! wire form bounds each to `< 2^64` (an 8-byte little-endian head).
//! This mirror uses `u64` throughout — the exact wire width — so a
//! decoded value round-trips losslessly.  `topUp` saturates at
//! `u64::MAX` (documented on [`ActorBudget::top_up`]); the saturation
//! point is `2^64`, already past the CBE-encodable bound, so it is
//! unreachable for any value that survives a round-trip.

use std::collections::BTreeMap;

/// The reserved bridge-actor id.  Mirrors Lean's
/// `LegalKernel.Bridge.bridgeActor` (`Bridge/BridgeActor.lean`),
/// which fixes `ActorId 0` as the bridge authority.  The GP.3.2
/// admission gate exempts this actor from budget consumption
/// (per OQ-GP-6).
pub const BRIDGE_ACTOR: u64 = 0;

/// CBE type tag for unsigned integers.  Mirrors Lean's
/// `Encoding.CBOR.cbeTagUint`.
const CBE_TAG_UINT: u8 = 0x00;

/// CBE type tag for byte strings.  Mirrors Lean's
/// `Encoding.CBOR.cbeTagBytes`.
const CBE_TAG_BYTES: u8 = 0x02;

/// CBE type tag for maps.  Mirrors Lean's `Encoding.CBOR.cbeTagMap`.
const CBE_TAG_MAP: u8 = 0x05;

/// Length of a CBE head: 1 type-tag byte + 8-byte little-endian
/// value/length.  Mirrors Lean's `Encoding.CBOR.cborHeadEncode`
/// output width.
const HEAD_LEN: usize = 9;

/// Append a CBE uint head (`CBE_TAG_UINT` + 8-byte LE value) to
/// `out`.  Mirrors `Encodable.encode (T := Nat)`.
fn push_cbe_uint(out: &mut Vec<u8>, value: u64) {
    out.push(CBE_TAG_UINT);
    out.extend_from_slice(&value.to_le_bytes());
}

/// Per-deployment budget-enforcement mode.  Mirror of
/// `LegalKernel.Authority.BudgetPolicy` (`Authority/Nonce.lean`).
///
/// Only the `bounded` constructor exists today; it is represented as
/// a single-variant enum so a future `unlimited` mode slots in
/// without changing the wire tag of `bounded` (frozen at `0`).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BudgetPolicy {
    /// Enforce per-actor epoch budgets.  `free_tier` is the
    /// per-epoch budget floor a normalised cell is raised to;
    /// `action_cost` is the per-action debit (clamped to `>= 1` by
    /// [`BudgetPolicy::mk_bounded`], matching Lean's
    /// `BudgetPolicy.mkBounded`); `current_epoch` is the current
    /// epoch index (per OQ-GP-4 this tracks an L1-block-derived
    /// counter).
    Bounded {
        /// Per-epoch budget floor (the free tier).
        free_tier: u64,
        /// Per-action budget debit (always `>= 1`).
        action_cost: u64,
        /// Current epoch index.
        current_epoch: u64,
    },
}

impl BudgetPolicy {
    /// Smart constructor for the bounded mode.  Clamps `action_cost`
    /// to at least `1`, exactly matching Lean's
    /// `BudgetPolicy.mkBounded` (`max actionCost 1`) — a zero
    /// per-action cost would let an actor spam for free.
    #[must_use]
    pub fn mk_bounded(free_tier: u64, action_cost: u64, current_epoch: u64) -> Self {
        Self::Bounded {
            free_tier,
            action_cost: action_cost.max(1),
            current_epoch,
        }
    }

    /// The free-tier floor for this policy.
    #[must_use]
    pub fn free_tier(self) -> u64 {
        match self {
            Self::Bounded { free_tier, .. } => free_tier,
        }
    }

    /// The per-action cost for this policy.
    #[must_use]
    pub fn action_cost(self) -> u64 {
        match self {
            Self::Bounded { action_cost, .. } => action_cost,
        }
    }

    /// The current epoch index for this policy.
    #[must_use]
    pub fn current_epoch(self) -> u64 {
        match self {
            Self::Bounded { current_epoch, .. } => current_epoch,
        }
    }

    /// CBE-encode this policy, byte-for-byte equal to Lean's
    /// `BudgetPolicy.encode` (`Encoding/State.lean`): the constructor
    /// tag `0` followed by `freeTier`, `actionCost`, `currentEpoch`,
    /// each a CBE uint head.
    #[must_use]
    pub fn encode(self) -> Vec<u8> {
        let Self::Bounded {
            free_tier,
            action_cost,
            current_epoch,
        } = self;
        let mut out = Vec::with_capacity(HEAD_LEN * 4);
        push_cbe_uint(&mut out, 0); // bounded constructor tag
        push_cbe_uint(&mut out, free_tier);
        push_cbe_uint(&mut out, action_cost);
        push_cbe_uint(&mut out, current_epoch);
        out
    }

    /// Decode a `BudgetPolicy` from a CBE stream, mirroring Lean's
    /// `BudgetPolicy.decode`: constructor tag (must be `0`), then
    /// `freeTier`, `actionCost`, `currentEpoch`.  Rejects a tag
    /// `!= 0` and `actionCost == 0` as non-canonical (the encoder's
    /// `mk_bounded` clamp guarantees `actionCost >= 1`).
    fn decode_at(cur: &mut CbeCursor) -> Result<Self, BudgetDecodeError> {
        let tag = cur.read_uint()?;
        if tag != 0 {
            return Err(BudgetDecodeError::NonCanonical {
                reason: "budgetPolicy tag must be 0",
            });
        }
        let free_tier = cur.read_uint()?;
        let action_cost = cur.read_uint()?;
        if action_cost == 0 {
            return Err(BudgetDecodeError::NonCanonical {
                reason: "budgetPolicy actionCost must be >= 1",
            });
        }
        let current_epoch = cur.read_uint()?;
        Ok(Self::Bounded {
            free_tier,
            action_cost,
            current_epoch,
        })
    }

    /// Decode a `BudgetPolicy` from a complete byte buffer, requiring
    /// the whole buffer to be consumed.
    ///
    /// # Errors
    ///
    /// Returns a [`BudgetDecodeError`] on malformed, non-canonical, or
    /// trailing input.
    pub fn decode(bytes: &[u8]) -> Result<Self, BudgetDecodeError> {
        let mut cur = CbeCursor::new(bytes);
        let p = Self::decode_at(&mut cur)?;
        if !cur.is_at_end() {
            return Err(BudgetDecodeError::TrailingBytes {
                trailing: bytes.len() - cur.pos(),
            });
        }
        Ok(p)
    }
}

/// A per-actor epoch budget cell.  Mirror of
/// `LegalKernel.Authority.ActorBudget` (`Authority/ActorBudget.lean`).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ActorBudget {
    /// The last epoch index at which this cell was observed/mutated.
    pub last_seen_epoch: u64,
    /// The budget balance tracked for `last_seen_epoch`.
    pub budget_balance: u64,
}

impl ActorBudget {
    /// The empty cell (`lastSeenEpoch = 0`, `budgetBalance = 0`).
    /// Mirrors `ActorBudget.empty`.
    #[must_use]
    pub fn empty() -> Self {
        Self {
            last_seen_epoch: 0,
            budget_balance: 0,
        }
    }

    /// Normalise against `now`, flooring a stale balance at
    /// `free_tier`.  Mirrors `ActorBudget.normalise`: when the cell
    /// is from a strictly earlier epoch, advance it to `now` and
    /// raise its balance to `max(balance, free_tier)`; otherwise
    /// leave it unchanged.
    #[must_use]
    pub fn normalise(self, now: u64, free_tier: u64) -> Self {
        if self.last_seen_epoch < now {
            Self {
                last_seen_epoch: now,
                budget_balance: self.budget_balance.max(free_tier),
            }
        } else {
            self
        }
    }

    /// Attempt to consume `cost` units after normalisation.  Mirrors
    /// `ActorBudget.consume`: returns the debited cell when the
    /// normalised balance covers `cost`, else `None`.  The
    /// subtraction is guarded (no underflow).
    #[must_use]
    pub fn consume(self, now: u64, free_tier: u64, cost: u64) -> Option<Self> {
        let normalised = self.normalise(now, free_tier);
        if cost <= normalised.budget_balance {
            Some(Self {
                last_seen_epoch: normalised.last_seen_epoch,
                budget_balance: normalised.budget_balance - cost,
            })
        } else {
            None
        }
    }

    /// Add `amount` units after normalisation.  Mirrors
    /// `ActorBudget.topUp`.
    ///
    /// Lean models the balance as an unbounded `Nat`; this mirror
    /// saturates at `u64::MAX`.  The saturation point (`2^64`) is
    /// already past the `< 2^64` CBE-encodable bound, so it is
    /// unreachable for any balance that round-trips through the wire.
    #[must_use]
    pub fn top_up(self, now: u64, free_tier: u64, amount: u64) -> Self {
        let normalised = self.normalise(now, free_tier);
        Self {
            last_seen_epoch: normalised.last_seen_epoch,
            budget_balance: normalised.budget_balance.saturating_add(amount),
        }
    }

    /// CBE-encode this cell, byte-for-byte equal to Lean's
    /// `ActorBudget.encode`: `lastSeenEpoch` then `budgetBalance`,
    /// each a CBE uint head.
    #[must_use]
    pub fn encode(self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEAD_LEN * 2);
        push_cbe_uint(&mut out, self.last_seen_epoch);
        push_cbe_uint(&mut out, self.budget_balance);
        out
    }

    /// Decode an `ActorBudget` from a cursor (mirrors Lean's
    /// `ActorBudget.decode`: `lastSeenEpoch` then `budgetBalance`).
    fn decode_at(cur: &mut CbeCursor) -> Result<Self, BudgetDecodeError> {
        let last_seen_epoch = cur.read_uint()?;
        let budget_balance = cur.read_uint()?;
        Ok(Self {
            last_seen_epoch,
            budget_balance,
        })
    }

    /// Decode an `ActorBudget` from a complete byte buffer, requiring
    /// the whole buffer to be consumed.
    ///
    /// # Errors
    ///
    /// Returns a [`BudgetDecodeError`] on malformed or trailing input.
    pub fn decode(bytes: &[u8]) -> Result<Self, BudgetDecodeError> {
        let mut cur = CbeCursor::new(bytes);
        let b = Self::decode_at(&mut cur)?;
        if !cur.is_at_end() {
            return Err(BudgetDecodeError::TrailingBytes {
                trailing: bytes.len() - cur.pos(),
            });
        }
        Ok(b)
    }
}

impl Default for ActorBudget {
    fn default() -> Self {
        Self::empty()
    }
}

/// The per-actor budget ledger.  Mirror of
/// `LegalKernel.Authority.EpochBudgetState` (a `TreeMap ActorId
/// ActorBudget`).  Backed by a [`BTreeMap`] so iteration order is
/// ascending by actor id, matching the Lean `TreeMap`'s `compare`
/// ordering — the property the CBE map encoding relies on for
/// byte-equivalence.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EpochBudgetState(BTreeMap<u64, ActorBudget>);

impl EpochBudgetState {
    /// The empty ledger.  Mirrors `EpochBudgetState.empty`.
    #[must_use]
    pub fn empty() -> Self {
        Self(BTreeMap::new())
    }

    /// `true` iff no actor has a budget cell.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// The number of populated budget cells.
    #[must_use]
    pub fn len(&self) -> usize {
        self.0.len()
    }

    /// The raw cell stored for `actor`, if any.  A missing entry
    /// behaves as [`ActorBudget::empty`] in every transition (mirrors
    /// Lean's `ebs[a]?.getD ActorBudget.empty`).
    #[must_use]
    pub fn cell(&self, actor: u64) -> Option<ActorBudget> {
        self.0.get(&actor).copied()
    }

    /// The actor's budget after normalising its cell against `now`.
    /// Mirrors `EpochBudgetState.currentBudget`.
    #[must_use]
    pub fn current_budget(&self, actor: u64, now: u64, free_tier: u64) -> u64 {
        self.0
            .get(&actor)
            .copied()
            .unwrap_or_default()
            .normalise(now, free_tier)
            .budget_balance
    }

    /// Consume `cost` units from `actor` in place.  Mirrors
    /// `EpochBudgetState.consume`: returns `true` and updates the
    /// cell on success; returns `false` and leaves the ledger
    /// untouched when the normalised balance is below `cost`.
    fn consume_in_place(&mut self, actor: u64, now: u64, free_tier: u64, cost: u64) -> bool {
        let cell = self.0.get(&actor).copied().unwrap_or_default();
        match cell.consume(now, free_tier, cost) {
            Some(updated) => {
                self.0.insert(actor, updated);
                true
            }
            None => false,
        }
    }

    /// Credit `actor` by `amount` in place.  Mirrors
    /// `EpochBudgetState.topUp`.
    fn top_up_in_place(&mut self, actor: u64, now: u64, free_tier: u64, amount: u64) {
        let cell = self.0.get(&actor).copied().unwrap_or_default();
        self.0.insert(actor, cell.top_up(now, free_tier, amount));
    }

    /// CBE-encode this ledger, byte-for-byte equal to the
    /// `encodeSortedPairs (K := Nat) (V := ActorBudget)` map form
    /// embedded in Lean's `ExtendedState.encode`
    /// (`Encoding/State.lean`): a CBE map head (`cbeTagMap` + 8-byte
    /// LE pair count) followed by each `(actorId, cell)` pair in
    /// ascending actor-id order, the key a CBE uint and the value
    /// the cell's [`ActorBudget::encode`].
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.push(CBE_TAG_MAP);
        // Pair count as an 8-byte LE head value.  `len()` fits in
        // `u64` on every supported host; the saturating conversion is
        // a wire-bound statement, not an expected runtime path.
        let count = u64::try_from(self.0.len()).unwrap_or(u64::MAX);
        out.extend_from_slice(&count.to_le_bytes());
        for (actor, cell) in &self.0 {
            push_cbe_uint(&mut out, *actor);
            out.extend_from_slice(&cell.encode());
        }
        out
    }

    /// Decode an `EpochBudgetState` from a cursor: a CBE map head
    /// (count `n`) then `n` `(actorId, ActorBudget)` pairs.  Mirrors
    /// the `decodeMap (K := Nat) (V := ActorBudget)` path Lean uses
    /// for `epochBudgets`.  Rejects non-strictly-ascending keys (the
    /// canonical-order requirement the encoder always satisfies),
    /// matching Lean's `decodeMap` canonicalisation check.
    fn decode_at(cur: &mut CbeCursor) -> Result<Self, BudgetDecodeError> {
        let count = cur.read_map_head()?;
        let mut map = BTreeMap::new();
        let mut prev_key: Option<u64> = None;
        for _ in 0..count {
            let key = cur.read_uint()?;
            if let Some(p) = prev_key {
                if key <= p {
                    return Err(BudgetDecodeError::NonCanonical {
                        reason: "epochBudgets keys must be strictly ascending",
                    });
                }
            }
            prev_key = Some(key);
            let cell = ActorBudget::decode_at(cur)?;
            map.insert(key, cell);
        }
        Ok(Self(map))
    }

    /// Decode an `EpochBudgetState` from a complete byte buffer,
    /// requiring the whole buffer to be consumed.
    ///
    /// # Errors
    ///
    /// Returns a [`BudgetDecodeError`] on malformed, non-canonical
    /// (unsorted keys), or trailing input.
    pub fn decode(bytes: &[u8]) -> Result<Self, BudgetDecodeError> {
        let mut cur = CbeCursor::new(bytes);
        let m = Self::decode_at(&mut cur)?;
        if !cur.is_at_end() {
            return Err(BudgetDecodeError::TrailingBytes {
                trailing: bytes.len() - cur.pos(),
            });
        }
        Ok(m)
    }
}

/// The budget-relevant projection of a decoded `Action`.  Captures
/// exactly the fields the GP.3.2 budget gate consults; every other
/// action field is skipped during decoding.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ActionBudgetKind {
    /// Any action that neither grants budget nor carries a
    /// signer-correlation safety gate: it simply consumes one
    /// action-cost unit from the signer (unless the signer is the
    /// exempt bridge actor).
    Ordinary,
    /// `Action.depositWithFee` (tag 19).  Grants `budget_grant` to
    /// `recipient`; must be bridge-signed.
    DepositWithFee {
        /// The L2 actor whose budget is credited.
        recipient: u64,
        /// The budget units granted to `recipient`.
        budget_grant: u64,
    },
    /// `Action.topUpActionBudget` (tag 20).  Credits the signer's
    /// own budget by `budget_increment` after a gas debit to
    /// `pool_actor`.
    TopUpActionBudget {
        /// The gas resource the signer pays from (captured so the
        /// strict-mode gate can check the gas-balance conjunct).
        gas_resource: u64,
        /// The gas-pool actor credited the gas payment.
        pool_actor: u64,
        /// The gas amount transferred (must be `> 0`).
        gas_amount: u64,
        /// The budget units credited to the signer.
        budget_increment: u64,
    },
    /// `Action.topUpActionBudgetFor` (tag 21).  Credits `recipient`'s
    /// budget by `budget_increment` after a gas debit by the signer
    /// to `pool_actor` (delegated top-up).
    TopUpActionBudgetFor {
        /// The L2 actor whose budget is credited.
        recipient: u64,
        /// The gas resource the signer pays from (captured so the
        /// strict-mode gate can check the gas-balance conjunct).
        gas_resource: u64,
        /// The gas-pool actor credited the gas payment.
        pool_actor: u64,
        /// The gas amount transferred (must be `> 0`).
        gas_amount: u64,
        /// The budget units credited to `recipient`.
        budget_increment: u64,
    },
    /// `Action.claimBudgetRefund` (tag 22, GP.9.1).  CONSUMES
    /// `action_cost + budget_units` from the signer (claimant) — a
    /// refund retires purchased budget, so it is a budget DEBIT, not a
    /// grant.  The pool is debited / the claimant credited at the
    /// kernel layer (out of the budget gate's scope).  The gate
    /// enforces the policy/balance-INDEPENDENT conjuncts (signer ≠
    /// bridge / pool, positive rate + units) and DEFERS the rate-pin
    /// (`wei == refundRate(gas_resource)`), the `pool_actor ==
    /// gasPoolActor` pin, the `budget_units ≤ refundableBudget` bound,
    /// and pool solvency to the authoritative Lean kernel via
    /// `CommandKernel` — exactly the GP.6.2 deferred-conjunct posture.
    ClaimBudgetRefund {
        /// The gas resource the refund is paid in (captured for the
        /// strict-mode pool-solvency check).
        gas_resource: u64,
        /// The gas-pool actor the refund is debited from.
        pool_actor: u64,
        /// The purchased budget units being retired — the EXTRA
        /// consume on top of `action_cost`.
        budget_units: u64,
        /// The trusted budget→gas exchange rate (`≥ 1` enables the
        /// refund; `0` is the disabled default the gate rejects).
        wei_per_budget_unit: u64,
    },
}

/// The budget-relevant projection of a decoded `SignedAction`: the
/// signer plus the [`ActionBudgetKind`] of its action.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SignedActionBudgetView {
    /// The action's signer (`SignedAction.signer`).
    pub signer: u64,
    /// The budget-relevant projection of the action.
    pub kind: ActionBudgetKind,
}

/// Errors from [`decode_budget_view`].
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum BudgetDecodeError {
    /// The stream ended before a required field was read.
    #[error("unexpected end of CBE stream while decoding budget view")]
    UnexpectedEnd,
    /// A CBE uint head carried the wrong type tag.
    #[error("expected CBE uint tag 0x00 at offset {offset}, found 0x{found:02x}")]
    ExpectedUint {
        /// Byte offset of the bad head.
        offset: usize,
        /// The tag byte actually found.
        found: u8,
    },
    /// A CBE byte-string head carried the wrong type tag.
    #[error("expected CBE byte-string tag 0x02 at offset {offset}, found 0x{found:02x}")]
    ExpectedBytes {
        /// Byte offset of the bad head.
        offset: usize,
        /// The tag byte actually found.
        found: u8,
    },
    /// The action's constructor tag is a valid kernel action but one
    /// whose CBE body this mirror does not model (the nested-encoding
    /// `dispute` (8) / `verdict` (10) / `declareLocalPolicy` (15)
    /// variants).  The authoritative Lean kernel handles them; the
    /// in-memory mock fails closed.
    #[error("action constructor tag {tag} is not modelled by the in-memory budget gate")]
    UnsupportedActionTag {
        /// The unmodelled constructor tag.
        tag: u64,
    },
    /// The action's constructor tag is outside the frozen `[0, 21]`
    /// range.
    #[error("unknown action constructor tag {tag}")]
    UnknownActionTag {
        /// The out-of-range constructor tag.
        tag: u64,
    },
    /// A CBE map head carried the wrong type tag (ledger decode).
    #[error("expected CBE map tag 0x05 at offset {offset}, found 0x{found:02x}")]
    ExpectedMap {
        /// Byte offset of the bad head.
        offset: usize,
        /// The tag byte actually found.
        found: u8,
    },
    /// A decoded value violated a canonical-form constraint (e.g. a
    /// `BudgetPolicy` constructor tag `!= 0`, or `actionCost == 0`,
    /// which the encoder's `mk_bounded` clamp can never produce).
    #[error("non-canonical encoding: {reason}")]
    NonCanonical {
        /// Why the bytes are non-canonical.
        reason: &'static str,
    },
    /// Bytes remained after a whole-buffer decode that expected to
    /// consume the entire input.
    #[error("{trailing} trailing byte(s) after decode")]
    TrailingBytes {
        /// Number of unconsumed bytes.
        trailing: usize,
    },
}

/// A bounds-checked, panic-free reader over a CBE byte stream.
struct CbeCursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> CbeCursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    /// The number of bytes consumed so far.
    fn pos(&self) -> usize {
        self.pos
    }

    /// `true` iff the whole buffer has been consumed.
    fn is_at_end(&self) -> bool {
        self.pos >= self.bytes.len()
    }

    /// Read a CBE map head (tag `0x05` + 8-byte LE element count),
    /// returning the count and advancing the cursor by [`HEAD_LEN`].
    fn read_map_head(&mut self) -> Result<u64, BudgetDecodeError> {
        let end = self
            .pos
            .checked_add(HEAD_LEN)
            .ok_or(BudgetDecodeError::UnexpectedEnd)?;
        let head = self
            .bytes
            .get(self.pos..end)
            .ok_or(BudgetDecodeError::UnexpectedEnd)?;
        if head[0] != CBE_TAG_MAP {
            return Err(BudgetDecodeError::ExpectedMap {
                offset: self.pos,
                found: head[0],
            });
        }
        let mut le = [0u8; 8];
        le.copy_from_slice(&head[1..HEAD_LEN]);
        self.pos = end;
        Ok(u64::from_le_bytes(le))
    }

    /// Read a CBE uint head (tag `0x00` + 8-byte LE value),
    /// advancing the cursor by [`HEAD_LEN`].
    fn read_uint(&mut self) -> Result<u64, BudgetDecodeError> {
        let end = self
            .pos
            .checked_add(HEAD_LEN)
            .ok_or(BudgetDecodeError::UnexpectedEnd)?;
        let head = self
            .bytes
            .get(self.pos..end)
            .ok_or(BudgetDecodeError::UnexpectedEnd)?;
        if head[0] != CBE_TAG_UINT {
            return Err(BudgetDecodeError::ExpectedUint {
                offset: self.pos,
                found: head[0],
            });
        }
        let mut le = [0u8; 8];
        le.copy_from_slice(&head[1..HEAD_LEN]);
        self.pos = end;
        Ok(u64::from_le_bytes(le))
    }

    /// Read a CBE uint head and discard its value.
    fn skip_uint(&mut self) -> Result<(), BudgetDecodeError> {
        self.read_uint().map(|_| ())
    }

    /// Skip a CBE byte-string field (tag `0x02` + 8-byte LE length +
    /// `length` payload bytes), advancing past the whole field.
    fn skip_bytes(&mut self) -> Result<(), BudgetDecodeError> {
        let end = self
            .pos
            .checked_add(HEAD_LEN)
            .ok_or(BudgetDecodeError::UnexpectedEnd)?;
        let head = self
            .bytes
            .get(self.pos..end)
            .ok_or(BudgetDecodeError::UnexpectedEnd)?;
        if head[0] != CBE_TAG_BYTES {
            return Err(BudgetDecodeError::ExpectedBytes {
                offset: self.pos,
                found: head[0],
            });
        }
        let mut le = [0u8; 8];
        le.copy_from_slice(&head[1..HEAD_LEN]);
        let len = usize::try_from(u64::from_le_bytes(le))
            .map_err(|_| BudgetDecodeError::UnexpectedEnd)?;
        let payload_end = end
            .checked_add(len)
            .ok_or(BudgetDecodeError::UnexpectedEnd)?;
        // Confirm the payload bytes are actually present.
        if payload_end > self.bytes.len() {
            return Err(BudgetDecodeError::UnexpectedEnd);
        }
        self.pos = payload_end;
        Ok(())
    }
}

/// Decode the budget-relevant projection of a CBE-encoded
/// `SignedAction`.
///
/// Mirrors the prefix of Lean's `Encoding.SignedAction.decode`
/// (`action ++ signer ++ nonce ++ sig`): the action is parsed by its
/// frozen constructor tag (so the cursor lands exactly on the signer
/// field), then the signer uint is read.  The trailing `nonce` and
/// `sig` are not needed for budgeting and are left unread.
///
/// The three nested-encoding action variants (`dispute` = 8,
/// `verdict` = 10, `declareLocalPolicy` = 15) are reported as
/// [`BudgetDecodeError::UnsupportedActionTag`]: their CBE bodies route
/// through `Encoding.Disputes` / `Encoding.LocalPolicy` and are not
/// modelled by this in-memory mirror.  The authoritative Lean kernel
/// (reached via [`crate::kernel::command::CommandKernel`]) budgets
/// them; the in-memory mock fails closed.
///
/// # Errors
///
/// Returns a [`BudgetDecodeError`] when the stream is malformed,
/// truncated, or carries an unmodelled / unknown constructor tag.
pub fn decode_budget_view(bytes: &[u8]) -> Result<SignedActionBudgetView, BudgetDecodeError> {
    let mut cur = CbeCursor::new(bytes);
    let tag = cur.read_uint()?;
    let kind = match tag {
        // transfer(0): r, sender, receiver, amount.
        0 => {
            for _ in 0..4 {
                cur.skip_uint()?;
            }
            ActionBudgetKind::Ordinary
        }
        // mint(1) / burn(2): r, x, amount.
        1 | 2 => {
            for _ in 0..3 {
                cur.skip_uint()?;
            }
            ActionBudgetKind::Ordinary
        }
        // freezeResource(3): r.
        3 => {
            cur.skip_uint()?;
            ActionBudgetKind::Ordinary
        }
        // replaceKey(4): actor, newKey(bytes).
        4 => {
            cur.skip_uint()?;
            cur.skip_bytes()?;
            ActionBudgetKind::Ordinary
        }
        // reward(5) / distributeOthers(6) / proportionalDilute(7):
        // r, x, amount.
        5..=7 => {
            for _ in 0..3 {
                cur.skip_uint()?;
            }
            ActionBudgetKind::Ordinary
        }
        // disputeWithdraw(9): idx.  rollback(11): targetIdx.
        9 | 11 => {
            cur.skip_uint()?;
            ActionBudgetKind::Ordinary
        }
        // registerIdentity(12): actor, pk(bytes).
        12 => {
            cur.skip_uint()?;
            cur.skip_bytes()?;
            ActionBudgetKind::Ordinary
        }
        // deposit(13): r, recipient, amount, depositId.
        13 => {
            for _ in 0..4 {
                cur.skip_uint()?;
            }
            ActionBudgetKind::Ordinary
        }
        // withdraw(14): r, sender, amount, recipientL1(bytes).
        14 => {
            for _ in 0..3 {
                cur.skip_uint()?;
            }
            cur.skip_bytes()?;
            ActionBudgetKind::Ordinary
        }
        // revokeLocalPolicy(16): no fields.
        16 => ActionBudgetKind::Ordinary,
        // faultProofChallenge(17): bindingHash(bytes), start, end,
        // commit(bytes).
        17 => {
            cur.skip_bytes()?;
            cur.skip_uint()?;
            cur.skip_uint()?;
            cur.skip_bytes()?;
            ActionBudgetKind::Ordinary
        }
        // faultProofResolution(18): bindingHash(bytes), gameId,
        // winner, revertFrom.
        18 => {
            cur.skip_bytes()?;
            for _ in 0..3 {
                cur.skip_uint()?;
            }
            ActionBudgetKind::Ordinary
        }
        // depositWithFee(19): r, recipient, poolActor, userAmount,
        // poolAmount, budgetGrant, depositId.
        19 => {
            cur.skip_uint()?; // r
            let recipient = cur.read_uint()?;
            cur.skip_uint()?; // poolActor
            cur.skip_uint()?; // userAmount
            cur.skip_uint()?; // poolAmount
            let budget_grant = cur.read_uint()?;
            cur.skip_uint()?; // depositId
            ActionBudgetKind::DepositWithFee {
                recipient,
                budget_grant,
            }
        }
        // topUpActionBudget(20): gasResource, gasAmount,
        // budgetIncrement, poolActor.
        20 => {
            let gas_resource = cur.read_uint()?;
            let gas_amount = cur.read_uint()?;
            let budget_increment = cur.read_uint()?;
            let pool_actor = cur.read_uint()?;
            ActionBudgetKind::TopUpActionBudget {
                gas_resource,
                pool_actor,
                gas_amount,
                budget_increment,
            }
        }
        // topUpActionBudgetFor(21): recipient, gasResource, gasAmount,
        // budgetIncrement, poolActor.
        21 => {
            let recipient = cur.read_uint()?;
            let gas_resource = cur.read_uint()?;
            let gas_amount = cur.read_uint()?;
            let budget_increment = cur.read_uint()?;
            let pool_actor = cur.read_uint()?;
            ActionBudgetKind::TopUpActionBudgetFor {
                recipient,
                gas_resource,
                pool_actor,
                gas_amount,
                budget_increment,
            }
        }
        // claimBudgetRefund(22): gasResource, budgetUnits,
        // weiPerBudgetUnit, poolActor.  GP.9.1 refund-on-exit.
        22 => {
            let gas_resource = cur.read_uint()?;
            let budget_units = cur.read_uint()?;
            let wei_per_budget_unit = cur.read_uint()?;
            let pool_actor = cur.read_uint()?;
            ActionBudgetKind::ClaimBudgetRefund {
                gas_resource,
                pool_actor,
                budget_units,
                wei_per_budget_unit,
            }
        }
        // dispute(8) / verdict(10) / declareLocalPolicy(15): nested
        // encodings not modelled here.
        8 | 10 | 15 => return Err(BudgetDecodeError::UnsupportedActionTag { tag }),
        other => return Err(BudgetDecodeError::UnknownActionTag { tag: other }),
    };
    let signer = cur.read_uint()?;
    // The SignedAction wire layout is `action ++ signer ++ nonce ++ sig`
    // (mirrors Lean's `Encoding.SignedAction.decode`).  The budget gate
    // does not need `nonce` / `sig`, but a complete, well-formed request
    // MUST carry them: read past both so a malformed / truncated buffer
    // is rejected as a decode error rather than silently admitting a
    // partial action (which would still mutate the budget ledger), and
    // reject trailing garbage so the entire buffer is accounted for.
    cur.skip_uint()?; // nonce
    cur.skip_bytes()?; // sig
    if !cur.is_at_end() {
        return Err(BudgetDecodeError::TrailingBytes {
            trailing: bytes.len() - cur.pos(),
        });
    }
    Ok(SignedActionBudgetView { signer, kind })
}

/// Why a [`BudgetGate`] refused an action.  Every variant maps to the
/// host's `NotAdmissible` verdict; the [`GateRejection::reason`]
/// string distinguishes them in the wire-format reason field.
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum GateRejection {
    /// The signer's normalised budget was below the per-action cost.
    /// This is the canonical OQ-GP-3 rejection; its reason string is
    /// the wire-stable `"InsufficientBudget"`.
    #[error("InsufficientBudget")]
    InsufficientBudget,
    /// A `topUpActionBudget` / `topUpActionBudgetFor` was signed by
    /// the bridge actor (rejected by the gate's first conjunct; the
    /// bridge actor is consume-exempt, so a self-top-up would mint
    /// free budget).
    #[error("BudgetGateBridgeActorTopUp")]
    BridgeActorTopUp,
    /// A `topUpActionBudget` / `topUpActionBudgetFor` routed its gas
    /// payment to the signer's own pool slot (net-zero kernel effect
    /// but a free budget grant).
    #[error("BudgetGateSelfPoolTopUp")]
    SelfPoolTopUp,
    /// A `topUpActionBudget` / `topUpActionBudgetFor` carried a zero
    /// gas amount (a no-op kernel step that would still grant
    /// budget).
    #[error("BudgetGateZeroGasTopUp")]
    ZeroGasTopUp,
    /// A `topUpActionBudgetFor` named the signer as its own recipient
    /// (the law's `recipient != signer` precondition; the kernel step
    /// would no-op while the grant still ran).
    #[error("BudgetGateSelfRecipientDelegatedTopUp")]
    SelfRecipientDelegatedTopUp,
    /// A `depositWithFee` was signed by a non-bridge actor (would
    /// inject free balance + free budget; only the bridge actor may
    /// sign deposit-class actions).
    #[error("BudgetGateNonBridgeDepositWithFee")]
    NonBridgeDepositWithFee,
    /// STRICT MODE ONLY: a `topUpActionBudget` /
    /// `topUpActionBudgetFor` signer's balance at the gas resource
    /// was below `gasAmount` (the Lean gate's `getBalance >=
    /// gasAmount` conjunct).  Only raised when the gate is in strict
    /// mode with a balance oracle; in the default lightweight mode
    /// this conjunct is deferred to the Lean kernel.
    #[error("BudgetGateInsufficientGas")]
    InsufficientGas,
    /// STRICT MODE ONLY: a `topUpActionBudgetFor` recipient had not
    /// authorised the signer as a delegate (the Lean gate's
    /// `delegatedTopUpConsentBool` conjunct).  Only raised when the
    /// gate is in strict mode with a consent oracle.
    #[error("BudgetGateDelegationNotAuthorized")]
    DelegationNotAuthorized,
    /// GP.9.1: a `claimBudgetRefund` was signed by the bridge actor
    /// (consume-exempt, so a self-refund would drain the pool for
    /// free).
    #[error("BudgetGateRefundByBridgeActor")]
    RefundByBridgeActor,
    /// GP.9.1: a `claimBudgetRefund` named the signer as its own pool
    /// (net-zero kernel effect; rejected so the claimant cannot be the
    /// pool).
    #[error("BudgetGateRefundToSelfPool")]
    RefundToSelfPool,
    /// GP.9.1: a `claimBudgetRefund` carried `weiPerBudgetUnit == 0`
    /// (refunds disabled — the default; the Lean gate's `1 <=
    /// weiPerBudgetUnit` refund-enabled conjunct).
    #[error("BudgetGateRefundRateDisabled")]
    RefundRateDisabled,
    /// GP.9.1: a `claimBudgetRefund` carried `budgetUnits == 0` (a
    /// zero-payout no-op the gate rejects).
    #[error("BudgetGateRefundZeroUnits")]
    RefundZeroUnits,
    /// GP.9.1 (review fix): a `claimBudgetRefund` named a non-canonical
    /// gas resource (neither 0 = ETH nor 1 = BOLD); the gas pool
    /// operates only at those legs, so the refund is rejected regardless
    /// of the deployment's rate function.
    #[error("BudgetGateRefundNonCanonicalResource")]
    RefundNonCanonicalResource,
    /// STRICT MODE ONLY: a `claimBudgetRefund`'s pool balance at the
    /// gas resource was below `budgetUnits * weiPerBudgetUnit` (the
    /// Lean gate's pool-solvency conjunct).  Only raised when the gate
    /// is in strict mode with a balance oracle; otherwise deferred to
    /// the Lean kernel.
    #[error("BudgetGateRefundInsufficientPool")]
    RefundInsufficientPool,
}

impl GateRejection {
    /// The wire-format reason string for this rejection.  Equals the
    /// `thiserror` `Display`; surfaced here as a `&'static str` so the
    /// kernel can build a `VerdictResponse` without an allocation.
    #[must_use]
    pub fn reason(self) -> &'static str {
        match self {
            Self::InsufficientBudget => "InsufficientBudget",
            Self::BridgeActorTopUp => "BudgetGateBridgeActorTopUp",
            Self::SelfPoolTopUp => "BudgetGateSelfPoolTopUp",
            Self::ZeroGasTopUp => "BudgetGateZeroGasTopUp",
            Self::SelfRecipientDelegatedTopUp => "BudgetGateSelfRecipientDelegatedTopUp",
            Self::NonBridgeDepositWithFee => "BudgetGateNonBridgeDepositWithFee",
            Self::InsufficientGas => "BudgetGateInsufficientGas",
            Self::DelegationNotAuthorized => "BudgetGateDelegationNotAuthorized",
            Self::RefundByBridgeActor => "BudgetGateRefundByBridgeActor",
            Self::RefundToSelfPool => "BudgetGateRefundToSelfPool",
            Self::RefundRateDisabled => "BudgetGateRefundRateDisabled",
            Self::RefundZeroUnits => "BudgetGateRefundZeroUnits",
            Self::RefundNonCanonicalResource => "BudgetGateRefundNonCanonicalResource",
            Self::RefundInsufficientPool => "BudgetGateRefundInsufficientPool",
        }
    }
}

/// The in-memory budget-admission gate: a [`BudgetPolicy`] plus the
/// live [`EpochBudgetState`] ledger.  Mirrors the budget-ledger
/// portion of Lean's `apply_admissible_with_budget`
/// (`Authority/SignedAction.lean`) per the scope boundary documented
/// at the module level.
#[derive(Clone, Debug)]
pub struct BudgetGate {
    policy: BudgetPolicy,
    ledger: EpochBudgetState,
    /// STRICT MODE: when `true`, the gate additionally enforces the
    /// two otherwise-deferred conjuncts of the Lean gate
    /// (`getBalance >= gasAmount` and `delegatedTopUpConsentBool`)
    /// using the `balances` / `consent` oracles, making the mock a
    /// FAITHFUL (not merely strictly-weaker) realisation of
    /// `apply_admissible_with_budget`.  Default `false` (the
    /// lightweight, permissive mode).
    strict: bool,
    /// Strict-mode gas-balance oracle: `(gasResource, actor) ->
    /// balance`.  A missing entry reads as `0`.  Only consulted in
    /// strict mode.
    balances: BTreeMap<(u64, u64), u64>,
    /// Strict-mode delegated-top-up consent oracle: the set of
    /// `(recipient, signer)` pairs the recipient has authorised
    /// (mirrors `delegatedTopUpConsentBool`).  Only consulted in
    /// strict mode.
    consent: std::collections::BTreeSet<(u64, u64)>,
    /// GP.6.2 epoch advancement (OQ-GP-4): admitted actions per
    /// budget epoch.  `0` (default) ⇒ the effective epoch is fixed at
    /// `policy.current_epoch()`.  A positive value advances the
    /// effective epoch by one every `epoch_length` ADMITTED actions —
    /// mirroring the Lean runtime's `logIndex`-keyed advancement
    /// (`admitted` plays the role of the next log index).
    epoch_length: u64,
    /// Count of admitted actions (the in-memory analogue of the
    /// runtime's log index), driving epoch advancement.
    admitted: u64,
}

impl BudgetGate {
    /// Construct a gate with an empty ledger under `policy` in the
    /// default (permissive) mode.
    #[must_use]
    pub fn new(policy: BudgetPolicy) -> Self {
        Self {
            policy,
            ledger: EpochBudgetState::empty(),
            strict: false,
            balances: BTreeMap::new(),
            consent: std::collections::BTreeSet::new(),
            epoch_length: 0,
            admitted: 0,
        }
    }

    /// Construct a gate with a pre-seeded ledger (e.g. for tests that
    /// pre-fund specific actors).
    #[must_use]
    pub fn with_ledger(policy: BudgetPolicy, ledger: EpochBudgetState) -> Self {
        Self {
            policy,
            ledger,
            strict: false,
            balances: BTreeMap::new(),
            consent: std::collections::BTreeSet::new(),
            epoch_length: 0,
            admitted: 0,
        }
    }

    /// Enable STRICT mode: the gate will additionally enforce the
    /// gas-balance and delegated-consent conjuncts using the
    /// `set_balance` / `allow_delegate` oracles.  This turns the mock
    /// into a faithful (not merely strictly-weaker) realisation of
    /// the Lean gate; an empty oracle then rejects every gas-funding
    /// action (zero balance / no consent), so a test MUST pre-fund
    /// balances + grant consent for the top-ups it expects to admit.
    #[must_use]
    pub fn with_strict_checks(mut self) -> Self {
        self.strict = true;
        self
    }

    /// Enable GP.6.2 epoch advancement: the effective epoch advances
    /// by one every `epoch_length` ADMITTED actions (0 ⇒ disabled),
    /// mirroring the Lean runtime's `logIndex`-keyed advancement so
    /// the in-memory mock can demonstrate lazy free-tier
    /// replenishment.
    #[must_use]
    pub fn with_epoch_length(mut self, epoch_length: u64) -> Self {
        self.epoch_length = epoch_length;
        self
    }

    /// `true` iff the gate is in strict mode.
    #[must_use]
    pub fn is_strict(&self) -> bool {
        self.strict
    }

    /// The effective epoch the gate currently evaluates at:
    /// `policy.current_epoch() + admitted / epoch_length` (or just
    /// `policy.current_epoch()` when advancement is disabled).
    #[must_use]
    pub fn effective_epoch(&self) -> u64 {
        if self.epoch_length == 0 {
            self.policy.current_epoch()
        } else {
            self.policy
                .current_epoch()
                .saturating_add(self.admitted / self.epoch_length)
        }
    }

    /// Set the strict-mode balance for `(gas_resource, actor)`.
    pub fn set_balance(&mut self, gas_resource: u64, actor: u64, balance: u64) {
        self.balances.insert((gas_resource, actor), balance);
    }

    /// Record that `recipient` has authorised `signer` as a delegate
    /// for `topUpActionBudgetFor` (strict-mode consent oracle).
    pub fn allow_delegate(&mut self, recipient: u64, signer: u64) {
        self.consent.insert((recipient, signer));
    }

    /// The gate's policy.
    #[must_use]
    pub fn policy(&self) -> BudgetPolicy {
        self.policy
    }

    /// The gate's current ledger.
    #[must_use]
    pub fn ledger(&self) -> &EpochBudgetState {
        &self.ledger
    }

    /// The actor's current budget under this gate's policy at the
    /// EFFECTIVE epoch (so a query after an epoch boundary reflects
    /// the replenished free tier).
    #[must_use]
    pub fn current_budget(&self, actor: u64) -> u64 {
        self.ledger
            .current_budget(actor, self.effective_epoch(), self.policy.free_tier())
    }

    /// The strict-mode balance recorded for `(gas_resource, actor)`
    /// (0 if none).  Consulted only in strict mode.
    fn balance_of(&self, gas_resource: u64, actor: u64) -> u64 {
        self.balances
            .get(&(gas_resource, actor))
            .copied()
            .unwrap_or(0)
    }

    /// Evaluate the gate against `view`, returning the post-admission
    /// ledger on success or a [`GateRejection`] on refusal.  Pure:
    /// the gate's own ledger is not mutated (use [`BudgetGate::admit`]
    /// to commit).
    ///
    /// In the default (permissive) mode this mirrors the balance- and
    /// policy-independent conjuncts of the Lean gate, deferring the
    /// `getBalance >= gasAmount` and `delegatedTopUpConsentBool`
    /// conjuncts to the kernel.  In strict mode (see
    /// [`BudgetGate::with_strict_checks`]) it ALSO enforces those two
    /// conjuncts via the balance / consent oracles, becoming a
    /// faithful realisation of `apply_admissible_with_budget`.
    ///
    /// # Errors
    ///
    /// Returns the [`GateRejection`] describing the failed conjunct.
    pub fn evaluate(
        &self,
        view: &SignedActionBudgetView,
    ) -> Result<EpochBudgetState, GateRejection> {
        // GP.6.2: evaluate at the EFFECTIVE epoch (advances with the
        // admitted-action count when `epoch_length > 0`).
        let now = self.effective_epoch();
        let free_tier = self.policy.free_tier();
        let action_cost = self.policy.action_cost();
        let signer = view.signer;

        // Signer-correlation safety gates (the balance/policy-
        // independent conjuncts of the Lean gate), plus the
        // balance/consent conjuncts when in strict mode.
        match view.kind {
            ActionBudgetKind::TopUpActionBudget {
                gas_resource,
                pool_actor,
                gas_amount,
                ..
            } => {
                if signer == BRIDGE_ACTOR {
                    return Err(GateRejection::BridgeActorTopUp);
                }
                if signer == pool_actor {
                    return Err(GateRejection::SelfPoolTopUp);
                }
                if gas_amount == 0 {
                    return Err(GateRejection::ZeroGasTopUp);
                }
                // GP.9.1 round-trip non-profitability: the Lean gate ALSO
                // enforces `budget_increment * refundRate(gas_resource) <=
                // gas_amount` (the `topUpRoundTripCheck` conjunct that seals
                // the top-up -> refund pool-drain — minting cheap budget and
                // refunding it at the deployment rate).  That conjunct is
                // RATE-dependent, so — exactly like the refund rate-pin
                // below — it is deferred to the authoritative Lean kernel via
                // `CommandKernel`; the mock stays a strictly-weaker pre-filter
                // on this dimension.
                if self.strict && self.balance_of(gas_resource, signer) < gas_amount {
                    return Err(GateRejection::InsufficientGas);
                }
            }
            ActionBudgetKind::TopUpActionBudgetFor {
                recipient,
                gas_resource,
                pool_actor,
                gas_amount,
                ..
            } => {
                if signer == BRIDGE_ACTOR {
                    return Err(GateRejection::BridgeActorTopUp);
                }
                if signer == pool_actor {
                    return Err(GateRejection::SelfPoolTopUp);
                }
                if recipient == signer {
                    return Err(GateRejection::SelfRecipientDelegatedTopUp);
                }
                if gas_amount == 0 {
                    return Err(GateRejection::ZeroGasTopUp);
                }
                // GP.9.1 round-trip non-profitability (delegated variant):
                // the Lean gate enforces `budget_increment *
                // refundRate(gas_resource) <= gas_amount` here too (the
                // delegate pays gas for the recipient's budget; the
                // recipient's later refund is bounded by the same
                // inequality).  Rate-dependent ⇒ deferred to the Lean kernel
                // via `CommandKernel`, like the refund rate-pin.
                if self.strict {
                    if self.balance_of(gas_resource, signer) < gas_amount {
                        return Err(GateRejection::InsufficientGas);
                    }
                    if !self.consent.contains(&(recipient, signer)) {
                        return Err(GateRejection::DelegationNotAuthorized);
                    }
                }
            }
            ActionBudgetKind::DepositWithFee { .. } => {
                if signer != BRIDGE_ACTOR {
                    return Err(GateRejection::NonBridgeDepositWithFee);
                }
            }
            ActionBudgetKind::ClaimBudgetRefund {
                gas_resource,
                pool_actor,
                budget_units,
                wei_per_budget_unit,
            } => {
                // GP.9.1: the policy/balance-INDEPENDENT conjuncts of
                // `claimBudgetRefund_gate`.  The rate-pin
                // (`wei == refundRate(gas_resource)`), the `pool_actor ==
                // gasPoolActor` pin, and the `budget_units <=
                // refundableBudget` bound are deferred to the
                // authoritative Lean kernel via `CommandKernel`.
                if signer == BRIDGE_ACTOR {
                    return Err(GateRejection::RefundByBridgeActor);
                }
                if signer == pool_actor {
                    return Err(GateRejection::RefundToSelfPool);
                }
                // Canonical-resource pin (review fix): the gas pool
                // operates only at resource 0 (ETH) / 1 (BOLD), so a
                // refund at any other resource is rejected regardless of
                // the deployment's rate function (policy-independent, so
                // enforced here, not deferred).
                if gas_resource != 0 && gas_resource != 1 {
                    return Err(GateRejection::RefundNonCanonicalResource);
                }
                if wei_per_budget_unit == 0 {
                    return Err(GateRejection::RefundRateDisabled);
                }
                if budget_units == 0 {
                    return Err(GateRejection::RefundZeroUnits);
                }
                if self.strict {
                    // Pool solvency (uint128: the payout can reach ~2^128).
                    let refund_amount = u128::from(budget_units) * u128::from(wei_per_budget_unit);
                    if u128::from(self.balance_of(gas_resource, pool_actor)) < refund_amount {
                        return Err(GateRejection::RefundInsufficientPool);
                    }
                }
            }
            ActionBudgetKind::Ordinary => {}
        }

        let mut ledger = self.ledger.clone();

        // Consume step: the bridge actor is exempt (OQ-GP-6); every
        // other signer is debited `action_cost` PLUS, for a
        // `claimBudgetRefund`, the retired `budget_units` (GP.9.1: the
        // refund is a budget DEBIT of `action_cost + budget_units`).
        let refund_extra = match view.kind {
            ActionBudgetKind::ClaimBudgetRefund { budget_units, .. } => budget_units,
            _ => 0,
        };
        if signer != BRIDGE_ACTOR
            && !ledger.consume_in_place(
                signer,
                now,
                free_tier,
                action_cost.saturating_add(refund_extra),
            )
        {
            return Err(GateRejection::InsufficientBudget);
        }

        // Per-action budget-grant arm, applied to the post-consume
        // ledger (matching Lean's `applyGrant ebs'`).
        match view.kind {
            ActionBudgetKind::DepositWithFee {
                recipient,
                budget_grant,
            } => ledger.top_up_in_place(recipient, now, free_tier, budget_grant),
            ActionBudgetKind::TopUpActionBudget {
                budget_increment, ..
            } => ledger.top_up_in_place(signer, now, free_tier, budget_increment),
            ActionBudgetKind::TopUpActionBudgetFor {
                recipient,
                budget_increment,
                ..
            } => ledger.top_up_in_place(recipient, now, free_tier, budget_increment),
            // GP.9.1: a refund grants NO budget — its budget effect is
            // the `action_cost + budget_units` consume above; `Ordinary`
            // likewise grants nothing (combined to satisfy
            // `clippy::match_same_arms`).
            ActionBudgetKind::ClaimBudgetRefund { .. } | ActionBudgetKind::Ordinary => {}
        }

        Ok(ledger)
    }

    /// Evaluate the gate against `view` and, on success, commit the
    /// post-admission ledger.  On rejection the ledger is unchanged.
    ///
    /// # Errors
    ///
    /// Returns the [`GateRejection`] describing the failed conjunct.
    pub fn admit(&mut self, view: &SignedActionBudgetView) -> Result<(), GateRejection> {
        let next = self.evaluate(view)?;
        self.ledger = next;
        // GP.6.2: a successful admission advances the action counter
        // (the in-memory log index) so the effective epoch can cross
        // a boundary on a later action.
        self.admitted = self.admitted.saturating_add(1);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        decode_budget_view, ActionBudgetKind, ActorBudget, BudgetDecodeError, BudgetGate,
        BudgetPolicy, EpochBudgetState, GateRejection, SignedActionBudgetView, BRIDGE_ACTOR,
        CBE_TAG_MAP, CBE_TAG_UINT,
    };

    // ---- CBE test helpers (independent re-derivation of the wire
    // ---- layout, so the known-vector tests are non-circular). ----

    /// A CBE uint head: `[0x00] ++ LE(n)`.
    fn u(n: u64) -> Vec<u8> {
        let mut v = vec![CBE_TAG_UINT];
        v.extend_from_slice(&n.to_le_bytes());
        v
    }

    /// A CBE byte-string field: `[0x02] ++ LE(len) ++ payload`.
    fn bytes(payload: &[u8]) -> Vec<u8> {
        let mut v = vec![super::CBE_TAG_BYTES];
        v.extend_from_slice(&(payload.len() as u64).to_le_bytes());
        v.extend_from_slice(payload);
        v
    }

    /// Concatenate a list of byte chunks.
    fn cat(chunks: &[Vec<u8>]) -> Vec<u8> {
        chunks.concat()
    }

    /// Append a signer uint (and a throwaway nonce + sig) after an
    /// action's CBE bytes, mirroring `SignedAction.encode`.
    fn signed(action: &[u8], signer: u64) -> Vec<u8> {
        let mut v = action.to_vec();
        v.extend_from_slice(&u(signer));
        v.extend_from_slice(&u(0)); // nonce (unread by the budget decoder)
        v.extend_from_slice(&bytes(&[0xAB; 4])); // sig (unread)
        v
    }

    // ============ Encoding: byte-exact known vectors ============

    /// `ActorBudget.encode` matches the hand-computed Lean bytes:
    /// `lastSeenEpoch` uint ++ `budgetBalance` uint.  Pinned
    /// byte-for-byte against the Lean known-vector test
    /// `actorBudgetEncodeKnownVector` (`Test/Encoding/State.lean`).
    #[test]
    fn actor_budget_encode_known_vector() {
        let b = ActorBudget {
            last_seen_epoch: 1,
            budget_balance: 2,
        };
        let expected: Vec<u8> = vec![
            0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, // lastSeenEpoch = 1
            0x00, 0x02, 0, 0, 0, 0, 0, 0, 0, // budgetBalance = 2
        ];
        assert_eq!(b.encode(), expected);
    }

    /// `BudgetPolicy.encode` matches the hand-computed Lean bytes:
    /// constructor tag 0 ++ freeTier ++ actionCost ++ currentEpoch.
    /// Pinned against `budgetPolicyEncodeKnownVector`.
    #[test]
    fn budget_policy_encode_known_vector() {
        let p = BudgetPolicy::mk_bounded(10, 1, 1);
        let expected: Vec<u8> = vec![
            0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, // bounded tag = 0
            0x00, 0x0a, 0, 0, 0, 0, 0, 0, 0, // freeTier = 10
            0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, // actionCost = 1
            0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, // currentEpoch = 1
        ];
        assert_eq!(p.encode(), expected);
    }

    /// `EpochBudgetState.encode` matches the hand-computed Lean
    /// `encodeSortedPairs` map form: map head (`cbeTagMap` + count)
    /// then each `(actorId, cell)` pair in ascending actor order.
    /// Pinned against `epochBudgetStateEncodeKnownVector`.
    #[test]
    fn epoch_budget_state_encode_known_vector() {
        let mut ebs = EpochBudgetState::empty();
        // Insert out of order to confirm canonical ascending output.
        ebs.top_up_in_place(20, 0, 0, 0); // creates cell {0,0}
        ebs.top_up_in_place(10, 0, 0, 0);
        // Force specific cell contents for the vector.
        ebs.0.insert(
            10,
            ActorBudget {
                last_seen_epoch: 1,
                budget_balance: 5,
            },
        );
        ebs.0.insert(
            20,
            ActorBudget {
                last_seen_epoch: 2,
                budget_balance: 7,
            },
        );
        let expected: Vec<u8> = vec![
            CBE_TAG_MAP,
            0x02,
            0,
            0,
            0,
            0,
            0,
            0,
            0, // count = 2
            // key 10
            0x00,
            0x0a,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            // cell {1, 5}
            0x00,
            0x01,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0x00,
            0x05,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            // key 20
            0x00,
            0x14,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            // cell {2, 7}
            0x00,
            0x02,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0x00,
            0x07,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        ];
        assert_eq!(ebs.encode(), expected);
    }

    /// Empty ledger encodes to a map head with count 0 (9 bytes).
    #[test]
    fn empty_epoch_budget_state_encode() {
        let ebs = EpochBudgetState::empty();
        assert_eq!(ebs.encode(), vec![CBE_TAG_MAP, 0, 0, 0, 0, 0, 0, 0, 0]);
    }

    /// Encoding is deterministic.
    #[test]
    fn encode_deterministic() {
        let p = BudgetPolicy::mk_bounded(3, 2, 4);
        assert_eq!(p.encode(), p.encode());
        let b = ActorBudget {
            last_seen_epoch: 9,
            budget_balance: 13,
        };
        assert_eq!(b.encode(), b.encode());
    }

    // ============ BudgetPolicy ============

    /// `mk_bounded` clamps `action_cost` to at least 1.
    #[test]
    fn mk_bounded_clamps_action_cost() {
        assert_eq!(BudgetPolicy::mk_bounded(0, 0, 0).action_cost(), 1);
        assert_eq!(BudgetPolicy::mk_bounded(0, 1, 0).action_cost(), 1);
        assert_eq!(BudgetPolicy::mk_bounded(0, 5, 0).action_cost(), 5);
    }

    /// Field accessors round-trip the constructor values.
    #[test]
    fn policy_accessors() {
        let p = BudgetPolicy::mk_bounded(10, 3, 7);
        assert_eq!(p.free_tier(), 10);
        assert_eq!(p.action_cost(), 3);
        assert_eq!(p.current_epoch(), 7);
    }

    // ============ ActorBudget semantics (mirror Lean) ============

    /// `normalise` is the identity when the cell is current (epoch
    /// not strictly earlier than `now`).  Mirrors
    /// `normalise_noop_if_current`.
    #[test]
    fn normalise_noop_if_current() {
        let b = ActorBudget {
            last_seen_epoch: 5,
            budget_balance: 3,
        };
        assert_eq!(b.normalise(5, 100), b);
        assert_eq!(b.normalise(4, 100), b);
    }

    /// A stale cell is floored at `free_tier` and advanced to `now`.
    /// Mirrors `normalise_floors_at_freeTier`.
    #[test]
    fn normalise_floors_stale_cell() {
        let b = ActorBudget {
            last_seen_epoch: 1,
            budget_balance: 3,
        };
        let n = b.normalise(5, 10);
        assert_eq!(n.last_seen_epoch, 5);
        assert_eq!(n.budget_balance, 10); // max(3, 10)
                                          // A stale cell whose balance exceeds the floor keeps its balance.
        let rich = ActorBudget {
            last_seen_epoch: 1,
            budget_balance: 50,
        };
        assert_eq!(rich.normalise(5, 10).budget_balance, 50);
    }

    /// `consume` succeeds iff the normalised balance covers the cost,
    /// and subtracts exactly.  Mirrors `consume_some_budgetBalance` /
    /// `consume_eq_none_iff`.
    #[test]
    fn consume_semantics() {
        let b = ActorBudget {
            last_seen_epoch: 5,
            budget_balance: 3,
        };
        assert_eq!(
            b.consume(5, 0, 2),
            Some(ActorBudget {
                last_seen_epoch: 5,
                budget_balance: 1
            })
        );
        assert_eq!(b.consume(5, 0, 3).map(|c| c.budget_balance), Some(0));
        assert_eq!(b.consume(5, 0, 4), None);
        // Stale cell is normalised before the cost check.
        let stale = ActorBudget {
            last_seen_epoch: 1,
            budget_balance: 0,
        };
        assert_eq!(stale.consume(5, 10, 4).map(|c| c.budget_balance), Some(6));
    }

    /// `top_up` adds after normalisation.  Mirrors `topUp_budgetBalance`.
    #[test]
    fn top_up_semantics() {
        let b = ActorBudget {
            last_seen_epoch: 5,
            budget_balance: 3,
        };
        assert_eq!(b.top_up(5, 0, 7).budget_balance, 10);
        // Stale cell normalised (floored) then credited.
        let stale = ActorBudget {
            last_seen_epoch: 1,
            budget_balance: 0,
        };
        let t = stale.top_up(5, 10, 7);
        assert_eq!(t.last_seen_epoch, 5);
        assert_eq!(t.budget_balance, 17); // max(0,10) + 7
    }

    /// `top_up` saturates at `u64::MAX` rather than wrapping.
    #[test]
    fn top_up_saturates() {
        let b = ActorBudget {
            last_seen_epoch: 5,
            budget_balance: u64::MAX - 1,
        };
        assert_eq!(b.top_up(5, 0, 10).budget_balance, u64::MAX);
    }

    // ============ EpochBudgetState semantics ============

    /// A missing cell yields `current_budget` floored at `free_tier`
    /// (after epoch advance) and `0` at genesis epoch.
    #[test]
    fn current_budget_missing_cell() {
        let ebs = EpochBudgetState::empty();
        // now=0 (genesis): empty cell stays 0.
        assert_eq!(ebs.current_budget(7, 0, 10), 0);
        // now=1 > 0: floored at free_tier.
        assert_eq!(ebs.current_budget(7, 1, 10), 10);
    }

    /// `consume` is local: it only affects the target actor.
    #[test]
    fn consume_locality() {
        let mut ebs = EpochBudgetState::empty();
        assert!(ebs.consume_in_place(10, 1, 5, 2));
        // actor 10 dropped to 3; actor 20 untouched (still floors to 5).
        assert_eq!(ebs.current_budget(10, 1, 5), 3);
        assert_eq!(ebs.current_budget(20, 1, 5), 5);
    }

    /// `consume` fails (no mutation) when the balance is insufficient.
    #[test]
    fn consume_insufficient_no_mutation() {
        let mut ebs = EpochBudgetState::empty();
        // now=0: empty cell has 0 budget, cost 1 fails.
        assert!(!ebs.consume_in_place(10, 0, 0, 1));
        assert!(ebs.is_empty());
    }

    // ============ Decoder ============

    /// Transfer decodes to `Ordinary` and recovers the signer.
    #[test]
    fn decode_transfer_ordinary() {
        let action = cat(&[u(0), u(1), u(10), u(20), u(100)]); // tag, r, sender, receiver, amount
        let sa = signed(&action, 42);
        let view = decode_budget_view(&sa).unwrap();
        assert_eq!(view.signer, 42);
        assert_eq!(view.kind, ActionBudgetKind::Ordinary);
    }

    /// Every modelled simple variant decodes to `Ordinary` with the
    /// signer recovered (exercises the per-tag field-skip layout).
    #[test]
    fn decode_simple_variants() {
        // (tag, action-bytes-after-tag)
        let cases: Vec<(u64, Vec<u8>)> = vec![
            (1, cat(&[u(1), u(2), u(3)])),                      // mint
            (2, cat(&[u(1), u(2), u(3)])),                      // burn
            (3, cat(&[u(1)])),                                  // freezeResource
            (4, cat(&[u(7), bytes(&[0x02; 33])])),              // replaceKey
            (5, cat(&[u(1), u(2), u(3)])),                      // reward
            (6, cat(&[u(1), u(2), u(3)])),                      // distributeOthers
            (7, cat(&[u(1), u(2), u(3)])),                      // proportionalDilute
            (9, cat(&[u(4)])),                                  // disputeWithdraw
            (11, cat(&[u(8)])),                                 // rollback
            (12, cat(&[u(7), bytes(&[0x02; 33])])),             // registerIdentity
            (13, cat(&[u(1), u(2), u(3), u(4)])),               // deposit
            (14, cat(&[u(1), u(2), u(3), bytes(&[0x11; 20])])), // withdraw
            (16, vec![]),                                       // revokeLocalPolicy
            (
                17,
                cat(&[bytes(&[0xAA; 32]), u(1), u(2), bytes(&[0xBB; 32])]),
            ), // faultProofChallenge
            (18, cat(&[bytes(&[0xCC; 32]), u(1), u(2), u(3)])), // faultProofResolution
        ];
        for (tag, fields) in cases {
            let action = cat(&[u(tag), fields]);
            let sa = signed(&action, 99);
            let view = decode_budget_view(&sa)
                .unwrap_or_else(|e| panic!("tag {tag} failed to decode: {e:?}"));
            assert_eq!(view.signer, 99, "tag {tag} signer");
            assert_eq!(view.kind, ActionBudgetKind::Ordinary, "tag {tag} kind");
        }
    }

    /// `depositWithFee` decodes to the recipient + budget grant.
    #[test]
    fn decode_deposit_with_fee() {
        // tag 19: r, recipient, poolActor, userAmount, poolAmount, budgetGrant, depositId
        let action = cat(&[u(19), u(0), u(10), u(1), u(1000), u(500), u(50), u(7)]);
        let sa = signed(&action, BRIDGE_ACTOR);
        let view = decode_budget_view(&sa).unwrap();
        assert_eq!(view.signer, BRIDGE_ACTOR);
        assert_eq!(
            view.kind,
            ActionBudgetKind::DepositWithFee {
                recipient: 10,
                budget_grant: 50
            }
        );
    }

    /// `topUpActionBudget` decodes to its pool/gas/increment fields.
    #[test]
    fn decode_top_up_action_budget() {
        // tag 20: gasResource, gasAmount, budgetIncrement, poolActor
        let action = cat(&[u(20), u(0), u(100), u(25), u(1)]);
        let sa = signed(&action, 10);
        let view = decode_budget_view(&sa).unwrap();
        assert_eq!(view.signer, 10);
        assert_eq!(
            view.kind,
            ActionBudgetKind::TopUpActionBudget {
                gas_resource: 0,
                pool_actor: 1,
                gas_amount: 100,
                budget_increment: 25
            }
        );
    }

    /// `topUpActionBudgetFor` decodes to its recipient/pool/gas/increment.
    #[test]
    fn decode_top_up_action_budget_for() {
        // tag 21: recipient, gasResource, gasAmount, budgetIncrement, poolActor
        let action = cat(&[u(21), u(7), u(0), u(100), u(25), u(1)]);
        let sa = signed(&action, 10);
        let view = decode_budget_view(&sa).unwrap();
        assert_eq!(view.signer, 10);
        assert_eq!(
            view.kind,
            ActionBudgetKind::TopUpActionBudgetFor {
                recipient: 7,
                gas_resource: 0,
                pool_actor: 1,
                gas_amount: 100,
                budget_increment: 25
            }
        );
    }

    /// The nested-encoding variants (8/10/15) report
    /// `UnsupportedActionTag`.
    #[test]
    fn decode_unsupported_tags() {
        for tag in [8u64, 10, 15] {
            let action = cat(&[u(tag)]);
            let sa = signed(&action, 5);
            match decode_budget_view(&sa) {
                Err(BudgetDecodeError::UnsupportedActionTag { tag: t }) => assert_eq!(t, tag),
                other => panic!("tag {tag}: expected UnsupportedActionTag, got {other:?}"),
            }
        }
    }

    /// An out-of-range constructor tag reports `UnknownActionTag`.
    /// Tag 23 is the first unknown tag (GP.9.1 added 22 =
    /// claimBudgetRefund; 23 is the reserved future GP.11 `ammSwap`).
    #[test]
    fn decode_unknown_tag() {
        let action = cat(&[u(23)]);
        let sa = signed(&action, 5);
        match decode_budget_view(&sa) {
            Err(BudgetDecodeError::UnknownActionTag { tag }) => assert_eq!(tag, 23),
            other => panic!("expected UnknownActionTag, got {other:?}"),
        }
    }

    /// A truncated stream (action present, signer missing) reports
    /// `UnexpectedEnd` rather than panicking.
    #[test]
    fn decode_truncated_no_signer() {
        let action = cat(&[u(3), u(1)]); // freezeResource, no signer
        match decode_budget_view(&action) {
            Err(BudgetDecodeError::UnexpectedEnd) => {}
            other => panic!("expected UnexpectedEnd, got {other:?}"),
        }
    }

    /// A SignedAction missing its `nonce` / `sig` tail (only
    /// `action ++ signer`) is rejected: the budget decoder requires a
    /// COMPLETE SignedAction, so a truncated request can't slip past
    /// the gate and mutate the ledger.
    #[test]
    fn decode_rejects_missing_nonce_sig() {
        // transfer action + signer, but no nonce / sig.
        let mut buf = cat(&[u(0), u(1), u(10), u(20), u(100)]);
        buf.extend_from_slice(&u(42)); // signer only
        match decode_budget_view(&buf) {
            Err(BudgetDecodeError::UnexpectedEnd) => {}
            other => panic!("expected UnexpectedEnd, got {other:?}"),
        }
        // action + signer + nonce, but no sig, is also incomplete.
        let mut buf2 = cat(&[u(0), u(1), u(10), u(20), u(100)]);
        buf2.extend_from_slice(&u(42)); // signer
        buf2.extend_from_slice(&u(0)); // nonce; sig still missing
        match decode_budget_view(&buf2) {
            Err(BudgetDecodeError::UnexpectedEnd) => {}
            other => panic!("expected UnexpectedEnd (no sig), got {other:?}"),
        }
    }

    /// Trailing bytes after a complete SignedAction are rejected, so the
    /// entire request buffer is accounted for (no silently-ignored
    /// suffix a peer could use to smuggle data past the gate).
    #[test]
    fn decode_view_rejects_trailing_after_sig() {
        let action = cat(&[u(0), u(1), u(10), u(20), u(100)]);
        let mut sa = signed(&action, 42);
        sa.extend_from_slice(&u(7)); // garbage past the signature
        match decode_budget_view(&sa) {
            Err(BudgetDecodeError::TrailingBytes { .. }) => {}
            other => panic!("expected TrailingBytes, got {other:?}"),
        }
    }

    /// A wrong type tag where a uint is expected reports `ExpectedUint`.
    #[test]
    fn decode_wrong_tag() {
        // Start with a byte-string head where the action tag (a uint)
        // is expected.
        let mut sa = bytes(&[0x01, 0x02]);
        sa.extend_from_slice(&u(5));
        match decode_budget_view(&sa) {
            Err(BudgetDecodeError::ExpectedUint { offset: 0, found }) => {
                assert_eq!(found, super::CBE_TAG_BYTES);
            }
            other => panic!("expected ExpectedUint, got {other:?}"),
        }
    }

    /// The decoder never panics on arbitrary bytes (fuzz-style sweep).
    #[test]
    fn decode_never_panics() {
        for len in 0usize..40 {
            for seed in 0u8..16 {
                let buf: Vec<u8> = (0..len).map(|i| seed.wrapping_add(i as u8)).collect();
                let _ = decode_budget_view(&buf); // must not panic
            }
        }
    }

    // ============ BudgetGate ============

    /// A view constructor shortcut for gate tests.
    fn view(signer: u64, kind: ActionBudgetKind) -> SignedActionBudgetView {
        SignedActionBudgetView { signer, kind }
    }

    /// Under `.bounded 1 1 1` the first ordinary action by a fresh
    /// actor succeeds, then the second is `InsufficientBudget`.
    /// Mirrors the Lean `budgetGateFirstActionSucceeds` /
    /// `budgetGateExhaustionRejects` production-path tests.
    #[test]
    fn gate_consume_then_exhaust() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1));
        assert_eq!(gate.current_budget(10), 1);
        assert!(gate.admit(&view(10, ActionBudgetKind::Ordinary)).is_ok());
        assert_eq!(gate.current_budget(10), 0);
        assert_eq!(
            gate.admit(&view(10, ActionBudgetKind::Ordinary)),
            Err(GateRejection::InsufficientBudget)
        );
    }

    /// Genesis-default `.bounded 0 1 0` denies every ordinary action
    /// (freeTier 0 at epoch 0).  Mirrors the Lean
    /// `genesisDefaultDeniesAdmission` test.
    #[test]
    fn gate_genesis_default_denies() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(0, 1, 0));
        assert_eq!(
            gate.admit(&view(10, ActionBudgetKind::Ordinary)),
            Err(GateRejection::InsufficientBudget)
        );
    }

    /// The bridge actor is exempt from consumption (OQ-GP-6): it is
    /// admitted even under the deny-all genesis policy, and its
    /// budget is unchanged.
    #[test]
    fn gate_bridge_actor_exempt() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(0, 1, 0));
        assert!(gate
            .admit(&view(BRIDGE_ACTOR, ActionBudgetKind::Ordinary))
            .is_ok());
        // No cell created for the bridge actor.
        assert!(gate.ledger().cell(BRIDGE_ACTOR).is_none());
    }

    /// Consuming actor A's budget leaves actor B's untouched.
    /// Mirrors `budgetGateOtherActorUnaffected`.
    #[test]
    fn gate_per_actor_isolation() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1));
        assert!(gate.admit(&view(10, ActionBudgetKind::Ordinary)).is_ok());
        assert_eq!(gate.current_budget(10), 0);
        assert_eq!(gate.current_budget(20), 1); // B still floored at free tier
        assert!(gate.admit(&view(20, ActionBudgetKind::Ordinary)).is_ok());
    }

    /// `topUpActionBudget` consumes one unit then credits the signer
    /// by `budget_increment`.
    #[test]
    fn gate_top_up_grants_signer() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1));
        let v = view(
            10,
            ActionBudgetKind::TopUpActionBudget {
                gas_resource: 0,
                pool_actor: 2,
                gas_amount: 5,
                budget_increment: 100,
            },
        );
        assert!(gate.admit(&v).is_ok());
        // 1 (free tier) - 1 (consume) + 100 (grant) = 100.
        assert_eq!(gate.current_budget(10), 100);
    }

    /// GP.9.1: a `claimBudgetRefund` consumes `action_cost +
    /// budget_units` (the per-action cost PLUS the retired purchased
    /// budget) and grants nothing.
    #[test]
    fn gate_refund_consumes_action_cost_plus_units() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(100, 1, 1));
        let v = view(
            10,
            ActionBudgetKind::ClaimBudgetRefund {
                gas_resource: 0,
                pool_actor: 2,
                budget_units: 10,
                wei_per_budget_unit: 5,
            },
        );
        assert!(gate.admit(&v).is_ok());
        // 100 (free tier) - 1 (action cost) - 10 (retired units) = 89.
        assert_eq!(gate.current_budget(10), 89);
    }

    /// GP.9.1: the refund's policy/balance-INDEPENDENT rejection
    /// conjuncts (signer ≠ bridge / pool, positive rate + units).
    #[test]
    fn gate_refund_rejections() {
        let mk = || BudgetGate::new(BudgetPolicy::mk_bounded(100, 1, 1));
        let refund = |signer, pool_actor, budget_units, wei| {
            view(
                signer,
                ActionBudgetKind::ClaimBudgetRefund {
                    gas_resource: 0,
                    pool_actor,
                    budget_units,
                    wei_per_budget_unit: wei,
                },
            )
        };
        assert_eq!(
            mk().admit(&refund(BRIDGE_ACTOR, 2, 10, 5)),
            Err(GateRejection::RefundByBridgeActor)
        );
        assert_eq!(
            mk().admit(&refund(2, 2, 10, 5)),
            Err(GateRejection::RefundToSelfPool)
        );
        assert_eq!(
            mk().admit(&refund(10, 2, 10, 0)),
            Err(GateRejection::RefundRateDisabled)
        );
        assert_eq!(
            mk().admit(&refund(10, 2, 0, 5)),
            Err(GateRejection::RefundZeroUnits)
        );
        // Non-canonical gas resource (2) rejected even with a positive
        // rate + units (the canonical-resource pin, review fix).
        assert_eq!(
            mk().admit(&view(
                10,
                ActionBudgetKind::ClaimBudgetRefund {
                    gas_resource: 2,
                    pool_actor: 99,
                    budget_units: 10,
                    wei_per_budget_unit: 5,
                },
            )),
            Err(GateRejection::RefundNonCanonicalResource)
        );
    }

    /// GP.9.1 STRICT MODE: pool solvency is enforced when a balance
    /// oracle is supplied (otherwise deferred to the Lean kernel).
    /// refundAmount = 10 × 5 = 50; the boundary (pool == 50) admits.
    #[test]
    fn strict_gate_refund_enforces_pool_solvency() {
        let v = view(
            10,
            ActionBudgetKind::ClaimBudgetRefund {
                gas_resource: 0,
                pool_actor: 2,
                budget_units: 10,
                wei_per_budget_unit: 5,
            },
        );
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(100, 1, 1)).with_strict_checks();
        gate.set_balance(0, 2, 40); // pool 40 < 50 => reject
        assert_eq!(
            gate.evaluate(&v),
            Err(GateRejection::RefundInsufficientPool)
        );
        gate.set_balance(0, 2, 50); // pool exactly 50 => admitted
        assert!(gate.admit(&v).is_ok());
        assert_eq!(gate.current_budget(10), 89);
    }

    /// `depositWithFee` (bridge-signed) grants the recipient without
    /// consuming the bridge actor's budget.
    #[test]
    fn gate_deposit_with_fee_grants_recipient() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(0, 1, 0));
        let v = view(
            BRIDGE_ACTOR,
            ActionBudgetKind::DepositWithFee {
                recipient: 10,
                budget_grant: 50,
            },
        );
        assert!(gate.admit(&v).is_ok());
        assert_eq!(gate.current_budget(10), 50);
    }

    /// `topUpActionBudgetFor` consumes the signer and credits the
    /// recipient.
    #[test]
    fn gate_delegated_top_up_grants_recipient() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1));
        let v = view(
            10,
            ActionBudgetKind::TopUpActionBudgetFor {
                recipient: 7,
                gas_resource: 0,
                pool_actor: 2,
                gas_amount: 5,
                budget_increment: 100,
            },
        );
        assert!(gate.admit(&v).is_ok());
        assert_eq!(gate.current_budget(10), 0); // signer consumed
                                                // recipient credited: floor(1) + 100 = 101.
        assert_eq!(gate.current_budget(7), 101);
    }

    /// Each balance/policy-independent safety conjunct rejects.
    #[test]
    fn gate_safety_conjuncts() {
        let policy = BudgetPolicy::mk_bounded(10, 1, 1);

        // bridge actor signing a topUp.
        let mut g = BudgetGate::new(policy);
        assert_eq!(
            g.admit(&view(
                BRIDGE_ACTOR,
                ActionBudgetKind::TopUpActionBudget {
                    gas_resource: 0,
                    pool_actor: 2,
                    gas_amount: 5,
                    budget_increment: 1
                }
            )),
            Err(GateRejection::BridgeActorTopUp)
        );

        // self-pool topUp.
        let mut g = BudgetGate::new(policy);
        assert_eq!(
            g.admit(&view(
                10,
                ActionBudgetKind::TopUpActionBudget {
                    gas_resource: 0,
                    pool_actor: 10,
                    gas_amount: 5,
                    budget_increment: 1
                }
            )),
            Err(GateRejection::SelfPoolTopUp)
        );

        // zero-gas topUp.
        let mut g = BudgetGate::new(policy);
        assert_eq!(
            g.admit(&view(
                10,
                ActionBudgetKind::TopUpActionBudget {
                    gas_resource: 0,
                    pool_actor: 2,
                    gas_amount: 0,
                    budget_increment: 1
                }
            )),
            Err(GateRejection::ZeroGasTopUp)
        );

        // self-recipient delegated topUp.
        let mut g = BudgetGate::new(policy);
        assert_eq!(
            g.admit(&view(
                10,
                ActionBudgetKind::TopUpActionBudgetFor {
                    recipient: 10,
                    gas_resource: 0,
                    pool_actor: 2,
                    gas_amount: 5,
                    budget_increment: 1
                }
            )),
            Err(GateRejection::SelfRecipientDelegatedTopUp)
        );

        // non-bridge depositWithFee.
        let mut g = BudgetGate::new(policy);
        assert_eq!(
            g.admit(&view(
                10,
                ActionBudgetKind::DepositWithFee {
                    recipient: 10,
                    budget_grant: 1
                }
            )),
            Err(GateRejection::NonBridgeDepositWithFee)
        );
    }

    /// `evaluate` is pure: a rejected action leaves the ledger
    /// untouched, and a rejected insufficient-budget action does not
    /// consume.
    #[test]
    fn gate_reject_does_not_mutate() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(0, 1, 0));
        let before = gate.ledger().clone();
        // Ordinary action under deny-all: rejected, no mutation.
        assert!(gate.admit(&view(10, ActionBudgetKind::Ordinary)).is_err());
        assert_eq!(gate.ledger(), &before);
        // Self-pool topUp: rejected before any consume.
        assert!(gate
            .admit(&view(
                10,
                ActionBudgetKind::TopUpActionBudget {
                    gas_resource: 0,
                    pool_actor: 10,
                    gas_amount: 5,
                    budget_increment: 1
                }
            ))
            .is_err());
        assert_eq!(gate.ledger(), &before);
    }

    /// Reason strings are wire-stable; `InsufficientBudget` matches
    /// the OQ-GP-3 contract exactly.
    #[test]
    fn rejection_reason_strings() {
        assert_eq!(
            GateRejection::InsufficientBudget.reason(),
            "InsufficientBudget"
        );
        assert_eq!(
            GateRejection::BridgeActorTopUp.reason(),
            "BudgetGateBridgeActorTopUp"
        );
        assert_eq!(
            GateRejection::SelfPoolTopUp.reason(),
            "BudgetGateSelfPoolTopUp"
        );
        assert_eq!(
            GateRejection::ZeroGasTopUp.reason(),
            "BudgetGateZeroGasTopUp"
        );
        assert_eq!(
            GateRejection::SelfRecipientDelegatedTopUp.reason(),
            "BudgetGateSelfRecipientDelegatedTopUp"
        );
        assert_eq!(
            GateRejection::NonBridgeDepositWithFee.reason(),
            "BudgetGateNonBridgeDepositWithFee"
        );
        assert_eq!(
            GateRejection::InsufficientGas.reason(),
            "BudgetGateInsufficientGas"
        );
        assert_eq!(
            GateRejection::DelegationNotAuthorized.reason(),
            "BudgetGateDelegationNotAuthorized"
        );
    }

    // ---- Strict mode: full-fidelity gate (audit gap #4) ----

    /// By default the gate is permissive: a top-up with no recorded
    /// balance is still admitted (the gas-balance conjunct is deferred
    /// to the Lean kernel).
    #[test]
    fn permissive_gate_admits_topup_without_balance() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1));
        assert!(!gate.is_strict());
        let v = view(
            10,
            ActionBudgetKind::TopUpActionBudget {
                gas_resource: 0,
                pool_actor: 2,
                gas_amount: 5,
                budget_increment: 100,
            },
        );
        assert!(gate.admit(&v).is_ok());
    }

    /// Strict mode rejects a top-up whose signer has insufficient gas
    /// balance (the Lean `getBalance >= gasAmount` conjunct), and
    /// admits it once the balance is pre-funded.
    #[test]
    fn strict_gate_enforces_gas_balance() {
        let v = view(
            10,
            ActionBudgetKind::TopUpActionBudget {
                gas_resource: 0,
                pool_actor: 2,
                gas_amount: 5,
                budget_increment: 100,
            },
        );
        // No balance recorded -> InsufficientGas.
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1)).with_strict_checks();
        assert!(gate.is_strict());
        assert_eq!(gate.evaluate(&v), Err(GateRejection::InsufficientGas));
        // Insufficient balance (4 < 5) -> still rejected.
        gate.set_balance(0, 10, 4);
        assert_eq!(gate.evaluate(&v), Err(GateRejection::InsufficientGas));
        // Sufficient balance -> admitted + grant applied.
        gate.set_balance(0, 10, 5);
        assert!(gate.admit(&v).is_ok());
        assert_eq!(gate.current_budget(10), 100);
    }

    /// The gas-balance check is keyed by the gas RESOURCE: funding a
    /// different resource does not satisfy the conjunct.
    #[test]
    fn strict_gate_gas_balance_is_resource_keyed() {
        let v = view(
            10,
            ActionBudgetKind::TopUpActionBudget {
                gas_resource: 1, // BOLD
                pool_actor: 2,
                gas_amount: 5,
                budget_increment: 100,
            },
        );
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1)).with_strict_checks();
        gate.set_balance(0, 10, 1000); // funds resource 0, not 1
        assert_eq!(gate.evaluate(&v), Err(GateRejection::InsufficientGas));
        gate.set_balance(1, 10, 5); // now fund resource 1
        assert!(gate.admit(&v).is_ok());
    }

    /// Strict mode rejects a delegated top-up the recipient never
    /// authorised (the Lean `delegatedTopUpConsentBool` conjunct),
    /// and admits it once consent + balance are present.
    #[test]
    fn strict_gate_enforces_delegated_consent() {
        let v = view(
            10,
            ActionBudgetKind::TopUpActionBudgetFor {
                recipient: 7,
                gas_resource: 0,
                pool_actor: 2,
                gas_amount: 5,
                budget_increment: 100,
            },
        );
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1)).with_strict_checks();
        gate.set_balance(0, 10, 5); // gas covered, but no consent yet
        assert_eq!(
            gate.evaluate(&v),
            Err(GateRejection::DelegationNotAuthorized)
        );
        // Consent for a DIFFERENT signer doesn't help.
        gate.allow_delegate(7, 99);
        assert_eq!(
            gate.evaluate(&v),
            Err(GateRejection::DelegationNotAuthorized)
        );
        // Correct consent -> admitted; recipient credited.
        gate.allow_delegate(7, 10);
        assert!(gate.admit(&v).is_ok());
        assert_eq!(gate.current_budget(7), 101); // floor(1) + 100
    }

    /// Strict mode still enforces the balance-independent conjuncts
    /// (a zero-gas top-up is rejected before the balance check).
    #[test]
    fn strict_gate_keeps_balance_independent_conjuncts() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1)).with_strict_checks();
        gate.set_balance(0, 10, 1000);
        let v = view(
            10,
            ActionBudgetKind::TopUpActionBudget {
                gas_resource: 0,
                pool_actor: 2,
                gas_amount: 0, // zero gas
                budget_increment: 100,
            },
        );
        assert_eq!(gate.evaluate(&v), Err(GateRejection::ZeroGasTopUp));
    }

    /// End-to-end: decode real CBE bytes then drive the gate.
    #[test]
    fn gate_drives_decoded_view() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(2, 1, 1));
        let action = cat(&[u(0), u(1), u(10), u(20), u(100)]); // transfer
        let sa = signed(&action, 10);
        let v = decode_budget_view(&sa).unwrap();
        assert!(gate.admit(&v).is_ok());
        assert!(gate.admit(&v).is_ok());
        assert_eq!(gate.admit(&v), Err(GateRejection::InsufficientBudget));
    }

    /// `with_ledger` pre-seeds the gate's ledger.
    #[test]
    fn gate_with_ledger_preseeds() {
        let mut ledger = EpochBudgetState::empty();
        ledger.top_up_in_place(10, 1, 0, 5);
        let gate = BudgetGate::with_ledger(BudgetPolicy::mk_bounded(0, 1, 1), ledger);
        assert_eq!(gate.current_budget(10), 5);
    }

    /// `BudgetGate` / `EpochBudgetState` / `ActorBudget` are
    /// `Send + Sync` (the gate lives behind the MockKernel's mutex).
    #[test]
    fn types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<BudgetGate>();
        assert_send_sync::<EpochBudgetState>();
        assert_send_sync::<ActorBudget>();
        assert_send_sync::<BudgetPolicy>();
    }

    // ---- Audit hardening: multi-byte LE + multi-key ordering ----

    /// Encoders use full 8-byte little-endian heads, not just the low
    /// byte.  Pinned against an EXPLICIT hand-computed LE byte literal
    /// (ground truth, not the `to_le_bytes`-based `u()` helper) for
    /// the same value the Lean `actorBudgetEncodeMultibyteKnownVector`
    /// test pins — a true multi-byte cross-stack equivalence.
    #[test]
    fn actor_budget_encode_multibyte_le() {
        let b = ActorBudget {
            last_seen_epoch: 0x0102_0304_0506_0708,
            budget_balance: 0x1122_3344_5566_7788,
        };
        let expected: Vec<u8> = vec![
            // lastSeenEpoch 0x0102030405060708 (LE)
            0x00, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
            // budgetBalance 0x1122334455667788 (LE)
            0x00, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        ];
        assert_eq!(b.encode(), expected);
        // u64::MAX field is all-0xff (full-width sanity).
        let max_cell = ActorBudget {
            last_seen_epoch: 0,
            budget_balance: u64::MAX,
        };
        assert_eq!(&max_cell.encode()[10..18], &[0xffu8; 8]);
    }

    /// `BudgetPolicy.encode` carries multi-byte field values in full
    /// 8-byte LE (constructor tag 0 then the three fields).
    #[test]
    fn budget_policy_encode_multibyte_le() {
        let p = BudgetPolicy::mk_bounded(1_000_000, 5, 4_294_967_296); // 2^32
        let expected = cat(&[u(0), u(1_000_000), u(5), u(4_294_967_296)]);
        assert_eq!(p.encode(), expected);
    }

    /// The map encoding emits entries in ascending actor-id order
    /// regardless of insertion order, with multi-byte keys encoded in
    /// full LE.  Keys `1`, `256`, `70_000` (1-, 2-, and 3-byte)
    /// exercise the LE key head; insertion is deliberately
    /// descending.
    #[test]
    fn epoch_budget_state_encode_multikey_ascending() {
        let mut ebs = EpochBudgetState::empty();
        // Insert descending so the ascending output is non-trivial.
        for &(k, e, v) in &[(70_000u64, 9u64, 9u64), (256, 2, 7), (1, 1, 5)] {
            ebs.0.insert(
                k,
                ActorBudget {
                    last_seen_epoch: e,
                    budget_balance: v,
                },
            );
        }
        let expected = cat(&[
            vec![CBE_TAG_MAP],
            3u64.to_le_bytes().to_vec(),
            // ascending: 1, 256, 70_000
            u(1),
            u(1),
            u(5),
            u(256),
            u(2),
            u(7),
            u(70_000),
            u(9),
            u(9),
        ]);
        assert_eq!(ebs.encode(), expected);
        // The 256 key's LE head must be [0x00, 0x00, 0x01, 0, ...].
        let key256_head = u(256);
        assert_eq!(key256_head[1], 0x00);
        assert_eq!(key256_head[2], 0x01);
    }

    /// The ledger orders actor ids UNSIGNED-ascending (BTreeMap<u64>
    /// guarantee), matching Lean's `compare` on `UInt64`.  The
    /// `2^63` boundary distinguishes unsigned from signed ordering:
    /// under unsigned, `1 < 2^63`; under signed, `2^63` is negative
    /// and would sort first.  Paired with the Lean
    /// `epochBudgetsLargeKeyOrdering` test, this pins the cross-stack
    /// map-ordering contract for the full `u64` range.
    #[test]
    fn epoch_budget_state_orders_keys_unsigned() {
        let mut ebs = EpochBudgetState::empty();
        ebs.0.insert(1u64 << 63, ActorBudget::empty());
        ebs.0.insert(1, ActorBudget::empty());
        let keys: Vec<u64> = ebs.0.keys().copied().collect();
        assert_eq!(keys, vec![1, 1u64 << 63]);
        // The encoded key heads appear in the same unsigned order.
        let enc = ebs.encode();
        // map head (9) + key1 head starts at 9; first key low byte == 1.
        assert_eq!(enc[9], CBE_TAG_UINT);
        assert_eq!(enc[10], 0x01);
    }

    /// The decoder recovers a full-width (multi-byte) signer value,
    /// confirming `read_uint` consumes all 8 LE bytes.
    #[test]
    fn decode_recovers_large_signer() {
        let action = cat(&[u(3), u(1)]); // freezeResource
        let sa = signed(&action, 0x00FF_EE00_1234_5678);
        let view = decode_budget_view(&sa).unwrap();
        assert_eq!(view.signer, 0x00FF_EE00_1234_5678);
        assert_eq!(view.kind, ActionBudgetKind::Ordinary);
    }

    /// Realistic multi-actor trace: interleaved consume / grant /
    /// per-actor isolation evolves the ledger exactly as the Lean
    /// gate would.  Under `.bounded 2 1 1`: each fresh actor floors
    /// to 2, ordinary actions consume 1, a self top-up nets
    /// `+increment - 1`, and a bridge-signed deposit grants the
    /// recipient without consuming.
    #[test]
    fn gate_multi_actor_trace() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(2, 1, 1));
        // actor 10: two ordinary actions -> budget 2 -> 1 -> 0.
        assert!(gate.admit(&view(10, ActionBudgetKind::Ordinary)).is_ok());
        assert!(gate.admit(&view(10, ActionBudgetKind::Ordinary)).is_ok());
        assert_eq!(gate.current_budget(10), 0);
        // third ordinary by 10 -> exhausted.
        assert_eq!(
            gate.admit(&view(10, ActionBudgetKind::Ordinary)),
            Err(GateRejection::InsufficientBudget)
        );
        // actor 20 is untouched (still floors to 2) and can top itself
        // up: consume 1 (2 -> 1) then +50 grant -> 51.
        assert_eq!(gate.current_budget(20), 2);
        assert!(gate
            .admit(&view(
                20,
                ActionBudgetKind::TopUpActionBudget {
                    gas_resource: 0,
                    pool_actor: 9,
                    gas_amount: 5,
                    budget_increment: 50,
                },
            ))
            .is_ok());
        assert_eq!(gate.current_budget(20), 51);
        // bridge-signed deposit grants actor 30 by 7 without consuming
        // the bridge's (non-existent) budget.
        assert!(gate
            .admit(&view(
                BRIDGE_ACTOR,
                ActionBudgetKind::DepositWithFee {
                    recipient: 30,
                    budget_grant: 7,
                },
            ))
            .is_ok());
        // actor 30: floor 2 + grant 7 = 9.
        assert_eq!(gate.current_budget(30), 9);
        // actor 10 remains exhausted; the bridge has no cell.
        assert_eq!(gate.current_budget(10), 0);
        assert!(gate.ledger().cell(BRIDGE_ACTOR).is_none());
    }

    // ---- GP.6.2 epoch advancement (mirrors the Lean runtime) ----

    /// With `epoch_length = 1` every admitted action lands in a fresh
    /// epoch, so a single actor's free tier is replenished each
    /// action — whereas the fixed-epoch default exhausts after one.
    #[test]
    fn gate_epoch_advancement_replenishes() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1)).with_epoch_length(1);
        assert_eq!(gate.effective_epoch(), 1); // base epoch, 0 admitted
        for i in 0..5u64 {
            assert!(
                gate.admit(&view(10, ActionBudgetKind::Ordinary)).is_ok(),
                "action {i} under epoch_length 1 should replenish"
            );
            assert_eq!(gate.effective_epoch(), 1 + i + 1);
        }
        // Contrast: the fixed-epoch default exhausts after one action.
        let mut fixed = BudgetGate::new(BudgetPolicy::mk_bounded(1, 1, 1));
        assert!(fixed.admit(&view(10, ActionBudgetKind::Ordinary)).is_ok());
        assert_eq!(
            fixed.admit(&view(10, ActionBudgetKind::Ordinary)),
            Err(GateRejection::InsufficientBudget)
        );
    }

    /// With `free_tier = 2` and `epoch_length = 2`, an actor gets two
    /// actions per epoch and the epoch advances every two admitted
    /// actions, so it keeps pace indefinitely.
    #[test]
    fn gate_epoch_advancement_boundary_paces_free_tier() {
        let mut gate = BudgetGate::new(BudgetPolicy::mk_bounded(2, 1, 1)).with_epoch_length(2);
        for i in 0..6u64 {
            assert!(
                gate.admit(&view(7, ActionBudgetKind::Ordinary)).is_ok(),
                "action {i} should be admitted (free tier paces epoch length)"
            );
        }
        // effective epoch advanced 6/2 = 3 times from base 1.
        assert_eq!(gate.effective_epoch(), 1 + 3);
    }

    // ---- Audit hardening: bidirectional codec round-trips ----

    /// `ActorBudget` encode → decode round-trips, including
    /// multi-byte + max-value fields.
    #[test]
    fn actor_budget_round_trip() {
        for b in [
            ActorBudget::empty(),
            ActorBudget {
                last_seen_epoch: 1,
                budget_balance: 2,
            },
            ActorBudget {
                last_seen_epoch: 0x0102_0304_0506_0708,
                budget_balance: u64::MAX,
            },
        ] {
            assert_eq!(ActorBudget::decode(&b.encode()), Ok(b));
        }
    }

    /// `BudgetPolicy` encode → decode round-trips.
    #[test]
    fn budget_policy_round_trip() {
        for p in [
            BudgetPolicy::mk_bounded(0, 1, 0),
            BudgetPolicy::mk_bounded(10, 5, 3),
            BudgetPolicy::mk_bounded(u64::MAX, u64::MAX, u64::MAX),
        ] {
            assert_eq!(BudgetPolicy::decode(&p.encode()), Ok(p));
        }
    }

    /// `EpochBudgetState` encode → decode round-trips (empty +
    /// multi-key incl. a key past `2^63`).
    #[test]
    fn epoch_budget_state_round_trip() {
        let empty = EpochBudgetState::empty();
        assert_eq!(EpochBudgetState::decode(&empty.encode()), Ok(empty));
        let mut ebs = EpochBudgetState::empty();
        ebs.0.insert(
            1,
            ActorBudget {
                last_seen_epoch: 1,
                budget_balance: 5,
            },
        );
        ebs.0.insert(
            256,
            ActorBudget {
                last_seen_epoch: 2,
                budget_balance: 7,
            },
        );
        ebs.0.insert(
            1u64 << 63,
            ActorBudget {
                last_seen_epoch: 9,
                budget_balance: 9,
            },
        );
        assert_eq!(EpochBudgetState::decode(&ebs.encode()), Ok(ebs));
    }

    /// Decode rejects a non-zero `BudgetPolicy` constructor tag.
    #[test]
    fn decode_rejects_bad_policy_tag() {
        let bytes = cat(&[u(1), u(0), u(1), u(0)]); // tag 1
        assert!(matches!(
            BudgetPolicy::decode(&bytes),
            Err(BudgetDecodeError::NonCanonical { .. })
        ));
    }

    /// Decode rejects `actionCost == 0` (the `mk_bounded` clamp can
    /// never produce it; a hand-crafted stream must be rejected).
    #[test]
    fn decode_rejects_zero_action_cost() {
        let bytes = cat(&[u(0), u(10), u(0), u(1)]); // tag 0, ft 10, ac 0, ce 1
        assert!(matches!(
            BudgetPolicy::decode(&bytes),
            Err(BudgetDecodeError::NonCanonical { .. })
        ));
    }

    /// Decode rejects non-strictly-ascending map keys (canonical-order
    /// requirement, matching Lean's `decodeMap`).
    #[test]
    fn decode_rejects_unsorted_keys() {
        let cell = cat(&[u(0), u(0)]);
        let bytes = cat(&[
            vec![CBE_TAG_MAP],
            2u64.to_le_bytes().to_vec(),
            u(5),
            cell.clone(),
            u(5),
            cell,
        ]);
        assert!(matches!(
            EpochBudgetState::decode(&bytes),
            Err(BudgetDecodeError::NonCanonical { .. })
        ));
    }

    /// Decode rejects trailing bytes after a complete value.
    #[test]
    fn decode_rejects_trailing_bytes() {
        let mut bytes = ActorBudget::empty().encode();
        bytes.push(0xFF);
        assert!(matches!(
            ActorBudget::decode(&bytes),
            Err(BudgetDecodeError::TrailingBytes { .. })
        ));
    }

    /// Decode surfaces a truncated stream as `UnexpectedEnd` (no panic).
    #[test]
    fn decode_truncated_is_unexpected_end() {
        assert_eq!(
            ActorBudget::decode(&[0x00, 0x01]),
            Err(BudgetDecodeError::UnexpectedEnd)
        );
    }

    /// A map head with the wrong tag is rejected as `ExpectedMap`.
    #[test]
    fn decode_rejects_non_map_head() {
        let bytes = cat(&[u(0)]); // a uint head where a map head is expected
        assert!(matches!(
            EpochBudgetState::decode(&bytes),
            Err(BudgetDecodeError::ExpectedMap { .. })
        ));
    }

    /// Build the CBE bytes a [`decode_budget_view`] would parse for a
    /// given signer + kind (test-only re-encoder enabling decoder
    /// round-trips).  Skipped fields are filled with arbitrary dummy
    /// values; only the budget-relevant fields are recovered.
    fn encode_view_bytes(signer: u64, kind: ActionBudgetKind) -> Vec<u8> {
        let action = match kind {
            ActionBudgetKind::Ordinary => cat(&[u(0), u(1), u(2), u(3), u(4)]), // transfer
            ActionBudgetKind::DepositWithFee {
                recipient,
                budget_grant,
            } => cat(&[
                u(19),
                u(7),
                u(recipient),
                u(8),
                u(9),
                u(10),
                u(budget_grant),
                u(11),
            ]),
            ActionBudgetKind::TopUpActionBudget {
                gas_resource,
                pool_actor,
                gas_amount,
                budget_increment,
            } => cat(&[
                u(20),
                u(gas_resource),
                u(gas_amount),
                u(budget_increment),
                u(pool_actor),
            ]),
            ActionBudgetKind::TopUpActionBudgetFor {
                recipient,
                gas_resource,
                pool_actor,
                gas_amount,
                budget_increment,
            } => cat(&[
                u(21),
                u(recipient),
                u(gas_resource),
                u(gas_amount),
                u(budget_increment),
                u(pool_actor),
            ]),
            ActionBudgetKind::ClaimBudgetRefund {
                gas_resource,
                pool_actor,
                budget_units,
                wei_per_budget_unit,
            } => cat(&[
                u(22),
                u(gas_resource),
                u(budget_units),
                u(wei_per_budget_unit),
                u(pool_actor),
            ]),
        };
        signed(&action, signer)
    }

    /// `decode_budget_view` round-trips the budget-relevant projection
    /// for every kind shape.
    #[test]
    fn decode_view_round_trip_unit() {
        let kinds = [
            ActionBudgetKind::Ordinary,
            ActionBudgetKind::DepositWithFee {
                recipient: 12,
                budget_grant: 34,
            },
            ActionBudgetKind::TopUpActionBudget {
                gas_resource: 3,
                pool_actor: 5,
                gas_amount: 6,
                budget_increment: 7,
            },
            ActionBudgetKind::TopUpActionBudgetFor {
                recipient: 8,
                gas_resource: 4,
                pool_actor: 9,
                gas_amount: 10,
                budget_increment: 11,
            },
            ActionBudgetKind::ClaimBudgetRefund {
                gas_resource: 0,
                pool_actor: 1,
                budget_units: 50,
                wei_per_budget_unit: 5,
            },
        ];
        for kind in kinds {
            let bytes = encode_view_bytes(42, kind);
            assert_eq!(
                decode_budget_view(&bytes),
                Ok(SignedActionBudgetView { signer: 42, kind })
            );
        }
    }

    /// Property-based coverage of the budget codec + decoder over
    /// random inputs (complements the deterministic known vectors).
    mod prop {
        use super::super::{
            decode_budget_view, ActionBudgetKind, ActorBudget, BudgetPolicy, EpochBudgetState,
            SignedActionBudgetView,
        };
        use super::encode_view_bytes;
        use proptest::prelude::*;

        proptest! {
            /// `ActorBudget` round-trips over arbitrary fields.
            #[test]
            fn actor_budget_round_trip(e in any::<u64>(), b in any::<u64>()) {
                let cell = ActorBudget { last_seen_epoch: e, budget_balance: b };
                prop_assert_eq!(ActorBudget::decode(&cell.encode()), Ok(cell));
            }

            /// `BudgetPolicy` round-trips (action_cost clamped >= 1).
            #[test]
            fn budget_policy_round_trip(ft in any::<u64>(), ac in any::<u64>(), ce in any::<u64>()) {
                let p = BudgetPolicy::mk_bounded(ft, ac, ce);
                prop_assert_eq!(BudgetPolicy::decode(&p.encode()), Ok(p));
            }

            /// `EpochBudgetState` round-trips over arbitrary key/cell sets.
            #[test]
            fn epoch_budget_state_round_trip(
                entries in prop::collection::vec(
                    (any::<u64>(), any::<u64>(), any::<u64>()), 0..8)
            ) {
                let mut ebs = EpochBudgetState::empty();
                for (k, e, b) in entries {
                    ebs.0.insert(k, ActorBudget { last_seen_epoch: e, budget_balance: b });
                }
                prop_assert_eq!(EpochBudgetState::decode(&ebs.encode()), Ok(ebs));
            }

            /// Encoding is deterministic over random inputs.
            #[test]
            fn encode_deterministic(e in any::<u64>(), b in any::<u64>()) {
                let cell = ActorBudget { last_seen_epoch: e, budget_balance: b };
                prop_assert_eq!(cell.encode(), cell.encode());
            }

            /// `decode_budget_view` round-trips ordinary actions for any signer.
            #[test]
            fn decode_view_ordinary(signer in any::<u64>()) {
                let bytes = encode_view_bytes(signer, ActionBudgetKind::Ordinary);
                prop_assert_eq!(
                    decode_budget_view(&bytes),
                    Ok(SignedActionBudgetView { signer, kind: ActionBudgetKind::Ordinary })
                );
            }

            /// `decode_budget_view` round-trips delegated top-ups for random fields.
            #[test]
            fn decode_view_topupfor(
                signer in any::<u64>(), r in any::<u64>(), gr in any::<u64>(),
                p in any::<u64>(), g in any::<u64>(), i in any::<u64>()
            ) {
                let kind = ActionBudgetKind::TopUpActionBudgetFor {
                    recipient: r, gas_resource: gr, pool_actor: p, gas_amount: g, budget_increment: i,
                };
                let bytes = encode_view_bytes(signer, kind);
                prop_assert_eq!(
                    decode_budget_view(&bytes),
                    Ok(SignedActionBudgetView { signer, kind })
                );
            }
        }
    }
}
