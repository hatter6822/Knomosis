/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Bridge.Admissible — Workstream C.0
(`docs/planning/ethereum_integration_plan.md` §7.0).

The bridge-aware admissibility predicate
(`BridgeAdmissibleWith`) and entry point
(`apply_bridge_admissible_with`).

The existing kernel `Transition.pre` operates on `State`, not on
`ExtendedState` or `BridgeState`.  This means three new bridge-
specific preconditions have nowhere to live in the existing
`AdmissibleWith` predicate:

  1. **Deposit-id uniqueness** — `depositId ∉ es.bridge.consumed`
     for `Action.deposit`.
  2. **Registration first-time-only** — `KeyRegistry.lookup
     es.registry actor = none` for `Action.registerIdentity`.
  3. **Bridge-only authority** — `Action.deposit` /
     `Action.withdraw` (and `Action.registerIdentity`) must be
     signed by `bridgeActor` (which is the L1 → L2 translator's
     authority).

Workstream C.0 extends the `AdmissibleWith` predicate with three
extra conjuncts capturing these obligations, and defines a
`apply_bridge_admissible_with` entry point that consumes the
strengthened witness and additionally updates the
`ExtendedState.bridge` field via `applyActionToBridgeState`.

The strict subset:
`BridgeAdmissibleWith verify P d es st →
 Authority.AdmissibleWith verify P d es st`
makes every Phase-3 / Phase-4-prelude / Phase-6 admissibility
theorem (replay protection, nonce uniqueness, etc.) lift
transparently to the bridge layer via the
`BridgeAdmissibleWith.toAdmissibleWith` projection.

This module is **not** part of the kernel TCB.  Bugs here would
weaken the bridge's deposit-uniqueness or registration-uniqueness
guarantees but cannot violate any kernel invariant — every bridge
admissibility witness inherits the kernel's `AdmissibleWith` body
verbatim.

Coverage map:

  * §7.0a (WU C.0) — `BridgeAdmissibleWith`,
    `apply_bridge_admissible_with`, `applyActionToBridgeState`,
    `BridgeAdmissibleWith.toAdmissibleWith`,
    `apply_bridge_admissible_with_kernel_agreement`,
    `apply_bridge_admissible_with_preserves_bridge_for_non_bridge`.
  * §7.1.3 (WU C.1.3) — `apply_admissible_with_preserves_bridge`.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Bridge.State
import LegalKernel.Bridge.BridgeActor

namespace LegalKernel
namespace Bridge

open LegalKernel.Authority

/-! ## Bridge-only action classification

`Action.isBridgeOnly` is `true` exactly for the action constructors
that **must** be signed by the bridge actor — namely the
L1-attested actions: `registerIdentity` (first-time identity
registration) and `deposit` (L1 deposit credit).

`withdraw` is *not* bridge-only.  Withdrawals are user-initiated:
the L2 sender signs their own withdrawal, and the deployment's
per-actor authority policy authorises the action.  The bridge
records the resulting `PendingWithdrawal` entry into its ledger
via `applyActionToBridgeState`, but does NOT need to sign the
withdrawal itself.  Workstream-C audit-1 hardening removed
`withdraw` from this set after surfacing that the original
listing forced ALL withdrawals to be bridge-actor-signed via
conjunct 8 of `BridgeAdmissibleWith` — contradicting the
user-initiated flow.  See CLAUDE.md's audit-1 changelog. -/

/-- Predicate: the action is a bridge-attested L1 → L2 action that
    must be signed by the bridge actor.  Used by
    `BridgeAdmissibleWith` conjunct 8.  Returns `true` only for
    `registerIdentity` (first-time bridge-attested identity
    registration) and `deposit` (bridge-attested L1 deposit
    credit).  Returns `false` for `withdraw` (user-initiated). -/
def Action.isBridgeOnly : Action → Bool
  | .registerIdentity _ _ => true
  | .deposit _ _ _ _      => true
  | _                     => false

