/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.WithdrawalRoot — Workstream D.1 acceptance tests.

Drives the `WithdrawalRoot` module's data structures, verifier,
constructor, completeness theorem, and soundness theorem at the
value level.

Test fixtures use a deterministic toy hash function (the FNV-1a-64
fallback wrapped via `Runtime.Hash.hashBytes`) to drive the
proofs to concrete byte sequences.  Production deployments
substitute the keccak256 binding via `@[extern]`.
-/

import LegalKernel.Bridge.WithdrawalRoot
import LegalKernel.Bridge.State
import LegalKernel.Bridge.AddressBook
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Encoding
open LegalKernel.Test

namespace LegalKernel.Test.Bridge.WithdrawalRootTests

/-- A toy deterministic hash for tests: applies `hashBytes` (the
    Phase-5 FNV-1a-64 fallback) directly.  Outputs are 32 bytes. -/
def H : ByteArray → ByteArray := hashBytes

/-- Single-leaf test fixture: one `PendingWithdrawal` at id 7. -/
def fixtureOne : BridgeState :=
  let wd : PendingWithdrawal :=
    { resource := 1, recipient := EthAddress.zero, amount := 100, l2LogIndex := 5 }
  BridgeState.empty.appendWithdrawal wd

/-- Two-leaf test fixture: ids 0 and 1. -/
def fixtureTwo : BridgeState :=
  let wd1 : PendingWithdrawal :=
    { resource := 1, recipient := EthAddress.zero, amount := 100, l2LogIndex := 0 }
  let wd2 : PendingWithdrawal :=
    { resource := 1, recipient := EthAddress.zero, amount := 200, l2LogIndex := 1 }
  (BridgeState.empty.appendWithdrawal wd1).appendWithdrawal wd2

/-- Eight-leaf test fixture: ids 0..7. -/
def fixtureEight : BridgeState :=
  let mkWd (i : Nat) : PendingWithdrawal :=
    { resource := 1, recipient := EthAddress.zero,
      amount := 10 + i, l2LogIndex := i }
  let st0 := BridgeState.empty
  let st1 := st0.appendWithdrawal (mkWd 0)
  let st2 := st1.appendWithdrawal (mkWd 1)
  let st3 := st2.appendWithdrawal (mkWd 2)
  let st4 := st3.appendWithdrawal (mkWd 3)
  let st5 := st4.appendWithdrawal (mkWd 4)
  let st6 := st5.appendWithdrawal (mkWd 5)
  let st7 := st6.appendWithdrawal (mkWd 6)
  let st8 := st7.appendWithdrawal (mkWd 7)
  st8

