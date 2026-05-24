/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Events.Types — Phase-5 WU 5.6 tests for the
`Event` inductive.
-/

import LegalKernel.Test.Framework
import LegalKernel.Events.Types

namespace LegalKernel.Test.Events
namespace TypesTests

open LegalKernel.Events
open LegalKernel.Authority

/-- `balanceChanged` is classified as a balance change. -/
def isBalanceChangeT : TestCase := {
  name := "balanceChanged.isBalanceChange = true"
  body := do
    let e : Event := .balanceChanged 1 2 30 40
    assertEq true e.isBalanceChange "isBalanceChange"
}

/-- `nonceAdvanced` is not a balance change. -/
def isBalanceChangeF : TestCase := {
  name := "nonceAdvanced.isBalanceChange = false"
  body := do
    let e : Event := .nonceAdvanced 5 0 1
    assertEq false e.isBalanceChange "isBalanceChange"
}

/-- `identityRegistered` is a registry change. -/
def isRegistryChangeT : TestCase := {
  name := "identityRegistered.isRegistryChange = true"
  body := do
    let e : Event := .identityRegistered 7 ⟨#[0x01]⟩
    assertEq true e.isRegistryChange "isRegistryChange"
}

/-- `identityRevoked` is a registry change. -/
def isRegistryChangeRevoked : TestCase := {
  name := "identityRevoked.isRegistryChange = true"
  body := do
    let e : Event := .identityRevoked 9
    assertEq true e.isRegistryChange "isRegistryChange"
}

/-- The `actor` projection returns `some` for actor-bearing events. -/
def actorProj : TestCase := {
  name := "Event.actor returns expected projection"
  body := do
    assertEq (some (5 : ActorId))
      ((Event.balanceChanged 1 5 30 40).actor) "balanceChanged actor"
    assertEq (some (7 : ActorId))
      ((Event.nonceAdvanced 7 0 1).actor) "nonceAdvanced actor"
    assertEq (none : Option ActorId)
      ((Event.timeRecorded 100).actor) "timeRecorded actor"
}

/-- The `resource` projection returns `some` only for `balanceChanged`. -/
def resourceProj : TestCase := {
  name := "Event.resource projection matches expectation"
  body := do
    assertEq (some (1 : ResourceId))
      ((Event.balanceChanged 1 5 30 40).resource) "balanceChanged resource"
    assertEq (none : Option ResourceId)
      ((Event.nonceAdvanced 7 0 1).resource) "nonceAdvanced resource"
}

/-- Equal events compare equal under DecidableEq. -/
def decEq : TestCase := {
  name := "Event DecidableEq matches structural equality"
  body := do
    let e₁ : Event := .balanceChanged 1 2 30 40
    let e₂ : Event := .balanceChanged 1 2 30 40
    let e₃ : Event := .balanceChanged 1 2 30 41
    if e₁ == e₂ then pure ()
    else throw <| IO.userError "BUG: equal events compared unequal"
    if e₁ == e₃ then
      throw <| IO.userError "BUG: distinct events compared equal"
    else pure ()
}

/-! ## Phase-6 incentive-integration: `Event.rewardIssued` -/

/-- `rewardIssued` projects its actor field. -/
def rewardIssuedActorProj : TestCase := {
  name := "Event.rewardIssued.actor returns recipient"
  body := do
    let e : Event := .rewardIssued 1 5 100
    assertEq (some (5 : ActorId)) e.actor "rewardIssued actor"
}

/-- `rewardIssued` projects its resource field. -/
def rewardIssuedResourceProj : TestCase := {
  name := "Event.rewardIssued.resource returns resource"
  body := do
    let e : Event := .rewardIssued 1 5 100
    assertEq (some (1 : ResourceId)) e.resource "rewardIssued resource"
}

/-- `rewardIssued` is recognised by `Event.isRewardIssued`. -/
def rewardIssuedDetected : TestCase := {
  name := "Event.isRewardIssued = true on rewardIssued"
  body := do
    let e : Event := .rewardIssued 1 5 100
    assertEq true e.isRewardIssued "isRewardIssued"
}

/-- Non-reward events return `false` for `isRewardIssued`. -/
def nonRewardNotDetected : TestCase := {
  name := "Event.isRewardIssued = false on non-reward events"
  body := do
    let e : Event := .balanceChanged 1 2 30 40
    assertEq false e.isRewardIssued "balanceChanged not a rewardIssued"
}

