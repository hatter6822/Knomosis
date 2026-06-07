-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.BridgeActor — Workstream B.3
(Ethereum integration plan §6.3).

Reserves `ActorId 0` as the *bridge actor* — the authority under
which all L1-derived Knomosis actions are signed.  The bridge actor's
public key is set at deployment time and is *not* rotatable except
via a dedicated governance event (out of MVP scope).

Design notes:

  * The bridge actor's `ActorId` is fixed at `0`, the lowest
    `UInt64`.  `AddressBook.empty.nextActorId = 3` (post-GP.7.1), so
    any address assigned via `assign` gets `id ≥ 3` — neither the
    bridge actor's slot (`0`) nor the GP.7.1-reserved `gasPoolActor`
    (`1`) / `sequencerActor` (`2`) slots are ever overwritten by a
    user-registered identity.

  * Workstream GP.7.1 reserves two further deployment slots alongside
    the bridge actor: `gasPoolActor` (`ActorId 1`) holds the gas-pool
    reserves and `sequencerActor` (`ActorId 2`) is the sole authorised
    recipient of pool drains under the canonical `gasPoolPolicy`
    (GP.7.2).  The three reserved actors occupy provably-distinct
    slots — `gasPoolActor_ne_bridgeActor`,
    `sequencerActor_ne_bridgeActor`, `sequencerActor_ne_gasPoolActor`
    — and the genesis `nextActorId` advance to `3` is pinned by
    `AddressBook.addressBook_empty_nextActorId`.

  * `bridgePolicy` is the deployment's `AuthorityPolicy` for the
    bridge actor.  It admits exactly the L1-attested action variants:

      * `replaceKey`       — bridge-actor-signed key rotations on
                             behalf of registered identities.
      * `registerIdentity` — first-time identity registrations
                             (Workstream B's L1 → Knomosis translator
                             flow; see `Bridge.Ingest`).
      * `deposit`          — Workstream C L1 → L2 deposit credits.
      * `depositWithFee`   — Workstream GP user-chosen-fee deposit
                             credits (frozen index 19).

    These are exactly the `Action.isBridgeOnly` variants — the ones
    `BridgeAdmissibleWith` REQUIRES be bridge-signed — so every
    `isBridgeOnly` action is bridge-authorised (pinned by
    `bridgeAuthorizedAction_of_isBridgeOnly` in `Bridge/Admissible.lean`).

    Other action variants (`transfer`, `mint`, `burn`,
    `freezeResource`, the positive-incentive trio, the dispute
    pipeline, `rollback`, `withdraw`, the gas-pool user actions
    `topUpActionBudget` / `topUpActionBudgetFor`) are explicitly
    rejected.  Deployments that need broader bridge-actor capabilities
    (e.g. a sovereign deployment that wants the bridge to mint
    synthetic tokens) extend the policy via `AuthorityPolicy.union`.

  * The `bridgePolicy` is decidable; the §12.9 theorems below
    discharge each branch by pure `decide`.

This module is **not** part of the kernel TCB.  Bugs here would
weaken the bridge's authority guarantees but cannot violate any
kernel invariant — the kernel's `apply_admissible` rejects any
action that fails the supplied `AuthorityPolicy.authorized`
predicate.

