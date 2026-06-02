-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
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
    `BridgeAdmissibleWith` conjunct 8.  Returns `true` for:

      * `registerIdentity` — first-time bridge-attested identity
        registration.
      * `deposit` — bridge-attested L1 deposit credit.
      * `depositWithFee` (Workstream GP) — bridge-attested L1
        deposit credit with user-chosen fee split AND a budget
        grant; the `bridgePolicy` AuthorityPolicy layer rejects
        non-bridge signers, and the kernel-only admission gate
        (`depositWithFee_signerCheck`) provides the matching
        defence-in-depth at the gate layer.  Including it here
        means `BridgeAdmissibleWith` ALSO requires
        `signer = bridgeActor` on the production bridge-aware
        path — three layers of agreement on the same invariant.

    Returns `false` for `withdraw` (user-initiated) and
    `topUpActionBudget` (user-initiated; user pays gas to refill
    their own action budget). -/
def Action.isBridgeOnly : Action → Bool
  | .registerIdentity _ _              => true
  | .deposit _ _ _ _                   => true
  | .depositWithFee _ _ _ _ _ _ _      => true
  | _                                  => false

/-- **Bridge-classification consistency invariant.**  Every
    `isBridgeOnly` action is bridge-authorised
    (`bridgeAuthorizedAction = true`).

    This is the load-bearing well-formedness guarantee that ties the
    two bridge classifiers together: `BridgeAdmissibleWith` conjunct 8
    REQUIRES an `isBridgeOnly` action to be bridge-actor-signed, while
    `bridgePolicy.authorized bridgeActor` reduces to
    `bridgeAuthorizedAction`.  Were any `isBridgeOnly` action NOT
    bridge-authorised, it would be *unadmittable under `bridgePolicy`*
    — bridge-signing is forced, yet the policy would reject it.  This
    theorem rules that out at the type level, so adding a new
    `isBridgeOnly` action without authorising it is a compile-time
    failure here rather than a silent dead-on-arrival action variant.

    (Workstream-GP fix: `depositWithFee` is `isBridgeOnly` but was
    initially absent from `bridgeAuthorizedAction`; this theorem now
    pins that it — and every present and future `isBridgeOnly`
    variant — is authorised.) -/
theorem bridgeAuthorizedAction_of_isBridgeOnly
    (action : Action) (h : Action.isBridgeOnly action = true) :
    bridgeAuthorizedAction action = true := by
  cases action <;> simp_all [Action.isBridgeOnly, bridgeAuthorizedAction]

/-! ## applyActionToBridgeState

The bridge-side state-update helper.  For most actions this is the
identity (the bridge state is unchanged).  For `deposit` and
`depositWithFee`, the deposit-id is recorded in `consumed` with its
`(resource, userAmount, poolAmount, budgetGrant)` metadata.  For
`withdraw`, a new `PendingWithdrawal` entry is inserted at `nextWdId`
and the counter is bumped. -/

/-- The bridge-state effect of an action, with explicit per-action
    closure over the L2 log index.  Most actions are bridge-state-
    identity; only `deposit`, `depositWithFee`, and `withdraw` mutate
    it.

    Workstream GP closure: `.depositWithFee` also carries a `depositId`
    sourced from an L1 attestation; recording it in `consumed` is
    required to prevent bridge-aware replay of the same L1 deposit
    payload (`BridgeAdmissibleWith` conjunct 6b enforces freshness
    at admission time, and this function persists the consumption at
    apply time so subsequent admissions reject duplicates).  The
    `consumed` entry records the `(userAmount, poolAmount)` split
    plus the `budgetGrant` separately (GP.4.1 widening); their sum
    `userAmount + poolAmount` is the total credited to L2 balances,
    matching the deposit-accounting invariant that `consumed` tracks
    "the L2 supply expansion attributable to this L1 event".  A
    fee-less `.deposit` records `userAmount := amount` with
    `poolAmount = budgetGrant = 0`. -/
