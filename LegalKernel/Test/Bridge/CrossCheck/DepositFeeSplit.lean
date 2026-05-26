/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.DepositFeeSplit — Workstream GP.5.1.i.

Generates the `deposit_fee_split.json` cross-stack fixture verifying
byte-equivalence between the L1-side fee-split arithmetic + receiptHash
(produced by `KnomosisBridge.depositETHWithFee` /
`_registerDepositWithFee`) and a Lean reference computation.

**The fee-split recipe** (mirrors `KnomosisBridge.depositETHWithFee`):

```
poolAmount  = floor(msgValue * chosenFeeBps / 10000)
userAmount  = msgValue - poolAmount
rawBudget   = floor(poolAmount / weiPerBudgetUnit)
budgetGrant = min(rawBudget, MAX_BUDGET_PER_DEPOSIT)        -- 10^12
```

**The receiptHash recipe** (mirrors `_registerDepositWithFee`; the
deploymentId binding gives deployment-replay resistance, and the
8-field cover defeats replay-with-modified-fields per the unified-gas-
pool plan §22.7b):

```
deploymentId = keccak256(abi.encode(chainid, contractAddr, knomosisVersionTag))
receiptHash  = keccak256(abi.encode(
    deploymentId, sender, resourceId, token,
    userAmount, poolAmount, budgetGrant, depositorNonce))
```

The ABI preimage is 8 × 32 = 256 bytes.

**Coverage breakdown** (16 corner + 64 randomised = 80):

  * 16 hand-listed corners: zero fee, max fee, tiny-rounds-to-user,
    rate-one budget=pool, budget clamp, exact + above clamp boundary,
    residue-favours-user, rate-trillion, exact half, max nonce,
    realistic 10%-fee, min-fee, fee-just-below-max, single fee, misc.
  * 64 randomised: `(msgValue ∈ [1, 2^96], chosenFeeBps ∈ [0, 5000],
    weiPerBudgetUnit ∈ [1, 2^50], nonce ∈ [0, 2^32))`.

The `msgValue` bound keeps `msgValue * chosenFeeBps` far below
`uint256.max` so the Solidity consumer's recompute cannot overflow.
Every entry satisfies `userAmount + poolAmount = msgValue` and
`budgetGrant ≤ MAX_BUDGET_PER_DEPOSIT`.

Hash-binding-conditional behaviour: when `isKeccak256Linked = false`,
`expectedHash` is the FNV-1a-64 fallback (NOT keccak256), so the
Solidity per-entry hash cross-check is skipped (the arithmetic
cross-check runs unconditionally).

This module is non-TCB.  It reuses the ABI / deploymentId helpers from
the sibling `DepositReceiptHash` generator so the two fixtures share a
single source of truth for the encoding recipe.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Property
import LegalKernel.Test.Bridge.CrossCheck.Framework
import LegalKernel.Test.Bridge.CrossCheck.DepositReceiptHash

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Test
open LegalKernel.Test.Property

namespace DepositFeeSplit

/-! ## Fee-split reference arithmetic -/

/-- Per-deposit budget-grant ceiling.  MUST equal
    `KnomosisBridge.MAX_BUDGET_PER_DEPOSIT` and
    `FeeSplitMath.MAX_BUDGET_PER_DEPOSIT`; the fixture exposes it in the
    header so the Solidity consumer can assert the equality. -/
def maxBudgetPerDeposit : Nat := 1000000000000

/-- The fee-split reference: mirrors `KnomosisBridge.depositETHWithFee`.
    Returns `(userAmount, poolAmount, budgetGrant)`.

    `min rawBudget maxBudgetPerDeposit` reproduces the contract's
    `raw > MAX ? MAX : raw` clamp exactly (the strict `>` and `min`
    agree at the boundary `raw = MAX`). -/
