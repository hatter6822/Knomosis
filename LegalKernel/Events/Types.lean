-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
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
import LegalKernel.Authority.LocalPolicy
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
  /-- An actor declared a local policy (Workstream LP / LP.10).
      Carries the actor and the declared policy.  Indexers consume
      this event to maintain a per-actor "currently declared
      policy" view.  Frozen index 11.

      Emitted UNCONDITIONALLY on a successful `declareLocalPolicy`
      (mirroring the `rewardIssued` convention): an idempotent
      re-declaration of the same policy still emits the event, so
      indexers see a faithful audit trail of every policy state
      change attempt. -/
  | localPolicyDeclared (actor : ActorId) (policy : Authority.LocalPolicy)
  /-- An actor revoked their local policy (Workstream LP / LP.10).
      Carries the actor.  Frozen index 12. -/
  | localPolicyRevoked  (actor : ActorId)
  /-- A fault-proof game was opened against a published state
      root (Workstream H §12.3).  Carries the L1-assigned
      `gameId`, the `challenger`, the disputed root range
      `[disputedStartIdx .. disputedEndIdx]`, and the L2 binding
      hash matching the corresponding `Action.faultProofChallenge`
      to the L1 game.  Frozen index 13. -/
  | faultProofGameOpened (gameId : Nat) (challenger : ActorId)
                          (disputedStartIdx : Nat)
                          (disputedEndIdx : Nat)
                          (bindingHash : ByteArray)
  /-- A bisection step was taken in an open fault-proof game
      (Workstream H §12.3).  Carries the gameId, the round
      number, the party who acted, and the midpoint claim
      (idx + commit).  Emitted by the runtime's L1-event watcher
      observing midpoint submissions on L1.  Frozen index 14. -/
  | faultProofBisectionStep (gameId : Nat) (round : Nat)
                              (party : ActorId)
                              (idx : Nat) (commit : ByteArray)
  /-- A fault-proof game was settled (Workstream H §12.3).
      Carries the gameId, winner, loser, and bond payout.
      Indexers consume this event to maintain a "settled games"
      view.  Frozen index 15. -/
  | faultProofGameSettled (gameId : Nat) (winner loser : ActorId)
                            (payout : Amount)
  /-- A bridge `depositWithFee` was credited on L2 (Workstream GP
      §15E v1.0).  Carries the L1 deposit-receipt id, the L2
      recipient, the resource, the credited user amount, the
      pool amount, and the budget grant amount.  Indexers consume
      this event to maintain a per-actor "deposits received" view
      with the budget-grant breakdown.  Distinct from
      `depositCredited` (index 10) so consumers can distinguish
      legacy deposits from fee-split deposits.  Frozen index 16. -/
  | depositWithFeeCredited (resource : ResourceId) (recipient : ActorId)
                            (poolActor : ActorId)
                            (userAmount poolAmount : Amount)
                            (budgetGrant : Nat)
                            (depositId : Bridge.DepositId)
  /-- An L2 actor topped up their action budget (Workstream GP
      §15E v1.0).  Carries the signer (whose budget is
      incremented), the gas resource debited, the gas amount, the
      budget increment, and the poolActor receiving the gas.
      Indexers consume this event to maintain a per-actor
      "current epoch budget" view + the L2 gas-pool drain
      accounting.  Frozen index 17. -/
  | actionBudgetTopUp     (signer : ActorId) (gasResource : ResourceId)
                            (gasAmount : Amount) (budgetIncrement : Nat)
                            (poolActor : ActorId)
  /-- The gas pool was drained by `amount` units of `resource` to
      `sequencerActor` (Workstream GP §15E v1.0).  Reserved for
      future GP.7 work — the gas-pool actor's transfer policy
      authorises this drain via `gasPoolPolicy`.  Frozen index 18. -/
  | gasPoolClaim          (resource : ResourceId) (sequencer : ActorId)
                            (amount : Amount)
  /-- A delegate topped up *another* actor's action budget
      (Workstream GP / GP.3.4 `topUpActionBudgetFor`).  Carries the
      `recipient` (whose budget is incremented), the `signer`
      (delegate/payer), the gas resource debited from the signer, the
      gas amount, the budget increment credited to the recipient, and
      the poolActor receiving the gas.  Distinct from
      `actionBudgetTopUp` because the budget target (`recipient`)
      differs from the payer (`signer`); indexers maintaining a
      per-actor budget view must credit the recipient, not the
      signer.  Frozen index 19. -/
  | delegatedActionBudgetTopUp (recipient signer : ActorId)
                            (gasResource : ResourceId) (gasAmount : Amount)
                            (budgetIncrement : Nat) (poolActor : ActorId)
  /-- An actor's per-epoch action budget was consumed by `amount`
      units (Workstream GP / GP.6.4).  Emitted by `extractEvents`
      on every successful admission whose signer is NOT exempt
      from consumption (i.e., signer ≠ bridgeActor) and whose
      `BudgetPolicy.bounded.actionCost > 0`.  Indexers consume this
      event to compute "current-epoch budget remaining" =
      `freeTier + grants_this_epoch − consumed_this_epoch`, the
      load-bearing semantics behind the deployment-UI promise
      "you have N actions remaining this epoch."  Distinct from the
      three grant events (`depositWithFeeCredited`,
      `actionBudgetTopUp`, `delegatedActionBudgetTopUp`), which
      track CREDITS to the budget ledger; `budgetConsumed` tracks
      DEBITS.  The bridgeActor exemption from GP.3.2.c means
      bridge-signed actions never emit `budgetConsumed` (the
      bridgeActor's L1-gas-gated authority makes L2 budget
      gating redundant).  Frozen index 20. -/
  | budgetConsumed         (actor : ActorId) (amount : Nat)
  /-- An L2 AMM swap was executed (Workstream GP / GP.11.4).  Carries
      the `fromResource` (credited to the reserve), `toResource`
      (debited from the reserve), the `amountIn` (input amount credited
      to the reserve at `fromResource`), the `amountOut` (output amount
      debited from the reserve at `toResource`), and the
      `ammReserveActor` whose balance cells were mutated.  Indexers
      consume this event to maintain AMM reserve views and LP yield
      accounting (every swap accrues the fee into the reserves, so
      `k = reserveFrom × reserveTo` is monotonically non-decreasing).
      Distinct from `balanceChanged` so subscribers can identify
      AMM-class balance mutations without re-deriving the action's
      intent.  Frozen index 21. -/
  | ammSwapExecuted        (fromResource toResource : ResourceId)
                            (amountIn amountOut : Amount)
                            (ammReserveActor : ActorId)
  deriving Repr, DecidableEq

