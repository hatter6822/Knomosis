// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";
import {KnomosisEip712} from "src/lib/KnomosisEip712.sol";
import {MockBold} from "test/utils/MockBold.sol";
import {
    MockLiquityV2,
    WrongSizeLiquityV2,
    OversizedLiquityV2,
    ReentrantLiquityV2
} from "test/utils/MockLiquityV2.sol";

/// @title BoldCircuitBreakerTest
/// @notice Workstream GP.5.5 — behavioural tests for the BOLD-specific
///         safety-hardening surface on `KnomosisBridge`: the per-currency
///         circuit breaker (manual + Liquity-V2 depeg auto-trigger), the
///         per-BOLD TVL cap, and the supporting access-control roles.
///
/// @dev    The harness mirrors `BridgeFeeSplitBold.t.sol`: a conformant
///         BOLD mock is etched at the compile-time `BOLD_TOKEN_ADDRESS`
///         pin before each deployment (the constructor reads `symbol()`),
///         then balances are minted post-etch.  Every BOLD-enabled bridge
///         ships operable `boldCircuitBreaker` / `boldAdmin` roles (the
///         constructor requires them non-zero), a keyed attestor (so the
///         end-to-end withdrawal tests can sign a state root), and an
///         optionally-bound Liquity V2 redemption oracle.
contract BoldCircuitBreakerTest is Test {
    address private alice = address(0xA1);
    address private bob = address(0xB0B);

    /// @dev Local mirror of `KnomosisBridge.BOLD_TOKEN_ADDRESS`.
    address private constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    /// @dev Mirror of `KnomosisBridge.RESOURCE_ID_BOLD`.
    uint64 private constant RESOURCE_BOLD = 1;

    /// @dev Safety-hardening roles for the deployed bridges.
    address private constant BREAKER = address(0xB12E6B6E);
    address private constant ADMIN = address(0xAD814);
    address private constant STRANGER = address(0x5152A6E2);

    /// @dev Attestor key — the end-to-end withdrawal tests sign a
    ///      state-root attestation.
    uint256 private constant ATTESTOR_PK = 0xA77E5709;

    /// @dev Mirror of `KnomosisBridge.BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS`.
    uint256 private constant THRESHOLD_BPS = 500;

    function setUp() public {
        _etchBold();
    }

    // ------------------------------------------------------------------
    // Deployment helpers
    // ------------------------------------------------------------------

    /// @notice Place a fresh conformant `MockBold`'s runtime code at the
    ///         pinned BOLD address (resets its storage).
    function _etchBold() internal {
        MockBold impl = new MockBold();
        vm.etch(BOLD, address(impl).code);
    }

    /// @notice Fully-parameterised deploy.  Full `[0, 5000]` fee range,
    ///         ETH rate 1, BOLD rate 1e9, keyed attestor, migration unset.
    function _deployRaw(
        address boldAddr,
        uint256 tvlCap,
        uint256 boldTvlCap,
        address breaker,
        address admin,
        address liquityOracle,
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
                liquityV2BorrowerOps: liquityOracle,
                enableLiquityAutoCircuitTrigger: enableAuto,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice BOLD-enabled bridge, no tight cap, no auto-trigger.
    function _defaultBridge() internal returns (KnomosisBridge) {
        return
            _deployRaw(
                BOLD, type(uint256).max, type(uint256).max, BREAKER, ADMIN, address(0), false
            );
    }

    /// @notice BOLD-enabled bridge with a specific (tvlCap, boldTvlCap).
    function _bridgeWithCaps(uint256 tvlCap, uint256 boldCap) internal returns (KnomosisBridge) {
        return _deployRaw(BOLD, tvlCap, boldCap, BREAKER, ADMIN, address(0), false);
    }

    /// @notice BOLD-enabled bridge with the Liquity auto-trigger bound to
    ///         `oracle`.
    function _bridgeWithAuto(address oracle) internal returns (KnomosisBridge) {
        return _deployRaw(BOLD, type(uint256).max, type(uint256).max, BREAKER, ADMIN, oracle, true);
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
        assertEq(bridge.liquityV2BorrowerOps(), address(0), "no oracle by default");
        assertTrue(!bridge.enableLiquityAutoCircuitTrigger(), "auto-trigger off by default");
    }

    function test_thresholdConstant_pinned() public {
        KnomosisBridge bridge = _defaultBridge();
        assertEq(bridge.BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS(), THRESHOLD_BPS, "threshold pinned");
        assertEq(bridge.BOLD_DEPEG_REDEMPTION_THRESHOLD_BPS(), 500, "threshold literal");
    }

    function test_revert_constructor_zeroBoldCircuitBreaker() public {
        vm.expectRevert(KnomosisBridge.ZeroBoldCircuitBreaker.selector);
        _deployRaw(BOLD, type(uint256).max, 1 ether, address(0), ADMIN, address(0), false);
    }

    function test_revert_constructor_zeroBoldAdmin() public {
        vm.expectRevert(KnomosisBridge.ZeroBoldAdmin.selector);
        _deployRaw(BOLD, type(uint256).max, 1 ether, BREAKER, address(0), address(0), false);
    }

    function test_revert_constructor_boldTvlCapExceedsGlobal() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.BoldTvlCapExceedsGlobal.selector, uint256(2 ether), uint256(1 ether)
            )
        );
        _deployRaw(BOLD, 1 ether, 2 ether, BREAKER, ADMIN, address(0), false);
    }

    function test_constructor_boldTvlCapEqualsGlobal_ok() public {
        KnomosisBridge bridge = _bridgeWithCaps(3 ether, 3 ether);
        assertEq(bridge.boldTvlCap(), 3 ether, "boldTvlCap == tvlCap accepted");
    }

    function test_constructor_disabledBold_zeroRolesOk() public {
        // BOLD disabled: the safety roles / cap / oracle are inert and so
        // are left unvalidated.  Zero roles must NOT revert.
        KnomosisBridge bridge =
            _deployRaw(address(0), type(uint256).max, 0, address(0), address(0), address(0), false);
        assertTrue(!bridge.boldEnabled(), "BOLD disabled");
        assertEq(bridge.boldCircuitBreaker(), address(0), "role stored verbatim when disabled");
    }

    // ---- Liquity auto-trigger construction guards ----

    function test_revert_constructor_autoTriggerRequiresBold() public {
        // enableAuto on a BOLD-disabled deployment -> AutoTriggerRequiresBold.
        MockLiquityV2 oracle = new MockLiquityV2();
        vm.expectRevert(KnomosisBridge.AutoTriggerRequiresBold.selector);
        _deployRaw(address(0), type(uint256).max, 0, address(0), address(0), address(oracle), true);
    }

    function test_revert_constructor_autoTriggerZeroOracle() public {
        vm.expectRevert(KnomosisBridge.ZeroLiquityOracle.selector);
        _deployRaw(BOLD, type(uint256).max, 1 ether, BREAKER, ADMIN, address(0), true);
    }

    function test_revert_constructor_autoTriggerOracleNoCode() public {
        // A non-zero oracle address with no contract code fails loudly.
        vm.expectRevert(KnomosisBridge.LiquityOracleHasNoCode.selector);
        _deployRaw(BOLD, type(uint256).max, 1 ether, BREAKER, ADMIN, address(0xC0DE15), true);
    }

    function test_constructor_autoTriggerEnabled_ok() public {
        MockLiquityV2 oracle = new MockLiquityV2();
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        assertTrue(bridge.enableLiquityAutoCircuitTrigger(), "auto-trigger enabled");
        assertEq(bridge.liquityV2BorrowerOps(), address(oracle), "oracle pinned");
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
        // A closed BOLD circuit halts ONLY the BOLD leg; the ETH fee-split
        // path is independent.
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
        // The admin role governs the TVL cap only — it cannot pause.
        KnomosisBridge bridge = _defaultBridge();
        vm.expectRevert(KnomosisBridge.NotBoldCircuitBreaker.selector);
        vm.prank(ADMIN);
        bridge.closeBoldCircuit();
    }

    function test_closeBoldCircuit_idempotent() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        // Re-closing is a harmless monotonic no-op (no revert).
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        assertTrue(bridge.boldCircuitClosed(), "still closed");
    }

    function test_multiDeposit_closeMidBlock_secondReverts() public {
        // Within a single block: first BOLD deposit lands, breaker closes
        // the circuit, the second BOLD deposit in the same block reverts.
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
        // Global cap is huge; the per-BOLD cap is the binding constraint.
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 1 ether);
        _mintApprove(bridge, alice, 2 ether);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(2 ether, 100);
    }

    function test_boldTvlCap_ethUnaffected() public {
        // A tight BOLD cap does not constrain the ETH leg.
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
        // Cumulative 2 + 2 = 4 > 3 -> reverts even though each leg < cap.
        _mintApprove(bridge, bob, 2 ether);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(bob);
        bridge.depositBoldWithFee(2 ether, 100);
        // A 1-ether deposit fits exactly (2 + 1 == 3 == cap).
        _depositBold(bridge, bob, 1 ether, 100);
        assertEq(bridge.boldTotalLockedValue(), 3 ether, "bold TVL at cap exactly");
    }

    function test_boldTvlCap_firesOnFullValue_notUserAmount() public {
        // The per-BOLD cap, like the global cap, fires on userAmount +
        // poolAmount, so a high fee cannot squeeze a larger deposit past it.
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 1 ether);
        // 1 BOLD at 50% fee == cap exactly; lands.
        _depositBold(bridge, alice, 1 ether, 5000);
        assertEq(bridge.boldTotalLockedValue(), 1 ether, "full-value accounting at cap");
        // A further 1 wei exceeds the cap.
        _mintApprove(bridge, bob, 1);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(bob);
        bridge.depositBoldWithFee(1, 0);
    }

    function test_setBoldTvlCap_byAdmin_raisesCap() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 1 ether);
        // 2-ether deposit blocked at the initial cap.
        _mintApprove(bridge, alice, 2 ether);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(2 ether, 100);

        vm.expectEmit(false, false, false, true, address(bridge));
        emit BoldTvlCapUpdated(5 ether);
        vm.prank(ADMIN);
        bridge.setBoldTvlCap(5 ether);
        assertEq(bridge.boldTvlCap(), 5 ether, "cap raised");

        // The same deposit now lands.
        vm.prank(alice);
        bridge.depositBoldWithFee(2 ether, 100);
        assertEq(bridge.boldTotalLockedValue(), 2 ether, "deposit lands after cap raise");
    }

    function test_setBoldTvlCap_toZero_failsClosed() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 5 ether);
        vm.prank(ADMIN);
        bridge.setBoldTvlCap(0);
        assertEq(bridge.boldTvlCap(), 0, "cap lowered to zero");
        // Every BOLD deposit now fails closed.
        _mintApprove(bridge, alice, 1);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(1, 0);
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
        // The breaker role cannot tune the cap — least privilege.
        KnomosisBridge bridge = _bridgeWithCaps(10 ether, 1 ether);
        vm.expectRevert(KnomosisBridge.NotBoldAdmin.selector);
        vm.prank(BREAKER);
        bridge.setBoldTvlCap(2 ether);
    }

    // ==================================================================
    // Liquity V2 depeg auto-trigger
    // ==================================================================

    event BoldCircuitClosedByAutoTrigger(uint256 timestamp, uint256 redemptionRateBps);

    function test_revert_autoTrigger_disabled() public {
        KnomosisBridge bridge = _defaultBridge(); // auto-trigger off
        vm.expectRevert(KnomosisBridge.AutoCircuitTriggerDisabled.selector);
        bridge.closeBoldCircuitIfRedeemingHeavily();
    }

    function test_autoTrigger_rateAboveThreshold_closesCircuit() public {
        MockLiquityV2 oracle = new MockLiquityV2();
        oracle.setRate(THRESHOLD_BPS + 100); // 6% > 5%
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));

        vm.expectEmit(false, false, false, true, address(bridge));
        emit BoldCircuitClosedByAutoTrigger(block.timestamp, THRESHOLD_BPS + 100);
        // Permissionless: a stranger may trigger it.
        vm.prank(STRANGER);
        bridge.closeBoldCircuitIfRedeemingHeavily();
        assertTrue(bridge.boldCircuitClosed(), "auto-trigger closed the circuit");

        // BOLD deposits are now paused.
        _mintApprove(bridge, alice, 1 ether);
        vm.expectRevert(KnomosisBridge.BoldDepositPaused.selector);
        vm.prank(alice);
        bridge.depositBoldWithFee(1 ether, 100);
    }

    function test_autoTrigger_rateAtThreshold_closesCircuit() public {
        MockLiquityV2 oracle = new MockLiquityV2();
        oracle.setRate(THRESHOLD_BPS); // exact boundary closes (>=)
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        bridge.closeBoldCircuitIfRedeemingHeavily();
        assertTrue(bridge.boldCircuitClosed(), "exact-threshold rate closes the circuit");
    }

    function test_revert_autoTrigger_rateBelowThreshold() public {
        MockLiquityV2 oracle = new MockLiquityV2();
        oracle.setRate(THRESHOLD_BPS - 1); // 4.99% < 5%
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisBridge.RedemptionRateBelowThreshold.selector, THRESHOLD_BPS - 1
            )
        );
        bridge.closeBoldCircuitIfRedeemingHeavily();
        assertTrue(!bridge.boldCircuitClosed(), "circuit stays open below threshold");
    }

    function test_revert_autoTrigger_oracleReverts() public {
        MockLiquityV2 oracle = new MockLiquityV2();
        oracle.setShouldRevert(true);
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        vm.expectRevert(KnomosisBridge.LiquityV2ReadFailed.selector);
        bridge.closeBoldCircuitIfRedeemingHeavily();
    }

    function test_revert_autoTrigger_oracleCodeRemoved() public {
        // The constructor requires code at the oracle, but defends against
        // a later code removal (e.g. SELFDESTRUCT under a pre-Cancun fork):
        // the runtime code-presence guard maps no-code onto LiquityV2ReadFailed
        // rather than an opaque empty revert.
        MockLiquityV2 oracle = new MockLiquityV2();
        oracle.setRate(THRESHOLD_BPS + 1);
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        // Wipe the oracle's code post-construction.
        vm.etch(address(oracle), hex"");
        vm.expectRevert(KnomosisBridge.LiquityV2ReadFailed.selector);
        bridge.closeBoldCircuitIfRedeemingHeavily();
    }

    function test_autoTrigger_idempotent_whenAlreadyClosed() public {
        // If the circuit is already closed, the auto-trigger short-circuits
        // (returns) BEFORE the oracle read — even a below-threshold rate
        // does not revert.  Proves the idempotency guard's precedence.
        MockLiquityV2 oracle = new MockLiquityV2();
        oracle.setRate(0); // would otherwise be RedemptionRateBelowThreshold
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        // No revert despite the below-threshold (here zero) rate.
        bridge.closeBoldCircuitIfRedeemingHeavily();
        assertTrue(bridge.boldCircuitClosed(), "still closed; no spurious revert");
    }

    function test_autoTrigger_thenReopenByBreaker() public {
        // After an auto-trigger close, the operator can still reopen.
        MockLiquityV2 oracle = new MockLiquityV2();
        oracle.setRate(THRESHOLD_BPS + 1);
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        bridge.closeBoldCircuitIfRedeemingHeavily();
        assertTrue(bridge.boldCircuitClosed(), "closed by auto-trigger");
        vm.prank(BREAKER);
        bridge.openBoldCircuit();
        assertTrue(!bridge.boldCircuitClosed(), "reopened by breaker");
    }

    // ==================================================================
    // End-to-end: withdrawals continue while paused; bold TVL decrements
    // ==================================================================

    /// @notice The defining safety posture: a BOLD withdrawal succeeds even
    ///         while the BOLD deposit circuit is closed, and it decrements
    ///         the per-BOLD TVL counter (so later deposits can refill).
    function test_e2e_withdrawalWorks_whilePaused_decrementsBoldTvl() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 10 ether);

        // Deposit 1 BOLD at zero fee -> escrow + boldTotalLockedValue = 1.
        _depositBold(bridge, alice, 1 ether, 0);
        assertEq(bridge.boldTotalLockedValue(), 1 ether, "bold TVL after deposit");
        assertEq(MockBold(BOLD).balanceOf(address(bridge)), 1 ether, "bridge escrowed BOLD");

        // Operator closes the BOLD deposit circuit (depeg response).
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();

        // Build + finalise a BOLD withdrawal leaf and redeem it.
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

    /// @notice A BOLD withdrawal frees per-BOLD cap room, so a deposit that
    ///         was over the cap fits after the withdrawal.
    function test_boldTvlCap_withdrawalFreesRoom() public {
        KnomosisBridge bridge = _bridgeWithCaps(100 ether, 1 ether);

        // Fill the cap exactly with a 1-BOLD deposit.
        _depositBold(bridge, alice, 1 ether, 0);
        assertEq(bridge.boldTotalLockedValue(), 1 ether, "cap full");

        // A further deposit reverts (cap reached).
        _mintApprove(bridge, bob, 1);
        vm.expectRevert(KnomosisBridge.BoldTvlCapReached.selector);
        vm.prank(bob);
        bridge.depositBoldWithFee(1, 0);

        // Withdraw 0.5 BOLD -> frees half the cap.
        _finaliseAndRedeem(bridge, address(0xBEEFCAFE), 0.5 ether, 1);
        assertEq(bridge.boldTotalLockedValue(), 0.5 ether, "half the cap freed");

        // A 0.5-BOLD deposit now fits exactly (0.5 + 0.5 == cap).
        _depositBold(bridge, bob, 0.5 ether, 0);
        assertEq(bridge.boldTotalLockedValue(), 1 ether, "refilled to cap");
    }

    // ==================================================================
    // Oracle fault classes — staticcall-based read soundness
    // ==================================================================

    /// @notice A wrong-shape oracle return (16 bytes instead of 32) is
    ///         caught by the bridge's `returndata.length != 32` guard
    ///         and degrades to `LiquityV2ReadFailed`.  Documents the
    ///         staticcall-based read's strict-shape policy.
    function test_revert_autoTrigger_wrongSizeReturn() public {
        WrongSizeLiquityV2 oracle = new WrongSizeLiquityV2();
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        vm.expectRevert(KnomosisBridge.LiquityV2ReadFailed.selector);
        bridge.closeBoldCircuitIfRedeemingHeavily();
        assertTrue(!bridge.boldCircuitClosed(), "circuit untouched on wrong-size read");
    }

    /// @notice An oversized oracle return (64 bytes) is ALSO rejected —
    ///         strict `== 32` policy fails closed on schema drift even
    ///         when the first word happens to be a sensible rate.
    function test_revert_autoTrigger_oversizedReturn() public {
        OversizedLiquityV2 oracle = new OversizedLiquityV2();
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        vm.expectRevert(KnomosisBridge.LiquityV2ReadFailed.selector);
        bridge.closeBoldCircuitIfRedeemingHeavily();
    }

    /// @notice A re-entrant oracle that probes a bridge VIEW during the
    ///         read is harmless: the bridge reads via `staticcall`, so
    ///         the EVM forbids any SSTORE in the inner frame.  This test
    ///         positively demonstrates the soundness claim — view reentry
    ///         succeeds AND the outer close completes correctly.
    function test_autoTrigger_reentrantOracle_viewProbeOk() public {
        ReentrantLiquityV2 oracle = new ReentrantLiquityV2();
        oracle.setRate(THRESHOLD_BPS + 100);
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        oracle.setTargetBridge(address(bridge));
        bridge.closeBoldCircuitIfRedeemingHeavily();
        assertTrue(bridge.boldCircuitClosed(), "close completes despite view reentry");
    }

    // ==================================================================
    // Fuzz / invariant coverage
    // ==================================================================

    /// @notice For any `newCap` chosen by an adversary, the setter
    ///         accepts iff `newCap <= tvlCap`.  Covers the full uint256
    ///         range — strictly stronger than the boundary unit test.
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

    /// @notice For any oracle rate, the threshold comparison is
    ///         `rate >= 500 ⇒ close`, `rate < 500 ⇒ revert with the
    ///         observed rate`.  Strictly stronger than the
    ///         per-boundary unit tests.
    function testFuzz_autoTrigger_thresholdComparison(uint256 rate) public {
        // Bound to a wide-but-tractable range straddling the threshold.
        rate = rate % (THRESHOLD_BPS * 20); // 0..9999
        MockLiquityV2 oracle = new MockLiquityV2();
        oracle.setRate(rate);
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        if (rate >= THRESHOLD_BPS) {
            bridge.closeBoldCircuitIfRedeemingHeavily();
            assertTrue(bridge.boldCircuitClosed(), "rate >= threshold closes");
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(KnomosisBridge.RedemptionRateBelowThreshold.selector, rate)
            );
            bridge.closeBoldCircuitIfRedeemingHeavily();
            assertTrue(!bridge.boldCircuitClosed(), "rate < threshold keeps it open");
        }
    }

    /// @notice Per-BOLD cap invariant: any admitted BOLD deposit
    ///         maintains `boldTotalLockedValue <= boldTvlCap`, AND a
    ///         BOLD deposit that would exceed the cap always reverts.
    ///         Drives random `(amount, feeBps)` pairs against a fixed
    ///         tight-cap deployment.
    function testFuzz_capInvariant_boldTvl(uint256 amount, uint16 feeBps) public {
        uint256 boldCap = 10 ether;
        amount = (amount % 30 ether) + 1; // 1 wei .. 30 BOLD-wei
        feeBps = uint16(uint256(feeBps) % 5001); // [0, 5000]
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

    /// @notice The constructor's `boldTvlCap <= tvlCap` validation is
    ///         strictly equivalent to the setter's check — any value
    ///         the setter would reject at runtime, the constructor
    ///         rejects at deploy time.
    function testFuzz_constructor_boldTvlCapBounds(uint256 globalCap, uint256 boldCap) public {
        // Bound to tractable ranges — uint256 max would dominate the
        // probability space without exercising the boundary.
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
    // Gas-regression smoke tests
    // ==================================================================

    /// @notice Catch gross gas regressions on the BOLD safety surface.
    ///         Generous ceilings — the goal is to surface 5x+ blowups,
    ///         not micro-optimise.
    function test_gas_closeBoldCircuit() public {
        KnomosisBridge bridge = _defaultBridge();
        vm.prank(BREAKER);
        uint256 g0 = gasleft();
        bridge.closeBoldCircuit();
        uint256 used = g0 - gasleft();
        emit log_named_uint("closeBoldCircuit gas", used);
        assertLt(used, 50_000, "closeBoldCircuit gas regression");
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
        assertLt(used, 50_000, "openBoldCircuit gas regression");
    }

    function test_gas_setBoldTvlCap() public {
        KnomosisBridge bridge = _bridgeWithCaps(10 ether, 1 ether);
        vm.prank(ADMIN);
        uint256 g0 = gasleft();
        bridge.setBoldTvlCap(5 ether);
        uint256 used = g0 - gasleft();
        emit log_named_uint("setBoldTvlCap gas", used);
        assertLt(used, 50_000, "setBoldTvlCap gas regression");
    }

    function test_gas_autoTrigger_close() public {
        MockLiquityV2 oracle = new MockLiquityV2();
        oracle.setRate(THRESHOLD_BPS + 1);
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        uint256 g0 = gasleft();
        bridge.closeBoldCircuitIfRedeemingHeavily();
        uint256 used = g0 - gasleft();
        emit log_named_uint("closeBoldCircuitIfRedeemingHeavily gas (close)", used);
        assertLt(used, 80_000, "auto-trigger gas regression");
    }

    function test_gas_autoTrigger_idempotentShortCircuit() public {
        // Idempotent path is the cheapest — verifies the short-circuit
        // is in fact cheap (no oracle call when already closed).
        MockLiquityV2 oracle = new MockLiquityV2();
        oracle.setRate(0); // deliberately below threshold; should not be read
        KnomosisBridge bridge = _bridgeWithAuto(address(oracle));
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        uint256 g0 = gasleft();
        bridge.closeBoldCircuitIfRedeemingHeavily();
        uint256 used = g0 - gasleft();
        emit log_named_uint("closeBoldCircuitIfRedeemingHeavily gas (idempotent)", used);
        assertLt(used, 20_000, "idempotent short-circuit must be cheap");
    }

    // ------------------------------------------------------------------
    // Withdrawal-flow helpers (mirror BridgeFeeSplitBold.t.sol)
    // ------------------------------------------------------------------

    /// @notice Build a BOLD withdrawal leaf at SMT index 0 for `recipient`,
    ///         submit + finalise the matching state root at `logIdx`, and
    ///         redeem the leaf.
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
        vm.roll(block.number + 100); // == disputeWindowBlocks
        bytes memory proofBlob = _encodeWithdrawalProof(leaf, leafIdx, siblings);
        bridge.withdrawWithProof(logIdx, proofBlob, leaf);
    }

    function _stateRootDigest(KnomosisBridge bridge, bytes32 root, uint64 idx)
        internal
        view
        returns (bytes32)
    {
        bytes32 ds = KnomosisEip712.domainSeparator(
            "KnomosisBridge", "1", block.chainid, uint256(0), address(bridge)
        );
        bytes32 sh = keccak256(
            abi.encode(
                keccak256("StateRoot(bytes32 root,uint64 logIndexHigh,bytes32 deploymentId)"),
                root,
                uint256(idx),
                bridge.deploymentId()
            )
        );
        return KnomosisEip712.digest(ds, sh);
    }

    function _signStateRoot(KnomosisBridge bridge, bytes32 root, uint64 idx)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, _stateRootDigest(bridge, root, idx));
        return abi.encodePacked(r, s, v);
    }

    function _leBytes8(uint64 v) internal pure returns (bytes memory out) {
        out = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    function _cbeUint(uint64 v) internal pure returns (bytes memory) {
        return bytes.concat(hex"00", _leBytes8(v));
    }

    function _cbeBytes(bytes memory payload) internal pure returns (bytes memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes.concat(hex"02", _leBytes8(uint64(payload.length)), payload);
    }

    function _cbeArrayHead(uint64 count) internal pure returns (bytes memory) {
        return bytes.concat(hex"04", _leBytes8(count));
    }

    function _encodeWithdrawalLeaf(
        uint64 resourceId,
        address recipient,
        uint64 amount,
        uint64 l2LogIndex
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            _cbeUint(resourceId),
            _cbeBytes(abi.encodePacked(recipient)),
            _cbeUint(amount),
            _cbeUint(l2LogIndex)
        );
    }

    function _encodeWithdrawalProof(bytes memory leaf, uint64 idx, bytes[] memory siblings)
        internal
        pure
        returns (bytes memory)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory out =
            bytes.concat(_cbeBytes(leaf), _cbeUint(idx), _cbeArrayHead(uint64(siblings.length)));
        for (uint256 i = 0; i < siblings.length; i++) {
            out = bytes.concat(out, _cbeBytes(siblings[i]));
        }
        return out;
    }
}
