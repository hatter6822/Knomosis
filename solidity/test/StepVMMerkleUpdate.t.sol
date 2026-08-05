// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {SmtCellVerifier} from "src/lib/SmtCellVerifier.sol";
import {SmtCellVerifierProxy} from "test/utils/SmtCellVerifierProxy.sol";
import {StepVMMerkle} from "src/lib/StepVMMerkle.sol";

/// @title StepVMMerkleUpdateProxy
/// @notice External wrapper for the calldata-typed library functions.
contract StepVMMerkleUpdateProxy {
    // `SmtCellVerifier`'s entry points are NOT mirrored here — they live
    // in the shared `SmtCellVerifierProxy`, which this suite deploys
    // alongside.  A proxy fronts ONE library; fronting a second is what
    // let three files each grow their own `recomputeRoot`.

    function updateCellRoot(bytes32 smtKey, bytes32 newLeaf, bytes calldata proofData)
        external
        pure
        returns (bytes32)
    {
        return StepVMMerkle.updateCellRoot(smtKey, newLeaf, proofData);
    }

    function cellLeafHash(bool isAbsent, bytes calldata leafPreimage)
        external
        pure
        returns (bytes32)
    {
        return StepVMMerkle.cellLeafHash(isAbsent, leafPreimage);
    }

    function verifyCellSmtProof(
        bytes32 expectedRoot,
        bytes calldata smtKey,
        bytes calldata leafPreimage,
        bytes calldata proofData
    ) external pure returns (bool) {
        return StepVMMerkle.verifyCellSmtProof(expectedRoot, smtKey, leafPreimage, proofData);
    }
}

