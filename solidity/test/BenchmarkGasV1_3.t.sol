// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {MockBold} from "test/utils/MockBold.sol";
import {MockLiquityV2TroveManager} from "test/utils/MockLiquityV2.sol";

/// @title BenchmarkGasV1_3Base
/// @notice Workstream GP.11.9 — gas-cost benchmarks for the v1.3 L1
///         operations (`depositETHWithFee`, `depositBoldWithFee`, `ammSwap`
///         in both directions, the BOLD circuit-breaker surface, and the
///         AMM kill switch), so deployments can budget L1-gas costs and so
///         review can spot performance regressions.
///
///         The committed baseline lives in
///         `test/BenchmarkGasV1_3.gas-snapshot`; regenerate it with
///         `make snapshot-gas` and verify it with `make snapshot-gas-check`
///         (the CI gate — any per-benchmark deviation beyond 5% fails).
///         Baseline numbers + the $-cost rationale are documented in
///         `docs/gas_pool_runbook.md` ("Gas economics"); update the runbook
///         table in the same PR whenever the baseline is regenerated.
///
/// @dev    Measurement discipline (everything here exists to keep the
///         committed numbers deterministic and meaningful):
///
///         1. NO fuzz / invariant tests — every benchmark is a fixed
///            scenario, so `forge snapshot` is byte-stable for a pinned
///            (forge, solc, foundry.toml) toolchain.
///         2. Every `test_gas_*` body is a PURE CALL: scenario state is
///            staged entirely in `setUp` (per-test state isolation resets
///            it between tests), so the per-test snapshot number is the
///            operation's execution gas plus a small constant harness
///            overhead (`vm.prank` + the internal CALL).  Success is
///            asserted by non-reversion alone; behavioural assertions live
///            in the companion `test_sanity_*` functions, which are
///            excluded from the snapshot by the `--match-test test_gas_`
///            filter in the Makefile targets.
///         3. Scenarios that need DIFFERENT pre-staged state (e.g. the
///            circuit already closed, or a specific Liquity branch in
///            shutdown) live in separate contracts below, each with its
///            own `setUp`, so no benchmark ever stages state inside the
///            measured test body.
///         4. The `test_sanity_*` companions pin every scenario assumption
///            (first-time vs repeat depositor, seeded reserve sizes,
///            staged approvals, branch shutdown states), so a future
///            refactor of `setUp` cannot silently change what a benchmark
///            measures without a test failing.
///
///         Reading the numbers: forge reports the gas consumed executing
///         the test function as an internal call.  An end-user transaction
///         additionally pays the 21 000 intrinsic transaction cost plus
///         calldata gas, and does not pay the harness's internal-CALL
///         accounting (cold account access + value-transfer surcharge);
///         see the runbook's "Gas economics" section for how to turn a
///         baseline into a $-cost estimate.
abstract contract BenchmarkGasV1_3Base is Test {
    /// @dev Mirror of `KnomosisBridge.BOLD_TOKEN_ADDRESS`.
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    /// @dev Mirrors of the three constitutional Liquity V2 TroveManager pins.
    address internal constant LIQUITY_TM_ETH = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address internal constant LIQUITY_TM_WSTETH = 0xA2895d6A3bf110561Dfe4b71cA539d84e1928B22;
    address internal constant LIQUITY_TM_RETH = 0xb2B2ABEb5C357a234363FF5D180912D319e3e19e;

    /// @dev Safety roles (must be distinct, non-bridge addresses).
    address internal constant BREAKER = address(0xB12E6B6E);
    address internal constant BOLD_ADMIN = address(0xAD814);
    address internal constant AMM_DR = address(0xA33D6);

    /// @dev Mirrors of `RESOURCE_ID_NATIVE_ETH` / `RESOURCE_ID_BOLD`.
    uint64 internal constant NATIVE_ETH = 0;
    uint64 internal constant BOLD_RID = 1;

    /// @dev Benchmark deployment parameters.  `SEED_RATIO_BPS = 3000`
    ///      is the production-recommended starting AMM seed ratio
    ///      (`docs/gas_pool_runbook.md`); the gas cost of the seeding
    ///      branch is ratio-independent for any non-zero ratio.
    uint16 internal constant SEED_RATIO_BPS = 3000;
    /// @dev The user-chosen fee benchmarked for deposits: 100 bps = 1%,
    ///      a typical voluntary gas-pool contribution.
    uint16 internal constant BENCH_FEE_BPS = 100;

    /// @dev Liquidity-provider staging deposits (seed the AMM + pre-warm
    ///      the pool accumulators to their steady-state non-zero shape).
    ///      100 ETH and 300 000 BOLD at the 5000-bps max fee with a
    ///      3000-bps seed ratio leave reserves of exactly 15 ETH and
    ///      45 000 BOLD — a realistic 1 ETH : 3000 BOLD spot price.
    uint256 internal constant LP_ETH_DEPOSIT = 100 ether;
    uint256 internal constant LP_BOLD_DEPOSIT = 300_000 ether;
    uint16 internal constant LP_FEE_BPS = 5000;

    /// @dev Benchmarked user amounts: ~equal-value legs at the seeded
    ///      1 : 3000 spot price.
    uint256 internal constant BENCH_ETH_AMOUNT = 1 ether;
    uint256 internal constant BENCH_BOLD_AMOUNT = 3000 ether;

    /// @dev Seeds the pool and the AMM reserves.
    address internal lp = address(0x11D);

    KnomosisBridge internal bridge;

    /// @notice Place a fresh conformant `MockBold` at the pinned BOLD
    ///         address and conformant `MockLiquityV2TroveManager`s
    ///         (healthy: `shutdownTime == 0`) at the three TroveManager
    ///         pins.  MUST run before `_deployBridge` (the constructor
    ///         cross-checks `symbol()` and the TroveManager code presence).
    function _etchMocks() internal {
        MockBold boldImpl = new MockBold();
        vm.etch(BOLD, address(boldImpl).code);
        MockLiquityV2TroveManager tmImpl = new MockLiquityV2TroveManager();
        bytes memory tmCode = address(tmImpl).code;
        vm.etch(LIQUITY_TM_ETH, tmCode);
        vm.etch(LIQUITY_TM_WSTETH, tmCode);
        vm.etch(LIQUITY_TM_RETH, tmCode);
    }

    /// @notice The canonical benchmark deployment: BOLD-enabled, AMM at the
    ///         production-recommended 30% seed ratio, Liquity auto-trigger
    ///         enabled, kill-switch role wired, full `[0, 5000]` fee band,
    ///         1-gwei-per-budget-unit exchange rates on both legs.
    function _deployBridge() internal returns (KnomosisBridge) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-gas-benchmark-v1_3"),
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
                boldCircuitBreaker: BREAKER,
                boldAdmin: BOLD_ADMIN,
                enableLiquityAutoCircuitTrigger: true,
                ammSeedRatioBps: SEED_RATIO_BPS,
                ammDisasterRecovery: AMM_DR,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice Mint `amount` BOLD to `user` and approve `bridge` for it.
    function _mintApprove(address user, uint256 amount) internal {
        MockBold(BOLD).mint(user, amount);
        vm.prank(user);
        MockBold(BOLD).approve(address(bridge), amount);
    }

    /// @notice Pre-warm the pool to its steady-state shape: the LP's two
    ///         max-fee deposits make `totalLockedValue`,
    ///         `boldTotalLockedValue`, `ammReserveEth`, and
    ///         `ammReserveBold` all non-zero, so the benchmarked deposits
    ///         and swaps measure the recurring (non-first-write) storage
    ///         costs of a live deployment.
    function _seedPool() internal {
        vm.deal(lp, LP_ETH_DEPOSIT);
        vm.prank(lp);
        bridge.depositETHWithFee{value: LP_ETH_DEPOSIT}(LP_FEE_BPS);
        _mintApprove(lp, LP_BOLD_DEPOSIT);
        vm.prank(lp);
        bridge.depositBoldWithFee(LP_BOLD_DEPOSIT, LP_FEE_BPS);
    }

    /// @notice A deadline comfortably in the future for the swap benchmarks.
    function _farDeadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }
}

