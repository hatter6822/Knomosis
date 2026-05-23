/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
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
    balanceChanged events plus a nonceAdvanced. -/
def transferEmitsThreeEvents : TestCase := {
  name := "transfer emits sender + receiver + nonce events"
  body := do
    let st : SignedAction := ⟨.transfer 1 1 2 30, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred postTransfer st
    assertEq (3 : Nat) evs.length "event count"
}

/-- `freezeResource` should emit only the nonce event. -/
def freezeOneEvent : TestCase := {
  name := "freezeResource emits only nonce event"
  body := do
    let post : ExtendedState :=
      { preStateOneHundred with
        nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let st : SignedAction := ⟨.freezeResource 1, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    assertEq (1 : Nat) evs.length "event count"
    let expected : Event := .nonceAdvanced 1 0 1
    if evs == [expected] then pure ()
    else throw <| IO.userError s!"unexpected events: {repr evs}"
}

/-- `replaceKey` should emit identityRegistered + nonceAdvanced. -/
def replaceKeyTwoEvents : TestCase := {
  name := "replaceKey emits registration + nonce events"
  body := do
    let pk : PublicKey := ⟨#[0x42]⟩
    let post : ExtendedState :=
      { preStateOneHundred with
        nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
        registry := KeyRegistry.empty.register 5 pk }
    let st : SignedAction := ⟨.replaceKey 5 pk, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    assertEq (2 : Nat) evs.length "event count"
}

/-- `mint` of 50 to actor 1 emits balanceChanged + nonceAdvanced. -/
def mintTwoEvents : TestCase := {
  name := "mint emits balance + nonce events"
  body := do
    let post : ExtendedState :=
      { base := setBalance preStateOneHundred.base 1 1 150
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction := ⟨.mint 1 1 50, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    assertEq (2 : Nat) evs.length "event count"
}

/-- `burn` of 30 from actor 1 emits balanceChanged + nonceAdvanced. -/
def burnTwoEvents : TestCase := {
  name := "burn emits balance + nonce events"
  body := do
    let post : ExtendedState :=
      { base := setBalance preStateOneHundred.base 1 1 70
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction := ⟨.burn 1 1 30, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    assertEq (2 : Nat) evs.length "event count"
}

/-- `reward` of 10 to actor 1 emits balanceChanged + rewardIssued +
    nonceAdvanced (Phase-6 incentive-integration amendment: the
    `rewardIssued` semantic event is unconditionally emitted on
    every reward action). -/
def rewardThreeEvents : TestCase := {
  name := "reward emits balance + rewardIssued + nonce events"
  body := do
    let post : ExtendedState :=
      { base := setBalance preStateOneHundred.base 1 1 110
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction := ⟨.reward 1 1 10, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    assertEq (3 : Nat) evs.length "event count"
}

/-- `reward` of 0 (zero-amount courtesy reward) emits ONLY the
    `rewardIssued` semantic event + the always-present
    `nonceAdvanced`.  No `balanceChanged` because the delta is
    zero.  Documents that `rewardIssued` is NOT delta-filtered. -/
def rewardZeroAmountEmitsRewardIssued : TestCase := {
  name := "reward 0 emits rewardIssued + nonce (no balanceChanged)"
  body := do
    let post : ExtendedState :=
      { base := preStateOneHundred.base
      , nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 }
      , registry := KeyRegistry.empty }
    let st : SignedAction := ⟨.reward 1 1 0, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    assertEq (2 : Nat) evs.length "event count"
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
    events (zero delta) but still emits the nonce event. -/
def selfTransferOneEvent : TestCase := {
  name := "self-transfer emits only nonce event"
  body := do
    -- Self-transfer leaves the balance unchanged; only the nonce advances.
    let post : ExtendedState :=
      { preStateOneHundred with
        nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let st : SignedAction := ⟨.transfer 1 1 1 30, 1, 0, dummySig⟩
    let evs := extractEvents preStateOneHundred post st
    -- Self-transfer at the same actor: oldV = newV, so no balanceChanged.
    -- Only the nonceAdvanced event remains.
    assertEq (1 : Nat) evs.length "event count"
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

/-- A `declareLocalPolicy` emits exactly two events: the LP semantic
    event and the nonce-advance event.  No balance events. -/
def declareTwoEvents : TestCase := {
  name := "declareLocalPolicy emits exactly LP event + nonce event"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { pre with nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let p : LocalPolicy := { clauses := [] }
    let st : SignedAction := ⟨.declareLocalPolicy p, 1, 0, dummySig⟩
    let evs := extractEvents pre post st
    assertEq (2 : Nat) evs.length "event count: LP + nonce"
}

/-- A `revokeLocalPolicy` emits exactly two events: the LP semantic
    event and the nonce-advance event. -/
def revokeTwoEvents : TestCase := {
  name := "revokeLocalPolicy emits exactly LP event + nonce event"
  body := do
    let pre : ExtendedState := preStateOneHundred
    let post : ExtendedState :=
      { pre with nonces := { next := (∅ : Std.TreeMap _ _ _).insert 1 1 } }
    let st : SignedAction := ⟨.revokeLocalPolicy, 1, 0, dummySig⟩
    let evs := extractEvents pre post st
    assertEq (2 : Nat) evs.length "event count: LP + nonce"
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
   declareEmitsAPI, revokeEmitsAPI]

end ExtractTests
end LegalKernel.Test.Events
