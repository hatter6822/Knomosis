// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {MockBold} from "test/utils/MockBold.sol";
import {AmmTestBase} from "test/utils/AmmTestBase.sol";

/// @title AmmSandwichTest
/// @notice Workstream GP.11.3.h — a sandwich-attack simulator over the
///         embedded AMM.  Demonstrates (1) that an unprotected swap is
///         degraded by a front-run, (2) that a front-run + back-run around a
///         large unprotected user swap is profitable for the attacker, and
///         (3) that the user's `minAmountOut` deterministically STOPS the
///         attack — the user reverts and the attacker is left holding a
///         losing position (the standard AMM slippage defence).
contract AmmSandwichTest is AmmTestBase {
    /// @dev The sandwich attacker (distinct from the honest user `swapper`).
    address private attacker = address(0xA77ACE);

    function setUp() public override {
        super.setUp();
        vm.deal(attacker, type(uint128).max);
    }

    /// @notice A front-run (attacker buys BOLD first) worsens the honest
    ///         user's execution: the user receives strictly LESS BOLD than the
    ///         pre-front-run "fair" quote.
    function test_sandwich_frontRunWorsensUserExecution() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);

        uint256 userIn = 10 ether;
        uint256 fairOut = _refOut(userIn, rEth, rBold); // no front-run

        // Attacker front-runs: ETH -> BOLD, pushing the BOLD price up.
        vm.prank(attacker);
        bridge.ammSwap{value: 10 ether}(NATIVE_ETH, 10 ether, 0, _farDeadline());

        // User swaps with NO slippage protection.
        vm.prank(swapper);
        uint256 userOut = bridge.ammSwap{value: userIn}(NATIVE_ETH, userIn, 0, _farDeadline());

        assertLt(userOut, fairOut, "the front-run degraded the user's execution");
    }

    /// @notice The full sandwich is profitable for the attacker when the user
    ///         does NOT protect: the attacker front-runs, the user swaps a
    ///         large amount unprotected, and the attacker back-runs out for a
    ///         net ETH gain (the price the user moved exceeds the attacker's
    ///         double fee + own impact).
    function test_sandwich_profitableWithoutProtection() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);

        uint256 frontRunIn = 10 ether;
        uint256 attackerEthBefore = attacker.balance;

        // Front-run: attacker buys BOLD.
        vm.prank(attacker);
        uint256 boldGained = bridge.ammSwap{value: frontRunIn}(NATIVE_ETH, frontRunIn, 0, _farDeadline());

        // Victim: a large unprotected ETH->BOLD swap moves the price further.
        vm.prank(swapper);
        bridge.ammSwap{value: 10 ether}(NATIVE_ETH, 10 ether, 0, _farDeadline());

        // Back-run: attacker sells the BOLD it bought, at the inflated price.
        // The attacker already holds `boldGained` BOLD from the front-run; it
        // only needs to approve the bridge to pull it.
        vm.prank(attacker);
        MockBold(BOLD).approve(address(bridge), boldGained);
        vm.prank(attacker);
        uint256 ethBack = bridge.ammSwap(BOLD_RID, boldGained, 0, _farDeadline());

        // Net ETH: spent `frontRunIn`, recovered `ethBack`.
        assertGt(ethBack, frontRunIn, "back-run recovers more ETH than the front-run spent");
        assertGt(attacker.balance, attackerEthBefore, "attacker nets a positive ETH profit");
    }

    /// @notice The user's `minAmountOut` STOPS the sandwich: with the bound set
    ///         to the fair (pre-front-run) quote, the attacker's front-run
    ///         pushes the user's execution below the bound and the user's swap
    ///         reverts `SlippageExceeded` — the attacker is left holding the
    ///         BOLD it bought (a losing position once it unwinds at the fee).
    function test_sandwich_slippageProtectionStopsAttack() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);

        uint256 userIn = 10 ether;
        uint256 fairOut = _refOut(userIn, rEth, rBold);

        // Attacker front-runs.
        vm.prank(attacker);
        bridge.ammSwap{value: 10 ether}(NATIVE_ETH, 10 ether, 0, _farDeadline());

        // User demands the fair (un-front-run) output as the floor.  The
        // front-run made the real output strictly less, so the user reverts.
        uint256 actualWouldBe = _refOut(userIn, bridge.ammReserveEth(), bridge.ammReserveBold());
        assertLt(actualWouldBe, fairOut, "sanity: real output is below the fair floor post-front-run");

        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.SlippageExceeded.selector, actualWouldBe, fairOut)
        );
        vm.prank(swapper);
        bridge.ammSwap{value: userIn}(NATIVE_ETH, userIn, fairOut, _farDeadline());
    }

    /// @notice With a realistic tolerance (`minAmountOut` = 99% of the fair
    ///         quote), a SMALL front-run within tolerance lets the user
    ///         through with at least the bound, while a LARGE front-run
    ///         exceeding tolerance reverts — `minAmountOut` deterministically
    ///         bounds the worst-case loss.
    function test_sandwich_minAmountOutBoundsLoss() public {
        // Tolerated: a tiny front-run keeps the user above 99% of fair.
        {
            KnomosisBridge bridge = _deploySeededReady();
            (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);
            uint256 userIn = 1 ether;
            uint256 fairOut = _refOut(userIn, rEth, rBold);
            uint256 minOut = (fairOut * 99) / 100;

            vm.prank(attacker);
            bridge.ammSwap{value: 0.01 ether}(NATIVE_ETH, 0.01 ether, 0, _farDeadline());

            vm.prank(swapper);
            uint256 out = bridge.ammSwap{value: userIn}(NATIVE_ETH, userIn, minOut, _farDeadline());
            assertGe(out, minOut, "small front-run within tolerance: user clears the bound");
        }
        // Stopped: a large front-run breaches the 99% bound, user reverts.
        {
            KnomosisBridge bridge = _deploySeededReady();
            (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);
            uint256 userIn = 1 ether;
            uint256 fairOut = _refOut(userIn, rEth, rBold);
            uint256 minOut = (fairOut * 99) / 100;

            vm.prank(attacker);
            bridge.ammSwap{value: 20 ether}(NATIVE_ETH, 20 ether, 0, _farDeadline());

            vm.expectRevert(); // SlippageExceeded
            vm.prank(swapper);
            bridge.ammSwap{value: userIn}(NATIVE_ETH, userIn, minOut, _farDeadline());
        }
    }
}
