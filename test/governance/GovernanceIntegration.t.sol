// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {Venture} from "../../src/core/Venture.sol";
import {GovernanceExecutor} from "../../src/core/GovernanceExecutor.sol";
import {GovernanceTypes} from "../../src/libraries/GovernanceTypes.sol";

contract GovernanceIntegrationTest is DecisionMarketBase {
    function setUp() public override {
        super.setUp();

        // Lowest threshold the Hub allows (floor is MIN_WINNING_THRESHOLD_BPS); keeps test
        // markets resolving on a small margin without disabling the threshold entirely.
        vm.prank(umiaAdmin);
        hub.setWinningMarketThresholdBps(100);
    }

    function test_executeWinningProposal_mintsTokens() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 100e18}))
        });

        bytes memory payload = abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));

        uint256 _marketId = _createMarketWithPayload(payload);

        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);

        vm.warp(block.timestamp + 1 days + 1);
        mm.split(_marketId, 0, 5_000e6);

        Market memory market = _marketById(_marketId);
        uint256 proposalId = market.proposalIds[1];
        Proposal memory proposal = _proposalById(proposalId);

        uint256 virtualMoneyBalance = mm.balanceOf(bob, proposal.virtualMoneyId);
        uint256 buyAmount = virtualMoneyBalance / 2;

        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposalId, buyAmount, false);
        uint256 maxPriceImpactBps = priceImpact > 1000 ? priceImpact + 100 : 1000;
        uint256 amountOutMin = expectedOut * 99 / 100;

        mm.swapExactIn(proposalId, buyAmount, amountOutMin, maxPriceImpactBps, false, block.timestamp);
        vm.stopPrank();

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(_marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(_marketId);
        assertEq(winning.proposalId, proposalId);

        vm.warp(block.timestamp + 1 hours);
        mm.executeWinningProposal(_marketId);

        address ventureTokenAddr = Venture(venture).token();
        assertEq(IERC20(ventureTokenAddr).balanceOf(bob), 100e18);
    }

    function test_executeWinningProposal_revertsWhenExecutorNotSet() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 1e18}))
        });

        bytes memory payload = abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));

        uint256 _marketId = _createMarketWithPayload(payload);

        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);
        vm.warp(block.timestamp + 1 days + 1);
        mm.split(_marketId, 0, 5_000e6);

        Market memory market = _marketById(_marketId);
        uint256 proposalId = market.proposalIds[1];
        Proposal memory proposal = _proposalById(proposalId);

        uint256 virtualMoneyBalance = mm.balanceOf(bob, proposal.virtualMoneyId);
        uint256 buyAmount = virtualMoneyBalance / 2;

        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposalId, buyAmount, false);
        uint256 maxPriceImpactBps = priceImpact > 1000 ? priceImpact + 100 : 1000;
        uint256 amountOutMin = expectedOut * 99 / 100;

        mm.swapExactIn(proposalId, buyAmount, amountOutMin, maxPriceImpactBps, false, block.timestamp);
        vm.stopPrank();

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(_marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(_marketId);
        assertEq(winning.proposalId, proposalId, "Non-no-op proposal should win");

        vm.prank(umiaAdmin);
        hub.setDefaultGovernanceExecutor(address(0));

        vm.expectRevert(IUmiaMarketCore.GovernanceExecutorNotSet.selector);
        vm.warp(block.timestamp + 1 hours);
        mm.executeWinningProposal(_marketId);
    }

    function test_executeWinningProposal_revertsWhenExecutorHasNoCode() public {
        GovernanceTypes.ActionV1[] memory actions = new GovernanceTypes.ActionV1[](1);
        actions[0] = GovernanceTypes.ActionV1({
            actionType: GovernanceTypes.ActionType.MINT_TOKENS,
            actionVersion: 1,
            data: abi.encode(GovernanceTypes.MintTokens({to: bob, amount: 1e18}))
        });

        bytes memory payload = abi.encode(GovernanceTypes.ExecutionPlanV1({version: 1, actions: actions}));

        uint256 _marketId = _createMarketWithPayload(payload);

        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);
        vm.warp(block.timestamp + 1 days + 1);
        mm.split(_marketId, 0, 5_000e6);

        Market memory market = _marketById(_marketId);
        uint256 proposalId = market.proposalIds[1];
        Proposal memory proposal = _proposalById(proposalId);

        uint256 virtualMoneyBalance = mm.balanceOf(bob, proposal.virtualMoneyId);
        uint256 buyAmount = virtualMoneyBalance / 2;

        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposalId, buyAmount, false);
        uint256 maxPriceImpactBps = priceImpact > 1000 ? priceImpact + 100 : 1000;
        uint256 amountOutMin = expectedOut * 99 / 100;

        mm.swapExactIn(proposalId, buyAmount, amountOutMin, maxPriceImpactBps, false, block.timestamp);
        vm.stopPrank();

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(_marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(_marketId);
        assertEq(winning.proposalId, proposalId, "Non-no-op proposal should win");

        vm.prank(umiaAdmin);
        hub.setDefaultGovernanceExecutor(makeAddr("executor-eoa"));

        vm.expectRevert(IUmiaMarketCore.GovernanceExecutorNotSet.selector);
        vm.warp(block.timestamp + 1 hours);
        mm.executeWinningProposal(_marketId);

        assertFalse(mm.marketExecuted(_marketId));
    }

    function test_executeWinningProposal_allowsEmptyPayloadWithoutExecutor() public {
        uint256 _marketId = _createMarketWithPayload("");

        vm.startPrank(bob);
        usdc.approve(address(mm), type(uint256).max);
        vm.warp(block.timestamp + 1 days + 1);
        mm.split(_marketId, 0, 5_000e6);

        Market memory market = _marketById(_marketId);
        uint256 proposalId = market.proposalIds[1];
        Proposal memory proposal = _proposalById(proposalId);

        uint256 virtualMoneyBalance = mm.balanceOf(bob, proposal.virtualMoneyId);
        uint256 buyAmount = virtualMoneyBalance / 2;

        (uint256 expectedOut, uint256 priceImpact) = mm.quoteSwapExactIn(proposalId, buyAmount, false);
        uint256 maxPriceImpactBps = priceImpact > 1000 ? priceImpact + 100 : 1000;
        uint256 amountOutMin = expectedOut * 99 / 100;

        mm.swapExactIn(proposalId, buyAmount, amountOutMin, maxPriceImpactBps, false, block.timestamp);
        vm.stopPrank();

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(_marketId);

        IUmiaMarketCore.WinningProposal memory winning = mm.winningProposalByMarketId(_marketId);
        assertEq(winning.proposalId, proposalId, "empty-payload proposal should win");

        vm.prank(umiaAdmin);
        hub.setDefaultGovernanceExecutor(address(0));

        vm.warp(block.timestamp + 1 hours);
        mm.executeWinningProposal(_marketId);

        assertTrue(mm.marketExecuted(_marketId));
    }

    function _createMarketWithPayload(bytes memory payload) internal returns (uint256 _marketId) {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "aliceUMO", "ALICE", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(ventureId, MIN_MARKET_STAKE);

        _mintVenture(hub, venture, alice, MIN_MARKET_STAKE);

        _warmSpotOracle(venture);

        vm.startPrank(alice);
        IERC20(ventureToken).approve(address(marketStake), type(uint256).max);
        marketStake.depositMarketStake(ventureId);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "mint treasury", executionPayload: payload});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: ventureId,
            title: "governance execution",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(alice);
        bytes memory signature = _signMarketCreation(alice, params, nonce);

        _marketId = mm.createMarket(params, alice, nonce, signature);
        marketId = _marketId;
        vm.stopPrank();
    }
}
