// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {UmiaHook} from "../../src/periphery/UmiaHook.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {UmiaHookV2} from "../../src/periphery/UmiaHookV2.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {IUmiaHookV2} from "../../src/interfaces/IUmiaHookV2.sol";
import {SpotMarketOracle} from "../../src/libraries/SpotMarketOracle.sol";

interface IHookOracle {
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory, uint144[] memory);
    function observeLong(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory, uint144[] memory);
}

contract UmiaHookV2TestBase is Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant HUB = address(0xB0B);
    address constant VENTURE = address(0x1234);
    address constant HUB_VAULT = address(0xA11CE);

    // Low 14 bits = 0x3A80 (beforeInitialize, afterInitialize, before{Add,Remove}Liquidity, beforeSwap).
    address constant V1_ADDR = address(uint160(0x1111 << 20) | 0x3A80);
    address constant V2_ADDR = address(uint160(0x2222 << 20) | 0x3A80);

    int24 constant SPACING = 60;
    int256 constant LIQ = 1e24;
    // Hour-aligned plus ten minutes, so every write lands mid-bucket.
    uint256 constant T0 = 480_000 hours + 600;

    UmiaHook v1;
    UmiaHookV2 v2;
    PoolModifyLiquidityTest activeRouter;

    function setUp() public virtual {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        activeRouter = new PoolModifyLiquidityTest(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(activeRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(activeRouter), type(uint256).max);

        deployCodeTo("UmiaHook.sol:UmiaHook", abi.encode(OWNER), V1_ADDR);
        deployCodeTo("UmiaHookV2.sol:UmiaHookV2", abi.encode(OWNER), V2_ADDR);
        v1 = UmiaHook(V1_ADDR);
        v2 = UmiaHookV2(V2_ADDR);

        vm.startPrank(OWNER);
        v1.initialize(FACTORY, manager);
        v2.initialize(FACTORY, manager, HUB);
        vm.stopPrank();

        vm.mockCall(FACTORY, abi.encodeWithSignature("isLBP(address)", address(this)), abi.encode(true));
        vm.mockCall(HUB, abi.encodeWithSignature("spotMigrator()"), abi.encode(address(this)));
    }

    function _key(address hook, uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, fee, SPACING, IHooks(hook));
    }

    function _fullRange(int256 delta) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(SPACING),
            tickUpper: TickMath.maxUsableTick(SPACING),
            liquidityDelta: delta,
            salt: 0
        });
    }

    function _v1Pool(uint24 fee) internal returns (PoolKey memory k) {
        k = _key(V1_ADDR, fee);
        v1.registerPool(
            k, IUmiaHook.PoolConfig({launcher: address(0), venture: VENTURE, operator: address(modifyLiquidityRouter)})
        );
        manager.initialize(k, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(k, _fullRange(LIQ), ZERO_BYTES);
    }

    function _setHubPool(PoolKey memory k) internal {
        vm.mockCall(HUB, abi.encodeWithSelector(IUmiaHub.ventureLiquidityVault.selector), abi.encode(HUB_VAULT));
        vm.mockCall(HUB_VAULT, abi.encodeWithSelector(ISpotLiquidityVault.getPoolKey.selector), abi.encode(k));
    }

    function _v2Cfg() internal view returns (IUmiaHookV2.PoolConfig memory) {
        return IUmiaHookV2.PoolConfig({
            launcher: address(0),
            venture: VENTURE,
            anchorOperator: address(modifyLiquidityRouter),
            activeOperator: address(activeRouter)
        });
    }

    function _tick(PoolKey memory k) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(k.toId());
    }

    function _sqrtPrice(PoolKey memory k) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(k.toId());
    }

    /// @dev Swap to exactly `target` using a price limit, so pools with any liquidity land on the same tick.
    function _moveTo(PoolKey memory k, int24 target) internal {
        int24 current = _tick(k);
        require(current != target, "no-op move");
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: target < current,
                amountSpecified: -1e30,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Deterministic tick path, never repeating the previous value.
    function _pathTick(uint256 step) internal pure returns (int24) {
        return int24(int256((step * 7919) % 4001) - 2000) * 3 + 1;
    }

    function _cum(address hook, PoolKey memory k, uint32 secondsAgo, bool long) internal view returns (int48) {
        uint32[] memory s = new uint32[](1);
        s[0] = secondsAgo;
        (int48[] memory c,) = long ? IHookOracle(hook).observeLong(k, s) : IHookOracle(hook).observe(k, s);
        return c[0];
    }

    function _now() internal view returns (uint32) {
        return uint32(vm.getBlockTimestamp());
    }
}

