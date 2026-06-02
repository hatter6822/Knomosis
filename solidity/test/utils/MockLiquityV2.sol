// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {ILiquityV2TroveManager} from "src/interfaces/ILiquityV2TroveManager.sol";

/// @title MockLiquityV2TroveManager
/// @notice Programmable stand-in for a Liquity V2 collateral-branch
///         `TroveManager`, used by `BoldCircuitBreaker.t.sol` to drive
///         `KnomosisBridge.closeBoldCircuitIfAnyLiquityBranchShutdown`
///         (Workstream GP.5.5).
///
/// @dev    `shutdownTime()` returns a settable uint256: `0` while the
///         branch is operating normally; non-zero (e.g. the block
///         timestamp of branch shutdown) signals that BOLD's backing on
///         this branch is wound down.  The companion
///         `WrongSizeLiquityV2` / `OversizedLiquityV2` /
///         `ReentrantLiquityV2` / `MutatingLiquityV2` variants below
///         exercise the wrong-shape, reentry, and state-mutation-attempt
///         paths the bridge's staticcall-based read guards against.  The
///         constructor's code-presence guard
///         (`LiquityOracleHasNoCode`) is exercised separately by clearing
///         a constant TroveManager's code via `vm.etch(tm, hex"")` BEFORE
///         construction.
contract MockLiquityV2TroveManager is ILiquityV2TroveManager {
    uint256 private _shutdownTime;
    bool private _shouldRevert;

    /// @notice Set the `shutdownTime` future reads return.  Zero models
    ///         a healthy branch; non-zero models a shutdown branch.
    function setShutdownTime(uint256 t) external {
        _shutdownTime = t;
    }

    /// @notice When `true`, `shutdownTime()` reverts — modelling an
    ///         incompatible or faulting TroveManager.
    function setShouldRevert(bool shouldRevert_) external {
        _shouldRevert = shouldRevert_;
    }

    /// @inheritdoc ILiquityV2TroveManager
    function shutdownTime() external view returns (uint256) {
        require(!_shouldRevert, "MockLiquityV2TroveManager: shutdownTime read failed");
        return _shutdownTime;
    }
}

/// @title WrongSizeLiquityV2
/// @notice A mock at a Liquity TroveManager slot whose `shutdownTime()`
///         selector returns FEWER than 32 bytes (16) — modelling a
///         hypothetical Liquity-V2 ABI change.  The bridge's staticcall-
///         based read enforces `returndata.length == 32` and reverts
///         `LiquityV2ReadFailed` on any other length, so this fault
///         degrades cleanly rather than panic-reverting on a typed-`try`
///         decode failure.
contract WrongSizeLiquityV2 {
    /// @notice `shutdownTime()` returning 16 bytes (one half of a uint256
    ///         word).  Implemented in assembly because Solidity high-level
    ///         returns always emit a full-word encoding.
    function shutdownTime() external pure {
        assembly {
            return(0, 16)
        }
    }
}

/// @title OversizedLiquityV2
/// @notice A mock whose `shutdownTime()` returns MORE than 32 bytes (64).
///         The bridge's strict `returndata.length == 32` check rejects
///         this with `LiquityV2ReadFailed` — fail-closed on schema drift
///         even when the first word happens to decode to a sensible
///         shutdownTime.
contract OversizedLiquityV2 {
    /// @notice Emit 64 bytes: a sentinel non-zero shutdownTime in the
    ///         first word and zero in the second.  A `data.length >= 32`
    ///         policy would silently accept the first word; the strict
    ///         `== 32` policy in `KnomosisBridge` does not.
    function shutdownTime() external pure {
        assembly {
            mstore(0, 9999)
            mstore(32, 0)
            return(0, 64)
        }
    }
}

/// @title ReentrantLiquityV2
/// @notice Re-entrant Liquity TroveManager that probes a bridge view
///         during `shutdownTime()`.  The bridge reads each TroveManager
///         via `staticcall`, so the EVM forbids any SSTORE in the inner
///         frame: a malicious TroveManager cannot mutate bridge state
///         during the read.  This mock confirms the property positively —
///         a VIEW probe (`bridge.boldCircuitClosed()`) succeeds and the
///         outer close completes correctly.
contract ReentrantLiquityV2 is ILiquityV2TroveManager {
    /// @notice Address of the target bridge for the view probe.
    address public targetBridge;
    uint256 private _shutdownTime;

    /// @notice Set the shutdownTime the read returns.
    function setShutdownTime(uint256 t) external {
        _shutdownTime = t;
    }

    /// @notice Wire the bridge address for the view probe.
    function setTargetBridge(address bridge_) external {
        targetBridge = bridge_;
    }

    /// @inheritdoc ILiquityV2TroveManager
    function shutdownTime() external view returns (uint256) {
        // Probe a bridge view.  Under the bridge's staticcall this
        // succeeds with `boldCircuitClosed == false` (the outer caller
        // is mid-execution and has not yet set the flag); any attempt
        // to SSTORE during this inner frame would revert (EVM staticcall
        // semantics), so a re-entrant TroveManager CANNOT corrupt state.
        (bool ok,) = targetBridge.staticcall(abi.encodeWithSignature("boldCircuitClosed()"));
        require(ok, "ReentrantLiquityV2: view probe failed");
        return _shutdownTime;
    }
}

/// @title MutatingLiquityV2
/// @notice Adversarial mock that ATTEMPTS to SSTORE during
///         `shutdownTime()` — testing the positive claim that the
///         bridge's staticcall-based read forbids state mutation by the
///         callee.  The Solidity `view` modifier is bypassed via inline
///         assembly so the compiler accepts the function, but at runtime
///         the staticcall context causes the SSTORE to revert, and the
///         bridge sees `success = false → LiquityV2ReadFailed`.
contract MutatingLiquityV2 {
    /// @notice A slot used by the mutating attempt.  Its value would
    ///         change if the bridge called this directly (NOT via
    ///         staticcall), which is why the staticcall guard matters.
    uint256 public counter;

    /// @notice Shares the selector `shutdownTime()` with
    ///         `ILiquityV2TroveManager.shutdownTime()` so the bridge's
    ///         staticcall reaches this implementation.  Declared
    ///         non-`view` because Solidity's static-check correctly
    ///         refuses to compile a `view` function containing
    ///         `sstore`; the EVM still enforces the staticcall context
    ///         at runtime, reverting the SSTORE attempt and routing the
    ///         outer call to `LiquityV2ReadFailed`.  The function never
    ///         returns under the staticcall — the EVM reverts first.
    function shutdownTime() external {
        assembly {
            // counter is the first storage slot (slot 0).
            sstore(0, add(sload(0), 1))
        }
    }
}
