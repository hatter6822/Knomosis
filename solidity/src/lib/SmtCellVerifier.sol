// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

/// @title SmtCellVerifier
/// @notice Solidity port of `LegalKernel.FaultProof.verifySmtCellProof`
///         (Workstream SC.2 — sparse-Merkle-tree cell-proof verifier
///         for the L1 step VM).
///
/// @dev    The L1 step VM consumes per-cell SMT proofs in the
///         bisection-game endgame.  Each proof is a 256-level Merkle
///         path opening a single (key, value) cell at the committed
///         state root.  This library walks the path and reconstructs
///         a candidate root; the caller compares against the
///         committed value.
///
///         Mirrors the Lean reference at
///         `LegalKernel/FaultProof/Smt.lean` (Workstream SC.1).
///         Cross-stack soundness (`smtCellProof_no_value_substitution`,
///         `smtCellProof_sound_under_collision_free`) holds when both
///         sides use the same hash (`keccak256`).
///
///         **Wire format** (`proofData : bytes calldata`):
///         ```
///         [0 .. 32)       : bitmask  (32 bytes = 256 bits, LSB-first
///                                     within each byte; bit d set
///                                     iff the depth-d sibling is
///                                     non-canonical-empty)
///         [32 .. 32+32N)  : siblings (N x 32-byte hashes, low-depth-
///                                     first)
///         ```
///         The wire format imposes no upper bound on N; the verifier
///         consumes only `popcount(bitmask)` siblings during the walk
///         and ignores any trailing extras (matching Lean's
///         `SmtCellProof.isWellFormed`).
///
///         **Walk algorithm**.  Starting from the leaf
///         `keccak256(leafPreimage)`, for each depth d in 0..255:
///         1. Read the proof's bitmask bit d.  If set: take the next
///            sibling from `siblings` (or fall back to `PADDING_HASH`
///            if exhausted).  If unset: use the canonical
///            `emptySubtreeHash(d)`.
///         2. Read the key's bit d (MSB-first within byte 0, byte 1,
///            ...).  If unset (left child): `current = keccak256(current
///            || sibling)`.  If set (right child): `current =
///            keccak256(sibling || current)`.
///         The final value (after 256 iterations) is the reconstructed
///         root.
///
///         **Bit conventions**.  The bitmask uses LSB-first within
///         each byte (bit 0 = LSB of byte 0; bit 8 = LSB of byte 1).
///         The key uses MSB-first within each byte (bit 0 = MSB of
///         byte 0; bit 8 = MSB of byte 1).  Both conventions match
///         Lean's `BitsKey` typeclass and `SmtCellProof.bitmaskBit`.
///
///         **Gas cost.**  The verifier performs at most 511 keccak256
///         calls (256 for the walk + up to 255 to advance the canonical
///         empty chain in lockstep) plus per-iteration bit-extraction
///         and branching.  No 8 KiB memory allocation: the empty
///         subtree chain is tracked through a single `bytes32`
///         accumulator that advances each iteration.
///
///         When invoked directly from another Solidity contract
///         (e.g. `StepVMMerkle.verifyCellSmtProof`), the library's
///         internal call cost is dominated by:
///           * 511 keccak256 ops via the EVM scratch space (~21k gas).
///           * 256 iterations of calldata-bit reads, branches, and
///             cursor maintenance (~15-25k gas).
///           * Total: 35-50k gas, within the SC.2 50k budget for
///             typical paths.
///         The exact cost depends on the proof's bitmask (no extra
///         calldata for unset bits; one calldataload per set bit) and
///         the surrounding contract's own dispatch overhead.
///
///         **Soundness**.  Under collision-resistance of `keccak256`,
///         the Lean side proves that the verifier accepts at most
///         one value per (root, key) pair
///         (`smtCellProof_no_value_substitution`).  This Solidity
///         port preserves that property by construction: it computes
///         the same root from the same inputs.
library SmtCellVerifier {
    /* ---------------------------------------------------------- */
    /* Constants                                                  */
    /* ---------------------------------------------------------- */

    /// @notice SMT depth — 256 levels (one per bit of the key space).
    ///         Matches Lean's `LegalKernel.FaultProof.smtDepth`.
    uint256 internal constant SMT_DEPTH = 256;

    /// @notice Bitmask size in bytes (= SMT_DEPTH / 8).
    uint256 internal constant BITMASK_BYTES = 32;

    /// @notice Hash output size in bytes (keccak256 produces 32-byte digests).
    uint256 internal constant HASH_BYTES = 32;

    /// @notice The 32-byte all-zero padding hash used for out-of-bounds
    ///         sibling lookups.  Matches Lean's `paddingHash`.
    ///
    /// @dev    The padding hash differs from every canonical
    ///         `emptySubtreeHash(d)` (the latter are keccak256 outputs
    ///         on non-degenerate inputs).  As a result, malformed
    ///         proofs with too-few siblings walk to a distinct root
    ///         from any honest proof and fail verification.
    bytes32 internal constant PADDING_HASH = bytes32(0);

    /// @notice The seed bytes for `H_0`: the ASCII string
    ///         `"EMPTY_LEAF"` encoded as UTF-8 (10 bytes).
    ///         Matches Lean's `emptyLeafSeedBytes`.
    bytes internal constant EMPTY_LEAF_SEED = bytes("EMPTY_LEAF");

    /* ---------------------------------------------------------- */
    /* Empty-subtree canonical hashes                             */
    /* ---------------------------------------------------------- */

    /// @notice Compute the canonical empty-subtree hash at depth `d`,
    ///         using the recursion `H_0 = keccak256("EMPTY_LEAF")`,
    ///         `H_{d+1} = keccak256(H_d || H_d)`.
    ///
    /// @dev    O(d) keccak256 calls per invocation.  Provided as a
    ///         reference for tests, audit scripts, and one-off
    ///         computations.  `recomputeRoot` does NOT call this
    ///         function: it tracks the empty-subtree chain through a
    ///         single `bytes32` accumulator that advances in lockstep
    ///         with the walk.
    ///
    ///         Reverts with `SmtCellDepthOutOfRange` if `d >= 256`.
    ///         Lean's `emptySubtreeHash` returns `ByteArray.empty`
    ///         (zero length) on out-of-range indices; this Solidity
    ///         port reverts instead because no in-bounds caller has
    ///         a legitimate reason to pass `d >= 256` and silently
    ///         returning a different shape would mask a caller bug.
    ///
    /// @param  d  the depth (must be in [0, 256)).
    /// @return h  the canonical empty-subtree hash at depth `d`.
    function emptySubtreeHash(uint256 d) internal pure returns (bytes32 h) {
        if (d >= SMT_DEPTH) {
            revert SmtCellDepthOutOfRange(d);
        }
        h = keccak256(EMPTY_LEAF_SEED);
        unchecked {
            for (uint256 i = 0; i < d; ++i) {
                h = _hashPair(h, h);
            }
        }
    }

    /// @notice Materialise all 256 canonical empty-subtree hashes
    ///         into an in-memory array.  Provided as a public helper
    ///         for tests and audit scripts (e.g.
    ///         `script/ComputeEmptyHashes.s.sol`).
    ///
    /// @dev    `recomputeRoot` does NOT call this function.  Instead,
    ///         it advances a single `bytes32` accumulator through the
    ///         chain in lockstep with the walk to avoid an 8 KiB
    ///         memory allocation.  Use this helper when you need a
    ///         full reference table, e.g. for golden-value tests.
    ///
    /// @return hashes  hashes[d] = canonical empty-subtree hash at depth d.
    function precomputeEmptySubtreeHashes()
        internal
        pure
        returns (bytes32[SMT_DEPTH] memory hashes)
    {
        hashes[0] = keccak256(EMPTY_LEAF_SEED);
        unchecked {
            for (uint256 i = 1; i < SMT_DEPTH; ++i) {
                hashes[i] = _hashPair(hashes[i - 1], hashes[i - 1]);
            }
        }
    }

    /* ---------------------------------------------------------- */
    /* Bit-extraction helpers                                     */
    /* ---------------------------------------------------------- */

    /// @notice Read bit `d` of `smtKey` MSB-first within each byte.
    ///         For indices past the key's byte length, returns 0.
    ///         Matches Lean's `BitsKey.keyBit` (ByteArray instance).
    ///
    /// @dev    For a 32-byte (256-bit) key, every bit in 0..255 is
    ///         in-range.  For a shorter key (e.g., 8 bytes for a
    ///         UInt64), bits past the end return 0 — matching the
    ///         Lean UInt64 instance which returns false for i >= 64.
    ///
    /// @param  smtKey  the SMT key bytes.
    /// @param  d       the bit index (0 = MSB of byte 0).
    /// @return bit     1 if the bit is set, 0 otherwise.
    function readKeyBitMSBFirst(bytes calldata smtKey, uint256 d)
        internal
        pure
        returns (uint256 bit)
    {
        unchecked {
            uint256 byteIdx = d >> 3; // d / 8
            if (byteIdx >= smtKey.length) return 0;
            uint256 bitIdx = 7 - (d & 7); // 7 - (d % 8) (MSB-first within byte)
            bit = (uint256(uint8(smtKey[byteIdx])) >> bitIdx) & 1;
        }
    }

    /// @notice Read bit `d` of `bitmask` LSB-first within each byte.
    ///         For indices past the bitmask's byte length, returns 0.
    ///         Matches Lean's `SmtCellProof.bitmaskBit`.
    ///
    /// @dev    Bit 0 is the LSB of byte 0; bit 7 is the MSB of byte 0;
    ///         bit 8 is the LSB of byte 1.  Distinct from the key
    ///         bit ordering (`readKeyBitMSBFirst`).
    ///
    /// @param  bitmask  the proof's 32-byte bitmask.
    /// @param  d        the bit index (0 = LSB of byte 0).
    /// @return bit      1 if the bit is set, 0 otherwise.
    function readBitmaskBit(bytes calldata bitmask, uint256 d) internal pure returns (uint256 bit) {
        unchecked {
            uint256 byteIdx = d >> 3;
            if (byteIdx >= bitmask.length) return 0;
            uint256 bitIdx = d & 7; // d % 8 (LSB-first within byte)
            bit = (uint256(uint8(bitmask[byteIdx])) >> bitIdx) & 1;
        }
    }

    /* ---------------------------------------------------------- */
    /* Walk + verifier                                            */
    /* ---------------------------------------------------------- */

    /// @notice Walk the SMT from a leaf up to the root, mixing in
    ///         the proof's siblings (or canonical-empty defaults).
    ///         Returns the reconstructed root candidate.
    ///
    /// @dev    Performs 256 keccak256 calls in the walk plus up to
    ///         255 calls to advance the canonical-empty-subtree
    ///         chain (lazily, in lockstep with the walk).  Total:
    ///         511 hashes + minor bit-extraction overhead.  No
    ///         8 KiB memory allocation — the empties chain is
    ///         tracked through a single `bytes32` accumulator that
    ///         advances each iteration via
    ///         `H_{d+1} = keccak256(H_d ‖ H_d)`.
    ///
    ///         Reverts on malformed input:
    ///           * `SmtCellProofTooShort`  — proofData < 32 bytes.
    ///           * `SmtCellSiblingsMisaligned` — siblings region not a
    ///             multiple of 32 bytes.
    ///
    /// @param  smtKey         the SMT key.  Read MSB-first per byte for
    ///                        path determination.  Any length is
    ///                        accepted; bits past `smtKey.length * 8`
    ///                        return 0 (matches Lean's
    ///                        `BitsKey.keyBit` for shorter keys).
    ///                        For 256-bit hash-bucketed keys, pass a
    ///                        32-byte value.  Bytes 32+ are silently
    ///                        ignored.
    /// @param  leafPreimage   bytes hashed to produce the leaf node;
    ///                        Lean spec: `Encodable.encode key ++
    ///                        Encodable.encode value`.  An empty
    ///                        preimage produces `keccak256(0x)`, which
    ///                        is well-defined but unusual.
    /// @param  proofData      the wire-encoded proof:
    ///                        `bitmask(32) || siblings(N x 32)`.
    /// @return root           the reconstructed root candidate.
    function recomputeRoot(
        bytes calldata smtKey,
        bytes calldata leafPreimage,
        bytes calldata proofData
    ) internal pure returns (bytes32 root) {
        if (proofData.length < BITMASK_BYTES) {
            revert SmtCellProofTooShort(proofData.length);
        }
        uint256 siblingsRegionLength = proofData.length - BITMASK_BYTES;
        if (siblingsRegionLength % HASH_BYTES != 0) {
            revert SmtCellSiblingsMisaligned(siblingsRegionLength);
        }
        uint256 siblingsCount = siblingsRegionLength / HASH_BYTES;

        bytes calldata bitmask = proofData[0:BITMASK_BYTES];
        bytes calldata siblings = proofData[BITMASK_BYTES:];

        // Initial state: leaf hash + H_0 (the leaf-level canonical
        // empty subtree hash).  emptyAtD advances per-iteration to
        // remain in lockstep with the walk's depth.
        bytes32 current = keccak256(leafPreimage);
        bytes32 emptyAtD = keccak256(EMPTY_LEAF_SEED);

        uint256 siblingsCursor = 0;
        unchecked {
            for (uint256 d = 0; d < SMT_DEPTH; ++d) {
                bytes32 sibling;
                if (readBitmaskBit(bitmask, d) == 1) {
                    if (siblingsCursor < siblingsCount) {
                        sibling = _readSiblingAt(siblings, siblingsCursor);
                        ++siblingsCursor;
                    } else {
                        sibling = PADDING_HASH;
                    }
                } else {
                    sibling = emptyAtD;
                }

                if (readKeyBitMSBFirst(smtKey, d) == 1) {
                    // Right child: parent = keccak256(sibling || current)
                    current = _hashPair(sibling, current);
                } else {
                    // Left child: parent = keccak256(current || sibling)
                    current = _hashPair(current, sibling);
                }

                // Advance emptyAtD = keccak256(H_d || H_d) for the
                // next iteration.  Skip at d=255 since H_256 is not
                // needed (the walk terminates at d=255).
                if (d < SMT_DEPTH - 1) {
                    emptyAtD = _hashPair(emptyAtD, emptyAtD);
                }
            }
        }
        root = current;
    }

    /// @notice Verify a cell proof against a claimed root.  Returns
    ///         true iff the proof reconstructs to `root`; returns
    ///         false on a structural mismatch (well-formed proof,
    ///         wrong root) AND on a wire-format violation (malformed
    ///         proof data).
    ///
    /// @dev    Non-reverting: a malformed proof returns `false`
    ///         rather than reverting.  This matches the Lean
    ///         reference (`verifySmtCellProof = isWellFormed &&
    ///         decide (walk = root)`) and gives the L1 caller a
    ///         single boolean verdict regardless of input shape.
    ///
    /// @param  root          the claimed SMT root.
    /// @param  smtKey        the SMT key (MSB-first bit reads).
    /// @param  leafPreimage  bytes hashed to produce the leaf node.
    /// @param  proofData     the wire-encoded proof.
    /// @return ok            true iff the proof verifies.
    function verifyCellProof(
        bytes32 root,
        bytes calldata smtKey,
        bytes calldata leafPreimage,
        bytes calldata proofData
    ) internal pure returns (bool ok) {
        // Well-formedness checks (mirror Lean's `isWellFormed`,
        // implicit in our wire format: bitmask = first 32 bytes,
        // siblings region = remaining bytes split into 32-byte
        // hashes).
        if (proofData.length < BITMASK_BYTES) return false;
        uint256 siblingsRegionLength = proofData.length - BITMASK_BYTES;
        if (siblingsRegionLength % HASH_BYTES != 0) return false;

        // Walk + compare.  The walk itself never reverts because we
        // already validated the input shape.
        ok = recomputeRoot(smtKey, leafPreimage, proofData) == root;
    }

    /* ---------------------------------------------------------- */
    /* Errors                                                     */
    /* ---------------------------------------------------------- */

    /// @notice Reverted by `recomputeRoot` when `proofData` is too
    ///         short to contain a 32-byte bitmask.
    error SmtCellProofTooShort(uint256 actualLength);

    /// @notice Reverted by `recomputeRoot` when the siblings region
    ///         of `proofData` is not a multiple of 32 bytes.
    error SmtCellSiblingsMisaligned(uint256 siblingsRegionLength);

    /// @notice Reverted by `emptySubtreeHash` when `d >= 256`.
    error SmtCellDepthOutOfRange(uint256 depth);

    /* ---------------------------------------------------------- */
    /* Internal helpers                                           */
    /* ---------------------------------------------------------- */

    /// @notice Gas-optimal hash of two 32-byte values:
    ///         `keccak256(a || b)`.  Uses the EVM scratch space at
    ///         memory offsets `0x00` and `0x20`, avoiding any free-
    ///         memory pointer update.
    ///
    /// @dev    The Solidity reserved scratch space (`0x00`..`0x3f`)
    ///         is exclusively for use by inline assembly, per the
    ///         language specification.  Writing to it does not
    ///         interfere with any compiler-allocated memory.
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }

    /// @notice Read the `idx`-th 32-byte sibling from a calldata
    ///         siblings region.  The caller MUST ensure
    ///         `(idx + 1) * 32 <= siblings.length`.
    ///
    /// @dev    Uses `calldataload` for a direct 32-byte read from
    ///         calldata; avoids a `bytes` slicing allocation.
    ///         `idx * HASH_BYTES` is wrapped in `unchecked` because
    ///         `idx` is bounded by `siblingsCount <= proofData.length
    ///         / 32`, which is bounded by the EVM block gas limit
    ///         (well under `type(uint256).max / 32`).
    function _readSiblingAt(bytes calldata siblings, uint256 idx) private pure returns (bytes32 s) {
        unchecked {
            uint256 offset = idx * HASH_BYTES;
            /// @solidity memory-safe-assembly
            assembly {
                s := calldataload(add(siblings.offset, offset))
            }
        }
    }
}