/-- `rewardIssued` is NOT classified as a balance-change event
    (it's a deployment-level semantic event, not a kernel-level
    balance delta). -/
def rewardIssuedNotBalanceChange : TestCase := {
  name := "rewardIssued.isBalanceChange = false"
  body := do
    let e : Event := .rewardIssued 1 5 100
    assertEq false e.isBalanceChange "rewardIssued isBalanceChange"
}

/-- `rewardIssued` is NOT classified as a dispute event. -/
def rewardIssuedNotDisputeEvent : TestCase := {
  name := "rewardIssued.isDisputeEvent = false"
  body := do
    let e : Event := .rewardIssued 1 5 100
    assertEq false e.isDisputeEvent "rewardIssued isDisputeEvent"
}

/-! ## Workstream LP / LP.10: local-policy events -/

/-- `localPolicyDeclared` projects its actor field. -/
def localPolicyDeclaredActorProj : TestCase := {
  name := "Event.localPolicyDeclared.actor returns declarer"
  body := do
    let p : Authority.LocalPolicy := { clauses := [] }
    let e : Event := .localPolicyDeclared 5 p
    assertEq (some (5 : ActorId)) e.actor "localPolicyDeclared actor"
}

/-- `localPolicyDeclared` has no resource projection (LP events
    are not resource-scoped). -/
def localPolicyDeclaredResourceProj : TestCase := {
  name := "Event.localPolicyDeclared.resource = none"
  body := do
    let p : Authority.LocalPolicy := { clauses := [] }
    let e : Event := .localPolicyDeclared 5 p
    assertEq (none : Option ResourceId) e.resource "localPolicyDeclared resource"
}

/-- `localPolicyRevoked` projects its actor field. -/
def localPolicyRevokedActorProj : TestCase := {
  name := "Event.localPolicyRevoked.actor returns revoker"
  body := do
    let e : Event := .localPolicyRevoked 7
    assertEq (some (7 : ActorId)) e.actor "localPolicyRevoked actor"
}

/-- `localPolicyDeclared` is recognised by `Event.isLocalPolicyEvent`. -/
def localPolicyDeclaredDetected : TestCase := {
  name := "Event.isLocalPolicyEvent = true on localPolicyDeclared"
  body := do
    let p : Authority.LocalPolicy := { clauses := [.denyTags [0]] }
    let e : Event := .localPolicyDeclared 1 p
    assertEq true e.isLocalPolicyEvent "isLocalPolicyEvent"
}

/-- `localPolicyRevoked` is recognised by `Event.isLocalPolicyEvent`. -/
def localPolicyRevokedDetected : TestCase := {
  name := "Event.isLocalPolicyEvent = true on localPolicyRevoked"
  body := do
    let e : Event := .localPolicyRevoked 1
    assertEq true e.isLocalPolicyEvent "isLocalPolicyEvent"
}

/-- Non-LP events return `false` for `isLocalPolicyEvent`. -/
def nonLPNotLocalPolicyEvent : TestCase := {
  name := "Event.isLocalPolicyEvent = false on non-LP events"
  body := do
    let e : Event := .balanceChanged 1 2 30 40
    assertEq false e.isLocalPolicyEvent "balanceChanged not LP"
    let e2 : Event := .rewardIssued 1 5 100
    assertEq false e2.isLocalPolicyEvent "rewardIssued not LP"
}

/-- `localPolicyDeclared` is NOT classified as a balance-change. -/
def localPolicyDeclaredNotBalanceChange : TestCase := {
  name := "localPolicyDeclared.isBalanceChange = false"
  body := do
    let p : Authority.LocalPolicy := { clauses := [] }
    let e : Event := .localPolicyDeclared 1 p
    assertEq false e.isBalanceChange "localPolicyDeclared not balance"
}

/-- LP events distinguish in DecidableEq (different actors). -/
def lpEventDecEq : TestCase := {
  name := "LP events compare equal/distinct correctly"
  body := do
    let p₁ : Authority.LocalPolicy := { clauses := [.denyTags [0]] }
    let p₂ : Authority.LocalPolicy := { clauses := [.denyTags [1]] }
    let e₁ : Event := .localPolicyDeclared 1 p₁
    let e₂ : Event := .localPolicyDeclared 1 p₁
    let e₃ : Event := .localPolicyDeclared 1 p₂
    let e₄ : Event := .localPolicyDeclared 2 p₁
    if e₁ == e₂ then pure ()
    else throw <| IO.userError "BUG: equal LP events compared unequal"
    if e₁ == e₃ then
      throw <| IO.userError "BUG: distinct policies compared equal"
    else pure ()
    if e₁ == e₄ then
      throw <| IO.userError "BUG: distinct actors compared equal"
    else pure ()
}

