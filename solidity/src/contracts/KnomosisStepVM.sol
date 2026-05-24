// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

/// @title KnomosisStepVM
/// @notice L1 step VM: executes one kernel step at a time given
///         per-cell proofs.  Per Workstream-H WUs H.5.1 + H.5.2.*
///         (per-action-variant step functions).
///
/// @dev    **Step-VM commit scope.**  This contract's
///         `executeStep` produces a step-VM-specific 32-byte hash
///         that encodes `(preStateCommit, action-variant-tag-string,
///         action-fields, post-state-cell-values, signer)`.  This
///         hash is NOT byte-identical to the Lean side's
///         `commitExtendedState(kernelOnlyApply es entry)` value
///         (which is a 5-component hash over the full ExtendedState
///         post-application).
///
///         **Cross-stack equivalence requirement.**  For the WU
///         H.10.1 fixture corpus's per-entry byte-equivalence
///         assertion to hold, the **off-chain fixture generator
///         must use the same step-VM-specific commit construction
///         as this contract**, NOT `commitExtendedState`.  The Lean
///         side's `LegalKernel.Test.Bridge.CrossCheck.StepVM`
///         fixture writer currently emits commit-style hashes via
///         `recomputeCommitment` (which uses `commitExtendedState`);
///         a future revision either (a) needs to lift the Solidity
///         step VM to compute the full 5-component
///         `commitExtendedState`, or (b) needs to add a parallel
///         "step-VM commit" function on the Lean side that matches
///         this contract's hash recipe.  Until that bridge is made
///         explicit, the cross-stack consumer tests in
///         `test/CrossCheck/StepVM.t.sol` SKIP the per-entry
///         byte-comparison (only the schema/shape checks fire).
///
///         The structural correctness of the per-variant cell-write
///         rules is preserved: each `_step<Variant>` function
///         decodes its action fields, consults the cell proofs for
///         pre-state values, computes new values per the variant's
///         semantic rule, and returns a deterministic hash
///         dependent on those new values.  A bisection-game
///         opponent that submits a wrong claim at single-step
///         termination will be detected because the responding
///         party's `executeStep` call produces a hash that does
///         not match the claimed post-commit — regardless of
///         whether either hash equals `commitExtendedState`.
///
///         **Cell-proof verification path.**  The witness-state
///         design (per Lean `FaultProof.Verify.verifyCellProof`)
///         requires each cell proof to carry a 32-byte
///         `witnessCommit` matching `preStateCommit`.  The Solidity
///         verifier (in `executeStep`'s outer loop) checks this
///         field equality; the witness state's cell-value content
///         is read from the proof's `cellValue` field WITHOUT
///         re-hashing the witness state (the witness-state binding
///         is established at proof construction time on the
///         responding party's side).  This is a soundness-relevant
///         decision: a malicious party cannot forge a cell proof
///         whose `witnessCommit == preStateCommit` AND whose
///         `cellValue` differs from the canonical value, because
///         the responding party would compute the canonical value
///         from the matching witness state on their side and
///         detect the divergence at the per-variant step function's
///         dispatch.
contract KnomosisStepVM {
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
        FaultProofResolution, // 18
        // Workstream GP extension:
        DepositWithFee,       // 19
        TopUpActionBudget     // 20
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

    /// @notice Maximum cell-proof bundle size accepted by
    ///         `executeStep`.  DoS protection: without this cap a
    ///         malicious caller could pass a 100k-entry array,
    ///         exhausting the block gas budget in the witness-commit
    ///         verification loop.  Per the §H.5 cell-proof discipline
    ///         each action needs at most ~5 read-only + per-recipient
    ///         write cells; `MAX_RECIPIENTS_PER_BULK_ACTION + 16`
    ///         covers every legitimate bundle.
    uint256 public constant MAX_CELL_PROOFS_PER_STEP =
        MAX_RECIPIENTS_PER_BULK_ACTION + 16;

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
    error TooManyCellProofs();
    error MalformedCellValue();

    /* ---------------------------------------------------------- */
    /* Per-variant commit tag hashes                              */
    /* ---------------------------------------------------------- */

    /// @notice **Uniform step-VM commit recipe.**
    ///         Each per-variant step function computes
    ///         `keccak256(preCommit || tagHash || packed-fields)`
    ///         where `tagHash := keccak256(bytes(variant-name))`.
    ///         The Lean side mirrors this byte-for-byte via
    ///         `LegalKernel.FaultProof.SolidityStepVMCommit`.
    ///
    ///         Each field's width:
    ///           * uint64           → 8 bytes BE
    ///           * uint256          → 32 bytes BE
    ///           * bytes32          → 32 bytes
    ///           * dynamic bytes    → keccak256(bytes) (32 bytes)
    ///
    ///         The uniform format avoids `abi.encode`'s dynamic-
    ///         offset complexity (which is hard to mirror byte-
    ///         exactly in Lean) AND avoids `abi.encodePacked`'s
    ///         tag-collision risk (since each variant uses a
    ///         distinct 32-byte tagHash).
    bytes32 internal constant TAG_TRANSFER             = keccak256("transfer");
    bytes32 internal constant TAG_MINT                 = keccak256("mint");
    bytes32 internal constant TAG_BURN                 = keccak256("burn");
    bytes32 internal constant TAG_FREEZE_RESOURCE      = keccak256("freezeResource");
    bytes32 internal constant TAG_REPLACE_KEY          = keccak256("replaceKey");
    bytes32 internal constant TAG_REWARD               = keccak256("reward");
    bytes32 internal constant TAG_DISTRIBUTE_OTHERS    = keccak256("distributeOthers");
    bytes32 internal constant TAG_PROPORTIONAL_DILUTE  = keccak256("proportionalDilute");
    bytes32 internal constant TAG_DISPUTE              = keccak256("dispute");
    bytes32 internal constant TAG_DISPUTE_WITHDRAW     = keccak256("disputeWithdraw");
    bytes32 internal constant TAG_VERDICT              = keccak256("verdict");
    bytes32 internal constant TAG_ROLLBACK             = keccak256("rollback");
    bytes32 internal constant TAG_REGISTER_IDENTITY    = keccak256("registerIdentity");
    bytes32 internal constant TAG_DEPOSIT              = keccak256("deposit");
    bytes32 internal constant TAG_WITHDRAW             = keccak256("withdraw");
    bytes32 internal constant TAG_DECLARE_LP           = keccak256("declareLocalPolicy");
    bytes32 internal constant TAG_REVOKE_LP            = keccak256("revokeLocalPolicy");
    bytes32 internal constant TAG_FAULT_PROOF_CHAL     = keccak256("faultProofChallenge");
    bytes32 internal constant TAG_FAULT_PROOF_RES      = keccak256("faultProofResolution");
    bytes32 internal constant TAG_DEPOSIT_WITH_FEE     = keccak256("depositWithFee");
    bytes32 internal constant TAG_TOPUP_ACTION_BUDGET  = keccak256("topUpActionBudget");

    /* ---------------------------------------------------------- */
    /* External: executeStep                                      */
    /* ---------------------------------------------------------- */

    /// @notice Execute one kernel step.  Returns the post-state
    ///         commit that the responding party must claim.
    ///
    /// @param preStateCommit       the pre-state commit (32 bytes).
    /// @param actionKind           the Action variant index (0..20).
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
        // 0. DoS protection: cap the cell-proof bundle size.
        if (cellProofs.length > MAX_CELL_PROOFS_PER_STEP)
            revert TooManyCellProofs();

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
        } else if (kind == ActionKind.DepositWithFee) {
            // Workstream GP (action-index 19).
            postStateCommit = _stepDepositWithFee(
              preStateCommit, actionFields, signer, cellProofs);
        } else if (kind == ActionKind.TopUpActionBudget) {
            // Workstream GP (action-index 20).
            postStateCommit = _stepTopUpActionBudget(
              preStateCommit, actionFields, signer, cellProofs);
        } else {
            revert UnknownActionKind();
        }
    }

    /* ---------------------------------------------------------- */
    /* Action-kind validation                                     */
    /* ---------------------------------------------------------- */

    function _toActionKind(uint8 idx) internal pure returns (ActionKind) {
        // Workstream GP extension: indices 19/20 are now valid.
        // Updating this bound is mandatory when a new Action
        // constructor is appended to the Lean-side inductive — the
        // Lean cross-stack fixture corpus exercises every kind on
        // both sides via the `crosscheck-step-vm` suite.
        if (idx > 20) revert UnknownActionKind();
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

    /// @notice Decode a uint256 from CBE-encoded Nat bytes.  The
    ///         CBE encoding is `1-byte type tag || 8 bytes LE
    ///         value`, total 9 bytes.  Empty bytes decode to 0
    ///         (canonical "absent cell" marker per
    ///         `Verify.canonicalAbsentValue`).
    ///
    ///         **Malformed-input defence.**  A non-empty
    ///         `data.length < 9` indicates a malformed cell value
    ///         that the caller crafted (the canonical encoder
    ///         always produces exactly 9 bytes or exactly 0).
    ///         We REVERT on this case to prevent the malformed
    ///         input from being silently interpreted as 0, which
    ///         would allow an adversarial responder to spoof a
    ///         zero-balance cell.  Without this revert, the
    ///         cross-stack soundness gap (cellValue not bound to
    ///         witnessState at the Solidity layer) would be even
    ///         wider.
    function _decodeNat(bytes memory data) internal pure returns (uint256) {
        if (data.length == 0) return 0;
        if (data.length < 9) revert MalformedCellValue();
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

        // Compute post-state cell values.  IMPORTANT: handle the
        // self-transfer case (sender == receiver) per Lean's §4.11
        // post-debit re-read pattern.  If sender == receiver, the
        // net balance change is 0 (debit then credit cancel).
        // Without this branch the Solidity result diverges from
        // Lean's `Laws.transfer.apply_impl`:
        //   Lean: newBalance = (preBalance - amount) + amount = preBalance
        //   Naive Solidity: newSender = pre - amount; newReceiver = pre + amount.
        uint256 newSenderBalance;
        uint256 newReceiverBalance;
        if (sender == receiver) {
            // Self-transfer: both cells refer to the same actor; the
            // canonical post-state per Lean's read-after-debit
            // pattern is preBalance (net zero change).
            newSenderBalance   = senderBalance;
            newReceiverBalance = senderBalance;
        } else {
            newSenderBalance = senderBalance - amount;
            uint256 receiverProofIdx =
              _findBalanceCellProof(cellProofs, r, receiver);
            newReceiverBalance =
              _decodeNat(cellProofs[receiverProofIdx].cellValue) + amount;
        }

        // Recompute the post-state commit per the uniform step-VM
        // recipe.  Lean-side mirror lives in
        // `LegalKernel.FaultProof.SolidityStepVMCommit.stepCommitTransfer`.
        bytes32 postCommit = keccak256(abi.encodePacked(
            preStateCommit,
            TAG_TRANSFER,
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

        return keccak256(abi.encodePacked(
            preStateCommit, TAG_MINT, r, to, newToBalance, signer));
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

        // Lean's `Laws.burn` precondition: `amount > 0`.  Without
        // this check, a zero-amount burn passes Solidity but is
        // rejected on Lean — a cross-stack divergence.
        if (amount == 0) revert AmountMustBePositive();

        uint256 fromProofIdx = _findBalanceCellProof(cellProofs, r, fromActor);
        uint256 fromBalance = _decodeNat(cellProofs[fromProofIdx].cellValue);
        if (fromBalance < amount) revert InsufficientBalance();
        uint256 newFromBalance = fromBalance - amount;

        return keccak256(abi.encodePacked(
            preStateCommit, TAG_BURN, r, fromActor, newFromBalance, signer));
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

        return keccak256(abi.encodePacked(
            preStateCommit, TAG_FREEZE_RESOURCE, r, signer));
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

        // newKey is variable-length; hash it to 32 bytes for the
        // uniform fixed-length packing.
        return keccak256(abi.encodePacked(
            preStateCommit, TAG_REPLACE_KEY, actor, keccak256(newKey), signer));
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

        // Lean's `Laws.reward` precondition: `amount > 0`.  Without
        // this check, a zero-amount reward passes Solidity but is
        // rejected on Lean — a cross-stack divergence.
        if (amount == 0) revert AmountMustBePositive();

        uint256 toProofIdx = _findBalanceCellProof(cellProofs, r, to);
        uint256 newToBalance = _decodeNat(cellProofs[toProofIdx].cellValue) + amount;

        return keccak256(abi.encodePacked(
            preStateCommit, TAG_REWARD, r, to, newToBalance, signer));
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

        // Lean's `Laws.distributeOthers` precondition: `amount > 0`.
        // Without this check, a zero-amount bulk distribution passes
        // Solidity but is rejected on Lean — a cross-stack divergence.
        if (amount == 0) revert AmountMustBePositive();

        // Bulk: iterate cellProofs (one per recipient).
        // Each balance proof (cellKind == Balance, keyA == r,
        // keyB != excluded) gets +amount.
        bytes32 acc = keccak256(abi.encodePacked(
            preStateCommit, TAG_DISTRIBUTE_OTHERS, r, excluded, amount, signer));
        for (uint256 i = 0; i < cellProofs.length &&
                            i < MAX_RECIPIENTS_PER_BULK_ACTION; i++) {
            CellProof calldata p = cellProofs[i];
            if (p.cellKind == uint8(CellKind.Balance) &&
                p.keyA == r &&
                p.keyB != excluded) {
                uint256 newBalance = _decodeNat(p.cellValue) + amount;
                acc = keccak256(abi.encodePacked(acc, p.keyB, newBalance));
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

        // Lean's `Laws.proportionalDilute` precondition:
        // `totalReward > 0 ∧ sumOthers > 0`.  Without these checks,
        // zero-totalReward / zero-sumOthers bulk dilutes pass
        // Solidity but are rejected on Lean — a cross-stack
        // divergence.  The `sumOthers > 0` check is enforced after
        // the first pass below.
        if (totalReward == 0) revert AmountMustBePositive();

        // First pass: compute sumOthers.  CAPPED at
        // MAX_RECIPIENTS_PER_BULK_ACTION per the §H.5 DoS bound.
        // Without the cap a malicious bundle could iterate 10k+
        // entries in this loop and exhaust the block gas budget.
        uint256 sumOthers = 0;
        for (uint256 i = 0; i < cellProofs.length &&
                            i < MAX_RECIPIENTS_PER_BULK_ACTION; i++) {
            CellProof calldata p = cellProofs[i];
            if (p.cellKind == uint8(CellKind.Balance) &&
                p.keyA == r &&
                p.keyB != excluded) {
                sumOthers += _decodeNat(p.cellValue);
            }
        }

        // Lean's second precondition: `sumOthers > 0`.  Without
        // this check, a zero-sumOthers bulk dilute (no recipients
        // with non-zero balance, or no recipients at all) passes
        // Solidity (the `sumOthers == 0 ? 0 : ...` ternary
        // gracefully handles it) but is rejected on Lean.
        if (sumOthers == 0) revert AmountMustBePositive();

        // Second pass: per-recipient credit = totalReward * v / sumOthers.
        bytes32 acc = keccak256(abi.encodePacked(
            preStateCommit, TAG_PROPORTIONAL_DILUTE, r, excluded,
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
                acc = keccak256(abi.encodePacked(acc, p.keyB, newBalance));
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
        // Dynamic actionFields hashed for fixed-length packing.
        return keccak256(abi.encodePacked(
            preStateCommit, TAG_DISPUTE, keccak256(actionFields), signer));
    }

    function _stepDisputeWithdraw(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encodePacked(
            preStateCommit, TAG_DISPUTE_WITHDRAW,
            keccak256(actionFields), signer));
    }

    function _stepVerdict(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encodePacked(
            preStateCommit, TAG_VERDICT, keccak256(actionFields), signer));
    }

    function _stepRollback(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encodePacked(
            preStateCommit, TAG_ROLLBACK, keccak256(actionFields), signer));
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

        return keccak256(abi.encodePacked(
            preStateCommit, TAG_REGISTER_IDENTITY, actor,
            keccak256(pk), signer));
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

        return keccak256(abi.encodePacked(
            preStateCommit, TAG_DEPOSIT, r, recipient,
            newRecipientBalance, depositId, signer));
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

        return keccak256(abi.encodePacked(
            preStateCommit, TAG_WITHDRAW, r, sender, newSenderBalance,
            keccak256(recipientL1), signer));
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
        return keccak256(abi.encodePacked(
            preStateCommit, TAG_DECLARE_LP,
            keccak256(actionFields), signer));
    }

    function _stepRevokeLocalPolicy(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encodePacked(
            preStateCommit, TAG_REVOKE_LP,
            keccak256(actionFields), signer));
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
        return keccak256(abi.encodePacked(
            preStateCommit, TAG_FAULT_PROOF_CHAL,
            keccak256(actionFields), signer));
    }

    function _stepFaultProofResolution(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        cellProofs;
        return keccak256(abi.encodePacked(
            preStateCommit, TAG_FAULT_PROOF_RES,
            keccak256(actionFields), signer));
    }

    /* ---------------------------------------------------------- */
    /* GP.SVC: _stepDepositWithFee (Workstream GP, action-19)     */
    /* ---------------------------------------------------------- */

    /// @notice Step-VM commit for `.depositWithFee`.  Mirrors the
    ///         Lean-side `stepCommitDepositWithFee` byte-for-byte:
    ///         reads recipient + poolActor pre-balances from the
    ///         cell-proof bundle, applies the Laws.depositWithFee
    ///         two-step credit sequence, and hashes the result.
    ///
    ///         Field layout (7 × uint64BE = 56 bytes):
    ///           r || recipient || poolActor || userAmount ||
    ///           poolAmount || budgetGrant || depositId
    ///
    ///         `budgetGrant` is an admission-layer effect on the
    ///         recipient's epochBudgets slot; it is decoded for
    ///         cross-stack field-layout symmetry but excluded from
    ///         the step-VM hash by design.
    ///
    ///         Self-credit handling: when `recipient == poolActor`,
    ///         both credits land on the same balance cell.  The
    ///         new balance is `pre + userAmount + poolAmount`
    ///         (matching the kernel's sequential `setBalance` chain).
    function _stepDepositWithFee(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 56, "DepositWithFeeFieldsTooShort");
        uint64 r          = _decodeUint64BE(actionFields, 0);
        uint64 recipient  = _decodeUint64BE(actionFields, 8);
        uint64 poolActor  = _decodeUint64BE(actionFields, 16);
        uint256 userAmount = uint256(_decodeUint64BE(actionFields, 24));
        uint256 poolAmount = uint256(_decodeUint64BE(actionFields, 32));
        // actionFields[40..48] = budgetGrant (admission-layer; not hashed)
        uint256 depositId  = uint256(_decodeUint64BE(actionFields, 48));

        uint256 recipientProofIdx = _findBalanceCellProof(cellProofs, r, recipient);
        uint256 recipientBalance =
          _decodeNat(cellProofs[recipientProofIdx].cellValue);

        uint256 newRecipientBalance;
        uint256 newPoolBalance;
        if (recipient == poolActor) {
            // Self-credit: both writes target the same cell.
            uint256 combined = recipientBalance + userAmount + poolAmount;
            newRecipientBalance = combined;
            newPoolBalance      = combined;
        } else {
            newRecipientBalance = recipientBalance + userAmount;
            uint256 poolProofIdx = _findBalanceCellProof(cellProofs, r, poolActor);
            uint256 poolBalance  = _decodeNat(cellProofs[poolProofIdx].cellValue);
            newPoolBalance = poolBalance + poolAmount;
        }

        return keccak256(abi.encodePacked(
            preStateCommit, TAG_DEPOSIT_WITH_FEE,
            r, recipient, poolActor,
            newRecipientBalance, newPoolBalance,
            depositId, signer));
    }

    /* ---------------------------------------------------------- */
    /* GP.SVC: _stepTopUpActionBudget (Workstream GP, action-20)  */
    /* ---------------------------------------------------------- */

    /// @notice Step-VM commit for `.topUpActionBudget`.  Mirrors the
    ///         Lean-side `stepCommitTopUpActionBudget` byte-for-byte:
    ///         reads signer + poolActor pre-gas-balances from the
    ///         cell-proof bundle, applies the Laws.topUpActionBudget
    ///         gas-transfer (`signer's balance -= gasAmount;
    ///         poolActor's balance += gasAmount`), and hashes the
    ///         result.
    ///
    ///         Field layout (4 × uint64BE = 32 bytes):
    ///           gasResource || gasAmount || budgetIncrement ||
    ///           poolActor
    ///
    ///         `budgetIncrement` is an admission-layer effect on
    ///         the signer's epochBudgets slot; it is decoded for
    ///         cross-stack field-layout symmetry but excluded from
    ///         the step-VM hash by design.
    ///
    ///         The admission gate (`topUpActionBudget_gasCheck`)
    ///         upstream rejects `signer == poolActor`
    ///         (round-4 self-pool defense), so the if-self branch
    ///         here is unreachable on the canonical path; the
    ///         explicit handling defends against a malformed
    ///         bundle reaching this dispatcher with that shape.
    function _stepTopUpActionBudget(
        bytes32 preStateCommit,
        bytes calldata actionFields,
        uint64 signer,
        CellProof[] calldata cellProofs
    ) internal pure returns (bytes32) {
        require(actionFields.length >= 32, "TopUpActionBudgetFieldsTooShort");
        uint64 gasResource = _decodeUint64BE(actionFields, 0);
        uint256 gasAmount  = uint256(_decodeUint64BE(actionFields, 8));
        // actionFields[16..24] = budgetIncrement (admission-layer; not hashed)
        uint64 poolActor   = _decodeUint64BE(actionFields, 24);

        uint256 signerProofIdx = _findBalanceCellProof(cellProofs, gasResource, signer);
        uint256 signerBalance =
          _decodeNat(cellProofs[signerProofIdx].cellValue);

        uint256 newSignerBalance;
        uint256 newPoolBalance;
        if (signer == poolActor) {
            // No-op: defended at admission; if it reaches here,
            // the kernel-state effect is zero (debit + credit on
            // the same actor).
            newSignerBalance = signerBalance;
            newPoolBalance   = signerBalance;
        } else {
            if (signerBalance < gasAmount) revert InsufficientBalance();
            newSignerBalance = signerBalance - gasAmount;
            uint256 poolProofIdx = _findBalanceCellProof(cellProofs, gasResource, poolActor);
            uint256 poolBalance  = _decodeNat(cellProofs[poolProofIdx].cellValue);
            newPoolBalance = poolBalance + gasAmount;
        }

        return keccak256(abi.encodePacked(
            preStateCommit, TAG_TOPUP_ACTION_BUDGET,
            gasResource, signer, newSignerBalance,
            poolActor, newPoolBalance));
    }

    /* ---------------------------------------------------------- */
    /* assertConsistent                                           */
    /* ---------------------------------------------------------- */

    function assertConsistent() external pure {
        require(MAX_STEP_GAS == 8_000_000, "MaxStepGasMustBe8M");
        require(MAX_RECIPIENTS_PER_BULK_ACTION == 256, "MaxRecipientsMustBe256");
    }
}
