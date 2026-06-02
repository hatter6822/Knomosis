// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CBEDecode} from "src/lib/CBEDecode.sol";

/// @title CBEDecodeProxy
/// @notice Thin wrapper that re-exposes `CBEDecode`'s internal
///         library functions as external calldata-taking functions.
///         The test deploys one instance and calls into it; this
///         is the standard way to test a calldata-only library
///         against `bytes memory` fixtures.
contract CBEDecodeProxy {
    function readUint64LE(bytes calldata buf, uint256 offset)
        external
        pure
        returns (uint64, uint256)
    {
        return CBEDecode.readUint64LE(buf, offset);
    }

    function readHead(bytes calldata buf, uint256 offset, uint8 expectedTag)
        external
        pure
        returns (uint64, uint256)
    {
        return CBEDecode.readHead(buf, offset, expectedTag);
    }

    function readBytes_(bytes calldata buf, uint256 offset)
        external
        pure
        returns (bytes memory, uint256)
    {
        return CBEDecode.readBytes(buf, offset);
    }

    function readBytes32Exact(bytes calldata buf, uint256 offset)
        external
        pure
        returns (bytes32, uint256)
    {
        return CBEDecode.readBytes32Exact(buf, offset);
    }

    function readAddressExact(bytes calldata buf, uint256 offset)
        external
        pure
        returns (address, uint256)
    {
        return CBEDecode.readAddressExact(buf, offset);
    }

    function readArrayHead(bytes calldata buf, uint256 offset)
        external
        pure
        returns (uint64, uint256)
    {
        return CBEDecode.readArrayHead(buf, offset);
    }

    function peekTag(bytes calldata buf, uint256 offset) external pure returns (uint8) {
        return CBEDecode.peekTag(buf, offset);
    }

    function assertFullyConsumed(bytes calldata buf, uint256 consumedTo) external pure {
        CBEDecode.assertFullyConsumed(buf, consumedTo);
    }
}

