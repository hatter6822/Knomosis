-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/
import LegalKernel
import LegalKernel.Bridge.AmmMath
import LegalKernel.Test.Framework
import LegalKernel.Test.Bridge.CrossCheck.Framework

/-!
LegalKernel.Test.Bridge.CrossCheck.AmmSwap — Workstream GP.11.7.

Generates the `amm_swap.json` cross-stack fixture corpus and the
companion `amm_swap.cxsf` binary corpus for the `Action.ammSwap`
constructor (frozen index 23).

The corpus covers:

  * 3 reserve sizes × 2 directions × 3 swap fractions × 3 slippage
    thresholds = 54 grid entries
  * 12 boundary corner cases (dust, max-U64, zero output, asymmetric
    pools, paired round-trip checks, varied fees)
  = 66 entries total.

Each entry carries:

  * The five `Action.ammSwap` fields: `fromResource`, `toResource`,
    `amountIn`, `amountOut`, `ammReserveActor`.
  * `expectedCbe`: the Lean `Encoding.Action.encode` hex of the
    constructed `Action`.
  * `expectedOut`: the Lean `AmmMath.getAmountOut` result (the same
    function the Solidity `AmmMath.sol` implements).
  * `reserveIn`, `reserveOut`: the pre-swap reserves (needed by the
    Solidity consumer to recompute `getAmountOut`).
  * `feeBps`: the swap fee in basis points (always 30 in production).
  * `kBefore`, `kAfter`: the constant product before and after the
    swap, as 0x-prefixed 32-byte BE hex strings (k-monotonicity).
  * `minAmountOut`: the slippage threshold the entry exercises.
  * `slippageSatisfied`: whether `expectedOut >= minAmountOut`.

**Reserve sizing discipline.** Reserves are scaled so that EVERY
`amountIn` and `expectedOut` value fits within u64 (≤ 2^64 − 1 =
18 446 744 073 709 551 615).  This is a hard constraint: the
kernel's CBE `Encodable Nat` encodes as an 8-byte LE word, and
the Rust `encode_amount` rejects values exceeding u64::MAX.  The
largest swap fraction (50 % of the larger reserve in the 1:3000
pools) yields `amountIn = 1500 × R`, so `R` must satisfy
`1500 × R ≤ u64::MAX` → `R ≤ ~1.23 × 10^16`.  The chosen scales
(`10^12`, `10^15`, `10^16`) satisfy this with margin.

Amount fields (`amountIn`, `expectedOut`, `reserveIn`, `reserveOut`,
`minAmountOut`) are emitted as `0x`-prefixed 32-byte BE hex strings
(read on the Solidity side via `vm.parseJsonBytes32`).  The `kBefore`
and `kAfter` products can exceed u64 (and even u128), so they are
likewise emitted as hex strings.

This module is non-TCB.
-/

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Bridge.AmmMath
open LegalKernel.Test

namespace AmmSwapCrossCheck

/-- The production swap fee in basis points (0.30%). -/
def ammSwapFeeBps : Nat := 30

/-- The AMM reserve actor id in production. -/
def ammReserveActorId : Nat := 3

/-- `10^12`. -/
def e12 : Nat := 1000000000000

/-- `10^15`. -/
def e15 : Nat := 1000000000000000

/-- `10^16`. -/
def e16 : Nat := 10000000000000000

/-- `10^18` (one ether / one BOLD-wei). -/
def e18 : Nat := 1000000000000000000

/-- `10^9` (one gwei). -/
def e9 : Nat := 1000000000

/-- `2^64 - 1`, the largest value a CBE uint head can represent. -/
def maxU64 : Nat := 18446744073709551615

/-- Encode an `Action` via the canonical Lean encoder and return the
    `0x`-prefixed lowercase hex. -/
def encodeActionHex (a : Action) : String :=
  hexFromBytes (ByteArray.mk (Encodable.encode (T := Action) a).toArray)

