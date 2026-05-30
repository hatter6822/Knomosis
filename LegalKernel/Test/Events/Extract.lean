/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Events.Extract — Phase-5 WU 5.6 tests for the
`extractEvents` function.

We exercise the per-action event-emission contract by constructing
hand-built `(pre, post)` `ExtendedState` pairs and verifying the
expected event list.  The pre/post pairs are *constructed*, not
*applied via the kernel* — this isolates `extractEvents`'s logic
from the kernel's apply path.
-/

import LegalKernel.Test.Framework
import LegalKernel.Events.Extract

namespace LegalKernel.Test.Events
namespace ExtractTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Events

/-- The dummy signature used in test fixtures. -/
def dummySig : Signature := ⟨#[0x99]⟩

/-- A pre-state with actor 1 holding 100 of resource 1.  Used by
    most balance-change tests. -/
def preStateOneHundred : ExtendedState :=
  { base    := setBalance ({ balances := ∅ }) 1 1 100
  , nonces  := { next := ∅ }
  , registry := KeyRegistry.empty }

/-- Post-state for a successful "transfer 30 from 1 to 2" action. -/
def postTransfer : ExtendedState :=
  let s' := setBalance preStateOneHundred.base 1 1 70
  let s'' := setBalance s' 1 2 30
  { base := s'', nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 },
    registry := KeyRegistry.empty }

/-- A transfer of 30 from actor 1 to actor 2 should emit two
    balanceChanged events plus a nonceAdvanced plus (post-GP.6.4)
    a `budgetConsumed` event for the non-bridge signer. -/
def transferEmitsThreeEvents : TestCase := {
  name := "transfer emits sender + receiver + nonce + budgetConsumed events"
  body := do
    let st : SignedAction := ⟨.transfer 1 1 2 30, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred postTransfer st
    -- 4 = 2 balanceChanged + 1 budgetConsumed + 1 nonceAdvanced
    -- (the genesis budget policy `.bounded 0 1 0` has actionCost=1,
    -- so non-bridge signer=1 emits `budgetConsumed 1 1`).
    assertEq (4 : Nat) evs.length "event count"
}

/-- `freezeResource` emits only the nonce event + (post-GP.6.4) a
    budgetConsumed event for the non-bridge signer. -/
def freezeOneEvent : TestCase := {
  name := "freezeResource emits nonce + budgetConsumed events"
  body := do
    let post : ExtendedState :=
      { preStateOneHundred with
        nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let st : SignedAction := ⟨.freezeResource 1, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    -- 2 = 1 budgetConsumed + 1 nonceAdvanced (genesis policy
    -- consumes actionCost=1 from non-bridge signer=1).
    assertEq (2 : Nat) evs.length "event count"
    let expected : List Event :=
      [.budgetConsumed 1 1, .nonceAdvanced 1 0 1]
    if evs == expected then pure ()
    else throw <| IO.userError s!"unexpected events: {repr evs}"
}

/-- **GP.6.4 bridgeActor exemption (security-relevant).**  A
    bridgeActor-signed action (signer = `Bridge.bridgeActor` = 0)
    must NOT emit a `budgetConsumed` event, EXACTLY mirroring the
    kernel's consume exemption (`apply_admissible_with_budget`
    GP.3.2.c): bridge-signed actions are L1-gas-gated upstream, so
    they skip the L2 budget consume.  Emitting a spurious
    `budgetConsumed` for the bridgeActor would corrupt an
    indexer's per-epoch consumption accounting. -/
def bridgeActorEmitsNoBudgetConsumed : TestCase := {
  name := "bridgeActor signer emits NO budgetConsumed event"
  body := do
    let post : ExtendedState :=
      { preStateOneHundred with
        nonces := { next := (∅ : Std.TreeMap _ _ _).insert 0 1 } }
    -- signer = 0 = Bridge.bridgeActor; genesis policy actionCost=1.
    let st : SignedAction := ⟨.freezeResource 1, 0, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    -- Only the nonce event — NO budgetConsumed (bridgeActor exempt).
    assertEq (1 : Nat) evs.length "event count"
    let hasBudgetConsumed := evs.any (fun e => match e with
      | .budgetConsumed _ _ => true | _ => false)
    if hasBudgetConsumed then
      throw <| IO.userError "bridgeActor must not emit budgetConsumed"
    else pure ()
}

