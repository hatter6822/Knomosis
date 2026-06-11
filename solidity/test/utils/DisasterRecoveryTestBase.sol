// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisAmmDisasterRecoveryMultisig} from
    "src/contracts/KnomosisAmmDisasterRecoveryMultisig.sol";
import {AmmTestBase} from "test/utils/AmmTestBase.sol";

/// @title DisasterRecoveryTestBase
/// @notice Shared scaffolding for the WU GP.11.10 disaster-recovery multisig
///         suites (`KnomosisAmmDisasterRecoveryMultisig.t.sol` unit suite and
///         the stateful invariant harness): the canonical 3-of-5 signer set
///         (operator + community representatives + auditor per the GP.11.10
///         custody spec) and the production predicted-address wiring where
///         the multisig is the bridge's `ammDisasterRecovery` role.
abstract contract DisasterRecoveryTestBase is AmmTestBase {
    /// @dev The canonical 3-of-5 signer set.
    address internal constant SIGNER_OPERATOR = address(0xD801);
    address internal constant SIGNER_COMMUNITY_A = address(0xD802);
    address internal constant SIGNER_COMMUNITY_B = address(0xD803);
    address internal constant SIGNER_AUDITOR = address(0xD804);
    address internal constant SIGNER_BACKUP = address(0xD805);
    /// @dev Never a signer; exercises the `NotSigner` paths.
    address internal constant OUTSIDER = address(0xBAD);

    function _signerSet() internal pure returns (address[] memory s) {
        s = new address[](5);
        s[0] = SIGNER_OPERATOR;
        s[1] = SIGNER_COMMUNITY_A;
        s[2] = SIGNER_COMMUNITY_B;
        s[3] = SIGNER_AUDITOR;
        s[4] = SIGNER_BACKUP;
    }

    /// @notice Deploy the production wiring: the multisig is constructed
    ///         FIRST against the bridge's predicted CREATE address, then
    ///         the bridge pins `ammDisasterRecovery = address(multisig)` —
    ///         the same predicted-address pre-wiring pattern production
    ///         deployments use for `KnomosisMigration`.
    function _deployWired()
        internal
        returns (KnomosisAmmDisasterRecoveryMultisig multisig, KnomosisBridge bridge)
    {
        _etchBold();
        // The multisig deploy consumes one nonce, so the bridge lands at
        // nonce + 1.
        address predictedBridge =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        multisig = new KnomosisAmmDisasterRecoveryMultisig(predictedBridge, _signerSet(), 3);
        KnomosisBridge.ConstructorArgs memory args = _boldEnabledArgs();
        args.ammDisasterRecovery = address(multisig);
        bridge = new KnomosisBridge(args);
        assertEq(address(bridge), predictedBridge, "bridge landed at the predicted address");
        assertEq(bridge.ammDisasterRecovery(), address(multisig), "multisig holds the role");
    }

    /// @notice The MISCONFIGURED wiring: the multisig points at a real
    ///         bridge whose `ammDisasterRecovery` role is someone ELSE
    ///         (`AMM_DR`), so the multisig's execution call must revert.
    ///         Used to pin the fail-safe rollback of a threshold-crossing
    ///         confirmation against a bridge that does not recognise the
    ///         quorum.
    function _deployMiswired()
        internal
        returns (KnomosisAmmDisasterRecoveryMultisig multisig, KnomosisBridge bridge)
    {
        _etchBold();
        bridge = _deployBoldEnabled(); // role = AMM_DR, not the multisig
        multisig = new KnomosisAmmDisasterRecoveryMultisig(address(bridge), _signerSet(), 3);
        assertEq(bridge.ammDisasterRecovery(), AMM_DR, "role held by AMM_DR, not the multisig");
    }
}
