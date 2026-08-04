// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {KnomosisStepVMRoot} from "src/contracts/KnomosisStepVMRoot.sol";
import {SmtMultiVerifier} from "src/lib/SmtMultiVerifier.sol";
import {StepWrites} from "src/lib/StepWrites.sol";
import {StepVMRootProbeHarness} from "test/utils/StepVMRootProbeHarness.sol";

/// @title StepVMRootMultiCrossCheck
/// @notice **The multiproof entry point, checked against Lean.**
///
/// @dev    `executeStepToRootMulti` adjudicates a step from a
///         deduplicating pre-root multiproof: one opening per CELL
///         against the pre-root with a shared sibling list, rather
///         than the retired `executeStepToRoot`'s one per WRITE
///         against a running root.
///
///         The agreement is against LEAN: the corpus's
///         `multiProofGoldens` column is what says this stack's merged
///         walk and Lean's `verifierPostRootMulti` compute the same
///         root, over the same twenty probes the retired chained entry
///         point was checked on.
///
///         While both entry points existed this suite also asserted
///         they agreed WITH EACH OTHER — the check that distinguished
///         "the multiproof works" from "the multiproof and the chained
///         fold both work, differently".  It passed on all twenty
///         probes, and it retired with its second operand; the corpus
///         keeps the same evidence one layer up, since Lean asserts
///         the two columns agree before it publishes either.
///
///         **Every corpus walk here reports EVERY failing probe**, not
///         the first.  A fail-fast walk understates a break: when the
///         amount head widened to 32 bytes and three `StepPlan` offsets
///         were left behind, the walk named probe 9 and stopped, so the
///         defect read as one variant's when it was every grant-bearing
///         variant's.  Establishing that took hand-run mutations; it is
///         now the failure message.  Reverts are caught for the same
///         reason and more urgently — a value mismatch at least names
///         its probe, whereas a revert escaping the loop reported
///         `FrontierMissingCell(2)` and identified no probe at all.
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
        string memory report = "";
        uint256 bad = 0;
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            (bool ok, bytes32 got, bytes memory err) = _tryProbe(raw, base);
            bytes32 want = probePostRoot(raw, base);
            if (ok && got == want) continue;
            bad++;
            report = _note(
                report, raw, base,
                ok
                    ? string.concat(
                        "got ", vm.toString(got), ", want ", vm.toString(want))
                    : string.concat("reverted ", vm.toString(err))
            );
        }
        _reportProbes("post-roots disagreeing with Lean", report, bad, n);
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
        string memory report = "";
        uint256 bad = 0;
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            (bool ok, bytes32 got, bytes memory err) = _tryProbe(raw, base);
            if (ok && got != probePreRoot(raw, base)) continue;
            bad++;
            report = _note(
                report, raw, base,
                ok
                    ? string.concat("the fold left the root at ", vm.toString(got))
                    : string.concat("reverted ", vm.toString(err))
            );
        }
        _reportProbes("probes whose fold did not move the root", report, bad, n);
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
        string memory report = "";
        uint256 bad = 0;
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
            (bool ok, bytes32 got, bytes memory err) = _tryCall(
                raw, base, cells, probeGapMask(raw, base), probeSiblings(raw, base)
            );
            bytes32 want = probePostRoot(raw, base);
            if (ok && got == want) continue;
            bad++;
            report = _note(
                report, raw, base,
                ok
                    ? string.concat(
                        "reversed to ", vm.toString(got), ", want ", vm.toString(want))
                    : string.concat("reversed frontier reverted ", vm.toString(err))
            );
        }
        _reportProbes("probes a reversed frontier changed", report, bad, n);
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

    /// @notice The adjudicability predicate is false on exactly the
    ///         bulk pair and unknown kinds.
    ///
    /// @dev    Mirrors `FaultProof.faultProofAdjudicable_eq_false_iff`.
    ///         Stated over the whole frozen range so ADDING a variant
    ///         without deciding its adjudicability fails here.
    ///
    ///         Inherited from the retired chained suite: the exclusion
    ///         is a property of the write set, not of the opening
    ///         scheme, so it outlives the entry point that first
    ///         asserted it.
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
    /* The frontier bound                                         */
    /* ---------------------------------------------------------- */

    /// @notice **The opening cap is derived from the write set, and
    ///         every corpus probe sits under it.**
    ///
    /// @dev    `assertConsistent` asks `deriveWriteSet` itself rather
    ///         than restating a literal, so a variant whose write set
    ///         grew past the cap fails at deploy time instead of
    ///         rejecting honest bundles at runtime — which on a
    ///         terminal step costs the responsible party the game by
    ///         timeout.  Checked here alongside the two facts that make
    ///         the bound meaningful: the widest frontier is what the
    ///         plan said it was, and no probe exceeds it.
    function test_the_opening_cap_is_derived_from_the_write_set() public view {
        vmRoot.assertConsistent();
        // `depositWithFee` writes six cells; plus the policy cell.
        assertEq(vmRoot.widestFrontier(new bytes(128)), 7, "widest frontier");
        assertLe(
            vmRoot.widestFrontier(new bytes(128)),
            vmRoot.MAX_CELL_OPENINGS(),
            "the cap must exceed the widest frontier"
        );

        if (!fixtureExists(STEP_VM_FIXTURE)) return;
        string memory raw = readFixture(STEP_VM_FIXTURE);
        uint256 n = vm.parseJsonUint(raw, ".multiProofGoldensCount");
        uint256 cap = vmRoot.widestFrontier(new bytes(128));
        string memory report = "";
        uint256 bad = 0;
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            uint256 cells = vm.parseJsonUint(raw, string.concat(base, ".cellCount"));
            if (cells <= cap) continue;
            bad++;
            report = _note(
                report, raw, base,
                string.concat(
                    "opens ", vm.toString(cells), " cells, cap ", vm.toString(cap))
            );
        }
        _reportProbes("probes exceeding the derived widest frontier", report, bad, n);
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

    /* ---------------------------------------------------------- */
    /* Revert-tolerant probing, for the corpus walks               */
    /* ---------------------------------------------------------- */

    /// @dev `_call`, but returning the failure instead of raising it.
    ///
    ///      The corpus walks need this and the negative controls must
    ///      NOT have it: a control asserts one specific revert and wants
    ///      `vm.expectRevert` to see it, whereas a walk that stops at the
    ///      first bad probe reports the corpus as one broken entry when
    ///      several may be broken.  Both go through
    ///      `encodeMultiProbeCall`, so the two paths cannot drift in what
    ///      they actually send.
    ///
    ///      A revert is caught rather than allowed to propagate because
    ///      it is the MORE opaque failure of the two: a value mismatch at
    ///      least names its probe, while `FrontierMissingCell(2)` escaping
    ///      the loop names a cell index in an unidentified probe.
    ///
    ///      The returndata is reported as raw hex rather than decoded to
    ///      an error name.  Decoding would need a selector table, and a
    ///      table that fell behind the contract's errors would mislabel
    ///      the failure it exists to explain — worse than four bytes the
    ///      reader can grep for.
    function _tryCall(
        string memory raw,
        string memory base,
        KnomosisStepVMRoot.OpenedCell[] memory cells,
        bytes memory gapMask,
        bytes memory siblings
    ) private view returns (bool ok, bytes32 root, bytes memory err) {
        bytes memory ret;
        (ok, ret) = address(vmRoot).staticcall(
            encodeMultiProbeCall(raw, base, cells, gapMask, siblings)
        );
        if (ok) root = abi.decode(ret, (bytes32));
        else err = ret;
    }

    /// @dev `_tryCall` on the probe's own published frontier and wire.
    function _tryProbe(string memory raw, string memory base)
        private
        view
        returns (bool ok, bytes32 root, bytes memory err)
    {
        return _tryCall(
            raw, base, loadOpenedCells(raw, base),
            probeGapMask(raw, base), probeSiblings(raw, base)
        );
    }

    /// @dev Append one probe's failure to a running report, naming the
    ///      VARIANT as well as the index — the index says where to look
    ///      and the variant says what shape broke, which is what turns a
    ///      list of failures into a diagnosis.
    function _note(
        string memory report,
        string memory raw,
        string memory base,
        string memory detail
    ) private pure returns (string memory) {
        return string.concat(
            report, "\n  ", base, " (",
            vm.parseJsonString(raw, string.concat(base, ".variant")),
            "): ", detail
        );
    }

    /// @dev Fail once, with every probe that failed.
    function _reportProbes(
        string memory what,
        string memory report,
        uint256 bad,
        uint256 n
    ) private pure {
        assertTrue(
            bytes(report).length == 0,
            string.concat(
                what, ": ", vm.toString(bad), " of ", vm.toString(n),
                " probes:", report
            )
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
    ///
    ///      Spelled out here rather than reusing `CBEEncode.amountValue`
    ///      on purpose: this builds the FORGERY the verifier must
    ///      reject, so it has to be able to construct a value the
    ///      production encoder would not — and that only works while it
    ///      owns its own bytes.  It must still be WELL-FORMED, or the
    ///      test would prove the shape check works rather than the
    ///      pre-root check.
    function _amountValue(uint256 n) private pure returns (bytes memory out) {
        out = new bytes(33);
        out[0] = 0x06;
        uint256 v = n;
        for (uint256 i = 0; i < 32; i++) {
            out[1 + i] = bytes1(uint8(v & 0xFF));
            v >>= 8;
        }
    }
}
