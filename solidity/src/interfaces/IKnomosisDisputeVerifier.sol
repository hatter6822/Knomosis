// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title IKnomosisDisputeVerifier
/// @notice External-facing surface of `KnomosisDisputeVerifier.sol`.  Exposes
///         the immutable getters used by sibling contracts (notably
///         `KnomosisSequencerStake` for the slashing wiring and
///         `KnomosisBridge` for the construction-time cross-check).
interface IKnomosisDisputeVerifier {
    /// @notice The deployment-id mirror, identical-shape to
    ///         `IKnomosisBridge.deploymentId`.
    function deploymentId() external view returns (bytes32);

    /// @notice The `KnomosisBridge` this verifier is paired with.
    ///         Immutable.
    function bridge() external view returns (address);

    /// @notice The `KnomosisSequencerStake` this verifier slashes.
    ///         Immutable.
    function sequencerStake() external view returns (address);

    /// @notice The `KnomosisIdentityRegistry` consulted for verifying
    ///         signer registration.  Immutable.
    function identityRegistry() external view returns (address);

    /// @notice The `KnomosisMigration` address (may be `address(0)`).
    ///         Immutable.
    function migration() external view returns (address);

    /// @notice Quorum threshold for verdict finalisation; immutable.
    function quorumThreshold() external view returns (uint8);

    /// @notice Whether `addr` is in the snapshotted approved-adjudicator
    ///         set.  Set in the constructor; immutable thereafter.
    function isApprovedAdjudicator(address addr) external view returns (bool);

    /// @notice Whether the dispute with id `disputeId` is in the
    ///         `.open` state (filed, not yet decided).  Used by
    ///         `KnomosisSequencerStake.withdraw` lock-up.
    function isDisputeOpen(uint64 disputeId) external view returns (bool);
}
