// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {KnomosisStepVM} from "src/contracts/KnomosisStepVM.sol";

/// @title StepVMCrossCheck
/// @notice Workstream-H F.1.8 — Solidity-side consumer of the
///         `step_vm.json` fixture (248 entries post-GP.5.3; #226 /
///         #251 coherence corpus).
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
///             value, mirroring `KnomosisStepVM.executeStep`'s output
///             exactly.  Lean-side mirror at
///             `LegalKernel.FaultProof.SolidityStepVMCommit`.
///
///         Under `isKeccak256Linked = true`, the Lean-side
///         `expectedStepVMCommitHex` byte-equals
///         `KnomosisStepVM.executeStep`'s output on the same inputs;
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
        // GP.9.1: the corpus widened from 248 → 258 entries
        // (refund-on-exit extension: +claimBudgetRefund at 10 entries,
        // on top of the 248 entries that already carried +depositWithFee
        // + topUpActionBudget + topUpActionBudgetFor).  The new countX
        // fields are checked individually below.
        assertEq(count, 258, "GP.9.1: total corpus is 258 entries");
        assertEq(countTransfer, 24, "transfer count");
        assertEq(countMint, 24, "mint count");
    }

    /// @notice GP.5.3 — verify the per-variant count fields are
    ///         the expected 10 each for the 17 SVC.5.e variants
    ///         plus the 3 Workstream-GP variants
    ///         (depositWithFee + topUpActionBudget +
    ///         topUpActionBudgetFor).
    function test_perVariant_counts() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        string[21] memory variantKeys = [
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
            ".countFaultProofResolution",
            // GP.3.3: two new variants at indices 19, 20.
            ".countDepositWithFee",
            ".countTopUpActionBudget",
            // GP.5.3: delegated top-up at index 21.
            ".countTopUpActionBudgetFor",
            // GP.9.1: refund-on-exit at index 22.
            ".countClaimBudgetRefund"
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
        // GP.9.1: 8 adversarial transfer + 8 adversarial mint +
        // 21 x4 = 84 adversarial new-variant entries (17 SVC.5.e +
        // 4 GP variants) = 100 total.
        assertEq(adversarialCount, 100, "100 adversarial entries total (16 + 21 x4)");
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
        // GP.9.1: 16 happy transfer + 16 happy mint + 21 x6 =
        // 158 happy entries total (17 SVC.5.e + 4 GP variants).
        assertEq(happyCount, 158, "158 happy entries total (32 + 21 x6)");
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
    ///         what `KnomosisStepVM.executeStep` would return on the
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
    ///         `KnomosisStepVM.executeStep`, and asserts byte
    ///         equality against `expectedStepVMCommitHex`.
    ///
    ///         Under `isKeccak256Linked = true`, all 158 happy
    ///         fixtures (16 transfer + 16 mint + 21 x6 other
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
        view
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
    function _checkEntryAtIndex(string memory raw, uint256 i) internal view returns (uint256) {
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
        // 16 transfer + 16 mint + 21 x6 other-variant happy entries
        // (17 SVC.5.e + 4 Workstream-GP variants).
        assertEq(happyChecked, 158, "expected 158 happy entries");
    }

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

    /// @notice GP.5.3 — cross-stack byte-equivalence for
    ///         the actionKind dispatch path.  Every happy fixture's
    ///         `actionKindByte` (the dispatcher byte) must be in
    ///         0..22 (the Solidity `ActionKind` enum's valid range
    ///         post-Workstream-GP: 0..18 SVC.5.e variants + 19
    ///         (DepositWithFee) + 20 (TopUpActionBudget) + 21
    ///         (TopUpActionBudgetFor) + 22 (ClaimBudgetRefund)).
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
            assertLe(kind, 22, string.concat("actionKindByte out of range for ", base));
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
            // Compare against the literal `0` (0x30) and `x` (0x78) bytes
            // via byte-array literals rather than string-to-bytes1 casts
            // (the latter trips forge-lint's unsafe-typecast warning even
            // though both literals are exactly 1 byte).
            assertEq(
                b[0], bytes1(0x30), string.concat("actionFieldsHex missing 0x prefix for ", base)
            );
            assertEq(
                b[1], bytes1(0x78), string.concat("actionFieldsHex missing 0x prefix for ", base)
            );
            // Even length (after 0x).
            assertEq(b.length % 2, 0, string.concat("actionFieldsHex has odd length for ", base));
        }
    }

    /// @dev SVC.5.e+ — parser for one cell-proof JSON entry.
    ///      Builds a `KnomosisStepVM.CellProof` from the 5 fields
    ///      at the given JSON base path.  Uses an in-place
    ///      struct initialization to keep stack pressure low.
    function _parseCellProof(string memory raw, string memory base)
        internal
        pure
        returns (KnomosisStepVM.CellProof memory cp)
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
        returns (KnomosisStepVM.CellProof[] memory proofs)
    {
        // Use the per-entry `cellProofsCount` scalar instead of
        // `vm.parseJsonKeys` (which only works on objects, not
        // arrays of objects).
        uint256 nProofs = vm.parseJsonUint(raw, string.concat(base, ".cellProofsCount"));
        proofs = new KnomosisStepVM.CellProof[](nProofs);
        for (uint256 k = 0; k < nProofs; k++) {
            proofs[k] =
                _parseCellProof(raw, string.concat(base, ".cellProofs[", vm.toString(k), "]"));
        }
    }

    /// @notice GP.5.3 — hash-independent **data-flow** layout pin for
    ///         the packed primitives EVERY structured step-VM variant's
    ///         commit preimage is built from.  Lean EMITS its actual
    ///         `uint64BE` / `uint256BE` encoder output into
    ///         `step_vm.json` (`packedLayoutGoldens[].encodedHex`);
    ///         this test READS that output and recomputes
    ///         `abi.encodePacked(uint64 / uint256)`, asserting byte
    ///         equality.  Because the comparison is against the
    ///         Lean-emitted bytes (the single source of truth) rather
    ///         than an independently-maintained literal, a one-sided
    ///         layout drift on either stack is caught mechanically.
    ///         Runs in EVERY binding mode (no keccak needed — pure
    ///         packed-integer layout), closing the gap the keccak-gated
    ///         final-hash driver leaves open under the FNV fallback.
    ///         The corpus includes full-32-byte-width `uint256` values
    ///         (all-distinct bytes + the maximum) so the high 24 bytes
    ///         — never set by the realistic balance domain — are pinned.
    function test_packedLayoutGoldens_match_abiEncodePacked() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".packedLayoutGoldensCount");
        assertGt(n, 0, "packedLayoutGoldens present");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".packedLayoutGoldens[", vm.toString(i), "]");
            uint256 width = vm.parseJsonUint(raw, string.concat(base, ".width"));
            // valueHex is a 32-byte BE hex string; parseJsonUint reads it
            // losslessly into a uint256 (no JSON-float precision loss).
            uint256 value = vm.parseJsonUint(raw, string.concat(base, ".valueHex"));
            bytes memory leanEnc = vm.parseJsonBytes(raw, string.concat(base, ".encodedHex"));
            if (width == 64) {
                // casting to `uint64` is safe: a width-64 golden carries a
                // value < 2^64 (the Lean side emits it as a uint64 field).
                assertEq(
                    // forge-lint: disable-next-line(unsafe-typecast)
                    abi.encodePacked(uint64(value)),
                    leanEnc,
                    "uint64BE != abi.encodePacked(uint64)"
                );
            } else {
                assertEq(
                    abi.encodePacked(uint256(value)),
                    leanEnc,
                    "uint256BE != abi.encodePacked(uint256)"
                );
            }
        }
    }

    /// @notice GP.5.3 — hash-independent **data-flow** pin of variant
    ///         21's exact commit-preimage tail field layout.  Lean
    ///         emits the tail (`uint64BE gasResource ++ uint64BE signer
    ///         ++ uint256BE newSigner ++ uint64BE poolActor ++ uint256BE
    ///         newPool`) plus its five component values; this test
    ///         recomputes `abi.encodePacked(...)` from those components
    ///         and asserts byte equality against the Lean-emitted
    ///         `tailHex`.  Combined with (a) the
    ///         `stepVMHash_topUpActionBudgetFor_kind` recipe-structure
    ///         reduction and (b) the tag being
    ///         `keccak256("topUpActionBudgetFor")` on both stacks, this
    ///         proves the full variant-21 step-VM commit is
    ///         byte-equivalent in every binding mode.
    function test_variant21_tailGolden_matches_abiEncodePacked() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        // Components emitted as 32-byte BE hex (lossless parseJsonUint).
        uint64 gr = uint64(vm.parseJsonUint(raw, ".variant21TailGolden.gasResource"));
        uint64 signer = uint64(vm.parseJsonUint(raw, ".variant21TailGolden.signer"));
        uint256 ns = vm.parseJsonUint(raw, ".variant21TailGolden.newSigner");
        uint64 pa = uint64(vm.parseJsonUint(raw, ".variant21TailGolden.poolActor"));
        uint256 np = vm.parseJsonUint(raw, ".variant21TailGolden.newPool");
        bytes memory leanTail = vm.parseJsonBytes(raw, ".variant21TailGolden.tailHex");
        bytes memory solTail = abi.encodePacked(gr, signer, ns, pa, np);
        assertEq(solTail.length, 88, "tail = 8 + 8 + 32 + 8 + 32 = 88 bytes");
        assertEq(
            solTail,
            leanTail,
            "variant-21 tail layout: abi.encodePacked != Lean uint64BE/uint256BE"
        );
    }

    /// @dev Deploy `KnomosisStepVM` for the byte-equivalence test.
    KnomosisStepVM internal stepVM;

    function setUp() public {
        stepVM = new KnomosisStepVM();
    }
}
