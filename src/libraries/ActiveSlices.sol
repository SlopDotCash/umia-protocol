// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IActiveLiquidityManager} from "../interfaces/IActiveLiquidityManager.sol";

/// @title ActiveSlices
/// @notice Turns ranges described relative to a pool's tick into ALM positions sized from the ALM's
///         balances. The migrator uses it for a proposal's slices and the V2 LBP for the Hub's launch
///         range, so both paths open the ALM's first liquidity the same way.
library ActiveSlices {
    uint16 internal constant MAX_BPS = 10_000;

    /// @notice The ALM's constructor default for `maxWidthTicks`, in tick spacings. Wide on purpose: a
    ///         launch seeds the ALM before the pool has the oracle history a rebalance needs, so the
    ///         first range has to survive launch-day moves on its own. The Hub caps the launch range by it.
    uint16 internal constant DEFAULT_MAX_WIDTH_SPACINGS = 1000;

    error InvalidSlice();

    /// @notice A concentrated position for the ALM, relative to the pool's tick.
    /// @dev Offsets must be multiples of the tick spacing. `bps` is the share of the ALM's balances.
    struct Slice {
        int24 tickLowerOffset;
        int24 tickUpperOffset;
        uint16 bps;
    }

    /// @dev Centres every slice on the tick-spacing boundary at or below `tick` and clamps it to the
    ///      pool's usable tick span, so a range near the edge of the price scale shrinks instead of
    ///      reverting. Shares across slices may not exceed 100%.
    function toPositions(PoolKey memory key, address alm, uint160 sqrtPriceX96, int24 tick, Slice[] memory slices)
        internal
        view
        returns (IActiveLiquidityManager.Position[] memory positions)
    {
        uint256 balance0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(alm);
        uint256 balance1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(alm);
        int24 spacing = key.tickSpacing;
        int24 center = tick / spacing * spacing;
        if (tick < 0 && tick % spacing != 0) center -= spacing;
        int256 minTick = TickMath.minUsableTick(spacing);
        int256 maxTick = TickMath.maxUsableTick(spacing);

        uint256 totalBps;
        positions = new IActiveLiquidityManager.Position[](slices.length);
        for (uint256 i = 0; i < slices.length; i++) {
            Slice memory s = slices[i];
            totalBps += s.bps;
            if (s.tickLowerOffset % spacing != 0 || s.tickUpperOffset % spacing != 0) revert InvalidSlice();
            int256 lower = int256(center) + s.tickLowerOffset;
            int256 upper = int256(center) + s.tickUpperOffset;
            if (lower < minTick) lower = minTick;
            if (upper > maxTick) upper = maxTick;
            // One wei of headroom per side: the pool rounds the owed amounts up.
            uint256 amount0 = balance0 * s.bps / MAX_BPS;
            uint256 amount1 = balance1 * s.bps / MAX_BPS;
            positions[i] = IActiveLiquidityManager.Position({
                tickLower: int24(lower),
                tickUpper: int24(upper),
                liquidity: LiquidityAmounts.getLiquidityForAmounts(
                    sqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(int24(lower)),
                    TickMath.getSqrtPriceAtTick(int24(upper)),
                    amount0 == 0 ? 0 : amount0 - 1,
                    amount1 == 0 ? 0 : amount1 - 1
                )
            });
        }
        if (totalBps > MAX_BPS) revert InvalidSlice();
    }
}
