// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";
import {SmtCellVerifier} from "src/lib/SmtCellVerifier.sol";
import {SmtMultiVerifier} from "src/lib/SmtMultiVerifier.sol";

/// @title MultiProofCrossCheckProxy
/// @notice Thin external proxy giving `SmtMultiVerifier`'s internal
///         library functions a `calldata`-bearing surface, so the
///         cross-check bodies can pass `bytes memory` decoded from
///         JSON.  Mirrors `SmtCellProofCrossCheckProxy`; named
///         distinctly to avoid ABI collisions across the suite.
contract MultiProofCrossCheckProxy {
    /// @notice Fold a probe's wire from its RAW SMT keys.
    ///
    /// @dev    The `pathIndex` derivation lives here rather than in the
    ///         fixture: the corpus publishes cell keys, and a column of
    ///         precomputed path indices would let a bug in this stack's
    ///         bit reversal be papered over by Lean's.  Deriving on both
    ///         sides is what makes the reversal itself cross-checked.
    function foldFromKeys(
        bytes32[] calldata smtKeys,
        bytes32[] calldata leaves,
        bytes calldata gapMask,
        bytes calldata siblings
    ) external pure returns (bytes32) {
        uint256 m = smtKeys.length;
        uint256[] memory idx = new uint256[](m);
        bytes32[] memory lv = new bytes32[](m);
        for (uint256 i = 0; i < m; ++i) {
            idx[i] = SmtMultiVerifier.pathIndex(smtKeys[i]);
            lv[i] = leaves[i];
        }
        bytes32[256] memory empties = SmtCellVerifier.precomputeEmptySubtreeHashes();
        return SmtMultiVerifier.multiWalk(idx, lv, gapMask, siblings, empties);
    }

    /// @notice The gap count `SmtMultiVerifier` derives from a key set.
    function gapCountOf(bytes32[] calldata smtKeys) external pure returns (uint256) {
        uint256 m = smtKeys.length;
        uint256[] memory idx = new uint256[](m);
        for (uint256 i = 0; i < m; ++i) {
            idx[i] = SmtMultiVerifier.pathIndex(smtKeys[i]);
        }
        return SmtMultiVerifier.gapCount(idx);
    }

    /// @notice This stack's `pathIndex`, for the ordering assertions.
    function pathIndexOf(bytes32 key) external pure returns (uint256) {
        return SmtMultiVerifier.pathIndex(key);
    }
}

