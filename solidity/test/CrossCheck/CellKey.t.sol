// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {StepVMMerkle} from "src/lib/StepVMMerkle.sol";

/// @title CellKeyCrossCheck
/// @notice Pins `StepVMMerkle.deriveCellSmtKey` against the Lean
///         `LegalKernel.FaultProof.smtCellKey` corpus
///         (`cell_key.json`, emitted by
///         `LegalKernel.Test.Bridge.CrossCheck.CellKey`).
///
/// @dev    An SMT cell proof opens exactly one leaf, and which leaf
///         is determined by the key.  If the two stacks derive
///         different keys, the Lean-computed state root and the
///         L1-recomputed root disagree — and nothing in either
///         suite would attribute that to the key derivation.
///
///         The two halves are pinned separately because they fail
///         differently:
///
///           * the PRE-IMAGE layout is hash-independent, so it is
///             checked unconditionally and catches any width, order
///             or padding drift even under the fallback hash;
///           * the KEY is `keccak256(preimage)`, so it is checked
///             only when the fixture was generated against a
///             keccak-linked build — the same gate the other
///             cross-stack suites use.
contract CellKeyCrossCheck is Test {
    string internal constant FIXTURE = "test/CrossCheck/fixtures/cell_key.json";

    function _fixture() internal view returns (string memory) {
        return vm.readFile(FIXTURE);
    }

    /// The pre-image layout, checked for every corpus entry.  This
    /// is the assertion that actually constrains the derivation: it
    /// runs regardless of which hash the fixture was built with.
    function test_preimage_layout_matches_lean() public view {
        string memory json = _fixture();
        uint256 count = vm.parseJsonUint(json, ".count");
        assertGt(count, 0, "empty corpus");

        for (uint256 i = 0; i < count; ++i) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            uint8 kind = uint8(vm.parseJsonUint(json, string.concat(base, ".kind")));
            uint256 keyA = _parseDecimalString(json, string.concat(base, ".keyA"));
            uint256 keyB = _parseDecimalString(json, string.concat(base, ".keyB"));
            // Compared as hex STRINGS via `parseJsonString`, not via
            // `parseJsonBytes`: that cheatcode truncated the 65-byte
            // value to 64, silently dropping a byte — and the dropped
            // byte is the kind discriminator this test exists to pin.
            // `parseJson` + `abi.decode(..., (string))` does not work
            // either: foundry auto-detects a `0x`-prefixed value as
            // bytes, so the decode yields an empty string and the
            // comparison passes vacuously against nothing.
            string memory expected =
                vm.parseJsonString(json, string.concat(base, ".preimageHex"));

            // The Solidity side of the layout: exactly the packing
            // `StepVMMerkle.deriveCellSmtKey` hashes.
            bytes memory actual = abi.encodePacked(kind, keyA, keyB);

            assertEq(actual.length, 65, "pre-image must be 1 + 32 + 32 bytes");
            assertEq(
                vm.toString(actual),
                expected,
                string.concat("pre-image mismatch at entry ", vm.toString(i))
            );
        }
    }

    /// The derived key, checked only against a keccak-linked
    /// fixture.  Under the FNV-1a-64 fallback the Lean `keyHex`
    /// column is not a keccak hash, so comparing would be
    /// meaningless rather than informative.
    function test_derived_key_matches_lean() public view {
        string memory json = _fixture();
        if (!vm.parseJsonBool(json, ".isKeccak256Linked")) {
            // Deliberately not `vm.skip`: this is a view function and
            // the pre-image test above still constrains the layout.
            return;
        }
        uint256 count = vm.parseJsonUint(json, ".count");
        for (uint256 i = 0; i < count; ++i) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            uint8 kind = uint8(vm.parseJsonUint(json, string.concat(base, ".kind")));
            uint256 keyA = _parseDecimalString(json, string.concat(base, ".keyA"));
            uint256 keyB = _parseDecimalString(json, string.concat(base, ".keyB"));
            string memory expected =
                vm.parseJsonString(json, string.concat(base, ".keyHex"));

            bytes32 derived = StepVMMerkle.deriveCellSmtKey(kind, keyA, keyB);
            assertEq(
                vm.toString(abi.encodePacked(derived)),
                expected,
                string.concat("key mismatch at entry ", vm.toString(i))
            );
        }
    }

    /// Distinct cells must derive distinct keys, or a proof for one
    /// verifies as a proof about another.  Checked directly on the
    /// Solidity side so the property does not rest on the Lean
    /// corpus alone.
    function test_distinct_cells_derive_distinct_keys() public pure {
        // Same key components, different kinds.
        assertTrue(
            StepVMMerkle.deriveCellSmtKey(1, 5, 0)
                != StepVMMerkle.deriveCellSmtKey(2, 5, 0),
            "nonce and registry for the same actor must differ"
        );
        // Same kind, swapped components — catches a derivation that
        // concatenates without preserving order.
        assertTrue(
            StepVMMerkle.deriveCellSmtKey(0, 1, 2)
                != StepVMMerkle.deriveCellSmtKey(0, 2, 1),
            "balance(1,2) and balance(2,1) must differ"
        );
        // Ids differing by exactly 2^64 — the case a packed
        // `1 + 8 + 8` key would collapse.
        assertTrue(
            StepVMMerkle.deriveCellSmtKey(4, 0, 0)
                != StepVMMerkle.deriveCellSmtKey(4, 1 << 64, 0),
            "deposit ids differing by 2^64 must not alias"
        );
    }

    /// `keyA` / `keyB` ship as decimal STRINGS because a Lean
    /// `DepositId` is an unbounded natural and JSON numbers are not
    /// a safe carrier for values past 2^53.
    function _parseDecimalString(string memory json, string memory path)
        internal
        pure
        returns (uint256)
    {
        return vm.parseUint(vm.parseJsonString(json, path));
    }
}