def applyActionToBridgeState (bs : BridgeState) (action : Action)
    (l2LogIndex : Nat) : BridgeState :=
  match action with
  | .deposit r _recipient amount d =>
    bs.markConsumed d ({ resource := r, userAmount := amount,
                         poolAmount := 0, budgetGrant := 0 })
  | .depositWithFee r _recipient _poolActor userAmount poolAmount budgetGrant d =>
    bs.markConsumed d ({ resource := r, userAmount := userAmount,
                         poolAmount := poolAmount, budgetGrant := budgetGrant })
  | .withdraw r _sender amount rcp =>
    bs.appendWithdrawal
      { resource    := r
        recipient   := rcp
        amount      := amount
        l2LogIndex  := l2LogIndex }
  | _ => bs

/-- Smoke check: non-bridge actions leave `BridgeState` unchanged.
    Excludes `.deposit`, `.depositWithFee`, and `.withdraw` — the
    three bridge-mutating constructors. -/
theorem applyActionToBridgeState_non_bridge
    (bs : BridgeState) (action : Action) (idx : Nat)
    (hne_dep : ∀ r recipient amount d, action ≠ .deposit r recipient amount d)
    (hne_dwf : ∀ r recipient poolActor ua pa bg d,
      action ≠ .depositWithFee r recipient poolActor ua pa bg d)
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
  | depositWithFee r recipient poolActor ua pa bg d =>
      exact absurd hact (hne_dwf r recipient poolActor ua pa bg d)
  | topUpActionBudget _ _ _ _     => rfl
  | topUpActionBudgetFor _ _ _ _ _ => rfl

/-- A `.depositWithFee` admission persists the `depositId` in
    `bridge.consumed`.  Companion to `applyActionToBridgeState`'s
    new `.depositWithFee` arm: the `consumed` cell becomes `true`,
    so any subsequent `.depositWithFee` (or `.deposit`) carrying
    the same `depositId` is rejected by `BridgeAdmissibleWith`'s
    deposit-id-uniqueness conjuncts. -/
@[simp] theorem applyActionToBridgeState_depositWithFee_consumed
    (bs : BridgeState) (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (d : DepositId) (idx : Nat) :
    (applyActionToBridgeState bs
      (.depositWithFee r recipient poolActor userAmount poolAmount budgetGrant d)
      idx).consumed.contains d = true := by
  unfold applyActionToBridgeState BridgeState.markConsumed
  simp

/-! ## BridgeAdmissibleWith

The §7.0 strengthened admissibility predicate.  Inherits the five
`AdmissibleWith` conjuncts and adds four bridge-specific obligations.

Each new conjunct fires only on the relevant action variant:

  * Conjunct 6 (deposit-id uniqueness for `.deposit`) is vacuous
    for non-`deposit` actions.
  * Conjunct 6b (deposit-id uniqueness for `.depositWithFee`) is
    vacuous for non-`depositWithFee` actions.  Required by
    Workstream GP: a bridge-signed `.depositWithFee` carries an
    L1-attested `depositId`; without this conjunct the same payload
    could be admitted multiple times, re-crediting balances and
    re-granting budget on every replay.
  * Conjunct 7 (first-time registration) is vacuous for non-
    `registerIdentity` actions.
  * Conjunct 8 (bridge-only signer) only restricts the
    `isBridgeOnly` action variants
    (`.registerIdentity`, `.deposit`, `.depositWithFee`).

For non-bridge actions, `BridgeAdmissibleWith` collapses to the
underlying `AdmissibleWith` (via vacuous truth on each new
conjunct). -/

/-- The bridge-aware admissibility predicate.  Strengthens the
    Phase-3 `AdmissibleWith` with four bridge-specific obligations
    (§7.0 + Workstream GP).  Non-bridge actions discharge each new
    conjunct vacuously, so this predicate is strictly equivalent to
    `AdmissibleWith` outside the bridge surface. -/
def BridgeAdmissibleWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray)
    (es : ExtendedState) (st : SignedAction) : Prop :=
  AdmissibleWith verify P deploymentId es st ∧
  -- (6) deposit-id uniqueness for `.deposit`:
  (∀ r recipient amount depositId,
    st.action = .deposit r recipient amount depositId →
    es.bridge.consumed.contains depositId = false) ∧
  -- (6b) deposit-id uniqueness for `.depositWithFee` (Workstream GP).
  -- Same uniqueness contract as (6), but for the depositWithFee
  -- constructor, which also carries a depositId.  Without this,
  -- the bridge-aware admission path would accept the same
  -- bridge-signed depositWithFee payload multiple times and
  -- re-credit user/pool balances + re-grant budget on each replay.
  (∀ r recipient poolActor userAmount poolAmount budgetGrant depositId,
    st.action = .depositWithFee r recipient poolActor userAmount poolAmount
                  budgetGrant depositId →
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

/-- The deposit-id-uniqueness conjunct for `.deposit`, projected. -/
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

/-- The deposit-id-uniqueness conjunct for `.depositWithFee`,
    projected (Workstream GP). -/
theorem BridgeAdmissibleWith.depositWithFeeIdFresh
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : BridgeAdmissibleWith verify P d es st)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (depositId : DepositId)
    (heq : st.action = .depositWithFee r recipient poolActor userAmount
                          poolAmount budgetGrant depositId) :
    es.bridge.consumed.contains depositId = false :=
  h.2.2.1 r recipient poolActor userAmount poolAmount budgetGrant depositId heq