/// @title BenchmarkGasV1_3DepositsTest
/// @notice GP.11.9 deposit benchmarks: the plain v1.0 `depositETH`
///         reference point, then `depositETHWithFee` / `depositBoldWithFee`
///         each in the two recurring shapes — a user's FIRST deposit (the
///         per-depositor `depositNonce` slot is written 0 → 1, the
///         expensive fresh-SSTORE shape) and a REPEAT deposit (nonce
///         non-zero → non-zero, the steady-state shape).
contract BenchmarkGasV1_3DepositsTest is BenchmarkGasV1_3Base {
    /// @dev First-time depositor: has never touched the bridge.
    address internal alice = address(0xA11);
    /// @dev Repeat depositor: two staging deposits in `setUp` leave
    ///      `depositNonce[bob] == 2`.
    address internal bob = address(0xB0B);

    function setUp() public {
        _etchMocks();
        bridge = _deployBridge();
        _seedPool();

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);

        // Bob's staging deposits (one per leg) make him a repeat
        // depositor; the follow-up approval stages his benchmarked BOLD
        // deposit.  10 000 BOLD minted up front covers both 3 000-BOLD
        // deposits with a non-zero residual, so his BOLD balance write
        // stays in the typical non-zero -> non-zero shape.
        MockBold(BOLD).mint(bob, 10_000 ether);
        vm.prank(bob);
        MockBold(BOLD).approve(address(bridge), BENCH_BOLD_AMOUNT);
        vm.prank(bob);
        bridge.depositETHWithFee{value: BENCH_ETH_AMOUNT}(BENCH_FEE_BPS);
        vm.prank(bob);
        bridge.depositBoldWithFee(BENCH_BOLD_AMOUNT, BENCH_FEE_BPS);
        vm.prank(bob);
        MockBold(BOLD).approve(address(bridge), BENCH_BOLD_AMOUNT);

        // Alice's staged BOLD funds + exact approval (the approval is a
        // separate prerequisite transaction in production — its gas is
        // deliberately NOT part of the deposit benchmark).
        MockBold(BOLD).mint(alice, 10_000 ether);
        vm.prank(alice);
        MockBold(BOLD).approve(address(bridge), BENCH_BOLD_AMOUNT);
    }

    /// @notice v1.0 reference point: a plain `depositETH` (no fee split,
    ///         no budget grant, no AMM seeding) by a first-time depositor.
    ///         The delta against `test_gas_depositETHWithFee_firstDeposit`
    ///         is the all-in cost of the GP.5.1 fee-split machinery.
    function test_gas_depositETH_reference() public {
        vm.prank(alice);
        bridge.depositETH{value: BENCH_ETH_AMOUNT}();
    }

    /// @notice `depositETHWithFee`, first-ever deposit by this depositor.
    function test_gas_depositETHWithFee_firstDeposit() public {
        vm.prank(alice);
        bridge.depositETHWithFee{value: BENCH_ETH_AMOUNT}(BENCH_FEE_BPS);
    }

    /// @notice `depositETHWithFee`, repeat deposit (steady-state shape).
    function test_gas_depositETHWithFee_repeatDeposit() public {
        vm.prank(bob);
        bridge.depositETHWithFee{value: BENCH_ETH_AMOUNT}(BENCH_FEE_BPS);
    }

    /// @notice `depositBoldWithFee`, first-ever deposit by this depositor
    ///         (exact approval staged in `setUp`).
    function test_gas_depositBoldWithFee_firstDeposit() public {
        vm.prank(alice);
        bridge.depositBoldWithFee(BENCH_BOLD_AMOUNT, BENCH_FEE_BPS);
    }

    /// @notice `depositBoldWithFee`, repeat deposit (steady-state shape).
    function test_gas_depositBoldWithFee_repeatDeposit() public {
        vm.prank(bob);
        bridge.depositBoldWithFee(BENCH_BOLD_AMOUNT, BENCH_FEE_BPS);
    }

    /// @notice Pins every scenario assumption the deposit benchmarks
    ///         depend on, so a `setUp` refactor cannot silently change
    ///         what they measure.
    function test_sanity_depositScenarioAssumptions() public view {
        assertEq(bridge.depositNonce(alice), 0, "alice is a first-time depositor");
        assertEq(bridge.depositNonce(bob), 2, "bob has deposited twice");
        assertGt(bridge.totalLockedValue(), 0, "pool pre-warmed");
        assertGt(bridge.boldTotalLockedValue(), 0, "BOLD pool pre-warmed");
        assertGt(bridge.ammReserveEth(), 0, "ETH reserve seeded");
        assertGt(bridge.ammReserveBold(), 0, "BOLD reserve seeded");
        assertEq(
            MockBold(BOLD).allowance(alice, address(bridge)),
            BENCH_BOLD_AMOUNT,
            "alice's exact approval staged"
        );
        assertEq(
            MockBold(BOLD).allowance(bob, address(bridge)),
            BENCH_BOLD_AMOUNT,
            "bob's exact approval staged"
        );
        assertGt(
            MockBold(BOLD).balanceOf(alice),
            BENCH_BOLD_AMOUNT,
            "alice keeps a residual BOLD balance"
        );
        assertGt(
            MockBold(BOLD).balanceOf(bob), BENCH_BOLD_AMOUNT, "bob keeps a residual BOLD balance"
        );
    }

    /// @notice The benchmarked operations actually do what their labels
    ///         say (effects checked once, outside the measured bodies).
    function test_sanity_depositEffects() public {
        uint256 tvlBefore = bridge.totalLockedValue();
        vm.prank(alice);
        bridge.depositETHWithFee{value: BENCH_ETH_AMOUNT}(BENCH_FEE_BPS);
        assertEq(bridge.depositNonce(alice), 1, "nonce bumped");
        assertEq(bridge.totalLockedValue(), tvlBefore + BENCH_ETH_AMOUNT, "TVL grew by deposit");

        uint256 boldTvlBefore = bridge.boldTotalLockedValue();
        vm.prank(bob);
        bridge.depositBoldWithFee(BENCH_BOLD_AMOUNT, BENCH_FEE_BPS);
        assertEq(
            bridge.boldTotalLockedValue(),
            boldTvlBefore + BENCH_BOLD_AMOUNT,
            "BOLD TVL grew by deposit"
        );
    }
}

