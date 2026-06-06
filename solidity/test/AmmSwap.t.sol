// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {MockBold} from "test/utils/MockBold.sol";
import {AmmTestBase} from "test/utils/AmmTestBase.sol";

/// @title AmmSwapTest
/// @notice Workstream GP.11.3.b / GP.11.3.c — the embedded ETH<->BOLD AMM
///         swap: directionality, reserve accounting, real-token movement,
///         the canonical event, the return value, and the revert surface.
///
/// @dev    Non-circularity: expected outputs are recomputed INLINE via the
///         base's `_refOut` (the raw constant-product formula), NOT via the
///         contract's `AmmMath` library, so this suite checks `contract ==
///         independent formula`.  `AmmMath.t.sol` separately pins `AmmMath ==
///         hand-computed ground truth`.
contract AmmSwapTest is AmmTestBase {
    // ------------------------------------------------------------------
    // ETH -> BOLD / BOLD -> ETH happy paths
    // ------------------------------------------------------------------

    /// @notice An ETH->BOLD swap: the caller sends ETH, receives BOLD; the
    ///         ETH reserve grows by the full input, the BOLD reserve shrinks
    ///         by the output, both real balances move in lockstep, the
    ///         canonical event fires, and the return value equals the output.
    function test_swapEthToBold_happyPath() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);

        uint256 amountIn = 1 ether;
        uint256 expectedOut = _refOut(amountIn, rEth, rBold);
        assertGt(expectedOut, 0, "non-trivial output expected");

        uint256 swapperBoldBefore = MockBold(BOLD).balanceOf(swapper);
        uint256 bridgeEthBefore = address(bridge).balance;
        uint256 bridgeBoldBefore = MockBold(BOLD).balanceOf(address(bridge));

        vm.expectEmit(true, true, true, true, address(bridge));
        emit AmmSwapExecuted(
            swapper, NATIVE_ETH, BOLD_RID, amountIn, expectedOut, rEth + amountIn, rBold - expectedOut
        );

        vm.prank(swapper);
        uint256 out = bridge.ammSwap{value: amountIn}(NATIVE_ETH, amountIn, 0, _farDeadline());

        assertEq(out, expectedOut, "return value == output");
        assertEq(bridge.ammReserveEth(), rEth + amountIn, "ETH reserve += amountIn (full input)");
        assertEq(bridge.ammReserveBold(), rBold - expectedOut, "BOLD reserve -= amountOut");
        assertEq(
            MockBold(BOLD).balanceOf(swapper) - swapperBoldBefore, expectedOut, "swapper got BOLD out"
        );
        assertEq(address(bridge).balance - bridgeEthBefore, amountIn, "bridge ETH balance += amountIn");
        assertEq(
            bridgeBoldBefore - MockBold(BOLD).balanceOf(address(bridge)), expectedOut, "bridge BOLD -= out"
        );
    }

    /// @notice A BOLD->ETH swap: the caller supplies BOLD, receives ETH; the
    ///         BOLD reserve grows by the full input, the ETH reserve shrinks
    ///         by the output, real balances move in lockstep.
    function test_swapBoldToEth_happyPath() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);

        uint256 amountIn = 3000 ether; // ~1 ETH worth of BOLD
        uint256 expectedOut = _refOut(amountIn, rBold, rEth);
        assertGt(expectedOut, 0, "non-trivial output expected");

        _mintApprove(bridge, swapper, amountIn);
        uint256 swapperEthBefore = swapper.balance;
        uint256 bridgeEthBefore = address(bridge).balance;
        uint256 bridgeBoldBefore = MockBold(BOLD).balanceOf(address(bridge));

        vm.expectEmit(true, true, true, true, address(bridge));
        emit AmmSwapExecuted(
            swapper, BOLD_RID, NATIVE_ETH, amountIn, expectedOut, rBold + amountIn, rEth - expectedOut
        );

        vm.prank(swapper);
        uint256 out = bridge.ammSwap(BOLD_RID, amountIn, 0, _farDeadline());

        assertEq(out, expectedOut, "return value == output");
        assertEq(bridge.ammReserveBold(), rBold + amountIn, "BOLD reserve += amountIn");
        assertEq(bridge.ammReserveEth(), rEth - expectedOut, "ETH reserve -= amountOut");
        assertEq(swapper.balance - swapperEthBefore, expectedOut, "swapper got ETH out");
        assertEq(bridgeEthBefore - address(bridge).balance, expectedOut, "bridge ETH -= out");
        assertEq(
            MockBold(BOLD).balanceOf(address(bridge)) - bridgeBoldBefore, amountIn, "bridge BOLD += in"
        );
    }

    // ------------------------------------------------------------------
    // Solvency / design invariants on the live contract
    // ------------------------------------------------------------------

    /// @notice A swap leaves `totalLockedValue` and `boldTotalLockedValue`
    ///         UNCHANGED — the AMM is a self-contained sub-pool (Option-C
    ///         accounting); solvency rides on the real-token-backing bounds,
    ///         not on TVL.
    function test_swap_doesNotTouchTvl() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);

        uint256 tvlBefore = bridge.totalLockedValue();
        uint256 boldTvlBefore = bridge.boldTotalLockedValue();

        vm.prank(swapper);
        bridge.ammSwap{value: 2 ether}(NATIVE_ETH, 2 ether, 0, _farDeadline());

        assertEq(bridge.totalLockedValue(), tvlBefore, "swap leaves global TVL unchanged");
        assertEq(bridge.boldTotalLockedValue(), boldTvlBefore, "swap leaves per-BOLD TVL unchanged");
    }

    /// @notice After a swap in EACH direction, the reserves remain backed by
    ///         the bridge's real token balances (the cross-currency solvency
    ///         statement).
    function test_swap_realTokenBacking_preserved() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);

        vm.prank(swapper);
        bridge.ammSwap{value: 5 ether}(NATIVE_ETH, 5 ether, 0, _farDeadline());

        _mintApprove(bridge, swapper, 9000 ether);
        vm.prank(swapper);
        bridge.ammSwap(BOLD_RID, 9000 ether, 0, _farDeadline());

        assertLe(bridge.ammReserveEth(), address(bridge).balance, "ETH reserve backed by real ETH");
        assertLe(
            bridge.ammReserveBold(),
            MockBold(BOLD).balanceOf(address(bridge)),
            "BOLD reserve backed by real BOLD"
        );
    }

    /// @notice Repeated round-trip swaps strictly grow k (the fee accrues to
    ///         the pool as LP yield).
    function test_swap_feeAccumulates_kGrows() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);

        uint256 kPrev = bridge.ammReserveEth() * bridge.ammReserveBold();
        for (uint256 i = 0; i < 5; ++i) {
            vm.prank(swapper);
            bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
            uint256 kNow = bridge.ammReserveEth() * bridge.ammReserveBold();
            assertGt(kNow, kPrev, "each fee'd swap strictly grows k");
            kPrev = kNow;

            _mintApprove(bridge, swapper, 2000 ether);
            vm.prank(swapper);
            bridge.ammSwap(BOLD_RID, 2000 ether, 0, _farDeadline());
            kNow = bridge.ammReserveEth() * bridge.ammReserveBold();
            assertGt(kNow, kPrev, "each fee'd swap strictly grows k (BOLD->ETH)");
            kPrev = kNow;
        }
    }

    // ------------------------------------------------------------------
    // Revert surface
    // ------------------------------------------------------------------

    /// @notice Before any seeding, an ETH->BOLD swap reverts `AmmEmpty` (the
    ///         BOLD reserve is zero).
    function test_swap_revertsAmmEmpty_beforeSeeding() public {
        KnomosisBridge bridge = _deploySeededReady();
        vm.expectRevert(KnomosisBridge.AmmEmpty.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
    }

    /// @notice If only one leg is seeded, swaps still revert `AmmEmpty`.
    function test_swap_revertsAmmEmpty_oneLegSeeded() public {
        KnomosisBridge bridge = _deploySeededReady();
        vm.prank(lp);
        bridge.depositETHWithFee{value: 100 ether}(5000);
        assertGt(bridge.ammReserveEth(), 0, "ETH leg seeded");
        assertEq(bridge.ammReserveBold(), 0, "BOLD leg empty");

        vm.expectRevert(KnomosisBridge.AmmEmpty.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
    }

    /// @notice On a BOLD-disabled deployment the AMM can never function;
    ///         swaps revert `AmmEmpty` immediately (before any token call).
    function test_swap_revertsAmmEmpty_whenBoldDisabled() public {
        KnomosisBridge bridge = _deployBoldDisabled();
        vm.prank(lp);
        bridge.depositETHWithFee{value: 50 ether}(5000);

        vm.expectRevert(KnomosisBridge.AmmEmpty.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
    }

    /// @notice A zero input reverts `ZeroSwapInput`.
    function test_swap_revertsZeroInput() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        vm.expectRevert(KnomosisBridge.ZeroSwapInput.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 0}(NATIVE_ETH, 0, 0, _farDeadline());
    }

    /// @notice An unsupported `fromResource` reverts `UnsupportedSwapResource`.
    function test_swap_revertsUnsupportedResource() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.UnsupportedSwapResource.selector, uint64(2)));
        vm.prank(swapper);
        bridge.ammSwap(2, 1 ether, 0, _farDeadline());
    }

    /// @notice An ETH swap whose `msg.value` differs from `amountIn` reverts
    ///         `EthAmountMismatch`.
    function test_swap_revertsEthAmountMismatch() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.EthAmountMismatch.selector, uint256(1 ether), uint256(2 ether)
            )
        );
        vm.prank(swapper);
        bridge.ammSwap{value: 2 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
    }

    /// @notice A BOLD swap carrying ETH reverts `UnexpectedEth`.
    function test_swap_revertsUnexpectedEth() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        _mintApprove(bridge, swapper, 1000 ether);
        vm.expectRevert(KnomosisBridge.UnexpectedEth.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 wei}(BOLD_RID, 1000 ether, 0, _farDeadline());
    }

    /// @notice A dust input whose output floors to zero reverts
    ///         `ZeroSwapOutput` (no donation-for-nothing).  With a 40 ETH /
    ///         120000 BOLD pool, 1 wei of BOLD is worth ~0.0003 wei of ETH,
    ///         which floors to a ZERO ETH output — the genuine dust case (the
    ///         reverse direction, where 1 wei ETH is worth ~3000 wei BOLD,
    ///         does NOT floor to zero).
    function test_swap_revertsZeroSwapOutput_onDustInput() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);
        // Sanity: 1 wei BOLD genuinely floors to a zero ETH output.
        assertEq(_refOut(1, rBold, rEth), 0, "1 wei BOLD floors to 0 ETH out");

        _mintApprove(bridge, swapper, 1);
        vm.expectRevert(KnomosisBridge.ZeroSwapOutput.selector);
        vm.prank(swapper);
        bridge.ammSwap(BOLD_RID, 1, 0, _farDeadline());
    }
}