/-- The first-time-registration conjunct, projected. -/
theorem BridgeAdmissibleWith.registrationFresh
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : BridgeAdmissibleWith verify P d es st)
    (actor : ActorId) (pk : PublicKey)
    (heq : st.action = .registerIdentity actor pk) :
    es.registry[actor]? = none :=
  h.2.2.2.1 actor pk heq

/-- The bridge-actor-signing conjunct, projected. -/
theorem BridgeAdmissibleWith.bridgeOnlySigner
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray}
    {es : ExtendedState} {st : SignedAction}
    (h : BridgeAdmissibleWith verify P d es st)
    (hBridgeOnly : Action.isBridgeOnly st.action = true) :
    st.signer = bridgeActor :=
  h.2.2.2.2 hBridgeOnly

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
      -- GP.3.2 + GP.3.4 safety gates: three named action-specific
      -- checks.  Mirrors the gates in
      -- `Authority/SignedAction.lean`'s `apply_admissible_with_budget`
      -- exactly.  See those helpers' docstrings for the security
      -- rationale (four topUp attack vectors + the non-bridge
      -- depositWithFee attack + the GP.3.4 delegated-top-up
      -- gas-safety + default-deny recipient-consent gate).
      if ! topUpActionBudget_gasCheck st.action st.signer es then
        none
      else if ! depositWithFee_signerCheck st.action st.signer then
        none
      else if ! topUpActionBudgetFor_gate st.action st.signer es then
        none
      else
      let applyGrant (ebs : EpochBudgetState) : EpochBudgetState :=
        match st.action with
        | .depositWithFee _ recipient _ _ _ budgetGrant _ =>
            ebs.topUp recipient currentEpoch freeTier budgetGrant
        | .topUpActionBudget _ _ budgetIncrement _ =>
            ebs.topUp st.signer currentEpoch freeTier budgetIncrement
        | .topUpActionBudgetFor recipient _ _ budgetIncrement _ =>
            -- GP.3.4: grant targets the RECIPIENT; consent enforced by
            -- `topUpActionBudgetFor_gate` above.
            ebs.topUp recipient currentEpoch freeTier budgetIncrement
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
    returns its input unchanged for non-bridge constructors).
    Excludes the three bridge-mutating constructors: `.deposit`,
    `.depositWithFee` (Workstream GP), and `.withdraw`. -/