/// @title BenchmarkGasV1_3SwapsTest
/// @notice GP.11.9 `ammSwap` benchmarks over reserves seeded to a
///         realistic 15 ETH : 45 000 BOLD depth.  ETH→BOLD is measured in
///         both recurring shapes — the swapper's FIRST BOLD (the output
///         credits a fresh ERC-20 balance slot, 0 → non-zero) and a REPEAT
///         swap (non-zero → non-zero) — and BOLD→ETH in the standard
///         exact-approval shape (`transferFrom` consumes the allowance to
///         zero; ETH is paid to an already-funded account).
contract BenchmarkGasV1_3SwapsTest is BenchmarkGasV1_3Base {
    /// @dev ETH→BOLD swapper holding no BOLD yet.
    address internal ethSwapperFresh = address(0x5A1);
    /// @dev ETH→BOLD swapper already holding BOLD.
    address internal ethSwapperRepeat = address(0x5A2);
    /// @dev BOLD→ETH swapper with a staged exact approval.
    address internal boldSwapper = address(0x5A3);

    function setUp() public {
        _etchMocks();
        bridge = _deployBridge();
        _seedPool();

        vm.deal(ethSwapperFresh, 1000 ether);
        vm.deal(ethSwapperRepeat, 1000 ether);
        vm.deal(boldSwapper, 1000 ether);

        // The repeat swapper already holds BOLD, so the swap output lands
        // in a non-zero balance slot.
        MockBold(BOLD).mint(ethSwapperRepeat, 100 ether);

        // The BOLD->ETH swapper holds more BOLD than the swap input
        // (typical residual) and has approved exactly the input.
        MockBold(BOLD).mint(boldSwapper, 10_000 ether);
        vm.prank(boldSwapper);
        MockBold(BOLD).approve(address(bridge), BENCH_BOLD_AMOUNT);
    }

    /// @notice `ammSwap` ETH→BOLD where the output credits the swapper's
    ///         first-ever BOLD (fresh balance-slot SSTORE).
    function test_gas_ammSwap_ethToBold_firstBoldRecipient() public {
        vm.prank(ethSwapperFresh);
        bridge.ammSwap{value: BENCH_ETH_AMOUNT}(NATIVE_ETH, BENCH_ETH_AMOUNT, 1, _farDeadline());
    }

    /// @notice `ammSwap` ETH→BOLD where the swapper already holds BOLD
    ///         (steady-state shape).
    function test_gas_ammSwap_ethToBold_repeatRecipient() public {
        vm.prank(ethSwapperRepeat);
        bridge.ammSwap{value: BENCH_ETH_AMOUNT}(NATIVE_ETH, BENCH_ETH_AMOUNT, 1, _farDeadline());
    }

    /// @notice `ammSwap` BOLD→ETH in the standard exact-approval shape.
    function test_gas_ammSwap_boldToEth() public {
        vm.prank(boldSwapper);
        bridge.ammSwap(BOLD_RID, BENCH_BOLD_AMOUNT, 1, _farDeadline());
    }

    /// @notice Pins the seeded reserve depths and the swapper staging the
    ///         swap benchmarks depend on.
    function test_sanity_swapScenarioAssumptions() public view {
        // 100 ETH * 50% fee * 30% seed = 15 ETH; 300k BOLD * 50% * 30% = 45k.
        assertEq(bridge.ammReserveEth(), 15 ether, "ETH reserve == 15");
        assertEq(bridge.ammReserveBold(), 45_000 ether, "BOLD reserve == 45 000");
        assertEq(MockBold(BOLD).balanceOf(ethSwapperFresh), 0, "fresh swapper holds no BOLD");
        assertGt(MockBold(BOLD).balanceOf(ethSwapperRepeat), 0, "repeat swapper holds BOLD");
        assertEq(
            MockBold(BOLD).allowance(boldSwapper, address(bridge)),
            BENCH_BOLD_AMOUNT,
            "exact approval staged"
        );
        assertGt(
            MockBold(BOLD).balanceOf(boldSwapper),
            BENCH_BOLD_AMOUNT,
            "BOLD swapper keeps a residual balance"
        );
    }

    /// @notice The benchmarked swaps produce real output in both
    ///         directions (effects checked once, outside the measured
    ///         bodies).
    function test_sanity_swapEffects() public {
        vm.prank(ethSwapperFresh);
        uint256 boldOut = bridge.ammSwap{value: BENCH_ETH_AMOUNT}(
            NATIVE_ETH, BENCH_ETH_AMOUNT, 1, _farDeadline()
        );
        assertGt(boldOut, 0, "ETH->BOLD output non-zero");
        assertEq(MockBold(BOLD).balanceOf(ethSwapperFresh), boldOut, "BOLD credited");

        uint256 ethBefore = boldSwapper.balance;
        vm.prank(boldSwapper);
        uint256 ethOut = bridge.ammSwap(BOLD_RID, BENCH_BOLD_AMOUNT, 1, _farDeadline());
        assertGt(ethOut, 0, "BOLD->ETH output non-zero");
        assertEq(boldSwapper.balance, ethBefore + ethOut, "ETH paid out");
    }
}

