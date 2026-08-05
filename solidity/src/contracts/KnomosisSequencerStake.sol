// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.36;

import {IKnomosisSequencerStake} from "src/interfaces/IKnomosisSequencerStake.sol";
import {IKnomosisBridge} from "src/interfaces/IKnomosisBridge.sol";
import {IKnomosisDisputeVerifier} from "src/interfaces/IKnomosisDisputeVerifier.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title KnomosisSequencerStake
/// @notice The sequencer's stake escrow.  On `DisputeUpheld`, the
///         stake is slashed: a `slashRatioBps` portion is paid to
///         the challenger as the reward documented in Phase-6's
///         incentive amendment (`DisputeRewardPolicy`); the
///         residual is sent to the canonical burn address.
///
/// @dev    Per workstream E.4 of the integration plan, this
///         contract is deployed immutably: no proxy, no admin
///         role, no upgrade hook.  All addresses (`sequencer`,
///         `disputeVerifier`, `bridge`) plus `slashRatioBps`,
///         `disputeWindowBlocks`, `burnAddress` are `immutable`.
///         Rotating any of them requires a new deployment plus a
///         `KnomosisMigration` handoff (§9.5).
contract KnomosisSequencerStake is IKnomosisSequencerStake, ReentrancyGuard {
    // ------------------------------------------------------------------
    // Custom errors
    // ------------------------------------------------------------------

    error NotSequencer();
    error NotDisputeVerifier();
    error InsufficientStake();
    error WithdrawDuringOpenDispute();
    error AlreadySlashed(uint64 disputeId);
    error SlashRatioOutOfRange();
    error ZeroAddress();
    error EthSendFailed();
    /// @notice `claimSlashReward()` was called with nothing credited.
    error NothingToClaim();
    /// @notice Constructor guard: a peer address (`disputeVerifier` /
    ///         `bridge`) has no deployed code.  Both are deployed before
    ///         this contract in every legitimate order (backward refs), so a
    ///         codeless peer is a wiring mistake — reject it at construction
    ///         (defence-in-depth beyond the post-deploy `assertConsistent()`).
    error NotAContract();

    // ------------------------------------------------------------------
    // Immutable parameters
    // ------------------------------------------------------------------

    bytes32 public immutable knomosisVersionTag;
    bytes32 public immutable deploymentId;

    address public immutable sequencer;
    address public immutable disputeVerifier;
    address public immutable bridge;
    address public immutable burnAddress;

    /// @notice Slash percentage in basis points (e.g. 5000 = 50%).
    uint256 public immutable slashRatioBps;
    /// @notice Block-window length consulted for stake-withdrawal
    ///         lock-up.  Set in the constructor; immutable.
    uint64 public immutable disputeWindowBlocks;

    // ------------------------------------------------------------------
    // Mutable state
    // ------------------------------------------------------------------

    uint256 public totalStaked;
    mapping(uint64 => bool) private _slashedDispute;

    /// @notice Slash rewards owed to challengers, withdrawn by
    ///         `claimSlashReward()`.
    ///
    ///         The challenger's cut is credited rather than pushed,
    ///         and that is load-bearing now that an open dispute
    ///         blocks `withdraw`.  Under a push model a challenger
    ///         contract with a reverting `receive()` would make
    ///         `slash` revert, `KnomosisDisputeVerifier.finalizeUpheld`
    ///         revert with it, and the dispute stay open forever —
    ///         freezing the whole stake at the cost of one challenger
    ///         bond.  Crediting makes the terminal transition
    ///         unconditional; a recipient that cannot receive ETH only
    ///         strands its own reward.
    ///
    ///         `burnAddress` is not credited: it is a sink chosen at
    ///         deployment and the burn is intended to be
    ///         irrecoverable, so the residual is sent directly.  A
    ///         `burnAddress` that reverts would be a deployment
    ///         error, not an attacker-chosen address.
    mapping(address => uint256) public slashCredit;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Deposited(address indexed sequencer, uint256 amount, uint256 newTotal);
    event Withdrawn(address indexed sequencer, uint256 amount, uint256 newTotal);
    event Slashed(
        uint64 indexed disputeId,
        address indexed challenger,
        uint256 paidToChallenger,
        uint256 burned,
        uint256 newTotal
    );
    /// @notice Emitted when a challenger withdraws a credited slash
    ///         reward.
    event SlashRewardClaimed(address indexed challenger, uint256 amount);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    constructor(
        bytes32 _knomosisVersionTag,
        address _sequencer,
        address _disputeVerifier,
        address _bridge,
        uint256 _slashRatioBps,
        uint64 _disputeWindowBlocks,
        address _burnAddress
    ) {
        if (_slashRatioBps > 10_000) revert SlashRatioOutOfRange();
        if (
            _sequencer == address(0) || _disputeVerifier == address(0)
                || _bridge == address(0) || _burnAddress == address(0)
        ) {
            revert ZeroAddress();
        }
        // Defence-in-depth: `disputeVerifier` and `bridge` are both deployed
        // BEFORE this contract in every legitimate order (the cluster-A cycle
        // deploys Bridge -> DisputeVerifier -> SequencerStake), so a codeless
        // peer here is a wiring mistake, not a deployable cycle.  Reject it at
        // construction.  (The `sequencer` and `burnAddress` are EOAs, so only
        // the zero-check above applies to them.)
        if (_disputeVerifier.code.length == 0) revert NotAContract();
        if (_bridge.code.length == 0) revert NotAContract();
        // Cross-contract back-reference (verifier.sequencerStake() ==
        // address(this)) is checked via the post-deploy
        // `assertConsistent()` view, not in the constructor.  Same
        // rationale as `KnomosisDisputeVerifier`: the back-check is
        // defensive, not load-bearing.
        knomosisVersionTag = _knomosisVersionTag;
        sequencer = _sequencer;
        disputeVerifier = _disputeVerifier;
        bridge = _bridge;
        burnAddress = _burnAddress;
        slashRatioBps = _slashRatioBps;
        disputeWindowBlocks = _disputeWindowBlocks;
        deploymentId =
            keccak256(abi.encode(block.chainid, address(this), _knomosisVersionTag));
    }

    // ------------------------------------------------------------------
    // External: deposit (sequencer-only, payable)
    // ------------------------------------------------------------------

    function deposit() external payable {
        if (msg.sender != sequencer) revert NotSequencer();
        // checked-arithmetic add via 0.8.20 default
        totalStaked += msg.value;
        emit Deposited(msg.sender, msg.value, totalStaked);
    }

    // ------------------------------------------------------------------
    // External: withdraw (sequencer-only, lock-up enforced)
    // ------------------------------------------------------------------

    function withdraw(uint256 amount) external nonReentrant {
        if (msg.sender != sequencer) revert NotSequencer();
        if (amount == 0 || amount > totalStaked) revert InsufficientStake();

        // ---- Lock 1: a dispute is actually open. ----
        //
        // This is the condition that makes slashing meaningful, and
        // it must be tested against the contract that owns the
        // open-dispute set.  `slash` zeroes `totalStaked` outright —
        // the penalty is the WHOLE stake, not a per-dispute share —
        // so while any dispute is open no part of the balance is
        // safely withdrawable and the lock is all-or-nothing.
        //
        // Filing is permissionless, so this lock is a griefing
        // surface; `KnomosisDisputeVerifier.challengerBond` is what
        // prices it.  A griefer pays the bond per dispute and
        // forfeits it on rejection.
        if (IKnomosisDisputeVerifier(disputeVerifier).openDisputeCount() != 0) {
            revert WithdrawDuringOpenDispute();
        }

        // ---- Lock 2: a state root is still inside its challenge window. ----
        //
        // Complementary, not redundant: lock 1 covers the period
        // AFTER someone files, this covers the window during which
        // they still may.  Withdrawing here would let the sequencer
        // submit a bad root and exit before anyone could dispute it.
        //
        // Note the getter's name overstates what it answers — it
        // reports whether a root was submitted inside the window, not
        // whether a dispute exists.  That is the correct question for
        // THIS lock; it was the wrong question when it was the only
        // one.
        uint64 threshold = block.number > disputeWindowBlocks
            ? uint64(block.number - disputeWindowBlocks)
            : 0;
        if (IKnomosisBridge(bridge).hasOpenDisputeOlderThan(threshold)) {
            revert WithdrawDuringOpenDispute();
        }

        // Effects before interaction.
        totalStaked -= amount;
        emit Withdrawn(msg.sender, amount, totalStaked);
        Address.sendValue(payable(sequencer), amount);
    }

    // ------------------------------------------------------------------
    // External: slash (dispute-verifier-only)
    // ------------------------------------------------------------------

    /// @inheritdoc IKnomosisSequencerStake
    function slash(uint64 disputeId, address challenger)
        external
        nonReentrant
    {
        if (msg.sender != disputeVerifier) revert NotDisputeVerifier();
        if (_slashedDispute[disputeId]) revert AlreadySlashed(disputeId);
        if (challenger == address(0)) revert ZeroAddress();

        // Compute the slashable amount based on the *current*
        // total stake.  If the stake has been entirely drained
        // (e.g. previously slashed), the amount may be zero —
        // we still mark the dispute slashed to preserve
        // idempotency.
        uint256 stakeAtTime = totalStaked;
        uint256 paid = (stakeAtTime * slashRatioBps) / 10_000;
        uint256 burned = stakeAtTime - paid;

        // Effects before interactions.
        _slashedDispute[disputeId] = true;
        totalStaked = 0;

        emit Slashed(disputeId, challenger, paid, burned, totalStaked);

        // The challenger's cut is credited, not pushed — see
        // `slashCredit`.  A push here is a liveness hole: it lets the
        // reward recipient revert the finalisation that awards it.
        if (paid > 0) slashCredit[challenger] += paid;

        // Interaction: burn the residual.
        if (burned > 0) Address.sendValue(payable(burnAddress), burned);
    }

    /// @notice Withdraw every slash reward credited to the caller.
    /// @return amount The wei transferred.
    function claimSlashReward() external nonReentrant returns (uint256 amount) {
        amount = slashCredit[msg.sender];
        if (amount == 0) revert NothingToClaim();
        // Effects before interaction.
        slashCredit[msg.sender] = 0;
        emit SlashRewardClaimed(msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function isSlashed(uint64 disputeId) external view returns (bool) {
        return _slashedDispute[disputeId];
    }

    /// @notice Symmetric cross-contract consistency check.  Returns
    ///         `true` iff this stake's `disputeVerifier` immutable
    ///         points at a verifier whose `sequencerStake` immutable
    ///         points back at this stake contract.  Anyone may call.
    function assertConsistent() external view returns (bool) {
        return IKnomosisSequencerStakePeer(disputeVerifier).sequencerStake() == address(this);
    }

    // ------------------------------------------------------------------
    // ETH receive — must come via deposit()
    // ------------------------------------------------------------------

    receive() external payable {
        revert("KnomosisSequencerStake: bare ETH transfers not allowed; use deposit()");
    }
}

/// @notice Minimal interface used by `assertConsistent()` to read
///         the verifier's sequencerStake reference without pulling
///         in the full `IKnomosisDisputeVerifier` ABI.
interface IKnomosisSequencerStakePeer {
    function sequencerStake() external view returns (address);
}
