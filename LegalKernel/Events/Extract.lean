/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Events.Extract — `extractEvents : LogEntry → List Event`.

Phase 5 WU 5.6.  Defines the deployment-supplied `extractEvents`
function that derives the per-action `Event` list from a
`(preState, signedAction, postState)` triple.  Implementation is
deterministic: equal inputs produce equal output event lists, and
two replays of the same log produce identical event streams
(Genesis Plan §8.9.1 / §8.9.2).

The Phase-5 implementation enumerates the eight `Action`
constructors (Phase 0 – Phase-4-prelude inclusive) and emits zero
or more balance events per action.  **All balance-event emission is
*delta-filtered*: events fire only when a probed balance actually
changed.**  This means a self-transfer (sender = receiver,
preserving the actor's balance) emits no balance events, and a
`distributeOthers` with `amount = 0` emits no events at all.

| Action constructor      | Events emitted (when balance changed)                                          |
|-------------------------|--------------------------------------------------------------------------------|
| `transfer r s r' a`     | `balanceChanged r s` (if s changed) + `balanceChanged r r'` (if r' changed)    |
| `mint r to a`           | `balanceChanged r to` (if to's balance changed)                                |
| `burn r fr a`           | `balanceChanged r fr` (if fr's balance changed)                                |
| `freezeResource r`      | (no event — kernel-level no-op)                                                |
| `replaceKey actor key`  | `identityRegistered actor key` (always, unconditionally)                       |
| `reward r to a`         | `balanceChanged r to` (if to's balance changed) + `rewardIssued r to a` (always) |
| `distributeOthers r e a`| one `balanceChanged` per affected actor whose balance changed                  |
| `proportionalDilute …`  | one `balanceChanged` per affected actor whose balance changed                  |
| `dispute d`             | `disputeFiled d.challenger (target index of d.claim)`                          |
| `disputeWithdraw idx`   | `disputeWithdrawn idx`                                                         |
| `verdict v`             | `verdictApplied v.disputeId (outcomeTag of v.outcome)`                         |
| `rollback _`            | (no balance event — rollback's effect is the runtime-level state replacement;  |
|                         |  observers see the replaced state via subsequent `balanceChanged` events)      |

Plus a `nonceAdvanced signer old new` event for every successfully
applied action (every admissible signed action advances the
signer's nonce by 1).  This event always fires, regardless of
whether any balances changed — so indexers can rely on at least one
event per applied action (`extractEvents_nonempty`).

This module is **not** part of the trusted computing base.  Bugs
here produce wrong event observations, but cannot violate any
kernel invariant.  In particular: an `extractEvents` that emitted
the wrong actor in `balanceChanged` would mislead an indexer, but
the kernel's `getBalance` queries still produce correct answers; the
wrong event is a *deployment-level* observability bug, not a kernel
bug.
-/

import LegalKernel.Authority.SignedAction
import LegalKernel.Disputes.Types
import LegalKernel.Events.Types

open Std

namespace LegalKernel
namespace Events

open LegalKernel.Authority
open LegalKernel.Disputes

/-! ## extractEvents

The function takes the pre-application `ExtendedState`, the
`SignedAction` that was applied, and the post-application
`ExtendedState`.  It returns a list of events in the order they
should be observed.

Determinism: every branch is a closed expression in the inputs (no
IO, no mutation), so `extractEvents` is a function and trivially
deterministic. -/

/-- Iterate over a list, emitting one `balanceChanged` event per
    actor whose pre-balance differs from its post-balance at
    resource `r`.  Used by the multi-actor laws
    (`distributeOthers`, `proportionalDilute`).

    The `actors` list is the set of actors potentially touched; we
    filter to only those whose balance actually changed (so a
    `distributeOthers` with `amount = 0` emits no events). -/
def balanceChangeEvents
    (preState postState : LegalKernel.State) (r : ResourceId)
    (actors : List ActorId) : List Event :=
  actors.filterMap (fun a =>
    let oldV := LegalKernel.getBalance preState  r a
    let newV := LegalKernel.getBalance postState r a
    if oldV != newV then some (.balanceChanged r a oldV newV) else none)

/-- The list of actors a Phase-5 multi-actor law (distributeOthers /
    proportionalDilute) potentially affects: every actor present in
    `r`'s pre-state `BalanceMap`, minus the excluded actor.

    **AR.13.5 / m-6 note.**  Returns *pre-state* actors only.  If a
    future law introduces new actors at a resource via
    `distributeOthers` / `proportionalDilute` (i.e. credits a
    previously-unmapped actor), those gained-only actors would NOT
    surface here, and the corresponding `balanceChanged` events
    would not be emitted by this helper.  No current law triggers
    this — `distributeOthers` and `proportionalDilute` operate
    over `bm.toList`, which is the pre-state actor set — but the
    helper is flagged as a future-extensibility hazard: any
    new-actor-introducing law would need a separate pass over
    the post-state actor set, or this helper would need to
    consume both `preState` and `postState` and union the actor
    sets. -/
def affectedActors
    (preState : LegalKernel.State) (r : ResourceId) (excluded : ActorId) :
    List ActorId :=
  match preState.balances[r]? with
  | none    => []
  | some bm => (bm.toList.map (·.1)).filter (· ≠ excluded)

/-- The per-action event list, ignoring the nonce-advance event
    (which is uniformly emitted by `extractEvents`). -/
def actionEvents
    (preState postState : LegalKernel.State) (action : Action) : List Event :=
  match action with
  | .transfer r s r' _a =>
    let s_old  := LegalKernel.getBalance preState  r s
    let s_new  := LegalKernel.getBalance postState r s
    let r_old  := LegalKernel.getBalance preState  r r'
    let r_new  := LegalKernel.getBalance postState r r'
    -- Filter zero-delta events: a self-transfer (sender == receiver,
    -- where the §4.11 self-transfer fix preserves the actor's balance)
    -- emits no balance events.  An indexer that needs to observe the
    -- "an action happened" beat picks it up via the always-emitted
    -- nonceAdvanced event.
    let evS := if s_old != s_new then [.balanceChanged r s s_old s_new] else []
    let evR := if r_old != r_new then [.balanceChanged r r' r_old r_new] else []
    evS ++ evR
  | .mint r to _a =>
    let oldV := LegalKernel.getBalance preState  r to
    let newV := LegalKernel.getBalance postState r to
    if oldV != newV then [.balanceChanged r to oldV newV] else []
  | .burn r fr _a =>
    let oldV := LegalKernel.getBalance preState  r fr
    let newV := LegalKernel.getBalance postState r fr
    if oldV != newV then [.balanceChanged r fr oldV newV] else []
  | .freezeResource _r =>
    []  -- kernel-level no-op; commitment to not mutate balances
  | .replaceKey actor newKey =>
    [.identityRegistered actor newKey]
  | .reward r to amt =>
    -- Phase-6 incentive-integration amendment: emit BOTH the
    -- delta-filtered `balanceChanged` (kernel-level effect) AND
    -- the unconditional `rewardIssued` (deployment-level
    -- semantic).  Indexers can subscribe to either or both.
    let oldV := LegalKernel.getBalance preState  r to
    let newV := LegalKernel.getBalance postState r to
    let balanceEv :=
      if oldV != newV then [Event.balanceChanged r to oldV newV] else []
    let rewardEv : List Event := [Event.rewardIssued r to amt]
    balanceEv ++ rewardEv
  | .distributeOthers r excluded _a =>
    balanceChangeEvents preState postState r (affectedActors preState r excluded)
  | .proportionalDilute r excluded _tr =>
    balanceChangeEvents preState postState r (affectedActors preState r excluded)
  | .dispute d =>
    -- Phase-6 dispute filing: emit a `disputeFiled` event identifying
    -- the challenger and the impugned log index.  The latter is
    -- extracted from the claim variant (each variant carries one or
    -- two indices; we report the *primary* impugned index).
    let targetIdx :=
      match d.claim with
      | .preconditionFalse i      => i
      | .signatureInvalid i       => i
      | .nonceMismatch i          => i
      | .oracleMisreported i _    => i
      | .doubleApply i _          => i
    [.disputeFiled d.challenger targetIdx]
  | .disputeWithdraw idx =>
    [.disputeWithdrawn idx]
  | .verdict v =>
    let outcomeTag :=
      match v.outcome with
      | .upheld       => 0
      | .rejected     => 1
      | .inconclusive => 2
    [.verdictApplied v.disputeId outcomeTag]
  | .rollback _ =>
    -- Rollback's *effect* is the runtime-level state replacement;
    -- observers see the new state via subsequent `balanceChanged`
    -- events generated by replay.  No direct rollback-event constructor
    -- (the §8.9.2 vocabulary does not define one); the audit trail is
    -- carried by `verdictApplied` plus the always-emitted `nonceAdvanced`.
    []
  | .registerIdentity actor pk =>
    -- Workstream B (Ethereum integration §6.3): a first-time
    -- identity registration.  Emit the same `identityRegistered`
    -- event that `replaceKey` emits, since the on-the-wire effect
    -- is identical (a new (actor, key) pair appears in the
    -- registry); subscribers can distinguish first-time from
    -- rotation by inspecting the prior registry state via the
    -- snapshot machinery.
    [.identityRegistered actor pk]
  | .deposit r recipient _amount _d =>
    -- Workstream C.5: bridge L1 → L2 deposit credit.  The
    -- `balanceChanged` event is delta-filtered; the
    -- `depositCredited` semantic event is appended by
    -- `extractEvents` (which has the original action's depositId
    -- in scope).
    let oldV := LegalKernel.getBalance preState  r recipient
    let newV := LegalKernel.getBalance postState r recipient
    if oldV != newV then [.balanceChanged r recipient oldV newV] else []
  | .withdraw r sender _amount _rcp =>
    -- Workstream C.5: bridge L2 → L1 withdrawal scheduling.  The
    -- balance-change event is delta-filtered; the
    -- `withdrawalRequested` semantic event is appended by
    -- `extractEvents` (which has access to the post-state's
    -- `BridgeState.nextWdId`).
    let oldV := LegalKernel.getBalance preState  r sender
    let newV := LegalKernel.getBalance postState r sender
    if oldV != newV then [.balanceChanged r sender oldV newV] else []
  | .declareLocalPolicy _ =>
    -- Workstream LP: actor-scoped local-policy declaration.  The
    -- kernel-level effect is identity (compiles to
    -- `Laws.freezeResource 0`), so no `balanceChanged` event.
    -- The deployment-level semantic event (`localPolicyDeclared`)
    -- is emitted by `extractEvents` (LP.10) which has the signer
    -- and policy in scope.
    []
  | .revokeLocalPolicy =>
    -- Workstream LP: actor-scoped local-policy revocation.  Same
    -- shape as `declareLocalPolicy`: kernel-level no-op; the
    -- semantic event (`localPolicyRevoked`) is emitted by
    -- `extractEvents` (LP.10).
    []
  | .faultProofChallenge _ _ _ _ =>
    -- Workstream H §12.3: a fault-proof challenge intent.  The
    -- kernel-level effect is identity (compiles to
    -- `Laws.freezeResource 0`); the semantic
    -- `faultProofGameOpened` event is emitted by `extractEvents`
    -- which has the signer / log-derived data in scope.
    []
  | .faultProofResolution _ _ _ _ =>
    -- Workstream H §12.3: a fault-proof game settlement mirror.
    -- The kernel-level effect is identity; the semantic
    -- `faultProofGameSettled` event is emitted by
    -- `extractEvents`.
    []
  | .depositWithFee r recipient poolActor _userAmount _poolAmount
                     _budgetGrant _depositId =>
    -- Workstream GP §15E (v1.0): bridge depositWithFee.  Emit two
    -- delta-filtered `balanceChanged` events (one for recipient,
    -- one for poolActor); the deployment-level semantic event
    -- (`depositWithFeeCredited`) is emitted unconditionally by
    -- `extractEvents` (which has the budget-grant and deposit-id
    -- in scope).
    let recipOld := LegalKernel.getBalance preState  r recipient
    let recipNew := LegalKernel.getBalance postState r recipient
    let poolOld  := LegalKernel.getBalance preState  r poolActor
    let poolNew  := LegalKernel.getBalance postState r poolActor
    let evRecip := if recipOld != recipNew then
                     [Event.balanceChanged r recipient recipOld recipNew] else []
    let evPool  := if poolOld != poolNew then
                     [Event.balanceChanged r poolActor poolOld poolNew] else []
    evRecip ++ evPool
  | .topUpActionBudget gasResource _gasAmount _budgetIncrement poolActor =>
    -- Workstream GP §15E (v1.0): L2 user self-topup.  The signer
    -- (whose balance is debited) is NOT in scope at the
    -- action-only `actionEvents` layer; we cannot emit a
    -- delta-filtered `balanceChanged` for the signer here.
    -- Instead, the semantic `actionBudgetTopUp` event is emitted
    -- by `extractEvents` (which has the signer in scope from
    -- `SignedAction.signer`); that event carries the signer +
    -- gas-payment metadata.  We can still emit the poolActor's
    -- balance change (signer-independent).
    let poolOld := LegalKernel.getBalance preState  gasResource poolActor
    let poolNew := LegalKernel.getBalance postState gasResource poolActor
    if poolOld != poolNew then
      [Event.balanceChanged gasResource poolActor poolOld poolNew]
    else
      []
  | .topUpActionBudgetFor _recipient gasResource _gasAmount _budgetIncrement poolActor =>
    -- Workstream GP §15E (GP.3.4): delegated top-up.  As with
    -- `topUpActionBudget`, the signer (whose balance is debited) is
    -- not in scope at the action-only `actionEvents` layer; the
    -- signer's `balanceChanged` and the semantic
    -- `delegatedActionBudgetTopUp` event are emitted by
    -- `extractEvents` (which has the signer in scope).  We can still
    -- emit the poolActor's balance change here (signer-independent).
    let poolOld := LegalKernel.getBalance preState  gasResource poolActor
    let poolNew := LegalKernel.getBalance postState gasResource poolActor
    if poolOld != poolNew then
      [Event.balanceChanged gasResource poolActor poolOld poolNew]
    else
      []
  -- Workstream-LX (LX.19): codegen-managed Lex `actionEvents`
  -- arms land between the fence markers below.  Empty in M1
  -- (the example law has no `Action` constructor, so it has no
  -- event arm).  M2 migrates kernel-built-in laws here.
  -- BEGIN LEX-GENERATED (do not edit by hand)
  -- END LEX-GENERATED

/-- The Phase-5 `extractEvents` per Genesis Plan §8.9.1.  Given the
    pre / post `ExtendedState` and the applied `SignedAction`,
    returns the deterministically-derived list of events.

    Every successful `apply_admissible` advances the signer's nonce,
    so `extractEvents` always emits a `nonceAdvanced` event for the
    signer, in addition to the action-specific balance / registry
    events.  The order is: action events first, then the nonce
    event — this matches the temporal order an observer would see
    if the runtime emitted events as the state changes happened. -/
def extractEvents
    (preState postState : ExtendedState) (st : SignedAction) : List Event :=
  let actEvts  := actionEvents preState.base postState.base st.action
  let bridgeEvts : List Event :=
    -- Workstream C.5 semantic bridge events.  Emitted UNCONDITIONALLY
    -- (i.e. NOT delta-filtered): an `Action.deposit … 0 …` still
    -- emits a `depositCredited … 0 …` event, mirroring the
    -- `rewardIssued` convention from the Phase-6 incentive
    -- amendment (the runtime-level effect is delta-filtered via
    -- `balanceChanged`; the deployment-level intent is emitted
    -- unconditionally).
    match st.action with
    | .deposit r recipient amount d =>
      [Event.depositCredited r recipient amount d]
    | .withdraw r sender amount rcp =>
      -- The withdrawal id is the *pre*-state's `nextWdId` (which
      -- the bridge then bumps to assign on this `withdraw`).  Using
      -- the pre-state lets the event match the runtime adaptor's
      -- side-effect: `applyActionToBridgeState` reads `nextWdId`,
      -- inserts at that key, then bumps.  An equivalent reading
      -- via the post-state's `nextWdId - 1` is recorded in the
      -- module docstring.
      [Event.withdrawalRequested r sender amount rcp preState.bridge.nextWdId]
    | _ => []
  let lpEvts : List Event :=
    -- Workstream LP / LP.10 semantic local-policy events.  Emitted
    -- UNCONDITIONALLY (mirroring `rewardIssued` / bridge events): an
    -- idempotent re-declaration still emits the event.  The events
    -- carry the *signer* as the actor since the LP actions are by
    -- construction signer-mutating only.
    match st.action with
    | .declareLocalPolicy p => [Event.localPolicyDeclared st.signer p]
    | .revokeLocalPolicy    => [Event.localPolicyRevoked st.signer]
    | _                     => []
  let faultProofEvts : List Event :=
    -- Workstream H §12.3 semantic fault-proof events.  Emitted
    -- UNCONDITIONALLY (mirroring bridge / LP / reward events): the
    -- L2 action is advisory but its emission is the canonical
    -- record of an L1 game intent or settlement that replicas
    -- consume.  The L1 contract is authoritative for game state;
    -- these events let off-chain observers / indexers maintain
    -- a read-side view without watching L1 directly.
    --
    -- The `gameId = 0` placeholder for the `challenge` event
    -- reflects the design that L1 assigns the actual gameId; the
    -- L2 event serves only as a binding-hash record.  Indexers
    -- match L2 events to L1 games via the bindingHash.
    match st.action with
    | .faultProofChallenge bh sIdx eIdx _cc =>
      [Event.faultProofGameOpened 0 st.signer sIdx eIdx bh]
    | .faultProofResolution _bh gid winner _rfi =>
      [Event.faultProofGameSettled gid winner st.signer 0]
    | _                                     => []
  let gasPoolEvts : List Event :=
    -- Workstream GP §15E (v1.0) semantic gas-pool events.  Emitted
    -- UNCONDITIONALLY (mirroring bridge / LP / fault-proof / reward
    -- events): the budget grant / topup is an admission-layer
    -- effect that downstream indexers consume to maintain a
    -- per-actor "current epoch budget" view.  The semantic events
    -- carry the full action payload; the kernel-level
    -- `balanceChanged` events live in `actionEvents`.
    match st.action with
    | .depositWithFee r recipient poolActor userAmount poolAmount
                       budgetGrant depositId =>
      [Event.depositWithFeeCredited r recipient poolActor
                                     userAmount poolAmount
                                     budgetGrant depositId]
    | .topUpActionBudget gasResource gasAmount budgetIncrement poolActor =>
      -- The signer (whose budget is incremented) comes from the
      -- enclosing SignedAction.
      [Event.actionBudgetTopUp st.signer gasResource gasAmount
                                budgetIncrement poolActor]
    | .topUpActionBudgetFor recipient gasResource gasAmount budgetIncrement poolActor =>
      -- GP.3.4: the budget is credited to `recipient`; the signer
      -- (delegate/payer) comes from the enclosing SignedAction.
      [Event.delegatedActionBudgetTopUp recipient st.signer gasResource
                                gasAmount budgetIncrement poolActor]
    | _                                     => []
  -- Workstream GP §15E (v1.0): for `topUpActionBudget`, also emit
  -- the signer's gas-balance change as a delta-filtered
  -- `balanceChanged` event.  This event lives outside `actionEvents`
  -- because `actionEvents` doesn't have the signer in scope (the
  -- function only takes the action payload, not the enclosing
  -- SignedAction).
  let topUpSignerBalanceEvt : List Event :=
    match st.action with
    | .topUpActionBudget gasResource _gasAmount _bi _poolActor =>
      let oldV := LegalKernel.getBalance preState.base  gasResource st.signer
      let newV := LegalKernel.getBalance postState.base gasResource st.signer
      if oldV != newV then
        [Event.balanceChanged gasResource st.signer oldV newV]
      else
        []
    | .topUpActionBudgetFor _recipient gasResource _gasAmount _bi _poolActor =>
      -- GP.3.4: the signer (delegate/payer) is debited; emit the
      -- signer's gas-balance change as a delta-filtered event.
      let oldV := LegalKernel.getBalance preState.base  gasResource st.signer
      let newV := LegalKernel.getBalance postState.base gasResource st.signer
      if oldV != newV then
        [Event.balanceChanged gasResource st.signer oldV newV]
      else
        []
    | _                                     => []
  let oldN     := expectsNonce preState  st.signer
  let newN     := expectsNonce postState st.signer
  let nonceEvt := [Event.nonceAdvanced st.signer oldN newN]
  actEvts ++ topUpSignerBalanceEvt ++ bridgeEvts ++ lpEvts ++
    faultProofEvts ++ gasPoolEvts ++ nonceEvt

/-! ## Determinism (the §8.9.1 headline property)

`extractEvents` is a pure Lean function, so equal inputs trivially
produce equal output event lists.  This is the type-level statement
that "two replays of the same log produce identical event streams". -/

/-- Determinism: equal inputs produce equal event lists. -/
theorem extractEvents_deterministic
    (preState₁ postState₁ : ExtendedState) (st₁ : SignedAction)
    (preState₂ postState₂ : ExtendedState) (st₂ : SignedAction)
    (h_pre : preState₁ = preState₂) (h_post : postState₁ = postState₂)
    (h_st : st₁ = st₂) :
    extractEvents preState₁ postState₁ st₁ =
    extractEvents preState₂ postState₂ st₂ := by
  rw [h_pre, h_post, h_st]

/-! ## Spot-check lemmas (acceptance gates per WU 5.6)

These document the per-constructor event-emission behaviour at the
type level.  Useful for indexer authors who need to know which events
to expect. -/

/-- Every `extractEvents` output is non-empty: the nonce-advance
    event is uniformly emitted for every signed action.  This is
    the type-level form of "every successful application produces
    at least one observation". -/
theorem extractEvents_nonempty
    (pre post : ExtendedState) (st : SignedAction) :
    extractEvents pre post st ≠ [] := by
  unfold extractEvents
  -- The result is `actionEvents ++ bridgeEvts ++ [nonceEvt]`; the
  -- last list has length 1, so the full concatenation has length ≥ 1,
  -- so it is non-empty.  We use the fact that `xs ++ ys ++ [z]` ends
  -- with `[z]` and hence is non-empty regardless of `xs`/`ys`.
  intro h
  have h_last := congrArg List.length h
  simp [List.length_append] at h_last

/-- `freezeResource` emits exactly one event (the nonce advance) and
    no action events. -/
theorem extractEvents_freeze_only_nonce
    (pre post : ExtendedState) (r : ResourceId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    extractEvents pre post ⟨.freezeResource r, signer, nonce, sig⟩ =
    [Event.nonceAdvanced signer (expectsNonce pre signer) (expectsNonce post signer)] := by
  rfl

/-- `replaceKey` emits the registration event, then the nonce event. -/
theorem extractEvents_replaceKey_emits_registration
    (pre post : ExtendedState) (actor : ActorId) (newKey : PublicKey)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    extractEvents pre post ⟨.replaceKey actor newKey, signer, nonce, sig⟩ =
    [Event.identityRegistered actor newKey,
     Event.nonceAdvanced signer (expectsNonce pre signer) (expectsNonce post signer)] := by
  rfl

/-! ## Workstream C.5 — bridge event extraction

The `deposit` and `withdraw` actions emit a delta-filtered
`balanceChanged` event, then the unconditional bridge semantic
event (`depositCredited` / `withdrawalRequested`), then the
nonce event.  The semantic event is NOT delta-filtered, so a
zero-amount deposit / withdrawal still emits the bridge event
(matching the `rewardIssued` convention from the Phase-6
incentive amendment). -/

/-- `deposit` always emits a `depositCredited` event in its
    output list (Workstream C.5).  Post-GP the output shape is
    `actEvts ++ topUpSignerBalanceEvt ++ bridgeEvts ++ lpEvts ++
    faultProofEvts ++ gasPoolEvts ++ nonceEvt`; for a `deposit`
    action `topUpSignerBalanceEvt = []`, `lpEvts = []`,
    `faultProofEvts = []`, `gasPoolEvts = []`, so the
    `depositCredited` is in the `bridgeEvts` segment (position 3). -/
theorem extractEvents_deposit_emits_credited
    (pre post : ExtendedState) (r : ResourceId) (recipient : ActorId)
    (amount : Amount) (d : LegalKernel.Bridge.DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    Event.depositCredited r recipient amount d ∈
    extractEvents pre post
      ⟨.deposit r recipient amount d, signer, nonce, sig⟩ := by
  unfold extractEvents
  -- Full output: actEvts ++ topUpSignerBalanceEvt ++ bridgeEvts
  --              ++ lpEvts ++ faultProofEvts ++ gasPoolEvts ++ nonceEvt.
  show _ ∈ _ ++ _ ++ [Event.depositCredited r recipient amount d]
                ++ _ ++ _ ++ _ ++ _
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inr ?_)
  exact List.mem_singleton.mpr rfl

/-- `withdraw` always emits a `withdrawalRequested` event in its
    output list (Workstream C.5).  The withdrawal id is exactly
    the *pre*-state's `BridgeState.nextWdId`. -/
theorem extractEvents_withdraw_emits_requested
    (pre post : ExtendedState) (r : ResourceId) (sender : ActorId)
    (amount : Amount) (rcp : LegalKernel.Bridge.EthAddress)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    Event.withdrawalRequested r sender amount rcp pre.bridge.nextWdId ∈
    extractEvents pre post
      ⟨.withdraw r sender amount rcp, signer, nonce, sig⟩ := by
  unfold extractEvents
  show _ ∈ _ ++ _ ++ [Event.withdrawalRequested r sender amount rcp pre.bridge.nextWdId]
                ++ _ ++ _ ++ _ ++ _
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inr ?_)
  exact List.mem_singleton.mpr rfl

/-! ## Workstream LP / LP.10 — local-policy event extraction

The `declareLocalPolicy` and `revokeLocalPolicy` actions emit a
`localPolicyDeclared` or `localPolicyRevoked` event, then the
nonce event.  The semantic event is NOT delta-filtered: an
idempotent re-declaration (same policy as before) still emits
the event, mirroring the `rewardIssued` / bridge-event
convention. -/

/-- LP.10: `declareLocalPolicy` always emits a `localPolicyDeclared`
    event in its output list.  The event carries the signer as the
    actor (per-actor policies are declared by their owner). -/
theorem extractEvents_declareLocalPolicy_emits_localPolicyDeclared
    (pre post : ExtendedState) (p : Authority.LocalPolicy)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    Event.localPolicyDeclared signer p ∈
    extractEvents pre post
      ⟨.declareLocalPolicy p, signer, nonce, sig⟩ := by
  unfold extractEvents
  -- Output shape (post-GP): actEvts ++ topUpSignerBalanceEvt ++ bridgeEvts
  --                          ++ lpEvts ++ faultProofEvts ++ gasPoolEvts ++ nonceEvt.
  -- The localPolicyDeclared event is in the `lpEvts` segment (position 4).
  show _ ∈ _ ++ _ ++ _ ++ [Event.localPolicyDeclared signer p] ++ _ ++ _ ++ _
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inr ?_)
  exact List.mem_singleton.mpr rfl

/-- LP.10: `revokeLocalPolicy` always emits a `localPolicyRevoked`
    event in its output list. -/
theorem extractEvents_revokeLocalPolicy_emits_localPolicyRevoked
    (pre post : ExtendedState)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    Event.localPolicyRevoked signer ∈
    extractEvents pre post
      ⟨.revokeLocalPolicy, signer, nonce, sig⟩ := by
  unfold extractEvents
  show _ ∈ _ ++ _ ++ _ ++ [Event.localPolicyRevoked signer] ++ _ ++ _ ++ _
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inr ?_)
  exact List.mem_singleton.mpr rfl

/-! ## Workstream H — fault-proof event extraction

The `faultProofChallenge` and `faultProofResolution` actions emit
a corresponding `faultProofGameOpened` or `faultProofGameSettled`
event in the `faultProofEvts` segment of the output list. -/

/-- Workstream H §12.3: `faultProofChallenge` always emits a
    `faultProofGameOpened` event in its output list.  The event
    carries `gameId = 0` as a placeholder (the L1 contract
    assigns the actual gameId on `initiateChallenge`); the
    canonical match is via `bindingHash`.  Indexers consume this
    event to maintain a "open challenges" view per actor. -/
theorem extractEvents_faultProofChallenge_emits_gameOpened
    (pre post : ExtendedState) (bh : ByteArray)
    (sIdx eIdx : LegalKernel.Disputes.LogIndex) (cc : ByteArray)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    Event.faultProofGameOpened 0 signer sIdx eIdx bh ∈
    extractEvents pre post
      ⟨.faultProofChallenge bh sIdx eIdx cc, signer, nonce, sig⟩ := by
  unfold extractEvents
  -- Output shape (post-GP): actEvts ++ topUpSignerBalanceEvt ++ bridgeEvts
  --                          ++ lpEvts ++ faultProofEvts ++ gasPoolEvts ++ nonceEvt.
  -- faultProofGameOpened is in the `faultProofEvts` segment (position 5).
  show _ ∈ _ ++ _ ++ _ ++ _ ++ [Event.faultProofGameOpened 0 signer sIdx eIdx bh] ++ _ ++ _
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inr ?_)
  exact List.mem_singleton.mpr rfl

/-- Workstream H §12.3: `faultProofResolution` always emits a
    `faultProofGameSettled` event in its output list.  The event
    carries the L1-assigned `gameId`, the `winner` (from the action
    field), and the `loser` (set to the signer — the actor that
    appended the resolution log entry). -/
theorem extractEvents_faultProofResolution_emits_gameSettled
    (pre post : ExtendedState) (bh : ByteArray) (gid : Nat)
    (winner : ActorId) (rfi : LegalKernel.Disputes.LogIndex)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    Event.faultProofGameSettled gid winner signer 0 ∈
    extractEvents pre post
      ⟨.faultProofResolution bh gid winner rfi, signer, nonce, sig⟩ := by
  unfold extractEvents
  show _ ∈ _ ++ _ ++ _ ++ _ ++ [Event.faultProofGameSettled gid winner signer 0] ++ _ ++ _
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inr ?_)
  exact List.mem_singleton.mpr rfl

/-! ## Workstream GP §15E — gas-pool event extraction

The `depositWithFee` and `topUpActionBudget` actions emit their
respective semantic events (`depositWithFeeCredited` /
`actionBudgetTopUp`) in the `gasPoolEvts` segment of the output
list.  Both events are emitted UNCONDITIONALLY: a zero-amount
deposit or top-up still emits the corresponding semantic event
(matching the `rewardIssued` / bridge / LP / fault-proof event
convention). -/

/-- Workstream GP §15E (v1.0): `depositWithFee` always emits a
    `depositWithFeeCredited` event in its output list.  The event
    carries the full action payload (resource, recipient,
    poolActor, userAmount, poolAmount, budgetGrant, depositId).
    Indexers consume this event to maintain a per-actor "deposits
    received with fee split" view. -/
theorem extractEvents_depositWithFee_emits_credited
    (pre post : ExtendedState) (r : ResourceId)
    (recipient poolActor : ActorId)
    (userAmount poolAmount : Amount) (budgetGrant : Nat)
    (depositId : LegalKernel.Bridge.DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    Event.depositWithFeeCredited r recipient poolActor userAmount
                                  poolAmount budgetGrant depositId ∈
    extractEvents pre post
      ⟨.depositWithFee r recipient poolActor userAmount poolAmount
                        budgetGrant depositId, signer, nonce, sig⟩ := by
  unfold extractEvents
  -- The depositWithFeeCredited event is in the `gasPoolEvts`
  -- segment (position 6 in the 7-segment output list).
  show _ ∈ _ ++ _ ++ _ ++ _ ++ _ ++
            [Event.depositWithFeeCredited r recipient poolActor userAmount
                                            poolAmount budgetGrant depositId] ++ _
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inr ?_)
  exact List.mem_singleton.mpr rfl

/-- Workstream GP §15E (v1.0): `topUpActionBudget` always emits an
    `actionBudgetTopUp` event in its output list.  The event
    carries the signer (whose budget is incremented) + the action
    payload (gasResource, gasAmount, budgetIncrement, poolActor). -/
theorem extractEvents_topUpActionBudget_emits_topUp
    (pre post : ExtendedState) (gasResource : ResourceId)
    (gasAmount : Amount) (budgetIncrement : Nat) (poolActor : ActorId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    Event.actionBudgetTopUp signer gasResource gasAmount budgetIncrement
                              poolActor ∈
    extractEvents pre post
      ⟨.topUpActionBudget gasResource gasAmount budgetIncrement poolActor,
        signer, nonce, sig⟩ := by
  unfold extractEvents
  -- The actionBudgetTopUp event is in the `gasPoolEvts` segment.
  show _ ∈ _ ++ _ ++ _ ++ _ ++ _ ++
            [Event.actionBudgetTopUp signer gasResource gasAmount budgetIncrement
                                       poolActor] ++ _
  refine List.mem_append.mpr (Or.inl ?_)
  refine List.mem_append.mpr (Or.inr ?_)
  exact List.mem_singleton.mpr rfl

end Events
end LegalKernel
