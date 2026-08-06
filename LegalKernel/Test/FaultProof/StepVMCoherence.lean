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
  * `actionKindByte` and `actionFieldsForL1` — the L1 field layout,
    which the fault proof still reads.

The 79 cases pinning `stepVMHash`'s per-variant dispatch went with the
recipe itself: both stacks computed it identically and neither value
was a state root, so the agreement adjudicated nothing.  What the step
VM computes now is pinned by `faultproof-terminate` (Lean) and
`CrossCheck/StepVMRoot.t.sol` (the L1), against a published root.
  * API-stability for all per-variant `_kind` theorems.
-/

import LegalKernel.FaultProof.StepVMCoherence
import LegalKernel.FaultProof.StateCells
import LegalKernel.FaultProof.ProductionApply
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.FaultProof
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
            (.depositWithFee 0 0 0 0 0 0 0 0))
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
  , { name := "actionKindByte: claimBudgetRefund is 22"
    , body := do
        assertEq (expected := (22 : UInt8))
          (actual := actionKindByte
            (.claimBudgetRefund 0 0 0 0))
          "claimBudgetRefund"
    }
  , { name := "actionKindByte: ammSwap is 23"
    , body := do
        assertEq (expected := (23 : UInt8))
          (actual := actionKindByte
            (.ammSwap 0 1 0 0 3))
          "ammSwap"
    }
  , { name := "actionKindByte: reclaimAmmReserves is 24"
    , body := do
        assertEq (expected := (24 : UInt8))
          (actual := actionKindByte
            (.reclaimAmmReserves 0 0 3 1))
          "reclaimAmmReserves"
    }
    -- ## actionFieldsForL1: byte-shape pinning
  , { name := "actionFieldsForL1: transfer produces 56 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.transfer 0 0 0 0)
        assertEq (expected := 56) (actual := bytes.size)
          "transfer fields = 3 × uint64BE + 1 × uint256BE = 56 bytes"
    }
  , { name := "actionFieldsForL1: mint produces 48 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.mint 0 0 0)
        assertEq (expected := 48) (actual := bytes.size)
          "mint fields = 2 × uint64BE + 1 × uint256BE = 48 bytes"
    }
  , { name := "actionFieldsForL1: burn produces 48 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.burn 0 0 0)
        assertEq (expected := 48) (actual := bytes.size)
          "burn fields = 2 × uint64BE + 1 × uint256BE = 48 bytes"
    }
  , { name := "actionFieldsForL1: freezeResource produces 8 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.freezeResource 0)
        assertEq (expected := 8) (actual := bytes.size)
          "freezeResource fields = 1 × uint64BE = 8 bytes"
    }
  , { name := "actionFieldsForL1: reward produces 48 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.reward 0 0 0)
        assertEq (expected := 48) (actual := bytes.size)
          "reward fields = 2 × uint64BE + 1 × uint256BE = 48 bytes"
    }
  , { name := "actionFieldsForL1: distributeOthers produces 48 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.distributeOthers 0 0 0)
        assertEq (expected := 48) (actual := bytes.size)
          "distributeOthers fields = 2 × uint64BE + 1 × uint256BE = 48 bytes"
    }
  , { name := "actionFieldsForL1: proportionalDilute produces 48 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.proportionalDilute 0 0 0)
        assertEq (expected := 48) (actual := bytes.size)
          "proportionalDilute fields = 2 × uint64BE + 1 × uint256BE = 48 bytes"
    }
  , { name := "actionFieldsForL1: deposit produces 56 bytes"
    , body := do
        let bytes := actionFieldsForL1 (.deposit 0 0 0 0)
        assertEq (expected := 56) (actual := bytes.size)
          "deposit fields = 3 × uint64BE + 1 × uint256BE = 56 bytes"
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
  , { name := "actionFieldsForL1: transfer encodes amount=0x42 at byte 55"
    , body := do
        let bytes := actionFieldsForL1 (.transfer 0 0 0 0x42)
        -- amount is the last 32 bytes (BE), so bytes[55] is its LSB.
        assertEq (expected := (0x42 : UInt8)) (actual := bytes.data[55]!)
          "amount=0x42 in BE: byte 55 = 0x42"
        -- The amount's most-significant byte, zero for a small value.
        assertEq (expected := (0 : UInt8)) (actual := bytes.data[24]!)
          "amount high byte is zero for a small amount"
        -- Byte 39 is where the RETIRED 16-byte layout put this LSB.
        -- Pinned at zero so a stack still reading the old width fails
        -- here rather than silently adjudicating a different number.
        assertEq (expected := (0 : UInt8)) (actual := bytes.data[39]!)
          "the retired layout's LSB position now holds a zero"
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
  , { name := "decodeCellNat: an unrecognised tag byte decodes to 0"
    , body := do
        -- Tag byte = 0xFF, neither `cbeTagUint` (0x00) nor
        -- `cbeTagAmount` (0x01).  Solidity's `_decodeNat` reverts
        -- `MalformedCellValue`; Lean returns 0.  Both outcomes mean
        -- "the dispatcher cannot produce the responsible party's
        -- claim", so the success domains still agree byte-for-byte.
        --
        -- An earlier form of both decoders read bytes[1..9] LE and
        -- IGNORED the tag.  That is what let a 33-byte amount cell
        -- pass as its own low 64 bits — a wrong balance, silently,
        -- on the cell values a bisection game settles against.
        let bytes : ByteArray := ByteArray.mk
          #[0xFF, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        assertEq (expected := 0) (actual := decodeCellNat bytes)
          "unrecognised tag must not yield a value"
    }
  , { name := "decodeCellNat: the tag byte is the wire constant"
    , body := do
        -- Pinned as a literal because it IS the wire: Solidity's
        -- `CBEDecode.TAG_AMOUNT` must carry the same byte, and the
        -- probes below hard-code it.  It moved when the body widened
        -- so a stale decoder fails on the tag instead of reading a
        -- 33-byte value as 17 and mis-parsing the remainder.
        assertEq (expected := (0x06 : UInt8)) (actual := Encoding.cbeTagAmount)
          "cbeTagAmount is the byte the Solidity mirror expects"
        assertEq (expected := (0x00 : UInt8)) (actual := Encoding.cbeTagUint)
          "cbeTagUint is unchanged"
    }
  , { name := "decodeCellNat: the tag selects the payload width"
    , body := do
        -- The same 8 payload bytes mean different things under the
        -- two tags: 9 bytes is a complete uint cell, while 9 bytes
        -- under the amount tag is a TRUNCATED amount cell and must
        -- decode to 0 rather than to its low half.
        let payload : ByteArray := ByteArray.mk
          #[0xEF, 0xBE, 0xAD, 0xDE, 0x00, 0x00, 0x00, 0x00]
        let narrow := ByteArray.mk #[0x00] ++ payload
        let truncatedWide := ByteArray.mk #[0x06] ++ payload
        assertEq (expected := 0xDEADBEEF) (actual := decodeCellNat narrow)
          "uint tag + 8 payload bytes reads the value"
        assertEq (expected := 0) (actual := decodeCellNat truncatedWide)
          "amount tag + only 8 payload bytes is malformed, not truncated"
        -- The full-width amount cell for the same value: 1 tag byte
        -- plus 32 body bytes.
        let wide := ByteArray.mk #[0x06] ++ payload ++
          ByteArray.mk
            #[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
              0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        assertEq (expected := 33) (actual := wide.size)
          "an amount cell is 1 tag byte + 32 body bytes"
        assertEq (expected := 0xDEADBEEF) (actual := decodeCellNat wide)
          "amount tag + 32 payload bytes reads the value"
    }
  , { name := "decodeCellNat: a value above 2^64 survives the amount head"
    , body := do
        -- 2^64 exactly: the boundary the 8-byte head truncated to 0.
        let wide : ByteArray := ByteArray.mk
          #[0x06,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        assertEq (expected := 18446744073709551616) (actual := decodeCellNat wide)
          "2^64 decodes exactly, not to 0"
    }
  , { name := "decodeCellNat: a value above 2^128 survives the amount head"
    , body := do
        -- 2^128 exactly: the boundary the 16-byte body truncated to 0,
        -- and 0 is `canonicalAbsentValue` for a balance cell — so under
        -- the retired width this cell read as one that does not exist.
        -- The byte at index 17 is the low byte of the second 16-byte
        -- half, i.e. the `2^128` place.
        let wide : ByteArray := ByteArray.mk
          #[0x06,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        assertEq
          (expected := 340282366920938463463374607431768211456)
          (actual := decodeCellNat wide)
          "2^128 decodes exactly, not to 0 (the absent value)"
    }
  , { name := "decodeCellNat: trailing bytes past the tagged width are malformed"
    , body := do
        -- Exact-width, so a 9-byte uint cell with extra trailing
        -- bytes no longer decodes.  The canonical encoder never
        -- produces this shape; accepting it would give one logical
        -- value two accepted byte forms.
        let bytes : ByteArray := ByteArray.mk
          #[0x00, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xDE, 0xAD, 0xBE, 0xEF]
        assertEq (expected := 0) (actual := decodeCellNat bytes)
          "trailing bytes past the tagged width are rejected"
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
        let amt := readUint256BE bytes 24
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
        assertEq (expected := 300) (actual := readUint256BE bytes 16) "amount"
    }
  , { name := "cross-stack: deposit field layout matches Solidity decoder"
    , body := do
        let bytes := actionFieldsForL1
          (.deposit (1 : UInt64) (2 : UInt64) (3 : Nat) (4 : Nat))
        assertEq (expected := 1) (actual := readUint64BE bytes 0) "r"
        assertEq (expected := 2) (actual := readUint64BE bytes 8) "recipient"
        assertEq (expected := 3) (actual := readUint256BE bytes 16) "amount"
        assertEq (expected := 4) (actual := readUint64BE bytes 48) "depositId"
    }
  , { name := "cross-stack: depositWithFee field layout matches Solidity decoder"
    , body := do
        -- Workstream GP closure + Workstream SB: depositWithFee's
        -- eight-field layout is fixed at 5 × uint64BE + 3 × uint256BE
        -- = 136 bytes, the three wide fields being the wei-denominated
        -- userAmount, poolAmount, and the APPENDED seedAmount (so
        -- every pre-existing offset survives).  This test pins the
        -- byte offsets so the Solidity `_step19` decoder reads each
        -- field at the matching offset and with the matching width.
        let bytes := actionFieldsForL1
          (.depositWithFee (1 : UInt64) (2 : UInt64) (3 : UInt64)
                           (4 : Nat) (5 : Nat) (6 : Nat) (7 : Nat) (8 : Nat))
        assertEq (expected := 136) (actual := bytes.size)
                 "5 × uint64BE + 3 × uint256BE = 136 bytes"
        assertEq (expected := 1) (actual := readUint64BE bytes 0)   "r"
        assertEq (expected := 2) (actual := readUint64BE bytes 8)   "recipient"
        assertEq (expected := 3) (actual := readUint64BE bytes 16)  "poolActor"
        assertEq (expected := 4) (actual := readUint256BE bytes 24) "userAmount"
        assertEq (expected := 5) (actual := readUint256BE bytes 56) "poolAmount"
        assertEq (expected := 6) (actual := readUint64BE bytes 88)  "budgetGrant"
        assertEq (expected := 7) (actual := readUint64BE bytes 96)  "depositId"
        assertEq (expected := 8) (actual := readUint256BE bytes 104) "seedAmount"
    }
  , { name := "cross-stack: topUpActionBudget field layout matches Solidity decoder"
    , body := do
        let bytes := actionFieldsForL1
          (.topUpActionBudget (1 : UInt64) (2 : Nat) (3 : Nat) (4 : UInt64))
        assertEq (expected := 56) (actual := bytes.size)
                 "3 × uint64BE + 1 × uint256BE = 56 bytes"
        assertEq (expected := 1) (actual := readUint64BE bytes 0)   "gasResource"
        assertEq (expected := 2) (actual := readUint256BE bytes 8)  "gasAmount"
        assertEq (expected := 3) (actual := readUint64BE bytes 40)  "budgetIncrement"
        assertEq (expected := 4) (actual := readUint64BE bytes 48)  "poolActor"
    }
  , { name := "cross-stack: topUpActionBudgetFor field layout matches Solidity decoder"
    , body := do
        -- GP.5.3 closure: topUpActionBudgetFor's five-field layout is
        -- fixed at 4 × uint64BE + 1 × uint256BE = 64 bytes.  The
        -- leading `recipient` field shifts the gas-transfer fields
        -- right by 8 bytes relative to topUpActionBudget; this pins
        -- the byte offsets so the Solidity `_step21` decoder reads
        -- gasResource at 8, the 32-byte gasAmount at 16, poolActor at
        -- 56 (recipient at 0 and budgetIncrement at 48 are
        -- admission-layer, not hashed).
        let bytes := actionFieldsForL1
          (.topUpActionBudgetFor (1 : UInt64) (2 : UInt64) (3 : Nat)
                                 (4 : Nat) (5 : UInt64))
        assertEq (expected := 64) (actual := bytes.size)
                 "4 × uint64BE + 1 × uint256BE = 64 bytes"
        assertEq (expected := 1) (actual := readUint64BE bytes 0)   "recipient"
        assertEq (expected := 2) (actual := readUint64BE bytes 8)   "gasResource"
        assertEq (expected := 3) (actual := readUint256BE bytes 16) "gasAmount"
        assertEq (expected := 4) (actual := readUint64BE bytes 48)  "budgetIncrement"
        assertEq (expected := 5) (actual := readUint64BE bytes 56)  "poolActor"
    }
  , { name := "OBLIGATION: writeCells declares the nonce for every action"
    , body := do
        let signer : ActorId := 7
        let actions : List Action :=
          [ .transfer 1 7 8 5, .mint 1 8 5, .burn 1 8 5, .freezeResource 1
          , .replaceKey 7 (ByteArray.mk #[1]), .reward 1 8 5
          , .distributeOthers 1 2 5, .proportionalDilute 1 2 5
          , .registerIdentity 7 (ByteArray.mk #[1])
          , .deposit 1 8 5 3, .withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero
          , .declareLocalPolicy Authority.LocalPolicy.empty, .revokeLocalPolicy
          , .depositWithFee 1 8 9 5 1 1 3 1, .topUpActionBudget 1 5 1 9
          , .topUpActionBudgetFor 8 1 5 1 9, .claimBudgetRefund 1 1 5 9
          , .ammSwap 1 2 5 4 9, .reclaimAmmReserves 1 5 9 8 ]
        for a in actions do
          if !((Action.writeCells a signer).contains (.nonce signer)) then
            throw <| IO.userError
              s!"writeCells omits the nonce for kind {actionKindByte a}"
    }
  , { name := "OBLIGATION: the reference apply omits a declared bridge write"
    , body := do
        -- The fault-proof coherence chain is anchored to
        -- `commitExtendedState ∘ kernelOnlyApply` (theorem #225), and
        -- `kernelOnlyApply` deliberately does not model bridge
        -- mutations.  `Action.writeCells` for a deposit nonetheless
        -- declares `.bridgeConsumed d` — correctly, because the
        -- PUBLISHED state root reflects the real, bridge-aware
        -- advance.  The two references disagree, which is harmless
        -- while the step VM's output is only compared against itself
        -- and an adjudication error the moment it is compared against
        -- a state root.  §4 has to settle which apply is the
        -- reference before the handlers can be written.
        let signer : ActorId := 7
        let d : LegalKernel.Bridge.DepositId := 3
        let action : Action := .deposit 1 8 5 d
        assert ((Action.writeCells action signer).contains (.bridgeConsumed d))
          "writeCells declares the consumed-deposit write"
        let es := ExtendedState.empty
        let entry : Runtime.LogEntry :=
          { prevHash := ByteArray.empty
          , signedAction :=
              { action, signer, nonce := 0, sig := ByteArray.empty }
          , postStateHash := ByteArray.empty }
        let after := Disputes.kernelOnlyApply es entry
        assertEq (expected := (getCellValue es (.bridgeConsumed d)).toList)
          (actual := (getCellValue after (.bridgeConsumed d)).toList)
          "but kernelOnlyApply leaves the cell untouched"
        -- The nonce, by contrast, does move — so the reference apply
        -- is not simply inert.
        assert ((getCellValue es (.nonce signer)).toList
                  != (getCellValue after (.nonce signer)).toList)
          "the reference apply does advance the nonce"
        -- And the RUNTIME's advance does record the deposit: the
        -- published root moves where the fault-proof model's does
        -- not.  `Runtime.processSignedAction` goes through
        -- `apply_bridge_admissible_with_budget`, whose bridge leg is
        -- `applyActionToBridgeState`.
        let realBridge :=
          LegalKernel.Bridge.applyActionToBridgeState es.bridge action 0
        let realAfter : ExtendedState := { after with bridge := realBridge }
        assert ((getCellValue realAfter (.bridgeConsumed d)).toList
                  != (getCellValue after (.bridgeConsumed d)).toList)
          "the runtime's advance records the deposit; the model's does not"
        assert ((commitExtendedState realAfter).toList
                  != (commitExtendedState after).toList)
          "so the two post-states have different roots"
        -- `productionApply` is the total function the guarded
        -- production stepper computes, so it IS the state above.
        assertEq (expected := (commitExtendedState realAfter).toList)
          (actual := (commitExtendedState
                       (productionApply es entry.signedAction 0)).toList)
          "productionApply reproduces the runtime's post-state"
    }
  , { name := "every action DECLARES the signer's epoch-budget cell"
    , body := do
        -- Read from `EpochBudgetState.consume`, which ends in
        -- `ebs.insert a b'` unconditionally: under a `.bounded`
        -- policy every admitted action from a non-bridge signer
        -- rewrites the signer's budget entry.  So the runtime's
        -- advance moves `.epochBudget signer` on EVERY action, and
        -- `Action.writeCells` declares that cell for NONE of the 25.
        --
        -- This is the budget-leg peer of the nonce obligation above,
        -- and it is strictly larger in consequence: the nonce gap
        -- makes the post-root wrong for every action, and so does
        -- this one, but this one is invisible from `kernelOnlyApply`
        -- (which has no budget leg at all) and therefore does not
        -- show up in any theorem anchored to it.
        let signer : ActorId := 7
        let action : Action := .transfer 1 signer 8 5
        let st : SignedAction := { action, signer, nonce := 0, sig := ByteArray.empty }
        assert ((Action.writeCells action signer).contains (.epochBudget signer))
          "writeCells declares the epoch-budget write"
        -- Declared on every variant, not just this one: the consume
        -- is signer-keyed and fires regardless of the action.
        let actions : List Action :=
          [ .transfer 1 7 8 5, .mint 1 8 5, .burn 1 8 5, .freezeResource 1
          , .replaceKey 7 (ByteArray.mk #[1]), .reward 1 8 5
          , .distributeOthers 1 2 5, .proportionalDilute 1 2 5
          , .registerIdentity 7 (ByteArray.mk #[1])
          , .deposit 1 8 5 3, .withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero
          , .declareLocalPolicy Authority.LocalPolicy.empty, .revokeLocalPolicy
          , .depositWithFee 1 8 9 5 1 1 3 1, .topUpActionBudget 1 5 1 9
          , .topUpActionBudgetFor 8 1 5 1 9, .claimBudgetRefund 1 1 5 9
          , .ammSwap 1 2 5 4 9, .reclaimAmmReserves 1 5 9 8 ]
        for a in actions do
          if !((Action.writeCells a signer).contains (.epochBudget signer)) then
            throw <| IO.userError
              s!"writeCells omits the epoch budget for kind {actionKindByte a}"
        -- And the two delegated variants additionally declare the
        -- RECIPIENT's cell, because that is where their grant lands.
        assert ((Action.writeCells (.depositWithFee 1 8 9 5 1 1 3 1) signer).contains
                  (.epochBudget 8))
          "depositWithFee declares the recipient's budget cell"
        assert ((Action.writeCells (.topUpActionBudgetFor 8 1 5 1 9) signer).contains
                  (.epochBudget 8))
          "topUpActionBudgetFor declares the recipient's budget cell"
        -- A state with a bounded budget policy and the signer funded.
        let es : ExtendedState :=
          { ExtendedState.empty with
              base := LegalKernel.setBalance ExtendedState.empty.base 1 signer 100
            , budgetPolicy := .bounded 10 3 1 }
        -- The cell moves exactly when the consume SUCCEEDS, which is
        -- what admission requires — so on the adjudication path (where
        -- L2 admission already happened) it always moves.  At epoch 0
        -- against an empty budget the consume refuses and the cell
        -- stays put, which is why the epoch is 1 here: `normalise`
        -- refreshes the balance to the free tier first.
        let after := productionApplyBudget es st 0
        assert (budgetGateAdmits es st (fun _ => 0)) "the action is admitted"
        assert ((getCellValue es (.epochBudget signer)).toList
                  != (getCellValue after (.epochBudget signer)).toList)
          "but the production advance moves the cell"
        -- And it moves the published root, so a step VM that omitted
        -- the write would compute a root no state has.
        let omitted : ExtendedState := { after with epochBudgets := es.epochBudgets }
        assert ((commitExtendedState omitted).toList
                  != (commitExtendedState after).toList)
          "omitting it lands on a different root"
    }
  , { name := "productionApply agrees with the replay off the bridge path"
    , body := do
        -- The other half of the divergence: on a non-bridge action
        -- the production advance and the dispute pipeline's replay
        -- are the same state, so the fault-proof layer's current
        -- choice of core is correct there and only there.
        let signer : ActorId := 7
        let st : SignedAction :=
          { action := .transfer 1 7 8 0, signer, nonce := 0
          , sig := ByteArray.empty }
        let es := ExtendedState.empty
        assertEq (expected := (commitExtendedState
                    (Disputes.kernelOnlyApply es (signedActionEntry st))).toList)
          (actual := (commitExtendedState (productionApply es st 0)).toList)
          "non-bridge: the two cores agree"
    }
  , { name := "productionApplyBudget models the epoch-budget leg"
    , body := do
        -- The budget leg is the other half of the divergence: the
        -- runtime consumes the signer's epoch budget on every
        -- non-bridgeActor action, and `kernelOnlyApply` models none
        -- of it.  Budget cells are tag 13, so the root binds them.
        let signer : ActorId := 7
        let st : SignedAction :=
          { action := .transfer 1 7 8 0, signer, nonce := 0
          , sig := ByteArray.empty }
        let es : ExtendedState :=
          { ExtendedState.empty with
              budgetPolicy := .bounded 10 3 0
            , epochBudgets := (∅ : EpochBudgetState).insert signer
                                { lastSeenEpoch := 0, budgetBalance := 50 } }
        let viaBudget := productionApplyBudget es st 0
        let viaBridge := productionApply es st 0
        assert ((getCellValue viaBudget (.epochBudget signer)).toList
                  != (getCellValue viaBridge (.epochBudget signer)).toList)
          "the budget leg moves the signer's epoch-budget cell"
        assert ((commitExtendedState viaBudget).toList
                  != (commitExtendedState viaBridge).toList)
          "and therefore the root"
        -- `bridgeActor` is exempt from the consume, so its budget
        -- cell does not move.
        let stBridge : SignedAction :=
          { action := .transfer 1 0 8 0, signer := LegalKernel.Bridge.bridgeActor
          , nonce := 0, sig := ByteArray.empty }
        assertEq (expected := (getCellValue (productionApply es stBridge 0)
                    (.epochBudget LegalKernel.Bridge.bridgeActor)).toList)
          (actual := (getCellValue (productionApplyBudget es stBridge 0)
                    (.epochBudget LegalKernel.Bridge.bridgeActor)).toList)
          "bridgeActor is exempt from the consume"
    }
  , { name := "API stability: the production-faithful core"
    , body := do
        let _tot : ∀ (verify : Authority.PublicKey → ByteArray →
              Authority.Signature → Bool)
            (P : Authority.AuthorityPolicy) (deploymentId : ByteArray)
            (es : ExtendedState) (st : SignedAction) (l2LogIndex : Nat)
            (h : LegalKernel.Bridge.BridgeAdmissibleWith verify P deploymentId es st),
            LegalKernel.Bridge.apply_bridge_admissible_with verify P deploymentId es st
                l2LogIndex h
              = productionApply es st l2LogIndex :=
          apply_bridge_admissible_with_eq_productionApply
        let _bud : ∀ (verify : Authority.PublicKey → ByteArray →
              Authority.Signature → Bool)
            (P : Authority.AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
            (st : SignedAction) (l2LogIndex : Nat)
            (h : LegalKernel.Bridge.BridgeAdmissibleWith verify P d es st)
            (refundRate : ResourceId → Nat),
            LegalKernel.Bridge.apply_bridge_admissible_with_budget verify P d es st
                l2LogIndex h refundRate
              = (if budgetGateAdmits es st refundRate then
                   some (productionApplyBudget es st l2LogIndex) else none) :=
          apply_bridge_admissible_with_budget_eq
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.StepVMCoherence
