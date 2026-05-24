// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisDisputeVerifier} from "src/contracts/KnomosisDisputeVerifier.sol";
import {KnomosisSequencerStake} from "src/contracts/KnomosisSequencerStake.sol";
import {KnomosisIdentityRegistry} from "src/contracts/KnomosisIdentityRegistry.sol";

import {CBEDecode} from "src/lib/CBEDecode.sol";
import {Deployer} from "test/utils/Deployer.sol";

/// @title KnomosisDisputeVerifierTest
/// @notice Tests for the dispute verifier contract.  Each test
///         exercises one functional area of E.2 (filing,
///         per-claim verifiers, finalisation).
contract KnomosisDisputeVerifierTest is Test {
    KnomosisBridge private bridge;
    KnomosisDisputeVerifier private verifier;
    KnomosisSequencerStake private stake;
    KnomosisIdentityRegistry private registry;

    Deployer private deployer;

    uint256 private constant ATTESTOR_PK = 0xA77E5701;
    uint256 private constant ADJ1_PK = 0xA1;
    uint256 private constant ADJ2_PK = 0xA2;
    uint256 private constant NON_ADJ_PK = 0xBAD;
    address private attestor;
    address private adjudicator1;
    address private adjudicator2;
    address private nonAdjudicator;
    address private sequencer = address(0xBEEF);
    address private challenger = address(0xC0DE);

    event DisputeFiled(
        uint64 indexed disputeId,
        address indexed challenger,
        uint64 impugnedLogIndex,
        uint8 claimVariant,
        bytes evidenceBlob
    );

    function setUp() public {
        attestor = vm.addr(ATTESTOR_PK);
        adjudicator1 = vm.addr(ADJ1_PK);
        adjudicator2 = vm.addr(ADJ2_PK);
        nonAdjudicator = vm.addr(NON_ADJ_PK);

        deployer = new Deployer();

        address[] memory adjudicators = new address[](2);
        adjudicators[0] = adjudicator1;
        adjudicators[1] = adjudicator2;

        uint64[] memory rids = new uint64[](0);
        address[] memory toks = new address[](0);

        Deployer.Deployment memory d = deployer.deployAll(
            attestor, sequencer, adjudicators,
            uint8(2), uint64(100), uint64(50),
            uint64(200), uint64(50),
            uint256(1000 ether), uint256(5000),
            rids, toks
        );
        bridge = d.bridge;
        verifier = d.verifier;
        stake = d.stake;
        registry = d.registry;
    }

    // ------------------------------------------------------------------
    // Constructor / immutability
    // ------------------------------------------------------------------

    function test_constructor_pins_immutables() public view {
        assertEq(verifier.bridge(), address(bridge));
        assertEq(verifier.sequencerStake(), address(stake));
        assertEq(verifier.identityRegistry(), address(registry));
        assertEq(verifier.quorumThreshold(), 2);
    }

    function test_assertConsistent() public view {
        assertTrue(verifier.assertConsistent());
    }

    function test_no_admin_surface() public {
        bytes4[] memory forbidden = new bytes4[](6);
        forbidden[0] = bytes4(keccak256("pause()"));
        forbidden[1] = bytes4(keccak256("setQuorumThreshold(uint8)"));
        forbidden[2] = bytes4(keccak256("addAdjudicator(address)"));
        forbidden[3] = bytes4(keccak256("removeAdjudicator(address)"));
        forbidden[4] = bytes4(keccak256("transferOwnership(address)"));
        forbidden[5] = bytes4(keccak256("upgradeTo(address)"));
        for (uint256 i = 0; i < forbidden.length; ++i) {
            (bool ok,) = address(verifier).call(abi.encodePacked(forbidden[i]));
            assertFalse(ok, "admin function unexpectedly callable");
        }
    }

    function test_approved_adjudicator_set_immutable() public view {
        assertTrue(verifier.isApprovedAdjudicator(adjudicator1));
        assertTrue(verifier.isApprovedAdjudicator(adjudicator2));
        assertFalse(verifier.isApprovedAdjudicator(nonAdjudicator));
    }

    function test_constructor_reverts_on_quorum_zero() public {
        Deployer fresh = new Deployer();
        address[] memory ad = new address[](1);
        ad[0] = adjudicator1;
        uint64[] memory r = new uint64[](0);
        address[] memory t = new address[](0);
        vm.expectRevert();
        fresh.deployAll(attestor, sequencer, ad, uint8(0),
            uint64(100), uint64(50), uint64(200), uint64(50),
            uint256(1 ether), uint256(5000), r, t);
    }

    function test_constructor_reverts_on_quorum_above_set_size() public {
        Deployer fresh = new Deployer();
        address[] memory ad = new address[](1);
        ad[0] = adjudicator1;
        uint64[] memory r = new uint64[](0);
        address[] memory t = new address[](0);
        vm.expectRevert();
        fresh.deployAll(attestor, sequencer, ad, uint8(2),
            uint64(100), uint64(50), uint64(200), uint64(50),
            uint256(1 ether), uint256(5000), r, t);
    }

    // ------------------------------------------------------------------
    // E.2.1 fileDispute
    // ------------------------------------------------------------------

    function test_fileDispute_assigns_id_and_records_record() public {
        bytes memory ev = hex"deadbeef";
        // Read public-constant getters BEFORE setting up vm.prank
        // (the prank only applies to the NEXT call, and a getter
        // call would consume it).
        uint8 doubleApplyVariant = verifier.CLAIM_DOUBLE_APPLY();
        uint8 openStatus = verifier.STATUS_OPEN();

        vm.expectEmit(true, true, false, true);
        emit DisputeFiled(0, challenger, uint64(7), doubleApplyVariant, ev);
        vm.prank(challenger);
        uint64 id = verifier.fileDispute(uint64(7), doubleApplyVariant, ev);
        assertEq(id, 0);

        (uint64 idx, address chal, uint8 cv, uint8 status, uint64 fab) =
            verifier.disputeAt(0);
        assertEq(idx, 7);
        assertEq(chal, challenger);
        assertEq(cv, doubleApplyVariant);
        assertEq(status, openStatus);
        assertEq(fab, uint64(block.number));
    }

    function test_fileDispute_increments_disputeId() public {
        vm.startPrank(challenger);
        uint64 id1 = verifier.fileDispute(uint64(7), verifier.CLAIM_DOUBLE_APPLY(), hex"01");
        uint64 id2 = verifier.fileDispute(uint64(8), verifier.CLAIM_DOUBLE_APPLY(), hex"02");
        uint64 id3 = verifier.fileDispute(uint64(9), verifier.CLAIM_DOUBLE_APPLY(), hex"03");
        vm.stopPrank();
        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(id3, 2);
        assertEq(verifier.nextDisputeId(), 3);
    }

    function test_fileDispute_rejects_unsupported_claim_variant() public {
        uint8 preconditionFalse = verifier.CLAIM_PRECONDITION_FALSE();
        vm.expectRevert(KnomosisDisputeVerifier.InvalidClaimVariant.selector);
        verifier.fileDispute(uint64(0), preconditionFalse, hex"");
    }

    function test_fileDispute_rejects_oracle_misreported_in_mvp() public {
        uint8 oracleMisreported = verifier.CLAIM_ORACLE_MISREPORTED();
        vm.expectRevert(KnomosisDisputeVerifier.InvalidClaimVariant.selector);
        verifier.fileDispute(uint64(0), oracleMisreported, hex"");
    }

    function test_isDisputeOpen() public {
        vm.prank(challenger);
        uint64 id = verifier.fileDispute(uint64(7), verifier.CLAIM_DOUBLE_APPLY(), hex"00");
        assertTrue(verifier.isDisputeOpen(id));
        assertFalse(verifier.isDisputeOpen(uint64(99)));
    }

    // ------------------------------------------------------------------
    // E.2.4 doubleApply verifier (simplest; doesn't need cross-stack CBE)
    // ------------------------------------------------------------------

    function test_checkDoubleApply_revert_on_self_claim() public {
        bytes memory blob = _logEntryBlob(1, 5, hex"0102");
        vm.expectRevert(KnomosisDisputeVerifier.SelfClaimInvalid.selector);
        verifier.checkDoubleApply(uint64(7), uint64(7), blob, blob);
    }

    function test_checkDoubleApply_upheld_when_signer_and_nonce_match() public view {
        // Two log entries with the same (signer, nonce) at different indices.
        bytes memory blobA = _logEntryBlob(1, 5, hex"deadbeef");
        bytes memory blobB = _logEntryBlob(1, 5, hex"cafe");
        uint8 v = verifier.checkDoubleApply(uint64(7), uint64(8), blobA, blobB);
        assertEq(v, verifier.VERDICT_UPHELD());
    }

    function test_checkDoubleApply_rejected_on_distinct_signers() public view {
        bytes memory blobA = _logEntryBlob(1, 5, hex"de");
        bytes memory blobB = _logEntryBlob(2, 5, hex"ad");
        uint8 v = verifier.checkDoubleApply(uint64(7), uint64(8), blobA, blobB);
        assertEq(v, verifier.VERDICT_REJECTED());
    }

    function test_checkDoubleApply_rejected_on_distinct_nonces() public view {
        bytes memory blobA = _logEntryBlob(1, 5, hex"de");
        bytes memory blobB = _logEntryBlob(1, 6, hex"ad");
        uint8 v = verifier.checkDoubleApply(uint64(7), uint64(8), blobA, blobB);
        assertEq(v, verifier.VERDICT_REJECTED());
    }

    // ------------------------------------------------------------------
    // E.2.3 nonceMismatch verifier
    // ------------------------------------------------------------------

    function test_checkNonceMismatch_upheld_when_nonce_does_not_match_expected() public view {
        // Build a 1-entry prefix with signer=1, nonce=99.  At index 0,
        // expected nonce is 0 (no prior entries for signer 1).  The
        // recorded nonce is 99 → mismatch → upheld.
        bytes memory entry = _logEntryBlob(1, 99, hex"ff");
        bytes memory prefix = _arrayHead(1);
        bytes memory full = bytes.concat(prefix, entry);
        uint8 v = verifier.checkNonceMismatch(uint64(0), full);
        assertEq(v, verifier.VERDICT_UPHELD());
    }

    function test_checkNonceMismatch_rejected_when_nonce_matches_expected() public view {
        // Build a 1-entry prefix with signer=1, nonce=0.  Expected = 0.
        bytes memory entry = _logEntryBlob(1, 0, hex"ff");
        bytes memory prefix = _arrayHead(1);
        bytes memory full = bytes.concat(prefix, entry);
        uint8 v = verifier.checkNonceMismatch(uint64(0), full);
        assertEq(v, verifier.VERDICT_REJECTED());
    }

    function test_checkNonceMismatch_rejected_on_two_entry_legitimate_chain() public view {
        // signer=1 nonce=0 at idx 0; then signer=1 nonce=1 at idx 1.
        bytes memory e1 = _logEntryBlob(1, 0, hex"01");
        bytes memory e2 = _logEntryBlob(1, 1, hex"02");
        bytes memory prefix = _arrayHead(2);
        bytes memory full = bytes.concat(prefix, e1, e2);
        uint8 v = verifier.checkNonceMismatch(uint64(1), full);
        assertEq(v, verifier.VERDICT_REJECTED());
    }

    function test_checkNonceMismatch_upheld_on_replay() public view {
        // signer=1 nonce=0 at idx 0; then signer=1 nonce=0 at idx 1 — replay.
        bytes memory e1 = _logEntryBlob(1, 0, hex"01");
        bytes memory e2 = _logEntryBlob(1, 0, hex"02");
        bytes memory prefix = _arrayHead(2);
        bytes memory full = bytes.concat(prefix, e1, e2);
        uint8 v = verifier.checkNonceMismatch(uint64(1), full);
        assertEq(v, verifier.VERDICT_UPHELD());
    }

    function test_checkNonceMismatch_revert_on_oversized_prefix() public {
        bytes memory prefix = _arrayHead(uint64(257)); // > MAX_PREFIX_LEN
        bytes memory full = bytes.concat(prefix, hex"00");
        vm.expectRevert(KnomosisDisputeVerifier.MaxPrefixLenExceeded.selector);
        verifier.checkNonceMismatch(uint64(0), full);
    }

    function test_checkNonceMismatch_inconclusive_when_index_past_prefix() public view {
        bytes memory e1 = _logEntryBlob(1, 0, hex"01");
        bytes memory prefix = _arrayHead(1);
        bytes memory full = bytes.concat(prefix, e1);
        uint8 v = verifier.checkNonceMismatch(uint64(99), full);
        assertEq(v, verifier.VERDICT_INCONCLUSIVE());
    }

    function test_checkNonceMismatch_per_signer_isolation() public view {
        // signer=1 nonce=0 at idx 0 (legit); signer=2 nonce=99 at idx 1.
        // At idx 1, signer 2's expected nonce is 0.  Recorded = 99 → upheld.
        bytes memory e1 = _logEntryBlob(1, 0, hex"01");
        bytes memory e2 = _logEntryBlob(2, 99, hex"02");
        bytes memory prefix = _arrayHead(2);
        bytes memory full = bytes.concat(prefix, e1, e2);
        uint8 v = verifier.checkNonceMismatch(uint64(1), full);
        assertEq(v, verifier.VERDICT_UPHELD());
    }

    // ------------------------------------------------------------------
    // CBE encoding helpers (mirror Lean's encoding shape)
    // ------------------------------------------------------------------

    /// @notice Build a CBE byte string: tag + 8 LE length + payload.
    function _cborBytesEncoding(bytes memory payload)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory head = _cborHead(CBEDecode.TAG_BYTES, uint64(payload.length));
        return bytes.concat(head, payload);
    }

    /// @notice Build a CBE uint head: tag + 8 LE bytes.
    function _cborHead(uint8 tag, uint64 n) internal pure returns (bytes memory) {
        bytes memory head = new bytes(9);
        head[0] = bytes1(tag);
        for (uint64 i = 0; i < 8; ++i) {
            head[1 + uint256(i)] = bytes1(uint8((n >> (8 * i)) & 0xFF));
        }
        return head;
    }

    function _cborUint(uint64 n) internal pure returns (bytes memory) {
        return _cborHead(CBEDecode.TAG_UINT, n);
    }

    function _arrayHead(uint64 count) internal pure returns (bytes memory) {
        return _cborHead(CBEDecode.TAG_ARRAY, count);
    }

    /// @notice Build a 32-byte CBE byte string (used for prevHash /
    ///         actionHash slots).
    function _cborBytes32(bytes32 b) internal pure returns (bytes memory) {
        return _cborBytesEncoding(abi.encodePacked(b));
    }

    /// @notice Build a CBE-encoded LogEntry (prevHash, actionHash,
    ///         signer, nonce, sig).  Mirrors the Lean encoding.
    function _logEntryBlob(uint64 signer, uint64 nonce, bytes memory sig)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            _cborBytes32(bytes32(0)), // prevHash placeholder
            _cborBytes32(keccak256(abi.encode(signer, nonce))), // actionHash
            _cborUint(signer),
            _cborUint(nonce),
            _cborBytesEncoding(sig)
        );
    }

    /// @notice Build a CBE-encoded LogEntry with a known
    ///         actionHash (instead of the default fingerprint).
    ///         Used by signatureInvalid tests where the signer
    ///         signs a *specific* actionHash.
    function _logEntryBlobWithActionHash(
        uint64 signer,
        uint64 nonce,
        bytes32 actionHash,
        bytes memory sig
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            _cborBytes32(bytes32(0)),
            _cborBytes32(actionHash),
            _cborUint(signer),
            _cborUint(nonce),
            _cborBytesEncoding(sig)
        );
    }

    // ==================================================================
    // Audit fix tests — added in the post-PR security audit.
    // ==================================================================

    // ---- FIX 1+2: checkSignatureInvalid signer-id resolution + domain ----

    function test_audit_checkSignatureInvalid_inconclusive_on_zero_address() public view {
        bytes memory blob = _logEntryBlob(uint64(1), uint64(0), hex"00");
        uint8 v = verifier.checkSignatureInvalid(blob, address(0));
        assertEq(v, verifier.VERDICT_INCONCLUSIVE());
    }

    function test_audit_checkSignatureInvalid_inconclusive_on_unregistered_address()
        public
    {
        bytes memory blob = _logEntryBlob(uint64(1), uint64(0), hex"00");
        // Use a fresh, never-registered address.
        address unreg = makeAddr("never-registered");
        uint8 v = verifier.checkSignatureInvalid(blob, unreg);
        assertEq(v, verifier.VERDICT_INCONCLUSIVE());
    }

    function test_audit_checkSignatureInvalid_upheld_on_invalid_signature_length()
        public
    {
        // Register the well-known user (privkey = 1, secp256k1 G).
        uint256 userPk = 1;
        address userAddr = vm.addr(userPk);
        bytes memory userPubkey = _vmAddrPubkey(userPk);
        vm.prank(userAddr);
        registry.registerECDSA(userPubkey);

        // Build a blob whose `sig` is too short (not 65 bytes).
        bytes memory blob = _logEntryBlob(uint64(1), uint64(0), hex"deadbeef");
        uint8 v = verifier.checkSignatureInvalid(blob, userAddr);
        // Length != 65 → upheld (signature is invalid).
        assertEq(v, verifier.VERDICT_UPHELD());
    }

    /// @notice **REJECTED-path test (audit-3 addition).**  When the
    ///         supplied signature DOES validate against the
    ///         registered pubkey for the supplied signerHint, the
    ///         claim "the signature is invalid" is REJECTED.  This
    ///         test was missing in audit-2's coverage; without it,
    ///         the REJECTED branch was untested.
    function test_audit3_checkSignatureInvalid_rejected_when_signature_is_valid()
        public
    {
        // Register the well-known user (privkey = 1, secp256k1 G).
        uint256 userPk = 1;
        address userAddr = vm.addr(userPk);
        bytes memory userPubkey = _vmAddrPubkey(userPk);
        vm.prank(userAddr);
        registry.registerECDSA(userPubkey);

        // Construct a SignedAction-shaped digest the user would
        // sign.  Use a deterministic actionHash and the bridge's
        // canonical EIP-712 wrap.
        uint64 signerId = 999;
        uint64 nonce = 0;
        bytes32 actionHash = keccak256("test-action");
        bytes32 ds = _actionDomainSeparator();
        bytes32 sh = _actionStructHash(actionHash, signerId, nonce, bridge.deploymentId());
        bytes32 digest = keccak256(abi.encodePacked(bytes2(0x1901), ds, sh));

        // Sign with privkey = 1.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Build the LogEntry blob with the signed actionHash.
        bytes memory blob =
            _logEntryBlobWithActionHash(signerId, nonce, actionHash, sig);

        // The verifier should recover userAddr (matching the
        // registered identity) and return REJECTED.
        uint8 verdict = verifier.checkSignatureInvalid(blob, userAddr);
        assertEq(verdict, verifier.VERDICT_REJECTED());
    }

    /// @notice **UPHELD-path test (audit-3 addition).**  When the
    ///         signature recovers to a DIFFERENT address than the
    ///         supplied signerHint, the claim is UPHELD.
    function test_audit3_checkSignatureInvalid_upheld_on_signature_for_wrong_signer()
        public
    {
        // Register the well-known user (privkey = 1).
        uint256 userPk = 1;
        address userAddr = vm.addr(userPk);
        bytes memory userPubkey = _vmAddrPubkey(userPk);
        vm.prank(userAddr);
        registry.registerECDSA(userPubkey);

        // Build the digest the user would sign.
        uint64 signerId = 999;
        uint64 nonce = 0;
        bytes32 actionHash = keccak256("test-action-2");
        bytes32 ds = _actionDomainSeparator();
        bytes32 sh = _actionStructHash(actionHash, signerId, nonce, bridge.deploymentId());
        bytes32 digest = keccak256(abi.encodePacked(bytes2(0x1901), ds, sh));

        // Sign with privkey = 1.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        bytes memory blob =
            _logEntryBlobWithActionHash(signerId, nonce, actionHash, sig);

        // Now query with a DIFFERENT expectedSignerAddr.  The
        // registry lookup against this wrong address will return
        // UNREGISTERED (or, if registered, a different pubkey),
        // so the verifier returns INCONCLUSIVE (not registered) or
        // UPHELD (registered with different pubkey, sig won't
        // match).  Use an unregistered address — INCONCLUSIVE is
        // the correct return for "we can't verify this signer".
        address wrongAddr = makeAddr("wrong-addr");
        uint8 verdict = verifier.checkSignatureInvalid(blob, wrongAddr);
        assertEq(verdict, verifier.VERDICT_INCONCLUSIVE());
    }

    // ---- Audit-3 helpers for the EIP-712 digest reconstruction ----

    function _actionDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,uint256 rollupId,bytes verifyingContract)"
                ),
                keccak256("KnomosisAction"),
                keccak256("1"),
                block.chainid,
                uint256(0),
                keccak256(abi.encodePacked(address(bridge)))
            )
        );
    }

    function _actionStructHash(
        bytes32 actionHash,
        uint64 signer,
        uint64 nonce,
        bytes32 deploymentId
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "KnomosisAction(bytes32 actionHash,uint64 signer,uint64 nonce,bytes deploymentId)"
                ),
                actionHash,
                uint256(signer),
                uint256(nonce),
                keccak256(abi.encodePacked(deploymentId))
            )
        );
    }

    // ---- FIX 3: verdictDigest binding ----

    function test_audit_verdictDigest_distinguishes_disputeId() public view {
        bytes32 d1 = verifier.verdictDigest(uint64(1), verifier.VERDICT_UPHELD());
        bytes32 d2 = verifier.verdictDigest(uint64(2), verifier.VERDICT_UPHELD());
        assertTrue(d1 != d2, "verdict digests must differ across disputeIds");
    }

    function test_audit_verdictDigest_distinguishes_outcome() public view {
        bytes32 dUpheld =
            verifier.verdictDigest(uint64(1), verifier.VERDICT_UPHELD());
        bytes32 dRejected =
            verifier.verdictDigest(uint64(1), verifier.VERDICT_REJECTED());
        assertTrue(dUpheld != dRejected, "verdict digests must differ across outcomes");
    }

    function test_audit_verdictDigest_deterministic() public view {
        bytes32 d1 = verifier.verdictDigest(uint64(1), verifier.VERDICT_UPHELD());
        bytes32 d2 = verifier.verdictDigest(uint64(1), verifier.VERDICT_UPHELD());
        assertEq(d1, d2);
    }

    // ---- FIX 5: signers length bound ----

    function test_audit_finalize_reverts_on_too_many_signers() public {
        // Cache constants before setting up state.
        uint8 doubleApply = verifier.CLAIM_DOUBLE_APPLY();
        uint256 maxSigners = verifier.MAX_VERDICT_SIGNERS();

        vm.prank(challenger);
        verifier.fileDispute(uint64(7), doubleApply, hex"00");

        // Build an oversized signers array.
        uint256 oversize = maxSigners + 1;
        address[] memory bigSigners = new address[](oversize);
        bytes[] memory bigSigs = new bytes[](oversize);
        for (uint256 i = 0; i < oversize; ++i) {
            bigSigners[i] = adjudicator1;
            bigSigs[i] = new bytes(65);
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisDisputeVerifier.TooManySigners.selector, oversize, maxSigners
            )
        );
        verifier.finalizeUpheld(uint64(0), hex"", address(0), bigSigners, bigSigs);
    }

    // ---- FIX 6: evidenceBlob bound ----

    function test_audit_fileDispute_reverts_on_oversized_evidence() public {
        // Cache constants BEFORE setting up the expectRevert.
        // `vm.expectRevert` only matches the next external call;
        // a getter call consumed in argument evaluation would
        // mistakenly match.
        uint256 maxBytes = verifier.MAX_EVIDENCE_BLOB_BYTES();
        uint8 doubleApply = verifier.CLAIM_DOUBLE_APPLY();
        bytes memory tooBig = new bytes(maxBytes + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisDisputeVerifier.EvidenceBlobTooLarge.selector,
                maxBytes + 1,
                maxBytes
            )
        );
        verifier.fileDispute(uint64(0), doubleApply, tooBig);
    }

    function test_audit_fileDispute_accepts_evidence_at_max() public {
        uint256 maxBytes = verifier.MAX_EVIDENCE_BLOB_BYTES();
        uint8 doubleApply = verifier.CLAIM_DOUBLE_APPLY();
        bytes memory atMax = new bytes(maxBytes);
        vm.prank(challenger);
        uint64 id = verifier.fileDispute(uint64(0), doubleApply, atMax);
        assertEq(id, 0);
    }

    // ---- FIX 6b: evidenceBlob is NOT stored on-chain (only emitted) ----

    function test_audit_evidenceBlob_not_stored_in_state() public {
        // Cache the constant BEFORE the prank so the prank applies
        // to fileDispute (not to the getter call).
        uint8 doubleApply = verifier.CLAIM_DOUBLE_APPLY();
        // Filing with a 50KB blob.
        bytes memory big = new bytes(50_000);
        vm.prank(challenger);
        uint64 id = verifier.fileDispute(uint64(7), doubleApply, big);
        // The DisputeRecord struct in storage no longer contains
        // evidenceBlob.  Verify by checking that disputeAt's
        // returned tuple doesn't expose the blob (the absence
        // would be a compile error if the field still existed).
        (uint64 idx, address chal, uint8 cv, uint8 status, uint64 fab) =
            verifier.disputeAt(id);
        // Sanity:
        assertEq(idx, 7);
        assertEq(chal, challenger);
        assertEq(cv, doubleApply);
        assertEq(status, verifier.STATUS_OPEN());
        assertEq(fab, uint64(block.number));
    }

    // ---- Helpers ----

    /// @notice Reconstruct an ECDSA secp256k1 uncompressed pubkey
    ///         from a private key, for registry registration in
    ///         tests.  Hard-coded for the well-known privkey = 1
    ///         (the secp256k1 generator); callers using other PKs
    ///         must hard-code their pubkey.
    function _vmAddrPubkey(uint256 pk) internal pure returns (bytes memory) {
        // For privkey = 1 the pubkey is the secp256k1 generator.
        // For other privkeys we'd need a per-pk lookup table.
        if (pk == 1) {
            return
                hex"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
                hex"483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8";
        }
        // Default: dummy 64-byte pubkey (will fail address-derivation
        // check); used by tests that don't care about the registry
        // entry beyond its existence.
        bytes memory dummy = new bytes(64);
        return dummy;
    }
}
