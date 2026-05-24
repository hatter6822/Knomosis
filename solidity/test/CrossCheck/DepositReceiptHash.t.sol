// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "./Framework.t.sol";

/// @title DepositReceiptHashCrossCheck
/// @notice Workstream F.1.4 — Solidity-side consumer of the
///         `deposit_receipt_hash.json` fixture.
///
/// @dev    For each entry, we recompute:
///           deploymentId = keccak256(abi.encode(chainid, contractAddr, knomosisVersionTag))
///           receiptHash  = keccak256(abi.encode(deploymentId, depositor, resourceId, token, amount, depositorNonce))
///         and assert byte equality with the fixture's `expectedHash`.
///         When the Lean side is on the FNV fallback (no production
///         keccak256 binding), the fixture's `expectedHash` won't
///         match `keccak256` — the cross-check is gated on the
///         header's `isKeccak256Linked`.
contract DepositReceiptHashCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE_NAME = "deposit_receipt_hash.json";

    /// @notice Header shape: 128 entries with the documented breakdown.
    function test_fixture_header_shape() public view {
        if (!fixtureExists(FIXTURE_NAME)) {
            revert("fixture missing; run `lake test` first");
        }
        string memory raw = readFixture(FIXTURE_NAME);
        assertEq(vm.parseJsonUint(raw, ".header.count"), 128, "count");
        assertEq(vm.parseJsonUint(raw, ".header.countCornerNativeEth"), 16, "native");
        assertEq(vm.parseJsonUint(raw, ".header.countCornerErc20"), 16, "erc20");
        assertEq(vm.parseJsonUint(raw, ".header.countBoundary"), 8, "boundary");
        assertEq(vm.parseJsonUint(raw, ".header.countReplayResistance"), 8, "replay");
        assertEq(vm.parseJsonUint(raw, ".header.countDeploymentReplay"), 16, "deploymentReplay");
        assertEq(vm.parseJsonUint(raw, ".header.countRandomised"), 64, "randomised");
    }

    /// @notice Per-entry cross-stack receipt-hash check.  Skipped if
    ///         the Lean side is on the FNV fallback.
    function test_perEntry_receiptHash_matches() public {
        if (!fixtureExists(FIXTURE_NAME)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE_NAME);
        bool linked = vm.parseJsonBool(raw, ".header.isKeccak256Linked");
        if (!linked) {
            _skipWithReason("keccak256 fallback; cross-check skipped");
            return;
        }
        uint256 n = vm.parseJsonUint(raw, ".header.count");
        for (uint256 i = 0; i < n; i++) {
            string memory base = string.concat(".entries[", vm.toString(i), "]");
            uint256 chainid     = vm.parseJsonUint(raw, string.concat(base, ".chainid"));
            address contractAddr = vm.parseJsonAddress(raw, string.concat(base, ".contractAddr"));
            bytes32 knomosisTag    = vm.parseJsonBytes32(raw, string.concat(base, ".knomosisVersionTag"));
            address depositor   = vm.parseJsonAddress(raw, string.concat(base, ".depositor"));
            uint256 resourceId  = vm.parseJsonUint(raw, string.concat(base, ".resourceId"));
            address token       = vm.parseJsonAddress(raw, string.concat(base, ".token"));
            bytes32 amountB     = vm.parseJsonBytes32(raw, string.concat(base, ".amount"));
            uint256 amount      = uint256(amountB);
            uint256 nonce       = vm.parseJsonUint(raw, string.concat(base, ".depositorNonce"));
            bytes32 expectedHash = vm.parseJsonBytes32(raw, string.concat(base, ".expectedHash"));
            bytes32 expectedDid  = vm.parseJsonBytes32(raw, string.concat(base, ".deploymentId"));

            // Audit-pass bound checks: the Lean generator constrains
            // `resourceId < 2^64` (genNat 64) and `depositorNonce <
            // 2^64` (genUInt64Wide).  Asserting the bound explicitly
            // converts a silent fixture-corruption case into a loud
            // failure here (rather than a byte-level digest mismatch
            // further down).  These bounds also guarantee that
            // passing the values to `abi.encode` as `uint256`
            // produces byte-identical output to the on-chain call's
            // `abi.encode(... uint64 resourceId ... uint64 nonce ...)`
            // — Solidity ABI v2 zero-pads every integer type ≤ 256
            // bits to a 32-byte word, and equal values < 2^64 always
            // yield equal 32-byte words regardless of the static
            // type used to encode.
            assertLt(resourceId, 1 << 64, "resourceId out of uint64 range");
            assertLt(nonce, 1 << 64, "depositorNonce out of uint64 range");

            bytes32 did = keccak256(abi.encode(chainid, contractAddr, knomosisTag));
            assertEq(did, expectedDid, "deploymentId mismatch");

            // No `uint64(...)` cast is needed: under the bound
            // checks above, encoding `resourceId` / `nonce` as
            // `uint256` produces the same 32-byte ABI words the
            // on-chain `_registerDeposit` produces from its `uint64`
            // parameters.  Avoiding the cast also avoids the
            // unsafe-typecast linter warning.
            bytes32 actual = keccak256(
                abi.encode(did, depositor, resourceId, token, amount, nonce)
            );
            assertEq(actual, expectedHash, "receiptHash mismatch");
        }
    }

    /// @notice Replay-distinguishability sub-suite.  The 8
    ///         replay-resistance corners (header offset = 32; +0..+7)
    ///         produce 8 distinct hashes.
    function test_replay_resistance_distinct() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        // Layout per Lean's `buildFixture`:
        //   [0..16) corner native + [16..32) corner erc20
        //   [32..40) boundary
        //   [40..48) replay-resistance
        //   [48..64) deployment-replay
        //   [64..96) random native + [96..128) random erc20
        bytes32[] memory hashes = new bytes32[](8);
        for (uint256 i = 0; i < 8; i++) {
            string memory base = string.concat(".entries[", vm.toString(40 + i), "]");
            hashes[i] = vm.parseJsonBytes32(raw, string.concat(base, ".expectedHash"));
        }
        for (uint256 i = 0; i < 8; i++) {
            for (uint256 j = i + 1; j < 8; j++) {
                assertTrue(hashes[i] != hashes[j], "replay-resistance hashes collided");
            }
        }
    }

    /// @notice The 16 deployment-replay corners produce 16 distinct hashes.
    function test_deployment_replay_distinct() public view {
        if (!fixtureExists(FIXTURE_NAME)) return;
        string memory raw = readFixture(FIXTURE_NAME);
        bytes32[] memory hashes = new bytes32[](16);
        for (uint256 i = 0; i < 16; i++) {
            string memory base = string.concat(".entries[", vm.toString(48 + i), "]");
            hashes[i] = vm.parseJsonBytes32(raw, string.concat(base, ".expectedHash"));
        }
        for (uint256 i = 0; i < 16; i++) {
            for (uint256 j = i + 1; j < 16; j++) {
                assertTrue(hashes[i] != hashes[j], "deployment-replay hashes collided");
            }
        }
    }
}
