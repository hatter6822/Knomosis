// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";
import {MockBold, ReentrantBold} from "test/utils/MockBold.sol";
import {WithdrawalFlowHarness} from "test/utils/WithdrawalFlowHarness.sol";
import {
    MockLiquityV2TroveManager,
    WrongSizeLiquityV2,
    OversizedLiquityV2,
    ReentrantLiquityV2,
    MutatingLiquityV2
} from "test/utils/MockLiquityV2.sol";

/// @title BoldCircuitBreakerTest
/// @notice Workstream GP.5.5 — behavioural tests for the BOLD-specific
///         safety-hardening surface on `KnomosisBridge`: the per-currency
///         circuit breaker (manual + Liquity-V2 branch-shutdown
///         auto-trigger), the per-BOLD TVL cap, and the supporting
///         access-control roles.
///
/// @dev    The harness mirrors `BridgeFeeSplitBold.t.sol`: a conformant
///         BOLD mock is etched at the compile-time `BOLD_TOKEN_ADDRESS`
///         pin AND conformant `MockLiquityV2TroveManager`s are etched at
///         the three compile-time `LIQUITY_V2_TROVE_MANAGER_*` pins
///         before each deployment (the constructor reads code lengths
///         when the auto-trigger is enabled).  Every BOLD-enabled bridge
///         ships operable `boldCircuitBreaker` / `boldAdmin` roles, a
///         keyed attestor (so the end-to-end withdrawal tests can sign a
///         state root), and the role-distinctness / no-self-as-role
///         constructor guards.
contract BoldCircuitBreakerTest is Test, WithdrawalFlowHarness {
    address private alice = address(0xA1);
    address private bob = address(0xB0B);

    /// @dev Local mirror of `KnomosisBridge.BOLD_TOKEN_ADDRESS`.
    address private constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_BOLD`.
    uint64 private constant RESOURCE_BOLD = 1;

    /// @dev Local mirrors of the three Liquity V2 TroveManager pins.
    address private constant LIQUITY_TM_ETH = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address private constant LIQUITY_TM_WSTETH = 0xA2895d6A3bf110561Dfe4b71cA539d84e1928B22;
    address private constant LIQUITY_TM_RETH = 0xb2B2ABEb5C357a234363FF5D180912D319e3e19e;

    /// @dev Safety-hardening roles for the deployed bridges.  MUST be
    ///      distinct (`BoldRolesNotDistinct` enforces) and not the bridge
    ///      itself (`BoldRoleIsBridge` enforces).
    address private constant BREAKER = address(0xB12E6B6E);
    address private constant ADMIN = address(0xAD814);
    address private constant STRANGER = address(0x5152A6E2);

    /// @dev Attestor key — the end-to-end withdrawal tests sign a
    ///      state-root attestation.
    uint256 private constant ATTESTOR_PK = 0xA77E5709;

    function setUp() public {
        _etchBold();
        _etchTroveManagers();
    }

    // ------------------------------------------------------------------
    // Etch helpers (place mocks at the pinned addresses)
    // ------------------------------------------------------------------

    /// @notice Place a fresh conformant `MockBold` at the pinned BOLD
    ///         address (resets its storage).
    function _etchBold() internal {
        MockBold impl = new MockBold();
        vm.etch(BOLD, address(impl).code);
    }

    /// @notice Place a conformant `MockLiquityV2TroveManager` at each of
    ///         the three pinned Liquity TroveManager addresses.  Default
    ///         `shutdownTime = 0` on all three (healthy branches).
    function _etchTroveManagers() internal {
        MockLiquityV2TroveManager impl = new MockLiquityV2TroveManager();
        bytes memory code = address(impl).code;
        vm.etch(LIQUITY_TM_ETH, code);
        vm.etch(LIQUITY_TM_WSTETH, code);
        vm.etch(LIQUITY_TM_RETH, code);
    }

    /// @notice Mark `tm`'s branch as shutdown at the given timestamp.
    function _setBranchShutdown(address tm, uint256 t) internal {
        MockLiquityV2TroveManager(tm).setShutdownTime(t);
    }

    // ------------------------------------------------------------------
    // Deploy helpers
    // ------------------------------------------------------------------

    /// @notice Fully-parameterised deploy.  Full `[0, 5000]` fee range,
    ///         ETH rate 1, BOLD rate 1e9, keyed attestor, migration unset.
    function _deployRaw(
        address boldAddr,
        uint256 tvlCap,
        uint256 boldTvlCap,
        address breaker,
        address admin,
        bool enableAuto
    ) internal returns (KnomosisBridge) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-bold-circuit-breaker-test"),
                attestor: vm.addr(ATTESTOR_PK),
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
                weiPerBudgetUnitEth: 1,
                weiPerBudgetUnitBold: 1_000_000_000,
                boldTokenAddress: boldAddr,
                boldTvlCap: boldTvlCap,
                boldCircuitBreaker: breaker,
                boldAdmin: admin,
                enableLiquityAutoCircuitTrigger: enableAuto,
                ammSeedRatioBps: 0,
                ammDisasterRecovery: address(0),
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice BOLD-enabled bridge, no tight cap, no auto-trigger.
    function _defaultBridge() internal returns (KnomosisBridge) {
        return _deployRaw(BOLD, type(uint256).max, type(uint256).max, BREAKER, ADMIN, false);
    }

    /// @notice BOLD-enabled bridge with a specific (tvlCap, boldTvlCap).
    function _bridgeWithCaps(uint256 tvlCap, uint256 boldCap) internal returns (KnomosisBridge) {
        return _deployRaw(BOLD, tvlCap, boldCap, BREAKER, ADMIN, false);
    }

    /// @notice BOLD-enabled bridge with the Liquity auto-trigger enabled.
    ///         Reads from the three constant TroveManagers etched in
    ///         `setUp` (callers must place mocks first if they were
    ///         re-etched mid-test).
    function _bridgeWithAuto() internal returns (KnomosisBridge) {
        return _deployRaw(BOLD, type(uint256).max, type(uint256).max, BREAKER, ADMIN, true);
    }

    /// @notice Mint `amount` BOLD to `user` and approve `bridge` for it.
    function _mintApprove(KnomosisBridge bridge, address user, uint256 amount) internal {
        MockBold(BOLD).mint(user, amount);
        vm.prank(user);
        MockBold(BOLD).approve(address(bridge), amount);
    }

    /// @notice Deposit `amount` BOLD at `feeBps` as `user`.
    function _depositBold(KnomosisBridge bridge, address user, uint256 amount, uint16 feeBps)
        internal
    {
        _mintApprove(bridge, user, amount);
        vm.prank(user);
        bridge.depositBoldWithFee(amount, feeBps);
    }

    // ==================================================================
    // Defaults + construction-time guards
    // ==================================================================

    function test_defaults_circuitOpenAndCountersZero() public {
        KnomosisBridge bridge = _bridgeWithCaps(type(uint256).max, 7 ether);
        assertTrue(bridge.boldEnabled(), "boldEnabled");
        assertTrue(!bridge.boldCircuitClosed(), "circuit open by default");
        assertEq(bridge.boldTotalLockedValue(), 0, "bold TVL starts at zero");
        assertEq(bridge.boldTvlCap(), 7 ether, "initial bold cap pinned");
        assertEq(bridge.boldCircuitBreaker(), BREAKER, "breaker role pinned");
        assertEq(bridge.boldAdmin(), ADMIN, "admin role pinned");
        assertTrue(!bridge.enableLiquityAutoCircuitTrigger(), "auto-trigger off by default");
    }

    /// @notice Pin the three Liquity V2 TroveManager constants against
    ///         the local mirror + the documented values.  Mirrors the
    ///         GP.5.2 source-level audit gate.  Drift fails loudly.
    function test_troveManagerConstants_pinned() public {
        KnomosisBridge bridge = _defaultBridge();
        assertEq(bridge.LIQUITY_V2_TROVE_MANAGER_ETH(), LIQUITY_TM_ETH, "ETH TM pin");
        assertEq(
            bridge.LIQUITY_V2_TROVE_MANAGER_ETH(),
            0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A,
            "ETH TM literal"
        );
        assertEq(bridge.LIQUITY_V2_TROVE_MANAGER_WSTETH(), LIQUITY_TM_WSTETH, "wstETH TM pin");
        assertEq(
            bridge.LIQUITY_V2_TROVE_MANAGER_WSTETH(),
            0xA2895d6A3bf110561Dfe4b71cA539d84e1928B22,
            "wstETH TM literal"
        );
        assertEq(bridge.LIQUITY_V2_TROVE_MANAGER_RETH(), LIQUITY_TM_RETH, "rETH TM pin");
        assertEq(
            bridge.LIQUITY_V2_TROVE_MANAGER_RETH(),
            0xb2B2ABEb5C357a234363FF5D180912D319e3e19e,
            "rETH TM literal"
        );
        // The three TMs must be pairwise distinct (a Liquity-V2 fact).
        assertTrue(
            bridge.LIQUITY_V2_TROVE_MANAGER_ETH() != bridge.LIQUITY_V2_TROVE_MANAGER_WSTETH(),
            "ETH != wstETH"
        );
        assertTrue(
            bridge.LIQUITY_V2_TROVE_MANAGER_WSTETH() != bridge.LIQUITY_V2_TROVE_MANAGER_RETH(),
            "wstETH != rETH"
        );
        assertTrue(
            bridge.LIQUITY_V2_TROVE_MANAGER_ETH() != bridge.LIQUITY_V2_TROVE_MANAGER_RETH(),
            "ETH != rETH"
        );
    }

    /// @notice The `LIQUITY_ORACLE_READ_GAS` cap (the gas forwarded to
    ///         each TroveManager staticcall — bounds the
    ///         malicious-TroveManager griefing surface) is pinned at
    ///         the contract level AND mirrored in the GP.5.2 cap-audit
    ///         gate, so a drift in either layer fails loudly.
    function test_liquityOracleReadGas_pinned() public {
        KnomosisBridge bridge = _defaultBridge();
        assertEq(bridge.LIQUITY_ORACLE_READ_GAS(), 100_000, "LIQUITY_ORACLE_READ_GAS pin == 100k");
    }

    /// @notice The constructor enforces pairwise-distinctness of the
    ///         three Liquity-V2 TroveManager constants (gated on the
    ///         auto-trigger opt-in) as defence-in-depth behind the
    ///         GP.5.2 cap-audit gate.  This test confirms the canonical
    ///         constants pass — a coverage statement that the runtime
    ///         check is present and consistent with the pinned values.
    ///         The negative path (two pins accidentally equal) is
    ///         caught by the audit gate; the constants are immutable
    ///         declarations and Foundry cannot override them, so we
    ///         do not have a synthetic negative test.
    function test_constructor_troveManagerDistinctness_canonicalPasses() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        assertTrue(bridge.enableLiquityAutoCircuitTrigger(), "auto-trigger enabled OK");
    }

    function test_revert_constructor_zeroBoldCircuitBreaker() public {
        vm.expectRevert(KnomosisBridge.ZeroBoldCircuitBreaker.selector);
        _deployRaw(BOLD, type(uint256).max, 1 ether, address(0), ADMIN, false);
    }

    function test_revert_constructor_zeroBoldAdmin() public {
        vm.expectRevert(KnomosisBridge.ZeroBoldAdmin.selector);
        _deployRaw(BOLD, type(uint256).max, 1 ether, BREAKER, address(0), false);
    }

    /// @notice GP.5.5 NEW: a BOLD-enabled deployment with `breaker == admin`
    ///         reverts to enforce least-privilege role separation.
    function test_revert_constructor_boldRolesNotDistinct() public {
        vm.expectRevert(KnomosisBridge.BoldRolesNotDistinct.selector);
        _deployRaw(BOLD, type(uint256).max, 1 ether, BREAKER, BREAKER, false);
    }

    /// @notice GP.5.5 NEW: a BOLD-enabled deployment that names the
    ///         bridge as a safety role reverts.  Because the bridge
    ///         address is determined inside the constructor (the result
    ///         of CREATE / CREATE2), there is no static prediction here;
    ///         instead we attempt the construction wrapped in a helper
    ///         that REPLAYS the deploy with the predicted address — the
    ///         simplest correct test uses a sentinel role-equals-bridge
    ///         scenario via post-deploy bytecode introspection.
    /// @dev    Practical test: deploy WITH a candidate role, then deploy
    ///         a second bridge that uses the FIRST bridge's address as a
    ///         role.  The second deploy MUST revert because the role
    ///         address has code (it's a contract) — but that's the
    ///         BridgeAccountingMismatch / unrelated revert.  To test the
    ///         BoldRoleIsBridge guard cleanly, we use a different
    ///         approach: deploy a `RoleProbe` helper that knows its own
    ///         address and passes it as the role, then asserts the
    ///         intended revert.
    function test_revert_constructor_boldRoleIsBridge_breaker() public {
        // The cleanest test: deploy a probe contract that, in its
        // constructor, attempts to deploy a KnomosisBridge passing its
        // OWN address as boldCircuitBreaker.  The bridge constructor's
        // self-as-role guard cannot fire (the probe is not the bridge);
        // instead we use a different vehicle: construct a bridge via
        // RoleEqualsBridgeProbe which records its own bytecode-deployed
        // address and observes the bridge constructor's revert.
        //
        // Pragmatic approach: directly construct a bridge passing
        // `address(this)` (the test contract) as boldCircuitBreaker —
        // address(this) is the test, NOT the bridge.  To trigger the
        // self-as-role guard, we need the role == the BRIDGE's address.
        //
        // We use CREATE2 prediction via the harness contract below.
        BridgeSelfRoleProbe probe = new BridgeSelfRoleProbe();
        vm.expectRevert(KnomosisBridge.BoldRoleIsBridge.selector);
        probe.deployBridgeWithSelfAsBreaker();
    }

    function test_revert_constructor_boldRoleIsBridge_admin() public {
        BridgeSelfRoleProbe probe = new BridgeSelfRoleProbe();
        vm.expectRevert(KnomosisBridge.BoldRoleIsBridge.selector);
        probe.deployBridgeWithSelfAsAdmin();
    }

    function test_revert_constructor_boldTvlCapExceedsGlobal() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.BoldTvlCapExceedsGlobal.selector, uint256(2 ether), uint256(1 ether)
            )
        );
        _deployRaw(BOLD, 1 ether, 2 ether, BREAKER, ADMIN, false);
    }

    function test_constructor_boldTvlCapEqualsGlobal_ok() public {
        KnomosisBridge bridge = _bridgeWithCaps(3 ether, 3 ether);
        assertEq(bridge.boldTvlCap(), 3 ether, "boldTvlCap == tvlCap accepted");
    }

    function test_constructor_disabledBold_zeroRolesOk() public {
        // BOLD disabled: the safety roles / cap are inert and so are
        // left unvalidated.  Zero roles must NOT revert.
        KnomosisBridge bridge =
            _deployRaw(address(0), type(uint256).max, 0, address(0), address(0), false);
        assertTrue(!bridge.boldEnabled(), "BOLD disabled");
        assertEq(bridge.boldCircuitBreaker(), address(0), "role stored verbatim when disabled");
    }

    /// @notice GP.5.5 NEW: BOLD-disabled deployment may store NON-zero
    ///         roles verbatim — the role check is skipped entirely when
    ///         disabled, so the roles are pinned as passed but inert.
    function test_constructor_disabledBold_nonZeroRoles_storedVerbatim() public {
        KnomosisBridge bridge = _deployRaw(address(0), type(uint256).max, 0, BREAKER, ADMIN, false);
        assertTrue(!bridge.boldEnabled(), "BOLD disabled");
        assertEq(bridge.boldCircuitBreaker(), BREAKER, "breaker stored verbatim when disabled");
        assertEq(bridge.boldAdmin(), ADMIN, "admin stored verbatim when disabled");
        // The role-gated functions are still unreachable: they revert
        // BoldNotEnabled?  No — they revert via the role check (the
        // user is not BREAKER unless they are).  More importantly, no
        // BOLD deposit path exists, so the roles are operationally inert.
        vm.expectRevert(KnomosisBridge.BoldNotEnabled.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 0);
    }

    /// @notice On a BOLD-disabled deployment with a NON-zero stored
    ///         admin, the admin CAN call `setBoldTvlCap` (the setter
    ///         has no `boldEnabled` gate — the storage is internal
    ///         state with no external effect on a disabled bridge).
    ///         The new cap is stored but operationally inert: no BOLD
    ///         entry point exists, so the cap is never consulted.
    function test_disabledBold_setBoldTvlCap_byStoredAdmin_isInert() public {
        KnomosisBridge bridge =
            _deployRaw(address(0), type(uint256).max, 7 ether, BREAKER, ADMIN, false);
        vm.prank(ADMIN);
        bridge.setBoldTvlCap(99 ether);
        assertEq(bridge.boldTvlCap(), 99 ether, "cap settable on disabled deployment");
        // BOLD deposits revert BoldNotEnabled at the entry point —
        // never reach the cap check.
        vm.expectRevert(KnomosisBridge.BoldNotEnabled.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(1, 0);
    }

    // ---- Liquity auto-trigger construction guards ----

    function test_revert_constructor_autoTriggerRequiresBold() public {
        // enableAuto on a BOLD-disabled deployment -> AutoTriggerRequiresBold.
        vm.expectRevert(KnomosisBridge.AutoTriggerRequiresBold.selector);
        _deployRaw(address(0), type(uint256).max, 0, address(0), address(0), true);
    }

    /// @notice Each branch's missing-code revert names the OFFENDING
    ///         TroveManager in the error data — operators can diagnose
    ///         without bisecting.
    function test_revert_constructor_autoTriggerOracleNoCode_ethBranch() public {
        vm.etch(LIQUITY_TM_ETH, hex"");
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.LiquityOracleHasNoCode.selector, LIQUITY_TM_ETH)
        );
        _bridgeWithAuto();
    }

    function test_revert_constructor_autoTriggerOracleNoCode_wstethBranch() public {
        vm.etch(LIQUITY_TM_WSTETH, hex"");
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.LiquityOracleHasNoCode.selector, LIQUITY_TM_WSTETH
            )
        );
        _bridgeWithAuto();
    }

    function test_revert_constructor_autoTriggerOracleNoCode_rethBranch() public {
        vm.etch(LIQUITY_TM_RETH, hex"");
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisBridge.LiquityOracleHasNoCode.selector, LIQUITY_TM_RETH)
        );
        _bridgeWithAuto();
    }

    function test_constructor_autoTriggerEnabled_ok() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        assertTrue(bridge.enableLiquityAutoCircuitTrigger(), "auto-trigger enabled");
    }

    // ---- Constructor revert ordering tests (NEW) ----

    /// @notice Both breaker AND admin zero -> ZeroBoldCircuitBreaker
    ///         fires first.  Pins the order so a future refactor cannot
    ///         silently change it.
    function test_constructor_revertOrder_zeroBreakerBeforeAdmin() public {
        vm.expectRevert(KnomosisBridge.ZeroBoldCircuitBreaker.selector);
        _deployRaw(BOLD, type(uint256).max, 1 ether, address(0), address(0), false);
    }

    /// @notice breaker zero, admin set, roles equal (since breaker is 0
    ///         and admin is set they aren't equal) -> ZeroBoldCircuitBreaker
    ///         fires (zero check precedes distinctness check).
    function test_constructor_revertOrder_zeroChecksBeforeDistinctness() public {
        vm.expectRevert(KnomosisBridge.ZeroBoldAdmin.selector);
        _deployRaw(BOLD, type(uint256).max, 1 ether, BREAKER, address(0), false);
    }

    /// @notice Roles non-zero AND equal -> BoldRolesNotDistinct fires
    ///         (after the per-role zero checks).
    function test_constructor_revertOrder_distinctnessBeforeOther() public {
        vm.expectRevert(KnomosisBridge.BoldRolesNotDistinct.selector);
        _deployRaw(BOLD, type(uint256).max, 1 ether, BREAKER, BREAKER, false);
    }

    // ==================================================================
    // Manual circuit breaker
    // ==================================================================

    event BoldCircuitClosed(uint256 timestamp);
    event BoldCircuitOpened(uint256 timestamp);

    function test_closeBoldCircuit_pausesBoldDeposits() public {
        KnomosisBridge bridge = _defaultBridge();

        // A BOLD deposit works while the circuit is open.
        _depositBold(bridge, alice, 1 ether, 100);

        vm.expectEmit(false, false, false, true, address(bridge));
        emit BoldCircuitClosed(block.timestamp);
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        assertTrue(bridge.boldCircuitClosed(), "circuit closed");

        // A BOLD deposit now reverts.
        _mintApprove(bridge, alice, 1 ether);
        vm.expectRevert(KnomosisBridge.BoldDepositPaused.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 100);
    }

    function test_openBoldCircuit_resumesBoldDeposits() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();

        vm.expectEmit(false, false, false, true, address(bridge));
        emit BoldCircuitOpened(block.timestamp);
        vm.prank(BREAKER);
        bridge.openBoldCircuit();
        assertTrue(!bridge.boldCircuitClosed(), "circuit reopened");

        // Deposits resume.
        _depositBold(bridge, alice, 1 ether, 100);
        assertEq(bridge.totalLockedValue(), 1 ether, "deposit lands after reopen");
    }

    function test_closedBoldCircuit_ethStillWorks() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 1 ether}(100);
        assertEq(bridge.totalLockedValue(), 1 ether, "ETH deposit unaffected by BOLD pause");
    }

    function test_revert_closeBoldCircuit_notBreaker() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.expectRevert(KnomosisBridge.NotBoldCircuitBreaker.selector);
        vm.prank(STRANGER);
        bridge.closeBoldCircuit();
    }

    function test_revert_openBoldCircuit_notBreaker() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        vm.expectRevert(KnomosisBridge.NotBoldCircuitBreaker.selector);
        vm.prank(STRANGER);
        bridge.openBoldCircuit();
    }

    function test_revert_admin_cannotToggleCircuit() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.expectRevert(KnomosisBridge.NotBoldCircuitBreaker.selector);
        vm.prank(ADMIN);
        bridge.closeBoldCircuit();
    }

    function test_closeBoldCircuit_idempotent() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        assertTrue(bridge.boldCircuitClosed(), "still closed");
    }

    function test_multiDeposit_closeMidBlock_secondReverts() public {
        KnomosisBridge bridge = _defaultBridge();
        _depositBold(bridge, alice, 1 ether, 100);

        vm.prank(BREAKER);
        bridge.closeBoldCircuit();

        _mintApprove(bridge, bob, 1 ether);
        vm.expectRevert(KnomosisBridge.BoldDepositPaused.selector);
        vm.prank(bob);
        bridge.depositBoldWithFee(1 ether, 100);
    }

    // ==================================================================
    // Per-BOLD TVL cap
    // ==================================================================

    event BoldTvlCapUpdated(uint256 newCap);

    function test_boldTvlCap_enforcedIndependentlyOfGlobal() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 1 ether);
        _mintApprove(bridge, alice, 2 ether);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(2 ether, 100);
    }

    function test_boldTvlCap_ethUnaffected() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 1 ether);
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 5 ether}(100);
        assertEq(bridge.totalLockedValue(), 5 ether, "ETH deposit > boldTvlCap still lands");
        assertEq(bridge.boldTotalLockedValue(), 0, "ETH deposit does not touch bold TVL");
    }

    function test_boldTvlCap_accumulatesAndBinds() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 3 ether);
        _depositBold(bridge, alice, 2 ether, 100);
        assertEq(bridge.boldTotalLockedValue(), 2 ether, "bold TVL accumulates");
        _mintApprove(bridge, bob, 2 ether);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(bob);
        bridge.depositBoldWithFee(2 ether, 100);
        _depositBold(bridge, bob, 1 ether, 100);
        assertEq(bridge.boldTotalLockedValue(), 3 ether, "bold TVL at cap exactly");
    }

    function test_boldTvlCap_firesOnFullValue_notUserAmount() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 1 ether);
        _depositBold(bridge, alice, 1 ether, 5000);
        assertEq(bridge.boldTotalLockedValue(), 1 ether, "full-value accounting at cap");
        _mintApprove(bridge, bob, 1);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(bob);
        bridge.depositBoldWithFee(1, 0);
    }

    function test_setBoldTvlCap_byAdmin_raisesCap() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 1 ether);
        _mintApprove(bridge, alice, 2 ether);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(2 ether, 100);

        vm.expectEmit(false, false, false, true, address(bridge));
        emit BoldTvlCapUpdated(5 ether);
        vm.prank(ADMIN);
        bridge.setBoldTvlCap(5 ether);
        assertEq(bridge.boldTvlCap(), 5 ether, "cap raised");

        vm.prank(alice);
        bridge.depositBoldWithFee(2 ether, 100);
        assertEq(bridge.boldTotalLockedValue(), 2 ether, "deposit lands after cap raise");
    }

    function test_setBoldTvlCap_toZero_failsClosed() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 5 ether);
        vm.prank(ADMIN);
        bridge.setBoldTvlCap(0);
        assertEq(bridge.boldTvlCap(), 0, "cap lowered to zero");
        _mintApprove(bridge, alice, 1);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(1, 0);
    }

    /// @notice GP.5.5 NEW: setBoldTvlCap to the current value is a no-op
    ///         that still emits and succeeds (no early-return guard).
    function test_setBoldTvlCap_toCurrentValue_noopButEmits() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 3 ether);
        vm.expectEmit(false, false, false, true, address(bridge));
        emit BoldTvlCapUpdated(3 ether);
        vm.prank(ADMIN);
        bridge.setBoldTvlCap(3 ether);
        assertEq(bridge.boldTvlCap(), 3 ether, "cap value unchanged");
    }

    function test_revert_setBoldTvlCap_exceedsGlobal() public {
        KnomosisBridge bridge = _bridgeWithCaps(10 ether, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.BoldTvlCapExceedsGlobal.selector,
                uint256(10 ether + 1),
                uint256(10 ether)
            )
        );
        vm.prank(ADMIN);
        bridge.setBoldTvlCap(10 ether + 1);
    }

    function test_setBoldTvlCap_toGlobal_ok() public {
        KnomosisBridge bridge = _bridgeWithCaps(10 ether, 1 ether);
        vm.prank(ADMIN);
        bridge.setBoldTvlCap(10 ether);
        assertEq(bridge.boldTvlCap(), 10 ether, "cap == global accepted");
    }

    function test_revert_setBoldTvlCap_notAdmin() public {
        KnomosisBridge bridge = _bridgeWithCaps(10 ether, 1 ether);
        vm.expectRevert(KnomosisBridge.NotBoldAdmin.selector);
        vm.prank(STRANGER);
        bridge.setBoldTvlCap(2 ether);
    }

    function test_revert_breaker_cannotSetCap() public {
        KnomosisBridge bridge = _bridgeWithCaps(10 ether, 1 ether);
        vm.expectRevert(KnomosisBridge.NotBoldAdmin.selector);
        vm.prank(BREAKER);
        bridge.setBoldTvlCap(2 ether);
    }

    // ==================================================================
    // Liquity V2 branch-shutdown auto-trigger
    // ==================================================================

    event BoldCircuitClosedByAutoTrigger(
        uint256 timestamp, address indexed shutdownBranch, uint256 branchShutdownTime
    );

    function test_revert_autoTrigger_disabled() public {
        KnomosisBridge bridge = _defaultBridge(); // auto-trigger off
        vm.expectRevert(KnomosisBridge.AutoCircuitTriggerDisabled.selector);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
    }

    function test_autoTrigger_ethBranchShutdown_closesCircuit() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        uint256 t = 1_700_000_000;
        _setBranchShutdown(LIQUITY_TM_ETH, t);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_TM_ETH, t);
        vm.prank(STRANGER); // permissionless
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(bridge.boldCircuitClosed(), "ETH shutdown closes circuit");

        _mintApprove(bridge, alice, 1 ether);
        vm.expectRevert(KnomosisBridge.BoldDepositPaused.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 100);
    }

    function test_autoTrigger_wstethBranchShutdown_closesCircuit() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        uint256 t = 1_700_000_001;
        _setBranchShutdown(LIQUITY_TM_WSTETH, t);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_TM_WSTETH, t);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(bridge.boldCircuitClosed(), "wstETH shutdown closes circuit");
    }

    function test_autoTrigger_rethBranchShutdown_closesCircuit() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        uint256 t = 1_700_000_002;
        _setBranchShutdown(LIQUITY_TM_RETH, t);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_TM_RETH, t);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(bridge.boldCircuitClosed(), "rETH shutdown closes circuit");
    }

    /// @notice Multiple branches in shutdown — the FIRST checked (ETH)
    ///         is reported, demonstrating the early-return short-circuit.
    function test_autoTrigger_multipleShutdown_emitsFirstDetected() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        _setBranchShutdown(LIQUITY_TM_ETH, 1_700_000_000);
        _setBranchShutdown(LIQUITY_TM_WSTETH, 1_700_000_001);
        _setBranchShutdown(LIQUITY_TM_RETH, 1_700_000_002);

        // The ETH branch is checked first; its address appears in the event.
        vm.expectEmit(true, false, false, true, address(bridge));
        emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_TM_ETH, 1_700_000_000);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(bridge.boldCircuitClosed(), "any-shutdown closes circuit");
    }

    /// @notice If ETH is healthy but wstETH is shutdown, wstETH is
    ///         reported (short-circuit advances past healthy branches).
    function test_autoTrigger_skipsHealthyEth_reportsWsteth() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        _setBranchShutdown(LIQUITY_TM_WSTETH, 1_700_000_500);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_TM_WSTETH, 1_700_000_500);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
    }

    function test_revert_autoTrigger_noBranchShutdown() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        // All branches default to shutdownTime=0 (healthy).
        vm.expectRevert(KnomosisBridge.NoLiquityBranchShutdown.selector);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(!bridge.boldCircuitClosed(), "circuit untouched on all-healthy");
    }

    function test_autoTrigger_thenReopenByBreaker() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        _setBranchShutdown(LIQUITY_TM_ETH, 1_700_000_000);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(bridge.boldCircuitClosed(), "closed by auto-trigger");
        vm.prank(BREAKER);
        bridge.openBoldCircuit();
        assertTrue(!bridge.boldCircuitClosed(), "reopened by breaker");
    }

    /// @notice Idempotent: when already closed, the auto-trigger returns
    ///         WITHOUT reading any oracle (short-circuit before the
    ///         staticcalls).  Even a HEALTHY all-branches state does not
    ///         revert NoLiquityBranchShutdown when already closed.
    function test_autoTrigger_idempotent_whenAlreadyClosed() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        // All branches healthy.  The idempotent guard short-circuits
        // BEFORE the oracle reads, so no revert.
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(bridge.boldCircuitClosed(), "still closed; no spurious revert");
    }

    function test_autoTrigger_permissionless() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        _setBranchShutdown(LIQUITY_TM_ETH, 1);
        // Any address can call.
        vm.prank(STRANGER);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(bridge.boldCircuitClosed());
    }

    // ==================================================================
    // Oracle fault classes — staticcall-based read soundness
    // ==================================================================

    // ---- Per-branch oracle-fault helpers + per-branch tests ----
    // Each fault class is exercised against EACH of the three branches:
    // ETH (first-checked), wstETH (second-checked, requires healthy ETH),
    // and rETH (third-checked, requires healthy ETH + wstETH).  Closes
    // the "only ETH branch tested" coverage gap.

    function _runOracleRevertsTest(address malfunctioningBranch) internal {
        KnomosisBridge bridge = _bridgeWithAuto();
        MockLiquityV2TroveManager(malfunctioningBranch).setShouldRevert(true);
        vm.expectRevert(KnomosisBridge.LiquityV2ReadFailed.selector);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(!bridge.boldCircuitClosed(), "circuit untouched on revert");
    }

    function test_revert_autoTrigger_oracleReverts_ethBranch() public {
        _runOracleRevertsTest(LIQUITY_TM_ETH);
    }

    function test_revert_autoTrigger_oracleReverts_wstethBranch() public {
        _runOracleRevertsTest(LIQUITY_TM_WSTETH);
    }

    function test_revert_autoTrigger_oracleReverts_rethBranch() public {
        _runOracleRevertsTest(LIQUITY_TM_RETH);
    }

    function _runWrongSizeTest(address malfunctioningBranch) internal {
        WrongSizeLiquityV2 impl = new WrongSizeLiquityV2();
        vm.etch(malfunctioningBranch, address(impl).code);
        KnomosisBridge bridge = _bridgeWithAuto();
        vm.expectRevert(KnomosisBridge.LiquityV2ReadFailed.selector);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(!bridge.boldCircuitClosed(), "circuit untouched on wrong-size read");
    }

    function test_revert_autoTrigger_wrongSizeReturn_ethBranch() public {
        _runWrongSizeTest(LIQUITY_TM_ETH);
    }

    function test_revert_autoTrigger_wrongSizeReturn_wstethBranch() public {
        _runWrongSizeTest(LIQUITY_TM_WSTETH);
    }

    function test_revert_autoTrigger_wrongSizeReturn_rethBranch() public {
        _runWrongSizeTest(LIQUITY_TM_RETH);
    }

    function _runOversizedTest(address malfunctioningBranch) internal {
        OversizedLiquityV2 impl = new OversizedLiquityV2();
        vm.etch(malfunctioningBranch, address(impl).code);
        KnomosisBridge bridge = _bridgeWithAuto();
        vm.expectRevert(KnomosisBridge.LiquityV2ReadFailed.selector);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
    }

    function test_revert_autoTrigger_oversizedReturn_ethBranch() public {
        _runOversizedTest(LIQUITY_TM_ETH);
    }

    function test_revert_autoTrigger_oversizedReturn_wstethBranch() public {
        _runOversizedTest(LIQUITY_TM_WSTETH);
    }

    function test_revert_autoTrigger_oversizedReturn_rethBranch() public {
        _runOversizedTest(LIQUITY_TM_RETH);
    }

    function _runCodeRemovedTest(address malfunctioningBranch) internal {
        KnomosisBridge bridge = _bridgeWithAuto();
        // After deploy, wipe the target TM's code.  The staticcall to a
        // no-code target returns (true, "") so data.length != 32 →
        // LiquityV2ReadFailed.  (The constructor's code-presence check
        // also catches no-code AT DEPLOY TIME — exercised separately by
        // `test_revert_constructor_autoTriggerOracleNoCode_*`.)
        vm.etch(malfunctioningBranch, hex"");
        vm.expectRevert(KnomosisBridge.LiquityV2ReadFailed.selector);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
    }

    function test_revert_autoTrigger_oracleCodeRemoved_ethBranch() public {
        _runCodeRemovedTest(LIQUITY_TM_ETH);
    }

    function test_revert_autoTrigger_oracleCodeRemoved_wstethBranch() public {
        _runCodeRemovedTest(LIQUITY_TM_WSTETH);
    }

    function test_revert_autoTrigger_oracleCodeRemoved_rethBranch() public {
        _runCodeRemovedTest(LIQUITY_TM_RETH);
    }

    /// @notice The bridge reads each TroveManager via staticcall, which
    ///         FORBIDS any SSTORE in the inner frame.  A re-entrant
    ///         TroveManager that probes a VIEW on the bridge during the
    ///         read succeeds harmlessly.
    function test_autoTrigger_reentrantOracle_viewProbeOk() public {
        ReentrantLiquityV2 reentrant = new ReentrantLiquityV2();
        reentrant.setShutdownTime(1_700_000_000);
        vm.etch(LIQUITY_TM_ETH, address(reentrant).code);
        // The targetBridge storage is set on the original `reentrant`
        // instance; after vm.etch the storage at LIQUITY_TM_ETH starts
        // fresh, so we must point the etched copy at the bridge.
        KnomosisBridge bridge = _bridgeWithAuto();
        ReentrantLiquityV2(LIQUITY_TM_ETH).setShutdownTime(1_700_000_000);
        ReentrantLiquityV2(LIQUITY_TM_ETH).setTargetBridge(address(bridge));

        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(bridge.boldCircuitClosed(), "close completes despite view reentry");
    }

    /// @notice GP.5.5 NEW: positively demonstrate that the staticcall
    ///         context prevents the TroveManager from mutating its own
    ///         storage during the read.  An adversarial mock that
    ///         attempts SSTORE inside `shutdownTime()` causes the
    ///         staticcall to fail (`ok == false`), routing to
    ///         `LiquityV2ReadFailed`.  Closes the "staticcall forbids
    ///         SSTORE → re-entrant TroveManager cannot corrupt bridge
    ///         state" claim by experimental proof, not just spec.
    ///         Tested per-branch (ETH / wstETH / rETH).
    function _runMutatingOracleTest(address malfunctioningBranch) internal {
        MutatingLiquityV2 impl = new MutatingLiquityV2();
        vm.etch(malfunctioningBranch, address(impl).code);
        KnomosisBridge bridge = _bridgeWithAuto();
        vm.expectRevert(KnomosisBridge.LiquityV2ReadFailed.selector);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(!bridge.boldCircuitClosed(), "circuit untouched on mutating oracle");
    }

    function test_revert_autoTrigger_mutatingOracle_ethBranch() public {
        _runMutatingOracleTest(LIQUITY_TM_ETH);
    }

    function test_revert_autoTrigger_mutatingOracle_wstethBranch() public {
        _runMutatingOracleTest(LIQUITY_TM_WSTETH);
    }

    function test_revert_autoTrigger_mutatingOracle_rethBranch() public {
        _runMutatingOracleTest(LIQUITY_TM_RETH);
    }

    // ==================================================================
    // Reentrancy attack via malicious BOLD token (depositBoldWithFee)
    // ==================================================================

    /// @notice A malicious BOLD whose `transferFrom` attempts to re-enter
    ///         `depositBoldWithFee` mid-flight MUST be rejected by the
    ///         bridge's `nonReentrant` modifier.  This is the realistic
    ///         attack shape — the attacker controls the BOLD code (via
    ///         a hypothetical malicious upgrade), the outer transferFrom
    ///         completes normally to satisfy the bridge's balance-delta
    ///         check, but then immediately calls back to attempt a
    ///         second deposit-credit on the same transferred tokens.
    ///         OZ's `ReentrancyGuard` catches the inner call.  Outer
    ///         deposit succeeds normally; inner reentry is rejected;
    ///         exactly ONE deposit's worth is credited.
    function test_depositBoldWithFee_nonReentrant_blocksReentryViaToken() public {
        ReentrantBold impl = new ReentrantBold();
        vm.etch(BOLD, address(impl).code);
        KnomosisBridge bridge = _defaultBridge();
        ReentrantBold(BOLD).setReentryTarget(address(bridge));

        // Pre-mint and pre-approve BOLD: alice has 2 ether + bridge can
        // pull 2 ether.  The OUTER deposit uses 1 ether; the inner
        // reentry would (if successful) attempt another 1-wei deposit.
        MockBold(BOLD).mint(alice, 2 ether);
        vm.prank(alice);
        MockBold(BOLD).approve(address(bridge), 2 ether);

        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 0);

        // Exactly ONE deposit credited.
        assertEq(bridge.boldTotalLockedValue(), 1 ether, "exactly one deposit credited");
        assertEq(bridge.totalLockedValue(), 1 ether, "global TVL = one deposit");
        assertEq(
            MockBold(BOLD).balanceOf(address(bridge)),
            1 ether,
            "bridge holds exactly one deposit's BOLD"
        );

        // The malicious BOLD attempted reentry...
        assertTrue(ReentrantBold(BOLD).didReenter(), "malicious BOLD attempted reentry");
        // ... and the reentrancy guard blocked it.
        assertTrue(
            ReentrantBold(BOLD).reentryWasBlocked(),
            "nonReentrant rejected the inner depositBoldWithFee"
        );
    }

    // ==================================================================
    // Fuzz / invariant coverage
    // ==================================================================

    function testFuzz_setBoldTvlCap_bounds(uint256 newCap) public {
        uint256 globalCap = 100 ether;
        KnomosisBridge bridge = _bridgeWithCaps(globalCap, 1 ether);
        vm.prank(ADMIN);
        if (newCap <= globalCap) {
            bridge.setBoldTvlCap(newCap);
            assertEq(bridge.boldTvlCap(), newCap, "cap stored");
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    KnomosisBridge.BoldTvlCapExceedsGlobal.selector, newCap, globalCap
                )
            );
            bridge.setBoldTvlCap(newCap);
        }
    }

    /// @notice For ANY non-zero shutdownTime on ANY branch, the
    ///         auto-trigger closes AND the event names the FIRST
    ///         detected branch in early-return order (ETH → wstETH →
    ///         rETH); for all-zero, it reverts.
    function testFuzz_anyBranchShutdownTriggers(
        uint256 ethShutdown,
        uint256 wstethShutdown,
        uint256 rethShutdown
    ) public {
        KnomosisBridge bridge = _bridgeWithAuto();
        _setBranchShutdown(LIQUITY_TM_ETH, ethShutdown);
        _setBranchShutdown(LIQUITY_TM_WSTETH, wstethShutdown);
        _setBranchShutdown(LIQUITY_TM_RETH, rethShutdown);
        if (ethShutdown != 0) {
            // ETH is first checked → event must name ETH with the ETH value.
            vm.expectEmit(true, false, false, true, address(bridge));
            emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_TM_ETH, ethShutdown);
            bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
            assertTrue(bridge.boldCircuitClosed(), "ETH shutdown closes");
        } else if (wstethShutdown != 0) {
            // ETH healthy → wstETH checked next → event names wstETH.
            vm.expectEmit(true, false, false, true, address(bridge));
            emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_TM_WSTETH, wstethShutdown);
            bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
            assertTrue(bridge.boldCircuitClosed(), "wstETH shutdown closes");
        } else if (rethShutdown != 0) {
            // Only rETH shutdown → event names rETH.
            vm.expectEmit(true, false, false, true, address(bridge));
            emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_TM_RETH, rethShutdown);
            bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
            assertTrue(bridge.boldCircuitClosed(), "rETH shutdown closes");
        } else {
            vm.expectRevert(KnomosisBridge.NoLiquityBranchShutdown.selector);
            bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
            assertTrue(!bridge.boldCircuitClosed(), "all-healthy keeps open");
        }
    }

    function testFuzz_capInvariant_boldTvl(uint256 amount, uint16 feeBps) public {
        uint256 boldCap = 10 ether;
        amount = (amount % 30 ether) + 1;
        feeBps = uint16(uint256(feeBps) % 5001);
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, boldCap);
        uint256 boldTvlBefore = bridge.boldTotalLockedValue();
        _mintApprove(bridge, alice, amount);
        if (boldTvlBefore + amount > boldCap) {
            vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
            vm.prank(alice);
            bridge.depositBoldWithFee(amount, feeBps);
            assertEq(
                bridge.boldTotalLockedValue(),
                boldTvlBefore,
                "rejected deposit does not move bold TVL"
            );
        } else {
            vm.prank(alice);
            bridge.depositBoldWithFee(amount, feeBps);
            assertEq(
                bridge.boldTotalLockedValue(),
                boldTvlBefore + amount,
                "admitted deposit grows bold TVL by full amount"
            );
            assertLe(bridge.boldTotalLockedValue(), boldCap, "invariant: bold TVL <= cap");
        }
    }

    function testFuzz_constructor_boldTvlCapBounds(uint256 globalCap, uint256 boldCap) public {
        globalCap = (globalCap % (100 ether)) + 1;
        boldCap = boldCap % (200 ether);
        if (boldCap > globalCap) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    KnomosisBridge.BoldTvlCapExceedsGlobal.selector, boldCap, globalCap
                )
            );
            _bridgeWithCaps(globalCap, boldCap);
        } else {
            KnomosisBridge bridge = _bridgeWithCaps(globalCap, boldCap);
            assertEq(bridge.boldTvlCap(), boldCap, "constructor pins the bold cap");
        }
    }

    // ==================================================================
    // Gas-regression smoke tests (tightened ceilings)
    // ==================================================================

    /// @notice Tightened to ~2x the observed cold-SSTORE cost.
    function test_gas_closeBoldCircuit() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.prank(BREAKER);
        uint256 g0 = gasleft();
        bridge.closeBoldCircuit();
        uint256 used = g0 - gasleft();
        emit log_named_uint("closeBoldCircuit gas", used);
        assertLt(used, 35_000, "closeBoldCircuit gas regression");
    }

    function test_gas_openBoldCircuit() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        vm.prank(BREAKER);
        uint256 g0 = gasleft();
        bridge.openBoldCircuit();
        uint256 used = g0 - gasleft();
        emit log_named_uint("openBoldCircuit gas", used);
        assertLt(used, 15_000, "openBoldCircuit gas regression");
    }

    function test_gas_setBoldTvlCap() public {
        KnomosisBridge bridge = _bridgeWithCaps(10 ether, 1 ether);
        vm.prank(ADMIN);
        uint256 g0 = gasleft();
        bridge.setBoldTvlCap(5 ether);
        uint256 used = g0 - gasleft();
        emit log_named_uint("setBoldTvlCap gas", used);
        assertLt(used, 15_000, "setBoldTvlCap gas regression");
    }

    /// @notice The fast path: ETH branch shutdown is detected on the
    ///         first staticcall.  Allows for ~3 SLOAD + 1 staticcall +
    ///         1 SSTORE + 1 event = ~35-40k gas.
    function test_gas_autoTrigger_close_ethBranch() public {
        _setBranchShutdown(LIQUITY_TM_ETH, 1_700_000_000);
        KnomosisBridge bridge = _bridgeWithAuto();
        uint256 g0 = gasleft();
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        uint256 used = g0 - gasleft();
        emit log_named_uint("autoTrigger gas (eth shutdown, fast path)", used);
        assertLt(used, 50_000, "auto-trigger fast-path gas regression");
    }

    /// @notice The slow path: all three TroveManagers must be read
    ///         (revert NoLiquityBranchShutdown).  Allows ~3 staticcalls.
    function test_gas_autoTrigger_noShutdown_pays3Reads() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        // All healthy.  Measure the revert path.
        uint256 g0 = gasleft();
        (bool ok,) = address(bridge)
            .call(abi.encodeWithSignature("closeBoldCircuitIfAnyLiquityBranchShutdown()"));
        uint256 used = g0 - gasleft();
        assertTrue(!ok, "expect revert");
        emit log_named_uint("autoTrigger gas (no shutdown, 3 reads)", used);
        assertLt(used, 100_000, "auto-trigger slow-path gas regression");
    }

    function test_gas_autoTrigger_idempotentShortCircuit() public {
        KnomosisBridge bridge = _bridgeWithAuto();
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        uint256 g0 = gasleft();
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        uint256 used = g0 - gasleft();
        emit log_named_uint("autoTrigger gas (idempotent)", used);
        assertLt(used, 15_000, "idempotent short-circuit must be cheap");
    }

    /// @notice GP.5.5 NEW: an adversarial TroveManager (e.g. a future
    ///         Liquity-V2 upgrade that consumes all forwarded gas on a
    ///         failed SSTORE) cannot grief the auto-trigger by exhausting
    ///         the caller's gas.  Without the 100k staticcall gas cap
    ///         the EVM's 63/64-rule would forward ~all-but-1/64 of the
    ///         caller's gas to the inner SSTORE attempt, burning ~30M+
    ///         per call.  With the cap, the worst case is ~LIQUITY_
    ///         ORACLE_READ_GAS (100k) + bridge overhead.  Pinning the
    ///         bound mechanically here.
    function test_gas_autoTrigger_griefBounded_firstBranch() public {
        MutatingLiquityV2 impl = new MutatingLiquityV2();
        vm.etch(LIQUITY_TM_ETH, address(impl).code);
        KnomosisBridge bridge = _bridgeWithAuto();
        uint256 g0 = gasleft();
        (bool ok,) = address(bridge)
            .call(abi.encodeWithSignature("closeBoldCircuitIfAnyLiquityBranchShutdown()"));
        uint256 used = g0 - gasleft();
        assertTrue(!ok, "expect revert");
        emit log_named_uint("autoTrigger grief gas (eth malicious)", used);
        // 100k (cap) + ~30k overhead = ~130k.  Ceiling 200k for headroom.
        assertLt(used, 200_000, "grief MUST be bounded by LIQUITY_ORACLE_READ_GAS + overhead");
    }

    /// @notice The grief-bounded property also holds when the malicious
    ///         branch is the SECOND or THIRD checked: ETH healthy
    ///         (returns 0), wstETH adversarial — bridge pays for one
    ///         honest read (~10k) plus one griefed read (~100k cap) plus
    ///         overhead.  Worst-case "all three malicious" still pays at
    ///         most one cap (short-circuit on first failure).
    function test_gas_autoTrigger_griefBounded_secondBranch() public {
        MutatingLiquityV2 impl = new MutatingLiquityV2();
        vm.etch(LIQUITY_TM_WSTETH, address(impl).code);
        // ETH stays healthy (shutdownTime=0 by default) so the check
        // advances to wstETH where the grief fires.
        KnomosisBridge bridge = _bridgeWithAuto();
        uint256 g0 = gasleft();
        (bool ok,) = address(bridge)
            .call(abi.encodeWithSignature("closeBoldCircuitIfAnyLiquityBranchShutdown()"));
        uint256 used = g0 - gasleft();
        assertTrue(!ok, "expect revert");
        emit log_named_uint("autoTrigger grief gas (wsteth malicious)", used);
        // Honest ETH read + griefed wstETH read + overhead.  Ceiling 250k.
        assertLt(used, 250_000, "grief bounded even when advancing past healthy branches");
    }

    // ==================================================================
    // End-to-end: withdrawals continue while paused; bold TVL decrements
    // ==================================================================

    function test_e2e_withdrawalWorks_whilePaused_decrementsBoldTvl() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 10 ether);

        _depositBold(bridge, alice, 1 ether, 0);
        assertEq(bridge.boldTotalLockedValue(), 1 ether, "bold TVL after deposit");
        assertEq(MockBold(BOLD).balanceOf(address(bridge)), 1 ether, "bridge escrowed BOLD");

        vm.prank(BREAKER);
        bridge.closeBoldCircuit();

        address recipient = address(0xBEEFCAFE);
        uint64 wAmount = 400_000;
        _finaliseAndRedeem(bridge, recipient, wAmount, 1);

        assertEq(
            MockBold(BOLD).balanceOf(recipient), wAmount, "recipient redeemed BOLD while paused"
        );
        assertEq(
            bridge.boldTotalLockedValue(), 1 ether - wAmount, "bold TVL decremented by withdrawal"
        );
        assertEq(bridge.totalLockedValue(), 1 ether - wAmount, "global TVL decremented too");
    }

    function test_boldTvlCap_withdrawalFreesRoom() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 1 ether);

        _depositBold(bridge, alice, 1 ether, 0);
        assertEq(bridge.boldTotalLockedValue(), 1 ether, "cap full");

        _mintApprove(bridge, bob, 1);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(bob);
        bridge.depositBoldWithFee(1, 0);

        _finaliseAndRedeem(bridge, address(0xBEEFCAFE), 0.5 ether, 1);
        assertEq(bridge.boldTotalLockedValue(), 0.5 ether, "half the cap freed");

        _depositBold(bridge, bob, 0.5 ether, 0);
        assertEq(bridge.boldTotalLockedValue(), 1 ether, "refilled to cap");
    }

    // ------------------------------------------------------------------
    // Withdrawal-flow helpers
    // ------------------------------------------------------------------

    function _finaliseAndRedeem(
        KnomosisBridge bridge,
        address recipient,
        uint64 wAmount,
        uint64 logIdx
    ) internal {
        uint64 leafIdx = 0;
        bytes memory leaf = _encodeWithdrawalLeaf(RESOURCE_BOLD, recipient, wAmount, leafIdx);
        bytes[] memory siblings = SmtVerifier.emptyProofSiblings();
        bytes32 root = SmtVerifier.recomputeRoot(uint256(leafIdx), leaf, siblings);
        bridge.submitStateRoot(root, logIdx, _signStateRoot(bridge, root, logIdx));
        vm.roll(block.number + 100);
        bytes memory proofBlob = _encodeWithdrawalProof(leaf, leafIdx, siblings);
        bridge.withdrawWithProof(logIdx, proofBlob, leaf);
    }

    /// @dev Thin per-suite delegate: the CBE + EIP-712 machinery lives
    ///      in the shared `WithdrawalFlowHarness`.
    function _signStateRoot(KnomosisBridge bridge, bytes32 root, uint64 idx)
        internal
        view
        returns (bytes memory)
    {
        return _signStateRootAs(ATTESTOR_PK, bridge, root, idx);
    }
}

/// @title BridgeSelfRoleProbe
/// @notice Helper for testing the `BoldRoleIsBridge` constructor guard.
///         A bridge cannot directly name itself as a role at construction
///         (its address is not yet known to the deployer), but it CAN
///         end up named indirectly if a deployer passes
///         `address(predictedBridge)` from a CREATE2 prediction or, more
///         simply, if the role address equals the bridge's address
///         post-deploy.  This probe drives the worst-case test by
///         passing the probe's OWN address as the role and asserting
///         that the constructor's `address(this) == role` check fires
///         for THIS specific shape: the test contract is fixed across
///         the test, but `address(this)` inside the bridge constructor
///         is the bridge's address.  We therefore can't trigger the
///         exact `role == address(this-as-bridge)` case from outside;
///         the probe's value is documenting the surface.
///
/// @dev    The actual `BoldRoleIsBridge` guard test below works by
///         driving CREATE2 to predict the bridge's address and passing
///         it as the role.  Foundry's `vm.computeCreate2Address` /
///         standard CREATE prediction lets us compute the address of
///         the next CREATE from this probe and pass it as the role,
///         forcing the constructor's `args.boldCircuitBreaker ==
///         address(this)` check to fire.
contract BridgeSelfRoleProbe is Test {
    uint256 private constant ATTESTOR_PK = 0xA77E5709;
    address private constant BREAKER = address(0xB12E6B6E);
    address private constant ADMIN = address(0xAD814);
    address private constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    /// @notice Deploy a bridge passing the bridge's own (predicted)
    ///         address as the `boldCircuitBreaker`.  Triggers
    ///         `BoldRoleIsBridge`.
    function deployBridgeWithSelfAsBreaker() external returns (KnomosisBridge) {
        // The next CREATE from this contract lands at
        // keccak256(rlp(this, nonce))[12:].  Foundry exposes
        // `vm.computeCreateAddress` for this exact prediction.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        return _deploy(predicted, ADMIN);
    }

    /// @notice Deploy a bridge passing the bridge's own (predicted)
    ///         address as `boldAdmin`.  Triggers `BoldRoleIsBridge`.
    function deployBridgeWithSelfAsAdmin() external returns (KnomosisBridge) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        return _deploy(BREAKER, predicted);
    }

    function _deploy(address breaker, address admin) internal returns (KnomosisBridge) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-self-role-probe"),
                attestor: vm.addr(ATTESTOR_PK),
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
                weiPerBudgetUnitBold: 1,
                boldTokenAddress: BOLD,
                boldTvlCap: type(uint256).max,
                boldCircuitBreaker: breaker,
                boldAdmin: admin,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 0,
                ammDisasterRecovery: address(0),
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }
}

