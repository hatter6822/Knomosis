// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {ILiquityV2Redemptions} from "src/interfaces/ILiquityV2Redemptions.sol";

/// @title MockLiquityV2
/// @notice Programmable stand-in for the Liquity V2 redemption-rate
///         oracle, used by `BoldCircuitBreaker.t.sol` to drive
///         `KnomosisBridge.closeBoldCircuitIfRedeemingHeavily`
///         (Workstream GP.5.5).
///
/// @dev    `getRedemptionRate()` returns a settable rate (bps).  A
///         `shouldRevert` toggle exercises the bridge's revert-on-oracle
///         path → `LiquityV2ReadFailed`, simulating an incompatible /
///         broken Liquity oracle.  The companion `WrongSizeLiquityV2` /
///         `OversizedLiquityV2` / `ReentrantLiquityV2` variants below
///         exercise the wrong-shape and reentry paths the bridge's
///         staticcall-based read guards against.  The constructor's
///         code-presence guard (`LiquityOracleHasNoCode`) is exercised
///         separately by pointing the bridge at a code-less address.
contract MockLiquityV2 is ILiquityV2Redemptions {
    uint256 private _rate;
    bool private _shouldRevert;

    /// @notice Set the redemption rate (basis points) future reads return.
    function setRate(uint256 rate) external {
        _rate = rate;
    }

    /// @notice When `true`, `getRedemptionRate()` reverts — modelling an
    ///         incompatible or faulting Liquity V2 oracle.
    function setShouldRevert(bool shouldRevert_) external {
        _shouldRevert = shouldRevert_;
    }

    /// @inheritdoc ILiquityV2Redemptions
    function getRedemptionRate() external view returns (uint256) {
        require(!_shouldRevert, "MockLiquityV2: redemption read failed");
        return _rate;
    }
}

/// @title WrongSizeLiquityV2
/// @notice A mock at the bridge's pinned oracle slot whose
///         `getRedemptionRate()` selector returns FEWER than 32 bytes
///         (16) — modelling a hypothetical Liquity-V2 ABI change.  The
///         bridge's staticcall-based read enforces `returndata.length ==
///         32` and reverts `LiquityV2ReadFailed` on any other length, so
///         this fault degrades cleanly rather than panic-reverting on a
///         typed-`try` decode failure.
contract WrongSizeLiquityV2 {
    /// @notice `getRedemptionRate()` returning 16 bytes (one half of a
    ///         uint256 word).  Implemented in assembly because Solidity
    ///         high-level returns always emit a full-word encoding.
    function getRedemptionRate() external pure {
        // forge-lint: disable-next-line(unused-state-var)
        assembly {
            return(0, 16)
        }
    }
}

/// @title OversizedLiquityV2
/// @notice A mock whose `getRedemptionRate()` returns MORE than 32 bytes
///         (64).  The bridge's strict `returndata.length == 32` check
///         rejects this with `LiquityV2ReadFailed` — fail-closed on
///         schema drift even when the first word happens to decode to a
///         sensible rate.
contract OversizedLiquityV2 {
    /// @notice Emit 64 bytes: a sentinel rate in the first word and
    ///         zero in the second.  A `data.length >= 32` policy would
    ///         silently accept the first word; the strict `== 32`
    ///         policy in `KnomosisBridge` does not.
    function getRedemptionRate() external pure {
        // forge-lint: disable-next-line(unused-state-var)
        assembly {
            mstore(0, 9999)
            mstore(32, 0)
            return(0, 64)
        }
    }
}

/// @title ReentrantLiquityV2
/// @notice Re-entrant Liquity-V2 oracle that probes a bridge view during
///         `getRedemptionRate()`.  The bridge reads the oracle via
///         `staticcall`, so the EVM forbids any SSTORE in the inner
///         frame: a malicious oracle cannot mutate bridge state during
///         the read.  This mock confirms the property positively — a
///         VIEW probe (`bridge.boldCircuitClosed()`) succeeds and the
///         outer close completes correctly — closing one of the auto-
///         trigger's stated soundness claims.
contract ReentrantLiquityV2 is ILiquityV2Redemptions {
    /// @notice Address of the target bridge for the view probe.  Set
    ///         once after the bridge is deployed (the bridge needs this
    ///         contract's address at construction, so the wiring is
    ///         one-shot post-construction).
    address public targetBridge;
    uint256 private _rate;

    /// @notice Set the redemption rate the read returns.
    function setRate(uint256 rate) external {
        _rate = rate;
    }

    /// @notice Wire the bridge address for the view probe.
    function setTargetBridge(address bridge_) external {
        targetBridge = bridge_;
    }

    /// @inheritdoc ILiquityV2Redemptions
    function getRedemptionRate() external view returns (uint256) {
        // Probe a bridge view.  Under the bridge's staticcall this
        // succeeds with `boldCircuitClosed == false` (the outer caller
        // is mid-execution and has not yet set the flag); any attempt
        // to SSTORE during this inner frame would revert (EVM staticcall
        // semantics), so a re-entrant oracle CANNOT corrupt state.
        (bool ok,) = targetBridge.staticcall(abi.encodeWithSignature("boldCircuitClosed()"));
        require(ok, "ReentrantLiquityV2: view probe failed");
        return _rate;
    }
}
