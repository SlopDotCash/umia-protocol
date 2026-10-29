// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";

/// @title DecisionMarketTWAPTest
/// @notice Tests for TWAP oracle functionality in decision markets
contract DecisionMarketTWAPTest is DecisionMarketBase {
    function test_twap_oracleInitializedOnMarketCreation() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        (,,,,, uint32 lastTimestamp,, bool initialized) = conditionalMarketOracle.oracleStates(proposal1Id);

        assertTrue(initialized, "Oracle should be initialized at market creation");
        assertEq(lastTimestamp, uint32(market.tradingStart), "Oracle anchored at trading start");
    }

    function test_twap_oracleUpdatesOnSwap() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        (int64 cum0Before,,,,,,,) = conditionalMarketOracle.oracleStates(proposal1Id);

        vm.warp(block.timestamp + 1 hours);

        _swapExactIn(bob, proposal1Id, 1_000e6, false);

        (int64 cum0After,,,,, uint32 tsAfter,,) = conditionalMarketOracle.oracleStates(proposal1Id);

        assertNotEq(cum0After, cum0Before, "Cumulative tick should accrue after time passes");
        assertEq(tsAfter, uint32(block.timestamp), "Timestamp should be updated");
    }

    function test_twap_oracleAnchoredAtCreation() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);

        for (uint256 i = 0; i < market.proposalIds.length; i++) {
            uint256 pid = market.proposalIds[i];
            (,,,,, uint32 lastTimestamp,, bool initialized) = conditionalMarketOracle.oracleStates(pid);
            assertTrue(initialized, "Every proposal initialized after creation");
            assertEq(lastTimestamp, uint32(market.tradingStart), "Oracle anchored at trading start");
        }
    }

    function test_twap_calculatesAveragePriceOverTime() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);

        _swapExactIn(bob, proposal1Id, 1_000e6, false);

        vm.warp(block.timestamp + 1 hours);
        uint256 twap2 = mm.getProposalTWAP(proposal1Id);

        assertGt(twap2, 0, "TWAP should be positive after trading");

        _swapExactIn(bob, proposal1Id, 10_000e6, false);

        uint256 twap3 = mm.getProposalTWAP(proposal1Id);

        vm.warp(block.timestamp + 1 hours);
        uint256 twap4 = mm.getProposalTWAP(proposal1Id);

        assertGt(twap4, twap3, "TWAP should drift towards current price over time");
    }

    function test_twap_settlementUsesTWAPNotSpot() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);

        _swapExactIn(bob, proposal1Id, 20_000e6, false);

        vm.warp(block.timestamp + 2 days);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(marketId);

        assertGt(winning.price, 0, "Winning price (TWAP) should be positive");
    }

    function test_twap_briefSpikeHasLimitedEffect() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);

        _swapExactIn(bob, proposal1Id, 100e6, false);

        vm.warp(block.timestamp + 2 hours);
        uint256 twapBaseline = mm.getProposalTWAP(proposal1Id);

        _swapExactIn(bob, proposal1Id, 20_000e6, false);

        vm.warp(block.timestamp + 1 minutes);
        uint256 twapBriefSpike = mm.getProposalTWAP(proposal1Id);

        assertGt(twapBriefSpike, twapBaseline, "TWAP should increase slightly after spike");

        vm.warp(block.timestamp + 1 hours);
        uint256 twapAfterHour = mm.getProposalTWAP(proposal1Id);

        assertGt(twapAfterHour, twapBriefSpike, "TWAP should continue increasing as spike price accumulates weight");
    }

    function test_twap_noTradesUsesInitialPriceTWAP() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.expectRevert(bytes4(keccak256("TradingNotStarted()")));
        mm.getProposalTWAP(proposal1Id);

        vm.warp(market.tradingStart + 1 hours);

        uint256 twap = mm.getProposalTWAP(proposal1Id);
        assertGt(twap, 0, "TWAP should be positive with no trades");

        uint256 noopTWAP = mm.getProposalTWAP(market.proposalIds[0]);
        assertEq(twap, noopTWAP, "All proposals should have equal TWAP when no trades occurred");
    }

    function test_twap_allProposalsUpdateOnSettlement() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        uint256 noopId = market.proposalIds[0];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        _swapExactIn(bob, proposal1Id, 1_000e6, false);

        vm.warp(market.tradingEnd + 1);

        mm.settleMarket(marketId);

        (,,,,, uint32 tsProp1After,,) = conditionalMarketOracle.oracleStates(proposal1Id);
        (,,,,, uint32 tsNoopAfter,,) = conditionalMarketOracle.oracleStates(noopId);

        assertEq(tsProp1After, uint32(market.tradingEnd), "Proposal1 oracle should be capped at tradingEnd");
        assertEq(tsNoopAfter, uint32(market.tradingEnd), "Noop oracle should be capped at tradingEnd");
    }

    function test_twap_settlementWithNoTradesUsesAnchoredTWAP() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        uint256 noopId = market.proposalIds[0];

        (,,,,,,, bool initialized) = conditionalMarketOracle.oracleStates(proposal1Id);
        assertTrue(initialized, "Oracle initialized even without trades");

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(marketId);
        assertEq(winning.proposalId, noopId, "No-op should win when no trades move any proposal price");
        assertGt(winning.price, 0, "Winning TWAP should be positive");
    }
}