theorem apply_bridge_admissible_with_preserves_bridge_for_non_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    (hne_dep : ∀ r recipient amount d', st.action ≠ .deposit r recipient amount d')
    (hne_dwf : ∀ r recipient poolActor ua pa bg d',
      st.action ≠ .depositWithFee r recipient poolActor ua pa bg d')
    (hne_wd  : ∀ r sender amount rcp, st.action ≠ .withdraw r sender amount rcp) :
    (apply_bridge_admissible_with verify P d es st idx h).bridge = es.bridge := by
  unfold apply_bridge_admissible_with
  show applyActionToBridgeState es.bridge st.action idx = es.bridge
  exact applyActionToBridgeState_non_bridge es.bridge st.action idx hne_dep hne_dwf hne_wd

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
  show (es.bridge.markConsumed d ({ resource := r, userAmount := amount,
                                    poolAmount := 0, budgetGrant := 0 })).consumed.contains d
       = true
  unfold BridgeState.markConsumed
  show (es.bridge.consumed.insert d ({ resource := r, userAmount := amount,
                                       poolAmount := 0, budgetGrant := 0 })).contains d = true
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

/-! ## Budget-gate bridge/kernel agreement (GP.3.2 + GP.3.4 completion)

The runtime applies via `apply_bridge_admissible_with_budget`, but the
GP.3.2 / GP.3.4 budget theorems in `Authority/SignedAction.lean` are
stated against the kernel-only `apply_admissible_with_budget`.  Rather
than duplicate each proof for the bridge path, we prove ONE structural
lemma — the bridge budget gate is *exactly* the kernel budget gate
with a `bridge`-field stamp — and lift every budget property through
it.

This is the load-bearing observation: `apply_bridge_admissible_with`
is definitionally `{ apply_admissible_with … with bridge := … }`, and
the two budget gates share byte-identical gate logic, `applyGrant`
helper, and consume step.  So the bridge result is the kernel result
mapped through a single `bridge`-field update — which touches NO
budget / base / nonce / registry / policy field.  Every such field
(in particular `epochBudgets`) therefore agrees, and the `some` /
`none` structure is identical. -/

/-- **Structural agreement (on the budget ledger).**  The bridge-aware
    and kernel-only budget gates agree on the post-state `epochBudgets`
    field (lifted through `Option.map`): same `some` / `none` shape,
    same budget ledger.  This holds because the two gates share
    byte-identical gate logic, `applyGrant`, and consume step, and the
    only structural difference (`apply_bridge_admissible_with` =
    `{ apply_admissible_with … with bridge := … }`) never touches
    `epochBudgets`.  Stated on the `epochBudgets` *field* (not the whole
    record) so the leaves close by structure-projection without any
    record-update commutation. -/
theorem apply_bridge_admissible_with_budget_epochBudgets_eq
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st) :
    Option.map (fun e => e.epochBudgets)
      (apply_bridge_admissible_with_budget verify P d es st idx h) =
    Option.map (fun e => e.epochBudgets)
      (apply_admissible_with_budget verify P d es st h.toAdmissibleWith) := by
  -- Deliberately do NOT unfold `apply_bridge_admissible_with`: in every
  -- success leaf the `epochBudgets` field is OVERWRITTEN by the shared
  -- `applyGrant`, so the differing base record (`apply_bridge_admissible_with`
  -- vs `apply_admissible_with`) is projected away.  `{ _ with epochBudgets
  -- := X }.epochBudgets` reduces to `X` regardless of `_`.
  unfold apply_bridge_admissible_with_budget apply_admissible_with_budget
  cases es.budgetPolicy with
  | bounded freeTier actionCost currentEpoch =>
    cases hg1 : topUpActionBudget_gasCheck st.action st.signer es with
    | false => simp
    | true =>
      cases hg2 : depositWithFee_signerCheck st.action st.signer with
      | false => simp
      | true =>
        cases hg3 : topUpActionBudgetFor_gate st.action st.signer es with
        | false => simp
        | true =>
          by_cases hbr : st.signer = Bridge.bridgeActor
          · -- bridgeActor branch.  `simp` reduces the control flow,
            -- `Option.map`, and the `epochBudgets` projection, leaving
            -- two structurally-identical `applyGrant` matches that are
            -- distinct match-auxiliaries; `cases` on the scrutinee
            -- reduces both per-constructor.
            simp [hbr]
            cases st.action <;> rfl
          · cases hc : EpochBudgetState.consume es.epochBudgets st.signer
                          currentEpoch freeTier actionCost with
            | none => simp [hbr, hc]
            | some ebs' =>
                simp [hbr, hc]
                cases st.action <;> rfl

/-- Corollary: the two budget gates reject in lockstep. -/
theorem apply_bridge_admissible_with_budget_none_iff
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st) :
    apply_bridge_admissible_with_budget verify P d es st idx h = none ↔
    apply_admissible_with_budget verify P d es st h.toAdmissibleWith = none := by
  have hmap := apply_bridge_admissible_with_budget_epochBudgets_eq verify P d es st idx h
  constructor
  · intro hb
    rw [hb] at hmap
    cases hk : apply_admissible_with_budget verify P d es st h.toAdmissibleWith with
    | none => rfl
    | some _ => rw [hk] at hmap; simp at hmap
  · intro hk
    rw [hk] at hmap
    cases hb : apply_bridge_admissible_with_budget verify P d es st idx h with
    | none => rfl
    | some _ => rw [hb] at hmap; simp at hmap