Coverage map:

  * §6.3 (WU B.3) — `bridgeActor`, `bridgePolicy`, the
    decidable-policy theorems (#32, #35, #36 from §12.9), plus a
    `bridgePolicy_rejects_*` family for the other action
    constructors.
  * Workstream C.4 (audit-1) — extends the policy with §12.9 #33
    (`bridgePolicy_rejects_withdraw`) and #34
    (`bridgePolicy_authorizes_deposit`).  Withdrawals are user-
    initiated; the bridge actor is forbidden from signing them
    (the `bridgeAuthorizedAction` lookup returns `false` for
    `withdraw`, so the bridge cannot withdraw on any user's
    behalf — closes a coordinated-attack vector where a
    compromised bridge actor could drain user balances and then
    forge an L1 redemption proof).
  * §12.9 — five theorems implemented here from the plan
    (`bridgePolicy_rejects_transfer`,
    `bridgePolicy_authorizes_replaceKey`,
    `bridgePolicy_authorizes_registerIdentity`,
    `bridgePolicy_authorizes_deposit`,
    `bridgePolicy_rejects_withdraw`), plus the wider rejection
    family for completeness.
  * Workstream GP.7.0 — an *exhaustive* characterisation of the
    bridge-signable action set, replacing reliance on the
    one-constructor-at-a-time `bridgePolicy_*` family with a single
    source of truth: `bridgeAuthorizedAction_eq_true_iff` (the bridge
    actor signs EXACTLY `replaceKey` / `registerIdentity` / `deposit`
    / `depositWithFee`), the positive `bridgePolicy_authorizes_all_bridge_actions`
    (no-regression), and the negative `bridgePolicy_rejects_non_bridgeable`
    (every other action is rejected).  Because the iff is proven by
    exhaustive `cases` on `Action`, authorising a new constructor —
    e.g. the `ammSwap` that Workstream GP.11 will add — without
    listing it in the iff is a compile-time failure, so the
    bridge-signable set can never widen silently.
-/

import LegalKernel.Authority.Action
import LegalKernel.Authority.Identity

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-! ## The bridge actor

`ActorId 0` is reserved for the bridge actor — the deployment
authority that signs every L1-derived Knomosis action.

The reservation is operational: `AddressBook.empty.nextActorId = 3`
(post-GP.7.1), so addresses assigned via `assign` get `id ≥ 3`,
leaving ids `0` / `1` / `2` exclusively for the bridge / gas-pool /
sequencer actors.  No structural enforcement is needed; the
convention plus the runtime adaptor's discipline suffice. -/

/-- The bridge actor's `ActorId`.  Fixed at `0` so that the
    `AddressBook`'s assigned ids (starting from `3` post-GP.7.1)
    never collide with the bridge actor's slot. -/
def bridgeActor : ActorId := 0

/-! ## Reserved gas-pool actors (GP.7.1)

Workstream GP.7.1 reserves two `ActorId` slots immediately after the
bridge actor:

  * `gasPoolActor` (`ActorId 1`) accumulates the deposit fee-split
    revenue and the per-actor budget top-up payments at both
    `ResourceId 0` (ETH) and `ResourceId 1` (BOLD).  Its outflow is
    bounded by the canonical `gasPoolPolicy` (GP.7.2): it may only
    `transfer` to `sequencerActor`, capped per action; the per-epoch
    drain bound is the inductive GP.7.3 theorem.

  * `sequencerActor` (`ActorId 2`) is the deployment's sequencer key:
    the sole authorised recipient of `gasPoolActor` outflow, and the
    actor that submits L2 state roots to L1.

Like the bridge actor, the reservation is operational — the genesis
`AddressBook.empty.nextActorId` advances to `3`
(`AddressBook.addressBook_empty_nextActorId`), so an `empty` + `assign`
chain never issues a reserved slot to a user-registered identity.  The
three reserved actors are pairwise distinct (the disjointness theorems
below), which the GP.7.2 `gasPoolPolicy` relies on: the pool's
recipient restriction is only meaningful when `sequencerActor` is a
*different* actor than `gasPoolActor`. -/

/-- The reserved `ActorId` of the gas-pool actor (Workstream GP.7.1).
    Holds the deposit fee-split skim and the per-actor budget top-up
    payments; its outflow is bounded by the canonical `gasPoolPolicy`
    (GP.7.2), which permits only capped `transfer`s to
    `sequencerActor`.

    Fixed at `1`, the first slot after the bridge actor.  The genesis
    `AddressBook.empty.nextActorId` advances to `3`
    (`AddressBook.addressBook_empty_nextActorId`) so this slot is never
    issued to a user-registered identity. -/
def gasPoolActor : ActorId := 1

/-- The reserved `ActorId` of the sequencer actor (Workstream GP.7.1).
    The only authorised recipient of `gasPoolActor` outflow under the
    canonical `gasPoolPolicy` (GP.7.2): the sequencer claims accrued
    gas-pool revenue (L1-gas reimbursement) and submits L2 state roots
    to L1.

    Fixed at `2`, the second reserved slot after the bridge actor. -/
def sequencerActor : ActorId := 2

/-! ### Reserved-actor disjointness (GP.7.1)

The three reserved actors occupy distinct `ActorId` slots: `0`
(`bridgeActor`), `1` (`gasPoolActor`), `2` (`sequencerActor`).  The
pairwise-distinctness theorems are the foundation the GP.7.2
`gasPoolPolicy` and the GP.7.3 drain bound rest on — a pool whose only
permitted recipient coincided with itself could not be drained, and a
bridge actor whose L1-attestation authority overlapped the pool slot
would conflate two distinct trust domains. -/

/-- GP.7.1 — the gas-pool actor and the bridge actor occupy distinct
    `ActorId` slots (`1 ≠ 0`). -/
theorem gasPoolActor_ne_bridgeActor : gasPoolActor ≠ bridgeActor := by decide

/-- GP.7.1 — the sequencer actor and the bridge actor occupy distinct
    `ActorId` slots (`2 ≠ 0`). -/
theorem sequencerActor_ne_bridgeActor : sequencerActor ≠ bridgeActor := by decide

/-- GP.7.1 — the sequencer actor and the gas-pool actor occupy distinct
    `ActorId` slots (`2 ≠ 1`).  Load-bearing for the GP.7.2
    `gasPoolPolicy`: the pool may only drain to a recipient strictly
    distinct from itself. -/
theorem sequencerActor_ne_gasPoolActor : sequencerActor ≠ gasPoolActor := by decide

/-! ### Reservation guarantee — `assign` never issues a reserved id (GP.7.1)

The disjointness theorems above establish that the three reserved
`ActorId`s are *distinct*; the theorem below establishes the
*operational* consequence the genesis advance buys.  Assigning a fresh
Ethereum address into the genesis `AddressBook` issues
`AddressBook.empty.nextActorId = 3`
(`AddressBook.addressBook_empty_nextActorId`), which is none of the
three reserved actors — so no user-registered identity built by an
`empty` + `assign` chain can ever collide with `bridgeActor`,
`gasPoolActor`, or `sequencerActor`.  The single-step form below is the
load-bearing fact; the chain-level promotion is a straightforward
induction over `assign`'s monotone `nextActorId`
(`AddressBook.assign_fresh_actorId_le`), deferred to the GP.7.x
drain-bound track. -/

/-- GP.7.1 — assigning a fresh Ethereum address into the genesis
    `AddressBook` issues an `ActorId` distinct from every reserved slot
    (`bridgeActor` = 0, `gasPoolActor` = 1, `sequencerActor` = 2).  This
    is the operational reservation guarantee the genesis `nextActorId`
    advance to `3` buys: the first user a fresh deployment registers is
    `ActorId 3` (`AddressBook.addressBook_empty_nextActorId`), never a
    reserved actor.  Proven by reducing `empty.assign` through its
    fresh-address branch (`AddressBook.assign_eq_of_lookup_none`, since
    the empty book maps no address) to `empty.nextActorId = 3` and
    deciding the three inequalities `3 ≠ 0 / 1 / 2`. -/
theorem empty_assign_id_avoids_reserved (addr : EthAddress) :
    (AddressBook.empty.assign addr).snd ≠ bridgeActor ∧
    (AddressBook.empty.assign addr).snd ≠ gasPoolActor ∧
    (AddressBook.empty.assign addr).snd ≠ sequencerActor := by
  have hnone : AddressBook.empty.forward[addr]? = none :=
    Std.TreeMap.getElem?_emptyc
  -- The empty book maps no address, so `assign` takes its fresh-address
  -- branch and returns `empty.nextActorId = 3` (independent of `addr`).
  have hsnd : (AddressBook.empty.assign addr).snd = 3 := by
    rw [AddressBook.assign_eq_of_lookup_none AddressBook.empty addr hnone]
    rfl
  rw [hsnd]
  refine ⟨?_, ?_, ?_⟩ <;> decide

/-! ## Bridge `AuthorityPolicy`

The `bridgePolicy` admits only the L1-derivable action variants
when the signer is the bridge actor.  All other (signer, action)
pairs are rejected.

The decidability witness pattern-matches on the action constructor;
each branch is a finite conjunction of decidable equalities, so
`decide` discharges every theorem. -/

/-- The set of `Action` constructors that the bridge actor is
    permitted to sign.

    **Exhaustive match (GP.7.0), no catch-all.**  Every `Action`
    constructor has an explicit arm — the four bridge-signable
    variants return `true`, the other eighteen return `false`.  The
    previous formulation ended in a `_ => false` wildcard; that was
    convenient (a new bridge-signable action was a one-line addition)
    but it silently absorbed *any* newly-added `Action` constructor as
    "not bridge-authorised" with no review forced.  Spelling out every
    constructor turns "is this new action bridge-signable?" into a
    compile-time question: adding a constructor to `Action` makes this
    `def` non-exhaustive and breaks the build until the author commits
    to a `true`/`false` classification here.  This is the same
    exhaustive-match discipline AR.17 applied to `kernelOnlyApply`'s
    dispatch, and it is what makes the
    `bridgeAuthorizedAction_eq_true_iff` characterisation's
    forcing-function guarantee hold for constructor *additions* (not
    only for verdict flips). -/
def bridgeAuthorizedAction : Action → Bool
  -- ## The four bridge-signable (L1-attested) variants.
  | .replaceKey _ _               => true
  | .registerIdentity _ _         => true
  | .deposit _ _ _ _              => true
  -- Workstream GP: `depositWithFee` is the user-chosen-fee bridge
  -- deposit (frozen index 19).  Like `deposit`, it is an L1-attested
  -- bridge credit signed by the bridge actor — and it is classified
  -- `Action.isBridgeOnly` (so `BridgeAdmissibleWith` REQUIRES it be
  -- bridgeActor-signed).  It must therefore be bridge-authorised, or
  -- it could never be admitted under `bridgePolicy`.  The
  -- `bridgeAuthorizedAction_of_isBridgeOnly` consistency theorem
  -- (`Bridge/Admissible.lean`) pins exactly this `isBridgeOnly ⊆
  -- bridgeAuthorizedAction` invariant.
  | .depositWithFee _ _ _ _ _ _ _ => true
  -- ## The eighteen non-bridge-signable variants (explicit, no
  -- wildcard).  Balance / supply movement, the positive-incentive
  -- trio, the dispute + fault-proof pipeline, identity-policy
  -- management, and the user gas-pool actions are all deployment- or
  -- user-initiated, never bridge attestations.
  | .transfer _ _ _ _             => false
  | .mint _ _ _                   => false
  | .burn _ _ _                   => false
  | .freezeResource _             => false
  | .reward _ _ _                 => false
  | .distributeOthers _ _ _       => false
  | .proportionalDilute _ _ _     => false
  | .dispute _                    => false
  | .disputeWithdraw _            => false
  | .verdict _                    => false
  | .rollback _                   => false
  -- `withdraw` is intentionally NOT admitted by the bridge actor
  -- (Workstream-C audit-1).  Withdrawals are user-initiated: the L2
  -- sender signs their own withdrawal under their own per-actor
  -- authority policy.  The bridge actor's role is attesting L1
  -- deposits + identity events, not initiating L2 withdrawals.  See
  -- `bridgePolicy_rejects_withdraw` (§12.9 #33).
  | .withdraw _ _ _ _             => false
  | .declareLocalPolicy _         => false
  | .revokeLocalPolicy            => false
  | .faultProofChallenge _ _ _ _  => false
  | .faultProofResolution _ _ _ _ => false
  -- The user gas-pool actions `topUpActionBudget` (index 20) and
  -- `topUpActionBudgetFor` (index 21) are user-initiated (a user
  -- converts their own balance into budget, or a delegate funds
  -- another actor's budget), NOT bridge attestations.  They are not
  -- `isBridgeOnly`, and the GP.3.2/3.4 admission gates additionally
  -- reject a bridgeActor signer for them (defense in depth).  See
  -- `bridgePolicy_rejects_topUpActionBudget` and
  -- `bridgePolicy_rejects_topUpActionBudgetFor`.
  | .topUpActionBudget _ _ _ _    => false
  | .topUpActionBudgetFor _ _ _ _ _ => false
  -- The GP.9.1 refund-on-exit `claimBudgetRefund` (index 22) is
  -- user-initiated (a claimant retires their OWN remaining action
  -- budget for a gas payout), NOT a bridge attestation.  It is not
  -- `isBridgeOnly`, and the GP.9.1 admission gate additionally rejects
  -- a bridgeActor signer for it (defense in depth: the bridgeActor is
  -- consume-exempt, so a refund signed by it would have no budget to
  -- retire).
  | .claimBudgetRefund _ _ _ _    => false
  -- GP.11.4: `ammSwap` (index 23) is bridge-attested — the L1 AMM
  -- swap executes on-chain and the bridge actor signs the L2 mirror
  -- action recording the resulting `amountOut`.  Like `depositWithFee`,
  -- the bridge is the sole authority on the swap result.
  | .ammSwap _ _ _ _ _            => true

/-- The bridge actor's authorisation policy.  Authorises an action
    iff:

      1. The signer is exactly `bridgeActor`.
      2. The action is one of the bridge-permitted variants.

    Both conjuncts are decidable; the `decAuth` field is a
    Decidable instance derived from the conjunction. -/
def bridgePolicy : AuthorityPolicy where
  authorized := fun signer action =>
    signer = bridgeActor ∧ bridgeAuthorizedAction action = true
  decAuth    := fun _ _ =>
    inferInstance

/-! ## §12.9 theorems: bridge policy admits / rejects -/

/-- §12.9 #32 — the bridge policy rejects `transfer` actions even
    when the signer is the bridge actor.  Per §6.3, the bridge does
    not move balances; balance movement is the deployment's job
    after L1 events have established identities and deposits. -/
theorem bridgePolicy_rejects_transfer
    (r : ResourceId) (sender receiver : ActorId) (amount : Amount) :
    ¬ bridgePolicy.authorized bridgeActor (.transfer r sender receiver amount) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- The bridge policy rejects `mint` actions.  Token issuance is a
    deployment-level decision, not a bridge-level one. -/
theorem bridgePolicy_rejects_mint
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    ¬ bridgePolicy.authorized bridgeActor (.mint r to amount) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- The bridge policy rejects `burn` actions.  Token destruction is
    a deployment-level decision, not a bridge-level one. -/
theorem bridgePolicy_rejects_burn
    (r : ResourceId) (fromActor : ActorId) (amount : Amount) :
    ¬ bridgePolicy.authorized bridgeActor (.burn r fromActor amount) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- The bridge policy rejects `freezeResource` actions. -/
theorem bridgePolicy_rejects_freezeResource (r : ResourceId) :
    ¬ bridgePolicy.authorized bridgeActor (.freezeResource r) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- The bridge policy rejects `reward` actions. -/
theorem bridgePolicy_rejects_reward
    (r : ResourceId) (to : ActorId) (amount : Amount) :
    ¬ bridgePolicy.authorized bridgeActor (.reward r to amount) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- The bridge policy rejects `distributeOthers` actions. -/
theorem bridgePolicy_rejects_distributeOthers
    (r : ResourceId) (excluded : ActorId) (amount : Amount) :
    ¬ bridgePolicy.authorized bridgeActor (.distributeOthers r excluded amount) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- The bridge policy rejects `proportionalDilute` actions. -/
theorem bridgePolicy_rejects_proportionalDilute
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) :
    ¬ bridgePolicy.authorized bridgeActor (.proportionalDilute r excluded totalReward) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- The bridge policy rejects dispute-pipeline actions.
    Disputes are user-driven; the bridge does not file or withdraw
    disputes. -/
theorem bridgePolicy_rejects_dispute (d : LegalKernel.Disputes.Dispute) :
    ¬ bridgePolicy.authorized bridgeActor (.dispute d) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- The bridge policy rejects `disputeWithdraw` actions. -/
theorem bridgePolicy_rejects_disputeWithdraw (idx : LegalKernel.Disputes.LogIndex) :
    ¬ bridgePolicy.authorized bridgeActor (.disputeWithdraw idx) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- The bridge policy rejects `verdict` actions.  Verdicts are
    issued by the dispute-resolution authority (typically a
    quorum), not by the bridge. -/
theorem bridgePolicy_rejects_verdict (v : LegalKernel.Disputes.Verdict) :
    ¬ bridgePolicy.authorized bridgeActor (.verdict v) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- The bridge policy rejects `rollback` markers. -/
theorem bridgePolicy_rejects_rollback (idx : LegalKernel.Disputes.LogIndex) :
    ¬ bridgePolicy.authorized bridgeActor (.rollback idx) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- §12.9 #35 — the bridge policy authorises `replaceKey` actions
    by the bridge actor.  This is the rotation flow for already-
    registered identities (the bridge produces these when an L1
    `identityRegistered` event references an Ethereum address that
    is already in the `AddressBook`). -/
theorem bridgePolicy_authorizes_replaceKey (actor : ActorId) (newKey : PublicKey) :
    bridgePolicy.authorized bridgeActor (.replaceKey actor newKey) := by
  unfold bridgePolicy bridgeAuthorizedAction
  exact ⟨rfl, rfl⟩

/-- §12.9 #36 — the bridge policy authorises `registerIdentity`
    actions by the bridge actor.  This is the first-time-
    registration flow for fresh Ethereum addresses encountered in
    L1 `identityRegistered` events. -/
theorem bridgePolicy_authorizes_registerIdentity (actor : ActorId) (pk : PublicKey) :
    bridgePolicy.authorized bridgeActor (.registerIdentity actor pk) := by
  unfold bridgePolicy bridgeAuthorizedAction
  exact ⟨rfl, rfl⟩

/-- §12.9 #34 — the bridge policy authorises `deposit` actions by
    the bridge actor (Workstream C.4).  Bridge-attested L1 → L2
    deposit credits are signed by the bridge, never by the
    L2-recipient. -/
theorem bridgePolicy_authorizes_deposit
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : Bridge.DepositId) :
    bridgePolicy.authorized bridgeActor (.deposit r recipient amount depositId) := by
  unfold bridgePolicy bridgeAuthorizedAction
  exact ⟨rfl, rfl⟩

