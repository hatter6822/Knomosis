// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title IKnomosisSequencerStake
/// @notice External-facing surface of `KnomosisSequencerStake.sol`.
interface IKnomosisSequencerStake {
    function deploymentId() external view returns (bytes32);
    function sequencer() external view returns (address);
    function disputeVerifier() external view returns (address);
    function bridge() external view returns (address);
    function slashRatioBps() external view returns (uint256);
    function disputeWindowBlocks() external view returns (uint64);
    function totalStaked() external view returns (uint256);
    function isSlashed(uint64 disputeId) external view returns (bool);

    /// @notice Wei credited to `challenger` by past slashes, awaiting
    ///         `claimSlashReward()`.
    function slashCredit(address challenger) external view returns (uint256);

    /// @notice Called by the dispute verifier on `.upheld` finalisation.
    ///         Credits `slashRatioBps * stake / 10000` to the
    ///         challenger and burns the residual.  Idempotent on
    ///         `disputeId`.
    ///
    ///         The challenger's cut is **credited, not transferred** —
    ///         see `KnomosisSequencerStake.slashCredit`.  Pushing it
    ///         would let a challenger that rejects ETH revert the
    ///         finalisation awarding it, leaving the dispute open and
    ///         the stake locked.
    function slash(uint64 disputeId, address challenger) external;

    /// @notice Withdraw every slash reward credited to the caller.
    function claimSlashReward() external returns (uint256);
}
