// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpotMarketOracle} from "../../src/libraries/SpotMarketOracle.sol";

contract SpotMarketOracleHarness {
    using SpotMarketOracle for SpotMarketOracle.Observation[65535];

    SpotMarketOracle.Observation[65535] internal observations;
    uint16 internal index;
    uint16 internal cardinality;
    uint16 internal cardinalityNext;
    uint16 internal tickAreaRemainder;

    function initialize(uint32 time, int24 tick) external {
        (cardinality, cardinalityNext) = observations.initialize(time, tick);
    }

    function grow(uint16 next) external {
        cardinalityNext = observations.grow(cardinalityNext, next);
    }

    function write(uint32 time, int24 tick) external {
        (index, cardinality, tickAreaRemainder) =
            observations.write(index, time, tick, 1, cardinality, cardinalityNext, tickAreaRemainder);
    }

    function observeNow(uint32 time, int24 tick) external view returns (int48 tickCumulative) {
        (tickCumulative,) = observations.observeSingle(time, 0, tick, index, 1, cardinality, tickAreaRemainder);
    }

    function observeAgo(uint32 time, uint32 secondsAgo, int24 tick) external view returns (int48 tickCumulative) {
        (tickCumulative,) = observations.observeSingle(time, secondsAgo, tick, index, 1, cardinality, tickAreaRemainder);
    }

    function observeAgoLiquidity(uint32 time, uint32 secondsAgo, int24 tick)
        external
        view
        returns (uint144 secondsPerLiquidityCumulativeX128)
    {
        (, secondsPerLiquidityCumulativeX128) =
            observations.observeSingle(time, secondsAgo, tick, index, 1, cardinality, tickAreaRemainder);
    }

    function latest()
        external
        view
        returns (uint32 timestamp, int24 acceptedTick, int48 tickCumulative, uint16 remainder)
    {
        SpotMarketOracle.Observation storage observation = observations[index];
        return (observation.blockTimestamp, observation.prevTick, observation.tickCumulative, tickAreaRemainder);
    }
}