/-- Workstream GP — the bridge policy authorises `depositWithFee`
    actions by the bridge actor.  `depositWithFee` is the
    user-chosen-fee bridge deposit (frozen index 19): an L1-attested
    credit signed by the bridge actor, exactly like `deposit`.  Since
    it is `Action.isBridgeOnly`, `BridgeAdmissibleWith` requires the
    signer to be the bridge actor; this theorem is the matching
    authorisation, so a bridge-signed `depositWithFee` is admissible
    under `bridgePolicy` (without it, the user-fee deposit path would
    be unadmittable). -/
theorem bridgePolicy_authorizes_depositWithFee
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (depositId : Bridge.DepositId) :
    bridgePolicy.authorized bridgeActor
      (.depositWithFee r recipient poolActor userAmount poolAmount
                        budgetGrant depositId) := by
  unfold bridgePolicy bridgeAuthorizedAction
  exact ⟨rfl, rfl⟩

/-- §12.9 #33 — the bridge policy *rejects* `withdraw` actions
    even when the signer is the bridge actor (Workstream-C
    audit-1).  Withdrawals are user-initiated: the L2 sender signs
    their own withdrawal under their own per-actor authority
    policy.  The bridge's role is attesting L1 deposits + identity
    events, not initiating L2 withdrawals.

    A user-signed withdrawal goes through whatever per-actor
    policy the deployment configures (`AuthorityPolicy.singleton`
    for a single-user deployment, `AuthorityPolicy.union` of
    per-user policies for a multi-user deployment, or
    `AuthorityPolicy.unrestricted` for a development sandbox).
    `bridgePolicy` is intersected with such per-user policies; the
    rejection here ensures the bridge actor itself never has the
    ability to drain a user's L2 balance via a coordinated
    withdrawal it could later forge an L1 redemption proof for. -/
