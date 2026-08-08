// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

/// @title LogChain
/// @notice The L1 spelling of the batched submission hash chain.
///
/// @dev    Pure functions, one definition each, shared by
///         `KnomosisStateRootSubmission` (which extends the chain on
///         every batch submission) and `ActionsRoot` (whose
///         signature-bound batch leaf extends `actionCommit`'s
///         pre-image, and whose `genesisChainSeed` is the chain step
///         at the all-zero predecessor).  A second spelling elsewhere
///         would be a place for the constructions to drift, and the
///         drift would be silent.
///
///         **The chain commits to the batch's actions** (Workstream SB
///         ruling R8).  One `nextEntryHash` fold per BATCH: the third
///         word — which the retired per-action registry spent on a
///         single action's commitment — carries the batch's
///         `actionsRoot`, the SMT root over its per-action
///         signature-bound leaf commitments.  Nothing on L1 used to
///         record WHICH action carried root `i-1` to root `i`, so a
///         party losing a game could pick a different action whose
///         step happened to reproduce the disputed root and settle in
///         its favour on an action the L2 never executed; under the
///         fold, the sequencer cannot rebind a batch's actions after
///         publishing it without breaking every descendant's chain
///         link, and `KnomosisFaultProofGame.terminateOnSingleStep`
///         authenticates the ONE disputed action by INCLUSION PROOF
///         against the committed root.  This keeps the L1 chain in
///         line with the Lean log it mirrors —
///         `Runtime.LogFile.LogEntry.hash` has always committed to
///         the actions it covers — while paying one fold per batch
///         instead of one per action.
library LogChain {
    /// @notice Commit to the L1 form of an action's unsigned triple.
    ///         The batch leaf the fault-proof game authenticates
    ///         (`ActionsRoot.actionLeafCommit`) extends exactly this
    ///         pre-image by the fixed 65-byte signature suffix.
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
    /// @param actionKind    the `Action` variant index (0..25).
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

    /// @notice Extend the chain by one BATCH record (SB ruling R8).
    ///
    /// @dev    `abi.encode` over three `bytes32` values is their plain
    ///         96-byte concatenation — no padding, no offsets — so the
    ///         Lean mirror (`l1NextEntryHash`, pinned by the
    ///         `batch_chain.json` corpus) is a concatenation too.
    ///
    /// @param prevLogEntryHash  the parent record's stored chain value.
    /// @param stateCommit       the state root this batch publishes.
    /// @param actionsRoot_      the batch's actions root
    ///                          (`bytes32(0)` at the genesis anchor).
    /// @return the chain value the NEXT submission must extend.
    function nextEntryHash(
        bytes32 prevLogEntryHash,
        bytes32 stateCommit,
        bytes32 actionsRoot_
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(prevLogEntryHash, stateCommit, actionsRoot_));
    }
}
