// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CanonBridge} from "src/contracts/CanonBridge.sol";
import {CanonDisputeVerifier} from "src/contracts/CanonDisputeVerifier.sol";
import {CanonSequencerStake} from "src/contracts/CanonSequencerStake.sol";
import {CanonIdentityRegistry} from "src/contracts/CanonIdentityRegistry.sol";
import {CanonMigration} from "src/contracts/CanonMigration.sol";
import {CanonEip712} from "src/lib/CanonEip712.sol";
import {CREATE3} from "src/lib/CREATE3.sol";

import {Deployer} from "test/utils/Deployer.sol";

/// @title CanonMigrationTest
/// @notice Tests for the migration handoff mechanism.
///
///         **Audit-3 design correction (this test file).**  The
///         pre-audit-3 implementation had the constructor check
///         `successor.migration() == address(this)`, which silently
///         FROZE THE SUCCESSOR (the opposite of the intended
///         user-exit behaviour).  The audit-3 fix swaps the check
///         to `predecessor.migration() == address(this)` so the
///         predecessor (which the migration is meant to retire)
///         is the one whose circuit breaker fires on activation.
///         The successor's `migration` field is no longer
///         constrained by this constructor; it can be 0 (no future
///         migration) or point to V2's CanonMigration.
contract CanonMigrationTest is Test {
    Deployer private deployer;
    CanonBridge private bridge; // Deployer-built; migration = 0 (genesis)
    CanonDisputeVerifier private verifier;

    /// @notice Local copy of `CanonMigration.MIN_GRACE_WINDOW_BLOCKS`.
    uint256 private constant MIN_GRACE = 216_000;

    uint256 private constant ATTESTOR_PK = 0xA77E5701;
    address private attestor;
    address private sequencer = address(0xBEEF);
    address private user = address(0xA1);

    event MigrationProposed(
        address indexed predecessor,
        address indexed successor,
        bytes32 migrationStateRoot,
        uint64 migrationStateRootLogIdx,
        uint256 graceWindowBlocks,
        uint256 proposedAtBlock
    );
    event MigrationActivated(
        address indexed predecessor, address indexed successor, uint256 atBlock
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
            uint8(2), uint64(100), uint64(50),
            uint64(200), uint64(50),
            uint256(1000 ether), uint256(5000),
            rids, toks
        );
        bridge = d.bridge;
        verifier = d.verifier;
    }

    // ------------------------------------------------------------------
    // Constructor sanity tests
    // ------------------------------------------------------------------

    function test_min_grace_window_constant() public {
        // Build a properly-configured triple (predecessor +
        // successor + valid attestation) and read the constant.
        (CanonBridge predecessor, CanonBridge successor, address predictedMig)
            = _setupMigratable("min-grace-pred", "min-grace-suc");
        bytes memory sig = _signMigration(
            address(predecessor), address(successor), MIN_GRACE,
            bytes32(0), uint64(0), predictedMig, ATTESTOR_PK
        );
        CanonMigration mig = new CanonMigration(
            address(predecessor), address(successor), MIN_GRACE,
            bytes32(0), uint64(0), sig
        );
        assertEq(mig.MIN_GRACE_WINDOW_BLOCKS(), 216_000);
    }

    function test_constructor_reverts_on_zero_predecessor() public {
        bytes memory dummySig = new bytes(65);
        vm.expectRevert(CanonMigration.ZeroAddress.selector);
        new CanonMigration(
            address(0), address(bridge), MIN_GRACE,
            bytes32(0), uint64(0), dummySig
        );
    }

    function test_constructor_reverts_on_zero_successor() public {
        bytes memory dummySig = new bytes(65);
        vm.expectRevert(CanonMigration.ZeroAddress.selector);
        new CanonMigration(
            address(bridge), address(0), MIN_GRACE,
            bytes32(0), uint64(0), dummySig
        );
    }

    function test_constructor_reverts_on_self_migration() public {
        bytes memory dummySig = new bytes(65);
        vm.expectRevert(CanonMigration.SelfMigration.selector);
        new CanonMigration(
            address(bridge), address(bridge), MIN_GRACE,
            bytes32(0), uint64(0), dummySig
        );
    }

    function test_constructor_reverts_on_grace_too_short() public {
        // Set up a properly-configured predecessor + successor so
        // the GraceTooShort check is the FIRST thing that fires.
        (CanonBridge predecessor, CanonBridge successor,)
            = _setupMigratable("grace-pred", "grace-suc");
        bytes memory dummySig = new bytes(65);
        vm.expectRevert(CanonMigration.GraceTooShort.selector);
        new CanonMigration(
            address(predecessor), address(successor), MIN_GRACE - 1,
            bytes32(0), uint64(0), dummySig
        );
    }

    /// @notice Audit-3: the constructor check is now on the
    ///         PREDECESSOR (not the successor).  This test
    ///         confirms that a migration whose predecessor has a
    ///         WRONG migration field reverts with the renamed
    ///         `PredecessorDoesNotReferenceThisMigration`.
    function test_audit3_constructor_reverts_on_predecessor_does_not_reference()
        public
    {
        // Use the Deployer-built bridge as the predecessor — its
        // `migration` field is 0 (NOT pointing at the migration we
        // are about to deploy).  Successor with proper field is
        // irrelevant to the new check.
        CanonBridge wrongPredecessor = bridge; // migration = 0

        // Successor: any properly-shaped bridge (its migration
        // field is no longer checked).
        uint64 nonce0 = vm.getNonce(address(this));
        // The migration deploy will land at nonce N+1 (after the
        // successor deploy bumps nonce to N+1).
        address migAddr = vm.computeCreateAddress(address(this), uint256(nonce0) + 1);
        CanonBridge successor = _deployBridgeWithMigration(migAddr, "audit3-suc");
        bytes memory dummySig = new bytes(65);

        vm.expectRevert(
            CanonMigration.PredecessorDoesNotReferenceThisMigration.selector
        );
        new CanonMigration(
            address(wrongPredecessor), address(successor), MIN_GRACE,
            bytes32(0), uint64(0), dummySig
        );
    }

    function test_constructor_reverts_on_invalid_attestation() public {
        (CanonBridge predecessor, CanonBridge successor, address predictedMig)
            = _setupMigratable("invalid-att-pred", "invalid-att-suc");

        // Sign with the WRONG key (a non-attestor).
        uint256 evilPk = 0xEEEEEE;
        bytes memory wrongSig = _signMigration(
            address(predecessor), address(successor), MIN_GRACE,
            bytes32(0), uint64(0), predictedMig, evilPk
        );
        vm.expectRevert(CanonMigration.AttestationInvalid.selector);
        new CanonMigration(
            address(predecessor), address(successor), MIN_GRACE,
            bytes32(0), uint64(0), wrongSig
        );
    }

    function test_constructor_reverts_on_invalid_signature_length() public {
        (CanonBridge predecessor, CanonBridge successor,)
            = _setupMigratable("inv-len-pred", "inv-len-suc");
        bytes memory shortSig = hex"deadbeef";
        vm.expectRevert(CanonMigration.InvalidSignatureLength.selector);
        new CanonMigration(
            address(predecessor), address(successor), MIN_GRACE,
            bytes32(0), uint64(0), shortSig
        );
    }

    // ------------------------------------------------------------------
    // Happy-path: full migration lifecycle
    // ------------------------------------------------------------------

    function test_full_migration_lifecycle() public {
        bytes32 stateRoot = keccak256("frozen-state-root");
        uint64 stateRootLogIdx = 42;

        // Audit-3: predecessor's migration field = predictedMig
        // (so predecessor freezes when migration activates);
        // successor's migration field = 0 (so successor stays
        // operational post-activation).
        uint64 nonce0 = vm.getNonce(address(this));
        // Deploy order: predecessor (N) → successor (N+1) → migration (N+2).
        address predictedMig =
            vm.computeCreateAddress(address(this), uint256(nonce0) + 2);

        CanonBridge predecessor =
            _deployBridgeWithMigration(predictedMig, "predecessor-v1");
        // Successor's migration field is 0 — it doesn't need to
        // commit to any future migration to be deployable.
        CanonBridge successor =
            _deployBridgeWithMigration(address(0), "successor-v1");

        bytes memory sig = _signMigration(
            address(predecessor), address(successor), MIN_GRACE,
            stateRoot, stateRootLogIdx, predictedMig, ATTESTOR_PK
        );

        vm.expectEmit(true, true, false, true);
        emit MigrationProposed(
            address(predecessor), address(successor),
            stateRoot, stateRootLogIdx, MIN_GRACE, block.number
        );
        CanonMigration mig = new CanonMigration(
            address(predecessor), address(successor), MIN_GRACE,
            stateRoot, stateRootLogIdx, sig
        );

        assertEq(address(mig), predictedMig);
        assertFalse(mig.activated());
        assertEq(mig.predecessor(), address(predecessor));
        assertEq(mig.successor(), address(successor));
        assertEq(mig.migrationStateRoot(), stateRoot);
        assertEq(mig.migrationStateRootLogIdx(), stateRootLogIdx);

        // Activate prematurely → reverts.
        vm.expectRevert(CanonMigration.GraceNotElapsed.selector);
        mig.activate();

        // Roll past grace window; activate.
        vm.roll(block.number + MIN_GRACE);
        vm.expectEmit(true, true, false, true);
        emit MigrationActivated(address(predecessor), address(successor), block.number);
        mig.activate();

        assertTrue(mig.activated());

        // Re-activate reverts.
        vm.expectRevert(CanonMigration.AlreadyActivated.selector);
        mig.activate();

        // Predecessor's MigrationActivated breaker now trips on
        // state-shaping calls.
        vm.deal(user, 10 ether);
        vm.expectRevert(CanonBridge.MigrationActivated.selector);
        vm.prank(user);
        predecessor.depositETH{value: 1 ether}();

        // Audit-3 check: SUCCESSOR remains operational
        // post-activation (its migration field is 0, so its
        // circuit breaker doesn't fire).
        vm.prank(user);
        successor.depositETH{value: 1 ether}();
        assertEq(successor.totalLockedValue(), 1 ether);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @notice Set up a (predecessor, successor) pair and return
    ///         the predicted address of the next migration deploy.
    ///         Predecessor.migration is set to that prediction;
    ///         successor.migration is set to 0 (audit-3 design).
    ///
    ///         Nonce timeline:
    ///           nonce N   : deploy predecessor (CREATE bumps to N+1)
    ///           nonce N+1 : deploy successor   (CREATE bumps to N+2)
    ///           nonce N+2 : deploy migration   (CREATE bumps to N+3)
    function _setupMigratable(bytes memory predTag, bytes memory sucTag)
        internal
        returns (CanonBridge predecessor, CanonBridge successor, address predictedMig)
    {
        uint64 nonce0 = vm.getNonce(address(this));
        predictedMig = vm.computeCreateAddress(address(this), uint256(nonce0) + 2);
        predecessor = _deployBridgeWithMigration(predictedMig, predTag);
        successor = _deployBridgeWithMigration(address(0), sucTag);
    }

    /// @notice Deploy a fresh bridge with a specific `migration`
    ///         immutable.  Used to construct properly-pre-committed
    ///         predecessors (and migration-0 successors).
    function _deployBridgeWithMigration(address migrationAddr, bytes memory tag)
        internal
        returns (CanonBridge)
    {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new CanonBridge(
            CanonBridge.ConstructorArgs({
                canonVersionTag: keccak256(tag),
                attestor: attestor,
                disputeVerifier: address(verifier),
                sequencerStake: address(0x9999),
                migration: migrationAddr,
                disputeWindowBlocks: uint64(100),
                maxRedemptionWindowBlocks: uint64(50),
                maxAttestationStaleBlocks: uint64(200),
                cooldownBlocks: uint64(50),
                tvlCap: uint256(1000 ether),
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    function _signMigration(
        address predecessor_,
        address successor_,
        uint256 grace,
        bytes32 stateRoot,
        uint64 stateRootLogIdx,
        address migAddr,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 ds = CanonEip712.domainSeparator(
            "Knomosis", "1", block.chainid, uint256(0), migAddr
        );
        bytes32 sh = CanonEip712.migrationStructHash(
            CanonBridge(payable(predecessor_)).deploymentId(),
            CanonBridge(payable(successor_)).deploymentId(),
            stateRoot,
            stateRootLogIdx,
            grace
        );
        bytes32 digest = CanonEip712.digest(ds, sh);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