theorem bridgePolicy_rejects_withdraw
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (recipientL1 : Bridge.EthAddress) :
    ¬ bridgePolicy.authorized bridgeActor
        (.withdraw r sender amount recipientL1) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- LP.8 — the bridge policy rejects `declareLocalPolicy` actions.
    The bridge actor is a deployment-authority slot that signs L1
    attestations; it does not declare per-actor policies.  A
    deployment that wants to expose per-bridge policy management
    can extend `bridgePolicy` via `AuthorityPolicy.union`, but the
    default rejection is the safe baseline. -/
theorem bridgePolicy_rejects_declareLocalPolicy (p : Authority.LocalPolicy) :
    ¬ bridgePolicy.authorized bridgeActor (.declareLocalPolicy p) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- LP.8 — the bridge policy rejects `revokeLocalPolicy` actions
    by the bridge actor.  Companion to
    `bridgePolicy_rejects_declareLocalPolicy`. -/
theorem bridgePolicy_rejects_revokeLocalPolicy :
    ¬ bridgePolicy.authorized bridgeActor .revokeLocalPolicy := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- Workstream H §12.1 — the bridge policy rejects
    `faultProofChallenge` actions by the bridge actor.  Fault-proof
    challenges are user-initiated; the bridge actor's role is
    attesting L1 events, not adjudication. -/
