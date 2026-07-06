// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {KnomosisIdentityRegistry} from "src/contracts/KnomosisIdentityRegistry.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {KnomosisDisputeVerifier} from "src/contracts/KnomosisDisputeVerifier.sol";
import {KnomosisSequencerStake} from "src/contracts/KnomosisSequencerStake.sol";
import {KnomosisAmmDisasterRecoveryMultisig} from
    "src/contracts/KnomosisAmmDisasterRecoveryMultisig.sol";
import {KnomosisStepVM} from "src/contracts/KnomosisStepVM.sol";
import {KnomosisStateRootSubmission} from "src/contracts/KnomosisStateRootSubmission.sol";
import {KnomosisDisputeVerifierV2} from "src/contracts/KnomosisDisputeVerifierV2.sol";
import {KnomosisFaultProofGame} from "src/contracts/KnomosisFaultProofGame.sol";

/// @title DeploySepolia
/// @notice Unified, production-shaped deployment of the FULL Knomosis L1
///         contract suite to a public testnet (Sepolia, chainid 11155111) or
///         mainnet.  Unlike the F.3 `TestnetAcceptance.s.sol` (which uses the
///         `test/utils/Deployer` CREATE3 *bundler* — a 42 KB harness that
///         exceeds EIP-170 and needs `--disable-code-size-limit`), this
///         script deploys every contract as its OWN transaction via
///         plain-nonce CREATE prediction, so it works against a real RPC with
///         no code-size accommodation (every production contract is under the
///         24 576-byte cap — the largest, `KnomosisBridge`, is 17 195 B).
///
///         It emits a machine-readable JSON manifest
///         (`deployments/<network>.json`) that the L2 daemon stack
///         (`knomosis-l1-ingest`, `knomosis-faultproof-observer`), the
///         gateway, and the Licio client consume — closing the
///         `docs/testnet_readiness.md` §3 "no addresses manifest" gap.
///
///         Run (dry-run / in-memory simulation, writes the manifest with the
///         simulated addresses):
///         ```bash
///         forge script script/DeploySepolia.s.sol
///         ```
///         Real Sepolia broadcast + Etherscan source-verification:
///         ```bash
///         SEPOLIA_RPC_URL=... ETHERSCAN_API_KEY=... \
///         KNOMOSIS_ATTESTOR=0x... KNOMOSIS_SEQUENCER=0x... KNOMOSIS_TREASURY=0x... \
///         forge script script/DeploySepolia.s.sol \
///             --rpc-url sepolia --broadcast --verify --slow \
///             --private-key $PRIVATE_KEY
///         ```
///
///         See `docs/sepolia_deployment_runbook.md` for the full operator
///         procedure and `docs/deployment_parameters.md` for parameter sizing.
///
/// @dev    Deploy order (LOAD-BEARING — plain-nonce CREATE prediction binds
///         each address to a specific broadcaster nonce; nothing may deploy
///         between a prediction and the matching `new`):
///           Cluster A (bridge core; a 3-way immutable cycle broken by
///           prediction): IdentityRegistry, Bridge, DisputeVerifier(v1),
///           SequencerStake, [AmmDisasterRecoveryMultisig only when a
///           FUNCTIONAL AMM is configured]; then `assertConsistent()`.
///           Cluster B (fault-proof stack): StepVM, StateRootSubmission,
///           DisputeVerifierV2, FaultProofGame (game LAST — its constructor
///           requires `stateRootSubmission.code > 0 && stepVM.code > 0`);
///           then `assertConsistent()`.
///         The recovery contracts (`KnomosisMigration`,
///         `KnomosisFaultProofMigration`) are NOT genesis contracts —
///         `bridge.migration()` is `address(0)` at v1 genesis.
contract DeploySepolia is Script {
    /// @notice Burn sink for the slash-burn remainder (mirrors the F.3
    ///         `TestnetAcceptance` / `Deployer` convention).
    address internal constant BURN_ADDRESS = address(0xdEaD);

    // ---- Dry-run placeholder actors (NEVER used on a real broadcast: the
    //      operator supplies real addresses via env; these only let a bare
    //      `forge script` in-memory simulation run with zero env). ----
    address internal constant PLACEHOLDER_ATTESTOR = address(0xA11A5);
    address internal constant PLACEHOLDER_SEQUENCER = address(0x5E9);
    address internal constant PLACEHOLDER_TREASURY = address(0x7EA5);
    address internal constant PLACEHOLDER_ADJUDICATOR = address(0xAD30);
    address internal constant PLACEHOLDER_BOLD_BREAKER = address(0xB12E6);
    address internal constant PLACEHOLDER_BOLD_ADMIN = address(0xAD814);
    address internal constant PLACEHOLDER_MULTISIG_SIGNER = address(0xD801);

    /// @notice Every deployment-shaping parameter, resolved from the
    ///         environment (or a testnet-sane default) by `_readConfig`.
    struct DeployConfig {
        bytes32 versionTag;
        // Cluster-A actors.
        address attestor;
        address sequencer;
        address treasury;
        address[] adjudicators;
        uint8 quorum;
        // Bridge windows + economics.
        uint64 disputeWindowBlocks;
        uint64 maxRedemptionWindowBlocks;
        uint64 maxAttestationStaleBlocks;
        uint64 cooldownBlocks;
        uint256 tvlCap;
        uint16 minFeeBps;
        uint16 maxFeeBps;
        uint64 weiPerBudgetUnitEth;
        // BOLD + AMM.  `boldToken == address(0)` opts OUT of BOLD (ETH-only).
        address boldToken;
        uint64 weiPerBudgetUnitBold;
        uint256 boldTvlCap;
        address boldCircuitBreaker;
        address boldAdmin;
        bool enableLiquityAutoTrigger;
        uint16 ammSeedRatioBps;
        address[] ammMultisigSigners;
        uint256 ammMultisigThreshold;
        // Sequencer stake.
        uint256 slashRatioBps;
        // Cluster-B fault-proof params.
        uint128 stateRootBond;
        uint64 srDisputeWindow;
        uint64 minSubmissionInterval;
        uint64 maxOutstandingRoots;
        uint64 withdrawalFinalisationWindow;
        uint64 bisectionResponseTimeout;
        uint128 minChallengeBond;
        uint64 minBisectionStepInterval;
        // Manifest output path.
        string outPath;
        string network;
    }

    /// @notice The deployed contract addresses + derived identifiers.
    struct Deployed {
        address registry;
        address bridge;
        address disputeVerifier;
        address sequencerStake;
        address ammMultisig; // address(0) when no functional AMM
        address stepVM;
        address stateRootSubmission;
        address disputeVerifierV2;
        address faultProofGame;
        bytes32 deploymentId;
        bool boldEnabled;
    }

    /// @notice Entry point: read config from the environment and deploy.
    function run() external virtual {
        _deployAll(_readConfig());
    }

    // ------------------------------------------------------------------
    // Config
    // ------------------------------------------------------------------

    /// @notice Resolve the full deployment config from the environment.
    ///         Every value has a testnet-sane default via `vm.envOr`, so a
    ///         bare `forge script` in-memory simulation runs with zero env;
    ///         a real broadcast supplies the production actor addresses.
    function _readConfig() internal view returns (DeployConfig memory cfg) {
        cfg.versionTag = vm.envOr("KNOMOSIS_VERSION_TAG", keccak256("knomosis-sepolia-v1"));

        cfg.attestor = vm.envOr("KNOMOSIS_ATTESTOR", PLACEHOLDER_ATTESTOR);
        cfg.sequencer = vm.envOr("KNOMOSIS_SEQUENCER", PLACEHOLDER_SEQUENCER);
        cfg.treasury = vm.envOr("KNOMOSIS_TREASURY", PLACEHOLDER_TREASURY);

        address adjBase = vm.envOr("KNOMOSIS_ADJUDICATOR", PLACEHOLDER_ADJUDICATOR);
        uint256 adjCount = vm.envOr("KNOMOSIS_ADJUDICATOR_COUNT", uint256(3));
        uint256 adjQuorum = vm.envOr("KNOMOSIS_ADJUDICATOR_QUORUM", adjCount);
        // Validate BEFORE the uint8 narrowing so a mis-sized value fails fast
        // with a clear message instead of silently truncating mod 256 (e.g.
        // count/quorum 256 -> 0, which would revert QuorumThresholdOutOfRange
        // and brick the deploy, or 260 -> a weaker-than-intended 4-of-N quorum).
        require(adjCount >= 1 && adjCount <= 255, "adjudicator count must be 1..255");
        require(adjQuorum >= 1 && adjQuorum <= adjCount, "adjudicator quorum out of range");
        // `adjQuorum <= adjCount <= 255` is enforced above, so the uint8
        // narrowing cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        cfg.quorum = uint8(adjQuorum);
        cfg.adjudicators = _deriveSet(adjBase, adjCount);

        cfg.disputeWindowBlocks = uint64(vm.envOr("KNOMOSIS_DISPUTE_WINDOW", uint256(50_400)));
        cfg.maxRedemptionWindowBlocks = uint64(vm.envOr("KNOMOSIS_MAX_REDEMPTION", uint256(36_000)));
        cfg.maxAttestationStaleBlocks = uint64(vm.envOr("KNOMOSIS_ATTEST_STALE", uint256(7_200)));
        cfg.cooldownBlocks = uint64(vm.envOr("KNOMOSIS_COOLDOWN", uint256(7_200)));
        cfg.tvlCap = vm.envOr("KNOMOSIS_TVL_CAP", uint256(100_000 ether));
        cfg.minFeeBps = uint16(vm.envOr("KNOMOSIS_MIN_FEE_BPS", uint256(0)));
        cfg.maxFeeBps = uint16(vm.envOr("KNOMOSIS_MAX_FEE_BPS", uint256(5_000)));
        cfg.weiPerBudgetUnitEth =
            uint64(vm.envOr("KNOMOSIS_WEI_PER_BUDGET_UNIT_ETH", uint256(1_000_000_000)));

        // BOLD + AMM.  Unset KNOMOSIS_BOLD_TOKEN => ETH-only (address(0)).
        cfg.boldToken = vm.envOr("KNOMOSIS_BOLD_TOKEN", address(0));
        cfg.weiPerBudgetUnitBold =
            uint64(vm.envOr("KNOMOSIS_WEI_PER_BUDGET_UNIT_BOLD", uint256(1_000_000_000)));
        cfg.boldTvlCap = vm.envOr("KNOMOSIS_BOLD_TVL_CAP", cfg.tvlCap);
        cfg.boldCircuitBreaker =
            vm.envOr("KNOMOSIS_BOLD_CIRCUIT_BREAKER", PLACEHOLDER_BOLD_BREAKER);
        cfg.boldAdmin = vm.envOr("KNOMOSIS_BOLD_ADMIN", PLACEHOLDER_BOLD_ADMIN);
        cfg.enableLiquityAutoTrigger = vm.envOr("KNOMOSIS_ENABLE_LIQUITY_AUTOTRIGGER", false);
        cfg.ammSeedRatioBps = uint16(vm.envOr("KNOMOSIS_AMM_SEED_RATIO_BPS", uint256(0)));

        address sigBase = vm.envOr("KNOMOSIS_AMM_MULTISIG_SIGNER", PLACEHOLDER_MULTISIG_SIGNER);
        uint256 sigCount = vm.envOr("KNOMOSIS_AMM_MULTISIG_COUNT", uint256(5));
        cfg.ammMultisigThreshold = vm.envOr("KNOMOSIS_AMM_MULTISIG_THRESHOLD", uint256(3));
        cfg.ammMultisigSigners = _deriveSet(sigBase, sigCount);

        cfg.slashRatioBps = vm.envOr("KNOMOSIS_SLASH_BPS", uint256(5_000));

        cfg.stateRootBond = uint128(vm.envOr("KNOMOSIS_STATE_ROOT_BOND", uint256(1 ether)));
        cfg.srDisputeWindow =
            uint64(vm.envOr("KNOMOSIS_STATE_ROOT_DISPUTE_WINDOW", uint256(216_000)));
        cfg.minSubmissionInterval =
            uint64(vm.envOr("KNOMOSIS_MIN_SUBMISSION_INTERVAL", uint256(100)));
        cfg.maxOutstandingRoots =
            uint64(vm.envOr("KNOMOSIS_MAX_OUTSTANDING_ROOTS", uint256(100)));
        cfg.withdrawalFinalisationWindow =
            uint64(vm.envOr("KNOMOSIS_WITHDRAWAL_WINDOW_BLOCKS", uint256(216_000)));
        cfg.bisectionResponseTimeout =
            uint64(vm.envOr("KNOMOSIS_BISECTION_TIMEOUT_BLOCKS", uint256(21_600)));
        cfg.minChallengeBond =
            uint128(vm.envOr("KNOMOSIS_MIN_CHALLENGE_BOND", uint256(0.05 ether)));
        cfg.minBisectionStepInterval =
            uint64(vm.envOr("KNOMOSIS_MIN_BISECTION_STEP_INTERVAL", uint256(5)));

        cfg.network = _networkName(block.chainid);
        cfg.outPath = vm.envOr(
            "KNOMOSIS_MANIFEST_OUT", string.concat("deployments/", cfg.network, ".json")
        );
    }

    /// @notice Derive `count` distinct addresses from a base (base, base+1,
    ///         ...).  Mirrors the F.3 `TestnetAcceptance` adjudicator
    ///         convention; a real deployment sets an explicit, independent set
    ///         per `docs/deployment_parameters.md`.
    function _deriveSet(address base, uint256 count) internal pure returns (address[] memory set) {
        set = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            // `i < count` (a small committee size), so the uint160 narrowing
            // of the loop index can never truncate a meaningful value.
            // forge-lint: disable-next-line(unsafe-typecast)
            set[i] = address(uint160(base) + uint160(i));
        }
    }

    function _networkName(uint256 id) internal pure returns (string memory) {
        if (id == 1) return "mainnet";
        if (id == 11_155_111) return "sepolia";
        if (id == 17_000) return "holesky";
        if (id == 31_337) return "anvil";
        return string.concat("chain-", vm.toString(id));
    }

    // ------------------------------------------------------------------
    // Deploy
    // ------------------------------------------------------------------

    /// @notice Deploy the full suite, verify the post-deploy invariants, and
    ///         emit the manifest.  Shared by `run()` and the local-devnet
    ///         wrapper `DeploySepoliaLocal`.
    function _deployAll(DeployConfig memory cfg) internal returns (Deployed memory d) {
        // A FUNCTIONAL AMM requires BOTH a BOLD leg and a non-zero seed ratio;
        // only then is the disaster-recovery multisig deployed + wired.
        bool functionalAmm = cfg.boldToken != address(0) && cfg.ammSeedRatioBps > 0;

        // The Liquity auto-trigger reads mainnet-pinned TroveManager oracles,
        // which do not exist off-mainnet; force it OFF anywhere but mainnet so
        // the bridge constructor's `LiquityOracleHasNoCode` guard cannot brick
        // the deploy.
        bool autoTrigger = cfg.enableLiquityAutoTrigger;
        if (autoTrigger && block.chainid != 1) {
            console.log("WARNING: forcing enableLiquityAutoCircuitTrigger OFF (non-mainnet chain)");
            autoTrigger = false;
        }

        address deployer = msg.sender;
        console.log("=== DeploySepolia: start ===");
        console.log("network:", cfg.network);
        console.log("chainId:", block.chainid);
        console.log("deployer:", deployer);
        console.log("BOLD enabled:", cfg.boldToken != address(0));
        console.log("functional AMM:", functionalAmm);

        vm.startBroadcast();

        // ---------------- Cluster A (bridge core) ----------------
        KnomosisIdentityRegistry registry = new KnomosisIdentityRegistry(cfg.versionTag);

        uint64 nA = vm.getNonce(deployer);
        address predB = vm.computeCreateAddress(deployer, nA);
        address predV = vm.computeCreateAddress(deployer, nA + 1);
        address predS = vm.computeCreateAddress(deployer, nA + 2);
        address predM = functionalAmm ? vm.computeCreateAddress(deployer, nA + 3) : address(0);

        KnomosisBridge bridge = new KnomosisBridge(
            KnomosisBridge.ConstructorArgs({
                knomosisVersionTag: cfg.versionTag,
                attestor: cfg.attestor,
                disputeVerifier: predV,
                sequencerStake: predS,
                migration: address(0),
                disputeWindowBlocks: cfg.disputeWindowBlocks,
                maxRedemptionWindowBlocks: cfg.maxRedemptionWindowBlocks,
                maxAttestationStaleBlocks: cfg.maxAttestationStaleBlocks,
                cooldownBlocks: cfg.cooldownBlocks,
                tvlCap: cfg.tvlCap,
                minFeeBps: cfg.minFeeBps,
                maxFeeBps: cfg.maxFeeBps,
                weiPerBudgetUnitEth: cfg.weiPerBudgetUnitEth,
                weiPerBudgetUnitBold: cfg.weiPerBudgetUnitBold,
                boldTokenAddress: cfg.boldToken,
                boldTvlCap: cfg.boldTvlCap,
                boldCircuitBreaker: cfg.boldCircuitBreaker,
                boldAdmin: cfg.boldAdmin,
                enableLiquityAutoCircuitTrigger: autoTrigger,
                ammSeedRatioBps: cfg.ammSeedRatioBps,
                ammDisasterRecovery: predM,
                erc20ResourceIds: new uint64[](0),
                erc20TokenAddrs: new address[](0)
            })
        );
        require(address(bridge) == predB, "bridge prediction mismatch");

        KnomosisDisputeVerifier verifier = new KnomosisDisputeVerifier(
            KnomosisDisputeVerifier.ConstructorArgs({
                knomosisVersionTag: cfg.versionTag,
                bridge: predB,
                sequencerStake: predS,
                identityRegistry: address(registry),
                migration: address(0),
                quorumThreshold: cfg.quorum,
                approvedAdjudicators: cfg.adjudicators
            })
        );
        require(address(verifier) == predV, "verifier prediction mismatch");

        KnomosisSequencerStake stake = new KnomosisSequencerStake(
            cfg.versionTag,
            cfg.sequencer,
            predV,
            predB,
            cfg.slashRatioBps,
            cfg.disputeWindowBlocks,
            BURN_ADDRESS
        );
        require(address(stake) == predS, "stake prediction mismatch");

        address ammMultisig = address(0);
        if (functionalAmm) {
            KnomosisAmmDisasterRecoveryMultisig m = new KnomosisAmmDisasterRecoveryMultisig(
                predB, cfg.ammMultisigSigners, cfg.ammMultisigThreshold
            );
            require(address(m) == predM, "multisig prediction mismatch");
            ammMultisig = address(m);
        }

        // Post-deploy invariants (the bidirectional-reference symmetry the
        // cyclic constructors deliberately defer).
        require(verifier.assertConsistent(), "verifier.assertConsistent failed");
        require(stake.assertConsistent(), "stake.assertConsistent failed");
        require(bridge.migration() == address(0), "bridge.migration must be 0 at genesis");

        bytes32 deploymentId =
            keccak256(abi.encode(block.chainid, address(bridge), cfg.versionTag));
        require(deploymentId == bridge.deploymentId(), "deploymentId mismatch vs bridge");

        // ---------------- Cluster B (fault-proof stack) ----------------
        KnomosisStepVM stepVM = new KnomosisStepVM();

        uint64 nB = vm.getNonce(deployer);
        address predSub = vm.computeCreateAddress(deployer, nB);
        address predV2 = vm.computeCreateAddress(deployer, nB + 1);
        address predGame = vm.computeCreateAddress(deployer, nB + 2);

        KnomosisStateRootSubmission submission = new KnomosisStateRootSubmission(
            cfg.stateRootBond,
            cfg.srDisputeWindow,
            cfg.minSubmissionInterval,
            cfg.maxOutstandingRoots,
            cfg.sequencer,
            predGame,
            deploymentId,
            cfg.withdrawalFinalisationWindow
        );
        require(address(submission) == predSub, "submission prediction mismatch");

        KnomosisDisputeVerifierV2 verifierV2 = new KnomosisDisputeVerifierV2(
            predGame,
            address(submission),
            cfg.adjudicators,
            cfg.quorum,
            address(bridge),
            address(stake),
            cfg.attestor,
            deploymentId
        );
        require(address(verifierV2) == predV2, "verifierV2 prediction mismatch");

        KnomosisFaultProofGame game = new KnomosisFaultProofGame(
            cfg.bisectionResponseTimeout,
            cfg.minChallengeBond,
            cfg.minBisectionStepInterval,
            cfg.treasury,
            address(stepVM),
            address(submission)
        );
        require(address(game) == predGame, "game prediction mismatch");

        // These four revert on inconsistency (they are `view`, return nothing).
        stepVM.assertConsistent();
        submission.assertConsistent();
        verifierV2.assertConsistent();
        game.assertConsistent();

        vm.stopBroadcast();

        d = Deployed({
            registry: address(registry),
            bridge: address(bridge),
            disputeVerifier: address(verifier),
            sequencerStake: address(stake),
            ammMultisig: ammMultisig,
            stepVM: address(stepVM),
            stateRootSubmission: address(submission),
            disputeVerifierV2: address(verifierV2),
            faultProofGame: address(game),
            deploymentId: deploymentId,
            boldEnabled: cfg.boldToken != address(0)
        });

        _logSummary(d);
        _writeManifest(cfg, d);
    }

    // ------------------------------------------------------------------
    // Reporting
    // ------------------------------------------------------------------

    function _logSummary(Deployed memory d) internal pure {
        console.log("=== DeploySepolia: complete ===");
        console.log("deploymentId:", vm.toString(d.deploymentId));
        console.log("KnomosisIdentityRegistry:  ", d.registry);
        console.log("KnomosisBridge:            ", d.bridge);
        console.log("KnomosisDisputeVerifier:   ", d.disputeVerifier);
        console.log("KnomosisSequencerStake:    ", d.sequencerStake);
        console.log("KnomosisAmmDisasterRecovery:", d.ammMultisig);
        console.log("KnomosisStepVM:            ", d.stepVM);
        console.log("KnomosisStateRootSubmission:", d.stateRootSubmission);
        console.log("KnomosisDisputeVerifierV2: ", d.disputeVerifierV2);
        console.log("KnomosisFaultProofGame:    ", d.faultProofGame);
    }

    /// @notice Emit the machine-readable deployment manifest that the L2
    ///         daemons + gateway + Licio client consume.  Requires the
    ///         `deployments/` directory (`make deploy-sepolia` mkdir's it) and
    ///         the `fs_permissions` read-write entry in `foundry.toml`.
    function _writeManifest(DeployConfig memory cfg, Deployed memory d) internal {
        // Nested `contracts` object (game serialized LAST so its return value
        // is the full object).
        string memory c = "contracts";
        vm.serializeAddress(c, "KnomosisIdentityRegistry", d.registry);
        vm.serializeAddress(c, "KnomosisBridge", d.bridge);
        vm.serializeAddress(c, "KnomosisDisputeVerifier", d.disputeVerifier);
        vm.serializeAddress(c, "KnomosisSequencerStake", d.sequencerStake);
        vm.serializeAddress(c, "KnomosisStepVM", d.stepVM);
        vm.serializeAddress(c, "KnomosisStateRootSubmission", d.stateRootSubmission);
        vm.serializeAddress(c, "KnomosisDisputeVerifierV2", d.disputeVerifierV2);
        if (d.ammMultisig != address(0)) {
            vm.serializeAddress(c, "KnomosisAmmDisasterRecoveryMultisig", d.ammMultisig);
        }
        string memory contractsJson = vm.serializeAddress(c, "KnomosisFaultProofGame", d.faultProofGame);

        // Nested `actors` object.
        string memory a = "actors";
        vm.serializeAddress(a, "attestor", cfg.attestor);
        vm.serializeAddress(a, "sequencer", cfg.sequencer);
        vm.serializeAddress(a, "treasury", cfg.treasury);
        vm.serializeAddress(a, "boldCircuitBreaker", cfg.boldCircuitBreaker);
        string memory actorsJson = vm.serializeAddress(a, "boldAdmin", cfg.boldAdmin);

        // Top-level manifest.
        string memory root = "manifest";
        vm.serializeString(root, "network", cfg.network);
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeBytes32(root, "deploymentId", d.deploymentId);
        vm.serializeBytes32(root, "knomosisVersionTag", cfg.versionTag);
        vm.serializeUint(root, "deployedAtBlock", block.number);
        vm.serializeAddress(root, "deployer", msg.sender);
        vm.serializeBool(root, "boldEnabled", d.boldEnabled);
        vm.serializeAddress(root, "boldToken", cfg.boldToken);
        vm.serializeString(root, "contracts", contractsJson);
        string memory finalJson = vm.serializeString(root, "actors", actorsJson);

        vm.writeJson(finalJson, cfg.outPath);
        console.log("manifest written to:", cfg.outPath);
    }
}