/-- The tests for `WithdrawalRoot`. -/
def tests : List TestCase :=
  [ -- §8.1.1 — SMT shape constants
    { name := "smtHeight = 64"
    , body := assertEq (expected := (64 : Nat)) (actual := smtHeight) "shape"
    }
  , { name := "emptyLeafHash is 32 bytes"
    , body := assertEq (expected := (32 : Nat)) (actual := emptyLeafHash.size)
                       "size"
    }
  , { name := "defaultHash 0 = emptyLeafHash"
    , body := do
        let _t := @defaultHash_zero
        assert ((defaultHash H 0).toList == emptyLeafHash.toList) "level 0"
    }
  , { name := "defaultHash 1 = H (emptyLeafHash ++ emptyLeafHash)"
    , body := do
        let _t := @defaultHash_succ
        let lhs := (defaultHash H 1).toList
        let rhs := (H (emptyLeafHash ++ emptyLeafHash)).toList
        if lhs == rhs then pure () else throw <| IO.userError "level 1 mismatch"
    }
  , { name := "defaultHash_well_defined: term-level API"
    , body := do
        let _t := @defaultHash_well_defined
        pure ()
    }
  -- §8.1.1 — withdrawalRoot
  , { name := "withdrawalRoot of empty bridge state = defaultHash smtHeight"
    , body := do
        let _t := @withdrawalRoot_empty_eq_defaultHash_top
        let lhs := (withdrawalRoot H BridgeState.empty).toList
        let rhs := (defaultHash H smtHeight).toList
        if lhs == rhs then pure () else throw <| IO.userError "empty mismatch"
    }
  , { name := "withdrawalRoot is deterministic"
    , body := do
        let r1 := (withdrawalRoot H fixtureOne).toList
        let r2 := (withdrawalRoot H fixtureOne).toList
        if r1 == r2 then pure () else throw <| IO.userError "non-deterministic"
    }
  , { name := "withdrawalRoot distinguishes empty from one-leaf"
    , body := do
        let r_empty := (withdrawalRoot H BridgeState.empty).toList
        let r_one := (withdrawalRoot H fixtureOne).toList
        if r_empty == r_one then
          throw <| IO.userError "non-empty collided with empty root"
        else pure ()
    }
  , { name := "withdrawalRoot distinguishes one-leaf from two-leaf"
    , body := do
        let r_one := (withdrawalRoot H fixtureOne).toList
        let r_two := (withdrawalRoot H fixtureTwo).toList
        if r_one == r_two then
          throw <| IO.userError "two-leaf collided with one-leaf"
        else pure ()
    }
  , { name := "withdrawalRoot_extensional: term-level API"
    , body := do
        let _t := @withdrawalRoot_extensional
        pure ()
    }
  -- §8.1.2 — verifyProof / constructProof
  , { name := "constructProof has siblings of length smtHeight"
    , body := do
        let proof := constructProof H fixtureOne 0
        assertEq (expected := smtHeight) (actual := proof.siblings.size) "len"
    }
  , { name := "constructProof_deterministic: same input → same output"
    , body := do
        let p1 := constructProof H fixtureOne 0
        let p2 := constructProof H fixtureOne 0
        if p1 == p2 then pure () else throw <| IO.userError "non-deterministic"
    }
  , { name := "constructProof on absent index has empty-leaf"
    , body := do
        let proof := constructProof H BridgeState.empty 42
        assertEq (expected := emptyLeafHash.toList) (actual := proof.leaf.toList)
                 "empty-leaf"
    }
  , { name := "constructProof on present index has populated leaf"
    , body := do
        let proof := constructProof H fixtureOne 0
        if proof.leaf.toList == emptyLeafHash.toList then
          throw <| IO.userError "populated leaf collided with sentinel"
        else pure ()
    }
  , { name := "constructProof_siblings_length: term-level API"
    , body := do
        let _t := @constructProof_siblings_length
        pure ()
    }
  , { name := "verifyProof_total: term-level API"
    , body := do
        let _t := @verifyProof_total
        pure ()
    }
  -- §8.1.3 — completeness
  , { name := "verifyProof_complete: term-level API"
    , body := do
        let _t := @verifyProof_complete
        pure ()
    }
  , { name := "fixtureOne: canonical proof verifies (single leaf)"
    , body := do
        let proof := constructProof H fixtureOne 0
        let root := withdrawalRoot H fixtureOne
        if verifyProof H proof root then pure ()
        else throw <| IO.userError "canonical proof for fixtureOne failed"
    }
  , { name := "fixtureTwo: canonical proof for id 0 verifies"
    , body := do
        let proof := constructProof H fixtureTwo 0
        let root := withdrawalRoot H fixtureTwo
        if verifyProof H proof root then pure ()
        else throw <| IO.userError "canonical proof at id 0 failed"
    }
  , { name := "fixtureTwo: canonical proof for id 1 verifies"
    , body := do
        let proof := constructProof H fixtureTwo 1
        let root := withdrawalRoot H fixtureTwo
        if verifyProof H proof root then pure ()
        else throw <| IO.userError "canonical proof at id 1 failed"
    }
  , { name := "fixtureEight: canonical proof for id 0 verifies"
    , body := do
        let proof := constructProof H fixtureEight 0
        let root := withdrawalRoot H fixtureEight
        if verifyProof H proof root then pure ()
        else throw <| IO.userError "fixtureEight id 0 failed"
    }
  , { name := "fixtureEight: canonical proof for id 4 verifies"
    , body := do
        let proof := constructProof H fixtureEight 4
        let root := withdrawalRoot H fixtureEight
        if verifyProof H proof root then pure ()
        else throw <| IO.userError "fixtureEight id 4 failed"
    }
  , { name := "fixtureEight: canonical proof for id 7 verifies"
    , body := do
        let proof := constructProof H fixtureEight 7
        let root := withdrawalRoot H fixtureEight
        if verifyProof H proof root then pure ()
        else throw <| IO.userError "fixtureEight id 7 failed"
    }
  -- §8.1.4 — soundness (negative cases — verifier rejects bogus proofs)
  , { name := "verifier rejects proof against wrong root"
    , body := do
        let proof := constructProof H fixtureOne 0
        let bogus := H (ByteArray.mk (Array.replicate 32 (0xFF : UInt8)))
        if verifyProof H proof bogus then
          throw <| IO.userError "verifier accepted bogus root"
        else pure ()
    }
  , { name := "verifier rejects proof with tampered leaf"
    , body := do
        let proof := constructProof H fixtureOne 0
        let tampered : WithdrawalProof :=
          { leaf := ByteArray.mk (Array.replicate 56 (0xFF : UInt8))
            index := proof.index
            siblings := proof.siblings }
        let root := withdrawalRoot H fixtureOne
        if verifyProof H tampered root then
          throw <| IO.userError "verifier accepted tampered leaf"
        else pure ()
    }
  , { name := "verifier rejects proof with tampered first sibling"
    , body := do
        let proof := constructProof H fixtureTwo 0
        let bogusSib := ByteArray.mk (Array.replicate 32 (0xAA : UInt8))
        let tamperedSibs := proof.siblings.set 0 bogusSib
        let tampered : WithdrawalProof :=
          { leaf := proof.leaf
            index := proof.index
            siblings := tamperedSibs }
        let root := withdrawalRoot H fixtureTwo
        if verifyProof H tampered root then
          throw <| IO.userError "verifier accepted tampered sibling"
        else pure ()
    }
  , { name := "verifier rejects proof with tampered index"
    , body := do
        -- Build a canonical proof for id 0, then change the index field to 1.
        -- The siblings are appropriate for id 0's path; under id 1 the path
        -- bits differ at level 0 (LSB), so the recomputed root will differ
        -- from the actual root.
        let proof := constructProof H fixtureTwo 0
        let tampered : WithdrawalProof :=
          { leaf := proof.leaf
            index := 1
            siblings := proof.siblings }
        let root := withdrawalRoot H fixtureTwo
        if verifyProof H tampered root then
          throw <| IO.userError "verifier accepted tampered index"
        else pure ()
    }
  , { name := "verifier rejects proof with tampered leaf-adjacent sibling"
    , body := do
        let proof := constructProof H fixtureEight 0
        let bogusSib := ByteArray.mk (Array.replicate 32 (0xCC : UInt8))
        -- Tamper the leaf-adjacent sibling (siblings[smtHeight - 1] = siblings[63]).
        let tamperedSibs := proof.siblings.set (smtHeight - 1) bogusSib
        let tampered : WithdrawalProof :=
          { leaf := proof.leaf
            index := proof.index
            siblings := tamperedSibs }
        let root := withdrawalRoot H fixtureEight
        if verifyProof H tampered root then
          throw <| IO.userError "verifier accepted tampered leaf-adjacent sibling"
        else pure ()
    }
  , { name := "non-membership proof for unmapped idx verifies"
    , body := do
        -- An unmapped idx's canonical proof has leaf = emptyLeafHash.
        -- This is a valid non-membership proof and verifies against the root.
        let proof := constructProof H fixtureTwo 99
        let root := withdrawalRoot H fixtureTwo
        if verifyProof H proof root then
          assertEq (expected := emptyLeafHash.toList) (actual := proof.leaf.toList)
                   "unmapped leaf is sentinel"
        else
          throw <| IO.userError "non-membership proof for unmapped idx failed"
    }
  , { name := "verifyProof_sound: term-level API"
    , body := do
        let _t := @verifyProof_sound
        pure ()
    }
  , { name := "verifyProof_sound_all_32: term-level API (32-byte corollary)"
    , body := do
        let _t := @verifyProof_sound_all_32
        pure ()
    }
  -- §8.1.4 — verifyProofRec_inj (verifier injectivity)
  , { name := "verifyProofRec_inj: term-level API"
    , body := do
        let _t := @verifyProofRec_inj
        pure ()
    }
  , { name := "siblingsHaveMatchingSizes: definition shape"
    , body := do
        let _t := @siblingsHaveMatchingSizes
        pure ()
    }
  , { name := "siblingsHaveMatchingSizes_of_all_32: term-level API"
    , body := do
        let _t := @siblingsHaveMatchingSizes_of_all_32
        pure ()
    }
  , { name := "CollisionFree: definition shape"
    , body := do
        let _t := @CollisionFree
        pure ()
    }
  , { name := "UniformOutputSize: definition shape"
    , body := do
        let _t := @UniformOutputSize
        pure ()
    }
  -- Edge cases (audit-2)
  , { name := "edge case: max-Nat WithdrawalId index doesn't crash"
    , body := do
        -- Construct a proof for an extremely large idx; the SMT should handle it
        -- (treating as `idx mod 2^smtHeight` due to bit-shifting semantics).
        let proof := constructProof H BridgeState.empty (2^65 + 5)
        -- We just need this to not crash; verifier should accept it as a
        -- non-membership proof (empty bridge has no leaves at any position).
        let root := withdrawalRoot H BridgeState.empty
        if verifyProof H proof root then
          pure ()
        else
          throw <| IO.userError "extremely large idx proof failed"
    }
  , { name := "edge case: idx = 0 single-leaf proof verifies"
    , body := do
        -- The "smallest" idx: bit pattern is all zeros.
        let proof := constructProof H fixtureOne 0
        if !verifyProof H proof (withdrawalRoot H fixtureOne) then
          throw <| IO.userError "id 0 proof failed"
    }
  , { name := "edge case: id 0 + id 1 (sequential dense pair) — both verify"
    , body := do
        -- The realistic deployment case: id 0 and id 1 share the deepest pair.
        -- Both canonical proofs should verify against the root, even though
        -- the leaf-adjacent canonical sibling is leafBytes (variable size).
        let proof0 := constructProof H fixtureTwo 0
        let proof1 := constructProof H fixtureTwo 1
        let root := withdrawalRoot H fixtureTwo
        if !verifyProof H proof0 root then
          throw <| IO.userError "id 0 (sequential pair) proof failed"
        if !verifyProof H proof1 root then
          throw <| IO.userError "id 1 (sequential pair) proof failed"
        -- Verify the leaf-adjacent canonical sibling for id 0 is NOT 32 bytes
        -- (it's leafBytes wd_1 since id 1 is also mapped).
        let lastSib := proof0.siblings.get ⟨smtHeight - 1, by simp [smtHeight]⟩
        -- Should be leafBytes for wd at id 1: ~56 bytes.
        if lastSib.size = 32 then
          throw <| IO.userError s!"expected variable-size leaf-adjacent sibling for dense pair, got {lastSib.size}"
    }
  , { name := "edge case: verifyProof_complete_any_index works for unmapped ids"
    , body := do
        -- The unconditional form covers ids not in pending.
        let proof := constructProof H fixtureTwo 999
        if !verifyProof H proof (withdrawalRoot H fixtureTwo) then
          throw <| IO.userError "non-membership proof for unmapped 999 failed"
    }
  , { name := "verifyProof_complete_any_index: term-level API"
    , body := do
        let _t := @verifyProof_complete_any_index
        pure ()
    }
  ]

end LegalKernel.Test.Bridge.WithdrawalRootTests
