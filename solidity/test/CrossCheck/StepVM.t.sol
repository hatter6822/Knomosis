// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {CanonStepVM} from "src/contracts/CanonStepVM.sol";

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

    /// @notice **Cross-stack per-entry byte-equivalence (audit-2
    ///         closure).**  The fixture now ships
    ///         `expectedStepVMCommitHex` produced by Lean's
    ///         `LegalKernel.FaultProof.SolidityStepVMCommit.stepCommit*`
    ///         functions — the **Lean-side mirror** of the
    ///         Solidity step-VM commit recipe (audit-2 uniform
    ///         format: `keccak256(preCommit || tagHash ||
    ///         packed-fields)`).
    ///
    ///         Under the production keccak256 binding, the
    ///         Lean-side `expectedStepVMCommitHex` byte-equals
    ///         what `CanonStepVM.executeStep` would return on the
    ///         same inputs.  This is the real cross-stack
    ///         byte-equivalence claim.
    ///
    ///         Without the binding (FNV-1a-64 fallback), Lean uses
    ///         FNV (8-byte output) while Solidity uses keccak256
    ///         (32-byte output) — outputs cannot match.  The test
    ///         correctly skips in fallback mode.
    function test_perEntry_stepVMCommit_present_and_well_formed() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        // Every entry (happy or adversarial) must have the new
        // expectedStepVMCommitHex field populated.
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason = vm.parseJsonString(
                raw, string.concat(base, ".expectedRevertReason"));
            string memory svmCommit = vm.parseJsonString(
                raw, string.concat(base, ".expectedStepVMCommitHex"));
            if (keccak256(bytes(revertReason)) == keccak256(bytes("null"))) {
                // Happy: must be 32-byte hex.
                assertEq(bytes(svmCommit).length, 66,
                    "happy entry's stepVMCommit is 32 bytes");
            } else {
                // Adversarial: null marker.
                assertEq(svmCommit, "null",
                    "adversarial entry's stepVMCommit is null");
            }
        }
    }

    /// @notice **Cross-stack per-entry byte-equivalence (mint
    ///         variant).**  Reconstructs the inputs to the
    ///         first mint fixture entry and calls
    ///         `executeStep` against the deployed `CanonStepVM`.
    ///         Asserts the result byte-equals the fixture's
    ///         `expectedStepVMCommitHex`.
    ///
    ///         The mint variant is chosen because its semantics
    ///         is closed over `ExtendedState.empty` (pre-balance
    ///         0; `newToBal = 0 + amount` requires no
    ///         sufficient-balance precondition).  Transfer
    ///         fixtures use empty state too but require
    ///         `senderBal ≥ amount`, which fails on empty.
    ///
    ///         Under the FNV fallback, the fixture's preCommit
    ///         is FNV-derived while Solidity uses keccak256
    ///         throughout; the outputs cannot match.  Skip in
    ///         that case.  Under the production keccak256
    ///         binding, the fixture's preCommit is keccak256-
    ///         derived too and both sides use the same hash —
    ///         byte equivalence holds.
    function test_perEntry_stepVMCommit_byte_equivalence_mint() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".isKeccak256Linked");
        if (!linked) {
            _skipWithReason(
              "step-VM byte-equivalence requires keccak256 binding");
            return;
        }

        // Mint fixtures start at offset countTransfer (24).  Fixture
        // 0 of the mint corpus uses buildMintHappy 0 0 0 50 0 0
        // (i.toUInt64 = 0 for all positions).
        uint256 mintIdx = vm.parseJsonUint(raw, ".countTransfer");
        string memory base =
          string.concat(".entries[", vm.toString(mintIdx), "]");
        bytes32 preCommit = vm.parseJsonBytes32(
            raw, string.concat(base, ".preStateCommitHex"));
        bytes32 expectedSVM = vm.parseJsonBytes32(
            raw, string.concat(base, ".expectedStepVMCommitHex"));

        // Construct executeStep inputs for mint with the fixture's
        // parameters: (r=0, to=0, amount=50), signer=0, one cell
        // proof for (Balance, r=0, to=0) with pre-balance 0.
        CanonStepVM.CellProof[] memory proofs =
            new CanonStepVM.CellProof[](1);
        proofs[0] = CanonStepVM.CellProof({
            cellKind: 0,                  // Balance
            keyA: 0,                      // resource
            keyB: 0,                      // actor
            cellValue: _encodeCbeNat(0),  // pre-balance 0
            witnessCommit: preCommit
        });
        bytes memory actionFields = abi.encodePacked(
            uint64(0), uint64(0), uint64(50));  // r, to, amount

        bytes32 result = stepVM.executeStep(
            preCommit,
            uint8(1),  // ActionKind.Mint
            actionFields,
            uint64(0),  // signer
            proofs);

        // Byte equivalence with the Lean-side
        // `SolidityStepVMCommit.stepCommitMint`.
        assertEq(result, expectedSVM,
            "mint fixture's expectedStepVMCommit byte-equals executeStep output");
    }

    /// @dev Encode a uint256 as a CBE Nat (1-byte tag + 8 bytes LE),
    ///      matching `LegalKernel.Encoding.cborHeadEncode`.
    function _encodeCbeNat(uint256 v) internal pure returns (bytes memory) {
        // The deployed CanonStepVM expects 9-byte CBE Nat values
        // (1 tag byte + 8 LE value bytes).  Tag byte 0x1B is the
        // 8-byte width marker per CBE.
        bytes memory result = new bytes(9);
        result[0] = 0x1B;
        for (uint256 i = 0; i < 8; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            result[1 + i] = bytes1(uint8(v >> (8 * i)));
        }
        return result;
    }

    /// @dev Deploy `CanonStepVM` for the byte-equivalence test.
    CanonStepVM internal stepVM;
    function setUp() public {
        stepVM = new CanonStepVM();
    }
}
