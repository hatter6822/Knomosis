-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Authority.Action — the §4.13 Action layer.

Phase 3 WU 3.1 and WU 3.2.  Defines the deployment's `Action`
inductive (a first-order data form: one constructor per law, each
carrying only scalars and identifiers), the `CompiledAction`
wrapper that pairs each kernel `Transition` with the originating
`Action`, the `Action.compile` function that produces the wrapper,
and the `Action.compile_injective` headline lemma.

**Structural injectivity design.**  The Genesis-Plan §4.13 sketch
returned `Transition` directly from `Action.compile`.  In Knomosis's
Phase-3 implementation we instead return `CompiledAction`, a thin
wrapper that carries the originating `Action` alongside the kernel
`Transition`.  This makes `Action.compile_injective` a *one-line
structural proof* (`congrArg CompiledAction.source`) rather than a
hairy case-by-case discrimination — and it sidesteps the genuine
non-injectivity at the bare-`Transition` level (two `freezeResource`
constructors with different `r` values produce the same kernel
`Transition`, by design of Phase-2's no-op-marker freeze law; and
two vacuous actions like `transfer r s s 0` and `mint r s 0` have
extensionally equal compiled bodies).

The wrapper adds zero TCB surface: the kernel still operates on
plain `Transition` values.  Authority-layer callers project out the
transition via `(Action.compile a).transition`; the `source` field
lives outside the kernel and exists purely to make compile injective
on the nose.

The `Action` type is the boundary between the kernel's *operational*
representation (functions in `Transition`, which cannot be
canonically serialised) and the deployment's *external*
representation (CBOR bytes that can be signed, logged, and replayed).
Everything that crosses a network, a disk, or a signature lives in
`Action`-space; everything that crosses the kernel's executable path
lives in `Transition`-space (Genesis Plan §4.13).

This module is **not** part of the trusted computing base.  It is
deployment-facing infrastructure: a bug here can produce a wrong
`Transition` from an `Action`, but cannot violate any kernel
invariant (the kernel's proofs all bottom out at `Transition` and
its `decPre` field, regardless of how the `Transition` was built).

Coverage map:

  * WU 3.1 — `Action` inductive enumerating the deployed laws;
              `CompiledAction` wrapper; `Action.compile` mapping each
              constructor to a `CompiledAction`.
  * WU 3.2 — `Action.compile_injective`: a one-line structural proof
              via `congrArg CompiledAction.source`.

The `Action` constructors mirror the four Phase-2 laws verbatim, plus
a Phase-3 `replaceKey` constructor for WU 3.10 (registered under the
`replaceKey` action, applied via the authority layer).  Adding a new
law to a deployment requires:

  1. A new `Action` constructor here (with fields matching the law's
     scalar parameters).
  2. A new branch in `Action.compileTransition`.
  3. A new `IsConservative` instance (or an explicit non-conservation
     witness, like `mint_not_conservative`).
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Burn
import LegalKernel.Laws.Freeze
import LegalKernel.Laws.Reward
import LegalKernel.Laws.DistributeOthers
import LegalKernel.Laws.ProportionalDilute
import LegalKernel.Laws.Deposit
import LegalKernel.Laws.Withdraw
import LegalKernel.Laws.DepositWithFee
import LegalKernel.Laws.TopUpActionBudget
import LegalKernel.Laws.TopUpActionBudgetFor
import LegalKernel.Laws.ClaimBudgetRefund
import LegalKernel.Laws.AmmSwap
import LegalKernel.Laws.ReclaimAmmReserves
import LegalKernel.Authority.Crypto
import LegalKernel.Authority.LocalPolicy
import LegalKernel.Bridge.AddressBook
import LegalKernel.Bridge.State
import LegalKernel.Disputes.Types

namespace LegalKernel
namespace Authority

open LegalKernel.Disputes

/-! ## The `Action` inductive (§4.13 / WU 3.1) -/

/-- The set of actions a deployment recognises.  One constructor per
    law, each carrying only first-order data (scalars and IDs).

    Phase 3 ships five constructors mirroring the four Phase-2 laws
    (`transfer`, `mint`, `burn`, `freezeResource`) plus the Phase-3
    `replaceKey` action (WU 3.10) that re-points an `ActorId` to a new
    `PublicKey`.  The Phase-4-prelude positive-incentive WU adds three
    more (`reward`, `distributeOthers`, `proportionalDilute`).  Adding
    a constructor here is a deployment-level decision: the kernel
    never refers to `Action`; only the authority module does.

    **Constructor-ordering policy (append-only).**  Constructors are
    listed in the historical order in which they were introduced:

    * Phase 0 / Phase 2 (balance-mutating, kernel `State.balances`):
      `transfer`, `mint`, `burn`, `freezeResource`.
    * Phase 3 (registry-mutating, authority-level `KeyRegistry`,
      applied via `applyActionToRegistry` in `apply_admissible`):
      `replaceKey`.
    * Phase-4 prelude (positive-incentive balance-mutating, all
      classified `IsMonotonic`): `reward`, `distributeOthers`,
      `proportionalDilute`.

    **Indices are stable: every new constructor is appended at the
    end.**  This is the contract that Phase 4's CBOR encoder will
    rely on (constructors are encoded by their inductive index).
    Re-grouping constructors by what they touch — even when it would
    yield a tidier listing — is forbidden once a constructor has
    landed, because re-grouping would silently reassign indices and
    break any deployed serialised data.  Future additions must
    likewise append at the end.

    `DecidableEq` is needed so that `Action` can be hashed, signed, and
    compared at the runtime layer (Phase 5).  `Repr` is needed for the
    test suite's failure messages. -/
