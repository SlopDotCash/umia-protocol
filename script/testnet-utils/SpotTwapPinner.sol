// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {TwapMath} from "../../src/libraries/TwapMath.sol";

interface IERC20Pinner {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @title SpotTwapPinner
/// @notice **Testnet utility, not part of the protocol.** Shared base for the atomic market
///         opener/settler: pins a venture's spot price onto its 30-minute TWAP via one in-range
///         swap inside a PoolManager unlock, so a subsequent action that re-checks the
///         `SpotLiquidityVault` deviation guard passes in the same transaction. Owner-gated,
///         single-use; funded with the venture token, sweeps leftovers back on completion.
abstract contract SpotTwapPinner is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    uint32 internal constant TWAP_WINDOW = 30 minutes;
    uint24 internal constant SPOT_FEE = 10000;
    int24 internal constant SPOT_TICK_SPACING = 60;

    IUmiaHub public immutable HUB;
    IPoolManager public immutable POOL_MANAGER;
    IUmiaHook public immutable HOOK;
    address public immutable OWNER;

    // Set by `_pinSpotToTwap`, read by `unlockCallback` within the same call.
    address internal _venture;
    address internal _money;
    bool internal _ventureIsToken0;

    error NotOwner();
    error NotPoolManager();

    constructor(address hub, address poolManager, address hook) {
        HUB = IUmiaHub(hub);
        POOL_MANAGER = IPoolManager(poolManager);
        HOOK = IUmiaHook(hook);
        OWNER = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    /// @dev Resolve the venture's spot pool and swap spot exactly onto the current TWAP tick.
    function _pinSpotToTwap(uint256 ventureId) internal {
        IUmiaHub.VentureInfo memory info = HUB.ventureById(ventureId);
        _venture = HUB.ventureTokenById(ventureId);
        _money = IVenture(info.venture).moneyToken();
        _ventureIsToken0 = uint160(_venture) < uint160(_money);
        POOL_MANAGER.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();

        PoolKey memory key = _poolKey();
        PoolId id = key.toId();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;
        (int48[] memory cum,) = HOOK.observe(key, secondsAgos);
        int24 twapTick = TwapMath.averageTick(cum[0], cum[1], TWAP_WINDOW);
        uint160 targetSqrt = TickMath.getSqrtPriceAtTick(twapTick);

        (uint160 curSqrt,,,) = POOL_MANAGER.getSlot0(id);
        if (curSqrt != targetSqrt) {
            // Exact-in with a huge cap; the price limit stops the swap exactly on the TWAP tick.
            BalanceDelta delta = POOL_MANAGER.swap(
                key,
                SwapParams({
                    zeroForOne: curSqrt > targetSqrt,
                    amountSpecified: -int256(type(int128).max),
                    sqrtPriceLimitX96: targetSqrt
                }),
                ""
            );
            _settleOrTake(key.currency0, delta.amount0());
            _settleOrTake(key.currency1, delta.amount1());
        }
        return "";
    }

    function _settleOrTake(Currency currency, int128 amount) internal {
        if (amount < 0) {
            POOL_MANAGER.sync(currency);
            IERC20Pinner(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), uint256(-int256(amount)));
            POOL_MANAGER.settle();
        } else if (amount > 0) {
            POOL_MANAGER.take(currency, address(this), uint256(int256(amount)));
        }
    }

    function _poolKey() internal view returns (PoolKey memory) {
        (address c0, address c1) = _ventureIsToken0 ? (_venture, _money) : (_money, _venture);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: SPOT_FEE,
            tickSpacing: SPOT_TICK_SPACING,
            hooks: IHooks(address(HOOK))
        });
    }

    /// @dev Sweep the whole balance of `token` back to the deployer.
    function _sweep(address token) internal {
        uint256 bal = IERC20Pinner(token).balanceOf(address(this));
        if (bal != 0) IERC20Pinner(token).transfer(OWNER, bal);
    }
}
