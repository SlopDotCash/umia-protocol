// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {ISpotLiquidityVaultV2} from "../../src/interfaces/ISpotLiquidityVaultV2.sol";
import {IUmiaHookV2} from "../../src/interfaces/IUmiaHookV2.sol";
import {UmiaHookV2} from "../../src/periphery/UmiaHookV2.sol";
import {SpotLiquidityVaultV2} from "../../src/core/SpotLiquidityVaultV2.sol";
import {ActiveLiquidityManager} from "../../src/core/ActiveLiquidityManager.sol";
import {IActiveLiquidityManager} from "../../src/interfaces/IActiveLiquidityManager.sol";
import {Venture} from "../../src/core/Venture.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";
import {SimpleLiquidator} from "../../src/liquidation/SimpleLiquidator.sol";

/// @notice The ALM's basket arbitrage against the real MarketCore. The ALM's V2
///         spot pool sits beside the venture's V1 pool, so its price can be set apart from the
///         decision markets'.
contract ActiveLiquidityBasketTest is DecisionMarketBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant HOOK_V2 = address(uint160(0x7777 << 20) | 0x3A80);
    address hookOwner = makeAddr("hookOwner");
    address fakeFactory = makeAddr("fakeFactory");
    address keeperAddr = makeAddr("keeper");

    ActiveLiquidityManager alm;
    SpotLiquidityVaultV2 anchor;
    PoolKey spotKey;
    bool ventureIsToken0;
    uint256[] proposalIds;

    function setUp() public override {
        super.setUp();
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();

        deployCodeTo("UmiaHookV2.sol:UmiaHookV2", abi.encode(hookOwner), HOOK_V2);
        vm.prank(hookOwner);
        UmiaHookV2(HOOK_V2).initialize(fakeFactory, IPoolManager(address(manager)), address(hub));

        alm = new ActiveLiquidityManager(address(hub), venture, address(manager), HOOK_V2, 10_000, 60, address(this));
        anchor = new SpotLiquidityVaultV2(address(hub), venture, address(manager), HOOK_V2, 10_000, 60, address(this));
        vm.startPrank(venture);
        alm.setConstraints(_constraints());
        alm.setKeeper(keeperAddr);
        vm.stopPrank();

        vm.mockCall(
            hub.ventureLiquidityVault(venture),
            abi.encodeWithSelector(ISpotLiquidityVaultV2.activeManager.selector),
            abi.encode(address(alm))
        );
        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "a", executionPayload: _liquidationPlan()});
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "b", executionPayload: ""});
        _createMarket(ventureId, proposals);
        proposalIds = mm.marketProposalIds(marketId);
        vm.warp(block.timestamp + 1 days + 1);
    }

    /// @dev Proposal "a" (`proposalIds[1]`) liquidates the treasury, so a test that makes it win can execute it.
    function _liquidationPlan() internal returns (bytes memory) {
        GovernanceTypes.LiquidationAsset[] memory assets = new GovernanceTypes.LiquidationAsset[](1);
        assets[0] = GovernanceTypes.LiquidationAsset({
            assetType: GovernanceTypes.AssetType.ERC20, token: address(usdc), tokenId: 0
        });
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.LIQUIDATE_TREASURY,
            actionVersion: 1,
            data: abi.encode(
                GovernanceTypes.LiquidationPlan({
                    liquidator: address(new SimpleLiquidator(address(hub))), assets: assets
                })
            )
        });
        return abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));
    }

    function _constraints() internal pure returns (IActiveLiquidityManager.Constraints memory) {
        return IActiveLiquidityManager.Constraints({
            maxPositions: 3,
            minWidthTicks: 120,
            maxWidthTicks: 24_000,
            minRebalanceInterval: 1 hours,
            maxTwapDeviationTicks: 100
        });
    }

    /// @dev Opens the ALM's spot pool with the venture token priced `spotBps` of the V1 pool price
    ///      the decision markets were seeded at, and funds the anchor and the ALM.
    function _openSpot(uint256 spotBps) internal {
        PoolKey memory v1Key = ISpotLiquidityVault(hub.ventureLiquidityVault(venture)).getPoolKey();
        (uint160 v1Sqrt,,,) = manager.getSlot0(v1Key.toId());
        ventureIsToken0 = Currency.unwrap(v1Key.currency0) == ventureToken;
        uint256 scale = FullMath.mulDiv(FixedPoint96.Q96, _sqrt(spotBps * 1e14), 1e9);
        uint160 sqrtPrice = ventureIsToken0
            ? uint160(FullMath.mulDiv(v1Sqrt, scale, FixedPoint96.Q96))
            : uint160(FullMath.mulDiv(v1Sqrt, FixedPoint96.Q96, scale));

        spotKey = PoolKey(v1Key.currency0, v1Key.currency1, 10_000, 60, IHooks(HOOK_V2));
        vm.mockCall(fakeFactory, abi.encodeWithSignature("isLBP(address)", address(this)), abi.encode(true));
        UmiaHookV2(HOOK_V2)
            .registerPool(
                spotKey,
                IUmiaHookV2.PoolConfig({
                launcher: address(0), venture: venture, anchorOperator: address(anchor), activeOperator: address(alm)
            })
            );
        manager.initialize(spotKey, sqrtPrice);

        uint256 ventureAmount = 1_000_000e18;
        uint256 moneyAmount = 2 * _moneyFor(ventureAmount, sqrtPrice);
        _mintVenture(hub, venture, address(this), ventureAmount);
        usdc.mint(address(this), moneyAmount);
        IERC20(ventureToken).approve(address(anchor), ventureAmount);
        usdc.approve(address(anchor), moneyAmount);
        anchor.bootstrapFromLBP(ventureAmount, moneyAmount, venture);

        _mintVenture(hub, venture, address(alm), ventureAmount);
        usdc.mint(address(alm), moneyAmount);
    }

    function _moneyFor(uint256 ventureAmount, uint160 sqrtPrice) internal view returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(sqrtPrice, sqrtPrice, FixedPoint96.Q96);
        return ventureIsToken0
            ? FullMath.mulDiv(ventureAmount, priceX96, FixedPoint96.Q96)
            : FullMath.mulDiv(ventureAmount, FixedPoint96.Q96, priceX96);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            (y, z) = (z, (x / z + z) / 2);
        }
    }

    /// @dev Largest output reserve fraction every proposal pays for `amountIn` at the normal fee, so
    ///      the fee-free basket fits inside `amountIn` on every leg.
    function _legFraction(uint256 amountIn, bool zeroForOne) internal view returns (uint256 fraction) {
        fraction = type(uint256).max;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            (uint256 quoted,) = mm.quoteSwapExactIn(proposalIds[i], amountIn, zeroForOne);
            (uint256 reserve0, uint256 reserve1) = mm.cpmmStates(proposalIds[i]);
            uint256 f = FullMath.mulDiv(quoted, 1e18, zeroForOne ? reserve1 : reserve0);
            if (f < fraction) fraction = f;
        }
    }

    function _minReserve0() internal view returns (uint256 r) {
        r = type(uint256).max;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            (uint256 reserve0,) = mm.cpmmStates(proposalIds[i]);
            if (reserve0 < r) r = reserve0;
        }
    }

    function _minReserve1() internal view returns (uint256 r) {
        r = type(uint256).max;
        for (uint256 i = 0; i < proposalIds.length; i++) {
            (, uint256 reserve1) = mm.cpmmStates(proposalIds[i]);
            if (reserve1 < r) r = reserve1;
        }
    }

    function test_BasketArb_SellDirectionProfitsAndConverges() public {
        _openSpot(9000);
        uint256 size = _minReserve0() / 200;
        uint256 fraction = _legFraction(size, true);
        (uint160 spotBefore,,,) = manager.getSlot0(spotKey.toId());
        uint256 noOpPriceBefore = mm.getPriceX96(proposalIds[0], true);

        vm.prank(keeperAddr);
        (uint256 moneyProfit,) = alm.basketArb(marketId, true, size, fraction, 0, 1);

        assertGt(moneyProfit, 0);
        (uint160 spotAfter,,,) = manager.getSlot0(spotKey.toId());
        assertTrue(ventureIsToken0 ? spotAfter > spotBefore : spotAfter < spotBefore, "spot venture price rises");
        assertLt(mm.getPriceX96(proposalIds[0], true), noOpPriceBefore, "decision-market price falls");
        for (uint256 i = 0; i < proposalIds.length; i++) {
            assertEq(_accruedFeeVenture(proposalIds[i]), 0);
        }
        _verifyInvariant(marketId);
    }

    function test_BasketArb_BuyDirectionProfits() public {
        _openSpot(11_000);
        uint256 size = _minReserve1() / 200;
        uint256 fraction = _legFraction(size, false);

        vm.prank(keeperAddr);
        (uint256 moneyProfit, uint256 ventureGain) = alm.basketArb(marketId, false, size, fraction, 0, 1);

        assertGt(moneyProfit, 0);
        assertEq(ventureGain, 0);
        _verifyInvariant(marketId);
    }

    function test_BasketArb_RevertsWithoutAGap() public {
        _openSpot(10_000);
        uint256 size = _minReserve0() / 200;
        uint256 fraction = _legFraction(size, true);
        vm.prank(keeperAddr);
        vm.expectRevert(IActiveLiquidityManager.BasketUnprofitable.selector);
        alm.basketArb(marketId, true, size, fraction, 0, 0);
    }

    function test_BasketArb_RevertsBelowMinProfit() public {
        _openSpot(9000);
        uint256 size = _minReserve0() / 200;
        uint256 fraction = _legFraction(size, true);
        vm.prank(keeperAddr);
        vm.expectRevert(IActiveLiquidityManager.BasketUnprofitable.selector);
        alm.basketArb(marketId, true, size, fraction, 0, type(uint128).max);
    }

    function test_BasketArb_PriceLimitStopsTheSpotLeg() public {
        _openSpot(9000);
        uint256 size = _minReserve0() / 200;
        uint256 fraction = _legFraction(size, true);
        (uint160 spot,,,) = manager.getSlot0(spotKey.toId());
        uint160 limit = ventureIsToken0 ? spot + 1 : spot - 1;
        vm.prank(keeperAddr);
        vm.expectRevert(IActiveLiquidityManager.BasketUnprofitable.selector);
        alm.basketArb(marketId, true, size, fraction, limit, 0);
    }

    function test_BasketArb_Gating() public {
        _openSpot(9000);
        uint256 size = _minReserve0() / 200;
        uint256 fraction = _legFraction(size, true);

        vm.prank(bob);
        vm.expectRevert(IActiveLiquidityManager.CallerNotKeeper.selector);
        alm.basketArb(marketId, true, size, fraction, 0, 0);

        vm.mockCall(address(mm), abi.encodeCall(IUmiaMarketCore.activeManager, (marketId)), abi.encode(address(0xBEEF)));
        vm.prank(keeperAddr);
        vm.expectRevert(IActiveLiquidityManager.ForeignMarket.selector);
        alm.basketArb(marketId, true, size, fraction, 0, 0);
        vm.clearMockedCalls();

        vm.prank(venture);
        alm.setPaused(true);
        vm.prank(keeperAddr);
        vm.expectRevert(IActiveLiquidityManager.Paused.selector);
        alm.basketArb(marketId, true, size, fraction, 0, 0);
    }

    /// @dev Pools priced apart leave unmergeable basket remainders; the winner's redeem back into the ALM.
    function test_ClaimDecisionMarket_RedeemsBasketLeftovers() public {
        _openSpot(9000);
        (, uint256 reserve1) = mm.cpmmStates(proposalIds[1]);
        _setupTrader(bob);
        vm.prank(bob);
        mm.split(marketId, 0, reserve1 / 20);
        _swapExactIn(bob, proposalIds[1], reserve1 / 20, false);
        uint256 size = _minReserve0() / 200;
        uint256 fraction = _legFraction(size, true);
        uint256 leadBefore = _priceRatio(proposalIds[1], proposalIds[0]);
        vm.prank(keeperAddr);
        alm.basketArb(marketId, true, size, fraction, 0, 0);
        assertApproxEqRel(_priceRatio(proposalIds[1], proposalIds[0]), leadBefore, 1e12, "the basket keeps the lead");

        (,,, uint256 tradingEnd) = mm.marketInfo(marketId);
        vm.warp(tradingEnd + 1);
        mm.settleMarket(marketId);
        uint256 winner = mm.winningProposalByMarketId(marketId).proposalId;
        assertEq(winner, proposalIds[1], "the pumped proposal wins");
        uint256 leftover = mm.balanceOf(address(alm), mm.getVirtualVentureId(winner));
        assertGt(leftover, 0, "the basket left a remainder in the winner");

        uint256 ventureBefore = IERC20(ventureToken).balanceOf(address(alm));
        alm.claimDecisionMarket(marketId);
        assertEq(IERC20(ventureToken).balanceOf(address(alm)) - ventureBefore, leftover);
    }

    /// @notice The cron's flow for a liquidation that won its own market: claim the ALM's basket
    ///         leftovers after settling, then execute; the liquidation sweeps them into the treasury.
    function test_ExecuteLiquidation_SweepsClaimedLeftoversInTheMarket() public {
        _openSpot(9000);
        (, uint256 reserve1) = mm.cpmmStates(proposalIds[1]);
        _setupTrader(bob);
        vm.prank(bob);
        mm.split(marketId, 0, reserve1 / 20);
        _swapExactIn(bob, proposalIds[1], reserve1 / 20, false);
        uint256 size = _minReserve0() / 200;
        uint256 fraction = _legFraction(size, true);
        vm.prank(keeperAddr);
        alm.basketArb(marketId, true, size, fraction, 0, 0);

        (,,, uint256 tradingEnd) = mm.marketInfo(marketId);
        vm.warp(tradingEnd + 1);
        mm.settleMarket(marketId);
        assertEq(mm.winningProposalByMarketId(marketId).proposalId, proposalIds[1]);
        uint256 leftover = mm.balanceOf(address(alm), mm.getVirtualVentureId(proposalIds[1]));
        assertGt(leftover, 0, "basket left a remainder");

        alm.claimDecisionMarket(marketId);
        vm.warp(block.timestamp + 30 days);
        _warmSpotOracle(venture);
        uint256 almVenture = IERC20(ventureToken).balanceOf(address(alm));
        uint256 treasuryBefore = IERC20(ventureToken).balanceOf(venture);
        uint256 supplyBefore = IERC20(ventureToken).totalSupply();
        mm.executeWinningProposal(marketId);

        assertTrue(Venture(payable(venture)).liquidationActive(), "liquidation active");
        assertEq(mm.balanceOf(address(alm), mm.getVirtualVentureId(proposalIds[1])), 0, "leftovers redeemed");
        assertEq(IERC20(ventureToken).balanceOf(address(alm)), 0, "manager emptied");
        assertEq(IERC20(ventureToken).balanceOf(venture), 0, "treasury venture tokens burned");
        assertGe(supplyBefore - IERC20(ventureToken).totalSupply(), treasuryBefore + almVenture, "swept tokens burned");
    }
}
