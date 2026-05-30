// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title CBEDecode
/// @notice Byte-level decoder for the **Knomosis Binary Encoding** (CBE)
///         format defined in `LegalKernel/Encoding/CBOR.lean`.
///         Implements the Solidity-side mirror used by
///         `KnomosisBridge.withdrawWithProof` and the
///         `KnomosisDisputeVerifier` per-claim verifiers.
///
/// @dev    Per the integration plan §9.2.1, this library MUST decode
///         byte sequences identically to Lean's
///         `LegalKernel.Encoding.cborHeadDecode` /
///         `LegalKernel.Encoding.natFromBytesLE`.  Cross-stack
///         equivalence is verified by F.1.6 fixtures.
///
///         **CBE format (canonical).**
///         - Each uint head: 1 type-tag byte + 8 little-endian value
///           bytes = 9 bytes total.
///         - Type tags (single byte each):
///           * 0x00 — uint
///           * 0x02 — bytes  (followed by `length` raw payload bytes)
///           * 0x03 — text   (followed by `length` UTF-8 bytes)
///           * 0x04 — array  (followed by `count` element encodings)
///           * 0x05 — map    (followed by `count` (key, value) pairs)
///         - All head values are bounded `< 2^64`; larger inputs are
///           rejected with `CBEMalformed`.
///
///         **Reverts.**  All decode functions revert with typed
///         custom errors on malformed inputs:
///           * `CBEUnexpectedEof` — fewer bytes than required
///           * `CBEInvalidMajorType(got, expected)` — wrong type tag
///           * `CBEInvalidLength` — length prefix exceeds buffer
///         Reverts mirror the Lean `DecodeError` constructors but
///         consolidate into a smaller set per Solidity convention.
library CBEDecode {
    // ------------------------------------------------------------------
    // CBE major-type constants (mirror LegalKernel.Encoding.cbeTag*)
    // ------------------------------------------------------------------

    uint8 internal constant TAG_UINT = 0x00;
    uint8 internal constant TAG_BYTES = 0x02;
    uint8 internal constant TAG_TEXT = 0x03;
    uint8 internal constant TAG_ARRAY = 0x04;
    uint8 internal constant TAG_MAP = 0x05;

    /// @notice Length of a CBE head: 1 type byte + 8 LE value bytes.
    uint256 internal constant HEAD_SIZE = 9;

    // ------------------------------------------------------------------
    // Custom errors
    // ------------------------------------------------------------------

    /// @notice Decoder ran out of bytes mid-item.
    error CBEUnexpectedEof();

    /// @notice Got CBE type tag `got`; expected type tag `expected`.
    error CBEInvalidMajorType(uint8 got, uint8 expected);

    /// @notice A length / count prefix exceeds the remaining buffer
    ///         or claims more than `2^64 - 1`.
    error CBEInvalidLength();

    /// @notice An entry's actual byte size does not match the expected
    ///         size declared by the caller (used for fixed-size
    ///         post-decode checks like `recipientL1` = 20 bytes).
    error CBESizeMismatch(uint256 expected, uint256 actual);

    // ------------------------------------------------------------------
    // Primitive: read 8 LE bytes as uint64
    // ------------------------------------------------------------------

    /// @notice Read 8 little-endian bytes from `buf` starting at
    ///         `offset` and return the Nat-equivalent uint64 value
    ///         plus the next-offset.  Reverts on EOF.
    /// @dev    Mirrors `natFromBytesLE rest 8` in Lean.
    function readUint64LE(bytes calldata buf, uint256 offset)
        internal
        pure
        returns (uint64 value, uint256 nextOffset)
    {
        if (offset + 8 > buf.length) revert CBEUnexpectedEof();
        // Accumulate directly into a uint64 to avoid an unsafe cast.
        // Each shift is `<< (8*i)` for i < 8, so the maximum bit
        // position is 56 (the high byte fills bits 56..63).  The
        // accumulator stays within `[0, 2^64 - 1]` mathematically,
        // and the `uint64` type makes that bound a type-level fact.
        uint64 acc = 0;
        unchecked {
            // Loop counter scoped as uint64 from the outset to satisfy
            // forge-lint's safe-cast discipline.  The loop runs exactly
            // 8 times, so `8 * i < 64` always.
            for (uint64 i = 0; i < 8; ++i) {
                acc |= uint64(uint8(buf[offset + uint256(i)])) << (8 * i);
            }
        }
        value = acc;
        nextOffset = offset + 8;
    }

    // ------------------------------------------------------------------
    // CBE head: tag-byte + 8 LE value bytes
    // ------------------------------------------------------------------

    /// @notice Read a CBE head (1 type byte + 8 LE value bytes) from
    ///         `buf` starting at `offset`, asserting the type tag
    ///         matches `expectedTag`.  Returns the recovered uint64
    ///         and next offset.
    /// @dev    Mirrors `cborHeadDecode` in Lean.
    function readHead(bytes calldata buf, uint256 offset, uint8 expectedTag)
        internal
        pure
        returns (uint64 value, uint256 nextOffset)
    {
        if (offset >= buf.length) revert CBEUnexpectedEof();
        uint8 gotTag = uint8(buf[offset]);
        if (gotTag != expectedTag) revert CBEInvalidMajorType(gotTag, expectedTag);
        (value, nextOffset) = readUint64LE(buf, offset + 1);
    }

    // ------------------------------------------------------------------
    // Typed decoders for the standard CBE shapes
    // ------------------------------------------------------------------

    /// @notice Decode a CBE uint (tag 0x00 + 8 LE bytes).
    function readUint(bytes calldata buf, uint256 offset)
        internal
        pure
        returns (uint64 value, uint256 nextOffset)
    {
        return readHead(buf, offset, TAG_UINT);
    }

    /// @notice Decode a CBE byte string (tag 0x02 + length head +
    ///         `length` payload bytes).  Returns the payload as a
    ///         freshly-allocated `bytes memory`.
    /// @dev    The length head is itself an 8-byte LE uint, so the
    ///         total head consumes 9 bytes before the payload.
    ///         Mirrors `Encodable.decode (T := ByteArray)` in Lean.
    function readBytes(bytes calldata buf, uint256 offset)
        internal
        pure
        returns (bytes memory payload, uint256 nextOffset)
    {
        (uint64 length, uint256 afterHead) = readHead(buf, offset, TAG_BYTES);
        // length is bounded by uint64; for CBE-validity we still
        // reject lengths that would overflow the buffer.
        if (afterHead + length > buf.length) revert CBEInvalidLength();
        payload = new bytes(length);
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                payload[i] = buf[afterHead + i];
            }
        }
        nextOffset = afterHead + length;
    }

    /// @notice Decode a CBE byte string and assert it is exactly
    ///         `expectedSize` bytes long.  Used for fixed-width
    ///         decodes (e.g. EthAddress = 20 bytes; signature = 65
    ///         bytes).
    function readBytesExact(bytes calldata buf, uint256 offset, uint256 expectedSize)
        internal
        pure
        returns (bytes memory payload, uint256 nextOffset)
    {
        (payload, nextOffset) = readBytes(buf, offset);
        if (payload.length != expectedSize) {
            revert CBESizeMismatch(expectedSize, payload.length);
        }
    }

    /// @notice Decode a CBE byte string of size 32 and return as
    ///         `bytes32`.  Convenience for hash / state-root fields.
    function readBytes32Exact(bytes calldata buf, uint256 offset)
        internal
        pure
        returns (bytes32 value, uint256 nextOffset)
    {
        bytes memory payload;
        (payload, nextOffset) = readBytesExact(buf, offset, 32);
        // Pack into a single bytes32 word (big-endian on the wire,
        // matching Lean's `keccak256` output convention).
        assembly {
            value := mload(add(payload, 32))
        }
    }

    /// @notice Decode a CBE byte string of size 20 and return as
    ///         `address`.  Convenience for EthAddress fields
    ///         (matches the audit-2 lossless 20-byte encoding).
    function readAddressExact(bytes calldata buf, uint256 offset)
        internal
        pure
        returns (address value, uint256 nextOffset)
    {
        bytes memory payload;
        (payload, nextOffset) = readBytesExact(buf, offset, 20);
        // Big-endian bytes20 → address.
        uint160 acc;
        unchecked {
            for (uint256 i = 0; i < 20; ++i) {
                acc = (acc << 8) | uint160(uint8(payload[i]));
            }
        }
        value = address(acc);
    }

    /// @notice Decode a CBE array head; returns the element count
    ///         and the offset of the first element's first byte.
    function readArrayHead(bytes calldata buf, uint256 offset)
        internal
        pure
        returns (uint64 count, uint256 nextOffset)
    {
        return readHead(buf, offset, TAG_ARRAY);
    }

    /// @notice Decode a CBE map head; returns the pair count and the
    ///         offset of the first (key,value) pair's first byte.
    function readMapHead(bytes calldata buf, uint256 offset)
        internal
        pure
        returns (uint64 count, uint256 nextOffset)
    {
        return readHead(buf, offset, TAG_MAP);
    }

    // ------------------------------------------------------------------
    // Convenience: peek the major-type tag without consuming
    // ------------------------------------------------------------------

    /// @notice Read the next byte's tag without advancing the offset.
    ///         Used for branching decoders (e.g. `Action`'s
    ///         constructor-tag uint).
    function peekTag(bytes calldata buf, uint256 offset) internal pure returns (uint8 tag) {
        if (offset >= buf.length) revert CBEUnexpectedEof();
        tag = uint8(buf[offset]);
    }

    // ------------------------------------------------------------------
    // Top-level full-consumption check
    // ------------------------------------------------------------------

    /// @notice Assert that `consumedTo == buf.length`.  Top-level
    ///         decoders call this after the last field to catch
    ///         trailing garbage (mirrors Lean's `trailingBytes`
    ///         decode-error case).
    function assertFullyConsumed(bytes calldata buf, uint256 consumedTo) internal pure {
        if (consumedTo != buf.length) revert CBEInvalidLength();
    }
}
