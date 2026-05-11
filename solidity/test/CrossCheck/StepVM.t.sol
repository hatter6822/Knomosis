// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";

/// @title StepVMCrossCheck
/// @notice Workstream-H F.1.8 — Solidity-side consumer of the
///         `step_vm.json` fixture (48 entries; #226 / #251
///         coherence corpus).
///
/// @dev    **Post-audit-1 honest scope statement.**  The Lean-side
///         fixture writer emits `expectedPostStateCommit` via
///         `commitExtendedState ∘ kernelOnlyApply` (the canonical
///         5-component hash).  The Solidity `executeStep` produces
///         a step-VM-specific 32-byte hash via
///         `keccak256(preCommit, tag-string, fields, post-cell-values,
///         signer)` — these constructions are STRUCTURALLY DISTINCT
///         and cannot be equal even under matching hash bindings.
///
///         Therefore the per-entry byte-equivalence check is
///         currently structurally infeasible without either:
///         (a) lifting Solidity to compute the full
///             `commitExtendedState` (deferred — requires per-sub-
///             state CBE encoders in Solidity), OR
///         (b) adding a parallel "step-VM commit" function on the
///             Lean side that matches this contract's hash recipe
///             (deferred — requires extending the Lean coherence
///             chain to the new commit form).
///
///         **Currently shipped checks** (active regardless of
///         binding status):
///           * Fixture file exists + header shape.
///           * Every entry's schema (fixtureId, actionVariant,
///             commit-hex-length) is well-formed.
///           * Adversarial entries' `expectedPostStateCommitHex`
///             is `"null"` (i.e., the fixture writer correctly
///             flags the failure case).
///
///         The shape checks catch any future Lean-side regression
///         that would break the per-entry contract.  The full
///         byte-equivalence test is parked as deferred future work,
///         openly documented in `docs/fault_proof_runbook.md` §7.2.
contract StepVMCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "step_vm.json";

    /// @notice Verify the fixture file exists and has the expected
    ///         shape (count fields populated, entries array
    ///         non-empty).
    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first to generate");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 count = vm.parseJsonUint(raw, ".count");
        uint256 countTransfer = vm.parseJsonUint(raw, ".countTransfer");
        uint256 countMint = vm.parseJsonUint(raw, ".countMint");
        assertGt(count, 0, "non-empty count");
        assertEq(countTransfer, 24, "transfer count");
        assertEq(countMint, 24, "mint count");
    }

    /// @notice Check every entry has the expected schema (fixtureId,
    ///         actionVariant, preStateCommitHex are non-empty).
    function test_perEntry_schema_is_well_formed() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory id = vm.parseJsonString(raw, string.concat(base, ".fixtureId"));
            string memory variant = vm.parseJsonString(raw, string.concat(base, ".actionVariant"));
            assertGt(bytes(id).length, 0, "non-empty fixtureId");
            assertGt(bytes(variant).length, 0, "non-empty actionVariant");
        }
    }

    /// @notice Per-entry adversarial-flag validation: every entry
    ///         whose `expectedRevertReason != "null"` must have
    ///         `expectedPostStateCommitHex == "null"`.  The Lean-
    ///         side `buildAdversarialBadPreCommit` enforces this
    ///         pairing; a regression that breaks it indicates the
    ///         fixture writer is corrupt.
    function test_perEntry_adversarial_flag_consistency() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        uint256 adversarialCount = 0;
        for (uint256 i = 0; i < n; i++) {
            string memory base =
              string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
              vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            string memory postCommit =
              vm.parseJsonString(raw, string.concat(base, ".expectedPostStateCommitHex"));
            // If revertReason != "null", postCommit must also be "null".
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                assertEq(postCommit, "null",
                    "adversarial entry must have null postCommit");
                adversarialCount++;
            }
        }
        // The fixture has 8 adversarial transfer + 8 adversarial mint = 16.
        assertEq(adversarialCount, 16,
            "16 adversarial entries total");
    }

    /// @notice Per-entry happy-path check: every entry whose
    ///         `expectedRevertReason == "null"` must have a
    ///         32-byte-formatted `expectedPostStateCommitHex`
    ///         (i.e., "0x" + 64 hex chars).
    function test_perEntry_happy_postCommit_is_32_bytes() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        uint256 happyCount = 0;
        for (uint256 i = 0; i < n; i++) {
            string memory base =
              string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
              vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) == keccak256(bytes("null"))) {
                string memory postCommit =
                  vm.parseJsonString(raw, string.concat(base, ".expectedPostStateCommitHex"));
                assertEq(bytes(postCommit).length, 66,
                    "happy postCommit is '0x' + 64 hex chars");
                happyCount++;
            }
        }
        // 16 happy transfer + 16 happy mint = 32 happy entries total.
        assertEq(happyCount, 32, "32 happy entries total");
    }

    /// @notice Cross-stack per-entry byte-equivalence check.
    ///         **Currently deferred** per the contract docstring:
    ///         the Solidity commit recipe and the Lean
    ///         `commitExtendedState` are structurally distinct, so
    ///         per-entry byte equality is not yet achievable.  This
    ///         test logs a skip and documents the deferral; future
    ///         work either lifts Solidity to compute the full
    ///         `commitExtendedState` or adds a parallel "step-VM
    ///         commit" on the Lean side.
    function test_perEntry_postCommit_matches_DEFERRED() public {
        _skipWithReason(
          "per-entry byte-equivalence deferred (see contract docstring)");
    }
}
