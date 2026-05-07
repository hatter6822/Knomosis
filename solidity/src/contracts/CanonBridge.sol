// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {ICanonBridge} from "src/interfaces/ICanonBridge.sol";
import {ICanonMigration} from "src/interfaces/ICanonMigration.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {CanonEip712} from "src/lib/CanonEip712.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";
import {CBEDecode} from "src/lib/CBEDecode.sol";

/// @title CanonBridge
/// @notice The L1 bridge contract.  Hosts deposits, withdrawals,
///         state-root submissions, and the rollback hook.  Per
///         workstream E.1 of the Ethereum integration plan, this
///         contract is deployed immutably: no proxy, no
///         `initialize`, no admin role, no upgrade hook.
///
/// @dev    All five sub-WUs (E.1.1 deposit, E.1.2 state-root
///         submission, E.1.3 withdrawal, E.1.4 circuit breakers,
///         E.1.5 rollback hook) are implemented in this single
///         contract per the plan's organisational discipline.
contract CanonBridge is ICanonBridge, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Custom errors
    // ------------------------------------------------------------------

    error NotAttestor();
    error NotDisputeVerifier();
    error AttestationStale();
    error DisputeCooldown();
    error TvlCapReached();
    error MigrationActivated();
    error NonMonotonic();
    error UnknownStateRoot();
    error StateRootReverted();
    error PreFinalisation();
    error AlreadyRedeemed();
    error InvalidProof();
    error InvalidLeafSizeForResource();
    error UnsupportedResource();
    error EthValueMismatch(uint256 expected, uint256 actual);
    error InvariantViolation_DisputeWindowVsRedemption();
    /// @notice Reverts when the bridge's internal `totalLockedValue`
    ///         disagrees with the L2 record at withdrawal time.
    ///         Should be unreachable if the bridge's deposit /
    ///         withdrawal accounting matches the L2 ledger; firing
    ///         it indicates a cross-stack drift bug.
    error BridgeAccountingMismatch(uint256 totalLockedValue, uint256 amountRequested);
    error InvalidSignatureLength();
    /// @notice Reverts when the constructor's resource map maps two
    ///         distinct resourceIds to the same ERC-20 token address
    ///         (audit-2: closes a misconfiguration where the same
    ///         token is double-counted).
    error DuplicateResourceToken(address token);
    /// @notice Reverts when an ERC-20 deposit receives a different
    ///         amount than declared (e.g. fee-on-transfer or
    ///         rebasing tokens).  Audit-2: the bridge cannot accept
    ///         such tokens at all because the L2 credit would
    ///         desync from the L1-locked value.
    error TransferAmountMismatch(uint256 declared, uint256 received);

    // ------------------------------------------------------------------
    // Constitutional / immutable parameters
    // ------------------------------------------------------------------

    bytes32 public immutable canonVersionTag;
    bytes32 public immutable deploymentId;

    address public immutable attestor;
    address public immutable disputeVerifier;
    address public immutable sequencerStake;
    address public immutable migration;

    uint64 public immutable disputeWindowBlocks;
    uint64 public immutable maxRedemptionWindowBlocks;
    uint64 public immutable maxAttestationStaleBlocks;
    uint64 public immutable cooldownBlocks;
    uint256 public immutable tvlCap;

    /// @notice EIP-712 domain components for state-root attestations.
    string public constant DOMAIN_NAME = "CanonBridge";
    string public constant DOMAIN_VERSION = "1";

    /// @notice The resource id 0 is reserved for native ETH; all
    ///         other resource ids are looked up via the immutable
    ///         resource map below.  The runtime adaptor establishes
    ///         the (resourceId → ERC-20 address) bijection at
    ///         deployment time and bakes it into the constructor.
    uint64 public constant RESOURCE_ID_NATIVE_ETH = 0;

    // ------------------------------------------------------------------
    // Mutable state — only written by proof-gated entry points
    // ------------------------------------------------------------------

    /// @notice Per-depositor counter; ensures `receiptHash`
    ///         determinism within a block.
    mapping(address => uint64) public depositNonce;

    /// @notice State-root ledger keyed by the post-state log index
    ///         of the highest-indexed log entry covered.  The
    ///         `reverted` status is NOT stored here; it is computed
    ///         on-the-fly as `logIndexHigh >= lowestRevertedLogIndexHigh`
    ///         per the O(1) `revertToPriorRoot` discipline.
    struct StateRootRecord {
        bytes32 root;
        uint64 logIndexHigh;
        uint64 submittedAtBlock;
        bool exists;
    }

    mapping(uint64 => StateRootRecord) private _stateRoots;
    uint64 public latestSubmittedLogIndexHigh;
    uint64 public latestStateRootSubmittedAtBlock;
    uint64 public lastUpheldDisputeBlock;

    /// @notice The reverted **range** is `[lowestRevertedLogIndexHigh,
    ///         revertedThroughLogIndexHigh]` (inclusive).  A state
    ///         root at index X is reverted iff
    ///         `lowestRevertedLogIndexHigh <= X <=
    ///         revertedThroughLogIndexHigh`.  Initial state:
    ///         floor = `type(uint64).max`, ceiling = 0 (empty range).
    ///
    ///         `revertToPriorRoot(N)` LOWERS the floor if `N <
    ///         floor` and RAISES the ceiling to
    ///         `latestSubmittedLogIndexHigh` (the highest existing
    ///         state root at the time of the revert).  Future
    ///         submissions land at indices > ceiling and are
    ///         therefore NOT reverted (they post-date the dispute).
    ///
    ///         Audit-2 fix: the previous "floor only" design
    ///         silently broke post-revert submissions because
    ///         `idx >= floor` would auto-mark every future
    ///         submission as reverted.  The (floor, ceiling) pair
    ///         correctly bounds the reverted range to historical
    ///         state.
    uint64 public lowestRevertedLogIndexHigh = type(uint64).max;

    /// @notice The highest index in the currently-reverted range.
    ///         See `lowestRevertedLogIndexHigh`.
    uint64 public revertedThroughLogIndexHigh; // default 0

    /// @notice Tracks redeemed leaves by their canonical
    ///         `keccak256(leafBlob)` so a single PendingWithdrawal
    ///         can never be redeemed twice.
    mapping(bytes32 => bool) public withdrawalLeafRedeemed;

    /// @notice Sum of locked value: deposits − withdrawals.
    uint256 public totalLockedValue;

    // ------------------------------------------------------------------
    // Resource map (immutable; resource id → ERC-20 token address)
    // ------------------------------------------------------------------

    /// @notice The per-deployment resource-id → token-address
    ///         bijection.  Set in the constructor and immutable
    ///         thereafter.  resource id 0 is reserved for ETH; ids
    ///         1..N map to ERC-20 tokens via the constructor's
    ///         `_resourceIdsForErc20` / `_erc20Addrs` parallel
    ///         arrays.
    mapping(uint64 => address) private _resourceTokens;
    /// @notice Bookkeeping flag: the resource id is registered
    ///         (true) or unknown (false).  ETH (id 0) is implicit;
    ///         every ERC-20 entry sets this to `true`.
    mapping(uint64 => bool) private _resourceRegistered;

    // ------------------------------------------------------------------
    // Open-dispute tracking (consulted by `CanonSequencerStake`)
    // ------------------------------------------------------------------

    /// @notice The block of the most-recently-submitted state root
    ///         that has an active (`.open`) dispute against it.
    ///         Updated by the dispute verifier through a side
    ///         channel; for now we compute the predicate `lastUpheldDisputeBlock != 0
    ///         && block.number < lastUpheldDisputeBlock + disputeWindowBlocks`
    ///         as the conservative approximation.  The full
    ///         per-state-root open-dispute index lives in the
    ///         dispute verifier and is queried via that contract.
    function hasOpenDisputeOlderThan(uint64 thresholdBlock)
        external
        view
        returns (bool)
    {
        // Conservative: any unfinalised state root past
        // `thresholdBlock` is treated as "potentially under
        // dispute".  The dispute verifier maintains the
        // authoritative open-dispute set; this getter is the
        // surface that `CanonSequencerStake` consults to lock
        // sequencer stake during the post-submission window.
        if (latestStateRootSubmittedAtBlock == 0) return false;
        if (latestStateRootSubmittedAtBlock <= thresholdBlock) return false;
        return block.number < latestStateRootSubmittedAtBlock + disputeWindowBlocks;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    struct ConstructorArgs {
        bytes32 canonVersionTag;
        address attestor;
        address disputeVerifier;
        address sequencerStake;
        address migration;
        uint64 disputeWindowBlocks;
        uint64 maxRedemptionWindowBlocks;
        uint64 maxAttestationStaleBlocks;
        uint64 cooldownBlocks;
        uint256 tvlCap;
        uint64[] erc20ResourceIds;
        address[] erc20TokenAddrs;
    }

    /// @notice Reverts when the `sequencerStake` constructor
    ///         argument is the zero address.  Audit-2: closes the
    ///         pre-audit gap where missing-zero-check on
    ///         `sequencerStake` allowed misconfigured deployments
    ///         that the test suite would not catch until a slash
    ///         was attempted.
    error ZeroSequencerStake();

    constructor(ConstructorArgs memory args) {
        // ---- Sanity: dispute window must dominate redemption window
        if (args.disputeWindowBlocks < args.maxRedemptionWindowBlocks) {
            revert InvariantViolation_DisputeWindowVsRedemption();
        }
        if (args.attestor == address(0)) revert NotAttestor();
        if (args.disputeVerifier == address(0)) revert NotDisputeVerifier();
        if (args.sequencerStake == address(0)) revert ZeroSequencerStake();

        // ---- Pin every immutable
        canonVersionTag = args.canonVersionTag;
        attestor = args.attestor;
        disputeVerifier = args.disputeVerifier;
        sequencerStake = args.sequencerStake;
        migration = args.migration;
        disputeWindowBlocks = args.disputeWindowBlocks;
        maxRedemptionWindowBlocks = args.maxRedemptionWindowBlocks;
        maxAttestationStaleBlocks = args.maxAttestationStaleBlocks;
        cooldownBlocks = args.cooldownBlocks;
        tvlCap = args.tvlCap;

        deploymentId =
            keccak256(abi.encode(block.chainid, address(this), args.canonVersionTag));

        // ---- Wire the resource map
        // Both arrays must be the same length; resource id 0 is
        // reserved for ETH and cannot be reassigned.
        if (args.erc20ResourceIds.length != args.erc20TokenAddrs.length) {
            revert UnsupportedResource();
        }
        for (uint256 i = 0; i < args.erc20ResourceIds.length; ++i) {
            uint64 rid = args.erc20ResourceIds[i];
            address tok = args.erc20TokenAddrs[i];
            if (rid == RESOURCE_ID_NATIVE_ETH || tok == address(0)) {
                revert UnsupportedResource();
            }
            if (_resourceRegistered[rid]) revert UnsupportedResource();
            // Audit-2: reject duplicate token addresses.  The
            // (resourceId → token) map must be a bijection so the
            // L2 ↔ L1 ledger stays in 1:1 correspondence.  Without
            // this check, two resourceIds could fund the same
            // token, splitting accounting at the L2 level.
            for (uint256 j = 0; j < i; ++j) {
                if (args.erc20TokenAddrs[j] == tok) {
                    revert DuplicateResourceToken(tok);
                }
            }
            _resourceTokens[rid] = tok;
            _resourceRegistered[rid] = true;
        }
    }

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    /// @notice The four §9.1.4 automatic circuit breakers.  Applied
    ///         to every state-shaping entry point.  Pure-state
    ///         predicates; no privileged caller required to
    ///         "trip" them.
    modifier circuitOpen() {
        // (a) AttestationStale
        if (
            latestStateRootSubmittedAtBlock != 0
                && block.number
                    > uint256(latestStateRootSubmittedAtBlock) + uint256(maxAttestationStaleBlocks)
        ) revert AttestationStale();
        // (b) DisputeCooldown
        if (
            lastUpheldDisputeBlock != 0
                && block.number < uint256(lastUpheldDisputeBlock) + uint256(cooldownBlocks)
        ) revert DisputeCooldown();
        // (c) TvlCapReached — tested at deposit-entry below; for
        //     symmetry with the spec we also re-check here so
        //     submitStateRoot rejects when the bridge is over cap.
        if (totalLockedValue > tvlCap) revert TvlCapReached();
        // (d) MigrationActivated
        if (migration != address(0) && ICanonMigration(migration).activated()) {
            revert MigrationActivated();
        }
        _;
    }

    /// @notice Withdrawals continue post-migration so users can
    ///         always exit; this modifier intentionally omits the
    ///         `MigrationActivated` and `TvlCapReached` breakers.
    ///         The `reverted` flag on the state-root record is the
    ///         primary correctness gate for withdrawals.
    modifier withdrawalOpen() {
        // Note: no MigrationActivated check (user-exit guarantee).
        _;
    }

    // ------------------------------------------------------------------
    // E.1.1 Deposit entry points
    // ------------------------------------------------------------------

    event DepositInitiated(
        address indexed depositor,
        uint64 indexed resourceId,
        address token,
        uint256 amount,
        uint64 depositorNonce,
        bytes32 receiptHash
    );

    /// @notice Deposit native ETH.  `msg.value` is the deposit
    ///         amount; the receipt is registered for L2 credit.
    function depositETH() external payable nonReentrant circuitOpen {
        _registerDeposit(RESOURCE_ID_NATIVE_ETH, address(0), msg.value);
    }

    /// @notice Deposit an ERC-20 token.  `amount` is debited from
    ///         `msg.sender` to this contract via `safeTransferFrom`.
    ///         The bridge measures the actual received amount
    ///         (balance-delta) and rejects if it differs from
    ///         `amount` — fee-on-transfer / rebasing / deflationary
    ///         tokens are NOT supported because the L2 credit
    ///         would desync from the L1-locked value.
    function depositERC20(uint64 resourceId, IERC20 token, uint256 amount)
        external
        nonReentrant
        circuitOpen
    {
        if (resourceId == RESOURCE_ID_NATIVE_ETH || !_resourceRegistered[resourceId]) {
            revert UnsupportedResource();
        }
        // Resource-id ↔ token mapping must match.
        if (_resourceTokens[resourceId] != address(token)) {
            revert UnsupportedResource();
        }
        // Balance-delta accounting: measure pre and post balance
        // and assert the actual transfer amount equals `amount`.
        // This rejects fee-on-transfer / rebasing tokens whose
        // received amount differs from the declared amount.
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balAfter = token.balanceOf(address(this));
        // Underflow-safe: balAfter ≥ balBefore is enforced by
        // SafeERC20 on a successful transfer.
        uint256 received;
        unchecked {
            received = balAfter - balBefore;
        }
        if (received != amount) {
            revert TransferAmountMismatch(amount, received);
        }
        _registerDeposit(resourceId, address(token), amount);
    }

    /// @notice Common deposit bookkeeping.  Computes the canonical
    ///         `receiptHash` (matching Lean `DepositId`), bumps the
    ///         per-depositor counter, increments TVL, and emits.
    function _registerDeposit(uint64 resourceId, address token, uint256 amount) internal {
        // Reject deposits that would push us past the TVL cap.
        // Checked-arithmetic prevents wraparound.
        uint256 newTvl = totalLockedValue + amount;
        if (newTvl > tvlCap) revert TvlCapReached();
        totalLockedValue = newTvl;

        uint64 nonce = depositNonce[msg.sender];
        bytes32 receiptHash = keccak256(
            abi.encode(deploymentId, msg.sender, resourceId, token, amount, nonce)
        );
        unchecked {
            depositNonce[msg.sender] = nonce + 1;
        }
        emit DepositInitiated(msg.sender, resourceId, token, amount, nonce, receiptHash);
    }

    // ------------------------------------------------------------------
    // E.1.2 State-root submission
    // ------------------------------------------------------------------

    event StateRootSubmitted(
        bytes32 indexed root,
        uint64 indexed logIndexHigh,
        address indexed signer,
        uint64 submittedAtBlock
    );

    function submitStateRoot(
        bytes32 root,
        uint64 logIndexHigh,
        bytes calldata attestorSig
    ) external circuitOpen {
        if (logIndexHigh <= latestSubmittedLogIndexHigh) revert NonMonotonic();
        if (attestorSig.length != 65) revert InvalidSignatureLength();

        // Recover the signer from the EIP-712 wrap of (root, logIndexHigh, deploymentId).
        bytes32 ds = CanonEip712.domainSeparator(
            DOMAIN_NAME, DOMAIN_VERSION, block.chainid, uint256(0), address(this)
        );
        bytes32 sh = keccak256(
            abi.encode(
                keccak256("StateRoot(bytes32 root,uint64 logIndexHigh,bytes32 deploymentId)"),
                root,
                uint256(logIndexHigh),
                deploymentId
            )
        );
        bytes32 digest = CanonEip712.digest(ds, sh);
        address recovered = ECDSA.recover(digest, attestorSig);
        if (recovered != attestor) revert NotAttestor();

        latestSubmittedLogIndexHigh = logIndexHigh;
        latestStateRootSubmittedAtBlock = uint64(block.number);
        _stateRoots[logIndexHigh] = StateRootRecord({
            root: root,
            logIndexHigh: logIndexHigh,
            submittedAtBlock: uint64(block.number),
            exists: true
        });

        emit StateRootSubmitted(root, logIndexHigh, recovered, uint64(block.number));
    }

    /// @notice Whether `logIndexHigh` falls in the reverted range
    ///         `[lowestRevertedLogIndexHigh, revertedThroughLogIndexHigh]`.
    ///         Computed in O(1) from the (floor, ceiling) pair —
    ///         no per-record state.
    function isStateRootReverted(uint64 logIndexHigh) public view returns (bool) {
        return logIndexHigh >= lowestRevertedLogIndexHigh
            && logIndexHigh <= revertedThroughLogIndexHigh;
    }

    /// @inheritdoc ICanonBridge
    function stateRootAt(uint64 logIndexHigh)
        external
        view
        returns (bytes32, uint64, bool)
    {
        StateRootRecord storage rec = _stateRoots[logIndexHigh];
        return (rec.root, rec.submittedAtBlock, isStateRootReverted(logIndexHigh));
    }

    /// @inheritdoc ICanonBridge
    function isStateRootFinalised(uint64 logIndexHigh)
        public
        view
        returns (bool)
    {
        StateRootRecord storage rec = _stateRoots[logIndexHigh];
        if (!rec.exists) return false;
        if (isStateRootReverted(logIndexHigh)) return false;
        return block.number >= uint256(rec.submittedAtBlock) + uint256(disputeWindowBlocks);
    }

    // ------------------------------------------------------------------
    // E.1.3 Withdrawal redemption
    // ------------------------------------------------------------------

    event WithdrawalRedeemed(
        bytes32 indexed leafHash,
        address indexed recipient,
        uint64 indexed resourceId,
        uint256 amount,
        uint64 atLogIndexHigh
    );

    /// @notice Decoded leaf shape — must mirror Lean's
    ///         `Bridge.PendingWithdrawal.encode`.  Layout:
    ///           CBE uint   resourceId   (9 bytes)
    ///           CBE bytes  recipientL1  (29 bytes; 1 tag + 8 length + 20 payload)
    ///           CBE uint   amount       (9 bytes)
    ///           CBE uint   l2LogIndex   (9 bytes)
    ///         Total: 56 bytes per the audit-2 lossless 20-byte
    ///         address encoding.
    struct PendingWithdrawal {
        uint64 resourceId;
        address recipientL1;
        uint256 amount;
        uint64 l2LogIndex;
    }

    /// @notice The proof shape mirrors Lean's `WithdrawalProof`:
    ///         variable-size leaf bytes + index + 64 variable-size
    ///         siblings (root-to-leaf ordered).  Audit-2 fix: leaf
    ///         and siblings are `bytes` (variable), NOT `bytes32`,
    ///         so the dense-pair case (where the leaf-adjacent
    ///         sibling is itself a ~56-byte raw leaf) is encodable.
    struct WithdrawalProof {
        bytes leaf;
        uint64 index;
        bytes[] siblings;
    }

    function withdrawWithProof(
        uint64 atLogIndexHigh,
        bytes calldata proofBlob,
        bytes calldata leafBlob
    ) external nonReentrant withdrawalOpen returns (bool) {
        // ---- Check phase ----
        // (a) Decode the leaf into a structured PendingWithdrawal.
        PendingWithdrawal memory wd = _decodePendingWithdrawal(leafBlob);

        // (b) Look up the state root.
        if (!isStateRootFinalised(atLogIndexHigh)) {
            StateRootRecord storage rec = _stateRoots[atLogIndexHigh];
            if (!rec.exists) revert UnknownStateRoot();
            if (isStateRootReverted(atLogIndexHigh)) revert StateRootReverted();
            revert PreFinalisation();
        }
        bytes32 root = _stateRoots[atLogIndexHigh].root;

        // (c) Reject double-spend (key by canonical hash of leafBlob).
        bytes32 leafHash = keccak256(leafBlob);
        if (withdrawalLeafRedeemed[leafHash]) revert AlreadyRedeemed();

        // (d) Decode the proof and verify against the root.
        // Audit-2 fix: the proof's `leaf` field is variable-size
        // bytes (matching Lean's `WithdrawalProof.leaf : ByteArray`).
        // Cross-check that the proof's leaf bytes equal the
        // separately-supplied leafBlob (binds the proof to the
        // payment-determining leafBlob).
        (bytes memory proofLeaf, uint64 proofIndex, bytes[] memory siblings) =
            _decodeWithdrawalProof(proofBlob);
        if (proofLeaf.length != leafBlob.length) revert InvalidProof();
        if (keccak256(proofLeaf) != leafHash) revert InvalidProof();
        if (proofIndex != wd.l2LogIndex) revert InvalidProof();
        if (!SmtVerifier.verifyProof(uint256(proofIndex), proofLeaf, siblings, root)) {
            revert InvalidProof();
        }

        // ---- Effect phase: mark redeemed before any external call ----
        withdrawalLeafRedeemed[leafHash] = true;
        // Underflow safeguard — should be unreachable if the
        // bridge's accounting matches the L2 record.  This
        // catches a class of cross-stack drift bugs early.
        if (totalLockedValue < wd.amount) {
            revert BridgeAccountingMismatch(totalLockedValue, wd.amount);
        }
        unchecked {
            totalLockedValue = totalLockedValue - wd.amount;
        }

        // ---- Interaction phase ----
        if (wd.resourceId == RESOURCE_ID_NATIVE_ETH) {
            // Native ETH: forward all gas via Address.sendValue.
            Address.sendValue(payable(wd.recipientL1), wd.amount);
        } else {
            address tok = _resourceTokens[wd.resourceId];
            if (tok == address(0)) revert UnsupportedResource();
            IERC20(tok).safeTransfer(wd.recipientL1, wd.amount);
        }

        emit WithdrawalRedeemed(
            leafHash, wd.recipientL1, wd.resourceId, wd.amount, atLogIndexHigh
        );
        return true;
    }

    function _decodePendingWithdrawal(bytes calldata leafBlob)
        internal
        pure
        returns (PendingWithdrawal memory wd)
    {
        uint256 off = 0;
        (wd.resourceId, off) = CBEDecode.readUint(leafBlob, off);
        (wd.recipientL1, off) = CBEDecode.readAddressExact(leafBlob, off);
        uint64 amount64;
        (amount64, off) = CBEDecode.readUint(leafBlob, off);
        wd.amount = uint256(amount64);
        (wd.l2LogIndex, off) = CBEDecode.readUint(leafBlob, off);
        CBEDecode.assertFullyConsumed(leafBlob, off);
    }

    function _decodeWithdrawalProof(bytes calldata proofBlob)
        internal
        pure
        returns (bytes memory leaf, uint64 index, bytes[] memory siblings)
    {
        uint256 off = 0;
        // Layout: CBE-encoded WithdrawalProof:
        //   leaf      : bytes      (variable; matches Lean's
        //                            `leafBytes wd` ≈ 56 bytes for
        //                            populated, 32 bytes for sentinel)
        //   index     : uint64
        //   siblings  : array<bytes>(64)  (each variable; typically
        //                            32-byte default-hash values, but
        //                            the leaf-adjacent sibling can
        //                            itself be a 56-byte raw leaf in
        //                            the dense-pair case).
        (leaf, off) = CBEDecode.readBytes(proofBlob, off);
        (index, off) = CBEDecode.readUint(proofBlob, off);
        uint64 count;
        (count, off) = CBEDecode.readArrayHead(proofBlob, off);
        if (count != SmtVerifier.SMT_HEIGHT) revert InvalidProof();

        siblings = new bytes[](SmtVerifier.SMT_HEIGHT);
        for (uint256 i = 0; i < SmtVerifier.SMT_HEIGHT; ++i) {
            (siblings[i], off) = CBEDecode.readBytes(proofBlob, off);
        }
        CBEDecode.assertFullyConsumed(proofBlob, off);
    }

    // ------------------------------------------------------------------
    // E.1.5 Rollback hook
    // ------------------------------------------------------------------

    /// @notice Emitted on every `revertToPriorRoot` call, carrying
    ///         the (floor, ceiling) bounds of the reverted range.
    ///         Audit-2: replaces the floor-only event;
    ///         post-revert submissions at indices > ceiling are
    ///         NOT auto-reverted.
    event StateRootRangeReverted(
        uint64 indexed disputedLogIndexHigh,
        uint64 newRevertedFloor,
        uint64 newRevertedCeiling
    );

    function revertToPriorRoot(uint64 disputedLogIndexHigh) external {
        if (msg.sender != disputeVerifier) revert NotDisputeVerifier();

        // O(1) reversion: track the (floor, ceiling) pair.
        //   - floor lowers monotonically (only decreases).
        //   - ceiling rises to the current `latestSubmittedLogIndexHigh`
        //     so all already-submitted state roots at idx ≥ floor
        //     are marked reverted.
        // Future submissions land at idx > current latest, hence
        // > ceiling, hence NOT reverted.  This closes the audit-2
        // gap where the floor-only design silently auto-reverted
        // every post-revert submission.
        bool changed = false;
        if (disputedLogIndexHigh < lowestRevertedLogIndexHigh) {
            lowestRevertedLogIndexHigh = disputedLogIndexHigh;
            changed = true;
        }
        if (latestSubmittedLogIndexHigh > revertedThroughLogIndexHigh) {
            revertedThroughLogIndexHigh = latestSubmittedLogIndexHigh;
            changed = true;
        }
        // Idempotent in the (floor, ceiling) sense: if neither the
        // floor nor the ceiling moves, no event is emitted but the
        // cooldown still trips.
        if (changed) {
            emit StateRootRangeReverted(
                disputedLogIndexHigh,
                lowestRevertedLogIndexHigh,
                revertedThroughLogIndexHigh
            );
        }

        // Trip the DisputeCooldown breaker for the next
        // `cooldownBlocks` blocks (called every time, not just on
        // a fresh-floor revert, so multiple disputes within the
        // window each refresh the cooldown).
        lastUpheldDisputeBlock = uint64(block.number);
    }

    // ------------------------------------------------------------------
    // ETH receive — only via depositETH; reject bare transfers
    // ------------------------------------------------------------------

    /// @notice Reject bare ETH transfers; users must call
    ///         `depositETH()` so the receipt is registered.
    receive() external payable {
        revert("CanonBridge: bare ETH transfers not allowed; use depositETH()");
    }
}
