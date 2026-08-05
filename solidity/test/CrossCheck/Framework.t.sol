// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.36;

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

    /* ------------------------------------------------------------ */
    /* Corpus walks: report EVERY failing entry, not the first       */
    /* ------------------------------------------------------------ */

    /// @dev These suites replay whole corpora in a single test body,
    ///      so a per-entry `assertEq` makes the FIRST bad entry the
    ///      only one anybody sees.  That is not a cosmetic problem:
    ///      when the CBE amount head widened to 32 bytes and three
    ///      `StepPlan` offsets were left behind, the walk named one
    ///      probe and stopped, so a defect affecting every
    ///      grant-bearing variant read as one variant's.  Establishing
    ///      the true extent took hand-run mutations against a corpus
    ///      the suite was already holding.
    ///
    ///      `check*` is `assert*` that records and keeps walking:
    ///      forge-std's `fail()` sets the failure flag without
    ///      reverting, forge reports the test as failed once the body
    ///      returns, and every `log_named_string` emitted on the way
    ///      is printed.  A walk therefore names all of its bad
    ///      entries in one run.
    ///
    ///      Two consequences worth knowing.  A test using these cannot
    ///      be `view` or `pure`, because `fail()` writes.  And a
    ///      REVERT inside the loop still ends it — soft assertions do
    ///      not help there — which is what `tryStatic` and
    ///      `describeRevert` below are for.

    /// @dev The corpus entry the following checks belong to.  Held
    ///      here rather than threaded through every call so converting
    ///      a walk costs one `beginEntry` line, not an edit at each
    ///      assertion.
    string private _entryLabel;

    /// @notice Name the corpus entry that subsequent `check*` calls
    ///         are about.  Call once per loop iteration.
    function beginEntry(string memory label) internal {
        _entryLabel = label;
    }

    /// @notice Record a failure against the current entry and keep
    ///         walking.
    function recordFailure(string memory what) internal {
        emit log_named_string(
            "entry",
            bytes(_entryLabel).length == 0
                ? what
                : string.concat(_entryLabel, ": ", what)
        );
        fail();
    }

    /// @notice `assertTrue`, recorded rather than raised.
    function checkTrue(bool ok, string memory what) internal {
        if (!ok) recordFailure(what);
    }

    /// @notice `assertFalse`, recorded rather than raised.
    function checkFalse(bool bad, string memory what) internal {
        if (bad) recordFailure(what);
    }

    /// @notice `assertEq` over `bytes32`, recorded rather than raised.
    function checkEq(bytes32 got, bytes32 want, string memory what) internal {
        if (got == want) return;
        recordFailure(
            string.concat(what, ": got ", vm.toString(got), ", want ", vm.toString(want))
        );
    }

    /// @notice `assertEq` over `uint256`, recorded rather than raised.
    function checkEq(uint256 got, uint256 want, string memory what) internal {
        if (got == want) return;
        recordFailure(
            string.concat(what, ": got ", vm.toString(got), ", want ", vm.toString(want))
        );
    }

    /// @notice `assertEq` over `bool`, recorded rather than raised.
    function checkEq(bool got, bool want, string memory what) internal {
        if (got == want) return;
        recordFailure(
            string.concat(what, ": got ", vm.toString(got), ", want ", vm.toString(want))
        );
    }

    /// @notice `assertEq` over `address`, recorded rather than raised.
    function checkEq(address got, address want, string memory what) internal {
        if (got == want) return;
        recordFailure(
            string.concat(what, ": got ", vm.toString(got), ", want ", vm.toString(want))
        );
    }

    /// @notice `assertEq` over `bytes`, recorded rather than raised.
    function checkEq(bytes memory got, bytes memory want, string memory what)
        internal
    {
        if (keccak256(got) == keccak256(want)) return;
        recordFailure(
            string.concat(what, ": got ", vm.toString(got), ", want ", vm.toString(want))
        );
    }

    /// @notice `assertEq` over `string`, recorded rather than raised.
    function checkEq(string memory got, string memory want, string memory what)
        internal
    {
        if (keccak256(bytes(got)) == keccak256(bytes(want))) return;
        recordFailure(string.concat(what, ": got '", got, "', want '", want, "'"));
    }

    /// @notice `assertLe`, recorded rather than raised.
    function checkLe(uint256 got, uint256 bound, string memory what) internal {
        if (got <= bound) return;
        recordFailure(
            string.concat(what, ": ", vm.toString(got), " exceeds ", vm.toString(bound))
        );
    }

    /// @notice `assertLt`, recorded rather than raised.
    function checkLt(uint256 got, uint256 bound, string memory what) internal {
        if (got < bound) return;
        recordFailure(
            string.concat(
                what, ": ", vm.toString(got), " is not below ", vm.toString(bound))
        );
    }

    /// @notice `assertGe`, recorded rather than raised.
    function checkGe(uint256 got, uint256 bound, string memory what) internal {
        if (got >= bound) return;
        recordFailure(
            string.concat(what, ": ", vm.toString(got), " is under ", vm.toString(bound))
        );
    }

    /// @notice `assertGt`, recorded rather than raised.
    function checkGt(uint256 got, uint256 bound, string memory what) internal {
        if (got > bound) return;
        recordFailure(
            string.concat(
                what, ": ", vm.toString(got), " does not exceed ", vm.toString(bound))
        );
    }

    /* ------------------------------------------------------------ */
    /* Revert tolerance                                              */
    /* ------------------------------------------------------------ */

    /// @notice Call `target` with `data`, returning the failure
    ///         instead of raising it.
    ///
    /// @dev    The half soft assertions cannot cover.  A value
    ///         mismatch at least names its entry; a revert escaping a
    ///         corpus walk named none at all — the case that started
    ///         this reported `FrontierMissingCell(2)`, a cell index
    ///         inside an unidentified probe, with the rest of the
    ///         corpus unexamined.
    function tryStatic(address target, bytes memory data)
        internal
        view
        returns (bool ok, bytes memory ret)
    {
        (ok, ret) = target.staticcall(data);
    }

    /// @notice Record a reverting corpus entry.  Returns `ok` so a
    ///         walk reads `if (!checkNoRevert(...)) continue;`.
    function checkNoRevert(bool ok, bytes memory err, string memory what)
        internal
        returns (bool)
    {
        if (!ok) recordFailure(string.concat(what, ": reverted ", describeRevert(err)));
        return ok;
    }

    /// @notice Render revert data as a name where one is known.
    ///
    /// @dev    Handles the two the compiler emits plus the empty
    ///         revert; a suite with its own custom errors overrides
    ///         this and falls back to `super` for the rest.  Every
    ///         selector an override matches is written
    ///         `Contract.Error.selector`, so RENAMING or REMOVING an
    ///         error is a compile error rather than silent drift, and
    ///         a suite that overrides is expected to carry the
    ///         completeness test that catches the remaining case — an
    ///         error ADDED and not described, which degrades to hex.
    function describeRevert(bytes memory err)
        internal
        pure
        virtual
        returns (string memory)
    {
        if (err.length == 0) return "(empty revert)";
        // Below four bytes there is no selector to read, and `_body`
        // would underflow.  A reporter that panicked on malformed
        // revert data would destroy the diagnosis it exists to give.
        if (err.length < 4) return vm.toString(err);
        bytes4 sel = revertSelector(err);
        if (sel == bytes4(keccak256("Error(string)"))) {
            return string.concat("Error('", abi.decode(_body(err), (string)), "')");
        }
        if (sel == bytes4(keccak256("Panic(uint256)"))) {
            uint256 code = abi.decode(_body(err), (uint256));
            return string.concat("Panic(", _panicName(code), ")");
        }
        return vm.toString(err);
    }

    /// @dev The leading four bytes of revert data.  Spelled out rather
    ///      than `bytes4(err)` so the read is explicitly bounded.
    function revertSelector(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0);
        sel = bytes4(bytes.concat(err[0], err[1], err[2], err[3]));
    }

    /// @dev Revert data with the four selector bytes removed.
    function _body(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i = 0; i < out.length; i++) out[i] = err[i + 4];
    }

    /// @dev The Solidity panic codes a corpus walk actually hits.
    function _panicName(uint256 code) private pure returns (string memory) {
        if (code == 0x01) return "assert";
        if (code == 0x11) return "arithmetic overflow";
        if (code == 0x12) return "division by zero";
        if (code == 0x21) return "invalid enum";
        if (code == 0x22) return "bad storage bytes";
        if (code == 0x31) return "pop on empty array";
        if (code == 0x32) return "array index out of bounds";
        if (code == 0x41) return "excessive allocation";
        if (code == 0x51) return "zero-initialised function";
        return vm.toString(code);
    }

    /* ------------------------------------------------------------ */
    /* Proving a `describeRevert` override complete                  */
    /* ------------------------------------------------------------ */

    /// @notice Require every error declared by `artifacts` to render as
    ///         something other than its own hex.
    ///
    /// @dev    The completeness half of a `describeRevert` override.
    ///         The compiler already catches a renamed or deleted error,
    ///         because every arm is written `Contract.Error.selector`.
    ///         What nothing catches is an error ADDED and never
    ///         described, which would surface a real failure as four
    ///         anonymous bytes — so the ABI is read back from the
    ///         compiled artifact and checked.
    ///
    ///         Reading `out/` is why `foundry.toml` grants it read
    ///         access.  Indices are probed until the parse fails
    ///         because forge exposes no array-length path and no
    ///         wildcard, and the artifact PATH crosses the call
    ///         boundary rather than its contents, so the megabyte of
    ///         JSON lives in the callee's fresh memory per call instead
    ///         of accumulating in the caller's.
    function assertEveryDeclaredErrorIsDescribed(string[] memory artifacts) internal {
        uint256 seen = 0;
        for (uint256 a = 0; a < artifacts.length; a++) {
            for (uint256 i = 0; ; i++) {
                string memory kind;
                try this.abiEntryType(artifacts[a], i) returns (string memory k) {
                    kind = k;
                } catch {
                    break;
                }
                if (keccak256(bytes(kind)) != keccak256("error")) continue;
                string memory sig = this.abiErrorSignature(artifacts[a], i);
                beginEntry(string.concat(artifacts[a], " ", sig));
                seen++;
                // A well-formed instance: the selector plus two zero
                // words, which covers every argument list in reach.
                bytes memory sample =
                    abi.encodePacked(bytes4(keccak256(bytes(sig))), new bytes(64));
                checkFalse(
                    keccak256(bytes(describeRevert(sample)))
                        == keccak256(bytes(vm.toString(sample))),
                    "declared error renders as raw hex: add it to describeRevert"
                );
            }
        }
        beginEntry("");
        assertGt(seen, 0, "no errors found: artifact path or ABI shape changed");
    }

    /// @dev The `type` of ABI entry `i`.  Reverts past the end, which
    ///      is how the walk above finds the end.
    function abiEntryType(string calldata artifact, uint256 i)
        external
        view
        returns (string memory)
    {
        return vm.parseJsonString(
            vm.readFile(artifact), string.concat(".abi[", vm.toString(i), "].type"));
    }

    /// @dev The canonical signature of the error at ABI entry `i`.
    function abiErrorSignature(string calldata artifact, uint256 i)
        external
        view
        returns (string memory sig)
    {
        string memory e = string.concat(".abi[", vm.toString(i), "]");
        sig = string.concat(
            vm.parseJsonString(vm.readFile(artifact), string.concat(e, ".name")), "(");
        for (uint256 k = 0; ; k++) {
            string memory t;
            try this.abiInputType(artifact, i, k) returns (string memory s) {
                t = s;
            } catch {
                break;
            }
            sig = string.concat(sig, k > 0 ? "," : "", t);
        }
        sig = string.concat(sig, ")");
    }

    /// @dev The `type` of input `k` of ABI entry `i`.  Reverts past the
    ///      end of the input list.
    function abiInputType(string calldata artifact, uint256 i, uint256 k)
        external
        view
        returns (string memory)
    {
        return vm.parseJsonString(
            vm.readFile(artifact),
            string.concat(".abi[", vm.toString(i), "].inputs[", vm.toString(k), "].type")
        );
    }

    /// @notice A corpus's entry count, from the nested `.header.count`.
    ///
    /// @dev    Three suites had written this line each.  Trivial in
    ///         isolation, and the reason it belongs here anyway: the
    ///         PATH is a schema fact, so three copies is three places to
    ///         edit when the header moves.
    function headerCount(string memory raw) internal pure returns (uint256) {
        return vm.parseJsonUint(raw, ".header.count");
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