/-! ## §8.9.1.bis Event constructor-index projection (AR.6)

`Event.tag : Event → Nat` mirrors `Action.tag` in
`Authority/LocalPolicySemantics.lean`.  AR.6 / m-7: prior to this
function, the `Event` constructor index space was pinned by
docstring annotations only — there was no Lean-level checkable
contract.  Off-chain indexers consume the index as a wire-format
discriminator (see `docs/abi.md`).

Frozen indices (matching the per-constructor docstring annotations
above):

  0  — `balanceChanged`
  1  — `nonceAdvanced`
  2  — `identityRegistered`
  3  — `identityRevoked`         (reserved for future revoke action)
  4  — `timeRecorded`            (reserved for deployment time-oracle)
  5  — `disputeFiled`
  6  — `disputeWithdrawn`
  7  — `verdictApplied`
  8  — `rewardIssued`
  9  — `withdrawalRequested`
  10 — `depositCredited`
  11 — `localPolicyDeclared`
  12 — `localPolicyRevoked`
  13 — `faultProofGameOpened`
  14 — `faultProofBisectionStep`
  15 — `faultProofGameSettled`
  16 — `depositWithFeeCredited`  (Workstream GP §15E v1.0)
  17 — `actionBudgetTopUp`       (Workstream GP §15E v1.0)
  18 — `gasPoolClaim`            (Workstream GP §15E v1.0)
  19 — `delegatedActionBudgetTopUp` (Workstream GP / GP.3.4)
  20 — `budgetConsumed`          (Workstream GP / GP.6.4)
  21 — `ammSwapExecuted`         (Workstream GP / GP.11.4)

