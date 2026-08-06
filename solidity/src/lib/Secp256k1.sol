// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

/// @title Secp256k1
/// @notice SEC1-compressed public-key decompression and Ethereum
///         address derivation — the bridge between the L2 registry's
///         33-byte compressed keys and L1 `ecrecover`'s 20-byte
///         addresses (Workstream F-A).
///
/// @dev    **Why this exists.**  The fault-proof game's terminal step
///         resolves the disputed action's signer to a public key by
///         opening the signer's registry cell against the pre-state
///         root; the registry stores the production adaptor's 33-byte
///         SEC1-compressed form.  `ecrecover` returns
///         `keccak256(uncompressed_point)[12:]`, so comparing the two
///         requires decompressing the registered key on-chain.
///
///         **The mathematics.**  secp256k1's field prime satisfies
///         `p ≡ 3 (mod 4)`, so a square root of a quadratic residue
///         `a` is `a^((p+1)/4) mod p`, one MODEXP precompile call.
///         The candidate is VERIFIED (`y² ≡ x³ + 7`) rather than
///         trusted: for a non-residue the exponentiation returns a
///         value whose square is `-a`, and an x-coordinate with no
///         curve point must be refused, not decompressed to garbage —
///         `x = 0` is such a value (7 is a non-residue mod p), and a
///         forged registry payload could otherwise smuggle an
///         off-curve "key" into the comparison.
///
///         Fail-closed throughout: wrong length, wrong prefix,
///         `x ≥ p` and off-curve x all revert.  The terminate wiring
///         maps these to its invalid-signature verdict — a registered
///         key the L1 cannot interpret can never DEFEND a disputed
///         action.
library Secp256k1 {
    /// @notice The field prime `p` of secp256k1.
    uint256 internal constant P =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;

    /// @notice `(p + 1) / 4` — the Tonelli shortcut exponent for
    ///         `p ≡ 3 (mod 4)`.
    uint256 internal constant SQRT_EXP =
        0x3FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBFFFFF0C;

    /// @notice The group order `n` of secp256k1.
    uint256 internal constant N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// @notice `⌊n / 2⌋` — the EIP-2 / BIP-62 low-s threshold.  A
    ///         signature with `s > N_HALF` is malleable and the L2
    ///         adaptor rejects it; L1 verification mirrors the gate so
    ///         the fault proof never DEFENDS a signature the L2 would
    ///         have refused to admit (`ecrecover` itself accepts
    ///         high-s, so the gate must live in the caller).
    uint256 internal constant N_HALF =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice The compressed key is not exactly 33 bytes.
    error PubkeyWrongLength(uint256 got);

    /// @notice The SEC1 prefix is not `0x02` / `0x03`.
    error PubkeyBadPrefix(uint8 prefix);

    /// @notice The x-coordinate is not a canonical field element.
    error PubkeyXNotInField(uint256 x);

    /// @notice The x-coordinate has no point on the curve.
    error PubkeyNotOnCurve(uint256 x);

    /// @notice The MODEXP precompile call failed (out-of-gas or a
    ///         pruned precompile — not reachable on mainnet-shaped
    ///         chains).
    error ModExpFailed();

    /// @dev `base^SQRT_EXP mod P` via the MODEXP precompile (0x05).
    function _modSqrtCandidate(uint256 base) private view returns (uint256 y) {
        bytes memory input = abi.encodePacked(
            uint256(32), uint256(32), uint256(32), base, SQRT_EXP, P
        );
        (bool ok, bytes memory out) = address(0x05).staticcall(input);
        if (!ok || out.length != 32) {
            revert ModExpFailed();
        }
        y = abi.decode(out, (uint256));
    }

    /// @notice Decompress a 33-byte SEC1-compressed secp256k1 public
    ///         key into its affine coordinates.
    /// @param  pk the compressed key: `0x02`/`0x03` prefix + 32-byte
    ///         big-endian x.
    /// @return x the x-coordinate.
    /// @return y the y-coordinate whose parity matches the prefix.
    function decompress(bytes memory pk)
        internal
        view
        returns (uint256 x, uint256 y)
    {
        if (pk.length != 33) {
            revert PubkeyWrongLength(pk.length);
        }
        uint8 prefix = uint8(pk[0]);
        if (prefix != 0x02 && prefix != 0x03) {
            revert PubkeyBadPrefix(prefix);
        }
        for (uint256 i = 0; i < 32; i++) {
            x = (x << 8) | uint256(uint8(pk[1 + i]));
        }
        if (x >= P) {
            revert PubkeyXNotInField(x);
        }
        // y² = x³ + 7 (mod p); candidate root via the p ≡ 3 (mod 4)
        // shortcut, then VERIFIED — a non-residue's candidate squares
        // to -y² and is refused.
        uint256 y2 = addmod(mulmod(mulmod(x, x, P), x, P), 7, P);
        y = _modSqrtCandidate(y2);
        if (mulmod(y, y, P) != y2) {
            revert PubkeyNotOnCurve(x);
        }
        // Select the root whose parity the prefix names.  (`y = 0`
        // only arises for `y2 = 0`, which no on-curve x produces
        // since x³ + 7 ≡ 0 has no root with a valid point pairing on
        // this curve's cofactor-1 group; the parity flip `P - y` is
        // therefore always a genuine second root.)
        if ((y & 1) != (uint256(prefix) & 1)) {
            y = P - y;
        }
    }

    /// @notice The Ethereum address of a compressed public key:
    ///         `keccak256(x ‖ y)[12:]` — exactly what `ecrecover`
    ///         returns for signatures under that key.
    function toAddress(bytes memory pk) internal view returns (address) {
        (uint256 x, uint256 y) = decompress(pk);
        // casting to 'uint160' is the address derivation itself: an
        // Ethereum address IS the low 160 bits of the point's hash,
        // so the truncation is the specified semantics rather than a
        // lossy accident.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
    }

    /// @notice Non-reverting [`decompress`]: `ok = false` on any
    ///         malformed or off-curve input instead of a revert.
    ///
    /// @dev    For callers whose malformed-key outcome is a VERDICT
    ///         rather than a refused call — the fault-proof game's
    ///         signature gate treats an uninterpretable registered key
    ///         as an invalid signature (fail-closed: it can never
    ///         DEFEND a disputed action), and a revert there would
    ///         leave the game unsettleable instead.
    function tryDecompress(bytes memory pk)
        internal
        view
        returns (bool ok, uint256 x, uint256 y)
    {
        if (pk.length != 33) {
            return (false, 0, 0);
        }
        uint8 prefix = uint8(pk[0]);
        if (prefix != 0x02 && prefix != 0x03) {
            return (false, 0, 0);
        }
        for (uint256 i = 0; i < 32; i++) {
            x = (x << 8) | uint256(uint8(pk[1 + i]));
        }
        if (x >= P) {
            return (false, 0, 0);
        }
        uint256 y2 = addmod(mulmod(mulmod(x, x, P), x, P), 7, P);
        y = _modSqrtCandidate(y2);
        if (mulmod(y, y, P) != y2) {
            return (false, 0, 0);
        }
        if ((y & 1) != (uint256(prefix) & 1)) {
            y = P - y;
        }
        ok = true;
    }

    /// @notice Non-reverting [`toAddress`]: `ok = false` on any
    ///         malformed or off-curve input.
    function tryToAddress(bytes memory pk)
        internal
        view
        returns (bool ok, address addr)
    {
        (bool okPoint, uint256 x, uint256 y) = tryDecompress(pk);
        if (!okPoint) {
            return (false, address(0));
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        addr = address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));
        ok = true;
    }
}
