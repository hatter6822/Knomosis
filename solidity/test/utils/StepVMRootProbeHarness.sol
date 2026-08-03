// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {CrossCheckFramework} from "test/CrossCheck/Framework.t.sol";
import {KnomosisStepVMRoot} from "src/contracts/KnomosisStepVMRoot.sol";

/// @title StepVMRootProbeHarness
/// @notice Shared loaders for the `multiProofGoldens` corpus column —
///         the (pre-root, action, signer, log index, frontier, wire,
///         post-root) tuples Lean publishes for
///         `KnomosisStepVMRoot.executeStepToRootMulti`.
///
/// @dev    Two suites consume the same probes for different reasons and
///         must load them identically: the cross-check suite
///         (`test/CrossCheck/StepVMRootMulti.t.sol`), which asserts the
///         verifier reaches Lean's root, and the gas benchmark
///         (`test/BenchmarkGasV1_3.t.sol`), which measures what that
///         costs.  A second spelling of the loader would be a place for
///         the measured call and the checked call to drift apart, which
///         is precisely the failure mode that would make a benchmark
///         report a number for an operation nothing verifies.
abstract contract StepVMRootProbeHarness is CrossCheckFramework {
    /// @notice The corpus these probes live in.
    string internal constant STEP_VM_FIXTURE = "step_vm.json";

    /* ---------------------------------------------------------- */
    /* The multiproof column                                      */
    /* ---------------------------------------------------------- */

    /// @notice The JSON base path of multiproof probe `i`.
    ///
    /// @dev    Twenty probes: the shapes the verifier has to handle,
    ///         including the aliased cell, the failing precondition and
    ///         the state-keyed write.
    function multiProbeBase(uint256 i) internal pure returns (string memory) {
        return string.concat(".multiProofGoldens[", vm.toString(i), "]");
    }

    /// @notice The JSON base path of the multiproof probe named
    ///         `variant`.  Reverts when the corpus does not carry it.
    function findMultiProbeBase(string memory raw, string memory variant)
        internal
        pure
        returns (string memory)
    {
        uint256 n = vm.parseJsonUint(raw, ".multiProofGoldensCount");
        for (uint256 i = 0; i < n; i++) {
            string memory base = multiProbeBase(i);
            if (
                keccak256(bytes(vm.parseJsonString(raw, string.concat(base, ".variant"))))
                    == keccak256(bytes(variant))
            ) {
                return base;
            }
        }
        revert(string.concat("multiproof probe not in the corpus: ", variant));
    }

    /// @notice The frontier: each opened cell's identity and PRE-value,
    ///         and NOT its post-value, which the verifier must derive.
    function loadOpenedCells(string memory raw, string memory base)
        internal
        pure
        returns (KnomosisStepVMRoot.OpenedCell[] memory cells)
    {
        uint256 n = vm.parseJsonUint(raw, string.concat(base, ".cellCount"));
        cells = new KnomosisStepVMRoot.OpenedCell[](n);
        for (uint256 i = 0; i < n; i++) {
            string memory c = string.concat(base, ".cells[", vm.toString(i), "]");
            cells[i] = KnomosisStepVMRoot.OpenedCell({
                cellKind: uint8(vm.parseJsonUint(raw, string.concat(c, ".cellKind"))),
                keyA: vm.parseJsonUint(raw, string.concat(c, ".keyA")),
                keyB: vm.parseJsonUint(raw, string.concat(c, ".keyB")),
                preValue: vm.parseJsonBytes(raw, string.concat(c, ".preValueHex"))
            });
        }
    }

    /// @notice The canonical `executeStepToRootMulti` calldata for a
    ///         probe, with caller-supplied cells and wire so a negative
    ///         control can perturb either.
    function encodeMultiProbeCall(
        string memory raw,
        string memory base,
        KnomosisStepVMRoot.OpenedCell[] memory cells,
        bytes memory gapMask,
        bytes memory siblings
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            KnomosisStepVMRoot.executeStepToRootMulti,
            (
                probePreRoot(raw, base),
                uint8(vm.parseJsonUint(raw, string.concat(base, ".actionKindByte"))),
                vm.parseJsonBytes(raw, string.concat(base, ".actionFieldsHex")),
                uint64(vm.parseJsonUint(raw, string.concat(base, ".signerNat"))),
                vm.parseJsonUint(raw, string.concat(base, ".l2LogIndex")),
                cells,
                gapMask,
                siblings
            )
        );
    }

    /// @notice The probe's published gap mask.
    function probeGapMask(string memory raw, string memory base)
        internal
        pure
        returns (bytes memory)
    {
        return vm.parseJsonBytes(raw, string.concat(base, ".gapMaskHex"));
    }

    /// @notice The probe's published sibling region.
    function probeSiblings(string memory raw, string memory base)
        internal
        pure
        returns (bytes memory)
    {
        return vm.parseJsonBytes(raw, string.concat(base, ".siblingsHex"));
    }

    /// @notice The probe's published pre-state root.
    function probePreRoot(string memory raw, string memory base)
        internal
        pure
        returns (bytes32)
    {
        return vm.parseJsonBytes32(raw, string.concat(base, ".preStateRootHex"));
    }

    /// @notice The probe's published post-state root — the root the
    ///         verifier must reach.
    function probePostRoot(string memory raw, string memory base)
        internal
        pure
        returns (bytes32)
    {
        return vm.parseJsonBytes32(raw, string.concat(base, ".postStateRootHex"));
    }
}
