// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Canon  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {SmtVerifier} from "./SmtVerifier.sol";

/// @title StepVMMerkle
/// @notice Per-cell Merkle proof verification for the L1 step VM
///         (Workstream H WU H.5.3).
///
/// Mirrors the Lean-side `LegalKernel.FaultProof.Verify` module
/// for cell-level proof verification.  The first-pass design uses
/// the witness-state-bearing form (no Merkle paths needed for
/// soundness); this library is the bridge to the SMT-optimised
/// form for production gas-efficient verification.
///
/// Cross-stack equivalence with Lean is established by the WU
/// H.10.1 fixture corpus.
library StepVMMerkle {
    /* ---------------------------------------------------------- */
    /* Cell-level proof verification                              */
    /* ---------------------------------------------------------- */

    /// @notice Verify a single cell proof against the committed
    ///         state root, given the cell tag, value, and Merkle
    ///         path siblings.
    ///
    /// First-pass implementation: the witness-commit field of
    /// `cellProof` must equal `commit`, and the cell value must
    /// match the per-cell-tag canonical encoding (which the L1
    /// contract verifies against the action's expected reads).
    ///
    /// Production SMT-optimised version (deferred): walks the
    /// Merkle path siblings via `SmtVerifier.recomputeRoot` and
    /// compares against the relevant sub-state root within the
    /// top-level commit.
    function verifyCellProofWitness(
        bytes32 commit,
        bytes32 witnessCommit
    ) internal pure returns (bool) {
        return commit == witnessCommit;
    }

    /// @notice Verify a Merkle-path-based cell proof.  Calls
    ///         the existing Workstream-D `SmtVerifier`
    ///         infrastructure with the per-cell leaf bytes.
    function verifyCellMerkleProof(
        bytes32 expectedRoot,
        bytes memory leaf,
        uint64  pathIndex,
        bytes[] memory siblings
    ) internal pure returns (bool) {
        bytes32 computedRoot = SmtVerifier.recomputeRoot(
            uint256(pathIndex), leaf, siblings);
        return computedRoot == expectedRoot;
    }

    /* ---------------------------------------------------------- */
    /* Cell-update commitment recomputation                       */
    /* ---------------------------------------------------------- */

    /// @notice Compute the new sub-state root after writing one
    ///         cell.  Mirrors Lean's `updateCommitment`.
    ///
    /// First-pass: under the witness-state-bearing form, the
    /// new commitment is computed by re-hashing the witness
    /// state with the cell write applied.  The L1 contract
    /// drives this via the per-variant `_step<Variant>`
    /// functions in `CanonStepVM`.
    function updateCommitment(
        bytes32 _oldCommit,  // unused in witness-state form
        bytes memory _leaf,
        uint64  _pathIndex,
        bytes[] memory _siblings,
        bytes memory newValue
    ) internal pure returns (bytes32) {
        // Defer to SmtVerifier for SMT-based recomputation.
        // First-pass placeholder: just hash the new value.
        _oldCommit; _leaf; _pathIndex; _siblings;
        return keccak256(newValue);
    }
}