inductive Action
  /-- Move `amount` units of `r` from `sender` to `receiver`. -/
  | transfer (r : ResourceId) (sender receiver : ActorId) (amount : Amount)
  /-- Mint `amount` units of `r` into `to`'s balance. -/
  | mint (r : ResourceId) (to : ActorId) (amount : Amount)
  /-- Burn `amount` units of `r` from `fromActor`'s balance. -/
  | burn (r : ResourceId) (fromActor : ActorId) (amount : Amount)
  /-- Mark `r` as frozen (no-op at the kernel level; deployment commitment). -/
  | freezeResource (r : ResourceId)
  /-- Re-point `actor`'s identity to `newKey`, signed by the *old* key.
      Kernel-level effect is identity on `State`; the authority-level
      effect (registry update) happens in `apply_admissible`. -/
  | replaceKey (actor : ActorId) (newKey : PublicKey)
  /-- Reward `to` with `amount` units of `r` (positive-incentive
      analogue of `mint`; classified as `IsMonotonic`).  Distinct from
      `mint` at the Action layer so that authority policies can grant
      "may reward" permission independently from "may mint". -/
  | reward (r : ResourceId) (to : ActorId) (amount : Amount)
  /-- Distribute `amount` to every actor in `r`'s `BalanceMap` except
      `excluded`.  Empty/excluded-only resources are no-ops.
      Substitute for "fining `excluded` by the equivalent of `amount *
      k`" without removing tokens from `excluded`. -/
  | distributeOthers (r : ResourceId) (excluded : ActorId) (amount : Amount)
  /-- Proportionally dilute `excluded` by minting `totalReward * v_k /
      sumOthers` (Nat floor; dust discarded) to each non-excluded
      actor `k`.  The strongest analogue of "burning `excluded`'s
      balance share" available without removing tokens. -/
  | proportionalDilute (r : ResourceId) (excluded : ActorId) (totalReward : Amount)
  /-- File a dispute against a prior log entry (Phase 6 §8.4).  The
      dispute carries the challenger's claim plus the standard nonce
      + signature replay-protection envelope.  Kernel-level effect is
      the identity on `State`; the dispute pipeline (`fileDispute`,
      `checkEvidence`) reads the dispute's data from the log without
      mutating state. -/
  | dispute (d : Dispute)
  /-- Withdraw a previously-filed dispute by referencing its log
      index (Phase 6 §8.4 / WU 6.11).  Idempotent: filing
      `disputeWithdraw idx` against an already-decided or already-
      withdrawn dispute is a no-op at the kernel level (the
      withdrawal is recorded in the log but takes no effect on the
      already-closed dispute). -/
  | disputeWithdraw (idx : Disputes.LogIndex)
  /-- Apply a quorum-signed verdict (Phase 6 §8.4 / WU 6.9).  The
      verdict references the dispute log entry's index; if upheld,
      the runtime layer's `applyVerdict` function performs the
      rollback computation by replaying `log[0..idx-1]`.  Kernel-
      level effect is identity on `State`; the rollback semantics
      live in the runtime layer. -/
  | verdict (v : Verdict)
  /-- A rollback marker recording that the runtime restored state
      to the replay-target of `log[0..targetIdx-1]` after an upheld
      verdict (Phase 6 §8.4 / WU 6.10).  Appended to the log AFTER
      the runtime layer's `applyVerdict` performs the actual state
      replacement.  Kernel-level effect on `State` is identity; the
      runtime layer maintains a separate `rolledBackTo : Option
      LogIndex` field so subsequent replay produces the correct
      state.  The action exists primarily for audit-trail
      readability (a log scanner can detect rollback points without
      replaying the whole log). -/
  | rollback (targetIdx : Disputes.LogIndex)
  /-- Register a new identity (Workstream B §6.3 / Ethereum
      integration).  Authoritative analogue of `replaceKey` for
      *first-time* identity registrations: `replaceKey` is signed
      by the *old* key (so requires an existing registration);
      `registerIdentity` is signed by the deployment's bridge
      actor and inserts the new `(actor, pk)` mapping into the
      `KeyRegistry`.

      The kernel-level effect is identity on `State` (compiled to
      `Laws.freezeResource 0`); the authority-level effect is
      registry insertion via `applyActionToRegistry`.  The "first-
      time only" invariant (registry-empty-for-actor precondition)
      is enforced by the bridge runtime (Workstream B.2: the
      `AddressBook` only generates `registerIdentity` for fresh
      Ethereum addresses) and by deployment-configured
      `AuthorityPolicy` predicates that reject `registerIdentity`
      for already-registered actors.  The full type-level
      first-time-only theorem is reserved for Workstream C.4. -/
  | registerIdentity (actor : ActorId) (pk : PublicKey)
  /-- Bridge deposit (Workstream C.4 / §7.4) at frozen index 13.
      Credits `amount` units of resource `r` to `recipient` on L2,
      marking the L1 `depositId` as consumed.

      Kernel-level effect: `Laws.deposit`-shaped balance increment.
      Bridge-level effect: `BridgeState.consumed` is updated via
      `applyActionToBridgeState` (Workstream C.0).  The `depositId`
      uniqueness check lives at the bridge-admissibility layer
      (`BridgeAdmissibleWith`); the kernel-level precondition is
      trivial. -/
  | deposit (r : ResourceId) (recipient : ActorId)
            (amount : Amount) (depositId : Bridge.DepositId)
  /-- Bridge withdrawal (Workstream C.4 / §7.4) at frozen index 14.
      Debits `amount` units of resource `r` from `sender`'s balance
      and schedules an L1 redemption to `recipientL1`.

      Kernel-level effect: `Laws.withdraw`-shaped balance decrement
      (gated by sufficient-balance precondition).  Bridge-level
      effect: `BridgeState.pending` gains a `PendingWithdrawal`
      entry at `BridgeState.nextWdId`, and `nextWdId` is bumped,
      via `applyActionToBridgeState`. -/
  | withdraw (r : ResourceId) (sender : ActorId)
             (amount : Amount) (recipientL1 : Bridge.EthAddress)
  /-- LP.4: declare (or replace) the signer's local policy
      (Workstream LP §5.2) at frozen index 15.  Mutates the
      `ExtendedState.localPolicies` table to map the signer's
      `ActorId` to `policy`.  Idempotent on equal `policy`;
      replaces on differing `policy`.

      Kernel-level effect: `Laws.freezeResource 0` (no `base`-state
      effect).  Authority-level effect: `localPolicies` insertion
      via `applyActionToLocalPolicies` inside `apply_admissible`
      (LP.5).

      Signed by the actor whose policy is being set: the signer's
      `ActorId` (carried by `SignedAction.signer`) is what the
      runtime inserts into `localPolicies`.  A different actor
      signing this action sets *that signer*'s policy, not someone
      else's — there is no "set policy for actor X" capability
      short of revealing X's signing key. -/
  | declareLocalPolicy (policy : LocalPolicy)
  /-- LP.4: revoke the signer's local policy (Workstream LP §5.3)
      at frozen index 16.  Mutates the `ExtendedState.localPolicies`
      table to erase the signer's `ActorId` entry.  Idempotent:
      revoking a non-existent entry is a no-op.  Compiles to
      `Laws.freezeResource 0` at the kernel level.

      No fields: which actor is being revoked is the signer.  The
      meta-action exemption in admissibility (LP.7) ensures an
      actor can always revoke their own policy regardless of the
      policy's contents (the structural lockout-prevention proof). -/
  | revokeLocalPolicy
  /-- Workstream H §12.1 — fault-proof challenge intent (frozen
      index 17).  A user submits this action to record an intent
      to challenge the sequencer's published state root for the
      log range `[disputedStartIdx .. disputedEndIdx]`.

      `bindingHash` is a 32-byte content hash binding
      `(challenger, disputedStateRoot, challengerCommit,
      deploymentId)`.  The L1 contract `KnomosisFaultProofGame`
      assigns the actual `gameId` on `initiateChallenge`; the L2
      runtime's L1-event watcher matches L2 challenge intents to
      L1 games via this hash.

      Kernel-level effect: identity (compiles to
      `Laws.freezeResource 0`).  The L2 action is *advisory* — the
      L1 contract is the authoritative game state.  The
      `Disputes/Rewards.lean`-style policy hooks can still consume
      this action's emission to compose challenger rewards on
      successful resolution.

      Why a binding hash rather than a `gameId : Nat` field:
      the L1 contract assigns gameIds at `initiateChallenge` time,
      so the L2 challenger cannot know the gameId before the L1
      game exists.  The hash binds the L2 intent to an L1 game
      that is later opened with matching parameters. -/
  | faultProofChallenge (bindingHash : ByteArray)
                        (disputedStartIdx : Disputes.LogIndex)
                        (disputedEndIdx : Disputes.LogIndex)
                        (challengerCommit : ByteArray)
  /-- Workstream H §12.1 — fault-proof game settlement mirror
      (frozen index 18).  The L2 runtime's L1-event watcher
      receives a `FaultProofGameSettled` event from L1 and emits
      this action to record the settlement in the canonical L2
      log.  Carries the same `bindingHash` as the corresponding
      `faultProofChallenge`, plus the L1-assigned `gameId`,
      `winner`, and `revertFromIdx`.

      The actual rollback is **not** triggered by this L2 action;
      it is triggered by the L1 contract's
      `revertToPriorRoot` on the bridge.  This L2 action is
      advisory-only: replicas that don't watch L1 directly can
      still observe disputes through the canonical log.

      Kernel-level effect: identity (compiles to
      `Laws.freezeResource 0`).  Authority-level effect: none
      (no registry / nonce-table / bridge-state / local-policy
      mutation beyond the standard signer-nonce advance). -/
  | faultProofResolution (bindingHash : ByteArray) (gameId : Nat)
                          (winner : ActorId)
                          (revertFromIdx : Disputes.LogIndex)
  /-- Workstream GP §15E (v1.0) — bridge deposit with user-chosen
      fee split (frozen index 19).  An L1-event-derived Knomosis
      action emitted by the L1 watcher when a user calls
      `KnomosisBridge.depositETHWithFee` (or `depositBoldWithFee`)
      with a positive `userAmount` + `poolAmount` split.

      Fields:
        * `resource`       — the L2 resource being credited
                              (0 = ETH-mirror, 1 = BOLD-mirror).
        * `recipient`      — the L2 actor receiving the user
                              portion of the deposit + the
                              `budgetGrant` action-budget credit.
        * `poolActor`      — the actor receiving the pool portion
                              of the deposit (canonically the
                              `gasPoolActor`, GP.7.1 / ActorId 1).
        * `userAmount`     — units credited to `recipient`.
        * `poolAmount`     — units credited to `poolActor`.
        * `budgetGrant`    — action-budget units granted to
                              `recipient`'s epoch budget slot.
        * `depositId`      — the L1 deposit-receipt id (frozen by
                              the bridge to defend against replay).

      Kernel-level effect: `Laws.depositWithFee`-shaped balance
      increment of both `recipient` (`+userAmount`) and `poolActor`
      (`+poolAmount`) at `resource`.  Bridge-level effect:
      `BridgeState.consumed` is updated via
      `applyActionToBridgeState`'s bridge tag (mirroring
      `Action.deposit` semantics in v1.0; GP.4 widens to track the
      pool portion separately).  Budget-level effect:
      `recipient`'s `EpochBudgetState` slot is incremented by
      `budgetGrant` via the admission gate's per-action
      budget-grant arm (GP.3.2.d).

      Why `bridgeActor`-signed: the L1 contract pays the L1 gas and
      emits the on-chain `DepositWithFeeInitiated` event; the L2
      watcher re-encodes this as a `depositWithFee` action and signs
      it as `bridgeActor` (GP.5).  This makes the action L1-gas-gated
      upstream — the GP.3.2.c bridgeActor exemption keeps it
      admissible even when bridgeActor's L2 budget would otherwise
      be empty. -/
  | depositWithFee (resource : ResourceId) (recipient : ActorId)
                    (poolActor : ActorId)
                    (userAmount : Amount) (poolAmount : Amount)
                    (budgetGrant : Nat)
                    (depositId : Bridge.DepositId)
  /-- Workstream GP §15E (v1.0) — L2 user self-topup of the
      action-budget (frozen index 20).  A user signs this action
      to convert a gas-resource balance into action-budget units,
      e.g. when their epoch budget is low and they want to
      continue acting without waiting for the next epoch
      boundary.

      Fields:
        * `gasResource`     — the resource used for payment
                               (0 = ETH-mirror, 1 = BOLD-mirror).
        * `gasAmount`       — units of `gasResource` debited from
                               the signer's balance.
        * `budgetIncrement` — action-budget units credited to the
                               signer's epoch budget slot.
        * `poolActor`       — the actor receiving the gas payment
                               (canonically the `gasPoolActor`,
                               GP.7.1 / ActorId 1).

      The signer is the actor whose budget is incremented; the
      signer's `ActorId` is NOT carried as a field — it is captured
      by the enclosing `SignedAction` per the standard Phase-3
      signed-action pattern.

      Kernel-level effect: `Laws.topUpActionBudget`-shaped balance
      transfer from `signer` to `poolActor` at `gasResource`
      (gated by the existing-balance precondition).
      Budget-level effect: the signer's `EpochBudgetState` slot is
      incremented by `budgetIncrement` (after the +1 budget
      consumption for the topup action itself), via the admission
      gate's per-action budget-grant arm (GP.3.2.d).  A signer with
      zero budget cannot top up unless their normalised free-tier
      budget covers the +1 cost. -/
  | topUpActionBudget (gasResource : ResourceId) (gasAmount : Amount)
                       (budgetIncrement : Nat) (poolActor : ActorId)
  /-- Workstream GP §15E (GP.3.4) — pre-authorised *delegated* L2
      action-budget top-up (frozen index 21).  A delegate (the
      signer) converts a gas-resource balance into action-budget
      units credited to a *different* actor's (`recipient`'s) epoch
      budget slot, provided `recipient` has pre-authorised the
      signer via an `allowTopUpFrom` clause in `recipient`'s declared
      `LocalPolicy` (default-deny: no clause ⇒ rejected).

      Fields:
        * `recipient`       — the L2 actor whose epoch budget is
                               credited by `budgetIncrement`.  Must
                               differ from the signer (self-top-up
                               goes through `topUpActionBudget`).
        * `gasResource`     — the resource used for payment
                               (0 = ETH-mirror, 1 = BOLD-mirror).
        * `gasAmount`       — units of `gasResource` debited from the
                               *signer*'s balance (the signer pays;
                               the recipient never loses funds).
        * `budgetIncrement` — action-budget units credited to
                               `recipient`'s epoch budget slot.
        * `poolActor`       — the actor receiving the gas payment
                               (canonically the `gasPoolActor`,
                               GP.7.1 / ActorId 1).

      The signer is the delegate paying the gas; the signer's
      `ActorId` is NOT a field — it is captured by the enclosing
      `SignedAction` per the standard Phase-3 signed-action pattern.

      Kernel-level effect: `Laws.topUpActionBudgetFor`-shaped balance
      transfer from `signer` to `poolActor` at `gasResource` (gated
      by the existing-balance + `recipient ≠ signer` precondition).
      Budget-level effect: the *recipient*'s `EpochBudgetState` slot
      is incremented by `budgetIncrement`, via the admission gate's
      per-action budget-grant arm (GP.3.4).  The recipient-consent
      check (signer ∈ recipient's `allowTopUpFrom` list) is enforced
      at the admission gate alongside the gas-safety checks. -/
  | topUpActionBudgetFor (recipient : ActorId) (gasResource : ResourceId)
                         (gasAmount : Amount) (budgetIncrement : Nat)
                         (poolActor : ActorId)
  /-- Workstream GP §15E (GP.9.1) — refund-on-exit (frozen index 22).
      A user (the signer / claimant) retires `budgetUnits` of their own
      remaining, *purchased* action budget in exchange for a gas-resource
      payout `refundAmount = budgetUnits × weiPerBudgetUnit`, paid out of
      the gas pool (`poolActor`, canonically `gasPoolActor`, GP.7.1).

      Fields:
        * `gasResource`      — the gas leg the refund is paid in
                                (0 = ETH-mirror, 1 = BOLD-mirror).
        * `budgetUnits`      — the amount of remaining action-budget the
                                claimant retires.  Bounded by the admission
                                gate to the claimant's `refundableBudget`
                                (the purchased budget above the free tier),
                                so the per-epoch free-tier subsidy is never
                                refundable.
        * `weiPerBudgetUnit` — the exchange rate.  Pinned by the admission
                                gate to the deployment's trusted per-resource
                                rate (the same rate the GP.5.1 / GP.5.4
                                deposit grant uses), so a refund cannot
                                inflate its own payout — `weiPerBudgetUnit`
                                is carried as a field only so the kernel-leg
                                amount `budgetUnits × weiPerBudgetUnit` is
                                computable from the logged action (replay /
                                fault-proof determinism), NOT so the user
                                may choose it.
        * `poolActor`        — the actor the refund is paid from
                                (pinned to `gasPoolActor` by the gate).

      The signer (claimant) is the enclosing `SignedAction.signer`, per
      the standard Phase-3 signed-action pattern — never a field.

      Kernel-level effect: `Laws.claimBudgetRefund`-shaped balance
      transfer from `poolActor` to the signer at `gasResource`, of
      `budgetUnits × weiPerBudgetUnit` (gated by pool solvency).  This is
      the MIRROR of `topUpActionBudget` (which moves
      `signer → poolActor`); the refund moves `poolActor → signer`.
      Budget-level effect: the signer's `EpochBudgetState` slot is
      DEBITED by `actionCost + budgetUnits` via the admission gate's
      refund consume (the standard per-action cost PLUS the retired
      units), leaving the signer at or above the free tier. -/
  | claimBudgetRefund (gasResource : ResourceId) (budgetUnits : Nat)
                      (weiPerBudgetUnit : Nat) (poolActor : ActorId)
  /-- Workstream GP (GP.11.4): L2 AMM swap action.  A bridge-attested
      constant-product ETH↔BOLD exchange mirroring the L1
      `KnomosisBridge.ammSwap`.  The kernel-level effect credits
      `ammReserveActor` at `fromResource` by `amountIn` and debits
      `ammReserveActor` at `toResource` by `amountOut`.  The swap-math
      (`getAmountOut`, k-monotonicity, no-drain) is authoritative at L1;
      the L2 action records the already-computed amounts attested by the
      bridge actor.  Frozen action index 23. -/
  | ammSwap (fromResource toResource : ResourceId) (amountIn amountOut : Amount)
            (ammReserveActor : ActorId)
  /-- Workstream GP (GP.11.10): post-disable AMM reserve reclamation.
      A bridge-attested EXACT SWEEP of the disabled AMM's frozen L2
      reserve balance at one resource into the gas-pool actor: the
      kernel-level effect debits `reserveActor` at `r` by `amount`
      (its entire balance, by the law's exact-sweep precondition) and
      credits `poolActor` the same `amount`.  Admissible only after
      the L1 `emergencyDisableAmm()` kill switch is mirrored on L2
      (`BridgeAdmissibleWith` conjunct 9 requires
      `es.bridge.ammDisabled = true` and pins the threaded actors to
      the canonical `ammReserveActor` / `gasPoolActor`).  Frozen
      action index 24. -/
  | reclaimAmmReserves (r : ResourceId) (amount : Amount)
                       (reserveActor poolActor : ActorId)
  -- Workstream-LX (LX.17): codegen-managed Lex constructors land
  -- between the fence markers below.  M1's example law (frozen
  -- index 17) deliberately does not extend `Action` — it lives
  -- in the JSON sidecar registry only — so the fence is empty in
  -- M1.  M2 (LX.22 – LX.30) populates this fence as the kernel-
  -- built-in laws are re-expressed in Lex.
  -- Workstream H reserves indices 17 and 18; Workstream GP reserves
  -- indices 19 (`depositWithFee`), 20 (`topUpActionBudget`),
  -- 21 (`topUpActionBudgetFor`), 22 (`claimBudgetRefund`),
  -- 23 (`ammSwap`), and 24 (`reclaimAmmReserves`).
  -- Future Lex-generated ctors (M2+) will append at index 25+.
  -- BEGIN LEX-GENERATED (do not edit by hand)
  -- END LEX-GENERATED
  deriving Repr, DecidableEq

/-! ## Compilation to kernel `Transition`s (§4.13 / WU 3.1) -/

/-- The raw transition compiler: maps each `Action` constructor to
    the corresponding kernel `Transition`.  Cases:

    * `transfer`            → `Laws.transfer`
    * `mint`                → `Laws.mint`
    * `burn`                → `Laws.burn`
    * `freezeResource`      → `Laws.freezeResource`
    * `replaceKey`          → `Laws.freezeResource 0`  (kernel-level no-op;
                               the authority-level effect happens in
                               `apply_admissible`).
    * `reward`              → `Laws.reward`             (positive-incentive credit)
    * `distributeOthers`    → `Laws.distributeOthers`   (uniform reward)
    * `proportionalDilute`  → `Laws.proportionalDilute` (proportional reward)

    This function is *not injective* on its own — the `freezeResource`
    constructor was deliberately designed in Phase 2 to ignore its
    `r` parameter (so `Laws.freezeResource r₁ = Laws.freezeResource r₂`
    for all `r₁`, `r₂`).  Callers that need injectivity must use the
    `Action.compile`/`CompiledAction` wrapper below, which carries the
    originating `Action` as a separate `source` field. -/
def Action.compileTransition : Action → Transition
  | .transfer r s r' a            => Laws.transfer r s r' a
  | .mint r to a                  => Laws.mint r to a
  | .burn r fr a                  => Laws.burn r fr a
  | .freezeResource r             => Laws.freezeResource r
  | .replaceKey _ _               => Laws.freezeResource 0
  | .reward r to a                => Laws.reward r to a
  | .distributeOthers r e a       => Laws.distributeOthers r e a
  | .proportionalDilute r e tr    => Laws.proportionalDilute r e tr
  -- Phase-6 dispute-pipeline actions: kernel-level no-ops.  The
  -- authority-level / runtime-level effects (recording the dispute,
  -- closing the dispute, applying the verdict, performing the
  -- rollback) all happen outside `apply_admissible`, in the dispute
  -- pipeline modules under `LegalKernel/Disputes/`.
  | .dispute _                    => Laws.freezeResource 0
  | .disputeWithdraw _             => Laws.freezeResource 0
  | .verdict _                    => Laws.freezeResource 0
  | .rollback _                   => Laws.freezeResource 0
  -- Workstream B: identity registration.  Kernel-level no-op; the
  -- registry mutation happens in `applyActionToRegistry` inside
  -- `apply_admissible`.  Mirrors `replaceKey`'s compile semantics.
  | .registerIdentity _ _         => Laws.freezeResource 0
  -- Workstream C: bridge actions.  Compile to the corresponding
  -- balance-mutating laws.  The bridge-level effects (`consumed`
  -- map insertion, `pending` map insertion + `nextWdId` bump) are
  -- handled separately by `applyActionToBridgeState` inside
  -- `apply_bridge_admissible_with`.
  | .deposit r recipient amount d   => Laws.deposit  r recipient amount d
  | .withdraw r sender amount rcp   => Laws.withdraw r sender amount rcp
  -- Workstream LP: actor-scoped local-policy actions.  Both compile
  -- to the kernel-level no-op (`Laws.freezeResource 0`).  The
  -- authority-level effect (`localPolicies` mutation) lives in
  -- `applyActionToLocalPolicies` inside `apply_admissible` (LP.5).
  | .declareLocalPolicy _           => Laws.freezeResource 0
  | .revokeLocalPolicy              => Laws.freezeResource 0
  -- Workstream H: fault-proof actions.  Both compile to the
  -- kernel-level no-op.  The L1 game contract is authoritative
  -- for fault-proof game outcomes; the L2 actions are advisory.
  | .faultProofChallenge _ _ _ _    => Laws.freezeResource 0
  | .faultProofResolution _ _ _ _   => Laws.freezeResource 0
  -- Workstream GP (v1.0): bridge deposit with fee split.  Compiles
  -- to the signer-independent `Laws.depositWithFee` law, which
  -- directly produces the kernel-level effect (credit recipient
  -- by `userAmount`, credit poolActor by `poolAmount`).  The
  -- budget-level effect (granting `budgetGrant` to `recipient`)
  -- is applied separately by the admission layer's per-action
  -- budget-grant arm (GP.3.2.d in `apply_admissible_with_budget`).
  | .depositWithFee r recipient poolActor userAmount poolAmount
                     budgetGrant depositId =>
      Laws.depositWithFee r recipient poolActor userAmount poolAmount
                            budgetGrant depositId
  -- Workstream GP (v1.0): L2 user self-topup.  Compiles to the
  -- kernel-level no-op `Laws.freezeResource 0`.  The signer-aware
  -- kernel effect (debit signer's gas balance, credit poolActor)
  -- is applied separately by `kernelOnlyApply` and by
  -- `apply_admissible_with_budget` (GP.3.2.d) — both have the
  -- signer in scope (from `SignedAction.signer`) and thread it
  -- into `Laws.topUpActionBudget`'s first parameter.  This
  -- mirrors the design used by `replaceKey` and
  -- `registerIdentity`: kernel-level no-op, with the
  -- authority/admission-level effect applied by a separate
  -- helper that has the signer in scope. -/
  | .topUpActionBudget _ _ _ _    => Laws.freezeResource 0
  -- Workstream GP (GP.3.4): delegated top-up.  Like
  -- `topUpActionBudget`, the kernel-level effect is signer-aware
  -- (the signer is the payer), so the signer-unaware
  -- `compileTransition` returns the kernel-level no-op
  -- `Laws.freezeResource 0`.  The real signer-bound effect
  -- (`Laws.topUpActionBudgetFor recipient signer ...`) is applied
  -- by `Action.toTransition` / `kernelOnlyApply` /
  -- `apply_admissible_with`, all of which have the signer in scope.
  | .topUpActionBudgetFor _ _ _ _ _ => Laws.freezeResource 0
  -- Workstream GP (GP.9.1): refund-on-exit.  Like the two top-up
  -- variants, the kernel-level effect is signer-aware (the signer is
  -- the claimant, credited from the pool), so the signer-unaware
  -- `compileTransition` returns the kernel-level no-op
  -- `Laws.freezeResource 0`.  The real signer-bound effect
  -- (`Laws.claimBudgetRefund signer poolActor gasResource
  -- (budgetUnits × weiPerBudgetUnit)`) is applied by
  -- `Action.toTransition` / `kernelOnlyApply` /
  -- `apply_admissible_with`, all of which have the signer in scope.
  | .claimBudgetRefund _ _ _ _      => Laws.freezeResource 0
  -- Workstream GP (GP.11.4): L2 AMM swap.  The swap is NOT
  -- signer-aware (both amounts are bridge-attested), so it compiles
  -- directly to the kernel law.
  | .ammSwap fr tr ai ao ra         => Laws.ammSwap fr tr ai ao ra
  -- Workstream GP (GP.11.10): post-disable reserve reclamation.  Like
  -- ammSwap, the sweep is NOT signer-aware (the amount and both actors
  -- are bridge-attested action fields), so it compiles directly to the
  -- kernel law.
  | .reclaimAmmReserves r amt ra pa => Laws.reclaimAmmReserves r amt ra pa
  -- Workstream-LX (LX.17): codegen-managed Lex `compileTransition`
  -- arms land between the fence markers below.  Empty in M1;
  -- populated in M2 once the kernel-built-in laws are re-expressed
  -- in Lex.
  -- BEGIN LEX-GENERATED (do not edit by hand)
  -- END LEX-GENERATED

/-! ## The `CompiledAction` wrapper -/

/-- An `Action` paired with its kernel `Transition`.  Carrying the
    originating `Action` in the `source` field is what makes
    `Action.compile_injective` a one-line structural proof: distinct
    actions necessarily have distinct `source` projections.

    The `transition` field is what the kernel actually executes; the
    `source` field exists purely for the structural-identification
    invariant.  At extraction time (Phase 5), the `source` field is
    erased; only `transition` carries runtime weight. -/
structure CompiledAction where
  /-- The originating `Action`.  Trivially distinguishes distinct
      compiled actions: `(a₁ : CompiledAction) = (a₂ : CompiledAction)`
      forces `a₁.source = a₂.source`. -/
  source     : Action
  /-- The kernel `Transition` that the source compiles to.  This is
      what `apply_admissible` actually executes against `State`. -/
  transition : Transition

/-- The deployment-supplied compilation function: produces the
    `(source, transition)` pair for each action.  Phase-3 callers
    typically project out `transition` immediately for kernel-level
    work, while injectivity proofs read off the `source` field.

    The kernel never executes this function; it is supplied per
    deployment and audited as part of the law set. -/
def Action.compile (a : Action) : CompiledAction where
  source     := a
  transition := Action.compileTransition a

/-! ## Signer-aware compilation (GP.2.3 / Workstream GP §15E v1.0) -/

/-- Signer-aware analogue of `Action.compileTransition`.  For most
    actions, the kernel-level transition is signer-independent and
    this function returns the same result as `compileTransition`.
    For actions whose kernel-level effect depends on the signer
    (specifically `topUpActionBudget`, whose `Laws.topUpActionBudget`
    law takes the *payer*'s `ActorId` as its first parameter), this
    function threads the signer (provided by the enclosing
    `SignedAction`) into the law's parameter list.

    The runtime entry points `apply_admissible_with` (kernel-only)
    and `apply_bridge_admissible_with` (bridge-aware) use the
    signer-aware transition for the kernel step; the dispute
    pipeline's `kernelOnlyApply` mirrors this choice so the
    `apply_admissible_with_eq_kernelOnlyApply` equivalence holds.

    This function is **not** part of the trusted computing base:
    bugs here produce wrong kernel-step semantics for
    `topUpActionBudget`, but cannot violate any kernel invariant
    (the kernel's proofs bottom out at `Transition`, which
    `toTransition` returns).

    Use this function (NOT `compileTransition`) for any runtime
    call site that has a `SignedAction.signer` in scope.  For
    Lex DSL callers that lack the signer, fall back to
    `compileTransition`; the result is correct for every action
    EXCEPT `topUpActionBudget`, where the placeholder
    `Laws.freezeResource 0` is returned instead of the
    signer-bound `Laws.topUpActionBudget signer ...`. -/
def Action.toTransition (a : Action) (signer : ActorId) : Transition :=
  match a with
  | .topUpActionBudget gasResource gasAmount budgetIncrement poolActor =>
      Laws.topUpActionBudget signer gasResource gasAmount budgetIncrement poolActor
  | .topUpActionBudgetFor recipient gasResource gasAmount budgetIncrement poolActor =>
      Laws.topUpActionBudgetFor recipient signer gasResource gasAmount
        budgetIncrement poolActor
  | .claimBudgetRefund gasResource budgetUnits weiPerBudgetUnit poolActor =>
      -- GP.9.1: the claimant (signer) is credited `budgetUnits ×
      -- weiPerBudgetUnit` out of `poolActor` at `gasResource`.  The
      -- amount is computed from the action's (gate-verified) fields, so
      -- the kernel step is reproducible from the logged action alone.
      Laws.claimBudgetRefund signer poolActor gasResource
        (budgetUnits * weiPerBudgetUnit)
  | _ => Action.compileTransition a

/-- For every action that is none of the three signer-aware actions
    (`topUpActionBudget`, `topUpActionBudgetFor`, `claimBudgetRefund`),
    `Action.toTransition` coincides with `Action.compileTransition`
    regardless of signer.  This is the load-bearing equation
    downstream theorems use to reduce signer-aware reasoning to the
    signer-unaware compile path for actions whose kernel-level
    semantics doesn't depend on the signer. -/
theorem Action.toTransition_eq_compileTransition_of_ne_topUp
    (a : Action) (signer : ActorId)
    (hne : ∀ gr ga bi pa, a ≠ .topUpActionBudget gr ga bi pa)
    (hneFor : ∀ recipient gr ga bi pa,
      a ≠ .topUpActionBudgetFor recipient gr ga bi pa)
    (hneRefund : ∀ gr bu w pa, a ≠ .claimBudgetRefund gr bu w pa) :
    Action.toTransition a signer = Action.compileTransition a := by
  unfold Action.toTransition
  cases hact : a with
  | topUpActionBudget gr ga bi pa => exact absurd hact (hne gr ga bi pa)
  | topUpActionBudgetFor recipient gr ga bi pa =>
      exact absurd hact (hneFor recipient gr ga bi pa)
  | claimBudgetRefund gr bu w pa => exact absurd hact (hneRefund gr bu w pa)
  | transfer _ _ _ _              => rfl
  | mint _ _ _                    => rfl
  | burn _ _ _                    => rfl
  | freezeResource _              => rfl
  | replaceKey _ _                => rfl
  | reward _ _ _                  => rfl
  | distributeOthers _ _ _        => rfl
  | proportionalDilute _ _ _      => rfl
  | dispute _                     => rfl
  | disputeWithdraw _             => rfl
  | verdict _                     => rfl
  | rollback _                    => rfl
  | registerIdentity _ _          => rfl
  | deposit _ _ _ _               => rfl
  | withdraw _ _ _ _              => rfl
  | declareLocalPolicy _          => rfl
  | revokeLocalPolicy             => rfl
  | faultProofChallenge _ _ _ _   => rfl
  | faultProofResolution _ _ _ _  => rfl
  | depositWithFee _ _ _ _ _ _ _  => rfl
  | ammSwap _ _ _ _ _             => rfl
  | reclaimAmmReserves _ _ _ _    => rfl

/-- For `topUpActionBudget` specifically, `toTransition` produces
    the signer-bound `Laws.topUpActionBudget` form. -/
theorem Action.toTransition_topUpActionBudget
    (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) (signer : ActorId) :
    Action.toTransition (.topUpActionBudget gasResource gasAmount
                          budgetIncrement poolActor) signer =
    Laws.topUpActionBudget signer gasResource gasAmount budgetIncrement poolActor := rfl

/-- For `topUpActionBudgetFor` specifically, `toTransition` produces
    the signer-bound `Laws.topUpActionBudgetFor` form (the signer is
    the delegate/payer; the `recipient` field is the budget target). -/
theorem Action.toTransition_topUpActionBudgetFor
    (recipient : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) (signer : ActorId) :
    Action.toTransition (.topUpActionBudgetFor recipient gasResource gasAmount
                          budgetIncrement poolActor) signer =
    Laws.topUpActionBudgetFor recipient signer gasResource gasAmount
      budgetIncrement poolActor := rfl

/-- For `claimBudgetRefund` specifically, `toTransition` produces the
    signer-bound `Laws.claimBudgetRefund` form, with the kernel-leg
    `refundAmount` computed as `budgetUnits × weiPerBudgetUnit` from the
    action's fields (the signer is the claimant credited from the pool). -/
theorem Action.toTransition_claimBudgetRefund
    (gasResource : ResourceId) (budgetUnits weiPerBudgetUnit : Nat)
    (poolActor : ActorId) (signer : ActorId) :
    Action.toTransition (.claimBudgetRefund gasResource budgetUnits
                          weiPerBudgetUnit poolActor) signer =
    Laws.claimBudgetRefund signer poolActor gasResource
      (budgetUnits * weiPerBudgetUnit) := rfl

/-! ## Compilation injectivity (§4.13 / WU 3.2)

The redesigned `Action.compile : Action → CompiledAction` makes
injectivity a one-line structural fact.  The `source` field of
`CompiledAction` is a faithful copy of the input `Action`, so two
equal compiled actions necessarily have equal sources.

This sidesteps the Phase-2 design choice to make `Laws.freezeResource`
ignore its `r` parameter (which broke injectivity at the bare
`Transition` level), and the corresponding Phase-3 design choice to
compile `replaceKey` actions to the same identity `Transition` (the
authority-level effect happens in `apply_admissible`, not in the
compiled `Transition`).  Both choices remain in place — they are
load-bearing for the kernel's invariant proofs — and the
`CompiledAction` wrapper recovers the injectivity property at the
authority layer where it actually matters.

**Why this is sufficient for security.**  The signature is computed
over the canonical encoding of `(action, signer, nonce)` (Genesis
Plan §8.2 condition 3); admissibility's `authorized` predicate also
operates on `Action` values.  So distinct actions are distinguishable
at every authority-layer check, regardless of whether their compiled
transitions happen to coincide.  The `compile_injective` theorem
provides a *type-level* sanity check on top of these runtime
distinctions. -/

/-- §4.13 / WU 3.2: structural injectivity of `Action.compile`.
    The proof is a single `congrArg` on the `source` projection of
    `CompiledAction`.  No discrimination lemmas are needed — the
    `source` field IS the originating action, so equal compiled
    actions trivially have equal sources. -/
theorem Action.compile_injective : Function.Injective Action.compile :=
  fun _ _ h => congrArg CompiledAction.source h

/-- A direct-form companion to `compile_injective`, useful at call
    sites that work with explicit equalities rather than the
    `Function.Injective` wrapper.  Same one-line proof. -/
theorem Action.compile_eq_iff (a₁ a₂ : Action) :
    Action.compile a₁ = Action.compile a₂ ↔ a₁ = a₂ :=
  ⟨fun h => Action.compile_injective h, fun h => h ▸ rfl⟩

/-- The contrapositive form: distinct actions necessarily produce
    distinct compiled actions.  Useful for security-relevant call
    sites that want to reason "two distinct signed actions cannot
    share a compiled transition path" symbolically. -/
theorem Action.compile_ne_of_ne (a₁ a₂ : Action) (h : a₁ ≠ a₂) :
    Action.compile a₁ ≠ Action.compile a₂ :=
  fun heq => h (Action.compile_injective heq)

/-! ## Convenience accessors -/

/-- Project the kernel `Transition` out of a compiled action.  Most
    Phase-3 / Phase-5 call sites will use this rather than reading
    `.transition` directly. -/
@[inline] def CompiledAction.kernelTransition (ca : CompiledAction) : Transition :=
  ca.transition

/-- The kernel-level precondition of an action's compiled transition,
    evaluated at a given state. -/
@[inline] def Action.pre (a : Action) (s : State) : Prop :=
  (Action.compileTransition a).pre s

/-- Decidability of `Action.pre`, lifted from the underlying
    `Transition.decPre` field. -/
instance Action.decPre (a : Action) (s : State) : Decidable (Action.pre a s) :=
  (Action.compileTransition a).decPre s

/-- The kernel-level state transformer for an action.  Wraps the
    underlying `Transition.apply_impl`. -/
@[inline] def Action.apply_impl (a : Action) (s : State) : State :=
  (Action.compileTransition a).apply_impl s

/-! ## Sanity smoke checks (`example`s)

The `example` declarations below are compile-time-only: if the
`compile`/`source` agreement breaks (e.g. someone refactors
`Action.compile` to drop the `source` field), elaboration fails and
the build catches the regression. -/

example (r : ResourceId) (s r' : ActorId) (am : Amount) :
    (Action.compile (.transfer r s r' am)).source = .transfer r s r' am := rfl

example (r : ResourceId) (to : ActorId) (am : Amount) :
    (Action.compile (.mint r to am)).source = .mint r to am := rfl

example (r : ResourceId) (fr : ActorId) (am : Amount) :
    (Action.compile (.burn r fr am)).source = .burn r fr am := rfl

example (r : ResourceId) :
    (Action.compile (.freezeResource r)).source = .freezeResource r := rfl

example (actor : ActorId) (newKey : PublicKey) :
    (Action.compile (.replaceKey actor newKey)).source = .replaceKey actor newKey := rfl

example (r : ResourceId) (to : ActorId) (am : Amount) :
    (Action.compile (.reward r to am)).source = .reward r to am := rfl

example (r : ResourceId) (e : ActorId) (am : Amount) :
    (Action.compile (.distributeOthers r e am)).source =
      .distributeOthers r e am := rfl

example (r : ResourceId) (e : ActorId) (tr : Amount) :
    (Action.compile (.proportionalDilute r e tr)).source =
      .proportionalDilute r e tr := rfl

example (d : Disputes.Dispute) :
    (Action.compile (.dispute d)).source = .dispute d := rfl

example (idx : Disputes.LogIndex) :
    (Action.compile (.disputeWithdraw idx)).source = .disputeWithdraw idx := rfl

example (v : Disputes.Verdict) :
    (Action.compile (.verdict v)).source = .verdict v := rfl

example (idx : Disputes.LogIndex) :
    (Action.compile (.rollback idx)).source = .rollback idx := rfl

example (actor : ActorId) (pk : PublicKey) :
    (Action.compile (.registerIdentity actor pk)).source =
      .registerIdentity actor pk := rfl

example (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (d : Bridge.DepositId) :
    (Action.compile (.deposit r recipient amount d)).source =
      .deposit r recipient amount d := rfl

example (r : ResourceId) (sender : ActorId) (amount : Amount)
    (rcp : Bridge.EthAddress) :
    (Action.compile (.withdraw r sender amount rcp)).source =
      .withdraw r sender amount rcp := rfl

example (p : LocalPolicy) :
    (Action.compile (.declareLocalPolicy p)).source =
      .declareLocalPolicy p := rfl

example :
    (Action.compile .revokeLocalPolicy).source = .revokeLocalPolicy := rfl

example (bh : ByteArray) (s e : Disputes.LogIndex) (cc : ByteArray) :
    (Action.compile (.faultProofChallenge bh s e cc)).source =
      .faultProofChallenge bh s e cc := rfl

example (bh : ByteArray) (gid : Nat) (w : ActorId) (rfi : Disputes.LogIndex) :
    (Action.compile (.faultProofResolution bh gid w rfi)).source =
      .faultProofResolution bh gid w rfi := rfl

example (r : ResourceId) (recipient poolActor : ActorId)
    (ua pa : Amount) (bg : Nat) (d : Bridge.DepositId) :
    (Action.compile (.depositWithFee r recipient poolActor ua pa bg d)).source =
      .depositWithFee r recipient poolActor ua pa bg d := rfl

example (gr : ResourceId) (ga : Amount) (bi : Nat) (pa : ActorId) :
    (Action.compile (.topUpActionBudget gr ga bi pa)).source =
      .topUpActionBudget gr ga bi pa := rfl

example (recipient : ActorId) (gr : ResourceId) (ga : Amount) (bi : Nat) (pa : ActorId) :
    (Action.compile (.topUpActionBudgetFor recipient gr ga bi pa)).source =
      .topUpActionBudgetFor recipient gr ga bi pa := rfl

example (gr : ResourceId) (bu : Nat) (w : Nat) (pa : ActorId) :
    (Action.compile (.claimBudgetRefund gr bu w pa)).source =
      .claimBudgetRefund gr bu w pa := rfl

example (r : ResourceId) (amt : Amount) (ra pa : ActorId) :
    (Action.compile (.reclaimAmmReserves r amt ra pa)).source =
      .reclaimAmmReserves r amt ra pa := rfl

end Authority
end LegalKernel
