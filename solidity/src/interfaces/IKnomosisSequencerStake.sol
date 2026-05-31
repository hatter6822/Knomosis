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

    /// @notice Called by the dispute verifier on `.upheld` finalisation.
    ///         Pays `slashRatioBps * stake / 10000` to the challenger
    ///         and burns the residual.  Idempotent on `disputeId`.
    function slash(uint64 disputeId, address challenger) external;
}
