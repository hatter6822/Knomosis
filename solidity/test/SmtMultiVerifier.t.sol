// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {SmtCellVerifier} from "src/lib/SmtCellVerifier.sol";
import {SmtMultiVerifier} from "src/lib/SmtMultiVerifier.sol";

/// @title SmtMultiVerifierProxy
/// @notice External wrapper so the calldata-typed parameters arrive as
///         calldata.
contract SmtMultiVerifierProxy {
    function multiWalk(
        uint256[] calldata sorted,
        bytes32[] calldata leaves,
        bytes calldata gapMask,
        bytes calldata siblings
    ) external pure returns (bytes32) {
        uint256[] memory s = sorted;
        bytes32[] memory l = leaves;
        return SmtMultiVerifier.multiWalk(
            s, l, gapMask, siblings, SmtCellVerifier.precomputeEmptySubtreeHashes());
    }

    function recomputeRootFromLeaf(bytes calldata key, bytes32 leaf, bytes calldata proofData)
        external
        pure
        returns (bytes32)
    {
        return SmtCellVerifier.recomputeRootFromLeaf(key, leaf, proofData);
    }

    function pathIndex(bytes32 key) external pure returns (uint256) {
        return SmtMultiVerifier.pathIndex(key);
    }

    function gapCount(uint256[] calldata sorted) external pure returns (uint256) {
        uint256[] memory s = sorted;
        return SmtMultiVerifier.gapCount(s);
    }

    function divLevel(uint256 a, uint256 b) external pure returns (uint256) {
        return SmtMultiVerifier.divLevel(a, b);
    }
}

