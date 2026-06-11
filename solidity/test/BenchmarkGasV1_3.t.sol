// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisAmmDisasterRecoveryMultisig} from
    "src/contracts/KnomosisAmmDisasterRecoveryMultisig.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";
import {WithdrawalFlowHarness} from "test/utils/WithdrawalFlowHarness.sol";
import {MockBoldOz} from "test/utils/MockBoldOz.sol";
import {MockLiquityV2TroveManager} from "test/utils/MockLiquityV2.sol";

/// @title InactiveMigration
/// @notice Minimal stand-in for a deployed-but-not-yet-activated
///         `KnomosisMigration` successor.  The bridge consults exactly one
///         selector on its `migration` immutable (`activated()`, from the
///         `circuitOpen` modifier and the `ammSwap` migration arm), so the
///         stand-in implements exactly that.  Lets the benchmark suite
///         measure the per-operation cost of the external `activated()`
///         read that every migration-wired deployment pays.
contract InactiveMigration {
    /// @notice Always inactive — the live-predecessor configuration.
    function activated() external pure returns (bool) {
        return false;
    }
}

/// @title BenchmarkGasV1_3Base
/// @notice Workstream GP.11.9 — gas-cost benchmarks for the v1.3 L1
///         operations (`depositETHWithFee`, `depositBoldWithFee`, the BOLD
///         `approve` prerequisite, `ammSwap` in both directions and both
///         approval shapes, the BOLD circuit-breaker surface, the AMM kill
///         switch, the Liquity auto-trigger paths, and the
///         `withdrawWithProof` exit legs), so deployments can budget
///         L1-gas costs and review can spot performance regressions.
///
///         The committed baseline lives in
///         `test/BenchmarkGasV1_3.gas-baseline.json`; regenerate it (and
///         the runbook table derived from it) with `make snapshot-gas`,
///         and verify it with `make snapshot-gas-check` — the CI gate,
///         which fails on any per-benchmark gas INCREASE beyond 5%
///         (the GP.11.9 regression rule), fails on benchmark-set drift
///         (added / removed benchmarks without a regenerated baseline),
///         warns on improvements beyond 5% (ratchet them into the
///         baseline), and verifies the runbook table is in sync.
///         Operator-facing numbers + the $-cost methodology live in
///         `docs/gas_pool_runbook.md` §9.
///
/// @dev    Measurement discipline:
///
///         1. The suite is RUN UNDER FORGE'S ISOLATED MODE (`--isolate`,
///            enforced by the `make snapshot-gas{,-check}` targets):
///            every benchmarked call executes as its own EVM
///            transaction, which is foundry's documented-accurate mode
///            for the `snapshotGas*` cheatcodes.  The value
///            `vm.snapshotGasLastCall` records is therefore the FULL
///            TRANSACTION GAS the user pays on L1 — 21 000 intrinsic +
///            EIP-2028 calldata + execution, with EIP-3529 refunds
///            netted and the transaction target pre-warmed (EIP-2929).
///            Test-harness overhead (pranks, asserts, calldata
///            abi-encoding) is excluded by construction.  Empirically
///            verified: isolated-vs-unisolated deltas decode to the gas
///            as `21 000 + calldata − refunds` on all 21 benchmarks
///            (e.g. `closeBoldCircuit` +21 064 = 21 000 + 64;
///            `depositBoldWithFee` +13 816 = 21 000 + 416 − 2 800
///            reentrancy-guard reset − 4 800 allowance-clear refund).
///         2. Alongside every gas entry the helper records
///            `<name>.calldata_gas` — the exact EIP-2028 intrinsic
///            calldata cost (16/non-zero byte, 4/zero byte) of the
///            canonical calldata it sent — as a breakdown of the total.
///            This matters: a `withdrawWithProof` carries a ~2.7 kB SMT
///            proof whose calldata cost (~37.9k) dwarfs the "few
///            hundred gas" of the small-call operations.
///         3. NO fuzz / invariant tests — every benchmark is a fixed
///            scenario, so the recorded values are byte-stable for the
///            pinned (forge 1.7.0, solc 0.8.20, foundry.toml) toolchain.
///         4. Scenario state is staged entirely in `setUp`; scenarios
///            needing different pre-staged state (circuit already closed,
///            a Liquity branch in shutdown, a migration-wired bridge, a
///            finalised withdrawal root) live in separate contracts below.
///            Companion `test_sanity_*` tests pin every scenario
///            assumption AND every benchmarked operation's effects, so a
///            `setUp` refactor cannot silently change what is measured.
///         5. BOLD is modelled by `MockBoldOz` — the real vendored
///            OpenZeppelin v5 ERC-20 (matching production BOLD's OZ
///            base), so allowance semantics (including the
///            infinite-approval storage-write skip) carry real gas
///            costs; under isolated mode this surfaces the true
///            refund-netted trade-off between the exact- and
///            infinite-approval flows.
///
///         Known residual model gap (kept honest in the runbook):
///         production BOLD / TroveManager bytecode may differ marginally
///         from the mocks (larger dispatch tables, recipient checks) —
///         a few hundred gas, not thousands.
abstract contract BenchmarkGasV1_3Base is Test {
    /// @dev The snapshot group: all benchmarks across all scenario
    ///      contracts aggregate into `snapshots/BenchmarkGasV1_3.json`
    ///      (forge scratch output; the committed copy is the baseline).
    string internal constant SNAP_GROUP = "BenchmarkGasV1_3";

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

    /// @dev Attestor key — the withdrawal benchmarks sign a state-root
    ///      attestation.  The address is `vm.addr(ATTESTOR_PK)`.
    uint256 internal constant ATTESTOR_PK = 0xA77E5709;

    /// @dev Mirrors of `RESOURCE_ID_NATIVE_ETH` / `RESOURCE_ID_BOLD`.
    uint64 internal constant NATIVE_ETH = 0;
    uint64 internal constant BOLD_RID = 1;

    /// @dev Mirror of the bridge's `disputeWindowBlocks` constructor arg
    ///      below; the withdrawal scenario rolls past it to finalise.
    uint64 internal constant DISPUTE_WINDOW_BLOCKS = 100;

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

    // ------------------------------------------------------------------
    // The measurement core
    // ------------------------------------------------------------------

    /// @notice Execute exactly one benchmarked call and record (a) its
    ///         gas via `vm.snapshotGasLastCall` — under the make
    ///         targets' isolated mode this is the call's FULL
    ///         transaction gas (intrinsic + calldata + execution,
    ///         refunds netted) — and (b) the exact EIP-2028 calldata
    ///         cost of `data` (`vm.snapshotValue`, entry
    ///         `<name>.calldata_gas`) as a breakdown.  The call is made
    ///         low-level so a designed-to-revert benchmark (the keeper
    ///         probe) records its true consumed gas with no
    ///         `vm.expectRevert` harness interference; `expectOk` then
    ///         asserts the intended outcome AFTER the measurement.
    function _bench(
        string memory name,
        address sender,
        address target,
        uint256 value,
        bytes memory data,
        bool expectOk
    ) internal {
        vm.prank(sender);
        (bool ok,) = target.call{value: value}(data);
        vm.snapshotGasLastCall(SNAP_GROUP, name);
        vm.snapshotValue(SNAP_GROUP, string.concat(name, ".calldata_gas"), _calldataGas(data));
        assertEq(ok, expectOk, string.concat(name, ": unexpected call outcome"));
    }

    /// @notice EIP-2028 intrinsic calldata gas of `data`: 16 per
    ///         non-zero byte, 4 per zero byte.
    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i = 0; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    // ------------------------------------------------------------------
    // Deployment + staging helpers
    // ------------------------------------------------------------------

    /// @notice Place a fresh `MockBoldOz` (the OZ-faithful BOLD mock) at
    ///         the pinned BOLD address and conformant
    ///         `MockLiquityV2TroveManager`s (healthy: `shutdownTime == 0`)
    ///         at the three TroveManager pins.  MUST run before
    ///         `_deployBridge` (the constructor cross-checks `symbol()`
    ///         and the TroveManager code presence).
    function _etchMocks() internal {
        MockBoldOz boldImpl = new MockBoldOz();
        vm.etch(BOLD, address(boldImpl).code);
        MockLiquityV2TroveManager tmImpl = new MockLiquityV2TroveManager();
        bytes memory tmCode = address(tmImpl).code;
        vm.etch(LIQUITY_TM_ETH, tmCode);
        vm.etch(LIQUITY_TM_WSTETH, tmCode);
        vm.etch(LIQUITY_TM_RETH, tmCode);
    }

    /// @notice The canonical benchmark deployment: BOLD-enabled, AMM at
    ///         the production-recommended 30% seed ratio, Liquity
    ///         auto-trigger enabled, kill-switch role wired, keyed
    ///         attestor, full `[0, 5000]` fee band,
    ///         1-gwei-per-budget-unit exchange rates on both legs.
    /// @param  migration_ The migration immutable: `address(0)` for the
    ///         initial-deployment shape (no successor planned), or a
    ///         not-yet-activated successor for the migration-wired shape
    ///         (every `circuitOpen` operation and every `ammSwap` then
    ///         pays an external `activated()` read).
    function _deployBridge(address migration_) internal returns (KnomosisBridge) {
        return _deployBridgeWithRecovery(migration_, AMM_DR);
    }

    /// @notice `_deployBridge` with an explicit `ammDisasterRecovery`
    ///         role — the GP.11.10 disaster-recovery benchmarks wire the
    ///         reference 3-of-N multisig in as the role.
    function _deployBridgeWithRecovery(address migration_, address recovery_)
        internal
        returns (KnomosisBridge)
    {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-gas-benchmark-v1_3"),
                attestor: vm.addr(ATTESTOR_PK),
                disputeVerifier: address(0xDEAD),
                sequencerStake: address(0xBEEF),
                migration: migration_,
                disputeWindowBlocks: DISPUTE_WINDOW_BLOCKS,
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
                ammDisasterRecovery: recovery_,
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice Mint `amount` BOLD to `user` and approve `b` for exactly
    ///         that amount.
    function _mintApprove(KnomosisBridge b, address user, uint256 amount) internal {
        MockBoldOz(BOLD).mint(user, amount);
        vm.prank(user);
        MockBoldOz(BOLD).approve(address(b), amount);
    }

    /// @notice Pre-warm `b` to its steady-state shape: the LP's two
    ///         max-fee deposits make `totalLockedValue`,
    ///         `boldTotalLockedValue`, `ammReserveEth`, and
    ///         `ammReserveBold` all non-zero, so the benchmarked deposits
    ///         and swaps measure the recurring (non-first-write) storage
    ///         costs of a live deployment.
    function _seedPool(KnomosisBridge b) internal {
        vm.deal(lp, LP_ETH_DEPOSIT);
        vm.prank(lp);
        b.depositETHWithFee{value: LP_ETH_DEPOSIT}(LP_FEE_BPS);
        _mintApprove(b, lp, LP_BOLD_DEPOSIT);
        vm.prank(lp);
        b.depositBoldWithFee(LP_BOLD_DEPOSIT, LP_FEE_BPS);
    }

    /// @notice A deadline comfortably in the future for the swap benchmarks.
    function _farDeadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }
}