/-- One corpus entry. -/
structure Entry where
  /-- Human-readable category tag. -/
  category      : String
  /-- Resource being swapped in (0 = ETH, 1 = BOLD). -/
  fromResource  : Nat
  /-- Resource being swapped out. -/
  toResource    : Nat
  /-- The amount supplied to the swap. -/
  amountIn      : Nat
  /-- Pre-swap reserve of the input asset. -/
  reserveIn     : Nat
  /-- Pre-swap reserve of the output asset. -/
  reserveOut    : Nat
  /-- Swap fee in basis points. -/
  feeBps        : Nat
  /-- The Lean-computed output. -/
  expectedOut   : Nat
  /-- Slippage threshold exercised. -/
  minAmountOut  : Nat
  /-- Whether `expectedOut >= minAmountOut`. -/
  slippageSatisfied : Bool
  /-- Constant product before the swap. -/
  kBefore       : Nat
  /-- Constant product after the swap. -/
  kAfter        : Nat

/-- Build an entry from the swap parameters, computing all derived fields. -/
def mkEntry (fromR toR amountIn reserveIn reserveOut feeBps minOut : Nat)
    (category : String) : Entry :=
  let out := getAmountOut amountIn reserveIn reserveOut feeBps
  let kB  := reserveIn * reserveOut
  let kA  := (reserveIn + amountIn) * (reserveOut - out)
  { category
  , fromResource := fromR
  , toResource := toR
  , amountIn
  , reserveIn
  , reserveOut
  , feeBps
  , expectedOut := out
  , minAmountOut := minOut
  , slippageSatisfied := out >= minOut
  , kBefore := kB
  , kAfter := kA
  }

/-- Serialise one entry to JSON.  Amount-scale fields use 32-byte BE
    hex strings (matching the `AmmMath.lean` cross-check pattern);
    `kBefore` / `kAfter` also use hex (products can exceed u128). -/
def entryJson (e : Entry) : Json :=
  let a : Action :=
    .ammSwap (UInt64.ofNat e.fromResource) (UInt64.ofNat e.toResource)
      e.amountIn e.expectedOut (UInt64.ofNat ammReserveActorId)
  Json.obj
    [ ("category",          Json.str e.category)
    , ("fromResource",      Json.num e.fromResource)
    , ("toResource",        Json.num e.toResource)
    , ("amountIn",          Json.str (hexFromUint256BE e.amountIn))
    , ("reserveIn",         Json.str (hexFromUint256BE e.reserveIn))
    , ("reserveOut",        Json.str (hexFromUint256BE e.reserveOut))
    , ("feeBps",            Json.num e.feeBps)
    , ("expectedOut",       Json.str (hexFromUint256BE e.expectedOut))
    , ("minAmountOut",      Json.str (hexFromUint256BE e.minAmountOut))
    , ("slippageSatisfied", Json.bool e.slippageSatisfied)
    , ("kBefore",           Json.str (hexFromUint256BE e.kBefore))
    , ("kAfter",            Json.str (hexFromUint256BE e.kAfter))
    , ("ammReserveActor",   Json.num ammReserveActorId)
    , ("expectedCbe",       Json.str (encodeActionHex a))
    ]

/-! ## Reserve configurations

Three pool sizes whose largest swap fraction (50 % of the bigger
reserve) fits within u64::MAX.  The 1:3000 ratio mirrors the
ETH/BOLD price relationship.

  * Small:  10^12 ETH / 3×10^15 BOLD
  * Medium: 10^15 ETH / 3×10^18 BOLD
  * Large:  10^16 ETH / 3×10^19 BOLD

Constraint: `1500 × reserveOut ≤ maxU64` where `reserveOut` is the
larger reserve (the BOLD leg in ETH→BOLD swaps).  For the large pool:
`1500 × 3×10^19 = 4.5×10^22 > maxU64`.  But the swap fraction is
applied to `reserveIn`, not `reserveOut`, so `amountIn = 0.5 × 10^16
= 5×10^15` and `expectedOut ≈ amountIn × 3000 × 0.997 ≈ 1.5×10^19
< maxU64`.  Verified below by the u64 guard test. -/

/-- (reserveEth, reserveBold, label). -/
def reserveConfigs : List (Nat × Nat × String) :=
  [ (e12, 3000 * e12, "small")
  , (e15, 3000 * e15, "medium")
  , (e16, 3000 * e16, "large")
  ]

/-! ## Swap sizes: 1%, 10%, 50% of the input reserve. -/

/-- (fraction_numerator, fraction_denominator, label). -/
def swapFractions : List (Nat × Nat × String) :=
  [ (1, 100, "1pct")
  , (10, 100, "10pct")
  , (50, 100, "50pct")
  ]