contract UmiaHookV2RegistrationTest is UmiaHookV2TestBase {
    using PoolIdLibrary for PoolKey;

    function test_HookAddressValidatesSameMaskAsV1() public view {
        Hooks.validateHookPermissions(IHooks(V2_ADDR), v2.getHookPermissions());
        Hooks.validateHookPermissions(IHooks(V2_ADDR), v1.getHookPermissions());
    }

    function test_Initialize_OneShotAndZeroChecks() public {
        UmiaHookV2 fresh = new UmiaHookV2(OWNER);
        vm.startPrank(OWNER);
        vm.expectRevert(IUmiaHookV2.InvalidHub.selector);
        fresh.initialize(FACTORY, manager, address(0));
        fresh.initialize(FACTORY, manager, HUB);
        vm.expectRevert(IUmiaHookV2.FactoryAlreadySet.selector);
        fresh.initialize(FACTORY, manager, HUB);
        vm.stopPrank();
        assertEq(fresh.hub(), HUB);
    }

    function test_RegisterPool_RequiresFactoryLBP() public {
        PoolKey memory k = _key(V2_ADDR, 3000);
        vm.mockCall(FACTORY, abi.encodeWithSignature("isLBP(address)", address(0xBAD)), abi.encode(false));
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IUmiaHookV2.NotFactoryDeployedLBP.selector, address(0xBAD)));
        v2.registerPool(k, _v2Cfg());
    }

    function test_RegisterPool_StoresConfigAndForcesLauncher() public {
        PoolKey memory k = _key(V2_ADDR, 3000);
        IUmiaHookV2.PoolConfig memory cfg = _v2Cfg();
        cfg.launcher = address(0xBAD);
        v2.registerPool(k, cfg);
        (address launcher, address venture, address anchor, address active) = v2.pools(k.toId());
        assertEq(launcher, address(this));
        assertEq(venture, VENTURE);
        assertEq(anchor, address(modifyLiquidityRouter));
        assertEq(active, address(activeRouter));
    }

    function test_RegisterPool_RejectsBadOperators() public {
        PoolKey memory k = _key(V2_ADDR, 3000);
        IUmiaHookV2.PoolConfig memory cfg = _v2Cfg();
        cfg.anchorOperator = address(0);
        vm.expectRevert(IUmiaHookV2.InvalidOperator.selector);
        v2.registerPool(k, cfg);

        cfg.anchorOperator = address(activeRouter);
        vm.expectRevert(IUmiaHookV2.InvalidOperator.selector);
        v2.registerPool(k, cfg);
    }

    function test_RegisterPool_AllowsNoActiveOperator() public {
        PoolKey memory k = _key(V2_ADDR, 3000);
        IUmiaHookV2.PoolConfig memory cfg = _v2Cfg();
        cfg.activeOperator = address(0);
        v2.registerPool(k, cfg);
        (,,, address active) = v2.pools(k.toId());
        assertEq(active, address(0));
    }

    function test_RegisterMigratedPool_RequiresSpotMigrator() public {
        PoolKey memory old = _v1Pool(3000);
        vm.mockCall(HUB, abi.encodeWithSignature("spotMigrator()"), abi.encode(address(0xCAFE)));
        vm.expectRevert(abi.encodeWithSelector(IUmiaHookV2.NotSpotMigrator.selector, address(this)));
        v2.registerMigratedPool(_key(V2_ADDR, 3000), _v2Cfg(), old);
    }

    function test_RegisterMigratedPool_RejectsMismatchedPredecessor() public {
        PoolKey memory old = _v1Pool(3000);
        PoolKey memory k = _key(V2_ADDR, 3000);
        _setHubPool(old);

        PoolKey memory otherPair = old;
        otherPair.currency1 = Currency.wrap(address(0xEEEE));
        vm.expectRevert(IUmiaHookV2.InvalidPredecessor.selector);
        v2.registerMigratedPool(k, _v2Cfg(), otherPair);

        IUmiaHookV2.PoolConfig memory cfg = _v2Cfg();
        cfg.venture = address(0x9999);
        vm.expectRevert(IUmiaHookV2.InvalidPredecessor.selector);
        v2.registerMigratedPool(k, cfg, old);
    }

    function test_RegisterMigratedPool_RejectsUninitializedPredecessor() public {
        PoolKey memory old = _key(V1_ADDR, 3000);
        v1.registerPool(
            old,
            IUmiaHook.PoolConfig({launcher: address(0), venture: VENTURE, operator: address(modifyLiquidityRouter)})
        );
        _setHubPool(old);
        vm.expectRevert(IUmiaHookV2.InvalidPredecessor.selector);
        v2.registerMigratedPool(_key(V2_ADDR, 3000), _v2Cfg(), old);
    }

    function test_RegisterMigratedPool_RejectsPoolTheHubDoesNotRecord() public {
        PoolKey memory old = _v1Pool(3000);
        _setHubPool(_v1Pool(500));
        vm.expectRevert(IUmiaHookV2.InvalidPredecessor.selector);
        v2.registerMigratedPool(_key(V2_ADDR, 3000), _v2Cfg(), old);

        vm.mockCall(HUB, abi.encodeWithSelector(IUmiaHub.ventureLiquidityVault.selector), abi.encode(address(0)));
        vm.expectRevert(IUmiaHookV2.InvalidPredecessor.selector);
        v2.registerMigratedPool(_key(V2_ADDR, 3000), _v2Cfg(), old);
    }
}

