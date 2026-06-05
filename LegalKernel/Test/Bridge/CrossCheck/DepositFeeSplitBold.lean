-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.DepositFeeSplitBold — Workstream
GP.5.4.e.

Generates the `deposit_fee_split_bold.json` cross-stack fixture verifying
byte-equivalence between the L1-side BOLD fee-split arithmetic +
receiptHash (produced by `KnomosisBridge.depositBoldWithFee` /
`_registerDepositWithFee`) and a Lean reference computation.

**The BOLD path is the byte-identical sibling of the ETH path
(GP.5.1).**  The fee-split arithmetic (`DepositFeeSplit.feeSplit`) and
the receiptHash recipe (`DepositFeeSplit.computeFeeSplitReceiptHash`,
which is resource-generic) are reused verbatim; the ONLY differences
are the two receiptHash inputs the BOLD entry point pins:

  * `resourceId = RESOURCE_ID_BOLD = 1`  (vs `0` for native ETH), and
  * `token      = BOLD_TOKEN_ADDRESS`    (vs the zero address).

So this fixture's distinct cross-stack obligation is exactly that Lean
and Solidity agree on the receiptHash (and its hash-independent preimage
tail) when those two fields take their BOLD values.  The split + budget
clamp are shared with the ETH fixture, and the spec-level guarantees
(`DepositFeeSplit.feeSplit_conserves` / `_pool_le` / `_budget_le_max`)
carry over unchanged.

**Coverage breakdown** (16 corner + 64 randomised = 80), mirroring
`DepositFeeSplit` so the two corpora line up index-for-index on the
shared `(msgValue, chosenFeeBps, weiPerBudgetUnit)` inputs.

Hash-binding-conditional behaviour matches the ETH fixture: when
`isKeccak256Linked = false`, `expectedHash` is the FNV-1a-64 fallback,
so the Solidity per-entry full-hash cross-check is skipped (the
arithmetic + the hash-independent receiptTail layout check run
unconditionally).

This module is non-TCB.  It reuses every arithmetic / ABI / deploymentId
helper from the sibling `DepositFeeSplit` + `DepositReceiptHash`
generators, so there is a single source of truth for the recipe across
the ETH and BOLD corpora.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Property
import LegalKernel.Test.Bridge.CrossCheck.Framework
import LegalKernel.Test.Bridge.CrossCheck.DepositReceiptHash
import LegalKernel.Test.Bridge.CrossCheck.DepositFeeSplit

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Test
open LegalKernel.Test.Property

namespace DepositFeeSplitBold

/-! ## BOLD constitutional constants (mirror `KnomosisBridge`) -/

/-- `KnomosisBridge.RESOURCE_ID_BOLD`. -/
def resourceIdBold : Nat := 1

/-- The 20-byte canonical Liquity V2 BOLD token address
    (`KnomosisBridge.BOLD_TOKEN_ADDRESS`,
    `0x6440f144b7e50D6a8439336510312d2F54beB01D`).  The byte values are
    case-independent; the contract's mixed-case literal is only the
    EIP-55 checksum form of these same 20 bytes. -/
def boldTokenAddr20 : ByteArray :=
  ByteArray.mk #[
    0x64, 0x40, 0xf1, 0x44, 0xb7, 0xe5, 0x0d, 0x6a, 0x84, 0x39,
    0x33, 0x65, 0x10, 0x31, 0x2d, 0x2f, 0x54, 0xbe, 0xb0, 0x1d]

/-- Lowercase `0x`-prefixed hex form of `boldTokenAddr20`, exposed in the
    fixture header so the Solidity consumer can pin the token address. -/
def boldTokenAddrHex : String := hexFromBytes boldTokenAddr20

/-! ## Fixture entry construction

Reuses `DepositFeeSplit.Entry` (which already carries `resourceId` /
`token` fields) and the shared `feeSplit` / receiptHash helpers, fixing
`resourceId = 1` and `token = BOLD_TOKEN_ADDRESS`. -/

/-- Build a BOLD `Entry`: the `DepositFeeSplit` recipe with
    `resourceId = resourceIdBold` and `token = boldTokenAddr20`. -/
