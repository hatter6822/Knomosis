// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {CanonStepVM} from "src/contracts/CanonStepVM.sol";

/// @title CanonStepVMTest
/// @notice Forge tests for the per-variant step VM (Workstream-H WUs
///         H.5.1 + H.5.2.*).  Tests cover (a) cell-proof verification
///         under the witness-state design, (b) the action-kind
///         dispatch, (c) per-variant gas budgets / bulk-action caps,
///         (d) error paths.
contract CanonStepVMTest is Test {
    CanonStepVM private stepVM;

    bytes32 private constant FIXTURE_PRE_COMMIT =
        bytes32(uint256(0xDEADBEEF));

    function setUp() public {
        stepVM = new CanonStepVM();
    }

    /* -------- Constants -------- */

    function test_constants_step_gas_cap_is_8M() public view {
        assertEq(stepVM.MAX_STEP_GAS(), 8_000_000);
    }

    function test_constants_bulk_recipients_cap_is_256() public view {
        assertEq(stepVM.MAX_RECIPIENTS_PER_BULK_ACTION(), 256);
    }

    /* -------- Cell-proof verification -------- */

    function _makeCellProof(
        uint8 cellKind,
        uint256 keyA,
        uint256 keyB,
        bytes memory cellValue,
        bytes32 witnessCommit
    ) internal pure returns (CanonStepVM.CellProof memory) {
        return CanonStepVM.CellProof({
            cellKind: cellKind,
            keyA: keyA,
            keyB: keyB,
            cellValue: cellValue,
            witnessCommit: witnessCommit
        });
    }

    function test_executeStep_rejects_mismatched_witness_commit() public {
        // A cell proof whose witnessCommit doesn't match preStateCommit
        // must trigger BadCellProof revert.
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0,            // CellKind.Balance
            1,            // keyA = resourceId
            10,           // keyB = actor
            new bytes(0), // empty cellValue (treated as 0)
            bytes32(uint256(0xBADC0DE))  // wrong witnessCommit
        );
        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(10), uint64(20), uint64(5));
        vm.expectRevert(CanonStepVM.BadCellProof.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT,
            uint8(0),  // ActionKind.Transfer
            actionFields,
            uint64(10),
            proofs);
    }

    /* -------- Action-kind dispatch -------- */

    function test_executeStep_unknown_action_kind_reverts() public {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        vm.expectRevert(CanonStepVM.UnknownActionKind.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT,
            uint8(99),  // out-of-range
            new bytes(0),
            uint64(0),
            proofs);
    }

    /* -------- Transfer step semantics -------- */

    function test_transfer_returns_deterministic_post_commit() public view {
        // Build a cell-proof bundle for a transfer of 5 from actor 10
        // to actor 20 of resource 1.
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](2);
        // Sender's balance: encode 100 as CBE Nat.
        bytes memory senderBalanceBytes = _encodeCbeNat(100);
        proofs[0] = _makeCellProof(
            0,                // Balance
            1, 10,            // (resource=1, actor=10)
            senderBalanceBytes,
            FIXTURE_PRE_COMMIT);
        // Receiver's balance: 50.
        proofs[1] = _makeCellProof(
            0, 1, 20,
            _encodeCbeNat(50),
            FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(10), uint64(20), uint64(5));
        bytes32 result1 = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(0), actionFields, uint64(10), proofs);
        bytes32 result2 = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(0), actionFields, uint64(10), proofs);
        assertEq(result1, result2, "transfer is deterministic");

        // Strong assertion (uniform recipe): the post-commit must
        // match the documented preimage exactly using the
        // `keccak256(abi.encodePacked(preCommit, TAG_TRANSFER,
        // fields...))` shape.  Sender pre=100, post=95; receiver
        // pre=50, post=55.
        bytes32 expected = keccak256(abi.encodePacked(
            FIXTURE_PRE_COMMIT,
            keccak256("transfer"),
            uint64(1), uint64(10), uint256(95),
            uint64(20), uint256(55),
            uint64(10)));
        assertEq(result1, expected,
            "transfer post-commit matches documented preimage");
    }

    /// @notice Audit-1 regression: self-transfer must produce net-zero
    ///         balance change, matching Lean's §4.11 post-debit
    ///         re-read pattern.
    function test_transfer_self_transfer_net_zero() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        // Self-transfer: sender == receiver.
        proofs[0] = _makeCellProof(
            0, 1, 10, _encodeCbeNat(100), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(10), uint64(10), uint64(5));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(0), actionFields, uint64(10), proofs);

        // Self-transfer: both balances stay 100 (the credit and
        // debit cancel on a single cell when sender == receiver).
        // tagHash is keccak256("transfer").
        bytes32 expected = keccak256(abi.encodePacked(
            FIXTURE_PRE_COMMIT,
            keccak256("transfer"),
            uint64(1), uint64(10), uint256(100),
            uint64(10), uint256(100),
            uint64(10)));
        assertEq(result, expected,
            "self-transfer produces net-zero balance change");
    }

    /// @notice DoS protection: a cell-proof bundle exceeding
    ///         MAX_CELL_PROOFS_PER_STEP must revert.
    function test_executeStep_rejects_oversize_cellproof_bundle() public {
        uint256 cap = stepVM.MAX_CELL_PROOFS_PER_STEP();
        CanonStepVM.CellProof[] memory proofs =
            new CanonStepVM.CellProof[](cap + 1);
        for (uint256 i = 0; i < cap + 1; i++) {
            proofs[i] = _makeCellProof(
                0, 1, i + 100, _encodeCbeNat(0), FIXTURE_PRE_COMMIT);
        }
        bytes memory actionFields = abi.encodePacked(uint64(1));
        vm.expectRevert(CanonStepVM.TooManyCellProofs.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(3),  // freezeResource
            actionFields, uint64(0), proofs);
    }

    /// @notice Audit-1 regression: burn rejects zero amount per
    ///         Lean's `Laws.burn` precondition.
    function test_burn_rejects_zero_amount() public {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 10, _encodeCbeNat(100), FIXTURE_PRE_COMMIT);
        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(10), uint64(0));
        vm.expectRevert(CanonStepVM.AmountMustBePositive.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(2), actionFields, uint64(10), proofs);
    }

    function test_transfer_rejects_zero_amount() public {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](2);
        proofs[0] = _makeCellProof(
            0, 1, 10, _encodeCbeNat(100), FIXTURE_PRE_COMMIT);
        proofs[1] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(50), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(10), uint64(20), uint64(0));
        vm.expectRevert(CanonStepVM.AmountMustBePositive.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(0), actionFields, uint64(10), proofs);
    }

    /// @notice SECURITY TEST: malformed cell values (data.length
    ///         between 1 and 8 bytes) must REVERT rather than
    ///         silently decode to 0.  Without this revert, an
    ///         adversarial responder could submit a truncated
    ///         cell value to spoof a zero balance and bypass the
    ///         `senderBalance < amount` check.
    function test_transfer_rejects_malformed_cell_value() public {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](2);
        // Malformed: 5-byte cellValue (should be 9 or 0).
        proofs[0] = _makeCellProof(
            0, 1, 10, hex"01020304ff", FIXTURE_PRE_COMMIT);
        proofs[1] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(50), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(10), uint64(20), uint64(10));
        vm.expectRevert(CanonStepVM.MalformedCellValue.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(0), actionFields, uint64(10), proofs);
    }

    function test_transfer_rejects_insufficient_balance() public {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](2);
        // Sender has 5 but tries to send 100.
        proofs[0] = _makeCellProof(
            0, 1, 10, _encodeCbeNat(5), FIXTURE_PRE_COMMIT);
        proofs[1] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(0), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(10), uint64(20), uint64(100));
        vm.expectRevert(CanonStepVM.InsufficientBalance.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(0), actionFields, uint64(10), proofs);
    }

    /* -------- Mint step semantics -------- */

    function test_mint_increases_balance() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(50), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(20), uint64(10));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(1), actionFields, uint64(0), proofs);

        // Strong (uniform recipe): mint of 10 to actor 20
        // (pre=50, post=60); tagHash is keccak256("mint").
        bytes32 expected = keccak256(abi.encodePacked(
            FIXTURE_PRE_COMMIT, keccak256("mint"),
            uint64(1), uint64(20), uint256(60), uint64(0)));
        assertEq(result, expected, "mint post-commit matches preimage");
    }

    function test_mint_rejects_zero_amount() public {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(50), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(20), uint64(0));
        vm.expectRevert(CanonStepVM.AmountMustBePositive.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(1), actionFields, uint64(0), proofs);
    }

    /* -------- Burn step semantics -------- */

    function test_burn_decreases_balance() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 10, _encodeCbeNat(100), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(10), uint64(50));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(2), actionFields, uint64(10), proofs);

        // Strong (uniform recipe): burn 50 from actor 10
        // (pre=100, post=50); tagHash is keccak256("burn").
        bytes32 expected = keccak256(abi.encodePacked(
            FIXTURE_PRE_COMMIT, keccak256("burn"),
            uint64(1), uint64(10), uint256(50), uint64(10)));
        assertEq(result, expected, "burn post-commit matches preimage");
    }

    function test_burn_rejects_insufficient_balance() public {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 10, _encodeCbeNat(5), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(10), uint64(100));
        vm.expectRevert(CanonStepVM.InsufficientBalance.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(2), actionFields, uint64(10), proofs);
    }

    /* -------- FreezeResource step semantics -------- */

    function test_freezeResource_kernel_identity() public view {
        // freezeResource is kernel-identity (no balance reads).
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        bytes memory actionFields = abi.encodePacked(uint64(1));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(3), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "freezeResource produces commit");
    }

    /* -------- Reward step semantics -------- */

    function test_reward_credits_recipient() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(50), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(20), uint64(10));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(5), actionFields, uint64(0), proofs);

        // Strong (uniform recipe): reward 10 to actor 20
        // (pre=50, post=60); tagHash is keccak256("reward").
        bytes32 expected = keccak256(abi.encodePacked(
            FIXTURE_PRE_COMMIT, keccak256("reward"),
            uint64(1), uint64(20), uint256(60), uint64(0)));
        assertEq(result, expected, "reward post-commit matches preimage");
    }

    /* -------- DistributeOthers (bulk) -------- */

    function test_distributeOthers_iterates_recipients() public view {
        // 3 balance proofs; one excluded (actor 5).
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](3);
        proofs[0] = _makeCellProof(
            0, 1, 10, _encodeCbeNat(50), FIXTURE_PRE_COMMIT);
        proofs[1] = _makeCellProof(
            0, 1, 5, _encodeCbeNat(100), FIXTURE_PRE_COMMIT);  // excluded
        proofs[2] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(75), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(5), uint64(10));  // excluded = 5, amount = 10
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(6), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "distributeOthers produces commit");
    }

    /* -------- ProportionalDilute (bulk) -------- */

    /// @notice Cross-stack precondition test: Lean's
    ///         `Laws.proportionalDilute` requires both
    ///         `totalReward > 0` AND `sumOthers > 0`.  With no
    ///         non-excluded recipients, `sumOthers = 0`, and the
    ///         action must REVERT to match Lean's rejection.
    function test_proportionalDilute_rejects_zero_sumOthers() public {
        // No non-excluded recipients ⇒ sumOthers = 0.
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 5, _encodeCbeNat(100), FIXTURE_PRE_COMMIT);  // excluded

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(5), uint64(50));
        vm.expectRevert(CanonStepVM.AmountMustBePositive.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(7), actionFields, uint64(0), proofs);
    }

    /// @notice Cross-stack precondition test: `totalReward == 0`
    ///         must revert (Lean's `Laws.proportionalDilute`
    ///         requires `totalReward > 0`).
    function test_proportionalDilute_rejects_zero_totalReward() public {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](2);
        proofs[0] = _makeCellProof(
            0, 1, 10, _encodeCbeNat(100), FIXTURE_PRE_COMMIT);
        proofs[1] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(50), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(5), uint64(0));  // totalReward = 0
        vm.expectRevert(CanonStepVM.AmountMustBePositive.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(7), actionFields, uint64(0), proofs);
    }

    /// @notice Cross-stack precondition test: `_stepReward`
    ///         requires `amount > 0` (Lean's `Laws.reward`).
    function test_reward_rejects_zero_amount() public {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(50), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(20), uint64(0));
        vm.expectRevert(CanonStepVM.AmountMustBePositive.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(5), actionFields, uint64(0), proofs);
    }

    /// @notice Cross-stack precondition test: `_stepDistributeOthers`
    ///         requires `amount > 0` (Lean's
    ///         `Laws.distributeOthers`).
    function test_distributeOthers_rejects_zero_amount() public {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(50), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(5), uint64(0));  // amount = 0
        vm.expectRevert(CanonStepVM.AmountMustBePositive.selector);
        stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(6), actionFields, uint64(0), proofs);
    }

    /* -------- Dispute pipeline (kernel-identity actions) -------- */

    function test_dispute_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        bytes memory actionFields = new bytes(0);
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(8), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "dispute produces commit");
    }

    function test_disputeWithdraw_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        bytes memory actionFields = abi.encodePacked(uint64(0));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(9), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "disputeWithdraw produces commit");
    }

    function test_verdict_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        bytes memory actionFields = new bytes(0);
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(10), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "verdict produces commit");
    }

    function test_rollback_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        bytes memory actionFields = abi.encodePacked(uint64(0));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(11), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "rollback produces commit");
    }

    /* -------- Identity / bridge actions -------- */

    function test_registerIdentity_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        bytes memory actionFields = abi.encodePacked(uint64(10));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(12), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "registerIdentity produces commit");
    }

    function test_deposit_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 20, _encodeCbeNat(0), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(20), uint64(10), uint64(42));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(13), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "deposit produces commit");
    }

    function test_withdraw_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = _makeCellProof(
            0, 1, 10, _encodeCbeNat(100), FIXTURE_PRE_COMMIT);

        bytes memory actionFields = abi.encodePacked(
            uint64(1), uint64(10), uint64(50));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(14), actionFields, uint64(10), proofs);
        assertTrue(result != bytes32(0), "withdraw produces commit");
    }

    /* -------- LocalPolicy actions -------- */

    function test_declareLocalPolicy_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        bytes memory actionFields = new bytes(0);
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(15), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "declareLocalPolicy produces commit");
    }

    function test_revokeLocalPolicy_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        bytes memory actionFields = new bytes(0);
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(16), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "revokeLocalPolicy produces commit");
    }

    /* -------- FaultProof actions -------- */

    function test_faultProofChallenge_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        bytes memory actionFields = abi.encodePacked(
            bytes32(uint256(0xDEAD)), uint64(0), uint64(64), bytes32(uint256(0xBEEF)));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(17), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "faultProofChallenge produces commit");
    }

    function test_faultProofResolution_action_executes() public view {
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](0);
        bytes memory actionFields = abi.encodePacked(
            bytes32(uint256(0xDEAD)), uint256(42), uint64(2), uint64(64));
        bytes32 result = stepVM.executeStep(
            FIXTURE_PRE_COMMIT, uint8(18), actionFields, uint64(0), proofs);
        assertTrue(result != bytes32(0), "faultProofResolution produces commit");
    }

    /* -------- assertConsistent -------- */

    function test_assertConsistent_does_not_revert() public view {
        // The function is a deploy-time invariant check; it should
        // never revert on a fresh contract.
        stepVM.assertConsistent();
    }

    /* -------- Helpers -------- */

    /// @dev Encode a uint256 as a CBE Nat (1-byte tag + 8 bytes LE).
    function _encodeCbeNat(uint256 v) internal pure returns (bytes memory) {
        bytes memory result = new bytes(9);
        result[0] = 0x1B;
        for (uint256 i = 0; i < 8; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            result[1 + i] = bytes1(uint8(v >> (8 * i)));
        }
        return result;
    }
}
