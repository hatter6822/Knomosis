// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title EcdsaVerifyCrossCheck
/// @notice Workstream F.1.2 — Solidity-side consumer of the
///         `ecdsa_verify.json` fixture.  Loads each entry, calls
///         `OZ.ECDSA.tryRecover`, and asserts the outcome matches
///         the per-entry `outcome` marker.
///
/// @dev    `outcome` cases:
///           * "verifies"     ⇒ recovered == expectedSigner
///           * "wrongSigner"  ⇒ recovered != expectedSigner
///           * "highS"        ⇒ tryRecover returns InvalidSignatureS
///           * "malformed"    ⇒ sig.length != 65
///
///         When the Lean keccak256 binding is NOT linked, the
///         fixture's `digest` and `sig` bytes are FNV-derived
///         placeholders.  In that mode the contract test logs a
///         skip and exits without assertion.  CI gates on the
///         binding being linked (header.isKeccak256Linked == true)
///         before counting the suite as "passing".
contract EcdsaVerifyCrossCheck is CrossCheckFramework {
    using ECDSA for bytes32;

    string internal constant FIXTURE_NAME = "ecdsa_verify.json";

    /// @notice Test that the fixture file exists and its header
    ///         records the expected per-outcome counts.
    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            // Fixture missing → Lean side hasn't run yet.  The
            // forge job is run after `lake test` in CI; if this
            // fires, the orchestration is broken.
            revert("fixture missing; run `lake test` first to generate");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 cnt          = vm.parseJsonUint(raw, ".header.count");
        uint256 cntVerifies  = vm.parseJsonUint(raw, ".header.countVerifies");
        uint256 cntWrong     = vm.parseJsonUint(raw, ".header.countWrongSigner");
        uint256 cntHighS     = vm.parseJsonUint(raw, ".header.countHighS");
        uint256 cntMalformed = vm.parseJsonUint(raw, ".header.countMalformed");
        assertEq(cnt, 20, "fixture entry count");
        assertEq(cntVerifies, 8, "verifies count");
        assertEq(cntWrong, 4, "wrongSigner count");
        assertEq(cntHighS, 4, "highS count");
        assertEq(cntMalformed, 4, "malformed count");
    }

    /// @notice Cross-stack recovery check over the corpus.  The fixture's
    ///         `(digest, sig, expectedSigner)` are REAL precomputed
    ///         secp256k1 vectors (hash-independent), so this runs
    ///         UNCONDITIONALLY — it is no longer gated on
    ///         `isKeccak256Linked`.  (Previously the fixture held random
    ///         bytes and this assertion was skipped under the FNV
    ///         fallback, so the recovery branches were never actually
    ///         exercised.)
    function test_perEntry_outcome_matches() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            // Use vm.parseJsonAddress for the documented address-typed
            // field — the audit-pass replaces a less idiomatic
            // `abi.decode(vm.parseJson(...), (address))` form that
            // could surface as a latent decode bug when the
            // production binding lands.
            address expectedSigner =
                vm.parseJsonAddress(raw, string.concat(base, ".expectedSigner"));
            bytes32 digest =
                vm.parseJsonBytes32(raw, string.concat(base, ".digest"));
            bytes memory sig =
                vm.parseJsonBytes(raw, string.concat(base, ".sig"));
            string memory outcome =
                vm.parseJsonString(raw, string.concat(base, ".outcome"));

            bytes32 outcomeHash = keccak256(abi.encodePacked(outcome));

            // Malformed: length check is the contract's first short-circuit.
            if (outcomeHash == keccak256(abi.encodePacked("malformed"))) {
                assertTrue(sig.length != 65, "malformed sig length should be != 65");
                continue;
            }

            // High-s: ECDSA.tryRecover returns the InvalidSignatureS error.
            if (outcomeHash == keccak256(abi.encodePacked("highS"))) {
                (address rec, ECDSA.RecoverError err, ) = digest.tryRecover(sig);
                assertTrue(
                    err == ECDSA.RecoverError.InvalidSignatureS || rec == address(0),
                    "highS sig should be flagged"
                );
                continue;
            }

            // Verifies + wrongSigner share the same recovery code path.
            (address recovered, , ) = digest.tryRecover(sig);
            if (outcomeHash == keccak256(abi.encodePacked("verifies"))) {
                assertEq(recovered, expectedSigner, "verifies: recovered should match");
            } else if (outcomeHash == keccak256(abi.encodePacked("wrongSigner"))) {
                assertTrue(recovered != expectedSigner, "wrongSigner: should not match");
            }
        }
    }

    /// @notice Sanity check: outcome strings are byte-distinct.
    function test_outcome_strings_distinct() public pure {
        bytes32 a = keccak256(abi.encodePacked("verifies"));
        bytes32 b = keccak256(abi.encodePacked("wrongSigner"));
        bytes32 c = keccak256(abi.encodePacked("highS"));
        bytes32 d = keccak256(abi.encodePacked("malformed"));
        assertTrue(a != b && a != c && a != d, "verifies distinct");
        assertTrue(b != c && b != d, "wrongSigner distinct");
        assertTrue(c != d, "highS distinct");
    }
}
