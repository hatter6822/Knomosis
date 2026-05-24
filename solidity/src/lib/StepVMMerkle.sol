// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {SmtCellVerifier} from "./SmtCellVerifier.sol";
import {SmtVerifier} from "./SmtVerifier.sol";

/// @title StepVMMerkle
/// @notice Per-cell Merkle proof verification for the L1 step VM
///         (Workstream H WU H.5.3 + Workstream SC.2).
///
/// Mirrors the Lean-side `LegalKernel.FaultProof.Verify` and
/// `LegalKernel.FaultProof.Smt` modules for cell-level proof
/// verification.  Two equivalent proof shapes ship here:
///
///   1. **Witness-state cell proof** (`verifyCellProofWitness`):
///      the responder submits the entire witness sub-state plus a
///      single 32-byte commit; verification re-hashes the sub-state
///      on L1.  Mathematically sound but O(|sub-state|) gas.
///
///   2. **SMT cell proof** (`verifyCellSmtProof`): the responder
///      submits an O(log N) sparse-Merkle-tree opening; verification
///      walks 256 levels and reconstructs the root.  Both
///      mathematically sound and gas-affordable (≤ 50k gas per cell).
///      Lean soundness: `LegalKernel.FaultProof.smtCellProof_sound
///      _under_collision_free` and `smtCellProof_no_value_substitution`.
///
/// Cross-stack equivalence with Lean is established by the
/// WU H.10.1 fixture corpus (witness-state form) and the SC.3
/// cross-stack corpus (SMT form).
library StepVMMerkle {
    /* ---------------------------------------------------------- */
    /* Cell-level proof verification (witness-state form)         */
    /* ---------------------------------------------------------- */

    /// @notice Verify a single cell proof against the committed
    ///         state root, given the cell tag, value, and Merkle
    ///         path siblings.
    ///
    /// Witness-state form: the witness-commit field of `cellProof`
    /// must equal `commit`, and the cell value must match the
    /// per-cell-tag canonical encoding (which the L1 contract
    /// verifies against the action's expected reads).
    function verifyCellProofWitness(bytes32 commit, bytes32 witnessCommit)
        internal
        pure
        returns (bool)
    {
        return commit == witnessCommit;
    }

    /// @notice Verify a Merkle-path-based withdrawal proof.  Calls
    ///         the existing Workstream-D `SmtVerifier`
    ///         infrastructure with the per-cell leaf bytes.  This
    ///         is the **withdrawal-tree** path (depth 64); the
    ///         **state-cell** path (depth 256) is
    ///         `verifyCellSmtProof` below.
    function verifyCellMerkleProof(
        bytes32 expectedRoot,
        bytes memory leaf,
        uint64 pathIndex,
        bytes[] memory siblings
    ) internal pure returns (bool) {
        bytes32 computedRoot = SmtVerifier.recomputeRoot(uint256(pathIndex), leaf, siblings);
        return computedRoot == expectedRoot;
    }

    /* ---------------------------------------------------------- */
    /* Cell-level proof verification (SMT form)                   */
    /* ---------------------------------------------------------- */

    /// @notice Verify a sparse-Merkle-tree cell proof against the
    ///         committed sub-state root (Workstream SC.2).
    ///
    /// SMT form: the responder submits a compact 256-level path
    /// opening for the disputed cell.  The proof's bitmask
    /// distinguishes non-canonical-empty siblings (drawn from
    /// `proofData`) from canonical-empty siblings (`SmtCellVerifier`'s
    /// per-depth `H_d` table).
    ///
    /// Cost: ≈ 35-50k gas per cell when invoked directly from
    /// another Solidity contract (within the SC.2 50k budget).
    /// The verifier performs 511 keccak256 operations total
    /// (256 for the walk + up to 255 to advance the canonical
    /// empty-subtree chain) without any 8 KiB memory
    /// allocations.
    ///
    /// Cross-stack soundness: under collision-resistance of
    /// `keccak256`, two verifying proofs for the same `(root,
    /// smtKey)` must witness the same value (Lean theorem
    /// `smtCellProof_no_value_substitution`).
    ///
    /// @param expectedRoot   the agreed sub-state SMT root.
    /// @param smtKey         the SMT key (read MSB-first); typically
    ///                       a 32-byte hash of the logical cell
    ///                       identifier (tag + sub-keys).
    /// @param leafPreimage   bytes hashed to form the leaf node;
    ///                       Lean spec: `Encodable.encode key ++
    ///                       Encodable.encode value`.
    /// @param proofData      wire-encoded proof:
    ///                       `bitmask(32 bytes) || siblings(N * 32 bytes)`.
    /// @return ok            true iff the proof reconstructs to
    ///                       `expectedRoot`.
    function verifyCellSmtProof(
        bytes32 expectedRoot,
        bytes calldata smtKey,
        bytes calldata leafPreimage,
        bytes calldata proofData
    ) internal pure returns (bool ok) {
        ok = SmtCellVerifier.verifyCellProof(expectedRoot, smtKey, leafPreimage, proofData);
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
    /// functions in `KnomosisStepVM`.
    function updateCommitment(
        bytes32 _oldCommit, // unused in witness-state form
        bytes memory _leaf,
        uint64 _pathIndex,
        bytes[] memory _siblings,
        bytes memory newValue
    ) internal pure returns (bytes32) {
        // First-pass placeholder: just hash the new value.
        // SMT-form updates compose the per-cell proof's siblings via
        // `SmtCellVerifier.recomputeRoot` after substituting the new
        // leaf bytes; that integration lives in the per-variant
        // `_step<Variant>` functions, not this generic helper.
        _oldCommit;
        _leaf;
        _pathIndex;
        _siblings;
        return keccak256(newValue);
    }
}
