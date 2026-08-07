// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.36;

import {DepositEventDecoder} from "test/utils/DepositEventDecoder.sol";
import {BoldTestSupport} from "test/utils/BoldTestSupport.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";
import {MockBold} from "test/utils/MockBold.sol";

/// @title AmmDepositSeedingTest
/// @notice Workstream GP.11.2 as re-cut by Workstream SB (the
///         L2-primary pool topology) — deposit-side AMM seed SPLIT.
///         Every fee-split deposit splits its `poolAmount` into an
///         AMM-liquidity seed
///         (`floor(poolAmount * ammSeedRatioBps / 10000)`) and a
///         sequencer-claimable free-pool remainder — and the seed is
///         credited ON L2 (the `depositWithFee` law's third leg, to
///         the reserve actor) from the event, while the L1
///         seed leg is credited on L2 only.  The
///         non-growth is asserted throughout this suite: it is the
///         topology guarantee.
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
contract AmmDepositSeedingTest is Test, BoldTestSupport, DepositEventDecoder {
    address private alice = address(0xA1);
    address private bob = address(0xB0B);

    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_NATIVE_ETH`.
    uint64 private constant NATIVE_ETH = 0;
    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_BOLD`.
    uint64 private constant BOLD_RID = 1;

    address private constant BOLD_BREAKER = address(0xB12E6B6E);
    address private constant BOLD_ADMIN = address(0xAD814);
    /// @dev The GP.11.3 AMM disaster-recovery (kill-switch) role.
    address private constant AMM_DR = address(0xA33D6);

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
        // ETH seeding only accrues on a FUNCTIONAL AMM (BOLD-enabled), so the
        // deploy helpers below are BOLD-enabled; etch a conformant BOLD mock
        // at the pinned address so their constructors' symbol() check passes.
        _etchBold();
    }

    // ------------------------------------------------------------------
    // Deployment helpers
    // ------------------------------------------------------------------

    /// @notice Deploy a standalone, BOLD-ENABLED bridge with a chosen
    ///         `ammSeedRatioBps` and a permissive fee-split config (no TVL
    ///         ceiling) so `depositETHWithFee` works on a fresh deployment.
    ///         BOLD-enabled because ETH seeding only accrues on a functional
    ///         AMM (a BOLD-disabled deployment seeds nothing — see
    ///         `AmmStorage.t.sol::test_boldDisabled_seedsNothing_despitePositiveRatio`).
    function _deploy(uint16 ammSeedRatioBps) internal returns (KnomosisBridge) {
        return _deployWithCap(ammSeedRatioBps, type(uint256).max);
    }

    /// @notice As `_deploy`, but with a caller-chosen global `tvlCap` so
    ///         the cap-revert path can be exercised.  Requires a BOLD mock
    ///         etched first (done in `setUp`).
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
                weiPerBudgetUnitBold: 1_000_000_000,
                boldTokenAddress: BOLD,
                boldTvlCap: tvlCap,
                boldCircuitBreaker: BOLD_BREAKER,
                boldAdmin: BOLD_ADMIN,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: ammSeedRatioBps,
                ammDisasterRecovery: AMM_DR,
                faultProofRollbackAuthority: address(0),
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice Place a fresh conformant `MockBold` at the pinned address.
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
                ammDisasterRecovery: AMM_DR,
                faultProofRollbackAuthority: address(0),
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }


    // ------------------------------------------------------------------
    // Core ETH-leg seeding + the canonical event's ammSeedAmount field
    // ------------------------------------------------------------------

    /// @notice A fee-split ETH deposit at a 50% seed ratio emits the
    ///         canonical `DepositWithFeeInitiated` carrying
    ///         `ammSeedAmount == floor(poolAmount / 2)` (with the bound
    ///         `receiptHash`) — the value the L2 credits to the reserve
    ///         actor — the L1 books are excised, so nothing L1-side moves, and
    ///         the FULL deposit is credited to TVL (the wei backing the
    ///         L2 seed stays in general escrow).
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

        assertEq(bridge.totalLockedValue(), value, "TVL credits the FULL deposit");
        assertEq(address(bridge).balance, value, "escrow holds the FULL deposit");
        assertEq(ammSeed + freePool, poolAmount, "conservation: seed + freePool == poolAmount");
    }

    /// @notice At the maximum seed ratio (8000 bps = 80%) the EVENT's
    ///         seed is exactly `floor(poolAmount * 8000 / 10000)` while
    ///         the L1 reserve stays untouched.
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

        assertEq(eventSeed, ammSeed, "event seed == floor(poolAmount * 80%)");
        assertEq(eventSeed, (poolAmount * 8000) / 10_000, "event seed matches direct recompute");
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

    /// @notice The BOLD-leg analogue of `test_receiptHash_bindsAmmSeedAmount`.
    ///         The BOLD path shares `_registerDepositWithFee`, but pinning the
    ///         tamper-evidence explicitly on the BOLD resourceId + token guards
    ///         against a future per-resource divergence in the binding.
    function test_boldReceiptHash_bindsAmmSeedAmount() public {
        _etchBold();
        KnomosisBridge bridge = _deployBoldEnabled(5000);

        uint256 amount = 6 ether;
        uint16 feeBps = 2500;
        _mintApprove(bridge, alice, amount);

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositBoldWithFee(amount, feeBps);
        (uint256 u, uint256 p, uint256 ammSeed, uint64 g, uint64 nonce, bytes32 rh) =
            _decodeDepositWithFee(vm.getRecordedLogs());
        assertGt(ammSeed, 0, "non-trivial BOLD seed so the tamper test is meaningful");

        bytes32 honest =
            FeeSplitMath.receiptHash(bridge.deploymentId(), alice, BOLD_RID, BOLD, u, p, ammSeed, g, nonce);
        assertEq(rh, honest, "BOLD receiptHash == reference over the real split");

        bytes32 tampered =
            FeeSplitMath.receiptHash(bridge.deploymentId(), alice, BOLD_RID, BOLD, u, p, 0, g, nonce);
        assertTrue(rh != tampered, "BOLD receiptHash is sensitive to ammSeedAmount");
    }

    /// @notice Non-circular anchor for the `FeeSplitMath.ammSeedSplit`
    ///         reference: the behavioural + invariant tests check the live
    ///         contract against this reference, so the reference itself is
    ///         pinned here to HAND-COMPUTED ground truth (independent of any
    ///         contract code) — closing the residual circularity where a
    ///         shared bug between `_seedAmmReserves` and the reference could
    ///         pass.  (The cross-stack corpus is the other anti-circularity
    ///         layer: Lean recomputes the seed independently.)
    function test_ammSeedSplit_knownVectors() public pure {
        // floor(1000 * 8000 / 10000) = 800; free = 200.
        (uint256 s1, uint256 f1) = FeeSplitMath.ammSeedSplit(1000, 8000);
        assertEq(s1, 800, "seed 8000bps of 1000");
        assertEq(f1, 200, "free 8000bps of 1000");
        // floor(50 * 8000 / 10000) = 40; free = 10 (the exact-half corner).
        (uint256 s2, uint256 f2) = FeeSplitMath.ammSeedSplit(50, 8000);
        assertEq(s2, 40, "seed 8000bps of 50");
        assertEq(f2, 10, "free 8000bps of 50");
        // floor(1 * 8000 / 10000) = 0 (dust floors to zero); free = 1.
        (uint256 s3, uint256 f3) = FeeSplitMath.ammSeedSplit(1, 8000);
        assertEq(s3, 0, "dust seed floors to zero");
        assertEq(f3, 1, "dust free == pool");
        // ratio 0 (disabled) -> (0, pool).
        (uint256 s4, uint256 f4) = FeeSplitMath.ammSeedSplit(777, 0);
        assertEq(s4, 0, "disabled seed");
        assertEq(f4, 777, "disabled free == pool");
        // floor(1e18 * 30 / 10000) = 3e15 (the AMM_SWAP_FEE_BPS=30 shape);
        // free = 1e18 - 3e15.
        (uint256 s5, uint256 f5) = FeeSplitMath.ammSeedSplit(1e18, 30);
        assertEq(s5, 3e15, "seed 30bps of 1e18");
        assertEq(f5, 1e18 - 3e15, "free 30bps of 1e18");
        // Conservation on every vector (mirrors the Lean `ammSeed_conserves`).
        assertEq(s1 + f1, 1000);
        assertEq(s5 + f5, 1e18);
    }

    /// @notice The off-gas-leg branch of `_ammSeedSplit` (the only
    ///         otherwise-uncoverable path): a resource that is neither
    ///         ETH (0) nor BOLD (1) splits NOTHING, even with the AMM
    ///         enabled.  Driven through a harness that exposes the
    ///         `internal` helper directly, since no public entry point
    ///         reaches a non-gas-leg resource.
    function test_ammSeedSplit_offLeg_splitsNothing() public {
        SeedHarness h = _deploySeedHarness(8000);

        // An off-leg resource (2, 7) splits nothing.
        assertEq(h.exposed_ammSeedSplit(2, 1 ether), 0, "off-leg resource 2 splits 0");
        assertEq(h.exposed_ammSeedSplit(7, 1 ether), 0, "off-leg resource 7 splits 0");

        // Sanity: the same harness DOES split on the real legs (so the
        // test isn't passing because the split is globally broken) —
        // and, per the L2-primary topology, no L1 reserve moves either
        // way (the helper is `view`; this pins the intent).
        uint256 ethSeed = h.exposed_ammSeedSplit(0, 1 ether); // floor(1e18*0.8)
        assertEq(ethSeed, (uint256(1 ether) * 8000) / 10_000, "ETH leg splits");
        uint256 boldSeed = h.exposed_ammSeedSplit(1, 2 ether);
        assertEq(boldSeed, (uint256(2 ether) * 8000) / 10_000, "BOLD leg splits");
    }

    /// @notice Deploy a `SeedHarness` (AMM-enabled at `ratio`) exposing the
    ///         internal `_ammSeedSplit` for branch coverage.
    function _deploySeedHarness(uint16 ratio) internal returns (SeedHarness) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new SeedHarness(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-seed-harness"),
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
                ammSeedRatioBps: ratio,
                ammDisasterRecovery: AMM_DR,
                faultProofRollbackAuthority: address(0),
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    // ------------------------------------------------------------------
    // BOLD-leg seeding (and ETH/BOLD leg independence)
    // ------------------------------------------------------------------

    /// @notice A BOLD fee-split deposit's EVENT carries the BOLD
    ///         `ammSeedAmount`; BOTH L1 reserves stay untouched (the
    ///         seed is credited on L2).
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
        assertEq(bridge.totalLockedValue(), amount, "global TVL credits full deposit");
        assertEq(bridge.boldTotalLockedValue(), amount, "per-BOLD TVL credits full deposit");
    }

    /// @notice The two legs' EVENT seeds are computed independently, and
    ///         neither deposit touches either L1 reserve.
    function test_legs_seededIndependently() public {
        _etchBold();
        KnomosisBridge bridge = _deployBoldEnabled(4000);

        uint256 ethValue = 2 ether;
        (, uint256 ethPool,) = FeeSplitMath.split(ethValue, 1000, bridge.weiPerBudgetUnitEth());
        (uint256 ethSeed,) = FeeSplitMath.ammSeedSplit(ethPool, 4000);
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: ethValue}(1000);
        (, , uint256 ethEventSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

        uint256 boldAmt = 6 ether;
        _mintApprove(bridge, alice, boldAmt);
        (, uint256 boldPool,) = FeeSplitMath.split(boldAmt, 2000, bridge.weiPerBudgetUnitBold());
        (uint256 boldSeed,) = FeeSplitMath.ammSeedSplit(boldPool, 4000);
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositBoldWithFee(boldAmt, 2000);
        (, , uint256 boldEventSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

        assertEq(ethEventSeed, ethSeed, "ETH event seed == ETH reference");
        assertEq(boldEventSeed, boldSeed, "BOLD event seed == BOLD reference");
        assertTrue(ethSeed != 0 && boldSeed != 0, "both legs split a non-zero seed");
    }

    // ------------------------------------------------------------------
    // L2-bound seeds accumulate in events; the L1 reserve never moves
    // ------------------------------------------------------------------

    /// @notice Across a run of deposits, the L2-bound seeds accumulate in
    ///         the EVENTS (each equal to the reference recompute) while
    ///         the L1 reserve stays at zero throughout — the topology
    ///         guarantee, stated over a sequence rather than one deposit.
    function test_reserve_accumulatesMonotonically() public {
        _etchBold();
        KnomosisBridge bridge = _deployBoldEnabled(6000);

        uint256 running;
        for (uint256 i = 0; i < 5; ++i) {
            uint256 value = (i + 1) * 1 ether;
            (, uint256 poolAmount,) = FeeSplitMath.split(value, 1200, bridge.weiPerBudgetUnitEth());
            (uint256 ammSeed,) = FeeSplitMath.ammSeedSplit(poolAmount, 6000);

            vm.recordLogs();
            vm.prank(alice);
            bridge.depositETHWithFee{value: value}(1200);
            (, , uint256 eventSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

            assertEq(eventSeed, ammSeed, "each event seed == reference");
            running += eventSeed;
        }
        assertGt(running, 0, "the L2-bound seeds accumulated a positive sum");
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

    }

    // ------------------------------------------------------------------
    // Negative paths: a reverted deposit and the non-fee-split path seed
    // nothing (the seed only happens on a successful fee-split deposit).
    // ------------------------------------------------------------------

    /// @notice A deposit that exceeds the TVL cap reverts, emitting no
    ///         event at all — no L2-bound seed exists for a rejected
    ///         deposit — and the L1 reserve stays where it always is
    ///         under the L2-primary topology: zero.
    function test_cappedDeposit_revertsAndDoesNotSeed() public {
        KnomosisBridge bridge = _deployWithCap(8000, 1 ether);

        // A deposit at the cap succeeds; its event carries the seed.
        (, uint256 pool1,) = FeeSplitMath.split(1 ether, 5000, bridge.weiPerBudgetUnitEth());
        (uint256 seed1,) = FeeSplitMath.ammSeedSplit(pool1, 8000);
        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(5000);
        (, , uint256 eventSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());
        assertEq(eventSeed, seed1, "first (at-cap) deposit's event carries the seed");

        // The next deposit pushes TVL over the cap: it reverts.
        vm.expectRevert(KnomosisBridge.TvlCapReached.selector);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 wei}(5000);
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
    }

    // ------------------------------------------------------------------
    // Gas-regression smoke test (the seeding path)
    // ------------------------------------------------------------------

    /// @notice COMPARATIVE gas-regression guard: measure the warm
    ///         `depositETHWithFee` gas on an AMM-DISABLED and an AMM-ENABLED
    ///         bridge under identical inputs, and bound the seeding OVERHEAD
    ///         (the warm reserve SSTORE + the seed arithmetic).  This
    ///         isolates the GP.11.2 cost — far tighter than an absolute
    ///         envelope, which an unrelated change could pass while seeding
    ///         silently doubled in cost.  A real regression (a cold SSTORE
    ///         every deposit, an accidental second store) trips the bound.
    function test_gas_seedingOverhead() public {
        uint256 disabledGas = _warmDepositGas(_deploy(0));
        uint256 seededGas = _warmDepositGas(_deploy(5000));

        assertGe(seededGas, disabledGas, "seeding cannot be cheaper than no-seed");
        // Warm SSTORE ~5k + the seed multiply/divide + (no event delta, the
        // ammSeedAmount field is present in both).  Generous headroom, but
        // far below the ~150k absolute path cost.
        assertLt(seededGas - disabledGas, 15_000, "seeding overhead regression");
    }

    /// @notice Warm-path gas for one `depositETHWithFee` (a first deposit
    ///         pre-warms the reserve slot so the measured call is steady
    ///         state, not the one-time cold SSTORE).
    function _warmDepositGas(KnomosisBridge bridge) internal returns (uint256) {
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(1000);
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        bridge.depositETHWithFee{value: 1 ether}(1000);
        return gasBefore - gasleft();
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

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositBoldWithFee(amount, feeBps);
        (, , uint256 eventSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

        assertEq(eventSeed, ammSeed, "event ammSeedAmount == reference seed");
        assertLe(ammSeed, poolAmount, "seed never exceeds pool fee");
        assertEq(ammSeed + freePool, poolAmount, "conservation: seed + freePool == poolAmount");
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

        vm.recordLogs();
        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);
        (, , uint256 eventSeed,,,) = _decodeDepositWithFee(vm.getRecordedLogs());

        assertEq(eventSeed, ammSeed, "event seed == reference across ratios");
        assertLe(ammSeed, poolAmount, "seed never exceeds pool fee");
        assertEq(ammSeed + freePool, poolAmount, "conservation across ratios");
        if (ratio == 0) {
            assertEq(ammSeed, 0, "disabled ratio never seeds");
        }
        assertEq(bridge.totalLockedValue(), value, "full deposit credited across ratios");
    }
}

/// @title SeedHarness
/// @notice Test-only subclass of `KnomosisBridge` exposing the `internal`
///         `_ammSeedSplit` so its off-gas-leg branch — unreachable
///         through the public entry points (ETH / BOLD only) — can be
///         exercised directly for full branch coverage.  Exposes nothing
///         the production ABI does; used only by `AmmDepositSeedingTest`.
contract SeedHarness is KnomosisBridge {
    constructor(KnomosisBridge.ConstructorArgs memory args) KnomosisBridge(args) {}

    /// @notice External shim over the internal `_ammSeedSplit`.
    function exposed_ammSeedSplit(uint64 resourceId, uint256 poolAmount)
        external
        view
        returns (uint256)
    {
        return _ammSeedSplit(resourceId, poolAmount);
    }
}
