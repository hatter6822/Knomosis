-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
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
9-field cover defeats replay-with-modified-fields per the unified-gas-
pool plan §22.7b).  Workstream GP.11.2 inserted `ammSeedAmount` after
`poolAmount` so the free-pool / AMM split is bound (a replay with a
tampered split is rejected); `ammSeedAmount = 0` on an AMM-disabled
deployment:

```
deploymentId = keccak256(abi.encode(chainid, contractAddr, knomosisVersionTag))
receiptHash  = keccak256(abi.encode(
    deploymentId, sender, resourceId, token,
    userAmount, poolAmount, ammSeedAmount, budgetGrant, depositorNonce))
```

The ABI preimage is 9 × 32 = 288 bytes.

**Coverage breakdown** (22 corner + 64 randomised @ random
`ammSeedRatioBps ∈ [0, 8000]` = 86):

  * 16 fee-split corners @ ratio 0: zero fee, max fee, tiny-rounds-to-user,
    rate-one budget=pool, budget clamp, exact + above clamp boundary,
    residue-favours-user, rate-trillion, exact half, max nonce,
    realistic 10%-fee, min-fee, fee-just-below-max, single fee, misc.
  * 6 AMM-enabled corners (`ammcorner:*`) intersecting fee boundaries with a
    NON-ZERO seed ratio: max-fee × max-ratio, budget-clamp × max-ratio,
    exact-half × max-ratio, dust-floors-to-zero @ ratio 8000, min-non-zero
    ratio, realistic mid-ratio.
  * 64 randomised: `(msgValue ∈ [1, 2^96], chosenFeeBps ∈ [0, 5000],
    weiPerBudgetUnit ∈ [1, 2^50], ammSeedRatioBps ∈ [0, 8000],
    nonce ∈ [0, 2^32))`.

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

/-! ## Spec-level guarantees of the reference

The cross-stack fixture pins the L1 contract against `feeSplit`; these
theorems then make the reference's core properties *proof-carrying*
rather than merely test-observed.  Together with the cross-stack
byte-equivalence they lift the contract's conservation and budget-bound
guarantees from "fuzz-checked" to "machine-proved up to the fixture
equivalence".  (`feeBps ≤ 10000` is the universal admissibility bound;
the contract enforces the stricter `feeBps ≤ maxFeeBps ≤ 5000`.) -/

/-- The pool credit never exceeds the deposit when `feeBps ≤ 10000`.
    The load-bearing lemma for conservation: it guarantees the
    `userAmount = v - poolAmount` truncating `Nat` subtraction does not
    lose value. -/
theorem feeSplit_pool_le (v feeBps weiPerBudgetUnit : Nat) (h : feeBps ≤ 10000) :
    (feeSplit v feeBps weiPerBudgetUnit).2.1 ≤ v := by
  show (v * feeBps) / 10000 ≤ v
  calc (v * feeBps) / 10000
      ≤ (v * 10000) / 10000 := Nat.div_le_div_right (Nat.mul_le_mul_left v h)
    _ = v                   := Nat.mul_div_cancel v (by decide)

/-- Conservation: the user credit plus the pool credit equals the full
    deposit exactly (for any admissible `feeBps ≤ 10000`).  The L1
    contract's `userAmount + poolAmount == msg.value` invariant follows
    from this via the cross-stack fixture. -/
theorem feeSplit_conserves (v feeBps weiPerBudgetUnit : Nat) (h : feeBps ≤ 10000) :
    (feeSplit v feeBps weiPerBudgetUnit).1 + (feeSplit v feeBps weiPerBudgetUnit).2.1 = v := by
  show (v - (v * feeBps) / 10000) + (v * feeBps) / 10000 = v
  exact Nat.sub_add_cancel (feeSplit_pool_le v feeBps weiPerBudgetUnit h)

/-- The budget grant is always clamped at `MAX_BUDGET_PER_DEPOSIT`,
    independent of the inputs.  Pins the state-bloat ceiling. -/
theorem feeSplit_budget_le_max (v feeBps weiPerBudgetUnit : Nat) :
    (feeSplit v feeBps weiPerBudgetUnit).2.2 ≤ maxBudgetPerDeposit :=
  Nat.min_le_right _ _

