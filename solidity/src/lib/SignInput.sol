// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {CBEEncode} from "./CBEEncode.sol";

/// @title SignInput
/// @notice Recomputes the L2 signing digest on L1: the keccak256 of
///         the canonical CBE sign-input bytes
///         (`signInput(action, signer, nonce, deploymentId)`,
///         Genesis Plan §8.8.5 / `docs/abi.md` §7) from the packed
///         `(kind, fields)` pair the fault-proof game's terminal step
///         already authenticates by inclusion proof.
///
/// @dev    **Why this exists (Workstream F-A).**  The batch
///         actions-root leaf binds the disputed action's 65-byte
///         signature (ruling R7), so terminate can authenticate WHICH
///         bytes the sequencer committed — but verifying the signature
///         needs the digest the signer attested, and that digest is
///         over the CBE `signInput`, not over the packed L1 field
///         layout.  This library is the packed → CBE transcoder plus
///         the digest assembly: given `(kind, fields, signer, nonce,
///         deploymentId)` it reproduces `Authority.signingInput`
///         byte-for-byte and hashes it, so
///         `ecrecover(digest, v, r, s)` can be compared against the
///         signer's registered key.
///
///         **Losslessness.**  `actionFieldsForL1`
///         (`FaultProof/StepVMCoherence.lean`) carries every CBE field
///         of every variant: structured variants pack them big-endian
///         at fixed offsets, and the opaque variants (dispute /
///         verdict / local-policy / fault-proof meta-actions) carry
///         their CBE encodings VERBATIM.  So the transcode is exact —
///         structured fields are re-emitted on the little-endian CBE
///         heads via `CBEEncode`, verbatim fields are appended
///         unchanged after the constructor tag.
///
///         **Fail-closed.**  A structured variant whose `fields`
///         length is not the frozen layout's reverts
///         (`FieldsWrongLength`) rather than mis-parsing; an unknown
///         kind reverts (`UnknownActionKind`).  Verbatim variants
///         take no length gate: their fields are opaque CBE payloads,
///         and a malformed blob simply produces a digest no genuine
///         signature verifies against — the same verdict-shaped
///         outcome the signature check itself delivers.
///
///         Byte authority: the Lean `Authority.signingInput`
///         (`Authority/SignedAction.lean`), pinned per-variant by the
///         `signing_input.json` cross-stack fixture.
library SignInput {
    /// @notice The action kind is outside the frozen `0..=25` range.
    /// @param  kind the offending kind byte.
    error UnknownActionKind(uint8 kind);

    /// @notice A structured variant's packed fields have the wrong
    ///         length for its frozen layout.
    /// @param  kind the action kind.
    /// @param  got the supplied length.
    /// @param  expected the frozen layout's length.
    error FieldsWrongLength(uint8 kind, uint256 got, uint256 expected);

    /// @dev The §8.8.5 domain-separation string, 27 ASCII bytes.
    ///      Mirrors `Authority.signedActionDomain`.
    bytes internal constant DOMAIN = "legalkernel/v1/signedaction";

    /// @dev Read a big-endian uint64 at `offset` in `fields`.
    ///      Callers gate the length first.
    function _u64BE(bytes memory fields, uint256 offset)
        private
        pure
        returns (uint256 v)
    {
        for (uint256 i = 0; i < 8; i++) {
            v = (v << 8) | uint256(uint8(fields[offset + i]));
        }
    }

    /// @dev Read a big-endian uint256 at `offset` in `fields`.
    function _u256BE(bytes memory fields, uint256 offset)
        private
        pure
        returns (uint256 v)
    {
        for (uint256 i = 0; i < 32; i++) {
            v = (v << 8) | uint256(uint8(fields[offset + i]));
        }
    }

    /// @dev Copy `fields[offset..]` into a fresh bytes value.
    function _tail(bytes memory fields, uint256 offset)
        private
        pure
        returns (bytes memory out)
    {
        out = new bytes(fields.length - offset);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = fields[offset + i];
        }
    }

    /// @dev Copy `fields[offset..offset+len)` into a fresh bytes value.
    function _slice(bytes memory fields, uint256 offset, uint256 len)
        private
        pure
        returns (bytes memory out)
    {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = fields[offset + i];
        }
    }

    /// @dev Revert unless `fields.length == expected`.
    function _requireLen(uint8 kind, bytes memory fields, uint256 expected)
        private
        pure
    {
        if (fields.length != expected) {
            revert FieldsWrongLength(kind, fields.length, expected);
        }
    }

    /// @notice Transcode a packed `(kind, fields)` pair into the
    ///         canonical CBE `Action` encoding
    ///         (`Encoding.Action.encode`): the 9-byte constructor tag
    ///         followed by the per-variant CBE fields.
    /// @param  kind the frozen constructor index (`0..=25`).
    /// @param  fields the packed `actionFieldsForL1` bytes.
    /// @return the CBE action bytes.
    function cbeAction(uint8 kind, bytes memory fields)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory tag = CBEEncode.uintValue(kind);
        if (kind == 0) {
            // transfer: u64 r ‖ u64 sender ‖ u64 receiver ‖ u256 amount.
            _requireLen(kind, fields, 56);
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.uintValue(_u64BE(fields, 8)),
                CBEEncode.uintValue(_u64BE(fields, 16)),
                CBEEncode.amountValue(_u256BE(fields, 24))
            );
        }
        if (kind == 1 || kind == 2 || kind == 5 || kind == 6 || kind == 7) {
            // mint / burn / reward / distributeOthers /
            // proportionalDilute: u64 ‖ u64 ‖ u256.
            _requireLen(kind, fields, 48);
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.uintValue(_u64BE(fields, 8)),
                CBEEncode.amountValue(_u256BE(fields, 16))
            );
        }
        if (kind == 3) {
            // freezeResource: u64 r.
            _requireLen(kind, fields, 8);
            return bytes.concat(tag, CBEEncode.uintValue(_u64BE(fields, 0)));
        }
        if (kind == 4 || kind == 12) {
            // replaceKey / registerIdentity: u64 actor ‖ raw key bytes
            // (variable trailer → CBE byte string).
            if (fields.length < 8) {
                revert FieldsWrongLength(kind, fields.length, 8);
            }
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.bytesValue(_tail(fields, 8))
            );
        }
        if (
            kind == 8 || kind == 9 || kind == 10 || kind == 11 || kind == 15
                || kind == 16 || kind == 17 || kind == 18
        ) {
            // Opaque variants: the packed fields ARE the CBE field
            // encodings (dispute, disputeWithdraw, verdict, rollback,
            // declareLocalPolicy, revokeLocalPolicy [empty],
            // faultProofChallenge, faultProofResolution) — append
            // verbatim after the tag.
            return bytes.concat(tag, fields);
        }
        if (kind == 13) {
            // deposit: u64 r ‖ u64 recipient ‖ u256 amount ‖ u64 depositId.
            _requireLen(kind, fields, 56);
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.uintValue(_u64BE(fields, 8)),
                CBEEncode.amountValue(_u256BE(fields, 16)),
                CBEEncode.uintValue(_u64BE(fields, 48))
            );
        }
        if (kind == 14) {
            // withdraw: u64 r ‖ u64 sender ‖ u256 amount ‖ 20-byte L1
            // address (CBE byte string on the Lean side).
            _requireLen(kind, fields, 68);
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.uintValue(_u64BE(fields, 8)),
                CBEEncode.amountValue(_u256BE(fields, 16)),
                CBEEncode.bytesValue(_slice(fields, 48, 20))
            );
        }
        if (kind == 19) {
            // depositWithFee: u64 r ‖ u64 recipient ‖ u64 poolActor ‖
            // u256 userAmount ‖ u256 poolAmount ‖ u64 budgetGrant ‖
            // u64 depositId ‖ u256 seedAmount.
            _requireLen(kind, fields, 136);
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.uintValue(_u64BE(fields, 8)),
                CBEEncode.uintValue(_u64BE(fields, 16)),
                CBEEncode.amountValue(_u256BE(fields, 24)),
                CBEEncode.amountValue(_u256BE(fields, 56)),
                CBEEncode.uintValue(_u64BE(fields, 88)),
                CBEEncode.uintValue(_u64BE(fields, 96)),
                CBEEncode.amountValue(_u256BE(fields, 104))
            );
        }
        if (kind == 20) {
            // topUpActionBudget: u64 gasResource ‖ u256 gasAmount ‖
            // u64 budgetIncrement ‖ u64 poolActor.
            _requireLen(kind, fields, 56);
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.amountValue(_u256BE(fields, 8)),
                CBEEncode.uintValue(_u64BE(fields, 40)),
                CBEEncode.uintValue(_u64BE(fields, 48))
            );
        }
        if (kind == 21) {
            // topUpActionBudgetFor: u64 recipient ‖ u64 gasResource ‖
            // u256 gasAmount ‖ u64 budgetIncrement ‖ u64 poolActor.
            _requireLen(kind, fields, 64);
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.uintValue(_u64BE(fields, 8)),
                CBEEncode.amountValue(_u256BE(fields, 16)),
                CBEEncode.uintValue(_u64BE(fields, 48)),
                CBEEncode.uintValue(_u64BE(fields, 56))
            );
        }
        if (kind == 22) {
            // claimBudgetRefund: u64 gasResource ‖ u64 budgetUnits ‖
            // u256 weiPerBudgetUnit ‖ u64 poolActor.
            _requireLen(kind, fields, 56);
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.uintValue(_u64BE(fields, 8)),
                CBEEncode.amountValue(_u256BE(fields, 16)),
                CBEEncode.uintValue(_u64BE(fields, 48))
            );
        }
        // Kind 23 (the retired L1-AMM ammSwap mirror) is a permanent
        // hole: the Lean encoder has no tag-23 arm and its decoder
        // refuses the tag, so this mirror falls through to
        // `UnknownActionKind` like any never-assigned kind.
        if (kind == 24) {
            // reclaimAmmReserves: u64 r ‖ u256 amount ‖ u64 reserveActor
            // ‖ u64 poolActor.
            _requireLen(kind, fields, 56);
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.amountValue(_u256BE(fields, 8)),
                CBEEncode.uintValue(_u64BE(fields, 40)),
                CBEEncode.uintValue(_u64BE(fields, 48))
            );
        }
        if (kind == 25) {
            // reserveSwap: u64 fromResource ‖ u64 toResource ‖ u64 user
            // ‖ u256 amountIn ‖ u256 minAmountOut ‖ u64 reserveActor.
            _requireLen(kind, fields, 96);
            return bytes.concat(
                tag,
                CBEEncode.uintValue(_u64BE(fields, 0)),
                CBEEncode.uintValue(_u64BE(fields, 8)),
                CBEEncode.uintValue(_u64BE(fields, 16)),
                CBEEncode.amountValue(_u256BE(fields, 24)),
                CBEEncode.amountValue(_u256BE(fields, 56)),
                CBEEncode.uintValue(_u64BE(fields, 88))
            );
        }
        revert UnknownActionKind(kind);
    }

    /// @notice Assemble the canonical sign-input bytes
    ///         (`Authority.signingInput`): the CBE-wrapped domain
    ///         string, the CBE-wrapped deployment id, the CBE action,
    ///         the CBE signer and the CBE nonce, concatenated.
    /// @param  kind the frozen constructor index.
    /// @param  fields the packed `actionFieldsForL1` bytes.
    /// @param  signer the L2 signer's actor id.
    /// @param  nonce the nonce the signature attests (at terminate:
    ///         the pre-state's expected nonce, the only admissible
    ///         value).
    /// @param  deploymentId the deployment's genesis-state hash.
    /// @return the sign-input bytes.
    function signingInput(
        uint8 kind,
        bytes memory fields,
        uint64 signer,
        uint64 nonce,
        bytes memory deploymentId
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            CBEEncode.bytesValue(DOMAIN),
            CBEEncode.bytesValue(deploymentId),
            cbeAction(kind, fields),
            CBEEncode.uintValue(signer),
            CBEEncode.uintValue(nonce)
        );
    }

    /// @notice The signing digest: `keccak256` of the sign-input
    ///         bytes — what the production wire signature's
    ///         `(r, s, v)` recovers against (`docs/abi.md` §7.1).
    function signingDigest(
        uint8 kind,
        bytes memory fields,
        uint64 signer,
        uint64 nonce,
        bytes memory deploymentId
    ) internal pure returns (bytes32) {
        return keccak256(signingInput(kind, fields, signer, nonce, deploymentId));
    }
}
