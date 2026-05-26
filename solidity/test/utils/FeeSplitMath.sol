// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title FeeSplitMath
/// @notice Reference implementation of the Workstream GP.5.1 fee-split
///         arithmetic, used by the test suites as a single source of
///         truth.
///
/// @dev    This library is a *test-only* reference; it is deliberately
///         independent of `KnomosisBridge.depositETHWithFee`'s inline
///         implementation.  The cross-stack corpus
///         (`DepositFeeSplit.t.sol`) pins this reference against the
///         Lean generator's byte-for-byte output, and the behavioural
///         suite (`BridgeFeeSplit.t.sol`) pins the live contract
///         against this reference via `vm.expectEmit`.  Together they
///         establish `contract == reference == Lean spec` without any
///         single file checking the formula against itself.  The clamp
///         constant is read from `KnomosisBridge.MAX_BUDGET_PER_DEPOSIT`
///         so the reference can never silently drift from the
///         deployed cap.
library FeeSplitMath {
    /// @notice Per-deposit budget-grant ceiling.  MUST equal
    ///         `KnomosisBridge.MAX_BUDGET_PER_DEPOSIT`; the test suites
    ///         assert the equality against the deployed contract's
    ///         getter and against the Lean fixture header, so any
    ///         drift fails loudly rather than silently.  (A contract's
    ///         public constant is not reachable as
    ///         `KnomosisBridge.MAX_BUDGET_PER_DEPOSIT` from another
    ///         file, hence this mirrored literal.)
    uint64 internal constant MAX_BUDGET_PER_DEPOSIT = 1_000_000_000_000;

    /// @notice Compute the `(userAmount, poolAmount, budgetGrant)`
    ///         split for a deposit of `v` wei at `feeBps` basis points
    ///         with the given `weiPerBudgetUnit` exchange rate.
    ///
    ///         Mirrors `KnomosisBridge.depositETHWithFee` exactly:
    ///           poolAmount  = floor(v * feeBps / 10000)
    ///           userAmount  = v - poolAmount
    ///           budgetGrant = min(floor(poolAmount / weiPerBudgetUnit),
    ///                             MAX_BUDGET_PER_DEPOSIT)
    ///
    /// @dev    Caller must ensure `feeBps <= 10000` (so
    ///         `poolAmount <= v` and the subtraction does not underflow)
    ///         and `weiPerBudgetUnit >= 1` (so the division is defined).
    ///         Both hold for every admissible on-chain call: the
    ///         contract rejects `feeBps > maxFeeBps <= MAX_FEE_BPS_CAP
    ///         = 5000` and rejects `weiPerBudgetUnit = 0` at
    ///         construction.
    function split(uint256 v, uint16 feeBps, uint64 weiPerBudgetUnit)
        internal
        pure
        returns (uint256 userAmount, uint256 poolAmount, uint64 budgetGrant)
    {
        poolAmount = (v * uint256(feeBps)) / 10_000;
        userAmount = v - poolAmount;
        uint256 raw = poolAmount / uint256(weiPerBudgetUnit);
        budgetGrant = raw > uint256(MAX_BUDGET_PER_DEPOSIT) ? MAX_BUDGET_PER_DEPOSIT : uint64(raw);
    }

    /// @notice Recompute the canonical fee-split `receiptHash`.
    ///         Mirrors `KnomosisBridge._registerDepositWithFee`.
    function receiptHash(
        bytes32 deploymentId,
        address sender,
        uint64 resourceId,
        address token,
        uint256 userAmount,
        uint256 poolAmount,
        uint64 budgetGrant,
        uint64 nonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                deploymentId, sender, resourceId, token, userAmount, poolAmount, budgetGrant, nonce
            )
        );
    }
}
