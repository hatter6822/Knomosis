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
tests for AMM state-root commitment integration.

19 GP.11.8 cases plus 7 GP.11.10 cases:
  * Genesis state-root with all AMM fields at zero.
  * Post-deposit / post-swap / post-circuit-close commitment changes.
  * Each AMM field independently alters the commitment (including
    the GP.11.10 `ammDisabled` kill-switch mirror).
  * Term-level API stability for the GP.11.8 + GP.11.10 theorems
    (`bridgeState_commit_includes_ammState`,
    `bridgeState_commit_extends_v1_2`, `bridgeState_encode_factored`,
    `bridgeState_amm_genesis_suffix_const`,
    `bridgeState_commit_extends_v1_3`,
    `commitBridgeState_reflects_ammDisabled`).
  * Encoding round-trip with AMM fields (including `ammDisabled`).
  * Migration: v1.2 state with genesis AMM defaults → well-formed commitment.
  * Determinism: same AMM state → same commitment.
  * Decoder rejects non-canonical boldCircuitClosed / ammDisabled encodings.
  * Encoding factoring: base prefix ++ AMM suffix decomposition.
  * AMM genesis suffix constancy across states.
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
  -- 1. Genesis state-root: all AMM fields at zero → 32-byte well-formed commitment.
  { name := "GP.11.8: genesis AMM state → 32-byte bridge commitment"
  , body := do
      let bs := BridgeState.empty
      let c := commitBridgeState bs
      assertEq (expected := 32) (actual := c.size) "32-byte bridge commit"
      assertEq (expected := (0 : Nat)) (actual := bs.ammReserveEth) "genesis ammReserveEth"
      assertEq (expected := (0 : Nat)) (actual := bs.ammReserveBold) "genesis ammReserveBold"
      assertEq (expected := false) (actual := bs.boldCircuitClosed) "genesis boldCircuitClosed"
      assertEq (expected := (0 : Nat)) (actual := bs.boldTvlCap) "genesis boldTvlCap"
      assertEq (expected := (0 : Nat)) (actual := bs.boldTotalLockedValue) "genesis boldTotalLockedValue"
      assertEq (expected := false) (actual := bs.ammDisabled) "genesis ammDisabled"
  }
  -- 2. Changing ammReserveEth changes the commitment.
  , { name := "GP.11.8: ammReserveEth change alters bridge commitment"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with ammReserveEth := 1000000 }
        let c0 := commitBridgeState bs0
        let c1 := commitBridgeState bs1
        assert (c0 ≠ c1) "ammReserveEth change must alter commit"
    }
  -- 3. Changing ammReserveBold changes the commitment.
  , { name := "GP.11.8: ammReserveBold change alters bridge commitment"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with ammReserveBold := 5000000 }
        let c0 := commitBridgeState bs0
        let c1 := commitBridgeState bs1
        assert (c0 ≠ c1) "ammReserveBold change must alter commit"
    }
  -- 4. Changing boldCircuitClosed changes the commitment.
  , { name := "GP.11.8: boldCircuitClosed change alters bridge commitment"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with boldCircuitClosed := true }
        let c0 := commitBridgeState bs0
        let c1 := commitBridgeState bs1
        assert (c0 ≠ c1) "boldCircuitClosed change must alter commit"
    }
  -- 5. Changing boldTvlCap changes the commitment.
  , { name := "GP.11.8: boldTvlCap change alters bridge commitment"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with boldTvlCap := 100000000 }
        let c0 := commitBridgeState bs0
        let c1 := commitBridgeState bs1
        assert (c0 ≠ c1) "boldTvlCap change must alter commit"
    }
  -- 6. Changing boldTotalLockedValue changes the commitment.
  , { name := "GP.11.8: boldTotalLockedValue change alters bridge commitment"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with boldTotalLockedValue := 42000 }
        let c0 := commitBridgeState bs0
        let c1 := commitBridgeState bs1
        assert (c0 ≠ c1) "boldTotalLockedValue change must alter commit"
    }
  -- 7. Post-deposit: state-root reflects deposit via top-level commit.
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
  -- 8. Post-swap: updating AMM reserves changes the state-root.
  , { name := "GP.11.8: post-swap AMM reserve update changes state-root"
    , body := do
        let es0 := ExtendedState.empty
        let bs1 : BridgeState := { es0.bridge with
          ammReserveEth := 500000
          ammReserveBold := 1500000 }
        let es1 : ExtendedState := { es0 with bridge := bs1 }
        let c0 := commitExtendedState es0
        let c1 := commitExtendedState es1
        assert (c0 ≠ c1) "post-swap commit differs from genesis"
    }
  -- 9. Post-circuit-close: flipping boldCircuitClosed changes state-root.
  , { name := "GP.11.8: post-circuit-close changes state-root"
    , body := do
        let es0 := ExtendedState.empty
        let bs1 : BridgeState := { es0.bridge with boldCircuitClosed := true }
        let es1 : ExtendedState := { es0 with bridge := bs1 }
        let c0 := commitExtendedState es0
        let c1 := commitExtendedState es1
        assert (c0 ≠ c1) "post-circuit-close commit differs from genesis"
    }
  -- 10. BridgeState encoding includes AMM fields (encoding size check).
  , { name := "GP.11.8: BridgeState encoding grows with non-zero AMM fields"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with ammReserveEth := 999 }
        let e0 := Bridge.BridgeState.encode bs0
        let e1 := Bridge.BridgeState.encode bs1
        assert (e0 != e1) "non-zero ammReserveEth changes encoding bytes"
    }
  -- 11. Term-level API: bridgeState_commit_includes_ammState.
  , { name := "GP.11.8: bridgeState_commit_includes_ammState API stable"
    , body := do
        let _proof : ∀ (bs : Bridge.BridgeState),
            Bridge.BridgeState.encode bs =
              Bridge.BridgeState.encodeConsumed bs ++
              Bridge.BridgeState.encodePending bs ++
              Encodable.encode (T := Nat) bs.nextWdId ++
              Encodable.encode (T := Nat) bs.ammReserveEth ++
              Encodable.encode (T := Nat) bs.ammReserveBold ++
              Encodable.encode (T := Nat) (if bs.boldCircuitClosed then 1 else 0) ++
              Encodable.encode (T := Nat) bs.boldTvlCap ++
              Encodable.encode (T := Nat) bs.boldTotalLockedValue ++
              Encodable.encode (T := Nat) (if bs.ammDisabled then 1 else 0) :=
          bridgeState_commit_includes_ammState
        pure ()
    }
  -- 12. Term-level API: bridgeState_commit_extends_v1_2.
  , { name := "GP.11.8: bridgeState_commit_extends_v1_2 API stable"
    , body := do
        let _proof : ∀ (bs₁ bs₂ : Bridge.BridgeState),
            bs₁.consumed = bs₂.consumed →
            bs₁.pending = bs₂.pending →
            bs₁.nextWdId = bs₂.nextWdId →
            (bs₁.ammReserveEth = 0 ∧ bs₁.ammReserveBold = 0 ∧
             bs₁.boldCircuitClosed = false ∧ bs₁.boldTvlCap = 0 ∧
             bs₁.boldTotalLockedValue = 0 ∧ bs₁.ammDisabled = false) →
            (bs₂.ammReserveEth = 0 ∧ bs₂.ammReserveBold = 0 ∧
             bs₂.boldCircuitClosed = false ∧ bs₂.boldTvlCap = 0 ∧
             bs₂.boldTotalLockedValue = 0 ∧ bs₂.ammDisabled = false) →
            commitBridgeState bs₁ = commitBridgeState bs₂ :=
          bridgeState_commit_extends_v1_2
        pure ()
    }
  -- 13. Determinism: same AMM state → same commitment.
  , { name := "GP.11.8: identical AMM states produce identical commitments"
    , body := do
        let bs : BridgeState := { BridgeState.empty with
          ammReserveEth := 1000, ammReserveBold := 2000,
          boldCircuitClosed := true, boldTvlCap := 50000,
          boldTotalLockedValue := 30000 }
        let c1 := commitBridgeState bs
        let c2 := commitBridgeState bs
        assertEq (expected := c1) (actual := c2) "determinism on AMM state"
    }
  -- 14. Migration: v1.2 state with genesis AMM fields → well-formed 32-byte commit.
  , { name := "GP.11.8: v1.2 state with genesis AMM defaults → 32-byte commit"
    , body := do
        let dep : DepositRecord := { resource := 0, userAmount := 1000, poolAmount := 0, budgetGrant := 0 }
        let bs : BridgeState := { BridgeState.empty with
          consumed := (∅ : Std.TreeMap DepositId DepositRecord compare).insert 1 dep }
        assertEq (expected := (0 : Nat)) (actual := bs.ammReserveEth) "default ammReserveEth"
        assertEq (expected := (0 : Nat)) (actual := bs.ammReserveBold) "default ammReserveBold"
        assertEq (expected := false) (actual := bs.boldCircuitClosed) "default boldCircuitClosed"
        let c := commitBridgeState bs
        assertEq (expected := 32) (actual := c.size) "32-byte commit"
    }
  -- 15. Cross-stack: encoding round-trip with AMM fields.
  , { name := "GP.11.8: BridgeState encoding with AMM fields round-trips"
    , body := do
        let bs : BridgeState := { BridgeState.empty with
          ammReserveEth := 7777, ammReserveBold := 8888,
          boldCircuitClosed := true, boldTvlCap := 99999,
          boldTotalLockedValue := 55555, ammDisabled := true }
        let encoded := Bridge.BridgeState.encode bs
        match Bridge.BridgeState.decode encoded with
        | .ok (bs', rest) =>
          assert (rest == []) "no trailing bytes after decode"
          assertEq (expected := bs.ammReserveEth) (actual := bs'.ammReserveEth) "ammReserveEth roundtrip"
          assertEq (expected := bs.ammReserveBold) (actual := bs'.ammReserveBold) "ammReserveBold roundtrip"
          assertEq (expected := bs.boldCircuitClosed) (actual := bs'.boldCircuitClosed) "boldCircuitClosed roundtrip"
          assertEq (expected := bs.boldTvlCap) (actual := bs'.boldTvlCap) "boldTvlCap roundtrip"
          assertEq (expected := bs.boldTotalLockedValue) (actual := bs'.boldTotalLockedValue) "boldTotalLockedValue roundtrip"
          assertEq (expected := bs.ammDisabled) (actual := bs'.ammDisabled) "ammDisabled roundtrip"
        | .error e => throw <| IO.userError s!"decode failed: {repr e}"
    }
  -- 16. Non-canonical boldCircuitClosed encoding is rejected.
  , { name := "GP.11.8: decoder rejects non-canonical boldCircuitClosed"
    , body := do
        let bs := BridgeState.empty
        let tampered : Encoding.Stream :=
          Bridge.BridgeState.encodeConsumed bs ++
          Bridge.BridgeState.encodePending bs ++
          Encodable.encode (T := Nat) bs.nextWdId ++
          Encodable.encode (T := Nat) bs.ammReserveEth ++
          Encodable.encode (T := Nat) bs.ammReserveBold ++
          Encodable.encode (T := Nat) 2 ++
          Encodable.encode (T := Nat) bs.boldTvlCap ++
          Encodable.encode (T := Nat) bs.boldTotalLockedValue ++
          Encodable.encode (T := Nat) (if bs.ammDisabled then 1 else 0)
        match Bridge.BridgeState.decode tampered with
        | .error _ => pure ()
        | .ok _ => throw <| IO.userError "decoder accepted non-canonical circuitClosed=2"
    }
  -- 17. Term-level API: bridgeState_encode_factored.
  , { name := "GP.11.8: bridgeState_encode_factored API stable"
    , body := do
        let _proof : ∀ (bs : Bridge.BridgeState),
            Bridge.BridgeState.encode bs =
            bridgeStateEncodeBase bs ++ bridgeStateEncodeAmmSuffix bs :=
          bridgeState_encode_factored
        pure ()
    }
  -- 18. Term-level API: bridgeState_amm_genesis_suffix_const.
  , { name := "GP.11.8: bridgeState_amm_genesis_suffix_const API stable"
    , body := do
        let _proof : ∀ (bs₁ bs₂ : Bridge.BridgeState),
            (bs₁.ammReserveEth = 0 ∧ bs₁.ammReserveBold = 0 ∧
             bs₁.boldCircuitClosed = false ∧ bs₁.boldTvlCap = 0 ∧
             bs₁.boldTotalLockedValue = 0 ∧ bs₁.ammDisabled = false) →
            (bs₂.ammReserveEth = 0 ∧ bs₂.ammReserveBold = 0 ∧
             bs₂.boldCircuitClosed = false ∧ bs₂.boldTvlCap = 0 ∧
             bs₂.boldTotalLockedValue = 0 ∧ bs₂.ammDisabled = false) →
            bridgeStateEncodeAmmSuffix bs₁ = bridgeStateEncodeAmmSuffix bs₂ :=
          bridgeState_amm_genesis_suffix_const
        pure ()
    }
  -- 19. Value-level: factored encoding round-trips back to the same bytes.
  , { name := "GP.11.8: factored encoding produces same bytes as direct"
    , body := do
        let bs : BridgeState := { BridgeState.empty with
          ammReserveEth := 42, ammReserveBold := 99,
          boldCircuitClosed := true, boldTvlCap := 1000,
          boldTotalLockedValue := 500, ammDisabled := true }
        let direct := Bridge.BridgeState.encode bs
        let factored := bridgeStateEncodeBase bs ++ bridgeStateEncodeAmmSuffix bs
        assertEq (expected := direct) (actual := factored) "factored encoding matches direct"
    }
  -- 20. GP.11.10: flipping ammDisabled changes the bridge commitment.
  , { name := "GP.11.10: ammDisabled change alters bridge commitment"
    , body := do
        let bs0 := BridgeState.empty
        let bs1 : BridgeState := { bs0 with ammDisabled := true }
        let c0 := commitBridgeState bs0
        let c1 := commitBridgeState bs1
        assert (c0 ≠ c1) "ammDisabled change must alter commit"
    }
  -- 21. GP.11.10: ammDisabled propagates to the top-level state root.
  , { name := "GP.11.10: ammDisabled change alters top-level state-root"
    , body := do
        let es0 := ExtendedState.empty
        let bs1 : BridgeState := { es0.bridge with ammDisabled := true }
        let es1 : ExtendedState := { es0 with bridge := bs1 }
        let c0 := commitExtendedState es0
        let c1 := commitExtendedState es1
        assert (c0 ≠ c1) "post-kill-switch state root differs from genesis"
    }
  -- 22. GP.11.10: ammDisabled flips independently of the other AMM fields
  --     (a populated state changes its commit on disable alone).
  , { name := "GP.11.10: populated AMM state still distinguishes ammDisabled"
    , body := do
        let bs0 : BridgeState := { BridgeState.empty with
          ammReserveEth := 123456, ammReserveBold := 654321,
          boldCircuitClosed := true, boldTvlCap := 777,
          boldTotalLockedValue := 888 }
        let bs1 : BridgeState := { bs0 with ammDisabled := true }
        assert (commitBridgeState bs0 ≠ commitBridgeState bs1)
          "disable flips the commit even with all other AMM fields populated"
    }
  -- 23. GP.11.10: decoder rejects non-canonical ammDisabled encoding.
  , { name := "GP.11.10: decoder rejects non-canonical ammDisabled"
    , body := do
        let bs := BridgeState.empty
        let tampered : Encoding.Stream :=
          Bridge.BridgeState.encodeConsumed bs ++
          Bridge.BridgeState.encodePending bs ++
          Encodable.encode (T := Nat) bs.nextWdId ++
          Encodable.encode (T := Nat) bs.ammReserveEth ++
          Encodable.encode (T := Nat) bs.ammReserveBold ++
          Encodable.encode (T := Nat) (if bs.boldCircuitClosed then 1 else 0) ++
          Encodable.encode (T := Nat) bs.boldTvlCap ++
          Encodable.encode (T := Nat) bs.boldTotalLockedValue ++
          Encodable.encode (T := Nat) 2
        match Bridge.BridgeState.decode tampered with
        | .error _ => pure ()
        | .ok _ => throw <| IO.userError "decoder accepted non-canonical ammDisabled=2"
    }
  -- 24. GP.11.10: ammDisabled=true round-trips through encode/decode and
  --     the disabled-state commitment is deterministic.
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
  -- 25. Term-level API: bridgeState_commit_extends_v1_3.
  , { name := "GP.11.10: bridgeState_commit_extends_v1_3 API stable"
    , body := do
        let _proof : ∀ (bs₁ bs₂ : Bridge.BridgeState),
            bs₁.consumed = bs₂.consumed →
            bs₁.pending = bs₂.pending →
            bs₁.nextWdId = bs₂.nextWdId →
            bs₁.ammReserveEth = bs₂.ammReserveEth →
            bs₁.ammReserveBold = bs₂.ammReserveBold →
            bs₁.boldCircuitClosed = bs₂.boldCircuitClosed →
            bs₁.boldTvlCap = bs₂.boldTvlCap →
            bs₁.boldTotalLockedValue = bs₂.boldTotalLockedValue →
            bs₁.ammDisabled = false →
            bs₂.ammDisabled = false →
            commitBridgeState bs₁ = commitBridgeState bs₂ :=
          bridgeState_commit_extends_v1_3
        pure ()
    }
  -- 26. Term-level API: commitBridgeState_reflects_ammDisabled.
  , { name := "GP.11.10: commitBridgeState_reflects_ammDisabled API stable"
    , body := do
        let _proof : ∀ (bs₁ bs₂ : Bridge.BridgeState),
            Bridge.CollisionFree LegalKernel.Runtime.hashBytes →
            bs₁.consumed = bs₂.consumed →
            bs₁.pending = bs₂.pending →
            bs₁.nextWdId = bs₂.nextWdId →
            bs₁.ammReserveEth = bs₂.ammReserveEth →
            bs₁.ammReserveBold = bs₂.ammReserveBold →
            bs₁.boldCircuitClosed = bs₂.boldCircuitClosed →
            bs₁.boldTvlCap = bs₂.boldTvlCap →
            bs₁.boldTotalLockedValue = bs₂.boldTotalLockedValue →
            bs₁.ammDisabled ≠ bs₂.ammDisabled →
            commitBridgeState bs₁ ≠ commitBridgeState bs₂ :=
          commitBridgeState_reflects_ammDisabled
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.AmmCommit
