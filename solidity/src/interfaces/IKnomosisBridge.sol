// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title IKnomosisBridge
/// @notice External-facing surface of `KnomosisBridge.sol`.  Exposes the
///         immutable getters that other Knomosis contracts (specifically
///         `KnomosisMigration` and `KnomosisDisputeVerifier`) need at
///         construction-time to validate cross-contract reference
///         consistency.
/// @dev    Per the §20 Immutability amendment of the Ethereum integration
///         plan, every state-shaping field surfaced through this
///         interface is `immutable` in the implementing contract.  The
///         remaining mutable getters (`stateRoots`, `latestSubmittedLogIndexHigh`,
///         `lastUpheldDisputeBlock`, `totalLockedValue`) report state
///         that evolves *only* through proof-gated entry points.
interface IKnomosisBridge {
    /// @notice The cryptographic deployment-id mirror of the Lean
    ///         `signInput` deploymentId (§8.8.5).  Derived in the
    ///         constructor as
    ///         `keccak256(abi.encode(block.chainid, address(this), knomosisVersionTag))`
    ///         and `immutable` thereafter.
    function deploymentId() external view returns (bytes32);

    /// @notice The attestor address authorised to call `submitStateRoot`.
    ///         Set in the constructor; immutable.
    function attestor() external view returns (address);

    /// @notice The `KnomosisDisputeVerifier` address authorised to call
    ///         `revertToPriorRoot`.  Set in the constructor; immutable.
    function disputeVerifier() external view returns (address);

    /// @notice The `KnomosisSequencerStake` address authorised to read the
    ///         dispute open-ness predicate via `hasOpenDisputeOlderThan`.
    ///         Set in the constructor; immutable.
    function sequencerStake() external view returns (address);

    /// @notice The `KnomosisMigration` address (may be `address(0)` if no
    ///         migration has been deployed for this bridge).  Set in
    ///         the constructor; immutable.  Per §9.5 the predecessor
    ///         records the migration address at construction time;
    ///         the migration's constructor verifies that this getter
    ///         points back at it.
    function migration() external view returns (address);

    /// @notice Length of the dispute window (in blocks).  Immutable.
    function disputeWindowBlocks() external view returns (uint64);

    /// @notice Block at which the latest state root was submitted.
    ///         Mutable; updated only by `submitStateRoot`.  Used by
    ///         the `AttestationStale` circuit breaker.
    function latestStateRootSubmittedAtBlock() external view returns (uint64);

    /// @notice Block of the most recent `.upheld` dispute.  Mutable;
    ///         updated only by `revertToPriorRoot`.  Used by the
    ///         `DisputeCooldown` circuit breaker.
    function lastUpheldDisputeBlock() external view returns (uint64);

    /// @notice Sum of L1-locked value (deposits − withdrawals).
    ///         Mutable; updated by deposit / withdraw paths.  Used by
    ///         the `TvlCapReached` circuit breaker.
    function totalLockedValue() external view returns (uint256);

    /// @notice Whether there is a `.open` (filed but not finalised)
    ///         dispute against any state root submitted before the
    ///         block height threshold.  Used by `KnomosisSequencerStake`
    ///         to lock sequencer stake withdrawals.
    function hasOpenDisputeOlderThan(uint64 thresholdBlock) external view returns (bool);

    /// @notice The state-root-submission ledger.  `logIndexHigh` →
    ///         (root, submittedAtBlock, reverted).  Storage layout
    ///         is implementation-internal; this getter is the
    ///         well-typed surface.
    function stateRootAt(uint64 logIndexHigh)
        external
        view
        returns (bytes32 root, uint64 submittedAtBlock, bool reverted);

    /// @notice Whether the state root at `logIndexHigh` is finalised
    ///         (non-reverted, dispute window elapsed).  Computed on
    ///         the fly from the ledger; no separate setter.
    function isStateRootFinalised(uint64 logIndexHigh) external view returns (bool);

    /// @notice Called only by the `disputeVerifier`.  Marks all state
    ///         roots from `disputedLogIndexHigh` onward as reverted
    ///         and updates `lastUpheldDisputeBlock` so the
    ///         `DisputeCooldown` breaker trips.  See E.1.5.
    function revertToPriorRoot(uint64 disputedLogIndexHigh) external;
}
