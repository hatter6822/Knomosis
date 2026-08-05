// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {MockBold} from "test/utils/MockBold.sol";

/// @title BoldTestSupport
/// @notice **The two things every BOLD-touching test does before it can
///         do anything else.**
///
/// @dev    `KnomosisBridge` pins the BOLD token to a compile-time
///         address, so a test must place a mock at exactly that address
///         before a BOLD path will run at all.  Five files had grown
///         their own byte-identical `_etchBold`, and six their own
///         `_mintApprove` — the same shape as the proxy and encoder
///         wrappers: boilerplate whose only job is to exist,
///         re-derived per file because there was nowhere to put it.
///
///         Deliberately SMALL.  `AmmTestBase` already offered both, and
///         the five files did not inherit it because it also brings a
///         `setUp` and a family of deployers they do not want.  A base
///         nobody can afford to inherit is not a shared home, so the
///         two universally-needed helpers live here and `AmmTestBase`
///         inherits this rather than the other way round.
abstract contract BoldTestSupport is Test {
    /// @notice The BOLD token's pinned address — the test tree's ONLY
    ///         copy of this literal.
    ///
    /// @dev    Deriving it (`KnomosisBridge.BOLD_TOKEN_ADDRESS`) would be
    ///         better still, but solc 0.8.20 will not resolve a `public
    ///         constant` through the contract type, and a derived value
    ///         would in any case assert nothing: a test suite that reads
    ///         the address off the contract cannot notice the contract
    ///         changing it.
    ///
    ///         So this is an INDEPENDENT literal, and
    ///         `BridgeFeeSplitBold.test_boldConstants_pinned` compares it
    ///         against the deployed constant.  Two independent values
    ///         and one assertion between them; previously the same
    ///         literal appeared eighteen times across twelve files, any
    ///         seventeen of which could have drifted silently.
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    /// @notice Place a `MockBold` at the pinned BOLD address.
    function _etchBold() internal {
        MockBold impl = new MockBold();
        vm.etch(BOLD, address(impl).code);
    }

    /// @notice Fund `user` with `amount` BOLD and approve `bridge` to
    ///         spend it.
    ///
    /// @dev    `virtual` for one caller: the gas benchmark deliberately
    ///         funds through `MockBoldOz`, the OpenZeppelin-faithful
    ///         mock, because a benchmark measuring a token transfer must
    ///         measure a realistic one.  That is a different function
    ///         wearing the same name, so it overrides rather than
    ///         forcing this one to know about it.
    function _mintApprove(KnomosisBridge bridge, address user, uint256 amount)
        internal
        virtual
    {
        MockBold(BOLD).mint(user, amount);
        vm.prank(user);
        MockBold(BOLD).approve(address(bridge), amount);
    }
}