/// @title MultiProofCrossCheck
/// @notice Solidity-side consumer of `smt_multi_proof.json` — the
///         non-degenerate cross-stack pin for the MERGED walk.
///
/// @dev    `SmtMultiVerifier` was already pinned against Lean at ONE
///         opened cell, transitively: `m = 1` degenerates to a
///         single-cell opening and `SmtCellVerifier.recomputeRootFromLeaf`
///         is pinned by `smt_cell_proof.json`.  That check is real and it
///         is blind to everything the multiproof exists for — the merge
///         itself, and the post-order in which the merged walk consumes
///         its gaps.  Neither runs at `m = 1`.
///
///         So this corpus. Each probe is a real `ExtendedState`, a real
///         frontier, the wire Lean builds from it, and BOTH roots that
///         wire serves: the pre-state's, which the L1 checks its input
///         against, and the post-state's, which is the answer.  This
///         stack folds the same bytes and must reach the same two
///         values.
///
///         Two of the assertions below are deliberately NOT gated on
///         `isKeccak256Linked`.  The wire's SHAPE — the gap count, the
///         mask length, the sibling count — is a function of the key set
///         alone, and both stacks derive it from the same published
///         keys, whichever hash produced them.  Only the root
///         comparisons need the keccak lane.
contract MultiProofCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "smt_multi_proof.json";

    /// @notice Proxy contract instantiated per-test by the harness.
    MultiProofCrossCheckProxy internal proxy;

    function setUp() public {
        proxy = new MultiProofCrossCheckProxy();
    }

    /* ---------------------------------------------------------- */
    /* Fixture accessors                                          */
    /* ---------------------------------------------------------- */

    /// @dev The JSON path prefix for probe `i`.
    function _probe(uint256 i) internal pure returns (string memory) {
        return string.concat(".probes[", vm.toString(i), "]");
    }

    /// @dev A probe's opened cell keys, in the order Lean published.
    function _keys(string memory raw, uint256 i) internal pure returns (bytes32[] memory ks) {
        string memory p = _probe(i);
        uint256 n = vm.parseJsonUint(raw, string.concat(p, ".cellCount"));
        ks = new bytes32[](n);
        for (uint256 c = 0; c < n; ++c) {
            ks[c] = vm.parseJsonBytes32(
                raw, string.concat(p, ".cells[", vm.toString(c), "].smtKeyHex")
            );
        }
    }

    /// @dev A probe's leaves, `pre` or `post`.
    function _leaves(string memory raw, uint256 i, bool post)
        internal
        pure
        returns (bytes32[] memory ls)
    {
        string memory p = _probe(i);
        string memory field = post ? ".postLeafHex" : ".preLeafHex";
        uint256 n = vm.parseJsonUint(raw, string.concat(p, ".cellCount"));
        ls = new bytes32[](n);
        for (uint256 c = 0; c < n; ++c) {
            ls[c] =
                vm.parseJsonBytes32(raw, string.concat(p, ".cells[", vm.toString(c), "]", field));
        }
    }

    /* ---------------------------------------------------------- */
    /* Shape assertions (binding-independent)                     */
    /* ---------------------------------------------------------- */

    /// @notice Header shape.  The probe count is pinned so a probe
    ///         quietly dropped from the Lean side shows up here rather
    ///         than as a silently narrower corpus.
    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first to generate");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        assertEq(
            vm.parseJsonString(raw, ".identifier"), "knomosis/smt-multi-proof/v1", "identifier"
        );
        assertEq(vm.parseJsonUint(raw, ".count"), 6, "probe count");
    }

    /// @notice Every probe's cells are in strictly ascending PATH order
    ///         as published.
    ///
    /// @dev    `multiWalk` requires that and refuses otherwise, so if
    ///         Lean's `frontierOf` ever sorted by something other than
    ///         the path index — or if this stack's bit reversal drifted
    ///         — the symptom would be a revert inside every root
    ///         assertion below.  Checking it here separates "the orders
    ///         disagree" from "the fold disagrees".
    function test_published_cells_are_in_ascending_path_order() public {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; ++i) {
            beginEntry(string.concat("#", vm.toString(i)));
            bytes32[] memory ks = _keys(raw, i);
            string memory name = vm.parseJsonString(raw, string.concat(_probe(i), ".name"));
            for (uint256 c = 0; c + 1 < ks.length; ++c) {
                (bool okA, uint256 a, bytes memory eA) = _tryPathIndex(ks[c]);
                (bool okB, uint256 b, bytes memory eB) = _tryPathIndex(ks[c + 1]);
                if (!okA || !okB) {
                    recordFailure(
                        string.concat(
                            "probe ", name, ": pathIndexOf reverted ",
                            describeRevert(okA ? eB : eA)));
                    continue;
                }
                checkLt(
                    a, b,
                    string.concat("probe ", name, ": cells not in ascending path order")
                );
            }
        }
    }

    /// @notice This stack derives the same gap count Lean published.
    ///
    /// @dev    The count is `G = (256 + 1) − m + Σ divs`, a function of
    ///         the key set alone — so this runs on a fallback-hash
    ///         fixture too: both stacks derive from the same published
    ///         keys, whichever hash produced them.  It is also the
    ///         single most load-bearing agreement in the wire format,
    ///         because every length check downstream is computed from
    ///         it.
    function test_derived_gap_count_matches_the_published_one() public {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; ++i) {
            beginEntry(string.concat("#", vm.toString(i)));
            string memory p = _probe(i);
            string memory name = vm.parseJsonString(raw, string.concat(p, ".name"));
            uint256 want = vm.parseJsonUint(raw, string.concat(p, ".gapCount"));
            (bool ok, uint256 got, bytes memory err) = _tryGapCount(_keys(raw, i));
            if (!ok) {
                recordFailure(
                    string.concat(
                        "probe ", name, ": gapCountOf reverted ", describeRevert(err)));
                continue;
            }
            checkEq(got, want, string.concat("probe ", name, ": derived gap count"));
        }
    }

    /// @notice The published wire has exactly the length the derived gap
    ///         count implies: `ceil(G/8)` mask bytes and `32 *
    ///         popcount(mask)` sibling bytes.  Binding-independent, for
    ///         the same reason as the gap count.
    function test_published_wire_lengths_match_the_derived_shape() public {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; ++i) {
            beginEntry(string.concat("#", vm.toString(i)));
            string memory p = _probe(i);
            string memory name = vm.parseJsonString(raw, string.concat(p, ".name"));
            (bool okG, uint256 g, bytes memory errG) = _tryGapCount(_keys(raw, i));
            if (!okG) {
                recordFailure(
                    string.concat(
                        "probe ", name, ": gapCountOf reverted ", describeRevert(errG)));
                continue;
            }
            bytes memory mask = vm.parseJsonBytes(raw, string.concat(p, ".gapMaskHex"));
            bytes memory sibs = vm.parseJsonBytes(raw, string.concat(p, ".siblingsHex"));
            checkEq(mask.length, (g + 7) / 8, string.concat("probe ", name, ": mask length"));
            uint256 popcount = 0;
            for (uint256 b = 0; b < g; ++b) {
                popcount += (uint256(uint8(mask[b >> 3])) >> (b & 7)) & 1;
            }
            checkEq(sibs.length, popcount * 32, string.concat("probe ", name, ": sibling bytes"));
        }
    }

    /// @notice The corpus reaches both gap branches on THIS stack too:
    ///         some probe draws siblings out of the wire, and some probe
    ///         takes the canonical empty sub-tree at every single gap.
    ///
    /// @dev    Mirrors the Lean-side assertion of the same name.  A
    ///         corpus that only ever hit one branch would leave the
    ///         other unpinned, and a sparse state produces exactly that
    ///         by accident.
    function test_corpus_exercises_both_gap_branches() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        bool sawSiblings = false;
        bool sawNone = false;
        for (uint256 i = 0; i < n; ++i) {
            bytes memory sibs = vm.parseJsonBytes(raw, string.concat(_probe(i), ".siblingsHex"));
            if (sibs.length > 0) sawSiblings = true;
            else sawNone = true;
        }
        assertTrue(sawSiblings, "no probe draws a sibling from the wire");
        assertTrue(sawNone, "no probe takes the empty sub-tree at every gap");
    }

    /* ---------------------------------------------------------- */
    /* The pin (binding-conditional)                              */
    /* ---------------------------------------------------------- */

    /// @notice **The headline.**  For every probe, folding the published
    ///         wire with the PRE leaves reaches the pre-state root, and
    ///         folding the SAME wire with the POST leaves reaches the
    ///         post-state root.
    ///
    /// @dev    One wire, two roots, is the whole design: the sibling
    ///         sub-trees contain no opened cell, so they are identical
    ///         in both states and the pre- and post-folds share them.
    ///         Asserting both against one wire is what makes that
    ///         cross-checked rather than assumed.
    function test_every_probe_folds_to_both_of_its_roots() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; ++i) {
            beginEntry(string.concat("#", vm.toString(i)));
            string memory p = _probe(i);
            string memory name = vm.parseJsonString(raw, string.concat(p, ".name"));
            bytes32[] memory ks = _keys(raw, i);
            bytes memory mask = vm.parseJsonBytes(raw, string.concat(p, ".gapMaskHex"));
            bytes memory sibs = vm.parseJsonBytes(raw, string.concat(p, ".siblingsHex"));

            (bool okPre, bytes32 preRoot, bytes memory errPre) =
                _tryFold(ks, _leaves(raw, i, false), mask, sibs);
            if (okPre) {
                checkEq(
                    preRoot,
                    vm.parseJsonBytes32(raw, string.concat(p, ".preStateRootHex")),
                    string.concat("probe ", name, ": pre-state root")
                );
            } else {
                recordFailure(
                    string.concat(
                        "probe ", name, ": pre-side fold reverted ",
                        describeRevert(errPre)));
            }
            (bool okPost, bytes32 postRoot, bytes memory errPost) =
                _tryFold(ks, _leaves(raw, i, true), mask, sibs);
            if (okPost) {
                checkEq(
                    postRoot,
                    vm.parseJsonBytes32(raw, string.concat(p, ".postStateRootHex")),
                    string.concat("probe ", name, ": post-state root")
                );
            } else {
                recordFailure(
                    string.concat(
                        "probe ", name, ": post-side fold reverted ",
                        describeRevert(errPost)));
            }
        }
    }

    /// @notice The two roots differ for every probe.
    ///
    /// @dev    Otherwise the post-root column pins nothing the pre-root
    ///         column does not, and a fold that ignored the leaves
    ///         entirely would pass the assertion above.
    function test_the_two_roots_differ_for_every_probe() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; ++i) {
            beginEntry(string.concat("#", vm.toString(i)));
            string memory p = _probe(i);
            checkTrue(
                vm.parseJsonBytes32(raw, string.concat(p, ".preStateRootHex"))
                    != vm.parseJsonBytes32(raw, string.concat(p, ".postStateRootHex")),
                string.concat(
                    "probe ",
                    vm.parseJsonString(raw, string.concat(p, ".name")),
                    ": pre and post roots coincide"
                )
            );
        }
    }

    /// @notice A tampered leaf does not reach the published root.
    ///
    /// @dev    The negative control for the headline: without it, a fold
    ///         that reached the right answer for the wrong reason — say
    ///         by hashing the wire alone — would still pass.
    function test_a_tampered_leaf_does_not_reach_the_root() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; ++i) {
            beginEntry(string.concat("#", vm.toString(i)));
            string memory p = _probe(i);
            bytes32[] memory ks = _keys(raw, i);
            bytes32[] memory ls = _leaves(raw, i, false);
            ls[0] = bytes32(uint256(ls[0]) ^ 1);
            // A revert here is a PASS in substance — the tampered leaf
            // did not reach the root — but it is recorded rather than
            // silently accepted, because a fold that reverted on every
            // input would satisfy this test while proving nothing.
            (bool ok, bytes32 root, bytes memory err) = _tryFold(
                ks,
                ls,
                vm.parseJsonBytes(raw, string.concat(p, ".gapMaskHex")),
                vm.parseJsonBytes(raw, string.concat(p, ".siblingsHex"))
            );
            if (!ok) {
                recordFailure(
                    string.concat(
                        "probe ",
                        vm.parseJsonString(raw, string.concat(p, ".name")),
                        ": tampered fold reverted rather than reaching a wrong root: ",
                        describeRevert(err)));
                continue;
            }
            checkTrue(
                root != vm.parseJsonBytes32(raw, string.concat(p, ".preStateRootHex")),
                string.concat(
                    "probe ",
                    vm.parseJsonString(raw, string.concat(p, ".name")),
                    ": a flipped leaf bit still reached the root"
                )
            );
        }
    }

    /* ---------------------------------------------------------- */
    /* Refusals against a real wire                               */
    /* ---------------------------------------------------------- */

    /// @dev The first probe carrying at least two cells and at least one
    ///      sibling — the shape the refusals below need.
    function _multiCellProbe(string memory raw) internal pure returns (uint256) {
        uint256 n = vm.parseJsonUint(raw, ".count");
        for (uint256 i = 0; i < n; ++i) {
            string memory p = _probe(i);
            if (
                vm.parseJsonUint(raw, string.concat(p, ".cellCount")) >= 2
                    && vm.parseJsonBytes(raw, string.concat(p, ".siblingsHex")).length > 0
            ) return i;
        }
        revert("corpus has no multi-cell probe carrying siblings");
    }

    /// @notice Truncating the sibling region reverts rather than being
    ///         padded out.
    ///
    /// @dev    This is the property the single-cell verifier does NOT
    ///         have: `SmtCellVerifier.recomputeRootFromLeaf` substitutes
    ///         a padding hash when the wire runs short and keeps
    ///         walking, so a truncated proof is a silent
    ///         reinterpretation there.  Here the sibling count is
    ///         derived from the key set, so short is short.
    function test_a_truncated_sibling_region_reverts() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 i = _multiCellProbe(raw);
        string memory p = _probe(i);
        bytes memory sibs = vm.parseJsonBytes(raw, string.concat(p, ".siblingsHex"));
        bytes memory short_ = new bytes(sibs.length - 32);
        for (uint256 b = 0; b < short_.length; ++b) {
            short_[b] = sibs[b];
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                SmtMultiVerifier.MultiProofSiblingCount.selector, sibs.length, short_.length
            )
        );
        proxy.foldFromKeys(
            _keys(raw, i),
            _leaves(raw, i, false),
            vm.parseJsonBytes(raw, string.concat(p, ".gapMaskHex")),
            short_
        );
    }

    /// @notice A reordered bundle reverts at the WALK.
    ///
    /// @dev    The walk itself demands path order; accepting an
    ///         arbitrary order is the job of the layer above, which
    ///         sorts before calling.  Pinning the refusal here is what
    ///         keeps that sort load-bearing instead of decorative.
    function test_a_reordered_bundle_reverts_at_the_walk() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 i = _multiCellProbe(raw);
        string memory p = _probe(i);
        bytes32[] memory ks = _keys(raw, i);
        bytes32[] memory ls = _leaves(raw, i, false);
        (ks[0], ks[1]) = (ks[1], ks[0]);
        (ls[0], ls[1]) = (ls[1], ls[0]);
        vm.expectRevert(
            abi.encodeWithSelector(SmtMultiVerifier.MultiProofNotStrictlySorted.selector, 0)
        );
        proxy.foldFromKeys(
            ks,
            ls,
            vm.parseJsonBytes(raw, string.concat(p, ".gapMaskHex")),
            vm.parseJsonBytes(raw, string.concat(p, ".siblingsHex"))
        );
    }

    /// @notice The same cell opened twice reverts.
    ///
    /// @dev    Strict ascent is the duplicate refusal as well as the
    ///         order one — a duplicate is simply not representable on
    ///         the wire, which is what retires the chained fold's
    ///         "first occurrence wins" rule.
    function test_the_same_cell_twice_reverts() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        uint256 i = _multiCellProbe(raw);
        string memory p = _probe(i);
        bytes32[] memory ks = _keys(raw, i);
        bytes32[] memory ls = _leaves(raw, i, false);
        ks[1] = ks[0];
        ls[1] = ls[0];
        vm.expectRevert(
            abi.encodeWithSelector(SmtMultiVerifier.MultiProofNotStrictlySorted.selector, 0)
        );
        proxy.foldFromKeys(
            ks,
            ls,
            vm.parseJsonBytes(raw, string.concat(p, ".gapMaskHex")),
            vm.parseJsonBytes(raw, string.concat(p, ".siblingsHex"))
        );
    }

    /* ---------------------------------------------------------- */
    /* Revert tolerance                                           */
    /* ---------------------------------------------------------- */

    /// @dev The proxy's three entry points, returning their failure
    ///      instead of raising it.  `proxy` is already external, so
    ///      `try` reaches it directly and no extra wrapper contract is
    ///      needed — what these add is the failure DATA, so a reverting
    ///      probe is named with its error rather than ending the walk.
    function _tryPathIndex(bytes32 k)
        private
        view
        returns (bool ok, uint256 v, bytes memory err)
    {
        try proxy.pathIndexOf(k) returns (uint256 x) {
            return (true, x, "");
        } catch (bytes memory e) {
            return (false, 0, e);
        }
    }

    /// @dev `gapCountOf`, revert-tolerant.
    function _tryGapCount(bytes32[] memory ks)
        private
        view
        returns (bool ok, uint256 v, bytes memory err)
    {
        try proxy.gapCountOf(ks) returns (uint256 x) {
            return (true, x, "");
        } catch (bytes memory e) {
            return (false, 0, e);
        }
    }

    /// @dev `foldFromKeys`, revert-tolerant.
    function _tryFold(
        bytes32[] memory ks,
        bytes32[] memory ls,
        bytes memory mask,
        bytes memory sibs
    ) private view returns (bool ok, bytes32 root, bytes memory err) {
        try proxy.foldFromKeys(ks, ls, mask, sibs) returns (bytes32 r) {
            return (true, r, "");
        } catch (bytes memory e) {
            return (false, bytes32(0), e);
        }
    }

    /// @notice Name the verifier libraries' errors; defer the rest.
    function describeRevert(bytes memory err)
        internal
        pure
        override
        returns (string memory)
    {
        bytes4 s = revertSelector(err);
        if (s == SmtMultiVerifier.MultiProofTooManyCells.selector) {
            return "MultiProofTooManyCells";
        }
        if (s == SmtMultiVerifier.MultiProofEmpty.selector) return "MultiProofEmpty";
        if (s == SmtMultiVerifier.MultiProofNotStrictlySorted.selector) {
            return "MultiProofNotStrictlySorted";
        }
        if (s == SmtMultiVerifier.MultiProofMaskLength.selector) {
            return "MultiProofMaskLength";
        }
        if (s == SmtMultiVerifier.MultiProofPadding.selector) return "MultiProofPadding";
        if (s == SmtMultiVerifier.MultiProofSiblingCount.selector) {
            return "MultiProofSiblingCount";
        }
        return super.describeRevert(err);
    }

    /// @notice **Every error `SmtMultiVerifier` declares has a name above.**
    function test_every_declared_error_is_described() public {
        string[] memory artifacts = new string[](1);
        artifacts[0] = "out/SmtMultiVerifier.sol/SmtMultiVerifier.json";
        assertEveryDeclaredErrorIsDescribed(artifacts);
    }

}
