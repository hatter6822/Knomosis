/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.BridgeActor — Workstream B.3
(Ethereum integration plan §6.3).

Reserves `ActorId 0` as the *bridge actor* — the authority under
which all L1-derived Canon actions are signed.  The bridge actor's
public key is set at deployment time and is *not* rotatable except
via a dedicated governance event (out of MVP scope).

Design notes:

  * The bridge actor's `ActorId` is fixed at `0`, the lowest
    `UInt64`.  `AddressBook.empty.nextActorId = 1`, so any address
    assigned via `assign` gets `id ≥ 1` — the bridge actor's slot
    is never overwritten.

  * `bridgePolicy` is the deployment's `AuthorityPolicy` for the
    bridge actor.  It admits exactly the L1-derivable action
    variants:

      * `replaceKey`       — bridge-actor-signed key rotations on
                             behalf of registered identities.
      * `registerIdentity` — first-time identity registrations
                             (Workstream B's L1 → Canon translator
                             flow; see `Bridge.Ingest`).

    Other action variants (`transfer`, `mint`, `burn`,
    `freezeResource`, the positive-incentive trio, the dispute
    pipeline, `rollback`) are explicitly rejected.  Deployments
    that need broader bridge-actor capabilities (e.g. a sovereign
    deployment that wants the bridge to mint synthetic tokens)
    extend the policy via `AuthorityPolicy.union`.

  * The `bridgePolicy` is decidable; the five §12.9 theorems below
    discharge each branch by pure `decide`.

  * Workstream C will extend the policy (when its `deposit` /
    `withdraw` constructors land) to also admit those variants
    for the bridge actor.  The extension goes through
    `AuthorityPolicy.union` and does not modify this module.

This module is **not** part of the kernel TCB.  Bugs here would
weaken the bridge's authority guarantees but cannot violate any
kernel invariant — the kernel's `apply_admissible` rejects any
action that fails the supplied `AuthorityPolicy.authorized`
predicate.

Coverage map:

  * §6.3 (WU B.3) — `bridgeActor`, `bridgePolicy`, the
    decidable-policy theorems (#32, #35, #36 from §12.9), plus a
    `bridgePolicy_rejects_*` family for the other action
    constructors.  `bridgePolicy_rejects_withdraw` (#33) and
    `bridgePolicy_authorizes_deposit` (#34) are reserved for
    Workstream C.4 when the `withdraw` and `deposit` Action
    constructors land at frozen indices 13 and 14 (post-
    Workstream B's `registerIdentity` at index 12).
  * §12.9 — three theorems implemented here from the plan
    (`bridgePolicy_rejects_transfer`,
    `bridgePolicy_authorizes_replaceKey`,
    `bridgePolicy_authorizes_registerIdentity`), plus the wider
    rejection family for completeness.  Two theorems (#33, #34)
    deferred to Workstream C.4 as noted above.
-/

import LegalKernel.Authority.Action
import LegalKernel.Authority.Identity

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-! ## The bridge actor

`ActorId 0` is reserved for the bridge actor — the deployment
authority that signs every L1-derived Canon action.

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
