// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {DecisionMarketBase} from "../markets/DecisionMarketBase.t.sol";
import {AtomicMarketOpener} from "../../script/testnet-utils/AtomicMarketOpener.sol";
import {AtomicMarketSettler} from "../../script/testnet-utils/AtomicMarketSettler.sol";
import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {ISpotLiquidityVault} from "../../src/interfaces/ISpotLiquidityVault.sol";
import {Venture} from "../../src/core/Venture.sol";

/// @notice Self-contained proof that the testnet atomic opener/settler get past the
///         SpotLiquidityVault deviation guard that a bare create/settle trips when spot has been
///         pushed far from the TWAP. Deploys the whole protocol via DecisionMarketBase — no fork,
///         no live-testnet dependency.
contract AtomicMarketHelpersTest is DecisionMarketBase {
    // A large one-shot spot buy that moves the tick well past the 1000-tick guard threshold.
    uint256 constant BIG_SPOT_BUY_USDC = 400_000e6;
    // Enough venture token to reverse that move back onto the TWAP; leftovers are swept back.
    uint256 constant PIN_FUNDING = 600_000e18;

    /// @dev Warm the oracle at a stable price, then shove spot far above the TWAP in one swap.
    ///      No warp afterwards, so the 30-min TWAP still reflects the pre-swap price.
    function _pushSpotOutOfRange() internal {
        _warmSpotOracle(venture);
        _swapSpot(venture, BIG_SPOT_BUY_USDC, true);
    }

    function test_settler_settlesPastDeviationGuard() external {
        uint256 mId = _createVentureAndMarket();

        vm.warp(_marketById(mId).tradingEnd + 1);
        _pushSpotOutOfRange();

        // A bare settle trips the deviation guard when returning seed liquidity.
        vm.expectRevert(ISpotLiquidityVault.SpotPriceDeviationTooHigh.selector);
        mm.settleMarket(mId);

        AtomicMarketSettler settler = new AtomicMarketSettler(address(hub), address(manager), address(umiaHook));
        _mintVenture(hub, venture, address(settler), PIN_FUNDING);

        settler.run(ventureId, mId);

        assertTrue(mm.marketSettled(mId), "market should be settled");
    }

    function test_opener_createsPastDeviationGuard() external {
        (ventureId, venture) = _createVentureWithLBP(hub, alice, "openerVenture", "OPN", 1_000_000e18);
        ventureToken = Venture(payable(venture)).token();

        vm.prank(umiaAdmin);
        hub.setVentureMinMarketStake(ventureId, MIN_MARKET_STAKE);

        _pushSpotOutOfRange();

        IUmiaMarketCore.CreateProposalParams[] memory proposals = new IUmiaMarketCore.CreateProposalParams[](2);
        proposals[0] = IUmiaMarketCore.CreateProposalParams({title: "Do nothing", executionPayload: ""});
        proposals[1] = IUmiaMarketCore.CreateProposalParams({title: "Do the thing", executionPayload: ""});

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: ventureId,
            title: "Should we do the thing?",
            startTimestamp: block.timestamp,
            duration: 0,
            proposals: proposals
        });

        // A bare create by a staked EOA trips the deviation guard while spot is out of range.
        _mintVenture(hub, venture, alice, MIN_MARKET_STAKE);
        vm.startPrank(alice);
        IERC20(ventureToken).approve(address(marketStake), MIN_MARKET_STAKE);
        marketStake.depositMarketStake(ventureId);
        uint256 aliceNonce = mm.marketCreationNonces(alice);
        bytes memory aliceSig = _signMarketCreation(alice, params, aliceNonce);
        vm.expectRevert(ISpotLiquidityVault.SpotPriceDeviationTooHigh.selector);
        mm.createMarket(params, alice, aliceNonce, aliceSig);
        vm.stopPrank();

        // The atomic opener pins spot onto the TWAP first, so its create succeeds in the same tx.
        AtomicMarketOpener opener = new AtomicMarketOpener(address(hub), address(manager), address(umiaHook));
        _mintVenture(hub, venture, address(opener), PIN_FUNDING);
        uint256 openerNonce = mm.marketCreationNonces(address(opener));
        bytes memory openerSig = _signMarketCreation(address(opener), params, openerNonce);

        uint256 mId = opener.run(
            AtomicMarketOpener.RunParams({
                ventureId: ventureId,
                title: params.title,
                startTimestamp: params.startTimestamp,
                duration: params.duration,
                proposals: proposals,
                nonce: openerNonce,
                signature: openerSig
            })
        );

        assertGt(mId, 0, "market should be created");
        assertEq(mm.activeMarketByVenture(ventureId), mId, "market should be active for the venture");
    }
}