/-! ## Slippage thresholds per entry: exact output, 99% of output, 50% of output. -/

/-- Given the computed output, return three slippage thresholds. -/
def slippageThresholds (out : Nat) : List (Nat × String) :=
  [ (out, "exact")
  , (out * 99 / 100, "99pct")
  , (out / 2, "50pct")
  ]

/-! ## Grid entries -/

/-- Build entries for one direction (ETH→BOLD or BOLD→ETH) across
    all reserve configs × swap sizes × slippage thresholds. -/
def directionEntries (fromR toR : Nat) (dirLabel : String) : List Entry :=
  reserveConfigs.flatMap fun (rEth, rBold, poolLabel) =>
    let reserveIn := if fromR = 0 then rEth else rBold
    let reserveOut := if fromR = 0 then rBold else rEth
    swapFractions.flatMap fun (num, den, fracLabel) =>
      let amountIn := reserveIn * num / den
      let out := getAmountOut amountIn reserveIn reserveOut ammSwapFeeBps
      (slippageThresholds out).map fun (minOut, slipLabel) =>
        mkEntry fromR toR amountIn reserveIn reserveOut ammSwapFeeBps minOut
          s!"grid:{dirLabel}-{poolLabel}-{fracLabel}-slip{slipLabel}"

/-- All grid entries: ETH→BOLD + BOLD→ETH = 2 × 3 × 3 × 3 = 54 entries. -/
def gridEntries : List Entry :=
  directionEntries 0 1 "eth2bold" ++ directionEntries 1 0 "bold2eth"

/-! ## Corner entries -/

/-- Hand-picked boundary cases the grid does not cover. -/
def cornerEntries : List Entry :=
  [ mkEntry 0 1 1 (1000 * e12) (3000000 * e12) ammSwapFeeBps 0
      "corner:dust-eth-in"
  , mkEntry 1 0 1 (3000000 * e12) (1000 * e12) ammSwapFeeBps 0
      "corner:dust-bold-in"
  , mkEntry 0 1 (999 * e12) (1000 * e12) (3000000 * e12) ammSwapFeeBps 0
      "corner:near-drain-eth"
  , mkEntry 0 1 1000 1000 1000 0 0
      "corner:handvector-noFee-500"
  , mkEntry 0 1 1000 1000 1000 ammSwapFeeBps 0
      "corner:handvector-fee30-499"
  , mkEntry 0 1 e9 e9 (40 * e12) ammSwapFeeBps 0
      "corner:asymmetric-tiny-eth-pool"
  , mkEntry 0 1 maxU64 maxU64 maxU64 ammSwapFeeBps 0
      "corner:max-u64-symmetric"
  , mkEntry 0 1 e12 (100 * e12) (300000 * e12) ammSwapFeeBps 0
      "corner:roundtrip-a-eth2bold"
  , let outA := getAmountOut e12 (100 * e12) (300000 * e12) ammSwapFeeBps
    let newResEth := 100 * e12 + e12
    let newResBold := 300000 * e12 - outA
    mkEntry 1 0 outA newResBold newResEth ammSwapFeeBps 0
      "corner:roundtrip-b-bold2eth"
  , mkEntry 0 1 e12 (100 * e12) (300000 * e12) 0 0
      "corner:zero-fee"
  , mkEntry 0 1 e12 (100 * e12) (300000 * e12) 5000 0
      "corner:high-fee-5000bps"
  , mkEntry 0 1 e12 (100 * e12) (300000 * e12) 9999 0
      "corner:fee-just-below-100pct"
  ]

/-- The full corpus. -/
def entries : List Entry := gridEntries ++ cornerEntries

/-- The fixture's JSON value. -/
def buildJson : Json :=
  Json.obj
    [ ("header", Json.obj
        [ ("workstream",       Json.str "GP.11.7")
        , ("count",            Json.num entries.length)
        , ("gridCount",        Json.num gridEntries.length)
        , ("cornerCount",      Json.num cornerEntries.length)
        , ("ammSwapFeeBps",    Json.num ammSwapFeeBps)
        , ("bpsDenominator",   Json.num bpsDenominator)
        , ("ammReserveActor",  Json.num ammReserveActorId)
        , ("actionTag",        Json.num 23)
        ])
    , ("entries", Json.arr (entries.map entryJson))
    ]

