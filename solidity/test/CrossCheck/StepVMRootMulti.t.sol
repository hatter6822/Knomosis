// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {KnomosisStepVMRoot} from "src/contracts/KnomosisStepVMRoot.sol";
import {SmtMultiVerifier} from "src/lib/SmtMultiVerifier.sol";
import {CBEEncode} from "src/lib/CBEEncode.sol";
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
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            beginEntry(_probeLabel(raw, base));
            try this.probe(loadProbeInput(raw, base)) returns (bytes32 got) {
                checkEq(got, probePostRoot(raw, base), "post-root disagrees with Lean");
            } catch (bytes memory err) {
                recordFailure(string.concat("reverted ", describeRevert(err)));
            }
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
            beginEntry(_probeLabel(raw, base));
            try this.probe(loadProbeInput(raw, base)) returns (bytes32 got) {
                checkTrue(
                    got != probePreRoot(raw, base), "the fold left the root alone");
            } catch (bytes memory err) {
                recordFailure(string.concat("reverted ", describeRevert(err)));
            }
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
            beginEntry(_probeLabel(raw, base));
            ProbeInput memory input = loadProbeInput(raw, base);
            KnomosisStepVMRoot.OpenedCell[] memory cells = input.cells;
            // Reverse: the maximal permutation, and the one a naive
            // implementation reading positionally is most likely to
            // survive by accident on a two-cell frontier.
            for (uint256 a = 0; a < cells.length / 2; a++) {
                (cells[a], cells[cells.length - 1 - a]) =
                    (cells[cells.length - 1 - a], cells[a]);
            }
            input.cells = cells;
            try this.probe(input) returns (bytes32 got) {
                checkEq(
                    got, probePostRoot(raw, base), "a reversed frontier changed the root");
            } catch (bytes memory err) {
                recordFailure(
                    string.concat("reversed frontier reverted ", describeRevert(err)));
            }
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
        ProbeInput memory input = loadProbeInput(raw, base);
        input.cells = dup;
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisStepVMRoot.FrontierLengthMismatch.selector,
                cells.length, dup.length
            )
        );
        this.probe(input);
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
        ProbeInput memory input = loadProbeInput(raw, base);
        input.cells = short_;
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisStepVMRoot.FrontierLengthMismatch.selector,
                cells.length, short_.length
            )
        );
        this.probe(input);
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
        ProbeInput memory input = loadProbeInput(raw, base);
        input.cells = cells;
        this.probe(input);
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
        ProbeInput memory input = loadProbeInput(raw, base);
        input.siblings = short_;
        vm.expectRevert(
            abi.encodeWithSelector(
                SmtMultiVerifier.MultiProofSiblingCount.selector,
                sibs.length, short_.length
            )
        );
        this.probe(input);
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
    function test_isAdjudicable_excludes_exactly_the_bulk_pair() public {
        for (uint8 k = 0; k <= 30; k++) {
            beginEntry(string.concat("#", vm.toString(k)));
            bool expected = k <= 24 && k != 6 && k != 7;
            checkEq(
                StepWrites.isAdjudicable(k), expected,
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
    function test_the_opening_cap_is_derived_from_the_write_set() public {
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
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            beginEntry(_probeLabel(raw, base));
            checkLe(
                vm.parseJsonUint(raw, string.concat(base, ".cellCount")),
                cap,
                "probe exceeds the derived widest frontier"
            );
        }
    }


    /* ---------------------------------------------------------- */
    /* The one call every check goes through                      */
    /* ---------------------------------------------------------- */

    /// @notice Run a probe.
    ///
    /// @dev    External on purpose, and it is the ONLY path to the
    ///         subject.  A corpus walk wraps it in `try` so a reverting
    ///         probe is reported and the walk continues; a negative
    ///         control puts `vm.expectRevert` in front of it so the
    ///         revert is asserted.  `expectRevert` sees a revert
    ///         propagated through a `this.` call, so the two uses differ
    ///         in exactly one property — whether the failure is caught —
    ///         rather than in what they send.
    ///
    ///         Previously these were two functions, and two functions
    ///         with the same argument tuple is precisely where the
    ///         measured call and the checked call drift apart.
    function probe(ProbeInput calldata input) external view returns (bytes32) {
        return vmRoot.executeStepToRootMulti(
            input.preRoot,
            input.actionKind,
            input.actionFields,
            input.signer,
            input.logIndex,
            input.cells,
            input.gapMask,
            input.siblings
        );
    }

    /* ---------------------------------------------------------- */
    /* Naming the reverts                                         */
    /* ---------------------------------------------------------- */

    /// @notice Render this stack's custom errors by name.
    ///
    /// @dev    Every arm matches `Contract.Error.selector`, so RENAMING
    ///         or REMOVING an error breaks the build rather than
    ///         silently mislabelling the failure this exists to
    ///         explain.  The remaining drift — an error ADDED and left
    ///         undescribed — degrades to hex, and
    ///         `test_every_declared_error_is_described` is what stops
    ///         that going unnoticed.
    function describeRevert(bytes memory err)
        internal
        pure
        override
        returns (string memory)
    {
        bytes4 s = revertSelector(err);
        if (s == KnomosisStepVMRoot.WriteSetMismatch.selector) {
            return _withArgs("WriteSetMismatch", err);
        }
        if (s == KnomosisStepVMRoot.TooManyCellOpenings.selector) {
            return _withArgs("TooManyCellOpenings", err);
        }
        if (s == KnomosisStepVMRoot.FrontierMissingCell.selector) {
            return _withArgs("FrontierMissingCell", err);
        }
        if (s == KnomosisStepVMRoot.FrontierLengthMismatch.selector) {
            return _withArgs("FrontierLengthMismatch", err);
        }
        if (s == KnomosisStepVMRoot.PreRootMismatch.selector) {
            return _withArgs("PreRootMismatch", err);
        }
        if (s == StepWrites.MalformedCellValue.selector) {
            return _withArgs("MalformedCellValue", err);
        }
        // Reaches the verifier's ABI through `StepWrites`' encoder, and
        // was missing here until the completeness test below said so —
        // which is the case that test exists for.
        if (s == CBEEncode.CBEValueTooWide.selector) {
            return _withArgs("CBEValueTooWide", err);
        }
        if (s == StepWrites.ActionNotAdjudicable.selector) {
            return _withArgs("ActionNotAdjudicable", err);
        }
        if (s == StepWrites.ActionFieldsTooShort.selector) {
            return _withArgs("ActionFieldsTooShort", err);
        }
        if (s == SmtMultiVerifier.MultiProofTooManyCells.selector) {
            return _withArgs("MultiProofTooManyCells", err);
        }
        if (s == SmtMultiVerifier.MultiProofEmpty.selector) {
            return _withArgs("MultiProofEmpty", err);
        }
        if (s == SmtMultiVerifier.MultiProofNotStrictlySorted.selector) {
            return _withArgs("MultiProofNotStrictlySorted", err);
        }
        if (s == SmtMultiVerifier.MultiProofMaskLength.selector) {
            return _withArgs("MultiProofMaskLength", err);
        }
        if (s == SmtMultiVerifier.MultiProofPadding.selector) {
            return _withArgs("MultiProofPadding", err);
        }
        if (s == SmtMultiVerifier.MultiProofSiblingCount.selector) {
            return _withArgs("MultiProofSiblingCount", err);
        }
        return super.describeRevert(err);
    }

    /// @dev `Name(0x<abi-encoded args>)`.  The arguments stay hex
    ///      because their types are not recoverable from the selector;
    ///      the NAME is what a reader needed.
    function _withArgs(string memory name, bytes memory err)
        private
        pure
        returns (string memory)
    {
        bytes memory args = _body(err);
        return args.length == 0
            ? string.concat(name, "()")
            : string.concat(name, "(", vm.toString(args), ")");
    }

    /// @notice **Every error the verifier path declares has a name in
    ///         `describeRevert`.**
    ///
    /// @dev    Found `CBEValueTooWide` on its first run — an error that
    ///         reaches this ABI through `StepWrites`' encoder and that
    ///         hand-listing the three obvious sources missed.  That is
    ///         the case it exists for.
    function test_every_declared_error_is_described() public {
        string[] memory artifacts = new string[](3);
        artifacts[0] = "out/KnomosisStepVMRoot.sol/KnomosisStepVMRoot.json";
        artifacts[1] = "out/SmtMultiVerifier.sol/SmtMultiVerifier.json";
        artifacts[2] = "out/StepWrites.sol/StepWrites.json";
        assertEveryDeclaredErrorIsDescribed(artifacts);
    }

    /* ---------------------------------------------------------- */
    /* Helpers                                                    */
    /* ---------------------------------------------------------- */

    /// @dev A probe's report label: the index says where to look, the
    ///      VARIANT says what shape broke.  Both, because an index
    ///      alone sends the reader back to the corpus to find out what
    ///      they are looking at.
    function _probeLabel(string memory raw, string memory base)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            base, " (", vm.parseJsonString(raw, string.concat(base, ".variant")), ")");
    }

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
            // casting to 'uint8' is safe because `& 0xFF` has already
            // reduced the operand to its low byte, so the cast is the
            // identity rather than a truncation.  Mirrors
            // `CBEEncode._leBytes`, which this helper reproduces.
            // forge-lint: disable-next-line(unsafe-typecast)
            out[1 + i] = bytes1(uint8(v & 0xFF));
            v >>= 8;
        }
    }

}
