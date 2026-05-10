// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {CanonFaultProofMigration} from "src/contracts/CanonFaultProofMigration.sol";

/// @notice A minimal predecessor mock that exposes `migration()`.
///         The migration target is settable post-construction so
///         we can wire the bidirectional-consent dance for tests.
contract MockPredecessor {
    address public migration;
    function setMigration(address m) external {
        migration = m;
    }
}

/// @notice A predecessor with no `migration()` function — used for
///         negative testing of the bidirectional-consent revert.
contract MockPredecessorNoMigration {
    function someOtherFn() external pure returns (uint256) { return 42; }
}

/// @title CanonFaultProofMigrationTest
/// @notice Forge tests for the V1→V2 migration handoff
///         (Workstream-H WU H.9.2).
contract CanonFaultProofMigrationTest is Test {
    MockPredecessor private predecessor;
    address private successor = address(0xC0DE);

    bytes32 private constant DEPLOYMENT_ID = bytes32(uint256(0xCAFE));
    bytes32 private constant LAST_HASH = bytes32(uint256(0xDEAD));
    uint64 private constant LAST_IDX = 100;
    uint64 private constant GRACE = 216_000;

    function setUp() public {
        predecessor = new MockPredecessor();
    }

    /// @dev Deploy migration with bidirectional consent already wired:
    ///      compute the expected migration address via CREATE, then
    ///      pre-set the predecessor's `migration` to that address.
    function _deployMigration() internal returns (CanonFaultProofMigration) {
        // Deterministic CREATE address: sender + nonce.
        // We'll use a two-step approach: compute address via vm.computeCreateAddress,
        // wire the predecessor, then deploy.
        address expectedAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        predecessor.setMigration(expectedAddr);
        return new CanonFaultProofMigration(
            GRACE,
            address(predecessor),
            successor,
            LAST_HASH,
            LAST_IDX,
            DEPLOYMENT_ID
        );
    }

    /* -------- Constructor -------- */

    function test_constructor_with_consent_succeeds() public {
        CanonFaultProofMigration m = _deployMigration();
        assertEq(m.predecessor(), address(predecessor));
        assertEq(m.successor(), successor);
        assertEq(m.graceWindowBlocks(), GRACE);
        assertEq(m.v1LastFinalisedLogEntryHash(), LAST_HASH);
        assertEq(m.v1LastFinalisedLogIndex(), LAST_IDX);
        assertEq(m.deploymentId(), DEPLOYMENT_ID);
        assertFalse(m.activated());
    }

    function test_constructor_rejects_zero_predecessor() public {
        vm.expectRevert(CanonFaultProofMigration.ZeroAddress.selector);
        new CanonFaultProofMigration(
            GRACE, address(0), successor, LAST_HASH, LAST_IDX, DEPLOYMENT_ID);
    }

    function test_constructor_rejects_zero_successor() public {
        vm.expectRevert(CanonFaultProofMigration.ZeroAddress.selector);
        new CanonFaultProofMigration(
            GRACE, address(predecessor), address(0),
            LAST_HASH, LAST_IDX, DEPLOYMENT_ID);
    }

    function test_constructor_rejects_grace_too_short() public {
        vm.expectRevert(CanonFaultProofMigration.GraceTooShort.selector);
        new CanonFaultProofMigration(
            GRACE - 1, address(predecessor), successor,
            LAST_HASH, LAST_IDX, DEPLOYMENT_ID);
    }

    function test_constructor_rejects_predecessor_without_consent() public {
        // Predecessor doesn't have `migration` set ⇒ migration() returns
        // address(0) which doesn't match the to-be-deployed contract.
        vm.expectRevert(
            CanonFaultProofMigration.PredecessorDoesNotReferenceThisMigration.selector);
        new CanonFaultProofMigration(
            GRACE, address(predecessor), successor,
            LAST_HASH, LAST_IDX, DEPLOYMENT_ID);
    }

    function test_constructor_rejects_predecessor_with_no_migration_fn() public {
        MockPredecessorNoMigration noMigPred = new MockPredecessorNoMigration();
        vm.expectRevert(
            CanonFaultProofMigration.PredecessorDoesNotReferenceThisMigration.selector);
        new CanonFaultProofMigration(
            GRACE, address(noMigPred), successor,
            LAST_HASH, LAST_IDX, DEPLOYMENT_ID);
    }

    /* -------- activate -------- */

    function test_activate_after_grace_window_succeeds() public {
        CanonFaultProofMigration m = _deployMigration();
        vm.roll(block.number + GRACE + 1);
        m.activate();
        assertTrue(m.activated());
    }

    function test_activate_within_grace_window_rejected() public {
        CanonFaultProofMigration m = _deployMigration();
        vm.expectRevert(CanonFaultProofMigration.NotYetActivatable.selector);
        m.activate();
    }

    function test_activate_double_call_rejected() public {
        CanonFaultProofMigration m = _deployMigration();
        vm.roll(block.number + GRACE + 1);
        m.activate();
        vm.expectRevert(CanonFaultProofMigration.AlreadyActivated.selector);
        m.activate();
    }

    /* -------- Constants -------- */

    function test_min_grace_window_blocks_is_30_days() public {
        // 216_000 blocks at 12 s = 2_592_000 s = 30 days.
        CanonFaultProofMigration m = _deployMigration();
        assertEq(m.MIN_GRACE_WINDOW_BLOCKS(), 216_000);
    }

    /* -------- assertConsistent -------- */

    function test_assertConsistent_does_not_revert() public {
        CanonFaultProofMigration m = _deployMigration();
        m.assertConsistent();
    }
}
