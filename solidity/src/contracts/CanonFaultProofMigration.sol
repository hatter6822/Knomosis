// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Canon  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

/// @title CanonFaultProofMigration
/// @notice Workstream-H migration handoff contract.  Moves
///         authority from V1 (Phase-6 quorum-only dispute verifier)
///         to V2 (`CanonDisputeVerifierV2` with fault-proof game
///         support).
///
/// Per Workstream-H WUs H.9.2 + H.9.4.  Mirrors `CanonMigration.sol`
/// (Workstream E §20) with audit-3 bidirectional consent: the
/// predecessor must pre-commit by setting its `migration` immutable
/// to point at this contract, and the predecessor (not the successor)
/// is what freezes on activation.
contract CanonFaultProofMigration {
    /* ---------------------------------------------------------- */
    /* Immutables                                                 */
    /* ---------------------------------------------------------- */

    /// @notice The grace window (must be ≥ 30 days = 216_000
    ///         blocks at 12 s).  Mirrors `MIN_GRACE_WINDOW_BLOCKS`.
    uint64  public immutable graceWindowBlocks;

    /// @notice The block at which migration was deployed.
    uint64  public immutable deployedAtBlock;

    /// @notice The earliest block at which migration may activate.
    uint64  public immutable earliestActivationBlock;

    /// @notice The V1 dispute-verifier contract (will be frozen on
    ///         activation).
    address public immutable predecessor;

    /// @notice The V2 dispute-verifier contract (takes authority
    ///         on activation).
    address public immutable successor;

    /// @notice V1's last-finalised log entry hash (for V2's
    ///         hash-chain bootstrap).
    bytes32 public immutable v1LastFinalisedLogEntryHash;

    /// @notice V1's last-finalised log index.
    uint64  public immutable v1LastFinalisedLogIndex;

    /// @notice The deployment ID for cross-deployment-replay
    ///         protection.
    bytes32 public immutable deploymentId;

    /* ---------------------------------------------------------- */
    /* Storage                                                    */
    /* ---------------------------------------------------------- */

    /// @notice Activated flag.  Once set, the predecessor's
    ///         dispute-verifier path is frozen.
    bool public activated;

    /// @notice Activation block (set on `activate`).
    uint64 public activatedAtBlock;

    /* ---------------------------------------------------------- */
    /* Events                                                     */
    /* ---------------------------------------------------------- */

    event MigrationActivated(
        uint64 indexed activationBlock,
        address indexed predecessor,
        address indexed successor
    );

    /* ---------------------------------------------------------- */
    /* Errors                                                     */
    /* ---------------------------------------------------------- */

    error ZeroAddress();
    error GraceTooShort();
    error AlreadyActivated();
    error NotYetActivatable();
    error PredecessorDoesNotReferenceThisMigration();

    /* ---------------------------------------------------------- */
    /* Constructor                                                */
    /* ---------------------------------------------------------- */

    /// @notice Minimum grace window: 30 days at 12 s/block.
    uint64 public constant MIN_GRACE_WINDOW_BLOCKS = 216_000;

    constructor(
        uint64  _graceWindowBlocks,
        address _predecessor,
        address _successor,
        bytes32 _v1LastFinalisedLogEntryHash,
        uint64  _v1LastFinalisedLogIndex,
        bytes32 _deploymentId
    ) {
        if (_predecessor == address(0)) revert ZeroAddress();
        if (_successor == address(0)) revert ZeroAddress();
        if (_graceWindowBlocks < MIN_GRACE_WINDOW_BLOCKS)
            revert GraceTooShort();

        // Bidirectional consent (audit-3): the predecessor must
        // already point at THIS migration contract.
        try
          IPredecessorMigration(_predecessor).migration()
        returns (address predecessorTarget) {
            if (predecessorTarget != address(this))
                revert PredecessorDoesNotReferenceThisMigration();
        } catch {
            // Predecessor doesn't expose `migration()` ⇒ not a
            // canonical V1 deployment.
            revert PredecessorDoesNotReferenceThisMigration();
        }

        graceWindowBlocks            = _graceWindowBlocks;
        deployedAtBlock              = uint64(block.number);
        earliestActivationBlock      = uint64(block.number) + _graceWindowBlocks;
        predecessor                  = _predecessor;
        successor                    = _successor;
        v1LastFinalisedLogEntryHash  = _v1LastFinalisedLogEntryHash;
        v1LastFinalisedLogIndex      = _v1LastFinalisedLogIndex;
        deploymentId                 = _deploymentId;
        activated                    = false;
    }

    /* ---------------------------------------------------------- */
    /* External: activate                                         */
    /* ---------------------------------------------------------- */

    /// @notice Activate the migration.  Anyone may call after
    ///         the grace window expires.
    function activate() external {
        if (activated) revert AlreadyActivated();
        if (block.number < earliestActivationBlock)
            revert NotYetActivatable();

        activated = true;
        activatedAtBlock = uint64(block.number);

        emit MigrationActivated(uint64(block.number),
                                predecessor, successor);
    }

    /* ---------------------------------------------------------- */
    /* assertConsistent                                           */
    /* ---------------------------------------------------------- */

    function assertConsistent() external view {
        require(predecessor != address(0), "ZeroPredecessor");
        require(successor != address(0), "ZeroSuccessor");
        require(graceWindowBlocks >= MIN_GRACE_WINDOW_BLOCKS,
                "GraceTooShort");
    }
}

/// @notice Interface for accessing a predecessor contract's
///         `migration` immutable.  Used for bidirectional consent.
interface IPredecessorMigration {
    function migration() external view returns (address);
}
