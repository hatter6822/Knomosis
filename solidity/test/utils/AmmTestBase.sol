// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.36;

import {BoldTestSupport} from "test/utils/BoldTestSupport.sol";
import {Test} from "forge-std/Test.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";

/// @title AmmTestBase
/// @notice Shared scaffolding for the surviving AMM-adjacent suites
///         (`AmmStorage` / `AmmDepositSeeding` / `AmmKillSwitch` and the
///         GP.11.10 disaster-recovery suites): the canonical deployment
///         configs and the BOLD etch.  The L1 embedded AMM was EXCISED
///         under the one-AMM L2-primary topology — the user-facing swap
///         is the L2 `Laws.reserveSwap` over the reserve actor's live
///         balances — so the old swap-suite helpers (the legacy-liquidity
///         harness, `_seedBothLegs`, the independent `_refOut` reference)
///         are gone with the swap they exercised.
abstract contract AmmTestBase is Test, BoldTestSupport {
    address internal constant BOLD_BREAKER = address(0xB12E6B6E);
    address internal constant BOLD_ADMIN = address(0xAD814);
    /// @dev The GP.11.10 AMM disaster-recovery (kill-switch) role.  Wired into
    ///      `_deployBoldEnabled` so the kill switch + breaker are testable.
    address internal constant AMM_DR = address(0xA33D6);

    uint64 internal constant NATIVE_ETH = 0;
    uint64 internal constant BOLD_RID = 1;

    /// @dev Funds fee-split deposits in the seeding suites.
    address internal lp = address(0x11D);

    function setUp() public virtual {
        vm.deal(lp, type(uint128).max);
    }

    // ------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------

    /// @notice The canonical BOLD-enabled + seed-enabled (80% ratio) +
    ///         kill-switch-enabled (`AMM_DR`) `ConstructorArgs`.  Exposed so
    ///         the constructor-guard test can override a single field.
    ///         (Place a conformant `MockBold` at the pinned BOLD address
    ///         with `_etchBold()` BEFORE deploying — the constructor
    ///         cross-checks `BOLD_TOKEN.symbol()`.)
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
            faultProofRollbackAuthority: address(0),
            erc20ResourceIds: rids,
            erc20TokenAddrs: toks
        });
    }

    /// @notice A BOLD-enabled bridge at the max seed ratio (80%).
    ///         Requires `_etchBold()` first.
    function _deployBoldEnabled() internal returns (KnomosisBridge) {
        return new KnomosisBridge(_boldEnabledArgs());
    }

    /// @notice Etch BOLD then deploy a BOLD-enabled bridge in the right order.
    function _deploySeededReady() internal returns (KnomosisBridge bridge) {
        _etchBold();
        bridge = _deployBoldEnabled();
    }

    /// @notice A BOLD-DISABLED bridge (the BOLD seed leg can never fire).
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
                faultProofRollbackAuthority: address(0),
                erc20ResourceIds: rids,
                erc20TokenAddrs: toks
            })
        );
    }
}
