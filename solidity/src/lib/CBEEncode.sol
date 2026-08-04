// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

/// @title CBEEncode
/// @notice The on-chain CBE value ENCODERS — the inverse of
///         `CBEDecode.sol`, and the primitives the step VM needs once
///         it computes cell values rather than hashing them.
///
/// @dev    **Why this exists.**  `CBEDecode` has readers and no
///         writers, which was sufficient while `executeStep` only ever
///         READ proven cell values and folded them into a bespoke
///         hash.  Returning a state root means the step VM must
///         produce each written cell's new value in its CANONICAL byte
///         form: the SMT leaf is hashed over those bytes, so a value
///         that is numerically right and byte-wrong re-walks to a
///         different root, and the honest sequencer's root becomes
///         unreachable.
///
///         Lean mirrors: `Encoding.cborHeadEncode` (the uint and
///         amount heads) and `Encoding.encodeBytesList` (the
///         byte-string head).  Byte layouts:
///
///         | value  | tag  | payload                    | total |
///         |--------|------|----------------------------|-------|
///         | uint   | 0x00 | 8 bytes, LITTLE-endian     | 9     |
///         | amount | 0x06 | 32 bytes, LITTLE-endian    | 33    |
///         | bytes  | 0x02 | 8-byte LE length, then raw | 9 + n |
///
///         **Little-endian, and that is not a typo.**  The CBE head is
///         little-endian while `actionFieldsForL1` is big-endian, so
///         the two byte orders coexist in the same contract and a
///         wrong-endianness encoder produces a plausible 9-byte value
///         that hashes to the wrong leaf.  `CBEDecode.readUint64LE`
///         reads the same order; these functions are its inverse and
///         are tested as such.
///
///         Widths are fixed rather than minimal: the head is always 8
///         payload bytes for a uint even when the value fits in one,
///         because a length-minimal encoding would make two encodings
///         of the same number and the SMT leaf must be a function of
///         the value alone.
library CBEEncode {
    /// @notice The uint tag.  Mirrors `Encoding.cbeTagUint`.
    uint8 internal constant CBE_TAG_UINT = 0x00;
    /// @notice The amount tag.  Mirrors `Encoding.cbeTagAmount`.
    ///
    /// @dev    `0x06`, not the `0x01` it was.  The tag moved with the
    ///         width so a stale decoder fails closed on an unexpected
    ///         tag rather than reading a 33-byte value as 17 and
    ///         mis-parsing every byte after it.
    uint8 internal constant CBE_TAG_AMOUNT = 0x06;
    /// @notice The byte-string tag.  Mirrors `Encoding.cbeTagBytes`.
    uint8 internal constant CBE_TAG_BYTES = 0x02;

    /// @notice A value exceeds the fixed-width payload it must fit.
    /// @param  value the offending value.
    /// @param  widthBytes the payload width in bytes.
    error CBEValueTooWide(uint256 value, uint256 widthBytes);

    /// @dev Little-endian fixed-width serialisation of `n` into
    ///      `widthBytes` bytes.  Reverts rather than truncating: a
    ///      silent truncation is how an over-wide value would encode
    ///      as its low bits and hash to a leaf for a DIFFERENT value,
    ///      which is exactly the class of bug a fault proof exists to
    ///      catch — and it is finding C-3, which reached the amount
    ///      head itself before the width moved to 32 bytes.  At
    ///      `widthBytes == 32` the range check is vacuous by
    ///      construction, since every `uint256` fits.
    function _leBytes(uint256 n, uint256 widthBytes)
        private
        pure
        returns (bytes memory out)
    {
        if (widthBytes < 32 && n >= (uint256(1) << (8 * widthBytes))) {
            revert CBEValueTooWide(n, widthBytes);
        }
        out = new bytes(widthBytes);
        uint256 v = n;
        for (uint256 i = 0; i < widthBytes; i++) {
            out[i] = bytes1(uint8(v & 0xFF));
            v >>= 8;
        }
    }

    /// @notice Encode a `Nat` as the canonical 9-byte CBE uint.
    ///
    /// @dev    The form every counter-shaped cell takes: nonces, the
    ///         withdrawal-id counter, the epoch-budget components, and
    ///         the 0/1 booleans.
    ///
    /// @param  n the value; must be below `2^64`.
    /// @return the 9-byte encoding.
    function uintValue(uint256 n) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(CBE_TAG_UINT), _leBytes(n, 8));
    }

    /// @notice Encode an `Amount` as the canonical 33-byte CBE amount.
    ///
    /// @dev    The form every balance cell takes.  A SEPARATE tag from
    ///         the uint, so a balance and a counter holding the same
    ///         number are different cell values — which is what stops
    ///         a proof opening one from being replayed as the other.
    ///
    /// @param  n the value; must be below `2^256` — i.e. any
    ///         `uint256`, so `_leBytes` cannot reject it.  That is the
    ///         point of the width: the EVM word and the CBE amount head
    ///         now have the same ceiling, and `Laws.maxAmount` is that
    ///         same `2^256`.
    /// @return the 33-byte encoding.
    function amountValue(uint256 n) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(CBE_TAG_AMOUNT), _leBytes(n, 32));
    }

    /// @notice Encode a byte string as the canonical CBE byte string.
    ///
    /// @dev    The form registry cells take.  The 9-byte head is
    ///         present even for a zero-length payload, which is what
    ///         makes a registration with the EMPTY key distinguishable
    ///         from an absent one — and registration is an
    ///         admissibility gate, so those are different states.
    ///
    /// @param  payload the raw bytes.
    /// @return the head followed by the payload.
    function bytesValue(bytes memory payload)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(
            bytes1(CBE_TAG_BYTES), _leBytes(payload.length, 8), payload
        );
    }

    /// @notice Encode an epoch-budget cell: two uints in sequence.
    ///
    /// @dev    Both components in ONE cell, so a proof cannot open the
    ///         balance without also fixing the epoch it belongs to —
    ///         reading them apart would let a stale-epoch balance be
    ///         presented as current.
    ///
    /// @param  lastSeenEpoch the epoch the budget was last normalised in.
    /// @param  budgetBalance the remaining budget.
    /// @return the 18-byte encoding.
    function epochBudgetValue(uint256 lastSeenEpoch, uint256 budgetBalance)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(uintValue(lastSeenEpoch), uintValue(budgetBalance));
    }
}
