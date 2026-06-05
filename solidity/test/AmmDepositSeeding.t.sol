// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";
import {MockBold} from "test/utils/MockBold.sol";

/// @title AmmDepositSeedingTest
/// @notice Workstream GP.11.2 — deposit-side seeding of the embedded
///         ETH<->BOLD AMM.  Every fee-split deposit splits its
///         `poolAmount` into an AMM-liquidity seed
///         (`floor(poolAmount * ammSeedRatioBps / 10000)`) and a
///         sequencer-claimable free-pool remainder, growing the matching
///         reserve by the seed.
///
/// @dev    Wire format (plan-literal): the split is carried in the
///         CANONICAL `DepositWithFeeInitiated` event via the GP.11.2
///         `ammSeedAmount` field, and BOUND in the `receiptHash`
///         (`keccak256(abi.encode(deploymentId, sender, resourceId, token,
///         userAmount, poolAmount, ammSeedAmount, budgetGrant, nonce))`).
///         So the L2 reconstructs `freePoolAmount = poolAmount -
///         ammSeedAmount` directly from one event, and a replay with a
///         tampered split is rejected (the receiptHash is sensitive to
///         `ammSeedAmount`, pinned by `test_receiptHash_bindsAmmSeedAmount`).
///
///         The conservation acceptance criterion (GP.11.2.c —
///         `ammSeedAmount + freePoolAmount == poolAmount` for 1000+ fuzz
///         inputs) is pinned by `testFuzz_ethSeed_conservation`,
///         `testFuzz_boldSeed_conservation`, and
///         `testFuzz_seed_conservation_acrossRatios`, plus the stateful
///         `AmmDepositSeedingInvariantTest` (reserve == sum-of-seeds,
///         reserves a subset of TVL).
contract AmmDepositSeedingTest is Test {
    address private alice = address(0xA1);
    address private bob = address(0xB0B);

    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_NATIVE_ETH`.
    uint64 private constant NATIVE_ETH = 0;
    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_BOLD`.
    uint64 private constant BOLD_RID = 1;

    /// @dev Mirror of `KnomosisBridge.BOLD_TOKEN_ADDRESS`.
    address private constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address private constant BOLD_BREAKER = address(0xB12E6B6E);
    address private constant BOLD_ADMIN = address(0xAD814);

    /// @dev Local copy of the canonical contract event for `vm.expectEmit`.
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
        vm.deal(alice, type(uint128).max);
        vm.deal(bob, type(uint128).max);
    }

    // ------------------------------------------------------------------
    // Deployment helpers
    // ------------------------------------------------------------------

    /// @notice Deploy a standalone, BOLD-disabled bridge with a chosen
    ///         `ammSeedRatioBps` and a permissive fee-split config (no TVL
    ///         ceiling) so `depositETHWithFee` works on a fresh deployment.
    function _deploy(uint16 ammSeedRatioBps) internal returns (KnomosisBridge) {
        return _deployWithCap(ammSeedRatioBps, type(uint256).max);
    }

    /// @notice As `_deploy`, but with a caller-chosen global `tvlCap` so
    ///         the cap-revert path can be exercised.
    function _deployWithCap(uint16 ammSeedRatioBps, uint256 tvlCap)
        internal
        returns (KnomosisBridge)
    {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-amm-seeding-test"),
                attestor: address(0xA11CE),
                disputeVerifier: address(0xDEAD),
                sequencerStake: address(0xBEEF),
                migration: address(0),
                disputeWindowBlocks: 100,
                maxRedemptionWindowBlocks: 50,
                maxAttestationStaleBlocks: 200,
                cooldownBlocks: 50,
                tvlCap: tvlCap,
                minFeeBps: 0,
                maxFeeBps: 5000,
                weiPerBudgetUnitEth: 1_000_000_000,
                weiPerBudgetUnitBold: 0,
                boldTokenAddress: address(0),
                boldTvlCap: 0,
                boldCircuitBreaker: address(0),
                boldAdmin: address(0),
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: ammSeedRatioBps,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice Place a fresh conformant `MockBold` at the pinned address.
    function _etchBold() internal {
        MockBold impl = new MockBold();
        vm.etch(BOLD, address(impl).code);
    }

    /// @notice Deploy a BOLD-ENABLED bridge with a chosen seed ratio.
    function _deployBoldEnabled(uint16 ammSeedRatioBps) internal returns (KnomosisBridge) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-amm-seeding-bold-test"),
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
                weiPerBudgetUnitEth: 1_000_000_000,
                weiPerBudgetUnitBold: 1_000_000_000,
                boldTokenAddress: BOLD,
                boldTvlCap: type(uint256).max,
                boldCircuitBreaker: BOLD_BREAKER,
                boldAdmin: BOLD_ADMIN,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: ammSeedRatioBps,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice Mint `amount` BOLD to `user` and approve `bridge`.
    function _mintApprove(KnomosisBridge bridge, address user, uint256 amount) internal {
        MockBold(BOLD).mint(user, amount);
        vm.prank(user);
        MockBold(BOLD).approve(address(bridge), amount);
    }

    /// @notice Locate + decode the single canonical `DepositWithFeeInitiated`
    ///         entry in a recorded-log array.  Reverts if absent.
    function _decodeDepositWithFee(Vm.Log[] memory logs)
        internal
        pure
        returns (
            uint256 userAmount,
            uint256 poolAmount,
            uint256 ammSeedAmount,
            uint64 budgetGrant,
            uint64 nonce,
            bytes32 receiptHash
        )
    {
        bytes32 sig = keccak256(
            "DepositWithFeeInitiated(address,uint64,address,uint256,uint256,uint256,uint64,uint64,bytes32)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == sig) {
                (userAmount, poolAmount, ammSeedAmount, budgetGrant, nonce, receiptHash) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint64, uint64, bytes32));
                return (userAmount, poolAmount, ammSeedAmount, budgetGrant, nonce, receiptHash);
            }
        }
        revert("DepositWithFeeInitiated not found");
    }

    // ------------------------------------------------------------------
    // Core ETH-leg seeding + the canonical event's ammSeedAmount field
    // ------------------------------------------------------------------

    /// @notice A fee-split ETH deposit at a 50% seed ratio seeds exactly
    ///         `floor(poolAmount / 2)` into `ammReserveEth` and emits the
    ///         canonical `DepositWithFeeInitiated` carrying that
    ///         `ammSeedAmount` (with the bound `receiptHash`); the FULL
    ///         deposit is still credited to TVL.
    function test_ethDeposit_seedsReserve_andEventCarriesSplit() public {
        KnomosisBridge bridge = _deploy(5000);

        uint256 value = 1 ether;
        uint16 feeBps = 1000; // 10% -> poolAmount = 0.1 ether
        (uint256 userAmount, uint256 poolAmount, uint64 budgetGrant) =
            FeeSplitMath.split(value, feeBps, bridge.weiPerBudgetUnitEth());
        (uint256 ammSeed, uint256 freePool) = FeeSplitMath.ammSeedSplit(poolAmount, 5000);
        assertGt(ammSeed, 0, "non-trivial seed expected");

        uint64 nonce = bridge.depositNonce(alice);
        bytes32 expectedHash = FeeSplitMath.receiptHash(
            bridge.deploymentId(),
            alice,
            NATIVE_ETH,
            address(0),
            userAmount,
            poolAmount,
            ammSeed,
            budgetGrant,
            nonce
        );

        vm.expectEmit(true, true, true, true, address(bridge));
        emit DepositWithFeeInitiated(
            alice, NATIVE_ETH, address(0), userAmount, poolAmount, ammSeed, budgetGrant, nonce, expectedHash
        );

        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);

        assertEq(bridge.ammReserveEth(), ammSeed, "ETH reserve seeded by floor(poolAmount/2)");
        assertEq(bridge.ammReserveBold(), 0, "BOLD reserve untouched by an ETH deposit");
        assertEq(bridge.totalLockedValue(), value, "TVL credits the FULL deposit");
        assertEq(address(bridge).balance, value, "escrow holds the FULL deposit");
        assertEq(ammSeed + freePool, poolAmount, "conservation: seed + freePool == poolAmount");
    }

    /// @notice At the maximum seed ratio (8000 bps = 80%) the seed is
    ///         exactly `floor(poolAmount * 8000 / 10000)`, and the event +
    ///         reserve agree.
    function test_ethDeposit_seedsReserve_atMaxRatio() public {
        KnomosisBridge bridge = _deploy(8000);

        uint256 value = 5 ether;
        uint16 feeBps = 2500; // 25%
        (, uint256 poolAmount,) = FeeSplitMath.split(value, feeBps, bridge.weiPerBudgetUnitEth());
        (uint256 ammSeed,) = FeeSplitMath.ammSeedSplit(poolAmount, 8000);

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);
        (, uint256 p, uint256 eventSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

        assertEq(bridge.ammReserveEth(), ammSeed, "seed == floor(poolAmount * 80%)");
        assertEq(bridge.ammReserveEth(), (poolAmount * 8000) / 10_000, "seed matches direct recompute");
        assertEq(eventSeed, ammSeed, "event ammSeedAmount == reserve delta");
        assertLe(eventSeed, p, "seed never exceeds the pool fee");
    }

    /// @notice An AMM-disabled deployment (ratio 0) seeds nothing and the
    ///         canonical event carries `ammSeedAmount == 0`.
    function test_ethDeposit_eventAmmSeedZero_whenDisabled() public {
        KnomosisBridge bridge = _deploy(0);

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: 2 ether}(1000);
        (, , uint256 ammSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

        assertEq(ammSeed, 0, "event ammSeedAmount == 0 when AMM disabled");
        assertEq(bridge.ammReserveEth(), 0, "ETH reserve untouched (disabled)");
        assertEq(bridge.totalLockedValue(), 2 ether, "full deposit credited to TVL");
    }

    /// @notice A zero-fee deposit (feeBps 0 -> poolAmount 0) seeds nothing
    ///         and emits `ammSeedAmount == 0`, even with the AMM enabled.
    function test_ethDeposit_eventAmmSeedZero_whenPoolFeeZero() public {
        KnomosisBridge bridge = _deploy(8000);

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: 3 ether}(0); // 0% fee
        (uint256 u, uint256 p, uint256 ammSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

        assertEq(p, 0, "no pool fee");
        assertEq(ammSeed, 0, "no seed when there is no pool fee");
        assertEq(u, 3 ether, "whole deposit is the user's");
        assertEq(bridge.ammReserveEth(), 0, "reserve untouched");
    }

    /// @notice A dust pool fee whose seed floors to zero
    ///         (`poolAmount * ratio < 10000`) seeds nothing and emits
    ///         `ammSeedAmount == 0` — the floor is the boundary.
    function test_ethDeposit_eventAmmSeedZero_whenDustFloors() public {
        KnomosisBridge bridge = _deploy(1000); // 10% seed ratio

        // value 2 wei, feeBps 5000 -> poolAmount = 1; seed = floor(1 * 1000/10000) = 0.
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: 2}(5000);
        (, uint256 p, uint256 ammSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

        assertEq(p, 1, "dust pool fee");
        assertEq(ammSeed, 0, "dust seed floors to zero in the event");
        assertEq(bridge.ammReserveEth(), 0, "reserve untouched on a floored seed");
    }

    // ------------------------------------------------------------------
    // The receiptHash genuinely binds ammSeedAmount (tamper resistance)
    // ------------------------------------------------------------------

    /// @notice The emitted `receiptHash` equals the reference recompute
    ///         INCLUDING `ammSeedAmount`, and a recompute with a DIFFERENT
    ///         `ammSeedAmount` (here 0) produces a DIFFERENT hash — so an
    ///         off-chain replay with a tampered free-pool / AMM split is
    ///         rejected.  This is the plan-literal tamper-evidence property.
    function test_receiptHash_bindsAmmSeedAmount() public {
        KnomosisBridge bridge = _deploy(5000);

        uint256 value = 4 ether;
        uint16 feeBps = 2000;

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);
        (uint256 u, uint256 p, uint256 ammSeed, uint64 g, uint64 nonce, bytes32 rh) =
            _decodeDepositWithFee(vm.getRecordedLogs());
        assertGt(ammSeed, 0, "non-trivial seed so the tamper test is meaningful");

        // The contract's real-keccak256 receiptHash matches the reference
        // recompute over the SAME ammSeedAmount.
        bytes32 honest = FeeSplitMath.receiptHash(
            bridge.deploymentId(), alice, NATIVE_ETH, address(0), u, p, ammSeed, g, nonce
        );
        assertEq(rh, honest, "receiptHash == reference over the real split");

        // A recompute with a tampered ammSeedAmount (0) differs — proving
        // the hash genuinely covers the split, not just (poolAmount,...).
        bytes32 tampered = FeeSplitMath.receiptHash(
            bridge.deploymentId(), alice, NATIVE_ETH, address(0), u, p, 0, g, nonce
        );
        assertTrue(rh != tampered, "receiptHash is sensitive to ammSeedAmount (split is bound)");
    }

    // ------------------------------------------------------------------
    // BOLD-leg seeding (and ETH/BOLD leg independence)
    // ------------------------------------------------------------------

    /// @notice A BOLD fee-split deposit seeds the BOLD reserve only and the
    ///         canonical event carries the BOLD `ammSeedAmount`; the ETH
    ///         reserve stays untouched.
    function test_boldDeposit_seedsBoldReserveOnly() public {
        _etchBold();
        KnomosisBridge bridge = _deployBoldEnabled(5000);

        uint256 amount = 8 ether; // 8e18 BOLD-wei
        uint16 feeBps = 1500; // 15%
        _mintApprove(bridge, alice, amount);

        (, uint256 poolAmount,) = FeeSplitMath.split(amount, feeBps, bridge.weiPerBudgetUnitBold());
        (uint256 ammSeed,) = FeeSplitMath.ammSeedSplit(poolAmount, 5000);
        assertGt(ammSeed, 0, "non-trivial BOLD seed expected");

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositBoldWithFee(amount, feeBps);
        (, , uint256 eventSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

        assertEq(eventSeed, ammSeed, "event ammSeedAmount == BOLD seed");
        assertEq(bridge.ammReserveBold(), ammSeed, "BOLD reserve seeded");
        assertEq(bridge.ammReserveEth(), 0, "ETH reserve untouched by a BOLD deposit");
        assertEq(bridge.totalLockedValue(), amount, "global TVL credits full deposit");
        assertEq(bridge.boldTotalLockedValue(), amount, "per-BOLD TVL credits full deposit");
    }

    /// @notice The two legs accumulate independently.
    function test_legs_seededIndependently() public {
        _etchBold();
        KnomosisBridge bridge = _deployBoldEnabled(4000);

        uint256 ethValue = 2 ether;
        (, uint256 ethPool,) = FeeSplitMath.split(ethValue, 1000, bridge.weiPerBudgetUnitEth());
        (uint256 ethSeed,) = FeeSplitMath.ammSeedSplit(ethPool, 4000);
        vm.prank(alice);
        bridge.depositETHWithFee{value: ethValue}(1000);

        uint256 boldAmt = 6 ether;
        _mintApprove(bridge, alice, boldAmt);
        (, uint256 boldPool,) = FeeSplitMath.split(boldAmt, 2000, bridge.weiPerBudgetUnitBold());
        (uint256 boldSeed,) = FeeSplitMath.ammSeedSplit(boldPool, 4000);
        vm.prank(alice);
        bridge.depositBoldWithFee(boldAmt, 2000);

        assertEq(bridge.ammReserveEth(), ethSeed, "ETH reserve == ETH seed only");
        assertEq(bridge.ammReserveBold(), boldSeed, "BOLD reserve == BOLD seed only");
        assertTrue(ethSeed != 0 && boldSeed != 0, "both legs seeded a non-zero amount");
    }

    // ------------------------------------------------------------------
    // Monotonic accumulation across deposits
    // ------------------------------------------------------------------

    /// @notice Reserves grow monotonically and additively across deposits.
    function test_reserve_accumulatesMonotonically() public {
        KnomosisBridge bridge = _deploy(6000);

        uint256 running;
        uint256 prev;
        for (uint256 i = 0; i < 5; ++i) {
            uint256 value = (i + 1) * 1 ether;
            (, uint256 poolAmount,) = FeeSplitMath.split(value, 1200, bridge.weiPerBudgetUnitEth());
            (uint256 ammSeed,) = FeeSplitMath.ammSeedSplit(poolAmount, 6000);
            running += ammSeed;

            vm.prank(alice);
            bridge.depositETHWithFee{value: value}(1200);

            assertEq(bridge.ammReserveEth(), running, "reserve == cumulative seeds");
            assertGe(bridge.ammReserveEth(), prev, "reserve never shrinks on deposit");
            prev = bridge.ammReserveEth();
        }
        assertGt(bridge.ammReserveEth(), 0, "reserve accumulated a positive balance");
    }

    // ------------------------------------------------------------------
    // Reserves are a subset of TVL (deposit-only surface)
    // ------------------------------------------------------------------

    /// @notice Across deposits on both legs, the seeded reserves sum to no
    ///         more than the global TVL.
    function test_reserves_areSubsetOfTvl() public {
        _etchBold();
        KnomosisBridge bridge = _deployBoldEnabled(8000);

        vm.prank(alice);
        bridge.depositETHWithFee{value: 10 ether}(5000);

        uint256 boldAmt = 7 ether;
        _mintApprove(bridge, alice, boldAmt);
        vm.prank(alice);
        bridge.depositBoldWithFee(boldAmt, 5000);

        assertLe(
            bridge.ammReserveEth() + bridge.ammReserveBold(),
            bridge.totalLockedValue(),
            "reserves are a subset of total locked value"
        );
    }

    // ------------------------------------------------------------------
    // Negative paths: a reverted deposit and the non-fee-split path seed
    // nothing (the seed only happens on a successful fee-split deposit).
    // ------------------------------------------------------------------

    /// @notice A deposit that exceeds the TVL cap reverts, and the AMM
    ///         reserve is unchanged (the seed is rolled back with the rest
    ///         of the transaction — it never partially seeds).
    function test_cappedDeposit_revertsAndDoesNotSeed() public {
        KnomosisBridge bridge = _deployWithCap(8000, 1 ether);

        // A deposit at the cap succeeds and seeds.
        (, uint256 pool1,) = FeeSplitMath.split(1 ether, 5000, bridge.weiPerBudgetUnitEth());
        (uint256 seed1,) = FeeSplitMath.ammSeedSplit(pool1, 8000);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(5000);
        assertEq(bridge.ammReserveEth(), seed1, "first (at-cap) deposit seeded");

        // The next deposit pushes TVL over the cap: it reverts, and the
        // reserve does NOT grow.
        uint256 reserveBefore = bridge.ammReserveEth();
        vm.expectRevert(KnomosisBridge.TvlCapReached.selector);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 wei}(5000);
        assertEq(bridge.ammReserveEth(), reserveBefore, "capped deposit seeds nothing");
    }

    /// @notice The non-fee-split entry point `depositETH()` never seeds the
    ///         AMM (only `depositETHWithFee` / `depositBoldWithFee` route
    ///         through `_registerDepositWithFee`).  Even on an AMM-enabled
    ///         bridge, a plain `depositETH` leaves both reserves at 0.
    function test_plainDepositETH_doesNotSeed() public {
        KnomosisBridge bridge = _deploy(8000);

        vm.prank(alice);
        bridge.depositETH{value: 5 ether}();

        assertEq(bridge.totalLockedValue(), 5 ether, "plain deposit credited to TVL");
        assertEq(bridge.ammReserveEth(), 0, "plain depositETH never seeds the AMM");
        assertEq(bridge.ammReserveBold(), 0, "plain depositETH never seeds the AMM");
    }

    // ------------------------------------------------------------------
    // Gas-regression smoke test (the seeding path)
    // ------------------------------------------------------------------

    /// @notice The seeding (AMM-enabled) `depositETHWithFee` path stays
    ///         within a generous gas envelope — a lightweight regression
    ///         guard mirroring `BridgeFeeSplit.t.sol::test_gas_depositETHWithFee`
    ///         (which covers the AMM-disabled path).  The first seeded
    ///         deposit pays a cold reserve SSTORE; subsequent ones are warm.
    function test_gas_seedingPath() public {
        KnomosisBridge bridge = _deploy(5000);

        // Warm the reserve slot with a first deposit (cold SSTORE excluded
        // from the measured call below, so the bound reflects steady state).
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(1000);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        bridge.depositETHWithFee{value: 1 ether}(1000);
        uint256 used = gasBefore - gasleft();
        assertLt(used, 150_000, "seeding depositETHWithFee gas regression (warm)");
    }

    // ------------------------------------------------------------------
    // Fuzz — conservation (the GP.11.2.c acceptance criterion)
    // ------------------------------------------------------------------

    /// @notice For an arbitrary ETH deposit at a fixed enabled ratio, the
    ///         seed equals the reference recompute, never exceeds the pool
    ///         fee, the free-pool remainder makes conservation hold, the
    ///         event carries the seed, and the full deposit is escrowed.
    function testFuzz_ethSeed_conservation(uint256 value, uint16 feeBps) public {
        KnomosisBridge bridge = _deploy(5000);
        value = bound(value, 1, uint256(type(uint128).max));
        feeBps = uint16(bound(uint256(feeBps), 0, 5000));
        vm.deal(alice, value);

        (, uint256 poolAmount,) = FeeSplitMath.split(value, feeBps, bridge.weiPerBudgetUnitEth());
        (uint256 ammSeed, uint256 freePool) = FeeSplitMath.ammSeedSplit(poolAmount, 5000);

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);
        (, , uint256 eventSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

        assertEq(bridge.ammReserveEth(), ammSeed, "reserve == reference seed");
        assertEq(eventSeed, ammSeed, "event ammSeedAmount == reference seed");
        assertLe(ammSeed, poolAmount, "seed never exceeds pool fee");
        assertEq(ammSeed + freePool, poolAmount, "conservation: seed + freePool == poolAmount");
        assertEq(bridge.totalLockedValue(), value, "full deposit credited to TVL");
        assertEq(address(bridge).balance, value, "full deposit escrowed");
    }

    /// @notice Same conservation property on the BOLD leg.
    function testFuzz_boldSeed_conservation(uint256 amount, uint16 feeBps) public {
        _etchBold();
        KnomosisBridge bridge = _deployBoldEnabled(7000);
        amount = bound(amount, 1, 1e30);
        feeBps = uint16(bound(uint256(feeBps), 0, 5000));
        _mintApprove(bridge, alice, amount);

        (, uint256 poolAmount,) = FeeSplitMath.split(amount, feeBps, bridge.weiPerBudgetUnitBold());
        (uint256 ammSeed, uint256 freePool) = FeeSplitMath.ammSeedSplit(poolAmount, 7000);

        vm.prank(alice);
        bridge.depositBoldWithFee(amount, feeBps);

        assertEq(bridge.ammReserveBold(), ammSeed, "BOLD reserve == reference seed");
        assertLe(ammSeed, poolAmount, "seed never exceeds pool fee");
        assertEq(ammSeed + freePool, poolAmount, "conservation: seed + freePool == poolAmount");
        assertEq(bridge.ammReserveEth(), 0, "ETH reserve untouched");
        assertEq(bridge.boldTotalLockedValue(), amount, "full BOLD deposit credited");
    }

    /// @notice Conservation holds across the WHOLE admissible ratio range,
    ///         including ratio 0 (disabled -> seed 0) and the cap (8000).
    function testFuzz_seed_conservation_acrossRatios(uint256 value, uint16 feeBps, uint16 ratio)
        public
    {
        ratio = uint16(bound(uint256(ratio), 0, 8000));
        KnomosisBridge bridge = _deploy(ratio);
        value = bound(value, 1, uint256(type(uint128).max));
        feeBps = uint16(bound(uint256(feeBps), 0, 5000));
        vm.deal(alice, value);

        (, uint256 poolAmount,) = FeeSplitMath.split(value, feeBps, bridge.weiPerBudgetUnitEth());
        (uint256 ammSeed, uint256 freePool) = FeeSplitMath.ammSeedSplit(poolAmount, ratio);

        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);

        assertEq(bridge.ammReserveEth(), ammSeed, "reserve == reference seed across ratios");
        assertLe(ammSeed, poolAmount, "seed never exceeds pool fee");
        assertEq(ammSeed + freePool, poolAmount, "conservation across ratios");
        if (ratio == 0) {
            assertEq(ammSeed, 0, "disabled ratio never seeds");
        }
        assertEq(bridge.totalLockedValue(), value, "full deposit credited across ratios");
    }
}