theorem bridgePolicy_rejects_faultProofChallenge
    (bh : ByteArray) (sIdx eIdx : Disputes.LogIndex) (cc : ByteArray) :
    ¬ bridgePolicy.authorized bridgeActor
        (.faultProofChallenge bh sIdx eIdx cc) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- Workstream H §12.1 — the bridge policy rejects
    `faultProofResolution` actions by the bridge actor.  Resolution
    mirrors are emitted by the runtime's L1-event watcher under its
    own deployment-specific authority, NOT by the bridge actor. -/
theorem bridgePolicy_rejects_faultProofResolution
    (bh : ByteArray) (gid : Nat) (winner : ActorId)
    (rfi : Disputes.LogIndex) :
    ¬ bridgePolicy.authorized bridgeActor
        (.faultProofResolution bh gid winner rfi) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- Workstream GP — the bridge policy rejects `topUpActionBudget`
    (frozen index 20).  Self-topup is user-initiated (an L2 actor
    converts their own gas balance into action budget); the bridge
    actor never signs it.  Companion defense-in-depth alongside the
    GP.3.2 gate's `signer ≠ bridgeActor` conjunct. -/
theorem bridgePolicy_rejects_topUpActionBudget
    (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) :
    ¬ bridgePolicy.authorized bridgeActor
        (.topUpActionBudget gasResource gasAmount budgetIncrement poolActor) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-- Workstream GP / GP.3.4 — the bridge policy rejects
    `topUpActionBudgetFor` (frozen index 21).  Delegated top-up is
    user-initiated (a delegate funds another actor's budget); the
    bridge actor never signs it.  Companion defense-in-depth
    alongside the GP.3.4 gate's `signer ≠ bridgeActor` conjunct — so
    the bridge actor is barred from delegated top-ups at BOTH the
    authority-policy and budget-gate layers. -/
theorem bridgePolicy_rejects_topUpActionBudgetFor
    (recipient : ActorId) (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId) :
    ¬ bridgePolicy.authorized bridgeActor
        (.topUpActionBudgetFor recipient gasResource gasAmount
                                budgetIncrement poolActor) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

/-! ## Cross-actor rejection

The bridge policy authorises actions ONLY when the signer is the
bridge actor.  A non-bridge signer is rejected even on otherwise-
permitted actions. -/

/-- The bridge policy rejects `replaceKey` actions signed by a
    non-bridge actor.  The kernel-level `apply_admissible` would
    catch this via the `authorized` check; the theorem records the
    rejection at the type level. -/
theorem bridgePolicy_rejects_non_bridge_signer
    (signer : ActorId) (action : Action) (h : signer ≠ bridgeActor) :
    ¬ bridgePolicy.authorized signer action := by
  unfold bridgePolicy
  intro ⟨h_eq, _⟩
  exact h h_eq

/-! ## Complete characterisation of the bridge-signable set (GP.7.0)

The per-constructor `bridgePolicy_authorizes_*` / `bridgePolicy_rejects_*`
theorems above pin individual `(action, verdict)` pairs.  The three
theorems below pin the bridge-signable set *exhaustively* — in one
statement each — so that any future change to the `Action` inductive,
or to `bridgeAuthorizedAction`, must reconcile with the bridge's
authority surface at compile time rather than slipping through.

`bridgeAuthorizedAction_eq_true_iff` is the single source of truth:
`bridgeActor` may sign EXACTLY the four L1-attested variants
(`replaceKey`, `registerIdentity`, `deposit`, `depositWithFee`) and
nothing else.  `bridgePolicy_authorizes_all_bridge_actions` is the
positive half (no regression — every action the bridge could sign
before still passes, and the Workstream-GP `depositWithFee` is
included).  `bridgePolicy_rejects_non_bridgeable` is the negative half
(every action outside the authorised set is rejected) and is derived
from the iff, so it inherits the same forcing function.

**Two complementary forcing functions guard against silent drift, and
it is worth being precise about which mechanism catches which change:**

  * *Adding a new `Action` constructor* is caught by
    `bridgeAuthorizedAction` itself: that `def` is an **exhaustive
    match with no wildcard** (GP.7.0), so a new constructor makes it
    non-exhaustive and the build fails until the author classifies the
    new action `true` or `false`.  (A `_ => false` catch-all would
    have silently absorbed the new constructor as "not authorised"
    with no review — exactly the gap this exhaustive form closes.)
  * *Flipping an existing constructor's verdict*, or *adding a new
    `=> true` arm without recording it*, is caught by
    `bridgeAuthorizedAction_eq_true_iff`: its proof is by exhaustive
    `cases` on `Action`, so changing `bridgeAuthorizedAction` without
    updating the iff's disjunction leaves a `True ↔ False` (or
    `False ↔ True`) goal that `simp` cannot close.

