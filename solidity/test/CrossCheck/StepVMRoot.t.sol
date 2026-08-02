// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {KnomosisStepVMRoot} from "src/contracts/KnomosisStepVMRoot.sol";
import {StepWrites} from "src/lib/StepWrites.sol";
import {StepVMRootProbeHarness} from "test/utils/StepVMRootProbeHarness.sol";

/// @title StepVMRootCrossCheck
/// @notice **The flip, checked end to end against Lean.**
///
/// @dev    The retired `KnomosisStepVM.executeStep` returned a
///         bespoke per-variant hash living outside state-root space,
///         so the fault proof's terminal comparison — computed value
///         against the disputed state root — never succeeded and an
///         honest sequencer lost every game it correctly defended.
///         `KnomosisStepVMRoot.executeStepToRoot` computes the other
///         side, and this suite is what says it agrees with Lean.
///
///         The 278-entry byte-equivalence corpus cannot establish
///         this: it pins Lean's `stepVMHash` against Solidity's
///         `executeStep` — two implementations of the SAME bespoke
///         recipe, whose agreement says nothing about whether either
///         equals a published root.  Here both sides are state roots.
///
///         What each probe exercises is the WHOLE verifier, not just
///         its fold: the L1 is handed the pre-root, the action, the
///         signer, the log index and a bundle of openings, and must
///         re-derive the cell list, re-derive every cell's post-value,
///         and fold — reaching the root Lean's `stepPostRoot` reaches.
///         Feeding it Lean's `newValue` column would test none of the
///         derivation, and would be unsound in production: those
///         values are the SEQUENCER's computation.
contract StepVMRootCrossCheck is StepVMRootProbeHarness {
    /// @dev The subject.  Deployed rather than linked as a library so
    ///      the calldata boundary is real — `executeStepToRoot` takes
    ///      `calldata` arrays and slices them, which an internal call
    ///      would paper over.
    KnomosisStepVMRoot internal vmRoot;

    function setUp() public {
        vmRoot = new KnomosisStepVMRoot();
    }

    /* ---------------------------------------------------------- */
    /* The end-to-end agreement                                   */
    /* ---------------------------------------------------------- */

    /// @notice **Every probe's fold lands on Lean's post-state root.**
    function test_executeStepToRoot_matches_lean() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        uint256 n = vm.parseJsonUint(raw, ".writeBundleGoldensCount");
        assertGt(n, 0, "the corpus must carry write-bundle goldens");
        for (uint256 i = 0; i < n; i++) {
            string memory base =
                string.concat(".writeBundleGoldens[", vm.toString(i), "]");
            assertEq(
                _runProbe(raw, base),
                probePostRoot(raw, base),
                string.concat("post-root mismatch at ", base)
            );
        }
    }

    /// @notice **The fold moves the root on every probe.**
    ///
    /// @dev    The negative control for the test above: a verifier that
    ///         returned its input unchanged would pass an equality
    ///         against a corpus whose pre- and post-roots happened to
    ///         coincide.  They never do here — every one of the
    ///         twenty-five variants advances the signer's nonce, so a
    ///         no-op implementation fails this loudly, including on the
    ///         probes whose LAW no-ops (`burnNoop`,
    ///         `topUpActionBudgetForSelf`).
    function test_executeStepToRoot_moves_the_root() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        uint256 n = vm.parseJsonUint(raw, ".writeBundleGoldensCount");
        for (uint256 i = 0; i < n; i++) {
            string memory base =
                string.concat(".writeBundleGoldens[", vm.toString(i), "]");
            assertTrue(
                _runProbe(raw, base) != probePreRoot(raw, base),
                string.concat("the fold left the root alone at ", base)
            );
        }
    }

    /* ---------------------------------------------------------- */
    /* Negative controls                                          */
    /* ---------------------------------------------------------- */

    /// @notice **Omitting a write is rejected.**
    ///
    /// @dev    The forgery the re-derived write set exists to stop.  A
    ///         responder that dropped the last opening would fold a
    ///         shorter bundle and reach a root where that cell never
    ///         moved — a root it could then defend.  The verifier
    ///         derives the cell list itself, so a short bundle cannot
    ///         even be parsed as this action's.
    function test_omitting_a_write_reverts() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        string memory base = ".writeBundleGoldens[0]";
        KnomosisStepVMRoot.CellOpening[] memory full = loadOpenings(raw, base);
        KnomosisStepVMRoot.CellOpening[] memory short_ =
            new KnomosisStepVMRoot.CellOpening[](full.length - 1);
        for (uint256 i = 0; i < short_.length; i++) short_[i] = full[i];
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisStepVMRoot.WriteSetLengthMismatch.selector,
                full.length, short_.length
            )
        );
        _call(raw, base, short_);
    }

    /// @notice **A forged pre-value is rejected.**
    ///
    /// @dev    The opening is verified against the RUNNING root with a
    ///         leaf built from exactly the submitted bytes, so claiming
    ///         a balance the state does not hold fails the walk rather
    ///         than deriving a post-value of the responder's choosing.
    function test_forged_pre_value_reverts() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        string memory base = ".writeBundleGoldens[0]";
        KnomosisStepVMRoot.CellOpening[] memory ops = loadOpenings(raw, base);
        // Probe 0 is `transfer`, whose cell 0 is the sender's balance.
        // Inflate it: an amount head over a number the state does not
        // hold.
        ops[0].preValue = _amountValue(1_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisStepVMRoot.BadCellOpening.selector, 0)
        );
        _call(raw, base, ops);
    }

    /// @notice **Reordering the bundle is rejected.**
    ///
    /// @dev    Order is consensus, not convention: the openings are
    ///         CHAINED, so opening `i` is only valid against the root
    ///         write `i-1` produced.  The write-set check catches this
    ///         before the fold does, which is the cheaper failure and
    ///         the one that names the problem.
    function test_reordered_bundle_reverts() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        string memory base = ".writeBundleGoldens[0]";
        KnomosisStepVMRoot.CellOpening[] memory ops = loadOpenings(raw, base);
        (ops[0], ops[1]) = (ops[1], ops[0]);
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisStepVMRoot.WriteSetMismatch.selector, 0)
        );
        _call(raw, base, ops);
    }

    /// @notice **A policy opening naming another cell is rejected.**
    ///
    /// @dev    The policy cell's identity is fixed by the verifier, not
    ///         submitted.  Otherwise a responder could open some other
    ///         cell that happens to hold four uints and pass its bytes
    ///         off as the deployment's budget policy — which selects
    ///         the branch every epoch-budget write takes.
    function test_policy_opening_must_name_the_policy_cell() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        string memory base = ".writeBundleGoldens[0]";
        KnomosisStepVMRoot.CellOpening memory policy = loadPolicyOpening(raw, base);
        policy.keyA = 1;
        vm.expectRevert(KnomosisStepVMRoot.PolicyCellMismatch.selector);
        vmRoot.executeStepToRoot(
            probePreRoot(raw, base),
            uint8(vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"))),
            vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex")),
            uint64(vm.parseJsonUint(raw, string.concat(base, ".signerNat"))),
            vm.parseJsonUint(raw, string.concat(base, ".l2LogIndex")),
            policy,
            loadOpenings(raw, base)
        );
    }

    /// @notice **The two bulk variants are not adjudicable.**
    ///
    /// @dev    Their write set is the actor set at a resource, which an
    ///         L1 holding only the pre-root cannot enumerate:
    ///         `smtCellKey` hashes the cell identity, so balance cells
    ///         at one resource share no key prefix and no subtree
    ///         argument reaches them.  A complete bundle and one
    ///         missing a recipient are indistinguishable — so the
    ///         verifier refuses both rather than adjudicating on a
    ///         coin flip.  Mirrors `FaultProof.FaultProofAdjudicable`.
    function test_bulk_variants_are_refused() public {
        KnomosisStepVMRoot.CellOpening memory policy;
        policy.cellKind = 14;
        policy.proofData = new bytes(32);
        KnomosisStepVMRoot.CellOpening[] memory none_ =
            new KnomosisStepVMRoot.CellOpening[](0);
        // Refused BEFORE any opening is verified, which is why this can
        // pass a policy proof that would not itself verify: a
        // deployment leaning on the fault proof must not authorise
        // these, so reaching them at all is the error.
        uint8[3] memory kinds = [uint8(6), uint8(7), uint8(25)];
        for (uint256 i = 0; i < kinds.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    StepWrites.ActionNotAdjudicable.selector, kinds[i])
            );
            vmRoot.executeStepToRoot(
                bytes32(0), kinds[i], hex"", 7, 0, policy, none_);
        }
    }

    /// @notice The adjudicability predicate is false on exactly the
    ///         bulk pair and unknown kinds.
    ///
    /// @dev    Mirrors `FaultProof.faultProofAdjudicable_eq_false_iff`.
    ///         Stated over the whole frozen range so ADDING a variant
    ///         without deciding its adjudicability fails here.
    function test_isAdjudicable_excludes_exactly_the_bulk_pair() public pure {
        for (uint256 k = 0; k <= 30; k++) {
            bool expected = k <= 24 && k != 6 && k != 7;
            assertEq(
                StepWrites.isAdjudicable(uint8(k)), expected,
                string.concat("adjudicability at kind ", vm.toString(k))
            );
        }
    }

    /* ---------------------------------------------------------- */
    /* Helpers                                                    */
    /* ---------------------------------------------------------- */

    /// @dev Run one probe and return the root the verifier reaches.
    function _runProbe(string memory raw, string memory base)
        private
        view
        returns (bytes32)
    {
        return _call(raw, base, loadOpenings(raw, base));
    }

    /// @dev The call itself, with a caller-supplied bundle so the
    ///      negative controls can perturb it.
    function _call(
        string memory raw,
        string memory base,
        KnomosisStepVMRoot.CellOpening[] memory ops
    ) private view returns (bytes32) {
        return vmRoot.executeStepToRoot(
            probePreRoot(raw, base),
            uint8(vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"))),
            vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex")),
            uint64(vm.parseJsonUint(raw, string.concat(base, ".signerNat"))),
            vm.parseJsonUint(raw, string.concat(base, ".l2LogIndex")),
            loadPolicyOpening(raw, base),
            ops
        );
    }

    /// @dev A CBE amount value, for the forged-balance control.
    function _amountValue(uint256 n) private pure returns (bytes memory out) {
        out = new bytes(17);
        out[0] = 0x01;
        uint256 v = n;
        for (uint256 i = 0; i < 16; i++) {
            out[1 + i] = bytes1(uint8(v & 0xFF));
            v >>= 8;
        }
    }
}
