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
///         **Gas cost.**  One walk is 256 keccak256 calls per leaf
///         plus per-iteration bit extraction and branching.  The
///         canonical empty-subtree chain is NOT rebuilt per walk: the
///         caller builds it once with `precomputeEmptySubtreeHashes`
///         and threads it in, because a step VM walks many openings and
///         the chain is a constant of the scheme.  A write opens and
///         re-walks in a SINGLE pass
///         (`recomputeRootPairFromLeaves`), since the two differ only
///         in their leaf.
///
///         The dominant term is the 256-iteration loop itself rather
///         than its hashing, so the bit sources are hoisted out of it:
///         the key and the bitmask are each ONE word, loaded once and
///         shifted, instead of a bounds-checked byte load per level.
///         The exact cost depends on the proof's bitmask (no extra
///         calldata for unset bits; one `calldataload` per set bit) and
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
    ///         computations.  The walk does not call this per level —
    ///         it reads `precomputeEmptySubtreeHashes()`'s table, built
    ///         once by the caller.
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
    ///         into an in-memory array — `H_0 = keccak256("EMPTY_LEAF")`,
    ///         `H_{d+1} = keccak256(H_d ‖ H_d)`.  Mirrors Lean's
    ///         memoised `emptySubtreeHash` (`FaultProof/Smt.lean`).
    ///
    /// @dev    **The walk's source of empty siblings.**  This used to be
    ///         a test-and-script helper that the walk pointedly did not
    ///         call: `recomputeRoot` advanced a single `bytes32`
    ///         accumulator through the chain in lockstep, one
    ///         `keccak256` per level, "to avoid an 8 KiB memory
    ///         allocation".  That trade is the wrong way round at
    ///         step-VM scale.  The allocation costs ~896 gas ONCE per
    ///         transaction; the accumulator costs 255 hashes per WALK,
    ///         and a terminal step walks twice per opening — so a
    ///         five-opening step rebuilt this identical chain ten
    ///         times.  The table is now built once by the caller and
    ///         threaded down.
    ///
    ///         Still `pure` and still returned by value: a verifier a
    ///         challenger can run off-chain must not depend on
    ///         deployment storage, and 255 `SLOAD`s would cost far more
    ///         than the hashes they replaced.
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
    function readKeyBitMSBFirst(bytes memory smtKey, uint256 d)
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

    /// @notice `smtKey`'s first 32 bytes as a big-endian word,
    ///         right-zero-padded when the key is shorter.
    ///
    /// @dev    **The walk's key, hoisted.**  A 256-level walk read one
    ///         bit per level with `readKeyBitMSBFirst`, and each read
    ///         was a bounds check plus a single-byte `mload` plus a
    ///         mask and a shift — 256 times over data that never
    ///         changes and fits in one word.  The key is loaded once
    ///         here and the walk shifts.
    ///
    ///         The right-zero-padding is what makes this agree with the
    ///         byte-wise reader rather than merely resemble it: a key
    ///         shorter than 32 bytes must read 0 at every bit at or
    ///         past `8 * length` (Lean's `BitsKey ByteArray` instance
    ///         returns `false` there), and masking off the trailing
    ///         bytes delivers exactly that.
    ///
    ///         **Scope: bit indices 0..255 only.**  This word covers
    ///         the first 32 bytes, so an OVER-LONG key's bits at index
    ///         256 and above are not in it — and those are bits the
    ///         byte-wise reader (and Lean) genuinely return, since
    ///         `BitsKey ByteArray` reads any `i < 8 * size`.  The walk
    ///         only ever asks for `d < SMT_DEPTH`, which is why the
    ///         hoist is sound there and why `readKeyBitMSBFirst` keeps
    ///         its byte-wise body for the general contract.
    ///         `test_word_readers_diverge_past_the_first_word` pins
    ///         that boundary rather than leaving it to be rediscovered.
    function keyWord(bytes memory smtKey) internal pure returns (uint256 w) {
        uint256 len = smtKey.length;
        /// @solidity memory-safe-assembly
        assembly {
            w := mload(add(smtKey, 32))
        }
        if (len < HASH_BYTES) {
            // Keep the top `len` bytes, zero the rest.  `len << 3 < 256`
            // here, so the shift is well-defined.
            unchecked {
                w &= ~(type(uint256).max >> (len << 3));
            }
        }
    }

    /// @notice Bit `d` of a key word, MSB-first — the word form of
    ///         `readKeyBitMSBFirst` on the walk's domain.  **Caller
    ///         MUST guarantee `d < 256`**; the shift underflows
    ///         otherwise.
    ///
    /// @dev    Byte `d / 8` of a big-endian word sits at bit positions
    ///         `8·(31 − d/8) + 7 … 8·(31 − d/8)`, and bit `d % 8`
    ///         counted MSB-first within it is offset `7 − (d % 8)` —
    ///         which sums to `255 − d`.
    function keyBitFromWord(uint256 keyW, uint256 d) internal pure returns (uint256) {
        unchecked {
            return (keyW >> (255 - d)) & 1;
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

    /// @notice `bitmask`'s first 32 bytes as a big-endian word,
    ///         right-zero-padded when it is shorter.  The bitmask
    ///         counterpart of `keyWord`, hoisted out of the walk for
    ///         the same reason and carrying the same 0..255 scope.
    function bitmaskWord(bytes calldata bitmask) internal pure returns (uint256 w) {
        uint256 len = bitmask.length;
        /// @solidity memory-safe-assembly
        assembly {
            w := calldataload(bitmask.offset)
        }
        if (len < BITMASK_BYTES) {
            unchecked {
                w &= ~(type(uint256).max >> (len << 3));
            }
        }
    }

    /// @notice Bit `d` of a bitmask word, LSB-first WITHIN each byte —
    ///         the word form of `readBitmaskBit` on the walk's domain.
    ///         **Caller MUST guarantee `d < 256`**; the subtraction
    ///         underflows otherwise.
    ///
    /// @dev    Deliberately not `255 - d`: the bitmask's convention is
    ///         the key's mirror image within the byte (bit 0 is the LSB
    ///         of byte 0, bit 7 its MSB), so the offset is
    ///         `8·(31 − d/8) + (d % 8)`.  The two conventions differing
    ///         is a property of the wire format, and expressing both
    ///         here — beside each other — is what keeps the difference
    ///         deliberate rather than a transcription hazard.
    function bitmaskBitFromWord(uint256 maskW, uint256 d) internal pure returns (uint256) {
        unchecked {
            return (maskW >> (((31 - (d >> 3)) << 3) + (d & 7))) & 1;
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
        bytes memory smtKey,
        bytes memory leafPreimage,
        bytes calldata proofData
    ) internal pure returns (bytes32 root) {
        root = recomputeRootFromLeaf(smtKey, keccak256(leafPreimage), proofData);
    }

    /// @notice The same walk, started from a LEAF HASH rather than
    ///         from a preimage.
    ///
    /// @dev    `recomputeRoot` above hashes its preimage
    ///         unconditionally, which is correct for a verifier handed
    ///         an opaque preimage and WRONG for a step VM: a cell the
    ///         state does not hold has an empty sub-tree beneath its
    ///         key, so its opening walks from the canonical empty leaf
    ///         rather than from `keccak256(key || value)`.  Lean's
    ///         `cellLeaf` makes that branch; the caller must too, and
    ///         it needs an entry point that takes the leaf it decided
    ///         on.
    ///
    ///         The preimage path is deliberately left as a wrapper
    ///         rather than reworked: it is pinned byte-for-byte by
    ///         `smt_cell_proof.json`, and routing it through this
    ///         function keeps the two walks provably the same code
    ///         rather than two implementations that must agree.
    ///
    /// @param  smtKey     the SMT key (MSB-first bit reads).
    /// @param  leaf       the leaf node hash to start the walk from.
    /// @param  proofData  the wire-encoded proof:
    ///                    `bitmask(32) || siblings(N x 32)`.
    /// @return root       the reconstructed root candidate.
    function recomputeRootFromLeaf(
        bytes memory smtKey,
        bytes32 leaf,
        bytes calldata proofData
    ) internal pure returns (bytes32 root) {
        (root,) = recomputeRootPairFromLeaves(
            keyWord(smtKey), leaf, leaf, proofData, precomputeEmptySubtreeHashes());
    }

    /// @notice **One walk, two leaves.**  Recompute the root a proof
    ///         opens against from `oldLeaf`, and the root the same
    ///         proof reaches from `newLeaf`, in a single pass.
    ///
    /// @dev    A cell write needs both: the OLD root to check the
    ///         opening against the state it claims to be against, and
    ///         the NEW root the write produces.  Both walks consume the
    ///         same key bits and the same siblings — the leaf is the
    ///         entire difference — so running them separately pays
    ///         twice for the proof parse, the 256 bitmask reads, the
    ///         256 key-bit reads, the sibling cursor and the loop
    ///         itself, and only the two `keccak256`s per level are
    ///         genuinely distinct work.  Fusing them halves the
    ///         dominant cost of the fold.
    ///
    ///         Callers that need only one root pass the same leaf
    ///         twice; the second accumulator then tracks the first and
    ///         is discarded.  That keeps ONE walk implementation rather
    ///         than two that must agree — the same reasoning that keeps
    ///         `recomputeRoot`'s preimage path a wrapper.
    ///
    /// @param  keyW       the SMT key as a word, from `keyWord` (or
    ///                    `uint256(bytes32 key)` for a caller that
    ///                    already holds a 32-byte derived key).
    /// @param  oldLeaf    the leaf the proof is claimed to open.
    /// @param  newLeaf    the leaf the write installs.
    /// @param  proofData  the wire-encoded proof:
    ///                    `bitmask(32) || siblings(N x 32)`.
    /// @param  empties    the canonical empty-subtree chain, from
    ///                    `precomputeEmptySubtreeHashes()`.
    /// @return oldRoot    the root reached from `oldLeaf`.
    /// @return newRoot    the root reached from `newLeaf`.
    function recomputeRootPairFromLeaves(
        uint256 keyW,
        bytes32 oldLeaf,
        bytes32 newLeaf,
        bytes calldata proofData,
        bytes32[SMT_DEPTH] memory empties
    ) internal pure returns (bytes32 oldRoot, bytes32 newRoot) {
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

        bytes32 currentOld = oldLeaf;
        bytes32 currentNew = newLeaf;

        // The bitmask is a single word that does not change across the
        // 256 levels, so it is loaded once rather than bounds-checked
        // and byte-indexed per level.  The key arrives already in that
        // form: every step-VM caller derives it as a `bytes32`, so
        // packing it into `bytes` only to unpack it again would be a
        // conversion that exists to be undone.
        uint256 maskW = bitmaskWord(bitmask);

        uint256 siblingsCursor = 0;
        unchecked {
            for (uint256 d = 0; d < SMT_DEPTH; ++d) {
                bytes32 sibling;
                if (bitmaskBitFromWord(maskW, d) == 1) {
                    if (siblingsCursor < siblingsCount) {
                        sibling = _readSiblingAt(siblings, siblingsCursor);
                        ++siblingsCursor;
                    } else {
                        sibling = PADDING_HASH;
                    }
                } else {
                    sibling = empties[d];
                }

                if (keyBitFromWord(keyW, d) == 1) {
                    // Right child: parent = keccak256(sibling || current)
                    currentOld = _hashPair(sibling, currentOld);
                    currentNew = _hashPair(sibling, currentNew);
                } else {
                    // Left child: parent = keccak256(current || sibling)
                    currentOld = _hashPair(currentOld, sibling);
                    currentNew = _hashPair(currentNew, sibling);
                }
            }
        }
        oldRoot = currentOld;
        newRoot = currentNew;
    }

    /// @notice The canonical empty-leaf hash — the value a cell with
    ///         no entry walks from.  Mirrors Lean's `emptyRootAt 0`.
    ///
    /// @dev    Exposed because the absent branch belongs in the
    ///         CALLER: this library takes a leaf, and only the caller
    ///         knows whether the cell it is opening is present.
    function emptyLeafHash() internal pure returns (bytes32) {
        return keccak256(EMPTY_LEAF_SEED);
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
        bytes memory smtKey,
        bytes memory leafPreimage,
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
