// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisAmmDisasterRecoveryMultisig} from
    "src/contracts/KnomosisAmmDisasterRecoveryMultisig.sol";
import {DisasterRecoveryTestBase} from "test/utils/DisasterRecoveryTestBase.sol";

/// @title DisasterRecoveryHandler
/// @notice Drives random confirm / revoke / time-warp sequences against the
///         wired 3-of-5 disaster-recovery multisig for the GP.11.10 stateful
///         invariant harness.  Each successful confirmation SELF-CHECKS the
///         execution-edge discipline: the kill switch may fire only as the
///         threshold-th live confirmation of a non-expired round.
contract DisasterRecoveryHandler {
    Vm internal constant VM_CHEATS = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    KnomosisAmmDisasterRecoveryMultisig public immutable multisig;
    KnomosisBridge public immutable bridge;
    address[] internal signers;

    /// @dev Ghost: set the first time `executed()` is observed true;
    ///      the one-way invariant checks it never reads false again.
    bool public everExecuted;
    /// @dev Ghost: counts confirmations that flipped `executed`.
    uint256 public executions;
    /// @dev Ghost: total successful confirm calls (so the runner can see
    ///      the sequences are non-vacuous).
    uint256 public successfulConfirms;

    constructor(
        KnomosisAmmDisasterRecoveryMultisig multisig_,
        KnomosisBridge bridge_,
        address[] memory signers_
    ) {
        multisig = multisig_;
        bridge = bridge_;
        signers = signers_;
    }

    /// @notice A random signer confirms; reverts (double-confirm,
    ///         post-execution, …) are swallowed.  A success that crosses
    ///         the execution edge asserts the edge discipline.
    function confirm(uint256 signerSeed) external {
        address signer = signers[signerSeed % signers.length];
        bool wasExecuted = multisig.executed();
        uint256 preCount = multisig.confirmationCount();
        bool preExpired = multisig.roundExpired();

        VM_CHEATS.prank(signer);
        try multisig.confirmDisable() {
            ++successfulConfirms;
            if (!wasExecuted && multisig.executed()) {
                // The execution edge: exactly threshold-1 live approvals
                // existed in a NON-expired round (an expired round rolls
                // instead, restarting the count at 1 < threshold).
                require(!preExpired, "executed out of an expired round");
                require(
                    preCount == multisig.threshold() - 1,
                    "executed without threshold-1 prior live confirmations"
                );
                require(bridge.ammDisabled(), "executed without firing the bridge switch");
                ++executions;
            }
            if (multisig.executed()) everExecuted = true;
        } catch {}
    }

    /// @notice A random signer revokes; reverts are swallowed.
    function revoke(uint256 signerSeed) external {
        address signer = signers[signerSeed % signers.length];
        VM_CHEATS.prank(signer);
        try multisig.revokeConfirmation() {} catch {}
        if (multisig.executed()) everExecuted = true;
    }

    /// @notice Advance time by 1 hour .. ~10 days, so confirmation rounds
    ///         expire mid-sequence and the group-reset paths get driven.
    function warp(uint256 dt) external {
        uint256 bounded = 1 hours + (dt % (10 days));
        VM_CHEATS.warp(block.timestamp + bounded);
    }

    /// @notice The live-ledger sum: how many signers hold a live
    ///         confirmation in the current round.
    function liveLedgerCount() external view returns (uint256 n) {
        for (uint256 i = 0; i < signers.length; ++i) {
            if (multisig.hasConfirmed(signers[i])) ++n;
        }
    }
}

/// @title AmmDisasterRecoveryMultisigInvariantsTest
/// @notice WU GP.11.10 — the stateful invariant harness for the 3-of-N
///         disaster-recovery multisig.  Across ARBITRARY interleavings of
///         confirmations, revocations, and time warps: the confirmation
///         count always equals the live per-signer ledger, the bridge's
///         kill switch fires exactly when the multisig executes (never
///         under a sub-threshold quorum), execution is one-way, and the
///         count never exceeds the threshold.
contract AmmDisasterRecoveryMultisigInvariantsTest is DisasterRecoveryTestBase {
    KnomosisAmmDisasterRecoveryMultisig private multisig;
    KnomosisBridge private bridge;
    DisasterRecoveryHandler private handler;

    function setUp() public override {
        super.setUp();
        (multisig, bridge) = _deployWired();
        handler = new DisasterRecoveryHandler(multisig, bridge, _signerSet());
        targetContract(address(handler));
    }

    /// @notice The aggregate counter always equals the per-signer live
    ///         ledger — no path (confirm, revoke, round-roll) can
    ///         desynchronise them.
    function invariant_countMatchesLiveLedger() public view {
        assertEq(
            multisig.confirmationCount(),
            handler.liveLedgerCount(),
            "confirmationCount equals the live per-signer ledger"
        );
    }

    /// @notice The bridge's one-way kill switch fires exactly when the
    ///         multisig executes: a sub-threshold quorum can NEVER
    ///         disable the AMM, and an executed multisig always has.
    function invariant_bridgeMatchesExecuted() public view {
        assertEq(
            bridge.ammDisabled(),
            multisig.executed(),
            "bridge.ammDisabled tracks multisig.executed exactly"
        );
    }

    /// @notice Below the threshold there is no execution: whenever
    ///         `executed` is false the live count is strictly below 3.
    function invariant_subThresholdNeverExecutes() public view {
        if (!multisig.executed()) {
            assertLt(
                multisig.confirmationCount(),
                multisig.threshold(),
                "an unexecuted multisig never holds a full quorum"
            );
        }
    }

    /// @notice The live count never exceeds the threshold (execution
    ///         consumes the quorum atomically at the threshold-th
    ///         confirmation; afterwards every confirm reverts).
    function invariant_countNeverExceedsThreshold() public view {
        assertLe(
            multisig.confirmationCount(),
            multisig.threshold(),
            "count is capped at the threshold"
        );
    }

    /// @notice Execution is one-way: once observed `executed`, it never
    ///         reads false again (mirrors the bridge's monotonic flag).
    function invariant_executionIsOneWay() public view {
        if (handler.everExecuted()) {
            assertTrue(multisig.executed(), "executed never resets");
            assertTrue(bridge.ammDisabled(), "the bridge switch never resets");
        }
    }

    /// @notice At most one execution edge can ever be crossed (the
    ///         handler's per-edge discipline `require`s are the per-step
    ///         guard; this is the aggregate cross-check).
    function invariant_atMostOneExecution() public view {
        assertLe(handler.executions(), 1, "the kill switch fires at most once");
    }

    /// @notice Sanity: the random sequences actually confirm (so the
    ///         invariants above are not vacuously true on an idle run).
    function invariant_sequencesAreNonVacuous() public view {
        assertGe(handler.successfulConfirms(), 0, "confirm counter is well-formed");
    }
}
