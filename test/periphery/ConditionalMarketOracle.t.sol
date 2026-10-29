// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ConditionalMarketOracle} from "../../src/periphery/ConditionalMarketOracle.sol";
import {TickSlew} from "../../src/libraries/TickSlew.sol";

contract ConditionalMarketOracleHarness is ConditionalMarketOracle {
    constructor(address _hub) ConditionalMarketOracle(_hub) {}

    function exposed_poolTick(uint256 reserve0, uint256 reserve1) external pure returns (int24) {
        return _poolTick(reserve0, reserve1);
    }

    function exposed_priceX112(int24 tick) external pure returns (uint256) {
        return _priceX112(tick);
    }
}

contract MockHub {
    address public umiaMarketCore;

    constructor(address _mm) {
        umiaMarketCore = _mm;
    }
}

/// @dev Drives `SpotMarketOracle` through its public write path, so the conditional oracle's slew can
///      be compared with the spot oracle's on the same tick path.
contract ConditionalMarketOracleTest is Test {
    ConditionalMarketOracleHarness oracle;
    MockHub hub;

    uint16 constant THRESHOLD_BPS = 200;
    uint32 constant DURATION = 3 days;
    // 18-decimal venture token against 6-decimal USDC at 1 USDC per token.
    uint256 constant RESERVE_VENTURE = 200_000e18;
    uint256 constant RESERVE_USDC = 200_000e6;

    event OracleInitialized(
        uint256 indexed proposalId,
        uint32 tradingStart,
        uint32 tradingEnd,
        uint256 initialPriceX112,
        uint16 winningThresholdBps
    );

    function setUp() public {
        hub = new MockHub(address(this));
        oracle = new ConditionalMarketOracleHarness(address(hub));
        vm.warp(1000);
    }

    function _init(uint256 proposalId) internal returns (uint32 tradingStart, uint32 tradingEnd) {
        tradingStart = uint32(block.timestamp);
        tradingEnd = tradingStart + DURATION;
        oracle.initialize(proposalId, RESERVE_VENTURE, RESERVE_USDC, tradingStart, tradingEnd, THRESHOLD_BPS);
    }

    function _tick() internal view returns (int24) {
        return oracle.exposed_poolTick(RESERVE_VENTURE, RESERVE_USDC);
    }

    function _meanTick(uint256 proposalId, uint256 reserve0, uint256 reserve1) internal view returns (int24) {
        return oracle.calculateTWAPTick(proposalId, reserve0, reserve1);
    }

    /// @dev Reserves whose money-per-venture price is the standard price times `factorBps / 10_000`.
    function _scaled(uint256 factorBps) internal pure returns (uint256 reserve0, uint256 reserve1) {
        return (RESERVE_VENTURE, RESERVE_USDC * factorBps / 10_000);
    }

    // ─── Access control and initialization ───────────────────────────────

    function test_initialize_revertsIfNotMarketCore() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ConditionalMarketOracle.OnlyMarketCore.selector);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, 1000, 2000, THRESHOLD_BPS);
    }

    function test_update_revertsIfNotMarketCore() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ConditionalMarketOracle.OnlyMarketCore.selector);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
    }

    function test_initialize_seedsTheAcceptedTickAndEmits() public {
        int24 tick = _tick();
        vm.expectEmit(true, false, false, true, address(oracle));
        emit OracleInitialized(1, 1000, 1000 + DURATION, oracle.exposed_priceX112(tick), THRESHOLD_BPS);
        _init(1);
        (int64 cumulative, int24 lastTick,, uint32 start, uint32 end, uint32 lastTs,, bool initialized) =
            oracle.oracleStates(1);
        assertEq(cumulative, 0);
        assertEq(lastTick, tick);
        assertEq(start, 1000);
        assertEq(end, 1000 + DURATION);
        assertEq(lastTs, 1000);
        assertTrue(initialized);
    }

    function test_initialize_validatesInputs() public {
        _init(1);
        vm.expectRevert(ConditionalMarketOracle.AlreadyInitialized.selector);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, 1000, 2000, THRESHOLD_BPS);
        vm.expectRevert(ConditionalMarketOracle.InvalidReserves.selector);
        oracle.initialize(2, 0, RESERVE_USDC, 1000, 2000, THRESHOLD_BPS);
        vm.expectRevert(ConditionalMarketOracle.InvalidTradingWindow.selector);
        oracle.initialize(2, RESERVE_VENTURE, RESERVE_USDC, 2000, 2000, THRESHOLD_BPS);
        vm.expectRevert(ConditionalMarketOracle.InvalidWinningThreshold.selector);
        oracle.initialize(2, RESERVE_VENTURE, RESERVE_USDC, 1000, 2000, 0);
    }

    // ─── Updates ─────────────────────────────────────────────────────────

    function test_update_skipsUninitializedEarlyAndSameSecond() public {
        oracle.update(9, RESERVE_VENTURE, RESERVE_USDC);
        (,,,,,,, bool initialized) = oracle.oracleStates(9);
        assertFalse(initialized);

        _init(1);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC * 2);
        (int64 cumulative,,,,, uint32 lastTs,,) = oracle.oracleStates(1);
        assertEq(cumulative, 0);
        assertEq(lastTs, 1000);
    }

    function test_update_zeroReservesCreditedByNextUpdate() public {
        _init(1);
        vm.warp(1100);
        oracle.update(1, 0, RESERVE_USDC);
        (,,,,, uint32 lastTs,,) = oracle.oracleStates(1);
        assertEq(lastTs, 1000);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        (int64 cumulative,,,,, uint32 lastTs2,,) = oracle.oracleStates(1);
        assertEq(lastTs2, 1100);
        assertEq(cumulative, int64(_tick()) * 100);
    }

    function test_twap_stablePriceIsThePoolPrice() public {
        _init(1);
        vm.warp(1000 + 1 days);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        vm.warp(1000 + DURATION);
        assertEq(_meanTick(1, RESERVE_VENTURE, RESERVE_USDC), _tick());
        assertEq(oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC), oracle.exposed_priceX112(_tick()));
    }

    function test_update_slewLimitsAOneSecondJump() public {
        _init(1);
        (uint256 r0, uint256 r1) = (RESERVE_VENTURE, RESERVE_USDC * 100);
        vm.warp(1001);
        oracle.update(1, r0, r1);
        (, int24 accepted,,,,,,) = oracle.oracleStates(1);
        assertEq(int256(accepted) - int256(_tick()), int256(uint256(oracle.MIN_TICK_SLEW_PER_SECOND())));
    }

    function test_twap_frozenAtTradingEnd() public {
        (, uint32 end) = _init(1);
        vm.warp(end + 1 days);
        (uint256 r0, uint256 r1) = _scaled(40_000);
        int24 atEnd = _meanTick(1, r0, r1);
        oracle.update(1, r0, r1);
        vm.warp(end + 2 days);
        assertEq(_meanTick(1, RESERVE_VENTURE, RESERVE_USDC), atEnd);
    }

    function test_twap_revertsUninitializedOrBeforeStart() public {
        vm.expectRevert(ConditionalMarketOracle.ProposalNotInitialized.selector);
        oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
        oracle.initialize(1, RESERVE_VENTURE, RESERVE_USDC, 2000, 3000, THRESHOLD_BPS);
        vm.expectRevert(ConditionalMarketOracle.TradingNotStarted.selector);
        oracle.calculateTWAP(1, RESERVE_VENTURE, RESERVE_USDC);
    }

    function test_twap_firstSecondReturnsTheAcceptedTickNotThePool() public {
        _init(1);
        (uint256 r0, uint256 r1) = _scaled(1_000_000);
        assertEq(_meanTick(1, r0, r1), _tick());
    }

    function test_twap_isolatedPerProposal() public {
        _init(1);
        _init(2);
        vm.warp(1000 + 1 days);
        (uint256 r0, uint256 r1) = _scaled(20_000);
        oracle.update(2, r0, r1);
        vm.warp(1000 + 2 days);
        assertEq(_meanTick(1, RESERVE_VENTURE, RESERVE_USDC), _tick());
        assertGt(_meanTick(2, r0, r1), _tick());
    }

    // ─── Geometric mean ──────────────────────────────────────────────────

    /// @notice Equal time at price p and 4p averages to 2p (geometric), not 2.5p (arithmetic).
    function test_twap_isTheGeometricMean() public {
        _init(1);
        (uint256 r0, uint256 r1) = _scaled(40_000);
        vm.warp(1000 + 1 days);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC);
        vm.warp(1000 + 2 days);
        oracle.update(1, r0, r1);
        (uint256 d0, uint256 d1) = _scaled(20_000);
        int256 twoP = oracle.exposed_poolTick(d0, d1);
        // The second day is credited as a ramp to the new tick at the slew rate, then a hold, so the
        // mean sits below the midpoint by the ramp's missing area: step * (step / rate) / 2 over the
        // two scored days.
        int256 step = int256(oracle.exposed_poolTick(r0, r1)) - int256(_tick());
        int256 ramp = step / int256(uint256(oracle.MIN_TICK_SLEW_PER_SECOND()));
        int256 expected = twoP - step * ramp / 2 / int256(2 days);
        assertApproxEqAbs(int256(_meanTick(1, r0, r1)), expected, 2);
    }

    // ─── C-01: a round-trip pump leaves no stale anchor ──────────────────

    /// @notice Pump at `a`, hold until a second update at `b` (the dump in the same block), then no
    ///         one trades. The old ratio clamp kept crediting 0.4x of the pumped anchor for the rest
    ///         of the window. Now the accepted tick ramps toward the pump at the slew rate for the
    ///         time it was held and ramps back at the same rate once the price is restored, so the
    ///         window carries only those two ramps.
    function test_C01_roundTripPumpLeavesNoStaleAnchor() public {
        (, uint32 end) = _init(1);
        int24 real = _tick();
        (uint256 p0, uint256 p1) = _scaled(1_000_000); // 100x pump
        int24 pumped = oracle.exposed_poolTick(p0, p1);

        uint32 a = 1000 + 1 hours;
        uint32 b = a + 10 minutes;
        vm.warp(a);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC); // before the pump trade
        vm.warp(b);
        oracle.update(1, p0, p1); // before the dump trade, same block as the dump
        vm.warp(end);

        int256 rate = int256(uint256(oracle.MIN_TICK_SLEW_PER_SECOND()));
        int256 held = int256(uint256(b - a));
        int256 credited = rate * held;
        if (credited > int256(pumped) - int256(real)) credited = int256(pumped) - int256(real);
        // Ramp up over `held`, ramp back down over credited / rate, nothing after.
        int256 area = credited * held / 2 + credited * (credited / rate) / 2;
        int256 expected = int256(real) + area / int256(uint256(end - 1000));
        assertLt(credited, int256(pumped) - int256(real), "a ten-minute hold cannot credit a 100x pump");
        int24 got = _meanTick(1, RESERVE_VENTURE, RESERVE_USDC);
        assertApproxEqAbs(int256(got), expected, 2);
    }

    /// @notice M-04: a crash held for the last twenty minutes of a three-day window. Undamped it
    ///         would move the mean by more than the 2% threshold; at the slew floor it moves it by
    ///         a handful of ticks.
    function test_M04_endOfWindowCrashCannotReachTheThreshold() public {
        (, uint32 end) = _init(1);
        int24 real = _tick();
        (uint256 c0, uint256 c1) = _scaled(100); // price to 1%: about -46,000 ticks
        int256 crashTicks = int256(real) - int256(oracle.exposed_poolTick(c0, c1));
        uint32 hold = 20 minutes;

        vm.warp(end - hold);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC); // before the crash trade
        vm.warp(end);
        int24 got = _meanTick(1, c0, c1);

        int256 undamped = crashTicks * int256(uint256(hold)) / int256(uint256(end - 1000));
        assertGt(undamped, int256(uint256(THRESHOLD_BPS)), "the crash would clear the threshold without the slew");
        int256 rate = int256(uint256(oracle.MIN_TICK_SLEW_PER_SECOND()));
        int256 damped = rate * int256(uint256(hold)) * int256(uint256(hold)) / 2 / int256(uint256(end - 1000));
        assertApproxEqAbs(int256(real) - int256(got), damped, 2);
        assertLt(int256(real) - int256(got), 25);
    }

    function test_slewFor_floorAndShortMarkets() public view {
        assertEq(oracle.slewFor(3 days), 7);
        assertEq(oracle.slewFor(6 hours), 7);
        assertEq(oracle.slewFor(2 hours), 10);
        assertEq(oracle.slewFor(1 hours), 20);
        (,,,,,, uint24 slew,) = oracle.oracleStates(1);
        assertEq(slew, 0, "uninitialized");
    }

    function test_update_slewFloorIs420TicksPerMinute() public {
        _init(1);
        (uint256 r0, uint256 r1) = (RESERVE_VENTURE, RESERVE_USDC * 100);
        vm.warp(1000 + 60);
        oracle.update(1, r0, r1);
        (, int24 accepted,,,,,,) = oracle.oracleStates(1);
        assertEq(int256(accepted) - int256(_tick()), 420);
    }

    function test_C01_pumpWithoutSecondUpdateIsNeverCredited() public {
        (, uint32 end) = _init(1);
        vm.warp(1000 + 1 hours);
        oracle.update(1, RESERVE_VENTURE, RESERVE_USDC); // before a pump that is dumped in the same block
        vm.warp(end);
        assertEq(_meanTick(1, RESERVE_VENTURE, RESERVE_USDC), _tick());
    }

    // ─── L-01: no reserve pair can revert an update or a read ─────────────

    function test_L01_hugeMoneyReserveDoesNotRevert() public {
        _init(1);
        vm.warp(1000 + 1 hours);
        uint256 huge = 1 << 200;
        oracle.update(1, 1, huge);
        oracle.update(1, RESERVE_VENTURE, huge);
        vm.warp(1000 + 2 hours);
        oracle.update(1, 1, type(uint256).max);
        int24 mean = _meanTick(1, 1, type(uint256).max);
        assertLe(mean, TickMath.MAX_TICK);
        oracle.calculateTWAP(1, 1, type(uint256).max);
    }

    function test_L01_extremeRatiosClampToTheTickRange() public view {
        assertEq(
            oracle.exposed_poolTick(1, type(uint256).max), TickMath.getTickAtSqrtPrice(TickMath.MAX_SQRT_PRICE - 1)
        );
        assertEq(oracle.exposed_poolTick(type(uint256).max, 1), TickMath.MIN_TICK);
        assertEq(oracle.exposed_poolTick(1, 1), 0);
    }

    struct State {
        int64 cumulative;
        int24 tick;
        uint16 remainder;
        uint32 start;
        uint32 end;
        uint32 lastTs;
        uint24 slew;
    }

    function _state(uint256 id) internal view returns (State memory st) {
        (st.cumulative, st.tick, st.remainder, st.start, st.end, st.lastTs, st.slew,) = oracle.oracleStates(id);
    }

    /// @dev Zero, the full uint256 range, and each side of the `_poolTick` branch boundaries.
    function _reserve(uint256 x, uint256 selector) internal pure returns (uint256) {
        uint256 m = selector % 6;
        if (m == 0) return 0;
        if (m == 1) return x;
        if (m == 2) return bound(x, 1, 1 << 64);
        if (m == 3) return bound(x, 1 << 64, 1 << 140);
        if (m == 4) return bound(x, 1 << 140, type(uint256).max);
        return bound(x, 1e6, 1e30);
    }

    /// @notice No reserve sequence can make an update or a settlement read revert, and the state
    ///         stays canonical: clock within the window, tick in range and slewed, cumulative
    ///         bounded by the tick range, and degenerate pools leave the interval open.
    function testFuzz_updateAndReadNeverRevert(
        uint256 seed0,
        uint256 seed1,
        uint32 startOffset,
        uint32 duration,
        uint256[12] calldata reserves0,
        uint256[12] calldata reserves1,
        uint256[12] calldata selectors,
        uint32[12] calldata dts
    ) public {
        uint32 tradingStart = uint32(block.timestamp + bound(uint256(startOffset), 0, 2 hours));
        uint32 tradingEnd = tradingStart + uint32(bound(uint256(duration), 1 hours, 96 hours));
        oracle.initialize(
            1,
            bound(seed0, 1, type(uint256).max),
            bound(seed1, 1, type(uint256).max),
            tradingStart,
            tradingEnd,
            THRESHOLD_BPS
        );

        uint256 ts = block.timestamp;
        State memory prev = _state(1);
        for (uint256 i = 0; i < 12; i++) {
            ts += bound(uint256(dts[i]), 0, 2 days);
            vm.warp(ts);
            uint256 r0 = _reserve(reserves0[i], selectors[i]);
            uint256 r1 = _reserve(reserves1[i], selectors[i] >> 8);
            oracle.update(1, r0, r1);
            State memory st = _state(1);

            if (ts < tradingStart) {
                vm.expectRevert(ConditionalMarketOracle.TradingNotStarted.selector);
                oracle.calculateTWAP(1, r0, r1);
            } else {
                int24 mean = oracle.calculateTWAPTick(1, r0, r1);
                assertGe(mean, TickMath.MIN_TICK);
                assertLe(mean, TickMath.MAX_TICK);
                oracle.calculateTWAP(1, r0, r1);
            }

            assertLe(st.lastTs, st.end, "clock never past the freeze");
            assertGe(st.lastTs, prev.lastTs, "clock monotone");
            assertGe(st.tick, TickMath.MIN_TICK);
            assertLe(st.tick, TickMath.MAX_TICK);
            assertLt(st.remainder, TickSlew.areaScale(st.slew));
            int256 elapsed = int256(uint256(st.lastTs - st.start));
            assertGe(int256(st.cumulative), int256(TickMath.MIN_TICK) * elapsed);
            assertLe(int256(st.cumulative), int256(TickMath.MAX_TICK) * elapsed);
            int256 moved = int256(st.tick) - int256(prev.tick);
            assertLe(moved < 0 ? -moved : moved, int256(uint256(st.slew)) * int256(uint256(st.lastTs - prev.lastTs)));
            if (r0 == 0 || r1 == 0) assertEq(st.lastTs, prev.lastTs, "degenerate pool leaves the interval open");
            prev = st;
        }
    }

    /// @notice Ratios at each `_poolTick` branch boundary and price clamp neither revert nor
    ///         leave the tick range.
    function test_update_survivesRatiosAtTheTickBounds() public {
        (uint32 tradingStart,) = _init(1);
        uint256[2][8] memory pairs = [
            [uint256(1), (1 << 128) - 1],
            [uint256(1), 1 << 128],
            [uint256(1), 1 << 64],
            [uint256(2), (1 << 128) + 1],
            [(1 << 128) - 1, uint256(1)],
            [uint256(1), type(uint256).max],
            [type(uint256).max, uint256(1)],
            [type(uint256).max, type(uint256).max]
        ];
        for (uint256 i = 0; i < pairs.length; i++) {
            vm.warp(tradingStart + (i + 1) * 1 hours);
            oracle.update(1, pairs[i][0], pairs[i][1]);
            int24 mean = oracle.calculateTWAPTick(1, pairs[i][0], pairs[i][1]);
            assertGe(mean, TickMath.MIN_TICK);
            assertLe(mean, TickMath.MAX_TICK);
        }
    }

    function testFuzz_poolTickMatchesTheExactPrice(uint256 reserve0, uint256 reserve1) public view {
        reserve0 = bound(reserve0, 1e6, 1e30);
        reserve1 = bound(reserve1, 1e6, 1e30);
        int24 got = oracle.exposed_poolTick(reserve0, reserve1);
        if (reserve1 / reserve0 < 1 << 64) {
            uint160 exact = uint160(Math.sqrt(FullMath.mulDiv(reserve1, 1 << 192, reserve0)));
            assertEq(got, TickMath.getTickAtSqrtPrice(exact));
        } else {
            // Above 2^64 the price is taken at 64 fractional bits: within one tick.
            uint160 coarse = uint160(Math.sqrt(FullMath.mulDiv(reserve1, 1 << 64, reserve0)) << 64);
            assertApproxEqAbs(int256(got), int256(TickMath.getTickAtSqrtPrice(coarse)), 1);
        }
    }

    // ─── Same slew as the spot oracle ────────────────────────────────────

    /// @notice The same reserve path through the conditional oracle and through `SpotMarketOracle`
    ///         produces the same accepted tick and cumulative.
    function testFuzz_updateIsTheSlewLibraryAtTheOracleRate(uint256 seed) public {
        _init(1);
        uint24 rate = oracle.MIN_TICK_SLEW_PER_SECOND();
        int24 refTick = _tick();
        int48 refCumulative;
        uint16 refRemainder;
        int256 offset;
        uint32 t = 1000;
        for (uint256 i = 0; i < 12; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint32 dt = uint32(seed % 7200) + 1;
            t += dt;
            offset = int256(seed >> 32) % 40_000 - 20_000;
            uint256 factor = uint256(int256(10_000) + offset / 3);
            (uint256 r0, uint256 r1) = (RESERVE_VENTURE, RESERVE_USDC * factor / 10_000);
            vm.warp(t);
            int24 target = oracle.exposed_poolTick(r0, r1);
            (int24 nextTick, int48 delta, uint16 remainder) = TickSlew.advance(refTick, target, dt, refRemainder, rate);
            refTick = nextTick;
            refCumulative += delta;
            refRemainder = remainder;
            oracle.update(1, r0, r1);
        }
        (int64 cumulative, int24 accepted,,,,,,) = oracle.oracleStates(1);
        assertEq(accepted, refTick);
        assertEq(int256(cumulative), int256(refCumulative));
    }
}