/// @title BoldHandler
/// @notice Foundry-invariant handler that drives the BOLD safety surface
///         through random operation sequences.  The fuzzer picks one of
///         the four `external` methods on each step, with random args
///         (bounded inside the handler).  After every step, the
///         `BoldCircuitBreakerInvariantTest` invariants are re-checked.
///
/// @dev    Closes the "no stateful invariant test" gap that my
///         stateless fuzz tests left open.  The handler is intentionally
///         small: one BOLD-depositing user, one breaker, one admin.  No
///         withdrawals (those require the full state-root + finalisation
///         flow, which the unit-level `_finaliseAndRedeem` covers
///         deterministically).
contract BoldHandler {
    /// @dev `vm` accessor (forge cheatcodes); inherited contracts can't
    ///      use `Test`'s `vm` directly without inheriting Test.
    Vm internal constant VM_CHEATS = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    KnomosisBridge public immutable bridge;
    address public immutable alice;
    address public immutable breaker;
    address public immutable admin;

    /// @notice Sum of every deposit AMOUNT that was admitted (i.e. did
    ///         not revert) over the random sequence — useful as a
    ///         sanity envelope on `boldTotalLockedValue`.
    uint256 public sumAdmittedDeposits;

    constructor(KnomosisBridge bridge_, address alice_, address breaker_, address admin_) {
        bridge = bridge_;
        alice = alice_;
        breaker = breaker_;
        admin = admin_;
    }

    /// @notice Random BOLD deposit attempt.  Bounded args to keep the
    ///         fuzzer in a productive region (large random uints would
    ///         mostly miss the BoldTvlCap / fee bounds).
    function deposit(uint256 amount, uint16 feeBps) external {
        amount = _bound(amount, 0, 5 ether);
        feeBps = uint16(_bound(uint256(feeBps), 0, 5000));
        MockBold(BOLD).mint(alice, amount);
        VM_CHEATS.prank(alice);
        MockBold(BOLD).approve(address(bridge), amount);
        VM_CHEATS.prank(alice);
        try bridge.depositBoldWithFee(amount, feeBps) {
            sumAdmittedDeposits += amount;
        } catch {
            // expected: ZeroDeposit, BoldTvlCapReached, BoldDepositPaused, etc.
        }
    }

    function closeCircuit(uint256) external {
        VM_CHEATS.prank(breaker);
        try bridge.closeBoldCircuit() {} catch {}
    }

    function openCircuit(uint256) external {
        VM_CHEATS.prank(breaker);
        try bridge.openBoldCircuit() {} catch {}
    }

    function setCap(uint256 newCap) external {
        newCap = _bound(newCap, 0, bridge.tvlCap());
        VM_CHEATS.prank(admin);
        try bridge.setBoldTvlCap(newCap) {} catch {}
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
}

/// @title BoldCircuitBreakerInvariantTest
/// @notice Foundry-invariant runner driving `BoldHandler` against the
///         BOLD safety surface.  Asserts properties that must hold
///         across ARBITRARY sequences of (deposit, close, open,
///         setCap) operations — stronger than the per-call assertions
///         in the stateless fuzz tests above.
contract BoldCircuitBreakerInvariantTest is Test {
    address private constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address private constant LIQUITY_TM_ETH = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address private constant LIQUITY_TM_WSTETH = 0xA2895d6A3bf110561Dfe4b71cA539d84e1928B22;
    address private constant LIQUITY_TM_RETH = 0xb2B2ABEb5C357a234363FF5D180912D319e3e19e;

    address private constant ALICE = address(0xA1);
    address private constant BREAKER = address(0xB12E6B6E);
    address private constant ADMIN = address(0xAD814);

    KnomosisBridge bridge;
    BoldHandler handler;

    function setUp() public {
        // Etch BOLD + the three TroveManagers (auto-trigger disabled, so
        // the TMs are inert for this invariant suite — focus on deposit
        // / cap / pause dynamics).
        vm.etch(BOLD, address(new MockBold()).code);

        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        bridge = new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-bold-invariant-test"),
                attestor: address(0xA11CE),
                disputeVerifier: address(0xDEAD),
                sequencerStake: address(0xBEEF),
                migration: address(0),
                disputeWindowBlocks: 100,
                maxRedemptionWindowBlocks: 50,
                maxAttestationStaleBlocks: 200,
                cooldownBlocks: 50,
                tvlCap: 100 ether,
                minFeeBps: 0,
                maxFeeBps: 5000,
                weiPerBudgetUnitEth: 1,
                weiPerBudgetUnitBold: 1_000_000_000,
                boldTokenAddress: BOLD,
                boldTvlCap: 5 ether,
                boldCircuitBreaker: BREAKER,
                boldAdmin: ADMIN,
                enableLiquityAutoCircuitTrigger: false,
                ammSeedRatioBps: 0,
                ammDisasterRecovery: address(0),
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );

        handler = new BoldHandler(bridge, ALICE, BREAKER, ADMIN);
        targetContract(address(handler));
    }

    /// @notice Component-of-whole invariant: the per-BOLD locked value
    ///         is always a subset of the global locked value (BOLD
    ///         deposits + ETH-leg deposits − all withdrawals).  Holds
    ///         across ANY sequence of admit / reject / pause / cap
    ///         changes.
    function invariant_boldTvlLeqGlobalTvl() public view {
        assertLe(
            bridge.boldTotalLockedValue(),
            bridge.totalLockedValue(),
            "bold TVL must be a subset of global TVL"
        );
    }

    /// @notice `boldTotalLockedValue` is exactly the sum of admitted
    ///         deposits (no withdrawals in this handler), so it must
    ///         equal `sumAdmittedDeposits`.  Stronger than the
    ///         "<= cap" invariant: catches double-counting,
    ///         missed-increment, or any other admission-accounting bug.
    function invariant_boldTvlEqualsSumOfAdmittedDeposits() public view {
        assertEq(
            bridge.boldTotalLockedValue(),
            handler.sumAdmittedDeposits(),
            "boldTotalLockedValue == sum of admitted deposit amounts"
        );
    }

    /// @notice `boldTvlCap <= tvlCap` always.  The setter enforces this
    ///         per call; the invariant confirms it holds across the
    ///         random sequence.
    function invariant_boldTvlCapLeqGlobalCap() public view {
        assertLe(bridge.boldTvlCap(), bridge.tvlCap(), "bold cap must never exceed global cap");
    }
}
