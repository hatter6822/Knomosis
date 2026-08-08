// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {SignInput} from "src/lib/SignInput.sol";
import {CrossCheckFramework} from "./Framework.t.sol";

/// @title SigningInputCrossCheck
/// @notice Pins `SignInput.sol`'s packed → CBE transcoder and
///         sign-input assembly against the Lean reference corpus
///         (`signing_input.json`, emitted by
///         `LegalKernel.Test.Bridge.CrossCheck.SigningInput`) —
///         Workstream F-A phase FA.1.
///
/// @dev    The corpus carries, per entry, the packed
///         `actionFieldsForL1` bytes (what terminate receives and the
///         batch leaf binds), the canonical CBE action encoding
///         (`Encoding.Action.encode`) and the full §8.8.5 sign-input
///         bytes (`Authority.signingInput`).  The consumer
///         reconstructs BOTH from `(kind, fieldsHex, signer, nonce,
///         deploymentIdHex)` alone, so a transcoder that mis-parses
///         an offset, swaps an endianness, drops a field, or
///         mis-assembles the envelope diverges on at least one of the
///         30 entries covering every frozen kind 0..25.
///
///         Hash-INDEPENDENT: the corpus pins bytes, not digests —
///         `SignInput.signingDigest` is `keccak256` of the pinned
///         bytes, natively computed here, so no keccak-linked gate is
///         needed and the suite runs on every build.
contract SigningInputCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE =
        "test/CrossCheck/fixtures/signing_input.json";

    /// The corpus schema this suite is written against.
    string internal constant IDENTIFIER = "knomosis-faultproof/signing-input/v1";

    /// Exposes the library's revert paths to `vm.expectRevert` via an
    /// external call boundary.
    SignInputCaller internal caller;

    function setUp() public {
        caller = new SignInputCaller();
    }

    function _fixture() internal view returns (string memory) {
        return vm.readFile(FIXTURE);
    }

    /// The CBE action transcode, per corpus entry: packed fields in,
    /// `Encoding.Action.encode` bytes out.
    function test_cbe_action_transcode_matches_lean() public {
        string memory json = _fixture();
        _requireIdentifier(json, ".header.identifier", IDENTIFIER);
        uint256 count = vm.parseJsonUint(json, ".header.count");
        assertGt(count, 0, "empty corpus");

        for (uint256 i = 0; i < count; ++i) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            beginEntry(base);
            uint8 kind =
                uint8(vm.parseJsonUint(json, string.concat(base, ".kind")));
            bytes memory fields = vm.parseBytes(
                vm.parseJsonString(json, string.concat(base, ".fieldsHex"))
            );
            string memory expected =
                vm.parseJsonString(json, string.concat(base, ".cbeActionHex"));

            bytes memory actual = SignInput.cbeAction(kind, fields);
            assertEq(
                vm.toString(actual),
                expected,
                string.concat("CBE action bytes diverge at ", base)
            );
        }
    }

    /// The full sign-input assembly, per corpus entry — and the
    /// digest as a self-consistency corollary.
    function test_signing_input_assembly_matches_lean() public {
        string memory json = _fixture();
        _requireIdentifier(json, ".header.identifier", IDENTIFIER);
        uint256 count = vm.parseJsonUint(json, ".header.count");

        for (uint256 i = 0; i < count; ++i) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            beginEntry(base);
            uint8 kind =
                uint8(vm.parseJsonUint(json, string.concat(base, ".kind")));
            bytes memory fields = vm.parseBytes(
                vm.parseJsonString(json, string.concat(base, ".fieldsHex"))
            );
            uint64 signer =
                uint64(vm.parseJsonUint(json, string.concat(base, ".signer")));
            uint64 nonce =
                uint64(vm.parseJsonUint(json, string.concat(base, ".nonce")));
            bytes memory deploymentId = vm.parseBytes(
                vm.parseJsonString(json, string.concat(base, ".deploymentIdHex"))
            );
            string memory expected = vm.parseJsonString(
                json, string.concat(base, ".signingInputHex")
            );

            bytes memory actual =
                SignInput.signingInput(kind, fields, signer, nonce, deploymentId);
            assertEq(
                vm.toString(actual),
                expected,
                string.concat("sign-input bytes diverge at ", base)
            );
            // The digest is keccak256 of exactly those bytes.
            assertEq(
                SignInput.signingDigest(kind, fields, signer, nonce, deploymentId),
                keccak256(actual),
                "digest is not keccak256 of the sign-input bytes"
            );
        }
    }

    /// Fail-closed: an unknown kind reverts.
    function test_unknown_kind_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(SignInput.UnknownActionKind.selector, 26)
        );
        caller.cbeAction(26, "");
    }

    /// Fail-closed: a structured variant with truncated fields
    /// reverts rather than mis-parsing.  Kind 0 (transfer) expects
    /// 56 bytes.
    function test_truncated_structured_fields_revert() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SignInput.FieldsWrongLength.selector, 0, 55, 56
            )
        );
        caller.cbeAction(0, new bytes(55));
    }

    /// Fail-closed: a variable-trailer variant (replaceKey) shorter
    /// than its fixed prefix reverts.
    function test_short_variable_trailer_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(SignInput.FieldsWrongLength.selector, 4, 7, 8)
        );
        caller.cbeAction(4, new bytes(7));
    }
}

/// @notice Thin external wrapper so library reverts surface across a
///         call boundary `vm.expectRevert` can observe.
contract SignInputCaller {
    function cbeAction(uint8 kind, bytes memory fields)
        external
        pure
        returns (bytes memory)
    {
        return SignInput.cbeAction(kind, fields);
    }
}
