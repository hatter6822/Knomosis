// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {MockBold} from "test/utils/MockBold.sol";
import {AmmTestBase} from "test/utils/AmmTestBase.sol";

/// @title AmmSlippageTest
/// @notice Workstream GP.11.3.g — `ammSwap` slippage (`minAmountOut`) and
///         `deadline` protection: exact boundaries on both, the
///         disable-with-zero case, and realistic protection scenarios.
contract AmmSlippageTest is AmmTestBase {
    // ------------------------------------------------------------------
    // Slippage (minAmountOut)
    // ------------------------------------------------------------------

    /// @notice `minAmountOut == amountOut` succeeds (the check is strict
    ///         `<`, so the exact output is acceptable).
    function test_slippage_exactMinMet_succeeds() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);
        uint256 amountIn = 1 ether;
        uint256 expectedOut = _refOut(amountIn, rEth, rBold);

        vm.prank(swapper);
        uint256 out = bridge.ammSwap{value: amountIn}(NATIVE_ETH, amountIn, expectedOut, _farDeadline());
        assertEq(out, expectedOut, "exact-min swap returns the expected output");
    }

    /// @notice `minAmountOut == amountOut + 1` reverts `SlippageExceeded`
    ///         carrying both the actual and the requested minimum.
    function test_slippage_oneWeiAboveOutput_reverts() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);
        uint256 amountIn = 1 ether;
        uint256 expectedOut = _refOut(amountIn, rEth, rBold);

        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.SlippageExceeded.selector, expectedOut, expectedOut + 1)
        );
        vm.prank(swapper);
        bridge.ammSwap{value: amountIn}(NATIVE_ETH, amountIn, expectedOut + 1, _farDeadline());
    }

    /// @notice `minAmountOut == 0` disables slippage protection: any positive
    ///         output is accepted (the arbitrage-bot escape hatch).
    function test_slippage_zeroMin_disablesProtection() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        vm.prank(swapper);
        uint256 out = bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
        assertGt(out, 0, "zero-min swap accepts any positive output");
    }

    /// @notice An unrealistically high `minAmountOut` (more than the pool can
    ///         deliver) reverts — slippage genuinely protects the caller.
    function test_slippage_unrealisticMin_reverts() public {
        KnomosisBridge bridge = _deploySeededReady();
        (, uint256 rBold) = _seedBothLegs(bridge);
        // Demand the entire BOLD reserve from a 1 ETH input — impossible.
        vm.expectRevert(); // SlippageExceeded(actual, rBold)
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, rBold, _farDeadline());
    }

    /// @notice Slippage protection on the BOLD->ETH direction too.
    function test_slippage_boldToEth_reverts() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);
        uint256 amountIn = 3000 ether;
        uint256 expectedOut = _refOut(amountIn, rBold, rEth);
        _mintApprove(bridge, swapper, amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.SlippageExceeded.selector, expectedOut, expectedOut + 1)
        );
        vm.prank(swapper);
        bridge.ammSwap(BOLD_RID, amountIn, expectedOut + 1, _farDeadline());
    }

    // ------------------------------------------------------------------
    // Deadline
    // ------------------------------------------------------------------

    /// @notice `deadline == block.timestamp` succeeds (the check is strict
    ///         `>`, so a swap landing exactly on its deadline is valid).
    function test_deadline_exactBoundary_succeeds() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        vm.warp(1_000_000);
        vm.prank(swapper);
        uint256 out = bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, block.timestamp);
        assertGt(out, 0, "swap on the exact deadline succeeds");
    }

    /// @notice `deadline == block.timestamp - 1` reverts `SwapDeadlineExpired`.
    function test_deadline_oneSecondPast_reverts() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        vm.warp(1_000_000);
        vm.expectRevert(KnomosisBridge.SwapDeadlineExpired.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, block.timestamp - 1);
    }

    /// @notice A deadline far in the past reverts even when the swap would
    ///         otherwise be valid (the deadline is checked FIRST).
    function test_deadline_staleTransaction_reverts() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        vm.warp(2_000_000);
        vm.expectRevert(KnomosisBridge.SwapDeadlineExpired.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, 1_000_000);
    }

    /// @notice The deadline is checked before the slippage bound: a swap that
    ///         is BOTH expired and over-slippage reverts with the DEADLINE
    ///         error (the first guard).
    function test_deadline_checkedBeforeSlippage() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        vm.warp(2_000_000);
        vm.expectRevert(KnomosisBridge.SwapDeadlineExpired.selector);
        vm.prank(swapper);
        // Past deadline AND an impossible minAmountOut: deadline error wins.
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, type(uint256).max, 1_000_000);
    }

    /// @notice `minAmountOut == amountOut` is acceptable on the BOLD->ETH leg
    ///         too (direction symmetry of the strict `<` slippage check).
    function test_slippage_boldToEth_exactMet_succeeds() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);
        uint256 amountIn = 3000 ether;
        uint256 expectedOut = _refOut(amountIn, rBold, rEth);
        _mintApprove(bridge, swapper, amountIn);

        vm.prank(swapper);
        uint256 out = bridge.ammSwap(BOLD_RID, amountIn, expectedOut, _farDeadline());
        assertEq(out, expectedOut, "BOLD->ETH exact-min swap returns the expected output");
    }

    /// @notice `minAmountOut == amountOut - 1` succeeds (strictly below the
    ///         output is acceptable; only `> amountOut` reverts).
    function test_slippage_oneBelowOutput_succeeds() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);
        uint256 amountIn = 1 ether;
        uint256 expectedOut = _refOut(amountIn, rEth, rBold);

        vm.prank(swapper);
        uint256 out = bridge.ammSwap{value: amountIn}(NATIVE_ETH, amountIn, expectedOut - 1, _farDeadline());
        assertEq(out, expectedOut, "min one below the output succeeds");
    }

    /// @notice `deadline == type(uint256).max` never expires (the swap
    ///         succeeds at an arbitrarily large block timestamp).
    function test_deadline_typeMax_neverExpires() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        vm.warp(type(uint64).max);
        vm.prank(swapper);
        uint256 out = bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, type(uint256).max);
        assertGt(out, 0, "max deadline never expires");
    }

    /// @notice Zero-min disables slippage on the BOLD->ETH leg too (the
    ///         arbitrage escape hatch is direction-symmetric).
    function test_slippage_boldToEth_zeroMin_disables() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        uint256 amountIn = 2000 ether;
        _mintApprove(bridge, swapper, amountIn);
        vm.prank(swapper);
        uint256 out = bridge.ammSwap(BOLD_RID, amountIn, 0, _farDeadline());
        assertGt(out, 0, "BOLD->ETH zero-min accepts any positive output");
    }
}
