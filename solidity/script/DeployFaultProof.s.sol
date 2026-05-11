// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Canon  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {Script} from "forge-std/Script.sol";

import {CanonStepVM}                from "../src/contracts/CanonStepVM.sol";
import {CanonFaultProofGame}        from "../src/contracts/CanonFaultProofGame.sol";
import {CanonStateRootSubmission}   from "../src/contracts/CanonStateRootSubmission.sol";
import {CanonDisputeVerifierV2}     from "../src/contracts/CanonDisputeVerifierV2.sol";
import {CanonFaultProofMigration}   from "../src/contracts/CanonFaultProofMigration.sol";

/// @title DeployFaultProof
/// @notice Workstream-H deployment script (WU H.9.3).  Deploys
///         the five fault-proof contracts in dependency order.
///
/// Per Workstream-E discipline: contracts are immutable; no
/// admin / pause / upgrade.  Recovery from bugs is via
/// CanonFaultProofMigration.
contract DeployFaultProof is Script {
    function run() external {
        // Configuration parameters (override via env).
        uint128 stateRootBond = uint128(
          vm.envOr("CANON_STATE_ROOT_BOND",
                   uint256(1 ether)));
        uint64  disputeWindow = uint64(
          vm.envOr("CANON_DISPUTE_WINDOW_BLOCKS",
                   uint256(216_000)));   // ~30 days
        uint64  withdrawalFinalisationWindow = uint64(
          vm.envOr("CANON_WITHDRAWAL_WINDOW_BLOCKS",
                   uint256(216_000)));
        uint64  minSubmissionInterval = uint64(
          vm.envOr("CANON_MIN_SUBMISSION_INTERVAL",
                   uint256(100)));
        uint64  maxOutstandingRoots = uint64(
          vm.envOr("CANON_MAX_OUTSTANDING_ROOTS",
                   uint256(100)));
        uint64  bisectionTimeout = uint64(
          vm.envOr("CANON_BISECTION_TIMEOUT_BLOCKS",
                   uint256(21_600)));    // ~3 days
        uint128 minChallengeBond = uint128(
          vm.envOr("CANON_MIN_CHALLENGE_BOND",
                   uint256(0.05 ether)));
        uint64  minBisectionStepInterval = uint64(
          vm.envOr("CANON_MIN_BISECTION_STEP_INTERVAL",
                   uint256(5)));
        address sequencer = vm.envAddress("CANON_SEQUENCER_ADDRESS");
        address treasury  = vm.envAddress("CANON_TREASURY_ADDRESS");
        address bridge    = vm.envAddress("CANON_BRIDGE_ADDRESS");
        bytes32 deploymentId = vm.envBytes32("CANON_DEPLOYMENT_ID");

        vm.startBroadcast();

        // The deploy has a circular dependency: the game contract
        // needs `stateRootSubmission`'s address; the state-root
        // submission contract needs the game's address; the
        // dispute verifier needs both.  We resolve by predicting
        // the game's address (via `computeCreateAddress` on the
        // broadcaster's nonce) before deploying state-root sub
        // and verifier.  The state-root submission's constructor
        // only zero-checks `_faultProofGame`; it does NOT
        // require the address to have code yet (because at this
        // point, the game hasn't been deployed).  The game's
        // constructor DOES require `_stateRootSubmission.code.length
        // > 0` (audit-2 defence) — by the time we deploy game,
        // state-root-sub has code.  Order:
        //   1. Deploy stepVM (nonce N)
        //   2. Predict state-root-sub addr (= addr at nonce N+1)
        //   3. Predict verifier addr (= addr at nonce N+2)
        //   4. Predict game addr (= addr at nonce N+3)
        //   5. Deploy state-root-sub with predicted game addr
        //   6. Deploy verifier with predicted game + real
        //      state-root-sub
        //   7. Deploy game with real state-root-sub + real stepVM

        // Single-adjudicator quorum (1-of-1) is the minimal valid
        // configuration for the deploy script's smoke test.  Real
        // deployments configure a multi-adjudicator set with a
        // strict-majority quorum via constructor arguments.
        address[] memory adjudicators = new address[](1);
        adjudicators[0] = sequencer;  // placeholder adjudicator

        // Step 1: deploy CanonStepVM (no dependencies).
        CanonStepVM stepVM = new CanonStepVM();

        // Step 2-4: predict the game's address before deploying
        // state-root-sub or verifier.  The broadcaster's nonce
        // advances by 1 per deployment; we predict
        // {state-root-sub, verifier, game} as next, next+1, next+2.
        address broadcaster = msg.sender;
        uint64 nonce = vm.getNonce(broadcaster);
        // After this point: nonce = N+1 (post-stepVM deploy).
        // Wait — we already deployed stepVM above, so the
        // current nonce reflects that.  Predict next 3 contracts:
        address predictedSubmission = vm.computeCreateAddress(broadcaster, nonce);
        address predictedVerifier   = vm.computeCreateAddress(broadcaster, nonce + 1);
        address predictedGame       = vm.computeCreateAddress(broadcaster, nonce + 2);

        // Step 5: deploy state-root-sub with predicted game addr.
        // The state-root-sub's constructor checks `_faultProofGame
        // != address(0)` — predictedGame is non-zero.  It does
        // NOT check code.length (the game doesn't exist yet).
        CanonStateRootSubmission submission =
          new CanonStateRootSubmission(
            stateRootBond,
            disputeWindow,
            minSubmissionInterval,
            maxOutstandingRoots,
            sequencer,
            predictedGame,
            deploymentId,
            withdrawalFinalisationWindow);
        require(address(submission) == predictedSubmission, "AddressMismatch");

        // Step 6: deploy verifier.  Same discipline.
        CanonDisputeVerifierV2 verifier = new CanonDisputeVerifierV2(
            predictedGame,           // faultProofGame (predicted)
            address(submission),     // stateRootSubmission (real)
            adjudicators,
            1,                       // quorumThreshold (1-of-1 smoke test)
            bridge,
            sequencer,               // sequencerStake placeholder
            sequencer,               // attestor placeholder
            deploymentId
        );
        require(address(verifier) == predictedVerifier, "AddressMismatch");

        // Step 7: deploy game.  Its constructor checks
        // `_stateRootSubmission.code.length > 0` — state-root-sub
        // is now deployed and has code.
        CanonFaultProofGame game = new CanonFaultProofGame(
            bisectionTimeout,
            minChallengeBond,
            minBisectionStepInterval,
            treasury,
            address(stepVM),
            address(submission)
        );
        require(address(game) == predictedGame, "AddressMismatch");

        // Post-deploy assert.  Defence-in-depth on every contract's
        // structural invariants.
        stepVM.assertConsistent();
        verifier.assertConsistent();
        submission.assertConsistent();
        game.assertConsistent();

        vm.stopBroadcast();
    }
}
