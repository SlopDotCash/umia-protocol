// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {IUmiaHub} from "../../src/interfaces/IUmiaHub.sol";
import {IVenture} from "../../src/interfaces/IVenture.sol";
import {IERC20Pinner, SpotTwapPinner} from "./SpotTwapPinner.sol";

interface IMarketStakeLike {
    function depositMarketStake(uint256 ventureId) external;
}

/// @title AtomicMarketOpener
/// @notice **Testnet utility, not part of the protocol.** Atomically pins spot onto the venture's
///         30-minute TWAP, deposits the market stake, and creates a decision market — in one
///         transaction, so adversarial spot flow can't move the price out of the
///         `SpotLiquidityVault` deviation guard between the pin and the create. Opt-in tool for
///         when `createMarket` reverts with `SpotPriceDeviationTooHigh`.
///
///         Single-use: deploy, fund with enough venture token for the pin swap + market stake,
///         call `run` once, discard. Leftover tokens are swept back to the deployer.
contract AtomicMarketOpener is SpotTwapPinner {
    constructor(address hub, address poolManager, address hook) SpotTwapPinner(hub, poolManager, hook) {}

    struct RunParams {
        uint256 ventureId;
        string title;
        uint256 startTimestamp;
        uint256 duration;
        IUmiaMarketCore.CreateProposalParams[] proposals;
        uint256 nonce;
        /// @dev The market-creation signer's EIP-712 approval over (this contract, ventureId,
        ///      title, startTimestamp, duration, proposals, nonce). `creator` is this contract.
        bytes signature;
    }

    function run(RunParams calldata p) external onlyOwner returns (uint256 marketId) {
        address ventureTreasury = HUB.ventureById(p.ventureId).venture;

        _pinSpotToTwap(p.ventureId);

        address stake = HUB.umiaMarketStake();
        if (stake != address(0)) {
            uint256 minStake = IVenture(ventureTreasury).minMarketStake();
            if (minStake != 0) {
                IERC20Pinner(_venture).approve(stake, minStake);
                IMarketStakeLike(stake).depositMarketStake(p.ventureId);
            }
        }

        IUmiaMarketCore.CreateMarketParams memory params = IUmiaMarketCore.CreateMarketParams({
            ventureId: p.ventureId,
            title: p.title,
            startTimestamp: p.startTimestamp,
            duration: p.duration,
            proposals: p.proposals
        });
        marketId = IUmiaMarketCore(HUB.umiaMarketCore()).createMarket(params, address(this), p.nonce, p.signature);

        _sweep(_venture);
        _sweep(_money);
    }
}