/-- Corollary: on a successful bridge admission, the kernel-only gate
    also succeeds with an `ExtendedState` carrying the *same*
    `epochBudgets` (the bridge stamp only rewrites the `bridge` field).
    This is the bridge between the production path and the kernel-only
    GP.3.2 / GP.3.4 budget theorems: any property of
    `(apply_admissible_with_budget …).epochBudgets` transfers verbatim
    to the production `(apply_bridge_admissible_with_budget …)`. -/
theorem apply_bridge_admissible_with_budget_kernel_epochBudgets
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es st idx h = some es') :
    ∃ esK, apply_admissible_with_budget verify P d es st h.toAdmissibleWith = some esK ∧
           esK.epochBudgets = es'.epochBudgets := by
  have hmap := apply_bridge_admissible_with_budget_epochBudgets_eq verify P d es st idx h
  rw [hsuc] at hmap
  cases hk : apply_admissible_with_budget verify P d es st h.toAdmissibleWith with
  | none => rw [hk] at hmap; simp at hmap
  | some esK =>
      refine ⟨esK, rfl, ?_⟩
      rw [hk] at hmap
      -- hmap : some esK.epochBudgets = some es'.epochBudgets
      simpa using hmap.symm

/-- The production budget gate preserves the accounting-relevant fields.
    On a successful `apply_bridge_admissible_with_budget` (the function
    the runtime `processSignedActionWith` / replay path executes), the
    resulting state's `base` and `bridge` fields are exactly those of
    the underlying `apply_bridge_admissible_with` step — the budget gate
    overwrites only `epochBudgets` in every `some` branch.

    Consequence: every accounting property proved over
    `apply_bridge_admissible_with` (the `totalDeposited` /
    `totalUserDeposited` / `totalPoolDeposited` / `totalWithdrawn`
    deltas, which read only `base` and `bridge`) transfers verbatim to
    the literal production runtime entry. -/
theorem apply_bridge_admissible_with_budget_base_bridge_eq
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es st)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es st idx h = some es') :
    es'.base = (apply_bridge_admissible_with verify P d es st idx h).base ∧
    es'.bridge = (apply_bridge_admissible_with verify P d es st idx h).bridge := by
  unfold apply_bridge_admissible_with_budget at hsuc
  cases es.budgetPolicy with
  | bounded freeTier actionCost currentEpoch =>
    -- Exhaustively split the control flow (three safety gates, the
    -- bridgeActor branch, the consume match) in `hsuc`.  Every `none`
    -- leaf contradicts `hsuc = some es'`; every `some` leaf returns
    -- `{ apply_bridge_admissible_with … with epochBudgets := … }`, whose
    -- `base` / `bridge` projections are the underlying step's by
    -- record-update construction (`⟨rfl, rfl⟩`).
    repeat' split at hsuc
    all_goals first
      | (simp only [Option.some.injEq] at hsuc; subst hsuc; exact ⟨rfl, rfl⟩)
      | simp at hsuc

/-! ## Bridge-aware (production-path) budget theorems (GP.3.2 + GP.3.4)

The runtime (`Runtime/Loop.lean`, `Runtime/Replay.lean`) dispatches on
`BridgeAdmissibleWith` and applies via
`apply_bridge_admissible_with_budget`.  The GP.3.2 / GP.3.4 budget
theorems in `Authority/SignedAction.lean` were stated against the
kernel-only `apply_admissible_with_budget`; the bridge-aware mirrors
below pin the SAME properties on the *production* path.

Each is a uniform lift through the agreement corollaries above
(`apply_bridge_admissible_with_budget_kernel_epochBudgets` for success
cases, `apply_bridge_admissible_with_budget_none_iff` for rejection
cases) — so there is exactly one proof of the gate structure (the
agreement lemma), and every property transfers verbatim.  This
completes the bridge-side coverage GP.3.2 left to value-level tests. -/

