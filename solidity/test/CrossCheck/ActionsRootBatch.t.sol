// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.36;

import {ActionsRoot} from "src/lib/ActionsRoot.sol";
import {LogChain} from "src/lib/LogChain.sol";
import {CrossCheckFramework} from "./Framework.t.sol";

/// @title ActionsRootBatchProxy
/// @notice External wrapper so the calldata-typed library surfaces
///         take real calldata in the tests.
contract ActionsRootBatchProxy {
    function actionLeafCommit(
        uint8 actionKind,
        uint64 signer,
        bytes calldata actionFields,
        bytes calldata actionSig
    ) external pure returns (bytes32) {
        return ActionsRoot.actionLeafCommit(
            actionKind, signer, actionFields, actionSig);
    }

    function verifyActionInclusion(
        bytes32 root,
        uint64 n,
        bytes32 commit,
        bytes calldata proofData
    ) external pure returns (bool) {
        return ActionsRoot.verifyActionInclusion(root, n, commit, proofData);
    }
}

/// @title ActionsRootBatchCrossCheck
/// @notice Pins `ActionsRoot` (Workstream SB) against the two
///         Lean-authored batching corpora:
///
///           * `actions_root.json` — per batch entry, the L1
///             re-derives the SMT key from the absolute log index and
///             the signature-bound leaf commit from the published raw
///             fields, then walks the inclusion proof to the batch
///             root; the negative rows (a forged commit, a wrong
///             index) must refuse.
///           * `batch_chain.json` — the genesis seed and the running
///             `nextEntryHash` fold, so the chain recurrence the
///             batching registry stores is byte-pinned against Lean's
///             `l1NextEntryHash` for the first time.
///
/// @dev    Both corpora hash with the kernel's `hashBytes`, so both
///         suites gate on `isKeccak256Linked` — a fallback-hash
///         corpus pins bytes no L1 reproduces, and the gate FAILS
///         (never skips) on one.
contract ActionsRootBatchCrossCheck is CrossCheckFramework {
    string internal constant FIXTURE = "actions_root.json";
    string internal constant CHAIN_FIXTURE = "batch_chain.json";

    ActionsRootBatchProxy internal proxy;

    function setUp() public {
        proxy = new ActionsRootBatchProxy();
    }

    /* ---------------------------------------------------------- */
    /* actions_root.json                                          */
    /* ---------------------------------------------------------- */

    /// @notice Every entry: the re-derived key matches, the
    ///         re-derived leaf commit matches, and the inclusion
    ///         proof verifies against the batch root.
    function test_every_batch_entry_verifies_by_inclusion() public {
        if (!fixtureExists(FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE);
        _requireIdentifier(raw, ".identifier", "knomosis/actions-root/v1");
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        uint256 nBatches = vm.parseJsonUint(raw, ".count");
        assertGt(nBatches, 0, "empty corpus");
        for (uint256 b = 0; b < nBatches; b++) {
            string memory bb = string.concat(".batches[", vm.toString(b), "]");
            bytes32 root =
                vm.parseJsonBytes32(raw, string.concat(bb, ".actionsRootHex"));
            uint256 n = vm.parseJsonUint(raw, string.concat(bb, ".count"));
            for (uint256 i = 0; i < n; i++) {
                string memory e =
                    string.concat(bb, ".entries[", vm.toString(i), "]");
                beginEntry(e);
                uint64 idx = uint64(
                    vm.parseJsonUint(raw, string.concat(e, ".absoluteIndex")));
                // The key is DERIVED from the index, never read from
                // the wire; the corpus column pins the derivation.
                checkEq(
                    ActionsRoot.actionKey(idx),
                    vm.parseJsonBytes32(raw, string.concat(e, ".actionKeyHex")),
                    "re-derived action key"
                );
                bytes32 commit = proxy.actionLeafCommit(
                    uint8(vm.parseJsonUint(
                        raw, string.concat(e, ".actionKindByte"))),
                    uint64(vm.parseJsonUint(raw, string.concat(e, ".signerNat"))),
                    vm.parseJsonBytes(raw, string.concat(e, ".actionFieldsHex")),
                    vm.parseJsonBytes(raw, string.concat(e, ".sigHex"))
                );
                checkEq(
                    commit,
                    vm.parseJsonBytes32(
                        raw, string.concat(e, ".expectedActionLeafHex")),
                    "re-derived signature-bound leaf commit"
                );
                checkTrue(
                    proxy.verifyActionInclusion(
                        root, idx, commit,
                        vm.parseJsonBytes(raw, string.concat(e, ".proofDataHex"))),
                    "inclusion proof must verify"
                );
            }
        }
    }

    /// @notice The negative rows refuse: a forged commit under the
    ///         honest proof, and an honest `(commit, proof)` replayed
    ///         at the wrong index.
    function test_negative_rows_refuse() public {
        if (!fixtureExists(FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(FIXTURE);
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        for (uint256 i = 0; i < 2; i++) {
            string memory e = string.concat(".negatives[", vm.toString(i), "]");
            beginEntry(vm.parseJsonString(raw, string.concat(e, ".category")));
            checkFalse(
                proxy.verifyActionInclusion(
                    vm.parseJsonBytes32(raw, string.concat(e, ".actionsRootHex")),
                    uint64(vm.parseJsonUint(
                        raw, string.concat(e, ".absoluteIndex"))),
                    vm.parseJsonBytes32(raw, string.concat(e, ".commitHex")),
                    vm.parseJsonBytes(raw, string.concat(e, ".proofDataHex"))),
                "negative row must refuse"
            );
        }
    }

    /// @notice The leaf commit REVERTS on any signature width but the
    ///         fixed 65 bytes — the pre-image split's injectivity
    ///         hinges on that width, so it is enforced, not assumed.
    function test_leaf_commit_rejects_non_65_byte_sig() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ActionsRoot.ActionSigWrongLength.selector, uint256(64)));
        proxy.actionLeafCommit(0, 7, hex"", new bytes(64));
    }

    /* ---------------------------------------------------------- */
    /* batch_chain.json                                           */
    /* ---------------------------------------------------------- */

    /// @notice The genesis seed and every running chain value match
    ///         the L1 recurrence — `genesisChainSeed` first, then one
    ///         `LogChain.nextEntryHash` per batch.
    function test_batch_chain_fold_matches_lean() public {
        if (!fixtureExists(CHAIN_FIXTURE)) {
            _skipWithReason("fixture missing");
            return;
        }
        string memory raw = readFixture(CHAIN_FIXTURE);
        _requireIdentifier(raw, ".identifier", "knomosis/batch-chain/v1");
        _requireKeccakLinked(raw, ".isKeccak256Linked");
        bytes32 gsc =
            vm.parseJsonBytes32(raw, ".genesisStateCommitHex");
        bytes32 seed = ActionsRoot.genesisChainSeed(gsc);
        assertEq(
            seed,
            vm.parseJsonBytes32(raw, ".genesisSeedHex"),
            "genesis chain seed"
        );
        uint256 n = vm.parseJsonUint(raw, ".count");
        assertGt(n, 0, "empty chain corpus");
        bytes32 acc = seed;
        for (uint256 i = 0; i < n; i++) {
            string memory s = string.concat(".steps[", vm.toString(i), "]");
            beginEntry(s);
            acc = LogChain.nextEntryHash(
                acc,
                vm.parseJsonBytes32(raw, string.concat(s, ".stateCommitHex")),
                vm.parseJsonBytes32(raw, string.concat(s, ".actionsRootHex"))
            );
            checkEq(
                acc,
                vm.parseJsonBytes32(
                    raw, string.concat(s, ".expectedNextEntryHashHex")),
                "running chain value"
            );
        }
    }
}
