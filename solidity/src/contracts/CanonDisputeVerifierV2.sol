// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/// @title CanonDisputeVerifierV2
/// @notice Version 2 of the dispute verifier supporting both
///         fault-proof game settlements (deterministic claim
///         variants) and adjudicator-quorum settlements
///         (`oracleMisreported`).
///
/// Per Workstream-H WU H.9.1.  Replaces V1 for new disputes
/// post-migration; V1 retains authority over its own in-flight
/// disputes for the grace window.
///
/// **Security model (mirrors V1's discipline).**
///   * `finaliseFromQuorum` requires both `signers` AND `sigs`,
///     and verifies each ECDSA signature against a canonical
///     verdict digest before counting toward the quorum.  This
///     mirrors V1's `_countVerifiedSignatures` pattern.
///   * `finaliseFromFaultProof` is gated to `msg.sender ==
///     faultProofGame`; the game contract is the only path that
///     can trigger a fault-proof rollback.
///   * Both finalisations check `status == Open` to prevent
///     double-finalisation.
contract CanonDisputeVerifierV2 is ReentrancyGuard {
    /* ---------------------------------------------------------- */
    /* Immutables                                                 */
    /* ---------------------------------------------------------- */

    /// @notice The fault-proof game contract address.  Only this
    ///         contract may call `finaliseFromFaultProof`.
    address public immutable faultProofGame;

    /// @notice The state-root submission contract.  Receives the
    ///         `revertStateRootsFrom` call on challenger-wins.
    address public immutable stateRootSubmission;

    /// @notice The pre-approved adjudicators for oracle disputes.
    address[] public approvedAdjudicators;

    /// @notice Approved-adjudicator membership map (O(1) lookup).
    mapping(address => bool) public isApprovedAdjudicator;

    /// @notice The quorum threshold for oracle disputes.
    uint8 public immutable quorumThreshold;

    /// @notice Maximum number of signers accepted in a single
    ///         `finaliseFromQuorum` call.  DoS protection.
    uint256 public constant MAX_VERDICT_SIGNERS = 64;

    /// @notice Verdict outcome tags used in the digest binding.
    uint8 public constant VERDICT_UPHELD   = 1;
    uint8 public constant VERDICT_REJECTED = 2;

    /// @notice The bridge contract.  Reserved for forward-looking
    ///         bridge-state queries; the canonical rollback path
    ///         is through `stateRootSubmission.revertStateRootsFrom`.
    address public immutable bridge;

    /// @notice The sequencer-stake contract (for slashing).
    address public immutable sequencerStake;

    /// @notice The deployment ID for cross-deployment-replay
    ///         protection (binds to verdict digests).
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
        address indexed caller,
        uint256 verifiedSignerCount
    );

    event DisputeRejectedByQuorum(
        uint256 indexed disputeId,
        address indexed caller,
        uint256 verifiedSignerCount
    );

    event DisputeRejected(uint256 indexed disputeId);

    /* ---------------------------------------------------------- */
    /* Errors                                                     */
    /* ---------------------------------------------------------- */

    error ZeroAddress();
    error NotFaultProofGame();
    error UnknownDispute();
    error AlreadyDecided();
    error InsufficientQuorum(uint256 verified, uint256 threshold);
    error NotApprovedAdjudicator();
    error TooManySigners(uint256 supplied, uint256 maxAllowed);
    error SignerSignatureCountMismatch();
    error QuorumThresholdZero();
    error QuorumThresholdAboveSetSize();

    /* ---------------------------------------------------------- */
    /* Constructor                                                */
    /* ---------------------------------------------------------- */

    constructor(
        address _faultProofGame,
        address _stateRootSubmission,
        address[] memory _approvedAdjudicators,
        uint8   _quorumThreshold,
        address _bridge,
        address _sequencerStake,
        address _attestor,
        bytes32 _deploymentId
    ) {
        if (_faultProofGame == address(0)) revert ZeroAddress();
        if (_stateRootSubmission == address(0)) revert ZeroAddress();
        if (_bridge == address(0)) revert ZeroAddress();
        if (_quorumThreshold == 0) revert QuorumThresholdZero();
        if (_quorumThreshold > _approvedAdjudicators.length)
            revert QuorumThresholdAboveSetSize();

        faultProofGame       = _faultProofGame;
        stateRootSubmission  = _stateRootSubmission;
        approvedAdjudicators = _approvedAdjudicators;
        quorumThreshold      = _quorumThreshold;
        bridge               = _bridge;
        sequencerStake       = _sequencerStake;
        attestor             = _attestor;
        deploymentId         = _deploymentId;

        // Populate the O(1) lookup map.  Duplicate addresses are
        // collapsed (an adjudicator listed twice still counts as
        // one).
        for (uint256 i = 0; i < _approvedAdjudicators.length; i++) {
            isApprovedAdjudicator[_approvedAdjudicators[i]] = true;
        }
    }

    /* ---------------------------------------------------------- */
    /* External: fileDispute                                      */
    /* ---------------------------------------------------------- */

    /// @notice File a new dispute.  Any account may file; off-chain
    ///         observers are expected to filter junk before passing
    ///         to the resolver.  No bond at this layer — the
    ///         `CanonFaultProofGame` charges its own bond on
    ///         `initiateChallenge`.
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
    ///         settlement results in challenger-wins.  Marks the
    ///         dispute as upheld-by-fault-proof.
    function finaliseFromFaultProof(
        uint256 disputeId,
        uint256 gameId,
        uint64  revertFromIdx
    ) external nonReentrant {
        if (msg.sender != faultProofGame) revert NotFaultProofGame();

        DisputeRecord storage d = disputes[disputeId];
        if (d.filedAtBlock == 0) revert UnknownDispute();
        if (d.status != DisputeStatusV2.Open) revert AlreadyDecided();

        // Effects first (CEI ordering).
        d.status = DisputeStatusV2.UpheldByFaultProof;

        // The state-root rollback is executed directly by
        // `CanonFaultProofGame` during settlement.  This contract
        // only records the verifier-side dispute outcome.

        emit DisputeUpheldByFaultProof(disputeId, gameId, revertFromIdx);
    }

    /* ---------------------------------------------------------- */
    /* External: finaliseFromQuorum (oracleMisreported only)      */
    /* ---------------------------------------------------------- */

    /// @notice Called by anyone with quorum-many adjudicator
    ///         signatures of the UPHELD verdict digest.  Used for
    ///         `oracleMisreported`-class disputes which the fault-
    ///         proof game cannot discharge.
    ///
    ///         Mirrors V1's `_countVerifiedSignatures`: each
    ///         distinct approved-adjudicator signature contributes
    ///         at most 1; non-approved signers are discarded;
    ///         malformed signatures are discarded; duplicates are
    ///         deduplicated.
    function finaliseFromQuorum(
        uint256 disputeId,
        uint8 outcome,
        address[] calldata signers,
        bytes[] calldata sigs
    ) external nonReentrant {
        if (signers.length != sigs.length)
            revert SignerSignatureCountMismatch();
        if (signers.length > MAX_VERDICT_SIGNERS)
            revert TooManySigners(signers.length, MAX_VERDICT_SIGNERS);
        if (outcome != VERDICT_UPHELD && outcome != VERDICT_REJECTED)
            revert UnknownDispute();  // reuse error for invalid outcome

        DisputeRecord storage d = disputes[disputeId];
        if (d.filedAtBlock == 0) revert UnknownDispute();
        if (d.status != DisputeStatusV2.Open) revert AlreadyDecided();

        // Compute the canonical verdict digest the adjudicators
        // must have signed.  Binds (deploymentId, disputeId,
        // disputeHash, outcome) to prevent cross-dispute replay.
        bytes32 digest = verdictDigest(disputeId, d.disputeHash, outcome);

        // Quorum verification: count approved-adjudicator signers
        // whose signatures verify.
        uint256 verified = _countVerifiedSignatures(digest, signers, sigs);
        if (verified < quorumThreshold)
            revert InsufficientQuorum(verified, quorumThreshold);

        // Effects-after-checks (no further external calls).
        if (outcome == VERDICT_UPHELD) {
            d.status = DisputeStatusV2.UpheldByQuorum;
            emit DisputeUpheldByQuorum(disputeId, msg.sender, verified);
        } else {
            d.status = DisputeStatusV2.Rejected;
            emit DisputeRejectedByQuorum(disputeId, msg.sender, verified);
        }
    }

    /* ---------------------------------------------------------- */
    /* Internal: signature verification                           */
    /* ---------------------------------------------------------- */

    /// @notice Canonical verdict digest the adjudicators sign.
    ///         Binds (deploymentId, disputeId, disputeHash, outcome)
    ///         so a signature for one dispute can't be replayed for
    ///         another, and one outcome can't be replayed for the
    ///         opposite outcome.
    function verdictDigest(
        uint256 disputeId,
        bytes32 disputeHash,
        uint8 outcome
    ) public view returns (bytes32) {
        return keccak256(abi.encode(
            "CanonDisputeVerifierV2.verdict",
            deploymentId,
            disputeId,
            disputeHash,
            outcome));
    }

    /// @notice Per-signer-deduplicated quorum count.  A signer
    ///         with one valid signature counts at most 1
    ///         regardless of duplicate listings.  Non-approved
    ///         signers and invalid signatures are discarded.
    function _countVerifiedSignatures(
        bytes32 digest,
        address[] calldata signers,
        bytes[] calldata sigs
    ) internal view returns (uint256) {
        // Quadratic dedup over signers — bounded by
        // MAX_VERDICT_SIGNERS = 64 in the worst case.
        address[] memory seen = new address[](signers.length);
        uint256 seenLen = 0;

        for (uint256 i = 0; i < signers.length; ++i) {
            address s = signers[i];
            if (s == address(0)) continue;
            if (!isApprovedAdjudicator[s]) continue;
            if (sigs[i].length != 65) continue;

            // Deduplication: skip if we've already counted this
            // signer.
            bool already;
            for (uint256 j = 0; j < seenLen; ++j) {
                if (seen[j] == s) { already = true; break; }
            }
            if (already) continue;

            // Recover the signing address from the signature.  OZ
            // ECDSA enforces canonical signature shape (length 65,
            // s-value in lower half, etc.) and reverts on malformed
            // input.  We wrap in a try-catch via a self-call so a
            // malformed signature doesn't kill the whole quorum
            // tally.
            try this.tryRecover(digest, sigs[i]) returns (address rec) {
                if (rec == s) {
                    seen[seenLen++] = s;
                }
            } catch {
                // Malformed signature: discard, continue tallying.
            }
        }
        return seenLen;
    }

    /// @notice External wrapper for `ECDSA.recover` so we can use
    ///         try-catch within the same contract.  Reverts on
    ///         malformed signature.
    function tryRecover(bytes32 digest, bytes calldata sig)
        external pure returns (address)
    {
        return ECDSA.recover(digest, sig);
    }

    /* ---------------------------------------------------------- */
    /* View: approved adjudicator query                           */
    /* ---------------------------------------------------------- */

    /// @notice Whether `addr` is in the approved-adjudicator set.
    function isApproved(address addr) external view returns (bool) {
        return isApprovedAdjudicator[addr];
    }

    /// @notice Size of the approved-adjudicator set (deduplicated).
    function approvedAdjudicatorCount() external view returns (uint256) {
        return approvedAdjudicators.length;
    }

    /* ---------------------------------------------------------- */
    /* assertConsistent                                           */
    /* ---------------------------------------------------------- */

    function assertConsistent() external view {
        require(faultProofGame != address(0), "ZeroFaultProofGame");
        require(stateRootSubmission != address(0), "ZeroStateRootSubmission");
        require(bridge != address(0), "ZeroBridge");
        require(quorumThreshold > 0, "QuorumThresholdZero");
        require(quorumThreshold <= approvedAdjudicators.length,
                "QuorumThresholdAboveSetSize");
    }
}
