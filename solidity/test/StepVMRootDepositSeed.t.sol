// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {StepPlan} from "src/lib/StepPlan.sol";
import {StepWrites} from "src/lib/StepWrites.sol";

/// @title StepVMRootDepositSeedProxy
/// @notice External wrapper for the calldata-typed kind-19 surfaces.
contract StepVMRootDepositSeedProxy {
    function deriveWriteSet(uint8 actionKind, bytes calldata fields, uint64 signer)
        external
        pure
        returns (StepWrites.Cell[] memory)
    {
        return StepWrites.deriveWriteSet(actionKind, fields, signer, 0);
    }

    function planBalances4(
        uint8 actionKind,
        bytes calldata fields,
        uint64 signer,
        uint256 pre0,
        uint256 pre1,
        uint256 pre2,
        uint256 pre3
    )
        external
        pure
        returns (uint256, uint256, uint256, uint256)
    {
        return StepPlan.planBalances4(
            actionKind, fields, signer, pre0, pre1, pre2, pre3);
    }
}

/// @title StepVMRootDepositSeedTest
/// @notice **The kind-19 (`depositWithFee`) three-leg step-VM arms,
///         on hand-built inputs** (Workstream SB) — the widened
///         seven-cell write set with the pinned AMM reserve target,
///         the chained three-credit split, every evaluated
///         precondition refusal (the over-seed no-op included, which
///         a checked-arithmetic mirror would turn into a revert), and
///         each pairwise actor alias reading the earlier write.
///
/// @dev    The Lean<->EVM byte-equivalence for the FULL fold rides
///         the cross-stack corpus's kind-19 seed-sweep rows (the
///         single corpus-cutover regeneration); this suite is the
///         arm-level unit coverage that must hold before those rows
///         exist.  The value fixtures mirror the Lean
///         `laws-deposit-with-fee` suite: userAmount 7, poolAmount 3,
///         seedAmount 2.
contract StepVMRootDepositSeedTest is Test {
    StepVMRootDepositSeedProxy internal proxy;

    /// @dev The canonical fixture's actors and resource.
    uint64 internal constant R = 1;
    uint64 internal constant RECIPIENT = 10;
    uint64 internal constant POOL = 99;
    uint64 internal constant SIGNER = 0; // bridgeActor signs deposits.

    function setUp() public {
        proxy = new StepVMRootDepositSeedProxy();
    }

    /// @dev The 136-byte kind-19 field layout: r at 0, recipient at 8,
    ///      poolActor at 16, userAmount at 24 (32 bytes), poolAmount
    ///      at 56 (32 bytes), budgetGrant at 88, depositId at 96, and
    ///      the Workstream SB APPENDED seedAmount at 104 (32 bytes).
    function _fields(
        uint64 recipient,
        uint64 poolActor,
        uint256 userAmount,
        uint256 poolAmount,
        uint256 seedAmount
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint64(R), recipient, poolActor,
            userAmount, poolAmount,
            uint64(5), uint64(42), seedAmount);
    }

    /* ---------------------------------------------------------- */
    /* The write set                                              */
    /* ---------------------------------------------------------- */

    /// @notice The write set is the three balance cells in the law's
    ///         write order — the seed target pinned to the canonical
    ///         AMM reserve actor, never read from calldata — then the
    ///         consumed cell, the uniform pair, and the recipient's
    ///         budget cell.
    function test_writeSet_is_the_three_legs_plus_records() public view {
        StepWrites.Cell[] memory cells =
            proxy.deriveWriteSet(19, _fields(RECIPIENT, POOL, 7, 3, 2), SIGNER);
        assertEq(cells.length, 7, "seven cells");
        assertEq(cells[0].kind, 0, "cell 0 balance");
        assertEq(cells[0].keyA, R, "cell 0 resource");
        assertEq(cells[0].keyB, RECIPIENT, "cell 0 recipient");
        assertEq(cells[1].kind, 0, "cell 1 balance");
        assertEq(cells[1].keyB, POOL, "cell 1 pool");
        assertEq(cells[2].kind, 0, "cell 2 balance");
        assertEq(cells[2].keyA, R, "cell 2 resource");
        assertEq(
            cells[2].keyB, StepWrites.AMM_RESERVE_ACTOR,
            "cell 2 is the PINNED reserve actor"
        );
        assertEq(cells[3].kind, 4, "cell 3 bridgeConsumed");
        assertEq(cells[3].keyA, 42, "cell 3 depositId");
        assertEq(cells[4].kind, 1, "cell 4 nonce");
        assertEq(cells[4].keyA, SIGNER, "cell 4 signer");
        assertEq(cells[5].kind, 13, "cell 5 epochBudget");
        assertEq(cells[5].keyA, SIGNER, "cell 5 signer");
        assertEq(cells[6].kind, 13, "cell 6 epochBudget");
        assertEq(cells[6].keyA, RECIPIENT, "cell 6 grant recipient");
    }

    /// @notice 135 bytes is one short of the widened layout and must
    ///         be refused — the appended seed field is load-bearing,
    ///         not optional.
    function test_writeSet_refuses_the_preSeed_layout() public {
        bytes memory short_ = new bytes(135);
        vm.expectRevert(
            abi.encodeWithSelector(
                StepWrites.ActionFieldsTooShort.selector, uint8(19), uint256(135)));
        proxy.deriveWriteSet(19, short_, SIGNER);
    }

    /* ---------------------------------------------------------- */
    /* The three-leg split                                        */
    /* ---------------------------------------------------------- */

    /// @notice Distinct actors: recipient +7, pool +(3−2), reserve +2.
    function test_three_legs_split_the_fee() public view {
        (uint256 n0, uint256 n1, uint256 n2, uint256 n3) = proxy.planBalances4(
            19, _fields(RECIPIENT, POOL, 7, 3, 2), SIGNER, 40, 5, 0, 77);
        assertEq(n0, 47, "recipient +userAmount");
        assertEq(n1, 6, "pool +(poolAmount - seedAmount)");
        assertEq(n2, 2, "reserve +seedAmount");
        assertEq(n3, 77, "slot 3 passes through");
    }

    /// @notice Seedless: the pool keeps the whole fee and the reserve
    ///         cell is planned at its pre-value.
    function test_zero_seed_keeps_the_fee_on_the_pool() public view {
        (uint256 n0, uint256 n1, uint256 n2,) = proxy.planBalances4(
            19, _fields(RECIPIENT, POOL, 7, 3, 0), SIGNER, 40, 5, 9, 0);
        assertEq(n0, 47, "recipient +userAmount");
        assertEq(n1, 8, "pool +poolAmount");
        assertEq(n2, 9, "reserve untouched");
    }

    /// @notice Full seed: the whole fee reaches the reserve.
    function test_full_seed_reaches_the_reserve() public view {
        (, uint256 n1, uint256 n2,) = proxy.planBalances4(
            19, _fields(RECIPIENT, POOL, 7, 3, 3), SIGNER, 40, 5, 9, 0);
        assertEq(n1, 5, "pool +0");
        assertEq(n2, 12, "reserve +poolAmount");
    }

    /// @notice **Over-seed is a NO-OP, not a revert.**  A split
    ///         claiming more seed than fee fails the law's
    ///         `seedAmount ≤ poolAmount` conjunct, so all three cells
    ///         are planned at their pre-values; checked subtraction
    ///         would instead revert, and a revert is not a verdict.
    function test_over_seed_is_a_noop() public view {
        (uint256 n0, uint256 n1, uint256 n2,) = proxy.planBalances4(
            19, _fields(RECIPIENT, POOL, 7, 3, 4), SIGNER, 40, 5, 9, 0);
        assertEq(n0, 40, "recipient unchanged");
        assertEq(n1, 5, "pool unchanged");
        assertEq(n2, 9, "reserve unchanged");
    }

    /// @notice The C-3 ceiling on the recipient leg refuses the whole
    ///         split — a partial application is never planned.
    function test_recipient_ceiling_refuses_the_split() public view {
        (uint256 n0, uint256 n1, uint256 n2,) = proxy.planBalances4(
            19, _fields(RECIPIENT, POOL, 7, 3, 2), SIGNER,
            type(uint256).max, 5, 9, 0);
        assertEq(n0, type(uint256).max, "recipient unchanged");
        assertEq(n1, 5, "pool unchanged");
        assertEq(n2, 9, "reserve unchanged");
    }

    /// @notice ...and so does the ceiling on the SEED leg, the last
    ///         conjunct: the earlier legs must not fire either.
    function test_seed_ceiling_refuses_the_split() public view {
        (uint256 n0, uint256 n1, uint256 n2,) = proxy.planBalances4(
            19, _fields(RECIPIENT, POOL, 7, 3, 2), SIGNER,
            40, 5, type(uint256).max, 0);
        assertEq(n0, 40, "recipient unchanged");
        assertEq(n1, 5, "pool unchanged");
        assertEq(n2, type(uint256).max, "reserve unchanged");
    }

    /* ---------------------------------------------------------- */
    /* The alias branches                                         */
    /* ---------------------------------------------------------- */

    /// @notice recipient = pool: the net leg reads the recipient's
    ///         ALREADY-CREDITED value, and both slots publish the last
    ///         write landing on the shared cell.
    function test_recipient_pool_alias_chains() public view {
        (uint256 n0, uint256 n1, uint256 n2,) = proxy.planBalances4(
            19, _fields(RECIPIENT, RECIPIENT, 7, 3, 2), SIGNER, 40, 40, 0, 0);
        assertEq(n0, 48, "shared cell: 40 + 7 + (3 - 2)");
        assertEq(n1, 48, "both slots publish the same value");
        assertEq(n2, 2, "reserve +seedAmount");
    }

    /// @notice pool = reserve: the seed leg reads the net leg's write,
    ///         so the shared cell nets back to the FULL fee and both
    ///         slots publish it.
    function test_pool_reserve_alias_nets_the_full_fee() public view {
        (uint256 n0, uint256 n1, uint256 n2,) = proxy.planBalances4(
            19,
            _fields(RECIPIENT, StepWrites.AMM_RESERVE_ACTOR, 7, 3, 2),
            SIGNER, 40, 5, 5, 0);
        assertEq(n0, 47, "recipient +userAmount");
        assertEq(n1, 8, "shared cell: 5 + (3 - 2) + 2");
        assertEq(n2, 8, "both slots publish the same value");
    }

    /// @notice recipient = reserve: the seed leg reads the recipient's
    ///         credited value and the recipient slot publishes the
    ///         LAST write.
    function test_recipient_reserve_alias_chains() public view {
        (uint256 n0, uint256 n1, uint256 n2,) = proxy.planBalances4(
            19,
            _fields(StepWrites.AMM_RESERVE_ACTOR, POOL, 7, 3, 2),
            SIGNER, 40, 5, 40, 0);
        assertEq(n0, 49, "shared cell: 40 + 7 + 2");
        assertEq(n1, 6, "pool +(poolAmount - seedAmount)");
        assertEq(n2, 49, "both slots publish the same value");
    }
}
