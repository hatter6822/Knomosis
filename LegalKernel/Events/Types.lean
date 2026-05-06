/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Events.Types — the §8.9.2 `Event` inductive.

Phase 5 WU 5.6.  Defines the deployment-facing `Event` type that
indexers, dashboards, and observers consume.  Events are
*observations* derived deterministically from log entries (Genesis
Plan §8.9.1); they are NOT separate from the kernel — every event is
a function of a `LogEntry` (`SignedAction` + pre/post state).

Phase-5 scope.  The Genesis Plan §8.9.2 enumerates seven event
constructors:

  ```
  inductive Event
    | balanceChanged   (r : ResourceId) (a : ActorId) (oldV newV : Amount)
    | nonceAdvanced    (a : ActorId) (oldN newN : Nonce)
    | identityRegistered (a : ActorId) (key : PublicKey)
    | identityRevoked  (a : ActorId)
    | timeRecorded     (t : Nat)
    | disputeFiled     (d : Dispute)
    | verdictApplied   (v : Verdict)
  ```

Phase 5 ships the first five (`balanceChanged`, `nonceAdvanced`,
`identityRegistered`, `identityRevoked`, `timeRecorded`).  The
`disputeFiled` and `verdictApplied` constructors are deferred to
Phase 6, when the `Dispute` and `Verdict` types land.  The
constructor list is **append-only**: indexers serialising events
under the Phase-5 schema must continue to deserialise them under any
Phase 6+ schema (their constructor indices do not shift).

This module is **not** part of the trusted computing base.  Bugs
here produce wrong observations, but cannot violate any kernel
invariant.
-/

import LegalKernel.Kernel
import LegalKernel.Authority.Crypto
import LegalKernel.Bridge.AddressBook
import LegalKernel.Bridge.State

namespace LegalKernel
namespace Events

/-! ## The `Event` inductive (§8.9.2)

Each constructor records *what changed* in domain-friendly
vocabulary.  Indexers consume events without re-deriving them from
`State` diffs; the event vocabulary is designed for query efficiency
without constraining the kernel.

**Constructor-ordering policy (append-only).**  Constructors are
listed in the order of their Genesis-Plan §8.9.2 listing.  Phase 5
ships indices 0..4; Phase 6 base appends indices 5..7
(`disputeFiled`, `disputeWithdrawn`, `verdictApplied`); the
Phase-6 incentive-integration amendment appends index 8
(`rewardIssued`).  The indices are part of the canonical event
encoding and cannot shift retroactively without invalidating
every indexed event in production. -/

open LegalKernel.Authority

/-- The set of observable events the runtime extracts from each log
    entry.  Phase-5 ships five constructors; Phase 6 base appends
    three more (`disputeFiled`, `disputeWithdrawn`,
    `verdictApplied`); the Phase-6 incentive-integration amendment
    appends one more (`rewardIssued`). -/
