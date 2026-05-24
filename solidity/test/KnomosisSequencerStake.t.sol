// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisDisputeVerifier} from "src/contracts/KnomosisDisputeVerifier.sol";
import {KnomosisSequencerStake} from "src/contracts/KnomosisSequencerStake.sol";
import {KnomosisIdentityRegistry} from "src/contracts/KnomosisIdentityRegistry.sol";

import {Deployer} from "test/utils/Deployer.sol";

contract KnomosisSequencerStakeTest is Test {
    KnomosisBridge private bridge;
    KnomosisDisputeVerifier private verifier;
    KnomosisSequencerStake private stake;
    KnomosisIdentityRegistry private registry;

    Deployer private deployer;

    uint256 private constant ATTESTOR_PK = 0xA77E5701;
    address private attestor;
    address private sequencer = address(0xBEEF);
    address private challenger = address(0xC0DE);
    address private notSequencer = address(0xDeadBeef);

    uint64 private constant DISPUTE_WINDOW = 100;
    uint256 private constant SLASH_RATIO_BPS = 5000; // 50%

    event Deposited(address indexed sequencer, uint256 amount, uint256 newTotal);
    event Withdrawn(address indexed sequencer, uint256 amount, uint256 newTotal);
    event Slashed(
        uint64 indexed disputeId,
        address indexed challenger,
        uint256 paidToChallenger,
        uint256 burned,
        uint256 newTotal
    );

    function setUp() public {
        attestor = vm.addr(ATTESTOR_PK);
        deployer = new Deployer();

        address[] memory adjudicators = new address[](2);
        adjudicators[0] = address(0xA001);
        adjudicators[1] = address(0xA002);

        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);

        Deployer.Deployment memory d = deployer.deployAll(
            attestor, sequencer, adjudicators,
            uint8(2), DISPUTE_WINDOW, uint64(50),
            uint64(200), uint64(50),
            uint256(1000 ether), SLASH_RATIO_BPS,
            rids, toks
        );
        bridge = d.bridge;
        verifier = d.verifier;
        stake = d.stake;
        registry = d.registry;

        vm.deal(sequencer, 100 ether);
        vm.deal(notSequencer, 100 ether);
    }

    // ------------------------------------------------------------------
    // Constructor / immutability
    // ------------------------------------------------------------------

    function test_constructor_pins_immutables() public view {
        assertEq(stake.sequencer(), sequencer);
        assertEq(stake.disputeVerifier(), address(verifier));
        assertEq(stake.bridge(), address(bridge));
        assertEq(stake.slashRatioBps(), SLASH_RATIO_BPS);
        assertEq(stake.disputeWindowBlocks(), DISPUTE_WINDOW);
        assertEq(stake.burnAddress(), address(0xdEaD));
    }

    function test_assertConsistent() public view {
        // Verifier was deployed with sequencerStake = stake's CREATE3
        // address; the back-pointer should be consistent.
        assertTrue(stake.assertConsistent());
    }

    function test_no_admin_surface() public {
        bytes4[] memory forbidden = new bytes4[](5);
        forbidden[0] = bytes4(keccak256("pause()"));
        forbidden[1] = bytes4(keccak256("unpause()"));
        forbidden[2] = bytes4(keccak256("setSlashRatio(uint256)"));
        forbidden[3] = bytes4(keccak256("transferOwnership(address)"));
        forbidden[4] = bytes4(keccak256("upgradeTo(address)"));
        for (uint256 i = 0; i < forbidden.length; ++i) {
            (bool ok,) = address(stake).call(abi.encodePacked(forbidden[i]));
            assertFalse(ok, "admin function unexpectedly callable");
        }
    }

    // ------------------------------------------------------------------
    // Deposit
    // ------------------------------------------------------------------

    function test_deposit_happy_path() public {
        vm.expectEmit(true, false, false, true);
        emit Deposited(sequencer, 10 ether, 10 ether);
        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();
        assertEq(stake.totalStaked(), 10 ether);
    }

    function test_deposit_reverts_on_non_sequencer() public {
        vm.expectRevert(KnomosisSequencerStake.NotSequencer.selector);
        vm.prank(notSequencer);
        stake.deposit{value: 10 ether}();
    }

    function test_deposit_accumulates() public {
        vm.startPrank(sequencer);
        stake.deposit{value: 10 ether}();
        stake.deposit{value: 5 ether}();
        vm.stopPrank();
        assertEq(stake.totalStaked(), 15 ether);
    }

    // ------------------------------------------------------------------
    // Withdraw
    // ------------------------------------------------------------------

    function test_withdraw_happy_path_when_no_open_dispute() public {
        vm.startPrank(sequencer);
        stake.deposit{value: 10 ether}();
        uint256 balBefore = sequencer.balance;
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(sequencer, 4 ether, 6 ether);
        stake.withdraw(4 ether);
        vm.stopPrank();

        assertEq(stake.totalStaked(), 6 ether);
        assertEq(sequencer.balance, balBefore + 4 ether);
    }

    function test_withdraw_reverts_on_non_sequencer() public {
        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();
        vm.expectRevert(KnomosisSequencerStake.NotSequencer.selector);
        vm.prank(notSequencer);
        stake.withdraw(1 ether);
    }

    function test_withdraw_reverts_on_zero_amount() public {
        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();
        vm.expectRevert(KnomosisSequencerStake.InsufficientStake.selector);
        vm.prank(sequencer);
        stake.withdraw(0);
    }

    function test_withdraw_reverts_on_overdraw() public {
        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();
        vm.expectRevert(KnomosisSequencerStake.InsufficientStake.selector);
        vm.prank(sequencer);
        stake.withdraw(11 ether);
    }

    function test_withdraw_blocked_during_dispute_window() public {
        // Submit a state root, then attempt withdrawal within window.
        bytes32 root = keccak256("r");
        bytes memory sig = _signStateRoot(root, 1);
        bridge.submitStateRoot(root, 1, sig);

        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();

        vm.expectRevert(KnomosisSequencerStake.WithdrawDuringOpenDispute.selector);
        vm.prank(sequencer);
        stake.withdraw(1 ether);
    }

    function test_withdraw_succeeds_after_dispute_window() public {
        bytes32 root = keccak256("r");
        bytes memory sig = _signStateRoot(root, 1);
        bridge.submitStateRoot(root, 1, sig);
        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();

        vm.roll(block.number + DISPUTE_WINDOW + 1);
        vm.prank(sequencer);
        stake.withdraw(1 ether);
        assertEq(stake.totalStaked(), 9 ether);
    }

    // ------------------------------------------------------------------
    // Slash
    // ------------------------------------------------------------------

    function test_slash_happy_path_50_percent() public {
        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();

        uint256 challengerBalBefore = challenger.balance;
        uint256 burnBalBefore = address(0xdEaD).balance;

        vm.expectEmit(true, true, false, true);
        emit Slashed(uint64(7), challenger, 5 ether, 5 ether, 0);
        // Caller must be the dispute verifier.  vm.prank to verifier address.
        vm.prank(address(verifier));
        stake.slash(7, challenger);

        assertEq(stake.totalStaked(), 0);
        assertEq(challenger.balance, challengerBalBefore + 5 ether);
        assertEq(address(0xdEaD).balance, burnBalBefore + 5 ether);
        assertTrue(stake.isSlashed(7));
    }

    function test_slash_reverts_on_non_disputeVerifier() public {
        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();
        vm.expectRevert(KnomosisSequencerStake.NotDisputeVerifier.selector);
        vm.prank(notSequencer);
        stake.slash(1, challenger);
    }

    function test_slash_idempotent_per_disputeId() public {
        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();

        vm.prank(address(verifier));
        stake.slash(1, challenger);

        // Second call with same disputeId reverts.
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisSequencerStake.AlreadySlashed.selector, uint64(1))
        );
        vm.prank(address(verifier));
        stake.slash(1, challenger);
    }

    function test_slash_distinct_disputeIds_independently_consumable() public {
        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();

        vm.prank(address(verifier));
        stake.slash(1, challenger);
        // Stake is now zero; second slash with disputeId=2 succeeds
        // (different id) but transfers nothing because the stake is
        // depleted.  The idempotency invariant only applies to the
        // disputeId, not the slash amount.
        vm.prank(address(verifier));
        stake.slash(2, challenger);
        assertTrue(stake.isSlashed(2));
        assertEq(stake.totalStaked(), 0);
    }

    function test_slash_sum_conservation() public {
        // Property: paid + burned == originalStake.  Holds for any
        // (stake, slashRatioBps) pair in [0, 10000].
        vm.prank(sequencer);
        stake.deposit{value: 100 ether}();

        uint256 challengerBalBefore = challenger.balance;
        uint256 burnBalBefore = address(0xdEaD).balance;

        vm.prank(address(verifier));
        stake.slash(1, challenger);

        uint256 paid = challenger.balance - challengerBalBefore;
        uint256 burned = address(0xdEaD).balance - burnBalBefore;
        assertEq(paid + burned, 100 ether);
        assertEq(paid, 50 ether);
        assertEq(burned, 50 ether);
    }

    function test_slash_reverts_on_zero_challenger() public {
        vm.prank(sequencer);
        stake.deposit{value: 10 ether}();
        vm.expectRevert(KnomosisSequencerStake.ZeroAddress.selector);
        vm.prank(address(verifier));
        stake.slash(1, address(0));
    }

    // ------------------------------------------------------------------
    // Bare-ETH rejection
    // ------------------------------------------------------------------

    function test_bare_eth_transfer_reverts() public {
        vm.deal(notSequencer, 1 ether);
        vm.prank(notSequencer);
        (bool ok,) = address(stake).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _signStateRoot(bytes32 root, uint64 idx) internal view returns (bytes memory) {
        // Re-derive what KnomosisBridge expects (mirrors the bridge test).
        bytes32 ds = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,uint256 rollupId,bytes verifyingContract)"
                ),
                keccak256(bytes("KnomosisBridge")),
                keccak256(bytes("1")),
                block.chainid,
                uint256(0),
                keccak256(abi.encodePacked(address(bridge)))
            )
        );
        bytes32 sh = keccak256(
            abi.encode(
                keccak256("StateRoot(bytes32 root,uint64 logIndexHigh,bytes32 deploymentId)"),
                root,
                uint256(idx),
                bridge.deploymentId()
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(bytes2(0x1901), ds, sh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, digest);
        return abi.encodePacked(r, s, v);
    }
}
