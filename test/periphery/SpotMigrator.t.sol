// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {UmiaHook} from "../../src/periphery/UmiaHook.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {UmiaHookV2} from "../../src/periphery/UmiaHookV2.sol";
import {IUmiaHookV2} from "../../src/interfaces/IUmiaHookV2.sol";
import {SpotLiquidityVault} from "../../src/core/SpotLiquidityVault.sol";
import {SpotLiquidityVaultV2} from "../../src/core/SpotLiquidityVaultV2.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {ActiveLiquidityManager} from "../../src/core/ActiveLiquidityManager.sol";
import {IActiveLiquidityManager} from "../../src/interfaces/IActiveLiquidityManager.sol";
import {SpotMigrator} from "../../src/periphery/SpotMigrator.sol";
import {ActiveSlices} from "../../src/libraries/ActiveSlices.sol";
import {SpotLiquidityV2Code} from "../../src/periphery/SpotLiquidityV2Code.sol";
import {TwapMath} from "../../src/libraries/TwapMath.sol";
import {SpotTwapGuard} from "../../src/libraries/SpotTwapGuard.sol";

/// @dev Anyone can deploy a contract that calls itself a venture and register a vault for it.
contract FakeVenture {
    address public lbp;

    constructor(address _lbp) {
        lbp = _lbp;
    }
}

/// @dev A "V1 vault" that reports whatever pool, venture and hub its deployer wants.
contract FakeVault {
    PoolKey internal key;
    address public venture;
    address public HUB;

    constructor(PoolKey memory _key, address _venture, address _hub) {
        key = _key;
        venture = _venture;
        HUB = _hub;
    }

    function getPoolKey() external view returns (PoolKey memory) {
        return key;
    }
}