contract SpotMarketOracleSlewTest is Test {
    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;
    uint32 internal constant T0 = 1_000_000;

    /// @notice A target between two observations is read off the straight line between them. After a
    ///         ramp the cumulative delta is not a multiple of the time delta, and dividing before
    ///         multiplying truncated the slope for the whole interval (audit L-06).
    function test_InterpolationKeepsTheSlope() public {
        SpotMarketOracleHarness oracle = new SpotMarketOracleHarness();
        oracle.initialize(T0, 0);
        oracle.grow(4);
        // The ramp from 0 to 1999 sits inside the first interval; read its start, middle and end.
        oracle.write(T0 + 1000, 1999);
        int48 startCumulative = oracle.observeAgo(T0 + 1000, 1000, 1999);
        int48 endCumulative = oracle.observeAgo(T0 + 1000, 0, 1999);
        int48 delta = endCumulative - startCumulative;
        assertTrue(delta % 1000 != 0, "the ramp leaves a fractional slope");
        int48 mid = oracle.observeAgo(T0 + 1000, 500, 1999);
        assertEq(mid - startCumulative, delta * 500 / 1000);
        assertApproxEqAbs(int256(mid) * 2, int256(startCumulative) + int256(endCumulative), 1);
    }

    /// @notice Both cumulatives wrap at their own width; interpolating across a wrap must take the
    ///         delta at that width, not after widening.
    function test_InterpolationAcrossCumulativeWrap() public {
        SpotMarketOracleHarness oracle = new SpotMarketOracleHarness();
        // Liquidity 1 adds 2^128 per second, so the uint144 cumulative wraps every 65,536 seconds.
        oracle.initialize(T0, 0);
        oracle.grow(4);
        oracle.write(T0 + 65_534, 0);
        oracle.write(T0 + 65_538, 0);
        assertEq(oracle.observeAgoLiquidity(T0 + 65_538, 2, 0), 0, "midpoint sits exactly on the wrap");
        assertEq(oracle.observeAgoLiquidity(T0 + 65_538, 3, 0), uint144(65_535) << 128);

        // At MAX_TICK the int48 tick cumulative wraps after about 158.6 million seconds; the second
        // observation sits past that point, the first just before it.
        SpotMarketOracleHarness ticks = new SpotMarketOracleHarness();
        ticks.initialize(T0, MAX_TICK);
        ticks.grow(4);
        ticks.write(T0 + 158_000_000, MAX_TICK);
        ticks.write(T0 + 160_000_000, MAX_TICK);
        assertGt(int256(MAX_TICK) * 160_000_000, int256(type(int48).max), "the second write is past the wrap");
        assertEq(ticks.observeAgo(T0 + 160_000_000, 1_000_000, MAX_TICK), int48(int256(MAX_TICK) * 159_000_000));
    }

    function test_TwoSecondAllowanceMatchesFormerPerObservationCap() public {
        SpotMarketOracleHarness oracle = new SpotMarketOracleHarness();
        oracle.initialize(T0, 0);
        oracle.write(T0 + 2, 30_000);

        (, int24 acceptedTick, int48 tickCumulative, uint16 remainder) = oracle.latest();
        assertEq(acceptedTick, int24(9_116), "two seconds allow the former 9,116-tick move");
        assertEq(tickCumulative, int48(9_116), "a full two-second ramp has a 4,558-tick average");
        assertEq(remainder, uint16(0), "the exact full-rate ramp leaves no fraction");
    }

    function test_SameTimestampWritePreservesFractionalCarry() public {
        SpotMarketOracleHarness oracle = new SpotMarketOracleHarness();
        oracle.initialize(T0, 0);
        oracle.write(T0 + 1, 1);

        (uint32 timestampBefore, int24 tickBefore, int48 cumulativeBefore, uint16 remainderBefore) = oracle.latest();
        assertEq(remainderBefore, uint16(9_115), "one-tick ramp retains its fractional area");

        oracle.write(T0 + 1, -1);
        (uint32 timestampAfter, int24 tickAfter, int48 cumulativeAfter, uint16 remainderAfter) = oracle.latest();
        assertEq(timestampAfter, timestampBefore);
        assertEq(tickAfter, tickBefore);
        assertEq(cumulativeAfter, cumulativeBefore);
        assertEq(remainderAfter, remainderBefore, "same-block dedup must not discard the carry");
    }

    function test_CounterfactualAndPersistedAdvanceMatch() public {
        SpotMarketOracleHarness oracle = new SpotMarketOracleHarness();
        oracle.initialize(T0, -12_345);

        int48 projected = oracle.observeNow(T0 + 37, 54_321);
        oracle.write(T0 + 37, 54_321);
        (,, int48 persisted,) = oracle.latest();

        assertEq(projected, persisted, "view and write paths must use identical slew integration");
    }

    /// @notice Splitting a constant raw-tick interval into arbitrary updates must not let a caller
    ///         ratchet the accepted tick faster or change the integrated tick area through rounding.
    function testFuzz_ConstantTargetIsCadenceIndependent(
        int24 startTick,
        int24 targetTick,
        uint8 writeCountSeed,
        uint8 spacingSeed
    ) public {
        startTick = int24(bound(int256(startTick), int256(MIN_TICK), int256(MAX_TICK)));
        targetTick = int24(bound(int256(targetTick), int256(MIN_TICK), int256(MAX_TICK)));
        uint32 writeCount = uint32(bound(uint256(writeCountSeed), 1, 64));
        uint32 spacing = uint32(bound(uint256(spacingSeed), 1, 120));

        SpotMarketOracleHarness sparse = new SpotMarketOracleHarness();
        SpotMarketOracleHarness dense = new SpotMarketOracleHarness();
        sparse.initialize(T0, startTick);
        dense.initialize(T0, startTick);

        uint32 end = T0 + writeCount * spacing;
        sparse.write(end, targetTick);
        for (uint32 i = 1; i <= writeCount; i++) {
            dense.write(T0 + i * spacing, targetTick);
        }

        (uint32 sparseTimestamp, int24 sparseTick, int48 sparseCumulative, uint16 sparseRemainder) = sparse.latest();
        (uint32 denseTimestamp, int24 denseTick, int48 denseCumulative, uint16 denseRemainder) = dense.latest();
        assertEq(denseTimestamp, sparseTimestamp);
        assertEq(denseTick, sparseTick, "update count must not accelerate the accepted tick");
        assertEq(denseCumulative, sparseCumulative, "tick area must be cadence-independent");
        assertEq(denseRemainder, sparseRemainder, "fractional area must be cadence-independent");
    }
}
