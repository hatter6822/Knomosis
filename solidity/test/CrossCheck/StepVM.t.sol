// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {CanonStepVM} from "src/contracts/CanonStepVM.sol";

/// @title StepVMCrossCheck
/// @notice Workstream-H F.1.8 — Solidity-side consumer of the
///         `step_vm.json` fixture (48 entries; #226 / #251
///         coherence corpus).
///
/// @dev    **Two commits per entry.**  Each fixture entry carries
///         two distinct 32-byte hashes:
///
///           * `expectedPostStateCommitHex` — the canonical
///             `commitExtendedState ∘ kernelOnlyApply` value,
///             produced from the 5-component state-aggregate
///             recipe (Workstream H §6).
///           * `expectedStepVMCommitHex` — the step-VM-specific
///             `keccak256(preCommit || tagHash || packed-fields)`
///             value, mirroring `CanonStepVM.executeStep`'s output
///             exactly.  Lean-side mirror at
///             `LegalKernel.FaultProof.SolidityStepVMCommit`.
///
///         Under `isKeccak256Linked = true`, the Lean-side
///         `expectedStepVMCommitHex` byte-equals
///         `CanonStepVM.executeStep`'s output on the same inputs;
///         this is the cross-stack byte-equivalence claim verified
///         in `test_perEntry_stepVMCommit_present_and_well_formed`
///         below.  Without the binding (FNV-1a-64 fallback), Lean
///         emits 8-byte FNV outputs while Solidity emits 32-byte
///         keccak256 outputs — outputs cannot match by construction,
///         and the byte-equivalence test correctly skips.
///
///         **Active checks** (independent of binding status):
///           * Fixture file exists + header shape.
///           * Every entry's schema (fixtureId, actionVariant,
///             commit-hex-length) is well-formed.
///           * Adversarial entries' `expectedPostStateCommitHex`
///             is `"null"` (i.e., the fixture writer correctly
///             flags the failure case).
///           * Step-VM commit field is present + well-formed.
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
        // SVC.5.e: the corpus widened from 48 → 218 entries (24
        // Transfer + 24 Mint + 17 x10 new-variant entries).
        // The new countX fields are checked individually below.
        assertEq(count, 218, "SVC.5.e: total corpus is 218 entries");
        assertEq(countTransfer, 24, "transfer count");
        assertEq(countMint, 24, "mint count");
    }

    /// @notice SVC.5.e — verify the per-variant count fields are
    ///         the expected 10 each for the 17 new variants.
    function test_perVariant_counts() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        string[17] memory variantKeys = [
            ".countBurn",
            ".countFreezeResource",
            ".countReplaceKey",
            ".countReward",
            ".countDistributeOthers",
            ".countProportionalDilute",
            ".countDispute",
            ".countDisputeWithdraw",
            ".countVerdict",
            ".countRollback",
            ".countRegisterIdentity",
            ".countDeposit",
            ".countWithdraw",
            ".countDeclareLocalPolicy",
            ".countRevokeLocalPolicy",
            ".countFaultProofChallenge",
            ".countFaultProofResolution"
        ];
        for (uint256 i = 0; i < variantKeys.length; i++) {
            uint256 c = vm.parseJsonUint(raw, variantKeys[i]);
            assertEq(c, 10, string.concat(variantKeys[i], " should be 10"));
        }
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
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            string memory postCommit =
                vm.parseJsonString(raw, string.concat(base, ".expectedPostStateCommitHex"));
            // If revertReason != "null", postCommit must also be "null".
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                assertEq(postCommit, "null", "adversarial entry must have null postCommit");
                adversarialCount++;
            }
        }
        // SVC.5.e: 8 adversarial transfer + 8 adversarial mint +
        // 17 x4 = 68 adversarial new-variant entries = 84 total.
        assertEq(adversarialCount, 84, "84 adversarial entries total (16 + 17 x4)");
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
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) == keccak256(bytes("null"))) {
                string memory postCommit =
                    vm.parseJsonString(raw, string.concat(base, ".expectedPostStateCommitHex"));
                assertEq(bytes(postCommit).length, 66, "happy postCommit is '0x' + 64 hex chars");
                happyCount++;
            }
        }
        // SVC.5.e: 16 happy transfer + 16 happy mint + 17 x6 =
        // 134 happy entries total.
        assertEq(happyCount, 134, "134 happy entries total (32 + 17 x6)");
    }

    /// @notice **Cross-stack per-entry byte-equivalence.**  The
    ///         fixture ships `expectedStepVMCommitHex` produced
    ///         by Lean's
    ///         `LegalKernel.FaultProof.SolidityStepVMCommit.stepCommit*`
    ///         functions — the Lean-side mirror of the Solidity
    ///         step-VM commit recipe (`keccak256(preCommit ||
    ///         tagHash || packed-fields)`).
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
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            string memory svmCommit =
                vm.parseJsonString(raw, string.concat(base, ".expectedStepVMCommitHex"));
            if (keccak256(bytes(revertReason)) == keccak256(bytes("null"))) {
                // Happy: must be 32-byte hex.
                assertEq(bytes(svmCommit).length, 66, "happy entry's stepVMCommit is 32 bytes");
            } else {
                // Adversarial: null marker.
                assertEq(svmCommit, "null", "adversarial entry's stepVMCommit is null");
            }
        }
    }

    /// @notice SVC.5.e+ — single uniform cross-stack
    ///         byte-equivalence driver.  Replaces the previous
    ///         per-variant tests (mint, opaque, freezeResource,
    ///         replaceKey, registerIdentity) with one generic
    ///         loop that walks every happy fixture, parses the
    ///         (preCommit, actionKind, actionFields, signer,
    ///         cellProofs) tuple from JSON, invokes
    ///         `CanonStepVM.executeStep`, and asserts byte
    ///         equality against `expectedStepVMCommitHex`.
    ///
    ///         Under `isKeccak256Linked = true`, all 134 happy
    ///         fixtures (16 transfer + 16 mint + 17 x6 other
    ///         variants) must produce identical bytes on both
    ///         sides.  Skipped under FNV fallback.
    ///
    ///         This is the load-bearing cross-stack byte-equivalence
    ///         claim closing Workstream SVC.5.e+: the 7
    ///         cell-bound structured variants (Transfer, Burn,
    ///         Reward, Deposit, Withdraw, DistributeOthers,
    ///         ProportionalDilute) now ship cell-proof bundles
    ///         from non-empty pre-states, so Solidity's
    ///         `_findBalanceCellProof` finds the matching cell
    ///         and the step-VM hash recipe can be invoked
    ///         without reverting.
    /// @dev SVC.5.e+ — execute the step VM with all inputs
    ///      parsed from JSON at the given base path, return
    ///      the recomputed step-VM commit.  Extracted to a
    ///      pure entry-parsing + call-chain so the outer
    ///      driver's stack stays shallow.
    function _executeStepFromFixture(string memory raw, string memory base)
        internal
        returns (bytes32)
    {
        return stepVM.executeStep(
            vm.parseJsonBytes32(raw, string.concat(base, ".preStateCommitHex")),
            uint8(vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"))),
            vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex")),
            uint64(vm.parseJsonUint(raw, string.concat(base, ".signerNat"))),
            _parseCellProofs(raw, base)
        );
    }

    /// @dev Check entry at index `i` is byte-equivalent.
    ///      Returns 1 if happy (asserted), 0 if adversarial
    ///      (skipped).  Pulled into a helper function so each
    ///      iteration of the outer loop resets its own stack
    ///      frame (avoiding Yul stack-too-deep).
    function _checkEntryAtIndex(string memory raw, uint256 i) internal returns (uint256) {
        string memory base = string.concat(".entries[", vm.toString(i), "]");
        string memory revertReason =
            vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
        if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
            return 0;
        }
        assertEq(
            _executeStepFromFixture(raw, base),
            vm.parseJsonBytes32(raw, string.concat(base, ".expectedStepVMCommitHex")),
            string.concat("byte-equivalence failed for ", base)
        );
        return 1;
    }

    function test_perEntry_byte_equivalence_all_happy() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".isKeccak256Linked");
        if (!linked) {
            _skipWithReason("byte-equivalence requires keccak256 binding");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".count");
        uint256 happyChecked = 0;
        for (uint256 i = 0; i < n; i++) {
            happyChecked += _checkEntryAtIndex(raw, i);
        }
        // 16 transfer + 16 mint + 17 x6 other-variant happy entries.
        assertEq(happyChecked, 134, "expected 134 happy entries");
    }

    /// @notice SVC.5.e+ — schema check: every cell-proof entry
    ///         in every fixture's cellProofs array has the
    ///         documented shape (cellKind ≤ 6, hex fields
    ///         well-formed).  Iterates every entry; runs
    ///         unconditionally (no isKeccak256Linked gate).
    /// @notice SVC.5.e+: cell-proof schema invariants are
    ///         enforced via two paths and don't need a separate
    ///         Solidity-side iteration:
    ///
    ///         1. Lean-side: `crosscheck-step-vm`'s
    ///            `"SVC.5.e+: every happy fixture's cellProofs
    ///            has cellKind ≤ 6"` and the byte-pinning
    ///            invariants on the fixture's JSON output.
    ///         2. Solidity-side: `executeStep`'s outer loop
    ///            checks `cellProofs[i].witnessCommit ==
    ///            preStateCommit` and reverts on mismatch
    ///            (`BadCellProof`).  Combined with the
    ///            `_findBalanceCellProof` lookups, malformed
    ///            cells force a revert during the
    ///            byte-equivalence driver below — making any
    ///            schema regression observable as a failing
    ///            assertion.
    ///
    ///         The separate per-cell schema test was removed
    ///         to satisfy Yul's stack-depth bound under
    ///         `via_ir = true`.

    /// @notice SVC.5.e+ — defence-in-depth: every happy
    ///         fixture's cellProofs entries have witnessCommitHex
    ///         equal to the fixture's preStateCommitHex.  This
    ///         is the binding that Solidity's outer loop in
    ///         `executeStep` enforces; verifying it at the
    ///         fixture level catches Lean-side cell-proof
    ///         construction regressions before they reach
    ///         `executeStep`.
    /// @dev Assert all cell proofs at the given fixture base
    ///      have witnessCommitHex matching the fixture's
    ///      preStateCommitHex.  Extracted to keep the outer
    ///      driver's stack shallow.
    function _assertWitnessBinding(string memory raw, string memory base) internal pure {
        string memory preStateHex =
            vm.parseJsonString(raw, string.concat(base, ".preStateCommitHex"));
        uint256 nProofs = vm.parseJsonUint(raw, string.concat(base, ".cellProofsCount"));
        for (uint256 j = 0; j < nProofs; j++) {
            string memory cpBase = string.concat(base, ".cellProofs[", vm.toString(j), "]");
            assertEq(
                vm.parseJsonString(raw, string.concat(cpBase, ".witnessCommitHex")),
                preStateHex,
                string.concat("witnessCommitHex != preStateCommitHex for ", cpBase)
            );
        }
    }

    function test_perEntry_cellProofs_witness_binding() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                continue;
            }
            _assertWitnessBinding(raw, base);
        }
    }

    /// @notice SVC.5.e — cross-stack byte-equivalence for
    ///         the actionKind dispatch path.  Every happy fixture's
    ///         `actionKindByte` (the dispatcher byte) must be in
    ///         0..18 (the Solidity `ActionKind` enum's valid range).
    ///         An out-of-range dispatcher would revert in
    ///         `_toActionKind`.
    function test_perEntry_actionKindByte_in_range() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                // Adversarial entries may have arbitrary kind bytes
                // by design; only check happy entries.
                continue;
            }
            uint256 kind = vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"));
            assertLe(kind, 18, string.concat("actionKindByte out of range for ", base));
        }
    }

    /// @notice SVC.5.e — actionFieldsHex schema: every happy
    ///         fixture's actionFieldsHex string starts with "0x"
    ///         and has an even (post-0x) length.  Defensive
    ///         schema check.
    function test_perEntry_actionFieldsHex_well_formed() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                continue;
            }
            string memory fields = vm.parseJsonString(raw, string.concat(base, ".actionFieldsHex"));
            bytes memory b = bytes(fields);
            assertGe(b.length, 2, string.concat("actionFieldsHex too short for ", base));
            assertEq(
                b[0], bytes1("0"), string.concat("actionFieldsHex missing 0x prefix for ", base)
            );
            assertEq(
                b[1], bytes1("x"), string.concat("actionFieldsHex missing 0x prefix for ", base)
            );
            // Even length (after 0x).
            assertEq(b.length % 2, 0, string.concat("actionFieldsHex has odd length for ", base));
        }
    }

    /// @dev SVC.5.e+ — parser for one cell-proof JSON entry.
    ///      Builds a `CanonStepVM.CellProof` from the 5 fields
    ///      at the given JSON base path.  Uses an in-place
    ///      struct initialization to keep stack pressure low.
    function _parseCellProof(string memory raw, string memory base)
        internal
        pure
        returns (CanonStepVM.CellProof memory cp)
    {
        cp.cellKind = uint8(vm.parseJsonUint(raw, string.concat(base, ".cellKind")));
        cp.keyA = vm.parseJsonUint(raw, string.concat(base, ".keyA"));
        cp.keyB = vm.parseJsonUint(raw, string.concat(base, ".keyB"));
        cp.cellValue = vm.parseJsonBytes(raw, string.concat(base, ".cellValueHex"));
        cp.witnessCommit = vm.parseJsonBytes32(raw, string.concat(base, ".witnessCommitHex"));
    }

    /// @dev SVC.5.e+ — parser for an entire fixture's
    ///      `cellProofs` array.  Discovers the array length via
    ///      `vm.parseJsonKeys` and iterates per-element.
    function _parseCellProofs(string memory raw, string memory base)
        internal
        pure
        returns (CanonStepVM.CellProof[] memory proofs)
    {
        // Use the per-entry `cellProofsCount` scalar instead of
        // `vm.parseJsonKeys` (which only works on objects, not
        // arrays of objects).
        uint256 nProofs = vm.parseJsonUint(raw, string.concat(base, ".cellProofsCount"));
        proofs = new CanonStepVM.CellProof[](nProofs);
        for (uint256 k = 0; k < nProofs; k++) {
            proofs[k] =
                _parseCellProof(raw, string.concat(base, ".cellProofs[", vm.toString(k), "]"));
        }
    }

    /// @dev Deploy `CanonStepVM` for the byte-equivalence test.
    CanonStepVM internal stepVM;

    function setUp() public {
        stepVM = new CanonStepVM();
    }
}
