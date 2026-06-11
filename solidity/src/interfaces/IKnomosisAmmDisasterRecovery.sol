// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title IKnomosisAmmDisasterRecovery
/// @notice The slice of `KnomosisBridge.sol` consumed by the holder of the
///         `ammDisasterRecovery` role (WU GP.11.10) — the one-way embedded-AMM
///         kill switch and its observable flag.  Mirrors the single-purpose
///         interface pattern of `IKnomosisMigration` so the reference
///         multisig (`KnomosisAmmDisasterRecoveryMultisig`) depends on
///         exactly the two members it needs, not the full bridge ABI.
interface IKnomosisAmmDisasterRecovery {
    /// @notice Operator-triggered emergency pause of the embedded AMM (the
    ///         GP.11.10 disaster-recovery kill switch).  Callable only by
    ///         the bridge's immutable `ammDisasterRecovery` role; one-way
    ///         (`ammDisabled` can never be reset within a deployment).
    function emergencyDisableAmm() external;

    /// @notice Whether the one-way kill switch has fired.  Once `true`,
    ///         `ammSwap` reverts `AmmIsDisabled` and deposit-time AMM
    ///         seeding stops; the reserves themselves are preserved.
    function ammDisabled() external view returns (bool);
}
