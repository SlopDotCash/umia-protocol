// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IActiveLiquidityManager} from "../../src/interfaces/IActiveLiquidityManager.sol";
import {SpotLiquidityV2TestBase} from "./ActiveLiquidityManager.t.sol";

/// @notice Several reshapes in a row: positions grow, shrink and regrow while fees accrue between
///         them. Position `i` must always be the V4 position under salt `i`, dropped salts must hold
///         nothing, and every reshape must pay out what the previous book earned.
contract ActiveLiquidityManagerSequenceTest is SpotLiquidityV2TestBase {
    using StateLibrary for IPoolManager;

    struct Range {
        int24 lower;
        int24 upper;
    }

    function setUp() public override {
        super.setUp();
        _fund(300_000 ether);
        alm.seed(_positions(-600, 600, 1e23));
        _ageOracle(13 hours);
    }

    function _target(Range[] memory ranges, uint128 liquidity)
        internal
        pure
        returns (IActiveLiquidityManager.Position[] memory p)
    {
        p = new IActiveLiquidityManager.Position[](ranges.length);
        for (uint256 i = 0; i < ranges.length; i++) {
            p[i] = IActiveLiquidityManager.Position(ranges[i].lower, ranges[i].upper, liquidity);
        }
    }

    function _rebalance(IActiveLiquidityManager.Position[] memory target) internal {
        _ageOracle(65 minutes);
        vm.prank(KEEPER);
        alm.rebalance(target);
        _assertSaltsMatchPositions();
    }

    function _poolLiquidity(int24 lower, int24 upper, uint256 salt) internal view returns (uint128 liquidity) {
        (liquidity,,) = manager.getPositionInfo(id, address(alm), lower, upper, bytes32(salt));
    }

    function _assertSaltsMatchPositions() internal view {
        IActiveLiquidityManager.Position[] memory p = alm.positions();
        for (uint256 i = 0; i < p.length; i++) {
            assertEq(_poolLiquidity(p[i].tickLower, p[i].tickUpper, i), p[i].liquidity, "salt i holds position i");
        }
    }

    function _earnFees() internal {
        for (uint256 i = 0; i < 6; i++) {
            _swap(i % 2 == 0, -5_000 ether);
        }
    }

    function test_Sequence_GrowShrinkRegrow_SaltIAlwaysHoldsPositionI() public {
        Range[] memory three = new Range[](3);
        three[0] = Range(-600, 600);
        three[1] = Range(-1800, -600);
        three[2] = Range(600, 1800);
        _rebalance(_target(three, 1e22));
        assertEq(alm.positions().length, 3);

        Range[] memory two = new Range[](2);
        two[0] = Range(-1200, 1200);
        two[1] = Range(-3000, -1200);
        _rebalance(_target(two, 1e22));
        assertEq(alm.positions().length, 2);
        assertEq(_poolLiquidity(600, 1800, 2), 0, "dropped salt 2 holds nothing");
        assertEq(_poolLiquidity(-600, 600, 0), 0, "salt 0's old range was closed");
        assertEq(_poolLiquidity(-1800, -600, 1), 0, "salt 1's old range was closed");

        Range[] memory regrown = new Range[](3);
        regrown[0] = Range(-1200, 1200);
        regrown[1] = Range(-3000, -1200);
        regrown[2] = Range(1200, 4200);
        _rebalance(_target(regrown, 2e22));
        assertEq(alm.positions().length, 3);
        assertEq(_poolLiquidity(1200, 4200, 2), 2e22, "salt 2 reused for the new third range");
        assertEq(_poolLiquidity(600, 1800, 2), 0, "salt 2's earlier range stays empty");
    }

    function test_Sequence_FeesAccrueBetweenReshapesAndArePaidOnEach() public {
        Range[] memory book = new Range[](2);
        book[0] = Range(-600, 600);
        book[1] = Range(-1800, 1800);
        _rebalance(_target(book, 1e23));

        uint256 ventureBefore0 = _token0().balanceOf(VENTURE);
        uint256 ventureBefore1 = _token1().balanceOf(VENTURE);
        uint256 owedBefore0 = alm.protocolOwedVenture();
        uint256 owedBefore1 = alm.protocolOwedMoney();

        _earnFees();
        _rebalance(_target(book, 1e23));

        uint256 paid0 = _token0().balanceOf(VENTURE) - ventureBefore0;
        uint256 paid1 = _token1().balanceOf(VENTURE) - ventureBefore1;
        uint256 cut0 = alm.protocolOwedVenture() - owedBefore0;
        uint256 cut1 = alm.protocolOwedMoney() - owedBefore1;
        assertGt(paid0 + paid1, 0, "the reshape paid the fees the book earned");
        // The protocol takes 10% of the fee, the venture the rest.
        assertApproxEqAbs(cut0 * 9, paid0, 9, "venture gets 9x the protocol cut on token0");
        assertApproxEqAbs(cut1 * 9, paid1, 9, "venture gets 9x the protocol cut on token1");
        assertGe(_token0().balanceOf(address(alm)), alm.protocolOwedVenture(), "owed cut stays backed");
        assertGe(_token1().balanceOf(address(alm)), alm.protocolOwedMoney(), "owed cut stays backed");

        _earnFees();
        uint256 ventureMid0 = _token0().balanceOf(VENTURE);
        alm.collectFees();
        assertGt(_token0().balanceOf(VENTURE), ventureMid0, "collectFees pays without reshaping");
        _assertSaltsMatchPositions();

        uint256 protocolBefore = _token0().balanceOf(PROTOCOL) + _token1().balanceOf(PROTOCOL);
        uint256 owed = alm.protocolOwedVenture() + alm.protocolOwedMoney();
        alm.claimProtocolFees();
        assertEq(_token0().balanceOf(PROTOCOL) + _token1().balanceOf(PROTOCOL) - protocolBefore, owed);
        assertEq(alm.protocolOwedVenture() + alm.protocolOwedMoney(), 0);
    }

    function test_Sequence_WithdrawAllAfterManyReshapes_LeavesNoLiquidityUnderAnySalt() public {
        Range[] memory a = new Range[](3);
        a[0] = Range(-600, 600);
        a[1] = Range(-2400, -600);
        a[2] = Range(600, 2400);
        _rebalance(_target(a, 1e22));
        _earnFees();
        Range[] memory b = new Range[](1);
        b[0] = Range(-1200, 1200);
        _rebalance(_target(b, 3e22));
        _earnFees();
        Range[] memory c = new Range[](2);
        c[0] = Range(-1800, 0);
        c[1] = Range(0, 1800);
        _rebalance(_target(c, 1e22));

        vm.prank(VENTURE);
        alm.withdrawAll();
        assertEq(alm.positions().length, 0);
        assertEq(_poolLiquidity(-600, 600, 0), 0);
        assertEq(_poolLiquidity(-2400, -600, 1), 0);
        assertEq(_poolLiquidity(600, 2400, 2), 0);
        assertEq(_poolLiquidity(-1200, 1200, 0), 0);
        assertEq(_poolLiquidity(-1800, 0, 0), 0);
        assertEq(_poolLiquidity(0, 1800, 1), 0);
        // withdrawAll returns the venture's idle; the protocol's accrued cut stays until it is claimed.
        assertEq(_token0().balanceOf(address(alm)), alm.protocolOwedVenture(), "only the protocol cut is left");
        assertEq(_token1().balanceOf(address(alm)), alm.protocolOwedMoney(), "only the protocol cut is left");
        alm.claimProtocolFees();
        assertEq(_token0().balanceOf(address(alm)) + _token1().balanceOf(address(alm)), 0, "then nothing");
    }
}
