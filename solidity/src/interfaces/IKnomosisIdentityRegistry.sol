// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title IKnomosisIdentityRegistry
/// @notice External-facing surface of `KnomosisIdentityRegistry.sol`.
///         Mirror of the Lean `KeyRegistry` (Authority/Identity.lean).
interface IKnomosisIdentityRegistry {
    /// @notice Distinguishes ECDSA EOAs from EIP-1271 contract
    ///         signers.  The two have different verification paths.
    enum SignerKind {
        UNREGISTERED, // explicit zero state
        ECDSA_EOA,
        EIP1271_CONTRACT
    }

    struct IdentityRecord {
        SignerKind kind;
        bytes pubkey; // 64 bytes uncompressed secp256k1 for ECDSA_EOA;
                     //   address-as-bytes20 for EIP1271_CONTRACT
        uint64 registeredAt;
    }

    function lookup(address actor) external view returns (IdentityRecord memory);

    function isRegistered(address actor) external view returns (bool);

    function registerECDSA(bytes calldata uncompressedPubkey) external;

    function registerEIP1271(address contractSigner) external;

    function revoke() external;

    event RegisteredECDSA(address indexed actor, bytes pubkey);
    event RegisteredEIP1271(address indexed actor, address contractSigner);
    event Revoked(address indexed actor);
}
