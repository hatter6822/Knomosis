/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
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
    `UInt64`.  `AddressBook.empty.nextActorId = 1`, so any address
    assigned via `assign` gets `id ≥ 1` — the bridge actor's slot
    is never overwritten.

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
-/

import LegalKernel.Authority.Action
import LegalKernel.Authority.Identity

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-! ## The bridge actor

`ActorId 0` is reserved for the bridge actor — the deployment
authority that signs every L1-derived Knomosis action.

The reservation is operational: `AddressBook.empty.nextActorId = 1`,
so addresses assigned via `assign` get `id ≥ 1`, leaving id 0
exclusively for the bridge.  No structural enforcement is needed;
the convention plus the runtime adaptor's discipline suffice. -/

/-- The bridge actor's `ActorId`.  Fixed at `0` so that the
    `AddressBook`'s assigned ids (starting from `1`) never collide
    with the bridge actor's slot. -/
def bridgeActor : ActorId := 0

/-! ## Bridge `AuthorityPolicy`

The `bridgePolicy` admits only the L1-derivable action variants
when the signer is the bridge actor.  All other (signer, action)
pairs are rejected.

The decidability witness pattern-matches on the action constructor;
each branch is a finite conjunction of decidable equalities, so
`decide` discharges every theorem. -/

/-- The set of `Action` constructors that the bridge actor is
    permitted to sign.

    Listed positively (rather than negatively) so future expansion
    (Workstream C: `deposit` / `withdraw`) is a single branch
    addition rather than a re-derivation of the rejection set. -/
def bridgeAuthorizedAction : Action → Bool
  | .replaceKey _ _      => true
  | .registerIdentity _ _ => true
  | .deposit _ _ _ _      => true
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
  -- Note: `withdraw` is intentionally NOT admitted by the bridge
  -- actor (Workstream-C audit-1).  Withdrawals are user-initiated:
  -- the L2 sender signs their own withdrawal under their own
  -- per-actor authority policy.  The bridge actor's role is
  -- attesting L1 deposits + identity events, not initiating L2
  -- withdrawals.  See `bridgePolicy_rejects_withdraw` (§12.9 #33).
  --
  -- Note: the user gas-pool actions `topUpActionBudget` (index 20)
  -- and `topUpActionBudgetFor` (index 21) are ALSO not admitted: they
  -- are user-initiated (a user converts their own balance into
  -- budget, or a delegate funds another actor's budget), NOT bridge
  -- attestations.  They are not `isBridgeOnly`, and the GP.3.2/3.4
  -- admission gates additionally reject a bridgeActor signer for
  -- them (defense in depth).  See `bridgePolicy_rejects_topUpActionBudget`
  -- and `bridgePolicy_rejects_topUpActionBudgetFor`.
  | _                     => false

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

/-! ## Sanity smoke checks -/

example : bridgeActor = (0 : ActorId) := rfl

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
