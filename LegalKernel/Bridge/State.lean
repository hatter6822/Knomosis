/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.State — Workstream C.1 (`docs/ethereum_integration_plan.md` §7.1).

The bridge ledger that tracks the L1 ↔ L2 deposit / withdrawal flow.
A `BridgeState` carries:

  * `consumed`   — the set of L1 deposit-receipt hashes that have
                   been credited on L2, indexed by the canonical
                   numeric (BE-decoded) form of the receipt hash.
                   Each entry is a `DepositRecord` carrying the
                   `(resource, amount)` metadata required by the
                   bridge accounting theorem (§7.6).
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
    bridge accounting theorem requires the per-deposit `(resource,
    amount)` metadata, so the value type is widened to a record).

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
-/

import LegalKernel.Kernel
import LegalKernel.RBMapLemmas
import LegalKernel.Bridge.AddressBook

open Std

namespace LegalKernel
namespace Bridge

/-! ## DepositId / WithdrawalId scalar types -/

/-- An L1 deposit-receipt identifier — the canonical big-endian
    numeric form of the 32-byte L1 deposit-receipt hash.

    Implemented as `Nat` (rather than `ByteArray`) so that the
    deposit-id index in `BridgeState.consumed` can be a
    `Std.TreeMap` keyed on Lean core's lawful `compare : Nat → Nat
    → Ordering`.  The runtime adaptor performs the BE-byte → Nat
    conversion at the bridge boundary; conversion is injective on
    fixed-length 32-byte inputs.

    Documented as a Lean-level encoding deviation from the
    integration plan §7.1.1's `abbrev DepositId := ByteArray`. -/
abbrev DepositId : Type := Nat

/-- A monotonically-increasing per-bridge withdrawal index.  Assigned
    at L2-side `withdraw` time and used as the L1-redemption
    coordinate. -/
abbrev WithdrawalId : Type := Nat

/-! ## DepositRecord -/

/-- Per-deposit metadata: which resource was credited, and by how
    much.  Required by the bridge accounting theorem (§7.6) so the
    `totalDeposited es r` fold can sum the per-deposit amounts at a
    fixed resource.

    Audit-2 amendment to §7.1.1: the original sketch had
    `consumed : TreeMap DepositId Unit`, but the accounting theorem
    requires per-deposit `(resource, amount)` metadata to compute
    `totalDeposited`.  The widened value type is recorded here. -/
structure DepositRecord where
  /-- The resource that was credited. -/
  resource : ResourceId
  /-- The credited amount. -/
  amount   : Amount
  deriving Repr, DecidableEq

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
  deriving Repr

namespace BridgeState

/-- The genesis bridge state: empty consumed set, empty pending set,
    next withdrawal id 0. -/
def empty : BridgeState where
  consumed := ∅
  pending  := ∅
  nextWdId := 0

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

/-! ## Convenience accessors / mutators -/

/-- Mark a deposit-id as consumed with the given metadata.  Inserts
    the record into `consumed`, leaving `pending` and `nextWdId`
    unchanged. -/
@[inline] def markConsumed (bs : BridgeState) (depositId : DepositId)
    (rec : DepositRecord) : BridgeState :=
  { bs with consumed := bs.consumed.insert depositId rec }

/-- Insert a pending withdrawal at `bs.nextWdId` and bump the
    counter.  Leaves `consumed` unchanged. -/
@[inline] def appendWithdrawal (bs : BridgeState) (wd : PendingWithdrawal) :
    BridgeState where
  consumed := bs.consumed
  pending  := bs.pending.insert bs.nextWdId wd
  nextWdId := bs.nextWdId + 1

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