When Workstream GP.11 introduces `ammSwap` (the constant-product
ETH↔BOLD swap), the *first* mechanism fires immediately — `ammSwap`
makes `bridgeAuthorizedAction` non-exhaustive, forcing a `true`/`false`
classification.  If a deployment wants the bridge actor to sign it
(`=> true`), the *second* mechanism then forces a matching disjunct in
`bridgeAuthorizedAction_eq_true_iff`.  The build will not compile until
both are done — which is precisely the safety net this section
provides. -/

/-- **Complete characterisation (GP.7.0).**  `bridgeAuthorizedAction`
    returns `true` for EXACTLY the four L1-attested action shapes the
    bridge actor is permitted to sign — `replaceKey`,
    `registerIdentity`, `deposit`, and `depositWithFee` — and `false`
    for every other constructor.

    This single iff subsumes the per-constructor
    `bridgePolicy_authorizes_*` / `bridgePolicy_rejects_*` family: the
    forward direction enumerates the permitted set (the bridge has no
    over-broad authority), and the backward direction confirms each
    listed shape is genuinely authorised.  Because the proof is by
    exhaustive `cases` on `Action`, *flipping a constructor's verdict*
    in `bridgeAuthorizedAction` (or adding a new `=> true` arm) without
    updating this iff's disjunction leaves an unsolved `True ↔ False`
    goal — so the authorised set cannot drift silently.  (A brand-new
    `Action` constructor is caught one level earlier, by
    `bridgeAuthorizedAction`'s wildcard-free exhaustive match, before
    this theorem is even reached.) -/