def feeSplit (v feeBps weiPerBudgetUnit : Nat) : Nat × Nat × Nat :=
  let poolAmount := (v * feeBps) / 10000
  let userAmount := v - poolAmount
  let rawBudget := poolAmount / weiPerBudgetUnit
  let budgetGrant := min rawBudget maxBudgetPerDeposit
  (userAmount, poolAmount, budgetGrant)

/-! ## ReceiptHash recipe -/

/-- The fee-split receiptHash preimage (8 × 32 = 256 bytes).  Reuses
    the `DepositReceiptHash` ABI helpers so the encoding recipe is
    shared. -/
def feeSplitReceiptPreimage (deploymentId sender : ByteArray) (resourceId : Nat)
    (token : ByteArray) (userAmount poolAmount budgetGrant nonce : Nat) : ByteArray :=
  DepositReceiptHash.concatBytes
    [ deploymentId
    , DepositReceiptHash.encodeAddressLeftPadded sender
    , DepositReceiptHash.encodeUint256BE resourceId
    , DepositReceiptHash.encodeAddressLeftPadded token
    , DepositReceiptHash.encodeUint256BE userAmount
    , DepositReceiptHash.encodeUint256BE poolAmount
    , DepositReceiptHash.encodeUint256BE budgetGrant
    , DepositReceiptHash.encodeUint256BE nonce
    ]

/-- Compute the fee-split receiptHash. -/
def computeFeeSplitReceiptHash (deploymentId sender : ByteArray) (resourceId : Nat)
    (token : ByteArray) (userAmount poolAmount budgetGrant nonce : Nat) : ByteArray :=
  hashBytes
    (feeSplitReceiptPreimage deploymentId sender resourceId token
      userAmount poolAmount budgetGrant nonce)

/-! ## Fixture entry type -/

/-- One cross-stack fee-split entry. -/
structure Entry where
  /-- Human-readable category tag. -/
  category           : String
  /-- The deploymentId preimage's chainid. -/
  chainid            : Nat
  /-- 20-byte bridge contract address. -/
  contractAddr       : ByteArray
  /-- 32-byte knomosis version tag. -/
  knomosisVersionTag : ByteArray
  /-- The derived `deploymentId` (32 bytes). -/
  deploymentId       : ByteArray
  /-- 20-byte depositor address (`msg.sender`). -/
  sender             : ByteArray
  /-- uint64 resourceId (always 0 = native ETH on this path). -/
  resourceId         : Nat
  /-- 20-byte token (zero address for native ETH). -/
  token              : ByteArray
  /-- uint256 `msg.value`. -/
  msgValue           : Nat
  /-- The user-chosen fee in basis points. -/
  chosenFeeBps       : Nat
  /-- The deployment's ETH-leg exchange rate. -/
  weiPerBudgetUnit   : Nat
  /-- uint64 per-depositor nonce. -/
  depositorNonce     : Nat
  /-- Derived user-facing credit. -/
  userAmount         : Nat
  /-- Derived pool credit. -/
  poolAmount         : Nat
  /-- Derived action-budget grant. -/
  budgetGrant        : Nat
  /-- 32-byte expected receipt hash. -/
  expectedHash       : ByteArray

/-- Build an `Entry`, computing the split, deploymentId, and hash. -/
def mkEntry (chainid : Nat) (contractAddr knomosisVersionTag sender : ByteArray)
    (msgValue chosenFeeBps weiPerBudgetUnit nonce : Nat) (category : String) : Entry :=
  let did := DepositReceiptHash.computeDeploymentId chainid contractAddr knomosisVersionTag
  let split := feeSplit msgValue chosenFeeBps weiPerBudgetUnit
  let userAmount := split.1
  let poolAmount := split.2.1
  let budgetGrant := split.2.2
  let hash := computeFeeSplitReceiptHash did sender 0 DepositReceiptHash.zeroAddr20
                userAmount poolAmount budgetGrant nonce
  { category := category
  , chainid := chainid
  , contractAddr := contractAddr
  , knomosisVersionTag := knomosisVersionTag
  , deploymentId := did
  , sender := sender
  , resourceId := 0
  , token := DepositReceiptHash.zeroAddr20
  , msgValue := msgValue
  , chosenFeeBps := chosenFeeBps
  , weiPerBudgetUnit := weiPerBudgetUnit
  , depositorNonce := nonce
  , userAmount := userAmount
  , poolAmount := poolAmount
  , budgetGrant := budgetGrant
  , expectedHash := hash
  }

