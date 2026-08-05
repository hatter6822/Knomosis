// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.36;

import {FeeSplitBehaviour} from "test/utils/FeeSplitBehaviour.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";

/// @title BridgeFeeSplitTest
/// @notice Workstream GP.5.1 — behavioural tests for the user-chosen
///         fee-split deposit path (`depositETHWithFee`).
///
/// @dev    Covers GP.5.1.f (happy path), GP.5.1.g (revert cases), and
///         GP.5.1.h (fuzz: `userAmount + poolAmount == msg.value`).
///         Each happy-path scenario pins the live contract against the
///         `FeeSplitMath` reference by decoding the emitted receipt; the
///         reference is independently anchored to hand-computed values
///         (`test_reference_anchor_*`) and to the Lean spec
///         (`test/CrossCheck/DepositFeeSplit.t.sol`).  No file checks
///         the formula against itself.
///
///         The twenty-five cases this leg shares with the BOLD leg live
///         in `FeeSplitBehaviour`; what remains here is ETH-specific --
///         the constructor guards, the `msg.value` fuzz, the gas smoke
///         test, and the mixed-currency nonce case.
contract BridgeFeeSplitTest is FeeSplitBehaviour {
    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_NATIVE_ETH` (a
    ///      contract constant is not reachable via the type name from
    ///      another contract).
    uint64 private constant NATIVE_ETH = 0;

    function setUp() public {
        vm.deal(alice, type(uint128).max);
        vm.deal(bob, type(uint128).max);
    }

    // ------------------------------------------------------------------
    // `FeeSplitBehaviour` hooks -- the ETH leg
    // ------------------------------------------------------------------

    /// @inheritdoc FeeSplitBehaviour
    /// @dev A standalone bridge, BOLD disabled.  `migration ==
    ///      address(0)` keeps the `circuitOpen` breaker open for a
    ///      fresh deployment.
    function _deployLeg(uint16 minFeeBps, uint16 maxFeeBps, uint64 rate, uint256 tvlCap)
        internal
        override
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
                weiPerBudgetUnitBold: 0,
                boldTokenAddress: address(0),
                boldTvlCap: 0,
                boldCircuitBreaker: address(0),
                boldAdmin: address(0),
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 0,
                ammDisasterRecovery: address(0),
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @inheritdoc FeeSplitBehaviour
    /// @dev No approval to grant: `msg.value` needs only a balance, and
    ///      `setUp` already funds both depositors well past any case here.
    function _fundFor(KnomosisBridge, address, uint256) internal pure override {}

    /// @inheritdoc FeeSplitBehaviour
    function _deposit(KnomosisBridge bridge, address user, uint256 amount, uint16 feeBps)
        internal
        override
    {
        vm.prank(user);
        bridge.depositETHWithFee{value: amount}(feeBps);
    }

    /// @inheritdoc FeeSplitBehaviour
    function _legRate(KnomosisBridge bridge) internal view override returns (uint64) {
        return bridge.weiPerBudgetUnitEth();
    }

    /// @inheritdoc FeeSplitBehaviour
    function _legResourceId() internal pure override returns (uint64) {
        return NATIVE_ETH;
    }

    /// @inheritdoc FeeSplitBehaviour
    /// @dev Native ETH carries no token address.
    function _legToken() internal pure override returns (address) {
        return address(0);
    }

    /// @inheritdoc FeeSplitBehaviour
    function _legBalanceOf(address who) internal view override returns (uint256) {
        return who.balance;
    }

    // ------------------------------------------------------------------
    // GP.5.1.f — happy-path cases
    // ------------------------------------------------------------------

    function test_budgetClamp_doesNotRevert() public {
        // Huge pool at rate 1 -> rawBudget far exceeds the 10^12 cap;
        // the budget is clamped (NOT a revert) and the deposit lands.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 10 ether, 5000);
        assertEq(rcpt.poolAmount, 5 ether, "half of 10 ETH");
        assertEq(rcpt.userAmount, 5 ether, "half to user");
        assertEq(rcpt.budgetGrant, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "budget clamped at cap");
    }

    function test_replayResistance_deploymentBinding() public {
        // The SAME deposit (depositor, value, fee, and nonce -- both
        // bridges are fresh, so nonce 0) on two DISTINCT deployments
        // produces different receiptHashes, because `deploymentId`
        // (keccak256 over chainid + contract address + version tag) is
        // bound into the hash.  Isolates cross-deployment replay
        // resistance -- the security rationale for binding deploymentId
        // (which the unified-gas-pool plan's bare recipe omitted).
        KnomosisBridge bridgeA = _deployLeg(0, 5000, 1, type(uint256).max);
        KnomosisBridge bridgeB = _deployLeg(0, 5000, 1, type(uint256).max);
        assertTrue(
            bridgeA.deploymentId() != bridgeB.deploymentId(),
            "two deployments have distinct deploymentIds"
        );

        vm.recordLogs();
        vm.prank(alice);
        bridgeA.depositETHWithFee{value: 1 ether}(100);
        DepositReceipt memory rA = _findDepositReceipt(vm.getRecordedLogs());

        vm.recordLogs();
        vm.prank(alice);
        bridgeB.depositETHWithFee{value: 1 ether}(100);
        DepositReceipt memory rB = _findDepositReceipt(vm.getRecordedLogs());

        // Both use nonce 0, so deploymentId is the only differing input.
        assertEq(rA.nonce, 0, "bridgeA deposit nonce 0");
        assertEq(rB.nonce, 0, "bridgeB deposit nonce 0");
        assertTrue(
            rA.receiptHash != rB.receiptHash,
            "same deposit on different deployments must hash differently"
        );
    }

    function test_realisticRate_tenPercentMaxFee() public {
        // A realistic deployment: max fee 10%, rate 10^9.
        KnomosisBridge bridge = _deployLeg(0, 1000, 1_000_000_000, type(uint256).max);
        DepositReceipt memory rcpt = _depositAndCheck(bridge, alice, 5 ether, 1000);
        assertEq(rcpt.poolAmount, 0.5 ether, "10% of 5 ETH");
        assertEq(rcpt.userAmount, 4.5 ether, "90% to user");
        // 0.5 ETH / 1e9 = 5e26 / 1e9 = 5e17; fits uint64? 5e17 < 1.8e19 yes.
        assertEq(rcpt.budgetGrant, 500_000_000, "pool / 1e9");
    }

    function test_gas_depositETHWithFee() public {
        // Lightweight gas-regression smoke test for the new entry point.
        // A generous ceiling catches gross regressions (an accidental
        // loop, an SSTORE storm) without being brittle to optimizer /
        // compiler drift; the dedicated 5%-tolerance gas baseline is
        // GP.11.9's deliverable.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1_000_000_000, type(uint256).max);
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        bridge.depositETHWithFee{value: 1 ether}(100);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("depositETHWithFee gas (first deposit, cold)", used);
        assertLt(used, 150_000, "depositETHWithFee gas regression");
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
    ///         here.  The three GP.5.5 Liquity-V2 TroveManager address
    ///         pins are mirrored by
    ///         `BoldCircuitBreaker.t.sol::test_troveManagerConstants_pinned`.
    function test_compileTimeCaps_pinned() public {
        KnomosisBridge bridge = _defaultLeg();
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

    function test_revert_feeAboveMax_uint16Max() public {
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, type(uint16).max)
        );
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(type(uint16).max);
    }

    // ---- Constructor guards ----

    function test_revert_constructor_minExceedsMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.MinFeeBpsExceedsMax.selector, uint16(2000), uint16(1000)
            )
        );
        _deployLeg(2000, 1000, 1, type(uint256).max);
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
        _deployLeg(5001, 5000, 1, type(uint256).max);
    }

    function test_revert_constructor_maxExceedsCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.MaxFeeBpsExceedsCap.selector, uint16(5001))
        );
        _deployLeg(0, 5001, 1, type(uint256).max);
    }

    function test_revert_constructor_maxExceedsCap_minEqualsMax() public {
        // minFeeBps == maxFeeBps == 6000: min>max passes, cap fails.
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.MaxFeeBpsExceedsCap.selector, uint16(6000))
        );
        _deployLeg(6000, 6000, 1, type(uint256).max);
    }

    function test_revert_constructor_weiPerBudgetUnitZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.WeiPerBudgetUnitTooSmall.selector, uint64(0))
        );
        _deployLeg(0, 5000, 0, type(uint256).max);
    }

    function test_constructor_pins_feeSplitImmutables() public {
        KnomosisBridge bridge = _deployLeg(25, 1234, 777, type(uint256).max);
        assertEq(bridge.minFeeBps(), 25);
        assertEq(bridge.maxFeeBps(), 1234);
        assertEq(bridge.weiPerBudgetUnitEth(), 777);
    }

    function test_constructor_allowsMaxFeeAtCap() public {
        // maxFeeBps exactly at the cap is allowed.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
        assertEq(bridge.maxFeeBps(), 5000);
    }

    // ------------------------------------------------------------------
    // GP.5.1.f — cross-function integration
    // ------------------------------------------------------------------

    function test_mixedDeposit_sharesNonce() public {
        // depositETH and depositETHWithFee share the per-depositor
        // `depositNonce` counter, so no two deposits by the same
        // depositor (of any kind) ever reuse a nonce — guaranteeing
        // receiptHash uniqueness across deposit kinds.
        KnomosisBridge bridge = _deployLeg(0, 5000, 1, type(uint256).max);
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
                weiPerBudgetUnitBold: 0,
                boldTokenAddress: address(0),
                boldTvlCap: 0,
                boldCircuitBreaker: address(0),
                boldAdmin: address(0),
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 0,
                ammDisasterRecovery: address(0),
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
        KnomosisBridge bridge = _deployLeg(0, 5000, 1_000_000_000, type(uint256).max);
        vm.deal(alice, v);

        (uint256 refUser, uint256 refPool, uint64 refBudget) =
            FeeSplitMath.split(v, feeBps, bridge.weiPerBudgetUnitEth());

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: v}(feeBps);
        DepositReceipt memory r = _findDepositReceipt(vm.getRecordedLogs());

        assertEq(r.userAmount + r.poolAmount, v, "conservation");
        assertEq(r.userAmount, refUser, "userAmount matches reference");
        assertEq(r.poolAmount, refPool, "poolAmount matches reference");
        assertEq(r.budgetGrant, refBudget, "budgetGrant matches reference");
        assertLe(r.budgetGrant, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "budget within cap");
    }

    /// @notice Differential across the exchange rate as well: deploy a
    ///         fresh bridge per run with a fuzzed `weiPerBudgetUnit` and
    ///         assert the contract still matches the reference.
    function testFuzz_differential_acrossRate(uint256 v, uint16 feeBps, uint64 rate) public {
        v = (v % 1e30) + 1;
        feeBps = uint16(uint256(feeBps) % 5001);
        rate = uint64(uint256(rate) % 1e15) + 1;
        KnomosisBridge bridge = _deployLeg(0, 5000, rate, type(uint256).max);
        vm.deal(alice, v);

        // The reference receipt, built from the FUZZED `rate` rather
        // than read back off the bridge -- that independence is the
        // point of a differential.  As a struct because the nine-argument
        // `FeeSplitMath.receiptHash` held nine live locals here, which is
        // one slot more than the ETH leg's frame has to spare.
        DepositReceipt memory want;
        want.sender = alice;
        want.resourceId = NATIVE_ETH;
        want.token = address(0);
        (want.userAmount, want.poolAmount, want.budgetGrant) =
            FeeSplitMath.split(v, feeBps, rate);
        // Fresh bridge, alice's first deposit.  `ammSeedAmount` stays 0.
        want.nonce = 0;
        want.receiptHash = _receiptHashOf(bridge.deploymentId(), want);

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: v}(feeBps);

        _assertReceiptEq(_findDepositReceipt(vm.getRecordedLogs()), want);
    }

    /// @notice A fuzzed out-of-range fee always reverts (never silently
    ///         under/overflows).  Splits the domain at `maxFeeBps`.
    function testFuzz_outOfRangeFee_reverts(uint256 v, uint16 feeBps) public {
        v = (v % 1e30) + 1;
        uint16 maxF = 1000;
        // Map into [maxF + 1, type(uint16).max] = [1001, 65535].
        feeBps = uint16(uint256(maxF) + 1 + (uint256(feeBps) % (uint256(type(uint16).max) - maxF)));
        KnomosisBridge bridge = _deployLeg(0, maxF, 1, type(uint256).max);
        vm.deal(alice, v);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, feeBps));
        vm.prank(alice);
        bridge.depositETHWithFee{value: v}(feeBps);
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
