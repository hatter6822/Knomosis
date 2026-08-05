// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

/// @title LogChain
/// @notice The L1 spelling of the L2 log-entry hash chain.
///
/// @dev    Two pure functions, one definition each, shared by
///         `KnomosisStateRootSubmission` (which extends the chain on
///         every submission) and `KnomosisFaultProofGame` (which
///         authenticates a disputed action against it).  A second
///         spelling in either contract would be a place for the two to
///         drift, and the drift would be silent: the chain check would
///         still pass for the submitter and still fail for the game.
///
///         **What changed and why.**  The chain used to commit to
///         state roots alone —
///         `keccak256(abi.encode(prevLogEntryHash, stateCommit))` —
///         which made it a sequencing guard and nothing more.  Nothing
///         on L1 recorded WHICH action carried root `i-1` to root `i`,
///         so `terminateOnSingleStep` accepted any
///         `(actionKind, actionFields, signer)` triple the responding
///         party cared to submit.  A party losing a game could pick a
///         different action whose step happened to reproduce the
///         disputed root, and the game would settle in its favour on an
///         action the L2 never executed.
///
///         Folding `actionCommit` into the chain closes that: the
///         submitted triple must hash to the value the sequencer bound
///         when it published the root, and the sequencer cannot rebind
///         it afterwards without breaking every descendant's chain
///         check.  This also brings the L1 chain into line with the
///         Lean one it mirrors — `Runtime.LogFile.LogEntry.hash` has
///         always chained `encode signedAction ++ encode prevHash`,
///         i.e. it has always committed to the action.
library LogChain {
    /// @notice Commit to the L1 form of a signed action.
    ///
    /// @dev    The dynamic field goes LAST.  `abi.encodePacked`
    ///         concatenates without length prefixes, so a leading
    ///         variable-length field would make the encoding ambiguous
    ///         — `(kind=0x01, fields=0x02…)` and a different split of
    ///         the same bytes would collide.  With `actionFields` last,
    ///         the first 9 bytes are fixed-width and the remainder is
    ///         exactly the fields, so the encoding is injective on
    ///         `(actionKind, signer, actionFields)`.
    ///
    ///         Mirrored byte-for-byte in Lean by
    ///         `LegalKernel.FaultProof.StepVMCoherence.l1ActionCommit`
    ///         and pinned per-entry by the `step_vm.json` cross-stack
    ///         corpus (`expectedActionCommitHex`).
    ///
    /// @param actionKind    the `Action` variant index (0..24).
    /// @param signer        the action's signer `ActorId`.
    /// @param actionFields  the variant's `actionFieldsForL1` bytes.
    /// @return the 32-byte action commitment.
    function actionCommit(uint8 actionKind, uint64 signer, bytes calldata actionFields)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(actionKind, signer, actionFields));
    }

    /// @notice The same commitment over a memory-resident field slice.
    ///
    /// @dev    Solidity cannot coerce `bytes memory` to `bytes
    ///         calldata`, and the test harnesses build fields in
    ///         memory.  Kept as an explicit overload rather than
    ///         narrowing the calldata version, because the on-chain
    ///         path is calldata and should not pay a copy for the
    ///         tests' convenience.  Both bodies must stay identical.
    function actionCommitMemory(uint8 actionKind, uint64 signer, bytes memory actionFields)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(actionKind, signer, actionFields));
    }

    /// @notice Extend the chain by one entry.
    ///
    /// @dev    `abi.encode` over three `bytes32` values is their plain
    ///         96-byte concatenation — no padding, no offsets — so the
    ///         Lean mirror is a concatenation too.
    ///
    /// @param prevLogEntryHash  the predecessor entry's hash.
    /// @param stateCommit       the state root this entry publishes.
    /// @param actionCommit_     the action that produced it.
    /// @return the entry hash the NEXT submission must chain to.
    function nextEntryHash(
        bytes32 prevLogEntryHash,
        bytes32 stateCommit,
        bytes32 actionCommit_
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(prevLogEntryHash, stateCommit, actionCommit_));
    }
}
