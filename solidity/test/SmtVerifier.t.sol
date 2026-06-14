// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";

/// @title SmtVerifierProxy
/// @notice External wrapper around `SmtVerifier`'s internal library
///         functions so test fixtures can be passed as `bytes
///         memory` / `bytes[] memory` and converted to the internal
///         calldata signature.
contract SmtVerifierProxy {
    function recomputeRoot(uint256 idx, bytes memory leaf, bytes[] memory siblings)
        external
        pure
        returns (bytes32)
    {
        return SmtVerifier.recomputeRoot(idx, leaf, siblings);
    }

    function verifyProof(uint256 idx, bytes memory leaf, bytes[] memory siblings, bytes32 root)
        external
        pure
        returns (bool)
    {
        return SmtVerifier.verifyProof(idx, leaf, siblings, root);
    }

    function emptyHashAtLevel(uint256 level) external pure returns (bytes32) {
        return SmtVerifier.emptyHashAtLevel(level);
    }

    function defaultHashTop() external pure returns (bytes32) {
        return SmtVerifier.defaultHashTop();
    }

    function emptyProofSiblings() external pure returns (bytes[] memory) {
        return SmtVerifier.emptyProofSiblings();
    }
}

/// @title SmtVerifierTest
/// @notice Tests for the SMT verifier with the post-audit-2 API
///         (variable-size `bytes` for leaf and each sibling) so the
///         dense-pair case (where the leaf-adjacent sibling is
///         itself a ~56-byte raw leaf) is exercised.
contract SmtVerifierTest is Test {
    SmtVerifierProxy private smt;

    bytes32 private emptyAt0; // = bytes32(0)
    bytes32 private emptyAt1; // = keccak256(0 ‖ 0)
    bytes32 private emptyAt63; // leaf-of-root level
    bytes32 private emptyAt64; // root level

    function setUp() public {
        smt = new SmtVerifierProxy();
        emptyAt0 = bytes32(0);
        emptyAt1 = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        emptyAt63 = smt.emptyHashAtLevel(63);
        emptyAt64 = smt.emptyHashAtLevel(64);
    }

    // ---- emptyHashAtLevel tests ----

    function test_emptyHashAtLevel_zero_is_zero_bytes32() public view {
        assertEq(smt.emptyHashAtLevel(0), bytes32(0));
    }

    function test_emptyHashAtLevel_one_recursion_step() public view {
        bytes32 expected = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        assertEq(smt.emptyHashAtLevel(1), expected);
    }

    function test_emptyHashAtLevel_two_recursion_steps() public view {
        bytes32 step1 = keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
        bytes32 step2 = keccak256(abi.encodePacked(step1, step1));
        assertEq(smt.emptyHashAtLevel(2), step2);
    }

    function test_emptyHashAtLevel_64_matches_defaultHashTop() public view {
        assertEq(smt.emptyHashAtLevel(64), smt.defaultHashTop());
    }

    // ---- recomputeRoot / verifyProof shape tests ----

    function test_recomputeRoot_revert_on_wrong_siblings_length() public {
        bytes[] memory short_ = new bytes[](63);
        bytes memory zeroLeaf = abi.encodePacked(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SmtVerifier.SmtBadProofShape.selector, 64, 63));
        smt.recomputeRoot(0, zeroLeaf, short_);
    }

    // ---- audit 21 / B.1: per-sibling SIZE discipline (soundness) ----

    /// @notice CRITICAL SECURITY TEST (audit 21, B.1): an upper-level
    ///         (non-leaf-adjacent) sibling that is NOT exactly 32 bytes
    ///         must be rejected.  Canonical proofs always have 32-byte
    ///         keccak-output siblings above the leaf; allowing an
    ///         off-size operand reopens the `keccak256(sibling ‖
    ///         current)` boundary the Lean `verifyProof_sound`
    ///         `h_sibs_match` precondition closes.  `siblings[0]` is
    ///         root-adjacent — squarely an upper level.
    function test_recomputeRoot_revert_on_oversized_upper_sibling() public {
        bytes[] memory siblings = smt.emptyProofSiblings();
        // Make the root-adjacent sibling 33 bytes (off-size).
        siblings[0] = abi.encodePacked(bytes32(0), bytes1(0x00));
        bytes memory leaf = abi.encodePacked(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(
            SmtVerifier.SmtBadSiblingSize.selector, uint256(0), uint256(33)));
        smt.recomputeRoot(0, leaf, siblings);
    }

    function test_recomputeRoot_revert_on_undersized_upper_sibling() public {
        bytes[] memory siblings = smt.emptyProofSiblings();
        // A mid-level (upper) sibling that is 31 bytes.
        siblings[30] = new bytes(31);
        bytes memory leaf = abi.encodePacked(bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(
            SmtVerifier.SmtBadSiblingSize.selector, uint256(30), uint256(31)));
        smt.recomputeRoot(0, leaf, siblings);
    }

    /// @notice The dense-pair case must STILL be accepted: the
    ///         leaf-adjacent sibling (`siblings[63]`) is consumed at the
    ///         leaf level and is legitimately variable-size (e.g. the
    ///         ~56-byte encoding of the paired leaf).  The size check
    ///         must NOT reject it — proving the B.1 fix doesn't
    ///         over-restrict.
    function test_recomputeRoot_accepts_variable_leaf_adjacent_sibling() public view {
        bytes[] memory siblings = smt.emptyProofSiblings();
        // A 56-byte leaf-adjacent sibling (the dense-pair shape).
        siblings[63] = new bytes(56);
        bytes memory leaf = abi.encodePacked(bytes32(0));
        // Must NOT revert (returns some root deterministically).
        bytes32 root = smt.recomputeRoot(0, leaf, siblings);
        bytes32 root2 = smt.recomputeRoot(0, leaf, siblings);
        assertEq(root, root2, "variable leaf-adjacent sibling is accepted + deterministic");
    }

    /// @notice The all-empty proof for an empty-leaf at index 0
    ///         should recompute to the empty-tree top hash.  The
    ///         leaf is the 32-byte sentinel (defaultHash 0 =
    ///         bytes32(0)).
    function test_recomputeRoot_empty_proof_at_index_0_returns_top_default() public view {
        bytes[] memory siblings = smt.emptyProofSiblings();
        bytes memory leaf = abi.encodePacked(bytes32(0));
        bytes32 root = smt.recomputeRoot(0, leaf, siblings);
        assertEq(root, emptyAt64);
    }

    function test_recomputeRoot_empty_proof_at_arbitrary_index() public view {
        bytes[] memory siblings = smt.emptyProofSiblings();
        bytes memory leaf = abi.encodePacked(bytes32(0));
        bytes32 root = smt.recomputeRoot(0xDEADBEEF, leaf, siblings);
        assertEq(root, emptyAt64);
    }

    /// @notice A populated leaf at index 0 with all-empty siblings:
    ///         the root should be the canonical hash chain
    ///         leaf → H(leaf ‖ emptyAt0) → H(prev ‖ emptyAt1) → ...
    ///         (since bit_k = 0 for all k when idx = 0).
    function test_recomputeRoot_populated_leaf_index_0() public view {
        bytes memory leaf = abi.encodePacked(keccak256("withdrawal-fixture-1"));
        bytes[] memory siblings = smt.emptyProofSiblings();

        // Bottom level (i=0): hash leaf (32 bytes here) with sibling[63] = emptyAt0.
        bytes32 expected = keccak256(abi.encodePacked(leaf, abi.encodePacked(emptyAt0)));
        // Levels 1..63: bit_k = 0, sibling is emptyAt_k.
        for (uint256 i = 1; i < 64; ++i) {
            bytes32 sib = smt.emptyHashAtLevel(i);
            expected = keccak256(abi.encodePacked(expected, sib));
        }
        bytes32 root = smt.recomputeRoot(0, leaf, siblings);
        assertEq(root, expected);
    }

    function test_recomputeRoot_populated_leaf_index_1() public view {
        bytes memory leaf = abi.encodePacked(keccak256("withdrawal-fixture-2"));
        bytes[] memory siblings = smt.emptyProofSiblings();

        // Bottom level (i=0): bit_0=1, sibling=emptyAt0=bytes32(0); hash(sibling, leaf).
        bytes32 expected = keccak256(abi.encodePacked(abi.encodePacked(emptyAt0), leaf));
        // Levels 1..63: bit_k=0, sibling=emptyAt_k; hash(current, sibling).
        for (uint256 i = 1; i < 64; ++i) {
            bytes32 sib = smt.emptyHashAtLevel(i);
            expected = keccak256(abi.encodePacked(expected, sib));
        }
        bytes32 root = smt.recomputeRoot(1, leaf, siblings);
        assertEq(root, expected);
    }

    function test_verifyProof_returns_true_on_match() public view {
        bytes memory leaf = abi.encodePacked(keccak256("ok"));
        bytes[] memory siblings = smt.emptyProofSiblings();
        bytes32 root = smt.recomputeRoot(42, leaf, siblings);
        assertTrue(smt.verifyProof(42, leaf, siblings, root));
    }

    function test_verifyProof_returns_false_on_wrong_root() public view {
        bytes memory leaf = abi.encodePacked(keccak256("ok"));
        bytes[] memory siblings = smt.emptyProofSiblings();
        bytes32 wrong = keccak256("wrong");
        assertFalse(smt.verifyProof(42, leaf, siblings, wrong));
    }

    function test_verifyProof_returns_false_on_wrong_index() public view {
        bytes memory leaf = abi.encodePacked(keccak256("ok"));
        bytes[] memory siblings = smt.emptyProofSiblings();
        bytes32 root = smt.recomputeRoot(42, leaf, siblings);
        assertFalse(smt.verifyProof(43, leaf, siblings, root));
    }

    function test_verifyProof_returns_false_on_wrong_leaf() public view {
        bytes memory leaf = abi.encodePacked(keccak256("ok"));
        bytes memory wrongLeaf = abi.encodePacked(keccak256("evil"));
        bytes[] memory siblings = smt.emptyProofSiblings();
        bytes32 root = smt.recomputeRoot(42, leaf, siblings);
        assertFalse(smt.verifyProof(42, wrongLeaf, siblings, root));
    }

    function test_verifyProof_returns_false_on_tampered_sibling() public view {
        bytes memory leaf = abi.encodePacked(keccak256("ok"));
        bytes[] memory siblings = smt.emptyProofSiblings();
        bytes32 root = smt.recomputeRoot(42, leaf, siblings);

        // Tamper one byte of the leaf-adjacent sibling.
        siblings[63] = abi.encodePacked(keccak256("tampered"));
        assertFalse(smt.verifyProof(42, leaf, siblings, root));
    }

    function test_recomputeRoot_distinct_leaves_distinct_roots() public view {
        bytes memory leafA = abi.encodePacked(keccak256("alpha"));
        bytes memory leafB = abi.encodePacked(keccak256("beta"));
        bytes[] memory siblings = smt.emptyProofSiblings();
        bytes32 rootA = smt.recomputeRoot(7, leafA, siblings);
        bytes32 rootB = smt.recomputeRoot(7, leafB, siblings);
        assertTrue(rootA != rootB);
    }

    function test_recomputeRoot_distinct_indices_distinct_roots() public view {
        bytes memory leaf = abi.encodePacked(keccak256("same-leaf"));
        bytes[] memory siblings = smt.emptyProofSiblings();
        bytes32 root0 = smt.recomputeRoot(0, leaf, siblings);
        bytes32 root1 = smt.recomputeRoot(1, leaf, siblings);
        assertTrue(root0 != root1);
    }

    function test_recomputeRoot_deterministic() public view {
        bytes memory leaf = abi.encodePacked(keccak256("det"));
        bytes[] memory siblings = _populatedSiblings();
        bytes32 root1 = smt.recomputeRoot(0xCAFE, leaf, siblings);
        bytes32 root2 = smt.recomputeRoot(0xCAFE, leaf, siblings);
        assertEq(root1, root2);
    }

    // ---- Audit-2: variable-size leaf + variable-size leaf-adjacent sibling ----

    /// @notice The dense-pair case: the leaf-adjacent sibling at
    ///         level 0 is itself a populated leaf (~56 bytes), not
    ///         a 32-byte default hash.  The pre-audit-2 Solidity
    ///         port could not represent this; this test pins the
    ///         post-fix behaviour.
    function test_audit2_dense_pair_variable_size_leaf_adjacent_sibling() public view {
        // Construct a 56-byte raw leaf (mimicking Lean's
        // `leafBytes wd` for a populated cell).
        bytes memory leaf = new bytes(56);
        for (uint8 i = 0; i < 56; ++i) leaf[uint256(i)] = bytes1(i + 1);

        // Construct a 56-byte raw leaf as the leaf-adjacent
        // sibling (the OTHER half of the dense pair).
        bytes memory pairSibling = new bytes(56);
        for (uint8 i = 0; i < 56; ++i) pairSibling[uint256(i)] = bytes1(0xFF - i);

        bytes[] memory siblings = smt.emptyProofSiblings();
        // Replace the leaf-adjacent sibling with the 56-byte raw leaf.
        siblings[63] = pairSibling;

        // Compute root WITH the variable-size sibling.
        bytes32 root = smt.recomputeRoot(0, leaf, siblings);

        // Manual computation: hash(leaf || pairSibling) = level 1 result.
        bytes32 expected = keccak256(abi.encodePacked(leaf, pairSibling));
        // Levels 1..63: bit_k=0 (idx=0), sibling = emptyAt_k.
        for (uint256 i = 1; i < 64; ++i) {
            expected = keccak256(abi.encodePacked(expected, smt.emptyHashAtLevel(i)));
        }
        assertEq(root, expected, "dense-pair root mismatch");

        // verifyProof returns true with the correct root.
        assertTrue(smt.verifyProof(0, leaf, siblings, root));
    }

    /// @notice A 56-byte leaf at index 0 with default-empty siblings.
    ///         Confirms variable-size leaves work even when siblings
    ///         are the standard 32-byte sentinels.
    function test_audit2_variable_size_leaf_with_default_siblings() public view {
        bytes memory leaf = new bytes(56);
        for (uint8 i = 0; i < 56; ++i) leaf[uint256(i)] = bytes1(i + 1);

        bytes[] memory siblings = smt.emptyProofSiblings();
        bytes32 root = smt.recomputeRoot(0, leaf, siblings);

        // Verify against itself.
        assertTrue(smt.verifyProof(0, leaf, siblings, root));
    }

    // ---- Fuzz: tampering invalidates the proof ----

    function testFuzz_tampered_proof_rejected(uint8 tamperLevel, uint256 idx)
        public
        view
    {
        tamperLevel = uint8(uint256(tamperLevel) % 64);
        bytes memory leaf = abi.encodePacked(keccak256("fuzz"));
        bytes[] memory siblings = _populatedSiblings();
        bytes32 root = smt.recomputeRoot(idx, leaf, siblings);

        // Tamper exactly one sibling (replace with a different 32-byte value).
        siblings[tamperLevel] = abi.encodePacked(
            keccak256(abi.encodePacked(siblings[tamperLevel], "tamper"))
        );

        bool ok = smt.verifyProof(idx, leaf, siblings, root);
        assertFalse(ok);
    }

    // ---- Helpers ----

    function _populatedSiblings() internal pure returns (bytes[] memory) {
        bytes[] memory siblings = new bytes[](64);
        for (uint256 i = 0; i < 64; ++i) {
            siblings[i] = abi.encodePacked(
                keccak256(abi.encodePacked("populated-sibling-", i))
            );
        }
        return siblings;
    }
}