/-- The fixture file name. -/
def fixtureName : String := "amm_swap.json"

/-! ## CXSF binary corpus

Each record: input = the five `Action.ammSwap` fields as 5 × 8-byte
BE u64 words (40 bytes); expected = the Lean `Action.encode` CBE
bytes (54 bytes: tag + 5 × 9-byte heads). -/

/-- CXSF kind tag for the AMM-swap corpus (on-disk tag 8). -/
def cxsfKindTag : UInt32 := 8

/-- Build a CXSF record pair from an entry. -/
def entryCxsf (e : Entry) : ByteArray × ByteArray :=
  let input :=
    beBytes e.fromResource 8
    |>.append (beBytes e.toResource 8)
    |>.append (beBytes e.amountIn 8)
    |>.append (beBytes e.expectedOut 8)
    |>.append (beBytes ammReserveActorId 8)
  let a : Action :=
    .ammSwap (UInt64.ofNat e.fromResource) (UInt64.ofNat e.toResource)
      e.amountIn e.expectedOut (UInt64.ofNat ammReserveActorId)
  let expected := ByteArray.mk (Encodable.encode (T := Action) a).toArray
  (input, expected)

/-- Build the full CXSF binary blob. -/
def buildCxsfBlob : ByteArray :=
  buildCxsf cxsfKindTag (entries.map entryCxsf)

/-- CXSF file name. -/
def cxsfName : String := "amm_swap.cxsf"

/-! ## Test cases -/

/-- Tests: entry count, mathematical soundness, u64 guard, CBE
    byte-shape, hand-pinned vectors, round-trip, slippage, and the
    fixture write. -/
