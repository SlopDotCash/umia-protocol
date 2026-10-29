// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TickSlew
/// @notice Moves an accepted tick toward the pool's tick at a fixed speed in log-price space and
///         integrates the path exactly. A TWAP built on the accepted tick credits a new price only as
///         fast as the speed allows.
/// @dev Pure arithmetic shared by the spot and conditional oracles; each passes its own speed. The
///      ramp toward the target and the hold after it are integrated exactly, carrying the fractional
///      area between calls. The spot oracle uses a high speed and barely lags. The conditional oracle
///      uses a low one, so a price has to be held for hours, not minutes, before the settlement TWAP
///      follows it.
library TickSlew {
    /// @dev Tick-area values are carried at `2 * rate` so a linear ramp can be integrated exactly
    ///      across any partitioning of the same time interval. The remainder is in [0, 2 * rate).
    function areaScale(uint24 ticksPerSecond) internal pure returns (uint24) {
        return 2 * ticksPerSecond;
    }

    /// @dev Integrates a linear slew at `ticksPerSecond` followed by a hold, returning whole
    ///      tick-seconds plus carry. The scaled area is `(start + end) * travel + 2 * end * (rate * dt - travel)`.
    function advance(
        int24 previousTick,
        int24 targetTick,
        uint32 delta,
        uint16 tickAreaRemainder,
        uint24 ticksPerSecond
    ) internal pure returns (int24 nextTick, int48 tickCumulativeDelta, uint16 tickAreaRemainderUpdated) {
        unchecked {
            int256 tickDelta = int256(targetTick) - int256(previousTick);
            uint256 distance = uint256(tickDelta < 0 ? -tickDelta : tickDelta);
            uint256 travelBudget = uint256(ticksPerSecond) * delta;
            uint256 travel = distance < travelBudget ? distance : travelBudget;

            int256 next = int256(previousTick);
            if (tickDelta > 0) next += int256(travel);
            else if (tickDelta < 0) next -= int256(travel);

            int256 tickAreaNumerator = (int256(previousTick) + next) * int256(travel) + 2 * next
                * int256(travelBudget - travel) + int256(uint256(tickAreaRemainder));

            int256 scale = int256(uint256(areaScale(ticksPerSecond)));
            int256 wholeTickArea = tickAreaNumerator / scale;
            int256 remainder = tickAreaNumerator % scale;
            // Solidity truncates signed division toward zero. Convert it to floor division so the
            // remainder is canonical in [0, scale), even when the accumulated path crosses zero.
            if (remainder < 0) {
                wholeTickArea--;
                remainder += scale;
            }

            nextTick = int24(next);
            tickCumulativeDelta = int48(wholeTickArea);
            tickAreaRemainderUpdated = uint16(uint256(remainder));
        }
    }
}