/// @title StepVMMerkleUpdateTest
/// @notice The two primitives the state-root flip needs from the L1:
///         re-walking an opening from a new leaf (`updateCellRoot`),
///         and deciding which leaf a cell occupies (`cellLeafHash`).
///
/// @dev    Both replace code that could not have worked.  The old
///         `updateCommitment` discarded its root and siblings and
///         returned `keccak256(newValue)` — a value in no root space
///         at all — and had zero callers, which is why nothing caught
///         it.  `recomputeRoot` hashed its preimage unconditionally,
///         which is right for a verifier handed an opaque preimage and
///         wrong for a step VM, whose first handler opens a cell the
///         state does not hold.
contract StepVMMerkleUpdateTest is Test {
    StepVMMerkleUpdateProxy internal p;
    /// @dev The `SmtCellVerifier` boundary, shared with the other suites.
    SmtCellVerifierProxy internal smt;

    /// A 32-byte key with a mixed bit pattern, so the walk exercises
    /// both the left- and right-child branches rather than one side.
    bytes internal constant KEY =
        hex"a3f100000000000000000000000000000000000000000000000000000000005c";

    /// The same key as the word the root-computing entry points take.
    /// `updateCellRoot` and the fold read a 32-byte DERIVED key, so
    /// they take `bytes32` rather than re-packing it into `bytes` only
    /// to unpack it again; `test_KEY32_is_KEY` pins the two forms
    /// together so this pair cannot drift.
    bytes32 internal constant KEY32 =
        0xa3f100000000000000000000000000000000000000000000000000000000005c;

    /// An all-zero bitmask with no siblings: every level's sibling is
    /// the canonical empty sub-tree, which is the shape a cell in an
    /// otherwise-empty tree actually has.
    bytes internal constant EMPTY_PROOF =
        hex"0000000000000000000000000000000000000000000000000000000000000000";

    function setUp() public {
        p = new StepVMMerkleUpdateProxy();
        smt = new SmtCellVerifierProxy();
    }

    /// @notice The preimage path is unchanged: it now routes through
    ///         `recomputeRootFromLeaf`, and the two must agree on the
    ///         same input or the refactor moved a pinned corpus.
    function test_recomputeRoot_is_the_leaf_path_with_a_hashed_preimage() public view {
        bytes memory preimage = hex"deadbeefcafe";
        assertEq(
            smt.recomputeRoot(KEY, preimage, EMPTY_PROOF),
            smt.recomputeRootFromLeaf(KEY, keccak256(preimage), EMPTY_PROOF),
            "the preimage wrapper must equal the leaf entry point"
        );
    }

    /// @notice `cellLeafHash` branches on absence, and the branch
    ///         matters: an absent cell walks from the canonical empty
    ///         leaf, a present one from its own leaf hash.
    function test_cellLeafHash_branches_on_absence() public view {
        bytes memory preimage = hex"0011223344556677";
        assertEq(
            p.cellLeafHash(true, preimage),
            smt.emptyLeafHash(),
            "an absent cell walks from the canonical empty leaf"
        );
        assertEq(
            p.cellLeafHash(false, preimage),
            keccak256(preimage),
            "a present cell walks from its own leaf hash"
        );
        assertTrue(
            p.cellLeafHash(true, preimage) != p.cellLeafHash(false, preimage),
            "the two branches must not coincide, or absence is unprovable"
        );
    }

    /// @notice **The update primitive moves the root.**  The old
    ///         placeholder returned `keccak256(newValue)` regardless of
    ///         root or siblings; this walks the supplied opening.
    /// @notice The two spellings of the probe key are the same bytes.
    ///
    /// @dev    A constant duplicated in two types is a constant that
    ///         can drift, so it is asserted rather than trusted.
    function test_KEY32_is_KEY() public pure {
        assertEq(KEY.length, 32, "the probe key is one word");
        assertEq(KEY, abi.encodePacked(KEY32), "the two spellings agree");
    }

    function test_updateCellRoot_re_walks_the_opening() public view {
        bytes32 oldLeaf = keccak256(hex"01");
        bytes32 newLeaf = keccak256(hex"02");

        bytes32 oldRoot = smt.recomputeRootFromLeaf(KEY, oldLeaf, EMPTY_PROOF);
        bytes32 newRoot = p.updateCellRoot(KEY32, newLeaf, EMPTY_PROOF);

        assertTrue(oldRoot != newRoot, "a different leaf must produce a different root");
        assertTrue(newRoot != newLeaf, "the root is a walk, not the leaf itself");
        assertTrue(
            newRoot != keccak256(abi.encodePacked(newLeaf)),
            "and not the old placeholder's keccak-of-the-value either"
        );
    }

    /// @notice Writing a cell back to its previous value restores the
    ///         root.  The update is a function of `(key, leaf, path)`
    ///         and nothing else — no accumulated state, no ordering
    ///         residue.
    function test_updateCellRoot_is_reversible() public view {
        bytes32 leafA = keccak256(hex"aa");
        bytes32 leafB = keccak256(hex"bb");

        bytes32 rootA = p.updateCellRoot(KEY32, leafA, EMPTY_PROOF);
        bytes32 rootB = p.updateCellRoot(KEY32, leafB, EMPTY_PROOF);
        bytes32 backToA = p.updateCellRoot(KEY32, leafA, EMPTY_PROOF);

        assertTrue(rootA != rootB, "distinct leaves, distinct roots");
        assertEq(rootA, backToA, "restoring the leaf restores the root");
    }

    /// @notice **The opening that verified against the pre-root is the
    ///         one that produces the post-root.**  This is the whole
    ///         mechanism of the fold: verify at the old leaf, re-walk
    ///         at the new one.
    function test_the_verifying_opening_produces_the_post_root() public view {
        bytes memory preimage = hex"c0ffee";
        bytes32 preRoot = smt.recomputeRoot(KEY, preimage, EMPTY_PROOF);

        assertTrue(
            p.verifyCellSmtProof(preRoot, KEY, preimage, EMPTY_PROOF),
            "the opening verifies against the root it was built for"
        );

        bytes32 newLeaf = p.cellLeafHash(false, hex"beef");
        bytes32 postRoot = p.updateCellRoot(KEY32, newLeaf, EMPTY_PROOF);

        assertTrue(postRoot != preRoot, "the write moved the published root");
        assertTrue(
            p.verifyCellSmtProof(postRoot, KEY, hex"beef", EMPTY_PROOF),
            "and the same opening now verifies the NEW value against it"
        );
        assertFalse(
            p.verifyCellSmtProof(preRoot, KEY, hex"beef", EMPTY_PROOF),
            "while the new value does NOT verify against the old root"
        );
    }

    /// @notice An absent cell's opening reaches a different root than
    ///         a present cell's carrying the canonical absent bytes —
    ///         which is exactly why the branch has to exist.
    function test_absent_and_present_reach_different_roots() public view {
        bytes memory absentBytes = hex"";
        bytes32 asAbsent = p.updateCellRoot(KEY32, p.cellLeafHash(true, absentBytes), EMPTY_PROOF);
        bytes32 asPresent = p.updateCellRoot(KEY32, p.cellLeafHash(false, absentBytes), EMPTY_PROOF);
        assertTrue(
            asAbsent != asPresent,
            "a verifier that always hashed the preimage would conflate these"
        );
    }
}
