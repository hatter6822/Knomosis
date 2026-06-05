// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";
import {MockBold} from "test/utils/MockBold.sol";

/// @title AmmStorageTest
/// @notice Workstream GP.11.1 — the embedded ETH<->BOLD AMM's L1 state
///         variables, reserves, and the immutable seed-ratio cap.
///
/// @dev    GP.11.1 declared the two AMM reserve storage slots
///         (`ammReserveEth` / `ammReserveBold`), the immutable
///         `ammSeedRatioBps`, and the two constitutional caps
///         (`AMM_SWAP_FEE_BPS`, `MAX_AMM_SEED_RATIO_BPS`), plus the
///         constructor validation that pins the seed ratio under the cap.
///         This suite pins that GP.11.1 STORAGE surface: the caps are
///         pinned, the seed ratio is stored / validated over the whole
///         `uint16` domain, the reserves start at zero with NO write path
///         other than deposit seeding, the AMM state has no admin setter,
///         and the constructor guard ordering is fixed.  The acceptance
///         criterion GP.11.1.c — "`ammSeedRatioBps = 0` preserves v1.2
///         behaviour" — is pinned by `test_deposit_doesNotSeedReserves_whenDisabled`
///         (a disabled deposit seeds nothing and matches the
///         `FeeSplitMath` reference) and `test_depositSplit_unchanged_acrossRatios`
///         (the EMITTED `DepositWithFeeInitiated` split is ratio-invariant —
///         the seed ratio changes only the AMM reserve, never the canonical
///         deposit event).
///
///         GP.11.2 has since landed deposit-side SEEDING: a non-zero seed
///         ratio now moves `floor(poolAmount * ratio / 10000)` of every
///         fee-split deposit into the matching reserve.  The comprehensive
///         seeding behaviour (conservation fuzz, both legs, the
///         `AmmReserveSeeded` event, monotonic accumulation, the
///         reserve-subset-of-TVL invariant) lives in `AmmDepositSeeding.t.sol`;
///         this file keeps only minimal positive seeding sanity checks
///         (`test_deposit_seedsReserves_whenRatioNonZero`,
///         `test_boldDeposit_seedsReserve`,
///         `test_ammSeedRatio_immutable_reservesGrowAcrossDeposits`) so the
///         storage-surface tests stay self-contained.
contract AmmStorageTest is Test {
    address private alice = address(0xA1);

    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_NATIVE_ETH` (a contract
    ///      constant is not reachable via the type name from another
    ///      contract).
    uint64 private constant NATIVE_ETH = 0;

    /// @dev Mirror of `KnomosisBridge.BOLD_TOKEN_ADDRESS`.  A conformant
    ///      `MockBold` is etched here before a BOLD-enabled bridge is
    ///      deployed so the constructor's address pin + `symbol()`
    ///      cross-check pass (see `test/utils/MockBold.sol`).
    address private constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    /// @dev GP.5.5 BOLD safety roles.  A BOLD-enabled deployment requires
    ///      both non-zero and distinct; the AMM-storage tests do not
    ///      exercise the circuit breaker, so any fixed addresses suffice.
    address private constant BOLD_BREAKER = address(0xB12E6B6E);
    address private constant BOLD_ADMIN = address(0xAD814);

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
        return _deployFull(5000, ammSeedRatioBps);
    }

    /// @notice As `_deploy`, but with a caller-chosen `maxFeeBps`, so the
    ///         constructor-guard ordering test can violate the fee-cap and
    ///         the AMM-cap guards in the same deployment and observe which
    ///         one fires first.
    function _deployFull(uint16 maxFeeBps, uint16 ammSeedRatioBps)
        internal
        returns (KnomosisBridge)
    {
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
                maxFeeBps: maxFeeBps,
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

    /// @notice Place a fresh conformant `MockBold`'s runtime code at the
    ///         pinned BOLD address (resets its storage).  `vm.etch` copies
    ///         runtime code only, so the mock's `pure` `symbol()` survives
    ///         while balances are seeded after the etch via `mint`.
    function _etchBold() internal {
        MockBold impl = new MockBold();
        vm.etch(BOLD, address(impl).code);
    }

    /// @notice Deploy a BOLD-ENABLED bridge with a chosen `ammSeedRatioBps`.
    ///         Requires a BOLD mock etched at the pinned address first
    ///         (`_etchBold`).  Used to prove the BOLD deposit leg also
    ///         leaves `ammReserveBold` untouched at GP.11.1.
    function _deployBoldEnabled(uint16 ammSeedRatioBps) internal returns (KnomosisBridge) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-amm-storage-bold-test"),
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

    /// @notice Mint `amount` BOLD to `user` and approve `bridge` for it.
    function _mintApprove(KnomosisBridge bridge, address user, uint256 amount) internal {
        MockBold(BOLD).mint(user, amount);
        vm.prank(user);
        MockBold(BOLD).approve(address(bridge), amount);
    }

    /// @notice `vm.expectEmit` setup asserting `bridge` emits a
    ///         `DepositWithFeeInitiated` carrying exactly the given split.
    ///         The per-bridge `receiptHash` is recomputed from the bridge's
    ///         own `deploymentId` + current nonce (it legitimately differs
    ///         between two deployments at different addresses; the split
    ///         itself must not).
    function _expectSplitEmit(
        KnomosisBridge bridge,
        address user,
        uint256 userAmount,
        uint256 poolAmount,
        uint64 budgetGrant
    ) internal {
        uint64 nonce = bridge.depositNonce(user);
        bytes32 expectedHash = FeeSplitMath.receiptHash(
            bridge.deploymentId(),
            user,
            NATIVE_ETH,
            address(0),
            userAmount,
            poolAmount,
            budgetGrant,
            nonce
        );
        vm.expectEmit(true, true, true, true, address(bridge));
        emit DepositWithFeeInitiated(
            user, NATIVE_ETH, address(0), userAmount, poolAmount, budgetGrant, nonce, expectedHash
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

    /// @notice GP.11.2: a non-zero seed ratio now seeds the matching
    ///         reserve while the FULL deposit is still credited to TVL (the
    ///         seed is a reclassification of pool fee already inside the
    ///         escrow, not new value).  A minimal positive sanity check;
    ///         the exhaustive seeding behaviour lives in
    ///         `AmmDepositSeeding.t.sol`.
    function test_deposit_seedsReserves_whenRatioNonZero() public {
        KnomosisBridge bridge = _deploy(8000);

        uint256 value = 3 ether;
        uint16 feeBps = 2500;
        (, uint256 poolAmount,) = FeeSplitMath.split(value, feeBps, bridge.weiPerBudgetUnitEth());
        (uint256 ammSeed,) = FeeSplitMath.ammSeedSplit(poolAmount, 8000);
        assertGt(ammSeed, 0, "non-trivial seed expected at the max ratio");

        vm.prank(alice);
        bridge.depositETHWithFee{value: value}(feeBps);

        assertEq(
            bridge.totalLockedValue(),
            value,
            "TVL grows by the FULL deposit (the seed is reclassified, not new value)"
        );
        assertEq(bridge.ammReserveEth(), ammSeed, "AMM ETH reserve seeded at GP.11.2");
        assertEq(bridge.ammReserveBold(), 0, "AMM BOLD reserve untouched by an ETH deposit");
    }

    /// @notice The CANONICAL deposit event is ratio-invariant: two
    ///         deployments differing ONLY in `ammSeedRatioBps` emit the
    ///         IDENTICAL `DepositWithFeeInitiated` split
    ///         (`userAmount` / `poolAmount` / `budgetGrant`) and credit the
    ///         identical TVL.  The seed ratio changes only the AMM reserve
    ///         (disabled stays 0; max-seed seeds `poolAmount * 80%`) — i.e.
    ///         GP.11.2 seeding ADDS an `AmmReserveSeeded` log without ever
    ///         altering the depositor-facing event.  This is the
    ///         minimal-break property the cross-stack ingest decoders rely
    ///         on (the `acceptance criterion` GP.11.1.c, sharpened for
    ///         GP.11.2).
    function test_depositSplit_unchanged_acrossRatios() public {
        KnomosisBridge disabled = _deploy(0);
        KnomosisBridge maxSeed = _deploy(8000);

        uint256 value = 2 ether;
        uint16 feeBps = 1500;

        // The split depends only on (value, feeBps, rate) — identical
        // across the two deployments — so both MUST emit the same
        // (userAmount, poolAmount, budgetGrant).  Asserting the emitted
        // split on EACH deposit (not merely the resulting TVL) pins that
        // the seed ratio changes nothing the depositor observes; only the
        // per-deployment receiptHash differs (its deploymentId binds the
        // contract address), which `_expectSplitEmit` recomputes per bridge.
        (uint256 userAmount, uint256 poolAmount, uint64 budgetGrant) =
            FeeSplitMath.split(value, feeBps, disabled.weiPerBudgetUnitEth());

        _expectSplitEmit(disabled, alice, userAmount, poolAmount, budgetGrant);
        vm.prank(alice);
        disabled.depositETHWithFee{value: value}(feeBps);

        _expectSplitEmit(maxSeed, alice, userAmount, poolAmount, budgetGrant);
        vm.prank(alice);
        maxSeed.depositETHWithFee{value: value}(feeBps);

        assertEq(
            disabled.totalLockedValue(), maxSeed.totalLockedValue(), "identical TVL across ratios"
        );
        assertEq(disabled.totalLockedValue(), value, "TVL == full deposit on both");
        // The reserves now DIFFER: the seed ratio is the only observable
        // that changes — disabled never seeds; max-seed seeds 80% of the
        // pool fee.
        (uint256 maxSeedAmount,) = FeeSplitMath.ammSeedSplit(poolAmount, 8000);
        assertEq(disabled.ammReserveEth(), 0, "disabled never seeds the reserve");
        assertEq(maxSeed.ammReserveEth(), maxSeedAmount, "max-seed seeds 80% of the pool fee");
        assertGt(maxSeedAmount, 0, "the max-seed reserve genuinely diverged from disabled");
        assertEq(
            disabled.depositNonce(alice), maxSeed.depositNonce(alice), "identical nonce advance"
        );
    }

    // ------------------------------------------------------------------
    // Immutability of the seed RATIO across deposits (the `immutable`
    // keyword guarantees it at compile time; the reserves, by contrast,
    // grow with each GP.11.2 seed — the only AMM write path).
    // ------------------------------------------------------------------

    /// @notice `ammSeedRatioBps` is `immutable` (no setter can exist) and
    ///         stays fixed across deposits, while the matching reserve
    ///         grows by exactly the per-deposit seed each time — the seed
    ///         is the SOLE AMM write path, and it is deterministic in the
    ///         (fixed) ratio.
    function test_ammSeedRatio_immutable_reservesGrowAcrossDeposits() public {
        KnomosisBridge bridge = _deploy(5000);
        assertEq(bridge.ammSeedRatioBps(), 5000, "seed ratio set");

        // Three identical deposits: each seeds the same amount.
        (, uint256 poolAmount,) = FeeSplitMath.split(1 ether, 500, bridge.weiPerBudgetUnitEth());
        (uint256 seedPerDeposit,) = FeeSplitMath.ammSeedSplit(poolAmount, 5000);
        assertGt(seedPerDeposit, 0, "non-trivial per-deposit seed");

        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(alice);
            bridge.depositETHWithFee{value: 1 ether}(500);
        }

        assertEq(bridge.ammSeedRatioBps(), 5000, "seed ratio immutable across deposits");
        assertEq(bridge.ammReserveEth(), 3 * seedPerDeposit, "ETH reserve == 3 cumulative seeds");
        assertEq(bridge.ammReserveBold(), 0, "BOLD reserve untouched by ETH deposits");
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

    // ------------------------------------------------------------------
    // Immutability via the external surface — "cannot mutate post-deploy
    // even via admin functions" (the plan's GP.11.1 test criterion).
    // ------------------------------------------------------------------

    /// @notice The bridge exposes NO callable mutator for the AMM state.
    ///         `ammSeedRatioBps` is `immutable`, so a setter is impossible
    ///         at compile time; the two reserves are mutable storage but
    ///         have no write path at GP.11.1.  This probes a battery of
    ///         plausible AMM setter selectors via low-level `call` and
    ///         asserts every one is unroutable — the bridge has a
    ///         `receive()` but no `fallback()`, so a 4-byte (non-empty)
    ///         selector that matches no function reverts.  Mirrors
    ///         `KnomosisBridge.t.sol::test_no_admin_surface` for the AMM
    ///         surface specifically.
    function test_ammState_hasNoSetterSurface() public {
        KnomosisBridge bridge = _deploy(5000);

        bytes4[] memory forbidden = new bytes4[](8);
        forbidden[0] = bytes4(keccak256("setAmmReserveEth(uint256)"));
        forbidden[1] = bytes4(keccak256("setAmmReserveBold(uint256)"));
        forbidden[2] = bytes4(keccak256("setAmmSeedRatioBps(uint16)"));
        forbidden[3] = bytes4(keccak256("setAmmReserves(uint256,uint256)"));
        forbidden[4] = bytes4(keccak256("seedAmm(uint256,uint256)"));
        forbidden[5] = bytes4(keccak256("setAmmReserve(uint64,uint256)"));
        forbidden[6] = bytes4(keccak256("syncAmmReserves()"));
        forbidden[7] = bytes4(keccak256("setReserves(uint256,uint256)"));

        for (uint256 i = 0; i < forbidden.length; ++i) {
            (bool ok,) = address(bridge).call(abi.encodePacked(forbidden[i]));
            assertFalse(ok, "AMM mutator selector unexpectedly callable");
        }

        // The getters remain the only AMM surface and read unchanged.
        assertEq(bridge.ammSeedRatioBps(), 5000, "seed ratio unchanged");
        assertEq(bridge.ammReserveEth(), 0, "ETH reserve unchanged");
        assertEq(bridge.ammReserveBold(), 0, "BOLD reserve unchanged");
    }

    // ------------------------------------------------------------------
    // BOLD leg: a real BOLD deposit on a BOLD-ENABLED bridge seeds the
    // BOLD reserve only (the ETH-leg tests run BOLD-disabled).
    // ------------------------------------------------------------------

    /// @notice GP.11.2 on the BOLD leg: a `depositBoldWithFee` on a
    ///         BOLD-enabled bridge seeds the BOLD reserve by
    ///         `floor(poolAmount * ratio / 10000)` and leaves the ETH
    ///         reserve untouched, while the deposit credits the global and
    ///         per-BOLD TVL by the FULL amount.  Exercises the BOLD seeding
    ///         path the ETH-leg tests cannot; the exhaustive BOLD seeding
    ///         coverage lives in `AmmDepositSeeding.t.sol`.
    function test_boldDeposit_seedsReserve() public {
        _etchBold();
        KnomosisBridge bridge = _deployBoldEnabled(8000);

        uint256 amount = 5 ether; // 5e18 BOLD-wei
        uint16 feeBps = 2500; // 25% fee
        _mintApprove(bridge, alice, amount);

        (, uint256 poolAmount,) = FeeSplitMath.split(amount, feeBps, bridge.weiPerBudgetUnitBold());
        (uint256 ammSeed,) = FeeSplitMath.ammSeedSplit(poolAmount, 8000);
        assertGt(ammSeed, 0, "non-trivial BOLD seed expected");

        vm.prank(alice);
        bridge.depositBoldWithFee(amount, feeBps);

        assertEq(bridge.totalLockedValue(), amount, "BOLD deposit credits the full global TVL");
        assertEq(bridge.boldTotalLockedValue(), amount, "BOLD deposit credits the per-BOLD TVL");
        assertEq(bridge.ammReserveBold(), ammSeed, "BOLD reserve seeded at GP.11.2");
        assertEq(bridge.ammReserveEth(), 0, "ETH reserve untouched by a BOLD deposit");
    }

    // ------------------------------------------------------------------
    // Constructor-guard ordering pin.
    // ------------------------------------------------------------------

    /// @notice The fee-split validation runs BEFORE the AMM seed-ratio
    ///         validation in the constructor, so a deployment that violates
    ///         BOTH the fee cap and the AMM cap reverts with the FEE error
    ///         (`MaxFeeBpsExceedsCap`), not `AmmSeedRatioExceedsMax`.  Pins
    ///         the order so an accidental reordering that surfaces the wrong
    ///         diagnostic is caught (mirrors the GP.5.5 revert-ordering pins).
    function test_constructor_guardOrdering_feeBeforeAmm() public {
        // maxFeeBps = 6000 (> MAX_FEE_BPS_CAP = 5000) AND ammSeedRatioBps =
        // 9000 (> MAX_AMM_SEED_RATIO_BPS = 8000): both guards would trip; the
        // fee guard fires first.
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.MaxFeeBpsExceedsCap.selector, uint16(6000))
        );
        _deployFull(6000, 9000);
    }
}
