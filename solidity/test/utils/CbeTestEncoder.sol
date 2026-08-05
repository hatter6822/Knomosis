// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
pragma solidity ^0.8.36;

/// @title  CbeTestEncoder
/// @notice Test-side CBE byte builders, mirroring Lean's canonical
///         encoding.  Shared by every suite that hand-builds a blob the
///         production `CBEDecode` reader has to accept.
///
/// @dev    This existed twice — once in `WithdrawalFlowHarness` and once
///         copied verbatim into `BridgeFeeSplitBold.t.sol` — which meant
///         a wire-format change had to be applied to both or one suite
///         silently kept testing the old layout.  Both now inherit this.
///
///         **Head widths are load-bearing.**  `_cbeUint` is the 9-byte
///         head (tag 0x00 + 8 LE) for identifiers, log indices, lengths
///         and budget-UNIT counts; `_cbeAmount` is the 33-byte head
///         (tag 0x06 + 32 LE) for value-carrying amounts.  Using the
///         wrong one shifts every following field, and the production
///         decoder rejects the tag rather than silently truncating.
abstract contract CbeTestEncoder {
    // ------------------------------------------------------------------
    // CBE primitives (mirror Lean's canonical byte encoding)
    // ------------------------------------------------------------------

    /// @notice 8 little-endian bytes of a uint64 (the CBE uint head's
    ///         value form).
    function _leBytes8(uint64 v) internal pure returns (bytes memory out) {
        out = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    /// @notice 32 little-endian bytes of a uint256 (the CBE amount
    ///         head's value form).
    function _leBytes32(uint256 v) internal pure returns (bytes memory out) {
        out = new bytes(32);
        for (uint256 i = 0; i < 32; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    /// @notice CBE uint: tag 0x00 + 8 LE value bytes.
    function _cbeUint(uint64 v) internal pure returns (bytes memory) {
        return bytes.concat(hex"00", _leBytes8(v));
    }

    /// @notice CBE amount: tag 0x06 + 32 LE value bytes.  Value-carrying
    ///         fields only.  The width is the EVM word, so no value a
    ///         test can construct is one the head cannot carry — which
    ///         is the property finding C-3 turned on.
    function _cbeAmount(uint256 v) internal pure returns (bytes memory) {
        return bytes.concat(hex"06", _leBytes32(v));
    }

    /// @notice CBE byte string: tag 0x02 + 8 LE length + payload.
    function _cbeBytes(bytes memory payload) internal pure returns (bytes memory) {
        // Payloads here are tiny (<= 64 bytes); the uint64 cast cannot lose.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes.concat(hex"02", _leBytes8(uint64(payload.length)), payload);
    }

    /// @notice CBE array head: tag 0x04 + 8 LE count.
    function _cbeArrayHead(uint64 count) internal pure returns (bytes memory) {
        return bytes.concat(hex"04", _leBytes8(count));
    }

    // ------------------------------------------------------------------
    // Withdrawal leaf + proof blobs
    // ------------------------------------------------------------------

    /// @notice The canonical 80-byte `PendingWithdrawal` leaf blob,
    ///         matching `KnomosisBridge._decodePendingWithdrawal`:
    ///         9 (resourceId) + 29 (recipient) + 33 (amount) + 9
    ///         (l2LogIndex) = 80 bytes.
    function _encodeWithdrawalLeaf(
        uint64 resourceId,
        address recipient,
        uint128 amount,
        uint64 l2LogIndex
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            _cbeUint(resourceId),
            _cbeBytes(abi.encodePacked(recipient)),
            _cbeAmount(amount),
            _cbeUint(l2LogIndex)
        );
    }

    /// @notice CBE-encode a `WithdrawalProof`, matching
    ///         `KnomosisBridge._decodeWithdrawalProof`: CBE bytes leaf,
    ///         CBE uint index, CBE array of `SMT_HEIGHT` CBE-bytes
    ///         siblings.
    function _encodeWithdrawalProof(bytes memory leaf, uint64 idx, bytes[] memory siblings)
        internal
        pure
        returns (bytes memory)
    {
        // siblings.length is SMT_HEIGHT (64); the uint64 cast cannot lose.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory out =
            bytes.concat(_cbeBytes(leaf), _cbeUint(idx), _cbeArrayHead(uint64(siblings.length)));
        for (uint256 i = 0; i < siblings.length; i++) {
            out = bytes.concat(out, _cbeBytes(siblings[i]));
        }
        return out;
    }
}
