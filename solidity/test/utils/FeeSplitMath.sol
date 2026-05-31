// SPDX-License-Identifier: GPL-3.0-or-later
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
///         constant is a mirrored literal (a contract's public constant
///         is not reachable via the type name from another file); both
///         test suites assert it equals the deployed
///         `KnomosisBridge.MAX_BUDGET_PER_DEPOSIT` getter and the Lean
///         fixture header, so any drift fails loudly.
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
    /// @dev    `feeBps` and `weiPerBudgetUnit` are taken as `uint256`
    ///         (rather than the contract's `uint16` / `uint64`) so call
    ///         sites that parse JSON values can pass them without a
    ///         narrowing cast — the arithmetic is value-identical.
    ///         Caller must ensure `feeBps <= 10000` (so `poolAmount <=
    ///         v` and the subtraction does not underflow) and
    ///         `weiPerBudgetUnit >= 1` (so the division is defined).
    ///         Both hold for every admissible on-chain call: the
    ///         contract rejects `feeBps > maxFeeBps <= MAX_FEE_BPS_CAP
    ///         = 5000` and rejects `weiPerBudgetUnit = 0` at
    ///         construction.  `budgetGrant` is returned as `uint64`
    ///         (the contract's type and the event field width).
    function split(uint256 v, uint256 feeBps, uint256 weiPerBudgetUnit)
        internal
        pure
        returns (uint256 userAmount, uint256 poolAmount, uint64 budgetGrant)
    {
        poolAmount = (v * feeBps) / 10_000;
        userAmount = v - poolAmount;
        uint256 raw = poolAmount / weiPerBudgetUnit;
        // casting to `uint64` is safe: the ternary takes this branch
        // only when raw <= MAX_BUDGET_PER_DEPOSIT = 10^12 < 2^63.
        // forge-lint: disable-next-line(unsafe-typecast)
        budgetGrant = raw > uint256(MAX_BUDGET_PER_DEPOSIT) ? MAX_BUDGET_PER_DEPOSIT : uint64(raw);
    }

    /// @notice Recompute the canonical fee-split `receiptHash`.
    ///         Mirrors `KnomosisBridge._registerDepositWithFee`.
    /// @dev    `resourceId`, `budgetGrant`, and `nonce` are taken as
    ///         `uint256` (the contract uses `uint64`).  ABI-encoding an
    ///         integer `< 2^64` as `uint256` yields the identical
    ///         32-byte word the contract's `uint64` `abi.encode`
    ///         produces, so the hash is byte-equal; widening lets call
    ///         sites avoid narrowing casts.
    function receiptHash(
        bytes32 deploymentId,
        address sender,
        uint256 resourceId,
        address token,
        uint256 userAmount,
        uint256 poolAmount,
        uint256 budgetGrant,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                deploymentId, sender, resourceId, token, userAmount, poolAmount, budgetGrant, nonce
            )
        );
    }
}
