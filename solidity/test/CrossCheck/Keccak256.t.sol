// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";

/// @title Keccak256CrossCheck
/// @notice Workstream F.1.3 — Solidity-side consumer of the
///         `keccak256.json` fixture.  Loads each entry, computes
///         `keccak256(input)` via the EVM opcode, and asserts the
///         result matches the fixture's `expected` field.
///
/// @dev    The EVM `keccak256` opcode is always available, so the
///         Solidity-side computation never depends on a binding flag.
///         The cross-stack assertion (Lean's `expected` matches
///         Solidity's `keccak256(input)`) is gated on the Lean side
///         linking the production keccak256 binding — when the
///         header's `isKeccak256Linked = false`, the fixture's
///         `expected` field is the FNV-1a-64 fallback bytes (NOT
///         keccak256), so we skip the assertion.
///
///         The four reference KAT vectors (`kat_empty`, `kat_abc`,
///         `kat_helloWorld`, `kat_singleZero`) appear at indices
///         0..3 of the fixture's `entries` array; their cross-check
///         is also gated on the binding being linked, but the on-
///         chain `keccak256` matching their *Lean* counterparts'
///         expected values is the load-bearing forward-protection
///         test for any future regression in the Rust adaptor's
///         keccak256 binding.
contract Keccak256CrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "keccak256.json";

    /// @notice Test that the fixture file exists and its header
    ///         records the expected count breakdown.
    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first to generate");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 cnt        = vm.parseJsonUint(raw, ".header.count");
        uint256 cntKat     = vm.parseJsonUint(raw, ".header.countKat");
        uint256 cntShort   = vm.parseJsonUint(raw, ".header.countShort");
        uint256 cntMedium  = vm.parseJsonUint(raw, ".header.countMedium");
        uint256 cntLong    = vm.parseJsonUint(raw, ".header.countLong");
        assertEq(cnt, 104, "fixture entry count");
        assertEq(cntKat, 4, "kat count");
        assertEq(cntShort, 50, "short count");
        assertEq(cntMedium, 30, "medium count");
        assertEq(cntLong, 20, "long count");
    }

    /// @notice Per-entry cross-stack assertion: keccak256(input)
    ///         on the EVM equals the fixture's `expected` field.
    ///         Gated on `isKeccak256Linked = true` in the header;
    ///         skipped otherwise.
    function test_perEntry_keccak256_matches() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".header.isKeccak256Linked");
        if (!linked) {
            _skipWithReason("keccak256 fallback (FNV-1a-64); cross-check skipped");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            bytes memory input =
                vm.parseJsonBytes(raw, string.concat(base, ".input"));
            bytes32 expected =
                vm.parseJsonBytes32(raw, string.concat(base, ".expected"));
            bytes32 actual = keccak256(input);
            string memory label =
                vm.parseJsonString(raw, string.concat(base, ".label"));
            assertEq(actual, expected, string.concat("keccak mismatch at ", label));
        }
    }

    /// @notice Sanity test: the four reference KAT vectors appear at
    ///         indices 0..3 with the documented labels.  Catches a
    ///         class of fixture-corruption bugs.
    function test_kat_labels_at_known_indices() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        string memory l0 = vm.parseJsonString(raw, ".entries[0].label");
        string memory l1 = vm.parseJsonString(raw, ".entries[1].label");
        string memory l2 = vm.parseJsonString(raw, ".entries[2].label");
        string memory l3 = vm.parseJsonString(raw, ".entries[3].label");
        assertEq(l0, "kat:empty",       "kat[0] label");
        assertEq(l1, "kat:abc",         "kat[1] label");
        assertEq(l2, "kat:helloWorld",  "kat[2] label");
        assertEq(l3, "kat:singleZero",  "kat[3] label");
    }
}
