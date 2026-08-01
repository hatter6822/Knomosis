// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title CrossCheckFramework
/// @notice Workstream F.1.1 — shared infrastructure for the
///         Lean ↔ Solidity cross-stack equivalence corpus.
///
/// @dev    Provides path resolution and fixture loading helpers that
///         every F.1.x cross-check suite uses.  The `vm.parseJson`
///         family decodes a fixture file into per-entry typed
///         structs; this base contract keeps the per-suite test
///         classes thin.
abstract contract CrossCheckFramework is Test {
    /// @notice Repo-relative path under which all fixture JSON files
    ///         live.  Mirrors `LegalKernel.Test.Bridge.CrossCheck.fixturesDir`
    ///         in `LegalKernel/Test/Bridge/CrossCheck/Framework.lean`.
    string internal constant FIXTURES_DIR = "test/CrossCheck/fixtures";

    /// @notice Resolve a fixture's full path under the repo root.
    function fixturePath(string memory name) internal pure returns (string memory) {
        return string(abi.encodePacked(FIXTURES_DIR, "/", name));
    }

    /// @notice Return `true` if the fixture file exists, `false`
    ///         otherwise.  Workstream F deliverables intentionally
    ///         skip (rather than fail) when a fixture is missing —
    ///         the Lean-side generator's first run produces it, and
    ///         CI gates on the production hash binding being linked.
    function fixtureExists(string memory name) internal view returns (bool) {
        try vm.readFile(fixturePath(name)) returns (string memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Read a fixture file's raw JSON content.
    function readFixture(string memory name) internal view returns (string memory) {
        return vm.readFile(fixturePath(name));
    }

    /// @notice Skip the test with a logged reason.  Mirrors the Lean
    ///         side's `skipWithReason` helper.  Implemented as
    ///         `vm.skip(true)` for proper forge-test "skipped" status.
    function _skipWithReason(string memory reason) internal {
        emit log_named_string("SKIPPED", reason);
        vm.skip(true);
    }

    /// @notice Assert a fixture was generated with the production
    ///         keccak256 binding linked.
    ///
    /// @dev    Every hash-dependent corpus exists to pin Lean's bytes
    ///         against the EVM's, which is only meaningful when both
    ///         compute the same hash.  These suites used to SKIP when
    ///         the flag was false, and the committed corpora carried
    ///         `false` — so a bare `forge test` reported green having
    ///         compared nothing.  That is coverage which is not
    ///         coverage, and it is exactly how the fault-proof
    ///         commit-recipe split survived a passing suite.
    ///
    ///         The corpora are now keccak artifacts by construction:
    ///         `writeHashDependentFixture` in
    ///         `LegalKernel/Test/Bridge/CrossCheck/Framework.lean`
    ///         refuses to author one on a fallback-hash build.  This
    ///         assertion is the consuming half of that invariant —
    ///         a fallback corpus must fail loudly here rather than
    ///         silently disable its own suite.
    ///
    /// @param raw      the fixture's raw JSON.
    /// @param jsonPath the flag's path, e.g. `".header.isKeccak256Linked"`.
    function _requireKeccakLinked(string memory raw, string memory jsonPath) internal pure {
        require(
            vm.parseJsonBool(raw, jsonPath),
            "cross-stack fixture was generated on a fallback-hash build; "
            "regenerate via ./scripts/verify_keccak_crossstack.sh"
        );
    }

    /// @notice Assert a fixture carries the schema identifier the
    ///         consuming suite was written against.
    ///
    /// @dev    A fixture's `identifier` is a schema version, and it is
    ///         the only thing that distinguishes a stale corpus from a
    ///         current one.  Entry counts, key layouts and cell-tag
    ///         indices all change without the JSON becoming
    ///         unparseable, so a suite reading a superseded corpus
    ///         compares real values and passes — against the wrong
    ///         contract.  Bumping the Lean-side identifier can only
    ///         fail the consuming suite if the suite reads it, so the
    ///         field is wired here rather than merely emitted.
    ///
    /// @param raw      the fixture's raw JSON.
    /// @param jsonPath the field's path — the corpora disagree on
    ///                 whether it sits at the root or under `.header`,
    ///                 so it is named by the caller rather than
    ///                 guessed.
    /// @param expected the identifier this suite pins.
    function _requireIdentifier(
        string memory raw,
        string memory jsonPath,
        string memory expected
    ) internal pure {
        require(
            keccak256(bytes(vm.parseJsonString(raw, jsonPath)))
                == keccak256(bytes(expected)),
            "cross-stack fixture schema identifier mismatch; the Lean-side "
            "corpus was bumped, so regenerate the fixture and update the suite"
        );
    }

    /// @notice Convert a hex-string (`"0x..."`) to its raw bytes.
    ///         Wraps `vm.parseBytes`.
    function hexToBytes(string memory hexStr) internal pure returns (bytes memory) {
        return vm.parseBytes(hexStr);
    }
}

/// @title FrameworkSmokeTest
/// @notice Workstream F.1.1 acceptance: empty-fixture round-trip.
///         Verifies the framework parses an empty array fixture
///         without error.
contract FrameworkSmokeTest is CrossCheckFramework {
    /// @notice Confirms the JSON parser accepts an empty array
    ///         without reverting.  `vm.parseJson` returns the raw
    ///         ABI-encoded representation of the parsed value (an
    ///         empty dynamic-bytes encoding, 64 bytes: offset 0x20 +
    ///         length 0x00).  We assert "no revert" rather than a
    ///         specific length here, since the encoding shape is a
    ///         Foundry implementation detail.
    function test_emptyArrayFixtureParses() public pure {
        // Inline JSON; not a file.  Successful parse = no revert.
        vm.parseJson("[]");
    }

    /// @notice Confirms `fixturePath` produces the expected joined path.
    function test_fixturePathFormat() public pure {
        string memory p = string(abi.encodePacked(FIXTURES_DIR, "/", "smoke.json"));
        assertEq(
            keccak256(abi.encodePacked(p)),
            keccak256(abi.encodePacked("test/CrossCheck/fixtures/smoke.json")),
            "joined path mismatch"
        );
    }

    /// @notice Confirms `fixtureExists` returns false for an absent
    ///         fixture.
    function test_fixtureExistsFalseOnAbsent() public view {
        assertFalse(fixtureExists("does_not_exist_qwerty.json"), "absent fixture detected");
    }

    /// @notice Confirms `hexToBytes` round-trips a small hex literal.
    function test_hexToBytesDecodesLiteral() public pure {
        bytes memory b = hexToBytes("0xdeadbeef");
        assertEq(b.length, 4, "expected 4 bytes");
        assertEq(uint8(b[0]), 0xde, "byte 0");
        assertEq(uint8(b[1]), 0xad, "byte 1");
        assertEq(uint8(b[2]), 0xbe, "byte 2");
        assertEq(uint8(b[3]), 0xef, "byte 3");
    }

    /// External wrappers so the two fail-loudly gates can be driven
    /// through `vm.expectRevert`, which needs a real call frame.
    function callRequireKeccakLinked(string memory raw, string memory path) public pure {
        _requireKeccakLinked(raw, path);
    }

    /// See `callRequireKeccakLinked`.
    function callRequireIdentifier(
        string memory raw,
        string memory jsonPath,
        string memory expected
    ) public pure {
        _requireIdentifier(raw, jsonPath, expected);
    }

    /// @notice Self-test: the keccak gate passes on a linked fixture
    ///         and REVERTS on a fallback one.  A gate that is never
    ///         observed to fire is indistinguishable from an absent
    ///         gate, which is the failure mode it exists to prevent.
    function test_requireKeccakLinkedFiresOnFallback() public {
        this.callRequireKeccakLinked('{"isKeccak256Linked":true}', ".isKeccak256Linked");
        vm.expectRevert();
        this.callRequireKeccakLinked('{"isKeccak256Linked":false}', ".isKeccak256Linked");
    }

    /// @notice Self-test: the identifier gate passes on a match and
    ///         REVERTS on a stale schema version.
    function test_requireIdentifierFiresOnMismatch() public {
        this.callRequireIdentifier(
            '{"identifier":"knomosis/x/v2"}', ".identifier", "knomosis/x/v2"
        );
        vm.expectRevert();
        this.callRequireIdentifier(
            '{"identifier":"knomosis/x/v1"}', ".identifier", "knomosis/x/v2"
        );
    }

    /// @notice Self-test: the identifier gate reads the path it is
    ///         given.  The corpora put the field in two places, so a
    ///         gate hardwired to the root would pass vacuously on
    ///         half of them — it would revert on the parse, which
    ///         reads as a failure, but a `try`-guarded caller would
    ///         see no difference between "absent" and "matching".
    function test_requireIdentifierReadsNestedPath() public {
        this.callRequireIdentifier(
            '{"header":{"identifier":"knomosis/y/v3"}}',
            ".header.identifier",
            "knomosis/y/v3"
        );
        vm.expectRevert();
        this.callRequireIdentifier(
            '{"header":{"identifier":"knomosis/y/v3"}}',
            ".header.identifier",
            "knomosis/y/v4"
        );
    }
}