/-- **GP.6.4 zero-actionCost.**  Under a `.bounded freeTier 0 _`
    policy (actionCost = 0), a non-bridge signer's admitted action
    consumes 0 budget, so NO `budgetConsumed` event is emitted
    (the kernel's consume of 0 is a balance no-op).  Pins the
    `actionCost > 0` guard in the emission. -/
def zeroActionCostEmitsNoBudgetConsumed : TestCase := {
  name := "zero actionCost emits NO budgetConsumed event"
  body := do
    -- Pre-state with budgetPolicy actionCost = 0.
    let pre : ExtendedState :=
      { preStateOneHundred with budgetPolicy := .bounded 5 0 0 }
    let post : ExtendedState :=
      { pre with nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    -- Non-bridge signer = 1, actionCost = 0.
    let st : SignedAction := ⟨.freezeResource 1, 1, 0, dummySig⟩
    let evs := extractEvents pre post st
    assertEq (1 : Nat) evs.length "event count"
    let hasBudgetConsumed := evs.any (fun e => match e with
      | .budgetConsumed _ _ => true | _ => false)
    if hasBudgetConsumed then
      throw <| IO.userError "actionCost=0 must not emit budgetConsumed"
    else pure ()
}

/-- **GP.6.4 emission-theorem API stability.**  Pins the term-level
    signature of `extractEvents_emits_budgetConsumed_for_non_bridge_signer`
    (the positive-case characterization). -/
def emitsBudgetConsumedAPI : TestCase := {
  name := "extractEvents_emits_budgetConsumed_for_non_bridge_signer API stable"
  body := do
    let _proof : ∀ (pre post : ExtendedState) (st : SignedAction) (actionCost : Nat),
        st.signer ≠ Bridge.bridgeActor →
        (∃ freeTier currentEpoch,
          pre.budgetPolicy = .bounded freeTier actionCost currentEpoch) →
        actionCost > 0 →
        Event.budgetConsumed st.signer actionCost ∈ extractEvents pre post st :=
      extractEvents_emits_budgetConsumed_for_non_bridge_signer
    pure ()
}

/-- `replaceKey` should emit identityRegistered + nonceAdvanced +
    (post-GP.6.4) a budgetConsumed event for the non-bridge signer. -/
def replaceKeyTwoEvents : TestCase := {
  name := "replaceKey emits registration + nonce + budgetConsumed events"
  body := do
    let pk : PublicKey := ⟨#[0x42]⟩
    let post : ExtendedState :=
      { preStateOneHundred with
        nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
        registry := KeyRegistry.empty.register 5 pk }
    let st : SignedAction := ⟨.replaceKey 5 pk, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    -- 3 = identityRegistered + budgetConsumed + nonceAdvanced.
    assertEq (3 : Nat) evs.length "event count"
}

/-- `mint` of 50 to actor 1 emits balanceChanged + nonceAdvanced +
    (post-GP.6.4) a budgetConsumed event for the non-bridge signer. -/
def mintTwoEvents : TestCase := {
  name := "mint emits balance + nonce + budgetConsumed events"
  body := do
    let post : ExtendedState :=
      { base := setBalance preStateOneHundred.base 1 1 150
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction := ⟨.mint 1 1 50, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    -- 3 = balanceChanged + budgetConsumed + nonceAdvanced.
    assertEq (3 : Nat) evs.length "event count"
}

/-- `burn` of 30 from actor 1 emits balanceChanged + nonceAdvanced +
    (post-GP.6.4) a budgetConsumed event for the non-bridge signer. -/
def burnTwoEvents : TestCase := {
  name := "burn emits balance + nonce + budgetConsumed events"
  body := do
    let post : ExtendedState :=
      { base := setBalance preStateOneHundred.base 1 1 70
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction := ⟨.burn 1 1 30, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    -- 3 = balanceChanged + budgetConsumed + nonceAdvanced.
    assertEq (3 : Nat) evs.length "event count"
}

/-- `reward` of 10 to actor 1 emits balanceChanged + rewardIssued +
    nonceAdvanced (Phase-6 incentive-integration amendment: the
    `rewardIssued` semantic event is unconditionally emitted on
    every reward action) + (post-GP.6.4) a budgetConsumed event. -/
def rewardThreeEvents : TestCase := {
  name := "reward emits balance + rewardIssued + nonce + budgetConsumed events"
  body := do
    let post : ExtendedState :=
      { base := setBalance preStateOneHundred.base 1 1 110
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction := ⟨.reward 1 1 10, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    -- 4 = balanceChanged + rewardIssued + budgetConsumed + nonceAdvanced.
    assertEq (4 : Nat) evs.length "event count"
}

/-- `reward` of 0 (zero-amount courtesy reward) emits ONLY the
    `rewardIssued` semantic event + the always-present
    `nonceAdvanced` + (post-GP.6.4) the budgetConsumed event.
    No `balanceChanged` because the delta is zero.  Documents that
    `rewardIssued` is NOT delta-filtered. -/
def rewardZeroAmountEmitsRewardIssued : TestCase := {
  name := "reward 0 emits rewardIssued + nonce + budgetConsumed (no balanceChanged)"
  body := do
    let post : ExtendedState :=
      { base := preStateOneHundred.base
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction := ⟨.reward 1 1 0, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    -- 3 = rewardIssued + budgetConsumed + nonceAdvanced.
    assertEq (3 : Nat) evs.length "event count"
}

/-- `transfer` action emits no `rewardIssued` event — the
    `rewardIssued` constructor is only emitted by `Action.reward`. -/
def transferNoRewardIssued : TestCase := {
  name := "transfer emits no rewardIssued event"
  body := do
    let post : ExtendedState :=
      { base := preStateOneHundred.base
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction := ⟨.transfer 1 1 2 30, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    -- Filter for rewardIssued events; should be empty.
    let rewardEvs := evs.filter Event.isRewardIssued
    assertEq (0 : Nat) rewardEvs.length "rewardIssued event count"
}

/-- Self-transfer (sender = receiver, amount > 0) emits no balance
    events (zero delta) but still emits the nonce event +
    (post-GP.6.4) the budgetConsumed event for the non-bridge
    signer. -/
def selfTransferOneEvent : TestCase := {
  name := "self-transfer emits only nonce + budgetConsumed events"
  body := do
    -- Self-transfer leaves the balance unchanged; only the nonce advances.
    let post : ExtendedState :=
      { preStateOneHundred with
        nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let st : SignedAction := ⟨.transfer 1 1 1 30, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    -- Self-transfer at the same actor: oldV = newV, so no balanceChanged.
    -- 2 = budgetConsumed + nonceAdvanced.
    assertEq (2 : Nat) evs.length "event count"
}

/-- Determinism: equal inputs produce equal event lists. -/
def determinism : TestCase := {
  name := "extractEvents is deterministic"
  body := do
    let st : SignedAction := ⟨.transfer 1 1 2 30, 1, 0, dummySig⟩
    let evs1 := extractEvents preStateOneHundred postTransfer st
    let evs2 := extractEvents preStateOneHundred postTransfer st
    if evs1 == evs2 then pure ()
    else throw <| IO.userError "non-deterministic extractEvents"
}

/-- Term-level API: `extractEvents_deterministic`. -/
def determinismAPI : TestCase := {
  name := "extractEvents_deterministic API stability"
  body := do
    let _proof : ∀ (pre₁ post₁ : ExtendedState) (st₁ : SignedAction)
                   (pre₂ post₂ : ExtendedState) (st₂ : SignedAction),
                   pre₁ = pre₂ → post₁ = post₂ → st₁ = st₂ →
                   extractEvents pre₁ post₁ st₁ = extractEvents pre₂ post₂ st₂ :=
      extractEvents_deterministic
    pure ()
}

/-- Term-level API: `extractEvents_nonempty`. -/
def nonemptyAPI : TestCase := {
  name := "extractEvents_nonempty API stability"
  body := do
    let _proof : ∀ (pre post : ExtendedState) (st : SignedAction),
                   extractEvents pre post st ≠ [] :=
      extractEvents_nonempty
    pure ()
}

/-! ## Workstream C.5 — bridge event extraction tests -/

/-- A deposit emits `depositCredited` (Workstream C.5). -/
def depositEmitsCredited : TestCase := {
  name := "deposit emits depositCredited event"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { base := setBalance preStateOneHundred.base 1 5 200
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction := ⟨.deposit 1 5 200 99, 1, 0, dummySig⟩
    let evs := extractEvents pre post st
    -- Should contain a depositCredited event.
    let depEvs := evs.filter (· matches Event.depositCredited _ _ _ _)
    assertEq (1 : Nat) depEvs.length "depositCredited count"
}

/-- A withdrawal emits `withdrawalRequested` (Workstream C.5). -/
def withdrawEmitsRequested : TestCase := {
  name := "withdraw emits withdrawalRequested event"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { base := setBalance preStateOneHundred.base 1 1 70
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction :=
      ⟨.withdraw 1 1 30 LegalKernel.Bridge.EthAddress.zero, 1, 0, dummySig⟩
    let evs := extractEvents pre post st
    let wdEvs := evs.filter (· matches Event.withdrawalRequested _ _ _ _ _)
    assertEq (1 : Nat) wdEvs.length "withdrawalRequested count"
}

/-- A zero-amount deposit still emits the depositCredited event. -/
def depositZeroAmountEmitsCredited : TestCase := {
  name := "deposit with zero amount still emits depositCredited"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { pre with nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let st : SignedAction := ⟨.deposit 1 5 0 99, 1, 0, dummySig⟩
    let evs := extractEvents pre post st
    let depEvs := evs.filter (· matches Event.depositCredited _ _ _ _)
    assertEq (1 : Nat) depEvs.length "depositCredited still emitted"
}

/-- Term-level API: `extractEvents_deposit_emits_credited`. -/
def depositEmitsCreditedAPI : TestCase := {
  name := "extractEvents_deposit_emits_credited: term-level API"
  body := do
    let _proof : ∀ (pre post : ExtendedState) (r : ResourceId)
                   (recipient : ActorId) (amount : Amount)
                   (d : LegalKernel.Bridge.DepositId)
                   (signer : ActorId) (nonce : Nonce) (sig : Signature),
                   Event.depositCredited r recipient amount d ∈
                   extractEvents pre post
                     ⟨.deposit r recipient amount d, signer, nonce, sig⟩ :=
      extractEvents_deposit_emits_credited
    pure ()
}

/-- Term-level API: `extractEvents_withdraw_emits_requested`. -/
def withdrawEmitsRequestedAPI : TestCase := {
  name := "extractEvents_withdraw_emits_requested: term-level API"
  body := do
    let _proof : ∀ (pre post : ExtendedState) (r : ResourceId)
                   (sender : ActorId) (amount : Amount)
                   (rcp : LegalKernel.Bridge.EthAddress)
                   (signer : ActorId) (nonce : Nonce) (sig : Signature),
                   Event.withdrawalRequested r sender amount rcp pre.bridge.nextWdId ∈
                   extractEvents pre post
                     ⟨.withdraw r sender amount rcp, signer, nonce, sig⟩ :=
      extractEvents_withdraw_emits_requested
    pure ()
}

/-! ## Workstream LP / LP.10 — local-policy event extraction tests -/

/-- A `declareLocalPolicy` action emits a `localPolicyDeclared` event. -/
def declareEmitsLocalPolicyDeclared : TestCase := {
  name := "declareLocalPolicy emits localPolicyDeclared event"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { pre with nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let p : LocalPolicy := { clauses := [.denyTags [0]] }
    let st : SignedAction := ⟨.declareLocalPolicy p, 1, 0, dummySig⟩
    let evs := extractEvents pre post st
    let lpEvs := evs.filter (· matches Event.localPolicyDeclared _ _)
    assertEq (1 : Nat) lpEvs.length "localPolicyDeclared count"
}

/-- A `revokeLocalPolicy` action emits a `localPolicyRevoked` event. -/
def revokeEmitsLocalPolicyRevoked : TestCase := {
  name := "revokeLocalPolicy emits localPolicyRevoked event"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { pre with nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let st : SignedAction := ⟨.revokeLocalPolicy, 1, 0, dummySig⟩
    let evs := extractEvents pre post st
    let lpEvs := evs.filter (· matches Event.localPolicyRevoked _)
    assertEq (1 : Nat) lpEvs.length "localPolicyRevoked count"
}

/-- A `declareLocalPolicy` emits exactly the LP semantic event +
    (post-GP.6.4) budgetConsumed + nonce-advance.  No balance events. -/
def declareTwoEvents : TestCase := {
  name := "declareLocalPolicy emits LP event + budgetConsumed + nonce event"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { pre with nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let p : LocalPolicy := { clauses := [] }
    let st : SignedAction := ⟨.declareLocalPolicy p, 1, 0, dummySig⟩
    let evs := extractEvents pre post st
    -- 3 = LP + budgetConsumed + nonce.
    assertEq (3 : Nat) evs.length "event count: LP + budgetConsumed + nonce"
}

/-- A `revokeLocalPolicy` emits exactly the LP semantic event +
    (post-GP.6.4) budgetConsumed + nonce-advance. -/
def revokeTwoEvents : TestCase := {
  name := "revokeLocalPolicy emits LP event + budgetConsumed + nonce event"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { pre with nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let st : SignedAction := ⟨.revokeLocalPolicy, 1, 0, dummySig⟩
    let evs := extractEvents pre post st
    -- 3 = LP + budgetConsumed + nonce.
    assertEq (3 : Nat) evs.length "event count: LP + budgetConsumed + nonce"
}

/-- The signer is the actor recorded in the LP event (per LP.10:
    "LP actions are by construction signer-mutating only"). -/
def lpEventCarriesSigner : TestCase := {
  name := "LP events carry the signer as actor"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { pre with nonces := { next := (∅ : Std.TreeMap _ _ _).insert 7 1 } }
    let p : LocalPolicy := { clauses := [.denyTags [0]] }
    let st : SignedAction := ⟨.declareLocalPolicy p, 7, 0, dummySig⟩
    let evs := extractEvents pre post st
    -- The localPolicyDeclared event should carry actor=7 (the signer).
    if evs.any (fun e => match e with
                          | .localPolicyDeclared 7 _ => true
                          | _ => false) then pure ()
    else throw <| IO.userError "localPolicyDeclared did not carry signer"
}

/-- LP-event emission is deterministic: equal inputs produce equal events. -/
def lpEventDeterministic : TestCase := {
  name := "LP-event emission is deterministic"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { pre with nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let p : LocalPolicy := { clauses := [.denyTags [0]] }
    let st : SignedAction := ⟨.declareLocalPolicy p, 1, 0, dummySig⟩
    let evs1 := extractEvents pre post st
    let evs2 := extractEvents pre post st
    if evs1 == evs2 then pure ()
    else throw <| IO.userError "non-deterministic LP event extraction"
}

/-- Term-level API: `extractEvents_declareLocalPolicy_emits_localPolicyDeclared`. -/
def declareEmitsAPI : TestCase := {
  name := "extractEvents_declareLocalPolicy_emits_localPolicyDeclared: term-level API"
  body := do
    let _proof : ∀ (pre post : ExtendedState) (p : LocalPolicy)
                   (signer : ActorId) (nonce : Nonce) (sig : Signature),
                   Event.localPolicyDeclared signer p ∈
                   extractEvents pre post
                     ⟨.declareLocalPolicy p, signer, nonce, sig⟩ :=
      extractEvents_declareLocalPolicy_emits_localPolicyDeclared
    pure ()
}

/-- Term-level API: `extractEvents_revokeLocalPolicy_emits_localPolicyRevoked`. -/
def revokeEmitsAPI : TestCase := {
  name := "extractEvents_revokeLocalPolicy_emits_localPolicyRevoked: term-level API"
  body := do
    let _proof : ∀ (pre post : ExtendedState)
                   (signer : ActorId) (nonce : Nonce) (sig : Signature),
                   Event.localPolicyRevoked signer ∈
                   extractEvents pre post
                     ⟨.revokeLocalPolicy, signer, nonce, sig⟩ :=
      extractEvents_revokeLocalPolicy_emits_localPolicyRevoked
    pure ()
}

/-- All tests. -/
def tests : List TestCase :=
  [transferEmitsThreeEvents, freezeOneEvent, replaceKeyTwoEvents,
   mintTwoEvents, burnTwoEvents, rewardThreeEvents,
   rewardZeroAmountEmitsRewardIssued, transferNoRewardIssued,
   selfTransferOneEvent,
   determinism, determinismAPI, nonemptyAPI,
   depositEmitsCredited, withdrawEmitsRequested,
   depositZeroAmountEmitsCredited,
   depositEmitsCreditedAPI, withdrawEmitsRequestedAPI,
   -- LP.10:
   declareEmitsLocalPolicyDeclared, revokeEmitsLocalPolicyRevoked,
   declareTwoEvents, revokeTwoEvents,
   lpEventCarriesSigner, lpEventDeterministic,
   declareEmitsAPI, revokeEmitsAPI,
   -- GP.6.4:
   bridgeActorEmitsNoBudgetConsumed, zeroActionCostEmitsNoBudgetConsumed,
   emitsBudgetConsumedAPI]

end ExtractTests
end LegalKernel.Test.Events
