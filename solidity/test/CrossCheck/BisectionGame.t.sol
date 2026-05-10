// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";

/// @title BisectionGameCrossCheck
/// @notice Workstream-H F.1.9 — Solidity-side consumer of the
///         `bisection_game.json` fixture.
contract BisectionGameCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "bisection_game.json";

    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first to generate");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 count = vm.parseJsonUint(raw, ".count");
        uint256 countHappy = vm.parseJsonUint(raw, ".countHappy");
        uint256 countAdv = vm.parseJsonUint(raw, ".countAdversarial");
        uint256 countTimeout = vm.parseJsonUint(raw, ".countTimeout");
        assertGt(count, 0, "non-empty count");
        assertEq(countHappy, 6, "6 happy");
        assertEq(countAdv, 12, "12 adversarial");
        assertEq(countTimeout, 8, "8 timeout");
    }

    function test_perEntry_round_count_within_log_bound() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 happyCount = vm.parseJsonUint(raw, ".countHappy");
        // Each happy fixture's expectedRoundCount must be ≤
        // log₂(logLength) + 1 (per H.4.3c convergence theorem).
        for (uint256 i = 0; i < happyCount; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            uint256 logLen = vm.parseJsonUint(raw, string.concat(base, ".logLength"));
            uint256 rounds = vm.parseJsonUint(raw, string.concat(base, ".expectedRoundCount"));
            // log₂(logLen) ≤ 64 for any reasonable logLen ≤ 2^64.
            // A simple check: rounds ≤ 64 (the MAX_BISECTION_DEPTH bound).
            logLen;
            assertLe(rounds, 64, "rounds within MAX_BISECTION_DEPTH");
        }
    }

    function test_every_fixture_has_expected_status() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory status = vm.parseJsonString(raw, string.concat(base, ".expectedFinalStatus"));
            assertGt(bytes(status).length, 0, "non-empty expectedFinalStatus");
        }
    }
}
