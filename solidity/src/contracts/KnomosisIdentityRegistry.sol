// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IKnomosisIdentityRegistry} from "src/interfaces/IKnomosisIdentityRegistry.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title KnomosisIdentityRegistry
/// @notice Mirror of the Lean `KeyRegistry` (Authority/Identity.lean) on
///         Ethereum.  Per workstream E.3 of the integration plan,
///         this contract distinguishes ECDSA EOAs from EIP-1271
///         contract signers at the type level (the two have
///         different verification paths in A.1's adaptor).
///
/// @dev    **Immutability discipline (§4.8 / §20).**  No proxy, no
///         `initialize`, no admin role, no upgrade hook.  Each user
///         registers their own identity by calling `registerECDSA`
///         / `registerEIP1271` directly.  Re-registration without
///         revocation is forbidden (closes the silent-kind-change
///         vector).  Re-deploying this contract requires a new
///         bridge deployment + a `KnomosisMigration` handoff (§9.5).
///
///         **Front-running protection** (`registerECDSA`): we
///         verify that `keccak256(uncompressedPubkey) == addr(msg.sender)`
///         so an attacker cannot register Alice's pubkey as their
///         own identity.
///
///         **EIP-1271 probe** (`registerEIP1271`): we call the
///         contract's `isValidSignature(bytes32(0), "")` and accept
///         only if it returns the canonical `0x1626ba7e` magic
///         (valid signature) or `0x00000000` (genuine rejection).
///         A reverting / non-conforming contract is rejected with
///         `NotEip1271Conforming`.
contract KnomosisIdentityRegistry is IKnomosisIdentityRegistry {
    // ------------------------------------------------------------------
    // Custom errors
    // ------------------------------------------------------------------

    /// @notice The supplied uncompressed pubkey doesn't match the
    ///         derived address `keccak256(pubkey)[12:]`.  Closes
    ///         the front-running vector where Eve registers Alice's
    ///         pubkey for her own address.
    error PubkeyAddressMismatch(address expected, address derived);

    /// @notice The supplied uncompressed pubkey is not exactly 64
    ///         bytes (canonical secp256k1 uncompressed form, sans
    ///         0x04 prefix).
    error WrongPubkeyLength(uint256 actual);

    /// @notice The supplied contract signer doesn't conform to the
    ///         EIP-1271 interface (reverts on probe or returns an
    ///         invalid magic value).
    error NotEip1271Conforming();

    /// @notice Re-registration without revocation forbidden.
    error AlreadyRegistered(address actor);

    /// @notice Cannot revoke when not registered (defensive; UX).
    error NotRegistered(address actor);

    // ------------------------------------------------------------------
    // Immutable deployment metadata
    // ------------------------------------------------------------------

    /// @notice Deployment-id mirror of the Lean §8.8.5 deploymentId.
    bytes32 public immutable deploymentId;

    // ------------------------------------------------------------------
    // State (per-user, mutable only by the owner of each entry)
    // ------------------------------------------------------------------

    mapping(address => IdentityRecord) private _identities;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @param _knomosisVersionTag a deployment-namespacing tag used in
    ///        the deploymentId derivation.  Constant for the lifetime
    ///        of this contract.
    constructor(bytes32 _knomosisVersionTag) {
        deploymentId =
            keccak256(abi.encode(block.chainid, address(this), _knomosisVersionTag));
    }

    // ------------------------------------------------------------------
    // External: register / revoke / lookup
    // ------------------------------------------------------------------

    /// @inheritdoc IKnomosisIdentityRegistry
    function registerECDSA(bytes calldata uncompressedPubkey) external {
        if (uncompressedPubkey.length != 64) {
            revert WrongPubkeyLength(uncompressedPubkey.length);
        }

        // Derive the canonical secp256k1 EVM address from the
        // pubkey: keccak256(pubkey)[12:].  This matches the
        // standard `address := uint160(keccak256(pubkey))` used
        // by every secp256k1-EVM library.
        bytes32 pkHash = keccak256(uncompressedPubkey);
        address derived = address(uint160(uint256(pkHash)));
        if (derived != msg.sender) {
            revert PubkeyAddressMismatch(msg.sender, derived);
        }

        if (_identities[msg.sender].kind != SignerKind.UNREGISTERED) {
            revert AlreadyRegistered(msg.sender);
        }

        _identities[msg.sender] = IdentityRecord({
            kind: SignerKind.ECDSA_EOA,
            pubkey: uncompressedPubkey,
            registeredAt: uint64(block.number)
        });

        emit RegisteredECDSA(msg.sender, uncompressedPubkey);
    }

    /// @inheritdoc IKnomosisIdentityRegistry
    function registerEIP1271(address contractSigner) external {
        if (contractSigner == address(0)) {
            revert NotEip1271Conforming();
        }

        if (_identities[msg.sender].kind != SignerKind.UNREGISTERED) {
            revert AlreadyRegistered(msg.sender);
        }

        // Probe the EIP-1271 surface.  We accept either:
        //   * 0x1626ba7e — the EIP-1271 "valid signature" magic
        //     (extremely unlikely on a (bytes32(0), "") probe but
        //     not impossible if the contract has a permissive
        //     accept-everything policy).
        //   * 0x00000000 — the canonical "invalid signature"
        //     response, evidence that the contract implements
        //     the interface and is not silently accepting.
        // We REJECT any other return value or any revert.
        try IERC1271(contractSigner).isValidSignature(bytes32(0), "") returns (
            bytes4 magic
        ) {
            if (magic != bytes4(0x1626ba7e) && magic != bytes4(0x00000000)) {
                revert NotEip1271Conforming();
            }
        } catch {
            revert NotEip1271Conforming();
        }

        _identities[msg.sender] = IdentityRecord({
            kind: SignerKind.EIP1271_CONTRACT,
            // Encode the address as 20 bytes BE (matching the Lean
            // side's `bytes20` discipline for EIP-1271 keys).
            pubkey: abi.encodePacked(contractSigner),
            registeredAt: uint64(block.number)
        });

        emit RegisteredEIP1271(msg.sender, contractSigner);
    }

    /// @inheritdoc IKnomosisIdentityRegistry
    function revoke() external {
        if (_identities[msg.sender].kind == SignerKind.UNREGISTERED) {
            revert NotRegistered(msg.sender);
        }
        delete _identities[msg.sender];
        emit Revoked(msg.sender);
    }

    /// @inheritdoc IKnomosisIdentityRegistry
    function lookup(address actor) external view returns (IdentityRecord memory) {
        return _identities[actor];
    }

    /// @inheritdoc IKnomosisIdentityRegistry
    function isRegistered(address actor) external view returns (bool) {
        return _identities[actor].kind != SignerKind.UNREGISTERED;
    }
}
