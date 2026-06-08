// SPDX-License-Identifier: GPL-3.0-or-later
//
// Knomosis — proof-carrying state transition system.
// Cross-stack consumer for the GP.11.7 embedded-AMM swap corpus.
//
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {AmmMath} from "src/lib/AmmMath.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {MockBold} from "test/utils/MockBold.sol";

/// @title AmmSwapFixturesCrossCheck (GP.11.7)
/// @notice Solidity-side consumer of the Lean-authored `amm_swap.json`
///         corpus.  Verifies:
///         1. `getAmountOut` formula compliance (Lean output == Solidity)
///         2. k-monotonicity: `kBefore <= kAfter` for every entry
///         3. No-drain: `expectedOut < reserveOut` for every entry
///         4. Slippage flag consistency
///         5. CBE byte length (54 bytes per entry)
///
///         Amount-scale fields and k-products are emitted as 0x-prefixed
///         32-byte BE hex strings by the Lean generator (matching the
///         established AmmMath cross-check pattern).
///
///         The swap-math corpus runs UNCONDITIONALLY in every hash-binding
///         mode since it involves no hashing.
contract AmmSwapFixturesCrossCheck is CrossCheckFramework {
    /// @dev Fixture file name under `test/CrossCheck/fixtures/`.
    string internal constant FIXTURE_NAME = "amm_swap.json";

    /// @dev Production swap fee in basis points.
    uint256 internal constant AMM_SWAP_FEE_BPS = 30;

    /// @dev Decoded fixture entry.
    struct Entry {
        uint256 fromResource;
        uint256 toResource;
        uint256 amountIn;
        uint256 reserveIn;
        uint256 reserveOut;
        uint256 feeBps;
        uint256 expectedOut;
        uint256 minAmountOut;
        bool slippageSatisfied;
        uint256 kBefore;
        uint256 kAfter;
        uint256 newReserveIn;
        uint256 newReserveOut;
        uint256 reserveActorCreditFrom;
        uint256 reserveActorDebitTo;
        uint256 ammReserveActor;
    }

    // ------------------------------------------------------------------
    // Fixture decoding
    // ------------------------------------------------------------------

    function _count(string memory raw) internal pure returns (uint256) {
        return vm.parseJsonUint(raw, ".header.count");
    }

    function _gridCount(string memory raw) internal pure returns (uint256) {
        return vm.parseJsonUint(raw, ".header.gridCount");
    }

    function _cornerCount(string memory raw) internal pure returns (uint256) {
        return vm.parseJsonUint(raw, ".header.cornerCount");
    }

    function _loadEntry(string memory raw, uint256 i) internal pure returns (Entry memory e) {
        string memory base = string.concat(".entries[", vm.toString(i), "]");
        e.fromResource = vm.parseJsonUint(raw, string.concat(base, ".fromResource"));
        e.toResource = vm.parseJsonUint(raw, string.concat(base, ".toResource"));
        e.amountIn = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".amountIn")));
        e.reserveIn = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".reserveIn")));
        e.reserveOut = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".reserveOut")));
        e.feeBps = vm.parseJsonUint(raw, string.concat(base, ".feeBps"));
        e.expectedOut = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".expectedOut")));
        e.minAmountOut = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".minAmountOut")));
        e.slippageSatisfied = vm.parseJsonBool(raw, string.concat(base, ".slippageSatisfied"));
        e.kBefore = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".kBefore")));
        e.kAfter = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".kAfter")));
        e.newReserveIn = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".newReserveIn")));
        e.newReserveOut = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".newReserveOut")));
        e.reserveActorCreditFrom = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".reserveActorCreditFrom")));
        e.reserveActorDebitTo = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".reserveActorDebitTo")));
        e.ammReserveActor = vm.parseJsonUint(raw, string.concat(base, ".ammReserveActor"));
    }

    // ------------------------------------------------------------------
    // Header
    // ------------------------------------------------------------------

    function test_header_shape() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("amm_swap.json not generated (run `lake test`)");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);

        assertGt(_count(raw), 0, "corpus is non-empty");
        assertEq(
            _gridCount(raw) + _cornerCount(raw),
            _count(raw),
            "grid + corner == total"
        );
        assertEq(
            vm.parseJsonUint(raw, ".header.ammSwapFeeBps"),
            AMM_SWAP_FEE_BPS,
            "production fee pinned"
        );
        assertEq(
            vm.parseJsonUint(raw, ".header.bpsDenominator"),
            AmmMath.BPS_DENOMINATOR,
            "bpsDenominator matches"
        );
        assertEq(
            vm.parseJsonUint(raw, ".header.ammReserveActor"),
            3,
            "ammReserveActor == 3"
        );
        assertEq(
            vm.parseJsonUint(raw, ".header.actionTag"),
            23,
            "actionTag == 23"
        );
        assertEq(vm.parseJsonString(raw, ".header.workstream"), "GP.11.7", "workstream tag");
    }

    // ------------------------------------------------------------------
    // Per-entry getAmountOut formula compliance
    // ------------------------------------------------------------------

    /// @notice For every non-degenerate corpus entry, `AmmMath.getAmountOut`
    ///         reproduces the Lean `expectedOut` byte-for-byte.  Degenerate
    ///         entries (zero reserves, zero amountIn, fee >= 100%) are
    ///         skipped because the Solidity library reverts on those inputs.
    function test_perEntry_getAmountOut_matchesLean() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("amm_swap.json not generated (run `lake test`)");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = _count(raw);

        for (uint256 i = 0; i < n; i++) {
            Entry memory e = _loadEntry(raw, i);
            if (e.reserveIn == 0 || e.reserveOut == 0 || e.amountIn == 0 || e.feeBps >= 10000) {
                continue;
            }
            uint256 got = AmmMath.getAmountOut(e.amountIn, e.reserveIn, e.reserveOut, e.feeBps);
            assertEq(got, e.expectedOut, "Solidity getAmountOut diverges from Lean");
        }
    }

    // ------------------------------------------------------------------
    // No-drain
    // ------------------------------------------------------------------

    function test_perEntry_noDrain() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("amm_swap.json not generated (run `lake test`)");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = _count(raw);

        for (uint256 i = 0; i < n; i++) {
            Entry memory e = _loadEntry(raw, i);
            if (e.reserveIn == 0 || e.reserveOut == 0 || e.amountIn == 0 || e.feeBps >= 10000) {
                continue;
            }
            assertLt(e.expectedOut, e.reserveOut, "no-drain violated");
        }
    }

    // ------------------------------------------------------------------
    // k-monotonicity
    // ------------------------------------------------------------------

    function test_perEntry_kNonDecreasing() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("amm_swap.json not generated (run `lake test`)");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = _count(raw);

        for (uint256 i = 0; i < n; i++) {
            Entry memory e = _loadEntry(raw, i);
            assertLe(e.kBefore, e.kAfter, "k decreased across the swap");
        }
    }

    // ------------------------------------------------------------------
    // Slippage consistency
    // ------------------------------------------------------------------

    function test_perEntry_slippageConsistency() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("amm_swap.json not generated (run `lake test`)");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = _count(raw);

        for (uint256 i = 0; i < n; i++) {
            Entry memory e = _loadEntry(raw, i);
            bool expected = e.expectedOut >= e.minAmountOut;
            assertEq(e.slippageSatisfied, expected, "slippage flag mismatch");
        }
    }

    // ------------------------------------------------------------------
    // Hand-vector anchor
    // ------------------------------------------------------------------

    function test_handVectors_knownGroundTruth() public pure {
        assertEq(AmmMath.getAmountOut(1000, 1000, 1000, 0), 500, "no-fee half-pool");
        assertEq(AmmMath.getAmountOut(1000, 1000, 1000, 30), 499, "0.30%-fee half-pool");
    }

    // ------------------------------------------------------------------
    // CBE byte-length pin
    // ------------------------------------------------------------------

    /// @notice Every entry's `expectedCbe` is exactly 54 bytes (110 hex chars + 0x prefix).
    function test_perEntry_cbeByteLength() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("amm_swap.json not generated (run `lake test`)");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = _count(raw);

        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory cbeHex = vm.parseJsonString(raw, string.concat(base, ".expectedCbe"));
            bytes memory cbeBytes = vm.parseBytes(cbeHex);
            assertEq(cbeBytes.length, 54, "CBE must be 54 bytes (tag + 5 x 9-byte heads)");
        }
    }

    // ------------------------------------------------------------------
    // Post-swap reserves
    // ------------------------------------------------------------------

    /// @notice Post-swap reserves equal `reserveIn + amountIn` / `reserveOut - expectedOut`.
    function test_perEntry_postSwapReserves() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("amm_swap.json not generated (run `lake test`)");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = _count(raw);

        for (uint256 i = 0; i < n; i++) {
            Entry memory e = _loadEntry(raw, i);
            assertEq(e.newReserveIn, e.reserveIn + e.amountIn, "newReserveIn mismatch");
            assertEq(e.newReserveOut, e.reserveOut - e.expectedOut, "newReserveOut mismatch");
        }
    }

    // ------------------------------------------------------------------
    // L2 balance deltas
    // ------------------------------------------------------------------

    /// @notice L2 balance deltas: credit = amountIn, debit = expectedOut.
    function test_perEntry_l2BalanceDeltas() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("amm_swap.json not generated (run `lake test`)");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = _count(raw);

        for (uint256 i = 0; i < n; i++) {
            Entry memory e = _loadEntry(raw, i);
            assertEq(e.reserveActorCreditFrom, e.amountIn, "reserveActorCreditFrom != amountIn");
            assertEq(e.reserveActorDebitTo, e.expectedOut, "reserveActorDebitTo != expectedOut");
        }
    }

    // ------------------------------------------------------------------
    // CBE tag-byte verification
    // ------------------------------------------------------------------

    /// @notice Every entry's `expectedCbe` starts with the CBE Nat type
    ///         marker (0x00) followed by the ammSwap action tag (0x17 = 23)
    ///         in little-endian.
    function test_perEntry_cbeTagByte() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("amm_swap.json not generated (run `lake test`)");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = _count(raw);

        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory cbeHex = vm.parseJsonString(raw, string.concat(base, ".expectedCbe"));
            bytes memory cbeBytes = vm.parseBytes(cbeHex);
            assertEq(uint8(cbeBytes[0]), 0x00, "first byte must be 0x00 (CBE Nat type)");
            assertEq(uint8(cbeBytes[1]), 0x17, "second byte must be 0x17 (= 23, ammSwap tag LE)");
        }
    }

    // ------------------------------------------------------------------
    // Live contract execution
    // ------------------------------------------------------------------

    /// @notice Deploy a BOLD-enabled bridge with AMM, seed reserves via
    ///         real deposits, and perform ETH->BOLD and BOLD->ETH swaps
    ///         verifying that the live contract's output matches
    ///         `AmmMath.getAmountOut`.
    function test_liveContract_ammSwapMatchesFormula() public {
        address constant_BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
        address BOLD_BREAKER = address(0xB12E6B6E);
        address BOLD_ADMIN = address(0xAD814);
        address AMM_DR = address(0xA33D6);
        address lp = address(0x11D);
        address swp = address(0x5A11);
        vm.deal(lp, type(uint128).max);
        vm.deal(swp, type(uint128).max);

        // Etch MockBold at the pinned address
        MockBold impl = new MockBold();
        vm.etch(constant_BOLD, address(impl).code);

        // Deploy BOLD-enabled, AMM-enabled bridge (80% seed ratio)
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        KnomosisBridge bridge = new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-amm-crosscheck"),
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
                boldTokenAddress: constant_BOLD,
                boldTvlCap: type(uint256).max,
                boldCircuitBreaker: BOLD_BREAKER,
                boldAdmin: BOLD_ADMIN,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 8000,
                ammDisasterRecovery: AMM_DR,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );

        // Seed ETH reserve via depositETHWithFee
        vm.prank(lp);
        bridge.depositETHWithFee{value: 100 ether}(5000);

        // Seed BOLD reserve via depositBoldWithFee
        uint256 boldDeposit = 300_000 ether;
        MockBold(constant_BOLD).mint(lp, boldDeposit);
        vm.prank(lp);
        MockBold(constant_BOLD).approve(address(bridge), boldDeposit);
        vm.prank(lp);
        bridge.depositBoldWithFee(boldDeposit, 5000);

        uint256 rEth = bridge.ammReserveEth();
        uint256 rBold = bridge.ammReserveBold();
        assertGt(rEth, 0, "ETH reserve seeded");
        assertGt(rBold, 0, "BOLD reserve seeded");

        // ETH -> BOLD swap: verify output matches AmmMath.getAmountOut
        uint256 amountIn = 1 ether;
        uint256 expectedOut = AmmMath.getAmountOut(amountIn, rEth, rBold, AMM_SWAP_FEE_BPS);
        assertGt(expectedOut, 0, "non-trivial ETH->BOLD output");
        vm.prank(swp);
        uint256 actualOut = bridge.ammSwap{value: amountIn}(
            0, amountIn, 0, block.timestamp + 1 hours
        );
        assertEq(actualOut, expectedOut, "live ETH->BOLD == AmmMath.getAmountOut");

        // Refresh reserves after the swap
        rEth = bridge.ammReserveEth();
        rBold = bridge.ammReserveBold();

        // BOLD -> ETH swap: verify output matches AmmMath.getAmountOut
        uint256 boldIn = 3000 ether;
        uint256 expectedEthOut = AmmMath.getAmountOut(boldIn, rBold, rEth, AMM_SWAP_FEE_BPS);
        assertGt(expectedEthOut, 0, "non-trivial BOLD->ETH output");
        MockBold(constant_BOLD).mint(swp, boldIn);
        vm.prank(swp);
        MockBold(constant_BOLD).approve(address(bridge), boldIn);
        vm.prank(swp);
        uint256 actualEthOut = bridge.ammSwap(
            1, boldIn, 0, block.timestamp + 1 hours
        );
        assertEq(actualEthOut, expectedEthOut, "live BOLD->ETH == AmmMath.getAmountOut");
    }
}
