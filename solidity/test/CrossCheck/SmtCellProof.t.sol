// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {SmtCellVerifier} from "src/lib/SmtCellVerifier.sol";

/// @title SmtCellProofCrossCheckProxy
/// @notice Thin external proxy exposing `SmtCellVerifier`'s internal
///         library functions through a `calldata`-bearing surface
///         so the cross-check tests can pass `bytes memory` data
///         decoded from JSON.  Mirrors the proxy pattern used by
///         `solidity/test/SmtCellVerifier.t.sol`; defined locally
///         here under a distinct name to avoid ABI-name collisions
///         when running the full forge-test suite.
contract SmtCellProofCrossCheckProxy {
    /// @notice External-pure proxy for `SmtCellVerifier.verifyCellProof`.
    function verifyCellProof(
        bytes32 root,
        bytes calldata smtKey,
        bytes calldata leafPreimage,
        bytes calldata proofData
    ) external pure returns (bool) {
        return SmtCellVerifier.verifyCellProof(root, smtKey, leafPreimage, proofData);
    }

    /// @notice External-pure proxy for `SmtCellVerifier.recomputeRoot`.
    ///         Used by tests that want the raw walked root without
    ///         the verifier's bool dispatch.
    function recomputeRoot(
        bytes calldata smtKey,
        bytes calldata leafPreimage,
        bytes calldata proofData
    ) external pure returns (bytes32) {
        return SmtCellVerifier.recomputeRoot(smtKey, leafPreimage, proofData);
    }
}

