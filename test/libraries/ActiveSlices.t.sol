// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ActiveSlices} from "../../src/libraries/ActiveSlices.sol";
import {IActiveLiquidityManager} from "../../src/interfaces/IActiveLiquidityManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract ActiveSlicesHarness {
    function toPositions(
        PoolKey memory key,
        address alm,
        uint160 sqrtPriceX96,
        int24 tick,
        ActiveSlices.Slice[] memory s
    ) external view returns (IActiveLiquidityManager.Position[] memory) {
        return ActiveSlices.toPositions(key, alm, sqrtPriceX96, tick, s);
    }
}

contract ActiveSlicesTest is Test {
    int24 constant SPACING = 60;
    ActiveSlicesHarness harness;
    PoolKey key;
    address alm = makeAddr("alm");
    // Uniswap liquidity math overflows uint128 for large balances at the edges of the tick range.
    address edgeAlm = makeAddr("edgeAlm");

    function setUp() public {
        harness = new ActiveSlicesHarness();
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 10_000, SPACING, IHooks(address(0)));
        a.mint(alm, 1_000e18);
        b.mint(alm, 1_000e18);
        a.mint(edgeAlm, 1_000);
        b.mint(edgeAlm, 1_000);
    }

    function _one(int24 lower, int24 upper, uint16 bps) internal pure returns (ActiveSlices.Slice[] memory s) {
        s = new ActiveSlices.Slice[](1);
        s[0] = ActiveSlices.Slice(lower, upper, bps);
    }

    function test_CentresOnTheSpacingBoundaryBelowTheTick() public view {
        int24 tick = 69_123;
        IActiveLiquidityManager.Position[] memory p =
            harness.toPositions(key, alm, TickMath.getSqrtPriceAtTick(tick), tick, _one(-600, 600, 10_000));
        assertEq(p[0].tickLower, 69_120 - 600);
        assertEq(p[0].tickUpper, 69_120 + 600);
        assertGt(p[0].liquidity, 0);

        tick = -69_123;
        p = harness.toPositions(key, alm, TickMath.getSqrtPriceAtTick(tick), tick, _one(-600, 600, 10_000));
        assertEq(p[0].tickLower, -69_180 - 600, "negative ticks round down");
    }

    function test_ClampsToTheUsableTickSpan() public view {
        int24 maxTick = TickMath.maxUsableTick(SPACING);
        int24 tick = maxTick - 600;
        IActiveLiquidityManager.Position[] memory p =
            harness.toPositions(key, edgeAlm, TickMath.getSqrtPriceAtTick(tick), tick, _one(-30_000, 30_000, 10_000));
        assertEq(p[0].tickLower, tick - 30_000);
        assertEq(p[0].tickUpper, maxTick, "upper edge clamped");

        int24 minTick = TickMath.minUsableTick(SPACING);
        tick = minTick + 600;
        p = harness.toPositions(key, edgeAlm, TickMath.getSqrtPriceAtTick(tick), tick, _one(-30_000, 30_000, 10_000));
        assertEq(p[0].tickLower, minTick, "lower edge clamped");
        assertEq(p[0].tickUpper, tick + 30_000);
    }

    function test_RejectsMisalignedOffsetsAndOversubscribedShares() public {
        int24 tick = 0;
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        vm.expectRevert(ActiveSlices.InvalidSlice.selector);
        harness.toPositions(key, alm, price, tick, _one(-601, 600, 10_000));

        ActiveSlices.Slice[] memory two = new ActiveSlices.Slice[](2);
        two[0] = ActiveSlices.Slice(-600, 600, 6_000);
        two[1] = ActiveSlices.Slice(-1_200, 1_200, 6_000);
        vm.expectRevert(ActiveSlices.InvalidSlice.selector);
        harness.toPositions(key, alm, price, tick, two);
    }
}