/-- The AMM-seed reference (Workstream GP.11.2): the portion of a pool
    fee routed to AMM liquidity at the deployment's immutable seed ratio.
    Mirrors `KnomosisBridge._seedAmmReserves` /
    `FeeSplitMath.ammSeedSplit`: `ammSeedAmount = floor(poolAmount *
    ammSeedRatioBps / 10000)`, and the free-pool remainder is `poolAmount
    - ammSeedAmount`.  `ammSeedRatioBps ≤ MAX_AMM_SEED_RATIO_BPS = 8000 <
    10000` so the seed never exceeds the pool fee. -/
def ammSeed (poolAmount ammSeedRatioBps : Nat) : Nat :=
  (poolAmount * ammSeedRatioBps) / 10000

/-- The seed never exceeds the pool fee for an admissible ratio (`≤
    10000`).  The load-bearing lemma for the GP.11.2 split conservation
    (`freePoolAmount = poolAmount - ammSeedAmount ≥ 0`). -/
theorem ammSeed_le (poolAmount ammSeedRatioBps : Nat) (h : ammSeedRatioBps ≤ 10000) :
    ammSeed poolAmount ammSeedRatioBps ≤ poolAmount := by
  show (poolAmount * ammSeedRatioBps) / 10000 ≤ poolAmount
  calc (poolAmount * ammSeedRatioBps) / 10000
      ≤ (poolAmount * 10000) / 10000 :=
        Nat.div_le_div_right (Nat.mul_le_mul_left poolAmount h)
    _ = poolAmount := Nat.mul_div_cancel poolAmount (by decide)

/-- The free-pool remainder of a pool fee after the AMM seed is carved
    out: `poolAmount - ammSeedAmount`.  This is the value credited to the
    gas-pool actor on L2 (the sequencer-claimable free pool); the L2
    reconstructs it from the canonical event's `poolAmount` and
    `ammSeedAmount`. -/
def freePool (poolAmount ammSeedRatioBps : Nat) : Nat :=
  poolAmount - ammSeed poolAmount ammSeedRatioBps

/-- GP.11.2 split conservation (proof-carrying): the AMM seed plus the
    free-pool remainder reconstitute the full pool fee exactly, for any
    admissible ratio (`≤ 10000`; the contract enforces the stricter `≤
    8000`).  The on-chain `_seedAmmReserves` carves `ammSeedAmount` from
    `poolAmount` and leaves `poolAmount - ammSeedAmount` as free pool, so
    `userAmount + ammSeedAmount + freePoolAmount == deposit` follows from
    this together with `feeSplit_conserves`.  This is the analogue of
    `feeSplit_conserves` for the SECOND split, so the cross-stack fixture
    pins a machine-proved conservation invariant for the AMM seed rather
    than a merely fuzz-observed one. -/
theorem ammSeed_conserves (poolAmount ammSeedRatioBps : Nat)
    (h : ammSeedRatioBps ≤ 10000) :
    ammSeed poolAmount ammSeedRatioBps + freePool poolAmount ammSeedRatioBps = poolAmount := by
  show ammSeed poolAmount ammSeedRatioBps
        + (poolAmount - ammSeed poolAmount ammSeedRatioBps) = poolAmount
  exact Nat.add_sub_cancel' (ammSeed_le poolAmount ammSeedRatioBps h)

/-! ## ReceiptHash recipe -/

/-- The hash-independent *tail* of the receiptHash preimage: the eight
    fields that follow the leading `deploymentId` word, ABI-encoded as
    8 × 32 = 256 bytes.  Workstream GP.11.2 inserted `ammSeedAmount` after
    `poolAmount` (the AMM split is bound in the receiptHash).  This is pure
    `abi.encode` layout — no hashing — so the Solidity consumer can
    byte-match it against its own `abi.encode(sender, resourceId, token,
    userAmount, poolAmount, ammSeedAmount, budgetGrant, nonce)` in *every*
    binding mode (the FNV fallback does not affect it).  That pins the
    receiptHash field order + widths cross-stack even when the
    keccak256-gated full-hash check is skipped. -/
