-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.AmmMath — Workstream GP.11.3 test suite.

Exercises the Lean AMM swap-math spec (`LegalKernel/Bridge/AmmMath.lean`)
that mirrors `solidity/src/lib/AmmMath.sol`'s `getAmountOut`.  Coverage:

  * **Value-level cross-stack vectors.**  The same hand-computed
    `getAmountOut` outputs the Solidity `test/AmmMath.t.sol` pins
    (`getAmountOut(1000,1000,1000,0) == 500`,
    `getAmountOut(1000,1000,1000,30) == 499`, the asymmetric
    1e18/1e20/3e23 vector, and the fee-reduces-output pair), so
    Lean-spec == Solidity-formula == ground truth.
  * **k grows under a fee.**  `getAmountOut(1000,1000,1000,30) == 499`
    and `(1000+1000)*(1000-499) > 1000*1000`, the value-level witness
    of the `k_nondecreasing` invariant at a concrete point.
  * **Term-level API stability** for both headline theorems
    (`getAmountOut_lt_reserveOut`, `k_nondecreasing`): each binding's
    type uses the theorem's exact signature, so a signature change
    fails elaboration before the `IO Unit` body runs.
-/

import LegalKernel.Bridge.AmmMath
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge
namespace AmmMathTests

open LegalKernel.Test
open LegalKernel.Bridge.AmmMath

/-- Tests for `LegalKernel.Bridge.AmmMath`. -/
def tests : List TestCase :=
  [ -- ## Value-level cross-stack vectors (mirror solidity/test/AmmMath.t.sol)
    { name := "getAmountOut(1000,1000,1000,0) == 500 (zero-fee, k preserved)"
    , body := do
        assertEq (expected := 500) (actual := getAmountOut 1000 1000 1000 0)
          "getAmountOut 1000 1000 1000 0"
        -- zero fee preserves k exactly: (1000+1000)*(1000-500) == 1000*1000
        assertEq (expected := 1000 * 1000) (actual := (1000 + 1000) * (1000 - 500))
          "k preserved at zero fee"
    }
  , { name := "getAmountOut(1000,1000,1000,30) == 499 (0.30% fee, k grows)"
    , body := do
        assertEq (expected := 499) (actual := getAmountOut 1000 1000 1000 30)
          "getAmountOut 1000 1000 1000 30"
        -- a non-zero fee makes k strictly grow: 2000*501 = 1_002_000 > 1_000_000
        assertEq (expected := 1002000) (actual := (1000 + 1000) * (1000 - 499))
          "fee grows k to 1_002_000"
        assert (decide (1000 * 1000 < (1000 + 1000) * (1000 - 499)))
          "k strictly increased under a 0.30% fee"
    }
  , { name := "getAmountOut asymmetric vector (1e18 in, 1e20 / 3e23 reserves)"
    , body := do
        -- reserveIn = 100 ether = 1e20, reserveOut = 300_000 ether = 3e23,
        -- amountIn = 1 ether = 1e18, fee = 30 bps.  Closed-form value
        -- recomputed independently against the same formula.
        assertEq (expected := 2961474103191183896551)
          (actual := getAmountOut 1000000000000000000 100000000000000000000
                       300000000000000000000000 30)
          "asymmetric vector matches the closed form"
    }
  , { name := "getAmountOut: a fee reduces the output (5000 in, 100k/100k pool)"
    , body := do
        let noFee  := getAmountOut 5000 100000 100000 0
        let withFee := getAmountOut 5000 100000 100000 30
        assertEq (expected := 4761) (actual := noFee)  "no-fee output"
        assertEq (expected := 4748) (actual := withFee) "with-fee output"
        assert (decide (withFee ≤ noFee)) "fee never increases the output"
    }
  , -- ## Term-level API stability for the headline theorems
    { name := "API: getAmountOut_lt_reserveOut signature stable"
    , body := do
        -- The ascribed type uses the theorem's exact signature; a
        -- signature change fails elaboration here.
        let _h : getAmountOut 100 1000 1000 30 < 1000 :=
          getAmountOut_lt_reserveOut (by omega) (by omega) (by decide)
        pure ()
    }
  , { name := "API: k_nondecreasing signature stable"
    , body := do
        let _h : 1000 * 1000
                  ≤ (1000 + 100) * (1000 - getAmountOut 100 1000 1000 30) :=
          k_nondecreasing (by omega) (by omega) (by decide)
        pure ()
    }
  ]

end AmmMathTests
end LegalKernel.Test.Bridge
