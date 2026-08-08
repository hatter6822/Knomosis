// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.36;

/// @title IKnomosisAmmDisasterRecovery
/// @notice The slice of `KnomosisBridge.sol` consumed by the holder of the
///         `ammDisasterRecovery` role (WU GP.11.10) — the one-way kill
///         switch for the L2 AMM (the `Laws.reserveSwap` pool over the
///         reserve actor's balances) and its observable flag.  Mirrors the
///         single-purpose interface pattern of `IKnomosisMigration` so the
///         reference multisig (`KnomosisAmmDisasterRecoveryMultisig`)
///         depends on exactly the two members it needs, not the full
///         bridge ABI.
interface IKnomosisAmmDisasterRecovery {
    /// @notice Operator-triggered emergency pause of the L2 AMM (the
    ///         GP.11.10 disaster-recovery kill switch).  Callable only by
    ///         the bridge's immutable `ammDisasterRecovery` role; one-way
    ///         (`ammDisabled` can never be reset within a deployment).
    function emergencyDisableAmm() external;

    /// @notice Whether the one-way kill switch has fired.  Once `true`,
    ///         deposit-time AMM seeding stops on the L1 and the flag is
    ///         committed to the state root, where the L2 admission gate
    ///         refuses new `reserveSwap`s and `Laws.reclaimAmmReserves`
    ///         becomes admissible to sweep the reserve actor's balances
    ///         back to the gas pool.
    function ammDisabled() external view returns (bool);
}
