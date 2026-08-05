// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {SmtCellVerifier} from "src/lib/SmtCellVerifier.sol";

/// @title SmtCellVerifierProxy
/// @notice External wrapper exposing `SmtCellVerifier`'s internal
///         library functions for tests.  All calldata-typed parameters
///         need an `external` boundary so Foundry can supply
///         `bytes memory` fixtures (which get re-wrapped as
///         `bytes calldata` at the proxy boundary).
///
/// @dev    Shared rather than per-suite.  Three test files had each
///         grown a proxy over the SAME library — this one,
///         `SmtCellProofCrossCheckProxy` in the SC.3 cross-check, and
///         the `SmtCellVerifier` half of `StepVMMerkleUpdateProxy` —
///         with byte-identical `recomputeRoot` / `verifyCellProof`
///         bodies.  A boundary wrapper is boilerplate whose only job is
///         to exist, so three copies is three places for the boundary to
///         drift from the library it fronts, and nothing that would
///         notice.  One home, named for the library it wraps; a suite
///         needing a DIFFERENT library gets its own proxy rather than a
///         second method here.
contract SmtCellVerifierProxy {
    function emptySubtreeHash(uint256 d) external pure returns (bytes32) {
        return SmtCellVerifier.emptySubtreeHash(d);
    }

    function precomputeEmptySubtreeHashes() external pure returns (bytes32[256] memory) {
        return SmtCellVerifier.precomputeEmptySubtreeHashes();
    }

    function readKeyBitMSBFirst(bytes calldata smtKey, uint256 d) external pure returns (uint256) {
        return SmtCellVerifier.readKeyBitMSBFirst(smtKey, d);
    }

    function readBitmaskBit(bytes calldata bitmask, uint256 d) external pure returns (uint256) {
        return SmtCellVerifier.readBitmaskBit(bitmask, d);
    }

    function bitmaskWord(bytes calldata bitmask) external pure returns (uint256) {
        return SmtCellVerifier.bitmaskWord(bitmask);
    }

    function recomputeRoot(
        bytes calldata smtKey,
        bytes calldata leafPreimage,
        bytes calldata proofData
    ) external pure returns (bytes32) {
        return SmtCellVerifier.recomputeRoot(smtKey, leafPreimage, proofData);
    }

    function verifyCellProof(
        bytes32 root,
        bytes calldata smtKey,
        bytes calldata leafPreimage,
        bytes calldata proofData
    ) external pure returns (bool) {
        return SmtCellVerifier.verifyCellProof(root, smtKey, leafPreimage, proofData);
    }

    /// @notice `SmtCellVerifier.recomputeRootFromLeaf` — the walk from
    ///         an already-hashed leaf, skipping the preimage step.
    function recomputeRootFromLeaf(bytes calldata smtKey, bytes32 leaf, bytes calldata proofData)
        external
        pure
        returns (bytes32)
    {
        return SmtCellVerifier.recomputeRootFromLeaf(smtKey, leaf, proofData);
    }

    /// @notice `SmtCellVerifier.emptyLeafHash` — the leaf a cell the
    ///         state does not hold occupies.
    function emptyLeafHash() external pure returns (bytes32) {
        return SmtCellVerifier.emptyLeafHash();
    }

}