/-! ## AR.6 — Event constructor-tag regression pins

16 elaboration-time pins (one per `Event` constructor), each
asserting the `Event.tag` value via `rfl`.  Any future PR that
reorders the `Event` constructors must update the matching
`Event.tag` match arm in `LegalKernel/Events/Types.lean` and
these pins catch a transposition.

Frozen indices: 0 — `balanceChanged`, 1 — `nonceAdvanced`,
2 — `identityRegistered`, 3 — `identityRevoked`,
4 — `timeRecorded`, 5 — `disputeFiled`, 6 — `disputeWithdrawn`,
7 — `verdictApplied`, 8 — `rewardIssued`,
9 — `withdrawalRequested`, 10 — `depositCredited`,
11 — `localPolicyDeclared`, 12 — `localPolicyRevoked`,
13 — `faultProofGameOpened`, 14 — `faultProofBisectionStep`,
15 — `faultProofGameSettled`. -/

-- 0
example (r : ResourceId) (a : ActorId) (oldV newV : Amount) :
    Event.tag (.balanceChanged r a oldV newV) = 0 := rfl
-- 1
example (a : ActorId) (oldN newN : Nonce) :
    Event.tag (.nonceAdvanced a oldN newN) = 1 := rfl
-- 2
example (a : ActorId) (k : PublicKey) :
    Event.tag (.identityRegistered a k) = 2 := rfl
-- 3
example (a : ActorId) :
    Event.tag (.identityRevoked a) = 3 := rfl
-- 4
example (t : Nat) :
    Event.tag (.timeRecorded t) = 4 := rfl
-- 5
example (c : ActorId) (idx : Nat) :
    Event.tag (.disputeFiled c idx) = 5 := rfl
-- 6
example (idx : Nat) :
    Event.tag (.disputeWithdrawn idx) = 6 := rfl
-- 7
example (idx tag : Nat) :
    Event.tag (.verdictApplied idx tag) = 7 := rfl
-- 8
example (r : ResourceId) (rec : ActorId) (am : Amount) :
    Event.tag (.rewardIssued r rec am) = 8 := rfl
-- 9
example (r : ResourceId) (sender : ActorId) (am : Amount)
    (eth : LegalKernel.Bridge.EthAddress) (wid : LegalKernel.Bridge.WithdrawalId) :
    Event.tag (.withdrawalRequested r sender am eth wid) = 9 := rfl
-- 10
example (r : ResourceId) (recv : ActorId) (am : Amount)
    (did : LegalKernel.Bridge.DepositId) :
    Event.tag (.depositCredited r recv am did) = 10 := rfl
-- 11
example (a : ActorId) (p : LocalPolicy) :
    Event.tag (.localPolicyDeclared a p) = 11 := rfl
-- 12
example (a : ActorId) :
    Event.tag (.localPolicyRevoked a) = 12 := rfl
-- 13
example (gid : Nat) (challenger : ActorId) (sIdx eIdx : Nat) (bh : ByteArray) :
    Event.tag (.faultProofGameOpened gid challenger sIdx eIdx bh) = 13 := rfl
-- 14
example (gid round : Nat) (party : ActorId) (idx : Nat) (commit : ByteArray) :
    Event.tag (.faultProofBisectionStep gid round party idx commit) = 14 := rfl
-- 15
example (gid : Nat) (winner loser : ActorId) (payout : Amount) :
    Event.tag (.faultProofGameSettled gid winner loser payout) = 15 := rfl

/-- All tests. -/
def tests : List TestCase :=
  [isBalanceChangeT, isBalanceChangeF, isRegistryChangeT, isRegistryChangeRevoked,
   actorProj, resourceProj, decEq,
   rewardIssuedActorProj, rewardIssuedResourceProj,
   rewardIssuedDetected, nonRewardNotDetected,
   rewardIssuedNotBalanceChange, rewardIssuedNotDisputeEvent,
   -- LP.10:
   localPolicyDeclaredActorProj, localPolicyDeclaredResourceProj,
   localPolicyRevokedActorProj,
   localPolicyDeclaredDetected, localPolicyRevokedDetected,
   nonLPNotLocalPolicyEvent, localPolicyDeclaredNotBalanceChange,
   lpEventDecEq]

end TypesTests
end LegalKernel.Test.Events
