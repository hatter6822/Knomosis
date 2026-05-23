// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {SmtCellVerifier} from "../src/lib/SmtCellVerifier.sol";

/// @title ComputeEmptyHashes
/// @notice SC.2.a — Foundry script that recomputes the 256 canonical
///         empty-subtree hashes used by `SmtCellVerifier`.  Mirrors
///         Lean's `LegalKernel.FaultProof.emptySubtreeHashes`.
///
/// @dev    Cross-stack reviewers re-run this script to confirm the
///         `SmtCellVerifier` constants byte-for-byte match the Lean
///         derivation.  The derivation rule is fixed:
///
///         ```
///         H_0     = keccak256("EMPTY_LEAF")
///         H_{d+1} = keccak256(H_d || H_d)
///         ```
///
///         Both sides MUST produce the same hashes when Lean is
///         linked against the production `knomosis-hash-keccak256`
///         adaptor.
///
///         Usage:
///         ```bash
///         forge script script/ComputeEmptyHashes.s.sol
///         ```
contract ComputeEmptyHashes is Script {
    /// @notice Recompute the 256 canonical empty-subtree hashes and
    ///         emit each one to the script log.  The output is the
    ///         reference table that `SmtCellVerifier.emptySubtreeHash`
    ///         and `SmtCellVerifier.precomputeEmptySubtreeHashes`
    ///         must reproduce.
    function run() external pure {
        bytes32[256] memory hashes = SmtCellVerifier.precomputeEmptySubtreeHashes();

        console.log("# SMT canonical empty-subtree hashes (depths 0..255)");
        console.log("# H_0 = keccak256(\"EMPTY_LEAF\")");
        console.log("# H_{d+1} = keccak256(H_d || H_d)");
        console.log("");

        for (uint256 d = 0; d < 256; ++d) {
            console.log("# depth %s:", d);
            console.logBytes32(hashes[d]);
        }

        // Self-check: verify the derivation rule holds.
        bytes32 seed = keccak256("EMPTY_LEAF");
        require(hashes[0] == seed, "H_0 must equal keccak256(\"EMPTY_LEAF\")");
        for (uint256 d = 1; d < 256; ++d) {
            bytes32 expected = keccak256(abi.encodePacked(hashes[d - 1], hashes[d - 1]));
            require(hashes[d] == expected, "H_{d+1} must equal keccak256(H_d || H_d)");
        }

        console.log("");
        console.log("# Self-check PASSED: all 256 hashes satisfy the derivation rule.");
    }
}
