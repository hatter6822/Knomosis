// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title CREATE3
/// @notice Deploy a contract at an address derived from
///         `(deployer, salt)` only — independent of the deployed
///         contract's init-code.
///
/// @dev    The standard CREATE3 pattern (Solady, Solmate) used to
///         break cross-reference cycles between contracts that
///         must point at each other's `immutable` addresses.  The
///         workflow:
///
///         1. Predict each contract's address from
///            `(deployer, salt)` alone via `addressOf(salt)`.
///         2. Bake the predicted addresses into each contract's
///            constructor arguments.
///         3. Deploy each contract with `deploy(salt, initCode)`.
///            The actual deployed address matches the prediction
///            byte-for-byte.
///
///         Mechanism: deploy a tiny "factory" contract via CREATE2
///         using `(deployer, salt)`.  The factory's address is
///         deterministic in `(deployer, salt, factoryInitCodeHash)`
///         — but `factoryInitCode` is constant for all CREATE3
///         deployments, so the factory address depends only on
///         `(deployer, salt)`.  The factory then deploys the
///         actual contract via CREATE; the contract ends up at
///         the factory's address with nonce 1, which is also
///         deterministic in `(factoryAddress)`.
///
///         Adapted from Solmate's CREATE3:
///         https://github.com/transmissions11/solmate/blob/main/src/utils/CREATE3.sol
library CREATE3 {
    /// @notice The 16-byte init-code that, when CREATE2-deployed,
    ///         yields a "proxy factory" — a minimal contract that
    ///         on its first (and only) external call, deploys the
    ///         provided calldata as a contract via CREATE.
    ///
    ///         Bytecode breakdown:
    ///           67_363d3d37363d34f0  PUSH8 + push the inner code
    ///                                (which is `RETURNDATASIZE
    ///                                CALLDATACOPY ... CREATE`).
    ///           3d5260086018f3       Store the inner code in
    ///                                memory and RETURN it as
    ///                                deployed bytecode.
    ///
    ///         The deployed proxy's runtime code:
    ///           36 3d 3d 37 36 3d 34 f0
    ///           CALLDATASIZE RETURNDATASIZE RETURNDATASIZE
    ///           CALLDATACOPY CALLDATASIZE RETURNDATASIZE
    ///           CALLVALUE CREATE
    ///         which executes `create(0, 0, calldatasize)` with
    ///         `msg.data` (the contract init-code) at offset 0.
    bytes internal constant FACTORY_BYTECODE = hex"67363d3d37363d34f03d5260086018f3";

    /// @notice keccak256 of `FACTORY_BYTECODE` — used in CREATE2
    ///         address derivation.
    bytes32 internal constant FACTORY_BYTECODE_HASH =
        0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    error FactoryDeployFailed();
    error TargetDeployFailed();

    /// @notice Predict the address that `deploy(salt, *)` will
    ///         deploy to from `deployer`.  Independent of the
    ///         init-code; depends only on `(deployer, salt)`.
    function addressOf(address deployer, bytes32 salt) internal pure returns (address) {
        // Step 1: compute the proxy factory's CREATE2 address.
        address proxy = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), deployer, salt, FACTORY_BYTECODE_HASH
                        )
                    )
                )
            )
        );
        // Step 2: the deployed contract is at the proxy's nonce-1
        // CREATE address.  RLP-encoded as
        // [0xd6, 0x94, address, 0x01].
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes2(0xd694), proxy, bytes1(0x01)))
                )
            )
        );
    }

    /// @notice Deploy `initCode` to a CREATE3-derived address.
    ///         Returns the deployed address; reverts on failure.
    function deploy(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        bytes memory factoryCode = FACTORY_BYTECODE;
        // Use a single assembly block that performs the create2 +
        // null-check + (success-path) factory call in one swoop.
        // This avoids any cross-block variable-lifetime issues
        // under via_ir optimisation.
        address factory;
        bool factoryDeployed;
        assembly {
            let f := create2(0, add(factoryCode, 0x20), mload(factoryCode), salt)
            // Convert the truthiness of `f` into a boolean while
            // we still hold the value on the stack.  Both
            // `factory` and `factoryDeployed` are written before
            // we leave the assembly block.
            factory := f
            factoryDeployed := iszero(iszero(f))
        }
        if (!factoryDeployed) revert FactoryDeployFailed();

        // Compute the predicted deployed address (factory's nonce-1 CREATE).
        deployed = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes2(0xd694), factory, bytes1(0x01)))
                )
            )
        );

        // Send the init-code to the factory; the factory's runtime
        // bytecode does `create(0, 0, calldatasize)` with msg.data
        // as the new contract's init-code.  We bubble up the inner
        // revert reason so the caller's `expectRevert` sees the
        // actual error, not a generic `TargetDeployFailed`.
        (bool ok, bytes memory returndata) = factory.call(initCode);
        if (!ok) {
            // Propagate the inner revert reason.
            assembly {
                let len := mload(returndata)
                revert(add(returndata, 0x20), len)
            }
        }
        // Defence-in-depth: assert the deployed address has code.
        // Even if the factory's call succeeded, an inner CREATE
        // failure leaves no code at the predicted address.
        if (deployed.code.length == 0) revert TargetDeployFailed();
    }
}
