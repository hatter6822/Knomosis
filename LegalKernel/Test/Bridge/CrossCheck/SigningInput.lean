-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.SigningInput — Workstream F-A
(on-chain signature verification at terminate), phase FA.1.

Generates the `signing_input.json` cross-stack fixture: for EVERY
frozen `Action` constructor (indices 0..25), the packed L1 field
layout (`actionFieldsForL1`), the canonical CBE action encoding
(`Action.encode`), and the full §8.8.5 sign-input bytes
(`Authority.signingInput`) for a fixed `(signer, nonce,
deploymentId)` triple.

**Why this fixture exists.**  The L1 fault-proof game's terminal step
receives the disputed action as the packed `(kind, fields)` pair the
batch leaf binds; VERIFYING the action's signature needs the digest
the signer attested, which is `keccak256` of the CBE sign-input — a
different encoding.  `solidity/src/lib/SignInput.sol` transcodes
packed → CBE and assembles the sign-input on-chain; its consumer test
(`solidity/test/CrossCheck/SigningInput.t.sol`) reconstructs each
entry's sign-input bytes from `(kind, fieldsHex, signer, nonce,
deploymentIdHex)` alone and asserts byte-equality against the
Lean-computed `signingInputHex`.  A transcoder that mis-parses one
offset, swaps an endianness, or drops a field diverges on at least
one entry.

**Hash independence.**  The corpus carries the sign-input BYTES, not
their digest — `keccak256` is native on the L1 side and the digest is
a pure function of the bytes — so the fixture is byte-identical under
the FNV fallback and the keccak build, and both consumers run
unconditionally.

This module is non-TCB.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Bridge.CrossCheck.Framework

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.FaultProof
open LegalKernel.Test

namespace SigningInput

/-! ## Fixed fixture parameters -/

/-- The fixture's deployment id: 32 bytes of `0xDD` (the shape of a
    real genesis-state hash, value arbitrary but frozen). -/
def fixtureDeploymentId : ByteArray :=
  ByteArray.mk (Array.replicate 32 (0xDD : UInt8))

/-- `2^64 - 1`, the largest value an 8-byte CBE uint head represents. -/
def maxU64 : Nat := 18446744073709551615

/-! ## Entry builder -/

/-- Build one fixture entry from an `Action` and a `(signer, nonce,
    deploymentId)` triple.  Every derived column is computed by the
    LEAN reference functions, so the Solidity consumer's agreement is
    a genuine cross-stack differential. -/
def mkEntry (category : String) (a : Action) (signer nonce : Nat)
    (deploymentId : ByteArray := fixtureDeploymentId) : Json :=
  let fields := StepVMCoherence.actionFieldsForL1 a
  let cbe := ByteArray.mk (Encodable.encode (T := Action) a).toArray
  let input :=
    Authority.signingInput a (UInt64.ofNat signer) nonce deploymentId
  .obj
    [ ("category",        .str category)
    , ("kind",            .num (StepVMCoherence.actionKindByte a).toNat)
    , ("signer",          .num signer)
    , ("nonce",           .num nonce)
    , ("deploymentIdHex", .str (hexFromBytes deploymentId))
    , ("fieldsHex",       .str (hexFromBytes fields))
    , ("cbeActionHex",    .str (hexFromBytes cbe))
    , ("signingInputHex", .str (hexFromBytes input))
    ]

/-! ## Sample payloads for the opaque variants -/

/-- A minimal canonical `Dispute` (signatureInvalid claim on log
    index 0), mirroring the step-VM corpus's construction. -/
def sampleDispute : Disputes.Dispute :=
  { challenger := 7
  , claim := .signatureInvalid 0
  , evidence := ByteArray.empty
  , nonce := 3
  , sig := ByteArray.empty }

/-- A minimal canonical empty-quorum `Verdict`. -/
def sampleVerdict : Disputes.Verdict :=
  { disputeId := 0
  , outcome := .upheld
  , rationale := ByteArray.empty
  , signatures := [] }

/-- A 20-byte L1 recipient address (`0x0102…14`). -/
def sampleRecipientL1 : Bridge.EthAddress :=
  (Bridge.EthAddress.ofBytes
    (ByteArray.mk (Array.ofFn (n := 20) fun i => (i.val + 1).toUInt8))).getD
    Bridge.EthAddress.zero

/-- A compressed-key-shaped 33-byte registry payload. -/
def samplePk : ByteArray :=
  ByteArray.mk (#[0x02] ++ Array.replicate 32 (0xAB : UInt8))

/-! ## The corpus: every frozen constructor once, plus corners -/

/-- One canonical entry per frozen `Action` constructor (26), plus
    boundary rows: max-u64 identifiers and signer/nonce, a wide
    amount, an empty registry key, and the empty deployment id. -/
def entries : List Json :=
  [ mkEntry "transfer:canonical" (.transfer 1 7 8 30) 7 3
  , mkEntry "mint:canonical" (.mint 1 7 100) 0 0
  , mkEntry "burn:canonical" (.burn 1 7 5) 7 1
  , mkEntry "freezeResource:canonical" (.freezeResource 2) 4 9
  , mkEntry "replaceKey:canonical" (.replaceKey 7 (ByteArray.mk #[1, 2, 3])) 7 2
  , mkEntry "reward:canonical" (.reward 1 8 12) 4 5
  , mkEntry "distributeOthers:canonical" (.distributeOthers 1 7 9) 4 6
  , mkEntry "proportionalDilute:canonical" (.proportionalDilute 1 7 21) 4 7
  , mkEntry "dispute:canonical" (.dispute sampleDispute) 7 3
  , mkEntry "disputeWithdraw:canonical" (.disputeWithdraw 4) 7 4
  , mkEntry "verdict:canonical" (.verdict sampleVerdict) 2 8
  , mkEntry "rollback:canonical" (.rollback 2) 2 9
  , mkEntry "registerIdentity:canonical" (.registerIdentity 9 samplePk) 1 0
  , mkEntry "deposit:canonical" (.deposit 0 7 1000 42) 1 11
  , mkEntry "withdraw:canonical" (.withdraw 0 7 500 sampleRecipientL1) 7 12
  , mkEntry "declareLocalPolicy:canonical"
      (.declareLocalPolicy Authority.LocalPolicy.empty) 7 13
  , mkEntry "revokeLocalPolicy:canonical" .revokeLocalPolicy 7 14
  , mkEntry "faultProofChallenge:canonical"
      (.faultProofChallenge (ByteArray.mk #[0x51]) 0 1 (ByteArray.mk #[0x52])) 5 15
  , mkEntry "faultProofResolution:canonical"
      (.faultProofResolution (ByteArray.mk #[0x53]) 1 2 0) 5 16
  , mkEntry "depositWithFee:canonical" (.depositWithFee 0 1 2 1000 500 10 42 25) 1 17
  , mkEntry "topUpActionBudget:canonical" (.topUpActionBudget 0 100 5 2) 7 18
  , mkEntry "topUpActionBudgetFor:canonical"
      (.topUpActionBudgetFor 7 0 100 5 2) 8 19
  , mkEntry "claimBudgetRefund:canonical" (.claimBudgetRefund 0 50 5 2) 2 20
  -- Tag 23 (`ammSwap`) is RETIRED — no canonical signing vector.
  , mkEntry "reclaimAmmReserves:canonical" (.reclaimAmmReserves 0 777 3 2) 1 22
  , mkEntry "reserveSwap:canonical" (.reserveSwap 0 1 7 1000 900 3) 7 23
    -- Boundary rows.
  , mkEntry "transfer:max-u64-ids-wide-amount"
      (.transfer (UInt64.ofNat maxU64) (UInt64.ofNat maxU64)
        (UInt64.ofNat maxU64) (2 ^ 128 - 1)) maxU64 maxU64
  , mkEntry "registerIdentity:empty-key"
      (.registerIdentity 3 ByteArray.empty) 3 0
  , mkEntry "reserveSwap:max-amounts"
      (.reserveSwap 1 0 (UInt64.ofNat maxU64) (2 ^ 200) (2 ^ 199) 3)
      maxU64 1
  , mkEntry "transfer:empty-deployment-id" (.transfer 1 7 8 30) 7 3
      (deploymentId := ByteArray.empty)
  ]

/-- The fixture's JSON value: header + entries. -/
def buildFixture : Json :=
  let header : Json := .obj
    [ ("identifier", .str "knomosis-faultproof/signing-input/v1")
    , ("count",      .num entries.length)
    , ("domain",     .str Authority.signedActionDomain)
    , ("note",
        .str "signingInputHex is Lean Authority.signingInput over (action, signer, nonce, deploymentId); SignInput.sol must reproduce it from (kind, fieldsHex, signer, nonce, deploymentIdHex) alone")
    ]
  .obj [ ("header", header), ("entries", .arr entries) ]

/-- Fixture file name. -/
def fixtureName : String := "signing_input.json"

/-! ## Test cases -/

/-- The suite: entry count, per-kind coverage, structural
    consistency of every entry (the sign-input CONTAINS the CBE
    action, the domain prefix leads, the deployment id follows), and
    the fixture write. -/
def tests : List TestCase :=
  [ { name := "FA.1: signing_input fixture has 29 entries"
    , body := do
        if entries.length ≠ 29 then
          throw <| IO.userError s!"expected 29 entries, got {entries.length}"
    }
  , { name := "FA.1: every live frozen kind (0..25 minus the retired 23) appears"
    , body := do
        let kinds := entries.filterMap fun e =>
          match e with
          | .obj fields =>
            match fields.lookup "kind" with
            | some (.num k) => some k
            | _ => none
          | _ => none
        for k in (List.range 26).filter (· ≠ 23) do
          if ¬ kinds.contains k then
            throw <| IO.userError s!"kind {k} missing from the corpus"
        -- The RETIRED kind 23 must NOT appear: a signing vector for a
        -- constructor that no longer exists would be unverifiable.
        if kinds.contains 23 then
          throw <| IO.userError "retired kind 23 must not appear in the corpus"
    }
  , { name := "FA.1: every sign-input embeds domain ++ deploymentId ++ cbeAction"
    , body := do
        -- Structural self-consistency: signingInputHex must equal
        -- cbeBytes(domain) ++ cbeBytes(deploymentId) ++ cbeActionHex
        -- ++ cbeUint(signer) ++ cbeUint(nonce).  Recompose from the
        -- entry's own columns and compare — this pins the CONCAT
        -- structure the Solidity assembler mirrors, not just the
        -- opaque final bytes.
        for e in entries do
          match e with
          | .obj fields =>
            let getStr (k : String) : String :=
              match fields.lookup k with
              | some (.str s) => s
              | _ => ""
            let getNum (k : String) : Nat :=
              match fields.lookup k with
              | some (.num n) => n
              | _ => 0
            let depId := (bytesFromHex (getStr "deploymentIdHex")).getD ByteArray.empty
            let cbe := (bytesFromHex (getStr "cbeActionHex")).getD ByteArray.empty
            let recomposed :=
              ByteArray.mk
                (Encodable.encode (T := ByteArray)
                  Authority.signedActionDomainBytes).toArray ++
              ByteArray.mk (Encodable.encode (T := ByteArray) depId).toArray ++
              cbe ++
              ByteArray.mk (Encodable.encode (T := Nat) (getNum "signer")).toArray ++
              ByteArray.mk (Encodable.encode (T := Nat) (getNum "nonce")).toArray
            let expected :=
              (bytesFromHex (getStr "signingInputHex")).getD ByteArray.empty
            if recomposed ≠ expected then
              throw <| IO.userError
                s!"{getStr "category"}: recomposed sign-input ≠ Lean signingInput"
          | _ => throw <| IO.userError "entry is not a JSON object"
    }
  , { name := "FA.1: write signing_input.json fixture file"
    , body := Test.Bridge.CrossCheck.writeFixture fixtureName buildFixture.encodeIndented
    }
  ]

end SigningInput
end LegalKernel.Test.Bridge.CrossCheck
