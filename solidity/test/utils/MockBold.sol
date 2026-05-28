// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title MockBold
/// @notice A standard-ERC-20 BOLD mock for the GP.5.4 `depositBoldWithFee`
///         test suites.
///
/// @dev    `KnomosisBridge.BOLD_TOKEN_ADDRESS` is a compile-time constant,
///         so the constructor's `symbol()` cross-check and the deposit
///         path's `transferFrom` both target that exact address.  Tests
///         place a mock there with `vm.etch(BOLD_TOKEN_ADDRESS,
///         address(new MockBold()).code)`.  `vm.etch` copies *runtime
///         code* and resets *storage*, so `name`/`symbol`/`decimals` are
///         `pure` (code-resident, survive the etch) while balances /
///         allowances live in storage and are seeded after the etch via
///         `mint` / `approve`.  The overridable surfaces are `virtual`
///         so the non-conformant variants below can subclass.
contract MockBold is IERC20Metadata {
    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowances;

    function name() external pure virtual returns (string memory) {
        return "Bold USD";
    }

    function symbol() external pure virtual returns (string memory) {
        return "BOLD";
    }

    function decimals() external pure virtual returns (uint8) {
        return 18;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address a) external view virtual returns (uint256) {
        return _balances[a];
    }

    function allowance(address o, address s) external view returns (uint256) {
        return _allowances[o][s];
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external virtual returns (bool) {
        uint256 a = _allowances[from][msg.sender];
        require(a >= value, "BOLD: insufficient allowance");
        unchecked {
            _allowances[from][msg.sender] = a - value;
        }
        _move(from, to, value);
        return true;
    }

    /// @notice Test-only mint.  Permissionless by design; called after the
    ///         `vm.etch` so the seeded balances land in the etched address's
    ///         (initially empty) storage.
    function mint(address to, uint256 value) external {
        _balances[to] += value;
        _totalSupply += value;
        emit Transfer(address(0), to, value);
    }

    function _move(address from, address to, uint256 value) internal {
        require(_balances[from] >= value, "BOLD: balance");
        unchecked {
            _balances[from] -= value;
        }
        _balances[to] += value;
        emit Transfer(from, to, value);
    }
}

/// @title FeeOnTransferBold
/// @notice A BOLD-symbol'd mock that skims a 1-wei fee on every
///         `transferFrom` (only `value - 1` actually arrives).  Passes the
///         constructor symbol check but trips the deposit path's
///         balance-delta check (`BoldTransferAmountMismatch`), proving the
///         bridge rejects a hypothetical fee-on-transfer BOLD upgrade.
contract FeeOnTransferBold is MockBold {
    function transferFrom(address from, address to, uint256 value)
        external
        override
        returns (bool)
    {
        uint256 a = _allowances[from][msg.sender];
        require(a >= value, "BOLD: insufficient allowance");
        unchecked {
            _allowances[from][msg.sender] = a - value;
        }
        require(_balances[from] >= value, "BOLD: balance");
        unchecked {
            _balances[from] -= value;
        }
        uint256 fee = value > 0 ? 1 : 0;
        uint256 received = value - fee;
        _balances[to] += received;
        if (fee > 0) {
            unchecked {
                _totalSupply -= fee;
            }
        }
        emit Transfer(from, to, received);
        return true;
    }
}

/// @title WrongSymbolBold
/// @notice A mock at the pinned address whose `symbol()` is NOT "BOLD".
///         The bridge constructor must reject it with
///         `BoldTokenSymbolMismatch`.
contract WrongSymbolBold is MockBold {
    function symbol() external pure override returns (string memory) {
        return "NOTBOLD";
    }
}

/// @title RevertingSymbolBold
/// @notice A mock whose `symbol()` reverts.  The bridge constructor's
///         try/catch must treat this as "not BOLD" and revert with
///         `BoldTokenSymbolUnavailable`.
contract RevertingSymbolBold is MockBold {
    function symbol() external pure override returns (string memory) {
        revert("BOLD: no symbol");
    }
}

/// @title ReturnsFalseBold
/// @notice A mock whose `transferFrom` returns `false` without moving any
///         tokens.  `SafeERC20.safeTransferFrom` must revert on the false
///         return, so the deposit fails closed (no phantom credit).
contract ReturnsFalseBold is MockBold {
    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}
