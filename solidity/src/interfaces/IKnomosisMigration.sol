// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title IKnomosisMigration
/// @notice External-facing surface of `KnomosisMigration.sol` — the
///         attested-handoff mechanism per §9.5 / §20 of the Ethereum
///         integration plan.  Read by `KnomosisBridge`'s `circuitOpen`
///         modifier on every state-shaping call.
interface IKnomosisMigration {
    /// @notice Whether the migration has activated.  One-way:
    ///         starts `false`; transitions to `true` exactly once
    ///         after `activate()` is called post-grace-window;
    ///         never transitions back.
    function activated() external view returns (bool);

    /// @notice The predecessor `KnomosisBridge` whose state is being
    ///         handed off.  Immutable.
    function predecessor() external view returns (address);

    /// @notice The successor `KnomosisBridge` accepting the handoff.
    ///         Immutable.
    function successor() external view returns (address);

    /// @notice The block at which the migration was deployed
    ///         (constructor-recorded).  `activate()` requires
    ///         `block.number >= proposedAtBlock + graceWindowBlocks`.
    function proposedAtBlock() external view returns (uint256);

    /// @notice The grace window in blocks.  Constructor-bounded by
    ///         `MIN_GRACE_WINDOW_BLOCKS`.  Immutable.
    function graceWindowBlocks() external view returns (uint256);

    /// @notice The state root captured at construction time.  All
    ///         proofs at this root or earlier remain redeemable on
    ///         the predecessor post-activation.
    function migrationStateRoot() external view returns (bytes32);

    /// @notice The log-index-high of `migrationStateRoot`.
    function migrationStateRootLogIdx() external view returns (uint64);
}