contract SpotMigratorTest is Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant OWNER = address(0xABCD);
    address constant FACTORY = address(0xF00D);
    address constant VENTURE = address(0x1234);
    address constant V1_ADDR = address(uint160(0x1111 << 20) | 0x3A80);
    address constant V2_ADDR = address(uint160(0x2222 << 20) | 0x3A80);
    uint24 constant FEE = 10_000;
    int24 constant SPACING = 60;
    uint256 constant T0 = 480_000 hours + 600;

    UmiaHub hub;
    UmiaHook v1;
    UmiaHookV2 v2;
    SpotLiquidityVault oldVault;
    SpotMigrator migrator;
    PoolKey oldKey;

    function setUp() public {
        vm.warp(T0);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        hub = UmiaHub(address(new ERC1967Proxy(address(new UmiaHub()), abi.encodeCall(UmiaHub.initialize, (OWNER)))));

        vm.mockCall(VENTURE, abi.encodeWithSignature("token()"), abi.encode(Currency.unwrap(currency0)));
        vm.mockCall(VENTURE, abi.encodeWithSignature("moneyToken()"), abi.encode(Currency.unwrap(currency1)));
        vm.mockCall(VENTURE, abi.encodeWithSignature("lbp()"), abi.encode(address(this)));
        vm.mockCall(FACTORY, abi.encodeWithSignature("isLBP(address)", address(this)), abi.encode(true));

        deployCodeTo("UmiaHook.sol:UmiaHook", abi.encode(OWNER), V1_ADDR);
        deployCodeTo("UmiaHookV2.sol:UmiaHookV2", abi.encode(OWNER), V2_ADDR);
        v1 = UmiaHook(V1_ADDR);
        v2 = UmiaHookV2(V2_ADDR);
        vm.startPrank(OWNER);
        v1.initialize(FACTORY, manager);
        v2.initialize(FACTORY, manager, address(hub));
        vm.stopPrank();

        oldVault = new SpotLiquidityVault(address(hub), VENTURE, address(manager), V1_ADDR, FEE, SPACING);
        oldKey = PoolKey(currency0, currency1, FEE, SPACING, IHooks(V1_ADDR));
        v1.registerPool(
            oldKey, IUmiaHook.PoolConfig({launcher: address(0), venture: VENTURE, operator: address(oldVault)})
        );
        manager.initialize(oldKey, SQRT_PRICE_1_1);
        hub.registerSpotLiquidityVault(VENTURE, address(oldVault));
        _token0().approve(address(oldVault), type(uint256).max);
        _token1().approve(address(oldVault), type(uint256).max);
        oldVault.bootstrapFromLBP(1_000_000 ether, 1_000_000 ether, VENTURE);

        for (uint256 i = 1; i <= 156; i++) {
            vm.warp(T0 + i * 5 minutes);
            _swap(oldKey, i % 2 == 0, -1_000 ether);
        }

        migrator = new SpotMigrator(address(hub), manager, V2_ADDR, V1_ADDR, new SpotLiquidityV2Code());
        vm.prank(OWNER);
        hub.setSpotMigrator(address(migrator));
        migrator.prepare(VENTURE);
    }

    function _token0() internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(currency0));
    }

    function _token1() internal view returns (MockERC20) {
        return MockERC20(Currency.unwrap(currency1));
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _params() internal pure returns (SpotMigrator.MigrateParams memory p) {
        p.anchorBps = 7500;
        p.activeSlices = new ActiveSlices.Slice[](2);
        p.activeSlices[0] = ActiveSlices.Slice({tickLowerOffset: -600, tickUpperOffset: 660, bps: 6000});
        p.activeSlices[1] = ActiveSlices.Slice({tickLowerOffset: -3000, tickUpperOffset: 3060, bps: 4000});
    }

    /// @dev Both proposal actions, as the venture, in one external call so a revert rolls back both.
    function runProposal(SpotMigrator.MigrateParams memory p) external {
        uint256 shares = oldVault.shareBalance(VENTURE);
        vm.startPrank(VENTURE);
        oldVault.withdraw(shares, 0, 0, address(migrator));
        migrator.migrate(p);
        vm.stopPrank();
    }

    function _withdrawn() internal returns (uint256 ventureOut, uint256 moneyOut) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(oldVault) && logs[i].topics[0] == ISpotLiquidityVault.Withdraw.selector) {
                (, ventureOut, moneyOut) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
    }

    function _longTwapTick(uint32 window) internal view returns (int24) {
        ISpotLiquidityVault vault = ISpotLiquidityVault(hub.ventureLiquidityVault(VENTURE));
        uint32[] memory s = new uint32[](2);
        s[0] = window;
        (int48[] memory c,) = IUmiaHook(vault.hook()).observeLong(vault.getPoolKey(), s);
        return TwapMath.averageTick(c[0], c[1], window);
    }

    function test_Prepare_DerivesFromV1AndRunsOnce() public {
        (address vault, address alm,) = migrator.prepared(VENTURE);
        assertEq(SpotLiquidityVaultV2(vault).bootstrapper(), address(migrator));
        assertEq(SpotLiquidityVaultV2(vault).hook(), V2_ADDR);
        assertEq(SpotLiquidityVaultV2(vault).getPoolKey().fee, FEE);
        assertEq(ActiveLiquidityManager(alm).bootstrapper(), address(migrator));
        assertEq(ActiveLiquidityManager(alm).constraints().maxTwapDeviationTicks, 100);

        vm.expectRevert(SpotMigrator.AlreadyPrepared.selector);
        migrator.prepare(VENTURE);
        vm.expectRevert(SpotMigrator.NoSpotVault.selector);
        migrator.prepare(address(0x999));
    }

    function test_Migrate_EndToEnd() public {
        assertFalse(migrator.seamBlocked(VENTURE));
        (address newVault, address alm,) = migrator.prepared(VENTURE);
        (uint160 v1Price,,,) = manager.getSlot0(oldKey.toId());
        uint256 ventureStart0 = _token0().balanceOf(VENTURE);
        uint256 ventureStart1 = _token1().balanceOf(VENTURE);

        PoolId expectedId = PoolKey(oldKey.currency0, oldKey.currency1, FEE, SPACING, IHooks(V2_ADDR)).toId();
        vm.recordLogs();
        vm.expectEmit(true, true, true, false, V2_ADDR);
        emit IUmiaHookV2.PoolPredecessorSet(expectedId, V1_ADDR, oldKey.toId(), 0, 0);
        this.runProposal(_params());
        (uint256 v1Venture, uint256 v1Money) = _withdrawn();

        assertEq(hub.ventureLiquidityVault(VENTURE), newVault);
        assertEq(oldVault.shareBalance(VENTURE), 0);
        assertEq(oldVault.currentLiquidity(), 0);
        assertGt(SpotLiquidityVaultV2(newVault).shareBalance(VENTURE), 0);
        assertEq(SpotLiquidityVaultV2(newVault).activeManager(), alm);
        assertEq(ActiveLiquidityManager(alm).positions().length, 2);
        assertEq(_token0().balanceOf(address(migrator)), 0);
        assertEq(_token1().balanceOf(address(migrator)), 0);

        PoolKey memory newKey = SpotLiquidityVaultV2(newVault).getPoolKey();
        (uint160 v2Price,,,) = manager.getSlot0(newKey.toId());
        assertEq(v2Price, v1Price);

        (uint256 anchorVenture, uint256 anchorMoney) = SpotLiquidityVaultV2(newVault).totalAssets();
        (uint256 activeVenture, uint256 activeMoney) = ActiveLiquidityManager(alm).totalAssets();
        uint256 surplusVenture = _token0().balanceOf(VENTURE) - ventureStart0;
        uint256 surplusMoney = _token1().balanceOf(VENTURE) - ventureStart1;
        assertApproxEqAbs(anchorVenture + activeVenture + surplusVenture, v1Venture, 10);
        assertApproxEqAbs(anchorMoney + activeMoney + surplusMoney, v1Money, 10);
        assertApproxEqRel(anchorMoney, v1Money * 3 / 4, 0.001e18);

        assertFalse(migrator.seamBlocked(VENTURE));
    }

    /// @notice What the vesting condition reads (Hub -> vault -> hook -> observeLong) is the same
    ///         in the block before and after the migration.
    function test_Migrate_LongTwapUnchangedAcrossSeam() public {
        for (uint256 i = 1; i <= 13; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _swap(oldKey, i % 2 == 0, -1_000 ether);
        }
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        int24 before = _longTwapTick(12 hours);

        this.runProposal(_params());

        assertEq(_longTwapTick(12 hours), before);
    }

    function test_Migrate_SkewedSpotRevertsAndLeavesV1Intact() public {
        _swap(oldKey, false, -30_000 ether);
        uint256 shares = oldVault.shareBalance(VENTURE);

        assertTrue(migrator.seamBlocked(VENTURE));
        vm.expectRevert(SpotMigrator.SeamPriceDeviationTooHigh.selector);
        this.runProposal(_params());

        assertEq(oldVault.shareBalance(VENTURE), shares);
        assertEq(hub.ventureLiquidityVault(VENTURE), address(oldVault));
    }

    /// @notice Holding V1 spot away for 30 minutes satisfies the 30-minute bound but not the 6-hour one.
    function test_Migrate_SeamRejectsSpotHeldAwayFromLongTwap() public {
        _moveToTick(oldKey, 1500);
        vm.warp(vm.getBlockTimestamp() + 35 minutes);
        assertLe(_distance(_v1TwapTick(30 minutes), 1500), int24(uint24(FEE / 50)));
        assertGt(_distance(_v1TwapTick(6 hours), 1500), 300);

        assertTrue(migrator.seamBlocked(VENTURE));
        vm.expectRevert(SpotMigrator.SeamPriceDeviationTooHigh.selector);
        this.runProposal(_params());

        for (uint256 i = 1; i <= 7; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _swap(oldKey, true, -1 ether);
            _moveToTick(oldKey, 1500);
        }
        assertFalse(migrator.seamBlocked(VENTURE));
    }

    /// @notice The backfilled coarse ring makes the 6-hour check live on the new pool right away,
    ///         where a fresh pool would fail closed for six hours.
    function test_Migrate_LongTwapCheckLiveImmediatelyOnNewPool() public {
        this.runProposal(_params());
        PoolKey memory newKey = SpotLiquidityVaultV2(hub.ventureLiquidityVault(VENTURE)).getPoolKey();

        vm.warp(vm.getBlockTimestamp() + 35 minutes);
        (bool ready, int24 deviation) = SpotTwapGuard.longDeviation(manager, V2_ADDR, newKey, 6 hours);
        assertTrue(ready);
        assertLe(deviation, 50);

        _moveToTick(newKey, 1500);
        vm.warp(vm.getBlockTimestamp() + 35 minutes);
        (ready, deviation) = SpotTwapGuard.longDeviation(manager, V2_ADDR, newKey, 6 hours);
        assertTrue(ready);
        assertGt(deviation, 1000);
    }

    /// @notice The backfill also covers the ALM's 12-hour window, so it can rebalance as soon as the
    ///         short window and the rebalance interval allow, not 12 hours after migration.
    function test_Migrate_AlmCanRebalanceRightAway() public {
        this.runProposal(_params());
        (, address alm,) = migrator.prepared(VENTURE);
        PoolKey memory newKey = SpotLiquidityVaultV2(hub.ventureLiquidityVault(VENTURE)).getPoolKey();

        vm.warp(vm.getBlockTimestamp() + 1);
        _swap(newKey, true, -1 ether);
        vm.warp(vm.getBlockTimestamp() + 65 minutes);
        (bool ready,) = SpotTwapGuard.longDeviation(manager, V2_ADDR, newKey, 12 hours);
        assertTrue(ready);

        IActiveLiquidityManager.Position[] memory current = ActiveLiquidityManager(alm).positions();
        vm.prank(ActiveLiquidityManager(alm).keeper());
        ActiveLiquidityManager(alm).rebalance(current);
        assertEq(ActiveLiquidityManager(alm).positions().length, current.length);
    }

    function _distance(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a - b : b - a;
    }

    /// @notice The seam bound is exactly twice the fee in ticks around V1's 30-minute TWAP.
    function test_Migrate_SeamBoundIsTwiceTheFee() public {
        int24 bound = int24(uint24(FEE / 50));
        int24 twapTick = _v1TwapTick(30 minutes);

        _moveToTick(oldKey, twapTick + bound - 30);
        assertFalse(migrator.seamBlocked(VENTURE));

        _moveToTick(oldKey, twapTick + bound + 30);
        assertTrue(migrator.seamBlocked(VENTURE));
        vm.expectRevert(SpotMigrator.SeamPriceDeviationTooHigh.selector);
        this.runProposal(_params());

        _moveToTick(oldKey, twapTick - bound - 30);
        assertTrue(migrator.seamBlocked(VENTURE));
    }

    function _v1TwapTick(uint32 window) internal view returns (int24) {
        uint32[] memory s = new uint32[](2);
        s[0] = window;
        (int48[] memory c,) = IUmiaHook(V1_ADDR).observe(oldKey, s);
        return TwapMath.averageTick(c[0], c[1], window);
    }

    function _moveToTick(PoolKey memory key, int24 target) internal {
        (, int24 current,,) = manager.getSlot0(key.toId());
        bool zeroForOne = target < current;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -1e30, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(target)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_Migrate_Gating() public {
        vm.expectRevert(SpotMigrator.NotPrepared.selector);
        migrator.migrate(_params());

        vm.prank(VENTURE);
        vm.expectRevert(SpotMigrator.NothingToMigrate.selector);
        migrator.migrate(_params());

        SpotMigrator.MigrateParams memory bad = _params();
        bad.anchorBps = migrator.MIN_ANCHOR_BPS() - 1;
        vm.expectRevert(SpotMigrator.InvalidParams.selector);
        this.runProposal(bad);

        bad = _params();
        bad.activeSlices[0].bps = 7000;
        vm.expectRevert(ActiveSlices.InvalidSlice.selector);
        this.runProposal(bad);

        this.runProposal(_params());
        vm.prank(VENTURE);
        vm.expectRevert(SpotMigrator.AlreadyMigrated.selector);
        migrator.migrate(_params());
    }

    /// @notice A dust deposit to the venture front-running the proposal must not brick it.
    function test_Migrate_ToleratesDustDepositToVenture() public {
        address griefer = address(0x6E1F);
        _token0().transfer(griefer, 1 ether);
        _token1().transfer(griefer, 1 ether);
        uint256 shares = oldVault.shareBalance(VENTURE);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.startPrank(griefer);
        _token0().approve(address(oldVault), 1 ether);
        _token1().approve(address(oldVault), 1 ether);
        oldVault.deposit(1 ether, 1 ether, 0, VENTURE);
        vm.stopPrank();

        vm.startPrank(VENTURE);
        oldVault.withdraw(shares, 0, 0, address(migrator));
        migrator.migrate(_params());
        vm.stopPrank();

        (address newVault,,) = migrator.prepared(VENTURE);
        assertEq(hub.ventureLiquidityVault(VENTURE), newVault);
        assertGt(oldVault.shareBalance(VENTURE), 0);
    }

    /// @notice Shares the proposal does not withdraw stay the venture's in V1, redeemable later.
    function test_Migrate_LeavesUnwithdrawnSharesInV1() public {
        uint256 shares = oldVault.shareBalance(VENTURE);
        vm.startPrank(VENTURE);
        oldVault.withdraw(shares / 2, 0, 0, address(migrator));
        migrator.migrate(_params());
        (address newVault,,) = migrator.prepared(VENTURE);
        assertEq(hub.ventureLiquidityVault(VENTURE), newVault);

        uint256 left = oldVault.shareBalance(VENTURE);
        assertEq(left, shares - shares / 2);
        uint256 moneyBefore = _token1().balanceOf(VENTURE);
        oldVault.withdraw(left, 0, 0, VENTURE);
        vm.stopPrank();
        assertEq(oldVault.shareBalance(VENTURE), 0);
        assertGt(_token1().balanceOf(VENTURE), moneyBefore);
    }

    function test_Migrate_AnchorOnly() public {
        SpotMigrator.MigrateParams memory p;
        p.anchorBps = 10_000;
        this.runProposal(p);
        (, address alm,) = migrator.prepared(VENTURE);
        assertEq(ActiveLiquidityManager(alm).positions().length, 0);
        assertEq(_token0().balanceOf(alm), 0);
    }

    function test_Hub_MigrateOnlyMigratorAndOnlyWhenRedeemed() public {
        (address newVault,,) = migrator.prepared(VENTURE);
        vm.expectRevert(IUmiaHub.NotSpotMigrator.selector);
        hub.migrateSpotLiquidityVault(VENTURE, newVault);

        vm.prank(OWNER);
        hub.setSpotMigrator(address(this));
        vm.expectRevert(IUmiaHub.InvalidSpotLiquidityVault.selector);
        hub.migrateSpotLiquidityVault(VENTURE, newVault);
        vm.expectRevert(IUmiaHub.SpotLiquidityVaultNotRegistered.selector);
        hub.migrateSpotLiquidityVault(address(0x999), newVault);

        vm.mockCall(newVault, abi.encodeWithSignature("isPoolInitialized()"), abi.encode(true));
        vm.mockCall(newVault, abi.encodeWithSignature("venture()"), abi.encode(address(0xBEEF)));
        vm.expectRevert(IUmiaHub.InvalidSpotLiquidityVault.selector);
        hub.migrateSpotLiquidityVault(VENTURE, newVault);
        vm.mockCall(newVault, abi.encodeWithSignature("venture()"), abi.encode(VENTURE));

        vm.mockCall(newVault, abi.encodeWithSignature("HUB()"), abi.encode(address(0xBEEF)));
        vm.expectRevert(IUmiaHub.InvalidSpotLiquidityVault.selector);
        hub.migrateSpotLiquidityVault(VENTURE, newVault);
        vm.mockCall(newVault, abi.encodeWithSignature("HUB()"), abi.encode(address(hub)));

        // Still seeding a decision market: the pointer must not move.
        vm.mockCall(address(oldVault), abi.encodeWithSignature("totalDeployedMoney()"), abi.encode(uint256(1)));
        vm.expectRevert(IUmiaHub.SpotLiquidityVaultStillFunded.selector);
        hub.migrateSpotLiquidityVault(VENTURE, newVault);
    }

    function test_Hub_SettersOnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.setSpotMigrator(address(1));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.setActiveLiquidityKeeper(address(1));
        vm.prank(OWNER);
        hub.setActiveLiquidityKeeper(address(0x4EE9));
        assertEq(hub.activeLiquidityKeeper(), address(0x4EE9));
    }

    /// @notice A fake venture pointing at the real venture's V1 pool: the source hook says the pool
    ///         is someone else's.
    function test_Prepare_RejectsAFakeVentureClaimingARealPool() public {
        FakeVenture fake = new FakeVenture(address(this));
        hub.registerSpotLiquidityVault(address(fake), address(new FakeVault(oldKey, address(fake), address(hub))));
        vm.expectRevert(SpotMigrator.UnknownSourcePool.selector);
        migrator.prepare(address(fake));
    }

    /// @notice A fake venture cannot register a vault that names another venture or another Hub, so
    ///         the registration event can never point an indexer at the real venture's vault.
    function test_Hub_RejectsRegisteringSomeoneElsesVault() public {
        FakeVenture fake = new FakeVenture(address(this));
        FakeVault otherHub = new FakeVault(oldKey, address(fake), address(0xB0B));
        FakeVault own = new FakeVault(oldKey, address(fake), address(hub));
        vm.expectRevert(IUmiaHub.InvalidSpotLiquidityVault.selector);
        hub.registerSpotLiquidityVault(address(fake), address(oldVault));
        vm.expectRevert(IUmiaHub.InvalidSpotLiquidityVault.selector);
        hub.registerSpotLiquidityVault(address(fake), address(otherHub));
        vm.expectRevert(IUmiaHub.InvalidSpotLiquidityVault.selector);
        hub.registerSpotLiquidityVault(address(fake), address(0xE0A));
        hub.registerSpotLiquidityVault(address(fake), address(own));
        assertEq(hub.ventureLiquidityVault(address(fake)), address(own));
    }

    /// @notice A fake venture with its own pool on another hook, which could otherwise take the real
    ///         venture's V2 pool key first.
    function test_Prepare_RejectsAPoolOnAnotherHook() public {
        PoolKey memory squat = oldKey;
        squat.hooks = IHooks(address(0xBAD));
        FakeVenture fake = new FakeVenture(address(this));
        hub.registerSpotLiquidityVault(address(fake), address(new FakeVault(squat, address(fake), address(hub))));
        vm.expectRevert(SpotMigrator.UnknownSourcePool.selector);
        migrator.prepare(address(fake));
    }

    /// @notice The real venture's pool, but a vault other than the one the hook records as operator.
    function test_Prepare_RejectsAVaultThatDoesNotOperateThePool() public {
        address venture2 = address(0x5678);
        vm.mockCall(venture2, abi.encodeWithSignature("lbp()"), abi.encode(address(this)));
        v1.registerPool(
            PoolKey(currency0, currency1, 500, 10, IHooks(V1_ADDR)),
            IUmiaHook.PoolConfig({launcher: address(0), venture: venture2, operator: address(0xA4)})
        );
        hub.registerSpotLiquidityVault(
            venture2,
            address(new FakeVault(PoolKey(currency0, currency1, 500, 10, IHooks(V1_ADDR)), venture2, address(hub)))
        );
        vm.expectRevert(SpotMigrator.UnknownSourcePool.selector);
        migrator.prepare(venture2);
    }
}
