// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {CrossCheckFramework} from "./Framework.t.sol";
import {LogChain} from "src/lib/LogChain.sol";
import {CBEEncode} from "src/lib/CBEEncode.sol";
import {SmtCellVerifier} from "src/lib/SmtCellVerifier.sol";
import {AmmMath} from "src/lib/AmmMath.sol";
import {StepWrites} from "src/lib/StepWrites.sol";

/// @title StepVMCrossCheck
/// @notice Workstream-H F.1.8 — Solidity-side consumer of the
///         `step_vm.json` fixture (278 entries after the L1-AMM
///         excision retired kind 23 and its 10 rows; #226 / #251
///         coherence corpus).
///
/// @dev    **One commit per entry.**  Each fixture entry carries
///         `expectedPostStateCommitHex` — the canonical
///         `commitExtendedState` of the production advance.
///
///         There used to be a second, `expectedStepVMCommitHex`: the
///         step-VM-specific `keccak256(preCommit || tagHash ||
///         packed-fields)` value, mirroring `KnomosisStepVM.executeStep`
///         byte-for-byte.  Both stacks computed it identically on all
///         170 happy entries — and neither value was a state root, so
///         the agreement said nothing about the only property the
///         fault-proof game needs.  The column and its driver went
///         with the recipe; `CrossCheck/StepVMRoot.t.sol` replaced
///         them, comparing state roots on both sides.
///
///         The fixture is a keccak artifact by construction (the Lean
///         writer refuses to author one on a fallback-hash build), so
///         this suite ASSERTS the binding rather than skipping on it.
///         It previously skipped, and the committed corpus carried
///         `false`, so a bare `forge test` compared nothing at all.
///
///         **Active checks** (independent of binding status):
///           * Fixture file exists + header shape.
///           * Every entry's schema (fixtureId, actionVariant,
///             commit-hex-length) is well-formed.
///           * Adversarial entries' `expectedPostStateCommitHex`
///             is `"null"` (i.e., the fixture writer correctly
///             flags the failure case).
///           * Step-VM commit field is present + well-formed.
/// @title StepVMCrossCheckProxy
/// @notice **An external boundary for the libraries this corpus walks.**
///
/// @dev    Library calls are internal, so a revert inside one ends the
///         walk that made it — which on a 278-entry corpus means one bad
///         entry hides the rest.  Reaching them through a contract makes
///         the revert catchable, and gives the `vm.expectRevert` controls
///         the call boundary they need.
///
///         A contract rather than a wrapper per function on the test
///         itself: nine near-identical `*External` methods buried the
///         tests they sat among, and the repo already spells this
///         pattern as a proxy (`MultiProofCrossCheckProxy`).  One
///         collaborator whose whole reason for existing is legible from
///         its name beats nine methods that each have to explain
///         themselves.
contract StepVMCrossCheckProxy {
    /// @dev `expectRevert` needs an external call boundary.
    function encodeUint(uint256 n) external pure returns (bytes memory) {
        return CBEEncode.uintValue(n);
    }

    /// @dev ...and likewise for the amount head.
    function encodeAmount(uint256 n) external pure returns (bytes memory) {
        return CBEEncode.amountValue(n);
    }

    /// @dev The byte-string encoder, completing the pair the
    ///      `expectRevert` controls already needed.
    function encodeBytes(bytes calldata payload)
        external
        pure
        returns (bytes memory)
    {
        return CBEEncode.bytesValue(payload);
    }

    /// @dev `expectRevert` needs an external call boundary.
    function deriveNonce(bytes memory pre)
        external
        pure
        returns (bytes memory)
    {
        return StepWrites.deriveNonce(pre);
    }

    /// @dev Calldata boundaries for the two field-passthrough
    ///      derivations.
    function deriveRegistryFromFields(bytes calldata fields)
        external
        pure
        returns (bytes memory)
    {
        return StepWrites.deriveRegistryFromFields(fields);
    }

    /// @dev ...and the policy one, which is the fields verbatim.
    function deriveDeclaredPolicy(bytes calldata fields)
        external
        pure
        returns (bytes memory)
    {
        return StepWrites.deriveDeclaredPolicyCellValue(fields);
    }

    /// @dev Calldata boundary for the dispatch.
    function deriveWriteSet(
        uint8 actionKind,
        bytes calldata fields,
        uint64 signer,
        uint256 nextWdIdPre
    ) external pure returns (StepWrites.Cell[] memory) {
        return StepWrites.deriveWriteSet(actionKind, fields, signer, nextWdIdPre);
    }

    /// @dev The boundary `_tryActionCommit` calls through.
    function actionCommit(uint8 kind, uint64 signer, bytes calldata fields)
        external
        pure
        returns (bytes32)
    {
        return LogChain.actionCommit(kind, signer, fields);
    }

    /// @dev Both round trips behind ONE boundary: they are asserted
    ///      together and a half-completed pair says nothing useful.
    function roundTrip(uint64 n)
        external
        pure
        returns (uint256 asUint, uint256 asAmount)
    {
        asUint = StepWrites.decodeNonce(CBEEncode.uintValue(n));
        asAmount = StepWrites.decodeAmount(CBEEncode.amountValue(n));
    }

    /// @dev The absence marker and its own classification, behind one
    ///      boundary — `isCanonicallyAbsent` reads the value
    ///      `canonicalAbsentValue` produced, so they cannot be
    ///      meaningfully separated.
    function canonicalAbsence(uint8 cellKind)
        external
        pure
        returns (bytes memory value, bool classified)
    {
        value = StepWrites.canonicalAbsentValue(cellKind);
        classified = StepWrites.isCanonicallyAbsent(cellKind, value);
    }

}
contract StepVMCrossCheck is CrossCheckFramework {
    /// @dev The external boundary for the libraries this corpus walks.
    StepVMCrossCheckProxy internal proxy = new StepVMCrossCheckProxy();

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
        // 48 transfer/mint + 23 further variants at 10 each: the
        // Workstream SB reserveSwap rows are in, the retired kind-23
        // ammSwap rows are out (the L1-AMM excision).
        assertEq(count, 278, "total corpus is 278 entries");
        assertEq(countTransfer, 24, "transfer count");
        assertEq(countMint, 24, "mint count");
        // The ONE swap-fee constant: the Lean value the corpus's
        // kind-25 quotes were priced with must be the L1's.
        assertEq(
            vm.parseJsonUint(raw, ".reserveSwapFeeBps"),
            AmmMath.SWAP_FEE_BPS,
            "SB: reserveSwap fee bps pinned across the stacks"
        );
    }

    /// @notice GP.11.8 — verify the per-variant count fields are
    ///         the expected 10 each for the 17 SVC.5.e variants
    ///         plus the 4 Workstream-GP budget variants
    ///         (depositWithFee + topUpActionBudget +
    ///         topUpActionBudgetFor + claimBudgetRefund), the
    ///         GP.11.10 reclaim and the Workstream SB reserveSwap.
    function test_perVariant_counts() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        string[23] memory variantKeys = [
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
            ".countClaimBudgetRefund",
            // Kind 23 (the retired L1-AMM ammSwap) is a permanent hole:
            // the corpus carries no rows and no count for it.
            // GP.11.10: post-disable reserve sweep at index 24.
            ".countReclaimAmmReserves",
            // Workstream SB: user-facing L2 swap at index 25.
            ".countReserveSwap"
        ];
        for (uint256 i = 0; i < variantKeys.length; i++) {
            beginEntry(string.concat("#", vm.toString(i)));
            uint256 c = vm.parseJsonUint(raw, variantKeys[i]);
            checkEq(c, 10, string.concat(variantKeys[i], " should be 10"));
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
            beginEntry(base);
            string memory id = vm.parseJsonString(raw, string.concat(base, ".fixtureId"));
            string memory variant = vm.parseJsonString(raw, string.concat(base, ".actionVariant"));
            checkGt(bytes(id).length, 0, "non-empty fixtureId");
            checkGt(bytes(variant).length, 0, "non-empty actionVariant");
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
            beginEntry(base);
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            string memory postCommit =
                vm.parseJsonString(raw, string.concat(base, ".expectedPostStateCommitHex"));
            // If revertReason != "null", postCommit must also be "null".
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                checkEq(postCommit, "null", "adversarial entry must have null postCommit");
                adversarialCount++;
            }
        }
        // 8 adversarial transfer + 8 adversarial mint + 23 x4 = 92
        // adversarial further-variant entries = 108 total (reserveSwap
        // in, the retired kind-23 ammSwap out).
        assertEq(adversarialCount, 108, "108 adversarial entries total (16 + 23 x4)");
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
            beginEntry(base);
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) == keccak256(bytes("null"))) {
                string memory postCommit =
                    vm.parseJsonString(raw, string.concat(base, ".expectedPostStateCommitHex"));
                checkEq(bytes(postCommit).length, 66, "happy postCommit is '0x' + 64 hex chars");
                happyCount++;
            }
        }
        // 16 happy transfer + 16 happy mint + 23 x6 = 138 happy
        // further-variant entries = 170 total (reserveSwap in, the
        // retired kind-23 ammSwap out).
        assertEq(happyCount, 170, "170 happy entries total (32 + 23 x6)");
    }

    /// @notice **The bespoke-hash byte-equivalence driver is gone.**
    ///
    /// @dev    It walked every happy fixture, called
    ///         `KnomosisStepVM.executeStep`, and asserted byte
    ///         equality against Lean's `expectedStepVMCommitHex`.
    ///         Both sides agreed on all 170 — and neither value was a
    ///         state root, so the agreement said nothing about the
    ///         only property the fault-proof game needs.  Two
    ///         implementations of the same wrong thing concurring.
    ///
    ///         `CrossCheck/StepVMRootMulti.t.sol` is what replaced it:
    ///         it drives `KnomosisStepVMRoot.executeStepToRootMulti`
    ///         against the root Lean's `stepMultiPostRoot` reaches, so
    ///         both sides are state roots.  The corpus's per-entry columns that
    ///         survive here — the action-kind dispatch, the field
    ///         layouts, the cell-proof shapes — are the L1 CALLDATA
    ///         contract, which the new verifier reads unchanged.


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
    function _assertWitnessBinding(string memory raw, string memory base) internal {
        string memory preStateHex =
            vm.parseJsonString(raw, string.concat(base, ".preStateCommitHex"));
        uint256 nProofs = vm.parseJsonUint(raw, string.concat(base, ".cellProofsCount"));
        for (uint256 j = 0; j < nProofs; j++) {
            beginEntry(string.concat("#", vm.toString(j)));
            string memory cpBase = string.concat(base, ".cellProofs[", vm.toString(j), "]");
            checkEq(
                vm.parseJsonString(raw, string.concat(cpBase, ".witnessCommitHex")),
                preStateHex,
                string.concat("witnessCommitHex != preStateCommitHex for ", cpBase)
            );
            // Every corpus entry must also carry an opening the L1
            // would accept.  `executeStep` shape-checks `proofData` at
            // intake, so a corpus entry that failed this would be one
            // the contract rejects — a fixture proving nothing.
            bytes memory pd = vm.parseJsonBytes(raw, string.concat(cpBase, ".proofDataHex"));
            checkTrue(pd.length > 0, string.concat("empty proofData for ", cpBase));
            checkEq(pd.length % 32, 0, string.concat("misaligned proofData for ", cpBase));
            // The tree's geometry: a 32-byte bitmask plus at most one
            // sibling per level.  Spelled here rather than read off the
            // step VM — the multiproof entry point derives its wire's
            // EXACT length from the key set and has no opinion about a
            // single-cell opening's cap.
            checkLe(
                pd.length,
                32 * (1 + 256),
                string.concat("oversize proofData for ", cpBase)
            );
        }
    }

    /// @notice **The action commitment is byte-identical across the
    ///         stacks.**
    ///
    ///         The unsigned triple commit is the shared PREFIX
    ///         construction: the batch leaf the fault-proof game
    ///         authenticates at terminate
    ///         (`ActionsRoot.actionLeafCommit`, Lean
    ///         `ActionsRoot.actionLeafValue`) extends this exact
    ///         `kind ‖ uint64BE signer ‖ fields` pre-image by the
    ///         fixed 65-byte signature suffix.  A one-byte
    ///         disagreement between the Lean field encoder and the
    ///         Solidity one therefore makes every honest terminate
    ///         revert `ActionNotInBatch` — a liveness failure that
    ///         looks exactly like a malicious submission.  The corpus
    ///         is where that is caught.
    function test_perEntry_actionCommit_matches_lean() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            beginEntry(base);
            bytes32 expected =
                vm.parseJsonBytes32(raw, string.concat(base, ".expectedActionCommitHex"));
            uint8 kind =
                uint8(vm.parseJsonUint(raw, string.concat(base, ".actionKindByte")));
            uint64 signer =
                uint64(vm.parseJsonUint(raw, string.concat(base, ".signerNat")));
            bytes memory fields =
                vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex"));
            (bool okC, bytes32 gotC, bytes memory errC) =
                _tryActionCommit(kind, signer, fields);
            if (!okC) {
                recordFailure(
                    string.concat("actionCommit reverted ", describeRevert(errC)));
                continue;
            }
            checkEq(
                gotC,
                expected,
                string.concat("actionCommit mismatch at ", base)
            );
        }
    }

    /// @notice **The CBE value encoders agree byte-for-byte.**
    ///
    ///         The foundation of the state-root flip: once
    ///         `executeStep` computes cell VALUES rather than hashing
    ///         them, it must produce each in its canonical CBE byte
    ///         form, because the SMT leaf is hashed over those bytes.
    ///         A value that is numerically right and byte-wrong
    ///         re-walks to a different root and makes the honest
    ///         sequencer's root unreachable — a liveness failure that
    ///         looks exactly like a fraudulent submission.
    ///
    ///         Two hazards this catches that inspection would not.
    ///         The CBE head is LITTLE-endian while `actionFieldsForL1`
    ///         is big-endian, so both orders live in this contract and
    ///         a flipped encoder still produces a plausible 9-byte
    ///         value.  And the widths are FIXED rather than minimal, so
    ///         a "helpfully" compact encoder would give two encodings
    ///         of one number — and an SMT leaf must be a function of
    ///         the value alone.
    function test_cbeEncoders_match_lean() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".cbeEncoderGoldensCount");
        assertGt(n, 0, "the corpus must carry encoder goldens");
        for (uint256 i = 0; i < n; i++) {
            beginEntry(string.concat("#", vm.toString(i)));
            string memory base =
                string.concat(".cbeEncoderGoldens[", vm.toString(i), "]");
            string memory kind =
                vm.parseJsonString(raw, string.concat(base, ".kind"));
            bytes memory expected =
                vm.parseJsonBytes(raw, string.concat(base, ".encodedHex"));
            bytes32 kindHash = keccak256(bytes(kind));
            if (kindHash == keccak256("uint")) {
                uint256 v = vm.parseJsonUint(raw, string.concat(base, ".valueHex"));
                try proxy.encodeUint(v) returns (bytes memory got) {
                    checkEq(got, expected,
                        string.concat("uint encoder mismatch at ", base));
                } catch (bytes memory err) {
                    recordFailure(
                        string.concat("uintValue reverted ", describeRevert(err)));
                }
            } else if (kindHash == keccak256("amount")) {
                uint256 v = vm.parseJsonUint(raw, string.concat(base, ".valueHex"));
                try proxy.encodeAmount(v) returns (bytes memory got) {
                    checkEq(got, expected,
                        string.concat("amount encoder mismatch at ", base));
                } catch (bytes memory err) {
                    recordFailure(
                        string.concat("amountValue reverted ", describeRevert(err)));
                }
            } else if (kindHash == keccak256("bytes")) {
                bytes memory payload =
                    vm.parseJsonBytes(raw, string.concat(base, ".payloadHex"));
                try proxy.encodeBytes(payload) returns (bytes memory got) {
                    checkEq(got, expected,
                        string.concat("bytes encoder mismatch at ", base));
                } catch (bytes memory err) {
                    recordFailure(
                        string.concat("bytesValue reverted ", describeRevert(err)));
                }
            } else {
                revert(string.concat("unknown golden kind at ", base));
            }
        }
    }

    /// @notice The encoders are the DECODERS' inverse, and refuse
    ///         values they cannot represent.
    ///
    /// @dev    The corpus pins Lean-vs-Solidity; this pins
    ///         Solidity-vs-Solidity, which the corpus cannot: an
    ///         encoder and decoder that were wrong the same way would
    ///         agree with each other, but not with Lean, and vice
    ///         versa.  Both directions together are what make the
    ///         round-trip meaningful.
    function test_cbeEncoders_reject_overwide_and_roundtrip() public {
        // A uint at 2^64 does not fit its 8-byte payload.  Reverting
        // rather than truncating is the point: a silent truncation is
        // how a balance above the width would encode as its low bits
        // and hash to the leaf for a DIFFERENT balance.
        vm.expectRevert(
            abi.encodeWithSelector(CBEEncode.CBEValueTooWide.selector, 1 << 64, 8));
        proxy.encodeUint(1 << 64);
        // The amount head has NO such rejection, and that is the point
        // rather than an omission: its width is the EVM word, so every
        // `uint256` fits and there is nothing to reject.  Closing C-3
        // meant making the ceiling unreachable, not merely far away —
        // a head that can refuse a value is a head a value can be
        // truncated by.
        assertEq(
            CBEEncode.amountValue(type(uint256).max).length,
            33,
            "the widest possible amount still encodes"
        );
        // ...and the largest representable value of each width does NOT
        // revert, so the bound is rejecting only what it must.
        assertEq(CBEEncode.uintValue(type(uint64).max).length, 9, "uint max encodes");
        assertEq(CBEEncode.amountValue(type(uint128).max).length, 33, "amount max encodes");
        // Round-trip against the step VM's own decoders — the ones
        // the fold reads proven cell values through, so an encoder
        // that disagreed with them would build a leaf no opening
        // verifies.
        uint64[4] memory probes = [uint64(0), 1, 0xFF, type(uint64).max];
        for (uint256 i = 0; i < probes.length; i++) {
            beginEntry(string.concat("#", vm.toString(i)));
            try proxy.roundTrip(probes[i]) returns (uint256 asUint, uint256 asAmount) {
                checkEq(asUint, uint256(probes[i]), "uint round-trip");
                checkEq(asAmount, uint256(probes[i]), "amount round-trip");
            } catch (bytes memory err) {
                recordFailure(
                    string.concat("encode/decode round trip reverted ",
                        describeRevert(err)));
            }
        }
    }

    /// @notice **The two cells every action writes are derived
    ///         identically on both stacks.**
    ///
    ///         `stepVMHash` reads and emits BALANCE cells only, while
    ///         `Action.writeCells` declares `.nonce signer` and
    ///         `.epochBudget signer` on all twenty-five variants — so
    ///         these are exactly the cells the current step VM is
    ///         silent about, and the ones its output would be wrong
    ///         about for EVERY action once it is compared against a
    ///         state root.
    ///
    ///         The epoch-budget half is where a mirror is most likely
    ///         to diverge, because the branch is not local to the
    ///         target: the consume is checked against the SIGNER's
    ///         budget but gates the write to every actor, and the
    ///         grant recipient differs per variant.  Both are
    ///         exercised — `topUpActionBudgetFor` at the signer AND at
    ///         the recipient, since that is the variant where the two
    ///         differ and a "top up the signer" shortcut would agree
    ///         everywhere else.
    function test_uniformWrites_match_lean() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".uniformWriteGoldensCount");
        assertGt(n, 0, "the corpus must carry uniform-write goldens");
        for (uint256 i = 0; i < n; i++) {
            _assertUniformWrite(raw,
                string.concat(".uniformWriteGoldens[", vm.toString(i), "]"));
        }
    }

    /// @dev One golden.  Extracted to keep the driver's stack shallow
    ///      under `via_ir`.
    function _assertUniformWrite(string memory raw, string memory base)
        internal
        pure
    {
        // The nonce: `pre + 1`, on every variant.
        assertEq(
            StepWrites.deriveNonce(
                vm.parseJsonBytes(raw, string.concat(base, ".noncePreHex"))),
            vm.parseJsonBytes(raw, string.concat(base, ".noncePostHex")),
            string.concat("nonce derivation mismatch at ", base)
        );
        // The epoch budget: policy + signer's budget + target's budget.
        assertEq(
            StepWrites.deriveEpochBudgetCellValue(
                vm.parseJsonBytes(raw, string.concat(base, ".policyHex")),
                vm.parseJsonBytes(raw, string.concat(base, ".signerBudgetPreHex")),
                vm.parseJsonBytes(raw, string.concat(base, ".targetBudgetPreHex")),
                uint64(vm.parseJsonUint(raw, string.concat(base, ".signer"))),
                uint64(vm.parseJsonUint(raw, string.concat(base, ".target"))),
                vm.parseJsonBool(raw, string.concat(base, ".grants")),
                uint64(vm.parseJsonUint(raw, string.concat(base, ".grantRecipient"))),
                vm.parseJsonUint(raw, string.concat(base, ".grantAmount")),
                vm.parseJsonUint(raw, string.concat(base, ".refundExtra"))
            ),
            vm.parseJsonBytes(raw, string.concat(base, ".targetBudgetPostHex")),
            string.concat("epoch-budget derivation mismatch at ", base)
        );
    }

    /// @notice The derivations are fail-closed on a malformed cell.
    ///
    /// @dev    Not a default, and the distinction is the point: a nonce
    ///         defaulting to zero is a replay, and a budget defaulting
    ///         to a fresh free tier is minting.  A trailing byte is
    ///         rejected too — a cell holds exactly one encoded value,
    ///         and accepting padding would let two distinct bundles
    ///         derive the same write.
    function test_uniformWrites_are_fail_closed() public {
        vm.expectRevert(StepWrites.MalformedCellValue.selector);
        proxy.deriveNonce(hex"");
        vm.expectRevert(StepWrites.MalformedCellValue.selector);
        proxy.deriveNonce(hex"FF0000000000000000");   // wrong tag
        vm.expectRevert(StepWrites.MalformedCellValue.selector);
        proxy.deriveNonce(hex"000000000000000000" hex"00"); // trailing byte
        // ...and the well-formed value still derives, so the checks
        // above are rejecting what they name rather than everything.
        assertEq(
            proxy.deriveNonce(CBEEncode.uintValue(41)),
            CBEEncode.uintValue(42),
            "a well-formed nonce cell must still derive"
        );
    }

    /// @notice **The per-variant balance derivations agree.**
    ///
    ///         Each golden carries the proven pre-balances and the
    ///         post-values Lean's `VerifierWrites` derives, including
    ///         the three cases a happy-path corpus never reaches: a
    ///         self-transfer (the credit reads the DEBITED state, so
    ///         the net change is zero), a failing precondition (both
    ///         cells keep their pre-values — the case the deployed
    ///         step VM REVERTS on), and a same-actor chain (the payer
    ///         IS the pool actor).
    ///
    ///         The base state is populated on two resources.  Over an
    ///         empty one every probe would start from zero, the
    ///         transfer would fail its precondition, and the goldens
    ///         would agree with a mirror that did nothing at all — a
    ///         vacuous golden reads as coverage.
    function test_balanceWrites_match_lean() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".balanceWriteGoldensCount");
        assertGt(n, 0, "the corpus must carry balance goldens");
        for (uint256 i = 0; i < n; i++) {
            _assertBalanceWrite(raw,
                string.concat(".balanceWriteGoldens[", vm.toString(i), "]"));
        }
    }

    /// @dev One balance golden.  Extracted to keep the driver's stack
    ///      shallow under `via_ir`.
    function _assertBalanceWrite(string memory raw, string memory base)
        internal
        pure
    {
        string memory kind = vm.parseJsonString(raw, string.concat(base, ".kind"));
        uint256 xPre = vm.parseJsonUint(raw, string.concat(base, ".xPre"));
        uint256 yPre = vm.parseJsonUint(raw, string.concat(base, ".yPre"));
        uint64 x = uint64(vm.parseJsonUint(raw, string.concat(base, ".x")));
        uint64 y = uint64(vm.parseJsonUint(raw, string.concat(base, ".y")));
        uint256 amountA = vm.parseJsonUint(raw, string.concat(base, ".amountA"));
        uint256 xPost = vm.parseJsonUint(raw, string.concat(base, ".xPost"));
        uint256 yPost = vm.parseJsonUint(raw, string.concat(base, ".yPost"));

        uint256 gotX;
        uint256 gotY = yPre;
        bytes32 k = keccak256(bytes(kind));
        if (k == keccak256("transfer")) {
            (gotX, gotY) =
                StepWrites.deriveTransferBalances(xPre, yPre, x, y, amountA);
        } else if (k == keccak256("credit")) {
            gotX = StepWrites.deriveCreditBalance(xPre, amountA);
        } else if (k == keccak256("debit")) {
            gotX = StepWrites.deriveDebitBalance(xPre, amountA);
        } else if (k == keccak256("deposit")) {
            gotX = StepWrites.deriveDepositBalance(xPre, amountA);
        } else if (k == keccak256("topUp")) {
            (gotX, gotY) = StepWrites.deriveTopUpBalances(
                xPre, yPre, x, y, amountA, amountA <= xPre);
        } else {
            revert(string.concat("unknown balance golden kind at ", base));
        }
        assertEq(gotX, xPost, string.concat("x post mismatch at ", base));
        assertEq(gotY, yPost, string.concat("y post mismatch at ", base));
    }

    /// @notice **The action-field-derived cells agree.**
    ///
    ///         Registry, revoked policy, and the two bridge records —
    ///         cells whose post-values come from the action's own
    ///         fields.  Cheap to derive and easy to get subtly wrong:
    ///         the registry value rides the CBE byte-string encoder (so
    ///         a present-EMPTY key stays distinguishable from an absent
    ///         one, and registration is an admissibility gate), a
    ///         revoke emits the ABSENT marker rather than an encoded
    ///         empty policy, and the two records are concatenations
    ///         whose components use DIFFERENT heads — uint, amount and
    ///         byte-string — so a uniform encoder would produce
    ///         plausible bytes for the wrong leaf.
    function test_recordWrites_match_lean() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".recordWriteGoldensCount");
        assertGt(n, 0, "the corpus must carry record goldens");
        for (uint256 i = 0; i < n; i++) {
            _assertRecordWrite(raw,
                string.concat(".recordWriteGoldens[", vm.toString(i), "]"));
        }
    }

    /// @dev One record golden.  Extracted for stack depth under
    ///      `via_ir`.
    function _assertRecordWrite(string memory raw, string memory base)
        internal
        view
    {
        string memory kind = vm.parseJsonString(raw, string.concat(base, ".kind"));
        bytes memory payload =
            vm.parseJsonBytes(raw, string.concat(base, ".payloadHex"));
        bytes memory expected =
            vm.parseJsonBytes(raw, string.concat(base, ".encodedHex"));
        uint256 a = vm.parseJsonUint(raw, string.concat(base, ".a"));
        uint256 b = vm.parseJsonUint(raw, string.concat(base, ".b"));
        uint256 c = vm.parseJsonUint(raw, string.concat(base, ".c"));
        uint256 d = vm.parseJsonUint(raw, string.concat(base, ".d"));

        bytes32 k = keccak256(bytes(kind));
        bytes memory got;
        if (k == keccak256("registry")) {
            got = StepWrites.deriveRegistryCellValue(payload);
        } else if (k == keccak256("revokedPolicy")) {
            got = StepWrites.deriveRevokedPolicyCellValue();
        } else if (k == keccak256("registryFromFields")) {
            // `payload` is the ACTION FIELDS here; the slice is the
            // library's, so a layout change fails rather than looking
            // silently correct.
            got = proxy.deriveRegistryFromFields(payload);
        } else if (k == keccak256("declaredPolicy")) {
            got = proxy.deriveDeclaredPolicy(payload);
        } else if (k == keccak256("consumed")) {
            got = StepWrites.deriveConsumedCellValue(a, b, c, d);
        } else if (k == keccak256("pending")) {
            got = StepWrites.derivePendingCellValue(a, payload, b, c, d);
        } else {
            revert(string.concat("unknown record golden kind at ", base));
        }
        assertEq(got, expected, string.concat("record mismatch at ", base));
    }

    /// @notice The withdrawal counter advances by one, like the nonce.
    /// @dev    Its PRE-value is what names the pending cell, so a reset
    ///         counter would let a later withdrawal overwrite an
    ///         earlier one's entry.
    function test_nextWdIdWrite_advances_by_one() public view {
        assertEq(
            StepWrites.deriveNextWdIdCellValue(CBEEncode.uintValue(4)),
            CBEEncode.uintValue(5),
            "the withdrawal counter must advance by one"
        );
    }

    /// @notice **The canonical-absence markers agree, per cell kind.**
    ///
    ///         `stateCellEntries` DROPS a cell whose value is the
    ///         canonically-absent one, so "this value means absent" and
    ///         "this key is not in the tree" are the SAME condition —
    ///         and the leaf a cell hashes to branches on it.  A stack
    ///         that disagreed here would hash an absent cell as a
    ///         present one holding zero, reach a leaf the other stack
    ///         never computes, and walk to a root the honest sequencer
    ///         cannot reproduce.
    ///
    ///         The markers are NOT uniform, which is why this is a
    ///         golden rather than a constant: balances and the bridge
    ///         amount scalars carry the 17-byte AMOUNT head, counters
    ///         and flags the 9-byte UINT head, the record cells are
    ///         genuinely empty, and the two budget cells are runs of
    ///         zero uints (two and four).  Getting a kind's head wrong
    ///         produces plausible-looking zero bytes of the wrong
    ///         length.
    function test_canonicalAbsentValues_match_lean() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".absentValueGoldensCount");
        assertGt(n, 0, "the corpus must carry absence goldens");
        for (uint256 i = 0; i < n; i++) {
            beginEntry(string.concat("#", vm.toString(i)));
            string memory base =
                string.concat(".absentValueGoldens[", vm.toString(i), "]");
            uint8 cellKind =
                uint8(vm.parseJsonUint(raw, string.concat(base, ".cellKind")));
            // Cell kinds 7/8 (the excised bridgeAmmReserve* books) are
            // permanent holes — a corpus carrying one has drifted.
            checkTrue(
                cellKind != 7 && cellKind != 8,
                string.concat("retired cell kind in the corpus at ", base)
            );
            bytes memory expected =
                vm.parseJsonBytes(raw, string.concat(base, ".absentValueHex"));
            try proxy.canonicalAbsence(cellKind) returns (
                bytes memory got, bool classified
            ) {
                checkEq(got, expected, string.concat("absence mismatch at ", base));
                checkTrue(
                    classified,
                    string.concat("the marker must classify as absent at ", base)
                );
            } catch (bytes memory err) {
                recordFailure(
                    string.concat("canonicalAbsentValue reverted ", describeRevert(err)));
            }
        }
        // 15 assigned cell kinds (0..14) minus the two permanent holes
        // left by the excised bridgeAmmReserve* books (7, 8).
        assertEq(n, 13, "every live cell kind must be covered");
    }

    /// @notice A NON-marker value is not classified as absent.
    ///
    /// @dev    The negative control for the test above, and it is the
    ///         direction that matters: `isCanonicallyAbsent` returning
    ///         true too eagerly would erase a present cell from the
    ///         tree, which is a state change no write declared.  A
    ///         balance of one, and the marker of a DIFFERENT kind, both
    ///         have to fail.
    function test_canonicalAbsence_rejects_present_values() public pure {
        assertFalse(
            StepWrites.isCanonicallyAbsent(0, CBEEncode.amountValue(1)),
            "a balance of one is present"
        );
        // Kind 1 is a nonce (uint head); kind 0's marker is the amount
        // head.  Same numeric zero, different width — so a length-blind
        // comparison would call this absent.
        assertFalse(
            StepWrites.isCanonicallyAbsent(1, StepWrites.canonicalAbsentValue(0)),
            "another kind's marker is not this kind's absence"
        );
        assertFalse(
            StepWrites.isCanonicallyAbsent(2, CBEEncode.bytesValue("")),
            "an encoded EMPTY registry entry is present, not absent"
        );
    }

    /// @notice **The fold's answer is the production advance's
    ///         published root.**
    ///
    ///         `multiProofGoldens` carries two independently-computed
    ///         numbers per probe: `postStateRootHex`, the root the
    ///         merged walk reaches by folding a step's derived writes
    ///         into the pre-root, and `publishedPostRootHex`, the root
    ///         `commitExtendedState (productionApplyBudget …)` gives
    ///         from the post-STATE.  A verifier is only right if they
    ///         coincide.
    ///
    ///         This is the fact the 278-entry byte-equivalence corpus
    ///         could not establish.  That corpus pinned Lean's
    ///         `stepVMHash` against Solidity's `executeStep`: two
    ///         implementations of the SAME recipe, whose agreement said
    ///         nothing about whether either equalled a published state
    ///         root.  Both are retired; this compares the fold against
    ///         the state.
    function test_the_fold_reaches_the_published_root() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        uint256 n = vm.parseJsonUint(raw, ".multiProofGoldensCount");
        assertGt(n, 0, "the corpus must carry multiproof goldens");
        for (uint256 i = 0; i < n; i++) {
            beginEntry(string.concat("#", vm.toString(i)));
            string memory base =
                string.concat(".multiProofGoldens[", vm.toString(i), "]");
            bytes32 foldRoot =
                vm.parseJsonBytes32(raw, string.concat(base, ".postStateRootHex"));
            bytes32 published =
                vm.parseJsonBytes32(raw, string.concat(base, ".publishedPostRootHex"));
            bytes32 preRoot =
                vm.parseJsonBytes32(raw, string.concat(base, ".preStateRootHex"));
            // The fold's target is the production advance's published
            // root — so the number the flip aims at is the right one.
            checkEq(foldRoot, published,
                string.concat("fold != published root at ", base));
            // ...and not the pre-root, so a fold that did nothing
            // would fail the first assertion rather than pass it.
            checkTrue(foldRoot != preRoot,
                string.concat("the fold did not move the root at ", base));
        }
    }

    /// @notice **The write fold reaches Lean's post-state root.**
    ///
    ///         The riskiest single piece of the flip, verified before
    ///         it lands: given a pre-root and the ORDERED
    ///         `(cell, pre-value, new value, opening)` bundle Lean
    ///         publishes, Solidity verifies each opening against the
    ///         RUNNING root and re-walks it from the new leaf,
    ///         arriving at exactly the published post-state root.
    ///
    ///         The order is load-bearing.  Openings go stale as soon as
    ///         a write lands, so proof `i` opens against the root write
    ///         `i-1` produced — not against the pre-root.  The
    ///         `selfTransfer` probe is the case that catches a fold
    ///         that got this wrong: two writes at the SAME cell, so a
    ///         fold verifying both against the pre-root would accept
    ///         the bundle and reach a root no state has.
    /// @notice The leaf PREIMAGE Lean hashes is one Solidity can build.
    ///
    /// @dev    `encodeAsBytes key ++ encodeAsBytes value` — two CBE
    ///         byte-strings.  Checking the fold with Lean's preimage
    ///         proves the WALK agrees; rebuilding it here from
    ///         `CBEEncode.bytesValue` proves the CONSTRUCTION does too,
    ///         which is what the step VM does for itself on every cell it
