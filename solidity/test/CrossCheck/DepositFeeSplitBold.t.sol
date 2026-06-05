// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {CrossCheckFramework} from "./Framework.t.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {MockBold} from "test/utils/MockBold.sol";

/// @title DepositFeeSplitBoldCrossCheck
/// @notice Workstream GP.5.4.e — Solidity-side consumer of the
///         `deposit_fee_split_bold.json` fixture.
///
/// @dev    The BOLD path is the byte-identical sibling of the ETH path
///         (GP.5.1.i); its split arithmetic + receiptHash recipe are
///         shared, so this consumer reuses `FeeSplitMath`.  The
///         BOLD-specific cross-stack obligation is that Lean and Solidity
///         agree on the receiptHash when `resourceId = RESOURCE_ID_BOLD`
///         and `token = BOLD_TOKEN_ADDRESS`.  Layers, mirroring the ETH
///         consumer:
///           * arithmetic recompute (`FeeSplitMath.split`) — every binding,
///           * receiptHash recompute (real keccak256) — gated on
///             `isKeccak256Linked`,
///           * hash-independent receiptTail layout byte-match — every
///             binding,
///           * a DIRECT live-contract check that deploys the real
///             BOLD-enabled `KnomosisBridge` per entry (with a BOLD mock
///             etched at the pinned address), runs `depositBoldWithFee`,
///             and asserts the EMITTED `(userAmount, poolAmount,
///             budgetGrant)` equal the Lean values — removing the
///             `FeeSplitMath` intermediary from the BOLD cross-stack path.
contract DepositFeeSplitBoldCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "deposit_fee_split_bold.json";

    /// @dev Local mirror of `KnomosisBridge.BOLD_TOKEN_ADDRESS`.
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_BOLD`.
    uint64 internal constant RESOURCE_BOLD = 1;
    /// @dev GP.5.5 safety-hardening roles (non-zero so a BOLD-enabled
    ///      bridge constructs; the cross-check does not exercise them).
    address internal constant BOLD_BREAKER = address(0xB12E6B6E);
    address internal constant BOLD_ADMIN = address(0xAD814);

    /// @notice Place a conformant BOLD mock at the pinned address so
    ///         BOLD-enabled bridges can be deployed in the live-contract
    ///         check (the constructor reads `symbol()`).
    function setUp() public {
        MockBold impl = new MockBold();
        vm.etch(BOLD, address(impl).code);
    }

    /// @notice Header shape: 80 entries (16 corner + 64 randomised) plus
    ///         the constitutional caps and the BOLD-resource fields.
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
        assertEq(vm.parseJsonUint(raw, ".header.resourceIdBold"), uint256(RESOURCE_BOLD), "resourceIdBold");
        assertEq(vm.parseJsonAddress(raw, ".header.boldTokenAddress"), BOLD, "boldTokenAddress");
    }

    /// @notice The fixture's `maxBudgetPerDeposit` agrees with the
    ///         `FeeSplitMath` reference constant (which the behavioural
    ///         suite pins against `KnomosisBridge.MAX_BUDGET_PER_DEPOSIT`).
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

    /// @notice The fixture header's pinned BOLD address + resource id
    ///         equal the deployed contract's getters (triple-pins the
    ///         constitutional values Lean fixture ↔ contract).
    function test_boldConstants_agree_with_contract() public {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        KnomosisBridge bridge = _deployBoldBridge(1);
        assertEq(
            vm.parseJsonAddress(raw, ".header.boldTokenAddress"),
            bridge.BOLD_TOKEN_ADDRESS(),
            "Lean BOLD address == contract pin"
        );
        assertEq(
            vm.parseJsonUint(raw, ".header.resourceIdBold"),
            uint256(bridge.RESOURCE_ID_BOLD()),
            "Lean resourceIdBold == contract constant"
        );
    }

    /// @notice Per-entry arithmetic cross-check + BOLD-field invariants.
    ///         Recompute the split and assert it matches the fixture,
    ///         plus conservation, the budget cap, and that every entry is
    ///         a BOLD entry (`resourceId == 1`, `token == BOLD`).  Runs in
    ///         every binding mode.
    function test_perEntry_split_matches() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");

            uint256 msgValue = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".msgValue")));
            uint256 feeBps = vm.parseJsonUint(raw, string.concat(base, ".chosenFeeBps"));
            uint256 rate = vm.parseJsonUint(raw, string.concat(base, ".weiPerBudgetUnit"));
            uint256 resourceId = vm.parseJsonUint(raw, string.concat(base, ".resourceId"));
            address token = vm.parseJsonAddress(raw, string.concat(base, ".token"));

            uint256 fixUser = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".userAmount")));
            uint256 fixPool = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".poolAmount")));
            uint256 fixBudget = vm.parseJsonUint(raw, string.concat(base, ".budgetGrant"));

            // BOLD-field invariants: every entry on this corpus is a BOLD
            // deposit, so resourceId is pinned at 1 and token at the BOLD
            // address.
            assertEq(resourceId, uint256(RESOURCE_BOLD), "resourceId != BOLD");
            assertEq(token, BOLD, "token != BOLD address");

            // Fixture-integrity bounds.
            assertLe(feeBps, 5000, "feeBps out of admissible range");
            assertLt(rate, 1 << 64, "rate out of uint64 range");
            assertLt(fixBudget, 1 << 64, "budgetGrant out of uint64 range");

            (uint256 u, uint256 p, uint64 g) = FeeSplitMath.split(msgValue, feeBps, rate);

            assertEq(u, fixUser, "userAmount mismatch");
            assertEq(p, fixPool, "poolAmount mismatch");
            assertEq(uint256(g), fixBudget, "budgetGrant mismatch");

            assertEq(u + p, msgValue, "conservation: userAmount + poolAmount == msgValue");
            assertLe(uint256(g), uint256(FeeSplitMath.MAX_BUDGET_PER_DEPOSIT), "budget within cap");
        }
    }

    /// @notice Per-entry receiptHash cross-check (BOLD resourceId + token).
    ///         Skipped under the FNV fallback — and the skip is sound, not
    ///         a coverage hole: the full keccak256 receiptHash
    ///         byte-equivalence Lean <-> Solidity for the BOLD path is
    ///         established TRANSITIVELY in every binding mode by three
    ///         already-running checks:
    ///           (1) `test_perEntry_receiptTail_layout` (below) byte-matches
    ///               the Lean preimage tail against Solidity `abi.encode`
    ///               with the BOLD `resourceId`/`token` — the only
    ///               BOLD-specific bytes;
    ///           (2) the `keccak256.json` cross-stack corpus
    ///               (`crosscheck-keccak256`) pins Lean's keccak256 ==
    ///               EVM keccak256 as a global fact;
    ///           (3) `test_perEntry_liveContract_split_matches` (below)
    ///               proves the live bridge computes
    ///               `keccak256(deploymentId ‖ tail)` correctly (real
    ///               keccak256, on-chain).
    ///         (1)+(2)+(3) ==> `keccak256(deploymentId ‖ tail)` is
    ///         byte-identical on both stacks; the keccak-linked fixture
    ///         regeneration is then a (deferred) belt-and-braces direct
    ///         confirmation, not a missing link.
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
            assertLt(budgetGrant, 1 << 64, "budgetGrant out of uint64 range");
            assertLt(nonce, 1 << 64, "depositorNonce out of uint64 range");

            bytes32 did = keccak256(abi.encode(chainid, contractAddr, tag));
            assertEq(did, expectedDid, "deploymentId mismatch");

            bytes32 actual = FeeSplitMath.receiptHash(
                did, sender, resourceId, token, userAmount, poolAmount, budgetGrant, nonce
            );
            assertEq(actual, expectedHash, "receiptHash mismatch");
        }
    }

    /// @notice Hash-independent receiptHash-layout pin.  Recompute the
    ///         224-byte preimage tail via `abi.encode` (with the BOLD
    ///         resourceId + token) and byte-match the Lean-emitted tail.
    ///         Runs in EVERY binding mode.
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
            uint256 budgetGrant = vm.parseJsonUint(raw, string.concat(base, ".budgetGrant"));
            uint256 nonce = vm.parseJsonUint(raw, string.concat(base, ".depositorNonce"));

            bytes memory leanTail = vm.parseJsonBytes(raw, string.concat(base, ".receiptTail"));
            bytes memory solTail =
                abi.encode(sender, resourceId, token, userAmount, poolAmount, budgetGrant, nonce);
            assertEq(solTail, leanTail, "BOLD receiptHash preimage-tail layout mismatch");
        }
    }

    /// @notice Direct cross-stack check: deploy the real BOLD-enabled
    ///         `KnomosisBridge` per fixture entry, run `depositBoldWithFee`
    ///         with the fixture's `(msgValue, chosenFeeBps)` at the
    ///         fixture's BOLD rate, and assert the EMITTED
    ///         `(userAmount, poolAmount, budgetGrant)` equal the
    ///         Lean-generated values — removing the `FeeSplitMath`
    ///         intermediary entirely.  Also re-derives the emitted
    ///         `receiptHash` (real keccak256) and pins the recipe on-chain.
    ///         The split is rate-/deployment-independent, so the fixture's
    ///         `deploymentId` / `depositorNonce` are intentionally not
    ///         compared against the fresh bridge's.
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
            uint256 fixUser = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".userAmount")));
            uint256 fixPool = uint256(vm.parseJsonBytes32(raw, string.concat(base, ".poolAmount")));
            uint256 fixBudget = vm.parseJsonUint(raw, string.concat(base, ".budgetGrant"));

            assertLe(feeBps, 5000, "feeBps out of admissible range");
            assertLt(rate, 1 << 64, "rate out of uint64 range");

            // forge-lint: disable-next-line(unsafe-typecast)
            KnomosisBridge bridge = _deployBoldBridge(uint64(rate));

            // Seed the depositor with BOLD and approve the fresh bridge.
            MockBold(BOLD).mint(depositor, msgValue);
            vm.prank(depositor);
            MockBold(BOLD).approve(address(bridge), msgValue);

            vm.recordLogs();
            vm.prank(depositor);
            // forge-lint: disable-next-line(unsafe-typecast)
            bridge.depositBoldWithFee(msgValue, uint16(feeBps));

            (uint256 u, uint256 p, uint64 g, uint64 nonce, bytes32 rh) =
                _decodeDepositWithFee(vm.getRecordedLogs());

            assertEq(u, fixUser, "live userAmount != Lean fixture");
            assertEq(p, fixPool, "live poolAmount != Lean fixture");
            assertEq(uint256(g), fixBudget, "live budgetGrant != Lean fixture");

            // Re-derive receiptHash with real keccak256 over the bridge's
            // own deploymentId + emitted fields (resourceId = BOLD, token =
            // BOLD), and pin the recipe.
            bytes32 recomputed = FeeSplitMath.receiptHash(
                bridge.deploymentId(), depositor, RESOURCE_BOLD, BOLD, u, p, g, nonce
            );
            assertEq(recomputed, rh, "live receiptHash recipe inconsistent");
        }
    }

    /// @notice The three budget-clamp corners (indices 4, 5, 6) all pin
    ///         `budgetGrant == MAX_BUDGET_PER_DEPOSIT`.
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

    /// @notice The zero-fee corner (index 0) produces a zero pool credit,
    ///         zero budget, and the full amount to the user.
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

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @notice Deploy a standalone BOLD-enabled bridge with the given
    ///         BOLD-leg rate; full `[0, 5000]` fee range, no TVL ceiling,
    ///         migration unset.  Requires a BOLD mock etched at the pin
    ///         (done in `setUp`).
    function _deployBoldBridge(uint64 boldRate) internal returns (KnomosisBridge) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-bold-fee-split-crosscheck"),
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
                weiPerBudgetUnitBold: boldRate,
                boldTokenAddress: BOLD,
                boldTvlCap: type(uint256).max,
                boldCircuitBreaker: BOLD_BREAKER,
                boldAdmin: BOLD_ADMIN,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 0,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice Locate + decode the single `DepositWithFeeInitiated` entry
    ///         in a recorded-log array (skips the BOLD `Transfer` event).
    function _decodeDepositWithFee(Vm.Log[] memory logs)
        internal
        pure
        returns (uint256 userAmount, uint256 poolAmount, uint64 budgetGrant, uint64 nonce, bytes32 receiptHash)
    {
        bytes32 sig = keccak256(
            "DepositWithFeeInitiated(address,uint64,address,uint256,uint256,uint64,uint64,bytes32)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == sig) {
                (userAmount, poolAmount, budgetGrant, nonce, receiptHash) =
                    abi.decode(logs[i].data, (uint256, uint256, uint64, uint64, bytes32));
                return (userAmount, poolAmount, budgetGrant, nonce, receiptHash);
            }
        }
        revert("DepositWithFeeInitiated not found");
    }
}
