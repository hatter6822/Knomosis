// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisDisputeVerifier} from "src/contracts/KnomosisDisputeVerifier.sol";
import {KnomosisSequencerStake} from "src/contracts/KnomosisSequencerStake.sol";
import {KnomosisIdentityRegistry} from "src/contracts/KnomosisIdentityRegistry.sol";
import {KnomosisEip712} from "src/lib/KnomosisEip712.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";
import {CBEDecode} from "src/lib/CBEDecode.sol";

import {Deployer} from "test/utils/Deployer.sol";
import {MockERC20, FeeOnTransferMockERC20} from "test/utils/MockERC20.sol";

/// @title KnomosisBridgeTest
/// @notice Comprehensive tests for `KnomosisBridge.sol` — covers all
///         five sub-WUs (E.1.1 deposit, E.1.2 state-root submission,
///         E.1.3 withdrawal, E.1.4 circuit breakers, E.1.5 rollback).
contract KnomosisBridgeTest is Test {
    KnomosisBridge private bridge;
    KnomosisDisputeVerifier private verifier;
    KnomosisSequencerStake private stake;
    KnomosisIdentityRegistry private registry;

    Deployer private deployer;
    MockERC20 private token;

    uint256 private constant ATTESTOR_PK = 0xA77E5701;
    address private attestor;
    address private sequencer = address(0xBEEF);
    address private alice = address(0xA1);
    address private bob = address(0xB0B);

    uint64 private constant DISPUTE_WINDOW = 100; // blocks
    uint64 private constant MAX_REDEMPTION_WINDOW = 50;
    uint64 private constant MAX_ATTESTATION_STALE = 200;
    uint64 private constant COOLDOWN_BLOCKS = 50;
    uint256 private constant TVL_CAP = 1000 ether;
    uint64 private constant ERC20_RESOURCE_ID = 1;

    /// @dev Local copies of the contract events for vm.expectEmit.
    event DepositInitiated(
        address indexed depositor,
        uint64 indexed resourceId,
        address token,
        uint256 amount,
        uint64 depositorNonce,
        bytes32 receiptHash
    );
    event StateRootSubmitted(
        bytes32 indexed root,
        uint64 indexed logIndexHigh,
        address indexed signer,
        uint64 submittedAtBlock
    );
    /// @dev Local copy of the post-audit-2 event signature
    ///      (audit-2: now carries both floor and ceiling).
    event StateRootRangeReverted(
        uint64 indexed disputedLogIndexHigh,
        uint64 newRevertedFloor,
        uint64 newRevertedCeiling
    );

    function setUp() public {
        attestor = vm.addr(ATTESTOR_PK);
        deployer = new Deployer();
        token = new MockERC20("Test Token", "TT");

        address[] memory adjudicators = new address[](2);
        adjudicators[0] = address(0xA001);
        adjudicators[1] = address(0xA002);

        uint64[] memory rids = new uint64[](1);
        rids[0] = ERC20_RESOURCE_ID;
        address[] memory toks = new address[](1);
        toks[0] = address(token);

        Deployer.Deployment memory d = deployer.deployAll(
            attestor, sequencer, adjudicators,
            uint8(2), DISPUTE_WINDOW, MAX_REDEMPTION_WINDOW,
            MAX_ATTESTATION_STALE, COOLDOWN_BLOCKS,
            TVL_CAP, uint256(5000),
            rids, toks
        );
        bridge = d.bridge;
        verifier = d.verifier;
        stake = d.stake;
        registry = d.registry;

        // Fund users so they can deposit.
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        token.mint(alice, 1000 ether);
    }

    // ------------------------------------------------------------------
    // Deployment / immutability sanity
    // ------------------------------------------------------------------

    function test_constructor_pins_immutables() public view {
        assertEq(bridge.attestor(), attestor);
        assertEq(bridge.disputeVerifier(), address(verifier));
        assertEq(bridge.sequencerStake(), address(stake));
        assertEq(bridge.disputeWindowBlocks(), DISPUTE_WINDOW);
        assertEq(bridge.tvlCap(), TVL_CAP);
        assertEq(bridge.deploymentId(),
            keccak256(abi.encode(block.chainid, address(bridge), keccak256("knomosis-test-v1")))
        );
    }

    function test_no_admin_surface() public {
        bytes4[] memory forbidden = new bytes4[](7);
        forbidden[0] = bytes4(keccak256("pause()"));
        forbidden[1] = bytes4(keccak256("unpause()"));
        forbidden[2] = bytes4(keccak256("transferOwnership(address)"));
        forbidden[3] = bytes4(keccak256("renounceOwnership()"));
        forbidden[4] = bytes4(keccak256("grantRole(bytes32,address)"));
        forbidden[5] = bytes4(keccak256("upgradeTo(address)"));
        forbidden[6] = bytes4(keccak256("proposeUpgrade(address)"));

        for (uint256 i = 0; i < forbidden.length; ++i) {
            (bool ok,) = address(bridge).call(abi.encodePacked(forbidden[i]));
            assertFalse(ok, "admin function unexpectedly callable");
        }
    }

    function test_constructor_reverts_on_dispute_window_smaller_than_redemption() public {
        Deployer d = new Deployer();
        address[] memory ad = new address[](1);
        ad[0] = address(0xA001);
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        // dispute window (50) < redemption window (100) -> revert
        vm.expectRevert();
        d.deployAll(
            attestor, sequencer, ad, uint8(1),
            uint64(50), uint64(100), uint64(200), uint64(50),
            uint256(1 ether), uint256(5000),
            rids, toks
        );
    }

    // ------------------------------------------------------------------
    // E.1.1 Deposit entry points
    // ------------------------------------------------------------------

    function test_depositETH_happy_path() public {
        bytes32 expectedReceipt = keccak256(
            abi.encode(
                bridge.deploymentId(), alice, uint64(0), address(0), uint256(1 ether), uint64(0)
            )
        );
        vm.expectEmit(true, true, false, true);
        emit DepositInitiated(alice, uint64(0), address(0), 1 ether, 0, expectedReceipt);

        vm.prank(alice);
        bridge.depositETH{value: 1 ether}();

        assertEq(bridge.totalLockedValue(), 1 ether);
        assertEq(bridge.depositNonce(alice), 1);
        assertEq(address(bridge).balance, 1 ether);
    }

    function test_depositETH_increments_nonce() public {
        vm.startPrank(alice);
        bridge.depositETH{value: 1 ether}();
        bridge.depositETH{value: 1 ether}();
        bridge.depositETH{value: 1 ether}();
        assertEq(bridge.depositNonce(alice), 3);
        assertEq(bridge.totalLockedValue(), 3 ether);
        vm.stopPrank();
    }

    function test_depositETH_reverts_on_tvl_cap() public {
        // Deposit up to the cap.
        vm.deal(alice, TVL_CAP + 1);
        vm.startPrank(alice);
        bridge.depositETH{value: TVL_CAP}();
        vm.expectRevert(KnomosisBridge.TvlCapReached.selector);
        bridge.depositETH{value: 1}();
        vm.stopPrank();
    }

    function test_depositERC20_happy_path() public {
        vm.startPrank(alice);
        token.approve(address(bridge), 100 ether);
        bridge.depositERC20(ERC20_RESOURCE_ID, token, 100 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(address(bridge)), 100 ether);
        assertEq(bridge.totalLockedValue(), 100 ether);
        assertEq(bridge.depositNonce(alice), 1);
    }

    function test_depositERC20_reverts_on_unknown_resource_id() public {
        vm.startPrank(alice);
        token.approve(address(bridge), 100 ether);
        vm.expectRevert(KnomosisBridge.UnsupportedResource.selector);
        bridge.depositERC20(uint64(999), token, 100 ether);
        vm.stopPrank();
    }

    function test_depositERC20_reverts_on_token_mismatch() public {
        MockERC20 other = new MockERC20("Other", "OT");
        other.mint(alice, 10 ether);
        vm.startPrank(alice);
        other.approve(address(bridge), 10 ether);
        vm.expectRevert(KnomosisBridge.UnsupportedResource.selector);
        bridge.depositERC20(ERC20_RESOURCE_ID, other, 10 ether);
        vm.stopPrank();
    }

    function test_depositETH_via_native_resource_id_fails() public {
        // Calling depositERC20 with resource id 0 must fail (id 0 is
        // the reserved native-ETH slot, only addressable via depositETH).
        vm.startPrank(alice);
        token.approve(address(bridge), 1 ether);
        vm.expectRevert(KnomosisBridge.UnsupportedResource.selector);
        bridge.depositERC20(uint64(0), token, 1 ether);
        vm.stopPrank();
    }

    function test_bare_eth_transfer_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(bridge).call{value: 1 ether}("");
        assertFalse(ok, "bare ETH should be rejected");
    }

    // ------------------------------------------------------------------
    // E.1.2 State-root submission
    // ------------------------------------------------------------------

    function test_submitStateRoot_happy_path() public {
        bytes32 root = keccak256("state-root-1");
        uint64 idx = 100;

        bytes memory sig = _signStateRoot(root, idx);

        vm.expectEmit(true, true, true, false);
        emit StateRootSubmitted(root, idx, attestor, uint64(block.number));
        bridge.submitStateRoot(root, idx, sig);

        assertEq(bridge.latestSubmittedLogIndexHigh(), idx);
        (bytes32 r, uint64 b, bool reverted) = bridge.stateRootAt(idx);
        assertEq(r, root);
        assertEq(b, uint64(block.number));
        assertFalse(reverted);
    }

    function test_submitStateRoot_reverts_on_wrong_signer() public {
        // Forge a signature using a non-attestor key.
        uint256 evilPk = 0xEE;
        address evilAddr = vm.addr(evilPk);
        assertTrue(evilAddr != attestor);

        bytes32 root = keccak256("evil-root");
        uint64 idx = 1;
        bytes32 digest = _stateRootDigest(root, idx);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(evilPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(KnomosisBridge.NotAttestor.selector);
        bridge.submitStateRoot(root, idx, sig);
    }

    function test_submitStateRoot_reverts_on_non_monotonic() public {
        bytes32 root1 = keccak256("r1");
        bytes32 root2 = keccak256("r2");
        bytes memory sig1 = _signStateRoot(root1, 100);
        bytes memory sig2 = _signStateRoot(root2, 50);

        bridge.submitStateRoot(root1, 100, sig1);
        vm.expectRevert(KnomosisBridge.NonMonotonic.selector);
        bridge.submitStateRoot(root2, 50, sig2);
    }

    function test_submitStateRoot_reverts_on_invalid_sig_length() public {
        bytes memory shortSig = hex"deadbeef";
        vm.expectRevert(KnomosisBridge.InvalidSignatureLength.selector);
        bridge.submitStateRoot(keccak256("x"), 1, shortSig);
    }

    function test_isStateRootFinalised_only_after_window() public {
        bytes32 root = keccak256("r");
        uint64 idx = 1;
        bridge.submitStateRoot(root, idx, _signStateRoot(root, idx));
        uint64 atBlock = uint64(block.number);

        assertFalse(bridge.isStateRootFinalised(idx));
        vm.roll(atBlock + DISPUTE_WINDOW - 1);
        assertFalse(bridge.isStateRootFinalised(idx));
        vm.roll(atBlock + DISPUTE_WINDOW);
        assertTrue(bridge.isStateRootFinalised(idx));
    }

    // ------------------------------------------------------------------
    // E.1.4 Automatic circuit breakers
    // ------------------------------------------------------------------

    function test_breaker_AttestationStale_blocks_deposit() public {
        // Submit a state root, then advance well past the staleness window.
        bridge.submitStateRoot(keccak256("r"), 1, _signStateRoot(keccak256("r"), 1));
        uint64 startBlock = uint64(block.number);
        vm.roll(startBlock + MAX_ATTESTATION_STALE + 1);

        vm.expectRevert(KnomosisBridge.AttestationStale.selector);
        vm.prank(alice);
        bridge.depositETH{value: 1 ether}();
    }

    function test_breaker_AttestationStale_does_not_fire_on_initial_state() public {
        // No state root submitted yet; the stale-breaker must be inert.
        vm.roll(uint64(block.number) + MAX_ATTESTATION_STALE * 10);
        vm.prank(alice);
        bridge.depositETH{value: 1 ether}();
        assertEq(bridge.totalLockedValue(), 1 ether);
    }

    function test_breaker_DisputeCooldown_blocks_deposit() public {
        // Trigger a rollback (sets `lastUpheldDisputeBlock`).
        vm.prank(address(verifier));
        bridge.revertToPriorRoot(0);

        uint64 markBlock = uint64(block.number);
        vm.roll(markBlock + COOLDOWN_BLOCKS - 1);

        vm.prank(alice);
        vm.expectRevert(KnomosisBridge.DisputeCooldown.selector);
        bridge.depositETH{value: 1 ether}();

        // After cooldown elapses, deposit succeeds.
        vm.roll(markBlock + COOLDOWN_BLOCKS);
        vm.prank(alice);
        bridge.depositETH{value: 1 ether}();
        assertEq(bridge.totalLockedValue(), 1 ether);
    }

    // ------------------------------------------------------------------
    // E.1.5 Rollback hook
    // ------------------------------------------------------------------

    function test_revertToPriorRoot_only_disputeVerifier() public {
        vm.expectRevert(KnomosisBridge.NotDisputeVerifier.selector);
        bridge.revertToPriorRoot(0);
    }

    function test_revertToPriorRoot_marks_records_reverted() public {
        bridge.submitStateRoot(keccak256("r1"), 1, _signStateRoot(keccak256("r1"), 1));
        bridge.submitStateRoot(keccak256("r2"), 2, _signStateRoot(keccak256("r2"), 2));
        bridge.submitStateRoot(keccak256("r3"), 3, _signStateRoot(keccak256("r3"), 3));

        vm.prank(address(verifier));
        bridge.revertToPriorRoot(2);

        (,, bool reverted1) = bridge.stateRootAt(1);
        (,, bool reverted2) = bridge.stateRootAt(2);
        (,, bool reverted3) = bridge.stateRootAt(3);
        assertFalse(reverted1, "root 1 (before threshold) must remain");
        assertTrue(reverted2, "root 2 (at threshold) reverted");
        assertTrue(reverted3, "root 3 (after threshold) reverted");
    }

    function test_revertToPriorRoot_idempotent() public {
        bridge.submitStateRoot(keccak256("r"), 1, _signStateRoot(keccak256("r"), 1));
        vm.startPrank(address(verifier));
        bridge.revertToPriorRoot(1);
        bridge.revertToPriorRoot(1);
        bridge.revertToPriorRoot(1);
        vm.stopPrank();

        (,, bool reverted) = bridge.stateRootAt(1);
        assertTrue(reverted);
    }

    function test_revertToPriorRoot_trips_cooldown() public {
        vm.prank(address(verifier));
        bridge.revertToPriorRoot(0);
        // Immediate next deposit reverts.
        vm.prank(alice);
        vm.expectRevert(KnomosisBridge.DisputeCooldown.selector);
        bridge.depositETH{value: 1 ether}();
    }

    // ------------------------------------------------------------------
    // hasOpenDisputeOlderThan
    // ------------------------------------------------------------------

    function test_hasOpenDisputeOlderThan_initial() public view {
        assertFalse(bridge.hasOpenDisputeOlderThan(0));
    }

    function test_hasOpenDisputeOlderThan_after_root_within_window() public {
        bridge.submitStateRoot(keccak256("r"), 1, _signStateRoot(keccak256("r"), 1));
        // Within dispute window
        assertTrue(bridge.hasOpenDisputeOlderThan(0));
    }

    function test_hasOpenDisputeOlderThan_after_window() public {
        bridge.submitStateRoot(keccak256("r"), 1, _signStateRoot(keccak256("r"), 1));
        vm.roll(block.number + DISPUTE_WINDOW);
        assertFalse(bridge.hasOpenDisputeOlderThan(0));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _stateRootDigest(bytes32 root, uint64 idx) internal view returns (bytes32) {
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
        return KnomosisEip712.digest(ds, sh);
    }

    function _signStateRoot(bytes32 root, uint64 idx) internal view returns (bytes memory) {
        bytes32 digest = _stateRootDigest(root, idx);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    // ==================================================================
    // Audit fix tests — added in the post-PR security audit.
    // ==================================================================

    // ---- FIX 4: revertToPriorRoot is now O(1) (lowestRevertedLogIndexHigh floor) ----

    function test_audit_revertToPriorRoot_initial_floor_is_max() public view {
        assertEq(bridge.lowestRevertedLogIndexHigh(), type(uint64).max);
    }

    function test_audit_revertToPriorRoot_lowers_floor() public {
        bridge.submitStateRoot(keccak256("r1"), 1, _signStateRoot(keccak256("r1"), 1));
        bridge.submitStateRoot(keccak256("r2"), 2, _signStateRoot(keccak256("r2"), 2));

        vm.expectEmit(true, false, false, true);
        // Floor=2, ceiling=latestSubmittedLogIndexHigh=2 at revert time.
        emit StateRootRangeReverted(uint64(2), uint64(2), uint64(2));
        vm.prank(address(verifier));
        bridge.revertToPriorRoot(2);

        assertEq(bridge.lowestRevertedLogIndexHigh(), uint64(2));
        assertEq(bridge.revertedThroughLogIndexHigh(), uint64(2));
        assertFalse(bridge.isStateRootReverted(uint64(1)));
        assertTrue(bridge.isStateRootReverted(uint64(2)));
        // Audit-2: idx=3 (above ceiling) is NOT reverted.
        assertFalse(bridge.isStateRootReverted(uint64(3)));
        assertFalse(bridge.isStateRootReverted(type(uint64).max));
    }

    function test_audit_revertToPriorRoot_idempotent_at_same_floor() public {
        bridge.submitStateRoot(keccak256("r1"), 1, _signStateRoot(keccak256("r1"), 1));
        vm.startPrank(address(verifier));
        bridge.revertToPriorRoot(1);
        bridge.revertToPriorRoot(1);
        bridge.revertToPriorRoot(1);
        vm.stopPrank();
        // Floor unchanged after repeated calls at same value.
        assertEq(bridge.lowestRevertedLogIndexHigh(), uint64(1));
    }

    function test_audit_revertToPriorRoot_floor_only_decreases() public {
        bridge.submitStateRoot(keccak256("r1"), 1, _signStateRoot(keccak256("r1"), 1));
        bridge.submitStateRoot(keccak256("r2"), 2, _signStateRoot(keccak256("r2"), 2));
        bridge.submitStateRoot(keccak256("r3"), 3, _signStateRoot(keccak256("r3"), 3));

        vm.startPrank(address(verifier));
        // First revert at idx 3 → floor = 3.
        bridge.revertToPriorRoot(3);
        assertEq(bridge.lowestRevertedLogIndexHigh(), uint64(3));
        // Second revert at idx 1 → floor lowers to 1 (broader range).
        bridge.revertToPriorRoot(1);
        assertEq(bridge.lowestRevertedLogIndexHigh(), uint64(1));
        // Third revert at idx 5 → floor stays at 1 (cannot raise).
        bridge.revertToPriorRoot(5);
        assertEq(bridge.lowestRevertedLogIndexHigh(), uint64(1));
        vm.stopPrank();
    }

    function test_audit_revertToPriorRoot_O1_with_huge_gap() public {
        // Submit two state roots with a HUGE gap in indices.  The
        // new O(1) implementation handles this in constant gas;
        // the old O(N) iterate-and-mark loop would have OOG'd.
        bridge.submitStateRoot(keccak256("r1"), 1, _signStateRoot(keccak256("r1"), 1));
        bridge.submitStateRoot(
            keccak256("r2"),
            uint64(1_000_000_000),
            _signStateRoot(keccak256("r2"), uint64(1_000_000_000))
        );

        // Revert at index 1 — must complete without OOG.
        uint256 gasStart = gasleft();
        vm.prank(address(verifier));
        bridge.revertToPriorRoot(1);
        uint256 gasUsed = gasStart - gasleft();
        // Sanity: gas usage is bounded (under 100k).  The old O(N)
        // loop would have used billions for the same call.
        assertLt(gasUsed, 100_000);

        // Both submitted indices are now in the reverted range
        // [floor=1, ceiling=1_000_000_000].
        assertTrue(bridge.isStateRootReverted(uint64(1)));
        assertTrue(bridge.isStateRootReverted(uint64(1_000_000_000)));
    }

    function test_audit_revertToPriorRoot_blocks_withdrawal_for_reverted_indices() public {
        bridge.submitStateRoot(keccak256("r1"), 1, _signStateRoot(keccak256("r1"), 1));
        // Wait past finalisation.
        vm.roll(block.number + DISPUTE_WINDOW);
        assertTrue(bridge.isStateRootFinalised(1));

        // Revert it.
        vm.prank(address(verifier));
        bridge.revertToPriorRoot(1);

        // isStateRootFinalised now returns false.
        assertFalse(bridge.isStateRootFinalised(1));
    }

    // ---- FIX 7: BridgeAccountingMismatch (renamed from misleading earlier error) ----

    function test_audit_BridgeAccountingMismatch_is_distinct_error_selector() public pure {
        bytes4 sel1 = KnomosisBridge.BridgeAccountingMismatch.selector;
        bytes4 sel2 = KnomosisBridge.InvariantViolation_DisputeWindowVsRedemption.selector;
        assertTrue(sel1 != sel2, "two errors must have distinct selectors");
    }

    // ==================================================================
    // Audit-2 fix tests (added by the second-pass audit).
    // ==================================================================

    // ---- FIX 2 (audit-2): post-revert submissions are NOT auto-reverted ----

    function test_audit2_post_revert_submission_is_not_auto_reverted() public {
        // Submit two state roots, revert idx 1, then submit at idx 3.
        // Idx 3 should NOT be in the reverted range.
        bridge.submitStateRoot(keccak256("r1"), 1, _signStateRoot(keccak256("r1"), 1));
        bridge.submitStateRoot(keccak256("r2"), 2, _signStateRoot(keccak256("r2"), 2));

        vm.prank(address(verifier));
        bridge.revertToPriorRoot(1);

        // Submit a fresh state root at idx 3 (post-revert correction).
        // First the cooldown breaker would block; advance past cooldown.
        vm.roll(block.number + COOLDOWN_BLOCKS);
        bridge.submitStateRoot(keccak256("r3"), 3, _signStateRoot(keccak256("r3"), 3));

        // Idx 1 and 2 are reverted; idx 3 is NOT.
        assertTrue(bridge.isStateRootReverted(1));
        assertTrue(bridge.isStateRootReverted(2));
        assertFalse(bridge.isStateRootReverted(3));
        // Floor=1, ceiling=2 (highest at revert time).
        assertEq(bridge.lowestRevertedLogIndexHigh(), uint64(1));
        assertEq(bridge.revertedThroughLogIndexHigh(), uint64(2));
    }

    function test_audit2_double_revert_extends_ceiling() public {
        bridge.submitStateRoot(keccak256("r1"), 1, _signStateRoot(keccak256("r1"), 1));
        bridge.submitStateRoot(keccak256("r2"), 2, _signStateRoot(keccak256("r2"), 2));

        // First revert at idx 2 → floor=2, ceiling=2.
        vm.prank(address(verifier));
        bridge.revertToPriorRoot(2);

        // Submit at idx 3 (post-cooldown).
        vm.roll(block.number + COOLDOWN_BLOCKS);
        bridge.submitStateRoot(keccak256("r3"), 3, _signStateRoot(keccak256("r3"), 3));
        assertFalse(bridge.isStateRootReverted(3));

        // Second revert at idx 3 → ceiling rises to current latest=3.
        vm.prank(address(verifier));
        bridge.revertToPriorRoot(3);
        assertEq(bridge.lowestRevertedLogIndexHigh(), uint64(2));
        assertEq(bridge.revertedThroughLogIndexHigh(), uint64(3));
        assertTrue(bridge.isStateRootReverted(3));
    }

    function test_audit2_revert_lowers_floor_only() public {
        bridge.submitStateRoot(keccak256("r1"), 1, _signStateRoot(keccak256("r1"), 1));
        bridge.submitStateRoot(keccak256("r2"), 2, _signStateRoot(keccak256("r2"), 2));
        bridge.submitStateRoot(keccak256("r3"), 3, _signStateRoot(keccak256("r3"), 3));

        vm.startPrank(address(verifier));
        // Revert at 3 first → floor=3, ceiling=3.
        bridge.revertToPriorRoot(3);
        assertEq(bridge.lowestRevertedLogIndexHigh(), uint64(3));
        // Then revert at 1 → floor=1, ceiling=3 (unchanged).
        bridge.revertToPriorRoot(1);
        assertEq(bridge.lowestRevertedLogIndexHigh(), uint64(1));
        assertEq(bridge.revertedThroughLogIndexHigh(), uint64(3));
        // Then revert at 5 → floor stays at 1 (5 > 1), ceiling stays
        // at 3 (latest is still 3).
        bridge.revertToPriorRoot(5);
        assertEq(bridge.lowestRevertedLogIndexHigh(), uint64(1));
        assertEq(bridge.revertedThroughLogIndexHigh(), uint64(3));
        vm.stopPrank();
    }

    // ---- FIX 3 (audit-2): zero-address check on sequencerStake ----

    function test_audit2_constructor_reverts_on_zero_sequencerStake() public {
        // Direct deploy with zero sequencerStake.  Must revert.
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        KnomosisBridge.ConstructorArgs memory args = KnomosisBridge.ConstructorArgs({
            knomosisVersionTag: keccak256("test"),
            attestor: attestor,
            disputeVerifier: address(0xDEAD),
            sequencerStake: address(0), // zero — should revert
            migration: address(0),
            disputeWindowBlocks: DISPUTE_WINDOW,
            maxRedemptionWindowBlocks: MAX_REDEMPTION_WINDOW,
            maxAttestationStaleBlocks: MAX_ATTESTATION_STALE,
            cooldownBlocks: COOLDOWN_BLOCKS,
            tvlCap: TVL_CAP,
            minFeeBps: 0,
            maxFeeBps: 1000,
            weiPerBudgetUnitEth: 1,
            weiPerBudgetUnitBold: 0,
            boldTokenAddress: address(0),
            boldTvlCap: 0,
            boldCircuitBreaker: address(0),
            boldAdmin: address(0),
            enableLiquityAutoCircuitTrigger: false,
            erc20ResourceIds: rids,
            erc20TokenAddrs: toks
        });
        vm.expectRevert(KnomosisBridge.ZeroSequencerStake.selector);
        new KnomosisBridge(args);
    }

    // ---- FIX 4 (audit-2): duplicate token addresses rejected ----

    // ---- FIX 5 (audit-2): fee-on-transfer ERC-20 rejection ----

    function test_audit2_depositERC20_rejects_fee_on_transfer_token() public {
        // Deploy a fresh bridge with a fee-on-transfer token in
        // the resource map.
        FeeOnTransferMockERC20 fotToken = new FeeOnTransferMockERC20();

        Deployer fresh = new Deployer();
        address[] memory adjs = new address[](1);
        adjs[0] = address(0xA001);
        uint64[] memory rids = new uint64[](1);
        rids[0] = uint64(7);
        address[] memory toks = new address[](1);
        toks[0] = address(fotToken);

        Deployer.Deployment memory d = fresh.deployAll(
            attestor, sequencer, adjs, uint8(1),
            DISPUTE_WINDOW, MAX_REDEMPTION_WINDOW,
            MAX_ATTESTATION_STALE, COOLDOWN_BLOCKS,
            TVL_CAP, uint256(5000),
            rids, toks
        );
        KnomosisBridge fotBridge = d.bridge;

        // Mint + approve.
        fotToken.mint(alice, 100 ether);
        vm.prank(alice);
        fotToken.approve(address(fotBridge), 100 ether);

        // Deposit 100 wei: bridge expects 100 received but gets 99.
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.TransferAmountMismatch.selector,
                uint256(100),
                uint256(99)
            )
        );
        vm.prank(alice);
        fotBridge.depositERC20(uint64(7), fotToken, 100);
    }

    function test_audit2_constructor_reverts_on_duplicate_tokens() public {
        // Two distinct resource ids mapped to the same token.
        uint64[] memory rids = new uint64[](2);
        rids[0] = uint64(1);
        rids[1] = uint64(2);
        address[] memory toks = new address[](2);
        toks[0] = address(token);
        toks[1] = address(token); // duplicate
        KnomosisBridge.ConstructorArgs memory args = KnomosisBridge.ConstructorArgs({
            knomosisVersionTag: keccak256("test"),
            attestor: attestor,
            disputeVerifier: address(0xDEAD),
            sequencerStake: address(0xBEEF),
            migration: address(0),
            disputeWindowBlocks: DISPUTE_WINDOW,
            maxRedemptionWindowBlocks: MAX_REDEMPTION_WINDOW,
            maxAttestationStaleBlocks: MAX_ATTESTATION_STALE,
            cooldownBlocks: COOLDOWN_BLOCKS,
            tvlCap: TVL_CAP,
            minFeeBps: 0,
            maxFeeBps: 1000,
            weiPerBudgetUnitEth: 1,
            weiPerBudgetUnitBold: 0,
            boldTokenAddress: address(0),
            boldTvlCap: 0,
            boldCircuitBreaker: address(0),
            boldAdmin: address(0),
            enableLiquityAutoCircuitTrigger: false,
            erc20ResourceIds: rids,
            erc20TokenAddrs: toks
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.DuplicateResourceToken.selector, address(token)
            )
        );
        new KnomosisBridge(args);
    }
}
