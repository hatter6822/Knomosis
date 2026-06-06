-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.AmmMath — Workstream GP.11.3 cross-stack
corpus for the embedded-AMM swap math.

Generates `amm_getamountout.json`, a Lean→Solidity equivalence corpus for the
constant-product pricing function `getAmountOut`.  For each entry the Lean
`LegalKernel.Bridge.AmmMath.getAmountOut` computes `expectedOut`; the Solidity
consumer (`solidity/test/CrossCheck/AmmMath.t.sol`) recomputes
`src/lib/AmmMath.sol`'s `getAmountOut` over the SAME inputs and byte-matches
the result — mechanically proving `Lean-spec == Solidity-formula` over the
whole corpus (not just the few hand-vectors the unit tests pin).

The corpus is also PROOF-CARRYING: every entry is checked value-level against
the two headline theorems — `getAmountOut_lt_reserveOut` (no-drain:
`expectedOut < reserveOut`) and `k_nondecreasing` (the constant product never
decreases) — and both theorems are bound term-level for API stability.  Inputs
are bounded so the Solidity `uint256` arithmetic never overflows (it reverts on
overflow, the Lean `Nat` does not), so on this realistic domain the two are
bit-identical.
-/

import LegalKernel.Bridge.AmmMath
import LegalKernel.Test.Framework
import LegalKernel.Test.Bridge.CrossCheck.Framework

namespace LegalKernel.Test.Bridge.CrossCheck
namespace AmmMathCrossCheck

open LegalKernel.Bridge.AmmMath
open LegalKernel.Test

/-- One corpus entry: the four `getAmountOut` inputs plus the Lean-computed
    output the Solidity consumer must reproduce. -/
structure Entry where
  /-- Human-readable category tag (for drift diagnostics). -/
  category   : String
  /-- The input amount supplied. -/
  amountIn   : Nat
  /-- The input asset's reserve. -/
  reserveIn  : Nat
  /-- The output asset's reserve. -/
  reserveOut : Nat
  /-- The swap fee in basis points. -/
  feeBps     : Nat
  /-- Lean's `getAmountOut amountIn reserveIn reserveOut feeBps`. -/
  expectedOut : Nat

/-- Build an `Entry`, computing `expectedOut` via the Lean `getAmountOut`. -/
def mkEntry (amountIn reserveIn reserveOut feeBps : Nat) (category : String) : Entry :=
  { category, amountIn, reserveIn, reserveOut, feeBps,
    expectedOut := getAmountOut amountIn reserveIn reserveOut feeBps }

/-- `10^18` (one ether / one BOLD-wei). -/
def e18 : Nat := 1000000000000000000
/-- `10^9` (one gwei). -/
def e9 : Nat := 1000000000
/-- `10^30` (a large-but-non-overflowing reserve scale). -/
def e30 : Nat := 1000000000000000000000000000000
/-- `10^27` (a large-but-`uint256`-safe input amount). -/
def e27 : Nat := 1000000000000000000000000000

/-- Grid input sets (all valid: `amountIn > 0`, reserves `> 0`, `feeBps <
    10000`; bounded so the EVM `uint256` products never overflow). -/
def amounts  : List Nat := [1, e9, e18]
/-- Reserve scales: a small pool, an ether-scale pool, and the realistic
    ~1 ETH : 3000 BOLD shape (40 ETH / 120000 BOLD). -/
def reservesA : List Nat := [1000, e18, 40 * e18, 120000 * e18]
/-- Fee points: zero, the production 0.30%, a 1% fee, and just below 100%. -/
def fees : List Nat := [0, 30, 100, 5000]

/-- The cartesian-product grid (`3 × 4 × 4 × 4 = 192` entries).  The amount
    outermost / fee innermost order keeps the listing deterministic. -/
def gridEntries : List Entry :=
  amounts.flatMap (fun a =>
    reservesA.flatMap (fun rI =>
      reservesA.flatMap (fun rO =>
        fees.map (fun f =>
          mkEntry a rI rO f s!"grid:a{a}-rI{rI}-rO{rO}-f{f}"))))