/-! ## applyActionToBridgeState

The bridge-side state-update helper.  For most actions this is the
identity (the bridge state is unchanged).  For `deposit`, the
deposit-id is recorded in `consumed` with its `(resource, amount)`
metadata.  For `withdraw`, a new `PendingWithdrawal` entry is
inserted at `nextWdId` and the counter is bumped. -/

/-- The bridge-state effect of an action, with explicit per-action
    closure over the L2 log index.  Most actions are bridge-state-
    identity; only `deposit` and `withdraw` mutate it. -/
def applyActionToBridgeState (bs : BridgeState) (action : Action)
    (l2LogIndex : Nat) : BridgeState :=
  match action with
  | .deposit r recipient amount d =>
    let _ := recipient  -- recipient is a L2-side balance update; bridge tracks (r, amount)
    bs.markConsumed d ({ resource := r, amount := amount })
  | .withdraw r _sender amount rcp =>
    bs.appendWithdrawal
      { resource    := r
        recipient   := rcp
        amount      := amount
        l2LogIndex  := l2LogIndex }
  | _ => bs

/-- Smoke check: non-bridge actions leave `BridgeState` unchanged. -/
theorem applyActionToBridgeState_non_bridge
    (bs : BridgeState) (action : Action) (idx : Nat)
    (hne_dep : ∀ r recipient amount d, action ≠ .deposit r recipient amount d)
    (hne_wd  : ∀ r sender amount rcp, action ≠ .withdraw r sender amount rcp) :
    applyActionToBridgeState bs action idx = bs := by
  unfold applyActionToBridgeState
  cases hact : action with
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
  | deposit r recipient amount d  => exact absurd hact (hne_dep r recipient amount d)
  | withdraw r sender amount rcp  => exact absurd hact (hne_wd r sender amount rcp)
  | declareLocalPolicy _          => rfl
  | revokeLocalPolicy             => rfl
  | faultProofChallenge _ _ _ _   => rfl
  | faultProofResolution _ _ _ _  => rfl
  | depositWithFee _ _ _ _ _ _ _  => rfl
  | topUpActionBudget _ _ _ _     => rfl

/-! ## BridgeAdmissibleWith

The §7.0 strengthened admissibility predicate.  Inherits the five
`AdmissibleWith` conjuncts and adds three bridge-specific obligations.

Each new conjunct fires only on the relevant action variant:

  * Conjunct 6 (deposit-id uniqueness) is vacuous for non-`deposit`
    actions.
  * Conjunct 7 (first-time registration) is vacuous for non-
    `registerIdentity` actions.
  * Conjunct 8 (bridge-only signer) only restricts the three
    `isBridgeOnly` action variants.

For non-bridge actions, `BridgeAdmissibleWith` collapses to the
underlying `AdmissibleWith` (via vacuous truth on each new
conjunct). -/

/-- The bridge-aware admissibility predicate.  Strengthens the
    Phase-3 `AdmissibleWith` with three bridge-specific obligations
    (§7.0).  Non-bridge actions discharge each new conjunct
    vacuously, so this predicate is strictly equivalent to
    `AdmissibleWith` outside the bridge surface. -/
def BridgeAdmissibleWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray)
    (es : ExtendedState) (st : SignedAction) : Prop :=
  AdmissibleWith verify P deploymentId es st ∧
  -- (6) deposit-id uniqueness:
  (∀ r recipient amount depositId,
    st.action = .deposit r recipient amount depositId →
    es.bridge.consumed.contains depositId = false) ∧
  -- (7) registration first-time-only:
  (∀ actor pk,
    st.action = .registerIdentity actor pk →
    es.registry[actor]? = none) ∧
  -- (8) bridge-only authority for bridge-emitted actions:
  (Action.isBridgeOnly st.action = true → st.signer = bridgeActor)

/-- Projection: bridge admissibility implies kernel admissibility.
    Direct consequence of `BridgeAdmissibleWith`'s definition: the
    kernel-level `AdmissibleWith` is the first conjunct. -/
