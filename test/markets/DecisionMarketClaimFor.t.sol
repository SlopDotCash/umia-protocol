// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";

contract DecisionMarketClaimForTest is DecisionMarketBase {
    address keeper = makeAddr("keeper");

    function _tradeAndSettle() internal {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 5_000e6);
        vm.prank(charlie);
        mm.split(marketId, 0, 2_000e6);
        _swapExactIn(bob, market.proposalIds[1], 1_000e6, false);

        for (uint256 i = 0; i < market.proposalIds.length; i++) {
            uint256 pid = market.proposalIds[i];
            Proposal memory prop = _proposalById(pid);
            _swapExactIn(charlie, pid, 200e6, false);
            uint256 v = mm.balanceOf(charlie, prop.virtualVentureId);
            uint256 m = mm.balanceOf(charlie, prop.virtualMoneyId);
            uint256 priceX96 = mm.getPriceX96(pid, true);
            vm.prank(charlie);
            mm.addLiquidity(pid, v / 2, m / 2, priceX96, 1000);
        }

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);
    }

    function _balances(address user) internal view returns (uint256 venture, uint256 money) {
        return (IERC20(ventureToken).balanceOf(user), usdc.balanceOf(user));
    }

    function _users(address a, address b) internal pure returns (address[] memory users) {
        users = new address[](2);
        users[0] = a;
        users[1] = b;
    }

    function test_claimFor_matchesSelfClaimAndPaysTheHolder() public {
        _tradeAndSettle();

        uint256 snapshot = vm.snapshotState();
        vm.prank(bob);
        mm.claimSettlement(marketId);
        vm.prank(charlie);
        mm.claimSettlement(marketId);
        (uint256 bobVenture, uint256 bobMoney) = _balances(bob);
        (uint256 charlieVenture, uint256 charlieMoney) = _balances(charlie);
        vm.revertToState(snapshot);

        vm.prank(keeper);
        mm.claimSettlementFor(marketId, _users(bob, charlie));

        (uint256 v, uint256 m) = _balances(bob);
        assertEq(v, bobVenture, "bob venture");
        assertEq(m, bobMoney, "bob money");
        (v, m) = _balances(charlie);
        assertEq(v, charlieVenture, "charlie venture");
        assertEq(m, charlieMoney, "charlie money");
        assertGt(charlieMoney, 0, "charlie's LP position is redeemed");
        (v, m) = _balances(keeper);
        assertEq(v + m, 0, "caller receives nothing");

        uint256 winningPid = mm.winningProposalByMarketId(marketId).proposalId;
        assertEq(mm.balanceOf(charlie, mm.getLiquidityShareId(winningPid)), 0, "LP shares burned");
        assertEq(mm.userVirtualVentureSupply(winningPid), 0, "no venture claims left");
        assertEq(mm.userVirtualMoneySupply(winningPid), 0, "no money claims left");
    }

    function test_claimFor_skipsClaimedEmptyAndDuplicateUsers() public {
        _tradeAndSettle();

        vm.prank(bob);
        mm.claimSettlement(marketId);
        (uint256 bobVenture, uint256 bobMoney) = _balances(bob);

        address[] memory users = new address[](4);
        users[0] = bob;
        users[1] = dave;
        users[2] = charlie;
        users[3] = charlie;
        (uint256 charlieVentureBefore, uint256 charlieMoneyBefore) = _balances(charlie);

        vm.prank(keeper);
        mm.claimSettlementFor(marketId, users);

        (uint256 v, uint256 m) = _balances(bob);
        assertEq(v, bobVenture, "bob unchanged");
        assertEq(m, bobMoney, "bob unchanged");
        (v, m) = _balances(charlie);
        assertGt(v + m, charlieVentureBefore + charlieMoneyBefore, "charlie claimed once");

        vm.expectRevert(IUmiaMarketCore.NoClaimableTokens.selector);
        vm.prank(dave);
        mm.claimSettlement(marketId);
    }

    function test_claimFor_blocksLaterSelfClaim() public {
        _tradeAndSettle();

        vm.prank(keeper);
        mm.claimSettlementFor(marketId, _users(bob, charlie));

        vm.expectRevert(IUmiaMarketCore.AlreadyClaimed.selector);
        vm.prank(bob);
        mm.claimSettlement(marketId);
    }

    function test_claimFor_rejectsMarketCore() public {
        _tradeAndSettle();

        vm.expectRevert(IUmiaMarketCore.InvalidRecipient.selector);
        vm.prank(keeper);
        mm.claimSettlementFor(marketId, _users(bob, address(mm)));
    }

    function test_claimFor_revertsBeforeSettlement() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        vm.expectRevert(IUmiaMarketCore.MarketNotEnded.selector);
        mm.claimSettlementFor(marketId, _users(bob, charlie));

        vm.warp(_marketById(marketId).tradingEnd + 1);
        vm.expectRevert(IUmiaMarketCore.MarketNotSettled.selector);
        mm.claimSettlementFor(marketId, _users(bob, charlie));
    }

    function test_claimFor_unknownMarketReverts() public {
        vm.expectRevert(IUmiaMarketCore.MarketNotFound.selector);
        mm.claimSettlementFor(999, _users(bob, charlie));
    }
}
