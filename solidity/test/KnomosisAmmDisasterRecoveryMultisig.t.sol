// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisAmmDisasterRecoveryMultisig} from
    "src/contracts/KnomosisAmmDisasterRecoveryMultisig.sol";
import {AmmTestBase} from "test/utils/AmmTestBase.sol";

/// @title KnomosisAmmDisasterRecoveryMultisigTest
/// @notice WU GP.11.10 — the reference 3-of-N disaster-recovery multisig:
///         constructor validation (the constructor-enforced 3-of-N floor),
///         the confirm / revoke flow, the stale-round expiry defence, and
///         the end-to-end wiring where the multisig IS the bridge's
///         `ammDisasterRecovery` role and the threshold-th confirmation
///         fires the one-way kill switch.
/// @dev    Pins the GP.11.10 test item "disaster-recovery multisig: 3-of-N
///         requirement enforced" in both directions: a sub-threshold quorum
///         can never disable the AMM, and the constructor rejects any
///         configuration whose threshold is below 3.
contract KnomosisAmmDisasterRecoveryMultisigTest is AmmTestBase {
    /// @dev Local copies of the multisig events for `vm.expectEmit`.
    event DisableConfirmed(address indexed signer, uint256 indexed roundId, uint256 confirmations);
    event DisableConfirmationRevoked(
        address indexed signer, uint256 indexed roundId, uint256 confirmations
    );
    event ConfirmationRoundExpired(uint256 indexed staleRoundId, uint256 indexed newRoundId);
    event AmmDisableExecuted(uint256 indexed roundId, uint256 timestamp);
    /// @dev Local copy of the bridge event for `vm.expectEmit`.
    event AmmDisabled(uint256 timestamp, uint256 reserveEth, uint256 reserveBold);

    /// @dev The canonical 3-of-5 signer set (operator + community
    ///      representatives + auditor per the GP.11.10 custody spec).
    address internal constant SIGNER_OPERATOR = address(0xD801);
    address internal constant SIGNER_COMMUNITY_A = address(0xD802);
    address internal constant SIGNER_COMMUNITY_B = address(0xD803);
    address internal constant SIGNER_AUDITOR = address(0xD804);
    address internal constant SIGNER_BACKUP = address(0xD805);
    address internal constant OUTSIDER = address(0xBAD);

    function _signerSet() internal pure returns (address[] memory s) {
        s = new address[](5);
        s[0] = SIGNER_OPERATOR;
        s[1] = SIGNER_COMMUNITY_A;
        s[2] = SIGNER_COMMUNITY_B;
        s[3] = SIGNER_AUDITOR;
        s[4] = SIGNER_BACKUP;
    }

    /// @notice Deploy the production wiring: the multisig is constructed
    ///         FIRST against the bridge's predicted CREATE address, then
    ///         the bridge pins `ammDisasterRecovery = address(multisig)` —
    ///         the same predicted-address pre-wiring pattern production
    ///         deployments use for `KnomosisMigration`.
    function _deployWired()
        internal
        returns (KnomosisAmmDisasterRecoveryMultisig multisig, KnomosisBridge bridge)
    {
        _etchBold();
        // The multisig deploy consumes one nonce, so the bridge lands at
        // nonce + 1.
        address predictedBridge =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        multisig = new KnomosisAmmDisasterRecoveryMultisig(predictedBridge, _signerSet(), 3);
        KnomosisBridge.ConstructorArgs memory args = _boldEnabledArgs();
        args.ammDisasterRecovery = address(multisig);
        bridge = new KnomosisBridge(args);
        assertEq(address(bridge), predictedBridge, "bridge landed at the predicted address");
        assertEq(bridge.ammDisasterRecovery(), address(multisig), "multisig holds the role");
    }

    // ------------------------------------------------------------------
    // Constructor validation (the 3-of-N floor and signer-set hygiene)
    // ------------------------------------------------------------------

    /// @notice GP.11.10 "3-of-N requirement enforced", constructor half:
    ///         thresholds 0, 1, and 2 are all rejected at construction.
    function test_constructor_thresholdBelowMinimum_reverts() public {
        for (uint256 t = 0; t < 3; ++t) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    KnomosisAmmDisasterRecoveryMultisig.ThresholdBelowMinimum.selector, t
                )
            );
            new KnomosisAmmDisasterRecoveryMultisig(address(0xB81D6E), _signerSet(), t);
        }
    }

    /// @notice An unreachable quorum (threshold > N) is rejected.
    function test_constructor_thresholdExceedsSignerCount_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisAmmDisasterRecoveryMultisig.ThresholdExceedsSignerCount.selector, 6, 5
            )
        );
        new KnomosisAmmDisasterRecoveryMultisig(address(0xB81D6E), _signerSet(), 6);
    }

    /// @notice A 3-of-3 quorum (threshold == N == the minimum) is the
    ///         smallest valid configuration.
    function test_constructor_threeOfThree_isValid() public {
        address[] memory s = new address[](3);
        s[0] = SIGNER_OPERATOR;
        s[1] = SIGNER_COMMUNITY_A;
        s[2] = SIGNER_AUDITOR;
        KnomosisAmmDisasterRecoveryMultisig multisig =
            new KnomosisAmmDisasterRecoveryMultisig(address(0xB81D6E), s, 3);
        assertEq(multisig.threshold(), 3, "threshold pinned");
        assertEq(multisig.signerCount(), 3, "signer count pinned");
    }

    /// @notice The zero bridge address is rejected.
    function test_constructor_zeroBridge_reverts() public {
        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.ZeroBridge.selector);
        new KnomosisAmmDisasterRecoveryMultisig(address(0), _signerSet(), 3);
    }

    /// @notice A zero signer is rejected.
    function test_constructor_zeroSigner_reverts() public {
        address[] memory s = _signerSet();
        s[2] = address(0);
        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.ZeroSigner.selector);
        new KnomosisAmmDisasterRecoveryMultisig(address(0xB81D6E), s, 3);
    }

    /// @notice A duplicated signer is rejected (duplicates would silently
    ///         lower the effective quorum below 3 distinct parties).
    function test_constructor_duplicateSigner_reverts() public {
        address[] memory s = _signerSet();
        s[4] = SIGNER_OPERATOR;
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisAmmDisasterRecoveryMultisig.DuplicateSigner.selector, SIGNER_OPERATOR
            )
        );
        new KnomosisAmmDisasterRecoveryMultisig(address(0xB81D6E), s, 3);
    }

    /// @notice The bridge itself cannot occupy a signer slot (it could
    ///         never confirm — a dead slot that weakens N).
    function test_constructor_signerIsBridge_reverts() public {
        address[] memory s = _signerSet();
        s[1] = address(0xB81D6E);
        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.SignerIsBridge.selector);
        new KnomosisAmmDisasterRecoveryMultisig(address(0xB81D6E), s, 3);
    }

    /// @notice The multisig's own (predicted) address cannot occupy a
    ///         signer slot.
    function test_constructor_signerIsSelf_reverts() public {
        address predictedSelf = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address[] memory s = _signerSet();
        s[3] = predictedSelf;
        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.SignerIsSelf.selector);
        new KnomosisAmmDisasterRecoveryMultisig(address(0xB81D6E), s, 3);
    }

    /// @notice A signer set above `MAX_SIGNERS` is rejected.
    function test_constructor_tooManySigners_reverts() public {
        address[] memory s = new address[](33);
        for (uint256 i = 0; i < 33; ++i) {
            // casting to 'uint160' is safe: 0xE000 + i < 0xE021 fits trivially.
            // forge-lint: disable-next-line(unsafe-typecast)
            s[i] = address(uint160(0xE000 + i));
        }
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisAmmDisasterRecoveryMultisig.TooManySigners.selector, 33)
        );
        new KnomosisAmmDisasterRecoveryMultisig(address(0xB81D6E), s, 3);
    }

    /// @notice The constructor stores the full configuration verbatim.
    function test_constructor_storesConfiguration() public {
        KnomosisAmmDisasterRecoveryMultisig multisig =
            new KnomosisAmmDisasterRecoveryMultisig(address(0xB81D6E), _signerSet(), 3);
        assertEq(address(multisig.bridge()), address(0xB81D6E), "bridge pinned");
        assertEq(multisig.threshold(), 3, "threshold pinned");
        assertEq(multisig.signerCount(), 5, "five signers");
        address[] memory stored = multisig.signers();
        address[] memory expected = _signerSet();
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(stored[i], expected[i], "signer order preserved");
            assertTrue(multisig.isSigner(expected[i]), "isSigner set");
        }
        assertFalse(multisig.isSigner(OUTSIDER), "outsider not a signer");
        assertFalse(multisig.executed(), "not executed at genesis");
        assertEq(multisig.confirmationCount(), 0, "no confirmations at genesis");
    }

    // ------------------------------------------------------------------
    // Confirm / revoke flow (sub-threshold quorums cannot disable)
    // ------------------------------------------------------------------

    /// @notice A non-signer can neither confirm nor revoke.
    function test_nonSigner_reverts() public {
        (KnomosisAmmDisasterRecoveryMultisig multisig,) = _deployWired();
        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.NotSigner.selector);
        vm.prank(OUTSIDER);
        multisig.confirmDisable();

        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.NotSigner.selector);
        vm.prank(OUTSIDER);
        multisig.revokeConfirmation();
    }

    /// @notice A signer cannot double-confirm within one round.
    function test_doubleConfirm_reverts() public {
        (KnomosisAmmDisasterRecoveryMultisig multisig,) = _deployWired();
        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.AlreadyConfirmedThisRound.selector);
        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        assertEq(multisig.confirmationCount(), 1, "double-confirm did not inflate the count");
    }

    /// @notice GP.11.10 "3-of-N requirement enforced", runtime half: TWO
    ///         confirmations — one below the floor — leave the AMM fully
    ///         live; the bridge's kill switch does not fire.
    function test_twoConfirmations_doNotDisable() public {
        (KnomosisAmmDisasterRecoveryMultisig multisig, KnomosisBridge bridge) = _deployWired();
        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        vm.prank(SIGNER_AUDITOR);
        multisig.confirmDisable();

        assertEq(multisig.confirmationCount(), 2, "two live confirmations");
        assertFalse(multisig.executed(), "below threshold: not executed");
        assertFalse(bridge.ammDisabled(), "below threshold: AMM still enabled");

        // The AMM is still fully operational: a swap succeeds.
        _seedBothLegs(bridge);
        vm.prank(swapper);
        uint256 out = bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
        assertGt(out, 0, "swap still works under a sub-threshold quorum");
    }

    /// @notice End-to-end: the THIRD confirmation fires the kill switch in
    ///         the same transaction — the bridge's `ammDisabled` flips, the
    ///         reserves are preserved, and both contracts emit their events.
    function test_thirdConfirmation_disablesAmm() public {
        (KnomosisAmmDisasterRecoveryMultisig multisig, KnomosisBridge bridge) = _deployWired();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);

        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        vm.prank(SIGNER_COMMUNITY_A);
        multisig.confirmDisable();

        vm.expectEmit(true, true, false, true, address(multisig));
        emit DisableConfirmed(SIGNER_AUDITOR, 0, 3);
        vm.expectEmit(true, false, false, true, address(multisig));
        emit AmmDisableExecuted(0, block.timestamp);
        vm.expectEmit(false, false, false, true, address(bridge));
        emit AmmDisabled(block.timestamp, rEth, rBold);

        vm.prank(SIGNER_AUDITOR);
        multisig.confirmDisable();

        assertTrue(multisig.executed(), "executed at threshold");
        assertTrue(bridge.ammDisabled(), "bridge kill switch fired");
        assertEq(bridge.ammReserveEth(), rEth, "ETH reserve preserved");
        assertEq(bridge.ammReserveBold(), rBold, "BOLD reserve preserved");

        vm.expectRevert(KnomosisBridge.AmmIsDisabled.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());
    }

    /// @notice Once executed, further confirmations and revocations revert
    ///         (the multisig is spent, mirroring the bridge's one-way flag).
    function test_afterExecution_confirmAndRevoke_revert() public {
        (KnomosisAmmDisasterRecoveryMultisig multisig,) = _deployWired();
        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        vm.prank(SIGNER_COMMUNITY_A);
        multisig.confirmDisable();
        vm.prank(SIGNER_AUDITOR);
        multisig.confirmDisable();

        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.AlreadyExecuted.selector);
        vm.prank(SIGNER_BACKUP);
        multisig.confirmDisable();

        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.AlreadyExecuted.selector);
        vm.prank(SIGNER_OPERATOR);
        multisig.revokeConfirmation();
    }

    /// @notice A revocation removes a live confirmation, so a later third
    ///         signature no longer reaches the threshold; re-confirming
    ///         afterwards completes the quorum and fires the switch.
    function test_revoke_blocksExecution_untilReconfirmed() public {
        (KnomosisAmmDisasterRecoveryMultisig multisig, KnomosisBridge bridge) = _deployWired();

        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        vm.prank(SIGNER_COMMUNITY_A);
        multisig.confirmDisable();

        // The operator stands down (incident judged resolved).
        vm.expectEmit(true, true, false, true, address(multisig));
        emit DisableConfirmationRevoked(SIGNER_OPERATOR, 0, 1);
        vm.prank(SIGNER_OPERATOR);
        multisig.revokeConfirmation();
        assertFalse(multisig.hasConfirmed(SIGNER_OPERATOR), "revocation recorded");

        // A third party confirms: only 2 live confirmations -> no execution.
        vm.prank(SIGNER_AUDITOR);
        multisig.confirmDisable();
        assertEq(multisig.confirmationCount(), 2, "revocation kept the count below threshold");
        assertFalse(bridge.ammDisabled(), "AMM still enabled after revocation");

        // The operator re-confirms: threshold reached, switch fires.
        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        assertTrue(bridge.ammDisabled(), "re-confirmation completes the quorum");
    }

    /// @notice Revoking without a live confirmation reverts.
    function test_revoke_withoutConfirmation_reverts() public {
        (KnomosisAmmDisasterRecoveryMultisig multisig,) = _deployWired();
        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.NothingToRevoke.selector);
        vm.prank(SIGNER_OPERATOR);
        multisig.revokeConfirmation();
    }

    // ------------------------------------------------------------------
    // Stale-confirmation expiry (group reset)
    // ------------------------------------------------------------------

    /// @notice Approvals gathered in an expired round cannot combine with a
    ///         fresh one: the late confirmation rolls the round and counts
    ///         as 1-of-3, so the switch does NOT fire.
    function test_expiredRound_resetsInsteadOfExecuting() public {
        (KnomosisAmmDisasterRecoveryMultisig multisig, KnomosisBridge bridge) = _deployWired();

        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        vm.prank(SIGNER_COMMUNITY_A);
        multisig.confirmDisable();
        assertFalse(multisig.roundExpired(), "round live inside the window");

        // The incident passes; the approvals are abandoned past the window.
        vm.warp(block.timestamp + multisig.CONFIRMATION_WINDOW() + 1);
        assertTrue(multisig.roundExpired(), "round expired past the window");

        vm.expectEmit(true, true, false, false, address(multisig));
        emit ConfirmationRoundExpired(0, 1);
        vm.prank(SIGNER_AUDITOR);
        multisig.confirmDisable();

        assertEq(multisig.roundId(), 1, "fresh round opened");
        assertEq(multisig.confirmationCount(), 1, "stale approvals discarded");
        assertFalse(multisig.executed(), "stale quorum did not execute");
        assertFalse(bridge.ammDisabled(), "AMM still enabled");

        // The discarded signers may confirm again in the fresh round.
        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        vm.prank(SIGNER_COMMUNITY_A);
        multisig.confirmDisable();
        assertTrue(bridge.ammDisabled(), "fresh coordinated round fires the switch");
    }

    /// @notice The full window is usable: a quorum completed exactly AT the
    ///         window boundary still executes (the strict `>` comparison).
    function test_confirmationAtWindowBoundary_executes() public {
        (KnomosisAmmDisasterRecoveryMultisig multisig, KnomosisBridge bridge) = _deployWired();

        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        vm.prank(SIGNER_COMMUNITY_A);
        multisig.confirmDisable();

        vm.warp(block.timestamp + multisig.CONFIRMATION_WINDOW());
        assertFalse(multisig.roundExpired(), "boundary instant is still inside the window");
        vm.prank(SIGNER_AUDITOR);
        multisig.confirmDisable();
        assertTrue(bridge.ammDisabled(), "boundary confirmation completes the quorum");
    }

    // ------------------------------------------------------------------
    // Wiring sanity
    // ------------------------------------------------------------------

    /// @notice The multisig holds ONLY the disaster-recovery power: even a
    ///         full quorum's execution leaves every other bridge control
    ///         untouched (the BOLD circuit stays open, deposits keep
    ///         working) — and a direct `emergencyDisableAmm` call from a
    ///         signer (rather than through the multisig) is rejected by the
    ///         bridge because the ROLE is the multisig, not the signer.
    function test_signersCannotBypassMultisig() public {
        (, KnomosisBridge bridge) = _deployWired();
        vm.expectRevert(KnomosisBridge.NotAmmDisasterRecovery.selector);
        vm.prank(SIGNER_OPERATOR);
        bridge.emergencyDisableAmm();
        assertFalse(bridge.ammDisabled(), "a lone signer cannot fire the switch directly");
    }

    /// @notice Post-execution, non-AMM bridge surfaces are untouched: the
    ///         BOLD circuit is still open and deposits still credit TVL
    ///         (the multisig's blast radius is exactly the AMM pause).
    function test_execution_leavesOtherBridgeControlsUntouched() public {
        (KnomosisAmmDisasterRecoveryMultisig multisig, KnomosisBridge bridge) = _deployWired();
        vm.prank(SIGNER_OPERATOR);
        multisig.confirmDisable();
        vm.prank(SIGNER_COMMUNITY_A);
        multisig.confirmDisable();
        vm.prank(SIGNER_AUDITOR);
        multisig.confirmDisable();
        assertTrue(bridge.ammDisabled(), "switch fired");

        assertFalse(bridge.boldCircuitClosed(), "BOLD circuit untouched");
        uint256 tvlBefore = bridge.totalLockedValue();
        vm.prank(lp);
        bridge.depositETHWithFee{value: 5 ether}(1000);
        assertEq(bridge.totalLockedValue(), tvlBefore + 5 ether, "deposits still work");
    }
}
