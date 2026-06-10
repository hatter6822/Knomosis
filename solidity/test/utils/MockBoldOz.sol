// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockBoldOz
/// @notice A gas-faithful BOLD stand-in for the GP.11.9 benchmark suite
///         (`BenchmarkGasV1_3.t.sol`), built on the REAL vendored
///         OpenZeppelin v5 `ERC20` implementation rather than the
///         hand-rolled `MockBold`.
///
///         Why a second BOLD mock exists: the production BOLD token
///         (Liquity V2) is OpenZeppelin-based, and OZ's ERC-20 has gas
///         behaviour the hand-rolled `MockBold` does not model — most
///         importantly `_spendAllowance` SKIPS the allowance storage
///         write entirely when the standing allowance is
///         `type(uint256).max` (the "infinite approval" wallet pattern),
///         where `MockBold.transferFrom` writes the decremented
///         allowance unconditionally.  Benchmarks measured against this
///         mock therefore reproduce real-BOLD storage-op counts for
///         BOTH the exact-approval and infinite-approval flows.
///
///         The behavioural suites deliberately keep using `MockBold`
///         (and its adversarial subclasses); this mock is benchmark-only
///         so its introduction shifts no existing test's expectations.
///
/// @dev    `name()` / `symbol()` are overridden as `pure` (code-resident
///         constants) because the harness places this mock at the pinned
///         `BOLD_TOKEN_ADDRESS` via `vm.etch`, which copies runtime code
///         but RESETS storage — the OZ constructor's storage-resident
///         `_name` / `_symbol` strings would read back empty after the
///         etch, failing the bridge constructor's
///         `symbol() == EXPECTED_BOLD_SYMBOL` cross-check.  Overriding
///         `view` with `pure` is a legal mutability tightening.
contract MockBoldOz is ERC20 {
    constructor() ERC20("", "") {}

    /// @inheritdoc ERC20
    function name() public pure override returns (string memory) {
        return "Bold USD";
    }

    /// @inheritdoc ERC20
    function symbol() public pure override returns (string memory) {
        return "BOLD";
    }

    /// @notice Test-only mint.  Permissionless by design (mirrors
    ///         `MockBold.mint`); called after the `vm.etch` so seeded
    ///         balances land in the etched address's storage.
    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}
