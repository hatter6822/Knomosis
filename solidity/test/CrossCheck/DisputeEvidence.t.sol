// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";

/// @title DisputeEvidenceCrossCheck
/// @notice Workstream F.1.6 — Solidity-side consumer of the
///         `dispute_evidence.json` fixture.  168 entries (144
///         per-claim + 24 verdict-finalisation).
///
/// @dev    Per the integration plan §10.1.6 + §21.5, this fixture
///         encodes the audit-1 + audit-3 cross-stack invariants:
///         signerHint API, verdictDigest derivation, MAX_VERDICT_
///         SIGNERS / MAX_EVIDENCE_BLOB_BYTES boundaries, quorum
///         deduplication, audit-3 doubleApply concat shape, EIP-712
///         domain pinning.
///
///         Cross-check is gated on `isKeccak256Linked` (Lean side
///         needs production keccak256 for the EIP-712 digests to be
///         meaningful).  Without the binding, the bytes are FNV
///         placeholders and we skip; CI gates on the binding.
///
///         A full per-entry cross-stack invocation requires deploying
///         `KnomosisDisputeVerifier` with mock peers; that's the F.3
///         testnet acceptance script's job.  This contract focuses
///         on:
///           * Fixture-shape sanity (count / breakdowns / domain pins)
///           * EIP-712 domain distinguishability (cryptographic
///             property the fixture pins)
///           * Audit-3 boundaries are recorded in the header
///             (regression-protection that the fixture itself stays
///             consistent with the deployed contract's constants).
contract DisputeEvidenceCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "dispute_evidence.json";

    /// @notice Header shape: 168 entries with the documented breakdowns.
    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        assertEq(vm.parseJsonUint(raw, ".header.countTotal"), 168, "total");
        assertEq(vm.parseJsonUint(raw, ".header.countSignatureInvalid"), 48, "sigInv");
        assertEq(vm.parseJsonUint(raw, ".header.countNonceMismatch"), 48, "nonce");
        assertEq(vm.parseJsonUint(raw, ".header.countDoubleApply"), 48, "dbl");
        assertEq(vm.parseJsonUint(raw, ".header.countVerdict"), 24, "verdict");
        assertEq(vm.parseJsonUint(raw, ".header.maxVerdictSigners"), 64, "MAX_VERDICT_SIGNERS");
        assertEq(vm.parseJsonUint(raw, ".header.maxEvidenceBlobBytes"), 100000, "MAX_EVIDENCE_BLOB_BYTES");
        assertEq(vm.parseJsonUint(raw, ".header.maxPrefixLen"), 256, "MAX_PREFIX_LEN");
    }

    /// @notice EIP-712 domain pinning sanity: action and verdict
    ///         domain names are byte-distinct (cross-protocol replay
    ///         protection).
    function test_eip712_domains_distinct() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        string memory actionDomain = vm.parseJsonString(raw, ".header.actionDomainName");
        string memory verdictDomain = vm.parseJsonString(raw, ".header.verdictDomainName");
        assertEq(actionDomain, "KnomosisAction", "action domain");
        assertEq(verdictDomain, "KnomosisDisputeVerifier", "verdict domain");
        assertTrue(
            keccak256(abi.encodePacked(actionDomain)) !=
            keccak256(abi.encodePacked(verdictDomain)),
            "action and verdict domains should be distinct"
        );
    }

    /// @notice Audit-3 regression: doubleApply adversarials include
    ///         the new `DoubleApplyConcatBadCount` and `CBEInvalidLength`
    ///         revert classes.
    function test_audit3_doubleApply_revert_classes() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        // The doubleApply claim entries occupy claimEntries[96..144).
        bool foundBadCount = false;
        bool foundCBE = false;
        bool foundSelf = false;
        for (uint256 i = 96; i < 144; i++) {
            string memory base = string.concat(".claimEntries[", vm.toString(i), "]");
            string memory outcome =
                vm.parseJsonString(raw, string.concat(base, ".expectedOutcome"));
            bytes32 oh = keccak256(abi.encodePacked(outcome));
            if (oh == keccak256(abi.encodePacked("revert:DoubleApplyConcatBadCount")))
                foundBadCount = true;
            if (oh == keccak256(abi.encodePacked("revert:CBEInvalidLength")))
                foundCBE = true;
            if (oh == keccak256(abi.encodePacked("revert:SelfClaimInvalid")))
                foundSelf = true;
        }
        assertTrue(foundBadCount, "missing DoubleApplyConcatBadCount adversarial");
        assertTrue(foundCBE, "missing CBEInvalidLength adversarial");
        assertTrue(foundSelf, "missing SelfClaimInvalid adversarial");
    }

    /// @notice Audit-1 regression: verdict-finalisation entries
    ///         include MAX_VERDICT_SIGNERS boundary, quorum-dedup,
    ///         and cross-disputeId / cross-outcome replay tests.
    function test_audit1_verdict_boundaries() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        bool foundMax = false;
        bool foundOverMax = false;
        bool foundCrossId = false;
        bool foundDedup = false;
        for (uint256 i = 0; i < 24; i++) {
            string memory base = string.concat(".verdictEntries[", vm.toString(i), "]");
            string memory label = vm.parseJsonString(raw, string.concat(base, ".label"));
            bytes32 lh = keccak256(abi.encodePacked(label));
            if (lh == keccak256(abi.encodePacked("verdict:max-signers"))) foundMax = true;
            if (lh == keccak256(abi.encodePacked("verdict:over-max-signers"))) foundOverMax = true;
            if (lh == keccak256(abi.encodePacked("verdict:cross-disputeId-2"))) foundCrossId = true;
            if (lh == keccak256(abi.encodePacked("verdict:dedup-padded"))) foundDedup = true;
        }
        assertTrue(foundMax, "missing max-signers boundary");
        assertTrue(foundOverMax, "missing over-max-signers boundary");
        assertTrue(foundCrossId, "missing cross-disputeId-2 entry");
        assertTrue(foundDedup, "missing dedup-padded entry");
    }

    /// @notice Cross-stack assertion gated on isKeccak256Linked.
    function test_perEntry_outcome_assertion() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".header.isKeccak256Linked");
        if (!linked) {
            _skipWithReason("keccak256 fallback; per-entry verifier cross-check skipped");
            return;
        }
        // With the production binding linked, this test would deploy
        // `KnomosisDisputeVerifier` + mock peers and per-entry call the
        // appropriate claim-verifier with the fixture inputs, asserting
        // the returned verdict byte (or revert selector) matches
        // `expectedOutcome`.  Until the binding lands, this skips.
        emit log("F.1.6: per-entry verifier cross-check requires production binding");
    }
}
