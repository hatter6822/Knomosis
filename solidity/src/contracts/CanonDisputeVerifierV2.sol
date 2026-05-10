// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Canon  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title CanonDisputeVerifierV2
/// @notice Version 2 of the dispute verifier supporting both
///         fault-proof game settlements (deterministic claim
///         variants) and adjudicator-quorum settlements
///         (`oracleMisreported`).
///
/// Per Workstream-H WU H.9.1.  Replaces V1 for new disputes
/// post-migration; V1 retains authority over its own in-flight
/// disputes for the grace window.
contract CanonDisputeVerifierV2 is ReentrancyGuard {
    /* ---------------------------------------------------------- */
    /* Immutables                                                 */
    /* ---------------------------------------------------------- */

    /// @notice The fault-proof game contract address.
    address public immutable faultProofGame;

    /// @notice The pre-approved adjudicators for oracle disputes.
    address[] public approvedAdjudicators;
    /// @notice The quorum threshold for oracle disputes.
    uint8 public immutable quorumThreshold;

    /// @notice The bridge contract for revertToPriorRoot calls.
    address public immutable bridge;

    /// @notice The sequencer-stake contract (for slashing).
    address public immutable sequencerStake;

    /// @notice The deployment ID for cross-deployment-replay
    ///         protection.
    bytes32 public immutable deploymentId;

    /// @notice The attestor (per V1's discipline).
    address public immutable attestor;

    /* ---------------------------------------------------------- */
    /* Storage                                                    */
    /* ---------------------------------------------------------- */

    enum DisputeStatusV2 {
        Open,
        UpheldByFaultProof,
        UpheldByQuorum,
        Rejected,
        Inconclusive
    }

    /// @notice Per-dispute record.
    struct DisputeRecord {
        DisputeStatusV2 status;
        address         filer;
        bytes32         disputeHash;
        uint64          filedAtBlock;
    }

    mapping(uint256 => DisputeRecord) public disputes;
    uint256 public nextDisputeId;

    /* ---------------------------------------------------------- */
    /* Events                                                     */
    /* ---------------------------------------------------------- */

    event DisputeFiledV2(
        uint256 indexed disputeId,
        address indexed filer,
        bytes32 disputeHash
    );

    event DisputeUpheldByFaultProof(
        uint256 indexed disputeId,
        uint256 indexed gameId,
        uint64  revertFromIdx
    );

    event DisputeUpheldByQuorum(
        uint256 indexed disputeId,
        address indexed adjudicator
    );

    event DisputeRejected(uint256 indexed disputeId);

    /* ---------------------------------------------------------- */
    /* Errors                                                     */
    /* ---------------------------------------------------------- */

    error ZeroAddress();
    error NotFaultProofGame();
    error UnknownDispute();
    error AlreadyDecided();
    error InsufficientQuorum();
    error NotApprovedAdjudicator();

    /* ---------------------------------------------------------- */
    /* Constructor                                                */
    /* ---------------------------------------------------------- */

    constructor(
        address _faultProofGame,
        address[] memory _approvedAdjudicators,
        uint8   _quorumThreshold,
        address _bridge,
        address _sequencerStake,
        address _attestor,
        bytes32 _deploymentId
    ) {
        if (_faultProofGame == address(0)) revert ZeroAddress();
        if (_bridge == address(0)) revert ZeroAddress();

        faultProofGame = _faultProofGame;
        approvedAdjudicators = _approvedAdjudicators;
        quorumThreshold = _quorumThreshold;
        bridge = _bridge;
        sequencerStake = _sequencerStake;
        attestor = _attestor;
        deploymentId = _deploymentId;
    }

    /* ---------------------------------------------------------- */
    /* External: fileDispute                                      */
    /* ---------------------------------------------------------- */

    function fileDispute(bytes32 disputeHash) external returns (uint256) {
        uint256 id = ++nextDisputeId;
        disputes[id] = DisputeRecord({
            status:       DisputeStatusV2.Open,
            filer:        msg.sender,
            disputeHash:  disputeHash,
            filedAtBlock: uint64(block.number)
        });
        emit DisputeFiledV2(id, msg.sender, disputeHash);
        return id;
    }

    /* ---------------------------------------------------------- */
    /* External: finaliseFromFaultProof                           */
    /* ---------------------------------------------------------- */

    /// @notice Called by the fault-proof game contract when a
    ///         settlement results in challenger-wins.  Triggers
    ///         the bridge's revertStateRootsFrom.
    function finaliseFromFaultProof(
        uint256 disputeId,
        uint256 gameId,
        uint64  revertFromIdx
    ) external nonReentrant {
        if (msg.sender != faultProofGame) revert NotFaultProofGame();

        DisputeRecord storage d = disputes[disputeId];
        if (d.filedAtBlock == 0) revert UnknownDispute();
        if (d.status != DisputeStatusV2.Open) revert AlreadyDecided();

        d.status = DisputeStatusV2.UpheldByFaultProof;

        // Trigger the rollback on the bridge.
        (bool ok, ) = bridge.call(
            abi.encodeWithSignature("revertStateRootsFrom(uint64)",
                                    revertFromIdx));
        require(ok, "BridgeRevertFailed");

        emit DisputeUpheldByFaultProof(disputeId, gameId, revertFromIdx);
    }

    /* ---------------------------------------------------------- */
    /* External: finaliseFromQuorum (oracleMisreported only)      */
    /* ---------------------------------------------------------- */

    /// @notice Called by an approved adjudicator with quorum
    ///         signatures.  Used for `oracleMisreported`-class
    ///         disputes which the fault-proof game cannot
    ///         discharge.
    function finaliseFromQuorum(
        uint256 disputeId,
        address[] calldata signers
    ) external nonReentrant {
        DisputeRecord storage d = disputes[disputeId];
        if (d.filedAtBlock == 0) revert UnknownDispute();
        if (d.status != DisputeStatusV2.Open) revert AlreadyDecided();

        // Quorum verification: count approved signers.
        uint256 approved = 0;
        for (uint256 i = 0; i < signers.length; i++) {
            for (uint256 j = 0; j < approvedAdjudicators.length; j++) {
                if (signers[i] == approvedAdjudicators[j]) {
                    approved++;
                    break;
                }
            }
        }
        if (approved < quorumThreshold) revert InsufficientQuorum();

        d.status = DisputeStatusV2.UpheldByQuorum;
        emit DisputeUpheldByQuorum(disputeId, msg.sender);
    }

    /* ---------------------------------------------------------- */
    /* assertConsistent                                           */
    /* ---------------------------------------------------------- */

    function assertConsistent() external view {
        require(faultProofGame != address(0), "ZeroFaultProofGame");
        require(bridge != address(0), "ZeroBridge");
    }
}
