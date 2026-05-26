// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";

/// @title DepositFeeSplitCrossCheck
/// @notice Workstream GP.5.1.i — Solidity-side consumer of the
///         `deposit_fee_split.json` fixture.
///
/// @dev    For each entry the consumer recomputes the fee split
///           poolAmount  = floor(msgValue * chosenFeeBps / 10000)
///           userAmount  = msgValue - poolAmount
///           budgetGrant = min(poolAmount / weiPerBudgetUnit,
///                             MAX_BUDGET_PER_DEPOSIT)
///         via `FeeSplitMath` (the same library the behavioural suite
///         pins the live contract against) and asserts byte equality
///         with the Lean generator's recorded `(userAmount, poolAmount,
///         budgetGrant)`.  It also recomputes
///           deploymentId = keccak256(abi.encode(chainid, contractAddr, tag))
///           receiptHash  = keccak256(abi.encode(deploymentId, sender,
///               resourceId, token, userAmount, poolAmount, budgetGrant,
///               depositorNonce))
///         and asserts equality.  The hash check is gated on the
///         header's `isKeccak256Linked` (the Lean side uses an FNV
///         fallback when the production keccak256 binding is absent);
///         the arithmetic and conservation checks run unconditionally.
contract DepositFeeSplitCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "deposit_fee_split.json";

    /// @notice Header shape: 80 entries (16 corner + 64 randomised)
    ///         plus the constitutional caps.
    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        assertEq(vm.parseJsonUint(raw, ".header.count"), 80, "count");
        assertEq(vm.parseJsonUint(raw, ".header.countCorner"), 16, "corner");
        assertEq(vm.parseJsonUint(raw, ".header.countRandomised"), 64, "randomised");
        assertEq(vm.parseJsonUint(raw, ".header.maxFeeBpsCap"), 5000, "maxFeeBpsCap");
        assertEq(vm.parseJsonUint(raw, ".header.minWeiPerBudgetUnit"), 1, "minWeiPerBudgetUnit");
    }

    /// @notice The fixture's `maxBudgetPerDeposit` must agree with the
    ///         `FeeSplitMath` reference constant (which the behavioural
    ///         suite in turn pins against
    ///         `KnomosisBridge.MAX_BUDGET_PER_DEPOSIT`).  Triple-pins
    ///         the clamp constant Lean ↔ reference ↔ contract.
    function test_maxBudgetPerDeposit_agrees() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        assertEq(
            vm.parseJsonUint(raw, ".header.maxBudgetPerDeposit"),
            uint256(FeeSplitMath.MAX_BUDGET_PER_DEPOSIT),
            "clamp constant Lean == reference"
        );
        assertEq(uint256(FeeSplitMath.MAX_BUDGET_PER_DEPOSIT), 1_000_000_000_000, "10^12");
    }

    /// @notice Per-entry arithmetic cross-check.  Recompute the split
    ///         and assert it matches the fixture, plus conservation and
    ///         the budget cap.  Runs in every binding mode.
    function test_perEntry_split_matches() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");

            uint256 msgValue = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".msgValue")));
            uint256 feeBps = vm.parseJsonUint(raw, string.concat(base, ".chosenFeeBps"));
            uint256 rate = vm.parseJsonUint(raw, string.concat(base, ".weiPerBudgetUnit"));

            uint256 fixUser = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".userAmount")));
            uint256 fixPool = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".poolAmount")));
            uint256 fixBudget = vm.parseJsonUint(raw, string.concat(base, ".budgetGrant"));

            // Bound checks: the Lean generator constrains feeBps to
            // [0, 5000] and the rate / budget to uint64 range; assert
            // them so a corrupt fixture fails loudly here rather than
            // as a downstream cast truncation.
            assertLe(feeBps, 5000, "feeBps out of admissible range");
            assertLt(rate, 1 << 64, "rate out of uint64 range");
            assertLt(fixBudget, 1 << 64, "budgetGrant out of uint64 range");

            (uint256 u, uint256 p, uint64 g) =
                FeeSplitMath.split(msgValue, uint16(feeBps), uint64(rate));

            assertEq(u, fixUser, "userAmount mismatch");
            assertEq(p, fixPool, "poolAmount mismatch");
            assertEq(uint256(g), fixBudget, "budgetGrant mismatch");

            // Conservation + cap, independent of the fixture's stored
            // split.
            assertEq(u + p, msgValue, "conservation: userAmount + poolAmount == msgValue");
            assertLe(uint256(g), uint256(FeeSplitMath.MAX_BUDGET_PER_DEPOSIT), "budget within cap");
        }
    }

    /// @notice Per-entry receiptHash cross-check.  Skipped under the
    ///         FNV fallback (the recomputed keccak256 cannot match an
    ///         FNV-derived `expectedHash`).
    function test_perEntry_receiptHash_matches() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        if (!vm.parseJsonBool(raw, ".header.isKeccak256Linked")) {
            _skipWithReason("keccak256 fallback; cross-check skipped");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");

            uint256 chainid = vm.parseJsonUint(raw, string.concat(base, ".chainid"));
            address contractAddr = vm.parseJsonAddress(raw, string.concat(base, ".contractAddr"));
            bytes32 tag = vm.parseJsonBytes32(raw, string.concat(base, ".knomosisVersionTag"));
            address sender = vm.parseJsonAddress(raw, string.concat(base, ".sender"));
            uint256 resourceId = vm.parseJsonUint(raw, string.concat(base, ".resourceId"));
            address token = vm.parseJsonAddress(raw, string.concat(base, ".token"));
            uint256 nonce = vm.parseJsonUint(raw, string.concat(base, ".depositorNonce"));

            uint256 userAmount = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".userAmount")));
            uint256 poolAmount = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".poolAmount")));
            uint256 budgetGrant = vm.parseJsonUint(raw, string.concat(base, ".budgetGrant"));

            bytes32 expectedHash = vm.parseJsonBytes32(raw, string.concat(base, ".expectedHash"));
            bytes32 expectedDid = vm.parseJsonBytes32(raw, string.concat(base, ".deploymentId"));

            assertLt(resourceId, 1 << 64, "resourceId out of uint64 range");
            assertLt(nonce, 1 << 64, "depositorNonce out of uint64 range");

            bytes32 did = keccak256(abi.encode(chainid, contractAddr, tag));
            assertEq(did, expectedDid, "deploymentId mismatch");

            bytes32 actual = FeeSplitMath.receiptHash(
                did,
                sender,
                uint64(resourceId),
                token,
                userAmount,
                poolAmount,
                uint64(budgetGrant),
                uint64(nonce)
            );
            assertEq(actual, expectedHash, "receiptHash mismatch");
        }
    }

    /// @notice The three budget-clamp corners (indices 4, 5, 6) all
    ///         pin `budgetGrant == MAX_BUDGET_PER_DEPOSIT`: the clamped
    ///         case, the exact boundary, and one above the boundary.
    function test_clamp_corners() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        _assertClampCorner(raw, 4, "corner:budget-clamp");
        _assertClampCorner(raw, 5, "corner:budget-boundary-exact");
        _assertClampCorner(raw, 6, "corner:budget-boundary-above");
    }

    function _assertClampCorner(string memory raw, uint256 idx, string memory expectedCategory)
        internal
        pure
    {
        string memory base = string.concat(".entries[", vm.toString(idx), "]");
        assertEq(
            keccak256(bytes(vm.parseJsonString(raw, string.concat(base, ".category")))),
            keccak256(bytes(expectedCategory)),
            "clamp-corner category mismatch (fixture layout drift)"
        );
        assertEq(
            vm.parseJsonUint(raw, string.concat(base, ".budgetGrant")),
            uint256(FeeSplitMath.MAX_BUDGET_PER_DEPOSIT),
            "clamp corner budgetGrant != cap"
        );
    }

    /// @notice The zero-fee corner (index 0) produces a zero pool
    ///         credit, zero budget, and the full amount to the user.
    function test_zeroFee_corner() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        assertEq(
            keccak256(bytes(vm.parseJsonString(raw, ".entries[0].category"))),
            keccak256(bytes("corner:zero-fee")),
            "zero-fee corner layout drift"
        );
        uint256 msgValue = uint256(vm.parseJsonBytes32(raw, ".entries[0].msgValue"));
        uint256 poolAmount = uint256(vm.parseJsonBytes32(raw, ".entries[0].poolAmount"));
        uint256 userAmount = uint256(vm.parseJsonBytes32(raw, ".entries[0].userAmount"));
        assertEq(poolAmount, 0, "zero pool at zero fee");
        assertEq(userAmount, msgValue, "full amount to user at zero fee");
        assertEq(vm.parseJsonUint(raw, ".entries[0].budgetGrant"), 0, "zero budget at zero fee");
    }
}