/-- Hand-picked corner cases (boundaries the grid does not hit). -/
def cornerEntries : List Entry :=
  [ mkEntry 1000 1000 1000 0    "corner:handvector-noFee-500"
  , mkEntry 1000 1000 1000 30   "corner:handvector-fee30-499"
  , mkEntry 1000 1000 1000 9999 "corner:fee-just-below-100pct"
  , mkEntry 1 1 2 0             "corner:tiny-pool"
  , mkEntry 1 (40 * e18) (120000 * e18) 30 "corner:dust-eth-in"
  , mkEntry 1 (120000 * e18) (40 * e18) 30 "corner:dust-bold-floors-to-zero"
  , mkEntry e18 (40 * e18) (120000 * e18) 30 "corner:1eth-to-bold"
  , mkEntry (3000 * e18) (120000 * e18) (40 * e18) 30 "corner:3000bold-to-eth"
  , mkEntry e27 e30 e30 30     "corner:huge-in-large-pool"
  , mkEntry e30 e30 e30 30     "corner:max-scale-symmetric"
  , mkEntry e18 (1000 * e18) e18 5000 "corner:high-fee-asymmetric"
  , mkEntry e9 e18 (40 * e18) 0 "corner:zero-fee-gwei" ]

/-- The full corpus. -/
def entries : List Entry := gridEntries ++ cornerEntries

/-- Serialise one entry: big values as 32-byte BE hex strings (read on the
    Solidity side via `vm.parseJsonBytes32`), `feeBps` as a small JSON number. -/
def entryJson (e : Entry) : Json :=
  Json.obj
    [ ("category",   Json.str e.category)
    , ("amountIn",   Json.str (hexFromUint256BE e.amountIn))
    , ("reserveIn",  Json.str (hexFromUint256BE e.reserveIn))
    , ("reserveOut", Json.str (hexFromUint256BE e.reserveOut))
    , ("feeBps",     Json.num e.feeBps)
    , ("expectedOut", Json.str (hexFromUint256BE e.expectedOut)) ]

/-- The whole fixture: a header (count + the BPS denominator + the production
    fee) and the per-entry array. -/
def buildJson : Json :=
  Json.obj
    [ ("header", Json.obj
        [ ("workstream", Json.str "GP.11.3")
        , ("count", Json.num entries.length)
        , ("bpsDenominator", Json.num bpsDenominator)
        , ("ammSwapFeeBps", Json.num 30) ])
    , ("entries", Json.arr (entries.map entryJson)) ]

/-- The fixture file name. -/
def fixtureName : String := "amm_getamountout.json"

/-- Tests: generate (or byte-verify) the fixture, the proof-carrying per-entry
    k-monotonicity + no-drain checks, and term-level theorem API stability. -/
def tests : List TestCase :=
  [ { name := "GP.11.3: AmmMath getAmountOut cross-stack fixture write/verify"
    , body := do
        writeFixture fixtureName buildJson.encode
    }
  , { name := "GP.11.3: every corpus entry is valid, no-drain, and k-monotonic"
    , body := do
        for e in entries do
          -- Validity (every entry is valid by construction).
          unless 0 < e.amountIn ∧ 0 < e.reserveIn ∧ 0 < e.reserveOut
              ∧ e.feeBps < bpsDenominator do
            throw <| IO.userError s!"invalid entry: {e.category}"
          -- No-drain (the `getAmountOut_lt_reserveOut` theorem, value-checked).
          unless e.expectedOut < e.reserveOut do
            throw <| IO.userError s!"no-drain violated: {e.category}"
          -- k-monotonicity (the `k_nondecreasing` theorem, value-checked on
          -- the exact corpus entry the Solidity consumes).
          unless e.reserveIn * e.reserveOut
              ≤ (e.reserveIn + e.amountIn) * (e.reserveOut - e.expectedOut) do
            throw <| IO.userError s!"k decreased: {e.category}"
    }
  , { name := "GP.11.3: the corpus matches the hand-computed ground truth"
    , body := do
        assertEq (expected := 500) (actual := getAmountOut 1000 1000 1000 0)
          "getAmountOut 1000 1000 1000 0"
        assertEq (expected := 499) (actual := getAmountOut 1000 1000 1000 30)
          "getAmountOut 1000 1000 1000 30"
    }
  , { name := "GP.11.3: getAmountOut_lt_reserveOut + k_nondecreasing API stability"
    , body := do
        -- Term-level bindings: the corpus is generated under these theorems,
        -- so a signature change fails elaboration here.
        let _noDrain : getAmountOut 1 1000 1000 30 < 1000 :=
          getAmountOut_lt_reserveOut (by omega) (by omega) (by decide)
        let _kMono : (1000 : Nat) * 1000
              ≤ (1000 + 1) * (1000 - getAmountOut 1 1000 1000 30) :=
          k_nondecreasing (by omega) (by omega) (by decide)
        pure ()
    }
  ]

end AmmMathCrossCheck
end LegalKernel.Test.Bridge.CrossCheck