/-! ## Corner entries -/

/-- 16 hand-listed corner cases over a fixed `(contractAddr, knomosisTag,
    sender)` base so the cases vary only in the fee-split inputs. -/
def cornerEntries : Gen (List Entry) := fun st0 =>
  let (contractAddr, s1) := DepositReceiptHash.genBytes 20 st0
  let (knomosisTag,   s2) := DepositReceiptHash.genBytes 32 s1
  let (sender,        s3) := DepositReceiptHash.genBytes 20 s2
  let c := 1   -- mainnet-equivalent chainid
  let max64 : Nat := 2 ^ 64 - 1
  let entries : List Entry :=
    [ mkEntry c contractAddr knomosisTag sender (10 ^ 18)            0    (10 ^ 9)  0     "corner:zero-fee"
    , mkEntry c contractAddr knomosisTag sender (10 ^ 18)            5000 (10 ^ 9)  0     "corner:max-fee"
    , mkEntry c contractAddr knomosisTag sender 1                    100  1         0     "corner:tiny-rounds-to-user"
    , mkEntry c contractAddr knomosisTag sender 10000                100  1         0     "corner:rate-one-budget-eq-pool"
    , mkEntry c contractAddr knomosisTag sender (10 ^ 19)            5000 1         0     "corner:budget-clamp"
    , mkEntry c contractAddr knomosisTag sender (2 * 10 ^ 12)        5000 1         0     "corner:budget-boundary-exact"
    , mkEntry c contractAddr knomosisTag sender (2 * 10 ^ 12 + 20000) 5000 1        0     "corner:budget-boundary-above"
    , mkEntry c contractAddr knomosisTag sender 12345                333  1         0     "corner:residue-favours-user"
    , mkEntry c contractAddr knomosisTag sender (6 * 10 ^ 12)        5000 (10 ^ 12) 0     "corner:rate-trillion"
    , mkEntry c contractAddr knomosisTag sender 100                  5000 1         0     "corner:exact-half"
    , mkEntry c contractAddr knomosisTag sender 1000                 100  1         max64 "corner:max-nonce"
    , mkEntry c contractAddr knomosisTag sender (5 * 10 ^ 18)        1000 (10 ^ 9)  0     "corner:realistic-ten-percent"
    , mkEntry c contractAddr knomosisTag sender 1000000              50   1         0     "corner:min-fee-small"
    , mkEntry c contractAddr knomosisTag sender 1000000              4999 1         0     "corner:fee-just-below-max"
    , mkEntry c contractAddr knomosisTag sender 1000000              250  1         0     "corner:single-fee"
    , mkEntry c contractAddr knomosisTag sender 999999999            4321 (10 ^ 6)  7     "corner:misc"
    ]
  (entries, s3)

/-! ## Randomised entries -/

/-- Generate a `msg.value` in `[1, 2^96]` via three 32-bit draws. -/
def genWei : Gen Nat := fun st0 =>
  let (a, s1) := genNat (2 ^ 32) st0
  let (b, s2) := genNat (2 ^ 32) s1
  let (cc, s3) := genNat (2 ^ 32) s2
  (a * (2 ^ 64) + b * (2 ^ 32) + cc + 1, s3)

/-- Generate a fee in `[0, 5000]` (the admissible range under
    `MAX_FEE_BPS_CAP`). -/
def genFeeBps : Gen Nat := genNat 5001

/-- Generate an exchange rate in `[1, 2^50]`, covering the realistic
    operator band `[10^9, 10^15]` and beyond. -/
