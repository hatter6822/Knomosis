// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title KnomosisEip712
/// @notice Solidity port of `LegalKernel.Bridge.Eip712` (workstream A.3).
///         Builds the `\x19\x01 ‖ domainSeparator ‖ structHash`
///         payload that wallets sign for Knomosis `signInput` actions
///         and for migration attestations.
///
/// @dev    The type strings are character-identical to the Lean
///         module's, so a spec-compliant wallet (MetaMask, Ledger)
///         parsing the type and producing a signature will produce
///         bytes that this library accepts byte-for-byte.
///
///         **Critical correctness invariant.**  The Lean module's
///         declared type string uses `bytes deploymentId` and
///         `bytes verifyingContract`, NOT `bytes32` / `address`.
///         This means EIP-712's "hash-before-encode" rule applies
///         to those fields: the wallet computes `keccak256(deploymentId)`
///         when assembling the struct hash, not the raw bytes.
///         This Solidity helper preserves that discipline.
library KnomosisEip712 {
    bytes2 internal constant EIP712_PREFIX = 0x1901;

    string internal constant EIP712_DOMAIN_TYPE_STRING =
        "EIP712Domain(string name,string version,uint256 chainId,"
        "uint256 rollupId,bytes verifyingContract)";

    string internal constant KNOMOSIS_ACTION_TYPE_STRING =
        "KnomosisAction(bytes32 actionHash,uint64 signer,uint64 nonce,bytes deploymentId)";

    string internal constant KNOMOSIS_MIGRATION_TYPE_STRING =
        "KnomosisMigration(bytes32 predecessorDeploymentId,"
        "bytes32 successorDeploymentId,bytes32 migrationStateRoot,"
        "uint64 migrationStateRootLogIdx,uint256 graceWindowBlocks)";

    /// @notice Type hash for the `EIP712Domain` struct.
    function domainTypeHash() internal pure returns (bytes32) {
        return keccak256(bytes(EIP712_DOMAIN_TYPE_STRING));
    }

    /// @notice Type hash for the `KnomosisAction` struct.
    function knomosisActionTypeHash() internal pure returns (bytes32) {
        return keccak256(bytes(KNOMOSIS_ACTION_TYPE_STRING));
    }

    /// @notice Type hash for the `KnomosisMigration` struct.
    function knomosisMigrationTypeHash() internal pure returns (bytes32) {
        return keccak256(bytes(KNOMOSIS_MIGRATION_TYPE_STRING));
    }

    /// @notice Compute the EIP-712 domain separator.  Mirrors
    ///         `eip712DomainSeparator` in Lean.
    /// @dev    `verifyingContract` is declared as `bytes` in the
    ///         type string, so we hash its bytes representation
    ///         (the 20-byte address as a packed bytes value) before
    ///         placing it in the preimage.
    function domainSeparator(
        string memory name,
        string memory version,
        uint256 chainId,
        uint256 rollupId,
        address verifyingContract
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                domainTypeHash(),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                rollupId,
                keccak256(abi.encodePacked(verifyingContract))
            )
        );
    }

    /// @notice Compute the EIP-712 struct hash for a Knomosis action
    ///         message.  Mirrors `eip712StructHash` in Lean.
    /// @dev    `deploymentId` is declared `bytes` in the type
    ///         string; we hash its bytes representation.
    function actionStructHash(
        bytes32 actionHash,
        uint64 signer,
        uint64 nonce,
        bytes32 deploymentId
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                knomosisActionTypeHash(),
                actionHash,
                uint256(signer),
                uint256(nonce),
                // deploymentId is a bytes32 on the Solidity side
                // (matching the on-chain `deploymentId` derivation
                // recipe); the Lean side hashes its byte form.
                keccak256(abi.encodePacked(deploymentId))
            )
        );
    }

    /// @notice Compute the EIP-712 struct hash for a Knomosis migration
    ///         attestation.  Mirrors the §9.5 `_eip712WrapHash`
    ///         scheme.
    function migrationStructHash(
        bytes32 predecessorDeploymentId,
        bytes32 successorDeploymentId,
        bytes32 migrationStateRoot,
        uint64 migrationStateRootLogIdx,
        uint256 graceWindowBlocks
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                knomosisMigrationTypeHash(),
                predecessorDeploymentId,
                successorDeploymentId,
                migrationStateRoot,
                uint256(migrationStateRootLogIdx),
                graceWindowBlocks
            )
        );
    }

    /// @notice Compute the full EIP-712 sign-input hash:
    ///         `keccak256(\x19\x01 ‖ domainSeparator ‖ structHash)`.
    function digest(bytes32 _domainSeparator, bytes32 _structHash)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(EIP712_PREFIX, _domainSeparator, _structHash));
    }
}
