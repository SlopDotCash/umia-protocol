// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";

/// @title DecisionMarketInvariantTest
/// @notice Tests for invariant verification and token accounting
contract DecisionMarketInvariantTest is DecisionMarketBase {
    function test_invariant_maintainedThroughFullCycle() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        uint256 noopId = market.proposalIds[0];

        vm.warp(block.timestamp + 1 days + 1);

        _verifyInvariant(marketId);

        vm.prank(bob);
        mm.split(marketId, 0, 5_000e6);
        _verifyInvariant(marketId);

        vm.prank(charlie);
        mm.split(marketId, 0, 3_000e6);
        _verifyInvariant(marketId);

        _swapExactIn(bob, proposal1Id, 500e6, false);
        _verifyInvariant(marketId);

        _swapExactIn(charlie, proposal1Id, 300e6, false);
        _verifyInvariant(marketId);

        _swapExactIn(bob, noopId, 200e6, false);
        _verifyInvariant(marketId);

        vm.prank(bob);
        mm.merge(marketId, 0, 100e6);
        _verifyInvariant(marketId);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        vm.prank(bob);
        mm.claimSettlement(marketId);
        vm.prank(charlie);
        mm.claimSettlement(marketId);
    }

    function test_invariant_swapDoesNotInflateSupply() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 10_000e6);

        (uint256 ventureSupplyBefore, uint256 moneySupplyBefore) = _getTotalVirtualSupply(proposal1Id);

        for (uint256 i = 0; i < 5; i++) {
            _swapExactIn(bob, proposal1Id, 100e6, false);

            Proposal memory prop1 = _proposalById(proposal1Id);
            uint256 bobVenture = mm.balanceOf(bob, prop1.virtualVentureId);
            if (bobVenture > 10e6) {
                _swapExactIn(bob, proposal1Id, bobVenture / 10, true);
            }
        }

        (uint256 ventureSupplyAfter, uint256 moneySupplyAfter) = _getTotalVirtualSupply(proposal1Id);
        assertEq(ventureSupplyAfter, ventureSupplyBefore, "venture supply should not change from swaps");
        assertEq(moneySupplyAfter, moneySupplyBefore, "Money supply should not change from swaps");
    }

    function test_invariant_splitMergeNetZero() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        vm.warp(block.timestamp + 1 days + 1);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        vm.startPrank(bob);
        mm.split(marketId, 0, 1_000e6);
        mm.merge(marketId, 0, 1_000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), bobUsdcBefore, "Split+merge should be net zero");

        Market memory market = _marketById(marketId);
        for (uint256 i = 0; i < market.proposalIds.length; i++) {
            uint256 propId = market.proposalIds[i];
            Proposal memory prop = _proposalById(propId);
            assertEq(mm.balanceOf(bob, prop.virtualMoneyId), 0, "Virtual money should be zero");
            assertEq(mm.balanceOf(bob, prop.virtualVentureId), 0, "Virtual venture should be zero");
        }
    }

    function test_accounting_realBalancesTrackDeposits() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);

        vm.warp(block.timestamp + 1 days + 1);

        uint256 realMoneyBefore = _realMoneyBalance(marketId);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);
        assertEq(_realMoneyBalance(marketId), realMoneyBefore + 1_000e6, "Real balance should increase");

        vm.prank(charlie);
        mm.split(marketId, 0, 500e6);
        assertEq(_realMoneyBalance(marketId), realMoneyBefore + 1_500e6, "Real balance should track all deposits");

        vm.prank(bob);
        mm.merge(marketId, 0, 300e6);
        assertEq(_realMoneyBalance(marketId), realMoneyBefore + 1_200e6, "Real balance should decrease on merge");
    }

    function test_accounting_userSupplyTracksCorrectly() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);

        assertEq(mm.userVirtualMoneySupply(proposal1Id), 0, "Initial user supply should be 0");

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);
        assertEq(mm.userVirtualMoneySupply(proposal1Id), 1_000e6, "User supply should match split");

        uint256 userMoneyBefore = mm.userVirtualMoneySupply(proposal1Id);
        uint256 userVentureBefore = mm.userVirtualVentureSupply(proposal1Id);

        uint256 swapAmountIn = 100e6;
        uint256 amountOut = _swapExactIn(bob, proposal1Id, swapAmountIn, false);

        assertEq(
            mm.userVirtualMoneySupply(proposal1Id),
            userMoneyBefore - swapAmountIn,
            "User money supply should decrease by swap input"
        );
        assertEq(
            mm.userVirtualVentureSupply(proposal1Id),
            userVentureBefore + amountOut,
            "User UMO supply should increase by swap output"
        );
    }

    function test_accounting_cpmmReservesMatchBalances() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];
        Proposal memory prop1 = _proposalById(proposal1Id);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(bob);
        mm.split(marketId, 0, 1_000e6);

        (uint256 reserve0, uint256 reserve1) = mm.cpmmStates(proposal1Id);

        uint256 contractVenture = mm.balanceOf(address(mm), prop1.virtualVentureId);
        uint256 contractMoney = mm.balanceOf(address(mm), prop1.virtualMoneyId);

        assertEq(contractVenture, reserve0, "Contract venture balance should match reserve0");
        assertEq(contractMoney, reserve1, "Contract Money balance should match reserve1");

        _swapExactIn(bob, proposal1Id, 100e6, false);

        (reserve0, reserve1) = mm.cpmmStates(proposal1Id);
        contractVenture = mm.balanceOf(address(mm), prop1.virtualVentureId);
        contractMoney = mm.balanceOf(address(mm), prop1.virtualMoneyId);

        // The protocol's cut of the swap fee is held as virtual tokens by the market but tracked in
        // accruedFee* rather than the CPMM reserves, so it sits outside reserve0/reserve1.
        assertEq(
            contractVenture,
            reserve0 + _accruedFeeVenture(proposal1Id),
            "After swap: Contract venture should match reserve0 + accrued fee"
        );
        assertEq(
            contractMoney,
            reserve1 + _accruedFeeMoney(proposal1Id),
            "After swap: Contract Money should match reserve1 + accrued fee"
        );
    }

    /// @notice Fuzzes random sequences of split / merge / swap / addLiquidity and asserts the
    ///         solvency invariant holds after every operation. This exercises the accounting
    ///         conservation `_checkInvariant` relies on across the swap and addLiquidity paths,
    ///         which are not self-checked on-chain. The assertion is the same `>=` property the
    ///         contract enforces: real backing must cover the largest per-proposal claim + fees.
    ///         An over-collateralized (`>`) state is a safe, supported outcome, not a failure.
    function testFuzz_solvencyInvariantUnderRandomOps(uint256 seed) public {
        _createVentureAndMarket();
        _setupTrader(bob);
        _setupTrader(charlie);
        _mintVenture(hub, venture, bob, 1_000_000e18);
        _mintVenture(hub, venture, charlie, 1_000_000e18);
        vm.warp(block.timestamp + 1 days + 1);

        Market memory market = _marketById(marketId);
        uint256 n = market.proposalIds.length;

        _verifyInvariant(marketId);
        _verifyGroundTruthSolvency(marketId);

        for (uint256 i = 0; i < 40; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address actor = ((seed >> 1) & 1) == 0 ? bob : charlie;
            uint256 op = seed % 6;
            uint256 propId = market.proposalIds[(seed >> 8) % n];
            uint256 amt = ((seed >> 16) % 5_000e6) + 1;

            if (op == 0) {
                // split money (6 decimals)
                vm.prank(actor);
                try mm.split(marketId, 0, amt) {} catch {}
            } else if (op == 1) {
                // split venture (18 decimals)
                vm.prank(actor);
                try mm.split(marketId, amt * 1e12, 0) {} catch {}
            } else if (op == 2) {
                // exact-in swap of whichever input token `actor` holds in this proposal
                bool zeroForOne = ((seed >> 24) & 1) == 0;
                uint256 inId = zeroForOne ? mm.getVirtualVentureId(propId) : mm.getVirtualMoneyId(propId);
                uint256 bal = mm.balanceOf(actor, inId);
                if (bal > 0) {
                    uint256 inAmt = ((seed >> 32) % bal) + 1;
                    vm.prank(actor);
                    try mm.swapExactIn(propId, inAmt, 0, 10_000, zeroForOne, block.timestamp + 300) {} catch {}
                }
            } else if (op == 3) {
                // exact-out swap, bounded so `actor`'s input holding can cover amountInMax
                bool zeroForOne = ((seed >> 24) & 1) == 0;
                uint256 outId = zeroForOne ? mm.getVirtualMoneyId(propId) : mm.getVirtualVentureId(propId);
                uint256 inId = zeroForOne ? mm.getVirtualVentureId(propId) : mm.getVirtualMoneyId(propId);
                uint256 outBal = mm.balanceOf(actor, outId);
                uint256 inBudget = mm.balanceOf(actor, inId);
                if (outBal > 0 && inBudget > 0) {
                    uint256 outAmt = ((seed >> 32) % (outBal / 4 + 1)) + 1;
                    vm.prank(actor);
                    try mm.swapExactOut(propId, outAmt, inBudget, 10_000, zeroForOne, block.timestamp + 300) {} catch {}
                }
            } else if (op == 4) {
                // merge equal amounts across all proposals (bounded by the min per-proposal balance)
                (uint256 minV, uint256 minM) = _minPerProposalBalance(actor, market.proposalIds);
                uint256 vMerge = minV == 0 ? 0 : ((seed >> 40) % (minV + 1));
                uint256 mMerge = minM == 0 ? 0 : ((seed >> 48) % (minM + 1));
                if (vMerge > 0 || mMerge > 0) {
                    vm.prank(actor);
                    try mm.merge(marketId, vMerge, mMerge) {} catch {}
                }
            } else {
                // add liquidity from `actor`'s holdings in this proposal
                uint256 vBal = mm.balanceOf(actor, mm.getVirtualVentureId(propId));
                uint256 mBal = mm.balanceOf(actor, mm.getVirtualMoneyId(propId));
                if (vBal > 0 && mBal > 0) {
                    uint256 a0 = ((seed >> 56) % vBal) + 1;
                    uint256 a1 = ((seed >> 96) % mBal) + 1;
                    try mm.getPriceX96(propId, true) returns (uint256 price) {
                        vm.prank(actor);
                        try mm.addLiquidity(propId, a0, a1, price, 10_000) {} catch {}
                    } catch {}
                }
            }

            // Both the counter-based conservation AND ground-truth (real ERC-20 balance) solvency
            // must hold after every op — the latter is what makes this fuzz catch a real-token leak.
            _verifyInvariant(marketId);
            _verifyGroundTruthSolvency(marketId);
            _verifyExactConservation(marketId);
        }

        // Exercise the redemption paths where real tokens actually leave the core, then assert the
        // core can still cover the winning proposal's user claims (ground-truth solvency at settle).
        vm.warp(market.tradingEnd + 1);
        (uint256 realVenture, uint256 realMoney,) = _marketSettlementState(marketId);
        mm.settleMarket(marketId);

        uint256 winner = mm.winningProposalByMarketId(marketId).proposalId;
        address ventureToken = hub.ventureTokenById(market.ventureId);
        address moneyToken = hub.ventureMoneyTokenById(market.ventureId);
        assertGe(
            IERC20(ventureToken).balanceOf(address(mm)),
            mm.userVirtualVentureSupply(winner),
            "post-settle: core cannot cover winning venture claims"
        );
        assertGe(
            IERC20(moneyToken).balanceOf(address(mm)),
            mm.userVirtualMoneySupply(winner),
            "post-settle: core cannot cover winning money claims"
        );

        _verifySettlementReservation(marketId, winner, [ventureToken, moneyToken], [realVenture, realMoney]);
        mm.collectProtocolFees(marketId);
    }

    /// @notice The spot return is ATOMIC with settlement (deliberate design choice — no deferral). If
    ///         the vault return reverts (e.g. a transient spot-vs-TWAP deviation in the vault's own
    ///         sandwich guard), settleMarket() reverts as a whole and the market stays unsettled,
    ///         retryable once the condition clears. Claims never see a settled-but-not-returned state.
    function test_settlement_atomicReAdd_revertBlocksSettleUntilCleared() public {
        _createVentureAndMarket();
        _setupTrader(bob);
        Market memory market = _marketById(marketId);
        uint256 proposal1Id = market.proposalIds[1];

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(bob);
        mm.split(marketId, 0, 5_000e6);
        _swapExactIn(bob, proposal1Id, 500e6, false); // give the winning proposal excess to re-add

        vm.warp(market.tradingEnd + 1);

        // Force the settlement vault return to revert -> the whole settleMarket reverts (atomic).
        address vault = hub.ventureLiquidityVault(hub.ventureById(market.ventureId).venture);
        vm.mockCallRevert(
            vault,
            abi.encodeWithSelector(ISpotLiquidityVault.returnFromDecisionMarket.selector),
            abi.encode("deviation")
        );
        vm.expectRevert();
        mm.settleMarket(marketId);
        assertFalse(mm.marketSettled(marketId), "market must NOT settle while the return reverts");

        // Once the spot condition clears, settlement + return commit atomically and claims pay out.
        vm.clearMockedCalls();
        mm.settleMarket(marketId);
        assertTrue(mm.marketSettled(marketId), "settles once the return can succeed");

        address moneyToken = hub.ventureMoneyTokenById(market.ventureId);
        uint256 balBefore = IERC20(moneyToken).balanceOf(bob);
        vm.prank(bob);
        mm.claimSettlement(marketId);
        assertGt(IERC20(moneyToken).balanceOf(bob), balBefore, "claim pays out after atomic settle");
    }

    /// @dev With a single market the core's ERC-20 balances back exactly one market's real balances.
    function _verifyExactConservation(uint256 _marketId) internal view {
        Market memory market = _marketById(_marketId);
        (uint256 realVenture, uint256 realMoney,) = _marketSettlementState(_marketId);
        for (uint256 i = 0; i < market.proposalIds.length; i++) {
            uint256 propId = market.proposalIds[i];
            (uint256 reserve0, uint256 reserve1) = mm.cpmmStates(propId);
            assertEq(
                realVenture,
                mm.userVirtualVentureSupply(propId) + reserve0 + _accruedFeeVenture(propId),
                "venture real != user supply + reserve + fee"
            );
            assertEq(
                realMoney,
                mm.userVirtualMoneySupply(propId) + reserve1 + _accruedFeeMoney(propId),
                "money real != user supply + reserve + fee"
            );
        }
        assertEq(IERC20(hub.ventureTokenById(market.ventureId)).balanceOf(address(mm)), realVenture, "venture ERC20");
        assertEq(IERC20(hub.ventureMoneyTokenById(market.ventureId)).balanceOf(address(mm)), realMoney, "money ERC20");
    }

    /// @dev Claims of every holder, the winning fees and the vault re-add fit in the real balance,
    ///      leaving at most the 1 wei buffer plus 1 wei of LP flooring per claimant.
    function _verifySettlementReservation(
        uint256 _marketId,
        uint256 winner,
        address[2] memory tokens,
        uint256[2] memory realBalances
    ) internal {
        (uint256 feeVenture, uint256 feeMoney) = mm.proposalFeeState(winner);
        uint256[2] memory fees = [feeVenture, feeMoney];
        uint256[2] memory before;
        for (uint256 t = 0; t < 2; t++) {
            before[t] = IERC20(tokens[t]).balanceOf(address(mm));
        }

        address[] memory holders = new address[](2);
        holders[0] = bob;
        holders[1] = charlie;
        mm.claimSettlementFor(_marketId, holders);
        assertEq(mm.userVirtualVentureSupply(winner) + mm.userVirtualMoneySupply(winner), 0, "unclaimed winner");

        for (uint256 t = 0; t < 2; t++) {
            uint256 reAdded = realBalances[t] - before[t];
            uint256 paid = before[t] - IERC20(tokens[t]).balanceOf(address(mm));
            assertLe(paid + fees[t] + reAdded, realBalances[t], "settlement reserved more than it holds");
            assertLe(realBalances[t] - paid - fees[t] - reAdded, 3, "stranded dust");
        }
    }

    function _minPerProposalBalance(address who, uint256[] memory proposalIds)
        internal
        view
        returns (uint256 minVenture, uint256 minMoney)
    {
        minVenture = type(uint256).max;
        minMoney = type(uint256).max;
        for (uint256 j = 0; j < proposalIds.length; j++) {
            uint256 v = mm.balanceOf(who, mm.getVirtualVentureId(proposalIds[j]));
            uint256 m = mm.balanceOf(who, mm.getVirtualMoneyId(proposalIds[j]));
            if (v < minVenture) minVenture = v;
            if (m < minMoney) minMoney = m;
        }
    }
}
