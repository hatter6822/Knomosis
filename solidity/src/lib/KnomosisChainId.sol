// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title KnomosisChainId
/// @notice Canonical Knomosis **L2** chain identifiers, distinct from the L1
///         settlement chain (Ethereum mainnet chainid 1 / Sepolia 11155111).
///
/// @dev    The L2 chain id is the identity a wallet uses to sign Knomosis L2
///         actions (the EIP-712 `"KnomosisAction"` domain, `§13.6`) and to
///         "Add Network" so a browser wallet can target the L2.  It is a
///         DIFFERENT quantity from:
///           * `block.chainid` — the L1 the bridge settles to; used for the
///             genuinely-L1 EIP-712 domains (state-root attestations, verdict
///             signatures, migration attestations) and every `deploymentId`
///             derivation, where replay protection must stay scoped to the L1.
///           * `deploymentId` — `keccak256(block.chainid, contract, versionTag)`,
///             which folds in the L1 chain id (NOT the L2 chain id).
///
///         The L2 chain id is CONSTANT across L1 settlement layers of the same
///         tier: the L2's identity does not change when it settles to a
///         different L1 — only the tier (production vs test) selects the value.
///         `l2ChainId(block.chainid)` derives it deterministically from the L1
///         the contract is deployed on, so every stack (this contract's
///         action-domain reconstruction, the deploy manifest, the gateway
///         `/v1/info` + JSON-RPC shim, and the off-chain wallet signer) obtains
///         the SAME value and it can never drift.
library KnomosisChainId {
    /// @notice The Knomosis L2 chain id when the bridge settles to Ethereum
    ///         mainnet (L1 chainid 1) — the production Knomosis L2.
    uint256 internal constant L2_CHAIN_ID_MAINNET = 8357;

    /// @notice The Knomosis L2 chain id when the bridge settles to any
    ///         non-mainnet L1 (Sepolia 11155111, Holesky, a local devnet) —
    ///         the test Knomosis L2.  A distinct id (`mainnet * 10 + 2`, the
    ///         Base 8453/84532 testnet convention) so a wallet never confuses
    ///         the test L2 with the production L2.
    uint256 internal constant L2_CHAIN_ID_TESTNET = 83572;

    /// @notice The canonical Knomosis L2 chain id for a bridge deployed on the
    ///         L1 identified by `l1ChainId`: mainnet L1 (chainid 1) selects the
    ///         production L2 (8357); every other L1 selects the test L2 (83572).
    /// @param  l1ChainId The L1 settlement chain id (`block.chainid`).
    /// @return The canonical Knomosis L2 chain id.
    function l2ChainId(uint256 l1ChainId) internal pure returns (uint256) {
        return l1ChainId == 1 ? L2_CHAIN_ID_MAINNET : L2_CHAIN_ID_TESTNET;
    }
}
