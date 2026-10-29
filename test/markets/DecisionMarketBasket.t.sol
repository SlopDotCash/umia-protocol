// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {ISpotLiquidityVaultV2} from "../../src/interfaces/ISpotLiquidityVaultV2.sol";
import {Venture} from "../../src/core/Venture.sol";

contract DecisionMarketBasketTest is DecisionMarketBase {
    address exempt = makeAddr("exemptTrader");
    uint256 constant LEG_FRACTION = 1e16;

    function _createMarketWithExemptTrader(address trader) internal returns (uint256) {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();
        if (trader != address(0)) {
            vm.mockCall(
                hub.ventureLiquidityVault(venture),
                abi.encodeWithSelector(ISpotLiquidityVaultV2.activeManager.selector),
                abi.encode(trader)
            );
        }
        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "a", executionPayload: ""});
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "b", executionPayload: ""});
        return _createMarket(ventureId, proposals);
    }

    function _fundAndSplit(address trader, uint256 ventureAmount) internal {
        _mintVenture(hub, venture, trader, ventureAmount);
        _setupTrader(trader);
        vm.prank(trader);
        mm.split(marketId, ventureAmount, 0);
    }

    function _legIn() internal view returns (uint256 maxIn) {
        uint256[] memory ids = mm.marketProposalIds(marketId);
        for (uint256 i = 0; i < ids.length; i++) {
            (uint256 reserve0,) = mm.cpmmStates(ids[i]);
            if (reserve0 / 20 > maxIn) maxIn = reserve0 / 20;
        }
    }

    function test_Snapshot_V1VaultHasNoExemptTrader() public {
        _createMarketWithExemptTrader(address(0));
        assertEq(mm.activeManager(marketId), address(0));
    }

    function test_Snapshot_RecordsVaultActiveManager() public {
        _createMarketWithExemptTrader(exempt);
        assertEq(mm.activeManager(marketId), exempt);
    }

    function test_Basket_SameReserveFractionInEveryProposalWithFee() public {
        _createMarketWithExemptTrader(exempt);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 maxIn = _legIn();
        _fundAndSplit(bob, maxIn);
        uint256[] memory ids = mm.marketProposalIds(marketId);
        uint256[] memory reserve1Before = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            (, reserve1Before[i]) = mm.cpmmStates(ids[i]);
        }

        vm.expectEmit(true, true, false, true, address(mm));
        emit IUmiaMarketCore.BasketSwap(marketId, bob, true, LEG_FRACTION, false);
        vm.prank(bob);
        (uint256[] memory amountsIn, uint256[] memory amountsOut) =
            mm.basketSwapExactOut(marketId, true, LEG_FRACTION, maxIn, block.timestamp);

        assertEq(amountsIn.length, ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(amountsOut[i], reserve1Before[i] * LEG_FRACTION / 1e18);
            assertEq(mm.balanceOf(bob, mm.getVirtualMoneyId(ids[i])), amountsOut[i]);
            assertEq(mm.balanceOf(bob, mm.getVirtualVentureId(ids[i])), maxIn - amountsIn[i]);
            assertGt(_accruedFeeVenture(ids[i]), 0);
        }
        _verifyInvariant(marketId);
    }

    function test_Basket_ExemptTraderPaysNoFee() public {
        _createMarketWithExemptTrader(exempt);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 maxIn = _legIn();
        _fundAndSplit(exempt, maxIn);
        _fundAndSplit(bob, maxIn);
        uint256[] memory ids = mm.marketProposalIds(marketId);

        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        (uint256[] memory paidIn,) = mm.basketSwapExactOut(marketId, true, LEG_FRACTION, maxIn, block.timestamp);
        vm.revertToState(snap);

        vm.prank(exempt);
        (uint256[] memory exemptIn, uint256[] memory exemptOut) =
            mm.basketSwapExactOut(marketId, true, LEG_FRACTION, maxIn, block.timestamp);
        for (uint256 i = 0; i < ids.length; i++) {
            assertLt(exemptIn[i], paidIn[i]);
            assertEq(_accruedFeeVenture(ids[i]), 0);
            assertEq(mm.balanceOf(exempt, mm.getVirtualMoneyId(ids[i])), exemptOut[i]);
        }
        _verifyInvariant(marketId);
    }

    function test_Basket_ExemptTraderOrdinarySwapPaysFee() public {
        _createMarketWithExemptTrader(exempt);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 maxIn = _legIn();
        _fundAndSplit(exempt, maxIn);
        uint256 proposalId = mm.marketProposalIds(marketId)[1];
        (, uint256 reserve1) = mm.cpmmStates(proposalId);

        vm.prank(exempt);
        mm.swapExactOut(proposalId, reserve1 / 100, maxIn, 10_000, true, block.timestamp);
        assertGt(_accruedFeeVenture(proposalId), 0);
    }

    function test_Basket_RevertsOutsideTradingWindow() public {
        _createMarketWithExemptTrader(exempt);
        uint256 maxIn = _legIn();
        _fundAndSplit(exempt, maxIn);

        vm.prank(exempt);
        vm.expectRevert(IUmiaMarketCore.MarketNotOpen.selector);
        mm.basketSwapExactOut(marketId, true, LEG_FRACTION, maxIn, block.timestamp);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(exempt);
        vm.expectRevert(IUmiaMarketCore.DeadlineExpired.selector);
        mm.basketSwapExactOut(marketId, true, LEG_FRACTION, maxIn, block.timestamp - 1);
    }

    function test_Basket_RevertsPastLegInputCap() public {
        _createMarketWithExemptTrader(exempt);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 maxIn = _legIn();
        _fundAndSplit(bob, maxIn);

        vm.prank(bob);
        vm.expectRevert();
        mm.basketSwapExactOut(marketId, true, LEG_FRACTION, 1, block.timestamp);
    }

    function test_Basket_RevertsOnFractionOutOfRange() public {
        _createMarketWithExemptTrader(exempt);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 maxIn = _legIn();
        _fundAndSplit(bob, maxIn);

        vm.startPrank(bob);
        vm.expectRevert(IUmiaMarketCore.InvalidAmount.selector);
        mm.basketSwapExactOut(marketId, true, 0, maxIn, block.timestamp);
        vm.expectRevert(IUmiaMarketCore.InvalidAmount.selector);
        mm.basketSwapExactOut(marketId, true, 1e18, maxIn, block.timestamp);
        vm.stopPrank();
    }

    function test_Basket_RevertsWhenALaterLegRoundsToZero() public {
        _createMarketWithExemptTrader(exempt);
        vm.warp(block.timestamp + 1 days + 1);
        uint256[] memory ids = mm.marketProposalIds(marketId);
        (uint256 reserve0, uint256 reserve1) = mm.cpmmStates(ids[0]);
        _fundAndSplit(bob, reserve0);

        // Drain some money from the second leg, leaving the no-op's reserves unchanged.
        vm.prank(bob);
        mm.swapExactIn(ids[1], reserve0 / 2, 0, 10_000, true, block.timestamp);
        uint256 fraction = (1e18 + reserve1 - 1) / reserve1;
        (, uint256 smallerReserve1) = mm.cpmmStates(ids[1]);
        assertEq(reserve1 * fraction / 1e18, 1, "first leg has a nonzero output");
        assertEq(smallerReserve1 * fraction / 1e18, 0, "second leg rounds to zero");

        vm.prank(bob);
        vm.expectRevert(IUmiaMarketCore.InvalidAmount.selector);
        mm.basketSwapExactOut(marketId, true, fraction, reserve0, block.timestamp);

        // The failed later leg must also roll back the first leg's swap and fee accrual.
        (uint256 after0, uint256 after1) = mm.cpmmStates(ids[0]);
        assertEq(after0, reserve0);
        assertEq(after1, reserve1);
        assertEq(mm.balanceOf(bob, mm.getVirtualVentureId(ids[0])), reserve0);
        assertEq(mm.balanceOf(bob, mm.getVirtualMoneyId(ids[0])), 0);
        assertEq(_accruedFeeVenture(ids[0]), 0);
        _verifyInvariant(marketId);
    }

    /// @dev Bob buys venture in `proposalId` until its price sits just under `targetWad` over the no-op's.
    function _skewTo(uint256 proposalId, uint256 targetWad) internal {
        uint256 noOp = mm.marketProposalIds(marketId)[0];
        (, uint256 seed1) = mm.cpmmStates(noOp);
        _setupTrader(bob);
        vm.prank(bob);
        mm.split(marketId, 0, seed1 / 10);
        uint256 lo;
        uint256 hi = seed1 / 20;
        for (uint256 i = 0; i < 80; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(bob);
            mm.swapExactIn(proposalId, mid, 0, 10_000, false, block.timestamp);
            uint256 ratio = _priceRatio(proposalId, noOp);
            vm.revertToState(snap);
            if (ratio <= targetWad) lo = mid;
            else hi = mid;
        }
        vm.prank(bob);
        mm.swapExactIn(proposalId, lo, 0, 10_000, false, block.timestamp);
    }

    function _fundBoth(address trader) internal {
        uint256 noOp = mm.marketProposalIds(marketId)[0];
        (uint256 seed0, uint256 seed1) = mm.cpmmStates(noOp);
        _mintVenture(hub, venture, trader, seed0 / 2);
        usdc.mint(trader, seed1 / 2);
        _setupTrader(trader);
        vm.prank(trader);
        mm.split(marketId, seed0 / 2, seed1 / 2);
    }

    /// @notice Buy and sell baskets, exempt or fee-paying, leave every proposal's price ratio to
    ///         every other unchanged, so they can never move a lead.
    function testFuzz_Basket_KeepsEveryPriceRatio(uint256 seed) public {
        _createMarketWithExemptTrader(exempt);
        (,, uint256 tradingStart,) = mm.marketInfo(marketId);
        vm.warp(tradingStart + 1);
        uint256[] memory ids = mm.marketProposalIds(marketId);
        _skewTo(ids[1], 1e18 + (seed % 500) * 1e14);
        _fundBoth(exempt);
        _fundBoth(charlie);

        for (uint256 r = 0; r < 6; r++) {
            seed = uint256(keccak256(abi.encode(seed, r)));
            address trader = (seed & 1) == 0 ? exempt : charlie;
            bool zeroForOne = ((seed >> 1) & 1) == 0;
            uint256 fraction = ((seed >> 8) % 300 + 1) * 1e14;
            uint256 ratio1 = _priceRatio(ids[1], ids[0]);
            uint256 ratio2 = _priceRatio(ids[2], ids[0]);
            vm.prank(trader);
            mm.basketSwapExactOut(marketId, zeroForOne, fraction, type(uint256).max, block.timestamp);
            assertApproxEqRel(_priceRatio(ids[1], ids[0]), ratio1, 1e12);
            assertApproxEqRel(_priceRatio(ids[2], ids[0]), ratio2, 1e12);
        }
        _verifyInvariant(marketId);
    }

    /// @notice A lead just under the threshold stays under it through fee-free round trips, so the
    ///         no-op still wins. Equal-output baskets used to widen it past the threshold.
    function test_Basket_RoundTripsLeaveTheOutcome() public {
        _createMarketWithExemptTrader(exempt);
        (,, uint256 tradingStart, uint256 tradingEnd) = mm.marketInfo(marketId);
        vm.warp(tradingStart + 1);
        uint256[] memory ids = mm.marketProposalIds(marketId);
        _skewTo(ids[1], 1.0196e18);
        _fundBoth(exempt);
        uint256 leadBefore = _priceRatio(ids[1], ids[0]);

        for (uint256 r = 0; r < 4; r++) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vm.prank(exempt);
            mm.basketSwapExactOut(marketId, false, 5e16, type(uint256).max, block.timestamp);
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vm.prank(exempt);
            mm.basketSwapExactOut(marketId, true, 4e16, type(uint256).max, block.timestamp);
        }
        assertApproxEqRel(_priceRatio(ids[1], ids[0]), leadBefore, 1e12);

        vm.warp(tradingEnd + 1);
        mm.settleMarket(marketId);
        assertEq(mm.winningProposalByMarketId(marketId).proposalId, ids[0]);
    }

    /// @notice Random split / merge / swap / addLiquidity / basket sequences, with an exempt and a
    ///         non-exempt trader: the per-proposal solvency invariant and real-token backing hold
    ///         after every step, exempt baskets never accrue a protocol fee, and settlement can pay
    ///         every winning claim.
    function testFuzz_SolvencyWithBaskets(uint256 seed) public {
        _createMarketWithExemptTrader(charlie);
        _setupTrader(bob);
        _setupTrader(charlie);
        _mintVenture(hub, venture, bob, 1_000_000e18);
        _mintVenture(hub, venture, charlie, 1_000_000e18);
        vm.warp(block.timestamp + 1 days + 1);
        uint256[] memory ids = mm.marketProposalIds(marketId);

        for (uint256 i = 0; i < 40; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address actor = ((seed >> 1) & 1) == 0 ? bob : charlie;
            uint256 op = seed % 5;
            uint256 propId = ids[(seed >> 8) % ids.length];
            uint256 amt = ((seed >> 16) % 5_000e6) + 1;
            bool zeroForOne = ((seed >> 24) & 1) == 0;

            if (op == 0) {
                vm.prank(actor);
                try mm.split(marketId, amt * 1e12, amt) {} catch {}
            } else if (op == 1) {
                uint256 inId = zeroForOne ? mm.getVirtualVentureId(propId) : mm.getVirtualMoneyId(propId);
                uint256 bal = mm.balanceOf(actor, inId);
                if (bal > 0) {
                    vm.prank(actor);
                    try mm.swapExactIn(propId, ((seed >> 32) % bal) + 1, 0, 10_000, zeroForOne, block.timestamp) {}
                        catch {}
                }
            } else if (op == 2) {
                (uint256 minV, uint256 minM) = _minBalances(actor, ids);
                uint256 v = minV == 0 ? 0 : (seed >> 40) % (minV + 1);
                uint256 m = minM == 0 ? 0 : (seed >> 48) % (minM + 1);
                if (v > 0 || m > 0) {
                    vm.prank(actor);
                    try mm.merge(marketId, v, m) {} catch {}
                }
            } else if (op == 3) {
                uint256 vBal = mm.balanceOf(actor, mm.getVirtualVentureId(propId));
                uint256 mBal = mm.balanceOf(actor, mm.getVirtualMoneyId(propId));
                if (vBal > 0 && mBal > 0) {
                    uint256 price = mm.getPriceX96(propId, true);
                    vm.prank(actor);
                    try mm.addLiquidity(propId, ((seed >> 56) % vBal) + 1, ((seed >> 96) % mBal) + 1, price, 10_000) {}
                        catch {}
                }
            } else {
                (uint256 minV, uint256 minM) = _minBalances(actor, ids);
                uint256 maxIn = zeroForOne ? minV : minM;
                uint256 fraction = ((seed >> 32) % 100 + 1) * 1e14;
                uint256[] memory feeBefore = _protocolFees(ids);
                if (maxIn > 0) {
                    vm.prank(actor);
                    try mm.basketSwapExactOut(marketId, zeroForOne, fraction, maxIn, block.timestamp) {
                        if (actor == charlie) {
                            uint256[] memory feeAfter = _protocolFees(ids);
                            for (uint256 j = 0; j < ids.length; j++) {
                                assertEq(feeAfter[j], feeBefore[j], "exempt basket accrued a fee");
                            }
                        }
                    } catch {}
                }
            }
            _verifyInvariant(marketId);
            _verifyGroundTruthSolvency(marketId);
        }

        (,,, uint256 tradingEnd) = mm.marketInfo(marketId);
        vm.warp(tradingEnd + 1);
        mm.settleMarket(marketId);
        uint256 winner = mm.winningProposalByMarketId(marketId).proposalId;
        assertGe(IERC20(ventureToken).balanceOf(address(mm)), mm.userVirtualVentureSupply(winner));
        assertGe(usdc.balanceOf(address(mm)), mm.userVirtualMoneySupply(winner));
        vm.prank(bob);
        try mm.claimSettlement(marketId) {} catch {}
        vm.prank(charlie);
        try mm.claimSettlement(marketId) {} catch {}
    }

    function _minBalances(address who, uint256[] memory ids) internal view returns (uint256 minV, uint256 minM) {
        minV = type(uint256).max;
        minM = type(uint256).max;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 v = mm.balanceOf(who, mm.getVirtualVentureId(ids[i]));
            uint256 m = mm.balanceOf(who, mm.getVirtualMoneyId(ids[i]));
            if (v < minV) minV = v;
            if (m < minM) minM = m;
        }
    }

    function _protocolFees(uint256[] memory ids) internal view returns (uint256[] memory fees) {
        fees = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            fees[i] = _accruedFeeVenture(ids[i]) + _accruedFeeMoney(ids[i]);
        }
    }
}
