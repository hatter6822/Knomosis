/-
  Knomosis  - A Societal Kernel
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
  , { name := "stepVMHash: unknown kind 21 returns empty"
    , body := do
        -- Kinds 19 (`.depositWithFee`) and 20 (`.topUpActionBudget`)
        -- are now wired through the dispatcher (Workstream GP).  The
        -- catch-all path fires only for kinds ≥ 21.
        let pc := ByteArray.mk #[(0xAA : UInt8)]
        let h := stepVMHash pc 21 ByteArray.empty 7 { proofs := [] }
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
  ]

end LegalKernel.Test.FaultProof.StepVMCoherence