/// @title BenchmarkGasV1_3DepositsTest
/// @notice GP.11.9 deposit benchmarks: the plain v1.0 `depositETH`
///         reference point, `depositETHWithFee` / `depositBoldWithFee`
///         each in the two recurring shapes — a user's FIRST deposit (the
///         per-depositor `depositNonce` slot is written 0 → 1, the
///         expensive fresh-SSTORE shape) and a REPEAT deposit (nonce
///         non-zero → non-zero, the steady-state shape) — plus the BOLD
///         `approve` prerequisite transaction (fresh allowance slot).
contract BenchmarkGasV1_3DepositsTest is BenchmarkGasV1_3Base {
    /// @dev First-time depositor: has never touched the bridge.
    address internal alice = address(0xA11);
    /// @dev Repeat depositor: two staging deposits in `setUp` leave
    ///      `depositNonce[bob] == 2`.
    address internal bob = address(0xB0B);
    /// @dev Approves the bridge in the `boldApprove_fresh` benchmark;
    ///      holds BOLD but has never granted an allowance.
    address internal carol = address(0xCA201);

    function setUp() public {
        _etchMocks();
        bridge = _deployBridge(address(0));
        _seedPool(bridge);

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);

        // Bob's staging deposits (one per leg) make him a repeat
        // depositor; the follow-up approval stages his benchmarked BOLD
        // deposit.  10 000 BOLD minted up front covers both 3 000-BOLD
        // deposits with a non-zero residual, so his BOLD balance write
        // stays in the typical non-zero -> non-zero shape.
        MockBoldOz(BOLD).mint(bob, 10_000 ether);
        vm.prank(bob);
        MockBoldOz(BOLD).approve(address(bridge), BENCH_BOLD_AMOUNT);
        vm.prank(bob);
        bridge.depositETHWithFee{value: BENCH_ETH_AMOUNT}(BENCH_FEE_BPS);
        vm.prank(bob);
        bridge.depositBoldWithFee(BENCH_BOLD_AMOUNT, BENCH_FEE_BPS);
        vm.prank(bob);
        MockBoldOz(BOLD).approve(address(bridge), BENCH_BOLD_AMOUNT);

        // Alice's staged BOLD funds + exact approval (the approval is a
        // separate prerequisite transaction in production — benchmarked
        // on its own as `boldApprove_fresh`, NOT folded into the deposit
        // rows).
        MockBoldOz(BOLD).mint(alice, 10_000 ether);
        vm.prank(alice);
        MockBoldOz(BOLD).approve(address(bridge), BENCH_BOLD_AMOUNT);

        // Carol holds BOLD but grants her allowance inside the
        // benchmark itself.
        MockBoldOz(BOLD).mint(carol, 10_000 ether);
    }

    /// @notice v1.0 reference point: a plain `depositETH` (no fee split,
    ///         no budget grant, no AMM seeding) by a first-time depositor.
    ///         The delta against `depositETHWithFee_firstDeposit` is the
    ///         all-in cost of the GP.5.1 fee-split machinery.
    function test_gas_depositETH_reference() public {
        _bench(
            "depositETH_reference",
            alice,
            address(bridge),
            BENCH_ETH_AMOUNT,
            abi.encodeCall(bridge.depositETH, ()),
            true
        );
    }

    /// @notice `depositETHWithFee`, first-ever deposit by this depositor.
    function test_gas_depositETHWithFee_firstDeposit() public {
        _bench(
            "depositETHWithFee_firstDeposit",
            alice,
            address(bridge),
            BENCH_ETH_AMOUNT,
            abi.encodeCall(bridge.depositETHWithFee, (BENCH_FEE_BPS)),
            true
        );
    }

    /// @notice `depositETHWithFee`, repeat deposit (steady-state shape).
    function test_gas_depositETHWithFee_repeatDeposit() public {
        _bench(
            "depositETHWithFee_repeatDeposit",
            bob,
            address(bridge),
            BENCH_ETH_AMOUNT,
            abi.encodeCall(bridge.depositETHWithFee, (BENCH_FEE_BPS)),
            true
        );
    }

    /// @notice `depositBoldWithFee`, first-ever deposit by this depositor
    ///         (exact approval staged in `setUp`).
    function test_gas_depositBoldWithFee_firstDeposit() public {
        _bench(
            "depositBoldWithFee_firstDeposit",
            alice,
            address(bridge),
            0,
            abi.encodeCall(bridge.depositBoldWithFee, (BENCH_BOLD_AMOUNT, BENCH_FEE_BPS)),
            true
        );
    }

    /// @notice `depositBoldWithFee`, repeat deposit (steady-state shape).
    function test_gas_depositBoldWithFee_repeatDeposit() public {
        _bench(
            "depositBoldWithFee_repeatDeposit",
            bob,
            address(bridge),
            0,
            abi.encodeCall(bridge.depositBoldWithFee, (BENCH_BOLD_AMOUNT, BENCH_FEE_BPS)),
            true
        );
    }

    /// @notice The BOLD `approve` prerequisite transaction (fresh
    ///         allowance slot, 0 → non-zero): every `depositBoldWithFee`
    ///         / BOLD→ETH `ammSwap` flow pays this once beforehand.
    function test_gas_boldApprove_fresh() public {
        _bench(
            "boldApprove_fresh",
            carol,
            BOLD,
            0,
            abi.encodeCall(IERC20.approve, (address(bridge), BENCH_BOLD_AMOUNT)),
            true
        );
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
            MockBoldOz(BOLD).allowance(alice, address(bridge)),
            BENCH_BOLD_AMOUNT,
            "alice's exact approval staged"
        );
        assertEq(
            MockBoldOz(BOLD).allowance(bob, address(bridge)),
            BENCH_BOLD_AMOUNT,
            "bob's exact approval staged"
        );
        assertGt(
            MockBoldOz(BOLD).balanceOf(alice),
            BENCH_BOLD_AMOUNT,
            "alice keeps a residual BOLD balance"
        );
        assertGt(
            MockBoldOz(BOLD).balanceOf(bob), BENCH_BOLD_AMOUNT, "bob keeps a residual BOLD balance"
        );
        assertEq(
            MockBoldOz(BOLD).allowance(carol, address(bridge)), 0, "carol has no allowance yet"
        );
        assertGt(MockBoldOz(BOLD).balanceOf(carol), 0, "carol holds BOLD");
    }

    /// @notice The benchmarked operations actually do what their labels
    ///         say (effects checked once, outside the measured calls).
    function test_sanity_depositEffects() public {
        uint256 tvlBefore = bridge.totalLockedValue();
        uint256 aliceEthBefore = alice.balance;
        vm.prank(alice);
        bridge.depositETHWithFee{value: BENCH_ETH_AMOUNT}(BENCH_FEE_BPS);
        assertEq(bridge.depositNonce(alice), 1, "nonce bumped");
        assertEq(bridge.totalLockedValue(), tvlBefore + BENCH_ETH_AMOUNT, "TVL grew by deposit");
        assertEq(
            alice.balance, aliceEthBefore - BENCH_ETH_AMOUNT, "deposit value paid by the depositor"
        );

        uint256 boldTvlBefore = bridge.boldTotalLockedValue();
        vm.prank(bob);
        bridge.depositBoldWithFee(BENCH_BOLD_AMOUNT, BENCH_FEE_BPS);
        assertEq(
            bridge.boldTotalLockedValue(),
            boldTvlBefore + BENCH_BOLD_AMOUNT,
            "BOLD TVL grew by deposit"
        );
        assertEq(
            MockBoldOz(BOLD).allowance(bob, address(bridge)),
            0,
            "exact approval consumed to zero (OZ writes the decrement)"
        );

        vm.prank(carol);
        MockBoldOz(BOLD).approve(address(bridge), BENCH_BOLD_AMOUNT);
        assertEq(
            MockBoldOz(BOLD).allowance(carol, address(bridge)),
            BENCH_BOLD_AMOUNT,
            "carol's approve granted"
        );
    }
}

