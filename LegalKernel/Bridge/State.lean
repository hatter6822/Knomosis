-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.State — Workstream C.1 (`docs/planning/ethereum_integration_plan.md` §7.1).

The bridge ledger that tracks the L1 ↔ L2 deposit / withdrawal flow.
A `BridgeState` carries:

  * `consumed`   — the set of L1 deposit-receipt hashes that have
                   been credited on L2, indexed by the canonical
                   numeric (BE-decoded) form of the receipt hash.
                   Each entry is a `DepositRecord` carrying the
                   `(resource, userAmount, poolAmount, budgetGrant)`
                   metadata required by the bridge accounting
                   theorems (§7.6 / §15E).
  * `pending`    — the set of withdrawal requests awaiting L1
                   redemption, indexed by an internal monotonically-
                   increasing `WithdrawalId`.  Each entry is a
                   `PendingWithdrawal` carrying the
                   `(resource, recipient, amount, l2LogIndex)` data.
  * `nextWdId`   — the next withdrawal id to assign on the next
                   `withdraw` action.

Design notes:

  * `DepositId : Type := Nat` (rather than the integration plan's
    sketch of `ByteArray`).  The runtime adaptor parses a 32-byte
    L1 deposit-receipt hash and converts it to its canonical big-
    endian numeric form at the bridge boundary; conversion is
    injective on fixed-length 32-byte inputs.  The Nat
    representation lets `consumed` be a `Std.TreeMap Nat _ compare`
    (using Lean core's lawful `compare` on `Nat`) without having to
    introduce a custom `ByteArray` comparator and re-prove the
    `TransCmp` / `LawfulEqCmp` laws for it.  Documented as a
    deviation from §7.1.1 in the integration plan.

  * `DepositRecord` is the audit-2 amendment to §7.1.1 (the original
    sketch tracked `consumed : TreeMap DepositId Unit`, but the
    bridge accounting theorem requires per-deposit metadata, so the
    value type is widened to a record).  The Workstream-GP widening
    (GP.4.1) further splits the single `amount` field into the
    `(userAmount, poolAmount, budgetGrant)` triple; the pre-widening
    two-field shape survives as `LegacyDepositRecord` with a lossless
    `DepositRecord.fromLegacy` lift.

  * `BridgeState` is a structural record; deployments construct
    `BridgeState.empty` at genesis and let the kernel-side machinery
    update it through `applyActionToBridgeState` (defined in
    `LegalKernel/Bridge/Admissible.lean` to keep this module
    Authority-layer-independent).

This module is **not** part of the kernel TCB.  Bugs here would
weaken the bridge's accounting guarantees but cannot violate any
kernel invariant.

Coverage map:

  * §7.1.1 (WU C.1.1) — `DepositId`, `WithdrawalId`,
    `DepositRecord`, `PendingWithdrawal`, `BridgeState`,
    `BridgeState.empty`, the four `empty_*_*` smoke-test
    theorems.
  * GP.4.1 — `DepositRecord` widened to
    `(resource, userAmount, poolAmount, budgetGrant)`;
    `LegacyDepositRecord` + `DepositRecord.fromLegacy` /
    `DepositRecord.toLegacy` + the `toLegacy_fromLegacy`
    round-trip lemma.
  * GP.11.8 — `BridgeState` extended with five AMM/BOLD
    state fields (`ammReserveEth`, `ammReserveBold`,
    `boldCircuitClosed`, `boldTvlCap`, `boldTotalLockedValue`)
    so the fault-proof game can adjudicate disputes that turn
    on AMM state.
  * GP.11.10 — `BridgeState` extended with the `ammDisabled`
    kill-switch mirror so the state-root preimage reflects the
    L1 `emergencyDisableAmm()` disaster-recovery state.  Per the
    GP.11.10 design decision there is NO `Action.disableAmm`
    variant: the flag is a passive L1 mirror (like the five
    GP.11.8 fields), populated by the deployment's ingest layer
    and committed by `commitBridgeState`.
-/

import LegalKernel.Kernel
import LegalKernel.RBMapLemmas
import LegalKernel.Bridge.AddressBook

open Std

namespace LegalKernel
namespace Bridge

/-! ## DepositId / WithdrawalId scalar types -/

/-- An L1 deposit-receipt identifier — the canonical numeric
    form of the 32-byte L1 deposit-receipt hash.

    Implemented as `Nat` (rather than `ByteArray`) so that the
    deposit-id index in `BridgeState.consumed` can be a
    `Std.TreeMap` keyed on Lean core's lawful `compare : Nat → Nat
    → Ordering`.  The runtime adaptor performs the BE-byte → Nat
    conversion at the bridge boundary; conversion is injective on
    fixed-length 32-byte inputs (the natural number value of the
    32 bytes interpreted big-endian uniquely identifies the
    underlying byte array).

    **Wire-encoding bound (§8.8.5).**  The Phase-4 CBE encoder
    encodes `Nat` as a 1-byte tag + 8-byte LE payload; values
    `≥ 2^64` are not roundtrip-safe.  An `Action.deposit` with a
    full 32-byte (256-bit) hash thus does NOT round-trip through
    `Encoding.Action.encode/decode`; the runtime adaptor must
    project the L1 hash into a 64-bit *deployment-canonical* form
    before it crosses the wire.  Practical projections include:

      * `keccak256(blockHash ‖ logIdx)[0:8]` — 64-bit deterministic
        identifier; collision-resistant for the lifetime of a
        single deployment under standard cryptographic assumptions.
      * Sequential numbering by the L1 contract (`uint64`
        per-event counter), bounded by the contract's lifetime.

    The `BridgeAdmissibleWith` conjunct 6 (deposit-id uniqueness
    against the `consumed` set) protects against replay regardless
    of which projection the deployment chooses; injectivity of the
    projection is the deployment's correctness obligation.  The
    Lean side simply requires the deposit-id to be unique within
    the bridge's lifetime.

    **Deployment-correctness obligation (AR.13.3).**  The L1
    `(receiptHash, blockNum, logIdx)` tuple must inject into a
    64-bit `DepositId` for the per-actor uniqueness gate to hold
    end-to-end.  The L1 contract — not the Lean kernel — is
    responsible for the projection.  Lean cannot enforce this; a
    collision in the 64-bit projection space would let an
    adversary replay a deposit credited under a different L1
    event.  The cross-stack F-corpus (Workstream F) verifies the
    obligation operationally; production deployments must surface
    the projection function in their auditor packet.

    Documented as a Lean-level encoding deviation from the
    integration plan §7.1.1's `abbrev DepositId := ByteArray`.
    Switching to `ByteArray` is a follow-up that would require
    defining a `byteArrayCompare : ByteArray → ByteArray →
    Ordering` plus the `TransCmp` / `LawfulEqCmp` instances; the
    current `Nat` choice keeps proofs lawful by Lean core's
    built-in `compare : Nat → Nat → Ordering`. -/
abbrev DepositId : Type := Nat

/-- A monotonically-increasing per-bridge withdrawal index.  Assigned
    at L2-side `withdraw` time and used as the L1-redemption
    coordinate. -/
abbrev WithdrawalId : Type := Nat

/-! ## DepositRecord -/

/-- Per-deposit metadata recorded in `BridgeState.consumed`: which
    resource was credited, the amount credited to the user-facing
    recipient, the amount credited to the gas-pool actor, and the
    action-budget grant credited to the recipient at the admission
    layer.  Required by the bridge accounting theorems (§7.6 / §15E)
    so the per-resource `totalUserDeposited` / `totalPoolDeposited`
    folds can sum each per-deposit quantity at a fixed resource.

    The `(userAmount, poolAmount)` split separates the two L2-credit
    destinations of a single L1 deposit:

      * `Action.deposit` (no fee) credits the full amount to the
        recipient — `userAmount := amount`, `poolAmount := 0`,
        `budgetGrant := 0`.
      * `Action.depositWithFee` (Workstream GP) splits the L1
        `msg.value` into a `userAmount` credited to the recipient
        and a `poolAmount` credited to the gas-pool actor, and grants
        the recipient `budgetGrant` action-budget units.

    Audit-2 amendment to §7.1.1: the original sketch had
    `consumed : TreeMap DepositId Unit`, but the accounting theorem
    requires per-deposit metadata to compute `totalDeposited`.  The
    Workstream-GP widening (GP.4.1) further splits the single
    `amount` field into the `(userAmount, poolAmount, budgetGrant)`
    triple so the unified-gas-pool accounting split (GP.4.2) can sum
    the user-credit and pool-credit terms independently.  A fee-less
    `Action.deposit` round-trips to / from the pre-widening two-field
    shape via `LegacyDepositRecord` (see below). -/
structure DepositRecord where
  /-- The resource that was credited. -/
  resource    : ResourceId
  /-- The amount credited to the user-facing recipient. -/
  userAmount  : Amount
  /-- The amount credited to the gas-pool actor.  Zero for legacy
      `Action.deposit` events. -/
  poolAmount  : Amount
  /-- The action-budget grant credited to the recipient at the
      admission layer.  Equals
      `min(MAX_BUDGET_PER_DEPOSIT, poolAmount / weiPerBudgetUnit)` as
      computed by the L1 contract.  Zero for legacy `Action.deposit`
      events.  Persisted in the bridge state so a re-org or replay can
      reconstruct the recipient's budget timeline without re-deriving
      from the L1 exchange rate (which is L1 contract state, not L2
      state). -/
  budgetGrant : Nat
  deriving Repr, DecidableEq

/-! ### Legacy deposit-record compatibility

Before the Workstream-GP widening (GP.4.1), a `DepositRecord` tracked
a single `(resource, amount)` pair.  `LegacyDepositRecord` preserves
that two-field shape so a migration / deserialisation path can lift a
pre-widening record into the current `DepositRecord` form.  The
round-trip lemma `DepositRecord.toLegacy_fromLegacy` certifies the
lift is lossless on the two legacy fields. -/

/-- The pre-widening two-field deposit record: a resource and the
    single credited amount.  A fee-less `Action.deposit` maps onto
    this shape directly. -/
structure LegacyDepositRecord where
  /-- The resource that was credited. -/
  resource : ResourceId
  /-- The credited amount. -/
  amount   : Amount
  deriving Repr, DecidableEq

/-- Lift a legacy two-field deposit record into the current
    `DepositRecord` form: the credited amount becomes the user-facing
    `userAmount`, with no pool credit and no budget grant (matching
    the semantics of a fee-less `Action.deposit`). -/
@[inline] def DepositRecord.fromLegacy (lr : LegacyDepositRecord) : DepositRecord where
  resource    := lr.resource
  userAmount  := lr.amount
  poolAmount  := 0
  budgetGrant := 0

/-- Project a `DepositRecord` back onto the legacy two-field shape,
    discarding the pool credit and budget grant.  Left inverse of
    `DepositRecord.fromLegacy`. -/
@[inline] def DepositRecord.toLegacy (rec : DepositRecord) : LegacyDepositRecord where
  resource := rec.resource
  amount   := rec.userAmount

/-- Round-trip preservation: lifting a legacy record and projecting it
    back is the identity.  Certifies that `DepositRecord.fromLegacy`
    is lossless on the two legacy `(resource, amount)` fields. -/
theorem DepositRecord.toLegacy_fromLegacy (lr : LegacyDepositRecord) :
    (DepositRecord.fromLegacy lr).toLegacy = lr := by
  cases lr with
  | mk resource amount => rfl

/-- Reverse round-trip on the legacy subspace: a `DepositRecord` with
    no pool credit and no budget grant — i.e. one that could have come
    from a fee-less `Action.deposit` — is recovered exactly by
    projecting to its legacy form and lifting back.  Together with
    `toLegacy_fromLegacy` this exhibits `LegacyDepositRecord` as
    precisely the `poolAmount = budgetGrant = 0` subspace of
    `DepositRecord`. -/
theorem DepositRecord.fromLegacy_toLegacy_of_zero_pool_budget
    (rec : DepositRecord) (h_pool : rec.poolAmount = 0)
    (h_budget : rec.budgetGrant = 0) :
    DepositRecord.fromLegacy rec.toLegacy = rec := by
  cases rec with
  | mk resource userAmount poolAmount budgetGrant =>
    subst h_pool
    subst h_budget
    rfl

/-! ## PendingWithdrawal -/

/-- One pending L2 withdrawal, awaiting L1 redemption. -/
structure PendingWithdrawal where
  /-- The resource being withdrawn. -/
  resource    : ResourceId
  /-- The L1 recipient address (raw bytes; resolved by the runtime
      adaptor via `EthAddress.ofBytes`). -/
  recipient   : EthAddress
  /-- The withdrawn amount. -/
  amount      : Amount
  /-- The L2 log index at which the withdrawal was applied.  Used by
      the L1-side proof verifier to locate the withdrawal in the
      finalised log slice. -/
  l2LogIndex  : Nat
  deriving Repr, DecidableEq

/-! ## BridgeState -/

/-- The bridge's L1 ↔ L2 ledger.

    `consumed` records which L1 deposit ids have been credited on
    L2 and the metadata for each (resource + amount).  `pending`
    records which L2 withdrawals are awaiting L1 redemption.
    `nextWdId` is the next withdrawal id to assign.

    `BridgeState.empty` is the genesis state: empty ledger, next
    withdrawal id 0. -/
structure BridgeState where
  /-- The set of consumed L1 deposit ids and per-deposit metadata. -/
  consumed : TreeMap DepositId DepositRecord compare
  /-- The set of pending L2 withdrawals awaiting L1 redemption. -/
  pending  : TreeMap WithdrawalId PendingWithdrawal compare
  /-- The next withdrawal id to assign on the next `withdraw`
      action.  Monotonically increases; never reused. -/
  nextWdId : WithdrawalId
  /-- GP.11.8: L2 reflection of L1 AMM ETH reserve.  Committed to the
      state root so the fault-proof game can adjudicate disputes that
      turn on AMM state. -/
  ammReserveEth : Amount := 0
  /-- GP.11.8: L2 reflection of L1 AMM BOLD reserve. -/
  ammReserveBold : Amount := 0
  /-- GP.11.8: Whether the BOLD circuit breaker is closed on L1. -/
  boldCircuitClosed : Bool := false
  /-- GP.11.8: L1 per-BOLD TVL cap. -/
  boldTvlCap : Amount := 0
  /-- GP.11.8: L1 per-BOLD total locked value. -/
  boldTotalLockedValue : Amount := 0
  /-- GP.11.10: Whether the L1 AMM kill switch has fired
      (`emergencyDisableAmm()` sets the one-way `ammDisabled` flag on
      L1).  Committed to the state root so the fault-proof game can
      adjudicate disputes that turn on the AMM's disabled state and
      the L2 ingestor learns the disable from the commitment alone
      (the GP.11.10 design decision: no `Action.disableAmm`).
      One-way on L1; the L2 mirror simply reflects the L1 value. -/
  ammDisabled : Bool := false
  deriving Repr

namespace BridgeState

/-- The genesis bridge state: empty consumed set, empty pending set,
    next withdrawal id 0, AMM reserves at zero, BOLD circuit open,
    AMM enabled (kill switch not fired). -/
def empty : BridgeState where
  consumed             := ∅
  pending              := ∅
  nextWdId             := 0
  ammReserveEth        := 0
  ammReserveBold       := 0
  boldCircuitClosed    := false
  boldTvlCap           := 0
  boldTotalLockedValue := 0
  ammDisabled          := false

/-- §7.1.1 smoke-test: `BridgeState.empty.consumed` is the empty
    `TreeMap`. -/
theorem empty_consumed_empty :
    (empty.consumed : TreeMap DepositId DepositRecord compare) = ∅ := rfl

/-- §7.1.1 smoke-test: `BridgeState.empty.pending` is the empty
    `TreeMap`. -/
theorem empty_pending_empty :
    (empty.pending : TreeMap WithdrawalId PendingWithdrawal compare) = ∅ := rfl

/-- §7.1.1 smoke-test: `BridgeState.empty.nextWdId = 0`. -/
theorem empty_nextWdId_zero :
    empty.nextWdId = 0 := rfl

/-- GP.11.8 smoke-test: `BridgeState.empty.ammReserveEth = 0`. -/
theorem empty_ammReserveEth_zero :
    empty.ammReserveEth = 0 := rfl

/-- GP.11.8 smoke-test: `BridgeState.empty.ammReserveBold = 0`. -/
theorem empty_ammReserveBold_zero :
    empty.ammReserveBold = 0 := rfl

/-- GP.11.8 smoke-test: `BridgeState.empty.boldCircuitClosed = false`. -/
theorem empty_boldCircuitClosed_false :
    empty.boldCircuitClosed = false := rfl

/-- GP.11.8 smoke-test: `BridgeState.empty.boldTvlCap = 0`. -/
theorem empty_boldTvlCap_zero :
    empty.boldTvlCap = 0 := rfl

/-- GP.11.8 smoke-test: `BridgeState.empty.boldTotalLockedValue = 0`. -/
theorem empty_boldTotalLockedValue_zero :
    empty.boldTotalLockedValue = 0 := rfl

/-- GP.11.10 smoke-test: `BridgeState.empty.ammDisabled = false` —
    the genesis AMM is enabled (the kill switch has not fired). -/
theorem empty_ammDisabled_false :
    empty.ammDisabled = false := rfl

/-! ## Convenience accessors / mutators -/

/-- Mark a deposit-id as consumed with the given metadata.  Inserts
    the record into `consumed`, leaving `pending` and `nextWdId`
    unchanged. -/
@[inline] def markConsumed (bs : BridgeState) (depositId : DepositId)
    (rec : DepositRecord) : BridgeState :=
  { bs with consumed := bs.consumed.insert depositId rec }

/-- Insert a pending withdrawal at `bs.nextWdId` and bump the
    counter.  Leaves `consumed` and AMM state unchanged. -/
@[inline] def appendWithdrawal (bs : BridgeState) (wd : PendingWithdrawal) :
    BridgeState :=
  { bs with
    pending  := bs.pending.insert bs.nextWdId wd
    nextWdId := bs.nextWdId + 1 }

/-- Look up whether a deposit-id has been consumed. -/
@[inline] def isConsumed (bs : BridgeState) (depositId : DepositId) : Bool :=
  bs.consumed.contains depositId

/-- Look up whether a deposit-id has been consumed (Prop form, for
    proofs). -/
@[inline] def hasConsumed (bs : BridgeState) (depositId : DepositId) : Prop :=
  bs.consumed.contains depositId = true

instance (bs : BridgeState) (d : DepositId) : Decidable (bs.hasConsumed d) :=
  inferInstanceAs (Decidable (bs.consumed.contains d = true))

end BridgeState

end Bridge
end LegalKernel
