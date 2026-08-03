// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

/// @title SmtMultiVerifier
/// @notice Solidity port of `LegalKernel.FaultProof.multiWalk` — ONE
///         merged walk opening many cells against a single root.
///
/// @dev    A chained fold walks the tree once per opening and carries a
///         full 256-level sibling path for each, even where those paths
///         coincide.  This descends with the whole key set at once,
///         splitting it exactly as the tree splits its entries: where
///         both halves still hold an opened cell it recurses into both
///         and hashes their results, and where only one does it reads a
///         SIBLING from the wire.  Those reads are the "gaps".
///
///         **Why a monotonic stack rather than recursion.**  Lean's
///         reference is a top-down recursion, which is the right shape
///         for its proof (the completeness theorem is then the same
///         induction as the single-key one) and the wrong shape for the
///         EVM at depth 256.  Processing the path-sorted leaves left to
///         right with a stack of pending merges produces the identical
///         gap sequence with a single cursor and a stack bounded by the
///         cell count — verified against the Lean order over random key
///         sets before this was written, because it is the one property
///         a compiler cannot check.
///
///         **The order.**  `smtRootListAux (d+1)` splits on key bit `d`
///         and the root is at `d = 255`, so a path read from the root
///         down reads bit indices 255 … 0.  `pathIndex` is the key with
///         its bits reversed, which makes that reading order a PLAIN
///         UNSIGNED COMPARE and the divergence level a most-significant
///         bit — the whole reason the sort and the merge test are cheap
///         here.
///
///         **The wire's shape is derived, not trusted.**  `gapCount`
///         computes the expected gap count from the KEY SET alone, so
///         the mask size, the padding bits and the sibling count are all
///         known before a byte of the proof is read.  A single-cell
///         verifier that runs out of siblings substitutes a padding hash
///         and keeps walking, reaching some root that is not the tree's;
///         this one refuses.
///
///         Mirrors `LegalKernel/FaultProof/MultiProof.lean`.
library SmtMultiVerifier {
    /* ---------------------------------------------------------- */
    /* Constants                                                  */
    /* ---------------------------------------------------------- */

    /// @notice SMT depth — matches Lean's `smtDepth`.
    uint256 internal constant SMT_DEPTH = 256;

    /// @notice Hash output size in bytes.
    uint256 internal constant HASH_BYTES = 32;

    /// @notice Maximum opened cells in one multiproof.  Bounds both the
    ///         sort and the pending-merge stack.
    uint256 internal constant MAX_OPENED_CELLS = 32;

    // Bit-reversal masks.
    uint256 private constant M1 = 0x5555555555555555555555555555555555555555555555555555555555555555;
    uint256 private constant M2 = 0x3333333333333333333333333333333333333333333333333333333333333333;
    uint256 private constant M4 = 0x0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f;
    uint256 private constant M8 = 0x00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff;
    uint256 private constant M16 = 0x0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff0000ffff;
    uint256 private constant M32 = 0x00000000ffffffff00000000ffffffff00000000ffffffff00000000ffffffff;
    uint256 private constant M64 = 0x0000000000000000ffffffffffffffff0000000000000000ffffffffffffffff;

    /* ---------------------------------------------------------- */
    /* Errors                                                     */
    /* ---------------------------------------------------------- */

    /// @notice The bundle exceeds `MAX_OPENED_CELLS`.
    error MultiProofTooManyCells(uint256 count);

    /// @notice The bundle is empty; there is nothing to open.
    error MultiProofEmpty();

    /// @notice Two opened cells are out of path order, or are the same
    ///         cell.  Strict ascent is distinctness as well as order, so
    ///         this is the duplicate refusal too.
    error MultiProofNotStrictlySorted(uint256 index);

    /// @notice The gap mask is not `ceil(G/8)` bytes for the derived
    ///         gap count `G`.
    error MultiProofMaskLength(uint256 expected, uint256 got);

    /// @notice A mask bit at or past the last gap is set, so the final
    ///         byte's padding was carrying a sibling.
    error MultiProofPadding(uint256 gapIndex);

    /// @notice The sibling region is not exactly `32 * popcount(mask)`.
    error MultiProofSiblingCount(uint256 expected, uint256 got);

    /* ---------------------------------------------------------- */
    /* The path index                                             */
    /* ---------------------------------------------------------- */

    /// @notice The key with its bits reversed.
    ///
    /// @dev    Bit `d` of the result is Lean's `BitsKey.keyBit key d`,
    ///         because a Lean bit index `i` is uint256 bit position
    ///         `255 - i`.  Reversing turns the tree's root-first reading
    ///         order into MSB-first, so path order is a plain unsigned
    ///         compare and the divergence level is an `msb`.
    function pathIndex(bytes32 key) internal pure returns (uint256 r) {
        unchecked {
            r = uint256(key);
            r = ((r & M1) << 1) | ((r >> 1) & M1);
            r = ((r & M2) << 2) | ((r >> 2) & M2);
            r = ((r & M4) << 4) | ((r >> 4) & M4);
            r = ((r & M8) << 8) | ((r >> 8) & M8);
            r = ((r & M16) << 16) | ((r >> 16) & M16);
            r = ((r & M32) << 32) | ((r >> 32) & M32);
            r = ((r & M64) << 64) | ((r >> 64) & M64);
            r = (r << 128) | (r >> 128);
        }
    }

    /// @notice Index of the most significant set bit.  Undefined at
    ///         zero, which the callers exclude by requiring strictly
    ///         ascending (hence distinct) path indices.
    function msb(uint256 x) internal pure returns (uint256 r) {
        unchecked {
            if (x >= 1 << 128) { x >>= 128; r += 128; }
            if (x >= 1 << 64) { x >>= 64; r += 64; }
            if (x >= 1 << 32) { x >>= 32; r += 32; }
            if (x >= 1 << 16) { x >>= 16; r += 16; }
            if (x >= 1 << 8) { x >>= 8; r += 8; }
            if (x >= 1 << 4) { x >>= 4; r += 4; }
            if (x >= 1 << 2) { x >>= 2; r += 2; }
            if (x >= 1 << 1) { r += 1; }
        }
    }

    /// @notice The level at which two keys' paths diverge — mirrors
    ///         Lean's `divLevel`.
    function divLevel(uint256 pa, uint256 pb) internal pure returns (uint256) {
        return msb(pa ^ pb);
    }

    /* ---------------------------------------------------------- */
    /* The wire's derived shape                                   */
    /* ---------------------------------------------------------- */

    /// @notice The number of gaps a key set implies — `G = (256 + 1) −
    ///         m + Σ divs`, mirroring Lean's `gapCountClosed`.
    ///
    /// @dev    Computed from the KEYS, never from the proof.  That is
    ///         what makes the length checks below refusals rather than
    ///         best-effort parsing: a merge consumes two active slots
    ///         and emits no gap, so the count is fixed the moment the
    ///         cell set is.
    ///
    /// @param  sorted strictly ascending path indices.
    function gapCount(uint256[] memory sorted) internal pure returns (uint256 g) {
        unchecked {
            uint256 m = sorted.length;
            g = SMT_DEPTH + 1 - m;
            for (uint256 j = 0; j + 1 < m; ++j) {
                g += divLevel(sorted[j], sorted[j + 1]);
            }
        }
    }

    /// @dev Bit `g` of the gap mask, LSB-first within each byte —
    ///      the same convention as `SmtCellVerifier.readBitmaskBit`, so
    ///      a single-cell multiproof's mask IS a single-cell proof's.
    function gapBit(bytes calldata mask, uint256 g) internal pure returns (uint256) {
        unchecked {
            uint256 byteIdx = g >> 3;
            if (byteIdx >= mask.length) return 0;
            return (uint256(uint8(mask[byteIdx])) >> (g & 7)) & 1;
        }
    }

    /// @notice **Validate the wire against the shape the key set
    ///         implies**, before walking a single level.
    ///
    /// @dev    Four conditions, each derived: the mask is exactly
    ///         `ceil(G/8)` bytes; every bit at or past `G` is clear, so
    ///         the final byte's padding cannot smuggle a sibling; the
    ///         sibling region is exactly `32 * popcount(mask)` — not
    ///         "at least", which is what lets a short proof be padded;
    ///         and it divides into whole 32-byte siblings.
    ///
    /// @return g the derived gap count, for the walk to consume.
    function requireShape(
        uint256[] memory sorted,
        bytes calldata gapMask,
        bytes calldata siblings
    ) internal pure returns (uint256 g) {
        unchecked {
            g = gapCount(sorted);
            uint256 wantMask = (g + 7) / 8;
            if (gapMask.length != wantMask) {
                revert MultiProofMaskLength(wantMask, gapMask.length);
            }
            // No set bit may live past the last gap.
            for (uint256 b = g; b < wantMask * 8; ++b) {
                if (gapBit(gapMask, b) == 1) revert MultiProofPadding(b);
            }
            uint256 popcount = 0;
            for (uint256 b = 0; b < g; ++b) {
                popcount += gapBit(gapMask, b);
            }
            uint256 wantSibs = popcount * HASH_BYTES;
            if (siblings.length != wantSibs) {
                revert MultiProofSiblingCount(wantSibs, siblings.length);
            }
        }
    }

    /* ---------------------------------------------------------- */
    /* The walk                                                   */
    /* ---------------------------------------------------------- */

    /// @dev One 32-byte sibling out of the packed region.
    function siblingAt(bytes calldata siblings, uint256 idx)
        private
        pure
        returns (bytes32 s)
    {
        unchecked {
            uint256 offset = idx * HASH_BYTES;
            /// @solidity memory-safe-assembly
            assembly {
                s := calldataload(add(siblings.offset, offset))
            }
        }
    }

    /// @dev `keccak256(a ‖ b)` over the scratch space.
    function hashPair(bytes32 a, bytes32 b) private pure returns (bytes32 h) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            h := keccak256(0x00, 0x40)
        }
    }

    /// @notice **The merged walk.**  Fold the opened leaves and the
    ///         wire's gaps into the tree's root.
    ///
    /// @dev    Leaves are processed left to right in path order.  Each
    ///         climbs until it either meets a pending merge (it is that
    ///         merge's RIGHT child, so pop and combine) or reaches its
    ///         own divergence with the next leaf (it becomes a pending
    ///         LEFT child, so push).  A merge reads NO sibling — the two
    ///         sub-trees are each other's — which is exactly why the gap
    ///         count is below `256 * m`.
    ///
    ///         The single `cursor` is what makes this equal to Lean's
    ///         post-order recursion: processing leaves left to right and
    ///         merging as early as possible visits sub-trees in the same
    ///         order the recursion's own concatenation does.
    ///
    /// @param  sorted   strictly ascending path indices.
    /// @param  leaves   each cell's leaf hash, parallel to `sorted`.
    /// @param  gapMask  one bit per gap; set iff drawn from `siblings`.
    /// @param  siblings the packed non-canonical-empty siblings.
    /// @param  empties  the canonical empty-subtree chain.
    /// @return root     the root the fold reaches.
    function multiWalk(
        uint256[] memory sorted,
        bytes32[] memory leaves,
        bytes calldata gapMask,
        bytes calldata siblings,
        bytes32[256] memory empties
    ) internal pure returns (bytes32 root) {
        uint256 m = sorted.length;
        if (m == 0) revert MultiProofEmpty();
        if (m > MAX_OPENED_CELLS) revert MultiProofTooManyCells(m);
        // Strict ascent is the order check AND the duplicate check: two
        // openings of one cell have equal path indices and fail here.
        for (uint256 j = 0; j + 1 < m; ++j) {
            if (sorted[j] >= sorted[j + 1]) revert MultiProofNotStrictlySorted(j);
        }
        requireShape(sorted, gapMask, siblings);

        // Pending merges, deepest first.
        uint256[] memory stackLevel = new uint256[](MAX_OPENED_CELLS);
        bytes32[] memory stackHash = new bytes32[](MAX_OPENED_CELLS);
        uint256 top = 0;

        uint256 gapIdx = 0;
        uint256 cursor = 0;

        unchecked {
            for (uint256 j = 0; j < m; ++j) {
                bytes32 cur = leaves[j];
                uint256 curKey = sorted[j];
                uint256 lvl = 0;
                uint256 nextDiv =
                    (j + 1 < m) ? divLevel(sorted[j], sorted[j + 1]) : SMT_DEPTH;

                // Settle every pending merge that lands below this
                // leaf's own divergence.
                while (top > 0 && stackLevel[top - 1] < nextDiv) {
                    uint256 mergeAt = stackLevel[top - 1];
                    while (lvl < mergeAt) {
                        bytes32 sib;
                        if (gapBit(gapMask, gapIdx) == 1) {
                            sib = siblingAt(siblings, cursor);
                            ++cursor;
                        } else {
                            sib = empties[lvl];
                        }
                        ++gapIdx;
                        cur = ((curKey >> lvl) & 1) == 1
                            ? hashPair(sib, cur)
                            : hashPair(cur, sib);
                        ++lvl;
                    }
                    // `cur` is the right child; the merge reads no gap.
                    cur = hashPair(stackHash[top - 1], cur);
                    lvl = mergeAt + 1;
                    --top;
                }

                // Climb to this leaf's own divergence (or to the root on
                // the last leaf, where `nextDiv` is the full depth).
                while (lvl < nextDiv) {
                    bytes32 sib;
                    if (gapBit(gapMask, gapIdx) == 1) {
                        sib = siblingAt(siblings, cursor);
                        ++cursor;
                    } else {
                        sib = empties[lvl];
                    }
                    ++gapIdx;
                    cur = ((curKey >> lvl) & 1) == 1
                        ? hashPair(sib, cur)
                        : hashPair(cur, sib);
                    ++lvl;
                }

                if (j + 1 < m) {
                    stackLevel[top] = nextDiv;
                    stackHash[top] = cur;
                    ++top;
                } else {
                    root = cur;
                }
            }
        }
    }
}
