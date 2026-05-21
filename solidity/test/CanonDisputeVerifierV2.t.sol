// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {CanonDisputeVerifierV2} from "src/contracts/CanonDisputeVerifierV2.sol";

/// @notice A minimal mock state-root submission contract.
contract MockStateRootSubmission {
}

/// @notice A trivial mock bridge (the verifier's `bridge` field is
///         reserved for forward-looking bridge-state queries; the
///         actual rollback goes through `stateRootSubmission`).
contract MockBridge {
    function dummy() external pure returns (uint8) { return 0; }
}

/// @title CanonDisputeVerifierV2Test
/// @notice Forge tests for the dual-path dispute verifier
///         (Workstream-H WU H.9.1).  Verifies the **signature-
///         checked** quorum path (the audit-fix replaces the
///         original `signers`-only API which trusted the caller).
contract CanonDisputeVerifierV2Test is Test {
    CanonDisputeVerifierV2 private verifier;
    MockStateRootSubmission private stateRootSubmission;
    MockBridge private bridge;

    address private faultProofGame = address(0xC0DE);
    address private sequencerStake = address(0xACE);
    address private attestor = address(0xBEEF);
    address[] private adjudicators;

    // Adjudicator signing keys.  Foundry's `vm.addr(k)` derives an
    // EOA from a private key `k`; we use small distinct keys for
    // deterministic test addresses.
    uint256 private constant ADJ1_KEY = 0xA0001;
    uint256 private constant ADJ2_KEY = 0xA0002;
    uint256 private constant ADJ3_KEY = 0xA0003;
    uint256 private constant NON_KEY  = 0xBAD01;  // not approved

    bytes32 private constant DEPLOYMENT_ID = bytes32(uint256(0xCAFE));
    uint8 private constant QUORUM = 2;

    uint8 private constant VERDICT_UPHELD   = 1;
    uint8 private constant VERDICT_REJECTED = 2;

    function setUp() public {
        stateRootSubmission = new MockStateRootSubmission();
        bridge = new MockBridge();

        // Adjudicators derived from known private keys for
        // signature-verified tests.
        adjudicators.push(vm.addr(ADJ1_KEY));
        adjudicators.push(vm.addr(ADJ2_KEY));
        adjudicators.push(vm.addr(ADJ3_KEY));

        verifier = new CanonDisputeVerifierV2(
            faultProofGame,
            address(stateRootSubmission),
            adjudicators,
            QUORUM,
            address(bridge),
            sequencerStake,
            attestor,
            DEPLOYMENT_ID
        );
    }

    /* -------- Helpers -------- */

    /// @notice Sign a verdict digest with a private key.  Returns
    ///         the 65-byte (v,r,s) signature in Ethereum's
    ///         canonical layout.
    function _sign(uint256 privKey, bytes32 digest)
        internal pure returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Compute the canonical verdict digest the contract
    ///         expects for `(disputeId, disputeHash, outcome)`.
    function _digest(uint256 disputeId, bytes32 disputeHash, uint8 outcome)
        internal view returns (bytes32)
    {
        return verifier.verdictDigest(disputeId, disputeHash, outcome);
    }

    /* -------- Constructor -------- */

    function test_constructor_sets_state() public view {
        assertEq(verifier.faultProofGame(), faultProofGame);
        assertEq(verifier.stateRootSubmission(), address(stateRootSubmission));
        assertEq(address(verifier.bridge()), address(bridge));
        assertEq(verifier.quorumThreshold(), QUORUM);
        assertEq(verifier.deploymentId(), DEPLOYMENT_ID);
    }

    function test_constructor_rejects_zero_faultProofGame() public {
        vm.expectRevert(CanonDisputeVerifierV2.ZeroAddress.selector);
        new CanonDisputeVerifierV2(
            address(0), address(stateRootSubmission), adjudicators,
            QUORUM, address(bridge), sequencerStake, attestor,
            DEPLOYMENT_ID);
    }

    function test_constructor_rejects_zero_stateRootSubmission() public {
        vm.expectRevert(CanonDisputeVerifierV2.ZeroAddress.selector);
        new CanonDisputeVerifierV2(
            faultProofGame, address(0), adjudicators,
            QUORUM, address(bridge), sequencerStake, attestor,
            DEPLOYMENT_ID);
    }

    function test_constructor_rejects_zero_bridge() public {
        vm.expectRevert(CanonDisputeVerifierV2.ZeroAddress.selector);
        new CanonDisputeVerifierV2(
            faultProofGame, address(stateRootSubmission), adjudicators,
            QUORUM, address(0), sequencerStake, attestor,
            DEPLOYMENT_ID);
    }

    function test_constructor_rejects_zero_quorum() public {
        vm.expectRevert(CanonDisputeVerifierV2.QuorumThresholdZero.selector);
        new CanonDisputeVerifierV2(
            faultProofGame, address(stateRootSubmission), adjudicators,
            0, address(bridge), sequencerStake, attestor, DEPLOYMENT_ID);
    }

    function test_constructor_rejects_quorum_above_set_size() public {
        vm.expectRevert(
          CanonDisputeVerifierV2.QuorumThresholdAboveSetSize.selector);
        new CanonDisputeVerifierV2(
            faultProofGame, address(stateRootSubmission), adjudicators,
            4, address(bridge), sequencerStake, attestor, DEPLOYMENT_ID);
    }

    function test_constructor_populates_approved_lookup() public view {
        assertTrue(verifier.isApproved(vm.addr(ADJ1_KEY)));
        assertTrue(verifier.isApproved(vm.addr(ADJ2_KEY)));
        assertTrue(verifier.isApproved(vm.addr(ADJ3_KEY)));
        assertFalse(verifier.isApproved(vm.addr(NON_KEY)));
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

    function test_finaliseFromFaultProof_records_upheld_status_only() public {
        uint256 id = verifier.fileDispute(bytes32(uint256(0xAAA)));
        vm.prank(faultProofGame);
        verifier.finaliseFromFaultProof(id, 1, 5);
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

    /* -------- finaliseFromQuorum (signature-checked) -------- */

    function test_finaliseFromQuorum_with_signed_quorum_upheld() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);
        bytes32 digest = _digest(id, hash, VERDICT_UPHELD);

        address[] memory signers = new address[](2);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(ADJ1_KEY, digest);
        sigs[1] = _sign(ADJ2_KEY, digest);

        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
        // No revert → status = UpheldByQuorum.
    }

    function test_finaliseFromQuorum_with_signed_quorum_rejected() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);
        bytes32 digest = _digest(id, hash, VERDICT_REJECTED);

        address[] memory signers = new address[](2);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(ADJ1_KEY, digest);
        sigs[1] = _sign(ADJ2_KEY, digest);

        verifier.finaliseFromQuorum(id, VERDICT_REJECTED, signers, sigs);
    }

    function test_finaliseFromQuorum_below_quorum_rejected() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);
        bytes32 digest = _digest(id, hash, VERDICT_UPHELD);

        address[] memory signers = new address[](1);
        signers[0] = vm.addr(ADJ1_KEY);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(ADJ1_KEY, digest);

        vm.expectRevert(
          abi.encodeWithSelector(
            CanonDisputeVerifierV2.InsufficientQuorum.selector, 1, 2));
        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
    }

    /// @notice CRITICAL SECURITY TEST: an attacker must NOT be able
    ///         to finalise a dispute just by LISTING adjudicator
    ///         addresses without their signatures.
    function test_finaliseFromQuorum_unsigned_listing_rejected() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);

        // Attacker lists adjudicator addresses with EMPTY signatures.
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = "";  // empty signature
        sigs[1] = "";

        vm.expectRevert(
          abi.encodeWithSelector(
            CanonDisputeVerifierV2.InsufficientQuorum.selector, 0, 2));
        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
    }

    /// @notice CRITICAL SECURITY TEST: an attacker with bogus
    ///         signatures (random bytes) must not pass.
    function test_finaliseFromQuorum_garbage_signatures_rejected() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);

        address[] memory signers = new address[](2);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        bytes[] memory sigs = new bytes[](2);
        // 65 bytes of garbage data — recovers to a wrong address.
        sigs[0] = abi.encodePacked(
          bytes32(uint256(0xDEAD)), bytes32(uint256(0xBEEF)), uint8(27));
        sigs[1] = abi.encodePacked(
          bytes32(uint256(0xCAFE)), bytes32(uint256(0xBABE)), uint8(27));

        vm.expectRevert(
          abi.encodeWithSelector(
            CanonDisputeVerifierV2.InsufficientQuorum.selector, 0, 2));
        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
    }

    /// @notice CRITICAL SECURITY TEST: signatures from a NON-approved
    ///         key (right shape but unauthorized signer) are discarded.
    function test_finaliseFromQuorum_nonApproved_signer_rejected() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);
        bytes32 digest = _digest(id, hash, VERDICT_UPHELD);

        address[] memory signers = new address[](2);
        signers[0] = vm.addr(ADJ1_KEY);   // approved
        signers[1] = vm.addr(NON_KEY);    // not approved
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(ADJ1_KEY, digest);
        sigs[1] = _sign(NON_KEY, digest); // valid sig but not approved

        // Only 1 approved signer counted; below quorum (2).
        vm.expectRevert(
          abi.encodeWithSelector(
            CanonDisputeVerifierV2.InsufficientQuorum.selector, 1, 2));
        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
    }

    /// @notice CRITICAL SECURITY TEST: duplicate signers count as 1.
    function test_finaliseFromQuorum_duplicate_signers_deduped() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);
        bytes32 digest = _digest(id, hash, VERDICT_UPHELD);

        // Same approved signer listed three times.
        address[] memory signers = new address[](3);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ1_KEY);
        signers[2] = vm.addr(ADJ1_KEY);
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _sign(ADJ1_KEY, digest);
        sigs[1] = _sign(ADJ1_KEY, digest);
        sigs[2] = _sign(ADJ1_KEY, digest);

        // Only 1 distinct approved signer; below quorum (2).
        vm.expectRevert(
          abi.encodeWithSelector(
            CanonDisputeVerifierV2.InsufficientQuorum.selector, 1, 2));
        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
    }

    /// @notice Cross-outcome replay: a signature for UPHELD must not
    ///         pass for REJECTED.
    function test_finaliseFromQuorum_cross_outcome_replay_blocked() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);
        // Sign the UPHELD digest...
        bytes32 upheldDigest = _digest(id, hash, VERDICT_UPHELD);

        address[] memory signers = new address[](2);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(ADJ1_KEY, upheldDigest);
        sigs[1] = _sign(ADJ2_KEY, upheldDigest);

        // ...then try to apply for REJECTED.  Signatures shouldn't
        // verify against the REJECTED digest.
        vm.expectRevert(
          abi.encodeWithSelector(
            CanonDisputeVerifierV2.InsufficientQuorum.selector, 0, 2));
        verifier.finaliseFromQuorum(id, VERDICT_REJECTED, signers, sigs);
    }

    /// @notice Cross-dispute replay: a signature for dispute X must
    ///         not pass for dispute Y.
    function test_finaliseFromQuorum_cross_dispute_replay_blocked() public {
        bytes32 hashX = bytes32(uint256(0xAAA));
        bytes32 hashY = bytes32(uint256(0xBBB));
        uint256 idX = verifier.fileDispute(hashX);
        uint256 idY = verifier.fileDispute(hashY);
        bytes32 digestX = _digest(idX, hashX, VERDICT_UPHELD);

        address[] memory signers = new address[](2);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(ADJ1_KEY, digestX);
        sigs[1] = _sign(ADJ2_KEY, digestX);

        // Apply X's signatures to Y → should fail.
        vm.expectRevert(
          abi.encodeWithSelector(
            CanonDisputeVerifierV2.InsufficientQuorum.selector, 0, 2));
        verifier.finaliseFromQuorum(idY, VERDICT_UPHELD, signers, sigs);
    }

    function test_finaliseFromQuorum_unknown_dispute_reverts() public {
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        sigs[0] = _sign(ADJ1_KEY, bytes32(0));
        sigs[1] = _sign(ADJ2_KEY, bytes32(0));
        vm.expectRevert(CanonDisputeVerifierV2.UnknownDispute.selector);
        verifier.finaliseFromQuorum(999, VERDICT_UPHELD, signers, sigs);
    }

    function test_finaliseFromQuorum_double_call_rejected() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);
        bytes32 digest = _digest(id, hash, VERDICT_UPHELD);

        address[] memory signers = new address[](2);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(ADJ1_KEY, digest);
        sigs[1] = _sign(ADJ2_KEY, digest);

        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
        vm.expectRevert(CanonDisputeVerifierV2.AlreadyDecided.selector);
        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
    }

    function test_finaliseFromQuorum_exact_quorum_succeeds() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);
        bytes32 digest = _digest(id, hash, VERDICT_UPHELD);

        address[] memory signers = new address[](2);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(ADJ1_KEY, digest);
        sigs[1] = _sign(ADJ2_KEY, digest);

        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
    }

    function test_finaliseFromQuorum_above_quorum_succeeds() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);
        bytes32 digest = _digest(id, hash, VERDICT_UPHELD);

        address[] memory signers = new address[](3);
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        signers[2] = vm.addr(ADJ3_KEY);
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _sign(ADJ1_KEY, digest);
        sigs[1] = _sign(ADJ2_KEY, digest);
        sigs[2] = _sign(ADJ3_KEY, digest);

        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
    }

    function test_finaliseFromQuorum_mismatched_lengths_rejected() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);

        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](1);  // length mismatch
        signers[0] = vm.addr(ADJ1_KEY);
        signers[1] = vm.addr(ADJ2_KEY);
        sigs[0] = "";

        vm.expectRevert(
          CanonDisputeVerifierV2.SignerSignatureCountMismatch.selector);
        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
    }

    function test_finaliseFromQuorum_too_many_signers_rejected() public {
        bytes32 hash = bytes32(uint256(0xAAA));
        uint256 id = verifier.fileDispute(hash);

        uint256 n = 65;  // exceeds MAX_VERDICT_SIGNERS = 64
        address[] memory signers = new address[](n);
        bytes[] memory sigs = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            signers[i] = vm.addr(ADJ1_KEY);
            sigs[i] = "";
        }

        vm.expectRevert(
          abi.encodeWithSelector(
            CanonDisputeVerifierV2.TooManySigners.selector, n, 64));
        verifier.finaliseFromQuorum(id, VERDICT_UPHELD, signers, sigs);
    }

    /* -------- assertConsistent -------- */

    function test_assertConsistent_does_not_revert() public view {
        verifier.assertConsistent();
    }
}
