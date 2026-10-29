// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Derived from Uniswap v4-periphery `TruncatedOracle.sol`, commit
// 2a25dae90d75e68195129951b244c9e3fd1bdd8c.
//
// Copyright 2023 Universal Navigation Inc.
// Distributed under the MIT License; the permission notice is reproduced in
// smart-contracts/licenses/MIT_LICENSE.

import {TickSlew} from "./TickSlew.sol";

/// @title Oracle
/// @notice Provides price and liquidity data useful for a wide variety of system designs
/// @dev Instances of stored oracle data, "observations", are collected in the oracle array
/// Every pool is initialized with an oracle array length of 1. Anyone can pay the SSTOREs to increase the
/// maximum length of the oracle array. New slots will be added when the array is fully populated.
/// Observations are overwritten when the full length of the oracle array is populated.
/// The most recent observation is available, independent of the length of the oracle array, by passing 0 to observe()
library SpotMarketOracle {
    /// @notice Rate at which the accepted tick can approach the pool tick.
    /// @dev 4,558 ticks/second preserves the former 9,116-tick allowance over a 2-second Base block,
    ///      while making the bound depend on elapsed time rather than the number of observations.
    uint24 internal constant TICK_SLEW_PER_SECOND = 4558;

    /// @notice Thrown when trying to interact with an Oracle of a non-initialized pool
    error OracleCardinalityCannotBeZero();

    /// @notice Thrown when trying to observe a price that is older than the oldest recorded price
    /// @param oldestTimestamp Timestamp of the oldest remaining observation
    /// @param targetTimestamp Invalid timestamp targeted to be observed
    error TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp);

    struct Observation {
        // the block timestamp of the observation
        uint32 blockTimestamp;
        // the previous accepted tick from which the slew-limited path continues
        int24 prevTick;
        // the tick accumulator, i.e. tick * time elapsed since the pool was first initialized
        int48 tickCumulative;
        // the seconds per liquidity, i.e. seconds elapsed / max(1, liquidity) since the pool was first initialized
        uint144 secondsPerLiquidityCumulativeX128;
        // whether or not the observation is initialized
        bool initialized;
    }

    /// @notice Advances the accepted tick toward the pool tick and integrates its continuous path.
    /// @dev The accepted tick moves linearly at `TICK_SLEW_PER_SECOND` until it reaches `tick`,
    ///      then remains there for the rest of the interval. `tickAreaRemainder` carries the exact
    ///      fractional tick-seconds between writes, making the result independent of write cadence.
    /// @dev blockTimestamp _must_ be chronologically equal to or greater than last.blockTimestamp, safe for 0 or 1 overflows
    /// @param last The specified observation to be transformed
    /// @param blockTimestamp The timestamp of the new observation
    /// @param tick The active tick at the time of the new observation
    /// @param liquidity The total in-range liquidity at the time of the new observation
    /// @param tickAreaRemainder Non-negative numerator left over from the previous tick-area division
    /// @return next The newly populated observation
    /// @return tickAreaRemainderUpdated Non-negative numerator to carry into the next transformation
    function transform(
        Observation memory last,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 tickAreaRemainder
    ) private pure returns (Observation memory next, uint16 tickAreaRemainderUpdated) {
        unchecked {
            uint32 delta = blockTimestamp - last.blockTimestamp;
            int48 tickCumulativeDelta;
            (tick, tickCumulativeDelta, tickAreaRemainderUpdated) =
                TickSlew.advance(last.prevTick, tick, delta, tickAreaRemainder, TICK_SLEW_PER_SECOND);

            next = Observation({
                blockTimestamp: blockTimestamp,
                prevTick: tick,
                tickCumulative: last.tickCumulative + tickCumulativeDelta,
                secondsPerLiquidityCumulativeX128: last.secondsPerLiquidityCumulativeX128
                    + ((uint144(delta) << 128) / (liquidity > 0 ? liquidity : 1)),
                initialized: true
            });
        }
    }

    /// @notice Initialize the oracle array by writing the first slot. Called once for the lifecycle of the observations array
    /// @param self The stored oracle array
    /// @param time The time of the oracle initialization, via block.timestamp truncated to uint32
    /// @return cardinality The number of populated elements in the oracle array
    /// @return cardinalityNext The new length of the oracle array, independent of population
    function initialize(Observation[65535] storage self, uint32 time, int24 tick)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        self[0] = Observation({
            blockTimestamp: time,
            prevTick: tick,
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });
        return (1, 1);
    }

    /// @notice Writes an oracle observation to the array
    /// @dev Writable at most once per block. Index represents the most recently written element. cardinality and index must be tracked externally.
    /// If the index is at the end of the allowable array length (according to cardinality), and the next cardinality
    /// is greater than the current one, cardinality may be increased. This restriction is created to preserve ordering.
    /// @param self The stored oracle array
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param blockTimestamp The timestamp of the new observation
    /// @param tick The active tick at the time of the new observation
    /// @param liquidity The total in-range liquidity at the time of the new observation
    /// @param cardinality The number of populated elements in the oracle array
    /// @param cardinalityNext The new length of the oracle array, independent of population
    /// @param tickAreaRemainder Fractional tick-area numerator carried from the previous write
    /// @return indexUpdated The new index of the most recently written element in the oracle array
    /// @return cardinalityUpdated The new cardinality of the oracle array
    /// @return tickAreaRemainderUpdated Fractional tick-area numerator for the next write
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext,
        uint16 tickAreaRemainder
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated, uint16 tickAreaRemainderUpdated) {
        unchecked {
            Observation memory last = self[index];

            // early return if we've already written an observation this block
            if (last.blockTimestamp == blockTimestamp) return (index, cardinality, tickAreaRemainder);

            // if the conditions are right, we can bump the cardinality
            if (cardinalityNext > cardinality && index == (cardinality - 1)) {
                cardinalityUpdated = cardinalityNext;
            } else {
                cardinalityUpdated = cardinality;
            }

            indexUpdated = (index + 1) % cardinalityUpdated;
            (self[indexUpdated], tickAreaRemainderUpdated) =
                transform(last, blockTimestamp, tick, liquidity, tickAreaRemainder);
        }
    }

    /// @notice Stores a pre-computed observation verbatim at the next slot (unlike `write`, which
    ///         transforms). Used to downsample a denser ring's cumulative. Indexing mirrors `write`.
    /// @dev The verbatim copy carries `prevTick` from the source observation. Coarse-ring reads never
    ///      extrapolate (`UmiaHook.observeLong` routes targets newer than the newest checkpoint to the
    ///      fine ring), so it goes unused; keep the copy intact in case a future read path transforms.
    function writeSnapshot(
        Observation[65535] storage self,
        uint16 index,
        Observation memory snapshot,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        unchecked {
            // Defense-in-depth for future callers: unreachable from the hook, whose bucket
            // gate already guarantees a fresh timestamp. Mirrors write's per-block dedup.
            if (self[index].blockTimestamp == snapshot.blockTimestamp) return (index, cardinality);

            if (cardinalityNext > cardinality && index == (cardinality - 1)) {
                cardinalityUpdated = cardinalityNext;
            } else {
                cardinalityUpdated = cardinality;
            }

            indexUpdated = (index + 1) % cardinalityUpdated;
            self[indexUpdated] = snapshot;
        }
    }

    /// @notice Prepares the oracle array to store up to `next` observations
    /// @param self The stored oracle array
    /// @param current The current next cardinality of the oracle array
    /// @param next The proposed next cardinality which will be populated in the oracle array
    /// @return next The next cardinality which will be populated in the oracle array
    function grow(Observation[65535] storage self, uint16 current, uint16 next) internal returns (uint16) {
        unchecked {
            if (current == 0) revert OracleCardinalityCannotBeZero();
            // no-op if the passed next value isn't greater than the current next value
            if (next <= current) return current;
            // store in each slot to prevent fresh SSTOREs in swaps
            // this data will not be used because the initialized boolean is still false
            for (uint16 i = current; i < next; i++) {
                self[i].blockTimestamp = 1;
            }
            return next;
        }
    }

    /// @notice comparator for 32-bit timestamps
    /// @dev safe for 0 or 1 overflows, a and b _must_ be chronologically before or equal to time
    /// @param time A timestamp truncated to 32 bits
    /// @param a A comparison timestamp from which to determine the relative position of `time`
    /// @param b From which to determine the relative position of `time`
    /// @return Whether `a` is chronologically <= `b`
    function lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        unchecked {
            // if there hasn't been overflow, no need to adjust
            if (a <= time && b <= time) return a <= b;

            uint256 aAdjusted = a > time ? a : a + 2 ** 32;
            uint256 bAdjusted = b > time ? b : b + 2 ** 32;

            return aAdjusted <= bAdjusted;
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a target, i.e. where [beforeOrAt, atOrAfter] is satisfied.
    /// The result may be the same observation, or adjacent observations.
    /// @dev The answer must be contained in the array, used when the target is located within the stored observation
    /// boundaries: older than the most recent observation and younger, or the same age as, the oldest observation
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation recorded before, or at, the target
    /// @return atOrAfter The observation recorded at, or after, the target
    function binarySearch(Observation[65535] storage self, uint32 time, uint32 target, uint16 index, uint16 cardinality)
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        unchecked {
            uint256 l = (index + 1) % cardinality; // oldest observation
            uint256 r = l + cardinality - 1; // newest observation
            uint256 i;
            while (true) {
                i = (l + r) / 2;

                beforeOrAt = self[i % cardinality];

                // we've landed on an uninitialized tick, keep searching higher (more recently)
                if (!beforeOrAt.initialized) {
                    l = i + 1;
                    continue;
                }

                atOrAfter = self[(i + 1) % cardinality];

                bool targetAtOrAfter = lte(time, beforeOrAt.blockTimestamp, target);

                // check if we've found the answer!
                if (targetAtOrAfter && lte(time, target, atOrAfter.blockTimestamp)) break;

                if (!targetAtOrAfter) r = i - 1;
                else l = i + 1;
            }
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a given target, i.e. where [beforeOrAt, atOrAfter] is satisfied
    /// @dev Assumes there is at least 1 initialized observation.
    /// Used by observeSingle() to compute the counterfactual accumulator values as of a given block timestamp.
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param tick The active tick at the time of the returned or simulated observation
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The total pool liquidity at the time of the call
    /// @param cardinality The number of populated elements in the oracle array
    /// @param tickAreaRemainder Fractional tick-area numerator carried by the newest observation
    /// @return beforeOrAt The observation which occurred at, or before, the given timestamp
    /// @return atOrAfter The observation which occurred at, or after, the given timestamp
    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality,
        uint16 tickAreaRemainder
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        unchecked {
            // optimistically set before to the newest observation
            beforeOrAt = self[index];

            // if the target is chronologically at or after the newest observation, we can early return
            if (lte(time, beforeOrAt.blockTimestamp, target)) {
                if (beforeOrAt.blockTimestamp == target) {
                    // if newest observation equals target, we're in the same block, so we can ignore atOrAfter
                    return (beforeOrAt, atOrAfter);
                } else {
                    // otherwise, we need to transform
                    (Observation memory transformed,) =
                        transform(beforeOrAt, target, tick, liquidity, tickAreaRemainder);
                    return (beforeOrAt, transformed);
                }
            }

            // now, set before to the oldest observation
            beforeOrAt = self[(index + 1) % cardinality];
            if (!beforeOrAt.initialized) beforeOrAt = self[0];

            // ensure that the target is chronologically at or after the oldest observation
            if (!lte(time, beforeOrAt.blockTimestamp, target)) {
                revert TargetPredatesOldestObservation(beforeOrAt.blockTimestamp, target);
            }

            // if we've reached this point, we have to binary search
            return binarySearch(self, time, target, index, cardinality);
        }
    }

    /// @dev Reverts if an observation at or before the desired observation timestamp does not exist.
    /// 0 may be passed as `secondsAgo' to return the current cumulative values.
    /// If called with a timestamp falling between two observations, returns the counterfactual accumulator values
    /// at exactly the timestamp between the two observations.
    /// @param self The stored oracle array
    /// @param time The current block timestamp
    /// @param secondsAgo The amount of time to look back, in seconds, at which point to return an observation
    /// @param tick The current tick
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The current in-range pool liquidity
    /// @param cardinality The number of populated elements in the oracle array
    /// @param tickAreaRemainder Fractional tick-area numerator carried by the newest observation
    /// @return tickCumulative The tick * time elapsed since the pool was first initialized, as of `secondsAgo`
    /// @return secondsPerLiquidityCumulativeX128 The time elapsed / max(1, liquidity) since the pool was first initialized, as of `secondsAgo`
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality,
        uint16 tickAreaRemainder
    ) internal view returns (int48 tickCumulative, uint144 secondsPerLiquidityCumulativeX128) {
        unchecked {
            if (secondsAgo == 0) {
                Observation memory last = self[index];
                if (last.blockTimestamp != time) {
                    (last,) = transform(last, time, tick, liquidity, tickAreaRemainder);
                }
                return (last.tickCumulative, last.secondsPerLiquidityCumulativeX128);
            }

            uint32 target = time - secondsAgo;
            (Observation memory beforeOrAt, Observation memory atOrAfter) =
                getSurroundingObservations(self, time, target, tick, index, liquidity, cardinality, tickAreaRemainder);

            if (target == beforeOrAt.blockTimestamp) {
                return (beforeOrAt.tickCumulative, beforeOrAt.secondsPerLiquidityCumulativeX128);
            }
            if (target == atOrAfter.blockTimestamp) {
                return (atOrAfter.tickCumulative, atOrAfter.secondsPerLiquidityCumulativeX128);
            }
            return interpolate(beforeOrAt, atOrAfter, target);
        }
    }

    /// @dev Both cumulatives on the straight line between two observations, at a `target` strictly
    ///      between them. Multiplies before dividing: after a ramp the cumulative delta is not a
    ///      multiple of the time delta, and dividing first would truncate the slope for the whole
    ///      interval. The deltas are taken at the cumulatives' own width, since both are allowed to
    ///      wrap and only the difference is meaningful.
    function interpolate(Observation memory beforeOrAt, Observation memory atOrAfter, uint32 target)
        internal
        pure
        returns (int48 tickCumulative, uint144 secondsPerLiquidityCumulativeX128)
    {
        unchecked {
            uint256 span = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
            uint256 elapsed = target - beforeOrAt.blockTimestamp;
            int256 tickDelta = int256(atOrAfter.tickCumulative - beforeOrAt.tickCumulative);
            uint256 liquidityDelta =
                uint256(atOrAfter.secondsPerLiquidityCumulativeX128 - beforeOrAt.secondsPerLiquidityCumulativeX128);
            tickCumulative = beforeOrAt.tickCumulative + int48(tickDelta * int256(elapsed) / int256(span));
            secondsPerLiquidityCumulativeX128 =
                beforeOrAt.secondsPerLiquidityCumulativeX128 + uint144(liquidityDelta * elapsed / span);
        }
    }

    /// @notice Returns the accumulator values as of each time seconds ago from the given time in the array of `secondsAgos`
    /// @dev Reverts if `secondsAgos` > oldest observation
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param secondsAgos Each amount of time to look back, in seconds, at which point to return an observation
    /// @param tick The current tick
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The current in-range pool liquidity
    /// @param cardinality The number of populated elements in the oracle array
    /// @param tickAreaRemainder Fractional tick-area numerator carried by the newest observation
    /// @return tickCumulatives The tick * time elapsed since the pool was first initialized, as of each `secondsAgo`
    /// @return secondsPerLiquidityCumulativeX128s The cumulative seconds / max(1, liquidity) since the pool was first initialized, as of each `secondsAgo`
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality,
        uint16 tickAreaRemainder
    ) internal view returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) {
        unchecked {
            if (cardinality == 0) revert OracleCardinalityCannotBeZero();

            tickCumulatives = new int48[](secondsAgos.length);
            secondsPerLiquidityCumulativeX128s = new uint144[](secondsAgos.length);
            for (uint256 i = 0; i < secondsAgos.length; i++) {
                (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) =
                    observeSingle(self, time, secondsAgos[i], tick, index, liquidity, cardinality, tickAreaRemainder);
            }
        }
    }
}
