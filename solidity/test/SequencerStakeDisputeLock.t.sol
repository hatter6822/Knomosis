// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisDisputeVerifier} from "src/contracts/KnomosisDisputeVerifier.sol";
import {KnomosisSequencerStake} from "src/contracts/KnomosisSequencerStake.sol";

import {CBEDecode} from "src/lib/CBEDecode.sol";
import {Deployer} from "test/utils/Deployer.sol";

/// @notice A challenger that refuses every incoming ETH transfer.
///
///         Used to prove the bond ledger is genuinely pull-based: a
///         push refund to this contract would revert, and since
///         `finalizeUpheld` is the only way to clear an open dispute,
///         a revert there would leave the sequencer's stake locked
///         forever.  That is a strictly worse freeze than the one the
///         bond exists to price, so it must not be reachable.
contract RejectingChallenger {
    receive() external payable {
        revert("no ETH accepted");
    }

    function file(
        KnomosisDisputeVerifier verifier,
        uint64 impugnedLogIndex,
        uint8 claimVariant,
        bytes calldata evidenceBlob,
        uint256 bond
    ) external payable returns (uint64) {
        return verifier.fileDispute{value: bond}(impugnedLogIndex, claimVariant, evidenceBlob);
    }

    function claim(KnomosisDisputeVerifier verifier) external returns (uint256) {
        return verifier.claimBond();
    }
}

