// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {KnomosisEip712} from "src/lib/KnomosisEip712.sol";

/// @title MigrationAttestationCrossCheck
/// @notice Workstream F.1.7 — Solidity-side consumer of the
///         `migration_attestation.json` fixture.  32 entries pinning
///         the cross-stack EIP-712 wrap of the migration struct hash.
///
/// @dev    Per the integration plan §10.1.7 + §21.6, this fixture
///         encodes the audit-3 direction-fix cross-stack invariant:
///         the `predecessor.migration() == address(this)` check (NOT
///         the pre-audit-3 successor-pre-committed form).
///
///         Cross-stack assertion is gated on `isKeccak256Linked`.
///         When linked, we recompute `KnomosisEip712.migrationStructHash
///         + KnomosisEip712.digest` and assert byte-equivalence with
///         the fixture's `expectedDigest`.
contract MigrationAttestationCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "migration_attestation.json";

    /// @notice Header shape: 32 entries split as 16 happy + 8 boundary
    ///         + 4 cross-replay + 4 audit-direction.
    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        assertEq(vm.parseJsonUint(raw, ".header.count"), 32, "count");
        assertEq(vm.parseJsonUint(raw, ".header.countHappyPath"), 16, "happy");
        assertEq(vm.parseJsonUint(raw, ".header.countBoundary"), 8, "boundary");
        assertEq(vm.parseJsonUint(raw, ".header.countCrossReplay"), 4, "cross-replay");
        assertEq(vm.parseJsonUint(raw, ".header.countAuditDirection"), 4, "audit-direction");
        assertEq(
            vm.parseJsonUint(raw, ".header.minGraceWindowBlocks"),
            216_000,
            "MIN_GRACE_WINDOW_BLOCKS"
        );
    }

    /// @notice Per-entry digest cross-check.  Recompute
    ///         `KnomosisEip712.digest(domainSeparator, structHash)` on
    ///         the Solidity side using the same five-field
    ///         migration struct preimage and the same five-field
    ///         EIP-712 domain (`name`, `version`, `chainId`,
    ///         `rollupId`, `verifyingContract`) the Lean side uses,
    ///         then assert byte-for-byte equality with the
    ///         fixture's `expectedDigest`.
    ///
    /// @dev    This audit pass replaced a tautological `sink == sink`
    ///         placeholder with a real assertion.  The fix required
    ///         (a) extending the Lean fixture with `rollupId` and
    ///         (b) correcting the Lean type string to `uint64
    ///         migrationStateRootLogIdx` (was `uint256`, which made
    ///         the typeHash diverge from Solidity's character-for-
    ///         character constant).  Both fixes are recorded in the
    ///         Workstream-F audit changelog.
    ///
    ///         Bound checks: the JSON `migrationStateRootLogIdx`
    ///         field is bounded at uint64 by construction (the
    ///         Lean generator uses `genUInt64Wide`).  We assert the
    ///         bound explicitly before truncating, so a corrupted
    ///         fixture surfaces with a clear error rather than a
    ///         silent typecast.
    function test_perEntry_digest_matches() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".header.isKeccak256Linked");
        if (!linked) {
            _skipWithReason("keccak256 fallback; cross-stack digest skipped");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            bytes32 predDid =
                vm.parseJsonBytes32(raw, string.concat(base, ".predecessorDeploymentId"));
            bytes32 succDid =
                vm.parseJsonBytes32(raw, string.concat(base, ".successorDeploymentId"));
            bytes32 stateRoot =
                vm.parseJsonBytes32(raw, string.concat(base, ".migrationStateRoot"));
            uint256 logIdx =
                vm.parseJsonUint(raw, string.concat(base, ".migrationStateRootLogIdx"));
            uint256 grace =
                vm.parseJsonUint(raw, string.concat(base, ".graceWindowBlocks"));
            uint256 chainId =
                vm.parseJsonUint(raw, string.concat(base, ".chainId"));
            uint256 rollupId =
                vm.parseJsonUint(raw, string.concat(base, ".rollupId"));
            address vc =
                vm.parseJsonAddress(raw, string.concat(base, ".verifyingContract"));

            // The cast `uint64(logIdx)` is structurally required:
            // `KnomosisEip712.migrationStructHash`'s declared parameter
            // type is `uint64 migrationStateRootLogIdx`, mirroring the
            // Solidity-side type-string declaration (`uint64
            // migrationStateRootLogIdx`).  We cannot pass `uint256`;
            // the library API insists on `uint64`.  Internally the
            // library widens to uint256 for `abi.encode`, but the
            // function signature still requires the truncating call
            // site here.
            //
            // The `assertLt` bound check converts a silent
            // fixture-corruption typecast into a loud test failure
            // before the cast happens; under the bound, the cast is
            // exact (no value loss).  The `forge-lint disable-next-
            // line(unsafe-typecast)` directive is the documented
            // Foundry pattern for "this cast has been reasoned about
            // and is safe" — preferable to leaving the warning in
            // the build output where it would erode the
            // zero-warning posture documented in CLAUDE.md.
            assertLt(logIdx, 1 << 64, "logIdx out of uint64 range");

            // Truncation safe: the assertLt above proves `logIdx < 2^64`,
            // so the `uint64(logIdx)` cast is exact (no value loss).
            // The library's `migrationStructHash` declares `uint64
            // migrationStateRootLogIdx` so the cast is structurally
            // forced.  The lint directive must be on the line
            // immediately preceding the cast (intervening comments
            // make Foundry's lint suppressor apply to the wrong line).
            bytes32 sh;
            // forge-lint: disable-next-line(unsafe-typecast)
            sh = KnomosisEip712.migrationStructHash(predDid, succDid, stateRoot, uint64(logIdx), grace);
            bytes32 ds = KnomosisEip712.domainSeparator(
                "KnomosisMigration", "1", chainId, rollupId, vc
            );
            bytes32 expected =
                vm.parseJsonBytes32(raw, string.concat(base, ".expectedDigest"));
            bytes32 actual = KnomosisEip712.digest(ds, sh);

            assertEq(actual, expected, "digest mismatch");
        }
    }

    /// @notice Type-string cross-check: pin the Lean side's
    ///         `knomosisMigrationTypeString` against
    ///         `KnomosisEip712.KNOMOSIS_MIGRATION_TYPE_STRING`
    ///         character-for-character.  This catches a class of
    ///         drift bugs where the Lean and Solidity typeHashes
    ///         diverge by a single character (e.g. `uint256` vs
    ///         `uint64`).
    function test_typeString_matches_solidity_constant() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        string memory leanString =
            vm.parseJsonString(raw, ".header.typeStringForReference");
        string memory expected =
            "KnomosisMigration(bytes32 predecessorDeploymentId,"
            "bytes32 successorDeploymentId,bytes32 migrationStateRoot,"
            "uint64 migrationStateRootLogIdx,uint256 graceWindowBlocks)";
        assertEq(
            keccak256(bytes(leanString)),
            keccak256(bytes(expected)),
            "Lean knomosisMigrationTypeString diverged from Solidity constant"
        );
    }

    /// @notice Domain-type-string cross-check: pin the Lean side's
    ///         5-field `EIP712Domain(...)` declaration against the
    ///         Solidity-side `KnomosisEip712.EIP712_DOMAIN_TYPE_STRING`.
    function test_domainTypeString_matches_solidity_constant() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        string memory leanString =
            vm.parseJsonString(raw, ".header.domainTypeStringForReference");
        string memory expected =
            "EIP712Domain(string name,string version,uint256 chainId,"
            "uint256 rollupId,bytes verifyingContract)";
        assertEq(
            keccak256(bytes(leanString)),
            keccak256(bytes(expected)),
            "Lean EIP-712 domain type string diverged from Solidity constant"
        );
    }

    /// @notice Cross-replay distinguishability: 4 cross-replay entries
    ///         (indices 24..28) produce 4 distinct expectedDigest values.
    function test_cross_replay_distinct() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        bytes32[] memory digests = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            string memory base = string.concat(".entries[", vm.toString(24 + i), "]");
            digests[i] = vm.parseJsonBytes32(raw, string.concat(base, ".expectedDigest"));
        }
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                assertTrue(digests[i] != digests[j], "cross-replay digests collided");
            }
        }
    }

    /// @notice Audit-3-direction sub-suite: indices 28..32 cover
    ///         the predecessor pre-commitment direction.  Two are
    ///         accepted (predecessorPreCommitted) and two are rejected
    ///         (predecessorAddressZero → revert
    ///         PredecessorDoesNotReferenceThisMigration).
    function test_audit3_direction_coverage() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 acceptCount = 0;
        uint256 rejectCount = 0;
        for (uint256 i = 28; i < 32; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory outcome = vm.parseJsonString(raw, string.concat(base, ".outcome"));
            string memory direction = vm.parseJsonString(raw, string.concat(base, ".direction"));
            bytes32 oh = keccak256(abi.encodePacked(outcome));
            bytes32 dh = keccak256(abi.encodePacked(direction));
            if (oh == keccak256(abi.encodePacked("accepted")) &&
                dh == keccak256(abi.encodePacked("predecessorPreCommitted"))) {
                acceptCount++;
            }
            if (oh == keccak256(abi.encodePacked("revert:PredecessorDoesNotReferenceThisMigration")) &&
                dh == keccak256(abi.encodePacked("predecessorAddressZero"))) {
                rejectCount++;
            }
        }
        assertEq(acceptCount, 2, "audit-3 accepted count");
        assertEq(rejectCount, 2, "audit-3 rejected count");
    }
}
