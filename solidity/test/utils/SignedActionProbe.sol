// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {SignInput} from "src/lib/SignInput.sol";

/// @title SignedActionProbe
/// @notice Shared signing helper for the fault-proof game suites
///         (Workstream F-A).
///
/// @dev    Once terminate VERIFIES the disputed action's signature, a
///         suite that wants the honest path has to present a real one
///         — the fixed-byte placeholder every game test used before
///         now makes the disputed entry inadmissible, which is a
///         DIFFERENT (and separately tested) outcome.
///
///         The key is the corpus's registered signer key: the
///         verifying key for secret scalar `0x01…01`, the same vector
///         `knomosis verify-check` self-tests and
///         `multiProofGoldens`' pre-state registers for the probe
///         signer.  The digest is recomputed with the SAME library
///         the contract uses, so the suites sign what the game will
///         verify rather than a re-derivation that could drift.
abstract contract SignedActionProbe is Test {
    /// @notice The probe signer's secret scalar.  Its SEC1-compressed
    ///         verifying key is
    ///         `0x031b84c5567b126440995d3ed5aaba0565d71e1834604819ff9c17f5e9d5dd078f`
    ///         — what the corpus's pre-state registers for the probe
    ///         signer, and what the game resolves by opening the
    ///         registry cell against the pre-root.
    uint256 internal constant PROBE_SK = uint256(
        0x0101010101010101010101010101010101010101010101010101010101010101);

    /// @notice Sign a disputed action the way its L2 signer did: over
    ///         `keccak256(signInput(kind, fields, signer, nonce,
    ///         deploymentId))`, returning the 65-byte wire signature
    ///         `(r ‖ s ‖ v)`.
    ///
    /// @dev    `vm.sign` emits a canonical low-s signature with
    ///         `v ∈ {27, 28}`, which is exactly the wire convention
    ///         (`docs/abi.md` §7.1) — so a signature built here passes
    ///         the game's low-s and `v`-range gates by construction,
    ///         and a test that wants to violate them perturbs the
    ///         bytes explicitly.
    function signAction(
        uint8 actionKind,
        bytes memory actionFields,
        uint64 signer,
        uint64 nonce,
        bytes32 deploymentId
    ) internal pure returns (bytes memory) {
        bytes32 digest = SignInput.signingDigest(
            actionKind, actionFields, signer, nonce,
            abi.encodePacked(deploymentId));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PROBE_SK, digest);
        return abi.encodePacked(r, s, v);
    }
}
