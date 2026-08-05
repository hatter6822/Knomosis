// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {FeeSplitMath} from "test/utils/FeeSplitMath.sol";

/// @title DepositEventDecoder
/// @notice **The deposit receipt, as a type.**
///
/// @dev    `DepositWithFeeInitiated` carries nine fields, and until this
///         existed nothing represented them together.  They travelled as
///         loose positional values: nine arguments into
///         `FeeSplitMath.receiptHash`, nine into `emit`, eight or nine
///         out of four separately hand-written readers, and call sites
///         that read `(,,,, bytes32 hash,,,)`.
///
///         That has two costs.  The obvious one is a miscount — nothing
///         distinguishes the fourth blank from the fifth.  The
///         structural one is that a function touching a deposit carries
///         one live local PER FIELD, at every hop; ten to fifteen live
///         locals is routine in these suites.  solc 0.8.20's allocator
///         tolerates it and 0.8.35's does not, which is how the cost
///         became visible — but the stack errors were the symptom.  The
///         defect was a nine-field domain object with no type.
///
///         Nine slots become one pointer, and the blanks become names.
abstract contract DepositEventDecoder {
    /// @dev forge-std's cheatcode handle, re-derived rather than
    ///      inherited: this module is deliberately not a `Test`, so a
    ///      non-test contract can decode a receipt too.
    Vm private constant _VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Every field of `DepositWithFeeInitiated`, indexed topics
    ///         and data words alike, in the event's own order.
    struct DepositReceipt {
        address sender;
        uint64 resourceId;
        address token;
        uint256 userAmount;
        uint256 poolAmount;
        uint256 ammSeedAmount;
        uint64 budgetGrant;
        uint64 nonce;
        bytes32 receiptHash;
    }

    /// @notice The receipt the bridge just emitted.
    ///
    /// @dev    The ONE reader.  Reverts when the log set holds no such
    ///         event, because every caller has just made a deposit it
    ///         expects to have succeeded: returning a zero struct would
    ///         let a silently-skipped deposit read as a legitimate
    ///         all-zero split.
    ///
    ///         The signature stays a string — solc will not resolve an
    ///         event through the contract type before 0.8.35, and
    ///         `IKnomosisBridge` does not redeclare it.  At one copy
    ///         that is safe in a way four copies were not: every caller
    ///         decodes a log the bridge has just emitted, so a drifted
    ///         signature matches nothing and reverts across every suite
    ///         at once.  Loud, not silent.
    function _findDepositReceipt(Vm.Log[] memory logs)
        internal
        pure
        returns (DepositReceipt memory r)
    {
        bytes32 sig = keccak256(
            "DepositWithFeeInitiated(address,uint64,address,uint256,uint256,uint256,uint64,uint64,bytes32)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 4 && logs[i].topics[0] == sig) {
                r.sender = address(uint160(uint256(logs[i].topics[1])));
                r.resourceId = uint64(uint256(logs[i].topics[2]));
                r.token = address(uint160(uint256(logs[i].topics[3])));
                (
                    r.userAmount,
                    r.poolAmount,
                    r.ammSeedAmount,
                    r.budgetGrant,
                    r.nonce,
                    r.receiptHash
                ) = abi.decode(
                    logs[i].data, (uint256, uint256, uint256, uint64, uint64, bytes32));
                return r;
            }
        }
        revert("DepositWithFeeInitiated not found");
    }

    /// @notice `FeeSplitMath.receiptHash` over a receipt.
    ///
    /// @dev    Two arguments instead of nine.  The nine-argument form is
    ///         where the stack pressure actually came from: every caller
    ///         that computed an expected hash held all nine live across
    ///         the call.
    function _receiptHashOf(bytes32 deploymentId, DepositReceipt memory r)
        internal
        pure
        returns (bytes32)
    {
        return FeeSplitMath.receiptHash(
            deploymentId,
            r.sender,
            r.resourceId,
            r.token,
            r.userAmount,
            r.poolAmount,
            r.ammSeedAmount,
            r.budgetGrant,
            r.nonce
        );
    }

    /// @notice The six data-region fields, for callers that assert on
    ///         those alone.
    ///
    /// @dev    A projection of `_findDepositReceipt`, not a second
    ///         reader.  Kept because several suites destructure exactly
    ///         these six; what matters is that only one function knows
    ///         the event's layout.
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
        DepositReceipt memory r = _findDepositReceipt(logs);
        return (
            r.userAmount, r.poolAmount, r.ammSeedAmount, r.budgetGrant, r.nonce, r.receiptHash
        );
    }
}
