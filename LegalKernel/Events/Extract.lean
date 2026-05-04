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
| `reward r to a`         | `balanceChanged r to` (if to's balance changed)                                |
| `distributeOthers r e a`| one `balanceChanged` per affected actor whose balance changed                  |
| `proportionalDilute …`  | one `balanceChanged` per affected actor whose balance changed                  |

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
import LegalKernel.Events.Types

open Std

namespace LegalKernel
namespace Events

open LegalKernel.Authority

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
  | .reward r to _a =>
    let oldV := LegalKernel.getBalance preState  r to
    let newV := LegalKernel.getBalance postState r to
    if oldV != newV then [.balanceChanged r to oldV newV] else []
  | .distributeOthers r excluded _a =>
    balanceChangeEvents preState postState r (affectedActors preState r excluded)
  | .proportionalDilute r excluded _tr =>
    balanceChangeEvents preState postState r (affectedActors preState r excluded)

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
  let oldN     := expectsNonce preState  st.signer
  let newN     := expectsNonce postState st.signer
  let nonceEvt := [Event.nonceAdvanced st.signer oldN newN]
  actEvts ++ nonceEvt

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
  -- The result is `actionEvents ++ [nonceEvt]`; the second list has
  -- length 1, so the concatenation has length ≥ 1, so it is non-empty.
  intro h
  have hlen : (actionEvents pre.base post.base st.action ++
                 [Event.nonceAdvanced st.signer (expectsNonce pre st.signer)
                                                (expectsNonce post st.signer)]).length = 0 := by
    rw [h]; rfl
  simp [List.length_append] at hlen

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

end Events
end LegalKernel
