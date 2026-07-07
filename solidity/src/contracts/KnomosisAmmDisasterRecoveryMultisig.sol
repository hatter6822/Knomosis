// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {IKnomosisAmmDisasterRecovery} from "src/interfaces/IKnomosisAmmDisasterRecovery.sol";

/// @title KnomosisAmmDisasterRecoveryMultisig
/// @notice WU GP.11.10 — the reference M-of-N (minimum 3-of-N) multisig for
///         the bridge's `ammDisasterRecovery` kill-switch role.  The GP.11.10
///         specification requires the disaster-recovery role to be "a 3-of-N
///         multisig with operator + community representatives + auditor
///         signatures, specified in the deployment configuration"; this
///         contract is the audited reference implementation of that
///         configuration.  Deployments may substitute any battle-tested
///         multisig (e.g. a Safe) — the bridge only sees an address — but
///         this contract makes the 3-of-N floor *constructor-enforced*
///         rather than a deployment-checklist promise.
///
///         **Single-purpose by construction.**  The contract can do exactly
///         one thing: call `emergencyDisableAmm()` on the immutable `bridge`
///         once `threshold` distinct signers have confirmed within one
///         confirmation round.  There is no generic `execute(target, data)`
///         surface, no value transfer, no signer rotation, and no
///         upgradability — the entire attack surface is the confirm /
///         revoke pair.  A compromised quorum can pause the AMM (a
///         capital-preserving, one-way degradation the bridge is designed
///         to survive) but can never move funds, alter state roots, or
///         touch any other bridge control.
///
///         **Stale-confirmation defence.**  Confirmations expire as a group:
///         each confirmation round is `CONFIRMATION_WINDOW` long, anchored
///         at the round's first confirmation.  A confirmation landing after
///         the window opens a fresh round (the stale approvals are
///         discarded), so approvals gathered during one incident can never
///         silently combine with a later signer's to fire the one-way
///         switch long after the original context has passed.  The
///         fail-safe direction is deliberate: an expired round costs the
///         signers a re-confirmation (minutes); a stale-quorum disable
///         would cost a full bridge redeploy (the switch is one-way).
///
/// @dev    Deployment wiring: the bridge pins `ammDisasterRecovery` at
///         construction and this contract pins `bridge` at construction, so
///         one side must be deployed against the other's *predicted* CREATE
///         address — the same pre-wiring pattern production deployments
///         already use for `KnomosisMigration` (see solidity/README.md,
///         "Production deployment notes").  Deploy this multisig first
///         against the predicted bridge address, then deploy the bridge
///         with `ammDisasterRecovery = address(multisig)`, and verify
///         `multisig.bridge() == address(bridge)` before accepting traffic.
contract KnomosisAmmDisasterRecoveryMultisig {
    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice The GP.11.10 floor on the confirmation threshold.  A
    ///         disaster-recovery quorum smaller than 3 collapses the
    ///         "operator + community + auditor" separation the WU
    ///         specifies, so the constructor rejects it
    ///         (`ThresholdBelowMinimum`).
    uint256 public constant MIN_DISABLE_THRESHOLD = 3;

    /// @notice Upper bound on the signer-set size.  A disaster-recovery
    ///         quorum is a small, named group (single digits in the
    ///         GP.11.10 spec); a very large set is a misconfiguration
    ///         smell, so the constructor rejects it (`TooManySigners`).
    uint256 public constant MAX_SIGNERS = 32;

    /// @notice How long a confirmation round stays live, measured from the
    ///         round's FIRST confirmation.  Confirmations arriving after
    ///         the window discard the stale round and start a fresh one.
    ///         Seven days comfortably covers the GP.11.10 invocation
    ///         conditions (the slowest is the 24-hour reserve-depth
    ///         pathology plus deliberation) while bounding how long an
    ///         abandoned approval can linger.
    uint256 public constant CONFIRMATION_WINDOW = 7 days;

    // ------------------------------------------------------------------
    // Immutable configuration
    // ------------------------------------------------------------------

    /// @notice The `KnomosisBridge` whose `emergencyDisableAmm()` this
    ///         multisig is authorised to call.  Set in the constructor;
    ///         immutable.
    IKnomosisAmmDisasterRecovery public immutable bridge;

    /// @notice Number of distinct signer confirmations required within one
    ///         round to fire the kill switch.  Constructor-validated
    ///         `MIN_DISABLE_THRESHOLD <= threshold <= signerCount()`;
    ///         immutable.
    uint256 public immutable threshold;

    /// @notice The fixed signer set.  There is no rotation: replacing a
    ///         signer means deploying a fresh multisig and a fresh bridge
    ///         (the bridge's role is itself immutable), exactly like every
    ///         other Knomosis role key.
    address[] private _signers;

    /// @notice Whether an address is in the signer set.
    mapping(address => bool) public isSigner;

    // ------------------------------------------------------------------
    // Mutable round state
    // ------------------------------------------------------------------

    /// @notice Monotonically increasing confirmation-round id.  Bumped when
    ///         a confirmation arrives after the live round's window has
    ///         expired; per-signer confirmations are scoped to a round, so
    ///         bumping the id discards every stale approval in O(1).
    uint256 public roundId;

    /// @notice Timestamp of the live round's first confirmation (0 when no
    ///         confirmation has ever been recorded).  The round expires at
    ///         `roundStartedAt + CONFIRMATION_WINDOW`.
    uint256 public roundStartedAt;

    /// @notice Number of distinct confirmations in the live round.
    uint256 public confirmationCount;

    /// @notice Whether the kill switch has been fired through this
    ///         multisig.  One-way, mirroring the bridge's own `ammDisabled`.
    bool public executed;

    /// @notice Per-round, per-signer confirmation ledger.  Scoped by
    ///         `roundId` so an expired round's entries become unreachable
    ///         without an O(N) clearing loop.
    mapping(uint256 => mapping(address => bool)) private _confirmedInRound;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// @notice Constructor guard: the bridge address is zero.
    error ZeroBridge();
    /// @notice Constructor guard: the bridge address has no deployed code.
    ///         The multisig is useless against an EOA/undeployed bridge (its
    ///         only action, `bridge.emergencyDisableAmm()`, would silently
    ///         succeed against a codeless address), and the bridge is deployed
    ///         before this multisig in every legitimate order, so reject a
    ///         codeless bridge at construction.
    error BridgeHasNoCode();
    /// @notice Constructor guard: the threshold is below the GP.11.10
    ///         3-of-N floor (`MIN_DISABLE_THRESHOLD`).
    error ThresholdBelowMinimum(uint256 threshold);
    /// @notice Constructor guard: the threshold exceeds the signer count,
    ///         which would make the quorum unreachable.
    error ThresholdExceedsSignerCount(uint256 threshold, uint256 signerCount);
    /// @notice Constructor guard: the signer set exceeds `MAX_SIGNERS`.
    error TooManySigners(uint256 signerCount);
    /// @notice Constructor guard: a signer is the zero address.
    error ZeroSigner();
    /// @notice Constructor guard: a signer appears twice.  Duplicates would
    ///         silently lower the effective quorum.
    error DuplicateSigner(address signer);
    /// @notice Constructor guard: a signer is the bridge itself.  The
    ///         bridge never calls out to arbitrary contracts, so such a
    ///         slot could never confirm — a dead slot that weakens N.
    error SignerIsBridge();
    /// @notice Constructor guard: a signer is this multisig itself.  The
    ///         contract cannot call its own `confirmDisable`, so the slot
    ///         would be dead weight in N.
    error SignerIsSelf();
    /// @notice The caller is not in the signer set.
    error NotSigner();
    /// @notice The kill switch has already been fired through this
    ///         multisig; confirmations and revocations are over.
    error AlreadyExecuted();
    /// @notice The caller has already confirmed in the live round.
    error AlreadyConfirmedThisRound();
    /// @notice The caller has no live confirmation to revoke.
    error NothingToRevoke();

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    /// @notice A signer confirmed the disable in round `roundId`,
    ///         bringing the live count to `confirmations`.
    event DisableConfirmed(address indexed signer, uint256 indexed roundId, uint256 confirmations);

    /// @notice A signer revoked their confirmation in round `roundId`,
    ///         bringing the live count to `confirmations`.
    event DisableConfirmationRevoked(
        address indexed signer, uint256 indexed roundId, uint256 confirmations
    );

    /// @notice A confirmation arrived after round `staleRoundId`'s window
    ///         expired; its approvals were discarded and round
    ///         `newRoundId` opened.
    event ConfirmationRoundExpired(uint256 indexed staleRoundId, uint256 indexed newRoundId);

    /// @notice The threshold was reached and `emergencyDisableAmm()` was
    ///         called on the bridge.
    event AmmDisableExecuted(uint256 indexed roundId, uint256 timestamp);

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    /// @param bridge_    The `KnomosisBridge` to guard.  Usually a predicted
    ///                   CREATE address (see the contract-level deployment
    ///                   note).
    /// @param signers_   The fixed signer set (operator + community
    ///                   representatives + auditor per GP.11.10).  Must be
    ///                   non-zero, pairwise distinct, not the bridge, and
    ///                   not this contract.
    /// @param threshold_ Confirmations required to fire the switch;
    ///                   `MIN_DISABLE_THRESHOLD <= threshold_ <= signers_.length`.
    constructor(address bridge_, address[] memory signers_, uint256 threshold_) {
        if (bridge_ == address(0)) revert ZeroBridge();
        if (bridge_.code.length == 0) revert BridgeHasNoCode();
        if (threshold_ < MIN_DISABLE_THRESHOLD) revert ThresholdBelowMinimum(threshold_);
        if (threshold_ > signers_.length) {
            revert ThresholdExceedsSignerCount(threshold_, signers_.length);
        }
        if (signers_.length > MAX_SIGNERS) revert TooManySigners(signers_.length);

        for (uint256 i = 0; i < signers_.length; ++i) {
            address signer = signers_[i];
            if (signer == address(0)) revert ZeroSigner();
            if (signer == bridge_) revert SignerIsBridge();
            if (signer == address(this)) revert SignerIsSelf();
            if (isSigner[signer]) revert DuplicateSigner(signer);
            isSigner[signer] = true;
        }
        _signers = signers_;
        bridge = IKnomosisAmmDisasterRecovery(bridge_);
        threshold = threshold_;
    }

    // ------------------------------------------------------------------
    // Confirmation flow
    // ------------------------------------------------------------------

    /// @notice Restricts a call to the fixed signer set.
    modifier onlySigner() {
        if (!isSigner[msg.sender]) revert NotSigner();
        _;
    }

    /// @notice Confirm the emergency AMM disable.  The `threshold`-th live
    ///         confirmation fires `bridge.emergencyDisableAmm()` in the
    ///         same transaction — in a disaster, the final signature IS
    ///         the trigger; no separate execute step can be front-run,
    ///         forgotten, or griefed.
    /// @dev    If the live round's window has expired, the stale approvals
    ///         are discarded first and this confirmation opens a fresh
    ///         round (so it never combines with stale ones).  If the bridge
    ///         call reverts, the whole transaction (including this
    ///         confirmation) rolls back — fail-safe and retryable.
    ///         `executed` is set before the external call
    ///         (checks-effects-interactions).
    function confirmDisable() external onlySigner {
        if (executed) revert AlreadyExecuted();

        // Group expiry: a stale round cannot accept its finishing vote.
        // The `block.timestamp` comparison is safe here: validator drift is
        // bounded to seconds against a 7-day window, and the fail-safe
        // direction of any manipulation is a premature round reset (a
        // re-confirmation), never an unauthorised execution.
        // forge-lint: disable-next-line(block-timestamp)
        if (confirmationCount > 0 && block.timestamp > roundStartedAt + CONFIRMATION_WINDOW) {
            uint256 staleRound = roundId;
            roundId = staleRound + 1;
            confirmationCount = 0;
            emit ConfirmationRoundExpired(staleRound, roundId);
        }

        if (_confirmedInRound[roundId][msg.sender]) revert AlreadyConfirmedThisRound();

        if (confirmationCount == 0) {
            roundStartedAt = block.timestamp;
        }
        _confirmedInRound[roundId][msg.sender] = true;
        uint256 live = confirmationCount + 1;
        confirmationCount = live;
        emit DisableConfirmed(msg.sender, roundId, live);

        if (live >= threshold) {
            executed = true;
            emit AmmDisableExecuted(roundId, block.timestamp);
            bridge.emergencyDisableAmm();
        }
    }

    /// @notice Withdraw a live confirmation (a signer who judged the
    ///         incident resolved, or confirmed in error).  Only reduces
    ///         authority, so it is callable at any point before execution.
    function revokeConfirmation() external onlySigner {
        if (executed) revert AlreadyExecuted();
        if (!_confirmedInRound[roundId][msg.sender]) revert NothingToRevoke();
        _confirmedInRound[roundId][msg.sender] = false;
        uint256 live = confirmationCount - 1;
        confirmationCount = live;
        emit DisableConfirmationRevoked(msg.sender, roundId, live);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice The fixed signer set.
    function signers() external view returns (address[] memory) {
        return _signers;
    }

    /// @notice Number of signers (the N in M-of-N).
    function signerCount() external view returns (uint256) {
        return _signers.length;
    }

    /// @notice Whether `signer` has a live confirmation in the current
    ///         round.  Confirmations from expired-but-not-yet-rolled
    ///         rounds still read `true` here until the next confirmation
    ///         rolls the round; pair with `roundExpired()` when deciding
    ///         whether a displayed count is actionable.
    function hasConfirmed(address signer) external view returns (bool) {
        return _confirmedInRound[roundId][signer];
    }

    /// @notice Whether the live round's window has lapsed (its approvals
    ///         will be discarded by the next confirmation).  `false` when
    ///         the round is empty.
    /// @dev    Same `block.timestamp` rationale as the expiry check in
    ///         `confirmDisable`: second-scale validator drift is immaterial
    ///         against the 7-day window and fails safe.
    function roundExpired() public view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return confirmationCount > 0 && block.timestamp > roundStartedAt + CONFIRMATION_WINDOW;
    }
}
