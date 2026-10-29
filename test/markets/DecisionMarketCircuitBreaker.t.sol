// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {UmiaMarketCore} from "../../src/core/UmiaMarketCore.sol";
import {UmiaHub} from "../../src/core/UmiaHub.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {Venture} from "../../src/core/Venture.sol";
import {DecisionMarketBase} from "./DecisionMarketBase.t.sol";

contract DecisionMarketCircuitBreakerTest is DecisionMarketBase {
    address guardian = makeAddr("guardian");

    function setUp() public override {
        super.setUp();
    }

    // ─────────────────────────────────────────────────────────
    // UmiaHub: tripDecisionMarketCircuitBreaker
    // ─────────────────────────────────────────────────────────

    function test_tripDecisionMarketCircuitBreaker_setsMapping() public {
        _createVentureAndMarket();

        vm.prank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        assertTrue(hub.decisionMarketCircuitBreakerActive(marketId));
    }

    function test_tripDecisionMarketCircuitBreaker_emitsEvent() public {
        _createVentureAndMarket();

        vm.expectEmit(true, false, false, false);
        emit IUmiaHub.DecisionMarketCircuitBreakerTripped(marketId);

        vm.prank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(marketId);
    }

    function test_tripDecisionMarketCircuitBreaker_onlyOwner() public {
        _createVentureAndMarket();

        vm.prank(alice);
        vm.expectRevert();
        hub.tripDecisionMarketCircuitBreaker(marketId);
    }

    function test_tripDecisionMarketCircuitBreaker_cannotTripTwice() public {
        _createVentureAndMarket();

        vm.startPrank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        vm.expectRevert(IUmiaHub.DecisionMarketCircuitBreakerAlreadyActive.selector);
        hub.tripDecisionMarketCircuitBreaker(marketId);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────
    // UmiaMarketCore: executeWinningProposal blocked
    // ─────────────────────────────────────────────────────────

    function test_circuitBreaker_blocksExecution() public {
        _createVentureAndMarket();

        vm.warp(block.timestamp + 4 days);
        mm.settleMarket(marketId);

        vm.prank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        vm.expectRevert(IUmiaMarketCore.DecisionMarketCircuitBreakerActive.selector);
        mm.executeWinningProposal(marketId);
    }

    // ─────────────────────────────────────────────────────────
    // Operations that remain unaffected
    // ─────────────────────────────────────────────────────────

    function test_circuitBreaker_doesNotBlockSettlement() public {
        _createVentureAndMarket();

        vm.warp(block.timestamp + 4 days);

        vm.prank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        mm.settleMarket(marketId);
    }

    function test_circuitBreaker_doesNotBlockClaims() public {
        _createVentureAndMarket();
        _setupTrader(bob);

        vm.warp(block.timestamp + 1 days);

        _mintVenture(hub, venture, bob, 1000e18);
        usdc.mint(bob, 1000e6);

        vm.prank(bob);
        mm.split(marketId, 100e18, 100e6);

        vm.warp(block.timestamp + 4 days);
        mm.settleMarket(marketId);

        vm.prank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        vm.prank(bob);
        mm.claimSettlement(marketId);
    }

    function test_circuitBreaker_doesNotAffectOtherMarkets() public {
        _createVentureAndMarket();
        uint256 trippedMarketId = marketId;

        // Create a second market on a different venture so we can trip the breaker
        // on the first market while it's still active (unsettled)
        (uint256 otherVentureId, address payable otherVenture) =
            _createVentureWithLBP(hub, bob, "bobUMO", "BOB", 1_000_000e18);
        address otherVentureToken = Venture(payable(otherVenture)).token();

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(otherVentureId, MIN_MARKET_STAKE);

        _mintVenture(hub, otherVenture, bob, MIN_MARKET_STAKE);

        _warmSpotOracle(otherVenture);

        vm.startPrank(bob);
        IERC20(otherVentureToken).approve(address(marketStake), type(uint256).max);
        marketStake.depositMarketStake(otherVentureId);

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](1);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "do something", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: otherVentureId,
            title: "another market",
            startTimestamp: block.timestamp + 1 days,
            duration: 0,
            proposals: proposals
        });

        uint256 nonce = mm.marketCreationNonces(bob);
        bytes memory signature = _signMarketCreation(bob, params, nonce);
        uint256 otherMarketId = mm.createMarket(params, bob, nonce, signature);
        vm.stopPrank();

        // Trip the circuit breaker on the first market while it's still active
        vm.prank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(trippedMarketId);

        // The second market on a different venture should be unaffected
        assertFalse(hub.decisionMarketCircuitBreakerActive(otherMarketId));

        vm.warp(block.timestamp + 4 days);
        mm.settleMarket(otherMarketId);
        vm.warp(block.timestamp + 1 hours);
        mm.executeWinningProposal(otherMarketId);
    }

    function test_circuitBreaker_defaultFalse() public view {
        assertFalse(hub.decisionMarketCircuitBreakerActive(999));
    }

    // ─────────────────────────────────────────────────────────
    // Execution delay
    // ─────────────────────────────────────────────────────────

    function test_executionDelay_blocksEarlyExecution() public {
        vm.prank(umiaAdmin);
        hub.setDecisionMarketExecutionDelay(4 hours);

        _createVentureAndMarket();
        Market memory market = _marketById(marketId);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        vm.expectRevert(IUmiaMarketCore.ExecutionDelayActive.selector);
        mm.executeWinningProposal(marketId);
    }

    function test_executionDelay_allowsExecutionAfterDelay() public {
        vm.prank(umiaAdmin);
        hub.setDecisionMarketExecutionDelay(4 hours);

        _createVentureAndMarket();
        Market memory market = _marketById(marketId);

        vm.warp(market.tradingEnd + 1);
        mm.settleMarket(marketId);

        vm.warp(uint256(market.tradingEnd) + 4 hours + 1);
        mm.executeWinningProposal(marketId);

        assertTrue(mm.marketExecuted(marketId), "winning proposal should execute after the delay");
    }

    function test_setDecisionMarketExecutionDelay() public {
        assertEq(hub.MAX_EXECUTION_DELAY(), 12 hours);
        assertEq(hub.MIN_EXECUTION_DELAY(), 1 hours);
        assertEq(hub.DEFAULT_EXECUTION_DELAY(), 4 hours);

        vm.prank(umiaAdmin);
        vm.expectRevert(IUmiaHub.InvalidExecutionDelay.selector);
        hub.setDecisionMarketExecutionDelay(uint32(1 hours) - 1);
        vm.prank(umiaAdmin);
        vm.expectRevert(IUmiaHub.InvalidExecutionDelay.selector);
        hub.setDecisionMarketExecutionDelay(0);

        vm.prank(umiaAdmin);
        hub.setDecisionMarketExecutionDelay(6 hours);
        assertEq(hub.decisionMarketExecutionDelay(), 6 hours);

        vm.prank(umiaAdmin);
        vm.expectRevert(IUmiaHub.InvalidExecutionDelay.selector);
        hub.setDecisionMarketExecutionDelay(uint32(12 hours) + 1);

        vm.prank(alice);
        vm.expectRevert();
        hub.setDecisionMarketExecutionDelay(1 hours);
    }

    // ─────────────────────────────────────────────────────────
    // Execution delay anchored to settlement (not tradingEnd)
    // ─────────────────────────────────────────────────────────

    /// @dev Even when settlement is delayed until long after tradingEnd + delay, execution is still
    ///      gated for the full delay measured from settlement — so settleMarket + executeWinningProposal
    ///      can never run atomically with zero governance reaction time.
    function test_executionDelay_anchoredToSettlement_blocksDelayedAtomicExecute() public {
        vm.prank(umiaAdmin);
        hub.setDecisionMarketExecutionDelay(4 hours);

        _createVentureAndMarket();
        Market memory market = _marketById(marketId);

        // Delay settlement far past tradingEnd + delay; a tradingEnd anchor would be fully elapsed.
        vm.warp(uint256(market.tradingEnd) + 30 days);
        mm.settleMarket(marketId);

        // Still blocked: the delay runs from settlement (now), not tradingEnd.
        vm.expectRevert(IUmiaMarketCore.ExecutionDelayActive.selector);
        mm.executeWinningProposal(marketId);

        // Only after the delay elapses from settlement does execution succeed.
        vm.warp(block.timestamp + 4 hours + 1);
        mm.executeWinningProposal(marketId);
        assertTrue(mm.marketExecuted(marketId), "should execute a full delay after settlement");
    }

    // ─────────────────────────────────────────────────────────
    // UmiaHub: resetDecisionMarketCircuitBreaker (reversible pause)
    // ─────────────────────────────────────────────────────────

    function test_resetDecisionMarketCircuitBreaker_resumesExecution() public {
        _createVentureAndMarket();
        Market memory market = _marketById(marketId);

        vm.warp(uint256(market.tradingEnd) + 1);
        mm.settleMarket(marketId);
        vm.warp(block.timestamp + 4 hours + 1); // past the execution delay

        vm.prank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        vm.expectRevert(IUmiaMarketCore.DecisionMarketCircuitBreakerActive.selector);
        mm.executeWinningProposal(marketId);

        vm.prank(umiaAdmin);
        hub.resetDecisionMarketCircuitBreaker(marketId);
        assertFalse(hub.decisionMarketCircuitBreakerActive(marketId));

        // Execution resumes after the breaker is cleared.
        mm.executeWinningProposal(marketId);
        assertTrue(mm.marketExecuted(marketId), "execution should resume after reset");
    }

    function test_resetDecisionMarketCircuitBreaker_emitsEvent() public {
        _createVentureAndMarket();

        vm.startPrank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        vm.expectEmit(true, false, false, false);
        emit IUmiaHub.DecisionMarketCircuitBreakerReset(marketId);
        hub.resetDecisionMarketCircuitBreaker(marketId);
        vm.stopPrank();
    }

    function test_resetDecisionMarketCircuitBreaker_onlyOwner() public {
        _createVentureAndMarket();

        vm.prank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        vm.prank(alice);
        vm.expectRevert();
        hub.resetDecisionMarketCircuitBreaker(marketId);
    }

    function test_resetDecisionMarketCircuitBreaker_revertsWhenNotActive() public {
        _createVentureAndMarket();

        vm.prank(umiaAdmin);
        vm.expectRevert(IUmiaHub.DecisionMarketCircuitBreakerNotActive.selector);
        hub.resetDecisionMarketCircuitBreaker(marketId);
    }

    // ─────────────────────────────────────────────────────────
    // UmiaHub: veto guardian (trip-only, separate from owner)
    // ─────────────────────────────────────────────────────────

    function test_setVetoGuardian_setsAndEmits() public {
        assertEq(hub.vetoGuardian(), address(0), "guardian unset by default");

        vm.expectEmit(true, true, false, false);
        emit IUmiaHub.VetoGuardianUpdated(address(0), guardian);

        vm.prank(umiaAdmin);
        hub.setVetoGuardian(guardian);

        assertEq(hub.vetoGuardian(), guardian);
    }

    function test_setVetoGuardian_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        hub.setVetoGuardian(guardian);
    }

    function test_setVetoGuardian_zeroRevokes() public {
        vm.startPrank(umiaAdmin);
        hub.setVetoGuardian(guardian);
        hub.setVetoGuardian(address(0));
        vm.stopPrank();
        assertEq(hub.vetoGuardian(), address(0));

        _createVentureAndMarket();

        // Former guardian can no longer trip once revoked.
        vm.prank(guardian);
        vm.expectRevert(IUmiaHub.UnauthorizedVeto.selector);
        hub.tripDecisionMarketCircuitBreaker(marketId);
    }

    function test_tripDecisionMarketCircuitBreaker_byGuardian() public {
        vm.prank(umiaAdmin);
        hub.setVetoGuardian(guardian);

        _createVentureAndMarket();

        vm.prank(guardian);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        assertTrue(hub.decisionMarketCircuitBreakerActive(marketId));
    }

    function test_tripDecisionMarketCircuitBreaker_ownerTripsWithGuardianSet() public {
        vm.prank(umiaAdmin);
        hub.setVetoGuardian(guardian);

        _createVentureAndMarket();

        vm.prank(umiaAdmin);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        assertTrue(hub.decisionMarketCircuitBreakerActive(marketId));
    }

    function test_tripDecisionMarketCircuitBreaker_unauthorizedReverts() public {
        vm.prank(umiaAdmin);
        hub.setVetoGuardian(guardian);

        _createVentureAndMarket();

        // Neither owner nor guardian.
        vm.prank(alice);
        vm.expectRevert(IUmiaHub.UnauthorizedVeto.selector);
        hub.tripDecisionMarketCircuitBreaker(marketId);
    }

    function test_guardianCannotResetCircuitBreaker() public {
        vm.prank(umiaAdmin);
        hub.setVetoGuardian(guardian);

        _createVentureAndMarket();

        vm.prank(guardian);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        // Reset stays owner-only: the guardian can pause but never resume.
        vm.prank(guardian);
        vm.expectRevert();
        hub.resetDecisionMarketCircuitBreaker(marketId);

        assertTrue(hub.decisionMarketCircuitBreakerActive(marketId), "breaker stays tripped");
    }

    function test_guardianVeto_blocksExecution_ownerResumes() public {
        vm.prank(umiaAdmin);
        hub.setVetoGuardian(guardian);

        _createVentureAndMarket();
        Market memory market = _marketById(marketId);

        vm.warp(uint256(market.tradingEnd) + 1);
        mm.settleMarket(marketId);
        vm.warp(block.timestamp + 4 hours + 1); // past the execution delay

        // Guardian (not the owner) vetoes by tripping the breaker.
        vm.prank(guardian);
        hub.tripDecisionMarketCircuitBreaker(marketId);

        vm.expectRevert(IUmiaMarketCore.DecisionMarketCircuitBreakerActive.selector);
        mm.executeWinningProposal(marketId);

        // Only the owner can resume execution.
        vm.prank(umiaAdmin);
        hub.resetDecisionMarketCircuitBreaker(marketId);

        mm.executeWinningProposal(marketId);
        assertTrue(mm.marketExecuted(marketId), "execution should resume after owner reset");
    }
}
