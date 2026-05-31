-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.StepVMCoherence — value-level + API-
stability tests for Workstream SVC's cross-stack-coherence
extension.

Tests cover:
  * `actionKindByte` returns the canonical 0..20 index for every
    Action variant (0..18 from SVC plus Workstream-GP's
    `depositWithFee` = 19 and `topUpActionBudget` = 20).
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
    -- Workstream GP: two new variants at action-indices 19, 20.
  , { name := "actionKindByte: depositWithFee is 19"
    , body := do
        assertEq (expected := (19 : UInt8))
          (actual := actionKindByte
            (.depositWithFee 0 0 0 0 0 0 0))
          "depositWithFee"
    }
  , { name := "actionKindByte: topUpActionBudget is 20"
    , body := do
        assertEq (expected := (20 : UInt8))
          (actual := actionKindByte
            (.topUpActionBudget 0 0 0 0))
          "topUpActionBudget"
    }
  , { name := "actionKindByte: topUpActionBudgetFor is 21"
    , body := do
        assertEq (expected := (21 : UInt8))
          (actual := actionKindByte
            (.topUpActionBudgetFor 0 0 0 0 0))
          "topUpActionBudgetFor"
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
    -- ## decodeCellNat: cross-stack byte-equivalence with Solidity's _decodeNat
  , { name := "decodeCellNat: non-canonical tag byte is IGNORED (mirrors Solidity)"
    , body := do
        -- Tag byte = 0xFF (not the canonical cbeTagUint = 0x00).
        -- Solidity's `_decodeNat` reads bytes[1..9] LE regardless
        -- of the tag.  This function MUST do the same to maintain
        -- byte-equivalence with the L1 contract.
        let bytes : ByteArray := ByteArray.mk
          #[0xFF, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        -- Expected value: bytes[1..9] LE = 0x2A = 42.
        assertEq (expected := 42) (actual := decodeCellNat bytes)
          "non-canonical tag must not block the value read"
    }
  , { name := "decodeCellNat: arbitrary first byte preserves bytes[1..9] LE value"
    , body := do
        -- Confirms bytes[0] genuinely doesn't affect the value.
        -- Same payload as above but with multiple distinct tags.
        let payload : ByteArray := ByteArray.mk
          #[0xEF, 0xBE, 0xAD, 0xDE, 0x00, 0x00, 0x00, 0x00]
        let bytes_a : ByteArray :=
          ByteArray.mk #[0x00] ++ payload   -- canonical
        let bytes_b : ByteArray :=
          ByteArray.mk #[0x01] ++ payload
        let bytes_c : ByteArray :=
          ByteArray.mk #[0xFF] ++ payload
        let va := decodeCellNat bytes_a
        let vb := decodeCellNat bytes_b
        let vc := decodeCellNat bytes_c
        assertEq (expected := 0xDEADBEEF) (actual := va) "canonical tag value"
        assertEq (expected := va) (actual := vb) "tag=0x01 same value"
        assertEq (expected := va) (actual := vc) "tag=0xFF same value"
    }
  , { name := "decodeCellNat: length 9 + extra trailing bytes ignored"
    , body := do
        -- Solidity's _decodeNat reads exactly 8 bytes starting at
        -- offset 1.  Trailing bytes after offset 9 are silently
        -- ignored by both sides (Solidity's slice-only semantics).
        let bytes : ByteArray := ByteArray.mk
          #[0x00, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xDE, 0xAD, 0xBE, 0xEF]
        assertEq (expected := 42) (actual := decodeCellNat bytes)
          "trailing bytes after offset 9 don't affect the decode"
    }
  , { name := "decodeCellNat: short bytes (length 1..8) return 0"
    , body := do
        -- Solidity reverts here; Lean returns 0 (documented in
        -- decodeCellNat's docstring; the chosen 0 ensures the
        -- dispatcher's hash can't match any honestly-claimed pivot
        -- under collision-resistance).
        for n in [1, 2, 3, 5, 7, 8] do
          let bytes : ByteArray := ByteArray.mk (Array.replicate n (0xAA : UInt8))
          assertEq (expected := 0) (actual := decodeCellNat bytes)
            s!"length {n} returns 0"
    }
  , { name := "decodeCellNat: full u64 max payload round-trips"
    , body := do
        -- The boundary value 2^64 - 1 = 0xFFFFFFFFFFFFFFFF.
        -- All 8 payload bytes are 0xFF.
        let bytes : ByteArray := ByteArray.mk
          #[0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        assertEq (expected := 0xFFFFFFFFFFFFFFFF)
          (actual := decodeCellNat bytes)
          "u64 max round-trips"
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
    -- ## Bulk-variant dispatch: head + per-recipient fold (mirrors
    -- ##                       Solidity's bulk loop byte-for-byte)
  , { name := "stepVMHash: kind=6 with empty bundle returns just head"
    , body := do
        -- No balance cells ⇒ Solidity's filter rejects all ⇒ no folds ⇒ head only.
        let pc := ByteArray.mk #[(0xAA : UInt8)]
        let fields := actionFieldsForL1 (.distributeOthers 0 0 0)
        let h1 := stepVMHash pc 6 fields 7 { proofs := [] }
        let h2 := stepCommitDistributeOthersHead pc 0 0 7 0
        assertEq (expected := h2) (actual := h1)
          "kind=6, empty bundle ⇒ head only"
    }
  , { name := "stepVMHash: kind=6 with one matching balance cell folds once"
    , body := do
        -- Bundle has one balance cell for (r=5, actor=10) with
        -- pre-balance 100, excluding actor 1 (≠ 10).  Solidity:
        --   head = keccak(pc || TAG_DO || r=5 || ex=1 || amt=50 || sig=7)
        --   acc  = keccak(head || keyB=10(u256) || newBal=150(u256))
        let pc := ByteArray.mk #[(0xBB : UInt8)]
        let r : Nat := 5; let excluded : Nat := 1; let amount : Nat := 50
        let fields := actionFieldsForL1 (.distributeOthers r.toUInt64 excluded.toUInt64 amount)
        -- Build one balance cell with cellValue = CBE(100).
        let preBalBytes := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let cellTag : CellTag := .balance r.toUInt64 (10 : UInt64)
        let proof : CellProof :=
          { cellTag, cellValue := preBalBytes,
            witnessState := ExtendedState.empty }
        let bundle : CellProofBundle := { proofs := [proof] }
        let h1 := stepVMHash pc 6 fields 7 bundle
        let head := stepCommitDistributeOthersHead pc r excluded 7 amount
        let h2 := stepCommitDistributeOthersFold head 10 (100 + amount)
        assertEq (expected := h2) (actual := h1)
          "kind=6, 1 matching cell ⇒ head + 1 fold"
    }
  , { name := "stepVMHash: kind=6 excludes the excluded-actor cell"
    , body := do
        -- Bundle has one balance cell for (r=5, actor=excluded=2).
        -- Solidity's filter `keyB != excluded` rejects it ⇒ no folds.
        let pc := ByteArray.mk #[(0xCC : UInt8)]
        let r : Nat := 5; let excluded : Nat := 2; let amount : Nat := 50
        let fields := actionFieldsForL1 (.distributeOthers r.toUInt64 excluded.toUInt64 amount)
        let preBalBytes := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let cellTag : CellTag := .balance r.toUInt64 excluded.toUInt64
        let proof : CellProof :=
          { cellTag, cellValue := preBalBytes,
            witnessState := ExtendedState.empty }
        let bundle : CellProofBundle := { proofs := [proof] }
        let h1 := stepVMHash pc 6 fields 7 bundle
        let h2 := stepCommitDistributeOthersHead pc r excluded 7 amount
        assertEq (expected := h2) (actual := h1)
          "kind=6 with excluded-actor's cell ⇒ head only (filter rejects)"
    }
  , { name := "stepVMHash: kind=6 skips non-balance cells (registry/nonce)"
    , body := do
        -- Bundle has registry+nonce cells (no balance) ⇒ filter
        -- rejects both ⇒ no folds.
        let pc := ByteArray.mk #[(0xDD : UInt8)]
        let r : Nat := 5; let excluded : Nat := 2; let amount : Nat := 50
        let fields := actionFieldsForL1 (.distributeOthers r.toUInt64 excluded.toUInt64 amount)
        let regProof : CellProof :=
          { cellTag := .registry (7 : UInt64),
            cellValue := ByteArray.empty,
            witnessState := ExtendedState.empty }
        let nonceProof : CellProof :=
          { cellTag := .nonce (7 : UInt64),
            cellValue := ByteArray.empty,
            witnessState := ExtendedState.empty }
        let bundle : CellProofBundle := { proofs := [regProof, nonceProof] }
        let h1 := stepVMHash pc 6 fields 7 bundle
        let h2 := stepCommitDistributeOthersHead pc r excluded 7 amount
        assertEq (expected := h2) (actual := h1)
          "kind=6 with non-balance cells ⇒ head only (filter rejects)"
    }
  , { name := "stepVMHash: kind=7 with empty bundle returns head with sumOthers=0"
    , body := do
        let pc := ByteArray.mk #[(0xAA : UInt8)]
        let fields := actionFieldsForL1 (.proportionalDilute 0 0 100)
        let h1 := stepVMHash pc 7 fields 7 { proofs := [] }
        -- Empty bundle ⇒ sumOthers = 0 ⇒ head with sumOthers=0; no fold.
        let h2 := stepCommitProportionalDiluteHead pc 0 0 7 100 0
        assertEq (expected := h2) (actual := h1)
          "kind=7, empty bundle ⇒ head with sumOthers=0"
    }
  , { name := "stepVMHash: kind=7 with one balance cell folds with credit"
    , body := do
        -- One balance cell: (r=3, actor=11, balance=200).
        -- excluded=1; totalReward=50.
        -- sumOthers = 200; credit = 50 * 200 / 200 = 50; newBal = 250.
        let pc := ByteArray.mk #[(0xCC : UInt8)]
        let r : Nat := 3; let excluded : Nat := 1; let totalReward : Nat := 50
        let fields := actionFieldsForL1
          (.proportionalDilute r.toUInt64 excluded.toUInt64 totalReward)
        let preBalBytes := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 200).toArray
        let cellTag : CellTag := .balance r.toUInt64 (11 : UInt64)
        let proof : CellProof :=
          { cellTag, cellValue := preBalBytes,
            witnessState := ExtendedState.empty }
        let bundle : CellProofBundle := { proofs := [proof] }
        let h1 := stepVMHash pc 7 fields 7 bundle
        let sumOthers := 200
        let head := stepCommitProportionalDiluteHead pc r excluded 7
                      totalReward sumOthers
        let credit := totalReward * 200 / sumOthers  -- = 50
        let newBal := 200 + credit                    -- = 250
        let h2 := stepCommitProportionalDiluteFold head 11 newBal
        assertEq (expected := h2) (actual := h1)
          "kind=7, 1 matching cell ⇒ head + 1 credit-weighted fold"
    }
  , { name := "stepVMHash: kind=7 with two cells matches two-pass logic"
    , body := do
        -- Two balance cells: (r=3, actor=11, bal=200), (r=3, actor=12, bal=100).
        -- excluded=1; totalReward=300.
        -- sumOthers = 300; credit_11 = 300*200/300 = 200; credit_12 = 300*100/300 = 100.
        -- newBal_11 = 400; newBal_12 = 200.
        -- Fold order: 11 first, then 12.
        let pc := ByteArray.mk #[(0xDD : UInt8)]
        let r : Nat := 3; let excluded : Nat := 1; let totalReward : Nat := 300
        let fields := actionFieldsForL1
          (.proportionalDilute r.toUInt64 excluded.toUInt64 totalReward)
        let bal200 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 200).toArray
        let bal100 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let p11 : CellProof :=
          { cellTag := .balance r.toUInt64 (11 : UInt64),
            cellValue := bal200,
            witnessState := ExtendedState.empty }
        let p12 : CellProof :=
          { cellTag := .balance r.toUInt64 (12 : UInt64),
            cellValue := bal100,
            witnessState := ExtendedState.empty }
        let bundle : CellProofBundle := { proofs := [p11, p12] }
        let h1 := stepVMHash pc 7 fields 7 bundle
        let sumOthers := 300
        let head := stepCommitProportionalDiluteHead pc r excluded 7
                      totalReward sumOthers
        let acc1 := stepCommitProportionalDiluteFold head 11 (200 + 200)
        let acc2 := stepCommitProportionalDiluteFold acc1 12 (100 + 100)
        assertEq (expected := acc2) (actual := h1)
          "kind=7, 2 matching cells ⇒ head + 2 fold steps in iteration order"
    }
  , { name := "stepVMHash: kind=6 with mixed bundle (registry+nonce+balances) folds only balances"
    , body := do
        -- Bundle: [registry, nonce, balance(r=4,act=20,bal=100),
        --           balance(r=4,act=30,bal=200)].
        -- excluded=99 (no cell matches it); amount=10.
        -- Expected: head + fold(act=20, newBal=110) + fold(act=30, newBal=210).
        let pc := ByteArray.mk #[(0xEE : UInt8)]
        let r : Nat := 4; let excluded : Nat := 99; let amount : Nat := 10
        let fields := actionFieldsForL1
          (.distributeOthers r.toUInt64 excluded.toUInt64 amount)
        let bal100 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let bal200 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 200).toArray
        let regProof : CellProof :=
          { cellTag := .registry (7 : UInt64),
            cellValue := ByteArray.empty,
            witnessState := ExtendedState.empty }
        let nonceProof : CellProof :=
          { cellTag := .nonce (7 : UInt64),
            cellValue := ByteArray.empty,
            witnessState := ExtendedState.empty }
        let bal20 : CellProof :=
          { cellTag := .balance r.toUInt64 (20 : UInt64),
            cellValue := bal100,
            witnessState := ExtendedState.empty }
        let bal30 : CellProof :=
          { cellTag := .balance r.toUInt64 (30 : UInt64),
            cellValue := bal200,
            witnessState := ExtendedState.empty }
        let bundle : CellProofBundle :=
          { proofs := [regProof, nonceProof, bal20, bal30] }
        let h1 := stepVMHash pc 6 fields 7 bundle
        let head := stepCommitDistributeOthersHead pc r excluded 7 amount
        let acc1 := stepCommitDistributeOthersFold head 20 110
        let acc2 := stepCommitDistributeOthersFold acc1 30 210
        assertEq (expected := acc2) (actual := h1)
          "kind=6 mixed bundle ⇒ registry/nonce skipped, balance folds in order"
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
  , { name := "stepVMHash: unknown kind 22 returns empty"
    , body := do
        -- Kinds 19 (`.depositWithFee`), 20 (`.topUpActionBudget`), and
        -- 21 (`.topUpActionBudgetFor`, GP.5.3) are now wired through
        -- the dispatcher.  The catch-all path fires only for kinds
        -- ≥ 22.
        let pc := ByteArray.mk #[(0xAA : UInt8)]
        let h := stepVMHash pc 22 ByteArray.empty 7 { proofs := [] }
        assertEq (expected := 0) (actual := h.size)
          "unknown kind ⇒ empty bytes"
    }
    -- ## Workstream GP value-level dispatch tests (kinds 19 / 20)
  , { name := "stepVMHash: kind=19 (DepositWithFee) dispatches with distinct recipient ≠ poolActor"
    , body := do
        -- Build a fixture matching Solidity's `_stepDepositWithFee`
        -- byte-for-byte: r=1, recipient=2, poolActor=3, userAmount=100,
        -- poolAmount=10, budgetGrant=5 (admission-only, not hashed),
        -- depositId=7.  Recipient pre-balance=20; poolActor pre-balance=30.
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action : Action :=
          .depositWithFee (1 : UInt64) (2 : UInt64) (3 : UInt64)
                          (100 : Nat) (10 : Nat) (5 : Nat) (7 : Nat)
        let fields := actionFieldsForL1 action
        -- Pre-balance cells: recipient (20), poolActor (30).
        let bal20 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 20).toArray
        let bal30 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 30).toArray
        let pRecipient : CellProof :=
          { cellTag := .balance (1 : UInt64) (2 : UInt64),
            cellValue := bal20, witnessState := ExtendedState.empty }
        let pPool : CellProof :=
          { cellTag := .balance (1 : UInt64) (3 : UInt64),
            cellValue := bal30, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle :=
          { proofs := [pRecipient, pPool] }
        let h1 := stepVMHash pc 19 fields 0 bundle
        -- Expected: stepCommitDepositWithFee with newRecipientBal=120,
        -- newPoolBal=40, depositId=7, signer=0 (bridgeActor).
        let h2 := stepCommitDepositWithFee pc 1 2 3 0 120 40 7
        assertEq (expected := h2) (actual := h1)
          "kind=19 distinct recipient/pool ⇒ two-arm credit"
    }
  , { name := "stepVMHash: kind=19 (DepositWithFee) self-credit (recipient = poolActor)"
    , body := do
        -- Self-credit edge case: recipient == poolActor.  Both writes
        -- land on the same cell; the new balance is
        -- pre + userAmount + poolAmount.
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action : Action :=
          .depositWithFee (1 : UInt64) (5 : UInt64) (5 : UInt64)
                          (100 : Nat) (10 : Nat) (5 : Nat) (7 : Nat)
        let fields := actionFieldsForL1 action
        let bal50 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 50).toArray
        let pSelf : CellProof :=
          { cellTag := .balance (1 : UInt64) (5 : UInt64),
            cellValue := bal50, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle := { proofs := [pSelf] }
        let h1 := stepVMHash pc 19 fields 0 bundle
        -- Expected: newRecipientBal = newPoolBal = 50 + 100 + 10 = 160.
        let h2 := stepCommitDepositWithFee pc 1 5 5 0 160 160 7
        assertEq (expected := h2) (actual := h1)
          "kind=19 self-credit ⇒ collapsed +userAmount+poolAmount"
    }
  , { name := "stepVMHash: kind=20 (TopUpActionBudget) dispatches with distinct signer ≠ poolActor"
    , body := do
        -- Build a fixture matching Solidity's `_stepTopUpActionBudget`
        -- byte-for-byte: gasResource=2, gasAmount=15, budgetIncrement=30
        -- (admission-only, not hashed), poolActor=99.  Signer=10
        -- with pre-balance 100; poolActor pre-balance 5.
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action : Action :=
          .topUpActionBudget (2 : UInt64) (15 : Nat) (30 : Nat) (99 : UInt64)
        let fields := actionFieldsForL1 action
        let bal100 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let bal5 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 5).toArray
        let pSigner : CellProof :=
          { cellTag := .balance (2 : UInt64) (10 : UInt64),
            cellValue := bal100, witnessState := ExtendedState.empty }
        let pPool : CellProof :=
          { cellTag := .balance (2 : UInt64) (99 : UInt64),
            cellValue := bal5, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle :=
          { proofs := [pSigner, pPool] }
        let h1 := stepVMHash pc 20 fields 10 bundle
        -- Expected: stepCommitTopUpActionBudget with newSignerBal=85,
        -- newPoolBal=20.
        let h2 := stepCommitTopUpActionBudget pc 2 10 99 85 20
        assertEq (expected := h2) (actual := h1)
          "kind=20 distinct signer/pool ⇒ debit-then-credit"
    }
  , { name := "stepVMHash: kind=20 (TopUpActionBudget) self-pool defended branch is no-op"
    , body := do
        -- Defence-in-depth corner case: signer = poolActor.  The
        -- admission gate rejects this upstream (round-4 self-pool
        -- defense); the dispatcher's defended branch should
        -- produce a net-zero kernel-state hash (newSignerBal =
        -- newPoolBal = pre-balance).
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action : Action :=
          .topUpActionBudget (2 : UInt64) (15 : Nat) (30 : Nat) (10 : UInt64)
        let fields := actionFieldsForL1 action
        let bal100 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let pSigner : CellProof :=
          { cellTag := .balance (2 : UInt64) (10 : UInt64),
            cellValue := bal100, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle := { proofs := [pSigner] }
        let h1 := stepVMHash pc 20 fields 10 bundle
        -- Expected: newSignerBal = newPoolBal = 100 (self-pool branch).
        let h2 := stepCommitTopUpActionBudget pc 2 10 10 100 100
        assertEq (expected := h2) (actual := h1)
          "kind=20 self-pool ⇒ defended no-op (both writes equal pre-balance)"
    }
  , { name := "stepVMHash: kind=19 ignores budgetGrant in the step-VM hash"
    , body := do
        -- Workstream GP design: `budgetGrant` is an admission-layer
        -- effect on `recipient`'s epochBudgets slot; the L1 step VM
        -- DOES NOT consume it.  Two fixtures with different
        -- budgetGrant values but otherwise identical inputs must
        -- produce the SAME step-VM hash.
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action1 : Action :=
          .depositWithFee (1 : UInt64) (2 : UInt64) (3 : UInt64)
                          (100 : Nat) (10 : Nat) (5 : Nat) (7 : Nat)
        let action2 : Action :=
          .depositWithFee (1 : UInt64) (2 : UInt64) (3 : UInt64)
                          (100 : Nat) (10 : Nat) (999999 : Nat) (7 : Nat)
        let fields1 := actionFieldsForL1 action1
        let fields2 := actionFieldsForL1 action2
        let bal20 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 20).toArray
        let bal30 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 30).toArray
        let pRecipient : CellProof :=
          { cellTag := .balance (1 : UInt64) (2 : UInt64),
            cellValue := bal20, witnessState := ExtendedState.empty }
        let pPool : CellProof :=
          { cellTag := .balance (1 : UInt64) (3 : UInt64),
            cellValue := bal30, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle :=
          { proofs := [pRecipient, pPool] }
        let h1 := stepVMHash pc 19 fields1 0 bundle
        let h2 := stepVMHash pc 19 fields2 0 bundle
        assertEq (expected := h1) (actual := h2)
          "different budgetGrant ⇒ same step-VM hash"
    }
  , { name := "stepVMHash: kind=20 ignores budgetIncrement in the step-VM hash"
    , body := do
        -- Same design: `budgetIncrement` is admission-only.  Two
        -- fixtures differing only in `budgetIncrement` produce the
        -- same step-VM hash.
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action1 : Action :=
          .topUpActionBudget (2 : UInt64) (15 : Nat) (30 : Nat) (99 : UInt64)
        let action2 : Action :=
          .topUpActionBudget (2 : UInt64) (15 : Nat) (999999 : Nat) (99 : UInt64)
        let fields1 := actionFieldsForL1 action1
        let fields2 := actionFieldsForL1 action2
        let bal100 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let bal5 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 5).toArray
        let pSigner : CellProof :=
          { cellTag := .balance (2 : UInt64) (10 : UInt64),
            cellValue := bal100, witnessState := ExtendedState.empty }
        let pPool : CellProof :=
          { cellTag := .balance (2 : UInt64) (99 : UInt64),
            cellValue := bal5, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle :=
          { proofs := [pSigner, pPool] }
        let h1 := stepVMHash pc 20 fields1 10 bundle
        let h2 := stepVMHash pc 20 fields2 10 bundle
        assertEq (expected := h1) (actual := h2)
          "different budgetIncrement ⇒ same step-VM hash"
    }
    -- ## GP.5.3 value-level dispatch tests (kind 21)
  , { name := "stepVMHash: kind=21 (TopUpActionBudgetFor) dispatches with distinct signer ≠ poolActor"
    , body := do
        -- Build a fixture matching Solidity's `_stepTopUpActionBudgetFor`
        -- byte-for-byte: recipient=50 (admission-only, not hashed),
        -- gasResource=2, gasAmount=15, budgetIncrement=30 (admission-only,
        -- not hashed), poolActor=99.  Signer=10 with pre-balance 100;
        -- poolActor pre-balance 5.
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action : Action :=
          .topUpActionBudgetFor (50 : UInt64) (2 : UInt64) (15 : Nat)
                                (30 : Nat) (99 : UInt64)
        let fields := actionFieldsForL1 action
        let bal100 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let bal5 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 5).toArray
        let pSigner : CellProof :=
          { cellTag := .balance (2 : UInt64) (10 : UInt64),
            cellValue := bal100, witnessState := ExtendedState.empty }
        let pPool : CellProof :=
          { cellTag := .balance (2 : UInt64) (99 : UInt64),
            cellValue := bal5, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle :=
          { proofs := [pSigner, pPool] }
        let h1 := stepVMHash pc 21 fields 10 bundle
        -- Expected: stepCommitTopUpActionBudgetFor with newSignerBal=85,
        -- newPoolBal=20.
        let h2 := stepCommitTopUpActionBudgetFor pc 2 10 99 85 20
        assertEq (expected := h2) (actual := h1)
          "kind=21 distinct signer/pool ⇒ debit-then-credit"
    }
  , { name := "stepVMHash: kind=21 distinct from kind=20 on identical gas-transfer fields (tag separation)"
    , body := do
        -- A delegated top-up and a self-funded top-up with the SAME
        -- (gasResource, gasAmount, poolActor, signer, pre-balances)
        -- must produce DIFFERENT step-VM hashes — the distinct tag
        -- (`topUpActionBudgetFor` ≠ `topUpActionBudget`) is what
        -- separates them.  Otherwise a bisection-game opponent could
        -- substitute one variant's commit for the other's.
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action21 : Action :=
          .topUpActionBudgetFor (50 : UInt64) (2 : UInt64) (15 : Nat)
                                (30 : Nat) (99 : UInt64)
        let action20 : Action :=
          .topUpActionBudget (2 : UInt64) (15 : Nat) (30 : Nat) (99 : UInt64)
        let bal100 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let bal5 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 5).toArray
        let pSigner : CellProof :=
          { cellTag := .balance (2 : UInt64) (10 : UInt64),
            cellValue := bal100, witnessState := ExtendedState.empty }
        let pPool : CellProof :=
          { cellTag := .balance (2 : UInt64) (99 : UInt64),
            cellValue := bal5, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle := { proofs := [pSigner, pPool] }
        let h21 := stepVMHash pc 21 (actionFieldsForL1 action21) 10 bundle
        let h20 := stepVMHash pc 20 (actionFieldsForL1 action20) 10 bundle
        assert (h21 ≠ h20)
          "delegated vs self-funded top-up ⇒ distinct commits via tag"
    }
  , { name := "stepVMHash: kind=21 (TopUpActionBudgetFor) self-pool defended branch is no-op"
    , body := do
        -- Defence-in-depth corner case: signer = poolActor.  The
        -- admission gate rejects this upstream (round-4 self-pool
        -- defense); the dispatcher's defended branch should produce a
        -- net-zero kernel-state hash (newSignerBal = newPoolBal =
        -- pre-balance).
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action : Action :=
          .topUpActionBudgetFor (50 : UInt64) (2 : UInt64) (15 : Nat)
                                (30 : Nat) (10 : UInt64)
        let fields := actionFieldsForL1 action
        let bal100 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let pSigner : CellProof :=
          { cellTag := .balance (2 : UInt64) (10 : UInt64),
            cellValue := bal100, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle := { proofs := [pSigner] }
        let h1 := stepVMHash pc 21 fields 10 bundle
        -- Expected: newSignerBal = newPoolBal = 100 (self-pool branch).
        let h2 := stepCommitTopUpActionBudgetFor pc 2 10 10 100 100
        assertEq (expected := h2) (actual := h1)
          "kind=21 self-pool ⇒ defended no-op (both writes equal pre-balance)"
    }
  , { name := "stepVMHash: kind=21 exact-balance drain zeroes the signer (Nat boundary)"
    , body := do
        -- Boundary parity with Solidity's `<`-guard edge case
        -- (`test_topUpActionBudgetFor_exact_balance_zeroes_signer`):
        -- gasAmount = signerBalance ⇒ newSigner = 0.  On the Lean side
        -- this is the `signerBalance - gasAmount = 0` Nat boundary; the
        -- step-VM hash must match Solidity's exact-drain commit so the
        -- cross-stack equivalence holds at the edge (gasResource=2,
        -- gasAmount=50, signer=10 pre-balance 50, poolActor=99
        -- pre-balance 10).
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action : Action :=
          .topUpActionBudgetFor (50 : UInt64) (2 : UInt64) (50 : Nat)
                                (30 : Nat) (99 : UInt64)
        let fields := actionFieldsForL1 action
        let bal50 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 50).toArray
        let bal10 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 10).toArray
        let pSigner : CellProof :=
          { cellTag := .balance (2 : UInt64) (10 : UInt64),
            cellValue := bal50, witnessState := ExtendedState.empty }
        let pPool : CellProof :=
          { cellTag := .balance (2 : UInt64) (99 : UInt64),
            cellValue := bal10, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle := { proofs := [pSigner, pPool] }
        let h1 := stepVMHash pc 21 fields 10 bundle
        -- Expected: newSigner = 50 - 50 = 0; newPool = 10 + 50 = 60.
        let h2 := stepCommitTopUpActionBudgetFor pc 2 10 99 0 60
        assertEq (expected := h2) (actual := h1)
          "kind=21 exact-balance ⇒ newSigner=0, pool credited full amount"
    }
  , { name := "stepVMHash: kind=21 ignores recipient + budgetIncrement in the step-VM hash"
    , body := do
        -- GP.5.3 design: `recipient` (offset 0) and `budgetIncrement`
        -- (offset 24) are admission-layer effects on the RECIPIENT's
        -- epochBudgets slot; the L1 step VM DOES NOT consume them.
        -- Two fixtures differing only in recipient + budgetIncrement
        -- but with identical gas-transfer fields must produce the
        -- SAME step-VM hash.
        let pc := ByteArray.mk #[(0xCD : UInt8)]
        let action1 : Action :=
          .topUpActionBudgetFor (50 : UInt64) (2 : UInt64) (15 : Nat)
                                (30 : Nat) (99 : UInt64)
        let action2 : Action :=
          .topUpActionBudgetFor (777 : UInt64) (2 : UInt64) (15 : Nat)
                                (999999 : Nat) (99 : UInt64)
        let fields1 := actionFieldsForL1 action1
        let fields2 := actionFieldsForL1 action2
        let bal100 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 100).toArray
        let bal5 := ByteArray.mk
          (Encoding.Encodable.encode (T := Nat) 5).toArray
        let pSigner : CellProof :=
          { cellTag := .balance (2 : UInt64) (10 : UInt64),
            cellValue := bal100, witnessState := ExtendedState.empty }
        let pPool : CellProof :=
          { cellTag := .balance (2 : UInt64) (99 : UInt64),
            cellValue := bal5, witnessState := ExtendedState.empty }
        let bundle : CellProofBundle :=
          { proofs := [pSigner, pPool] }
        let h1 := stepVMHash pc 21 fields1 10 bundle
        let h2 := stepVMHash pc 21 fields2 10 bundle
        assertEq (expected := h1) (actual := h2)
          "different recipient/budgetIncrement ⇒ same step-VM hash"
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
    -- ## GP.3.3 end-to-end production-path coverage.  These verify
    -- the FULL `stepVMHashFromAction` chain (commitExtendedState +
    -- actionFieldsForL1 + buildObserverCellProofs + dispatcher) for
    -- the new variants computes the correct post-balances by
    -- reading them out of the observer-built cell-proof bundle —
    -- closing the gap between the hand-built-bundle dispatch unit
    -- tests above and the hand-composed fixture-corpus expected
    -- values.  If buildObserverCellProofs ever stops emitting the
    -- recipient / poolActor balance cells (or emits them with the
    -- wrong tag), these assertions break.
  , { name := "stepVMHashFromAction: depositWithFee distinct reads pre-balances from observer bundle"
    , body := do
        -- Pre-state: balance(1,4)=25, balance(1,5)=15.
        let es : ExtendedState :=
          let b1 := LegalKernel.setBalance LegalKernel.genesisState 1 4 25
          let b2 := LegalKernel.setBalance b1 1 5 15
          { ExtendedState.empty with base := b2 }
        let action : Action := .depositWithFee 1 4 5 100 10 50 7
        let signer : ActorId := Bridge.bridgeActor
        let viaDispatcher := stepVMHashFromAction es action signer
        -- recipient 25 + userAmount 100 = 125; pool 15 + poolAmount 10 = 25.
        let viaCommit :=
          stepCommitDepositWithFee (commitExtendedState es) 1 4 5
            signer.toNat 125 25 7
        assertEq (expected := viaCommit) (actual := viaDispatcher)
          "full path computes recipient=125, pool=25 from observer bundle"
    }
  , { name := "stepVMHashFromAction: depositWithFee self-credit reads collapsed pre-balance"
    , body := do
        -- Self-credit: recipient = poolActor = 5, balance(1,5)=15.
        let es : ExtendedState :=
          { ExtendedState.empty with
            base := LegalKernel.setBalance LegalKernel.genesisState 1 5 15 }
        let action : Action := .depositWithFee 1 5 5 100 10 50 7
        let signer : ActorId := Bridge.bridgeActor
        let viaDispatcher := stepVMHashFromAction es action signer
        -- self-credit: 15 + 100 + 10 = 125 for both writes.
        let viaCommit :=
          stepCommitDepositWithFee (commitExtendedState es) 1 5 5
            signer.toNat 125 125 7
        assertEq (expected := viaCommit) (actual := viaDispatcher)
          "self-credit collapses to 125 = pre + userAmount + poolAmount"
    }
  , { name := "stepVMHashFromAction: topUpActionBudget reads signer + pool gas balances from observer bundle"
    , body := do
        -- Pre-state: balance(2,10)=100, balance(2,99)=5.  signer=10
        -- (non-bridge, non-pool); gasAmount=15.
        let es : ExtendedState :=
          let b1 := LegalKernel.setBalance LegalKernel.genesisState 2 10 100
          let b2 := LegalKernel.setBalance b1 2 99 5
          { ExtendedState.empty with base := b2 }
        let action : Action := .topUpActionBudget 2 15 30 99
        let signer : ActorId := 10
        let viaDispatcher := stepVMHashFromAction es action signer
        -- signer 100 - 15 = 85; pool 5 + 15 = 20.
        let viaCommit :=
          stepCommitTopUpActionBudget (commitExtendedState es) 2 10 99 85 20
        assertEq (expected := viaCommit) (actual := viaDispatcher)
          "full path computes signer=85, pool=20 from observer bundle"
    }
  , { name := "stepVMHashFromAction: topUpActionBudgetFor reads signer + pool gas balances from observer bundle"
    , body := do
        -- GP.5.3 end-to-end: pre-state balance(2,10)=100,
        -- balance(2,99)=5.  signer=10 (non-bridge, non-pool);
        -- recipient=50 (≠ signer); gasAmount=15.  The full chain
        -- (commitExtendedState + actionFieldsForL1 +
        -- buildObserverCellProofs + dispatcher) must read the signer +
        -- pool balances from the observer bundle and compute
        -- signer=85, pool=20 — the same as the self-funded
        -- topUpActionBudget but under the DISTINCT delegated tag.
        let es : ExtendedState :=
          let b1 := LegalKernel.setBalance LegalKernel.genesisState 2 10 100
          let b2 := LegalKernel.setBalance b1 2 99 5
          { ExtendedState.empty with base := b2 }
        let action : Action := .topUpActionBudgetFor 50 2 15 30 99
        let signer : ActorId := 10
        let viaDispatcher := stepVMHashFromAction es action signer
        -- signer 100 - 15 = 85; pool 5 + 15 = 20.
        let viaCommit :=
          stepCommitTopUpActionBudgetFor (commitExtendedState es) 2 10 99 85 20
        assertEq (expected := viaCommit) (actual := viaDispatcher)
          "full path computes signer=85, pool=20 from observer bundle"
    }
  , { name := "stepVMHashFromAction: topUpActionBudgetFor credits pool from an absent (zero) pre-balance"
    , body := do
        -- GP.5.3 edge case mirroring the depositWithFee absent-cell
        -- test: the pool actor has NO balance entry in genesis (absent
        -- ⇒ canonical 0).  `buildObserverCellProofs` still emits the
        -- `balance gasResource poolActor` cell (with encode(0)), so the
        -- dispatcher must read 0 and credit it to gasAmount.  The
        -- signer keeps a sufficient balance so the non-self branch
        -- (which Solidity guards with InsufficientBalance) is taken.
        let es : ExtendedState :=
          { ExtendedState.empty with
            base := LegalKernel.setBalance LegalKernel.genesisState 3 12 40 }
        let action : Action := .topUpActionBudgetFor 77 3 15 30 88
        let signer : ActorId := 12
        let viaDispatcher := stepVMHashFromAction es action signer
        -- signer 40 - 15 = 25; pool (absent ⇒ 0) + 15 = 15.
        let viaCommit :=
          stepCommitTopUpActionBudgetFor (commitExtendedState es) 3 12 88 25 15
        assertEq (expected := viaCommit) (actual := viaDispatcher)
          "absent pool pre-balance read as 0, credited to gasAmount"
    }
  , { name := "stepVMHashFromAction: depositWithFee with zero pre-balances credits from absent cells"
    , body := do
        -- Recipient + poolActor have NO balance in genesis (absent ⇒
        -- canonical 0).  buildObserverCellProofs still emits the
        -- balance cells (getCellValue returns encode(0)); the
        -- dispatcher must read 0 and credit to userAmount/poolAmount.
        let es : ExtendedState := ExtendedState.empty
        let action : Action := .depositWithFee 3 8 9 40 20 50 11
        let signer : ActorId := Bridge.bridgeActor
        let viaDispatcher := stepVMHashFromAction es action signer
        -- recipient 0 + 40 = 40; pool 0 + 20 = 20.
        let viaCommit :=
          stepCommitDepositWithFee (commitExtendedState es) 3 8 9
            signer.toNat 40 20 11
        assertEq (expected := viaCommit) (actual := viaDispatcher)
          "absent pre-balances read as 0, credited to amounts"
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
  , { name := "stepVMHash_distributeOthers_kind API stable"
    , body := do
        let _ := @stepVMHash_distributeOthers_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_proportionalDilute_kind API stable"
    , body := do
        let _ := @stepVMHash_proportionalDilute_kind
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
  , { name := "cross-stack: depositWithFee field layout matches Solidity decoder"
    , body := do
        -- Workstream GP closure: depositWithFee's seven-field layout
        -- is fixed (7 × uint64BE = 56 bytes total).  This test pins
        -- the byte offsets so the Solidity `_step19` decoder (when
        -- added) reads each field at the matching offset.
        let bytes := actionFieldsForL1
          (.depositWithFee (1 : UInt64) (2 : UInt64) (3 : UInt64)
                           (4 : Nat) (5 : Nat) (6 : Nat) (7 : Nat))
        assertEq (expected := 56) (actual := bytes.size)
                 "7 fields × 8 bytes BE = 56 bytes"
        assertEq (expected := 1) (actual := readUint64BE bytes 0)  "r"
        assertEq (expected := 2) (actual := readUint64BE bytes 8)  "recipient"
        assertEq (expected := 3) (actual := readUint64BE bytes 16) "poolActor"
        assertEq (expected := 4) (actual := readUint64BE bytes 24) "userAmount"
        assertEq (expected := 5) (actual := readUint64BE bytes 32) "poolAmount"
        assertEq (expected := 6) (actual := readUint64BE bytes 40) "budgetGrant"
        assertEq (expected := 7) (actual := readUint64BE bytes 48) "depositId"
    }
  , { name := "cross-stack: topUpActionBudget field layout matches Solidity decoder"
    , body := do
        let bytes := actionFieldsForL1
          (.topUpActionBudget (1 : UInt64) (2 : Nat) (3 : Nat) (4 : UInt64))
        assertEq (expected := 32) (actual := bytes.size)
                 "4 fields × 8 bytes BE = 32 bytes"
        assertEq (expected := 1) (actual := readUint64BE bytes 0)  "gasResource"
        assertEq (expected := 2) (actual := readUint64BE bytes 8)  "gasAmount"
        assertEq (expected := 3) (actual := readUint64BE bytes 16) "budgetIncrement"
        assertEq (expected := 4) (actual := readUint64BE bytes 24) "poolActor"
    }
  , { name := "cross-stack: topUpActionBudgetFor field layout matches Solidity decoder"
    , body := do
        -- GP.5.3 closure: topUpActionBudgetFor's five-field layout is
        -- fixed (5 × uint64BE = 40 bytes total).  The leading
        -- `recipient` field shifts the gas-transfer fields right by 8
        -- bytes relative to topUpActionBudget; this pins the byte
        -- offsets so the Solidity `_step21` decoder reads gasResource
        -- at 8, gasAmount at 16, poolActor at 32 (recipient at 0 and
        -- budgetIncrement at 24 are admission-layer, not hashed).
        let bytes := actionFieldsForL1
          (.topUpActionBudgetFor (1 : UInt64) (2 : UInt64) (3 : Nat)
                                 (4 : Nat) (5 : UInt64))
        assertEq (expected := 40) (actual := bytes.size)
                 "5 fields × 8 bytes BE = 40 bytes"
        assertEq (expected := 1) (actual := readUint64BE bytes 0)  "recipient"
        assertEq (expected := 2) (actual := readUint64BE bytes 8)  "gasResource"
        assertEq (expected := 3) (actual := readUint64BE bytes 16) "gasAmount"
        assertEq (expected := 4) (actual := readUint64BE bytes 24) "budgetIncrement"
        assertEq (expected := 5) (actual := readUint64BE bytes 32) "poolActor"
    }
  -- ## "Ensure this can't happen again" — dispatcher coverage
  -- regression tests.  These guarantee that every `actionKindByte`
  -- value has a non-empty `stepVMHash` dispatch path: a future PR
  -- that adds an Action constructor must also extend the
  -- dispatcher, or these tests will fail.
  , { name := "stepVMHash: every actionKindByte case dispatches to a non-empty hash"
    , body := do
        -- Build a sample bundle that covers the cell shapes the
        -- structured kinds read.  For the bulk variants (6 / 7),
        -- the bundle's `.proofs` set determines the iterated cells;
        -- empty is fine — the head hash is still emitted.
        let pc := ByteArray.mk #[(0xAA : UInt8)]
        let signer : Nat := 7
        -- Per-variant minimal field bytes (matches each variant's
        -- `actionFieldsForL1` width).  We use small constants to
        -- keep the test deterministic.
        let mkBundle : CellProofBundle := {
          proofs := [
            { cellTag := .balance 1 7, cellValue := ByteArray.empty,
              witnessState := ExtendedState.empty },
            { cellTag := .balance 1 99, cellValue := ByteArray.empty,
              witnessState := ExtendedState.empty }
          ]
        }
        -- Each kind has its own fields layout, so we test the
        -- catch-all property: dispatcher returns 32-byte hash, not
        -- ByteArray.empty.  The exact value doesn't matter — only
        -- non-emptiness.
        for kind in actionKindByteCases do
          let fields := ByteArray.mk
            #[0,0,0,0,0,0,0,1,  0,0,0,0,0,0,0,2,  0,0,0,0,0,0,0,3,
              0,0,0,0,0,0,0,4,  0,0,0,0,0,0,0,5,  0,0,0,0,0,0,0,6,
              0,0,0,0,0,0,0,7]
          let h := stepVMHash pc kind fields signer mkBundle
          assert (h.size > 0) s!"kind {kind}: dispatcher must return non-empty hash"
    }
  , { name := "stepVMHash_depositWithFee_kind API stable"
    , body := do
        let _ := @stepVMHash_depositWithFee_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_topUpActionBudget_kind API stable"
    , body := do
        let _ := @stepVMHash_topUpActionBudget_kind
        assert true "API exists"
    }
  , { name := "stepVMHash_topUpActionBudgetFor_kind API stable"
    , body := do
        let _ := @stepVMHash_topUpActionBudgetFor_kind
        assert true "API exists"
    }
  ]

end LegalKernel.Test.FaultProof.StepVMCoherence