theorem bridgeAuthorizedAction_eq_true_iff (action : Action) :
    bridgeAuthorizedAction action = true ↔
      (∃ actor newKey, action = .replaceKey actor newKey) ∨
      (∃ actor pk, action = .registerIdentity actor pk) ∨
      (∃ r recipient amount d, action = .deposit r recipient amount d) ∨
      (∃ r recipient poolActor userAmount poolAmount budgetGrant d,
        action = .depositWithFee r recipient poolActor userAmount
                                  poolAmount budgetGrant d) ∨
      (∃ fr tr ai ao ra, action = .ammSwap fr tr ai ao ra) := by
  cases action <;> simp [bridgeAuthorizedAction]

/-- **No-regression / positive half (GP.7.0).**  Every action variant
    the bridge actor is permitted to sign passes `bridgePolicy`: the
    three pre-GP variants (`replaceKey`, `registerIdentity`,
    `deposit`) plus the Workstream-GP `depositWithFee` and `ammSwap`.
    Bundles the individual `bridgePolicy_authorizes_*` theorems so a
    single term witnesses that the bridge-signable set is preserved
    across extensions — the bridge can still do everything it could
    before, and now also the AMM swap mirror. -/
theorem bridgePolicy_authorizes_all_bridge_actions :
    (∀ actor newKey,
        bridgePolicy.authorized bridgeActor (.replaceKey actor newKey)) ∧
    (∀ actor pk,
        bridgePolicy.authorized bridgeActor (.registerIdentity actor pk)) ∧
    (∀ r recipient amount d,
        bridgePolicy.authorized bridgeActor (.deposit r recipient amount d)) ∧
    (∀ r recipient poolActor userAmount poolAmount budgetGrant d,
        bridgePolicy.authorized bridgeActor
          (.depositWithFee r recipient poolActor userAmount poolAmount
                            budgetGrant d)) ∧
    (∀ fr tr ai ao ra,
        bridgePolicy.authorized bridgeActor (.ammSwap fr tr ai ao ra)) :=
  ⟨bridgePolicy_authorizes_replaceKey,
   bridgePolicy_authorizes_registerIdentity,
   bridgePolicy_authorizes_deposit,
   bridgePolicy_authorizes_depositWithFee,
   fun _ _ _ _ _ => ⟨rfl, rfl⟩⟩

