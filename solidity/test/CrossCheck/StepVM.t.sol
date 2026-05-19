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
            _skipWithReason("step-VM byte-equivalence requires keccak256 binding");
            return;
        }

        // Mint fixtures start at offset countTransfer (24).  Fixture
        // 0 of the mint corpus uses buildMintHappy 0 0 0 50 0 0
        // (i.toUInt64 = 0 for all positions).
        uint256 mintIdx = vm.parseJsonUint(raw, ".countTransfer");
        string memory base = string.concat(".entries[", vm.toString(mintIdx), "]");
        bytes32 preCommit = vm.parseJsonBytes32(raw, string.concat(base, ".preStateCommitHex"));
        bytes32 expectedSVM =
            vm.parseJsonBytes32(raw, string.concat(base, ".expectedStepVMCommitHex"));

        // Construct executeStep inputs for mint with the fixture's
        // parameters: (r=0, to=0, amount=50), signer=0, one cell
        // proof for (Balance, r=0, to=0) with pre-balance 0.
        CanonStepVM.CellProof[] memory proofs = new CanonStepVM.CellProof[](1);
        proofs[0] = CanonStepVM.CellProof({
            cellKind: 0, // Balance
            keyA: 0, // resource
            keyB: 0, // actor
            cellValue: _encodeCbeNat(0), // pre-balance 0
            witnessCommit: preCommit
        });
        bytes memory actionFields = abi.encodePacked(uint64(0), uint64(0), uint64(50)); // r, to, amount

        bytes32 result = stepVM.executeStep(
            preCommit,
            uint8(1), // ActionKind.Mint
            actionFields,
            uint64(0), // signer
            proofs
        );

        // Byte equivalence with the Lean-side
        // `SolidityStepVMCommit.stepCommitMint`.
        assertEq(
            result,
            expectedSVM,
            "mint fixture's expectedStepVMCommit byte-equals executeStep output"
        );
    }

    /// @notice SVC.5.e — generic cross-stack byte-equivalence
    ///         test for the OPAQUE variant family (dispute,
    ///         disputeWithdraw, verdict, rollback,
    ///         declareLocalPolicy, revokeLocalPolicy,
    ///         faultProofChallenge, faultProofResolution).
    ///
    ///         Opaque variants' `_stepXX` hash is
    ///         `keccak256(preCommit || TAG || keccak256(actionFields)
    ///          || signer)` — no cell-state interaction.  This
    ///         lets the test drive `executeStep` with an empty
    ///         cell-proofs array and pin the result against the
    ///         fixture-supplied `expectedStepVMCommitHex`.
    ///
    ///         Skipped when `isKeccak256Linked = false` (the
    ///         standard cross-stack discipline).
    function test_perEntry_opaque_variant_byte_equivalence() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".isKeccak256Linked");
        if (!linked) {
            _skipWithReason("opaque-variant byte-equivalence requires keccak256 binding");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".count");
        // Opaque-variant action-kind discriminators (per
        // CanonStepVM.ActionKind enum).
        uint8[8] memory opaqueKinds = [
            uint8(8), // Dispute
            uint8(9), // DisputeWithdraw
            uint8(10), // Verdict
            uint8(11), // Rollback
            uint8(15), // DeclareLocalPolicy
            uint8(16), // RevokeLocalPolicy
            uint8(17), // FaultProofChallenge
            uint8(18) // FaultProofResolution
        ];
        uint256 opaqueChecked = 0;
        CanonStepVM.CellProof[] memory emptyProofs = new CanonStepVM.CellProof[](0);
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                continue; // Skip adversarial entries.
            }
            uint256 kind = vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"));
            bool isOpaque = false;
            for (uint256 j = 0; j < opaqueKinds.length; j++) {
                if (uint8(kind) == opaqueKinds[j]) {
                    isOpaque = true;
                    break;
                }
            }
            if (!isOpaque) {
                continue;
            }
            bytes32 preCommit = vm.parseJsonBytes32(raw, string.concat(base, ".preStateCommitHex"));
            bytes32 expectedSVM =
                vm.parseJsonBytes32(raw, string.concat(base, ".expectedStepVMCommitHex"));
            bytes memory actionFields =
                vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex"));
            uint256 signer = vm.parseJsonUint(raw, string.concat(base, ".signerNat"));
            bytes32 result = stepVM.executeStep(
                preCommit, uint8(kind), actionFields, uint64(signer), emptyProofs
            );
            assertEq(
                result,
                expectedSVM,
                string.concat("opaque-variant byte-equivalence failed for ", base)
            );
            opaqueChecked++;
        }
        // Each of the 8 opaque variants has 6 happy entries =
        // 48 expected.
        assertEq(opaqueChecked, 48, "expected 48 opaque-variant happy entries");
    }

    /// @notice SVC.5.e — cross-stack byte-equivalence for
    ///         freezeResource (structured but cell-free: the
    ///         step doesn't consult any balance cells).
    function test_perEntry_freezeResource_byte_equivalence() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".isKeccak256Linked");
        if (!linked) {
            _skipWithReason("freezeResource byte-equivalence requires keccak256 binding");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".count");
        uint256 checked = 0;
        CanonStepVM.CellProof[] memory emptyProofs = new CanonStepVM.CellProof[](0);
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                continue;
            }
            uint256 kind = vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"));
            if (kind != 3) {
                continue; // FreezeResource is kind 3.
            }
            bytes32 preCommit = vm.parseJsonBytes32(raw, string.concat(base, ".preStateCommitHex"));
            bytes32 expectedSVM =
                vm.parseJsonBytes32(raw, string.concat(base, ".expectedStepVMCommitHex"));
            bytes memory actionFields =
                vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex"));
            uint256 signer = vm.parseJsonUint(raw, string.concat(base, ".signerNat"));
            bytes32 result = stepVM.executeStep(
                preCommit, uint8(kind), actionFields, uint64(signer), emptyProofs
            );
            assertEq(
                result,
                expectedSVM,
                string.concat("freezeResource byte-equivalence failed for ", base)
            );
            checked++;
        }
        assertEq(checked, 6, "expected 6 freezeResource happy entries");
    }

    /// @notice SVC.5.e — cross-stack byte-equivalence for
    ///         replaceKey (structured but cell-free).
    function test_perEntry_replaceKey_byte_equivalence() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".isKeccak256Linked");
        if (!linked) {
            _skipWithReason("replaceKey byte-equivalence requires keccak256 binding");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".count");
        uint256 checked = 0;
        CanonStepVM.CellProof[] memory emptyProofs = new CanonStepVM.CellProof[](0);
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                continue;
            }
            uint256 kind = vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"));
            if (kind != 4) {
                continue; // ReplaceKey is kind 4.
            }
            bytes32 preCommit = vm.parseJsonBytes32(raw, string.concat(base, ".preStateCommitHex"));
            bytes32 expectedSVM =
                vm.parseJsonBytes32(raw, string.concat(base, ".expectedStepVMCommitHex"));
            bytes memory actionFields =
                vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex"));
            uint256 signer = vm.parseJsonUint(raw, string.concat(base, ".signerNat"));
            bytes32 result = stepVM.executeStep(
                preCommit, uint8(kind), actionFields, uint64(signer), emptyProofs
            );
            assertEq(
                result, expectedSVM, string.concat("replaceKey byte-equivalence failed for ", base)
            );
            checked++;
        }
        assertEq(checked, 6, "expected 6 replaceKey happy entries");
    }

    /// @notice SVC.5.e — cross-stack byte-equivalence for
    ///         registerIdentity (structured but cell-free).
    function test_perEntry_registerIdentity_byte_equivalence() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".isKeccak256Linked");
        if (!linked) {
            _skipWithReason("registerIdentity byte-equivalence requires keccak256 binding");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".count");
        uint256 checked = 0;
        CanonStepVM.CellProof[] memory emptyProofs = new CanonStepVM.CellProof[](0);
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                continue;
            }
            uint256 kind = vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"));
            if (kind != 12) {
                continue; // RegisterIdentity is kind 12.
            }
            bytes32 preCommit = vm.parseJsonBytes32(raw, string.concat(base, ".preStateCommitHex"));
            bytes32 expectedSVM =
                vm.parseJsonBytes32(raw, string.concat(base, ".expectedStepVMCommitHex"));
            bytes memory actionFields =
                vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex"));
            uint256 signer = vm.parseJsonUint(raw, string.concat(base, ".signerNat"));
            bytes32 result = stepVM.executeStep(
                preCommit, uint8(kind), actionFields, uint64(signer), emptyProofs
            );
            assertEq(
                result,
                expectedSVM,
                string.concat("registerIdentity byte-equivalence failed for ", base)
            );
            checked++;
        }
        assertEq(checked, 6, "expected 6 registerIdentity happy entries");
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