theorem BridgeAdmissibleWith.toAdmissibleWith
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : BridgeAdmissibleWith verify P d es st) :
    AdmissibleWith verify P d es st := h.1

/-- The deposit-id-uniqueness conjunct, projected. -/
theorem BridgeAdmissibleWith.depositIdFresh
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : BridgeAdmissibleWith verify P d es st)
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (depositId : DepositId)
    (heq : st.action = .deposit r recipient amount depositId) :
    es.bridge.consumed.contains depositId = false :=
  h.2.1 r recipient amount depositId heq

/-- The first-time-registration conjunct, projected. -/
theorem BridgeAdmissibleWith.registrationFresh
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : BridgeAdmissibleWith verify P d es st)
    (actor : ActorId) (pk : PublicKey)
    (heq : st.action = .registerIdentity actor pk) :
    es.registry[actor]? = none :=
  h.2.2.1 actor pk heq

/-- The bridge-actor-signing conjunct, projected. -/
theorem BridgeAdmissibleWith.bridgeOnlySigner
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : BridgeAdmissibleWith verify P d es st)
    (hBridgeOnly : Action.isBridgeOnly st.action = true) :
    st.signer = bridgeActor :=
  h.2.2.2 hBridgeOnly

/-! ## apply_bridge_admissible_with

The bridge-aware entry point.  Calls the Phase-3 `apply_admissible_with`
on the underlying `AdmissibleWith` witness, then additionally
updates the `ExtendedState.bridge` field for `deposit` / `withdraw`
actions.  Non-bridge actions leave the bridge field unchanged
(`applyActionToBridgeState` is the identity on them). -/

/-- The bridge-aware single-step state advance.  Equivalent to
    `apply_admissible_with` on every field except `bridge`, which
    is updated via `applyActionToBridgeState`.

    `l2LogIndex` is the logical position of this signed action in
    the deployment's log.  The runtime layer (Phase 5) tracks it as
    `RuntimeState.logIndex`; for tests / unit-of-work proofs that
    don't need a meaningful index, callers pass `0`. -/
def apply_bridge_admissible_with
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray)
    (es : ExtendedState) (st : SignedAction)
    (l2LogIndex : Nat)
    (h : BridgeAdmissibleWith verify P deploymentId es st) :
    ExtendedState :=
  let es' := apply_admissible_with verify P deploymentId es st h.toAdmissibleWith
  { es' with bridge :=
      applyActionToBridgeState es.bridge st.action l2LogIndex }

/-! ## `apply_bridge_admissible_with_budget` (RB.2 — bridge-aware
    runtime entry combining admission + bridge state + budget gate)

The runtime entry-point analogue of `apply_admissible_with_budget`
(`Authority/SignedAction.lean`).  Threads through the GP.3.2
bounded-policy budget gate on top of `apply_bridge_admissible_with`,
which means a single call:

  * verifies the kernel-level admissibility (via the
    `BridgeAdmissibleWith` witness),
  * gates the action on the signer's epoch budget (consume-only
    path, mirroring `apply_admissible_with_budget`),
  * advances the kernel state, nonce ledger, registry, and local-
    policy table (via `apply_admissible_with`),
  * updates the bridge state for `deposit` / `withdraw` actions
    (via `applyActionToBridgeState`).

`l2LogIndex` is the runtime's view of "where this signed action sits
in the deployment's log".  For `processSignedActionWith` it equals
`rs.logIndex` (the index THIS action will be appended at; identical
to `rs.logIndex + 0` since `appendEntry` is called immediately
after); for `replayStepWith` it equals the entry's index within the
log being replayed.  The bridge state writes a `PendingWithdrawal`
record carrying this index for withdraws, so the index threads
through to L1-side withdrawal proofs (Workstream D). -/