/// @title BenchmarkGasV1_3SwapsTest
/// @notice GP.11.9 `ammSwap` benchmarks over reserves seeded to a
///         realistic 15 ETH : 45 000 BOLD depth.  ETH→BOLD is measured in
///         both recurring shapes — the swapper's FIRST BOLD (the output
///         credits a fresh ERC-20 balance slot, 0 → non-zero) and a REPEAT
///         swap (non-zero → non-zero) — and BOLD→ETH in BOTH approval
///         shapes: exact approval (`transferFrom` writes the allowance to
///         zero) and infinite approval (production BOLD's OZ
///         `_spendAllowance` skips the allowance write entirely —
///         reproduced faithfully by the OZ-based `MockBoldOz`).
contract BenchmarkGasV1_3SwapsTest is BenchmarkGasV1_3Base {
    /// @dev ETH→BOLD swapper holding no BOLD yet.
    address internal ethSwapperFresh = address(0x5A1);
    /// @dev ETH→BOLD swapper already holding BOLD.
    address internal ethSwapperRepeat = address(0x5A2);
    /// @dev BOLD→ETH swapper with a staged EXACT approval.
    address internal boldSwapperExact = address(0x5A3);
    /// @dev BOLD→ETH swapper with a staged INFINITE approval.
    address internal boldSwapperInfinite = address(0x5A4);

    function setUp() public {
        _etchMocks();
        bridge = _deployBridge(address(0));
        _seedPool(bridge);

        vm.deal(ethSwapperFresh, 1000 ether);
        vm.deal(ethSwapperRepeat, 1000 ether);
        vm.deal(boldSwapperExact, 1000 ether);
        vm.deal(boldSwapperInfinite, 1000 ether);

        // The repeat swapper already holds BOLD, so the swap output lands
        // in a non-zero balance slot.
        MockBoldOz(BOLD).mint(ethSwapperRepeat, 100 ether);

        // Both BOLD->ETH swappers hold more BOLD than the swap input
        // (typical residual); one approves exactly the input, the other
        // grants the infinite-approval wallet pattern.
        MockBoldOz(BOLD).mint(boldSwapperExact, 10_000 ether);
        vm.prank(boldSwapperExact);
        MockBoldOz(BOLD).approve(address(bridge), BENCH_BOLD_AMOUNT);
        MockBoldOz(BOLD).mint(boldSwapperInfinite, 10_000 ether);
        vm.prank(boldSwapperInfinite);
        MockBoldOz(BOLD).approve(address(bridge), type(uint256).max);
    }

    /// @dev The canonical swap calldata for this suite's swaps.
    function _swapData(uint64 fromResource, uint256 amountIn) internal view returns (bytes memory) {
        return abi.encodeCall(bridge.ammSwap, (fromResource, amountIn, 1, _farDeadline()));
    }

    /// @notice `ammSwap` ETH→BOLD where the output credits the swapper's
    ///         first-ever BOLD (fresh balance-slot SSTORE).
    function test_gas_ammSwap_ethToBold_firstBoldRecipient() public {
        _bench(
            "ammSwap_ethToBold_firstBoldRecipient",
            ethSwapperFresh,
            address(bridge),
            BENCH_ETH_AMOUNT,
            _swapData(NATIVE_ETH, BENCH_ETH_AMOUNT),
            true
        );
    }

    /// @notice `ammSwap` ETH→BOLD where the swapper already holds BOLD
    ///         (steady-state shape).
    function test_gas_ammSwap_ethToBold_repeatRecipient() public {
        _bench(
            "ammSwap_ethToBold_repeatRecipient",
            ethSwapperRepeat,
            address(bridge),
            BENCH_ETH_AMOUNT,
            _swapData(NATIVE_ETH, BENCH_ETH_AMOUNT),
            true
        );
    }

    /// @notice `ammSwap` BOLD→ETH in the exact-approval shape (the
    ///         `transferFrom` writes the allowance down to zero).
    function test_gas_ammSwap_boldToEth_exactApproval() public {
        _bench(
            "ammSwap_boldToEth_exactApproval",
            boldSwapperExact,
            address(bridge),
            0,
            _swapData(BOLD_RID, BENCH_BOLD_AMOUNT),
            true
        );
    }

    /// @notice `ammSwap` BOLD→ETH in the infinite-approval shape (OZ
    ///         `_spendAllowance` skips the allowance write — the cheaper
    ///         recurring path for wallets holding a standing approval).
    function test_gas_ammSwap_boldToEth_infiniteApproval() public {
        _bench(
            "ammSwap_boldToEth_infiniteApproval",
            boldSwapperInfinite,
            address(bridge),
            0,
            _swapData(BOLD_RID, BENCH_BOLD_AMOUNT),
            true
        );
    }

    /// @notice Pins the seeded reserve depths and the swapper staging the
    ///         swap benchmarks depend on.
    function test_sanity_swapScenarioAssumptions() public view {
        // 100 ETH * 50% fee * 30% seed = 15 ETH; 300k BOLD * 50% * 30% = 45k.
        assertEq(bridge.ammReserveEth(), 15 ether, "ETH reserve == 15");
        assertEq(bridge.ammReserveBold(), 45_000 ether, "BOLD reserve == 45 000");
        assertEq(MockBoldOz(BOLD).balanceOf(ethSwapperFresh), 0, "fresh swapper holds no BOLD");
        assertGt(MockBoldOz(BOLD).balanceOf(ethSwapperRepeat), 0, "repeat swapper holds BOLD");
        assertEq(
            MockBoldOz(BOLD).allowance(boldSwapperExact, address(bridge)),
            BENCH_BOLD_AMOUNT,
            "exact approval staged"
        );
        assertEq(
            MockBoldOz(BOLD).allowance(boldSwapperInfinite, address(bridge)),
            type(uint256).max,
            "infinite approval staged"
        );
        assertGt(
            MockBoldOz(BOLD).balanceOf(boldSwapperExact),
            BENCH_BOLD_AMOUNT,
            "exact-approval swapper keeps a residual balance"
        );
        assertGt(
            MockBoldOz(BOLD).balanceOf(boldSwapperInfinite),
            BENCH_BOLD_AMOUNT,
            "infinite-approval swapper keeps a residual balance"
        );
    }

    /// @notice The benchmarked swaps produce real output in both
    ///         directions, the swap value is paid by the pranked swapper
    ///         (pinning the harness's value-accounting assumption), and
    ///         the infinite approval is NOT decremented (the OZ
    ///         `_spendAllowance` skip the infinite-approval benchmark
    ///         exists to measure).
    function test_sanity_swapEffects() public {
        uint256 ethBeforeIn = ethSwapperFresh.balance;
        vm.prank(ethSwapperFresh);
        uint256 boldOut = bridge.ammSwap{value: BENCH_ETH_AMOUNT}(
            NATIVE_ETH, BENCH_ETH_AMOUNT, 1, _farDeadline()
        );
        assertGt(boldOut, 0, "ETH->BOLD output non-zero");
        assertEq(MockBoldOz(BOLD).balanceOf(ethSwapperFresh), boldOut, "BOLD credited");
        assertEq(
            ethSwapperFresh.balance, ethBeforeIn - BENCH_ETH_AMOUNT, "swap input paid by swapper"
        );

        uint256 ethBefore = boldSwapperExact.balance;
        vm.prank(boldSwapperExact);
        uint256 ethOut = bridge.ammSwap(BOLD_RID, BENCH_BOLD_AMOUNT, 1, _farDeadline());
        assertGt(ethOut, 0, "BOLD->ETH output non-zero");
        assertEq(boldSwapperExact.balance, ethBefore + ethOut, "ETH paid out");
        assertEq(
            MockBoldOz(BOLD).allowance(boldSwapperExact, address(bridge)),
            0,
            "exact approval consumed"
        );

        vm.prank(boldSwapperInfinite);
        uint256 ethOut2 = bridge.ammSwap(BOLD_RID, BENCH_BOLD_AMOUNT, 1, _farDeadline());
        assertGt(ethOut2, 0, "infinite-approval swap output non-zero");
        assertEq(
            MockBoldOz(BOLD).allowance(boldSwapperInfinite, address(bridge)),
            type(uint256).max,
            "infinite approval NOT decremented (OZ skip)"
        );
    }
}