def tests : List TestCase :=
  [ { name := "GP.11.7: amm_swap corpus has >= 66 entries"
    , body := do
        if entries.length < 66 then
          throw <| IO.userError s!"expected >= 66 entries, got {entries.length}"
    }
  , { name := "GP.11.7: grid has 54 entries (2 directions × 3 pools × 3 fracs × 3 slippage)"
    , body := do
        if gridEntries.length ≠ 54 then
          throw <| IO.userError s!"expected 54 grid entries, got {gridEntries.length}"
    }
  , { name := "GP.11.7: every entry's amountIn and expectedOut fit within u64"
    , body := do
        for e in entries do
          unless e.amountIn ≤ maxU64 do
            throw <| IO.userError s!"amountIn exceeds u64: {e.category} ({e.amountIn})"
          unless e.expectedOut ≤ maxU64 do
            throw <| IO.userError s!"expectedOut exceeds u64: {e.category} ({e.expectedOut})"
    }
  , { name := "GP.11.7: every entry satisfies no-drain (expectedOut < reserveOut)"
    , body := do
        for e in entries do
          unless e.expectedOut < e.reserveOut ∨ e.reserveOut = 0 ∨ e.reserveIn = 0
              ∨ e.feeBps ≥ bpsDenominator ∨ e.amountIn = 0 do
            throw <| IO.userError s!"no-drain violated: {e.category}"
    }
  , { name := "GP.11.7: every entry satisfies k-monotonicity (kBefore <= kAfter)"
    , body := do
        for e in entries do
          unless e.kBefore ≤ e.kAfter do
            throw <| IO.userError s!"k decreased: {e.category} (kBefore={e.kBefore}, kAfter={e.kAfter})"
    }
  , { name := "GP.11.7: every entry's expectedOut matches getAmountOut recomputation"
    , body := do
        for e in entries do
          let recomputed := getAmountOut e.amountIn e.reserveIn e.reserveOut e.feeBps
          unless e.expectedOut = recomputed do
            throw <| IO.userError
              s!"formula mismatch: {e.category} (got {e.expectedOut}, recomputed {recomputed})"
    }
  , { name := "GP.11.7: hand-vector anchors match known ground truth"
    , body := do
        assertEq (expected := 500)
          (actual := getAmountOut 1000 1000 1000 0) "noFee half-pool"
        assertEq (expected := 499)
          (actual := getAmountOut 1000 1000 1000 30) "fee30 half-pool"
    }
  , { name := "GP.11.7: ammSwap canonical vector matches hand-pinned CBE bytes"
    , body := do
        let a : Action := .ammSwap 0 1 1000 500 3
        let hex := encodeActionHex a
        let expected :=
          "0x" ++
          "001700000000000000" ++
          "000000000000000000" ++
          "000100000000000000" ++
          "00e803000000000000" ++
          "00f401000000000000" ++
          "000300000000000000"
        if hex ≠ expected then
          throw <| IO.userError
            s!"ammSwap canonical bytes mismatch:\n  got      {hex}\n  expected {expected}"
    }
  , { name := "GP.11.7: every entry's expectedCbe is 54 bytes (110 hex chars with 0x prefix)"
    , body := do
        for e in entries do
          let a : Action :=
            .ammSwap (UInt64.ofNat e.fromResource) (UInt64.ofNat e.toResource)
              e.amountIn e.expectedOut (UInt64.ofNat ammReserveActorId)
          let hex := encodeActionHex a
          if hex.length ≠ 110 then
            throw <| IO.userError s!"CBE length mismatch for {e.category}: {hex.length} ≠ 110"
    }
  , { name := "GP.11.7: every entry's leading tag byte is 0x17 (= 23)"
    , body := do
        for e in entries do
          let a : Action :=
            .ammSwap (UInt64.ofNat e.fromResource) (UInt64.ofNat e.toResource)
              e.amountIn e.expectedOut (UInt64.ofNat ammReserveActorId)
          let hex := encodeActionHex a
          let tagHex := if hex.length ≥ 6
            then String.ofList ((hex.toList.drop 4).take 2) else ""
          if tagHex ≠ "17" then
            throw <| IO.userError s!"tag byte {tagHex} ≠ 17 for {e.category}"
    }
  , { name := "GP.11.7: paired round-trip entries show k never decreases across both swaps"
    , body := do
        let outA := getAmountOut e12 (100 * e12) (300000 * e12) ammSwapFeeBps
        let kBeforeA := (100 * e12) * (300000 * e12)
        let kAfterA := (100 * e12 + e12) * (300000 * e12 - outA)
        unless kBeforeA ≤ kAfterA do
          throw <| IO.userError "round-trip leg A: k decreased"
        let newResEth := 100 * e12 + e12
        let newResBold := 300000 * e12 - outA
        let outB := getAmountOut outA newResBold newResEth ammSwapFeeBps
        let kBeforeB := newResBold * newResEth
        let kAfterB := (newResBold + outA) * (newResEth - outB)
        unless kBeforeB ≤ kAfterB do
          throw <| IO.userError "round-trip leg B: k decreased"
    }
  , { name := "GP.11.7: slippageSatisfied is correctly computed for every entry"
    , body := do
        for e in entries do
          let expected := e.expectedOut >= e.minAmountOut
          unless e.slippageSatisfied = expected do
            throw <| IO.userError
              s!"slippage flag mismatch: {e.category} (out={e.expectedOut}, min={e.minAmountOut})"
    }
  , { name := "GP.11.7: header constants match the Lean definitions"
    , body := do
        assertEq (expected := 10000)
          (actual := bpsDenominator) "bpsDenominator"
        assertEq (expected := 30)
          (actual := ammSwapFeeBps) "ammSwapFeeBps"
        assertEq (expected := 3)
          (actual := ammReserveActorId) "ammReserveActorId"
    }
  , { name := "GP.11.7: term-level API stability for getAmountOut_lt_reserveOut"
    , body := do
        let _noDrain : getAmountOut 1 1000 1000 30 < 1000 :=
          getAmountOut_lt_reserveOut (by omega) (by omega) (by decide)
        pure ()
    }
  , { name := "GP.11.7: term-level API stability for k_nondecreasing"
    , body := do
        let _kMono : (1000 : Nat) * 1000
              ≤ (1000 + 1) * (1000 - getAmountOut 1 1000 1000 30) :=
          k_nondecreasing (by omega) (by omega) (by decide)
        pure ()
    }
  , { name := "GP.11.7: write amm_swap.json fixture file"
    , body :=
        writeFixture fixtureName buildJson.encodeIndented
    }
  , { name := "GP.11.7: write amm_swap.cxsf binary fixture"
    , body :=
        writeBinFixture cxsfName buildCxsfBlob
    }
  ]

end AmmSwapCrossCheck
end LegalKernel.Test.Bridge.CrossCheck
