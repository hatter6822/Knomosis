// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {AmmMath} from "src/lib/AmmMath.sol";
import {StepPlan} from "src/lib/StepPlan.sol";
import {StepWrites} from "src/lib/StepWrites.sol";

/// @title StepVMRootReserveSwapProxy
/// @notice External wrapper for the calldata-typed kind-25 surfaces.
contract StepVMRootReserveSwapProxy {
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

/// @title StepVMRootReserveSwapTest
/// @notice **The kind-25 (`reserveSwap`) step-VM arms, on hand-built
///         inputs** (Workstream SB) — the write-set quad, the
///         re-derived constant-product quote, every evaluated
///         precondition refusal, and the uint256-domain no-op that a
///         checked-arithmetic mirror would otherwise turn into a
///         revert.
///
/// @dev    The quote fixture is worked by hand so the suite is
///         non-circular (and it is the SAME fixture the Lean
///         `laws-reserve-swap` suite pins): reserves 10000/10000,
///         input 1000, fee 30 bps ⇒
///         `amountInWithFee = 1000 × 9970 = 9 970 000`,
///         `numerator = 9 970 000 × 10000 = 99 700 000 000`,
///         `denominator = 10⁸ + 9 970 000 = 109 970 000`,
///         `amountOut = ⌊99 700 000 000 / 109 970 000⌋ = 906`.
///
///         The Lean<->EVM byte-equivalence for the FULL fold rides
///         the cross-stack corpus's kind-25 rows (the single
///         corpus-cutover regeneration); this suite is the arm-level
///         unit coverage that must hold before those rows exist.
contract StepVMRootReserveSwapTest is Test {
    StepVMRootReserveSwapProxy internal proxy;

    /// @dev The canonical fixture's actors and resources.
    uint64 internal constant FROM = 0;
    uint64 internal constant TO = 1;
    uint64 internal constant USER = 9;
    uint64 internal constant RESERVE = 3;

    /// @dev The hand-computed quote for 1000 in against 10000/10000.
    uint256 internal constant QUOTE = 906;

    function setUp() public {
        proxy = new StepVMRootReserveSwapProxy();
    }

    /// @dev The 96-byte kind-25 field layout: fromResource at 0,
    ///      toResource at 8, user at 16, amountIn at 24 (32 bytes),
    ///      minAmountOut at 56 (32 bytes), reserveActor at 88.
    function _fields(uint256 amountIn, uint256 minAmountOut)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            uint64(FROM), uint64(TO), uint64(USER),
            amountIn, minAmountOut, uint64(RESERVE));
    }

    /* ---------------------------------------------------------- */
    /* The fee constant is ONE value                              */
    /* ---------------------------------------------------------- */

    /// @notice `AmmMath.SWAP_FEE_BPS` is pinned to 30 — the same
    ///         number `AmmStorage.t.sol` pins for the bridge's
    ///         `AMM_SWAP_FEE_BPS` and the cap-audit gate pins in
    ///         source, so a re-pricing on either surface is a test
    ///         failure rather than a silent cross-venue divergence
    ///         (and the Lean `AmmMath.swapFeeBps` is the corpus's
    ///         authority for the kind-25 rows).
    function test_swapFeeBps_is_one_value_across_surfaces() public pure {
        assertEq(AmmMath.SWAP_FEE_BPS, 30, "AmmMath.SWAP_FEE_BPS == 30");
        assertLt(
            AmmMath.SWAP_FEE_BPS,
            AmmMath.BPS_DENOMINATOR,
            "the fee sits inside the denominator"
        );
    }

    /* ---------------------------------------------------------- */
    /* Adjudicability and the write set                           */
    /* ---------------------------------------------------------- */

    function test_kind25_is_adjudicable() public pure {
        assertTrue(StepWrites.isAdjudicable(25), "reserveSwap is adjudicable");
        assertFalse(StepWrites.isAdjudicable(26), "26 is unknown");
        assertFalse(StepWrites.isAdjudicable(6), "bulk stays excluded");
        assertFalse(StepWrites.isAdjudicable(7), "bulk stays excluded");
    }

    /// @notice The write set is the four balance cells in the law's
    ///         write order, then the uniform nonce/budget pair.
    function test_writeSet_is_the_quad_plus_uniform_pair() public view {
        StepWrites.Cell[] memory cells =
            proxy.deriveWriteSet(25, _fields(1000, 900), USER);
        assertEq(cells.length, 6, "six cells");
        // user debit at from.
        assertEq(cells[0].kind, 0, "cell 0 balance");
        assertEq(cells[0].keyA, FROM, "cell 0 resource");
        assertEq(cells[0].keyB, USER, "cell 0 actor");
        // reserve credit at from.
        assertEq(cells[1].kind, 0, "cell 1 balance");
        assertEq(cells[1].keyA, FROM, "cell 1 resource");
        assertEq(cells[1].keyB, RESERVE, "cell 1 actor");
        // reserve debit at to.
        assertEq(cells[2].kind, 0, "cell 2 balance");
        assertEq(cells[2].keyA, TO, "cell 2 resource");
        assertEq(cells[2].keyB, RESERVE, "cell 2 actor");
        // user credit at to.
        assertEq(cells[3].kind, 0, "cell 3 balance");
        assertEq(cells[3].keyA, TO, "cell 3 resource");
        assertEq(cells[3].keyB, USER, "cell 3 actor");
        // The uniform pair, keyed by the signer.
        assertEq(cells[4].kind, 1, "cell 4 nonce");
        assertEq(cells[4].keyA, USER, "cell 4 signer");
        assertEq(cells[5].kind, 13, "cell 5 epochBudget");
        assertEq(cells[5].keyA, USER, "cell 5 signer");
    }

    function test_writeSet_rejects_short_fields() public {
        bytes memory short_ = abi.encodePacked(uint64(FROM), uint64(TO));
        vm.expectRevert(
            abi.encodeWithSelector(
                StepWrites.ActionFieldsTooShort.selector, uint8(25), uint256(16)));
        proxy.deriveWriteSet(25, short_, USER);
    }

    /* ---------------------------------------------------------- */
    /* The derivation: happy path                                 */
    /* ---------------------------------------------------------- */

    /// @notice The four writes land the hand-computed values, and the
    ///         reserve product does not decrease.
    function test_derive_happy_path_lands_the_quote() public view {
        (uint256 n0, uint256 n1, uint256 n2, uint256 n3) = proxy.planBalances4(
            25, _fields(1000, 900), USER, 5000, 10000, 10000, 0);
        assertEq(n0, 4000, "user debited at from (5000 - 1000)");
        assertEq(n1, 11000, "reserve credited at from (10000 + 1000)");
        assertEq(n2, 10000 - QUOTE, "reserve debited at to (10000 - 906)");
        assertEq(n3, QUOTE, "user credited at to (0 + 906)");
        assertGe(n1 * n2, 10000 * 10000, "k is non-decreasing");
    }

    /// @notice The slippage floor is exact: the quote itself passes,
    ///         one above it no-ops.
    function test_derive_slippage_floor_is_exact() public view {
        (uint256 a0,,, uint256 a3) = proxy.planBalances4(
            25, _fields(1000, QUOTE), USER, 5000, 10000, 10000, 0);
        assertEq(a0, 4000, "minAmountOut = quote admits");
        assertEq(a3, QUOTE, "...crediting the quote");
        (uint256 b0, uint256 b1, uint256 b2, uint256 b3) = proxy.planBalances4(
            25, _fields(1000, QUOTE + 1), USER, 5000, 10000, 10000, 0);
        assertEq(b0, 5000, "one above the quote no-ops");
        assertEq(b1, 10000, "reserve at from untouched");
        assertEq(b2, 10000, "reserve at to untouched");
        assertEq(b3, 0, "user at to untouched");
    }

    /// @notice A starved output leg quotes zero, and the
    ///         `max 1 minAmountOut` floor refuses it even at
    ///         minAmountOut = 0 — the `ZeroSwapOutput` mirror.
    function test_derive_zero_quote_is_refused() public view {
        (uint256 n0,, uint256 n2,) = proxy.planBalances4(
            25, _fields(1, 0), USER, 5000, 10000, 1, 0);
        assertEq(n0, 5000, "zero-output swap no-ops");
        assertEq(n2, 1, "the starved leg is untouched");
    }

    /* ---------------------------------------------------------- */
    /* The derivation: evaluated refusals                         */
    /* ---------------------------------------------------------- */

    function test_derive_refuses_each_precondition() public view {
        // Zero input.
        (uint256 a0,,,) = proxy.planBalances4(
            25, _fields(0, 0), USER, 5000, 10000, 10000, 0);
        assertEq(a0, 5000, "zero input no-ops");
        // Same resource on both legs.
        bytes memory sameRes = abi.encodePacked(
            uint64(FROM), uint64(FROM), uint64(USER),
            uint256(1000), uint256(1), uint64(RESERVE));
        (uint256 b0,,,) = proxy.planBalances4(
            25, sameRes, USER, 5000, 10000, 10000, 0);
        assertEq(b0, 5000, "same-resource swap no-ops");
        // The reserve trading against itself.
        bytes memory selfSwap = abi.encodePacked(
            uint64(FROM), uint64(TO), uint64(RESERVE),
            uint256(1000), uint256(1), uint64(RESERVE));
        (uint256 c0,,,) = proxy.planBalances4(
            25, selfSwap, RESERVE, 10000, 10000, 10000, 0);
        assertEq(c0, 10000, "user == reserveActor no-ops");
        // Insufficient user balance.
        (uint256 d0,,,) = proxy.planBalances4(
            25, _fields(5001, 1), USER, 5000, 10000, 10000, 0);
        assertEq(d0, 5000, "underfunded swap no-ops");
        // An empty reserve leg.
        (uint256 e0,, uint256 e2,) = proxy.planBalances4(
            25, _fields(1000, 1), USER, 5000, 10000, 0, 0);
        assertEq(e0, 5000, "empty output leg no-ops");
        assertEq(e2, 0, "...leaving it empty");
    }

    /// @notice **The uint256-domain refusal is a NO-OP, never a
    ///         revert.**  `amountIn = 2^255` is representable and
    ///         fundable (balances range to 2^256), and Lean's `Nat`
    ///         quote computes fine — but `amountIn × 9970` does not
    ///         exist in uint256.  The law's
    ///         `reserveQuoteDomainBounded` conjunct refuses the swap
    ///         on BOTH stacks; a checked-arithmetic mirror without the
    ///         wrap-free evaluation would revert here and cost
    ///         whoever's turn it is the game by timeout.
    function test_derive_out_of_domain_is_a_noop_not_a_revert() public view {
        uint256 big = 1 << 255;
        (uint256 n0, uint256 n1, uint256 n2, uint256 n3) = proxy.planBalances4(
            25, _fields(big, 1), USER, big, 10000, 10000, 0);
        assertEq(n0, big, "the 2^255 swap no-ops");
        assertEq(n1, 10000, "reserve at from untouched");
        assertEq(n2, 10000, "reserve at to untouched");
        assertEq(n3, 0, "user at to untouched");
    }

    /// @notice The C-3 credit ceilings are evaluated: a reserve credit
    ///         or a user credit that would cross 2^256 no-ops.
    function test_derive_refuses_ceiling_crossings() public view {
        uint256 nearMax = type(uint256).max - 500;
        // Reserve-credit ceiling: preResFrom + amountIn wraps.
        (uint256 a0, uint256 a1,,) = proxy.planBalances4(
            25, _fields(1000, 1), USER, 5000, nearMax, 10000, 0);
        assertEq(a0, 5000, "reserve-credit crossing no-ops");
        assertEq(a1, nearMax, "the near-max leg is untouched");
        // User-credit ceiling: preUserTo + quote wraps.
        (uint256 b0,,, uint256 b3) = proxy.planBalances4(
            25, _fields(1000, 1), USER, 5000, 10000, 10000, nearMax);
        assertEq(b0, 5000, "user-credit crossing no-ops");
        assertEq(b3, nearMax, "the near-max cell is untouched");
    }

    /* ---------------------------------------------------------- */
    /* The plan pass-through                                      */
    /* ---------------------------------------------------------- */

    /// @notice A two-cell variant routed through `planBalances4`
    ///         computes its pair exactly as before and passes cells 2
    ///         and 3 through untouched.
    function test_planBalances4_passes_through_for_pair_variants() public view {
        // transfer: r @0, sender @8, receiver @16, amount @24 (32).
        bytes memory fields = abi.encodePacked(
            uint64(0), uint64(USER), uint64(7), uint256(100));
        (uint256 n0, uint256 n1, uint256 n2, uint256 n3) = proxy.planBalances4(
            0, fields, USER, 500, 50, 111, 222);
        assertEq(n0, 400, "sender debited");
        assertEq(n1, 150, "receiver credited");
        assertEq(n2, 111, "slot 2 passed through");
        assertEq(n3, 222, "slot 3 passed through");
    }
}