The regression-tier pins live in `LegalKernel/Test/Events/Types.lean`. -/

/-- The constructor index of an `Event`, as a `Nat`.  Mirrors
    `Action.tag`; pinned by elaboration-time examples in
    `LegalKernel/Test/Events/Types.lean`. -/
def Event.tag : Event → Nat
  | .balanceChanged       _ _ _ _     =>  0
  | .nonceAdvanced        _ _ _       =>  1
  | .identityRegistered   _ _         =>  2
  | .identityRevoked      _           =>  3
  | .timeRecorded         _           =>  4
  | .disputeFiled         _ _         =>  5
  | .disputeWithdrawn     _           =>  6
  | .verdictApplied       _ _         =>  7
  | .rewardIssued         _ _ _       =>  8
  | .withdrawalRequested  _ _ _ _ _   =>  9
  | .depositCredited      _ _ _ _     => 10
  | .localPolicyDeclared  _ _         => 11
  | .localPolicyRevoked   _           => 12
  | .faultProofGameOpened _ _ _ _ _   => 13
  | .faultProofBisectionStep _ _ _ _ _ => 14
  | .faultProofGameSettled  _ _ _ _   => 15
  | .depositWithFeeCredited _ _ _ _ _ _ _ => 16
  | .actionBudgetTopUp    _ _ _ _ _   => 17
  | .gasPoolClaim         _ _ _       => 18
  | .delegatedActionBudgetTopUp _ _ _ _ _ _ => 19
  | .budgetConsumed       _ _         => 20
  | .ammSwapExecuted     _ _ _ _ _   => 21

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
  | .localPolicyDeclared a _      => some a
  | .localPolicyRevoked a         => some a
  | .faultProofGameOpened _ c _ _ _   => some c
  | .faultProofBisectionStep _ _ p _ _ => some p
  | .faultProofGameSettled _ w _ _    => some w
  | .depositWithFeeCredited _ a _ _ _ _ _ => some a
  | .actionBudgetTopUp a _ _ _ _      => some a
  | .gasPoolClaim _ s _               => some s
  -- GP.3.4: the budget target is the recipient (the actor whose
  -- per-actor budget view an indexer must credit).
  | .delegatedActionBudgetTopUp recipient _ _ _ _ _ => some recipient
  -- GP.6.4: the actor whose budget was debited.
  | .budgetConsumed a _                             => some a
  -- GP.11.4: the reserve actor whose balances were mutated.
  | .ammSwapExecuted _ _ _ _ ra                     => some ra

/-- The resource that this event affects, if any. -/
def Event.resource : Event → Option ResourceId
  | .balanceChanged r _ _ _        => some r
  | .rewardIssued r _ _            => some r
  | .withdrawalRequested r _ _ _ _ => some r
  | .depositCredited r _ _ _       => some r
  | .depositWithFeeCredited r _ _ _ _ _ _ => some r
  | .actionBudgetTopUp _ r _ _ _   => some r
  | .gasPoolClaim r _ _            => some r
  | .delegatedActionBudgetTopUp _ _ r _ _ _ => some r
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

/-- True iff `e` is a local-policy management event
    (`localPolicyDeclared` or `localPolicyRevoked`).  Used by
    indexers that maintain a per-actor "currently declared
    policy" view.  Workstream LP / LP.10. -/
def Event.isLocalPolicyEvent : Event → Bool
  | .localPolicyDeclared _ _ => true
  | .localPolicyRevoked _    => true
  | _                        => false

/-- True iff `e` is a fault-proof pipeline event
    (`faultProofGameOpened`, `faultProofBisectionStep`, or
    `faultProofGameSettled`).  Workstream H. -/
def Event.isFaultProofEvent : Event → Bool
  | .faultProofGameOpened _ _ _ _ _   => true
  | .faultProofBisectionStep _ _ _ _ _ => true
  | .faultProofGameSettled _ _ _ _    => true
  | _                                 => false

end Events
end LegalKernel