def feeSplitReceiptTail (sender : ByteArray) (resourceId : Nat)
    (token : ByteArray) (userAmount poolAmount ammSeedAmount budgetGrant nonce : Nat) : ByteArray :=
  DepositReceiptHash.concatBytes
    [ DepositReceiptHash.encodeAddressLeftPadded sender
    , DepositReceiptHash.encodeUint256BE resourceId
    , DepositReceiptHash.encodeAddressLeftPadded token
    , DepositReceiptHash.encodeUint256BE userAmount
    , DepositReceiptHash.encodeUint256BE poolAmount
    , DepositReceiptHash.encodeUint256BE ammSeedAmount
    , DepositReceiptHash.encodeUint256BE budgetGrant
    , DepositReceiptHash.encodeUint256BE nonce
    ]

/-- The fee-split receiptHash preimage (9 × 32 = 288 bytes): the
    `deploymentId` word followed by `feeSplitReceiptTail`.  Reuses the
    `DepositReceiptHash` ABI helpers so the encoding recipe is shared. -/
def feeSplitReceiptPreimage (deploymentId sender : ByteArray) (resourceId : Nat)
    (token : ByteArray) (userAmount poolAmount ammSeedAmount budgetGrant nonce : Nat) : ByteArray :=
  deploymentId.append
    (feeSplitReceiptTail sender resourceId token userAmount poolAmount ammSeedAmount budgetGrant nonce)

/-- Compute the fee-split receiptHash. -/
def computeFeeSplitReceiptHash (deploymentId sender : ByteArray) (resourceId : Nat)
    (token : ByteArray) (userAmount poolAmount ammSeedAmount budgetGrant nonce : Nat) : ByteArray :=
  hashBytes
    (feeSplitReceiptPreimage deploymentId sender resourceId token
      userAmount poolAmount ammSeedAmount budgetGrant nonce)

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
  /-- The deployment's immutable AMM seed ratio in bps (Workstream
      GP.11.2); `0` disables the AMM (no seed). -/
  ammSeedRatioBps    : Nat
  /-- uint64 per-depositor nonce. -/
  depositorNonce     : Nat
  /-- Derived user-facing credit. -/
  userAmount         : Nat
  /-- Derived pool credit (the full fee). -/
  poolAmount         : Nat
  /-- Derived AMM-liquidity seed (`floor(poolAmount * ammSeedRatioBps /
      10000)`, GP.11.2); the free-pool remainder is `poolAmount -
      ammSeedAmount`. -/
  ammSeedAmount      : Nat
  /-- Derived action-budget grant. -/
  budgetGrant        : Nat
  /-- 32-byte expected receipt hash. -/
  expectedHash       : ByteArray
  /-- 256-byte hash-independent receiptHash preimage tail (the eight
      ABI-encoded fields after `deploymentId`, including the GP.11.2
      `ammSeedAmount`).  The Solidity consumer byte-matches this against
      its own `abi.encode`, pinning the receiptHash layout cross-stack
      regardless of hash binding. -/
  receiptTail        : ByteArray

/-- Build an `Entry`, computing the split, AMM seed, deploymentId, and
    hash.  `seedRatio` is the deployment's `ammSeedRatioBps` (GP.11.2); `0`
    on an AMM-disabled entry. -/
def mkEntry (chainid : Nat) (contractAddr knomosisVersionTag sender : ByteArray)
    (msgValue chosenFeeBps weiPerBudgetUnit seedRatio nonce : Nat) (category : String) : Entry :=
  let did := DepositReceiptHash.computeDeploymentId chainid contractAddr knomosisVersionTag
  let split := feeSplit msgValue chosenFeeBps weiPerBudgetUnit
  let userAmount := split.1
  let poolAmount := split.2.1
  let budgetGrant := split.2.2
  let ammSeedAmount := ammSeed poolAmount seedRatio
  let hash := computeFeeSplitReceiptHash did sender 0 DepositReceiptHash.zeroAddr20
                userAmount poolAmount ammSeedAmount budgetGrant nonce
  let tail := feeSplitReceiptTail sender 0 DepositReceiptHash.zeroAddr20
                userAmount poolAmount ammSeedAmount budgetGrant nonce
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
  , ammSeedRatioBps := seedRatio
  , depositorNonce := nonce
  , userAmount := userAmount
  , poolAmount := poolAmount
  , ammSeedAmount := ammSeedAmount
  , budgetGrant := budgetGrant
  , expectedHash := hash
  , receiptTail := tail
  }

