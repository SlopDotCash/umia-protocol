// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {ConditionalMarketOracle} from "../../src/periphery/ConditionalMarketOracle.sol";
import {Venture} from "../../src/core/Venture.sol";

/// @title DecisionMarketOracleTruncationTest
/// @notice Integration tests for oracle price clamping in full market lifecycle
contract DecisionMarketOracleTruncationTest is DecisionMarketBase {
    uint256 constant Q112 = 2 ** 112;

    // ═══════════════════════════════════════════════════════════
    // Clamping limits single-swap TWAP impact
    // ═══════════════════════════════════════════════════════════

    function test_truncation_massiveSwapClamped() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        // Split to get virtual tokens
        vm.prank(bob);
        mm.split(marketId, 0, 100_000e6);

        // Get baseline TWAP after split
        vm.warp(block.timestamp + 1 hours);
        uint256 twapBefore = mm.getProposalTWAP(proposal1Id);

        // Massive swap to push price
        _swapExactIn(bob, proposal1Id, 50_000e6, false);

        // Immediately check — TWAP should barely move since the price is clamped
        // and the swap happened in the same block (or close)
        vm.warp(block.timestamp + 1);
        uint256 twapAfter = mm.getProposalTWAP(proposal1Id);

        // Even a 50k swap should not move 3h+ TWAP by more than a bounded amount
        // The clamping ensures the per-update contribution is at most 2.5x
        uint256 maxReasonableRatio = 300; // 3x at absolute most
        assertLt(
            (twapAfter * 100) / twapBefore,
            maxReasonableRatio,
            "Massive single swap should not move TWAP by more than 3x"
        );
    }

    function test_truncation_lastBlockManipulationHasBoundedImpact() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);

        // Small trade to establish a baseline
        _swapExactIn(bob, proposal1Id, 100e6, false);
        vm.warp(block.timestamp + 1 hours);

        uint256 twapBeforeManipulation = mm.getProposalTWAP(proposal1Id);

        // Warp to just before trading end
        vm.warp(market.tradingEnd - 1);

        // Massive last-second swap
        _swapExactIn(bob, proposal1Id, 40_000e6, false);

        vm.warp(market.tradingEnd + 1);
        uint256 twapAfterManipulation = mm.getProposalTWAP(proposal1Id);

        // The TWAP change from the last-second manipulation should be bounded:
        // Clamping limits per-update to 2.5x, and the 3-day TWAP window dilutes it.
        // The manipulation contributes only ~2 seconds out of ~3 days.
        uint256 maxAllowedRatio = 300; // 3x at absolute most
        uint256 actualRatio = (twapAfterManipulation * 100) / twapBeforeManipulation;
        assertLt(actualRatio, maxAllowedRatio, "Last-second manipulation should have bounded TWAP impact");
    }

    // ═══════════════════════════════════════════════════════════
    // TWAP convergence with legitimate trading
    // ═══════════════════════════════════════════════════════════

    function test_truncation_legitimateTradingConverges() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);

        // Steady buying over multiple hours (legitimate price discovery)
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1 hours);
            _swapExactIn(bob, proposal1Id, 1_000e6, false);
        }

        uint256 twapAfterBuying = mm.getProposalTWAP(proposal1Id);

        // Wait some more for TWAP to converge closer to spot
        vm.warp(block.timestamp + 12 hours);
        uint256 twapConverged = mm.getProposalTWAP(proposal1Id);

        // TWAP should be moving towards the new price
        assertGt(twapConverged, twapAfterBuying, "TWAP should converge towards new steady price");
    }

    // ═══════════════════════════════════════════════════════════
    // Oracle update at every state change
    // ═══════════════════════════════════════════════════════════

    function test_oracleUpdatedOnEverySwap() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        (,,,,, uint32 tsBeforeSwap,,) = conditionalMarketOracle.oracleStates(proposal1Id);

        // First swap in a new block
        vm.warp(block.timestamp + 1 hours);
        _swapExactIn(bob, proposal1Id, 500e6, false);

        (,,,,, uint32 ts1,,) = conditionalMarketOracle.oracleStates(proposal1Id);
        assertGt(ts1, tsBeforeSwap, "Oracle timestamp should advance after first swap");

        // Second swap in a later block
        vm.warp(block.timestamp + 60);
        _swapExactIn(bob, proposal1Id, 500e6, false);

        (,,,,, uint32 ts2,,) = conditionalMarketOracle.oracleStates(proposal1Id);
        assertGt(ts2, ts1, "Oracle timestamp should advance after second swap");
    }

    function test_oracleUpdatedAtSettlement() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);
        uint256 noopId = market.proposalIds[0];

        (,,,,, uint32 tsBeforeSettlement,,) = conditionalMarketOracle.oracleStates(noopId);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        (,,,,, uint32 tsAfterSettlement,,) = conditionalMarketOracle.oracleStates(noopId);
        assertEq(
            tsAfterSettlement, uint32(market.tradingEnd), "Oracle should be capped at tradingEnd, not current time"
        );
        assertGt(tsAfterSettlement, tsBeforeSettlement, "Timestamp should advance at settlement");
    }

    // ═══════════════════════════════════════════════════════════
    // Settlement with spot price guard
    // ═══════════════════════════════════════════════════════════

    function test_settlementCallsSpotPriceGuard() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);
        _swapExactIn(bob, proposal1Id, 1_000e6, false);

        vm.warp(market.tradingEnd + 1);

        // Should succeed — no spot price manipulation
        mm.settleMarket(marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(marketId);
        assertGt(winning.proposalId, 0, "Settlement should complete");
    }

    function _createVentureSetup() internal {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();
        vm.label(ventureToken, "ALICE");

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(ventureId, MIN_MARKET_STAKE);

        _mintVenture(hub, venture, alice, MIN_MARKET_STAKE);

        vm.startPrank(alice);
        IERC20(ventureToken).approve(address(marketStake), type(uint256).max);
        marketStake.depositMarketStake(ventureId);
        vm.stopPrank();
    }

    function _createMarketOnly() internal {
        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] =
            IUmiaMarketCore.CreateProposalParams({title: "yes, cut yearly emissions by 10%", executionPayload: ""});
        proposals[1] =
            IUmiaMarketCore.CreateProposalParams({title: "yes, cut yearly emissions by 15%", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: ventureId,
            title: "should we cut yearly emissions?",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        vm.startPrank(alice);
        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);
        marketId = mm.createMarket(params, alice, nonce, signature);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    // TWAP anchoring at initialization
    // ═══════════════════════════════════════════════════════════

    function test_oracleAnchoredAtTradingStart() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);

        for (uint256 i = 0; i < market.proposalIds.length; i++) {
            uint256 pid = market.proposalIds[i];
            (,,,,, uint32 lastTimestamp,, bool initialized) = conditionalMarketOracle.oracleStates(pid);
            assertTrue(initialized, "Oracle must be initialized at market creation");
            assertEq(lastTimestamp, uint32(market.tradingStart), "Oracle must be anchored at trading start");
        }
    }

    function test_getProposalTWAPRevertsBeforeTradingStart() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);

        vm.warp(market.tradingStart - 1);
        vm.expectRevert(ConditionalMarketOracle.TradingNotStarted.selector);
        mm.getProposalTWAP(market.proposalIds[1]);
    }

    function test_scoringWindowNotMovedBySubsequentSwaps() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        (,,, uint32 startBefore, uint32 endBefore,,,) = conditionalMarketOracle.oracleStates(proposal1Id);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);
        _swapExactIn(bob, proposal1Id, 1_000e6, false);

        (,,, uint32 startAfter, uint32 endAfter,,,) = conditionalMarketOracle.oracleStates(proposal1Id);
        assertEq(startAfter, startBefore, "tradingStart should not change after trading begins");
        assertEq(endAfter, endBefore, "tradingEnd should not change after trading begins");
    }

    // ═══════════════════════════════════════════════════════════
    // Clamping state stored correctly
    // ═══════════════════════════════════════════════════════════

    function test_lastPriceStoredAfterMarketCreation() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        (, int24 lastP0,,,,,,) = conditionalMarketOracle.oracleStates(proposal1Id);
        assertEq(lastP0, _seedTick(proposal1Id), "seed observation should be set after market creation");
    }

    // ═══════════════════════════════════════════════════════════
    // Multiple proposals maintain independent oracle state
    // ═══════════════════════════════════════════════════════════

    function test_settlementTWAPFrozenAtTradingEnd() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);
        _swapExactIn(bob, proposal1Id, 1_000e6, false);

        vm.warp(block.timestamp + 1 hours);
        _swapExactIn(bob, proposal1Id, 500e6, false);

        // Settle just after trading end
        vm.warp(market.tradingEnd + 1);
        uint256 twapEarly = mm.getProposalTWAP(proposal1Id);

        // TWAP should be the same even if we wait much longer before reading
        vm.warp(market.tradingEnd + 1 hours);
        uint256 twapLate = mm.getProposalTWAP(proposal1Id);

        assertEq(twapLate, twapEarly, "TWAP should be identical regardless of settlement delay");
    }

    function test_cumulativeZeroBaselineAtCreation() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        (int64 cum0, int24 lastP0,, uint32 start,, uint32 lastTimestamp,,) =
            conditionalMarketOracle.oracleStates(proposal1Id);

        assertEq(cum0, 0, "cumulative starts at zero, scoring anchored at trading start");
        assertEq(lastTimestamp, start, "anchor timestamp equals trading start");
        assertEq(start, uint32(market.tradingStart), "oracle trading start matches the market's");
        assertEq(lastP0, _seedTick(proposal1Id), "seed observation recorded at initialization");
    }

    function test_tradingWindowSetAtCreation() public {
        _createVentureAndMarket();

        Market memory market = _marketById(marketId);

        for (uint256 i = 0; i < market.proposalIds.length; i++) {
            uint256 pid = market.proposalIds[i];
            (,,, uint32 start, uint32 end,,,) = conditionalMarketOracle.oracleStates(pid);
            assertEq(start, uint32(market.tradingStart), "tradingStart should be set for each proposal");
            assertEq(end, uint32(market.tradingEnd), "tradingEnd should be set for each proposal");
        }
    }

    function test_proposalOracleStatesIndependent() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        uint256 proposal2Id = market.proposalIds[2];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 50_000e6);

        // Only trade on proposal 1
        _swapExactIn(bob, proposal1Id, 10_000e6, false);

        vm.warp(block.timestamp + 1 hours);

        uint256 twap1 = mm.getProposalTWAP(proposal1Id);
        uint256 twap2 = mm.getProposalTWAP(proposal2Id);

        // Proposal 1 had a large buy → TWAP should differ from proposal 2
        // Both start at the same initial price, but proposal 1 should diverge
        assertFalse(twap1 == twap2, "Traded proposal should have different TWAP from untraded");
    }

    /// @dev The pool's tick for the proposal's current reserves, as the oracle computes it.
    function _seedTick(uint256 proposalId) internal view returns (int24) {
        (uint256 reserve0, uint256 reserve1) = mm.cpmmStates(proposalId);
        return TickMath.getTickAtSqrtPrice(uint160(Math.sqrt(FullMath.mulDiv(reserve1, 1 << 192, reserve0))));
    }
}
