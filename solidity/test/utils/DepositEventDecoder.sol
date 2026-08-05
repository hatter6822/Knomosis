// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

/// @title DepositEventDecoder
/// @notice **Reads `DepositWithFeeInitiated` out of a recorded log.**
///
/// @dev    Four files had written this decoder — three byte-identical
///         six-field versions and one narrower three-field projection —
///         and each hand-wrote the event's canonical signature as a
///         string literal.  That is the same shape as the proxy
///         wrappers, with a sharper edge: the signature and the
///         `abi.decode` tuple together restate the event's ABI, so a
///         field reordered on the contract needs four synchronised
///         edits, and the narrow copy would keep decoding the fields it
///         happened to read.
///
///         The signature stays a string: solc 0.8.20 will not resolve
///         an event through the contract type, and `IKnomosisBridge`
///         does not redeclare it.  That is tolerable HERE in a way it
///         was not at four copies, because the string is anchored by
///         behaviour — every caller decodes a log the bridge has just
///         emitted, so a signature that drifted would match nothing and
///         revert "not found" across four suites at once.  Loud, not
///         silent.  What four copies risked was not a wrong string but
///         three RIGHT ones and a stale fourth.
///
///         One six-field decoder, not one per caller: a caller wanting
///         three fields ignores three, whereas a narrower second
///         function is a second place to update.
abstract contract DepositEventDecoder {
    /// @notice The fields `DepositWithFeeInitiated` carries in its data
    ///         region.
    ///
    /// @dev    Reverts when the log set holds no such event, because
    ///         every caller has just made a deposit it expects to have
    ///         succeeded: returning zeroes would let a silently-skipped
    ///         deposit read as a legitimate all-zero split.
    function _decodeDepositWithFee(Vm.Log[] memory logs)
        internal
        pure
        returns (
            uint256 userAmount,
            uint256 poolAmount,
            uint256 ammSeedAmount,
            uint64 budgetGrant,
            uint64 nonce,
            bytes32 receiptHash
        )
    {
        bytes32 sig = keccak256(
            "DepositWithFeeInitiated(address,uint64,address,uint256,uint256,uint256,uint64,uint64,bytes32)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == sig) {
                (userAmount, poolAmount, ammSeedAmount, budgetGrant, nonce, receiptHash) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint64, uint64, bytes32));
                return (userAmount, poolAmount, ammSeedAmount, budgetGrant, nonce, receiptHash);
            }
        }
        revert("DepositWithFeeInitiated not found");
    }
}