/// @title BenchmarkGasV1_3BreakerTest
/// @notice GP.11.9 operator-surface benchmarks from the genesis state
///         (circuit open, AMM enabled): the manual `closeBoldCircuit`,
///         the `setBoldTvlCap` tune, and the one-way `emergencyDisableAmm`
///         kill switch.
contract BenchmarkGasV1_3BreakerTest is BenchmarkGasV1_3Base {
    function setUp() public {
        _etchMocks();
        bridge = _deployBridge();
    }

    /// @notice Manual BOLD circuit close by the `boldCircuitBreaker` role.
    function test_gas_closeBoldCircuit() public {
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
    }

    /// @notice Per-BOLD TVL-cap tune by the `boldAdmin` role (non-zero →
    ///         non-zero storage write).
    function test_gas_setBoldTvlCap() public {
        vm.prank(BOLD_ADMIN);
        bridge.setBoldTvlCap(1_000_000 ether);
    }

    /// @notice One-way AMM kill switch by the `ammDisasterRecovery` role.
    function test_gas_emergencyDisableAmm() public {
        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();
    }

    /// @notice Pins the genesis pre-state + the operations' effects.
    function test_sanity_breakerEffects() public {
        assertFalse(bridge.boldCircuitClosed(), "circuit starts open");
        assertFalse(bridge.ammDisabled(), "AMM starts enabled");
        assertEq(bridge.boldTvlCap(), type(uint256).max, "cap starts at max");

        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
        assertTrue(bridge.boldCircuitClosed(), "circuit closed");

        vm.prank(BOLD_ADMIN);
        bridge.setBoldTvlCap(1_000_000 ether);
        assertEq(bridge.boldTvlCap(), 1_000_000 ether, "cap tuned");

        vm.prank(AMM_DR);
        bridge.emergencyDisableAmm();
        assertTrue(bridge.ammDisabled(), "AMM disabled");
    }
}

