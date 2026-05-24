// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {KnomosisIdentityRegistry} from "src/contracts/KnomosisIdentityRegistry.sol";
import {IKnomosisIdentityRegistry} from "src/interfaces/IKnomosisIdentityRegistry.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title MockEip1271AcceptAll
/// @notice EIP-1271 contract that returns the magic value
///         (`0x1626ba7e`) for any signature.  Used to test the
///         "permissive accept-everything" branch of registerEIP1271.
contract MockEip1271AcceptAll is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/// @title MockEip1271RejectAll
/// @notice EIP-1271 contract that returns the canonical "invalid"
///         response (`0x00000000`) on every probe.  This is the
///         expected real-world EIP-1271 contract behaviour for the
///         (bytes32(0), "") probe.
contract MockEip1271RejectAll is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0x00000000;
    }
}

/// @title MockEip1271BadMagic
/// @notice Returns a non-canonical magic value, which the registry
///         must reject.
contract MockEip1271BadMagic is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @title MockEip1271Reverter
/// @notice Reverts on every call.  Models a non-EIP-1271 contract.
contract MockEip1271Reverter {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        revert("nope");
    }
}

contract KnomosisIdentityRegistryTest is Test {
    KnomosisIdentityRegistry private reg;

    // Local copies of the interface events so `vm.expectEmit` can
    // bind them inside this test contract.  Solidity 0.8.20 does
    // not let you `emit Interface.Event(...)`; re-declaring them
    // here is the canonical workaround.
    event RegisteredECDSA(address indexed actor, bytes pubkey);
    event RegisteredEIP1271(address indexed actor, address contractSigner);
    event Revoked(address indexed actor);

    bytes32 private constant KNOMOSIS_VERSION = keccak256("knomosis/v1");

    /// @notice A precomputed valid (privkey, pubkey, address) triple.
    ///         The pubkey is the 64-byte uncompressed form (sans the
    ///         0x04 prefix) of secp256k1 generator base * 1.
    uint256 private constant ALICE_PRIVKEY = 1;
    address private alice;
    bytes private alicePubkey;

    function setUp() public {
        reg = new KnomosisIdentityRegistry(KNOMOSIS_VERSION);

        // Derive Alice's pubkey + address using forge-std's vm.
        alice = vm.addr(ALICE_PRIVKEY);
        // forge-std doesn't expose the pubkey directly; reconstruct
        // it from the address-derivation invariant: address ==
        // keccak256(pubkey)[12:].  We materialise the pubkey by
        // calling cheatcode `vm.sign` against a known message and
        // recovering — but forge-std v1.9 supports `vm.publicKey`
        // via the new cheatcode `vm.computeCreateAddress` patterns.
        //
        // Cleanest reproducible path: hard-code the well-known
        // pubkey for privkey = 1.  This is the secp256k1 generator
        // (G) coordinates, big-endian, concatenated.
        alicePubkey =
            hex"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
            hex"483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8";
    }

    // ------------------------------------------------------------------
    // Constructor / immutability
    // ------------------------------------------------------------------

    function test_constructor_sets_deploymentId() public view {
        bytes32 expected =
            keccak256(abi.encode(block.chainid, address(reg), KNOMOSIS_VERSION));
        assertEq(reg.deploymentId(), expected);
    }

    function test_no_admin_role() public {
        // The contract has no admin functions whatsoever.  This
        // test is a documentation-as-code assertion: any admin
        // function call should fail at the ABI level.  We can't
        // call non-existent functions in Solidity, so we instead
        // check that the contract bytecode doesn't expose any of
        // the standard admin-shaped selectors.
        bytes4[] memory forbiddenSelectors = new bytes4[](7);
        forbiddenSelectors[0] = bytes4(keccak256("pause()"));
        forbiddenSelectors[1] = bytes4(keccak256("unpause()"));
        forbiddenSelectors[2] = bytes4(keccak256("transferOwnership(address)"));
        forbiddenSelectors[3] = bytes4(keccak256("renounceOwnership()"));
        forbiddenSelectors[4] =
            bytes4(keccak256("grantRole(bytes32,address)"));
        forbiddenSelectors[5] =
            bytes4(keccak256("revokeRole(bytes32,address)"));
        forbiddenSelectors[6] = bytes4(keccak256("upgradeTo(address)"));

        for (uint256 i = 0; i < forbiddenSelectors.length; ++i) {
            (bool ok,) = address(reg).call(abi.encodePacked(forbiddenSelectors[i]));
            // Calling a non-existent selector either reverts (ok=false)
            // OR succeeds without returndata (the contract has a fallback).
            // Since this contract has NO fallback, the call must revert.
            assertFalse(ok, "admin function unexpectedly callable");
        }
    }

    // ------------------------------------------------------------------
    // ECDSA registration
    // ------------------------------------------------------------------

    function test_registerECDSA_happy_path() public {
        // Verify the precomputed pubkey indeed derives Alice's address.
        bytes32 pkHash = keccak256(alicePubkey);
        address derived = address(uint160(uint256(pkHash)));
        assertEq(derived, alice, "test fixture: pubkey doesn't match address");

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit RegisteredECDSA(alice, alicePubkey);
        reg.registerECDSA(alicePubkey);

        assertTrue(reg.isRegistered(alice));
        IKnomosisIdentityRegistry.IdentityRecord memory rec = reg.lookup(alice);
        assertEq(uint256(rec.kind), uint256(IKnomosisIdentityRegistry.SignerKind.ECDSA_EOA));
        assertEq(rec.pubkey, alicePubkey);
        assertEq(rec.registeredAt, uint64(block.number));
    }

    function test_registerECDSA_revert_on_pubkey_address_mismatch() public {
        // Eve tries to register Alice's pubkey for her own address.
        address eve = makeAddr("eve");
        vm.prank(eve);
        vm.expectRevert(
            abi.encodeWithSelector(
                KnomosisIdentityRegistry.PubkeyAddressMismatch.selector,
                eve,
                alice
            )
        );
        reg.registerECDSA(alicePubkey);
    }

    function test_registerECDSA_revert_on_wrong_pubkey_length() public {
        bytes memory short_ = hex"deadbeef";
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisIdentityRegistry.WrongPubkeyLength.selector, 4)
        );
        reg.registerECDSA(short_);
    }

    function test_registerECDSA_revert_on_re_registration() public {
        vm.startPrank(alice);
        reg.registerECDSA(alicePubkey);

        // Second call must revert.
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisIdentityRegistry.AlreadyRegistered.selector, alice)
        );
        reg.registerECDSA(alicePubkey);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // EIP-1271 registration
    // ------------------------------------------------------------------

    function test_registerEIP1271_happy_path_accept_all() public {
        MockEip1271AcceptAll signer_ = new MockEip1271AcceptAll();
        address user = makeAddr("contract-owner");

        vm.prank(user);
        vm.expectEmit(true, false, false, true);
        emit RegisteredEIP1271(user, address(signer_));
        reg.registerEIP1271(address(signer_));

        IKnomosisIdentityRegistry.IdentityRecord memory rec = reg.lookup(user);
        assertEq(
            uint256(rec.kind),
            uint256(IKnomosisIdentityRegistry.SignerKind.EIP1271_CONTRACT)
        );
        assertEq(rec.pubkey.length, 20);
    }

    function test_registerEIP1271_happy_path_reject_all() public {
        MockEip1271RejectAll signer_ = new MockEip1271RejectAll();
        address user = makeAddr("contract-owner-2");

        vm.prank(user);
        reg.registerEIP1271(address(signer_));

        assertTrue(reg.isRegistered(user));
    }

    function test_registerEIP1271_revert_on_bad_magic() public {
        MockEip1271BadMagic signer_ = new MockEip1271BadMagic();
        address user = makeAddr("contract-owner-3");

        vm.prank(user);
        vm.expectRevert(KnomosisIdentityRegistry.NotEip1271Conforming.selector);
        reg.registerEIP1271(address(signer_));
    }

    function test_registerEIP1271_revert_on_reverter() public {
        MockEip1271Reverter signer_ = new MockEip1271Reverter();
        address user = makeAddr("contract-owner-4");

        vm.prank(user);
        vm.expectRevert(KnomosisIdentityRegistry.NotEip1271Conforming.selector);
        reg.registerEIP1271(address(signer_));
    }

    function test_registerEIP1271_revert_on_zero_address() public {
        vm.expectRevert(KnomosisIdentityRegistry.NotEip1271Conforming.selector);
        reg.registerEIP1271(address(0));
    }

    function test_registerEIP1271_revert_on_re_registration() public {
        MockEip1271AcceptAll signer_ = new MockEip1271AcceptAll();
        address user = makeAddr("contract-owner-5");

        vm.startPrank(user);
        reg.registerEIP1271(address(signer_));

        vm.expectRevert(
            abi.encodeWithSelector(KnomosisIdentityRegistry.AlreadyRegistered.selector, user)
        );
        reg.registerEIP1271(address(signer_));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Cross-kind registration is forbidden
    // ------------------------------------------------------------------

    function test_no_silent_kind_change_ECDSA_then_EIP1271() public {
        vm.startPrank(alice);
        reg.registerECDSA(alicePubkey);

        MockEip1271AcceptAll signer_ = new MockEip1271AcceptAll();
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisIdentityRegistry.AlreadyRegistered.selector, alice)
        );
        reg.registerEIP1271(address(signer_));
        vm.stopPrank();
    }

    function test_no_silent_kind_change_EIP1271_then_ECDSA() public {
        MockEip1271AcceptAll signer_ = new MockEip1271AcceptAll();
        vm.startPrank(alice);
        reg.registerEIP1271(address(signer_));

        vm.expectRevert(
            abi.encodeWithSelector(KnomosisIdentityRegistry.AlreadyRegistered.selector, alice)
        );
        reg.registerECDSA(alicePubkey);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Revocation
    // ------------------------------------------------------------------

    function test_revoke_clears_record() public {
        vm.startPrank(alice);
        reg.registerECDSA(alicePubkey);
        assertTrue(reg.isRegistered(alice));

        vm.expectEmit(true, false, false, false);
        emit Revoked(alice);
        reg.revoke();

        assertFalse(reg.isRegistered(alice));
        IKnomosisIdentityRegistry.IdentityRecord memory rec = reg.lookup(alice);
        assertEq(
            uint256(rec.kind),
            uint256(IKnomosisIdentityRegistry.SignerKind.UNREGISTERED)
        );
        vm.stopPrank();
    }

    function test_revoke_reverts_when_not_registered() public {
        vm.expectRevert(
            abi.encodeWithSelector(KnomosisIdentityRegistry.NotRegistered.selector, alice)
        );
        vm.prank(alice);
        reg.revoke();
    }

    function test_revoke_then_re_register_ECDSA_passes() public {
        vm.startPrank(alice);
        reg.registerECDSA(alicePubkey);
        reg.revoke();
        reg.registerECDSA(alicePubkey);
        assertTrue(reg.isRegistered(alice));
        vm.stopPrank();
    }

    function test_revoke_then_re_register_EIP1271_passes() public {
        MockEip1271AcceptAll signer_ = new MockEip1271AcceptAll();
        vm.startPrank(alice);
        reg.registerECDSA(alicePubkey);
        reg.revoke();
        reg.registerEIP1271(address(signer_));
        IKnomosisIdentityRegistry.IdentityRecord memory rec = reg.lookup(alice);
        assertEq(
            uint256(rec.kind),
            uint256(IKnomosisIdentityRegistry.SignerKind.EIP1271_CONTRACT)
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Cross-actor isolation
    // ------------------------------------------------------------------

    function test_revoke_does_not_touch_other_actors() public {
        address bob = makeAddr("bob");

        // Bob registers via EIP-1271.
        MockEip1271AcceptAll bobSigner = new MockEip1271AcceptAll();
        vm.prank(bob);
        reg.registerEIP1271(address(bobSigner));

        // Alice registers + revokes.
        vm.startPrank(alice);
        reg.registerECDSA(alicePubkey);
        reg.revoke();
        vm.stopPrank();

        // Bob's record is intact.
        assertTrue(reg.isRegistered(bob));
    }
}