contract UmiaHookV2LiquidityGatingTest is UmiaHookV2TestBase {
    using PoolIdLibrary for PoolKey;

    PoolKey k;

    function setUp() public override {
        super.setUp();
        k = _key(V2_ADDR, 3000);
        v2.registerPool(k, _v2Cfg());
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function _range(int24 lower, int24 upper, int256 delta) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: delta, salt: 0});
    }

    function test_Anchor_FullRangeOnly() public {
        modifyLiquidityRouter.modifyLiquidity(k, _fullRange(1e18), ZERO_BYTES);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(k, _range(-600, 600, 1e18), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(k, _fullRange(-1e18), ZERO_BYTES);
    }

    function test_Active_AnyRangeAddAndRemove() public {
        activeRouter.modifyLiquidity(k, _range(-600, 600, 1e18), ZERO_BYTES);
        activeRouter.modifyLiquidity(k, _range(-120, 60, 1e18), ZERO_BYTES);
        activeRouter.modifyLiquidity(k, _fullRange(1e18), ZERO_BYTES);
        activeRouter.modifyLiquidity(k, _range(-600, 600, -1e18), ZERO_BYTES);
    }

    function test_ThirdParty_CannotAdd() public {
        vm.expectRevert();
        modifyLiquidityNoChecks.modifyLiquidity(k, _fullRange(1e18), ZERO_BYTES);
    }

    function test_Active_CannotRemoveAnchorPosition() public {
        modifyLiquidityRouter.modifyLiquidity(k, _fullRange(1e18), ZERO_BYTES);
        vm.expectRevert();
        activeRouter.modifyLiquidity(k, _fullRange(-1e18), ZERO_BYTES);
    }

    function test_NoActiveOperator_RejectsEveryoneButAnchor() public {
        PoolKey memory k2 = _key(V2_ADDR, 500);
        IUmiaHookV2.PoolConfig memory cfg = _v2Cfg();
        cfg.activeOperator = address(0);
        v2.registerPool(k2, cfg);
        manager.initialize(k2, SQRT_PRICE_1_1);
        vm.expectRevert();
        activeRouter.modifyLiquidity(k2, _range(-600, 600, 1e18), ZERO_BYTES);
    }
}

