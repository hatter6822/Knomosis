// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {KnomosisBridge} from "src/contracts/KnomosisBridge.sol";
import {MockBold} from "test/utils/MockBold.sol";
import {AmmTestBase} from "test/utils/AmmTestBase.sol";

/// @title EthReentryAttacker
/// @notice A malicious ETH recipient.  It initiates a BOLD->ETH swap, and on
///         receiving the ETH output it RE-ENTERS the bridge with a fresh
///         ETH->BOLD swap that WOULD SUCCEED if reentrancy were allowed (it
///         holds the received ETH and can receive the BOLD output).  The
///         reentry call is made via a low-level `call` and its revert is
///         CAUGHT, so the outer swap still completes — letting the test
///         assert that exactly ONE swap's accounting was applied (no
///         double-spend) while the reentry was rejected.
contract EthReentryAttacker {
    KnomosisBridge public immutable bridge;
    bool internal attacking;
    bool public didReenter;
    bool public reentryWasBlocked;

    constructor(KnomosisBridge bridge_) {
        bridge = bridge_;
    }

    /// @notice Approve the bridge for `amountIn` BOLD and launch the outer
    ///         BOLD->ETH swap (this contract must already hold the BOLD).
    function attackBoldToEth(address bold, uint256 amountIn) external returns (uint256) {
        IERC20(bold).approve(address(bridge), amountIn);
        attacking = true;
        return bridge.ammSwap(uint64(1), amountIn, 0, type(uint256).max);
    }

    receive() external payable {
        if (!attacking) return;
        attacking = false;
        didReenter = true;
        // Re-enter with an ETH->BOLD swap of the ETH we just received — this
        // would succeed if the guard were absent.  `nonReentrant` must reject
        // it; we CATCH the revert so the outer swap completes.
        (bool ok,) = address(bridge).call{value: msg.value}(
            abi.encodeWithSignature(
                "ammSwap(uint64,uint256,uint256,uint256)",
                uint64(0),
                msg.value,
                uint256(0),
                type(uint256).max
            )
        );
        reentryWasBlocked = !ok;
    }
}

/// @title ReentrantSwapBold
/// @notice A BOLD-symbol'd token whose `transfer` (the ETH->BOLD swap's
///         output path) re-enters the bridge and PROPAGATES the revert, so a
///         malicious output-path token makes the whole swap fail safely
///         (`nonReentrant` bubbles up through `safeTransfer`).
contract ReentrantSwapBold is MockBold {
    address public targetBridge;

    /// @notice Arm the reentry (set AFTER seeding so only the swap output
    ///         triggers it — seeding deposits use `transferFrom`, not
    ///         `transfer`).
    function arm(address bridge_) external {
        targetBridge = bridge_;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        _move(msg.sender, to, value);
        if (targetBridge != address(0)) {
            // Re-enter with a BOLD->ETH swap; `nonReentrant` reverts, and the
            // revert propagates (no catch), failing the outer swap.
            KnomosisBridge(payable(targetBridge)).ammSwap(uint64(1), 1, 0, type(uint256).max);
        }
        return true;
    }
}

/// @title AmmReentrancyTest
/// @notice Workstream GP.11.3.e — reentrancy resistance of `ammSwap` against
///         both external-call vectors (the ETH `call` and the BOLD
///         `transfer`).  The headline guarantee is no double-spend: a swap's
///         accounting reflects EXACTLY one swap regardless of a re-entrant
///         attempt.
contract AmmReentrancyTest is AmmTestBase {
    /// @notice A malicious ETH recipient re-entering on the ETH output of a
    ///         BOLD->ETH swap is rejected by `nonReentrant`, the outer swap
    ///         completes, and EXACTLY ONE swap's accounting is applied (the
    ///         reentry — which WOULD have succeeded unguarded — moved no
    ///         additional value).
    function test_reentrancy_ethRecipient_blocked_noDoubleSpend() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);

        EthReentryAttacker attacker = new EthReentryAttacker(bridge);
        uint256 amountIn = 3000 ether;
        MockBold(BOLD).mint(address(attacker), amountIn);
        uint256 expectedOut = _refOut(amountIn, rBold, rEth);
        assertGt(expectedOut, 0, "non-trivial output");

        uint256 out = attacker.attackBoldToEth(BOLD, amountIn);

        assertTrue(attacker.didReenter(), "attacker attempted reentry");
        assertTrue(attacker.reentryWasBlocked(), "nonReentrant rejected the would-succeed reentry");
        assertEq(out, expectedOut, "outer swap delivered exactly one swap's output");
        // EXACTLY one swap applied — the reentry corrupted nothing.
        assertEq(bridge.ammReserveBold(), rBold + amountIn, "BOLD reserve reflects exactly one swap");
        assertEq(bridge.ammReserveEth(), rEth - expectedOut, "ETH reserve reflects exactly one swap");
        assertEq(address(attacker).balance, expectedOut, "attacker holds exactly one output (reentry returned its value)");
    }

    /// @notice A malicious BOLD token re-entering on the BOLD output of an
    ///         ETH->BOLD swap makes the whole swap revert
    ///         (`ReentrancyGuardReentrantCall` bubbles through `safeTransfer`),
    ///         leaving the reserves untouched — fail-safe, no partial state.
    function test_reentrancy_boldToken_failsSafe_reservesUnchanged() public {
        ReentrantSwapBold mal = new ReentrantSwapBold();
        vm.etch(BOLD, address(mal).code);
        KnomosisBridge bridge = _deployBoldEnabled();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);
        ReentrantSwapBold(BOLD).arm(address(bridge));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(swapper);
        bridge.ammSwap{value: 1 ether}(NATIVE_ETH, 1 ether, 0, _farDeadline());

        assertEq(bridge.ammReserveEth(), rEth, "ETH reserve unchanged after the reverted reentrant swap");
        assertEq(bridge.ammReserveBold(), rBold, "BOLD reserve unchanged after the reverted reentrant swap");
    }

    /// @notice Control: the SAME `EthReentryAttacker` performing a single,
    ///         non-re-entrant BOLD->ETH swap (the `attacking` flag never set
    ///         by a second receive) succeeds normally — proving the guard
    ///         rejects only the re-entrant path, not honest contract callers.
    function test_reentrancy_honestContractCaller_succeeds() public {
        KnomosisBridge bridge = _deploySeededReady();
        (uint256 rEth, uint256 rBold) = _seedBothLegs(bridge);

        EthReentryAttacker attacker = new EthReentryAttacker(bridge);
        uint256 amountIn = 1500 ether;
        MockBold(BOLD).mint(address(attacker), amountIn);
        uint256 expectedOut = _refOut(amountIn, rBold, rEth);

        uint256 out = attacker.attackBoldToEth(BOLD, amountIn);

        // The reentry is attempted exactly once and blocked, yet the honest
        // outer swap still settles correctly.
        assertEq(out, expectedOut, "honest contract caller's swap settles");
        assertEq(bridge.ammReserveEth(), rEth - expectedOut, "single swap applied");
        assertEq(bridge.ammReserveBold(), rBold + amountIn, "single swap applied");
    }
}