/// @title BenchmarkGasV1_3MigrationWiredTest
/// @notice GP.11.9 — the migration-wired deployment shape.  Production
///         deployments are encouraged to pre-wire a predicted
///         `KnomosisMigration` successor address (solidity/README,
///         "Production deployment notes"); every `circuitOpen` operation
///         (deposits, state-root submission) and every `ammSwap` then
///         pays an external `activated()` read on the successor.  These
///         rows measure that recurring premium against the unwired rows
///         of the same shape in the deposit / swap suites.
contract BenchmarkGasV1_3MigrationWiredTest is BenchmarkGasV1_3Base {
    /// @dev Repeat depositor on the migration-wired bridge.
    address internal bob = address(0xB0B);
    /// @dev ETH→BOLD swapper already holding BOLD (repeat shape).
    address internal ethSwapperRepeat = address(0x5A2);

    InactiveMigration internal successor;

    function setUp() public {
        _etchMocks();
        successor = new InactiveMigration();
        bridge = _deployBridge(address(successor));
        _seedPool(bridge);

        vm.deal(bob, 1000 ether);
        vm.deal(ethSwapperRepeat, 1000 ether);

        // Stage bob as a repeat depositor (one prior deposit) and the
        // swapper as a repeat BOLD recipient, mirroring the unwired
        // repeat-shape scenarios so the wired-vs-unwired delta is the
        // ONLY difference.
        vm.prank(bob);
        bridge.depositETHWithFee{value: BENCH_ETH_AMOUNT}(BENCH_FEE_BPS);
        MockBoldOz(BOLD).mint(ethSwapperRepeat, 100 ether);
    }

    /// @notice `depositETHWithFee`, repeat shape, on a migration-wired
    ///         bridge (the `circuitOpen` modifier's `activated()` read
    ///         is the delta against `depositETHWithFee_repeatDeposit`).
    function test_gas_depositETHWithFee_repeat_migrationWired() public {
        _bench(
            "depositETHWithFee_repeat_migrationWired",
            bob,
            address(bridge),
            BENCH_ETH_AMOUNT,
            abi.encodeCall(bridge.depositETHWithFee, (BENCH_FEE_BPS)),
            true
        );
    }

    /// @notice `ammSwap` ETH→BOLD, repeat shape, on a migration-wired
    ///         bridge (the swap body's migration arm performs the
    ///         `activated()` read; delta against
    ///         `ammSwap_ethToBold_repeatRecipient`).
    function test_gas_ammSwap_ethToBold_repeat_migrationWired() public {
        _bench(
            "ammSwap_ethToBold_repeat_migrationWired",
            ethSwapperRepeat,
            address(bridge),
            BENCH_ETH_AMOUNT,
            abi.encodeCall(bridge.ammSwap, (NATIVE_ETH, BENCH_ETH_AMOUNT, 1, _farDeadline())),
            true
        );
    }

    /// @notice Pins the migration wiring + the staged repeat shapes.
    function test_sanity_migrationWiredAssumptions() public view {
        assertEq(bridge.migration(), address(successor), "migration wired");
        assertFalse(successor.activated(), "successor not activated");
        assertEq(bridge.depositNonce(bob), 1, "bob is a repeat depositor");
        assertGt(MockBoldOz(BOLD).balanceOf(ethSwapperRepeat), 0, "repeat swapper holds BOLD");
        // LP seed (15 ETH) + bob's staging deposit's seed
        // (1 ETH x 1% fee x 30% seed = 0.003 ETH).
        assertEq(bridge.ammReserveEth(), 15.003 ether, "ETH reserve == 15.003");
        assertEq(bridge.ammReserveBold(), 45_000 ether, "BOLD reserve == 45 000");
    }

    /// @notice The wired bridge's operations still succeed (the breaker
    ///         only fires once the successor ACTIVATES).
    function test_sanity_migrationWiredEffects() public {
        vm.prank(bob);
        bridge.depositETHWithFee{value: BENCH_ETH_AMOUNT}(BENCH_FEE_BPS);
        assertEq(bridge.depositNonce(bob), 2, "wired deposit succeeded");
        vm.prank(ethSwapperRepeat);
        uint256 out = bridge.ammSwap{value: BENCH_ETH_AMOUNT}(
            NATIVE_ETH, BENCH_ETH_AMOUNT, 1, _farDeadline()
        );
        assertGt(out, 0, "wired swap succeeded");
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
        bridge = _deployBridge(address(0));
    }

    /// @notice Manual BOLD circuit close by the `boldCircuitBreaker` role.
    function test_gas_closeBoldCircuit() public {
        _bench(
            "closeBoldCircuit",
            BREAKER,
            address(bridge),
            0,
            abi.encodeCall(bridge.closeBoldCircuit, ()),
            true
        );
    }

    /// @notice Per-BOLD TVL-cap tune by the `boldAdmin` role (non-zero →
    ///         non-zero storage write).
    function test_gas_setBoldTvlCap() public {
        _bench(
            "setBoldTvlCap",
            BOLD_ADMIN,
            address(bridge),
            0,
            abi.encodeCall(bridge.setBoldTvlCap, (1_000_000 ether)),
            true
        );
    }

    /// @notice One-way AMM kill switch by the `ammDisasterRecovery` role.
    function test_gas_emergencyDisableAmm() public {
        _bench(
            "emergencyDisableAmm",
            AMM_DR,
            address(bridge),
            0,
            abi.encodeCall(bridge.emergencyDisableAmm, ()),
            true
        );
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
///         state (staged in `setUp`, NOT inside the measured call).
contract BenchmarkGasV1_3BreakerReopenTest is BenchmarkGasV1_3Base {
    function setUp() public {
        _etchMocks();
        bridge = _deployBridge(address(0));
        vm.prank(BREAKER);
        bridge.closeBoldCircuit();
    }

    /// @notice Manual BOLD circuit reopen by the `boldCircuitBreaker` role.
    function test_gas_openBoldCircuit() public {
        _bench(
            "openBoldCircuit",
            BREAKER,
            address(bridge),
            0,
            abi.encodeCall(bridge.openBoldCircuit, ()),
            true
        );
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
    /// @dev The keeper bot calling the permissionless trigger.
    address internal keeper = address(0x6EE6);

    function setUp() public {
        _etchMocks();
        bridge = _deployBridge(address(0));
        vm.deal(keeper, 1 ether);
        MockLiquityV2TroveManager(LIQUITY_TM_ETH).setShutdownTime(12_345);
    }

    /// @notice Auto-trigger close, first-branch (ETH) fast path.
    function test_gas_autoTriggerClose_firstBranch() public {
        _bench(
            "autoTriggerClose_firstBranch",
            keeper,
            address(bridge),
            0,
            abi.encodeCall(bridge.closeBoldCircuitIfAnyLiquityBranchShutdown, ()),
            true
        );
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
    /// @dev The keeper bot calling the permissionless trigger.
    address internal keeper = address(0x6EE6);

    function setUp() public {
        _etchMocks();
        bridge = _deployBridge(address(0));
        vm.deal(keeper, 1 ether);
        MockLiquityV2TroveManager(LIQUITY_TM_RETH).setShutdownTime(12_345);
    }

    /// @notice Auto-trigger close, last-branch (rETH) worst path.
    function test_gas_autoTriggerClose_lastBranch() public {
        _bench(
            "autoTriggerClose_lastBranch",
            keeper,
            address(bridge),
            0,
            abi.encodeCall(bridge.closeBoldCircuitIfAnyLiquityBranchShutdown, ()),
            true
        );
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
///         recurring probe cost.  The benchmark's low-level call (via
///         `_bench` with `expectOk = false`) records the gas actually
///         consumed up to the revert with NO `vm.expectRevert` harness
///         interference.
contract BenchmarkGasV1_3AutoTriggerNoShutdownTest is BenchmarkGasV1_3Base {
    /// @dev The keeper bot calling the permissionless trigger.
    address internal keeper = address(0x6EE6);

    function setUp() public {
        _etchMocks();
        bridge = _deployBridge(address(0));
        vm.deal(keeper, 1 ether);
    }

    /// @notice Auto-trigger probe with all branches healthy (reverts).
    function test_gas_autoTriggerProbe_noShutdown() public {
        _bench(
            "autoTriggerProbe_noShutdown",
            keeper,
            address(bridge),
            0,
            abi.encodeCall(bridge.closeBoldCircuitIfAnyLiquityBranchShutdown, ()),
            false
        );
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

/// @title BenchmarkGasV1_3WithdrawalsTest
/// @notice GP.11.9 — the `withdrawWithProof` exit legs, completing the
///         round-trip cost picture (deposit rows alone are half the
///         user's bridging UX).  Scenario: alice deposited on both legs;
///         two single-leaf withdrawal trees are attested, submitted, and
///         finalised in `setUp` (the dispute window is rolled past), so
///         each benchmark measures exactly one redemption.
///
/// @dev    Proof-shape realism: `SmtVerifier.recomputeRoot` ALWAYS walks
///         all 64 levels over 64 supplied siblings (default-hash bytes
///         for empty subtrees are the same 32-byte size as populated
///         hashes), so verification gas is essentially independent of
///         tree population and the canonical single-leaf proof is
///         representative.  What DOES distinguish withdrawals from the
///         other rows is calldata: the ~2.7 kB proof blob costs ~30-45k
///         intrinsic calldata gas, captured exactly by the recorded
///         `.calldata_gas` companion entry.
contract BenchmarkGasV1_3WithdrawalsTest is BenchmarkGasV1_3Base, WithdrawalFlowHarness {
    /// @dev Depositor AND withdrawal recipient (the round-trip user).
    address internal alice = address(0xA11);

    uint256 internal constant ETH_WITHDRAW_AMOUNT = 0.5 ether;
    /// @dev 5 BOLD.  Leaf amounts are CBE uint64, so any single leaf is
    ///      bounded by ~18.4e18 wei units; 5e18 fits comfortably.
    uint256 internal constant BOLD_WITHDRAW_AMOUNT = 5 ether;

    uint64 internal constant ETH_ROOT_LOG_INDEX = 1;
    uint64 internal constant BOLD_ROOT_LOG_INDEX = 2;

    bytes internal ethLeaf;
    bytes internal ethProof;
    bytes internal boldLeaf;
    bytes internal boldProof;

    function setUp() public {
        _etchMocks();
        bridge = _deployBridge(address(0));

        // Round-trip staging: alice deposits on both legs, so the bridge
        // escrow covers the withdrawals, the TVL counters are non-zero,
        // and alice (the recipient) holds residual balances of both
        // assets — her balance writes stay in the typical non-zero ->
        // non-zero shape.
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        bridge.depositETHWithFee{value: 2 ether}(BENCH_FEE_BPS);
        _mintApprove(bridge, alice, 100 ether);
        vm.prank(alice);
        bridge.depositBoldWithFee(100 ether, BENCH_FEE_BPS);
        // Residual BOLD so the recipient's balance write on redemption is
        // the typical non-zero -> non-zero shape.
        MockBoldOz(BOLD).mint(alice, 50 ether);

        // One single-leaf withdrawal tree per leg, each attested under
        // its own (monotonic) logIndexHigh, then finalised by rolling
        // past the dispute window.
        bytes[] memory siblings = SmtVerifier.emptyProofSiblings();

        // forge-lint: disable-next-line(unsafe-typecast)
        ethLeaf = _encodeWithdrawalLeaf(NATIVE_ETH, alice, uint64(ETH_WITHDRAW_AMOUNT), 0);
        bytes32 ethRoot = SmtVerifier.recomputeRoot(0, ethLeaf, siblings);
        bridge.submitStateRoot(
            ethRoot, ETH_ROOT_LOG_INDEX, _signStateRoot(ethRoot, ETH_ROOT_LOG_INDEX)
        );
        ethProof = _encodeWithdrawalProof(ethLeaf, 0, siblings);

        // forge-lint: disable-next-line(unsafe-typecast)
        boldLeaf = _encodeWithdrawalLeaf(BOLD_RID, alice, uint64(BOLD_WITHDRAW_AMOUNT), 0);
        bytes32 boldRoot = SmtVerifier.recomputeRoot(0, boldLeaf, siblings);
        bridge.submitStateRoot(
            boldRoot, BOLD_ROOT_LOG_INDEX, _signStateRoot(boldRoot, BOLD_ROOT_LOG_INDEX)
        );
        boldProof = _encodeWithdrawalProof(boldLeaf, 0, siblings);

        vm.roll(block.number + DISPUTE_WINDOW_BLOCKS);
    }

    /// @notice `withdrawWithProof`, native-ETH leg (canonical 64-sibling
    ///         proof; recipient already funded).
    function test_gas_withdrawWithProof_eth() public {
        _bench(
            "withdrawWithProof_eth",
            alice,
            address(bridge),
            0,
            abi.encodeCall(bridge.withdrawWithProof, (ETH_ROOT_LOG_INDEX, ethProof, ethLeaf)),
            true
        );
    }

    /// @notice `withdrawWithProof`, BOLD leg (canonical 64-sibling proof;
    ///         recipient holds a residual BOLD balance).
    function test_gas_withdrawWithProof_bold() public {
        _bench(
            "withdrawWithProof_bold",
            alice,
            address(bridge),
            0,
            abi.encodeCall(bridge.withdrawWithProof, (BOLD_ROOT_LOG_INDEX, boldProof, boldLeaf)),
            true
        );
    }

    /// @notice Pins the staged withdrawal scenario: finalised roots, the
    ///         canonical proof-blob size, unredeemed leaves, and the
    ///         recipient's non-zero balances.
    function test_sanity_withdrawalScenarioAssumptions() public view {
        assertTrue(bridge.isStateRootFinalised(ETH_ROOT_LOG_INDEX), "ETH root finalised");
        assertTrue(bridge.isStateRootFinalised(BOLD_ROOT_LOG_INDEX), "BOLD root finalised");
        assertFalse(bridge.withdrawalLeafRedeemed(keccak256(ethLeaf)), "ETH leaf unredeemed");
        assertFalse(bridge.withdrawalLeafRedeemed(keccak256(boldLeaf)), "BOLD leaf unredeemed");
        // Canonical proof-blob size: cbeBytes(56-byte leaf) = 65, cbeUint
        // index = 9, array head = 9, 64 x cbeBytes(32-byte sibling) = 64
        // x 41 = 2624; total 2707 bytes.  Pins the proof shape the
        // benchmark's ~2.7 kB calldata figure rests on.
        assertEq(ethProof.length, 2707, "canonical proof blob is 2707 bytes");
        assertEq(boldProof.length, 2707, "canonical proof blob is 2707 bytes");
        assertEq(ethLeaf.length, 56, "canonical leaf blob is 56 bytes");
        assertGt(alice.balance, 0, "recipient already funded with ETH");
        assertGt(MockBoldOz(BOLD).balanceOf(alice), 0, "recipient holds residual BOLD");
    }

    /// @notice The benchmarked redemptions actually pay out, decrement
    ///         the TVL counters, mark the leaf redeemed, and reject a
    ///         double redemption.
    function test_sanity_withdrawalEffects() public {
        uint256 tvlBefore = bridge.totalLockedValue();
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        bridge.withdrawWithProof(ETH_ROOT_LOG_INDEX, ethProof, ethLeaf);
        assertEq(alice.balance, ethBefore + ETH_WITHDRAW_AMOUNT, "ETH paid out");
        assertEq(bridge.totalLockedValue(), tvlBefore - ETH_WITHDRAW_AMOUNT, "TVL decremented");
        assertTrue(bridge.withdrawalLeafRedeemed(keccak256(ethLeaf)), "ETH leaf marked redeemed");

        uint256 boldTvlBefore = bridge.boldTotalLockedValue();
        uint256 boldBefore = MockBoldOz(BOLD).balanceOf(alice);
        vm.prank(alice);
        bridge.withdrawWithProof(BOLD_ROOT_LOG_INDEX, boldProof, boldLeaf);
        assertEq(
            MockBoldOz(BOLD).balanceOf(alice), boldBefore + BOLD_WITHDRAW_AMOUNT, "BOLD paid out"
        );
        assertEq(
            bridge.boldTotalLockedValue(),
            boldTvlBefore - BOLD_WITHDRAW_AMOUNT,
            "per-BOLD TVL decremented"
        );

        vm.expectRevert(KnomosisBridge.AlreadyRedeemed.selector);
        vm.prank(alice);
        bridge.withdrawWithProof(ETH_ROOT_LOG_INDEX, ethProof, ethLeaf);
    }

    // ------------------------------------------------------------------
    // Withdrawal-flow helpers (CBE + EIP-712; mirror the canonical
    // encodings used by `BoldCircuitBreaker.t.sol`'s end-to-end tests)
    // ------------------------------------------------------------------

    /// @dev Thin per-suite delegate: the CBE + EIP-712 machinery lives
    ///      in the shared `WithdrawalFlowHarness`.
    function _signStateRoot(bytes32 root, uint64 idx) internal view returns (bytes memory) {
        return _signStateRootAs(ATTESTOR_PK, bridge, root, idx);
    }
}

/// @notice GP.11.10 disaster-recovery costs: the multisig confirmation
///         flow against the production 3-of-5 wiring.  Two benchmarks:
///         a NON-final confirmation (the recurring per-signer cost) and
///         the threshold-th confirmation, which atomically fires
///         `emergencyDisableAmm()` on the bridge — the full
///         crisis-resolution transaction.  (The direct single-key
///         `emergencyDisableAmm` row remains the BreakerTest scenario's
///         benchmark; these rows price the multisig custody the
///         GP.11.10 spec mandates.)
contract BenchmarkGasV1_3DisasterRecoveryTest is BenchmarkGasV1_3Base {
    KnomosisAmmDisasterRecoveryMultisig internal multisig;

    address internal constant DR_OPERATOR = address(0xD811);
    address internal constant DR_COMMUNITY_A = address(0xD812);
    address internal constant DR_COMMUNITY_B = address(0xD813);
    address internal constant DR_AUDITOR = address(0xD814);
    address internal constant DR_BACKUP = address(0xD815);

    function setUp() public {
        _etchMocks();
        address[] memory signers = new address[](5);
        signers[0] = DR_OPERATOR;
        signers[1] = DR_COMMUNITY_A;
        signers[2] = DR_COMMUNITY_B;
        signers[3] = DR_AUDITOR;
        signers[4] = DR_BACKUP;
        // Production predicted-address wiring: multisig first, bridge
        // second (nonce + 1).
        address predictedBridge =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        multisig = new KnomosisAmmDisasterRecoveryMultisig(predictedBridge, signers, 3);
        bridge = _deployBridgeWithRecovery(address(0), address(multisig));
        _seedPool(bridge);
        // Stage the FIRST confirmation, so the non-final benchmark
        // measures the recurring (second-signature) shape and the
        // executing benchmark only needs one more staged signature.
        vm.prank(DR_OPERATOR);
        multisig.confirmDisable();
    }

    /// @notice A non-final `confirmDisable` (the second of three): the
    ///         recurring per-signer confirmation cost.
    function test_gas_confirmDisable_nonFinal() public {
        _bench(
            "confirmDisable_nonFinal",
            DR_COMMUNITY_A,
            address(multisig),
            0,
            abi.encodeCall(multisig.confirmDisable, ()),
            true
        );
        assertEq(multisig.confirmationCount(), 2, "two live confirmations");
        assertFalse(bridge.ammDisabled(), "below threshold: switch not fired");
    }

    /// @notice The threshold-th `confirmDisable`: includes the atomic
    ///         `emergencyDisableAmm()` bridge call (the kill-switch
    ///         SSTORE + both events) — the full crisis-resolution
    ///         transaction a deployment should budget for.
    function test_gas_confirmDisable_executes() public {
        vm.prank(DR_COMMUNITY_A);
        multisig.confirmDisable(); // staged second signature (unbenched)
        _bench(
            "confirmDisable_executes",
            DR_AUDITOR,
            address(multisig),
            0,
            abi.encodeCall(multisig.confirmDisable, ()),
            true
        );
        assertTrue(multisig.executed(), "threshold reached");
        assertTrue(bridge.ammDisabled(), "the bridge switch fired atomically");
    }

    /// @notice Pins the staged scenario: the multisig holds the role,
    ///         one confirmation is live, and the AMM is enabled.
    function test_sanity_disasterRecoveryScenarioAssumptions() public view {
        assertEq(bridge.ammDisasterRecovery(), address(multisig), "multisig holds the role");
        assertEq(multisig.threshold(), 3, "3-of-5 quorum");
        assertEq(multisig.confirmationCount(), 1, "one staged confirmation");
        assertFalse(multisig.executed(), "not executed in the staged state");
        assertFalse(bridge.ammDisabled(), "AMM live in the staged state");
        assertGt(bridge.ammReserveEth(), 0, "pool seeded");
    }
}
