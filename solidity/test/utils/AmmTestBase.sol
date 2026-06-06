// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {MockBold} from "test/utils/MockBold.sol";

/// @title AmmTestBase
/// @notice Shared scaffolding for the Workstream GP.11.3 embedded-AMM swap
///         test suites (`AmmSwap` / `AmmReentrancy` / `AmmInvariants` /
///         `AmmSlippage` / `AmmSandwich`): the canonical deployment configs,
///         the BOLD etch, reserve seeding via fee-split deposits, and an
///         INDEPENDENT constant-product reference (`_refOut`) — recomputed
///         from the raw formula, NOT via the contract's `AmmMath`, so the
///         behavioural suites check `contract == independent formula` while
///         `AmmMath.t.sol` separately pins `AmmMath == hand-computed truth`.
abstract contract AmmTestBase is Test {
    /// @dev Mirror of `KnomosisBridge.BOLD_TOKEN_ADDRESS`.
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address internal constant BOLD_BREAKER = address(0xB12E6B6E);
    address internal constant BOLD_ADMIN = address(0xAD814);
    /// @dev The GP.11.3 AMM disaster-recovery (kill-switch) role.  Wired into
    ///      `_deployBoldEnabled` so the kill switch + breaker are testable.
    address internal constant AMM_DR = address(0xA33D6);

    uint64 internal constant NATIVE_ETH = 0;
    uint64 internal constant BOLD_RID = 1;
    /// @dev Mirror of `KnomosisBridge.AMM_SWAP_FEE_BPS` (0.30%).
    uint256 internal constant FEE = 30;

    /// @dev Seeds the reserves via deposits.
    address internal lp = address(0x11D);
    /// @dev Performs swaps.
    address internal swapper = address(0x5A11);

    /// @dev Local copy of the contract event for `vm.expectEmit`.
    event AmmSwapExecuted(
        address indexed swapper,
        uint64 indexed fromResource,
        uint64 indexed toResource,
        uint256 amountIn,
        uint256 amountOut,
        uint256 newReserveIn,
        uint256 newReserveOut
    );

    function setUp() public virtual {
        vm.deal(lp, type(uint128).max);
        vm.deal(swapper, type(uint128).max);
    }

    // ------------------------------------------------------------------
    // Deployment + seeding
    // ------------------------------------------------------------------

    /// @notice Place a fresh conformant `MockBold`'s runtime code at the
    ///         pinned BOLD address.  MUST run BEFORE deploying a BOLD-enabled
    ///         bridge (the constructor cross-checks `BOLD_TOKEN.symbol()`).
    function _etchBold() internal {
        MockBold impl = new MockBold();
        vm.etch(BOLD, address(impl).code);
    }

    /// @notice The canonical BOLD-enabled + AMM-enabled (80% seed) +
    ///         kill-switch-enabled (`AMM_DR`) `ConstructorArgs`.  Exposed so
    ///         the constructor-guard test can override a single field.
    function _boldEnabledArgs() internal pure returns (KnomosisBridge.ConstructorArgs memory) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return KnomosisBridge.ConstructorArgs({
            knomosisVersionTag: keccak256("knomosis-amm-swap-base"),
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
            ammSeedRatioBps: 8000,
            ammDisasterRecovery: AMM_DR,
            erc20ResourceIds: rids,
            erc20TokenAddrs: toks
        });
    }

    /// @notice A BOLD-enabled bridge at the max seed ratio (80%), so deposits
    ///         seed the reserves generously.  Requires `_etchBold()` first.
    function _deployBoldEnabled() internal returns (KnomosisBridge) {
        return new KnomosisBridge(_boldEnabledArgs());
    }

    /// @notice Etch BOLD then deploy a BOLD-enabled bridge in the right order.
    function _deploySeededReady() internal returns (KnomosisBridge bridge) {
        _etchBold();
        bridge = _deployBoldEnabled();
    }

    /// @notice A BOLD-DISABLED bridge (the BOLD reserve can never fill).
    function _deployBoldDisabled() internal returns (KnomosisBridge) {
        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);
        return new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: keccak256("knomosis-amm-swap-nobold"),
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
                ammSeedRatioBps: 8000,
                ammDisasterRecovery: address(0),
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }

    /// @notice Mint `amount` BOLD to `user` and approve `bridge`.
    function _mintApprove(KnomosisBridge bridge, address user, uint256 amount) internal {
        MockBold(BOLD).mint(user, amount);
        vm.prank(user);
        MockBold(BOLD).approve(address(bridge), amount);
    }

    /// @notice Seed both AMM reserves to a realistic ~1 ETH : 3000 BOLD ratio.
    ///         100 ETH at 50% fee -> pool 50 -> 80% seed = 40 ETH;
    ///         300000 BOLD at 50% fee -> pool 150000 -> 80% seed = 120000 BOLD.
    function _seedBothLegs(KnomosisBridge bridge)
        internal
        returns (uint256 reserveEth, uint256 reserveBold)
    {
        vm.prank(lp);
        bridge.depositETHWithFee{value: 100 ether}(5000);

        uint256 boldDeposit = 300_000 ether;
        _mintApprove(bridge, lp, boldDeposit);
        vm.prank(lp);
        bridge.depositBoldWithFee(boldDeposit, 5000);

        reserveEth = bridge.ammReserveEth();
        reserveBold = bridge.ammReserveBold();
        assertGt(reserveEth, 0, "ETH reserve seeded");
        assertGt(reserveBold, 0, "BOLD reserve seeded");
    }

    /// @notice Independent constant-product output reference (NOT via the
    ///         contract's `AmmMath`): `floor(amountIn*(10000-FEE)*reserveOut
    ///         / (reserveIn*10000 + amountIn*(10000-FEE)))`.
    function _refOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256)
    {
        uint256 amountInWithFee = amountIn * (10_000 - FEE);
        return (amountInWithFee * reserveOut) / (reserveIn * 10_000 + amountInWithFee);
    }

    /// @notice A deadline comfortably in the future for non-deadline tests.
    function _farDeadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }
}
