// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CPMM} from "../../src/libraries/CPMM.sol";
import {CPMMWithFee} from "../../src/libraries/CPMMWithFee.sol";

contract CPMMHarness {
    CPMM.State public s;

    function set(uint256 r0, uint256 r1) external {
        s.reserve0 = r0;
        s.reserve1 = r1;
    }

    function swapExactIn(uint256 amountIn, bool zeroForOne, uint256 feeBps, uint256 cutBps)
        external
        returns (CPMM.SwapResult memory, uint256)
    {
        return CPMMWithFee._swapExactIn(s, amountIn, 0, type(uint256).max, zeroForOne, feeBps, cutBps);
    }

    function swapExactOut(uint256 amountOut, bool zeroForOne, uint256 feeBps, uint256 cutBps)
        external
        returns (CPMM.SwapResult memory, uint256)
    {
        return CPMMWithFee._swapExactOut(s, amountOut, type(uint256).max, type(uint256).max, zeroForOne, feeBps, cutBps);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return CPMM._getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return CPMM._getAmountIn(amountOut, reserveIn, reserveOut);
    }
}

/// @notice Differential tests of the decision-market CPMM against exact rational references.
///         Reserves and amounts stay below 2^100 so every cross-multiplied reference is exact.
contract CPMMTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant MAX = 2 ** 100;
    uint256 constant MAX_FEE_BPS = 1000;

    CPMMHarness h;

    function setUp() public {
        h = new CPMMHarness();
    }

    function _oriented(uint256 r0, uint256 r1, bool zeroForOne) internal pure returns (uint256 rin, uint256 rout) {
        (rin, rout) = zeroForOne ? (r0, r1) : (r1, r0);
    }

    function testFuzz_exactIn_isTheFloorOfTheExactOutput(
        uint256 r0,
        uint256 r1,
        uint256 amountIn,
        bool zeroForOne,
        uint256 fee,
        uint256 cut
    ) public {
        r0 = bound(r0, 1e3, MAX);
        r1 = bound(r1, 1e3, MAX);
        amountIn = bound(amountIn, 0, MAX);
        fee = bound(fee, 0, MAX_FEE_BPS);
        cut = bound(cut, 0, BPS);
        h.set(r0, r1);
        (CPMM.SwapResult memory r, uint256 protocolFee) = h.swapExactIn(amountIn, zeroForOne, fee, cut);
        (uint256 n0, uint256 n1) = h.s();
        (uint256 rin, uint256 rout) = _oriented(r0, r1, zeroForOne);
        (uint256 nin, uint256 nout) = _oriented(n0, n1, zeroForOne);

        uint256 net = amountIn - amountIn * fee / BPS;
        assertLe(r.amountOut * (rin + net), net * rout, "output above exact");
        assertGt((r.amountOut + 1) * (rin + net), net * rout, "output not the floor");
        assertEq(nin, rin + amountIn - protocolFee, "input conservation");
        assertEq(nout, rout - r.amountOut, "output conservation");
        assertGe(nin * nout, rin * rout, "k decreased");
    }

    function testFuzz_exactOut_chargesTheCeilAndNeverUndercutsExactIn(
        uint256 r0,
        uint256 r1,
        uint256 amountOut,
        bool zeroForOne,
        uint256 fee,
        uint256 cut
    ) public {
        r0 = bound(r0, 1e3, MAX);
        r1 = bound(r1, 1e3, MAX);
        fee = bound(fee, 0, MAX_FEE_BPS);
        cut = bound(cut, 0, BPS);
        (uint256 rin, uint256 rout) = _oriented(r0, r1, zeroForOne);
        amountOut = bound(amountOut, 1, rout / 2);
        h.set(r0, r1);
        (CPMM.SwapResult memory r, uint256 protocolFee) = h.swapExactOut(amountOut, zeroForOne, fee, cut);
        (uint256 n0, uint256 n1) = h.s();
        (uint256 nin, uint256 nout) = _oriented(n0, n1, zeroForOne);

        // Net input: the exact ceil of rin*out/(rout-out), one wei over when that divides evenly.
        uint256 exactCeil = (rin * amountOut + rout - amountOut - 1) / (rout - amountOut);
        uint256 netIn = h.getAmountIn(amountOut, rin, rout);
        assertGe(netIn, exactCeil, "net input below the exact ceil");
        assertLe(netIn, exactCeil + 1, "net input overcharged");
        // Gross is the smallest amount whose post-fee value covers the net input.
        assertGe(r.amountIn * (BPS - fee), netIn * BPS, "gross does not cover net");
        assertLt((r.amountIn - 1) * (BPS - fee), netIn * BPS, "gross not minimal");
        assertEq(nin, rin + r.amountIn - protocolFee, "input conservation");
        assertEq(nout, rout - amountOut, "output conservation");
        assertGe(nin * nout, rin * rout, "k decreased");

        // The cheapest exact-in gross that delivers `amountOut` is never above the exact-out gross.
        uint256 lo = 1;
        uint256 hi = r.amountIn;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (h.getAmountOut(mid - mid * fee / BPS, rin, rout) >= amountOut) hi = mid;
            else lo = mid + 1;
        }
        assertGe(h.getAmountOut(lo - lo * fee / BPS, rin, rout), amountOut, "exact-in at the exact-out gross");
        assertLe(r.amountIn - lo, 3, "exact-out overcharges vs exact-in");
    }
}
