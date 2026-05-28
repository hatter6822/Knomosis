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
//! The [`BudgetGate`] enforces every *balance- and policy-independent*
//! conjunct of the Lean gate (the bridge-actor / self-pool /
//! zero-gas / self-recipient correlation guards, the per-action
//! consume, and the budget-grant arms) and DEFERS the two
//! state-dependent conjuncts to the authoritative Lean kernel reached
//! through [`crate::kernel::command::CommandKernel`].  The gate is
//! therefore a faithful but *strictly weaker* admission predicate: it
//! never admits an ordinary action the kernel would reject for budget
//! reasons, but it may admit a gas-funding action whose gas-balance /
//! consent precondition only the kernel can check.  This is the
//! correct posture for the test/dev `MockKernel`; production budget
//! enforcement is the Lean kernel's responsibility (see
//! `docs/planning/unified_gas_pool_plan.md` §GP.3.2 / §GP.6.2).
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
        /// The gas-pool actor credited the gas payment.
        pool_actor: u64,
        /// The gas amount transferred (must be `> 0`).
        gas_amount: u64,
        /// The budget units credited to `recipient`.
        budget_increment: u64,
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
            cur.skip_uint()?; // gasResource
            let gas_amount = cur.read_uint()?;
            let budget_increment = cur.read_uint()?;
            let pool_actor = cur.read_uint()?;
            ActionBudgetKind::TopUpActionBudget {
                pool_actor,
                gas_amount,
                budget_increment,
            }
        }
        // topUpActionBudgetFor(21): recipient, gasResource, gasAmount,
        // budgetIncrement, poolActor.
        21 => {
            let recipient = cur.read_uint()?;
            cur.skip_uint()?; // gasResource
            let gas_amount = cur.read_uint()?;
            let budget_increment = cur.read_uint()?;
            let pool_actor = cur.read_uint()?;
            ActionBudgetKind::TopUpActionBudgetFor {
                recipient,
                pool_actor,
                gas_amount,
                budget_increment,
            }
        }
        // dispute(8) / verdict(10) / declareLocalPolicy(15): nested
        // encodings not modelled here.
        8 | 10 | 15 => return Err(BudgetDecodeError::UnsupportedActionTag { tag }),
        other => return Err(BudgetDecodeError::UnknownActionTag { tag: other }),
    };
    let signer = cur.read_uint()?;
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
}

impl BudgetGate {
    /// Construct a gate with an empty ledger under `policy`.
    #[must_use]
    pub fn new(policy: BudgetPolicy) -> Self {
        Self {
            policy,
            ledger: EpochBudgetState::empty(),
        }
    }

    /// Construct a gate with a pre-seeded ledger (e.g. for tests that
    /// pre-fund specific actors).
    #[must_use]
    pub fn with_ledger(policy: BudgetPolicy, ledger: EpochBudgetState) -> Self {
        Self { policy, ledger }
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

    /// The actor's current budget under this gate's policy/epoch.
    #[must_use]
    pub fn current_budget(&self, actor: u64) -> u64 {
        self.ledger
            .current_budget(actor, self.policy.current_epoch(), self.policy.free_tier())
    }

    /// Evaluate the gate against `view`, returning the post-admission
    /// ledger on success or a [`GateRejection`] on refusal.  Pure:
    /// the gate's own ledger is not mutated (use [`BudgetGate::admit`]
    /// to commit).
    ///
    /// Mirrors the balance- and policy-independent conjuncts of the
    /// Lean gate; see the module-level scope boundary for the two
    /// state-dependent conjuncts that are deferred to the kernel.
    ///
    /// # Errors
    ///
    /// Returns the [`GateRejection`] describing the failed conjunct.
    pub fn evaluate(
        &self,
        view: &SignedActionBudgetView,
    ) -> Result<EpochBudgetState, GateRejection> {
        let now = self.policy.current_epoch();
        let free_tier = self.policy.free_tier();
        let action_cost = self.policy.action_cost();
        let signer = view.signer;

        // Signer-correlation safety gates (the balance/policy-
        // independent conjuncts of the Lean gate).
        match view.kind {
            ActionBudgetKind::TopUpActionBudget {
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
            }
            ActionBudgetKind::TopUpActionBudgetFor {
                recipient,
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
            }
            ActionBudgetKind::DepositWithFee { .. } => {
                if signer != BRIDGE_ACTOR {
                    return Err(GateRejection::NonBridgeDepositWithFee);
                }
            }
            ActionBudgetKind::Ordinary => {}
        }

        let mut ledger = self.ledger.clone();

        // Consume step: the bridge actor is exempt (OQ-GP-6); every
        // other signer is debited `action_cost`.
        if signer != BRIDGE_ACTOR && !ledger.consume_in_place(signer, now, free_tier, action_cost) {
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
            ActionBudgetKind::Ordinary => {}
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
    #[test]
    fn decode_unknown_tag() {
        let action = cat(&[u(22)]);
        let sa = signed(&action, 5);
        match decode_budget_view(&sa) {
            Err(BudgetDecodeError::UnknownActionTag { tag }) => assert_eq!(tag, 22),
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
                pool_actor: 2,
                gas_amount: 5,
                budget_increment: 100,
            },
        );
        assert!(gate.admit(&v).is_ok());
        // 1 (free tier) - 1 (consume) + 100 (grant) = 100.
        assert_eq!(gate.current_budget(10), 100);
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
}