/-! ## Corner entries -/

/-- 22 hand-listed corner cases over a fixed `(contractAddr, knomosisTag,
    sender)` base.  The first 16 use `seedRatio = 0` (AMM-disabled): they
    focus on the fee-split arithmetic + receiptHash layout (with the
    GP.11.2 `ammSeedAmount` field present and 0).  The final 6 (`ammcorner:*`)
    intersect the deliberate fee-split boundaries with a NON-ZERO AMM seed
    ratio (max-fee × max-ratio, budget-clamp × max-ratio, exact-half ×
    max-ratio, dust-floors-to-zero at a non-zero ratio, min-non-zero ratio,
    realistic mid-ratio), so the receiptHash binding of a non-zero
    `ammSeedAmount` is pinned at SPECIFIC boundary×boundary combinations —
    not only the statistical coverage the randomised half gives.  The
    `ammcorner:*` entries are APPENDED (indices 16..21), so the index-keyed
    consumer checks (zero-fee at 0; budget-clamp corners at 4/5/6) are
    unchanged. -/
def cornerEntries : Gen (List Entry) := fun st0 =>
  let (contractAddr, s1) := DepositReceiptHash.genBytes 20 st0
  let (knomosisTag,   s2) := DepositReceiptHash.genBytes 32 s1
  let (sender,        s3) := DepositReceiptHash.genBytes 20 s2
  let c := 1   -- mainnet-equivalent chainid
  let max64 : Nat := 2 ^ 64 - 1
  let entries : List Entry :=
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
    , mkEntry c contractAddr knomosisTag sender (5 * 10 ^ 18)        1000 (10 ^ 9)  0 0     "corner:realistic-ten-percent"
    , mkEntry c contractAddr knomosisTag sender 1000000              50   1         0 0     "corner:min-fee-small"
    , mkEntry c contractAddr knomosisTag sender 1000000              4999 1         0 0     "corner:fee-just-below-max"
    , mkEntry c contractAddr knomosisTag sender 1000000              250  1         0 0     "corner:single-fee"
    , mkEntry c contractAddr knomosisTag sender 999999999            4321 (10 ^ 6)  0 7     "corner:misc"
    -- GP.11.2 AMM-enabled boundary corners (non-zero seed ratio):
    , mkEntry c contractAddr knomosisTag sender (10 ^ 18)            5000 (10 ^ 9)  8000 0  "ammcorner:max-fee-max-ratio"
    , mkEntry c contractAddr knomosisTag sender (10 ^ 19)            5000 1         8000 0  "ammcorner:budget-clamp-max-ratio"
    , mkEntry c contractAddr knomosisTag sender 100                  5000 1         8000 0  "ammcorner:exact-half-max-ratio"
    , mkEntry c contractAddr knomosisTag sender 3                    5000 1         8000 0  "ammcorner:dust-seed-floors-to-zero"
    , mkEntry c contractAddr knomosisTag sender (10 ^ 18)            5000 (10 ^ 9)  1    0  "ammcorner:min-nonzero-ratio"
    , mkEntry c contractAddr knomosisTag sender (5 * 10 ^ 18)        1000 (10 ^ 9)  3000 0  "ammcorner:realistic-mid-ratio"
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

/-- Generate an AMM seed ratio in `[0, 8000]` (the admissible range under
    `MAX_AMM_SEED_RATIO_BPS`, Workstream GP.11.2).  `0` ≈ 1/8001 of draws
    leave the AMM disabled; the rest exercise a non-zero `ammSeedAmount`
    binding in the receiptHash. -/
def genSeedRatio : Gen Nat := genNat 8001

/-- Generate an exchange rate in `[1, 2^50]`, covering the realistic
    operator band `[10^9, 10^15]` and beyond. -/
def genRate : Gen Nat := fun st0 =>
  let (hi, s1) := genNat (2 ^ 18) st0
  let (lo, s2) := genNat (2 ^ 32) s1
  (hi * (2 ^ 32) + lo + 1, s2)

