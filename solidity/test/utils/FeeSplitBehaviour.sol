// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {DepositEventDecoder} from "test/utils/DepositEventDecoder.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";

/// @title  FeeSplitBehaviour
/// @notice **The fee split, once, for whichever currency carries it.**
///
/// @dev    GP.5.4 says the BOLD leg "mirrors `depositETHWithFee`
///         (GP.5.1) exactly save that value arrives as the pinned BOLD
///         ERC-20 via `transferFrom` rather than as `msg.value`".  Both
///         suites took that literally and wrote the same twenty-five
///         tests twice.  Normalise away the deploy factory and the
///         deposit call and the two copies are character-identical --
///         the assertions, the constants, the failure messages.
///
///         Duplication that exact does not stay exact.  It already had
///         not: the BOLD copy of `test_budgetClamp_exactBoundary_*` had
///         lost the sentence explaining WHY the boundary passes through
///         (the clamp's `>` is strict), and `test_rate_nearUint64Max`
///         had lost the note that the constructor's rate domain runs to
///         `type(uint64).max`.  Nothing failed.  Nothing would.
///
///         So the mirror is a base class and the difference is six
///         hooks.  A test written here runs on BOTH legs, which is the
///         property the two copies could never have: today, a case
///         added to one suite reaches one currency.
///
///         **The unification took the better half of each.**  The ETH
///         suite verified its event with `vm.expectEmit`, which on a
///         mismatch reports only that the log did not match; the BOLD
///         suite decoded the receipt and compared field by field, so a
///         failure names the field.  The BOLD suite also asserted that
///         the bridge actually RECEIVED the value (its fee-on-transfer
///         guard) where the ETH suite did not.  `_depositAndCheck`
///         below is the BOLD shape, so the ETH leg gains both.
abstract contract FeeSplitBehaviour is Test, DepositEventDecoder {
    /// @dev Two depositors, shared by every case.  `bob` exists to
    ///      exercise the per-depositor nonce independently of `alice`.
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);

    /// @notice What a deposit is expected to move, read before it lands.
    ///
    /// @dev    Two `uint256` locals, until they were one slot too many
    ///         for the Yul stack limiter.  One pointer instead -- the
    ///         same trick, and the same justification, as
    ///         `DepositEventDecoder.DepositReceipt`: these two values
    ///         are one observation of the bridge, not two unrelated
    ///         numbers that happen to be read together.
    struct LegSnapshot {
        uint256 tvl;
        uint256 bridgeBalance;
    }

    // ------------------------------------------------------------------
    // The six hooks -- everything that differs between the two legs
    // ------------------------------------------------------------------

    /// @notice Deploy a bridge whose fee range is `[minFeeBps,
    ///         maxFeeBps]`, whose budget exchange rate for THIS leg is
    ///         `rate`, and whose TVL ceiling is `tvlCap`.
    function _deployLeg(uint16 minFeeBps, uint16 maxFeeBps, uint64 rate, uint256 tvlCap)
        internal
        virtual
        returns (KnomosisBridge);

    /// @notice Give `user` `amount` of this leg's currency and whatever
    ///         approval the deposit needs.  Called before every deposit,
    ///         including the ones expected to revert -- a revert must be
    ///         attributable to the guard under test, not to funding.
    function _fundFor(KnomosisBridge bridge, address user, uint256 amount) internal virtual;

    /// @notice Perform the deposit as `user`.  Includes the `vm.prank`,
    ///         so a caller can arm `vm.expectRevert` immediately before.
    function _deposit(KnomosisBridge bridge, address user, uint256 amount, uint16 feeBps)
        internal
        virtual;

    /// @notice This leg's budget exchange rate as the bridge stores it
    ///         (`weiPerBudgetUnitEth` or `weiPerBudgetUnitBold`).
    function _legRate(KnomosisBridge bridge) internal view virtual returns (uint64);

    /// @notice This leg's `resourceId`, as the emitted receipt carries it.
    function _legResourceId() internal pure virtual returns (uint64);

    /// @notice This leg's token address (`address(0)` for native ETH).
    function _legToken() internal view virtual returns (address);

    /// @notice `who`'s balance in this leg's currency.  Backs the
    ///         "the bridge received the full amount" assertion.
    function _legBalanceOf(address who) internal view virtual returns (uint256);

    // ------------------------------------------------------------------
    // Derived helpers
    // ------------------------------------------------------------------

    /// @notice The default bridge: full `[0, 5000]` fee range, a
    ///         realistic exchange rate of one budget unit per 10^9 base
    ///         units, no TVL ceiling.
    function _defaultLeg() internal returns (KnomosisBridge) {
        return _deployLeg(0, 5000, 1_000_000_000, type(uint256).max);
    }

    /// @notice Deposit `amount` at `feeBps` as `user`, asserting the
    ///         emitted `DepositWithFeeInitiated` matches the
    ///         `FeeSplitMath` reference field by field, that TVL grows
    ///         by the full deposit, that the per-depositor nonce
    ///         increments, and that the bridge actually received the
    ///         value.
    ///
    /// @return The reference receipt, for the caller to cross-check
    ///         against hand-computed numbers.  A receipt and not the
    ///         `(userAmount, poolAmount, budgetGrant)` triple it used to
    ///         return: three stack slots at every call site, where the
    ///         deposit path already has none to spare, and callers that
    ///         wanted the second one wrote `(, uint256 p,)`.
    function _depositAndCheck(
        KnomosisBridge bridge,
        address user,
        uint256 amount,
        uint16 feeBps
    ) internal returns (DepositReceipt memory) {
        // Each stage keeps its own working values in its OWN frame.  That
        // is not tidiness: with the expected receipt, the decoded receipt
        // and the pre-state read all live here at once, the ETH leg (whose
        // `_fundFor` is empty and whose `_deposit` inlines to a `CALL` with
        // value) sat one slot past what the Yul stack limiter allows.
        DepositReceipt memory want = _expectedReceipt(bridge, user, amount, feeBps);
        LegSnapshot memory before =
            LegSnapshot(bridge.totalLockedValue(), _legBalanceOf(address(bridge)));

        _fundFor(bridge, user, amount);
        vm.recordLogs();
        _deposit(bridge, user, amount, feeBps);

        _assertReceiptEq(_findDepositReceipt(vm.getRecordedLogs()), want);
        _assertAccounting(bridge, user, amount, want, before);

        return want;
    }

    /// @dev The receipt this leg's bridge OUGHT to emit, computed from
    ///      the `FeeSplitMath` reference rather than read back from the
    ///      contract.  These are AMM-disabled deployments, so
    ///      `ammSeedAmount` stays 0 (`freePoolAmount == poolAmount`).
    function _expectedReceipt(
        KnomosisBridge bridge,
        address user,
        uint256 amount,
        uint16 feeBps
    ) internal view returns (DepositReceipt memory want) {
        want.sender = user;
        want.resourceId = _legResourceId();
        want.token = _legToken();
        (want.userAmount, want.poolAmount, want.budgetGrant) =
            FeeSplitMath.split(amount, feeBps, _legRate(bridge));
        want.nonce = bridge.depositNonce(user);
        want.receiptHash = _receiptHashOf(bridge.deploymentId(), want);
    }

    /// @dev Conservation + accounting invariants read off the LIVE
    ///      contract, against the pre-state `before` and the reference
    ///      `want`.  The last one -- that the bridge's own balance grew
    ///      by the full deposit -- is the fee-on-transfer guard the BOLD
    ///      leg had and the ETH leg did not.
    function _assertAccounting(
        KnomosisBridge bridge,
        address user,
        uint256 amount,
        DepositReceipt memory want,
        LegSnapshot memory before
    ) private {
        assertEq(want.userAmount + want.poolAmount, amount, "split must conserve the deposit");
        assertEq(bridge.totalLockedValue(), before.tvl + amount, "TVL grows by full deposit");
        assertEq(bridge.depositNonce(user), want.nonce + 1, "nonce increments");
        assertEq(
            _legBalanceOf(address(bridge)),
            before.bridgeBalance + amount,
            "bridge received the full amount"
        );
    }

    /// @dev Field-by-field receipt equality.  Named per field, so a
    ///      failure says WHICH one drifted -- the reason this replaced
    ///      the ETH leg's `vm.expectEmit`, which reports only that the
    ///      log did not match.
    ///
    ///      Nothing here checks the EMITTER, and nothing needs to:
    ///      `receiptHash` binds `deploymentId()`, so a receipt from any
    ///      other bridge fails the hash comparison.  That is a stricter
    ///      binding than `expectEmit`'s address argument, not a weaker one.
    function _assertReceiptEq(DepositReceipt memory got, DepositReceipt memory want) internal {
        assertEq(got.sender, want.sender, "event sender");
        assertEq(got.resourceId, want.resourceId, "event resourceId");
        assertEq(got.token, want.token, "event token");
        assertEq(got.userAmount, want.userAmount, "event userAmount");
        assertEq(got.poolAmount, want.poolAmount, "event poolAmount");
        assertEq(got.budgetGrant, want.budgetGrant, "event budgetGrant");
        assertEq(got.nonce, want.nonce, "event depositorNonce");
        assertEq(got.receiptHash, want.receiptHash, "event receiptHash");
    }

    // ------------------------------------------------------------------
    // Happy-path cases (GP.5.1.f / GP.5.4.b)
    // ------------------------------------------------------------------

    function test_zeroFee_pureDeposit() public {
        KnomosisBridge bridge = _defaultLeg();
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 1 ether, 0);
        assertEq(rcpt.poolAmount, 0, "no pool credit at zero fee");
        assertEq(rcpt.userAmount, 1 ether, "full amount to user");
        assertEq(rcpt.budgetGrant, 0, "no budget grant at zero fee");
    }

    function test_minFee_smallestPool() public {
        // minFeeBps = 50 (0.5%); the smallest admissible pool credit.
        KnomosisBridge bridge = _deployLeg(50, 5000, 1, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 1_000_000, 50);
        assertEq(rcpt.poolAmount, 5000, "0.5% of 1e6");
        assertEq(rcpt.userAmount, 995_000, "remainder to user");
        assertEq(rcpt.budgetGrant, 5000, "budget == poolAmount at rate 1");
    }

    function test_maxFee_largestPool() public {
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 100, 5000);
        assertEq(rcpt.poolAmount, 50, "50% of 100");
        assertEq(rcpt.userAmount, 50, "exact half to user");
    }

    function test_tinyAmount_roundsToUser() public {
        // 1 base unit at 1% -> poolAmount floors to 0, all of it to the user.
        KnomosisBridge bridge = _defaultLeg();
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 1, 100);
        assertEq(rcpt.poolAmount, 0, "pool rounds to zero");
        assertEq(rcpt.userAmount, 1, "the single base unit goes to the user");
        assertEq(rcpt.budgetGrant, 0, "budget rounds to zero");
    }

    function test_rateOne_budgetEqualsPool() public {
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 10_000, 100);
        assertEq(rcpt.poolAmount, 100, "1% of 1e4");
        assertEq(rcpt.budgetGrant, 100, "budget == poolAmount at rate 1");
    }

    function test_rateTrillion_budgetDivides() public {
        KnomosisBridge bridge = _deployLeg(0, 5000, 1_000_000_000_000, type(uint256).max);
        // poolAmount = 50% of 6e12 = 3e12; budget = 3e12 / 1e12 = 3.
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 6_000_000_000_000, 5000);
        assertEq(rcpt.poolAmount, 3_000_000_000_000, "half of 6e12");
        assertEq(rcpt.budgetGrant, 3, "3e12 / 1e12");
    }

    function test_budgetClamp_exactBoundary_notClamped() public {
        // rawBudget == MAX_BUDGET_PER_DEPOSIT exactly: the clamp uses a
        // strict `>` so the boundary value passes through unclamped.
        // poolAmount = 50% of 2e12 = 1e12; rate 1 -> rawBudget = 1e12.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 2_000_000_000_000, 5000);
        assertEq(rcpt.poolAmount, 1_000_000_000_000, "half of 2e12");
        assertEq(rcpt.budgetGrant, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "exact boundary, not clamped");
    }

    function test_budgetClamp_oneAboveBoundary_clamped() public {
        // poolAmount = 1e12 + 10000 > 1e12 -> clamped to the cap.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 2_000_000_020_000, 5000);
        assertEq(rcpt.poolAmount, 1_000_000_010_000, "half of 2e12 + 20000");
        assertEq(rcpt.budgetGrant, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "one above boundary, clamped");
    }

    function test_residue_favoursUser() public {
        // amount = 12345, feeBps = 333 -> poolAmount = floor(12345*333/10000)
        // = floor(411.0885) = 411; the residue accrues to the user.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 12_345, 333);
        assertEq(rcpt.poolAmount, 411, "floor(12345 * 333 / 10000)");
        assertEq(rcpt.userAmount, 11_934, "residue to user");
    }

    function test_feeJustBelowMax() public {
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 1_000_000, 4999);
        assertEq(rcpt.poolAmount, 499_900, "floor(1e6 * 4999 / 10000)");
    }

    function test_singleAllowedFee_minEqualsMax() public {
        // minFeeBps == maxFeeBps: exactly one admissible fee value.
        KnomosisBridge bridge = _deployLeg(250, 250, 1, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 1_000_000, 250);
        assertEq(rcpt.poolAmount, 25_000, "2.5% of 1e6");
    }

    function test_rate_nearUint64Max() public {
        // Exercises the upper edge of the exchange-rate domain
        // (the constructor accepts up to type(uint64).max).
        uint64 hugeRate = type(uint64).max; // ~1.8447e19
        KnomosisBridge bridge = _deployLeg(0, 5000, hugeRate, type(uint256).max);
        // Small deposit: pool credit (5e17) < rate -> budget 0.
        DepositReceipt memory small = _depositAndCheck(bridge, alice, 1 ether, 5000);
        assertEq(small.poolAmount, 0.5 ether, "half to pool");
        assertEq(small.budgetGrant, 0, "budget rounds to zero when pool < rate");
        // Large deposit: pool credit (2e19) >= rate -> budget 1
        // (floor(2e19 / 1.8447e19) = 1).
        DepositReceipt memory large = _depositAndCheck(bridge, bob, 40 ether, 5000);
        assertEq(large.poolAmount, 20 ether, "half to pool");
        assertEq(large.budgetGrant, 1, "budget = floor(2e19 / uint64max) = 1");
    }

    // ------------------------------------------------------------------
    // Nonce + TVL accounting
    // ------------------------------------------------------------------

    function test_nonce_incrementsAcrossDeposits() public {
        KnomosisBridge bridge = _defaultLeg();
        assertEq(bridge.depositNonce(alice), 0);
        _depositAndCheck(bridge, alice, 1 ether, 100);
        assertEq(bridge.depositNonce(alice), 1);
        _depositAndCheck(bridge, alice, 2 ether, 200);
        assertEq(bridge.depositNonce(alice), 2);
    }

    function test_independentNonces_perDepositor() public {
        KnomosisBridge bridge = _defaultLeg();
        _depositAndCheck(bridge, alice, 1 ether, 100);
        _depositAndCheck(bridge, alice, 1 ether, 100);
        // Bob's first deposit uses nonce 0 even though Alice is at 2.
        assertEq(bridge.depositNonce(bob), 0);
        _depositAndCheck(bridge, bob, 1 ether, 100);
        assertEq(bridge.depositNonce(bob), 1);
        assertEq(bridge.depositNonce(alice), 2);
    }

    function test_tvl_accumulatesAcrossDeposits() public {
        KnomosisBridge bridge = _defaultLeg();
        _depositAndCheck(bridge, alice, 3 ether, 100);
        _depositAndCheck(bridge, bob, 5 ether, 4000);
        assertEq(bridge.totalLockedValue(), 8 ether, "TVL = sum of full deposits");
    }

    // ------------------------------------------------------------------
    // Receipt-hash binding
    // ------------------------------------------------------------------

    function test_differentFee_distinctReceiptHash() public {
        // Two deposits with identical other fields but different
        // chosenFeeBps must produce different receiptHashes, because
        // the split fields (userAmount / poolAmount / budgetGrant) feed
        // the hash.  We capture both via recorded logs.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);

        _fundFor(bridge, alice, 1_000_000);
        vm.recordLogs();
        _deposit(bridge, alice, 1_000_000, 100);
        bytes32 hash1 = _findDepositReceipt(vm.getRecordedLogs()).receiptHash;

        _fundFor(bridge, alice, 1_000_000);
        vm.recordLogs();
        _deposit(bridge, alice, 1_000_000, 200);
        bytes32 hash2 = _findDepositReceipt(vm.getRecordedLogs()).receiptHash;

        assertTrue(hash1 != hash2, "different fee -> different receiptHash");
    }

    function test_replayResistance_nonceBinding() public {
        // Two deposits with IDENTICAL (amount, fee) by the same depositor
        // on the same bridge produce different receiptHashes, because the
        // per-depositor nonce is bound into the hash.  Isolates
        // nonce-replay resistance WITHIN a deployment (the prior test
        // conflated fee + nonce changes).
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);

        _fundFor(bridge, alice, 1 ether);
        vm.recordLogs();
        _deposit(bridge, alice, 1 ether, 100);
        DepositReceipt memory r1 = _findDepositReceipt(vm.getRecordedLogs());

        _fundFor(bridge, alice, 1 ether);
        vm.recordLogs();
        _deposit(bridge, alice, 1 ether, 100);
        DepositReceipt memory r2 = _findDepositReceipt(vm.getRecordedLogs());

        assertEq(r1.nonce, 0, "first deposit uses nonce 0");
        assertEq(r2.nonce, 1, "second deposit uses nonce 1");
        assertTrue(
            r1.receiptHash != r2.receiptHash,
            "identical deposits at different nonces must hash differently"
        );
    }

    // ------------------------------------------------------------------
    // Revert cases (GP.5.1.g / GP.5.4.c)
    // ------------------------------------------------------------------

    function test_minEqualsMax_zero_forcesZeroFee() public {
        // A deployment that forbids any fee: min == max == 0.  Only
        // chosenFeeBps == 0 is admissible (a pure balance deposit); any
        // positive fee reverts FeeBpsAboveMax.
        KnomosisBridge bridge = _deployLeg(0, 0, 1, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 1 ether, 0);
        assertEq(rcpt.poolAmount, 0, "forced zero pool");
        assertEq(rcpt.userAmount, 1 ether, "full amount to user");
        assertEq(rcpt.budgetGrant, 0, "no budget");

        _fundFor(bridge, alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, uint16(1)));
        _deposit(bridge, alice, 1 ether, 1);
    }

    function test_revert_zeroDeposit() public {
        KnomosisBridge bridge = _defaultLeg();
        vm.expectRevert(KnomosisBridge.ZeroDeposit.selector);
        _deposit(bridge, alice, 0, 0);
    }

    function test_revert_zeroDeposit_takesPrecedenceOverFeeCheck() public {
        // minFeeBps = 100; a zero-value call still reverts ZeroDeposit
        // (the value guard fires before the fee-range guards).
        KnomosisBridge bridge = _deployLeg(100, 5000, 1, type(uint256).max);
        vm.expectRevert(KnomosisBridge.ZeroDeposit.selector);
        _deposit(bridge, alice, 0, 200);
    }

    function test_revert_feeBelowMin() public {
        KnomosisBridge bridge = _deployLeg(100, 5000, 1, type(uint256).max);
        _fundFor(bridge, alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsBelowMin.selector, uint16(99)));
        _deposit(bridge, alice, 1 ether, 99);
    }

    function test_revert_feeAboveMax() public {
        KnomosisBridge bridge = _deployLeg(0, 1000, 1, type(uint256).max);
        _fundFor(bridge, alice, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, uint16(1001))
        );
        _deposit(bridge, alice, 1 ether, 1001);
    }

    function test_revert_feeAboveMax_outOfBpsRange() public {
        // chosenFeeBps = 10001 (> 100%): the range guard fires before
        // any arithmetic, so it reverts FeeBpsAboveMax, not an
        // arithmetic error.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
        _fundFor(bridge, alice, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, uint16(10001))
        );
        _deposit(bridge, alice, 1 ether, 10001);
    }

    function test_revert_tvlCapReached() public {
        // Cap at 1e18; a 2e18 deposit exceeds it.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, 1 ether);
        _fundFor(bridge, alice, 2 ether);
        vm.expectRevert(KnomosisBridge.TvlCapReached.selector);
        _deposit(bridge, alice, 2 ether, 100);
    }

    function test_revert_tvlCap_firesOnFullValue_notUserAmount() public {
        // Cap at 1e18.  A deposit of exactly 1e18 at 50% fee has
        // userAmount = 0.5e18, but the cap must fire on the FULL
        // 1e18 + 1, proving fee manipulation cannot bypass the cap.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, 1 ether);
        // The full-cap deposit lands (TVL == cap).
        _depositAndCheck(bridge, alice, 1 ether, 5000);
        // A further 1-unit deposit pushes TVL over the cap.
        _fundFor(bridge, bob, 1);
        vm.expectRevert(KnomosisBridge.TvlCapReached.selector);
        _deposit(bridge, bob, 1, 0);
    }
}