/// @title BenchmarkGasV1_3BreakerReopenTest
/// @notice GP.11.9 — `openBoldCircuit` measured from the closed-circuit
///         state (staged in `setUp`, NOT inside the measured body).
contract BenchmarkGasV1_3BreakerReopenTest is BenchmarkGasV1_3Base {
    function setUp() public {
        _etchMocks();
        bridge = _deployBridge();
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
    }

    /// @notice Manual BOLD circuit reopen by the `boldCircuitBreaker` role.
    function test_gas_openBoldCircuit() public {
        vm.prank(BREAKER);
        bridge.openBoldCircuit();
    }

    /// @notice Pins the closed pre-state + the reopen effect.
    function test_sanity_reopenEffects() public {
        assertTrue(bridge.boldCircuitClosed(), "circuit staged closed");
        vm.prank(BREAKER);
        bridge.openBoldCircuit();
        assertFalse(bridge.boldCircuitClosed(), "circuit reopened");
    }
}

/// @title BenchmarkGasV1_3AutoTriggerFirstBranchTest
/// @notice GP.11.9 — the permissionless Liquity auto-trigger's FAST close
///         path: the first-checked branch (ETH) is in shutdown, so the
///         close costs one TroveManager staticcall plus the circuit write.
contract BenchmarkGasV1_3AutoTriggerFirstBranchTest is BenchmarkGasV1_3Base {
    function setUp() public {
        _etchMocks();
        bridge = _deployBridge();
        MockLiquityV2TroveManager(LIQUITY_TM_ETH).setShutdownTime(12_345);
    }

    /// @notice Auto-trigger close, first-branch (ETH) fast path.
    function test_gas_closeBoldCircuitIfAnyLiquityBranchShutdown_firstBranch() public {
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
    }

    /// @notice Pins the staged branch states + the close effect.
    function test_sanity_firstBranchEffects() public {
        assertTrue(bridge.enableLiquityAutoCircuitTrigger(), "auto-trigger enabled");
        assertEq(MockLiquityV2TroveManager(LIQUITY_TM_ETH).shutdownTime(), 12_345, "ETH shutdown");
        assertEq(MockLiquityV2TroveManager(LIQUITY_TM_WSTETH).shutdownTime(), 0, "wstETH healthy");
        assertEq(MockLiquityV2TroveManager(LIQUITY_TM_RETH).shutdownTime(), 0, "rETH healthy");
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(bridge.boldCircuitClosed(), "circuit closed by auto-trigger");
    }
}

