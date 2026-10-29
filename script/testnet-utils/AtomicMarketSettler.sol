// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUmiaMarketCore} from "../../src/interfaces/IUmiaMarketCore.sol";
import {SpotTwapPinner} from "./SpotTwapPinner.sol";

/// @title AtomicMarketSettler
/// @notice **Testnet utility, not part of the protocol.** Atomically pins spot onto the venture's
///         30-minute TWAP and then settles an ended decision market — in one transaction, so
///         adversarial spot flow can't move the price out of the `SpotLiquidityVault` deviation
///         guard that `returnFromDecisionMarket` re-checks. `settleMarket` is permissionless, so no
///         signature or stake is involved. Opt-in tool for when `settleMarket` reverts with
///         `SpotPriceDeviationTooHigh`.
///
///         Single-use: deploy, fund with enough venture token for the pin swap, call `run` once,
///         discard. Leftover tokens are swept back to the deployer.
contract AtomicMarketSettler is SpotTwapPinner {
    constructor(address hub, address poolManager, address hook) SpotTwapPinner(hub, poolManager, hook) {}

    function run(uint256 ventureId, uint256 marketId) external onlyOwner {
        _pinSpotToTwap(ventureId);
        IUmiaMarketCore(HUB.umiaMarketCore()).settleMarket(marketId);
        _sweep(_venture);
        _sweep(_money);
    }
}
