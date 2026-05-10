// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {CanonDisputeVerifierV2} from "src/contracts/CanonDisputeVerifierV2.sol";

/// @notice A mock bridge that records the latest revert call.
contract MockBridge {
    uint64 public lastRevertedFrom;
    bool public revertCalled;
    function revertStateRootsFrom(uint64 idx) external {
        lastRevertedFrom = idx;
        revertCalled = true;
    }
}

/// @title CanonDisputeVerifierV2Test
/// @notice Forge tests for the dual-path dispute verifier
///         (Workstream-H WU H.9.1).
contract CanonDisputeVerifierV2Test is Test {
    CanonDisputeVerifierV2 private verifier;
    MockBridge private bridge;

    address private faultProofGame = address(0xC0DE);
    address private sequencerStake = address(0xACE);
    address private attestor = address(0xBEEF);
    address[] private adjudicators;

    bytes32 private constant DEPLOYMENT_ID = bytes32(uint256(0xCAFE));
    uint8 private constant QUORUM = 2;

    function setUp() public {
        bridge = new MockBridge();
        adjudicators.push(address(0xA1));
        adjudicators.push(address(0xA2));
        adjudicators.push(address(0xA3));

        verifier = new CanonDisputeVerifierV2(
            faultProofGame,
            adjudicators,
            QUORUM,
            address(bridge),
            sequencerStake,
            attestor,
            DEPLOYMENT_ID
        );
    }

    /* -------- Constructor -------- */

    function test_constructor_sets_state() public view {
        assertEq(verifier.faultProofGame(), faultProofGame);
        assertEq(address(verifier.bridge()), address(bridge));
        assertEq(verifier.quorumThreshold(), QUORUM);
        assertEq(verifier.deploymentId(), DEPLOYMENT_ID);
    }

    function test_constructor_rejects_zero_faultProofGame() public {
        vm.expectRevert(CanonDisputeVerifierV2.ZeroAddress.selector);
        new CanonDisputeVerifierV2(
            address(0), adjudicators, QUORUM, address(bridge),
            sequencerStake, attestor, DEPLOYMENT_ID);
    }

    function test_constructor_rejects_zero_bridge() public {
        vm.expectRevert(CanonDisputeVerifierV2.ZeroAddress.selector);
        new CanonDisputeVerifierV2(
            faultProofGame, adjudicators, QUORUM, address(0),
            sequencerStake, attestor, DEPLOYMENT_ID);
    }

    /* -------- fileDispute -------- */

    function test_fileDispute_returns_id() public {
        uint256 id1 = verifier.fileDispute(bytes32(uint256(0xAAA)));
        uint256 id2 = verifier.fileDispute(bytes32(uint256(0xBBB)));
        assertEq(id1, 1);
        assertEq(id2, 2);
    }

    /* -------- finaliseFromFaultProof -------- */

    function test_finaliseFromFaultProof_only_faultProofGame() public {
        uint256 id = verifier.fileDispute(bytes32(uint256(0xAAA)));
        vm.expectRevert(CanonDisputeVerifierV2.NotFaultProofGame.selector);
        verifier.finaliseFromFaultProof(id, 1, 5);
    }

    function test_finaliseFromFaultProof_triggers_bridge_revert() public {
        uint256 id = verifier.fileDispute(bytes32(uint256(0xAAA)));
        vm.prank(faultProofGame);
        verifier.finaliseFromFaultProof(id, 1, 5);
        assertTrue(bridge.revertCalled());
        assertEq(bridge.lastRevertedFrom(), 5);
    }

    function test_finaliseFromFaultProof_unknown_dispute_reverts() public {
        vm.prank(faultProofGame);
        vm.expectRevert(CanonDisputeVerifierV2.UnknownDispute.selector);
        verifier.finaliseFromFaultProof(999, 1, 5);
    }

    function test_finaliseFromFaultProof_double_call_rejected() public {
        uint256 id = verifier.fileDispute(bytes32(uint256(0xAAA)));
        vm.prank(faultProofGame);
        verifier.finaliseFromFaultProof(id, 1, 5);
        vm.prank(faultProofGame);
        vm.expectRevert(CanonDisputeVerifierV2.AlreadyDecided.selector);
        verifier.finaliseFromFaultProof(id, 1, 5);
    }

    /* -------- finaliseFromQuorum -------- */

    function test_finaliseFromQuorum_with_quorum_succeeds() public {
        uint256 id = verifier.fileDispute(bytes32(uint256(0xAAA)));
        address[] memory signers = new address[](2);
        signers[0] = address(0xA1);
        signers[1] = address(0xA2);
        verifier.finaliseFromQuorum(id, signers);
        // No revert ⇒ status = UpheldByQuorum.
    }

    function test_finaliseFromQuorum_below_quorum_rejected() public {
        uint256 id = verifier.fileDispute(bytes32(uint256(0xAAA)));
        address[] memory signers = new address[](1);
        signers[0] = address(0xA1);
        vm.expectRevert(CanonDisputeVerifierV2.InsufficientQuorum.selector);
        verifier.finaliseFromQuorum(id, signers);
    }

    function test_finaliseFromQuorum_unapproved_signer_skipped() public {
        uint256 id = verifier.fileDispute(bytes32(uint256(0xAAA)));
        // Two signers, one approved + one not.
        address[] memory signers = new address[](2);
        signers[0] = address(0xA1);    // approved
        signers[1] = address(0xBAD);   // not approved
        // Only 1 approved counted; below quorum (2).
        vm.expectRevert(CanonDisputeVerifierV2.InsufficientQuorum.selector);
        verifier.finaliseFromQuorum(id, signers);
    }

    function test_finaliseFromQuorum_unknown_dispute_reverts() public {
        address[] memory signers = new address[](2);
        signers[0] = address(0xA1);
        signers[1] = address(0xA2);
        vm.expectRevert(CanonDisputeVerifierV2.UnknownDispute.selector);
        verifier.finaliseFromQuorum(999, signers);
    }

    /* -------- assertConsistent -------- */

    function test_assertConsistent_does_not_revert() public view {
        verifier.assertConsistent();
    }
}
