// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// @title ILiquityV2Redemptions
/// @notice Minimal read-only view of the Liquity V2 redemption-rate
///         accumulator, consulted by `KnomosisBridge`'s permissionless
///         BOLD depeg auto-trigger (`closeBoldCircuitIfRedeemingHeavily`,
///         Workstream GP.5.5).
///
/// @dev    Liquity V2's own redemption mechanism is the canonical
///         on-chain depeg signal for BOLD: when BOLD trades below peg,
///         arbitrageurs redeem against the lowest-interest-rate troves,
///         which raises the redemption-rate accumulator.  A sustained
///         elevated rate is therefore a trust-minimised "BOLD is under
///         peg pressure" indicator that requires no external price
///         oracle.
///
///         Only the single `getRedemptionRate()` view is declared so the
///         coupling to Liquity V2 is as narrow as possible; the rate is
///         returned in basis points (1e-4).  The bridge wraps every call
///         in `try`/`catch` and a code-presence pre-check so an
///         incompatible / absent oracle degrades to a clean
///         `LiquityV2ReadFailed` rather than an opaque revert, letting
///         the operator fall back to the manual `closeBoldCircuit()`
///         path.
interface ILiquityV2Redemptions {
    /// @notice The current BOLD redemption rate, in basis points
    ///         (`10000` == 100%).  Higher values signal heavier
    ///         redemption activity, i.e. stronger downward peg pressure.
    function getRedemptionRate() external view returns (uint256);
}
