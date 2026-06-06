// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AmmMath} from "src/lib/AmmMath.sol";

/// @title AmmMathHarness
/// @notice External shim over the `internal` `AmmMath` library, so the
///         library's revert paths are reachable through a real CALL (and
///         thus observable by `vm.expectRevert`).  The math is identical;
///         only the call boundary differs.
contract AmmMathHarness {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        external
        pure
        returns (uint256)
    {
        return AmmMath.getAmountOut(amountIn, reserveIn, reserveOut, feeBps);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        external
        pure
        returns (uint256)
    {
        return AmmMath.getAmountIn(amountOut, reserveIn, reserveOut, feeBps);
    }
}

/// @title AmmMathTest
/// @notice Workstream GP.11.3.a — the pure constant-product (Uniswap
///         v2-style) swap-math library backing `KnomosisBridge.ammSwap`.
///
/// @dev    Three property layers:
///           1. exact hand-computed vectors (non-circular ground truth);
///           2. structural guarantees the contract relies on
///              (`amountOut < reserveOut`, the fee reduces output,
///              monotonicity in `amountIn`, the `getAmountIn` round-trip);
///           3. the headline k-monotonicity invariant under fuzzed inputs.
contract AmmMathTest is Test {
    /// @dev The production swap fee (0.30%); mirrors
    ///      `KnomosisBridge.AMM_SWAP_FEE_BPS`.
    uint256 private constant FEE = 30;
    uint256 private constant BPS = 10_000;

    AmmMathHarness private h;

    function setUp() public {
        h = new AmmMathHarness();
    }

    // ------------------------------------------------------------------
    // Exact hand-computed vectors (ground truth, no contract dependency)
    // ------------------------------------------------------------------

    /// @notice With no fee, adding `amountIn == reserveIn` to a balanced
    ///         1000/1000 pool returns exactly 500, leaving 2000/500 with the
    ///         product k = 1_000_000 unchanged (the constant-product
    ///         identity at the zero-fee boundary).
    function test_getAmountOut_exact_noFee() public view {
        uint256 out = h.getAmountOut(1000, 1000, 1000, 0);
        assertEq(out, 500, "getAmountOut(1000,1000,1000,0) == 500");
        // k is exactly preserved at the zero-fee boundary.
        assertEq((1000 + 1000) * (1000 - out), 1000 * 1000, "k preserved at zero fee");
    }

    /// @notice The same swap at the 0.30% production fee returns 499 — one
    ///         less than the zero-fee output — and the retained fee lifts k
    ///         from 1_000_000 to 1_002_000 (2000 * 501).
    function test_getAmountOut_exact_withFee() public view {
        uint256 out = h.getAmountOut(1000, 1000, 1000, FEE);
        assertEq(out, 499, "getAmountOut(1000,1000,1000,30) == 499");
        assertEq((1000 + 1000) * (1000 - out), 1_002_000, "fee grows k to 1_002_000");
        assertGt((1000 + 1000) * (1000 - out), 1000 * 1000, "k strictly grows with the fee");
    }

    /// @notice A second exact vector at an asymmetric pool: a 1 ETH swap
    ///         into a 100/300000 (ETH/BOLD) pool at the 0.30% fee.
    ///         amountInWithFee = 1e18 * 9970 = 9.97e21;
    ///         numerator       = 9.97e21 * 3e23 = 2.991e45;
    ///         denominator     = 1e20 * 1e4 + 9.97e21 = 1.0097e24;
    ///         amountOut       = floor(2.991e45 / 1.0097e24).
    function test_getAmountOut_exact_asymmetric() public view {
        uint256 reserveIn = 100 ether; // 1e20
        uint256 reserveOut = 300_000 ether; // 3e23
        uint256 amountIn = 1 ether; // 1e18
        uint256 out = h.getAmountOut(amountIn, reserveIn, reserveOut, FEE);

        uint256 amountInWithFee = amountIn * (BPS - FEE);
        uint256 expected = (amountInWithFee * reserveOut) / (reserveIn * BPS + amountInWithFee);
        assertEq(out, expected, "asymmetric vector matches the closed form");
        assertLt(out, reserveOut, "output strictly below the output reserve");
    }

    // ------------------------------------------------------------------
    // Structural guarantees the contract depends on
    // ------------------------------------------------------------------

    /// @notice `amountOut < reserveOut` strictly for a battery of inputs —
    ///         the curve can never be drained to (or past) zero.
    function test_getAmountOut_strictlyBelowReserveOut() public view {
        // A near-infinite input still cannot reach the output reserve.
        assertLt(h.getAmountOut(type(uint128).max, 1, 1_000_000, FEE), 1_000_000, "huge in < reserveOut");
        assertLt(h.getAmountOut(1, 1, 2, FEE), 2, "tiny pool");
        assertLt(h.getAmountOut(1_000_000, 1, 1_000_000, 0), 1_000_000, "zero fee, huge in");
    }

    /// @notice The fee never increases the output: at equal inputs, a higher
    ///         fee yields no more than a lower fee.
    function test_getAmountOut_feeReducesOutput() public view {
        uint256 noFee = h.getAmountOut(5000, 100_000, 100_000, 0);
        uint256 withFee = h.getAmountOut(5000, 100_000, 100_000, FEE);
        assertLe(withFee, noFee, "the fee cannot increase the output");
        assertGt(noFee, 0, "sanity: a real swap moves value");
    }

    /// @notice Output is monotone non-decreasing in `amountIn`.
    function test_getAmountOut_monotonicInAmountIn() public view {
        uint256 small = h.getAmountOut(1000, 50_000, 50_000, FEE);
        uint256 large = h.getAmountOut(2000, 50_000, 50_000, FEE);
        assertGe(large, small, "more input never yields less output");
    }

    // ------------------------------------------------------------------
    // getAmountOut revert paths (via the external harness)
    // ------------------------------------------------------------------

    function test_getAmountOut_revertsZeroInput() public {
        vm.expectRevert(AmmMath.AmmMathInsufficientInput.selector);
        h.getAmountOut(0, 1000, 1000, FEE);
    }

    function test_getAmountOut_revertsZeroReserveIn() public {
        vm.expectRevert(AmmMath.AmmMathInsufficientLiquidity.selector);
        h.getAmountOut(100, 0, 1000, FEE);
    }

    function test_getAmountOut_revertsZeroReserveOut() public {
        vm.expectRevert(AmmMath.AmmMathInsufficientLiquidity.selector);
        h.getAmountOut(100, 1000, 0, FEE);
    }

    function test_getAmountOut_revertsFeeAtDenominator() public {
        vm.expectRevert(AmmMath.AmmMathFeeTooHigh.selector);
        h.getAmountOut(100, 1000, 1000, BPS); // feeBps == 10000 (100%)
    }

    function test_getAmountOut_revertsFeeAboveDenominator() public {
        vm.expectRevert(AmmMath.AmmMathFeeTooHigh.selector);
        h.getAmountOut(100, 1000, 1000, BPS + 1);
    }

    // ------------------------------------------------------------------
    // getAmountIn (the inverse) — exact vector, round-trip, revert paths
    // ------------------------------------------------------------------

    /// @notice `getAmountIn(500, 1000, 1000, 0) == 1001` (the round-up `+1`
    ///         over the closed-form 1000).
    function test_getAmountIn_exact_noFee() public view {
        assertEq(h.getAmountIn(500, 1000, 1000, 0), 1001, "getAmountIn rounds up to 1001");
    }

    /// @notice Supplying `getAmountIn(out)` as the input yields AT LEAST
    ///         `out` (the round-up guarantees no under-delivery).
    function test_getAmountIn_roundTrip() public view {
        uint256 desiredOut = 4321;
        uint256 reserveIn = 1_000_000;
        uint256 reserveOut = 2_000_000;
        uint256 amountIn = h.getAmountIn(desiredOut, reserveIn, reserveOut, FEE);
        uint256 actualOut = h.getAmountOut(amountIn, reserveIn, reserveOut, FEE);
        assertGe(actualOut, desiredOut, "round-trip delivers at least the desired output");
    }

    function test_getAmountIn_revertsZeroOutput() public {
        vm.expectRevert(AmmMath.AmmMathInsufficientInput.selector);
        h.getAmountIn(0, 1000, 1000, FEE);
    }

    function test_getAmountIn_revertsZeroReserve() public {
        vm.expectRevert(AmmMath.AmmMathInsufficientLiquidity.selector);
        h.getAmountIn(100, 0, 1000, FEE);
    }

    function test_getAmountIn_revertsOutputExceedsReserve() public {
        // amountOut == reserveOut is unreachable by the curve.
        vm.expectRevert(AmmMath.AmmMathInsufficientLiquidity.selector);
        h.getAmountIn(1000, 1000, 1000, FEE);
    }

    function test_getAmountIn_revertsFeeTooHigh() public {
        vm.expectRevert(AmmMath.AmmMathFeeTooHigh.selector);
        h.getAmountIn(100, 1000, 2000, BPS);
    }

    // ------------------------------------------------------------------
    // Fuzz — the headline k-monotonicity invariant + structural bounds
    // ------------------------------------------------------------------

    /// @notice For ANY valid (amountIn, reserveIn, reserveOut, feeBps),
    ///         `(reserveIn + amountIn) * (reserveOut - amountOut) >=
    ///          reserveIn * reserveOut` — the constant product never
    ///         decreases.  Inputs bounded to 1e30 so the post-swap product
    ///         (~1e60) stays well below `uint256.max`.
    function testFuzz_kMonotonicity(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint16 feeBps)
        public
        view
    {
        amountIn = bound(amountIn, 1, 1e30);
        reserveIn = bound(reserveIn, 1, 1e30);
        reserveOut = bound(reserveOut, 1, 1e30);
        uint256 fee = bound(uint256(feeBps), 0, BPS - 1);

        uint256 amountOut = h.getAmountOut(amountIn, reserveIn, reserveOut, fee);
        assertLt(amountOut, reserveOut, "fuzz: output strictly below reserveOut");

        uint256 kBefore = reserveIn * reserveOut;
        uint256 kAfter = (reserveIn + amountIn) * (reserveOut - amountOut);
        assertGe(kAfter, kBefore, "fuzz: k is monotonically non-decreasing");
    }

    /// @notice For a non-zero fee and a non-trivial swap (one that produces a
    ///         positive output), k STRICTLY increases — the fee genuinely
    ///         accrues to the pool.
    function testFuzz_kStrictlyGrowsWithFee(uint256 amountIn, uint256 reserve) public view {
        reserve = bound(reserve, 1e6, 1e30);
        // An input large enough that the floored output is positive.
        amountIn = bound(amountIn, reserve / 1000 + 1, 1e30);

        uint256 amountOut = h.getAmountOut(amountIn, reserve, reserve, FEE);
        vm.assume(amountOut > 0);

        uint256 kBefore = reserve * reserve;
        uint256 kAfter = (reserve + amountIn) * (reserve - amountOut);
        assertGt(kAfter, kBefore, "fuzz: a non-trivial fee'd swap strictly grows k");
    }

    /// @notice `getAmountIn` round-trip under fuzzing: the rounded-up input
    ///         always delivers at least the requested output.
    /// @dev    `desiredOut` is bounded to AT MOST half the output reserve, and
    ///         the reserves to 1e24.  As `desiredOut -> reserveOut` the
    ///         required input diverges to infinity (the curve's asymptote), so
    ///         a near-`reserveOut` request would make the round-trip's
    ///         intermediate `getAmountOut(getAmountIn(...))` product overflow
    ///         `uint256` — a test-arithmetic limit, not a contract behaviour
    ///         (no real caller requests ~100% of a reserve, whose price is
    ///         unbounded).  The bound keeps every intermediate well below
    ///         `uint256.max` while still spanning a wide realistic regime.
    function testFuzz_getAmountIn_roundTrip(uint256 desiredOut, uint256 reserveIn, uint256 reserveOut)
        public
        view
    {
        reserveOut = bound(reserveOut, 2, 1e24);
        // desiredOut at most half the output reserve (keeps getAmountIn finite).
        desiredOut = bound(desiredOut, 1, reserveOut / 2);
        reserveIn = bound(reserveIn, 1, 1e24);

        uint256 amountIn = h.getAmountIn(desiredOut, reserveIn, reserveOut, FEE);
        uint256 actualOut = h.getAmountOut(amountIn, reserveIn, reserveOut, FEE);
        assertGe(actualOut, desiredOut, "fuzz: round-trip never under-delivers");
    }
}
