// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";

/// @title BridgeFeeSplitTest
/// @notice Workstream GP.5.1 — behavioural tests for the user-chosen
///         fee-split deposit path (`depositETHWithFee`).
///
/// @dev    Covers GP.5.1.f (happy path), GP.5.1.g (revert cases), and
///         GP.5.1.h (fuzz: `userAmount + poolAmount == msg.value`).
///         Each happy-path scenario pins the live contract against the
///         `FeeSplitMath` reference via `vm.expectEmit`; the reference
///         is independently anchored to hand-computed values
///         (`test_reference_anchor_*`) and to the Lean spec
///         (`test/CrossCheck/DepositFeeSplit.t.sol`).  No file checks
///         the formula against itself.
contract BridgeFeeSplitTest is Test {
    address private alice = address(0xA1);
    address private bob = address(0xB0B);

    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_NATIVE_ETH` (a
    ///      contract constant is not reachable via the type name from
    ///      another contract).
    uint64 private constant NATIVE_ETH = 0;

    /// @dev Local copy of the contract event for `vm.expectEmit`.
    event DepositWithFeeInitiated(
        address indexed sender,
        uint64 indexed resourceId,
        address indexed token,
        uint256 userAmount,
        uint256 poolAmount,
        uint64 budgetGrant,
        uint64 depositorNonce,
        bytes32 receiptHash
    );

    function setUp() public {
        vm.deal(alice, type(uint128).max);
        vm.deal(bob, type(uint128).max);
    }

    // ------------------------------------------------------------------
    // Deployment helper
    // ------------------------------------------------------------------

    /// @notice Deploy a standalone bridge with chosen fee-split
    ///         parameters.  `migration == address(0)` keeps the
    ///         `circuitOpen` breaker open for a fresh deployment.
    function _deploy(uint16 minFeeBps, uint16 maxFeeBps, uint64 rate, uint256 tvlCap)
        internal
        returns (KnomosisBridge)
    {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-fee-split-test"),
                attestor: address(0xA11CE),
                disputeVerifier: address(0xDEAD),
                sequencerStake: address(0xBEEF),
                migration: address(0),
                disputeWindowBlocks: 100,
                maxRedemptionWindowBlocks: 50,
                maxAttestationStaleBlocks: 200,
                cooldownBlocks: 50,
                tvlCap: tvlCap,
                minFeeBps: minFeeBps,
                maxFeeBps: maxFeeBps,
                weiPerBudgetUnitEth: rate,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice Default test bridge: full `[0, 5000]` fee range, a
    ///         realistic exchange rate of 1 budget unit per 10^9 wei,
    ///         no TVL ceiling.
    function _defaultBridge() internal returns (KnomosisBridge) {
        return _deploy(0, 5000, 1_000_000_000, type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Shared assertion helper
    // ------------------------------------------------------------------

    /// @notice Deposit `v` wei at `feeBps` as `user`, asserting the
    ///         emitted `DepositWithFeeInitiated` matches the
    ///         `FeeSplitMath` reference exactly, that TVL grows by the
    ///         full deposit, and that the per-depositor nonce
    ///         increments.  Returns the reference split for the caller
    ///         to cross-check against hand-computed values.
    function _depositAndCheck(KnomosisBridge bridge, address user, uint256 v, uint16 feeBps)
        internal
        returns (uint256 userAmount, uint256 poolAmount, uint64 budgetGrant)
    {
        (userAmount, poolAmount, budgetGrant) =
            FeeSplitMath.split(v, feeBps, bridge.weiPerBudgetUnitEth());

        uint64 nonce = bridge.depositNonce(user);
        bytes32 expectedHash = FeeSplitMath.receiptHash(
            bridge.deploymentId(),
            user,
            NATIVE_ETH,
            address(0),
            userAmount,
            poolAmount,
            budgetGrant,
            nonce
        );

        uint256 tvlBefore = bridge.totalLockedValue();

        vm.expectEmit(true, true, true, true, address(bridge));
        emit DepositWithFeeInitiated(
            user,
            NATIVE_ETH,
            address(0),
            userAmount,
            poolAmount,
            budgetGrant,
            nonce,
            expectedHash
        );

        vm.prank(user);
        bridge.depositETHWithFee{value: v}(feeBps);

        // Conservation + accounting invariants on the live contract.
        assertEq(userAmount + poolAmount, v, "split must conserve msg.value");
        assertEq(bridge.totalLockedValue(), tvlBefore + v, "TVL grows by full deposit");
        assertEq(bridge.depositNonce(user), nonce + 1, "nonce increments");
    }

    // ------------------------------------------------------------------
    // GP.5.1.f — happy-path cases
    // ------------------------------------------------------------------

    function test_zeroFee_pureDeposit() public {
        KnomosisBridge bridge = _defaultBridge();
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 1 ether, 0);
        assertEq(p, 0, "no pool credit at zero fee");
        assertEq(u, 1 ether, "full amount to user");
        assertEq(g, 0, "no budget grant at zero fee");
    }

    function test_minFee_smallestPool() public {
        // minFeeBps = 50 (0.5%); the smallest admissible pool credit.
        KnomosisBridge bridge = _deploy(50, 5000, 1, type(uint256).max);
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 1_000_000, 50);
        assertEq(p, 5000, "0.5% of 1e6");
        assertEq(u, 995_000, "remainder to user");
        assertEq(g, 5000, "budget == poolAmount at rate 1");
    }

    function test_maxFee_largestPool() public {
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        (uint256 u, uint256 p,) = _depositAndCheck(bridge, alice, 100, 5000);
        assertEq(p, 50, "50% of 100");
        assertEq(u, 50, "exact half to user");
    }

    function test_tinyAmount_roundsToUser() public {
        // 1 wei at 1% → poolAmount floors to 0, all 1 wei to user.
        KnomosisBridge bridge = _defaultBridge();
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 1, 100);
        assertEq(p, 0, "pool rounds to zero");
        assertEq(u, 1, "1 wei to user");
        assertEq(g, 0, "budget rounds to zero");
    }

    function test_rateOne_budgetEqualsPool() public {
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        (, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 10_000, 100);
        assertEq(p, 100, "1% of 1e4");
        assertEq(g, 100, "budget == poolAmount at rate 1");
    }

    function test_rateTrillion_budgetDivides() public {
        KnomosisBridge bridge = _deploy(0, 5000, 1_000_000_000_000, type(uint256).max);
        // poolAmount = 50% of 6e12 = 3e12; budget = 3e12 / 1e12 = 3.
        (, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 6_000_000_000_000, 5000);
        assertEq(p, 3_000_000_000_000, "half of 6e12");
        assertEq(g, 3, "3e12 / 1e12");
    }

    function test_budgetClamp_doesNotRevert() public {
        // Huge pool at rate 1 → rawBudget far exceeds the 10^12 cap;
        // the budget is clamped (NOT a revert) and the deposit lands.
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 10 ether, 5000);
        assertEq(p, 5 ether, "half of 10 ETH");
        assertEq(u, 5 ether, "half to user");
        assertEq(g, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "budget clamped at cap");
    }

    function test_budgetClamp_exactBoundary_notClamped() public {
        // rawBudget == MAX_BUDGET_PER_DEPOSIT exactly: the clamp uses a
        // strict `>` so the boundary value passes through unclamped.
        // poolAmount = 50% of 2e12 = 1e12; rate 1 → rawBudget = 1e12.
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        (, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 2_000_000_000_000, 5000);
        assertEq(p, 1_000_000_000_000, "half of 2e12");
        assertEq(g, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "exact boundary, not clamped");
    }

    function test_budgetClamp_oneAboveBoundary_clamped() public {
        // poolAmount = 1e12 + 10000 > 1e12 → clamped to the cap.
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        (, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 2_000_000_020_000, 5000);
        assertEq(p, 1_000_000_010_000, "half of 2e12 + 20000");
        assertEq(g, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "one above boundary, clamped");
    }

    function test_residue_favoursUser() public {
        // v = 12345, feeBps = 333 → poolAmount = floor(12345*333/10000)
        // = floor(411.0885) = 411; the residue accrues to the user.
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        (uint256 u, uint256 p,) = _depositAndCheck(bridge, alice, 12_345, 333);
        assertEq(p, 411, "floor(12345 * 333 / 10000)");
        assertEq(u, 11_934, "residue to user");
    }

    function test_feeJustBelowMax() public {
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        (, uint256 p,) = _depositAndCheck(bridge, alice, 1_000_000, 4999);
        assertEq(p, 499_900, "floor(1e6 * 4999 / 10000)");
    }

    function test_singleAllowedFee_minEqualsMax() public {
        // minFeeBps == maxFeeBps: exactly one admissible fee value.
        KnomosisBridge bridge = _deploy(250, 250, 1, type(uint256).max);
        (, uint256 p,) = _depositAndCheck(bridge, alice, 1_000_000, 250);
        assertEq(p, 25_000, "2.5% of 1e6");
    }

    function test_nonce_incrementsAcrossDeposits() public {
        KnomosisBridge bridge = _defaultBridge();
        assertEq(bridge.depositNonce(alice), 0);
        _depositAndCheck(bridge, alice, 1 ether, 100);
        assertEq(bridge.depositNonce(alice), 1);
        _depositAndCheck(bridge, alice, 2 ether, 200);
        assertEq(bridge.depositNonce(alice), 2);
    }

    function test_independentNonces_perDepositor() public {
        KnomosisBridge bridge = _defaultBridge();
        _depositAndCheck(bridge, alice, 1 ether, 100);
        _depositAndCheck(bridge, alice, 1 ether, 100);
        // Bob's first deposit uses nonce 0 even though Alice is at 2.
        assertEq(bridge.depositNonce(bob), 0);
        _depositAndCheck(bridge, bob, 1 ether, 100);
        assertEq(bridge.depositNonce(bob), 1);
        assertEq(bridge.depositNonce(alice), 2);
    }

    function test_tvl_accumulatesAcrossDeposits() public {
        KnomosisBridge bridge = _defaultBridge();
        _depositAndCheck(bridge, alice, 3 ether, 100);
        _depositAndCheck(bridge, bob, 5 ether, 4000);
        assertEq(bridge.totalLockedValue(), 8 ether, "TVL = sum of full deposits");
    }

    function test_differentFee_distinctReceiptHash() public {
        // Two deposits with identical other fields but different
        // chosenFeeBps must produce different receiptHashes, because
        // the split fields (userAmount / poolAmount / budgetGrant) feed
        // the hash.  We capture both via recorded logs.
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1_000_000}(100);
        (,,,, bytes32 hash1,,,) = _findEvent(vm.getRecordedLogs());

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1_000_000}(200);
        (,,,, bytes32 hash2,,,) = _findEvent(vm.getRecordedLogs());

        assertTrue(hash1 != hash2, "different fee -> different receiptHash");
    }

    function test_realisticRate_tenPercentMaxFee() public {
        // A realistic deployment: max fee 10%, rate 10^9.
        KnomosisBridge bridge = _deploy(0, 1000, 1_000_000_000, type(uint256).max);
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 5 ether, 1000);
        assertEq(p, 0.5 ether, "10% of 5 ETH");
        assertEq(u, 4.5 ether, "90% to user");
        assertEq(g, uint64(uint256(0.5 ether) / 1_000_000_000), "pool / 1e9");
    }

    // ------------------------------------------------------------------
    // GP.5.1.f — reference anchors (independent ground truth)
    // ------------------------------------------------------------------

    /// @notice Anchor `FeeSplitMath.split` to hand-computed values, so
    ///         the `vm.expectEmit` checks above are not circular.
    function test_reference_anchor_split() public pure {
        (uint256 u, uint256 p, uint64 g) = FeeSplitMath.split(10_000, 100, 1);
        assertEq(u, 9900);
        assertEq(p, 100);
        assertEq(g, 100);

        (u, p, g) = FeeSplitMath.split(1, 100, 1);
        assertEq(u, 1);
        assertEq(p, 0);
        assertEq(g, 0);

        (u, p, g) = FeeSplitMath.split(12_345, 333, 1);
        assertEq(u, 11_934);
        assertEq(p, 411);
        assertEq(g, 411);

        // Clamp.
        (,, g) = FeeSplitMath.split(10 ether, 5000, 1);
        assertEq(g, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT);
    }

    /// @notice Pin the contract's compile-time caps against the
    ///         reference library's mirrored constant and the documented
    ///         values.  Any drift in `MAX_BUDGET_PER_DEPOSIT` fails
    ///         here.
    function test_compileTimeCaps_pinned() public {
        KnomosisBridge bridge = _defaultBridge();
        assertEq(bridge.MAX_FEE_BPS_CAP(), 5000, "MAX_FEE_BPS_CAP");
        assertEq(bridge.MIN_WEI_PER_BUDGET_UNIT(), 1, "MIN_WEI_PER_BUDGET_UNIT");
        assertEq(
            bridge.MAX_BUDGET_PER_DEPOSIT(),
            FeeSplitMath.MAX_BUDGET_PER_DEPOSIT,
            "contract cap == reference cap"
        );
        assertEq(bridge.MAX_BUDGET_PER_DEPOSIT(), 1_000_000_000_000, "10^12");
    }

    // ------------------------------------------------------------------
    // GP.5.1.g — revert / error cases
    // ------------------------------------------------------------------

    function test_revert_zeroDeposit() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.expectRevert(KnomosisBridge.ZeroDeposit.selector);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 0}(0);
    }

    function test_revert_zeroDeposit_takesPrecedenceOverFeeCheck() public {
        // minFeeBps = 100; a zero-value call still reverts ZeroDeposit
        // (the value guard fires before the fee-range guards).
        KnomosisBridge bridge = _deploy(100, 5000, 1, type(uint256).max);
        vm.expectRevert(KnomosisBridge.ZeroDeposit.selector);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 0}(200);
    }

    function test_revert_feeBelowMin() public {
        KnomosisBridge bridge = _deploy(100, 5000, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsBelowMin.selector, uint16(99)));
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(99);
    }

    function test_revert_feeAboveMax() public {
        KnomosisBridge bridge = _deploy(0, 1000, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, uint16(1001)));
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(1001);
    }

    function test_revert_feeAboveMax_outOfBpsRange() public {
        // chosenFeeBps = 10001 (> 100%): the range guard fires before
        // any arithmetic, so it reverts FeeBpsAboveMax, not an
        // arithmetic error.
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, uint16(10001)));
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(10001);
    }

    function test_revert_feeAboveMax_uint16Max() public {
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, type(uint16).max)
        );
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(type(uint16).max);
    }

    function test_revert_tvlCapReached() public {
        // Cap at 1 ETH; a 2-ETH deposit exceeds it.
        KnomosisBridge bridge = _deploy(0, 5000, 1, 1 ether);
        vm.expectRevert(KnomosisBridge.TvlCapReached.selector);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 2 ether}(100);
    }

    function test_revert_tvlCap_firesOnFullValue_notUserAmount() public {
        // Cap at 1 ETH.  A deposit of exactly 1 ETH at 50% fee has
        // userAmount = 0.5 ETH but the cap must fire on the FULL 1 ETH
        // + 1 wei, proving fee manipulation cannot bypass the cap.
        KnomosisBridge bridge = _deploy(0, 5000, 1, 1 ether);
        // 1 ETH deposit lands (TVL == cap).
        _depositAndCheck(bridge, alice, 1 ether, 5000);
        // A further 1-wei deposit pushes TVL over the cap.
        vm.expectRevert(KnomosisBridge.TvlCapReached.selector);
        vm.prank(bob);
        bridge.depositETHWithFee{value: 1}(0);
    }

    // ---- Constructor guards ----

    function test_revert_constructor_minExceedsMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.MinFeeBpsExceedsMax.selector, uint16(2000), uint16(1000)
            )
        );
        _deploy(2000, 1000, 1, type(uint256).max);
    }

    function test_revert_constructor_minExceedsMax_takesPrecedence() public {
        // minFeeBps = 5001 > maxFeeBps = 5000: the min>max check fires
        // before the cap check (which would also reject 5001 once it
        // were the max, but it is the min here).
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.MinFeeBpsExceedsMax.selector, uint16(5001), uint16(5000)
            )
        );
        _deploy(5001, 5000, 1, type(uint256).max);
    }

    function test_revert_constructor_maxExceedsCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.MaxFeeBpsExceedsCap.selector, uint16(5001))
        );
        _deploy(0, 5001, 1, type(uint256).max);
    }

    function test_revert_constructor_maxExceedsCap_minEqualsMax() public {
        // minFeeBps == maxFeeBps == 6000: min>max passes, cap fails.
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.MaxFeeBpsExceedsCap.selector, uint16(6000))
        );
        _deploy(6000, 6000, 1, type(uint256).max);
    }

    function test_revert_constructor_weiPerBudgetUnitZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.WeiPerBudgetUnitTooSmall.selector, uint64(0))
        );
        _deploy(0, 5000, 0, type(uint256).max);
    }

    function test_constructor_pins_feeSplitImmutables() public {
        KnomosisBridge bridge = _deploy(25, 1234, 777, type(uint256).max);
        assertEq(bridge.minFeeBps(), 25);
        assertEq(bridge.maxFeeBps(), 1234);
        assertEq(bridge.weiPerBudgetUnitEth(), 777);
    }

    function test_constructor_allowsMaxFeeAtCap() public {
        // maxFeeBps exactly at the cap is allowed.
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        assertEq(bridge.maxFeeBps(), 5000);
    }

    function test_minEqualsMax_zero_forcesZeroFee() public {
        // A deployment that forbids any fee: min == max == 0.  Only
        // chosenFeeBps == 0 is admissible (a pure balance deposit); any
        // positive fee reverts FeeBpsAboveMax.
        KnomosisBridge bridge = _deploy(0, 0, 1, type(uint256).max);
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 1 ether, 0);
        assertEq(p, 0, "forced zero pool");
        assertEq(u, 1 ether, "full amount to user");
        assertEq(g, 0, "no budget");
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, uint16(1)));
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(1);
    }

    // ------------------------------------------------------------------
    // GP.5.1.f — cross-function integration
    // ------------------------------------------------------------------

    function test_mixedDeposit_sharesNonce() public {
        // depositETH and depositETHWithFee share the per-depositor
        // `depositNonce` counter, so no two deposits by the same
        // depositor (of any kind) ever reuse a nonce — guaranteeing
        // receiptHash uniqueness across deposit kinds.
        KnomosisBridge bridge = _deploy(0, 5000, 1, type(uint256).max);
        assertEq(bridge.depositNonce(alice), 0);
        vm.prank(alice);
        bridge.depositETH{value: 1 ether}();
        assertEq(bridge.depositNonce(alice), 1, "depositETH consumes nonce 0");
        // `_depositAndCheck` reads nonce 1, expects the event with nonce
        // 1, and asserts it advances to 2.
        _depositAndCheck(bridge, alice, 2 ether, 100);
        assertEq(bridge.depositNonce(alice), 2, "depositETHWithFee consumes nonce 1");
    }

    function test_revert_circuitBroken_byActivatedMigration() public {
        // depositETHWithFee carries the `circuitOpen` modifier, so an
        // activated migration halts fee-split deposits exactly as it
        // halts depositETH.  Confirms the modifier is wired onto the
        // new entry point.
        MockActivatedMigration mig = new MockActivatedMigration();
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        KnomosisBridge bridge = new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-fee-split-test"),
                attestor: address(0xA11CE),
                disputeVerifier: address(0xDEAD),
                sequencerStake: address(0xBEEF),
                migration: address(mig),
                disputeWindowBlocks: 100,
                maxRedemptionWindowBlocks: 50,
                maxAttestationStaleBlocks: 200,
                cooldownBlocks: 50,
                tvlCap: type(uint256).max,
                minFeeBps: 0,
                maxFeeBps: 5000,
                weiPerBudgetUnitEth: 1,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
        vm.expectRevert(KnomosisBridge.MigrationActivated.selector);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(100);
    }

    // ------------------------------------------------------------------
    // GP.5.1.h — fuzz: conservation + differential against reference
    // ------------------------------------------------------------------

    /// @notice For any admissible `(v, feeBps)`, the live contract emits
    ///         exactly the `FeeSplitMath` reference split, and
    ///         `userAmount + poolAmount == msg.value`.
    function testFuzz_conservation_and_reference(uint256 v, uint16 feeBps) public {
        // Modulo bounding (no forge-std `bound` console noise): v in
        // [1, 1e30] keeps `v * feeBps` far below uint256.max; feeBps in
        // [0, 5000] is the admissible range for this bridge.
        v = (v % 1e30) + 1;
        feeBps = uint16(uint256(feeBps) % 5001);
        KnomosisBridge bridge = _deploy(0, 5000, 1_000_000_000, type(uint256).max);
        vm.deal(alice, v);

        (uint256 refUser, uint256 refPool, uint64 refBudget) =
            FeeSplitMath.split(v, feeBps, bridge.weiPerBudgetUnitEth());

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: v}(feeBps);
        (uint256 u, uint256 p, uint64 g,,,,,) = _findEvent(vm.getRecordedLogs());

        assertEq(u + p, v, "conservation");
        assertEq(u, refUser, "userAmount matches reference");
        assertEq(p, refPool, "poolAmount matches reference");
        assertEq(g, refBudget, "budgetGrant matches reference");
        assertLe(g, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "budget within cap");
    }

    /// @notice Differential across the exchange rate as well: deploy a
    ///         fresh bridge per run with a fuzzed `weiPerBudgetUnit` and
    ///         assert the contract still matches the reference.
    function testFuzz_differential_acrossRate(uint256 v, uint16 feeBps, uint64 rate) public {
        v = (v % 1e30) + 1;
        feeBps = uint16(uint256(feeBps) % 5001);
        rate = uint64(uint256(rate) % 1e15) + 1;
        KnomosisBridge bridge = _deploy(0, 5000, rate, type(uint256).max);
        vm.deal(alice, v);

        (uint256 refUser, uint256 refPool, uint64 refBudget) = FeeSplitMath.split(v, feeBps, rate);

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: v}(feeBps);
        (uint256 u, uint256 p, uint64 g,, bytes32 hash,,,) = _findEvent(vm.getRecordedLogs());

        assertEq(u, refUser, "userAmount matches reference");
        assertEq(p, refPool, "poolAmount matches reference");
        assertEq(g, refBudget, "budgetGrant matches reference");

        bytes32 refHash = FeeSplitMath.receiptHash(
            bridge.deploymentId(),
            alice,
            NATIVE_ETH,
            address(0),
            refUser,
            refPool,
            refBudget,
            0
        );
        assertEq(hash, refHash, "receiptHash matches reference");
    }

    /// @notice A fuzzed out-of-range fee always reverts (never silently
    ///         under/overflows).  Splits the domain at `maxFeeBps`.
    function testFuzz_outOfRangeFee_reverts(uint256 v, uint16 feeBps) public {
        v = (v % 1e30) + 1;
        uint16 maxF = 1000;
        // Map into [maxF + 1, type(uint16).max] = [1001, 65535].
        feeBps = uint16(uint256(maxF) + 1 + (uint256(feeBps) % (uint256(type(uint16).max) - maxF)));
        KnomosisBridge bridge = _deploy(0, maxF, 1, type(uint256).max);
        vm.deal(alice, v);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, feeBps));
        vm.prank(alice);
        bridge.depositETHWithFee{value: v}(feeBps);
    }

    // ------------------------------------------------------------------
    // Event-decoding helper
    // ------------------------------------------------------------------

    /// @notice Locate and decode the single `DepositWithFeeInitiated`
    ///         entry in a recorded-log array.  Reverts if absent.
    function _findEvent(Vm.Log[] memory logs)
        internal
        pure
        returns (
            uint256 userAmount,
            uint256 poolAmount,
            uint64 budgetGrant,
            uint64 nonce,
            bytes32 receiptHash,
            address sender,
            uint64 resourceId,
            address token
        )
    {
        bytes32 sig = keccak256(
            "DepositWithFeeInitiated(address,uint64,address,uint256,uint256,uint64,uint64,bytes32)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == sig) {
                sender = address(uint160(uint256(logs[i].topics[1])));
                resourceId = uint64(uint256(logs[i].topics[2]));
                token = address(uint160(uint256(logs[i].topics[3])));
                (userAmount, poolAmount, budgetGrant, nonce, receiptHash) =
                    abi.decode(logs[i].data, (uint256, uint256, uint64, uint64, bytes32));
                return
                    (userAmount, poolAmount, budgetGrant, nonce, receiptHash, sender, resourceId, token);
            }
        }
        revert("DepositWithFeeInitiated not found");
    }
}

/// @notice Minimal migration mock whose `activated()` returns true.
///         Used to confirm `depositETHWithFee` respects the
///         `circuitOpen` breaker (`MigrationActivated`).
contract MockActivatedMigration {
    function activated() external pure returns (bool) {
        return true;
    }
}
