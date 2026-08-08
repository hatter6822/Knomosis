-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.AmmCommit — GP.11.8 + GP.11.10 acceptance
tests for the L1-mirror state-root commitment integration.

Under the one-AMM L2-primary topology the surviving mirrors are the
three BOLD deposit guards (`boldCircuitClosed`, `boldTvlCap`,
`boldTotalLockedValue`) and the GP.11.10 `ammDisabled` kill switch.
(The two excised L1-AMM book mirrors' cases are gone with the
fields.)  Coverage:

  * Genesis state-root with all mirror fields at their defaults.
  * Post-deposit / post-guard-change commitment changes.
  * Each mirror field independently alters the commitment (including
    the GP.11.10 `ammDisabled` kill-switch mirror).
  * Term-level API stability for the GP.11.8 + GP.11.10 theorems
    (`bridgeState_commit_includes_mirrorState`,
    `bridgeState_commit_extends_v1_2`, `bridgeState_encode_factored`,
    `bridgeState_mirror_genesis_suffix_const`,
    `commitBridgeState_reflects_ammDisabled`,
    `commitExtendedStateConcat_reflects_ammDisabled`).
  * Encoding round-trip with mirror fields (including `ammDisabled`).
  * Determinism: same mirror state → same commitment.
  * Decoder rejects non-canonical boldCircuitClosed / ammDisabled.
  * Encoding factoring: base prefix ++ mirror suffix decomposition.
  * Mirror genesis suffix constancy across states.
  * H-1: the top-level root binds all seven sub-states.
-/

import LegalKernel.FaultProof.Commit
import LegalKernel.Encoding.State
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Bridge
open LegalKernel.Encoding
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.AmmCommit