/// @title SequencerStakeDisputeLockTest
/// @notice Regression suite for the sequencer-stake withdrawal lock
///         and the challenger bond that prices it.
///
/// **The defect.**  `KnomosisSequencerStake.withdraw` consulted only
/// `IKnomosisBridge.hasOpenDisputeOlderThan`, which answers "was a
/// state root submitted inside the dispute window" — not "is a dispute
/// open".  With no state root ever submitted the getter returns
/// `false` unconditionally, so the sequencer could drain the escrow
/// with a dispute pending and the subsequent `slash` would find
/// `totalStaked == 0`.  Slashing, the entire economic backstop of the
/// dispute pipeline, was a no-op on demand.
///
/// Every lock test below deliberately runs with **no state root
/// submitted**, so `hasOpenDisputeOlderThan` is `false` and the only
/// thing that can block the withdrawal is the new
/// `openDisputeCount` check.  Reverting that check makes these tests
/// fail rather than pass for the wrong reason.
contract SequencerStakeDisputeLockTest is Test {
    KnomosisBridge private bridge;
    KnomosisDisputeVerifier private verifier;
    KnomosisSequencerStake private stake;

    uint256 private constant ADJ1_PK = 0xA1;
    uint256 private constant ADJ2_PK = 0xA2;

    address private adjudicator1;
    address private adjudicator2;
    address private attestor = address(0xA77E);
    address private sequencer = address(0xBEEF);
    address private challenger = address(0xC0DE);

    uint256 private constant BOND = 0.05 ether;
    uint256 private constant STAKE_AMOUNT = 10 ether;

    /// Cached because reading it inline would be an external
    /// staticcall in the argument list of a `vm.prank`ed call —
    /// which consumes the prank, so the filing would be attributed
    /// to this test contract instead of `challenger`.
    uint8 private doubleApply;

    function setUp() public {
        adjudicator1 = vm.addr(ADJ1_PK);
        adjudicator2 = vm.addr(ADJ2_PK);

        address[] memory adjudicators = new address[](2);
        adjudicators[0] = adjudicator1;
        adjudicators[1] = adjudicator2;

        Deployer.DeployParams memory p;
        p.attestor = attestor;
        p.sequencer = sequencer;
        p.adjudicators = adjudicators;
        p.quorumThreshold = 2;
        p.disputeWindowBlocks = 100;
        p.maxRedemptionWindowBlocks = 50;
        p.maxAttestationStaleBlocks = 200;
        p.cooldownBlocks = 50;
        p.tvlCap = 1000 ether;
        p.slashRatioBps = 5000;
        p.erc20ResourceIds = new uint64[](0);
        p.erc20TokenAddrs = new address[](0);
        p.challengerBond = BOND;

        Deployer.Deployment memory d = (new Deployer()).deployAllParams(p);
        bridge = d.bridge;
        verifier = d.verifier;
        stake = d.stake;
        doubleApply = verifier.CLAIM_DOUBLE_APPLY();

        vm.deal(sequencer, STAKE_AMOUNT);
        vm.prank(sequencer);
        stake.deposit{value: STAKE_AMOUNT}();

        vm.deal(challenger, 10 ether);
    }

    // ------------------------------------------------------------------
    // The lock itself
    // ------------------------------------------------------------------

    /// The baseline the defect hid behind: with no dispute open and no
    /// state root submitted, withdrawal is permitted.  Without this,
    /// the blocked-withdrawal test below could pass for any reason.
    function test_withdraw_allowed_when_no_dispute_open() public {
        assertEq(verifier.openDisputeCount(), 0);
        assertFalse(bridge.hasOpenDisputeOlderThan(0), "precondition: legacy lock is open");

        vm.prank(sequencer);
        stake.withdraw(1 ether);
        assertEq(stake.totalStaked(), STAKE_AMOUNT - 1 ether);
    }

    /// The regression: an open dispute blocks withdrawal even though
    /// the legacy `hasOpenDisputeOlderThan` oracle says nothing is
    /// happening.
    function test_withdraw_blocked_while_dispute_open() public {
        _file(uint64(7));
        assertEq(verifier.openDisputeCount(), 1);
        // The legacy oracle is FALSE here — this assertion is what
        // makes the revert below attributable to the new check.
        assertFalse(bridge.hasOpenDisputeOlderThan(0), "legacy oracle must not be the blocker");

        vm.prank(sequencer);
        vm.expectRevert(KnomosisSequencerStake.WithdrawDuringOpenDispute.selector);
        stake.withdraw(1 ether);

        assertEq(stake.totalStaked(), STAKE_AMOUNT, "stake must be untouched");
    }

    /// Even a dust withdrawal is refused: `slash` zeroes the whole
    /// balance, so no part of it is safely withdrawable while a
    /// dispute is live.
    function test_withdraw_blocked_for_any_amount_while_dispute_open() public {
        _file(uint64(7));
        vm.prank(sequencer);
        vm.expectRevert(KnomosisSequencerStake.WithdrawDuringOpenDispute.selector);
        stake.withdraw(1 wei);
    }

    /// Multiple open disputes; the lock lifts only when the last one
    /// closes, so an off-by-one in the counter is caught.
    function test_withdraw_unblocked_only_after_last_dispute_closes() public {
        uint64 idA = _file(uint64(7));
        uint64 idB = _file(uint64(9));
        assertEq(verifier.openDisputeCount(), 2);

        _finalizeRejected(idA, uint64(7));
        assertEq(verifier.openDisputeCount(), 1);
        vm.prank(sequencer);
        vm.expectRevert(KnomosisSequencerStake.WithdrawDuringOpenDispute.selector);
        stake.withdraw(1 ether);

        _finalizeRejected(idB, uint64(9));
        assertEq(verifier.openDisputeCount(), 0);
        vm.prank(sequencer);
        stake.withdraw(1 ether);
        assertEq(stake.totalStaked(), STAKE_AMOUNT - 1 ether);
    }

    /// Depositing more stake stays available while a dispute is open —
    /// the lock is on exit, not on entry.
    function test_deposit_allowed_while_dispute_open() public {
        _file(uint64(7));
        vm.deal(sequencer, 1 ether);
        vm.prank(sequencer);
        stake.deposit{value: 1 ether}();
        assertEq(stake.totalStaked(), STAKE_AMOUNT + 1 ether);
    }

    // ------------------------------------------------------------------
    // The bond that prices the lock
    // ------------------------------------------------------------------

    function test_fileDispute_requires_exact_bond() public {
        bytes memory ev = hex"01";
        uint8 variant = doubleApply;

        vm.prank(challenger);
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisDisputeVerifier.IncorrectChallengerBond.selector, uint256(0), BOND
            )
        );
        verifier.fileDispute(uint64(7), variant, ev);

        // Over-payment is refused too: absorbing the excess silently
        // would make a fat-fingered filing cost more than the posted
        // price with no way to reclaim the difference.
        vm.prank(challenger);
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisDisputeVerifier.IncorrectChallengerBond.selector, BOND + 1, BOND
            )
        );
        verifier.fileDispute{value: BOND + 1}(uint64(7), variant, ev);
    }

    function test_fileDispute_records_bond_and_holds_it() public {
        uint64 id = _file(uint64(7));
        assertEq(verifier.disputeBond(id), BOND);
        assertEq(address(verifier).balance, BOND);
        assertEq(verifier.bondCredit(challenger), 0, "not settled until a verdict");
    }

    function test_bond_forfeited_to_sequencer_on_rejected() public {
        uint64 id = _file(uint64(7));
        _finalizeRejected(id, uint64(7));

        assertEq(verifier.disputeBond(id), 0);
        assertEq(verifier.bondCredit(challenger), 0, "a wrong challenger is not refunded");
        assertEq(verifier.bondCredit(sequencer), BOND, "the griefed party is compensated");

        uint256 before = sequencer.balance;
        vm.prank(sequencer);
        uint256 paid = verifier.claimBond();
        assertEq(paid, BOND);
        assertEq(sequencer.balance, before + BOND);
        assertEq(verifier.bondCredit(sequencer), 0);
    }

    function test_bond_refunded_to_challenger_on_upheld() public {
        uint64 id = _fileDoubleApplyUpholdable(uint64(7));
        _finalizeUpheld(id, uint64(7));

        assertEq(verifier.disputeBond(id), 0);
        assertEq(verifier.bondCredit(challenger), BOND, "a correct challenger is made whole");

        uint256 before = challenger.balance;
        vm.prank(challenger);
        uint256 paid = verifier.claimBond();
        assertEq(paid, BOND);
        assertEq(challenger.balance, before + BOND);
    }

    function test_claimBond_reverts_with_nothing_credited() public {
        vm.prank(challenger);
        vm.expectRevert(KnomosisDisputeVerifier.NoBondToClaim.selector);
        verifier.claimBond();
    }

    /// Bond settlement must not be push: a challenger that rejects ETH
    /// would otherwise make `finalizeUpheld` revert, and with the
    /// dispute stuck open the sequencer's stake would be frozen
    /// permanently.  The credit ledger makes the terminal transition
    /// unconditional and leaves the un-collectable bond parked.
    function test_hostile_challenger_cannot_block_finalisation() public {
        RejectingChallenger hostile = new RejectingChallenger();
        vm.deal(address(hostile), 1 ether);

        (bytes memory blob,) = _upholdableConcat(uint64(7));
        uint64 id = hostile.file{value: BOND}(verifier, uint64(7), doubleApply, blob, BOND);

        // The terminal transition succeeds despite BOTH ETH legs
        // targeting a recipient that refuses transfers: the bond
        // refund (verifier) and the slash reward (stake) are each
        // credited, not pushed.
        _finalizeUpheld(id, uint64(7));
        assertEq(verifier.openDisputeCount(), 0, "the stake lock must lift");
        assertEq(verifier.bondCredit(address(hostile)), BOND);
        assertEq(
            stake.slashCredit(address(hostile)),
            (STAKE_AMOUNT * 5000) / 10_000,
            "the slash reward is credited, not pushed"
        );

        // The slash zeroed the escrow; re-fund it so the withdrawal
        // below tests the lock rather than the balance guard.
        vm.deal(sequencer, 1 ether);
        vm.prank(sequencer);
        stake.deposit{value: 1 ether}();

        // The sequencer can now exit, which is the property the whole
        // test is protecting: a hostile challenger cannot convert a
        // won dispute into a permanent stake freeze.
        vm.prank(sequencer);
        stake.withdraw(1 wei);

        // Pulling still fails for the hostile contract on both
        // ledgers — but that is its own problem, not a liveness
        // failure of the pipeline.
        vm.expectRevert(KnomosisDisputeVerifier.BondTransferFailed.selector);
        hostile.claim(verifier);
    }

    /// A deployment may set the bond to zero (permissioned filing by
    /// other means); the lock must still work and settlement must be
    /// a no-op rather than a revert.
    function test_zero_bond_deployment_still_locks() public {
        address[] memory adjudicators = new address[](2);
        adjudicators[0] = adjudicator1;
        adjudicators[1] = adjudicator2;

        Deployer.Deployment memory d = (new Deployer()).deployAll(
            attestor, sequencer, adjudicators,
            uint8(2), uint64(100), uint64(50), uint64(200), uint64(50),
            uint256(1000 ether), uint256(5000),
            new uint64[](0), new address[](0)
        );
        assertEq(d.verifier.challengerBond(), 0);

        vm.deal(sequencer, 1 ether);
        vm.prank(sequencer);
        d.stake.deposit{value: 1 ether}();

        uint8 variant = d.verifier.CLAIM_DOUBLE_APPLY();
        vm.prank(challenger);
        d.verifier.fileDispute(uint64(7), variant, hex"01");
        assertEq(d.verifier.openDisputeCount(), 1);

        vm.prank(sequencer);
        vm.expectRevert(KnomosisSequencerStake.WithdrawDuringOpenDispute.selector);
        d.stake.withdraw(1 wei);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// File a dispute whose re-evidence will be REJECTED (distinct
    /// signers), returning its id.
    function _file(uint64 impugnedIdx) internal returns (uint64 id) {
        bytes memory blob = _concatBlob(impugnedIdx + 1, _entry(1, 5), _entry(2, 5));
        vm.prank(challenger);
        id = verifier.fileDispute{value: BOND}(impugnedIdx, doubleApply, blob);
    }

    /// File a dispute whose re-evidence will be UPHELD (same signer
    /// AND nonce across two distinct log indices — a genuine double
    /// apply).
    function _fileDoubleApplyUpholdable(uint64 impugnedIdx) internal returns (uint64 id) {
        (bytes memory blob,) = _upholdableConcat(impugnedIdx);
        vm.prank(challenger);
        id = verifier.fileDispute{value: BOND}(impugnedIdx, doubleApply, blob);
    }

    function _upholdableConcat(uint64 impugnedIdx)
        internal
        pure
        returns (bytes memory blob, uint64 secondaryIdx)
    {
        secondaryIdx = impugnedIdx + 1;
        blob = _concatBlob(secondaryIdx, _entry(1, 5), _entry(1, 5));
    }

    function _finalizeRejected(uint64 id, uint64 impugnedIdx) internal {
        bytes memory blob = _concatBlob(impugnedIdx + 1, _entry(1, 5), _entry(2, 5));
        (address[] memory signers, bytes[] memory sigs) =
            _quorum(id, verifier.VERDICT_REJECTED());
        verifier.finalizeRejected(id, blob, address(0), signers, sigs);
    }

    function _finalizeUpheld(uint64 id, uint64 impugnedIdx) internal {
        (bytes memory blob,) = _upholdableConcat(impugnedIdx);
        (address[] memory signers, bytes[] memory sigs) =
            _quorum(id, verifier.VERDICT_UPHELD());
        verifier.finalizeUpheld(id, blob, address(0), signers, sigs);
    }

    function _quorum(uint64 disputeId, uint8 outcome)
        internal
        view
        returns (address[] memory signers, bytes[] memory sigs)
    {
        bytes32 digest = verifier.verdictDigest(disputeId, outcome);
        signers = new address[](2);
        sigs = new bytes[](2);
        signers[0] = adjudicator1;
        signers[1] = adjudicator2;
        sigs[0] = _sign(ADJ1_PK, digest);
        sigs[1] = _sign(ADJ2_PK, digest);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ---- CBE builders (mirroring KnomosisDisputeVerifier.t.sol) ----

    function _entry(uint64 signer, uint64 nonce) internal pure returns (bytes memory) {
        return bytes.concat(
            _cborBytes32(bytes32(0)),
            _cborBytes32(keccak256(abi.encode(signer, nonce))),
            _cborUint(signer),
            _cborUint(nonce),
            _cborBytesEncoding(hex"01")
        );
    }

    /// `uint(secondaryLogIndex) ++ array(2) ++ bytes(a) ++ bytes(b)`,
    /// the shape `_runDoubleApplyFromConcat` decodes.
    function _concatBlob(uint64 secondaryIdx, bytes memory a, bytes memory b)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            _cborUint(secondaryIdx),
            _cborHead(CBEDecode.TAG_ARRAY, uint64(2)),
            _cborBytesEncoding(a),
            _cborBytesEncoding(b)
        );
    }

    function _cborHead(uint8 tag, uint64 n) internal pure returns (bytes memory) {
        bytes memory head = new bytes(9);
        head[0] = bytes1(tag);
        for (uint64 i = 0; i < 8; ++i) {
            head[1 + uint256(i)] = bytes1(uint8((n >> (8 * i)) & 0xFF));
        }
        return head;
    }

    function _cborUint(uint64 n) internal pure returns (bytes memory) {
        return _cborHead(CBEDecode.TAG_UINT, n);
    }

    function _cborBytesEncoding(bytes memory payload) internal pure returns (bytes memory) {
        return bytes.concat(_cborHead(CBEDecode.TAG_BYTES, uint64(payload.length)), payload);
    }

    function _cborBytes32(bytes32 b) internal pure returns (bytes memory) {
        return _cborBytesEncoding(abi.encodePacked(b));
    }
}