def mkEntry (chainid : Nat) (contractAddr knomosisVersionTag sender : ByteArray)
    (msgValue chosenFeeBps weiPerBudgetUnit seedRatio nonce : Nat) (category : String) :
    DepositFeeSplit.Entry :=
  let did := DepositReceiptHash.computeDeploymentId chainid contractAddr knomosisVersionTag
  let split := DepositFeeSplit.feeSplit msgValue chosenFeeBps weiPerBudgetUnit
  let userAmount := split.1
  let poolAmount := split.2.1
  let budgetGrant := split.2.2
  let ammSeedAmount := DepositFeeSplit.ammSeed poolAmount seedRatio
  let hash := DepositFeeSplit.computeFeeSplitReceiptHash did sender resourceIdBold
                boldTokenAddr20 userAmount poolAmount ammSeedAmount budgetGrant nonce
  let tail := DepositFeeSplit.feeSplitReceiptTail sender resourceIdBold
                boldTokenAddr20 userAmount poolAmount ammSeedAmount budgetGrant nonce
  { category := category
  , chainid := chainid
  , contractAddr := contractAddr
  , knomosisVersionTag := knomosisVersionTag
  , deploymentId := did
  , sender := sender
  , resourceId := resourceIdBold
  , token := boldTokenAddr20
  , msgValue := msgValue
  , chosenFeeBps := chosenFeeBps
  , weiPerBudgetUnit := weiPerBudgetUnit
  , ammSeedRatioBps := seedRatio
  , depositorNonce := nonce
  , userAmount := userAmount
  , poolAmount := poolAmount
  , ammSeedAmount := ammSeedAmount
  , budgetGrant := budgetGrant
  , expectedHash := hash
  , receiptTail := tail
  }

/-! ## Corner entries

The same 16 `(msgValue, chosenFeeBps, weiPerBudgetUnit, nonce)` tuples as
the ETH corpus (so the two line up), with one BOLD-flavoured rate swap on
the "realistic" corner to exercise the calibrated `3 × 10¹⁵` BOLD rate. -/

/-- 16 hand-listed corner cases over a fixed `(contractAddr, knomosisTag,
    sender)` base so the cases vary only in the fee-split inputs. -/
def cornerEntries : Gen (List DepositFeeSplit.Entry) := fun st0 =>
  let (contractAddr, s1) := DepositReceiptHash.genBytes 20 st0
  let (knomosisTag,   s2) := DepositReceiptHash.genBytes 32 s1
  let (sender,        s3) := DepositReceiptHash.genBytes 20 s2
  let c := 1   -- mainnet-equivalent chainid
  let max64 : Nat := 2 ^ 64 - 1
  let entries : List DepositFeeSplit.Entry :=
    [ mkEntry c contractAddr knomosisTag sender (10 ^ 18)            0    (10 ^ 9)  0 0     "corner:zero-fee"
    , mkEntry c contractAddr knomosisTag sender (10 ^ 18)            5000 (10 ^ 9)  0 0     "corner:max-fee"
    , mkEntry c contractAddr knomosisTag sender 1                    100  1         0 0     "corner:tiny-rounds-to-user"
    , mkEntry c contractAddr knomosisTag sender 10000                100  1         0 0     "corner:rate-one-budget-eq-pool"
    , mkEntry c contractAddr knomosisTag sender (10 ^ 19)            5000 1         0 0     "corner:budget-clamp"
    , mkEntry c contractAddr knomosisTag sender (2 * 10 ^ 12)        5000 1         0 0     "corner:budget-boundary-exact"
    , mkEntry c contractAddr knomosisTag sender (2 * 10 ^ 12 + 20000) 5000 1        0 0     "corner:budget-boundary-above"
    , mkEntry c contractAddr knomosisTag sender 12345                333  1         0 0     "corner:residue-favours-user"
    , mkEntry c contractAddr knomosisTag sender (6 * 10 ^ 12)        5000 (10 ^ 12) 0 0     "corner:rate-trillion"
    , mkEntry c contractAddr knomosisTag sender 100                  5000 1         0 0     "corner:exact-half"
    , mkEntry c contractAddr knomosisTag sender 1000                 100  1         0 max64 "corner:max-nonce"
    , mkEntry c contractAddr knomosisTag sender (10 ^ 21)            1000 (3 * 10 ^ 15) 0 0 "corner:bold-realistic-calibration"
    , mkEntry c contractAddr knomosisTag sender 1000000              50   1         0 0     "corner:min-fee-small"
    , mkEntry c contractAddr knomosisTag sender 1000000              4999 1         0 0     "corner:fee-just-below-max"
    , mkEntry c contractAddr knomosisTag sender 1000000              250  1         0 0     "corner:single-fee"
    , mkEntry c contractAddr knomosisTag sender 999999999            4321 (10 ^ 6)  0 7     "corner:misc"
    ]
  (entries, s3)