/-- GP.11.8 + GP.11.10 acceptance tests. -/
def tests : List TestCase :=
  [
  -- 1. Genesis state-root: all mirror fields at defaults → 32-byte commit.
  { name := "GP.11.8: genesis mirror state → 32-byte bridge commitment"
  , body := do
      let bs := BridgeState.empty
      let c := commitBridgeState bs
      assertEq (expected := 32) (actual := c.size) "32-byte bridge commit"
      assertEq (expected := false) (actual := bs.boldCircuitClosed) "genesis boldCircuitClosed"
      assertEq (expected := (0 : Nat)) (actual := bs.boldTvlCap) "genesis boldTvlCap"
      assertEq (expected := (0 : Nat)) (actual := bs.boldTotalLockedValue) "genesis boldTotalLockedValue"
      assertEq (expected := false) (actual := bs.ammDisabled) "genesis ammDisabled"
  }
  -- 2. Changing boldCircuitClosed changes the commitment.
  , { name := "GP.11.8: boldCircuitClosed change alters bridge commitment"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with boldCircuitClosed := true }
        let c0 := commitBridgeState bs0
        let c1 := commitBridgeState bs1
        assert (c0 ≠ c1) "boldCircuitClosed change must alter commit"
    }
  -- 3. Changing boldTvlCap changes the commitment.
  , { name := "GP.11.8: boldTvlCap change alters bridge commitment"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with boldTvlCap := 100000000 }
        let c0 := commitBridgeState bs0
        let c1 := commitBridgeState bs1
        assert (c0 ≠ c1) "boldTvlCap change must alter commit"
    }
  -- 4. Changing boldTotalLockedValue changes the commitment.
  , { name := "GP.11.8: boldTotalLockedValue change alters bridge commitment"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with boldTotalLockedValue := 42000 }
        let c0 := commitBridgeState bs0
        let c1 := commitBridgeState bs1
        assert (c0 ≠ c1) "boldTotalLockedValue change must alter commit"
    }
  -- 5. Post-deposit: state-root reflects deposit via top-level commit.
  , { name := "GP.11.8: post-deposit state-root changes"
    , body := do
        let es0 := ExtendedState.empty
        let dep : DepositRecord := { resource := 0, userAmount := 900, poolAmount := 100, budgetGrant := 10 }
        let bs1 := es0.bridge.markConsumed 42 dep
        let es1 : ExtendedState := { es0 with bridge := bs1 }
        let c0 := commitExtendedState es0
        let c1 := commitExtendedState es1
        assert (c0 ≠ c1) "post-deposit commit differs from genesis"
    }
  -- 6. Post-circuit-close: flipping boldCircuitClosed changes state-root.
  , { name := "GP.11.8: post-circuit-close changes state-root"
    , body := do
        let es0 := ExtendedState.empty
        let bs1 : BridgeState := { es0.bridge with boldCircuitClosed := true }
        let es1 : ExtendedState := { es0 with bridge := bs1 }
        let c0 := commitExtendedState es0
        let c1 := commitExtendedState es1
        assert (c0 ≠ c1) "post-circuit-close commit differs from genesis"
    }
  -- 7. BridgeState encoding includes the guard fields (byte check).
  , { name := "GP.11.8: BridgeState encoding grows with non-zero guard fields"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with boldTvlCap := 999 }
        let e0 := Bridge.BridgeState.encode bs0
        let e1 := Bridge.BridgeState.encode bs1
        assert (e0 != e1) "non-zero boldTvlCap changes encoding bytes"
    }
  -- 8. Term-level API: bridgeState_commit_includes_mirrorState.
  , { name := "GP.11.8: bridgeState_commit_includes_mirrorState API stable"
    , body := do
        let _proof : ∀ (bs : Bridge.BridgeState),
            Bridge.BridgeState.encode bs =
              Bridge.BridgeState.encodeConsumed bs ++
              Bridge.BridgeState.encodePending bs ++
              Encodable.encode (T := Nat) bs.nextWdId ++
              Encodable.encode (T := Nat) (if bs.boldCircuitClosed then 1 else 0) ++
              encodeAmount bs.boldTvlCap ++
              encodeAmount bs.boldTotalLockedValue ++
              Encodable.encode (T := Nat) (if bs.ammDisabled then 1 else 0) :=
          bridgeState_commit_includes_mirrorState
        pure ()
    }
  -- 9. Term-level API: bridgeState_commit_extends_v1_2.
  , { name := "GP.11.8: bridgeState_commit_extends_v1_2 API stable"
    , body := do
        let _proof : ∀ (bs₁ bs₂ : Bridge.BridgeState),
            bs₁.consumed = bs₂.consumed →
            bs₁.pending = bs₂.pending →
            bs₁.nextWdId = bs₂.nextWdId →
            (bs₁.boldCircuitClosed = false ∧ bs₁.boldTvlCap = 0 ∧
             bs₁.boldTotalLockedValue = 0 ∧ bs₁.ammDisabled = false) →
            (bs₂.boldCircuitClosed = false ∧ bs₂.boldTvlCap = 0 ∧
             bs₂.boldTotalLockedValue = 0 ∧ bs₂.ammDisabled = false) →
            commitBridgeState bs₁ = commitBridgeState bs₂ :=
          bridgeState_commit_extends_v1_2
        pure ()
    }
  -- 10. Determinism: same mirror state → same commitment.
  , { name := "GP.11.8: identical mirror states produce identical commitments"
    , body := do
        let bs : BridgeState := { BridgeState.empty with
          boldCircuitClosed := true, boldTvlCap := 50000,
          boldTotalLockedValue := 30000 }
        let c1 := commitBridgeState bs
        let c2 := commitBridgeState bs
        assertEq (expected := c1) (actual := c2) "determinism on mirror state"
    }
  -- 11. A v1.2-shaped state with genesis mirror defaults → 32-byte commit.
  , { name := "GP.11.8: v1.2 state with genesis mirror defaults → 32-byte commit"
    , body := do
        let dep : DepositRecord := { resource := 0, userAmount := 1000, poolAmount := 0, budgetGrant := 0 }
        let bs : BridgeState := { BridgeState.empty with
          consumed := (∅ : Std.TreeMap DepositId DepositRecord compare).insert 1 dep }
        assertEq (expected := false) (actual := bs.boldCircuitClosed) "default boldCircuitClosed"
        let c := commitBridgeState bs
        assertEq (expected := 32) (actual := c.size) "32-byte commit"
    }
  -- 12. Encoding round-trip with mirror fields.
  , { name := "GP.11.8: BridgeState encoding with mirror fields round-trips"
    , body := do
        let bs : BridgeState := { BridgeState.empty with
          boldCircuitClosed := true, boldTvlCap := 99999,
          boldTotalLockedValue := 55555, ammDisabled := true }
        let encoded := Bridge.BridgeState.encode bs
        match Bridge.BridgeState.decode encoded with
        | .ok (bs', rest) =>
          assert (rest == []) "no trailing bytes after decode"
          assertEq (expected := bs.boldCircuitClosed) (actual := bs'.boldCircuitClosed) "boldCircuitClosed roundtrip"
          assertEq (expected := bs.boldTvlCap) (actual := bs'.boldTvlCap) "boldTvlCap roundtrip"
          assertEq (expected := bs.boldTotalLockedValue) (actual := bs'.boldTotalLockedValue) "boldTotalLockedValue roundtrip"
          assertEq (expected := bs.ammDisabled) (actual := bs'.ammDisabled) "ammDisabled roundtrip"
        | .error e => throw <| IO.userError s!"decode failed: {repr e}"
    }
  -- 13. Non-canonical boldCircuitClosed encoding is rejected.
  , { name := "GP.11.8: decoder rejects non-canonical boldCircuitClosed"
    , body := do
        let bs := BridgeState.empty
        let tampered : Encoding.Stream :=
          Bridge.BridgeState.encodeConsumed bs ++
          Bridge.BridgeState.encodePending bs ++
          Encodable.encode (T := Nat) bs.nextWdId ++
          Encodable.encode (T := Nat) 2 ++
          encodeAmount bs.boldTvlCap ++
          encodeAmount bs.boldTotalLockedValue ++
          Encodable.encode (T := Nat) (if bs.ammDisabled then 1 else 0)
        match Bridge.BridgeState.decode tampered with
        | .error _ => pure ()
        | .ok _ => throw <| IO.userError "decoder accepted non-canonical circuitClosed=2"
    }
  -- 14. Term-level API: bridgeState_encode_factored.
  , { name := "GP.11.8: bridgeState_encode_factored API stable"
    , body := do
        let _proof : ∀ (bs : Bridge.BridgeState),
            Bridge.BridgeState.encode bs =
            bridgeStateEncodeBase bs ++ bridgeStateEncodeMirrorSuffix bs :=
          bridgeState_encode_factored
        pure ()
    }
  -- 15. Term-level API: bridgeState_mirror_genesis_suffix_const.
  , { name := "GP.11.8: bridgeState_mirror_genesis_suffix_const API stable"
    , body := do
        let _proof : ∀ (bs₁ bs₂ : Bridge.BridgeState),
            (bs₁.boldCircuitClosed = false ∧ bs₁.boldTvlCap = 0 ∧
             bs₁.boldTotalLockedValue = 0 ∧ bs₁.ammDisabled = false) →
            (bs₂.boldCircuitClosed = false ∧ bs₂.boldTvlCap = 0 ∧
             bs₂.boldTotalLockedValue = 0 ∧ bs₂.ammDisabled = false) →
            bridgeStateEncodeMirrorSuffix bs₁ = bridgeStateEncodeMirrorSuffix bs₂ :=
          bridgeState_mirror_genesis_suffix_const
        pure ()
    }
  -- 16. Value-level: factored encoding produces the same bytes as direct.
  , { name := "GP.11.8: factored encoding produces same bytes as direct"
    , body := do
        let bs : BridgeState := { BridgeState.empty with
          boldCircuitClosed := true, boldTvlCap := 1000,
          boldTotalLockedValue := 500, ammDisabled := true }
        let direct := Bridge.BridgeState.encode bs
        let factored := bridgeStateEncodeBase bs ++ bridgeStateEncodeMirrorSuffix bs
        assertEq (expected := direct) (actual := factored) "factored encoding matches direct"
    }
  -- 17. GP.11.10: flipping ammDisabled changes the bridge commitment.
  , { name := "GP.11.10: ammDisabled change alters bridge commitment"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with ammDisabled := true }
        let c0 := commitBridgeState bs0
        let c1 := commitBridgeState bs1
        assert (c0 ≠ c1) "ammDisabled change must alter commit"
    }
  -- 18. GP.11.10: ammDisabled propagates to the top-level state root.
  , { name := "GP.11.10: ammDisabled change alters top-level state-root"
    , body := do
        let es0 := ExtendedState.empty
        let bs1 : BridgeState := { es0.bridge with ammDisabled := true }
        let es1 : ExtendedState := { es0 with bridge := bs1 }
        let c0 := commitExtendedState es0
        let c1 := commitExtendedState es1
        assert (c0 ≠ c1) "post-kill-switch state root differs from genesis"
    }
  -- 19. GP.11.10: ammDisabled flips independently of the guard fields.
  , { name := "GP.11.10: populated mirror state still distinguishes ammDisabled"
    , body := do
        let bs0 : BridgeState := { BridgeState.empty with
          boldCircuitClosed := true, boldTvlCap := 777,
          boldTotalLockedValue := 888 }
        let bs1 : BridgeState := { bs0 with ammDisabled := true }
        assert (commitBridgeState bs0 ≠ commitBridgeState bs1)
          "disable flips the commit even with the guard fields populated"
    }
  -- 20. GP.11.10: decoder rejects non-canonical ammDisabled encoding.
  , { name := "GP.11.10: decoder rejects non-canonical ammDisabled"
    , body := do
        let bs := BridgeState.empty
        let tampered : Encoding.Stream :=
          Bridge.BridgeState.encodeConsumed bs ++
          Bridge.BridgeState.encodePending bs ++
          Encodable.encode (T := Nat) bs.nextWdId ++
          Encodable.encode (T := Nat) (if bs.boldCircuitClosed then 1 else 0) ++
          encodeAmount bs.boldTvlCap ++
          encodeAmount bs.boldTotalLockedValue ++
          Encodable.encode (T := Nat) 2
        match Bridge.BridgeState.decode tampered with
        | .error _ => pure ()
        | .ok _ => throw <| IO.userError "decoder accepted non-canonical ammDisabled=2"
    }
  -- 21. GP.11.10: ammDisabled=true round-trips and commits deterministically.
  , { name := "GP.11.10: disabled-AMM state round-trips and commits deterministically"
    , body := do
        let bs : BridgeState := { BridgeState.empty with ammDisabled := true }
        match Bridge.BridgeState.decode (Bridge.BridgeState.encode bs) with
        | .ok (bs', rest) =>
          assert (rest == []) "no trailing bytes after decode"
          assertEq (expected := true) (actual := bs'.ammDisabled) "ammDisabled=true roundtrip"
        | .error e => throw <| IO.userError s!"decode failed: {repr e}"
        assertEq (expected := commitBridgeState bs) (actual := commitBridgeState bs)
          "determinism on the disabled state"
    }
  -- H-1. The published state root binds ALL SEVEN `ExtendedState`
  --     sub-states.  Before H-1 it bound five: `epochBudgets` and
  --     `budgetPolicy` were omitted, so two executions agreeing on
  --     every committed sub-state but disagreeing on budget grants or
  --     consumption produced the SAME root and a fault proof had
  --     nothing to challenge.  These are value-level pins: mutate one
  --     of the two formerly-unbound fields and the root must move.
  , { name := "H-1: state root reflects epochBudgets"
    , body := do
        let base : Authority.ExtendedState := { base := genesisState
                                              , nonces := Authority.NonceState.empty
                                              , registry := Authority.KeyRegistry.empty }
        -- Same state, except one actor holds a budget cell.
        let withBudget : Authority.ExtendedState :=
          { base with
            epochBudgets := Authority.EpochBudgetState.empty.topUp 7 0 0 500 }
        Test.assert
          (commitExtendedState base != commitExtendedState withBudget)
          "a differing epochBudgets ledger must change the state root"
    }
  , { name := "H-1: state root reflects budgetPolicy"
    , body := do
        let base : Authority.ExtendedState := { base := genesisState
                                              , nonces := Authority.NonceState.empty
                                              , registry := Authority.KeyRegistry.empty }
        let otherPolicy : Authority.ExtendedState :=
          { base with budgetPolicy := .bounded 10 1 100 }
        Test.assert
          (commitExtendedState base != commitExtendedState otherPolicy)
          "a differing budgetPolicy must change the state root"
    }
  , { name := "H-1: commitExtendedState binds seven sub-states"
    , body := do
        -- The decomposition theorem now yields SEVEN sub-commit
        -- equalities; this pins its arity so a future field added to
        -- `ExtendedState` without extending the commitment is caught.
        let _proof : ∀ (es₁ es₂ : Authority.ExtendedState),
            Bridge.CollisionFreeOn
              [extendedStatePreimage es₁, extendedStatePreimage es₂]
              LegalKernel.Runtime.hashBytes →
            commitExtendedStateConcat es₁ = commitExtendedStateConcat es₂ →
            commitState es₁.base = commitState es₂.base ∧
            commitNonceState es₁.nonces = commitNonceState es₂.nonces ∧
            commitKeyRegistry es₁.registry = commitKeyRegistry es₂.registry ∧
            commitLocalPolicies es₁.localPolicies = commitLocalPolicies es₂.localPolicies ∧
            commitBridgeState es₁.bridge = commitBridgeState es₂.bridge ∧
            commitEpochBudgets es₁.epochBudgets = commitEpochBudgets es₂.epochBudgets ∧
            commitBudgetPolicy es₁.budgetPolicy = commitBudgetPolicy es₂.budgetPolicy :=
          commitExtendedStateConcat_subcommits_eq_under_collision_free
        pure ()
    }
  -- 22. Term-level API: commitBridgeState_reflects_ammDisabled.
  , { name := "GP.11.10: commitBridgeState_reflects_ammDisabled API stable"
    , body := do
        let _proof : ∀ (bs₁ bs₂ : Bridge.BridgeState),
            Bridge.CollisionFreeOn
              [ ByteArray.mk (Encoding.Encodable.encode
                  (T := Bridge.BridgeState) bs₁).toArray
              , ByteArray.mk (Encoding.Encodable.encode
                  (T := Bridge.BridgeState) bs₂).toArray ]
              LegalKernel.Runtime.hashBytes →
            bs₁.consumed.toList = bs₂.consumed.toList →
            bs₁.pending.toList = bs₂.pending.toList →
            bs₁.nextWdId = bs₂.nextWdId →
            bs₁.boldCircuitClosed = bs₂.boldCircuitClosed →
            bs₁.boldTvlCap = bs₂.boldTvlCap →
            bs₁.boldTotalLockedValue = bs₂.boldTotalLockedValue →
            bs₁.ammDisabled ≠ bs₂.ammDisabled →
            commitBridgeState bs₁ ≠ commitBridgeState bs₂ :=
          commitBridgeState_reflects_ammDisabled
        pure ()
    }
  -- 23. Term-level API: commitExtendedStateConcat_reflects_ammDisabled —
  --     the GP.11.10 TOP-LEVEL headline (the kill switch is reflected
  --     in the published state root itself, with no hypotheses on the
  --     non-bridge sub-states).
  , { name := "GP.11.10: commitExtendedStateConcat_reflects_ammDisabled API stable"
    , body := do
        let _proof : ∀ (es₁ es₂ : Authority.ExtendedState),
            Bridge.CollisionFreeOn
              (extendedStateCommitPreimages es₁ es₂)
              LegalKernel.Runtime.hashBytes →
            es₁.bridge.consumed.toList = es₂.bridge.consumed.toList →
            es₁.bridge.pending.toList = es₂.bridge.pending.toList →
            es₁.bridge.nextWdId = es₂.bridge.nextWdId →
            es₁.bridge.boldCircuitClosed = es₂.bridge.boldCircuitClosed →
            es₁.bridge.boldTvlCap = es₂.bridge.boldTvlCap →
            es₁.bridge.boldTotalLockedValue = es₂.bridge.boldTotalLockedValue →
            es₁.bridge.ammDisabled ≠ es₂.bridge.ammDisabled →
            commitExtendedStateConcat es₁ ≠ commitExtendedStateConcat es₂ :=
          commitExtendedStateConcat_reflects_ammDisabled
        pure ()
    }
  -- 24. Value-level: flipping ONLY ammDisabled on a populated extended
  --     state (non-trivial kernel sub-state) flips the top-level root —
  --     the value-level twin of test 23.
  , { name := "GP.11.10: top-level root reflects ammDisabled on populated states"
    , body := do
        let es0 := ExtendedState.empty
        let es1 : ExtendedState :=
          { es0 with
            base := LegalKernel.setBalance es0.base 0 7 1000
            bridge := { es0.bridge with boldTvlCap := 5555 } }
        let es2 : ExtendedState :=
          { es1 with bridge := { es1.bridge with ammDisabled := true } }
        assert (commitExtendedState es1 ≠ commitExtendedState es2)
          "kill-switch flip alters the top-level root on a populated state"
    }
  ]

end LegalKernel.Test.FaultProof.AmmCommit
