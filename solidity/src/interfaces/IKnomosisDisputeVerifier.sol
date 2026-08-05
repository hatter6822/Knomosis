// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.36;

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
    ///         `.open` state (filed, not yet decided).  Per-dispute
    ///         introspection for tooling; the stake lock-up consults
    ///         the aggregate `openDisputeCount` below, since a slash
    ///         draws on the whole stake and is therefore not
    ///         attributable to one dispute.
    function isDisputeOpen(uint64 disputeId) external view returns (bool);

    /// @notice How many disputes are currently `.open`.
    ///
    ///         `KnomosisSequencerStake.withdraw` refuses while this is
    ///         non-zero: `slash` zeroes the entire stake, so any open
    ///         dispute puts the entire balance at risk and no part of
    ///         it is safely withdrawable.
    function openDisputeCount() external view returns (uint64);

    /// @notice Wei a challenger must post to `fileDispute`.  Refunded
    ///         on UPHELD, forfeited to the sequencer on REJECTED.
    function challengerBond() external view returns (uint256);
}
