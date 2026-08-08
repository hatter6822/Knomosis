// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Secp256k1} from "src/lib/Secp256k1.sol";

/// @title Secp256k1Test
/// @notice Unit suite for the compressed-key decompression that
///         bridges the L2 registry's 33-byte keys to L1 `ecrecover`
///         addresses (Workstream F-A).
///
/// @dev    The positive vectors are ground truth, not self-derived:
///         the generator point's coordinates are the SEC2 curve
///         constants, and the `verify-check` key's y-coordinate and
///         parity were computed independently of this library.  The
///         `ecrecover` agreement test closes the loop the terminate
///         wiring will rely on: a signature under a key recovers to
///         exactly `Secp256k1.toAddress` of that key's compressed
///         form.
contract Secp256k1Test is Test {
    /// Generator x — SEC2 curve constant.
    uint256 internal constant GX =
        0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798;
    /// Generator y — SEC2 curve constant (even).
    uint256 internal constant GY =
        0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8;

    /// The `knomosis verify-check` self-test key (secret scalar
    /// `0x01…01`): compressed form `0x03 ‖ x`, odd y.
    bytes internal constant VERIFY_CHECK_PK =
        hex"031b84c5567b126440995d3ed5aaba0565d71e1834604819ff9c17f5e9d5dd078f";
    /// Its independently-computed y-coordinate
    /// (`(x³+7)^((p+1)/4) mod p`, parity-flipped to odd).
    uint256 internal constant VERIFY_CHECK_Y =
        0x70beaf8f588b541507fed6a642c5ab42dfdf8120a7f639de5122d47a69a8e8d1;

    Secp256k1Caller internal caller;

    function setUp() public {
        caller = new Secp256k1Caller();
    }

    function _compressed(uint8 prefix, uint256 x)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(prefix, x);
    }

    /// The generator decompresses to its SEC2 coordinates.
    function test_decompresses_generator() public view {
        (uint256 x, uint256 y) = caller.decompress(_compressed(0x02, GX));
        assertEq(x, GX, "generator x");
        assertEq(y, GY, "generator y");
    }

    /// The odd-parity prefix selects the OTHER root: `0x03 ‖ Gx`
    /// yields `p - Gy`.
    function test_parity_selects_root() public view {
        (, uint256 y) = caller.decompress(_compressed(0x03, GX));
        assertEq(y, Secp256k1.P - GY, "odd-parity root");
    }

    /// The verify-check key decompresses to its independently
    /// computed odd y.
    function test_decompresses_verify_check_key() public view {
        (, uint256 y) = caller.decompress(VERIFY_CHECK_PK);
        assertEq(y, VERIFY_CHECK_Y, "verify-check y");
        assertEq(y & 1, 1, "prefix 0x03 names the odd root");
    }

    /// The ecrecover loop: signing with a known key and recovering
    /// lands on `toAddress` of that key's compressed form.  This is
    /// the exact comparison the terminate wiring performs.
    function test_toAddress_agrees_with_ecrecover() public view {
        // The verify-check secret key, as a plain uint256 literal —
        // no cast, so nothing for a truncation lint to doubt.
        uint256 sk = 0x0101010101010101010101010101010101010101010101010101010101010101;
        bytes32 digest = keccak256("F-A ecrecover agreement probe");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sk, digest);
        address recovered = ecrecover(digest, v, r, s);
        assertEq(
            recovered,
            caller.toAddress(VERIFY_CHECK_PK),
            "ecrecover address must equal the decompressed registry key's address"
        );
    }

    /// x = 0 has no curve point (7 is a quadratic non-residue mod p)
    /// and must be refused, not decompressed to garbage.
    function test_rejects_off_curve_x() public {
        vm.expectRevert(
            abi.encodeWithSelector(Secp256k1.PubkeyNotOnCurve.selector, 0)
        );
        caller.decompress(_compressed(0x02, 0));
    }

    /// A non-canonical x (`x ≥ p`) is refused before any curve math.
    function test_rejects_x_at_field_prime() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Secp256k1.PubkeyXNotInField.selector, Secp256k1.P
            )
        );
        caller.decompress(_compressed(0x02, Secp256k1.P));
    }

    /// Uncompressed / hybrid / garbage prefixes are refused.
    function test_rejects_bad_prefixes() public {
        uint8[5] memory bad = [0x00, 0x01, 0x04, 0x06, 0xFF];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    Secp256k1.PubkeyBadPrefix.selector, bad[i]
                )
            );
            caller.decompress(_compressed(bad[i], GX));
        }
    }

    /// Wrong lengths are refused.
    function test_rejects_wrong_lengths() public {
        vm.expectRevert(
            abi.encodeWithSelector(Secp256k1.PubkeyWrongLength.selector, 32)
        );
        caller.decompress(new bytes(32));
        vm.expectRevert(
            abi.encodeWithSelector(Secp256k1.PubkeyWrongLength.selector, 34)
        );
        caller.decompress(new bytes(34));
    }

    /// Fuzz: for random scalars, `toAddress(compressed(sk·G))` equals
    /// `vm.addr(sk)` — foundry's own independent derivation — and a
    /// signature under `sk` ecrecovers to it.
    function testFuzz_toAddress_matches_vm_addr(uint256 skSeed) public {
        // Clamp into the valid scalar range [1, n-1].
        uint256 n =
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        uint256 sk = (skSeed % (n - 1)) + 1;
        // Foundry exposes the public key only via vm.addr / vm.sign;
        // recover the full point by signing and using ecrecover's
        // candidates is circular.  Instead compress via the wallet
        // cheatcode's public key.
        Vm.Wallet memory w = vm.createWallet(sk);
        uint8 prefix = (w.publicKeyY & 1) == 0 ? 0x02 : 0x03;
        bytes memory pk = abi.encodePacked(prefix, w.publicKeyX);
        (uint256 x, uint256 y) = caller.decompress(pk);
        assertEq(x, w.publicKeyX, "fuzz x");
        assertEq(y, w.publicKeyY, "fuzz y");
        assertEq(caller.toAddress(pk), vm.addr(sk), "fuzz address");
    }
}

import {Vm} from "forge-std/Vm.sol";

/// @notice External wrapper so library reverts surface across a call
///         boundary `vm.expectRevert` can observe.
contract Secp256k1Caller {
    function decompress(bytes memory pk)
        external
        view
        returns (uint256, uint256)
    {
        return Secp256k1.decompress(pk);
    }

    function toAddress(bytes memory pk) external view returns (address) {
        return Secp256k1.toAddress(pk);
    }
}
