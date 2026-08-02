// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title SmtVerifier
/// @notice Solidity port of `LegalKernel.Bridge.WithdrawalRoot.verifyProof`
///         (workstream D.1.2 / D.1.4).  Re-computes the SMT root from a
///         leaf, an index, and a sibling path; compares to the asserted
///         root; returns the boolean equivalence.
///
/// @dev    **Mathematical invariants** (must mirror Lean exactly):
///
///         1. Tree height `SMT_HEIGHT = 64` (matches WithdrawalId domain).
///         2. Sibling array is **root-to-leaf ordered**: `siblings[0]` is
///            root-adjacent, `siblings[63]` is leaf-adjacent.
///         3. Path-bit indexing is **LSB-up**: `bit_k = (idx >> k) & 1`,
///            where `bit_0` selects at the leaf level and `bit_63` at
///            the root level.
///         4. Per-level combinator `hashUp`:
///              - `bit = 0` (left child): `keccak256(current ‖ sibling)`
///              - `bit = 1` (right child): `keccak256(sibling ‖ current)`
///
///         **Variable-size leaf and siblings (post-audit-2 fix).**
///         Lean's `WithdrawalProof.leaf : ByteArray` is variable-size
///         (raw `leafBytes wd` ≈ 56 bytes for a populated cell, 32
///         bytes for the empty sentinel).  Lean's
///         `WithdrawalProof.siblings : Vector ByteArray smtHeight`
///         allows each sibling to be a variable-size ByteArray;
///         in the dense-pair case (sequentially-assigned
///         WithdrawalIds 0 and 1 share a deepest pair), the
///         leaf-adjacent sibling for id 0 is `leafBytes wd_1` ≈ 56
///         bytes, not the typical 32-byte default.
///
///         The pre-audit-2 Solidity port assumed leaves and
///         siblings were uniformly 32 bytes (using `bytes32`),
///         which silently broke cross-stack equivalence: a Lean-
///         built proof in the dense-pair case would NOT verify
///         on-chain.  This audit-2 fix takes leaf and siblings as
///         variable-size `bytes` so the cross-stack proof shape
///         matches Lean byte-for-byte.
///
///         **Cross-stack soundness** (verified by F.1.5 fixtures):
///         the verifier accepts a proof iff the canonical Lean
///         constructor would accept it, byte-for-byte.
library SmtVerifier {
    /// @notice Tree height; matches Lean's `smtHeight`.
    uint256 internal constant SMT_HEIGHT = 64;

    /// @notice Reverts when the supplied proof's siblings array does
    ///         not have exactly `SMT_HEIGHT` entries.
    error SmtBadProofShape(uint256 expected, uint256 actual);

    /// @notice Reverts when an upper-level (non-leaf-adjacent) sibling
    ///         is not exactly 32 bytes.  This enforces the size
    ///         discipline the Lean soundness theorem
    ///         `verifyProof_sound` (`WithdrawalRoot.lean`) requires as
    ///         its `h_sibs_match` precondition: canonical proofs have
    ///         32-byte keccak-output / default-hash siblings at every
    ///         level above the leaf, so an off-size upper sibling is
    ///         malformed.  `siblingArrayIndex` is the index into the
    ///         root-to-leaf `siblings` array (0 = root-adjacent).
    error SmtBadSiblingSize(uint256 siblingArrayIndex, uint256 actualSize);

    /// @notice Compute the SMT root from a leaf at index `idx` plus
    ///         a sibling path.  Returns the recomputed root.  Caller
    ///         compares to the asserted root.
    ///
    ///         `siblings.length` MUST equal `SMT_HEIGHT`; reverts
    ///         with `SmtBadProofShape` otherwise.  Each `siblings[i]`
    ///         is `bytes` (variable-length); typical sparse cases
    ///         have all siblings equal to 32-byte default-hash
    ///         values, but the dense-pair case includes a variable-
    ///         size leaf-adjacent sibling.
    function recomputeRoot(uint256 idx, bytes memory leaf, bytes[] memory siblings)
        internal
        pure
        returns (bytes32 root)
    {
        if (siblings.length != SMT_HEIGHT) {
            revert SmtBadProofShape(SMT_HEIGHT, siblings.length);
        }

        // Level 0 → level 1: hash the variable-size leaf with the
        // leaf-adjacent sibling (siblings[63]).  The result is a
        // 32-byte keccak output.
        bytes32 current;
        {
            bytes memory leafSibling = siblings[SMT_HEIGHT - 1];
            uint256 bit0 = idx & 1;
            if (bit0 == 1) {
                current = keccak256(abi.encodePacked(leafSibling, leaf));
            } else {
                current = keccak256(abi.encodePacked(leaf, leafSibling));
            }
        }

        // Level 1 → level SMT_HEIGHT: `current` is bytes32 (a keccak
        // output) and every upper-level sibling MUST be exactly 32
        // bytes.  Enforcing this supplies the Lean `verifyProof_sound`
        // `h_sibs_match` precondition structurally: a canonical proof's
        // siblings above the leaf are always 32-byte keccak-output /
        // default-hash values, so an off-size upper sibling is
        // malformed.  Without the check, the `keccak256(sibling ‖
        // current)` packing (bit == 1) would have an attacker-movable
        // operand boundary — the size-witness gap the Lean soundness
        // docstring warns about.  The ONLY legitimately variable-size
        // operand (the dense-pair leaf-adjacent sibling) is
        // `siblings[SMT_HEIGHT-1]`, consumed at the leaf level above and
        // therefore NOT covered by this loop.
        unchecked {
            for (uint256 i = 1; i < SMT_HEIGHT; ++i) {
                uint256 arrayIndex = SMT_HEIGHT - 1 - i;
                bytes memory sibling = siblings[arrayIndex];
                if (sibling.length != 32) {
                    revert SmtBadSiblingSize(arrayIndex, sibling.length);
                }
                // The size check above makes `sibling` exactly one
                // word, so the pair is hashed through the EVM scratch
                // space rather than by allocating and copying a fresh
                // 64-byte `bytes` per level.  Byte-identical: both
                // forms hash the same 64-byte concatenation.
                bytes32 sib;
                /// @solidity memory-safe-assembly
                assembly {
                    sib := mload(add(sibling, 32))
                }
                uint256 bit = (idx >> i) & 1;
                if (bit == 1) {
                    current = _hashPair(sib, current);
                } else {
                    current = _hashPair(current, sib);
                }
            }
        }
        root = current;
    }

    /// @notice Verify a withdrawal proof against an asserted root.
    ///         Returns `true` iff the recomputed root matches.
    function verifyProof(
        uint256 idx,
        bytes memory leaf,
        bytes[] memory siblings,
        bytes32 root
    ) internal pure returns (bool) {
        return recomputeRoot(idx, leaf, siblings) == root;
    }

    /// @notice The level-`i` "all-empty subtree" hash — mirror of
    ///         Lean's `defaultHash`.  Used by the canonical
    ///         "non-membership" proof shape and for fixture
    ///         constructors.
    ///
    ///         `emptyHashAtLevel(0) = bytes32(0)` (the
    ///         `emptyLeafHash` sentinel; matches Lean's `zeroHash`).
    ///         `emptyHashAtLevel(i+1) = keccak256(prev ‖ prev)`.
    function emptyHashAtLevel(uint256 level) internal pure returns (bytes32 h) {
        h = bytes32(0);
        unchecked {
            for (uint256 i = 0; i < level; ++i) {
                h = _hashPair(h, h);
            }
        }
    }

    /// @notice The top-level empty-subtree hash for the standard
    ///         `SMT_HEIGHT = 64` tree.
    ///
    /// @dev    `SMT_HEIGHT` sequential hashes.  A caller needing it
    ///         repeatedly in one transaction should hoist it into a
    ///         local, the same way `emptyProofSiblings` does — it is
    ///         a constant of the scheme, not a function of any input.
    function defaultHashTop() internal pure returns (bytes32) {
        return emptyHashAtLevel(SMT_HEIGHT);
    }

    /// @notice Convenience: the canonical "all-empty" proof shape
    ///         for any index in an empty SMT.  Each sibling is the
    ///         `defaultHash` at the level that sibling sits in.
    ///         `siblings[0]` (root-adjacent) = `defaultHash 63`;
    ///         `siblings[63]` (leaf-adjacent) = `defaultHash 0`
    ///         (the `emptyLeafHash` = bytes32(0) sentinel).
    ///
    ///         Used by tests and by the canonical non-membership
    ///         proof shape.
    ///
    /// @dev    Built in ONE ascending pass.  Calling
    ///         `emptyHashAtLevel(level)` per entry — as this did — is
    ///         quadratic: that function restarts the recurrence from
    ///         `bytes32(0)` every time, so producing a 64-entry chain
    ///         cost `64·63/2 = 2016` hashes to compute 63 distinct
    ///         values.  The chain is a prefix of itself, so one
    ///         accumulator suffices; the entries are written
    ///         back-to-front because `siblings` is root-adjacent-first
    ///         while the recurrence runs leaf-upward.
    function emptyProofSiblings() internal pure returns (bytes[] memory siblings) {
        siblings = new bytes[](SMT_HEIGHT);
        bytes32 h = bytes32(0); // level 0: the `emptyLeafHash` sentinel.
        unchecked {
            for (uint256 level = 0; level < SMT_HEIGHT; ++level) {
                // siblings[i] sits at level (SMT_HEIGHT - 1 - i), so
                // level `level` lands at index `SMT_HEIGHT - 1 - level`.
                siblings[SMT_HEIGHT - 1 - level] = abi.encodePacked(h);
                h = _hashPair(h, h);
            }
        }
    }

    /// @notice `keccak256(a ‖ b)` through the EVM scratch space.
    ///
    /// @dev    Identical output to `keccak256(abi.encodePacked(a, b))`
    ///         and identical to `SmtCellVerifier._hashPair`, without
    ///         allocating a 64-byte `bytes` per call — which matters
    ///         because every caller here is a loop.
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }

}
