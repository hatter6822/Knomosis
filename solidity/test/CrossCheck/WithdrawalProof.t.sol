// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";

/// @title WithdrawalProofCrossCheck
/// @notice Workstream F.1.5 — Solidity-side consumer of the
///         `withdrawal_proof.json` fixture.  64 valid entries
///         must `verifyProof = true`; 32 tampered must
///         `verifyProof = false`.
///
/// @dev    Variable-size leaf and siblings (audit-2 cross-stack
///         format).  Per `solidity/src/lib/SmtVerifier.sol`, the
///         verifier accepts `bytes leaf` and `bytes[] siblings`,
///         each variable-size, so dense-pair entries (where the
///         leaf-adjacent sibling is the *other* leaf's bytes
///         ≈ 56 bytes, not a 32-byte default-hash) work natively.
contract WithdrawalProofCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "withdrawal_proof.json";

    /// @notice Helper proxy to call the internal SmtVerifier
    ///         library function from a non-internal context.
    function _verify(uint256 idx, bytes memory leaf, bytes[] memory siblings, bytes32 root)
        internal
        pure
        returns (bool)
    {
        return SmtVerifier.verifyProof(idx, leaf, siblings, root);
    }

    /// @notice Header shape: 96 entries with the documented breakdown.
    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        assertEq(vm.parseJsonUint(raw, ".header.count"), 96, "count");
        assertEq(vm.parseJsonUint(raw, ".header.countValid"), 64, "valid count");
        assertEq(vm.parseJsonUint(raw, ".header.countSparse"), 16, "sparse");
        assertEq(vm.parseJsonUint(raw, ".header.countDensePair"), 16, "dense-pair");
        assertEq(vm.parseJsonUint(raw, ".header.countUnmapped"), 16, "unmapped");
        assertEq(vm.parseJsonUint(raw, ".header.countTampered"), 32, "tampered");
        assertEq(vm.parseJsonUint(raw, ".header.smtHeight"), 64, "smtHeight");
    }

    /// @notice Per-entry cross-stack verification.  Skipped if the
    ///         keccak256 binding is not linked (Lean side computed
    ///         the root via FNV; Solidity uses keccak256).
    function test_perEntry_verifyProof() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".header.isKeccak256Linked");
        if (!linked) {
            _skipWithReason("keccak256 fallback; cross-check skipped");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            bytes32 stateRoot =
                vm.parseJsonBytes32(raw, string.concat(base, ".stateRootHex"));
            uint256 idx =
                vm.parseJsonUint(raw, string.concat(base, ".proof.index"));
            bytes memory leaf =
                vm.parseJsonBytes(raw, string.concat(base, ".proof.leafHex"));
            bytes[] memory siblings =
                vm.parseJsonBytesArray(raw, string.concat(base, ".proof.siblingsHex"));
            bool shouldVerify = vm.parseJsonBool(raw, string.concat(base, ".shouldVerify"));

            bool actual = _verify(idx, leaf, siblings, stateRoot);
            if (shouldVerify) {
                assertTrue(actual, "valid entry failed to verify");
            } else {
                assertFalse(actual, "tampered entry unexpectedly verified");
            }
        }
    }

    /// @notice Sanity check: all proof.siblings arrays have length
    ///         64 (the SMT_HEIGHT).  Catches a class of
    ///         fixture-corruption bugs.
    function test_all_proofs_have_64_siblings() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            bytes[] memory siblings =
                vm.parseJsonBytesArray(raw, string.concat(base, ".proof.siblingsHex"));
            assertEq(siblings.length, 64, "siblings array length");
        }
    }
}
