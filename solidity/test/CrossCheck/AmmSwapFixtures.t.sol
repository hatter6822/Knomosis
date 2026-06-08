// SPDX-License-Identifier: GPL-3.0-or-later
//
// Knomosis — proof-carrying state transition system.
// Cross-stack consumer for the GP.11.7 embedded-AMM swap corpus.
//
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {AmmMath} from "src/lib/AmmMath.sol";

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

    /// @notice For EVERY corpus entry, `AmmMath.getAmountOut` reproduces
    ///         the Lean `expectedOut` byte-for-byte.
    function test_perEntry_getAmountOut_matchesLean() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("amm_swap.json not generated (run `lake test`)");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = _count(raw);

        for (uint256 i = 0; i < n; i++) {
            Entry memory e = _loadEntry(raw, i);
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
}
