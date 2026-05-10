// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";

/// @title FaultProofScenariosCrossCheck
/// @notice Workstream-H F.1.10 — Solidity-side consumer of the
///         `fault_proof_scenarios.json` fixture (8 end-to-end
///         scenarios per WU H.10.3).
contract FaultProofScenariosCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "fault_proof_scenarios.json";

    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first to generate");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 count = vm.parseJsonUint(raw, ".count");
        assertEq(count, 8, "8 end-to-end scenarios");
    }

    function test_every_scenario_has_outcome() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory outcome = vm.parseJsonString(raw, string.concat(base, ".expectedFinalOutcome"));
            assertGt(bytes(outcome).length, 0, "non-empty outcome");
        }
    }

    function test_corpus_covers_full_outcome_spectrum() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        bool sawChallengerWon;
        bool sawSequencerWon;
        bool sawFinalised;
        bool sawTimeoutSeq;
        bool sawTimeoutChal;
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory outcome = vm.parseJsonString(raw, string.concat(base, ".expectedFinalOutcome"));
            bytes32 oh = keccak256(bytes(outcome));
            if (oh == keccak256("ChallengerWon")) sawChallengerWon = true;
            else if (oh == keccak256("SequencerWon")) sawSequencerWon = true;
            else if (oh == keccak256("Finalised")) sawFinalised = true;
            else if (oh == keccak256("TimedOutSequencer")) sawTimeoutSeq = true;
            else if (oh == keccak256("TimedOutChallenger")) sawTimeoutChal = true;
        }
        assertTrue(sawChallengerWon, "ChallengerWon present");
        assertTrue(sawSequencerWon,  "SequencerWon present");
        assertTrue(sawFinalised,     "Finalised present");
        assertTrue(sawTimeoutSeq,    "TimedOutSequencer present");
        assertTrue(sawTimeoutChal,   "TimedOutChallenger present");
    }
}