def genRate : Gen Nat := fun st0 =>
  let (hi, s1) := genNat (2 ^ 18) st0
  let (lo, s2) := genNat (2 ^ 32) s1
  (hi * (2 ^ 32) + lo + 1, s2)

/-- Generate one randomised entry. -/
def genRandomEntry (idx : Nat) : Gen Entry := fun st0 =>
  let (contractAddr, s1) := DepositReceiptHash.genBytes 20 st0
  let (knomosisTag,   s2) := DepositReceiptHash.genBytes 32 s1
  let (sender,        s3) := DepositReceiptHash.genBytes 20 s2
  let (chainid,       s4) := genNat (2 ^ 32) s3
  let (msgValue,      s5) := genWei s4
  let (feeBps,        s6) := genFeeBps s5
  let (rate,          s7) := genRate s6
  let (nonce,         s8) := genNat (2 ^ 32) s7
  let e := mkEntry (chainid + 1) contractAddr knomosisTag sender
              msgValue feeBps rate nonce s!"random:{idx}"
  (e, s8)

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
    , ("maxBudgetPerDeposit", .num maxBudgetPerDeposit)
    , ("maxFeeBpsCap",        .num 5000)
    , ("minWeiPerBudgetUnit", .num 1)
    , ("projection",
        .str "keccak256(abi.encode(deploymentId,sender,resourceId,token,userAmount,poolAmount,budgetGrant,depositorNonce))")
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
        , ("depositorNonce",     .num e.depositorNonce)
        , ("userAmount",         .str (hexFromUint256BE e.userAmount))
        , ("poolAmount",         .str (hexFromUint256BE e.poolAmount))
        , ("budgetGrant",        .num e.budgetGrant)
        , ("expectedHash",       .str (hexFromBytes e.expectedHash))
        ])))
    ]
  (topLevel, allEntries.length)

/-- Fixture file name. -/
def fixtureName : String := "deposit_fee_split.json"

/-! ## Test cases -/

/-- The test cases: count, determinism, byte sizes, conservation,
    budget bound, reference anchors, hash self-consistency, clamp
    corners, preimage size, file write, and the conditional
    cross-check skip. -/
