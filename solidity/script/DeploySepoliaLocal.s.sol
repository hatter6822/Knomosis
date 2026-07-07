// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Knomosis  - A Societal Kernel
//  Copyright (C) 2026  Adam Hall
pragma solidity 0.8.20;

import {DeploySepolia} from "script/DeploySepolia.s.sol";
import {MockBold} from "test/utils/MockBold.sol";

/// @title DeploySepoliaLocal
/// @notice Local-devnet / dry-run variant of `DeploySepolia` that stands up a
///         conformant `MockBold` (its `symbol()` returns "BOLD") and deploys
///         the FULL BOLD + AMM suite against it — exercising the BOLD/AMM
///         deploy path end-to-end on a local anvil node (or an in-memory
///         `forge script` simulation) with NO real chain-native BOLD token.
///
///         NON-MAINNET ONLY: the mainnet BOLD pin (chainid 1) forbids an
///         operator-supplied token, so this wrapper refuses to run on mainnet.
///         Off-mainnet the chain-conditional bridge accepts the mock (code +
///         `symbol() == "BOLD"`).
///
///         Usage:
///         ```bash
///         # in-memory simulation (chainid 31337), writes deployments/anvil.json
///         forge script script/DeploySepoliaLocal.s.sol
///         # live local anvil node
///         make deploy-local
///         ```
///
///         This is a TEST/DEVNET helper (it imports a `test/utils` mock); the
///         production `DeploySepolia` has no test dependency and expects a real
///         `KNOMOSIS_BOLD_TOKEN` (or ETH-only when unset).
contract DeploySepoliaLocal is DeploySepolia {
    function run() external override {
        require(block.chainid != 1, "DeploySepoliaLocal: non-mainnet only");

        // Deploy a conformant BOLD mock; its own address becomes the
        // operator-supplied BOLD token (accepted off-mainnet).
        vm.startBroadcast();
        MockBold bold = new MockBold();
        vm.stopBroadcast();

        DeployConfig memory cfg = _readConfig();
        cfg.boldToken = address(bold);
        // Ensure a FUNCTIONAL AMM so the disaster-recovery multisig is
        // deployed + wired (the BOLD+AMM path exercised here).
        if (cfg.ammSeedRatioBps == 0) {
            cfg.ammSeedRatioBps = 1000; // 10%
        }

        _deployAll(cfg);
    }
}