/// @title SmtMultiVerifierTest
/// @notice The merged walk, and the refusals its derived shape buys.
///
/// @dev    **The pin is transitive.**  At ONE opened cell a multiproof
///         degenerates to a single-cell opening — 256 gaps, one per
///         level, a 32-byte mask indexed exactly as
///         `SmtCellProof.bitmask` is.  So `multiWalk` on a one-cell
///         bundle must equal `SmtCellVerifier.recomputeRootFromLeaf` on
///         the same path, and THAT is already pinned to Lean
///         byte-for-byte by `smt_cell_proof.json`.  Agreement here
///         therefore ties the multiproof to the Lean reference without
///         inventing a second fixture corpus — and it is a real check,
///         because the two walk the tree by completely different
///         mechanisms (a level loop against a leaf-ordered stack scan).
///
///         Lean's `multiSiblings_single` and `multiGapLevels_single`
///         are the same statement on the other stack.
contract SmtMultiVerifierTest is Test {
    SmtMultiVerifierProxy internal p;

    /// @dev A key with bits set in both halves, so the walk takes both
    ///      the left- and right-child branches rather than one side.
    bytes32 internal constant KEY =
        0xa3f100000000000000000000000000000000000000000000000000000000005c;
    bytes32 internal constant LEAF = keccak256("leaf");

    function setUp() public {
        p = new SmtMultiVerifierProxy();
    }

    /* ---------------------------------------------------------- */
    /* The path index                                             */
    /* ---------------------------------------------------------- */

    /// @notice `pathIndex` bit `d` is the tree's key bit `d`.
    ///
    /// @dev    The tree reads a path from the root down, which is Lean
    ///         bit indices 255 … 0, which is uint256 positions 0 … 255.
    ///         Reversing makes that MSB-first, so path order is a plain
    ///         compare.  Checked against the byte-wise reader the walk
    ///         used to use, over every level.
    function test_pathIndex_bit_is_the_key_bit() public view {
        uint256 r = p.pathIndex(KEY);
        bytes memory k = abi.encodePacked(KEY);
        for (uint256 d = 0; d < 256; d++) {
            assertEq(
                (r >> d) & 1,
                SmtCellVerifier.readKeyBitMSBFirst(k, d),
                string.concat("bit ", vm.toString(d))
            );
        }
    }

    /// @notice Divergence is the most significant differing bit.
    function test_divLevel_is_the_msb_of_the_difference() public view {
        assertEq(p.divLevel(1, 0), 0, "differ at bit 0");
        assertEq(p.divLevel(1 << 200, 0), 200, "differ at bit 200");
        assertEq(p.divLevel((1 << 200) | 3, (1 << 200) | 1), 1, "shared prefix ignored");
    }

    /* ---------------------------------------------------------- */
    /* The gap count                                              */
    /* ---------------------------------------------------------- */

    /// @notice One opened cell has one gap per level.
    function test_gapCount_single_is_the_depth() public view {
        uint256[] memory one = new uint256[](1);
        one[0] = p.pathIndex(KEY);
        assertEq(p.gapCount(one), 256, "m = 1 gives 256 gaps");
    }

    /// @notice Two cells diverging at `d` give `255 + d` gaps.
    ///
    /// @dev    `2d` below the split, none AT it — a merge reads no
    ///         sibling — and `255 - d` above.  That "none at the split"
    ///         is the whole compression, and the arithmetic is the one
    ///         the plan first got wrong (a merge consumes TWO active
    ///         slots, not one).
    function test_gapCount_pair_matches_the_closed_form() public view {
        for (uint256 d = 1; d < 250; d += 37) {
            uint256[] memory two = new uint256[](2);
            two[0] = 0;
            two[1] = 1 << d;
            assertEq(p.gapCount(two), 255 + d, string.concat("divergence ", vm.toString(d)));
        }
    }

    /* ---------------------------------------------------------- */
    /* The transitive pin                                         */
    /* ---------------------------------------------------------- */

    /// @dev A proof whose mask has a set bit every `stride` levels, with
    ///      exactly that many siblings — an EXACT-count proof, which is
    ///      what the multiproof requires and the single-cell verifier
    ///      merely tolerates.
    function _exactProof(uint256 stride)
        internal
        pure
        returns (bytes memory mask, bytes memory sibs)
    {
        mask = new bytes(32);
        uint256 n = 0;
        for (uint256 d = 0; d < 256; d += stride) {
            mask[d >> 3] = bytes1(uint8(mask[d >> 3]) | uint8(1 << (d & 7)));
            n++;
        }
        sibs = new bytes(0);
        for (uint256 i = 0; i < n; i++) {
            sibs = bytes.concat(sibs, keccak256(abi.encodePacked("sib", i)));
        }
    }

    /// @notice **One opened cell walks exactly as a single-cell opening
    ///         does.**
    function test_single_cell_matches_the_pinned_verifier() public view {
        for (uint256 stride = 1; stride <= 64; stride *= 4) {
            (bytes memory mask, bytes memory sibs) = _exactProof(stride);

            uint256[] memory sorted = new uint256[](1);
            sorted[0] = p.pathIndex(KEY);
            bytes32[] memory leaves = new bytes32[](1);
            leaves[0] = LEAF;

            assertEq(
                p.multiWalk(sorted, leaves, mask, sibs),
                p.recomputeRootFromLeaf(abi.encodePacked(KEY), LEAF, bytes.concat(mask, sibs)),
                string.concat("stride ", vm.toString(stride))
            );
        }
    }

    /* ---------------------------------------------------------- */
    /* Refusals the derived shape buys                            */
    /* ---------------------------------------------------------- */

    /// @notice A wire one sibling short is REFUSED, not padded.
    ///
    /// @dev    The single-cell verifier substitutes a padding hash here
    ///         and keeps walking, reaching a root the tree does not
    ///         have.  This one knows how many siblings to expect before
    ///         it reads any, so it can say no.
    function test_short_wire_is_refused() public {
        (bytes memory mask, bytes memory sibs) = _exactProof(8);
        uint256[] memory sorted = new uint256[](1);
        sorted[0] = p.pathIndex(KEY);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = LEAF;

        bytes memory short_ = new bytes(sibs.length - 32);
        for (uint256 i = 0; i < short_.length; i++) short_[i] = sibs[i];

        vm.expectRevert(
            abi.encodeWithSelector(
                SmtMultiVerifier.MultiProofSiblingCount.selector, sibs.length, short_.length)
        );
        p.multiWalk(sorted, leaves, mask, short_);
    }

    /// @notice A mask bit past the last gap is refused.
    ///
    /// @dev    With one cell every bit is a real gap, so the padding
    ///         case needs a cell count whose gap total is not a multiple
    ///         of eight — two cells diverging at level 1 give 256 gaps
    ///         plus... the point is that the final byte's spare bits are
    ///         checked rather than ignored.
    function test_padding_bit_is_refused() public {
        uint256[] memory sorted = new uint256[](2);
        sorted[0] = 0;
        sorted[1] = 1 << 3; // divergence at level 3 => 255 + 3 = 258 gaps
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = LEAF;
        leaves[1] = keccak256("leaf2");

        uint256 g = p.gapCount(sorted);
        assertEq(g, 258, "the probe's gap count");
        bytes memory mask = new bytes((g + 7) / 8); // 33 bytes, 6 spare bits
        // Set a bit past the last gap.
        mask[g >> 3] = bytes1(uint8(1 << (g & 7)));

        vm.expectRevert(
            abi.encodeWithSelector(SmtMultiVerifier.MultiProofPadding.selector, g)
        );
        p.multiWalk(sorted, leaves, mask, new bytes(0));
    }

    /// @notice A duplicate cell is refused, and by the ORDER check.
    ///
    /// @dev    Strict ascent is distinctness as well as ordering, so the
    ///         same comparison that rejects an out-of-order bundle
    ///         rejects one naming a cell twice.  That is the same-cell
    ///         defence: under a pre-root multiproof a duplicate has no
    ///         wire representation.
    function test_duplicate_cell_is_refused() public {
        uint256[] memory sorted = new uint256[](2);
        sorted[0] = p.pathIndex(KEY);
        sorted[1] = p.pathIndex(KEY);
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = LEAF;
        leaves[1] = LEAF;

        vm.expectRevert(
            abi.encodeWithSelector(SmtMultiVerifier.MultiProofNotStrictlySorted.selector, 0)
        );
        p.multiWalk(sorted, leaves, new bytes(32), new bytes(0));
    }

    /// @notice An out-of-order bundle is refused.
    function test_unsorted_bundle_is_refused() public {
        uint256[] memory sorted = new uint256[](2);
        sorted[0] = 1 << 3;
        sorted[1] = 0;
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = LEAF;
        leaves[1] = keccak256("leaf2");

        vm.expectRevert(
            abi.encodeWithSelector(SmtMultiVerifier.MultiProofNotStrictlySorted.selector, 0)
        );
        p.multiWalk(sorted, leaves, new bytes(33), new bytes(0));
    }

    /// @notice A mask of the wrong length is refused.
    function test_wrong_mask_length_is_refused() public {
        uint256[] memory sorted = new uint256[](1);
        sorted[0] = p.pathIndex(KEY);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = LEAF;

        vm.expectRevert(
            abi.encodeWithSelector(SmtMultiVerifier.MultiProofMaskLength.selector, 32, 31)
        );
        p.multiWalk(sorted, leaves, new bytes(31), new bytes(0));
    }

    /* ---------------------------------------------------------- */
    /* The merge                                                  */
    /* ---------------------------------------------------------- */

    /// @notice **Two cells sharing a sub-tree cost fewer gaps than two
    ///         separate openings.**  The economy, measured.
    function test_merging_saves_gaps() public view {
        uint256[] memory two = new uint256[](2);
        two[0] = 0;
        two[1] = 1 << 200;
        // Two separate single-cell proofs would carry 512 gaps.
        assertEq(p.gapCount(two), 455, "the merged wire carries 455");
        assertEq(p.gapCount(two) < 512, true, "fewer than two full paths");
    }

    /// @notice The merged walk of two cells reaches the root an explicit
    ///         two-path fold reaches.
    ///
    /// @dev    Built by hand rather than by the library, so this is an
    ///         independent check of the stack scan's arithmetic: climb
    ///         each leaf to the divergence level through canonical empty
    ///         siblings, combine, then climb the merged node to the top.
    function test_two_cells_reach_the_hand_built_root() public view {
        uint256 dLevel = 5;
        uint256[] memory sorted = new uint256[](2);
        sorted[0] = 0;
        sorted[1] = 1 << dLevel;
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("a");
        leaves[1] = keccak256("b");

        bytes32[256] memory empties = SmtCellVerifier.precomputeEmptySubtreeHashes();

        // Left leaf: bits 0..dLevel-1 are all zero, so it is always the
        // LEFT child and the sibling is the canonical empty sub-tree.
        bytes32 lo = leaves[0];
        for (uint256 d = 0; d < dLevel; d++) lo = keccak256(abi.encodePacked(lo, empties[d]));
        // Right leaf: same, since only bit `dLevel` is set.
        bytes32 hi = leaves[1];
        for (uint256 d = 0; d < dLevel; d++) hi = keccak256(abi.encodePacked(hi, empties[d]));
        // They merge at `dLevel`: left then right, no sibling read.
        bytes32 cur = keccak256(abi.encodePacked(lo, hi));
        // Then climb: bits above `dLevel` are zero in both.
        for (uint256 d = dLevel + 1; d < 256; d++) {
            cur = keccak256(abi.encodePacked(cur, empties[d]));
        }

        uint256 g = p.gapCount(sorted);
        assertEq(
            p.multiWalk(sorted, leaves, new bytes((g + 7) / 8), new bytes(0)),
            cur,
            "the stack scan reaches the hand-built root"
        );
    }
}
