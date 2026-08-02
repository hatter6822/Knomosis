// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {SmtCellVerifier} from "./SmtCellVerifier.sol";

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

    /* ---------------------------------------------------------- */
    /* Canonical cell-key derivation                              */
    /* ---------------------------------------------------------- */

    /// @notice Derive the canonical SMT key for a cell from its
    ///         logical identity.  Mirrors Lean's
    ///         `LegalKernel.FaultProof.smtCellKey`.
    ///
    /// @dev    **Callers must DERIVE the key, never accept one.**
    ///         An SMT cell proof opens one leaf, and which leaf is
    ///         determined by the key.  If a caller supplies the key,
    ///         a proof opening cell X can be presented as a proof
    ///         about cell Y — the responder opens whichever balance
    ///         cell it likes and offers the value as, say, the AMM
    ///         kill switch.  `verifyCellSmtProof` below takes the key
    ///         as calldata precisely so that the ONE place deriving
    ///         it is this function.
    ///
    ///         The pre-image is `abi.encodePacked(uint8, uint256,
    ///         uint256)` — 65 bytes, fixed-width, no length prefixes
    ///         — which is byte-identical to Lean's
    ///         `cellKeyPreimageOf`:
    ///
    ///             [kind : 1 byte] ++ [keyA : 32 BE] ++ [keyB : 32 BE]
    ///
    ///         Hashing rather than packing into 32 bytes directly is
    ///         forced by the key types: Lean's `DepositId` /
    ///         `WithdrawalId` are unbounded naturals, so a packed
    ///         `1 + 8 + 8` key would alias ids agreeing mod 2^64.
    ///
    /// @param cellKind the cell-kind discriminator (0..14).
    /// @param keyA     the first key component (resource / actor /
    ///                 deposit id / withdrawal id; 0 for singletons).
    /// @param keyB     the second key component (actor for balance
    ///                 cells; 0 otherwise).
    /// @return the 32-byte SMT key.
    function deriveCellSmtKey(uint8 cellKind, uint256 keyA, uint256 keyB)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(cellKind, keyA, keyB));
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
        bytes memory smtKey,
        bytes memory leafPreimage,
        bytes calldata proofData
    ) internal pure returns (bool ok) {
        ok = SmtCellVerifier.verifyCellProof(expectedRoot, smtKey, leafPreimage, proofData);
    }

    /* ---------------------------------------------------------- */
    /* Cell-update root recomputation                             */
    /* ---------------------------------------------------------- */

    /// @notice The new state root after writing one cell: the SAME
    ///         opening, re-walked from the new leaf.  Mirrors Lean's
    ///         `updateStateCellRoot`.
    ///
    /// @dev    Replaces a placeholder that discarded its root and
    ///         siblings and returned `keccak256(newValue)` — a value
    ///         in no root space at all.  It had zero callers, which is
    ///         why nothing caught it; the flip is what gives it one.
    ///
    ///         Correct because the canonical path never reads the
    ///         key's own entry, so two states agreeing away from this
    ///         cell share it and the whole difference is the leaf.
    ///         Lean's `updateStateCellRoot_eq_commit_of_canonical`
    ///         proves the result is `commitExtendedState` of the
    ///         post-state — not merely some well-formed hash.
    ///
    ///         Openings go stale as soon as a write lands, so a
    ///         multi-write step folds strictly in order with proof `i`
    ///         opening against the root write `i-1` produced.
    ///
    /// @param smtKey    the SMT key, DERIVED via `deriveCellSmtKey`.
    /// @param newLeaf   the post-write leaf, from `cellLeafHash`.
    /// @param proofData the opening that verified against the pre-root.
    /// @return the post-write root.
    function updateCellRoot(bytes memory smtKey, bytes32 newLeaf, bytes calldata proofData)
        internal
        pure
        returns (bytes32)
    {
        return SmtCellVerifier.recomputeRootFromLeaf(smtKey, newLeaf, proofData);
    }

    /// @notice The leaf a cell occupies: its leaf hash when present,
    ///         the canonical empty leaf when canonically absent.
    ///         Mirrors Lean's `cellLeaf`.
    ///
    /// @dev    The branch is not an optimisation.  `stateCellEntries`
    ///         drops canonically-absent cells, so a cell with no entry
    ///         has an EMPTY sub-tree beneath its key rather than a
    ///         leaf holding the absent value — and an opening built
    ///         the present way reconstructs a root the tree does not
    ///         have.  Crediting a receiver who holds no balance yet
    ///         hits this on the first line of the first handler, so it
    ///         is the common case, not an edge case.
    ///
    ///         `isAbsent` is supplied by the caller rather than
    ///         recomputed here: deciding it means comparing the value
    ///         against the kind's canonical absent encoding, which is
    ///         the step VM's business and is pinned cross-stack
    ///         against Lean's `canonicalAbsentValue`.
    ///
    /// @param isAbsent      whether the value equals the kind's
    ///                      canonical absent encoding.
    /// @param leafPreimage  `cbe(smtKey) || cbe(value)`, ignored when
    ///                      `isAbsent`.
    /// @return the leaf to walk from.
    function cellLeafHash(bool isAbsent, bytes memory leafPreimage)
        internal
        pure
        returns (bytes32)
    {
        if (isAbsent) {
            return SmtCellVerifier.emptyLeafHash();
        }
        return keccak256(leafPreimage);
    }

    /* ---------------------------------------------------------- */
    /* The write fold                                             */
    /* ---------------------------------------------------------- */

    /// @notice One write applied to a running root: verify the
    ///         opening against it with the OLD leaf, then re-walk the
    ///         same opening from the NEW leaf.
    ///
    /// @dev    Mirrors Lean's `applyStateCellWrite`.  The two halves
    ///         use the SAME `proofData`, which is what makes the
    ///         update sound: the sibling path is a property of the
    ///         key's route through the tree, and the write changes
    ///         only the leaf at its end.
    ///
    ///         `ok = false` means the opening did not verify.  The
    ///         caller must treat that as fatal rather than skipping
    ///         the write — a fold that silently dropped an unverified
    ///         write would reach a root for a state where that cell
    ///         never moved, which is precisely the forgery the fold
    ///         exists to prevent.
    ///
    /// @param  root       the running root, before this write.
    /// @param  smtKey     the cell's derived SMT key.
    /// @param  oldIsAbsent whether the PRE-value is canonically absent.
    /// @param  oldPreimage the pre-value's leaf preimage.
    /// @param  newIsAbsent whether the POST-value is canonically absent.
    /// @param  newPreimage the post-value's leaf preimage.
    /// @param  proofData  the opening, against `root`.
    function applyCellWrite(
        bytes32 root,
        bytes memory smtKey,
        bool oldIsAbsent,
        bytes memory oldPreimage,
        bool newIsAbsent,
        bytes memory newPreimage,
        bytes calldata proofData
    ) internal pure returns (bool ok, bytes32 newRoot) {
        bytes32 oldLeaf = cellLeafHash(oldIsAbsent, oldPreimage);
        if (SmtCellVerifier.recomputeRootFromLeaf(smtKey, oldLeaf, proofData) != root) {
            return (false, root);
        }
        bytes32 newLeaf = cellLeafHash(newIsAbsent, newPreimage);
        return (true, SmtCellVerifier.recomputeRootFromLeaf(smtKey, newLeaf, proofData));
    }
}