/// @title AmmSeedingHandler
/// @notice Drives random ETH + BOLD deposits against a seeding-enabled
///         bridge, tracking the cumulative seed each leg SHOULD have
///         accrued (recomputed via the `FeeSplitMath` reference on every
///         admitted deposit).  The invariant runner asserts the live
///         reserves equal those running sums.
contract AmmSeedingHandler {
    Vm internal constant VM_CHEATS = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    KnomosisBridge public immutable bridge;
    address public immutable actor;
    uint16 public immutable ratio;

    uint256 public sumSeededEth;
    uint256 public sumSeededBold;

    constructor(KnomosisBridge bridge_, address actor_) {
        bridge = bridge_;
        actor = actor_;
        ratio = bridge_.ammSeedRatioBps();
    }

    function depositEth(uint256 value, uint16 feeBps) external {
        value = _bound(value, 0, 100 ether);
        feeBps = uint16(_bound(uint256(feeBps), 0, 5000));
        VM_CHEATS.deal(actor, value);
        (, uint256 poolAmount,) = FeeSplitMath.split(value, feeBps, bridge.weiPerBudgetUnitEth());
        (uint256 ammSeed,) = FeeSplitMath.ammSeedSplit(poolAmount, ratio);
        VM_CHEATS.prank(actor);
        try bridge.depositETHWithFee{value: value}(feeBps) {
            sumSeededEth += ammSeed;
        } catch {
            // ZeroDeposit (value 0), TvlCapReached, etc.: nothing seeded.
        }
    }

    function depositBold(uint256 amount, uint16 feeBps) external {
        amount = _bound(amount, 0, 100 ether);
        feeBps = uint16(_bound(uint256(feeBps), 0, 5000));
        MockBold(BOLD).mint(actor, amount);
        VM_CHEATS.prank(actor);
        MockBold(BOLD).approve(address(bridge), amount);
        (, uint256 poolAmount,) = FeeSplitMath.split(amount, feeBps, bridge.weiPerBudgetUnitBold());
        (uint256 ammSeed,) = FeeSplitMath.ammSeedSplit(poolAmount, ratio);
        VM_CHEATS.prank(actor);
        try bridge.depositBoldWithFee(amount, feeBps) {
            sumSeededBold += ammSeed;
        } catch {
            // ZeroDeposit and friends: nothing seeded.
        }
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
}

/// @title AmmDepositSeedingInvariantTest
/// @notice Stateful Foundry-invariant runner: across ARBITRARY sequences
///         of ETH and BOLD deposits (some of which revert at the TVL cap),
///         the live reserves equal the cumulative seeds of the ADMITTED
///         deposits, and the reserves are always a subset of TVL.
contract AmmDepositSeedingInvariantTest is Test {
    address private constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address private constant BOLD_BREAKER = address(0xB12E6B6E);
    address private constant BOLD_ADMIN = address(0xAD814);
    address private constant ACTOR = address(0xACC0);

    KnomosisBridge private bridge;
    AmmSeedingHandler private handler;

    function setUp() public {
        vm.etch(BOLD, address(new MockBold()).code);

        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        // A moderate global cap so the handler's larger deposits sometimes
        // REVERT at the cap (exercising the revert-rolls-back-the-seed
        // path), while smaller ones keep succeeding.  The reserve ==
        // sum-of-ADMITTED-seeds invariant must hold regardless.
        bridge = new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-amm-seeding-invariant"),
                attestor: address(0xA11CE),
                disputeVerifier: address(0xDEAD),
                sequencerStake: address(0xBEEF),
                migration: address(0),
                disputeWindowBlocks: 100,
                maxRedemptionWindowBlocks: 50,
                maxAttestationStaleBlocks: 200,
                cooldownBlocks: 50,
                tvlCap: 5000 ether,
                minFeeBps: 0,
                maxFeeBps: 5000,
                weiPerBudgetUnitEth: 1_000_000_000,
                weiPerBudgetUnitBold: 1_000_000_000,
                boldTokenAddress: BOLD,
                boldTvlCap: 5000 ether,
                boldCircuitBreaker: BOLD_BREAKER,
                boldAdmin: BOLD_ADMIN,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 6000,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );

        handler = new AmmSeedingHandler(bridge, ACTOR);
        targetContract(address(handler));
    }

    /// @notice The live ETH reserve equals exactly the cumulative ETH seed
    ///         of the ADMITTED deposits — catches a missed seed, a
    ///         double-seed, a wrong-leg seed, or a seed that leaked from a
    ///         reverted deposit.
    function invariant_ethReserveEqualsSumSeeded() public view {
        assertEq(
            bridge.ammReserveEth(),
            handler.sumSeededEth(),
            "ammReserveEth == cumulative admitted ETH seeds"
        );
    }

    /// @notice The live BOLD reserve equals the cumulative admitted BOLD seed.
    function invariant_boldReserveEqualsSumSeeded() public view {
        assertEq(
            bridge.ammReserveBold(),
            handler.sumSeededBold(),
            "ammReserveBold == cumulative admitted BOLD seeds"
        );
    }

    /// @notice The reserves are always a subset of the total locked value.
    function invariant_reservesSubsetOfTvl() public view {
        assertLe(
            bridge.ammReserveEth() + bridge.ammReserveBold(),
            bridge.totalLockedValue(),
            "reserves <= total locked value"
        );
    }
}