/-- GP.3.2.e (bridge mirror) — every non-bridge, non-`depositWithFee`,
    non-`topUpActionBudget`, non-`topUpActionBudgetFor` action admitted
    on the production path reduces the signer's budget by `actionCost`. -/
theorem admission_consumes_budget_on_success_bridge
    {verify : PublicKey → ByteArray → Signature → Bool}
    {P : AuthorityPolicy} {d : ByteArray} {es : ExtendedState}
    {st : SignedAction} (idx : Nat) {h : BridgeAdmissibleWith verify P d es st}
    {freeTier actionCost currentEpoch : Nat}
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hne_bridge : st.signer ≠ Bridge.bridgeActor)
    (hne_dep : ∀ r recipient poolActor ua pa bg dep,
      st.action ≠ .depositWithFee r recipient poolActor ua pa bg dep)
    (hne_topup : ∀ gr ga bi pa, st.action ≠ .topUpActionBudget gr ga bi pa)
    (hne_topupFor : ∀ recipient gr ga bi pa,
      st.action ≠ .topUpActionBudgetFor recipient gr ga bi pa)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es st idx h = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets st.signer currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets st.signer currentEpoch freeTier - actionCost := by
  obtain ⟨_, hk, heb⟩ :=
    apply_bridge_admissible_with_budget_kernel_epochBudgets verify P d es st idx h hsuc
  rw [← heb]
  exact admission_consumes_budget_on_success hpolicy hne_bridge hne_dep hne_topup hne_topupFor hk

/-- GP.3.2.f (bridge mirror) — a non-bridge actor with insufficient
    budget is rejected on the production path. -/
theorem admission_rejected_when_budget_zero_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat) (h : BridgeAdmissibleWith verify P d es st)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hne_bridge : st.signer ≠ Bridge.bridgeActor)
    (hbudget : EpochBudgetState.currentBudget es.epochBudgets st.signer currentEpoch freeTier
                  < actionCost) :
    apply_bridge_admissible_with_budget verify P d es st idx h = none := by
  rw [apply_bridge_admissible_with_budget_none_iff]
  exact admission_rejected_when_budget_zero verify P d es st h.toAdmissibleWith
    freeTier actionCost currentEpoch hpolicy hne_bridge hbudget

/-- GP.3.2.g (bridge mirror) — a bridgeActor-signed action leaves
    bridgeActor's own budget unchanged on the production path. -/
theorem bridgeActor_budget_exempt_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat) (h : BridgeAdmissibleWith verify P d es st)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hbridge : st.signer = Bridge.bridgeActor)
    (hne_topup : ∀ gr ga bi pa, st.action ≠ .topUpActionBudget gr ga bi pa)
    (hne_topupFor : ∀ recipient gr ga bi pa,
      st.action ≠ .topUpActionBudgetFor recipient gr ga bi pa)
    (hne_dep_to_bridge : ∀ r recipient poolActor ua pa bg dep,
      st.action = .depositWithFee r recipient poolActor ua pa bg dep →
      recipient ≠ Bridge.bridgeActor)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es st idx h = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets Bridge.bridgeActor currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets Bridge.bridgeActor currentEpoch freeTier := by
  obtain ⟨_, hk, heb⟩ :=
    apply_bridge_admissible_with_budget_kernel_epochBudgets verify P d es st idx h hsuc
  rw [← heb]
  exact bridgeActor_budget_exempt verify P d es st h.toAdmissibleWith
    freeTier actionCost currentEpoch hpolicy hbridge hne_topup hne_topupFor hne_dep_to_bridge hk

/-- GP.3.2.g (bridge mirror) — a successful `depositWithFee` on the
    production path grants the recipient `budgetGrant`. -/
theorem depositWithFee_grants_budget_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat) (depositId : DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es
            ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                              budgetGrant depositId, signer, nonce, sig⟩)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es
              ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                                budgetGrant depositId, signer, nonce, sig⟩ idx h
            = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets recipient currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets recipient currentEpoch freeTier + budgetGrant := by
  obtain ⟨_, hk, heb⟩ :=
    apply_bridge_admissible_with_budget_kernel_epochBudgets verify P d es _ idx h hsuc
  rw [← heb]
  exact depositWithFee_grants_budget verify P d es r recipient poolActor userAmount poolAmount
    budgetGrant depositId signer nonce sig h.toAdmissibleWith freeTier actionCost currentEpoch
    hpolicy hk

