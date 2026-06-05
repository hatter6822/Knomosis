// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {CrossCheckFramework} from "./Framework.t.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";

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
///         and asserts equality.  The full-hash check is gated on the
///         header's `isKeccak256Linked` (the Lean side uses an FNV
///         fallback when the production keccak256 binding is absent);
///         the arithmetic and conservation checks run unconditionally.
///
///         Two further layers close the gaps a recompute-only check
///         leaves: `test_perEntry_receiptTail_layout` byte-matches the
///         Lean-emitted 224-byte preimage tail against `abi.encode`
///         (hash-independent, so it pins the receiptHash field layout in
///         every binding mode), and `test_perEntry_liveContract_split_matches`
///         deploys the real `KnomosisBridge` per entry and asserts the
///         EMITTED split equals the Lean values -- a direct
///         contract-vs-Lean equivalence with no `FeeSplitMath`
///         intermediary, plus an on-chain real-keccak256 check of the
///         receiptHash recipe.
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
        assertEq(vm.parseJsonUint(raw, ".header.maxAmmSeedRatioBps"), 8000, "maxAmmSeedRatioBps");
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

            uint256 seedRatio = vm.parseJsonUint(raw, string.concat(base, ".ammSeedRatioBps"));
            uint256 fixUser = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".userAmount")));
            uint256 fixPool = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".poolAmount")));
            uint256 fixSeed = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".ammSeedAmount")));
            uint256 fixBudget = vm.parseJsonUint(raw, string.concat(base, ".budgetGrant"));

            // Fixture-integrity checks: the Lean generator constrains
            // feeBps to [0, 5000] and the AMM seed ratio to [0, 8000] (the
            // admissible on-chain ranges) and the rate / budget to uint64
            // range (the contract's types); assert them so a corrupt
            // fixture fails loudly here.
            assertLe(feeBps, 5000, "feeBps out of admissible range");
            assertLe(seedRatio, 8000, "ammSeedRatioBps out of admissible range");
            assertLt(rate, 1 << 64, "rate out of uint64 range");
            assertLt(fixBudget, 1 << 64, "budgetGrant out of uint64 range");

            (uint256 u, uint256 p, uint64 g) = FeeSplitMath.split(msgValue, feeBps, rate);
            (uint256 ammSeed, uint256 freePool) = FeeSplitMath.ammSeedSplit(p, seedRatio);

            assertEq(u, fixUser, "userAmount mismatch");
            assertEq(p, fixPool, "poolAmount mismatch");
            assertEq(ammSeed, fixSeed, "ammSeedAmount mismatch (GP.11.2)");
            assertEq(uint256(g), fixBudget, "budgetGrant mismatch");

            // Conservation + cap, independent of the fixture's stored
            // split.
            assertEq(u + p, msgValue, "conservation: userAmount + poolAmount == msgValue");
            assertEq(ammSeed + freePool, p, "conservation: ammSeed + freePool == poolAmount");
            assertLe(ammSeed, p, "ammSeed never exceeds the pool fee");
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
            uint256 ammSeedAmount =
                uint256(vm.parseJsonBytes32(raw, string.concat(base, ".ammSeedAmount")));
            uint256 budgetGrant = vm.parseJsonUint(raw, string.concat(base, ".budgetGrant"));

            bytes32 expectedHash = vm.parseJsonBytes32(raw, string.concat(base, ".expectedHash"));
            bytes32 expectedDid = vm.parseJsonBytes32(raw, string.concat(base, ".deploymentId"));

            // The contract abi-encodes resourceId / budgetGrant / nonce
            // as uint64; asserting `< 2^64` guarantees the reference's
            // uint256 abi.encode yields the identical 32-byte words (so
            // the recomputed hash is byte-equal to the contract's).
            assertLt(resourceId, 1 << 64, "resourceId out of uint64 range");
            assertLt(budgetGrant, 1 << 64, "budgetGrant out of uint64 range");
            assertLt(nonce, 1 << 64, "depositorNonce out of uint64 range");

            bytes32 did = keccak256(abi.encode(chainid, contractAddr, tag));
            assertEq(did, expectedDid, "deploymentId mismatch");

            // GP.11.2: the receiptHash binds ammSeedAmount after poolAmount.
            bytes32 actual = FeeSplitMath.receiptHash(
                did, sender, resourceId, token, userAmount, poolAmount, ammSeedAmount, budgetGrant, nonce
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

    /// @notice Hash-independent receiptHash-layout pin.  The Lean
    ///         generator emits the 224-byte preimage tail (the seven
    ///         ABI-encoded fields after `deploymentId`); here we
    ///         recompute the same `abi.encode` and assert byte equality.
    ///         No hashing is involved, so this runs in EVERY binding
    ///         mode -- it pins the receiptHash field order + widths
    ///         cross-stack even when the keccak256-gated full-hash check
    ///         is skipped under the FNV fallback.
    function test_perEntry_receiptTail_layout() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            address sender = vm.parseJsonAddress(raw, string.concat(base, ".sender"));
            uint256 resourceId = vm.parseJsonUint(raw, string.concat(base, ".resourceId"));
            address token = vm.parseJsonAddress(raw, string.concat(base, ".token"));
            uint256 userAmount = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".userAmount")));
            uint256 poolAmount = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".poolAmount")));
            uint256 ammSeedAmount =
                uint256(vm.parseJsonBytes32(raw, string.concat(base, ".ammSeedAmount")));
            uint256 budgetGrant = vm.parseJsonUint(raw, string.concat(base, ".budgetGrant"));
            uint256 nonce = vm.parseJsonUint(raw, string.concat(base, ".depositorNonce"));

            // GP.11.2: the 256-byte tail inserts ammSeedAmount after poolAmount.
            bytes memory leanTail = vm.parseJsonBytes(raw, string.concat(base, ".receiptTail"));
            bytes memory solTail = abi.encode(
                sender, resourceId, token, userAmount, poolAmount, ammSeedAmount, budgetGrant, nonce
            );
            assertEq(solTail, leanTail, "receiptHash preimage-tail layout mismatch");
        }
    }

    /// @notice Direct cross-stack check: deploy the real `KnomosisBridge`
    ///         per fixture entry, call `depositETHWithFee` with the
    ///         fixture's `(msgValue, chosenFeeBps)` at the fixture's
    ///         exchange rate, and assert the EMITTED
    ///         `(userAmount, poolAmount, budgetGrant)` equal the
    ///         Lean-generated values -- removing the `FeeSplitMath`
    ///         intermediary from the cross-stack path entirely.  Also
    ///         re-derives the emitted `receiptHash` from the bridge's own
    ///         `deploymentId` + fields (real keccak256) to pin the hash
    ///         recipe on-chain.  The split is rate- and
    ///         deployment-independent, so the fixture's `deploymentId` /
    ///         `depositorNonce` (which differ from the fresh bridge's)
    ///         are intentionally not compared.
    function test_perEntry_liveContract_split_matches() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        address depositor = address(0xA11CE);
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            uint256 msgValue = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".msgValue")));
            uint256 feeBps = vm.parseJsonUint(raw, string.concat(base, ".chosenFeeBps"));
            uint256 rate = vm.parseJsonUint(raw, string.concat(base, ".weiPerBudgetUnit"));
            uint256 seedRatio = vm.parseJsonUint(raw, string.concat(base, ".ammSeedRatioBps"));
            uint256 fixUser = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".userAmount")));
            uint256 fixPool = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".poolAmount")));
            uint256 fixSeed = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".ammSeedAmount")));
            uint256 fixBudget = vm.parseJsonUint(raw, string.concat(base, ".budgetGrant"));

            // Fixture-integrity bounds matching the contract's ABI widths.
            assertLe(feeBps, 5000, "feeBps out of admissible range");
            assertLe(seedRatio, 8000, "ammSeedRatioBps out of admissible range");
            assertLt(rate, 1 << 64, "rate out of uint64 range");

            // Deploy at the fixture's exchange rate AND seed ratio so the
            // emitted ammSeedAmount matches the Lean value.  Narrowing is
            // safe under the bounds asserted directly above.
            // forge-lint: disable-next-line(unsafe-typecast)
            KnomosisBridge bridge = _deployBridge(uint64(rate), uint16(seedRatio));
            vm.deal(depositor, msgValue);
            vm.recordLogs();
            vm.prank(depositor);
            // forge-lint: disable-next-line(unsafe-typecast)
            bridge.depositETHWithFee{value: msgValue}(uint16(feeBps));

            (uint256 u, uint256 p, uint256 ammSeed, uint64 g, uint64 nonce, bytes32 rh) =
                _decodeDepositWithFee(vm.getRecordedLogs());

            assertEq(u, fixUser, "live userAmount != Lean fixture");
            assertEq(p, fixPool, "live poolAmount != Lean fixture");
            assertEq(ammSeed, fixSeed, "live ammSeedAmount != Lean fixture (GP.11.2)");
            assertEq(uint256(g), fixBudget, "live budgetGrant != Lean fixture");
            // The live reserve grew by exactly the seed.
            assertEq(bridge.ammReserveEth(), ammSeed, "live reserve != emitted ammSeedAmount");

            // The bridge computes receiptHash with real keccak256 over
            // ITS OWN deploymentId + the emitted fields; re-derive via the
            // reference recipe and assert equality.
            bytes32 recomputed = FeeSplitMath.receiptHash(
                bridge.deploymentId(), depositor, 0, address(0), u, p, ammSeed, g, nonce
            );
            assertEq(recomputed, rh, "live receiptHash recipe inconsistent");
        }
    }

    /// @notice Deploy a standalone bridge with the given ETH-leg rate and
    ///         AMM seed ratio; full `[0, 5000]` fee range, no TVL ceiling,
    ///         migration unset (so `circuitOpen` passes for a fresh
    ///         deployment).
    function _deployBridge(uint64 rate, uint16 ammSeedRatioBps)
        internal
        returns (KnomosisBridge)
    {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-fee-split-crosscheck"),
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
                weiPerBudgetUnitEth: rate,
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

    /// @notice Locate + decode the single `DepositWithFeeInitiated`
    ///         entry in a recorded-log array.
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
}