/-- Generate one randomised entry, including a random `ammSeedRatioBps`
    (GP.11.2) so the receiptHash's AMM-seed binding is fuzzed cross-stack. -/
def genRandomEntry (idx : Nat) : Gen Entry := fun st0 =>
  let (contractAddr, s1) := DepositReceiptHash.genBytes 20 st0
  let (knomosisTag,   s2) := DepositReceiptHash.genBytes 32 s1
  let (sender,        s3) := DepositReceiptHash.genBytes 20 s2
  let (chainid,       s4) := genNat (2 ^ 32) s3
  let (msgValue,      s5) := genWei s4
  let (feeBps,        s6) := genFeeBps s5
  let (rate,          s7) := genRate s6
  let (seedRatio,     s8) := genSeedRatio s7
  let (nonce,         s9) := genNat (2 ^ 32) s8
  let e := mkEntry (chainid + 1) contractAddr knomosisTag sender
              msgValue feeBps rate seedRatio nonce s!"random:{idx}"
  (e, s9)

/-! ## Top-level fixture -/

/-- Build the full fixture: 22 corners (16 fee-split + 6 AMM-enabled) + 64
    randomised = 86 entries.  `countNonZeroSeed` records how many entries
    carry a NON-ZERO `ammSeedAmount`; the consumer recomputes + asserts it
    is ≥ a floor, so the receiptHash's AMM-seed binding can never silently
    regress to all-zero coverage (a generator bug zeroing the ratio would
    drop the count and fail the consumer). -/