/-! ## Randomised entries -/

/-- Generate one randomised entry (reuses the ETH corpus's input
    generators so the two corpora draw from the same distribution). -/
def genRandomEntry (idx : Nat) : Gen DepositFeeSplit.Entry := fun st0 =>
  let (contractAddr, s1) := DepositReceiptHash.genBytes 20 st0
  let (knomosisTag,   s2) := DepositReceiptHash.genBytes 32 s1
  let (sender,        s3) := DepositReceiptHash.genBytes 20 s2
  let (chainid,       s4) := genNat (2 ^ 32) s3
  let (msgValue,      s5) := DepositFeeSplit.genWei s4
  let (feeBps,        s6) := DepositFeeSplit.genFeeBps s5
  let (rate,          s7) := DepositFeeSplit.genRate s6
  let (seedRatio,     s8) := DepositFeeSplit.genSeedRatio s7
  let (nonce,         s9) := genNat (2 ^ 32) s8
  let e := mkEntry (chainid + 1) contractAddr knomosisTag sender
              msgValue feeBps rate seedRatio nonce s!"random:{idx}"
  (e, s9)

/-! ## Top-level fixture -/

/-- Build the full fixture: 16 corners + 64 randomised = 80 entries. -/
def buildFixture (seed : UInt64) : (Json × Nat) :=
  let (corners,    s1) := cornerEntries ⟨seed⟩
  let (randomised, _ ) := DepositReceiptHash.genN genRandomEntry 64 s1
  let allEntries := corners ++ randomised
  let header : Json := .obj
    [ ("seed",                .num seed.toNat)
    , ("isKeccak256Linked",   .bool isKeccak256Linked)
    , ("hashIdentifier",      .str (hashImplementationIdentifier ()))
    , ("count",               .num allEntries.length)
    , ("countCorner",         .num 16)
    , ("countRandomised",     .num 64)
    , ("maxBudgetPerDeposit", .num DepositFeeSplit.maxBudgetPerDeposit)
    , ("maxFeeBpsCap",        .num 5000)
    , ("minWeiPerBudgetUnit", .num 1)
    , ("maxAmmSeedRatioBps",  .num 8000)
    , ("resourceIdBold",      .num resourceIdBold)
    , ("boldTokenAddress",    .str boldTokenAddrHex)
    , ("projection",
        .str "keccak256(abi.encode(deploymentId,sender,resourceId,token,userAmount,poolAmount,ammSeedAmount,budgetGrant,depositorNonce))")
    ]
  let topLevel : Json := .obj
    [ ("header", header)
    , ("entries", .arr (allEntries.map (fun e => .obj
        [ ("category",           .str e.category)
        , ("chainid",            .num e.chainid)
        , ("contractAddr",       .str (hexFromBytes e.contractAddr))
        , ("knomosisVersionTag", .str (hexFromBytes e.knomosisVersionTag))
        , ("deploymentId",       .str (hexFromBytes e.deploymentId))
        , ("sender",             .str (hexFromBytes e.sender))
        , ("resourceId",         .num e.resourceId)
        , ("token",              .str (hexFromBytes e.token))
        , ("msgValue",           .str (hexFromUint256BE e.msgValue))
        , ("chosenFeeBps",       .num e.chosenFeeBps)
        , ("weiPerBudgetUnit",   .num e.weiPerBudgetUnit)
        , ("ammSeedRatioBps",    .num e.ammSeedRatioBps)
        , ("depositorNonce",     .num e.depositorNonce)
        , ("userAmount",         .str (hexFromUint256BE e.userAmount))
        , ("poolAmount",         .str (hexFromUint256BE e.poolAmount))
        , ("ammSeedAmount",      .str (hexFromUint256BE e.ammSeedAmount))
        , ("budgetGrant",        .num e.budgetGrant)
        , ("expectedHash",       .str (hexFromBytes e.expectedHash))
        , ("receiptTail",        .str (hexFromBytes e.receiptTail))
        ])))
    ]
  (topLevel, allEntries.length)