/-- GP.3.2.g (bridge mirror) — a successful `depositWithFee` on the
    production path changes no actor's budget except the recipient's. -/
theorem depositWithFee_budget_locality_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (r : ResourceId) (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat) (depositId : DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es
            ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                              budgetGrant depositId, signer, nonce, sig⟩)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (other : ActorId) (hne_other : other ≠ recipient)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es
              ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                                budgetGrant depositId, signer, nonce, sig⟩ idx h
            = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets other currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets other currentEpoch freeTier := by
  obtain ⟨_, hk, heb⟩ :=
    apply_bridge_admissible_with_budget_kernel_epochBudgets verify P d es _ idx h hsuc
  rw [← heb]
  exact depositWithFee_budget_locality verify P d es r recipient poolActor userAmount poolAmount
    budgetGrant depositId signer nonce sig h.toAdmissibleWith freeTier actionCost currentEpoch
    hpolicy other hne_other hk

/-- GP.3.2.h (bridge mirror) — a successful self-`topUpActionBudget` on
    the production path produces a net budget change of
    `budgetIncrement - actionCost` on the signer's slot. -/
theorem topUpActionBudget_net_budget_change_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (gasResource : ResourceId) (gasAmount : Amount)
    (budgetIncrement : Nat) (poolActor : ActorId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es
            ⟨.topUpActionBudget gasResource gasAmount budgetIncrement poolActor,
              signer, nonce, sig⟩)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hne_bridge : signer ≠ Bridge.bridgeActor)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es
              ⟨.topUpActionBudget gasResource gasAmount budgetIncrement poolActor,
                signer, nonce, sig⟩ idx h = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets signer currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets signer currentEpoch freeTier
      - actionCost + budgetIncrement := by
  obtain ⟨_, hk, heb⟩ :=
    apply_bridge_admissible_with_budget_kernel_epochBudgets verify P d es _ idx h hsuc
  rw [← heb]
  exact topUpActionBudget_net_budget_change verify P d es gasResource gasAmount budgetIncrement
    poolActor signer nonce sig h.toAdmissibleWith freeTier actionCost currentEpoch
    hpolicy hne_bridge hk

/-- GP.3.2.i (bridge mirror) — a non-deposit, non-topup, non-bridge
    admission on the production path mutates only the signer's budget. -/
theorem admission_locality_in_budget_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction) (idx : Nat) (h : BridgeAdmissibleWith verify P d es st)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (hne_bridge : st.signer ≠ Bridge.bridgeActor)
    (hne_dep : ∀ r recipient poolActor ua pa bg dep,
      st.action ≠ .depositWithFee r recipient poolActor ua pa bg dep)
    (hne_topup : ∀ gr ga bi pa, st.action ≠ .topUpActionBudget gr ga bi pa)
    (hne_topupFor : ∀ recipient gr ga bi pa,
      st.action ≠ .topUpActionBudgetFor recipient gr ga bi pa)
    (other : ActorId) (hne : st.signer ≠ other)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es st idx h = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets other currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets other currentEpoch freeTier := by
  obtain ⟨_, hk, heb⟩ :=
    apply_bridge_admissible_with_budget_kernel_epochBudgets verify P d es st idx h hsuc
  rw [← heb]
  exact admission_locality_in_budget verify P d es st h.toAdmissibleWith
    freeTier actionCost currentEpoch hpolicy hne_bridge hne_dep hne_topup hne_topupFor other hne hk

/-! ### GP.3.4 delegated-top-up (production-path mirrors) -/

/-- GP.3.4.g (bridge mirror) — the production path rejects a delegated
    top-up whose recipient has not pre-authorised the signer.  The
    default-deny guarantee on the runtime entry. -/
