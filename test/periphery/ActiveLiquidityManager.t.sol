// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {UmiaHookV2} from "../../src/periphery/UmiaHookV2.sol";
import {IUmiaHookV2} from "../../src/interfaces/IUmiaHookV2.sol";
import {SpotLiquidityVaultV2} from "../../src/core/SpotLiquidityVaultV2.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {ISpotLiquidityVaultV2} from "../../src/interfaces/ISpotLiquidityVaultV2.sol";
import {ActiveLiquidityManager} from "../../src/core/ActiveLiquidityManager.sol";
import {IActiveLiquidityManager} from "../../src/interfaces/IActiveLiquidityManager.sol";
import {SpotTwapGuard} from "../../src/libraries/SpotTwapGuard.sol";

contract SpotLiquidityV2TestBase is Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant HUB = address(0xB0B);
    address constant HUB_OWNER = address(0xB0B0);
    address constant VENTURE = address(0x1234);
    address constant PROTOCOL = address(0xFEE);
    address constant KEEPER = address(0x4EE9);
    address constant MARKET_CORE = address(0xC0DE);
    address constant HOOK_ADDR = address(uint160(0x2222 << 20) | 0x3A80);
    int24 constant SPACING = 60;
    uint256 constant T0 = 480_000 hours;

    UmiaHookV2 hook;
    SpotLiquidityVaultV2 vault;
    ActiveLiquidityManager alm;
    PoolKey poolKey;
    PoolId id;

    function setUp() public virtual {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        vm.mockCall(VENTURE, abi.encodeWithSignature("token()"), abi.encode(Currency.unwrap(currency0)));
        vm.mockCall(VENTURE, abi.encodeWithSignature("moneyToken()"), abi.encode(Currency.unwrap(currency1)));
        vm.mockCall(HUB, abi.encodeWithSignature("spotProtocolFeeCutBps()"), abi.encode(uint16(1000)));
        vm.mockCall(HUB, abi.encodeWithSignature("protocolFeeRecipient()"), abi.encode(PROTOCOL));
        vm.mockCall(HUB, abi.encodeWithSignature("owner()"), abi.encode(HUB_OWNER));
        vm.mockCall(HUB, abi.encodeWithSignature("activeLiquidityKeeper()"), abi.encode(KEEPER));
        vm.mockCall(HUB, abi.encodeWithSignature("umiaMarketCore()"), abi.encode(MARKET_CORE));
        vm.mockCall(FACTORY, abi.encodeWithSignature("isLBP(address)", address(this)), abi.encode(true));

        deployCodeTo("UmiaHookV2.sol:UmiaHookV2", abi.encode(OWNER), HOOK_ADDR);
        hook = UmiaHookV2(HOOK_ADDR);
        vm.prank(OWNER);
        hook.initialize(FACTORY, manager, HUB);

        alm = new ActiveLiquidityManager(HUB, VENTURE, address(manager), HOOK_ADDR, 3000, SPACING, address(this));
        vault = new SpotLiquidityVaultV2(HUB, VENTURE, address(manager), HOOK_ADDR, 3000, SPACING, address(this));
        poolKey = PoolKey(currency0, currency1, 3000, SPACING, IHooks(HOOK_ADDR));
        id = poolKey.toId();

        hook.registerPool(
            poolKey,
            IUmiaHookV2.PoolConfig({
                launcher: address(0), venture: VENTURE, anchorOperator: address(vault), activeOperator: address(alm)
            })
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        _token0().approve(address(vault), type(uint256).max);
        _token1().approve(address(vault), type(uint256).max);
        vault.bootstrapFromLBP(1_000_000 ether, 1_000_000 ether, VENTURE);
    }

    function _defaultConstraints() internal pure returns (IActiveLiquidityManager.Constraints memory) {
        return IActiveLiquidityManager.Constraints({
            maxPositions: 3,
            minWidthTicks: 120,
            maxWidthTicks: 60_000,
            minRebalanceInterval: 1 hours,
            maxTwapDeviationTicks: 30
        });
    }

    function _token0() internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(currency0));
    }

    function _token1() internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(currency1));
    }

    function _positions(int24 lower, int24 upper, uint128 liquidity)
        internal
        pure
        returns (IActiveLiquidityManager.Position[] memory p)
    {
        p = new IActiveLiquidityManager.Position[](1);
        p[0] = IActiveLiquidityManager.Position({tickLower: lower, tickUpper: upper, liquidity: liquidity});
    }

    function _fund(uint256 amount) internal {
        _token0().transfer(address(alm), amount);
        _token1().transfer(address(alm), amount);
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Pins spot at `target` for `duration`, writing both oracle rings every 5 minutes.
    function _holdAt(int24 target, uint256 duration) internal {
        uint256 steps = duration / 5 minutes;
        for (uint256 i = 0; i < steps; i++) {
            vm.warp(vm.getBlockTimestamp() + 5 minutes);
            _swap(i % 2 == 0, -1 ether);
            _swapToTick(target);
        }
    }

    function _swapToTick(int24 target) internal {
        (, int24 current,,) = manager.getSlot0(id);
        if (current == target) return;
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: target < current,
                amountSpecified: -1e30,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _shortDeviation() internal view returns (int24 d) {
        (, d) = SpotTwapGuard.deviation(manager, HOOK_ADDR, poolKey, 30 minutes);
    }

    function _longDeviation(uint32 window) internal view returns (int24 d) {
        bool ready;
        (ready, d) = SpotTwapGuard.longDeviation(manager, HOOK_ADDR, poolKey, window);
        assertTrue(ready);
    }

    function _spotTick() internal view returns (int24) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @dev Round-trip swaps with oracle writes spread over `duration`, ending near the start price.
    function _ageOracle(uint256 duration) internal {
        uint256 steps = duration / 5 minutes;
        for (uint256 i = 0; i < steps; i++) {
            vm.warp(vm.getBlockTimestamp() + 5 minutes);
            _swap(i % 2 == 0, -1 ether);
        }
    }
}

contract SpotLiquidityVaultV2Test is SpotLiquidityV2TestBase {
    function test_Constructor_StartsWithDefaultConstraints() public view {
        IActiveLiquidityManager.Constraints memory c = alm.constraints();
        IActiveLiquidityManager.Constraints memory d = _defaultConstraints();
        assertEq(c.maxPositions, d.maxPositions);
        assertEq(c.minWidthTicks, d.minWidthTicks);
        assertEq(c.maxWidthTicks, d.maxWidthTicks);
        assertEq(c.minRebalanceInterval, d.minRebalanceInterval);
        assertEq(c.maxTwapDeviationTicks, alm.maxTwapDeviationCap());
    }

    /// @notice A price held for 30 minutes passes the short window on its own; the 6-hour TWAP
    ///         still blocks the vault until the coarse ring has followed.
    function test_Guard_RejectsSpotHeldAwayFromLongTwap() public {
        _ageOracle(7 hours);
        _holdAt(3000, 35 minutes);
        assertLe(_shortDeviation(), 30);

        vm.expectRevert(ISpotLiquidityVault.SpotPriceDeviationTooHigh.selector);
        vault.deposit(1 ether, 1 ether, 0, address(this));

        _holdAt(3000, 7 hours);
        vault.deposit(1 ether, 1 ether, 0, address(this));
    }

    function test_Guard_FailsClosedWhileCoarseRingIsYoung() public {
        _ageOracle(65 minutes);
        vm.expectRevert(ISpotLiquidityVault.InsufficientOracleHistory.selector);
        vault.deposit(1 ether, 1 ether, 0, address(this));
    }

    function test_Bootstrap_GatedToBootstrapper() public {
        SpotLiquidityVaultV2 other =
            new SpotLiquidityVaultV2(HUB, VENTURE, address(manager), HOOK_ADDR, 500, SPACING, address(0xB00));
        vm.expectRevert(ISpotLiquidityVaultV2.CallerNotBootstrapper.selector);
        other.bootstrapFromLBP(1 ether, 1 ether, VENTURE);
    }

    function test_Bootstrap_MintsSharesToVentureOnce() public {
        assertGt(vault.shareBalance(VENTURE), 0);
        assertEq(vault.totalShares(), vault.shareBalance(VENTURE));
        assertTrue(vault.isPoolInitialized());
        assertEq(vault.activeManager(), address(alm));
        assertEq(vault.bootstrapper(), address(this));
        vm.expectRevert(ISpotLiquidityVault.PoolAlreadyInitialized.selector);
        vault.bootstrapFromLBP(1 ether, 1 ether, VENTURE);
    }

    function test_Constructor_RejectsZeroBootstrapper() public {
        vm.expectRevert(ISpotLiquidityVault.InvalidAddress.selector);
        new SpotLiquidityVaultV2(HUB, VENTURE, address(manager), HOOK_ADDR, 3000, SPACING, address(0));
    }

    function test_MarketPullAndReturn_TouchOnlyTheAnchor() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));
        _ageOracle(7 hours);
        uint128 almLiquidity = alm.positions()[0].liquidity;

        vm.prank(MARKET_CORE);
        (uint256 v, uint256 m,) = vault.pullForDecisionMarket(1, 5000);
        assertGt(v, 0);
        assertEq(alm.positions()[0].liquidity, almLiquidity);

        vm.startPrank(MARKET_CORE);
        _token0().approve(address(vault), v);
        _token1().approve(address(vault), m);
        vault.returnFromDecisionMarket(1, v, m);
        vm.stopPrank();
    }

    function test_Withdraw_VentureRedeemsAll() public {
        _ageOracle(7 hours);
        uint256 shares = vault.shareBalance(VENTURE);
        vm.prank(VENTURE);
        (uint256 v, uint256 m) = vault.withdraw(shares, 0, 0, VENTURE);
        assertGt(v, 0);
        assertGt(m, 0);
        assertEq(vault.currentLiquidity(), 0);
    }
}

