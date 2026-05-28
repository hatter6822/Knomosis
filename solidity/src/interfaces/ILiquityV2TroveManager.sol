// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title ILiquityV2TroveManager
/// @notice Minimal read-only view of a Liquity V2 collateral-branch
///         `TroveManager`, consulted by `KnomosisBridge`'s permissionless
///         BOLD depeg auto-trigger (`closeBoldCircuitIfAnyLiquityBranchShutdown`,
///         Workstream GP.5.5).
///
/// @dev    Liquity V2's per-branch `shutdownTime` is the canonical on-chain
///         signal that a collateral branch has been wound down (oracle
///         failure, governance, etc.): it is `0` while the branch is
///         operating normally and is set to the wind-down block timestamp
///         the moment a branch enters shutdown.  A shutdown branch
///         materially weakens BOLD's backing, so any non-zero
///         `shutdownTime` on any of BOLD's collateral branches is a hard
///         "halt new BOLD deposits" indicator.
///
///         Only the single `shutdownTime()` view is declared so the
///         coupling to Liquity V2 is as narrow as possible.  The bridge
///         calls this via `staticcall` with strict `success` /
///         `returndata.length` checks, so an incompatible / absent /
///         re-entrant TroveManager degrades to a clean
///         `LiquityV2ReadFailed` rather than an opaque revert.
interface ILiquityV2TroveManager {
    /// @notice The block timestamp at which this branch entered
    ///         shutdown, or `0` if the branch is operating normally.
    ///         Once non-zero, this never resets to zero — branch
    ///         shutdown is monotonic in Liquity V2.
    function shutdownTime() external view returns (uint256);
}
