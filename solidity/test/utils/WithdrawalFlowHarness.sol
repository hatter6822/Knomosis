// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisEip712} from "src/lib/KnomosisEip712.sol";

/// @title WithdrawalFlowHarness
/// @notice Shared CBE + EIP-712 withdrawal-flow helpers for every suite that
///         drives the full deposit → state-root → `withdrawWithProof` round
///         trip (`BoldCircuitBreaker`, `BenchmarkGasV1_3`, `AmmKillSwitch`).
///         One canonical copy of the leaf / proof encoders and the attestor
///         EIP-712 signer, so the wire format the tests speak cannot drift
///         per-suite.
///
/// @dev    The CBE encoders mirror Lean's `Bridge.PendingWithdrawal.encode`
///         and `WithdrawalProof` shapes byte-for-byte (`docs/abi.md` §13.4 /
///         §16.3); the EIP-712 digest mirrors `KnomosisBridge`'s
///         `submitStateRoot` recovery.  Stateless (`internal pure` / `view`
///         helpers only); inheriting suites supply the bridge instance and
///         the attestor key, so suites with different staging keep their own
///         scenario state.
abstract contract WithdrawalFlowHarness {
    /// @dev Cheatcode handle independent of forge-std's `Test`, so the
    ///      harness composes with any base-contract stack without a
    ///      diamond on `Test`.
    Vm private constant VM_SIGNER = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ------------------------------------------------------------------
    // EIP-712 state-root attestation
    // ------------------------------------------------------------------

    /// @notice The EIP-712 digest `submitStateRoot` recovers against.
    function _stateRootDigest(KnomosisBridge bridge, bytes32 root, uint64 idx)
        internal
        view
        returns (bytes32)
    {
        bytes32 ds = KnomosisEip712.domainSeparator(
            "KnomosisBridge", "1", block.chainid, uint256(0), address(bridge)
        );
        bytes32 sh = keccak256(
            abi.encode(
                keccak256("StateRoot(bytes32 root,uint64 logIndexHigh,bytes32 deploymentId)"),
                root,
                uint256(idx),
                bridge.deploymentId()
            )
        );
        return KnomosisEip712.digest(ds, sh);
    }

    /// @notice Sign a state root as the attestor whose private key is
    ///         `attestorPk`, in the `(r, s, v)` packing `submitStateRoot`
    ///         expects.
    function _signStateRootAs(uint256 attestorPk, KnomosisBridge bridge, bytes32 root, uint64 idx)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            VM_SIGNER.sign(attestorPk, _stateRootDigest(bridge, root, idx));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------
    // CBE primitives (mirror Lean's canonical byte encoding)
    // ------------------------------------------------------------------

    function _leBytes8(uint64 v) internal pure returns (bytes memory out) {
        out = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    function _cbeUint(uint64 v) internal pure returns (bytes memory) {
        return bytes.concat(hex"00", _leBytes8(v));
    }

    function _cbeBytes(bytes memory payload) internal pure returns (bytes memory) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes.concat(hex"02", _leBytes8(uint64(payload.length)), payload);
    }

    function _cbeArrayHead(uint64 count) internal pure returns (bytes memory) {
        return bytes.concat(hex"04", _leBytes8(count));
    }

    // ------------------------------------------------------------------
    // Withdrawal leaf + proof blobs
    // ------------------------------------------------------------------

    /// @notice The canonical 56-byte `PendingWithdrawal` leaf blob.
    function _encodeWithdrawalLeaf(
        uint64 resourceId,
        address recipient,
        uint64 amount,
        uint64 l2LogIndex
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            _cbeUint(resourceId),
            _cbeBytes(abi.encodePacked(recipient)),
            _cbeUint(amount),
            _cbeUint(l2LogIndex)
        );
    }

    /// @notice The canonical `WithdrawalProof` blob: leaf + index + the
    ///         64 root-to-leaf siblings.
    function _encodeWithdrawalProof(bytes memory leaf, uint64 idx, bytes[] memory siblings)
        internal
        pure
        returns (bytes memory)
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory out =
            bytes.concat(_cbeBytes(leaf), _cbeUint(idx), _cbeArrayHead(uint64(siblings.length)));
        for (uint256 i = 0; i < siblings.length; i++) {
            out = bytes.concat(out, _cbeBytes(siblings[i]));
        }
        return out;
    }
}
