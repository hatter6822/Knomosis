// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title AmmMath
/// @notice Pure constant-product (Uniswap v2-style) swap math for the
///         embedded ETH<->BOLD AMM (Workstream GP.11.3).  A swap fee in
///         basis points is RETAINED in the reserves: only
///         `amountIn * (10000 - feeBps)` participates in the curve, while
///         the full `amountIn` is added to the input reserve.  This makes
///         the product `k = reserveIn * reserveOut` monotonically
///         non-decreasing across swaps (strictly increasing for a non-zero
///         fee and a non-zero input), so the fee accrues to the pool as LP
///         yield for the gas pool (the sole liquidity provider).
///
/// @dev    Every function is `pure` and `internal`, so it inlines into the
///         caller at compile time — no external library deployment, no
///         delegatecall, no linking.  All arithmetic is CHECKED (Solidity
///         0.8 default): for any realistic reserve / amount (bounded by a
///         deployment's TVL, far below `uint256.max`) no operation
///         overflows, and a hypothetical overflow reverts rather than
///         wrapping.  The library validates its OWN inputs (defence in
///         depth) so it is a faithful, self-contained reference even though
///         `KnomosisBridge.ammSwap` pre-validates before every call.
library AmmMath {
    /// @notice Basis-points denominator (100% == 10000 bps).  A `feeBps`
    ///         argument is interpreted as a fraction of this.
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Thrown when an input amount is zero (`getAmountOut`) or a
    ///         requested output amount is zero (`getAmountIn`).  A swap
    ///         must move a positive quantity in each direction.
    error AmmMathInsufficientInput();

    /// @notice Thrown when a reserve is zero (the curve is undefined on an
    ///         unseeded pool) or, in `getAmountIn`, when the requested
    ///         output is not strictly less than the output reserve (the
    ///         constant-product curve can never deliver `>= reserveOut`).
    error AmmMathInsufficientLiquidity();

    /// @notice Thrown when `feeBps >= BPS_DENOMINATOR` (a fee of 100% or
    ///         more would leave no input to swap and break the curve).
    error AmmMathFeeTooHigh();

    /// @notice Constant-product output for supplying `amountIn` of the
    ///         input asset into a pool of `(reserveIn, reserveOut)`, net of
    ///         a `feeBps` swap fee retained in the pool.
    ///
    ///         Uniswap v2 formula:
    ///           amountInWithFee = amountIn * (10000 - feeBps)
    ///           numerator       = amountInWithFee * reserveOut
    ///           denominator     = reserveIn * 10000 + amountInWithFee
    ///           amountOut       = floor(numerator / denominator)
    ///
    /// @param  amountIn    The input amount the caller supplies (> 0).
    /// @param  reserveIn   The input asset's reserve before the swap (> 0).
    /// @param  reserveOut  The output asset's reserve before the swap (> 0).
    /// @param  feeBps      The swap fee in basis points (`< 10000`).
    /// @return amountOut   The output amount, floored.  Guaranteed
    ///                     `amountOut < reserveOut` strictly (so the pool
    ///                     can never be drained to zero by a swap): because
    ///                     `amountInWithFee > 0` and `reserveIn > 0`, the
    ///                     denominator strictly exceeds `amountInWithFee`,
    ///                     hence `numerator < denominator * reserveOut`.
    /// @dev    The flooring rounds the output DOWN, which can only make
    ///         `k = reserveIn * reserveOut` increase (less leaves the pool),
    ///         never decrease — the formal basis for the k-monotonicity
    ///         invariant.  See `KnomosisBridge.ammSwap`'s on-chain
    ///         belt-and-braces k-check and `AmmInvariants.t.sol`.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert AmmMathInsufficientInput();
        if (reserveIn == 0 || reserveOut == 0) revert AmmMathInsufficientLiquidity();
        if (feeBps >= BPS_DENOMINATOR) revert AmmMathFeeTooHigh();

        uint256 amountInWithFee = amountIn * (BPS_DENOMINATOR - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BPS_DENOMINATOR + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Inverse of `getAmountOut`: the minimum input that yields at
    ///         least `amountOut` of the output asset, net of the `feeBps`
    ///         fee.  Rounds UP (the trailing `+ 1`) so the returned input is
    ///         never an under-estimate — a caller that supplies exactly this
    ///         amount receives AT LEAST `amountOut`.
    ///
    ///         Uniswap v2 formula:
    ///           numerator   = reserveIn * amountOut * 10000
    ///           denominator = (reserveOut - amountOut) * (10000 - feeBps)
    ///           amountIn    = floor(numerator / denominator) + 1
    ///
    /// @param  amountOut   The desired output amount (`0 < amountOut < reserveOut`).
    /// @param  reserveIn   The input asset's reserve before the swap (> 0).
    /// @param  reserveOut  The output asset's reserve before the swap (> 0).
    /// @param  feeBps      The swap fee in basis points (`< 10000`).
    /// @return amountIn    The minimum input (rounded up) for `amountOut`.
    /// @dev    Provided for completeness / symmetry (the standard Uniswap v2
    ///         pair) and exercised by `AmmMath.t.sol`'s round-trip tests;
    ///         `KnomosisBridge.ammSwap` uses only `getAmountOut`.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert AmmMathInsufficientInput();
        if (reserveIn == 0 || reserveOut == 0) revert AmmMathInsufficientLiquidity();
        if (amountOut >= reserveOut) revert AmmMathInsufficientLiquidity();
        if (feeBps >= BPS_DENOMINATOR) revert AmmMathFeeTooHigh();

        uint256 numerator = reserveIn * amountOut * BPS_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * (BPS_DENOMINATOR - feeBps);
        amountIn = (numerator / denominator) + 1;
    }
}
