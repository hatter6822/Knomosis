// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IKnomosisDisputeVerifier} from "src/interfaces/IKnomosisDisputeVerifier.sol";
import {IKnomosisBridge} from "src/interfaces/IKnomosisBridge.sol";
import {IKnomosisSequencerStake} from "src/interfaces/IKnomosisSequencerStake.sol";
import {IKnomosisIdentityRegistry} from "src/interfaces/IKnomosisIdentityRegistry.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CBEDecode} from "src/lib/CBEDecode.sol";
import {KnomosisEip712} from "src/lib/KnomosisEip712.sol";

/// @title KnomosisDisputeVerifier
/// @notice The L1 dispute pipeline.  Per workstream E.2 of the
///         Ethereum integration plan, this contract receives
///         disputes against state roots from `KnomosisBridge`,
///         re-verifies the impugned evidence on-chain, and (on
///         `.upheld`) slashes the sequencer + reverts the bad
///         state roots atomically.
///
/// @dev    Three claim variants ship in MVP (mirror the
///         post-Phase-6 Lean dispute pipeline):
///           * `signatureInvalid` — E.2.2
///           * `nonceMismatch`    — E.2.3
///           * `doubleApply`      — E.2.4
///
///         Deferred to v2: `preconditionFalse` (requires full
///         kernel replay) and `oracleMisreported` (requires
///         deployment-specific oracle policy).  Adding either
///         requires a new dispute-verifier deployment + a
///         `KnomosisMigration` handoff.
contract KnomosisDisputeVerifier is IKnomosisDisputeVerifier, ReentrancyGuard {
    // ------------------------------------------------------------------
    // Custom errors
    // ------------------------------------------------------------------

    error NotApprovedAdjudicator();
    error UnknownDispute();
    error AlreadyDecided();
    error NotOpen();
    error QuorumNotMet(uint256 verified, uint8 required);
    error EvidenceNotUpheld();
    error EvidenceNotRejected();
    error SelfClaimInvalid();
    error InvalidClaimVariant();
    error MaxPrefixLenExceeded();
    error PrefixSignerMissing();
    error InvalidSignatureLength();
    error VerifierBridgeMismatch();
    error ZeroAddress();
    error QuorumThresholdOutOfRange();
    error VerdictReplay();

    // ------------------------------------------------------------------
    // Constitutional / immutable parameters
    // ------------------------------------------------------------------

    bytes32 public immutable knomosisVersionTag;
    bytes32 public immutable deploymentId;

    address public immutable bridge;
    address public immutable sequencerStake;
    address public immutable identityRegistry;
    address public immutable migration;
    uint8 public immutable quorumThreshold;

    /// @notice Approved-adjudicator membership snapshot, set in the
    ///         constructor.  Immutable thereafter.
    mapping(address => bool) private _approvedAdjudicator;
    bytes32 public immutable approvedAdjudicatorRoot;

    /// @notice The EIP-712 domain name used for **per-action signing**
    ///         by users.  This MUST match the domain used at the
    ///         time the user signed the action (off-chain), so the
    ///         dispute verifier can reproduce the digest the
    ///         signature was made against.
    ///
    ///         Per the integration plan §5.3 / §9.2.2, the canonical
    ///         per-action signing domain is `("KnomosisAction", "1")`
    ///         with `verifyingContract = bridge`.  This constant is
    ///         frozen for the dispute verifier's lifetime; rotating
    ///         it requires a new dispute-verifier deployment plus a
    ///         `KnomosisMigration` handoff.
    string public constant ACTION_DOMAIN_NAME = "KnomosisAction";
    string public constant ACTION_DOMAIN_VERSION = "1";

    /// @notice The EIP-712 domain used for **verdict signing** by
    ///         adjudicators.  Different from the action domain so a
    ///         per-action signature cannot be replayed as a verdict
    ///         signature (cross-protocol replay protection mirroring
    ///         Lean's `verdictDomain` / `signedActionDomain` split).
    string public constant VERDICT_DOMAIN_NAME = "KnomosisDisputeVerifier";
    string public constant VERDICT_DOMAIN_VERSION = "1";

    /// @notice Hard upper bound on the verdict signers array length.
    ///         Prevents memory-allocation DoS in
    ///         `_countVerifiedSignatures`.  64 is comfortably above
    ///         realistic quorum sizes (typical 3..7) yet bounds the
    ///         worst-case gas usage at ≈ 64 × 64 × 5k = 20M gas
    ///         (still within block-gas budget).
    uint256 public constant MAX_VERDICT_SIGNERS = 64;

    /// @notice Hard upper bound on the per-dispute evidence blob
    ///         emitted in the `DisputeFiled` event.  Bounds gas
    ///         cost of filing; values larger than this cap should
    ///         use the `nonceMismatch`-style log-prefix bound
    ///         (`MAX_PREFIX_LEN`) at finalisation time, not the
    ///         file-time blob.  100 KB is enough for a 256-entry
    ///         log prefix at ≈ 400 bytes per entry.
    uint256 public constant MAX_EVIDENCE_BLOB_BYTES = 100_000;

    /// @notice One-shot bound on `nonceMismatch` log prefix length
    ///         (the MVP fraud-proof bound; bisection is post-MVP).
    uint64 public constant MAX_PREFIX_LEN = 256;

    // ------------------------------------------------------------------
    // Claim variants (frozen indices; mirror Lean Disputes.Types)
    // ------------------------------------------------------------------

    /// @notice Same indices as `LegalKernel.Disputes.Types.DisputeClaim`
    ///         (frozen 0..4).  MVP ships three; the others are
    ///         decoded but reverted with `InvalidClaimVariant`.
    uint8 public constant CLAIM_PRECONDITION_FALSE = 0;
    uint8 public constant CLAIM_SIGNATURE_INVALID = 1;
    uint8 public constant CLAIM_NONCE_MISMATCH = 2;
    uint8 public constant CLAIM_ORACLE_MISREPORTED = 3;
    uint8 public constant CLAIM_DOUBLE_APPLY = 4;

    /// @notice Verdict outcomes; frozen indices mirror Lean
    ///         `EvidenceVerdict`.
    uint8 public constant VERDICT_UPHELD = 0;
    uint8 public constant VERDICT_REJECTED = 1;
    uint8 public constant VERDICT_INCONCLUSIVE = 2;

    /// @notice Dispute status; frozen indices mirror Lean
    ///         `DisputeStatus`.
    uint8 public constant STATUS_OPEN = 0;
    uint8 public constant STATUS_UPHELD = 1;
    uint8 public constant STATUS_REJECTED = 2;
    uint8 public constant STATUS_INCONCLUSIVE = 3;
    uint8 public constant STATUS_WITHDRAWN = 4;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @dev `evidenceBlob` is **emitted in the `DisputeFiled` event,
    ///      not stored** in the record.  It is purely informational
    ///      (off-chain inspection / auditor); finalisation re-runs
    ///      the per-claim verifier on a freshly-supplied
    ///      `reEvidenceBlob` so the file-time blob is never read
    ///      on-chain.  Skipping the storage write saves ~640k gas
    ///      per typical large filing.
    struct DisputeRecord {
        uint64 impugnedLogIndex;
        address challenger;
        uint8 claimVariant;
        uint8 status; // STATUS_*
        uint64 filedAtBlock;
    }

    mapping(uint64 => DisputeRecord) private _disputes;
    uint64 public nextDisputeId;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event DisputeFiled(
        uint64 indexed disputeId,
        address indexed challenger,
        uint64 impugnedLogIndex,
        uint8 claimVariant,
        bytes evidenceBlob
    );

    event DisputeUpheld(uint64 indexed disputeId, uint64 impugnedLogIndex);
    event DisputeRejected(uint64 indexed disputeId);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    struct ConstructorArgs {
        bytes32 knomosisVersionTag;
        address bridge;
        address sequencerStake;
        address identityRegistry;
        address migration;
        uint8 quorumThreshold;
        address[] approvedAdjudicators;
    }

    constructor(ConstructorArgs memory args) {
        if (args.bridge == address(0)) revert ZeroAddress();
        if (args.sequencerStake == address(0)) revert ZeroAddress();
        if (args.identityRegistry == address(0)) revert ZeroAddress();
        if (args.approvedAdjudicators.length == 0) revert QuorumThresholdOutOfRange();
        if (
            args.quorumThreshold == 0
                || uint256(args.quorumThreshold) > args.approvedAdjudicators.length
        ) revert QuorumThresholdOutOfRange();

        // **Cross-contract back-reference is defensive, not
        // load-bearing.**  An attacker deploying a malicious
        // verifier pointing at a legitimate bridge cannot make the
        // legitimate bridge do anything: the bridge only honours
        // calls from `bridge.disputeVerifier()`, which is its own
        // immutable.  We expose `assertConsistent()` post-deployment
        // (callable by anyone) for tooling that wants to verify the
        // cross-reference symmetrically.  This refactor lets the
        // deployment script use CREATE2 with predictable salts in
        // either order without a circular bytecode-hash dependency.

        knomosisVersionTag = args.knomosisVersionTag;
        bridge = args.bridge;
        sequencerStake = args.sequencerStake;
        identityRegistry = args.identityRegistry;
        migration = args.migration;
        quorumThreshold = args.quorumThreshold;

        // Snapshot the approved adjudicator set.  Duplicates in
        // `approvedAdjudicators` are silently merged (the per-key
        // mapping write is idempotent), but we track the canonical
        // commitment via `approvedAdjudicatorRoot` so any future
        // governance design can compare to the snapshot.
        for (uint256 i = 0; i < args.approvedAdjudicators.length; ++i) {
            address a = args.approvedAdjudicators[i];
            if (a == address(0)) revert ZeroAddress();
            _approvedAdjudicator[a] = true;
        }
        approvedAdjudicatorRoot = keccak256(abi.encode(args.approvedAdjudicators));

        deploymentId =
            keccak256(abi.encode(block.chainid, address(this), args.knomosisVersionTag));
    }

    // ------------------------------------------------------------------
    // E.2.1 Dispute filing
    // ------------------------------------------------------------------

    /// @notice File a dispute against a previously-submitted state
    ///         root.  Reverts only if migration is activated; the
    ///         dispute pipeline must remain available for as long
    ///         as the predecessor accepts state roots.  Anyone may
    ///         file (the challenger pays the gas).
    /// @notice Reverts when `evidenceBlob.length` exceeds the
    ///         per-dispute upper bound.  Prevents storage / event
    ///         griefing.
    error EvidenceBlobTooLarge(uint256 actual, uint256 maxBytes);

    function fileDispute(
        uint64 impugnedLogIndex,
        uint8 claimVariant,
        bytes calldata evidenceBlob
    ) external returns (uint64 disputeId) {
        if (claimVariant != CLAIM_SIGNATURE_INVALID && claimVariant != CLAIM_NONCE_MISMATCH
            && claimVariant != CLAIM_DOUBLE_APPLY)
        {
            revert InvalidClaimVariant();
        }
        if (evidenceBlob.length > MAX_EVIDENCE_BLOB_BYTES) {
            revert EvidenceBlobTooLarge(evidenceBlob.length, MAX_EVIDENCE_BLOB_BYTES);
        }

        disputeId = nextDisputeId++;
        _disputes[disputeId] = DisputeRecord({
            impugnedLogIndex: impugnedLogIndex,
            challenger: msg.sender,
            claimVariant: claimVariant,
            status: STATUS_OPEN,
            filedAtBlock: uint64(block.number)
        });

        // Emit `evidenceBlob` in the event for off-chain inspection;
        // we deliberately do NOT store it on-chain (the file-time
        // blob is unused by finalisation).
        emit DisputeFiled(disputeId, msg.sender, impugnedLogIndex, claimVariant, evidenceBlob);
    }

    // ------------------------------------------------------------------
    // E.2.2 signatureInvalid claim verifier
    // ------------------------------------------------------------------

    /// @notice The Solidity port of
    ///         `LegalKernel.Disputes.Evidence.checkSignatureInvalid`.
    ///         Decodes a `LogEntry` blob into `(actionHash, signer,
    ///         nonce, sig)`, recomputes the EIP-712 digest the
    ///         user signed, recovers the signing address, and
    ///         compares it against the on-chain registered address
    ///         for `expectedSignerAddr` looked up in the
    ///         `KnomosisIdentityRegistry`.
    ///
    /// @dev    The dispute filer MUST supply
    ///         `expectedSignerAddr` — the L1 address corresponding
    ///         to the LogEntry's `uint64 signer` actor-id.  This
    ///         resolution lives in the runtime adaptor (workstream
    ///         B's L1 ingestor), not on-chain in the MVP.  An
    ///         incorrect `expectedSignerAddr` causes the verifier
    ///         to return `UPHELD` (the supplied address won't
    ///         match the recovered signer), which is the correct
    ///         behaviour for the dispute claim "the signature is
    ///         invalid for this signer-id".
    ///
    ///         The previous design self-derived the address from
    ///         `signer` via `address(uint160(signer))` — a stub that
    ///         silently broke `checkSignatureInvalid` because the
    ///         synthesized address was never the user's actual
    ///         registered address.  The current API closes that gap.
    ///
    /// @param logEntryBlob       CBE-encoded LogEntry
    ///                           (prevHash, actionHash, signer, nonce, sig).
    /// @param expectedSignerAddr the L1 address the dispute filer
    ///                           claims corresponds to `signer`.  The
    ///                           registry lookup keys off this.
    /// @return verdict           0 = upheld, 1 = rejected, 2 = inconclusive.
    function checkSignatureInvalid(
        bytes calldata logEntryBlob,
        address expectedSignerAddr
    ) external view returns (uint8 verdict) {
        // The logEntryBlob's CBE shape mirrors Lean's
        // `Runtime.LogFile.LogEntry` encoding:
        //   prevHash :  bytes32 (32 bytes payload)
        //   actionHash : bytes32  (commitment to action; we don't
        //                          reconstruct the full action
        //                          on-chain — the signer-recovery
        //                          step uses actionHash directly
        //                          per the EIP-712 wrap)
        //   signer :   uint64
        //   nonce :    uint64
        //   sig :      bytes (65 bytes)
        uint256 off = 0;
        // Skip prevHash (not needed for signature verification).
        (, off) = CBEDecode.readBytes32Exact(logEntryBlob, off);
        bytes32 actionHash;
        (actionHash, off) = CBEDecode.readBytes32Exact(logEntryBlob, off);
        uint64 signer;
        (signer, off) = CBEDecode.readUint(logEntryBlob, off);
        uint64 nonce;
        (nonce, off) = CBEDecode.readUint(logEntryBlob, off);
        bytes memory sig;
        (sig, off) = CBEDecode.readBytes(logEntryBlob, off);

        // The bridge's deploymentId is what the signer signed
        // against.
        bytes32 bridgeDid = IKnomosisBridge(bridge).deploymentId();

        // Re-construct the EIP-712 digest the signer must have
        // signed for this entry to be valid.  Uses the canonical
        // per-action signing domain (`ACTION_DOMAIN_NAME`), NOT the
        // verdict domain — the user signed against the action
        // domain at submission time.
        bytes32 ds = KnomosisEip712.domainSeparator(
            ACTION_DOMAIN_NAME, ACTION_DOMAIN_VERSION, block.chainid, uint256(0), bridge
        );
        bytes32 sh =
            KnomosisEip712.actionStructHash(actionHash, signer, nonce, bridgeDid);
        bytes32 digest = KnomosisEip712.digest(ds, sh);

        // Defensive: if the supplied expected address is zero, we
        // can't verify and return INCONCLUSIVE.  A zero address
        // would never produce a valid ECDSA signature.
        if (expectedSignerAddr == address(0)) return VERDICT_INCONCLUSIVE;

        // Look up the supplied address in the identity registry.
        // If unregistered or wrong kind, return INCONCLUSIVE — the
        // dispute filer either provided the wrong address or the
        // signer hasn't registered yet.
        IKnomosisIdentityRegistry.IdentityRecord memory rec =
            IKnomosisIdentityRegistry(identityRegistry).lookup(expectedSignerAddr);
        if (rec.kind != IKnomosisIdentityRegistry.SignerKind.ECDSA_EOA) {
            return VERDICT_INCONCLUSIVE;
        }

        // Sanity: the registered pubkey must hash to the supplied
        // address (front-running protection from
        // `KnomosisIdentityRegistry.registerECDSA`).  This is
        // already guaranteed by the registry's invariants but the
        // explicit check is defence in depth.
        address derivedFromPubkey = address(uint160(uint256(keccak256(rec.pubkey))));
        if (derivedFromPubkey != expectedSignerAddr) return VERDICT_INCONCLUSIVE;

        // Recover the signer from the signature.  Length / s-value
        // are checked by OZ ECDSA; an invalid signature produces
        // a different recovered address.  The OZ `recover` reverts
        // on malformed signatures (high-s, length != 65, etc.).
        if (sig.length != 65) return VERDICT_UPHELD;
        address recovered;
        try this.tryRecover(digest, sig) returns (address rec_) {
            recovered = rec_;
        } catch {
            // OZ ECDSA reverts on malformed signature — claim is
            // upheld (signature was indeed invalid).
            return VERDICT_UPHELD;
        }
        if (recovered == address(0)) return VERDICT_UPHELD;
        if (recovered == expectedSignerAddr) return VERDICT_REJECTED;
        return VERDICT_UPHELD;
    }

    /// @notice External wrapper for `ECDSA.recover` so we can use
    ///         try/catch for malformed signatures (`recover` reverts
    ///         on high-s sigs etc.).  The MVP-friendly behaviour
    ///         maps a revert to `UPHELD` (the signature is indeed
    ///         invalid).  Public so test fixtures can call it.
    function tryRecover(bytes32 digest, bytes memory sig)
        external
        pure
        returns (address)
    {
        return ECDSA.recover(digest, sig);
    }

    // ------------------------------------------------------------------
    // E.2.3 nonceMismatch claim verifier
    // ------------------------------------------------------------------

    /// @notice The Solidity port of
    ///         `LegalKernel.Disputes.Evidence.checkNonceMismatch`.
    ///         Replays a log prefix in order, maintaining a
    ///         `(signer → expectedNonce)` map; at the impugned
    ///         entry, compares the recorded nonce against
    ///         expectsNonce.  No signature checks.
    /// @return verdict 0 = upheld, 1 = rejected, 2 = inconclusive.
    function checkNonceMismatch(uint64 impugnedLogIndex, bytes calldata prefixBlob)
        external
        pure
        returns (uint8 verdict)
    {
        // The prefixBlob encodes a CBE array of LogEntry encodings.
        // Each LogEntry has shape (prevHash, actionHash, signer,
        // nonce, sig).  We only need (signer, nonce) per entry.
        uint256 off = 0;
        uint64 entryCount;
        (entryCount, off) = CBEDecode.readArrayHead(prefixBlob, off);
        if (entryCount > MAX_PREFIX_LEN) revert MaxPrefixLenExceeded();

        // Compact in-memory map for `expectsNonce`: arrays of
        // signers and their next-expected nonces.  256 entries
        // max, so linear search per insertion is bounded gas-wise.
        uint64[] memory signerKeys = new uint64[](entryCount);
        uint64[] memory expectedNonces = new uint64[](entryCount);
        uint256 mapLen = 0;

        for (uint64 i = 0; i < entryCount; ++i) {
            // Skip prevHash + actionHash.
            (, off) = CBEDecode.readBytes32Exact(prefixBlob, off);
            (, off) = CBEDecode.readBytes32Exact(prefixBlob, off);
            uint64 signer;
            uint64 nonce;
            (signer, off) = CBEDecode.readUint(prefixBlob, off);
            (nonce, off) = CBEDecode.readUint(prefixBlob, off);
            // Skip sig.
            (, off) = CBEDecode.readBytes(prefixBlob, off);

            // Find existing slot or allocate new one.
            uint256 slot = type(uint256).max;
            for (uint256 j = 0; j < mapLen; ++j) {
                if (signerKeys[j] == signer) {
                    slot = j;
                    break;
                }
            }

            if (i == impugnedLogIndex) {
                uint64 expected = (slot == type(uint256).max)
                    ? uint64(0)
                    : expectedNonces[slot];
                if (nonce != expected) return VERDICT_UPHELD;
                return VERDICT_REJECTED;
            }

            // Otherwise advance the per-signer counter.
            // Mirrors Lean kernelOnlyReplay: just bump nonce, no
            // admissibility check.
            if (slot == type(uint256).max) {
                signerKeys[mapLen] = signer;
                expectedNonces[mapLen] = nonce + 1;
                ++mapLen;
            } else {
                expectedNonces[slot] = nonce + 1;
            }
        }
        // The impugned index was never reached during prefix walk.
        return VERDICT_INCONCLUSIVE;
    }

    // ------------------------------------------------------------------
    // E.2.4 doubleApply claim verifier
    // ------------------------------------------------------------------

    /// @notice The Solidity port of
    ///         `LegalKernel.Disputes.Evidence.checkDoubleApply`.
    ///         Two log entries with the same `(signer, nonce)`
    ///         pair at distinct indices indicate a replay.
    /// @return verdict 0 = upheld, 1 = rejected, 2 = inconclusive.
    function checkDoubleApply(
        uint64 impugnedLogIndex,
        uint64 secondaryLogIndex,
        bytes calldata impugnedBlob,
        bytes calldata secondaryBlob
    ) external pure returns (uint8 verdict) {
        if (impugnedLogIndex == secondaryLogIndex) revert SelfClaimInvalid();

        (uint64 sigA, uint64 nonceA) = _readSignerNonce(impugnedBlob);
        (uint64 sigB, uint64 nonceB) = _readSignerNonce(secondaryBlob);

        if (sigA == sigB && nonceA == nonceB) return VERDICT_UPHELD;
        return VERDICT_REJECTED;
    }

    function _readSignerNonce(bytes calldata blob)
        internal
        pure
        returns (uint64 signer, uint64 nonce)
    {
        uint256 off = 0;
        // Skip prevHash + actionHash.
        (, off) = CBEDecode.readBytes32Exact(blob, off);
        (, off) = CBEDecode.readBytes32Exact(blob, off);
        (signer, off) = CBEDecode.readUint(blob, off);
        (nonce, off) = CBEDecode.readUint(blob, off);
    }

    // ------------------------------------------------------------------
    // E.2.5 Verdict finalisation
    // ------------------------------------------------------------------

    /// @notice Reverts if the supplied signers array is too long.
    error TooManySigners(uint256 supplied, uint256 maxAllowed);

    /// @notice Reverts if the supplied evidence references the
    ///         wrong signer-id resolution (used by `signatureInvalid`
    ///         only).
    error MissingSignerHint();

    /// @notice Computes the canonical EIP-712 verdict digest that
    ///         adjudicators sign.  Binds `(disputeId, outcome,
    ///         deploymentId)` so a signature for one verdict cannot
    ///         be replayed as a signature for a different one.  The
    ///         dispute filer / finaliser never supplies the digest;
    ///         the contract derives it on-chain.
    function verdictDigest(uint64 disputeId, uint8 outcome)
        public
        view
        returns (bytes32)
    {
        bytes32 ds = KnomosisEip712.domainSeparator(
            VERDICT_DOMAIN_NAME, VERDICT_DOMAIN_VERSION,
            block.chainid, uint256(0), address(this)
        );
        bytes32 sh = keccak256(
            abi.encode(
                keccak256(
                    "Verdict(uint64 disputeId,uint8 outcome,bytes32 deploymentId)"
                ),
                uint256(disputeId),
                uint256(outcome),
                deploymentId
            )
        );
        return KnomosisEip712.digest(ds, sh);
    }

    /// @notice For `signatureInvalid` claims, the dispute finaliser
    ///         must supply `signerHint` — the L1 address
    ///         corresponding to the LogEntry's `uint64 signer`
    ///         actor-id.  For other claim variants this argument is
    ///         ignored.  See `checkSignatureInvalid` docstring for
    ///         rationale.
    function finalizeUpheld(
        uint64 disputeId,
        bytes calldata reEvidenceBlob,
        address signerHint,
        address[] calldata signers,
        bytes[] calldata sigs
    ) external nonReentrant {
        DisputeRecord storage d = _disputes[disputeId];
        if (d.challenger == address(0)) revert UnknownDispute();
        if (d.status != STATUS_OPEN) revert AlreadyDecided();
        if (signers.length > MAX_VERDICT_SIGNERS) {
            revert TooManySigners(signers.length, MAX_VERDICT_SIGNERS);
        }

        // Compute the canonical verdict digest the adjudicators
        // must have signed.  Binds (disputeId, outcome=UPHELD,
        // deploymentId) — replay-resistant across disputes.
        bytes32 digest = verdictDigest(disputeId, VERDICT_UPHELD);

        // Quorum check with deduplication: each distinct approved
        // signer with a valid signature contributes at most 1.
        uint256 verified = _countVerifiedSignatures(digest, signers, sigs);
        if (verified < quorumThreshold) revert QuorumNotMet(verified, quorumThreshold);

        // Re-run the per-claim verifier at finalisation time.
        // The contract does not trust the file-time evidence; the
        // verifier must re-confirm UPHELD against the *current*
        // log prefix.
        uint8 verdict = _runClaimVerifier(d, reEvidenceBlob, signerHint);
        if (verdict != VERDICT_UPHELD) revert EvidenceNotUpheld();

        // ---- Effects ----
        d.status = STATUS_UPHELD;

        // ---- Interactions: slash + revert ----
        // Both calls happen inside this transaction; if either
        // reverts, the entire finalisation reverts.
        IKnomosisSequencerStake(sequencerStake).slash(disputeId, d.challenger);
        IKnomosisBridge(bridge).revertToPriorRoot(d.impugnedLogIndex);

        emit DisputeUpheld(disputeId, d.impugnedLogIndex);
    }

    /// @notice Symmetric path for adjudicator-signed `.rejected`
    ///         verdicts: no slash, no rollback.  Closes a dispute
    ///         that the evidence does not support.
    function finalizeRejected(
        uint64 disputeId,
        bytes calldata reEvidenceBlob,
        address signerHint,
        address[] calldata signers,
        bytes[] calldata sigs
    ) external nonReentrant {
        DisputeRecord storage d = _disputes[disputeId];
        if (d.challenger == address(0)) revert UnknownDispute();
        if (d.status != STATUS_OPEN) revert AlreadyDecided();
        if (signers.length > MAX_VERDICT_SIGNERS) {
            revert TooManySigners(signers.length, MAX_VERDICT_SIGNERS);
        }

        bytes32 digest = verdictDigest(disputeId, VERDICT_REJECTED);

        uint256 verified = _countVerifiedSignatures(digest, signers, sigs);
        if (verified < quorumThreshold) revert QuorumNotMet(verified, quorumThreshold);

        uint8 verdict = _runClaimVerifier(d, reEvidenceBlob, signerHint);
        if (verdict != VERDICT_REJECTED) revert EvidenceNotRejected();

        d.status = STATUS_REJECTED;
        emit DisputeRejected(disputeId);
    }

    /// @notice Per-signer-deduplicated quorum count.  Mirrors the
    ///         Phase-6 audit-1 fix in
    ///         `LegalKernel.Disputes.Verdict.countVerifiedSignatures`:
    ///         a signer with one valid signature counts at most 1
    ///         regardless of (signers, sigs) padding.
    function _countVerifiedSignatures(
        bytes32 verdictHash,
        address[] calldata signers,
        bytes[] calldata sigs
    ) internal view returns (uint256) {
        if (signers.length != sigs.length) return 0;
        // Caller-side bound is enforced in finalize{Upheld,Rejected};
        // this is a defence-in-depth re-check.
        if (signers.length > MAX_VERDICT_SIGNERS) return 0;

        // Quadratic dedup over signers — bounded by
        // MAX_VERDICT_SIGNERS = 64 in the worst case.
        address[] memory seen = new address[](signers.length);
        uint256 seenLen = 0;

        for (uint256 i = 0; i < signers.length; ++i) {
            address s = signers[i];
            if (s == address(0)) continue;
            if (!_approvedAdjudicator[s]) continue;
            if (sigs[i].length != 65) continue;

            bool already;
            for (uint256 j = 0; j < seenLen; ++j) {
                if (seen[j] == s) { already = true; break; }
            }
            if (already) continue;

            address recovered = ECDSA.recover(verdictHash, sigs[i]);
            if (recovered != s) continue;

            seen[seenLen++] = s;
        }
        return seenLen;
    }

    function _runClaimVerifier(
        DisputeRecord storage d,
        bytes calldata reEvidenceBlob,
        address signerHint
    ) internal view returns (uint8) {
        if (d.claimVariant == CLAIM_SIGNATURE_INVALID) {
            // signatureInvalid REQUIRES a signerHint.  Without it
            // the registry lookup can't proceed.
            if (signerHint == address(0)) revert MissingSignerHint();
            return this.checkSignatureInvalid(reEvidenceBlob, signerHint);
        } else if (d.claimVariant == CLAIM_NONCE_MISMATCH) {
            return this.checkNonceMismatch(d.impugnedLogIndex, reEvidenceBlob);
        } else if (d.claimVariant == CLAIM_DOUBLE_APPLY) {
            // The doubleApply re-evidence blob is the
            // concatenation of impugnedBlob + secondaryBlob with
            // their lengths written first; the verifier expects
            // them as separate calldata, so we split here.  The
            // shape matches the off-chain assembly produced by
            // the sequencer's dispute-playback tool.
            return _runDoubleApplyFromConcat(d.impugnedLogIndex, reEvidenceBlob);
        }
        revert InvalidClaimVariant();
    }

    /// @notice Reverts when the `_runDoubleApplyFromConcat` blob's
    ///         array head doesn't declare exactly 2 entries.
    ///         Audit-3 defensive check: closes a class of malformed
    ///         input where the count and the actual byte-string
    ///         count diverge.
    error DoubleApplyConcatBadCount(uint64 declared, uint64 expected);

    function _runDoubleApplyFromConcat(uint64 impugnedLogIndex, bytes calldata blob)
        internal
        view
        returns (uint8)
    {
        // CBE array of two byte strings: impugnedBlob, secondaryBlob.
        // Plus the secondary log index as a uint at the front.
        uint256 off = 0;
        uint64 secondaryLogIndex;
        (secondaryLogIndex, off) = CBEDecode.readUint(blob, off);
        uint64 count;
        (count, off) = CBEDecode.readArrayHead(blob, off);
        // Audit-3: assert the array declares exactly 2 entries (the
        // dispute-replay tooling always emits this shape).
        if (count != 2) revert DoubleApplyConcatBadCount(count, uint64(2));
        // Read each of the two byte strings.
        bytes memory impugnedBytes;
        bytes memory secondaryBytes;
        (impugnedBytes, off) = CBEDecode.readBytes(blob, off);
        (secondaryBytes, off) = CBEDecode.readBytes(blob, off);
        // Audit-3: assert no trailing garbage.
        CBEDecode.assertFullyConsumed(blob, off);
        return this.checkDoubleApplyFromBytes(
            impugnedLogIndex, secondaryLogIndex, impugnedBytes, secondaryBytes
        );
    }

    /// @notice External wrapper used by `_runDoubleApplyFromConcat`
    ///         to re-enter the doubleApply verifier with calldata-
    ///         shaped arguments.
    function checkDoubleApplyFromBytes(
        uint64 impugnedLogIndex,
        uint64 secondaryLogIndex,
        bytes calldata impugnedBlob,
        bytes calldata secondaryBlob
    ) external pure returns (uint8) {
        if (impugnedLogIndex == secondaryLogIndex) revert SelfClaimInvalid();

        (uint64 sigA, uint64 nonceA) = _readSignerNonce(impugnedBlob);
        (uint64 sigB, uint64 nonceB) = _readSignerNonce(secondaryBlob);

        if (sigA == sigB && nonceA == nonceB) return VERDICT_UPHELD;
        return VERDICT_REJECTED;
    }

    // ------------------------------------------------------------------
    // External views
    // ------------------------------------------------------------------

    function disputeAt(uint64 disputeId)
        external
        view
        returns (
            uint64 impugnedLogIndex,
            address challenger,
            uint8 claimVariant,
            uint8 status,
            uint64 filedAtBlock
        )
    {
        DisputeRecord storage d = _disputes[disputeId];
        return (d.impugnedLogIndex, d.challenger, d.claimVariant, d.status, d.filedAtBlock);
    }

    function isDisputeOpen(uint64 disputeId) external view returns (bool) {
        return _disputes[disputeId].status == STATUS_OPEN
            && _disputes[disputeId].challenger != address(0);
    }

    function isApprovedAdjudicator(address addr) external view returns (bool) {
        return _approvedAdjudicator[addr];
    }

    /// @notice Symmetric cross-contract consistency check.  Returns
    ///         `true` iff this verifier's `bridge` immutable points
    ///         at a bridge whose `disputeVerifier` immutable points
    ///         back at this verifier.  Anyone may call.  This is the
    ///         deployment-time invariant that an off-chain auditor
    ///         (or the deployment script) verifies post-deploy; it
    ///         is moved out of the constructor so the cross-contract
    ///         reference cycle does not block CREATE2 deployment.
    function assertConsistent() external view returns (bool) {
        return IKnomosisBridge(bridge).disputeVerifier() == address(this);
    }
}