/// @title CBEDecodeTest
/// @notice Tests for the CBE decoder library.  Each test exercises
///         exactly one fixture pattern so cross-stack failures (Lean
///         vs. Solidity divergence) are localised.
contract CBEDecodeTest is Test {
    CBEDecodeProxy private cbe;

    function setUp() public {
        cbe = new CBEDecodeProxy();
    }

    // ---- Fixture builders (mirror Lean's natToBytesLE / cborHeadEncode) ----

    /// @notice Encode a Nat as 8 little-endian bytes (matches
    ///         `natToBytesLE n 8`).
    function _natToBytesLE8(uint64 n) internal pure returns (bytes memory) {
        bytes memory out = new bytes(8);
        for (uint64 i = 0; i < 8; ++i) {
            out[uint256(i)] = bytes1(uint8((n >> (8 * i)) & 0xFF));
        }
        return out;
    }

    /// @notice Build a CBE head: tag + 8 LE bytes.
    function _cborHead(uint8 tag, uint64 n) internal pure returns (bytes memory) {
        bytes memory head = new bytes(9);
        head[0] = bytes1(tag);
        bytes memory tail = _natToBytesLE8(n);
        for (uint256 i = 0; i < 8; ++i) {
            head[1 + i] = tail[i];
        }
        return head;
    }

    /// @notice Build a CBE byte string: head(tag=0x02, length=N) + N
    ///         payload bytes.
    function _cborBytes(bytes memory payload) internal pure returns (bytes memory) {
        bytes memory head = _cborHead(CBEDecode.TAG_BYTES, uint64(payload.length));
        return bytes.concat(head, payload);
    }

    // ---- readUint64LE tests ----

    function test_readUint64LE_zero() public view {
        bytes memory s = _natToBytesLE8(0);
        (uint64 v, uint256 nxt) = cbe.readUint64LE(s, 0);
        assertEq(v, uint64(0));
        assertEq(nxt, 8);
    }

    function test_readUint64LE_max() public view {
        bytes memory s = _natToBytesLE8(type(uint64).max);
        (uint64 v, uint256 nxt) = cbe.readUint64LE(s, 0);
        assertEq(v, type(uint64).max);
        assertEq(nxt, 8);
    }

    function test_readUint64LE_arbitrary_value() public view {
        // 0x01_02_03_04_05_06_07_08 written LE → bytes 08, 07, 06, ...
        uint64 expected = 0x0102030405060708;
        bytes memory s = _natToBytesLE8(expected);
        assertEq(uint8(s[0]), 0x08);
        assertEq(uint8(s[7]), 0x01);
        (uint64 v,) = cbe.readUint64LE(s, 0);
        assertEq(v, expected);
    }

    function test_readUint64LE_with_offset() public view {
        bytes memory prefix = hex"deadbeef";
        bytes memory tail = _natToBytesLE8(42);
        bytes memory s = bytes.concat(prefix, tail);
        (uint64 v, uint256 nxt) = cbe.readUint64LE(s, 4);
        assertEq(v, 42);
        assertEq(nxt, 12);
    }

    function test_readUint64LE_revert_on_short_input() public {
        bytes memory s = hex"010203";
        vm.expectRevert(CBEDecode.CBEUnexpectedEof.selector);
        cbe.readUint64LE(s, 0);
    }

    function testFuzz_readUint64LE_roundtrip(uint64 n) public view {
        bytes memory s = _natToBytesLE8(n);
        (uint64 v,) = cbe.readUint64LE(s, 0);
        assertEq(v, n);
    }

    // ---- readHead tests ----

    function test_readHead_uint() public view {
        bytes memory s = _cborHead(CBEDecode.TAG_UINT, 12345);
        (uint64 v, uint256 nxt) = cbe.readHead(s, 0, CBEDecode.TAG_UINT);
        assertEq(v, 12345);
        assertEq(nxt, 9);
    }

    function test_readHead_array() public view {
        bytes memory s = _cborHead(CBEDecode.TAG_ARRAY, 7);
        (uint64 count, uint256 nxt) = cbe.readHead(s, 0, CBEDecode.TAG_ARRAY);
        assertEq(count, 7);
        assertEq(nxt, 9);
    }

    function test_readHead_revert_on_wrong_tag() public {
        bytes memory s = _cborHead(CBEDecode.TAG_UINT, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                CBEDecode.CBEInvalidMajorType.selector,
                uint8(CBEDecode.TAG_UINT),
                uint8(CBEDecode.TAG_BYTES)
            )
        );
        cbe.readHead(s, 0, CBEDecode.TAG_BYTES);
    }

    function test_readHead_revert_on_eof_before_tag() public {
        bytes memory s = "";
        vm.expectRevert(CBEDecode.CBEUnexpectedEof.selector);
        cbe.readHead(s, 0, CBEDecode.TAG_UINT);
    }

    function test_readHead_revert_on_eof_after_tag() public {
        bytes memory s = hex"00";
        vm.expectRevert(CBEDecode.CBEUnexpectedEof.selector);
        cbe.readHead(s, 0, CBEDecode.TAG_UINT);
    }

    // ---- readBytes tests ----

    function test_readBytes_empty_payload() public view {
        bytes memory s = _cborBytes(hex"");
        (bytes memory payload, uint256 nxt) = cbe.readBytes_(s, 0);
        assertEq(payload.length, 0);
        assertEq(nxt, 9);
    }

    function test_readBytes_three_byte_payload() public view {
        bytes memory s = _cborBytes(hex"010203");
        (bytes memory payload, uint256 nxt) = cbe.readBytes_(s, 0);
        assertEq(payload.length, 3);
        assertEq(uint8(payload[0]), 1);
        assertEq(uint8(payload[1]), 2);
        assertEq(uint8(payload[2]), 3);
        assertEq(nxt, 12);
    }

    function test_readBytes_revert_on_truncated_payload() public {
        // Claim 100 bytes of payload but only provide 2.
        bytes memory s = abi.encodePacked(_cborHead(CBEDecode.TAG_BYTES, 100), hex"abcd");
        vm.expectRevert(CBEDecode.CBEInvalidLength.selector);
        cbe.readBytes_(s, 0);
    }

    function test_readBytes_revert_on_wrong_tag() public {
        bytes memory s = _cborHead(CBEDecode.TAG_UINT, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                CBEDecode.CBEInvalidMajorType.selector,
                uint8(CBEDecode.TAG_UINT),
                uint8(CBEDecode.TAG_BYTES)
            )
        );
        cbe.readBytes_(s, 0);
    }

    // ---- readBytes32Exact / readBytesExact / readAddressExact tests ----

    function test_readBytes32Exact_round_trip() public view {
        bytes32 hash = keccak256("foo");
        bytes memory payload = abi.encodePacked(hash);
        bytes memory s = _cborBytes(payload);
        (bytes32 got, uint256 nxt) = cbe.readBytes32Exact(s, 0);
        assertEq(got, hash);
        assertEq(nxt, 9 + 32);
    }

    function test_readBytes32Exact_revert_on_size_mismatch() public {
        bytes memory s = _cborBytes(hex"0102");
        vm.expectRevert(
            abi.encodeWithSelector(CBEDecode.CBESizeMismatch.selector, 32, 2)
        );
        cbe.readBytes32Exact(s, 0);
    }

    function test_readAddressExact_round_trip() public view {
        address a = 0xa11CE0AAAaaa00000000000000000000000000Aa;
        // BE-encode the 20 bytes via abi.encodePacked, which emits
        // the canonical lowest-byte-first big-endian form for an
        // address.
        bytes memory payload = abi.encodePacked(a);
        assertEq(payload.length, 20);
        bytes memory s = _cborBytes(payload);
        (address got,) = cbe.readAddressExact(s, 0);
        assertEq(got, a);
    }

    function test_readAddressExact_revert_on_size_mismatch() public {
        bytes memory s = _cborBytes(hex"deadbeef");
        vm.expectRevert(
            abi.encodeWithSelector(CBEDecode.CBESizeMismatch.selector, 20, 4)
        );
        cbe.readAddressExact(s, 0);
    }

    // ---- assertFullyConsumed tests ----

    function test_assertFullyConsumed_ok() public view {
        bytes memory s = hex"abcd";
        cbe.assertFullyConsumed(s, 2);
    }

    function test_assertFullyConsumed_revert_on_trailing_bytes() public {
        bytes memory s = hex"abcdef";
        vm.expectRevert(CBEDecode.CBEInvalidLength.selector);
        cbe.assertFullyConsumed(s, 2);
    }

    // ---- peekTag tests ----

    function test_peekTag_does_not_advance() public view {
        bytes memory s = _cborHead(CBEDecode.TAG_ARRAY, 5);
        uint8 tag = cbe.peekTag(s, 0);
        assertEq(tag, CBEDecode.TAG_ARRAY);
        // Subsequent decode still works.
        (uint64 count,) = cbe.readArrayHead(s, 0);
        assertEq(count, 5);
    }

    function test_peekTag_revert_on_eof() public {
        bytes memory s = "";
        vm.expectRevert(CBEDecode.CBEUnexpectedEof.selector);
        cbe.peekTag(s, 0);
    }
}