inductive Event
  /-- A balance changed for `(resource, actor)`.  The `oldV` and
      `newV` fields are the pre / post values from the kernel's
      view; subscribers can compute the delta as `newV - oldV` (or
      detect a debit when `oldV > newV`). -/
  | balanceChanged   (r : ResourceId) (a : ActorId) (oldV newV : Amount)
  /-- An actor's nonce advanced.  The `oldN` and `newN` fields are
      the pre / post values from the nonce ledger.  By the §8.5
      `expectsNonce_strict_mono` lemma, `newN = oldN + 1` always —
      we record both values for indexer convenience (an indexer can
      verify the strict-mono property without reading the kernel
      proofs). -/
  | nonceAdvanced    (a : ActorId) (oldN newN : Nonce)
  /-- An actor's `PublicKey` was registered or rotated.  Emitted by
      the `replaceKey` action (Phase 3 WU 3.10) — the rotation
      semantics make "register" and "rotate" the same observable
      action at the event layer.  Deployments distinguish first-time
      registration from rotation by inspecting the pre-state's
      registry. -/
  | identityRegistered (a : ActorId) (key : PublicKey)
  /-- An actor's `PublicKey` registration was revoked.  Reserved for
      a future `revokeKey` Action constructor; Phase 5's `Action`
      layer does not currently emit this event (no revoke action
      has landed). -/
  | identityRevoked  (a : ActorId)
  /-- A timestamp was recorded into deployment-level state.  Used by
      deployments that track an external time oracle; Phase 5's
      core action set does not currently emit this event. -/
  | timeRecorded     (t : Nat)
  /-- A dispute was filed against a log entry (Phase 6 §8.4.2).
      Emitted by the `dispute` action.  `challenger` is the actor
      filing the dispute; `targetIdx` is the impugned log index.
      Indexers consume this event to maintain a "open disputes"
      view per actor. -/
  | disputeFiled     (challenger : ActorId) (targetIdx : Nat)
  /-- A previously-filed dispute was withdrawn by the challenger
      (Phase 6 §8.4.4 / WU 6.11).  `disputeIdx` is the log index of
      the original dispute entry. -/
  | disputeWithdrawn (disputeIdx : Nat)
  /-- A quorum-signed verdict was applied (Phase 6 §8.4.2).
      `disputeIdx` references the dispute entry; `outcomeTag`
      records the outcome (0 = upheld, 1 = rejected,
      2 = inconclusive — matching the `EvidenceVerdict` constructor
      indices).  An `upheld` verdict triggers a subsequent
      `rollback` action whose effect is observable via state-hash
      diffing. -/
  | verdictApplied   (disputeIdx : Nat) (outcomeTag : Nat)
  /-- A reward of `amount` units of `resource` was issued to
      `recipient` (Phase-6 incentive-integration amendment).
      Emitted IN ADDITION to `balanceChanged` so indexers can
      distinguish "reward-class transfer" (intended payout from
      a deployment-supplied reward policy) from "regular
      transfer" without re-deriving the action's intent.
      Frozen index 8.

      Unlike `balanceChanged`, this event is NOT delta-filtered:
      a `reward _ _ 0` action emits `rewardIssued _ _ 0` even
      when the recipient's balance does not change.  Indexers
      that want the kernel-level effect should subscribe to
      `balanceChanged`; indexers that want the policy-level
      intent should subscribe to `rewardIssued`. -/
  | rewardIssued     (resource : ResourceId) (recipient : ActorId)
                     (amount : Amount)
  /-- A bridge L2 → L1 withdrawal was scheduled for L1 redemption
      (Workstream C.5 / §7.5).  Carries the L2 sender, amount,
      destination L1 address, and the assigned `WithdrawalId`
      (derived from the post-state `BridgeState.nextWdId`).
      Frozen index 9. -/
  | withdrawalRequested (resource : ResourceId) (sender : ActorId)
                        (amount : Amount)
                        (recipientL1 : Bridge.EthAddress)
                        (withdrawalId : Bridge.WithdrawalId)
  /-- A bridge L1 → L2 deposit was credited on L2 (Workstream C.5 /
      §7.5).  Carries the L1 deposit-receipt id, the L2 recipient,
      the resource, and the credited amount.  Frozen index 10. -/
  | depositCredited     (resource : ResourceId) (recipient : ActorId)
                        (amount : Amount)
                        (depositId : Bridge.DepositId)
  deriving Repr, DecidableEq

/-! ## Convenience predicates -/

/-- True iff `e` records a balance change.  Used by indexers that
    want to subscribe only to balance updates. -/
def Event.isBalanceChange : Event → Bool
  | .balanceChanged _ _ _ _ => true
  | _                       => false

/-- True iff `e` records a registry mutation (registration or
    revocation). -/
def Event.isRegistryChange : Event → Bool
  | .identityRegistered _ _ => true
  | .identityRevoked _      => true
  | _                       => false

/-- The actor that this event affects, if any.  Used by indexers
    that maintain a per-actor view. -/
def Event.actor : Event → Option ActorId
  | .balanceChanged _ a _ _       => some a
  | .nonceAdvanced a _ _          => some a
  | .identityRegistered a _       => some a
  | .identityRevoked a            => some a
  | .timeRecorded _               => none
  | .disputeFiled c _             => some c
  | .disputeWithdrawn _           => none
  | .verdictApplied _ _           => none
  | .rewardIssued _ a _           => some a
  | .withdrawalRequested _ a _ _ _ => some a
  | .depositCredited _ a _ _      => some a

/-- The resource that this event affects, if any. -/
def Event.resource : Event → Option ResourceId
  | .balanceChanged r _ _ _        => some r
  | .rewardIssued r _ _            => some r
  | .withdrawalRequested r _ _ _ _ => some r
  | .depositCredited r _ _ _       => some r
  | _                              => none

/-- True iff `e` records a dispute-pipeline observation
    (filing / withdrawing / verdict).  Used by indexers that
    track adjudication activity separately from balance flow. -/
def Event.isDisputeEvent : Event → Bool
  | .disputeFiled _ _     => true
  | .disputeWithdrawn _   => true
  | .verdictApplied _ _   => true
  | _                     => false

/-- True iff `e` is a `rewardIssued` event.  Used by indexers that
    subscribe specifically to deployment-level reward semantics
    (e.g. for bug-bounty leaderboards).  `balanceChanged` events
    on reward actions are still emitted; this projection
    distinguishes the SEMANTIC observable from the kernel-level
    balance delta. -/
def Event.isRewardIssued : Event → Bool
  | .rewardIssued _ _ _ => true
  | _                   => false

/-- True iff `e` is a bridge-pipeline event (`withdrawalRequested`
    or `depositCredited`).  Used by indexers that maintain a
    bridge-flow view separate from regular balance flow. -/
def Event.isBridgeEvent : Event → Bool
  | .withdrawalRequested _ _ _ _ _ => true
  | .depositCredited _ _ _ _       => true
  | _                              => false

end Events
end LegalKernel
