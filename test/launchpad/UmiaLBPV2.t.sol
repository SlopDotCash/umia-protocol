// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ContinuousClearingAuctionFactory} from "@continuous-clearing-auction/ContinuousClearingAuctionFactory.sol";
import {
    AuctionParameters,
    IContinuousClearingAuction
} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {AuctionStepsBuilder} from "@continuous-clearing-auction/../test/utils/AuctionStepsBuilder.sol";
import {PosmTestSetup} from "@uniswap/v4-periphery/test/shared/PosmTestSetup.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {UmiaLBPV2} from "../../src/launchpad/UmiaLBPV2.sol";
import {UmiaLBPFactoryV2} from "../../src/launchpad/UmiaLBPFactoryV2.sol";
import {SpotLiquidityV2Code} from "../../src/periphery/SpotLiquidityV2Code.sol";
import {SpotLiquidityVaultV2} from "../../src/core/SpotLiquidityVaultV2.sol";
import {ActiveLiquidityManager} from "../../src/core/ActiveLiquidityManager.sol";
import {IActiveLiquidityManager} from "../../src/interfaces/IActiveLiquidityManager.sol";
import {UmiaHookV2} from "../../src/periphery/UmiaHookV2.sol";
import {IUmiaHook} from "../../src/interfaces/IUmiaHook.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IUmiaLBP} from "../../src/interfaces/IUmiaLBP.sol";
import {ILBPMigrationCallback} from "../../src/interfaces/ILBPMigrationCallback.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice A fresh launch through `UmiaLBPV2` lands on `UmiaHookV2` with an anchor vault and an
///         empty ALM, no migration involved. The test contract stands in for the Hub and factory.
contract UmiaLBPV2Test is Test, PosmTestSetup {
    using AuctionStepsBuilder for bytes;
    using FixedPointMathLib for *;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SpotLiquidityV2Code code;
    UmiaLBPV2 lbp;
    UmiaHookV2 hookV2;
    ContinuousClearingAuctionFactory ccaFactory;
    MockERC20 token;
    MockERC20 currency;

    address constant VENTURE = address(0x1111);
    address constant KEEPER = address(0x4EE9);
    int24 constant LAUNCH_HALF_WIDTH = 10_980;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint128 constant TOTAL_SUPPLY = 1_000_000e18;
    uint256 constant VENTURE_BPS = 2000;
    uint160 constant HOOK_FLAGS = uint160(1 << 13 | 1 << 12 | 1 << 11 | 1 << 9 | 1 << 7);
    uint256 constant FLOOR_PRICE = 1000 << FixedPoint96.RESOLUTION;
    uint256 constant TICK_SPACING_CCA = 100 << FixedPoint96.RESOLUTION;
    uint24 constant FEE = 10_000;
    int24 constant SPACING = 60;

    address registeredVault;
    PoolKey poolKey;

    function setUp() public {
        vm.warp(1_790_000_000);
        deployFreshManagerAndRouters();
        deployPosm(manager);
        token = new MockERC20("Project Token", "PROJ", 18);
        currency = new MockERC20("Currency", "CURR", 18);
        ccaFactory = new ContinuousClearingAuctionFactory(address(0));
        code = new SpotLiquidityV2Code();

        hookV2 = UmiaHookV2(address(uint160(0x7777 << 20) | HOOK_FLAGS));
        deployCodeTo("UmiaHookV2.sol:UmiaHookV2", abi.encode(address(this)), address(hookV2));
        hookV2.initialize(address(this), IPoolManager(address(manager)), address(this));

        vm.mockCall(address(this), abi.encodeWithSelector(bytes4(keccak256("isLBP(address)"))), abi.encode(true));
        vm.mockCall(VENTURE, abi.encodeWithSelector(ILBPMigrationCallback.onLBPMigrated.selector), abi.encode());
        vm.mockCall(VENTURE, abi.encodeWithSelector(IVenture.HUB.selector), abi.encode(address(this)));
        vm.mockCall(
            address(this), abi.encodeWithSelector(IUmiaHub.ccaFactory.selector), abi.encode(address(ccaFactory))
        );
        vm.mockCall(
            address(this), abi.encodeWithSelector(IUmiaHub.migrationDelayBlocks.selector), abi.encode(uint64(100))
        );
        vm.mockCall(address(this), abi.encodeWithSelector(IUmiaHub.spotSwapFeeBps.selector), abi.encode(uint16(100)));
        vm.mockCall(
            address(this), abi.encodeWithSelector(IUmiaHub.defaultPoolTickSpacing.selector), abi.encode(SPACING)
        );
        vm.mockCall(address(this), abi.encodeWithSelector(IUmiaHub.activeLiquidityKeeper.selector), abi.encode(KEEPER));
        vm.mockCall(address(this), abi.encodeWithSelector(IUmiaHub.launchAnchorBps.selector), abi.encode(uint16(7_500)));
        vm.mockCall(
            address(this),
            abi.encodeWithSelector(IUmiaHub.launchActiveHalfWidthTicks.selector),
            abi.encode(int24(LAUNCH_HALF_WIDTH))
        );
        vm.mockCall(
            address(this), abi.encodeWithSelector(IUmiaHub.spotProtocolFeeCutBps.selector), abi.encode(uint16(0))
        );
        vm.mockCall(VENTURE, abi.encodeWithSignature("token()"), abi.encode(address(token)));
        vm.mockCall(VENTURE, abi.encodeWithSignature("moneyToken()"), abi.encode(address(currency)));

        _launch();
        lbp.migrate();
        _setPoolKey();
    }

    /// @dev Stand-in for `UmiaHub.registerSpotLiquidityVault`.
    function registerSpotLiquidityVault(address venture, address vault) external {
        assertEq(msg.sender, address(lbp));
        assertEq(venture, VENTURE);
        registeredVault = vault;
    }

    function _launch() internal {
        uint64 startBlock = uint64(block.number + 1);
        uint64 endBlock = startBlock + 100;
        bytes memory auctionParamsData = abi.encode(
            AuctionParameters({
                currency: address(currency),
                tokensRecipient: address(1),
                fundsRecipient: address(1),
                startBlock: startBlock,
                endBlock: endBlock,
                claimBlock: endBlock + 100,
                tickSpacing: TICK_SPACING_CCA,
                validationHook: address(0),
                floorPrice: FLOOR_PRICE,
                requiredCurrencyRaised: 0,
                auctionStepsData: AuctionStepsBuilder.init().addStep(100_000, 50).addStep(100_000, 50)
            })
        );

        lbp = new UmiaLBPV2(
            address(token),
            TOTAL_SUPPLY,
            5_000_000,
            address(currency),
            auctionParamsData,
            IPoolManager(address(manager)),
            IUmiaHook(address(hookV2)),
            VENTURE,
            VENTURE_BPS,
            code
        );
        vm.mockCall(VENTURE, abi.encodeWithSignature("lbp()"), abi.encode(address(lbp)));

        token.mint(address(this), TOTAL_SUPPLY);
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        IContinuousClearingAuction auction = IContinuousClearingAuction(address(lbp.initializer()));
        vm.roll(startBlock);
        uint256 targetPrice = FLOOR_PRICE + TICK_SPACING_CCA;
        uint128 bidAmount = uint128(uint256(250_000e18).fullMulDivUp(targetPrice, FixedPoint96.Q96));
        _submitBid(auction, alice, bidAmount, targetPrice, FLOOR_PRICE, 0);
        _submitBid(auction, bob, bidAmount, targetPrice, FLOOR_PRICE, 1);
        vm.roll(endBlock);
        auction.checkpoint();

        vm.roll(uint256(endBlock) + 100);
    }

    function _setPoolKey() internal {
        (address c0, address c1) = address(token) < address(currency)
            ? (address(token), address(currency))
            : (address(currency), address(token));
        poolKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), FEE, SPACING, IHooks(address(hookV2)));
    }

    function _submitBid(
        IContinuousClearingAuction auction,
        address bidder,
        uint128 amount,
        uint256 price,
        uint256 prevPrice,
        uint256 expectedId
    ) internal {
        currency.mint(bidder, amount);
        vm.startPrank(bidder);
        currency.approve(address(permit2), amount);
        permit2.approve(address(currency), address(auction), uint160(amount), uint48(block.timestamp + 1000));
        assertEq(auction.submitBid(price, amount, bidder, prevPrice, bytes("")), expectedId);
        vm.stopPrank();
    }

    function _swap(uint256 amount, bool zeroForOne) internal {
        address swapper = makeAddr("swapper");
        MockERC20 input = MockERC20(Currency.unwrap(zeroForOne ? poolKey.currency0 : poolKey.currency1));
        input.mint(swapper, amount);
        vm.startPrank(swapper);
        input.approve(address(swapRouter), amount);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_Migrate_LandsOnV2WithAnchorAndSeededAlm() public view {
        SpotLiquidityVaultV2 vault = SpotLiquidityVaultV2(registeredVault);
        address alm = vault.activeManager();
        (address launcher, address venture, address anchor, address active) = hookV2.pools(poolKey.toId());
        assertEq(launcher, address(lbp));
        assertEq(venture, VENTURE);
        assertEq(anchor, address(vault));
        assertEq(active, alm);
        assertTrue(alm != address(0));

        assertTrue(vault.isPoolInitialized());
        assertEq(vault.bootstrapper(), address(lbp));
        assertGt(vault.shareBalance(VENTURE), 0);
        assertEq(vault.totalShares(), vault.shareBalance(VENTURE));
        assertGt(vault.currentLiquidity(), 0);

        ActiveLiquidityManager manager_ = ActiveLiquidityManager(alm);
        assertEq(manager_.bootstrapper(), address(lbp));
        IActiveLiquidityManager.Position[] memory seeded = manager_.positions();
        assertEq(seeded.length, 1);
        (, int24 tick,,) = manager.getSlot0(poolKey.toId());
        int24 center = tick / SPACING * SPACING;
        if (tick < 0 && tick % SPACING != 0) center -= SPACING;
        assertEq(seeded[0].tickLower, center - LAUNCH_HALF_WIDTH);
        assertEq(seeded[0].tickUpper, center + LAUNCH_HALF_WIDTH);
        assertGt(seeded[0].liquidity, 0);
        assertEq(token.balanceOf(address(lbp)), 0);
        assertEq(currency.balanceOf(address(lbp)), 0);
        assertEq(manager_.constraints().maxTwapDeviationTicks, 100);
        assertEq(manager_.keeper(), KEEPER);
        (uint16 coarseIndex, uint16 coarseCardinality,) = hookV2.coarseOracleStates(poolKey.toId());
        assertEq(coarseIndex, 0);
        assertEq(coarseCardinality, 1);
    }

    /// @dev A second launch in one test needs its own pool, so its own token pair.
    function _freshTokens() internal {
        token = new MockERC20("Project Token 2", "PROJ2", 18);
        currency = new MockERC20("Currency 2", "CURR2", 18);
        vm.mockCall(VENTURE, abi.encodeWithSignature("token()"), abi.encode(address(token)));
        vm.mockCall(VENTURE, abi.encodeWithSignature("moneyToken()"), abi.encode(address(currency)));
    }

    function test_Migrate_RevertsWhileTheHubHasNoLaunchSplit() public {
        _freshTokens();
        _launch();
        vm.mockCall(address(this), abi.encodeWithSelector(IUmiaHub.launchAnchorBps.selector), abi.encode(uint16(0)));
        vm.expectRevert(IUmiaLBP.LaunchSplitUnset.selector);
        lbp.migrate();
    }

    /// @notice An all-anchor split leaves the ALM deployed and empty, as V1 launches did.
    function test_Migrate_AllAnchorLeavesAlmEmpty() public {
        _freshTokens();
        _launch();
        vm.mockCall(
            address(this), abi.encodeWithSelector(IUmiaHub.launchAnchorBps.selector), abi.encode(uint16(10_000))
        );
        lbp.migrate();
        ActiveLiquidityManager alm = ActiveLiquidityManager(SpotLiquidityVaultV2(registeredVault).activeManager());
        assertEq(alm.positions().length, 0);
        assertEq(token.balanceOf(address(alm)), 0);
        assertEq(currency.balanceOf(address(alm)), 0);
    }

    /// @notice After launch the venture adds to its ALM by transfer and the default keeper rebalances.
    function test_VentureFundsAlmAndKeeperRebalances() public {
        ActiveLiquidityManager alm = ActiveLiquidityManager(SpotLiquidityVaultV2(registeredVault).activeManager());
        for (uint256 i = 0; i < 156; i++) {
            vm.warp(vm.getBlockTimestamp() + 5 minutes);
            _swap(100e18, i % 2 == 0);
        }
        token.mint(address(alm), 10_000e18);
        currency.mint(address(alm), 10_000e18);

        (, int24 tick,,) = manager.getSlot0(poolKey.toId());
        int24 center = tick / SPACING * SPACING;
        IActiveLiquidityManager.Position[] memory target = new IActiveLiquidityManager.Position[](1);
        target[0] = IActiveLiquidityManager.Position(center - 600, center + 600, 1e20);
        vm.prank(KEEPER);
        alm.rebalance(target);
        assertEq(alm.positions().length, 1);
    }

    function test_Factory_CreatesV2LbpsFromSharedCode() public {
        UmiaLBPFactoryV2 factory =
            new UmiaLBPFactoryV2(IPoolManager(address(manager)), address(hookV2), address(this), code);
        assertEq(address(factory.spotLiquidityCode()), address(code));

        bytes memory configData =
            abi.encode(uint256(5_000_000), address(currency), lbp.auctionParams(), VENTURE, VENTURE_BPS);
        vm.prank(address(0xBAD));
        vm.expectRevert(UmiaLBPFactoryV2.Unauthorized.selector);
        factory.create(address(token), TOTAL_SUPPLY, configData, bytes32(0));

        address predicted =
            address(factory.getAddress(address(token), TOTAL_SUPPLY, configData, bytes32(uint256(7)), address(this)));
        address created = address(factory.create(address(token), TOTAL_SUPPLY, configData, bytes32(uint256(7))));
        assertEq(created, predicted);
        assertTrue(factory.isLBP(created));
        assertEq(address(UmiaLBPV2(created).spotLiquidityCode()), address(code));
        assertEq(address(UmiaLBPV2(created).umiaHook()), address(hookV2));
    }
}