def tests : List TestCase :=
  [ { name := "GP.5.1: deposit_fee_split fixture has 80 entries"
    , body := do
        let seed ← readSeed
        let (_, n) := buildFixture seed
        if n ≠ 80 then
          throw <| IO.userError s!"expected 80 entries, got {n}"
    }
  , { name := "GP.5.1: fixture is byte-deterministic across runs"
    , body := do
        let seed ← readSeed
        let (j₁, _) := buildFixture seed
        let (j₂, _) := buildFixture seed
        if j₁.encode ≠ j₂.encode then
          throw <| IO.userError "non-deterministic"
    }
  , { name := "GP.5.1: every entry has 20-byte addresses + 32-byte tag / id / hash"
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
          if e.token.size ≠ 20 then
            throw <| IO.userError s!"token size {e.token.size} in {e.category}"
          if e.deploymentId.size ≠ 32 then
            throw <| IO.userError s!"deploymentId size {e.deploymentId.size} in {e.category}"
          if e.expectedHash.size ≠ 32 then
            throw <| IO.userError s!"expectedHash size {e.expectedHash.size} in {e.category}"
    }
  , { name := "GP.5.1: every entry conserves msg.value (userAmount + poolAmount = msgValue)"
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
  , { name := "GP.5.1: every entry's budgetGrant is within MAX_BUDGET_PER_DEPOSIT"
    , body := do
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          if e.budgetGrant > maxBudgetPerDeposit then
            throw <| IO.userError <|
              s!"budgetGrant {e.budgetGrant} exceeds cap in {e.category}"
    }
  , { name := "GP.5.1: feeSplit reference matches hand-computed corners"
    , body := do
        -- Anchor the reference arithmetic to ground truth so the
        -- cross-stack equivalence is not circular.
        if feeSplit 10000 100 1 ≠ (9900, 100, 100) then
          throw <| IO.userError "feeSplit 10000 100 1 mismatch"
        if feeSplit 1 100 1 ≠ (1, 0, 0) then
          throw <| IO.userError "feeSplit 1 100 1 mismatch (tiny rounds to user)"
        if feeSplit 12345 333 1 ≠ (11934, 411, 411) then
          throw <| IO.userError "feeSplit 12345 333 1 mismatch (residue)"
        if feeSplit 100 5000 1 ≠ (50, 50, 50) then
          throw <| IO.userError "feeSplit 100 5000 1 mismatch (exact half)"
        -- Clamp: rawBudget far exceeds the cap → budget = cap.
        if (feeSplit (10 ^ 19) 5000 1).2.2 ≠ maxBudgetPerDeposit then
          throw <| IO.userError "feeSplit clamp mismatch"
        -- Boundary: rawBudget == cap → budget = cap (not clamped, equal).
        if (feeSplit (2 * 10 ^ 12) 5000 1).2.2 ≠ maxBudgetPerDeposit then
          throw <| IO.userError "feeSplit boundary mismatch"
        -- Rate trillion: 3e12 / 1e12 = 3.
        if (feeSplit (6 * 10 ^ 12) 5000 (10 ^ 12)).2.2 ≠ 3 then
          throw <| IO.userError "feeSplit rate-trillion mismatch"
    }
  , { name := "GP.5.1: feeSplitReceiptPreimage is exactly 256 bytes"
    , body := do
        let did := DepositReceiptHash.encodeUint256BE 0   -- 32 bytes
        let preimage :=
          feeSplitReceiptPreimage did DepositReceiptHash.zeroAddr20 0
            DepositReceiptHash.zeroAddr20 0 0 0 0
        if preimage.size ≠ 256 then
          throw <| IO.userError s!"feeSplitReceiptPreimage size {preimage.size}, expected 256"
    }
  , { name := "GP.5.1: receiptHash recipe self-consistency (any binding)"
    , body := do
        -- Recompute deploymentId + hash from each entry's recorded
        -- fields and assert they match the stored values.  Holds under
        -- both FNV fallback and production keccak256.
        let seed ← readSeed
        let (corners, _) := cornerEntries ⟨seed⟩
        for e in corners do
          let didR :=
            DepositReceiptHash.computeDeploymentId e.chainid e.contractAddr e.knomosisVersionTag
          if didR ≠ e.deploymentId then
            throw <| IO.userError s!"deploymentId drift in {e.category}"
          let hashR :=
            computeFeeSplitReceiptHash e.deploymentId e.sender e.resourceId e.token
              e.userAmount e.poolAmount e.budgetGrant e.depositorNonce
          if hashR ≠ e.expectedHash then
            throw <| IO.userError s!"receiptHash drift in {e.category}"
    }
  , { name := "GP.5.1: budget-clamp corners produce exactly MAX_BUDGET_PER_DEPOSIT"
    , body := do
        let seed ← readSeed
        let (corners, _) := cornerEntries ⟨seed⟩
        for e in corners do
          if e.category = "corner:budget-clamp"
             ∨ e.category = "corner:budget-boundary-exact"
             ∨ e.category = "corner:budget-boundary-above" then
            if e.budgetGrant ≠ maxBudgetPerDeposit then
              throw <| IO.userError <|
                s!"{e.category} budgetGrant {e.budgetGrant} ≠ {maxBudgetPerDeposit}"
    }
  , { name := "GP.5.1: fixture file write / verify cycle succeeds"
    , body := do
        let seed ← readSeed
        let (json, _) := buildFixture seed
        writeFixture fixtureName json.encode
    }
  , { name := "GP.5.1: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        if !isKeccak256Linked then
          skipWithReason s!"keccak256 fallback; cross-stack assert skipped"
    }
  ]

end DepositFeeSplit
end LegalKernel.Test.Bridge.CrossCheck
