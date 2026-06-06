// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {MockBold} from "test/utils/MockBold.sol";
import {AmmTestBase} from "test/utils/AmmTestBase.sol";

/// @title AmmKillSwitchTest
/// @notice Workstream GP.11.3 — the two emergency brakes on `ammSwap`: the
///         one-way `emergencyDisableAmm` kill switch (GP.11.10's
///         disaster-recovery control, pulled forward) and the automatic
///         GP.5.5 BOLD circuit-breaker gating (depeg freeze).
///
/// @dev    Pins the three GP.11.10 theorems as tests:
///         `emergencyDisableAmm_preserves_reserves`,
///         `ammDisabled_implies_swap_reverts`, `ammDisabled_is_monotonic`;
///         the access control on the disaster-recovery role; the
///         seeding-stops-when-disabled effect; the breaker gating in both
///         directions; the breaker/kill-switch independence + precedence;
///         and the constructor `AmmRoleIsBridge` guard.
contract AmmKillSwitchTest is AmmTestBase {
    /// @dev Local copy of the contract event for `vm.expectEmit`.
    event AmmDisabled(uint256 timestamp, uint256 reserveEth, uint256 reserveBold);

    // ------------------------------------------------------------------
    // Kill switch — access control
    // ------------------------------------------------------------------

    /// @notice `emergencyDisableAmm` is callable ONLY by the immutable
    ///         `ammDisasterRecovery` role; every other caller reverts
    ///         `NotAmmDisasterRecovery`.
    function test_emergencyDisableAmm_onlyRole() public {
        KnomosisBridge bridge = _deploySeededReady();

        // A non-role caller (the lp, the breaker, the admin, a random) reverts.
        vm.expectRevert(KnomosisBridge.NotAmmDisasterRecovery.selector);
        vm.prank(lp);
        bridge.emergencyDisableAmm();

        vm.expectRevert(KnomosisBridge.NotAmmDisasterRecovery.selector);
        vm.prank(BOLD_BREAKER);
        bridge.emergencyDisableAmm();

        assertFalse(bridge.ammDisabled(), "still enabled after rejected calls");

        // The role succeeds.
        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();
        assertTrue(bridge.ammDisabled(), "AMM disabled by the disaster-recovery role");
    }

    /// @notice A FUNCTIONAL AMM (BOLD-enabled with `ammSeedRatioBps > 0`)
    ///         CANNOT opt out of the kill switch: deploying one with
    ///         `ammDisasterRecovery == address(0)` reverts
    ///         `AmmDisasterRecoveryRequired` at construction — mirroring the
    ///         GP.5.5 rule that an enabled feature must ship its safety roles.
    function test_constructor_functionalAmmRequiresRole() public {
        _etchBold();
        KnomosisBridge.ConstructorArgs memory args = _boldEnabledArgs(); // ratio 8000
        args.ammDisasterRecovery = address(0); // attempt to opt out
        vm.expectRevert(KnomosisBridge.AmmDisasterRecoveryRequired.selector);
        new KnomosisBridge(args);
    }

    /// @notice The role may be `address(0)` (opt out) ONLY when the AMM is
    ///         disabled (`ammSeedRatioBps == 0`) — the AMM cannot function, so
    ///         a kill switch is moot.  Such a deployment is valid, and
    ///         `emergencyDisableAmm` is unreachable (no caller is `address(0)`).
    function test_constructor_disabledAmmMayOptOutOfRole() public {
        _etchBold();
        KnomosisBridge.ConstructorArgs memory args = _boldEnabledArgs();
        args.ammSeedRatioBps = 0; // AMM disabled -> role optional
        args.ammDisasterRecovery = address(0);
        KnomosisBridge bridge = new KnomosisBridge(args);

        assertEq(bridge.ammDisasterRecovery(), address(0), "kill switch opted out (AMM disabled)");
        vm.expectRevert(KnomosisBridge.NotAmmDisasterRecovery.selector);
        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();
    }

    /// @notice The constructor rejects an `ammDisasterRecovery` role equal to
    ///         the bridge's own (future) address (`AmmRoleIsBridge`), closing
    ///         the self-as-role footgun by construction.
    function test_constructor_ammRoleIsBridge_reverts() public {
        _etchBold();
        // The bridge will deploy at this CREATE address; pass it as the role.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        KnomosisBridge.ConstructorArgs memory args = _boldEnabledArgs();
        args.ammDisasterRecovery = predicted;

        vm.expectRevert(KnomosisBridge.AmmRoleIsBridge.selector);
        new KnomosisBridge(args);
    }

    // ------------------------------------------------------------------
    // Kill switch — semantics (the GP.11.10 theorems as tests)
    // ------------------------------------------------------------------

    /// @notice `emergencyDisableAmm_preserves_reserves`: the reserves are
    ///         UNCHANGED by the call (a graceful shutdown, not a drain), and
    ///         the `AmmDisabled` event carries them.
    function test_emergencyDisableAmm_preservesReserves_andEmits() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);

        vm.expectEmit(false, false, false, true, address(bridge));
        emit AmmDisabled(block.timestamp, rEth, rBold);

        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();

        assertEq(bridge.ammReserveEth(), rEth, "ETH reserve preserved across disable");
        assertEq(bridge.ammReserveBold(), rBold, "BOLD reserve preserved across disable");
    }

    /// @notice `ammDisabled_implies_swap_reverts`: once disabled, EVERY
    ///         `ammSwap` reverts `AmmIsDisabled`, in both directions.
    function test_ammDisabled_swapReverts_bothDirections() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);
        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();

        vm.expectRevert(KnomosisBridge.AmmIsDisabled.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());

        _mintApprove(bridge, swapper, 1000 ether);
        vm.expectRevert(KnomosisBridge.AmmIsDisabled.selector);
        vm.prank(swapper);
        bridge.ammSwap(BOLD_RID, 1000 ether, 0, _farDeadline());
    }

    /// @notice `ammDisabled_is_monotonic`: the kill switch is one-way — a
    ///         second `emergencyDisableAmm` reverts `AmmAlreadyDisabled`, and
    ///         there is no path that resets `ammDisabled` to false.
    function test_ammDisabled_isMonotonic() public {
        KnomosisBridge bridge = _deploySeededReady();
        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();
        assertTrue(bridge.ammDisabled(), "disabled");

        vm.expectRevert(KnomosisBridge.AmmAlreadyDisabled.selector);
        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();
        assertTrue(bridge.ammDisabled(), "still disabled (one-way)");
    }

    /// @notice Once disabled, deposits STOP accruing AMM reserves (the
    ///         `_seedAmmReserves` early-out) — the reserves freeze — while the
    ///         deposit itself still succeeds and credits TVL (the kill switch
    ///         touches only the AMM, not the bridge's core deposit path).
    function test_ammDisabled_stopsSeeding_depositStillWorks() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth,) = _seedBothLegs(bridge);

        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();

        uint256 tvlBefore = bridge.totalLockedValue();
        vm.prank(lp);
        bridge.depositETHWithFee{value: 10 ether}(5000); // would normally seed

        assertEq(bridge.ammReserveEth(), rEth, "reserve frozen (disabled AMM stops seeding)");
        assertEq(bridge.totalLockedValue(), tvlBefore + 10 ether, "deposit still credits TVL");
    }

    // ------------------------------------------------------------------
    // BOLD circuit-breaker gating (automatic depeg freeze)
    // ------------------------------------------------------------------

    /// @notice A closed BOLD circuit (the depeg signal) freezes the AMM:
    ///         swaps revert `AmmPausedByBoldCircuit` in both directions.
    function test_breaker_closedHaltsSwaps_bothDirections() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);

        vm.prank(BOLD_BREAKER);
        bridge.closeBoldCircuit();

        vm.expectRevert(KnomosisBridge.AmmPausedByBoldCircuit.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());

        _mintApprove(bridge, swapper, 1000 ether);
        vm.expectRevert(KnomosisBridge.AmmPausedByBoldCircuit.selector);
        vm.prank(swapper);
        bridge.ammSwap(BOLD_RID, 1000 ether, 0, _farDeadline());
    }

    /// @notice Reopening the BOLD circuit resumes swaps (unlike the one-way
    ///         kill switch, the breaker toggles).
    function test_breaker_reopenedResumesSwaps() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);

        vm.prank(BOLD_BREAKER);
        bridge.closeBoldCircuit();
        vm.prank(BOLD_BREAKER);
        bridge.openBoldCircuit();

        vm.prank(swapper);
        uint256 out = bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
        assertGt(out, 0, "swap resumes after the circuit reopens");
    }

    // ------------------------------------------------------------------
    // Independence + precedence of the two brakes
    // ------------------------------------------------------------------

    /// @notice The two brakes are independent: closing the BOLD circuit does
    ///         NOT set `ammDisabled`, and disabling the AMM does NOT close the
    ///         BOLD circuit.
    function test_brakes_areIndependent() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);

        vm.prank(BOLD_BREAKER);
        bridge.closeBoldCircuit();
        assertFalse(bridge.ammDisabled(), "breaker does not flip the kill switch");

        vm.prank(BOLD_BREAKER);
        bridge.openBoldCircuit();
        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();
        assertFalse(bridge.boldCircuitClosed(), "kill switch does not close the breaker");
    }

    /// @notice Precedence: when the AMM is BOTH disabled and the breaker is
    ///         closed, the `ammActive` modifier fires FIRST, so the swap
    ///         reverts `AmmIsDisabled` (not `AmmPausedByBoldCircuit`).
    function test_brakes_killSwitchPrecedesBreaker() public {
        KnomosisBridge bridge = _deploySeededReady();
        _seedBothLegs(bridge);

        vm.prank(BOLD_BREAKER);
        bridge.closeBoldCircuit();
        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();

        vm.expectRevert(KnomosisBridge.AmmIsDisabled.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
    }
}