/-- RB.2 — bridge-aware admission entry combining the four
    layers (kernel admissibility, bridge state advance, budget gate,
    L2 log-index threading).  Returns `none` exactly when the budget
    gate rejects the action; otherwise returns the fully-advanced
    `ExtendedState` (kernel + nonce + registry + local policies +
    bridge + budget) wrapped in `some`.

    Compared with the legacy `apply_admissible_with_budget`
    (`Authority/SignedAction.lean`), this entry adds the
    bridge-state mutation step and consumes the stronger
    `BridgeAdmissibleWith` witness — so deposit-id-uniqueness,
    first-time-registration, and bridge-only-signer obligations
    are all enforced atomically with the kernel-level admission.

    The legacy entry remains in source for callers that don't yet
    thread the bridge witness (none in the runtime tree post-RB.3,
    but it ships for future deployments / external integrations
    that bypass the bridge layer).

    **GP.3.2.c bridgeActor exemption (per OQ-GP-6).**  When
    `st.signer = bridgeActor`, the consume step is skipped entirely.
    Mirrors the exemption in `apply_admissible_with_budget`; both
    paths share the same upstream rationale (bridge actions are
    L1-gas-gated already). -/
def apply_bridge_admissible_with_budget
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (l2LogIndex : Nat)
    (h : BridgeAdmissibleWith verify P d es st) :
    Option ExtendedState :=
  match es.budgetPolicy with
  | .bounded freeTier actionCost currentEpoch =>
      -- GP.3.2 safety: signer-aware gas precondition check.  Mirrors
      -- the named `topUpActionBudget_gasCheck` helper in
      -- `Authority/SignedAction.lean` exactly.  See that helper's
      -- docstring for the security rationale (zero-gas and
      -- insufficient-gas attack vectors).
      if ! topUpActionBudget_gasCheck st.action st.signer es then
        none
      else
      let applyGrant (ebs : EpochBudgetState) : EpochBudgetState :=
        match st.action with
        | .depositWithFee _ recipient _ _ _ budgetGrant _ =>
            ebs.topUp recipient currentEpoch freeTier budgetGrant
        | .topUpActionBudget _ _ budgetIncrement _ =>
            ebs.topUp st.signer currentEpoch freeTier budgetIncrement
        | _ => ebs
      if st.signer = bridgeActor then
        -- GP.3.2.c: bridgeActor exemption (per OQ-GP-6).  Skip consume.
        let applied := apply_bridge_admissible_with verify P d es st l2LogIndex h
        some { applied with epochBudgets := applyGrant es.epochBudgets }
      else
        match EpochBudgetState.consume es.epochBudgets st.signer
                currentEpoch freeTier actionCost with
        | none => none
        | some ebs' =>
            let applied := apply_bridge_admissible_with verify P d es st l2LogIndex h
            some { applied with epochBudgets := applyGrant ebs' }

/-! ## Pass-through preservation theorems (§7.1.3) -/

/-- §7.1.3 (WU C.1.3): the Phase-3 `apply_admissible_with` does NOT
    mutate the `bridge` field of `ExtendedState`.  Direct `rfl`:
    `apply_admissible_with`'s body uses `{ es with base := s' }` and
    `{ es'' with registry := … }` syntax, which preserves all other
    fields (including the new `bridge` field) by construction. -/
theorem apply_admissible_with_preserves_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction)
    (h : AdmissibleWith verify P d es st) :
    (apply_admissible_with verify P d es st h).bridge = es.bridge := rfl

/-- The Phase-3 `apply_admissible` (back-compat alias) likewise
    preserves the bridge field. -/
theorem apply_admissible_preserves_bridge
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction)
    (h : Admissible P es st) :
    (apply_admissible P es st h).bridge = es.bridge := rfl

/-! ## Bridge-aware kernel agreement (§7.0a) -/

/-- The bridge-aware entry point agrees with the Phase-3 entry point
    on the `base` field. -/
theorem apply_bridge_admissible_with_base_agrees
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st) :
    (apply_bridge_admissible_with verify P d es st idx h).base =
    (apply_admissible_with verify P d es st h.toAdmissibleWith).base := rfl

/-- The bridge-aware entry point agrees with the Phase-3 entry point
    on the `nonces` field. -/
theorem apply_bridge_admissible_with_nonces_agrees
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st) :
    (apply_bridge_admissible_with verify P d es st idx h).nonces =
    (apply_admissible_with verify P d es st h.toAdmissibleWith).nonces := rfl

/-- The bridge-aware entry point agrees with the Phase-3 entry point
    on the `registry` field. -/
theorem apply_bridge_admissible_with_registry_agrees
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st) :
    (apply_bridge_admissible_with verify P d es st idx h).registry =
    (apply_admissible_with verify P d es st h.toAdmissibleWith).registry := rfl

/-- Non-bridge actions: the bridge-aware entry point preserves the
    bridge field structurally (since `applyActionToBridgeState`
    returns its input unchanged for non-bridge constructors). -/
theorem apply_bridge_admissible_with_preserves_bridge_for_non_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hne_dep : ∀ r recipient amount d', st.action ≠ .deposit r recipient amount d')
    (hne_wd  : ∀ r sender amount rcp, st.action ≠ .withdraw r sender amount rcp) :
    (apply_bridge_admissible_with verify P d es st idx h).bridge = es.bridge := by
  unfold apply_bridge_admissible_with
  show applyActionToBridgeState es.bridge st.action idx = es.bridge
  exact applyActionToBridgeState_non_bridge es.bridge st.action idx hne_dep hne_wd

/-! ## §7.0a — Post-application bridge-state invariants

After a successful `apply_bridge_admissible_with` call, the
`bridge` field reflects the action's effect:

  * Deposit: the depositId IS in `consumed` (so a replay attempt
    fails conjunct 6).  Closes the L1-deposit-replay attack:
    a malicious bridge cannot credit the same L1 deposit twice
    on L2.
  * Withdraw: a new `PendingWithdrawal` is at `nextWdId`, and
    `nextWdId` is bumped.  Closes the L2-withdraw-replay
    attack: distinct withdrawals get distinct ids.

These are the type-level statements that the bridge ledger
actually evolves under bridge-admissible application. -/

/-- §7.0a / audit-1: after `apply_bridge_admissible_with` of a
    `deposit r recipient amount d`, the depositId `d` IS in the
    post-state's `consumed` map.  Direct corollary: the same
    deposit cannot be admissibly applied twice (the second attempt
    fails `BridgeAdmissibleWith` conjunct 6). -/
theorem deposit_marks_consumed
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (depId : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P depId es st)
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (d : DepositId)
    (heq : st.action = .deposit r recipient amount d) :
    (apply_bridge_admissible_with verify P depId es st idx h).bridge.consumed.contains d
      = true := by
  unfold apply_bridge_admissible_with
  show (applyActionToBridgeState es.bridge st.action idx).consumed.contains d = true
  rw [heq]
  show (es.bridge.markConsumed d ({ resource := r, amount := amount })).consumed.contains d
       = true
  unfold BridgeState.markConsumed
  show (es.bridge.consumed.insert d ({ resource := r, amount := amount })).contains d = true
  exact Std.TreeMap.contains_insert_self

/-- §7.0a / audit-1: a successful deposit-bridge-admissible
    application means the depositId is ALWAYS recorded as
    consumed at the post-state.  Cannot be `false` in the
    `consumed` map after a successful application. -/
theorem deposit_replay_blocked_by_consumed
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (depId : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P depId es st)
    (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (d : DepositId)
    (heq : st.action = .deposit r recipient amount d) :
    ¬ ((apply_bridge_admissible_with verify P depId es st idx h).bridge.consumed.contains d
       = false) := by
  rw [deposit_marks_consumed verify P depId es st idx h r recipient amount d heq]
  intro hcontra
  cases hcontra

/-- §7.0a / audit-1: after `apply_bridge_admissible_with` of a
    `withdraw r sender amount rcp`, the post-state's
    `bridge.nextWdId` is exactly one greater than the pre-state's.
    Direct corollary: distinct withdrawals get distinct ids. -/
theorem withdraw_bumps_nextWdId
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (depId : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P depId es st)
    (r : ResourceId) (sender : ActorId) (amount : Amount)
    (rcp : EthAddress)
    (heq : st.action = .withdraw r sender amount rcp) :
    (apply_bridge_admissible_with verify P depId es st idx h).bridge.nextWdId =
    es.bridge.nextWdId + 1 := by
  unfold apply_bridge_admissible_with
  show (applyActionToBridgeState es.bridge st.action idx).nextWdId =
       es.bridge.nextWdId + 1
  rw [heq]
  rfl

/-! ## Bridge-aware replay-impossible (lift via projection) -/

/-- §7.0a: the Phase-3 `replay_impossible` theorem lifts to bridge
    admissibility via the projection
    `BridgeAdmissibleWith.toAdmissibleWith` plus the kernel agreement
    theorem on the nonces field.  A successfully applied
    bridge-admissible action cannot be bridge-admissible at the
    post-state. -/
theorem bridge_replay_impossible
    (P : AuthorityPolicy) (es : ExtendedState) (st : SignedAction)
    (idx : Nat)
    (h : BridgeAdmissibleWith Verify P ByteArray.empty es st) :
    ¬ BridgeAdmissibleWith Verify P ByteArray.empty
        (apply_bridge_admissible_with Verify P ByteArray.empty es st idx h) st := by
  intro h'
  have h_kernel_pre : Admissible P es st := h.toAdmissibleWith
  have h_post_kernel :
      Admissible P (apply_bridge_admissible_with Verify P ByteArray.empty es st idx h) st :=
    h'.toAdmissibleWith
  -- The bridge-aware post-state shares `base`, `nonces`, `registry`
  -- with the kernel-aware post-state (the per-field agreement
  -- theorems).  `Admissible` reads exactly those three fields, so
  -- the kernel post-state is also admissible.
  have h_kernel_post :
      Admissible P (apply_admissible P es st h_kernel_pre) st := by
    refine ⟨h_post_kernel.1, ?_, ?_, ?_⟩
    · -- nonces match: expectsNonce reads `nonces.next`
      show st.nonce = expectsNonce (apply_admissible P es st h_kernel_pre) st.signer
      have hn := h_post_kernel.2.1
      show st.nonce = (apply_admissible P es st h_kernel_pre).nonces.next[st.signer]?.getD 0
      have hn' : st.nonce =
        (apply_bridge_admissible_with Verify P ByteArray.empty es st idx h).nonces.next[st.signer]?.getD 0 := hn
      have heq :
        (apply_admissible P es st h_kernel_pre).nonces =
        (apply_bridge_admissible_with Verify P ByteArray.empty es st idx h).nonces :=
        (apply_bridge_admissible_with_nonces_agrees Verify P ByteArray.empty
            es st idx h).symm
      rw [heq]
      exact hn'
    · -- registry match
      have hr := h_post_kernel.2.2.1
      have heq :
        (apply_admissible P es st h_kernel_pre).registry =
        (apply_bridge_admissible_with Verify P ByteArray.empty es st idx h).registry :=
        (apply_bridge_admissible_with_registry_agrees Verify P ByteArray.empty
            es st idx h).symm
      rw [heq]
      exact hr
    · -- base match
      have hb := h_post_kernel.2.2.2
      have heq :
        (apply_admissible P es st h_kernel_pre).base =
        (apply_bridge_admissible_with Verify P ByteArray.empty es st idx h).base :=
        (apply_bridge_admissible_with_base_agrees Verify P ByteArray.empty
            es st idx h).symm
      rw [heq]
      exact hb
  exact replay_impossible P es st h_kernel_pre h_kernel_post

end Bridge
end LegalKernel