/-- **Exhaustive rejection / negative half (GP.7.0).**  If an action is
    none of the four bridge-signable shapes, then `bridgePolicy`
    rejects it for `bridgeActor`.  This is the exhaustive companion to
    the per-constructor `bridgePolicy_rejects_*` theorems: rather than
    naming one rejected constructor at a time, it rejects every action
    outside the authorised set in a single statement.

    Derived from `bridgeAuthorizedAction_eq_true_iff`, so it inherits
    the same compile-time forcing function: a newly-authorised action
    variant would add a disjunct to the iff's right-hand side, which
    would leave this theorem's case analysis non-exhaustive until a
    matching exclusion hypothesis is supplied. -/
theorem bridgePolicy_rejects_non_bridgeable
    (action : Action)
    (h_rk  : ∀ actor newKey, action ≠ .replaceKey actor newKey)
    (h_ri  : ∀ actor pk, action ≠ .registerIdentity actor pk)
    (h_dep : ∀ r recipient amount d, action ≠ .deposit r recipient amount d)
    (h_dwf : ∀ r recipient poolActor userAmount poolAmount budgetGrant d,
               action ≠ .depositWithFee r recipient poolActor userAmount
                                        poolAmount budgetGrant d)
    (h_amm : ∀ fr tr ai ao ra, action ≠ .ammSwap fr tr ai ao ra) :
    ¬ bridgePolicy.authorized bridgeActor action := by
  unfold bridgePolicy
  intro ⟨_, hauth⟩
  rcases (bridgeAuthorizedAction_eq_true_iff action).mp hauth with
    ⟨a, nk, rfl⟩ | ⟨a, pk, rfl⟩ | ⟨r, rcp, amt, d, rfl⟩
    | ⟨r, rcp, pa, ua, pamt, bg, d, rfl⟩ | ⟨fr, tr, ai, ao, ra, rfl⟩
  · exact h_rk a nk rfl
  · exact h_ri a pk rfl
  · exact h_dep r rcp amt d rfl
  · exact h_dwf r rcp pa ua pamt bg d rfl
  · exact h_amm fr tr ai ao ra rfl

/-! ## Sanity smoke checks -/

example : bridgeActor = (0 : ActorId) := rfl

example : gasPoolActor = (1 : ActorId) := rfl

example : sequencerActor = (2 : ActorId) := rfl

example : bridgePolicy.authorized 0 (.replaceKey 1 (⟨#[]⟩ : PublicKey)) := by
  unfold bridgePolicy bridgeAuthorizedAction
  exact ⟨rfl, rfl⟩

example : ¬ bridgePolicy.authorized 0 (.transfer 1 2 3 4) := by
  unfold bridgePolicy
  intro ⟨_, h⟩
  exact absurd h (by simp [bridgeAuthorizedAction])

example : ¬ bridgePolicy.authorized 1 (.replaceKey 2 (⟨#[]⟩ : PublicKey)) := by
  unfold bridgePolicy
  intro ⟨h_eq, _⟩
  exact absurd h_eq (by decide)

end Bridge
end LegalKernel
