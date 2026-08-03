// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {KnomosisStepVMRoot} from "src/contracts/KnomosisStepVMRoot.sol";
import {SmtMultiVerifier} from "src/lib/SmtMultiVerifier.sol";
import {StepWrites} from "src/lib/StepWrites.sol";
import {StepVMRootProbeHarness} from "test/utils/StepVMRootProbeHarness.sol";

/// @title StepVMRootMultiCrossCheck
/// @notice **The multiproof entry point, checked against Lean and
///         against its own chained twin.**
///
/// @dev    `executeStepToRootMulti` adjudicates the same step as
///         `executeStepToRoot` from a deduplicating pre-root
///         multiproof: one opening per CELL against the pre-root with
///         a shared sibling list, instead of one per WRITE against the
///         running root.
///
///         Two agreements are asserted, and both are needed.  Against
///         LEAN, because the corpus's `multiProofGoldens` column is
///         what says this stack's merged walk and Lean's
///         `verifierPostRootMulti` compute the same root.  Against the
///         CHAINED entry point, because that is what distinguishes
///         "the multiproof works" from "the multiproof and the chained
///         fold both work, differently" — two consensus surfaces that
///         disagree on one step would each be defensible and the game
///         could not say which was right.
///
///         The negative controls are where the design actually differs.
///         A duplicate cell is not representable (strict ascent after
///         the sort is the distinctness check); a permutation is
///         ACCEPTED and reaches the identical root, which is the
///         chained path's `test_reordered_bundle_reverts` inverted on
///         purpose; and a short wire is refused rather than padded,
///         which is the property the single-cell verifier does not
///         have.
contract StepVMRootMultiCrossCheck is StepVMRootProbeHarness {
    /// @dev The subject.  Deployed rather than linked so the calldata
    ///      boundary is real — the entry point takes `calldata` arrays
    ///      and slices them, which an internal call would paper over.
    KnomosisStepVMRoot internal vmRoot;

    function setUp() public {
        vmRoot = new KnomosisStepVMRoot();
    }

    /* ---------------------------------------------------------- */
    /* The end-to-end agreement                                   */
    /* ---------------------------------------------------------- */

    /// @notice **Every probe's merged fold lands on Lean's post-state
    ///         root.**
    function test_executeStepToRootMulti_matches_lean() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        uint256 n = vm.parseJsonUint(raw, ".multiProofGoldensCount");
        assertGt(n, 0, "the corpus must carry multiproof goldens");
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            assertEq(
                _runProbe(raw, base),
                probePostRoot(raw, base),
                string.concat("post-root mismatch at ", base)
            );
        }
    }

    /// @notice **The two entry points agree on every probe.**
    ///
    /// @dev    Same pre-state, same action, opened two different ways.
    ///         Asserted on THIS stack rather than only in the corpus,
    ///         because the corpus's own check compares two Lean
    ///         computations and this compares two Solidity ones — a
    ///         derivation that drifted between the chained and the
    ///         merged path would satisfy the corpus and fail here.
    function test_the_two_entry_points_agree() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        uint256 n = vm.parseJsonUint(raw, ".multiProofGoldensCount");
        assertEq(
            n, vm.parseJsonUint(raw, ".writeBundleGoldensCount"),
            "the two columns must cover the same probes"
        );
        for (uint256 i = 0; i < n; i++) {
            string memory multi = multiProbeBase(i);
            string memory chained = findProbeBase(
                raw, vm.parseJsonString(raw, string.concat(multi, ".variant")));
            assertEq(
                probePreRoot(raw, multi), probePreRoot(raw, chained),
                "the two columns must share a pre-state"
            );
            assertEq(
                _runProbe(raw, multi),
                vmRoot.executeStepToRoot(
                    probePreRoot(raw, chained),
                    uint8(vm.parseJsonUint(raw, string.concat(chained, ".actionKindByte"))),
                    vm.parseJsonBytes(raw, string.concat(chained, ".actionFieldsHex")),
                    uint64(vm.parseJsonUint(raw, string.concat(chained, ".signerNat"))),
                    vm.parseJsonUint(raw, string.concat(chained, ".l2LogIndex")),
                    loadPolicyOpening(raw, chained),
                    loadOpenings(raw, chained)
                ),
                string.concat("the entry points disagree at ", multi)
            );
        }
    }

    /// @notice **The merged fold moves the root on every probe.**
    ///
    /// @dev    The negative control for the agreements above: a
    ///         verifier returning its input unchanged would satisfy
    ///         both if the corpus's pre- and post-roots ever coincided.
    ///         They never do — every variant advances the signer's
    ///         nonce — so a no-op implementation fails loudly here,
    ///         including on the probes whose LAW no-ops.
    function test_executeStepToRootMulti_moves_the_root() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        uint256 n = vm.parseJsonUint(raw, ".multiProofGoldensCount");
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            assertTrue(
                _runProbe(raw, base) != probePreRoot(raw, base),
                string.concat("the fold left the root alone at ", base)
            );
        }
    }

    /* ---------------------------------------------------------- */
    /* The relaxation                                             */
    /* ---------------------------------------------------------- */

    /// @notice **A permuted frontier reaches the identical root.**
    ///
    /// @dev    The chained path's `test_reordered_bundle_reverts`,
    ///         inverted deliberately.  There, order was consensus:
    ///         opening `i` was only valid against the root write `i-1`
    ///         produced.  Here every opening is against the SAME root,
    ///         so order carries no information and the verifier sorts.
    ///
    ///         The consequence is accepted rather than incidental: two
    ///         calldata encodings become valid for one step.  Harmless
    ///         — nothing signs the bundle, and the game stores only the
    ///         resulting root — and asserted here so it is a known
    ///         property rather than a discovery.
    function test_a_permuted_frontier_reaches_the_same_root() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        uint256 n = vm.parseJsonUint(raw, ".multiProofGoldensCount");
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            KnomosisStepVMRoot.OpenedCell[] memory cells = loadOpenedCells(raw, base);
            // Reverse: the maximal permutation, and the one a naive
            // implementation reading positionally is most likely to
            // survive by accident on a two-cell frontier.
            for (uint256 a = 0; a < cells.length / 2; a++) {
                (cells[a], cells[cells.length - 1 - a]) =
                    (cells[cells.length - 1 - a], cells[a]);
            }
            assertEq(
                _call(raw, base, cells, probeGapMask(raw, base), probeSiblings(raw, base)),
                probePostRoot(raw, base),
                string.concat("a reversed frontier changed the root at ", base)
            );
        }
    }

    /* ---------------------------------------------------------- */
    /* Negative controls                                          */
    /* ---------------------------------------------------------- */

    /// @notice **The same cell twice is rejected.**
    ///
    /// @dev    Strict ascent after the sort is the duplicate check as
    ///         well as the order check, so a duplicate is not
    ///         representable on the wire at all.  That is what retires
    ///         the chained fold's first-occurrence rule: with one
    ///         opening per cell there is nothing to disambiguate.
    ///
    ///         The length check fires first — the frontier's size is
    ///         derived from the key set, and duplicating an entry
    ///         overshoots it — which is the cheaper refusal and the one
    ///         that names the problem.
    function test_the_same_cell_twice_reverts() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        string memory base = _probeWithAtLeast(raw, 2);
        KnomosisStepVMRoot.OpenedCell[] memory cells = loadOpenedCells(raw, base);
        KnomosisStepVMRoot.OpenedCell[] memory dup =
            new KnomosisStepVMRoot.OpenedCell[](cells.length + 1);
        for (uint256 i = 0; i < cells.length; i++) dup[i] = cells[i];
        dup[cells.length] = cells[0];
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisStepVMRoot.FrontierLengthMismatch.selector,
                cells.length, dup.length
            )
        );
        _call(raw, base, dup, probeGapMask(raw, base), probeSiblings(raw, base));
    }

    /// @notice **Omitting a cell is rejected.**
    ///
    /// @dev    The forgery the re-derived frontier exists to stop: a
    ///         responder that dropped a cell would fold a shorter
    ///         frontier and reach a root where that cell never moved.
    function test_omitting_a_cell_reverts() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        string memory base = _probeWithAtLeast(raw, 2);
        KnomosisStepVMRoot.OpenedCell[] memory cells = loadOpenedCells(raw, base);
        KnomosisStepVMRoot.OpenedCell[] memory short_ =
            new KnomosisStepVMRoot.OpenedCell[](cells.length - 1);
        for (uint256 i = 0; i < short_.length; i++) short_[i] = cells[i];
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisStepVMRoot.FrontierLengthMismatch.selector,
                cells.length, short_.length
            )
        );
        _call(raw, base, short_, probeGapMask(raw, base), probeSiblings(raw, base));
    }

    /// @notice **A forged pre-value is rejected.**
    ///
    /// @dev    The pre-side fold is what binds submitted values to the
    ///         published root.  There is no per-opening check to fail
    ///         here — that is the point of the single root comparison —
    ///         so the forgery surfaces as the AGGREGATE missing the
    ///         pre-root.
    function test_a_forged_pre_value_reverts() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        string memory base = findMultiProbeBase(raw, "transfer");
        KnomosisStepVMRoot.OpenedCell[] memory cells = loadOpenedCells(raw, base);
        uint256 target = type(uint256).max;
        for (uint256 i = 0; i < cells.length; i++) {
            if (cells[i].cellKind == 0) {
                target = i;
                break;
            }
        }
        assertLt(target, cells.length, "the transfer probe must open a balance cell");
        cells[target].preValue = _amountValue(1_000_000);
        // The revert carries the pre-root it wanted and the one the
        // forged fold produced, so the expectation names only the
        // selector: the second word is a hash of the tampered input.
        vm.expectPartialRevert(KnomosisStepVMRoot.PreRootMismatch.selector);
        _call(raw, base, cells, probeGapMask(raw, base), probeSiblings(raw, base));
    }

    /// @notice **A wire short by one sibling is rejected, not padded.**
    ///
    /// @dev    The property `SmtCellVerifier.recomputeRootFromLeaf` does
    ///         not have: it substitutes a padding hash when the wire
    ///         runs short and keeps walking, so a truncated proof is a
    ///         silent reinterpretation reaching SOME root.  Here the
    ///         sibling count is derived from the key set before a byte
    ///         is read.
    function test_a_truncated_wire_reverts() public {
        if (!fixtureExists(STEP_VM_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(STEP_VM_FIXTURE);
        string memory base = _probeWithSiblings(raw);
        bytes memory sibs = probeSiblings(raw, base);
        bytes memory short_ = new bytes(sibs.length - 32);
        for (uint256 b = 0; b < short_.length; b++) short_[b] = sibs[b];
        vm.expectRevert(
            abi.encodeWithSelector(
                SmtMultiVerifier.MultiProofSiblingCount.selector,
                sibs.length, short_.length
            )
        );
        _call(raw, base, loadOpenedCells(raw, base), probeGapMask(raw, base), short_);
    }

    /// @notice **The two bulk variants are not adjudicable here either.**
    ///
    /// @dev    A multiproof does not make an unenumerable write set
    ///         enumerable: the bulk pair's cells are the actor set at a
    ///         resource, and `smtCellKey` hashes the cell identity, so
    ///         no subtree argument reaches them from a root.  The
    ///         exclusion is a property of the write set, not of the
    ///         opening scheme, so both entry points refuse the same
    ///         kinds.
    function test_bulk_variants_are_refused() public {
        KnomosisStepVMRoot.OpenedCell[] memory none_ =
            new KnomosisStepVMRoot.OpenedCell[](0);
        uint8[3] memory kinds = [uint8(6), uint8(7), uint8(25)];
        for (uint256 i = 0; i < kinds.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    StepWrites.ActionNotAdjudicable.selector, kinds[i])
            );
            vmRoot.executeStepToRootMulti(
                bytes32(0), kinds[i], hex"", 7, 0, none_, hex"", hex"");
        }
    }

    /* ---------------------------------------------------------- */
    /* Helpers                                                    */
    /* ---------------------------------------------------------- */

    /// @dev The first multiproof probe opening at least `k` cells.
    function _probeWithAtLeast(string memory raw, uint256 k)
        private
        pure
        returns (string memory)
    {
        uint256 n = vm.parseJsonUint(raw, ".multiProofGoldensCount");
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            if (vm.parseJsonUint(raw, string.concat(base, ".cellCount")) >= k) {
                return base;
            }
        }
        revert("no multiproof probe opens enough cells");
    }

    /// @dev The first multiproof probe whose wire carries a sibling.
    function _probeWithSiblings(string memory raw)
        private
        pure
        returns (string memory)
    {
        uint256 n = vm.parseJsonUint(raw, ".multiProofGoldensCount");
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            if (probeSiblings(raw, base).length > 0) return base;
        }
        revert("no multiproof probe carries a sibling");
    }

    /// @dev Run one probe with its published frontier and wire.
    function _runProbe(string memory raw, string memory base)
        private
        view
        returns (bytes32)
    {
        return _call(
            raw, base, loadOpenedCells(raw, base),
            probeGapMask(raw, base), probeSiblings(raw, base)
        );
    }

    /// @dev The call, with caller-supplied frontier and wire so the
    ///      negative controls can perturb either.
    function _call(
        string memory raw,
        string memory base,
        KnomosisStepVMRoot.OpenedCell[] memory cells,
        bytes memory gapMask,
        bytes memory siblings
    ) private view returns (bytes32) {
        return vmRoot.executeStepToRootMulti(
            probePreRoot(raw, base),
            uint8(vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"))),
            vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex")),
            uint64(vm.parseJsonUint(raw, string.concat(base, ".signerNat"))),
            vm.parseJsonUint(raw, string.concat(base, ".l2LogIndex")),
            cells,
            gapMask,
            siblings
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
