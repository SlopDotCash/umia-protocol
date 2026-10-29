// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IUmiaHook} from "../interfaces/IUmiaHook.sol";
import {TwapMath} from "./TwapMath.sol";

/// @title SpotTwapGuard
/// @notice One question, answered the same way for the V2 vault, the ALM and the migrator: is spot
///         close enough to the pool's recent TWAPs that acting at this price is safe?
/// @dev A single 30-minute TWAP is not enough, because a price held for 30 minutes drags that TWAP
///      along with it. `withinBands` therefore pairs the short window with a TWAP of hours from the
///      coarse ring. Passing both takes a long hold: after a push of D ticks, the long TWAP comes
///      within B ticks of it only after longWindow * (1 - B / D). Missing history never passes: when
///      the hook cannot serve a window, `withinBands` reports not ready (or not safe, if the short
///      band already failed), and callers wait either way.
library SpotTwapGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @return ready False when either ring cannot serve its window; callers must fail closed.
    /// @return ok Spot is within `shortBand` of the `shortWindow` TWAP and within `longBand` of
    ///         the `longWindow` TWAP.
    function withinBands(
        IPoolManager poolManager,
        address hook,
        PoolKey memory key,
        uint32 shortWindow,
        int24 shortBand,
        uint32 longWindow,
        int24 longBand
    ) internal view returns (bool ready, bool ok) {
        (bool shortReady, int24 shortDeviation) = deviation(poolManager, hook, key, shortWindow);
        if (!shortReady) return (false, false);
        if (shortDeviation > shortBand) return (true, false);
        (bool longReady, int24 longDeviation) = longDeviation(poolManager, hook, key, longWindow);
        return (longReady, longDeviation <= longBand);
    }

    /// @return ready False when the per-block ring cannot serve the full window; callers must fail
    ///         closed, since on a single observation `observe` extrapolates the spot tick.
    function deviation(IPoolManager poolManager, address hook, PoolKey memory key, uint32 window)
        internal
        view
        returns (bool ready, int24)
    {
        return _deviation(poolManager, hook, key, window, false);
    }

    /// @notice |spot tick - `window` TWAP tick| from the coarse ring.
    /// @return ready False while the coarse ring is younger than the window: a fresh pool for its
    ///         first `window`, a migrated pool only if its predecessor had less history than that.
    /// @dev `observeLong` serves a lookback newer than the newest coarse checkpoint from the
    ///      per-block ring, which after a busy hour followed by quiet may no longer reach it. When
    ///      that checkpoint is older than the window, measure from the checkpoint instead: the
    ///      lookback stays on the coarse ring and the window only gets longer.
    function longDeviation(IPoolManager poolManager, address hook, PoolKey memory key, uint32 window)
        internal
        view
        returns (bool ready, int24)
    {
        PoolId id = key.toId();
        (uint16 index, uint16 cardinality,) = IUmiaHook(hook).coarseOracleStates(id);
        if (cardinality < 2) return (false, 0);
        (uint32 newestTs,) = _observation(hook, id, index, true);
        uint32 newestAge = uint32(block.timestamp) - newestTs;
        if (newestAge > window) window = newestAge;
        return _deviation(poolManager, hook, key, window, true);
    }

    function distance(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a - b : b - a;
    }

    function _deviation(IPoolManager poolManager, address hook, PoolKey memory key, uint32 window, bool coarse)
        private
        view
        returns (bool, int24)
    {
        PoolId id = key.toId();
        if (!_hasFullWindow(hook, id, window, coarse)) return (false, 0);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        int48[] memory tickCumulatives;
        if (coarse) (tickCumulatives,) = IUmiaHook(hook).observeLong(key, secondsAgos);
        else (tickCumulatives,) = IUmiaHook(hook).observe(key, secondsAgos);
        int24 twapTick = TwapMath.averageTick(tickCumulatives[0], tickCumulatives[1], window);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        return (true, distance(TickMath.getTickAtSqrtPrice(sqrtPriceX96), twapTick));
    }

    /// @dev The slot after the cursor holds the oldest observation once the ring has wrapped,
    ///      slot 0 before that.
    function _hasFullWindow(address hook, PoolId id, uint32 window, bool coarse) private view returns (bool) {
        uint16 index;
        uint16 cardinality;
        if (coarse) (index, cardinality,) = IUmiaHook(hook).coarseOracleStates(id);
        else (index, cardinality,) = IUmiaHook(hook).oracleStates(id);
        if (cardinality < 2) return false;
        (uint32 oldestTs, bool initialized) = _observation(hook, id, (index + 1) % cardinality, coarse);
        if (!initialized) {
            (oldestTs, initialized) = _observation(hook, id, 0, coarse);
            if (!initialized) return false;
        }
        return uint32(block.timestamp) >= oldestTs + window;
    }

    function _observation(address hook, PoolId id, uint16 i, bool coarse)
        private
        view
        returns (uint32 blockTimestamp, bool initialized)
    {
        if (coarse) (blockTimestamp,,, initialized) = IUmiaHook(hook).getCoarseObservation(id, i);
        else (blockTimestamp,,, initialized) = IUmiaHook(hook).getObservation(id, i);
    }
}
