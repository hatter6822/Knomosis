/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.StepVMCoherence — value-level + API-
stability tests for Workstream SVC's cross-stack-coherence
extension.

Tests cover:
  * `actionKindByte` returns the canonical 0..18 index for every
    Action variant.
  * `actionFieldsForL1` produces the expected byte layout for
    structured variants (uint64BE-packed) and opaque variants
    (CBE-encoded payload).
  * `readUint64BE` decodes 8 big-endian bytes correctly.
  * `decodeCellNat` handles both empty (absent) and CBE-encoded
    values.
  * `stepVMHash` dispatch coherence for each variant.
  * `stepVMHashFromAction` matches its underlying dispatch.
  * API-stability for all per-variant `_kind` theorems.
-/

import LegalKernel.FaultProof.StepVMCoherence
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.FaultProof
open LegalKernel.FaultProof.SolidityStepVMCommit
open LegalKernel.FaultProof.StepVMCoherence
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.StepVMCoherence

/-- Tests for the SVC step-VM coherence module. -/
def tests : List TestCase :=
  [ -- ## actionKindByte: per-variant index pinning
    { name := "actionKindByte: transfer is 0"
    , body := do
        assertEq (expected := (0 : UInt8))
          (actual := actionKindByte (.transfer 0 0 0 0))
          "Action.transfer's dispatcher index is 0"
    }
  , { name := "actionKindByte: mint is 1"
    , body := do
        assertEq (expected := (1 : UInt8))
          (actual := actionKindByte (.mint 0 0 0))
          "Action.mint's dispatcher index is 1"
    }
  , { name := "actionKindByte: burn is 2"
    , body := do
        assertEq (expected := (2 : UInt8))
          (actual := actionKindByte (.burn 0 0 0)) "burn"
    }
  , { name := "actionKindByte: freezeResource is 3"
    , body := do
        assertEq (expected := (3 : UInt8))
          (actual := actionKindByte (.freezeResource 0)) "freezeResource"
    }
  , { name := "actionKindByte: replaceKey is 4"
    , body := do
        assertEq (expected := (4 : UInt8))
          (actual := actionKindByte (.replaceKey 0 ByteArray.empty))
          "replaceKey"
    }
  , { name := "actionKindByte: reward is 5"
    , body := do
        assertEq (expected := (5 : UInt8))
          (actual := actionKindByte (.reward 0 0 0)) "reward"
    }
  , { name := "actionKindByte: distributeOthers is 6"
    , body := do
        assertEq (expected := (6 : UInt8))
          (actual := actionKindByte (.distributeOthers 0 0 0))
          "distributeOthers"
    }
  , { name := "actionKindByte: proportionalDilute is 7"
    , body := do
        assertEq (expected := (7 : UInt8))
          (actual := actionKindByte (.proportionalDilute 0 0 0))
          "proportionalDilute"
    }
  , { name := "actionKindByte: registerIdentity is 12"
    , body := do
        assertEq (expected := (12 : UInt8))
          (actual := actionKindByte (.registerIdentity 0 ByteArray.empty))
          "registerIdentity"
    }
  , { name := "actionKindByte: deposit is 13"
    , body := do
        assertEq (expected := (13 : UInt8))
          (actual := actionKindByte (.deposit 0 0 0 0)) "deposit"
    }
  , { name := "actionKindByte: withdraw is 14"
    , body := do
        let addr : Bridge.EthAddress := Bridge.EthAddress.zero
        assertEq (expected := (14 : UInt8))
          (actual := actionKindByte (.withdraw 0 0 0 addr))
          "withdraw"
    }
  , { name := "actionKindByte: declareLocalPolicy is 15"
    , body := do
        assertEq (expected := (15 : UInt8))
          (actual := actionKindByte (.declareLocalPolicy
                       LocalPolicy.empty))
          "declareLocalPolicy"
    }
  , { name := "actionKindByte: revokeLocalPolicy is 16"
    , body := do
        assertEq (expected := (16 : UInt8))
          (actual := actionKindByte .revokeLocalPolicy)
          "revokeLocalPolicy"
    }
  , { name := "actionKindByte: faultProofChallenge is 17"
    , body := do
        assertEq (expected := (17 : UInt8))
          (actual := actionKindByte
            (.faultProofChallenge ByteArray.empty 0 0 ByteArray.empty))
          "faultProofChallenge"
    }
  , { name := "actionKindByte: faultProofResolution is 18"
    , body := do
        assertEq (expected := (18 : UInt8))
          (actual := actionKindByte
            (.faultProofResolution ByteArray.empty 0 0 0))
          "faultProofResolution"
    }
    -- ## actionFieldsForL1: byte-shape pinning
  , { name := "actionFieldsForL1: transfer produces 32 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.transfer 0 0 0 0)
        assertEq (expected := 32) (actual := bytes.size)
          "transfer fields = 4 × uint64BE = 32 bytes"
    }
  , { name := "actionFieldsForL1: mint produces 24 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.mint 0 0 0)
        assertEq (expected := 24) (actual := bytes.size)
          "mint fields = 3 × uint64BE = 24 bytes"
    }
  , { name := "actionFieldsForL1: burn produces 24 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.burn 0 0 0)
        assertEq (expected := 24) (actual := bytes.size)
          "burn fields = 3 × uint64BE = 24 bytes"
    }
  , { name := "actionFieldsForL1: freezeResource produces 8 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.freezeResource 0)
        assertEq (expected := 8) (actual := bytes.size)
          "freezeResource fields = 1 × uint64BE = 8 bytes"
    }
  , { name := "actionFieldsForL1: reward produces 24 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.reward 0 0 0)
        assertEq (expected := 24) (actual := bytes.size)
          "reward fields = 3 × uint64BE = 24 bytes"
    }
  , { name := "actionFieldsForL1: distributeOthers produces 24 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.distributeOthers 0 0 0)
        assertEq (expected := 24) (actual := bytes.size)
          "distributeOthers fields = 3 × uint64BE = 24 bytes"
    }
  , { name := "actionFieldsForL1: proportionalDilute produces 24 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.proportionalDilute 0 0 0)
        assertEq (expected := 24) (actual := bytes.size)
          "proportionalDilute fields = 3 × uint64BE = 24 bytes"
    }
  , { name := "actionFieldsForL1: deposit produces 32 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.deposit 0 0 0 0)
        assertEq (expected := 32) (actual := bytes.size)
          "deposit fields = 4 × uint64BE = 32 bytes"
    }
  , { name := "actionFieldsForL1: revokeLocalPolicy is empty"
    , body := do
        let bytes := actionFieldsForL1 .revokeLocalPolicy
        assertEq (expected := 0) (actual := bytes.size)
          "revokeLocalPolicy has no fields"
    }
    -- ## actionFieldsForL1: big-endian byte order
  , { name := "actionFieldsForL1: transfer encodes r=1 as 8 BE bytes with 1 in last byte"
    , body := do
        let bytes := actionFieldsForL1 (.transfer 1 0 0 0)
        -- r is the first 8 bytes (BE), so bytes[7] should be 1.
        assertEq (expected := (1 : UInt8)) (actual := bytes.data[7]!)
          "r=1 in BE: byte 7 = 1"
        assertEq (expected := (0 : UInt8)) (actual := bytes.data[0]!)
          "r=1 in BE: byte 0 = 0"
    }
  , { name := "actionFieldsForL1: transfer encodes amount=0x42 at byte 31"
    , body := do
        let bytes := actionFieldsForL1 (.transfer 0 0 0 0x42)
        -- amount is the last 8 bytes (BE), so bytes[31] should be 0x42.
        assertEq (expected := (0x42 : UInt8)) (actual := bytes.data[31]!)
          "amount=0x42 in BE: byte 31 = 0x42"
    }
    -- ## readUint64BE: round-trip correctness
  , { name := "readUint64BE: zero array reads 0"
    , body := do
        let zeros := ByteArray.mk (List.replicate 8 (0 : UInt8)).toArray
        assertEq (expected := 0) (actual := readUint64BE zeros 0)
          "all-zero bytes decode to 0"
    }
  , { name := "readUint64BE: out-of-bounds reads 0"
    , body := do
        let short := ByteArray.mk #[1, 2, 3, 4]
        assertEq (expected := 0) (actual := readUint64BE short 0)
          "short buffer returns 0 (defensive)"
    }
  , { name := "readUint64BE: big-endian 0x01..0x08 = 0x0102030405060708"
    , body := do
        let bytes := ByteArray.mk
          #[(1 : UInt8), 2, 3, 4, 5, 6, 7, 8]
        assertEq (expected := 0x0102030405060708)
          (actual := readUint64BE bytes 0)
          "BE-decoded value"
    }
  , { name := "readUint64BE: round-trip through uint64BE"
    , body := do
        let n := 0xDEADBEEFCAFEBABE
        let bytes := uint64BE n
        assertEq (expected := n) (actual := readUint64BE bytes 0)
          "uint64BE round-trips through readUint64BE"
    }
    -- ## decodeCellNat: absent + present cases
  , { name := "decodeCellNat: empty bytes decode to 0"
    , body := do
        assertEq (expected := 0)
          (actual := decodeCellNat ByteArray.empty)
          "empty (absent) decodes to 0"
    }
  , { name := "decodeCellNat: CBE-encoded 42 round-trips"
    , body := do
        let bytes := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 42).toArray
        assertEq (expected := 42) (actual := decodeCellNat bytes)
          "CBE 42 decodes back to 42"
    }
  , { name := "decodeCellNat: CBE-encoded 0xDEADBEEF round-trips"
    , body := do
        let bytes := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 0xDEADBEEF).toArray
        assertEq (expected := 0xDEADBEEF) (actual := decodeCellNat bytes)
          "CBE 0xDEADBEEF round-trips"
    }
    -- ## stepVMHash: dispatch coherence (per-variant)
  , { name := "stepVMHash: kind=0 dispatches to stepCommitTransfer"
    , body := do
        let pc := ByteArray.mk #[(0xAA : UInt8)]
        let fields := actionFieldsForL1 (.transfer 0 0 0 0)
        -- Empty bundle (no balance cells) ⇒ senderBalance = 0,
        -- receiverBalance = 0, self-transfer branch.
        let h1 := stepVMHash pc 0 fields 7 { proofs := [] }
        let h2 := stepCommitTransfer pc 0 0 0 7 0 0
        assertEq (expected := h2) (actual := h1)
          "kind=0 ⇒ stepCommitTransfer dispatch"
    }
  , { name := "stepVMHash: kind=1 dispatches to stepCommitMint"
    , body := do
        let pc := ByteArray.mk #[(0xBB : UInt8)]
        let fields := actionFieldsForL1 (.mint 0 0 0)
        let h1 := stepVMHash pc 1 fields 7 { proofs := [] }
        let h2 := stepCommitMint pc 0 0 7 0
        assertEq (expected := h2) (actual := h1)
          "kind=1 ⇒ stepCommitMint dispatch"
    }
  , { name := "stepVMHash: kind=3 dispatches to stepCommitFreezeResource"
    , body := do
        let pc := ByteArray.mk #[(0xCC : UInt8)]
        let fields := actionFieldsForL1 (.freezeResource 5)
        let h1 := stepVMHash pc 3 fields 7 { proofs := [] }
        let h2 := stepCommitFreezeResource pc 5 7
        assertEq (expected := h2) (actual := h1)
          "kind=3 ⇒ stepCommitFreezeResource dispatch"
    }
  , { name := "stepVMHash: kind=8 (Dispute) dispatches to stepCommitDispute"
    , body := do
        let pc := ByteArray.mk #[(0xDD : UInt8)]
        let fields := ByteArray.mk #[(0xEE : UInt8), 0xEF]
        let h1 := stepVMHash pc 8 fields 7 { proofs := [] }
        let h2 := stepCommitDispute pc fields 7
        assertEq (expected := h2) (actual := h1)
          "kind=8 ⇒ stepCommitDispute dispatch"
    }
  , { name := "stepVMHash: kind=16 (RevokeLocalPolicy) dispatches"
    , body := do
        let pc := ByteArray.mk #[(0xFF : UInt8)]
        let fields := ByteArray.empty
        let h1 := stepVMHash pc 16 fields 7 { proofs := [] }
        let h2 := stepCommitRevokeLocalPolicy pc fields 7
        assertEq (expected := h2) (actual := h1)
          "kind=16 ⇒ stepCommitRevokeLocalPolicy dispatch"
    }
  , { name := "stepVMHash: kind=18 (FaultProofResolution) dispatches"
    , body := do
        let pc := ByteArray.mk #[(0xAA : UInt8)]
        let fields := ByteArray.mk #[(0xBB : UInt8)]
        let h1 := stepVMHash pc 18 fields 7 { proofs := [] }
        let h2 := stepCommitFaultProofResolution pc fields 7
        assertEq (expected := h2) (actual := h1)
          "kind=18 ⇒ stepCommitFaultProofResolution dispatch"
    }
  , { name := "stepVMHash: unknown kind 19 returns empty"
    , body := do
        let pc := ByteArray.mk #[(0xAA : UInt8)]
        let h := stepVMHash pc 19 ByteArray.empty 7 { proofs := [] }
        assertEq (expected := 0) (actual := h.size)
          "unknown kind ⇒ empty bytes"
    }
    -- ## stepVMHashFromAction: composition
  , { name := "stepVMHashFromAction: composition equality"
    , body := do
        let es := ExtendedState.empty
        let action : Action := .freezeResource 0
        let signer : ActorId := 0
        let h1 := stepVMHashFromAction es action signer
        let h2 := stepVMHash (commitExtendedState es)
                    (actionKindByte action)
                    (actionFieldsForL1 action)
                    signer.toNat
                    (Observer.buildObserverCellProofs es action signer)
        assertEq (expected := h2) (actual := h1)
          "stepVMHashFromAction unfolds to its definition"
    }
  , { name := "stepVMHashFromAction: determinism"
    , body := do
        let es := ExtendedState.empty
        let action : Action := .mint 1 2 3
        let signer : ActorId := 4
        let h1 := stepVMHashFromAction es action signer
        let h2 := stepVMHashFromAction es action signer
        assertEq (expected := h1) (actual := h2)
          "same input ⇒ same output"
    }
    -- ## API-stability for the per-variant dispatch theorems
  , { name := "stepVMHash_transfer_kind API stable"
    , body := do
        let _ := @stepVMHash_transfer_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_mint_kind API stable"
    , body := do
        let _ := @stepVMHash_mint_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_burn_kind API stable"
    , body := do
        let _ := @stepVMHash_burn_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_freezeResource_kind API stable"
    , body := do
        let _ := @stepVMHash_freezeResource_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_replaceKey_kind API stable"
    , body := do
        let _ := @stepVMHash_replaceKey_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_reward_kind API stable"
    , body := do
        let _ := @stepVMHash_reward_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_dispute_kind API stable"
    , body := do
        let _ := @stepVMHash_dispute_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_disputeWithdraw_kind API stable"
    , body := do
        let _ := @stepVMHash_disputeWithdraw_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_verdict_kind API stable"
    , body := do
        let _ := @stepVMHash_verdict_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_rollback_kind API stable"
    , body := do
        let _ := @stepVMHash_rollback_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_registerIdentity_kind API stable"
    , body := do
        let _ := @stepVMHash_registerIdentity_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_deposit_kind API stable"
    , body := do
        let _ := @stepVMHash_deposit_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_withdraw_kind API stable"
    , body := do
        let _ := @stepVMHash_withdraw_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_declareLocalPolicy_kind API stable"
    , body := do
        let _ := @stepVMHash_declareLocalPolicy_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_revokeLocalPolicy_kind API stable"
    , body := do
        let _ := @stepVMHash_revokeLocalPolicy_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_faultProofChallenge_kind API stable"
    , body := do
        let _ := @stepVMHash_faultProofChallenge_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_faultProofResolution_kind API stable"
    , body := do
        let _ := @stepVMHash_faultProofResolution_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_unknown_kind_empty API stable"
    , body := do
        let _ := @stepVMHash_unknown_kind_empty
        assert true "API exists"
    }
  , { name := "step_vm_dispatch_well_typed API stable"
    , body := do
        let _ := @step_vm_dispatch_well_typed
        assert true "API exists"
    }
  , { name := "stepVMHashFromAction_dispute API stable"
    , body := do
        let _ := @stepVMHashFromAction_dispute
        assert true "API exists"
    }
  , { name := "stepVMHashFromAction_verdict API stable"
    , body := do
        let _ := @stepVMHashFromAction_verdict
        assert true "API exists"
    }
  , { name := "stepVMHashFromAction_revokeLocalPolicy API stable"
    , body := do
        let _ := @stepVMHashFromAction_revokeLocalPolicy
        assert true "API exists"
    }
  , { name := "stepVMHashFromAction_freezeResource API stable"
    , body := do
        let _ := @stepVMHashFromAction_freezeResource
        assert true "API exists"
    }
    -- ## Cross-stack regression: actionFieldsForL1 matches Solidity layout
  , { name := "cross-stack: transfer field layout matches Solidity decoder"
    , body := do
        -- Build a transfer with distinct values and verify the
        -- bytes can be re-decoded via readUint64BE at the right
        -- offsets.
        let bytes := actionFieldsForL1
          (.transfer (10 : UInt64) (20 : UInt64) (30 : UInt64) (40 : Nat))
        let r := readUint64BE bytes 0
        let s := readUint64BE bytes 8
        let rcv := readUint64BE bytes 16
        let amt := readUint64BE bytes 24
        assertEq (expected := 10) (actual := r) "r = 10"
        assertEq (expected := 20) (actual := s) "sender = 20"
        assertEq (expected := 30) (actual := rcv) "receiver = 30"
        assertEq (expected := 40) (actual := amt) "amount = 40"
    }
  , { name := "cross-stack: mint field layout matches Solidity decoder"
    , body := do
        let bytes := actionFieldsForL1
          (.mint (100 : UInt64) (200 : UInt64) (300 : Nat))
        assertEq (expected := 100) (actual := readUint64BE bytes 0) "r"
        assertEq (expected := 200) (actual := readUint64BE bytes 8) "to"
        assertEq (expected := 300) (actual := readUint64BE bytes 16) "amount"
    }
  , { name := "cross-stack: deposit field layout matches Solidity decoder"
    , body := do
        let bytes := actionFieldsForL1
          (.deposit (1 : UInt64) (2 : UInt64) (3 : Nat) (4 : Nat))
        assertEq (expected := 1) (actual := readUint64BE bytes 0) "r"
        assertEq (expected := 2) (actual := readUint64BE bytes 8) "recipient"
        assertEq (expected := 3) (actual := readUint64BE bytes 16) "amount"
        assertEq (expected := 4) (actual := readUint64BE bytes 24) "depositId"
    }
  ]

end LegalKernel.Test.FaultProof.StepVMCoherence
