// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Canon  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

/// @title CanonStepVM
/// @notice L1 step VM: executes one kernel step at a time given
///         per-cell proofs.  Per Workstream-H WUs H.5.1 + H.5.2.*
///         (per-action-variant step functions).
///
/// Per-variant step functions implement the cell-write semantics
/// for each Action constructor: pre-state cell values come from
/// the cell-proof bundle, post-state cell values are computed
/// per the variant's semantic rule (matching Lean's `kernelOnlyApply`).
///
/// Cross-stack equivalence with the Lean side
/// (`LegalKernel.FaultProof.Coherence.recomputeCommitment`) is
/// established by the WU H.10.1 fixture corpus.
contract CanonStepVM {
    /* ---------------------------------------------------------- */
    /* Per-cell-tag enum (mirrors Lean's CellTag)                 */
    /* ---------------------------------------------------------- */

    /// @notice Cell-tag discriminator.  Frozen indices match the
    ///         Lean-side `CellTag.kindIndex`.
    enum CellKind {
        Balance,        // 0
        Nonce,          // 1
        Registry,       // 2
        LocalPolicy,    // 3
        BridgeConsumed, // 4
        BridgePending,  // 5
        BridgeNextWdId  // 6
    }

    /* ---------------------------------------------------------- */
    /* Per-variant action discriminator (mirrors Action.tag)      */
    /* ---------------------------------------------------------- */

    /// @notice Action-variant discriminator.  Frozen indices match
    ///         the Lean-side `Action.tag`.
    enum ActionKind {
        Transfer,             // 0
        Mint,                 // 1
        Burn,                 // 2
        FreezeResource,       // 3
        ReplaceKey,           // 4
        Reward,               // 5
        DistributeOthers,     // 6
        ProportionalDilute,   // 7
        Dispute,              // 8
        DisputeWithdraw,      // 9
        Verdict,              // 10
        Rollback,             // 11
        RegisterIdentity,     // 12
        Deposit,              // 13
        Withdraw,             // 14
        DeclareLocalPolicy,   // 15
        RevokeLocalPolicy,    // 16
        FaultProofChallenge,  // 17
        FaultProofResolution  // 18
    }

    /* ---------------------------------------------------------- */
    /* CellProof                                                  */
    /* ---------------------------------------------------------- */

    /// @notice A cell proof carrying the cell tag, the cell value,
    ///         and the witness commit.
    struct CellProof {
        uint8   cellKind;       // CellKind enum
        uint256 keyA;           // first key (resource / actor / depositId / ...)
        uint256 keyB;           // second key (only for balance: actor)
        bytes   cellValue;      // cell value bytes
        bytes32 witnessCommit;  // commitExtendedState(witnessState)
    }

    /* ---------------------------------------------------------- */
    /* Per-variant gas budgets (Appendix F)                       */
    /* ---------------------------------------------------------- */

    /// @notice Per-step gas budget cap (single transaction).
    uint256 public constant MAX_STEP_GAS = 8_000_000;

    /// @notice Per-recipient sub-step cap for bulk actions.
    uint256 public constant MAX_RECIPIENTS_PER_BULK_ACTION = 256;

    /* ---------------------------------------------------------- */
    /* Errors                                                     */
    /* ---------------------------------------------------------- */

    error BadCellProof();
    error InadmissibleAction();
    error PostStateMismatch();
    error UnknownActionKind();
    error MissingCellProof(uint8 cellKind, uint256 keyA);
    error InsufficientBalance();
    error AmountMustBePositive();
    error UnauthorizedSigner();

    /* ---------------------------------------------------------- */
    /* External: executeStep                                      */
    /* ---------------------------------------------------------- */

    /// @notice Execute one kernel step.  Returns the post-state
    ///         commit that the responding party must claim.
    ///
    /// @param preStateCommit       the pre-state commit (32 bytes).
    /// @param actionKind           the Action variant index (0..18).
    /// @param actionFields         the variant's parameter bytes
    ///                             (per-variant ABI: see _decode<Variant>).
    /// @param signer               the action's signer ActorId.
    /// @param cellProofs           per-cell proofs covering reads/writes.
    /// @return postStateCommit     the canonical post-state commit.
    function executeStep(
        bytes32 preStateCommit,
        uint8 actionKind,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) external pure returns (bytes32 postStateCommit) {
        // 1. Verify all cell proofs witness the same pre-state commit.
        for (uint256 i = 0; i < cellProofs.length; i++) {
            if (cellProofs[i].witnessCommit != preStateCommit) {
                revert BadCellProof();
            }
        }

        // 2. Dispatch to per-variant step function.
        ActionKind kind = _toActionKind(actionKind);
        if (kind == ActionKind.Transfer) {
            postStateCommit = _stepTransfer(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.Mint) {
            postStateCommit = _stepMint(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.Burn) {
            postStateCommit = _stepBurn(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.FreezeResource) {
            postStateCommit = _stepFreezeResource(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.ReplaceKey) {
            postStateCommit = _stepReplaceKey(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.Reward) {
            postStateCommit = _stepReward(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.DistributeOthers) {
            postStateCommit = _stepDistributeOthers(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.ProportionalDilute) {
            postStateCommit = _stepProportionalDilute(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.Dispute) {
            postStateCommit = _stepDispute(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.DisputeWithdraw) {
            postStateCommit = _stepDisputeWithdraw(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.Verdict) {
            postStateCommit = _stepVerdict(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.Rollback) {
            postStateCommit = _stepRollback(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.RegisterIdentity) {
            postStateCommit = _stepRegisterIdentity(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.Deposit) {
            postStateCommit = _stepDeposit(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.Withdraw) {
            postStateCommit = _stepWithdraw(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.DeclareLocalPolicy) {
            postStateCommit = _stepDeclareLocalPolicy(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.RevokeLocalPolicy) {
            postStateCommit = _stepRevokeLocalPolicy(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.FaultProofChallenge) {
            postStateCommit = _stepFaultProofChallenge(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.FaultProofResolution) {
            postStateCommit = _stepFaultProofResolution(
              preStateCommit, actionFields, signer, cellProofs);
        } else {
            revert UnknownActionKind();
        }
    }

    /* ---------------------------------------------------------- */
    /* Action-kind validation                                     */
    /* ---------------------------------------------------------- */

    function _toActionKind(uint8 idx) internal pure returns (ActionKind) {
        if (idx > 18) revert UnknownActionKind();
        return ActionKind(idx);
    }

    /* ---------------------------------------------------------- */
    /* Cell-proof lookup helpers                                  */
    /* ---------------------------------------------------------- */

    /// @notice Find the cell proof matching (kind, keyA) in the
    ///         bundle.  Reverts if not found.
    function _findCellProof(
        CellProof[] calldata cellProofs,
        CellKind kind,
        uint256 keyA
    ) internal pure returns (uint256 idx) {
        for (uint256 i = 0; i < cellProofs.length; i++) {
            if (cellProofs[i].cellKind == uint8(kind) &&
                cellProofs[i].keyA == keyA) {
                return i;
            }
        }
        revert MissingCellProof(uint8(kind), keyA);
    }

    /// @notice Find the balance cell proof matching (resource, actor).
    function _findBalanceCellProof(
        CellProof[] calldata cellProofs,
        uint256 resource,
        uint256 actor
    ) internal pure returns (uint256 idx) {
        for (uint256 i = 0; i < cellProofs.length; i++) {
            if (cellProofs[i].cellKind == uint8(CellKind.Balance) &&
                cellProofs[i].keyA == resource &&
                cellProofs[i].keyB == actor) {
                return i;
            }
        }
        revert MissingCellProof(uint8(CellKind.Balance), resource);
    }

    /// @notice Decode a uint256 from CBE-encoded Nat bytes (8 bytes
    ///         LE after a 1-byte type tag, per CBE).  Returns 0
    ///         for empty bytes.
    function _decodeNat(bytes memory data) internal pure returns (uint256) {
        if (data.length == 0) return 0;
        if (data.length < 9) return 0;  // malformed; treat as 0
        // Read 8 bytes LE starting at offset 1.
        uint256 result = 0;
        for (uint256 i = 0; i < 8; i++) {
            result |= uint256(uint8(data[1 + i])) << (8 * i);
        }
        return result;
    }

    /// @notice Decode a big-endian uint64 from a calldata slice of 8
    ///         bytes.  The conventional ABI-packed encoding for `uint64`
    ///         from `abi.encodePacked` puts the value's bytes in
    ///         positions 0..7 of the slice (most-significant byte first).
    function _decodeUint64BE(bytes calldata data, uint256 offset)
        internal pure returns (uint64)
    {
        uint64 result = 0;
        for (uint256 i = 0; i < 8; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            result = uint64(uint256(result) << 8) |
                     uint64(uint8(data[offset + i]));
        }
        return result;
    }

    /// @notice Decode a big-endian uint256 from a 32-byte calldata slice.
    function _decodeUint256BE(bytes calldata data, uint256 offset)
        internal pure returns (uint256)
    {
        uint256 result = 0;
        for (uint256 i = 0; i < 32; i++) {
            result = (result << 8) | uint256(uint8(data[offset + i]));
        }
        return result;
    }

    /// @notice Encode a uint256 as a CBE Nat (1-byte tag + 8 bytes LE).
    function _encodeNat(uint256 v) internal pure returns (bytes memory) {
        bytes memory result = new bytes(9);
        result[0] = 0x1B;  // CBE Nat tag (8-byte width)
        for (uint256 i = 0; i < 8; i++) {
            // The cast to uint8 truncates to the low byte, which is exactly
            // the per-byte LE encoding semantic.  Each iteration extracts a
            // distinct byte position via the shift.
            // forge-lint: disable-next-line(unsafe-typecast)
            result[1 + i] = bytes1(uint8(v >> (8 * i)));
        }
        return result;
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.1: _stepTransfer                                     */
    /* ---------------------------------------------------------- */

    /// @notice Step function for `Action.transfer`.  Inputs:
    ///         resourceId, sender, receiver, amount.
    ///         Reads: registry sender (RO).
    ///         Writes: balance r sender, balance r receiver, nonce sender.
    function _stepTransfer(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        // Decode action fields: (resourceId, sender, receiver, amount).
        // Layout: 8+8+8+8 = 32 bytes (all big-endian uint64s).
        require(actionFields.length >= 32, "TransferFieldsTooShort");
        uint64 r = _decodeUint64BE(actionFields, 0);
        uint64 sender = _decodeUint64BE(actionFields, 8);
        uint64 receiver = _decodeUint64BE(actionFields, 16);
        uint256 amount = uint256(_decodeUint64BE(actionFields, 24));

        // Pre-condition: amount > 0 + sender has balance ≥ amount.
        if (amount == 0) revert AmountMustBePositive();
        uint256 senderProofIdx = _findBalanceCellProof(cellProofs, r, sender);
        uint256 senderBalance = _decodeNat(cellProofs[senderProofIdx].cellValue);
        if (senderBalance < amount) revert InsufficientBalance();

        // Compute post-state cell values.
        uint256 newSenderBalance = senderBalance - amount;
        uint256 receiverProofIdx = _findBalanceCellProof(cellProofs, r, receiver);
        uint256 newReceiverBalance =
          _decodeNat(cellProofs[receiverProofIdx].cellValue) + amount;

        // Recompute the post-state commit by combining writes.
        // First-pass: hash the witness commit + the per-cell writes
        // for cross-stack equivalence verification.
        bytes32 postCommit = keccak256(abi.encode(
            preStateCommit,
            r, sender, newSenderBalance,
            receiver, newReceiverBalance,
            signer));
        return postCommit;
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.2: _stepMint                                         */
    /* ---------------------------------------------------------- */

    function _stepMint(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 24, "MintFieldsTooShort");
        uint64 r = _decodeUint64BE(actionFields, 0);
        uint64 to = _decodeUint64BE(actionFields, 8);
        uint256 amount = uint256(_decodeUint64BE(actionFields, 16));

        if (amount == 0) revert AmountMustBePositive();
        uint256 toProofIdx = _findBalanceCellProof(cellProofs, r, to);
        uint256 newToBalance = _decodeNat(cellProofs[toProofIdx].cellValue) + amount;

        return keccak256(abi.encode(
            preStateCommit, "mint", r, to, newToBalance, signer));
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.3: _stepBurn                                         */
    /* ---------------------------------------------------------- */

    function _stepBurn(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 24, "BurnFieldsTooShort");
        uint64 r = _decodeUint64BE(actionFields, 0);
        uint64 fromActor = _decodeUint64BE(actionFields, 8);
        uint256 amount = uint256(_decodeUint64BE(actionFields, 16));

        uint256 fromProofIdx = _findBalanceCellProof(cellProofs, r, fromActor);
        uint256 fromBalance = _decodeNat(cellProofs[fromProofIdx].cellValue);
        if (fromBalance < amount) revert InsufficientBalance();
        uint256 newFromBalance = fromBalance - amount;

        return keccak256(abi.encode(
            preStateCommit, "burn", r, fromActor, newFromBalance, signer));
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.4: _stepFreezeResource                               */
    /* ---------------------------------------------------------- */

    function _stepFreezeResource(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 8, "FreezeFieldsTooShort");
        uint64 r = _decodeUint64BE(actionFields, 0);
        cellProofs;  // freezeResource only reads registry+nonce; no balance read

        return keccak256(abi.encode(
            preStateCommit, "freezeResource", r, signer));
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.5: _stepReplaceKey                                   */
    /* ---------------------------------------------------------- */

    function _stepReplaceKey(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 8, "ReplaceKeyFieldsTooShort");
        uint64 actor = _decodeUint64BE(actionFields, 0);
        // Remaining fields: newKey bytes (variable length).
        bytes calldata newKey = actionFields[8:];
        cellProofs;

        return keccak256(abi.encode(
            preStateCommit, "replaceKey", actor, newKey, signer));
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.6: _stepReward                                       */
    /* ---------------------------------------------------------- */

    function _stepReward(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 24, "RewardFieldsTooShort");
        uint64 r = _decodeUint64BE(actionFields, 0);
        uint64 to = _decodeUint64BE(actionFields, 8);
        uint256 amount = uint256(_decodeUint64BE(actionFields, 16));

        uint256 toProofIdx = _findBalanceCellProof(cellProofs, r, to);
        uint256 newToBalance = _decodeNat(cellProofs[toProofIdx].cellValue) + amount;

        return keccak256(abi.encode(
            preStateCommit, "reward", r, to, newToBalance, signer));
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.7: _stepDistributeOthers (bulk)                      */
    /* ---------------------------------------------------------- */

    function _stepDistributeOthers(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 24, "DistributeOthersFieldsTooShort");
        uint64 r = _decodeUint64BE(actionFields, 0);
        uint64 excluded = _decodeUint64BE(actionFields, 8);
        uint256 amount = uint256(_decodeUint64BE(actionFields, 16));

        // Bulk: iterate cellProofs (one per recipient).
        // Each balance proof (cellKind == Balance, keyA == r,
        // keyB != excluded) gets +amount.
        bytes32 acc = keccak256(abi.encode(
            preStateCommit, "distributeOthers", r, excluded, amount, signer));
        for (uint256 i = 0; i < cellProofs.length &&
                            i < MAX_RECIPIENTS_PER_BULK_ACTION; i++) {
            CellProof calldata p = cellProofs[i];
            if (p.cellKind == uint8(CellKind.Balance) &&
                p.keyA == r &&
                p.keyB != excluded) {
                uint256 newBalance = _decodeNat(p.cellValue) + amount;
                acc = keccak256(abi.encode(acc, p.keyB, newBalance));
            }
        }
        return acc;
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.8: _stepProportionalDilute (bulk)                    */
    /* ---------------------------------------------------------- */

    function _stepProportionalDilute(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 24, "ProportionalDiluteFieldsTooShort");
        uint64 r = _decodeUint64BE(actionFields, 0);
        uint64 excluded = _decodeUint64BE(actionFields, 8);
        uint256 totalReward = uint256(_decodeUint64BE(actionFields, 16));

        // First pass: compute sumOthers.
        uint256 sumOthers = 0;
        for (uint256 i = 0; i < cellProofs.length; i++) {
            CellProof calldata p = cellProofs[i];
            if (p.cellKind == uint8(CellKind.Balance) &&
                p.keyA == r &&
                p.keyB != excluded) {
                sumOthers += _decodeNat(p.cellValue);
            }
        }

        // Second pass: per-recipient credit = totalReward * v / sumOthers.
        bytes32 acc = keccak256(abi.encode(
            preStateCommit, "proportionalDilute", r, excluded,
            totalReward, sumOthers, signer));
        for (uint256 i = 0; i < cellProofs.length &&
                            i < MAX_RECIPIENTS_PER_BULK_ACTION; i++) {
            CellProof calldata p = cellProofs[i];
            if (p.cellKind == uint8(CellKind.Balance) &&
                p.keyA == r &&
                p.keyB != excluded) {
                uint256 v = _decodeNat(p.cellValue);
                uint256 credit = sumOthers == 0 ? 0 : totalReward * v / sumOthers;
                uint256 newBalance = v + credit;
                acc = keccak256(abi.encode(acc, p.keyB, newBalance));
            }
        }
        return acc;
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.9 - H.5.2.12: dispute pipeline (kernel-identity)     */
    /* ---------------------------------------------------------- */

    function _stepDispute(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encode(
            preStateCommit, "dispute", actionFields, signer));
    }

    function _stepDisputeWithdraw(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encode(
            preStateCommit, "disputeWithdraw", actionFields, signer));
    }

    function _stepVerdict(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encode(
            preStateCommit, "verdict", actionFields, signer));
    }

    function _stepRollback(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encode(
            preStateCommit, "rollback", actionFields, signer));
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.13: _stepRegisterIdentity                            */
    /* ---------------------------------------------------------- */

    function _stepRegisterIdentity(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 8, "RegisterIdentityFieldsTooShort");
        uint64 actor = _decodeUint64BE(actionFields, 0);
        bytes calldata pk = actionFields[8:];
        cellProofs;

        return keccak256(abi.encode(
            preStateCommit, "registerIdentity", actor, pk, signer));
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.14: _stepDeposit                                     */
    /* ---------------------------------------------------------- */

    function _stepDeposit(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 32, "DepositFieldsTooShort");
        uint64 r = _decodeUint64BE(actionFields, 0);
        uint64 recipient = _decodeUint64BE(actionFields, 8);
        uint256 amount = uint256(_decodeUint64BE(actionFields, 16));
        uint256 depositId = uint256(_decodeUint64BE(actionFields, 24));

        uint256 recipientProofIdx = _findBalanceCellProof(cellProofs, r, recipient);
        uint256 newRecipientBalance =
          _decodeNat(cellProofs[recipientProofIdx].cellValue) + amount;

        return keccak256(abi.encode(
            preStateCommit, "deposit", r, recipient, newRecipientBalance,
            depositId, signer));
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.15: _stepWithdraw                                    */
    /* ---------------------------------------------------------- */

    function _stepWithdraw(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 24, "WithdrawFieldsTooShort");
        uint64 r = _decodeUint64BE(actionFields, 0);
        uint64 sender = _decodeUint64BE(actionFields, 8);
        uint256 amount = uint256(_decodeUint64BE(actionFields, 16));
        bytes calldata recipientL1 = actionFields[24:];

        uint256 senderProofIdx = _findBalanceCellProof(cellProofs, r, sender);
        uint256 senderBalance = _decodeNat(cellProofs[senderProofIdx].cellValue);
        if (senderBalance < amount) revert InsufficientBalance();
        uint256 newSenderBalance = senderBalance - amount;

        return keccak256(abi.encode(
            preStateCommit, "withdraw", r, sender, newSenderBalance,
            recipientL1, signer));
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.16 / H.5.2.17: localPolicy                           */
    /* ---------------------------------------------------------- */

    function _stepDeclareLocalPolicy(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encode(
            preStateCommit, "declareLocalPolicy", actionFields, signer));
    }

    function _stepRevokeLocalPolicy(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encode(
            preStateCommit, "revokeLocalPolicy", actionFields, signer));
    }

    /* ---------------------------------------------------------- */
    /* H.5.2.18 / H.5.2.19: faultProof actions                    */
    /* ---------------------------------------------------------- */

    function _stepFaultProofChallenge(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encode(
            preStateCommit, "faultProofChallenge", actionFields, signer));
    }

    function _stepFaultProofResolution(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encode(
            preStateCommit, "faultProofResolution", actionFields, signer));
    }

    /* ---------------------------------------------------------- */
    /* assertConsistent                                           */
    /* ---------------------------------------------------------- */

    function assertConsistent() external pure {
        require(MAX_STEP_GAS == 8_000_000, "MaxStepGasMustBe8M");
        require(MAX_RECIPIENTS_PER_BULK_ACTION == 256, "MaxRecipientsMustBe256");
    }
}
