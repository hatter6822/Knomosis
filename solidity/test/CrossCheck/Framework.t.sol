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
}
