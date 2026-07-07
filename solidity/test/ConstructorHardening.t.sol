// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {KnomosisIdentityRegistry} from "src/contracts/KnomosisIdentityRegistry.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisDisputeVerifier} from "src/contracts/KnomosisDisputeVerifier.sol";
import {KnomosisSequencerStake} from "src/contracts/KnomosisSequencerStake.sol";
import {KnomosisAmmDisasterRecoveryMultisig} from
    "src/contracts/KnomosisAmmDisasterRecoveryMultisig.sol";
import {KnomosisStateRootSubmission} from "src/contracts/KnomosisStateRootSubmission.sol";
import {KnomosisDisputeVerifierV2} from "src/contracts/KnomosisDisputeVerifierV2.sol";
import {KnomosisFaultProofGame} from "src/contracts/KnomosisFaultProofGame.sol";
import {KnomosisFaultProofMigration} from "src/contracts/KnomosisFaultProofMigration.sol";

/// @title ConstructorHardeningTest
/// @notice Negative-path coverage for the constructor-input hardening added
///         across the L1 contract suite: every new zero / range / distinctness
///         / backward-reference-code guard must actually FIRE.  The happy path
///         (all guards passing) is exercised end-to-end by
///         `script/DeploySepolia.s.sol` + the per-contract suites; these tests
///         assert the guards reject the misconfiguration they were added for.
contract ConstructorHardeningTest is Test {
    address internal constant BURN = address(0xdEaD);

    /// @dev Place minimal (1-byte) runtime code at `a` so `a.code.length > 0`.
    function _code(address a) internal returns (address) {
        vm.etch(a, hex"00");
        return a;
    }

    // ---- KnomosisIdentityRegistry: ZeroVersionTag -----------------------

    function test_registry_rejects_zero_version_tag() public {
        vm.expectRevert(KnomosisIdentityRegistry.ZeroVersionTag.selector);
        new KnomosisIdentityRegistry(bytes32(0));
    }

    // ---- KnomosisBridge: ZeroDisputeWindow / ZeroMaxAttestationStaleBlocks

    function _validEthArgs() internal pure returns (KnomosisBridge.ConstructorArgs memory) {
        return KnomosisBridge.ConstructorArgs({
            knomosisVersionTag: keccak256("hardening-test"),
            attestor: address(0xA11CE),
            disputeVerifier: address(0xDE),
            sequencerStake: address(0x5E),
            migration: address(0),
            disputeWindowBlocks: 100,
            maxRedemptionWindowBlocks: 50,
            maxAttestationStaleBlocks: 200,
            cooldownBlocks: 50,
            tvlCap: type(uint256).max,
            minFeeBps: 0,
            maxFeeBps: 5000,
            weiPerBudgetUnitEth: 1,
            weiPerBudgetUnitBold: 0,
            boldTokenAddress: address(0),
            boldTvlCap: 0,
            boldCircuitBreaker: address(0),
            boldAdmin: address(0),
            enableLiquityAutoCircuitTrigger: false,
            ammSeedRatioBps: 0,
            ammDisasterRecovery: address(0),
            erc20ResourceIds: new uint64[](0),
            erc20TokenAddrs: new address[](0)
        });
    }

    function test_bridge_valid_eth_only_constructs() public {
        // Sanity: the baseline ETH-only config is valid (so the negatives
        // below isolate exactly the field under test).
        KnomosisBridge b = new KnomosisBridge(_validEthArgs());
        assertFalse(b.boldEnabled(), "ETH-only");
    }

    function test_bridge_rejects_zero_dispute_window() public {
        KnomosisBridge.ConstructorArgs memory a = _validEthArgs();
        a.disputeWindowBlocks = 0;
        a.maxRedemptionWindowBlocks = 0; // keep disputeWindow >= maxRedemption
        vm.expectRevert(KnomosisBridge.ZeroDisputeWindow.selector);
        new KnomosisBridge(a);
    }

    function test_bridge_rejects_zero_attestation_stale_window() public {
        KnomosisBridge.ConstructorArgs memory a = _validEthArgs();
        a.maxAttestationStaleBlocks = 0;
        vm.expectRevert(KnomosisBridge.ZeroMaxAttestationStaleBlocks.selector);
        new KnomosisBridge(a);
    }

    // ---- KnomosisDisputeVerifier: backward-ref code checks --------------

    function _verifierArgs(address bridge, address registry)
        internal
        pure
        returns (KnomosisDisputeVerifier.ConstructorArgs memory a)
    {
        address[] memory adj = new address[](1);
        adj[0] = address(0xAD1);
        a = KnomosisDisputeVerifier.ConstructorArgs({
            knomosisVersionTag: keccak256("hardening-test"),
            bridge: bridge,
            sequencerStake: address(0x5E),
            identityRegistry: registry,
            migration: address(0),
            quorumThreshold: 1,
            approvedAdjudicators: adj
        });
    }

    function test_verifier_rejects_codeless_bridge() public {
        // Codeless bridge EOA -> BridgeNotContract (checked before registry).
        vm.expectRevert(KnomosisDisputeVerifier.BridgeNotContract.selector);
        new KnomosisDisputeVerifier(_verifierArgs(address(0xB0), _code(address(0xE1))));
    }

    function test_verifier_rejects_codeless_registry() public {
        // Code-bearing bridge, codeless registry EOA -> IdentityRegistryNotContract.
        vm.expectRevert(KnomosisDisputeVerifier.IdentityRegistryNotContract.selector);
        new KnomosisDisputeVerifier(_verifierArgs(_code(address(0xB1)), address(0xE0)));
    }

    // ---- KnomosisSequencerStake: backward-ref code check ---------------

    function test_stake_rejects_codeless_verifier() public {
        // Codeless verifier EOA -> NotAContract (checked after the zero-checks).
        vm.expectRevert(KnomosisSequencerStake.NotAContract.selector);
        new KnomosisSequencerStake(
            keccak256("hardening-test"),
            address(0x5E9),          // sequencer (EOA, fine)
            address(0xDEAD),         // disputeVerifier: codeless EOA
            _code(address(0xB2)),    // bridge: code-bearing
            5000,
            100,
            BURN
        );
    }

    // ---- KnomosisAmmDisasterRecoveryMultisig: BridgeHasNoCode -----------

    function test_multisig_rejects_codeless_bridge() public {
        address[] memory s = new address[](3);
        s[0] = address(0xD1);
        s[1] = address(0xD2);
        s[2] = address(0xD3);
        vm.expectRevert(KnomosisAmmDisasterRecoveryMultisig.BridgeHasNoCode.selector);
        new KnomosisAmmDisasterRecoveryMultisig(address(0xB0B), s, 3); // codeless bridge
    }

    // ---- KnomosisStateRootSubmission: SequencerIsFaultProofGame ---------

    function test_state_root_rejects_sequencer_equals_game() public {
        address same = address(0x5A3E);
        vm.expectRevert(KnomosisStateRootSubmission.SequencerIsFaultProofGame.selector);
        new KnomosisStateRootSubmission(
            1 ether, 216_000, 100, 100, same, same, keccak256("dep"), 216_000
        );
    }

    // ---- KnomosisDisputeVerifierV2: zero sequencerStake / attestor ------

    function _v2(address seqStake, address attestor) internal {
        address[] memory adj = new address[](1);
        adj[0] = address(0xAD1);
        new KnomosisDisputeVerifierV2(
            address(0x6A),   // faultProofGame (non-zero; forward ref, no code-check)
            address(0x5B),   // stateRootSubmission
            adj,
            1,               // quorum
            address(0xB1),   // bridge
            seqStake,
            attestor,
            keccak256("dep")
        );
    }

    function test_v2_rejects_zero_sequencer_stake() public {
        vm.expectRevert(KnomosisDisputeVerifierV2.ZeroAddress.selector);
        _v2(address(0), address(0xA77E5));
    }

    function test_v2_rejects_zero_attestor() public {
        vm.expectRevert(KnomosisDisputeVerifierV2.ZeroAddress.selector);
        _v2(address(0x5B), address(0));
    }

    // ---- KnomosisFaultProofGame: InvalidBondConfig ---------------------

    function test_game_rejects_zero_challenge_bond() public {
        // stepVM + submission must be code-bearing (their code-checks precede
        // the bond check); the timeout must exceed the step interval.
        address stepVM = _code(address(0x57E9)); // stepVM (code-bearing)
        address submission = _code(address(0x5AB)); // stateRootSubmission (code-bearing)
        vm.expectRevert(KnomosisFaultProofGame.InvalidBondConfig.selector);
        new KnomosisFaultProofGame(
            100,             // bisectionResponseTimeout
            0,               // minChallengeBond == 0 -> InvalidBondConfig
            5,               // minBisectionStepInterval
            address(0x7EA5), // treasury
            stepVM,
            submission
        );
    }

    // ---- KnomosisFaultProofMigration: ZeroDeploymentId -----------------

    function test_fault_proof_migration_rejects_zero_deployment_id() public {
        // Distinct non-zero predecessor/successor; the ZeroDeploymentId guard
        // fires before the successor-code / predecessor-consent checks.
        vm.expectRevert(KnomosisFaultProofMigration.ZeroDeploymentId.selector);
        new KnomosisFaultProofMigration(
            216_000, address(0x1), address(0x2), keccak256("h"), 1, bytes32(0)
        );
    }
}