theorem delegatedTopUp_requires_allowTopUpFrom_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (recipient : ActorId) (gr : ResourceId) (ga : Amount) (bi : Nat) (pa : ActorId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es
            ⟨.topUpActionBudgetFor recipient gr ga bi pa, signer, nonce, sig⟩)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (h_no_consent : delegatedTopUpConsentBool es recipient signer = false) :
    apply_bridge_admissible_with_budget verify P d es
      ⟨.topUpActionBudgetFor recipient gr ga bi pa, signer, nonce, sig⟩ idx h = none := by
  rw [apply_bridge_admissible_with_budget_none_iff]
  exact delegatedTopUp_requires_allowTopUpFrom verify P d es recipient gr ga bi pa
    signer nonce sig h.toAdmissibleWith freeTier actionCost currentEpoch hpolicy h_no_consent

/-- GP.3.4.g (bridge mirror) — a successful delegated top-up on the
    production path credits the recipient's budget by `budgetIncrement`. -/
theorem delegatedTopUp_grants_budget_to_recipient_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (recipient : ActorId) (gr : ResourceId) (ga : Amount) (bi : Nat) (pa : ActorId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es
            ⟨.topUpActionBudgetFor recipient gr ga bi pa, signer, nonce, sig⟩)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es
              ⟨.topUpActionBudgetFor recipient gr ga bi pa, signer, nonce, sig⟩ idx h
            = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets recipient currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets recipient currentEpoch freeTier + bi := by
  obtain ⟨_, hk, heb⟩ :=
    apply_bridge_admissible_with_budget_kernel_epochBudgets verify P d es _ idx h hsuc
  rw [← heb]
  exact delegatedTopUp_grants_budget_to_recipient verify P d es recipient gr ga bi pa
    signer nonce sig h.toAdmissibleWith freeTier actionCost currentEpoch hpolicy hk

/-- GP.3.4.g (bridge mirror) — a successful delegated top-up on the
    production path consumes the signer's budget by `actionCost`. -/
theorem delegatedTopUp_signer_budget_consumed_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (recipient : ActorId) (gr : ResourceId) (ga : Amount) (bi : Nat) (pa : ActorId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es
            ⟨.topUpActionBudgetFor recipient gr ga bi pa, signer, nonce, sig⟩)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es
              ⟨.topUpActionBudgetFor recipient gr ga bi pa, signer, nonce, sig⟩ idx h
            = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets signer currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets signer currentEpoch freeTier - actionCost := by
  obtain ⟨_, hk, heb⟩ :=
    apply_bridge_admissible_with_budget_kernel_epochBudgets verify P d es _ idx h hsuc
  rw [← heb]
  exact delegatedTopUp_signer_budget_consumed verify P d es recipient gr ga bi pa
    signer nonce sig h.toAdmissibleWith freeTier actionCost currentEpoch hpolicy hk

/-- GP.3.4.g (bridge mirror) — a successful delegated top-up on the
    production path changes only the recipient's and signer's budgets. -/
theorem delegatedTopUp_budget_locality_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (recipient : ActorId) (gr : ResourceId) (ga : Amount) (bi : Nat) (pa : ActorId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) (idx : Nat)
    (h : BridgeAdmissibleWith verify P d es
            ⟨.topUpActionBudgetFor recipient gr ga bi pa, signer, nonce, sig⟩)
    (freeTier actionCost currentEpoch : Nat)
    (hpolicy : es.budgetPolicy = .bounded freeTier actionCost currentEpoch)
    (other : ActorId) (hne_signer : other ≠ signer) (hne_recipient : other ≠ recipient)
    {es' : ExtendedState}
    (hsuc : apply_bridge_admissible_with_budget verify P d es
              ⟨.topUpActionBudgetFor recipient gr ga bi pa, signer, nonce, sig⟩ idx h
            = some es') :
    EpochBudgetState.currentBudget es'.epochBudgets other currentEpoch freeTier =
    EpochBudgetState.currentBudget es.epochBudgets other currentEpoch freeTier := by
  obtain ⟨_, hk, heb⟩ :=
    apply_bridge_admissible_with_budget_kernel_epochBudgets verify P d es _ idx h hsuc
  rw [← heb]
  exact delegatedTopUp_budget_locality verify P d es recipient gr ga bi pa
    signer nonce sig h.toAdmissibleWith freeTier actionCost currentEpoch hpolicy
    other hne_signer hne_recipient hk

end Bridge
end LegalKernel
