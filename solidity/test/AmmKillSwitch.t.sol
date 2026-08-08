// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {DepositEventDecoder} from "test/utils/DepositEventDecoder.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";
import {MockBold} from "test/utils/MockBold.sol";
import {AmmTestBase} from "test/utils/AmmTestBase.sol";
import {WithdrawalFlowHarness} from "test/utils/WithdrawalFlowHarness.sol";

/// @title AmmKillSwitchTest
/// @notice Workstream GP.11.10 — the one-way `emergencyDisableAmm`
///         kill switch, re-pointed at the LIVE L2 pool under the
///         one-AMM topology (the excised L1 `ammSwap` and its brake
///         interplay are gone; the switch's L2 effects — swap
///         inadmissibility + reclaim admissibility — are proven and
///         tested on the Lean side).
///
/// @dev    Pins as tests: `ammDisabled_is_monotonic`; the access
///         control on the disaster-recovery role; the
///         seeding-stops-when-disabled effect; the GP.11.10
///         "post-disable deposit + withdraw still work" degraded-mode
///         guarantee; the one-argument `AmmDisabled` event; and the
///         constructor `AmmRoleIsBridge` guard.  The 3-of-N multisig
///         hardening of the role lives in
///         `KnomosisAmmDisasterRecoveryMultisig.t.sol`.
contract AmmKillSwitchTest is AmmTestBase, WithdrawalFlowHarness, DepositEventDecoder {
    /// @dev Local copy of the contract event for `vm.expectEmit`.
    event AmmDisabled(uint256 timestamp);

    /// @dev Attestor key for the post-disable withdrawal round trip.
    uint256 private constant ATTESTOR_PK = 0xA77E5709;

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

    /// @notice A graceful shutdown, not a drain: the disable is a pure
    ///         flag flip whose `AmmDisabled` event carries the block
    ///         timestamp (the excised books' reserve arguments are gone
    ///         with the books), and the escrow/TVL accounting is
    ///         untouched by the call.
    function test_emergencyDisableAmm_flagOnly_andEmits() public {
        KnomosisBridge bridge = _deploySeededReady();
        uint256 tvlBefore = bridge.totalLockedValue();

        vm.expectEmit(false, false, false, true, address(bridge));
        emit AmmDisabled(block.timestamp);

        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();

        assertTrue(bridge.ammDisabled(), "flag set");
        assertEq(bridge.totalLockedValue(), tvlBefore, "escrow accounting untouched");
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

    /// @notice Once disabled, deposits STOP seeding the L2 pool (the
    ///         `_ammSeedSplit` early-out reports a ZERO seed in the
    ///         `DepositWithFeeInitiated` event) — while the deposit
    ///         itself still succeeds and credits TVL (the kill switch
    ///         touches only the pool, not the bridge's core deposit
    ///         path).
    function test_ammDisabled_stopsSeeding_depositStillWorks() public {
        KnomosisBridge bridge = _deploySeededReady();

        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();

        uint256 tvlBefore = bridge.totalLockedValue();
        vm.recordLogs();
        vm.prank(lp);
        bridge.depositETHWithFee{value: 10 ether}(5000); // would normally seed

        // The canonical deposit event's ammSeedAmount slot is ZERO.
        DepositReceipt memory r = _findDepositReceipt(vm.getRecordedLogs());
        assertEq(r.ammSeedAmount, 0, "disabled pool receives no seed");
        assertEq(bridge.totalLockedValue(), tvlBefore + 10 ether, "deposit still credits TVL");
    }

    /// @notice GP.11.10 "post-disable deposit + withdraw still work", the
    ///         withdrawal half: with the kill switch FIRED, the full exit
    ///         path stays open on BOTH legs — a state root finalises and
    ///         `withdrawWithProof` pays out ETH and BOLD.  The kill switch
    ///         degrades the bridge to the v1.2 "external L1 DEX" mode for
    ///         swaps; it must never trap user funds.
    function test_ammDisabled_withdrawStillWorks_bothLegs() public {
        // A bridge whose attestor key the test controls, so it can
        // finalise withdrawal state roots.
        _etchBold();
        KnomosisBridge.ConstructorArgs memory args = _boldEnabledArgs();
        args.attestor = vm.addr(ATTESTOR_PK);
        KnomosisBridge bridge = new KnomosisBridge(args);
        // Fund the escrow on both legs with ordinary deposits.
        vm.prank(lp);
        bridge.depositETH{value: 40 ether}();
        _mintApprove(bridge, lp, 120_000 ether);
        vm.prank(lp);
        bridge.depositBoldWithFee(120_000 ether, 0);

        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();
        assertTrue(bridge.ammDisabled(), "kill switch fired before the exits");

        // ETH leg: a single-leaf withdrawal tree, attested, finalised,
        // and redeemed — all post-disable.
        address ethRecipient = address(0xE7B1);
        uint64 ethAmount = 700_000;
        _finaliseAndRedeem(bridge, NATIVE_ETH, ethRecipient, ethAmount, 1);
        assertEq(ethRecipient.balance, ethAmount, "ETH redeemed while AMM disabled");

        // BOLD leg: same flow under the next monotonic log index.
        address boldRecipient = address(0xB07D);
        uint64 boldAmount = 400_000;
        _finaliseAndRedeem(bridge, BOLD_RID, boldRecipient, boldAmount, 2);
        assertEq(
            MockBold(BOLD).balanceOf(boldRecipient), boldAmount, "BOLD redeemed while AMM disabled"
        );

        // The reserves were never touched by the exits (withdrawals pay
        // from escrow; the frozen AMM reserves are a sub-pool of it).
        assertTrue(bridge.ammDisabled(), "kill switch still set after the exits");
    }

    // The breaker-gates-swaps, brake-independence/precedence and
    // migration-freeze cases died with the L1 `ammSwap` they exercised;
    // the GP.5.5 BOLD circuit breaker keeps its own deposit-path suite
    // (`BoldCircuitBreaker.t.sol`).

    /// @notice The two brakes remain independent state: disabling the
    ///         pool does NOT close the BOLD circuit, and closing the
    ///         circuit does NOT set `ammDisabled`.
    function test_brakes_areIndependent() public {
        KnomosisBridge bridge = _deploySeededReady();

        vm.prank(BOLD_BREAKER);
        bridge.closeBoldCircuit();
        assertFalse(bridge.ammDisabled(), "breaker does not flip the kill switch");

        vm.prank(BOLD_BREAKER);
        bridge.openBoldCircuit();
        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();
        assertFalse(bridge.boldCircuitClosed(), "kill switch does not close the breaker");
    }

    // ------------------------------------------------------------------
    // Withdrawal-flow staging (the CBE + EIP-712 encoders live in the
    // shared `WithdrawalFlowHarness`)
    // ------------------------------------------------------------------

    function _finaliseAndRedeem(
        KnomosisBridge bridge,
        uint64 resourceId,
        address recipient,
        uint64 wAmount,
        uint64 logIdx
    ) internal {
        uint64 leafIdx = 0;
        bytes memory leaf = _encodeWithdrawalLeaf(
            resourceId, recipient, wAmount, leafIdx + 7, leafIdx);
        bytes[] memory siblings = SmtVerifier.emptyProofSiblings();
        bytes32 root = SmtVerifier.recomputeRoot(uint256(leafIdx), leaf, siblings);
        bridge.submitStateRoot(root, logIdx, _signStateRootAs(ATTESTOR_PK, bridge, root, logIdx));
        // `vm.getBlockNumber()`, not `block.number`.  `block.number` is
        // the NUMBER opcode, which is genuinely constant within a call
        // frame, so the Yul optimiser may read it once and reuse the
        // value.  `vm.roll` mutates it out of band, which the optimiser
        // cannot see.  This helper runs twice per test, and under solc
        // 0.8.36 the second call reused the FIRST read — rolling to 101
        // again instead of 201, leaving the second state root inside its
        // dispute window and reverting `PreFinalisation()`.  The
        // cheatcode is an external staticcall, so it cannot be hoisted.
        vm.roll(vm.getBlockNumber() + 100); // past the 100-block dispute window
        bytes memory proofBlob = _encodeWithdrawalProof(leaf, leafIdx, siblings);
        bridge.withdrawWithProof(logIdx, proofBlob, leaf);
    }
}
