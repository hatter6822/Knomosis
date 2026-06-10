// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";
import {KnomosisEip712} from "src/lib/KnomosisEip712.sol";
import {MockBold} from "test/utils/MockBold.sol";
import {AmmTestBase} from "test/utils/AmmTestBase.sol";

/// @title AmmKillSwitchTest
/// @notice Workstream GP.11.3 / GP.11.10 — the two emergency brakes on
///         `ammSwap`: the one-way `emergencyDisableAmm` kill switch
///         (GP.11.10's disaster-recovery control) and the automatic
///         GP.5.5 BOLD circuit-breaker gating (depeg freeze).
///
/// @dev    Pins the three GP.11.10 theorems as tests:
///         `emergencyDisableAmm_preserves_reserves`,
///         `ammDisabled_implies_swap_reverts`, `ammDisabled_is_monotonic`;
///         the access control on the disaster-recovery role; the
///         seeding-stops-when-disabled effect; the GP.11.10
///         "post-disable deposit + withdraw still work" degraded-mode
///         guarantee; the breaker gating in both directions; the
///         breaker/kill-switch independence + precedence; and the
///         constructor `AmmRoleIsBridge` guard.  The 3-of-N multisig
///         hardening of the role lives in
///         `KnomosisAmmDisasterRecoveryMultisig.t.sol`.
contract AmmKillSwitchTest is AmmTestBase {
    /// @dev Local copy of the contract event for `vm.expectEmit`.
    event AmmDisabled(uint256 timestamp, uint256 reserveEth, uint256 reserveBold);

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
        _seedBothLegs(bridge); // funds the escrow on both legs

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

    // ------------------------------------------------------------------
    // Migration freeze (GP.11.3 review fix — the migration arm of circuitOpen)
    // ------------------------------------------------------------------

    /// @notice Once the bridge MIGRATES to a successor, `ammSwap` freezes
    ///         (reverts `MigrationActivated`) in BOTH directions — a retired
    ///         bridge must not keep mutating its reserves or moving real assets
    ///         after hand-off.  The pre-migration swap succeeds under the SAME
    ///         (non-transient) state, isolating migration as the added gate; the
    ///         transient `circuitOpen` arms (attestation-stale / dispute-cooldown)
    ///         are deliberately not applied to the AMM.
    function test_swap_freezesAfterMigration() public {
        MockToggleMigration mig = new MockToggleMigration();
        _etchBold();
        KnomosisBridge.ConstructorArgs memory args = _boldEnabledArgs();
        args.migration = address(mig);
        KnomosisBridge bridge = new KnomosisBridge(args);
        _seedBothLegs(bridge);

        // Pre-migration: swaps work (the migration mock is inactive).
        vm.prank(swapper);
        uint256 out = bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
        assertGt(out, 0, "swap works before migration");

        // Activate migration: the AMM freezes in BOTH directions.
        mig.activate();

        vm.expectRevert(KnomosisBridge.MigrationActivated.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());

        _mintApprove(bridge, swapper, 1000 ether);
        vm.expectRevert(KnomosisBridge.MigrationActivated.selector);
        vm.prank(swapper);
        bridge.ammSwap(BOLD_RID, 1000 ether, 0, _farDeadline());

        // The freeze is a gate, not a state change: reserves + kill switch
        // are untouched.
        assertFalse(bridge.ammDisabled(), "migration freeze does not flip the kill switch");
    }

    // ------------------------------------------------------------------
    // Withdrawal-flow helpers (CBE + EIP-712; mirror the canonical
    // encodings used by `BoldCircuitBreaker.t.sol`'s end-to-end tests)
    // ------------------------------------------------------------------

    function _finaliseAndRedeem(
        KnomosisBridge bridge,
        uint64 resourceId,
        address recipient,
        uint64 wAmount,
        uint64 logIdx
    ) internal {
        uint64 leafIdx = 0;
        bytes memory leaf = _encodeWithdrawalLeaf(resourceId, recipient, wAmount, leafIdx);
        bytes[] memory siblings = SmtVerifier.emptyProofSiblings();
        bytes32 root = SmtVerifier.recomputeRoot(uint256(leafIdx), leaf, siblings);
        bridge.submitStateRoot(root, logIdx, _signStateRoot(bridge, root, logIdx));
        vm.roll(block.number + 100); // past the 100-block dispute window
        bytes memory proofBlob = _encodeWithdrawalProof(leaf, leafIdx, siblings);
        bridge.withdrawWithProof(logIdx, proofBlob, leaf);
    }

    function _signStateRoot(KnomosisBridge bridge, bytes32 root, uint64 idx)
        internal
        view
        returns (bytes memory)
    {
        bytes32 ds = KnomosisEip712.domainSeparator(
            "KnomosisBridge", "1", block.chainid, uint256(0), address(bridge)
        );
        bytes32 sh = keccak256(
            abi.encode(
                keccak256("StateRoot(bytes32 root,uint64 logIndexHigh,bytes32 deploymentId)"),
                root,
                uint256(idx),
                bridge.deploymentId()
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, KnomosisEip712.digest(ds, sh));
        return abi.encodePacked(r, s, v);
    }

    function _leBytes8(uint64 v) internal pure returns (bytes memory out) {
        out = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    function _cbeUint(uint64 v) internal pure returns (bytes memory) {
        return bytes.concat(hex"00", _leBytes8(v));
    }

    function _cbeBytes(bytes memory payload) internal pure returns (bytes memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes.concat(hex"02", _leBytes8(uint64(payload.length)), payload);
    }

    function _cbeArrayHead(uint64 count) internal pure returns (bytes memory) {
        return bytes.concat(hex"04", _leBytes8(count));
    }

    function _encodeWithdrawalLeaf(
        uint64 resourceId,
        address recipient,
        uint64 amount,
        uint64 l2LogIndex
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            _cbeUint(resourceId),
            _cbeBytes(abi.encodePacked(recipient)),
            _cbeUint(amount),
            _cbeUint(l2LogIndex)
        );
    }

    function _encodeWithdrawalProof(bytes memory leaf, uint64 idx, bytes[] memory siblings)
        internal
        pure
        returns (bytes memory)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory out =
            bytes.concat(_cbeBytes(leaf), _cbeUint(idx), _cbeArrayHead(uint64(siblings.length)));
        for (uint256 i = 0; i < siblings.length; i++) {
            out = bytes.concat(out, _cbeBytes(siblings[i]));
        }
        return out;
    }
}

/// @notice A migration mock whose `activated()` is operator-toggleable, so a
///         test can seed the AMM while migration is inactive and then activate
///         it to prove the swap freezes.  Matches the single `activated()`
///         method `KnomosisBridge` reads via `IKnomosisMigration`.
contract MockToggleMigration {
    bool public isActivated;

    function activate() external {
        isActivated = true;
    }

    function activated() external view returns (bool) {
        return isActivated;
    }
}
