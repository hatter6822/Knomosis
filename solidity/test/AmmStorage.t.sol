// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";

/// @title AmmStorageTest
/// @notice Workstream GP.11.1 — the embedded ETH<->BOLD AMM's L1 state
///         variables, reserves, and the immutable seed-ratio cap.
///
/// @dev    GP.11.1 is purely additive: it declares the two AMM reserve
///         storage slots (`ammReserveEth` / `ammReserveBold`), the
///         immutable `ammSeedRatioBps`, and the two constitutional caps
///         (`AMM_SWAP_FEE_BPS`, `MAX_AMM_SEED_RATIO_BPS`), plus the
///         constructor validation that pins the seed ratio under the cap.
///         No deposit-seeding (GP.11.2) or swap (GP.11.3) logic ships
///         yet, so the reserves stay at 0 for the lifetime of a
///         GP.11.1-era deployment regardless of the seed ratio.  These
///         tests therefore assert exactly the GP.11.1 surface: the caps
///         are pinned, the seed ratio is stored / validated, the reserves
///         start (and remain) zero, and the pre-v1.3 deposit behaviour is
///         preserved unchanged.  The acceptance criterion (GP.11.1.c —
///         "`ammSeedRatioBps = 0` preserves v1.2 behaviour") is pinned by
///         `test_deposit_doesNotSeedReserves_whenDisabled` and the
///         cross-ratio `test_v1_2_depositSplit_unchanged_acrossRatios`.
contract AmmStorageTest is Test {
    address private alice = address(0xA1);

    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_NATIVE_ETH` (a contract
    ///      constant is not reachable via the type name from another
    ///      contract).
    uint64 private constant NATIVE_ETH = 0;

    /// @dev Local copy of the contract event for `vm.expectEmit`.
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

    function setUp() public {
        vm.deal(alice, type(uint128).max);
    }

    // ------------------------------------------------------------------
    // Deployment helper
    // ------------------------------------------------------------------

    /// @notice Deploy a standalone, BOLD-disabled bridge with a chosen
    ///         `ammSeedRatioBps`.  The fee-split parameters are permissive
    ///         (full `[0, MAX_FEE_BPS_CAP]` range, a realistic 1e9 wei/unit
    ///         rate, no TVL ceiling) so `depositETHWithFee` works on a
    ///         fresh deployment, and `migration == address(0)` keeps the
    ///         `circuitOpen` breaker open.
    function _deploy(uint16 ammSeedRatioBps) internal returns (KnomosisBridge) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-amm-storage-test"),
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

    // ------------------------------------------------------------------
    // GP.11.1.a / GP.11.1.b — constitutional caps are pinned
    // ------------------------------------------------------------------

    /// @notice The two embedded-AMM compile-time caps carry their
    ///         canonical values.  This is the runtime half of the
    ///         two-layer cap protection; the source half is the GP.5.2
    ///         `scripts/audit_compile_time_caps.sh` gate (which now also
    ///         pins these two constants).
    function test_ammCompileTimeCaps_pinned() public {
        KnomosisBridge bridge = _deploy(0);
        assertEq(bridge.AMM_SWAP_FEE_BPS(), 30, "AMM_SWAP_FEE_BPS == 30 bps (0.30%)");
        assertEq(bridge.MAX_AMM_SEED_RATIO_BPS(), 8000, "MAX_AMM_SEED_RATIO_BPS == 8000 bps (80%)");
    }

    // ------------------------------------------------------------------
    // GP.11.1.b — seed ratio storage + constructor validation
    // ------------------------------------------------------------------

    /// @notice An in-range seed ratio is stored verbatim and surfaced
    ///         through the public immutable getter.
    function test_ammSeedRatioBps_storedExactly() public {
        KnomosisBridge bridge = _deploy(4321);
        assertEq(bridge.ammSeedRatioBps(), 4321, "ammSeedRatioBps stored exactly");
    }

    /// @notice A zero seed ratio is admissible: it disables the AMM at
    ///         construction.  The getter reads 0 and both reserves start
    ///         empty.
    function test_ammSeedRatioBps_zero_disablesAmm() public {
        KnomosisBridge bridge = _deploy(0);
        assertEq(bridge.ammSeedRatioBps(), 0, "ammSeedRatioBps == 0 (AMM disabled)");
        assertEq(bridge.ammReserveEth(), 0, "ammReserveEth starts 0");
        assertEq(bridge.ammReserveBold(), 0, "ammReserveBold starts 0");
    }

    /// @notice The cap boundary itself (8000 bps == MAX) is accepted; the
    ///         constructor guard is `>` (strict), not `>=`.
    function test_ammSeedRatioBps_maxAccepted() public {
        KnomosisBridge bridge = _deploy(8000);
        assertEq(bridge.ammSeedRatioBps(), 8000, "MAX_AMM_SEED_RATIO_BPS accepted at the boundary");
        assertEq(bridge.ammSeedRatioBps(), bridge.MAX_AMM_SEED_RATIO_BPS(), "stored == cap");
    }

    /// @notice One bps above the cap reverts `AmmSeedRatioExceedsMax`,
    ///         carrying the offending value.
    function test_constructor_revertsAboveMax() public {
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.AmmSeedRatioExceedsMax.selector, uint16(8001))
        );
        _deploy(8001);
    }

    /// @notice The `uint16` ceiling (65535) reverts identically — there
    ///         is no wraparound or silent acceptance of large ratios.
    function test_constructor_revertsAtUint16Max() public {
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.AmmSeedRatioExceedsMax.selector, type(uint16).max)
        );
        _deploy(type(uint16).max);
    }

    // ------------------------------------------------------------------
    // GP.11.1.a — reserves start at zero and have no direct setter
    // ------------------------------------------------------------------

    /// @notice Both AMM reserves are zero on a fresh deployment,
    ///         independent of the configured seed ratio (no deposit has
    ///         occurred yet, and there is no constructor-side seeding).
    function test_ammReserves_startAtZero() public {
        KnomosisBridge disabled = _deploy(0);
        assertEq(disabled.ammReserveEth(), 0, "disabled: ETH reserve 0");
        assertEq(disabled.ammReserveBold(), 0, "disabled: BOLD reserve 0");

        KnomosisBridge enabled = _deploy(5000);
        assertEq(enabled.ammReserveEth(), 0, "enabled: ETH reserve 0 (no deposit yet)");
        assertEq(enabled.ammReserveBold(), 0, "enabled: BOLD reserve 0 (no deposit yet)");
    }

    // ------------------------------------------------------------------
    // GP.11.1.c — `ammSeedRatioBps = 0` preserves v1.2 behaviour
    // ------------------------------------------------------------------

    /// @notice With the AMM disabled, a fee-split deposit behaves exactly
    ///         as in v1.2: the emitted split matches the `FeeSplitMath`
    ///         reference, TVL grows by the full deposit, the per-depositor
    ///         nonce advances, and neither reserve is touched.
    function test_deposit_doesNotSeedReserves_whenDisabled() public {
        KnomosisBridge bridge = _deploy(0);

        uint256 value = 1 ether;
        uint16 feeBps = 1000; // 10%
        (uint256 userAmount, uint256 poolAmount, uint64 budgetGrant) =
            FeeSplitMath.split(value, feeBps, bridge.weiPerBudgetUnitEth());

        uint64 nonce = bridge.depositNonce(alice);
        bytes32 expectedHash = FeeSplitMath.receiptHash(
            bridge.deploymentId(),
            alice,
            NATIVE_ETH,
            address(0),
            userAmount,
            poolAmount,
            budgetGrant,
            nonce
        );

        vm.expectEmit(true, true, true, true, address(bridge));
        emit DepositWithFeeInitiated(
            alice, NATIVE_ETH, address(0), userAmount, poolAmount, budgetGrant, nonce, expectedHash
        );
        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);

        assertEq(bridge.totalLockedValue(), value, "TVL grows by the FULL deposit (v1.2 behaviour)");
        assertEq(bridge.depositNonce(alice), nonce + 1, "nonce advanced");
        assertEq(bridge.ammReserveEth(), 0, "AMM ETH reserve untouched (disabled)");
        assertEq(bridge.ammReserveBold(), 0, "AMM BOLD reserve untouched (disabled)");
    }

    /// @notice GP.11.1 scope boundary: even with a NON-zero seed ratio,
    ///         no reserve is seeded yet — deposit-side seeding is GP.11.2.
    ///         A deposit therefore behaves identically to the disabled
    ///         case (full TVL credit, reserves stay 0).  This documents
    ///         that GP.11.1 alone introduces no behavioural change.
    function test_deposit_doesNotSeedReserves_whenRatioNonZero() public {
        KnomosisBridge bridge = _deploy(8000);

        uint256 value = 3 ether;
        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(2500);

        assertEq(
            bridge.totalLockedValue(),
            value,
            "TVL grows by the FULL deposit (no AMM seeding at GP.11.1)"
        );
        assertEq(bridge.ammReserveEth(), 0, "AMM ETH reserve NOT seeded at GP.11.1");
        assertEq(bridge.ammReserveBold(), 0, "AMM BOLD reserve NOT seeded at GP.11.1");
    }

    /// @notice Two deployments differing ONLY in `ammSeedRatioBps` produce
    ///         byte-identical observable deposit outcomes at GP.11.1 — the
    ///         strong "no behavioural change" guarantee across the whole
    ///         admissible ratio range.
    function test_v1_2_depositSplit_unchanged_acrossRatios() public {
        KnomosisBridge disabled = _deploy(0);
        KnomosisBridge maxSeed = _deploy(8000);

        uint256 value = 2 ether;
        uint16 feeBps = 1500;

        vm.prank(alice);
        disabled.depositETHWithFee{value: value}(feeBps);
        vm.prank(alice);
        maxSeed.depositETHWithFee{value: value}(feeBps);

        assertEq(
            disabled.totalLockedValue(), maxSeed.totalLockedValue(), "identical TVL across ratios"
        );
        assertEq(disabled.totalLockedValue(), value, "TVL == full deposit on both");
        assertEq(
            disabled.ammReserveEth(), maxSeed.ammReserveEth(), "identical ETH reserve (both 0)"
        );
        assertEq(disabled.ammReserveEth(), 0, "reserves untouched on both");
        assertEq(
            disabled.depositNonce(alice), maxSeed.depositNonce(alice), "identical nonce advance"
        );
    }

    // ------------------------------------------------------------------
    // Immutability: the seed ratio is fixed and the reserves have no
    // write path at GP.11.1 (the `immutable` keyword guarantees the
    // former at compile time; the latter is shown across repeated
    // deposits).
    // ------------------------------------------------------------------

    /// @notice `ammSeedRatioBps` is `immutable` (no setter can exist), and
    ///         the reserves are not mutated by any GP.11.1 path: the
    ///         seed ratio and both reserves are unchanged across several
    ///         deposits.
    function test_ammState_immutableAcrossDeposits() public {
        KnomosisBridge bridge = _deploy(5000);
        assertEq(bridge.ammSeedRatioBps(), 5000, "seed ratio set");

        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(alice);
            bridge.depositETHWithFee{value: 1 ether}(500);
        }

        assertEq(bridge.ammSeedRatioBps(), 5000, "seed ratio immutable across deposits");
        assertEq(bridge.ammReserveEth(), 0, "ETH reserve unchanged (no write path at GP.11.1)");
        assertEq(bridge.ammReserveBold(), 0, "BOLD reserve unchanged (no write path at GP.11.1)");
        assertEq(bridge.totalLockedValue(), 3 ether, "three deposits all credited to TVL");
    }

    // ------------------------------------------------------------------
    // Fuzz: the constructor validation is total over the whole `uint16`
    // domain — accept iff `<= MAX_AMM_SEED_RATIO_BPS`, revert otherwise.
    // ------------------------------------------------------------------

    /// @notice Any ratio within `[0, MAX_AMM_SEED_RATIO_BPS]` deploys and
    ///         stores the exact value; the reserves start empty.
    function testFuzz_constructor_withinCap_accepted(uint16 ratio) public {
        ratio = uint16(bound(uint256(ratio), 0, 8000));
        KnomosisBridge bridge = _deploy(ratio);
        assertEq(bridge.ammSeedRatioBps(), ratio, "in-range ratio stored exactly");
        assertEq(bridge.ammReserveEth(), 0, "ETH reserve starts 0");
        assertEq(bridge.ammReserveBold(), 0, "BOLD reserve starts 0");
    }

    /// @notice Any ratio strictly above the cap reverts
    ///         `AmmSeedRatioExceedsMax` carrying the offending value —
    ///         across the entire `(MAX, uint16Max]` range.
    function testFuzz_constructor_aboveCap_reverts(uint16 ratio) public {
        ratio = uint16(bound(uint256(ratio), 8001, type(uint16).max));
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.AmmSeedRatioExceedsMax.selector, ratio)
        );
        _deploy(ratio);
    }
}