/-- Fixture file name. -/
def fixtureName : String := "deposit_fee_split_bold.json"

/-! ## Test cases -/

/-- The test cases: count, determinism, byte sizes, BOLD-field
    invariants (resourceId = 1, token = BOLD), conservation, budget bound,
    hash self-consistency, ETH/BOLD split parity, file write, and the
    conditional cross-check skip. -/
def tests : List TestCase :=
  [ { name := "GP.5.4: deposit_fee_split_bold fixture has 80 entries"
    , body := do
        let seed ← readSeed
        let (_, n) := buildFixture seed
        if n ≠ 80 then
          throw <| IO.userError s!"expected 80 entries, got {n}"
    }
  , { name := "GP.5.4: BOLD fixture is byte-deterministic across runs"
    , body := do
        let seed ← readSeed
        let (j₁, _) := buildFixture seed
        let (j₂, _) := buildFixture seed
        if j₁.encode ≠ j₂.encode then
          throw <| IO.userError "non-deterministic"
    }
  , { name := "GP.5.4: BOLD token address constant is exactly 20 bytes"
    , body := do
        if boldTokenAddr20.size ≠ 20 then
          throw <| IO.userError s!"boldTokenAddr20 size {boldTokenAddr20.size}, expected 20"
        if boldTokenAddrHex ≠ "0x6440f144b7e50d6a8439336510312d2f54beb01d" then
          throw <| IO.userError s!"boldTokenAddrHex mismatch: {boldTokenAddrHex}"
    }
  , { name := "GP.5.4: every BOLD entry has resourceId = 1 and token = BOLD"
    , body := do
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          if e.resourceId ≠ resourceIdBold then
            throw <| IO.userError s!"resourceId {e.resourceId} ≠ 1 in {e.category}"
          if e.token ≠ boldTokenAddr20 then
            throw <| IO.userError s!"token ≠ BOLD address in {e.category}"
          if e.token.size ≠ 20 then
            throw <| IO.userError s!"token size {e.token.size} in {e.category}"
    }
  , { name := "GP.5.4: every BOLD entry has 20-byte addresses + 32-byte tag / id / hash"
    , body := do
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          if e.contractAddr.size ≠ 20 then
            throw <| IO.userError s!"contractAddr size {e.contractAddr.size} in {e.category}"
          if e.knomosisVersionTag.size ≠ 32 then
            throw <| IO.userError s!"knomosisVersionTag size {e.knomosisVersionTag.size} in {e.category}"
          if e.sender.size ≠ 20 then
            throw <| IO.userError s!"sender size {e.sender.size} in {e.category}"
          if e.deploymentId.size ≠ 32 then
            throw <| IO.userError s!"deploymentId size {e.deploymentId.size} in {e.category}"
          if e.expectedHash.size ≠ 32 then
            throw <| IO.userError s!"expectedHash size {e.expectedHash.size} in {e.category}"
    }
  , { name := "GP.5.4: every BOLD entry conserves msg.value (userAmount + poolAmount = msgValue)"
    , body := do
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          if e.userAmount + e.poolAmount ≠ e.msgValue then
            throw <| IO.userError <|
              s!"conservation violated in {e.category}: " ++
              s!"{e.userAmount} + {e.poolAmount} ≠ {e.msgValue}"
    }
  , { name := "GP.5.4: every BOLD entry's budgetGrant is within MAX_BUDGET_PER_DEPOSIT"
    , body := do
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          if e.budgetGrant > DepositFeeSplit.maxBudgetPerDeposit then
            throw <| IO.userError <|
              s!"budgetGrant {e.budgetGrant} exceeds cap in {e.category}"
    }
  , { name := "GP.5.4: BOLD split equals the shared ETH-leg feeSplit reference"
    , body := do
        -- The BOLD split is the SAME arithmetic as the ETH leg; pin that
        -- each entry's stored (userAmount, poolAmount, budgetGrant) equals
        -- the shared `DepositFeeSplit.feeSplit` on the same inputs.
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          let split := DepositFeeSplit.feeSplit e.msgValue e.chosenFeeBps e.weiPerBudgetUnit
          if (e.userAmount, e.poolAmount, e.budgetGrant) ≠ split then
            throw <| IO.userError s!"BOLD split ≠ shared feeSplit reference in {e.category}"
    }
  , { name := "GP.5.4: every BOLD entry's receiptTail is exactly 256 bytes (suffix of preimage, GP.11.2)"
    , body := do
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          if e.receiptTail.size ≠ 256 then
            throw <| IO.userError s!"receiptTail size {e.receiptTail.size} in {e.category}, expected 256"
          if e.deploymentId.append e.receiptTail ≠
             DepositFeeSplit.feeSplitReceiptPreimage e.deploymentId e.sender e.resourceId e.token
               e.userAmount e.poolAmount e.ammSeedAmount e.budgetGrant e.depositorNonce then
            throw <| IO.userError s!"receiptTail not the preimage suffix in {e.category}"
    }
  , { name := "GP.11.2: every BOLD entry's ammSeedAmount conserves the pool fee"
    , body := do
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          if e.ammSeedRatioBps > 8000 then
            throw <| IO.userError s!"ammSeedRatioBps {e.ammSeedRatioBps} out of range in {e.category}"
          if e.ammSeedAmount ≠ DepositFeeSplit.ammSeed e.poolAmount e.ammSeedRatioBps then
            throw <| IO.userError s!"ammSeedAmount recompute mismatch in {e.category}"
          if e.ammSeedAmount > e.poolAmount then
            throw <| IO.userError s!"ammSeedAmount {e.ammSeedAmount} exceeds pool fee in {e.category}"
    }
  , { name := "GP.5.4: receiptHash recipe self-consistency (any binding)"
    , body := do
        let seed ← readSeed
        let (corners, _) := cornerEntries ⟨seed⟩
        for e in corners do
          let didR :=
            DepositReceiptHash.computeDeploymentId e.chainid e.contractAddr e.knomosisVersionTag
          if didR ≠ e.deploymentId then
            throw <| IO.userError s!"deploymentId drift in {e.category}"
          let hashR :=
            DepositFeeSplit.computeFeeSplitReceiptHash e.deploymentId e.sender e.resourceId e.token
              e.userAmount e.poolAmount e.ammSeedAmount e.budgetGrant e.depositorNonce
          if hashR ≠ e.expectedHash then
            throw <| IO.userError s!"receiptHash drift in {e.category}"
    }
  , { name := "GP.5.4: BOLD receiptHash differs from the ETH receiptHash on the same split"
    , body := do
        -- The BOLD entry binds resourceId = 1 + token = BOLD; an ETH
        -- receipt over the identical (deploymentId, sender, amounts,
        -- nonce) binds resourceId = 0 + token = 0x0.  Under any binding
        -- those two preimages differ, so the hashes must differ — pinning
        -- that the resourceId / token fields actually feed the hash.
        let seed ← readSeed
        let (corners, _) := cornerEntries ⟨seed⟩
        for e in corners do
          let ethHash :=
            DepositFeeSplit.computeFeeSplitReceiptHash e.deploymentId e.sender 0
              DepositReceiptHash.zeroAddr20 e.userAmount e.poolAmount e.ammSeedAmount
              e.budgetGrant e.depositorNonce
          if ethHash = e.expectedHash then
            throw <| IO.userError <|
              s!"BOLD receiptHash collides with the ETH receiptHash in {e.category}"
    }
  , { name := "GP.5.4: budget-clamp corners produce exactly MAX_BUDGET_PER_DEPOSIT"
    , body := do
        let seed ← readSeed
        let (corners, _) := cornerEntries ⟨seed⟩
        for e in corners do
          if e.category = "corner:budget-clamp"
             ∨ e.category = "corner:budget-boundary-exact"
             ∨ e.category = "corner:budget-boundary-above" then
            if e.budgetGrant ≠ DepositFeeSplit.maxBudgetPerDeposit then
              throw <| IO.userError <|
                s!"{e.category} budgetGrant {e.budgetGrant} ≠ {DepositFeeSplit.maxBudgetPerDeposit}"
    }
  , { name := "GP.5.4: bold fixture file write / verify cycle succeeds"
    , body := do
        let seed ← readSeed
        let (json, _) := buildFixture seed
        writeFixture fixtureName json.encode
    }
  , { name := "GP.5.4: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        if !isKeccak256Linked then
          skipWithReason s!"keccak256 fallback; cross-stack assert skipped"
    }
  ]

end DepositFeeSplitBold
end LegalKernel.Test.Bridge.CrossCheck
