// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {CBEEncode} from "src/lib/CBEEncode.sol";
import {LogChain} from "src/lib/LogChain.sol";
import {SmtCellVerifier} from "src/lib/SmtCellVerifier.sol";

/// @title ActionsRoot
/// @notice The batch actions-root tree (Workstream SB): one sparse-
///         Merkle root per submitted batch, committing to every action
///         in `[prevEnd, end)` by log index, so a single L1 record
///         covers a whole batch and the fault-proof game authenticates
///         the ONE disputed action by inclusion proof instead of the
///         chain folding one commitment per action.
///
/// @dev    **The tree is the cell-SMT family verbatim** — the same
///         depth-256 walk, the same `bitmask ‖ siblings` wire, the
///         same CBE leaf pre-image, verified by the existing
///         `SmtCellVerifier` — instantiated at `K = V = bytes32`:
///
///           * key   = `keccak256("knomosis.actionsRoot" ‖ uint64BE n)`
///             (the `smtCellKey` recipe over the absolute log index),
///           * value = `keccak256(kind ‖ uint64BE signer ‖ fields ‖
///             sig)` — the SIGNATURE-BOUND leaf commit (decision R7:
///             the fixed 65-byte suffix keeps the pre-image split
///             injective; see Lean `actionLeafPreimage_inj`).
///
///         Mirrors `LegalKernel.FaultProof.ActionsRoot` declaration
///         for declaration; the `actions_root.json` corpus pins the
///         two stacks byte-for-byte, and the `batch_chain.json` corpus
///         pins the chain fold this root is folded into.
library ActionsRoot {
    /// @notice The key-derivation domain tag.  Mirrors Lean
    ///         `ActionsRoot.actionKeyDomain`
    ///         (`"knomosis.actionsRoot".toUTF8`, 20 bytes).
    bytes internal constant ACTION_KEY_DOMAIN = "knomosis.actionsRoot";

    /// @notice The fixed signature width the leaf pre-image binds
    ///         (secp256k1 `r ‖ s ‖ v`).  A variable width would make
    ///         the `fields ‖ sig` split ambiguous and the leaf
    ///         pre-image non-injective.
    uint256 internal constant SIG_BYTES = 65;

    /// @notice The signature is not the fixed 65-byte wire form.
    error ActionSigWrongLength(uint256 got);

    /// @notice The SMT key of absolute log index `n`:
    ///         `keccak256(domain ‖ uint64BE n)`.  Derived on-chain from
    ///         the index — never accepted from calldata — exactly as
    ///         `StepVMMerkle.deriveCellSmtKey` derives cell keys.
    ///         Mirrors Lean `ActionsRoot.actionKey`.
    function actionKey(uint64 n) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(ACTION_KEY_DOMAIN, n));
    }

    /// @notice The 32-byte leaf commit of one signed action:
    ///         `keccak256(kind ‖ uint64BE signer ‖ fields ‖ sig)`.
    ///         Extends `LogChain.actionCommit` (the unsigned triple)
    ///         by the signature suffix.  Mirrors Lean
    ///         `ActionsRoot.actionLeafValue`.
    ///
    /// @dev    The signature is HASHED, not verified — on-chain
    ///         signature verification at terminate is a recorded
    ///         follow-up needing L1 actorId→key resolution.  Binding
    ///         it now means the leaf already commits to what that
    ///         follow-up will check.
    function actionLeafCommit(
        uint8 actionKind,
        uint64 signer,
        bytes calldata actionFields,
        bytes calldata actionSig
    ) internal pure returns (bytes32) {
        if (actionSig.length != SIG_BYTES) {
            revert ActionSigWrongLength(actionSig.length);
        }
        return keccak256(
            abi.encodePacked(actionKind, signer, actionFields, actionSig));
    }

    /// @notice Verify that `commit` is batch index `n`'s leaf under
    ///         `root`.  Mirrors Lean `ActionsRoot.verifyActionProof`:
    ///         a thin instantiation of the cell-proof walk at
    ///         `K = V = bytes32`, deliberately present-leaf-only —
    ///         every index inside a batch carries exactly one action,
    ///         so there is no absent case for an honest submission to
    ///         need.
    ///
    /// @dev    Non-reverting: a malformed proof is `false`, matching
    ///         `SmtCellVerifier.verifyCellProof`'s single-verdict
    ///         contract.
    function verifyActionInclusion(
        bytes32 root,
        uint64 n,
        bytes32 commit,
        bytes calldata proofData
    ) internal pure returns (bool) {
        bytes memory key = abi.encodePacked(actionKey(n));
        return SmtCellVerifier.verifyCellProof(
            root,
            key,
            bytes.concat(
                CBEEncode.bytesValue(key),
                CBEEncode.bytesValue(abi.encodePacked(commit))
            ),
            proofData
        );
    }

    /// @notice The genesis chain seed the constructor-written anchor
    ///         record carries: the ordinary chain step evaluated at
    ///         the all-zero predecessor and the empty actions root.
    ///         Mirrors Lean `ActionsRoot.genesisChainSeed`; pinned by
    ///         the `batch_chain.json` corpus (`genesisSeedHex`).
    function genesisChainSeed(bytes32 genesisStateCommit)
        internal
        pure
        returns (bytes32)
    {
        return LogChain.nextEntryHash(bytes32(0), genesisStateCommit, bytes32(0));
    }
}
