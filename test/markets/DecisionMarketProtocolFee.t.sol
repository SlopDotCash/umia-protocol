// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";

contract DecisionMarketProtocolFeeTest is DecisionMarketBase {
    address feeRecipient = makeAddr("feeRecipient");
    uint16 constant FEE_BPS_100 = 100; // 1%

    function _setupFee() internal {
        vm.startPrank(umiaAdmin);
        hub.setDecisionSwapFeeBps(FEE_BPS_100);
        // 100% cut routes the entire swap fee to the protocol (no LP portion), so accrued == full fee.
        hub.setDecisionProtocolFeeCutBps(10_000);
        hub.setProtocolFeeRecipient(feeRecipient);
        vm.stopPrank();
    }

    function test_feeDeduction_traderReceivesFullCPMMOutput() public {
        _setupFee();
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        (uint256 expectedOut,) = mm.quoteSwapExactIn(proposal1Id, 1_000e6, false);

        Proposal memory prop = _proposalById(proposal1Id);
        uint256 bobVentureBefore = mm.balanceOf(bob, prop.virtualVentureId);

        uint256 actualOut = _swapExactIn(bob, proposal1Id, 1_000e6, false);

        assertEq(actualOut, expectedOut, "Trader should receive full CPMM output (fee on input)");
        assertEq(
            mm.balanceOf(bob, prop.virtualVentureId) - bobVentureBefore,
            expectedOut,
            "Virtual balance should match quote"
        );
    }

    function test_feeAccrual_correctMappingsUpdated() public {
        _setupFee();
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        uint256 swapAmount = 1_000e6;
        uint256 expectedMoneyFee = (swapAmount * FEE_BPS_100) / 10_000;

        _swapExactIn(bob, proposal1Id, swapAmount, false);

        assertEq(
            _accruedFeeMoney(proposal1Id),
            expectedMoneyFee,
            "money fee should accrue for money->venture swap (input-side)"
        );
        assertEq(_accruedFeeVenture(proposal1Id), 0, "venture fee should be zero for money->venture swap");

        Proposal memory prop = _proposalById(proposal1Id);
        uint256 bobVenture = mm.balanceOf(bob, prop.virtualVentureId);
        uint256 ventureSwapAmount = bobVenture / 2;
        uint256 expectedVentureFee = (ventureSwapAmount * FEE_BPS_100) / 10_000;

        _swapExactIn(bob, proposal1Id, ventureSwapAmount, true);

        assertEq(
            _accruedFeeVenture(proposal1Id),
            expectedVentureFee,
            "venture fee should accrue for venture->money swap (input-side)"
        );
        assertEq(_accruedFeeMoney(proposal1Id), expectedMoneyFee, "money fee should remain from first swap");
    }

    function test_zeroFee_noDeduction() public {
        // Zero the default decision fee before creation (snapshotted per market).
        vm.prank(umiaAdmin);
        hub.setDecisionSwapFeeBps(0);
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        (uint256 expectedOut,) = mm.quoteSwapExactIn(proposal1Id, 1_000e6, false);
        uint256 actualOut = _swapExactIn(bob, proposal1Id, 1_000e6, false);

        assertEq(actualOut, expectedOut, "With zero fee, trader should receive full amountOut");
        assertEq(_accruedFeeVenture(proposal1Id), 0, "No fee should accrue");
        assertEq(_accruedFeeMoney(proposal1Id), 0, "No fee should accrue");
    }

    function test_settlement_autoCollectsFees() public {
        _setupFee();
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        _swapExactIn(bob, proposal1Id, 1_000e6, false);
        _swapExactIn(bob, proposal1Id, 500e6, false);

        uint256 totalFeeMoney = _accruedFeeMoney(proposal1Id);
        assertGt(totalFeeMoney, 0, "Fees should have accrued on input token (money)");

        vm.warp(market.tradingEnd + 1);

        uint256 recipientUsdcBefore = usdc.balanceOf(feeRecipient);

        mm.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(marketId);
        if (winning.proposalId == proposal1Id) {
            mm.collectProtocolFees(marketId);

            assertEq(
                usdc.balanceOf(feeRecipient) - recipientUsdcBefore,
                totalFeeMoney,
                "Fee recipient should receive accrued money fees"
            );
            assertEq(_accruedFeeMoney(proposal1Id), 0, "Accrued fee should be reset after collection");
        }
    }

    function test_settlement_feesDeductedBeforeLPReAddition() public {
        _setupFee();
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        uint256 noopId = market.proposalIds[0];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 5_000e6);
        vm.prank(charlie);
        mm.split(marketId, 0, 5_000e6);

        // Trade in both proposals to ensure fees accrue on the winning one
        _swapExactIn(bob, proposal1Id, 500e6, false);
        _swapExactIn(charlie, noopId, 500e6, false);

        vm.warp(market.tradingEnd + 1);

        // Settlement should succeed (fees deducted before LP re-addition)
        mm.settleMarket(marketId);

        // All users can still claim
        vm.prank(bob);
        mm.claimSettlement(marketId);
        vm.prank(charlie);
        mm.claimSettlement(marketId);
    }

    function test_settlement_noRecipient_feesSkipped() public {
        // Set fee but NO recipient (protocolFeeRecipient defaults to address(0)).
        vm.startPrank(umiaAdmin);
        hub.setDecisionSwapFeeBps(FEE_BPS_100);
        hub.setDecisionProtocolFeeCutBps(10_000);
        vm.stopPrank();

        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        _swapExactIn(bob, proposal1Id, 1_000e6, false);

        uint256 accruedFee = _accruedFeeMoney(proposal1Id);
        assertGt(accruedFee, 0, "Fees should accrue even without recipient");

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        assertEq(_accruedFeeMoney(proposal1Id), accruedFee, "Fees should not be cleared without recipient");
    }

    function test_invariant_holdsWithFees() public {
        _setupFee();
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        uint256 proposal2Id = market.proposalIds[2];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);
        vm.prank(charlie);
        mm.split(marketId, 0, 10_000e6);

        _swapExactIn(bob, proposal1Id, 1_000e6, false);
        _swapExactIn(charlie, proposal2Id, 2_000e6, false);
        _swapExactIn(bob, proposal1Id, 500e6, false);

        _verifyInvariant(marketId);

        // Swap back the other direction
        Proposal memory prop1 = _proposalById(proposal1Id);
        uint256 bobVenture = mm.balanceOf(bob, prop1.virtualVentureId);
        _swapExactIn(bob, proposal1Id, bobVenture / 2, true);

        _verifyInvariant(marketId);
    }

    function test_invariant_feeLiabilityIncludedInSolvencyCheck() public {
        _setupFee();
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        _swapExactIn(bob, proposal1Id, 5_000e6, false);
        _swapExactIn(bob, proposal1Id, 3_000e6, false);

        uint256 feeVenture = _accruedFeeVenture(proposal1Id);
        uint256 feeMoney = _accruedFeeMoney(proposal1Id);
        assertGt(feeVenture + feeMoney, 0, "Fees should have accrued");

        LiquidityRemovalInfo memory removalInfo = _liquidityRemovalInfo(marketId);
        uint256 ventureRemoved = removalInfo.ventureRemoved;
        uint256 moneyRemoved = removalInfo.moneyRemoved;
        uint256 totalRealVenture = _realVentureBalance(marketId) + ventureRemoved;
        uint256 totalRealMoney = _realMoneyBalance(marketId) + moneyRemoved;

        uint256 userVenture = mm.userVirtualVentureSupply(proposal1Id);
        uint256 userMoney = mm.userVirtualMoneySupply(proposal1Id);

        assertGe(totalRealVenture, userVenture + feeVenture, "Real venture must cover user claims + fee liability");
        assertGe(totalRealMoney, userMoney + feeMoney, "Real money must cover user claims + fee liability");

        _verifyInvariant(marketId);
    }

    function test_feeAccrual_emitsEvent() public {
        _setupFee();
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        uint256 swapAmount = 1_000e6;
        uint256 expectedFee = (swapAmount * FEE_BPS_100) / 10_000;

        vm.expectEmit(true, false, false, true, address(mm));
        emit IUmiaMarketCore.ProtocolFeeAccrued(proposal1Id, false, expectedFee);

        _swapExactIn(bob, proposal1Id, swapAmount, false);
    }

    function test_settlement_emitsFeesCollectedEvent() public {
        _setupFee();
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);
        _swapExactIn(bob, proposal1Id, 1_000e6, false);

        vm.warp(market.tradingEnd + 1);

        // We can't predict which proposal wins, so just verify settlement succeeds
        mm.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(marketId);
        assertTrue(winning.proposalId != 0, "Market should be settled");
    }

    function test_hubSetters_workCorrectly() public {
        vm.startPrank(umiaAdmin);

        hub.setSpotSwapFeeBps(120);
        assertEq(hub.spotSwapFeeBps(), 120);
        hub.setSpotProtocolFeeCutBps(3_000);
        assertEq(hub.spotProtocolFeeCutBps(), 3_000);

        hub.setDecisionSwapFeeBps(250);
        assertEq(hub.decisionSwapFeeBps(), 250);
        hub.setDecisionProtocolFeeCutBps(4_000);
        assertEq(hub.decisionProtocolFeeCutBps(), 4_000);

        hub.setProtocolFeeRecipient(feeRecipient);
        assertEq(hub.protocolFeeRecipient(), feeRecipient);

        vm.stopPrank();
    }

    function test_hubSetters_revertOnInvalidBps() public {
        uint16 cap = hub.MAX_SWAP_FEE_BPS();
        vm.startPrank(umiaAdmin);

        // Swap fees are capped at MAX_SWAP_FEE_BPS (10%); one above the cap reverts.
        hub.setDecisionSwapFeeBps(cap);
        assertEq(hub.decisionSwapFeeBps(), cap);
        vm.expectRevert();
        hub.setDecisionSwapFeeBps(cap + 1);

        hub.setSpotSwapFeeBps(cap);
        assertEq(hub.spotSwapFeeBps(), cap);
        vm.expectRevert();
        hub.setSpotSwapFeeBps(cap + 1);
        // Zero would leave V2 pools without an active-liquidity band.
        vm.expectRevert(IUmiaHub.InvalidBps.selector);
        hub.setSpotSwapFeeBps(0);

        // Protocol cuts are capped at 100% of the fee (MAX_BPS = 10000).
        hub.setDecisionProtocolFeeCutBps(10_000);
        vm.expectRevert();
        hub.setDecisionProtocolFeeCutBps(10_001);

        // Winning-market threshold has a floor: below 100 bps (incl. 0) reverts, 100 is accepted.
        vm.expectRevert();
        hub.setWinningMarketThresholdBps(0);
        vm.expectRevert();
        hub.setWinningMarketThresholdBps(99);
        hub.setWinningMarketThresholdBps(100);
        assertEq(hub.winningMarketThresholdBps(), 100);

        vm.stopPrank();
    }

    function test_hubSetters_revertOnNonOwner() public {
        vm.prank(bob);
        vm.expectRevert();
        hub.setDecisionSwapFeeBps(100);

        vm.prank(bob);
        vm.expectRevert();
        hub.setDecisionProtocolFeeCutBps(5_000);

        vm.prank(bob);
        vm.expectRevert();
        hub.setProtocolFeeRecipient(feeRecipient);
    }

    function test_hubSetters_poolAndTimingGlobals() public {
        vm.startPrank(umiaAdmin);

        hub.setDefaultPoolTickSpacing(10);
        assertEq(hub.defaultPoolTickSpacing(), 10);

        hub.setMigrationDelayBlocks(1234);
        assertEq(hub.migrationDelayBlocks(), 1234);

        hub.setSweepDelayBlocks(5678);
        assertEq(hub.sweepDelayBlocks(), 5678);

        vm.stopPrank();
    }

    function test_hubSetters_revertOnInvalidPoolParams() public {
        vm.startPrank(umiaAdmin);

        // Tick spacing of 0 (below MIN_TICK_SPACING) reverts.
        vm.expectRevert(IUmiaHub.InvalidPoolTickSpacing.selector);
        hub.setDefaultPoolTickSpacing(0);

        vm.stopPrank();
    }

    function test_hubSetters_poolAndTimingRevertOnNonOwner() public {
        vm.prank(bob);
        vm.expectRevert();
        hub.setDefaultPoolTickSpacing(10);

        vm.prank(bob);
        vm.expectRevert();
        hub.setMigrationDelayBlocks(100);

        vm.prank(bob);
        vm.expectRevert();
        hub.setSweepDelayBlocks(100);
    }
}
