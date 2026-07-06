// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";
import {KnomosisEip712} from "src/lib/KnomosisEip712.sol";
import {
    MockBold,
    FeeOnTransferBold,
    WrongSymbolBold,
    RevertingSymbolBold,
    ReturnsFalseBold
} from "test/utils/MockBold.sol";

/// @title BridgeFeeSplitBoldTest
/// @notice Workstream GP.5.4 — behavioural tests for the BOLD-currency
///         fee-split deposit path (`depositBoldWithFee`).
///
/// @dev    The BOLD leg mirrors `depositETHWithFee` (GP.5.1) exactly save
///         that value arrives as the pinned BOLD ERC-20 via
///         `transferFrom` (with a balance-delta check) rather than as
///         `msg.value`, the pool credit accrues at `RESOURCE_ID_BOLD`,
///         and the budget grant uses `weiPerBudgetUnitBold`.  Each
///         happy-path scenario pins the live contract against the
///         `FeeSplitMath` reference (the same library the ETH suite uses,
///         independently anchored to hand-computed values and to the Lean
///         spec) by decoding the emitted `DepositWithFeeInitiated`.
///
///         `KnomosisBridge.BOLD_TOKEN_ADDRESS` is a compile-time pin, so a
///         BOLD mock is placed there with `vm.etch` before the bridge is
///         deployed (the constructor's `symbol()` cross-check reads it).
///         `vm.etch` copies runtime code and resets storage, hence the
///         `pure` `symbol()` in `MockBold` and the post-etch `mint`.
contract BridgeFeeSplitBoldTest is Test {
    address private alice = address(0xA1);
    address private bob = address(0xB0B);

    /// @dev Local mirror of `KnomosisBridge.BOLD_TOKEN_ADDRESS` (a
    ///      contract constant is not reachable via the type name from
    ///      another contract, and the mock must be etched here BEFORE the
    ///      bridge is deployed).  `test_boldConstants_pinned` asserts this
    ///      mirror equals the deployed contract's getter, so drift fails.
    address private constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_BOLD`.
    uint64 private constant RESOURCE_BOLD = 1;

    /// @dev Attestor key for the end-to-end withdrawal test (the bridge's
    ///      `submitStateRoot` requires an EIP-712 signature over the root).
    uint256 private constant ATTESTOR_PK = 0xA77E5709;

    /// @dev GP.5.5 safety-hardening roles.  A BOLD-enabled deployment
    ///      requires both non-zero; these tests do not exercise the
    ///      circuit breaker (see `BoldCircuitBreaker.t.sol`), so any fixed
    ///      non-zero addresses suffice to satisfy the constructor.
    address private constant BOLD_BREAKER = address(0xB12E6B6E);
    address private constant BOLD_ADMIN = address(0xAD814);
    /// @dev The GP.11.3 AMM disaster-recovery (kill-switch) role.
    address private constant AMM_DR = address(0xA33D6);

    /// @dev Local copy of the contract event for log decoding.  The
    ///      GP.11.2 `ammSeedAmount` field is 0 throughout this suite (every
    ///      bridge here is AMM-disabled, `ammSeedRatioBps = 0`).
    event DepositWithFeeInitiated(
        address indexed sender,
        uint64 indexed resourceId,
        address indexed token,
        uint256 userAmount,
        uint256 poolAmount,
        uint256 ammSeedAmount,
        uint64 budgetGrant,
        uint64 depositorNonce,
        bytes32 receiptHash
    );

    function setUp() public {
        // Etch a conformant BOLD mock at the pinned address so the bridge
        // constructor's address pin + symbol cross-check pass.  Tests that
        // exercise non-conformant tokens re-etch a variant first.
        _etchBold();
    }

    // ------------------------------------------------------------------
    // Deployment + BOLD-token helpers
    // ------------------------------------------------------------------

    /// @notice Place a fresh conformant `MockBold`'s runtime code at the
    ///         pinned BOLD address (resets its storage).
    function _etchBold() internal {
        MockBold impl = new MockBold();
        vm.etch(BOLD, address(impl).code);
    }

    /// @notice Master deploy helper: standalone bridge with the given fee
    ///         range, ETH + BOLD exchange rates, BOLD token address, and
    ///         TVL ceiling.  `migration == address(0)` keeps `circuitOpen`
    ///         open for a fresh deployment.
    function _deploy(
        uint16 minF,
        uint16 maxF,
        uint64 ethRate,
        uint64 boldRate,
        address boldAddr,
        uint256 tvlCap
    ) internal returns (KnomosisBridge) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-bold-fee-split-test"),
                attestor: address(0xA11CE),
                disputeVerifier: address(0xDEAD),
                sequencerStake: address(0xBEEF),
                migration: address(0),
                disputeWindowBlocks: 100,
                maxRedemptionWindowBlocks: 50,
                maxAttestationStaleBlocks: 200,
                cooldownBlocks: 50,
                tvlCap: tvlCap,
                minFeeBps: minF,
                maxFeeBps: maxF,
                weiPerBudgetUnitEth: ethRate,
                weiPerBudgetUnitBold: boldRate,
                boldTokenAddress: boldAddr,
                // Per-BOLD cap == global cap, so it never binds tighter
                // than the existing GP.5.4 behaviour these suites assert;
                // `BoldCircuitBreaker.t.sol` exercises a tighter cap.
                boldTvlCap: tvlCap,
                boldCircuitBreaker: BOLD_BREAKER,
                boldAdmin: BOLD_ADMIN,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 0,
                ammDisasterRecovery: AMM_DR,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice BOLD-enabled bridge with the canonical pin and ETH rate 1.
    function _deployBold(uint16 minF, uint16 maxF, uint64 boldRate, uint256 tvlCap)
        internal
        returns (KnomosisBridge)
    {
        return _deploy(minF, maxF, 1, boldRate, BOLD, tvlCap);
    }

    /// @notice Default test bridge: full `[0, 5000]` fee range, a
    ///         realistic BOLD exchange rate of 1 unit per 10^9 BOLD-wei,
    ///         no TVL ceiling.
    function _defaultBold() internal returns (KnomosisBridge) {
        return _deployBold(0, 5000, 1_000_000_000, type(uint256).max);
    }

    /// @notice Deploy a bridge with a chosen BOLD address + resource map.
    ///         Used by the resourceId-1-reservation guard tests.
    function _deployWithResources(
        address boldAddr,
        uint64[] memory rids,
        address[] memory toks
    ) internal returns (KnomosisBridge) {
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-bold-fee-split-test"),
                attestor: address(0xA11CE),
                disputeVerifier: address(0xDEAD),
                sequencerStake: address(0xBEEF),
                migration: address(0),
                disputeWindowBlocks: 100,
                maxRedemptionWindowBlocks: 50,
                maxAttestationStaleBlocks: 200,
                cooldownBlocks: 50,
                tvlCap: type(uint256).max,
                minFeeBps: 0,
                maxFeeBps: 5000,
                weiPerBudgetUnitEth: 1,
                weiPerBudgetUnitBold: 1,
                boldTokenAddress: boldAddr,
                boldTvlCap: type(uint256).max,
                boldCircuitBreaker: BOLD_BREAKER,
                boldAdmin: BOLD_ADMIN,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 0,
                ammDisasterRecovery: AMM_DR,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice Mint `amount` BOLD to `user` and approve `bridge` for it.
    function _mintApprove(KnomosisBridge bridge, address user, uint256 amount) internal {
        MockBold(BOLD).mint(user, amount);
        vm.prank(user);
        MockBold(BOLD).approve(address(bridge), amount);
    }

    // ------------------------------------------------------------------
    // Shared assertion helper
    // ------------------------------------------------------------------

    /// @notice Deposit `amount` BOLD at `feeBps` as `user`, asserting the
    ///         emitted `DepositWithFeeInitiated` matches the `FeeSplitMath`
    ///         reference exactly, that TVL grows by the full deposit, that
    ///         the per-depositor nonce increments, and that the bridge
    ///         actually received the full BOLD (no fee-on-transfer skim).
    function _depositAndCheck(KnomosisBridge bridge, address user, uint256 amount, uint16 feeBps)
        internal
        returns (uint256 userAmount, uint256 poolAmount, uint64 budgetGrant)
    {
        (userAmount, poolAmount, budgetGrant) =
            FeeSplitMath.split(amount, feeBps, bridge.weiPerBudgetUnitBold());

        uint64 nonce = bridge.depositNonce(user);
        // AMM-disabled suite: ammSeedAmount is 0 (freePoolAmount == poolAmount).
        bytes32 expectedHash = FeeSplitMath.receiptHash(
            bridge.deploymentId(), user, RESOURCE_BOLD, BOLD, userAmount, poolAmount, 0, budgetGrant, nonce
        );

        uint256 tvlBefore = bridge.totalLockedValue();
        uint256 bridgeBalBefore = MockBold(BOLD).balanceOf(address(bridge));

        _mintApprove(bridge, user, amount);

        vm.recordLogs();
        vm.prank(user);
        bridge.depositBoldWithFee(amount, feeBps);

        (
            uint256 u,
            uint256 p,
            uint64 g,
            uint64 n,
            bytes32 rh,
            address sender,
            uint64 rid,
            address tok
        ) = _findEvent(vm.getRecordedLogs());

        // Event field equality against the reference computation.
        assertEq(sender, user, "event sender");
        assertEq(rid, RESOURCE_BOLD, "event resourceId == BOLD");
        assertEq(tok, BOLD, "event token == BOLD address");
        assertEq(u, userAmount, "event userAmount");
        assertEq(p, poolAmount, "event poolAmount");
        assertEq(g, budgetGrant, "event budgetGrant");
        assertEq(n, nonce, "event depositorNonce");
        assertEq(rh, expectedHash, "event receiptHash");

        // Conservation + accounting invariants on the live contract.
        assertEq(userAmount + poolAmount, amount, "split must conserve amount");
        assertEq(bridge.totalLockedValue(), tvlBefore + amount, "TVL grows by full deposit");
        assertEq(bridge.depositNonce(user), nonce + 1, "nonce increments");
        assertEq(
            MockBold(BOLD).balanceOf(address(bridge)),
            bridgeBalBefore + amount,
            "bridge received the full BOLD amount"
        );
    }

    // ------------------------------------------------------------------
    // GP.5.4 — constant pins
    // ------------------------------------------------------------------

    /// @notice Pin the BOLD constitutional constants against the local
    ///         mirror + the documented values, and confirm `boldEnabled`
    ///         reflects the constructor's opt-in.
    function test_boldConstants_pinned() public {
        KnomosisBridge bridge = _defaultBold();
        assertEq(bridge.BOLD_TOKEN_ADDRESS(), BOLD, "BOLD_TOKEN_ADDRESS pin");
        assertEq(bridge.BOLD_TOKEN_ADDRESS(), 0x6440f144b7e50D6a8439336510312d2F54beB01D, "BOLD address literal");
        assertEq(bridge.RESOURCE_ID_BOLD(), RESOURCE_BOLD, "RESOURCE_ID_BOLD");
        assertEq(bridge.RESOURCE_ID_BOLD(), 1, "RESOURCE_ID_BOLD == 1");
        assertEq(
            keccak256(bytes(bridge.EXPECTED_BOLD_SYMBOL())),
            keccak256(bytes("BOLD")),
            "EXPECTED_BOLD_SYMBOL"
        );
        assertTrue(bridge.boldEnabled(), "boldEnabled true for a BOLD deployment");
    }

    function test_constructor_pins_boldImmutables() public {
        KnomosisBridge bridge = _deployBold(25, 1234, 777, type(uint256).max);
        assertEq(bridge.weiPerBudgetUnitBold(), 777, "weiPerBudgetUnitBold pinned");
        assertTrue(bridge.boldEnabled(), "boldEnabled");
        // The ETH-leg immutables are independent and still pinned.
        assertEq(bridge.minFeeBps(), 25);
        assertEq(bridge.maxFeeBps(), 1234);
        assertEq(bridge.weiPerBudgetUnitEth(), 1);
    }

    // ------------------------------------------------------------------
    // GP.5.4.c — happy-path mirror of GP.5.1.f
    // ------------------------------------------------------------------

    function test_zeroFee_pureDeposit() public {
        KnomosisBridge bridge = _defaultBold();
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 1 ether, 0);
        assertEq(p, 0, "no pool credit at zero fee");
        assertEq(u, 1 ether, "full amount to user");
        assertEq(g, 0, "no budget grant at zero fee");
    }

    function test_minFee_smallestPool() public {
        KnomosisBridge bridge = _deployBold(50, 5000, 1, type(uint256).max);
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 1_000_000, 50);
        assertEq(p, 5000, "0.5% of 1e6");
        assertEq(u, 995_000, "remainder to user");
        assertEq(g, 5000, "budget == poolAmount at rate 1");
    }

    function test_maxFee_largestPool() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);
        (uint256 u, uint256 p,) = _depositAndCheck(bridge, alice, 100, 5000);
        assertEq(p, 50, "50% of 100");
        assertEq(u, 50, "exact half to user");
    }

    function test_tinyAmount_roundsToUser() public {
        KnomosisBridge bridge = _defaultBold();
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 1, 100);
        assertEq(p, 0, "pool rounds to zero");
        assertEq(u, 1, "1 wei to user");
        assertEq(g, 0, "budget rounds to zero");
    }

    function test_rateOne_budgetEqualsPool() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);
        (, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 10_000, 100);
        assertEq(p, 100, "1% of 1e4");
        assertEq(g, 100, "budget == poolAmount at rate 1");
    }

    function test_rateTrillion_budgetDivides() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1_000_000_000_000, type(uint256).max);
        // poolAmount = 50% of 6e12 = 3e12; budget = 3e12 / 1e12 = 3.
        (, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 6_000_000_000_000, 5000);
        assertEq(p, 3_000_000_000_000, "half of 6e12");
        assertEq(g, 3, "3e12 / 1e12");
    }

    function test_budgetClamp_doesNotRevert() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 10 ether, 5000);
        assertEq(p, 5 ether, "half of 10 BOLD");
        assertEq(u, 5 ether, "half to user");
        assertEq(g, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "budget clamped at cap");
    }

    function test_budgetClamp_exactBoundary_notClamped() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);
        // poolAmount = 50% of 2e12 = 1e12; rate 1 -> rawBudget = 1e12 == cap.
        (, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 2_000_000_000_000, 5000);
        assertEq(p, 1_000_000_000_000, "half of 2e12");
        assertEq(g, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "exact boundary, not clamped");
    }

    function test_budgetClamp_oneAboveBoundary_clamped() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);
        (, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 2_000_000_020_000, 5000);
        assertEq(p, 1_000_000_010_000, "half of 2e12 + 20000");
        assertEq(g, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "one above boundary, clamped");
    }

    function test_residue_favoursUser() public {
        // amount = 12345, feeBps = 333 -> poolAmount = floor(411.0885) = 411.
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);
        (uint256 u, uint256 p,) = _depositAndCheck(bridge, alice, 12_345, 333);
        assertEq(p, 411, "floor(12345 * 333 / 10000)");
        assertEq(u, 11_934, "residue to user");
    }

    function test_feeJustBelowMax() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);
        (, uint256 p,) = _depositAndCheck(bridge, alice, 1_000_000, 4999);
        assertEq(p, 499_900, "floor(1e6 * 4999 / 10000)");
    }

    function test_singleAllowedFee_minEqualsMax() public {
        KnomosisBridge bridge = _deployBold(250, 250, 1, type(uint256).max);
        (, uint256 p,) = _depositAndCheck(bridge, alice, 1_000_000, 250);
        assertEq(p, 25_000, "2.5% of 1e6");
    }

    function test_nonce_incrementsAcrossDeposits() public {
        KnomosisBridge bridge = _defaultBold();
        assertEq(bridge.depositNonce(alice), 0);
        _depositAndCheck(bridge, alice, 1 ether, 100);
        assertEq(bridge.depositNonce(alice), 1);
        _depositAndCheck(bridge, alice, 2 ether, 200);
        assertEq(bridge.depositNonce(alice), 2);
    }

    function test_independentNonces_perDepositor() public {
        KnomosisBridge bridge = _defaultBold();
        _depositAndCheck(bridge, alice, 1 ether, 100);
        _depositAndCheck(bridge, alice, 1 ether, 100);
        assertEq(bridge.depositNonce(bob), 0);
        _depositAndCheck(bridge, bob, 1 ether, 100);
        assertEq(bridge.depositNonce(bob), 1);
        assertEq(bridge.depositNonce(alice), 2);
    }

    function test_tvl_accumulatesAcrossDeposits() public {
        KnomosisBridge bridge = _defaultBold();
        _depositAndCheck(bridge, alice, 3 ether, 100);
        _depositAndCheck(bridge, bob, 5 ether, 4000);
        assertEq(bridge.totalLockedValue(), 8 ether, "TVL = sum of full deposits");
    }

    function test_differentFee_distinctReceiptHash() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);

        _mintApprove(bridge, alice, 1_000_000);
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositBoldWithFee(1_000_000, 100);
        (,,,, bytes32 hash1,,,) = _findEvent(vm.getRecordedLogs());

        _mintApprove(bridge, alice, 1_000_000);
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositBoldWithFee(1_000_000, 200);
        (,,,, bytes32 hash2,,,) = _findEvent(vm.getRecordedLogs());

        assertTrue(hash1 != hash2, "different fee -> different receiptHash");
    }

    function test_replayResistance_nonceBinding() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);

        _mintApprove(bridge, alice, 1 ether);
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 100);
        (,,, uint64 n1, bytes32 h1,,,) = _findEvent(vm.getRecordedLogs());

        _mintApprove(bridge, alice, 1 ether);
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 100);
        (,,, uint64 n2, bytes32 h2,,,) = _findEvent(vm.getRecordedLogs());

        assertEq(n1, 0, "first deposit uses nonce 0");
        assertEq(n2, 1, "second deposit uses nonce 1");
        assertTrue(h1 != h2, "identical deposits at different nonces must hash differently");
    }

    function test_replayResistance_deploymentBinding() public {
        KnomosisBridge bridgeA = _deployBold(0, 5000, 1, type(uint256).max);
        KnomosisBridge bridgeB = _deployBold(0, 5000, 1, type(uint256).max);
        assertTrue(
            bridgeA.deploymentId() != bridgeB.deploymentId(),
            "two deployments have distinct deploymentIds"
        );

        _mintApprove(bridgeA, alice, 1 ether);
        vm.recordLogs();
        vm.prank(alice);
        bridgeA.depositBoldWithFee(1 ether, 100);
        (,,, uint64 na, bytes32 hA,,,) = _findEvent(vm.getRecordedLogs());

        _mintApprove(bridgeB, alice, 1 ether);
        vm.recordLogs();
        vm.prank(alice);
        bridgeB.depositBoldWithFee(1 ether, 100);
        (,,, uint64 nb, bytes32 hB,,,) = _findEvent(vm.getRecordedLogs());

        assertEq(na, 0, "bridgeA deposit nonce 0");
        assertEq(nb, 0, "bridgeB deposit nonce 0");
        assertTrue(hA != hB, "same deposit on different deployments must hash differently");
    }

    function test_realisticRate_boldCalibration() public {
        // A realistic BOLD deployment: max fee 10%, rate 3e15 BOLD-wei per
        // budget unit (the plan's ~$0.003-of-BOLD-per-unit calibration).
        KnomosisBridge bridge = _deployBold(0, 1000, 3_000_000_000_000_000, type(uint256).max);
        // 1000 BOLD deposit at 10% -> pool 100 BOLD = 1e20 BOLD-wei.
        // budget = 1e20 / 3e15 = 33333.
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 1000 ether, 1000);
        assertEq(p, 100 ether, "10% of 1000 BOLD");
        assertEq(u, 900 ether, "90% to user");
        assertEq(g, 33_333, "1e20 / 3e15");
    }

    function test_rate_nearUint64Max() public {
        uint64 hugeRate = type(uint64).max; // ~1.8447e19
        KnomosisBridge bridge = _deployBold(0, 5000, hugeRate, type(uint256).max);
        // Small deposit: pool credit (0.5 BOLD = 5e17) < rate -> budget 0.
        (, uint256 p1, uint64 g1) = _depositAndCheck(bridge, alice, 1 ether, 5000);
        assertEq(p1, 0.5 ether, "half to pool");
        assertEq(g1, 0, "budget rounds to zero when pool < rate");
        // Large deposit: pool credit (20 BOLD = 2e19) >= rate -> budget 1.
        (, uint256 p2, uint64 g2) = _depositAndCheck(bridge, bob, 40 ether, 5000);
        assertEq(p2, 20 ether, "half to pool");
        assertEq(g2, 1, "budget = floor(2e19 / uint64max) = 1");
    }

    function test_gas_depositBoldWithFee() public {
        // Lightweight gas-regression smoke test for the BOLD entry point.
        // The BOLD path costs more than the ETH path (an ERC-20
        // transferFrom + two balanceOf reads); a generous ceiling catches
        // gross regressions without being brittle to optimizer drift.
        KnomosisBridge bridge = _deployBold(0, 5000, 1_000_000_000, type(uint256).max);
        _mintApprove(bridge, alice, 1 ether);
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        bridge.depositBoldWithFee(1 ether, 100);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("depositBoldWithFee gas (first deposit, cold)", used);
        assertLt(used, 200_000, "depositBoldWithFee gas regression");
    }

    // ------------------------------------------------------------------
    // GP.5.4 — cross-leg calibration parity
    // ------------------------------------------------------------------

    function test_calibrationParity_equalBudgetAtCalibratedRates() public {
        // ETH rate 1e12, BOLD rate 3e15 (ETH ~ $3000, BOLD ~ $1; 1 budget
        // unit ~ same USD on either leg).  A pool credit 3000x larger on
        // the BOLD leg therefore yields the same budget grant.
        KnomosisBridge bridge =
            _deploy(0, 5000, 1_000_000_000_000, 3_000_000_000_000_000, BOLD, type(uint256).max);

        // ETH: deposit 2e12 wei at 50% -> pool 1e12 -> budget 1.
        vm.deal(alice, 2_000_000_000_000);
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: 2_000_000_000_000}(5000);
        (, uint256 pEth, uint64 gEth,,,,,) = _findEvent(vm.getRecordedLogs());

        // BOLD: deposit 6e15 BOLD-wei at 50% -> pool 3e15 -> budget 1.
        _mintApprove(bridge, bob, 6_000_000_000_000_000);
        vm.recordLogs();
        vm.prank(bob);
        bridge.depositBoldWithFee(6_000_000_000_000_000, 5000);
        (, uint256 pBold, uint64 gBold,,,,,) = _findEvent(vm.getRecordedLogs());

        assertEq(gEth, 1, "ETH-leg budget == 1");
        assertEq(gBold, gEth, "calibrated rates -> equal budget grant");
        assertEq(pBold, 3000 * pEth, "BOLD pool is 3000x the ETH pool");
    }

    // ------------------------------------------------------------------
    // GP.5.4.c — revert / error cases (mirror of GP.5.1.g)
    // ------------------------------------------------------------------

    function test_revert_zeroDeposit() public {
        KnomosisBridge bridge = _defaultBold();
        vm.expectRevert(KnomosisBridge.ZeroDeposit.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(0, 0);
    }

    function test_revert_zeroDeposit_takesPrecedenceOverFeeCheck() public {
        KnomosisBridge bridge = _deployBold(100, 5000, 1, type(uint256).max);
        vm.expectRevert(KnomosisBridge.ZeroDeposit.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(0, 200);
    }

    function test_revert_feeBelowMin() public {
        KnomosisBridge bridge = _deployBold(100, 5000, 1, type(uint256).max);
        _mintApprove(bridge, alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsBelowMin.selector, uint16(99)));
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 99);
    }

    function test_revert_feeAboveMax() public {
        KnomosisBridge bridge = _deployBold(0, 1000, 1, type(uint256).max);
        _mintApprove(bridge, alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, uint16(1001)));
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 1001);
    }

    function test_revert_feeAboveMax_outOfBpsRange() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);
        _mintApprove(bridge, alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, uint16(10001)));
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 10001);
    }

    function test_revert_tvlCapReached() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, 1 ether);
        _mintApprove(bridge, alice, 2 ether);
        vm.expectRevert(KnomosisBridge.TvlCapReached.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(2 ether, 100);
    }

    function test_revert_tvlCap_firesOnFullValue_notUserAmount() public {
        KnomosisBridge bridge = _deployBold(0, 5000, 1, 1 ether);
        // 1 BOLD deposit lands (TVL == cap), even at 50% fee.
        _depositAndCheck(bridge, alice, 1 ether, 5000);
        // A further 1-wei deposit pushes TVL over the cap.
        _mintApprove(bridge, bob, 1);
        vm.expectRevert(KnomosisBridge.TvlCapReached.selector);
        vm.prank(bob);
        bridge.depositBoldWithFee(1, 0);
    }

    function test_minEqualsMax_zero_forcesZeroFee() public {
        KnomosisBridge bridge = _deployBold(0, 0, 1, type(uint256).max);
        (uint256 u, uint256 p, uint64 g) = _depositAndCheck(bridge, alice, 1 ether, 0);
        assertEq(p, 0, "forced zero pool");
        assertEq(u, 1 ether, "full amount to user");
        assertEq(g, 0, "no budget");
        _mintApprove(bridge, alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, uint16(1)));
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 1);
    }

    // ------------------------------------------------------------------
    // GP.5.4.c — cross-function integration
    // ------------------------------------------------------------------

    function test_mixedDeposit_sharesNonce() public {
        // depositBoldWithFee and depositETHWithFee share the per-depositor
        // nonce counter, so no two deposits by the same depositor ever
        // reuse a nonce across currencies.
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);
        assertEq(bridge.depositNonce(alice), 0);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(100);
        assertEq(bridge.depositNonce(alice), 1, "ETH deposit consumes nonce 0");

        // BOLD deposit reads nonce 1, advances to 2.
        _depositAndCheck(bridge, alice, 2 ether, 100);
        assertEq(bridge.depositNonce(alice), 2, "BOLD deposit consumes nonce 1");
    }

    function test_revert_circuitBroken_byActivatedMigration() public {
        // depositBoldWithFee carries `circuitOpen`, so an activated
        // migration halts BOLD deposits exactly as it halts depositETH.
        MockActivatedMigration mig = new MockActivatedMigration();
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        KnomosisBridge bridge = new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-bold-fee-split-test"),
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
                weiPerBudgetUnitBold: 1,
                boldTokenAddress: BOLD,
                boldTvlCap: type(uint256).max,
                boldCircuitBreaker: BOLD_BREAKER,
                boldAdmin: BOLD_ADMIN,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 0,
                ammDisasterRecovery: AMM_DR,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
        _mintApprove(bridge, alice, 1 ether);
        vm.expectRevert(KnomosisBridge.MigrationActivated.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 100);
    }

    // ------------------------------------------------------------------
    // GP.5.4 — opt-out (BOLD-disabled) behaviour
    // ------------------------------------------------------------------

    function test_boldDisabled_revertsBoldNotEnabled() public {
        // boldTokenAddress == address(0) opts out; depositBoldWithFee must
        // revert BoldNotEnabled (before touching BOLD at all).
        KnomosisBridge bridge = _deploy(0, 5000, 1, 0, address(0), type(uint256).max);
        assertTrue(!bridge.boldEnabled(), "boldEnabled false on opt-out");
        vm.expectRevert(KnomosisBridge.BoldNotEnabled.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 100);
    }

    function test_boldDisabled_ethStillWorks() public {
        // A BOLD-disabled deployment's ETH fee-split path is unaffected.
        KnomosisBridge bridge = _deploy(0, 5000, 1_000_000_000, 0, address(0), type(uint256).max);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(100);
        assertEq(bridge.totalLockedValue(), 1 ether, "ETH deposit lands on a BOLD-disabled bridge");
    }

    function test_boldNotEnabled_takesPrecedence() public {
        // The boldEnabled gate fires before the zero-amount / fee-range
        // guards: a disabled deployment reverts BoldNotEnabled even for an
        // otherwise-degenerate call.
        KnomosisBridge bridge = _deploy(0, 5000, 1, 0, address(0), type(uint256).max);
        vm.expectRevert(KnomosisBridge.BoldNotEnabled.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(0, 0);
    }

    // ------------------------------------------------------------------
    // GP.5.4.a — constructor BOLD-authenticity guards
    // ------------------------------------------------------------------

    function test_revert_constructor_boldAddressMismatch() public {
        // On MAINNET (chainid 1) the canonical BOLD_TOKEN_ADDRESS pin is
        // UNCONDITIONAL: any other non-zero boldTokenAddress reverts.  The
        // chain-conditional relaxation only applies off-mainnet (see the
        // companion below), so force the mainnet path here.
        vm.chainId(1);
        address wrong = address(0x1234);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.BoldTokenAddressMismatch.selector, wrong));
        _deploy(0, 5000, 1, 1, wrong, type(uint256).max);
    }

    /// @notice The chain-conditional relaxation (GP.5.4 §13.6 amendment): on
    ///         a NON-mainnet chain (here Sepolia, 11155111) there is no
    ///         canonical mainnet BOLD, so the operator supplies a chain-native
    ///         BOLD token.  A NON-pin address is ACCEPTED as long as it has
    ///         code and `symbol() == "BOLD"`; the effective token is exposed
    ///         via `boldToken()` and bound to `RESOURCE_ID_BOLD`.  The mainnet
    ///         authenticity pin (asserted above) is unaffected.
    function test_constructor_boldAcceptsOperatorTokenOffMainnet() public {
        vm.chainId(11_155_111);
        MockBold sepoliaBold = new MockBold(); // code present, symbol() == "BOLD"
        address tok = address(sepoliaBold);
        assertTrue(tok != BOLD, "companion must use a NON-pin address");
        KnomosisBridge b = _deploy(0, 5000, 1, 1, tok, type(uint256).max);
        assertTrue(b.boldEnabled(), "BOLD enabled off-mainnet with an operator token");
        assertEq(b.boldToken(), tok, "effective boldToken is the operator-supplied token");
        assertEq(b.resourceToken(RESOURCE_BOLD), tok, "BOLD resource bound to the operator token");
    }

    /// @notice The mainnet ACCEPT branch: at chainid 1 the canonical
    ///         BOLD_TOKEN_ADDRESS pin is REQUIRED, and a construction WITH the
    ///         pinned token succeeds.  The effective `boldToken` IS the pin, so
    ///         every runtime BOLD path on mainnet is byte-identical to the
    ///         pre-amendment contract.  (`setUp()` already etched a conformant
    ///         MockBold at the pinned address.)
    function test_constructor_boldAcceptsPinnedTokenOnMainnet() public {
        vm.chainId(1);
        KnomosisBridge b = _deployBold(0, 5000, 1, type(uint256).max);
        assertTrue(b.boldEnabled(), "BOLD enabled at chainid 1 with the canonical pin");
        assertEq(b.boldToken(), BOLD, "effective boldToken is the canonical pin on mainnet");
        assertEq(b.resourceToken(RESOURCE_BOLD), BOLD, "BOLD resource bound to the pin on mainnet");
    }

    function test_revert_constructor_boldSymbolMismatch() public {
        // BOLD address pin passes, but symbol() != "BOLD".
        WrongSymbolBold impl = new WrongSymbolBold();
        vm.etch(BOLD, address(impl).code);
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.BoldTokenSymbolMismatch.selector, "NOTBOLD")
        );
        _deployBold(0, 5000, 1, type(uint256).max);
    }

    function test_revert_constructor_boldSymbolReverts() public {
        // symbol() reverts -> caught -> BoldTokenSymbolUnavailable.
        RevertingSymbolBold impl = new RevertingSymbolBold();
        vm.etch(BOLD, address(impl).code);
        vm.expectRevert(KnomosisBridge.BoldTokenSymbolUnavailable.selector);
        _deployBold(0, 5000, 1, type(uint256).max);
    }

    function test_revert_constructor_boldNoCodeAtPin() public {
        // No code at the pinned address -> symbol() call to empty code
        // reverts -> caught -> BoldTokenSymbolUnavailable.
        vm.etch(BOLD, hex"");
        vm.expectRevert(KnomosisBridge.BoldTokenSymbolUnavailable.selector);
        _deployBold(0, 5000, 1, type(uint256).max);
    }

    function test_revert_constructor_boldWeiPerBudgetUnitZero() public {
        // BOLD enabled but BOLD-leg rate 0 -> WeiPerBudgetUnitTooSmall(0).
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.WeiPerBudgetUnitTooSmall.selector, uint64(0))
        );
        _deployBold(0, 5000, 0, type(uint256).max);
    }

    function test_constructor_disabled_ignoresBoldRate() public {
        // BOLD disabled: weiPerBudgetUnitBold is unconstrained (0 is fine).
        KnomosisBridge bridge = _deploy(0, 5000, 1, 0, address(0), type(uint256).max);
        assertEq(bridge.weiPerBudgetUnitBold(), 0, "rate stored verbatim when disabled");
        assertTrue(!bridge.boldEnabled());
    }

    // ------------------------------------------------------------------
    // GP.5.4 — RESOURCE_ID_BOLD reservation + auto-binding
    // ------------------------------------------------------------------

    function test_boldAutoBindsResourceId1() public {
        // BOLD enabled + empty resource map: the constructor auto-binds
        // (RESOURCE_ID_BOLD -> BOLD_TOKEN_ADDRESS), so BOLD withdrawals
        // resolve to the canonical token with no deployer action.
        KnomosisBridge bridge = _defaultBold();
        assertTrue(bridge.boldEnabled(), "boldEnabled");
        assertEq(bridge.resourceToken(RESOURCE_BOLD), BOLD, "resourceId 1 auto-bound to BOLD");
    }

    function test_boldDisabled_resourceId1_unbound() public {
        // BOLD disabled: no auto-binding; resourceId 1 is an ordinary
        // (here unregistered) slot.
        KnomosisBridge bridge = _deploy(0, 5000, 1, 0, address(0), type(uint256).max);
        assertEq(bridge.resourceToken(RESOURCE_BOLD), address(0), "no auto-bind when BOLD disabled");
    }

    function test_revert_constructor_boldResourceId1Reserved_nonBoldToken() public {
        // BOLD enabled + deployer tries to map resourceId 1 to a NON-BOLD
        // token: reserved -> revert (the id is auto-bound to BOLD).
        uint64[] memory rids = new uint64[](1);
        rids[0] = 1;
        address[] memory toks = new address[](1);
        toks[0] = address(0xC0FFEE);
        vm.expectRevert(KnomosisBridge.BoldResourceReserved.selector);
        _deployWithResources(BOLD, rids, toks);
    }

    function test_revert_constructor_boldResourceId1Reserved_evenBoldToken() public {
        // BOLD enabled + deployer tries to map resourceId 1 to BOLD
        // itself: still reserved (the id is auto-bound; the deployer must
        // not register it) -> revert.
        uint64[] memory rids = new uint64[](1);
        rids[0] = 1;
        address[] memory toks = new address[](1);
        toks[0] = BOLD;
        vm.expectRevert(KnomosisBridge.BoldResourceReserved.selector);
        _deployWithResources(BOLD, rids, toks);
    }

    function test_revert_constructor_boldTokenAtOtherResourceId() public {
        // BOLD enabled + deployer tries to register BOLD at a DIFFERENT
        // resourceId: reserved -> revert (BOLD lives only at id 1, so two
        // ids can never map to BOLD).
        uint64[] memory rids = new uint64[](1);
        rids[0] = 5;
        address[] memory toks = new address[](1);
        toks[0] = BOLD;
        vm.expectRevert(KnomosisBridge.BoldResourceReserved.selector);
        _deployWithResources(BOLD, rids, toks);
    }

    function test_boldEnabled_otherResourcesStillRegister() public {
        // BOLD enabled + deployer registers an unrelated ERC-20 at id 7:
        // accepted (only id 1 / BOLD are reserved), and BOLD is still
        // auto-bound at id 1.
        uint64[] memory rids = new uint64[](1);
        rids[0] = 7;
        address[] memory toks = new address[](1);
        toks[0] = address(0xC0FFEE);
        KnomosisBridge bridge = _deployWithResources(BOLD, rids, toks);
        assertEq(bridge.resourceToken(7), address(0xC0FFEE), "other ERC-20 registers");
        assertEq(bridge.resourceToken(RESOURCE_BOLD), BOLD, "BOLD auto-bound at id 1");
    }

    function test_constructor_disabledBold_resourceId1_anyToken_ok() public {
        // BOLD disabled: resourceId 1 is an ordinary ERC-20 slot, so the
        // reservation is inert and any non-zero token is accepted.
        uint64[] memory rids = new uint64[](1);
        rids[0] = 1;
        address[] memory toks = new address[](1);
        toks[0] = address(0xC0FFEE);
        KnomosisBridge bridge = _deployWithResources(address(0), rids, toks);
        assertTrue(!bridge.boldEnabled(), "boldEnabled false on opt-out");
        assertEq(bridge.resourceToken(RESOURCE_BOLD), address(0xC0FFEE), "rid 1 = chosen token when disabled");
    }

    function test_revert_depositERC20_rejectsBoldWhenEnabled() public {
        // The BOLD auto-bind (installed so `withdrawWithProof` can resolve
        // the payout token) also satisfies `depositERC20`'s registration /
        // mapping checks — which would otherwise open a fee-bypassing
        // legacy deposit path for BOLD (emitting `DepositInitiated` with no
        // pool credit / budget grant).  The guard closes it: depositERC20
        // for RESOURCE_ID_BOLD reverts on a BOLD-enabled deployment, so
        // every BOLD deposit flows through `depositBoldWithFee`.
        KnomosisBridge bridge = _defaultBold();
        _mintApprove(bridge, alice, 1 ether);
        vm.expectRevert(KnomosisBridge.BoldDepositViaFeeSplitOnly.selector);
        vm.prank(alice);
        bridge.depositERC20(RESOURCE_BOLD, MockBold(BOLD), 1 ether);
    }

    function test_depositERC20_resourceId1_okWhenBoldDisabled() public {
        // The guard is gated on `boldEnabled`: when BOLD is disabled,
        // resourceId 1 is an ordinary ERC-20 slot and depositERC20 to it
        // works normally (the fix does not regress the BOLD-off case).
        MockBold genericTok = new MockBold();
        uint64[] memory rids = new uint64[](1);
        rids[0] = RESOURCE_BOLD;
        address[] memory toks = new address[](1);
        toks[0] = address(genericTok);
        KnomosisBridge bridge = _deployWithResources(address(0), rids, toks);
        assertTrue(!bridge.boldEnabled(), "BOLD disabled");

        genericTok.mint(alice, 5 ether);
        vm.prank(alice);
        genericTok.approve(address(bridge), 5 ether);
        vm.prank(alice);
        bridge.depositERC20(RESOURCE_BOLD, genericTok, 5 ether);
        assertEq(
            genericTok.balanceOf(address(bridge)),
            5 ether,
            "generic ERC-20 at id 1 deposits normally when BOLD is off"
        );
    }

    // ------------------------------------------------------------------
    // GP.5.4.d — non-conformant BOLD token reverts
    // ------------------------------------------------------------------

    function test_revert_feeOnTransferBold() public {
        // A fee-on-transfer BOLD (1-wei skim) passes the symbol check but
        // trips the deposit's balance-delta guard.
        FeeOnTransferBold impl = new FeeOnTransferBold();
        vm.etch(BOLD, address(impl).code);
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);

        _mintApprove(bridge, alice, 100);
        // Deposit 100: bridge expects 100 received but only 99 arrives.
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.BoldTransferAmountMismatch.selector, uint256(100), uint256(99)
            )
        );
        vm.prank(alice);
        bridge.depositBoldWithFee(100, 100);
    }

    function test_revert_returnsFalseBold() public {
        // transferFrom returns false without moving tokens -> SafeERC20
        // reverts (the deposit fails closed; no phantom credit).
        ReturnsFalseBold impl = new ReturnsFalseBold();
        vm.etch(BOLD, address(impl).code);
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);

        _mintApprove(bridge, alice, 1 ether);
        // SafeERC20 reverts with SafeERC20FailedOperation; any revert is
        // sufficient -- the deposit must not succeed.
        vm.expectRevert();
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 100);

        // No state changed: TVL still zero, nonce unchanged.
        assertEq(bridge.totalLockedValue(), 0, "no TVL on failed transfer");
        assertEq(bridge.depositNonce(alice), 0, "no nonce bump on failed transfer");
    }

    function test_revert_revokedAllowance() public {
        // Mint but do NOT approve: transferFrom reverts on insufficient
        // allowance, so the whole deposit reverts.
        KnomosisBridge bridge = _defaultBold();
        MockBold(BOLD).mint(alice, 1 ether);
        vm.expectRevert();
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 100);
        assertEq(bridge.totalLockedValue(), 0, "no TVL on missing allowance");
    }

    function test_revert_insufficientBalance() public {
        // Approve but never mint: transferFrom reverts on insufficient
        // balance.
        KnomosisBridge bridge = _defaultBold();
        vm.prank(alice);
        MockBold(BOLD).approve(address(bridge), 1 ether);
        vm.expectRevert();
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 100);
        assertEq(bridge.totalLockedValue(), 0, "no TVL on insufficient balance");
    }

    function test_feeOnTransfer_isolatedToBold_ethUnaffected() public {
        // Even with a fee-on-transfer BOLD etched, the ETH leg is
        // independent and still works (the BOLD failure is contained).
        FeeOnTransferBold impl = new FeeOnTransferBold();
        vm.etch(BOLD, address(impl).code);
        KnomosisBridge bridge = _deployBold(0, 5000, 1, type(uint256).max);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(100);
        assertEq(bridge.totalLockedValue(), 1 ether, "ETH leg unaffected by BOLD token quirk");
    }

    // ------------------------------------------------------------------
    // GP.5.4 — end-to-end deposit -> escrow -> withdraw lifecycle
    // ------------------------------------------------------------------

    /// @notice Full BOLD lifecycle: a BOLD fee-split deposit escrows BOLD
    ///         in the bridge, the sequencer's attested state root carries
    ///         a BOLD withdrawal leaf, and after finalisation
    ///         `withdrawWithProof` pays the recipient the BOLD out of the
    ///         auto-bound `(RESOURCE_ID_BOLD -> BOLD_TOKEN_ADDRESS)` slot.
    ///         Proves the withdrawal side resolves BOLD correctly (closing
    ///         the deposit/withdraw symmetry) and that a redeemed leaf
    ///         cannot be replayed.
    function test_e2e_boldDepositThenWithdraw() public {
        KnomosisBridge bridge = _deployKeyedAttestorBold(0);
        // The auto-bound resource map is what makes BOLD withdrawals work.
        assertEq(bridge.resourceToken(RESOURCE_BOLD), BOLD, "BOLD auto-bound at id 1");

        // (1) Deposit: alice bridges 1 BOLD at zero fee -> 1 BOLD escrowed.
        _mintApprove(bridge, alice, 1 ether);
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 0);
        assertEq(MockBold(BOLD).balanceOf(address(bridge)), 1 ether, "bridge escrowed 1 BOLD");
        assertEq(bridge.totalLockedValue(), 1 ether, "TVL == deposit");

        // (2) Build a BOLD withdrawal leaf (resourceId 1) for `recipient`,
        //     with the canonical all-empty (default-sibling) proof at SMT
        //     index 0, and compute its root.
        address recipient = address(0xBEEFCAFE);
        uint64 wAmount = 400_000;
        uint64 idx = 0;
        bytes memory leaf = _encodeWithdrawalLeaf(RESOURCE_BOLD, recipient, wAmount, idx);
        bytes[] memory siblings = SmtVerifier.emptyProofSiblings();
        bytes32 root = SmtVerifier.recomputeRoot(uint256(idx), leaf, siblings);

        // (3) Attestor submits the state root (any caller; the signature is
        //     what's checked), then the dispute window elapses.
        uint64 atLogIndexHigh = 1;
        bridge.submitStateRoot(root, atLogIndexHigh, _signStateRoot(bridge, root, atLogIndexHigh));
        vm.roll(block.number + 100); // == disputeWindowBlocks
        assertTrue(bridge.isStateRootFinalised(atLogIndexHigh), "state root finalised");

        // (4) Redeem: recipient receives `wAmount` BOLD; bridge + TVL debit.
        bytes memory proofBlob = _encodeWithdrawalProof(leaf, idx, siblings);
        assertEq(MockBold(BOLD).balanceOf(recipient), 0, "recipient starts with no BOLD");
        bridge.withdrawWithProof(atLogIndexHigh, proofBlob, leaf);
        assertEq(MockBold(BOLD).balanceOf(recipient), wAmount, "recipient redeemed BOLD");
        assertEq(
            MockBold(BOLD).balanceOf(address(bridge)),
            1 ether - wAmount,
            "bridge BOLD debited by withdrawal"
        );
        assertEq(bridge.totalLockedValue(), 1 ether - wAmount, "TVL debited by withdrawal");

        // (5) Replay of the same leaf is rejected.
        vm.expectRevert(KnomosisBridge.AlreadyRedeemed.selector);
        bridge.withdrawWithProof(atLogIndexHigh, proofBlob, leaf);
    }

    /// @notice Deploy a BOLD-enabled bridge with a KEYED attestor (so the
    ///         e2e tests can sign state-root attestations), an empty resource
    ///         map (BOLD auto-binds at id 1), and a caller-chosen AMM seed
    ///         ratio (`0` for the AMM-disabled lifecycle test; non-zero for
    ///         the GP.11.2 reserve-survives-withdrawal test).
    function _deployKeyedAttestorBold(uint16 ammSeedRatioBps) internal returns (KnomosisBridge) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-bold-e2e"),
                attestor: vm.addr(ATTESTOR_PK),
                disputeVerifier: address(0xDEAD),
                sequencerStake: address(0xBEEF),
                migration: address(0),
                disputeWindowBlocks: 100,
                maxRedemptionWindowBlocks: 50,
                maxAttestationStaleBlocks: 200,
                cooldownBlocks: 50,
                tvlCap: type(uint256).max,
                minFeeBps: 0,
                maxFeeBps: 5000,
                weiPerBudgetUnitEth: 1,
                weiPerBudgetUnitBold: 1,
                boldTokenAddress: BOLD,
                boldTvlCap: type(uint256).max,
                boldCircuitBreaker: BOLD_BREAKER,
                boldAdmin: BOLD_ADMIN,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: ammSeedRatioBps,
                ammDisasterRecovery: AMM_DR,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice GP.11.2 — the AMM reserve survives a withdrawal.  An
    ///         AMM-enabled (80% ratio) BOLD fee-split deposit seeds
    ///         `ammReserveBold`; a recipient then withdraws ALL non-seed
    ///         value (`amount - seed`), draining TVL down to exactly the
    ///         seed's backing.  `ammReserveBold <= boldTotalLockedValue <=
    ///         totalLockedValue` holds throughout, with the seed as the
    ///         irreducible TVL floor.  This exercises the deposit/withdraw
    ///         interaction the deposit-only invariant suite in
    ///         `AmmDepositSeeding.t.sol` could not reach (it needs the
    ///         state-root + SMT-proof machinery that lives here).  Withdrawing
    ///         exactly `amount - seed` models the realistic ceiling: a
    ///         correct L2 never credits the seed's backing to a withdrawing
    ///         actor until the AMM swap/redeem path lands (GP.11.3+).
    function test_e2e_ammReserveSurvivesBoldWithdrawal() public {
        KnomosisBridge bridge = _deployKeyedAttestorBold(8000);

        // Deposit 1 BOLD at 50% fee -> pool 0.5, user 0.5, seed = floor(0.5 * 0.8) = 0.4.
        uint256 amount = 1 ether;
        uint16 feeBps = 5000;
        _mintApprove(bridge, alice, amount);
        vm.prank(alice);
        bridge.depositBoldWithFee(amount, feeBps);

        (, uint256 poolAmount,) = FeeSplitMath.split(amount, feeBps, bridge.weiPerBudgetUnitBold());
        (uint256 seed,) = FeeSplitMath.ammSeedSplit(poolAmount, 8000);
        assertGt(seed, 0, "non-trivial seed");
        assertEq(bridge.ammReserveBold(), seed, "BOLD reserve seeded on deposit");
        assertEq(bridge.totalLockedValue(), amount, "TVL == full deposit");
        assertEq(bridge.boldTotalLockedValue(), amount, "BOLD TVL == full deposit");
        assertLe(bridge.ammReserveBold(), bridge.boldTotalLockedValue(), "reserve <= bold TVL (pre)");

        // Withdraw EVERYTHING except the seed's backing: amount - seed.
        address recipient = address(0xBEEFCAFE);
        // amount (1e18) and seed (< amount) both fit uint64.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 wAmount = uint64(amount - seed);
        uint64 idx = 0;
        bytes memory leaf = _encodeWithdrawalLeaf(RESOURCE_BOLD, recipient, wAmount, idx);
        bytes[] memory siblings = SmtVerifier.emptyProofSiblings();
        bytes32 root = SmtVerifier.recomputeRoot(uint256(idx), leaf, siblings);

        uint64 atLogIndexHigh = 1;
        bridge.submitStateRoot(root, atLogIndexHigh, _signStateRoot(bridge, root, atLogIndexHigh));
        vm.roll(block.number + 100); // == disputeWindowBlocks
        bytes memory proofBlob = _encodeWithdrawalProof(leaf, idx, siblings);
        bridge.withdrawWithProof(atLogIndexHigh, proofBlob, leaf);

        // TVL drained to exactly the seed; the reserve is the irreducible
        // floor and is UNCHANGED by the withdrawal (GP.11.2 never decrements
        // it — that is the GP.11.3 swap/redeem path).
        assertEq(uint256(wAmount), amount - seed, "withdrew all non-seed value");
        assertEq(bridge.totalLockedValue(), seed, "TVL drained to the seed floor");
        assertEq(bridge.boldTotalLockedValue(), seed, "BOLD TVL drained to the seed floor");
        assertEq(bridge.ammReserveBold(), seed, "reserve unchanged by withdrawal");
        assertLe(bridge.ammReserveBold(), bridge.totalLockedValue(), "reserve <= TVL (post-withdraw)");
        assertLe(
            bridge.ammReserveBold(), bridge.boldTotalLockedValue(), "reserve <= bold TVL (post)"
        );
    }

    /// @notice EIP-712 digest for a state-root attestation (mirrors
    ///         `KnomosisBridge.submitStateRoot`).
    function _stateRootDigest(KnomosisBridge bridge, bytes32 root, uint64 idx)
        internal
        view
        returns (bytes32)
    {
        bytes32 ds = KnomosisEip712.domainSeparator(
            "KnomosisBridge", "1", block.chainid, uint256(0), address(bridge)
        );
        bytes32 sh = keccak256(
            abi.encode(
                keccak256("StateRoot(bytes32 root,uint64 logIndexHigh,bytes32 deploymentId)"),
                root,
                uint256(idx),
                bridge.deploymentId()
            )
        );
        return KnomosisEip712.digest(ds, sh);
    }

    /// @notice Sign a state-root attestation with the attestor key.
    function _signStateRoot(KnomosisBridge bridge, bytes32 root, uint64 idx)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, _stateRootDigest(bridge, root, idx));
        return abi.encodePacked(r, s, v);
    }

    /// @notice 8 little-endian bytes of a uint64 (the CBE head value form).
    function _leBytes8(uint64 v) internal pure returns (bytes memory out) {
        out = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            // Extract byte i (LE) by truncating the shifted value.
            // forge-lint: disable-next-line(unsafe-typecast)
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    /// @notice CBE uint: tag 0x00 + 8 LE value bytes.
    function _cbeUint(uint64 v) internal pure returns (bytes memory) {
        return bytes.concat(hex"00", _leBytes8(v));
    }

    /// @notice CBE byte string: tag 0x02 + 8 LE length + payload.
    function _cbeBytes(bytes memory payload) internal pure returns (bytes memory) {
        // payload.length is tiny here (<= 56); the uint64 cast cannot lose.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes.concat(hex"02", _leBytes8(uint64(payload.length)), payload);
    }

    /// @notice CBE array head: tag 0x04 + 8 LE count.
    function _cbeArrayHead(uint64 count) internal pure returns (bytes memory) {
        return bytes.concat(hex"04", _leBytes8(count));
    }

    /// @notice CBE-encode a `PendingWithdrawal` leaf, matching
    ///         `KnomosisBridge._decodePendingWithdrawal`: CBE uint
    ///         resourceId, CBE bytes recipient (20-byte address), CBE uint
    ///         amount, CBE uint l2LogIndex.
    function _encodeWithdrawalLeaf(uint64 resourceId, address recipient, uint64 amount, uint64 l2LogIndex)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            _cbeUint(resourceId),
            _cbeBytes(abi.encodePacked(recipient)),
            _cbeUint(amount),
            _cbeUint(l2LogIndex)
        );
    }

    /// @notice CBE-encode a `WithdrawalProof`, matching
    ///         `KnomosisBridge._decodeWithdrawalProof`: CBE bytes leaf, CBE
    ///         uint index, CBE array of `SMT_HEIGHT` CBE-bytes siblings.
    function _encodeWithdrawalProof(bytes memory leaf, uint64 idx, bytes[] memory siblings)
        internal
        pure
        returns (bytes memory)
    {
        // siblings.length is SMT_HEIGHT (64); the uint64 cast cannot lose.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory out = bytes.concat(_cbeBytes(leaf), _cbeUint(idx), _cbeArrayHead(uint64(siblings.length)));
        for (uint256 i = 0; i < siblings.length; i++) {
            out = bytes.concat(out, _cbeBytes(siblings[i]));
        }
        return out;
    }

    // ------------------------------------------------------------------
    // GP.5.4 — fuzz: conservation + differential against reference
    // ------------------------------------------------------------------

    /// @notice For any admissible `(amount, feeBps)`, the live BOLD path
    ///         emits exactly the `FeeSplitMath` reference split and
    ///         conserves `userAmount + poolAmount == amount`.
    function testFuzz_conservation_and_reference(uint256 amount, uint16 feeBps) public {
        amount = (amount % 1e30) + 1;
        feeBps = uint16(uint256(feeBps) % 5001);
        KnomosisBridge bridge = _deployBold(0, 5000, 1_000_000_000, type(uint256).max);

        (uint256 refUser, uint256 refPool, uint64 refBudget) =
            FeeSplitMath.split(amount, feeBps, bridge.weiPerBudgetUnitBold());

        _mintApprove(bridge, alice, amount);
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositBoldWithFee(amount, feeBps);
        (uint256 u, uint256 p, uint64 g,,,, uint64 rid, address tok) =
            _findEvent(vm.getRecordedLogs());

        assertEq(u + p, amount, "conservation");
        assertEq(u, refUser, "userAmount matches reference");
        assertEq(p, refPool, "poolAmount matches reference");
        assertEq(g, refBudget, "budgetGrant matches reference");
        assertEq(rid, RESOURCE_BOLD, "resourceId == BOLD");
        assertEq(tok, BOLD, "token == BOLD address");
        assertLe(g, FeeSplitMath.MAX_BUDGET_PER_DEPOSIT, "budget within cap");
    }

    /// @notice Differential across the BOLD exchange rate: deploy a fresh
    ///         bridge per run with a fuzzed `weiPerBudgetUnitBold` and
    ///         assert the contract matches the reference (split + hash).
    function testFuzz_differential_acrossRate(uint256 amount, uint16 feeBps, uint64 rate) public {
        amount = (amount % 1e30) + 1;
        feeBps = uint16(uint256(feeBps) % 5001);
        rate = uint64(uint256(rate) % 1e15) + 1;
        KnomosisBridge bridge = _deployBold(0, 5000, rate, type(uint256).max);

        (uint256 refUser, uint256 refPool, uint64 refBudget) =
            FeeSplitMath.split(amount, feeBps, rate);

        _mintApprove(bridge, alice, amount);
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositBoldWithFee(amount, feeBps);
        (uint256 u, uint256 p, uint64 g,, bytes32 hash,,,) = _findEvent(vm.getRecordedLogs());

        assertEq(u, refUser, "userAmount matches reference");
        assertEq(p, refPool, "poolAmount matches reference");
        assertEq(g, refBudget, "budgetGrant matches reference");

        bytes32 refHash = FeeSplitMath.receiptHash(
            bridge.deploymentId(), alice, RESOURCE_BOLD, BOLD, refUser, refPool, 0, refBudget, 0
        );
        assertEq(hash, refHash, "receiptHash matches reference");
    }

    /// @notice A fuzzed out-of-range fee always reverts (never silently
    ///         under/overflows).
    function testFuzz_outOfRangeFee_reverts(uint256 amount, uint16 feeBps) public {
        amount = (amount % 1e30) + 1;
        uint16 maxF = 1000;
        feeBps = uint16(uint256(maxF) + 1 + (uint256(feeBps) % (uint256(type(uint16).max) - maxF)));
        KnomosisBridge bridge = _deployBold(0, maxF, 1, type(uint256).max);
        _mintApprove(bridge, alice, amount);
        vm.expectRevert(abi.encodeWithSelector(KnomosisBridge.FeeBpsAboveMax.selector, feeBps));
        vm.prank(alice);
        bridge.depositBoldWithFee(amount, feeBps);
    }

    // ------------------------------------------------------------------
    // Event-decoding helper
    // ------------------------------------------------------------------

    /// @notice Locate + decode the single `DepositWithFeeInitiated` entry
    ///         in a recorded-log array (skipping the BOLD `Transfer` event,
    ///         which has 3 topics vs. this event's 4).  Reverts if absent.
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
            "DepositWithFeeInitiated(address,uint64,address,uint256,uint256,uint256,uint64,uint64,bytes32)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == sig) {
                sender = address(uint160(uint256(logs[i].topics[1])));
                resourceId = uint64(uint256(logs[i].topics[2]));
                token = address(uint160(uint256(logs[i].topics[3])));
                // GP.11.2: data adds ammSeedAmount (0 in this AMM-disabled
                // suite) between poolAmount and budgetGrant; skipped here.
                (userAmount, poolAmount,, budgetGrant, nonce, receiptHash) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint64, uint64, bytes32));
                return
                    (userAmount, poolAmount, budgetGrant, nonce, receiptHash, sender, resourceId, token);
            }
        }
        revert("DepositWithFeeInitiated not found");
    }
}

/// @notice Minimal migration mock whose `activated()` returns true.
contract MockActivatedMigration {
    function activated() external pure returns (bool) {
        return true;
    }
}