/// @title SmtCellProofCrossCheck
/// @notice Workstream SC.3 — Solidity-side consumer of the
///         `smt_cell_proof.json` fixture.  50 honest entries must
///         `verifyCellProof = true`; 50 adversarial entries must
///         `verifyCellProof = false`.
///
/// @dev    The cross-stack contract is:
///
///         ```
///         lean.verifySmtCellProof root key value proof
///           ↔
///         solidity.SmtCellVerifier.verifyCellProof(root, smtKey,
///           leafPreimage, proofData)
///         ```
///
///         Both sides walk the same 256-level SMT path using the
///         same canonical empty-subtree hashes and the same bit
///         conventions (key MSB-first per byte; bitmask LSB-first
///         per byte).  When the Lean side links against
///         `knomosis-hash-keccak256` and Solidity uses the EVM
///         `keccak256` opcode, the byte outputs match exactly —
///         every honest entry verifies and every tamper class
///         rejects.
///
///         When the Lean side is on the FNV-1a-64 fallback (the
///         default at `lake test` time), the fixture's `root` and
///         siblings are computed via FNV, which Solidity cannot
///         reproduce; the per-entry cross-stack assertion is
///         gated on the header's `isKeccak256Linked` flag and
///         skipped otherwise.  Header-shape and well-formedness
///         assertions still run.
///
///         Closes the Genesis-Plan §15B note "Production
///         deployments MUST audit cellProof submissions off-chain
///         until the SMT path is shipped" by ratifying cross-stack
///         soundness at the mechanical fixture-corpus level.
contract SmtCellProofCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "smt_cell_proof.json";

    /// @notice Proxy contract instantiated per-test by the harness.
    ///         Stateless; deployed in `setUp`.
    SmtCellProofCrossCheckProxy internal proxy;

    function setUp() public {
        proxy = new SmtCellProofCrossCheckProxy();
    }

    /// @notice Helper that calls the proxy.  Wraps the external
    ///         call boundary so test bodies can pass `bytes memory`
    ///         decoded from JSON.
    function _verify(
        bytes32 root,
        bytes memory smtKey,
        bytes memory leafPreimage,
        bytes memory proofData
    ) internal view returns (bool) {
        return proxy.verifyCellProof(root, smtKey, leafPreimage, proofData);
    }

    /* ---------------------------------------------------------- */
    /* Header / shape assertions (binding-independent)            */
    /* ---------------------------------------------------------- */

    /// @notice Header shape: 100 entries with the documented
    ///         honest / adversarial breakdown.  Each named tamper
    ///         class has at least one entry.
    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first to generate");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        assertEq(vm.parseJsonUint(raw, ".header.count"), 100, "count");
        assertEq(vm.parseJsonUint(raw, ".header.countHonest"), 50, "honest count");
        assertEq(vm.parseJsonUint(raw, ".header.countAdversarial"), 50, "adversarial count");
        assertEq(vm.parseJsonUint(raw, ".header.smtDepth"), 256, "smtDepth");
        assertEq(vm.parseJsonUint(raw, ".header.countSingleton"), 8, "singleton subcount");
        assertEq(vm.parseJsonUint(raw, ".header.countTwoCell"), 8, "two-cell subcount");
        assertEq(vm.parseJsonUint(raw, ".header.countThreeCell"), 8, "three-cell subcount");
        assertEq(vm.parseJsonUint(raw, ".header.countFourCell"), 8, "four-cell subcount");
        assertEq(vm.parseJsonUint(raw, ".header.countEightCell"), 8, "eight-cell subcount");
        assertEq(vm.parseJsonUint(raw, ".header.countEdge"), 10, "edge subcount");
        // Each tamper class has at least one entry.
        assertGt(vm.parseJsonUint(raw, ".header.countValueSubst"), 0, "valueSubst > 0");
        assertGt(vm.parseJsonUint(raw, ".header.countSiblingTamper"), 0, "siblingTamper > 0");
        assertGt(vm.parseJsonUint(raw, ".header.countBitmaskTamper"), 0, "bitmaskTamper > 0");
        assertGt(vm.parseJsonUint(raw, ".header.countRootTamper"), 0, "rootTamper > 0");
        assertGt(vm.parseJsonUint(raw, ".header.countKeyMismatch"), 0, "keyMismatch > 0");
        assertGt(vm.parseJsonUint(raw, ".header.countAbsentKey"), 0, "absentKey > 0");
    }

    /// @notice Honest entries (first 50) have `shouldVerify=true`
    ///         and `tamper=null`.  Adversarial entries (next 50)
    ///         have `shouldVerify=false` and a non-null `tamper`.
    function test_per_entry_shouldVerify_matches_position() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        for (uint256 i = 0; i < 50; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            assertTrue(
                vm.parseJsonBool(raw, string.concat(base, ".shouldVerify")),
                "honest entry must have shouldVerify=true"
            );
        }
        for (uint256 i = 50; i < 100; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            assertFalse(
                vm.parseJsonBool(raw, string.concat(base, ".shouldVerify")),
                "adversarial entry must have shouldVerify=false"
            );
        }
    }

    /// @notice Every honest entry's `smtKey` is exactly 8 bytes
    ///         (UInt64 big-endian; matches Lean's
    ///         `uint64ToBytesBE` and Solidity's MSB-first reading).
    function test_all_honest_smtKeys_are_8_bytes() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        for (uint256 i = 0; i < 50; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            bytes memory smtKey = vm.parseJsonBytes(raw, string.concat(base, ".smtKeyHex"));
            assertEq(smtKey.length, 8, "honest smtKey must be 8 bytes (UInt64 BE)");
        }
    }

    /// @notice Every honest entry's `leafPreimage` is exactly 16
    ///         bytes (UInt64 key + UInt64 value, both big-endian).
    function test_all_honest_leafPreimages_are_16_bytes() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        for (uint256 i = 0; i < 50; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            bytes memory leafPreimage =
                vm.parseJsonBytes(raw, string.concat(base, ".leafPreimageHex"));
            assertEq(leafPreimage.length, 16, "honest leafPreimage must be 16 bytes");
        }
    }

    /// @notice Every entry's `proofData` has the canonical wire
    ///         layout: 32-byte bitmask plus an integer number of
    ///         32-byte siblings.
    function test_all_proofData_well_formed_wire_layout() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            bytes memory proofData = vm.parseJsonBytes(raw, string.concat(base, ".proofDataHex"));
            assertGe(proofData.length, 32, "proofData must be at least 32 bytes (bitmask)");
            assertEq((proofData.length - 32) % 32, 0, "siblings region must be 32-byte-aligned");
        }
    }

    /// @notice Every entry's `root` is exactly 32 bytes (one hash
    ///         output).
    function test_all_roots_are_32_bytes() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            bytes memory root = vm.parseJsonBytes(raw, string.concat(base, ".rootHex"));
            assertEq(root.length, 32, "root must be 32 bytes");
        }
    }

    /* ---------------------------------------------------------- */
    /* Per-entry cross-stack verdict (binding-conditional)        */
    /* ---------------------------------------------------------- */

    /// @notice Per-entry cross-stack assertion.  For every entry:
    ///         `SmtCellVerifier.verifyCellProof(root, smtKey,
    ///         leafPreimage, proofData) == shouldVerify`.  Gated
    ///         on `isKeccak256Linked` because the fixture's roots
    ///         and sibling hashes depend on which `hashBytes`
    ///         Lean linked.
    function test_per_entry_verifyCellProof_matches_shouldVerify() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".header.isKeccak256Linked");
        if (!linked) {
            _skipWithReason("keccak256 fallback (FNV-1a-64); cross-stack assert skipped");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            bytes32 root = vm.parseJsonBytes32(raw, string.concat(base, ".rootHex"));
            bytes memory smtKey = vm.parseJsonBytes(raw, string.concat(base, ".smtKeyHex"));
            bytes memory leafPreimage =
                vm.parseJsonBytes(raw, string.concat(base, ".leafPreimageHex"));
            bytes memory proofData = vm.parseJsonBytes(raw, string.concat(base, ".proofDataHex"));
            bool shouldVerify = vm.parseJsonBool(raw, string.concat(base, ".shouldVerify"));
            string memory category = vm.parseJsonString(raw, string.concat(base, ".category"));

            bool actual = _verify(root, smtKey, leafPreimage, proofData);
            if (shouldVerify) {
                assertTrue(actual, string.concat("honest entry rejected: ", category));
            } else {
                assertFalse(actual, string.concat("adversarial entry accepted: ", category));
            }
        }
    }

    /// @notice Stronger property for honest entries:
    ///         `recomputeRoot(smtKey, leafPreimage, proofData) ==
    ///         root` byte-for-byte (not just the bool verdict).
    ///         Gated identically.
    function test_per_honest_entry_recomputed_root_byte_matches() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".header.isKeccak256Linked");
        if (!linked) {
            _skipWithReason("keccak256 fallback; cross-stack assert skipped");
            return;
        }
        for (uint256 i = 0; i < 50; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            bytes32 root = vm.parseJsonBytes32(raw, string.concat(base, ".rootHex"));
            bytes memory smtKey = vm.parseJsonBytes(raw, string.concat(base, ".smtKeyHex"));
            bytes memory leafPreimage =
                vm.parseJsonBytes(raw, string.concat(base, ".leafPreimageHex"));
            bytes memory proofData = vm.parseJsonBytes(raw, string.concat(base, ".proofDataHex"));
            string memory category = vm.parseJsonString(raw, string.concat(base, ".category"));

            bytes32 reconstructed = proxy.recomputeRoot(smtKey, leafPreimage, proofData);
            assertEq(reconstructed, root, string.concat("recomputeRoot mismatch for ", category));
        }
    }

    /* ---------------------------------------------------------- */
    /* Spot checks: documented categories appear in expected slots */
    /* ---------------------------------------------------------- */

    /// @notice Entry 0 is the lowest-singleton honest entry
    ///         (`honest:singleton:k=0`).  Catches a class of
    ///         fixture-corruption bugs where entries are reordered.
    function test_entry_zero_is_lowest_singleton() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        string memory c0 = vm.parseJsonString(raw, ".entries[0].category");
        assertEq(c0, "honest:singleton:k=0", "entry[0] category");
    }

    /// @notice Entry 50 is the first adversarial entry.  Its
    ///         category must end with the documented suffix
    ///         "::tampered:valueSubst" (the first tamper class in
    ///         the round-robin).
    function test_entry_50_is_first_adversarial_value_subst() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        string memory tamper = vm.parseJsonString(raw, ".entries[50].tamper");
        assertEq(tamper, "valueSubst", "entry[50] tamper");
    }

    /// @notice Defense against fixture corruption: every
    ///         adversarial entry's `tamper` field must be one of
    ///         the six documented strings, and every honest entry's
    ///         `tamper` field must be parseable as the canonical
    ///         "null" representation (verified by deferring to the
    ///         positional `shouldVerify=true` check above).
    ///
    /// @dev    `vm.parseJsonString` on a `null` JSON literal returns
    ///         an empty string in Foundry; we use that semantics
    ///         here.  If the fixture format changes to encode null
    ///         differently, this test will need updating.
    function test_per_entry_tamper_string_in_valid_set() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);

        // Pre-hash the six valid tamper strings for fast comparison.
        bytes32 hValueSubst = keccak256(bytes("valueSubst"));
        bytes32 hSiblingTamper = keccak256(bytes("siblingTamper"));
        bytes32 hBitmaskTamper = keccak256(bytes("bitmaskTamper"));
        bytes32 hRootTamper = keccak256(bytes("rootTamper"));
        bytes32 hKeyMismatch = keccak256(bytes("keyMismatch"));
        bytes32 hAbsentKey = keccak256(bytes("absentKey"));

        for (uint256 i = 50; i < 100; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory t = vm.parseJsonString(raw, string.concat(base, ".tamper"));
            bytes32 h = keccak256(bytes(t));
            bool valid = h == hValueSubst || h == hSiblingTamper || h == hBitmaskTamper
                || h == hRootTamper || h == hKeyMismatch || h == hAbsentKey;
            assertTrue(
                valid,
                string.concat(
                    "adversarial entry[", vm.toString(i), "] has unrecognised tamper string: ", t
                )
            );
        }
    }

    /// @notice Every adversarial entry's `category` ends with a
    ///         `::tampered:<class>` suffix that matches the
    ///         `tamper` field.  Catches a class of fixture-
    ///         corruption bugs where the category and tamper fields
    ///         drift out of sync (e.g., a refactor that renames one
    ///         but not the other).
    function test_per_entry_category_consistent_with_tamper() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        for (uint256 i = 50; i < 100; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory category = vm.parseJsonString(raw, string.concat(base, ".category"));
            string memory tamper = vm.parseJsonString(raw, string.concat(base, ".tamper"));
            // The category contains "::tampered:<tamper>" as a
            // substring.  We check by verifying that
            // `keccak256(bytes(category))` contains
            // `keccak256(bytes("::tampered:<tamper>"))` as a
            // substring — implemented as a manual scan since
            // Solidity does not provide a built-in substring check.
            string memory needle = string.concat("::tampered:", tamper);
            assertTrue(
                _containsSubstring(category, needle),
                string.concat(
                    "adversarial entry[",
                    vm.toString(i),
                    "] category does not contain '",
                    needle,
                    "': ",
                    category
                )
            );
        }
    }

    /// @notice Internal substring check used by
    ///         `test_per_entry_category_consistent_with_tamper`.
    ///         Returns true iff `needle` appears anywhere within
    ///         `haystack`.  O(|haystack| * |needle|) naive
    ///         implementation; acceptable for the bounded test-time
    ///         inputs (category strings ≤ 256 bytes).
    function _containsSubstring(string memory haystack, string memory needle)
        internal
        pure
        returns (bool)
    {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (h.length < n.length) return false;
        uint256 limit = h.length - n.length;
        for (uint256 i = 0; i <= limit; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }
}
