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
/// @dev    Design (vs the plan sketch): the seeding is MINIMAL-BREAK.  It
///         does NOT change the canonical `DepositWithFeeInitiated` event
///         or its `receiptHash` (so the cross-stack ingest decoders and
///         all existing fee-split fixtures stay byte-valid); instead it
///         adds a SEPARATE `AmmReserveSeeded` event for observability,
///         emitted only when a non-zero amount is seeded.  The split is a
///         pure function of the bound `poolAmount` and the immutable
///         `ammSeedRatioBps`, so the L2 reconstructs it deterministically
///         with no new trust surface (no replay-with-modified-split is
///         possible — `poolAmount` is the only free variable and it is
///         bound by `receiptHash`).  `test_split_doesNotAlterDepositEvent`
///         pins the unchanged-canonical-event property.
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

    /// @dev topic0 of `AmmReserveSeeded(...)`, used to assert the seed
    ///      event's presence / absence in recorded logs.
    bytes32 private constant AMM_SEEDED_TOPIC =
        keccak256("AmmReserveSeeded(address,uint64,uint256,uint256,uint256,uint64)");

    // Local copies of the contract events for `vm.expectEmit`.
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
    event AmmReserveSeeded(
        address indexed sender,
        uint64 indexed resourceId,
        uint256 poolAmount,
        uint256 ammSeedAmount,
        uint256 newReserve,
        uint64 depositorNonce
    );

    function setUp() public {
        vm.deal(alice, type(uint128).max);
        vm.deal(bob, type(uint128).max);
    }

    // ------------------------------------------------------------------
    // Deployment helpers
    // ------------------------------------------------------------------

    /// @notice Deploy a standalone, BOLD-disabled bridge with a chosen
    ///         `ammSeedRatioBps` and a permissive fee-split config so
    ///         `depositETHWithFee` works on a fresh deployment.
    function _deploy(uint16 ammSeedRatioBps) internal returns (KnomosisBridge) {
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
                tvlCap: type(uint256).max,
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

    /// @notice True iff any recorded log is an `AmmReserveSeeded`.
    function _sawSeedEvent(Vm.Log[] memory logs) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == AMM_SEEDED_TOPIC) {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Core ETH-leg seeding + the AmmReserveSeeded event
    // ------------------------------------------------------------------

    /// @notice A fee-split ETH deposit at a 50% seed ratio seeds exactly
    ///         `floor(poolAmount / 2)` into `ammReserveEth`, emits BOTH the
    ///         canonical `DepositWithFeeInitiated` and the supplementary
    ///         `AmmReserveSeeded` (with the matching nonce + resulting
    ///         reserve), and still credits the FULL deposit to TVL.
    function test_ethDeposit_seedsReserve_andEmits() public {
        KnomosisBridge bridge = _deploy(5000);

        uint256 value = 1 ether;
        uint16 feeBps = 1000; // 10% -> poolAmount = 0.1 ether
        (uint256 userAmount, uint256 poolAmount, uint64 budgetGrant) =
            FeeSplitMath.split(value, feeBps, bridge.weiPerBudgetUnitEth());
        (uint256 ammSeed, uint256 freePool) = FeeSplitMath.ammSeedSplit(poolAmount, 5000);
        assertGt(ammSeed, 0, "non-trivial seed expected");

        uint64 nonce = bridge.depositNonce(alice);
        bytes32 expectedHash = FeeSplitMath.receiptHash(
            bridge.deploymentId(), alice, NATIVE_ETH, address(0), userAmount, poolAmount, budgetGrant, nonce
        );

        vm.expectEmit(true, true, true, true, address(bridge));
        emit DepositWithFeeInitiated(
            alice, NATIVE_ETH, address(0), userAmount, poolAmount, budgetGrant, nonce, expectedHash
        );
        vm.expectEmit(true, true, true, true, address(bridge));
        emit AmmReserveSeeded(alice, NATIVE_ETH, poolAmount, ammSeed, ammSeed, nonce);

        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);

        assertEq(bridge.ammReserveEth(), ammSeed, "ETH reserve seeded by floor(poolAmount/2)");
        assertEq(bridge.ammReserveBold(), 0, "BOLD reserve untouched by an ETH deposit");
        assertEq(bridge.totalLockedValue(), value, "TVL credits the FULL deposit");
        assertEq(address(bridge).balance, value, "escrow holds the FULL deposit");
        assertEq(ammSeed + freePool, poolAmount, "conservation: seed + freePool == poolAmount");
    }

    /// @notice At the maximum seed ratio (8000 bps = 80%) the seed is
    ///         exactly `floor(poolAmount * 8000 / 10000)`.
    function test_ethDeposit_seedsReserve_atMaxRatio() public {
        KnomosisBridge bridge = _deploy(8000);

        uint256 value = 5 ether;
        uint16 feeBps = 2500; // 25%
        (, uint256 poolAmount,) = FeeSplitMath.split(value, feeBps, bridge.weiPerBudgetUnitEth());
        (uint256 ammSeed,) = FeeSplitMath.ammSeedSplit(poolAmount, 8000);

        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);

        assertEq(bridge.ammReserveEth(), ammSeed, "seed == floor(poolAmount * 80%)");
        assertEq(bridge.ammReserveEth(), (poolAmount * 8000) / 10_000, "seed matches direct recompute");
        assertLe(bridge.ammReserveEth(), poolAmount, "seed never exceeds the pool fee");
    }

    /// @notice An AMM-disabled deployment (ratio 0) seeds nothing and emits
    ///         NO `AmmReserveSeeded` — the deposit log shape is exactly the
    ///         pre-GP.11.2 single event.
    function test_ethDeposit_noSeed_whenDisabled() public {
        KnomosisBridge bridge = _deploy(0);

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: 2 ether}(1000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_sawSeedEvent(logs), "no AmmReserveSeeded when AMM disabled");
        assertEq(bridge.ammReserveEth(), 0, "ETH reserve untouched (disabled)");
        assertEq(bridge.totalLockedValue(), 2 ether, "full deposit credited to TVL");
    }

    /// @notice A zero-fee deposit (feeBps 0 -> poolAmount 0) seeds nothing
    ///         even with the AMM enabled — there is no pool fee to split.
    function test_ethDeposit_noSeed_whenPoolFeeZero() public {
        KnomosisBridge bridge = _deploy(8000);

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: 3 ether}(0); // 0% fee
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_sawSeedEvent(logs), "no seed event when poolAmount == 0");
        assertEq(bridge.ammReserveEth(), 0, "no seed when there is no pool fee");
        assertEq(bridge.totalLockedValue(), 3 ether, "whole deposit is the user's");
    }

    /// @notice A dust pool fee whose seed floors to zero
    ///         (`poolAmount * ratio < 10000`) seeds nothing and emits no
    ///         seed event — the floor is the boundary, not a silent 1-wei
    ///         seed.
    function test_ethDeposit_dustSeedFloorsToZero() public {
        KnomosisBridge bridge = _deploy(1000); // 10% seed ratio

        // value 2 wei, feeBps 5000 -> poolAmount = floor(2 * 5000 / 10000) = 1.
        // seed = floor(1 * 1000 / 10000) = 0.
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: 2}(5000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(_sawSeedEvent(logs), "no seed event when the seed floors to zero");
        assertEq(bridge.ammReserveEth(), 0, "dust seed floors to zero, reserve untouched");
        assertEq(bridge.totalLockedValue(), 2, "deposit still credited");
    }

    // ------------------------------------------------------------------
    // BOLD-leg seeding (and ETH/BOLD leg independence)
    // ------------------------------------------------------------------

    /// @notice A BOLD fee-split deposit seeds the BOLD reserve only; the
    ///         ETH reserve stays untouched.  The seed math is identical to
    ///         the ETH leg.
    function test_boldDeposit_seedsBoldReserveOnly() public {
        _etchBold();
        KnomosisBridge bridge = _deployBoldEnabled(5000);

        uint256 amount = 8 ether; // 8e18 BOLD-wei
        uint16 feeBps = 1500; // 15%
        _mintApprove(bridge, alice, amount);

        (, uint256 poolAmount,) = FeeSplitMath.split(amount, feeBps, bridge.weiPerBudgetUnitBold());
        (uint256 ammSeed,) = FeeSplitMath.ammSeedSplit(poolAmount, 5000);
        assertGt(ammSeed, 0, "non-trivial BOLD seed expected");

        uint64 nonce = bridge.depositNonce(alice);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit AmmReserveSeeded(alice, BOLD_RID, poolAmount, ammSeed, ammSeed, nonce);

        vm.prank(alice);
        bridge.depositBoldWithFee(amount, feeBps);

        assertEq(bridge.ammReserveBold(), ammSeed, "BOLD reserve seeded");
        assertEq(bridge.ammReserveEth(), 0, "ETH reserve untouched by a BOLD deposit");
        assertEq(bridge.totalLockedValue(), amount, "global TVL credits full deposit");
        assertEq(bridge.boldTotalLockedValue(), amount, "per-BOLD TVL credits full deposit");
    }

    /// @notice The two legs accumulate independently: an ETH deposit then a
    ///         BOLD deposit on the same bridge each seed only their own
    ///         reserve.
    function test_legs_seededIndependently() public {
        _etchBold();
        KnomosisBridge bridge = _deployBoldEnabled(4000);

        // ETH leg.
        uint256 ethValue = 2 ether;
        (, uint256 ethPool,) = FeeSplitMath.split(ethValue, 1000, bridge.weiPerBudgetUnitEth());
        (uint256 ethSeed,) = FeeSplitMath.ammSeedSplit(ethPool, 4000);
        vm.prank(alice);
        bridge.depositETHWithFee{value: ethValue}(1000);

        // BOLD leg.
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

    /// @notice Reserves grow monotonically and additively across several
    ///         deposits — each deposit's seed adds to the running reserve;
    ///         deposit-side flow never shrinks a reserve.
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

    /// @notice The `newReserve` field of `AmmReserveSeeded` reports the
    ///         POST-seed reserve, so the second deposit's event carries the
    ///         accumulated total (not just its own increment).
    function test_seedEvent_reportsAccumulatedReserve() public {
        KnomosisBridge bridge = _deploy(5000);

        // First deposit seeds s1.
        (, uint256 pool1,) = FeeSplitMath.split(1 ether, 2000, bridge.weiPerBudgetUnitEth());
        (uint256 seed1,) = FeeSplitMath.ammSeedSplit(pool1, 5000);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(2000);
        assertEq(bridge.ammReserveEth(), seed1, "first seed landed");

        // Second deposit: AmmReserveSeeded.newReserve must be seed1 + seed2.
        (, uint256 pool2,) = FeeSplitMath.split(4 ether, 2000, bridge.weiPerBudgetUnitEth());
        (uint256 seed2,) = FeeSplitMath.ammSeedSplit(pool2, 5000);
        uint64 nonce = bridge.depositNonce(alice);

        vm.expectEmit(true, true, true, true, address(bridge));
        emit AmmReserveSeeded(alice, NATIVE_ETH, pool2, seed2, seed1 + seed2, nonce);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 4 ether}(2000);

        assertEq(bridge.ammReserveEth(), seed1 + seed2, "reserve is the cumulative total");
    }

    // ------------------------------------------------------------------
    // Minimal-break invariant: the canonical deposit event is unchanged
    // ------------------------------------------------------------------

    /// @notice The depositor-facing `DepositWithFeeInitiated` event and its
    ///         `receiptHash` are BYTE-IDENTICAL whether the AMM is enabled
    ///         or disabled (for the same deposit at the same address): the
    ///         seeding only ADDS an `AmmReserveSeeded` log, never altering
    ///         the canonical deposit event the cross-stack ingest decoders
    ///         read.  This is the property that keeps the Rust ingestor and
    ///         every existing fee-split fixture valid under GP.11.2.
    function test_split_doesNotAlterDepositEvent() public {
        // Two bridges that differ ONLY in the seed ratio.  Deploying both
        // from THIS contract at the same nonce-relative point would give
        // different addresses (and thus different deploymentIds); to isolate
        // the event payload we recompute the expected receiptHash per bridge
        // from its own deploymentId, exactly as a real consumer would.
        KnomosisBridge disabled = _deploy(0);
        KnomosisBridge enabled = _deploy(8000);

        uint256 value = 2 ether;
        uint16 feeBps = 1500;
        (uint256 userAmount, uint256 poolAmount, uint64 budgetGrant) =
            FeeSplitMath.split(value, feeBps, disabled.weiPerBudgetUnitEth());

        // Disabled bridge: exactly one DepositWithFeeInitiated, no seed.
        _expectDepositEvent(disabled, alice, userAmount, poolAmount, budgetGrant);
        vm.prank(alice);
        disabled.depositETHWithFee{value: value}(feeBps);

        // Enabled bridge: the SAME DepositWithFeeInitiated payload (the
        // userAmount / poolAmount / budgetGrant are identical; only the
        // deploymentId-bound receiptHash differs per address, which
        // `_expectDepositEvent` recomputes).
        _expectDepositEvent(enabled, bob, userAmount, poolAmount, budgetGrant);
        vm.prank(bob);
        enabled.depositETHWithFee{value: value}(feeBps);

        // The canonical poolAmount is identical; the enabled bridge merely
        // ALSO seeded its reserve, which the disabled one did not.
        assertEq(enabled.ammReserveEth(), (poolAmount * 8000) / 10_000, "enabled seeded");
        assertEq(disabled.ammReserveEth(), 0, "disabled did not seed");
    }

    /// @dev `vm.expectEmit` the canonical deposit event for `user` on
    ///      `bridge`, recomputing the per-bridge receiptHash.
    function _expectDepositEvent(
        KnomosisBridge bridge,
        address user,
        uint256 userAmount,
        uint256 poolAmount,
        uint64 budgetGrant
    ) internal {
        uint64 nonce = bridge.depositNonce(user);
        bytes32 expectedHash = FeeSplitMath.receiptHash(
            bridge.deploymentId(), user, NATIVE_ETH, address(0), userAmount, poolAmount, budgetGrant, nonce
        );
        vm.expectEmit(true, true, true, true, address(bridge));
        emit DepositWithFeeInitiated(
            user, NATIVE_ETH, address(0), userAmount, poolAmount, budgetGrant, nonce, expectedHash
        );
    }

    // ------------------------------------------------------------------
    // Reserves are a subset of TVL (deposit-only surface)
    // ------------------------------------------------------------------

    /// @notice Across deposits on both legs, the seeded reserves sum to no
    ///         more than the global TVL: each seed is a subset of a
    ///         `poolAmount`, a subset of an `amount`, and the legs partition
    ///         `totalLockedValue`.
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
    // Fuzz — conservation (the GP.11.2.c acceptance criterion)
    // ------------------------------------------------------------------

    /// @notice For an arbitrary ETH deposit at a fixed enabled ratio, the
    ///         seed equals the reference recompute, never exceeds the pool
    ///         fee, the free-pool remainder makes conservation hold, and the
    ///         full deposit is escrowed.
    function testFuzz_ethSeed_conservation(uint256 value, uint16 feeBps) public {
        KnomosisBridge bridge = _deploy(5000);
        value = bound(value, 1, uint256(type(uint128).max));
        feeBps = uint16(bound(uint256(feeBps), 0, 5000));
        vm.deal(alice, value);

        (, uint256 poolAmount,) = FeeSplitMath.split(value, feeBps, bridge.weiPerBudgetUnitEth());
        (uint256 ammSeed, uint256 freePool) = FeeSplitMath.ammSeedSplit(poolAmount, 5000);

        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);

        assertEq(bridge.ammReserveEth(), ammSeed, "reserve == reference seed");
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
            // ZeroDeposit (value 0) and friends: nothing seeded.
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
///         of ETH and BOLD deposits, the live reserves equal the
///         cumulative seeds, and the reserves are always a subset of TVL.
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
                ammSeedRatioBps: 6000,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );

        handler = new AmmSeedingHandler(bridge, ACTOR);
        targetContract(address(handler));
    }

    /// @notice The live ETH reserve equals exactly the cumulative ETH seed
    ///         the handler recomputed from every admitted deposit — catches
    ///         a missed seed, double-seed, or wrong-leg seed.
    function invariant_ethReserveEqualsSumSeeded() public view {
        assertEq(
            bridge.ammReserveEth(),
            handler.sumSeededEth(),
            "ammReserveEth == cumulative ETH seeds"
        );
    }

    /// @notice The live BOLD reserve equals the cumulative BOLD seed.
    function invariant_boldReserveEqualsSumSeeded() public view {
        assertEq(
            bridge.ammReserveBold(),
            handler.sumSeededBold(),
            "ammReserveBold == cumulative BOLD seeds"
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