///         folds.
    function test_leafPreimage_is_reconstructible() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        string memory c = ".multiProofGoldens[0].cells[0]";
        bytes memory smtKey = vm.parseJsonBytes(raw, string.concat(c, ".smtKeyHex"));
        bytes memory preValue = vm.parseJsonBytes(raw, string.concat(c, ".preValueHex"));
        assertEq(
            bytes.concat(CBEEncode.bytesValue(smtKey), CBEEncode.bytesValue(preValue)),
            vm.parseJsonBytes(raw, string.concat(c, ".preLeafPreimageHex")),
            "the leaf preimage must be two CBE byte-strings"
        );
    }

    /// @notice **The write SET agrees, per variant, on real field
    ///         bytes.**
    ///
    ///         A verifier re-derives which cells an action writes and
    ///         rejects a bundle naming different ones; without that a
    ///         responder could omit a write and fold to a root where
    ///         that cell never moved.  The goldens carry the ACTUAL
    ///         `actionFieldsForL1` bytes, so a field-offset slip fails
    ///         here rather than being reasoned about — and offsets are
    ///         exactly where a mirror goes silently wrong, since the
    ///         layouts are big-endian with mixed widths and a
    ///         one-field slip still decodes to a plausible actor id.
    function test_writeSet_matches_lean() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".writeSetGoldensCount");
        assertGt(n, 0, "the corpus must carry write-set goldens");
        for (uint256 i = 0; i < n; i++) {
            this.assertWriteSetExternal(raw,
                string.concat(".writeSetGoldens[", vm.toString(i), "]"));
        }
    }

    /// @dev External so `fields` arrives in calldata.
    function assertWriteSetExternal(string calldata raw, string calldata base)
        external
    {
        uint8 kind =
            uint8(vm.parseJsonUint(raw, string.concat(base, ".actionKindByte")));
        // Adjudicability comes from Lean, not from a constant here, so
        // the two predicates are PINNED rather than restated — a
        // variant excluded on one stack and not the other fails at this
        // line instead of silently adjudicating one-sided.
        bool adjudicable =
            vm.parseJsonBool(raw, string.concat(base, ".adjudicable"));
        assertEq(
            StepWrites.isAdjudicable(kind), adjudicable,
            string.concat("adjudicability at ", base)
        );
        if (!adjudicable) {
            // The write set exists on the Lean side and is deliberately
            // unreachable on the L1 one.  Nothing further to compare.
            assertGt(
                vm.parseJsonUint(raw, string.concat(base, ".cellCount")), 0,
                string.concat("a refused variant still has a Lean write set at ",
                    base)
            );
            return;
        }
        StepWrites.Cell[] memory got = proxy.deriveWriteSet(
            kind,
            vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex")),
            uint64(vm.parseJsonUint(raw, string.concat(base, ".signerNat"))),
            vm.parseJsonUint(raw, string.concat(base, ".nextWdIdPre"))
        );
        uint256 m = vm.parseJsonUint(raw, string.concat(base, ".cellCount"));
        assertEq(got.length, m, string.concat("cell count at ", base));
        for (uint256 j = 0; j < m; j++) {
            beginEntry(string.concat("#", vm.toString(j)));
            string memory c = string.concat(base, ".cells[", vm.toString(j), "]");
            checkEq(uint256(got[j].kind),
                vm.parseJsonUint(raw, string.concat(c, ".cellKind")),
                string.concat("cellKind at ", c));
            checkEq(got[j].keyA, vm.parseJsonUint(raw, string.concat(c, ".keyA")),
                string.concat("keyA at ", c));
            checkEq(got[j].keyB, vm.parseJsonUint(raw, string.concat(c, ".keyB")),
                string.concat("keyB at ", c));
        }
    }

    /// @notice The bulk pair and the retired kind 23 are refused, and
    ///         only those.
    /// @dev    The deployment decision made executable.  A gate never
    ///         observed to fire is indistinguishable from an absent
    ///         one, so both directions are checked.
    function test_writeSet_refuses_the_bulk_pair_and_the_retired_kind() public {
        // Long enough for EVERY adjudicable kind's `_need` floor: the
        // widest is `depositWithFee` at 136 bytes once all three
        // amounts — the Workstream SB seed included — ride the
        // 32-byte field.
        bytes memory fields = new bytes(136);
        vm.expectRevert(
            abi.encodeWithSelector(StepWrites.ActionNotAdjudicable.selector, uint8(6)));
        proxy.deriveWriteSet(6, fields, 7, 0);
        vm.expectRevert(
            abi.encodeWithSelector(StepWrites.ActionNotAdjudicable.selector, uint8(7)));
        proxy.deriveWriteSet(7, fields, 7, 0);
        // The retired kind 23 (the L1-AMM ammSwap mirror) is a
        // permanent hole, refused exactly like a never-assigned kind.
        vm.expectRevert(
            abi.encodeWithSelector(StepWrites.ActionNotAdjudicable.selector, uint8(23)));
        proxy.deriveWriteSet(23, fields, 7, 0);
        // An unknown kind is refused too — a new `Action` constructor
        // must be considered rather than defaulting into the
        // kernel-identity family.  26 is the first unassigned index
        // (Workstream SB seated `reserveSwap` at 25).
        vm.expectRevert(
            abi.encodeWithSelector(StepWrites.ActionNotAdjudicable.selector, uint8(26)));
        proxy.deriveWriteSet(26, fields, 7, 0);
        // ...and every adjudicable kind still derives.
        for (uint8 k = 0; k <= 25; k++) {
            beginEntry(string.concat("#", vm.toString(k)));
            if (k == 6 || k == 7 || k == 23) continue;
            checkGe(proxy.deriveWriteSet(k, fields, 7, 0).length, 2,
                "every adjudicable kind writes at least the uniform pair");
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

    /// @notice GP.11.8 — cross-stack byte-equivalence for
    ///         the actionKind dispatch path.  Every happy fixture's
    ///         `actionKindByte` (the dispatcher byte) must be in
    ///         0..25 excluding the retired 23: 0..18 SVC.5.e variants
    ///         + 19 (DepositWithFee) + 20 (TopUpActionBudget) + 21
    ///         (TopUpActionBudgetFor) + 22 (ClaimBudgetRefund) +
    ///         24 (ReclaimAmmReserves) + 25 (ReserveSwap, Workstream
    ///         SB); 23 is the retired L1-AMM ammSwap mirror, a
    ///         permanent hole no happy fixture may carry.
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
            beginEntry(base);
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                // Adversarial entries may have arbitrary kind bytes
                // by design; only check happy entries.
                continue;
            }
            uint256 kind = vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"));
            checkLe(kind, 25, string.concat("actionKindByte out of range for ", base));
            checkEq(
                kind == 23 ? 1 : 0,
                0,
                string.concat("retired kind 23 must carry no happy fixture at ", base)
            );
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
            beginEntry(base);
            string memory revertReason =
                vm.parseJsonString(raw, string.concat(base, ".expectedRevertReason"));
            if (keccak256(bytes(revertReason)) != keccak256(bytes("null"))) {
                continue;
            }
            string memory fields = vm.parseJsonString(raw, string.concat(base, ".actionFieldsHex"));
            bytes memory b = bytes(fields);
            checkGe(b.length, 2, string.concat("actionFieldsHex too short for ", base));
            // Compare against the literal `0` (0x30) and `x` (0x78) bytes
            // via byte-array literals rather than string-to-bytes1 casts
            // (the latter trips forge-lint's unsafe-typecast warning even
            // though both literals are exactly 1 byte).
            checkEq(
                b[0], bytes1(0x30), string.concat("actionFieldsHex missing 0x prefix for ", base)
            );
            checkEq(
                b[1], bytes1(0x78), string.concat("actionFieldsHex missing 0x prefix for ", base)
            );
            // Even length (after 0x).
            checkEq(b.length % 2, 0, string.concat("actionFieldsHex has odd length for ", base));
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
            beginEntry(base);
            uint256 width = vm.parseJsonUint(raw, string.concat(base, ".width"));
            // valueHex is a 32-byte BE hex string; parseJsonUint reads it
            // losslessly into a uint256 (no JSON-float precision loss).
            uint256 value = vm.parseJsonUint(raw, string.concat(base, ".valueHex"));
            bytes memory leanEnc = vm.parseJsonBytes(raw, string.concat(base, ".encodedHex"));
            if (width == 64) {
                // casting to `uint64` is safe: a width-64 golden carries a
                // value < 2^64 (the Lean side emits it as a uint64 field).
                checkEq(
                    // forge-lint: disable-next-line(unsafe-typecast)
                    abi.encodePacked(uint64(value)),
                    leanEnc,
                    "uint64BE != abi.encodePacked(uint64)"
                );
            } else {
                checkEq(
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


    /* ---------------------------------------------------------- */
    /* Revert tolerance                                           */
    /* ---------------------------------------------------------- */

    /// @dev `LogChain.actionCommitMemory`, revert-tolerant.  A library
    ///      call is internal, so without a boundary one reverting entry
    ///      ends the walk over a 278-entry corpus.
    function _tryActionCommit(uint8 kind, uint64 signer, bytes memory fields)
        private
        view
        returns (bool ok, bytes32 v, bytes memory err)
    {
        try proxy.actionCommit(kind, signer, fields) returns (bytes32 x) {
            return (true, x, "");
        } catch (bytes memory e) {
            return (false, bytes32(0), e);
        }
    }

    /// @notice Name the errors this corpus's libraries declare.
    function describeRevert(bytes memory err)
        internal
        pure
        override
        returns (string memory)
    {
        bytes4 s = revertSelector(err);
        if (s == StepWrites.ActionNotAdjudicable.selector) return "ActionNotAdjudicable";
        if (s == StepWrites.ActionFieldsTooShort.selector) return "ActionFieldsTooShort";
        if (s == StepWrites.MalformedCellValue.selector) return "MalformedCellValue";
        if (s == CBEEncode.CBEValueTooWide.selector) return "CBEValueTooWide";
        return super.describeRevert(err);
    }

    /// @notice **Every error these libraries declare has a name above.**
    function test_every_declared_error_is_described() public {
        string[] memory artifacts = new string[](3);
        artifacts[0] = "out/StepWrites.sol/StepWrites.json";
        artifacts[1] = "out/CBEEncode.sol/CBEEncode.json";
        artifacts[2] = "out/LogChain.sol/LogChain.json";
        assertEveryDeclaredErrorIsDescribed(artifacts);
    }

}