/// @title BenchmarkGasV1_3AutoTriggerLastBranchTest
/// @notice GP.11.9 — the auto-trigger's WORST close path: only the
///         last-checked branch (rETH) is in shutdown, so the close reads
///         all three TroveManagers before writing the circuit.
contract BenchmarkGasV1_3AutoTriggerLastBranchTest is BenchmarkGasV1_3Base {
    function setUp() public {
        _etchMocks();
        bridge = _deployBridge();
        MockLiquityV2TroveManager(LIQUITY_TM_RETH).setShutdownTime(12_345);
    }

    /// @notice Auto-trigger close, last-branch (rETH) worst path.
    function test_gas_closeBoldCircuitIfAnyLiquityBranchShutdown_lastBranch() public {
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
    }

    /// @notice Pins the staged branch states + the close effect.
    function test_sanity_lastBranchEffects() public {
        assertEq(MockLiquityV2TroveManager(LIQUITY_TM_ETH).shutdownTime(), 0, "ETH healthy");
        assertEq(MockLiquityV2TroveManager(LIQUITY_TM_WSTETH).shutdownTime(), 0, "wstETH healthy");
        assertEq(MockLiquityV2TroveManager(LIQUITY_TM_RETH).shutdownTime(), 12_345, "rETH shutdown");
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertTrue(bridge.boldCircuitClosed(), "circuit closed by auto-trigger");
    }
}

