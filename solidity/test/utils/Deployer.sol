// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {CanonBridge} from "src/contracts/CanonBridge.sol";
import {CanonDisputeVerifier} from "src/contracts/CanonDisputeVerifier.sol";
import {CanonSequencerStake} from "src/contracts/CanonSequencerStake.sol";
import {CanonIdentityRegistry} from "src/contracts/CanonIdentityRegistry.sol";
import {CREATE3} from "src/lib/CREATE3.sol";

/// @title Deployer
/// @notice Deploys the four core Knomosis contracts in the right
///         order using `CREATE3` to break the
///         bridge ↔ verifier ↔ stake reference cycle.
///
/// @dev    Each child's address is predicted from
///         `(deployer, salt)` alone (independent of init-code),
///         so we can bake the predictions into each child's
///         `immutable` constructor arguments before deploying.
///         The actual deployed addresses match the predictions
///         byte-for-byte.
///
///         This pattern is the canonical solution for deploying
///         contracts with `immutable` cross-references.  Mainnet
///         deployment scripts (workstream F.3 testnet acceptance
///         + the production deployment kit) follow the same
///         flow.
contract Deployer {
    bytes32 internal constant SALT_BRIDGE = keccak256("knomosis-bridge-salt");
    bytes32 internal constant SALT_VERIFIER = keccak256("knomosis-dispute-verifier-salt");
    bytes32 internal constant SALT_STAKE = keccak256("knomosis-sequencer-stake-salt");
    bytes32 internal constant VERSION_TAG = keccak256("knomosis-test-v1");
    address internal constant BURN_ADDRESS = address(0xdEaD);

    struct Deployment {
        CanonBridge bridge;
        CanonDisputeVerifier verifier;
        CanonSequencerStake stake;
        CanonIdentityRegistry registry;
    }

    function deployAll(
        address attestor,
        address sequencer,
        address[] memory adjudicators,
        uint8 quorumThreshold,
        uint64 disputeWindowBlocks,
        uint64 maxRedemptionWindowBlocks,
        uint64 maxAttestationStaleBlocks,
        uint64 cooldownBlocks,
        uint256 tvlCap,
        uint256 slashRatioBps,
        uint64[] memory erc20ResourceIds,
        address[] memory erc20TokenAddrs
    ) external returns (Deployment memory d) {
        // Step 0: deploy the registry — no cross-references.
        d.registry = new CanonIdentityRegistry(VERSION_TAG);

        // Step 1: predict CREATE3 addresses for the cycle.
        address bridgeAddr = CREATE3.addressOf(address(this), SALT_BRIDGE);
        address verifierAddr = CREATE3.addressOf(address(this), SALT_VERIFIER);
        address stakeAddr = CREATE3.addressOf(address(this), SALT_STAKE);

        // Step 2: assemble each contract's init-code with the
        // predicted addresses baked in.  Because CREATE3 is
        // init-code-independent, each contract's init-code can
        // freely reference the other contracts' predicted
        // addresses without affecting its own deployed address.
        bytes memory bridgeInit = abi.encodePacked(
            type(CanonBridge).creationCode,
            abi.encode(
                CanonBridge.ConstructorArgs({
                    canonVersionTag: VERSION_TAG,
                    attestor: attestor,
                    disputeVerifier: verifierAddr,
                    sequencerStake: stakeAddr,
                    migration: address(0),
                    disputeWindowBlocks: disputeWindowBlocks,
                    maxRedemptionWindowBlocks: maxRedemptionWindowBlocks,
                    maxAttestationStaleBlocks: maxAttestationStaleBlocks,
                    cooldownBlocks: cooldownBlocks,
                    tvlCap: tvlCap,
                    erc20ResourceIds: erc20ResourceIds,
                    erc20TokenAddrs: erc20TokenAddrs
                })
            )
        );
        bytes memory verifierInit = abi.encodePacked(
            type(CanonDisputeVerifier).creationCode,
            abi.encode(
                CanonDisputeVerifier.ConstructorArgs({
                    canonVersionTag: VERSION_TAG,
                    bridge: bridgeAddr,
                    sequencerStake: stakeAddr,
                    identityRegistry: address(d.registry),
                    migration: address(0),
                    quorumThreshold: quorumThreshold,
                    approvedAdjudicators: adjudicators
                })
            )
        );
        bytes memory stakeInit = abi.encodePacked(
            type(CanonSequencerStake).creationCode,
            abi.encode(
                VERSION_TAG,
                sequencer,
                verifierAddr,
                bridgeAddr,
                slashRatioBps,
                disputeWindowBlocks,
                BURN_ADDRESS
            )
        );

        // Step 3: deploy via CREATE3.  Order is irrelevant to
        // address derivation, but we deploy the bridge first so
        // its `disputeVerifier` and `sequencerStake` immutables
        // are fully wired before V/S start reading from it.
        address deployedBridge = CREATE3.deploy(SALT_BRIDGE, bridgeInit);
        require(deployedBridge == bridgeAddr, "bridge predict mismatch");
        d.bridge = CanonBridge(payable(deployedBridge));

        address deployedVerifier = CREATE3.deploy(SALT_VERIFIER, verifierInit);
        require(deployedVerifier == verifierAddr, "verifier predict mismatch");
        d.verifier = CanonDisputeVerifier(deployedVerifier);

        address deployedStake = CREATE3.deploy(SALT_STAKE, stakeInit);
        require(deployedStake == stakeAddr, "stake predict mismatch");
        d.stake = CanonSequencerStake(payable(deployedStake));
    }
}