/// @notice A fresh V2 pool's oracle answers exactly like a V1 pool given the same history.
contract UmiaHookV2FreshPoolDifferentialTest is UmiaHookV2TestBase {
    function test_FreshPool_MatchesV1() public {
        PoolKey memory a = _v1Pool(3000);
        PoolKey memory b = _key(V2_ADDR, 3000);
        v2.registerPool(b, _v2Cfg());
        manager.initialize(b, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(b, _fullRange(LIQ), ZERO_BYTES);

        v1.increaseCardinalityNext(a, 40);
        v1.increaseCoarseCardinalityNext(a, 40);
        v2.increaseCardinalityNext(b, 40);
        v2.increaseCoarseCardinalityNext(b, 40);

        for (uint256 i = 1; i <= 30; i++) {
            vm.warp(T0 + i * 1 hours + (i % 3) * 400);
            int24 t = _pathTick(i);
            _moveTo(a, t);
            _moveTo(b, t);
        }
        vm.warp(vm.getBlockTimestamp() + 1234);

        uint32[] memory s = new uint32[](6);
        (s[0], s[1], s[2], s[3], s[4], s[5]) = (0, 60, 1800, 3 hours + 17, 20 hours, 29 hours);
        (int48[] memory c1, uint144[] memory l1) = v1.observe(a, s);
        (int48[] memory c2, uint144[] memory l2) = v2.observe(b, s);
        (int48[] memory c3, uint144[] memory l3) = v1.observeLong(a, s);
        (int48[] memory c4, uint144[] memory l4) = v2.observeLong(b, s);
        for (uint256 i = 0; i < s.length; i++) {
            assertEq(c1[i], c2[i]);
            assertEq(l1[i], l2[i]);
            assertEq(c3[i], c4[i]);
            assertEq(l3[i], l4[i]);
        }
    }
}

contract UmiaHookV2BackfillTest is UmiaHookV2TestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 constant STEP = 3 hours;
    uint256 constant PRE_STEPS = 256;
    int48 constant PATH_RANGE = 12_000;

    PoolKey old;
    PoolKey ref;
    PoolKey neu;
    uint32 handoverTs;

    function setUp() public override {
        super.setUp();
        old = _v1Pool(3000);
        ref = _v1Pool(500);
        v1.increaseCardinalityNext(old, 20);
        v1.increaseCardinalityNext(ref, 20);
        v1.increaseCoarseCardinalityNext(old, 300);
        v1.increaseCoarseCardinalityNext(ref, 1200);

        for (uint256 i = 1; i <= PRE_STEPS; i++) {
            vm.warp(T0 + i * STEP);
            int24 t = _pathTick(i);
            _moveTo(old, t);
            _moveTo(ref, t);
        }
        vm.warp(T0 + PRE_STEPS * STEP + 1 hours);
    }

    function _migrate(bool growCoarse) internal {
        modifyLiquidityRouter.modifyLiquidity(old, _fullRange(-LIQ), ZERO_BYTES);
        ModifyLiquidityParams memory poke = _fullRange(1e9);
        poke.salt = bytes32(uint256(1));
        modifyLiquidityRouter.modifyLiquidity(ref, poke, ZERO_BYTES);

        neu = _key(V2_ADDR, 3000);
        _setHubPool(old);
        v2.registerMigratedPool(neu, _v2Cfg(), old);
        manager.initialize(neu, _sqrtPrice(old));
        modifyLiquidityRouter.modifyLiquidity(neu, _fullRange(LIQ), ZERO_BYTES);
        v2.increaseCardinalityNext(neu, 20);
        if (growCoarse) v2.increaseCoarseCardinalityNext(neu, 900);
        handoverTs = _now();
    }

    function _postHours(uint256 fromHour, uint256 toHour, bool moveRef) internal {
        for (uint256 h = fromHour; h <= toHour; h++) {
            vm.warp(handoverTs + h * 1 hours);
            int24 t = _pathTick(PRE_STEPS + h);
            _moveTo(neu, t);
            if (moveRef) _moveTo(ref, t);
        }
    }

    function _monthArea(address hook, PoolKey memory k) internal view returns (int48) {
        return _cum(hook, k, 0, true) - _cum(hook, k, 30 days, true);
    }

    function _readMonth(PoolKey memory k) internal view returns (bool ok) {
        uint32[] memory s = new uint32[](2);
        s[0] = 30 days;
        try v2.observeLong(k, s) {
            ok = true;
        } catch (bytes memory err) {
            assertEq(bytes4(err), SpotMarketOracle.TargetPredatesOldestObservation.selector);
        }
    }

    function test_Backfill_Layout() public {
        vm.recordLogs();
        _migrate(false);

        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = v2.coarseOracleStates(neu.toId());
        assertEq(index, 121);
        assertEq(cardinality, 122);
        assertEq(cardinalityNext, 122 + v2.BACKFILL_RESERVE());
        (uint32 reservedTs,,, bool reservedInitialized) = v2.getCoarseObservation(neu.toId(), 122);
        assertEq(reservedTs, 0, "the reserve is not pre-written");
        assertFalse(reservedInitialized);

        int48 v1AtHandover = _cum(V1_ADDR, old, 0, true);
        for (uint16 i = 0; i < 122; i++) {
            uint32 ago = uint32(121 - i) * v2.BACKFILL_SPACING();
            (uint32 ts, int48 tickCumulative,, bool initialized) = v2.getCoarseObservation(neu.toId(), i);
            assertTrue(initialized);
            assertEq(ts, handoverTs - ago);
            assertEq(tickCumulative, _cum(V1_ADDR, old, ago, true) - v1AtHandover);
        }
        (, int48 handoverCumulative, uint144 handoverSpl,) = v2.getCoarseObservation(neu.toId(), 121);
        assertEq(handoverCumulative, 0);
        assertEq(handoverSpl, 0);
        assertEq(_cum(V2_ADDR, neu, 0, true), 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != V2_ADDR || logs[i].topics[0] != IUmiaHookV2.PoolPredecessorSet.selector) continue;
            found = true;
            assertEq(logs[i].topics[1], PoolId.unwrap(neu.toId()));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(V1_ADDR))));
            assertEq(logs[i].topics[3], PoolId.unwrap(old.toId()));
            (uint32 backfillStart, uint16 observations) = abi.decode(logs[i].data, (uint32, uint16));
            assertEq(backfillStart, handoverTs - 121 * v2.BACKFILL_SPACING());
            assertEq(observations, 122);
        }
        assertTrue(found);
    }

    function test_Backfill_ExactAtSamplePoints() public {
        _migrate(true);
        _postHours(1, 24, true);
        assertEq((30 days - 24 hours) % v2.BACKFILL_SPACING(), 0);
        assertApproxEqAbs(_monthArea(V2_ADDR, neu), _monthArea(V1_ADDR, ref), 2);
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_Backfill_WithinInterpolationBound(uint256 hoursAfter, uint256 extraSeconds) public {
        _migrate(true);
        uint256 h = bound(hoursAfter, 1, 30);
        _postHours(1, h, true);
        vm.warp(vm.getBlockTimestamp() + bound(extraSeconds, 0, 59 minutes));
        int48 tolerance = PATH_RANGE * int48(int256(uint256(v2.BACKFILL_SPACING() + STEP))) / 4 + 2;
        assertApproxEqAbs(_monthArea(V2_ADDR, neu), _monthArea(V1_ADDR, ref), uint256(int256(tolerance)));
    }

    function test_Backfill_ClampsToPredecessorHistory() public {
        PoolKey memory young = _v1Pool(10_000);
        v1.increaseCoarseCardinalityNext(young, 50);
        uint32 start = _now();
        for (uint256 i = 1; i <= 9; i++) {
            vm.warp(start + i * STEP);
            _moveTo(young, _pathTick(i));
        }
        vm.warp(start + 28 hours);
        PoolKey memory k = _migrateFrom(young, 10_000);

        (uint16 index, uint16 cardinality,) = v2.coarseOracleStates(k.toId());
        assertEq(index, 4);
        assertEq(cardinality, 5);
        _cum(V2_ADDR, k, 24 hours, true);
        uint32[] memory s = new uint32[](1);
        s[0] = 24 hours + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SpotMarketOracle.TargetPredatesOldestObservation.selector, _now() - 24 hours, _now() - 24 hours - 1
            )
        );
        v2.observeLong(k, s);

        PoolKey memory baby = _v1Pool(100);
        vm.warp(_now() + 5 hours);
        PoolKey memory k2 = _migrateFrom(baby, 100);
        (index, cardinality,) = v2.coarseOracleStates(k2.toId());
        assertEq(index, 0);
        assertEq(cardinality, 1);
    }

    function _migrateFrom(PoolKey memory predecessor, uint24 fee) internal returns (PoolKey memory k) {
        modifyLiquidityRouter.modifyLiquidity(predecessor, _fullRange(-LIQ), ZERO_BYTES);
        k = _key(V2_ADDR, fee);
        _setHubPool(predecessor);
        v2.registerMigratedPool(k, _v2Cfg(), predecessor);
        manager.initialize(k, _sqrtPrice(predecessor));
    }

    function test_Backfill_IgnoresPostHandoverPredecessorWrites() public {
        _migrate(true);
        uint32[3] memory targets = [handoverTs - 1 hours, handoverTs - 5 days, handoverTs - 29 days];
        int48[3] memory before;
        for (uint256 i = 0; i < 3; i++) {
            before[i] = _cum(V2_ADDR, neu, _now() - targets[i], true);
        }

        for (uint256 h = 1; h <= 30; h++) {
            vm.warp(handoverTs + h * 1 hours);
            _moveTo(old, h % 2 == 0 ? int24(60_000) : int24(-60_000));
        }
        assertEq(manager.getLiquidity(old.toId()), 0);

        for (uint256 i = 0; i < 3; i++) {
            assertEq(_cum(V2_ADDR, neu, _now() - targets[i], true), before[i]);
        }
    }

    function test_Backfill_ChainsAcrossTwoMigrations() public {
        _migrate(true);
        _postHours(1, 48, true);

        modifyLiquidityRouter.modifyLiquidity(neu, _fullRange(-LIQ), ZERO_BYTES);
        PoolKey memory third = _key(V2_ADDR, 10_000);
        _setHubPool(neu);
        v2.registerMigratedPool(third, _v2Cfg(), neu);
        manager.initialize(third, _sqrtPrice(neu));

        (, uint16 cardinality,) = v2.coarseOracleStates(third.toId());
        assertEq(cardinality, 122);
        assertEq((_now() - handoverTs) % v2.BACKFILL_SPACING(), 0);
        assertApproxEqAbs(_monthArea(V2_ADDR, third), _monthArea(V1_ADDR, ref), 2);
    }

    /// @notice With no keeper growth, the reserve keeps the 30-day read serving until the pool's
    ///         own history spans the window, and after the ring first wraps.
    function test_Backfill_ServesAMonthWithoutGrowth() public {
        _migrate(false);
        uint16[5] memory checkpoints = [uint16(59), 200, 500, 720, 760];
        uint256 h = 1;
        for (uint256 c = 0; c < checkpoints.length; c++) {
            _postHours(h, checkpoints[c], false);
            assertTrue(_readMonth(neu));
            h = checkpoints[c] + 1;
        }
    }

    function test_Backfill_OneSampleServesAMonthWithLateCheckpoints() public {
        vm.warp((_now() / 1 hours + 1) * 1 hours);
        PoolKey memory baby = _v1Pool(100);
        vm.warp(_now() + 5 hours);
        PoolKey memory k = _migrateFrom(baby, 100);
        modifyLiquidityRouter.modifyLiquidity(k, _fullRange(LIQ), ZERO_BYTES);
        (, uint16 cardinality,) = v2.coarseOracleStates(k.toId());
        assertEq(cardinality, 1);

        uint32 h0 = _now();
        for (uint256 h = 1; h <= 720; h++) {
            vm.warp(h0 + h * 1 hours + 59 minutes);
            _moveTo(k, _pathTick(h));
        }
        for (uint256 h = 721; h <= 722; h++) {
            vm.warp(h0 + h * 1 hours);
            _moveTo(k, _pathTick(h));
            assertTrue(_readMonth(k));
        }
    }

    function test_Backfill_GrowthBeforeTheWrapKeepsHistory() public {
        _migrate(false);
        _postHours(1, 10, false);
        v2.increaseCoarseCardinalityNext(neu, 900);
        _postHours(11, 100, false);
        assertTrue(_readMonth(neu));
    }

    function test_Backfill_Gas() public {
        modifyLiquidityRouter.modifyLiquidity(old, _fullRange(-LIQ), ZERO_BYTES);
        neu = _key(V2_ADDR, 3000);
        _setHubPool(old);
        uint256 gasBefore = gasleft();
        v2.registerMigratedPool(neu, _v2Cfg(), old);
        uint256 used = gasBefore - gasleft();
        console.log("registerMigratedPool gas", used);
        assertLt(used, 8_000_000);
    }

    function test_Observe_NotBackfilled() public {
        _migrate(true);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint32[] memory s = new uint32[](1);
        s[0] = 11 minutes;
        vm.expectRevert();
        v2.observe(neu, s);
    }
}