def buildFixture (seed : UInt64) : (Json × Nat) :=
  let (corners,    s1) := cornerEntries ⟨seed⟩
  let (randomised, _ ) := DepositReceiptHash.genN genRandomEntry 64 s1
  let allEntries := corners ++ randomised
  let countNonZeroSeed := (allEntries.filter (fun e => e.ammSeedAmount > 0)).length
  let header : Json := .obj
    [ ("seed",                .num seed.toNat)
    , ("isKeccak256Linked",   .bool isKeccak256Linked)
    , ("hashIdentifier",      .str (hashImplementationIdentifier ()))
    , ("count",               .num allEntries.length)
    , ("countCorner",         .num 22)
    , ("countRandomised",     .num 64)
    , ("countNonZeroSeed",    .num countNonZeroSeed)
    , ("maxBudgetPerDeposit", .num maxBudgetPerDeposit)
    , ("maxFeeBpsCap",        .num 5000)
    , ("minWeiPerBudgetUnit", .num 1)
    , ("maxAmmSeedRatioBps",  .num 8000)
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
def fixtureName : String := "deposit_fee_split.json"

/-! ## Test cases -/

/-- The test cases: count, determinism, byte sizes, conservation,
    budget bound, reference anchors, hash self-consistency, clamp
    corners, preimage size, file write, and the conditional
    cross-check skip. -/
def tests : List TestCase :=
  [ { name := "GP.5.1: deposit_fee_split fixture has 86 entries"
    , body := do
        let seed ← readSeed
        let (_, n) := buildFixture seed
        if n ≠ 86 then
          throw <| IO.userError s!"expected 86 entries, got {n}"
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
  , { name := "GP.5.1: feeSplitReceiptPreimage is exactly 288 bytes (GP.11.2)"
    , body := do
        let did := DepositReceiptHash.encodeUint256BE 0   -- 32 bytes
        let preimage :=
          feeSplitReceiptPreimage did DepositReceiptHash.zeroAddr20 0
            DepositReceiptHash.zeroAddr20 0 0 0 0 0
        if preimage.size ≠ 288 then
          throw <| IO.userError s!"feeSplitReceiptPreimage size {preimage.size}, expected 288"
    }
  , { name := "GP.5.1: every entry's receiptTail is exactly 256 bytes (GP.11.2)"
    , body := do
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          if e.receiptTail.size ≠ 256 then
            throw <| IO.userError s!"receiptTail size {e.receiptTail.size} in {e.category}, expected 256"
          -- The tail is the 32-byte-aligned suffix of the full preimage.
          if e.deploymentId.append e.receiptTail ≠
             feeSplitReceiptPreimage e.deploymentId e.sender e.resourceId e.token
               e.userAmount e.poolAmount e.ammSeedAmount e.budgetGrant e.depositorNonce then
            throw <| IO.userError s!"receiptTail not the preimage suffix in {e.category}"
    }
  , { name := "GP.5.1: feeSplit spec theorems (conservation + budget bound)"
    , body := do
        -- Bind the proof-carrying spec theorems at the term level so the
        -- IO suite fails to elaborate if their signatures regress, and
        -- value-check conservation + the budget bound on every entry.
        let _conserves : ∀ (v feeBps wpu : Nat), feeBps ≤ 10000 →
            (feeSplit v feeBps wpu).1 + (feeSplit v feeBps wpu).2.1 = v :=
          feeSplit_conserves
        let _poolLe : ∀ (v feeBps wpu : Nat), feeBps ≤ 10000 →
            (feeSplit v feeBps wpu).2.1 ≤ v :=
          feeSplit_pool_le
        let _budgetLe : ∀ (v feeBps wpu : Nat),
            (feeSplit v feeBps wpu).2.2 ≤ maxBudgetPerDeposit :=
          feeSplit_budget_le_max
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          if e.userAmount + e.poolAmount ≠ e.msgValue then
            throw <| IO.userError s!"conservation value-check failed in {e.category}"
          if e.budgetGrant > maxBudgetPerDeposit then
            throw <| IO.userError s!"budget-bound value-check failed in {e.category}"
    }
  , { name := "GP.11.2: every entry's ammSeedAmount conserves the pool fee"
    , body := do
        -- Bind the proof-carrying AMM-seed theorems at the term level
        -- (forcing functions on their signatures): `ammSeed_le` (seed ≤
        -- pool) and `ammSeed_conserves` (seed + freePool == pool).  Then
        -- value-check the split on every entry: the recomputed seed
        -- matches, never exceeds the pool fee, and seed + (pool - seed) ==
        -- pool (the on-chain free-pool split conservation).
        let _seedLe : ∀ (p r : Nat), r ≤ 10000 → ammSeed p r ≤ p := ammSeed_le
        let _seedConserves : ∀ (p r : Nat), r ≤ 10000 →
            ammSeed p r + freePool p r = p := ammSeed_conserves
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        for e in corners ++ randomised do
          if e.ammSeedRatioBps > 8000 then
            throw <| IO.userError s!"ammSeedRatioBps {e.ammSeedRatioBps} out of range in {e.category}"
          if e.ammSeedAmount ≠ ammSeed e.poolAmount e.ammSeedRatioBps then
            throw <| IO.userError s!"ammSeedAmount recompute mismatch in {e.category}"
          if e.ammSeedAmount > e.poolAmount then
            throw <| IO.userError s!"ammSeedAmount {e.ammSeedAmount} exceeds pool fee in {e.category}"
          -- Conservation value-check: seed + freePool == poolAmount.
          if e.ammSeedAmount + freePool e.poolAmount e.ammSeedRatioBps ≠ e.poolAmount then
            throw <| IO.userError s!"seed + freePool ≠ poolAmount in {e.category}"
    }
  , { name := "GP.11.2: corpus pins a non-zero-seed coverage floor"
    , body := do
        -- The receiptHash's ammSeedAmount binding is only meaningfully
        -- exercised by entries with a NON-ZERO seed.  Pin that the corpus
        -- carries a healthy number (the 64 randomised draw a random ratio,
        -- plus 5 of the 6 AMM corners are non-zero), so a future change
        -- that silently zeroed every seed cannot pass unnoticed.  The
        -- generator publishes this count in the header `countNonZeroSeed`,
        -- which the Solidity consumer independently recomputes + asserts ==
        -- header AND >= the floor (the cross-stack mechanical pin).
        let seed ← readSeed
        let (corners, s1) := cornerEntries ⟨seed⟩
        let (randomised, _) := DepositReceiptHash.genN genRandomEntry 64 s1
        let recount := ((corners ++ randomised).filter (fun e => e.ammSeedAmount > 0)).length
        if recount < 50 then
          throw <| IO.userError s!"non-zero-seed coverage too low: {recount} < 50"
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
              e.userAmount e.poolAmount e.ammSeedAmount e.budgetGrant e.depositorNonce
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