/// @title BenchmarkGasV1_3AutoTriggerNoShutdownTest
/// @notice GP.11.9 — the auto-trigger's NO-SHUTDOWN path: all three
///         branches healthy, so the call reads all three TroveManagers and
///         reverts `NoLiquityBranchShutdown`.  This is the keeper bot's
///         recurring probe cost.  The snapshot number includes the
///         `vm.expectRevert` harness overhead on top of the gas consumed
///         up to the revert.
contract BenchmarkGasV1_3AutoTriggerNoShutdownTest is BenchmarkGasV1_3Base {
    function setUp() public {
        _etchMocks();
        bridge = _deployBridge();
    }

    /// @notice Auto-trigger probe with all branches healthy (reverts).
    function test_gas_closeBoldCircuitIfAnyLiquityBranchShutdown_noShutdown() public {
        vm.expectRevert(KnomosisBridge.NoLiquityBranchShutdown.selector);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
    }

    /// @notice Pins the all-healthy staging + the no-state-change effect.
    function test_sanity_noShutdownEffects() public {
        assertEq(MockLiquityV2TroveManager(LIQUITY_TM_ETH).shutdownTime(), 0, "ETH healthy");
        assertEq(MockLiquityV2TroveManager(LIQUITY_TM_WSTETH).shutdownTime(), 0, "wstETH healthy");
        assertEq(MockLiquityV2TroveManager(LIQUITY_TM_RETH).shutdownTime(), 0, "rETH healthy");
        vm.expectRevert(KnomosisBridge.NoLiquityBranchShutdown.selector);
        bridge.closeBoldCircuitIfAnyLiquityBranchShutdown();
        assertFalse(bridge.boldCircuitClosed(), "circuit stays open");
    }
}
