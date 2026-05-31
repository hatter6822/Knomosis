-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.BridgeActor — Workstream B.3 test suite.

Exercises the bridge-actor reservation infrastructure
(`LegalKernel/Bridge/BridgeActor.lean`).  Coverage:

  * **Bridge actor identifier.**  `bridgeActor = (0 : ActorId)`.
  * **Authorisation: positive cases.**  The bridge policy
    authorises `replaceKey` and `registerIdentity` actions when
    the signer is the bridge actor.
  * **Authorisation: rejection cases.**  The bridge policy
    rejects every other Action constructor (transfer, mint, burn,
    freezeResource, reward, distributeOthers, proportionalDilute,
    dispute, disputeWithdraw, verdict, rollback) for the bridge
    actor.
  * **Cross-actor rejection.**  The bridge policy rejects every
    action by a non-bridge signer, including otherwise-permitted
    actions.
  * **Decidability sanity.**  The `decAuth` field is properly
    decidable and `decide` works at concrete inputs.
  * **Term-level API stability** for every §12.9 theorem.
-/

import LegalKernel.Bridge.BridgeActor
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge
namespace BridgeActorTests

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Test

/-- A sample public key for fixture construction. -/
def samplePk : PublicKey := ⟨#[0xAA, 0xBB]⟩

