/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
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
    `r`'s pre-state `BalanceMap`, minus the excluded actor. -/
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
  let oldN     := expectsNonce preState  st.signer
  let newN     := expectsNonce postState st.signer
  let nonceEvt := [Event.nonceAdvanced st.signer oldN newN]
  actEvts ++ bridgeEvts ++ nonceEvt

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
    output list (Workstream C.5). -/
theorem extractEvents_deposit_emits_credited
    (pre post : ExtendedState) (r : ResourceId) (recipient : ActorId)
    (amount : Amount) (d : LegalKernel.Bridge.DepositId)
    (signer : ActorId) (nonce : Nonce) (sig : Signature) :
    Event.depositCredited r recipient amount d ∈
    extractEvents pre post
      ⟨.deposit r recipient amount d, signer, nonce, sig⟩ := by
  unfold extractEvents
  -- The bridgeEvts list is `[Event.depositCredited r recipient amount d]`.
  -- The full output is `actEvts ++ bridgeEvts ++ nonceEvt`; the
  -- depositCredited is the unique element of bridgeEvts.
  show _ ∈ _ ++ [Event.depositCredited r recipient amount d] ++ _
  exact List.mem_append.mpr (Or.inl
    (List.mem_append.mpr (Or.inr (List.mem_singleton.mpr rfl))))

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
  show _ ∈ _ ++ [Event.withdrawalRequested r sender amount rcp pre.bridge.nextWdId] ++ _
  exact List.mem_append.mpr (Or.inl
    (List.mem_append.mpr (Or.inr (List.mem_singleton.mpr rfl))))

end Events
end LegalKernel