contract ActiveLiquidityManagerTest is SpotLiquidityV2TestBase {
    using StateLibrary for IPoolManager;

    function test_Seed_OnlyBootstrapperOnce() public {
        _fund(100_000 ether);
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.CallerNotBootstrapper.selector);
        alm.seed(_positions(-600, 600, 1e24));

        alm.seed(_positions(-600, 600, 1e24));
        assertEq(alm.positions().length, 1);
        (uint128 liq,,) = manager.getPositionInfo(id, address(alm), -600, 600, bytes32(0));
        assertEq(liq, 1e24);

        vm.expectRevert(IActiveLiquidityManager.AlreadySeeded.selector);
        alm.seed(_positions(-600, 600, 1e24));
    }

    function test_Seed_RevertsWhenUnderfunded() public {
        vm.expectRevert();
        alm.seed(_positions(-600, 600, 1e24));
    }

    function test_Rebalance_OnlyKeeperAfterIntervalAndOracle() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));

        vm.expectRevert(IActiveLiquidityManager.CallerNotKeeper.selector);
        alm.rebalance(_positions(-1200, 1200, 1e24));

        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(IActiveLiquidityManager.RebalanceTooSoon.selector, T0 + 1 hours));
        alm.rebalance(_positions(-1200, 1200, 1e24));

        _ageOracle(13 hours);
        vm.prank(KEEPER);
        alm.rebalance(_positions(-1200, 1200, 1e24));
        (uint128 oldLiq,,) = manager.getPositionInfo(id, address(alm), -600, 600, bytes32(0));
        (uint128 newLiq,,) = manager.getPositionInfo(id, address(alm), -1200, 1200, bytes32(0));
        assertEq(oldLiq, 0);
        assertEq(newLiq, 1e24);
    }

    function test_Rebalance_FailsClosedOnYoungOracle() public {
        _fund(100_000 ether);
        vm.warp(T0 + 2 hours);
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.InsufficientOracleHistory.selector);
        alm.rebalance(_positions(-600, 600, 1e24));
    }

    function test_Rebalance_RejectsManipulatedSpot() public {
        _fund(100_000 ether);
        _ageOracle(13 hours);
        _swap(false, -200_000 ether);
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.SpotPriceDeviationTooHigh.selector);
        alm.rebalance(_positions(-600, 600, 1e24));
    }

    /// @notice Holding spot 15% away for 30 minutes drags the 30-minute TWAP along; the 12-hour
    ///         TWAP still rejects the rebalance after a 7-hour hold (which the old 6-hour, 300-tick
    ///         guard would have let through) and only clears it after about eight hours.
    function test_Rebalance_RejectsSpotHeldAwayFromLongTwap() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));
        _ageOracle(13 hours);

        _holdAt(1500, 35 minutes);
        assertLe(_shortDeviation(), alm.maxTwapDeviationCap());
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.SpotPriceDeviationTooHigh.selector);
        alm.rebalance(_positions(-600, 600, 1e24));

        _holdAt(1500, 7 hours - 35 minutes);
        assertLe(_shortDeviation(), alm.maxTwapDeviationCap());
        assertLe(_longDeviation(6 hours), 300);
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.SpotPriceDeviationTooHigh.selector);
        alm.rebalance(_positions(-600, 600, 1e24));

        _holdAt(1500, 2 hours);
        vm.prank(KEEPER);
        alm.rebalance(_positions(-600, 600, 1e24));
    }

    /// @notice The long band is exactly 500 ticks around the 12-hour TWAP.
    function test_Rebalance_LongBandIs500Ticks() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));
        _ageOracle(13 hours);
        _holdAt(1500, 35 minutes);
        while (_longDeviation(12 hours) > 520) {
            _holdAt(1500, 5 minutes);
        }

        // Writes this block's observation so the swaps below move spot but not the TWAPs.
        vm.warp(vm.getBlockTimestamp() + 1);
        _swapToTick(1499);
        int24 longTwap = _spotTick() - _longDeviation(12 hours);

        _swapToTick(longTwap + 501);
        assertEq(_longDeviation(12 hours), 501);
        assertLe(_shortDeviation(), alm.maxTwapDeviationCap());
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.SpotPriceDeviationTooHigh.selector);
        alm.rebalance(_positions(-600, 600, 1e24));

        _swapToTick(longTwap + 500);
        assertEq(_longDeviation(12 hours), 500);
        assertLe(_shortDeviation(), alm.maxTwapDeviationCap());
        vm.prank(KEEPER);
        alm.rebalance(_positions(-600, 600, 1e24));
    }

    /// @notice After a busy hour (more swaps than the per-block ring holds) followed by 12 quiet
    ///         hours, the 12-hour lookback is newer than the last coarse checkpoint but older than
    ///         the per-block ring; the guard must still serve it rather than revert.
    function test_Rebalance_LongTwapServedAfterBusyHourThenQuiet() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));
        _ageOracle(13 hours);

        vm.warp((vm.getBlockTimestamp() / 1 hours + 1) * 1 hours);
        for (uint256 i = 0; i < 120; i++) {
            vm.warp(vm.getBlockTimestamp() + 2);
            _swap(i % 2 == 0, -1 ether);
        }
        vm.warp(vm.getBlockTimestamp() - 220 + 12 hours);

        assertEq(_shortDeviation(), 0);
        vm.prank(KEEPER);
        alm.rebalance(_positions(-600, 600, 1e24));
    }

    /// @notice The long check fails closed like the short one: no rebalance until the coarse ring
    ///         covers 12 hours.
    function test_Rebalance_FailsClosedWhileCoarseRingIsYoung() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));
        _ageOracle(65 minutes);
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.InsufficientOracleHistory.selector);
        alm.rebalance(_positions(-600, 600, 1e24));

        _ageOracle(7 hours);
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.InsufficientOracleHistory.selector);
        alm.rebalance(_positions(-600, 600, 1e24));

        _ageOracle(5 hours);
        vm.prank(KEEPER);
        alm.rebalance(_positions(-600, 600, 1e24));
    }

    function test_Rebalance_EnforcesConstraints() public {
        _fund(100_000 ether);
        _ageOracle(13 hours);

        IActiveLiquidityManager.Position[] memory tooMany = new IActiveLiquidityManager.Position[](4);
        for (uint256 i = 0; i < 4; i++) {
            tooMany[i] = IActiveLiquidityManager.Position(-600, 600, 1e20);
        }
        vm.startPrank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.TooManyPositions.selector);
        alm.rebalance(tooMany);
        vm.expectRevert(abi.encodeWithSelector(IActiveLiquidityManager.InvalidPosition.selector, 0));
        alm.rebalance(_positions(-60, 0, 1e20));
        vm.expectRevert(abi.encodeWithSelector(IActiveLiquidityManager.InvalidPosition.selector, 0));
        alm.rebalance(_positions(-60_000, 60_000, 1e20));
        vm.expectRevert(abi.encodeWithSelector(IActiveLiquidityManager.InvalidPosition.selector, 0));
        alm.rebalance(_positions(-600, 600, 0));
        vm.stopPrank();
    }

    function test_Rebalance_PreservesValueAtUnchangedPrice() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));
        _ageOracle(13 hours);
        alm.collectFees();
        (uint256 v0, uint256 m0) = alm.totalAssets();

        IActiveLiquidityManager.Position[] memory target = new IActiveLiquidityManager.Position[](2);
        target[0] = IActiveLiquidityManager.Position(-1200, 1200, 5e23);
        target[1] = IActiveLiquidityManager.Position(-300, 300, 5e23);
        vm.prank(KEEPER);
        alm.rebalance(target);

        // No swap happens, so each token only moves between positions and idle.
        (uint256 v1, uint256 m1) = alm.totalAssets();
        assertApproxEqAbs(v1, v0, 10);
        assertApproxEqAbs(m1, m0, 10);
        assertEq(alm.positions().length, 2);
    }

    function test_CollectFees_PaysVentureAndAccruesProtocolCut() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));
        for (uint256 i = 0; i < 10; i++) {
            _swap(i % 2 == 0, -10_000 ether);
        }

        uint256 venture0 = _token0().balanceOf(VENTURE);
        uint256 almLiq = alm.positions()[0].liquidity;
        vm.prank(address(0xA11CE));
        alm.collectFees();

        uint256 ventureGain0 = _token0().balanceOf(VENTURE) - venture0;
        uint256 owed0 = alm.protocolOwedVenture();
        assertGt(ventureGain0, 0);
        assertGt(owed0, 0);
        assertApproxEqRel(owed0 * 9, ventureGain0, 0.001e18);
        assertEq(alm.positions()[0].liquidity, almLiq);

        alm.claimProtocolFees();
        assertEq(_token0().balanceOf(PROTOCOL), owed0);
        assertEq(alm.protocolOwedVenture(), 0);
    }

    /// @dev A protocol recipient that rejects transfers cannot block the venture's exit.
    function test_WithdrawAll_IgnoresRevertingProtocolRecipient() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));
        for (uint256 i = 0; i < 4; i++) {
            _swap(i % 2 == 0, -10_000 ether);
        }
        vm.mockCallRevert(
            Currency.unwrap(currency0), abi.encodeWithSignature("transfer(address,uint256)", PROTOCOL), "blocked"
        );

        vm.prank(VENTURE);
        alm.withdrawAll();
        uint256 owed0 = alm.protocolOwedVenture();
        assertGt(owed0, 0);
        assertEq(_token0().balanceOf(address(alm)), owed0);
        assertEq(_token1().balanceOf(address(alm)), alm.protocolOwedMoney());

        vm.expectRevert();
        alm.claimProtocolFees();
    }

    /// @dev A keeper sizing a rebalance to consume every token, including the accrued protocol cut.
    function test_Rebalance_CannotSpendProtocolOwed() public {
        _fund(10_000 ether);
        alm.seed(_positions(-600, 600, 1e23));
        for (uint256 i = 0; i < 6; i++) {
            _swap(i % 2 == 0, -10_000 ether);
        }
        alm.collectFees();
        assertGt(alm.protocolOwedVenture() + alm.protocolOwedMoney(), 0);
        _ageOracle(13 hours);

        (uint160 sqrtP,,,) = manager.getSlot0(id);
        (uint256 capitalVenture, uint256 capitalMoney) = alm.totalAssets();
        uint128 everything = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(-600),
            TickMath.getSqrtPriceAtTick(600),
            capitalVenture + alm.protocolOwedVenture() - 1,
            capitalMoney + alm.protocolOwedMoney() - 1
        );
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.InsufficientIdle.selector);
        alm.rebalance(_positions(-600, 600, everything));
    }

    function test_Defund_CannotTouchProtocolOwed() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));
        for (uint256 i = 0; i < 4; i++) {
            _swap(i % 2 == 0, -10_000 ether);
        }
        alm.collectFees();
        uint256 balance0 = _token0().balanceOf(address(alm));
        vm.prank(VENTURE);
        vm.expectRevert(IActiveLiquidityManager.InsufficientIdle.selector);
        alm.defund(balance0, 0);
    }

    /// @notice Keeper-compromise sandwich: push spot to the edge of the band, place a range at the
    ///         pushed price, trade back through it. The band is capped at the pool fee, so the
    ///         venture never ends up worse off at the original price.
    function test_KeeperSandwichWithinBand_DoesNotExtractValue() public {
        _fund(100_000 ether);
        IActiveLiquidityManager.Constraints memory c = _defaultConstraints();
        c.maxTwapDeviationTicks = alm.maxTwapDeviationCap();
        vm.prank(VENTURE);
        alm.setConstraints(c);
        _ageOracle(13 hours);
        _swap(true, -1);
        (uint256 v0, uint256 m0) = alm.totalAssets();
        (uint256 tv0, uint256 tm0) = (_token0().balanceOf(VENTURE), _token1().balanceOf(VENTURE));
        int24 fairTick = _tick();

        _swapTo(fairTick + alm.maxTwapDeviationCap() - 1);
        vm.prank(KEEPER);
        alm.rebalance(_positions(_floor(fairTick), _floor(fairTick) + 120, 1e25));
        _swapTo(fairTick);
        alm.collectFees();

        (uint256 v1, uint256 m1) = alm.totalAssets();
        (uint256 tv1, uint256 tm1) = (_token0().balanceOf(VENTURE), _token1().balanceOf(VENTURE));
        (uint160 sqrtP,,,) = manager.getSlot0(id);
        uint256 priceE18 = FullMath.mulDiv(uint256(sqrtP) * sqrtP, 1e18, 1 << 192);
        uint256 valueBefore = v0 * priceE18 / 1e18 + m0;
        uint256 valueAfter = (v1 + tv1 - tv0) * priceE18 / 1e18 + m1 + tm1 - tm0;
        assertGe(valueAfter, valueBefore);
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(id);
    }

    function _floor(int24 tick) internal pure returns (int24) {
        int24 compressed = tick / SPACING;
        if (tick < 0 && tick % SPACING != 0) compressed--;
        return compressed * SPACING;
    }

    function _swapTo(int24 target) internal {
        bool zeroForOne = target < _tick();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -1e30, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_Seed_RejectsEmpty() public {
        _fund(100_000 ether);
        vm.expectRevert(abi.encodeWithSelector(IActiveLiquidityManager.InvalidPosition.selector, 0));
        alm.seed(new IActiveLiquidityManager.Position[](0));
    }

    function test_Seed_IgnoresThePause() public {
        _fund(100_000 ether);
        vm.prank(KEEPER);
        alm.setPaused(true);
        alm.seed(_positions(-600, 600, 1e24));
        assertEq(alm.positions().length, 1);
        assertTrue(alm.paused());
    }

    function test_WithdrawAll_ReturnsEverythingEvenWhenPaused() public {
        _fund(100_000 ether);
        alm.seed(_positions(-600, 600, 1e24));
        vm.prank(KEEPER);
        alm.setPaused(true);

        uint256 venture0 = _token0().balanceOf(VENTURE);
        vm.prank(VENTURE);
        alm.withdrawAll();

        assertEq(alm.positions().length, 0);
        assertEq(_token0().balanceOf(address(alm)), 0);
        assertEq(_token1().balanceOf(address(alm)), 0);
        assertApproxEqAbs(_token0().balanceOf(VENTURE) - venture0, 100_000 ether, 2);
        (uint128 liq,,) = manager.getPositionInfo(id, address(alm), -600, 600, bytes32(0));
        assertEq(liq, 0);
    }

    function test_WithdrawAll_And_Defund_OnlyVenture() public {
        _fund(10 ether);
        vm.expectRevert(IActiveLiquidityManager.CallerNotVenture.selector);
        alm.withdrawAll();
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.CallerNotVenture.selector);
        alm.defund(1 ether, 1 ether);

        vm.prank(VENTURE);
        alm.defund(1 ether, 2 ether);
        assertEq(_token0().balanceOf(address(alm)), 9 ether);
        assertEq(_token1().balanceOf(address(alm)), 8 ether);
    }

    function test_SetPaused_Permissions() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(IActiveLiquidityManager.CallerCannotPause.selector);
        alm.setPaused(true);

        vm.prank(HUB_OWNER);
        alm.setPaused(true);
        assertTrue(alm.paused());

        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.CallerCannotPause.selector);
        alm.setPaused(false);

        vm.prank(VENTURE);
        alm.setPaused(false);
        assertFalse(alm.paused());

        vm.prank(KEEPER);
        alm.setPaused(true);
        _ageOracle(13 hours);
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.Paused.selector);
        alm.rebalance(_positions(-600, 600, 1e20));
    }

    function test_Keeper_DefaultsToHubAndVentureCanOverride() public {
        assertEq(alm.keeper(), KEEPER);
        vm.prank(KEEPER);
        vm.expectRevert(IActiveLiquidityManager.CallerNotVenture.selector);
        alm.setKeeper(address(0x777));

        vm.prank(VENTURE);
        alm.setKeeper(address(0x777));
        assertEq(alm.keeper(), address(0x777));
    }

    function test_SetConstraints_Validates() public {
        IActiveLiquidityManager.Constraints memory c = _defaultConstraints();
        vm.startPrank(VENTURE);
        c.maxPositions = 9;
        vm.expectRevert(IActiveLiquidityManager.InvalidConstraints.selector);
        alm.setConstraints(c);
        c.maxPositions = 2;
        c.minWidthTicks = 30;
        vm.expectRevert(IActiveLiquidityManager.InvalidConstraints.selector);
        alm.setConstraints(c);
        c.minWidthTicks = 600;
        c.maxWidthTicks = 300;
        vm.expectRevert(IActiveLiquidityManager.InvalidConstraints.selector);
        alm.setConstraints(c);
        c.maxWidthTicks = 6000;
        c.maxTwapDeviationTicks = alm.maxTwapDeviationCap() + 1;
        vm.expectRevert(IActiveLiquidityManager.InvalidConstraints.selector);
        alm.setConstraints(c);
        c.maxTwapDeviationTicks = alm.maxTwapDeviationCap();
        alm.setConstraints(c);
        vm.stopPrank();
        assertEq(alm.constraints().maxPositions, 2);
    }

    /// @dev Same ticks and salt as the anchor's position, but V4 keys by owner, so closing the
    ///      ALM's full-range position leaves the anchor untouched.
    function test_AnchorPositionIsolated() public {
        _fund(100_000 ether);
        IActiveLiquidityManager.Constraints memory c = _defaultConstraints();
        c.maxWidthTicks = TickMath.maxUsableTick(SPACING) - TickMath.minUsableTick(SPACING);
        vm.prank(VENTURE);
        alm.setConstraints(c);
        uint128 anchorBefore = vault.currentLiquidity();
        alm.seed(_positions(TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), 1e20));
        _ageOracle(13 hours);
        vm.prank(KEEPER);
        alm.rebalance(new IActiveLiquidityManager.Position[](0));
        assertEq(vault.currentLiquidity(), anchorBefore);
    }
}