/-- Tests for `bridgeActor` and `bridgePolicy`. -/
def tests : List TestCase :=
  [ -- ## bridgeActor identifier
    { name := "bridgeActor = 0"
    , body := do
        assertEq (expected := (0 : ActorId)) (actual := bridgeActor) "bridgeActor"
    }
  , -- ## Authorisation: positive cases
    { name := "bridgePolicy authorises replaceKey by bridge actor"
    , body := do
        let h : bridgePolicy.authorized bridgeActor (.replaceKey 1 samplePk) :=
          bridgePolicy_authorizes_replaceKey 1 samplePk
        let _ := h  -- API stability check
        pure ()
    }
  , { name := "bridgePolicy authorises registerIdentity by bridge actor"
    , body := do
        let h : bridgePolicy.authorized bridgeActor (.registerIdentity 5 samplePk) :=
          bridgePolicy_authorizes_registerIdentity 5 samplePk
        let _ := h
        pure ()
    }
  , -- ## Authorisation: rejection cases
    { name := "bridgePolicy rejects transfer"
    , body := do
        let h := bridgePolicy_rejects_transfer 1 2 3 4
        if (decide (bridgePolicy.authorized bridgeActor (.transfer 1 2 3 4))) then
          throw <| IO.userError "bridgePolicy unexpectedly authorised transfer"
        let _ := h
        pure ()
    }
  , { name := "bridgePolicy rejects mint"
    , body := do
        let h := bridgePolicy_rejects_mint 1 2 3
        let _ := h
        if (decide (bridgePolicy.authorized bridgeActor (.mint 1 2 3))) then
          throw <| IO.userError "bridgePolicy unexpectedly authorised mint"
    }
  , { name := "bridgePolicy rejects burn"
    , body := do
        let h := bridgePolicy_rejects_burn 1 2 3
        let _ := h
        if (decide (bridgePolicy.authorized bridgeActor (.burn 1 2 3))) then
          throw <| IO.userError "bridgePolicy unexpectedly authorised burn"
    }
  , { name := "bridgePolicy rejects freezeResource"
    , body := do
        let h := bridgePolicy_rejects_freezeResource 1
        let _ := h
        if (decide (bridgePolicy.authorized bridgeActor (.freezeResource 1))) then
          throw <| IO.userError "bridgePolicy unexpectedly authorised freezeResource"
    }
  , { name := "bridgePolicy rejects reward"
    , body := do
        let h := bridgePolicy_rejects_reward 1 2 3
        let _ := h
        if (decide (bridgePolicy.authorized bridgeActor (.reward 1 2 3))) then
          throw <| IO.userError "bridgePolicy unexpectedly authorised reward"
    }
  , { name := "bridgePolicy rejects distributeOthers"
    , body := do
        let h := bridgePolicy_rejects_distributeOthers 1 2 3
        let _ := h
        if (decide (bridgePolicy.authorized bridgeActor (.distributeOthers 1 2 3))) then
          throw <| IO.userError "bridgePolicy unexpectedly authorised distributeOthers"
    }
  , { name := "bridgePolicy rejects proportionalDilute"
    , body := do
        let h := bridgePolicy_rejects_proportionalDilute 1 2 3
        let _ := h
        if (decide (bridgePolicy.authorized bridgeActor (.proportionalDilute 1 2 3))) then
          throw <| IO.userError "bridgePolicy unexpectedly authorised proportionalDilute"
    }
  , { name := "bridgePolicy rejects rollback"
    , body := do
        let h := bridgePolicy_rejects_rollback 5
        let _ := h
        if (decide (bridgePolicy.authorized bridgeActor (.rollback 5))) then
          throw <| IO.userError "bridgePolicy unexpectedly authorised rollback"
    }
  , -- ## Cross-actor rejection
    { name := "bridgePolicy rejects non-bridge signer (transfer)"
    , body := do
        let h := bridgePolicy_rejects_non_bridge_signer 1 (.transfer 0 0 0 0) (by decide)
        let _ := h
        if (decide (bridgePolicy.authorized 1 (.transfer 0 0 0 0))) then
          throw <| IO.userError
            "bridgePolicy unexpectedly authorised non-bridge signer"
    }
  , { name := "bridgePolicy rejects non-bridge signer (replaceKey)"
    , body := do
        -- Even replaceKey, which the bridge is allowed to do, is
        -- rejected when signed by a non-bridge actor.
        let h := bridgePolicy_rejects_non_bridge_signer 5
                   (.replaceKey 1 samplePk) (by decide)
        let _ := h
        if (decide (bridgePolicy.authorized 5 (.replaceKey 1 samplePk))) then
          throw <| IO.userError
            "bridgePolicy unexpectedly authorised non-bridge replaceKey"
    }
  , -- ## Decidability sanity
    { name := "bridgePolicy.authorized is decidable at concrete inputs"
    , body := do
        -- replaceKey by bridge: decide → true.
        if ¬ (decide (bridgePolicy.authorized 0 (.replaceKey 1 samplePk))) then
          throw <| IO.userError "decide failed on positive case"
        -- transfer by bridge: decide → false.
        if (decide (bridgePolicy.authorized 0 (.transfer 1 2 3 4))) then
          throw <| IO.userError "decide failed on negative case"
    }
  , -- ## Term-level API stability for §12.9 theorems
    { name := "bridgePolicy_rejects_transfer: term-level API"
    , body := do
        let _f : (r : ResourceId) → (sender receiver : ActorId) → (amount : Amount) →
                 ¬ bridgePolicy.authorized bridgeActor (.transfer r sender receiver amount) :=
          bridgePolicy_rejects_transfer
        pure ()
    }
  , { name := "bridgePolicy_authorizes_replaceKey: term-level API"
    , body := do
        let _f : (actor : ActorId) → (newKey : PublicKey) →
                 bridgePolicy.authorized bridgeActor (.replaceKey actor newKey) :=
          bridgePolicy_authorizes_replaceKey
        pure ()
    }
  , { name := "bridgePolicy_authorizes_registerIdentity: term-level API"
    , body := do
        let _f : (actor : ActorId) → (pk : PublicKey) →
                 bridgePolicy.authorized bridgeActor (.registerIdentity actor pk) :=
          bridgePolicy_authorizes_registerIdentity
        pure ()
    }
  , -- ## Workstream C.4 (audit-1): deposit admitted, withdraw rejected
    { name := "bridgePolicy authorises deposit by bridge actor"
    , body := do
        if ¬ (decide (bridgePolicy.authorized 0 (.deposit 1 10 100 42))) then
          throw <| IO.userError "expected bridge to authorise deposit"
    }
  , { name := "bridgePolicy rejects withdraw by bridge actor (§12.9 #33)"
    , body := do
        -- Workstream-C audit-1: withdrawals are user-initiated; the
        -- bridge actor must NOT be authorised to withdraw on a user's
        -- behalf.  This closes a coordinated-attack vector where a
        -- compromised bridge actor could drain L2 balances and then
        -- forge an L1 redemption proof.
        if (decide (bridgePolicy.authorized 0
                     (.withdraw 1 10 50 LegalKernel.Bridge.EthAddress.zero))) then
          throw <| IO.userError "bridge unexpectedly authorised withdraw"
    }
  , { name := "bridgePolicy_authorizes_deposit: term-level API"
    , body := do
        let _f : (r : ResourceId) → (recipient : ActorId) → (amount : Amount) →
                 (depositId : LegalKernel.Bridge.DepositId) →
                 bridgePolicy.authorized bridgeActor
                   (.deposit r recipient amount depositId) :=
          bridgePolicy_authorizes_deposit
        pure ()
    }
  , { name := "bridgePolicy_rejects_withdraw: term-level API"
    , body := do
        let _f : (r : ResourceId) → (sender : ActorId) → (amount : Amount) →
                 (recipientL1 : LegalKernel.Bridge.EthAddress) →
                 ¬ bridgePolicy.authorized bridgeActor
                   (.withdraw r sender amount recipientL1) :=
          bridgePolicy_rejects_withdraw
        pure ()
    }
  , { name := "bridgePolicy rejects deposit by non-bridge signer"
    , body := do
        if (decide (bridgePolicy.authorized 5 (.deposit 1 10 100 42))) then
          throw <| IO.userError "non-bridge signer should be rejected"
    }
  , { name := "bridgePolicy rejects withdraw by non-bridge signer too"
    , body := do
        -- Withdrawals are not under bridgePolicy at all; this just
        -- confirms the policy uniformly rejects withdraw regardless
        -- of signer.  User-signed withdrawals go through a different
        -- (per-actor) policy.
        if (decide (bridgePolicy.authorized 5
                     (.withdraw 1 10 50 LegalKernel.Bridge.EthAddress.zero))) then
          throw <| IO.userError "non-bridge signer should be rejected"
    }
  , { name := "bridgeAuthorizedAction returns false for withdraw"
    , body := do
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction
                       (.withdraw 1 10 50 LegalKernel.Bridge.EthAddress.zero))
          "withdraw not in bridge's set"
    }
  , { name := "bridgeAuthorizedAction returns true for deposit"
    , body := do
        assertEq (expected := true)
          (actual := bridgeAuthorizedAction (.deposit 1 10 100 42))
          "deposit in bridge's set"
    }
  , { name := "bridgePolicy_rejects_non_bridge_signer: term-level API"
    , body := do
        let _f : (signer : ActorId) → (action : Action) → signer ≠ bridgeActor →
                 ¬ bridgePolicy.authorized signer action :=
          bridgePolicy_rejects_non_bridge_signer
        pure ()
    }
  , -- ## bridgeAuthorizedAction direct value-level checks (defence-in-depth)
    { name := "bridgeAuthorizedAction returns true for replaceKey/registerIdentity"
    , body := do
        assertEq (expected := true)
          (actual := bridgeAuthorizedAction (.replaceKey 1 samplePk))
          "replaceKey is authorized"
        assertEq (expected := true)
          (actual := bridgeAuthorizedAction (.registerIdentity 1 samplePk))
          "registerIdentity is authorized"
    }
  , { name := "bridgeAuthorizedAction returns false for every other constructor"
    , body := do
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.transfer 1 2 3 4)) "transfer"
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.mint 1 2 3)) "mint"
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.burn 1 2 3)) "burn"
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.freezeResource 1)) "freezeResource"
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.reward 1 2 3)) "reward"
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.distributeOthers 1 2 3))
          "distributeOthers"
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.proportionalDilute 1 2 3))
          "proportionalDilute"
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.disputeWithdraw 5)) "disputeWithdraw"
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.rollback 5)) "rollback"
    }
  , -- ## Defense in depth: catch any future drift between bridgePolicy
    -- and bridgeAuthorizedAction.
    { name := "bridgePolicy.authorized iff (signer = 0 ∧ bridgeAuthorizedAction)"
    , body := do
        -- For (signer = 0, replaceKey): both true.
        let h1 : bridgePolicy.authorized 0 (.replaceKey 1 samplePk) :=
          bridgePolicy_authorizes_replaceKey 1 samplePk
        let _ := h1
        if not (decide (bridgeAuthorizedAction (.replaceKey 1 samplePk))) then
          throw <| IO.userError "drift: policy authorises but action not in set"
        -- For (signer = 0, transfer): both false.
        let _h2 := bridgePolicy_rejects_transfer 1 2 3 4
        if (decide (bridgeAuthorizedAction (.transfer 1 2 3 4))) then
          throw <| IO.userError "drift: action in set but policy rejects"
        pure ()
    }
  , -- ## Workstream LP / LP.8 — bridge actor cannot declare/revoke local policies.
    { name := "bridgePolicy rejects declareLocalPolicy"
    , body := do
        let p : Authority.LocalPolicy := { clauses := [.denyTags [0]] }
        let _proof := bridgePolicy_rejects_declareLocalPolicy p
        if decide (bridgePolicy.authorized bridgeActor (.declareLocalPolicy p)) then
          throw <| IO.userError "BUG: bridge actor permitted to declareLocalPolicy"
        else pure ()
    }
  , { name := "bridgePolicy rejects revokeLocalPolicy"
    , body := do
        let _proof := bridgePolicy_rejects_revokeLocalPolicy
        if decide (bridgePolicy.authorized bridgeActor .revokeLocalPolicy) then
          throw <| IO.userError "BUG: bridge actor permitted to revokeLocalPolicy"
        else pure ()
    }
  , { name := "bridgePolicy_rejects_declareLocalPolicy term-level API"
    , body := do
        let _proof : ∀ (p : Authority.LocalPolicy),
                       ¬ bridgePolicy.authorized bridgeActor (.declareLocalPolicy p) :=
          bridgePolicy_rejects_declareLocalPolicy
        pure ()
    }
  , { name := "bridgePolicy_rejects_revokeLocalPolicy term-level API"
    , body := do
        let _proof : ¬ bridgePolicy.authorized bridgeActor .revokeLocalPolicy :=
          bridgePolicy_rejects_revokeLocalPolicy
        pure ()
    }
  , { name := "bridgeAuthorizedAction rejects declareLocalPolicy/revokeLocalPolicy"
    , body := do
        let p : Authority.LocalPolicy := { clauses := [] }
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.declareLocalPolicy p))
          "declareLocalPolicy"
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction .revokeLocalPolicy)
          "revokeLocalPolicy"
    }
    -- ## Workstream GP fix: depositWithFee is bridge-authorised
    -- (it is `isBridgeOnly`, so it MUST be signable by the bridge
    -- actor), while the user gas actions are not.
  , { name := "bridgeAuthorizedAction returns true for depositWithFee (GP fix)"
    , body := do
        assertEq (expected := true)
          (actual := bridgeAuthorizedAction (.depositWithFee 1 10 1 90 10 5 42))
          "depositWithFee is bridge-authorised"
    }
  , { name := "bridgeAuthorizedAction returns false for the user gas actions"
    , body := do
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.topUpActionBudget 1 10 5 1))
          "topUpActionBudget (user self-topup)"
        assertEq (expected := false)
          (actual := bridgeAuthorizedAction (.topUpActionBudgetFor 20 1 10 5 1))
          "topUpActionBudgetFor (delegated, user-initiated)"
    }
  , { name := "bridgePolicy authorises bridge-signed depositWithFee (end-to-end fix)"
    , body := do
        -- Before the fix, this proof did not exist — a bridge-signed
        -- depositWithFee was unadmittable under bridgePolicy despite
        -- being `isBridgeOnly`.
        let _h : bridgePolicy.authorized bridgeActor
                  (.depositWithFee 1 10 1 90 10 5 42) :=
          bridgePolicy_authorizes_depositWithFee 1 10 1 90 10 5 42
        pure ()
    }
  , { name := "bridgePolicy rejects bridge-signed topUpActionBudget / topUpActionBudgetFor"
    , body := do
        let _h1 : ¬ bridgePolicy.authorized bridgeActor
                    (.topUpActionBudget 1 10 5 1) :=
          bridgePolicy_rejects_topUpActionBudget 1 10 5 1
        let _h2 : ¬ bridgePolicy.authorized bridgeActor
                    (.topUpActionBudgetFor 20 1 10 5 1) :=
          bridgePolicy_rejects_topUpActionBudgetFor 20 1 10 5 1
        pure ()
    }
  ]

end BridgeActorTests
end LegalKernel.Test.Bridge
