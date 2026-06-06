// SPDX-License-Identifier: GPL-3.0-or-later
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

    function transfer(address to, uint256 value) external virtual returns (bool) {
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

/// @title ReentrantBold
/// @notice A BOLD mock whose `transferFrom` attempts to re-enter the
///         bridge's `depositBoldWithFee` mid-flight, testing that the
///         bridge's `nonReentrant` modifier rejects the inner call.  The
///         outer deposit's balance-delta check expects the inner call to
///         fail closed (so the outer transferFrom STILL moves `value`
///         tokens normally before the reentry attempt) — that's the
///         realistic attack shape an attacker would mount.  After the
///         test, `didReenter == true` (the malicious BOLD attempted
///         reentry) and `reentryWasBlocked == true` (the guard rejected
///         it).  Used by `BoldCircuitBreaker.t.sol`.
contract ReentrantBold is MockBold {
    /// @notice Address of the bridge to attempt reentry against.  Set
    ///         once after the etch.
    address public targetBridge;
    /// @notice Set to `true` the moment the malicious `transferFrom`
    ///         runs (regardless of whether the reentry call reverted).
    bool public didReenter;
    /// @notice Set to `true` iff the inner `depositBoldWithFee` call
    ///         reverted — i.e. the `nonReentrant` guard fired.
    bool public reentryWasBlocked;

    /// @notice Wire the bridge address for the reentry attempt.
    function setReentryTarget(address bridge_) external {
        targetBridge = bridge_;
    }

    function transferFrom(address from, address to, uint256 value)
        external
        override
        returns (bool)
    {
        // Standard transfer first so the OUTER deposit's balance-delta
        // check passes after this function returns.  An attacker would
        // do this exactly because the outer deposit must not abort —
        // they want the outer deposit to credit the malicious user
        // AND then double-credit via the reentrant inner call.
        uint256 a = _allowances[from][msg.sender];
        require(a >= value, "RBOLD: allowance");
        unchecked {
            _allowances[from][msg.sender] = a - value;
        }
        require(_balances[from] >= value, "RBOLD: balance");
        unchecked {
            _balances[from] -= value;
        }
        _balances[to] += value;
        emit Transfer(from, to, value);

        // Attempt reentry into the bridge's `nonReentrant`
        // `depositBoldWithFee`.  The reentrancy guard MUST reject this.
        didReenter = true;
        (bool ok,) = targetBridge.call(
            abi.encodeWithSignature("depositBoldWithFee(uint256,uint16)", uint256(1), uint16(0))
        );
        reentryWasBlocked = !ok;
        return true;
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
