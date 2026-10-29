// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

import {IUmiaHub} from "../interfaces/IUmiaHub.sol";
import {IUmiaMarketCore} from "../interfaces/IUmiaMarketCore.sol";
import {IConditionalMarketOracle} from "../interfaces/IConditionalMarketOracle.sol";
import {IVenture} from "../interfaces/IVenture.sol";
import {ISpotLiquidityVault} from "../interfaces/ISpotLiquidityVault.sol";
import {CPMM} from "./CPMM.sol";
import {MarketData, Pool, SettleAcct} from "./MarketCoreTypes.sol";
import {LedgerLib} from "./LedgerLib.sol";

/// @title SettlementLib
/// @notice Implements settlement for UmiaMarketCore: `settle` (winner selection by TWAP, winning-fee
///         reservation, and re-adding excess liquidity to the spot market), `claim` / `claimFor`
///         (per-user redemption of the winning proposal's tokens), and `collectFees`
///         (winning-proposal protocol fees).
/// @dev Executed via delegatecall from UmiaMarketCore, so it operates on the core's storage, which
///      is passed in as explicit references.
library SettlementLib {
    using SafeTransferLib for address;

    uint256 internal constant LP_SHARE_TOKEN_PREFIX = 1 << 255;

    /// @notice Finalize a market: pick the winning proposal by TWAP vs the snapshotted threshold,
    ///         reserve the winning proposal's protocol fee, mark `settled`, and atomically return the
    ///         spot excess to the venture's SpotLiquidityVault. Emits MarketSettled from the core.
    function settle(
        IUmiaHub hub,
        uint256 marketId,
        mapping(uint256 => uint256) storage totalSupply,
        mapping(uint256 => MarketData) storage markets,
        mapping(uint256 => Pool) storage pools,
        mapping(uint256 => SettleAcct) storage settleAcct
    ) external {
        MarketData storage market = markets[marketId];
        if (market.id == 0) revert IUmiaMarketCore.MarketNotFound();
        if (block.timestamp < market.tradingEnd) revert IUmiaMarketCore.MarketNotEnded();
        if (market.settled) revert IUmiaMarketCore.MarketAlreadySettled();

        uint256[] storage proposalIds = market.proposalIds;

        for (uint256 i = 0; i < proposalIds.length; i++) {
            _syncOracle(hub, proposalIds[i], pools);
        }

        // No-op proposal TWAP (always first proposal)
        uint256 noOpProposalId = proposalIds[0];
        uint256 noOpTWAP = _getProposalTWAP(hub, noOpProposalId, pools);

        // Find highest TWAP proposal
        uint256 highestTWAP = noOpTWAP;
        uint256 highestProposalId = noOpProposalId;

        for (uint256 i = 1; i < proposalIds.length; i++) {
            uint256 proposalId = proposalIds[i];
            uint256 proposalTWAP = _getProposalTWAP(hub, proposalId, pools);

            if (proposalTWAP > highestTWAP) {
                highestTWAP = proposalTWAP;
                highestProposalId = proposalId;
            }
        }

        // Check threshold if not no-op
        uint256 winningProposalId = noOpProposalId;
        uint256 winningTWAP = noOpTWAP;
        uint256 priceDeltaBps = 0;

        if (highestProposalId != noOpProposalId) {
            if (noOpTWAP == 0) {
                priceDeltaBps = type(uint256).max;
            } else {
                uint256 diff = highestTWAP > noOpTWAP ? highestTWAP - noOpTWAP : noOpTWAP - highestTWAP;
                priceDeltaBps = FullMath.mulDiv(diff, 10_000, noOpTWAP);
            }

            // Use the snapshotted threshold from market creation, not the live Hub value
            if (priceDeltaBps >= market.winningThresholdBps) {
                winningProposalId = highestProposalId;
                winningTWAP = highestTWAP;
            }
        }

        // Store flattened winner (price is TWAP in Q112 format)
        SettleAcct storage acct = settleAcct[marketId];
        acct.winningProposalId = winningProposalId;
        acct.winningPriceX112 = winningTWAP;

        // Compute what users need to claim (userVirtualSupply + collective LP claims in winning
        // proposal), reserving the winning proposal's protocol fees.
        Pool storage winningPool = pools[winningProposalId];
        uint256 feeVenture = winningPool.accruedFeeVenture;
        uint256 feeMoney = winningPool.accruedFeeMoney;

        uint256 userVentureClaims = winningPool.userVirtualVentureSupply;
        uint256 userMoneyClaims = winningPool.userVirtualMoneySupply;
        (uint256 lpVentureClaims, uint256 lpMoneyClaims) =
            _previewCollectiveUserLiquidityClaim(winningProposalId, pools, totalSupply);

        // Total real tokens available for this market (the seed escrow is already folded into the
        // real balance at creation), minus the winning proposal's reserved fees.
        uint256 totalRealVenture = acct.realVentureBalance - feeVenture;
        uint256 totalRealMoney = acct.realMoneyBalance - feeMoney;

        // Excess that can go back to LP (after reserving for user claims, +1 dust buffer)
        uint256 ventureToReAdd = totalRealVenture > userVentureClaims + lpVentureClaims + 1
            ? totalRealVenture - userVentureClaims - lpVentureClaims - 1
            : 0;
        uint256 moneyToReAdd = totalRealMoney > userMoneyClaims + lpMoneyClaims + 1
            ? totalRealMoney - userMoneyClaims - lpMoneyClaims - 1
            : 0;

        // activeUnsettledMarketCount is decremented by the core wrapper, not here.
        market.settled = true;
        // Anchor the execution delay to settlement (when the winner becomes known), not to
        // tradingEnd — settleMarket is permissionless and delayable, so a tradingEnd anchor could be
        // fully elapsed before the outcome is decided, letting settle+execute run atomically.
        acct.settledAt = uint64(block.timestamp);

        emit IUmiaMarketCore.MarketSettled(marketId, winningProposalId, winningTWAP, noOpTWAP, priceDeltaBps);

        // Return the excess to the venture's spot vault, which folds it back into the full-range
        // position under its own spot-vs-TWAP sandwich guard and clears the market's deployment record
        // (unblocking LP withdrawals). Deliberately NOT wrapped in try/catch: settlement and the return
        // commit or revert together. A transient spot deviation reverts settle() — permissionless and
        // retryable once it clears — so the market simply stays unsettled until the return succeeds.
        // Called whenever a vault exists, even with zero excess, so the deployment record is cleared.
        {
            address venture = hub.ventureById(market.ventureId).venture;
            address vault = hub.ventureLiquidityVault(venture);
            if (vault != address(0)) {
                if (ventureToReAdd > 0) {
                    SafeTransferLib.safeApprove(IVenture(venture).token(), vault, ventureToReAdd);
                }
                if (moneyToReAdd > 0) {
                    SafeTransferLib.safeApprove(IVenture(venture).moneyToken(), vault, moneyToReAdd);
                }
                ISpotLiquidityVault(vault).returnFromDecisionMarket(marketId, ventureToReAdd, moneyToReAdd);
            }
        }
    }

    /// @notice Redeem `user`'s winning-proposal virtual tokens + LP position for real tokens 1:1.
    function claim(
        IUmiaHub hub,
        uint256 marketId,
        address user,
        mapping(address => mapping(uint256 => uint256)) storage balanceOf,
        mapping(uint256 => uint256) storage totalSupply,
        mapping(uint256 => MarketData) storage markets,
        mapping(uint256 => Pool) storage pools,
        mapping(uint256 => SettleAcct) storage settleAcct,
        mapping(uint256 => mapping(address => bool)) storage hasClaimed
    ) external {
        uint256 winningPid = _claimableWinner(marketId, markets, settleAcct);
        if (hasClaimed[marketId][user]) revert IUmiaMarketCore.AlreadyClaimed();
        if (!_redeem(
                hub, marketId, markets[marketId].ventureId, winningPid, user, balanceOf, totalSupply, pools, hasClaimed
            )) {
            revert IUmiaMarketCore.NoClaimableTokens();
        }
    }

    /// @notice Redeem each of `users`' winning-proposal positions to that user, skipping users who
    ///         already claimed or hold nothing.
    function claimFor(
        IUmiaHub hub,
        uint256 marketId,
        address[] calldata users,
        mapping(address => mapping(uint256 => uint256)) storage balanceOf,
        mapping(uint256 => uint256) storage totalSupply,
        mapping(uint256 => MarketData) storage markets,
        mapping(uint256 => Pool) storage pools,
        mapping(uint256 => SettleAcct) storage settleAcct,
        mapping(uint256 => mapping(address => bool)) storage hasClaimed
    ) external {
        uint256 winningPid = _claimableWinner(marketId, markets, settleAcct);
        uint256 ventureId = markets[marketId].ventureId;
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            // The core's own balance holds the pools' reserves, not a claimable position.
            if (user == address(this)) revert IUmiaMarketCore.InvalidRecipient();
            if (hasClaimed[marketId][user]) continue;
            _redeem(hub, marketId, ventureId, winningPid, user, balanceOf, totalSupply, pools, hasClaimed);
        }
    }

    /// @notice Transfer the winning proposal's accrued protocol fees to the Hub fee recipient.
    function collectFees(
        IUmiaHub hub,
        uint256 marketId,
        mapping(uint256 => MarketData) storage markets,
        mapping(uint256 => Pool) storage pools,
        mapping(uint256 => SettleAcct) storage settleAcct
    ) external {
        if (!markets[marketId].settled) {
            revert IUmiaMarketCore.MarketNotSettled();
        }

        uint256 winningPid = settleAcct[marketId].winningProposalId;
        Pool storage winningPool = pools[winningPid];
        uint256 feeVenture = winningPool.accruedFeeVenture;
        uint256 feeMoney = winningPool.accruedFeeMoney;
        if (feeVenture == 0 && feeMoney == 0) return;

        address feeRecipient = hub.protocolFeeRecipient();
        if (feeRecipient == address(0)) return;

        uint256 ventureId = markets[marketId].ventureId;
        if (feeVenture > 0) {
            winningPool.accruedFeeVenture = 0;
            hub.ventureTokenById(ventureId).safeTransfer(feeRecipient, feeVenture);
        }
        if (feeMoney > 0) {
            winningPool.accruedFeeMoney = 0;
            hub.ventureMoneyTokenById(ventureId).safeTransfer(feeRecipient, feeMoney);
        }

        emit IUmiaMarketCore.ProtocolFeesCollected(marketId, feeRecipient, feeVenture, feeMoney);
    }

    // ─────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────

    function _claimableWinner(
        uint256 marketId,
        mapping(uint256 => MarketData) storage markets,
        mapping(uint256 => SettleAcct) storage settleAcct
    ) internal view returns (uint256 winningPid) {
        MarketData storage market = markets[marketId];
        if (market.id == 0) revert IUmiaMarketCore.MarketNotFound();
        if (block.timestamp < market.tradingEnd) revert IUmiaMarketCore.MarketNotEnded();
        winningPid = settleAcct[marketId].winningProposalId;
        if (winningPid == 0) revert IUmiaMarketCore.MarketNotSettled();
    }

    /// @return claimed False when `user` had nothing to redeem.
    function _redeem(
        IUmiaHub hub,
        uint256 marketId,
        uint256 ventureId,
        uint256 winningPid,
        address user,
        mapping(address => mapping(uint256 => uint256)) storage balanceOf,
        mapping(uint256 => uint256) storage totalSupply,
        mapping(uint256 => Pool) storage pools,
        mapping(uint256 => mapping(address => bool)) storage hasClaimed
    ) internal returns (bool claimed) {
        // Redeem the user's LP-share position first (mints virtual tokens from reserves to the user).
        _claimLiquidityPosition(winningPid, user, balanceOf, totalSupply, pools);

        uint256 virtualVentureBal = balanceOf[user][_virtualVentureId(winningPid)];
        uint256 virtualMoneyBal = balanceOf[user][_virtualMoneyId(winningPid)];

        if (virtualVentureBal == 0 && virtualMoneyBal == 0) return false;

        // CEI: mark claimed before any external transfer.
        hasClaimed[marketId][user] = true;

        Pool storage winningPool = pools[winningPid];

        // Burn virtual tokens and transfer real tokens to user 1:1.
        if (virtualVentureBal > 0) {
            LedgerLib.burn(balanceOf, totalSupply, user, _virtualVentureId(winningPid), virtualVentureBal);
            winningPool.userVirtualVentureSupply -= virtualVentureBal;
            hub.ventureTokenById(ventureId).safeTransfer(user, virtualVentureBal);
        }
        if (virtualMoneyBal > 0) {
            LedgerLib.burn(balanceOf, totalSupply, user, _virtualMoneyId(winningPid), virtualMoneyBal);
            winningPool.userVirtualMoneySupply -= virtualMoneyBal;
            hub.ventureMoneyTokenById(ventureId).safeTransfer(user, virtualMoneyBal);
        }

        emit IUmiaMarketCore.SettlementClaimed(marketId, user, virtualVentureBal, virtualMoneyBal);
        return true;
    }

    /// @notice Redeem a user's LP-share position pro-rata: burn shares, pull reserves out, and
    ///         mint the corresponding virtual tokens to the user.
    function _claimLiquidityPosition(
        uint256 proposalId,
        address user,
        mapping(address => mapping(uint256 => uint256)) storage balanceOf,
        mapping(uint256 => uint256) storage totalSupply,
        mapping(uint256 => Pool) storage pools
    ) internal returns (uint256 ventureAmount, uint256 moneyAmount) {
        uint256 lpShareId = _lpShareId(proposalId);
        uint256 shares = balanceOf[user][lpShareId];
        if (shares == 0) return (0, 0);

        Pool storage pool = pools[proposalId];
        uint256 totalShares = pool.totalLiquidityShares;
        if (totalShares == 0) revert IUmiaMarketCore.InvariantViolation();

        CPMM.State storage cpmmState = pool.cpmm;
        ventureAmount = FullMath.mulDiv(cpmmState.reserve0, shares, totalShares);
        moneyAmount = FullMath.mulDiv(cpmmState.reserve1, shares, totalShares);

        LedgerLib.burn(balanceOf, totalSupply, user, lpShareId, shares);
        pool.totalLiquidityShares = totalShares - shares;

        uint256 vVentureId = _virtualVentureId(proposalId);
        uint256 vMoneyId = _virtualMoneyId(proposalId);

        if (ventureAmount > 0) {
            cpmmState.reserve0 -= ventureAmount;
            LedgerLib.move(balanceOf, address(this), user, vVentureId, ventureAmount);
            pool.userVirtualVentureSupply += ventureAmount;
        }

        if (moneyAmount > 0) {
            cpmmState.reserve1 -= moneyAmount;
            LedgerLib.move(balanceOf, address(this), user, vMoneyId, moneyAmount);
            pool.userVirtualMoneySupply += moneyAmount;
        }

        if (ventureAmount > 0 || moneyAmount > 0) {
            emit IUmiaMarketCore.LiquidityRemoved(proposalId, user, ventureAmount, moneyAmount);
        }
    }

    /// @notice Preview the collective (all-users) LP claim against a proposal's reserves.
    /// @dev The protocol-seeded baseline is part of `totalLiquidityShares` but is never minted, so
    ///      the LP-share `totalSupply` is the user-owned share count only.
    function _previewCollectiveUserLiquidityClaim(
        uint256 proposalId,
        mapping(uint256 => Pool) storage pools,
        mapping(uint256 => uint256) storage totalSupply
    ) internal view returns (uint256 ventureAmount, uint256 moneyAmount) {
        uint256 totalShares = pools[proposalId].totalLiquidityShares;
        if (totalShares == 0) return (0, 0);

        uint256 userShares = totalSupply[_lpShareId(proposalId)];
        if (userShares == 0) return (0, 0);

        CPMM.State storage cpmmState = pools[proposalId].cpmm;
        ventureAmount = FullMath.mulDiv(cpmmState.reserve0, userShares, totalShares);
        moneyAmount = FullMath.mulDiv(cpmmState.reserve1, userShares, totalShares);
    }

    /// @notice Sync the oracle with the current reserves of a proposal.
    function _syncOracle(IUmiaHub hub, uint256 proposalId, mapping(uint256 => Pool) storage pools) internal {
        CPMM.State storage s = pools[proposalId].cpmm;
        IConditionalMarketOracle(hub.conditionalMarketOracle()).update(proposalId, s.reserve0, s.reserve1);
    }

    /// @notice Read the TWAP for a proposal from the oracle (Q112.112).
    function _getProposalTWAP(IUmiaHub hub, uint256 proposalId, mapping(uint256 => Pool) storage pools)
        internal
        view
        returns (uint256 twapX112)
    {
        CPMM.State storage s = pools[proposalId].cpmm;
        return IConditionalMarketOracle(hub.conditionalMarketOracle()).calculateTWAP(proposalId, s.reserve0, s.reserve1);
    }

    // ─────────────────────────────────────────────────────────
    // Token-id derivation (pure)
    // ─────────────────────────────────────────────────────────

    function _virtualVentureId(uint256 proposalId) internal pure returns (uint256) {
        return proposalId * 2;
    }

    function _virtualMoneyId(uint256 proposalId) internal pure returns (uint256) {
        return proposalId * 2 + 1;
    }

    function _lpShareId(uint256 proposalId) internal pure returns (uint256) {
        return LP_SHARE_TOKEN_PREFIX | proposalId;
    }
}
