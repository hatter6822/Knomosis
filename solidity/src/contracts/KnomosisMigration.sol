// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {IKnomosisBridge} from "src/interfaces/IKnomosisBridge.sol";
import {IKnomosisMigration} from "src/interfaces/IKnomosisMigration.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {KnomosisEip712} from "src/lib/KnomosisEip712.sol";

/// @title KnomosisMigration
/// @notice One-shot, immutable, cryptographically attested handoff
///         between a predecessor `KnomosisBridge` and a successor
///         `KnomosisBridge`.  Per workstream E.5 and §20 of the
///         Ethereum integration plan, this contract is Knomosis's only
///         mechanism for changing the on-chain rules
///         post-deployment; it replaces the role traditionally
///         played by upgradeable proxies and admin keys.
///
///         The contract has exactly two state mutations: the
///         constructor (which sets every field as `immutable`) and
///         a one-shot `activate()` call (which flips a single
///         `bool activated` field after the grace window elapses).
///         There is no admin role, no upgrade hook, no pause, and
///         no field that can be re-set.
///
/// @dev    **Mathematical invariants** (§9.5 critical correctness
///         obligations).  Each is enforced at the bytecode level
///         via `immutable` storage or a `constant` modifier:
///
///         1. **Single-shot activation.**  `activated` transitions
///            from `false` to `true` exactly once, never reverts.
///         2. **Attestation chain integrity.**  The constructor
///            ECDSA-recovers the signer of the EIP-712 wrap of the
///            canonical migration record and asserts equality with
///            the predecessor's `attestor()`.  An invalid attestation
///            makes the deployment revert; no on-chain artefact is
///            left.
///         3. **Predecessor-attestor binding.**  The migration
///            attestor is read from `predecessor.attestor()` at
///            construction time, never supplied as a constructor
///            argument.
///         4. **Predecessor-references-this-migration check
///            (audit-3 fix).**  The constructor asserts
///            `predecessor.migration() == address(this)`.  This
///            is what BINDS the migration's `activated()` flag to
///            the predecessor's `MigrationActivated` circuit
///            breaker: at deploy time, the predecessor must have
///            been pre-committed (via its `migration` immutable)
///            to be frozen by THIS migration's activation.
///            Without this check, the migration's `activated()`
///            would have no effect — the predecessor wouldn't be
///            reading this migration's status.  Pre-audit-3
///            erroneously checked the SUCCESSOR's migration
///            field, which silently froze the successor (the
///            OPPOSITE of the intended user-exit behaviour).
///         5. **Grace-window minimum.**  `MIN_GRACE_WINDOW_BLOCKS`
///            is a `constant` (≈ 30 days @ 12s per block).  The
///            constructor reverts on a shorter grace window.
///         6. **No state-transfer mutability.**  `migrationStateRoot`
///            and `migrationStateRootLogIdx` are `immutable`.
///         7. **Cross-deployment isolation.**
///            `predecessorDeploymentId != successorDeploymentId`
///            asserted at construction.
contract KnomosisMigration is IKnomosisMigration {
    // ------------------------------------------------------------------
    // Custom errors
    // ------------------------------------------------------------------

    error ZeroAddress();
    error SelfMigration();
    error GraceTooShort();
    error SameDeploymentId();
    /// @notice Reverts if `predecessor.migration() != address(this)`.
    ///         Audit-3: the predecessor must be pre-committed (via
    ///         its `migration` immutable) to be frozen by THIS
    ///         migration's activation; otherwise the migration is
    ///         deployable but inert (predecessor's circuit breaker
    ///         doesn't fire on activation).
    error PredecessorDoesNotReferenceThisMigration();
    error AttestationInvalid();
    error AlreadyActivated();
    error GraceNotElapsed();
    error InvalidSignatureLength();

    // ------------------------------------------------------------------
    // Constitutional constants
    // ------------------------------------------------------------------

    /// @notice The constitutional floor on the grace window.  Even
    ///         a fully-compromised migration deployer cannot ship a
    ///         handoff with a grace window shorter than this — the
    ///         constructor reverts.  This is the on-chain mirror of
    ///         the Lean kernel's "TCB never grows" rule (§4.1):
    ///         certain safety parameters are immutable at the
    ///         bytecode level.
    ///
    ///         Default value ≈ 30 days at 12-second block time
    ///         (Ethereum mainnet post-merge):
    ///         30 * 24 * 60 * 60 / 12 = 216_000 blocks.
    uint256 public constant MIN_GRACE_WINDOW_BLOCKS = 216_000;

    /// @notice EIP-712 domain components used for the attestation
    ///         signature.  The wallet sees these strings in the
    ///         "request to sign" UI.
    string public constant DOMAIN_NAME = "Knomosis";
    string public constant DOMAIN_VERSION = "1";

    // ------------------------------------------------------------------
    // Immutable handoff record
    // ------------------------------------------------------------------

    /// @inheritdoc IKnomosisMigration
    address public immutable predecessor;
    /// @inheritdoc IKnomosisMigration
    address public immutable successor;

    bytes32 public immutable predecessorDeploymentId;
    bytes32 public immutable successorDeploymentId;

    /// @notice The address whose ECDSA signature attests to this
    ///         migration.  Read from `predecessor.attestor()` at
    ///         construction time; never settable via constructor
    ///         argument.
    address public immutable migrationAttestor;

    /// @inheritdoc IKnomosisMigration
    uint256 public immutable proposedAtBlock;
    /// @inheritdoc IKnomosisMigration
    uint256 public immutable graceWindowBlocks;
    /// @inheritdoc IKnomosisMigration
    bytes32 public immutable migrationStateRoot;
    /// @inheritdoc IKnomosisMigration
    uint64 public immutable migrationStateRootLogIdx;

    // ------------------------------------------------------------------
    // One-shot activation flag
    // ------------------------------------------------------------------

    bool private _activated;
    uint256 public activatedAtBlock;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event MigrationActivated(
        address indexed predecessor, address indexed successor, uint256 atBlock
    );

    event MigrationProposed(
        address indexed predecessor,
        address indexed successor,
        bytes32 migrationStateRoot,
        uint64 migrationStateRootLogIdx,
        uint256 graceWindowBlocks,
        uint256 proposedAtBlock
    );

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @notice Deploy a migration record.  Reverts if any of the
    ///         seven §9.5 invariants is violated.  Anyone can call
    ///         this — the cryptographic check on `_attestorSig`
    ///         binds the meaningful authority to the predecessor's
    ///         attestor key.
    ///
    /// @param _predecessor              the old `KnomosisBridge`
    /// @param _successor                the new `KnomosisBridge` (must
    ///                                  reference this migration's
    ///                                  predicted address as its
    ///                                  `migration` immutable)
    /// @param _graceWindowBlocks        the grace window (≥
    ///                                  `MIN_GRACE_WINDOW_BLOCKS`)
    /// @param _migrationStateRoot       the predecessor state root
    ///                                  the migration freezes at
    /// @param _migrationStateRootLogIdx the log-index-high of that
    ///                                  state root
    /// @param _attestorSig              the attestor's 65-byte
    ///                                  ECDSA signature over the
    ///                                  EIP-712 migration wrap
    constructor(
        address _predecessor,
        address _successor,
        uint256 _graceWindowBlocks,
        bytes32 _migrationStateRoot,
        uint64 _migrationStateRootLogIdx,
        bytes memory _attestorSig
    ) {
        // ---- Address sanity checks ----
        if (_predecessor == address(0) || _successor == address(0)) {
            revert ZeroAddress();
        }
        if (_predecessor == _successor) revert SelfMigration();
        if (_graceWindowBlocks < MIN_GRACE_WINDOW_BLOCKS) revert GraceTooShort();

        // ---- Read deployment-ids from the bridges ----
        // Both reads happen inside the constructor so any later
        // (impossible) field mutation is foreclosed.  If either
        // bridge reverts on the getter call, the migration
        // deployment fails open.
        bytes32 _preDid = IKnomosisBridge(_predecessor).deploymentId();
        bytes32 _sucDid = IKnomosisBridge(_successor).deploymentId();
        if (_preDid == _sucDid) revert SameDeploymentId();

        // ---- Predecessor must reference this migration ----
        // Audit-3 fix: this binds THIS migration's `activated()`
        // flag to the predecessor's `MigrationActivated` circuit
        // breaker.  At deploy time, the predecessor must have
        // been pre-committed (via its immutable `migration`
        // field) to be frozen by THIS migration's activation.
        // Without this check, the migration would deploy
        // successfully but its `activated()` flag would have NO
        // effect on the predecessor — the predecessor wouldn't
        // be reading this migration.
        //
        // The pre-audit-3 design checked the SUCCESSOR's migration
        // field, which silently froze the successor (the OPPOSITE
        // of the intended user-exit behaviour).  See §20 amendment.
        if (IKnomosisBridge(_predecessor).migration() != address(this)) {
            revert PredecessorDoesNotReferenceThisMigration();
        }

        // ---- Read attestor from the predecessor ----
        // The attestor is the predecessor's attestor.  An attacker
        // cannot substitute a malicious attestor address by
        // manipulating constructor arguments.
        address _attestor = IKnomosisBridge(_predecessor).attestor();
        if (_attestor == address(0)) revert ZeroAddress();

        // ---- Store the immutable record ----
        predecessor = _predecessor;
        successor = _successor;
        predecessorDeploymentId = _preDid;
        successorDeploymentId = _sucDid;
        migrationAttestor = _attestor;
        proposedAtBlock = block.number;
        graceWindowBlocks = _graceWindowBlocks;
        migrationStateRoot = _migrationStateRoot;
        migrationStateRootLogIdx = _migrationStateRootLogIdx;

        // ---- Verify the attestor signature over the canonical wrap ----
        // The wrap binds every field above so the signature is
        // *only* valid for this exact migration record.  A
        // signature on a different (predecessor, successor,
        // stateRoot, ...) tuple cannot be replayed.
        bytes32 digest = _wrapDigest();
        if (_attestorSig.length != 65) revert InvalidSignatureLength();
        address recovered = ECDSA.recover(digest, _attestorSig);
        if (recovered != _attestor) revert AttestationInvalid();

        emit MigrationProposed(
            _predecessor,
            _successor,
            _migrationStateRoot,
            _migrationStateRootLogIdx,
            _graceWindowBlocks,
            block.number
        );
    }

    // ------------------------------------------------------------------
    // External: activate (anyone, post-grace)
    // ------------------------------------------------------------------

    /// @notice Flip the migration into the activated state.  After
    ///         this call returns, the predecessor's `circuitOpen`
    ///         modifier reads `true` from `activated()` and reverts
    ///         all state-shaping calls with `MigrationActivated`.
    ///         Withdrawals at the predecessor continue to work
    ///         (the user-exit guarantee).
    /// @dev    Anyone can call this — there is no role gating.
    ///         The cryptographic security comes entirely from the
    ///         constructor's signature verification: only a
    ///         predecessor-attestor-signed migration can have a
    ///         contract at this address; once that contract
    ///         exists, activation is just a deterministic timer
    ///         elapse.
    function activate() external {
        if (_activated) revert AlreadyActivated();
        if (block.number < proposedAtBlock + graceWindowBlocks) {
            revert GraceNotElapsed();
        }
        _activated = true;
        activatedAtBlock = block.number;
        emit MigrationActivated(predecessor, successor, block.number);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IKnomosisMigration
    function activated() external view returns (bool) {
        return _activated;
    }

    /// @notice Compute the canonical EIP-712 digest that the
    ///         attestor signs.  Public so off-chain tooling can
    ///         reproduce the digest for signing without redeploying
    ///         a copy of the contract.
    function wrapDigest() external view returns (bytes32) {
        return _wrapDigest();
    }

    function _wrapDigest() internal view returns (bytes32) {
        bytes32 ds = KnomosisEip712.domainSeparator(
            DOMAIN_NAME,
            DOMAIN_VERSION,
            block.chainid,
            // For migration records we use rollupId = 0 (the
            // migration is *not* per-rollup; it's a one-shot
            // contract-level event).  Future per-rollup migration
            // policies would parametrise this; the MVP keeps it
            // constant.
            uint256(0),
            address(this)
        );
        bytes32 sh = KnomosisEip712.migrationStructHash(
            predecessorDeploymentId,
            successorDeploymentId,
            migrationStateRoot,
            migrationStateRootLogIdx,
            graceWindowBlocks
        );
        return KnomosisEip712.digest(ds, sh);
    }
}
